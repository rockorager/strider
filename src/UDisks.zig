//! Drives from UDisks2 on the system bus: block devices with file systems,
//! mounted or not, with mount, unmount, and eject (or power off), and
//! encrypted (LUKS) volumes, unlocked with a passphrase before mounting
//! and locked again when unmounted or ejected.
//!
//! The drive list comes from the object manager's GetManagedObjects and is
//! fetched again whenever UDisks2 reports a change (InterfacesAdded,
//! InterfacesRemoved, PropertiesChanged under its tree), one fetch at a
//! time. Mounting and unmounting are interactive, so polkit may ask the
//! user; a dismissed prompt says nothing.

const std = @import("std");
const siv = @import("siv");
const c = siv.c;
const bus = @import("bus.zig");
const model = @import("model.zig");
const places_mod = @import("places.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");

const UDisks = @This();

const service = "org.freedesktop.UDisks2";
const root_path = "/org/freedesktop/UDisks2";
const block_iface = "org.freedesktop.UDisks2.Block";
const fs_iface = "org.freedesktop.UDisks2.Filesystem";
const drive_iface = "org.freedesktop.UDisks2.Drive";
const encrypted_iface = "org.freedesktop.UDisks2.Encrypted";

app: *App,
conn: siv.Dbus,
/// UDisks2 runs (its name has an owner).
present: bool = false,
fetching: bool = false,
/// A change arrived during a fetch: fetch again when it answers.
stale: bool = false,
/// What the drives in the sidebar refer to, by block path.
arena: std.heap.ArenaAllocator,
volumes: []Volume = &.{},

/// A file system UDisks2 can mount, or an encrypted volume to unlock.
const Volume = struct {
    block: []const u8,
    drive: []const u8,
    ejectable: bool,
    can_power_off: bool,
    /// A locked encrypted volume: unlock `block` first.
    locked: bool = false,
    /// The encrypted volume an unlocked file system is on, to lock after
    /// unmounting; empty for plain ones.
    backing: []const u8 = "",
};

/// What GetManagedObjects says about one object.
const Object = struct {
    path: []const u8 = "",
    block: bool = false,
    filesystem: bool = false,
    drive: bool = false,
    encrypted: bool = false,
    // Block
    drive_path: []const u8 = "/",
    label: []const u8 = "",
    hint_name: []const u8 = "",
    hint_icon: []const u8 = "",
    hint_ignore: bool = false,
    hint_system: bool = true,
    size: u64 = 0,
    /// For an unlocked volume's cleartext device: the encrypted one.
    crypto_backing: []const u8 = "/",
    // Encrypted: the cleartext device, "/" while locked.
    cleartext: []const u8 = "/",
    // Filesystem
    mount_point: []const u8 = "",
    // Drive
    ejectable: bool = false,
    removable: bool = false,
    can_power_off: bool = false,
};

pub fn create(app: *App) !*UDisks {
    const conn = try bus.connect(app.app, .system, app.opts.system_bus);
    errdefer c.siv_dbus_disconnect(conn);
    const self = try app.gpa.create(UDisks);
    errdefer app.gpa.destroy(self);
    self.* = .{ .app = app, .conn = conn, .arena = .init(app.gpa) };
    errdefer self.arena.deinit();
    var watch: siv.DbusNameWatch = .null;
    try siv.check(c.siv_dbus_watch_name(conn, service, service.len, onOwner, null, self, &watch));
    // Signals from UDisks2's tree; the sender follows the name's owner.
    const signals = [_]struct { []const u8, ?[]const u8 }{
        .{ "org.freedesktop.DBus.ObjectManager", null },
        .{ "org.freedesktop.DBus.Properties", "PropertiesChanged" },
    };
    for (signals) |s| {
        const iface, const member = s;
        var sub: siv.DbusSubscription = .null;
        try siv.check(c.siv_dbus_subscribe(conn, &.{
            .sender = service,
            .sender_len = service.len,
            .path_namespace = root_path,
            .path_namespace_len = root_path.len,
            .interface = iface.ptr,
            .interface_len = iface.len,
            .member = if (member) |m| m.ptr else null,
            .member_len = if (member) |m| m.len else 0,
        }, onChanged, null, self, &sub));
    }
    return self;
}

