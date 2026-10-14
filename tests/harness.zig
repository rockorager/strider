//! Runs the file manager on siv's headless backend through siv's public
//! test API (D27): input injected as a compositor would deliver it,
//! settling until every frame is presented, the semantics tree a screen
//! reader sees, and captures compared with golden images.
//!
//! To accept new captures: SIV_UPDATE_GOLDEN=1 zig build test

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
pub const App = @import("app");
const png = @import("png.zig");

const testing = std.testing;

pub const golden_dir = "tests/golden";
const failure_dir = ".zig-cache/golden-failures";

const fonts = [_][]const u8{
    @embedFile("fonts/DroidSans.ttf"),
    @embedFile("fonts/DroidSansArabic.ttf"),
    @embedFile("fonts/DroidSansHebrew-Regular.ttf"),
};

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

/// A folder of files with fixed sizes and times, removed afterwards. Its
/// home has a trash, and the fixture's folder is "home".
pub const Fixture = struct {
    buf: [128]u8 = undefined,
    path: [:0]const u8 = "",

    pub const Item = struct { name: []const u8, size: usize = 0, dir: bool = false, mtime: i64 = 1_791_900_300, mode: u32 = 0o644 };

    /// Makes /tmp/siv-columns-test/NAME afresh: a fixed path, so that
    /// captures showing it are the same on every run.
    pub fn create(f: *Fixture, name: []const u8, items: []const Item) !void {
        const p = try std.fmt.bufPrintSentinel(&f.buf, "/tmp/siv-columns-test/{s}", .{name}, 0);
        var cmd: [512]u8 = undefined;
        const z = try std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}' && mkdir -p '{s}'", .{ p, p }, 0);
        if (system(z.ptr) != 0) return error.Unexpected;
        f.path = p;
        for (items) |it| try f.add(it);
    }

    pub fn add(f: *Fixture, it: Item) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, it.name }, 0);
        if (it.dir) {
            if (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o755)) != .SUCCESS) return error.Unexpected;
        } else {
            const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, it.mode);
            if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
            const fd: i32 = @intCast(rc);
            defer _ = linux.close(fd);
            var chunk: [4096]u8 = @splat('x');
            var left = it.size;
            while (left > 0) {
                const n = @min(left, chunk.len);
                _ = linux.write(fd, &chunk, n);
                left -= n;
            }
        }
        const ts = [2]linux.timespec{ .{ .sec = it.mtime, .nsec = 0 }, .{ .sec = it.mtime, .nsec = 0 } };
        _ = linux.utimensat(linux.AT.FDCWD, p, &ts, 0);
    }

    pub fn touch(f: *Fixture, name: []const u8, mtime: i64) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, name }, 0);
        const ts = [2]linux.timespec{ .{ .sec = mtime, .nsec = 0 }, .{ .sec = mtime, .nsec = 0 } };
        _ = linux.utimensat(linux.AT.FDCWD, p, &ts, 0);
    }

    pub fn writeFile(f: *Fixture, rel: []const u8, data: []const u8) !void {
        var buf: [512]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, rel }, 0);
        const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        _ = linux.write(fd, data.ptr, data.len);
    }

    pub fn sub(f: *const Fixture, buf: []u8, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ f.path, rel }) catch unreachable;
    }

    pub fn exists(f: *const Fixture, name: []const u8) bool {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ f.path, name }, 0) catch return false;
        var st: linux.Statx = undefined;
        return linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
    }

    pub fn remove(f: *Fixture) void {
        if (f.path.len == 0) return;
        var buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf '{s}'", .{f.path}, 0) catch return;
        _ = system(cmd.ptr);
    }
};

