//! A window: three Miller columns (the parent folder, the current one,
//! and a preview of the entry under the cursor), a header with the path
//! and the tabs, a status line, and a command line. Keys go through the
//! keymap: counts, multi-key sequences with a which-key popup, and
//! prompts for search, find, filter, rename, and commands.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Dir = @import("Dir.zig");
const Column = @import("Column.zig");
const Preview = @import("Preview.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const fsops = @import("fsops.zig");
const uri = @import("uri.zig");
const ui = @import("ui.zig");
const commands = @import("commands.zig");

const Window = @This();
pub const PreviewMode = Preview.Mode;
const Node = siv.Node;
const Txn = siv.Txn;

pub const Tab = struct {
    dir: *Dir,
    history: std.ArrayList([]u8) = .empty,
    history_pos: usize = 0,

    pub fn path(t: *const Tab) []const u8 {
        return t.dir.path;
    }
};

pub const PromptKind = enum {
    command,
    search,
    search_back,
    find,
    filter,
    shell,
    rename,
    create,
    passphrase,

    fn label(k: PromptKind) []const u8 {
        return switch (k) {
            .command => ":",
            .search => "/",
            .search_back => "?",
            .find => "find:",
            .filter => "filter:",
            .shell => "!",
            .rename => "rename:",
            .create => "new:",
            .passphrase => "passphrase:",
        };
    }
};

/// A key the window waits for instead of a binding.
pub const Await = enum { none, bookmark_set, bookmark_jump, bookmark_remove, confirm_delete, confirm_empty_trash, conflict };

gpa: Allocator,
app: *App,
window: siv.Window = .null,
closing: bool = false,

root: Node = .null,
header: Node = .null,
path_dir: Node = .null,
path_name: Node = .null,
tabs_row: Node = .null,
parent_col: Column,
current: Column,
preview: Preview,
parent_box: Node = .null,
preview_box: Node = .null,
current_box: Node = .null,
status_mode: Node = .null,
status_left: Node = .null,
status_keys: Node = .null,
status_right: Node = .null,
cmd_row: Node = .null,
cmd_label: Node = .null,
cmd_editor: Node = .null,
/// The masked editor that replaces cmd_editor for passphrases.
pass_editor: Node = .null,
/// The volume a passphrase is for.
unlock_block: std.ArrayList(u8) = .empty,
unlock_label: std.ArrayList(u8) = .empty,
unlock_new_tab: bool = false,
whichkey: Node = .null,

tabs: std.ArrayList(*Tab) = .empty,
active: usize = 0,

mode: keys.Mode = .normal,
visual_anchor: u32 = 0,
pending: [keys.max_keys]keys.Key = undefined,
pending_len: usize = 0,
count: ?u32 = null,
await_key: Await = .none,
conflict: ?*App.OpEntry = null,
/// What a delete confirmation will delete.
confirm_paths: std.ArrayList([]u8) = .empty,
prompt: ?PromptKind = null,
/// The cursor when a search or find started, to go back on Escape.
prompt_origin: u32 = 0,
/// For renames: the path being renamed.
prompt_target: std.ArrayList(u8) = .empty,
history_pos: usize = 0,
last_search: std.ArrayList(u8) = .empty,
last_search_back: bool = false,
/// A message in the status line until the next key.
message: std.ArrayList(u8) = .empty,
message_error: bool = false,

whichkey_timer: siv.Timer = .null,
last_input: u64 = 0,
/// The window's logical width (0 before the first configure).
width: f32 = 0,
/// What the parent column's names need, in logical pixels (0: unknown).
parent_fit: f32 = 0,
/// For measurements: frames presented, the first, and the first with the
/// current folder's rows.
frames: u64 = 0,
first_frame_ns: u64 = 0,
rows_frame_ns: u64 = 0,
rows_pending: bool = false,

var input_clock: u64 = 0;

pub fn create(app: *App, path: []const u8) !*Window {
    const gpa = app.gpa;
    const self = try gpa.create(Window);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .app = app,
        .parent_col = .{ .win = undefined, .kind = .parent },
        .current = .{ .win = undefined, .kind = .current },
        .preview = undefined,
    };
    self.parent_col.win = self;
    self.current.win = self;
    self.preview = Preview.init(self);
    self.window = try siv.windowCreate(app.app, .{
        .title = "Columns",
        .app_id = App.app_id,
        .width = app.opts.window_width,
        .height = app.opts.window_height,
        .min_width = 360,
        .min_height = 240,
        .user_data = self,
        .on_event = onWindowEvent,
        .destroy = onWindowDestroyed,
    });
    var size: siv.Size = .{};
    if (c.siv_window_get_size(self.window, &size) == .ok) self.width = size.width;
    try self.build();
    const t = self.addTab(path) orelse return error.OutOfMemory;
    _ = t;
    self.active = 0;
    self.showTab();
    _ = c.siv_node_focus(self.current.view);
    return self;
}

/// Closes the window (its destroy-notify frees the rest).
pub fn close(self: *Window) void {
    if (self.window != .null) _ = c.siv_window_destroy(self.window);
}

fn onWindowEvent(ud: ?*anyopaque, _: siv.Window, ev: *const siv.WindowEvent) callconv(.c) bool {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    switch (ev.type) {
        .resized => if (self.width != @as(f32, @floatFromInt(ev.width))) {
            self.width = @floatFromInt(ev.width);
            if (self.tabs.items.len != 0) if (self.begin()) |txn| {
                self.applyRatioTxn(txn);
                _ = commit(txn);
            };
        },
        .presented => {
            self.frames += 1;
            if (self.first_frame_ns == 0) self.first_frame_ns = ev.commit_ns;
            if (self.rows_pending) {
                self.rows_pending = false;
                if (self.rows_frame_ns == 0) self.rows_frame_ns = ev.commit_ns;
            }
        },
        else => {},
    }
    return false;
}

fn onWindowDestroyed(ud: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const gpa = self.gpa;
    self.window = .null;
    self.closing = true;
    if (self.whichkey_timer != .null) _ = c.siv_timer_cancel(self.whichkey_timer);
    if (self.conflict) |e| e.answer(.cancel, false);
    self.preview.deinit();
    if (self.parent_col.dir) |d| d.pins -= 1;
    if (self.current.dir) |d| d.pins -= 1;
    for (self.tabs.items) |t| freeTab(gpa, t);
    self.tabs.deinit(gpa);
    for (self.confirm_paths.items) |p| gpa.free(p);
    self.confirm_paths.deinit(gpa);
    self.prompt_target.deinit(gpa);
    self.unlock_block.deinit(gpa);
    self.unlock_label.deinit(gpa);
    self.last_search.deinit(gpa);
    self.message.deinit(gpa);
    self.app.windowClosed(self);
    gpa.destroy(self);
}

fn freeTab(gpa: Allocator, t: *Tab) void {
    t.dir.pins -= 1;
    for (t.history.items) |h| gpa.free(h);
    t.history.deinit(gpa);
    gpa.destroy(t);
}

pub fn begin(self: *Window) ?Txn {
    if (self.window == .null) return null;
    var txn: Txn = .null;
    if (c.siv_txn_begin(self.window, &txn) != .ok) return null;
    return txn;
}

const commit = ui.commit;
const px = ui.px;

// Building ----------------------------------------------------------------------------

