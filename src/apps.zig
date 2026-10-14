//! Applications from freedesktop.org desktop entries, and which ones open
//! a MIME type: mimeapps.list's defaults and associations (the user's,
//! then the system's), then every application whose MimeType lists the
//! type or one of its ancestors. Launching expands the Exec line's field
//! codes and starts the program detached, with an activation token.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const mime = @import("mime.zig");
const uri = @import("uri.zig");

pub const App = struct {
    /// The desktop file id ("org.gnome.TextEditor.desktop").
    id: []const u8,
    name: []const u8,
    exec: []const u8,
    icon: []const u8,
    /// The desktop file.
    path: []const u8,
    terminal: bool,
    /// Listed in menus (NoDisplay is not set).
    shown: bool,
    mime_types: []const []const u8,
};

pub const Db = struct {
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    by_id: std.StringHashMapUnmanaged(u32) = .empty,
    /// mimeapps.list: [Default Applications], [Added Associations], and
    /// [Removed Associations], merged most important first.
    defaults: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    added: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    removed: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// The user's mimeapps.list, which setDefault writes.
    user_list: []const u8 = "",

    pub fn deinit(db: *Db) void {
        db.arena.deinit();
    }

    fn a(db: *Db) Allocator {
        return db.arena.allocator();
    }

    pub fn get(db: *const Db, id: []const u8) ?*const App {
        const i = db.by_id.get(id) orelse return null;
        return &db.apps.items[i];
    }

    /// The application that opens `type` by default, if any.
    pub fn defaultFor(db: *const Db, types: *mime.Db, type_id: mime.Id) ?*const App {
        var buf: [16]mime.Id = undefined;
        for (types.ancestry(type_id, &buf)) |t| {
            const nm = types.name(t);
            if (db.defaults.get(nm)) |ids| for (ids) |id| if (db.get(id)) |app| if (!db.isRemoved(nm, id)) return app;
            if (db.added.get(nm)) |ids| for (ids) |id| if (db.get(id)) |app| if (!db.isRemoved(nm, id)) return app;
            for (db.apps.items) |*app| if (app.shown and handles(app, nm) and !db.isRemoved(nm, app.id)) return app;
        }
        return null;
    }

    fn isRemoved(db: *const Db, type_name: []const u8, id: []const u8) bool {
        const ids = db.removed.get(type_name) orelse return false;
        for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
        return false;
    }

    /// Applications for `type`: the default first, then associations,
    /// then the rest that handle it or an ancestor (most specific first).
    pub fn appsFor(db: *const Db, gpa: Allocator, types: *mime.Db, type_id: mime.Id) ![]*const App {
        var out: std.ArrayList(*const App) = .empty;
        errdefer out.deinit(gpa);
        if (db.defaultFor(types, type_id)) |d| try out.append(gpa, d);
        var buf: [16]mime.Id = undefined;
        for (types.ancestry(type_id, &buf)) |t| {
            const nm = types.name(t);
            if (db.added.get(nm)) |ids| for (ids) |id| if (db.get(id)) |app| try appendUnique(gpa, &out, app);
            for (db.apps.items) |*app| if (app.shown and handles(app, nm) and !db.isRemoved(nm, app.id)) try appendUnique(gpa, &out, app);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every application shown in menus, by name.
    pub fn allApps(db: *const Db, gpa: Allocator) ![]*const App {
        var out: std.ArrayList(*const App) = .empty;
        errdefer out.deinit(gpa);
        for (db.apps.items) |*app| if (app.shown) try out.append(gpa, app);
        std.mem.sort(*const App, out.items, {}, struct {
            fn less(_: void, x: *const App, y: *const App) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.less);
        return out.toOwnedSlice(gpa);
    }

    /// Makes `app_id` the default for `type_name` in the user's
    /// mimeapps.list (and in this database).
    pub fn setDefault(db: *Db, gpa: Allocator, type_name: []const u8, app_id: []const u8) !void {
        if (db.user_list.len == 0) return error.Unavailable;
        // Rewrite the file: keep every line except this type's default.
        var old_buf: std.ArrayList(u8) = .empty;
        defer old_buf.deinit(gpa);
        if (readAll(gpa, db.user_list)) |old| {
            defer gpa.free(old);
            try old_buf.appendSlice(gpa, old);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var it = std.mem.splitScalar(u8, old_buf.items, '\n');
        var section: []const u8 = "";
        var wrote = false;
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len > 0 and line[0] == '[') {
                if (std.mem.eql(u8, section, "[Default Applications]") and !wrote) {
                    try out.print(gpa, "{s}={s};\n", .{ type_name, app_id });
                    wrote = true;
                }
                section = line;
            } else if (std.mem.eql(u8, section, "[Default Applications]") and std.mem.startsWith(u8, line, type_name) and line.len > type_name.len and line[type_name.len] == '=') {
                continue;
            }
            if (line.len == 0 and it.peek() == null) break;
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
        }
        if (!wrote) {
            if (!std.mem.eql(u8, section, "[Default Applications]")) try out.appendSlice(gpa, "[Default Applications]\n");
            try out.print(gpa, "{s}={s};\n", .{ type_name, app_id });
        }
        try writeAll(db.user_list, out.items);
        const ids = try db.a().alloc([]const u8, 1);
        ids[0] = try db.a().dupe(u8, app_id);
        try db.defaults.put(db.a(), try db.a().dupe(u8, type_name), ids);
    }
};

fn appendUnique(gpa: Allocator, out: *std.ArrayList(*const App), app: *const App) !void {
    for (out.items) |x| if (x == app) return;
    try out.append(gpa, app);
}

fn handles(app: *const App, type_name: []const u8) bool {
    for (app.mime_types) |t| if (std.mem.eql(u8, t, type_name)) return true;
    return false;
}

pub const Dirs = struct {
    /// $XDG_DATA_HOME first, then $XDG_DATA_DIRS.
    data: []const []const u8,
    /// $XDG_CONFIG_HOME first, then $XDG_CONFIG_DIRS.
    config: []const []const u8,
    /// $XDG_CURRENT_DESKTOP's names, lowercased, for desktop-specific
    /// mimeapps lists.
    desktops: []const []const u8 = &.{},
};

/// Reads every desktop entry and mimeapps.list. Blocking.
pub fn load(gpa: Allocator, dirs: Dirs) !*Db {
    const db = try gpa.create(Db);
    errdefer gpa.destroy(db);
    db.* = .{ .arena = .init(gpa) };
    errdefer db.arena.deinit();
    // Applications: earlier directories win for the same id.
    for (dirs.data) |d| {
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        const apps_dir = std.fmt.bufPrint(&pbuf, "{s}/applications", .{d}) catch continue;
        scanApps(db, gpa, apps_dir, "") catch {};
    }
    // mimeapps.list, most important first: config dirs (desktop-specific
    // before generic), then data dirs' applications/.
    if (dirs.config.len > 0) db.user_list = try std.fmt.allocPrint(db.a(), "{s}/mimeapps.list", .{dirs.config[0]});
    for (dirs.config) |d| {
        for (dirs.desktops) |desk| {
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            readMimeApps(db, gpa, std.fmt.bufPrint(&pbuf, "{s}/{s}-mimeapps.list", .{ d, desk }) catch continue) catch {};
        }
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        readMimeApps(db, gpa, std.fmt.bufPrint(&pbuf, "{s}/mimeapps.list", .{d}) catch continue) catch {};
    }
    for (dirs.data) |d| {
        var pbuf: [linux.PATH_MAX]u8 = undefined;
        readMimeApps(db, gpa, std.fmt.bufPrint(&pbuf, "{s}/applications/mimeapps.list", .{d}) catch continue) catch {};
    }
    return db;
}

fn scanApps(db: *Db, gpa: Allocator, dir: []const u8, prefix: []const u8) !void {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{dir}, 0);
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const d: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
            off += d.reclen;
            const raw: [*:0]const u8 = @ptrCast(&buf[off - d.reclen + @offsetOf(linux.dirent64, "name")]);
            const nm = std.mem.span(raw);
            if (nm[0] == '.') continue;
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ dir, nm }) catch continue;
            if (d.type == linux.DT.DIR) {
                // Subdirectories prefix the id: kde/x.desktop is kde-x.desktop.
                var idp: [256]u8 = undefined;
                const p = std.fmt.bufPrint(&idp, "{s}{s}-", .{ prefix, nm }) catch continue;
                scanApps(db, gpa, path, p) catch {};
                continue;
            }
            if (!std.mem.endsWith(u8, nm, ".desktop")) continue;
            var idb: [256]u8 = undefined;
            const id = std.fmt.bufPrint(&idb, "{s}{s}", .{ prefix, nm }) catch continue;
            if (db.by_id.contains(id)) continue;
            const data = readAll(gpa, path) orelse continue;
            defer gpa.free(data);
            const app = parseEntry(db.a(), data) catch continue;
            const entry = app orelse {
                // Hidden or not an application: still claims the id, so a
                // user's Hidden=true overrides the system's entry.
                try db.by_id.put(db.a(), try db.a().dupe(u8, id), std.math.maxInt(u32));
                continue;
            };
            var e = entry;
            e.id = try db.a().dupe(u8, id);
            e.path = try db.a().dupe(u8, path);
            try db.by_id.put(db.a(), e.id, @intCast(db.apps.items.len));
            try db.apps.append(db.a(), e);
        }
    }
    // Ids that a Hidden entry claimed resolve to nothing.
    var it = db.by_id.iterator();
    while (it.next()) |kv| if (kv.value_ptr.* == std.math.maxInt(u32)) {
        _ = db.by_id.remove(kv.key_ptr.*);
        // The iterator is invalid after a removal: start over.
        it = db.by_id.iterator();
    };
}

