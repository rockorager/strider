//! Drag and drop inside the app: what a drag from the current column
//! carries, and how each folder under the pointer takes it.
//!
//! A drag starts from a row of the current column with what commands act
//! on (the visual range, the marks, or the row), and an icon of the file's
//! icon and name ("3 items" for several) with what a drop would do. Any
//! folder takes it: a folder's row in any column, a column's empty space
//! (its folder), a folder of the header path, or a tab (its folder). The
//! target under the pointer is outlined, the status line says "Move 3
//! items to src", and the drop runs as a file operation, so conflicts,
//! progress, and undo work as for p. Within one filesystem a drop moves,
//! across filesystems it copies; Shift moves, Ctrl copies, Ctrl+Shift
//! links. The folder the items are in, the items themselves, and folders
//! that cannot be written take nothing. Resting on a folder's row (or a
//! tab) opens it, so a drop can go deeper; resting near a column's top or
//! bottom scrolls it. Escape cancels, where the compositor sends keys.
//!
//! The drag's source (its paths, icon, and node) is the app's, so another
//! window of the app knows what is dragged; each window keeps the target
//! it highlights and its timers.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Column = @import("Column.zig");
const model = @import("model.zig");
const fsops = @import("fsops.zig");
const uri = @import("uri.zig");

const Node = siv.Node;
const Dnd = @This();

/// How long a drag rests on a folder before it opens.
pub const spring_ms = 700;
/// How near a column's top or bottom a drag scrolls it, and how often.
const edge_px = 24;
const scroll_ms = 80;

pub const Action = enum {
    move,
    copy,
    link,

    fn word(a: Action) []const u8 {
        return switch (a) {
            .move => "Move",
            .copy => "Copy",
            .link => "Link",
        };
    }

    fn kind(a: Action) fsops.Kind {
        return switch (a) {
            .move => .move,
            .copy => .copy,
            .link => .link,
        };
    }
};

/// What the app is dragging: its own drag, from one window.
pub const Source = struct {
    win: *Window,
    node: Node,
    paths: [][]u8,
    /// The folder they are in, and its filesystem.
    dir: []u8,
    dev: u64,
    /// The icon, redrawn when what a drop would do changes.
    icon: siv.Image = .null,
    icon_action: ?Action = null,
    icon_width: f32 = 0,

    fn deinit(s: *Source, gpa: std.mem.Allocator) void {
        App.freePaths(gpa, s.paths);
        gpa.free(s.dir);
        if (s.icon != .null) c.siv_image_destroy(s.icon);
    }
};

/// A node that takes drops, and how it shows it.
pub const Target = union(enum) {
    /// A folder's row: its line node, in a column.
    row: struct { line: Node, col: *Column, index: u32 },
    /// A column's empty space: its folder.
    column: *Column,
    /// A folder of the header path.
    crumb: Node,
    /// A tab, by index.
    tab: usize,

    fn eql(a: Target, b: Target) bool {
        return switch (a) {
            .row => |r| b == .row and b.row.line == r.line and b.row.index == r.index,
            .column => |col| b == .column and b.column == col,
            .crumb => |n| b == .crumb and b.crumb == n,
            .tab => |i| b == .tab and b.tab == i,
        };
    }
};

win: *Window,
/// The target outlined, and the folder it stands for.
over: ?Target = null,
dest: std.ArrayList(u8) = .empty,
dest_dev: u64 = 0,
dest_ok: bool = false,
/// What the status line says while a drag rests on a target.
hint: std.ArrayList(u8) = .empty,
spring: siv.Timer = .null,
spring_path: std.ArrayList(u8) = .empty,
spring_tab: ?usize = null,
scroll: siv.Timer = .null,
scroll_col: ?*Column = null,
scroll_index: i64 = 0,
scroll_dir: i64 = 0,

pub fn deinit(d: *Dnd) void {
    const gpa = d.win.gpa;
    d.stopTimers();
    d.dest.deinit(gpa);
    d.hint.deinit(gpa);
    d.spring_path.deinit(gpa);
    const app = d.win.app;
    if (app.drag) |s| if (s.win == d.win) endSource(app);
}

// Starting ---------------------------------------------------------------------------------

