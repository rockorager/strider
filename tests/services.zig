//! The D-Bus services against a private dbus-daemon: drives from a
//! stand-in UDisks2 (mount, browse, unmount and eject), and
//! org.freedesktop.FileManager1 called as another application would.
//! Skipped where dbus-daemon is not installed.

const std = @import("std");
const linux = std.os.linux;
const siv = @import("siv");
const c = siv.c;
const h_mod = @import("harness.zig");
const Harness = h_mod.Harness;
const Fixture = h_mod.Fixture;
const App = h_mod.App;

const testing = std.testing;

extern "c" fn system(cmd: [*:0]const u8) c_int;

/// `dbus-daemon --session` on a socket of its own, stopped afterwards.
const Daemon = struct {
    address: [256]u8 = undefined,
    address_len: usize = 0,
    pid: i32 = 0,
    dir: []const u8 = "",

    fn start(d: *Daemon, dir: []const u8) !void {
        d.dir = dir;
        var cmd: [512]u8 = undefined;
        // Beside the fixture, not in it, so captures do not show it.
        const out = try std.fmt.bufPrint(&d.address, "{s}.bus", .{dir});
        const z = try std.fmt.bufPrintSentinel(&cmd, "dbus-daemon --session --fork --print-address=1 --print-pid=1 > '{s}' 2>/dev/null", .{out}, 0);
        if (system(z.ptr) != 0) return error.SkipZigTest;
        var buf: [512]u8 = undefined;
        var zpath: [256]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&zpath, "{s}", .{out}, 0);
        const rc = linux.openat(linux.AT.FDCWD, p, .{ .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) return error.Unexpected;
        var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
        const address = lines.next() orelse return error.Unexpected;
        d.pid = try std.fmt.parseInt(i32, lines.next() orelse return error.Unexpected, 10);
        @memcpy(d.address[0..address.len], address);
        d.address_len = address.len;
    }

    fn addr(d: *const Daemon) []const u8 {
        return d.address[0..d.address_len];
    }

    fn stop(d: *Daemon) void {
        if (d.pid > 0) _ = linux.kill(d.pid, linux.SIG.TERM);
        var buf: [300]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}.bus", .{d.dir}, 0) catch return;
        _ = linux.unlinkat(linux.AT.FDCWD, p, 0);
    }
};

