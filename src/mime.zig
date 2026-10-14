//! MIME types from the freedesktop.org shared-mime-info database:
//! globs2 (by name), aliases, subclasses, icons, and the types' comments
//! (their human-readable names) from <type>.xml, with a small content
//! sniffer for names no glob matches. Names that several types claim at
//! the same weight (*.ts: Qt Linguist, MPEG transport stream, and on newer
//! databases TypeScript) are settled by the file's first bytes: the magic
//! rules of the contending types, then whether it reads as text.
//!
//! Loaded once, from a worker thread, then read from any thread; only the
//! comment cache changes afterwards, under a mutex.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");

pub const Id = u16;

/// Types every listing needs, at fixed ids.
pub const directory: Id = 0;
pub const octet_stream: Id = 1;
pub const text_plain: Id = 2;
pub const executable: Id = 3;
pub const symlink: Id = 4;
pub const shellscript: Id = 5;
pub const zerosize: Id = 6;
pub const unknown: Id = 7;
const builtin_types = [_][]const u8{
    "inode/directory",
    "application/octet-stream",
    "text/plain",
    "application/x-executable",
    "inode/symlink",
    "application/x-shellscript",
    "application/x-zerosize",
    "application/x-unknown",
};

pub const Hit = struct { id: Id, weight: u16 };
/// The types one name or extension matches, in database order (the most
/// important data directory first); `contested` when the best weight is
/// shared and the file's content can tell the types apart.
const Hits = struct { list: std.ArrayList(Hit) = .empty, contested: bool = false };
/// A glob match: the best type, and all candidates when content must
/// settle it (see `Db.settle`).
pub const Match = struct { id: Id, contested: ?[]const Hit = null };
/// A rule from the `magic` file: `value` (under `mask`) at an offset from
/// `offset` to `offset + range - 1`, and, if it has children, one of them.
const Matchlet = struct { offset: u32, range: u32, value: []const u8, mask: ?[]const u8, children: []const Matchlet };
const Magic = struct { priority: u8, rules: []const Matchlet };
const Complex = struct { pattern: []const u8, id: Id, weight: u16, case_sensitive: bool };

