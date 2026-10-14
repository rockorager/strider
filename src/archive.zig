//! Archive listings for previews: ZIP (and its relatives: jar, epub,
//! docx, ...) from its central directory, tar plain or gzipped by walking
//! its headers, and every other format libarchive's bsdtar reads, when
//! it is installed (on Arch it always is: pacman needs it). Blocking: runs
//! on a worker thread.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const proc = @import("proc.zig");

pub const Entry = struct { name: []const u8, size: u64, dir: bool };

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    /// There were more entries than the limit, or the archive ended early.
    truncated: bool = false,

    pub fn deinit(l: *Listing) void {
        l.arena.deinit();
    }
};

pub const Kind = enum { zip, tar, tar_gz, other };

const zip_exts = [_][]const u8{ ".zip", ".jar", ".apk", ".epub", ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".whl", ".xpi", ".cbz", ".vsix", ".aar" };
const other_exts = [_][]const u8{ ".tar.xz", ".txz", ".tar.zst", ".tzst", ".tar.bz2", ".tbz2", ".tbz", ".7z", ".rar", ".cbr", ".iso", ".xz", ".bz2", ".zst", ".lz", ".lzma", ".cpio", ".deb", ".rpm", ".cab", ".pkg.tar.zst", ".tar.lz", ".tar.lzma" };

/// The kind of archive a file name says, if any.
pub fn kindOf(name: []const u8) ?Kind {
    var buf: [256]u8 = undefined;
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, name);
    for (zip_exts) |e| if (std.mem.endsWith(u8, lower, e)) return .zip;
    if (std.mem.endsWith(u8, lower, ".tar.gz") or std.mem.endsWith(u8, lower, ".tgz")) return .tar_gz;
    if (std.mem.endsWith(u8, lower, ".tar")) return .tar;
    for (other_exts) |e| if (std.mem.endsWith(u8, lower, e)) return .other;
    return null;
}

/// Lists up to `limit` entries of the archive at `path`.
pub fn list(gpa: Allocator, path: []const u8, kind: Kind, limit: usize) !Listing {
    var l: Listing = .{ .arena = .init(gpa), .entries = &.{} };
    errdefer l.arena.deinit();
    const a = l.arena.allocator();
    var out: std.ArrayList(Entry) = .empty;
    switch (kind) {
        .zip => try listZip(a, path, &out, limit, &l.truncated),
        .tar => try listTarFile(a, path, &out, limit, &l.truncated, false),
        .tar_gz => try listTarFile(a, path, &out, limit, &l.truncated, true),
        .other => try listBsdtar(a, gpa, path, &out, limit, &l.truncated),
    }
    l.entries = try out.toOwnedSlice(a);
    return l;
}

fn openFile(path: []const u8) !i32 {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return error.NameTooLong;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
    return @intCast(rc);
}

fn pread(fd: i32, buf: []u8, off: u64) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = linux.pread(fd, buf[got..].ptr, buf.len - got, @intCast(off + got));
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        got += n;
    }
    return got;
}

fn fileSize(fd: i32) u64 {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS) return 0;
    return st.size;
}

