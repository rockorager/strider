//! Every action is a named command: keys are bound to command lines, the
//! : prompt runs them, and Lua calls them with fm.exec. A command gets
//! its arguments as text and the count typed before its keys.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");
const Dir = @import("Dir.zig");
const keys = @import("keys.zig");
const highlight = @import("highlight.zig");
const model = @import("model.zig");
const fsops = @import("fsops.zig");
const proc = @import("proc.zig");
const apps = @import("apps.zig");

pub const Ctx = struct {
    win: *Window,
    args: []const u8,
    count: ?u32,
    /// Run from a key binding rather than typed.
    from_key: bool,

    fn n(ctx: Ctx) u32 {
        return ctx.count orelse 1;
    }
};

pub const Complete = enum { none, path, dir, command, option, sort };

pub const Command = struct {
    name: []const u8,
    desc: []const u8,
    run: *const fn (Ctx) void,
    complete: Complete = .none,
};

pub const list = [_]Command{
    .{ .name = "down", .desc = "Move down [count]", .run = down },
    .{ .name = "up", .desc = "Move up [count]", .run = up },
    .{ .name = "top", .desc = "First entry, or entry [count]", .run = top },
    .{ .name = "bottom", .desc = "Last entry, or entry [count]", .run = bottom },
    .{ .name = "half-down", .desc = "Half a page down", .run = halfDown },
    .{ .name = "half-up", .desc = "Half a page up", .run = halfUp },
    .{ .name = "page-down", .desc = "A page down", .run = pageDown },
    .{ .name = "page-up", .desc = "A page up", .run = pageUp },
    .{ .name = "leave", .desc = "The parent folder", .run = leave },
    .{ .name = "enter", .desc = "Enter the folder, or open the file", .run = enter },
    .{ .name = "open", .desc = "Open the targets", .run = open },
    .{ .name = "back", .desc = "Back in history", .run = back },
    .{ .name = "forward", .desc = "Forward in history", .run = forward },
    .{ .name = "cd", .desc = "Go to a folder (or a file's folder)", .run = cd, .complete = .dir },
    .{ .name = "fuzzy", .desc = "Find a file or folder below this one", .run = fuzzyFind },
    .{ .name = "z", .desc = "Jump to zoxide's best folder for the words, or pick one", .run = zJump },
    .{ .name = "zi", .desc = "Pick a folder zoxide knows", .run = zPick },
    .{ .name = "cd-xdg", .desc = "Go to an XDG user folder: DOWNLOAD, DOCUMENTS, …", .run = cdXdg },
    .{ .name = "cd-media", .desc = "Go to where drives mount", .run = cdMedia },
    .{ .name = "trash-browse", .desc = "Show the trash", .run = trashBrowse },
    .{ .name = "preview-down", .desc = "Scroll the preview down", .run = previewDown },
    .{ .name = "preview-up", .desc = "Scroll the preview up", .run = previewUp },
    .{ .name = "search", .desc = "Search forward (or for the argument)", .run = search },
    .{ .name = "search-back", .desc = "Search backward", .run = searchBack },
    .{ .name = "search-next", .desc = "Next match", .run = searchNext },
    .{ .name = "search-prev", .desc = "Previous match", .run = searchPrev },
    .{ .name = "find", .desc = "Jump by typing part of a name", .run = find },
    .{ .name = "filter", .desc = "Show only names containing the text", .run = filter },
    .{ .name = "toggle-mark", .desc = "Mark or unmark, and move down", .run = toggleMark },
    .{ .name = "mark-all", .desc = "Mark every entry", .run = markAll },
    .{ .name = "unmark-all", .desc = "Unmark every entry", .run = unmarkAll },
    .{ .name = "invert-marks", .desc = "Invert the marks", .run = invertMarks },
    .{ .name = "visual", .desc = "Visual selection", .run = visual },
    .{ .name = "visual-end", .desc = "End the visual selection, marking it", .run = visualEnd },
    .{ .name = "escape", .desc = "Cancel: the filter, the visual range, the marks", .run = escape },
    .{ .name = "yank", .desc = "Copy the targets", .run = yank },
    .{ .name = "cut", .desc = "Cut the targets", .run = cut },
    .{ .name = "paste", .desc = "Paste here", .run = paste },
    .{ .name = "paste-overwrite", .desc = "Paste here, replacing", .run = pasteOverwrite },
    .{ .name = "yank-path", .desc = "Copy the targets' paths", .run = yankPath },
    .{ .name = "yank-name", .desc = "Copy the targets' names", .run = yankName },
    .{ .name = "yank-dir", .desc = "Copy the folder's path", .run = yankDir },
    .{ .name = "trash", .desc = "Move the targets to the trash", .run = trashCmd },
    .{ .name = "delete", .desc = "Delete the targets permanently", .run = delete },
    .{ .name = "restore", .desc = "Restore the targets from the trash", .run = restore },
    .{ .name = "empty-trash", .desc = "Empty the trash", .run = emptyTrash },
    .{ .name = "undo", .desc = "Undo the last operation", .run = undo },
    .{ .name = "rename", .desc = "Rename (to the argument)", .run = rename },
    .{ .name = "rename-append", .desc = "Rename, the caret at the end", .run = renameAppend },
    .{ .name = "rename-insert", .desc = "Rename, the caret at the start", .run = renameInsert },
    .{ .name = "bulk-rename", .desc = "Rename the targets in $EDITOR", .run = bulkRename },
    .{ .name = "create", .desc = "New file, or folder with a trailing /", .run = create },
    .{ .name = "mkdir", .desc = "New folder", .run = mkdir },
    .{ .name = "touch", .desc = "New file", .run = touch },
    .{ .name = "open-with", .desc = "Open with an application", .run = openWith },
    .{ .name = "chmod", .desc = "Permissions: chmod [-R] 755, u+x, go-w, a=rX…", .run = chmod },
    .{ .name = "chown", .desc = "Owner: chown [-R] user, user:group, :group", .run = chown },
    .{ .name = "shell", .desc = "Run a shell command (-t in a terminal)", .run = shell, .complete = .path },
    .{ .name = "shell-prompt", .desc = "Type a shell command", .run = shellPrompt },
    .{ .name = "insert", .desc = "Chooser: type the name or path (stem, start, end, or clear)", .run = insert },
    .{ .name = "terminal", .desc = "A terminal in this folder", .run = terminal, .complete = .dir },
    .{ .name = "reload", .desc = "Read the folders again", .run = reload },
    .{ .name = "toggle-hidden", .desc = "Show or hide hidden files", .run = toggleHidden },
    .{ .name = "toggle-preview", .desc = "Show or hide the preview", .run = togglePreview },
    .{ .name = "toggle-icons", .desc = "Show or hide icons", .run = toggleIcons },
    .{ .name = "sort", .desc = "Sort by name, size, modified, type, extension [reverse]", .run = sort, .complete = .sort },
    .{ .name = "sort-reverse", .desc = "Reverse the sort", .run = sortReverse },
    .{ .name = "sort-dirs-first", .desc = "Folders first, or not", .run = sortDirsFirst },
    .{ .name = "set", .desc = "Set an option: set name value", .run = set, .complete = .option },
    .{ .name = "bookmark-set", .desc = "Bookmark this folder under a key", .run = bookmarkSet },
    .{ .name = "bookmark-jump", .desc = "Go to a bookmark", .run = bookmarkJump },
    .{ .name = "bookmark-remove", .desc = "Remove a bookmark", .run = bookmarkRemove },
    .{ .name = "tab-new", .desc = "New tab (here, or at the argument)", .run = tabNew, .complete = .dir },
    .{ .name = "tab-close", .desc = "Close the tab", .run = tabClose },
    .{ .name = "tab-next", .desc = "Next tab", .run = tabNext },
    .{ .name = "tab-prev", .desc = "Previous tab", .run = tabPrev },
    .{ .name = "tab", .desc = "Go to tab N", .run = tabGo },
    .{ .name = "drives", .desc = "Drives: mount, open, unmount", .run = drives },
    .{ .name = "mount", .desc = "Mount a drive by name", .run = mount },
    .{ .name = "unmount", .desc = "Unmount the drive this folder is on", .run = unmount },
    .{ .name = "eject", .desc = "Unmount and eject the drive this folder is on", .run = eject },
    .{ .name = "map", .desc = "Bind keys: map [mode] keys command…", .run = map },
    .{ .name = "unmap", .desc = "Unbind keys: unmap [mode] keys", .run = unmap },
    .{ .name = "lua", .desc = "Run Lua", .run = luaCmd },
    .{ .name = "help", .desc = "Every key and command", .run = help },
    .{ .name = "messages", .desc = "Recent messages, newest first", .run = messages },
    .{ .name = "tasks", .desc = "Open or close the tasks view", .run = tasks },
    .{ .name = "menu", .desc = "The context menu at the cursor", .run = contextMenu },
    .{ .name = "properties", .desc = "The targets' details, permissions, and owner", .run = properties },
    .{ .name = "column-wider", .desc = "Widen the current column (or: column-wider parent)", .run = columnWider },
    .{ .name = "column-narrower", .desc = "Narrow the current column (or: column-narrower parent)", .run = columnNarrower },
    .{ .name = "column-reset", .desc = "Column widths from the ratio again", .run = columnReset },
    .{ .name = "task-down", .desc = "The next task", .run = taskDown },
    .{ .name = "task-up", .desc = "The previous task", .run = taskUp },
    .{ .name = "task-pause", .desc = "Pause or resume the task", .run = taskPause },
    .{ .name = "task-cancel", .desc = "Cancel the task, or remove it when done", .run = taskCancel },
    .{ .name = "command", .desc = "Open the command line", .run = commandLine },
    .{ .name = "new-window", .desc = "A new window here", .run = newWindow },
    .{ .name = "quit", .desc = "Close the tab, or the window", .run = quit },
    .{ .name = "quit-all", .desc = "Quit", .run = quitAll },
    .{ .name = "q", .desc = "Close the tab, or the window", .run = quit },
    .{ .name = "qa", .desc = "Quit", .run = quitAll },
};