fn build(self: *Window) !void {
    const txn = try siv.txnBegin(self.window);
    errdefer _ = c.siv_txn_abort(txn);
    self.root = c.siv_window_get_root(self.window);
    _ = c.siv_set_visual(txn, self.root, &.{ .background_token = .window_bg });
    // The keymap sees every key first, on its way down to the focused
    // row (whose own defaults would take Space and the arrows).
    _ = c.siv_on_capture(txn, self.root, .key, onKey, null, self);
    const main = c.siv_flex(txn, self.root, &.{ .axis = .column });
    _ = c.siv_set_layout(txn, main, &.{ .width = ui.fill(), .height = ui.fill() });

    // Header: the path, the hovered name, and the tabs.
    self.header = c.siv_flex(txn, main, &.{ .axis = .row, .gap = 0, .align_items = .center });
    _ = c.siv_set_layout(txn, self.header, &.{ .padding = .{ .start = 12, .end = 8, .top = 6, .bottom = 6 }, .min_height = 32 });
    // Paths read left to right in right-to-left layouts too.
    const path_box = c.siv_flex(txn, self.header, &.{ .axis = .row, .align_items = .center });
    _ = c.siv_set_layout(txn, path_box, &.{ .grow = 1, .basis = px(0), .direction = .ltr });
    self.path_dir = c.siv_text(txn, path_box, "", 0);
    _ = c.siv_set_text_style(txn, self.path_dir, &.{ .color_token = .accent, .size_role = .body, .weight = .bold, .flags = .{ .no_wrap = true, .ellipsize = true } });
    _ = c.siv_set_layout(txn, self.path_dir, &.{ .shrink = 1 });
    _ = c.siv_set_semantics(txn, self.path_dir, &.{ .role = .heading, .level = 1 });
    self.path_name = c.siv_text(txn, path_box, "", 0);
    _ = c.siv_set_text_style(txn, self.path_name, &.{ .color_token = .window_fg, .size_role = .body, .flags = .{ .no_wrap = true, .ellipsize = true } });
    _ = c.siv_set_layout(txn, self.path_name, &.{ .grow = 1, .basis = px(0), .shrink = 4 });
    self.tabs_row = c.siv_flex(txn, self.header, &.{ .axis = .row, .gap = 4, .align_items = .center });
    _ = c.siv_set_semantics(txn, self.tabs_row, &.{ .role = .tab_list, .label = "Tabs", .label_len = 4 });
    _ = c.siv_set_layout(txn, self.tabs_row, &.{ .flags = .{ .no_shrink = true } });

    // The columns.
    const cols = c.siv_flex(txn, main, &.{ .axis = .row });
    _ = c.siv_set_layout(txn, cols, &.{ .grow = 1, .basis = px(0), .width = ui.fill() });
    _ = c.siv_set_visual(txn, cols, &.{ .background_token = .view_bg });
    self.parent_box = c.siv_box(txn, cols);
    self.parent_col.build(txn, self.parent_box, "Parent folder");
    _ = ui.vrule(txn, cols);
    self.current_box = c.siv_box(txn, cols);
    self.current.build(txn, self.current_box, "Files");
    _ = ui.vrule(txn, cols);
    self.preview_box = c.siv_box(txn, cols);
    self.preview.build(txn, self.preview_box);
    self.applyRatioTxn(txn);
    const drop_mimes = "text/uri-list";
    _ = c.siv_set_drop_target(txn, self.current_box, &.{ .mimes = drop_mimes, .mimes_len = drop_mimes.len, .actions = .{ .copy = true, .move = true }, .preferred = .copy });
    _ = c.siv_on(txn, self.current_box, .drop, onDrop, null, self);

    // The status line.
    const status = c.siv_flex(txn, main, &.{ .axis = .row, .gap = 10, .align_items = .center });
    _ = c.siv_set_layout(txn, status, &.{ .padding = .{ .start = 8, .end = 12, .top = 3, .bottom = 3 }, .min_height = 26 });
    _ = c.siv_set_visual(txn, status, &.{ .background_token = .window_bg });
    _ = c.siv_set_semantics(txn, status, &.{ .role = .status, .flags = .{ .live_polite = true } });
    self.status_mode = c.siv_text(txn, status, "", 0);
    _ = c.siv_set_layout(txn, self.status_mode, &.{ .padding = .{ .start = 6, .end = 6, .top = 1, .bottom = 1 }, .flags = .{ .no_shrink = true } });
    _ = c.siv_set_visual(txn, self.status_mode, &.{ .background_token = .accent, .radius = .{ .top_start = 3, .top_end = 3, .bottom_start = 3, .bottom_end = 3 } });
    _ = c.siv_set_text_style(txn, self.status_mode, &.{ .color_token = .accent_fg, .size_role = .caption, .weight = .bold, .flags = .{ .no_wrap = true } });
    _ = c.siv_set_hidden(txn, self.status_mode, true);
    self.status_left = ui.text(txn, status, "", .muted_fg, .caption);
    _ = c.siv_set_layout(txn, self.status_left, &.{ .grow = 1, .basis = px(0) });
    self.status_keys = ui.text(txn, status, "", .accent, .caption);
    _ = c.siv_set_layout(txn, self.status_keys, &.{ .flags = .{ .no_shrink = true } });
    self.status_right = ui.text(txn, status, "", .muted_fg, .caption);
    _ = c.siv_set_layout(txn, self.status_right, &.{ .flags = .{ .no_shrink = true } });

    // The command line, under the status line while it is open.
    self.cmd_row = c.siv_flex(txn, main, &.{ .axis = .row, .gap = 4, .align_items = .center });
    _ = c.siv_set_layout(txn, self.cmd_row, &.{ .padding = .{ .start = 8, .end = 8, .top = 4, .bottom = 4 } });
    _ = c.siv_set_visual(txn, self.cmd_row, &.{ .background_token = .view_bg });
    self.cmd_label = c.siv_text(txn, self.cmd_row, ":", 1);
    _ = c.siv_set_text_style(txn, self.cmd_label, &.{ .color_token = .accent, .size_role = .body, .weight = .bold, .flags = .{ .no_wrap = true } });
    _ = c.siv_set_layout(txn, self.cmd_label, &.{ .flags = .{ .no_shrink = true } });
    self.cmd_editor = c.siv_editor(txn, self.cmd_row, .{});
    _ = c.siv_set_layout(txn, self.cmd_editor, &.{ .grow = 1, .basis = px(0) });
    _ = c.siv_set_text_style(txn, self.cmd_editor, &.{ .color_token = .view_fg, .size_role = .body });
    _ = c.siv_set_semantics(txn, self.cmd_editor, &.{ .role = .text_input, .label = "Command", .label_len = 7, .flags = .{ .focusable = true } });
    _ = c.siv_on(txn, self.cmd_editor, .key, onPromptKey, null, self);
    _ = c.siv_on(txn, self.cmd_editor, .change, onPromptChange, null, self);
    self.pass_editor = c.siv_editor(txn, self.cmd_row, .{ .masked = true });
    _ = c.siv_set_layout(txn, self.pass_editor, &.{ .grow = 1, .basis = px(0) });
    _ = c.siv_set_text_style(txn, self.pass_editor, &.{ .color_token = .view_fg, .size_role = .body });
    _ = c.siv_set_semantics(txn, self.pass_editor, &.{ .role = .text_input, .label = "Passphrase", .label_len = 10, .flags = .{ .focusable = true } });
    _ = c.siv_on(txn, self.pass_editor, .key, onPromptKey, null, self);
    _ = c.siv_set_hidden(txn, self.pass_editor, true);
    _ = c.siv_set_hidden(txn, self.cmd_row, true);

    // The which-key popup, over the columns at the bottom end.
    self.whichkey = c.siv_flex(txn, self.root, &.{ .axis = .column, .gap = 6 });
    _ = c.siv_set_layout(txn, self.whichkey, &.{
        .align_x = .end,
        .align_y = .end,
        .inset_end = 12,
        .inset_bottom = 34,
        .max_width = 760,
        .padding = .{ .start = 14, .end = 14, .top = 10, .bottom = 12 },
        .flags = .{ .inset_end = true, .inset_bottom = true },
    });
    _ = c.siv_set_visual(txn, self.whichkey, &.{ .background_token = .card_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 8, .top_end = 8, .bottom_start = 8, .bottom_end = 8 } });
    _ = c.siv_set_semantics(txn, self.whichkey, &.{ .role = .group, .label = "Keys", .label_len = 4 });
    _ = c.siv_set_hidden(txn, self.whichkey, true);
    try siv.txnCommit(txn);
}

/// Column widths from the ratio and the window's width: narrow windows
/// drop the parent column, then the preview; the parent widens to fit its
/// names (fit_parent).
fn applyRatioTxn(self: *Window, txn: Txn) void {
    const o = &self.app.options;
    const r = o.ratio;
    const narrow: f32 = @floatFromInt(o.narrow_width);
    const w = self.width;
    const show_parent = r[0] > 0 and (w == 0 or w >= narrow);
    const show_preview = o.preview and r[2] > 0 and (w == 0 or w >= narrow * 2 / 3);
    // Fitting the parent fixes it and the current column at their widths
    // and leaves the rest to the preview, so only the preview narrows.
    var parent_px: f32 = 0;
    var current_px: f32 = 0;
    if (show_parent and show_preview and o.fit_parent and w > 0 and self.parent_fit > 0) {
        const total = r[0] + @max(r[1], 0.1) + r[2];
        const share = w * r[0] / total;
        parent_px = std.math.clamp(self.parent_fit, share, @max(share, w / 4));
        current_px = w * @max(r[1], 0.1) / total;
    }
    if (parent_px > 0) {
        _ = c.siv_set_layout(txn, self.parent_box, &.{ .basis = px(parent_px), .height = ui.fill(), .min_width = 0, .flags = .{ .no_shrink = true } });
        _ = c.siv_set_layout(txn, self.current_box, &.{ .basis = px(current_px), .height = ui.fill(), .flags = .{ .no_shrink = true } });
    } else {
        _ = c.siv_set_layout(txn, self.parent_box, &.{ .grow = r[0], .basis = px(0), .height = ui.fill(), .min_width = 0 });
        _ = c.siv_set_layout(txn, self.current_box, &.{ .grow = @max(r[1], 0.1), .basis = px(0), .height = ui.fill() });
    }
    _ = c.siv_set_hidden(txn, self.parent_box, !show_parent);
    _ = c.siv_set_hidden(txn, c.siv_node_get_related(self.parent_box, .next), !show_parent);
    _ = c.siv_set_layout(txn, self.preview_box, &.{ .grow = r[2], .basis = px(0), .height = ui.fill() });
    _ = c.siv_set_hidden(txn, self.preview_box, !show_preview);
    _ = c.siv_set_hidden(txn, c.siv_node_get_related(self.preview_box, .previous), !show_preview);
    _ = c.siv_set_layout(txn, self.parent_col.root, &.{ .width = ui.fill(), .height = ui.fill() });
    _ = c.siv_set_layout(txn, self.current.root, &.{ .width = ui.fill(), .height = ui.fill() });
    _ = c.siv_set_layout(txn, self.preview.root, &.{ .width = ui.fill(), .height = ui.fill() });
}

/// The width the parent column needs for its longest names: the few
/// longest in bytes are measured, so a 100 000-entry parent costs one
/// pass over its names and a dozen measurements. 0 while it reads.
fn fitWidth(self: *Window, d: ?*Dir) f32 {
    const dir = d orelse return 0;
    const l = if (dir.listing) |*l| l else return 0;
    if (!dir.loaded) return 0;
    const k = 12;
    var longest: [k]u32 = undefined;
    var lens: [k]usize = @splat(0);
    var n: usize = 0;
    for (dir.visible.items) |i| {
        const len = l.base(l.entries[i]).len;
        if (n < k) {
            longest[n] = i;
            lens[n] = len;
            n += 1;
            continue;
        }
        const min_at = std.mem.indexOfMin(usize, &lens);
        if (len > lens[min_at]) {
            longest[min_at] = i;
            lens[min_at] = len;
        }
    }
    var widest: f32 = 0;
    for (longest[0..n]) |i| {
        const name = l.base(l.entries[i]);
        var m: siv.TextMetrics = .{};
        if (c.siv_app_measure_text(self.app.app, name.ptr, name.len, 1e6, &.{ .size_role = .body, .weight = .bold, .flags = .{ .no_wrap = true } }, &m) == .ok)
            widest = @max(widest, m.width);
    }
    if (widest == 0) return 0;
    // The row around the name: its padding, the mark, the icon, and the
    // gaps between them (Column.bindRow).
    const icon: f32 = if (self.app.options.icons) 16 + 6 else 0;
    return widest + 1 + 8 + 3 + 6 + icon + 6 + 10;
}

/// Measures the parent column's names again and widens or narrows it.
fn refitParent(self: *Window, txn: Txn) void {
    const fit = self.fitWidth(self.parent_col.dir);
    if (fit == self.parent_fit) return;
    self.parent_fit = fit;
    self.applyRatioTxn(txn);
}

// Tabs ------------------------------------------------------------------------------------

pub fn tab(self: *Window) *Tab {
    return self.tabs.items[self.active];
}