fn str(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

fn writeStr(m: siv.DbusMessage, ty: u8, s: []const u8) void {
    c.siv_dbus_message_write_string(m, ty, s.ptr, s.len);
}

fn open(m: siv.DbusMessage, ty: u8, sig: []const u8) void {
    c.siv_dbus_message_write_open(m, ty, sig.ptr, sig.len);
}

fn close(m: siv.DbusMessage) void {
    c.siv_dbus_message_write_close(m);
}

/// One {sv} entry.
fn entry(m: siv.DbusMessage, name: []const u8, sig: []const u8) void {
    open(m, 'e', "");
    writeStr(m, 's', name);
    open(m, 'v', sig);
}

fn endEntry(m: siv.DbusMessage) void {
    close(m);
    close(m);
}

/// A stand-in UDisks2, written against siv's D-Bus API as a service
/// would be: a USB stick with a plain file system (sdb1) and a LUKS
/// volume (sdc1) whose passphrase is "hunter2", unlocked as dm-0.
const FakeUDisks = struct {
    conn: siv.Dbus = .null,
    mount_dir: []const u8 = "",
    secret_dir: []const u8 = "",
    mounted: bool = false,
    unlocked: bool = false,
    secret_mounted: bool = false,
    /// Methods called, in order ("Mount sdb1", "Unlock sdc1", ...).
    calls: std.ArrayList([]const u8) = .empty,

    const prefix = "/org/freedesktop/UDisks2/";
    const block = prefix ++ "block_devices/sdb1";
    const crypt = prefix ++ "block_devices/sdc1";
    const clear = prefix ++ "block_devices/dm_2d0";
    const drive = prefix ++ "drives/Stick";

    fn start(u: *FakeUDisks, app: siv.App, address: []const u8) !void {
        try siv.check(c.siv_dbus_connect(app, &.{ .bus = .address, .address = address.ptr, .address_len = address.len }, &u.conn));
        const om = [_]siv.DbusMethod{method("GetManagedObjects", "", "a{oa{sa{sv}}}")};
        const fs = [_]siv.DbusMethod{ method("Mount", "a{sv}", "s"), method("Unmount", "a{sv}", "") };
        const enc = [_]siv.DbusMethod{ method("Unlock", "sa{sv}", "o"), method("Lock", "a{sv}", "") };
        const dr = [_]siv.DbusMethod{ method("Eject", "a{sv}", ""), method("PowerOff", "a{sv}", "") };
        const objects = [_]struct { []const u8, []const u8, []const siv.DbusMethod }{
            .{ "/org/freedesktop/UDisks2", "org.freedesktop.DBus.ObjectManager", &om },
            .{ block, "org.freedesktop.UDisks2.Filesystem", &fs },
            .{ crypt, "org.freedesktop.UDisks2.Encrypted", &enc },
            .{ clear, "org.freedesktop.UDisks2.Filesystem", &fs },
            .{ drive, "org.freedesktop.UDisks2.Drive", &dr },
        };
        for (objects) |o| {
            var obj: siv.DbusObject = .null;
            try siv.check(c.siv_dbus_export(u.conn, &.{
                .path = o[0].ptr,
                .path_len = o[0].len,
                .interface = o[1].ptr,
                .interface_len = o[1].len,
                .methods = o[2].ptr,
                .methods_count = o[2].len,
                .user_data = u,
                .on_call = onCall,
            }, &obj));
        }
        var name: siv.DbusName = .null;
        try siv.check(c.siv_dbus_own_name(u.conn, "org.freedesktop.UDisks2", 23, .{}, null, null, null, &name));
    }

    fn method(comptime n: []const u8, comptime in: []const u8, comptime out: []const u8) siv.DbusMethod {
        return .{ .name = n.ptr, .name_len = n.len, .in_signature = in.ptr, .in_signature_len = in.len, .out_signature = out.ptr, .out_signature_len = out.len };
    }

    fn deinit(u: *FakeUDisks) void {
        for (u.calls.items) |x| testing.allocator.free(x);
        u.calls.deinit(testing.allocator);
    }

    fn called(u: *const FakeUDisks, what: []const u8) bool {
        for (u.calls.items) |x| if (std.mem.eql(u8, x, what)) return true;
        return false;
    }

    fn onCall(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, args: siv.DbusReader, inv: siv.DbusInvocation) callconv(.c) void {
        const u: *FakeUDisks = @ptrCast(@alignCast(ud.?));
        const member = str(info.member, info.member_len);
        const path = str(info.path, info.path_len);
        const eql = std.mem.eql;
        if (eql(u8, member, "GetManagedObjects")) {
            var m: siv.DbusMessage = .null;
            siv.check(c.siv_dbus_invocation_new_reply(inv, &m)) catch return;
            u.writeObjects(m);
            _ = c.siv_dbus_message_send(m);
            return;
        }
        const entry_ = std.fmt.allocPrint(testing.allocator, "{s} {s}", .{ member, std.fs.path.basename(path) }) catch return;
        u.calls.append(testing.allocator, entry_) catch {};
        if (eql(u8, member, "Unlock")) {
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            _ = c.siv_dbus_reader_read_string(args, &buf, buf.len, &len);
            if (!eql(u8, buf[0..@min(len, buf.len)], "hunter2")) {
                const e = "org.freedesktop.UDisks2.Error.Failed";
                const msg = "Error unlocking /dev/sdc1: Failed to activate device: Operation not permitted (Incorrect passphrase?)";
                _ = c.siv_dbus_invocation_reply_error(inv, e, e.len, msg, msg.len);
                return;
            }
            u.unlocked = true;
        }
        var m: siv.DbusMessage = .null;
        siv.check(c.siv_dbus_invocation_new_reply(inv, &m)) catch return;
        const secret = eql(u8, path, clear);
        if (eql(u8, member, "Mount")) {
            if (secret) u.secret_mounted = true else u.mounted = true;
            writeStr(m, 's', if (secret) u.secret_dir else u.mount_dir);
        } else if (eql(u8, member, "Unmount")) {
            if (secret) u.secret_mounted = false else u.mounted = false;
        } else if (eql(u8, member, "Unlock")) {
            writeStr(m, 'o', clear);
        } else if (eql(u8, member, "Lock")) {
            u.unlocked = false;
            u.secret_mounted = false;
        }
        _ = c.siv_dbus_message_send(m);
        u.changed(if (secret) clear else block);
    }

    fn object(m: siv.DbusMessage, path: []const u8) void {
        open(m, 'e', "");
        writeStr(m, 'o', path);
        open(m, 'a', "{sa{sv}}");
    }

    fn iface(m: siv.DbusMessage, name: []const u8) void {
        open(m, 'e', "");
        writeStr(m, 's', name);
        open(m, 'a', "{sv}");
    }

    /// Closes an interface or an object.
    fn end(m: siv.DbusMessage) void {
        close(m);
        close(m);
    }

    fn propStr(m: siv.DbusMessage, name: []const u8, ty: u8, value: []const u8) void {
        entry(m, name, &.{ty});
        writeStr(m, ty, value);
        endEntry(m);
    }

    fn propInt(m: siv.DbusMessage, name: []const u8, ty: u8, value: i64) void {
        entry(m, name, &.{ty});
        c.siv_dbus_message_write_int(m, ty, value);
        endEntry(m);
    }

    fn mountPoints(m: siv.DbusMessage, dir: ?[]const u8) void {
        entry(m, "MountPoints", "aay");
        open(m, 'a', "ay");
        if (dir) |d| {
            open(m, 'a', "y");
            for (d) |b| c.siv_dbus_message_write_int(m, 'y', b);
            c.siv_dbus_message_write_int(m, 'y', 0);
            close(m);
        }
        close(m);
        endEntry(m);
    }

    fn writeObjects(u: *FakeUDisks, m: siv.DbusMessage) void {
        open(m, 'a', "{oa{sa{sv}}}");
        // The plain file system.
        object(m, block);
        iface(m, "org.freedesktop.UDisks2.Block");
        propStr(m, "Drive", 'o', drive);
        propStr(m, "IdLabel", 's', "STICK");
        propInt(m, "HintSystem", 'b', 0);
        propInt(m, "Size", 't', 16_000_000_000);
        end(m);
        iface(m, "org.freedesktop.UDisks2.Filesystem");
        mountPoints(m, if (u.mounted) u.mount_dir else null);
        end(m);
        end(m);
        // The encrypted volume, and its cleartext device while unlocked.
        object(m, crypt);
        iface(m, "org.freedesktop.UDisks2.Block");
        propStr(m, "Drive", 'o', drive);
        propStr(m, "IdLabel", 's', "SECRET");
        propInt(m, "HintSystem", 'b', 0);
        propInt(m, "Size", 't', 8_000_000_000);
        end(m);
        iface(m, "org.freedesktop.UDisks2.Encrypted");
        propStr(m, "CleartextDevice", 'o', if (u.unlocked) clear else "/");
        end(m);
        end(m);
        if (u.unlocked) {
            object(m, clear);
            iface(m, "org.freedesktop.UDisks2.Block");
            propStr(m, "Drive", 'o', "/");
            propStr(m, "CryptoBackingDevice", 'o', crypt);
            propStr(m, "IdLabel", 's', "SECRET");
            propInt(m, "HintSystem", 'b', 1);
            end(m);
            iface(m, "org.freedesktop.UDisks2.Filesystem");
            mountPoints(m, if (u.secret_mounted) u.secret_dir else null);
            end(m);
            end(m);
        }
        // Their drive.
        object(m, drive);
        iface(m, "org.freedesktop.UDisks2.Drive");
        propInt(m, "Removable", 'b', 1);
        propInt(m, "Ejectable", 'b', 0);
        propInt(m, "CanPowerOff", 'b', 1);
        end(m);
        end(m);
        close(m);
    }

    /// PropertiesChanged on a block device, as UDisks2 sends when a mount
    /// changes.
    fn changed(u: *FakeUDisks, path: []const u8) void {
        var m: siv.DbusMessage = .null;
        const props = "org.freedesktop.DBus.Properties";
        siv.check(c.siv_dbus_new_signal(u.conn, &.{ .path = path.ptr, .path_len = path.len, .interface = props, .interface_len = props.len, .member = "PropertiesChanged", .member_len = 17 }, &m)) catch return;
        writeStr(m, 's', "org.freedesktop.UDisks2.Filesystem");
        open(m, 'a', "{sv}");
        close(m);
        open(m, 'a', "s");
        writeStr(m, 's', "MountPoints");
        close(m);
        _ = c.siv_dbus_message_send(m);
    }
};

fn driveNamed(h: *Harness, label: []const u8) ?App.places_mod.Drive {
    for (h.app.?.places.drives.items) |d| if (std.mem.eql(u8, d.label, label)) return d;
    return null;
}

fn drives(h: *Harness) usize {
    return h.app.?.places.drives.items.len;
}

fn inDir(h: *Harness, suffix: []const u8, n: u32) bool {
    const d = h.dir();
    return std.mem.endsWith(u8, d.path, suffix) and d.count() == n;
}

test "drives from UDisks2: mount, browse, unmount and power off" {
    var f: Fixture = .{};
    try f.create("udisks", &.{ .{ .name = "home", .dir = true }, .{ .name = "Stick", .dir = true }, .{ .name = "Stick/on-the-stick.txt", .size = 10 } });
    defer f.remove();
    try f.touch("Stick", 1_791_900_300);
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    var u: FakeUDisks = .{ .mount_dir = f.sub(&mount_buf, "Stick") };
    defer u.deinit();
    try u.start(h.sapp, d.addr());
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return drives(x) == 2;
        }
    }.ok);
    const drive = driveNamed(&h, "STICK").?;
    try testing.expectEqualStrings("", drive.mount_point);
    try testing.expect(drive.can_mount and drive.can_eject);
    // gv lists the drives; its key mounts the stick and goes there.
    try h.typeText("gv");
    const menu = h.popup();
    try testing.expect(menu != .null);
    try h.expectGolden(menu, "drives-menu");
    try testing.expect(h.find(menu, .{ .role = .menu_item, .name = "Mount STICK — 16.0 GB", .name_len = "Mount STICK — 16.0 GB".len }) != null);
    try siv.check(c.siv_test_key(menu, @enumFromInt('2'), .{}, "2", 1));
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return inDir(x, "/Stick", 1);
        }
    }.ok);
    try testing.expectEqualStrings("on-the-stick.txt", h.hovered());
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return driveNamed(x, "STICK").?.mount_point.len != 0;
        }
    }.ok);
    // :eject unmounts it, sends the tab out of it, and powers the stick
    // off (it is removable, not ejectable).
    try h.typeText(":eject\n");
    try h.waitFor(&u, struct {
        fn ok(x: *FakeUDisks) bool {
            return x.called("PowerOff Stick");
        }
    }.ok);
    try testing.expectEqualStrings(f.path, h.dir().path);
    try testing.expect(!u.mounted);
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return driveNamed(x, "STICK").?.mount_point.len == 0;
        }
    }.ok);
    try testing.expectEqualStrings("“STICK” can be removed", h.win.?.message.items);
}

