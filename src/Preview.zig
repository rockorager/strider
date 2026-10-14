//! The preview column: what is under the cursor, as soon as the cursor
//! is on it. Folders show their entries (from the directory cache),
//! text files their start with syntax coloring, images decode on siv's
//! workers at the size shown, archives list their entries, PDFs show
//! their first page (poppler's pdftoppm, else MuPDF's mutool), videos a
//! frame (ffmpegthumbnailer, else ffmpeg), binary files their start in
//! hex, and other files their details. Each preview has a generation:
//! moving on cancels decoding and reading that has not started, kills the
//! programs a preview runs, and drops results that arrive late.
//!
//! Nothing here touches the file system on the UI thread: reads,
//! listings, renders, and even a link's target happen in jobs, and at
//! most `max_jobs` of them run at once, so previews stuck on a slow or
//! hung file system cannot take the workers that read folders.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Column = @import("Column.zig");
const Dir = @import("Dir.zig");
const model = @import("model.zig");
const mime = @import("mime.zig");
const ui = @import("ui.zig");
const highlight = @import("highlight.zig");
const archive = @import("archive.zig");
const proc = @import("proc.zig");
const Thumbs = @import("Thumbs.zig");

const Preview = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const Mode = enum { none, dir, text, image, info };

win: *Window,
root: Node = .null,
column: Column,
scroll: Node = .null,
text: Node = .null,
image_box: Node = .null,
image: Node = .null,
caption: Node = .null,
info: Node = .null,
info_title: Node = .null,
info_body: Node = .null,
mode: Mode = .none,
/// Which preview results belong to.
gen: u64 = 0,
/// The file previewed, for results to check against.
path: std.ArrayList(u8) = .empty,
image_request: siv.ImageRequest = .null,
/// The image load in flight's link back here, cut when it is no longer
/// wanted.
image_ctx: ?*ImageCtx = null,
job: ?*Job = null,
/// Scrolled lines of a text preview.
scroll_y: f32 = 0,
/// For tests and measurements: the kind of the last preview applied.
applied: Mode = .none,
/// What the text preview shows, for tests.
text_kind: TextKind = .none,
/// A job waiting for one of the `max_jobs` slots (the newest wins).
pending: ?Pending = null,

pub const TextKind = enum { none, text, archive, command, binary };

pub fn init(win: *Window) Preview {
    return .{ .win = win, .column = .{ .win = win, .kind = .preview } };
}

pub fn deinit(p: *Preview) void {
    p.dropPending();
    if (p.image_request != .null) _ = c.siv_image_request_cancel(p.image_request);
    if (p.image_ctx) |x| x.preview = null;
    if (p.job) |j| j.preview = null;
    if (p.column.dir) |d| d.pins -= 1;
    p.column.dir = null;
    p.path.deinit(p.win.gpa);
}

pub fn build(p: *Preview, txn: Txn, parent: Node) void {
    p.root = c.siv_stack(txn, parent, null);
    _ = c.siv_set_semantics(txn, p.root, &.{ .role = .group, .label = "Preview", .label_len = 7 });
    p.column.build(txn, p.root, "Folder preview");

    p.scroll = c.siv_scroll(txn, p.root, .both);
    _ = c.siv_set_layout(txn, p.scroll, &.{ .width = ui.fill(), .height = ui.fill() });
    p.text = c.siv_text(txn, p.scroll, "", 0);
    // Code reads left to right in right-to-left layouts too.
    _ = c.siv_set_layout(txn, p.text, &.{ .padding = .{ .start = 10, .end = 10, .top = 6, .bottom = 6 }, .direction = .ltr });
    _ = c.siv_set_semantics(txn, p.text, &.{ .role = .document, .label = "File preview", .label_len = 12 });

    p.image_box = c.siv_flex(txn, p.root, &.{ .axis = .column, .gap = 6, .align_items = .center, .justify = .center });
    _ = c.siv_set_layout(txn, p.image_box, &.{ .width = ui.fill(), .height = ui.fill(), .padding = .{ .start = 8, .end = 8, .top = 8, .bottom = 8 } });
    p.image = c.siv_image_view(txn, p.image_box, &.{ .fit = .contain });
    _ = c.siv_set_layout(txn, p.image, &.{ .grow = 1, .basis = ui.px(0), .width = ui.fill() });
    _ = c.siv_set_semantics(txn, p.image, &.{ .role = .image, .label = "Image preview", .label_len = 13 });
    p.caption = ui.text(txn, p.image_box, "", .muted_fg, .caption);
    _ = c.siv_set_text_style(txn, p.caption, &.{ .color_token = .muted_fg, .size_role = .caption, .direction = .ltr, .flags = .{ .no_wrap = true, .ellipsize = true } });

    p.info = c.siv_flex(txn, p.root, &.{ .axis = .column, .gap = 6 });
    _ = c.siv_set_layout(txn, p.info, &.{ .width = ui.fill(), .padding = .{ .start = 14, .end = 14, .top = 14, .bottom = 14 } });
    p.info_title = c.siv_text(txn, p.info, "", 0);
    _ = c.siv_set_text_style(txn, p.info_title, &.{ .color_token = .view_fg, .size_role = .heading, .weight = .bold, .flags = .{ .break_words = true } });
    _ = c.siv_set_semantics(txn, p.info_title, &.{ .role = .heading, .level = 2 });
    p.info_body = c.siv_text(txn, p.info, "", 0);
    _ = c.siv_set_text_style(txn, p.info_body, &.{ .color_token = .muted_fg, .size_role = .body, .line_spacing = 1.3, .tab_width = 110, .flags = .{ .break_words = true } });
    p.applyModeTxn(txn, .none);
}

