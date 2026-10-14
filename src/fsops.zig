//! File operations: copy, move, move to the trash, restore from the trash,
//! and delete. `Op.run` blocks and runs on a worker thread of siv's pool
//! (siv_job_start); the UI thread reads its progress from atomics, asks it
//! to stop with `cancel`, and answers its questions about conflicts.
//!
//! A conflict (the target name exists) stops the worker until the UI
//! answers through `answer`: replace, skip, keep both (a free name with
//! " (2)" before the extension), merge two folders, or cancel; the answer
//! can apply to every later conflict of the operation. Copies into the
//! folder the files come from keep both without asking (duplicates).
//!
//! Every operation records what it did as (from, to) pairs, which undo
//! reverses.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const sync = @import("sync.zig");

/// `move_back` moves each source to the exact path in `targets` (undoing
/// a move); `restore` does the same from the trash and removes the info
/// files.
pub const Kind = enum { copy, move, trash, delete, restore, move_back, chmod, chown };

/// "Copying", for progress.
pub fn doing(kind: Kind) []const u8 {
    return switch (kind) {
        .copy => "Copying",
        .move, .move_back => "Moving",
        .trash => "Trashing",
        .delete => "Deleting",
        .restore => "Restoring",
        .chmod => "Changing permissions",
        .chown => "Changing owners",
    };
}

/// "copy", for "Could not copy …".
pub fn verb(kind: Kind) []const u8 {
    return switch (kind) {
        .copy => "copy",
        .move, .move_back => "move",
        .trash => "move to the trash",
        .delete => "delete",
        .restore => "restore",
        .chmod => "change the permissions of",
        .chown => "change the owner of",
    };
}

pub const Error = error{
    Canceled,
    FileNotFound,
    AccessDenied,
    NoSpace,
    Exists,
    InvalidName,
    IntoItself,
    NameTooLong,
    NotEmpty,
    CrossDevice,
    OutOfMemory,
    Unexpected,
};

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.Canceled => "Canceled",
        error.FileNotFound => "No such file or folder",
        error.AccessDenied => "Permission denied",
        error.NoSpace => "No space left on the device",
        error.Exists => "A file with that name already exists",
        error.InvalidName => "Names cannot be empty or contain “/”",
        error.IntoItself => "A folder cannot be copied or moved into itself",
        error.NameTooLong => "The name is too long",
        error.NotEmpty => "The folder is not empty",
        error.CrossDevice => "It is on another device",
        error.OutOfMemory => "Out of memory",
        error.Unexpected => "Unexpected error",
    };
}

pub const Resolution = enum(u32) { none = 0, replace, skip, keep_both, merge, cancel };

/// What the UI is asked about: `src` would land on `dst`, which exists.
pub const Conflict = struct {
    src: [linux.PATH_MAX]u8 = undefined,
    src_len: usize = 0,
    dst: [linux.PATH_MAX]u8 = undefined,
    dst_len: usize = 0,
    src_dir: bool = false,
    dst_dir: bool = false,
    src_size: u64 = 0,
    dst_size: u64 = 0,
    src_mtime: i64 = 0,
    dst_mtime: i64 = 0,

    pub fn srcPath(c: *const Conflict) []const u8 {
        return c.src[0..c.src_len];
    }
    pub fn dstPath(c: *const Conflict) []const u8 {
        return c.dst[0..c.dst_len];
    }
};

/// One thing an operation did, for undo.
pub const Done = struct {
    from: []u8,
    to: []u8,
    /// A copy that replaced an existing file (undo cannot bring it back).
    replaced: bool = false,
};

