//! The files in `$XDG_STATE_HOME/strider/`, in the Zig build's formats, byte for byte:
//!
//! - `columns`: the chosen column widths, two fractions of the window, `0.2500 0.3000\n`.
//! - `chooser`: the size the user last gave a file chooser, `1024 768\n`.
//! - `bookmarks`: a line per bookmark, the key, a colon, and an absolute path, `p:/home/me/p\n`.
//! - `history`: the command lines typed after `:`, oldest first, a line each.
//!
//! The `parse_` and `format_` functions do no I/O; `load_` and `save_` read and write a file
//! in the state directory with them. A file that is missing or unreadable loads as nothing.
//! Saving writes a temporary file beside the real one and renames it over, so a crash leaves
//! the old file or the new one, never half of one.

use std::ffi::{OsStr, OsString};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// How many command lines `history` keeps.
pub const HISTORY_MAX: usize = 200;

/// The smallest chooser size worth remembering, and that reads back: width, height.
pub const CHOOSER_MIN: [u32; 2] = [200, 150];

/// A file's reading stops once it has more than this many bytes.
const READ_MAX: usize = 4 << 20;

// The column widths --------------------------------------------------------------------------

/// Reads `columns`: two fractions, each between 0 and 1 and summing under 1, separated by
/// spaces or line breaks; whatever follows them is ignored. Anything else is nothing, and the
/// Zig build said nothing about it either.
pub fn parse_widths(data: &[u8]) -> Option<[f32; 2]> {
    let mut it = data
        .split(|&b| b == b' ' || b == b'\n')
        .filter(|t| !t.is_empty());
    let mut w = [0.0f32; 2];
    for x in &mut w {
        *x = parse_float(std::str::from_utf8(it.next()?).ok()?)?;
        if !(*x > 0.0 && *x < 1.0) {
            return None;
        }
    }
    if w[0] + w[1] >= 1.0 {
        return None;
    }
    Some(w)
}

/// The text of `columns`: each width to four decimals, as Zig's `{d:.4}` writes them.
pub fn format_widths(w: [f32; 2]) -> String {
    format!("{} {}\n", zig_decimal4(w[0]), zig_decimal4(w[1]))
}

/// Zig's `{d:.4}` for an `f32`. It rounds the shortest decimal that reads back as `x`, half
/// up, not `x`'s exact value as Rust's `{:.4}` does: 0.99995 is `1.0000`, not `0.9999`.
/// Checked against Zig 0.17.1 on 400,000 floats: the same text for every one under 1000 (a
/// width is under 1). Above that, where two shortest decimals tie, Zig's Ryu can pick the
/// other one (`1703448.2000` for Rust's `1703448.3`).
fn zig_decimal4(x: f32) -> String {
    let sign = if x.is_sign_negative() { "-" } else { "" };
    if x.is_nan() {
        return format!("{sign}nan");
    }
    if x.is_infinite() {
        return format!("{sign}inf");
    }
    // Rust's Display writes the shortest digits that read back, never in exponent form.
    let shortest = format!("{}", x.abs());
    let (int, frac) = shortest.split_once('.').unwrap_or((&shortest, ""));
    let mut digits: Vec<u8> = int
        .bytes()
        .chain(frac.bytes().chain(*b"0000").take(4))
        .collect();
    if frac.as_bytes().get(4).is_some_and(|&d| d >= b'5') {
        let carry = digits.iter_mut().rev().all(|d| {
            *d = if *d == b'9' { b'0' } else { *d + 1 };
            *d == b'0'
        });
        if carry {
            digits.insert(0, b'1');
        }
    }
    let (int, frac) = digits.split_at(digits.len() - 4);
    format!(
        "{sign}{}.{}",
        std::str::from_utf8(int).unwrap_or_default(),
        std::str::from_utf8(frac).unwrap_or_default()
    )
}

