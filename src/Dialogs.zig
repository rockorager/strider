//! Dialogs, where a dialog beats the status line: confirming what cannot
//! be undone (deleting permanently, emptying the trash), a conflict in an
//! operation of several items (both files compared, a choice for every
//! later conflict), and properties (the details, permissions as check
//! boxes and as a mode, the owner). Each is a siv dialog driven from the
//! keyboard: buttons and check boxes carry mnemonics, underlined, that
//! work as keys; Enter presses the focused button (Cancel when a dialog
//! opens; Apply in properties); Escape cancels. Quick one-key
//! questions (a single file's conflict, bookmarks) stay in the status
//! line.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Window = @import("Window.zig");
const fsops = @import("fsops.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const commands = @import("commands.zig");

const Dialogs = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const Kind = enum { delete, empty_trash, conflict, properties, overwrite };

win: *Window,
kind: Kind = .delete,
node: Node = .null,
/// Buttons by what they do.
buttons: [6]Node = @splat(.null),
actions: [6]Action = undefined,
nbuttons: usize = 0,
/// Delete: what goes. Properties: what changes.
paths: std.ArrayList([]u8) = .empty,
/// Conflict: the operation asking, and "every conflict".
entry: ?*App.OpEntry = null,
all: Node = .null,
/// Properties.
mode_field: Node = .null,
owner_field: Node = .null,
boxes: [9]Node = @splat(.null),
recursive: Node = .null,
mode0: [16]u8 = undefined,
mode0_len: usize = 0,
owner0: [128]u8 = undefined,
owner0_len: usize = 0,

const Action = enum { cancel, delete, empty_trash, replace, skip, keep_both, merge, apply, overwrite };

pub fn init(win: *Window) Dialogs {
    return .{ .win = win };
}

pub fn deinit(d: *Dialogs) void {
    d.freePaths();
    d.paths.deinit(d.win.gpa);
}

pub fn isOpen(d: *const Dialogs) bool {
    return d.node != .null;
}

fn freePaths(d: *Dialogs) void {
    for (d.paths.items) |p| d.win.gpa.free(p);
    d.paths.clearRetainingCapacity();
}

/// Starts a dialog: a card over the window with `title` and `text`.
fn begin(d: *Dialogs, kind: Kind, title: []const u8, text: []const u8) ?Txn {
    if (d.isOpen()) d.dismiss();
    d.kind = kind;
    d.nbuttons = 0;
    d.all = .null;
    d.mode_field = .null;
    d.owner_field = .null;
    d.recursive = .null;
    const txn = d.win.begin() orelse return null;
    d.node = c.siv_dialog(txn, d.win.root, &.{ .title = title.ptr, .title_len = title.len, .text = text.ptr, .text_len = text.len });
    _ = c.siv_on(txn, d.node, .close, onClose, null, d);
    _ = c.siv_on(txn, d.node, .key, onKey, null, d);
    return txn;
}

fn button(d: *Dialogs, txn: Txn, label: []const u8, mnemonic: u8, style: siv.ButtonStyle, action: Action) void {
    const actions = c.siv_widget_get_part(d.node, .actions, 0);
    const b = c.siv_push_button(txn, actions, &.{ .label = label.ptr, .label_len = label.len, .style = style, .mnemonic = mnemonic });
    _ = c.siv_on(txn, b, .activate, onButton, null, d);
    d.buttons[d.nbuttons] = b;
    d.actions[d.nbuttons] = action;
    d.nbuttons += 1;
}

/// Shows a dialog of buttons with its first, Cancel, focused, as GTK
/// does: Enter then cancels (siv focuses the card, where Enter did
/// nothing at all), Tab reaches the others, and each one's key presses it.
fn present(d: *Dialogs, txn: Txn) void {
    if (!ui.commit(txn)) return;
    if (d.nbuttons != 0) _ = c.siv_node_focus(d.buttons[0]);
}

fn content(d: *Dialogs) Node {
    return c.siv_widget_get_part(d.node, .content, 0);
}

fn line(txn: Txn, parent: Node, text: []const u8, token: siv.ColorToken) Node {
    const t = c.siv_text(txn, parent, text.ptr, text.len);
    _ = c.siv_set_text_style(txn, t, &.{ .color_token = token, .size_role = .body, .tab_width = 110, .flags = .{ .break_words = true } });
    return t;
}

/// Closes the dialog without acting.
fn dismiss(d: *Dialogs) void {
    const node = d.node;
    d.node = .null;
    d.freePaths();
    if (node == .null) return;
    if (d.win.begin()) |txn| {
        _ = c.siv_remove(txn, node);
        _ = ui.commit(txn);
    }
    _ = c.siv_node_focus(d.win.current.view);
}

// Deleting -----------------------------------------------------------------------------------

/// Asks before deleting `paths` permanently.
pub fn confirmDelete(d: *Dialogs, paths: []const []const u8) void {
    var tb: [512]u8 = undefined;
    const title = if (paths.len == 1)
        std.fmt.bufPrint(&tb, "Delete “{s}” permanently?", .{model.basename(paths[0])}) catch "Delete permanently?"
    else
        std.fmt.bufPrint(&tb, "Delete {d} items permanently?", .{paths.len}) catch "Delete permanently?";
    const txn = d.begin(.delete, title, "They will not go to the trash, and this cannot be undone; folders go with everything in them.") orelse return;
    for (paths) |p| d.paths.append(d.win.gpa, d.win.gpa.dupe(u8, p) catch continue) catch {};
    if (paths.len > 1) {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(d.win.gpa);
        for (paths[0..@min(paths.len, 6)]) |p| list.print(d.win.gpa, "{s}\n", .{model.basename(p)}) catch {};
        if (paths.len > 6) list.print(d.win.gpa, "and {d} more", .{paths.len - 6}) catch {};
        _ = line(txn, d.content(), std.mem.trimEnd(u8, list.items, "\n"), .card_fg);
    }
    d.button(txn, "Cancel", 'c', .default, .cancel);
    d.button(txn, "Delete", 'd', .destructive, .delete);
    d.present(txn);
}

pub fn confirmEmptyTrash(d: *Dialogs) void {
    const txn = d.begin(.empty_trash, "Empty the trash?", "Everything in it is deleted permanently; this cannot be undone.") orelse return;
    d.button(txn, "Cancel", 'c', .default, .cancel);
    d.button(txn, "Empty the trash", 'e', .destructive, .empty_trash);
    d.present(txn);
}

// Saving over files ---------------------------------------------------------------------------

/// The file chooser saving over files that exist (`names`, in `folder`).
pub fn confirmOverwrite(d: *Dialogs, names: []const []const u8, folder: []const u8) void {
    var tb: [512]u8 = undefined;
    var xb: [512]u8 = undefined;
    var pb: [linux.PATH_MAX]u8 = undefined;
    const title = if (names.len == 1)
        std.fmt.bufPrint(&tb, "Replace “{s}”?", .{names[0]}) catch "Replace it?"
    else
        std.fmt.bufPrint(&tb, "Replace {d} files?", .{names.len}) catch "Replace them?";
    const text = std.fmt.bufPrint(&xb, "{s} exist{s} in {s}; saving replaces what {s} hold{s}.", .{ if (names.len == 1) "It" else "They", if (names.len == 1) "s" else "", d.win.shortPathIn(&pb, folder), if (names.len == 1) "it" else "they", if (names.len == 1) "s" else "" }) catch "";
    const txn = d.begin(.overwrite, title, text) orelse return;
    if (names.len > 1) {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(d.win.gpa);
        for (names[0..@min(names.len, 6)]) |n| list.print(d.win.gpa, "{s}\n", .{n}) catch {};
        if (names.len > 6) list.print(d.win.gpa, "and {d} more", .{names.len - 6}) catch {};
        _ = line(txn, d.content(), std.mem.trimEnd(u8, list.items, "\n"), .card_fg);
    }
    d.button(txn, "Cancel", 'c', .default, .cancel);
    d.button(txn, "Replace", 'r', .destructive, .overwrite);
    d.present(txn);
}

// Conflicts ----------------------------------------------------------------------------------

/// A conflict in an operation of several items: both files side by side,
/// and whether the answer goes for every later conflict.
pub fn askConflict(d: *Dialogs, e: *App.OpEntry) void {
    const cf = &e.op.conflict;
    var tb: [512]u8 = undefined;
    var xb: [512]u8 = undefined;
    var pb: [linux.PATH_MAX]u8 = undefined;
    const title = std.fmt.bufPrint(&tb, "“{s}” already exists", .{model.basename(cf.dstPath())}) catch "It already exists";
    const text = std.fmt.bufPrint(&xb, "{s} {d} items into {s}", .{ fsops.doing(e.op.kind), e.op.sources.len, d.win.shortPathIn(&pb, model.parent(cf.dstPath())) }) catch "";
    const txn = d.begin(.conflict, title, text) orelse return e.answer(.cancel, false);
    d.entry = e;
    const tz = if (d.win.app.opts.reproducible) 0 else d.win.app.tz_offset_s;
    var sb: [32]u8 = undefined;
    var mb: [32]u8 = undefined;
    var lb: [256]u8 = undefined;
    _ = line(txn, d.content(), std.fmt.bufPrint(&lb, "There now\t{s}, modified {s}", .{ if (cf.dst_dir) "a folder" else model.formatSize(&sb, cf.dst_size), model.formatTime(&mb, cf.dst_mtime, tz) }) catch "", .card_fg);
    _ = line(txn, d.content(), std.fmt.bufPrint(&lb, "Coming in\t{s}, modified {s}", .{ if (cf.src_dir) "a folder" else model.formatSize(&sb, cf.src_size), model.formatTime(&mb, cf.src_mtime, tz) }) catch "", .card_fg);
    d.all = c.siv_check_box(txn, d.content(), &.{ .label = "Do the same for every conflict", .label_len = 30, .mnemonic = 'a' });
    d.button(txn, "Cancel", 'c', .default, .cancel);
    d.button(txn, "Skip", 's', .default, .skip);
    d.button(txn, "Keep both", 'k', .default, .keep_both);
    if (cf.src_dir and cf.dst_dir) d.button(txn, "Merge", 'm', .default, .merge);
    d.button(txn, "Replace", 'r', .primary, .replace);
    d.present(txn);
}

// Properties ---------------------------------------------------------------------------------

/// What a properties dialog shows, read on a worker (stat can wait on
/// the file system).
const Facts = struct {
    win: *Window,
    gpa: std.mem.Allocator,
    paths: [][]u8,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    mtime: i64 = 0,
    dir: bool = false,
    ok: bool = false,
    same_mode: bool = true,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const f: *Facts = @ptrCast(@alignCast(ud.?));
        for (f.paths, 0..) |p, i| {
            var zb: [linux.PATH_MAX]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{p}, 0) catch continue;
            var st: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .SIZE = true, .MTIME = true }, &st)) != .SUCCESS) continue;
            if (i == 0) {
                f.ok = true;
                f.mode = st.mode & 0o7777;
                f.uid = st.uid;
                f.gid = st.gid;
                f.mtime = st.mtime.sec * std.time.ns_per_s + st.mtime.nsec;
            } else if (st.mode & 0o7777 != f.mode) f.same_mode = false;
            if (st.mode & linux.S.IFMT == linux.S.IFDIR) f.dir = true else f.size += st.size;
        }
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const f: *Facts = @ptrCast(@alignCast(ud.?));
        for (f.win.app.windows.items) |w| if (w == f.win) {
            if (f.ok) w.dialogs.showProperties(f) else w.notify("Its properties could not be read", true);
            return;
        };
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const f: *Facts = @ptrCast(@alignCast(ud.?));
        App.freePaths(f.gpa, f.paths);
        f.gpa.destroy(f);
    }
};

