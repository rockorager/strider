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
const Picker = @import("Picker.zig");
const Chooser = @import("Chooser.zig");
pub const Menu = @import("Menu.zig");
pub const Dialogs = @import("Dialogs.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");
const mime = @import("mime.zig");
const fsops = @import("fsops.zig");
const uri = @import("uri.zig");
const ui = @import("ui.zig");
const commands = @import("commands.zig");

const Window = @This();
pub const PreviewMode = Preview.Mode;
const Node = siv.Node;
const Txn = siv.Txn;

/// A clickable segment of the header path.
const Crumb = struct { node: Node, path: []u8 };

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
    /// The picker's query.
    pick,

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
            .pick => "",
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
/// The folder part of the header path: a text per segment, folders
/// above the current one clickable (a breadcrumb).
path_dir: Node = .null,
path_name: Node = .null,
crumbs: std.ArrayList(Crumb) = .empty,
/// The folder the crumbs show (rebuilt when it changes).
crumbs_for: std.ArrayList(u8) = .empty,
tabs_row: Node = .null,
/// Each tab's nodes, in tab order, so hovering restyles them in place.
tab_nodes: std.ArrayList(TabNodes) = .empty,
/// The tab under the pointer, and the tab whose close button is.
tab_hover: ?usize = null,
tab_close_hover: ?usize = null,
parent_col: Column,
current: Column,
preview: Preview,
/// Fuzzy finding (gf) and zoxide's folders (gz), over the command line.
picker: Picker,
/// The context menu.
menu: Menu,
/// The dialog showing, if any.
dialogs: Dialogs,
/// The FileChooser portal request this window serves, if it is one.
chooser: ?*Chooser = null,
/// Whether it was made for one (the request goes before the window).
is_chooser: bool = false,
/// The user resized it (after its first frame settled): a chooser's size
/// is remembered for the next one.
user_resized: bool = false,
height: f32 = 0,
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
/// A visual-mode y or d that just ran: the next key may finish the
/// two-key form (yy, dd, dT, dD) on the same files.
visual_op: u32 = 0,
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
/// The handles on the column boundaries (parent|current, current|preview),
/// their lines, and a drag in progress.
handles: [2]Handle = undefined,
drag: ?Drag = null,
/// The tasks view (w): file operations running and done; open in mode
/// tasks, with this row selected.
tasks: Node = .null,
task_cursor: usize = 0,
last_input: u64 = 0,
/// cd's look at a path on a worker, and which cd is the newest.
probing: ?*Probe = null,
probe_gen: u64 = 0,
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
    return createWith(app, path, null);
}

/// A window for a file chooser request: its title, its caller's window
/// as the parent, and the chooser's bar.
pub fn createChooser(app: *App, path: []const u8, ch: *Chooser) !*Window {
    return createWith(app, path, ch);
}

fn createWith(app: *App, path: []const u8, chooser: ?*Chooser) !*Window {
    const gpa = app.gpa;
    const self = try gpa.create(Window);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .app = app,
        .parent_col = .{ .win = undefined, .kind = .parent },
        .current = .{ .win = undefined, .kind = .current },
        .preview = undefined,
        .picker = undefined,
        .menu = undefined,
        .dialogs = undefined,
        .chooser = chooser,
        .is_chooser = chooser != null,
    };
    self.parent_col.win = self;
    self.current.win = self;
    self.preview = Preview.init(self);
    self.picker = Picker.init(self);
    self.menu = Menu.init(self);
    self.dialogs = Dialogs.init(self);
    const parent: []const u8 = if (chooser) |ch| ch.parent_window else "";
    const size = app.chooserSize();
    // Hyprland opens a chooser (a floating dialog) at its least size, not
    // the size it asks for: that least fits the columns and the bar, and a
    // 1366x768 screen, unless `chooser_size` asks for less.
    const least = [2]u32{ @min(800, app.options.chooser_size[0]), @min(500, app.options.chooser_size[1]) };
    self.window = try siv.windowCreate(app.app, .{
        .title = if (chooser) |ch| ch.windowTitle() else "Strider",
        .app_id = if (chooser != null) App.chooser_app_id else App.app_id,
        .width = if (chooser != null) size[0] else app.opts.window_width,
        .height = if (chooser != null) size[1] else app.opts.window_height,
        .min_width = if (chooser != null) least[0] else 360,
        .min_height = if (chooser != null) least[1] else 240,
        .user_data = self,
        .on_event = onWindowEvent,
        .destroy = onWindowDestroyed,
        // A chooser belongs to its caller's window, modal unless asked
        // otherwise; "x11:" parents and none leave it a plain window.
        .parent_handle = parent,
        .flags = .{ .modal = chooser != null and chooser.?.modal and parent.len != 0 },
    });
    if (chooser) |ch| ch.win = self;
    // The icon by name, for compositors that do not find it from the app
    // id: the chooser's app id has no desktop file naming it, and a build
    // run from zig-out has none at all. siv draws it from the app's own
    // icons, where the build installs it too.
    _ = c.siv_window_set_icon(self.window, App.app_id, App.app_id.len, .null);
    var wsize: siv.Size = .{};
    if (c.siv_window_get_size(self.window, &wsize) == .ok) {
        self.width = wsize.width;
        self.height = wsize.height;
    }
    try self.build();
    const t = self.addTab(path) orelse return error.OutOfMemory;
    _ = t;
    self.active = 0;
    self.showTab();
    _ = c.siv_node_focus(self.current.view);
    if (chooser) |ch| ch.shown();
    return self;
}

/// Closes the window (its destroy-notify frees the rest).
pub fn close(self: *Window) void {
    if (self.window != .null) _ = c.siv_window_destroy(self.window);
}

