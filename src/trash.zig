//! The freedesktop.org trash: listing what is in it (the home trash and
//! each mounted device's $topdir/.Trash/$uid and $topdir/.Trash-$uid),
//! with where each item was and when it was deleted, and finding where an
//! item goes back to.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const mime = @import("mime.zig");
const uri = @import("uri.zig");
const mounts = @import("mounts.zig");

/// Where each entry of a trash listing came from, parallel to its entries.
pub const Info = struct {
    gpa: Allocator,
    strings: []u8,
    items: []Item,

    pub const Item = struct {
        off: u32 = 0,
        len: u32 = 0,
        /// DeletionDate as local wall-clock nanoseconds (formatted with no
        /// time zone offset), 0 if unknown.
        deleted: i64 = 0,
    };

    pub const Entry = struct { original: []const u8, deleted: i64 };

    pub fn deinit(i: *Info) void {
        i.gpa.free(i.strings);
        i.gpa.free(i.items);
        i.* = undefined;
    }

    pub fn get(i: *const Info, index: u32) Entry {
        if (index >= i.items.len) return .{ .original = "", .deleted = 0 };
        const it = i.items[index];
        return .{ .original = i.strings[it.off..][0..it.len], .deleted = it.deleted };
    }
};

/// The trash directories to show: the home trash, then each mount
/// point's.
pub fn trashDirs(gpa: Allocator, home_trash: []const u8, mount_points: []const []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |d| gpa.free(d);
        out.deinit(gpa);
    }
    try out.append(gpa, try gpa.dupe(u8, home_trash));
    const uid = linux.getuid();
    for (mount_points) |mp| {
        const top = if (std.mem.eql(u8, mp, "/")) "" else mp;
        var buf: [linux.PATH_MAX]u8 = undefined;
        const a = std.fmt.bufPrint(&buf, "{s}/.Trash/{d}", .{ top, uid }) catch continue;
        if (isDir(a)) try out.append(gpa, try gpa.dupe(u8, a));
        const b = std.fmt.bufPrint(&buf, "{s}/.Trash-{d}", .{ top, uid }) catch continue;
        if (isDir(b)) try out.append(gpa, try gpa.dupe(u8, b));
    }
    return out.toOwnedSlice(gpa);
}

/// Lists the home trash and every mounted file system's trash.
pub fn listAll(gpa: Allocator, home_trash: []const u8, db: ?*mime.Db, info: *Info) model.ReadError!model.Listing {
    var table = mounts.read(gpa) catch return error.OutOfMemory;
    defer table.deinit();
    const mps = table.realMountPoints(gpa) catch return error.OutOfMemory;
    defer gpa.free(mps);
    return list(gpa, home_trash, mps, db, info);
}

/// Lists every trash: a listing rooted at "/" whose names are the trashed
/// files' paths without the leading slash (so `pathOf` gives where they
/// are now), with `info` saying where they were. Blocking.
pub fn list(gpa: Allocator, home_trash: []const u8, mount_points: []const []const u8, db: ?*mime.Db, info: *Info) model.ReadError!model.Listing {
    const dirs = trashDirs(gpa, home_trash, mount_points) catch return error.OutOfMemory;
    defer {
        for (dirs) |d| gpa.free(d);
        gpa.free(dirs);
    }
    var b: model.Builder = .{ .gpa = gpa };
    errdefer b.deinit();
    var strings: std.ArrayList(u8) = .empty;
    errdefer strings.deinit(gpa);
    var items: std.ArrayList(Info.Item) = .empty;
    errdefer items.deinit(gpa);
    var sniffs: usize = 0;
    for (dirs) |dir| {
        var fbuf: [linux.PATH_MAX]u8 = undefined;
        const files = std.fmt.bufPrintSentinel(&fbuf, "{s}/files", .{dir}, 0) catch continue;
        const fd = model.openDir(files) catch continue;
        defer _ = linux.close(fd);
        const top = topOf(dir);
        var buf: [16 * 1024]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off < n) {
                const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
                off += d.reclen;
                const raw: [*:0]const u8 = @ptrCast(&buf[off - d.reclen + @offsetOf(linux.dirent64, "name")]);
                const nm = std.mem.span(raw);
                if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
                var e = model.statEntry(fd, raw, nm);
                // Hidden files are not hidden in the trash.
                e.hidden = false;
                if (db) |m| e.mime = model.classify(m, fd, raw, nm, e, &sniffs);
                var rel_buf: [linux.PATH_MAX]u8 = undefined;
                const rel = std.fmt.bufPrint(&rel_buf, "{s}/{s}", .{ files[1..], nm }) catch continue;
                try b.add(rel, e);
                // Its info file.
                var item: Info.Item = .{};
                var ibuf: [linux.PATH_MAX]u8 = undefined;
                const info_path = std.fmt.bufPrint(&ibuf, "{s}/info/{s}.trashinfo", .{ dir, nm }) catch "";
                var contents: [8192]u8 = undefined;
                if (readSmall(info_path, &contents)) |body| {
                    const parsed = parseInfo(body);
                    var pbuf: [linux.PATH_MAX]u8 = undefined;
                    if (decodePath(&pbuf, parsed.path)) |p| {
                        item.off = @intCast(strings.items.len);
                        if (p.len > 0 and p[0] != '/') {
                            // Relative to the device's top directory.
                            try strings.appendSlice(gpa, top);
                            if (top.len == 0 or top[top.len - 1] != '/') try strings.append(gpa, '/');
                        }
                        try strings.appendSlice(gpa, p);
                        item.len = @intCast(strings.items.len - item.off);
                    }
                    item.deleted = parseDate(parsed.date);
                }
                try items.append(gpa, item);
            }
        }
    }
    if (db) |m| model.warmComments(m, b.entries.items);
    const l = try b.finish("/");
    info.* = .{
        .gpa = gpa,
        .strings = strings.toOwnedSlice(gpa) catch return error.OutOfMemory,
        .items = items.toOwnedSlice(gpa) catch return error.OutOfMemory,
    };
    return l;
}