/// Drags the targets (the visual range, the marks, or the row) from
/// `node`, a row of the current column: to folders here, and out to
/// other applications as files.
pub fn start(win: *Window, node: Node) void {
    const app = win.app;
    const gpa = win.gpa;
    const paths = win.targets() catch return;
    if (paths.len == 0) return App.freePaths(gpa, paths);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    for (paths) |p| {
        uri.appendFileUri(&data, gpa, p) catch return App.freePaths(gpa, paths);
        data.appendSlice(gpa, "\r\n") catch return App.freePaths(gpa, paths);
    }
    const first = data.items.len;
    for (paths, 0..) |p, i| {
        if (i > 0) data.append(gpa, '\n') catch break;
        data.appendSlice(gpa, p) catch break;
    }
    const s = gpa.create(Source) catch return App.freePaths(gpa, paths);
    const dir = gpa.dupe(u8, model.parent(paths[0])) catch {
        gpa.destroy(s);
        return App.freePaths(gpa, paths);
    };
    s.* = .{ .win = win, .node = node, .paths = paths, .dir = dir, .dev = devOf(dir) orelse 0 };
    if (app.drag) |old| {
        old.deinit(gpa);
        gpa.destroy(old);
    }
    app.drag = s;
    s.icon = drawIcon(win, s, null);
    const lengths = [2]usize{ first, data.items.len - first };
    const mimes = "text/uri-list\ntext/plain;charset=utf-8";
    if (c.siv_drag_start(node, &.{ .mimes = mimes, .mimes_len = mimes.len, .data = data.items.ptr, .data_count = data.items.len, .lengths = &lengths, .lengths_count = 2, .icon = s.icon, .actions = .{ .copy = true, .move = true }, .hotspot_x = 14, .hotspot_y = 14 }) != .ok) endSource(app);
}

/// The drag ended, dropped or not: forget it everywhere.
pub fn sourceEnded(app: *App) void {
    endSource(app);
}

fn endSource(app: *App) void {
    const s = app.drag orelse return;
    app.drag = null;
    for (app.windows.items) |w| w.dnd.leave();
    s.deinit(app.gpa);
    app.gpa.destroy(s);
}

/// Escape while dragging: cancels the app's drag. False without one.
pub fn cancel(win: *Window) bool {
    const s = win.app.drag orelse return false;
    if (s.win != win) return false;
    _ = c.siv_drag_cancel(s.node);
    return true;
}

// The icon ---------------------------------------------------------------------------------

const icon_h: f32 = 28;
const DrawCtx = struct { win: *Window, s: *Source, action: ?Action, label: []const u8, icon: []const u8, folder: bool, label_w: f32, badge_w: f32 };

/// The file's icon and name ("3 items"), with what a drop would do.
fn drawIcon(win: *Window, s: *Source, action: ?Action) siv.Image {
    var nb: [64]u8 = undefined;
    const label = if (s.paths.len == 1) model.basename(s.paths[0]) else std.fmt.bufPrint(&nb, "{d} items", .{s.paths.len}) catch "items";
    var ib: [512]u8 = undefined;
    const one = s.paths.len == 1;
    const folder = one and Window.isDirPath(s.paths[0]);
    const icon: []const u8 = if (!one) "edit-copy-symbolic\nemblem-documents-symbolic\ntext-x-generic" else if (folder) "folder\nfolder-symbolic" else win.iconForPath(s.paths[0], &ib);
    const style: siv.TextStyleDesc = .{ .size_role = .body, .flags = .{ .no_wrap = true } };
    var m: siv.TextMetrics = .{};
    _ = c.siv_app_measure_text(win.app.app, label.ptr, label.len, 0, &style, &m);
    var bm: siv.TextMetrics = .{};
    if (action) |a| {
        const badge_style: siv.TextStyleDesc = .{ .size_role = .caption, .weight = .bold, .flags = .{ .no_wrap = true } };
        _ = c.siv_app_measure_text(win.app.app, a.word().ptr, a.word().len, 0, &badge_style, &bm);
    }
    const label_w = @min(m.width, 220);
    const badge_w: f32 = if (action != null) bm.width + 12 else 0;
    const width = 8 + 16 + 6 + label_w + (if (action != null) 8 + badge_w else 0) + 10;
    var ctx: DrawCtx = .{ .win = win, .s = s, .action = action, .label = label, .icon = icon, .folder = folder, .label_w = label_w, .badge_w = badge_w };
    var img: siv.Image = .null;
    if (c.siv_image_draw(win.window, &.{ .user_data = &ctx, .draw = drawFn, .width = @ceil(width), .height = icon_h }, &img) != .ok) return .null;
    s.icon_action = action;
    s.icon_width = width;
    return img;
}