fn onWindowEvent(ud: ?*anyopaque, _: siv.Window, ev: *const siv.WindowEvent) callconv(.c) bool {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    switch (ev.type) {
        .resized => if (self.width != @as(f32, @floatFromInt(ev.width)) or self.height != @as(f32, @floatFromInt(ev.height))) {
            // A resize well after the first frame is the user's (the
            // compositor settles a new window's size before that).
            if (self.first_frame_ns != 0 and Chooser.now() > self.first_frame_ns + 500 * std.time.ns_per_ms) self.user_resized = true;
            self.height = @floatFromInt(ev.height);
            self.width = @floatFromInt(ev.width);
            if (self.tabs.items.len != 0) if (self.begin()) |txn| {
                self.applyRatioTxn(txn);
                _ = commit(txn);
            };
        },
        .presented => {
            self.frames += 1;
            if (self.first_frame_ns == 0) {
                self.first_frame_ns = ev.commit_ns;
                if (self.chooser) |ch| ch.firstFrame(ev.commit_ns);
            }
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
    if (self.probing) |pr| pr.win = null;
    if (self.is_chooser and self.user_resized and self.width > 0)
        self.app.rememberChooserSize(.{ @intFromFloat(self.width), @intFromFloat(self.height) });
    // Closed by the user: the request is cancelled.
    if (self.chooser) |ch| {
        self.chooser = null;
        ch.windowGone();
    }
    if (self.conflict) |e| e.answer(.cancel, false);
    self.preview.deinit();
    self.picker.deinit();
    self.menu.deinit();
    self.dialogs.deinit();
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
    self.freeCrumbs();
    self.crumbs.deinit(gpa);
    self.crumbs_for.deinit(gpa);
    self.tab_nodes.deinit(gpa);
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
    self.path_dir = c.siv_flex(txn, path_box, &.{ .axis = .row, .align_items = .center });
    _ = c.siv_set_layout(txn, self.path_dir, &.{ .shrink = 1, .min_width = 0 });
    _ = c.siv_set_visual(txn, self.path_dir, &.{ .flags = .{ .clip = true } });
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
    self.buildHandle(txn, cols, 0);
    self.current_box = c.siv_box(txn, cols);
    self.current.build(txn, self.current_box, "Files");
    self.buildHandle(txn, cols, 1);
    self.preview_box = c.siv_box(txn, cols);
    self.preview.build(txn, self.preview_box);
    self.applyRatioTxn(txn);
    if (self.chooser) |ch| ch.build(txn, main);
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

    // The tasks view, over the middle of the columns.
    self.tasks = c.siv_flex(txn, self.root, &.{ .axis = .column, .gap = 6 });
    _ = c.siv_set_layout(txn, self.tasks, &.{
        .align_x = .center,
        .align_y = .center,
        .width = ui.fill(),
        .max_width = 720,
        .padding = .{ .start = 16, .end = 16, .top = 12, .bottom = 12 },
    });
    _ = c.siv_set_visual(txn, self.tasks, &.{ .background_token = .card_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 8, .top_end = 8, .bottom_start = 8, .bottom_end = 8 } });
    _ = c.siv_set_semantics(txn, self.tasks, &.{ .role = .list, .label = "Tasks", .label_len = 5 });
    _ = c.siv_set_hidden(txn, self.tasks, true);
    self.picker.build(txn, self.root);
    try siv.txnCommit(txn);
}

/// Column widths from the ratio and the window's width: narrow windows
/// drop the parent column, then the preview; the parent widens to fit its
/// names (fit_parent).
// Column handles ---------------------------------------------------------------------------

/// How wide a column boundary is to grab: a 1 px line in the middle, with
/// each side on its column's surface.
const handle_width: f32 = 7;
/// No column gets narrower than this by dragging or < and >.
const min_column: f32 = 80;

const Handle = struct { win: *Window, which: u1, node: Node = .null, line: Node = .null, hover: bool = false };

/// A boundary being dragged: where the pointer started (window
/// coordinates) and the parent's and current column's widths then.
const Drag = struct { which: u1, x0: f32, widths: [2]f32 };

fn buildHandle(self: *Window, txn: Txn, parent: Node, which: u1) void {
    const h = &self.handles[which];
    h.* = .{ .win = self, .which = which };
    h.node = c.siv_flex(txn, parent, &.{ .axis = .row, .align_items = .stretch });
    _ = c.siv_set_layout(txn, h.node, &.{ .width = px(handle_width), .height = ui.fill(), .flags = .{ .no_shrink = true } });
    const sides = [2][2]siv.ColorToken{ .{ .sidebar_bg, .secondary_sidebar_bg }, .{ .secondary_sidebar_bg, .view_bg } };
    const a = c.siv_box(txn, h.node);
    _ = c.siv_set_layout(txn, a, &.{ .grow = 1, .basis = px(0) });
    _ = c.siv_set_visual(txn, a, &.{ .background_token = sides[which][0] });
    h.line = c.siv_box(txn, h.node);
    const b = c.siv_box(txn, h.node);
    _ = c.siv_set_layout(txn, b, &.{ .grow = 1, .basis = px(0) });
    _ = c.siv_set_visual(txn, b, &.{ .background_token = sides[which][1] });
    _ = c.siv_set_semantics(txn, h.node, &.{ .role = .none });
    _ = c.siv_set_cursor(txn, h.node, .ew_resize);
    _ = c.siv_on(txn, h.node, .pointer, onHandlePointer, null, h);
    styleHandle(txn, h, false);
}

/// The line: the separator at rest, the accent and twice as wide under
/// the pointer or while dragged.
fn styleHandle(txn: Txn, h: *const Handle, lit: bool) void {
    _ = c.siv_set_layout(txn, h.line, &.{ .width = px(if (lit) 2 else 1), .flags = .{ .no_shrink = true } });
    _ = c.siv_set_visual(txn, h.line, &.{ .background_token = if (lit) .accent else .separator });
}

fn onHandlePointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const h: *Handle = @ptrCast(@alignCast(ud.?));
    const self = h.win;
    var r: siv.Rect = .{};
    _ = c.siv_node_get_rect(node, &r);
    // In window coordinates, from the last layout, so that moves before
    // the next frame do not add up.
    const x = r.x + ev.x;
    switch (ev.phase) {
        .down => if (ev.button == .primary) {
            self.drag = .{ .which = h.which, .x0 = x, .widths = self.columnWidths() };
            self.restyleHandle(h);
            return .handled;
        },
        .move => if (self.drag) |d| if (d.which == h.which) {
            var rtl = false;
            _ = c.siv_node_is_rtl(node, &rtl);
            const delta = (x - d.x0) * @as(f32, if (rtl) -1 else 1);
            var w = d.widths;
            if (d.which == 0) {
                // The boundary moves; the current column's other edge stays.
                w[0] += delta;
                w[1] -= delta;
            } else w[1] += delta;
            self.setColumnWidths(w, false);
            return .handled;
        },
        .up, .cancel => if (self.drag != null) {
            self.drag = null;
            self.restyleHandle(h);
            // Kept for the next start once the drag ends.
            if (self.app.widths) |w| self.app.setWidths(w);
            return .handled;
        },
        .enter, .leave => {
            h.hover = ev.phase == .enter;
            self.restyleHandle(h);
        },
        else => {},
    }
    return .pass;
}

fn restyleHandle(self: *Window, h: *const Handle) void {
    const txn = self.begin() orelse return;
    styleHandle(txn, h, h.hover or (self.drag != null and self.drag.?.which == h.which));
    _ = commit(txn);
}

/// The parent's and the current column's widths as laid out.
pub fn columnWidths(self: *Window) [2]f32 {
    var a: siv.Rect = .{};
    var b: siv.Rect = .{};
    _ = c.siv_node_get_rect(self.parent_box, &a);
    _ = c.siv_node_get_rect(self.current_box, &b);
    return .{ a.width, b.width };
}