pub fn load_widths(dir: &Path) -> Option<[f32; 2]> {
    parse_widths(&read_capped(&dir.join("columns"))?)
}

/// Keeps the widths, or with `None` forgets them (removes the file).
pub fn save_widths(dir: &Path, w: Option<[f32; 2]>) -> io::Result<()> {
    match w {
        Some(w) => write_atomic(dir, "columns", format_widths(w).as_bytes()),
        None => remove(&dir.join("columns")),
    }
}

// The chooser's size -------------------------------------------------------------------------

/// Reads `chooser`: trimmed of spaces and line breaks at its ends, a width and a height,
/// separated by any of ` ,x{}` (a line break between them does not count), at least
/// [`CHOOSER_MIN`]; whatever follows them is ignored. Anything else is nothing, silently.
pub fn parse_chooser_size(data: &[u8]) -> Option<[u32; 2]> {
    let start = data.iter().position(|b| !b" \n".contains(b))?;
    let end = data.iter().rposition(|b| !b" \n".contains(b))? + 1;
    let mut it = data[start..end]
        .split(|b| b" ,x{}".contains(b))
        .filter(|t| !t.is_empty());
    let mut out = [0u32; 2];
    for x in &mut out {
        *x = parse_u32(it.next()?)?;
    }
    if out[0] < CHOOSER_MIN[0] || out[1] < CHOOSER_MIN[1] {
        return None;
    }
    Some(out)
}

pub fn format_chooser_size(size: [u32; 2]) -> String {
    format!("{} {}\n", size[0], size[1])
}

pub fn load_chooser_size(dir: &Path) -> Option<[u32; 2]> {
    parse_chooser_size(&read_capped(&dir.join("chooser"))?)
}

/// Keeps a size the user gave a chooser, or with `None` forgets it (removes the file). A size
/// under [`CHOOSER_MIN`] writes nothing: the Zig build did not remember one.
pub fn save_chooser_size(dir: &Path, size: Option<[u32; 2]>) -> io::Result<()> {
    match size {
        Some(s) if s[0] < CHOOSER_MIN[0] || s[1] < CHOOSER_MIN[1] => Ok(()),
        Some(s) => write_atomic(dir, "chooser", format_chooser_size(s).as_bytes()),
        None => remove(&dir.join("chooser")),
    }
}

// Bookmarks ----------------------------------------------------------------------------------

/// Reads `bookmarks`: a line each, the key (one character, which may be `:` itself), a colon,
/// and an absolute path, which is the rest of the line. Empty lines are skipped quietly; any
/// other line that is not that is skipped and named in the problems. A key given twice keeps
/// its first place and its last path.
pub fn parse_bookmarks(data: &[u8]) -> (Vec<(char, PathBuf)>, Vec<String>) {
    let mut marks = Vec::new();
    let mut problems = Vec::new();
    for (i, line) in data.split(|&b| b == b'\n').enumerate() {
        if line.is_empty() {
            continue;
        }
        let parsed = decode_first(line).and_then(|(key, len)| {
            (line.len() > len + 1 && line[len] == b':' && line[len + 1] == b'/')
                .then(|| (key, PathBuf::from(OsStr::from_bytes(&line[len + 1..]))))
        });
        match parsed {
            Some((key, path)) => set_bookmark(&mut marks, key, path),
            None => problems.push(format!(
                "Skipped line {} of the bookmarks file: not a key, a colon, and an absolute path",
                i + 1
            )),
        }
    }
    (marks, problems)
}

