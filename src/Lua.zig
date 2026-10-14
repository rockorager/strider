//! The Lua configuration: $XDG_CONFIG_HOME/siv-columns/init.lua, run in a
//! Lua 5.5 state from siv's Lua binding (libsiv-lua, linked in). Lua
//! reaches the file manager through require("fm") — keymaps, options,
//! commands, previewers, and events — and siv itself through
//! require("siv"), with the running application from fm.siv_app().

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const siv = @import("siv");
const sl = @import("siv_lua");
pub const lc = sl.c;
pub const lh = sl.helpers;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");
const keys = @import("keys.zig");
const mime = @import("mime.zig");
const commands = @import("commands.zig");
const model = @import("model.zig");

const Lua = @This();
const State = sl.State;

gpa: Allocator,
app: *App,
L: *State,
/// The window a binding, command, or event runs for.
window: ?*Window = null,
user_commands: std.ArrayList(UserCommand) = .empty,
previewers: std.ArrayList(Previewer) = .empty,
handlers: std.ArrayList(Handler) = .empty,

const UserCommand = struct { name: []u8, desc: []u8, ref: c_int };
const Previewer = struct {
    name: ?[]u8 = null,
    mime: ?[]u8 = null,
    match: c_int = lh.noref,
    run: c_int = lh.noref,
    cmd: ?[][]u8 = null,
};
const Handler = struct { event: []u8, ref: c_int };

pub fn create(app: *App) !*Lua {
    const L = sl.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    const self = try app.gpa.create(Lua);
    self.* = .{ .gpa = app.gpa, .app = app, .L = L };
    // require("fm").
    _ = lc.lua_getfield(L, lh.registry, "_PRELOAD");
    lc.lua_pushlightuserdata(L, self);
    lc.lua_pushcclosure(L, openFm, 1);
    lc.lua_setfield(L, -2, "fm");
    lh.pop(L, 1);
    return self;
}

pub fn destroy(self: *Lua) void {
    const gpa = self.gpa;
    lc.lua_close(self.L);
    for (self.user_commands.items) |u| {
        gpa.free(u.name);
        gpa.free(u.desc);
    }
    self.user_commands.deinit(gpa);
    for (self.previewers.items) |p| freePreviewer(gpa, p);
    self.previewers.deinit(gpa);
    for (self.handlers.items) |h| gpa.free(h.event);
    self.handlers.deinit(gpa);
    gpa.destroy(self);
}

fn freePreviewer(gpa: Allocator, p: Previewer) void {
    if (p.name) |n| gpa.free(n);
    if (p.mime) |m| gpa.free(m);
    if (p.cmd) |cmd| {
        for (cmd) |x| gpa.free(x);
        gpa.free(cmd);
    }
}

/// The keymap's release hook: drops a binding's function.
pub fn releaseRef(ctx: ?*anyopaque, ref: c_int) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const self = app.lua orelse return;
    lc.luaL_unref(self.L, lh.registry, ref);
}

fn get(L: *State) *Lua {
    return @ptrCast(@alignCast(lc.lua_touserdata(L, lh.upvalue(1))));
}

fn traceback(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const msg = lc.luaL_tolstring(L, 1, null);
    lc.luaL_traceback(L, L, msg, 1);
    return 1;
}

/// Calls the function under `nargs` arguments in protected mode; reports
/// an error and returns false if it raises.
fn pcall(self: *Lua, nargs: c_int, nresults: c_int) bool {
    const L = self.L;
    const base = lc.lua_gettop(L) - nargs;
    lh.pushcfunction(L, traceback);
    lh.insert(L, base);
    const r = lh.pcall(L, nargs, nresults, base);
    lh.remove(L, base);
    if (r != lh.ok) {
        const msg = lh.toString(L, -1) orelse "error";
        self.report(msg);
        lh.pop(L, 1);
        return false;
    }
    return true;
}

