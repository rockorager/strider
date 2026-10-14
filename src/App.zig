//! The application: its windows, and what they share — the directory
//! cache, options and keymap, the Lua configuration, the MIME and
//! application databases, bookmarks, the command history, the yank
//! register, running file operations, the undo history, and drives.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const c = siv.c;
pub const Window = @import("Window.zig");
pub const Dir = @import("Dir.zig");
pub const Config = @import("Config.zig");
pub const keys = @import("keys.zig");
pub const model = @import("model.zig");
pub const mime = @import("mime.zig");
pub const fsops = @import("fsops.zig");
const proc = @import("proc.zig");
pub const places_mod = @import("places.zig");
pub const apps = @import("apps.zig");
pub const undo_mod = @import("undo.zig");
pub const trash = @import("trash.zig");
pub const uri = @import("uri.zig");
pub const mounts = @import("mounts.zig");
pub const sync = @import("sync.zig");
pub const ui = @import("ui.zig");
pub const Lua = @import("Lua.zig");
pub const UDisks = @import("UDisks.zig");
pub const FileManager1 = @import("FileManager1.zig");
pub const Portal = @import("Portal.zig");
pub const Chooser = @import("Chooser.zig");
pub const commands = @import("commands.zig");

const App = @This();

pub const app_id = "org.siv.Columns";
/// File chooser windows' app id, for compositor rules (Hyprland's, say).
pub const chooser_app_id = "org.siv.Columns.Chooser";
pub const program = "siv-columns";

pub const Options = struct {
    /// Thread-safe: jobs allocate on worker threads.
    gpa: Allocator,
    home: []const u8,
    config_home: ?[]const u8 = null,
    data_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
    state_home: ?[]const u8 = null,
    /// $XDG_DATA_HOME then $XDG_DATA_DIRS, for MIME types and
    /// applications; empty for none (tests).
    data_dirs: []const []const u8 = &.{},
    /// $XDG_CONFIG_HOME then $XDG_CONFIG_DIRS, for mimeapps.list.
    config_dirs: []const []const u8 = &.{},
    desktops: []const []const u8 = &.{},
    /// Seconds east of UTC for dates.
    tz_offset_s: i64 = 0,
    /// Follow changes to folders with inotify.
    watch: bool = true,
    /// Tell zoxide about the folders visited, when it is on $PATH.
    zoxide: bool = true,
    /// Ask UDisks2 for drives (off in tests).
    udisks: bool = true,
    /// UDisks2's bus: null is the system bus (tests pass an address).
    system_bus: ?[]const u8 = null,
    /// Where org.freedesktop.FileManager1 is served: null is the session
    /// bus (tests pass an address).
    session_bus: ?[]const u8 = null,
    /// Read drives from the mount table (off in tests).
    mount_table: bool = true,
    /// Leave out what differs between machines and runs, for golden
    /// images.
    reproducible: bool = false,
    /// The application's own icons, searched before the icon theme's
    /// fallbacks.
    icon_dir: ?[]const u8 = null,
    /// init.lua to run; null runs none.
    config_file: ?[]const u8 = null,
    /// Where bookmarks and the command history persist; null keeps them
    /// in memory (tests).
    state_dir: ?[]const u8 = null,
    /// Print errors from init.lua to stderr as well.
    log_errors: bool = true,
    window_width: u32 = 1200,
    window_height: u32 = 720,
    /// Called when the last window is gone.
    on_last_window_closed: ?*const fn (*App) void = null,
};

gpa: Allocator,
app: siv.App,
opts: Options,
home: []u8,
places: places_mod.Places,
options: Config.Options = .{},
strings: Config.Strings,
keymap: keys.Keymap,
cache: Dir.Cache,
windows: std.ArrayList(*Window) = .empty,
undo: undo_mod.Stack,
tz_offset_s: i64,
thumbnail_cache: []u8 = &.{},
preview_cache: []u8 = &.{},
lua: ?*Lua = null,
/// Errors from init.lua, shown by the first window.
config_error: ?[]u8 = null,

/// Bookmarks: a path per key character.
bookmarks: std.AutoArrayHashMapUnmanaged(u32, []u8) = .empty,
/// Command lines entered, oldest first.
history: std.ArrayList([]u8) = .empty,
/// Column widths the user chose by dragging a handle or with < and >:
/// the parent's and the current column's shares of the window's width.
/// They win over `ratio` and `fit_parent` until `column-reset`, and
/// persist in $XDG_STATE_HOME/siv-columns/columns.
widths: ?[2]f32 = null,
/// The size the user last gave a file chooser window, kept across starts.
chooser_size: ?[2]u32 = null,
/// File operations that finished, newest first, for the tasks view.
recent: std.ArrayList(Finished) = .empty,
/// zoxide is on $PATH (looked for once, at startup), and the folder
/// last told to it.
zoxide: bool = false,
zoxide_last: std.ArrayList(u8) = .empty,
/// The status line's recent messages, oldest first (`:messages`).
messages: std.ArrayList(Message) = .empty,
/// What yy and dd took: paths, and whether pasting moves them.
register: std.ArrayList([]u8) = .empty,
register_cut: bool = false,

/// Loaded once by the first job that needs it.
mime_db: ?*mime.Db = null,
mime_mutex: sync.Mutex = .{},
apps_db: ?*apps.Db = null,
apps_loading: bool = false,
/// Opens waiting for the application database.
pending_opens: std.ArrayList(PendingOpen) = .empty,

ops: std.ArrayList(*OpEntry) = .empty,
ops_timer: siv.Timer = .null,
udisks: ?*UDisks = null,
file_manager1: ?*FileManager1 = null,
/// The FileChooser portal backend.
portal: ?*Portal = null,
/// Where the last file chooser picked, where the next one starts.
last_chooser_folder: ?[]u8 = null,
drives_arena: std.heap.ArenaAllocator,

const PendingOpen = struct { win: *Window, paths: [][]u8, ask: bool };

/// A finished file operation, as the tasks view lists it.
pub const Finished = struct {
    title: []u8,
    /// What came of it, as the status line said.
    result: []u8,
    failed: bool,
    canceled: bool,
};

/// How many finished operations the tasks view keeps.
pub const max_recent = 20;

/// A row of the tasks view: running operations first, in the order they
/// started, then finished ones, newest first.
pub const Task = union(enum) { running: *OpEntry, finished: *const Finished };

