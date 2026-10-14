//! The file manager on siv's headless backend, driven like a user through
//! siv's public test API, with golden images of its main views.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const h_mod = @import("harness.zig");
const Harness = h_mod.Harness;
const Fixture = h_mod.Fixture;
const App = h_mod.App;
const png = @import("png.zig");

const testing = std.testing;

test {
    _ = @import("services.zig");
}

const zig_source =
    \\const std = @import("std");
    \\
    \\/// Adds two numbers.
    \\pub fn add(a: u32, b: u32) u32 {
    \\    return a + b; // no overflow check
    \\}
    \\
    \\test "add" {
    \\    try std.testing.expectEqual(@as(u32, 5), add(2, 3));
    \\}
    \\
;

/// A home with a few folders beside "work", which tests start in.
fn fixture(f: *Fixture, name: []const u8) !void {
    try f.create(name, &.{
        .{ .name = "Desktop", .dir = true },
        .{ .name = "Documents", .dir = true },
        .{ .name = "Music", .dir = true },
        .{ .name = "work", .dir = true },
        .{ .name = "notes.txt", .size = 1200 },
    });
    const items = [_]Fixture.Item{
        .{ .name = "work/assets", .dir = true },
        .{ .name = "work/src", .dir = true },
        .{ .name = "work/docs", .dir = true },
        .{ .name = "work/build.zig", .size = 2048 },
        .{ .name = "work/README.md", .size = 4200, .mtime = 1_790_000_000 },
        .{ .name = "work/report.pdf", .size = 2_400_000 },
        .{ .name = "work/photo.png", .size = 300_000 },
        .{ .name = "work/backup.tar.gz", .size = 52_000 },
        .{ .name = "work/run.sh", .size = 80, .mode = 0o755 },
        .{ .name = "work/a-very-long-file-name-that-does-not-fit-in-its-column.txt", .size = 10 },
        .{ .name = "work/.hidden", .size = 5 },
        .{ .name = "work/src/main.zig", .size = 0 },
        .{ .name = "work/src/App.zig", .size = 300 },
        .{ .name = "work/src/util", .dir = true },
        .{ .name = "work/docs/guide.md", .size = 900 },
    };
    for (items) |it| try f.add(it);
    try f.writeFile("work/src/main.zig", zig_source);
    try f.writeFile("work/README.md", "# Work\n\nNotes about **the project**, with `code` and a [link](https://example.org).\n\n- one\n- two\n");
    // Adding children changed the folders' times: set them again.
    for ([_][]const u8{ "work/assets", "work/src", "work/docs", "work/src/util", "Desktop", "Documents", "Music", "work" }) |d| try f.touch(d, 1_791_900_300);
    try f.touch("work/src/main.zig", 1_791_900_300);
    try f.touch("work/README.md", 1_790_000_000);
}

var path_buf: [512]u8 = undefined;

test "three columns: the parent, the folder, and a preview" {
    var f: Fixture = .{};
    try fixture(&f, "columns");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // Folders first, by name; the cursor on the first.
    try testing.expectEqualStrings("assets", h.hovered());
    _ = try h.expect(.list, "Files");
    _ = try h.expect(.list, "Parent folder");
    // The parent column's cursor is on the folder shown.
    try testing.expectEqualStrings("work", h.win.?.parent_col.dir.?.nameAt(h.win.?.parent_col.dir.?.cursor).?);
    // Down to src: its entries in the preview.
    try h.typeText("j");
    try testing.expectEqualStrings("docs", h.hovered());
    try h.typeText("j");
    try testing.expectEqualStrings("src", h.hovered());
    try testing.expectEqual(App.Window.PreviewMode.dir, h.win.?.preview.applied);
    // Into src, onto main.zig: its text, colored.
    try h.typeText("ljj");
    try testing.expectEqualStrings("main.zig", h.hovered());
    try testing.expectEqual(App.Window.PreviewMode.text, h.win.?.preview.applied);
    try h.expectGolden(h.window(), "columns-light");
}

test "keys: counts, gg and G, search, find, and history" {
    var f: Fixture = .{};
    try fixture(&f, "keys");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // assets docs src a-very… backup.tar.gz build.zig photo.png README.md report.pdf run.sh
    try h.typeText("G");
    try testing.expectEqualStrings("run.sh", h.hovered());
    try h.typeText("gg");
    try testing.expectEqualStrings("assets", h.hovered());
    try h.typeText("3j");
    try testing.expectEqualStrings("a-very-long-file-name-that-does-not-fit-in-its-column.txt", h.hovered());
    try h.typeText("2k");
    try testing.expectEqualStrings("docs", h.hovered());
    // 5G goes to the fifth entry.
    try h.typeText("5G");
    try testing.expectEqualStrings("backup.tar.gz", h.hovered());
    // / searches as you type, n and N repeat it, wrapping.
    try h.typeText("/rep\n");
    try testing.expectEqualStrings("report.pdf", h.hovered());
    try h.typeText("/s\n");
    try testing.expectEqualStrings("run.sh", h.hovered());
    try h.typeText("n");
    try testing.expectEqualStrings("assets", h.hovered());
    try h.typeText("N");
    try testing.expectEqualStrings("run.sh", h.hovered());
    // Escape in a search goes back where it started.
    try h.typeText("/bui");
    try testing.expectEqualStrings("build.zig", h.hovered());
    try h.typeText("\x1b");
    try testing.expectEqualStrings("run.sh", h.hovered());
    try testing.expect(h.win.?.prompt == null);
    // f jumps to the only match without Enter.
    try h.typeText("fph");
    try testing.expectEqualStrings("photo.png", h.hovered());
    try testing.expect(h.win.?.prompt == null);
    // Without find_auto_accept, Enter closes it.
    h.app.?.options.find_auto_accept = false;
    try h.typeText("fRE");
    try testing.expectEqualStrings("README.md", h.hovered());
    try testing.expect(h.win.?.prompt != null);
    try h.typeText("\n");
    try testing.expect(h.win.?.prompt == null);
    h.app.?.options.find_auto_accept = true;
    // l enters a folder, h comes back with the cursor on it, H and L
    // walk the history.
    try h.typeText("ggjjl");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    try h.typeText("h");
    try testing.expectEqualStrings("work", model.basename(h.dir().path));
    try testing.expectEqualStrings("src", h.hovered());
    try h.typeText("H");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    try h.typeText("L");
    try testing.expectEqualStrings("work", model.basename(h.dir().path));
    // Half pages, and the cursor stays in bounds.
    try h.typeText("gg");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try testing.expectEqualStrings("run.sh", h.hovered());
}

const model = App.model;

test "zf filters the folder as you type, in smart case, apart from / search" {
    var f: Fixture = .{};
    try fixture(&f, "filter");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    const all = h.dir().count();
    try h.typeText("zfre");
    try testing.expectEqual(@as(u32, 2), h.dir().count());
    try testing.expectEqualStrings("README.md", h.hovered());
    try h.expectGolden(h.window(), "filter");
    // A capital letter matches its case only.
    try h.key(.backspace, .{}, "");
    try h.key(.backspace, .{}, "");
    try h.typeText("RE");
    try testing.expectEqual(@as(u32, 1), h.dir().count());
    // Enter keeps the filter; keys work on what it shows.
    try h.typeText("\n");
    try testing.expect(h.win.?.prompt == null);
    try testing.expect(h.reads("filter: RE   1/1"));
    // Search looks in what the filter shows.
    try h.typeText("/run\n");
    try testing.expectEqualStrings("No match", h.win.?.message.items);
    // Escape clears it.
    try h.typeText("\x1b");
    try testing.expectEqual(all, h.dir().count());
    try h.typeText("/run\n");
    try testing.expectEqualStrings("run.sh", h.hovered());
    // Escape in the prompt cancels it, back to every entry.
    try h.typeText("zfzzz");
    try testing.expectEqual(@as(u32, 0), h.dir().count());
    try h.typeText("\x1b");
    try testing.expectEqual(all, h.dir().count());
    try testing.expectEqualStrings("run.sh", h.hovered());
}

fn countIn(f: *const Fixture, rel: []const u8) usize {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, rel }, 0) catch return 0;
    var it = App.fsops.DirIter.open(p) catch return 0;
    defer it.close();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn modeOf(f: *const Fixture, rel: []const u8) u32 {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, rel }, 0) catch return 0;
    var st: std.os.linux.Statx = undefined;
    if (std.os.linux.statx(std.os.linux.AT.FDCWD, p, 0, .{ .MODE = true }, &st) != 0) return 0;
    return st.mode & 0o7777;
}