fn report(self: *Lua, msg: []const u8) void {
    // The first line in the status line and a toast; all of it on stderr.
    if (self.app.opts.log_errors) std.debug.print("{s}: {s}\n", .{ App.program, msg });
    const first = msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len];
    if (self.window orelse self.app.lastWindow()) |w| {
        w.notify(first, true);
    } else if (self.app.config_error == null) {
        self.app.config_error = self.gpa.dupe(u8, first) catch null;
    }
}

/// Runs init.lua, if it exists.
pub fn runFile(self: *Lua, path: []const u8) void {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zb, "{s}", .{path}, 0) catch return;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return;
    const L = self.L;
    // Modules beside init.lua: require("plugins.foo") finds lua/plugins/foo.lua too.
    const dir = std.fs.path.dirname(path) orelse ".";
    _ = lc.lua_getglobal(L, "package");
    var pb: [linux.PATH_MAX * 3]u8 = undefined;
    const pp = std.fmt.bufPrintSentinel(&pb, "{s}/?.lua;{s}/?/init.lua;{s}/lua/?.lua;{s}/lua/?/init.lua", .{ dir, dir, dir, dir }, 0) catch "";
    _ = lc.lua_pushstring(L, pp.ptr);
    lc.lua_setfield(L, -2, "path");
    lh.pop(L, 1);
    if (lc.luaL_loadfilex(L, z.ptr, "t") != lh.ok) {
        self.report(lh.toString(L, -1) orelse "init.lua could not be loaded");
        lh.pop(L, 1);
        return;
    }
    _ = self.pcall(0, 0);
}

/// :lua code.
pub fn runString(self: *Lua, win: *Window, code: []const u8) void {
    const L = self.L;
    self.window = win;
    defer self.window = null;
    // An expression prints its value.
    var buf: [4096]u8 = undefined;
    const expr = std.fmt.bufPrint(&buf, "return {s}", .{code}) catch code;
    if (lc.luaL_loadbufferx(L, expr.ptr, expr.len, "=:lua", "t") != lh.ok) {
        lh.pop(L, 1);
        if (lc.luaL_loadbufferx(L, code.ptr, code.len, "=:lua", "t") != lh.ok) {
            self.report(lh.toString(L, -1) orelse "syntax error");
            lh.pop(L, 1);
            return;
        }
    }
    if (!self.pcall(0, 1)) return;
    if (lc.lua_type(L, -1) != lh.tnil) {
        var len: usize = 0;
        const s = lc.luaL_tolstring(L, -1, &len);
        win.notify(s[0..len], false);
        lh.pop(L, 1);
    }
    lh.pop(L, 1);
}

/// A key bound to a Lua function.
pub fn callBinding(self: *Lua, win: *Window, ref: c_int, count: ?u32) void {
    const L = self.L;
    self.window = win;
    defer self.window = null;
    _ = lc.lua_rawgeti(L, lh.registry, ref);
    if (count) |n| lc.lua_pushinteger(L, n) else lc.lua_pushnil(L);
    _ = self.pcall(1, 0);
}

/// A command fm.command defined; false if there is none by that name.
pub fn runCommand(self: *Lua, win: *Window, name: []const u8, args: []const u8, count: ?u32) bool {
    const u = for (self.user_commands.items) |u| {
        if (std.mem.eql(u8, u.name, name)) break u;
    } else return false;
    const L = self.L;
    self.window = win;
    defer self.window = null;
    _ = lc.lua_rawgeti(L, lh.registry, u.ref);
    lh.pushString(L, args);
    if (count) |n| lc.lua_pushinteger(L, n) else lc.lua_pushnil(L);
    _ = self.pcall(2, 0);
    return true;
}

pub fn commandNames(self: *Lua, a: Allocator, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    for (self.user_commands.items) |u| if (std.mem.startsWith(u8, u.name, prefix)) try out.append(a, u.name);
}

pub fn appendCommands(self: *Lua, out: *std.ArrayList(u8)) void {
    if (self.user_commands.items.len == 0) return;
    out.appendSlice(self.gpa, "\nCOMMANDS FROM init.lua\n\n") catch return;
    for (self.user_commands.items) |u| out.print(self.gpa, "  {s: <18} {s}\n", .{ u.name, u.desc }) catch return;
}