pub const Op = struct {
    gpa: Allocator,
    kind: Kind,
    /// Absolute paths (owned).
    sources: [][]u8,
    /// The destination folder for copy and move (owned), else empty.
    dest: []u8,
    /// Restore and move_back: where each source goes (owned, parallel to
    /// sources).
    targets: [][]u8 = &.{},
    /// The home trash ($XDG_DATA_HOME/Trash).
    home_trash: []u8 = &.{},
    /// chmod: what to do to the permissions, as chmod(1) takes it (owned;
    /// checked with `parseMode` first).
    mode_spec: []u8 = &.{},
    /// chown: the new owner and group; null keeps one.
    uid: ?u32 = null,
    gid: ?u32 = null,
    /// chmod and chown: into folders too.
    recursive: bool = false,

    cancel: std.atomic.Value(bool) = .init(false),
    /// 1 while paused: the worker waits at its next item or chunk.
    paused: std.atomic.Value(u32) = .init(0),
    total_bytes: std.atomic.Value(u64) = .init(0),
    done_bytes: std.atomic.Value(u64) = .init(0),
    total_items: std.atomic.Value(u32) = .init(0),
    done_items: std.atomic.Value(u32) = .init(0),
    /// Counting what to do before doing it.
    scanning: std.atomic.Value(bool) = .init(true),
    /// Waiting for the UI to resolve `conflict`.
    asking: std.atomic.Value(bool) = .init(false),
    /// Set once by the worker when it finishes.
    result: ?Error = null,
    /// The file the error was about.
    err_path: [256]u8 = undefined,
    err_path_len: usize = 0,
    /// Names the operation created in `dest`, newline-separated, so the
    /// view can select them.
    created: std.ArrayList(u8) = .empty,
    /// What was done, in order (owned).
    done: std.ArrayList(Done) = .empty,
    /// Items skipped by the user.
    skipped: u32 = 0,

    // Conflicts.
    conflict: Conflict = .{},
    answer: Resolution = .none,
    answer_all: bool = false,
    answered: sync.Event = .{},
    /// The answer that applies to every conflict from now on.
    policy: Resolution = .none,
    /// Called on the worker thread when a conflict needs an answer; must
    /// get it to the UI thread (siv_post) and return.
    ask: ?*const fn (ctx: ?*anyopaque, op: *Op) void = null,
    ask_ctx: ?*anyopaque = null,

    /// The current item's name, for progress.
    current_mutex: sync.Mutex = .{},
    current: [256]u8 = undefined,
    current_len: usize = 0,

    /// An operation that moves each source to its target (restore,
    /// move_back).
    pub fn createTargeted(gpa: Allocator, kind: Kind, sources: []const []const u8, targets: []const []const u8) !*Op {
        const op = try create(gpa, kind, sources, "");
        errdefer op.destroy();
        op.targets = try dupeAll(gpa, targets);
        return op;
    }

    pub fn create(gpa: Allocator, kind: Kind, sources: []const []const u8, dest: []const u8) !*Op {
        const op = try gpa.create(Op);
        errdefer gpa.destroy(op);
        const srcs = try dupeAll(gpa, sources);
        errdefer freeAll(gpa, srcs);
        const d = try gpa.dupe(u8, dest);
        op.* = .{ .gpa = gpa, .kind = kind, .sources = srcs, .dest = d };
        return op;
    }

    pub fn destroy(op: *Op) void {
        const gpa = op.gpa;
        freeAll(gpa, op.sources);
        freeAll(gpa, op.targets);
        gpa.free(op.dest);
        gpa.free(op.home_trash);
        gpa.free(op.mode_spec);
        op.created.deinit(gpa);
        for (op.done.items) |d| {
            gpa.free(d.from);
            gpa.free(d.to);
        }
        op.done.deinit(gpa);
        gpa.destroy(op);
    }

    /// Does the work. Blocking; on a worker thread.
    pub fn run(op: *Op) void {
        op.result = null;
        op.scan();
        op.scanning.store(false, .release);
        for (op.sources, 0..) |src, i| {
            op.one(src, i) catch |err| {
                op.result = err;
                return;
            };
        }
    }

    /// The UI's answer to the current conflict (UI thread).
    pub fn resolve(op: *Op, r: Resolution, all: bool) void {
        op.answer = r;
        op.answer_all = all;
        op.asking.store(false, .release);
        op.answered.set();
    }

    pub fn currentName(op: *Op, buf: []u8) []const u8 {
        op.current_mutex.lock();
        defer op.current_mutex.unlock();
        const n = @min(buf.len, op.current_len);
        @memcpy(buf[0..n], op.current[0..n]);
        return buf[0..n];
    }

    fn setCurrent(op: *Op, path: []const u8) void {
        const nm = model.basename(path);
        op.current_mutex.lock();
        defer op.current_mutex.unlock();
        var n = @min(nm.len, op.current.len);
        // Do not cut a UTF-8 sequence.
        while (n > 0 and n < nm.len and nm[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(op.current[0..n], nm[0..n]);
        op.current_len = n;
    }

    fn fail(op: *Op, path: []const u8, err: Error) Error {
        const n = @min(path.len, op.err_path.len);
        @memcpy(op.err_path[0..n], path[0..n]);
        op.err_path_len = n;
        return err;
    }

    pub fn errPath(op: *const Op) []const u8 {
        return op.err_path[0..op.err_path_len];
    }

    /// Waits while paused, then stops if cancelled (worker).
    fn checkCancel(op: *Op) Error!void {
        while (op.paused.load(.acquire) == 1 and !op.cancel.load(.acquire)) {
            _ = linux.futex_4arg(&op.paused.raw, .{ .cmd = .WAIT, .private = true }, 1, null);
        }
        if (op.cancel.load(.acquire)) return error.Canceled;
    }

    /// Pauses or resumes the worker (UI thread).
    pub fn setPaused(op: *Op, on: bool) void {
        op.paused.store(@intFromBool(on), .release);
        if (!on) _ = linux.futex_3arg(&op.paused.raw, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
    }

    pub fn isPaused(op: *const Op) bool {
        return op.paused.load(.acquire) == 1;
    }

    /// What the operation does, for the tasks view: "Copying 3 items to
    /// Music".
    pub fn title(op: *const Op, buf: []u8) []const u8 {
        var nbuf: [300]u8 = undefined;
        const what = if (op.sources.len == 1)
            std.fmt.bufPrint(&nbuf, "“{s}”", .{model.basename(op.sources[0])}) catch "1 item"
        else
            std.fmt.bufPrint(&nbuf, "{d} items", .{op.sources.len}) catch "items";
        const dest = model.basename(trimSlash(op.dest));
        return (switch (op.kind) {
            .copy => std.fmt.bufPrint(buf, "Copying {s} to {s}", .{ what, if (dest.len == 0) "/" else dest }),
            .move => std.fmt.bufPrint(buf, "Moving {s} to {s}", .{ what, if (dest.len == 0) "/" else dest }),
            .move_back => std.fmt.bufPrint(buf, "Moving {s} back", .{what}),
            .trash => std.fmt.bufPrint(buf, "Moving {s} to the trash", .{what}),
            .delete => std.fmt.bufPrint(buf, "Deleting {s}", .{what}),
            .restore => std.fmt.bufPrint(buf, "Restoring {s}", .{what}),
            .chmod => std.fmt.bufPrint(buf, "Changing the permissions of {s}", .{what}),
            .chown => std.fmt.bufPrint(buf, "Changing the owner of {s}", .{what}),
        }) catch "";
    }

    /// What a finished operation did, as the status line says it, and
    /// whether that is an error. Empty when there is nothing to say.
    pub fn summary(op: *const Op, buf: []u8) struct { []const u8, bool } {
        if (op.result) |err| {
            if (err == error.Canceled) return .{ "Canceled", false };
            return .{ std.fmt.bufPrint(buf, "Could not {s} “{s}”: {s}", .{ verb(op.kind), model.basename(op.errPath()), describe(err) }) catch "The operation failed", true };
        }
        if (op.kind == .chmod or op.kind == .chown) {
            const n = op.done_items.load(.monotonic);
            const what = if (op.kind == .chmod) "permissions" else "owner";
            const msg = if (n == 1)
                std.fmt.bufPrint(buf, "Changed the {s} of “{s}”", .{ what, model.basename(op.sources[0]) })
            else
                std.fmt.bufPrint(buf, "Changed the {s} of {d} items", .{ what, n });
            return .{ msg catch "Changed", false };
        }
        const n = op.done.items.len;
        if (n == 0 and op.kind != .delete) return .{ if (op.skipped != 0) "Nothing changed: every item was skipped" else "", false };
        const what = if (op.done.items.len == 1) model.basename(op.done.items[0].from) else if (op.sources.len == 1) model.basename(op.sources[0]) else "";
        const single = n == 1 or (op.kind == .delete and op.sources.len == 1);
        const cnt = if (op.kind == .delete) op.sources.len else n;
        const msg = (switch (op.kind) {
            .copy => if (single) std.fmt.bufPrint(buf, "Copied “{s}”", .{what}) else std.fmt.bufPrint(buf, "Copied {d} items", .{cnt}),
            .move, .move_back => if (single) std.fmt.bufPrint(buf, "Moved “{s}”", .{what}) else std.fmt.bufPrint(buf, "Moved {d} items", .{cnt}),
            .trash => if (single) std.fmt.bufPrint(buf, "“{s}” moved to the trash", .{what}) else std.fmt.bufPrint(buf, "{d} items moved to the trash", .{cnt}),
            .delete => if (single) std.fmt.bufPrint(buf, "“{s}” deleted", .{what}) else std.fmt.bufPrint(buf, "{d} items deleted", .{cnt}),
            .restore => if (single) std.fmt.bufPrint(buf, "“{s}” restored", .{what}) else std.fmt.bufPrint(buf, "{d} items restored", .{cnt}),
            .chmod, .chown => unreachable,
        }) catch "";
        return .{ msg, false };
    }

    fn record(op: *Op, from: []const u8, to: []const u8, replaced: bool) Error!void {
        const f = try op.gpa.dupe(u8, from);
        errdefer op.gpa.free(f);
        const t = try op.gpa.dupe(u8, to);
        errdefer op.gpa.free(t);
        try op.done.append(op.gpa, .{ .from = f, .to = t, .replaced = replaced });
    }

    /// Counts files and bytes, for progress. Moves within one file system
    /// and deletes count items only.
    fn scan(op: *Op) void {
        for (op.sources) |src| {
            if (op.cancel.load(.acquire)) return;
            var buf: [linux.PATH_MAX]u8 = undefined;
            const z = zpath(&buf, src) catch continue;
            op.scanTree(z, op.kind == .copy);
        }
    }

    fn scanTree(op: *Op, path: [:0]const u8, bytes: bool) void {
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .SIZE = true }, &st)) != .SUCCESS) return;
        _ = op.total_items.fetchAdd(1, .monotonic);
        if (st.mode & linux.S.IFMT == linux.S.IFREG and bytes) _ = op.total_bytes.fetchAdd(st.size, .monotonic);
        const walks = op.kind == .copy or op.kind == .delete or ((op.kind == .chmod or op.kind == .chown) and op.recursive);
        if (st.mode & linux.S.IFMT != linux.S.IFDIR or !walks) return;
        var it = DirIter.open(path) catch return;
        defer it.close();
        while (it.next()) |nm| {
            if (op.cancel.load(.acquire)) return;
            var buf: [linux.PATH_MAX]u8 = undefined;
            const child = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ path, nm }, 0) catch continue;
            op.scanTree(child, bytes);
        }
    }

    fn one(op: *Op, src: []const u8, index: usize) Error!void {
        try op.checkCancel();
        op.setCurrent(src);
        switch (op.kind) {
            .copy, .move => {
                // A folder into itself or below itself.
                if (model.isWithin(op.dest, src)) return op.fail(src, error.IntoItself);
                const same_dir = std.mem.eql(u8, model.parent(src), op.dest);
                if (op.kind == .move and same_dir) return; // nothing to do
                var buf: [linux.PATH_MAX]u8 = undefined;
                const target = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ trimSlash(op.dest), model.basename(src) }, 0) catch return op.fail(src, error.NameTooLong);
                const placed = try op.place(src, target, same_dir);
                if (placed) |t| {
                    try op.created.appendSlice(op.gpa, model.basename(t));
                    try op.created.append(op.gpa, '\n');
                }
            },
            .trash => try op.trash(src),
            .delete => try op.deleteTree(src),
            .restore, .move_back => try op.restore(src, op.targets[index]),
            .chmod, .chown => {
                var buf: [linux.PATH_MAX]u8 = undefined;
                const z = zpath(&buf, src) catch return op.fail(src, error.NameTooLong);
                // Links named on the command line are followed, as
                // chmod(1) and chown(1) do; links inside folders are not.
                try op.attrTree(z, true);
            },
        }
    }

    /// chmod or chown on `path`, and below it when recursive.
    fn attrTree(op: *Op, path: [:0]const u8, follow: bool) Error!void {
        try op.checkCancel();
        var st: linux.Statx = undefined;
        const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
        switch (linux.errno(linux.statx(linux.AT.FDCWD, path, flags, .{ .TYPE = true, .MODE = true }, &st))) {
            .SUCCESS => {},
            else => |e| return op.fail(path, mapErrno(e)),
        }
        const kind = st.mode & linux.S.IFMT;
        const rc = if (op.kind == .chmod) blk: {
            // chmod cannot change a link's own bits.
            if (kind == linux.S.IFLNK) break :blk 0;
            const mode = applyMode(op.mode_spec, st.mode & 0o7777, kind == linux.S.IFDIR, fileUmask()) orelse return op.fail(path, error.Unexpected);
            break :blk linux.fchmodat(linux.AT.FDCWD, path, mode);
        } else linux.fchownat(linux.AT.FDCWD, path, op.uid orelse std.math.maxInt(u32), op.gid orelse std.math.maxInt(u32), flags);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .PERM => return op.fail(path, error.AccessDenied),
            else => |e| return op.fail(path, mapErrno(e)),
        }
        _ = op.done_items.fetchAdd(1, .monotonic);
        if (!op.recursive or kind != linux.S.IFDIR) return;
        var it = DirIter.open(path) catch |err| return op.fail(path, err);
        defer it.close();
        while (it.next()) |nm| {
            var buf: [linux.PATH_MAX]u8 = undefined;
            const child = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ path, nm }, 0) catch return op.fail(path, error.NameTooLong);
            op.setCurrent(child);
            try op.attrTree(child, false);
        }
    }

    /// Copies or moves `src` to `target`, resolving a conflict there.
    /// Returns where it went, or null if skipped.
    fn place(op: *Op, src: []const u8, target_in: [:0]u8, duplicate: bool) Error!?[]const u8 {
        var target = target_in;
        var replaced = false;
        var free_buf: [linux.PATH_MAX]u8 = undefined;
        if (exists(target)) {
            const r: Resolution = if (duplicate) .keep_both else try op.resolveConflict(src, target);
            switch (r) {
                .skip => {
                    op.skipped += 1;
                    _ = op.done_items.fetchAdd(1, .monotonic);
                    return null;
                },
                .cancel, .none => return error.Canceled,
                .keep_both => target = try op.freeName(&free_buf, model.parent(target), model.basename(target)),
                .replace => {
                    // Moving a file onto itself (another name for it) does nothing.
                    if (std.mem.eql(u8, src, target)) return null;
                    try op.deleteTreeQuiet(target);
                    replaced = true;
                },
                .merge => {
                    try op.merge(src, target);
                    try op.record(src, target, true);
                    return target;
                },
            }
        }
        if (op.kind == .move) {
            try op.move(src, target);
        } else {
            try op.copyTree(src, target, true);
        }
        try op.record(src, target, replaced);
        return target;
    }

    /// Copies or moves the contents of folder `src` into folder `dst`,
    /// resolving conflicts inside; a move removes `src` afterwards.
    fn merge(op: *Op, src: []const u8, dst: []const u8) Error!void {
        var sbuf: [linux.PATH_MAX]u8 = undefined;
        const zs = zpath(&sbuf, src) catch return op.fail(src, error.NameTooLong);
        if (!isDirPath(zs)) {
            // A file onto a folder or the reverse cannot merge: replace.
            var dbuf: [linux.PATH_MAX]u8 = undefined;
            const zd = zpath(&dbuf, dst) catch return op.fail(dst, error.NameTooLong);
            try op.deleteTreeQuiet(zd);
            if (op.kind == .move) try op.move(src, zd) else try op.copyTree(src, zd, true);
            return;
        }
        var it = DirIter.open(zs) catch |err| return op.fail(src, err);
        defer it.close();
        while (it.next()) |nm| {
            try op.checkCancel();
            var cs: [linux.PATH_MAX]u8 = undefined;
            var ct: [linux.PATH_MAX]u8 = undefined;
            const child_src = std.fmt.bufPrint(&cs, "{s}/{s}", .{ src, nm }) catch return op.fail(src, error.NameTooLong);
            const child_dst = std.fmt.bufPrintSentinel(&ct, "{s}/{s}", .{ dst, nm }, 0) catch return op.fail(dst, error.NameTooLong);
            op.setCurrent(child_src);
            if (exists(child_dst)) {
                const r = try op.resolveConflict(child_src, child_dst);
                switch (r) {
                    .skip => {
                        op.skipped += 1;
                        continue;
                    },
                    .cancel, .none => return error.Canceled,
                    .keep_both => {
                        var fb: [linux.PATH_MAX]u8 = undefined;
                        const t = try op.freeName(&fb, dst, nm);
                        if (op.kind == .move) try op.move(child_src, t) else try op.copyTree(child_src, t, true);
                    },
                    .replace => {
                        try op.deleteTreeQuiet(child_dst);
                        if (op.kind == .move) try op.move(child_src, child_dst) else try op.copyTree(child_src, child_dst, true);
                    },
                    .merge => try op.merge(child_src, child_dst),
                }
            } else {
                if (op.kind == .move) try op.move(child_src, child_dst) else try op.copyTree(child_src, child_dst, true);
            }
        }
        if (op.kind == .move) {
            // What was skipped stays behind.
            _ = linux.unlinkat(linux.AT.FDCWD, zs, linux.AT.REMOVEDIR);
        }
    }

    /// Asks the UI what to do about `dst` existing (or applies the
    /// policy), waiting for the answer.
    fn resolveConflict(op: *Op, src: []const u8, dst: [:0]const u8) Error!Resolution {
        var c: Conflict = .{};
        fillConflict(&c, src, dst);
        // A policy of merging folders replaces files.
        if (op.policy != .none) {
            if (op.policy == .merge and !(c.src_dir and c.dst_dir)) return .replace;
            if (op.policy == .replace and c.src_dir and c.dst_dir) return .merge;
            return op.policy;
        }
        const ask = op.ask orelse return .keep_both;
        op.conflict = c;
        op.answered.reset();
        op.asking.store(true, .release);
        ask(op.ask_ctx, op);
        // Wait for the answer, waking for cancellation too (resolve or a
        // cancel sets the event).
        op.answered.wait();
        if (op.cancel.load(.acquire)) return error.Canceled;
        const r = op.answer;
        if (op.answer_all and r != .cancel) op.policy = r;
        return r;
    }

    /// Wakes a worker waiting for an answer so that it sees `cancel`.
    pub fn requestCancel(op: *Op) void {
        op.cancel.store(true, .release);
        op.answered.set();
        op.setPaused(false);
    }

    /// `dir/name`, or with " (2)", " (3)", ... before the extension if
    /// that exists.
    fn freeName(op: *Op, buf: *[linux.PATH_MAX]u8, dir: []const u8, nm: []const u8) Error![:0]u8 {
        return freeNameIn(buf, dir, nm) catch |err| op.fail(nm, err);
    }

    fn move(op: *Op, src: []const u8, target: [:0]const u8) Error!void {
        var sbuf: [linux.PATH_MAX]u8 = undefined;
        const zs = zpath(&sbuf, src) catch return op.fail(src, error.NameTooLong);
        const rc = linux.renameat2(linux.AT.FDCWD, zs, linux.AT.FDCWD, target, .{ .NOREPLACE = true });
        switch (linux.errno(rc)) {
            .SUCCESS => {
                _ = op.done_items.fetchAdd(1, .monotonic);
                return;
            },
            // Another file system: copy, then delete the original.
            .XDEV => {},
            else => |e| return op.fail(src, mapErrno(e)),
        }
        // Count the bytes now that they must be copied.
        op.scanTree(zs, true);
        try op.copyTree(src, target, true);
        try op.deleteTree(src);
    }

    fn copyTree(op: *Op, src: []const u8, target: [:0]const u8, top: bool) Error!void {
        _ = top;
        try op.checkCancel();
        var sbuf: [linux.PATH_MAX]u8 = undefined;
        const zs = zpath(&sbuf, src) catch return op.fail(src, error.NameTooLong);
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .SIZE = true, .MTIME = true, .ATIME = true };
        switch (linux.errno(linux.statx(linux.AT.FDCWD, zs, linux.AT.SYMLINK_NOFOLLOW, mask, &st))) {
            .SUCCESS => {},
            else => |e| return op.fail(src, mapErrno(e)),
        }
        const mode = st.mode & 0o7777;
        switch (st.mode & linux.S.IFMT) {
            linux.S.IFDIR => {
                switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, target, mode | 0o700))) {
                    .SUCCESS => {},
                    else => |e| return op.fail(target, mapErrno(e)),
                }
                _ = op.done_items.fetchAdd(1, .monotonic);
                var it = DirIter.open(zs) catch |err| return op.fail(src, err);
                defer it.close();
                while (it.next()) |nm| {
                    var cs: [linux.PATH_MAX]u8 = undefined;
                    var ct: [linux.PATH_MAX]u8 = undefined;
                    const child_src = std.fmt.bufPrint(&cs, "{s}/{s}", .{ src, nm }) catch return op.fail(src, error.NameTooLong);
                    const child_target = std.fmt.bufPrintSentinel(&ct, "{s}/{s}", .{ target, nm }, 0) catch return op.fail(src, error.NameTooLong);
                    try op.copyTree(child_src, child_target, false);
                }
                _ = linux.fchmodat(linux.AT.FDCWD, target, mode);
            },
            linux.S.IFLNK => {
                var lbuf: [linux.PATH_MAX]u8 = undefined;
                const n = linux.readlinkat(linux.AT.FDCWD, zs, &lbuf, lbuf.len - 1);
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    else => |e| return op.fail(src, mapErrno(e)),
                }
                lbuf[n] = 0;
                switch (linux.errno(linux.symlinkat(lbuf[0..n :0], linux.AT.FDCWD, target))) {
                    .SUCCESS => {},
                    else => |e| return op.fail(target, mapErrno(e)),
                }
                _ = op.done_items.fetchAdd(1, .monotonic);
            },
            linux.S.IFREG => try op.copyFile(src, zs, target, mode, st),
            // Devices, sockets, and pipes are not copied.
            else => _ = op.done_items.fetchAdd(1, .monotonic),
        }
    }

    fn copyFile(op: *Op, src: []const u8, zs: [:0]const u8, target: [:0]const u8, mode: u32, st: linux.Statx) Error!void {
        op.setCurrent(src);
        const in_rc = linux.openat(linux.AT.FDCWD, zs, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const in: i32 = switch (linux.errno(in_rc)) {
            .SUCCESS => @intCast(in_rc),
            else => |e| return op.fail(src, mapErrno(e)),
        };
        defer _ = linux.close(in);
        const out_rc = linux.openat(linux.AT.FDCWD, target, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, mode);
        const out: i32 = switch (linux.errno(out_rc)) {
            .SUCCESS => @intCast(out_rc),
            else => |e| return op.fail(target, mapErrno(e)),
        };
        var ok = false;
        defer {
            _ = linux.close(out);
            if (!ok) _ = linux.unlinkat(linux.AT.FDCWD, target, 0);
        }
        // copy_file_range in chunks, so that cancelling and progress work
        // for large files (and reflinks or server-side copies happen where
        // the file system offers them); read and write where it is refused.
        const chunk: usize = 4 << 20;
        var use_read = false;
        var buf: [128 * 1024]u8 = undefined;
        while (true) {
            try op.checkCancel();
            var n: usize = 0;
            if (!use_read) {
                const rc = linux.copy_file_range(in, null, out, null, chunk, 0);
                switch (linux.errno(rc)) {
                    .SUCCESS => n = rc,
                    .INTR => continue,
                    .XDEV, .INVAL, .OPNOTSUPP, .NOSYS => {
                        use_read = true;
                        continue;
                    },
                    else => |e| return op.fail(target, mapErrno(e)),
                }
            } else {
                const rc = linux.read(in, &buf, buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => n = rc,
                    .INTR => continue,
                    else => |e| return op.fail(src, mapErrno(e)),
                }
                var off: usize = 0;
                while (off < n) {
                    const w = linux.write(out, buf[off..n].ptr, n - off);
                    switch (linux.errno(w)) {
                        .SUCCESS => off += w,
                        .INTR => {},
                        else => |e| return op.fail(target, mapErrno(e)),
                    }
                }
            }
            if (n == 0) break;
            _ = op.done_bytes.fetchAdd(n, .monotonic);
        }
        const times = [2]linux.timespec{
            .{ .sec = st.atime.sec, .nsec = st.atime.nsec },
            .{ .sec = st.mtime.sec, .nsec = st.mtime.nsec },
        };
        _ = linux.utimensat(out, null, &times, 0);
        ok = true;
        _ = op.done_items.fetchAdd(1, .monotonic);
    }

    fn deleteTree(op: *Op, path: []const u8) Error!void {
        try op.checkCancel();
        var buf: [linux.PATH_MAX]u8 = undefined;
        const z = zpath(&buf, path) catch return op.fail(path, error.NameTooLong);
        switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0))) {
            .SUCCESS => {
                _ = op.done_items.fetchAdd(1, .monotonic);
                return;
            },
            .ISDIR, .PERM => {},
            else => |e| return op.fail(path, mapErrno(e)),
        }
        var it = DirIter.open(z) catch |err| return op.fail(path, err);
        while (it.next()) |nm| {
            var cbuf: [linux.PATH_MAX]u8 = undefined;
            const child = std.fmt.bufPrint(&cbuf, "{s}/{s}", .{ path, nm }) catch {
                it.close();
                return op.fail(path, error.NameTooLong);
            };
            op.deleteTree(child) catch |err| {
                it.close();
                return err;
            };
        }
        it.close();
        switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, linux.AT.REMOVEDIR))) {
            .SUCCESS => _ = op.done_items.fetchAdd(1, .monotonic),
            else => |e| return op.fail(path, mapErrno(e)),
        }
    }

    /// Deletes what a replace overwrites, without counting it as progress.
    fn deleteTreeQuiet(op: *Op, path: []const u8) Error!void {
        const before = op.done_items.load(.monotonic);
        try op.deleteTree(path);
        op.done_items.store(before, .monotonic);
    }

    /// The freedesktop.org trash: the file moves to Trash/files under a
    /// free name, with Trash/info/<name>.trashinfo saying where it was
    /// and when. Files on other devices go to that device's
    /// $topdir/.Trash-$uid, as the specification says.
    fn trash(op: *Op, src: []const u8) Error!void {
        var tdbuf: [linux.PATH_MAX]u8 = undefined;
        var topbuf: [linux.PATH_MAX]u8 = undefined;
        const where = trashDirFor(&tdbuf, &topbuf, op.home_trash, src) catch |err| return op.fail(src, err);
        var dbuf: [linux.PATH_MAX]u8 = undefined;
        const files = std.fmt.bufPrintSentinel(&dbuf, "{s}/files", .{where.dir}, 0) catch return op.fail(src, error.NameTooLong);
        try mkdirs(files);
        var ibuf: [linux.PATH_MAX]u8 = undefined;
        const info_dir = std.fmt.bufPrintSentinel(&ibuf, "{s}/info", .{where.dir}, 0) catch return op.fail(src, error.NameTooLong);
        try mkdirs(info_dir);

        // Claim a name by creating its info file exclusively, so that two
        // trashes never claim the same one.
        var tbuf: [linux.PATH_MAX]u8 = undefined;
        var info_buf: [linux.PATH_MAX]u8 = undefined;
        const nm = model.basename(src);
        var k: u32 = 1;
        var target: [:0]u8 = undefined;
        var info_path: [:0]u8 = undefined;
        var fd: i32 = -1;
        while (k < 10000) : (k += 1) {
            target = (if (k == 1)
                std.fmt.bufPrintSentinel(&tbuf, "{s}/{s}", .{ files, nm }, 0)
            else
                numbered(&tbuf, files, nm, k)) catch return op.fail(src, error.NameTooLong);
            info_path = std.fmt.bufPrintSentinel(&info_buf, "{s}/{s}.trashinfo", .{ info_dir, model.basename(target) }, 0) catch return op.fail(src, error.NameTooLong);
            const rc = linux.openat(linux.AT.FDCWD, info_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (exists(target)) {
                        // A file with no info: leave both alone.
                        _ = linux.close(@intCast(rc));
                        _ = linux.unlinkat(linux.AT.FDCWD, info_path, 0);
                        continue;
                    }
                    fd = @intCast(rc);
                    break;
                },
                .EXIST => continue,
                else => |e| return op.fail(info_path, mapErrno(e)),
            }
        }
        if (fd < 0) return op.fail(src, error.Exists);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(op.gpa);
        try body.appendSlice(op.gpa, "[Trash Info]\nPath=");
        // Paths in a device's own trash are relative to its top directory.
        const recorded = if (where.top.len > 0 and model.isWithin(src, where.top)) src[where.top.len + @intFromBool(where.top.len > 1) ..] else src;
        try appendEscaped(op.gpa, &body, recorded);
        var date: [64]u8 = undefined;
        try body.appendSlice(op.gpa, "\nDeletionDate=");
        try body.appendSlice(op.gpa, localIsoNow(&date));
        try body.append(op.gpa, '\n');
        _ = linux.write(fd, body.items.ptr, body.items.len);
        _ = linux.close(fd);
        op.move(src, target) catch |err| {
            _ = linux.unlinkat(linux.AT.FDCWD, info_path, 0);
            return err;
        };
        try op.record(src, target, false);
    }

    /// Moves a trashed file (in some Trash/files) back to `target`,
    /// resolving a conflict there, and removes its info file.
    fn restore(op: *Op, trashed: []const u8, target_in: []const u8) Error!void {
        var tbuf: [linux.PATH_MAX]u8 = undefined;
        var target = zpath(&tbuf, target_in) catch return op.fail(trashed, error.NameTooLong);
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        const parent_dir = zpath(&pbuf, model.parent(target_in)) catch return op.fail(trashed, error.NameTooLong);
        mkdirs(parent_dir) catch |err| return op.fail(target_in, err);
        var fb: [linux.PATH_MAX]u8 = undefined;
        if (exists(target)) {
            switch (try op.resolveConflict(trashed, target)) {
                .skip => {
                    op.skipped += 1;
                    return;
                },
                .cancel, .none => return error.Canceled,
                .keep_both => target = try op.freeName(&fb, model.parent(target_in), model.basename(target_in)),
                .replace, .merge => try op.deleteTreeQuiet(target),
            }
        }
        try op.move(trashed, target);
        var ibuf: [linux.PATH_MAX]u8 = undefined;
        if (op.kind == .restore) if (infoPathOf(&ibuf, trashed)) |info| {
            _ = linux.unlinkat(linux.AT.FDCWD, info, 0);
        };
        try op.record(trashed, target, false);
    }
};