/// Makes the parent and current columns `w` wide (clamped so that every
/// shown column keeps `min_column`), as the user's choice; `persist`
/// keeps it for the next start.
fn setColumnWidths(self: *Window, w_in: [2]f32, persist: bool) void {
    const total = self.width;
    if (total <= 0) return;
    var w = w_in;
    const room = total - 2 * handle_width - min_column;
    w[0] = std.math.clamp(w[0], min_column, @max(min_column, room - min_column));
    w[1] = std.math.clamp(w[1], min_column, @max(min_column, room - w[0]));
    const shares: [2]f32 = .{ w[0] / total, w[1] / total };
    if (persist) self.app.setWidths(shares) else {
        self.app.widths = shares;
        for (self.app.windows.items) |win| win.relayout();
    }
}

/// < and >: widens (or narrows, with a negative `delta`) the current
/// column, or the parent; the room comes from the preview.
pub fn resizeColumn(self: *Window, parent: bool, delta: f32) void {
    var w = self.columnWidths();
    w[if (parent) 0 else 1] += delta;
    self.setColumnWidths(w, true);
}

/// Lays the columns out again (the widths or the options changed).
pub fn relayout(self: *Window) void {
    if (self.tabs.items.len == 0) return;
    const txn = self.begin() orelse return;
    self.applyRatioTxn(txn);
    _ = commit(txn);
}

fn applyRatioTxn(self: *Window, txn: Txn) void {
    const o = &self.app.options;
    const r = o.ratio;
    const narrow: f32 = @floatFromInt(o.narrow_width);
    const w = self.width;
    // A chooser keeps the parent (where it is) longer than the preview.
    const parent_at = if (self.is_chooser) narrow * 2 / 3 else narrow;
    const preview_at = if (self.is_chooser) narrow else narrow * 2 / 3;
    const show_parent = r[0] > 0 and (w == 0 or w >= parent_at);
    const show_preview = o.preview and r[2] > 0 and (w == 0 or w >= preview_at);
    // Chosen widths, or fitting the parent, fix it and the current column
    // at their widths and leave the rest to the preview.
    var parent_px: f32 = 0;
    var current_px: f32 = 0;
    if (self.app.widths) |chosen| if (w > 0) {
        // The user's widths win over the ratio and fit_parent; narrow
        // windows still drop columns, and the preview keeps its least.
        const room = w - 2 * handle_width - (if (show_preview) min_column else 0);
        parent_px = if (show_parent) std.math.clamp(chosen[0] * w, min_column, @max(min_column, room - min_column)) else 0;
        current_px = if (show_preview) std.math.clamp(chosen[1] * w, min_column, @max(min_column, room - parent_px)) else 0;
    };
    const manual = self.app.widths != null and w > 0;
    if (manual) {
        if (show_parent) _ = c.siv_set_layout(txn, self.parent_box, &.{ .basis = px(parent_px), .height = ui.fill(), .min_width = 0, .flags = .{ .no_shrink = true } });
        if (show_preview)
            _ = c.siv_set_layout(txn, self.current_box, &.{ .basis = px(current_px), .height = ui.fill(), .flags = .{ .no_shrink = true } })
        else
            _ = c.siv_set_layout(txn, self.current_box, &.{ .grow = 1, .basis = px(0), .height = ui.fill() });
    } else {
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
    self.closeTabAt(self.active);
}

/// Closes tab i; the active tab stays active unless it is the one
/// closed. Closing the last tab closes the window.
pub fn closeTabAt(self: *Window, i: usize) void {
    if (i >= self.tabs.items.len) return;
    if (self.tabs.items.len <= 1) return self.close();
    const t = self.tabs.orderedRemove(i);
    if (i < self.active or self.active >= self.tabs.items.len) self.active -= 1;
    self.tab_hover = null;
    self.tab_close_hover = null;
    self.endVisual();
    self.showTab();
    freeTab(self.gpa, t);
}

fn tabLabel(self: *Window, buf: []u8, i: usize) []const u8 {
    const p = self.tabs.items[i].path();
    const name = if (std.mem.eql(u8, p, self.app.home)) "~" else model.basename(p);
    return std.fmt.bufPrint(buf, "{d} {s}", .{ i + 1, name }) catch name;
}

const tab_radius: siv.Corners = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 };

const TabNodes = struct { root: Node, label: Node, close: Node, icon: Node };

fn applyTabs(self: *Window, txn: Txn) void {
    ui.clear(txn, self.tabs_row);
    self.tab_nodes.clearRetainingCapacity();
    if (self.tabs.items.len < 2) return;
    for (0..self.tabs.items.len) |i| {
        var buf: [96]u8 = undefined;
        const label = self.tabLabel(&buf, i);
        const root = c.siv_flex(txn, self.tabs_row, &.{ .axis = .row, .gap = 2, .align_items = .center });
        _ = c.siv_set_layout(txn, root, &.{ .padding = .{ .start = 8, .end = 2, .top = 1, .bottom = 1 }, .max_width = 180 });
        _ = c.siv_set_semantics(txn, root, &.{ .role = .tab, .label = label.ptr, .label_len = label.len });
        _ = c.siv_on(txn, root, .pointer, onTabPointer, null, self);
        const text = c.siv_text(txn, root, label.ptr, label.len);
        _ = c.siv_set_layout(txn, text, &.{ .shrink = 1, .min_width = 0 });
        // The close button's space is always kept, so labels stay put when
        // it shows; hidden, it is transparent and the pointer passes through.
        const x = c.siv_flex(txn, root, &.{ .axis = .row, .justify = .center, .align_items = .center });
        _ = c.siv_set_layout(txn, x, &.{ .width = px(18), .height = px(18), .flags = .{ .no_shrink = true } });
        _ = c.siv_on(txn, x, .pointer, onTabClosePointer, null, self);
        const icon = c.siv_image_view(txn, x, &.{ .icon_size = 12 });
        _ = c.siv_set_semantics(txn, icon, &.{ .role = .none });
        self.tab_nodes.append(self.gpa, .{ .root = root, .label = text, .close = x, .icon = icon }) catch return;
        self.styleTab(txn, i);
    }
}

