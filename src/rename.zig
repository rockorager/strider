//! Batch rename: new names from find-and-replace or a template, and the
//! checks that keep a batch from colliding with itself or other files.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Mode = enum { replace, template };

pub const Spec = struct {
    mode: Mode,
    find: []const u8 = "",
    replace: []const u8 = "",
    /// [N] the name without its extension, [E] the extension, [#] the
    /// item's number from 1 ([###] pads it to three digits). Without [E],
    /// the extension stays.
    template: []const u8 = "",
};

/// The new name of the item at `index` (owned).
pub fn newName(gpa: Allocator, spec: Spec, name: []const u8, index: usize) ![]u8 {
    switch (spec.mode) {
        .replace => {
            if (spec.find.len == 0) return gpa.dupe(u8, name);
            return std.mem.replaceOwned(u8, gpa, name, spec.find, spec.replace);
        },
        .template => {
            const stem_len = stemLength(name);
            const stem = name[0..stem_len];
            const ext = name[stem_len..]; // with its dot
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            var used_ext = false;
            var i: usize = 0;
            const t = spec.template;
            while (i < t.len) {
                if (std.mem.startsWith(u8, t[i..], "[N]")) {
                    try out.appendSlice(gpa, stem);
                    i += 3;
                } else if (std.mem.startsWith(u8, t[i..], "[E]")) {
                    try out.appendSlice(gpa, if (ext.len > 0) ext[1..] else "");
                    used_ext = true;
                    i += 3;
                } else if (t[i] == '[' and i + 1 < t.len and t[i + 1] == '#') {
                    var j = i + 1;
                    while (j < t.len and t[j] == '#') j += 1;
                    if (j < t.len and t[j] == ']') {
                        var nb: [32]u8 = undefined;
                        const digits = std.fmt.bufPrint(&nb, "{d}", .{index + 1}) catch "";
                        const width = j - i - 1;
                        if (digits.len < width) try out.appendNTimes(gpa, '0', width - digits.len);
                        try out.appendSlice(gpa, digits);
                        i = j + 1;
                    } else {
                        try out.append(gpa, t[i]);
                        i += 1;
                    }
                } else {
                    try out.append(gpa, t[i]);
                    i += 1;
                }
            }
            if (!used_ext) try out.appendSlice(gpa, ext);
            return out.toOwnedSlice(gpa);
        },
    }
}

fn stemLength(nm: []const u8) usize {
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.') orelse return nm.len;
    if (dot == 0) return nm.len;
    if (std.mem.endsWith(u8, nm[0..dot], ".tar")) return dot - 4;
    return dot;
}

/// Why the batch cannot be applied, or null: an invalid name, two items
/// getting the same name, or a name another file in the folder has.
pub fn check(gpa: Allocator, paths: []const []const u8, new_names: []const []const u8) ?[]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var olds: std.StringHashMapUnmanaged(void) = .empty;
    defer olds.deinit(gpa);
    for (paths) |p| olds.put(gpa, model.basename(p), {}) catch return null;
    for (paths, new_names) |p, n| {
        if (!model.validName(n)) return "A new name is empty or has a “/”";
        const gop = seen.getOrPut(gpa, n) catch return null;
        if (gop.found_existing) return "Two items would get the same name";
        if (std.mem.eql(u8, n, model.basename(p))) continue;
        // Another file (not in the batch) has the name already.
        if (olds.contains(n)) continue;
        var buf: [linux.PATH_MAX]u8 = undefined;
        const target = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ model.parent(p), n }, 0) catch continue;
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, target, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS) return "A new name is taken by another file";
    }
    return null;
}

const testing = std.testing;

test "templates and replacing" {
    const gpa = testing.allocator;
    const a = try newName(gpa, .{ .mode = .template, .template = "Trip [###]" }, "IMG_0042.JPG", 6);
    defer gpa.free(a);
    try testing.expectEqualStrings("Trip 007.JPG", a);
    const b = try newName(gpa, .{ .mode = .template, .template = "[N]-[#].[E]" }, "notes.tar.gz", 0);
    defer gpa.free(b);
    try testing.expectEqualStrings("notes-1.tar.gz", b);
    const r = try newName(gpa, .{ .mode = .replace, .find = "_", .replace = " " }, "a_b_c.txt", 0);
    defer gpa.free(r);
    try testing.expectEqualStrings("a b c.txt", r);
}

test "batch checks" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("Two items would get the same name", check(gpa, &.{ "/nonexistent/a", "/nonexistent/b" }, &.{ "x", "x" }).?);
    try testing.expect(check(gpa, &.{ "/nonexistent/a", "/nonexistent/b" }, &.{ "b", "a" }) == null);
    try testing.expect(check(gpa, &.{"/nonexistent/a"}, &.{"a/b"}) != null);
}
