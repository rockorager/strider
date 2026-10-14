//! Measurements of the file manager on siv's headless backend, through
//! siv's public API (`zig build bench`, ReleaseSafe by default): startup
//! to the first frame and to the first frame with the folder's rows,
//! memory, idle wakeups, and navigating, searching, marking, sorting, and
//! filtering a folder of 100 000 entries with the keys a user presses.
//! Prints numbers; README.md records them.

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");
const siv = @import("siv");
const c = siv.c;
const App = @import("app");

const entries = 100_000;

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn mib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

/// CPU time of the calling (UI) thread.
fn threadCpu() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// A field of /proc/self/status in kB, as bytes.
fn status(key: []const u8) u64 {
    var buf: [4096]u8 = undefined;
    const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, "/proc/self/status", .{ .CLOEXEC = true }, 0));
    defer _ = linux.close(fd);
    const n = linux.read(fd, &buf, buf.len);
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        var it = std.mem.tokenizeAny(u8, line[key.len..], " \t:kB");
        return (std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0) * 1024;
    }
    return 0;
}

/// Context switches of every thread: each is a wakeup or a preemption.
fn switches() u64 {
    var total: u64 = 0;
    const dfd: i32 = @intCast(linux.openat(linux.AT.FDCWD, "/proc/self/task", .{ .DIRECTORY = true, .CLOEXEC = true }, 0));
    defer _ = linux.close(dfd);
    var dbuf: [8192]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(dfd, &dbuf, dbuf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&dbuf[off]);
            const name: [*:0]const u8 = @ptrCast(&dbuf[off + @offsetOf(linux.dirent64, "name")]);
            off += d.reclen;
            const tid = std.mem.span(name);
            if (tid[0] == '.') continue;
            var pbuf: [64]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&pbuf, "/proc/self/task/{s}/status", .{tid}, 0) catch continue;
            const rc = linux.openat(linux.AT.FDCWD, p, .{ .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) continue;
            const fd: i32 = @intCast(rc);
            defer _ = linux.close(fd);
            var sbuf: [4096]u8 = undefined;
            const sn = linux.read(fd, &sbuf, sbuf.len);
            var lines = std.mem.splitScalar(u8, sbuf[0..sn], '\n');
            while (lines.next()) |line| for ([_][]const u8{ "voluntary_ctxt_switches:", "nonvoluntary_ctxt_switches:" }) |key| {
                if (std.mem.startsWith(u8, line, key)) total += std.fmt.parseInt(u64, std.mem.trim(u8, line[key.len..], " \t"), 10) catch 0;
            };
        }
    }
    return total;
}

fn makeFolder(path: [:0]const u8, n: usize) !void {
    if (linux.errno(linux.mkdirat(linux.AT.FDCWD, path, 0o755)) != .SUCCESS) return error.Mkdir;
    var buf: [256]u8 = undefined;
    for (0..n) |i| {
        // Varied names, sizes, and kinds, as in a real download folder.
        const ext = [_][]const u8{ "txt", "pdf", "png", "zig", "tar.gz", "flac", "md" };
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/file-{d}.{s}", .{ path, i, ext[i % ext.len] }, 0);
        const fd: i32 = @intCast(linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true }, 0o644));
        if (i % 3 == 0) _ = linux.ftruncate(fd, @intCast(i * 37));
        _ = linux.close(fd);
        if (i % 1000 == 0) {
            const d = try std.fmt.bufPrintSentinel(&buf, "{s}/folder-{d}", .{ path, i }, 0);
            _ = linux.mkdirat(linux.AT.FDCWD, d, 0o755);
        }
    }
}

extern "c" fn system(cmd: [*:0]const u8) c_int;

const MallInfo2 = extern struct { arena: usize, ordblks: usize, smblks: usize, hblks: usize, hblkhd: usize, usmblks: usize, fsmblks: usize, uordblks: usize, fordblks: usize, keepcost: usize };
extern "c" fn mallinfo2() MallInfo2;

/// Bytes malloc has handed out and not had back.
fn heapInUse() u64 {
    const m = mallinfo2();
    return m.uordblks + m.hblkhd;
}

fn removeFolder(path: []const u8) void {
    var buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf '{s}'", .{path}, 0) catch return;
    _ = system(cmd.ptr);
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("bench: " ++ fmt ++ "\n", args);
}

