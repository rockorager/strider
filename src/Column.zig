//! A Miller column: a virtualized list of one directory's shown entries,
//! with its cursor row selected. The parent and current columns, and the
//! preview of a folder, are each one.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const Dir = @import("Dir.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const Window = @import("Window.zig");

const Column = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const Kind = enum { parent, current, preview };

pub const row_height: f32 = 26;

win: *Window,
kind: Kind,
root: Node = .null,
view: Node = .null,
/// What shows instead of rows: "Empty", "Loading…", an error.
message: Node = .null,
dir: ?*Dir = null,
/// The count the view was last given.
shown_count: u32 = 0,
/// A press that may become a drag.
drag_armed: bool = false,
drag_x: f32 = 0,
drag_y: f32 = 0,

/// Row parts, kept in node data on each row.
const RowParts = extern struct {
    col: ?*Column,
    index: u32,
    mark: Node,
    icon: Node,
    name: Node,
    info: Node,
};
var row_key: u8 = 0;

pub fn build(col: *Column, txn: Txn, parent: Node, label: []const u8) void {
    col.root = c.siv_stack(txn, parent, null);
    _ = c.siv_set_layout(txn, col.root, &.{ .width = ui.fill(), .height = ui.fill() });
    col.view = c.siv_list_view(txn, col.root, &.{
        .label = label.ptr,
        .label_len = label.len,
        .user_data = col,
        .bind = bindRow,
        .item_height = row_height,
        .selection = .single,
    });
    _ = c.siv_set_layout(txn, col.view, &.{ .width = ui.fill(), .height = ui.fill() });
    _ = c.siv_set_visual(txn, col.view, &.{ .background_token = .view_bg, .flags = .{ .clip = true } });
    _ = c.siv_on(txn, col.view, .select, onSelect, null, col);
    _ = c.siv_on(txn, col.view, .activate, onActivate, null, col);
    col.message = c.siv_text(txn, col.root, "", 0);
    _ = c.siv_set_text_style(txn, col.message, &.{ .color_token = .muted_fg, .size_role = .body, .@"align" = .center });
    _ = c.siv_set_layout(txn, col.message, &.{ .align_x = .center, .padding = .{ .start = 12, .end = 12, .top = 16 } });
    _ = c.siv_set_visual(txn, col.message, &.{ .flags = .{ .no_hit_test = true } });
    _ = c.siv_set_hidden(txn, col.message, true);
}

/// Shows `dir` (or nothing), with its cursor; pins it while shown.
pub fn show(col: *Column, txn: Txn, dir: ?*Dir) void {
    if (col.dir != dir) {
        if (col.dir) |old| old.pins -= 1;
        if (dir) |d| d.pins += 1;
        col.dir = dir;
    }
    col.refresh(txn);
}

/// Gives the view the directory's rows and cursor again.
pub fn refresh(col: *Column, txn: Txn) void {
    const d = col.dir;
    const n: u32 = if (d) |x| x.count() else 0;
    col.shown_count = n;
    _ = c.siv_view_set_count(txn, col.view, n);
    if (d) |x| if (n > 0) col.placeCursor(txn, x.cursor, false);
    col.applyMessage(txn);
}

fn applyMessage(col: *Column, txn: Txn) void {
    var msg: []const u8 = "";
    if (col.dir) |d| {
        if (d.err) |err| {
            msg = switch (err) {
                error.AccessDenied => "Permission denied",
                error.FileNotFound => "Not found",
                error.NotDir => "Not a folder",
                else => "Cannot read this folder",
            };
        } else if (!d.loaded) {
            msg = "Loading…";
        } else if (d.count() == 0) {
            msg = if (d.filter.items.len != 0) "No matches" else if (d.isTrash()) "The trash is empty" else "Empty";
        }
    }
    _ = c.siv_set_text(txn, col.message, msg.ptr, msg.len);
    _ = c.siv_set_hidden(txn, col.message, msg.len == 0);
}