pub const Db = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    names: std.ArrayList([]const u8) = .empty,
    ids: std.StringHashMapUnmanaged(Id) = .empty,
    /// Exact file names (case-sensitive), then lowercased.
    literal: std.StringHashMapUnmanaged(Hits) = .empty,
    literal_ci: std.StringHashMapUnmanaged(Hits) = .empty,
    /// "*.ext" globs by extension (without the dot): case-sensitive ones,
    /// then the rest lowercased.
    ext_cs: std.StringHashMapUnmanaged(Hits) = .empty,
    ext_ci: std.StringHashMapUnmanaged(Hits) = .empty,
    complex: std.ArrayList(Complex) = .empty,
    aliases: std.StringHashMapUnmanaged(Id) = .empty,
    /// Each type's parents, by id.
    parents: std.AutoHashMapUnmanaged(Id, []Id) = .empty,
    /// Icon names by id (from `icons` and `generic-icons`).
    icon: std.AutoHashMapUnmanaged(Id, []const u8) = .empty,
    generic_icon: std.AutoHashMapUnmanaged(Id, []const u8) = .empty,
    /// Magic rules, only for the types of contested names.
    magic: std.AutoHashMapUnmanaged(Id, Magic) = .empty,
    /// The directories holding mime/ (data dirs), for <type>.xml.
    dirs: std.ArrayList([]const u8) = .empty,

    mutex: sync.Mutex = .{},
    comments: std.AutoHashMapUnmanaged(Id, []const u8) = .empty,

    fn loadGlobs(db: *Db, dir: []const u8) !void {
        try eachLine(db.gpa, dir, "globs2", db, loadGlobsImpl);
    }

    fn loadAliases(db: *Db, dir: []const u8) !void {
        try eachLine(db.gpa, dir, "aliases", db, loadAliasImpl);
    }

    fn loadSubclasses(db: *Db, dir: []const u8) !void {
        try eachLine(db.gpa, dir, "subclasses", db, loadSubclassImpl);
    }

    fn loadIcons(db: *Db, dir: []const u8, file: []const u8, map: *std.AutoHashMapUnmanaged(Id, []const u8)) !void {
        try eachLine(db.gpa, dir, file, IconCtx{ .db = db, .map = map }, loadIconsImpl);
    }

    pub fn deinit(db: *Db) void {
        db.arena.deinit();
        db.* = undefined;
    }

    fn a(db: *Db) Allocator {
        return db.arena.allocator();
    }

    /// The id of `name`, added if new. Aliases resolve to their type.
    pub fn intern(db: *Db, type_name: []const u8) !Id {
        if (db.aliases.get(type_name)) |id| return id;
        if (db.ids.get(type_name)) |id| return id;
        if (db.names.items.len >= std.math.maxInt(Id)) return unknown;
        const copy = try db.a().dupe(u8, type_name);
        const id: Id = @intCast(db.names.items.len);
        try db.names.append(db.a(), copy);
        try db.ids.put(db.a(), copy, id);
        return id;
    }

    pub fn lookup(db: *const Db, type_name: []const u8) ?Id {
        if (db.aliases.get(type_name)) |id| return id;
        return db.ids.get(type_name);
    }

    pub fn name(db: *const Db, id: Id) []const u8 {
        return if (id < db.names.items.len) db.names.items[id] else "application/octet-stream";
    }

    /// The type of a file by its name alone, or null if no glob matches.
    /// For a contested name this is the database's first best guess; see
    /// `match` for settling it by content.
    pub fn byName(db: *const Db, file_name: []const u8) ?Id {
        return if (db.match(file_name)) |m| m.id else null;
    }

    /// The glob match for a file name, or null if no glob matches.
    pub fn match(db: *const Db, file_name: []const u8) ?Match {
        var lower_buf: [256]u8 = undefined;
        if (db.literal.get(file_name)) |h| return hitsMatch(h);
        const lower = if (file_name.len <= lower_buf.len) std.ascii.lowerString(&lower_buf, file_name) else file_name;
        if (db.literal_ci.get(lower)) |h| return hitsMatch(h);
        // The longest extension that is a glob: from the first dot on.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, file_name, i, '.')) |dot| : (i = dot + 1) {
            if (dot + 1 >= file_name.len) break;
            if (db.ext_cs.get(file_name[dot + 1 ..])) |h| return hitsMatch(h);
            if (db.ext_ci.get(lower[dot + 1 ..])) |h| return hitsMatch(h);
        }
        var best: ?Hit = null;
        for (db.complex.items) |cx| {
            const subject = if (cx.case_sensitive) file_name else lower;
            if (best != null and best.?.weight >= cx.weight) continue;
            if (globMatch(cx.pattern, subject)) best = .{ .id = cx.id, .weight = cx.weight };
        }
        return if (best) |b| .{ .id = b.id } else null;
    }

    fn hitsMatch(h: Hits) Match {
        return .{ .id = bestHit(h.list.items).id, .contested = if (h.contested) h.list.items else null };
    }

    /// Settles a contested name by the file's first bytes (`head`; a few
    /// KiB, so that magic at larger offsets can match). The shared-mime-
    /// info spec has magic decide between globs of equal weight; when no
    /// candidate's magic matches, text content goes to a text candidate
    /// whose strong (priority 50 and up) magic did not just fail, as GIO
    /// does with its looks-like-text check, and binary content to a binary
    /// candidate. Weaker globs count too: TypeScript's *.ts glob is weight
    /// 40 against Linguist's and MPEG-TS's 50, and only content tells them
    /// apart.
    pub fn settle(db: *const Db, hits: []const Hit, head: []const u8) Id {
        var best: ?Hit = null;
        var best_priority: u8 = 0;
        for (hits) |h| {
            const m = db.magic.get(h.id) orelse continue;
            if (!magicMatches(m.rules, head)) continue;
            if (best == null or m.priority > best_priority or (m.priority == best_priority and h.weight > best.?.weight)) {
                best = h;
                best_priority = m.priority;
            }
        }
        if (best) |b| return b.id;
        const text = looksLikeText(head);
        for (hits) |h| {
            if (db.isA(h.id, text_plain) != text) continue;
            if (text) if (db.magic.get(h.id)) |m| if (m.priority >= 50) continue;
            if (best == null or h.weight > best.?.weight) best = h;
        }
        if (best) |b| return b.id;
        return if (text) text_plain else octet_stream;
    }

    pub fn byNameOr(db: *const Db, file_name: []const u8, default: Id) Id {
        return db.byName(file_name) orelse default;
    }

    /// Whether `id` is `ancestor` or a subclass of it (text/x-csrc is
    /// text/plain).
    pub fn isA(db: *const Db, id: Id, ancestor: Id) bool {
        if (id == ancestor) return true;
        var depth: u8 = 0;
        return db.isAInner(id, ancestor, &depth);
    }

    fn isAInner(db: *const Db, id: Id, ancestor: Id, depth: *u8) bool {
        if (depth.* > 8) return false;
        depth.* += 1;
        defer depth.* -= 1;
        const ps = db.parents.get(id) orelse {
            // Every text/* is text/plain; every type is octet-stream.
            const n = db.name(id);
            if (ancestor == text_plain and std.mem.startsWith(u8, n, "text/")) return true;
            return ancestor == octet_stream and id != directory;
        };
        for (ps) |p| if (p == ancestor or db.isAInner(p, ancestor, depth)) return true;
        return false;
    }

    /// The type and its ancestors, nearest first, for finding an
    /// application that opens it.
    pub fn ancestry(db: *const Db, id: Id, out: []Id) []Id {
        var n: usize = 0;
        out[n] = id;
        n += 1;
        var i: usize = 0;
        while (i < n and n < out.len) : (i += 1) {
            const ps = db.parents.get(out[i]) orelse {
                const nm = db.name(out[i]);
                if (std.mem.startsWith(u8, nm, "text/") and out[i] != text_plain) pushUnique(out, &n, text_plain);
                continue;
            };
            for (ps) |p| pushUnique(out, &n, p);
        }
        return out[0..n];
    }

    fn pushUnique(out: []Id, n: *usize, id: Id) void {
        if (n.* >= out.len) return;
        for (out[0..n.*]) |x| if (x == id) return;
        out[n.*] = id;
        n.* += 1;
    }

    /// Icon names for the type, one per line, most specific first: the
    /// type's own icon, its generic icon, then the media type's generic.
    pub fn iconNames(db: *const Db, id: Id, buf: []u8) []const u8 {
        const nm = db.name(id);
        var w: std.Io.Writer = .fixed(buf);
        if (id == directory) return "folder";
        if (db.icon.get(id)) |ic| w.print("{s}\n", .{ic}) catch {};
        for (nm) |ch| w.writeByte(if (ch == '/') '-' else ch) catch {};
        w.writeByte('\n') catch {};
        if (db.generic_icon.get(id)) |g| {
            w.print("{s}\n", .{g}) catch {};
        } else {
            const slash = std.mem.indexOfScalar(u8, nm, '/') orelse nm.len;
            const media = nm[0..slash];
            const generic: []const u8 = if (std.mem.eql(u8, media, "image")) "image-x-generic" else if (std.mem.eql(u8, media, "audio")) "audio-x-generic" else if (std.mem.eql(u8, media, "video")) "video-x-generic" else if (std.mem.eql(u8, media, "text")) "text-x-generic" else if (std.mem.eql(u8, media, "font")) "font-x-generic" else if (id == executable) "application-x-executable" else "application-x-generic";
            w.print("{s}\n", .{generic}) catch {};
        }
        w.writeAll("text-x-generic") catch {};
        return w.buffered();
    }

    /// The type's human-readable name ("PNG image"), read from its XML
    /// file the first time and cached. May block on the disk: call from
    /// a worker, or for a type already asked for.
    pub fn comment(db: *Db, id: Id) []const u8 {
        db.mutex.lock();
        defer db.mutex.unlock();
        if (db.comments.get(id)) |cm| return cm;
        const value = db.readComment(id) catch null;
        const cm = value orelse fallbackComment(db.name(id));
        db.comments.put(db.a(), id, cm) catch {};
        return cm;
    }

    /// The cached comment, or null if not read yet (UI thread).
    pub fn cachedComment(db: *Db, id: Id) ?[]const u8 {
        db.mutex.lock();
        defer db.mutex.unlock();
        return db.comments.get(id);
    }

    fn readComment(db: *Db, id: Id) !?[]const u8 {
        switch (id) {
            directory => return "Folder",
            symlink => return "Link",
            unknown => return "Unknown",
            else => {},
        }
        const nm = db.name(id);
        for (db.dirs.items) |dir| {
            var pbuf: [linux.PATH_MAX]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "{s}/mime/{s}.xml", .{ dir, nm }) catch continue;
            var buf: [16384]u8 = undefined;
            const xml = readFile(p, &buf) orelse continue;
            if (std.mem.indexOf(u8, xml, "<comment>")) |start| {
                const s = start + "<comment>".len;
                const e = std.mem.indexOfPos(u8, xml, s, "</comment>") orelse continue;
                return try unescapeXml(db.a(), xml[s..e]);
            }
        }
        return null;
    }
};

