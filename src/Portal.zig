//! org.freedesktop.impl.portal.FileChooser on the session bus: the
//! desktop's file chooser. xdg-desktop-portal routes applications'
//! OpenFile, SaveFile, and SaveFiles here when portals.conf names this
//! backend (README.md); each call opens a chooser window (Chooser.zig)
//! and is answered when the user picks or cancels. The request's handle
//! carries an org.freedesktop.impl.portal.Request object whose Close
//! ends it (response 2).
//!
//! The bus starts the program for the name (its D-Bus service file), and
//! one instance serves every window, so a request opens a window in the
//! instance already running when there is one.

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const bus = @import("bus.zig");
const App = @import("App.zig");
const Chooser = @import("Chooser.zig");

const Portal = @This();

pub const name = "org.freedesktop.impl.portal.desktop.siv_columns";
pub const path = "/org/freedesktop/portal/desktop";
pub const interface = "org.freedesktop.impl.portal.FileChooser";
const request_interface = "org.freedesktop.impl.portal.Request";

app: *App,
conn: siv.Dbus,

pub fn create(app: *App) !*Portal {
    const conn = try bus.connect(app.app, .session, app.opts.session_bus);
    errdefer c.siv_dbus_disconnect(conn);
    const self = try app.gpa.create(Portal);
    errdefer app.gpa.destroy(self);
    self.* = .{ .app = app, .conn = conn };
    const methods = [_]siv.DbusMethod{ method("OpenFile"), method("SaveFile"), method("SaveFiles") };
    var object: siv.DbusObject = .null;
    try siv.check(c.siv_dbus_export(conn, &.{
        .path = path,
        .path_len = path.len,
        .interface = interface,
        .interface_len = interface.len,
        .methods = &methods,
        .methods_count = methods.len,
        .user_data = self,
        .on_call = onCall,
    }, &object));
    var request: siv.DbusName = .null;
    try siv.check(c.siv_dbus_own_name(conn, name, name.len, .{}, null, null, null, &request));
    return self;
}

fn method(comptime n: []const u8) siv.DbusMethod {
    return .{ .name = n.ptr, .name_len = n.len, .in_signature = "osssa{sv}", .in_signature_len = 9, .out_signature = "ua{sv}", .out_signature_len = 6 };
}

pub fn destroy(self: *Portal) void {
    c.siv_dbus_disconnect(self.conn);
    self.app.gpa.destroy(self);
}

fn onCall(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, args: siv.DbusReader, inv: siv.DbusInvocation) callconv(.c) void {
    const self: *Portal = @ptrCast(@alignCast(ud.?));
    const member = bus.infoString(info.member, info.member_len);
    const kind: Chooser.Kind = if (std.mem.eql(u8, member, "SaveFile")) .save else if (std.mem.eql(u8, member, "SaveFiles")) .save_files else .open;
    const ch = Chooser.create(self.app, kind, self.conn, inv) catch {
        _ = c.siv_dbus_invocation_reply_error(inv, "org.freedesktop.DBus.Error.NoMemory", 35, "", 0);
        return;
    };
    ch.read(args);
    // The Request object, for Close.
    if (ch.handle.len != 0) {
        const methods = [_]siv.DbusMethod{.{ .name = "Close", .name_len = 5 }};
        _ = c.siv_dbus_export(self.conn, &.{
            .path = ch.handle.ptr,
            .path_len = ch.handle.len,
            .interface = request_interface,
            .interface_len = request_interface.len,
            .methods = &methods,
            .methods_count = methods.len,
            .user_data = ch,
            .on_call = onClose,
        }, &ch.request);
    }
    self.app.openChooser(ch);
}

/// The caller (or xdg-desktop-portal) gave up on the request: answered
/// with 2, after this call returns (ending destroys this object).
fn onClose(ud: ?*anyopaque, _: *const siv.DbusMessageInfo, _: siv.DbusReader, inv: siv.DbusInvocation) callconv(.c) void {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    var reply: siv.DbusMessage = .null;
    if (c.siv_dbus_invocation_new_reply(inv, &reply) == .ok) _ = c.siv_dbus_message_send(reply);
    if (ch.closing) return;
    ch.closing = true;
    if (c.siv_timer_start(ch.app.app, 0, onCloseLater, null, ch, &ch.close_timer) != .ok) ch.finish(2);
}

fn onCloseLater(ud: ?*anyopaque) callconv(.c) void {
    const ch: *Chooser = @ptrCast(@alignCast(ud.?));
    ch.close_timer = .null;
    ch.finish(2);
}