pub fn curDir(self: *Window) *Dir {
    return self.tab().dir;
}

fn addTab(self: *Window, path_in: []const u8) ?*Tab {
    var nbuf: [linux.PATH_MAX]u8 = undefined;
    var path = model.normalize(&nbuf, path_in);
    // A file: its folder, with the file under the cursor.
    var select: ?[]const u8 = null;
    if (!isDirPath(path) and isPath(path)) {
        select = model.basename(path);
        path = model.parent(path);
    }
    const d = self.app.cache.get(path, self.app.options.stale_ms) orelse return null;
    if (select) |s| d.selectName(s);
    const t = self.gpa.create(Tab) catch return null;
    t.* = .{ .dir = d };
    d.pins += 1;
    self.tabs.append(self.gpa, t) catch {
        freeTab(self.gpa, t);
        return null;
    };
    const copy = self.gpa.dupe(u8, d.path) catch return t;
    t.history.append(self.gpa, copy) catch self.gpa.free(copy);
    return t;
}

pub fn newTab(self: *Window, path: []const u8) void {
    _ = self.addTab(path) orelse return;
    self.active = self.tabs.items.len - 1;
    self.showTab();
}

/// A new tab on `path`'s folder with `path` under the cursor, folders
/// included (ShowItems).
pub fn newTabSelecting(self: *Window, path: []const u8) void {
    _ = self.addTab(model.parent(path)) orelse return;
    self.active = self.tabs.items.len - 1;
    self.curDir().selectName(model.basename(path));
    self.showTab();
}

pub fn selectTab(self: *Window, i: usize) void {
    if (i >= self.tabs.items.len) return;
    self.endVisual();
    self.active = i;
    self.showTab();
}

pub fn closeTab(self: *Window) void {
    if (self.tabs.items.len <= 1) return self.close();
    const t = self.tabs.orderedRemove(self.active);
    if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1;
    self.endVisual();
    self.showTab();
    freeTab(self.gpa, t);
}

fn applyTabs(self: *Window, txn: Txn) void {
    ui.clear(txn, self.tabs_row);
    if (self.tabs.items.len < 2) return;
    for (self.tabs.items, 0..) |t, i| {
        var buf: [96]u8 = undefined;
        const name = if (std.mem.eql(u8, t.path(), self.app.home)) "~" else model.basename(t.path());
        const label = std.fmt.bufPrint(&buf, "{d} {s}", .{ i + 1, name }) catch "";
        const on = i == self.active;
        const b = c.siv_text(txn, self.tabs_row, label.ptr, label.len);
        _ = c.siv_set_text_style(txn, b, &.{ .color_token = if (on) .accent_fg else .muted_fg, .size_role = .caption, .weight = if (on) .bold else .regular, .flags = .{ .no_wrap = true } });
        _ = c.siv_set_layout(txn, b, &.{ .padding = .{ .start = 8, .end = 8, .top = 2, .bottom = 2 }, .max_width = 160 });
        _ = c.siv_set_visual(txn, b, &.{ .background_token = if (on) .accent else .control_bg, .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 } });
        _ = c.siv_set_semantics(txn, b, &.{ .role = .tab, .selected = if (on) .on else .off });
        _ = c.siv_on(txn, b, .pointer, onTabPointer, null, self);
    }
}

fn onTabPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    if (ev.phase != .down) return .pass;
    var i: usize = 0;
    var cur = c.siv_node_get_related(self.tabs_row, .first_child);
    while (cur != .null and cur != node) : (cur = c.siv_node_get_related(cur, .next)) i += 1;
    if (ev.button == .middle) {
        self.active = i;
        self.closeTab();
    } else self.selectTab(i);
    return .handled;
}

// Showing ----------------------------------------------------------------------------------

/// Shows the active tab: its folder, the parent, and the preview.
pub fn showTab(self: *Window) void {
    const t = self.tab();
    const d = t.dir;
    _ = d.sync();
    const app = self.app;
    var pd: ?*Dir = null;
    if (!std.mem.eql(u8, d.path, "/")) {
        pd = app.cache.get(model.parent(d.path), app.options.stale_ms);
        if (pd) |p| {
            _ = p.sync();
            p.selectName(model.basename(d.path));
        }
    }
    const txn = self.begin() orelse return;
    self.current.show(txn, d);
    self.parent_col.show(txn, pd);
    self.refitParent(txn);
    self.updatePreviewTxn(txn);
    self.applyTabs(txn);
    self.applyHeader(txn);
    self.applyStatus(txn);
    _ = commit(txn);
    _ = c.siv_window_set_title(self.window, d.path.ptr, d.path.len);
}

fn updatePreviewTxn(self: *Window, txn: Txn) void {
    const d = self.curDir();
    if (!self.app.options.preview or d.count() == 0) return self.preview.clear(txn);
    self.preview.showEntry(txn, d, d.cursor);
}

/// A directory finished reading: columns showing it follow.
pub fn dirLoaded(self: *Window, d: *Dir) void {
    if (self.tabs.items.len == 0) return;
    const cur = self.curDir();
    const txn = self.begin() orelse return;
    if (d == cur) {
        if (d.count() > 0) self.rows_pending = true;
        if (self.mode == .visual) self.visual_anchor = @min(self.visual_anchor, d.count() -| 1);
        self.current.refresh(txn);
        self.current.rebind(txn);
        self.updatePreviewTxn(txn);
        self.applyHeader(txn);
        self.applyStatus(txn);
    }
    if (self.parent_col.dir == d) {
        d.selectName(model.basename(cur.path));
        self.parent_col.refresh(txn);
        self.refitParent(txn);
    }
    if (self.preview.column.dir == d) {
        self.preview.column.refresh(txn);
    }
    _ = commit(txn);
}

/// Sort, hidden files, icons, ratio, or the preview changed.
pub fn optionsChanged(self: *Window) void {
    if (self.tabs.items.len == 0) return;
    const txn = self.begin() orelse return;
    self.applyRatioTxn(txn);
    _ = commit(txn);
    for ([_]?*Dir{ self.curDir(), self.parent_col.dir, self.preview.column.dir }) |dd| if (dd) |d| {
        _ = d.sync();
    };
    // The parent's cursor stays on the current folder.
    if (self.parent_col.dir) |p| p.selectName(model.basename(self.curDir().path));
    const t2 = self.begin() orelse return;
    self.current.refresh(t2);
    self.current.rebind(t2);
    self.parent_col.refresh(t2);
    self.parent_col.rebind(t2);
    self.parent_fit = self.fitWidth(self.parent_col.dir);
    self.applyRatioTxn(t2);
    if (self.preview.column.dir != null) {
        self.preview.column.refresh(t2);
        self.preview.column.rebind(t2);
    }
    self.updatePreviewTxn(t2);
    self.applyStatus(t2);
    self.applyHeader(t2);
    _ = commit(t2);
}

pub fn refreshRows(self: *Window) void {
    const txn = self.begin() orelse return;
    self.current.rebind(txn);
    self.parent_col.rebind(txn);
    _ = commit(txn);
}

fn applyHeader(self: *Window, txn: Txn) void {
    const d = self.curDir();
    var buf: [linux.PATH_MAX + 8]u8 = undefined;
    const home = self.app.home;
    var shown: []const u8 = d.path;
    if (std.mem.eql(u8, d.path, home)) {
        shown = "~";
    } else if (model.isWithin(d.path, home) and home.len > 1) {
        shown = std.fmt.bufPrint(&buf, "~{s}", .{d.path[home.len..]}) catch d.path;
    }
    var dbuf: [linux.PATH_MAX + 8]u8 = undefined;
    const dir_text = if (std.mem.eql(u8, shown, "/")) "/" else std.fmt.bufPrint(&dbuf, "{s}/", .{shown}) catch shown;
    if (d.isTrash()) {
        _ = c.siv_set_text(txn, self.path_dir, "Trash/", 6);
    } else _ = c.siv_set_text(txn, self.path_dir, dir_text.ptr, dir_text.len);
    const name = d.nameAt(d.cursor) orelse "";
    const base = model.basename(name);
    _ = c.siv_set_text(txn, self.path_name, base.ptr, if (name.len == 0) 0 else base.len);
}