fn fallbackComment(nm: []const u8) []const u8 {
    if (std.mem.startsWith(u8, nm, "text/")) return "Text";
    if (std.mem.startsWith(u8, nm, "image/")) return "Image";
    if (std.mem.startsWith(u8, nm, "audio/")) return "Audio";
    if (std.mem.startsWith(u8, nm, "video/")) return "Video";
    return "Binary";
}

fn unescapeXml(gpa: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            const ents = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
            for (ents) |en| if (std.mem.startsWith(u8, s[i..], en[0])) {
                try out.append(gpa, en[1]);
                i += en[0].len;
                break;
            } else {
                try out.append(gpa, s[i]);
                i += 1;
            };
            continue;
        }
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Loads the database from the data directories (most important first:
/// $XDG_DATA_HOME, then $XDG_DATA_DIRS). Missing files are fine: names
/// then resolve by the sniffer only.
pub fn load(gpa: Allocator, data_dirs: []const []const u8) !*Db {
    const db = try gpa.create(Db);
    errdefer gpa.destroy(db);
    db.* = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer db.arena.deinit();
    for (builtin_types) |t| _ = try db.intern(t);
    for (data_dirs) |d| try db.dirs.append(db.a(), try db.a().dupe(u8, d));
    // Least important first, so that more important directories win.
    var k = data_dirs.len;
    while (k > 0) {
        k -= 1;
        const dir = data_dirs[k];
        db.loadAliases(dir) catch {};
    }
    // Globs most important first: on equal weights the first type wins.
    for (data_dirs) |dir| db.loadGlobs(dir) catch {};
    k = data_dirs.len;
    while (k > 0) {
        k -= 1;
        const dir = data_dirs[k];
        db.loadSubclasses(dir) catch {};
        db.loadIcons(dir, "icons", &db.icon) catch {};
        db.loadIcons(dir, "generic-icons", &db.generic_icon) catch {};
    }
    try markContested(db);
    return db;
}

const maps_of_hits = .{ "literal", "literal_ci", "ext_cs", "ext_ci" };

/// The first hit of the best weight.
fn bestHit(hits: []const Hit) Hit {
    var best = hits[0];
    for (hits[1..]) |h| if (h.weight > best.weight) {
        best = h;
    };
    return best;
}

fn tied(hits: []const Hit) bool {
    const top = bestHit(hits).weight;
    var n: usize = 0;
    for (hits) |h| n += @intFromBool(h.weight == top);
    return n > 1;
}

fn markContested(db: *Db) !void {
    // Only tied names need magic: load it for their types alone.
    var wanted: std.DynamicBitSetUnmanaged = try .initEmpty(db.gpa, db.names.items.len);
    defer wanted.deinit(db.gpa);
    var any = false;
    inline for (maps_of_hits) |field| {
        var it = @field(db, field).valueIterator();
        while (it.next()) |h| if (tied(h.list.items)) {
            any = true;
            for (h.list.items) |x| wanted.set(x.id);
        };
    }
    if (!any) return;
    var k = db.dirs.items.len;
    while (k > 0) {
        k -= 1;
        loadMagic(db, db.dirs.items[k], &wanted) catch {};
    }
    // Contested when content can tell: some candidate has magic, or the
    // candidates are not all text or all binary.
    inline for (maps_of_hits) |field| {
        var it = @field(db, field).valueIterator();
        while (it.next()) |h| if (tied(h.list.items)) {
            const first_text = db.isA(h.list.items[0].id, text_plain);
            for (h.list.items) |x| {
                if (db.magic.contains(x.id) or db.isA(x.id, text_plain) != first_text) h.contested = true;
            }
        };
    }
}

/// Reads `<dir>/mime/magic`: "MIME-Magic\0\n", then sections
/// "[priority:type]\n" of rules, one per line:
/// [indent]">"offset"="length(2 bytes, big-endian) value ["&"mask]
/// ["~"word-size] ["+"range]"\n".
fn loadMagic(db: *Db, dir: []const u8, wanted: *const std.DynamicBitSetUnmanaged) !void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/mime/magic", .{dir});
    const data = readAll(db.gpa, p) orelse return;
    defer db.gpa.free(data);
    const header = "MIME-Magic\x00\n";
    if (!std.mem.startsWith(u8, data, header)) return;
    var r: MagicReader = .{ .data = data, .pos = header.len };
    var flat: std.ArrayList(FlatMatchlet) = .empty;
    defer flat.deinit(db.gpa);
    while (r.pos < data.len) {
        if (data[r.pos] != '[') return; // malformed: stop
        const close = std.mem.indexOfScalarPos(u8, data, r.pos, ']') orelse return;
        const head = data[r.pos + 1 .. close];
        r.pos = close + 1;
        if (r.pos < data.len and data[r.pos] == '\n') r.pos += 1;
        const colon = std.mem.indexOfScalar(u8, head, ':') orelse return;
        const priority = std.fmt.parseInt(u8, head[0..colon], 10) catch 50;
        flat.clearRetainingCapacity();
        while (r.pos < data.len and data[r.pos] != '[') {
            if (r.line()) |m| try flat.append(db.gpa, m) else return;
        }
        const id = db.lookup(head[colon + 1 ..]) orelse continue;
        if (id >= wanted.bit_length or !wanted.isSet(id)) continue;
        var i: usize = 0;
        const rules = try buildMatchlets(db, flat.items, &i, 0);
        try db.magic.put(db.a(), id, .{ .priority = priority, .rules = rules });
    }
}

