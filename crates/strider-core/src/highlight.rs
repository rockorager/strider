//! Syntax coloring for text previews: a small tokenizer that knows the comment, string, and
//! keyword rules of common languages, chosen by file name. It reports byte ranges with a
//! class; the preview turns classes into themed text spans, so colors follow light, dark, and
//! high contrast. Plain code with no UI: it runs on a worker thread.
//!
//! Text is bytes; every span starts and ends on an ASCII byte or the end of the text, so the
//! ranges of UTF-8 text fall on character boundaries.

/// What a span of text is, which the theme gives a color.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Class {
    Keyword,
    Type,
    String,
    Number,
    Comment,
    /// Markdown headings, INI sections, diff file headers.
    Heading,
    /// Diff lines.
    Added,
    Removed,
    Punct,
}

/// Bytes `start..end` of the text are `class`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub class: Class,
}

/// How a language is tokenized.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Comments, strings, numbers, and words.
    Code,
    /// By line: headings, quotes, fences, bullets, inline code, and links.
    Markdown,
    /// By line: file headers, hunks, added and removed lines.
    Diff,
    /// As code, with `[sections]` and the keys before `=` at the start of lines.
    Ini,
}

/// A language's rules.
#[derive(Debug, PartialEq, Eq)]
pub struct Lang {
    /// What it is called, to show.
    pub name: &'static str,
    /// What starts a comment to the end of the line.
    pub line_comments: &'static [&'static str],
    /// What opens and closes a comment that may span lines.
    pub block_comment: Option<(&'static str, &'static str)>,
    /// The characters that quote strings.
    pub quotes: &'static [u8],
    pub keywords: &'static [&'static str],
    pub types: &'static [&'static str],
    /// Capitalized words are types (Rust, Go, Zig, Java, ...).
    pub capital_types: bool,
    pub kind: Kind,
}