pub fn find_(name: []const u8) ?*const Command {
    for (&list) |*cmd| if (std.mem.eql(u8, cmd.name, name)) return cmd;
    return null;
}

/// Runs a command line: "name args…". Lua commands (fm.command) come
/// first, so a configuration can replace a built-in one.
pub fn execute(win: *Window, line_in: []const u8, count: ?u32, from_key: bool) void {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0) return;
    // A leading count typed at the prompt: ":5down".
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    var cnt = count;
    var rest = line;
    if (i > 0 and i < line.len and line[i] != ' ') {
        cnt = std.fmt.parseInt(u32, line[0..i], 10) catch count;
        rest = line[i..];
    }
    // ":!cmd" is a shell command.
    if (rest[0] == '!') return runShell(win, std.mem.trim(u8, rest[1..], " "), false);
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const name = rest[0..sp];
    const args = std.mem.trim(u8, rest[sp..], " \t");
    if (win.app.lua) |l| if (l.runCommand(win, name, args, cnt)) return;
    // A bare number goes to that entry, as in vim.
    if (i == line.len) return win.moveCursor(@as(i64, std.fmt.parseInt(u32, line, 10) catch 1) - 1);
    const cmd = find_(name) orelse {
        var buf: [256]u8 = undefined;
        win.notify(std.fmt.bufPrint(&buf, "Unknown command: {s}", .{name}) catch "Unknown command", true);
        return;
    };
    cmd.run(.{ .win = win, .args = args, .count = cnt, .from_key = from_key });
}

// Moving -----------------------------------------------------------------------------------

fn down(ctx: Ctx) void {
    const n = if (ctx.args.len != 0) std.fmt.parseInt(u32, ctx.args, 10) catch 1 else ctx.n();
    ctx.win.moveBy(n);
}
fn up(ctx: Ctx) void {
    const n = if (ctx.args.len != 0) std.fmt.parseInt(u32, ctx.args, 10) catch 1 else ctx.n();
    ctx.win.moveBy(-@as(i64, n));
}
fn top(ctx: Ctx) void {
    ctx.win.moveCursor(if (ctx.count) |n| @as(i64, n) - 1 else 0);
}
fn bottom(ctx: Ctx) void {
    ctx.win.moveCursor(if (ctx.count) |n| @as(i64, n) - 1 else std.math.maxInt(i32));
}
fn halfDown(ctx: Ctx) void {
    ctx.win.moveBy(@max(1, ctx.win.pageRows() / 2) * ctx.n());
}
fn halfUp(ctx: Ctx) void {
    ctx.win.moveBy(-@as(i64, @max(1, ctx.win.pageRows() / 2) * ctx.n()));
}
fn pageDown(ctx: Ctx) void {
    ctx.win.moveBy(@max(1, ctx.win.pageRows() -| 1) * ctx.n());
}
fn pageUp(ctx: Ctx) void {
    ctx.win.moveBy(-@as(i64, @max(1, ctx.win.pageRows() -| 1) * ctx.n()));
}
fn leave(ctx: Ctx) void {
    var n = ctx.n();
    while (n > 0) : (n -= 1) ctx.win.leave();
}
fn enter(ctx: Ctx) void {
    ctx.win.enter();
}
fn open(ctx: Ctx) void {
    if (ctx.win.chooser) |ch| return ch.open(ctx.win);
    ctx.win.openTargets();
    ctx.win.consumeTargets();
}
fn back(ctx: Ctx) void {
    ctx.win.historyMove(-@as(i32, @intCast(ctx.n())));
}
fn forward(ctx: Ctx) void {
    ctx.win.historyMove(@intCast(ctx.n()));
}
fn cd(ctx: Ctx) void {
    ctx.win.cd(if (ctx.args.len == 0) "~" else unquote(ctx.args));
}
fn fuzzyFind(ctx: Ctx) void {
    ctx.win.startPicker(.files, ctx.args);
}
fn zPick(ctx: Ctx) void {
    if (!ctx.win.app.zoxide) return ctx.win.notify("zoxide is not installed (it is in most distributions' packages)", true);
    ctx.win.startPicker(.folders, ctx.args);
}
fn zJump(ctx: Ctx) void {
    const win = ctx.win;
    if (ctx.args.len == 0) return zPick(ctx);
    if (!win.app.zoxide) return win.notify("zoxide is not installed (it is in most distributions' packages)", true);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(win.gpa);
    argv.appendSlice(win.gpa, &.{ "zoxide", "query", "--exclude", win.curDir().path, "--" }) catch return;
    var it = std.mem.tokenizeScalar(u8, ctx.args, ' ');
    while (it.next()) |w| argv.append(win.gpa, w) catch return;
    win.app.runProgram(win, argv.items, zFound);
}
fn zFound(win: *Window, status: u8, output: []const u8) void {
    const path = std.mem.trim(u8, output, " \n");
    if (status != 0 or path.len == 0) return win.notify("zoxide knows no folder for that", true);
    win.cd(path);
}