const FlatMatchlet = struct { indent: u32, m: Matchlet };

const MagicReader = struct {
    data: []const u8,
    pos: usize,

    fn number(r: *MagicReader) ?u32 {
        const start = r.pos;
        while (r.pos < r.data.len and std.ascii.isDigit(r.data[r.pos])) r.pos += 1;
        if (r.pos == start) return null;
        return std.fmt.parseInt(u32, r.data[start..r.pos], 10) catch null;
    }

    fn bytes(r: *MagicReader, n: usize) ?[]const u8 {
        if (r.pos + n > r.data.len) return null;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    /// One rule line, or null if malformed.
    fn line(r: *MagicReader) ?FlatMatchlet {
        const indent = r.number() orelse 0;
        if ((r.bytes(1) orelse return null)[0] != '>') return null;
        const offset = r.number() orelse return null;
        if ((r.bytes(1) orelse return null)[0] != '=') return null;
        const len_bytes = r.bytes(2) orelse return null;
        const len = std.mem.readInt(u16, len_bytes[0..2], .big);
        const value = r.bytes(len) orelse return null;
        var m: Matchlet = .{ .offset = offset, .range = 1, .value = value, .mask = null, .children = &.{} };
        var word: u32 = 1;
        while (r.pos < r.data.len) {
            const ch = r.data[r.pos];
            r.pos += 1;
            switch (ch) {
                '\n' => break,
                '&' => m.mask = r.bytes(len) orelse return null,
                '~' => word = r.number() orelse 1,
                '+' => m.range = @max(1, r.number() orelse 1),
                // An extension this reader does not know: skip the line.
                else => {
                    const nl = std.mem.indexOfScalarPos(u8, r.data, r.pos, '\n') orelse r.data.len;
                    r.pos = @min(r.data.len, nl + 1);
                    break;
                },
            }
        }
        // Host-order words are stored big-endian: compare in host order.
        if (word > 1 and builtin.cpu.arch.endian() == .little and len % word == 0) m.value = swapped(r, m.value, word) orelse return null;
        if (m.mask) |mk| if (word > 1 and builtin.cpu.arch.endian() == .little and len % word == 0) {
            m.mask = swapped(r, mk, word) orelse return null;
        };
        return .{ .indent = indent, .m = m };
    }

    /// `value` with each `word`-byte group reversed, in place: the data is
    /// a private copy (readAll), and each rule's bytes are swapped once.
    fn swapped(r: *MagicReader, value: []const u8, word: u32) ?[]const u8 {
        const off = @intFromPtr(value.ptr) - @intFromPtr(r.data.ptr);
        const mut = @constCast(r.data)[off..][0..value.len];
        var i: usize = 0;
        while (i < mut.len) : (i += word) std.mem.reverse(u8, mut[i..][0..word]);
        return mut;
    }
};

/// The rules at `indent` from `flat[i.*]` on, each with its children (the
/// following rules indented deeper), copied into the arena.
fn buildMatchlets(db: *Db, flat: []const FlatMatchlet, i: *usize, indent: u32) ![]const Matchlet {
    var out: std.ArrayList(Matchlet) = .empty;
    while (i.* < flat.len and flat[i.*].indent >= indent) {
        if (flat[i.*].indent > indent) {
            // A child without a parent at this level: skip it.
            i.* += 1;
            continue;
        }
        var m = flat[i.*].m;
        m.value = try db.a().dupe(u8, m.value);
        if (m.mask) |mk| m.mask = try db.a().dupe(u8, mk);
        i.* += 1;
        m.children = try buildMatchlets(db, flat, i, indent + 1);
        try out.append(db.a(), m);
    }
    return out.items;
}

/// Whether any rule matches `head` (a rule with children needs one of
/// them to match too).
fn magicMatches(rules: []const Matchlet, head: []const u8) bool {
    for (rules) |m| {
        if (!matchletHits(m, head)) continue;
        if (m.children.len == 0 or magicMatches(m.children, head)) return true;
    }
    return false;
}

fn matchletHits(m: Matchlet, head: []const u8) bool {
    var off: usize = m.offset;
    const end = off + m.range;
    while (off < end and off + m.value.len <= head.len) : (off += 1) {
        const got = head[off..][0..m.value.len];
        if (m.mask) |mk| {
            for (got, m.value, mk) |g, v, k| {
                if (g & k != v & k) break;
            } else return true;
        } else if (std.mem.eql(u8, got, m.value)) return true;
    }
    return false;
}

/// Whether the bytes read as text: UTF-8 (a sequence cut off at the end
/// is fine), no NUL, and few control characters.
pub fn looksLikeText(head: []const u8) bool {
    if (std.mem.indexOfScalar(u8, head, 0) != null) return false;
    var bad: usize = 0;
    for (head) |b| bad += @intFromBool(b < 0x09 or (b > 0x0d and b < 0x20 and b != 0x1b) or b == 0x7f);
    if (bad * 20 > head.len) return false;
    // Drop a sequence cut short by the end of the read.
    var end = head.len;
    var back: usize = 0;
    while (back < 3 and end > back and head[end - back - 1] & 0xc0 == 0x80) back += 1;
    if (end > back) {
        const lead = head[end - back - 1];
        const need: usize = if (lead >= 0xf0) 3 else if (lead >= 0xe0) 2 else if (lead >= 0xc0) 1 else 0;
        if (need > back) end -= back + 1;
    }
    return std.unicode.utf8ValidateSlice(head[0..end]);
}

fn readAll(gpa: Allocator, path: []const u8) ?[]u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        list.appendSlice(gpa, chunk[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

fn readFile(path: []const u8, buf: []u8) ?[]u8 {
    var zbuf: [linux.PATH_MAX]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
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

fn eachLine(gpa: Allocator, dir: []const u8, file: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
    var pbuf: [linux.PATH_MAX]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/mime/{s}", .{ dir, file });
    const data = readAll(gpa, p) orelse return;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try f(ctx, line);
    }
}

fn putHit(db: *Db, map: *std.StringHashMapUnmanaged(Hits), key: []const u8, hit: Hit) !void {
    const gop = try map.getOrPut(db.a(), key);
    if (!gop.found_existing) {
        gop.key_ptr.* = try db.a().dupe(u8, key);
        gop.value_ptr.* = .{};
    }
    // A type listed again (in another data directory): the first listing
    // (the more important directory) stands.
    for (gop.value_ptr.list.items) |h| if (h.id == hit.id) return;
    try gop.value_ptr.list.append(db.a(), hit);
}

fn globLine(db: *Db, line: []const u8) !void {
    // weight:type:glob[:flags]
    var it = std.mem.splitScalar(u8, line, ':');
    const weight = std.fmt.parseInt(u16, it.next() orelse return, 10) catch return;
    const t = it.next() orelse return;
    const glob = it.next() orelse return;
    const flags = it.next() orelse "";
    const cs = std.mem.indexOf(u8, flags, "cs") != null;
    const id = try db.intern(t);
    const hit: Hit = .{ .id = id, .weight = weight };
    const special = std.mem.indexOfAny(u8, glob, "*?[") != null;
    if (!special) {
        if (cs) try putHit(db, &db.literal, glob, hit) else {
            var lb: [256]u8 = undefined;
            if (glob.len > lb.len) return;
            try putHit(db, &db.literal_ci, std.ascii.lowerString(&lb, glob), hit);
        }
        return;
    }
    if (std.mem.startsWith(u8, glob, "*.") and std.mem.indexOfAny(u8, glob[2..], "*?[") == null) {
        const ext = glob[2..];
        if (cs) try putHit(db, &db.ext_cs, ext, hit) else {
            var lb: [256]u8 = undefined;
            if (ext.len > lb.len) return;
            try putHit(db, &db.ext_ci, std.ascii.lowerString(&lb, ext), hit);
        }
        return;
    }
    var lb: [256]u8 = undefined;
    if (glob.len > lb.len) return;
    const pat = if (cs) glob else std.ascii.lowerString(&lb, glob);
    try db.complex.append(db.a(), .{ .pattern = try db.a().dupe(u8, pat), .id = id, .weight = weight, .case_sensitive = cs });
}

fn aliasLine(db: *Db, line: []const u8) !void {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return;
    const canonical = try db.intern(line[sp + 1 ..]);
    const gop = try db.aliases.getOrPut(db.a(), line[0..sp]);
    if (!gop.found_existing) gop.key_ptr.* = try db.a().dupe(u8, line[0..sp]);
    gop.value_ptr.* = canonical;
}

fn subclassLine(db: *Db, line: []const u8) !void {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return;
    const child = try db.intern(line[0..sp]);
    const parent = try db.intern(line[sp + 1 ..]);
    const gop = try db.parents.getOrPut(db.a(), child);
    if (!gop.found_existing) gop.value_ptr.* = &.{};
    for (gop.value_ptr.*) |p| if (p == parent) return;
    const grown = try db.a().alloc(Id, gop.value_ptr.len + 1);
    @memcpy(grown[0..gop.value_ptr.len], gop.value_ptr.*);
    grown[grown.len - 1] = parent;
    gop.value_ptr.* = grown;
}

const IconCtx = struct { db: *Db, map: *std.AutoHashMapUnmanaged(Id, []const u8) };

fn iconLine(ctx: IconCtx, line: []const u8) !void {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return;
    const id = try ctx.db.intern(line[0..colon]);
    try ctx.map.put(ctx.db.a(), id, try ctx.db.a().dupe(u8, line[colon + 1 ..]));
}

fn loadGlobsImpl(db: *Db, line: []const u8) anyerror!void {
    return globLine(db, line);
}

fn loadIconsImpl(ctx: IconCtx, line: []const u8) anyerror!void {
    return iconLine(ctx, line);
}

fn loadAliasImpl(db: *Db, line: []const u8) anyerror!void {
    return aliasLine(db, line);
}

fn loadSubclassImpl(db: *Db, line: []const u8) anyerror!void {
    return subclassLine(db, line);
}

/// fnmatch(3) without flags: `*`, `?`, and `[...]` classes.
pub fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_i = i;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    i += 1;
                    continue;
                },
                '[' => {
                    if (matchClass(pattern, &p, s[i])) {
                        i += 1;
                        continue;
                    }
                },
                else => if (pattern[p] == s[i]) {
                    p += 1;
                    i += 1;
                    continue;
                },
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_i += 1;
            i = star_i;
            continue;
        }
        return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn matchClass(pattern: []const u8, p: *usize, ch: u8) bool {
    var j = p.* + 1;
    var negate = false;
    if (j < pattern.len and (pattern[j] == '!' or pattern[j] == '^')) {
        negate = true;
        j += 1;
    }
    var matched = false;
    var first = true;
    while (j < pattern.len and (first or pattern[j] != ']')) : (first = false) {
        if (j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j + 2] != ']') {
            if (ch >= pattern[j] and ch <= pattern[j + 2]) matched = true;
            j += 3;
        } else {
            if (ch == pattern[j]) matched = true;
            j += 1;
        }
    }
    if (j >= pattern.len) return false;
    p.* = j + 1;
    return matched != negate;
}