/// The top directory a trash belongs to: "/x/.Trash-1000" → "/x",
/// "/x/.Trash/1000" → "/x"; "" for the home trash.
fn topOf(dir: []const u8) []const u8 {
    const base = model.basename(dir);
    if (std.mem.startsWith(u8, base, ".Trash-")) return model.parent(dir);
    const up = model.parent(dir);
    if (std.mem.eql(u8, model.basename(up), ".Trash")) return model.parent(up);
    return "";
}

const Parsed = struct { path: []const u8 = "", date: []const u8 = "" };

pub fn parseInfo(body: []const u8) Parsed {
    var p: Parsed = .{};
    var it = std.mem.splitScalar(u8, body, '\n');
    var in_section = false;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len > 0 and line[0] == '[') {
            in_section = std.mem.eql(u8, line, "[Trash Info]");
            continue;
        }
        if (!in_section) continue;
        if (std.mem.startsWith(u8, line, "Path=")) p.path = line[5..];
        if (std.mem.startsWith(u8, line, "DeletionDate=")) p.date = line[13..];
    }
    return p;
}

/// Percent-decodes a trashinfo Path.
pub fn decodePath(buf: []u8, s: []const u8) ?[]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (n >= buf.len) return null;
        if (s[i] == '%' and i + 2 < s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return null;
            buf[n] = v;
            i += 2;
        } else buf[n] = s[i];
        n += 1;
    }
    return buf[0..n];
}

/// "2026-10-13T14:05:09" as nanoseconds of that wall-clock time.
pub fn parseDate(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return 0;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const se = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return 0;
    const days = daysFromCivil(y, mo, d);
    return ((days * 86400) + h * 3600 + mi * 60 + se) * std.time.ns_per_s;
}

fn daysFromCivil(y_in: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Where a trashed file goes back to, from its info file, into `buf`.
pub fn originalPath(buf: []u8, trashed: []const u8) ?[]const u8 {
    const files_dir = model.parent(trashed);
    const dir = model.parent(files_dir);
    var ibuf: [linux.PATH_MAX]u8 = undefined;
    const info_path = std.fmt.bufPrint(&ibuf, "{s}/info/{s}.trashinfo", .{ dir, model.basename(trashed) }) catch return null;
    var contents: [8192]u8 = undefined;
    const body = readSmall(info_path, &contents) orelse return null;
    const parsed = parseInfo(body);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = decodePath(&pbuf, parsed.path) orelse return null;
    if (p.len > 0 and p[0] == '/') return std.fmt.bufPrint(buf, "{s}", .{p}) catch null;
    const top = topOf(dir);
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ top, p }) catch null;
}

/// Sorts a trash listing's indices by deletion date (modified) or
/// original location (type), then by name.
pub fn sortIndices(l: *const model.Listing, info: *const Info, order: []u32, s: model.Sort) void {
    const Ctx = struct {
        l: *const model.Listing,
        info: *const Info,
        s: model.Sort,
        fn less(ctx: @This(), a: u32, b: u32) bool {
            const ia = ctx.info.get(a);
            const ib = ctx.info.get(b);
            var ord: std.math.Order = switch (ctx.s.key) {
                .modified => std.math.order(ia.deleted, ib.deleted),
                else => std.mem.order(u8, ia.original, ib.original),
            };
            if (ord == .eq) ord = model.naturalOrder(ctx.l.base(ctx.l.entries[a]), ctx.l.base(ctx.l.entries[b]));
            if (ord == .eq) ord = std.math.order(a, b);
            return if (ctx.s.descending) ord == .gt else ord == .lt;
        }
    };
    std.mem.sort(u32, order, Ctx{ .l = l, .info = info, .s = s }, Ctx.less);
}

fn isDir(path: []const u8) bool {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

const testing = std.testing;

test "trash info" {
    const p = parseInfo("[Trash Info]\nPath=/home/me/a%20b.txt\nDeletionDate=2026-10-13T14:05:09\n");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/home/me/a b.txt", decodePath(&buf, p.path).?);
    var tb: [32]u8 = undefined;
    try testing.expectEqualStrings("2026-10-13 14:05", model.formatTime(&tb, parseDate(p.date), 0));
    try testing.expectEqualStrings("/media/usb", topOf("/media/usb/.Trash-1000"));
    try testing.expectEqualStrings("/media/usb", topOf("/media/usb/.Trash/1000"));
    try testing.expectEqualStrings("", topOf("/home/me/.local/share/Trash"));
}
