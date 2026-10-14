//! A directory's entries: reading them (on a worker thread), sorting,
//! and filtering. Plain Zig with no siv calls, so the tests exercise it
//! directly.
//!
//! Names live in one byte arena per listing; entries refer to them by
//! offset, so a listing of 100 000 entries is a handful of allocations. A
//! name is a path relative to the listing's folder: a plain name in a
//! folder's listing, "sub/dir/name" in recursive search results.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const mime = @import("mime.zig");

pub const Kind = enum(u8) { file, dir, other };

pub const Entry = struct {
    name_off: u32,
    name_len: u32,
    size: u64,
    /// Modification time in nanoseconds since the epoch.
    mtime: i64,
    mode: u32,
    /// Offset of the base name within the name (after the last slash).
    base_off: u16 = 0,
    mime: mime.Id = mime.unknown,
    kind: Kind,
    /// A symbolic link (kind is its target's).
    link: bool,
    hidden: bool,
};

pub const Listing = struct {
    gpa: Allocator,
    /// The directory, absolute and without a trailing slash (except "/").
    path: []u8,
    names: []u8,
    entries: []Entry,

    pub fn deinit(l: *Listing) void {
        l.gpa.free(l.path);
        l.gpa.free(l.names);
        l.gpa.free(l.entries);
        l.* = undefined;
    }

    /// The path relative to the folder.
    pub fn name(l: *const Listing, e: Entry) []const u8 {
        return l.names[e.name_off..][0..e.name_len];
    }

    /// The last component, as shown.
    pub fn base(l: *const Listing, e: Entry) []const u8 {
        return l.name(e)[e.base_off..];
    }

    /// The folder the entry is in, relative to the listing's ("" for the
    /// listing's own folder).
    pub fn dirOf(l: *const Listing, e: Entry) []const u8 {
        const n = l.name(e);
        return if (e.base_off == 0) "" else n[0 .. e.base_off - 1];
    }

    /// The entry's absolute path, in `buf`.
    pub fn pathOf(l: *const Listing, buf: []u8, e: Entry) ?[]u8 {
        return join(buf, l.path, l.name(e));
    }
};

/// Builds a listing entry by entry (the directory reader and recursive
/// search).
pub const Builder = struct {
    gpa: Allocator,
    names: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(b: *Builder) void {
        b.names.deinit(b.gpa);
        b.entries.deinit(b.gpa);
    }

    pub fn add(b: *Builder, rel: []const u8, e_in: Entry) !void {
        var e = e_in;
        e.name_off = @intCast(b.names.items.len);
        e.name_len = @intCast(rel.len);
        e.base_off = if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| @intCast(@min(i + 1, std.math.maxInt(u16))) else 0;
        try b.names.appendSlice(b.gpa, rel);
        try b.entries.append(b.gpa, e);
    }

    pub fn finish(b: *Builder, path: []const u8) !Listing {
        const owned_path = try b.gpa.dupe(u8, path);
        errdefer b.gpa.free(owned_path);
        const owned_names = try b.names.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(owned_names);
        return .{ .gpa = b.gpa, .path = owned_path, .names = owned_names, .entries = try b.entries.toOwnedSlice(b.gpa) };
    }
};

pub const ReadError = error{ FileNotFound, AccessDenied, NotDir, OutOfMemory, Unexpected };

/// How many files without a matching glob a listing reads the start of to
/// tell their type; the rest stay "unknown" until opened.
const max_sniffs = 512;

/// Reads `path` (absolute): every entry but "." and "..", with its type,
/// size, modification time, and MIME type (by name, or by content for a
/// few names no glob matches). Symbolic links report their target's
/// kind. Blocking: runs on a worker thread.
pub fn read(gpa: Allocator, path: []const u8, db: ?*mime.Db) ReadError!Listing {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const zpath = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return error.FileNotFound;
    const fd = try openDir(zpath);
    defer _ = linux.close(fd);

    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();
    var sniffs: usize = 0;
    var buf: [32 * 1024]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            off += d.reclen;
            const raw: [*:0]const u8 = @ptrCast(&buf[off - d.reclen + @offsetOf(linux.dirent64, "name")]);
            const nm = std.mem.span(raw);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            var e = statEntry(fd, raw, nm);
            if (db) |m| e.mime = classify(m, fd, raw, nm, e, &sniffs);
            try b.add(nm, e);
        }
    }
    if (db) |m| warmComments(m, b.entries.items);
    return b.finish(path);
}