pub fn taskCount(self: *const App) usize {
    return self.ops.items.len + self.recent.items.len;
}

pub fn taskAt(self: *const App, i: usize) ?Task {
    if (i < self.ops.items.len) return .{ .running = self.ops.items[i] };
    const k = i - self.ops.items.len;
    if (k < self.recent.items.len) return .{ .finished = &self.recent.items[k] };
    return null;
}

/// Takes a finished operation off the tasks view.
pub fn removeRecent(self: *App, k: usize) void {
    const f = self.recent.orderedRemove(k);
    self.gpa.free(f.title);
    self.gpa.free(f.result);
}

pub const Message = struct {
    /// Wall clock, in seconds since the epoch.
    time: i64,
    is_error: bool,
    text: []u8,
};

/// How many messages `:messages` keeps.
pub const max_messages = 200;

pub fn create(sapp: siv.App, opts: Options) !*App {
    const gpa = opts.gpa;
    const self = try gpa.create(App);
    errdefer gpa.destroy(self);
    const home = try gpa.dupe(u8, opts.home);
    errdefer gpa.free(home);
    var places = try places_mod.load(gpa, .{ .home = opts.home, .config_home = opts.config_home, .data_home = opts.data_home });
    errdefer places.deinit();
    self.* = .{
        .gpa = gpa,
        .app = sapp,
        .opts = opts,
        .home = home,
        .places = places,
        .strings = .{ .gpa = gpa },
        .keymap = .{ .gpa = gpa },
        .cache = .{ .gpa = gpa, .sapp = sapp, .load_mime = loadMimeCb, .on_loaded = dirLoadedCb, .ctx = self },
        .undo = .{ .gpa = gpa },
        .tz_offset_s = opts.tz_offset_s,
        .drives_arena = .init(gpa),
    };
    self.cache.trash_files = self.places.trash_files;
    self.cache.trash_dir = self.places.trash_dir;
    self.keymap.release = Lua.releaseRef;
    self.keymap.release_ctx = self;
    const cache_root = if (opts.cache_home) |ch| try gpa.dupe(u8, ch) else try std.fmt.allocPrint(gpa, "{s}/.cache", .{opts.home});
    defer gpa.free(cache_root);
    self.thumbnail_cache = try std.fmt.allocPrint(gpa, "{s}/thumbnails", .{cache_root});
    self.preview_cache = try std.fmt.allocPrint(gpa, "{s}/" ++ program ++ "/previews", .{cache_root});
    if (opts.icon_dir) |dir| try siv.check(c.siv_app_add_icon_path(sapp, dir.ptr, dir.len));
    for (Config.default_bindings) |b| self.keymap.map(b[0], b[1], .{ .command = b[2] }, b[3]) catch {};
    self.loadBookmarks();
    self.loadHistory();
    self.loadWidths();
    self.loadChooserSize();
    // The configuration: Lua changes options and the keymap.
    if (opts.config_file) |path| {
        self.lua = Lua.create(self) catch null;
        if (self.lua) |l| l.runFile(path);
    }
    self.applyViewOptions();
    if (opts.watch) self.cache.startWatching();
    self.zoxide = opts.zoxide and proc.onPath("zoxide");
    if (opts.mount_table) self.refreshMountDrives();
    if (opts.udisks) self.udisks = UDisks.create(self) catch null;
    return self;
}

pub fn destroy(self: *App) void {
    const gpa = self.gpa;
    while (self.windows.items.len > 0) {
        const w = self.windows.items[self.windows.items.len - 1];
        w.close();
    }
    self.windows.deinit(gpa);
    for (self.ops.items) |e| {
        e.app = null;
        e.op.requestCancel();
    }
    self.ops.deinit(gpa);
    if (self.ops_timer != .null) _ = c.siv_timer_cancel(self.ops_timer);
    if (self.udisks) |u| u.destroy();
    if (self.file_manager1) |f| f.destroy();
    if (self.portal) |p| p.destroy();
    if (self.last_chooser_folder) |p| gpa.free(p);
    for (self.pending_opens.items) |p| freePaths(gpa, p.paths);
    self.pending_opens.deinit(gpa);
    // Lua holds keymap references: the keymap goes first.
    self.keymap.deinit();
    if (self.lua) |l| l.destroy();
    self.cache.deinit();
    self.undo.deinit();
    self.places.deinit();
    self.drives_arena.deinit();
    self.strings.deinit();
    for (self.bookmarks.values()) |v| gpa.free(v);
    self.bookmarks.deinit(gpa);
    for (self.history.items) |h| gpa.free(h);
    self.history.deinit(gpa);
    self.zoxide_last.deinit(gpa);
    for (self.messages.items) |m| gpa.free(m.text);
    self.messages.deinit(gpa);
    for (self.recent.items) |f| {
        gpa.free(f.title);
        gpa.free(f.result);
    }
    self.recent.deinit(gpa);
    freePathList(gpa, &self.register);
    if (self.config_error) |e| gpa.free(e);
    if (self.mime_db) |db| {
        db.deinit();
        gpa.destroy(db);
    }
    if (self.apps_db) |db| {
        db.deinit();
        gpa.destroy(db);
    }
    gpa.free(self.thumbnail_cache);
    gpa.free(self.preview_cache);
    gpa.free(self.home);
    gpa.destroy(self);
}