fn drawFn(ud: ?*anyopaque, _: Node, dr: siv.Draw, width: f32, height: f32) callconv(.c) void {
    const ctx: *DrawCtx = @ptrCast(@alignCast(ud.?));
    const win = ctx.win.window;
    const r: siv.Radii = .{ .top_left = 6, .top_right = 6, .bottom_left = 6, .bottom_right = 6 };
    c.siv_draw_rounded_rect(dr, .{ .x = 0.5, .y = 0.5, .width = width - 1, .height = height - 1 }, r);
    c.siv_draw_fill(dr, &.{ .color = color(win, .card_bg) }, .{ .keep_path = true });
    c.siv_draw_stroke(dr, &.{ .width = 1 }, &.{ .color = color(win, .border) });
    c.siv_draw_icon(dr, ctx.icon.ptr, ctx.icon.len, .{ .x = 8, .y = (height - 16) / 2, .width = 16, .height = 16 }, color(win, if (ctx.folder) .accent else .card_fg), .{});
    const style: siv.TextStyleDesc = .{ .color_token = .card_fg, .size_role = .body, .flags = .{ .no_wrap = true, .ellipsize = true } };
    var m: siv.TextMetrics = .{};
    _ = c.siv_app_measure_text(ctx.win.app.app, "Ag", 2, 0, &style, &m);
    c.siv_draw_text(dr, 30, (height - m.height) / 2, ctx.label_w, ctx.label.ptr, ctx.label.len, &style);
    const a = ctx.action orelse return;
    // What a drop would do, as a badge on the accent.
    const bx = 30 + ctx.label_w + 8;
    c.siv_draw_rounded_rect(dr, .{ .x = bx, .y = 6, .width = ctx.badge_w, .height = height - 12 }, .{ .top_left = 4, .top_right = 4, .bottom_left = 4, .bottom_right = 4 });
    c.siv_draw_fill(dr, &.{ .color = color(win, if (a == .move) .accent else .success) }, .{});
    const bs: siv.TextStyleDesc = .{ .color_token = .accent_fg, .size_role = .caption, .weight = .bold, .flags = .{ .no_wrap = true } };
    var bm: siv.TextMetrics = .{};
    _ = c.siv_app_measure_text(ctx.win.app.app, a.word().ptr, a.word().len, 0, &bs, &bm);
    c.siv_draw_text(dr, bx + 6, (height - bm.height) / 2, 0, a.word().ptr, a.word().len, &bs);
}

fn color(win: siv.Window, token: siv.ColorToken) siv.Color {
    var col: siv.Color = .{};
    _ = c.siv_window_get_color(win, token, &col);
    return col;
}

/// Redraws the icon for `action` (null: no target).
fn showAction(s: *Source, action: ?Action) void {
    if (s.icon_action == action or s.icon == .null) return;
    const img = drawIcon(s.win, s, action);
    if (img == .null) return;
    if (c.siv_drag_set_icon(s.node, img, 14, 14) == .ok) {
        c.siv_image_destroy(s.icon);
        s.icon = img;
    } else c.siv_image_destroy(img);
}

// Targets ----------------------------------------------------------------------------------