fn cdXdg(ctx: Ctx) void {
    const app = ctx.win.app;
    const want = if (std.ascii.eqlIgnoreCase(ctx.args, "DOWNLOAD")) "Downloads" else if (std.ascii.eqlIgnoreCase(ctx.args, "DOCUMENTS")) "Documents" else if (std.ascii.eqlIgnoreCase(ctx.args, "PICTURES")) "Pictures" else if (std.ascii.eqlIgnoreCase(ctx.args, "MUSIC")) "Music" else if (std.ascii.eqlIgnoreCase(ctx.args, "VIDEOS")) "Videos" else if (std.ascii.eqlIgnoreCase(ctx.args, "DESKTOP")) "Desktop" else ctx.args;
    for (app.places.items.items) |p| if (p.kind == .place and std.mem.eql(u8, p.label, want)) return ctx.win.cd(p.path);
    var buf: [128]u8 = undefined;
    ctx.win.notify(std.fmt.bufPrint(&buf, "There is no {s} folder", .{want}) catch "No such folder", true);
}
fn cdMedia(ctx: Ctx) void {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const user = std.mem.span(getenv("USER") orelse "");
    const run_media = std.fmt.bufPrint(&buf, "/run/media/{s}", .{user}) catch "/media";
    ctx.win.cd(if (Window.isDirPath(run_media)) run_media else if (Window.isDirPath("/media")) "/media" else "/mnt");
}
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn trashBrowse(ctx: Ctx) void {
    const app = ctx.win.app;
    var zb: [linux.PATH_MAX]u8 = undefined;
    // The trash's folders exist once something was trashed; show it
    // empty before that.
    mkdirs(&zb, app.places.trash_files);
    ctx.win.cd(app.places.trash_files);
}
fn previewDown(ctx: Ctx) void {
    ctx.win.preview.scrollBy(@intCast(4 * ctx.n()));
}
fn previewUp(ctx: Ctx) void {
    ctx.win.preview.scrollBy(-@as(i32, @intCast(4 * ctx.n())));
}

// Searching --------------------------------------------------------------------------------

fn search(ctx: Ctx) void {
    if (ctx.args.len != 0) return searchFor(ctx.win, ctx.args, false);
    ctx.win.startPrompt(.search, "", 0, 0);
}
fn searchBack(ctx: Ctx) void {
    if (ctx.args.len != 0) return searchFor(ctx.win, ctx.args, true);
    ctx.win.startPrompt(.search_back, "", 0, 0);
}
fn searchFor(win: *Window, q: []const u8, backward: bool) void {
    win.last_search.clearRetainingCapacity();
    win.last_search.appendSlice(win.gpa, q) catch {};
    win.last_search_back = backward;
    win.searchNext(false, 1);
}
fn searchNext(ctx: Ctx) void {
    ctx.win.searchNext(false, ctx.n());
}
fn searchPrev(ctx: Ctx) void {
    ctx.win.searchNext(true, ctx.n());
}
fn find(ctx: Ctx) void {
    ctx.win.startPrompt(.find, "", 0, 0);
}
fn filter(ctx: Ctx) void {
    const d = ctx.win.curDir();
    if (!ctx.from_key or ctx.args.len != 0) {
        d.filter.clearRetainingCapacity();
        d.filter.appendSlice(ctx.win.gpa, ctx.args) catch {};
        d.refilter();
        ctx.win.showTab();
        return;
    }
    ctx.win.startPrompt(.filter, d.filter.items, @intCast(d.filter.items.len), 0);
}

// Marks ------------------------------------------------------------------------------------

fn toggleMark(ctx: Ctx) void {
    const win = ctx.win;
    const d = win.curDir();
    var n = ctx.n();
    var i = d.cursor;
    while (n > 0 and i < d.count()) : (n -= 1) {
        d.setMark(i, !d.isMarked(i));
        i += 1;
    }
    win.rebindCurrent();
    win.moveCursor(i);
}
fn markAll(ctx: Ctx) void {
    const d = ctx.win.curDir();
    var i: u32 = 0;
    while (i < d.count()) : (i += 1) d.setMark(i, true);
    ctx.win.rebindCurrent();
}
fn unmarkAll(ctx: Ctx) void {
    ctx.win.curDir().clearMarks();
    ctx.win.rebindCurrent();
}
fn invertMarks(ctx: Ctx) void {
    const d = ctx.win.curDir();
    var i: u32 = 0;
    while (i < d.count()) : (i += 1) d.setMark(i, !d.isMarked(i));
    ctx.win.rebindCurrent();
}
fn visual(ctx: Ctx) void {
    if (ctx.win.mode == .visual) return ctx.win.finishVisual(true);
    ctx.win.startVisual();
}
fn visualEnd(ctx: Ctx) void {
    ctx.win.finishVisual(true);
}
fn escape(ctx: Ctx) void {
    const win = ctx.win;
    const d = win.curDir();
    if (win.mode == .visual) return win.finishVisual(false);
    if (d.filter.items.len != 0) {
        d.filter.clearRetainingCapacity();
        d.refilter();
        win.showTab();
        return;
    }
    if (d.mark_count != 0) {
        d.clearMarks();
        win.rebindCurrent();
        return;
    }
    // Nothing to clear: a file chooser is cancelled.
    if (win.chooser) |ch| ch.finish(1);
}

// The register -------------------------------------------------------------------------------

fn takeTargets(ctx: Ctx, cut_: bool) void {
    const win = ctx.win;
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.app.setRegister(Window.toConst(paths), cut_);
    win.writeClipboard(Window.toConst(paths), cut_);
    win.consumeTargets();
    var buf: [400]u8 = undefined;
    const msg = if (paths.len == 1)
        std.fmt.bufPrint(&buf, "{s} “{s}”", .{ if (cut_) "Cut" else "Copied", model.basename(paths[0]) }) catch ""
    else
        std.fmt.bufPrint(&buf, "{s} {d} items", .{ if (cut_) "Cut" else "Copied", paths.len }) catch "";
    win.notify(msg, false);
}
fn yank(ctx: Ctx) void {
    takeTargets(ctx, false);
}
fn cut(ctx: Ctx) void {
    takeTargets(ctx, true);
}
fn paste(ctx: Ctx) void {
    const d = ctx.win.curDir();
    if (d.isTrash()) return ctx.win.notify("Paste into a folder, not the trash", true);
    ctx.win.paste(d.path, false);
}
fn pasteOverwrite(ctx: Ctx) void {
    const d = ctx.win.curDir();
    if (d.isTrash()) return ctx.win.notify("Paste into a folder, not the trash", true);
    ctx.win.paste(d.path, true);
}
fn yankText(ctx: Ctx, which: enum { path, name }) void {
    const win = ctx.win;
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(win.gpa);
    for (paths, 0..) |p, i| {
        if (i > 0) out.append(win.gpa, '\n') catch return;
        out.appendSlice(win.gpa, if (which == .path) p else model.basename(p)) catch return;
    }
    if (out.items.len == 0) return;
    win.writeClipboardText(out.items);
    win.consumeTargets();
    var buf: [512]u8 = undefined;
    win.notify(std.fmt.bufPrint(&buf, "Copied {s}", .{if (paths.len == 1) out.items else if (which == .path) "the paths" else "the names"}) catch "Copied", false);
}
fn yankPath(ctx: Ctx) void {
    yankText(ctx, .path);
}
fn yankName(ctx: Ctx) void {
    yankText(ctx, .name);
}
fn yankDir(ctx: Ctx) void {
    const p = ctx.win.curDir().path;
    ctx.win.writeClipboardText(p);
    var buf: [linux.PATH_MAX + 16]u8 = undefined;
    ctx.win.notify(std.fmt.bufPrint(&buf, "Copied {s}", .{p}) catch "Copied", false);
}

// Operations -------------------------------------------------------------------------------

fn trashCmd(ctx: Ctx) void {
    const win = ctx.win;
    if (win.curDir().isTrash()) return delete(ctx);
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.app.startOp(win, .trash, Window.toConst(paths), "", &.{}, true);
    win.consumeTargets();
}
fn delete(ctx: Ctx) void {
    const win = ctx.win;
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.confirmDelete(Window.toConst(paths));
    // Out of visual mode, as every operator; the range stays marked, so
    // cancelling the dialog loses nothing.
    win.finishVisual(true);
}
fn restore(ctx: Ctx) void {
    const win = ctx.win;
    if (!win.curDir().isTrash()) return win.notify("Restore works in the trash (gx)", true);
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.app.restoreFromTrash(win, Window.toConst(paths));
    win.consumeTargets();
}
/// "-R" before or after the rest of the arguments.
fn recursiveFlag(args: []const u8) struct { bool, []const u8 } {
    const t = std.mem.trim(u8, args, " ");
    if (std.mem.startsWith(u8, t, "-R ")) return .{ true, std.mem.trim(u8, t[3..], " ") };
    if (std.mem.endsWith(u8, t, " -R")) return .{ true, std.mem.trim(u8, t[0 .. t.len - 3], " ") };
    return .{ false, t };
}