/// A tab's look: the active tab on the accent, a hovered one raised, and
/// the close button on the active and hovered tabs.
fn styleTab(self: *Window, txn: Txn, i: usize) void {
    if (i >= self.tab_nodes.items.len) return;
    const n = self.tab_nodes.items[i];
    const on = i == self.active;
    const hover = self.tab_hover == i;
    const fg: siv.ColorToken = if (on) .accent_fg else if (hover) .control_fg else .muted_fg;
    _ = c.siv_set_visual(txn, n.root, &.{ .background_token = if (on) .accent else if (hover) .control_hover else .control_bg, .radius = tab_radius });
    _ = c.siv_set_semantics(txn, n.root, &.{ .role = .tab, .selected = if (on) .on else .off });
    _ = c.siv_set_text_style(txn, n.label, &.{ .color_token = fg, .size_role = .caption, .weight = if (on) .bold else .regular, .flags = .{ .no_wrap = true, .ellipsize = true } });
    const shown = on or hover;
    const close_hover = shown and self.tab_close_hover == i;
    _ = c.siv_set_visual(txn, n.close, &.{ .background_token = if (!close_hover) .none else if (on) .accent_active else .control_active, .radius = tab_radius, .flags = .{ .no_hit_test = !shown } });
    _ = c.siv_set_opacity(txn, n.close, if (shown) 1 else 0);
    _ = c.siv_set_cursor(txn, n.close, if (shown) .pointer else .default);
    var lb: [96]u8 = undefined;
    var buf: [104]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "Close {s}", .{self.tabLabel(&lb, i)}) catch "Close";
    _ = c.siv_set_semantics(txn, n.close, &.{ .role = if (shown) .button else .none, .label = name.ptr, .label_len = name.len, .flags = .{ .focusable = false } });
    _ = c.siv_set_image_view(txn, n.icon, &.{ .icon = "window-close-symbolic", .icon_len = 21, .icon_size = 12, .color_token = fg });
}

fn tabIndex(self: *Window, node: Node, comptime field: []const u8) ?usize {
    for (self.tab_nodes.items, 0..) |n, i| {
        if (@field(n, field) == node) return i;
    }
    return null;
}

fn setTabHover(self: *Window, hover: ?usize, close_hover: ?usize) void {
    if (hover == self.tab_hover and close_hover == self.tab_close_hover) return;
    const txn = self.begin() orelse return;
    const old = [_]?usize{ self.tab_hover, self.tab_close_hover };
    self.tab_hover = hover;
    self.tab_close_hover = close_hover;
    for (old ++ [_]?usize{ hover, close_hover }) |o| if (o) |i| self.styleTab(txn, i);
    _ = commit(txn);
}

fn onTabPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const i = self.tabIndex(node, "root") orelse return .pass;
    switch (ev.phase) {
        .enter => self.setTabHover(i, self.tab_close_hover),
        .leave => if (self.tab_hover == i) self.setTabHover(null, null),
        .down => {
            if (ev.button == .middle) self.closeTabAt(i) else if (ev.button == .primary) self.selectTab(i) else return .pass;
            return .handled;
        },
        else => {},
    }
    return .pass;
}

fn onTabClosePointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const i = self.tabIndex(node, "close") orelse return .pass;
    switch (ev.phase) {
        .enter => self.setTabHover(i, i),
        .leave => if (self.tab_close_hover == i) self.setTabHover(self.tab_hover, null),
        .down => {
            if (ev.button != .primary and ev.button != .middle) return .pass;
            self.closeTabAt(i);
            return .handled;
        },
        else => {},
    }
    return .pass;
}

// Showing ----------------------------------------------------------------------------------

/// Shows the active tab: its folder, the parent, and the preview.
pub fn showTab(self: *Window) void {
    if (self.chooser) |ch| ch.applyTypes(self);
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
    const title = if (self.chooser) |ch| ch.windowTitle() else d.path;
    _ = c.siv_window_set_title(self.window, title.ptr, title.len);
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
    if (!std.mem.eql(u8, self.crumbs_for.items, d.path)) self.buildCrumbs(txn, d);
    const name = d.nameAt(d.cursor) orelse "";
    const base = model.basename(name);
    _ = c.siv_set_text(txn, self.path_name, base.ptr, if (name.len == 0) 0 else base.len);
}

fn freeCrumbs(self: *Window) void {
    for (self.crumbs.items) |cr| self.gpa.free(cr.path);
    self.crumbs.clearRetainingCapacity();
}

/// The header path as segments: "~" or "/", then each folder down to
/// the current one, separated by slashes. Those above the current folder
/// go there when clicked (a new tab with the middle button), underlined
/// under the pointer.
fn buildCrumbs(self: *Window, txn: Txn, d: *Dir) void {
    self.freeCrumbs();
    self.crumbs_for.clearRetainingCapacity();
    self.crumbs_for.appendSlice(self.gpa, d.path) catch {};
    ui.clear(txn, self.path_dir);
    if (d.isTrash()) {
        _ = self.crumb(txn, "Trash/", null);
        return;
    }
    const home = self.app.home;
    const in_home = home.len > 1 and (std.mem.eql(u8, d.path, home) or model.isWithin(d.path, home));
    // Segments: their labels and where they go.
    var labels: std.ArrayList([]const u8) = .empty;
    defer labels.deinit(self.gpa);
    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(self.gpa);
    labels.append(self.gpa, if (in_home) "~" else "/") catch return;
    ends.append(self.gpa, if (in_home) home.len else 1) catch return;
    const rest_from = if (in_home) home.len else 0;
    var it = std.mem.tokenizeScalar(u8, d.path[rest_from..], '/');
    while (it.next()) |seg| {
        labels.append(self.gpa, seg) catch return;
        ends.append(self.gpa, @intFromPtr(seg.ptr) - @intFromPtr(d.path.ptr) + seg.len) catch return;
    }
    for (labels.items, ends.items, 0..) |label, end, i| {
        if (i > 1 or (i == 1 and in_home)) _ = self.crumb(txn, "/", null);
        const last = i + 1 == labels.items.len;
        _ = self.crumb(txn, label, if (last) null else d.path[0..end]);
    }
    if (!std.mem.eql(u8, d.path, "/")) _ = self.crumb(txn, "/", null);
}

fn crumb(self: *Window, txn: Txn, label: []const u8, path: ?[]const u8) Node {
    const n = c.siv_text(txn, self.path_dir, label.ptr, label.len);
    // Folders above give way first when the path is too long, so the
    // current folder stays whole.
    _ = c.siv_set_text_style(txn, n, &.{ .color_token = .accent, .size_role = .body, .weight = .bold, .direction = .ltr, .flags = .{ .no_wrap = true, .ellipsize = path != null } });
    _ = c.siv_set_layout(txn, n, if (path != null) &.{ .shrink = 1, .min_width = 0 } else &.{ .flags = .{ .no_shrink = true } });
    const p = path orelse return n;
    const copy = self.gpa.dupe(u8, p) catch return n;
    self.crumbs.append(self.gpa, .{ .node = n, .path = copy }) catch {
        self.gpa.free(copy);
        return n;
    };
    _ = c.siv_set_cursor(txn, n, .pointer);
    _ = c.siv_set_semantics(txn, n, &.{ .role = .link, .label = label.ptr, .label_len = label.len, .flags = .{ .focusable = false } });
    _ = c.siv_on(txn, n, .pointer, onCrumbPointer, null, self);
    return n;
}