/// Parses a desktop entry; null for entries that are not applications or
/// are hidden.
pub fn parseEntry(arena: Allocator, data: []const u8) !?App {
    var app: App = .{ .id = "", .name = "", .exec = "", .icon = "", .path = "", .terminal = false, .shown = true, .mime_types = &.{} };
    var in_entry = false;
    var is_app = false;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "Type")) {
            is_app = std.mem.eql(u8, value, "Application");
        } else if (std.mem.eql(u8, key, "Name")) {
            app.name = try unescape(arena, value);
        } else if (std.mem.eql(u8, key, "Exec")) {
            app.exec = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Icon")) {
            app.icon = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "Terminal")) {
            app.terminal = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            app.shown = !std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "Hidden")) {
            if (std.mem.eql(u8, value, "true")) return null;
        } else if (std.mem.eql(u8, key, "MimeType")) {
            app.mime_types = try splitList(arena, value);
        }
    }
    if (!is_app or app.exec.len == 0 or app.name.len == 0) return null;
    return app;
}

fn unescape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(arena, switch (s[i]) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => s[i],
            });
        } else try out.append(arena, s[i]);
    }
    return out.toOwnedSlice(arena);
}

fn splitList(arena: Allocator, value: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, value, ';');
    while (it.next()) |x| {
        const t = std.mem.trim(u8, x, " ");
        if (t.len != 0) try list.append(arena, try arena.dupe(u8, t));
    }
    return list.toOwnedSlice(arena);
}

