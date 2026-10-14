//! The sidebar's places: home, the XDG user directories that exist
//! ($XDG_CONFIG_HOME/user-dirs.dirs), the trash, and the root of the file
//! system; GTK bookmarks ($XDG_CONFIG_HOME/gtk-3.0/bookmarks, which other
//! file managers and file choosers share); and drives (from UDisks2, or
//! the mount table without it). Headers separate the sections.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const uri = @import("uri.zig");

pub const Kind = enum { header, place, bookmark, trash, root, drive };

pub const Place = struct {
    kind: Kind,
    label: []u8,
    /// Where it goes; empty for a drive that is not mounted.
    path: []u8,
    /// Icon names, one per line.
    icon: []const u8,
    /// Drives: the index in `drives`.
    drive: u32 = 0,
};

/// Drive icons, with the application's own symbolic ones last: each
/// starts with a newline so a themed name can go before it.
pub const removable_icon = "\ndrive-removable-media\ndrive-removable-media-symbolic";
pub const harddisk_icon = "\ndrive-harddisk\ndrive-harddisk-symbolic";

/// A drive, as UDisks2 or the mount table describes it.
pub const Drive = struct {
    /// UDisks2's block object path, or the device node.
    id: []const u8,
    label: []const u8,
    /// Empty when not mounted.
    mount_point: []const u8,
    icon: []const u8 = "drive-harddisk",
    can_mount: bool = false,
    can_unmount: bool = false,
    can_eject: bool = false,
    /// Size in bytes, 0 if unknown.
    size: u64 = 0,
};