/// Tells handlers registered with fm.on about an event.
pub fn emit(self: *Lua, event: []const u8, arg: []const u8) void {
    for (self.handlers.items) |h| {
        if (!std.mem.eql(u8, h.event, event)) continue;
        _ = lc.lua_rawgeti(self.L, lh.registry, h.ref);
        lh.pushString(self.L, arg);
        _ = self.pcall(1, 0);
    }
}

pub const PreviewResult = union(enum) {
    /// Text to show, owned by the caller.
    text: []u8,
    /// A command whose output to show, owned by the caller.
    command: [][]u8,
};

/// What a previewer from init.lua shows for this file, if one matches.
pub fn previewer(self: *Lua, path: []const u8, name: []const u8, type_name: []const u8) ?PreviewResult {
    const L = self.L;
    var i = self.previewers.items.len;
    while (i > 0) {
        i -= 1;
        const p = self.previewers.items[i];
        if (p.name) |pat| if (!mime.globMatch(pat, name)) continue;
        if (p.mime) |m| {
            if (std.mem.endsWith(u8, m, "/*")) {
                if (!std.mem.startsWith(u8, type_name, m[0 .. m.len - 1])) continue;
            } else if (!std.mem.eql(u8, m, type_name)) continue;
        }
        if (p.match != lh.noref) {
            _ = lc.lua_rawgeti(L, lh.registry, p.match);
            lh.pushString(L, path);
            lh.pushString(L, type_name);
            if (!self.pcall(2, 1)) continue;
            const ok = lc.lua_toboolean(L, -1) != 0;
            lh.pop(L, 1);
            if (!ok) continue;
        }
        if (p.cmd) |cmd| {
            const out = self.gpa.alloc([]u8, cmd.len + 1) catch return null;
            var n: usize = 0;
            var had_path = false;
            for (cmd) |arg| {
                if (std.mem.eql(u8, arg, "%s")) {
                    out[n] = self.gpa.dupe(u8, path) catch return null;
                    had_path = true;
                } else out[n] = self.gpa.dupe(u8, arg) catch return null;
                n += 1;
            }
            if (!had_path) {
                out[n] = self.gpa.dupe(u8, path) catch return null;
                n += 1;
            }
            return .{ .command = self.gpa.realloc(out, n) catch out[0..n] };
        }
        if (p.run != lh.noref) {
            _ = lc.lua_rawgeti(L, lh.registry, p.run);
            lh.pushString(L, path);
            lh.pushString(L, type_name);
            if (!self.pcall(2, 1)) continue;
            defer lh.pop(L, 1);
            if (lc.lua_type(L, -1) == lh.tstring) {
                const s = lh.toString(L, -1).?;
                return .{ .text = self.gpa.dupe(u8, s) catch return null };
            }
        }
    }
    return null;
}

// The fm module ----------------------------------------------------------------------------

fn pushFn(L: *State, self: *Lua, f: lh.CFunction) void {
    lc.lua_pushlightuserdata(L, self);
    lc.lua_pushcclosure(L, f, 1);
}

fn openFm(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    lc.lua_createtable(L, 0, 24);
    const fns = [_]struct { [:0]const u8, lh.CFunction }{
        .{ "map", fmMap },
        .{ "unmap", fmUnmap },
        .{ "set", fmSet },
        .{ "get", fmGet },
        .{ "command", fmCommand },
        .{ "exec", fmExec },
        .{ "notify", fmNotify },
        .{ "cwd", fmCwd },
        .{ "hovered", fmHovered },
        .{ "selected", fmSelected },
        .{ "cd", fmCd },
        .{ "previewer", fmPreviewer },
        .{ "on", fmOn },
        .{ "siv_app", fmSivApp },
        .{ "siv_window", fmSivWindow },
        .{ "bookmark", fmBookmark },
    };
    for (fns) |f| {
        pushFn(L, self, f[1]);
        lc.lua_setfield(L, -2, f[0].ptr);
    }
    lh.pushString(L, "0.1.0");
    lc.lua_setfield(L, -2, "version");
    // fm.opt.name = value, as a shorthand for fm.set.
    lh.newtable(L);
    lc.lua_createtable(L, 0, 2);
    pushFn(L, self, optIndex);
    lc.lua_setfield(L, -2, "__index");
    pushFn(L, self, optNewIndex);
    lc.lua_setfield(L, -2, "__newindex");
    _ = lc.lua_setmetatable(L, -2);
    lc.lua_setfield(L, -2, "opt");
    return 1;
}