pub fn destroy(self: *UDisks) void {
    // Everything made on the connection goes with it.
    c.siv_dbus_disconnect(self.conn);
    self.arena.deinit();
    self.app.gpa.destroy(self);
}

fn onOwner(ud: ?*anyopaque, _: siv.DbusNameWatch, owner: ?[*]const u8, len: usize) callconv(.c) void {
    const self: *UDisks = @ptrCast(@alignCast(ud.?));
    self.present = len != 0 and owner != null;
    if (self.present) return self.fetch();
    // UDisks2 went away (or never ran): back to the mount table.
    self.volumes = &.{};
    self.app.refreshMountDrives();
}

fn onChanged(ud: ?*anyopaque, _: *const siv.DbusMessageInfo, _: siv.DbusReader) callconv(.c) void {
    const self: *UDisks = @ptrCast(@alignCast(ud.?));
    self.fetch();
}

fn fetch(self: *UDisks) void {
    if (self.fetching) {
        self.stale = true;
        return;
    }
    const m = bus.newCall(self.conn, service, root_path, "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", false) catch return;
    if (c.siv_dbus_message_call(m, 0, onObjects, null, self) != .ok) return;
    self.fetching = true;
}

fn onObjects(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, r: siv.DbusReader) callconv(.c) void {
    const self: *UDisks = @ptrCast(@alignCast(ud.?));
    self.fetching = false;
    if (self.stale) {
        self.stale = false;
        return self.fetch();
    }
    if (info.type != .method_return) return;
    var arena: std.heap.ArenaAllocator = .init(self.app.gpa);
    defer arena.deinit();
    const objects = parseObjects(r, arena.allocator()) catch return;
    self.apply(objects);
}

const Kind = enum { block, fs, drive, encrypted, other };

/// a{oa{sa{sv}}}: objects, their interfaces, and their properties.
fn parseObjects(r: siv.DbusReader, a: std.mem.Allocator) ![]Object {
    var list: std.ArrayList(Object) = .empty;
    if (bus.next(r) != 'a' or !bus.enter(r)) return error.Invalid;
    while (bus.next(r) == '{') {
        _ = bus.enter(r);
        var o: Object = .{ .path = bus.readString(r, a) orelse return error.Invalid };
        if (bus.next(r) == 'a' and bus.enter(r)) {
            while (bus.next(r) == '{') {
                _ = bus.enter(r);
                const iface = bus.readString(r, a) orelse return error.Invalid;
                const kind: Kind = if (std.mem.eql(u8, iface, block_iface)) .block else if (std.mem.eql(u8, iface, fs_iface)) .fs else if (std.mem.eql(u8, iface, drive_iface)) .drive else if (std.mem.eql(u8, iface, encrypted_iface)) .encrypted else .other;
                switch (kind) {
                    .block => o.block = true,
                    .fs => o.filesystem = true,
                    .drive => o.drive = true,
                    .encrypted => o.encrypted = true,
                    .other => {},
                }
                if (kind != .other and bus.next(r) == 'a' and bus.enter(r)) {
                    while (bus.next(r) == '{') {
                        _ = bus.enter(r);
                        const name = bus.readString(r, a) orelse return error.Invalid;
                        if (bus.enter(r)) {
                            property(&o, kind, name, r, a);
                            bus.exit(r);
                        }
                        bus.exit(r);
                    }
                    bus.exit(r);
                }
                bus.exit(r);
            }
            bus.exit(r);
        }
        bus.exit(r);
        try list.append(a, o);
    }
    bus.exit(r);
    return list.items;
}