fn readMimeApps(db: *Db, gpa: Allocator, path: []const u8) !void {
    const data = readAll(gpa, path) orelse return;
    defer gpa.free(data);
    var section: enum { none, defaults, added, removed } = .none;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = if (std.mem.eql(u8, line, "[Default Applications]")) .defaults else if (std.mem.eql(u8, line, "[Added Associations]")) .added else if (std.mem.eql(u8, line, "[Removed Associations]")) .removed else .none;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const map = switch (section) {
            .none => continue,
            .defaults => &db.defaults,
            .added => &db.added,
            .removed => &db.removed,
        };
        const key = std.mem.trim(u8, line[0..eq], " ");
        // The most important file came first: keep its value.
        if (map.contains(key)) continue;
        try map.put(db.a(), try db.a().dupe(u8, key), try splitList(db.a(), line[eq + 1 ..]));
    }
}

fn readAll(gpa: Allocator, path: []const u8) ?[]u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(gpa, chunk[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
        if (list.items.len > 1 << 20) break;
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn writeAll(path: []const u8, data: []const u8) !void {
    var tbuf: [linux.PATH_MAX]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tbuf, "{s}.tmp", .{path}, 0);
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0);
    const rc = linux.openat(linux.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return error.AccessDenied;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < data.len) {
        const w = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(w) != .SUCCESS) {
            _ = linux.close(fd);
            return error.Unexpected;
        }
        off += w;
    }
    _ = linux.close(fd);
    if (linux.errno(linux.renameat(linux.AT.FDCWD, tmp, linux.AT.FDCWD, z)) != .SUCCESS) return error.Unexpected;
}