pub const Harness = struct {
    sapp: siv.App = .null,
    app: ?*App = null,
    win: ?*App.Window = null,
    /// The fixture's data home first, as the app has $XDG_DATA_HOME.
    data_dirs: [2][]const u8 = .{ "", "tests/data" },
    config_dirs: [1][]const u8 = .{""},
    config_buf: [256]u8 = undefined,
    state_buf: [256]u8 = undefined,
    data_home_buf: [256]u8 = undefined,
    cache_buf: [256]u8 = undefined,

    pub const Start = struct {
        /// The folder to show; its parent is home.
        path: []const u8,
        width: u32 = 1000,
        height: u32 = 560,
        rtl: bool = false,
        /// Keep state (bookmarks, history, column widths) under the home.
        state: bool = false,
        scheme: siv.ColorScheme = .light,
        contrast: siv.Contrast = .follow,
        hidden: bool = false,
        watch: bool = false,
        /// init.lua to run.
        config: ?[]const u8 = null,
        /// Show the which-key popup at once.
        which_key_now: bool = true,
        /// A private bus standing in for the system and session buses.
        bus: ?[]const u8 = null,
    };

    pub fn start(h: *Harness, s: Start) !void {
        try siv.check(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .no_system_fonts = true, .no_system_icons = true, .reduced_motion = true, .rtl = s.rtl } }, &h.sapp));
        for (fonts) |font| try siv.check(c.siv_app_add_font(h.sapp, "Droid", 5, font.ptr, font.len));
        try siv.check(c.siv_app_set_default_font(h.sapp, "Droid", 5));
        try siv.check(c.siv_app_set_theme(h.sapp, &.{ .scheme = s.scheme, .contrast = s.contrast }));
        const home = std.fs.path.dirname(s.path) orelse s.path;
        const config = try std.fmt.bufPrint(&h.config_buf, "{s}/.config", .{home});
        h.config_dirs[0] = config;
        const data_home = try std.fmt.bufPrint(&h.data_home_buf, "{s}/.local/share", .{home});
        h.data_dirs[0] = data_home;
        h.app = try App.create(h.sapp, .{
            .gpa = testing.allocator,
            .home = home,
            .config_home = config,
            .data_home = data_home,
            .cache_home = try std.fmt.bufPrint(&h.cache_buf, "{s}/.cache", .{home}),
            .data_dirs = &h.data_dirs,
            .config_dirs = &h.config_dirs,
            .watch = s.watch,
            .udisks = s.bus != null,
            .system_bus = s.bus,
            .session_bus = s.bus,
            .reproducible = true,
            .mount_table = false,
            .icon_dir = "icons",
            .config_file = s.config,
            .log_errors = false,
            .window_width = s.width,
            .window_height = s.height,
            .state_dir = if (s.state) try std.fmt.bufPrint(&h.state_buf, "{s}/.local/state/siv-columns", .{home}) else null,
        });
        const app = h.app.?;
        if (s.which_key_now) app.options.which_key_delay = 0;
        if (s.hidden) {
            app.options.show_hidden = true;
            app.applyViewOptions();
        }
        if (s.bus != null) app.startServices();
        h.win = try app.newWindow(s.path);
        try h.settle();
    }

    pub fn deinit(h: *Harness) void {
        if (h.app) |a| {
            a.destroy();
            // Let siv run the destroy-notifies of the closed windows.
            _ = c.siv_app_dispatch(h.sapp, 0);
        }
        if (h.sapp != .null) _ = c.siv_app_destroy(h.sapp);
    }

    pub fn window(h: *Harness) siv.Window {
        return h.win.?.window;
    }

    pub fn dir(h: *Harness) *App.Dir {
        return h.win.?.curDir();
    }

    /// The name under the cursor.
    pub fn hovered(h: *Harness) []const u8 {
        const d = h.dir();
        return d.nameAt(d.cursor) orelse "";
    }

    /// Dispatches until idle: every frame presented, nothing loading.
    pub fn settle(h: *Harness) !void {
        var settled = false;
        try siv.check(c.siv_test_settle(h.sapp, 10_000, &settled));
        if (!settled) return error.NotSettled;
    }

    /// Dispatches until `cond` holds (timers and other work the settle
    /// does not wait for), then settles.
    pub fn waitFor(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        try h.dispatchUntil(ctx, cond);
        try h.settle();
    }

    /// Dispatches until `cond` holds, without settling: for a state in
    /// which a job waits (a file operation asking about a conflict).
    pub fn dispatchUntil(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx)) bool) !void {
        var i: usize = 0;
        while (!cond(ctx)) : (i += 1) {
            if (i > 400) return error.Timeout;
            try siv.check(c.siv_app_dispatch(h.sapp, 25));
        }
        for (0..8) |_| try siv.check(c.siv_app_dispatch(h.sapp, 10));
    }

    pub fn key(h: *Harness, k: siv.Key, mods: siv.Modifiers, txt: []const u8) !void {
        try siv.check(c.siv_test_key(h.window(), k, mods, txt.ptr, txt.len));
        try h.settle();
    }

    /// Types keys as a user would, one key per character ("\n" is
    /// Enter, "\x1b" is Escape).
    pub fn typeText(h: *Harness, txt: []const u8) !void {
        var i: usize = 0;
        while (i < txt.len) {
            if (txt[i] == 0x1b) {
                try siv.check(c.siv_test_key(h.window(), .escape, .{}, "", 0));
                i += 1;
                continue;
            }
            var end = i;
            while (end < txt.len and txt[end] != 0x1b) end += 1;
            try siv.check(c.siv_test_type(h.window(), txt[i..end].ptr, end - i));
            i = end;
        }
        try h.settle();
    }

    pub fn find(_: *Harness, w: siv.Window, q: siv.TestQuery) ?siv.TestNode {
        var found = false;
        var node: siv.TestNode = .{};
        if (c.siv_test_find(w, &q, &found, &node) != .ok or !found) return null;
        return node;
    }

    /// The node with this role and name in the window, or fails with the
    /// tree.
    pub fn expect(h: *Harness, role: siv.Role, name: []const u8) !siv.TestNode {
        return h.find(h.window(), .{ .role = role, .name = name.ptr, .name_len = name.len }) orelse {
            std.debug.print("no {s} named “{s}”; the window reads:\n", .{ @tagName(role), name });
            h.dump(h.window());
            return error.NotFound;
        };
    }

    pub fn reads(h: *Harness, name: []const u8) bool {
        return h.find(h.window(), .{ .name = name.ptr, .name_len = name.len }) != null;
    }

    pub fn dump(h: *Harness, w: siv.Window) void {
        _ = h;
        const buf = testing.allocator.alloc(u8, 1 << 20) catch return;
        defer testing.allocator.free(buf);
        var len: usize = 0;
        if (c.siv_test_dump(w, buf.ptr, buf.len, &len) == .ok) std.debug.print("{s}\n", .{buf[0..@min(len, buf.len)]});
    }

    pub fn click(h: *Harness, w: siv.Window, n: siv.TestNode, button: siv.PointerButton) !void {
        const b = n.bounds;
        try siv.check(c.siv_test_click(w, b.x + @min(b.width / 2, 40), b.y + b.height / 2, button));
        try h.settle();
    }

    /// The newest popup (menu) window.
    pub fn popup(h: *Harness) siv.Window {
        return c.siv_test_get_popup(h.sapp);
    }

    /// Compares what `w` presented with tests/golden/NAME.png.
    pub fn expectGolden(h: *Harness, w: siv.Window, name: []const u8) !void {
        _ = h;
        const gpa = testing.allocator;
        var len: usize = 0;
        var width: u32 = 0;
        var height: u32 = 0;
        try siv.check(c.siv_test_capture(w, null, 0, &len, &width, &height));
        const pixels = try gpa.alloc(u8, len);
        defer gpa.free(pixels);
        try siv.check(c.siv_test_capture(w, pixels.ptr, pixels.len, &len, &width, &height));
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            const a = pixels[i + 3];
            if (a != 0 and a != 255) for (0..3) |k| {
                pixels[i + k] = @intCast(@min(255, @as(u32, pixels[i + k]) * 255 / a));
            };
        }
        var pbuf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&pbuf, "{s}/{s}.png", .{ golden_dir, name });
        const update = getenv("SIV_UPDATE_GOLDEN") != null;
        const io = testing.io;
        const cwd = std.Io.Dir.cwd();
        if (!update) blk: {
            const data = cwd.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |err| {
                if (err == error.FileNotFound) break :blk; // new: write it
                return err;
            };
            defer gpa.free(data);
            const img = try png.decode(gpa, data);
            defer img.deinit(gpa);
            if (img.width == width and img.height == height) {
                var bad: usize = 0;
                for (img.pixels, pixels) |x, y| {
                    if (@abs(@as(i32, x) - @as(i32, y)) > 3) bad += 1;
                }
                if (bad <= pixels.len / 2000) return;
                std.debug.print("{s}: {d} channels differ\n", .{ name, bad });
            } else std.debug.print("{s}: {d}×{d}, golden {d}×{d}\n", .{ name, width, height, img.width, img.height });
            cwd.createDirPath(io, failure_dir) catch {};
            var fbuf: [256]u8 = undefined;
            const fpath = try std.fmt.bufPrint(&fbuf, "{s}/{s}.png", .{ failure_dir, name });
            const enc = try png.encode(gpa, width, height, pixels);
            defer gpa.free(enc);
            try cwd.writeFile(io, .{ .sub_path = fpath, .data = enc });
            std.debug.print("wrote {s}; SIV_UPDATE_GOLDEN=1 accepts it\n", .{fpath});
            return error.GoldenMismatch;
        }
        cwd.createDirPath(io, golden_dir) catch {};
        const enc = try png.encode(gpa, width, height, pixels);
        defer gpa.free(enc);
        try cwd.writeFile(io, .{ .sub_path = path, .data = enc });
    }
};