pub fn freePaths(gpa: Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

fn freePathList(gpa: Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |p| gpa.free(p);
    list.deinit(gpa);
}

/// Starts the services on the session bus: org.freedesktop.FileManager1
/// and the FileChooser portal backend.
pub fn startServices(self: *App) void {
    if (self.portal == null) self.portal = Portal.create(self) catch null;
    if (self.file_manager1 == null) self.file_manager1 = FileManager1.create(self) catch null;
}

/// A file chooser request: its window, in the folder it asked for, else
/// where the last one picked, else home.
pub fn openChooser(self: *App, ch: *Chooser) void {
    const start = if (ch.folder.len != 0) ch.folder else self.last_chooser_folder orelse self.home;
    const w = Window.createChooser(self, start, ch) catch return ch.finish(2);
    self.windows.append(self.gpa, w) catch {
        w.close();
        return;
    };
    if (ch.select.len != 0) w.curDir().selectName(ch.select);
}

pub fn setChooserFolder(self: *App, path: []const u8) void {
    const copy = self.gpa.dupe(u8, path) catch return;
    if (self.last_chooser_folder) |p| self.gpa.free(p);
    self.last_chooser_folder = copy;
}

// Windows ----------------------------------------------------------------------------------

pub fn newWindow(self: *App, path: []const u8) !*Window {
    const w = try Window.create(self, path);
    errdefer w.close();
    try self.windows.append(self.gpa, w);
    if (self.config_error) |e| {
        w.notify(e, true);
        self.gpa.free(e);
        self.config_error = null;
    }
    return w;
}

pub fn windowClosed(self: *App, w: *Window) void {
    for (self.windows.items, 0..) |x, i| if (x == w) {
        _ = self.windows.orderedRemove(i);
        break;
    };
    for (self.ops.items) |e| if (e.win == w) {
        e.win = null;
    };
    for (self.pending_opens.items) |*p| if (p.win == w) {
        freePaths(self.gpa, p.paths);
        p.paths = &.{};
    };
    if (self.windows.items.len == 0) if (self.opts.on_last_window_closed) |f| f(self);
}

/// The window input went to last, for activations; file choosers are
/// their callers', not the app's.
pub fn lastWindow(self: *App) ?*Window {
    var best: ?*Window = null;
    for (self.windows.items) |w| {
        if (w.chooser != null) continue;
        if (best == null or w.last_input > best.?.last_input) best = w;
    }
    return best;
}

/// Shows these folders and files (their folders, with the file under the
/// cursor): a tab each in the last window, or a new window.
pub fn showPaths(self: *App, paths: []const []const u8, new_window: bool, token: []const u8) void {
    var win: ?*Window = if (new_window) null else self.lastWindow();
    for (paths) |p| {
        if (win == null) {
            win = self.newWindow(p) catch return;
            continue;
        }
        win.?.newTab(p);
    }
    if (win == null) win = self.newWindow(self.home) catch return;
    _ = c.siv_window_activate(win.?.window, token.ptr, token.len);
}

/// FileManager1's ShowItems: each item (folders too) under the cursor in
/// its folder, a tab each.
pub fn showItems(self: *App, paths: []const []const u8, token: []const u8) void {
    var win = self.lastWindow();
    for (paths) |p| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const target = model.normalize(&buf, p);
        if (win) |w| {
            w.newTabSelecting(target);
        } else {
            win = self.newWindow(model.parent(target)) catch return;
            win.?.selectAfterLoad(target);
            win.?.showTab();
        }
    }
    if (win) |w| _ = c.siv_window_activate(w.window, token.ptr, token.len);
}

/// FileManager1's ShowItemProperties: the item under the cursor, its
/// details in the preview.
pub fn showProperties(self: *App, paths: []const []const u8, token: []const u8) void {
    self.showItems(paths, token);
}

// Directories -----------------------------------------------------------------------------

fn loadMimeCb(ctx: ?*anyopaque) ?*mime.Db {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    return self.loadMimeDb();
}

fn dirLoadedCb(ctx: ?*anyopaque, d: *Dir) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    for (self.windows.items) |w| w.dirLoaded(d);
}

/// The sort and hidden options to the cache, and every window shows them.
pub fn applyViewOptions(self: *App) void {
    self.cache.setView(self.options.sort, self.options.show_hidden);
    for (self.windows.items) |w| w.optionsChanged();
}

// Databases ---------------------------------------------------------------------------

/// The MIME database, loading it if no job has: from worker threads.
pub fn loadMimeDb(self: *App) ?*mime.Db {
    self.mime_mutex.lock();
    defer self.mime_mutex.unlock();
    if (self.mime_db) |db| return db;
    if (self.opts.data_dirs.len == 0) return null;
    const db = mime.load(self.gpa, self.opts.data_dirs) catch return null;
    @atomicStore(?*mime.Db, &self.mime_db, db, .release);
    return db;
}

/// The MIME database if it is loaded (UI thread).
pub fn mimeDb(self: *App) ?*mime.Db {
    return @atomicLoad(?*mime.Db, &self.mime_db, .acquire);
}

const AppsLoad = struct {
    app: *App,
    db: ?*apps.Db = null,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const l: *AppsLoad = @ptrCast(@alignCast(ud.?));
        _ = l.app.loadMimeDb();
        l.db = apps.load(l.app.gpa, .{ .data = l.app.opts.data_dirs, .config = l.app.opts.config_dirs, .desktops = l.app.opts.desktops }) catch null;
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const l: *AppsLoad = @ptrCast(@alignCast(ud.?));
        const self = l.app;
        self.apps_loading = false;
        self.apps_db = l.db;
        l.db = null;
        const pending = self.pending_opens.toOwnedSlice(self.gpa) catch return;
        defer self.gpa.free(pending);
        for (pending) |p| {
            if (p.paths.len != 0) {
                const views = self.gpa.alloc([]const u8, p.paths.len) catch continue;
                defer self.gpa.free(views);
                for (p.paths, 0..) |x, i| views[i] = x;
                if (p.ask) p.win.openWithMenu(views) else self.openPaths(p.win, views, null);
            }
            freePaths(self.gpa, p.paths);
        }
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const l: *AppsLoad = @ptrCast(@alignCast(ud.?));
        if (l.db) |db| {
            db.deinit();
            l.app.gpa.destroy(db);
        }
        l.app.gpa.destroy(l);
    }
};

/// Starts reading the desktop entries if nothing has.
pub fn loadApps(self: *App) void {
    if (self.apps_db != null or self.apps_loading) return;
    const l = self.gpa.create(AppsLoad) catch return;
    l.* = .{ .app = self };
    self.apps_loading = true;
    if (c.siv_job_start(self.app, .{}, AppsLoad.work, AppsLoad.done, AppsLoad.destroy, l) != .ok) self.apps_loading = false;
}

/// Queues an open until the application database is loaded; true if it
/// was queued.
pub fn waitForApps(self: *App, win: *Window, paths: []const []const u8, ask: bool) bool {
    if (self.apps_db != null) return false;
    const owned = self.gpa.alloc([]u8, paths.len) catch return true;
    for (paths, 0..) |p, i| owned[i] = self.gpa.dupe(u8, p) catch {
        for (owned[0..i]) |x| self.gpa.free(x);
        self.gpa.free(owned);
        return true;
    };
    self.pending_opens.append(self.gpa, .{ .win = win, .paths = owned, .ask = ask }) catch {
        freePaths(self.gpa, owned);
        return true;
    };
    self.loadApps();
    return true;
}

