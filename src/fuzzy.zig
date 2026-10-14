//! Fuzzy finding: the paths below a folder, walked on a worker, and a
//! score for a path against a query in the spirit of fzf: every character
//! of each space-separated word in order, in the tightest window that
//! holds them, with bonuses for matches at word starts, after slashes,
//! in runs, and in the base name, and a cost for gaps. Smart case, as the
//! rest of the program: a capital letter makes the query exact.
//!
//! Plain Zig without siv, so the tests reach every part.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// Paths in one buffer: path i is bytes[offs[i]..offs[i + 1]].
pub const Paths = struct {
    bytes: std.ArrayList(u8) = .empty,
    offs: std.ArrayList(u32) = .empty,

    pub fn deinit(p: *Paths, gpa: Allocator) void {
        p.bytes.deinit(gpa);
        p.offs.deinit(gpa);
    }

    pub fn len(p: *const Paths) usize {
        return if (p.offs.items.len == 0) 0 else p.offs.items.len - 1;
    }

    pub fn get(p: *const Paths, i: usize) []const u8 {
        return p.bytes.items[p.offs.items[i]..p.offs.items[i + 1]];
    }

    pub fn append(p: *Paths, gpa: Allocator, path: []const u8) !void {
        if (p.offs.items.len == 0) try p.offs.append(gpa, 0);
        try p.bytes.appendSlice(gpa, path);
        try p.offs.append(gpa, @intCast(p.bytes.items.len));
    }

    /// Moves every path of `other` to the end (other is emptied).
    pub fn take(p: *Paths, gpa: Allocator, other: *Paths) !void {
        for (0..other.len()) |i| try p.append(gpa, other.get(i));
        other.bytes.clearRetainingCapacity();
        other.offs.clearRetainingCapacity();
    }
};

// Scoring ------------------------------------------------------------------

const score_match = 16;
const bonus_boundary = 8;
const bonus_slash = 10;
const bonus_camel = 7;
const bonus_run = 6;
const bonus_base = 12;
const penalty_gap_start = 3;
const penalty_gap = 1;

/// The most positions `score` reports.
pub const max_positions = 64;

fn lower(ch: u8) u8 {
    return std.ascii.toLower(ch);
}

fn eq(a: u8, b: u8, exact: bool) bool {
    return if (exact) a == b else lower(a) == lower(b);
}

fn boundaryBonus(text: []const u8, i: usize) i32 {
    if (i == 0) return bonus_slash;
    const prev = text[i - 1];
    if (prev == '/') return bonus_slash;
    if (prev == '_' or prev == '-' or prev == '.' or prev == ' ') return bonus_boundary;
    if (std.ascii.isLower(prev) and std.ascii.isUpper(text[i])) return bonus_camel;
    if (!std.ascii.isAlphanumeric(prev) and std.ascii.isAlphanumeric(text[i])) return bonus_boundary;
    return 0;
}

/// One word against `text`: null if its characters are not all there in
/// order. Positions go to `pos` (as many as fit).
fn scoreWord(text: []const u8, word: []const u8, exact: bool, pos: *std.ArrayList(u16), gpa: ?Allocator) ?i32 {
    if (word.len == 0) return 0;
    // The first place the whole word fits, scanning forward...
    var j: usize = 0;
    var end: usize = 0;
    for (text, 0..) |ch, i| {
        if (eq(ch, word[j], exact)) {
            j += 1;
            if (j == word.len) {
                end = i;
                break;
            }
        }
    } else return null;
    // ...then back from its end, for the tightest window.
    var start = end;
    var k: usize = word.len;
    var i: usize = end + 1;
    while (i > 0) {
        i -= 1;
        if (eq(text[i], word[k - 1], exact)) {
            k -= 1;
            if (k == 0) {
                start = i;
                break;
            }
        }
    }
    const base_at = if (std.mem.lastIndexOfScalar(u8, text[0 .. text.len - @intFromBool(text.len > 0 and text[text.len - 1] == '/')], '/')) |s| s + 1 else 0;
    var total: i32 = 0;
    var prev: ?usize = null;
    var w: usize = 0;
    var t = start;
    while (t <= end and w < word.len) : (t += 1) {
        if (!eq(text[t], word[w], exact)) continue;
        total += score_match + boundaryBonus(text, t);
        if (prev) |p| {
            if (p + 1 == t) total += bonus_run else total -= penalty_gap_start + penalty_gap * @as(i32, @intCast(@min(t - p - 2, 20)));
        }
        if (gpa) |a| if (pos.items.len < max_positions) pos.append(a, @intCast(t)) catch {};
        prev = t;
        w += 1;
    }
    if (start >= base_at) total += bonus_base;
    return total;
}