pub const Places = struct {
    gpa: Allocator,
    items: std.ArrayList(Place) = .empty,
    /// $XDG_DATA_HOME/Trash, and its files folder.
    trash_dir: []u8 = &.{},
    trash_files: []u8 = &.{},
    bookmarks_file: []u8 = &.{},
    home: []u8 = &.{},
    /// Owned copies of the drives the items refer to.
    drives: std.ArrayList(Drive) = .empty,
    drive_arena: std.heap.ArenaAllocator,

    pub fn deinit(p: *Places) void {
        p.clearItems();
        p.items.deinit(p.gpa);
        p.drives.deinit(p.gpa);
        p.drive_arena.deinit();
        p.gpa.free(p.trash_dir);
        p.gpa.free(p.trash_files);
        p.gpa.free(p.bookmarks_file);
        p.gpa.free(p.home);
    }

    fn clearItems(p: *Places) void {
        for (p.items.items) |it| {
            p.gpa.free(it.label);
            p.gpa.free(it.path);
        }
        p.items.clearRetainingCapacity();
    }

    fn add(p: *Places, kind: Kind, label: []const u8, path: []const u8, icon: []const u8) !void {
        const l = try p.gpa.dupe(u8, label);
        errdefer p.gpa.free(l);
        const pa = try p.gpa.dupe(u8, path);
        errdefer p.gpa.free(pa);
        try p.items.append(p.gpa, .{ .kind = kind, .label = l, .path = pa, .icon = icon });
    }

    fn has(p: *const Places, path: []const u8) bool {
        for (p.items.items) |it| if (it.kind != .header and std.mem.eql(u8, it.path, path)) return true;
        return false;
    }

    /// The place whose path is `path`, if any.
    pub fn find(p: *const Places, path: []const u8) ?usize {
        for (p.items.items, 0..) |it, i| if (it.kind != .header and it.path.len != 0 and std.mem.eql(u8, it.path, path)) return i;
        return null;
    }

    /// The place with the longest path that holds `path` (a drive, home),
    /// for breadcrumbs.
    pub fn containing(p: *const Places, path: []const u8) ?usize {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (p.items.items, 0..) |it, i| {
            if (it.kind != .drive and it.kind != .root and !(it.kind == .place and std.mem.eql(u8, it.path, p.home))) continue;
            if (it.path.len == 0) continue;
            const within = std.mem.eql(u8, it.path, "/") or (std.mem.startsWith(u8, path, it.path) and (path.len == it.path.len or path[it.path.len] == '/'));
            if (within and it.path.len >= best_len) {
                best = i;
                best_len = it.path.len;
            }
        }
        return best;
    }

    pub fn isBookmarked(p: *const Places, path: []const u8) bool {
        for (p.items.items) |it| if (it.kind == .bookmark and std.mem.eql(u8, it.path, path)) return true;
        return false;
    }

    /// Rebuilds the list from the environment, the bookmarks file, and
    /// `drives`.
    pub fn rebuild(p: *Places, env: Env, drives: []const Drive) !void {
        p.clearItems();
        var buf: [linux.PATH_MAX]u8 = undefined;
        try p.add(.header, "Places", "", "");
        try p.add(.place, "Home", env.home, "user-home");

        const config = env.config_home orelse (std.fmt.bufPrint(&buf, "{s}/.config", .{env.home}) catch env.home);
        var cfg_buf: [linux.PATH_MAX]u8 = undefined;
        const cfg = try p.gpa.dupe(u8, config);
        defer p.gpa.free(cfg);
        const dirs_path = std.fmt.bufPrint(&cfg_buf, "{s}/user-dirs.dirs", .{cfg}) catch "";
        const wanted = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            .{ "XDG_DESKTOP_DIR", "Desktop", "user-desktop", "Desktop" },
            .{ "XDG_DOCUMENTS_DIR", "Documents", "folder-documents", "Documents" },
            .{ "XDG_DOWNLOAD_DIR", "Downloads", "folder-download", "Downloads" },
            .{ "XDG_MUSIC_DIR", "Music", "folder-music", "Music" },
            .{ "XDG_PICTURES_DIR", "Pictures", "folder-pictures", "Pictures" },
            .{ "XDG_VIDEOS_DIR", "Videos", "folder-videos", "Videos" },
        };
        var contents_buf: [8192]u8 = undefined;
        const contents = readSmall(dirs_path, &contents_buf);
        for (wanted) |wd| {
            const key, const label, const icon, const default = wd;
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const path = userDir(contents, key, env.home, &pbuf) orelse (std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ env.home, default }) catch continue);
            // XDG says a user directory equal to $HOME is disabled.
            if (std.mem.eql(u8, path, env.home)) continue;
            if (isDir(path) and !p.has(path)) try p.add(.place, label, path, icon);
        }
        try p.add(.trash, "Trash", p.trash_files, "user-trash");
        try p.add(.root, "Computer", "/", "drive-harddisk-system\ncomputer");

        // GTK bookmarks: "file:///path optional label" per line.
        var bm_list: std.ArrayList(u8) = .empty;
        defer bm_list.deinit(p.gpa);
        const bm = readAllAlloc(p.gpa, p.bookmarks_file) orelse "";
        defer if (bm.len != 0) p.gpa.free(bm);
        var lines = std.mem.splitScalar(u8, bm, '\n');
        var first_bookmark = true;
        while (lines.next()) |line| {
            const sp = std.mem.indexOfScalar(u8, line, ' ');
            const u = if (sp) |i| line[0..i] else line;
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const path = uri.filePath(&pbuf, u) orelse continue;
            const label = if (sp) |i| std.mem.trim(u8, line[i + 1 ..], " ") else basename(path);
            if (first_bookmark) {
                try p.add(.header, "Bookmarks", "", "");
                first_bookmark = false;
            }
            try p.add(.bookmark, if (label.len == 0) basename(path) else label, path, "user-bookmarks\nfolder");
        }

        // Drives.
        _ = p.drive_arena.reset(.retain_capacity);
        p.drives.clearRetainingCapacity();
        const a = p.drive_arena.allocator();
        for (drives) |d| try p.drives.append(p.gpa, .{
            .id = try a.dupe(u8, d.id),
            .label = try a.dupe(u8, d.label),
            .mount_point = try a.dupe(u8, d.mount_point),
            .icon = try a.dupe(u8, d.icon),
            .can_mount = d.can_mount,
            .can_unmount = d.can_unmount,
            .can_eject = d.can_eject,
            .size = d.size,
        });
        if (p.drives.items.len != 0) try p.add(.header, "Devices", "", "");
        for (p.drives.items, 0..) |d, i| {
            try p.add(.drive, d.label, d.mount_point, d.icon);
            p.items.items[p.items.items.len - 1].drive = @intCast(i);
        }
    }

    /// Adds `path` to the bookmarks file.
    pub fn addBookmark(p: *Places, path: []const u8) !void {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(p.gpa);
        if (readAllAlloc(p.gpa, p.bookmarks_file)) |old| {
            defer p.gpa.free(old);
            try list.appendSlice(p.gpa, old);
            if (list.items.len > 0 and list.items[list.items.len - 1] != '\n') try list.append(p.gpa, '\n');
        }
        try uri.appendFileUri(&list, p.gpa, path);
        try list.append(p.gpa, '\n');
        try writeFile(p.bookmarks_file, list.items);
    }

    /// Removes `path` from the bookmarks file.
    pub fn removeBookmark(p: *Places, path: []const u8) !void {
        const old = readAllAlloc(p.gpa, p.bookmarks_file) orelse return;
        defer p.gpa.free(old);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(p.gpa);
        var lines = std.mem.splitScalar(u8, old, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ');
            const u = if (sp) |i| line[0..i] else line;
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            if (uri.filePath(&pbuf, u)) |bp| if (std.mem.eql(u8, bp, path)) continue;
            try list.appendSlice(p.gpa, line);
            try list.append(p.gpa, '\n');
        }
        try writeFile(p.bookmarks_file, list.items);
    }
};