fn onCrumbPointer(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const self: *Window = @ptrCast(@alignCast(ud.?));
    const cr = for (self.crumbs.items) |x| {
        if (x.node == node) break x;
    } else return .pass;
    switch (ev.phase) {
        .enter, .leave => if (self.begin()) |txn| {
            var tb: [linux.PATH_MAX]u8 = undefined;
            const len = ui.getText(node, &tb).len;
            const spans = [_]siv.TextSpan{.{ .start = 0, .end = @intCast(len), .flags = .{ .underline = true } }};
            _ = c.siv_set_text_spans(txn, node, &.{ .spans = &spans, .spans_count = if (ev.phase == .enter) 1 else 0 });
            _ = commit(txn);
        },
        .down => {
            // A copy: going there rebuilds the crumbs.
            var pb: [linux.PATH_MAX]u8 = undefined;
            if (cr.path.len > pb.len) return .handled;
            @memcpy(pb[0..cr.path.len], cr.path);
            const path = pb[0..cr.path.len];
            switch (ev.button) {
                .primary => self.cd(path),
                .middle => self.newTab(path),
                else => return .pass,
            }
            _ = c.siv_node_focus(self.current.view);
            return .handled;
        },
        else => {},
    }
    return .pass;
}

/// The status line: the mode, the entry's details, pending keys, and
/// where the cursor is.
fn applyStatus(self: *Window, txn: Txn) void {
    const d = self.curDir();
    const app = self.app;
    // The mode badge.
    // A chooser has two modes, as vim: typing the name or a path, or
    // moving in the columns.
    const mode_text: []const u8 = switch (self.mode) {
        .visual => "VISUAL",
        .tasks => "TASKS",
        .normal => if (self.chooser) |ch| (if (ch.nameFocused()) "INSERT" else "NORMAL") else "",
    };
    _ = c.siv_set_text(txn, self.status_mode, mode_text.ptr, mode_text.len);
    _ = c.siv_set_hidden(txn, self.status_mode, mode_text.len == 0);
    // Left: a message, the question being asked, or the entry's details.
    var lbuf: [512]u8 = undefined;
    var left: []const u8 = "";
    var left_token: siv.ColorToken = .muted_fg;
    if (self.await_key != .none) {
        left = self.questionText(&lbuf);
        left_token = .window_fg;
    } else if (self.mode == .tasks and self.message.items.len == 0) {
        // The selected task, for screen readers (the status line is a
        // live region) and at a glance.
        if (app.taskAt(self.task_cursor)) |t| {
            var tb: [512]u8 = undefined;
            left = switch (t) {
                .running => |e| std.fmt.bufPrint(&lbuf, "{s}: {s}", .{ e.op.title(&tb), taskState(e) }) catch "",
                .finished => |f| std.fmt.bufPrint(&lbuf, "{s}: {s}", .{ f.title, f.result }) catch "",
            };
        } else left = "No file operations yet";
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
        if (op.isPaused()) {
            w.print("{s}: paused   ", .{verb}) catch {};
        } else if (op.asking.load(.acquire)) {
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
    // A folder the cache holds is a folder; anything else is looked at
    // on a worker, so a slow or hung file system never holds the keys.
    if (std.mem.eql(u8, path, self.app.places.trash_files) or self.app.cache.dirs.get(path) != null)
        return self.cdKnown(path, select, record);
    self.probe(path, select, record);
}

/// Shows `path`, a folder (a listing or the cache said so).
pub fn cdKnown(self: *Window, path: []const u8, select: ?[]const u8, record: bool) void {
    self.probe_gen +%= 1; // a pending probe is overtaken
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
    self.app.zoxideAdd(d);
    if (self.app.lua) |l| l.emit("cd", d.path);
}

/// What a path is (folder, file, nothing), found on a worker; the newest
/// cd wins.
const Probe = struct {
    win: ?*Window,
    gpa: std.mem.Allocator,
    gen: u64,
    path: []u8,
    select: ?[]u8,
    record: bool,
    kind: enum { dir, file, missing } = .missing,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const pr: *Probe = @ptrCast(@alignCast(ud.?));
        pr.kind = if (isDirPath(pr.path)) .dir else if (isPath(pr.path)) .file else .missing;
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const pr: *Probe = @ptrCast(@alignCast(ud.?));
        const w = pr.win orelse return;
        if (w.probing == pr) w.probing = null;
        if (pr.gen != w.probe_gen or w.tabs.items.len == 0) return;
        switch (pr.kind) {
            .dir => w.cdKnown(pr.path, pr.select, pr.record),
            // A file: its folder, with the cursor on it.
            .file => w.cdSelect(model.parent(pr.path), model.basename(pr.path), pr.record),
            .missing => {
                var mbuf: [linux.PATH_MAX + 32]u8 = undefined;
                w.notify(std.fmt.bufPrint(&mbuf, "No such folder: {s}", .{pr.path}) catch "No such folder", true);
            },
        }
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const pr: *Probe = @ptrCast(@alignCast(ud.?));
        if (pr.win) |w| if (w.probing == pr) {
            w.probing = null;
        };
        pr.gpa.free(pr.path);
        if (pr.select) |x| pr.gpa.free(x);
        pr.gpa.destroy(pr);
    }
};

fn probe(self: *Window, path: []const u8, select: ?[]const u8, record: bool) void {
    const gpa = self.gpa;
    self.probe_gen +%= 1;
    const pr = gpa.create(Probe) catch return;
    pr.* = .{ .win = self, .gpa = gpa, .gen = self.probe_gen, .path = gpa.dupe(u8, path) catch return gpa.destroy(pr), .select = null, .record = record };
    if (select) |x| pr.select = gpa.dupe(u8, x) catch null;
    if (self.probing) |old| old.win = null;
    self.probing = pr;
    // The destroy-notify runs if the job cannot start.
    _ = c.siv_job_start(self.app.app, .{}, Probe.work, Probe.done, Probe.destroy, pr);
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
    if (self.chooser) |ch| return ch.enter(self);
    const d = self.curDir();
    const e = d.current() orelse return;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, d.cursor) orelse return;
    if (e.kind == .dir) return self.cdKnown(p, null, true);
    self.openTargets();
}

/// h: the parent folder.
pub fn leave(self: *Window) void {
    const d = self.curDir();
    if (d.isTrash()) return self.cd(self.app.home);
    if (std.mem.eql(u8, d.path, "/")) return;
    self.cdKnown(model.parent(d.path), null, true);
}