/// The status line: the mode, the entry's details, pending keys, and
/// where the cursor is.
fn applyStatus(self: *Window, txn: Txn) void {
    const d = self.curDir();
    const app = self.app;
    // The mode badge.
    const mode_text: []const u8 = if (self.mode == .visual) "VISUAL" else if (self.prompt != null) "" else "";
    _ = c.siv_set_text(txn, self.status_mode, mode_text.ptr, mode_text.len);
    _ = c.siv_set_hidden(txn, self.status_mode, mode_text.len == 0);
    // Left: a message, the question being asked, or the entry's details.
    var lbuf: [512]u8 = undefined;
    var left: []const u8 = "";
    var left_token: siv.ColorToken = .muted_fg;
    if (self.await_key != .none) {
        left = self.questionText(&lbuf);
        left_token = .window_fg;
    } else if (self.message.items.len != 0) {
        left = self.message.items;
        left_token = if (self.message_error) .destructive else .window_fg;
    } else if (d.current()) |e| {
        var mb: [9]u8 = undefined;
        var sb: [32]u8 = undefined;
        var tb: [32]u8 = undefined;
        const tz = if (app.opts.reproducible) 0 else app.tz_offset_s;
        const kind: u8 = switch (e.kind) {
            .dir => 'd',
            .file => if (e.link) 'l' else '-',
            .other => if (e.link) 'l' else '?',
        };
        const size = if (e.kind == .dir) (if (d.trash_info != null) "" else "") else model.formatSize(&sb, e.size);
        left = std.fmt.bufPrint(&lbuf, "{c}{s}   {s}{s}{s}", .{ kind, model.formatMode(&mb, e.mode), size, if (size.len != 0) "   " else "", model.formatTime(&tb, e.mtime, tz) }) catch "";
    } else if (d.err) |_| {
        left = "Cannot read this folder";
    }
    _ = c.siv_set_text(txn, self.status_left, left.ptr, left.len);
    _ = c.siv_set_text_style(txn, self.status_left, &.{ .color_token = left_token, .size_role = .caption, .direction = .ltr, .flags = .{ .no_wrap = true, .ellipsize = true } });
    // Pending keys and count.
    var kbuf: [64]u8 = undefined;
    var kw: std.Io.Writer = .fixed(&kbuf);
    if (self.count) |n| kw.print("{d}", .{n}) catch {};
    var fbuf: [48]u8 = undefined;
    kw.writeAll(keys.format(&fbuf, self.pending[0..self.pending_len])) catch {};
    const ktext = kw.buffered();
    _ = c.siv_set_text(txn, self.status_keys, ktext.ptr, ktext.len);
    // Right: operations, marks, filter, sort, and the position.
    var rbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    if (app.ops.items.len != 0) {
        const op = app.ops.items[0].op;
        const total = op.total_bytes.load(.monotonic);
        const done = op.done_bytes.load(.monotonic);
        const verb = fsops.doing(op.kind);
        const items = op.total_items.load(.monotonic);
        if (op.asking.load(.acquire)) {
            w.print("{s}: waiting   ", .{verb}) catch {};
        } else if (total > 0) {
            w.print("{s} {d}%   ", .{ verb, done * 100 / total }) catch {};
        } else if (items > 0 and !op.scanning.load(.acquire)) {
            w.print("{s} {d}%   ", .{ verb, @min(100, @as(u64, op.done_items.load(.monotonic)) * 100 / items) }) catch {};
        } else w.print("{s}…   ", .{verb}) catch {};
    }
    if (self.mode == .visual) {
        const lo = @min(self.visual_anchor, d.cursor);
        const hi = @max(self.visual_anchor, d.cursor);
        w.print("{d} in range   ", .{hi - lo + 1}) catch {};
    }
    if (d.mark_count != 0) w.print("{d} marked   ", .{d.mark_count}) catch {};
    if (app.register.items.len != 0) w.print("{d} {s}   ", .{ app.register.items.len, if (app.register_cut) "cut" else "copied" }) catch {};
    if (d.filter.items.len != 0) w.print("filter: {s}   ", .{d.filter.items}) catch {};
    if (app.options.show_hidden) w.writeAll("hidden   ") catch {};
    const s = app.options.sort;
    if (s.key != .name or s.descending) w.print("{s}{s}   ", .{ @tagName(s.key), if (s.descending) " ↓" else "" }) catch {};
    if (d.count() != 0) w.print("{d}/{d}", .{ d.cursor + 1, d.count() }) catch {} else w.writeAll("0/0") catch {};
    const right = w.buffered();
    _ = c.siv_set_text(txn, self.status_right, right.ptr, right.len);
}

pub fn updateStatus(self: *Window) void {
    if (self.tabs.items.len == 0) return;
    const txn = self.begin() orelse return;
    self.applyStatus(txn);
    _ = commit(txn);
}

fn questionText(self: *Window, buf: []u8) []const u8 {
    return switch (self.await_key) {
        .none => "",
        .bookmark_set => "Set a bookmark: press a key",
        .bookmark_jump => "Go to a bookmark: press its key",
        .bookmark_remove => "Remove a bookmark: press its key",
        .confirm_delete => std.fmt.bufPrint(buf, "Delete {d} item{s} permanently? y/N", .{ self.confirm_paths.items.len, if (self.confirm_paths.items.len == 1) "" else "s" }) catch "",
        .confirm_empty_trash => "Empty the trash? Everything in it is deleted permanently. y/N",
        .conflict => blk: {
            const e = self.conflict orelse break :blk "";
            break :blk std.fmt.bufPrint(buf, "“{s}” exists: (r)eplace (s)kip (k)eep both{s} (c)ancel — Shift for all", .{ model.basename(e.op.conflict.dstPath()), if (e.op.conflict.src_dir and e.op.conflict.dst_dir) " (m)erge" else "" }) catch "";
        },
    };
}

/// A message in the status line, which screen readers announce (it is a
/// live region), until the next key; errors in the error color.
/// `:messages` lists them afterwards.
pub fn notify(self: *Window, msg: []const u8, is_error: bool) void {
    self.app.logMessage(msg, is_error);
    self.message.clearRetainingCapacity();
    self.message.appendSlice(self.gpa, msg) catch {};
    self.message_error = is_error;
    if (self.tabs.items.len == 0) return;
    const txn = self.begin() orelse return;
    self.applyStatus(txn);
    _ = commit(txn);
}

// Moving -------------------------------------------------------------------------------------

/// Puts the cursor on shown entry `to` (clamped), and the preview
/// follows.
pub fn moveCursor(self: *Window, to: i64) void {
    const d = self.curDir();
    const n = d.count();
    if (n == 0) return;
    const i: u32 = @intCast(std.math.clamp(to, 0, @as(i64, n) - 1));
    const moved = i != d.cursor;
    d.setCursor(i);
    const txn = self.begin() orelse return;
    self.current.placeCursor(txn, i, true);
    if (self.mode == .visual and moved) self.current.rebind(txn);
    self.updatePreviewTxn(txn);
    self.applyHeader(txn);
    self.applyStatus(txn);
    _ = commit(txn);
}

pub fn moveBy(self: *Window, delta: i64) void {
    self.moveCursor(@as(i64, self.curDir().cursor) + delta);
}

/// Rows a page shows.
pub fn pageRows(self: *Window) u32 {
    var r: siv.Rect = .{};
    if (c.siv_node_get_rect(self.current.view, &r) != .ok or r.height <= 0) return 20;
    return @max(1, @as(u32, @intFromFloat(r.height / Column.row_height)));
}

/// Shows `path`, with the cursor where it was there last (or on
/// `select`), and records it in the tab's history.
pub fn cd(self: *Window, path: []const u8) void {
    self.cdSelect(path, null, true);
}

pub fn cdSelect(self: *Window, path_in: []const u8, select: ?[]const u8, record: bool) void {
    var nbuf: [linux.PATH_MAX]u8 = undefined;
    var ebuf: [linux.PATH_MAX]u8 = undefined;
    const expanded = self.expandPath(&ebuf, path_in);
    const path = model.normalize(&nbuf, expanded);
    if (!isDirPath(path) and !std.mem.eql(u8, path, self.app.places.trash_files)) {
        // A file: go to its folder and put the cursor on it.
        if (isPath(path)) return self.cdSelect(model.parent(path), model.basename(path), record);
        var mbuf: [linux.PATH_MAX + 32]u8 = undefined;
        self.notify(std.fmt.bufPrint(&mbuf, "No such folder: {s}", .{path}) catch "No such folder", true);
        return;
    }
    const t = self.tab();
    const old = t.dir;
    const d = self.app.cache.get(path, self.app.options.stale_ms) orelse return;
    if (select) |s| d.selectName(s);
    // Going up: the cursor on the folder we came from.
    if (select == null and d != old and model.isWithin(old.path, d.path)) {
        const rest = old.path[if (std.mem.eql(u8, d.path, "/")) 1 else d.path.len + 1 ..];
        const first = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
        if (first.len != 0) d.selectName(first);
    }
    if (d != old) {
        self.endVisual();
        d.pins += 1;
        old.pins -= 1;
        t.dir = d;
        if (record) self.pushHistory(t, d.path);
    }
    self.showTab();
    if (self.app.lua) |l| l.emit("cd", d.path);
}

fn pushHistory(self: *Window, t: *Tab, path: []const u8) void {
    const gpa = self.gpa;
    if (t.history.items.len > 0) {
        for (t.history.items[t.history_pos + 1 ..]) |h| gpa.free(h);
        t.history.shrinkRetainingCapacity(t.history_pos + 1);
        if (std.mem.eql(u8, t.history.items[t.history_pos], path)) return;
    }
    const copy = gpa.dupe(u8, path) catch return;
    t.history.append(gpa, copy) catch {
        gpa.free(copy);
        return;
    };
    t.history_pos = t.history.items.len - 1;
    // Bounded.
    while (t.history.items.len > 100) {
        gpa.free(t.history.orderedRemove(0));
        t.history_pos -= 1;
    }
}

pub fn historyMove(self: *Window, delta: i32) void {
    const t = self.tab();
    const pos: i64 = @as(i64, @intCast(t.history_pos)) + delta;
    if (pos < 0 or pos >= t.history.items.len) return;
    t.history_pos = @intCast(pos);
    self.cdSelect(t.history.items[t.history_pos], null, false);
}

/// "~" and $VARIABLES, and relative paths against the current folder.
pub fn expandPath(self: *Window, buf: []u8, p: []const u8) []const u8 {
    const home = self.app.home;
    if (p.len == 0) return home;
    if (std.mem.eql(u8, p, "~")) return home;
    if (std.mem.startsWith(u8, p, "~/")) return std.fmt.bufPrint(buf, "{s}{s}", .{ home, p[1..] }) catch p;
    if (p[0] == '$') {
        const end = std.mem.indexOfScalar(u8, p, '/') orelse p.len;
        var nb: [128]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&nb, "{s}", .{p[1..end]}, 0) catch return p;
        const v = getenv(name.ptr) orelse return p;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ std.mem.span(v), p[end..] }) catch p;
    }
    if (p[0] != '/') return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.curDir().path, p }) catch p;
    return p;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn isDirPath(path: []const u8) bool {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

pub fn isPath(path: []const u8) bool {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
}

/// After an undo: put the cursor on `path` once its folder reloads.
pub fn selectAfterLoad(self: *Window, path: []const u8) void {
    const d = self.curDir();
    if (std.mem.eql(u8, d.path, model.parent(path))) d.selectName(model.basename(path));
}

/// l: enter the folder under the cursor, or open the file.
pub fn enter(self: *Window) void {
    const d = self.curDir();
    const e = d.current() orelse return;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, d.cursor) orelse return;
    if (e.kind == .dir) return self.cd(p);
    self.openTargets();
}

/// h: the parent folder.
pub fn leave(self: *Window) void {
    const d = self.curDir();
    if (d.isTrash()) return self.cd(self.app.home);
    if (std.mem.eql(u8, d.path, "/")) return;
    self.cd(model.parent(d.path));
}

/// Opens the targets with their default applications.
pub fn openTargets(self: *Window) void {
    const paths = self.targets() catch return;
    defer App.freePaths(self.gpa, paths);
    if (paths.len == 0) return;
    if (paths.len == 1 and isDirPath(paths[0])) return self.cd(paths[0]);
    self.app.openPaths(self, toConst(paths), null);
}