const C_KEYWORDS: &[&str] = &[
    "auto",
    "break",
    "case",
    "const",
    "continue",
    "default",
    "do",
    "else",
    "enum",
    "extern",
    "for",
    "goto",
    "if",
    "inline",
    "register",
    "restrict",
    "return",
    "sizeof",
    "static",
    "struct",
    "switch",
    "typedef",
    "union",
    "volatile",
    "while",
    "#include",
    "#define",
    "#if",
    "#ifdef",
    "#ifndef",
    "#endif",
    "#else",
    "#elif",
    "#pragma",
    "class",
    "namespace",
    "template",
    "typename",
    "public",
    "private",
    "protected",
    "virtual",
    "override",
    "new",
    "delete",
    "try",
    "catch",
    "throw",
    "using",
    "nullptr",
    "true",
    "false",
    "NULL",
];
const C_TYPES: &[&str] = &[
    "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool",
    "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t",
    "int32_t", "int64_t", "auto",
];
const ZIG_KEYWORDS: &[&str] = &[
    "const",
    "var",
    "fn",
    "pub",
    "return",
    "if",
    "else",
    "while",
    "for",
    "switch",
    "break",
    "continue",
    "defer",
    "errdefer",
    "try",
    "catch",
    "orelse",
    "and",
    "or",
    "struct",
    "enum",
    "union",
    "error",
    "test",
    "comptime",
    "inline",
    "extern",
    "export",
    "packed",
    "align",
    "callconv",
    "noreturn",
    "unreachable",
    "undefined",
    "null",
    "true",
    "false",
    "usingnamespace",
    "threadlocal",
    "volatile",
    "allowzero",
    "anytype",
    "opaque",
    "suspend",
    "resume",
    "nosuspend",
    "async",
    "await",
    "linksection",
    "noalias",
];
const ZIG_TYPES: &[&str] = &[
    "u8",
    "u16",
    "u32",
    "u64",
    "u128",
    "usize",
    "i8",
    "i16",
    "i32",
    "i64",
    "i128",
    "isize",
    "f16",
    "f32",
    "f64",
    "f80",
    "f128",
    "bool",
    "void",
    "type",
    "anyerror",
    "anyopaque",
    "c_int",
    "c_uint",
    "c_long",
    "c_char",
    "comptime_int",
    "comptime_float",
];
const RUST_KEYWORDS: &[&str] = &[
    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
    "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
    "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type",
    "unsafe", "use", "where", "while",
];
const RUST_TYPES: &[&str] = &[
    "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32",
    "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box",
];
const GO_KEYWORDS: &[&str] = &[
    "break",
    "case",
    "chan",
    "const",
    "continue",
    "default",
    "defer",
    "else",
    "fallthrough",
    "for",
    "func",
    "go",
    "goto",
    "if",
    "import",
    "interface",
    "map",
    "package",
    "range",
    "return",
    "select",
    "struct",
    "switch",
    "type",
    "var",
    "nil",
    "true",
    "false",
];
const GO_TYPES: &[&str] = &[
    "bool",
    "byte",
    "complex64",
    "complex128",
    "error",
    "float32",
    "float64",
    "int",
    "int8",
    "int16",
    "int32",
    "int64",
    "rune",
    "string",
    "uint",
    "uint8",
    "uint16",
    "uint32",
    "uint64",
    "uintptr",
    "any",
];
const PY_KEYWORDS: &[&str] = &[
    "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
    "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
    "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "None",
    "True", "False", "self",
];
const PY_TYPES: &[&str] = &[
    "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object",
];
const JS_KEYWORDS: &[&str] = &[
    "async",
    "await",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "debugger",
    "default",
    "delete",
    "do",
    "else",
    "export",
    "extends",
    "finally",
    "for",
    "from",
    "function",
    "if",
    "import",
    "in",
    "instanceof",
    "let",
    "new",
    "of",
    "return",
    "static",
    "super",
    "switch",
    "this",
    "throw",
    "try",
    "typeof",
    "var",
    "void",
    "while",
    "with",
    "yield",
    "null",
    "undefined",
    "true",
    "false",
    "interface",
    "type",
    "enum",
    "implements",
    "private",
    "public",
    "protected",
    "readonly",
];
const JS_TYPES: &[&str] = &[
    "string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol",
];
const LUA_KEYWORDS: &[&str] = &[
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];
const SH_KEYWORDS: &[&str] = &[
    "if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done",
    "in", "function", "return", "local", "export", "readonly", "set", "unset", "shift", "exit",
    "echo", "cd", "source", "alias", "trap", "eval", "exec", "true", "false",
];
const JSON_KEYWORDS: &[&str] = &["true", "false", "null"];
const TOML_KEYWORDS: &[&str] = &["true", "false"];
const JAVA_KEYWORDS: &[&str] = &[
    "abstract",
    "assert",
    "break",
    "case",
    "catch",
    "class",
    "const",
    "continue",
    "default",
    "do",
    "else",
    "enum",
    "extends",
    "final",
    "finally",
    "for",
    "goto",
    "if",
    "implements",
    "import",
    "instanceof",
    "interface",
    "native",
    "new",
    "package",
    "private",
    "protected",
    "public",
    "return",
    "static",
    "strictfp",
    "super",
    "switch",
    "synchronized",
    "this",
    "throw",
    "throws",
    "transient",
    "try",
    "volatile",
    "while",
    "true",
    "false",
    "null",
    "val",
    "var",
    "fun",
    "object",
    "when",
    "override",
];
const JAVA_TYPES: &[&str] = &[
    "boolean", "byte", "char", "double", "float", "int", "long", "short", "void", "String",
];
const RB_KEYWORDS: &[&str] = &[
    "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
    "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
    "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until",
    "when", "while", "yield", "require",
];
const CSS_KEYWORDS: &[&str] = &["important", "inherit", "initial", "none", "auto"];
const SQL_KEYWORDS: &[&str] = &[
    "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
    "table", "drop", "alter", "index", "join", "left", "right", "inner", "outer", "on", "and",
    "or", "not", "null", "as", "order", "by", "group", "having", "limit", "primary", "key",
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE",
    "TABLE", "DROP", "ALTER", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AND",
    "OR", "NOT", "NULL", "AS", "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "PRIMARY", "KEY",
];