fn checkString(L: *State, i: c_int) []const u8 {
    var len: usize = 0;
    const p = lc.luaL_checklstring(L, i, &len);
    return p[0..len];
}

fn optString(L: *State, i: c_int) ?[]const u8 {
    if (lh.isnoneornil(L, i)) return null;
    return checkString(L, i);
}

fn modesOf(L: *State, i: c_int, out: *[2]keys.Mode) []keys.Mode {
    if (lc.lua_type(L, i) == lh.ttable) {
        var n: usize = 0;
        const len = lc.luaL_len(L, i);
        var k: c_int = 1;
        while (k <= len and n < 2) : (k += 1) {
            _ = lc.lua_rawgeti(L, i, k);
            const s = lh.toString(L, -1) orelse "";
            if (keys.Mode.parse(s)) |m| {
                out[n] = m;
                n += 1;
            } else lh.raise(L, "unknown mode '{s}' (n or v)", .{s});
            lh.pop(L, 1);
        }
        return out[0..n];
    }
    const s = checkString(L, i);
    out[0] = keys.Mode.parse(s) orelse lh.raise(L, "unknown mode '{s}' (n or v)", .{s});
    return out[0..1];
}

/// fm.map(mode, keys, command_or_function [, description])
fn fmMap(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    var mbuf: [2]keys.Mode = undefined;
    const modes = modesOf(L, 1, &mbuf);
    const spec = checkString(L, 2);
    const desc = optString(L, 4) orelse "";
    for (modes) |mode| {
        const action: keys.Action = switch (lc.lua_type(L, 3)) {
            lh.tstring => .{ .command = lh.toString(L, 3).? },
            lh.tfunction => blk: {
                lc.lua_pushvalue(L, 3);
                break :blk .{ .lua = lc.luaL_ref(L, lh.registry) };
            },
            else => lh.argError(L, 3, "a command string or a function", .{}),
        };
        self.app.keymap.map(mode, spec, action, desc) catch |err| {
            if (action == .lua) lc.luaL_unref(L, lh.registry, action.lua);
            lh.raise(L, "fm.map: cannot bind '{s}': {s}", .{ spec, @errorName(err) });
        };
    }
    return 0;
}

/// fm.unmap(mode, keys): true if it was bound.
fn fmUnmap(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    var mbuf: [2]keys.Mode = undefined;
    const modes = modesOf(L, 1, &mbuf);
    const spec = checkString(L, 2);
    var any = false;
    for (modes) |mode| any = (self.app.keymap.unmap(mode, spec) catch false) or any;
    lc.lua_pushboolean(L, @intFromBool(any));
    return 1;
}

fn setOption(L: *State, self: *Lua, name: []const u8, vi: c_int) void {
    const info = Config.info(name) orelse lh.raise(L, "unknown option '{s}'", .{name});
    const o = &self.app.options;
    switch (info.kind) {
        .boolean => Config.setBool(o, name, lc.lua_toboolean(L, vi) != 0),
        .number => {
            const n = lc.luaL_checkinteger(L, vi);
            if (n < 0) lh.argError(L, vi, "a number of zero or more", .{});
            Config.setNumber(o, name, @intCast(@min(n, std.math.maxInt(u32))));
        },
        .string => Config.setString(o, &self.app.strings, name, checkString(L, vi)) catch lh.raise(L, "out of memory", .{}),
        .sort => {
            const s = checkString(L, vi);
            o.sort.key = Config.parseSortKey(s) orelse lh.raise(L, "unknown sort '{s}'", .{s});
        },
        .ratio => {
            lc.luaL_checktype(L, vi, lh.ttable);
            var r: [3]f32 = undefined;
            for (&r, 1..) |*x, k| {
                _ = lc.lua_rawgeti(L, vi, @intCast(k));
                x.* = @floatCast(lc.luaL_checknumber(L, -1));
                lh.pop(L, 1);
            }
            o.ratio = r;
        },
    }
    self.app.applyViewOptions();
}

