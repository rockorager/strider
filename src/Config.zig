//! Options and the default keymap. Lua (init.lua) changes both through
//! the `fm` module; without a configuration these are what you get.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");
const keys = @import("keys.zig");

pub const Options = struct {
    /// Show entries whose names start with a dot.
    show_hidden: bool = false,
    sort: model.Sort = .{},
    /// Widths of the parent, current, and preview columns, as shares
    /// (ranger's column_ratios).
    ratio: [3]f32 = .{ 1, 3, 4 },
    /// The parent column widens to show its longest name, up to a quarter
    /// of the window, taking the room from the preview.
    fit_parent: bool = true,
    /// Logical pixels: a window narrower than this hides the parent
    /// column, and one narrower than two thirds of it the preview too.
    narrow_width: u32 = 640,
    /// Themed icons beside names.
    icons: bool = true,
    /// The preview column.
    preview: bool = true,
    /// Image previews (decoded at the size shown).
    preview_images: bool = true,
    /// How much of a text file a preview reads.
    preview_max_bytes: u32 = 128 * 1024,
    /// Image files larger than this show their details instead.
    preview_max_image_bytes: u32 = 64 * 1024 * 1024,
    /// Syntax coloring in text previews.
    syntax: bool = true,
    /// Milliseconds before the which-key popup shows after a prefix; 0
    /// shows it at once.
    which_key_delay: u32 = 300,
    /// Rows kept visible above and below the cursor.
    scroll_off: u32 = 3,
    /// Searches wrap around the end.
    wrap_scan: bool = true,
    /// f: close the prompt as soon as one name matches, as ranger does;
    /// off, Enter closes it.
    find_auto_accept: bool = true,
    /// Ask before deleting permanently.
    confirm_delete: bool = true,
    /// Sizes in the current column.
    show_size: bool = true,
    /// The terminal for $EDITOR and shell commands, as a command line
    /// that the program follows ("foot", "kitty --"); empty finds one.
    terminal: []const u8 = "",
    /// The editor for bulk renames; empty uses $VISUAL, then $EDITOR,
    /// then vi.
    editor: []const u8 = "",
    /// Whether the editor is a terminal program (run in `terminal`).
    editor_in_terminal: bool = true,
    /// The shell for ! commands.
    shell: []const u8 = "sh",
    /// Re-read a shown folder that is not watched when it is older than
    /// this many milliseconds.
    stale_ms: u32 = 2000,
};

pub const Kind = enum { boolean, number, string, sort, ratio };

pub const Info = struct { name: []const u8, kind: Kind, desc: []const u8 };

/// The options Lua and :set know, with what each means.
pub const infos = [_]Info{
    .{ .name = "hidden", .kind = .boolean, .desc = "Show hidden files" },
    .{ .name = "sort", .kind = .sort, .desc = "Sort by: name, size, modified, type, extension" },
    .{ .name = "sort_reverse", .kind = .boolean, .desc = "Reverse the sort" },
    .{ .name = "dirs_first", .kind = .boolean, .desc = "Folders before files" },
    .{ .name = "ratio", .kind = .ratio, .desc = "Column widths, e.g. {1, 3, 4}" },
    .{ .name = "fit_parent", .kind = .boolean, .desc = "Widen the parent column to fit its names" },
    .{ .name = "narrow_width", .kind = .number, .desc = "Hide the parent column below this window width" },
    .{ .name = "icons", .kind = .boolean, .desc = "Icons beside names" },
    .{ .name = "preview", .kind = .boolean, .desc = "The preview column" },
    .{ .name = "preview_images", .kind = .boolean, .desc = "Image previews" },
    .{ .name = "preview_max_bytes", .kind = .number, .desc = "How much of a text file a preview reads" },
    .{ .name = "preview_max_image_bytes", .kind = .number, .desc = "Larger images show their details" },
    .{ .name = "syntax", .kind = .boolean, .desc = "Syntax coloring in previews" },
    .{ .name = "which_key_delay", .kind = .number, .desc = "Milliseconds before the key hints show" },
    .{ .name = "scroll_off", .kind = .number, .desc = "Rows kept visible around the cursor" },
    .{ .name = "wrap_scan", .kind = .boolean, .desc = "Searches wrap around" },
    .{ .name = "find_auto_accept", .kind = .boolean, .desc = "f jumps to a single match at once" },
    .{ .name = "confirm_delete", .kind = .boolean, .desc = "Ask before deleting permanently" },
    .{ .name = "show_size", .kind = .boolean, .desc = "Sizes in the current column" },
    .{ .name = "terminal", .kind = .string, .desc = "Terminal command for editors and shells" },
    .{ .name = "editor", .kind = .string, .desc = "Editor for bulk renames" },
    .{ .name = "editor_in_terminal", .kind = .boolean, .desc = "Run the editor in the terminal" },
    .{ .name = "shell", .kind = .string, .desc = "Shell for ! commands" },
    .{ .name = "stale_ms", .kind = .number, .desc = "Re-read unwatched folders older than this" },
};