/// Reads the property `name` (the reader is inside its variant).
fn property(o: *Object, kind: Kind, name: []const u8, r: siv.DbusReader, a: std.mem.Allocator) void {
    const eql = std.mem.eql;
    switch (kind) {
        .block => {
            if (eql(u8, name, "Drive")) o.drive_path = bus.readString(r, a) orelse "/";
            if (eql(u8, name, "IdLabel")) o.label = bus.readString(r, a) orelse "";
            if (eql(u8, name, "HintName")) o.hint_name = bus.readString(r, a) orelse "";
            if (eql(u8, name, "HintIconName")) o.hint_icon = bus.readString(r, a) orelse "";
            if (eql(u8, name, "HintIgnore")) o.hint_ignore = (bus.readInt(r) orelse 0) != 0;
            if (eql(u8, name, "HintSystem")) o.hint_system = (bus.readInt(r) orelse 1) != 0;
            if (eql(u8, name, "Size")) o.size = @bitCast(bus.readInt(r) orelse 0);
            if (eql(u8, name, "CryptoBackingDevice")) o.crypto_backing = bus.readString(r, a) orelse "/";
        },
        // aay: the first mount point is the one to show.
        .fs => if (eql(u8, name, "MountPoints") and bus.next(r) == 'a' and bus.enter(r)) {
            if (bus.next(r) == 'a') o.mount_point = bus.readBytePath(r, a) orelse "";
            bus.exit(r);
        },
        .drive => {
            if (eql(u8, name, "Ejectable")) o.ejectable = (bus.readInt(r) orelse 0) != 0;
            if (eql(u8, name, "Removable")) o.removable = (bus.readInt(r) orelse 0) != 0;
            if (eql(u8, name, "CanPowerOff")) o.can_power_off = (bus.readInt(r) orelse 0) != 0;
        },
        .encrypted => if (eql(u8, name, "CleartextDevice")) {
            o.cleartext = bus.readString(r, a) orelse "/";
        },
        .other => {},
    }
}

fn find(objects: []const Object, path: []const u8) ?*const Object {
    for (objects) |*o| if (std.mem.eql(u8, o.path, path)) return o;
    return null;
}

fn userMountPoint(mp: []const u8) bool {
    for ([_][]const u8{ "/media/", "/run/media/", "/mnt/" }) |p| if (std.mem.startsWith(u8, mp, p)) return true;
    return std.mem.eql(u8, mp, "/mnt");
}