pub fn toConst(paths: [][]u8) []const []const u8 {
    return @ptrCast(paths);
}

// Marks and visual mode ----------------------------------------------------------------------

pub fn inVisualRange(self: *Window, col: *const Column, i: u32) bool {
    if (self.mode != .visual or col != &self.current) return false;
    const d = self.curDir();
    const lo = @min(self.visual_anchor, d.cursor);
    const hi = @max(self.visual_anchor, d.cursor);
    return i >= lo and i <= hi;
}

pub fn startVisual(self: *Window) void {
    self.mode = .visual;
    self.visual_anchor = self.curDir().cursor;
    self.rebindCurrent();
}

/// Leaves visual mode; with `keep`, the range becomes marks.
pub fn finishVisual(self: *Window, keep: bool) void {
    if (self.mode != .visual) return;
    const d = self.curDir();
    if (keep) {
        const lo = @min(self.visual_anchor, d.cursor);
        const hi = @max(self.visual_anchor, d.cursor);
        var i = lo;
        while (i <= hi) : (i += 1) d.setMark(i, true);
    }
    self.mode = .normal;
    self.rebindCurrent();
}

fn endVisual(self: *Window) void {
    self.mode = .normal;
}

pub fn rebindCurrent(self: *Window) void {
    const txn = self.begin() orelse return;
    self.current.rebind(txn);
    self.applyStatus(txn);
    _ = commit(txn);
}

/// What commands act on: the visual range, else the marked entries, else
/// the entry under the cursor. Absolute paths; free with App.freePaths.
pub fn targets(self: *Window) ![][]u8 {
    const d = self.curDir();
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| self.gpa.free(p);
        out.deinit(self.gpa);
    }
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    if (self.mode == .visual) {
        const lo = @min(self.visual_anchor, d.cursor);
        const hi = @max(self.visual_anchor, d.cursor);
        var i = lo;
        while (i <= hi) : (i += 1) if (d.pathAt(&pbuf, i)) |p| try out.append(self.gpa, try self.gpa.dupe(u8, p));
    } else if (d.mark_count != 0) {
        const marked = try d.markedIndices(self.gpa);
        defer self.gpa.free(marked);
        for (marked) |i| if (d.pathAt(&pbuf, i)) |p| try out.append(self.gpa, try self.gpa.dupe(u8, p));
    } else if (d.pathAt(&pbuf, d.cursor)) |p| {
        try out.append(self.gpa, try self.gpa.dupe(u8, p));
    }
    return out.toOwnedSlice(self.gpa);
}

/// After acting on the targets: visual mode ends and marks clear.
pub fn consumeTargets(self: *Window) void {
    const d = self.curDir();
    self.mode = .normal;
    d.clearMarks();
    self.rebindCurrent();
}

// Keys -------------------------------------------------------------------------------------

/// Every key, captured at the root before the focused node: the keymap
/// handles what it binds and passes the rest (and everything while a
/// prompt's editor has focus).
fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .pass;
    input_clock += 1;
    self.last_input = input_clock;
    if (self.prompt != null or self.tabs.items.len == 0) return .pass;
    const m = ev.modifiers;
    const text = if (ev.text) |t| t[0..ev.text_len] else "";
    const keysym: u32 = @bitCast(@intFromEnum(ev.keysym));
    const k = keys.fromEvent(keysym, text, m.ctrl, m.alt, m.super, m.shift) orelse return .pass;
    return if (self.handleKey(k)) .handled else .pass;
}

/// One key in normal or visual mode; true if it meant something.
pub fn handleKey(self: *Window, k: keys.Key) bool {
    if (self.message.items.len != 0) self.message.clearRetainingCapacity();
    // A key the window asked for.
    if (self.await_key != .none) {
        self.answerAwait(k);
        return true;
    }
    if (k.code == keys.sym.escape and k.mods.ctrl == false and self.pending_len != 0) {
        self.resetPending();
        return true;
    }
    // Counts.
    if (self.pending_len == 0 and k.isChar() and k.code >= '0' and k.code <= '9' and (k.code != '0' or self.count != null)) {
        const digit: u32 = k.code - '0';
        self.count = (self.count orelse 0) *| 10 +| digit;
        self.updateStatus();
        return true;
    }
    if (self.pending_len >= keys.max_keys) self.resetPending();
    self.pending[self.pending_len] = k;
    self.pending_len += 1;
    const match = self.app.keymap.lookup(self.mode, self.pending[0..self.pending_len]);
    if (match.exact) |b| if (!match.prefix) {
        const count = self.count;
        const action = b.action;
        self.resetPending();
        self.run(action, count);
        return true;
    };
    if (match.prefix) {
        self.scheduleWhichKey();
        self.updateStatus();
        return true;
    }
    // Nothing: the keys so far mean nothing together.
    const was_pending = self.pending_len > 1;
    self.resetPending();
    return was_pending or !(k.code == keys.sym.tab and @as(u8, @bitCast(k.mods)) == 0);
}

fn resetPending(self: *Window) void {
    self.pending_len = 0;
    self.count = null;
    self.hideWhichKey();
    self.updateStatus();
}

/// Runs a binding's action with a count.
pub fn run(self: *Window, action: keys.Action, count: ?u32) void {
    switch (action) {
        .command => |line| commands.execute(self, line, count, true),
        .lua => |ref| if (self.app.lua) |l| l.callBinding(self, ref, count),
    }
}

fn scheduleWhichKey(self: *Window) void {
    if (self.whichkey_timer != .null) _ = c.siv_timer_cancel(self.whichkey_timer);
    self.whichkey_timer = .null;
    const delay = self.app.options.which_key_delay;
    if (delay == 0) return self.showWhichKey();
    _ = c.siv_timer_start(self.app.app, delay, onWhichKeyTimer, null, self, &self.whichkey_timer);
}

fn onWhichKeyTimer(ud: ?*anyopaque) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    self.whichkey_timer = .null;
    if (self.pending_len != 0 or self.await_key == .bookmark_jump or self.await_key == .bookmark_remove) self.showWhichKey();
}

const Hint = struct { key: []const u8, desc: []const u8 };

/// The popup of what the pending keys can continue with (or the
/// bookmarks, while waiting for one).
pub fn showWhichKey(self: *Window) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var hints: std.ArrayList(Hint) = .empty;
    var title: []const u8 = "";
    if (self.await_key == .bookmark_jump or self.await_key == .bookmark_remove or self.await_key == .bookmark_set) {
        title = "Bookmarks";
        var it = self.app.bookmarks.iterator();
        while (it.next()) |kv| {
            var kb: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(kv.key_ptr.*), &kb) catch continue;
            hints.append(a, .{ .key = a.dupe(u8, kb[0..n]) catch continue, .desc = self.shortPath(a, kv.value_ptr.*) }) catch {};
        }
        if (hints.items.len == 0) hints.append(a, .{ .key = "", .desc = "No bookmarks yet: m and a key sets one" }) catch {};
    } else {
        const conts = self.app.keymap.continuations(a, self.mode, self.pending[0..self.pending_len]) catch return;
        var fbuf: [48]u8 = undefined;
        title = a.dupe(u8, keys.format(&fbuf, self.pending[0..self.pending_len])) catch "";
        for (conts) |b| {
            const rest = b.keys[self.pending_len..];
            var kb: [64]u8 = undefined;
            const ks = keys.format(&kb, rest[0..@min(rest.len, 1)]);
            const more = rest.len > 1;
            const desc = if (more) "+more" else if (b.desc.len != 0) b.desc else switch (b.action) {
                .command => |cmd| cmd,
                .lua => "Lua function",
            };
            hints.append(a, .{ .key = a.dupe(u8, ks) catch continue, .desc = desc }) catch {};
        }
    }
    const txn = self.begin() orelse return;
    ui.clear(txn, self.whichkey);
    const t = c.siv_text(txn, self.whichkey, title.ptr, title.len);
    _ = c.siv_set_text_style(txn, t, &.{ .color_token = .accent, .size_role = .body, .weight = .bold });
    // Up to three columns of key and description.
    const cols: usize = if (hints.items.len > 16) 3 else if (hints.items.len > 6) 2 else 1;
    var tracks: [6]siv.Track = undefined;
    for (0..cols) |i| {
        tracks[i * 2] = .{ .unit = .auto };
        tracks[i * 2 + 1] = .{ .unit = .auto };
    }
    const grid = c.siv_grid(txn, self.whichkey, &.{ .columns = &tracks, .columns_count = cols * 2, .column_gap = 12, .row_gap = 3 });
    const rows = (hints.items.len + cols - 1) / cols;
    for (0..rows) |r| for (0..cols) |col| {
        const idx = col * rows + r;
        if (idx >= hints.items.len) continue;
        const h = hints.items[idx];
        const kn = c.siv_text(txn, grid, h.key.ptr, h.key.len);
        _ = c.siv_set_text_style(txn, kn, &.{ .color_token = .accent, .size_role = .body, .weight = .bold, .family = "monospace", .family_len = 9, .flags = .{ .no_wrap = true } });
        _ = c.siv_set_layout(txn, kn, &.{ .column = @intCast(col * 2 + 1), .row = @intCast(r + 1) });
        const dn = c.siv_text(txn, grid, h.desc.ptr, h.desc.len);
        _ = c.siv_set_text_style(txn, dn, &.{ .color_token = .card_fg, .size_role = .body, .flags = .{ .no_wrap = true, .ellipsize = true } });
        _ = c.siv_set_layout(txn, dn, &.{ .column = @intCast(col * 2 + 2), .row = @intCast(r + 1), .max_width = 240 });
    };
    _ = c.siv_set_hidden(txn, self.whichkey, false);
    _ = commit(txn);
}

fn shortPath(self: *Window, a: Allocator, p: []const u8) []const u8 {
    const home = self.app.home;
    if (std.mem.eql(u8, p, home)) return "~";
    if (home.len > 1 and model.isWithin(p, home)) return std.fmt.allocPrint(a, "~{s}", .{p[home.len..]}) catch p;
    return p;
}

