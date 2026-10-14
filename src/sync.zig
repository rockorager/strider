//! A mutex and a one-shot event on Linux futexes, for the few places
//! where worker jobs and the UI thread share state (Zig 0.17's std moved
//! its primitives behind std.Io, which siv's worker threads do not have).

const std = @import("std");
const linux = std.os.linux;

pub const Mutex = struct {
    /// 0 unlocked, 1 locked, 2 locked with waiters.
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(m: *Mutex) void {
        if (m.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) return;
        while (m.state.swap(2, .acquire) != 0) {
            _ = linux.futex_4arg(&m.state.raw, .{ .cmd = .WAIT, .private = true }, 2, null);
        }
    }

    pub fn unlock(m: *Mutex) void {
        if (m.state.swap(0, .release) == 2) {
            _ = linux.futex_3arg(&m.state.raw, .{ .cmd = .WAKE, .private = true }, 1);
        }
    }
};

/// A value one thread waits for and another sets once.
pub const Event = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn wait(e: *Event) void {
        while (e.state.load(.acquire) == 0) {
            _ = linux.futex_4arg(&e.state.raw, .{ .cmd = .WAIT, .private = true }, 0, null);
        }
    }

    pub fn set(e: *Event) void {
        e.state.store(1, .release);
        _ = linux.futex_3arg(&e.state.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    }

    pub fn reset(e: *Event) void {
        e.state.store(0, .release);
    }
};

test "mutex and event" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();
    var e: Event = .{};
    e.set();
    e.wait();
}