// Opening -----------------------------------------------------------------------------

/// Opens files with their default applications (mimeapps.list), or
/// `with`, grouped so that each application gets all of its files at
/// once. Files without one ask which to use.
pub fn openPaths(self: *App, win: *Window, paths: []const []const u8, with: ?*const apps.App) void {
    if (self.waitForApps(win, paths, false)) return;
    const db = self.apps_db orelse return self.openWithPortal(win, paths);
    const types = self.loadMimeDb() orelse return self.openWithPortal(win, paths);
    var groups: std.AutoArrayHashMapUnmanaged(*const apps.App, std.ArrayList([]const u8)) = .empty;
    defer {
        for (groups.values()) |*v| v.deinit(self.gpa);
        groups.deinit(self.gpa);
    }
    var orphans: std.ArrayList([]const u8) = .empty;
    defer orphans.deinit(self.gpa);
    for (paths) |p| {
        const app = with orelse db.defaultFor(types, model.typeOfPath(types, p));
        if (app) |a| {
            const gop = groups.getOrPut(self.gpa, a) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(self.gpa, p) catch {};
        } else orphans.append(self.gpa, p) catch {};
    }
    var it = groups.iterator();
    while (it.next()) |kv| self.launch(win, kv.key_ptr.*, kv.value_ptr.items);
    if (orphans.items.len != 0) win.openWithMenu(orphans.items);
}

/// Without desktop entries: the OpenURI portal decides.
fn openWithPortal(self: *App, win: *Window, paths: []const []const u8) void {
    for (paths) |p| {
        var ubuf: std.ArrayList(u8) = .empty;
        defer ubuf.deinit(self.gpa);
        uri.appendFileUri(&ubuf, self.gpa, p) catch return;
        _ = c.siv_open_uri(self.app, win.window, ubuf.items.ptr, ubuf.items.len, .{}, onPortalOpened, null, win);
    }
}

fn onPortalOpened(ud: ?*anyopaque, result: *const siv.PortalResult) callconv(.c) void {
    const win: *Window = @ptrCast(@alignCast(ud.?));
    switch (result.response) {
        .success, .cancelled => {},
        else => win.notify("No application is set to open this file", true),
    }
}

/// A launch waiting for its activation token.
const Launch = struct {
    app: *App,
    arena: std.heap.ArenaAllocator,
    lines: [][]const []const u8,
    cwd: []const u8,
    name: []const u8,

    fn tokenReady(ud: ?*anyopaque, result: *const siv.PortalResult) callconv(.c) void {
        const l: *Launch = @ptrCast(@alignCast(ud.?));
        const token = if (result.token) |t| t[0..result.token_len] else "";
        for (l.lines) |argv| apps.spawn(l.app.gpa, argv, l.cwd, token) catch {
            if (l.app.lastWindow()) |w| {
                var buf: [256]u8 = undefined;
                w.notify(std.fmt.bufPrint(&buf, "Could not start {s}", .{l.name}) catch "Could not start the application", true);
            }
        };
    }

    fn free(ud: ?*anyopaque) callconv(.c) void {
        const l: *Launch = @ptrCast(@alignCast(ud.?));
        const gpa = l.app.gpa;
        l.arena.deinit();
        gpa.destroy(l);
    }
};

/// Starts `app` on `paths`, with an activation token from the window so
/// that it may take focus.
pub fn launch(self: *App, win: *Window, app: *const apps.App, paths: []const []const u8) void {
    const l = self.gpa.create(Launch) catch return;
    l.* = .{ .app = self, .arena = .init(self.gpa), .lines = &.{}, .cwd = "", .name = "" };
    const a = l.arena.allocator();
    l.lines = apps.commandLines(a, app, paths) catch {
        Launch.free(l);
        return;
    };
    l.cwd = a.dupe(u8, if (paths.len > 0) model.parent(paths[0]) else self.home) catch "/";
    l.name = a.dupe(u8, app.name) catch "";
    // siv frees it if the request cannot start.
    _ = c.siv_window_request_activation_token(win.window, Launch.tokenReady, Launch.free, l);
}

// Drives ----------------------------------------------------------------------------------

/// Drives from the mount table: what is mounted where users mount things.
pub fn refreshMountDrives(self: *App) void {
    if (!self.opts.mount_table) return self.setDrives(&.{});
    var table = mounts.read(self.gpa) catch return;
    defer table.deinit();
    _ = self.drives_arena.reset(.retain_capacity);
    const a = self.drives_arena.allocator();
    var drives: std.ArrayList(places_mod.Drive) = .empty;
    for (table.mounts) |m| {
        if (!mounts.isUserDrive(m)) continue;
        drives.append(a, .{
            .id = a.dupe(u8, m.device) catch continue,
            .label = a.dupe(u8, places_mod.basename(m.mount_point)) catch continue,
            .mount_point = a.dupe(u8, m.mount_point) catch continue,
            .icon = places_mod.removable_icon[1..],
        }) catch {};
    }
    self.setDrives(drives.items);
}

/// New drives (from UDisks2 or the mount table).
pub fn setDrives(self: *App, drives: []const places_mod.Drive) void {
    self.places.rebuild(.{ .home = self.opts.home, .config_home = self.opts.config_home, .data_home = self.opts.data_home }, drives) catch return;
    for (self.windows.items) |w| w.drivesChanged();
}

pub fn placesChanged(self: *App) void {
    const drives = self.gpa.dupe(places_mod.Drive, self.places.drives.items) catch return;
    defer self.gpa.free(drives);
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (drives) |*d| {
        d.id = a.dupe(u8, d.id) catch "";
        d.label = a.dupe(u8, d.label) catch "";
        d.mount_point = a.dupe(u8, d.mount_point) catch "";
        d.icon = a.dupe(u8, d.icon) catch "";
    }
    self.setDrives(drives);
}

/// A drive was mounted for `win`: go there.
pub fn driveMounted(self: *App, win: *Window, mount_point: []const u8, new_tab: bool) void {
    _ = self;
    if (new_tab) win.newTab(mount_point) else win.cd(mount_point);
}