fn applyModeTxn(p: *Preview, txn: Txn, mode: Mode) void {
    p.mode = mode;
    _ = c.siv_set_hidden(txn, p.column.root, mode != .dir);
    _ = c.siv_set_hidden(txn, p.scroll, mode != .text);
    _ = c.siv_set_hidden(txn, p.image_box, mode != .image);
    _ = c.siv_set_hidden(txn, p.info, mode != .info);
    if (mode != .dir and p.column.dir != null) {
        if (p.column.dir) |d| d.pins -= 1;
        p.column.dir = null;
        p.column.shown_count = 0;
        _ = c.siv_view_set_count(txn, p.column.view, 0);
    }
}

/// Moves on: whatever is decoding or reading for the last preview stops,
/// and its results will be dropped.
fn cancel(p: *Preview) void {
    p.gen +%= 1;
    if (p.image_request != .null) _ = c.siv_image_request_cancel(p.image_request);
    p.image_request = .null;
    if (p.image_ctx) |x| x.preview = null;
    p.image_ctx = null;
    if (p.job) |j| {
        j.cancelled.store(true, .release);
        j.preview = null;
    }
    p.job = null;
    p.dropPending();
}

/// Shows nothing.
pub fn clear(p: *Preview, txn: Txn) void {
    p.cancel();
    p.path.clearRetainingCapacity();
    p.applyModeTxn(txn, .none);
}

/// Previews entry `i` of `dir`.
pub fn showEntry(p: *Preview, txn: Txn, d: *Dir, i: u32) void {
    const app = p.win.app;
    const e = d.entryAt(i) orelse return p.clear(txn);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = d.pathAt(&pbuf, i) orelse return p.clear(txn);
    if (!app.options.preview) return p.clear(txn);
    // The same entry again (a reload): keep what shows unless it changed.
    const same = std.mem.eql(u8, p.path.items, path);
    p.path.clearRetainingCapacity();
    p.path.appendSlice(p.win.gpa, path) catch {};
    if (e.kind == .dir) {
        p.cancel();
        const old = p.column.dir;
        const nd = app.cache.get(path, app.options.stale_ms);
        if (old) |o| if (o != nd and o.pins == 1) o.cancelLoad();
        p.applyModeTxn(txn, .dir);
        p.column.show(txn, nd);
        p.applied = .dir;
        return;
    }
    if (same and p.mode != .none and p.mode != .dir and p.job == null and p.image_request == .null) return;
    p.cancel();
    p.scroll_y = 0;
    const name = d.listing.?.base(e);
    const type_name = if (app.mimeDb()) |db| db.name(e.mime) else "";
    // Text by its type, or by being a subclass of text/plain
    // (application/typescript).
    const texty = isTexty(type_name) or if (app.mimeDb()) |db| db.isA(e.mime, mime.text_plain) else false;
    // Lua previewers first.
    if (app.lua) |lua| if (lua.previewer(path, name, type_name)) |pv| switch (pv) {
        .text => |t| {
            defer p.win.gpa.free(t);
            p.showText(txn, t, null, .command);
            return;
        },
        .command => |argv| {
            p.startJob(txn, .{ .command = argv }, path, e);
            return;
        },
    };
    if (e.kind != .file) return p.showInfo(txn, d, e, path, null);
    const images = app.options.preview_images;
    if (model.thumbnailable(name) and images) {
        if (e.size > app.options.preview_max_image_bytes) return p.showInfo(txn, d, e, path, "Too large to preview (preview_max_image_bytes)");
        if (p.loadImage(path, e)) {
            p.applyCaption(txn, d, e);
            return;
        }
    }
    if (archive.kindOf(name)) |kind| return p.startJob(txn, .{ .archive = kind }, path, e);
    const pdf = std.mem.eql(u8, type_name, "application/pdf") or std.ascii.endsWithIgnoreCase(name, ".pdf");
    const video = std.mem.startsWith(u8, type_name, "video/");
    if (pdf and images) {
        const r: ?Renderer = if (proc.onPath("pdftoppm")) .pdftoppm else if (proc.onPath("mutool")) .mutool else null;
        if (r) |x| {
            p.applyCaption(txn, d, e);
            return p.startJob(txn, .{ .page = x }, path, e);
        }
    }
    // A thumbnail another program cached, for videos and others.
    if (!texty and images) {
        var tb: [linux.PATH_MAX]u8 = undefined;
        if (Thumbs.cachedPath(p.win.gpa, app.thumbnail_cache, path, e.mtime, &tb)) |thumb| {
            if (p.loadImage(thumb, e)) {
                p.applyCaption(txn, d, e);
                return;
            }
        }
    }
    if (video and images) {
        const r: ?Renderer = if (proc.onPath("ffmpegthumbnailer")) .ffmpegthumbnailer else if (proc.onPath("ffmpeg")) .ffmpeg else null;
        if (r) |x| {
            p.applyCaption(txn, d, e);
            return p.startJob(txn, .{ .page = x }, path, e);
        }
        return p.showInfo(txn, d, e, path, "Install ffmpegthumbnailer or ffmpeg to preview videos");
    }
    if (pdf) return p.showInfo(txn, d, e, path, if (images) "Install poppler (pdftoppm) or MuPDF (mutool) to preview PDFs" else null);
    if (e.size == 0) return p.showInfo(txn, d, e, path, "Empty file");
    if (texty or type_name.len == 0 or std.mem.eql(u8, type_name, "application/octet-stream") or std.mem.startsWith(u8, type_name, "application/x-unknown")) {
        return p.startJob(txn, .text, path, e);
    }
    // Programs, libraries, and other application data with no previewer:
    // their start in hex (text that only has an application type shows
    // as text).
    if (std.mem.startsWith(u8, type_name, "application/")) return p.startJob(txn, .text, path, e);
    p.showInfo(txn, d, e, path, null);
}

