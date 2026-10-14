//! One directory as the columns show it: its listing (read on a worker
//! thread and sorted there), the entries shown after hiding dotfiles and
//! filtering, the cursor, and the marks. Directories live in a cache by
//! path (`Cache`), so going up, down, and back shows a folder at once
//! from memory while a fresh read, if one is due, runs behind it.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const model = @import("model.zig");
const mime = @import("mime.zig");
const trash = @import("trash.zig");

const Dir = @This();

cache: *Cache,
/// Absolute, normalized, without a trailing slash (except "/").
path: []u8,
listing: ?model.Listing = null,
/// The trash view: where each entry came from, parallel to entries.
trash_info: ?trash.Info = null,
err: ?model.ReadError = null,
/// Every entry's index, in `sorted_by` order.
order: std.ArrayList(u32) = .empty,
sorted_by: model.Sort = .{},
/// The entries shown, in order: the column's row i is entries[visible[i]].
visible: std.ArrayList(u32) = .empty,
/// What `visible` was filtered with.
shows_hidden: bool = false,
filter: std.ArrayList(u8) = .empty,
/// The cursor, as an index into `visible`, and the name it is on (or is
/// to be on, once a reload shows it), which survives reloads, sorting,
/// and filtering: every move of the cursor updates it.
cursor: u32 = 0,
cursor_name: std.ArrayList(u8) = .empty,
/// Marked entries, by entry index.
marks: std.DynamicBitSetUnmanaged = .{},
mark_count: u32 = 0,
/// The read in flight, if any.
loading: ?*Load = null,
/// A read finished at least once (successfully or not).
loaded: bool = false,
/// When the last read finished, in nanoseconds of CLOCK_MONOTONIC.
stamp: i64 = 0,
/// Columns and tabs showing it; pinned directories are not evicted.
pins: u32 = 0,
last_used: u64 = 0,

/// The cache of directories, shared by every window.
pub const Cache = struct {
    gpa: Allocator,
    sapp: siv.App,
    dirs: std.StringHashMapUnmanaged(*Dir) = .empty,
    tick: u64 = 0,
    /// The MIME database, for classifying and sorting by type; loaded by
    /// the first read (on a worker).
    load_mime: *const fn (ctx: ?*anyopaque) ?*mime.Db,
    /// Called on the UI thread when a directory's listing changed.
    on_loaded: *const fn (ctx: ?*anyopaque, dir: *Dir) void,
    ctx: ?*anyopaque,
    /// The home trash's files directory: its listing is every trash's.
    trash_files: []const u8 = "",
    trash_dir: []const u8 = "",
    sort: model.Sort = .{},
    show_hidden: bool = false,
    /// How many unpinned directories to keep.
    max_cached: usize = 64,

    pub fn deinit(cache: *Cache) void {
        var it = cache.dirs.valueIterator();
        while (it.next()) |d| d.*.destroy();
        cache.dirs.deinit(cache.gpa);
    }

    /// The directory at `path` (normalized), made and read if it is not
    /// cached. A cached one is re-read when it is older than `max_age_ms`
    /// (and not being read); 0 never re-reads.
    pub fn get(cache: *Cache, path_in: []const u8, max_age_ms: u32) ?*Dir {
        var nbuf: [linux.PATH_MAX]u8 = undefined;
        const path = model.normalize(&nbuf, path_in);
        cache.tick += 1;
        if (cache.dirs.get(path)) |d| {
            d.last_used = cache.tick;
            if (d.loading == null and (!d.loaded or (max_age_ms != 0 and now() - d.stamp > @as(i64, max_age_ms) * std.time.ns_per_ms))) d.reload();
            return d;
        }
        cache.evict();
        const d = cache.gpa.create(Dir) catch return null;
        const owned = cache.gpa.dupe(u8, path) catch {
            cache.gpa.destroy(d);
            return null;
        };
        d.* = .{ .cache = cache, .path = owned, .last_used = cache.tick, .sorted_by = cache.sort, .shows_hidden = cache.show_hidden };
        cache.dirs.put(cache.gpa, d.path, d) catch {
            d.destroy();
            return null;
        };
        d.reload();
        return d;
    }

    /// The cached directory at `path`, without reading it.
    pub fn peek(cache: *Cache, path: []const u8) ?*Dir {
        return cache.dirs.get(path);
    }

    /// Re-reads the cached directory at `path`, if any.
    pub fn invalidate(cache: *Cache, path: []const u8) void {
        if (cache.dirs.get(path)) |d| {
            if (d.pins > 0) d.reload() else d.stamp = 0;
        }
    }

    /// Drops the least recently used unpinned directories beyond the
    /// limit.
    fn evict(cache: *Cache) void {
        while (cache.dirs.count() >= cache.max_cached) {
            var oldest: ?*Dir = null;
            var it = cache.dirs.valueIterator();
            while (it.next()) |d| {
                if (d.*.pins > 0) continue;
                if (oldest == null or d.*.last_used < oldest.?.last_used) oldest = d.*;
            }
            const victim = oldest orelse return;
            _ = cache.dirs.remove(victim.path);
            victim.destroy();
        }
    }

    /// New sort or hidden setting: every directory follows when shown.
    pub fn setView(cache: *Cache, sort: model.Sort, show_hidden: bool) void {
        cache.sort = sort;
        cache.show_hidden = show_hidden;
    }
};