fn le16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}
fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn listZip(a: Allocator, path: []const u8, out: *std.ArrayList(Entry), limit: usize, truncated: *bool) !void {
    const fd = try openFile(path);
    defer _ = linux.close(fd);
    const size = fileSize(fd);
    if (size < 22) return error.InvalidArchive;
    // The end of central directory record is in the last 64 KiB + 22.
    const tail_len: usize = @intCast(@min(size, 65_557));
    const tail = try a.alloc(u8, tail_len);
    if (pread(fd, tail, size - tail_len) != tail_len) return error.InvalidArchive;
    var i: usize = tail_len - 22;
    const eocd = while (true) : (i -= 1) {
        if (le32(tail[i..]) == 0x06054b50) break i;
        if (i == 0) return error.InvalidArchive;
    };
    const count = le16(tail[eocd + 10 ..]);
    const cd_size = le32(tail[eocd + 12 ..]);
    const cd_off = le32(tail[eocd + 16 ..]);
    if (@as(u64, cd_off) + cd_size > size) return error.InvalidArchive;
    const cd = try a.alloc(u8, cd_size);
    if (pread(fd, cd, cd_off) != cd_size) return error.InvalidArchive;
    var p: usize = 0;
    var n: usize = 0;
    while (n < count and p + 46 <= cd.len) : (n += 1) {
        if (le32(cd[p..]) != 0x02014b50) break;
        const usize_ = le32(cd[p + 24 ..]);
        const name_len = le16(cd[p + 28 ..]);
        const extra_len = le16(cd[p + 30 ..]);
        const comment_len = le16(cd[p + 32 ..]);
        if (p + 46 + name_len > cd.len) break;
        const name = cd[p + 46 ..][0..name_len];
        if (out.items.len >= limit) {
            truncated.* = true;
            break;
        }
        const dir = name.len > 0 and name[name.len - 1] == '/';
        try out.append(a, .{ .name = if (dir) name[0 .. name.len - 1] else name, .size = usize_, .dir = dir });
        p += 46 + name_len + extra_len + comment_len;
    }
}

/// Reads at most this much of a tarball to list it.
const max_tar_read = 64 << 20;

fn listTarFile(a: Allocator, path: []const u8, out: *std.ArrayList(Entry), limit: usize, truncated: *bool, gz: bool) !void {
    const fd = try openFile(path);
    defer _ = linux.close(fd);
    const size = fileSize(fd);
    const len: usize = @intCast(@min(size, max_tar_read));
    const data = try a.alloc(u8, len);
    const got = pread(fd, data, 0);
    if (got < len) return error.InvalidArchive;
    if (size > max_tar_read) truncated.* = true;
    var input: std.Io.Reader = .fixed(data);
    if (gz) {
        const window = try a.alloc(u8, std.compress.flate.max_window_len);
        var dec: std.compress.flate.Decompress = .init(&input, .gzip, window);
        try walkTar(a, &dec.reader, out, limit, truncated);
    } else {
        try walkTar(a, &input, out, limit, truncated);
    }
}

fn octal(field: []const u8) u64 {
    var v: u64 = 0;
    // Base-256 for large sizes (GNU).
    if (field.len > 0 and field[0] & 0x80 != 0) {
        for (field[1..]) |b| v = (v << 8) | b;
        return v;
    }
    for (field) |ch| {
        if (ch == 0 or ch == ' ') {
            if (v != 0) break else continue;
        }
        if (ch < '0' or ch > '7') break;
        v = v * 8 + (ch - '0');
    }
    return v;
}

fn walkTar(a: Allocator, r: *std.Io.Reader, out: *std.ArrayList(Entry), limit: usize, truncated: *bool) !void {
    var hdr: [512]u8 = undefined;
    var long_name: ?[]u8 = null;
    while (true) {
        const n = r.readSliceShort(&hdr) catch {
            truncated.* = true;
            return;
        };
        if (n < 512) {
            if (n != 0) truncated.* = true;
            return;
        }
        if (std.mem.allEqual(u8, &hdr, 0)) return;
        const size = octal(hdr[124..136]);
        const typeflag = hdr[156];
        const padded = (size + 511) / 512 * 512;
        if (typeflag == 'L' or typeflag == 'x' or typeflag == 'g') {
            // A GNU long name, or pax headers (whose path= we read).
            const body = try a.alloc(u8, @intCast(@min(size, 1 << 20)));
            const got = r.readSliceShort(body) catch 0;
            _ = r.discardShort(@intCast(padded - got)) catch {};
            if (typeflag == 'L') {
                long_name = std.mem.sliceTo(body[0..got], 0);
            } else if (typeflag == 'x') {
                var it = std.mem.splitScalar(u8, body[0..got], '\n');
                while (it.next()) |rec| if (std.mem.indexOf(u8, rec, " path=")) |k| {
                    long_name = @constCast(rec[k + 6 ..]);
                };
            }
            continue;
        }
        var name: []const u8 = undefined;
        if (long_name) |ln| {
            name = ln;
            long_name = null;
        } else {
            const base = std.mem.sliceTo(hdr[0..100], 0);
            const prefix = if (std.mem.eql(u8, hdr[257..262], "ustar")) std.mem.sliceTo(hdr[345..500], 0) else "";
            name = if (prefix.len != 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, base }) else try a.dupe(u8, base);
        }
        const dir = typeflag == '5' or (name.len > 0 and name[name.len - 1] == '/');
        if (name.len > 1 and name[name.len - 1] == '/') name = name[0 .. name.len - 1];
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (name.len != 0 and !std.mem.eql(u8, name, ".")) {
            if (out.items.len >= limit) {
                truncated.* = true;
                return;
            }
            try out.append(a, .{ .name = name, .size = if (dir) 0 else size, .dir = dir });
        }
        if (padded != 0) {
            const skipped = r.discardShort(@intCast(padded)) catch {
                truncated.* = true;
                return;
            };
            if (skipped < padded) {
                truncated.* = true;
                return;
            }
        }
    }
}