fn pushOption(L: *State, self: *Lua, name: []const u8) c_int {
    const info = Config.info(name) orelse return 0;
    const o = &self.app.options;
    switch (info.kind) {
        .boolean => lc.lua_pushboolean(L, @intFromBool(Config.getBool(o, name).?)),
        .number => lc.lua_pushinteger(L, Config.getNumber(o, name).?),
        .string, .sort => lh.pushString(L, Config.getString(o, name).?),
        .ratio => {
            lc.lua_createtable(L, 3, 0);
            for (o.ratio, 1..) |x, k| {
                lc.lua_pushnumber(L, x);
                lc.lua_rawseti(L, -2, @intCast(k));
            }
        },
    }
    return 1;
}

/// fm.set(name, value), or fm.set{ name = value, ... }
fn fmSet(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    if (lc.lua_type(L, 1) == lh.ttable) {
        lc.lua_pushnil(L);
        while (lc.lua_next(L, 1) != 0) {
            const k = lh.toString(L, -2) orelse lh.raise(L, "option names are strings", .{});
            setOption(L, self, k, lc.lua_gettop(L));
            lh.pop(L, 1);
        }
        return 0;
    }
    setOption(L, self, checkString(L, 1), 2);
    return 0;
}

fn fmGet(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    return pushOption(L, get(L), checkString(L, 1));
}

fn optIndex(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    return pushOption(L, get(L), checkString(L, 2));
}

fn optNewIndex(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    setOption(L, get(L), checkString(L, 2), 3);
    return 0;
}

/// fm.command(name, function(args, count) ... end [, description])
fn fmCommand(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const name = checkString(L, 1);
    lc.luaL_checktype(L, 2, lh.tfunction);
    const desc = optString(L, 3) orelse "";
    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lh.registry);
    for (self.user_commands.items) |*u| if (std.mem.eql(u8, u.name, name)) {
        lc.luaL_unref(L, lh.registry, u.ref);
        u.ref = ref;
        return 0;
    };
    const n = self.gpa.dupe(u8, name) catch lh.raise(L, "out of memory", .{});
    const d = self.gpa.dupe(u8, desc) catch lh.raise(L, "out of memory", .{});
    self.user_commands.append(self.gpa, .{ .name = n, .desc = d, .ref = ref }) catch lh.raise(L, "out of memory", .{});
    return 0;
}

/// fm.exec(command_line [, count])
fn fmExec(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const line = checkString(L, 1);
    const count: ?u32 = if (lh.isnoneornil(L, 2)) null else @intCast(@max(0, lc.luaL_checkinteger(L, 2)));
    const w = self.windowOf(L) orelse lh.raise(L, "fm.exec: no window", .{});
    var buf: [4096]u8 = undefined;
    if (line.len > buf.len) lh.raise(L, "fm.exec: the line is too long", .{});
    @memcpy(buf[0..line.len], line);
    commands.execute(w, buf[0..line.len], count, false);
    return 0;
}

/// fm.notify(message [, "error"])
fn fmNotify(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    var len: usize = 0;
    const p = lc.luaL_tolstring(L, 1, &len);
    const level = optString(L, 2) orelse "";
    if (self.windowOf(L)) |w| w.notify(p[0..len], std.mem.eql(u8, level, "error"));
    return 0;
}

fn fmCwd(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const w = get(L).windowOf(L) orelse return 0;
    lh.pushString(L, w.curDir().path);
    return 1;
}

fn fmHovered(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const w = get(L).windowOf(L) orelse return 0;
    const d = w.curDir();
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, d.cursor) orelse return 0;
    lh.pushString(L, p);
    return 1;
}