pub fn info(name: []const u8) ?Info {
    for (infos) |i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

/// Strings options own (the terminal, editor, shell), freed on change.
pub const Strings = struct {
    gpa: Allocator,
    owned: std.ArrayList([]u8) = .empty,

    pub fn deinit(s: *Strings) void {
        for (s.owned.items) |x| s.gpa.free(x);
        s.owned.deinit(s.gpa);
    }

    pub fn keep(s: *Strings, v: []const u8) ![]const u8 {
        const d = try s.gpa.dupe(u8, v);
        try s.owned.append(s.gpa, d);
        return d;
    }
};

pub const SetError = error{ UnknownOption, InvalidValue, OutOfMemory };

/// Sets an option from text (":set name value"); booleans take
/// true/false/on/off/yes/no, or toggle with "!" or no value.
pub fn setFromText(o: *Options, strings: *Strings, name: []const u8, value: ?[]const u8) SetError!void {
    const i = info(name) orelse return error.UnknownOption;
    switch (i.kind) {
        .boolean => {
            const cur = getBool(o, name).?;
            const v: bool = if (value) |t| parseBool(t) orelse return error.InvalidValue else !cur;
            setBool(o, name, v);
        },
        .number => {
            const t = value orelse return error.InvalidValue;
            const v = std.fmt.parseInt(u32, t, 10) catch return error.InvalidValue;
            setNumber(o, name, v);
        },
        .string => try setString(o, strings, name, value orelse ""),
        .sort => {
            const t = value orelse return error.InvalidValue;
            o.sort.key = parseSortKey(t) orelse return error.InvalidValue;
        },
        .ratio => {
            const t = value orelse return error.InvalidValue;
            var r: [3]f32 = undefined;
            var it = std.mem.tokenizeAny(u8, t, " ,:{}");
            for (&r) |*x| {
                const w = it.next() orelse return error.InvalidValue;
                x.* = std.fmt.parseFloat(f32, w) catch return error.InvalidValue;
                if (x.* < 0) return error.InvalidValue;
            }
            o.ratio = r;
        },
    }
}

pub fn parseBool(t: []const u8) ?bool {
    const yes = [_][]const u8{ "true", "on", "yes", "1" };
    const no = [_][]const u8{ "false", "off", "no", "0" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(t, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(t, n)) return false;
    return null;
}

pub fn parseSortKey(t: []const u8) ?model.SortKey {
    if (std.mem.eql(u8, t, "name") or std.mem.eql(u8, t, "natural")) return .name;
    if (std.mem.eql(u8, t, "size")) return .size;
    if (std.mem.eql(u8, t, "modified") or std.mem.eql(u8, t, "mtime")) return .modified;
    if (std.mem.eql(u8, t, "type") or std.mem.eql(u8, t, "mime")) return .type;
    if (std.mem.eql(u8, t, "extension") or std.mem.eql(u8, t, "ext")) return .extension;
    return null;
}

/// Options fields that are booleans and numbers under their own names.
const bool_fields = .{ "icons", "fit_parent", "preview", "preview_images", "syntax", "wrap_scan", "find_auto_accept", "confirm_delete", "show_size", "editor_in_terminal" };
const number_fields = .{ "narrow_width", "preview_max_bytes", "preview_max_image_bytes", "which_key_delay", "scroll_off", "stale_ms" };

pub fn getBool(o: *const Options, name: []const u8) ?bool {
    if (std.mem.eql(u8, name, "hidden")) return o.show_hidden;
    if (std.mem.eql(u8, name, "sort_reverse")) return o.sort.descending;
    if (std.mem.eql(u8, name, "dirs_first")) return o.sort.folders_first;
    inline for (bool_fields) |f| {
        if (std.mem.eql(u8, name, f)) return @field(o, f);
    }
    return null;
}

pub fn setBool(o: *Options, name: []const u8, v: bool) void {
    if (std.mem.eql(u8, name, "hidden")) o.show_hidden = v;
    if (std.mem.eql(u8, name, "sort_reverse")) o.sort.descending = v;
    if (std.mem.eql(u8, name, "dirs_first")) o.sort.folders_first = v;
    inline for (bool_fields) |f| {
        if (std.mem.eql(u8, name, f)) @field(o, f) = v;
    }
}

pub fn getNumber(o: *const Options, name: []const u8) ?u32 {
    inline for (number_fields) |f| {
        if (std.mem.eql(u8, name, f)) return @field(o, f);
    }
    return null;
}

pub fn setNumber(o: *Options, name: []const u8, v: u32) void {
    inline for (number_fields) |f| {
        if (std.mem.eql(u8, name, f)) @field(o, f) = v;
    }
}

pub fn getString(o: *const Options, name: []const u8) ?[]const u8 {
    inline for (.{ "terminal", "editor", "shell" }) |f| {
        if (std.mem.eql(u8, name, f)) return @field(o, f);
    }
    if (std.mem.eql(u8, name, "sort")) return @tagName(o.sort.key);
    return null;
}

pub fn setString(o: *Options, strings: *Strings, name: []const u8, v: []const u8) SetError!void {
    inline for (.{ "terminal", "editor", "shell" }) |f| {
        if (std.mem.eql(u8, name, f)) {
            @field(o, f) = try strings.keep(v);
            return;
        }
    }
    return error.UnknownOption;
}

/// The default keymap: ranger's and vim's keys.
pub const default_bindings = [_]struct { keys.Mode, []const u8, []const u8, []const u8 }{
    // Moving.
    .{ .normal, "j", "down", "Down" },
    .{ .normal, "k", "up", "Up" },
    .{ .normal, "h", "leave", "Parent folder" },
    .{ .normal, "l", "enter", "Enter or open" },
    .{ .normal, "<Down>", "down", "Down" },
    .{ .normal, "<Up>", "up", "Up" },
    .{ .normal, "<Left>", "leave", "Parent folder" },
    .{ .normal, "<Right>", "enter", "Enter or open" },
    .{ .normal, "<CR>", "open", "Open" },
    .{ .normal, "<BS>", "leave", "Parent folder" },
    .{ .normal, "gg", "top", "First entry" },
    .{ .normal, "G", "bottom", "Last entry" },
    .{ .normal, "<Home>", "top", "First entry" },
    .{ .normal, "<End>", "bottom", "Last entry" },
    .{ .normal, "<C-d>", "half-down", "Half a page down" },
    .{ .normal, "<C-u>", "half-up", "Half a page up" },
    .{ .normal, "<C-f>", "page-down", "Page down" },
    .{ .normal, "<C-b>", "page-up", "Page up" },
    .{ .normal, "<PageDown>", "page-down", "Page down" },
    .{ .normal, "<PageUp>", "page-up", "Page up" },
    .{ .normal, "H", "back", "Back in history" },
    .{ .normal, "L", "forward", "Forward in history" },
    .{ .normal, "J", "preview-down", "Scroll the preview down" },
    .{ .normal, "K", "preview-up", "Scroll the preview up" },
    // Going places.
    .{ .normal, "gh", "cd ~", "Home" },
    .{ .normal, "g/", "cd /", "Root" },
    .{ .normal, "gd", "cd-xdg DOWNLOAD", "Downloads" },
    .{ .normal, "gD", "cd-xdg DOCUMENTS", "Documents" },
    .{ .normal, "gc", "cd ~/.config", "~/.config" },
    .{ .normal, "gx", "trash-browse", "Trash" },
    .{ .normal, "gv", "drives", "Drives" },
    .{ .normal, "gm", "cd-media", "Mounted media" },
    .{ .normal, "gf", "fuzzy", "Find a file below" },
    .{ .normal, "gz", "zi", "Jump with zoxide" },
    .{ .normal, "g?", "help", "All keys" },
    .{ .normal, "<F1>", "help", "All keys" },
    // Tabs.
    .{ .normal, "gn", "tab-new", "New tab" },
    .{ .normal, "<C-t>", "tab-new", "New tab" },
    .{ .normal, "gt", "tab-next", "Next tab" },
    .{ .normal, "gT", "tab-prev", "Previous tab" },
    .{ .normal, "<Tab>", "tab-next", "Next tab" },
    .{ .normal, "<S-Tab>", "tab-prev", "Previous tab" },
    .{ .normal, "gq", "tab-close", "Close tab" },
    .{ .normal, "<C-w>", "tab-close", "Close tab" },
    .{ .normal, "<A-1>", "tab 1", "Tab 1" },
    .{ .normal, "<A-2>", "tab 2", "Tab 2" },
    .{ .normal, "<A-3>", "tab 3", "Tab 3" },
    .{ .normal, "<A-4>", "tab 4", "Tab 4" },
    .{ .normal, "<A-5>", "tab 5", "Tab 5" },
    .{ .normal, "<A-6>", "tab 6", "Tab 6" },
    .{ .normal, "<A-7>", "tab 7", "Tab 7" },
    .{ .normal, "<A-8>", "tab 8", "Tab 8" },
    .{ .normal, "<A-9>", "tab 9", "Tab 9" },
    // Searching.
    .{ .normal, "/", "search", "Search" },
    .{ .normal, "?", "search-back", "Search backward" },
    .{ .normal, "n", "search-next", "Next match" },
    .{ .normal, "N", "search-prev", "Previous match" },
    .{ .normal, "f", "find", "Jump to a name" },
    .{ .normal, "zf", "filter", "Filter the folder" },
    // Marking.
    .{ .normal, "<Space>", "toggle-mark", "Mark and move down" },
    .{ .normal, "v", "visual", "Visual selection" },
    .{ .normal, "V", "visual", "Visual selection" },
    .{ .normal, "<C-a>", "mark-all", "Mark everything" },
    .{ .normal, "<Esc>", "escape", "Cancel, unmark" },
    .{ .visual, "<Esc>", "visual-end", "Keep the range marked" },
    .{ .visual, "v", "visual-end", "Keep the range marked" },
    .{ .visual, "V", "visual-end", "Keep the range marked" },
    // Files.
    .{ .normal, "yy", "yank", "Copy" },
    .{ .normal, "dd", "cut", "Cut" },
    .{ .normal, "p", "paste", "Paste" },
    .{ .normal, "P", "paste-overwrite", "Paste, replacing" },
    .{ .normal, "yp", "yank-path", "Copy the path" },
    .{ .normal, "yn", "yank-name", "Copy the name" },
    .{ .normal, "yd", "yank-dir", "Copy the folder's path" },
    .{ .visual, "y", "yank", "Copy" },
    .{ .visual, "d", "cut", "Cut" },
    .{ .normal, "dT", "trash", "Move to the trash" },
    .{ .normal, "dD", "delete", "Delete permanently" },
    .{ .normal, "dr", "restore", "Restore from the trash" },
    .{ .normal, "<Del>", "trash", "Move to the trash" },
    .{ .normal, "<S-Del>", "delete", "Delete permanently" },
    .{ .normal, "u", "undo", "Undo" },
    .{ .normal, "r", "rename", "Rename" },
    .{ .normal, "cw", "rename", "Rename" },
    .{ .normal, "A", "rename-append", "Rename at the end" },
    .{ .normal, "I", "rename-insert", "Rename at the start" },
    .{ .normal, "R", "bulk-rename", "Rename in $EDITOR" },
    .{ .normal, "<F2>", "rename", "Rename" },
    .{ .normal, "a", "create", "New file (or folder/)" },
    .{ .normal, "o", "open-with", "Open with…" },
    .{ .normal, "!", "shell-prompt", "Run a shell command" },
    .{ .normal, "S", "terminal", "Terminal here" },
    .{ .normal, "=", "chmod", "Change permissions" },
    .{ .normal, "w", "tasks", "Tasks" },
    // The tasks view.
    .{ .tasks, "j", "task-down", "Next task" },
    .{ .tasks, "<Down>", "task-down", "Next task" },
    .{ .tasks, "k", "task-up", "Previous task" },
    .{ .tasks, "<Up>", "task-up", "Previous task" },
    .{ .tasks, "p", "task-pause", "Pause or resume" },
    .{ .tasks, "<Space>", "task-pause", "Pause or resume" },
    .{ .tasks, "x", "task-cancel", "Cancel it, or remove it when done" },
    .{ .tasks, "dd", "task-cancel", "Cancel it, or remove it when done" },
    .{ .tasks, "<Esc>", "tasks", "Close" },
    .{ .tasks, "q", "tasks", "Close" },
    .{ .tasks, "w", "tasks", "Close" },
    .{ .normal, "<C-r>", "reload", "Reload" },
    // Views.
    .{ .normal, "zh", "toggle-hidden", "Hidden files" },
    .{ .normal, "<C-h>", "toggle-hidden", "Hidden files" },
    .{ .normal, "zp", "toggle-preview", "Preview column" },
    .{ .normal, "zi", "toggle-icons", "Icons" },
    .{ .normal, "sn", "sort name", "Sort by name" },
    .{ .normal, "ss", "sort size", "Sort by size" },
    .{ .normal, "sm", "sort modified", "Sort by modified" },
    .{ .normal, "st", "sort type", "Sort by type" },
    .{ .normal, "se", "sort extension", "Sort by extension" },
    .{ .normal, "sr", "sort-reverse", "Reverse the sort" },
    .{ .normal, "sd", "sort-dirs-first", "Folders first" },
    .{ .normal, "sN", "sort name reverse", "By name, reversed" },
    .{ .normal, "sS", "sort size reverse", "By size, largest first" },
    .{ .normal, "sM", "sort modified reverse", "By modified, newest first" },
    // Marks.
    .{ .normal, "m", "bookmark-set", "Set a bookmark" },
    .{ .normal, "'", "bookmark-jump", "Go to a bookmark" },
    .{ .normal, "`", "bookmark-jump", "Go to a bookmark" },
    .{ .normal, "dm", "bookmark-remove", "Remove a bookmark" },
    // Commands.
    .{ .normal, ":", "command", "Command line" },
    .{ .normal, ";", "command", "Command line" },
    .{ .normal, "q", "quit", "Close the tab or quit" },
    .{ .normal, "ZZ", "quit-all", "Quit" },
    .{ .normal, "ZQ", "quit-all", "Quit" },
};
