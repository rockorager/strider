//! Running other programs and waiting for them, from worker threads:
//! archive listings (bsdtar), PDF pages (pdftoppm), shell commands, and
//! the editor for bulk renames. Only async-signal-safe calls happen
//! between fork and exec.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

extern "c" fn fork() c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setsid() c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;

pub const Result = struct {
    /// The exit status, or 128 plus the signal, or 127 if it could not run.
    status: u8,
    /// Standard output and error, at most the limit asked for.
    output: []u8,
    /// More output was cut off.
    truncated: bool = false,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        gpa.free(r.output);
    }
};

pub const Options = struct {
    cwd: ?[]const u8 = null,
    /// Keep at most this much output; the rest is read and dropped.
    max_output: usize = 64 * 1024,
    /// Stop reading (and kill the program) after this much output.
    kill_after: ?usize = null,
    /// Standard input from /dev/null rather than this process's.
    null_stdin: bool = true,
};

/// Runs `argv` (searched on $PATH) to completion, collecting what it
/// writes. Blocking.
pub fn run(gpa: Allocator, argv: []const []const u8, opts: Options) !Result {
    if (argv.len == 0) return error.InvalidArgument;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cargv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |x, i| cargv[i] = try arena.dupeSentinel(u8, x, 0);
    const ccwd: ?[:0]u8 = if (opts.cwd) |d| try arena.dupeSentinel(u8, d, 0) else null;
    var fds: [2]c_int = undefined;
    if (pipe2(&fds, 0o2000000) != 0) return error.Unavailable; // O_CLOEXEC
    const pid = fork();
    if (pid < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        return error.Unavailable;
    }
    if (pid == 0) {
        _ = dup2(fds[1], 1);
        _ = dup2(fds[1], 2);
        if (opts.null_stdin) {
            const devnull = open("/dev/null", 0);
            if (devnull >= 0) _ = dup2(devnull, 0);
        }
        if (ccwd) |d| _ = chdir(d.ptr);
        _ = execvp(cargv[0].?, cargv.ptr);
        _exit(127);
    }
    _ = close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var truncated = false;
    var total: usize = 0;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = read(fds[0], &buf, buf.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            break;
        }
        if (n == 0) break;
        const got: usize = @intCast(n);
        total += got;
        const room = opts.max_output -| out.items.len;
        if (got > room) truncated = true;
        try out.appendSlice(gpa, buf[0..@min(got, room)]);
        if (opts.kill_after) |k| if (total >= k) {
            _ = kill(pid, 15);
            truncated = true;
            break;
        };
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    const s: u32 = @bitCast(status);
    const code: u8 = if (s & 0x7f == 0) @intCast((s >> 8) & 0xff) else @intCast(128 + (s & 0x7f));
    return .{ .status = code, .output = try out.toOwnedSlice(gpa), .truncated = truncated };
}

/// Whether `prog` is an executable on $PATH.
pub fn onPath(prog: []const u8) bool {
    const S = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    };
    if (std.mem.indexOfScalar(u8, prog, '/') != null) {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}", .{prog}, 0) catch return false;
        return linux.errno(linux.faccessat(linux.AT.FDCWD, p, linux.X_OK, 0)) == .SUCCESS;
    }
    const path = if (S.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, prog }, 0) catch continue;
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, p, linux.X_OK, 0)) == .SUCCESS) return true;
    }
    return false;
}

test "runs a program and collects its output and status" {
    var r = try run(std.testing.allocator, &.{ "sh", "-c", "echo hi; echo err >&2; exit 3" }, .{});
    defer r.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 3), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "hi\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "err\n") != null);
    var missing = try run(std.testing.allocator, &.{"/nonexistent/program"}, .{});
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 127), missing.status);
}