/// The type of a file's content, from its first bytes: for names no glob
/// matches. `head` may be empty (an empty file).
pub fn sniff(db: *Db, head: []const u8, mode: u32) Id {
    if (head.len == 0) return zerosize;
    const magic = [_]struct { []const u8, []const u8 }{
        .{ "\x7fELF", "application/x-executable" },
        .{ "\x89PNG\r\n\x1a\n", "image/png" },
        .{ "\xff\xd8\xff", "image/jpeg" },
        .{ "GIF8", "image/gif" },
        .{ "%PDF-", "application/pdf" },
        .{ "PK\x03\x04", "application/zip" },
        .{ "\x1f\x8b", "application/gzip" },
        .{ "\xfd7zXZ\x00", "application/x-xz" },
        .{ "\x28\xb5\x2f\xfd", "application/zstd" },
        .{ "BZh", "application/x-bzip" },
        .{ "7z\xbc\xaf\x27\x1c", "application/x-7z-compressed" },
        .{ "OggS", "audio/ogg" },
        .{ "fLaC", "audio/flac" },
        .{ "ID3", "audio/mpeg" },
        .{ "\x1aE\xdf\xa3", "video/x-matroska" },
        .{ "<?xml", "application/xml" },
        .{ "<svg", "image/svg+xml" },
    };
    for (magic) |m| if (std.mem.startsWith(u8, head, m[0])) {
        if (std.mem.eql(u8, m[1], "application/x-executable") and head.len > 17 and head[16] == 3) {
            // ET_DYN: a PIE executable or a shared library; the mode tells.
            return if (mode & 0o111 != 0) executable else db.intern("application/x-sharedlib") catch octet_stream;
        }
        return db.lookup(m[1]) orelse (db.intern(m[1]) catch octet_stream);
    };
    if (std.mem.startsWith(u8, head, "#!")) {
        const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
        const line = head[0..nl];
        if (std.mem.indexOf(u8, line, "python") != null) return db.lookup("text/x-python") orelse shellscript;
        if (std.mem.indexOf(u8, line, "perl") != null) return db.lookup("application/x-perl") orelse shellscript;
        return shellscript;
    }
    if (std.mem.indexOfScalar(u8, head, 0) != null) return octet_stream;
    // Mostly printable: text.
    var bad: usize = 0;
    for (head) |b| if (b < 0x09 or (b > 0x0d and b < 0x20 and b != 0x1b)) {
        bad += 1;
    };
    return if (bad * 20 > head.len) octet_stream else text_plain;
}