pub fn openDir(zpath: [:0]const u8) ReadError!i32 {
    const rc = linux.openat(linux.AT.FDCWD, zpath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotDir,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// Reads the comment (type name) of every type in `entries` into the
/// database's cache, so that the UI thread finds them there.
pub fn warmComments(db: *mime.Db, entries: []const Entry) void {
    var seen: std.StaticBitSet(1 << 16) = .empty;
    for (entries) |e| {
        if (seen.isSet(e.mime)) continue;
        seen.set(e.mime);
        _ = db.comment(e.mime);
    }
}

/// The MIME type of an entry: folders, then the name's glob, then the
/// first bytes of the file.
pub fn classify(db: *mime.Db, dirfd: i32, zname: [*:0]const u8, nm: []const u8, e: Entry, sniffs: *usize) mime.Id {
    switch (e.kind) {
        .dir => return mime.directory,
        .other => return if (e.link) mime.symlink else db.byNameOr(nm, mime.octet_stream),
        .file => {},
    }
    if (db.byName(nm)) |id| return id;
    if (e.size == 0) return mime.zerosize;
    if (sniffs.* >= max_sniffs) return if (e.mode & 0o111 != 0) mime.executable else mime.unknown;
    sniffs.* += 1;
    var head: [512]u8 = undefined;
    const got = readHead(dirfd, zname, &head);
    return mime.sniff(db, got, e.mode);
}

fn readHead(dirfd: i32, zname: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.openat(dirfd, zname, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return buf[0..0];
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return buf[0..0];
    return buf[0..n];
}

/// The MIME type of one file by path (properties, opening).
pub fn typeOfPath(db: *mime.Db, path: []const u8) mime.Id {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return mime.unknown;
    const e = statEntry(linux.AT.FDCWD, z, basename(path));
    var sniffs: usize = 0;
    return classify(db, linux.AT.FDCWD, z, basename(path), e, &sniffs);
}

pub fn statEntry(dirfd: i32, zname: [*:0]const u8, nm: []const u8) Entry {
    var st: linux.Statx = undefined;
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true };
    var e: Entry = .{
        .name_off = 0,
        .name_len = 0,
        .size = 0,
        .mtime = 0,
        .mode = 0,
        .kind = .other,
        .link = false,
        .hidden = nm.len > 0 and nm[0] == '.',
    };
    if (linux.errno(linux.statx(dirfd, zname, linux.AT.SYMLINK_NOFOLLOW, mask, &st)) != .SUCCESS) return e;
    if (st.mode & linux.S.IFMT == linux.S.IFLNK) {
        e.link = true;
        // The target, if there is one; a dangling link stays "other".
        var target: linux.Statx = undefined;
        if (linux.errno(linux.statx(dirfd, zname, 0, mask, &target)) == .SUCCESS) st = target;
    }
    e.size = st.size;
    e.mtime = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
    e.mode = st.mode;
    e.kind = switch (st.mode & linux.S.IFMT) {
        linux.S.IFDIR => .dir,
        linux.S.IFREG => .file,
        else => .other,
    };
    if (e.kind == .dir) e.size = 0;
    return e;
}

/// Whether siv decodes the file for a thumbnail.
pub fn thumbnailable(nm: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse return false;
    var ext_buf: [8]u8 = undefined;
    const ext_raw = nm[dot + 1 ..];
    if (ext_raw.len > ext_buf.len) return false;
    const ext = std.ascii.lowerString(&ext_buf, ext_raw);
    for ([_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "avif", "jxl", "svg" }) |x| if (std.mem.eql(u8, ext, x)) return true;
    return false;
}

// Sorting ---------------------------------------------------------------------

pub const SortKey = enum(u8) { name, size, modified, type, extension };

pub const Sort = struct {
    key: SortKey = .name,
    descending: bool = false,
    /// Folders before files whatever the order, as file managers do.
    folders_first: bool = true,
};

/// Fills `order` with every entry's index, sorted. `db` names types for
/// sorting by type (comments must be cached: see warmComments).
pub fn sort(l: *const Listing, order: []u32, s: Sort, db: ?*mime.Db) void {
    std.debug.assert(order.len == l.entries.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    sortIndices(l, order, s, db);
}

/// Sorts the given indices of `l`.
pub fn sortIndices(l: *const Listing, order: []u32, s: Sort, db: ?*mime.Db) void {
    std.mem.sort(u32, order, Ctx{ .l = l, .s = s, .db = db }, Ctx.less);
}

const Ctx = struct {
    l: *const Listing,
    s: Sort,
    db: ?*mime.Db,

    fn typeName(ctx: Ctx, e: Entry) []const u8 {
        const db = ctx.db orelse return "";
        return db.cachedComment(e.mime) orelse db.name(e.mime);
    }

    fn less(ctx: Ctx, a: u32, b: u32) bool {
        const ea = ctx.l.entries[a];
        const eb = ctx.l.entries[b];
        if (ctx.s.folders_first) {
            const da = ea.kind == .dir;
            const db = eb.kind == .dir;
            if (da != db) return da;
        }
        var ord: std.math.Order = switch (ctx.s.key) {
            .name => .eq,
            .size => std.math.order(ea.size, eb.size),
            .modified => std.math.order(ea.mtime, eb.mtime),
            .type => if (ea.mime == eb.mime) .eq else std.mem.order(u8, ctx.typeName(ea), ctx.typeName(eb)),
            .extension => naturalOrder(extension(ctx.l.base(ea)), extension(ctx.l.base(eb))),
        };
        if (ord == .eq) ord = naturalOrder(ctx.l.base(ea), ctx.l.base(eb));
        if (ord == .eq) ord = naturalOrder(ctx.l.name(ea), ctx.l.name(eb));
        if (ord == .eq) ord = std.math.order(a, b);
        return if (ctx.s.descending) ord == .gt else ord == .lt;
    }
};

/// The extension of a name without its dot, "" for none (and for names
/// that only start with a dot).
pub fn extension(nm: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse return "";
    return if (dot == 0) "" else nm[dot + 1 ..];
}

/// Compares names as people read them: case-insensitively (ASCII), with
/// runs of digits compared as numbers, so "file2" sorts before "file10".
/// A leading dot is ignored, so ".config" sorts among the c's.
pub fn naturalOrder(a_in: []const u8, b_in: []const u8) std.math.Order {
    const a = if (a_in.len > 1 and a_in[0] == '.') a_in[1..] else a_in;
    const b = if (b_in.len > 1 and b_in[0] == '.') b_in[1..] else b_in;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            // Compare without leading zeros: longer is larger, then digits.
            const na = std.mem.trimStart(u8, a[i..ie], "0");
            const nb = std.mem.trimStart(u8, b[j..je], "0");
            if (na.len != nb.len) return std.math.order(na.len, nb.len);
            const o = std.mem.order(u8, na, nb);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    const o = std.math.order(a.len - i, b.len - j);
    if (o != .eq) return o;
    // Equal ignoring case: a stable tiebreak on the bytes.
    return std.mem.order(u8, a_in, b_in);
}

// Filtering -------------------------------------------------------------------

/// Copies the indices of `order` whose entries match into `out` and
/// returns how many: hidden entries only with `show_hidden`, and with a
/// query, names containing it case-insensitively.
pub fn filter(l: *const Listing, order: []const u32, out: []u32, query: []const u8, show_hidden: bool) usize {
    var n: usize = 0;
    for (order) |i| {
        const e = l.entries[i];
        if (e.hidden and !show_hidden) continue;
        if (query.len != 0 and !matches(l.base(e), query)) continue;
        out[n] = i;
        n += 1;
    }
    return n;
}

/// Whether `name` contains every space-separated word of `query`: in
/// smart case, as / searches, so a word with a capital letter matches its
/// case exactly and others ignore ASCII case.
pub fn matches(nm: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |word| {
        const exact = for (word) |ch| {
            if (std.ascii.isUpper(ch)) break true;
        } else false;
        const found = if (exact) std.mem.indexOf(u8, nm, word) != null else std.ascii.findIgnoreCase(nm, word) != null;
        if (!found) return false;
    }
    return true;
}

// Formatting ------------------------------------------------------------------

/// "1.2 MB" (decimal units, as GNOME and the SI do), "512 bytes".
pub fn formatSize(buf: []u8, size: u64) []const u8 {
    if (size < 1000) return std.fmt.bufPrint(buf, "{d} {s}", .{ size, if (size == 1) "byte" else "bytes" }) catch buf[0..0];
    const units = [_][]const u8{ "kB", "MB", "GB", "TB", "PB" };
    var v: f64 = @floatFromInt(size);
    var u: usize = 0;
    v /= 1000;
    while (v >= 1000 and u + 1 < units.len) : (u += 1) v /= 1000;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch buf[0..0];
}

/// "2026-10-13 14:05" in UTC offset `tz_offset_s` (local time comes from
/// the caller, which reads it from libc once).
pub fn formatTime(buf: []u8, mtime_ns: i64, tz_offset_s: i64) []const u8 {
    const secs = @divFloor(mtime_ns, std.time.ns_per_s) + tz_offset_s;
    if (secs < 0) return std.fmt.bufPrint(buf, "—", .{}) catch buf[0..0];
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch buf[0..0];
}

/// "rwxr-xr-x" for permission bits.
pub fn formatMode(buf: *[9]u8, mode: u32) []const u8 {
    const chars = "rwxrwxrwx";
    for (0..9) |i| buf[i] = if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) chars[i] else '-';
    return buf;
}

// Paths -----------------------------------------------------------------------

/// `dir` joined with `name`.
pub fn join(buf: []u8, dir: []const u8, nm: []const u8) ?[]u8 {
    const sep: []const u8 = if (dir.len > 0 and dir[dir.len - 1] == '/') "" else "/";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ dir, sep, nm }) catch null;
}

