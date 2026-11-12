//! The Lua configuration: $XDG_CONFIG_HOME/strider/init.lua, run in a
//! Lua 5.5 state from siv's Lua binding (libsiv-lua, linked in). Lua
//! reaches the file manager through require("strider") — keymaps, options,
//! commands, previewers, and events — and siv itself through
//! require("siv"), with the running application from strider.siv_app().

const std = @import("std");
const print = std.debug.print;
const Io = std.Io;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const sl = @import("siv_lua");
pub const lc = sl.c;
pub const lh = sl.helpers;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");
const keys = @import("keys.zig");
const mime = @import("mime.zig");
const commands = @import("commands.zig");

const Lua = @This();
const State = sl.State;

gpa: Allocator,
app: *App,
state: *State,
/// The window a binding, command, or event runs for.
window: ?*Window,
user_commands: std.ArrayList(UserCommand),
previewers: std.ArrayList(Previewer),
handlers: std.ArrayList(Handler),

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
    const state = sl.siv_lua_new(~@as(c_int, 0)) orelse return error.OutOfMemory;
    const self = try app.gpa.create(Lua);
    self.* = .{
        .gpa = app.gpa,
        .app = app,
        .state = state,
        .window = null,
        .user_commands = .empty,
        .previewers = .empty,
        .handlers = .empty,
    };
    // require("strider").
    _ = lc.lua_getfield(state, lh.registry, "_PRELOAD");
    lc.lua_pushlightuserdata(state, self);
    lc.lua_pushcclosure(state, openStrider, 1);
    lc.lua_setfield(state, -2, "strider");
    lh.pop(state, 1);
    return self;
}

pub fn destroy(self: *Lua) void {
    const gpa = self.gpa;
    lc.lua_close(self.state);
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
    lc.luaL_unref(self.state, lh.registry, ref);
}

fn get(state: *State) *Lua {
    return @ptrCast(@alignCast(lc.lua_touserdata(state, lh.upvalue(1))));
}

fn traceback(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const msg = lc.luaL_tolstring(state, 1, null);
    lc.luaL_traceback(state, state, msg, 1);
    return 1;
}

/// Calls the function under `nargs` arguments in protected mode; reports
/// an error and returns false if it raises.
fn pcall(self: *Lua, nargs: c_int, nresults: c_int) bool {
    const state = self.state;
    const base = lc.lua_gettop(state) - nargs;
    lh.pushcfunction(state, traceback);
    lh.insert(state, base);
    const r = lh.pcall(state, nargs, nresults, base);
    lh.remove(state, base);
    if (r != lh.ok) {
        const msg = lh.toString(state, -1) orelse "error";
        self.report(msg);
        lh.pop(state, 1);
        return false;
    }
    return true;
}

fn report(self: *Lua, msg: []const u8) void {
    // The first line in the status line and a toast; all of it on stderr.
    if (self.app.opts.log_errors) print("{s}: {s}\n", .{ App.program, msg });
    const first = msg[0 .. std.mem.findScalar(u8, msg, '\n') orelse msg.len];
    if (self.window orelse self.app.lastWindow()) |w| {
        w.notify(first, true);
    } else if (self.app.config_error == null) {
        self.app.config_error = self.gpa.dupe(u8, first) catch null;
    }
}

/// Runs init.lua, if it exists.
pub fn runFile(self: *Lua, path: []const u8) void {
    var zb: [linux.PATH_MAX]u8 = undefined;
    const z = std.mem.printSentinel(&zb, "{s}", .{path}, 0) catch return;
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .TYPE = true }, &st)) != .SUCCESS) return;
    const state = self.state;
    // Modules beside init.lua: require("plugins.foo") finds lua/plugins/foo.lua too.
    const dir = Io.Dir.path.dirname(path) orelse ".";
    _ = lc.lua_getglobal(state, "package");
    var pb: [linux.PATH_MAX * 3]u8 = undefined;
    const pp = std.mem.printSentinel(
        &pb,
        "{s}/?.lua;{s}/?/init.lua;{s}/lua/?.lua;{s}/lua/?/init.lua",
        .{ dir, dir, dir, dir },
        0,
    ) catch "";
    _ = lc.lua_pushstring(state, pp.ptr);
    lc.lua_setfield(state, -2, "path");
    lh.pop(state, 1);
    if (lc.luaL_loadfilex(state, z.ptr, "t") != lh.ok) {
        self.report(lh.toString(state, -1) orelse "init.lua could not be loaded");
        lh.pop(state, 1);
        return;
    }
    _ = self.pcall(0, 0);
}