// Launching -----------------------------------------------------------------------

/// The argument vectors to run `app` on `paths`: one for all of them if
/// its Exec takes a list (%F, %U), else one per path (%f, %u), or one
/// without arguments. Every string is copied into `arena`: the launch
/// spawns them later (once the activation token arrives), after the
/// caller's paths and perhaps the application database are gone.
pub fn commandLines(arena: Allocator, app: *const App, paths: []const []const u8) ![][]const []const u8 {
    const args = try splitExec(arena, app.exec);
    var takes_list = false;
    var takes_one = false;
    for (args) |arg| {
        if (std.mem.indexOf(u8, arg, "%F") != null or std.mem.indexOf(u8, arg, "%U") != null) takes_list = true;
        if (std.mem.indexOf(u8, arg, "%f") != null or std.mem.indexOf(u8, arg, "%u") != null) takes_one = true;
    }
    var out: std.ArrayList([]const []const u8) = .empty;
    if (takes_list or paths.len == 0 or !takes_one) {
        try out.append(arena, try expand(arena, app, args, paths));
    } else {
        for (paths) |p| try out.append(arena, try expand(arena, app, args, &.{p}));
    }
    // Terminal applications run in the user's terminal.
    if (app.terminal) for (out.items) |*argv| {
        argv.* = try inTerminal(arena, argv.*);
    };
    return out.toOwnedSlice(arena);
}

fn inTerminal(arena: Allocator, argv: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try terminal(arena, &out);
    for (argv) |x| try out.append(arena, x);
    return out.toOwnedSlice(arena);
}

/// Terminals, and the arguments before the command they run.
const known_terminals = [_][]const []const u8{
    &.{ "foot", "--" },
    &.{ "alacritty", "-e" },
    &.{ "kitty", "--" },
    &.{ "wezterm", "start", "--" },
    &.{ "ghostty", "-e" },
    &.{ "gnome-terminal", "--" },
    &.{ "ptyxis", "--" },
    &.{ "konsole", "-e" },
    &.{ "xfce4-terminal", "-x" },
    &.{ "xterm", "-e" },
};

/// The terminal command a Terminal=true application runs in, copied into
/// `out`: $TERMINAL (which may carry arguments) with the flag its
/// terminal takes before a command ("-e" for one this does not know),
/// else xdg-terminal-exec, else the first common terminal on $PATH.
fn terminal(arena: Allocator, out: *std.ArrayList([]const u8)) !void {
    const S = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    };
    if (S.getenv("TERMINAL")) |t| {
        var it = std.mem.tokenizeAny(u8, std.mem.span(t), " \t");
        const prog = it.next() orelse "";
        if (prog.len != 0) {
            try out.append(arena, try arena.dupe(u8, prog));
            var has_args = false;
            while (it.next()) |x| {
                has_args = true;
                try out.append(arena, try arena.dupe(u8, x));
            }
            // "foot -e" or the like already ends in its flag.
            if (has_args) return;
            const base = if (std.mem.lastIndexOfScalar(u8, prog, '/')) |i| prog[i + 1 ..] else prog;
            for (known_terminals) |k| if (std.mem.eql(u8, k[0], base)) {
                for (k[1..]) |x| try out.append(arena, x);
                return;
            };
            try out.append(arena, "-e");
            return;
        }
    }
    if (onPath("xdg-terminal-exec")) return out.append(arena, "xdg-terminal-exec");
    for (known_terminals) |k| if (onPath(k[0])) {
        for (k) |x| try out.append(arena, x);
        return;
    };
    try out.appendSlice(arena, &.{ "xterm", "-e" });
}