/// Moves the view's cursor and selection to `i`, keeping `scroll_off`
/// rows around it in view.
pub fn placeCursor(col: *Column, txn: Txn, i: u32, _: bool) void {
    if (i >= col.shown_count) return;
    _ = c.siv_view_set_cursor(txn, col.view, @intCast(i));
    _ = c.siv_view_set_selected(txn, col.view, i, true);
    const off = col.win.app.options.scroll_off;
    if (off > 0 and col.kind == .current) {
        const below = @min(i + off, col.shown_count - 1);
        const above = i -| off;
        _ = c.siv_view_scroll_to(txn, col.view, below);
        _ = c.siv_view_scroll_to(txn, col.view, above);
    }
}

/// Binds the rows in view again (marks, the register, icons changed).
pub fn rebind(col: *Column, txn: Txn) void {
    _ = c.siv_view_refresh(txn, col.view);
}

fn rowParts(txn: Txn, row: Node) ?*RowParts {
    var p: ?*anyopaque = null;
    if (c.siv_node_get_data(row, &row_key, &p) == .ok and p != null) return @ptrCast(@alignCast(p));
    if (c.siv_set_data(txn, row, &row_key, @sizeOf(RowParts), &p) != .ok) return null;
    return @ptrCast(@alignCast(p));
}