/// The trash a file goes to: the home trash if it is on the home trash's
/// device, else $topdir/.Trash/$uid (if the administrator made it) or
/// $topdir/.Trash-$uid on the file's device. `top` is that device's top
/// directory ("" for the home trash).
pub fn trashDirFor(buf: *[linux.PATH_MAX]u8, top_buf: *[linux.PATH_MAX]u8, home_trash: []const u8, src: []const u8) Error!struct { dir: []const u8, top: []const u8 } {
    const src_dev = deviceOf(src) orelse return error.FileNotFound;
    // The home trash may not exist yet: its nearest existing ancestor.
    var hb: [linux.PATH_MAX]u8 = undefined;
    var probe: []const u8 = home_trash;
    while (deviceOf(probe) == null and probe.len > 1) probe = model.parent(probe);
    _ = &hb;
    if (deviceOf(probe)) |home_dev| if (home_dev == src_dev) {
        @memcpy(buf[0..home_trash.len], home_trash);
        return .{ .dir = buf[0..home_trash.len], .top = "" };
    };
    // The top directory: the highest ancestor on the same device.
    var top: []const u8 = model.parent(src);
    while (top.len > 1) {
        const up = model.parent(top);
        if (deviceOf(up) != src_dev) break;
        top = up;
    }
    @memcpy(top_buf[0..top.len], top);
    const top_copy = top_buf[0..top.len];
    const uid = linux.getuid();
    // $topdir/.Trash must be a sticky directory, not a link.
    var admin_buf: [linux.PATH_MAX]u8 = undefined;
    const admin = std.fmt.bufPrintSentinel(&admin_buf, "{s}/.Trash", .{trimSlash(top)}, 0) catch return error.NameTooLong;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, admin, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &st)) == .SUCCESS and
        st.mode & linux.S.IFMT == linux.S.IFDIR and st.mode & linux.S.ISVTX != 0)
    {
        const d = std.fmt.bufPrint(buf, "{s}/.Trash/{d}", .{ trimSlash(top), uid }) catch return error.NameTooLong;
        return .{ .dir = d, .top = top_copy };
    }
    const d = std.fmt.bufPrint(buf, "{s}/.Trash-{d}", .{ trimSlash(top), uid }) catch return error.NameTooLong;
    return .{ .dir = d, .top = top_copy };
}

