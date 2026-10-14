//! Writes the desktop file and D-Bus service files with the installed
//! program's absolute path, which D-Bus needs (it starts programs without
//! searching $PATH). Run by the build at make time, when the install
//! prefix is known.
//!
//!     desktop_files PREFIX OUT_DIR

const std = @import("std");

const app_id = "org.siv.Columns";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;
    const prefix = args[1];
    const out = args[2];
    // A relative prefix (zig-out) is relative to the build root, where
    // this runs.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd = if (std.os.linux.errno(cwd_len) == .SUCCESS) std.mem.sliceTo(&cwd_buf, 0) else "/";
    const trimmed = std.mem.trimEnd(u8, prefix, "/");
    const abs = if (std.mem.startsWith(u8, trimmed, "/")) trimmed else try std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, std.mem.trimStart(u8, trimmed, "./") });
    const bin = try std.fmt.allocPrint(arena, "{s}/bin/siv-columns", .{abs});
    const files = [_]struct { []const u8, []const u8 }{
        .{ app_id ++ ".desktop", try std.fmt.allocPrint(arena,
            \\[Desktop Entry]
            \\Type=Application
            \\Name=Columns
            \\GenericName=File Manager
            \\Comment=Browse and organize files from the keyboard, in Miller columns
            \\Icon={s}
            \\Exec={s} %U
            \\DBusActivatable=true
            \\StartupNotify=true
            \\Terminal=false
            \\Categories=System;FileManager;FileTools;
            \\Keywords=folder;manager;explore;disk;filesystem;ranger;yazi;vim;keyboard;miller;columns;
            \\MimeType=inode/directory;
            \\Actions=new-window;
            \\
            \\[Desktop Action new-window]
            \\Name=New Window
            \\Exec={s} --new-window
            \\
        , .{ app_id, bin, bin }) },
        // File chooser windows' app id: hidden from launchers, there for
        // its name and icon (and for compositor rules to match).
        .{ app_id ++ ".Chooser.desktop", try std.fmt.allocPrint(arena,
            \\[Desktop Entry]
            \\Type=Application
            \\Name=Columns File Chooser
            \\Comment=The desktop's file chooser, in Miller columns
            \\Icon={s}
            \\Exec={s} --service
            \\NoDisplay=true
            \\Terminal=false
            \\
        , .{ app_id, bin }) },
        .{ app_id ++ ".service", try std.fmt.allocPrint(arena,
            \\[D-BUS Service]
            \\Name={s}
            \\Exec={s} --service
            \\
        , .{ app_id, bin }) },
        .{ "org.freedesktop.impl.portal.desktop.siv_columns.service", try std.fmt.allocPrint(arena,
            \\[D-BUS Service]
            \\Name=org.freedesktop.impl.portal.desktop.siv_columns
            \\Exec={s} --service
            \\
        , .{bin}) },
        .{ "org.freedesktop.FileManager1.service", try std.fmt.allocPrint(arena,
            \\[D-BUS Service]
            \\Name=org.freedesktop.FileManager1
            \\Exec={s} --service
            \\
        , .{bin}) },
    };
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, out, .{});
    defer dir.close(io);
    for (files) |f| try dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
}