fn chmod(ctx: Ctx) void {
    const win = ctx.win;
    const recursive, const spec = recursiveFlag(ctx.args);
    if (spec.len == 0) return win.startPrompt(.command, "chmod ", 6, 6);
    if (!fsops.parseMode(spec)) {
        var buf: [128]u8 = undefined;
        return win.notify(std.fmt.bufPrint(&buf, "Not a mode: {s} (755, u+x, go-w, a=rX)", .{spec}) catch "Not a mode", true);
    }
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.app.startAttrOp(win, .chmod, Window.toConst(paths), spec, null, null, recursive);
    win.consumeTargets();
}

fn chown(ctx: Ctx) void {
    const win = ctx.win;
    const recursive, const spec = recursiveFlag(ctx.args);
    if (spec.len == 0) return win.startPrompt(.command, "chown ", 6, 6);
    const o = parseOwner(win, spec) orelse return;
    if (o.uid == null and o.gid == null) return win.notify("chown needs a user, user:group, or :group", true);
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    win.app.startAttrOp(win, .chown, Window.toConst(paths), "", o.uid, o.gid, recursive);
    win.consumeTargets();
}

pub const Owner = struct { uid: ?u32, gid: ?u32 };

/// "user", "user:group", or ":group", by name or number; says in the
/// status line what is wrong.
pub fn parseOwner(win: *Window, spec: []const u8) ?Owner {
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const user = spec[0 .. colon orelse spec.len];
    const group = if (colon) |i| spec[i + 1 ..] else "";
    var buf: [160]u8 = undefined;
    const uid: ?u32 = if (user.len == 0) null else userId(user) orelse {
        win.notify(std.fmt.bufPrint(&buf, "No such user: {s}", .{user}) catch "No such user", true);
        return null;
    };
    const gid: ?u32 = if (group.len == 0) null else groupId(group) orelse {
        win.notify(std.fmt.bufPrint(&buf, "No such group: {s}", .{group}) catch "No such group", true);
        return null;
    };
    return .{ .uid = uid, .gid = gid };
}

/// A user by name or number (getpwnam: /etc/passwd, or NSS).
fn userId(name: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, name, 10)) |n| return n else |_| {}
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    const pw = std.c.getpwnam(z) orelse return null;
    return pw.uid;
}

fn groupId(name: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, name, 10)) |n| return n else |_| {}
    var buf: [256]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return null;
    const gr = getgrnam(z) orelse return null;
    return gr.gid;
}

const Group = extern struct { name: ?[*:0]u8, passwd: ?[*:0]u8, gid: u32, members: ?[*:null]?[*:0]u8 };
extern "c" fn getgrnam(name: [*:0]const u8) ?*Group;

fn emptyTrash(ctx: Ctx) void {
    ctx.win.dialogs.confirmEmptyTrash();
}
fn undo(ctx: Ctx) void {
    var n = ctx.n();
    while (n > 0) : (n -= 1) ctx.win.app.undoLast(ctx.win);
}

fn renameWith(ctx: Ctx, where: enum { stem, end, start }) void {
    const win = ctx.win;
    const d = win.curDir();
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, d.cursor) orelse return;
    if (ctx.args.len != 0) {
        if (win.app.renameOne(win, p, unquote(ctx.args))) d.selectName(unquote(ctx.args));
        return;
    }
    win.prompt_target.clearRetainingCapacity();
    win.prompt_target.appendSlice(win.gpa, p) catch return;
    const name = model.basename(p);
    const e = d.current().?;
    // The name without its extension is selected (folders: all of it).
    const stem: u32 = @intCast(if (e.kind == .dir) name.len else if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| (if (dot == 0) name.len else dot) else name.len);
    switch (where) {
        .stem => win.startPrompt(.rename, name, stem, 0),
        .end => win.startPrompt(.rename, name, stem, stem),
        .start => win.startPrompt(.rename, name, 0, 0),
    }
}
fn rename(ctx: Ctx) void {
    renameWith(ctx, .stem);
}
fn renameAppend(ctx: Ctx) void {
    renameWith(ctx, .end);
}
fn renameInsert(ctx: Ctx) void {
    renameWith(ctx, .start);
}

/// The rename prompt's Enter.
pub fn finishRename(win: *Window, name: []const u8) void {
    const old = win.prompt_target.items;
    if (old.len == 0 or name.len == 0) return;
    if (win.app.renameOne(win, old, name)) win.curDir().selectName(name);
}

fn create(ctx: Ctx) void {
    if (ctx.args.len != 0) return finishCreate(ctx.win, ctx.args);
    ctx.win.startPrompt(.create, "", 0, 0);
}
fn mkdir(ctx: Ctx) void {
    if (ctx.args.len == 0) return ctx.win.notify("mkdir needs a name", true);
    var buf: [linux.PATH_MAX]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}/", .{std.mem.trimEnd(u8, unquote(ctx.args), "/")}) catch return;
    finishCreate(ctx.win, name);
}
fn touch(ctx: Ctx) void {
    if (ctx.args.len == 0) return ctx.win.notify("touch needs a name", true);
    finishCreate(ctx.win, std.mem.trimEnd(u8, unquote(ctx.args), "/"));
}

/// The new-file prompt's Enter: "name" makes a file, "name/" a folder
/// (and "a/b/c" the folders on the way).
pub fn finishCreate(win: *Window, text: []const u8) void {
    const d = win.curDir();
    if (text.len == 0) return;
    const is_dir = text[text.len - 1] == '/';
    const rel = std.mem.trim(u8, text, "/");
    if (rel.len == 0) return;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const full = model.join(&buf, d.path, rel) orelse return;
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{full}, 0) catch return;
    if (fsops.exists(z)) return win.notify("That name is taken", true);
    // Folders on the way.
    var parent_buf: [linux.PATH_MAX]u8 = undefined;
    mkdirs(&parent_buf, model.parent(full));
    const r = if (is_dir) fsops.makeDir(model.parent(full), model.basename(full)) else fsops.makeFile(model.parent(full), model.basename(full));
    r catch |err| {
        var mbuf: [512]u8 = undefined;
        return win.notify(std.fmt.bufPrint(&mbuf, "Could not create “{s}”: {s}", .{ rel, fsops.describe(err) }) catch "Could not create it", true);
    };
    win.app.undo.pushCreated(full);
    const first = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len];
    d.selectName(first);
    d.reload();
}

fn mkdirs(buf: *[linux.PATH_MAX]u8, dir: []const u8) void {
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(buf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = linux.mkdirat(linux.AT.FDCWD, z, 0o755);
        }
    }
}

fn openWith(ctx: Ctx) void {
    const win = ctx.win;
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    if (paths.len == 0) return;
    if (ctx.args.len != 0) {
        // ":open-with app-id" or a command.
        if (win.app.apps_db) |db| if (db.get(ctx.args)) |app| return win.app.launch(win, app, Window.toConst(paths));
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(win.gpa);
        cmd.appendSlice(win.gpa, ctx.args) catch return;
        cmd.appendSlice(win.gpa, " \"$@\" &") catch return;
        return runShellArgs(win, cmd.items, Window.toConst(paths), false, true);
    }
    win.openWithMenu(Window.toConst(paths));
}

// Shell commands ------------------------------------------------------------------------------

fn shellPrompt(ctx: Ctx) void {
    ctx.win.startPrompt(.shell, "", 0, 0);
}
fn shell(ctx: Ctx) void {
    var args = ctx.args;
    var term = false;
    if (std.mem.startsWith(u8, args, "-t ")) {
        term = true;
        args = std.mem.trim(u8, args[3..], " ");
    }
    if (args.len == 0) return shellPrompt(ctx);
    runShell(ctx.win, args, term);
}