/// The parent of an absolute path; "/" is its own parent.
pub fn parent(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (i == 0) "/" else path[0..i];
}

/// The last component; "/" for the root.
pub fn basename(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// Whether `path` is `dir` or inside it.
pub fn isWithin(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return true;
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/');
}

/// Whether `name` can be a file name: not empty, ".", or "..", without
/// slashes or NULs, at most 255 bytes.
pub fn validName(nm: []const u8) bool {
    if (nm.len == 0 or nm.len > 255) return false;
    if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) return false;
    return std.mem.indexOfAny(u8, nm, "/\x00") == null;
}

/// Collapses "//", "/./", and "/x/../" and drops a trailing slash.
pub fn normalize(buf: []u8, path: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            while (n > 0 and buf[n - 1] != '/') n -= 1;
            if (n > 0) n -= 1;
            continue;
        }
        if (n + 1 + part.len > buf.len) break;
        buf[n] = '/';
        @memcpy(buf[n + 1 ..][0..part.len], part);
        n += 1 + part.len;
    }
    if (n == 0) {
        buf[0] = '/';
        n = 1;
    }
    return buf[0..n];
}

const testing = std.testing;

test "natural order" {
    try testing.expectEqual(.lt, naturalOrder("file2", "file10"));
    try testing.expectEqual(.gt, naturalOrder("file10", "file9"));
    try testing.expectEqual(.lt, naturalOrder("apple", "Banana"));
    try testing.expectEqual(.lt, naturalOrder("a", "ab"));
    try testing.expectEqual(.lt, naturalOrder(".bashrc", "config"));
    try testing.expectEqual(.lt, naturalOrder("x007", "x8"));
    try testing.expect(naturalOrder("Readme", "readme") != .eq);
}

