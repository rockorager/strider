//! What can be undone: created folders and files, renames (one, or a
//! batch as one step), and copies, moves, trashes, and restores, as the
//! (from, to) pairs their operations recorded. Deleting permanently cannot
//! be undone and is not recorded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fsops = @import("fsops.zig");

pub const Kind = enum { created, renamed, copied, moved, trashed, restored };

pub const Pair = struct { from: []u8, to: []u8 };

pub const Step = struct {
    kind: Kind,
    pairs: []Pair,

    /// "Undo Move to Trash", for menus.
    pub fn label(s: *const Step) []const u8 {
        return switch (s.kind) {
            .created => "Undo New Folder",
            .renamed => "Undo Rename",
            .copied => "Undo Copy",
            .moved => "Undo Move",
            .trashed => "Undo Move to Trash",
            .restored => "Undo Restore",
        };
    }
};

pub const Stack = struct {
    gpa: Allocator,
    steps: std.ArrayList(Step) = .empty,

    const max_steps = 50;

    pub fn deinit(s: *Stack) void {
        for (s.steps.items) |*st| freeStep(s.gpa, st);
        s.steps.deinit(s.gpa);
    }

    pub fn top(s: *const Stack) ?*const Step {
        if (s.steps.items.len == 0) return null;
        return &s.steps.items[s.steps.items.len - 1];
    }

    /// Takes the newest step; the caller frees it with `free`.
    pub fn pop(s: *Stack) ?Step {
        return s.steps.pop();
    }

    pub fn free(s: *Stack, st: *Step) void {
        freeStep(s.gpa, st);
    }

    fn push(s: *Stack, kind: Kind, pairs: []const [2][]const u8) void {
        const gpa = s.gpa;
        const owned = gpa.alloc(Pair, pairs.len) catch return;
        var n: usize = 0;
        while (n < pairs.len) : (n += 1) {
            const f = gpa.dupe(u8, pairs[n][0]) catch break;
            const t = gpa.dupe(u8, pairs[n][1]) catch {
                gpa.free(f);
                break;
            };
            owned[n] = .{ .from = f, .to = t };
        }
        if (n != pairs.len) {
            for (owned[0..n]) |p| {
                gpa.free(p.from);
                gpa.free(p.to);
            }
            gpa.free(owned);
            return;
        }
        if (s.steps.items.len >= max_steps) {
            var oldest = s.steps.orderedRemove(0);
            freeStep(gpa, &oldest);
        }
        s.steps.append(gpa, .{ .kind = kind, .pairs = owned }) catch {
            var st: Step = .{ .kind = kind, .pairs = owned };
            freeStep(gpa, &st);
        };
    }

    pub fn pushCreated(s: *Stack, path: []const u8) void {
        s.push(.created, &.{.{ path, path }});
    }

    pub fn pushRenames(s: *Stack, pairs: []const [2][]const u8) void {
        if (pairs.len != 0) s.push(.renamed, pairs);
    }

    /// Records a finished operation's pairs (replacements cannot be
    /// undone and are left out of copies).
    pub fn pushOp(s: *Stack, op: *const fsops.Op) void {
        const kind: Kind = switch (op.kind) {
            .copy, .link => .copied,
            .move => .moved,
            .trash => .trashed,
            .restore => .restored,
            .delete, .move_back, .chmod, .chown => return,
        };
        var pairs: std.ArrayList([2][]const u8) = .empty;
        defer pairs.deinit(s.gpa);
        for (op.done.items) |d| {
            if (kind == .copied and d.replaced) continue;
            pairs.append(s.gpa, .{ d.from, d.to }) catch return;
        }
        if (pairs.items.len != 0) s.push(kind, pairs.items);
    }
};

fn freeStep(gpa: Allocator, st: *Step) void {
    for (st.pairs) |p| {
        gpa.free(p.from);
        gpa.free(p.to);
    }
    gpa.free(st.pairs);
}