/// Properties of `paths` (owned from here): read on a worker, then shown.
pub fn properties(d: *Dialogs, paths: [][]u8) void {
    const gpa = d.win.gpa;
    const f = gpa.create(Facts) catch return App.freePaths(gpa, paths);
    f.* = .{ .win = d.win, .gpa = gpa, .paths = paths };
    // The destroy-notify runs if the job cannot start.
    _ = c.siv_job_start(d.win.app.app, .{}, Facts.work, Facts.done, Facts.destroy, f);
}

const who = [3][]const u8{ "Owner", "Group", "Others" };
const what = [3][]const u8{ "Read", "Write", "Run" };

fn showProperties(d: *Dialogs, f: *const Facts) void {
    const gpa = d.win.gpa;
    var tb: [512]u8 = undefined;
    const one = f.paths.len == 1;
    const title = if (one) model.basename(f.paths[0]) else std.fmt.bufPrint(&tb, "{d} items", .{f.paths.len}) catch "Properties";
    var title_copy: [512]u8 = undefined;
    @memcpy(title_copy[0..title.len], title);
    const txn = d.begin(.properties, title_copy[0..title.len], "") orelse return;
    for (f.paths) |p| d.paths.append(gpa, gpa.dupe(u8, p) catch continue) catch {};
    const tz = if (d.win.app.opts.reproducible) 0 else d.win.app.tz_offset_s;
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(gpa);
    var sb: [32]u8 = undefined;
    var mb: [32]u8 = undefined;
    var pb: [linux.PATH_MAX]u8 = undefined;
    info.print(gpa, "Location\t{s}\n", .{d.win.shortPathIn(&pb, model.parent(f.paths[0]))}) catch {};
    if (!f.dir or !one) info.print(gpa, "Size\t{s}{s}\n", .{ model.formatSize(&sb, f.size), if (f.dir) " in files, not counting folders" else "" }) catch {};
    if (one) info.print(gpa, "Modified\t{s}\n", .{model.formatTime(&mb, f.mtime, tz)}) catch {};
    _ = line(txn, d.content(), std.mem.trimEnd(u8, info.items, "\n"), .card_fg);

    // The mode, typed as chmod takes it (octal or symbolic), and the same
    // as nine check boxes.
    const mode_text = if (f.same_mode) std.fmt.bufPrint(&d.mode0, "{o:0>4}", .{f.mode}) catch "" else "";
    d.mode0_len = mode_text.len;
    const mrow = c.siv_flex(txn, d.content(), &.{ .axis = .row, .gap = 10, .align_items = .center });
    _ = line(txn, mrow, "Permissions", .card_fg);
    d.mode_field = c.siv_editor(txn, mrow, .{});
    _ = c.siv_set_text(txn, d.mode_field, mode_text.ptr, mode_text.len);
    _ = c.siv_set_layout(txn, d.mode_field, &.{ .width = ui.px(120), .padding = .{ .start = 6, .end = 6, .top = 3, .bottom = 3 } });
    _ = c.siv_set_visual(txn, d.mode_field, &.{ .background_token = .view_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 } });
    _ = c.siv_set_text_style(txn, d.mode_field, &.{ .color_token = .view_fg, .size_role = .body, .family = "monospace", .family_len = 9 });
    _ = c.siv_set_semantics(txn, d.mode_field, &.{ .role = .text_input, .label = "Mode, as chmod takes it", .label_len = 23, .flags = .{ .focusable = true } });
    _ = c.siv_on(txn, d.mode_field, .change, onModeChange, null, d);
    const hint = line(txn, mrow, if (f.same_mode) "755, u+x, go-w…" else "mixed: type a mode for all", .muted_fg);
    _ = hint;
    for (who, 0..) |w_, r| {
        const row = c.siv_flex(txn, d.content(), &.{ .axis = .row, .gap = 14, .align_items = .center });
        const l = line(txn, row, w_, .card_fg);
        _ = c.siv_set_layout(txn, l, &.{ .width = ui.px(80) });
        for (what, 0..) |x, k| {
            const bit: u32 = @as(u32, 0o400) >> @intCast(r * 3 + k);
            var nb: [32]u8 = undefined;
            _ = std.fmt.bufPrint(&nb, "{s} {s}", .{ w_, x }) catch "";
            const box = c.siv_check_box(txn, row, &.{ .label = x.ptr, .label_len = x.len, .checked = if (f.same_mode and f.mode & bit != 0) .on else .off });
            _ = c.siv_on(txn, box, .change, onBoxChange, null, d);
            d.boxes[r * 3 + k] = box;
        }
    }
    // The owner, as chown takes it.
    var ob: [128]u8 = undefined;
    const owner = ownerText(&ob, f.uid, f.gid);
    @memcpy(d.owner0[0..owner.len], owner);
    d.owner0_len = owner.len;
    const orow = c.siv_flex(txn, d.content(), &.{ .axis = .row, .gap = 10, .align_items = .center });
    const ol = line(txn, orow, "Owned by", .card_fg);
    _ = c.siv_set_layout(txn, ol, &.{ .width = ui.px(80) });
    d.owner_field = c.siv_editor(txn, orow, .{});
    _ = c.siv_set_text(txn, d.owner_field, owner.ptr, owner.len);
    _ = c.siv_set_layout(txn, d.owner_field, &.{ .width = ui.px(200), .padding = .{ .start = 6, .end = 6, .top = 3, .bottom = 3 } });
    _ = c.siv_set_visual(txn, d.owner_field, &.{ .background_token = .view_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 } });
    _ = c.siv_set_text_style(txn, d.owner_field, &.{ .color_token = .view_fg, .size_role = .body });
    _ = c.siv_set_semantics(txn, d.owner_field, &.{ .role = .text_input, .label = "Owner, user:group", .label_len = 17, .flags = .{ .focusable = true } });
    if (f.dir) d.recursive = c.siv_check_box(txn, d.content(), &.{ .label = "Apply to enclosed files", .label_len = 23, .mnemonic = 'e' });
    d.button(txn, "Cancel", 'c', .default, .cancel);
    d.button(txn, "Apply", 'a', .primary, .apply);
    // Typing goes to the mode, all of it selected.
    _ = c.siv_set_selection(txn, d.mode_field, @intCast(mode_text.len), 0);
    _ = ui.commit(txn);
    _ = c.siv_node_focus(d.mode_field);
}