test "encrypted volumes: a passphrase unlocks and mounts; eject locks" {
    var f: Fixture = .{};
    try f.create("udisks-luks", &.{ .{ .name = "home", .dir = true }, .{ .name = "Secret", .dir = true }, .{ .name = "Secret/diary.txt", .size = 20 } });
    defer f.remove();
    try f.touch("Secret", 1_791_900_300);
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    var u: FakeUDisks = .{ .secret_dir = f.sub(&mount_buf, "Secret") };
    defer u.deinit();
    try u.start(h.sapp, d.addr());
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return driveNamed(x, "SECRET") != null;
        }
    }.ok);
    try testing.expect(driveNamed(&h, "SECRET").?.can_mount);
    // :mount SECRET asks for the passphrase in a masked field.
    try h.typeText(":mount SECRET\n");
    try testing.expectEqual(App.Window.PromptKind.passphrase, h.win.?.prompt.?);
    _ = try h.expect(.text_input, "Passphrase");
    // A wrong one: the status line says so and it asks again.
    try h.typeText("wrong\n");
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return x.win.?.prompt != null and std.mem.eql(u8, x.win.?.message.items, "Wrong passphrase. Try again. Unlock “SECRET”");
        }
    }.ok);
    try testing.expect(!u.unlocked);
    try h.typeText("hunter2");
    try h.expectGolden(h.window(), "unlock");
    try h.typeText("\n");
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            return inDir(x, "/Secret", 1);
        }
    }.ok);
    try testing.expect(h.win.?.prompt == null);
    try testing.expectEqualStrings("diary.txt", h.hovered());
    try testing.expectEqualStrings("Unlock sdc1", u.calls.items[1]);
    try testing.expectEqualStrings("Mount dm_2d0", u.calls.items[2]);
    try h.waitFor(&h, struct {
        fn ok(x: *Harness) bool {
            const s = driveNamed(x, "SECRET") orelse return false;
            return s.mount_point.len != 0;
        }
    }.ok);
    // Eject: unmount, lock, then power the drive off.
    try h.typeText(":eject\n");
    try h.waitFor(&u, struct {
        fn ok(x: *FakeUDisks) bool {
            return x.called("PowerOff Stick");
        }
    }.ok);
    try testing.expectEqualStrings("Unmount dm_2d0", u.calls.items[3]);
    try testing.expectEqualStrings("Lock sdc1", u.calls.items[4]);
    try testing.expect(!u.unlocked);
}

var mount_buf: [256]u8 = undefined;

