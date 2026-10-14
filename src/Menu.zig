//! Context menus: right-click an entry, the selection, or a column's
//! empty space (or press the Menu key, or Shift+F10, for the cursor's
//! row), and a siv menu lists what applies, each item a command from the
//! command table with the keys bound to it at the end, so the menu
//! teaches the keymap. Commands from init.lua come in a submenu of their
//! own. Choosing an item runs its command as a key would.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const Window = @import("Window.zig");
const commands = @import("commands.zig");
const keys = @import("keys.zig");
const model = @import("model.zig");

const Menu = @This();
const Node = siv.Node;

/// What was right-clicked.
pub const Context = enum {
    /// The targets: the cursor's entry, the marked ones, or the visual
    /// range.
    entries,
    /// The current folder (its empty space).
    folder,
};

win: *Window,
node: Node = .null,
/// The command of each item of the menu and of its submenus, by menu,
/// in item order (separators and submenu openers have none).
items: std.ArrayList(Item) = .empty,

const Item = struct { menu: Node, command: ?[]u8 };

pub fn init(win: *Window) Menu {
    return .{ .win = win };
}

pub fn deinit(m: *Menu) void {
    m.clearItems();
    m.items.deinit(m.win.gpa);
}

fn clearItems(m: *Menu) void {
    for (m.items.items) |it| if (it.command) |cmd| m.win.gpa.free(cmd);
    m.items.clearRetainingCapacity();
}

/// What a menu entry is: a command (with its label), a separator, a
/// check item, or a submenu of further entries.
const Entry = struct {
    label: []const u8 = "",
    command: []const u8 = "",
    disabled: bool = false,
    /// A check mark: 1 on, 0 off; null for an ordinary item.
    checked: ?bool = null,
    separator: bool = false,
    sub: []const Entry = &.{},
    icon: []const u8 = "",
};

const sep: Entry = .{ .separator = true };