fn isTexty(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "text/")) return true;
    const texty = [_][]const u8{ "application/json", "application/xml", "application/javascript", "application/x-shellscript", "application/toml", "application/x-yaml", "application/sql", "application/x-desktop", "inode/x-empty", "application/x-zerosize", "application/x-executable" };
    for (texty) |x| if (std.mem.eql(u8, t, x)) return true;
    return std.mem.endsWith(u8, t, "+xml") or std.mem.endsWith(u8, t, "+json");
}

// Images --------------------------------------------------------------------------------

/// The size images decode at: the preview's box.
fn imageBox(p: *Preview) siv.Size {
    var r: siv.Rect = .{};
    if (c.siv_node_get_rect(p.root, &r) != .ok or r.width < 16) return .{ .width = 480, .height = 480 };
    return .{ .width = @max(16, r.width - 16), .height = @max(16, r.height - 40) };
}

const ImageCtx = struct { preview: ?*Preview, gpa: Allocator };

fn loadImage(p: *Preview, path: []const u8, _: model.Entry) bool {
    const box = p.imageBox();
    var scale: f64 = 1;
    if (c.siv_window_get_scale(p.win.window, &scale) != .ok) scale = 1;
    const ctx = p.win.gpa.create(ImageCtx) catch return false;
    ctx.* = .{ .preview = p, .gpa = p.win.gpa };
    var req: siv.ImageRequest = .null;
    // siv frees the context if the load cannot start.
    if (c.siv_image_load(p.win.app.app, &.{ .path = path.ptr, .path_len = path.len, .max_width = box.width, .max_height = box.height, .scale = @floatCast(scale), .priority = 10 }, onImage, freeImageCtx, ctx, &req) != .ok) return false;
    p.image_request = req;
    p.image_ctx = ctx;
    return true;
}

fn freeImageCtx(ud: ?*anyopaque) callconv(.c) void {
    const ctx: *ImageCtx = @ptrCast(@alignCast(ud.?));
    ctx.gpa.destroy(ctx);
}

fn onImage(ud: ?*anyopaque, result: siv.Result, image: siv.Image) callconv(.c) void {
    const ctx: *ImageCtx = @ptrCast(@alignCast(ud.?));
    defer if (result == .ok) c.siv_image_destroy(image);
    const p = ctx.preview orelse return;
    p.image_request = .null;
    p.image_ctx = null;
    const txn = p.win.begin() orelse return;
    if (result == .ok) {
        _ = c.siv_set_image_view(txn, p.image, &.{ .image = image, .fit = .contain });
        p.applyModeTxn(txn, .image);
        p.applied = .image;
    } else {
        const msg = switch (result) {
            .error_unsupported => "This image format is not supported",
            .error_limit_exceeded => "This image is too large to preview",
            else => "This image could not be read",
        };
        p.setInfoText(txn, model.basename(p.path.items), msg);
        p.applyModeTxn(txn, .info);
        p.applied = .info;
    }
    _ = ui.commit(txn);
}

