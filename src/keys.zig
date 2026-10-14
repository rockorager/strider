//! Keys as vim writes them ("gg", "<C-d>", "<Space>", "<S-Tab>"), keys
//! from siv's key events in the same form, and the keymap: sequences of
//! keys bound to commands or Lua functions, per mode, with the prefixes
//! the which-key popup lists.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Mods = packed struct(u8) {
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    /// Only for keys that type nothing (Shift+Tab); a typed character
    /// carries its shift in the character ("G").
    shift: bool = false,
    _: u4 = 0,
};

/// A character's code point, or an XKB keysym (0xff00 and up) for keys
/// that type nothing.
pub const Key = struct {
    code: u32,
    mods: Mods = .{},

    pub fn eql(a: Key, b: Key) bool {
        return a.code == b.code and @as(u8, @bitCast(a.mods)) == @as(u8, @bitCast(b.mods));
    }

    pub fn char(ch: u32) Key {
        return .{ .code = ch };
    }

    /// A printable character without modifiers.
    pub fn isChar(k: Key) bool {
        return @as(u8, @bitCast(k.mods)) == 0 and k.code < 0xff00 and k.code > 0x20;
    }
};

pub const sym = struct {
    pub const backspace: u32 = 0xff08;
    pub const tab: u32 = 0xff09;
    pub const @"return": u32 = 0xff0d;
    pub const escape: u32 = 0xff1b;
    pub const home: u32 = 0xff50;
    pub const left: u32 = 0xff51;
    pub const up: u32 = 0xff52;
    pub const right: u32 = 0xff53;
    pub const down: u32 = 0xff54;
    pub const page_up: u32 = 0xff55;
    pub const page_down: u32 = 0xff56;
    pub const end: u32 = 0xff57;
    pub const insert: u32 = 0xff63;
    pub const menu: u32 = 0xff67;
    pub const kp_enter: u32 = 0xff8d;
    pub const f1: u32 = 0xffbe;
    pub const delete: u32 = 0xffff;
    pub const iso_left_tab: u32 = 0xfe20;
};

const Name = struct { []const u8, u32 };
const names = [_]Name{
    .{ "Space", ' ' },        .{ "CR", sym.@"return" },     .{ "Enter", sym.@"return" }, .{ "Return", sym.@"return" },
    .{ "Esc", sym.escape },   .{ "Tab", sym.tab },          .{ "BS", sym.backspace },    .{ "Backspace", sym.backspace },
    .{ "Del", sym.delete },   .{ "Delete", sym.delete },    .{ "Up", sym.up },           .{ "Down", sym.down },
    .{ "Left", sym.left },    .{ "Right", sym.right },      .{ "Home", sym.home },       .{ "End", sym.end },
    .{ "PageUp", sym.page_up }, .{ "PageDown", sym.page_down }, .{ "Insert", sym.insert },  .{ "Menu", sym.menu },
    .{ "lt", '<' },           .{ "gt", '>' },               .{ "Bar", '|' },             .{ "Bslash", '\\' },
};

/// The name `format` gives a keysym or character, if it has one.
fn nameOf(code: u32) ?[]const u8 {
    if (code >= sym.f1 and code < sym.f1 + 24) return null;
    for (names) |n| if (n[1] == code) return n[0];
    return null;
}

pub const ParseError = error{ InvalidKey, TooLong };

/// Parses vim key notation into `out`; returns how many keys.
pub fn parse(spec: []const u8, out: []Key) ParseError!usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < spec.len) {
        if (n == out.len) return error.TooLong;
        if (spec[i] == '<') if (std.mem.indexOfScalarPos(u8, spec, i + 1, '>')) |close| {
            if (close > i + 1) {
                out[n] = try parseAngle(spec[i + 1 .. close]);
                n += 1;
                i = close + 1;
                continue;
            }
        };
        const len = std.unicode.utf8ByteSequenceLength(spec[i]) catch return error.InvalidKey;
        if (i + len > spec.len) return error.InvalidKey;
        const cp = std.unicode.utf8Decode(spec[i..][0..len]) catch return error.InvalidKey;
        out[n] = .{ .code = cp };
        n += 1;
        i += len;
    }
    return n;
}