pub fn hideWhichKey(self: *Window) void {
    if (self.whichkey_timer != .null) _ = c.siv_timer_cancel(self.whichkey_timer);
    self.whichkey_timer = .null;
    if (!self.isWhichKeyShown()) return;
    const txn = self.begin() orelse return;
    _ = c.siv_set_hidden(txn, self.whichkey, true);
    _ = commit(txn);
}

pub fn isWhichKeyShown(self: *Window) bool {
    var hidden = true;
    _ = c.siv_node_is_hidden(self.whichkey, &hidden);
    return !hidden;
}

// Waiting for a key --------------------------------------------------------------------------

pub fn awaitKey(self: *Window, what: Await) void {
    self.await_key = what;
    if (what == .bookmark_jump or what == .bookmark_remove) self.scheduleWhichKey();
    self.updateStatus();
}

fn answerAwait(self: *Window, k: keys.Key) void {
    const what = self.await_key;
    self.await_key = .none;
    self.hideWhichKey();
    const esc = k.code == keys.sym.escape;
    switch (what) {
        .none => {},
        .bookmark_set => if (!esc and k.isChar()) {
            const d = self.curDir();
            self.app.setBookmark(k.code, d.path);
            var buf: [64]u8 = undefined;
            var kb: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(k.code), &kb) catch 0;
            self.notify(std.fmt.bufPrint(&buf, "Bookmark '{s}' set", .{kb[0..n]}) catch "Bookmark set", false);
        },
        .bookmark_jump => if (!esc) {
            if (k.code == '\'' or k.code == '`') {
                // '' goes back where the last jump came from.
                self.historyMove(-1);
            } else if (self.app.bookmarks.get(k.code)) |p| {
                self.cd(p);
            } else self.notify("No such bookmark", true);
        },
        .bookmark_remove => if (!esc) {
            if (!self.app.removeBookmark(k.code)) self.notify("No such bookmark", true) else self.notify("Bookmark removed", false);
        },
        .confirm_delete => {
            if (k.code == 'y' or k.code == 'Y') {
                const paths = self.confirm_paths.toOwnedSlice(self.gpa) catch return;
                defer App.freePaths(self.gpa, paths);
                self.app.startOp(self, .delete, toConst(paths), "", &.{}, false);
                self.consumeTargets();
            } else {
                for (self.confirm_paths.items) |p| self.gpa.free(p);
                self.confirm_paths.clearRetainingCapacity();
                self.notify("Not deleted", false);
            }
        },
        .confirm_empty_trash => if (k.code == 'y' or k.code == 'Y') self.app.emptyTrash(self),
        .conflict => {
            const e = self.conflict orelse return;
            const lower: u32 = if (k.code < 128) std.ascii.toLower(@intCast(k.code)) else k.code;
            const all = k.code < 128 and std.ascii.isUpper(@intCast(k.code));
            const r: ?fsops.Resolution = switch (lower) {
                'r' => .replace,
                's' => .skip,
                'k' => .keep_both,
                'm' => if (e.op.conflict.src_dir and e.op.conflict.dst_dir) .merge else null,
                'c' => .cancel,
                else => if (esc) .cancel else null,
            };
            if (r) |res| {
                self.conflict = null;
                e.answer(res, all);
            } else {
                // Ask again.
                self.await_key = .conflict;
            }
        },
    }
    self.updateStatus();
}

/// An operation found its target taken: ask in the status line.
pub fn askConflict(self: *Window, e: *App.OpEntry) void {
    self.conflict = e;
    self.awaitKey(.conflict);
}

pub fn confirmDelete(self: *Window, paths: []const []const u8) void {
    for (self.confirm_paths.items) |p| self.gpa.free(p);
    self.confirm_paths.clearRetainingCapacity();
    for (paths) |p| self.confirm_paths.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
    if (!self.app.options.confirm_delete) return self.answerAwait(.{ .code = 'y' });
    self.awaitKey(.confirm_delete);
}

pub fn opFinished(self: *Window, op: *fsops.Op, undoable: bool) void {
    _ = undoable;
    var buf: [512]u8 = undefined;
    if (op.result) |err| {
        if (err == error.Canceled) return self.notify("Canceled", false);
        self.notify(std.fmt.bufPrint(&buf, "Could not {s} “{s}”: {s}", .{ fsops.verb(op.kind), model.basename(op.errPath()), fsops.describe(err) }) catch "The operation failed", true);
        return;
    }
    if (op.kind == .chmod or op.kind == .chown) {
        const n = op.done_items.load(.monotonic);
        const what = if (op.kind == .chmod) "permissions" else "owner";
        const msg = if (n == 1)
            std.fmt.bufPrint(&buf, "Changed the {s} of “{s}”", .{ what, model.basename(op.sources[0]) })
        else
            std.fmt.bufPrint(&buf, "Changed the {s} of {d} items", .{ what, n });
        return self.notify(msg catch "Changed", false);
    }
    const n = op.done.items.len;
    if (n == 0 and op.kind != .delete) {
        if (op.skipped != 0) self.notify("Nothing changed: every item was skipped", false);
        return;
    }
    const what = if (op.done.items.len == 1) model.basename(op.done.items[0].from) else if (op.sources.len == 1) model.basename(op.sources[0]) else "";
    const one = n == 1 or (op.kind == .delete and op.sources.len == 1);
    const cnt = if (op.kind == .delete) op.sources.len else n;
    const msg = (switch (op.kind) {
        .copy => if (one) std.fmt.bufPrint(&buf, "Copied “{s}”", .{what}) else std.fmt.bufPrint(&buf, "Copied {d} items", .{cnt}),
        .move, .move_back => if (one) std.fmt.bufPrint(&buf, "Moved “{s}”", .{what}) else std.fmt.bufPrint(&buf, "Moved {d} items", .{cnt}),
        .trash => if (one) std.fmt.bufPrint(&buf, "“{s}” moved to the trash", .{what}) else std.fmt.bufPrint(&buf, "{d} items moved to the trash", .{cnt}),
        .delete => if (one) std.fmt.bufPrint(&buf, "“{s}” deleted", .{what}) else std.fmt.bufPrint(&buf, "{d} items deleted", .{cnt}),
        .restore => if (one) std.fmt.bufPrint(&buf, "“{s}” restored", .{what}) else std.fmt.bufPrint(&buf, "{d} items restored", .{cnt}),
        .chmod, .chown => unreachable,
    }) catch "";
    self.notify(msg, false);
    // The cursor on the first thing a paste brought here.
    if (op.kind == .copy or op.kind == .move) {
        const d = self.curDir();
        if (std.mem.eql(u8, op.dest, d.path)) {
            const first = op.created.items[0 .. std.mem.indexOfScalar(u8, op.created.items, '\n') orelse op.created.items.len];
            if (first.len != 0) d.selectName(first);
        }
    }
}

// Prompts ------------------------------------------------------------------------------------

/// Opens the command line for `kind`, with `initial` text and the caret
/// (and selection anchor) at the given offsets.
pub fn startPrompt(self: *Window, kind: PromptKind, initial: []const u8, caret: u32, anchor: u32) void {
    self.resetPending();
    self.prompt = kind;
    self.prompt_origin = self.curDir().cursor;
    self.history_pos = self.app.history.items.len;
    const label = kind.label();
    const txn = self.begin() orelse return;
    _ = c.siv_set_text(txn, self.cmd_label, label.ptr, label.len);
    _ = c.siv_set_text(txn, self.cmd_editor, initial.ptr, initial.len);
    _ = c.siv_set_selection(txn, self.cmd_editor, caret, anchor);
    _ = c.siv_set_hidden(txn, self.cmd_row, false);
    _ = c.siv_set_hidden(txn, self.cmd_editor, kind == .passphrase);
    _ = c.siv_set_hidden(txn, self.pass_editor, kind != .passphrase);
    const sem_label: []const u8 = switch (kind) {
        .command => "Command",
        .search, .search_back => "Search",
        .find => "Find",
        .filter => "Filter",
        .shell => "Shell command",
        .rename => "New name",
        .create => "New file or folder",
        .passphrase => "Passphrase",
    };
    _ = c.siv_set_semantics(txn, self.cmd_editor, &.{ .role = .text_input, .label = sem_label.ptr, .label_len = sem_label.len, .flags = .{ .focusable = true } });
    self.applyStatus(txn);
    _ = commit(txn);
    _ = c.siv_node_focus(if (kind == .passphrase) self.pass_editor else self.cmd_editor);
}

pub fn closePrompt(self: *Window) void {
    self.prompt = null;
    self.hideWhichKey();
    const txn = self.begin() orelse return;
    _ = c.siv_set_hidden(txn, self.cmd_row, true);
    _ = c.siv_set_text(txn, self.cmd_editor, "", 0);
    // Passphrases do not linger in the editor.
    _ = c.siv_set_text(txn, self.pass_editor, "", 0);
    self.applyStatus(txn);
    _ = commit(txn);
    _ = c.siv_node_focus(self.current.view);
}

pub fn promptText(self: *Window, buf: []u8) []const u8 {
    return ui.getText(self.cmd_editor, buf);
}

fn setPromptText(self: *Window, s: []const u8) void {
    const txn = self.begin() orelse return;
    _ = c.siv_set_text(txn, self.cmd_editor, s.ptr, s.len);
    _ = c.siv_set_selection(txn, self.cmd_editor, @intCast(s.len), @intCast(s.len));
    _ = commit(txn);
}

fn onPromptKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .stop;
    input_clock += 1;
    self.last_input = input_clock;
    const kind = self.prompt orelse return .stop;
    const m = ev.modifiers;
    switch (ev.keysym) {
        .escape => {
            self.cancelPrompt(kind);
            return .handled;
        },
        .@"return", .kp_enter => {
            self.submitPrompt(kind);
            return .handled;
        },
        .tab, .iso_left_tab => {
            if (kind == .command or kind == .shell) self.complete();
            return .handled;
        },
        .up, .down => {
            if (kind == .command or kind == .shell) {
                self.recallHistory(if (ev.keysym == .up) -1 else 1);
                return .handled;
            }
            return .stop;
        },
        else => {},
    }
    // Ctrl+C and Ctrl+[ cancel, as in a terminal.
    if (m.ctrl and (@intFromEnum(ev.keysym) == 'c' or @intFromEnum(ev.keysym) == '[')) {
        self.cancelPrompt(kind);
        return .handled;
    }
    return .stop;
}