/// The application on the headless backend, with the system's fonts and
/// icons as the program uses them.
const Run = struct {
    sapp: siv.App = .null,
    app: *App = undefined,
    win: *App.Window = undefined,

    fn start(r: *Run, folder: []const u8, home: []const u8, height: u32) !void {
        return r.startWith(folder, home, height, null);
    }

    fn startWith(r: *Run, folder: []const u8, home: []const u8, height: u32, config: ?[]const u8) !void {
        try siv.check(c.siv_app_create(&.{ .backend = .headless, .flags = .{ .reduced_motion = true } }, &r.sapp));
        r.app = try App.create(r.sapp, .{
            .gpa = std.heap.c_allocator,
            .home = home,
            .config_home = "/nonexistent",
            .data_home = home,
            .cache_home = "/nonexistent",
            .data_dirs = &.{"/usr/share"},
            .watch = true,
            .udisks = false,
            .mount_table = false,
            .icon_dir = "icons",
            .window_height = height,
            .config_file = config,
        });
        r.app.options.which_key_delay = 0;
        r.win = try r.app.newWindow(folder);
    }

    fn settle(r: *Run) !void {
        var settled = false;
        try siv.check(c.siv_test_settle(r.sapp, 30_000, &settled));
        if (!settled) return error.NotSettled;
    }

    fn typeKeys(r: *Run, text: []const u8) !void {
        try siv.check(c.siv_test_type(r.win.window, text.ptr, text.len));
        try r.settle();
    }

    fn key(r: *Run, k: siv.Key, mods: siv.Modifiers, text: []const u8) !void {
        try siv.check(c.siv_test_key(r.win.window, k, mods, text.ptr, text.len));
        try r.settle();
    }

    fn stop(r: *Run) void {
        r.app.destroy();
        _ = c.siv_app_dispatch(r.sapp, 0);
        _ = c.siv_app_destroy(r.sapp);
    }
};

/// Runs `f` and reports its UI thread CPU and wall time.
fn timed(r: *Run, comptime label: []const u8, keys_text: []const u8) !void {
    const c0 = threadCpu();
    const w0 = now();
    try r.typeKeys(keys_text);
    report(label ++ ": UI thread CPU {d:.2} ms, {d:.1} ms wall", .{ ms(threadCpu() - c0), ms(now() - w0) });
}

