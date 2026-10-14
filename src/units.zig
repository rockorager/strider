//! The unit tests: everything that needs no siv.

test {
    _ = @import("model.zig");
    _ = @import("mime.zig");
    _ = @import("fsops.zig");
    _ = @import("sync.zig");
    _ = @import("uri.zig");
    _ = @import("trash.zig");
    _ = @import("apps.zig");
    _ = @import("mounts.zig");
    _ = @import("places.zig");
    _ = @import("undo.zig");
    _ = @import("rename.zig");
    _ = @import("keys.zig");
    _ = @import("highlight.zig");
    _ = @import("proc.zig");
    _ = @import("archive.zig");
}
