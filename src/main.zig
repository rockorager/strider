//! siv-columns: a keyboard-driven, ranger-style file manager for Wayland,
//! built on siv.
//!
//!     siv-columns [FOLDER or FILE ...] [--new-window] [--hidden]
//!         [--dark | --light] [--rtl] [--clean]
//!
//! One instance serves every window: a second launch hands its folders to
//! the first and exits. A file on the command line is shown under the
//! cursor in its folder.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const App = @import("App.zig");
const uri = @import("uri.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern "c" fn free(ptr: ?*anyopaque) void;

/// libsiv needs no alternate signal stack per thread; neither do we.
pub const std_options: std.Options = .{ .signal_stack_size = null };

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}

const usage =
    \\usage: siv-columns [FOLDER or FILE ...] [options]
    \\
    \\  --new-window      open a new window even if one is open
    \\  --hidden          show hidden files
    \\  --dark, --light   choose the style instead of following the desktop
    \\  --rtl             lay out right to left
    \\  --clean           do not run init.lua
    \\  --config FILE     run FILE instead of $XDG_CONFIG_HOME/siv-columns/init.lua
    \\  --service         started by D-Bus activation
    \\  --version         print the version
    \\
    \\Keys: g? or F1 lists them; : opens the command line.
    \\
;