/// :lua code.
pub fn runString(self: *Lua, win: *Window, code: []const u8) void {
    const state = self.state;
    self.window = win;
    defer self.window = null;
    // An expression prints its value.
    var buf: [4096]u8 = undefined;
    const expr = std.mem.print(&buf, "return {s}", .{code}) catch code;
    if (lc.luaL_loadbufferx(state, expr.ptr, expr.len, "=:lua", "t") != lh.ok) {
        lh.pop(state, 1);
        if (lc.luaL_loadbufferx(state, code.ptr, code.len, "=:lua", "t") != lh.ok) {
            self.report(lh.toString(state, -1) orelse "syntax error");
            lh.pop(state, 1);
            return;
        }
    }
    if (!self.pcall(0, 1)) return;
    if (lc.lua_type(state, -1) != lh.tnil) {
        var len: usize = 0;
        const s = lc.luaL_tolstring(state, -1, &len);
        win.notify(s[0..len], false);
        lh.pop(state, 1);
    }
    lh.pop(state, 1);
}

/// A key bound to a Lua function.
pub fn callBinding(self: *Lua, win: *Window, ref: c_int, count: ?u32) void {
    const state = self.state;
    self.window = win;
    defer self.window = null;
    _ = lc.lua_rawgeti(state, lh.registry, ref);
    if (count) |n| lc.lua_pushinteger(state, n) else lc.lua_pushnil(state);
    _ = self.pcall(1, 0);
}

/// A command strider.command defined; false if there is none by that name.
pub fn runCommand(self: *Lua, win: *Window, name: []const u8, args: []const u8, count: ?u32) bool {
    const u = for (self.user_commands.items) |u| {
        if (std.mem.eql(u8, u.name, name)) break u;
    } else return false;
    const state = self.state;
    self.window = win;
    defer self.window = null;
    _ = lc.lua_rawgeti(state, lh.registry, u.ref);
    lh.pushString(state, args);
    if (count) |n| lc.lua_pushinteger(state, n) else lc.lua_pushnil(state);
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

/// Tells handlers registered with strider.on about an event.
pub fn emit(self: *Lua, event: []const u8, arg: []const u8) void {
    for (self.handlers.items) |h| {
        if (!std.mem.eql(u8, h.event, event)) continue;
        _ = lc.lua_rawgeti(self.state, lh.registry, h.ref);
        lh.pushString(self.state, arg);
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
    const state = self.state;
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
            _ = lc.lua_rawgeti(state, lh.registry, p.match);
            lh.pushString(state, path);
            lh.pushString(state, type_name);
            if (!self.pcall(2, 1)) continue;
            const ok = lc.lua_toboolean(state, -1) != 0;
            lh.pop(state, 1);
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
            _ = lc.lua_rawgeti(state, lh.registry, p.run);
            lh.pushString(state, path);
            lh.pushString(state, type_name);
            if (!self.pcall(2, 1)) continue;
            defer lh.pop(state, 1);
            if (lc.lua_type(state, -1) == lh.tstring) {
                const s = lh.toString(state, -1).?;
                return .{ .text = self.gpa.dupe(u8, s) catch return null };
            }
        }
    }
    return null;
}

// The strider module ----------------------------------------------------------------------------

fn pushFn(state: *State, self: *Lua, f: lh.CFunction) void {
    lc.lua_pushlightuserdata(state, self);
    lc.lua_pushcclosure(state, f, 1);
}

fn openStrider(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    lc.lua_createtable(state, 0, 24);
    const fns = [_]struct { [:0]const u8, lh.CFunction }{
        .{ "map", striderMap },
        .{ "unmap", striderUnmap },
        .{ "set", striderSet },
        .{ "get", striderGet },
        .{ "command", striderCommand },
        .{ "exec", striderExec },
        .{ "notify", striderNotify },
        .{ "cwd", striderCwd },
        .{ "hovered", striderHovered },
        .{ "selected", striderSelected },
        .{ "cd", striderCd },
        .{ "previewer", striderPreviewer },
        .{ "on", striderOn },
        .{ "siv_app", striderSivApp },
        .{ "siv_window", striderSivWindow },
        .{ "bookmark", striderBookmark },
    };
    for (fns) |f| {
        pushFn(state, self, f[1]);
        lc.lua_setfield(state, -2, f[0].ptr);
    }
    lh.pushString(state, "0.1.0");
    lc.lua_setfield(state, -2, "version");
    // strider.opt.name = value, as a shorthand for strider.set.
    lh.newtable(state);
    lc.lua_createtable(state, 0, 2);
    pushFn(state, self, optIndex);
    lc.lua_setfield(state, -2, "__index");
    pushFn(state, self, optNewIndex);
    lc.lua_setfield(state, -2, "__newindex");
    _ = lc.lua_setmetatable(state, -2);
    lc.lua_setfield(state, -2, "opt");
    return 1;
}