const testing = std.testing;

test "globs" {
    try testing.expect(globMatch("*.so.[0-9]*", "libx.so.1"));
    try testing.expect(!globMatch("*.so.[0-9]*", "libx.so.a"));
    try testing.expect(globMatch("README*", "README.md"));
    try testing.expect(globMatch("[Mm]akefile", "makefile"));
    try testing.expect(!globMatch("a?c", "ac"));
    try testing.expect(globMatch("*", ""));
}

test "database" {
    const gpa = testing.allocator;
    var tmp_buf: [64]u8 = undefined;
    const S = struct {
        extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
        extern "c" fn system(cmd: [*:0]const u8) c_int;
    };
    const tmpl = try std.fmt.bufPrintSentinel(&tmp_buf, "/tmp/siv-files-mime-XXXXXX", .{}, 0);
    _ = S.mkdtemp(tmpl.ptr) orelse return error.Unexpected;
    var cmd_buf: [2048]u8 = undefined;
    const cmd = try std.fmt.bufPrintSentinel(&cmd_buf,
        \\mkdir -p {0s}/mime/text && printf '50:text/x-csrc:*.c\n50:application/x-compressed-tar:*.tar.gz\n50:application/gzip:*.gz\n50:text/x-makefile:makefile\n50:text/x-c++src:*.C:cs\n10:application/x-sharedlib:*.so.[0-9]*\n' > {0s}/mime/globs2 && printf 'text/x-csrc text/plain\n' > {0s}/mime/subclasses && printf 'application/x-gzip application/gzip\n' > {0s}/mime/aliases && printf '<mime-type><comment>C source code</comment><comment xml:lang="de">C-Quelltext</comment></mime-type>' > {0s}/mime/text/x-csrc.xml
    , .{tmpl}, 0);
    try testing.expectEqual(@as(c_int, 0), S.system(cmd.ptr));
    defer {
        const rm = std.fmt.bufPrintSentinel(&cmd_buf, "rm -rf {s}", .{tmpl}, 0) catch unreachable;
        _ = S.system(rm.ptr);
    }
    const db = try load(gpa, &.{tmpl});
    defer {
        db.deinit();
        gpa.destroy(db);
    }
    const csrc = db.lookup("text/x-csrc").?;
    try testing.expectEqual(csrc, db.byName("main.c").?);
    try testing.expectEqual(db.lookup("text/x-c++src").?, db.byName("x.C").?);
    try testing.expectEqual(db.lookup("application/x-compressed-tar").?, db.byName("a.tar.gz").?);
    try testing.expectEqual(db.lookup("application/gzip").?, db.byName("a.gz").?);
    try testing.expectEqual(db.lookup("application/gzip").?, db.lookup("application/x-gzip").?);
    try testing.expectEqual(db.lookup("text/x-makefile").?, db.byName("Makefile").?);
    try testing.expectEqual(db.lookup("application/x-sharedlib").?, db.byName("libz.so.1").?);
    try testing.expect(db.byName("noext") == null);
    try testing.expect(db.isA(csrc, text_plain));
    try testing.expectEqualStrings("C source code", db.comment(csrc));
    var ib: [256]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, db.iconNames(csrc, &ib), "text-x-csrc\ntext-x-generic"));
    try testing.expectEqual(text_plain, sniff(db, "hello\nworld\n", 0o644));
    try testing.expectEqual(shellscript, sniff(db, "#!/bin/sh\necho\n", 0o755));
    try testing.expectEqual(octet_stream, sniff(db, "a\x00b", 0o644));
}

