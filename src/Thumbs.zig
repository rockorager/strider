//! Thumbnails other applications saved in the freedesktop.org thumbnail
//! cache ($XDG_CACHE_HOME/thumbnails, named by the MD5 of the file's URI),
//! for previews of files siv cannot decode itself, such as videos.

const std = @import("std");
const linux = std.os.linux;
const uri = @import("uri.zig");

/// The newest-fitting cached thumbnail of `path` that is newer than the
/// file (modified at `mtime` nanoseconds), largest first, in `out`.
pub fn cachedPath(gpa: std.mem.Allocator, cache_dir: []const u8, path: []const u8, mtime: i64, out: []u8) ?[:0]u8 {
    if (cache_dir.len == 0) return null;
    var ubuf: std.ArrayList(u8) = .empty;
    defer ubuf.deinit(gpa);
    uri.appendFileUri(&ubuf, gpa, path) catch return null;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(ubuf.items, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    for ([_][]const u8{ "xx-large", "x-large", "large", "normal" }) |kind| {
        const tp = std.fmt.bufPrintSentinel(out, "{s}/{s}/{s}.png", .{ cache_dir, kind, hex }, 0) catch return null;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, tp, 0, .{ .MTIME = true }, &st)) != .SUCCESS) continue;
        const tm = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
        if (tm >= mtime) return tp;
    }
    return null;
}