/// `query`'s score for `text`, or null if a word does not match. With
/// `pos`, the matched byte offsets (for highlighting) are added to it.
pub fn score(text: []const u8, query: []const u8, pos: ?*std.ArrayList(u16), gpa: ?Allocator) ?i32 {
    const exact = for (query) |ch| {
        if (std.ascii.isUpper(ch)) break true;
    } else false;
    var dummy: std.ArrayList(u16) = .empty;
    const out = pos orelse &dummy;
    var total: i32 = 0;
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |word| total += scoreWord(text, word, exact, out, if (pos != null) gpa else null) orelse return null;
    return total;
}

pub const Match = struct { index: u32, score: i32 };

/// Scores `candidates` (all of `paths`, or the indices given, which must
/// not be `out`'s) against `query` into `out`, best first; shorter paths win ties, then earlier
/// ones (the walk is breadth first, so shallower ones).
pub fn filter(gpa: Allocator, paths: *const Paths, candidates: ?[]const Match, query: []const u8, out: *std.ArrayList(Match)) !void {
    out.clearRetainingCapacity();
    if (candidates) |cs| {
        for (cs) |m| if (score(paths.get(m.index), query, null, null)) |s| try out.append(gpa, .{ .index = m.index, .score = s });
    } else {
        for (0..paths.len()) |i| if (score(paths.get(i), query, null, null)) |s| try out.append(gpa, .{ .index = @intCast(i), .score = s });
    }
    if (query.len == 0) return; // as listed
    const Ctx = struct {
        paths: *const Paths,
        fn less(ctx: @This(), a: Match, b: Match) bool {
            if (a.score != b.score) return a.score > b.score;
            const la = ctx.paths.get(a.index).len;
            const lb = ctx.paths.get(b.index).len;
            if (la != lb) return la < lb;
            return a.index < b.index;
        }
    };
    std.sort.pdq(Match, out.items, Ctx{ .paths = paths }, Ctx.less);
}

// Walking ------------------------------------------------------------------