fn bindRow(ud: ?*anyopaque, txn: Txn, row: Node, item: u64, _: u32, _: u32, _: bool) callconv(.c) void {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    const parts = rowParts(txn, row) orelse return;
    const d = col.dir orelse return;
    const i: u32 = @intCast(item);
    const e = d.entryAt(i) orelse return;
    const l = &d.listing.?;
    const app = col.win.app;
    if (parts.col == null) {
        parts.col = col;
        const line = c.siv_flex(txn, row, &.{ .axis = .row, .gap = 6, .align_items = .center });
        _ = c.siv_set_layout(txn, line, &.{ .height = ui.fill(), .width = ui.fill() });
        parts.mark = c.siv_box(txn, line);
        _ = c.siv_set_layout(txn, parts.mark, &.{ .width = ui.px(3), .height = ui.px(row_height - 8), .flags = .{ .no_shrink = true } });
        parts.icon = ui.iconView(txn, line, 16);
        parts.name = c.siv_text(txn, line, "", 0);
        _ = c.siv_set_layout(txn, parts.name, &.{ .grow = 1, .basis = ui.px(0) });
        parts.info = c.siv_text(txn, line, "", 0);
        _ = c.siv_set_layout(txn, parts.info, &.{ .flags = .{ .no_shrink = true } });
        // Pointer and drop handlers on the body, which fills the row.
        _ = c.siv_on(txn, row, .pointer, onRowPointer, null, parts);
        _ = c.siv_on(txn, row, .drop, onRowDrop, null, parts);
    }
    parts.index = i;
    // Folders take drops (into them); other rows leave drops to the
    // column behind them.
    const drop_mimes: []const u8 = if (e.kind == .dir and col.kind != .preview) "text/uri-list" else "";
    _ = c.siv_set_drop_target(txn, row, &.{ .mimes = drop_mimes.ptr, .mimes_len = drop_mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
    parts.col = col;
    const marked = d.isMarked(i) or col.win.inVisualRange(col, i);
    _ = c.siv_set_visual(txn, parts.mark, &.{ .background_token = if (marked) .warning else .none, .radius = .{ .top_start = 1.5, .top_end = 1.5, .bottom_start = 1.5, .bottom_end = 1.5 } });
    _ = c.siv_set_semantics(txn, parts.mark, if (marked) &.{ .role = .image, .label = "marked", .label_len = 6 } else &.{ .role = .none });

    const name = l.base(e);
    _ = c.siv_set_text(txn, parts.name, name.ptr, name.len);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const in_register = app.register.items.len != 0 and if (l.pathOf(&pbuf, e)) |p| app.inRegister(p) else false;
    const token: siv.ColorToken = if (marked) .warning else if (e.kind == .dir) .accent else if (e.hidden) .muted_fg else if (e.mode & 0o111 != 0 and e.kind == .file) .success else .view_fg;
    _ = c.siv_set_text_style(txn, parts.name, &.{
        .color_token = token,
        .size_role = .body,
        .weight = if (e.kind == .dir or marked) .bold else .regular,
        .slant = if (e.link) .italic else .roman,
        .flags = .{ .no_wrap = true, .ellipsize = true },
    });
    // Cut files look struck through until pasted; copied ones underlined.
    if (in_register) {
        const span: siv.TextSpan = .{ .start = 0, .end = @intCast(name.len), .flags = if (app.register_cut) .{ .strikethrough = true } else .{ .underline = true } };
        _ = c.siv_set_text_spans(txn, parts.name, &.{ .spans = @ptrCast(&span), .spans_count = 1 });
    }

    // Icons.
    _ = c.siv_set_hidden(txn, parts.icon, !app.options.icons);
    if (app.options.icons) {
        var ibuf: [512]u8 = undefined;
        const icon = iconFor(col.win, e, &ibuf);
        _ = c.siv_set_image_view(txn, parts.icon, &.{ .icon = icon.ptr, .icon_len = icon.len, .icon_size = 16, .color_token = if (e.kind == .dir) .accent else .view_fg });
    }

    // Sizes (files) in the current column and folder previews.
    var sbuf: [64]u8 = undefined;
    var info: []const u8 = "";
    const show_info = col.kind != .parent and app.options.show_size;
    if (show_info) {
        if (d.trash_info) |*ti| {
            const t = ti.get(d.visible.items[i]);
            info = model.basename(model.parent(t.original));
        } else if (e.kind == .file) {
            info = compactSize(&sbuf, e.size);
        } else if (e.link and e.kind == .other) {
            info = "broken link";
        }
    }
    _ = c.siv_set_text(txn, parts.info, info.ptr, info.len);
    _ = c.siv_set_text_style(txn, parts.info, &.{ .color_token = .muted_fg, .size_role = .caption, .direction = .ltr, .flags = .{ .no_wrap = true } });
    _ = c.siv_set_hidden(txn, parts.info, info.len == 0);
}

/// "1.2K", "34M", "512": the short sizes file managers' columns use.
pub fn compactSize(buf: []u8, size: u64) []const u8 {
    if (size < 1024) return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "";
    const units = [_][]const u8{ "K", "M", "G", "T", "P" };
    var v: f64 = @floatFromInt(size);
    var u: usize = 0;
    v /= 1024;
    while (v >= 1024 and u + 1 < units.len) : (u += 1) v /= 1024;
    if (v < 10) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "";
}

pub fn iconFor(win: *Window, e: model.Entry, buf: []u8) []const u8 {
    if (e.kind == .dir) return "folder";
    const db = win.app.mimeDb() orelse return "text-x-generic";
    return db.iconNames(e.mime, buf);
}

const drag_threshold: f32 = 6;

/// Rows of the current column drag what commands act on out to other
/// applications (and other folders); the view still selects on press.
fn onRowPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const parts: *RowParts = @ptrCast(@alignCast(ud.?));
    const col = parts.col orelse return .pass;
    if (col.kind != .current) return .pass;
    switch (ev.phase) {
        .down => {
            if (ev.button != .primary) return .pass;
            col.drag_armed = true;
            col.drag_x = ev.x;
            col.drag_y = ev.y;
        },
        .move => if (col.drag_armed and (@abs(ev.x - col.drag_x) >= drag_threshold or @abs(ev.y - col.drag_y) >= drag_threshold)) {
            col.drag_armed = false;
            col.win.startDrag(node);
        },
        .up, .cancel => col.drag_armed = false,
        else => {},
    }
    return .pass;
}

/// A drop on a folder's row goes into that folder.
fn onRowDrop(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const parts: *RowParts = @ptrCast(@alignCast(ud.?));
    const col = parts.col orelse return .pass;
    const d = col.dir orelse return .pass;
    const e = d.entryAt(parts.index) orelse return .pass;
    if (e.kind != .dir) return .pass;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, parts.index) orelse return .pass;
    return if (col.win.acceptDrop(ev, p)) .handled else .pass;
}

fn onSelect(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    // Only the user's choices report: a click (keys go to the window).
    col.win.columnClicked(col, ev.index, false);
    return .handled;
}

fn onActivate(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const col: *Column = @ptrCast(@alignCast(ud.?));
    col.win.columnClicked(col, ev.index, true);
    return .handled;
}