/// Runs `cmd` with the shell in the current folder, the targets as $@
/// (and %s in the text), and shows what it printed.
pub fn runShell(win: *Window, cmd: []const u8, in_terminal: bool) void {
    const paths = win.targets() catch return;
    defer App.freePaths(win.gpa, paths);
    runShellArgs(win, cmd, Window.toConst(paths), in_terminal, false);
    win.consumeTargets();
}

const ShellJob = struct {
    win: ?*Window,
    app: *App,
    gpa: Allocator,
    argv: [][]u8,
    cwd: []u8,
    cmd: []u8,
    result: ?proc.Result = null,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const j: *ShellJob = @ptrCast(@alignCast(ud.?));
        const views = j.gpa.alloc([]const u8, j.argv.len) catch return;
        defer j.gpa.free(views);
        for (j.argv, 0..) |a, i| views[i] = a;
        j.result = proc.run(j.gpa, views, .{ .cwd = j.cwd, .max_output = 64 * 1024 }) catch null;
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const j: *ShellJob = @ptrCast(@alignCast(ud.?));
        const app = j.app;
        app.cache.invalidate(j.cwd);
        // The window may be gone.
        var win: ?*Window = null;
        for (app.windows.items) |w| if (j.win == w) {
            win = w;
        };
        const w = win orelse return;
        const r = j.result orelse return w.notify("The shell could not run", true);
        const out = std.mem.trimEnd(u8, r.output, "\n");
        var buf: [600]u8 = undefined;
        if (out.len == 0) {
            if (r.status != 0) w.notify(std.fmt.bufPrint(&buf, "“{s}” exited with {d}", .{ j.cmd, r.status }) catch "Failed", true);
            return;
        }
        // The last line in the status line; all of it in the preview.
        const last = out[if (std.mem.lastIndexOfScalar(u8, out, '\n')) |i| i + 1 else 0..];
        w.notify(last, r.status != 0);
        w.preview.showOutput(j.cmd, out, null);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const j: *ShellJob = @ptrCast(@alignCast(ud.?));
        const gpa = j.gpa;
        if (j.result) |*r| r.deinit(gpa);
        for (j.argv) |a| gpa.free(a);
        gpa.free(j.argv);
        gpa.free(j.cwd);
        gpa.free(j.cmd);
        gpa.destroy(j);
    }
};

fn runShellArgs(win: *Window, cmd: []const u8, paths: []const []const u8, in_terminal: bool, detached: bool) void {
    const gpa = win.gpa;
    const app = win.app;
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    // "%s" stands for the targets, quoted.
    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(gpa);
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '%' and i + 1 < cmd.len and (cmd[i + 1] == 's' or cmd[i + 1] == 'f' or cmd[i + 1] == 'd')) {
            const which = cmd[i + 1];
            i += 1;
            if (which == 'd') {
                appendQuoted(gpa, &expanded, win.curDir().path) catch return;
                continue;
            }
            for (paths, 0..) |p, k| {
                if (which == 'f' and k > 0) break;
                if (k > 0) expanded.append(gpa, ' ') catch return;
                appendQuoted(gpa, &expanded, p) catch return;
            }
            continue;
        }
        expanded.append(gpa, cmd[i]) catch return;
    }
    const shell_prog = app.options.shell;
    if (in_terminal) {
        const term = terminalCommand(app);
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        line.appendSlice(gpa, expanded.items) catch return;
        line.appendSlice(gpa, "; printf '\\n[exit %s] ' $?; read -r _") catch return;
        var targs: std.ArrayList([]const u8) = .empty;
        defer targs.deinit(gpa);
        for (term.items) |t| targs.append(gpa, t) catch return;
        targs.appendSlice(gpa, &.{ shell_prog, "-c", line.items, shell_prog }) catch return;
        for (paths) |p| targs.append(gpa, p) catch return;
        apps.spawn(gpa, targs.items, win.curDir().path, "") catch win.notify("Could not start a terminal", true);
        term.deinit();
        return;
    }
    if (detached) {
        var targs: std.ArrayList([]const u8) = .empty;
        defer targs.deinit(gpa);
        targs.appendSlice(gpa, &.{ shell_prog, "-c", expanded.items, shell_prog }) catch return;
        for (paths) |p| targs.append(gpa, p) catch return;
        apps.spawn(gpa, targs.items, win.curDir().path, "") catch win.notify("Could not run it", true);
        return;
    }
    argv.append(gpa, gpa.dupe(u8, shell_prog) catch return) catch return;
    argv.append(gpa, gpa.dupe(u8, "-c") catch return) catch return;
    argv.append(gpa, gpa.dupe(u8, expanded.items) catch return) catch return;
    argv.append(gpa, gpa.dupe(u8, shell_prog) catch return) catch return;
    for (paths) |p| argv.append(gpa, gpa.dupe(u8, p) catch return) catch return;
    const j = gpa.create(ShellJob) catch return;
    j.* = .{
        .win = win,
        .app = app,
        .gpa = gpa,
        .argv = argv.toOwnedSlice(gpa) catch return gpa.destroy(j),
        .cwd = gpa.dupe(u8, win.curDir().path) catch "",
        .cmd = gpa.dupe(u8, cmd) catch "",
    };
    _ = c.siv_job_start(app.app, .{}, ShellJob.work, ShellJob.done, ShellJob.destroy, j);
}

fn appendQuoted(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, ch);
    }
    try out.append(gpa, '\'');
}

const TermCmd = struct {
    arena: std.heap.ArenaAllocator,
    items: []const []const u8,
    fn deinit(t: *const TermCmd) void {
        var a = t.arena;
        a.deinit();
    }
};

/// The terminal command, option or found: "foot", "kitty --", ...
pub fn terminalCommand(app: *App) TermCmd {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    const a = arena.allocator();
    if (app.options.terminal.len != 0) {
        const parts = apps.splitExec(a, app.options.terminal) catch &.{};
        return .{ .arena = arena, .items = parts };
    }
    if (getenv("TERMINAL")) |t| {
        const parts = apps.splitExec(a, std.mem.span(t)) catch &.{};
        if (parts.len != 0) return .{ .arena = arena, .items = parts };
    }
    const known = [_][]const []const u8{
        &.{ "foot", "--" },
        &.{ "alacritty", "-e" },
        &.{ "kitty", "--" },
        &.{ "wezterm", "start", "--" },
        &.{ "ghostty", "-e" },
        &.{ "gnome-terminal", "--wait", "--" },
        &.{ "konsole", "-e" },
        &.{ "xterm", "-e" },
    };
    for (known) |k| if (proc.onPath(k[0])) return .{ .arena = arena, .items = k };
    return .{ .arena = arena, .items = &.{ "xterm", "-e" } };
}

/// :insert [stem|start|end|clear]: a chooser's name or path field,
/// with the caret where vim's i, a, I, A, or cc would put it.
fn insert(ctx: Ctx) void {
    const win = ctx.win;
    const ch = win.chooser orelse return win.notify("Only a chooser has a name or path to type", true);
    const a = std.mem.trim(u8, ctx.args, " ");
    const how: App.Chooser.Insert = if (a.len == 0) .keep else std.meta.stringToEnum(App.Chooser.Insert, a) orelse return win.notify("insert takes stem, start, end, or clear", true);
    _ = ch.insert(how);
}

/// :terminal [folder]: the user's terminal in the folder shown (or
/// that one), taking focus.
fn terminal(ctx: Ctx) void {
    const win = ctx.win;
    if (win.curDir().isTrash() and ctx.args.len == 0) return win.notify("No terminal in the trash", true);
    var buf: [linux.PATH_MAX]u8 = undefined;
    win.app.openTerminal(win, if (ctx.args.len != 0) win.expandPath(&buf, unquote(ctx.args)) else win.curDir().path);
}