fn applyCaption(p: *Preview, txn: Txn, d: *Dir, e: model.Entry) void {
    var buf: [256]u8 = undefined;
    var sbuf: [32]u8 = undefined;
    var tbuf: [32]u8 = undefined;
    const tz = if (p.win.app.opts.reproducible) 0 else p.win.app.tz_offset_s;
    const cap = std.fmt.bufPrint(&buf, "{s}  ·  {s}  ·  {s}", .{ d.listing.?.base(e), model.formatSize(&sbuf, e.size), model.formatTime(&tbuf, e.mtime, tz) }) catch "";
    _ = c.siv_set_text(txn, p.caption, cap.ptr, cap.len);
}

// Details ----------------------------------------------------------------------------------

fn setInfoText(p: *Preview, txn: Txn, title: []const u8, body: []const u8) void {
    _ = c.siv_set_text(txn, p.info_title, title.ptr, title.len);
    _ = c.siv_set_text(txn, p.info_body, body.ptr, body.len);
}

/// The file's details: type, size, dates, permissions, link target.
pub fn showInfo(p: *Preview, txn: Txn, d: *Dir, e: model.Entry, path: []const u8, note: ?[]const u8) void {
    const app = p.win.app;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(p.win.gpa);
    const gpa = p.win.gpa;
    const type_label = if (app.mimeDb()) |db| (db.cachedComment(e.mime) orelse db.name(e.mime)) else "";
    var sbuf: [32]u8 = undefined;
    var tbuf: [32]u8 = undefined;
    var mbuf: [9]u8 = undefined;
    const tz = if (app.opts.reproducible) 0 else app.tz_offset_s;
    const w = struct {
        fn line(list: *std.ArrayList(u8), a: Allocator, k: []const u8, v: []const u8) void {
            if (v.len == 0) return;
            if (list.items.len != 0) list.append(a, '\n') catch {};
            list.appendSlice(a, k) catch {};
            list.append(a, '\t') catch {};
            list.appendSlice(a, v) catch {};
        }
    };
    w.line(&body, gpa, "Type", if (e.kind == .dir) "Folder" else type_label);
    if (e.kind == .file) w.line(&body, gpa, "Size", model.formatSize(&sbuf, e.size));
    w.line(&body, gpa, "Modified", model.formatTime(&tbuf, e.mtime, tz));
    w.line(&body, gpa, "Permissions", model.formatMode(&mbuf, e.mode));
    // A link's target comes from a job (readlink can wait on the file
    // system too) and joins these lines when it arrives.
    if (e.link and p.job == null) p.startJob(txn, .link, path, e);
    if (d.trash_info) |*ti| {
        const i = for (d.visible.items) |vi| {
            if (std.meta.eql(d.listing.?.entries[vi], e)) break vi;
        } else null;
        if (i) |idx| {
            const t = ti.get(idx);
            w.line(&body, gpa, "From", t.original);
        }
    }
    if (note) |n| {
        body.appendSlice(gpa, "\n\n") catch {};
        body.appendSlice(gpa, n) catch {};
    }
    p.setInfoText(txn, d.listing.?.base(e), body.items);
    p.applyModeTxn(txn, .info);
    p.applied = .info;
}

// Text -----------------------------------------------------------------------------------

fn spanFor(class: highlight.Class) siv.TextSpan {
    var s: siv.TextSpan = .{ .flags = .{ .color = true } };
    switch (class) {
        .keyword => {
            s.color_token = .accent;
            s.flags.weight = true;
            s.weight = .bold;
        },
        .type => s.color_token = .accent,
        .string => s.color_token = .success,
        .number => s.color_token = .warning,
        .comment => {
            s.color_token = .muted_fg;
            s.flags.slant = true;
            s.slant = .italic;
        },
        .heading => {
            s.color_token = .accent;
            s.flags.weight = true;
            s.weight = .bold;
        },
        .added => s.color_token = .success,
        .removed => s.color_token = .destructive,
        .punct => s.color_token = .muted_fg,
    }
    return s;
}

fn showText(p: *Preview, txn: Txn, text: []const u8, spans: ?[]const highlight.Span, kind: TextKind) void {
    _ = c.siv_set_text(txn, p.text, text.ptr, text.len);
    _ = c.siv_set_text_style(txn, p.text, &.{ .family = "monospace", .family_len = 9, .color_token = .view_fg, .size_role = .caption, .flags = .{ .no_wrap = true }, .direction = .ltr });
    if (spans) |list| if (list.len != 0) {
        const gpa = p.win.gpa;
        const out = gpa.alloc(siv.TextSpan, list.len) catch return;
        defer gpa.free(out);
        for (list, out) |s, *o| {
            o.* = spanFor(s.class);
            o.start = s.start;
            o.end = s.end;
        }
        _ = c.siv_set_text_spans(txn, p.text, &.{ .spans = out.ptr, .spans_count = out.len });
    };
    _ = c.siv_scroll_to(txn, p.scroll, 0, 0);
    p.applyModeTxn(txn, .text);
    p.applied = .text;
    p.text_kind = kind;
}