/// Walks `root` breadth first on a worker, handing paths (relative to the
/// root; folders end in "/") to `sink` in batches. Skips .git, and hidden
/// entries unless `hidden`; does not follow links into folders; stops at
/// `limit` paths or when `cancel` is set.
pub const Walk = struct {
    gpa: Allocator,
    root: []const u8,
    hidden: bool,
    limit: usize = 200_000,
    cancel: *const std.atomic.Value(bool),
    /// Takes a batch (it owns it from then on); `done` on the last.
    sink: *const fn (ctx: ?*anyopaque, batch: *Paths, done: bool) void,
    ctx: ?*anyopaque,
    batch_size: usize = 4096,

    pub fn run(w: *const Walk) void {
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var queue: std.ArrayList([]const u8) = .empty;
        queue.append(arena, "") catch return w.finish(null);
        var head: usize = 0;
        var count: usize = 0;
        var batch: ?*Paths = null;
        var buf: [8192]u8 align(8) = undefined;
        outer: while (head < queue.items.len) : (head += 1) {
            const rel = queue.items[head];
            var pb: [linux.PATH_MAX]u8 = undefined;
            const abs = std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ w.root, rel }, 0) catch continue;
            const rc = linux.openat(linux.AT.FDCWD, abs, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(rc);
            defer _ = linux.close(fd);
            while (true) {
                if (w.cancel.load(.acquire)) break :outer;
                const n = linux.getdents64(fd, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                var off: usize = 0;
                while (off < n) {
                    const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
                    off += d.reclen;
                    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.name)), 0);
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                    if (std.mem.eql(u8, name, ".git")) continue;
                    if (!w.hidden and name[0] == '.') continue;
                    var dir = d.type == linux.DT.DIR;
                    if (d.type == linux.DT.UNKNOWN) {
                        var st: linux.Statx = undefined;
                        var zb: [256]u8 = undefined;
                        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{name}, 0) catch continue;
                        if (linux.errno(linux.statx(fd, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS)
                            dir = st.mode & linux.S.IFMT == linux.S.IFDIR;
                    }
                    var rb: [linux.PATH_MAX]u8 = undefined;
                    const child = std.fmt.bufPrint(&rb, "{s}{s}{s}", .{ rel, name, if (dir) "/" else "" }) catch continue;
                    if (dir) queue.append(arena, arena.dupe(u8, child) catch continue) catch continue;
                    if (batch == null) {
                        batch = w.gpa.create(Paths) catch break :outer;
                        batch.?.* = .{};
                    }
                    batch.?.append(w.gpa, child) catch break :outer;
                    count += 1;
                    if (count >= w.limit) break :outer;
                    if (batch.?.len() >= w.batch_size) {
                        w.sink(w.ctx, batch.?, false);
                        batch = null;
                    }
                }
            }
        }
        w.finish(batch);
    }

    fn finish(w: *const Walk, batch: ?*Paths) void {
        const b = batch orelse blk: {
            const nb = w.gpa.create(Paths) catch return;
            nb.* = .{};
            break :blk nb;
        };
        w.sink(w.ctx, b, true);
    }
};

// Tests --------------------------------------------------------------------

const testing = std.testing;

test "every word's characters in order, in smart case" {
    try testing.expect(score("src/main.zig", "mz", null, null) != null);
    try testing.expect(score("src/main.zig", "zm", null, null) == null);
    try testing.expect(score("src/main.zig", "main src", null, null) != null);
    try testing.expect(score("src/main.zig", "main docs", null, null) == null);
    try testing.expect(score("README.md", "readme", null, null) != null);
    try testing.expect(score("README.md", "Readme", null, null) == null);
    try testing.expect(score("anything", "", null, null).? == 0);
}

test "word starts, runs, and the base name rank first" {
    const T = struct {
        fn better(a: []const u8, b: []const u8, q: []const u8) !void {
            const sa = score(a, q, null, null).?;
            const sb = score(b, q, null, null).?;
            if (sa <= sb) {
                std.debug.print("{s} ({d}) should beat {s} ({d}) for {s}\n", .{ a, sa, b, sb, q });
                return error.TestExpectedBetter;
            }
        }
    };
    // A run beats scattered letters.
    try T.better("src/main.zig", "src/my_animal_index.zig", "main");
    // The base name beats a folder on the way.
    try T.better("docs/notes/main.txt", "main/docs/notes.txt", "main");
    // A word start beats the middle of a word.
    try T.better("src/file_view.zig", "src/fileview.zig", "fv");
    // camelCase starts count.
    try T.better("src/FileView.zig", "src/fileview.zig", "fv");
    // Tight beats spread out.
    try T.better("a/build.zig", "b/u/i/l/d.zig", "build");
}

test "positions for highlighting" {
    var pos: std.ArrayList(u16) = .empty;
    defer pos.deinit(testing.allocator);
    _ = score("src/main.zig", "mz", &pos, testing.allocator).?;
    try testing.expectEqualSlices(u16, &.{ 4, 9 }, pos.items);
}