fn ownerText(buf: []u8, uid: u32, gid: u32) []const u8 {
    var ub: [64]u8 = undefined;
    var gb: [64]u8 = undefined;
    const u = if (std.c.getpwuid(uid)) |pw| (if (pw.name) |n| std.mem.span(n) else std.fmt.bufPrint(&ub, "{d}", .{uid}) catch "") else std.fmt.bufPrint(&ub, "{d}", .{uid}) catch "";
    const g = if (getgrgid(gid)) |gr| (if (gr.name) |n| std.mem.span(n) else std.fmt.bufPrint(&gb, "{d}", .{gid}) catch "") else std.fmt.bufPrint(&gb, "{d}", .{gid}) catch "";
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ u, g }) catch "";
}

const Group = extern struct { name: ?[*:0]u8, passwd: ?[*:0]u8, gid: u32, members: ?[*:null]?[*:0]u8 };
extern "c" fn getgrgid(gid: u32) ?*Group;

/// The mode typed: the check boxes follow when it is one.
fn onModeChange(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const d: *Dialogs = @ptrCast(@alignCast(ud.?));
    var buf: [64]u8 = undefined;
    const t = ui.getText(d.mode_field, &buf);
    const base = std.fmt.parseInt(u32, d.mode0[0..d.mode0_len], 8) catch 0o644;
    const mode = fsops.applyMode(t, base, false, 0o022) orelse return .handled;
    const txn = d.win.begin() orelse return .handled;
    for (d.boxes, 0..) |b, i| c.siv_widget_set_value(txn, b, if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) 1 else 0);
    _ = ui.commit(txn);
    return .handled;
}