/// Shows text that is not a file: a command's output, the help.
pub fn showOutput(p: *Preview, title: []const u8, text: []const u8, spans: ?[]const highlight.Span) void {
    _ = title;
    p.cancel();
    p.path.clearRetainingCapacity();
    const txn = p.win.begin() orelse return;
    p.showText(txn, text, spans, .command);
    _ = ui.commit(txn);
}

/// Scrolls a text preview by `lines` (negative: up).
pub fn scrollBy(p: *Preview, lines: i32) void {
    if (p.mode != .text) return;
    p.scroll_y = @max(0, p.scroll_y + @as(f32, @floatFromInt(lines)) * 16);
    const txn = p.win.begin() orelse return;
    _ = c.siv_scroll_to(txn, p.scroll, 0, p.scroll_y);
    _ = ui.commit(txn);
}

// Jobs -----------------------------------------------------------------------------------

/// Programs that render a file's first page or a video's frame to PNG.
const Renderer = enum { pdftoppm, mutool, ffmpegthumbnailer, ffmpeg };

const JobKind = union(enum) {
    text,
    archive: archive.Kind,
    page: Renderer,
    /// A Lua previewer's command; owned.
    command: [][]u8,
    /// A symbolic link's target, for the details.
    link,
};

/// Preview jobs that may run at once, over every window.
pub const max_jobs = 2;
/// Preview jobs running (UI thread).
var running: u32 = 0;
/// Previews whose next job waits for a slot, oldest first.
var waiting: [32]?*Preview = @splat(null);

/// Programs a preview runs are killed after this long.
const program_timeout_ms = 15_000;
/// How much of a binary file the hex view shows.
const hex_bytes = 1024;

const Pending = struct { kind: JobKind, path: []u8, e: model.Entry };