fn checkString(state: *State, i: c_int) []const u8 {
    var len: usize = 0;
    const p = lc.luaL_checklstring(state, i, &len);
    return p[0..len];
}

fn optString(state: *State, i: c_int) ?[]const u8 {
    if (lh.isnoneornil(state, i)) return null;
    return checkString(state, i);
}

fn modesOf(state: *State, i: c_int, out: *[3]keys.Mode) []keys.Mode {
    if (lc.lua_type(state, i) == lh.ttable) {
        var n: usize = 0;
        const len = lc.luaL_len(state, i);
        var k: c_int = 1;
        while (k <= len and n < 3) : (k += 1) {
            _ = lc.lua_rawgeti(state, i, k);
            const s = lh.toString(state, -1) orelse "";
            if (keys.Mode.parse(s)) |m| {
                out[n] = m;
                n += 1;
            } else lh.raise(state, "unknown mode '{s}' (n, v, or t)", .{s});
            lh.pop(state, 1);
        }
        return out[0..n];
    }
    const s = checkString(state, i);
    out[0] = keys.Mode.parse(s) orelse lh.raise(state, "unknown mode '{s}' (n, v, or t)", .{s});
    return out[0..1];
}

/// strider.map(mode, keys, command_or_function [, description])
fn striderMap(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    var mbuf: [3]keys.Mode = undefined;
    const modes = modesOf(state, 1, &mbuf);
    const spec = checkString(state, 2);
    const desc = optString(state, 4) orelse "";
    for (modes) |mode| {
        const action: keys.Action = switch (lc.lua_type(state, 3)) {
            lh.tstring => .{ .command = lh.toString(state, 3).? },
            lh.tfunction => blk: {
                lc.lua_pushvalue(state, 3);
                break :blk .{ .lua = lc.luaL_ref(state, lh.registry) };
            },
            else => lh.argError(state, 3, "a command string or a function", .{}),
        };
        self.app.keymap.map(mode, spec, action, desc) catch |err| {
            if (action == .lua) lc.luaL_unref(state, lh.registry, action.lua);
            lh.raise(state, "strider.map: cannot bind '{s}': {s}", .{ spec, @errorName(err) });
        };
    }
    return 0;
}

/// strider.unmap(mode, keys): true if it was bound.
fn striderUnmap(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    var mbuf: [3]keys.Mode = undefined;
    const modes = modesOf(state, 1, &mbuf);
    const spec = checkString(state, 2);
    var any = false;
    for (modes) |mode| any = (self.app.keymap.unmap(mode, spec) catch false) or any;
    lc.lua_pushboolean(state, @intFromBool(any));
    return 1;
}

fn setOption(state: *State, self: *Lua, name: []const u8, vi: c_int) void {
    const info = Config.info(name) orelse lh.raise(state, "unknown option '{s}'", .{name});
    const o = &self.app.options;
    switch (info.kind) {
        .boolean => Config.setBool(o, name, lc.lua_toboolean(state, vi) != 0),
        .number => {
            const n = lc.luaL_checkinteger(state, vi);
            if (n < 0) lh.argError(state, vi, "a number of zero or more", .{});
            Config.setNumber(o, name, @intCast(@min(n, std.math.maxInt(u32))));
        },
        .string => Config.setString(
            o,
            &self.app.strings,
            name,
            checkString(state, vi),
        ) catch lh.raise(state, "out of memory", .{}),
        .sort => {
            const s = checkString(state, vi);
            o.sort.key = Config.parseSortKey(s) orelse lh.raise(state, "unknown sort '{s}'", .{s});
        },
        .ratio => {
            lc.luaL_checktype(state, vi, lh.ttable);
            var r: [3]f32 = undefined;
            for (&r, 1..) |*x, k| {
                _ = lc.lua_rawgeti(state, vi, @intCast(k));
                x.* = @floatCast(lc.luaL_checknumber(state, -1));
                lh.pop(state, 1);
            }
            o.ratio = r;
        },
        .size => {
            lc.luaL_checktype(state, vi, lh.ttable);
            var sz: [2]u32 = undefined;
            for (&sz, 1..) |*x, k| {
                _ = lc.lua_rawgeti(state, vi, @intCast(k));
                const n = lc.luaL_checkinteger(state, -1);
                lh.pop(state, 1);
                if (n < (if (k == 1) @as(i64, 200) else 150)) {
                    lh.argError(state, vi, "a width of 200 or more and a height of 150 or more", .{});
                }
                x.* = @intCast(@min(n, 100_000));
            }
            o.chooser_size = sz;
        },
    }
    self.app.applyViewOptions();
}