// Bulk rename ------------------------------------------------------------------------------

const BulkJob = struct {
    win: ?*Window,
    app: *App,
    gpa: Allocator,
    paths: [][]u8,
    file: []u8,
    argv: [][]u8,
    status: u8 = 255,
    edited: ?[]u8 = null,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const j: *BulkJob = @ptrCast(@alignCast(ud.?));
        const views = j.gpa.alloc([]const u8, j.argv.len) catch return;
        defer j.gpa.free(views);
        for (j.argv, 0..) |a, i| views[i] = a;
        var r = proc.run(j.gpa, views, .{ .null_stdin = false, .max_output = 4096 }) catch return;
        defer r.deinit(j.gpa);
        j.status = r.status;
        j.edited = readFile(j.gpa, j.file);
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const j: *BulkJob = @ptrCast(@alignCast(ud.?));
        var win: ?*Window = null;
        for (j.app.windows.items) |w| if (j.win == w) {
            win = w;
        };
        const w = win orelse return;
        if (j.status != 0) return w.notify("The editor failed; nothing was renamed", true);
        const text = j.edited orelse return w.notify("The list could not be read back", true);
        applyBulk(w, j.paths, text);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const j: *BulkJob = @ptrCast(@alignCast(ud.?));
        const gpa = j.gpa;
        var zb: [linux.PATH_MAX]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&zb, "{s}", .{j.file}, 0)) |z| _ = linux.unlinkat(linux.AT.FDCWD, z, 0) else |_| {}
        for (j.paths) |p| gpa.free(p);
        gpa.free(j.paths);
        for (j.argv) |a| gpa.free(a);
        gpa.free(j.argv);
        gpa.free(j.file);
        if (j.edited) |e| gpa.free(e);
        gpa.destroy(j);
    }
};

/// Applies an edited list of names: line i is the new name of path i.
pub fn applyBulk(win: *Window, paths: []const []const u8, text: []const u8) void {
    const gpa = win.gpa;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| names.append(gpa, l) catch return;
    if (names.items.len != paths.len) {
        var buf: [128]u8 = undefined;
        return win.notify(std.fmt.bufPrint(&buf, "The list has {d} lines for {d} names; nothing was renamed", .{ names.items.len, paths.len }) catch "Line count changed", true);
    }
    var pairs: std.ArrayList([2][]const u8) = .empty;
    defer pairs.deinit(gpa);
    var bufs: std.ArrayList([]u8) = .empty;
    defer {
        for (bufs.items) |b| gpa.free(b);
        bufs.deinit(gpa);
    }
    for (paths, names.items) |p, n| {
        if (std.mem.eql(u8, model.basename(p), n)) continue;
        if (!model.validName(n)) {
            var buf: [300]u8 = undefined;
            return win.notify(std.fmt.bufPrint(&buf, "“{s}” is not a valid name; nothing was renamed", .{n}) catch "Invalid name", true);
        }
        const to = std.fmt.allocPrint(gpa, "{s}/{s}", .{ model.parent(p), n }) catch return;
        bufs.append(gpa, to) catch return;
        pairs.append(gpa, .{ p, to }) catch return;
    }
    if (pairs.items.len == 0) return win.notify("No names changed", false);
    _ = win.app.renameMany(win, pairs.items);
}

fn bulkRename(ctx: Ctx) void {
    const win = ctx.win;
    const app = win.app;
    const gpa = win.gpa;
    const paths = win.targets() catch return;
    if (paths.len == 0) return App.freePaths(gpa, paths);
    // The names, one per line, in a temporary file.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    for (paths) |p| {
        const name = model.basename(p);
        if (std.mem.indexOfScalar(u8, name, '\n') != null) {
            App.freePaths(gpa, paths);
            return win.notify("Names with line breaks cannot be renamed in an editor", true);
        }
        body.appendSlice(gpa, name) catch return;
        body.append(gpa, '\n') catch return;
    }
    const tmpdir = std.mem.span(getenv("XDG_RUNTIME_DIR") orelse getenv("TMPDIR") orelse "/tmp");
    var fbuf: [linux.PATH_MAX]u8 = undefined;
    const file = std.fmt.bufPrint(&fbuf, "{s}/" ++ App.program ++ "-rename-{d}-{d}.txt", .{ tmpdir, linux.getpid(), @as(u64, @bitCast(Dir.now())) }) catch return;
    if (!writeFile(file, body.items)) {
        App.freePaths(gpa, paths);
        return win.notify("Could not write the list of names", true);
    }
    // The editor: in a terminal unless it is a graphical one.
    const editor = if (app.options.editor.len != 0) app.options.editor else std.mem.span(getenv("VISUAL") orelse getenv("EDITOR") orelse "vi");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ed_argv = apps.splitExec(arena.allocator(), editor) catch &.{};
    var argv: std.ArrayList([]u8) = .empty;
    if (app.options.editor_in_terminal) {
        const term = terminalCommand(app);
        defer term.deinit();
        for (term.items) |t| argv.append(gpa, gpa.dupe(u8, t) catch return) catch return;
    }
    for (ed_argv) |a| argv.append(gpa, gpa.dupe(u8, a) catch return) catch return;
    argv.append(gpa, gpa.dupe(u8, file) catch return) catch return;
    const j = gpa.create(BulkJob) catch return;
    j.* = .{ .win = win, .app = app, .gpa = gpa, .paths = paths, .file = gpa.dupe(u8, file) catch return, .argv = argv.toOwnedSlice(gpa) catch return };
    win.consumeTargets();
    win.notify("Editing the names: save and quit the editor to rename", false);
    _ = c.siv_job_start(app.app, .{}, BulkJob.work, BulkJob.done, BulkJob.destroy, j);
}