fn destroy(d: *Dir) void {
    const gpa = d.cache.gpa;
    if (d.loading) |l| l.dir = null;
    if (d.listing) |*l| l.deinit();
    if (d.trash_info) |*t| t.deinit();
    d.order.deinit(gpa);
    d.visible.deinit(gpa);
    d.filter.deinit(gpa);
    d.cursor_name.deinit(gpa);
    d.marks.deinit(gpa);
    gpa.free(d.path);
    gpa.destroy(d);
}

pub fn now() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn isTrash(d: *const Dir) bool {
    return d.cache.trash_files.len != 0 and std.mem.eql(u8, d.path, d.cache.trash_files);
}

// Reading ---------------------------------------------------------------------------

pub const Load = struct {
    dir: ?*Dir,
    gpa: Allocator,
    cache: *Cache,
    path: []u8,
    sort: model.Sort,
    trash_view: bool,
    /// Set when no one waits for the result any more: a read that has not
    /// started skips its work.
    cancelled: std.atomic.Value(bool) = .init(false),
    result: model.ReadError!model.Listing = error.Unexpected,
    info: ?trash.Info = null,
    order: []u32 = &.{},
    taken: bool = false,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        if (l.cancelled.load(.acquire)) return;
        const db = l.cache.load_mime(l.cache.ctx);
        if (l.trash_view) {
            var info: trash.Info = undefined;
            l.result = trash.listAll(l.gpa, l.cache.trash_dir, db, &info);
            if (l.result) |_| l.info = info else |_| {}
        } else {
            l.result = model.read(l.gpa, l.path, db);
        }
        // Sort on the worker too: 100 000 names take a while.
        if (l.result) |*listing| {
            l.order = l.gpa.alloc(u32, listing.entries.len) catch {
                listing.deinit();
                l.result = error.OutOfMemory;
                return;
            };
            model.sort(listing, l.order, l.sort, db);
        } else |_| {}
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        const d = l.dir orelse return;
        if (d.loading != l) return;
        d.loading = null;
        if (l.cancelled.load(.acquire)) return;
        l.taken = true;
        d.finish(l);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const l: *Load = @ptrCast(@alignCast(ud.?));
        if (!l.taken) {
            if (l.result) |*listing| listing.deinit() else |_| {}
            if (l.info) |*i| i.deinit();
            l.gpa.free(l.order);
        }
        l.gpa.free(l.path);
        l.gpa.destroy(l);
    }
};

/// Reads the directory again on a worker, unless a read is in flight.
pub fn reload(d: *Dir) void {
    if (d.loading) |l| {
        if (!l.cancelled.load(.acquire)) return;
        l.dir = null;
        d.loading = null;
    }
    const gpa = d.cache.gpa;
    const l = gpa.create(Load) catch return;
    const p = gpa.dupe(u8, d.path) catch {
        gpa.destroy(l);
        return;
    };
    l.* = .{ .dir = d, .gpa = gpa, .cache = d.cache, .path = p, .sort = d.cache.sort, .trash_view = d.isTrash() };
    d.loading = l;
    // The destroy-notify runs if the job cannot start.
    if (c.siv_job_start(d.cache.sapp, .{}, Load.work, Load.done, Load.destroy, l) != .ok) d.loading = null;
}

/// Gives up on the read in flight if it has not started: the preview
/// moved on. The directory reads again when it is shown again.
pub fn cancelLoad(d: *Dir) void {
    if (d.loading) |l| {
        if (d.loaded) return; // a refresh of a shown folder: let it finish
        l.cancelled.store(true, .release);
        l.dir = null;
        d.loading = null;
    }
}

/// Whether the directory is being read for the first time.
pub fn pending(d: *const Dir) bool {
    return !d.loaded;
}