/// A drop event on `target`, which stands for the folder `dest`.
pub fn onDrop(d: *Dnd, ev: *const siv.Event, target: Target, dest: []const u8) siv.EventResult {
    switch (ev.phase) {
        .enter, .move => {
            const changed = if (d.over) |o| !o.eql(target) else true;
            if (changed) d.enter(target, dest);
            if (!d.dest_ok) {
                d.clearHighlight();
                return .pass;
            }
            const action = d.actionFor(ev.modifiers);
            // Wayland has copy and move; a link is asked for as a copy and
            // made here.
            _ = c.siv_drop_set_action(d.win.window, if (action == .move) .move else .copy);
            if (d.win.app.drag) |s| showAction(s, action);
            d.setHint(action);
            if (changed) d.springFor(target, dest);
            d.autoscroll(target, ev);
            return .handled;
        },
        .leave => {
            if (d.over) |o| if (o.eql(target)) d.leave();
            return .handled;
        },
        .drop => {
            const ok = d.dest_ok;
            const action = d.actionFor(ev.modifiers);
            var db: [linux.PATH_MAX]u8 = undefined;
            const to = std.fmt.bufPrint(&db, "{s}", .{dest}) catch return .pass;
            d.leave();
            if (!ok) return .pass;
            const data = if (ev.data) |p| p[0..ev.data_count] else return .pass;
            const win = d.win;
            // The app's own drag: its paths; another application's: the
            // files its list names.
            if (win.app.drag) |s| {
                win.app.startOp(win, action.kind(), Window.toConst(s.paths), to, &.{}, true);
                return .handled;
            }
            win.dropUris(data, to, if (ev.modifiers.ctrl and ev.modifiers.shift) .link else if (ev.action == .move) .move else .copy);
            return .handled;
        },
        else => return .pass,
    }
}

/// The drag arrived on a new target: whether it takes the items, and
/// the outline.
fn enter(d: *Dnd, target: Target, dest: []const u8) void {
    const gpa = d.win.gpa;
    d.clearHighlight();
    d.stopTimers();
    d.dest.clearRetainingCapacity();
    d.dest.appendSlice(gpa, dest) catch {};
    d.dest_dev = devOf(dest) orelse 0;
    d.dest_ok = takes(d.win.app.drag, dest);
    d.over = target;
    if (d.dest_ok) d.highlight(true);
}

/// Whether `dest` takes the drag: not the folder the items are in, not
/// one of them or a folder inside one, and only a folder that can be
/// written.
fn takes(src: ?*Source, dest: []const u8) bool {
    if (src) |s| {
        if (std.mem.eql(u8, dest, s.dir)) return false;
        for (s.paths) |p| if (std.mem.eql(u8, dest, p) or model.isWithin(dest, p)) return false;
    }
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{dest}, 0) catch return false;
    return linux.errno(linux.faccessat(linux.AT.FDCWD, z, linux.W_OK | linux.X_OK, 0)) == .SUCCESS;
}

/// Shift moves, Ctrl copies, both link; else a move within one
/// filesystem and a copy across.
fn actionFor(d: *const Dnd, mods: siv.Modifiers) Action {
    if (mods.ctrl and mods.shift) return .link;
    if (mods.ctrl) return .copy;
    if (mods.shift) return .move;
    const s = d.win.app.drag orelse return .copy;
    return if (s.dev != 0 and s.dev == d.dest_dev) .move else .copy;
}

/// The drag left every target here (or ended).
pub fn leave(d: *Dnd) void {
    d.clearHighlight();
    d.over = null;
    d.dest_ok = false;
    d.stopTimers();
    if (d.hint.items.len != 0) {
        d.hint.clearRetainingCapacity();
        d.win.updateStatus();
    }
    if (d.win.app.drag) |s| if (s.win == d.win) showAction(s, null);
}

fn setHint(d: *Dnd, action: Action) void {
    const s = d.win.app.drag;
    var nb: [300]u8 = undefined;
    const what = if (s) |x| (if (x.paths.len == 1) std.fmt.bufPrint(&nb, "“{s}”", .{model.basename(x.paths[0])}) catch "it" else std.fmt.bufPrint(&nb, "{d} items", .{x.paths.len}) catch "them") else "the files";
    const name = if (std.mem.eql(u8, d.dest.items, d.win.app.home)) "~" else model.basename(d.dest.items);
    var hb: [600]u8 = undefined;
    const text = std.fmt.bufPrint(&hb, "{s} {s} {s} {s}", .{ action.word(), what, if (action == .link) "in" else "to", if (name.len == 0) "/" else name }) catch return;
    if (std.mem.eql(u8, text, d.hint.items)) return;
    d.hint.clearRetainingCapacity();
    d.hint.appendSlice(d.win.gpa, text) catch return;
    d.win.updateStatus();
}

// The outline -------------------------------------------------------------------------------

const outline: siv.Corners = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 };