const Called = struct {
    done: bool = false,
    err: [128]u8 = undefined,
    err_len: usize = 0,

    fn onReply(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, _: siv.DbusReader) callconv(.c) void {
        const x: *Called = @ptrCast(@alignCast(ud.?));
        x.done = true;
        const e = str(info.error_name, info.error_name_len);
        @memcpy(x.err[0..e.len], e);
        x.err_len = e.len;
    }
};

fn callFileManager(h: *Harness, conn: siv.Dbus, member: []const u8, uri: []const u8) !void {
    const fm = "org.freedesktop.FileManager1";
    const path = "/org/freedesktop/FileManager1";
    var m: siv.DbusMessage = .null;
    try siv.check(c.siv_dbus_new_call(conn, &.{ .destination = fm, .destination_len = fm.len, .path = path, .path_len = path.len, .interface = fm, .interface_len = fm.len, .member = member.ptr, .member_len = member.len }, &m));
    open(m, 'a', "s");
    writeStr(m, 's', uri);
    close(m);
    writeStr(m, 's', "");
    var called: Called = .{};
    try siv.check(c.siv_dbus_message_call(m, 0, Called.onReply, null, &called));
    try h.waitFor(&called, struct {
        fn ok(x: *Called) bool {
            return x.done;
        }
    }.ok);
    try testing.expectEqualStrings("", called.err[0..called.err_len]);
}

test "FileManager1: show items, folders, and properties for other applications" {
    var f: Fixture = .{};
    try f.create("fm1", &.{ .{ .name = "home", .dir = true }, .{ .name = "Projects", .dir = true }, .{ .name = "Projects/siv", .dir = true }, .{ .name = "notes.txt", .size = 3 } });
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    const win = h.win.?;
    // ShowItems: a folder is shown under the cursor in its parent, not
    // opened, in a new tab.
    var buf: [512]u8 = undefined;
    try callFileManager(&h, client, "ShowItems", try std.fmt.bufPrint(&buf, "file://{s}/Projects/siv", .{f.path}));
    try h.settle();
    try testing.expectEqual(@as(usize, 2), win.tabs.items.len);
    try testing.expect(std.mem.endsWith(u8, h.dir().path, "/Projects"));
    try testing.expectEqualStrings("siv", h.hovered());
    // ShowFolders opens the folder itself.
    try callFileManager(&h, client, "ShowFolders", try std.fmt.bufPrint(&buf, "file://{s}/Projects/siv", .{f.path}));
    try h.settle();
    try testing.expectEqual(@as(usize, 3), win.tabs.items.len);
    try testing.expect(std.mem.endsWith(u8, h.dir().path, "/Projects/siv"));
    // ShowItemProperties: the file under the cursor, its details in the
    // preview.
    try callFileManager(&h, client, "ShowItemProperties", try std.fmt.bufPrint(&buf, "file://{s}/notes.txt", .{f.path}));
    try h.settle();
    try testing.expectEqualStrings("notes.txt", h.hovered());
    try testing.expectEqual(@as(usize, 4), win.tabs.items.len);
    // A file manager the user prefers can take the name over.
    var state: Owned = .{};
    var name: siv.DbusName = .null;
    const fm = "org.freedesktop.FileManager1";
    try siv.check(c.siv_dbus_own_name(client, fm, fm.len, .{ .replace_existing = true, .do_not_queue = true }, Owned.onState, null, &state, &name));
    try h.waitFor(&state, struct {
        fn ok(x: *Owned) bool {
            return x.state != null;
        }
    }.ok);
    try testing.expectEqual(siv.DbusNameState.primary, state.state.?);
}

const Owned = struct {
    state: ?siv.DbusNameState = null,

    fn onState(ud: ?*anyopaque, _: siv.DbusName, s: siv.DbusNameState) callconv(.c) void {
        const x: *Owned = @ptrCast(@alignCast(ud.?));
        x.state = s;
    }
};

// The FileChooser portal --------------------------------------------------------------------

const portal_name = "org.freedesktop.impl.portal.desktop.siv_columns";

/// A FileChooser call as xdg-desktop-portal makes it, and its answer.
const Chosen = struct {
    done: bool = false,
    err: [128]u8 = undefined,
    err_len: usize = 0,
    response: u32 = 99,
    uris: [8][512]u8 = undefined,
    uri_lens: [8]usize = @splat(0),
    n_uris: usize = 0,
    choices: [4][2][64]u8 = undefined,
    choice_lens: [4][2]usize = undefined,
    n_choices: usize = 0,
    filter: [64]u8 = undefined,
    filter_len: usize = 0,

    fn uri(x: *const Chosen, i: usize) []const u8 {
        return x.uris[i][0..x.uri_lens[i]];
    }

    fn choice(x: *const Chosen, id: []const u8) []const u8 {
        for (0..x.n_choices) |i| if (std.mem.eql(u8, x.choices[i][0][0..x.choice_lens[i][0]], id)) return x.choices[i][1][0..x.choice_lens[i][1]];
        return "";
    }

    fn readStr(r: siv.DbusReader, buf: []u8) usize {
        var len: usize = 0;
        if (c.siv_dbus_reader_read_string(r, buf.ptr, buf.len, &len) != .ok) return 0;
        return @min(len, buf.len);
    }

    fn next(r: siv.DbusReader) u8 {
        var t: u8 = 0;
        _ = c.siv_dbus_reader_read_type(r, &t);
        return t;
    }

    fn onReply(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, r: siv.DbusReader) callconv(.c) void {
        const x: *Chosen = @ptrCast(@alignCast(ud.?));
        x.done = true;
        const e = str(info.error_name, info.error_name_len);
        @memcpy(x.err[0..e.len], e);
        x.err_len = e.len;
        if (e.len != 0) return;
        var v: i64 = 0;
        _ = c.siv_dbus_reader_read_int(r, &v);
        x.response = @intCast(v);
        if (c.siv_dbus_reader_read_enter(r) != .ok) return;
        while (next(r) == '{') {
            _ = c.siv_dbus_reader_read_enter(r);
            var kb: [64]u8 = undefined;
            const key = kb[0..readStr(r, &kb)];
            _ = c.siv_dbus_reader_read_enter(r); // the variant
            if (std.mem.eql(u8, key, "uris")) {
                _ = c.siv_dbus_reader_read_enter(r);
                while (next(r) == 's' and x.n_uris < x.uris.len) : (x.n_uris += 1) x.uri_lens[x.n_uris] = readStr(r, &x.uris[x.n_uris]);
                _ = c.siv_dbus_reader_read_exit(r);
            } else if (std.mem.eql(u8, key, "choices")) {
                _ = c.siv_dbus_reader_read_enter(r);
                while (next(r) == '(' and x.n_choices < x.choices.len) : (x.n_choices += 1) {
                    _ = c.siv_dbus_reader_read_enter(r);
                    x.choice_lens[x.n_choices][0] = readStr(r, &x.choices[x.n_choices][0]);
                    x.choice_lens[x.n_choices][1] = readStr(r, &x.choices[x.n_choices][1]);
                    _ = c.siv_dbus_reader_read_exit(r);
                }
                _ = c.siv_dbus_reader_read_exit(r);
            } else if (std.mem.eql(u8, key, "current_filter")) {
                _ = c.siv_dbus_reader_read_enter(r);
                x.filter_len = readStr(r, &x.filter);
                _ = c.siv_dbus_reader_read_exit(r);
            }
            _ = c.siv_dbus_reader_read_exit(r);
            _ = c.siv_dbus_reader_read_exit(r);
        }
    }
};