/// The languages [`detect`] knows.
pub mod langs {
    use super::*;

    /// C and C++.
    pub static C: Lang = Lang {
        name: "C",
        line_comments: &["//"],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'",
        keywords: C_KEYWORDS,
        types: C_TYPES,
        capital_types: false,
        kind: Kind::Code,
    };
    pub static ZIG: Lang = Lang {
        name: "Zig",
        line_comments: &["//"],
        block_comment: None,
        quotes: b"\"'",
        keywords: ZIG_KEYWORDS,
        types: ZIG_TYPES,
        capital_types: true,
        kind: Kind::Code,
    };
    pub static RUST: Lang = Lang {
        name: "Rust",
        line_comments: &["//"],
        block_comment: Some(("/*", "*/")),
        // Not ', which starts lifetimes as often as characters.
        quotes: b"\"",
        keywords: RUST_KEYWORDS,
        types: RUST_TYPES,
        capital_types: true,
        kind: Kind::Code,
    };
    pub static GO: Lang = Lang {
        name: "Go",
        line_comments: &["//"],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'`",
        keywords: GO_KEYWORDS,
        types: GO_TYPES,
        capital_types: false,
        kind: Kind::Code,
    };
    pub static PYTHON: Lang = Lang {
        name: "Python",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: PY_KEYWORDS,
        types: PY_TYPES,
        capital_types: true,
        kind: Kind::Code,
    };
    /// JavaScript and TypeScript.
    pub static JS: Lang = Lang {
        name: "JavaScript",
        line_comments: &["//"],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'`",
        keywords: JS_KEYWORDS,
        types: JS_TYPES,
        capital_types: true,
        kind: Kind::Code,
    };
    pub static LUA: Lang = Lang {
        name: "Lua",
        line_comments: &["--"],
        block_comment: None,
        quotes: b"\"'",
        keywords: LUA_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static SH: Lang = Lang {
        name: "Shell",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: SH_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static JSON: Lang = Lang {
        name: "JSON",
        line_comments: &[],
        block_comment: None,
        quotes: b"\"",
        keywords: JSON_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static TOML: Lang = Lang {
        name: "TOML",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: TOML_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Ini,
    };
    pub static YAML: Lang = Lang {
        name: "YAML",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: TOML_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    /// Java and its kin: Kotlin, Scala, C#, Swift.
    pub static JAVA: Lang = Lang {
        name: "Java",
        line_comments: &["//"],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'",
        keywords: JAVA_KEYWORDS,
        types: JAVA_TYPES,
        capital_types: true,
        kind: Kind::Code,
    };
    pub static RUBY: Lang = Lang {
        name: "Ruby",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: RB_KEYWORDS,
        types: &[],
        capital_types: true,
        kind: Kind::Code,
    };
    pub static CSS: Lang = Lang {
        name: "CSS",
        line_comments: &[],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'",
        keywords: CSS_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    /// HTML, XML, and SVG.
    pub static HTML: Lang = Lang {
        name: "HTML",
        line_comments: &[],
        block_comment: Some(("<!--", "-->")),
        quotes: b"\"'",
        keywords: &[],
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static SQL: Lang = Lang {
        name: "SQL",
        line_comments: &["--"],
        block_comment: Some(("/*", "*/")),
        quotes: b"\"'",
        keywords: SQL_KEYWORDS,
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static MAKE: Lang = Lang {
        name: "Makefile",
        line_comments: &["#"],
        block_comment: None,
        quotes: b"\"'",
        keywords: &[],
        types: &[],
        capital_types: false,
        kind: Kind::Code,
    };
    pub static MARKDOWN: Lang = Lang {
        name: "Markdown",
        line_comments: &[],
        block_comment: None,
        quotes: b"\"'",
        keywords: &[],
        types: &[],
        capital_types: false,
        kind: Kind::Markdown,
    };
    pub static DIFF: Lang = Lang {
        name: "Diff",
        line_comments: &[],
        block_comment: None,
        quotes: b"\"'",
        keywords: &[],
        types: &[],
        capital_types: false,
        kind: Kind::Diff,
    };
    pub static INI: Lang = Lang {
        name: "INI",
        line_comments: &["#", ";"],
        block_comment: None,
        quotes: b"\"'",
        keywords: &[],
        types: &[],
        capital_types: false,
        kind: Kind::Ini,
    };
}

/// Lowercase extensions and their languages.
static BY_EXT: &[(&str, &Lang)] = &[
    ("c", &langs::C),
    ("h", &langs::C),
    ("cc", &langs::C),
    ("cpp", &langs::C),
    ("cxx", &langs::C),
    ("hpp", &langs::C),
    ("hh", &langs::C),
    ("zig", &langs::ZIG),
    ("zon", &langs::ZIG),
    ("rs", &langs::RUST),
    ("go", &langs::GO),
    ("py", &langs::PYTHON),
    ("js", &langs::JS),
    ("mjs", &langs::JS),
    ("cjs", &langs::JS),
    ("ts", &langs::JS),
    ("tsx", &langs::JS),
    ("jsx", &langs::JS),
    ("lua", &langs::LUA),
    ("sh", &langs::SH),
    ("bash", &langs::SH),
    ("zsh", &langs::SH),
    ("fish", &langs::SH),
    ("json", &langs::JSON),
    ("toml", &langs::TOML),
    ("yaml", &langs::YAML),
    ("yml", &langs::YAML),
    ("java", &langs::JAVA),
    ("kt", &langs::JAVA),
    ("scala", &langs::JAVA),
    ("cs", &langs::JAVA),
    ("swift", &langs::JAVA),
    ("rb", &langs::RUBY),
    ("css", &langs::CSS),
    ("scss", &langs::CSS),
    ("html", &langs::HTML),
    ("htm", &langs::HTML),
    ("xml", &langs::HTML),
    ("svg", &langs::HTML),
    ("sql", &langs::SQL),
    ("mk", &langs::MAKE),
    ("md", &langs::MARKDOWN),
    ("markdown", &langs::MARKDOWN),
    ("diff", &langs::DIFF),
    ("patch", &langs::DIFF),
    ("ini", &langs::INI),
    ("conf", &langs::INI),
    ("cfg", &langs::INI),
    ("desktop", &langs::INI),
    ("service", &langs::INI),
    ("nix", &langs::SH),
    ("pl", &langs::SH),
];

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Where `needle` is in `hay` at or after `from`.
fn find_from(hay: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    find(&hay[from..], needle).map(|i| from + i)
}

/// The language of a file by its name (or path), then by the interpreter on the first line
/// of `head`, the start of its contents; None for plain text.
pub fn detect(name: &[u8], head: &[u8]) -> Option<&'static Lang> {
    let base = name.rsplit(|&c| c == b'/').next().unwrap_or(name);
    if matches!(base, b"Makefile" | b"makefile" | b"GNUmakefile") {
        return Some(&langs::MAKE);
    }
    if base == b"PKGBUILD" || base.starts_with(b".bash") || base == b".profile" || base == b".zshrc"
    {
        return Some(&langs::SH);
    }
    if base == b"CMakeLists.txt" {
        return Some(&langs::SH);
    }
    // An extension, not a hidden file's name; longer ones than any known are skipped.
    if let Some(dot) = base.iter().rposition(|&c| c == b'.')
        && dot > 0
        && base.len() - dot - 1 <= 16
    {
        let ext = base[dot + 1..].to_ascii_lowercase();
        if let Some((_, lang)) = BY_EXT.iter().find(|(e, _)| e.as_bytes() == ext) {
            return Some(lang);
        }
    }
    // A script's interpreter line.
    if head.starts_with(b"#!") {
        let line = head.split(|&c| c == b'\n').next().unwrap_or(head);
        for (word, lang) in [
            (&b"python"[..], &langs::PYTHON),
            (b"lua", &langs::LUA),
            (b"node", &langs::JS),
            (b"ruby", &langs::RUBY),
            (b"sh", &langs::SH),
        ] {
            if find(line, word).is_some() {
                return Some(lang);
            }
        }
    }
    None
}

/// Colors `text` as `lang`: spans in order, not overlapping, none empty.
pub fn highlight(lang: &Lang, text: &[u8]) -> Vec<Span> {
    let mut out = Vec::new();
    match lang.kind {
        Kind::Markdown => markdown(&mut out, text),
        Kind::Diff => diff(&mut out, text),
        Kind::Code | Kind::Ini => code(&mut out, lang, text),
    }
    out
}

fn add(out: &mut Vec<Span>, start: usize, end: usize, class: Class) {
    if end > start {
        out.push(Span { start, end, class });
    }
}

fn is_ident(ch: u8) -> bool {
    ch.is_ascii_alphanumeric() || ch == b'_' || ch >= 0x80
}

fn line_comment(lang: &Lang, rest: &[u8]) -> bool {
    lang.line_comments
        .iter()
        .any(|lc| rest.starts_with(lc.as_bytes()))
}

/// The end of the line that `from` is on: its newline, or the end of the text.
fn line_end(text: &[u8], from: usize) -> usize {
    text[from..]
        .iter()
        .position(|&c| c == b'\n')
        .map_or(text.len(), |e| from + e)
}

fn code(out: &mut Vec<Span>, lang: &Lang, text: &[u8]) {
    let mut i = 0;
    let mut line_start = true;
    while i < text.len() {
        let ch = text[i];
        if ch == b'\n' {
            line_start = true;
            i += 1;
            continue;
        }
        // INI and TOML: [sections] and keys.
        if lang.kind == Kind::Ini && line_start {
            let mut j = i;
            while j < text.len() && matches!(text[j], b' ' | b'\t') {
                j += 1;
            }
            if j < text.len() && text[j] == b'[' {
                let e = line_end(text, j);
                add(out, j, e, Class::Heading);
                i = e;
                continue;
            }
            let eq = text[j..]
                .iter()
                .position(|&c| c == b'=' || c == b'\n')
                .map_or(text.len(), |e| j + e);
            if eq < text.len() && text[eq] == b'=' && !line_comment(lang, &text[j..]) {
                add(out, j, eq, Class::Keyword);
                i = eq;
                line_start = false;
                continue;
            }
        }
        if ch != b' ' && ch != b'\t' {
            line_start = false;
        }
        // Comments.
        if line_comment(lang, &text[i..]) {
            let e = line_end(text, i);
            add(out, i, e, Class::Comment);
            i = e;
            continue;
        }
        if let Some((open, close)) = lang.block_comment
            && text[i..].starts_with(open.as_bytes())
        {
            let e = find_from(text, i + open.len(), close.as_bytes())
                .map_or(text.len(), |x| x + close.len());
            add(out, i, e, Class::Comment);
            i = e;
            continue;
        }
        // Strings, to the closing quote on the same line (or the next lines for backquotes
        // and Python's triple quotes).
        if lang.quotes.contains(&ch) {
            // An apostrophe inside a word is not a quote (Rust lifetimes, English in
            // comments of languages without char literals).
            if ch == b'\'' && i > 0 && is_ident(text[i - 1]) {
                i += 1;
                continue;
            }
            let triple = i + 2 < text.len() && text[i + 1] == ch && text[i + 2] == ch;
            let mut j = i + if triple { 3 } else { 1 };
            while j < text.len() {
                if text[j] == b'\\' {
                    j += 2;
                    continue;
                }
                if triple {
                    if j + 2 < text.len() && text[j] == ch && text[j + 1] == ch && text[j + 2] == ch
                    {
                        j += 3;
                        break;
                    }
                } else if text[j] == ch {
                    j += 1;
                    break;
                } else if text[j] == b'\n' && ch != b'`' {
                    break;
                }
                j += 1;
            }
            let e = j.min(text.len());
            add(out, i, e, Class::String);
            i = e;
            continue;
        }
        // Numbers.
        if ch.is_ascii_digit() && (i == 0 || !is_ident(text[i - 1])) {
            let mut j = i + 1;
            while j < text.len() && (is_ident(text[j]) || text[j] == b'.') {
                j += 1;
            }
            add(out, i, j, Class::Number);
            i = j;
            continue;
        }
        // Words: keywords and types. "#include" and "@import" count as words.
        if is_ident(ch) || ch == b'#' || ch == b'@' {
            let mut j = i + 1;
            while j < text.len() && is_ident(text[j]) {
                j += 1;
            }
            // Zig's @"quoted identifier": the string comes next.
            if ch == b'@' && j < text.len() && text[j] == b'"' {
                i = j;
                continue;
            }
            let word = &text[i..j];
            let listed = |list: &[&str]| list.iter().any(|w| w.as_bytes() == word);
            if ch == b'@' || listed(lang.keywords) {
                add(out, i, j, Class::Keyword);
            } else if listed(lang.types)
                || (lang.capital_types
                    && word[0].is_ascii_uppercase()
                    && word.len() > 1
                    && word.iter().any(u8::is_ascii_lowercase))
            {
                add(out, i, j, Class::Type);
            }
            i = j;
            continue;
        }
        i += 1;
    }
}

/// Each line of `text` with the offset it starts at.
fn lines(text: &[u8]) -> impl Iterator<Item = (usize, &[u8])> {
    let mut start = 0;
    text.split(|&c| c == b'\n').map(move |line| {
        let at = start;
        start += line.len() + 1;
        (at, line)
    })
}

fn markdown(out: &mut Vec<Span>, text: &[u8]) {
    let mut fenced = false;
    for (start, line) in lines(text) {
        let end = start + line.len();
        let indent = line.iter().take_while(|&&c| c == b' ').count();
        let trimmed = &line[indent..];
        if trimmed.starts_with(b"```") || trimmed.starts_with(b"~~~") {
            fenced = !fenced;
            add(out, start, end, Class::Comment);
            continue;
        }
        if fenced {
            add(out, start, end, Class::String);
            continue;
        }
        if trimmed.starts_with(b"#") {
            add(out, start, end, Class::Heading);
            continue;
        }
        if trimmed.starts_with(b">") {
            add(out, start, end, Class::Comment);
            continue;
        }
        // List bullets, inline code, and links.
        if trimmed.len() > 1 && matches!(trimmed[0], b'-' | b'*' | b'+') && trimmed[1] == b' ' {
            add(out, start + indent, start + indent + 1, Class::Keyword);
        }
        let mut i = 0;
        while i < line.len() {
            if line[i] == b'`' {
                let Some(e) = line[i + 1..]
                    .iter()
                    .position(|&c| c == b'`')
                    .map(|e| i + 1 + e)
                else {
                    break;
                };
                add(out, start + i, start + e + 1, Class::String);
                i = e + 1;
                continue;
            }
            if line[i] == b'['
                && let Some(mid) = find_from(line, i, b"](")
                && let Some(e) = line[mid..].iter().position(|&c| c == b')').map(|e| mid + e)
            {
                add(out, start + i, start + mid + 1, Class::Type);
                add(out, start + mid + 1, start + e + 1, Class::Comment);
                i = e + 1;
                continue;
            }
            i += 1;
        }
    }
}

fn diff(out: &mut Vec<Span>, text: &[u8]) {
    for (start, line) in lines(text) {
        let end = start + line.len();
        let class = if line.starts_with(b"+++")
            || line.starts_with(b"---")
            || line.starts_with(b"diff ")
            || line.starts_with(b"index ")
        {
            Class::Heading
        } else if line.starts_with(b"@@") {
            Class::Type
        } else if line.starts_with(b"+") {
            Class::Added
        } else if line.starts_with(b"-") {
            Class::Removed
        } else {
            continue;
        };
        add(out, start, end, class);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The class at the first occurrence of `word` in `text`.
    fn class_at(spans: &[Span], text: &str, word: &str) -> Option<Class> {
        let at = text.find(word)?;
        spans
            .iter()
            .find(|s| s.start <= at && at < s.end)
            .map(|s| s.class)
    }

    /// The text of each span with its class.
    fn spans<'t>(lang: &Lang, text: &'t str) -> Vec<(&'t str, Class)> {
        highlight(lang, text.as_bytes())
            .iter()
            .map(|s| (&text[s.start..s.end], s.class))
            .collect()
    }

    // Case-insensitive extensions, the base name of a path, interpreter lines, names without
    // an extension, and plain text.
    #[test]
    fn detects_languages_by_name_and_interpreter() {
        let name = |n: &str, head: &str| detect(n.as_bytes(), head.as_bytes()).map(|l| l.name);
        assert_eq!(name("main.zig", ""), Some("Zig"));
        assert_eq!(name("/x/y/foo.H", ""), Some("C"));
        assert_eq!(name("run", "#!/usr/bin/env python3\n"), Some("Python"));
        assert_eq!(name("Makefile", ""), Some("Makefile"));
        assert_eq!(name("notes.txt", "hello"), None);
    }

    #[test]
    fn zig_keywords_types_strings_numbers_comments() {
        let src = "const x: u32 = 42; // answer\nconst s = \"a // b\";\nfn f(a: Foo) void {}\n";
        let spans = highlight(&langs::ZIG, src.as_bytes());
        assert_eq!(class_at(&spans, src, "const"), Some(Class::Keyword));
        assert_eq!(class_at(&spans, src, "u32"), Some(Class::Type));
        assert_eq!(class_at(&spans, src, "42"), Some(Class::Number));
        assert_eq!(class_at(&spans, src, "// answer"), Some(Class::Comment));
        // A comment marker inside a string is the string's.
        assert_eq!(class_at(&spans, src, "a // b"), Some(Class::String));
        assert_eq!(class_at(&spans, src, "Foo"), Some(Class::Type));
        // Spans are ordered and disjoint, and none is empty.
        let mut last = 0;
        for s in &spans {
            assert!(s.start >= last && s.end > s.start, "{spans:?}");
            last = s.end;
        }
    }

    // A block comment runs across lines and ends at its close; an escaped quote does not
    // close a string.
    #[test]
    fn c_block_comments_and_escapes() {
        let src = "int a; /* multi\nline */ return \"x\\\"y\";";
        assert_eq!(
            spans(&langs::C, src),
            [
                ("int", Class::Type),
                ("/* multi\nline */", Class::Comment),
                ("return", Class::Keyword),
                ("\"x\\\"y\"", Class::String),
            ]
        );
    }

    // Whole lines for headings and fences, the inside of a fence as code, and the exact
    // ranges of bullets, inline code, and a link's text and target.
    #[test]
    fn markdown_lines_and_inline_ranges() {
        let md =
            "# Title\n  - Some `code` and [a link](http://x).\n```\nfenced # not a heading\n```\n";
        assert_eq!(
            spans(&langs::MARKDOWN, md),
            [
                ("# Title", Class::Heading),
                ("-", Class::Keyword),
                ("`code`", Class::String),
                ("[a link]", Class::Type),
                ("(http://x)", Class::Comment),
                ("```", Class::Comment),
                ("fenced # not a heading", Class::String),
                ("```", Class::Comment),
            ]
        );
    }

    // File headers start with "+++" and "---", so they must be tested before added and
    // removed lines.
    #[test]
    fn diff_headers_before_added_and_removed() {
        let d = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n same";
        assert_eq!(
            spans(&langs::DIFF, d),
            [
                ("--- a/f", Class::Heading),
                ("+++ b/f", Class::Heading),
                ("@@ -1 +1 @@", Class::Type),
                ("-old", Class::Removed),
                ("+new", Class::Added),
            ]
        );
    }

    // Sections and keys at the start of lines; a commented-out assignment stays a comment.
    #[test]
    fn ini_sections_keys_and_comments() {
        let ini = "[core]\n  name = \"x\" ; note\n# off = 1\n";
        assert_eq!(
            spans(&langs::INI, ini),
            [
                ("[core]", Class::Heading),
                ("name ", Class::Keyword),
                ("\"x\"", Class::String),
                ("; note", Class::Comment),
                ("# off = 1", Class::Comment),
            ]
        );
    }
}