fn parseAngle(inner: []const u8) ParseError!Key {
    var mods: Mods = .{};
    var rest = inner;
    // Modifier prefixes: C-, A-, M-, S-, D- (super).
    while (rest.len > 2 and rest[1] == '-') {
        switch (std.ascii.toLower(rest[0])) {
            'c' => mods.ctrl = true,
            'a', 'm' => mods.alt = true,
            's' => mods.shift = true,
            'd' => mods.super = true,
            else => return error.InvalidKey,
        }
        rest = rest[2..];
    }
    var code: u32 = 0;
    if (rest.len > 1 and (rest[0] == 'F' or rest[0] == 'f')) {
        if (std.fmt.parseInt(u32, rest[1..], 10)) |f| {
            if (f >= 1 and f <= 24) code = sym.f1 + f - 1;
        } else |_| {}
    }
    if (code == 0) for (names) |nm| {
        if (std.ascii.eqlIgnoreCase(nm[0], rest)) {
            code = nm[1];
            break;
        }
    };
    if (code == 0) {
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidKey;
        if (len != rest.len) return error.InvalidKey;
        code = std.unicode.utf8Decode(rest[0..len]) catch return error.InvalidKey;
    }
    // A shifted character is the character: <S-a> is "A".
    if (mods.shift and code < 0xff00 and code != ' ') {
        if (code < 128) code = std.ascii.toUpper(@intCast(code));
        mods.shift = false;
    }
    return .{ .code = code, .mods = mods };
}

/// The key a key event names, or null for modifier keys alone.
pub fn fromEvent(keysym: u32, text: []const u8, ctrl: bool, alt: bool, super: bool, shift: bool) ?Key {
    // Modifiers, Caps Lock, and the like.
    if (keysym >= 0xffe1 and keysym <= 0xffee) return null;
    if (keysym == 0xfe03) return null; // ISO_Level3_Shift
    if (keysym == 0) return null;
    const mods: Mods = .{ .ctrl = ctrl, .alt = alt, .super = super };
    if (!ctrl and !alt and !super and text.len > 0) {
        const len = std.unicode.utf8ByteSequenceLength(text[0]) catch 0;
        if (len == text.len) if (std.unicode.utf8Decode(text[0..len])) |cp| {
            if (cp >= 0x20 and cp != 0x7f) return .{ .code = cp };
        } else |_| {};
    }
    var code = keysym;
    var m = mods;
    if (code == sym.iso_left_tab) {
        code = sym.tab;
        m.shift = true;
    } else if (code == sym.kp_enter) {
        code = sym.@"return";
    } else if (code >= 0x01000000) {
        code -= 0x01000000;
    }
    if (code >= 0xff00) {
        m.shift = shift;
    } else if (code < 128 and m.ctrl and !shift) {
        code = std.ascii.toLower(@intCast(code));
    }
    return .{ .code = code, .mods = m };
}

/// Writes keys in vim notation.
pub fn format(buf: []u8, keys: []const Key) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (keys) |k| writeKey(&w, k) catch break;
    return w.buffered();
}

fn writeKey(w: *std.Io.Writer, k: Key) !void {
    const plain = @as(u8, @bitCast(k.mods)) == 0;
    const name = nameOf(k.code);
    if (plain and name == null and k.code < 0xff00 and k.code > 0x20) {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(k.code), &b) catch return;
        try w.writeAll(b[0..n]);
        return;
    }
    // "<" alone reads as itself in angle notation too.
    if (plain and (k.code == '<' or k.code == '>' or k.code == '|' or k.code == '\\')) {
        try w.writeByte(@intCast(k.code));
        return;
    }
    try w.writeByte('<');
    if (k.mods.ctrl) try w.writeAll("C-");
    if (k.mods.alt) try w.writeAll("A-");
    if (k.mods.super) try w.writeAll("D-");
    if (k.mods.shift) try w.writeAll("S-");
    if (k.code >= sym.f1 and k.code < sym.f1 + 24) {
        try w.print("F{d}", .{k.code - sym.f1 + 1});
    } else if (name) |nm| {
        try w.writeAll(nm);
    } else if (k.code < 0xff00) {
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(k.code), &b) catch return;
        try w.writeAll(b[0..n]);
    } else {
        try w.print("0x{x}", .{k.code});
    }
    try w.writeByte('>');
}