/// A drive is about to go away: tabs on it go home.
pub fn leaveMount(self: *App, mount_point: []const u8) void {
    for (self.windows.items) |w| w.leaveMount(mount_point);
}

// zoxide ----------------------------------------------------------------------------------

/// Tells zoxide about a folder the user went to (`zoxide add`), on a
/// worker; each folder once until another is visited.
pub fn zoxideAdd(self: *App, d: *const Dir) void {
    if (!self.zoxide or d.isTrash() or std.mem.eql(u8, d.path, self.zoxide_last.items)) return;
    self.zoxide_last.clearRetainingCapacity();
    self.zoxide_last.appendSlice(self.gpa, d.path) catch return;
    self.runProgram(null, &.{ "zoxide", "add", "--", d.path }, null);
}

/// What a program run by `runProgram` printed, for its window.
pub const ProgramDone = *const fn (win: *Window, status: u8, output: []const u8) void;

/// Runs `argv` on a worker (killed after 10 seconds), then `done` with
/// what it printed if `win` is still open.
pub fn runProgram(self: *App, win: ?*Window, argv: []const []const u8, done: ?ProgramDone) void {
    const gpa = self.gpa;
    const j = gpa.create(ProgramJob) catch return;
    j.* = .{ .app = self, .win = win, .gpa = gpa, .done = done };
    for (argv) |a| {
        const copy = gpa.dupe(u8, a) catch return ProgramJob.destroy(j);
        j.argv.append(gpa, copy) catch {
            gpa.free(copy);
            return ProgramJob.destroy(j);
        };
    }
    // The destroy-notify runs if the job cannot start.
    _ = c.siv_job_start(self.app, .{}, ProgramJob.work, ProgramJob.finish, ProgramJob.destroy, j);
}

const ProgramJob = struct {
    app: *App,
    win: ?*Window,
    gpa: Allocator,
    argv: std.ArrayList([]u8) = .empty,
    done: ?ProgramDone,
    status: u8 = 127,
    output: []u8 = &.{},

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const j: *ProgramJob = @ptrCast(@alignCast(ud.?));
        const r = proc.run(j.gpa, @ptrCast(j.argv.items), .{ .max_output = 1 << 20, .timeout_ms = 10_000 }) catch return;
        j.status = r.status;
        j.output = r.output;
    }

    fn finish(ud: ?*anyopaque) callconv(.c) void {
        const j: *ProgramJob = @ptrCast(@alignCast(ud.?));
        const done = j.done orelse return;
        const w = j.win orelse return;
        // The window may have closed meanwhile.
        for (j.app.windows.items) |x| if (x == w) return done(w, j.status, j.output);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const j: *ProgramJob = @ptrCast(@alignCast(ud.?));
        for (j.argv.items) |a| j.gpa.free(a);
        j.argv.deinit(j.gpa);
        j.gpa.free(j.output);
        j.gpa.destroy(j);
    }
};

/// Keeps a message for `:messages`, dropping the oldest past
/// `max_messages`.
pub fn logMessage(self: *App, text: []const u8, is_error: bool) void {
    if (text.len == 0) return;
    const copy = self.gpa.dupe(u8, text) catch return;
    if (self.messages.items.len >= max_messages) self.gpa.free(self.messages.orderedRemove(0).text);
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    self.messages.append(self.gpa, .{ .time = ts.sec, .is_error = is_error, .text = copy }) catch self.gpa.free(copy);
}

// Bookmarks and history ----------------------------------------------------------------------

fn statePath(self: *App, buf: []u8, name: []const u8) ?[]const u8 {
    const dir = self.opts.state_dir orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch null;
}

fn loadWidths(self: *App) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "columns") orelse return;
    const data = readAll(self.gpa, path) orelse return;
    defer self.gpa.free(data);
    var it = std.mem.tokenizeAny(u8, data, " \n");
    var w: [2]f32 = undefined;
    for (&w) |*x| {
        x.* = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
        if (!(x.* > 0 and x.* < 1)) return;
    }
    if (w[0] + w[1] >= 1) return;
    self.widths = w;
}

/// Sets (or with null, forgets) the chosen column widths, in every window,
/// and keeps them for the next start.
pub fn setWidths(self: *App, w: ?[2]f32) void {
    self.widths = w;
    for (self.windows.items) |win| win.relayout();
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "columns") orelse return;
    if (w) |x| {
        var buf: [64]u8 = undefined;
        writeAll(self.opts.state_dir.?, path, std.fmt.bufPrint(&buf, "{d:.4} {d:.4}\n", .{ x[0], x[1] }) catch return);
    } else {
        var zb: [linux.PATH_MAX]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return;
        _ = linux.unlinkat(linux.AT.FDCWD, z, 0);
    }
}

fn loadChooserSize(self: *App) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "chooser") orelse return;
    const data = readAll(self.gpa, path) orelse return;
    defer self.gpa.free(data);
    self.chooser_size = Config.parseSize(std.mem.trim(u8, data, " \n"));
}

/// The size a new file chooser asks for: the one the user last gave a
/// chooser, else `chooser_size`.
pub fn chooserSize(self: *const App) [2]u32 {
    return self.chooser_size orelse self.options.chooser_size;
}

/// A chooser the user resized: the next one opens at this size.
pub fn rememberChooserSize(self: *App, size: [2]u32) void {
    if (size[0] < 200 or size[1] < 150) return;
    self.chooser_size = size;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "chooser") orelse return;
    var buf: [32]u8 = undefined;
    writeAll(self.opts.state_dir.?, path, std.fmt.bufPrint(&buf, "{d} {d}\n", .{ size[0], size[1] }) catch return);
}

/// `:set chooser_size`: the option wins again.
pub fn forgetChooserSize(self: *App) void {
    self.chooser_size = null;
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "chooser") orelse return;
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return;
    _ = linux.unlinkat(linux.AT.FDCWD, z, 0);
}

fn loadBookmarks(self: *App) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "bookmarks") orelse return;
    const data = readAll(self.gpa, path) orelse return;
    defer self.gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        // "c:/path", the key as UTF-8.
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.unicode.utf8Decode(line[0..colon]) catch continue;
        const p = self.gpa.dupe(u8, line[colon + 1 ..]) catch continue;
        const gop = self.bookmarks.getOrPut(self.gpa, key) catch {
            self.gpa.free(p);
            continue;
        };
        if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = p;
    }
}

