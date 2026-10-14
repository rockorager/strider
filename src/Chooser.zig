//! A file chooser: the FileChooser portal's OpenFile, SaveFile, and
//! SaveFiles (Portal.zig takes the calls), served by a window of the
//! app's own. It is the app's three columns with every key, preview, and
//! command, and a bar over the status line: the name to save as, the
//! request's filters and choices, and its buttons.
//!
//! Enter picks the file under the cursor, or the marked files when the
//! request allows several; on a folder it goes in, except when choosing
//! folders, where it picks that folder. l and double clicks go into
//! folders and pick files. Escape (with nothing to clear) and q cancel.
//! Saving is modal like vim: the name field is insert mode, the columns
//! normal mode; Escape goes from the name to the columns, and i, a, I,
//! A, cc, and S come back.
//! The answer goes back as the portal's response: 0 with the URIs, 1 when
//! the user cancelled, 2 when the caller closed the request.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Window = @import("Window.zig");
const commands = @import("commands.zig");
const model = @import("model.zig");
const uri = @import("uri.zig");
const ui = @import("ui.zig");
const bus = @import("bus.zig");

const Chooser = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const Kind = enum { open, save, save_files };

/// A filter as the request gave it: shown by name, and answered with as
/// it came (current_filter).
pub const Filter = struct {
    name: []const u8,
    rules: []const Rule,
    types: model.TypeFilter,
};
/// 0: a glob, 1: a MIME type.
pub const Rule = struct { kind: u32, pattern: []const u8 };

/// A choice: a check box when it has no options (its value "true" or
/// "false"), else a combo box of them (its value an option's id).
pub const Choice = struct {
    id: []const u8,
    label: []const u8,
    options: []const Option,
    initial: []const u8,
    node: Node = .null,
};
pub const Option = struct { id: []const u8, label: []const u8 };

app: *App,
arena: std.heap.ArenaAllocator,
kind: Kind,
conn: siv.Dbus,
invocation: siv.DbusInvocation,
/// The impl.portal.Request object at the request's handle (Close).
request: siv.DbusObject = .null,
handle: []const u8 = "",
app_id: []const u8 = "",
parent_window: []const u8 = "",
title: []const u8 = "",
accept_label: []const u8 = "",
modal: bool = true,
multiple: bool = false,
directory: bool = false,
filters: []Filter = &.{},
/// The filter shown, an index into filters.
filter: ?usize = null,
choices: []Choice = &.{},
current_name: []const u8 = "",
/// Where the window starts, and the name to put the cursor on there.
folder: []const u8 = "",
select: []const u8 = "",
/// SaveFiles: the names to save in the folder picked.
files: []const []const u8 = &.{},
win: ?*Window = null,
answered: bool = false,
/// Close came; the answer follows on a timer.
closing: bool = false,
close_timer: siv.Timer = .null,
/// When the call came (CLOCK_MONOTONIC), for the time to the first frame.
called_ns: u64 = 0,
/// Saving over files waits for the overwrite dialog: the URIs to answer.
pending: std.ArrayList([]const u8) = .empty,

bar: Node = .null,
field: Node = .null,
filter_combo: Node = .null,
accept_button: Node = .null,
cancel_button: Node = .null,

pub fn create(app: *App, kind: Kind, conn: siv.Dbus, invocation: siv.DbusInvocation) !*Chooser {
    const ch = try app.gpa.create(Chooser);
    ch.* = .{ .app = app, .arena = .init(app.gpa), .kind = kind, .conn = conn, .invocation = invocation, .called_ns = now() };
    return ch;
}

fn destroy(ch: *Chooser) void {
    const gpa = ch.app.gpa;
    ch.pending.deinit(gpa);
    ch.arena.deinit();
    gpa.destroy(ch);
}

fn a(ch: *Chooser) Allocator {
    return ch.arena.allocator();
}

pub fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// With STRIDER_TIMING set: how long the call took to show, and when
/// (the wall clock, to compare with the caller's).
pub fn firstFrame(ch: *const Chooser, commit_ns: u64) void {
    if (getenv("STRIDER_TIMING") == null) return;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const ms = @as(f64, @floatFromInt(commit_ns -| ch.called_ns)) / std.time.ns_per_ms;
    std.debug.print("strider: file chooser: first frame {d:.1} ms after the call (at {d}.{d:0>9})\n", .{ ms, ts.sec, @as(u64, @intCast(ts.nsec)) });
}

// Reading the request ---------------------------------------------------------------------