// The keymap ---------------------------------------------------------------------------

pub const Mode = enum {
    normal,
    visual,

    pub fn parse(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "n") or std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "v") or std.mem.eql(u8, s, "visual")) return .visual;
        return null;
    }
};

pub const Action = union(enum) {
    /// A command line, as typed after ":".
    command: []const u8,
    /// A Lua function, by its reference in the registry.
    lua: c_int,
};

pub const Binding = struct {
    mode: Mode,
    keys: []Key,
    action: Action,
    desc: []const u8,
};

pub const max_keys = 8;

pub const Keymap = struct {
    gpa: Allocator,
    bindings: std.ArrayList(Binding) = .empty,
    /// Called with a Lua action that is replaced, to release it.
    release: ?*const fn (ctx: ?*anyopaque, ref: c_int) void = null,
    release_ctx: ?*anyopaque = null,

    pub fn deinit(km: *Keymap) void {
        for (km.bindings.items) |*b| km.freeBinding(b);
        km.bindings.deinit(km.gpa);
    }

    fn freeBinding(km: *Keymap, b: *Binding) void {
        km.gpa.free(b.keys);
        km.gpa.free(b.desc);
        switch (b.action) {
            .command => |s| km.gpa.free(s),
            .lua => |ref| if (km.release) |r| r(km.release_ctx, ref),
        }
    }

    /// Binds `spec` in `mode`, replacing what it was bound to.
    pub fn map(km: *Keymap, mode: Mode, spec: []const u8, action: Action, desc: []const u8) !void {
        var buf: [max_keys]Key = undefined;
        const n = try parse(spec, &buf);
        if (n == 0) return error.InvalidKey;
        const keys = try km.gpa.dupe(Key, buf[0..n]);
        errdefer km.gpa.free(keys);
        const d = try km.gpa.dupe(u8, desc);
        errdefer km.gpa.free(d);
        const owned_action: Action = switch (action) {
            .command => |s| .{ .command = try km.gpa.dupe(u8, s) },
            .lua => action,
        };
        if (km.find(mode, keys)) |i| {
            km.freeBinding(&km.bindings.items[i]);
            km.bindings.items[i] = .{ .mode = mode, .keys = keys, .action = owned_action, .desc = d };
            return;
        }
        try km.bindings.append(km.gpa, .{ .mode = mode, .keys = keys, .action = owned_action, .desc = d });
    }

    /// Removes the binding of `spec` in `mode`; false if there was none.
    pub fn unmap(km: *Keymap, mode: Mode, spec: []const u8) !bool {
        var buf: [max_keys]Key = undefined;
        const n = try parse(spec, &buf);
        const i = km.find(mode, buf[0..n]) orelse return false;
        km.freeBinding(&km.bindings.items[i]);
        _ = km.bindings.orderedRemove(i);
        return true;
    }

    fn find(km: *const Keymap, mode: Mode, keys: []const Key) ?usize {
        for (km.bindings.items, 0..) |b, i| {
            if (b.mode == mode and seqEql(b.keys, keys)) return i;
        }
        return null;
    }

    pub const Match = struct {
        /// The binding the keys complete, if any.
        exact: ?*const Binding = null,
        /// Whether longer bindings start with the keys.
        prefix: bool = false,
    };

    /// What `keys` mean in `mode`; visual mode falls back to normal
    /// mode's bindings.
    pub fn lookup(km: *const Keymap, mode: Mode, keys: []const Key) Match {
        var m = km.lookupIn(mode, keys);
        if (mode != .normal and m.exact == null and !m.prefix) m = km.lookupIn(.normal, keys);
        return m;
    }

    fn lookupIn(km: *const Keymap, mode: Mode, keys: []const Key) Match {
        var m: Match = .{};
        for (km.bindings.items) |*b| {
            if (b.mode != mode or b.keys.len < keys.len) continue;
            if (!seqEql(b.keys[0..keys.len], keys)) continue;
            if (b.keys.len == keys.len) m.exact = b else m.prefix = true;
        }
        return m;
    }

    /// The bindings that continue `keys` (for the which-key popup), the
    /// mode's own before normal mode's, each next key once.
    pub fn continuations(km: *const Keymap, gpa: Allocator, mode: Mode, keys: []const Key) ![]*const Binding {
        var out: std.ArrayList(*const Binding) = .empty;
        errdefer out.deinit(gpa);
        const modes: []const Mode = if (mode == .normal) &.{.normal} else &.{ mode, .normal };
        for (modes) |md| for (km.bindings.items) |*b| {
            if (b.mode != md or b.keys.len <= keys.len) continue;
            if (!seqEql(b.keys[0..keys.len], keys)) continue;
            const next = b.keys[keys.len];
            var dup = false;
            for (out.items) |o| if (o.keys[keys.len].eql(next)) {
                dup = true;
                break;
            };
            if (!dup) try out.append(gpa, b);
        };
        return out.toOwnedSlice(gpa);
    }
};