/// The text of `bookmarks`, in their order. A path with a line break would not read back, so
/// it is left out.
pub fn format_bookmarks(marks: &[(char, PathBuf)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (key, path) in marks {
        let path = path.as_os_str().as_bytes();
        if path.contains(&b'\n') {
            continue;
        }
        out.extend_from_slice(key.encode_utf8(&mut [0; 4]).as_bytes());
        out.push(b':');
        out.extend_from_slice(path);
        out.push(b'\n');
    }
    out
}

/// Sets a bookmark: a key already there keeps its place and takes the new path; a new key goes
/// last.
pub fn set_bookmark(marks: &mut Vec<(char, PathBuf)>, key: char, path: PathBuf) {
    match marks.iter_mut().find(|(k, _)| *k == key) {
        Some(m) => m.1 = path,
        None => marks.push((key, path)),
    }
}

pub fn load_bookmarks(dir: &Path) -> (Vec<(char, PathBuf)>, Vec<String>) {
    match read_capped(&dir.join("bookmarks")) {
        Some(data) => parse_bookmarks(&data),
        None => (Vec::new(), Vec::new()),
    }
}

pub fn save_bookmarks(dir: &Path, marks: &[(char, PathBuf)]) -> io::Result<()> {
    write_atomic(dir, "bookmarks", &format_bookmarks(marks))
}

// Command history ----------------------------------------------------------------------------

/// Reads `history`: every non-empty line, oldest first. Loading neither drops duplicates nor
/// trims to [`HISTORY_MAX`]; [`add_history`] does both. A line that is not UTF-8 has its bad
/// bytes replaced.
pub fn parse_history(data: &[u8]) -> Vec<String> {
    data.split(|&b| b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| String::from_utf8_lossy(l).into_owned())
        .collect()
}

/// The text of `history`: a line each.
pub fn format_history(history: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    for h in history {
        out.extend_from_slice(h.as_bytes());
        out.push(b'\n');
    }
    out
}

/// Adds a command line as the newest, dropping its older copies and the oldest lines past
/// [`HISTORY_MAX`]. An empty line, or one with a line break, is not added; the return says
/// whether it was, and so whether to save.
pub fn add_history(history: &mut Vec<String>, line: &str) -> bool {
    if line.is_empty() || line.contains('\n') {
        return false;
    }
    history.retain(|h| h != line);
    history.push(line.to_owned());
    if history.len() > HISTORY_MAX {
        history.drain(..history.len() - HISTORY_MAX);
    }
    true
}

pub fn load_history(dir: &Path) -> Vec<String> {
    read_capped(&dir.join("history"))
        .map(|d| parse_history(&d))
        .unwrap_or_default()
}

pub fn save_history(dir: &Path, history: &[String]) -> io::Result<()> {
    write_atomic(dir, "history", &format_history(history))
}

// Parsing as Zig's std does ------------------------------------------------------------------

/// The first character of `s` and its length in bytes, if it starts with valid UTF-8.
fn decode_first(s: &[u8]) -> Option<(char, usize)> {
    let len = match *s.first()? {
        0x00..=0x7f => 1,
        0xc0..=0xdf => 2,
        0xe0..=0xef => 3,
        0xf0..=0xf7 => 4,
        _ => return None,
    };
    let c = std::str::from_utf8(s.get(..len)?).ok()?.chars().next()?;
    Some((c, len))
}

/// `std.fmt.parseInt(u32, t, 10)`: an optional sign, then digits, with underscores allowed
/// between them.
fn parse_u32(t: &[u8]) -> Option<u32> {
    let (neg, digits) = match t.first() {
        Some(b'+') => (false, &t[1..]),
        Some(b'-') => (true, &t[1..]),
        _ => (false, t),
    };
    if digits.first() == Some(&b'_') || digits.last() == Some(&b'_') {
        return None;
    }
    let mut n: u32 = 0;
    let mut any = false;
    for &c in digits {
        if c == b'_' {
            continue;
        }
        if !c.is_ascii_digit() {
            return None;
        }
        any = true;
        n = n.checked_mul(10)?.checked_add(u32::from(c - b'0'))?;
    }
    // "-0" is the only negative a u32 takes.
    (any && !(neg && n != 0)).then_some(n)
}

/// `std.fmt.parseFloat(f32, t)` for decimal numbers: Rust's grammar, plus underscores each
/// between two digits. Zig's hex floats (`0x0.8p0`) are not read; the Zig build never wrote
/// one.
fn parse_float(t: &str) -> Option<f32> {
    let b = t.as_bytes();
    let body = b.strip_prefix(b"+").or(b.strip_prefix(b"-")).unwrap_or(b);
    if !body.contains(&b'_') {
        return t.parse().ok();
    }
    for (i, &c) in body.iter().enumerate() {
        if c == b'_'
            && (i == 0
                || i + 1 == body.len()
                || !body[i - 1].is_ascii_digit()
                || !body[i + 1].is_ascii_digit())
        {
            return None;
        }
    }
    t.replace('_', "").parse().ok()
}

// Files --------------------------------------------------------------------------------------

/// A file's bytes, read until its end, an error, or past [`READ_MAX`]; `None` if it does not
/// open.
fn read_capped(path: &Path) -> Option<Vec<u8>> {
    let mut f = fs::File::open(path).ok()?;
    let mut out = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        match f.read(&mut chunk) {
            Ok(0) | Err(_) => break,
            Ok(n) => out.extend_from_slice(&chunk[..n]),
        }
        if out.len() > READ_MAX {
            break;
        }
    }
    Some(out)
}