/// Reads, lists, or renders a file on a worker.
const Job = struct {
    preview: ?*Preview,
    gpa: Allocator,
    gen: u64,
    kind: JobKind,
    path: []u8,
    name: []u8,
    mtime: i64,
    size: u64,
    max_bytes: u32,
    syntax: bool,
    width: f32,
    cache_dir: []u8,
    /// The file's type, as people read it, over a hex view.
    type_label: []u8 = &.{},
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Holds one of the `max_jobs` slots.
    started: bool = false,
    // Results.
    text: std.ArrayList(u8) = .empty,
    spans: []highlight.Span = &.{},
    text_kind: TextKind = .text,
    image_path: ?[]u8 = null,
    failed: ?[]const u8 = null,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ud.?));
        if (j.cancelled.load(.acquire)) return;
        switch (j.kind) {
            .text => j.readText(),
            .archive => |k| j.listArchive(k),
            .page => |r| j.renderPage(r),
            .command => |argv| j.runCommand(argv),
            .link => {
                var zb: [linux.PATH_MAX]u8 = undefined;
                var lbuf: [linux.PATH_MAX]u8 = undefined;
                const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{j.path}, 0) catch return;
                const n = linux.readlinkat(linux.AT.FDCWD, z, &lbuf, lbuf.len);
                if (linux.errno(n) == .SUCCESS) j.text.appendSlice(j.gpa, lbuf[0..n]) catch {};
            },
        }
    }

    fn readText(j: *Job) void {
        var zb: [linux.PATH_MAX]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{j.path}, 0) catch return;
        const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true }, 0);
        if (linux.errno(rc) != .SUCCESS) {
            j.failed = "This file could not be read";
            return;
        }
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        const want: usize = @intCast(@min(j.size, j.max_bytes));
        j.text.resize(j.gpa, want) catch return;
        var got: usize = 0;
        while (got < want) {
            const n = linux.read(fd, j.text.items[got..].ptr, want - got);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            got += n;
        }
        j.text.shrinkRetainingCapacity(got);
        const head = j.text.items[0..@min(got, 8192)];
        if (std.mem.indexOfScalar(u8, head, 0) != null or !std.unicode.utf8ValidateSlice(trimPartial(head))) {
            j.text_kind = .binary;
            j.hexDump(j.text.items[0..@min(got, hex_bytes)]) catch {};
            return;
        }
        // Cut at the last whole line or character.
        if (got == want and j.size > want) {
            if (std.mem.lastIndexOfScalar(u8, j.text.items, '\n')) |nl| j.text.shrinkRetainingCapacity(nl + 1);
        }
        const valid = trimPartial(j.text.items);
        j.text.shrinkRetainingCapacity(valid.len);
        // Tabs read as four spaces wide anyway; carriage returns go.
        stripCr(&j.text);
        if (j.syntax) if (highlight.detect(j.name, head)) |lang| {
            j.spans = highlight.highlight(j.gpa, lang, j.text.items) catch &.{};
        };
    }

    fn listArchive(j: *Job, kind: archive.Kind) void {
        var l = archive.list(j.gpa, j.path, kind, 2000) catch |err| {
            j.failed = switch (err) {
                error.Unsupported => "Install libarchive (bsdtar) to list this archive",
                else => "This archive could not be read",
            };
            return;
        };
        defer l.deinit();
        j.text_kind = .archive;
        var sbuf: [32]u8 = undefined;
        for (l.entries) |e| {
            const size = if (e.dir or e.size == 0) "" else model.formatSize(&sbuf, e.size);
            j.text.print(j.gpa, "{s}{s}{s}{s}\n", .{ e.name, if (e.dir) "/" else "", if (size.len != 0) "  " else "", size }) catch return;
        }
        if (l.truncated) j.text.appendSlice(j.gpa, "…\n") catch {};
        if (l.entries.len == 0) j.text.appendSlice(j.gpa, "(empty archive)\n") catch {};
        // Folders colored like keywords.
        var spans: std.ArrayList(highlight.Span) = .empty;
        var start: usize = 0;
        for (l.entries) |e| {
            const line_len = std.mem.indexOfScalarPos(u8, j.text.items, start, '\n') orelse break;
            if (e.dir) spans.append(j.gpa, .{ .start = @intCast(start), .end = @intCast(start + e.name.len + 1), .class = .keyword }) catch {};
            const two = std.mem.indexOfPos(u8, j.text.items[0..line_len], start, "  ");
            if (two) |t| spans.append(j.gpa, .{ .start = @intCast(t + 2), .end = @intCast(line_len), .class = .comment }) catch {};
            start = line_len + 1;
        }
        j.spans = spans.toOwnedSlice(j.gpa) catch &.{};
    }

    /// The start of a binary file as hexdump -C shows it: the offset, 16
    /// bytes in hex, and those that are printable.
    fn hexDump(j: *Job, bytes: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(j.gpa);
        var spans: std.ArrayList(highlight.Span) = .empty;
        errdefer spans.deinit(j.gpa);
        var sbuf: [32]u8 = undefined;
        if (j.type_label.len != 0) {
            try out.print(j.gpa, "{s}, {s}\n\n", .{ j.type_label, model.formatSize(&sbuf, j.size) });
            try spans.append(j.gpa, .{ .start = 0, .end = @intCast(out.items.len), .class = .heading });
        }
        var off: usize = 0;
        while (off < bytes.len) : (off += 16) {
            const row = bytes[off..@min(off + 16, bytes.len)];
            const start: u32 = @intCast(out.items.len);
            try out.print(j.gpa, "{x:0>8}", .{off});
            try spans.append(j.gpa, .{ .start = start, .end = start + 8, .class = .comment });
            for (0..16) |k| {
                if (k % 8 == 0) try out.append(j.gpa, ' ');
                if (k < row.len) try out.print(j.gpa, " {x:0>2}", .{row[k]}) else try out.appendSlice(j.gpa, "   ");
            }
            try out.appendSlice(j.gpa, "  |");
            const a: u32 = @intCast(out.items.len);
            for (row) |b| try out.append(j.gpa, if (b >= 0x20 and b < 0x7f) b else '.');
            try spans.append(j.gpa, .{ .start = a, .end = @intCast(out.items.len), .class = .string });
            try out.appendSlice(j.gpa, "|\n");
        }
        if (j.size > bytes.len) {
            try out.print(j.gpa, "… the first {d} bytes of {s}\n", .{ bytes.len, model.formatSize(&sbuf, j.size) });
        }
        j.text.deinit(j.gpa);
        j.text = out;
        j.spans = try spans.toOwnedSlice(j.gpa);
    }

    /// A PDF's first page or a video's frame, at the preview's width, as
    /// a PNG in $XDG_CACHE_HOME/strider/previews/<hash>.png (by path,
    /// time, and width).
    fn renderPage(j: *Job, r: Renderer) void {
        var h = std.hash.Wyhash.init(0);
        h.update(j.path);
        h.update(std.mem.asBytes(&j.mtime));
        const w: u32 = @intFromFloat(@max(64, j.width));
        h.update(std.mem.asBytes(&w));
        const key = h.final();
        var obuf: [linux.PATH_MAX]u8 = undefined;
        const prefix = std.fmt.bufPrint(&obuf, "{s}/{x:0>16}", .{ j.cache_dir, key }) catch return;
        var pngbuf: [linux.PATH_MAX]u8 = undefined;
        const png = std.fmt.bufPrintSentinel(&pngbuf, "{s}.png", .{prefix}, 0) catch return;
        if (!nonEmpty(png)) {
            mkdirs(j.cache_dir);
            var wbuf: [16]u8 = undefined;
            const ws = std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch return;
            var sbuf: [48]u8 = undefined;
            const scale = std.fmt.bufPrint(&sbuf, "scale={d}:-2", .{w}) catch return;
            const pdf = r == .pdftoppm or r == .mutool;
            const argv: []const []const u8 = switch (r) {
                .pdftoppm => &.{ "pdftoppm", "-f", "1", "-l", "1", "-singlefile", "-png", "-scale-to-x", ws, "-scale-to-y", "-1", j.path, prefix },
                .mutool => &.{ "mutool", "draw", "-q", "-o", png, "-w", ws, "-F", "png", j.path, "1" },
                .ffmpegthumbnailer => &.{ "ffmpegthumbnailer", "-i", j.path, "-o", png, "-s", ws, "-c", "png", "-t", "10%" },
                // A few seconds in, past a fade from black; short videos
                // have no frame there, so then the first.
                .ffmpeg => &.{ "ffmpeg", "-nostdin", "-v", "error", "-y", "-ss", "3", "-i", j.path, "-frames:v", "1", "-vf", scale, png },
            };
            const opts: proc.Options = .{ .max_output = 4096, .cancel = &j.cancelled, .timeout_ms = program_timeout_ms };
            var res = proc.run(j.gpa, argv, opts) catch {
                j.failed = if (pdf) "The PDF renderer could not run" else "The video thumbnailer could not run";
                return;
            };
            res.deinit(j.gpa);
            if (r == .ffmpeg and !nonEmpty(png) and !j.cancelled.load(.acquire)) {
                var again = proc.run(j.gpa, &.{ "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", j.path, "-frames:v", "1", "-vf", scale, png }, opts) catch return;
                again.deinit(j.gpa);
            }
            if (j.cancelled.load(.acquire)) return;
            if (!nonEmpty(png)) {
                j.failed = if (pdf) "This PDF could not be rendered" else "No frame could be taken from this video";
                return;
            }
        }
        j.image_path = j.gpa.dupe(u8, png) catch null;
    }

    fn runCommand(j: *Job, argv: []const []u8) void {
        const views = j.gpa.alloc([]const u8, argv.len) catch return;
        defer j.gpa.free(views);
        for (argv, 0..) |a, i| views[i] = a;
        var r = proc.run(j.gpa, views, .{ .max_output = j.max_bytes, .kill_after = j.max_bytes * 4, .cwd = std.fs.path.dirname(j.path), .cancel = &j.cancelled, .timeout_ms = program_timeout_ms }) catch {
            j.failed = "The previewer could not run";
            return;
        };
        defer r.deinit(j.gpa);
        j.text_kind = .command;
        j.text.appendSlice(j.gpa, trimPartial(r.output)) catch {};
        stripCr(&j.text);
        stripAnsi(&j.text);
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ud.?));
        const p = j.preview orelse return;
        if (p.job != j or p.gen != j.gen) return;
        p.job = null;
        if (j.cancelled.load(.acquire)) return;
        const txn = p.win.begin() orelse return;
        if (j.kind == .link) {
            // The details again, with where the link goes.
            if (j.text.items.len != 0 and p.mode == .info) {
                var buf: [8192]u8 = undefined;
                const body = ui.getText(p.info_body, &buf);
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(j.gpa);
                // Before a note (a blank line), if there is one.
                const split = std.mem.indexOf(u8, body, "\n\n") orelse body.len;
                out.print(j.gpa, "{s}\nLinks to\t{s}{s}", .{ body[0..split], j.text.items, body[split..] }) catch {};
                _ = c.siv_set_text(txn, p.info_body, out.items.ptr, out.items.len);
            }
        } else if (j.failed) |msg| {
            p.setInfoText(txn, model.basename(j.path), msg);
            p.applyModeTxn(txn, .info);
            p.applied = .info;
        } else if (j.image_path) |img| {
            _ = ui.commit(txn);
            if (!p.loadImage(img, undefined)) p.win.notify("The preview could not be shown", true);
            return;
        } else {
            p.showText(txn, j.text.items, j.spans, j.text_kind);
        }
        _ = ui.commit(txn);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const j: *Job = @ptrCast(@alignCast(ud.?));
        const gpa = j.gpa;
        if (j.started) {
            running -= 1;
            startWaiting();
        }
        j.text.deinit(gpa);
        gpa.free(j.spans);
        if (j.image_path) |x| gpa.free(x);
        if (j.kind == .command) {
            for (j.kind.command) |a| gpa.free(a);
            gpa.free(j.kind.command);
        }
        gpa.free(j.path);
        gpa.free(j.name);
        gpa.free(j.cache_dir);
        gpa.free(j.type_label);
        gpa.destroy(j);
    }
};