fn pushOption(state: *State, self: *Lua, name: []const u8) c_int {
    const info = Config.info(name) orelse return 0;
    const o = &self.app.options;
    switch (info.kind) {
        .boolean => lc.lua_pushboolean(state, @intFromBool(Config.getBool(o, name).?)),
        .number => lc.lua_pushinteger(state, Config.getNumber(o, name).?),
        .string, .sort => lh.pushString(state, Config.getString(o, name).?),
        .ratio => {
            lc.lua_createtable(state, 3, 0);
            for (o.ratio, 1..) |x, k| {
                lc.lua_pushnumber(state, x);
                lc.lua_rawseti(state, -2, @intCast(k));
            }
        },
        .size => {
            lc.lua_createtable(state, 2, 0);
            for (o.chooser_size, 1..) |x, k| {
                lc.lua_pushinteger(state, x);
                lc.lua_rawseti(state, -2, @intCast(k));
            }
        },
    }
    return 1;
}

/// strider.set(name, value), or strider.set{ name = value, ... }
fn striderSet(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    if (lc.lua_type(state, 1) == lh.ttable) {
        lc.lua_pushnil(state);
        while (lc.lua_next(state, 1) != 0) {
            const k = lh.toString(state, -2) orelse lh.raise(state, "option names are strings", .{});
            setOption(state, self, k, lc.lua_gettop(state));
            lh.pop(state, 1);
        }
        return 0;
    }
    setOption(state, self, checkString(state, 1), 2);
    return 0;
}

fn striderGet(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    return pushOption(state, get(state), checkString(state, 1));
}

fn optIndex(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    return pushOption(state, get(state), checkString(state, 2));
}

fn optNewIndex(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    setOption(state, get(state), checkString(state, 2), 3);
    return 0;
}

/// strider.command(name, function(args, count) ... end [, description])
fn striderCommand(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const name = checkString(state, 1);
    lc.luaL_checktype(state, 2, lh.tfunction);
    const desc = optString(state, 3) orelse "";
    lc.lua_pushvalue(state, 2);
    const ref = lc.luaL_ref(state, lh.registry);
    for (self.user_commands.items) |*u| if (std.mem.eql(u8, u.name, name)) {
        lc.luaL_unref(state, lh.registry, u.ref);
        u.ref = ref;
        return 0;
    };
    const n = self.gpa.dupe(u8, name) catch lh.raise(state, "out of memory", .{});
    const d = self.gpa.dupe(u8, desc) catch lh.raise(state, "out of memory", .{});
    self.user_commands.append(self.gpa, .{
        .name = n,
        .desc = d,
        .ref = ref,
    }) catch lh.raise(state, "out of memory", .{});
    return 0;
}

/// strider.exec(command_line [, count])
fn striderExec(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const line = checkString(state, 1);
    const count: ?u32 = if (lh.isnoneornil(state, 2)) null else @intCast(@max(0, lc.luaL_checkinteger(state, 2)));
    const w = self.windowOf(state) orelse lh.raise(state, "strider.exec: no window", .{});
    var buf: [4096]u8 = undefined;
    if (line.len > buf.len) lh.raise(state, "strider.exec: the line is too long", .{});
    @memcpy(buf[0..line.len], line);
    commands.execute(w, buf[0..line.len], count, false);
    return 0;
}

/// strider.notify(message [, "error"])
fn striderNotify(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    var len: usize = 0;
    const p = lc.luaL_tolstring(state, 1, &len);
    const level = optString(state, 2) orelse "";
    if (self.windowOf(state)) |w| w.notify(p[0..len], std.mem.eql(u8, level, "error"));
    return 0;
}

fn striderCwd(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const w = get(state).windowOf(state) orelse return 0;
    lh.pushString(state, w.curDir().path);
    return 1;
}