/// Writes a request's options.
const Options = *const fn (m: siv.DbusMessage, f: *const Fixture) void;

fn writeBytePath(m: siv.DbusMessage, p: []const u8) void {
    open(m, 'a', "y");
    for (p) |b| c.siv_dbus_message_write_int(m, 'y', b);
    c.siv_dbus_message_write_int(m, 'y', 0);
    close(m);
}

fn folderOption(m: siv.DbusMessage, f: *const Fixture, rel: []const u8) void {
    var buf: [512]u8 = undefined;
    entry(m, "current_folder", "ay");
    writeBytePath(m, f.sub(&buf, rel));
    endEntry(m);
}

fn boolOption(m: siv.DbusMessage, name: []const u8, v: bool) void {
    entry(m, name, "b");
    c.siv_dbus_message_write_int(m, 'b', @intFromBool(v));
    endEntry(m);
}

var request_serial: u32 = 0;
var handle_buf: [128]u8 = undefined;

/// Calls `member` on the portal backend and returns at once; `out` gets
/// the answer. The request's handle is in `handle_buf`.
fn callChooser(conn: siv.Dbus, member: []const u8, f: *const Fixture, title: []const u8, opts: Options, out: *Chosen) ![]const u8 {
    request_serial += 1;
    const handle = try std.fmt.bufPrint(&handle_buf, "/org/freedesktop/portal/desktop/request/1_42/t{d}", .{request_serial});
    const path = "/org/freedesktop/portal/desktop";
    const iface = "org.freedesktop.impl.portal.FileChooser";
    var m: siv.DbusMessage = .null;
    try siv.check(c.siv_dbus_new_call(conn, &.{ .destination = portal_name, .destination_len = portal_name.len, .path = path, .path_len = path.len, .interface = iface, .interface_len = iface.len, .member = member.ptr, .member_len = member.len }, &m));
    writeStr(m, 'o', handle);
    writeStr(m, 's', "org.example.Editor");
    writeStr(m, 's', "wayland:caller-handle");
    writeStr(m, 's', title);
    open(m, 'a', "{sv}");
    opts(m, f);
    close(m);
    try siv.check(c.siv_dbus_message_call(m, 0, Chosen.onReply, null, out));
    return handle;
}

/// Waits for the chooser window and makes it the one keys go to.
fn chooserWindow(h: *Harness) !*App.Window {
    try h.waitFor(h, struct {
        fn ok(x: *Harness) bool {
            for (x.app.?.windows.items) |w| if (w.chooser != null) return true;
            return false;
        }
    }.ok);
    for (h.app.?.windows.items) |w| if (w.chooser != null) {
        h.win = w;
        return w;
    };
    unreachable;
}

/// Waits for the answer; keys go to the main window again.
fn answered(h: *Harness, main: *App.Window, out: *Chosen) !void {
    try h.waitFor(out, struct {
        fn ok(x: *Chosen) bool {
            return x.done;
        }
    }.ok);
    h.win = main;
    try testing.expectEqualStrings("", out.err[0..out.err_len]);
    // The chooser's window went with the answer.
    for (h.app.?.windows.items) |w| try testing.expect(w.chooser == null);
}

fn fileUri(buf: []u8, f: *const Fixture, rel: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "file://{s}/{s}", .{ f.path, rel }) catch unreachable;
}

fn chooserFixture(f: *Fixture, name: []const u8) !void {
    try f.create(name, &.{
        .{ .name = "home", .dir = true },
        .{ .name = "work", .dir = true },
        .{ .name = "work/src", .dir = true },
        .{ .name = "work/photo.png", .size = 30 },
        .{ .name = "work/scan.jpg", .size = 30 },
        .{ .name = "work/notes.txt", .size = 3 },
        .{ .name = "work/report.txt", .size = 3 },
        .{ .name = "work/build.zig", .size = 3 },
    });
}