test "matching words" {
    try testing.expect(matches("Holiday Photo 2024.jpg", "photo 24"));
    try testing.expect(!matches("Holiday Photo 2024.jpg", "photo 25"));
    try testing.expect(matches("anything", ""));
    try testing.expect(matches("README.md", "read"));
    try testing.expect(!matches("README.md", "Read"));
    try testing.expect(matches("Holiday Photo.jpg", "Photo jpg"));
}

test "sizes, times, and modes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1 byte", formatSize(&buf, 1));
    try testing.expectEqualStrings("999 bytes", formatSize(&buf, 999));
    try testing.expectEqualStrings("1.5 kB", formatSize(&buf, 1500));
    try testing.expectEqualStrings("2.0 GB", formatSize(&buf, 2_000_000_000));
    try testing.expectEqualStrings("2026-10-13 14:05", formatTime(&buf, 1_791_900_300 * std.time.ns_per_s, 0));
    var mb: [9]u8 = undefined;
    try testing.expectEqualStrings("rwxr-x--x", formatMode(&mb, 0o751));
}

test "paths" {
    try testing.expectEqualStrings("/", parent("/home"));
    try testing.expectEqualStrings("/home", parent("/home/user"));
    try testing.expectEqualStrings("user", basename("/home/user"));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/a", join(&buf, "/", "a").?);
    try testing.expectEqualStrings("/x/a", join(&buf, "/x", "a").?);
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName(".."));
    try testing.expect(validName("..a"));
    try testing.expectEqualStrings("/a/c", normalize(&buf, "//a/./b/../c/"));
    try testing.expect(isWithin("/a/b", "/a"));
    try testing.expect(!isWithin("/ab", "/a"));
}

test "relative names" {
    var b: Builder = .{ .gpa = testing.allocator };
    const e: Entry = .{ .name_off = 0, .name_len = 0, .size = 1, .mtime = 0, .mode = 0, .kind = .file, .link = false, .hidden = false };
    try b.add("sub/dir/file.txt", e);
    try b.add("top", e);
    var l = try b.finish("/x");
    defer l.deinit();
    try testing.expectEqualStrings("file.txt", l.base(l.entries[0]));
    try testing.expectEqualStrings("sub/dir", l.dirOf(l.entries[0]));
    try testing.expectEqualStrings("", l.dirOf(l.entries[1]));
    var pb: [64]u8 = undefined;
    try testing.expectEqualStrings("/x/sub/dir/file.txt", l.pathOf(&pb, l.entries[0]).?);
}