fn opsDone(x: *Harness) bool {
    return x.app.?.ops.items.len == 0;
}

test "chmod and chown on the targets, into folders with -R" {
    var f: Fixture = .{};
    try fixture(&f, "perms");
    defer f.remove();
    try f.add(.{ .name = "work/assets/logo.svg", .size = 10 });
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    try testing.expectEqual(@as(u32, 0o644), modeOf(&f, "work/build.zig"));
    // = opens the command line with chmod.
    try h.typeText("fbu=");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("chmod ", h.win.?.promptText(&buf));
    try h.typeText("u+x,go-r\n");
    try h.waitFor(&h, opsDone);
    try testing.expectEqual(@as(u32, 0o700), modeOf(&f, "work/build.zig"));
    try testing.expectEqualStrings("Changed the permissions of “build.zig”", h.win.?.message.items);
    // Marked entries, into folders.
    try h.typeText(" gg :chmod -R a-w\n");
    try h.waitFor(&h, opsDone);
    try testing.expectEqual(@as(u32, 0o555), modeOf(&f, "work/assets"));
    try testing.expectEqual(@as(u32, 0o444), modeOf(&f, "work/assets/logo.svg"));
    try testing.expectEqual(@as(u32, 0o500), modeOf(&f, "work/build.zig"));
    try testing.expectEqualStrings("Changed the permissions of 3 items", h.win.?.message.items);
    try h.typeText("gg:chmod -R u+w\n");
    try h.waitFor(&h, opsDone);
    try testing.expectEqual(@as(u32, 0o755), modeOf(&f, "work/assets"));
    try h.typeText(":chmod u+q\n");
    try testing.expect(h.win.?.message_error);
    try testing.expect(std.mem.startsWith(u8, h.win.?.message.items, "Not a mode: u+q"));
    // chown: to oneself works; to root needs root.
    const uid = std.os.linux.getuid();
    var cmd: [64]u8 = undefined;
    try h.typeText(try std.fmt.bufPrint(&cmd, ":chown {d}:{d}\n", .{ uid, std.os.linux.getgid() }));
    try h.waitFor(&h, opsDone);
    try testing.expectEqualStrings("Changed the owner of “assets”", h.win.?.message.items);
    try h.typeText(":chown nosuchuser\n");
    try testing.expectEqualStrings("No such user: nosuchuser", h.win.?.message.items);
    if (uid != 0) {
        try h.typeText(":chown 0\n");
        try h.waitFor(&h, opsDone);
        try testing.expectEqualStrings("Could not change the owner of “assets”: Permission denied", h.win.?.message.items);
    }
}

test "marks, visual selection, copy, cut, paste, trash, undo, delete" {
    var f: Fixture = .{};
    try fixture(&f, "ops");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // Space marks and moves down: build.zig and photo.png.
    try h.typeText("fbu");
    try h.typeText("  ");
    try testing.expectEqual(@as(u32, 2), h.dir().mark_count);
    try testing.expectEqualStrings("README.md", h.hovered());
    _ = try h.expect(.image, "marked");
    // yy copies the marks; into docs, p pastes them.
    try h.typeText("yy");
    try testing.expectEqual(@as(u32, 0), h.dir().mark_count);
    try testing.expectEqual(@as(usize, 2), h.app.?.register.items.len);
    try h.typeText("ggjl");
    try testing.expectEqualStrings("docs", model.basename(h.dir().path));
    try h.typeText("p");
    try testing.expect(f.exists("work/docs/build.zig"));
    try testing.expect(f.exists("work/docs/photo.png"));
    try testing.expect(f.exists("work/build.zig"));
    // Visual selection: v and one down marks guide.md and photo.png; d
    // cuts the range.
    try h.typeText("ggjvj");
    try testing.expectEqual(App.keys.Mode.visual, h.win.?.mode);
    {
        const t = try h.win.?.targets();
        defer App.freePaths(testing.allocator, t);
        try testing.expectEqual(@as(usize, 2), t.len);
    }
    try h.expectGolden(h.window(), "visual");
    try h.typeText("d");
    try testing.expectEqual(App.keys.Mode.normal, h.win.?.mode);
    try testing.expect(h.app.?.register_cut);
    // Pasted in the parent: photo.png is there already. Two items move,
    // so a dialog compares the two files; a ticks "for every conflict",
    // k keeps both.
    try h.typeText("h");
    try siv.check(c.siv_test_type(h.window(), "p", 1));
    const Asking = struct {
        fn check(w: *App.Window) bool {
            return w.dialogs.isOpen() and w.dialogs.kind == .conflict;
        }
    };
    try h.dispatchUntil(h.win.?, Asking.check);
    try h.expectGolden(h.window(), "conflict");
    try testing.expect(h.reads("Do the same for every conflict"));
    try h.typeText("ak");
    try testing.expect(!h.win.?.dialogs.isOpen());
    try testing.expect(f.exists("work/guide.md"));
    try testing.expect(f.exists("work/photo (2).png"));
    try testing.expect(!f.exists("work/docs/guide.md"));
    try testing.expectEqual(@as(usize, 1), countIn(&f, "work/docs"));
    // dT trashes; u restores.
    try h.typeText("fgu");
    try h.typeText("dT");
    try testing.expect(!f.exists("work/guide.md"));
    try testing.expect(f.exists(".local/share/Trash/files/guide.md"));
    try h.typeText("u");
    try testing.expect(f.exists("work/guide.md"));
    // dD asks in a dialog; c (or Escape) keeps it, d deletes it, and the
    // keys go to the dialog, not the columns behind it.
    try h.typeText("fgu");
    try h.typeText("dD");
    try testing.expect(h.win.?.dialogs.isOpen() and h.win.?.dialogs.kind == .delete);
    try h.expectGolden(h.window(), "confirm-delete");
    try h.typeText("jc");
    try testing.expect(!h.win.?.dialogs.isOpen());
    try testing.expectEqualStrings("Not deleted", h.win.?.message.items);
    try testing.expectEqualStrings("guide.md", h.hovered());
    try testing.expect(f.exists("work/guide.md"));
    try h.typeText("dD\x1b");
    try testing.expect(f.exists("work/guide.md"));
    try h.typeText("dDd");
    try testing.expect(!f.exists("work/guide.md"));
}

test "rename, create, and bulk rename in an editor" {
    var f: Fixture = .{};
    try fixture(&f, "rename");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // r selects the name without its extension: typing replaces it.
    try h.typeText("fbu");
    try h.typeText("r");
    try testing.expectEqual(App.Window.PromptKind.rename, h.win.?.prompt.?);
    try h.expectGolden(h.window(), "rename");
    try h.typeText("make\n");
    try testing.expect(f.exists("work/make.zig"));
    try testing.expectEqualStrings("make.zig", h.hovered());
    // u undoes it.
    try h.typeText("u");
    try testing.expect(f.exists("work/build.zig"));
    // a makes a file, or a folder with a trailing slash.
    try h.typeText("anew.txt\n");
    try testing.expect(f.exists("work/new.txt"));
    try testing.expectEqualStrings("new.txt", h.hovered());
    try h.typeText("adeep/er/\n");
    try testing.expect(f.exists("work/deep/er"));
    // Bulk rename: the editor gets the names and rewrites them.
    h.app.?.options.editor = "sed -i s/^re/RE/";
    h.app.?.options.editor_in_terminal = false;
    try h.typeText("frep");
    try h.typeText(" kk ");
    try testing.expectEqual(@as(u32, 2), h.dir().mark_count);
    try h.typeText("R");
    const Cond = struct {
        fn done(ff: *const Fixture) bool {
            return ff.exists("work/REport.pdf");
        }
    };
    try h.waitFor(&f, Cond.done);
    try testing.expect(f.exists("work/REport.pdf"));
    try testing.expect(f.exists("work/README.md"));
}