test "FileChooser: open one file and several, choose folders, by keys and by double clicks" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-open");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    var ub: [512]u8 = undefined;

    // One file: the folder asked for, the accept label without its
    // mnemonic mark, Enter on a file picks it.
    var one: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "Insert a picture", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
            entry(m, "accept_label", "s");
            writeStr(m, 's', "_Insert");
            endEntry(m);
        }
    }.w, &one);
    const win = try chooserWindow(&h);
    try testing.expect(std.mem.endsWith(u8, h.dir().path, "/work"));
    _ = try h.expect(.button, "Insert");
    _ = try h.expect(.button, "Cancel");
    try testing.expectEqualStrings("Insert a picture", win.chooser.?.windowTitle());
    try h.typeText("fph");
    try h.expectGolden(h.window(), "chooser-open");
    // Enter on a folder goes in; h comes back.
    try h.typeText("fsr\nh");
    try testing.expect(std.mem.endsWith(u8, h.dir().path, "/work"));
    try h.typeText("fph\n");
    try answered(&h, main, &one);
    try testing.expectEqual(@as(u32, 0), one.response);
    try testing.expectEqual(@as(usize, 1), one.n_uris);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/photo.png"), one.uri(0));

    // Several: marks pick them; the next chooser starts where this one
    // picked.
    var several: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", struct {
        fn w(m: siv.DbusMessage, _: *const Fixture) void {
            boolOption(m, "multiple", true);
        }
    }.w, &several);
    _ = try chooserWindow(&h);
    try testing.expect(std.mem.endsWith(u8, h.dir().path, "/work"));
    try h.typeText("fno fsc \n");
    try answered(&h, main, &several);
    try testing.expectEqual(@as(u32, 0), several.response);
    try testing.expectEqual(@as(usize, 2), several.n_uris);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/notes.txt"), several.uri(0));
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/scan.jpg"), several.uri(1));

    // Folders: Enter picks the folder under the cursor, l goes in, and on
    // a file it is the folder shown.
    var folder: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
            boolOption(m, "directory", true);
        }
    }.w, &folder);
    _ = try chooserWindow(&h);
    _ = try h.expect(.button, "Choose");
    try h.typeText("fsr\n");
    try answered(&h, main, &folder);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/src"), folder.uri(0));

    // The mouse: a double click on a file picks it.
    var clicked: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
        }
    }.w, &clicked);
    _ = try chooserWindow(&h);
    const row = try h.expect(.list_item, "build.zig 3 B");
    try h.click(h.window(), row, .primary);
    try h.click(h.window(), row, .primary);
    try answered(&h, main, &clicked);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/build.zig"), clicked.uri(0));
}

test "FileChooser: filters hide other files but not folders; choices come back" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-filters");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "work"), .bus = d.addr() });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    var ub: [512]u8 = undefined;
    var x: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
            // Images: a glob and a MIME type; Text: a glob.
            entry(m, "filters", "a(sa(us))");
            open(m, 'a', "(sa(us))");
            open(m, 'r', "");
            writeStr(m, 's', "Images");
            open(m, 'a', "(us)");
            open(m, 'r', "");
            c.siv_dbus_message_write_int(m, 'u', 0);
            writeStr(m, 's', "*.PNG");
            close(m);
            open(m, 'r', "");
            c.siv_dbus_message_write_int(m, 'u', 1);
            writeStr(m, 's', "image/jpeg");
            close(m);
            close(m);
            close(m);
            open(m, 'r', "");
            writeStr(m, 's', "Text");
            open(m, 'a', "(us)");
            open(m, 'r', "");
            c.siv_dbus_message_write_int(m, 'u', 0);
            writeStr(m, 's', "*.txt");
            close(m);
            close(m);
            close(m);
            close(m);
            endEntry(m);
            // A combo box and a check box.
            entry(m, "choices", "a(ssa(ss)s)");
            open(m, 'a', "(ssa(ss)s)");
            open(m, 'r', "");
            writeStr(m, 's', "size");
            writeStr(m, 's', "Size");
            open(m, 'a', "(ss)");
            for ([_][2][]const u8{ .{ "small", "Small" }, .{ "large", "Large" } }) |o| {
                open(m, 'r', "");
                writeStr(m, 's', o[0]);
                writeStr(m, 's', o[1]);
                close(m);
            }
            close(m);
            writeStr(m, 's', "large");
            close(m);
            open(m, 'r', "");
            writeStr(m, 's', "link");
            writeStr(m, 's', "_Link instead of copying");
            open(m, 'a', "(ss)");
            close(m);
            writeStr(m, 's', "false");
            close(m);
            close(m);
            endEntry(m);
        }
    }.w, &x);
    const win = try chooserWindow(&h);
    // Images: the folder and the two pictures (*.PNG ignores case).
    try testing.expectEqual(@as(u32, 3), h.dir().count());
    try testing.expect(h.reads("photo.png 30 B") and h.reads("scan.jpg 30 B") and h.reads("src"));
    try testing.expect(!h.reads("notes.txt 3 B"));
    _ = try h.expect(.combo_box, "Filter");
    _ = try h.expect(.combo_box, "Size");
    try h.expectGolden(h.window(), "chooser-filters");
    // Another filter: the text files.
    win.chooser.?.setFilter(1);
    try h.settle();
    try testing.expectEqual(@as(u32, 3), h.dir().count());
    try testing.expect(h.reads("notes.txt 3 B") and h.reads("report.txt 3 B"));
    // The main window shows the same folder unfiltered once the chooser is
    // done; the check box by a click.
    try h.click(h.window(), try h.expect(.checkbox, "Link instead of copying"), .primary);
    try h.typeText("fno\n");
    try answered(&h, main, &x);
    try testing.expectEqual(@as(u32, 0), x.response);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/notes.txt"), x.uri(0));
    try testing.expectEqualStrings("large", x.choice("size"));
    try testing.expectEqualStrings("true", x.choice("link"));
    try testing.expectEqualStrings("Text", x.filter[0..x.filter_len]);
    try testing.expectEqual(@as(u32, 6), h.dir().count());
}