fn listBsdtar(a: Allocator, gpa: Allocator, path: []const u8, out: *std.ArrayList(Entry), limit: usize, truncated: *bool) !void {
    if (!proc.onPath("bsdtar")) return error.Unsupported;
    var r = try proc.run(gpa, &.{ "bsdtar", "-tf", path }, .{ .max_output = 1 << 20, .kill_after = 4 << 20 });
    defer r.deinit(gpa);
    if (r.status != 0 and r.output.len == 0) return error.InvalidArchive;
    if (r.truncated) truncated.* = true;
    var it = std.mem.splitScalar(u8, r.output, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "bsdtar: ")) continue;
        if (out.items.len >= limit) {
            truncated.* = true;
            break;
        }
        const dir = line[line.len - 1] == '/';
        const name = try a.dupe(u8, if (dir) line[0 .. line.len - 1] else line);
        try out.append(a, .{ .name = name, .size = 0, .dir = dir });
    }
}

const testing = std.testing;

test "archive kinds by name" {
    try testing.expectEqual(Kind.zip, kindOf("book.EPUB").?);
    try testing.expectEqual(Kind.tar_gz, kindOf("src.tar.gz").?);
    try testing.expectEqual(Kind.tar, kindOf("a.tar").?);
    try testing.expectEqual(Kind.other, kindOf("pkg.tar.zst").?);
    try testing.expect(kindOf("notes.txt") == null);
}

test "lists a zip and a tarball made by the system's tools" {
    if (!proc.onPath("tar") or !proc.onPath("gzip")) return error.SkipZigTest;
    var r = try proc.run(testing.allocator, &.{ "sh", "-c",
        \\set -e
        \\rm -rf /tmp/strider-archive-test && mkdir -p /tmp/strider-archive-test/src/sub
        \\cd /tmp/strider-archive-test
        \\printf 'hello' > src/a.txt
        \\printf 'x' > src/sub/b.txt
        \\tar -czf t.tar.gz src
        \\tar -cf t.tar src
    }, .{});
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), r.status);
    defer {
        var rm = proc.run(testing.allocator, &.{ "rm", "-rf", "/tmp/strider-archive-test" }, .{}) catch unreachable;
        rm.deinit(testing.allocator);
    }
    for ([_]struct { []const u8, Kind }{ .{ "/tmp/strider-archive-test/t.tar.gz", .tar_gz }, .{ "/tmp/strider-archive-test/t.tar", .tar } }) |t| {
        var l = try list(testing.allocator, t[0], t[1], 100);
        defer l.deinit();
        var found_a = false;
        var found_sub = false;
        for (l.entries) |e| {
            if (std.mem.eql(u8, e.name, "src/a.txt")) {
                found_a = true;
                try testing.expectEqual(@as(u64, 5), e.size);
            }
            if (std.mem.eql(u8, e.name, "src/sub") and e.dir) found_sub = true;
        }
        try testing.expect(found_a and found_sub);
        try testing.expect(!l.truncated);
    }
}