test "the which-key popup, the command line, and completion" {
    var f: Fixture = .{};
    try fixture(&f, "keyhints");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    try h.typeText("g");
    try testing.expect(h.win.?.isWhichKeyShown());
    _ = try h.expect(.label, "Home");
    try h.expectGolden(h.window(), "which-key");
    try h.typeText("\x1b");
    try testing.expect(!h.win.?.isWhichKeyShown());
    // :set with Tab completion.
    try h.typeText(":set\t");
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("set ", h.win.?.promptText(&buf));
    try h.typeText("hid\t");
    try testing.expectEqualStrings("set hidden ", h.win.?.promptText(&buf));
    try h.typeText("\n");
    try testing.expect(h.app.?.options.show_hidden);
    try testing.expect(h.dir().indexOf(".hidden") != null);
    // Paths complete too.
    try h.typeText(":cd ../Mu\t");
    try testing.expectEqualStrings("cd ../Music/", h.win.?.promptText(&buf));
    try h.expectGolden(h.window(), "command-line");
    try h.typeText("\n");
    try testing.expectEqualStrings("Music", model.basename(h.dir().path));
    // Up recalls the history.
    try h.typeText(":");
    try h.key(.up, .{}, "");
    try testing.expectEqualStrings("cd ../Music/", h.win.?.promptText(&buf));
    try h.typeText("\x1b");
    // Unknown commands say so.
    try h.typeText(":frobnicate\n");
    try testing.expectEqualStrings("Unknown command: frobnicate", h.win.?.message.items);
    // Paths the cache does not know are looked at on a worker: a file
    // goes to its folder with the cursor on it; nothing says so.
    try h.typeText(":cd ../work/README.md\n");
    try testing.expectEqualStrings("README.md", h.hovered());
    try h.typeText(":cd nowhere\n");
    try testing.expect(std.mem.endsWith(u8, h.win.?.message.items, "/work/nowhere"));
}

test "messages stay until the next key, and :messages lists them" {
    var f: Fixture = .{};
    try fixture(&f, "messages");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // An error stays in the status line, however long nothing happens.
    try h.typeText("/zzz\n");
    try testing.expect(h.win.?.message_error);
    for (0..20) |_| try siv.check(c.siv_app_dispatch(h.sapp, 10));
    try h.settle();
    try testing.expect(h.reads("No match"));
    try h.expectGolden(h.window(), "status-error");
    // The next key clears it, whatever the key does.
    try h.typeText("j");
    try testing.expect(!h.reads("No match"));
    try h.typeText("p");
    try testing.expect(h.reads("Nothing to paste"));
    try h.typeText(":frobnicate\n");
    try testing.expect(!h.reads("Nothing to paste"));
    // Every one is kept, newest first, the errors in the error color.
    const log = h.app.?.messages.items;
    try testing.expectEqual(@as(usize, 3), log.len);
    for (log, 0..) |*m, i| m.time = 9 * 3600 + 41 * 60 + @as(i64, @intCast(i)) * 7;
    try h.typeText(":messages\n");
    try h.expectGolden(h.window(), "messages");
    // Listing them is not a message.
    try testing.expectEqual(@as(usize, 3), h.app.?.messages.items.len);
}

test "tabs, bookmarks, sorting, and hidden files" {
    var f: Fixture = .{};
    try fixture(&f, "tabs");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    try h.typeText("ma");
    try h.typeText("gn");
    try testing.expectEqual(@as(usize, 2), h.win.?.tabs.items.len);
    try h.typeText("ggjjl");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    try h.expectGolden(h.window(), "tabs");
    try h.typeText("gt");
    try testing.expectEqual(@as(usize, 0), h.win.?.active);
    try testing.expectEqualStrings("work", model.basename(h.dir().path));
    try h.key(@enumFromInt('2'), .{ .alt = true }, "2");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    // ' and the key goes to the bookmark; '' back.
    try h.typeText("'");
    try testing.expect(h.win.?.isWhichKeyShown());
    try h.typeText("a");
    try testing.expectEqualStrings("work", model.basename(h.dir().path));
    try h.typeText("''");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    try h.typeText("gq");
    try testing.expectEqual(@as(usize, 1), h.win.?.tabs.items.len);
    // Sorting: by size, largest first, folders still first.
    try h.typeText("sS");
    try testing.expectEqual(App.model.SortKey.size, h.app.?.options.sort.key);
    try h.typeText("gg3j");
    try testing.expectEqualStrings("report.pdf", h.hovered());
    try h.typeText("sn");
    // zh shows hidden files; the cursor stays on its entry.
    try h.typeText("zh");
    try testing.expect(h.dir().indexOf(".hidden") != null);
    try testing.expectEqualStrings("report.pdf", h.hovered());
    try h.typeText("zh");
    try testing.expect(h.dir().indexOf(".hidden") == null);
}

extern "c" fn system(cmd: [*:0]const u8) c_int;

/// A minimal one-page PDF with a filled rectangle, offsets computed.
fn writePdf(f: *Fixture, rel: []const u8) !void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var offs: [5]usize = undefined;
    try w.writeAll("%PDF-1.4\n");
    const objs = [_][]const u8{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 260] /Contents 4 0 R >>",
    };
    for (objs, 1..) |o, i| {
        offs[i] = w.end;
        try w.print("{d} 0 obj\n{s}\nendobj\n", .{ i, o });
    }
    const content = "0.2 0.4 0.8 rg 20 20 160 220 re f";
    offs[4] = w.end;
    try w.print("4 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ content.len, content });
    const xref = w.end;
    try w.writeAll("xref\n0 5\n0000000000 65535 f \n");
    for (offs[1..5]) |o| try w.print("{d:0>10} 00000 n \n", .{o});
    try w.print("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{d}\n%%EOF\n", .{xref});
    try f.writeFile(rel, w.buffered());
}

test "previews: images at the size shown, archives, PDFs, text, binary files" {
    var f: Fixture = .{};
    try fixture(&f, "previews");
    defer f.remove();
    // A real PNG: a 160×120 gradient.
    {
        const gpa = testing.allocator;
        const px = try gpa.alloc(u8, 160 * 120 * 4);
        defer gpa.free(px);
        for (0..120) |y| for (0..160) |x| {
            const p = px[(y * 160 + x) * 4 ..][0..4];
            p.* = .{ @intCast(x * 255 / 159), @intCast(y * 255 / 119), 180, 255 };
        };
        const enc = try png.encode(gpa, 160, 120, px);
        defer gpa.free(enc);
        try f.writeFile("work/photo.png", enc);
        try f.touch("work/photo.png", 1_791_900_300);
    }
    // A tarball made by tar.
    var cmd: [512]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&cmd, "cd '{s}/work' && mkdir -p pkg/lib && printf 'hello' > pkg/lib/a.txt && printf 'x' > pkg/b.txt && tar --mtime=@1791900300 --owner=0 --group=0 --numeric-owner --sort=name -cf - pkg | gzip -n > backup.tar.gz && rm -rf pkg", .{f.path}, 0);
    try testing.expectEqual(@as(c_int, 0), system(z.ptr));
    try writePdf(&f, "work/report.pdf");
    try f.writeFile("work/data.bin", "\x00\x01\x02binary\x00");
    for ([_][]const u8{ "work/backup.tar.gz", "work/report.pdf", "work/data.bin" }) |n| try f.touch(n, 1_791_900_300);
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    const p = &h.win.?.preview;
    try h.typeText("fph");
    try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
    _ = try h.expect(.image, "Image preview");
    try h.expectGolden(h.window(), "preview-image");
    try h.typeText("fba");
    try testing.expectEqual(App.Window.PreviewMode.text, p.applied);
    try testing.expectEqual(@TypeOf(p.text_kind).archive, p.text_kind);
    {
        var tb: [256]u8 = undefined;
        const t = App.ui.getText(p.text, &tb);
        try testing.expect(std.mem.indexOf(u8, t, "pkg/lib/a.txt  5 bytes\n") != null);
        try testing.expect(std.mem.indexOf(u8, t, "pkg/b.txt  1 byte\n") != null);
    }
    try h.expectGolden(h.window(), "preview-archive");
    // Binary files: their start in hex.
    try h.typeText("fda");
    try testing.expectEqual(App.Window.PreviewMode.text, p.applied);
    try testing.expectEqual(@TypeOf(p.text_kind).binary, p.text_kind);
    {
        var tb: [256]u8 = undefined;
        try testing.expectEqualStrings("Binary file, 10 bytes\n\n00000000  00 01 02 62 69 6e 61 72  79 00                    |...binary.|\n", App.ui.getText(p.text, &tb));
    }
    try h.expectGolden(h.window(), "preview-hex");
    // Images past the size limit show their details.
    try h.typeText(":set preview_max_image_bytes 500\nfph");
    try testing.expectEqual(App.Window.PreviewMode.info, p.applied);
    {
        var tb: [512]u8 = undefined;
        try testing.expect(std.mem.endsWith(u8, App.ui.getText(p.info_body, &tb), "Too large to preview (preview_max_image_bytes)"));
    }
    try h.typeText(":set preview_max_image_bytes 67108864\n");
    try h.typeText("fR");
    try testing.expectEqual(App.Window.PreviewMode.text, p.applied);
    if (App.Window.isPath("/usr/bin/pdftoppm")) {
        try h.typeText("frep");
        if (p.applied != .image) {
            var tb: [256]u8 = undefined;
            std.debug.print("pdf preview: {s}\n", .{App.ui.getText(p.info_body, &tb)});
        }
        try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
        try h.expectGolden(h.window(), "preview-pdf");
    }
    // Moving on quickly: every preview but the last is dropped.
    try siv.check(c.siv_test_type(h.window(), "ggjjjjjjjjk", 11));
    try h.settle();
    try testing.expectEqualStrings("photo.png", h.hovered());
    try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
}