fn saveBookmarks(self: *App) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "bookmarks") orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    var it = self.bookmarks.iterator();
    while (it.next()) |kv| {
        var kb: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(kv.key_ptr.*), &kb) catch continue;
        out.appendSlice(self.gpa, kb[0..n]) catch return;
        out.append(self.gpa, ':') catch return;
        out.appendSlice(self.gpa, kv.value_ptr.*) catch return;
        out.append(self.gpa, '\n') catch return;
    }
    writeAll(self.opts.state_dir.?, path, out.items);
}

pub fn setBookmark(self: *App, key: u32, path: []const u8) void {
    const p = self.gpa.dupe(u8, path) catch return;
    const gop = self.bookmarks.getOrPut(self.gpa, key) catch {
        self.gpa.free(p);
        return;
    };
    if (gop.found_existing) self.gpa.free(gop.value_ptr.*);
    gop.value_ptr.* = p;
    self.saveBookmarks();
}

pub fn removeBookmark(self: *App, key: u32) bool {
    const kv = self.bookmarks.fetchOrderedRemove(key) orelse return false;
    self.gpa.free(kv.value);
    self.saveBookmarks();
    return true;
}

fn loadHistory(self: *App) void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "history") orelse return;
    const data = readAll(self.gpa, path) orelse return;
    defer self.gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| if (line.len != 0) {
        self.history.append(self.gpa, self.gpa.dupe(u8, line) catch continue) catch {};
    };
}

pub fn addHistory(self: *App, line: []const u8) void {
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, '\n') != null) return;
    // The latest copy only.
    var i: usize = 0;
    while (i < self.history.items.len) {
        if (std.mem.eql(u8, self.history.items[i], line)) {
            self.gpa.free(self.history.orderedRemove(i));
        } else i += 1;
    }
    self.history.append(self.gpa, self.gpa.dupe(u8, line) catch return) catch return;
    while (self.history.items.len > 200) self.gpa.free(self.history.orderedRemove(0));
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const path = self.statePath(&pbuf, "history") orelse return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    for (self.history.items) |h| {
        out.appendSlice(self.gpa, h) catch return;
        out.append(self.gpa, '\n') catch return;
    }
    writeAll(self.opts.state_dir.?, path, out.items);
}

fn readAll(gpa: Allocator, path: []const u8) ?[]u8 {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch {
            out.deinit(gpa);
            return null;
        };
        if (out.items.len > 4 << 20) break;
    }
    return out.toOwnedSlice(gpa) catch null;
}

/// Writes a file atomically (a temporary beside it, then a rename),
/// making its directory first.
fn writeAll(dir: []const u8, path: []const u8, data: []const u8) void {
    var dbuf: [linux.PATH_MAX]u8 = undefined;
    // mkdir -p of the state directory.
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(&dbuf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = linux.mkdirat(linux.AT.FDCWD, z, 0o700);
        }
    }
    var tbuf: [linux.PATH_MAX]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.tmp", .{path}, 0) catch return;
    const rc = linux.openat(linux.AT.FDCWD, tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        off += n;
    }
    _ = linux.close(fd);
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return;
    _ = linux.renameat(linux.AT.FDCWD, tmp, linux.AT.FDCWD, z);
}

// The register -------------------------------------------------------------------------------

pub fn setRegister(self: *App, paths: []const []const u8, cut: bool) void {
    for (self.register.items) |p| self.gpa.free(p);
    self.register.clearRetainingCapacity();
    for (paths) |p| self.register.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
    self.register_cut = cut;
    for (self.windows.items) |w| w.refreshRows();
}