/// Opens the targets with their default applications.
pub fn openTargets(self: *Window) void {
    const paths = self.targets() catch return;
    defer App.freePaths(self.gpa, paths);
    if (paths.len == 0) return;
    // One folder: go in (the listing knows it is one; a path from
    // elsewhere is looked at off this thread).
    if (paths.len == 1) {
        const d = self.curDir();
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        if (d.current()) |e| if (d.pathAt(&pbuf, d.cursor)) |cp| if (std.mem.eql(u8, cp, paths[0])) {
            if (e.kind == .dir) return self.cdKnown(cp, null, true);
            return self.app.openPaths(self, toConst(paths), null);
        };
        if (isDirPath(paths[0])) return self.cd(paths[0]);
    }
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

/// The shown indices commands act on: the visual range, else the marks,
/// else the cursor's.
pub fn selectedIndices(self: *Window, gpa: Allocator) ![]u32 {
    const d = self.curDir();
    if (self.mode == .visual) {
        const lo = @min(self.visual_anchor, d.cursor);
        const hi = @max(self.visual_anchor, d.cursor);
        const out = try gpa.alloc(u32, hi - lo + 1);
        for (out, 0..) |*x, i| x.* = lo + @as(u32, @intCast(i));
        return out;
    }
    if (d.mark_count != 0) return d.markedIndices(gpa);
    if (d.count() == 0) return gpa.alloc(u32, 0);
    const out = try gpa.alloc(u32, 1);
    out[0] = d.cursor;
    return out;
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
    if (self.prompt != null or self.tabs.items.len == 0 or self.dialogs.isOpen()) return .pass;
    const m = ev.modifiers;
    // A chooser's name field takes its keys (insert mode); Tab goes to it.
    if (self.chooser) |ch| {
        if (ch.nameFocused()) return .pass;
        if (ev.keysym == .tab and !m.ctrl and !m.alt and !m.shift and !m.super and ch.focusName()) return .handled;
    }
    const text = if (ev.text) |t| t[0..ev.text_len] else "";
    const keysym: u32 = @bitCast(@intFromEnum(ev.keysym));
    const k = keys.fromEvent(keysym, text, m.ctrl, m.alt, m.super, m.shift) orelse return .pass;
    if (self.chooserInsertKey(k)) return .handled;
    return if (self.handleKey(k)) .handled else .pass;
}

/// A chooser's way into insert mode, as in vim: i, a, I, A, cc,
/// and S, over what the keymap binds to them (create, rename, terminal).
fn chooserInsertKey(self: *Window, k: keys.Key) bool {
    if (self.chooser == null) return false;
    if (self.mode != .normal or self.await_key != .none or self.count != null) return false;
    if (!k.isChar() or k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    const arg: []const u8 = if (self.pending_len == 0) switch (k.code) {
        'i' => "",
        'a' => "stem",
        'I' => "start",
        'A' => "end",
        'S' => "clear",
        else => return false,
    } else if (self.pending_len == 1 and k.code == 'c' and self.pending[0].code == 'c' and self.pending[0].isChar() and @as(u8, @bitCast(self.pending[0].mods)) == 0)
        "clear"
    else
        return false;
    self.resetPending();
    var buf: [16]u8 = undefined;
    commands.execute(self, std.fmt.bufPrint(&buf, "insert {s}", .{arg}) catch return true, null, true);
    return true;
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
    if (self.visualFollowup(k)) return true;
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
        // A visual operator that takes the range into the register.
        const op: u32 = if (self.mode == .visual and self.pending_len == 1 and (k.code == 'y' or k.code == 'd') and k.isChar()) k.code else 0;
        self.resetPending();
        self.run(action, count);
        if (op != 0 and self.mode == .normal) self.visual_op = op;
        return true;
    };
    if (match.prefix) {
        self.scheduleWhichKey();
        self.updateStatus();
        return true;
    }
    // Nothing: the keys so far mean nothing together. Say so for typed
    // keys and sequences, so a key that does nothing is not silent; other
    // keys (arrows, Ctrl+...) may still be the focused widget's.
    const was_pending = self.pending_len > 1;
    if (was_pending or k.isChar()) {
        var kb: [64]u8 = undefined;
        var mb: [128]u8 = undefined;
        const seq = keys.format(&kb, self.pending[0..self.pending_len]);
        self.notify(std.fmt.bufPrint(&mb, "{s} isn't bound in {s} mode", .{ seq, @tagName(self.mode) }) catch "Not bound", false);
    }
    self.resetPending();
    return was_pending or !(k.code == keys.sym.tab and @as(u8, @bitCast(k.mods)) == 0);
}

/// The second key of yy, dd, dT, or dD after visual y or d, which acted
/// at once: the files are in the register, and nothing changed on disk
/// yet, so dT and dD trash or delete them instead of the cut.
fn visualFollowup(self: *Window, k: keys.Key) bool {
    const op = self.visual_op;
    self.visual_op = 0;
    if (op == 0 or self.pending_len != 0 or self.count != null or !k.isChar()) return false;
    if (k.code == op) return true;
    if (op != 'd' or (k.code != 'T' and k.code != 'D')) return false;
    const app = self.app;
    if (app.register.items.len == 0 or !app.register_cut) return false;
    const paths = app.gpa.alloc([]const u8, app.register.items.len) catch return true;
    defer app.gpa.free(paths);
    for (app.register.items, paths) |p, *q| q.* = p;
    if (k.code == 'T') {
        app.startOp(self, .trash, paths, "", &.{}, true);
    } else self.confirmDelete(paths);
    app.setRegister(&.{}, false);
    return true;
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

/// `p` with the home as "~", in `buf`.
pub fn shortPathIn(self: *Window, buf: []u8, p: []const u8) []const u8 {
    const home = self.app.home;
    if (std.mem.eql(u8, p, home)) return "~";
    if (home.len > 1 and model.isWithin(p, home)) return std.fmt.bufPrint(buf, "~{s}", .{p[home.len..]}) catch p;
    return p;
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

// Context menus -----------------------------------------------------------------------------

/// A right click on entry `i` of the current column: a GUI's convention,
/// the menu acts on the selection when the entry is in it, else on the
/// entry alone (the marks go, the cursor moves there).
pub fn contextMenuAt(self: *Window, i: u32, anchor: Node, x: f32, y: f32) void {
    const d = self.curDir();
    const in_selection = (self.mode == .visual and self.inVisualRange(&self.current, i)) or (self.mode != .visual and d.mark_count != 0 and d.isMarked(i));
    if (!in_selection) {
        if (self.mode == .visual) self.endVisual();
        if (d.mark_count != 0) {
            d.clearMarks();
            self.rebindCurrent();
        }
        self.moveCursor(i);
    }
    self.menu.open(.entries, anchor, x, y);
}

/// The Menu key or Shift+F10: the menu at the cursor's row (the folder's
/// when it is empty).
pub fn contextMenuAtCursor(self: *Window) void {
    const d = self.curDir();
    if (d.count() == 0) return self.menu.open(.folder, self.current.view, 40, 20);
    const row = c.siv_view_get_row(self.current.view, d.cursor);
    if (row == .null) return self.menu.open(.entries, self.current.view, 40, 20);
    self.menu.open(.entries, row, 48, Column.row_height);
}

// The tasks view ----------------------------------------------------------------------------

pub fn openTasks(self: *Window) void {
    self.endVisual();
    self.resetPending();
    self.mode = .tasks;
    self.task_cursor = 0;
    if (self.begin()) |txn| {
        _ = c.siv_set_hidden(txn, self.tasks, false);
        _ = commit(txn);
    }
    self.refreshTasks();
    self.updateStatus();
}

pub fn closeTasks(self: *Window) void {
    if (self.mode != .tasks) return;
    self.mode = .normal;
    if (self.begin()) |txn| {
        _ = c.siv_set_hidden(txn, self.tasks, true);
        ui.clear(txn, self.tasks);
        _ = commit(txn);
    }
    self.updateStatus();
}

pub fn moveTaskCursor(self: *Window, delta: i32) void {
    const n = self.app.taskCount();
    if (n == 0) return;
    const to = @as(i64, @intCast(self.task_cursor)) + delta;
    self.task_cursor = @intCast(std.math.clamp(to, 0, @as(i64, @intCast(n - 1))));
    self.refreshTasks();
    self.updateStatus();
}

/// "45%", "Paused", "Counting…": where a running task is.
fn taskState(e: *const App.OpEntry) []const u8 {
    const S = struct {
        threadlocal var buf: [32]u8 = undefined;
    };
    const op = e.op;
    if (op.isPaused()) return "Paused";
    if (e.asking) return "Waiting for an answer";
    if (op.scanning.load(.acquire)) return "Counting…";
    return std.fmt.bufPrint(&S.buf, "{d}%", .{taskPercent(op)}) catch "";
}

fn taskPercent(op: *const fsops.Op) u64 {
    const total = op.total_bytes.load(.monotonic);
    if (total > 0) return @min(100, op.done_bytes.load(.monotonic) * 100 / total);
    const items = op.total_items.load(.monotonic);
    if (items > 0) return @min(100, @as(u64, op.done_items.load(.monotonic)) * 100 / items);
    return 0;
}

/// Builds the tasks view's rows again (while it is open): each running
/// task's title, state, progress, and current file; each finished one's
/// title and what came of it.
pub fn refreshTasks(self: *Window) void {
    if (self.mode != .tasks) return;
    const app = self.app;
    const n = app.taskCount();
    if (self.task_cursor >= n) self.task_cursor = n -| 1;
    const txn = self.begin() orelse return;
    ui.clear(txn, self.tasks);
    const head = c.siv_text(txn, self.tasks, "Tasks", 5);
    _ = c.siv_set_text_style(txn, head, &.{ .color_token = .card_fg, .size_role = .heading, .weight = .bold });
    _ = c.siv_set_semantics(txn, head, &.{ .role = .heading, .level = 2 });
    if (n == 0) _ = ui.text(txn, self.tasks, "No file operations yet: copies, moves, and deletes show here.", .muted_fg, .body);
    for (0..n) |i| {
        const t = app.taskAt(i).?;
        const selected = i == self.task_cursor;
        var tb: [512]u8 = undefined;
        const title = switch (t) {
            .running => |e| e.op.title(&tb),
            .finished => |f| f.title,
        };
        const row = c.siv_flex(txn, self.tasks, &.{ .axis = .column, .gap = 4 });
        _ = c.siv_set_layout(txn, row, &.{ .width = ui.fill(), .padding = .{ .start = 10, .end = 10, .top = 6, .bottom = 6 } });
        _ = c.siv_set_visual(txn, row, &.{ .background_token = if (selected) .selection_bg else .none, .radius = .{ .top_start = 6, .top_end = 6, .bottom_start = 6, .bottom_end = 6 } });
        _ = c.siv_set_semantics(txn, row, &.{ .role = .list_item, .label = title.ptr, .label_len = title.len, .selected = if (selected) .on else .off, .position = @intCast(i + 1), .set_size = @intCast(n) });
        const line = c.siv_flex(txn, row, &.{ .axis = .row, .gap = 12, .align_items = .center });
        _ = c.siv_set_layout(txn, line, &.{ .width = ui.fill() });
        const tt = c.siv_text(txn, line, title.ptr, title.len);
        _ = c.siv_set_layout(txn, tt, &.{ .grow = 1, .basis = px(0) });
        _ = c.siv_set_text_style(txn, tt, &.{ .color_token = if (selected) .selection_fg else .card_fg, .size_role = .body, .weight = .bold, .flags = .{ .no_wrap = true, .ellipsize = true } });
        switch (t) {
            .running => |e| {
                const st = taskState(e);
                const sn = ui.text(txn, line, st, if (e.op.isPaused()) .warning else .accent, .caption);
                _ = c.siv_set_layout(txn, sn, &.{ .flags = .{ .no_shrink = true } });
                const bar = c.siv_progress_bar(txn, row, &.{ .label = title.ptr, .label_len = title.len, .min = 0, .max = 100, .value = @floatFromInt(taskPercent(e.op)) });
                _ = c.siv_set_layout(txn, bar, &.{ .width = ui.fill() });
                var db: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&db);
                var b1: [32]u8 = undefined;
                var b2: [32]u8 = undefined;
                const total = e.op.total_bytes.load(.monotonic);
                if (total > 0) w.print("{s} of {s}   ", .{ model.formatSize(&b1, e.op.done_bytes.load(.monotonic)), model.formatSize(&b2, total) }) catch {};
                const items = e.op.total_items.load(.monotonic);
                if (items > 0) w.print("{d} of {d} items   ", .{ e.op.done_items.load(.monotonic), items }) catch {};
                var cb: [256]u8 = undefined;
                w.writeAll(e.op.currentName(&cb)) catch {};
                const detail = w.buffered();
                const dn = c.siv_text(txn, row, detail.ptr, detail.len);
                _ = c.siv_set_text_style(txn, dn, &.{ .color_token = if (selected) .selection_fg else .muted_fg, .size_role = .caption, .flags = .{ .no_wrap = true, .ellipsize = true } });
            },
            .finished => |f| {
                const label: []const u8 = if (f.failed) "Failed" else if (f.canceled) "Canceled" else "Done";
                const sn = ui.text(txn, line, label, if (f.failed) .destructive else .muted_fg, .caption);
                _ = c.siv_set_layout(txn, sn, &.{ .flags = .{ .no_shrink = true } });
                const dn = c.siv_text(txn, row, f.result.ptr, f.result.len);
                _ = c.siv_set_text_style(txn, dn, &.{ .color_token = if (f.failed) .destructive else if (selected) .selection_fg else .muted_fg, .size_role = .caption, .flags = .{ .no_wrap = true, .ellipsize = true } });
            },
        }
    }
    const hint = "j k move   p pause or resume   x cancel, or remove a finished task   Esc close";
    const hn = ui.text(txn, self.tasks, hint, .muted_fg, .caption);
    _ = c.siv_set_layout(txn, hn, &.{ .padding = .{ .top = 4 } });
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

/// An operation found its target taken: a quick question in the status
/// line for a single item, a dialog comparing the two when there are
/// more (folders included), with a choice for every later conflict.
pub fn askConflict(self: *Window, e: *App.OpEntry) void {
    self.conflict = e;
    if (e.op.sources.len > 1 or e.op.conflict.src_dir) return self.dialogs.askConflict(e);
    self.awaitKey(.conflict);
}

pub fn confirmDelete(self: *Window, paths: []const []const u8) void {
    for (self.confirm_paths.items) |p| self.gpa.free(p);
    self.confirm_paths.clearRetainingCapacity();
    for (paths) |p| self.confirm_paths.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
    if (!self.app.options.confirm_delete) return self.answerAwait(.{ .code = 'y' });
    // What cannot be undone gets a dialog, not a y/N in the status line.
    self.dialogs.confirmDelete(paths);
    for (self.confirm_paths.items) |p| self.gpa.free(p);
    self.confirm_paths.clearRetainingCapacity();
}

pub fn opFinished(self: *Window, op: *fsops.Op, undoable: bool) void {
    _ = undoable;
    var buf: [512]u8 = undefined;
    const msg, const is_error = op.summary(&buf);
    if (msg.len != 0) self.notify(msg, is_error);
    if (op.result != null) return;
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
    const label = if (kind == .pick) self.picker.label() else kind.label();
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
        .pick => if (self.picker.kind == .files) "Find a file or folder" else "Jump to a folder",
    };
    _ = c.siv_set_semantics(txn, self.cmd_editor, &.{ .role = .text_input, .label = sem_label.ptr, .label_len = sem_label.len, .flags = .{ .focusable = true } });
    self.applyStatus(txn);
    _ = commit(txn);
    _ = c.siv_node_focus(if (kind == .passphrase) self.pass_editor else self.cmd_editor);
}

pub fn closePrompt(self: *Window) void {
    if (self.prompt == .pick) self.picker.close();
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
            if (kind == .pick) self.picker.move(if (ev.keysym == .tab and !m.shift) 1 else -1);
            return .handled;
        },
        .page_up, .page_down => if (kind == .pick) {
            self.picker.move(if (ev.keysym == .page_down) Picker.rows else -Picker.rows);
            return .handled;
        },
        .up, .down => {
            if (kind == .pick) {
                self.picker.move(if (ev.keysym == .up) -1 else 1);
                return .handled;
            }
            if (kind == .command or kind == .shell) {
                self.recallHistory(if (ev.keysym == .up) -1 else 1);
                return .handled;
            }
            return .stop;
        },
        else => {},
    }
    // Ctrl+N and Ctrl+P (Ctrl+J and Ctrl+K) move in the picker, as in fzf.
    if (kind == .pick and m.ctrl) switch (@intFromEnum(ev.keysym)) {
        'n', 'j' => {
            self.picker.move(1);
            return .handled;
        },
        'p', 'k' => {
            self.picker.move(-1);
            return .handled;
        },
        else => {},
    };
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
        .pick => self.picker.setQuery(t),
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

/// Opens the picker: files and folders below this one, or zoxide's.
pub fn startPicker(self: *Window, kind: Picker.Kind, query: []const u8) void {
    if (self.prompt != null) self.closePrompt();
    self.picker.start(kind, self.curDir().path, self.app.options.show_hidden);
    self.startPrompt(.pick, query, @intCast(query.len), @intCast(query.len));
    if (query.len != 0) self.picker.setQuery(query);
}

/// Enter in the picker: a folder opens; a file shows in its folder.
fn submitPick(self: *Window) void {
    var buf: [linux.PATH_MAX + 2]u8 = undefined;
    const got = self.picker.chosen(&buf);
    var copy: [linux.PATH_MAX + 2]u8 = undefined;
    const path = if (got) |g| copy[0..g.len] else null;
    if (got) |g| @memcpy(path.?, g);
    const kind = self.picker.kind;
    self.closePrompt();
    const p = path orelse return;
    if (std.mem.endsWith(u8, p, "/")) {
        const dir = p[0 .. p.len - 1];
        // A walk found the folder just now; zoxide's may be gone.
        if (kind == .files) self.cdKnown(dir, null, true) else self.cd(dir);
    } else self.cdKnown(model.parent(p), model.basename(p), true);
}

fn submitPrompt(self: *Window, kind: PromptKind) void {
    if (kind == .pick) return self.submitPick();
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
        .pick => {},
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

pub fn showCandidates(self: *Window, cands: []const []const u8) void {
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
    // A folder opens in a terminal first, then in what handles folders.
    const folder = t == mime.directory;
    var list = db.appsFor(self.gpa, types, t) catch return;
    if (list.len == 0 and !folder) {
        self.gpa.free(list);
        list = db.allApps(self.gpa) catch return;
    }
    defer self.gpa.free(list);
    if (list.len == 0 and !folder) return self.notify("No applications found", true);
    const state = self.gpa.create(OpenWith) catch return;
    state.* = .{ .win = self, .terminal = folder, .apps = self.gpa.dupe(*const @import("apps.zig").App, list) catch {
        self.gpa.destroy(state);
        return;
    }, .paths = .empty };
    for (paths) |p| state.paths.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
    const txn = self.begin() orelse return state.free();
    const menu = c.siv_menu(txn, self.root, &.{ .label = "Open with", .label_len = 9 });
    const first: usize = @intFromBool(folder);
    if (folder) _ = c.siv_menu_item(txn, menu, &.{ .label = "Terminal", .label_len = 8, .shortcut = "1", .shortcut_len = 1, .mnemonic = '1', .icon = "utilities-terminal", .icon_len = 18 });
    for (list, first..) |app, i| {
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
    /// Item 0 is the terminal (a folder).
    terminal: bool = false,
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
        const first: usize = @intFromBool(s.terminal);
        if (s.terminal and ev.index == 0) {
            if (s.paths.items.len != 0) s.win.app.openTerminal(s.win, s.paths.items[0]);
        } else if (ev.index >= first and ev.index - first < s.apps.len) s.win.app.launch(s.win, s.apps[ev.index - first], @ptrCast(s.paths.items));
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