/// A check box flipped: the mode follows, in octal.
fn onBoxChange(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const d: *Dialogs = @ptrCast(@alignCast(ud.?));
    var mode: u32 = (std.fmt.parseInt(u32, d.mode0[0..d.mode0_len], 8) catch 0) & 0o7000;
    for (d.boxes, 0..) |b, i| {
        var v: f64 = 0;
        _ = c.siv_widget_get_value(b, &v);
        if (v >= 0.5) mode |= @as(u32, 0o400) >> @intCast(i);
    }
    var mb: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&mb, "{o:0>4}", .{mode}) catch return .handled;
    const txn = d.win.begin() orelse return .handled;
    _ = c.siv_set_text(txn, d.mode_field, text.ptr, text.len);
    _ = ui.commit(txn);
    return .handled;
}

fn checked(node: Node) bool {
    if (node == .null) return false;
    var v: f64 = 0;
    _ = c.siv_widget_get_value(node, &v);
    return v >= 0.5;
}

/// Apply: chmod and chown as operations, for what changed.
fn applyProperties(d: *Dialogs) void {
    const win = d.win;
    var mb: [64]u8 = undefined;
    var ob: [128]u8 = undefined;
    const mode = std.mem.trim(u8, ui.getText(d.mode_field, &mb), " ");
    const owner = std.mem.trim(u8, ui.getText(d.owner_field, &ob), " ");
    const recursive = checked(d.recursive);
    if (mode.len != 0 and !fsops.parseMode(mode)) {
        var buf: [128]u8 = undefined;
        return win.notify(std.fmt.bufPrint(&buf, "Not a mode: {s} (755, u+x, go-w, a=rX)", .{mode}) catch "Not a mode", true);
    }
    const ids: ?commands.Owner = if (!std.mem.eql(u8, owner, d.owner0[0..d.owner0_len]) or recursive) commands.parseOwner(win, owner) orelse return else null;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(win.gpa);
    for (d.paths.items) |p| paths.append(win.gpa, p) catch return;
    const mode_changed = mode.len != 0 and (!std.mem.eql(u8, mode, d.mode0[0..d.mode0_len]) or recursive);
    if (mode_changed) win.app.startAttrOp(win, .chmod, paths.items, mode, null, null, recursive);
    if (ids) |o| if (o.uid != null or o.gid != null) win.app.startAttrOp(win, .chown, paths.items, "", o.uid, o.gid, recursive);
    d.dismiss();
}