/// The user's terminal by itself, to open in a folder: the `terminal`
/// option ("foot", "kitty --"), else $TERMINAL, else xdg-terminal-exec,
/// else the first common terminal on $PATH, each without the flag it
/// takes before a command. Copied into `arena`.
pub fn terminalAlone(arena: Allocator, option: []const u8) ![]const []const u8 {
    const S = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    };
    var out: std.ArrayList([]const u8) = .empty;
    const given: []const u8 = if (option.len != 0) option else if (S.getenv("TERMINAL")) |t| std.mem.span(t) else "";
    if (given.len != 0) {
        for (try splitExec(arena, given)) |x| {
            // What follows is the command it would run.
            if (std.mem.eql(u8, x, "--") or std.mem.eql(u8, x, "-e") or std.mem.eql(u8, x, "-x") or std.mem.eql(u8, x, "start")) break;
            try out.append(arena, try arena.dupe(u8, x));
        }
        if (out.items.len != 0) return out.items;
    }
    if (onPath("xdg-terminal-exec")) return arena.dupe([]const u8, &.{"xdg-terminal-exec"});
    for (known_terminals) |k| if (onPath(k[0])) return arena.dupe([]const u8, &.{k[0]});
    return arena.dupe([]const u8, &.{"xterm"});
}

pub fn onPath(prog: []const u8) bool {
    const S = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    };
    const path = if (S.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const p = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, prog }, 0) catch continue;
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, p, linux.X_OK, 0)) == .SUCCESS) return true;
    }
    return false;
}

/// Splits an Exec value into arguments, with the specification's quoting:
/// double quotes, inside which \", \`, \$, and \\ escape.
pub fn splitExec(arena: Allocator, exec: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_quotes = false;
    var has = false;
    var i: usize = 0;
    while (i < exec.len) : (i += 1) {
        const ch = exec[i];
        if (in_quotes) {
            if (ch == '"') {
                in_quotes = false;
            } else if (ch == '\\' and i + 1 < exec.len and std.mem.indexOfScalar(u8, "\"`$\\", exec[i + 1]) != null) {
                i += 1;
                try cur.append(arena, exec[i]);
            } else try cur.append(arena, ch);
            continue;
        }
        switch (ch) {
            '"' => {
                in_quotes = true;
                has = true;
            },
            ' ', '\t' => if (has or cur.items.len > 0) {
                try out.append(arena, try cur.toOwnedSlice(arena));
                has = false;
            },
            else => try cur.append(arena, ch),
        }
    }
    if (has or cur.items.len > 0) try out.append(arena, try cur.toOwnedSlice(arena));
    return out.toOwnedSlice(arena);
}