/// Whether `path` is in the register (rows show it).
pub fn inRegister(self: *const App, path: []const u8) bool {
    for (self.register.items) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

// File operations --------------------------------------------------------------------------

/// A running operation: the window that started it answers its
/// questions and shows its result.
pub const OpEntry = struct {
    app: ?*App,
    win: ?*Window,
    op: *fsops.Op,
    /// Whether to record it for undo (not when it is an undo itself).
    undoable: bool,
    /// A conflict question is showing.
    asking: bool = false,
    sapp: siv.App,

    fn work(ud: ?*anyopaque) callconv(.c) void {
        const e: *OpEntry = @ptrCast(@alignCast(ud.?));
        e.op.run();
    }

    fn done(ud: ?*anyopaque) callconv(.c) void {
        const e: *OpEntry = @ptrCast(@alignCast(ud.?));
        if (e.app) |self| self.opFinished(e);
    }

    fn destroy(ud: ?*anyopaque) callconv(.c) void {
        const e: *OpEntry = @ptrCast(@alignCast(ud.?));
        const gpa = e.op.gpa;
        e.op.destroy();
        gpa.destroy(e);
    }

    /// On the worker: a conflict needs an answer from the UI thread.
    fn ask(ctx: ?*anyopaque, op: *fsops.Op) void {
        const e: *OpEntry = @ptrCast(@alignCast(ctx.?));
        if (c.siv_post(e.sapp, showConflict, null, e) != .ok) op.resolve(.cancel, false);
    }

    fn showConflict(ud: ?*anyopaque) callconv(.c) void {
        const e: *OpEntry = @ptrCast(@alignCast(ud.?));
        const self = e.app orelse return e.op.resolve(.cancel, false);
        const win = e.win orelse self.lastWindow() orelse return e.op.resolve(.cancel, false);
        e.asking = true;
        win.askConflict(e);
        self.updateOps();
    }

    /// The answer, from the window.
    pub fn answer(e: *OpEntry, r: fsops.Resolution, all: bool) void {
        e.asking = false;
        e.op.resolve(r, all);
        if (e.app) |a| a.updateOps();
    }
};

/// Runs a file operation on the worker pool, with progress in every
/// window's status line.
pub fn startOp(self: *App, win: ?*Window, kind: fsops.Kind, sources: []const []const u8, dest: []const u8, targets: []const []const u8, undoable: bool) void {
    self.startOpWith(win, kind, sources, dest, targets, undoable, .none);
}

pub fn startOpWith(self: *App, win: ?*Window, kind: fsops.Kind, sources: []const []const u8, dest: []const u8, targets: []const []const u8, undoable: bool, policy: fsops.Resolution) void {
    const gpa = self.gpa;
    const op = (if (targets.len != 0) fsops.Op.createTargeted(gpa, kind, sources, targets) else fsops.Op.create(gpa, kind, sources, dest)) catch return;
    op.home_trash = gpa.dupe(u8, self.places.trash_dir) catch &.{};
    op.policy = policy;
    self.launchOp(win, op, undoable);
}

/// chmod (`spec`, as chmod(1) takes it) or chown (`uid` and `gid`) on
/// `sources`, into folders when `recursive`.
pub fn startAttrOp(self: *App, win: ?*Window, kind: fsops.Kind, sources: []const []const u8, spec: []const u8, uid: ?u32, gid: ?u32, recursive: bool) void {
    const gpa = self.gpa;
    const op = fsops.Op.create(gpa, kind, sources, "") catch return;
    op.mode_spec = gpa.dupe(u8, spec) catch {
        op.destroy();
        return;
    };
    op.uid = uid;
    op.gid = gid;
    op.recursive = recursive;
    self.launchOp(win, op, false);
}

/// Runs `op` (owned from here) on a blocking worker.
fn launchOp(self: *App, win: ?*Window, op: *fsops.Op, undoable: bool) void {
    const gpa = self.gpa;
    const e = gpa.create(OpEntry) catch {
        op.destroy();
        return;
    };
    e.* = .{ .app = self, .win = win, .op = op, .undoable = undoable, .sapp = self.app };
    op.ask = OpEntry.ask;
    op.ask_ctx = e;
    self.ops.append(gpa, e) catch {
        op.destroy();
        gpa.destroy(e);
        return;
    };
    if (c.siv_job_start(self.app, .{}, OpEntry.work, OpEntry.done, OpEntry.destroy, e) != .ok) {
        _ = self.ops.pop();
        return;
    }
    self.updateOps();
    if (self.ops_timer == .null) _ = c.siv_timer_start(self.app, 100, onOpsTimer, null, self, &self.ops_timer);
}

fn onOpsTimer(ud: ?*anyopaque) callconv(.c) void {
    const self: *App = @ptrCast(@alignCast(ud.?));
    self.ops_timer = .null;
    self.updateOps();
    if (self.ops.items.len != 0) _ = c.siv_timer_start(self.app, 100, onOpsTimer, null, self, &self.ops_timer);
}

pub fn updateOps(self: *App) void {
    for (self.windows.items) |w| {
        w.updateStatus();
        w.refreshTasks();
    }
}

pub fn cancelOps(self: *App) void {
    for (self.ops.items) |e| e.op.requestCancel();
}

fn opFinished(self: *App, e: *OpEntry) void {
    for (self.ops.items, 0..) |o, i| if (o == e) {
        _ = self.ops.orderedRemove(i);
        break;
    };
    e.app = null;
    const op = e.op;
    self.recordFinished(op);
    if (e.undoable and !(if (op.result) |err| err == error.Canceled else false)) self.undo.pushOp(op);
    // A cut is pasted once.
    if (op.kind == .move and self.register_cut) self.setRegister(&.{}, false);
    const win = e.win orelse self.lastWindow();
    if (win) |w| w.opFinished(op, e.undoable);
    self.updateOps();
    // Folders the operation touched read again now (inotify would, a
    // moment later, and not at all without it).
    self.reloadAffected(op);
}

fn recordFinished(self: *App, op: *const fsops.Op) void {
    const gpa = self.gpa;
    var tbuf: [512]u8 = undefined;
    var sbuf: [512]u8 = undefined;
    const msg, const failed = op.summary(&sbuf);
    const canceled = if (op.result) |err| err == error.Canceled else false;
    const title = gpa.dupe(u8, op.title(&tbuf)) catch return;
    const result = gpa.dupe(u8, if (msg.len != 0) msg else "Done") catch {
        gpa.free(title);
        return;
    };
    if (self.recent.items.len >= max_recent) self.removeRecent(self.recent.items.len - 1);
    self.recent.insert(gpa, 0, .{ .title = title, .result = result, .failed = failed, .canceled = canceled }) catch {
        gpa.free(title);
        gpa.free(result);
    };
}

fn reloadAffected(self: *App, op: *const fsops.Op) void {
    if (op.dest.len != 0) self.cache.invalidate(op.dest);
    for (op.sources) |s| self.cache.invalidate(model.parent(s));
    for (op.targets) |t| self.cache.invalidate(model.parent(t));
    if (op.kind == .trash or op.kind == .restore or op.kind == .delete) self.cache.invalidate(self.places.trash_files);
}

// Renames and undo -----------------------------------------------------------------------

/// Renames one file in place, recording it for undo.
pub fn renameOne(self: *App, win: *Window, old_path: []const u8, new_name: []const u8) bool {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const new_path = model.join(&buf, model.parent(old_path), new_name) orelse return false;
    if (!model.validName(new_name)) {
        win.notify("Names cannot be empty or contain “/”", true);
        return false;
    }
    if (std.mem.eql(u8, old_path, new_path)) return true;
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{new_path}, 0) catch return false;
    if (fsops.exists(z)) {
        win.notify("A file with that name already exists", true);
        return false;
    }
    fsops.renamePath(old_path, new_path) catch |err| {
        var mbuf: [512]u8 = undefined;
        win.notify(std.fmt.bufPrint(&mbuf, "Could not rename “{s}”: {s}", .{ model.basename(old_path), fsops.describe(err) }) catch "Could not rename", true);
        return false;
    };
    self.undo.pushRenames(&.{.{ old_path, new_path }});
    self.cache.invalidate(model.parent(old_path));
    return true;
}