// Events -------------------------------------------------------------------------------------

fn act(d: *Dialogs, action: Action) void {
    switch (action) {
        .cancel => d.cancel(),
        .delete => {
            const win = d.win;
            var paths: std.ArrayList([]const u8) = .empty;
            defer paths.deinit(win.gpa);
            for (d.paths.items) |p| paths.append(win.gpa, p) catch return;
            win.app.startOp(win, .delete, paths.items, "", &.{}, false);
            win.consumeTargets();
            d.dismiss();
        },
        .empty_trash => {
            d.dismiss();
            d.win.app.emptyTrash(d.win);
        },
        .replace, .skip, .keep_both, .merge => {
            const e = d.entry orelse return d.dismiss();
            const all = checked(d.all);
            d.entry = null;
            d.dismiss();
            d.win.conflict = null;
            e.answer(switch (action) {
                .replace => .replace,
                .skip => .skip,
                .keep_both => .keep_both,
                else => .merge,
            }, all);
        },
        .apply => d.applyProperties(),
        .overwrite => {
            d.dismiss();
            if (d.win.chooser) |ch| ch.overwriteConfirmed();
        },
    }
}

/// Escape, the scrim, or Cancel: nothing happens (a conflict cancels the
/// operation, as in the status line).
fn cancel(d: *Dialogs) void {
    const kind = d.kind;
    const e = d.entry;
    d.entry = null;
    d.dismiss();
    switch (kind) {
        .delete => d.win.notify("Not deleted", false),
        .conflict => if (e) |x| {
            d.win.conflict = null;
            x.answer(.cancel, false);
        },
        // Back to the name, to type another.
        .overwrite => if (d.win.chooser) |ch| {
            _ = ch.focusName();
        },
        else => {},
    }
}

fn onButton(ud: ?*anyopaque, node: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const d: *Dialogs = @ptrCast(@alignCast(ud.?));
    for (d.buttons[0..d.nbuttons], d.actions[0..d.nbuttons]) |b, a| if (b == node) {
        d.act(a);
        return .handled;
    };
    return .pass;
}

fn onClose(ud: ?*anyopaque, _: Node, _: *const siv.Event) callconv(.c) siv.EventResult {
    const d: *Dialogs = @ptrCast(@alignCast(ud.?));
    d.cancel();
    return .handled;
}

/// Enter takes the default: Apply in properties (from its text fields
/// too). Elsewhere it presses the focused button, Cancel at first
/// (present), so nothing is destroyed by Enter alone.
fn onKey(ud: ?*anyopaque, _: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const d: *Dialogs = @ptrCast(@alignCast(ud.?));
    if (!ev.flags.pressed) return .pass;
    if ((ev.keysym == .@"return" or ev.keysym == .kp_enter) and d.kind == .properties) {
        const focus = c.siv_window_get_focus(d.win.window);
        for (d.buttons[0..d.nbuttons]) |b| if (b == focus) return .pass;
        d.applyProperties();
        return .handled;
    }
    return .pass;
}
