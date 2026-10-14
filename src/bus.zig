//! Small helpers over siv's D-Bus calls (siv_dbus_*, D19): connecting,
//! starting messages, and reading the values UDisks2 and FileManager1
//! callers send.

const std = @import("std");
const siv = @import("siv");
const c = siv.c;

pub const Message = siv.DbusMessage;
pub const Reader = siv.DbusReader;

/// The system or session bus, or the bus at `address` (tests).
pub fn connect(app: siv.App, bus: siv.DbusBus, address: ?[]const u8) !siv.Dbus {
    var conn: siv.Dbus = .null;
    if (address) |a| {
        try siv.check(c.siv_dbus_connect(app, &.{ .bus = .address, .address = a.ptr, .address_len = a.len }, &conn));
    } else {
        try siv.check(c.siv_dbus_connect(app, &.{ .bus = bus }, &conn));
    }
    return conn;
}

pub fn newCall(conn: siv.Dbus, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, interactive: bool) !Message {
    return newCallFlags(conn, destination, path, interface, member, .{ .interactive = interactive });
}

/// With `.secret`, siv wipes the message's memory once it is sent.
pub fn newCallFlags(conn: siv.Dbus, destination: []const u8, path: []const u8, interface: []const u8, member: []const u8, flags: siv.DbusMessageFlags) !Message {
    var m: Message = .null;
    try siv.check(c.siv_dbus_new_call(conn, &.{
        .destination = destination.ptr,
        .destination_len = destination.len,
        .path = path.ptr,
        .path_len = path.len,
        .interface = interface.ptr,
        .interface_len = interface.len,
        .member = member.ptr,
        .member_len = member.len,
        .flags = flags,
    }, &m));
    return m;
}

pub fn writeString(m: Message, s: []const u8) void {
    c.siv_dbus_message_write_string(m, 's', s.ptr, s.len);
}

/// An empty a{sv}: the options most UDisks2 methods take.
pub fn writeNoOptions(m: Message) void {
    c.siv_dbus_message_write_open(m, 'a', "{sv}", 4);
    c.siv_dbus_message_write_close(m);
}

pub fn infoString(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

/// The next value's type code, 0 at the end of the container.
pub fn next(r: Reader) u8 {
    var t: u8 = 0;
    _ = c.siv_dbus_reader_read_type(r, &t);
    return t;
}

pub fn enter(r: Reader) bool {
    return c.siv_dbus_reader_read_enter(r) == .ok;
}

pub fn exit(r: Reader) void {
    _ = c.siv_dbus_reader_read_exit(r);
}

pub fn skip(r: Reader) void {
    _ = c.siv_dbus_reader_read_skip(r);
}

/// A string, object path, or signature, copied with `a`; null if the next
/// value is something else.
pub fn readString(r: Reader, a: std.mem.Allocator) ?[]u8 {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    if (c.siv_dbus_reader_read_string(r, &buf, buf.len, &len) != .ok) return null;
    if (len <= buf.len) return a.dupe(u8, buf[0..len]) catch null;
    const big = a.alloc(u8, len) catch return null;
    if (c.siv_dbus_reader_read_string(r, big.ptr, big.len, &len) != .ok) return null;
    return big;
}

pub fn readInt(r: Reader) ?i64 {
    var v: i64 = 0;
    if (c.siv_dbus_reader_read_int(r, &v) != .ok) return null;
    return v;
}

/// An `ay` holding a NUL-terminated path (UDisks2's device and mount
/// point arrays), without the NUL.
pub fn readBytePath(r: Reader, a: std.mem.Allocator) ?[]u8 {
    if (next(r) != 'a' or !enter(r)) return null;
    defer exit(r);
    var out: std.ArrayList(u8) = .empty;
    while (next(r) == 'y') {
        const b = readInt(r) orelse return null;
        if (b == 0) break;
        out.append(a, @intCast(b)) catch return null;
    }
    return out.items;
}

/// An `as` of file URIs as paths, copied with `a`; other URIs are left
/// out.
pub fn readFileUris(r: Reader, a: std.mem.Allocator) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (next(r) != 'a' or !enter(r)) return out.items;
    defer exit(r);
    const uri = @import("uri.zig");
    while (next(r) == 's') {
        const text = readString(r, a) orelse break;
        var buf: [std.os.linux.PATH_MAX]u8 = undefined;
        const p = uri.filePath(&buf, text) orelse continue;
        out.append(a, a.dupe(u8, p) catch continue) catch {};
    }
    return out.items;
}