/// Reads `handle o, app_id s, parent_window s, title s, options a{sv}`.
pub fn read(ch: *Chooser, r: bus.Reader) void {
    const al = ch.a();
    ch.handle = bus.readString(r, al) orelse "";
    ch.app_id = bus.readString(r, al) orelse "";
    ch.parent_window = bus.readString(r, al) orelse "";
    ch.title = bus.readString(r, al) orelse "";
    // Chromium sends its "All Files" filter label as the title of a save
    // dialog it gave none (IDS_SAVEAS_ALL_FILES in
    // select_file_dialog_linux_portal.cc); that is no title.
    if (ch.kind == .save and std.mem.eql(u8, ch.title, "All Files")) ch.title = "";
    if (bus.next(r) != 'a' or !bus.enter(r)) return;
    defer bus.exit(r);
    while (bus.next(r) == '{') {
        if (!bus.enter(r)) break;
        defer bus.exit(r);
        const key = bus.readString(r, al) orelse continue;
        if (bus.next(r) != 'v' or !bus.enter(r)) continue;
        defer bus.exit(r);
        ch.readOption(key, r);
    }
}

fn readOption(ch: *Chooser, key: []const u8, r: bus.Reader) void {
    const al = ch.a();
    const eql = std.mem.eql;
    if (eql(u8, key, "accept_label")) {
        ch.accept_label = stripMnemonic(al, bus.readString(r, al) orelse "");
    } else if (eql(u8, key, "modal")) {
        ch.modal = (bus.readInt(r) orelse 1) != 0;
    } else if (eql(u8, key, "multiple")) {
        ch.multiple = (bus.readInt(r) orelse 0) != 0;
    } else if (eql(u8, key, "directory")) {
        ch.directory = (bus.readInt(r) orelse 0) != 0;
    } else if (eql(u8, key, "filters")) {
        var list: std.ArrayList(Filter) = .empty;
        if (bus.next(r) == 'a' and bus.enter(r)) {
            defer bus.exit(r);
            while (bus.next(r) == '(') if (ch.readFilter(r)) |f| list.append(al, f) catch {};
        }
        ch.filters = list.items;
    } else if (eql(u8, key, "current_filter")) {
        if (bus.next(r) == '(') if (ch.readFilter(r)) |f| {
            // The same filter as one of `filters` (by name), else one more.
            for (ch.filters, 0..) |x, i| if (eql(u8, x.name, f.name)) {
                ch.filter = i;
                return;
            };
            const grown = al.alloc(Filter, ch.filters.len + 1) catch return;
            @memcpy(grown[0..ch.filters.len], ch.filters);
            grown[ch.filters.len] = f;
            ch.filters = grown;
            ch.filter = grown.len - 1;
        };
    } else if (eql(u8, key, "choices")) {
        var list: std.ArrayList(Choice) = .empty;
        if (bus.next(r) == 'a' and bus.enter(r)) {
            defer bus.exit(r);
            while (bus.next(r) == '(') if (ch.readChoice(r)) |x| list.append(al, x) catch {};
        }
        ch.choices = list.items;
    } else if (eql(u8, key, "current_name")) {
        ch.current_name = bus.readString(r, al) orelse "";
    } else if (eql(u8, key, "current_folder")) {
        if (bus.readBytePath(r, al)) |p| if (p.len != 0) {
            ch.folder = p;
        };
    } else if (eql(u8, key, "current_file")) {
        if (bus.readBytePath(r, al)) |p| if (p.len != 0) {
            ch.folder = al.dupe(u8, model.parent(p)) catch "";
            ch.select = al.dupe(u8, model.basename(p)) catch "";
            if (ch.current_name.len == 0) ch.current_name = ch.select;
        };
    } else if (eql(u8, key, "files")) {
        var list: std.ArrayList([]const u8) = .empty;
        if (bus.next(r) == 'a' and bus.enter(r)) {
            defer bus.exit(r);
            while (bus.next(r) == 'a') {
                const n = bus.readBytePath(r, al) orelse break;
                if (n.len != 0) list.append(al, model.basename(n)) catch {};
            }
        }
        ch.files = list.items;
    }
}

/// `(sa(us))`: a name and its rules.
fn readFilter(ch: *Chooser, r: bus.Reader) ?Filter {
    const al = ch.a();
    if (!bus.enter(r)) return null;
    defer bus.exit(r);
    const name = bus.readString(r, al) orelse return null;
    var rules: std.ArrayList(Rule) = .empty;
    var globs: std.ArrayList([]const u8) = .empty;
    var mimes: std.ArrayList([]const u8) = .empty;
    if (bus.next(r) == 'a' and bus.enter(r)) {
        defer bus.exit(r);
        while (bus.next(r) == '(') {
            if (!bus.enter(r)) break;
            defer bus.exit(r);
            const kind: u32 = @intCast(bus.readInt(r) orelse continue);
            const pattern = bus.readString(r, al) orelse continue;
            rules.append(al, .{ .kind = kind, .pattern = pattern }) catch {};
            if (kind == 0) {
                globs.append(al, std.ascii.allocLowerString(al, pattern) catch continue) catch {};
            } else mimes.append(al, pattern) catch {};
        }
    }
    return .{ .name = name, .rules = rules.items, .types = .{ .globs = globs.items, .mimes = mimes.items } };
}

