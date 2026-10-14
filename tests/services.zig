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
