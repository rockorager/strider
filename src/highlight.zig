//! Syntax coloring for text previews: a small tokenizer that knows the
//! comment, string, and keyword rules of common languages, chosen by file
//! name. It reports byte ranges with a class; the preview turns classes
//! into themed text spans, so colors follow light, dark, and high
//! contrast. Plain Zig: it runs on a worker thread.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Class = enum(u8) { keyword, type, string, number, comment, heading, added, removed, punct };

pub const Span = struct { start: u32, end: u32, class: Class };

pub const Lang = struct {
    name: []const u8,
    line_comments: []const []const u8 = &.{},
    block_comment: ?[2][]const u8 = null,
    quotes: []const u8 = "\"'",
    keywords: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    /// Capitalized words are types (Rust, Go, Zig, Java, ...).
    capital_types: bool = false,
    kind: enum { code, markdown, diff, ini } = .code,
};

const c_keywords = [_][]const u8{ "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static", "struct", "switch", "typedef", "union", "volatile", "while", "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#else", "#elif", "#pragma", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "try", "catch", "throw", "using", "nullptr", "true", "false", "NULL" };
const c_types = [_][]const u8{ "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "auto" };
const zig_keywords = [_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "break", "continue", "defer", "errdefer", "try", "catch", "orelse", "and", "or", "struct", "enum", "union", "error", "test", "comptime", "inline", "extern", "export", "packed", "align", "callconv", "noreturn", "unreachable", "undefined", "null", "true", "false", "usingnamespace", "threadlocal", "volatile", "allowzero", "anytype", "opaque", "suspend", "resume", "nosuspend", "async", "await", "linksection", "noalias" };
const zig_types = [_][]const u8{ "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f80", "f128", "bool", "void", "type", "anyerror", "anyopaque", "c_int", "c_uint", "c_long", "c_char", "comptime_int", "comptime_float" };
const rust_keywords = [_][]const u8{ "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while" };
const rust_types = [_][]const u8{ "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box" };
const go_keywords = [_][]const u8{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false" };
const go_types = [_][]const u8{ "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any" };
const py_keywords = [_][]const u8{ "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "None", "True", "False", "self" };
const py_types = [_][]const u8{ "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object" };
const js_keywords = [_][]const u8{ "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield", "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "private", "public", "protected", "readonly" };
const js_types = [_][]const u8{ "string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol" };
const lua_keywords = [_][]const u8{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" };
const sh_keywords = [_][]const u8{ "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "return", "local", "export", "readonly", "set", "unset", "shift", "exit", "echo", "cd", "source", "alias", "trap", "eval", "exec", "true", "false" };
const json_keywords = [_][]const u8{ "true", "false", "null" };
const toml_keywords = [_][]const u8{ "true", "false" };
const java_keywords = [_][]const u8{ "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import", "instanceof", "interface", "native", "new", "package", "private", "protected", "public", "return", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try", "volatile", "while", "true", "false", "null", "val", "var", "fun", "object", "when", "override" };
const java_types = [_][]const u8{ "boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "String" };
const rb_keywords = [_][]const u8{ "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require" };
const css_keywords = [_][]const u8{ "important", "inherit", "initial", "none", "auto" };
const sql_keywords = [_][]const u8{ "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "index", "join", "left", "right", "inner", "outer", "on", "and", "or", "not", "null", "as", "order", "by", "group", "having", "limit", "primary", "key", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "PRIMARY", "KEY" };

pub const langs = struct {
    pub const c: Lang = .{ .name = "C", .line_comments = &.{"//"}, .block_comment = .{ "/*", "*/" }, .keywords = &c_keywords, .types = &c_types };
    pub const zig: Lang = .{ .name = "Zig", .line_comments = &.{"//"}, .keywords = &zig_keywords, .types = &zig_types, .capital_types = true };
    pub const rust: Lang = .{ .name = "Rust", .line_comments = &.{"//"}, .block_comment = .{ "/*", "*/" }, .keywords = &rust_keywords, .types = &rust_types, .capital_types = true, .quotes = "\"" };
    pub const go: Lang = .{ .name = "Go", .line_comments = &.{"//"}, .block_comment = .{ "/*", "*/" }, .keywords = &go_keywords, .types = &go_types, .quotes = "\"'`" };
    pub const python: Lang = .{ .name = "Python", .line_comments = &.{"#"}, .keywords = &py_keywords, .types = &py_types, .capital_types = true };
    pub const js: Lang = .{ .name = "JavaScript", .line_comments = &.{"//"}, .block_comment = .{ "/*", "*/" }, .keywords = &js_keywords, .types = &js_types, .quotes = "\"'`", .capital_types = true };
    pub const lua: Lang = .{ .name = "Lua", .line_comments = &.{"--"}, .keywords = &lua_keywords };
    pub const sh: Lang = .{ .name = "Shell", .line_comments = &.{"#"}, .keywords = &sh_keywords };
    pub const json: Lang = .{ .name = "JSON", .keywords = &json_keywords, .quotes = "\"" };
    pub const toml: Lang = .{ .name = "TOML", .line_comments = &.{"#"}, .keywords = &toml_keywords, .kind = .ini };
    pub const yaml: Lang = .{ .name = "YAML", .line_comments = &.{"#"}, .keywords = &toml_keywords };
    pub const java: Lang = .{ .name = "Java", .line_comments = &.{"//"}, .block_comment = .{ "/*", "*/" }, .keywords = &java_keywords, .types = &java_types, .capital_types = true };
    pub const ruby: Lang = .{ .name = "Ruby", .line_comments = &.{"#"}, .keywords = &rb_keywords, .capital_types = true };
    pub const css: Lang = .{ .name = "CSS", .block_comment = .{ "/*", "*/" }, .keywords = &css_keywords };
    pub const html: Lang = .{ .name = "HTML", .block_comment = .{ "<!--", "-->" }, .quotes = "\"'" };
    pub const sql: Lang = .{ .name = "SQL", .line_comments = &.{"--"}, .block_comment = .{ "/*", "*/" }, .keywords = &sql_keywords };
    pub const make: Lang = .{ .name = "Makefile", .line_comments = &.{"#"}, .quotes = "\"'" };
    pub const markdown: Lang = .{ .name = "Markdown", .kind = .markdown };
    pub const diff: Lang = .{ .name = "Diff", .kind = .diff };
    pub const ini: Lang = .{ .name = "INI", .line_comments = &.{ "#", ";" }, .kind = .ini };
};

const ByExt = struct { []const u8, *const Lang };
const by_ext = [_]ByExt{
    .{ "c", &langs.c },        .{ "h", &langs.c },          .{ "cc", &langs.c },        .{ "cpp", &langs.c },
    .{ "cxx", &langs.c },      .{ "hpp", &langs.c },        .{ "hh", &langs.c },        .{ "zig", &langs.zig },
    .{ "zon", &langs.zig },    .{ "rs", &langs.rust },      .{ "go", &langs.go },       .{ "py", &langs.python },
    .{ "js", &langs.js },      .{ "mjs", &langs.js },       .{ "cjs", &langs.js },      .{ "ts", &langs.js },
    .{ "tsx", &langs.js },     .{ "jsx", &langs.js },       .{ "lua", &langs.lua },     .{ "sh", &langs.sh },
    .{ "bash", &langs.sh },    .{ "zsh", &langs.sh },       .{ "fish", &langs.sh },     .{ "json", &langs.json },
    .{ "toml", &langs.toml },  .{ "yaml", &langs.yaml },    .{ "yml", &langs.yaml },    .{ "java", &langs.java },
    .{ "kt", &langs.java },    .{ "scala", &langs.java },   .{ "cs", &langs.java },     .{ "swift", &langs.java },
    .{ "rb", &langs.ruby },    .{ "css", &langs.css },      .{ "scss", &langs.css },    .{ "html", &langs.html },
    .{ "htm", &langs.html },   .{ "xml", &langs.html },     .{ "svg", &langs.html },    .{ "sql", &langs.sql },
    .{ "mk", &langs.make },    .{ "md", &langs.markdown },  .{ "markdown", &langs.markdown }, .{ "diff", &langs.diff },
    .{ "patch", &langs.diff }, .{ "ini", &langs.ini },      .{ "conf", &langs.ini },    .{ "cfg", &langs.ini },
    .{ "desktop", &langs.ini }, .{ "service", &langs.ini }, .{ "nix", &langs.sh },      .{ "pl", &langs.sh },
};

/// The language of a file by its name, or null for plain text.
pub fn detect(name: []const u8, head: []const u8) ?*const Lang {
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
    if (std.mem.eql(u8, base, "Makefile") or std.mem.eql(u8, base, "makefile") or std.mem.eql(u8, base, "GNUmakefile")) return &langs.make;
    if (std.mem.eql(u8, base, "PKGBUILD") or std.mem.startsWith(u8, base, ".bash") or std.mem.eql(u8, base, ".profile") or std.mem.eql(u8, base, ".zshrc")) return &langs.sh;
    if (std.mem.eql(u8, base, "CMakeLists.txt")) return &langs.sh;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| if (dot > 0) {
        var buf: [16]u8 = undefined;
        const ext_raw = base[dot + 1 ..];
        if (ext_raw.len <= buf.len) {
            const ext = std.ascii.lowerString(&buf, ext_raw);
            for (by_ext) |e| if (std.mem.eql(u8, e[0], ext)) return e[1];
        }
    };
    // A script's interpreter line.
    if (std.mem.startsWith(u8, head, "#!")) {
        const line = head[0 .. std.mem.indexOfScalar(u8, head, '\n') orelse head.len];
        if (std.mem.indexOf(u8, line, "python") != null) return &langs.python;
        if (std.mem.indexOf(u8, line, "lua") != null) return &langs.lua;
        if (std.mem.indexOf(u8, line, "node") != null) return &langs.js;
        if (std.mem.indexOf(u8, line, "ruby") != null) return &langs.ruby;
        if (std.mem.indexOf(u8, line, "sh") != null) return &langs.sh;
    }
    return null;
}

/// Colors `text` as `lang`: spans in order, not overlapping.
pub fn highlight(gpa: Allocator, lang: *const Lang, text: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    switch (lang.kind) {
        .markdown => try markdown(gpa, &out, text),
        .diff => try diff(gpa, &out, text),
        .code, .ini => try code(gpa, &out, lang, text),
    }
    return out.toOwnedSlice(gpa);
}

fn add(gpa: Allocator, out: *std.ArrayList(Span), start: usize, end: usize, class: Class) !void {
    if (end <= start) return;
    try out.append(gpa, .{ .start = @intCast(start), .end = @intCast(end), .class = class });
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

fn code(gpa: Allocator, out: *std.ArrayList(Span), lang: *const Lang, text: []const u8) !void {
    var i: usize = 0;
    var line_start = true;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            line_start = true;
            i += 1;
            continue;
        }
        // INI and TOML: [sections] and keys.
        if (lang.kind == .ini and line_start) {
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
            if (j < text.len and text[j] == '[') {
                const e = std.mem.indexOfScalarPos(u8, text, j, '\n') orelse text.len;
                try add(gpa, out, j, e, .heading);
                i = e;
                continue;
            }
            const eq = std.mem.indexOfAnyPos(u8, text, j, "=\n") orelse text.len;
            if (eq < text.len and text[eq] == '=' and !isComment(lang, text[j..])) {
                try add(gpa, out, j, eq, .keyword);
                i = eq;
                line_start = false;
                continue;
            }
        }
        if (ch != ' ' and ch != '\t') line_start = false;
        // Comments.
        if (lineComment(lang, text[i..])) {
            const e = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            try add(gpa, out, i, e, .comment);
            i = e;
            continue;
        }
        if (lang.block_comment) |bc| if (std.mem.startsWith(u8, text[i..], bc[0])) {
            const e = if (std.mem.indexOfPos(u8, text, i + bc[0].len, bc[1])) |x| x + bc[1].len else text.len;
            try add(gpa, out, i, e, .comment);
            i = e;
            continue;
        };
        // Strings, to the closing quote on the same line (or the next
        // lines for backquotes and Python's triple quotes).
        if (std.mem.indexOfScalar(u8, lang.quotes, ch) != null) {
            // An apostrophe inside a word is not a quote (Rust lifetimes,
            // English in comments of languages without char literals).
            if (ch == '\'' and i > 0 and isIdent(text[i - 1])) {
                i += 1;
                continue;
            }
            const triple = i + 2 < text.len and text[i + 1] == ch and text[i + 2] == ch;
            var j = i + if (triple) @as(usize, 3) else 1;
            while (j < text.len) : (j += 1) {
                if (text[j] == '\\') {
                    j += 1;
                    continue;
                }
                if (triple) {
                    if (j + 2 < text.len and text[j] == ch and text[j + 1] == ch and text[j + 2] == ch) {
                        j += 3;
                        break;
                    }
                    continue;
                }
                if (text[j] == ch) {
                    j += 1;
                    break;
                }
                if (text[j] == '\n' and ch != '`') break;
            }
            try add(gpa, out, i, @min(j, text.len), .string);
            i = @min(j, text.len);
            continue;
        }
        // Numbers.
        if (std.ascii.isDigit(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            var j = i + 1;
            while (j < text.len and (isIdent(text[j]) or text[j] == '.')) j += 1;
            try add(gpa, out, i, j, .number);
            i = j;
            continue;
        }
        // Words: keywords and types. "#include" and "@import" count as
        // words.
        if (isIdent(ch) or ch == '#' or ch == '@') {
            var j = i + 1;
            while (j < text.len and isIdent(text[j])) j += 1;
            if (ch == '@' and j < text.len and text[j] == '"') {
                i = j;
                continue;
            }
            const word = text[i..j];
            if (ch == '@') {
                try add(gpa, out, i, j, .keyword);
            } else if (contains(lang.keywords, word)) {
                try add(gpa, out, i, j, .keyword);
            } else if (contains(lang.types, word) or (lang.capital_types and std.ascii.isUpper(word[0]) and word.len > 1 and hasLower(word))) {
                try add(gpa, out, i, j, .type);
            }
            i = j;
            continue;
        }
        i += 1;
    }
}

fn hasLower(s: []const u8) bool {
    for (s) |ch| if (std.ascii.isLower(ch)) return true;
    return false;
}

fn isComment(lang: *const Lang, rest: []const u8) bool {
    return lineComment(lang, rest);
}

fn lineComment(lang: *const Lang, rest: []const u8) bool {
    for (lang.line_comments) |lc| if (std.mem.startsWith(u8, rest, lc)) {
        // "#!" and "#include" are not comments in C; shells' "#" always is.
        return true;
    };
    return false;
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn markdown(gpa: Allocator, out: *std.ArrayList(Span), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var fenced = false;
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        const end = start + line.len;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            fenced = !fenced;
            try add(gpa, out, start, end, .comment);
            continue;
        }
        if (fenced) {
            try add(gpa, out, start, end, .string);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            try add(gpa, out, start, end, .heading);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, ">")) {
            try add(gpa, out, start, end, .comment);
            continue;
        }
        // List bullets, inline code, and links.
        var i: usize = 0;
        if (trimmed.len > 1 and (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and trimmed[1] == ' ') {
            const b = start + (line.len - trimmed.len);
            try add(gpa, out, b, b + 1, .keyword);
        }
        while (i < line.len) {
            if (line[i] == '`') {
                const e = std.mem.indexOfScalarPos(u8, line, i + 1, '`') orelse break;
                try add(gpa, out, start + i, start + e + 1, .string);
                i = e + 1;
                continue;
            }
            if (line[i] == '[') {
                if (std.mem.indexOfPos(u8, line, i, "](")) |mid| if (std.mem.indexOfScalarPos(u8, line, mid, ')')) |e| {
                    try add(gpa, out, start + i, start + mid + 1, .type);
                    try add(gpa, out, start + mid + 1, start + e + 1, .comment);
                    i = e + 1;
                    continue;
                };
            }
            i += 1;
        }
    }
}

fn diff(gpa: Allocator, out: *std.ArrayList(Span), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        const end = start + line.len;
        if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---") or std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "index ")) {
            try add(gpa, out, start, end, .heading);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            try add(gpa, out, start, end, .type);
        } else if (std.mem.startsWith(u8, line, "+")) {
            try add(gpa, out, start, end, .added);
        } else if (std.mem.startsWith(u8, line, "-")) {
            try add(gpa, out, start, end, .removed);
        }
    }
}

const testing = std.testing;

fn classAt(spans: []const Span, text: []const u8, word: []const u8) ?Class {
    const at = std.mem.indexOf(u8, text, word) orelse return null;
    for (spans) |s| if (s.start <= at and at < s.end) return s.class;
    return null;
}

test "detects languages by name and interpreter" {
    try testing.expectEqualStrings("Zig", detect("main.zig", "").?.name);
    try testing.expectEqualStrings("C", detect("/x/y/foo.H", "").?.name);
    try testing.expectEqualStrings("Python", detect("run", "#!/usr/bin/env python3\n").?.name);
    try testing.expectEqualStrings("Makefile", detect("Makefile", "").?.name);
    try testing.expect(detect("notes.txt", "hello") == null);
}

test "zig: keywords, types, strings, numbers, comments" {
    const src = "const x: u32 = 42; // answer\nconst s = \"a // b\";\nfn f(a: Foo) void {}\n";
    const spans = try highlight(testing.allocator, &langs.zig, src);
    defer testing.allocator.free(spans);
    try testing.expectEqual(Class.keyword, classAt(spans, src, "const").?);
    try testing.expectEqual(Class.type, classAt(spans, src, "u32").?);
    try testing.expectEqual(Class.number, classAt(spans, src, "42").?);
    try testing.expectEqual(Class.comment, classAt(spans, src, "// answer").?);
    // A comment marker inside a string is the string's.
    try testing.expectEqual(Class.string, classAt(spans, src, "a // b").?);
    try testing.expectEqual(Class.type, classAt(spans, src, "Foo").?);
    // Spans are ordered and disjoint.
    var last: u32 = 0;
    for (spans) |s| {
        try testing.expect(s.start >= last and s.end > s.start);
        last = s.end;
    }
}

test "c block comments and markdown" {
    const src = "int a; /* multi\nline */ return 0;";
    const spans = try highlight(testing.allocator, &langs.c, src);
    defer testing.allocator.free(spans);
    try testing.expectEqual(Class.comment, classAt(spans, src, "line */").?);
    try testing.expectEqual(Class.keyword, classAt(spans, src, "return").?);
    const md = "# Title\nSome `code` and [a link](http://x).\n```\nfenced\n```\n";
    const ms = try highlight(testing.allocator, &langs.markdown, md);
    defer testing.allocator.free(ms);
    try testing.expectEqual(Class.heading, classAt(ms, md, "Title").?);
    try testing.expectEqual(Class.string, classAt(ms, md, "`code`").?);
    try testing.expectEqual(Class.string, classAt(ms, md, "fenced").?);
}