/// `(ssa(ss)s)`: an id, a label, options, and the initial value.
fn readChoice(ch: *Chooser, r: bus.Reader) ?Choice {
    const al = ch.a();
    if (!bus.enter(r)) return null;
    defer bus.exit(r);
    const id = bus.readString(r, al) orelse return null;
    const label = bus.readString(r, al) orelse return null;
    var options: std.ArrayList(Option) = .empty;
    if (bus.next(r) == 'a' and bus.enter(r)) {
        defer bus.exit(r);
        while (bus.next(r) == '(') {
            if (!bus.enter(r)) break;
            defer bus.exit(r);
            const oid = bus.readString(r, al) orelse continue;
            const olabel = bus.readString(r, al) orelse continue;
            options.append(al, .{ .id = oid, .label = olabel }) catch {};
        }
    }
    const initial = bus.readString(r, al) orelse "";
    return .{ .id = id, .label = stripMnemonic(al, label), .options = options.items, .initial = initial };
}

/// "_Open" is "Open": GTK's mnemonic marks, which the bar does not use.
fn stripMnemonic(al: Allocator, s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '_') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '_') {
            if (i + 1 < s.len and s[i + 1] == '_') {
                out.append(al, '_') catch return s;
                i += 1;
            }
            continue;
        }
        out.append(al, s[i]) catch return s;
    }
    return out.items;
}

// Defaults ---------------------------------------------------------------------------------

pub fn windowTitle(ch: *const Chooser) []const u8 {
    if (ch.title.len != 0) return ch.title;
    return switch (ch.kind) {
        .open => if (ch.directory) (if (ch.multiple) "Choose Folders" else "Choose a Folder") else if (ch.multiple) "Open Files" else "Open a File",
        .save => "Save a File",
        .save_files => "Choose a Folder to Save In",
    };
}

fn acceptText(ch: *const Chooser) []const u8 {
    if (ch.accept_label.len != 0) return ch.accept_label;
    return switch (ch.kind) {
        .open => if (ch.directory) "Choose" else "Open",
        .save, .save_files => "Save",
    };
}

/// Whether picking takes folders (OpenFile with directory, SaveFiles).
fn picksFolders(ch: *const Chooser) bool {
    return ch.kind == .save_files or (ch.kind == .open and ch.directory);
}

/// The filter the columns show, if any.
pub fn types(ch: *const Chooser) ?*const model.TypeFilter {
    // Filters only make sense for files.
    if (ch.picksFolders()) return null;
    const i = ch.filter orelse (if (ch.filters.len != 0) @as(?usize, 0) else null) orelse return null;
    return &ch.filters[i].types;
}

// The bar ---------------------------------------------------------------------------------

