//! Mounted file systems from /proc/self/mountinfo: the ones a person
//! would call a drive (removable media under /media, /run/media, /mnt,
//! and other block devices outside the system's own mounts), and every
//! real file system's mount point, for finding per-device trash folders.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Mount = struct {
    mount_point: []const u8,
    device: []const u8,
    fstype: []const u8,
};

pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    mounts: []Mount = &.{},

    pub fn deinit(t: *Table) void {
        t.arena.deinit();
    }

    /// Mount points of real (block device or network) file systems.
    pub fn realMountPoints(t: *const Table, gpa: Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (t.mounts) |m| if (isReal(m)) try out.append(gpa, m.mount_point);
        return out.toOwnedSlice(gpa);
    }
};

const pseudo = [_][]const u8{ "proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "cgroup", "cgroup2", "securityfs", "pstore", "bpf", "debugfs", "tracefs", "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs", "efivarfs", "binfmt_misc", "nsfs", "overlay", "squashfs", "rpc_pipefs", "ramfs", "selinuxfs", "fuse.portal", "fuse.gvfsd-fuse", "fuse.xdg-document-portal" };

pub fn isReal(m: Mount) bool {
    for (pseudo) |p| if (std.mem.eql(u8, m.fstype, p)) return false;
    for ([_][]const u8{ "/proc", "/sys", "/dev", "/run/user", "/run/credentials", "/snap", "/var/lib/docker" }) |p| {
        if (std.mem.startsWith(u8, m.mount_point, p) and (m.mount_point.len == p.len or m.mount_point[p.len] == '/')) return false;
    }
    return true;
}

/// Whether a mount is a drive to show in the sidebar: a real file system
/// mounted somewhere a user mounts things, or on a block device that is
/// not part of the system's own tree.
pub fn isUserDrive(m: Mount) bool {
    if (!isReal(m)) return false;
    if (std.mem.eql(u8, m.mount_point, "/")) return false;
    for ([_][]const u8{ "/media/", "/run/media/", "/mnt/" }) |p| if (std.mem.startsWith(u8, m.mount_point, p)) return true;
    if (std.mem.eql(u8, m.mount_point, "/mnt")) return true;
    return false;
}

pub fn read(gpa: Allocator) !Table {
    var t: Table = .{ .arena = .init(gpa) };
    errdefer t.deinit();
    const a = t.arena.allocator();
    const data = readAll(a, "/proc/self/mountinfo") orelse return t;
    var list: std.ArrayList(Mount) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (parseLine(a, line)) |m| try list.append(a, m) else |_| {}
    }
    t.mounts = try list.toOwnedSlice(a);
    return t;
}

/// "36 35 98:0 /mnt1 /mnt/parent rw,noatime master:1 - ext3 /dev/root rw"
fn parseLine(a: Allocator, line: []const u8) !Mount {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    _ = fields.next() orelse return error.Bad; // id
    _ = fields.next() orelse return error.Bad; // parent
    _ = fields.next() orelse return error.Bad; // major:minor
    _ = fields.next() orelse return error.Bad; // root
    const mp = fields.next() orelse return error.Bad;
    while (fields.next()) |f| if (std.mem.eql(u8, f, "-")) break;
    const fstype = fields.next() orelse return error.Bad;
    const dev = fields.next() orelse "";
    return .{ .mount_point = try unescapeOctal(a, mp), .device = try unescapeOctal(a, dev), .fstype = try a.dupe(u8, fstype) };
}

/// mountinfo escapes spaces and the like as \040.
fn unescapeOctal(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 3 < s.len + 1 and i + 3 <= s.len) {
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 4], 8) catch {
                try out.append(a, s[i]);
                continue;
            };
            try out.append(a, v);
            i += 3;
        } else try out.append(a, s[i]);
    }
    return out.toOwnedSlice(a);
}

fn readAll(a: Allocator, path: [:0]const u8) ?[]u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(a, chunk[0..n]) catch return null;
    }
    return list.items;
}

test "mountinfo lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try parseLine(arena.allocator(), "36 35 98:0 / /run/media/me/My\\040Disk rw,nosuid shared:1 - vfat /dev/sdb1 rw");
    try std.testing.expectEqualStrings("/run/media/me/My Disk", m.mount_point);
    try std.testing.expectEqualStrings("vfat", m.fstype);
    try std.testing.expect(isUserDrive(m));
    const p = try parseLine(arena.allocator(), "22 1 0:21 / /proc rw - proc proc rw");
    try std.testing.expect(!isReal(p));
}