fn highlight(d: *Dnd, on: bool) void {
    const t = d.over orelse return;
    const win = d.win;
    const txn = win.begin() orelse return;
    switch (t) {
        .row => |r| _ = c.siv_set_visual(txn, r.line, if (on) &.{ .border_token = .accent, .border_width = 2, .radius = outline } else &.{}),
        .column => |col| col.showDropRing(txn, on),
        .crumb => |n| _ = c.siv_set_visual(txn, n, if (on) &.{ .background_token = .selection_bg, .border_token = .accent, .border_width = 1, .radius = outline } else &.{}),
        .tab => |i| win.tabDropOutline(txn, i, on),
    }
    _ = c.siv_txn_commit(txn);
}

fn clearHighlight(d: *Dnd) void {
    if (d.over != null and d.dest_ok) d.highlight(false);
}

/// A row was bound to another entry: an outline on it no longer fits.
pub fn rowRebound(d: *Dnd, line: Node, index: u32) void {
    const t = d.over orelse return;
    if (t == .row and t.row.line == line and t.row.index != index) {
        d.clearHighlight();
        d.over = null;
        d.stopTimers();
    }
}

// Opening folders and scrolling -----------------------------------------------------------

fn springFor(d: *Dnd, target: Target, dest: []const u8) void {
    if (!d.dest_ok) return;
    switch (target) {
        .row => {},
        .tab => |i| d.spring_tab = i,
        else => return,
    }
    d.spring_path.clearRetainingCapacity();
    d.spring_path.appendSlice(d.win.gpa, dest) catch return;
    _ = c.siv_timer_start(d.win.app.app, spring_ms, onSpring, null, d, &d.spring);
}

fn onSpring(ud: ?*anyopaque) callconv(.c) void {
    const d: *Dnd = @ptrCast(@alignCast(ud.?));
    d.spring = .null;
    const tab = d.spring_tab;
    d.spring_tab = null;
    var pb: [linux.PATH_MAX]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}", .{d.spring_path.items}) catch return;
    d.clearHighlight();
    d.over = null;
    if (tab) |i| d.win.selectTab(i) else d.win.cd(path);
}

/// Near a column's top or bottom edge, the column scrolls a row at a time
/// while the drag rests there.
fn autoscroll(d: *Dnd, target: Target, ev: *const siv.Event) void {
    const r = switch (target) {
        .row => |x| x,
        else => return d.stopScroll(),
    };
    var row_rect: siv.Rect = .{};
    var view_rect: siv.Rect = .{};
    if (c.siv_node_get_rect(r.line, &row_rect) != .ok or c.siv_node_get_rect(r.col.view, &view_rect) != .ok) return;
    const y = row_rect.y + ev.y;
    const dir: i64 = if (y < view_rect.y + edge_px) -1 else if (y > view_rect.y + view_rect.height - edge_px) 1 else 0;
    if (dir == 0) return d.stopScroll();
    if (d.scroll != .null and d.scroll_dir == dir and d.scroll_col == r.col) return;
    d.stopScroll();
    d.scroll_col = r.col;
    d.scroll_dir = dir;
    d.scroll_index = r.index;
    _ = c.siv_timer_start(d.win.app.app, scroll_ms, onScroll, null, d, &d.scroll);
}

fn onScroll(ud: ?*anyopaque) callconv(.c) void {
    const d: *Dnd = @ptrCast(@alignCast(ud.?));
    d.scroll = .null;
    const col = d.scroll_col orelse return;
    const dir = col.dir orelse return;
    const n: i64 = dir.count();
    d.scroll_index = std.math.clamp(d.scroll_index + d.scroll_dir, 0, @max(n - 1, 0));
    if (d.win.begin()) |txn| {
        _ = c.siv_view_scroll_to(txn, col.view, @intCast(d.scroll_index));
        _ = c.siv_txn_commit(txn);
    }
    if (d.scroll_index > 0 and d.scroll_index < n - 1) _ = c.siv_timer_start(d.win.app.app, scroll_ms, onScroll, null, d, &d.scroll);
}

fn stopScroll(d: *Dnd) void {
    if (d.scroll != .null) _ = c.siv_timer_cancel(d.scroll);
    d.scroll = .null;
    d.scroll_dir = 0;
    d.scroll_col = null;
}

fn stopTimers(d: *Dnd) void {
    if (d.spring != .null) _ = c.siv_timer_cancel(d.spring);
    d.spring = .null;
    d.spring_tab = null;
    d.stopScroll();
}

fn devOf(path: []const u8) ?u64 {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return null;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}