/// The bar, in the window's column under the columns: a row of the
/// request's filters and choices, which wraps, over a row of the name to
/// save as (or a hint) and the buttons. Only the name or the hint gives
/// way when the window is narrow, so the buttons always show.
pub fn build(ch: *Chooser, txn: Txn, parent: Node) void {
    if (ch.filter == null and ch.filters.len != 0) ch.filter = 0;
    ch.bar = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 8 });
    _ = c.siv_set_layout(txn, ch.bar, &.{ .padding = .{ .start = 12, .end = 12, .top = 8, .bottom = 8 } });
    _ = c.siv_set_visual(txn, ch.bar, &.{ .background_token = .window_bg });
    _ = c.siv_set_semantics(txn, ch.bar, &.{ .role = .group, .label = "File chooser", .label_len = 12 });
    const has_filter = ch.filters.len != 0 and !ch.picksFolders();
    if (has_filter or ch.choices.len != 0) {
        const opts = c.siv_flex(txn, ch.bar, &.{ .axis = .row, .gap = 10, .line_gap = 6, .align_items = .center, .flags = .{ .wrap = true, .line_gap = true } });
        if (has_filter) {
            ch.filter_combo = c.siv_combo_box(txn, opts, &.{ .label = "Filter", .label_len = 6 });
            for (ch.filters) |f| _ = c.siv_combo_box_item(txn, ch.filter_combo, &.{ .label = f.name.ptr, .label_len = f.name.len });
            _ = c.siv_widget_set_value(txn, ch.filter_combo, @floatFromInt(ch.filter orelse 0));
            _ = c.siv_on(txn, ch.filter_combo, .change, onFilter, null, ch);
            combo(txn, ch.filter_combo);
        }
        for (ch.choices) |*x| {
            if (x.options.len == 0) {
                x.node = c.siv_check_box(txn, opts, &.{ .label = x.label.ptr, .label_len = x.label.len, .checked = if (std.mem.eql(u8, x.initial, "true")) .on else .off });
                fixed(txn, x.node);
                continue;
            }
            // The label and its combo box wrap together.
            const pair = c.siv_flex(txn, opts, &.{ .axis = .row, .gap = 6, .align_items = .center });
            fixed(txn, ui.text(txn, pair, x.label, .window_fg, .body));
            x.node = c.siv_combo_box(txn, pair, &.{ .label = x.label.ptr, .label_len = x.label.len });
            var selected: usize = 0;
            for (x.options, 0..) |o, i| {
                _ = c.siv_combo_box_item(txn, x.node, &.{ .label = o.label.ptr, .label_len = o.label.len });
                if (std.mem.eql(u8, o.id, x.initial)) selected = i;
            }
            _ = c.siv_widget_set_value(txn, x.node, @floatFromInt(selected));
            combo(txn, x.node);
        }
    }
    const row = c.siv_flex(txn, ch.bar, &.{ .axis = .row, .gap = 10, .align_items = .center });
    if (ch.kind == .save) {
        fixed(txn, ui.text(txn, row, "Name", .window_fg, .body));
        ch.field = c.siv_editor(txn, row, .{});
        ch.styleField(txn);
        _ = c.siv_set_semantics(txn, ch.field, &.{ .role = .text_input, .label = "Name", .label_len = 4, .flags = .{ .focusable = true } });
        _ = c.siv_set_text(txn, ch.field, ch.current_name.ptr, ch.current_name.len);
        // The name without its extension selected, ready to type over.
        const stem = if (std.mem.lastIndexOfScalar(u8, ch.current_name, '.')) |dot| (if (dot > 0) dot else ch.current_name.len) else ch.current_name.len;
        _ = c.siv_set_selection(txn, ch.field, @intCast(stem), 0);
        _ = c.siv_on(txn, ch.field, .key, onNameKey, null, ch);
        _ = c.siv_on(txn, ch.field, .focus, onNameFocus, null, ch);
    } else {
        // A path to type (insert mode), where Save has its name; empty in
        // normal mode, showing the keys instead.
        fixed(txn, ui.text(txn, row, "Path", .window_fg, .body));
        ch.field = c.siv_editor(txn, row, .{});
        ch.styleField(txn);
        _ = c.siv_set_semantics(txn, ch.field, &.{ .role = .text_input, .label = "Path", .label_len = 4, .flags = .{ .focusable = true } });
        const h = ch.hint();
        _ = c.siv_set_placeholder(txn, ch.field, h.ptr, h.len);
        _ = c.siv_on(txn, ch.field, .key, onNameKey, null, ch);
        _ = c.siv_on(txn, ch.field, .focus, onNameFocus, null, ch);
    }
    ch.cancel_button = c.siv_push_button(txn, row, &.{ .label = "Cancel", .label_len = 6 });
    _ = c.siv_on(txn, ch.cancel_button, .activate, onCancelButton, null, ch);
    fixed(txn, ch.cancel_button);
    const label = ch.acceptText();
    ch.accept_button = c.siv_push_button(txn, row, &.{ .label = label.ptr, .label_len = label.len, .style = .primary });
    _ = c.siv_on(txn, ch.accept_button, .activate, onAcceptButton, null, ch);
    fixed(txn, ch.accept_button);
}

/// The name or path field: it takes what the row has left.
fn styleField(ch: *Chooser, txn: Txn) void {
    _ = c.siv_set_layout(txn, ch.field, &.{ .grow = 1, .shrink = 1, .basis = ui.px(0), .min_width = 60, .padding = .{ .start = 6, .end = 6, .top = 4, .bottom = 4 } });
    _ = c.siv_set_visual(txn, ch.field, &.{ .background_token = .view_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 }, .flags = .{ .clip = true } });
    _ = c.siv_set_text_style(txn, ch.field, &.{ .color_token = .view_fg, .size_role = .body, .flags = .{ .no_wrap = true } });
}

/// A combo box as wide as its options, up to a limit, narrower when the
/// window is.
fn combo(txn: Txn, n: Node) void {
    _ = c.siv_set_layout(txn, n, &.{ .max_width = 260, .shrink = 1 });
}

/// Labels, boxes, and buttons keep their size; the hint or the name gives.
fn fixed(txn: Txn, n: Node) void {
    _ = c.siv_set_layout(txn, n, &.{ .flags = .{ .no_shrink = true } });
}