fn finish(d: *Dir, l: *Load) void {
    const gpa = d.cache.gpa;
    // Marks survive by name.
    var marked: std.StringHashMapUnmanaged(void) = .empty;
    var marked_names: std.ArrayList(u8) = .empty;
    defer {
        marked.deinit(gpa);
        marked_names.deinit(gpa);
    }
    if (d.mark_count != 0) if (d.listing) |*old| {
        var it = d.marks.iterator(.{});
        while (it.next()) |i| {
            if (i >= old.entries.len) break;
            marked_names.appendSlice(gpa, old.name(old.entries[i])) catch break;
            marked_names.append(gpa, 0) catch break;
        }
        var nit = std.mem.splitScalar(u8, marked_names.items, 0);
        while (nit.next()) |n| if (n.len != 0) marked.put(gpa, n, {}) catch {};
    };
    if (d.trash_info) |*t| t.deinit();
    d.trash_info = l.info;
    l.info = null;
    if (d.listing) |*old| old.deinit();
    d.listing = null;
    d.order.clearRetainingCapacity();
    if (l.result) |listing| {
        d.listing = listing;
        d.err = null;
        d.order.appendSlice(gpa, l.order) catch {};
        d.sorted_by = l.sort;
    } else |err| {
        d.err = err;
    }
    gpa.free(l.order);
    l.order = &.{};
    d.loaded = true;
    d.stamp = now();
    d.visible.clearRetainingCapacity();
    // Marks again, by name.
    d.marks.resize(gpa, if (d.listing) |li| li.entries.len else 0, false) catch {};
    d.marks.unsetAll();
    d.mark_count = 0;
    if (marked.count() != 0) if (d.listing) |*li| for (li.entries, 0..) |e, i| {
        if (marked.contains(li.name(e))) {
            d.marks.set(i);
            d.mark_count += 1;
        }
    };
    d.rebuild();
    d.cache.on_loaded(d.cache.ctx, d);
}

// The view -----------------------------------------------------------------------------

/// Re-sorts and re-filters if the cache's sort or hidden setting changed
/// since; true if `visible` changed.
pub fn sync(d: *Dir) bool {
    if (d.listing == null) return false;
    if (std.meta.eql(d.sorted_by, d.cache.sort) and d.shows_hidden == d.cache.show_hidden) return false;
    d.rebuild();
    return true;
}

/// Re-filters (the filter changed), keeping the cursor on its entry.
pub fn refilter(d: *Dir) void {
    d.rebuild();
}

/// Sorts if the order is stale, rebuilds `visible`, and puts the cursor
/// back on the entry named `cursor_name`.
fn rebuild(d: *Dir) void {
    const cache = d.cache;
    const gpa = cache.gpa;
    const l = if (d.listing) |*li| li else {
        d.visible.clearRetainingCapacity();
        d.cursor = 0;
        return;
    };
    if (!std.meta.eql(d.sorted_by, cache.sort) or d.order.items.len != l.entries.len) {
        d.order.resize(gpa, l.entries.len) catch return;
        if (d.trash_info) |*info| {
            for (d.order.items, 0..) |*o, i| o.* = @intCast(i);
            trash.sortIndices(l, info, d.order.items, cache.sort);
        } else model.sort(l, d.order.items, cache.sort, cache.load_mime(cache.ctx));
        d.sorted_by = cache.sort;
    }
    d.shows_hidden = cache.show_hidden;
    d.visible.resize(gpa, d.order.items.len) catch return;
    const n = model.filter(l, d.order.items, d.visible.items, d.filter.items, d.shows_hidden or d.isTrash());
    d.visible.shrinkRetainingCapacity(n);
    d.restoreCursor();
}

fn rememberCursorName(d: *Dir) void {
    const gpa = d.cache.gpa;
    const e = d.entryAt(d.cursor) orelse return;
    d.cursor_name.clearRetainingCapacity();
    d.cursor_name.appendSlice(gpa, d.listing.?.name(e)) catch {};
}

/// Moves the cursor onto the entry named `cursor_name`, or keeps its
/// position within the new bounds.
pub fn restoreCursor(d: *Dir) void {
    if (d.cursor_name.items.len != 0) if (d.indexOf(d.cursor_name.items)) |i| {
        d.cursor = i;
        return;
    };
    const n: u32 = @intCast(d.visible.items.len);
    d.cursor = if (n == 0) 0 else @min(d.cursor, n - 1);
}

/// Puts the cursor on the entry named `name` if it is shown; otherwise
/// remembers the name for when it is.
pub fn selectName(d: *Dir, name: []const u8) void {
    d.cursor_name.clearRetainingCapacity();
    d.cursor_name.appendSlice(d.cache.gpa, name) catch {};
    if (d.indexOf(name)) |i| d.cursor = i;
}