fn writeFile(path: []const u8, data: []const u8) bool {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return false;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

fn readFile(gpa: Allocator, path: []const u8) ?[]u8 {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

// Views ----------------------------------------------------------------------------------------

fn reload(ctx: Ctx) void {
    ctx.win.reload();
}

fn toggleHidden(ctx: Ctx) void {
    const app = ctx.win.app;
    app.options.show_hidden = !app.options.show_hidden;
    app.applyViewOptions();
    ctx.win.notify(if (app.options.show_hidden) "Showing hidden files" else "Hiding hidden files", false);
}
fn togglePreview(ctx: Ctx) void {
    const app = ctx.win.app;
    app.options.preview = !app.options.preview;
    app.applyViewOptions();
}
fn toggleIcons(ctx: Ctx) void {
    const app = ctx.win.app;
    app.options.icons = !app.options.icons;
    app.applyViewOptions();
}
fn sort(ctx: Ctx) void {
    const app = ctx.win.app;
    var it = std.mem.tokenizeScalar(u8, ctx.args, ' ');
    const key_name = it.next() orelse return ctx.win.notify("sort needs a key: name, size, modified, type, extension", true);
    const key = Config.parseSortKey(key_name) orelse return ctx.win.notify("Unknown sort key", true);
    var descending = false;
    if (it.next()) |w| descending = std.mem.eql(u8, w, "reverse") or std.mem.eql(u8, w, "desc");
    app.options.sort.key = key;
    app.options.sort.descending = descending;
    app.applyViewOptions();
}
fn sortReverse(ctx: Ctx) void {
    const app = ctx.win.app;
    app.options.sort.descending = !app.options.sort.descending;
    app.applyViewOptions();
}
fn sortDirsFirst(ctx: Ctx) void {
    const app = ctx.win.app;
    app.options.sort.folders_first = !app.options.sort.folders_first;
    app.applyViewOptions();
}
fn set(ctx: Ctx) void {
    const app = ctx.win.app;
    var it = std.mem.tokenizeAny(u8, ctx.args, " =");
    var name = it.next() orelse return ctx.win.notify("set needs an option", true);
    var value: ?[]const u8 = it.rest();
    if (value.?.len == 0) value = null;
    // "set nohidden", "set hidden!" as in vim.
    if (std.mem.endsWith(u8, name, "!")) {
        name = name[0 .. name.len - 1];
        value = null;
    } else if (std.mem.startsWith(u8, name, "no") and Config.info(name[2..]) != null and Config.info(name[2..]).?.kind == .boolean) {
        name = name[2..];
        value = "false";
    } else if (value == null) if (Config.info(name)) |i| if (i.kind == .boolean) {
        value = "true";
    };
    Config.setFromText(&app.options, &app.strings, name, value) catch |err| {
        var buf: [128]u8 = undefined;
        return ctx.win.notify(std.fmt.bufPrint(&buf, "set {s}: {s}", .{ name, switch (err) {
            error.UnknownOption => "no such option",
            error.InvalidValue => "invalid value",
            error.OutOfMemory => "out of memory",
        } }) catch "Cannot set it", true);
    };
    // Set by hand: the next chooser takes it over the remembered size.
    if (std.mem.eql(u8, name, "chooser_size")) app.forgetChooserSize();
    app.applyViewOptions();
}

// Bookmarks -----------------------------------------------------------------------------------

fn bookmarkSet(ctx: Ctx) void {
    if (ctx.args.len != 0) {
        const k = bookmarkKey(ctx) orelse return;
        ctx.win.app.setBookmark(k, ctx.win.curDir().path);
        return;
    }
    ctx.win.awaitKey(.bookmark_set);
}
fn bookmarkJump(ctx: Ctx) void {
    if (ctx.args.len != 0) {
        const k = bookmarkKey(ctx) orelse return;
        if (ctx.win.app.bookmarks.get(k)) |p| return ctx.win.cd(p);
        return ctx.win.notify("No such bookmark", true);
    }
    ctx.win.awaitKey(.bookmark_jump);
}
/// A bookmark command's argument: one key, a single codepoint.
fn bookmarkKey(ctx: Ctx) ?u32 {
    const a = std.mem.trim(u8, ctx.args, " ");
    const k = keys.decodeFirst(a) orelse {
        ctx.win.notify("A bookmark is one key", true);
        return null;
    };
    if (k.len != a.len) {
        ctx.win.notify("A bookmark is one key", true);
        return null;
    }
    return k.cp;
}
fn bookmarkRemove(ctx: Ctx) void {
    ctx.win.awaitKey(.bookmark_remove);
}

// Tabs ----------------------------------------------------------------------------------------

fn tabNew(ctx: Ctx) void {
    const win = ctx.win;
    if (ctx.args.len != 0) {
        var buf: [linux.PATH_MAX]u8 = undefined;
        return win.newTab(win.expandPath(&buf, unquote(ctx.args)));
    }
    win.newTab(win.curDir().path);
}
fn tabClose(ctx: Ctx) void {
    ctx.win.closeTab();
}
fn tabNext(ctx: Ctx) void {
    const win = ctx.win;
    const n = win.tabs.items.len;
    if (ctx.count) |k| return win.selectTab(k -| 1);
    win.selectTab((win.active + 1) % n);
}
fn tabPrev(ctx: Ctx) void {
    const win = ctx.win;
    const n = win.tabs.items.len;
    win.selectTab((win.active + n - 1) % n);
}
fn tabGo(ctx: Ctx) void {
    const n = std.fmt.parseInt(usize, ctx.args, 10) catch @as(usize, ctx.count orelse 1);
    ctx.win.selectTab(n -| 1);
}

// Drives --------------------------------------------------------------------------------------

fn drives(ctx: Ctx) void {
    ctx.win.drivesMenu();
}
fn mount(ctx: Ctx) void {
    const win = ctx.win;
    const app = win.app;
    for (app.places.drives.items, 0..) |d, i| {
        if (ctx.args.len == 0 or std.ascii.eqlIgnoreCase(d.label, ctx.args)) {
            if (d.mount_point.len != 0) return win.cd(d.mount_point);
            if (app.udisks) |u| return u.mount(win, @intCast(i), false);
        }
    }
    win.notify("No such drive", true);
}
fn unmountWith(ctx: Ctx, do_eject: bool) void {
    const win = ctx.win;
    const app = win.app;
    const here = win.curDir().path;
    for (app.places.drives.items, 0..) |d, i| {
        if (d.mount_point.len != 0 and (ctx.args.len == 0 and model.isWithin(here, d.mount_point) or std.ascii.eqlIgnoreCase(d.label, ctx.args))) {
            if (app.udisks) |u| return u.unmount(win, @intCast(i), do_eject);
            return win.notify("Unmounting needs UDisks2", true);
        }
    }
    win.notify("This folder is not on a drive that can be unmounted", true);
}
fn unmount(ctx: Ctx) void {
    unmountWith(ctx, false);
}
fn eject(ctx: Ctx) void {
    unmountWith(ctx, true);
}

// Configuration --------------------------------------------------------------------------------

fn map(ctx: Ctx) void {
    var rest = ctx.args;
    var mode: keys.Mode = .normal;
    var it = std.mem.tokenizeScalar(u8, rest, ' ');
    var first = it.next() orelse return ctx.win.notify("map needs keys and a command", true);
    if (keys.Mode.parse(first)) |m| {
        mode = m;
        first = it.next() orelse return ctx.win.notify("map needs keys and a command", true);
    }
    rest = std.mem.trim(u8, it.rest(), " ");
    if (rest.len == 0) return ctx.win.notify("map needs a command", true);
    ctx.win.app.keymap.map(mode, first, .{ .command = rest }, "") catch return ctx.win.notify("Invalid keys", true);
}
fn unmap(ctx: Ctx) void {
    var it = std.mem.tokenizeScalar(u8, ctx.args, ' ');
    var mode: keys.Mode = .normal;
    var first = it.next() orelse return;
    if (keys.Mode.parse(first)) |m| {
        mode = m;
        first = it.next() orelse return;
    }
    _ = ctx.win.app.keymap.unmap(mode, first) catch {};
}
fn luaCmd(ctx: Ctx) void {
    const l = ctx.win.app.lua orelse return ctx.win.notify("Lua is not available", true);
    l.runString(ctx.win, ctx.args);
}

/// Every binding and command, in the preview.
fn help(ctx: Ctx) void {
    const win = ctx.win;
    const gpa = win.gpa;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, "KEYS\n\n") catch return;
    for (win.app.keymap.bindings.items) |b| {
        var kb: [64]u8 = undefined;
        const ks = keys.format(&kb, b.keys);
        const what = switch (b.action) {
            .command => |cmd| cmd,
            .lua => "(Lua)",
        };
        out.print(gpa, "{s}{s: <10} {s: <24} {s}\n", .{ switch (b.mode) {
            .normal => "  ",
            .visual => "v ",
            .tasks => "t ",
        }, ks, what, b.desc }) catch return;
    }
    out.appendSlice(gpa, "\nCOMMANDS (type : and Tab completes)\n\n") catch return;
    for (list) |cmd| out.print(gpa, "  {s: <18} {s}\n", .{ cmd.name, cmd.desc }) catch return;
    if (win.app.lua) |l| l.appendCommands(&out);
    win.preview.showOutput("Keys and commands", out.items, null);
}

/// The status line's recent messages in the preview, newest first,
/// errors in the error color.
fn messages(ctx: Ctx) void {
    const win = ctx.win;
    const gpa = win.gpa;
    const app = win.app;
    // Not a message itself: it would list itself next time.
    if (app.messages.items.len == 0) return win.preview.showOutput("Messages", "No messages yet.\n", null);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var spans: std.ArrayList(highlight.Span) = .empty;
    defer spans.deinit(gpa);
    out.appendSlice(gpa, "MESSAGES (newest first)\n\n") catch return;
    var i = app.messages.items.len;
    while (i > 0) {
        i -= 1;
        const m = app.messages.items[i];
        const start: u32 = @intCast(out.items.len);
        const secs: u64 = @intCast(@max(0, m.time + app.tz_offset_s));
        const ds = (std.time.epoch.EpochSeconds{ .secs = secs }).getDaySeconds();
        out.print(gpa, "{d:0>2}:{d:0>2}:{d:0>2}  ", .{ ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch return;
        // One line each.
        for (m.text) |ch| out.append(gpa, if (ch == '\n') ' ' else ch) catch return;
        if (m.is_error) spans.append(gpa, .{ .start = start, .end = @intCast(out.items.len), .class = .removed }) catch {};
        out.append(gpa, '\n') catch return;
    }
    win.preview.showOutput("Messages", out.items, spans.items);
}

fn properties(ctx: Ctx) void {
    const paths = ctx.win.targets() catch return;
    if (paths.len == 0) return App.freePaths(ctx.win.gpa, paths);
    ctx.win.dialogs.properties(paths);
}

fn contextMenu(ctx: Ctx) void {
    ctx.win.contextMenuAtCursor();
}

// Column widths ---------------------------------------------------------------------------

/// How far < and > move a column's edge, in logical pixels, per count.
const column_step: f32 = 32;

fn columnWider(ctx: Ctx) void {
    ctx.win.resizeColumn(std.mem.eql(u8, std.mem.trim(u8, ctx.args, " "), "parent"), column_step * @as(f32, @floatFromInt(ctx.n())));
}
fn columnNarrower(ctx: Ctx) void {
    ctx.win.resizeColumn(std.mem.eql(u8, std.mem.trim(u8, ctx.args, " "), "parent"), -column_step * @as(f32, @floatFromInt(ctx.n())));
}
fn columnReset(ctx: Ctx) void {
    ctx.win.app.setWidths(null);
}

// Tasks -------------------------------------------------------------------------------------

fn tasks(ctx: Ctx) void {
    if (ctx.win.mode == .tasks) ctx.win.closeTasks() else ctx.win.openTasks();
}
fn taskDown(ctx: Ctx) void {
    ctx.win.moveTaskCursor(@intCast(ctx.n()));
}
fn taskUp(ctx: Ctx) void {
    ctx.win.moveTaskCursor(-@as(i32, @intCast(ctx.n())));
}

/// The task the view selects; with the view closed, the first running.
fn selectedTask(win: *Window) ?App.Task {
    if (win.mode == .tasks) return win.app.taskAt(win.task_cursor);
    return win.app.taskAt(0);
}

fn taskPause(ctx: Ctx) void {
    const t = selectedTask(ctx.win) orelse return ctx.win.notify("No task is running", false);
    switch (t) {
        .running => |e| e.op.setPaused(!e.op.isPaused()),
        .finished => return ctx.win.notify("That task is done", false),
    }
    ctx.win.app.updateOps();
}

fn taskCancel(ctx: Ctx) void {
    const win = ctx.win;
    const t = selectedTask(win) orelse return win.notify("No task is running", false);
    switch (t) {
        .running => |e| e.op.requestCancel(),
        .finished => if (win.mode == .tasks) win.app.removeRecent(win.task_cursor - win.app.ops.items.len),
    }
    win.app.updateOps();
}

fn commandLine(ctx: Ctx) void {
    ctx.win.startPrompt(.command, ctx.args, @intCast(ctx.args.len), @intCast(ctx.args.len));
}
fn newWindow(ctx: Ctx) void {
    _ = ctx.win.app.newWindow(ctx.win.curDir().path) catch {};
}
fn quit(ctx: Ctx) void {
    if (ctx.win.chooser) |ch| return ch.finish(1);
    ctx.win.closeTab();
}
fn quitAll(ctx: Ctx) void {
    const app = ctx.win.app;
    var i = app.windows.items.len;
    while (i > 0) {
        i -= 1;
        app.windows.items[i].close();
    }
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) return s[1 .. s.len - 1];
    return s;
}

// Completion -----------------------------------------------------------------------------------

pub const Completion = struct { completed: []const u8, candidates: []const []const u8 };

/// Completes the command line: a command's name, then its argument
/// (folders, paths, options, sort keys). Shell lines complete paths.
pub fn complete(win: *Window, a: Allocator, text: []const u8, shell_line: bool) !Completion {
    const sp = std.mem.lastIndexOfScalar(u8, text, ' ');
    if (sp == null and !shell_line) {
        var cands: std.ArrayList([]const u8) = .empty;
        for (list) |cmd| if (std.mem.startsWith(u8, cmd.name, text)) try cands.append(a, cmd.name);
        if (win.app.lua) |l| try l.commandNames(a, text, &cands);
        return finish(a, "", text, cands.items, true);
    }
    const head = if (sp) |i| text[0 .. i + 1] else "";
    const word = if (sp) |i| text[i + 1 ..] else text;
    const name = text[0 .. std.mem.indexOfScalar(u8, text, ' ') orelse text.len];
    const kind: Complete = if (shell_line) .path else if (find_(name)) |cmd| cmd.complete else .path;
    var cands: std.ArrayList([]const u8) = .empty;
    switch (kind) {
        .option => for (Config.infos) |i| if (std.mem.startsWith(u8, i.name, word)) try cands.append(a, i.name),
        .sort => for ([_][]const u8{ "name", "size", "modified", "type", "extension" }) |s| if (std.mem.startsWith(u8, s, word)) try cands.append(a, s),
        .command, .none, .path, .dir => try pathCandidates(win, a, word, kind == .dir, &cands),
    }
    return finish(a, head, word, cands.items, kind != .path and kind != .dir);
}

fn finish(a: Allocator, head: []const u8, word: []const u8, cands: []const []const u8, add_space: bool) !Completion {
    if (cands.len == 0) return .{ .completed = try std.fmt.allocPrint(a, "{s}{s}", .{ head, word }), .candidates = cands };
    // The longest common prefix.
    var prefix = cands[0];
    for (cands[1..]) |cand| {
        var k: usize = 0;
        while (k < prefix.len and k < cand.len and prefix[k] == cand[k]) k += 1;
        prefix = prefix[0..k];
    }
    const full = cands.len == 1 and add_space;
    const completed = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ head, if (prefix.len >= word.len) prefix else word, if (full) " " else "" });
    return .{ .completed = completed, .candidates = cands };
}