const Startup = struct {
    app: *App,
    new_window: bool,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.c_allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var flags: siv.AppFlags = .{};
    var scheme: siv.ColorScheme = .follow;
    var new_window = false;
    var service = false;
    var hidden = false;
    var clean = false;
    var config_override: ?[]const u8 = null;
    var paths: std.ArrayList([]const u8) = .empty;
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--hidden")) {
            hidden = true;
        } else if (std.mem.eql(u8, a, "--dark")) {
            scheme = .dark;
        } else if (std.mem.eql(u8, a, "--light")) {
            scheme = .light;
        } else if (std.mem.eql(u8, a, "--rtl")) {
            flags.rtl = true;
        } else if (std.mem.eql(u8, a, "--clean")) {
            clean = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("siv-columns: --config needs a file\n", .{});
                return 2;
            }
            config_override = args[i];
        } else if (std.mem.eql(u8, a, "--new-window")) {
            new_window = true;
        } else if (std.mem.eql(u8, a, "--service") or std.mem.eql(u8, a, "--gapplication-service")) {
            service = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("siv-columns 0.1.0\n", .{});
            return 0;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.startsWith(u8, a, "--")) {
            std.debug.print("siv-columns: unknown option {s}\n{s}", .{ a, usage });
            return 2;
        } else {
            try paths.append(arena, a);
        }
    }

    const home = env("HOME") orelse "/";
    var data_dirs: std.ArrayList([]const u8) = .empty;
    try data_dirs.append(arena, env("XDG_DATA_HOME") orelse try std.fmt.allocPrint(arena, "{s}/.local/share", .{home}));
    var it = std.mem.tokenizeScalar(u8, env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (it.next()) |d| try data_dirs.append(arena, d);
    var config_dirs: std.ArrayList([]const u8) = .empty;
    const config_home = env("XDG_CONFIG_HOME") orelse try std.fmt.allocPrint(arena, "{s}/.config", .{home});
    try config_dirs.append(arena, config_home);
    it = std.mem.tokenizeScalar(u8, env("XDG_CONFIG_DIRS") orelse "/etc/xdg", ':');
    while (it.next()) |d| try config_dirs.append(arena, d);
    var desktops: std.ArrayList([]const u8) = .empty;
    it = std.mem.tokenizeScalar(u8, env("XDG_CURRENT_DESKTOP") orelse "", ':');
    while (it.next()) |d| try desktops.append(arena, try std.ascii.allocLowerString(arena, d));
    const state_home = env("XDG_STATE_HOME") orelse try std.fmt.allocPrint(arena, "{s}/.local/state", .{home});

    // URIs for the command line's paths, resolved against the working
    // directory.
    var uris: std.ArrayList(siv.Uri) = .empty;
    for (paths.items) |p| {
        var list: std.ArrayList(u8) = .empty;
        if (std.mem.indexOf(u8, p, "://") != null) {
            try list.appendSlice(arena, p);
        } else {
            const z = try arena.dupeSentinel(u8, p, 0);
            const resolved = realpath(z.ptr, null);
            defer if (resolved) |r| free(r);
            try uri.appendFileUri(&list, arena, if (resolved) |r| std.mem.span(r) else p);
        }
        try uris.append(arena, .{ .uri = list.items.ptr, .uri_len = list.items.len });
    }

    var sapp: siv.App = .null;
    var r = c.siv_app_create(&.{ .flags = flags, .name = "Columns", .name_len = 7, .app_id = App.app_id, .app_id_len = App.app_id.len }, &sapp);
    if (r != .ok) {
        std.debug.print("siv-columns: cannot start: {s}\n", .{std.mem.span(c.siv_result_name(r))});
        return 1;
    }
    defer _ = c.siv_app_destroy(sapp);
    if (scheme != .follow) _ = c.siv_app_set_theme(sapp, &.{ .scheme = scheme });

    var icon_buf: [4096]u8 = undefined;
    const config_file = if (clean) null else config_override orelse try std.fmt.allocPrint(arena, "{s}/" ++ App.program ++ "/init.lua", .{config_home});
    const app = App.create(sapp, .{
        .gpa = gpa,
        .home = home,
        .config_home = env("XDG_CONFIG_HOME"),
        .data_home = env("XDG_DATA_HOME"),
        .cache_home = env("XDG_CACHE_HOME"),
        .state_home = state_home,
        .data_dirs = data_dirs.items,
        .config_dirs = config_dirs.items,
        .desktops = desktops.items,
        .tz_offset_s = localOffset(),
        .icon_dir = iconDir(&icon_buf),
        .config_file = config_file,
        .state_dir = try std.fmt.allocPrint(arena, "{s}/" ++ App.program, .{state_home}),
    }) catch |err| {
        std.debug.print("siv-columns: cannot start: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer app.destroy();
    if (hidden) {
        app.options.show_hidden = true;
        app.applyViewOptions();
    }

    var startup: Startup = .{ .app = app, .new_window = new_window };
    _ = c.siv_app_add_action(sapp, "new-window", 10, onNewWindowAction, null, app);
    r = c.siv_app_launch(sapp, &.{
        .uris = uris.items.ptr,
        .uris_count = uris.items.len,
        .on_activate = onActivate,
        .user_data = &startup,
        .flags = .{ .service = service },
        .idle_timeout_ms = if (service) 30_000 else 0,
    });
    if (r != .ok) {
        std.debug.print("siv-columns: cannot launch: {s}\n", .{std.mem.span(c.siv_result_name(r))});
        return 1;
    }
    // The application's services on the session bus.
    app.startServices();
    r = c.siv_app_run(sapp);
    if (r != .ok) {
        std.debug.print("siv-columns: {s}\n", .{std.mem.span(c.siv_result_name(r))});
        return 1;
    }
    return 0;
}

/// Every activation lands here: this launch's, another instance's, or the
/// desktop's.
fn onActivate(ud: ?*anyopaque, _: siv.App, act: *const siv.Activation) callconv(.c) void {
    const s: *Startup = @ptrCast(@alignCast(ud.?));
    const app = s.app;
    const token = if (act.activation_token) |t| t[0..act.activation_token_len] else "";
    if (act.type == .open and act.uris_count > 0) {
        var list: std.ArrayList([]const u8) = .empty;
        defer {
            for (list.items) |p| app.gpa.free(p);
            list.deinit(app.gpa);
        }
        for (act.uris.?[0..act.uris_count]) |u| {
            const text = u.uri.?[0..u.uri_len];
            var buf: [linux.PATH_MAX]u8 = undefined;
            const p = uri.filePath(&buf, text) orelse continue;
            list.append(app.gpa, app.gpa.dupe(u8, p) catch continue) catch {};
        }
        app.showPaths(list.items, s.new_window and act.source == .launch, token);
        return;
    }
    // A plain launch: a window, a new one when asked or when another
    // instance asked for one.
    if (app.windows.items.len == 0 or s.new_window or act.source == .remote) {
        const cwd = currentDir(app);
        const w = app.newWindow(cwd) catch return;
        _ = c.siv_window_activate(w.window, token.ptr, token.len);
        return;
    }
    if (app.lastWindow()) |w| _ = c.siv_window_activate(w.window, token.ptr, token.len);
}

/// Started from a terminal: its folder; from a launcher: home.
fn currentDir(app: *App) []const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    const n = linux.getcwd(&S.buf, S.buf.len);
    if (linux.errno(n) != .SUCCESS) return app.home;
    const cwd = std.mem.sliceTo(&S.buf, 0);
    if (std.mem.eql(u8, cwd, "/")) return app.home;
    return cwd;
}

fn onNewWindowAction(ud: ?*anyopaque, _: *const siv.ActionEvent) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ud.?));
    _ = app.newWindow(app.home) catch {};
}

/// share/siv-columns/icons beside the executable's bin directory.
fn iconDir(buf: []u8) ?[]const u8 {
    var exe: [4096]u8 = undefined;
    const n = linux.readlink("/proc/self/exe", &exe, exe.len);
    if (linux.errno(n) != .SUCCESS) return null;
    const bin = std.fs.path.dirname(exe[0..n]) orelse return null;
    const prefix = std.fs.path.dirname(bin) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/share/" ++ App.program ++ "/icons", .{prefix}) catch null;
}

/// The local time zone's offset from UTC now, in seconds, from libc.
fn localOffset() i64 {
    const tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
    const S = struct {
        extern "c" fn time(t: ?*i64) i64;
        extern "c" fn localtime_r(t: *const i64, out: *tm) ?*tm;
    };
    var now = S.time(null);
    var out: tm = undefined;
    if (S.localtime_r(&now, &out) == null) return 0;
    return out.gmtoff;
}