/// Renames several files as one undoable step. Renames go through
/// temporary names, so "a"→"b" and "b"→"a" work.
pub fn renameMany(self: *App, win: *Window, pairs: []const [2][]const u8) usize {
    var done: std.ArrayList([2][]const u8) = .empty;
    defer done.deinit(self.gpa);
    var failed: usize = 0;
    var tmp_names: std.ArrayList([]u8) = .empty;
    defer {
        for (tmp_names.items) |t| self.gpa.free(t);
        tmp_names.deinit(self.gpa);
    }
    var staged: std.ArrayList([2][]const u8) = .empty;
    defer staged.deinit(self.gpa);
    for (pairs, 0..) |p, i| {
        if (std.mem.eql(u8, p[0], p[1])) continue;
        var tb: [linux.PATH_MAX]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tb, "{s}/." ++ program ++ "-rename-{d}-{d}", .{ model.parent(p[0]), linux.getpid(), i }) catch continue;
        fsops.renamePath(p[0], tmp) catch {
            failed += 1;
            continue;
        };
        const owned = self.gpa.dupe(u8, tmp) catch continue;
        tmp_names.append(self.gpa, owned) catch {};
        staged.append(self.gpa, .{ owned, p[1] }) catch {};
        done.append(self.gpa, .{ p[0], p[1] }) catch {};
    }
    for (staged.items, 0..) |s, k| {
        var zbuf: [linux.PATH_MAX]u8 = undefined;
        const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{s[1]}, 0) catch continue;
        const taken = fsops.exists(z);
        if (taken) {
            fsops.renamePath(s[0], done.items[k][0]) catch {};
            done.items[k][1] = done.items[k][0];
            failed += 1;
            continue;
        }
        fsops.renamePath(s[0], s[1]) catch {
            // Back under its old name.
            fsops.renamePath(s[0], done.items[k][0]) catch {};
            done.items[k][1] = done.items[k][0];
            failed += 1;
        };
    }
    var effective: std.ArrayList([2][]const u8) = .empty;
    defer effective.deinit(self.gpa);
    for (done.items) |d| if (!std.mem.eql(u8, d[0], d[1])) effective.append(self.gpa, d) catch {};
    self.undo.pushRenames(effective.items);
    for (pairs) |p| self.cache.invalidate(model.parent(p[0]));
    var buf: [128]u8 = undefined;
    if (failed != 0) {
        win.notify(std.fmt.bufPrint(&buf, "{d} items could not be renamed", .{failed}) catch "Some items could not be renamed", true);
    } else if (effective.items.len != 0) {
        win.notify(std.fmt.bufPrint(&buf, "Renamed {d} items", .{effective.items.len}) catch "Renamed", false);
    }
    return effective.items.len;
}

/// Reverses the newest step.
pub fn undoLast(self: *App, win: *Window) void {
    var step = self.undo.pop() orelse {
        win.notify("Nothing to undo", false);
        return;
    };
    defer self.undo.free(&step);
    const gpa = self.gpa;
    var froms: std.ArrayList([]const u8) = .empty;
    defer froms.deinit(gpa);
    var tos: std.ArrayList([]const u8) = .empty;
    defer tos.deinit(gpa);
    for (step.pairs) |p| {
        froms.append(gpa, p.from) catch return;
        tos.append(gpa, p.to) catch return;
    }
    switch (step.kind) {
        .created => {
            fsops.removeEmpty(step.pairs[0].from) catch |err| {
                var buf: [256]u8 = undefined;
                win.notify(std.fmt.bufPrint(&buf, "Could not undo: {s}", .{fsops.describe(err)}) catch "Could not undo", true);
                return;
            };
            self.cache.invalidate(model.parent(step.pairs[0].from));
            win.notify("Undid creating it", false);
        },
        .renamed => {
            var failed = false;
            var i = step.pairs.len;
            while (i > 0) {
                i -= 1;
                const p = step.pairs[i];
                fsops.renamePath(p.to, p.from) catch {
                    failed = true;
                };
                self.cache.invalidate(model.parent(p.from));
            }
            if (failed) win.notify("Some renames could not be undone", true) else win.notify("Undid the rename", false);
            if (step.pairs.len == 1) win.selectAfterLoad(step.pairs[0].from);
        },
        // Copies go to the trash, so that undoing never loses data.
        .copied => self.startOp(win, .trash, tos.items, "", &.{}, false),
        .moved => self.startOp(win, .move_back, tos.items, "", froms.items, false),
        .trashed => self.startOp(win, .restore, tos.items, "", froms.items, false),
        .restored => self.startOp(win, .trash, tos.items, "", &.{}, false),
    }
}

/// Restores trashed files to where they were.
pub fn restoreFromTrash(self: *App, win: *Window, trashed: []const []const u8) void {
    var targets: std.ArrayList([]u8) = .empty;
    defer freePathList(self.gpa, &targets);
    var sources: std.ArrayList([]const u8) = .empty;
    defer sources.deinit(self.gpa);
    for (trashed) |p| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const orig = trash.originalPath(&buf, p) orelse continue;
        targets.append(self.gpa, self.gpa.dupe(u8, orig) catch continue) catch continue;
        sources.append(self.gpa, p) catch {};
    }
    if (sources.items.len == 0) {
        win.notify("These items do not say where they came from", true);
        return;
    }
    const views = self.gpa.alloc([]const u8, targets.items.len) catch return;
    defer self.gpa.free(views);
    for (targets.items, 0..) |t, i| views[i] = t;
    self.startOp(win, .restore, sources.items, "", views, true);
}

/// Deletes everything in every trash.
pub fn emptyTrash(self: *App, win: *Window) void {
    var table = mounts.read(self.gpa) catch return;
    defer table.deinit();
    const mps = table.realMountPoints(self.gpa) catch return;
    defer self.gpa.free(mps);
    const dirs = trash.trashDirs(self.gpa, self.places.trash_dir, mps) catch return;
    defer {
        for (dirs) |d| self.gpa.free(d);
        self.gpa.free(dirs);
    }
    var items: std.ArrayList([]u8) = .empty;
    defer freePathList(self.gpa, &items);
    for (dirs) |dir| for ([_][]const u8{ "files", "info" }) |sub| {
        var buf: [linux.PATH_MAX]u8 = undefined;
        const d = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, sub }, 0) catch continue;
        var it = fsops.DirIter.open(d) catch continue;
        defer it.close();
        while (it.next()) |nm| {
            var pb: [linux.PATH_MAX]u8 = undefined;
            const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ d, nm }) catch continue;
            items.append(self.gpa, self.gpa.dupe(u8, p) catch continue) catch {};
        }
    };
    if (items.items.len == 0) return win.notify("The trash is empty", false);
    const views = self.gpa.alloc([]const u8, items.items.len) catch return;
    defer self.gpa.free(views);
    for (items.items, 0..) |t, i| views[i] = t;
    self.startOp(win, .delete, views, "", &.{}, false);
}