test "FileChooser: save with a name, asking before replacing; save several into a folder" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-save");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    var ub: [512]u8 = undefined;

    // A new name: the name field has the keys, its stem selected.
    var fresh: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "Save the report", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
            entry(m, "current_name", "s");
            writeStr(m, 's', "report.txt");
            endEntry(m);
        }
    }.w, &fresh);
    const win = try chooserWindow(&h);
    try testing.expect(win.chooser.?.nameFocused());
    _ = try h.expect(.button, "Save");
    try h.expectGolden(h.window(), "chooser-save");
    try h.typeText("summary\n");
    try answered(&h, main, &fresh);
    try testing.expectEqual(@as(u32, 0), fresh.response);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/summary.txt"), fresh.uri(0));

    // A name that exists asks first; Cancel keeps the chooser, Replace
    // answers. The title is Chromium's when it has none.
    var over: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "All Files", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            var buf: [512]u8 = undefined;
            entry(m, "current_file", "ay");
            writeBytePath(m, fx.sub(&buf, "work/report.txt"));
            endEntry(m);
        }
    }.w, &over);
    const win2 = try chooserWindow(&h);
    try testing.expectEqualStrings("Save a File", win2.chooser.?.windowTitle());
    try testing.expectEqualStrings("report.txt", h.hovered());
    try h.typeText("\n");
    try testing.expect(win2.dialogs.isOpen());
    _ = try h.expect(.button, "Replace");
    try h.key(.escape, .{}, "");
    try testing.expect(!win2.dialogs.isOpen() and !over.done);
    // Tab goes to the columns (normal mode); Enter on the file there
    // saves over it, asking again.
    try h.key(.tab, .{}, "");
    try testing.expect(!over.done and !win2.chooser.?.nameFocused());
    try h.typeText("\n");
    try testing.expect(win2.dialogs.isOpen());
    try h.click(h.window(), try h.expect(.button, "Replace"), .primary);
    try answered(&h, main, &over);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/report.txt"), over.uri(0));

    // Several files: a folder, the names in it.
    var many: Chosen = .{};
    _ = try callChooser(client, "SaveFiles", &f, "", struct {
        fn w(m: siv.DbusMessage, fx: *const Fixture) void {
            folderOption(m, fx, "work");
            entry(m, "files", "aay");
            open(m, 'a', "ay");
            writeBytePath(m, "a.txt");
            writeBytePath(m, "b.txt");
            close(m);
            endEntry(m);
        }
    }.w, &many);
    _ = try chooserWindow(&h);
    try h.typeText("fsr\n");
    try answered(&h, main, &many);
    try testing.expectEqual(@as(usize, 2), many.n_uris);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/src/a.txt"), many.uri(0));
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/src/b.txt"), many.uri(1));
}

test "FileChooser: Escape and q cancel; the caller's Close ends it" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-cancel");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    const none = struct {
        fn w(_: siv.DbusMessage, _: *const Fixture) void {}
    }.w;
    // Escape clears the marks first, then cancels.
    var esc: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", none, &esc);
    _ = try chooserWindow(&h);
    try h.typeText(" ");
    try testing.expectEqual(@as(u32, 1), h.dir().mark_count);
    try h.key(.escape, .{}, "");
    try testing.expect(!esc.done);
    try h.key(.escape, .{}, "");
    try answered(&h, main, &esc);
    try testing.expectEqual(@as(u32, 1), esc.response);
    try testing.expectEqual(@as(usize, 0), esc.n_uris);
    // q cancels too; the Cancel button too.
    var q: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "", none, &q);
    _ = try chooserWindow(&h);
    try h.click(h.window(), try h.expect(.button, "Cancel"), .primary);
    try answered(&h, main, &q);
    try testing.expectEqual(@as(u32, 1), q.response);
    // Close on the request object: response 2, the window goes.
    var closed: Chosen = .{};
    const handle = try callChooser(client, "OpenFile", &f, "", none, &closed);
    _ = try chooserWindow(&h);
    var m: siv.DbusMessage = .null;
    const iface = "org.freedesktop.impl.portal.Request";
    try siv.check(c.siv_dbus_new_call(client, &.{ .destination = portal_name, .destination_len = portal_name.len, .path = handle.ptr, .path_len = handle.len, .interface = iface, .interface_len = iface.len, .member = "Close", .member_len = 5 }, &m));
    var close_reply: Called = .{};
    try siv.check(c.siv_dbus_message_call(m, 0, Called.onReply, null, &close_reply));
    try answered(&h, main, &closed);
    try testing.expectEqual(@as(u32, 2), closed.response);
    try h.waitFor(&close_reply, struct {
        fn ok(x: *Called) bool {
            return x.done;
        }
    }.ok);
    try testing.expectEqualStrings("", close_reply.err[0..close_reply.err_len]);
    try testing.expectEqual(@as(usize, 1), h.app.?.windows.items.len);
}

/// Firefox's Save Page As: its four filters and a suggested name.
fn firefoxSave(m: siv.DbusMessage, fx: *const Fixture) void {
    folderOption(m, fx, "work");
    entry(m, "current_name", "s");
    writeStr(m, 's', "New Tab.html");
    endEntry(m);
    entry(m, "filters", "a(sa(us))");
    open(m, 'a', "(sa(us))");
    for ([_][2][]const u8{ .{ "Web Page, complete", "*.html" }, .{ "Web Page, HTML only", "*.htm" }, .{ "Text Files", "*.txt" }, .{ "All Files", "*" } }) |f| {
        open(m, 'r', "");
        writeStr(m, 's', f[0]);
        open(m, 'a', "(us)");
        open(m, 'r', "");
        c.siv_dbus_message_write_int(m, 'u', 0);
        writeStr(m, 's', f[1]);
        close(m);
        close(m);
        close(m);
    }
    close(m);
    endEntry(m);
}

/// Both buttons lie inside the window.
fn buttonsShow(h: *Harness, width: f32) !void {
    for ([_][]const u8{ "Cancel", "Save" }) |name| {
        const b = (try h.expect(.button, name)).bounds;
        try testing.expect(b.width > 20 and b.x >= 0 and b.x + b.width <= width);
    }
}