fn onPromptChange(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const kind = self.prompt orelse return .pass;
    var buf: [1024]u8 = undefined;
    const t = self.promptText(&buf);
    const d = self.curDir();
    switch (kind) {
        .search, .search_back => {
            if (d.findMatch(t, self.prompt_origin, kind == .search_back, true)) |i| self.moveCursor(i) else self.moveCursor(self.prompt_origin);
        },
        .find => {
            const matches = d.countMatches(t);
            if (d.findMatch(t, self.prompt_origin, false, true)) |i| self.moveCursor(i);
            if (matches == 1 and self.app.options.find_auto_accept and t.len != 0) self.closePrompt();
        },
        .filter => {
            d.filter.clearRetainingCapacity();
            d.filter.appendSlice(self.gpa, t) catch {};
            d.refilter();
            const txn = self.begin() orelse return .handled;
            self.current.refresh(txn);
            self.current.rebind(txn);
            self.updatePreviewTxn(txn);
            self.applyHeader(txn);
            self.applyStatus(txn);
            _ = commit(txn);
        },
        else => {},
    }
    return .handled;
}

fn cancelPrompt(self: *Window, kind: PromptKind) void {
    const d = self.curDir();
    switch (kind) {
        .search, .search_back, .find => self.moveCursor(self.prompt_origin),
        .filter => {
            d.filter.clearRetainingCapacity();
            d.refilter();
            self.closePrompt();
            self.showTab();
            return;
        },
        else => {},
    }
    self.closePrompt();
}

fn submitPrompt(self: *Window, kind: PromptKind) void {
    if (kind == .passphrase) {
        var pass: [1024]u8 = undefined;
        const p = ui.getText(self.pass_editor, &pass);
        defer std.crypto.secureZero(u8, &pass);
        self.closePrompt();
        if (self.app.udisks) |u| u.unlock(self, self.unlock_block.items, p, self.unlock_new_tab);
        return;
    }
    var buf: [4096]u8 = undefined;
    const t0 = self.promptText(&buf);
    var copy: [4096]u8 = undefined;
    @memcpy(copy[0..t0.len], t0);
    const t = copy[0..t0.len];
    self.closePrompt();
    switch (kind) {
        .command => {
            self.app.addHistory(t);
            commands.execute(self, t, null, false);
        },
        .shell => {
            if (t.len == 0) return;
            var hbuf: [4100]u8 = undefined;
            self.app.addHistory(std.fmt.bufPrint(&hbuf, "shell {s}", .{t}) catch t);
            commands.runShell(self, t, false);
        },
        .search, .search_back => {
            self.last_search.clearRetainingCapacity();
            self.last_search.appendSlice(self.gpa, t) catch {};
            self.last_search_back = kind == .search_back;
            if (t.len != 0 and self.curDir().findMatch(t, self.prompt_origin, kind == .search_back, true) == null) self.notify("No match", true);
        },
        .find => {},
        .filter => {},
        .rename => commands.finishRename(self, t),
        .create => commands.finishCreate(self, t),
        .passphrase => {},
    }
}

fn recallHistory(self: *Window, delta: i32) void {
    const h = self.app.history.items;
    if (h.len == 0) return;
    const pos: i64 = @as(i64, @intCast(self.history_pos)) + delta;
    if (pos < 0) return;
    if (pos >= h.len) {
        self.history_pos = h.len;
        self.setPromptText("");
        return;
    }
    self.history_pos = @intCast(pos);
    self.setPromptText(h[self.history_pos]);
}

/// Tab in the command line: completes a command's name, then paths.
fn complete(self: *Window) void {
    var buf: [4096]u8 = undefined;
    const t = self.promptText(&buf);
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = commands.complete(self, a, t, self.prompt == .shell) catch return;
    if (r.candidates.len == 0) return;
    if (!std.mem.eql(u8, r.completed, t)) self.setPromptText(r.completed);
    if (r.candidates.len > 1) self.showCandidates(r.candidates) else self.hideWhichKey();
}

fn showCandidates(self: *Window, cands: []const []const u8) void {
    const txn = self.begin() orelse return;
    ui.clear(txn, self.whichkey);
    const shown = @min(cands.len, 60);
    const cols: usize = if (shown > 16) 3 else if (shown > 6) 2 else 1;
    var tracks: [3]siv.Track = .{ .{ .unit = .auto }, .{ .unit = .auto }, .{ .unit = .auto } };
    const grid = c.siv_grid(txn, self.whichkey, &.{ .columns = &tracks, .columns_count = cols, .column_gap = 18, .row_gap = 2 });
    for (cands[0..shown]) |cand| {
        const n = c.siv_text(txn, grid, cand.ptr, cand.len);
        _ = c.siv_set_text_style(txn, n, &.{ .color_token = .card_fg, .size_role = .body, .flags = .{ .no_wrap = true, .ellipsize = true } });
        _ = c.siv_set_layout(txn, n, &.{ .max_width = 240 });
    }
    _ = c.siv_set_hidden(txn, self.whichkey, false);
    _ = commit(txn);
}

// Searching ----------------------------------------------------------------------------------

pub fn searchNext(self: *Window, reverse: bool, count: u32) void {
    const q = self.last_search.items;
    if (q.len == 0) return self.notify("No previous search", true);
    const back = self.last_search_back != reverse;
    const d = self.curDir();
    var at = d.cursor;
    var n: u32 = 0;
    while (n < @max(count, 1)) : (n += 1) {
        const next = d.findMatch(q, at, back, false) orelse return self.notify("No match", true);
        if (!self.app.options.wrap_scan and ((back and next > at) or (!back and next < at))) return self.notify("Search hit the end", true);
        at = next;
    }
    self.moveCursor(at);
}

// Columns and the mouse ----------------------------------------------------------------------

/// A click (or double click) in a column: the mouse works, but the
/// keyboard owns focus.
pub fn columnClicked(self: *Window, col: *Column, index: u32, activate: bool) void {
    switch (col.kind) {
        .current => {
            if (activate) {
                self.moveCursor(index);
                self.enter();
            } else self.moveCursor(index);
        },
        .parent => if (col.dir) |d| {
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const p = d.pathAt(&pbuf, index) orelse return;
            const e = d.entryAt(index) orelse return;
            if (e.kind == .dir) self.cd(p) else self.cdSelect(d.path, model.basename(p), true);
        },
        .preview => if (col.dir) |d| {
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const p = d.pathAt(&pbuf, index) orelse return;
            if (activate) {
                const e = d.entryAt(index) orelse return;
                if (e.kind == .dir) self.cd(p) else self.cdSelect(d.path, model.basename(p), true);
            } else self.cdSelect(d.path, model.basename(p), true);
        },
    }
    _ = c.siv_node_focus(self.current.view);
}

// Watching and reloading ---------------------------------------------------------------------

pub fn reload(self: *Window) void {
    self.curDir().reload();
    if (self.parent_col.dir) |p| p.reload();
}

pub fn drivesChanged(self: *Window) void {
    _ = self;
}

/// An encrypted volume asks for its passphrase in the command line.
pub fn askPassphrase(self: *Window, block: []const u8, label: []const u8, new_tab: bool) void {
    self.askPassphraseAgain(block, label, new_tab, null);
}

fn askPassphraseAgain(self: *Window, block: []const u8, label: []const u8, new_tab: bool, failure: ?[]const u8) void {
    var lbuf: [256]u8 = undefined;
    const label_copy = lbuf[0..@min(label.len, lbuf.len)];
    @memcpy(label_copy, label[0..label_copy.len]);
    self.unlock_block.clearRetainingCapacity();
    self.unlock_block.appendSlice(self.gpa, block) catch return;
    self.unlock_label.clearRetainingCapacity();
    self.unlock_label.appendSlice(self.gpa, label_copy) catch {};
    self.unlock_new_tab = new_tab;
    if (failure) |f| self.app.logMessage(f, true);
    self.startPrompt(.passphrase, "", 0, 0);
    var buf: [600]u8 = undefined;
    self.message.clearRetainingCapacity();
    const msg = if (failure) |f|
        std.fmt.bufPrint(&buf, "{s} Unlock “{s}”", .{ f, label_copy }) catch "Unlock"
    else
        std.fmt.bufPrint(&buf, "Unlock “{s}”", .{label_copy}) catch "Unlock";
    self.message.appendSlice(self.gpa, msg) catch {};
    self.message_error = failure != null;
    self.updateStatus();
}

pub fn unlockFailed(self: *Window, msg: []const u8, block: []const u8, label: []const u8, new_tab: bool) void {
    if (block.len == 0) return self.notify(msg, true);
    self.askPassphraseAgain(block, label, new_tab, msg);
}

/// The drives in a menu at the cursor: choosing a mounted one goes
/// there, an unmounted one mounts it (asking for a passphrase if it is
/// encrypted).
pub fn drivesMenu(self: *Window) void {
    const ds = self.app.places.drives.items;
    if (ds.len == 0) return self.notify("No drives", false);
    const txn = self.begin() orelse return;
    const menu = c.siv_menu(txn, self.root, &.{ .label = "Drives", .label_len = 6 });
    for (ds, 0..) |d, i| {
        var buf: [600]u8 = undefined;
        var sb: [32]u8 = undefined;
        const size = if (d.size != 0) model.formatSize(&sb, d.size) else "";
        const label = if (d.mount_point.len != 0)
            std.fmt.bufPrint(&buf, "{s} — {s}", .{ d.label, d.mount_point }) catch d.label
        else
            std.fmt.bufPrint(&buf, "Mount {s}{s}{s}", .{ d.label, if (size.len != 0) " — " else "", size }) catch d.label;
        var kb: [4]u8 = undefined;
        const shortcut = if (i < 9) std.fmt.bufPrint(&kb, "{d}", .{i + 1}) catch "" else "";
        const icon = std.mem.trimStart(u8, d.icon, "\n");
        _ = c.siv_menu_item(txn, menu, &.{ .label = label.ptr, .label_len = label.len, .shortcut = shortcut.ptr, .shortcut_len = shortcut.len, .mnemonic = if (i < 9) @intCast('1' + i) else 0, .icon = icon.ptr, .icon_len = icon.len });
    }
    _ = c.siv_on(txn, menu, .select, onDriveChosen, null, self);
    if (!commit(txn)) return;
    const row = c.siv_view_get_row(self.current.view, self.curDir().cursor);
    if (row != .null) _ = c.siv_menu_open_at(menu, row, 40, Column.row_height) else _ = c.siv_menu_open(menu, self.current.view);
}

