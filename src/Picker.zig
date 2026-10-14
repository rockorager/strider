//! The picker: a query typed in the command line over the best of many
//! candidates, for files and folders below the current folder (gf,
//! :fuzzy) and the folders zoxide knows (gz, :zi). Candidates arrive in
//! batches from a worker (a breadth-first walk, or `zoxide query`), so
//! the first results show while a big tree is still being read; each
//! keystroke scores them again, narrowing the last result when the query
//! only grew.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
const Window = @import("Window.zig");
const fuzzy = @import("fuzzy.zig");
const model = @import("model.zig");
const proc = @import("proc.zig");
const ui = @import("ui.zig");

const Picker = @This();
const Node = siv.Node;
const Txn = siv.Txn;

pub const Kind = enum { files, folders };

/// Rows the panel shows at once.
pub const rows = 10;

win: *Window,
panel: Node = .null,
kind: Kind = .files,
open: bool = false,
/// The folder files are found below (absolute, no trailing slash).
root: std.ArrayList(u8) = .empty,
paths: fuzzy.Paths = .{},
/// What the query matches, best first, and the buffer filtering swaps in.
matches: std.ArrayList(fuzzy.Match) = .empty,
spare: std.ArrayList(fuzzy.Match) = .empty,
query: std.ArrayList(u8) = .empty,
selected: usize = 0,
/// The worker is still reading candidates.
loading: bool = false,
/// Which open its deliveries belong to.
gen: u64 = 0,
source: ?*Source = null,

/// Pickers alive, for deliveries posted by workers to check against.
var live: [16]?*Picker = @splat(null);

pub fn init(win: *Window) Picker {
    return .{ .win = win };
}

pub fn deinit(p: *Picker) void {
    p.stop();
    for (&live) |*slot| if (slot.* == p) {
        slot.* = null;
    };
    const gpa = p.win.gpa;
    p.root.deinit(gpa);
    p.paths.deinit(gpa);
    p.matches.deinit(gpa);
    p.spare.deinit(gpa);
    p.query.deinit(gpa);
}

pub fn build(p: *Picker, txn: Txn, parent: Node) void {
    for (&live) |*slot| if (slot.* == null) {
        slot.* = p;
        break;
    };
    // Over the bottom of the columns, just above the status line.
    p.panel = c.siv_flex(txn, parent, &.{ .axis = .column, .gap = 2 });
    _ = c.siv_set_layout(txn, p.panel, &.{
        .align_y = .end,
        .inset_start = 8,
        .inset_end = 8,
        .inset_bottom = 66,
        .padding = .{ .start = 10, .end = 10, .top = 8, .bottom = 8 },
        .flags = .{ .inset_start = true, .inset_end = true, .inset_bottom = true },
    });
    _ = c.siv_set_visual(txn, p.panel, &.{ .background_token = .card_bg, .border_token = .border, .border_width = 1, .radius = .{ .top_start = 8, .top_end = 8, .bottom_start = 8, .bottom_end = 8 } });
    _ = c.siv_set_semantics(txn, p.panel, &.{ .role = .list, .label = "Results", .label_len = 7 });
    _ = c.siv_set_hidden(txn, p.panel, true);
}

/// The command line's label while the picker is open.
pub fn label(p: *const Picker) []const u8 {
    return switch (p.kind) {
        .files => "files:",
        .folders => "zoxide:",
    };
}

/// Opens for `kind` (files below `root`) and starts reading candidates.
pub fn start(p: *Picker, kind: Kind, root: []const u8, hidden: bool) void {
    p.stop();
    const gpa = p.win.gpa;
    p.kind = kind;
    p.open = true;
    p.gen +%= 1;
    p.root.clearRetainingCapacity();
    p.root.appendSlice(gpa, root) catch {};
    p.paths.bytes.clearRetainingCapacity();
    p.paths.offs.clearRetainingCapacity();
    p.matches.clearRetainingCapacity();
    p.query.clearRetainingCapacity();
    p.selected = 0;
    p.loading = true;
    const s = gpa.create(Source) catch return;
    s.* = .{ .gpa = gpa, .gen = p.gen, .sapp = p.win.app.app, .kind = kind, .root = gpa.dupe(u8, root) catch "", .hidden = hidden, .picker = p };
    p.source = s;
    // The destroy-notify runs if the job cannot start.
    if (c.siv_job_start(p.win.app.app, .{}, Source.work, null, Source.destroy, s) != .ok) p.source = null;
    p.render();
}