fn striderHovered(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const w = get(state).windowOf(state) orelse return 0;
    const d = w.curDir();
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = d.pathAt(&pbuf, d.cursor) orelse return 0;
    lh.pushString(state, p);
    return 1;
}

/// strider.selected(): what commands act on — the visual range, the marks, or
/// the entry under the cursor — as a list of paths.
fn striderSelected(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const w = self.windowOf(state) orelse return 0;
    const paths = w.targets() catch return 0;
    defer App.freePaths(self.gpa, paths);
    lc.lua_createtable(state, @intCast(paths.len), 0);
    for (paths, 1..) |p, i| {
        lh.pushString(state, p);
        lc.lua_rawseti(state, -2, @intCast(i));
    }
    return 1;
}

fn striderCd(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const w = get(state).windowOf(state) orelse lh.raise(state, "strider.cd: no window", .{});
    w.cd(checkString(state, 1));
    return 0;
}

/// strider.bookmark(key, path): sets a bookmark.
fn striderBookmark(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const k = checkString(state, 1);
    const path = checkString(state, 2);
    const d = keys.decodeFirst(k) orelse lh.argError(state, 1, "a key", .{});
    if (d.len != k.len) lh.argError(state, 1, "a key", .{});
    self.app.setBookmark(d.cp, path);
    return 0;
}

/// strider.previewer{ name = "*.csv", mime = "text/csv", match = fn,
/// run = function(path, mime) return text end, cmd = { "prog", "%s" } }
fn striderPreviewer(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    lc.luaL_checktype(state, 1, lh.ttable);
    var p: Previewer = .{};
    errdefer freePreviewer(self.gpa, p);
    if (lc.lua_getfield(state, 1, "name") == lh.tstring) {
        p.name = self.gpa.dupe(u8, lh.toString(state, -1).?) catch null;
    }
    lh.pop(state, 1);
    if (lc.lua_getfield(state, 1, "mime") == lh.tstring) {
        p.mime = self.gpa.dupe(u8, lh.toString(state, -1).?) catch null;
    }
    lh.pop(state, 1);
    if (lc.lua_getfield(state, 1, "match") == lh.tfunction) {
        p.match = lc.luaL_ref(state, lh.registry);
    } else {
        lh.pop(state, 1);
    }
    if (lc.lua_getfield(state, 1, "run") == lh.tfunction) p.run = lc.luaL_ref(state, lh.registry) else lh.pop(state, 1);
    if (lc.lua_getfield(state, 1, "cmd") == lh.ttable) {
        const n: usize = @intCast(lc.luaL_len(state, -1));
        const cmd = self.gpa.alloc([]u8, n) catch lh.raise(state, "out of memory", .{});
        for (cmd, 1..) |*x, k| {
            _ = lc.lua_rawgeti(state, -1, @intCast(k));
            x.* = self.gpa.dupe(u8, lh.toString(state, -1) orelse "") catch "";
            lh.pop(state, 1);
        }
        p.cmd = cmd;
    }
    lh.pop(state, 1);
    if (p.run == lh.noref and p.cmd == null) lh.raise(state, "strider.previewer needs run or cmd", .{});
    self.previewers.append(self.gpa, p) catch lh.raise(state, "out of memory", .{});
    return 0;
}

/// strider.on(event, function(arg) ... end): "cd" (the new folder).
fn striderOn(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const ev = checkString(state, 1);
    lc.luaL_checktype(state, 2, lh.tfunction);
    lc.lua_pushvalue(state, 2);
    const ref = lc.luaL_ref(state, lh.registry);
    const e = self.gpa.dupe(u8, ev) catch lh.raise(state, "out of memory", .{});
    self.handlers.append(self.gpa, .{ .event = e, .ref = ref }) catch lh.raise(state, "out of memory", .{});
    return 0;
}

/// strider.siv_app(): the running siv application, for siv's Lua API
/// (timers, jobs, notifications, D-Bus, ...).
fn striderSivApp(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    _ = sl.siv_lua_push_handle(state, "app", @backingInt(self.app.app));
    return 1;
}

/// strider.siv_window(): the current window's siv window.
fn striderSivWindow(state_opt: ?*State) callconv(.c) c_int {
    const state = state_opt.?;
    const self = get(state);
    const w = self.windowOf(state) orelse return 0;
    _ = sl.siv_lua_push_handle(state, "window", @backingInt(w.window));
    return 1;
}

fn windowOf(self: *Lua, _: *State) ?*Window {
    return self.window orelse self.app.lastWindow();
}