/// Writes `dir/name` atomically: makes `dir` (mode 0700) if need be, writes `dir/name.tmp`
/// (mode 0600), and renames it over `dir/name`. A failed write leaves the old file alone.
fn write_atomic(dir: &Path, name: &str, data: &[u8]) -> io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let path = dir.join(name);
    let mut tmp = OsString::from(path.as_os_str());
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let written = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(data));
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    fs::rename(&tmp, &path)
}

/// Removes a file; one already gone is no error.
fn remove(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    /// A bookmarks file the Zig build wrote (`key ':' path '\n'`, in insertion order) reads
    /// back whole. Catches splitting at the last colon or at spaces, rejecting `:` or a
    /// multibyte character as the key, and reordering on load.
    #[test]
    fn zig_bookmarks_read_back() {
        let text = "p:/home/me/My Projects\n::/srv/a:b\né:/tmp/x y:z\n";
        let (marks, problems) = parse_bookmarks(text.as_bytes());
        assert_eq!(problems, Vec::<String>::new());
        let want = vec![
            ('p', p("/home/me/My Projects")),
            (':', p("/srv/a:b")),
            ('é', p("/tmp/x y:z")),
        ];
        assert_eq!(marks, want);
        assert_eq!(format_bookmarks(&marks), text.as_bytes());
    }

    /// A bad line costs only itself, is named by its 1-based line number (empty lines count but
    /// are not reported), and a repeated key keeps its first place with its last path. Catches
    /// aborting on the first bad line, off-by-one line numbers, accepting a relative path or a
    /// bare `k:`, and a duplicate moving to the end.
    #[test]
    fn bad_bookmark_lines_are_skipped_and_named() {
        let text = b"a:/one\n\nab:/two\nb:relative\nc:\n\xff:/bad\nb:/three\na:/four";
        let (marks, problems) = parse_bookmarks(text);
        assert_eq!(marks, vec![('a', p("/four")), ('b', p("/three"))]);
        let skipped = |n| {
            format!(
                "Skipped line {n} of the bookmarks file: not a key, a colon, and an absolute path"
            )
        };
        assert_eq!(
            problems,
            vec![skipped(3), skipped(4), skipped(5), skipped(6)]
        );
    }

    /// A path with a line break is left out of the file, where it would read back as a bad
    /// line and a bogus path. Catches writing it.
    #[test]
    fn bookmark_with_line_break_is_not_written() {
        let marks = vec![('a', p("/x\ny")), ('b', p("/ok"))];
        assert_eq!(format_bookmarks(&marks), b"b:/ok\n");
    }

    /// History keeps the newest copy of a line and at most 200 lines, dropping the oldest;
    /// loading keeps every non-empty line as written. Catches an off-by-one limit, trimming
    /// the newest end, keeping the old copy's place, and dropping lines on load.
    #[test]
    fn history_limit_and_round_trip() {
        let mut h: Vec<String> = (0..HISTORY_MAX).map(|i| format!("cd /d {i}")).collect();
        assert!(add_history(&mut h, "cd /d 5"));
        assert_eq!(h.len(), HISTORY_MAX);
        assert_eq!(h.last().unwrap(), "cd /d 5");
        assert!(add_history(&mut h, "rename a: b"));
        assert_eq!(h.len(), HISTORY_MAX);
        assert_eq!(h[0], "cd /d 1");
        assert!(!add_history(&mut h, ""));
        assert!(!add_history(&mut h, "a\nb"));
        assert_eq!(parse_history(&format_history(&h)), h);
        // As the Zig build wrote it; a duplicate on disk is kept, as Zig's load kept it.
        assert_eq!(
            parse_history(b"cd /tmp\n\nsort size\ncd /tmp\n"),
            ["cd /tmp", "sort size", "cd /tmp"]
        );
    }

    /// `columns` and `chooser` as the Zig build wrote them (`{d:.4} {d:.4}\n`, `{d} {d}\n`)
    /// and its limits. Catches a precision other than four decimals, accepting widths that
    /// sum to 1 or a chooser under 200x150, and not reading the `x` and `{}` separators.
    #[test]
    fn widths_and_chooser_size() {
        assert_eq!(format_widths([0.25, 1.0 / 3.0]), "0.2500 0.3333\n");
        // Zig rounds the shortest decimal half up; Rust's `{:.4}` gives 0.9999 and 0.0000.
        assert_eq!(format_widths([0.99995, 0.00005]), "1.0000 0.0001\n");
        assert_eq!(parse_widths(b"0.2500 0.3333\n"), Some([0.25, 0.3333]));
        assert_eq!(parse_widths(b"0.5000 0.5000\n"), None);
        assert_eq!(parse_widths(b"0.5 0\n"), None);
        assert_eq!(parse_widths(b"0.2_5\n0.3 junk"), Some([0.25, 0.3]));
        assert_eq!(parse_widths(b"0.25"), None);
        assert_eq!(format_chooser_size([1024, 768]), "1024 768\n");
        assert_eq!(parse_chooser_size(b"1024 768\n"), Some([1024, 768]));
        assert_eq!(parse_chooser_size(b"{+1_024x768}"), Some([1024, 768]));
        assert_eq!(parse_chooser_size(b"1024\n768\n"), None);
        assert_eq!(parse_chooser_size(b"199 768\n"), None);
        assert_eq!(parse_chooser_size(b"1024 4294967296\n"), None);
    }

    /// Saving and loading through a real directory: the directory is made, the file has the
    /// Zig's bytes and mode 0600, no `.tmp` is left behind, and forgetting removes the file.
    #[test]
    fn save_and_load_files() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("strider-state-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let state = dir.join("strider");
        save_bookmarks(&state, &[('p', p("/a b"))]).unwrap();
        assert_eq!(fs::read(state.join("bookmarks")).unwrap(), b"p:/a b\n");
        let mode = fs::metadata(state.join("bookmarks"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(!state.join("bookmarks.tmp").exists());
        assert_eq!(load_bookmarks(&state).0, vec![('p', p("/a b"))]);
        save_widths(&state, Some([0.2, 0.3])).unwrap();
        assert_eq!(load_widths(&state), Some([0.2, 0.3]));
        save_widths(&state, None).unwrap();
        save_widths(&state, None).unwrap();
        assert_eq!(load_widths(&state), None);
        save_chooser_size(&state, Some([100, 100])).unwrap();
        assert!(!state.join("chooser").exists());
        fs::remove_dir_all(&dir).unwrap();
    }
}