/// The keys that matter here, in the bar.
fn hint(ch: *const Chooser) []const u8 {
    return switch (ch.kind) {
        .open => if (ch.directory)
            (if (ch.multiple) "Enter chooses the folder under the cursor, or the marked ones · Space marks · l goes in · i types a path · Esc cancels" else "Enter chooses the folder under the cursor · l goes in · i types a path · Esc cancels")
        else if (ch.multiple) "Enter opens the file, or the marked ones · Space marks · i types a path · Esc cancels" else "Enter opens the file · i types a path · Esc cancels",
        .save => "",
        .save_files => "Enter chooses the folder under the cursor, else this folder · l goes in · i types a path · Esc cancels",
    };
}

/// Called once the window shows its first tab: Save starts in insert
/// mode, in its name; the others in normal mode, in the columns.
pub fn shown(ch: *Chooser) void {
    if (ch.kind == .save) _ = c.siv_node_focus(ch.field);
}

pub fn nameFocused(ch: *const Chooser) bool {
    const w = ch.win orelse return false;
    return ch.field != .null and c.siv_window_get_focus(w.window) == ch.field;
}

/// Tab between the columns and the name field.
pub fn focusName(ch: *Chooser) bool {
    if (ch.field == .null) return false;
    _ = c.siv_node_focus(ch.field);
    return true;
}

/// Insert mode is the name field having focus: the badge follows it,
/// however it moved (Escape, Tab, i, or a click).
fn onNameFocus(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    const w = ch.win orelse return .pass;
    // The path field starts from the folder shown, and empties again (to
    // show the keys) in normal mode.
    if (ch.kind != .save) if (w.begin()) |txn| {
        var tb: [8]u8 = undefined;
        if (!ev.flags.gained) {
            _ = c.siv_set_text(txn, ch.field, "", 0);
            w.hideWhichKey();
        } else if (ui.getText(ch.field, &tb).len == 0) {
            var buf: [linux.PATH_MAX + 2]u8 = undefined;
            const p = ch.shownPath(&buf, w);
            _ = c.siv_set_text(txn, ch.field, p.ptr, p.len);
            _ = c.siv_set_selection(txn, ch.field, @intCast(p.len), @intCast(p.len));
        }
        _ = ui.commit(txn);
    };
    w.updateStatus();
    return .pass;
}

/// The folder shown, as the path field starts: ~ for home, and a slash
/// to type a name after.
fn shownPath(ch: *Chooser, buf: []u8, w: *Window) []const u8 {
    const p = w.curDir().path;
    const home = ch.app.home;
    if (std.mem.eql(u8, p, "/")) return "/";
    if (home.len > 1 and std.mem.eql(u8, p, home)) return "~/";
    if (home.len > 1 and model.isWithin(p, home)) return std.fmt.bufPrint(buf, "~{s}/", .{p[home.len..]}) catch p;
    return std.fmt.bufPrint(buf, "{s}/", .{p}) catch p;
}

/// Where insert mode puts the caret in the name.
pub const Insert = enum {
    /// As it was (at first, the stem selected): i.
    keep,
    /// After the stem, before the extension: a.
    stem,
    /// At the start: I.
    start,
    /// At the end: A.
    end,
    /// An empty name: cc and S.
    clear,
};

/// Normal mode to insert mode (Save only).
pub fn insert(ch: *Chooser, how: Insert) bool {
    const w = ch.win orelse return false;
    if (ch.field == .null) return false;
    _ = c.siv_node_focus(ch.field);
    // A path is typed at its end; only a name keeps its selection.
    const at_end = how == .keep and ch.kind != .save;
    if (how != .keep or at_end) if (w.begin()) |txn| {
        var buf: [1024]u8 = undefined;
        const name = ui.getText(ch.field, &buf);
        const at: usize = switch (how) {
            .clear, .start => 0,
            .keep, .end => name.len,
            .stem => if (ch.kind != .save) name.len else if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| (if (dot > 0) dot else name.len) else name.len,
        };
        if (how == .clear) _ = c.siv_set_text(txn, ch.field, "", 0);
        _ = c.siv_set_selection(txn, ch.field, @intCast(at), @intCast(at));
        _ = ui.commit(txn);
    };
    return true;
}

fn onNameKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .pass;
    const w = ch.win orelse return .pass;
    switch (ev.keysym) {
        .@"return", .kp_enter => {
            if (ch.kind == .save) ch.saveAs(ch.nameText()) else ch.goPath(ch.nameText());
            return .handled;
        },
        // Escape leaves insert mode for the columns (normal mode), as in
        // vim; Escape there cancels once nothing is left to clear.
        .escape => {
            _ = c.siv_node_focus(w.current.view);
            return .handled;
        },
        // Tab goes between Save's name and the columns; a path completes,
        // as :cd's does.
        .tab => {
            if (ch.kind == .save) {
                _ = c.siv_node_focus(w.current.view);
            } else ch.completePath(w);
            return .handled;
        },
        else => return .pass,
    }
}