test "*.ts: TypeScript shows as highlighted source, a transport stream as video" {
    var f: Fixture = .{};
    try fixture(&f, "typescript");
    defer f.remove();
    // The test database lists *.ts as Linguist and MPEG-TS at weight 50,
    // and TypeScript at 40, as shared-mime-info 2.5 does.
    try f.writeFile("work/app.ts", "import { readFile } from \"node:fs/promises\";\n\n/** Reads a config. */\nexport async function load(path: string): Promise<number> {\n    const text = await readFile(path, \"utf8\");\n    return text.length; // bytes, roughly\n}\n");
    var stream: [188 * 5]u8 = @splat(0xff);
    for (0..5) |k| stream[k * 188] = 0x47;
    try f.writeFile("work/clip.ts", &stream);
    for ([_][]const u8{ "work/app.ts", "work/clip.ts" }) |n| try f.touch(n, 1_791_900_300);
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    const db = h.app.?.mimeDb().?;
    const p = &h.win.?.preview;
    try h.typeText("fap");
    try testing.expectEqualStrings("app.ts", h.hovered());
    try testing.expectEqualStrings("application/typescript", db.name(h.dir().entryAt(h.dir().cursor).?.mime));
    try testing.expectEqual(App.Window.PreviewMode.text, p.applied);
    try testing.expectEqual(@TypeOf(p.text_kind).text, p.text_kind);
    try h.expectGolden(h.window(), "preview-typescript");
    try h.typeText("fcl");
    try testing.expectEqualStrings("clip.ts", h.hovered());
    try testing.expectEqualStrings("video/mp2t", db.name(h.dir().entryAt(h.dir().cursor).?.mime));
    try testing.expect(p.applied != .text);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn infoText(h: *Harness, buf: []u8) []const u8 {
    return App.ui.getText(h.win.?.preview.info_body, buf);
}

test "previews without poppler, of videos, and of links; slow previewers never hold the keys" {
    var f: Fixture = .{};
    try fixture(&f, "fallbacks");
    defer f.remove();
    try writePdf(&f, "work/report.pdf");
    for ([_][]const u8{ "work/clip1.mp4", "work/clip2.mp4", "work/clip3.mp4" }) |n| try f.writeFile(n, "not really a video");
    try f.add(.{ .name = "work/slow", .dir = true });
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |n| {
        var nb: [64]u8 = undefined;
        try f.writeFile(try std.fmt.bufPrint(&nb, "work/slow/{s}.slow", .{n}), "x");
    }
    {
        const gpa = testing.allocator;
        const px = try gpa.alloc(u8, 32 * 24 * 4);
        defer gpa.free(px);
        @memset(px, 200);
        const enc = try png.encode(gpa, 32, 24, px);
        defer gpa.free(enc);
        try f.writeFile("frame.png", enc);
    }
    // Stand-ins for the renderers: each copies frame.png where it was
    // told to write.
    var cmd: [1024]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(&cmd,
        \\cd '{s}' && mkdir -p bin && ln -s nowhere work/dangling &&
        \\printf '#!/bin/sh\n/bin/cp "{s}/frame.png" "$4"\n' > bin/mutool &&
        \\printf '#!/bin/sh\n/bin/cp "{s}/frame.png" "$4"\n' > bin/ffmpegthumbnailer &&
        \\printf '#!/bin/sh\nfor a; do last=$a; done\n/bin/cp "{s}/frame.png" "$last"\n' > bin/ffmpeg.off &&
        \\chmod +x bin/*
    , .{ f.path, f.path, f.path, f.path }, 0);
    try testing.expectEqual(@as(c_int, 0), system(setup.ptr));
    const old_path = try testing.allocator.dupeSentinel(u8, std.mem.span(getenv("PATH") orelse "/usr/bin:/bin"), 0);
    defer testing.allocator.free(old_path);
    defer _ = setenv("PATH", old_path.ptr, 1);
    var bin_buf: [512]u8 = undefined;
    _ = setenv("PATH", (try std.fmt.bufPrintSentinel(&bin_buf, "{s}/bin", .{f.path}, 0)).ptr, 1);

    var cbuf: [512]u8 = undefined;
    try f.writeFile("init.lua", "local fm = require('fm')\nfm.previewer { name = '*.slow', cmd = { '/bin/sh', '-c', '/bin/sleep 30', '%s' } }\n");
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work"), .config = f.sub(&cbuf, "init.lua") });
    const p = &h.win.?.preview;
    var tb: [1024]u8 = undefined;
    // No pdftoppm: MuPDF renders the page.
    try h.typeText("frep");
    try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
    // A video: ffmpegthumbnailer, else ffmpeg, else a word on what to
    // install.
    try h.typeText("fclip1");
    try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
    try testing.expectEqual(@as(c_int, 0), system((try std.fmt.bufPrintSentinel(&cmd, "cd '{s}/bin' && /bin/rm mutool ffmpegthumbnailer && /bin/mv ffmpeg.off ffmpeg", .{f.path}, 0)).ptr));
    try h.typeText("fclip2");
    try testing.expectEqual(App.Window.PreviewMode.image, p.applied);
    try testing.expectEqual(@as(c_int, 0), system((try std.fmt.bufPrintSentinel(&cmd, "/bin/rm '{s}/bin/ffmpeg'", .{f.path}, 0)).ptr));
    try h.typeText("fclip3");
    try testing.expectEqual(App.Window.PreviewMode.info, p.applied);
    try testing.expect(std.mem.endsWith(u8, infoText(&h, &tb), "Install ffmpegthumbnailer or ffmpeg to preview videos"));
    // And a PDF with no renderer at all.
    try h.typeText("frep");
    try testing.expectEqual(App.Window.PreviewMode.info, p.applied);
    try testing.expect(std.mem.endsWith(u8, infoText(&h, &tb), "Install poppler (pdftoppm) or MuPDF (mutool) to preview PDFs"));
    // A link's details say where it goes (read in a job).
    try h.typeText("fdan");
    try testing.expectEqual(App.Window.PreviewMode.info, p.applied);
    try testing.expect(std.mem.indexOf(u8, infoText(&h, &tb), "Links to\tnowhere") != null);
    // Previewers that never finish: moving over six of them and on to a
    // folder kills each as the cursor leaves it, so settling (which waits
    // for every job) is quick and the keys never wait.
    try h.typeText("fsl");
    try siv.check(c.siv_test_type(h.window(), "l", 1));
    for (0..20) |_| try siv.check(c.siv_app_dispatch(h.sapp, 10));
    try testing.expect(p.job != null); // a.slow's previewer runs
    const t0 = App.Dir.now();
    try siv.check(c.siv_test_type(h.window(), "jjjjjgg", 7));
    try h.typeText("h");
    try testing.expectEqualStrings("slow", h.hovered());
    try testing.expect(App.Dir.now() - t0 < 5 * std.time.ns_per_s);
}

test "Lua: options, keys, commands, previewers, and siv from init.lua" {
    var f: Fixture = .{};
    try fixture(&f, "lua");
    defer f.remove();
    try f.writeFile("work/data.csv", "a,b\n1,2\n");
    try f.writeFile("init.lua",
        \\local fm = require("fm")
        \\fm.set { hidden = true, ratio = { 1, 2, 3 } }
        \\fm.opt.scroll_off = 1
        \\assert(fm.get("hidden") == true and fm.opt.scroll_off == 1)
        \\fm.map("n", "gw", "cd ~/work/src", "Sources")
        \\fm.map({ "n", "v" }, "X", function(count) fm.notify("count " .. tostring(count)) end, "Count")
        \\fm.command("hello", function(args, count) fm.notify("hello " .. args) end, "Greets")
        \\fm.previewer { name = "*.csv", run = function(path, mime) return "CSV: " .. path:match("[^/]*$") end }
        \\fm.unmap("n", "dD")
        \\fm.on("cd", function(path) entered = path end)
        \\-- siv's own binding, with the running application.
        \\local siv = require("siv")
        \\local app = fm.siv_app()
        \\assert(tostring(app):find("^siv.app"))
        \\fm.command("timer", function()
        \\  app:timer_start(0, function() fm.notify("timer fired") end)
        \\end)
        \\fm.command("where", function() fm.notify(fm.cwd() .. " " .. tostring(#fm.selected())) end)
        \\fm.command("boom", function() error("boom!") end)
    );
    var h: Harness = .{};
    defer h.deinit();
    var cbuf: [512]u8 = undefined;
    try h.start(.{ .path = f.sub(&path_buf, "work"), .config = f.sub(&cbuf, "init.lua") });
    const app = h.app.?;
    try testing.expect(app.options.show_hidden);
    try testing.expect(h.dir().indexOf(".hidden") != null);
    try testing.expectEqual(@as(f32, 2), app.options.ratio[1]);
    try h.typeText("3X");
    try testing.expectEqualStrings("count 3", h.win.?.message.items);
    try h.typeText(":hello world\n");
    try testing.expectEqualStrings("hello world", h.win.?.message.items);
    try h.typeText(":where\n");
    try testing.expect(std.mem.endsWith(u8, h.win.?.message.items, "/work 1"));
    try h.typeText(":timer\n");
    try testing.expectEqualStrings("timer fired", h.win.?.message.items);
    try h.typeText(":boom\n");
    try testing.expect(std.mem.indexOf(u8, h.win.?.message.items, "boom!") != null);
    try testing.expect(h.win.?.message_error);
    try h.typeText("fda");
    {
        var tb: [256]u8 = undefined;
        try testing.expectEqualStrings("CSV: data.csv", App.ui.getText(h.win.?.preview.text, &tb));
    }
    // dD is unbound: d then D mean nothing.
    try h.typeText("dD");
    try testing.expectEqual(App.Window.Await.none, h.win.?.await_key);
    try h.typeText("gw");
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    const L = app.lua.?.L;
    _ = App.Lua.lc.lua_getglobal(L, "entered");
    try testing.expect(std.mem.endsWith(u8, App.Lua.lh.toString(L, -1).?, "/work/src"));
    App.Lua.lh.pop(L, 1);
}

fn widthOf(n: siv.Node) f32 {
    var r: siv.Rect = .{};
    _ = c.siv_node_get_rect(n, &r);
    return r.width;
}

/// p, then `keys` as soon as the paste (which reads the clipboard
/// first) has started its copy.
fn pasteAndThen(h: *Harness, keys: []const u8) !void {
    try siv.check(c.siv_test_type(h.window(), "p", 1));
    var i: usize = 0;
    while (h.app.?.ops.items.len == 0) : (i += 1) {
        if (i > 2000) return error.Timeout;
        try siv.check(c.siv_app_dispatch(h.sapp, 1));
    }
    try siv.check(c.siv_test_type(h.window(), keys.ptr, keys.len));
    try dispatchFor(h, 100);
}

fn dispatchFor(h: *Harness, ms: usize) !void {
    for (0..ms / 10) |_| try siv.check(c.siv_app_dispatch(h.sapp, 10));
}

test "gf finds files below; gz and :z jump with zoxide, which hears of each folder" {
    var f: Fixture = .{};
    try fixture(&f, "picker");
    defer f.remove();
    // A stand-in zoxide: it logs what it is told and knows three folders.
    var cmd: [2048]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(&cmd,
        \\mkdir -p '{s}/bin' && cat > '{s}/bin/zoxide' <<'EOF'
        \\#!/bin/sh
        \\case "$1" in
        \\add) echo "$3" >> "{s}/zoxide.log" ;;
        \\query) if [ "$2" = "--list" ]; then printf '%s\n' "{s}/Music" "{s}/Documents" "{s}/work/docs"
        \\  else for a; do last=$a; done; case "$last" in doc*) echo "{s}/work/docs" ;; *) exit 1 ;; esac; fi ;;
        \\esac
        \\EOF
        \\chmod +x '{s}/bin/zoxide'
    , .{ f.path, f.path, f.path, f.path, f.path, f.path, f.path, f.path }, 0);
    try testing.expectEqual(@as(c_int, 0), system(setup.ptr));
    const old_path = try testing.allocator.dupeSentinel(u8, std.mem.span(getenv("PATH") orelse "/usr/bin:/bin"), 0);
    defer testing.allocator.free(old_path);
    defer _ = setenv("PATH", old_path.ptr, 1);
    var pbuf: [1024]u8 = undefined;
    _ = setenv("PATH", (try std.fmt.bufPrintSentinel(&pbuf, "{s}/bin:{s}", .{ f.path, old_path }, 0)).ptr, 1);

    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    const w = h.win.?;
    var tb: [256]u8 = undefined;
    // gf: everything below, best match first; Enter shows a file in its
    // folder.
    try h.typeText("gf");
    try testing.expectEqual(App.Window.PromptKind.pick, w.prompt.?);
    try testing.expect(h.reads("Find a file or folder"));
    try testing.expect(w.picker.paths.len() >= 12);
    try h.typeText("mainz");
    try testing.expectEqualStrings("src/main.zig", w.picker.paths.get(w.picker.matches.items[0].index));
    try h.typeText("\n");
    try testing.expect(w.prompt == null);
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    try testing.expectEqualStrings("main.zig", h.hovered());
    // A folder opens; Ctrl+N and Ctrl+P move; Esc leaves.
    try h.typeText("hgfutil");
    try testing.expectEqualStrings("src/util/", w.picker.chosen(&tb).?[w.picker.root.items.len + 1 ..]);
    try h.typeText("\n");
    try testing.expectEqualStrings("util", model.basename(h.dir().path));
    try h.typeText("hhgfzig");
    const second = w.picker.paths.get(w.picker.matches.items[1].index);
    var sbuf: [256]u8 = undefined;
    const want = sbuf[0..second.len];
    @memcpy(want, second);
    try h.key(@enumFromInt('n'), .{ .ctrl = true }, "\x0e");
    try h.key(@enumFromInt('n'), .{ .ctrl = true }, "\x0e");
    try h.key(@enumFromInt('p'), .{ .ctrl = true }, "\x10");
    try testing.expectEqual(@as(usize, 1), w.picker.selected);
    try h.expectGolden(h.window(), "picker");
    try h.typeText("\x1b");
    try testing.expect(w.prompt == null and !w.picker.open);
    // zoxide heard of every folder visited.
    var lb: [4096]u8 = undefined;
    const log = try readFile(&f, "zoxide.log", &lb);
    try testing.expect(std.mem.indexOf(u8, log, "/work/src\n") != null);
    try testing.expect(std.mem.indexOf(u8, log, "/work/src/util\n") != null);
    // gz: zoxide's folders, filtered as you type.
    try h.typeText("gz");
    try testing.expectEqual(@as(usize, 3), w.picker.paths.len());
    try h.typeText("mus\n");
    try testing.expectEqualStrings("Music", model.basename(h.dir().path));
    // :z words: zoxide's best folder for them.
    try h.typeText(":z doc\n");
    try testing.expectEqualStrings("docs", model.basename(h.dir().path));
    try h.typeText(":z nothing\n");
    try testing.expectEqualStrings("zoxide knows no folder for that", w.message.items);
}

fn readFile(f: *const Fixture, rel: []const u8, buf: []u8) ![]const u8 {
    var pb: [512]u8 = undefined;
    const p = try std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ f.path, rel }, 0);
    const rc = std.os.linux.openat(std.os.linux.AT.FDCWD, p, .{ .ACCMODE = .RDONLY }, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.FileNotFound;
    defer _ = std.os.linux.close(@intCast(rc));
    const n = std.os.linux.read(@intCast(rc), buf.ptr, buf.len);
    return buf[0..n];
}

test "the tasks view: progress, pause, resume, cancel, and finished tasks" {
    var f: Fixture = .{};
    try fixture(&f, "tasks");
    defer f.remove();
    var cmd: [512]u8 = undefined;
    // 256 MiB: 64 of the copy's 4 MiB chunks, so a pause lands mid-copy.
    try testing.expectEqual(@as(c_int, 0), system((try std.fmt.bufPrintSentinel(&cmd, "truncate -s 256M '{s}/work/big.bin'", .{f.path}, 0)).ptr));
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    const app = h.app.?;
    // Nothing yet.
    try h.typeText("w");
    try testing.expectEqual(App.keys.Mode.tasks, h.win.?.mode);
    try testing.expect(h.reads("No file operations yet"));
    try h.typeText("\x1b");
    try testing.expectEqual(App.keys.Mode.normal, h.win.?.mode);
    // Copy big.bin into docs, and pause it from the tasks view at once.
    try h.typeText("fbi");
    try h.typeText("yyfdocl");
    try pasteAndThen(&h, "wp");
    try testing.expectEqual(@as(usize, 1), app.ops.items.len);
    const op = app.ops.items[0].op;
    try testing.expect(op.isPaused());
    try testing.expect(h.reads("Copying “big.bin” to docs"));
    const at = op.done_bytes.load(.monotonic);
    try dispatchFor(&h, 300);
    try testing.expectEqual(at, op.done_bytes.load(.monotonic));
    try testing.expect(at < op.total_bytes.load(.monotonic));
    // Resume: it finishes, and stays listed as done.
    try h.typeText("p");
    try h.waitFor(&h, opsDone);
    try testing.expectEqual(@as(usize, 1), app.recent.items.len);
    try testing.expectEqualStrings("Copied “big.bin”", app.recent.items[0].result);
    // A second copy, cancelled from the view.
    try h.typeText("\x1bhfbiyyfasl");
    try pasteAndThen(&h, "wpx");
    try h.waitFor(&h, opsDone);
    try testing.expect(app.recent.items[0].canceled);
    try testing.expect(!f.exists("work/assets/big.bin"));
    try testing.expectEqual(App.keys.Mode.tasks, h.win.?.mode);
    try h.expectGolden(h.window(), "tasks");
    // x on a finished task takes it off the list; j and k move.
    try h.typeText("jx");
    try testing.expectEqual(@as(usize, 1), app.recent.items.len);
    try testing.expect(app.recent.items[0].canceled);
    try h.typeText("q");
    try testing.expectEqual(App.keys.Mode.normal, h.win.?.mode);
}

test "column widths: the ratio, the parent fitted to its names, narrow windows" {
    var f: Fixture = .{};
    try fixture(&f, "ratio");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work/src") });
    const w = h.win.?;
    // work's long name widens the parent from its share (1/8 of 1000) to
    // a quarter of the window; the current column keeps 3/8; the preview
    // gives up the rest.
    try testing.expectEqual(@as(f32, 250), widthOf(w.parent_box));
    try testing.expectEqual(@as(f32, 375), widthOf(w.current_box));
    try h.typeText(":set fit_parent false\n");
    // 1/8 of what the two 7 px handles leave.
    try testing.expectApproxEqAbs(@as(f32, 123.25), widthOf(w.parent_box), 0.5);
    try h.typeText(":set fit_parent true\n");
    // A parent whose names are short keeps its share or a little more.
    try h.typeText("h");
    try testing.expect(widthOf(w.parent_box) >= 125 and widthOf(w.parent_box) < 200);
    try h.typeText("l");
    // Narrow windows drop the parent, then the preview.
    try siv.check(c.siv_test_resize(h.window(), 600, 560));
    try h.settle();
    try testing.expect(!h.reads("Parent folder"));
    try testing.expect(h.reads("Preview"));
    try h.expectGolden(h.window(), "narrow");
    try siv.check(c.siv_test_resize(h.window(), 400, 560));
    try h.settle();
    try testing.expect(!h.reads("Preview"));
    try testing.expectEqual(@as(f32, 400), widthOf(w.current_box));
    try siv.check(c.siv_test_resize(h.window(), 1000, 560));
    try h.settle();
    try testing.expect(h.reads("Parent folder") and h.reads("Preview"));
    try testing.expectEqual(@as(f32, 250), widthOf(w.parent_box));
    // :set (and fm.set in init.lua) change the ratio and the breakpoint.
    try h.typeText(":set ratio 2,3,3\n:set narrow_width 1200\n");
    try testing.expect(!h.reads("Parent folder"));
    try testing.expectApproxEqAbs(@as(f32, 496.5), widthOf(w.current_box), 0.5);
}

/// Presses the primary button at a column handle's middle, moves by `dx`
/// in steps, and lets go.
fn dragHandle(h: *Harness, which: usize, dx: f32) !void {
    var r: siv.Rect = .{};
    _ = c.siv_node_get_rect(h.win.?.handles[which].node, &r);
    const x = r.x + r.width / 2;
    const y = r.y + 200;
    try siv.check(c.siv_test_pointer_move(h.window(), x, y));
    try h.settle();
    try siv.check(c.siv_test_pointer_button(h.window(), .primary, true));
    for (1..5) |k| try siv.check(c.siv_test_pointer_move(h.window(), x + dx * @as(f32, @floatFromInt(k)) / 4, y));
    try h.settle();
    try siv.check(c.siv_test_pointer_button(h.window(), .primary, false));
    try h.settle();
}

test "column handles: dragging, < and >, z= to reset, and widths kept across starts" {
    var f: Fixture = .{};
    try fixture(&f, "resize");
    defer f.remove();
    var lb: [256]u8 = undefined;
    {
        var h: Harness = .{};
        defer h.deinit();
        try h.start(.{ .path = f.sub(&path_buf, "work/src"), .state = true });
        const w = h.win.?;
        // Fitted: a quarter for work's long names, 3/8 for the current.
        try testing.expectEqual(@as(f32, 250), widthOf(w.parent_box));
        try testing.expectEqual(@as(f32, 375), widthOf(w.current_box));
        try h.expectGolden(h.window(), "handles");
        // The pointer over a handle lights its line.
        var r: siv.Rect = .{};
        _ = c.siv_node_get_rect(w.handles[1].node, &r);
        try siv.check(c.siv_test_pointer_move(h.window(), r.x + 3, 300));
        try h.settle();
        try testing.expectEqual(@as(f32, 2), widthOf(w.handles[1].line));
        // Dragging the first boundary 60 px right widens the parent; the
        // current column's far edge stays.
        try dragHandle(&h, 0, 60);
        try testing.expectApproxEqAbs(@as(f32, 310), widthOf(w.parent_box), 1);
        try testing.expectApproxEqAbs(@as(f32, 315), widthOf(w.current_box), 1);
        // Lit while the pointer stays over it, at rest once it leaves.
        try testing.expectEqual(@as(f32, 2), widthOf(w.handles[0].line));
        try siv.check(c.siv_test_pointer_move(h.window(), 900, 300));
        try h.settle();
        try testing.expectEqual(@as(f32, 1), widthOf(w.handles[0].line));
        // The second boundary takes from the preview.
        try dragHandle(&h, 1, -40);
        try testing.expectApproxEqAbs(@as(f32, 275), widthOf(w.current_box), 1);
        try testing.expectApproxEqAbs(@as(f32, 310), widthOf(w.parent_box), 1);
        // > and < by 32 px, with counts; a column keeps 80 px.
        try h.typeText(">");
        try testing.expectApproxEqAbs(@as(f32, 307), widthOf(w.current_box), 1);
        try h.typeText("2<");
        try testing.expectApproxEqAbs(@as(f32, 243), widthOf(w.current_box), 1);
        try h.typeText(":column-narrower parent\n");
        try testing.expectApproxEqAbs(@as(f32, 278), widthOf(w.parent_box), 1);
        try h.typeText("20<");
        try testing.expectApproxEqAbs(@as(f32, 80), widthOf(w.current_box), 1);
        try h.typeText("5>");
        try testing.expectApproxEqAbs(@as(f32, 240), widthOf(w.current_box), 1);
        // A narrow window still drops the parent, and the widths come back.
        try siv.check(c.siv_test_resize(h.window(), 600, 560));
        try h.settle();
        try testing.expect(!h.reads("Parent folder"));
        try siv.check(c.siv_test_resize(h.window(), 1000, 560));
        try h.settle();
        try testing.expectApproxEqAbs(@as(f32, 278), widthOf(w.parent_box), 1);
        try testing.expectEqualStrings("0.2780 0.2400\n", try readFile(&f, "work/.local/state/siv-columns/columns", &lb));
    }
    {
        // The next start keeps them; z= goes back to the ratio and
        // forgets them.
        var h: Harness = .{};
        defer h.deinit();
        try h.start(.{ .path = f.sub(&path_buf, "work/src"), .state = true });
        const w = h.win.?;
        try testing.expectApproxEqAbs(@as(f32, 278), widthOf(w.parent_box), 1);
        try testing.expectApproxEqAbs(@as(f32, 240), widthOf(w.current_box), 1);
        try h.typeText("z=");
        try testing.expectEqual(@as(f32, 250), widthOf(w.parent_box));
        try testing.expectEqual(@as(f32, 375), widthOf(w.current_box));
        try testing.expectError(error.FileNotFound, readFile(&f, "work/.local/state/siv-columns/columns", &lb));
    }
    {
        // Right to left, the parent is on the right: dragging its
        // boundary left widens it.
        var h: Harness = .{};
        defer h.deinit();
        try h.start(.{ .path = f.sub(&path_buf, "work/src"), .rtl = true });
        try dragHandle(&h, 0, -60);
        try testing.expectApproxEqAbs(@as(f32, 310), widthOf(h.win.?.parent_box), 1);
    }
}

/// Right-clicks node `n` of window `w` (the middle of its first 40 px).
fn rightClick(h: *Harness, w: siv.Window, n: siv.TestNode) !void {
    try h.click(w, n, .secondary);
}

/// Clicks the item named `name` in the newest popup.
fn choose(h: *Harness, name: []const u8) !void {
    const popup = h.popup();
    const item = h.find(popup, .{ .role = .menu_item, .name = name.ptr, .name_len = name.len }) orelse {
        h.dump(popup);
        return error.NotFound;
    };
    try h.click(popup, item, .primary);
}

fn menuHas(h: *Harness, name: []const u8) bool {
    return h.find(h.popup(), .{ .role = .menu_item, .name = name.ptr, .name_len = name.len }) != null;
}

test "context menus: entries, the selection, empty space, the Menu key, and init.lua's commands" {
    var f: Fixture = .{};
    try fixture(&f, "menus");
    defer f.remove();
    var cbuf: [512]u8 = undefined;
    try f.writeFile("init.lua", "local fm = require('fm')\nfm.command('hello', function() fm.notify('hi from init.lua') end, 'Say hello')\n");
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work"), .config = f.sub(&cbuf, "init.lua") });
    const app = h.app.?;
    // A right click on an entry moves the cursor there and lists what
    // applies to it, each with its keys.
    try rightClick(&h, h.window(), try h.expect(.list_item, "build.zig 2.0 K"));
    try testing.expectEqualStrings("build.zig", h.hovered());
    try testing.expect(menuHas(&h, "Open with…") and menuHas(&h, "Copy") and menuHas(&h, "Delete permanently…"));
    try h.expectGolden(h.popup(), "context-menu");
    try choose(&h, "Copy");
    try testing.expectEqual(@as(usize, 1), app.register.items.len);
    // On a marked entry it acts on every marked one; on another entry the
    // marks go, as in other file managers.
    try h.typeText("gg  ");
    try testing.expectEqual(@as(u32, 2), h.dir().mark_count);
    try rightClick(&h, h.window(), try h.expect(.list_item, "marked assets"));
    try testing.expect(menuHas(&h, "Copy the paths"));
    try choose(&h, "Copy");
    try testing.expectEqual(@as(usize, 2), app.register.items.len);
    try h.typeText("gg  ");
    try rightClick(&h, h.window(), try h.expect(.list_item, "README.md 97 B"));
    try testing.expectEqual(@as(u32, 0), h.dir().mark_count);
    try testing.expect(menuHas(&h, "Copy the path"));
    try h.key(.escape, .{}, "");
    // The empty space below the entries: the folder's menu, with check
    // items and a submenu.
    const files = try h.expect(.list, "Files");
    var below = files;
    below.bounds.y = files.bounds.y + files.bounds.height - 40;
    below.bounds.height = 20;
    try rightClick(&h, h.window(), below);
    try testing.expect(menuHas(&h, "New file or folder…") and menuHas(&h, "Sort by"));
    try choose(&h, "Hidden files");
    try testing.expect(app.options.show_hidden);
    // The Menu key opens it at the cursor; init.lua's commands are in a
    // submenu of their own.
    try h.key(.menu, .{}, "");
    try testing.expect(menuHas(&h, "From init.lua"));
    try choose(&h, "From init.lua");
    try choose(&h, "Say hello");
    try testing.expectEqualStrings("hi from init.lua", h.win.?.message.items);
}

test "the properties dialog: the mode typed or ticked, the owner, applied as operations" {
    var f: Fixture = .{};
    try fixture(&f, "props");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    try testing.expectEqual(@as(u32, 0o644), modeOf(&f, "work/build.zig"));
    try h.typeText("fbu");
    try h.key(.@"return", .{ .alt = true }, "");
    const d = &h.win.?.dialogs;
    try testing.expect(d.isOpen() and d.kind == .properties);
    // The owner is this machine's user: a fixed one for the image.
    var ob: [128]u8 = undefined;
    const owner = try testing.allocator.dupe(u8, App.ui.getText(d.owner_field, &ob));
    defer testing.allocator.free(owner);
    try setText(&h, d.owner_field, "tim:users");
    try h.expectGolden(h.window(), "properties");
    try setText(&h, d.owner_field, owner);
    // The mode is selected: typing replaces it, and the boxes follow.
    try h.typeText("755");
    try testing.expect(h.find(h.window(), .{ .role = .checkbox, .name = "Run", .name_len = 3 }) != null);
    var v: f64 = 0;
    _ = c.siv_widget_get_value(d.boxes[2], &v);
    try testing.expectEqual(@as(f64, 1), v);
    // A box flipped writes the mode back.
    try h.click(h.window(), try nodeOf(&h, d.boxes[4]), .primary);
    var mb: [16]u8 = undefined;
    try testing.expectEqualStrings("0775", App.ui.getText(d.mode_field, &mb));
    // Enter applies (a chmod operation); keys never reached the columns.
    try h.typeText("\n");
    try h.waitFor(&h, opsDone);
    try testing.expect(!d.isOpen());
    try testing.expectEqual(@as(u32, 0o775), modeOf(&f, "work/build.zig"));
    try testing.expectEqualStrings("build.zig", h.hovered());
    // Escape leaves without a change; Alt+a applies from a text field.
    try h.key(.@"return", .{ .alt = true }, "");
    try h.typeText("700\x1b");
    try testing.expect(!d.isOpen());
    try testing.expectEqual(@as(u32, 0o775), modeOf(&f, "work/build.zig"));
    try h.key(.@"return", .{ .alt = true }, "");
    try h.typeText("go-w");
    try h.key(@enumFromInt('a'), .{ .alt = true }, "");
    try h.waitFor(&h, opsDone);
    try testing.expectEqual(@as(u32, 0o755), modeOf(&f, "work/build.zig"));
}

fn setText(h: *Harness, n: siv.Node, text: []const u8) !void {
    var txn: siv.Txn = .null;
    try siv.check(c.siv_txn_begin(h.window(), &txn));
    _ = c.siv_set_text(txn, n, text.ptr, text.len);
    try siv.check(c.siv_txn_commit(txn));
    try h.settle();
}

/// The test node for a node of the window (for clicking it).
fn nodeOf(h: *Harness, n: siv.Node) !siv.TestNode {
    var r: siv.Rect = .{};
    try siv.check(c.siv_node_get_rect(n, &r));
    _ = h;
    return .{ .bounds = r };
}

test "themes and right to left" {
    var f: Fixture = .{};
    try fixture(&f, "themes");
    defer f.remove();
    const looks = [_]struct { []const u8, siv.ColorScheme, siv.Contrast, bool }{
        .{ "columns-dark", .dark, .follow, false },
        .{ "columns-high-contrast", .light, .high, false },
        .{ "columns-rtl", .light, .follow, true },
    };
    for (looks) |l| {
        var h: Harness = .{};
        defer h.deinit();
        try h.start(.{ .path = f.sub(&path_buf, "work/src"), .scheme = l[1], .contrast = l[2], .rtl = l[3] });
        try h.typeText("G v");
        try h.expectGolden(h.window(), l[0]);
        // The cursor on the first row: square at the top as at the bottom
        // (the columns are flat views, with no frame to round them).
        try h.typeText("\x1bgg");
        try expectSquareFirstRow(&h);
        if (l[1] == .dark) try h.expectGolden(h.window(), "first-row-dark");
    }
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work/src") });
    try expectSquareFirstRow(&h);
}

/// The current column's first row (the cursor's) has the same color at
/// all four corners.
fn expectSquareFirstRow(h: *Harness) !void {
    try testing.expectEqual(@as(u32, 0), h.dir().cursor);
    const r = (try h.expect(.list, "Files")).bounds;
    var len: usize = 0;
    var cw: u32 = 0;
    var chh: u32 = 0;
    try siv.check(c.siv_test_capture(h.window(), null, 0, &len, &cw, &chh));
    const px = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(px);
    try siv.check(c.siv_test_capture(h.window(), px.ptr, len, &len, &cw, &chh));
    const x0: u32 = @intFromFloat(@ceil(r.x));
    const x1: u32 = @intFromFloat(@floor(r.x + r.width) - 1);
    const y0: u32 = @intFromFloat(@ceil(r.y));
    const y1: u32 = y0 + @as(u32, @intFromFloat(@TypeOf(h.win.?.current).row_height)) - 1;
    const at = struct {
        fn f(p: []const u8, width: u32, x: u32, y: u32) [3]u8 {
            const i = (y * width + x) * 4;
            return p[i..][0..3].*;
        }
    }.f;
    const tl = at(px, cw, x0, y0);
    try testing.expectEqual(tl, at(px, cw, x1, y0));
    try testing.expectEqual(tl, at(px, cw, x0, y1));
    try testing.expectEqual(tl, at(px, cw, x1, y1));
}

test "the mouse: clicks in each column, double clicks, and drops" {
    var f: Fixture = .{};
    try fixture(&f, "mouse");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    // A click moves the cursor; the keyboard keeps working after.
    try h.click(h.window(), try h.expect(.list_item, "README.md 97 B"), .primary);
    try testing.expectEqualStrings("README.md", h.hovered());
    try h.typeText("j");
    try testing.expectEqualStrings("report.pdf", h.hovered());
    // A double click on a folder enters it.
    const src = try h.expect(.list_item, "src");
    try siv.check(c.siv_test_click(h.window(), src.bounds.x + 30, src.bounds.y + 10, .primary));
    try siv.check(c.siv_test_click(h.window(), src.bounds.x + 30, src.bounds.y + 10, .primary));
    try h.settle();
    try testing.expectEqualStrings("src", model.basename(h.dir().path));
    // A click in the parent column goes there.
    try h.click(h.window(), try h.expect(.list_item, "docs"), .primary);
    try testing.expectEqualStrings("docs", model.basename(h.dir().path));
    try h.typeText("k");
    // Files dropped from another application are copied here.
    var ubuf: [600]u8 = undefined;
    const u = try std.fmt.bufPrint(&ubuf, "file://{s}/notes.txt\r\n", .{f.path});
    const list = try h.expect(.list, "Files");
    try siv.check(c.siv_test_drop(h.window(), list.bounds.x + 100, list.bounds.y + 200, "text/uri-list", 13, u.ptr, u.len));
    try h.settle();
    try testing.expect(f.exists("work/docs/notes.txt"));
    try testing.expect(f.exists("notes.txt"));
}

/// Reads what the recorder wrote (its working folder, then one argument
/// per line) once it has run, and removes it for the next launch.
fn recorded(h: *Harness, f: *const Fixture, buf: []u8) ![]const u8 {
    var pb: [512]u8 = undefined;
    const out = try std.fmt.bufPrintSentinel(&pb, "{s}/bin/out", .{f.path}, 0);
    const Ctx = struct {
        p: [*:0]const u8,
        fn ready(x: @This()) bool {
            return linux.errno(linux.faccessat(linux.AT.FDCWD, x.p, linux.F_OK, 0)) == .SUCCESS;
        }
    };
    try h.dispatchUntil(Ctx{ .p = out.ptr }, Ctx.ready);
    const rc = linux.openat(linux.AT.FDCWD, out, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    _ = linux.unlinkat(linux.AT.FDCWD, out, 0);
    return buf[0..n];
}

test "opening: %F applications like imv and nvim get the paths, in a terminal, through symlinked folders" {
    var f: Fixture = .{};
    try fixture(&f, "open");
    defer f.remove();
    // Applications whose Exec takes a list (%F), as imv's and nvim's do,
    // run a recorder from the fixture's PATH. The launch spawns them only
    // when the activation token arrives, after the keys' paths are freed.
    try f.add(.{ .name = "bin", .dir = true });
    try f.add(.{ .name = "bin/record-args", .mode = 0o755 });
    try f.writeFile("bin/record-args", "#!/bin/sh\nd=$(dirname \"$0\")\n{ pwd -P; for a in \"$@\"; do printf '%s\\n' \"$a\"; done; } > \"$d/out.tmp\" && mv \"$d/out.tmp\" \"$d/out\"\n");
    for ([_][]const u8{ ".local", ".local/share", ".local/share/applications", ".config" }) |d| {
        if (!f.exists(d)) try f.add(.{ .name = d, .dir = true });
    }
    try f.writeFile(".local/share/applications/org.example.Imv.desktop", "[Desktop Entry]\nType=Application\nName=imv\nExec=record-args %F\nMimeType=image/png;\n");
    try f.writeFile(".local/share/applications/org.example.Nvim.desktop", "[Desktop Entry]\nType=Application\nName=Neovim\nExec=record-args %F\nTerminal=true\nMimeType=text/plain;\n");
    try f.writeFile(".config/mimeapps.list", "[Default Applications]\nimage/png=org.example.Imv.desktop\ntext/plain=org.example.Nvim.desktop\n");
    try f.add(.{ .name = "work/shot.png", .size = 10 });
    var cmd: [512]u8 = undefined;
    const ln = try std.fmt.bufPrintSentinel(&cmd, "ln -s src '{s}/work/linked'", .{f.path}, 0);
    try testing.expectEqual(@as(c_int, 0), system(ln.ptr));
    const old_path = std.mem.span(getenv("PATH") orelse "/usr/bin:/bin");
    var saved: [4096]u8 = undefined;
    const saved_path = try std.fmt.bufPrintSentinel(&saved, "{s}", .{old_path}, 0);
    var nb: [4096]u8 = undefined;
    _ = setenv("PATH", (try std.fmt.bufPrintSentinel(&nb, "{s}/bin:{s}", .{ f.path, saved_path }, 0)).ptr, 1);
    defer _ = setenv("PATH", saved_path.ptr, 1);
    // A terminal this does not know: it gets "-e" before the command.
    _ = setenv("TERMINAL", "record-args", 1);
    defer _ = unsetenv("TERMINAL");
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work") });
    var rb: [2048]u8 = undefined;
    var eb: [2048]u8 = undefined;
    // Text in nvim's terminal, in the file's folder.
    try h.typeText("fa-\n");
    try testing.expectEqualStrings(try std.fmt.bufPrint(&eb, "{0s}/work\n-e\nrecord-args\n{0s}/work/a-very-long-file-name-that-does-not-fit-in-its-column.txt\n", .{f.path}), try recorded(&h, &f, &rb));
    // Through a symlinked folder: the path as browsed.
    try h.typeText("flil");
    try h.typeText("fAp\n");
    try testing.expectEqualStrings(try std.fmt.bufPrint(&eb, "{0s}/work/src\n-e\nrecord-args\n{0s}/work/linked/App.zig\n", .{f.path}), try recorded(&h, &f, &rb));
    // Both images at once, with imv's %F.
    try h.typeText("hfph fsho \n");
    try testing.expectEqualStrings(try std.fmt.bufPrint(&eb, "{0s}/work\n{0s}/work/photo.png\n{0s}/work/shot.png\n", .{f.path}), try recorded(&h, &f, &rb));
}

test "folders follow changes on disk: the current one, its parent, and the previewed one" {
    var f: Fixture = .{};
    try fixture(&f, "watch");
    defer f.remove();
    var h: Harness = .{};
    defer h.deinit();
    try h.start(.{ .path = f.sub(&path_buf, "work"), .watch = true });
    // The cursor is on assets, previewed (empty).
    try f.add(.{ .name = "work/fresh.txt", .size = 1 });
    try f.add(.{ .name = "Pictures", .dir = true });
    try f.add(.{ .name = "work/assets/logo.svg", .size = 1 });
    const Cond = struct {
        fn ok(x: *Harness) bool {
            const w = x.win.?;
            const pd = w.parent_col.dir orelse return false;
            const prev = w.preview.column.dir orelse return false;
            return x.dir().indexOf("fresh.txt") != null and pd.indexOf("Pictures") != null and prev.indexOf("logo.svg") != null;
        }
    };
    try h.waitFor(&h, Cond.ok);
    // The cursor stayed on its entry.
    try testing.expectEqualStrings("assets", h.hovered());
}