test "FileChooser: Save has vim's modes: insert in the name, normal in the columns" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-modes");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr() });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));
    var ub: [512]u8 = undefined;

    var saved: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "", firefoxSave, &saved);
    const win = try chooserWindow(&h);
    const ch = win.chooser.?;
    // Insert mode first, the stem selected; Escape goes to normal mode,
    // where keys move in the columns.
    try testing.expect(ch.nameFocused() and h.reads("INSERT"));
    try h.key(.escape, .{}, "");
    try testing.expect(!ch.nameFocused() and h.reads("NORMAL") and !saved.done);
    try h.expectGolden(h.window(), "chooser-normal");
    try h.typeText("gg");
    try testing.expectEqualStrings("src", h.hovered());
    // i: back to the name as it was, the stem still selected.
    try h.typeText("i");
    try testing.expect(ch.nameFocused() and h.reads("INSERT"));
    try h.typeText("page");
    try testing.expectEqualStrings("page.html", ch.nameText());
    // I and a, over the keymap's rename and create: the start, and after
    // the stem.
    try h.key(.escape, .{}, "");
    try h.typeText("Imy-");
    try h.key(.escape, .{}, "");
    try h.typeText("a-2");
    try testing.expectEqualStrings("my-page-2.html", ch.nameText());
    // A: the end.
    try h.key(.escape, .{}, "");
    try h.typeText("Ax");
    try testing.expectEqualStrings("my-page-2.htmlx", ch.nameText());
    // cc and S (not the terminal) clear the name.
    try h.key(.escape, .{}, "");
    try h.typeText("cc");
    try testing.expect(ch.nameFocused());
    try testing.expectEqualStrings("", ch.nameText());
    try h.typeText("x");
    try h.key(.escape, .{}, "");
    try h.typeText("S");
    try testing.expectEqualStrings("", ch.nameText());
    // Clicks choose the mode too: the columns are normal, the field insert.
    try h.click(h.window(), try h.expect(.list_item, "src"), .primary);
    try testing.expect(!ch.nameFocused() and h.reads("NORMAL"));
    try h.click(h.window(), try h.expect(.text_input, "Name"), .primary);
    try testing.expect(ch.nameFocused() and h.reads("INSERT"));
    // A path in the name saves in that folder, as Emacs takes one.
    try h.typeText("src/../src/new.txt\n");
    try answered(&h, main, &saved);
    try testing.expectEqual(@as(u32, 0), saved.response);
    try testing.expectEqualStrings(fileUri(&ub, &f, "work/src/new.txt"), saved.uri(0));

    // Escape twice from the name cancels; so does q in normal mode.
    var twice: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "", firefoxSave, &twice);
    _ = try chooserWindow(&h);
    try h.key(.escape, .{}, "");
    try h.key(.escape, .{}, "");
    try answered(&h, main, &twice);
    try testing.expectEqual(@as(u32, 1), twice.response);
    var quit: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "", firefoxSave, &quit);
    _ = try chooserWindow(&h);
    try h.key(.escape, .{}, "");
    try h.typeText("q");
    try answered(&h, main, &quit);
    try testing.expectEqual(@as(u32, 1), quit.response);
}

test "FileChooser: a narrow window keeps its buttons; Escape twice from the name and closing the window cancel; the size is kept" {
    var f: Fixture = .{};
    try chooserFixture(&f, "chooser-narrow");
    defer f.remove();
    var d: Daemon = .{};
    try d.start(f.path);
    defer d.stop();
    var h: Harness = .{};
    defer h.deinit();
    var hbuf: [256]u8 = undefined;
    try h.start(.{ .path = f.sub(&hbuf, "home"), .bus = d.addr(), .state = true });
    const main = h.win.?;
    var client: siv.Dbus = .null;
    try siv.check(c.siv_dbus_connect(h.sapp, &.{ .bus = .address, .address = d.address[0..].ptr, .address_len = d.address_len }, &client));

    // Narrower than its least size (a tiling layout can do that), and
    // half of a 1920x1080 screen: the buttons stay on screen.
    var narrow: Chosen = .{};
    _ = try callChooser(client, "SaveFile", &f, "Save As", firefoxSave, &narrow);
    const win = try chooserWindow(&h);
    try siv.check(c.siv_test_resize(h.window(), 600, 400));
    try h.settle();
    try buttonsShow(&h, 600);
    // The parent column stays before the preview does.
    try testing.expect(h.reads("home"));
    try h.expectGolden(h.window(), "chooser-narrow");
    // Even at 360x240, as small as Hyprland once made it.
    try siv.check(c.siv_test_resize(h.window(), 360, 240));
    try h.settle();
    try buttonsShow(&h, 360);
    try siv.check(c.siv_test_resize(h.window(), 960, 1040));
    try h.settle();
    try buttonsShow(&h, 960);
    try h.expectGolden(h.window(), "chooser-half");
    // Escape in the name field goes to normal mode; Escape there cancels.
    try testing.expect(win.chooser.?.nameFocused());
    try h.key(.escape, .{}, "");
    try testing.expect(!narrow.done and !win.chooser.?.nameFocused());
    try h.key(.escape, .{}, "");
    try answered(&h, main, &narrow);
    try testing.expectEqual(@as(u32, 1), narrow.response);

    // The compositor's close (Super+W, killactive) cancels too.
    var closed: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", firefoxSave, &closed);
    _ = try chooserWindow(&h);
    try siv.check(c.siv_test_close(h.window()));
    try answered(&h, main, &closed);
    try testing.expectEqual(@as(u32, 1), closed.response);
    try testing.expectEqual(@as(usize, 1), h.app.?.windows.items.len);

    // A size the user gives a chooser is the next one's.
    var sized: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", firefoxSave, &sized);
    _ = try chooserWindow(&h);
    var size: siv.Size = .{};
    try siv.check(c.siv_window_get_size(h.window(), &size));
    try testing.expectEqual(@as(u32, 960), size.width);
    try testing.expectEqual(@as(u32, 640), size.height);
    for (0..30) |_| try siv.check(c.siv_app_dispatch(h.sapp, 25));
    try siv.check(c.siv_test_resize(h.window(), 820, 560));
    try h.settle();
    try h.key(.escape, .{}, "");
    try answered(&h, main, &sized);
    var again: Chosen = .{};
    _ = try callChooser(client, "OpenFile", &f, "", firefoxSave, &again);
    _ = try chooserWindow(&h);
    try siv.check(c.siv_window_get_size(h.window(), &size));
    try testing.expectEqual(@as(u32, 820), size.width);
    try testing.expectEqual(@as(u32, 560), size.height);
    try h.key(.escape, .{}, "");
    try answered(&h, main, &again);
}