/// The file systems worth a place in the sidebar: those UDisks2 does not
/// hide, on removable drives or not part of the system, or mounted where
/// users mount things.
fn apply(self: *UDisks, objects: []const Object) void {
    _ = self.arena.reset(.retain_capacity);
    const a = self.arena.allocator();
    var volumes: std.ArrayList(Volume) = .empty;
    var drives: std.ArrayList(places_mod.Drive) = .empty;
    for (objects) |o| {
        if (!o.block or o.hint_ignore) continue;
        // A locked encrypted volume shows until unlocked; then its
        // cleartext device's file system stands for it.
        const locked = o.encrypted and std.mem.eql(u8, o.cleartext, "/");
        if (!o.filesystem and !locked) continue;
        const backing: ?*const Object = if (std.mem.eql(u8, o.crypto_backing, "/")) null else find(objects, o.crypto_backing);
        // The cleartext device has no drive or useful hints of its own.
        const outer = backing orelse &o;
        if (outer.hint_ignore) continue;
        const d = find(objects, outer.drive_path);
        const removable = if (d) |dd| dd.removable or dd.ejectable else false;
        const mounted = o.mount_point.len != 0;
        if (outer.hint_system and !removable and !(mounted and userMountPoint(o.mount_point))) continue;
        var size_buf: [32]u8 = undefined;
        const label = if (o.label.len != 0) o.label else if (outer.label.len != 0) outer.label else if (outer.hint_name.len != 0) outer.hint_name else std.fmt.allocPrint(a, "{s} {s}", .{ model.formatSize(&size_buf, outer.size), if (locked or backing != null) "Encrypted Volume" else "Volume" }) catch continue;
        const ejectable = if (d) |dd| dd.ejectable else false;
        const power_off = if (d) |dd| dd.can_power_off and removable else false;
        volumes.append(a, .{
            .block = a.dupe(u8, o.path) catch continue,
            .drive = a.dupe(u8, outer.drive_path) catch continue,
            .ejectable = ejectable,
            .can_power_off = power_off,
            .locked = locked,
            .backing = if (backing) |b| a.dupe(u8, b.path) catch continue else "",
        }) catch continue;
        drives.append(a, .{
            .id = volumes.items[volumes.items.len - 1].block,
            .label = a.dupe(u8, label) catch continue,
            .mount_point = a.dupe(u8, o.mount_point) catch continue,
            .icon = icon: {
                const fallback = if (removable) places_mod.removable_icon else places_mod.harddisk_icon;
                if (outer.hint_icon.len == 0) break :icon fallback[1..];
                break :icon std.fmt.allocPrint(a, "{s}{s}", .{ outer.hint_icon, fallback }) catch continue;
            },
            .can_mount = !mounted,
            .can_unmount = mounted,
            .can_eject = ejectable or power_off,
            .size = outer.size,
        }) catch continue;
    }
    std.mem.sort(places_mod.Drive, drives.items, {}, struct {
        fn lt(_: void, x: places_mod.Drive, y: places_mod.Drive) bool {
            return std.mem.lessThan(u8, x.label, y.label);
        }
    }.lt);
    self.volumes = volumes.items;
    self.app.setDrives(drives.items);
}

fn volumeOf(self: *UDisks, drive: u32) ?Volume {
    const drives = self.app.places.drives.items;
    if (drive >= drives.len) return null;
    for (self.volumes) |v| if (std.mem.eql(u8, v.block, drives[drive].id)) return v;
    return null;
}

// Requests --------------------------------------------------------------------------

/// A step in flight (unlock, mount, unmount, lock, eject), answered to the
/// window that asked if it is still open. Steps that follow another (lock
/// after unmount, eject after lock) go in a copy.
const Request = struct {
    udisks: *UDisks,
    win: *Window,
    kind: enum { unlock, mount, unmount, lock, eject },
    new_tab: bool = false,
    label: Text(128) = .{},
    /// Mount: the device; unmount: where it was mounted.
    target: Text(256) = .{},
    mount_point: Text(512) = .{},
    /// The encrypted volume to lock after unmounting.
    backing: Text(256) = .{},
    /// The drive to eject after, if any.
    drive: Text(256) = .{},
    power_off: bool = false,
    eject_after: bool = false,
    /// Mounts right after an unlock retry while UDisks2 probes the new
    /// device's file system.
    retries: u8 = 0,

    fn window(req: *const Request) ?*Window {
        for (req.udisks.app.windows.items) |w| if (w == req.win) return w;
        return null;
    }

    fn free(ud: ?*anyopaque) callconv(.c) void {
        const req: *Request = @ptrCast(@alignCast(ud.?));
        req.udisks.app.gpa.destroy(req);
    }

    /// A copy for the next step.
    fn next(req: *const Request, kind: @FieldType(Request, "kind")) ?*Request {
        const n = req.udisks.app.gpa.create(Request) catch return null;
        n.* = req.*;
        n.kind = kind;
        return n;
    }
};

fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        fn set(t: *@This(), s: []const u8) void {
            t.len = @min(s.len, n);
            @memcpy(t.buf[0..t.len], s[0..t.len]);
        }

        fn get(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

fn newRequest(self: *UDisks, win: *Window, drive: u32, v: Volume) ?*Request {
    const req = self.app.gpa.create(Request) catch return null;
    req.* = .{ .udisks = self, .win = win, .kind = .mount };
    const d = self.app.places.drives.items[drive];
    req.label.set(d.label);
    req.mount_point.set(d.mount_point);
    req.target.set(v.block);
    req.backing.set(v.backing);
    req.drive.set(v.drive);
    req.power_off = !v.ejectable;
    return req;
}

/// Calls `member` on `path` with the request's arguments and empty
/// options. Consumes `req`.
fn send(self: *UDisks, req: *Request, path: []const u8, iface: []const u8, member: []const u8, passphrase: ?[]const u8) void {
    const m = bus.newCallFlags(self.conn, service, path, iface, member, .{ .interactive = true, .secret = passphrase != null }) catch {
        Request.free(req);
        return;
    };
    if (passphrase) |p| bus.writeString(m, p);
    bus.writeNoOptions(m);
    // Polkit may ask the user: no timeout.
    if (c.siv_dbus_message_call(m, -1, onReply, Request.free, req) != .ok) {
        if (req.window()) |w| w.notify("UDisks2 is not available", true);
    }
}

fn sendStep(self: *UDisks, req: *Request) void {
    switch (req.kind) {
        .mount => self.send(req, req.target.get(), fs_iface, "Mount", null),
        .unmount => self.send(req, req.target.get(), fs_iface, "Unmount", null),
        .lock => self.send(req, req.backing.get(), encrypted_iface, "Lock", null),
        .eject => self.send(req, req.drive.get(), drive_iface, if (req.power_off) "PowerOff" else "Eject", null),
        .unlock => unreachable,
    }
}

/// Mounts the drive and goes there; a locked volume asks for its
/// passphrase first.
pub fn mount(self: *UDisks, win: *Window, drive: u32, new_tab: bool) void {
    const v = self.volumeOf(drive) orelse return;
    if (v.locked) {
        const label = self.app.places.drives.items[drive].label;
        return win.askPassphrase(v.block, label, new_tab);
    }
    const req = self.newRequest(win, drive, v) orelse return;
    req.new_tab = new_tab;
    self.sendStep(req);
}

/// Unlocks the encrypted volume `block` with `passphrase` (copied into
/// the message), then mounts it. The window's unlock dialog hears how it
/// went.
pub fn unlock(self: *UDisks, win: *Window, block: []const u8, passphrase: []const u8, new_tab: bool) void {
    const req = self.app.gpa.create(Request) catch return;
    req.* = .{ .udisks = self, .win = win, .kind = .unlock, .new_tab = new_tab };
    req.target.set(block);
    for (self.app.places.drives.items) |d| if (std.mem.eql(u8, d.id, block)) req.label.set(d.label);
    self.send(req, block, encrypted_iface, "Unlock", passphrase);
}

/// Unmounts the drive's file system, locks the encrypted volume it is on,
/// and with `eject` ejects or powers off its drive after.
pub fn unmount(self: *UDisks, win: *Window, drive: u32, eject: bool) void {
    const v = self.volumeOf(drive) orelse return;
    const req = self.newRequest(win, drive, v) orelse return;
    req.eject_after = eject and (v.ejectable or v.can_power_off);
    const mp = req.mount_point.get();
    if (mp.len == 0) {
        // Not mounted: lock an unlocked volume, eject, or both.
        if (v.backing.len != 0) {
            req.kind = .lock;
        } else if (req.eject_after) {
            req.kind = .eject;
        } else return Request.free(req);
        return self.sendStep(req);
    }
    // Panes inside the mount would keep it busy: send them home.
    for (self.app.windows.items) |w| w.leaveMount(mp);
    req.kind = .unmount;
    self.sendStep(req);
}

fn onReply(ud: ?*anyopaque, info: *const siv.DbusMessageInfo, r: siv.DbusReader) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(ud.?));
    const self = req.udisks;
    const label = req.label.get();
    if (info.type != .method_return) {
        const name = bus.infoString(info.error_name, info.error_name_len);
        if (std.mem.endsWith(u8, name, ".NotAuthorizedDismissed")) {
            if (req.kind == .unlock) if (req.window()) |w| w.notify("Not unlocked", false);
            return;
        }
        // Mounting just after an unlock: the file system may not be
        // known yet.
        if (req.kind == .mount and req.retries < 10 and (std.mem.endsWith(u8, name, ".UnknownMethod") or std.mem.endsWith(u8, name, ".UnknownInterface") or std.mem.endsWith(u8, name, ".UnknownObject"))) {
            const again = req.next(.mount) orelse return;
            again.retries += 1;
            var timer: siv.Timer = .null;
            if (c.siv_timer_start(self.app.app, 200, onRetry, Request.free, again, &timer) != .ok) return;
            return;
        }
        var tbuf: [256]u8 = undefined;
        var mbuf: [512]u8 = undefined;
        var mlen: usize = 0;
        const detail = if (c.siv_dbus_reader_read_string(r, &tbuf, tbuf.len, &mlen) == .ok and mlen <= tbuf.len) tbuf[0..mlen] else name;
        if (req.kind == .unlock) {
            if (req.window()) |w| w.unlockFailed(unlockError(detail), req.target.get(), label, req.new_tab);
            return;
        }
        const verb = switch (req.kind) {
            .unlock => unreachable,
            .mount => "mount",
            .unmount => "unmount",
            .lock => "lock",
            .eject => "eject",
        };
        const msg = std.fmt.bufPrint(&mbuf, "Cannot {s} “{s}”: {s}", .{ verb, label, detail }) catch "The drive refused";
        if (req.window()) |w| w.notify(msg, true);
        return;
    }
    switch (req.kind) {
        .unlock => {
            var pbuf: [256]u8 = undefined;
            var plen: usize = 0;
            if (c.siv_dbus_reader_read_string(r, &pbuf, pbuf.len, &plen) != .ok or plen > pbuf.len) return;
            if (req.window()) |w| w.notify("Unlocked", false);
            const m = req.next(.mount) orelse return;
            m.target.set(pbuf[0..plen]);
            self.sendStep(m);
        },
        .mount => {
            var pbuf: [512]u8 = undefined;
            var plen: usize = 0;
            if (c.siv_dbus_reader_read_string(r, &pbuf, pbuf.len, &plen) != .ok or plen > pbuf.len) return;
            if (req.window()) |w| self.app.driveMounted(w, pbuf[0..plen], req.new_tab);
        },
        .unmount, .lock => {
            if (req.kind == .unmount and req.backing.len != 0) {
                if (req.next(.lock)) |n| self.sendStep(n);
                return;
            }
            if (req.eject_after) {
                if (req.next(.eject)) |n| self.sendStep(n);
                return;
            }
            toastRemovable(req);
        },
        .eject => toastRemovable(req),
    }
}

fn toastRemovable(req: *const Request) void {
    const w = req.window() orelse return;
    var mbuf: [256]u8 = undefined;
    w.notify(std.fmt.bufPrint(&mbuf, "“{s}” can be removed", .{req.label.get()}) catch "Done", false);
}

fn onRetry(ud: ?*anyopaque) callconv(.c) void {
    const req: *Request = @ptrCast(@alignCast(ud.?));
    // The timer's destroy-notify frees `req`: send a copy.
    const again = req.next(.mount) orelse return;
    req.udisks.sendStep(again);
}

/// UDisks2's (cryptsetup's) words for a wrong passphrase, said plainly.
fn unlockError(detail: []const u8) []const u8 {
    if (std.ascii.findIgnoreCase(detail, "passphrase") != null or std.ascii.findIgnoreCase(detail, "No key available") != null) return "Wrong passphrase. Try again.";
    return detail;
}