fn deviceOf(path: []const u8) ?u64 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) return null;
    return (@as(u64, st.dev_major) << 32) | st.dev_minor;
}

/// Trash/files/NAME → Trash/info/NAME.trashinfo.
pub fn infoPathOf(buf: *[linux.PATH_MAX]u8, trashed: []const u8) ?[:0]u8 {
    const files_dir = model.parent(trashed);
    if (!std.mem.eql(u8, model.basename(files_dir), "files")) return null;
    const trash_dir = model.parent(files_dir);
    return std.fmt.bufPrintSentinel(buf, "{s}/info/{s}.trashinfo", .{ trimSlash(trash_dir), model.basename(trashed) }, 0) catch null;
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    for (path) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~/", b) != null) {
            try out.append(gpa, b);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(gpa, &.{ '%', hex[b >> 4], hex[b & 15] });
        }
    }
}

/// Local time now as the trash specification wants it
/// (YYYY-MM-DDThh:mm:ss).
fn localIsoNow(buf: []u8) []const u8 {
    const tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
    const S = struct {
        extern "c" fn time(t: ?*i64) i64;
        extern "c" fn localtime_r(t: *const i64, out: *tm) ?*tm;
    };
    var now = S.time(null);
    var t: tm = undefined;
    if (S.localtime_r(&now, &t) == null) return "";
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(t.year + 1900)), @as(u32, @intCast(t.mon + 1)), @as(u32, @intCast(t.mday)), @as(u32, @intCast(t.hour)), @as(u32, @intCast(t.min)), @as(u32, @intCast(t.sec)),
    }) catch "";
}