pub const Env = struct {
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
};

/// Builds the list for `env`. Directories that do not exist are left out.
pub fn load(gpa: Allocator, env: Env) !Places {
    var p: Places = .{ .gpa = gpa, .drive_arena = .init(gpa) };
    errdefer p.deinit();
    var buf: [linux.PATH_MAX]u8 = undefined;
    p.home = try gpa.dupe(u8, env.home);
    const data = env.data_home orelse (std.fmt.bufPrint(&buf, "{s}/.local/share", .{env.home}) catch env.home);
    p.trash_dir = try std.fmt.allocPrint(gpa, "{s}/Trash", .{data});
    p.trash_files = try std.fmt.allocPrint(gpa, "{s}/Trash/files", .{data});
    const config = env.config_home orelse (std.fmt.bufPrint(&buf, "{s}/.config", .{env.home}) catch env.home);
    p.bookmarks_file = try std.fmt.allocPrint(gpa, "{s}/gtk-3.0/bookmarks", .{config});
    try p.rebuild(env, &.{});
    return p;
}

pub fn basename(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return if (i + 1 == path.len) path else path[i + 1 ..];
}

/// `KEY="$HOME/Pictures"` from user-dirs.dirs, with $HOME expanded.
fn userDir(contents: []const u8, key: []const u8, home: []const u8, out: []u8) ?[]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != '=') continue;
        var v = std.mem.trim(u8, line[key.len + 1 ..], " ");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        if (std.mem.startsWith(u8, v, "$HOME")) {
            return std.fmt.bufPrint(out, "{s}{s}", .{ home, v["$HOME".len..] }) catch null;
        }
        if (v.len > 0 and v[0] == '/') return std.fmt.bufPrint(out, "{s}", .{v}) catch null;
        return null;
    }
    return null;
}

fn readSmall(path: []const u8, buf: []u8) []const u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return "";
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

fn readAllAlloc(gpa: Allocator, path: []const u8) ?[]u8 {
    var buf: [65536]u8 = undefined;
    const s = readSmall(path, &buf);
    if (s.len == 0) return null;
    return gpa.dupe(u8, s) catch null;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    // The directory may not exist yet ($XDG_CONFIG_HOME/gtk-3.0).
    var dbuf: [linux.PATH_MAX]u8 = undefined;
    const dir = path[0 .. std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.Unexpected];
    const zd = try std.fmt.bufPrintSentinel(&dbuf, "{s}", .{dir}, 0);
    _ = linux.mkdirat(linux.AT.FDCWD, zd, 0o755);
    var tbuf: [linux.PATH_MAX]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tbuf, "{s}.tmp", .{path}, 0);
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0);
    const rc = linux.openat(linux.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.AccessDenied;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, data.ptr, data.len);
    _ = linux.close(fd);
    if (linux.errno(linux.renameat(linux.AT.FDCWD, tmp, linux.AT.FDCWD, z)) != .SUCCESS) return error.Unexpected;
}

pub fn isDir(path: []const u8) bool {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return false;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

test "user dirs" {
    var out: [256]u8 = undefined;
    const contents = "# comment\nXDG_PICTURES_DIR=\"$HOME/Bilder\"\nXDG_MUSIC_DIR=\"/srv/music\"\n";
    try std.testing.expectEqualStrings("/home/me/Bilder", userDir(contents, "XDG_PICTURES_DIR", "/home/me", &out).?);
    try std.testing.expectEqualStrings("/srv/music", userDir(contents, "XDG_MUSIC_DIR", "/home/me", &out).?);
    try std.testing.expect(userDir(contents, "XDG_VIDEOS_DIR", "/home/me", &out) == null);
}