/// Stops reading and hides the panel.
pub fn close(p: *Picker) void {
    p.stop();
    p.open = false;
    const txn = p.win.begin() orelse return;
    _ = c.siv_set_hidden(txn, p.panel, true);
    ui.clear(txn, p.panel);
    _ = ui.commit(txn);
}

fn stop(p: *Picker) void {
    p.gen +%= 1;
    if (p.source) |s| {
        s.cancel.store(true, .release);
        s.picker = null;
    }
    p.source = null;
    p.loading = false;
}

/// The query changed.
pub fn setQuery(p: *Picker, q: []const u8) void {
    const gpa = p.win.gpa;
    // Narrow the last result when the query only grew (and no batch came
    // since, which `refilter` handles by scoring everything).
    const grew = p.query.items.len != 0 and std.mem.startsWith(u8, q, p.query.items);
    p.query.clearRetainingCapacity();
    p.query.appendSlice(gpa, q) catch {};
    if (grew) {
        std.mem.swap(std.ArrayList(fuzzy.Match), &p.matches, &p.spare);
        fuzzy.filter(gpa, &p.paths, p.spare.items, p.query.items, &p.matches) catch {};
    } else fuzzy.filter(gpa, &p.paths, null, p.query.items, &p.matches) catch {};
    p.selected = 0;
    p.render();
}

fn refilter(p: *Picker) void {
    fuzzy.filter(p.win.gpa, &p.paths, null, p.query.items, &p.matches) catch {};
    p.selected = @min(p.selected, p.matches.items.len -| 1);
    p.render();
}

pub fn move(p: *Picker, delta: i32) void {
    if (p.matches.items.len == 0) return;
    const to = @as(i64, @intCast(p.selected)) + delta;
    p.selected = @intCast(std.math.clamp(to, 0, @as(i64, @intCast(p.matches.items.len - 1))));
    p.render();
}

/// The selected result as an absolute path (folders end in "/"), or null.
pub fn chosen(p: *const Picker, buf: []u8) ?[]const u8 {
    if (p.selected >= p.matches.items.len) return null;
    const rel = p.paths.get(p.matches.items[p.selected].index);
    return switch (p.kind) {
        .files => std.fmt.bufPrint(buf, "{s}/{s}", .{ if (std.mem.eql(u8, p.root.items, "/")) "" else p.root.items, rel }) catch null,
        .folders => std.fmt.bufPrint(buf, "{s}/", .{rel}) catch null,
    };
}

fn render(p: *Picker) void {
    if (!p.open) return;
    const win = p.win;
    const gpa = win.gpa;
    const txn = win.begin() orelse return;
    defer _ = ui.commit(txn);
    ui.clear(txn, p.panel);
    _ = c.siv_set_hidden(txn, p.panel, false);
    var hb: [256]u8 = undefined;
    var nb1: [32]u8 = undefined;
    var nb2: [32]u8 = undefined;
    const what = switch (p.kind) {
        .files => "files and folders",
        .folders => "folders zoxide knows",
    };
    const head = std.fmt.bufPrint(&hb, "{s} of {s} {s}{s}", .{ grouped(&nb1, p.matches.items.len), grouped(&nb2, p.paths.len()), what, if (p.loading) " (reading…)" else "" }) catch "";
    _ = ui.text(txn, p.panel, head, .muted_fg, .caption);
    if (p.matches.items.len == 0) {
        const none: []const u8 = if (p.loading) "Reading…" else if (p.kind == .folders and p.paths.len() == 0) "zoxide knows no folders yet" else "Nothing matches";
        _ = ui.text(txn, p.panel, none, .muted_fg, .body);
        return;
    }
    // A window of rows that keeps the selection in view, best at the top.
    const top = if (p.selected >= rows) p.selected + 1 - rows else 0;
    const end = @min(p.matches.items.len, top + rows);
    var pos: std.ArrayList(u16) = .empty;
    defer pos.deinit(gpa);
    for (top..end) |i| {
        const m = p.matches.items[i];
        const text = p.paths.get(m.index);
        const selected = i == p.selected;
        const row = c.siv_flex(txn, p.panel, &.{ .axis = .row });
        _ = c.siv_set_layout(txn, row, &.{ .width = ui.fill(), .padding = .{ .start = 6, .end = 6, .top = 2, .bottom = 2 } });
        _ = c.siv_set_visual(txn, row, &.{ .background_token = if (selected) .selection_bg else .none, .radius = .{ .top_start = 4, .top_end = 4, .bottom_start = 4, .bottom_end = 4 } });
        _ = c.siv_set_semantics(txn, row, &.{ .role = .list_item, .label = text.ptr, .label_len = text.len, .selected = if (selected) .on else .off, .position = @intCast(i + 1), .set_size = @intCast(p.matches.items.len) });
        const t = c.siv_text(txn, row, text.ptr, text.len);
        const dir = std.mem.endsWith(u8, text, "/") or p.kind == .folders;
        _ = c.siv_set_text_style(txn, t, &.{ .color_token = if (selected) .selection_fg else if (dir) .accent else .card_fg, .size_role = .body, .direction = .ltr, .flags = .{ .no_wrap = true, .ellipsize = true } });
        // The matched characters stand out.
        pos.clearRetainingCapacity();
        _ = fuzzy.score(text, p.query.items, &pos, gpa);
        if (pos.items.len != 0) {
            const spans = gpa.alloc(siv.TextSpan, pos.items.len) catch continue;
            defer gpa.free(spans);
            for (pos.items, spans) |at, *s| s.* = .{ .start = at, .end = at + 1, .flags = .{ .color = true, .weight = true }, .color_token = if (selected) .selection_fg else .accent, .weight = .bold };
            _ = c.siv_set_text_spans(txn, t, &.{ .spans = spans.ptr, .spans_count = spans.len });
        }
    }
}