test "names several types claim are settled by content" {
    const gpa = testing.allocator;
    var tmp_buf: [64]u8 = undefined;
    const S = struct {
        extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
        extern "c" fn system(cmd: [*:0]const u8) c_int;
        fn write(dir: []const u8, file: []const u8, bytes: []const u8) !void {
            var pb: [256]u8 = undefined;
            const p = try std.fmt.bufPrintSentinel(&pb, "{s}/mime/{s}", .{ dir, file }, 0);
            const rc = linux.openat(linux.AT.FDCWD, p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
            if (linux.errno(rc) != .SUCCESS) return error.Unexpected;
            defer _ = linux.close(@intCast(rc));
            if (linux.write(@intCast(rc), bytes.ptr, bytes.len) != bytes.len) return error.Unexpected;
        }
    };
    const tmpl = try std.fmt.bufPrintSentinel(&tmp_buf, "/tmp/siv-files-mime-XXXXXX", .{}, 0);
    _ = S.mkdtemp(tmpl.ptr) orelse return error.Unexpected;
    var cmd_buf: [256]u8 = undefined;
    defer {
        const rm = std.fmt.bufPrintSentinel(&cmd_buf, "rm -rf {s}", .{tmpl}, 0) catch unreachable;
        _ = S.system(rm.ptr);
    }
    const mk = try std.fmt.bufPrintSentinel(&cmd_buf, "mkdir -p {s}/mime", .{tmpl}, 0);
    try testing.expectEqual(@as(c_int, 0), S.system(mk.ptr));
    // As in shared-mime-info 2.5, plus two made-up types for word sizes
    // and masks, and two text types that only a glob tells apart.
    try S.write(tmpl, "globs2",
        \\50:text/vnd.trolltech.linguist:*.ts
        \\50:video/mp2t:*.ts
        \\40:application/typescript:*.ts
        \\50:application/x-word:*.w
        \\50:application/x-masked:*.w
        \\50:application/json:*.json
        \\50:application/schema+json:*.json
        \\50:text/x-csrc:*.c
        \\
    );
    try S.write(tmpl, "subclasses",
        \\application/typescript text/plain
        \\text/vnd.trolltech.linguist application/xml
        \\application/xml text/plain
        \\application/json text/plain
        \\application/schema+json application/json
        \\
    );
    try S.write(tmpl, "magic", "MIME-Magic\x00\n" ++
        "[50:text/vnd.trolltech.linguist]\n>0=\x00\x04<TS +257\n" ++
        "[50:video/mp2t]\n>0=\x00\x01G\n1>188=\x00\x01G\n2>376=\x00\x01G\n" ++
        "[10:application/typescript]\n>0=\x00\x02//\n>0=\x00\x05class\n" ++
        // Host-order 0x1234 (bytes 34 12 here), and any byte 0x4_.
        "[60:application/x-word]\n>0=\x00\x02\x12\x34~2\n" ++
        "[50:application/x-masked]\n>0=\x00\x01\x40&\xf0\n" ++
        "[50:text/x-csrc]\n>0=\x00\x08#include\n");
    const db = try load(gpa, &.{tmpl});
    defer {
        db.deinit();
        gpa.destroy(db);
    }
    const ts = db.lookup("application/typescript").?;
    const mp2t = db.lookup("video/mp2t").?;
    const linguist = db.lookup("text/vnd.trolltech.linguist").?;
    const hits = db.match("app.ts").?.contested.?;
    try testing.expectEqual(@as(usize, 3), hits.len);
    // Text that no magic claims: TypeScript, not Linguist (whose magic
    // failed) or MPEG-TS (binary).
    try testing.expectEqual(ts, db.settle(hits, "import { a } from './b';\nexport const x = a;\n"));
    try testing.expectEqual(ts, db.settle(hits, "// a comment\nlet x = 1;\n"));
    try testing.expectEqual(ts, db.settle(hits, ""));
    var stream: [800]u8 = @splat(0xff);
    for ([_]usize{ 0, 188, 376, 564, 752 }) |o| stream[o] = 0x47;
    try testing.expectEqual(mp2t, db.settle(hits, &stream));
    // Two sync bytes are not a stream, but binary is binary.
    stream[376] = 0;
    try testing.expectEqual(mp2t, db.settle(hits, &stream));
    try testing.expectEqual(linguist, db.settle(hits, "<?xml version=\"1.0\"?>\n<!DOCTYPE TS>\n<TS version=\"2.1\">\n"));
    // An older database without TypeScript: plain text.
    try testing.expectEqual(text_plain, db.settle(&.{ hits[0], hits[1] }, "import { a } from './b';\n"));
    const w = db.match("x.w").?.contested.?;
    try testing.expectEqual(db.lookup("application/x-word").?, db.settle(w, "\x34\x12\x00"));
    try testing.expectEqual(db.lookup("application/x-masked").?, db.settle(w, "\x4f\x00"));
    // Only a glob tells these apart: no read, the first one listed.
    const json = db.match("a.json").?;
    try testing.expect(json.contested == null);
    try testing.expectEqual(db.lookup("application/json").?, json.id);
    // Magic is kept only for contested names' types.
    try testing.expect(!db.magic.contains(db.lookup("text/x-csrc").?));
    try testing.expect(db.match("main.c").?.contested == null);
}

test "text or binary" {
    try testing.expect(looksLikeText("plain ascii\n\ttabbed\n"));
    try testing.expect(looksLikeText("caf\xc3\xa9 au lait"));
    // A read that ends inside a character.
    try testing.expect(looksLikeText("caf\xc3"));
    try testing.expect(looksLikeText("\xe2\x82"));
    try testing.expect(!looksLikeText("bad \xff\xfe utf-8"));
    try testing.expect(!looksLikeText("nul\x00inside"));
    try testing.expect(!looksLikeText("\x47\x01\x02\x03\x04\x05\x06"));
}