test "filter ranks, breaks ties by length, and narrows a previous result" {
    const gpa = testing.allocator;
    var paths: Paths = .{};
    defer paths.deinit(gpa);
    for ([_][]const u8{ "docs/", "src/", "src/util/", "src/main.zig", "src/util/strings.zig", "docs/manual.md", "README.md" }) |p| try paths.append(gpa, p);
    var out: std.ArrayList(Match) = .empty;
    defer out.deinit(gpa);
    try filter(gpa, &paths, null, "", &out);
    try testing.expectEqual(@as(usize, 7), out.items.len);
    try filter(gpa, &paths, null, "ma", &out);
    try testing.expectEqualStrings("src/main.zig", paths.get(out.items[0].index));
    try testing.expectEqualStrings("docs/manual.md", paths.get(out.items[1].index));
    const prev = try gpa.dupe(Match, out.items);
    defer gpa.free(prev);
    try filter(gpa, &paths, prev, "man", &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // Now the run of three wins.
    try testing.expectEqualStrings("docs/manual.md", paths.get(out.items[0].index));
    const prev2 = try gpa.dupe(Match, out.items);
    defer gpa.free(prev2);
    try filter(gpa, &paths, prev2, "manu", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "walks breadth first, skipping .git and hidden entries, in batches" {
    const gpa = testing.allocator;
    var tmp_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&tmp_buf, "/tmp/siv-columns-fuzzy-{d}", .{linux.getpid()});
    var cmd: [512]u8 = undefined;
    const S = struct {
        extern "c" fn system(c: [*:0]const u8) c_int;
    };
    _ = S.system((try std.fmt.bufPrintSentinel(&cmd, "rm -rf {s} && mkdir -p {s}/a/b {s}/.git/objects {s}/.hidden && touch {s}/top {s}/a/mid {s}/a/b/deep {s}/.git/HEAD {s}/.hidden/x {s}/.dotfile", .{ root, root, root, root, root, root, root, root, root, root }, 0)).ptr);
    defer _ = S.system((std.fmt.bufPrintSentinel(&cmd, "rm -rf {s}", .{root}, 0) catch unreachable).ptr);
    const Sink = struct {
        all: Paths = .{},
        batches: usize = 0,
        done: bool = false,
        fn sink(ctx: ?*anyopaque, batch: *Paths, done: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.all.take(testing.allocator, batch) catch {};
            batch.deinit(testing.allocator);
            testing.allocator.destroy(batch);
            self.batches += 1;
            self.done = done;
        }
    };
    var cancel: std.atomic.Value(bool) = .init(false);
    for ([_]bool{ false, true }) |hidden| {
        var s: Sink = .{};
        defer s.all.deinit(gpa);
        const w: Walk = .{ .gpa = gpa, .root = root, .hidden = hidden, .cancel = &cancel, .sink = Sink.sink, .ctx = &s, .batch_size = 2 };
        w.run();
        try testing.expect(s.done);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        for (0..s.all.len()) |i| try names.append(gpa, s.all.get(i));
        // Breadth first: depth 1 before 2 before 3; within a folder the
        // directory's order, so sort each depth to compare.
        const want: []const []const u8 = if (hidden)
            &.{ ".dotfile", ".hidden/", "a/", "top", ".hidden/x", "a/b/", "a/mid", "a/b/deep" }
        else
            &.{ "a/", "top", "a/b/", "a/mid", "a/b/deep" };
        var depth_start: usize = 0;
        while (depth_start < names.items.len) {
            const d = std.mem.count(u8, std.mem.trimEnd(u8, names.items[depth_start], "/"), "/");
            var e = depth_start;
            while (e < names.items.len and std.mem.count(u8, std.mem.trimEnd(u8, names.items[e], "/"), "/") == d) e += 1;
            std.sort.pdq([]const u8, names.items[depth_start..e], {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            depth_start = e;
        }
        try testing.expectEqual(want.len, names.items.len);
        for (want, names.items) |a, b| try testing.expectEqualStrings(a, b);
        try testing.expect(s.batches >= 3);
    }
}
