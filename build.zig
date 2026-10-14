//! siv-columns: a keyboard-driven, ranger-style file manager for Wayland,
//! built on siv.
//!
//!   zig build                  bin/siv-columns and its desktop files in zig-out
//!   zig build run -- [ARGS]    run it from zig-out
//!   zig build install --prefix ~/.local   install for one user (or
//!                              sudo zig build install --prefix /usr/local)
//!   zig build test             unit tests and headless tests with goldens
//!   zig build bench            startup, memory, and navigating 100 000 entries
//!
//! Options:
//!   -Doptimize=...             the program defaults to ReleaseSafe, the tests
//!                              to Debug
//!   -Dtest-filter=<text>       only tests whose name contains <text>
//!
//! The program uses only siv's public API: the `siv` module generated from
//! its C ABI schema and the Lua binding's embedding API, both linked
//! statically (libsiv.a and the Lua binding's object), so the installed
//! program is one file that needs only the system's libwayland-client,
//! xkbcommon, and Fontconfig.

const std = @import("std");

const app_id = "org.siv.Columns";
const program = "siv-columns";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize_opt = b.option(std.builtin.Optimize, "optimize", "Prioritize performance, safety, or binary size (default: safe for the program, debug for tests)");
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests whose name does not contain this text") orelse &.{};
    // D-Bus activation cannot choose between two service files for one
    // name, so other file managers' would compete with this one.
    const filemanager1 = b.option(bool, "filemanager1", "Install a D-Bus service file for org.freedesktop.FileManager1, so the bus starts this program for other applications' \"Show in folder\" (default: false)") orelse false;

    const exe_optimize = optimize_opt orelse .safe;
    const test_optimize = optimize_opt orelse .debug;

    // The program.
    const exe_siv = sivModule(b, target, exe_optimize);
    const exe = b.addExecutable(.{
        .name = program,
        .root_module = appModule(b, exe_siv, "src/main.zig"),
    });
    b.installArtifact(exe);
    installData(b, filemanager1);
    const siv_dep = b.dependency("siv", .{ .target = target, .optimize = exe_optimize });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(siv_dep.namedLazyPath("notices"), .prefix, "share/licenses/" ++ program ++ "/NOTICES-siv").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(siv_dep.namedLazyPath("lua-notices"), .prefix, "share/licenses/" ++ program ++ "/NOTICES-siv-lua").step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the file manager").dependOn(&run.step);

    // Tests: the plain modules' unit tests, and the application on siv's
    // headless backend driven through siv's public test API.
    const test_step = b.step("test", "Run the unit and headless tests");
    const units = b.addTest(.{
        .name = "units",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/units.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(units).step);

    const test_siv = sivModule(b, target, test_optimize);
    const headless_mod = appModule(b, test_siv, "tests/headless.zig");
    headless_mod.addImport("app", appModule(b, test_siv, "src/App.zig"));
    const headless = b.addTest(.{ .name = "headless", .root_module = headless_mod, .filters = test_filters });
    const headless_run = b.addRunArtifact(headless);
    // Goldens are read and written relative to the project.
    headless_run.setCwd(b.path("."));
    headless_run.has_side_effects = true;
    test_step.dependOn(&headless_run.step);

    // Measurements: not a test.
    const bench_mod = appModule(b, exe_siv, "tests/bench.zig");
    bench_mod.addImport("app", appModule(b, exe_siv, "src/App.zig"));
    const bench = b.addExecutable(.{ .name = program ++ "-bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    bench_run.addPassthruArgs();
    bench_run.has_side_effects = true;
    b.step("bench", "Measure startup, memory, and navigating a 100 000-entry folder").dependOn(&bench_run.step);
}

/// siv's generated Zig API with libsiv linked statically, and the Lua
/// binding (libsiv-lua.a) with the Lua C API it embeds as `lua`.
fn sivModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    const siv_dep = b.dependency("siv", .{ .target = target, .optimize = optimize });
    const siv_mod = siv_dep.module("siv-static");
    return siv_mod;
}

/// A module of this project that imports siv and Lua.
fn appModule(b: *std.Build, siv_mod: *std.Build.Module, root: []const u8) *std.Build.Module {
    const siv_dep = b.dependency("siv", .{ .target = siv_mod.resolved_target.?, .optimize = siv_mod.optimize.? });
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = siv_mod.resolved_target,
        .optimize = siv_mod.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "siv", .module = siv_mod },
            .{ .name = "siv_lua", .module = siv_dep.module("siv-lua-static") },
        },
    });
}

/// The desktop file, D-Bus service files, icon, AppStream metadata, and
/// the program's own fallback icons. The desktop and service files name
/// the installed program by absolute path (D-Bus starts it without a PATH
/// search), so a small program writes them once the prefix is known.
fn installData(b: *std.Build, filemanager1: bool) void {
    const gen = b.addExecutable(.{
        .name = "desktop-files",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/desktop_files.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(gen);
    run.addDirectoryArg(.{ .relative = .{ .base = .install_prefix } });
    const out = run.addOutputDirectoryArg("data");
    const files = [_]struct { std.Build.LazyPath, []const u8 }{
        .{ out.path(b, app_id ++ ".desktop"), "share/applications/" ++ app_id ++ ".desktop" },
        .{ out.path(b, app_id ++ ".service"), "share/dbus-1/services/" ++ app_id ++ ".service" },
        .{ b.path("data/" ++ app_id ++ ".svg"), "share/icons/hicolor/scalable/apps/" ++ app_id ++ ".svg" },
        .{ b.path("data/" ++ app_id ++ ".metainfo.xml"), "share/metainfo/" ++ app_id ++ ".metainfo.xml" },
        .{ b.path("data/init.lua"), "share/doc/" ++ program ++ "/init.lua" },
    };
    for (files) |f| b.getInstallStep().dependOn(&b.addInstallFileWithDir(f[0], .prefix, f[1]).step);
    if (filemanager1) b.getInstallStep().dependOn(&b.addInstallFileWithDir(out.path(b, "org.freedesktop.FileManager1.service"), .prefix, "share/dbus-1/services/org.freedesktop.FileManager1.service").step);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("icons"), .install_dir = .prefix, .install_subdir = "share/" ++ program ++ "/icons" }).step);
}