/// fm.selected(): what commands act on — the visual range, the marks, or
/// the entry under the cursor — as a list of paths.
fn fmSelected(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const w = self.windowOf(L) orelse return 0;
    const paths = w.targets() catch return 0;
    defer App.freePaths(self.gpa, paths);
    lc.lua_createtable(L, @intCast(paths.len), 0);
    for (paths, 1..) |p, i| {
        lh.pushString(L, p);
        lc.lua_rawseti(L, -2, @intCast(i));
    }
    return 1;
}

fn fmCd(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const w = get(L).windowOf(L) orelse lh.raise(L, "fm.cd: no window", .{});
    w.cd(checkString(L, 1));
    return 0;
}

/// fm.bookmark(key, path): sets a bookmark.
fn fmBookmark(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const k = checkString(L, 1);
    const path = checkString(L, 2);
    const len = std.unicode.utf8ByteSequenceLength(k[0]) catch lh.argError(L, 1, "a key", .{});
    const code = std.unicode.utf8Decode(k[0..@min(len, k.len)]) catch lh.argError(L, 1, "a key", .{});
    self.app.setBookmark(code, path);
    return 0;
}

/// fm.previewer{ name = "*.csv", mime = "text/csv", match = fn,
/// run = function(path, mime) return text end, cmd = { "prog", "%s" } }
fn fmPreviewer(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    lc.luaL_checktype(L, 1, lh.ttable);
    var p: Previewer = .{};
    errdefer freePreviewer(self.gpa, p);
    if (lc.lua_getfield(L, 1, "name") == lh.tstring) p.name = self.gpa.dupe(u8, lh.toString(L, -1).?) catch null;
    lh.pop(L, 1);
    if (lc.lua_getfield(L, 1, "mime") == lh.tstring) p.mime = self.gpa.dupe(u8, lh.toString(L, -1).?) catch null;
    lh.pop(L, 1);
    if (lc.lua_getfield(L, 1, "match") == lh.tfunction) p.match = lc.luaL_ref(L, lh.registry) else lh.pop(L, 1);
    if (lc.lua_getfield(L, 1, "run") == lh.tfunction) p.run = lc.luaL_ref(L, lh.registry) else lh.pop(L, 1);
    if (lc.lua_getfield(L, 1, "cmd") == lh.ttable) {
        const n: usize = @intCast(lc.luaL_len(L, -1));
        const cmd = self.gpa.alloc([]u8, n) catch lh.raise(L, "out of memory", .{});
        for (cmd, 1..) |*x, k| {
            _ = lc.lua_rawgeti(L, -1, @intCast(k));
            x.* = self.gpa.dupe(u8, lh.toString(L, -1) orelse "") catch "";
            lh.pop(L, 1);
        }
        p.cmd = cmd;
    }
    lh.pop(L, 1);
    if (p.run == lh.noref and p.cmd == null) lh.raise(L, "fm.previewer needs run or cmd", .{});
    self.previewers.append(self.gpa, p) catch lh.raise(L, "out of memory", .{});
    return 0;
}

/// fm.on(event, function(arg) ... end): "cd" (the new folder).
fn fmOn(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const ev = checkString(L, 1);
    lc.luaL_checktype(L, 2, lh.tfunction);
    lc.lua_pushvalue(L, 2);
    const ref = lc.luaL_ref(L, lh.registry);
    const e = self.gpa.dupe(u8, ev) catch lh.raise(L, "out of memory", .{});
    self.handlers.append(self.gpa, .{ .event = e, .ref = ref }) catch lh.raise(L, "out of memory", .{});
    return 0;
}

/// fm.siv_app(): the running siv application, for siv's Lua API
/// (timers, jobs, notifications, D-Bus, ...).
fn fmSivApp(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    _ = sl.siv_lua_push_handle(L, "app", @intFromEnum(self.app.app));
    return 1;
}

/// fm.siv_window(): the current window's siv window.
fn fmSivWindow(Lq: ?*State) callconv(.c) c_int {
    const L = Lq.?;
    const self = get(L);
    const w = self.windowOf(L) orelse return 0;
    _ = sl.siv_lua_push_handle(L, "window", @intFromEnum(w.window));
    return 1;
}

fn windowOf(self: *Lua, _: *State) ?*Window {
    return self.window orelse self.app.lastWindow();
}