/// Opens the menu for `ctx` at (x, y) in `anchor`.
pub fn open(m: *Menu, ctx: Context, anchor: Node, x: f32, y: f32) void {
    const win = m.win;
    const app = win.app;
    const d = win.curDir();
    var arena_state: std.heap.ArenaAllocator = .init(win.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var list: std.ArrayList(Entry) = .empty;
    const paste_ok = app.register.items.len != 0;
    switch (ctx) {
        .entries => {
            const paths = win.targets() catch return;
            defer @import("App.zig").freePaths(win.gpa, paths);
            if (paths.len == 0) return m.open(.folder, anchor, x, y);
            const one = paths.len == 1;
            const e = d.current();
            const dir = one and e != null and e.?.kind == .dir and win.mode != .visual and d.mark_count == 0;
            if (dir) {
                list.appendSlice(a, &.{
                    .{ .label = "Open", .command = "enter", .icon = "folder-open-symbolic" },
                    .{ .label = "Open in a new tab", .command = std.fmt.allocPrint(a, "tab-new {s}", .{paths[0]}) catch return },
                    .{ .label = "Open terminal here", .command = std.fmt.allocPrint(a, "terminal {s}", .{paths[0]}) catch return, .icon = "utilities-terminal-symbolic" },
                    .{ .label = "Open with…", .command = "open-with" },
                }) catch return;
            } else list.appendSlice(a, &.{
                .{ .label = "Open", .command = "open", .icon = "document-open-symbolic" },
                .{ .label = "Open with…", .command = "open-with" },
            }) catch return;
            list.appendSlice(a, &.{
                sep,
                .{ .label = "Copy", .command = "yank", .icon = "edit-copy-symbolic" },
                .{ .label = "Cut", .command = "cut", .icon = "edit-cut-symbolic" },
                .{ .label = "Paste here", .command = "paste", .disabled = !paste_ok, .icon = "edit-paste-symbolic" },
                .{ .label = if (one) "Copy the path" else "Copy the paths", .command = "yank-path" },
                sep,
                if (one) .{ .label = "Rename…", .command = "rename" } else .{ .label = "Rename in the editor…", .command = "bulk-rename" },
                .{ .label = "Properties…", .command = "properties", .icon = "document-properties-symbolic" },
                sep,
            }) catch return;
            if (d.isTrash()) {
                list.append(a, .{ .label = "Restore", .command = "restore" }) catch return;
            } else list.append(a, .{ .label = "Move to the trash", .command = "trash", .icon = "user-trash-symbolic" }) catch return;
            list.appendSlice(a, &.{
                .{ .label = "Delete permanently…", .command = "delete", .icon = "edit-delete-symbolic" },
                sep,
                .{ .label = "Run a shell command…", .command = "shell-prompt" },
            }) catch return;
        },
        .folder => {
            const sort = app.options.sort;
            const by = [_]struct { []const u8, model.SortKey, []const u8 }{
                .{ "Name", .name, "sort name" },
                .{ "Size", .size, "sort size" },
                .{ "Modified", .modified, "sort modified" },
                .{ "Type", .type, "sort type" },
                .{ "Extension", .extension, "sort extension" },
            };
            var sorts: std.ArrayList(Entry) = .empty;
            for (by) |b| sorts.append(a, .{ .label = b[0], .command = b[2], .checked = sort.key == b[1] }) catch return;
            sorts.appendSlice(a, &.{
                sep,
                .{ .label = "Reverse", .command = "sort-reverse", .checked = sort.descending },
                .{ .label = "Folders first", .command = "sort-dirs-first", .checked = sort.folders_first },
            }) catch return;
            list.appendSlice(a, &.{
                .{ .label = "New file or folder…", .command = "create", .icon = "document-new-symbolic" },
                .{ .label = "Paste here", .command = "paste", .disabled = !paste_ok, .icon = "edit-paste-symbolic" },
                .{ .label = "Select everything", .command = "mark-all", .icon = "edit-select-all-symbolic" },
                sep,
                .{ .label = "Open terminal here", .command = "terminal", .icon = "utilities-terminal-symbolic" },
                .{ .label = "Run a shell command…", .command = "shell-prompt" },
                sep,
                .{ .label = "Hidden files", .command = "toggle-hidden", .checked = app.options.show_hidden },
                .{ .label = "Sort by", .sub = sorts.items },
                sep,
                .{ .label = "Reload", .command = "reload", .icon = "view-refresh-symbolic" },
                .{ .label = "Tasks", .command = "tasks" },
            }) catch return;
        },
    }
    // init.lua's commands.
    if (app.lua) |l| if (l.user_commands.items.len != 0) {
        var more: std.ArrayList(Entry) = .empty;
        for (l.user_commands.items) |u| more.append(a, .{ .label = if (u.desc.len != 0) u.desc else u.name, .command = u.name }) catch return;
        list.appendSlice(a, &.{ sep, .{ .label = "From init.lua", .sub = more.items } }) catch return;
    };

    m.clearItems();
    const txn = win.begin() orelse return;
    if (m.node != .null) _ = c.siv_remove(txn, m.node);
    m.node = c.siv_menu(txn, win.root, &.{ .label = "Actions", .label_len = 7 });
    m.fill(txn, m.node, list.items) catch {};
    if (!@import("ui.zig").commit(txn)) return;
    _ = c.siv_menu_open_at(m.node, anchor, x, y);
}

fn fill(m: *Menu, txn: siv.Txn, menu: Node, entries: []const Entry) !void {
    const gpa = m.win.gpa;
    _ = c.siv_on(txn, menu, .select, onSelect, null, m);
    for (entries) |e| {
        if (e.separator) {
            _ = c.siv_menu_item(txn, menu, &.{ .flags = .{ .separator = true } });
            try m.items.append(gpa, .{ .menu = menu, .command = null });
            continue;
        }
        var sub: Node = .null;
        if (e.sub.len != 0) {
            sub = c.siv_menu(txn, m.node, &.{ .label = e.label.ptr, .label_len = e.label.len });
            try m.fill(txn, sub, e.sub);
        }
        var kb: [64]u8 = undefined;
        const shortcut = if (e.command.len != 0) m.keysFor(e.command, &kb) else "";
        _ = c.siv_menu_item(txn, menu, &.{
            .label = e.label.ptr,
            .label_len = e.label.len,
            .shortcut = shortcut.ptr,
            .shortcut_len = shortcut.len,
            .icon = e.icon.ptr,
            .icon_len = e.icon.len,
            .submenu = sub,
            .flags = .{ .disabled = e.disabled, .checkable = e.checked != null and !e.checked.?, .checked = e.checked orelse false },
        });
        try m.items.append(gpa, .{ .menu = menu, .command = if (sub == .null) try gpa.dupe(u8, e.command) else null });
    }
}

/// The keys bound to `command` in normal mode, as the keymap writes them
/// ("yy", "<C-a>"), or "" when none is.
fn keysFor(m: *Menu, command: []const u8, buf: []u8) []const u8 {
    for (m.win.app.keymap.bindings.items) |b| {
        if (b.mode != .normal) continue;
        switch (b.action) {
            .command => |cmd| if (std.mem.eql(u8, cmd, command)) return keys.format(buf, b.keys),
            .lua => {},
        }
    }
    return "";
}

fn onSelect(ud: ?*anyopaque, node: Node, ev: *const siv.Event) callconv(.c) siv.EventResult {
    const m: *Menu = @ptrCast(@alignCast(ud.?));
    var k: u32 = 0;
    for (m.items.items) |it| {
        if (it.menu != node) continue;
        if (k == ev.index) {
            const cmd = it.command orelse return .handled;
            // A copy: running it may rebuild the menu.
            var buf: [linux.PATH_MAX + 64]u8 = undefined;
            if (cmd.len > buf.len) return .handled;
            @memcpy(buf[0..cmd.len], cmd);
            commands.execute(m.win, buf[0..cmd.len], null, true);
            return .handled;
        }
        k += 1;
    }
    return .handled;
}