pub fn main() !void {
    if (builtin.mode == .debug) report("warning: a Debug build; use -Doptimize=safe or fast", .{});
    var dir_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/siv-columns-bench-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdirat(linux.AT.FDCWD, base, 0o755);
    defer removeFolder(base);
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrintSentinel(&root_buf, "{s}/big", .{base}, 0);
    var small_buf: [160]u8 = undefined;
    const small = try std.fmt.bufPrintSentinel(&small_buf, "{s}/small", .{base}, 0);
    try makeFolder(small, 40);
    const t_make = now();
    try makeFolder(root, entries);
    report("made {d} files and {d} folders in {d:.0} ms", .{ entries, entries / 1000, ms(now() - t_make) });

    // Startup with a small folder: siv, the application, its window, the
    // first frame, and the first frame with the folder's rows.
    {
        const rss0 = status("VmRSS");
        var r: Run = .{};
        const t0 = now();
        const cpu0 = threadCpu();
        try r.start(small, base, 720);
        while (r.win.rows_frame_ns == 0) {
            try siv.check(c.siv_app_dispatch(r.sapp, 1));
            if (now() - t0 > 10 * std.time.ns_per_s) return error.Timeout;
        }
        const cpu = threadCpu() - cpu0;
        report("startup (40 entries): first frame {d:.1} ms, first frame with rows {d:.1} ms, UI thread CPU {d:.1} ms", .{ ms(r.win.first_frame_ns - t0), ms(r.win.rows_frame_ns - t0), ms(cpu) });
        try r.settle();
        base_heap = heapInUse();
        report("memory with the window open: {d:.1} MiB resident (the process grew {d:.1} MiB), heap in use {d:.1} MiB", .{ mib(status("VmRSS")), mib(status("VmRSS") -| rss0), mib(base_heap) });
        const sw0 = switches();
        const t_idle = now();
        while (now() - t_idle < 2 * std.time.ns_per_s) try siv.check(c.siv_app_dispatch(r.sapp, 2000));
        report("idle for 2 s: {d} context switches over all threads (the bench's own 2 s timeout is one)", .{switches() - sw0});
        r.stop();
    }

    // The same with the example configuration (data/init.lua): a Lua
    // state, keymaps, commands, and a previewer.
    {
        var r: Run = .{};
        const t0 = now();
        try r.startWith(small, base, 720, "data/init.lua");
        while (r.win.rows_frame_ns == 0) {
            try siv.check(c.siv_app_dispatch(r.sapp, 1));
            if (now() - t0 > 10 * std.time.ns_per_s) return error.Timeout;
        }
        report("startup with data/init.lua: first frame with rows {d:.1} ms", .{ms(r.win.rows_frame_ns - t0)});
        try r.settle();
        r.stop();
    }

    // The big folder.
    var r: Run = .{};
    const t0 = now();
    try r.start(root, base, 720);
    defer r.stop();
    var loaded: u64 = 0;
    while (loaded == 0 or r.win.rows_frame_ns == 0) {
        try siv.check(c.siv_app_dispatch(r.sapp, 1));
        if (loaded == 0 and r.win.curDir().loaded) loaded = now();
        if (now() - t0 > 60 * std.time.ns_per_s) return error.Timeout;
    }
    try r.settle();
    report("{d} entries: first frame {d:.1} ms, read and sorted {d:.1} ms, rows shown {d:.1} ms", .{ r.win.curDir().count(), ms(r.win.first_frame_ns - t0), ms(loaded - t0), ms(r.win.rows_frame_ns - t0) });
    const listed = heapInUse() -| base_heap;
    report("memory: {d:.1} MiB resident, heap in use {d:.1} MiB more than with 40 entries ({d:.0} bytes per entry)", .{ mib(status("VmRSS")), mib(listed), @as(f64, @floatFromInt(listed)) / entries });

    // j, one key at a time, each settled (its frame presented, its
    // preview read) before the next: UI thread CPU per key bounds how
    // fast keys can repeat.
    {
        const steps = 300;
        var worst: u64 = 0;
        var total_cpu: u64 = 0;
        const w0 = now();
        for (0..steps) |_| {
            const c0 = threadCpu();
            try r.typeKeys("j");
            const cpu = threadCpu() - c0;
            total_cpu += cpu;
            worst = @max(worst, cpu);
        }
        report("j x{d} (cursor and preview each time): UI thread CPU {d:.2} ms per key on average, {d:.2} ms worst; {d:.1} ms wall per settled key (the headless backend's 60 Hz vblanks)", .{ steps, ms(total_cpu / steps), ms(worst), ms((now() - w0) / steps) });
    }
    // Held keys: 100 j's queued at once, as key repeat delivers them.
    const hundred: [100]u8 = @splat('j');
    try timed(&r, "100 j's queued at once (key repeat)", &hundred);
    try timed(&r, "G (to the last of 100 100)", "G");
    try timed(&r, "gg", "gg");
    {
        var worst: u64 = 0;
        var total: u64 = 0;
        for (0..100) |_| {
            const c0 = threadCpu();
            try r.key(@enumFromInt('f'), .{ .ctrl = true }, "\x06");
            const cpu = threadCpu() - c0;
            total += cpu;
            worst = @max(worst, cpu);
        }
        report("Ctrl+F (page down) x100: UI thread CPU {d:.2} ms per page on average, {d:.2} ms worst", .{ ms(total / 100), ms(worst) });
    }
    try timed(&r, "/ search typed \"file-99999\" (every keystroke searches 100 100 names) and Enter", "/file-99999\n");
    try timed(&r, "n (next match, wrapping)", "n");
    try timed(&r, "h to the parent, l back in (cached)", "hl");
    {
        const c0 = threadCpu();
        const w0 = now();
        try r.key(@enumFromInt('a'), .{ .ctrl = true }, "\x01");
        report("Ctrl+A marking all {d}: UI thread CPU {d:.1} ms, {d:.1} ms wall", .{ r.win.curDir().mark_count, ms(threadCpu() - c0), ms(now() - w0) });
    }
    try timed(&r, "Escape (unmark all)", "\x1b");
    try timed(&r, "sS (sort by size, largest first, keeping the cursor's entry)", "sS");
    try timed(&r, "sn (by name again)", "sn");
    try timed(&r, "zh (hidden files on)", "zh");
    try timed(&r, "zf filter typed \"-12\" and Enter", "zf-12\n");
    report("filtered to {d} entries", .{r.win.curDir().count()});
    report("peak memory {d:.1} MiB", .{mib(status("VmHWM"))});
}

/// The heap in use with a 40-entry folder shown.
var base_heap: u64 = 0;