fn expand(arena: Allocator, app: *const App, args: []const []const u8, paths: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        // Codes that stand alone expand to several arguments, or none.
        if (std.mem.eql(u8, arg, "%F")) {
            for (paths) |p| try out.append(arena, try arena.dupe(u8, p));
            continue;
        }
        if (std.mem.eql(u8, arg, "%U")) {
            for (paths) |p| try out.append(arena, try fileUri(arena, p));
            continue;
        }
        if (std.mem.eql(u8, arg, "%i")) {
            if (app.icon.len != 0) {
                try out.append(arena, "--icon");
                try out.append(arena, try arena.dupe(u8, app.icon));
            }
            continue;
        }
        var s: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var dropped = false;
        while (i < arg.len) : (i += 1) {
            if (arg[i] != '%' or i + 1 >= arg.len) {
                try s.append(arena, arg[i]);
                continue;
            }
            i += 1;
            switch (arg[i]) {
                '%' => try s.append(arena, '%'),
                'f' => if (paths.len > 0) try s.appendSlice(arena, paths[0]) else {
                    dropped = true;
                },
                'u' => if (paths.len > 0) try s.appendSlice(arena, try fileUri(arena, paths[0])) else {
                    dropped = true;
                },
                'c' => try s.appendSlice(arena, app.name),
                'k' => try s.appendSlice(arena, app.path),
                // Deprecated and list codes inside a word: dropped.
                else => {},
            }
        }
        if (dropped and s.items.len == 0) continue;
        try out.append(arena, try s.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

fn fileUri(arena: Allocator, path: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    try uri.appendFileUri(&list, arena, path);
    return list.toOwnedSlice(arena);
}

extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern var environ: [*:null]?[*:0]u8;

/// Starts `argv` detached from this process (its own session, reparented
/// to init), in `cwd`, with $XDG_ACTIVATION_TOKEN set when there is a
/// token. Only async-signal-safe calls happen between fork and exec.
pub fn spawn(gpa: Allocator, argv: []const []const u8, cwd: []const u8, token: []const u8) !void {
    if (argv.len == 0) return error.InvalidArgument;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cargv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |x, i| cargv[i] = try arena.dupeSentinel(u8, x, 0);
    // The environment, with the activation token replaced.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "XDG_ACTIVATION_TOKEN=") or std.mem.startsWith(u8, s, "DESKTOP_STARTUP_ID=")) continue;
        try env.append(arena, e);
    }
    if (token.len != 0) {
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "XDG_ACTIVATION_TOKEN={s}", .{token}, 0));
        try env.append(arena, try std.fmt.allocPrintSentinel(arena, "DESKTOP_STARTUP_ID={s}", .{token}, 0));
    }
    const cenv = try arena.allocSentinel(?[*:0]const u8, env.items.len, null);
    @memcpy(cenv[0..env.items.len], env.items);
    const ccwd = try arena.dupeSentinel(u8, cwd, 0);
    const pid = fork();
    if (pid < 0) return error.Unavailable;
    if (pid == 0) {
        // The child forks again and exits, so the program is not ours to
        // reap.
        if (fork() != 0) _exit(0);
        _ = setsid();
        _ = chdir(ccwd.ptr);
        _ = execvpe(cargv[0].?, cargv.ptr, cenv.ptr);
        _exit(127);
    }
    _ = waitpid(pid, null, 0);
}

const testing = std.testing;

test "exec lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try splitExec(a, "env \"A B\" prog --flag=\"x\\\"y\" %U");
    try testing.expectEqual(@as(usize, 5), args.len);
    try testing.expectEqualStrings("A B", args[1]);
    try testing.expectEqualStrings("--flag=x\"y", args[3]);
    const app: App = .{ .id = "x.desktop", .name = "X", .exec = "x --new %f", .icon = "x", .path = "/a/x.desktop", .terminal = false, .shown = true, .mime_types = &.{} };
    const lines = try commandLines(a, &app, &.{ "/a b", "/c" });
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("/a b", lines[0][2]);
    const app2: App = .{ .id = "y.desktop", .name = "Y", .exec = "y %U %i", .icon = "yi", .path = "", .terminal = false, .shown = true, .mime_types = &.{} };
    const l2 = try commandLines(a, &app2, &.{ "/a b", "/c" });
    try testing.expectEqual(@as(usize, 1), l2.len);
    try testing.expectEqualStrings("file:///a%20b", l2[0][1]);
    try testing.expectEqualStrings("--icon", l2[0][3]);
    const l3 = try commandLines(a, &app, &.{});
    try testing.expectEqual(@as(usize, 2), l3[0].len);
}

test "desktop entries" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const e = (try parseEntry(arena.allocator(), "[Desktop Entry]\nType=Application\nName=Text Editor\nName[de]=Texteditor\nExec=te %F\nMimeType=text/plain;text/x-csrc;\n[Desktop Action new]\nExec=other\n")).?;
    try testing.expectEqualStrings("Text Editor", e.name);
    try testing.expectEqualStrings("te %F", e.exec);
    try testing.expectEqual(@as(usize, 2), e.mime_types.len);
    try testing.expect(try parseEntry(arena.allocator(), "[Desktop Entry]\nType=Link\nName=x\nExec=y\n") == null);
}