fn fillConflict(c: *Conflict, src: []const u8, dst: []const u8) void {
    const ns = @min(src.len, c.src.len);
    @memcpy(c.src[0..ns], src[0..ns]);
    c.src_len = ns;
    const nd = @min(dst.len, c.dst.len);
    @memcpy(c.dst[0..nd], dst[0..nd]);
    c.dst_len = nd;
    for ([_]struct { []const u8, *bool, *u64, *i64 }{ .{ src, &c.src_dir, &c.src_size, &c.src_mtime }, .{ dst, &c.dst_dir, &c.dst_size, &c.dst_mtime } }) |x| {
        var zb: [linux.PATH_MAX]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{x[0]}, 0) catch continue;
        const e = model.statEntry(linux.AT.FDCWD, z, model.basename(x[0]));
        x[1].* = e.kind == .dir;
        x[2].* = e.size;
        x[3].* = e.mtime;
    }
}

/// Creates a folder `name` in `dir`.
pub fn makeDir(dir: []const u8, nm: []const u8) Error!void {
    if (!model.validName(nm)) return error.InvalidName;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ trimSlash(dir), nm }, 0) catch return error.NameTooLong;
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o755))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

/// Creates an empty file `name` in `dir`.
pub fn makeFile(dir: []const u8, nm: []const u8) Error!void {
    if (!model.validName(nm)) return error.InvalidName;
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ trimSlash(dir), nm }, 0) catch return error.NameTooLong;
    const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o644);
    switch (linux.errno(rc)) {
        .SUCCESS => _ = linux.close(@intCast(rc)),
        else => |e| return mapErrno(e),
    }
}

