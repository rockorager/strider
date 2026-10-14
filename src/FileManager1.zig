//! org.freedesktop.FileManager1 on the session bus: other applications'
//! "Show in folder" (ShowItems), "Open folder" (ShowFolders), and
//! "Properties" (ShowItemProperties) land here.
//!
//! The name is requested with queueing and allowing replacement: a file
//! manager that runs first keeps it, this one takes over when that one
//! quits, and a file manager the user prefers can take it from this one.
//! The bus starts the program for the name only when it was installed
//! with -Dfilemanager1=true (README.md).

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const bus = @import("bus.zig");
const App = @import("App.zig");

const FileManager1 = @This();

pub const name = "org.freedesktop.FileManager1";
const path = "/org/freedesktop/FileManager1";

app: *App,
conn: siv.Dbus,

pub fn create(app: *App) !*FileManager1 {
    const conn = try bus.connect(app.app, .session, app.opts.session_bus);
    errdefer c.siv_dbus_disconnect(conn);
    const self = try app.gpa.create(FileManager1);
    errdefer app.gpa.destroy(self);
    self.* = .{ .app = app, .conn = conn };
    const methods = [_]siv.DbusMethod{
        method("ShowFolders"),
        method("ShowItems"),
        method("ShowItemProperties"),
    };
    var object: siv.DbusObject = .null;
    try siv.check(c.siv_dbus_export(conn, &.{
        .path = path,
        .path_len = path.len,
        .interface = name,
        .interface_len = name.len,
        .methods = &methods,
        .methods_count = methods.len,
        .user_data = self,
        .on_call = onCall,
    }, &object));
    var request: siv.DbusName = .null;
    try siv.check(c.siv_dbus_own_name(conn, name, name.len, .{ .allow_replacement = true }, null, null, null, &request));
    return self;
}

fn method(comptime n: []const u8) siv.DbusMethod {
    return .{ .name = n.ptr, .name_len = n.len, .in_signature = "ass", .in_signature_len = 3 };
}

pub fn destroy(self: *FileManager1) void {
    // On the session bus this drops only what was made on this handle.
    c.siv_dbus_disconnect(self.conn);
    self.app.gpa.destroy(self);
}

fn onCall(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, args: siv.DbusReader, inv: siv.DbusInvocation) callconv(.c) void {
    const self: *FileManager1 = @ptrCast(@alignCast(ud.?));
    var arena: std.heap.ArenaAllocator = .init(self.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = bus.readFileUris(args, a);
    const token = bus.readString(args, a) orelse "";
    // Answer first: the caller does not wait for the windows.
    var reply: siv.DbusMessage = .null;
    if (c.siv_dbus_invocation_new_reply(inv, &reply) == .ok) _ = c.siv_dbus_message_send(reply);
    if (paths.len == 0) return;
    const member = bus.infoString(info.member, info.member_len);
    if (std.mem.eql(u8, member, "ShowFolders")) {
        self.app.showPaths(paths, false, token);
    } else if (std.mem.eql(u8, member, "ShowItems")) {
        self.app.showItems(paths, token);
    } else {
        self.app.showProperties(paths, token);
    }
}
