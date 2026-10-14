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
    try h.typeText("<");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try h.key(@enumFromInt('d'), .{ .ctrl = true }, "\x04");
    try testing.expectEqualStrings("run.sh", h.hovered());
}

const model = App.model;

fn countIn(f: *const Fixture, rel: []const u8) usize {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, rel }, 0) catch return 0;
    var it = App.fsops.DirIter.open(p) catch return 0;
    defer it.close();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
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
    // Pasted in the parent: photo.png is there already, so the status
    // line asks; K keeps both, for every conflict.
    try h.typeText("h");
    try siv.check(c.siv_test_type(h.window(), "p", 1));
    const Asking = struct {
        fn check(w: *App.Window) bool {
            return w.await_key == .conflict;
        }
    };
    try h.dispatchUntil(h.win.?, Asking.check);
    try h.expectGolden(h.window(), "conflict");
    try h.typeText("K");
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
    // dD asks first; n keeps it, y deletes it.
    try h.typeText("fgu");
    try h.typeText("dD");
    try testing.expectEqual(App.Window.Await.confirm_delete, h.win.?.await_key);
    try h.expectGolden(h.window(), "confirm-delete");
    try h.typeText("n");
    try testing.expect(f.exists("work/guide.md"));
    try h.typeText("dDy");
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
    try h.typeText("fda");
    try testing.expectEqual(App.Window.PreviewMode.info, p.applied);
    try testing.expect(h.reads("Binary file"));
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
    }
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