/// Removes an empty folder or a file (undo of creating it).
pub fn removeEmpty(path: []const u8) Error!void {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = zpath(&buf, path) catch return error.NameTooLong;
    switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, linux.AT.REMOVEDIR))) {
        .SUCCESS => return,
        .NOTDIR => {},
        else => |e| return mapErrno(e),
    }
    switch (linux.errno(linux.unlinkat(linux.AT.FDCWD, z, 0))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

/// Renames `old` to `new` in `dir`, refusing to replace an existing file.
pub fn rename(dir: []const u8, old: []const u8, new: []const u8) Error!void {
    if (!model.validName(new)) return error.InvalidName;
    if (std.mem.eql(u8, old, new)) return;
    var a: [linux.PATH_MAX]u8 = undefined;
    var b: [linux.PATH_MAX]u8 = undefined;
    const pa = std.fmt.bufPrint(&a, "{s}/{s}", .{ trimSlash(dir), old }) catch return error.NameTooLong;
    const pb = std.fmt.bufPrint(&b, "{s}/{s}", .{ trimSlash(dir), new }) catch return error.NameTooLong;
    return renamePath(pa, pb);
}

/// Renames a path to another in the same file system, refusing to replace.
pub fn renamePath(from: []const u8, to: []const u8) Error!void {
    var a: [linux.PATH_MAX]u8 = undefined;
    var b: [linux.PATH_MAX]u8 = undefined;
    const pa = zpath(&a, from) catch return error.NameTooLong;
    const pb = zpath(&b, to) catch return error.NameTooLong;
    switch (linux.errno(linux.renameat2(linux.AT.FDCWD, pa, linux.AT.FDCWD, pb, .{ .NOREPLACE = true }))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

/// Whether `spec` is a mode chmod(1) takes: octal ("755"), or symbolic
/// clauses separated by commas ("u+x", "go-w", "a=rX", "+x").
pub fn parseMode(spec: []const u8) bool {
    return applyMode(spec, 0o644, false, 0o022) != null;
}

/// The permission bits `spec` makes of `old`, as chmod(1) does: X adds
/// execute only to folders and files executable by someone already;
/// clauses without u, g, o, or a leave the bits the umask masks alone.
/// Null if `spec` is not a mode.
pub fn applyMode(spec: []const u8, old: u32, is_dir: bool, umask: u32) ?u32 {
    if (spec.len == 0) return null;
    if (std.fmt.parseInt(u32, spec, 8)) |m| {
        if (spec.len > 4 or m > 0o7777) return null;
        // Like GNU chmod, a short octal mode keeps a folder's setuid
        // and setgid bits.
        return if (is_dir and spec.len < 4) m | (old & 0o6000) else m;
    } else |_| {}
    var mode = old;
    var clauses = std.mem.splitScalar(u8, spec, ',');
    while (clauses.next()) |clause| {
        var i: usize = 0;
        var who: u32 = 0;
        while (i < clause.len) : (i += 1) switch (clause[i]) {
            'u' => who |= 0o4700,
            'g' => who |= 0o2070,
            'o' => who |= 0o1007,
            'a' => who |= 0o7777,
            else => break,
        };
        const masked = who == 0;
        if (masked) who = 0o7777;
        if (i == clause.len) return null;
        while (i < clause.len) {
            const action = clause[i];
            if (action != '+' and action != '-' and action != '=') return null;
            i += 1;
            var bits: u32 = 0;
            while (i < clause.len and clause[i] != '+' and clause[i] != '-' and clause[i] != '=') : (i += 1) switch (clause[i]) {
                'r' => bits |= 0o444,
                'w' => bits |= 0o222,
                'x' => bits |= 0o111,
                'X' => if (is_dir or mode & 0o111 != 0) {
                    bits |= 0o111;
                },
                's' => bits |= 0o6000,
                't' => bits |= 0o1000,
                else => return null,
            };
            var affected = bits & who;
            if (masked) affected &= ~umask;
            switch (action) {
                '+' => mode |= affected,
                '-' => mode &= ~affected,
                '=' => mode = (mode & ~(who & if (masked) ~umask else @as(u32, 0o7777))) | affected,
                else => unreachable,
            }
        }
    }
    return mode & 0o7777;
}

/// The process's umask, read once from /proc (the umask call would
/// change it while reading it).
fn fileUmask() u32 {
    const S = struct {
        var value: std.atomic.Value(u32) = .init(0xffff_ffff);
    };
    const v = S.value.load(.monotonic);
    if (v != 0xffff_ffff) return v;
    var m: u32 = 0o022;
    var buf: [4096]u8 = undefined;
    const fd = linux.open("/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) == .SUCCESS) {
        defer _ = linux.close(@intCast(fd));
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (linux.errno(n) == .SUCCESS) if (std.mem.indexOf(u8, buf[0..n], "Umask:\t")) |at| {
            const rest = buf[at + 7 ..n];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            m = std.fmt.parseInt(u32, rest[0..end], 8) catch m;
        };
    }
    S.value.store(m, .monotonic);
    return m;
}

/// Sets a file's permission bits.
pub fn chmod(path: []const u8, mode: u32) Error!void {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = zpath(&buf, path) catch return error.NameTooLong;
    switch (linux.errno(linux.fchmodat(linux.AT.FDCWD, z, mode & 0o7777))) {
        .SUCCESS => {},
        else => |e| return mapErrno(e),
    }
}

pub fn trimSlash(dir: []const u8) []const u8 {
    return if (dir.len > 1 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else if (dir.len == 1) "" else dir;
}

fn zpath(buf: *[linux.PATH_MAX]u8, p: []const u8) error{NameTooLong}![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}", .{p}, 0) catch error.NameTooLong;
}

pub fn exists(p: [:0]const u8) bool {
    var st: linux.Statx = undefined;
    return linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) == .SUCCESS;
}

fn isDirPath(p: [:0]const u8) bool {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

fn numbered(buf: *[linux.PATH_MAX]u8, dir: []const u8, nm: []const u8, k: u32) error{NoSpaceLeft}![:0]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, nm, '.');
    const stem, const ext = if (dot) |d| (if (d == 0) .{ nm, "" } else .{ nm[0..d], nm[d..] }) else .{ nm, "" };
    // ".tar.gz" stays whole.
    var s = stem;
    var e = ext;
    if (std.mem.endsWith(u8, stem, ".tar")) {
        s = stem[0 .. stem.len - 4];
        e = nm[s.len..];
    }
    return std.fmt.bufPrintSentinel(buf, "{s}/{s} ({d}){s}", .{ trimSlash(dir), s, k, e }, 0);
}

/// `dir/name`, or with " (2)", " (3)", ... before the extension if that
/// exists.
pub fn freeNameIn(buf: *[linux.PATH_MAX]u8, dir: []const u8, nm: []const u8) Error![:0]u8 {
    const first = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ trimSlash(dir), nm }, 0) catch return error.NameTooLong;
    if (!exists(first)) return first;
    var k: u32 = 2;
    while (k < 10000) : (k += 1) {
        const p = numbered(buf, dir, nm, k) catch return error.NameTooLong;
        if (!exists(p)) return p;
    }
    return error.Exists;
}