/// Starts a job for the preview, or queues it while `max_jobs` run (the
/// newest queued job replaces an older one).
fn startJob(p: *Preview, txn: Txn, kind: JobKind, path: []const u8, e: model.Entry) void {
    if (running < max_jobs) return p.launch(kind, path, e);
    p.dropPending();
    const copy = p.win.gpa.dupe(u8, path) catch return freeKind(p.win.gpa, kind);
    p.pending = .{ .kind = kind, .path = copy, .e = e };
    for (&waiting) |*slot| if (slot.* == null) {
        slot.* = p;
        break;
    };
    // A link's target only adds a line; anything else says it waits.
    if (kind != .link) {
        p.setInfoText(txn, model.basename(path), "Waiting for the file system…");
        p.applyModeTxn(txn, .info);
    }
}

fn dropPending(p: *Preview) void {
    for (&waiting) |*slot| if (slot.* == p) {
        slot.* = null;
    };
    const pd = p.pending orelse return;
    p.pending = null;
    freeKind(p.win.gpa, pd.kind);
    p.win.gpa.free(pd.path);
}

fn freeKind(gpa: Allocator, kind: JobKind) void {
    if (kind == .command) {
        for (kind.command) |a| gpa.free(a);
        gpa.free(kind.command);
    }
}