fn onFilter(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    if (ev.index >= 0 and @as(usize, @intCast(ev.index)) < ch.filters.len) ch.setFilter(@intCast(ev.index));
    return .handled;
}

/// Shows filter `i`: the folders this window shows filter by it.
pub fn setFilter(ch: *Chooser, i: usize) void {
    ch.filter = i;
    const w = ch.win orelse return;
    ch.applyTypes(w);
    w.showTab();
}

/// Puts the filter on the folders the window shows; others lose it.
pub fn applyTypes(ch: *Chooser, w: *Window) void {
    const t = ch.types();
    var it = ch.app.cache.dirs.valueIterator();
    while (it.next()) |d| {
        const mine = d.*.types != null and ch.ownsTypes(d.*.types.?);
        const here = d.* == w.curDir();
        if (here and d.*.types != t) {
            d.*.types = t;
            d.*.refilter();
        } else if (!here and mine) {
            d.*.types = null;
            d.*.refilter();
        }
    }
}

fn ownsTypes(ch: *const Chooser, t: *const model.TypeFilter) bool {
    for (ch.filters) |*f| if (&f.types == t) return true;
    return false;
}

fn onCancelButton(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    ch.finish(1);
    return .handled;
}

fn onAcceptButton(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    const w = ch.win orelse return .handled;
    if (ch.kind == .save) ch.saveAs(ch.nameText()) else if (ch.nameText().len != 0) ch.goPath(ch.nameText()) else ch.open(w);
    return .handled;
}

pub fn nameText(ch: *Chooser) []const u8 {
    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    return std.mem.trim(u8, ui.getText(ch.field, &S.buf), " ");
}

// Picking ----------------------------------------------------------------------------------

/// l and double clicks: into a folder, else what Enter does.
pub fn enter(ch: *Chooser, w: *Window) void {
    const d = w.curDir();
    if (d.current()) |e| if (e.kind == .dir) {
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        const p = d.pathAt(&pbuf, d.cursor) orelse return;
        return w.cdKnown(p, null, true);
    };
    ch.open(w);
}

/// Enter: picks what is under the cursor (or marked), or goes into a
/// folder when picking files.
pub fn open(ch: *Chooser, w: *Window) void {
    const d = w.curDir();
    const gpa = ch.app.gpa;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const sel = w.selectedIndices(gpa) catch return;
    defer gpa.free(sel);
    const several = ch.multiple and sel.len > 1;
    switch (ch.kind) {
        .open, .save_files => if (ch.picksFolders()) {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(gpa);
            if (several or (ch.multiple and sel.len == 1 and d.mark_count != 0)) {
                for (sel) |i| if (d.entryAt(i)) |e| if (e.kind == .dir) if (d.pathAt(&pbuf, i)) |p| {
                    paths.append(gpa, ch.a().dupe(u8, p) catch continue) catch {};
                };
            } else if (d.current()) |e| {
                if (e.kind == .dir) if (d.pathAt(&pbuf, d.cursor)) |p| paths.append(gpa, ch.a().dupe(u8, p) catch return) catch {};
            }
            // Nothing that is a folder: the folder shown.
            if (paths.items.len == 0) paths.append(gpa, d.path) catch return;
            if (ch.kind == .save_files) return ch.saveInto(paths.items[0]);
            ch.answerPaths(paths.items);
        } else {
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(gpa);
            if (several or (ch.multiple and sel.len == 1 and d.mark_count != 0)) {
                for (sel) |i| if (d.entryAt(i)) |e| if (e.kind != .dir) if (d.pathAt(&pbuf, i)) |p| {
                    paths.append(gpa, ch.a().dupe(u8, p) catch continue) catch {};
                };
                if (paths.items.len == 0) return w.notify("Only folders are marked: mark files to open them", true);
                return ch.answerPaths(paths.items);
            }
            const e = d.current() orelse return;
            const p = d.pathAt(&pbuf, d.cursor) orelse return;
            if (e.kind == .dir) return w.cdKnown(p, null, true);
            ch.answerPaths(&.{p});
        },
        .save => {
            const e = d.current() orelse return ch.saveAs(ch.nameText());
            const p = d.pathAt(&pbuf, d.cursor) orelse return;
            if (e.kind == .dir) return w.cdKnown(p, null, true);
            // A file: saving over it, by that name.
            const name = model.basename(p);
            if (w.begin()) |txn| {
                _ = c.siv_set_text(txn, ch.field, name.ptr, name.len);
                _ = ui.commit(txn);
            }
            ch.saveAs(name);
        },
    }
}