fn mkdirs(p: [:0]const u8) Error!void {
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o700))) {
        .SUCCESS, .EXIST => return,
        .NOENT => {},
        else => |e| return mapErrno(e),
    }
    var buf: [linux.PATH_MAX]u8 = undefined;
    const up = model.parent(p);
    if (up.len == p.len) return error.FileNotFound;
    try mkdirs(std.fmt.bufPrintSentinel(&buf, "{s}", .{up}, 0) catch return error.NameTooLong);
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, p, 0o700))) {
        .SUCCESS, .EXIST => {},
        else => |e| return mapErrno(e),
    }
}

pub fn mapErrno(e: linux.E) Error {
    return switch (e) {
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .NOSPC, .DQUOT => error.NoSpace,
        .EXIST => error.Exists,
        .NOTEMPTY => error.NotEmpty,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        .INVAL => error.IntoItself,
        .XDEV => error.CrossDevice,
        else => error.Unexpected,
    };
}

fn dupeAll(gpa: Allocator, items: []const []const u8) ![][]u8 {
    const out = try gpa.alloc([]u8, items.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    while (n < items.len) : (n += 1) out[n] = try gpa.dupe(u8, items[n]);
    return out;
}

fn freeAll(gpa: Allocator, items: [][]u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

/// Names in a directory, without "." and "..".
pub const DirIter = struct {
    fd: i32,
    buf: [8192]u8 align(8) = undefined,
    len: usize = 0,
    off: usize = 0,

    pub fn open(path: [:0]const u8) Error!DirIter {
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            else => |e| mapErrno(e),
        };
    }

    pub fn close(it: *DirIter) void {
        _ = linux.close(it.fd);
    }

    pub fn next(it: *DirIter) ?[]const u8 {
        while (true) {
            if (it.off >= it.len) {
                const n = linux.getdents64(it.fd, &it.buf, it.buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) return null;
                it.len = n;
                it.off = 0;
            }
            const d: *align(1) const linux.dirent64 = @ptrCast(&it.buf[it.off]);
            const name_ptr: [*:0]const u8 = @ptrCast(&it.buf[it.off + @offsetOf(linux.dirent64, "name")]);
            it.off += d.reclen;
            const nm = std.mem.span(name_ptr);
            if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
            return nm;
        }
    }
};

// Tests --------------------------------------------------------------------------

const testing = std.testing;

const Tmp = struct {
    buf: [64]u8 = undefined,
    path: [:0]u8 = undefined,
    const S = struct {
        extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
        extern "c" fn system(cmd: [*:0]const u8) c_int;
    };
    fn make(t: *Tmp) !void {
        t.path = try std.fmt.bufPrintSentinel(&t.buf, "/tmp/siv-files-ops-XXXXXX", .{}, 0);
        _ = S.mkdtemp(t.path.ptr) orelse return error.Unexpected;
    }
    fn sh(t: *Tmp, comptime fmt: []const u8) !void {
        var cmd: [1024]u8 = undefined;
        const z = try std.fmt.bufPrintSentinel(&cmd, "cd {s} && " ++ fmt, .{t.path}, 0);
        if (S.system(z.ptr) != 0) return error.Unexpected;
    }
    fn has(t: *Tmp, rel: []const u8) bool {
        var b: [256]u8 = undefined;
        return exists(std.fmt.bufPrintSentinel(&b, "{s}/{s}", .{ t.path, rel }, 0) catch return false);
    }
    fn p(t: *Tmp, buf: []u8, rel: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ t.path, rel }) catch unreachable;
    }
    fn done(t: *Tmp) void {
        t.sh("cd / && rm -rf \"$OLDPWD\"") catch {};
    }
};