fn grouped(buf: []u8, n: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
}

// Reading candidates ---------------------------------------------------------------------

/// A worker reading candidates: a walk below the root, or zoxide's list.
const Source = struct {
    picker: ?*Picker,
    gpa: Allocator,
    gen: u64,
    sapp: siv.App,
    kind: Kind,
    root: []u8,
    hidden: bool,
    cancel: std.atomic.Value(bool) = .init(false),

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const s: *Source = @ptrCast(@alignCast(ud.?));
        switch (s.kind) {
            .files => {
                const w: fuzzy.Walk = .{ .gpa = s.gpa, .root = s.root, .hidden = s.hidden, .cancel = &s.cancel, .sink = sink, .ctx = s };
                w.run();
            },
            .folders => {
                const batch = s.gpa.create(fuzzy.Paths) catch return;
                batch.* = .{};
                // zoxide leaves out the folder it is asked from.
                var r = proc.run(s.gpa, &.{ "zoxide", "query", "--list", "--exclude", s.root }, .{ .max_output = 4 << 20, .cancel = &s.cancel, .timeout_ms = 10_000 }) catch null;
                if (r) |*res| {
                    defer res.deinit(s.gpa);
                    if (res.status == 0) {
                        var it = std.mem.tokenizeScalar(u8, res.output, '\n');
                        while (it.next()) |line| batch.append(s.gpa, line) catch break;
                    }
                }
                sink(s, batch, true);
            },
        }
    }

    /// On the worker: hands a batch to the UI thread.
    fn sink(ctx: ?*anyopaque, batch: *fuzzy.Paths, done: bool) void {
        const s: *Source = @ptrCast(@alignCast(ctx.?));
        const d = s.gpa.create(Delivery) catch return freeBatch(s.gpa, batch);
        d.* = .{ .gpa = s.gpa, .gen = s.gen, .batch = batch, .done = done };
        // On failure nothing runs, so the batch is freed here.
        if (c.siv_post(s.sapp, Delivery.deliver, Delivery.free, d) != .ok) Delivery.free(d);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const s: *Source = @ptrCast(@alignCast(ud.?));
        if (s.picker) |p| if (p.source == s) {
            p.source = null;
        };
        s.gpa.free(s.root);
        s.gpa.destroy(s);
    }
};

const Delivery = struct {
    gpa: Allocator,
    gen: u64,
    batch: *fuzzy.Paths,
    done: bool,

    fn deliver(ud: ?*anyopaque) callconv(.c) void {
        const d: *Delivery = @ptrCast(@alignCast(ud.?));
        const p = for (live) |slot| {
            if (slot) |x| if (x.open and x.gen == d.gen) break x;
        } else return;
        p.paths.take(p.win.gpa, d.batch) catch {};
        if (d.done) p.loading = false;
        p.refilter();
    }

    fn free(ud: ?*anyopaque) callconv(.c) void {
        const d: *Delivery = @ptrCast(@alignCast(ud.?));
        freeBatch(d.gpa, d.batch);
        d.gpa.destroy(d);
    }
};

fn freeBatch(gpa: Allocator, b: *fuzzy.Paths) void {
    b.deinit(gpa);
    gpa.destroy(b);
}