fn onDriveChosen(ud: ?*anyopaque, menu: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const ds = self.app.places.drives.items;
    if (ev.index < ds.len) {
        const d = ds[ev.index];
        if (d.mount_point.len != 0) {
            self.cd(d.mount_point);
        } else if (self.app.udisks) |u| {
            u.mount(self, @intCast(ev.index), false);
        } else self.notify("Mounting needs UDisks2", true);
    }
    if (self.begin()) |txn| {
        _ = c.siv_remove(txn, menu);
        _ = commit(txn);
    }
    return .handled;
}

pub fn leaveMount(self: *Window, mount_point: []const u8) void {
    for (self.tabs.items, 0..) |t, i| if (model.isWithin(t.path(), mount_point)) {
        const was = self.active;
        self.active = i;
        self.cd(model.parent(mount_point));
        self.active = was;
    };
    self.showTab();
}

// Open with -------------------------------------------------------------------------------

/// A menu of the applications that open these files, at the cursor.
pub fn openWithMenu(self: *Window, paths: []const []const u8) void {
    if (paths.len == 0) return;
    if (self.app.waitForApps(self, paths, true)) return;
    const db = self.app.apps_db orelse return self.notify("No applications found", true);
    const types = self.app.loadMimeDb() orelse return;
    const t = model.typeOfPath(types, paths[0]);
    var list = db.appsFor(self.gpa, types, t) catch return;
    if (list.len == 0) {
        self.gpa.free(list);
        list = db.allApps(self.gpa) catch return;
    }
    defer self.gpa.free(list);
    if (list.len == 0) return self.notify("No applications found", true);
    const state = self.gpa.create(OpenWith) catch return;
    state.* = .{ .win = self, .apps = self.gpa.dupe(*const @import("apps.zig").App, list) catch {
        self.gpa.destroy(state);
        return;
    }, .paths = .empty };
    for (paths) |p| state.paths.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
    const txn = self.begin() orelse return state.free();
    const menu = c.siv_menu(txn, self.root, &.{ .label = "Open with", .label_len = 9 });
    for (list, 0..) |app, i| {
        var sb: [8]u8 = undefined;
        const shortcut = if (i < 9) std.fmt.bufPrint(&sb, "{d}", .{i + 1}) catch "" else "";
        _ = c.siv_menu_item(txn, menu, &.{ .label = app.name.ptr, .label_len = app.name.len, .shortcut = shortcut.ptr, .shortcut_len = shortcut.len, .mnemonic = if (i < 9) @intCast('1' + i) else 0, .icon = app.icon.ptr, .icon_len = app.icon.len });
    }
    _ = c.siv_on(txn, menu, .select, OpenWith.onSelect, OpenWith.destroy, state);
    if (!commit(txn)) return;
    const row = c.siv_view_get_row(self.current.view, self.curDir().cursor);
    if (row != .null) _ = c.siv_menu_open_at(menu, row, 40, Column.row_height) else _ = c.siv_menu_open(menu, self.current.view);
}

const OpenWith = struct {
    win: *Window,
    apps: []*const @import("apps.zig").App,
    paths: std.ArrayList([]u8),

    fn free(s: *OpenWith) void {
        const gpa = s.win.gpa;
        for (s.paths.items) |p| gpa.free(p);
        s.paths.deinit(gpa);
        gpa.free(s.apps);
        gpa.destroy(s);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const s: *OpenWith = @ptrCast(@alignCast(ud.?));
        s.free();
    }

    fn onSelect(ud: ?*anyopaque, menu: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
        const s: *OpenWith = @ptrCast(@alignCast(ud.?));
        if (ev.index < s.apps.len) s.win.app.launch(s.win, s.apps[ev.index], @ptrCast(s.paths.items));
        // The menu is done with.
        if (s.win.begin()) |txn| {
            _ = c.siv_remove(txn, menu);
            _ = commit(txn);
        }
        return .handled;
    }
};

// Clipboard and drag and drop ------------------------------------------------------------------

/// The paths as text/uri-list, x-special/gnome-copied-files (with "copy"
/// or "cut" first, so a paste here or in GNOME Files moves cut files),
/// KDE's cut marker, and plain text.
pub fn writeClipboard(self: *Window, paths: []const []const u8, cut: bool) void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(self.gpa);
    var lengths: [4]usize = undefined;
    var start: usize = 0;
    for (paths) |p| {
        uri.appendFileUri(&data, self.gpa, p) catch return;
        data.appendSlice(self.gpa, "\r\n") catch return;
    }
    lengths[0] = data.items.len - start;
    start = data.items.len;
    data.appendSlice(self.gpa, if (cut) "cut" else "copy") catch return;
    for (paths) |p| {
        data.append(self.gpa, '\n') catch return;
        uri.appendFileUri(&data, self.gpa, p) catch return;
    }
    lengths[1] = data.items.len - start;
    start = data.items.len;
    data.appendSlice(self.gpa, if (cut) "1" else "0") catch return;
    lengths[2] = data.items.len - start;
    start = data.items.len;
    for (paths, 0..) |p, i| {
        if (i > 0) data.append(self.gpa, '\n') catch return;
        data.appendSlice(self.gpa, p) catch return;
    }
    lengths[3] = data.items.len - start;
    const mimes = "text/uri-list\nx-special/gnome-copied-files\napplication/x-kde-cutselection\ntext/plain;charset=utf-8";
    _ = c.siv_clipboard_write_data(self.window, .clipboard, &.{ .mimes = mimes, .mimes_len = mimes.len, .data = data.items.ptr, .data_count = data.items.len, .lengths = &lengths, .lengths_count = 4 });
}

pub fn writeClipboardText(self: *Window, s: []const u8) void {
    _ = c.siv_clipboard_write(self.window, .clipboard, s.ptr, s.len);
}

/// A paste waiting for the clipboard.
const Paste = struct {
    win: *Window,
    gpa: Allocator,
    dest: []u8,
    replace: bool,

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const t: *Paste = @ptrCast(@alignCast(ud.?));
        t.gpa.free(t.dest);
        t.gpa.destroy(t);
    }

    fn onData(ud: ?*anyopaque, d: *const siv.ClipboardData) callconv(.c) void {
        const t: *Paste = @ptrCast(@alignCast(ud.?));
        const self = t.win;
        if (self.closing) return;
        if (d.result != .ok or d.data == null) return self.pasteRegister(t.dest, t.replace);
        const bytes = d.data.?[0..d.data_count];
        const g = if (d.index == 0) uri.gnomeCopied(bytes) else @TypeOf(uri.gnomeCopied(bytes)){ .cut = false, .uris = bytes };
        self.transferUris(g.uris, t.dest, if (g.cut) .move else .copy, t.replace);
    }
};

/// p: pastes what the clipboard holds (what yy or dd put there, or files
/// copied in another file manager) into `dest`.
pub fn paste(self: *Window, dest: []const u8, replace: bool) void {
    const t = self.gpa.create(Paste) catch return;
    t.* = .{ .win = self, .gpa = self.gpa, .dest = self.gpa.dupe(u8, dest) catch {
        self.gpa.destroy(t);
        return;
    }, .replace = replace };
    const mimes = "x-special/gnome-copied-files\ntext/uri-list";
    if (c.siv_clipboard_read_data(self.window, .clipboard, mimes, mimes.len, Paste.onData, Paste.destroy, t) != .ok) self.pasteRegister(dest, replace);
}

/// Without a clipboard: what yy or dd took.
fn pasteRegister(self: *Window, dest: []const u8, replace: bool) void {
    const reg = self.app.register.items;
    if (reg.len == 0) return self.notify("Nothing to paste", false);
    self.app.startOpWith(self, if (self.app.register_cut) .move else .copy, @ptrCast(reg), dest, &.{}, true, if (replace) .replace else .none);
}

fn transferUris(self: *Window, uris: []const u8, dest: []const u8, kind: fsops.Kind, replace: bool) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |x| self.gpa.free(x);
        paths.deinit(self.gpa);
    }
    var it: uri.Lines = .{ .rest = uris };
    while (it.next()) |u| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = uri.filePath(&buf, u) orelse continue;
        paths.append(self.gpa, self.gpa.dupe(u8, p) catch return) catch return;
    }
    if (paths.items.len == 0) return self.notify("Only local files can be pasted here", false);
    self.app.startOpWith(self, kind, toConst(paths.items), dest, &.{}, true, if (replace) .replace else .none);
}

fn onDrop(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const d = self.curDir();
    if (d.isTrash()) return .pass;
    return if (self.acceptDrop(ev, d.path)) .handled else .pass;
}

/// Files dropped into `dest`: copied, or moved when the drop says so.
pub fn acceptDrop(self: *Window, ev: *const siv.Event, dest: []const u8) bool {
    switch (ev.phase) {
        .enter, .move => return true,
        .drop => {
            const data = if (ev.data) |p| p[0..ev.data_count] else return false;
            self.transferUris(data, dest, if (ev.action == .move) .move else .copy, false);
            return true;
        },
        else => return false,
    }
}

/// Drags the targets out to other applications.
pub fn startDrag(self: *Window, node: Node) void {
    const paths = self.targets() catch return;
    defer App.freePaths(self.gpa, paths);
    if (paths.len == 0) return;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(self.gpa);
    for (paths) |p| {
        uri.appendFileUri(&data, self.gpa, p) catch return;
        data.appendSlice(self.gpa, "\r\n") catch return;
    }
    const first = data.items.len;
    for (paths, 0..) |p, i| {
        if (i > 0) data.append(self.gpa, '\n') catch return;
        data.appendSlice(self.gpa, p) catch return;
    }
    const lengths = [2]usize{ first, data.items.len - first };
    const mimes = "text/uri-list\ntext/plain;charset=utf-8";
    _ = c.siv_drag_start(node, &.{ .mimes = mimes, .mimes_len = mimes.len, .data = data.items.ptr, .data_count = data.items.len, .lengths = &lengths, .lengths_count = 2, .actions = .{ .copy = true, .move = true } });
}