/// Completes a path by itself (a chooser's path field), as :cd's
/// argument completes.
pub fn completePath(win: *Window, a: Allocator, word: []const u8, dirs_only: bool) !Completion {
    var cands: std.ArrayList([]const u8) = .empty;
    try pathCandidates(win, a, word, dirs_only, &cands);
    return finish(a, "", word, cands.items, false);
}

fn pathCandidates(win: *Window, a: Allocator, word: []const u8, dirs_only: bool, cands: *std.ArrayList([]const u8)) !void {
    // Split into the folder typed so far and the name being completed.
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |i| word[0 .. i + 1] else "";
    const name_part = if (slash) |i| word[i + 1 ..] else word;
    var ebuf: [linux.PATH_MAX]u8 = undefined;
    const dir = if (dir_part.len == 0) win.curDir().path else win.expandPath(&ebuf, dir_part);
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{dir}, 0) catch return;
    var it = fsops.DirIter.open(z) catch return;
    defer it.close();
    var names: std.ArrayList([]const u8) = .empty;
    while (it.next()) |nm| {
        if (!std.mem.startsWith(u8, nm, name_part)) continue;
        if (nm.len > 0 and nm[0] == '.' and (name_part.len == 0 or name_part[0] != '.')) continue;
        var pb: [linux.PATH_MAX]u8 = undefined;
        const full = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, nm }) catch continue;
        const is_dir = Window.isDirPath(full);
        if (dirs_only and !is_dir) continue;
        try names.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir_part, nm, if (is_dir) "/" else "" }));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return model.naturalOrder(x, y) == .lt;
        }
    }.lt);
    try cands.appendSlice(a, names.items);
}