/// A slot came free: the longest-waiting preview's job starts.
fn startWaiting() void {
    while (running < max_jobs) {
        const p = for (&waiting) |*slot| {
            if (slot.*) |x| {
                slot.* = null;
                break x;
            }
        } else return;
        const pd = p.pending orelse continue;
        p.pending = null;
        defer p.win.gpa.free(pd.path);
        p.launch(pd.kind, pd.path, pd.e);
    }
}

fn launch(p: *Preview, kind: JobKind, path: []const u8, e: model.Entry) void {
    const gpa = p.win.gpa;
    const app = p.win.app;
    const j = gpa.create(Job) catch return freeKind(gpa, kind);
    j.* = .{
        .preview = p,
        .gpa = gpa,
        .gen = p.gen,
        .kind = kind,
        .path = gpa.dupe(u8, path) catch return gpa.destroy(j),
        .name = gpa.dupe(u8, model.basename(path)) catch "",
        .mtime = e.mtime,
        .size = e.size,
        .max_bytes = app.options.preview_max_bytes,
        .syntax = app.options.syntax,
        .width = p.imageBox().width,
        .cache_dir = gpa.dupe(u8, app.preview_cache) catch "",
    };
    if (kind == .text) {
        const db = app.mimeDb();
        const known = db != null and e.mime != mime.unknown and !std.mem.eql(u8, db.?.name(e.mime), "application/octet-stream");
        const label = if (!known) "Binary file" else db.?.cachedComment(e.mime) orelse db.?.name(e.mime);
        j.type_label = gpa.dupe(u8, label) catch &.{};
    }
    p.job = j;
    j.started = true;
    running += 1;
    // The destroy-notify runs if the job cannot start.
    if (c.siv_job_start(app.app, .{}, Job.work, Job.done, Job.destroy, j) != .ok) p.job = null;
}

fn nonEmpty(path: [:0]const u8) bool {
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, path, 0, .{ .SIZE = true }, &st)) == .SUCCESS and st.size > 0;
}

fn trimPartial(s: []const u8) []const u8 {
    // Drop a UTF-8 sequence cut off at the end.
    var end = s.len;
    var back: usize = 0;
    while (end > 0 and back < 4) : (back += 1) {
        const b = s[end - 1];
        if (b < 0x80) break;
        if (b >= 0xc0) {
            const len = std.unicode.utf8ByteSequenceLength(b) catch return s[0 .. end - 1];
            if (len > back + 1) return s[0 .. end - 1];
            break;
        }
        end -= 1;
    }
    return s;
}

fn stripCr(list: *std.ArrayList(u8)) void {
    var w: usize = 0;
    for (list.items, 0..) |ch, i| {
        if (ch == '\r' and i + 1 < list.items.len and list.items[i + 1] == '\n') continue;
        list.items[w] = ch;
        w += 1;
    }
    list.shrinkRetainingCapacity(w);
}

/// Removes ANSI escape sequences (colors from previewer commands).
fn stripAnsi(list: *std.ArrayList(u8)) void {
    var w: usize = 0;
    var i: usize = 0;
    const s = list.items;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !(s[i] >= 0x40 and s[i] <= 0x7e)) i += 1;
            i += 1;
            continue;
        }
        s[w] = s[i];
        w += 1;
        i += 1;
    }
    list.shrinkRetainingCapacity(w);
}

fn mkdirs(dir: []const u8) void {
    var buf: [linux.PATH_MAX]u8 = undefined;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = linux.mkdirat(linux.AT.FDCWD, z, 0o755);
        }
    }
}