/// Enter on a typed path (Open and folder choosers): a folder is gone to
/// (or, choosing folders, picked), a file picked; nothing there stays in
/// insert mode with an error.
pub fn goPath(ch: *Chooser, typed: []const u8) void {
    const w = ch.win orelse return;
    if (typed.len == 0) return w.notify("Type a path", true);
    var xbuf: [linux.PATH_MAX]u8 = undefined;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = model.normalize(&pbuf, w.expandPath(&xbuf, typed));
    switch (pathKind(p)) {
        .missing => {
            var mb: [linux.PATH_MAX + 32]u8 = undefined;
            w.notify(std.fmt.bufPrint(&mb, "No such file or folder: {s}", .{typed}) catch "No such file or folder", true);
        },
        .dir => if (ch.kind == .save_files)
            ch.saveInto(p)
        else if (ch.picksFolders())
            ch.answerPaths(&.{p})
        else {
            // Normal mode, in that folder.
            _ = c.siv_node_focus(w.current.view);
            w.cd(p);
        },
        .file => if (ch.picksFolders()) w.notify("Choose a folder", true) else ch.answerPaths(&.{p}),
    }
}

/// Tab in the path field: the longest common start of the names that
/// fit, the candidates shown when there are several.
fn completePath(ch: *Chooser, w: *Window) void {
    var arena: std.heap.ArenaAllocator = .init(ch.app.gpa);
    defer arena.deinit();
    const text = ch.nameText();
    const r = commands.completePath(w, arena.allocator(), text, ch.picksFolders()) catch return;
    if (r.candidates.len == 0) return;
    if (!std.mem.eql(u8, r.completed, text)) if (w.begin()) |txn| {
        _ = c.siv_set_text(txn, ch.field, r.completed.ptr, r.completed.len);
        _ = c.siv_set_selection(txn, ch.field, @intCast(r.completed.len), @intCast(r.completed.len));
        _ = ui.commit(txn);
    };
    if (r.candidates.len > 1) w.showCandidates(r.candidates) else w.hideWhichKey();
}

/// Saves as `name` in the folder shown, asking before replacing a file.
pub fn saveAs(ch: *Chooser, name: []const u8) void {
    const w = ch.win orelse return;
    if (name.len == 0) return w.notify("Type a name to save as", true);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    var xbuf: [linux.PATH_MAX]u8 = undefined;
    const d = w.curDir();
    // A path, as Emacs takes one: "~/Documents/a.pdf" or "../a.pdf"
    // saves in that folder, which must exist.
    const p = if (std.mem.indexOfScalar(u8, name, '/') != null) blk: {
        if (name[name.len - 1] == '/') return w.notify("Type a name after the folder", true);
        const full = model.normalize(&pbuf, w.expandPath(&xbuf, name));
        if (pathKind(model.parent(full)) != .dir) return w.notify("No such folder", true);
        break :blk full;
    } else blk: {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return w.notify("Not a name for a file", true);
        break :blk std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ if (std.mem.eql(u8, d.path, "/")) "" else d.path, name }) catch return;
    };
    const base = model.basename(p);
    switch (pathKind(p)) {
        .missing => ch.answerPaths(&.{p}),
        // A folder by that name: go in, as other choosers do.
        .dir => w.cd(p),
        .file => {
            ch.setPending(&.{p});
            w.dialogs.confirmOverwrite(&.{base}, model.parent(p));
        },
    }
}

/// SaveFiles: the request's names in `folder`, asking before replacing.
fn saveInto(ch: *Chooser, folder: []const u8) void {
    const w = ch.win orelse return;
    const gpa = ch.app.gpa;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var existing: std.ArrayList([]const u8) = .empty;
    defer existing.deinit(gpa);
    for (ch.files) |n| {
        const p = std.fmt.allocPrint(ch.a(), "{s}/{s}", .{ if (std.mem.eql(u8, folder, "/")) "" else folder, n }) catch return;
        paths.append(gpa, p) catch return;
        if (pathKind(p) != .missing) existing.append(gpa, n) catch {};
    }
    // With no names, the folder itself.
    if (ch.files.len == 0) paths.append(gpa, folder) catch return;
    if (existing.items.len == 0) return ch.answerPaths(paths.items);
    ch.setPending(paths.items);
    w.dialogs.confirmOverwrite(existing.items, folder);
}

fn setPending(ch: *Chooser, paths: []const []const u8) void {
    ch.pending.clearRetainingCapacity();
    for (paths) |p| ch.pending.append(ch.app.gpa, ch.a().dupe(u8, p) catch continue) catch {};
}

/// The overwrite dialog said Replace.
pub fn overwriteConfirmed(ch: *Chooser) void {
    if (ch.pending.items.len == 0) return;
    ch.answerPaths(ch.pending.items);
}

const PathKind = enum { missing, file, dir };

fn pathKind(p: []const u8) PathKind {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{p}, 0) catch return .missing;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return .missing;
    return if (st.mode & linux.S.IFMT == linux.S.IFDIR) .dir else .file;
}