pub fn seqEql(a: []const Key, b: []const Key) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

const testing = std.testing;

test "parse and format" {
    var buf: [8]Key = undefined;
    var n = try parse("gg", &buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 'g'), buf[1].code);
    n = try parse("<C-d>", &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(buf[0].mods.ctrl and buf[0].code == 'd');
    n = try parse("<S-Tab><Space>x<lt>", &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expect(buf[0].mods.shift and buf[0].code == sym.tab);
    try testing.expectEqual(@as(u32, ' '), buf[1].code);
    try testing.expectEqual(@as(u32, '<'), buf[3].code);
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("<S-Tab><Space>x<", format(&out, buf[0..n]));
    n = try parse("<S-a><A-1><F2>", &buf);
    try testing.expectEqualStrings("A<A-1><F2>", format(&out, buf[0..n]));
    try testing.expectError(error.InvalidKey, parse("<C-xyz>", &buf));
}

test "keys from events" {
    // Shift+g types "G".
    try testing.expect(fromEvent('G', "G", false, false, false, true).?.eql(.{ .code = 'G' }));
    // Ctrl+d types a control character; it is <C-d>.
    try testing.expect(fromEvent('d', "\x04", true, false, false, false).?.eql(.{ .code = 'd', .mods = .{ .ctrl = true } }));
    // Shift+Tab arrives as ISO_Left_Tab.
    try testing.expect(fromEvent(sym.iso_left_tab, "", false, false, false, true).?.eql(.{ .code = sym.tab, .mods = .{ .shift = true } }));
    try testing.expect(fromEvent(sym.@"return", "\r", false, false, false, false).?.eql(.{ .code = sym.@"return" }));
    try testing.expect(fromEvent(0xffe1, "", false, false, false, true) == null);
    try testing.expect(fromEvent(' ', " ", false, false, false, false).?.eql(.{ .code = ' ' }));
}

test "keymap lookup, prefixes, and visual fallback" {
    var km: Keymap = .{ .gpa = testing.allocator };
    defer km.deinit();
    try km.map(.normal, "gg", .{ .command = "top" }, "Top");
    try km.map(.normal, "gh", .{ .command = "cd ~" }, "Home");
    try km.map(.normal, "j", .{ .command = "down" }, "Down");
    try km.map(.visual, "<Esc>", .{ .command = "visual-end" }, "");
    try km.map(.normal, "j", .{ .command = "down 1" }, "Down");
    var buf: [8]Key = undefined;
    var n = try parse("g", &buf);
    var m = km.lookup(.normal, buf[0..n]);
    try testing.expect(m.exact == null and m.prefix);
    const conts = try km.continuations(testing.allocator, .normal, buf[0..n]);
    defer testing.allocator.free(conts);
    try testing.expectEqual(@as(usize, 2), conts.len);
    n = try parse("j", &buf);
    m = km.lookup(.visual, buf[0..n]);
    try testing.expectEqualStrings("down 1", m.exact.?.action.command);
    try testing.expect(try km.unmap(.normal, "gg"));
    n = try parse("gg", &buf);
    try testing.expect(km.lookup(.normal, buf[0..n]).exact == null);
}