pub fn setCursor(d: *Dir, i: u32) void {
    const n: u32 = @intCast(d.visible.items.len);
    if (n == 0) return;
    d.cursor = @min(i, n - 1);
    d.rememberCursorName();
}

/// The shown index of the entry named `name`.
pub fn indexOf(d: *const Dir, name: []const u8) ?u32 {
    const l = d.listing orelse return null;
    for (d.visible.items, 0..) |e, i| {
        if (std.mem.eql(u8, l.name(l.entries[e]), name)) return @intCast(i);
    }
    return null;
}

pub fn count(d: *const Dir) u32 {
    return @intCast(d.visible.items.len);
}

pub fn entryAt(d: *const Dir, i: u32) ?model.Entry {
    const l = d.listing orelse return null;
    if (i >= d.visible.items.len) return null;
    return l.entries[d.visible.items[i]];
}

/// The entry under the cursor.
pub fn current(d: *const Dir) ?model.Entry {
    return d.entryAt(d.cursor);
}

pub fn nameAt(d: *const Dir, i: u32) ?[]const u8 {
    const e = d.entryAt(i) orelse return null;
    return d.listing.?.name(e);
}

/// The absolute path of the shown entry `i`, in `buf`.
pub fn pathAt(d: *const Dir, buf: []u8, i: u32) ?[]u8 {
    const e = d.entryAt(i) orelse return null;
    return d.listing.?.pathOf(buf, e);
}

// Marks --------------------------------------------------------------------------------

pub fn isMarked(d: *const Dir, i: u32) bool {
    if (i >= d.visible.items.len) return false;
    const e = d.visible.items[i];
    return e < d.marks.bit_length and d.marks.isSet(e);
}

pub fn setMark(d: *Dir, i: u32, on: bool) void {
    if (i >= d.visible.items.len) return;
    const e = d.visible.items[i];
    if (e >= d.marks.bit_length) return;
    if (d.marks.isSet(e) == on) return;
    d.marks.setValue(e, on);
    if (on) d.mark_count += 1 else d.mark_count -= 1;
}

pub fn clearMarks(d: *Dir) void {
    d.marks.unsetAll();
    d.mark_count = 0;
}

/// Shown indices of marked entries, in order.
pub fn markedIndices(d: *const Dir, gpa: Allocator) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(gpa);
    if (d.mark_count == 0) return out.toOwnedSlice(gpa);
    for (d.visible.items, 0..) |e, i| {
        if (e < d.marks.bit_length and d.marks.isSet(e)) try out.append(gpa, @intCast(i));
    }
    return out.toOwnedSlice(gpa);
}

// Search ---------------------------------------------------------------------------------

/// The next shown entry after `from` (or before it, backwards), wrapping,
/// whose name contains `query` ignoring case (smart case: case matters
/// when the query has a capital letter).
pub fn findMatch(d: *const Dir, query: []const u8, from: u32, backward: bool, include_from: bool) ?u32 {
    const l = d.listing orelse return null;
    const n: u32 = @intCast(d.visible.items.len);
    if (n == 0 or query.len == 0) return null;
    const exact = hasUpper(query);
    const start = @min(from, n - 1);
    // Every entry once, the starting one last unless it counts first.
    var k: u32 = if (include_from) 0 else 1;
    const end: u32 = if (include_from) n - 1 else n;
    while (k <= end) : (k += 1) {
        const i = if (backward) (start + n - k % n) % n else (start + k) % n;
        if (contains(l.base(l.entries[d.visible.items[i]]), query, exact)) return i;
    }
    return null;
}

/// How many shown entries match `query`.
pub fn countMatches(d: *const Dir, query: []const u8) u32 {
    const l = d.listing orelse return 0;
    const exact = hasUpper(query);
    var n: u32 = 0;
    for (d.visible.items) |e| {
        if (contains(l.base(l.entries[e]), query, exact)) n += 1;
    }
    return n;
}

pub fn hasUpper(s: []const u8) bool {
    for (s) |ch| if (std.ascii.isUpper(ch)) return true;
    return false;
}

pub fn contains(name: []const u8, query: []const u8, exact: bool) bool {
    if (exact) return std.mem.indexOf(u8, name, query) != null;
    return std.ascii.findIgnoreCase(name, query) != null;
}

test "find with wrapping and smart case" {
    try std.testing.expect(contains("README.md", "read", false));
    try std.testing.expect(!contains("README.md", "Read", true));
    try std.testing.expect(hasUpper("Read"));
}