// Answering --------------------------------------------------------------------------------

/// Picked: response 0 with these paths as file URIs.
fn answerPaths(ch: *Chooser, paths: []const []const u8) void {
    if (ch.win) |w| ch.app.setChooserFolder(w.curDir().path);
    ch.reply(0, paths);
    ch.end();
}

/// Not picked: 1 when the user cancelled, 2 when the caller closed it or
/// it could not go on.
pub fn finish(ch: *Chooser, response: u32) void {
    ch.reply(response, &.{});
    ch.end();
}

/// The window went (closed by the user): cancelled, unless answered.
pub fn windowGone(ch: *Chooser) void {
    ch.win = null;
    if (!ch.answered) ch.reply(1, &.{});
    ch.end();
}

fn reply(ch: *Chooser, response: u32, paths: []const []const u8) void {
    if (ch.answered) return;
    ch.answered = true;
    var m: siv.DbusMessage = .null;
    if (c.siv_dbus_invocation_new_reply(ch.invocation, &m) != .ok) return;
    c.siv_dbus_message_write_int(m, 'u', response);
    c.siv_dbus_message_write_open(m, 'a', "{sv}", 4);
    if (response == 0) {
        entry(m, "uris", "as");
        c.siv_dbus_message_write_open(m, 'a', "s", 1);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(ch.app.gpa);
        for (paths) |p| {
            list.clearRetainingCapacity();
            uri.appendFileUri(&list, ch.app.gpa, p) catch continue;
            bus.writeString(m, list.items);
        }
        c.siv_dbus_message_write_close(m);
        endEntry(m);
        if (ch.choices.len != 0) {
            entry(m, "choices", "a(ss)");
            c.siv_dbus_message_write_open(m, 'a', "(ss)", 4);
            for (ch.choices) |x| {
                c.siv_dbus_message_write_open(m, 'r', "", 0);
                bus.writeString(m, x.id);
                bus.writeString(m, ch.choiceValue(x));
                c.siv_dbus_message_write_close(m);
            }
            c.siv_dbus_message_write_close(m);
            endEntry(m);
        }
        if (ch.filter) |i| if (!ch.picksFolders()) {
            const f = ch.filters[i];
            entry(m, "current_filter", "(sa(us))");
            c.siv_dbus_message_write_open(m, 'r', "", 0);
            bus.writeString(m, f.name);
            c.siv_dbus_message_write_open(m, 'a', "(us)", 4);
            for (f.rules) |rule| {
                c.siv_dbus_message_write_open(m, 'r', "", 0);
                c.siv_dbus_message_write_int(m, 'u', rule.kind);
                bus.writeString(m, rule.pattern);
                c.siv_dbus_message_write_close(m);
            }
            c.siv_dbus_message_write_close(m);
            c.siv_dbus_message_write_close(m);
            endEntry(m);
        };
        if (ch.kind == .open) {
            entry(m, "writable", "b");
            c.siv_dbus_message_write_int(m, 'b', 1);
            endEntry(m);
        }
    }
    c.siv_dbus_message_write_close(m);
    _ = c.siv_dbus_message_send(m);
}

fn choiceValue(ch: *const Chooser, x: Choice) []const u8 {
    _ = ch;
    var v: f64 = 0;
    const got = x.node != .null and c.siv_widget_get_value(x.node, &v) == .ok;
    if (x.options.len == 0) return if (got) (if (v >= 0.5) "true" else "false") else (if (std.mem.eql(u8, x.initial, "true")) "true" else "false");
    if (!got or v < 0) return x.initial;
    const i: usize = @intFromFloat(v);
    return if (i < x.options.len) x.options[i].id else x.initial;
}

fn entry(m: siv.DbusMessage, key: []const u8, sig: []const u8) void {
    c.siv_dbus_message_write_open(m, 'e', "", 0);
    bus.writeString(m, key);
    c.siv_dbus_message_write_open(m, 'v', sig.ptr, sig.len);
}

fn endEntry(m: siv.DbusMessage) void {
    c.siv_dbus_message_write_close(m);
    c.siv_dbus_message_write_close(m);
}

/// After answering: the window closes, the folders lose the filter, the
/// Request object goes.
fn end(ch: *Chooser) void {
    if (ch.close_timer != .null) _ = c.siv_timer_cancel(ch.close_timer);
    if (ch.request != .null) {
        const r = ch.request;
        ch.request = .null;
        c.siv_dbus_object_destroy(r);
    }
    var it = ch.app.cache.dirs.valueIterator();
    while (it.next()) |d| if (d.*.types) |t| if (ch.ownsTypes(t)) {
        d.*.types = null;
        d.*.refilter();
    };
    if (ch.win) |w| {
        ch.win = null;
        w.chooser = null;
        w.close();
    }
    ch.destroy();
}