/// Answers every conflict with a fixed resolution, on the worker thread.
fn answerWith(ctx: ?*anyopaque, op: *Op) void {
    const r: *const Resolution = @ptrCast(@alignCast(ctx.?));
    op.resolve(r.*, false);
}

test "copy duplicates in place, and conflicts resolve" {
    var t: Tmp = .{};
    try t.make();
    defer t.done();
    try t.sh("mkdir a b && echo one > a/f.txt && echo two > b/f.txt && mkdir a/d b/d && echo x > a/d/x && echo y > b/d/y");
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    // Copy into the same folder: a duplicate.
    {
        const op = try Op.create(testing.allocator, .copy, &.{t.p(&b1, "a/f.txt")}, t.p(&b2, "a"));
        defer op.destroy();
        op.run();
        try testing.expect(op.result == null);
        try testing.expect(t.has("a/f (2).txt"));
    }
    // Skip.
    {
        var r: Resolution = .skip;
        const op = try Op.create(testing.allocator, .copy, &.{t.p(&b1, "a/f.txt")}, t.p(&b2, "b"));
        defer op.destroy();
        op.ask = answerWith;
        op.ask_ctx = &r;
        op.run();
        try testing.expect(op.result == null);
        try testing.expectEqual(@as(u32, 1), op.skipped);
        try t.sh("grep -q two b/f.txt");
    }
    // Replace.
    {
        var r: Resolution = .replace;
        const op = try Op.create(testing.allocator, .copy, &.{t.p(&b1, "a/f.txt")}, t.p(&b2, "b"));
        defer op.destroy();
        op.ask = answerWith;
        op.ask_ctx = &r;
        op.run();
        try testing.expect(op.result == null);
        try t.sh("grep -q one b/f.txt");
        try testing.expect(op.done.items[0].replaced);
    }
    // Merge folders: both files end up in b/d.
    {
        var r: Resolution = .merge;
        const op = try Op.create(testing.allocator, .move, &.{t.p(&b1, "a/d")}, t.p(&b2, "b"));
        defer op.destroy();
        op.ask = answerWith;
        op.ask_ctx = &r;
        op.run();
        try testing.expect(op.result == null);
        try testing.expect(t.has("b/d/x") and t.has("b/d/y"));
        try testing.expect(!t.has("a/d"));
    }
    // Keep both.
    {
        var r: Resolution = .keep_both;
        const op = try Op.create(testing.allocator, .move, &.{t.p(&b1, "a/f.txt")}, t.p(&b2, "b"));
        defer op.destroy();
        op.ask = answerWith;
        op.ask_ctx = &r;
        op.run();
        try testing.expect(op.result == null);
        try testing.expect(t.has("b/f (2).txt") and !t.has("a/f.txt"));
        try testing.expectEqualStrings(t.p(&b1, "b/f (2).txt"), op.done.items[0].to);
    }
}

test "trash and restore" {
    var t: Tmp = .{};
    try t.make();
    defer t.done();
    try t.sh("mkdir -p home/Trash work && echo hi > 'work/a b.txt'");
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var trashed: [256]u8 = undefined;
    var trashed_len: usize = 0;
    {
        const op = try Op.create(testing.allocator, .trash, &.{t.p(&b1, "work/a b.txt")}, "");
        defer op.destroy();
        op.home_trash = try testing.allocator.dupe(u8, t.p(&b2, "home/Trash"));
        op.run();
        try testing.expect(op.result == null);
        try testing.expect(!t.has("work/a b.txt"));
        try testing.expect(t.has("home/Trash/files/a b.txt"));
        try t.sh("grep -q 'Path=.*work/a%20b.txt' 'home/Trash/info/a b.txt.trashinfo' && grep -q DeletionDate= 'home/Trash/info/a b.txt.trashinfo'");
        @memcpy(trashed[0..op.done.items[0].to.len], op.done.items[0].to);
        trashed_len = op.done.items[0].to.len;
    }
    {
        const op = try Op.createTargeted(testing.allocator, .restore, &.{trashed[0..trashed_len]}, &.{t.p(&b1, "work/a b.txt")});
        defer op.destroy();
        op.run();
        try testing.expect(op.result == null);
        try testing.expect(t.has("work/a b.txt"));
        try testing.expect(!t.has("home/Trash/info/a b.txt.trashinfo"));
    }
}

test "free names keep compound extensions" {
    var t: Tmp = .{};
    try t.make();
    defer t.done();
    try t.sh("touch x.tar.gz");
    var buf: [linux.PATH_MAX]u8 = undefined;
    const p = try freeNameIn(&buf, t.path, "x.tar.gz");
    try testing.expectEqualStrings("x (2).tar.gz", model.basename(p));
}

test "modes as chmod(1) takes them" {
    const T = struct {
        fn check(spec: []const u8, old: u32, dir: bool, want: ?u32) !void {
            try std.testing.expectEqual(want, applyMode(spec, old, dir, 0o022));
        }
    };
    try T.check("755", 0o644, false, 0o755);
    try T.check("0600", 0o2755, true, 0o600);
    // Short octal modes keep a folder's setgid bit, as GNU chmod does.
    try T.check("755", 0o2700, true, 0o2755);
    try T.check("u+x", 0o644, false, 0o744);
    try T.check("go-w", 0o666, false, 0o644);
    try T.check("u=rw,go=", 0o777, false, 0o600);
    try T.check("ug+rw,o-rwx", 0o604, false, 0o660);
    // X: execute only for folders and files someone may run already.
    try T.check("a=rX", 0o644, false, 0o444);
    try T.check("a=rX", 0o744, false, 0o555);
    try T.check("a=rX", 0o700, true, 0o555);
    // Without u, g, o, or a, the umask's bits stay as they were.
    try T.check("+w", 0o444, false, 0o644);
    try T.check("+x", 0o644, false, 0o755);
    try T.check("=r", 0o666, false, 0o444 | 0o022);
    try T.check("g+s,+t", 0o755, true, 0o3755);
    try T.check("u+x-w", 0o644, false, 0o544);
    for ([_][]const u8{ "", "u", "u+q", "8", "77777", "u+x,", "+x y" }) |bad| try T.check(bad, 0o644, false, null);
}
