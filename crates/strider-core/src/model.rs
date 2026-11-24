//! A directory's entries: reading them (on a worker thread), sorting, and filtering.
//!
//! Names live in one byte arena per listing; entries refer to them by offset, so a listing of
//! 100 000 entries is a handful of allocations. A name is a path relative to the listing's
//! folder: a plain name in a folder's listing, "sub/dir/name" in recursive search results.
//! Names are bytes, as Linux has them.
//!
//! Types (MIME) are not here: the app classifies entries and passes what sorting by type and a
//! file chooser's type filter need, by entry index.

use std::cmp::Ordering;
use std::ffi::OsStr;
use std::fs::{self, Metadata};
use std::io;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use crate::options::{Sort, SortKey};

/// The longest path the kernel takes, with its NUL.
const PATH_MAX: usize = 4096;

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;
const S_IFLNK: u32 = 0o120000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    File,
    Dir,
    Other,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name_off: u32,
    pub name_len: u32,
    pub size: u64,
    /// Modification time in nanoseconds since the epoch.
    pub mtime: i64,
    pub mode: u32,
    /// Offset of the base name within the name (after the last slash).
    pub base_off: u16,
    pub kind: Kind,
    /// A symbolic link (kind is its target's).
    pub link: bool,
    pub hidden: bool,
}

impl Entry {
    /// An entry nothing is known about: what a failed stat leaves.
    fn unknown(name: &[u8]) -> Entry {
        Entry {
            name_off: 0,
            name_len: 0,
            size: 0,
            mtime: 0,
            mode: 0,
            base_off: 0,
            kind: Kind::Other,
            link: false,
            hidden: name.first() == Some(&b'.'),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listing {
    /// The directory, absolute and without a trailing slash (except "/").
    pub path: PathBuf,
    pub names: Vec<u8>,
    pub entries: Vec<Entry>,
}

impl Listing {
    /// The path relative to the folder.
    pub fn name(&self, e: &Entry) -> &[u8] {
        let off = e.name_off as usize;
        &self.names[off..off + e.name_len as usize]
    }

    /// The last component, as shown.
    pub fn base(&self, e: &Entry) -> &[u8] {
        &self.name(e)[e.base_off as usize..]
    }

    /// The folder the entry is in, relative to the listing's ("" for the listing's own
    /// folder).
    pub fn dir_of(&self, e: &Entry) -> &[u8] {
        if e.base_off == 0 {
            b""
        } else {
            &self.name(e)[..e.base_off as usize - 1]
        }
    }

    /// The entry's absolute path.
    pub fn path_of(&self, e: &Entry) -> PathBuf {
        join(&self.path, self.name(e))
    }
}

/// Builds a listing entry by entry (the directory reader and recursive search).
#[derive(Debug, Default)]
pub struct Builder {
    names: Vec<u8>,
    entries: Vec<Entry>,
}

impl Builder {
    pub fn new() -> Builder {
        Builder::default()
    }

    /// Adds `e` under the relative name `rel`, setting its name's offsets.
    pub fn add(&mut self, rel: &[u8], mut e: Entry) {
        e.name_off = u32::try_from(self.names.len()).expect("a listing's names fit in 4 GiB");
        e.name_len = u32::try_from(rel.len()).expect("a name fits in 4 GiB");
        e.base_off = match rel.iter().rposition(|&c| c == b'/') {
            Some(i) => u16::try_from(i + 1).unwrap_or(u16::MAX),
            None => 0,
        };
        self.names.extend_from_slice(rel);
        self.entries.push(e);
    }

    pub fn finish(self, path: impl Into<PathBuf>) -> Listing {
        Listing {
            path: path.into(),
            names: self.names,
            entries: self.entries,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReadError {
    FileNotFound,
    AccessDenied,
    NotDir,
    OutOfMemory,
    Unexpected,
}

impl From<io::Error> for ReadError {
    fn from(e: io::Error) -> ReadError {
        match e.kind() {
            io::ErrorKind::NotFound => ReadError::FileNotFound,
            io::ErrorKind::PermissionDenied => ReadError::AccessDenied,
            io::ErrorKind::NotADirectory => ReadError::NotDir,
            io::ErrorKind::OutOfMemory => ReadError::OutOfMemory,
            _ => ReadError::Unexpected,
        }
    }
}

/// Reads `path` (absolute): every entry but "." and "..", with its kind, size, modification
/// time, and mode. Symbolic links report their target's kind. Blocking: runs on a worker
/// thread.
pub fn read(path: &Path) -> Result<Listing, ReadError> {
    // A path the kernel cannot take names nothing.
    if path.as_os_str().len() >= PATH_MAX {
        return Err(ReadError::FileNotFound);
    }
    let mut b = Builder::new();
    for d in fs::read_dir(path)? {
        let d = d.map_err(|_| ReadError::Unexpected)?;
        let name = d.file_name().into_vec();
        let e = entry_from(&name, d.metadata(), || fs::metadata(d.path()));
        b.add(&name, e);
    }
    Ok(b.finish(path))
}

/// The entry for the file at `path`, named `name` (its base name: a leading dot hides it),
/// with the name's offsets unset.
pub fn stat_entry(path: &Path, name: &[u8]) -> Entry {
    entry_from(name, fs::symlink_metadata(path), || fs::metadata(path))
}

/// An entry from its file's metadata, not following a link (`lstat`), and `follow`, which
/// stats a link's target.
fn entry_from(
    name: &[u8],
    lstat: io::Result<Metadata>,
    follow: impl FnOnce() -> io::Result<Metadata>,
) -> Entry {
    let mut e = Entry::unknown(name);
    let Ok(mut st) = lstat else {
        return e;
    };
    if st.mode() & S_IFMT == S_IFLNK {
        e.link = true;
        // The target, if there is one; a dangling link stays "other".
        if let Ok(target) = follow() {
            st = target;
        }
    }
    e.size = st.size();
    e.mtime = st
        .mtime()
        .saturating_mul(1_000_000_000)
        .saturating_add(st.mtime_nsec());
    e.mode = st.mode();
    e.kind = match st.mode() & S_IFMT {
        S_IFDIR => Kind::Dir,
        S_IFREG => Kind::File,
        _ => Kind::Other,
    };
    if e.kind == Kind::Dir {
        e.size = 0;
    }
    e
}

/// Whether the file is decoded for a thumbnail, by its extension.
pub fn thumbnailable(name: &[u8]) -> bool {
    let Some(dot) = name.iter().rposition(|&c| c == b'.') else {
        return false;
    };
    let ext = &name[dot + 1..];
    if ext.len() > 8 {
        return false;
    }
    ["png", "jpg", "jpeg", "gif", "webp", "avif", "jxl", "svg"]
        .iter()
        .any(|x| ext.eq_ignore_ascii_case(x.as_bytes()))
}

// Sorting -----------------------------------------------------------------------------------

/// Every entry's index, sorted. `type_key` gives an entry's type's sort key by index, for
/// sorting by type: the type's comment ("PNG image"), as the database names it. A caller
/// with no types passes `|_| ()`.
pub fn sort<K: Ord>(l: &Listing, s: Sort, type_key: impl Fn(u32) -> K) -> Vec<u32> {
    let n = u32::try_from(l.entries.len()).expect("a listing has fewer than 2^32 entries");
    let mut order: Vec<u32> = (0..n).collect();
    sort_indices(l, &mut order, s, type_key);
    order
}

/// Sorts the given indices of `l`.
pub fn sort_indices<K: Ord>(l: &Listing, order: &mut [u32], s: Sort, type_key: impl Fn(u32) -> K) {
    // A total order (the index breaks ties), so an unstable sort gives the one answer.
    order.sort_unstable_by(|&a, &b| compare(l, s, &type_key, a, b));
}

fn compare<K: Ord>(l: &Listing, s: Sort, type_key: &impl Fn(u32) -> K, a: u32, b: u32) -> Ordering {
    let ea = &l.entries[a as usize];
    let eb = &l.entries[b as usize];
    if s.folders_first {
        let da = ea.kind == Kind::Dir;
        let db = eb.kind == Kind::Dir;
        if da != db {
            return if da {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
    }
    let ord = match s.key {
        SortKey::Name => Ordering::Equal,
        SortKey::Size => ea.size.cmp(&eb.size),
        SortKey::Modified => ea.mtime.cmp(&eb.mtime),
        SortKey::Type => type_key(a).cmp(&type_key(b)),
        SortKey::Extension => natural_order(extension(l.base(ea)), extension(l.base(eb))),
    }
    .then_with(|| natural_order(l.base(ea), l.base(eb)))
    .then_with(|| natural_order(l.name(ea), l.name(eb)))
    .then_with(|| a.cmp(&b));
    if s.descending { ord.reverse() } else { ord }
}

/// The extension of a name without its dot, "" for none (and for names that only start with
/// a dot).
pub fn extension(name: &[u8]) -> &[u8] {
    match name.iter().rposition(|&c| c == b'.') {
        None | Some(0) => b"",
        Some(dot) => &name[dot + 1..],
    }
}

/// Compares names as people read them: case-insensitively (ASCII), with runs of digits
/// compared as numbers, so "file2" sorts before "file10". A leading dot is ignored, so
/// ".config" sorts among the c's.
pub fn natural_order(a_in: &[u8], b_in: &[u8]) -> Ordering {
    let strip = |s: &'_ [u8]| -> usize { usize::from(s.len() > 1 && s[0] == b'.') };
    let a = &a_in[strip(a_in)..];
    let b = &b_in[strip(b_in)..];
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let ie = i + a[i..].iter().take_while(|c| c.is_ascii_digit()).count();
            let je = j + b[j..].iter().take_while(|c| c.is_ascii_digit()).count();
            // Compare without leading zeros: longer is larger, then digits.
            let na = trim_zeros(&a[i..ie]);
            let nb = trim_zeros(&b[j..je]);
            let o = na.len().cmp(&nb.len()).then_with(|| na.cmp(nb));
            if o != Ordering::Equal {
                return o;
            }
            i = ie;
            j = je;
            continue;
        }
        let ca = a[i].to_ascii_lowercase();
        let cb = b[j].to_ascii_lowercase();
        if ca != cb {
            return ca.cmp(&cb);
        }
        i += 1;
        j += 1;
    }
    // Equal ignoring case: a stable tiebreak on the bytes.
    (a.len() - i)
        .cmp(&(b.len() - j))
        .then_with(|| a_in.cmp(b_in))
}

fn trim_zeros(digits: &[u8]) -> &[u8] {
    let zeros = digits.iter().take_while(|&&c| c == b'0').count();
    &digits[zeros..]
}

// Filtering ---------------------------------------------------------------------------------

/// The indices of `order` whose entries match: hidden entries only with `show_hidden`; with a
/// query, names containing it (see [`matches`]); with `types`, what the filter admits.
/// `type_names` gives, by index, the names of an entry's type and of each type it is a
/// subclass of ("image/png", "image/*"'s parents...): see [`TypeFilter::admits`]. It is
/// called only with `types`; a caller without types passes `|_| std::iter::empty()`.
pub fn filter<'a, I>(
    l: &Listing,
    order: &[u32],
    query: &str,
    show_hidden: bool,
    types: Option<&TypeFilter>,
    type_names: impl Fn(u32) -> I,
) -> Vec<u32>
where
    I: IntoIterator<Item = &'a str>,
{
    order
        .iter()
        .copied()
        .filter(|&i| {
            let e = &l.entries[i as usize];
            if e.hidden && !show_hidden {
                return false;
            }
            if !query.is_empty() && !matches(l.base(e), query) {
                return false;
            }
            types.is_none_or(|t| t.admits(l.base(e), e, || type_names(i)))
        })
        .collect()
}

/// A file chooser's filter (the FileChooser portal's): files whose name matches a glob,
/// ignoring case, or whose type is one of the MIME types (a subclass counts; "image/*" is
/// every image). Folders always pass, so the chooser can still go anywhere.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TypeFilter {
    /// Lowercased globs.
    pub globs: Vec<String>,
    pub mimes: Vec<String>,
}

impl TypeFilter {
    /// Whether the filter admits the entry named `name`. `type_names` lists the MIME names of
    /// the entry's type and its ancestors (the type itself first; none when there is no
    /// database), and is called only when no glob matches.
    pub fn admits<'a, I>(&self, name: &[u8], e: &Entry, type_names: impl FnOnce() -> I) -> bool
    where
        I: IntoIterator<Item = &'a str>,
    {
        if e.kind == Kind::Dir || (self.globs.is_empty() && self.mimes.is_empty()) {
            return true;
        }
        // Names longer than 256 bytes are matched as they are.
        let lower;
        let name = if name.len() <= 256 {
            lower = name.to_ascii_lowercase();
            &lower[..]
        } else {
            name
        };
        if self.globs.iter().any(|g| glob_match(g.as_bytes(), name)) {
            return true;
        }
        type_names().into_iter().any(|tn| {
            self.mimes.iter().any(|m| match m.strip_suffix('*') {
                Some(prefix) if prefix.ends_with('/') => tn.starts_with(prefix),
                _ => tn.eq_ignore_ascii_case(m),
            })
        })
    }
}

/// Whether `s` matches the shell glob `pattern`: `*`, `?`, and `[...]` classes (with ranges
/// and `!` or `^` negating).
fn glob_match(pattern: &[u8], s: &[u8]) -> bool {
    let (mut p, mut i) = (0, 0);
    let mut star: Option<usize> = None;
    let mut star_i = 0;
    while i < s.len() {
        if p < pattern.len() {
            match pattern[p] {
                b'*' => {
                    star = Some(p);
                    star_i = i;
                    p += 1;
                    continue;
                }
                b'?' => {
                    p += 1;
                    i += 1;
                    continue;
                }
                b'[' => {
                    if let Some(next) = match_class(pattern, p, s[i]) {
                        p = next;
                        i += 1;
                        continue;
                    }
                }
                c if c == s[i] => {
                    p += 1;
                    i += 1;
                    continue;
                }
                _ => {}
            }
        }
        let Some(sp) = star else {
            return false;
        };
        p = sp + 1;
        star_i += 1;
        i = star_i;
    }
    p += pattern[p..].iter().take_while(|&&c| c == b'*').count();
    p == pattern.len()
}

/// Whether the class at `pattern[p]` ('[') matches `ch`: the index after the class if so.
fn match_class(pattern: &[u8], p: usize, ch: u8) -> Option<usize> {
    let mut j = p + 1;
    let mut negate = false;
    if j < pattern.len() && (pattern[j] == b'!' || pattern[j] == b'^') {
        negate = true;
        j += 1;
    }
    let mut matched = false;
    let mut first = true;
    while j < pattern.len() && (first || pattern[j] != b']') {
        first = false;
        if j + 2 < pattern.len() && pattern[j + 1] == b'-' && pattern[j + 2] != b']' {
            if (pattern[j]..=pattern[j + 2]).contains(&ch) {
                matched = true;
            }
            j += 3;
        } else {
            if ch == pattern[j] {
                matched = true;
            }
            j += 1;
        }
    }
    if j >= pattern.len() || matched == negate {
        return None;
    }
    Some(j + 1)
}

/// Whether `name` contains every space-separated word of `query`: in smart case, as /
/// searches, so a word with a capital letter matches its case exactly and others ignore ASCII
/// case.
pub fn matches(name: &[u8], query: &str) -> bool {
    query.split(' ').filter(|w| !w.is_empty()).all(|word| {
        let word = word.as_bytes();
        if word.len() > name.len() {
            return false;
        }
        let mut windows = name.windows(word.len());
        if word.iter().any(u8::is_ascii_uppercase) {
            windows.any(|w| w == word)
        } else {
            windows.any(|w| w.eq_ignore_ascii_case(word))
        }
    })
}

// Formatting --------------------------------------------------------------------------------

/// "1.2 MB" (decimal units, as GNOME and the SI do), "512 bytes".
pub fn format_size(size: u64) -> String {
    if size < 1000 {
        return format!("{size} {}", if size == 1 { "byte" } else { "bytes" });
    }
    const UNITS: [&str; 5] = ["kB", "MB", "GB", "TB", "PB"];
    let mut v = size as f64 / 1000.0;
    let mut u = 0;
    while v >= 1000.0 && u + 1 < UNITS.len() {
        v /= 1000.0;
        u += 1;
    }
    format!("{} {}", fixed(v, 1), UNITS[u])
}

/// "512 B", "1.2 K", "34 M": the short sizes in binary units the columns show.
pub fn compact_size(size: u64) -> String {
    if size < 1024 {
        return format!("{size} B");
    }
    const UNITS: [&str; 5] = ["K", "M", "G", "T", "P"];
    let mut v = size as f64 / 1024.0;
    let mut u = 0;
    while v >= 1024.0 && u + 1 < UNITS.len() {
        v /= 1024.0;
        u += 1;
    }
    format!("{} {}", fixed(v, if v < 10.0 { 1 } else { 0 }), UNITS[u])
}

/// `v` (finite, not negative) with `places` (0 or 1) digits after the point, rounded as Zig's
/// `{d:.1}` rounds: half up on the shortest decimal that reads back as `v`, so 1.25 and 1.15
/// (which is 1.149999... in binary) both round up, where `{:.1}` gives 1.2 and 1.1.
fn fixed(v: f64, places: usize) -> String {
    let sci = format!("{v:e}");
    let (mantissa, exp) = sci.split_once('e').expect("{:e} has an exponent");
    let exp: i64 = exp.parse().expect("{:e}'s exponent is a number");
    let mut digits: Vec<u8> = mantissa.bytes().filter(u8::is_ascii_digit).collect();
    // Digits before the point.
    let mut point = exp + 1;
    if point < 1 {
        let zeros = (1 - point) as usize;
        digits.splice(0..0, std::iter::repeat_n(b'0', zeros));
        point = 1;
    }
    let point = point as usize;
    if digits.len() < point + places + 1 {
        digits.resize(point + places + 1, b'0');
    }
    let round_up = digits[point + places] >= b'5';
    digits.truncate(point + places);
    let mut point = point;
    if round_up {
        let mut k = digits.len();
        loop {
            if k == 0 {
                digits.insert(0, b'1');
                point += 1;
                break;
            }
            k -= 1;
            if digits[k] == b'9' {
                digits[k] = b'0';
            } else {
                digits[k] += 1;
                break;
            }
        }
    }
    if places > 0 {
        digits.insert(point, b'.');
    }
    String::from_utf8(digits).expect("digits are ASCII")
}

/// "2026-10-13 14:05" in UTC offset `tz_offset_s` (local time comes from the caller, which
/// reads it once); "—" before 1970.
pub fn format_time(mtime_ns: i64, tz_offset_s: i64) -> String {
    let secs = mtime_ns.div_euclid(1_000_000_000) + tz_offset_s;
    if secs < 0 {
        return "—".into();
    }
    let (days, day_secs) = (secs / 86_400, secs % 86_400);
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}",
        day_secs / 3600,
        day_secs % 3600 / 60
    )
}

/// The proleptic Gregorian date `days` (not negative) after 1970-01-01 (Howard Hinnant's
/// algorithm).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// "rwxr-xr-x" for permission bits.
pub fn format_mode(mode: u32) -> String {
    b"rwxrwxrwx"
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            if mode & (0o400 >> i) != 0 {
                c as char
            } else {
                '-'
            }
        })
        .collect()
}

// Paths -------------------------------------------------------------------------------------

/// `dir` joined with `name`: one slash between them, unlike [`Path::join`], which replaces
/// `dir` with an absolute `name`.
pub fn join(dir: &Path, name: &[u8]) -> PathBuf {
    let dir = dir.as_os_str().as_bytes();
    let mut out = Vec::with_capacity(dir.len() + 1 + name.len());
    out.extend_from_slice(dir);
    if dir.last() != Some(&b'/') {
        out.push(b'/');
    }
    out.extend_from_slice(name);
    PathBuf::from(OsStr::from_bytes(&out))
}

/// The parent of an absolute path; "/" is its own parent.
pub fn parent(path: &Path) -> &Path {
    let p = path.as_os_str().as_bytes();
    if p.len() <= 1 {
        return Path::new("/");
    }
    match p.iter().rposition(|&c| c == b'/') {
        None | Some(0) => Path::new("/"),
        Some(i) => Path::new(OsStr::from_bytes(&p[..i])),
    }
}

/// The last component; "/" for the root.
pub fn basename(path: &Path) -> &[u8] {
    let p = path.as_os_str().as_bytes();
    if p.len() <= 1 {
        return b"/";
    }
    match p.iter().rposition(|&c| c == b'/') {
        None => p,
        Some(i) => &p[i + 1..],
    }
}

/// Whether `path` is `dir` or inside it.
pub fn is_within(path: &Path, dir: &Path) -> bool {
    let (p, d) = (path.as_os_str().as_bytes(), dir.as_os_str().as_bytes());
    d == b"/" || (p.starts_with(d) && (p.len() == d.len() || p[d.len()] == b'/'))
}

/// Whether `name` can be a file name: not empty, ".", or "..", without slashes or NULs, at
/// most 255 bytes.
pub fn valid_name(name: &[u8]) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && name != b"."
        && name != b".."
        && !name.iter().any(|&c| c == b'/' || c == 0)
}

/// The Drives folder's path. No folder on disk normalizes to it (it starts with "//"), so it
/// stands for the folder wherever paths go: tabs, history, bookmarks, and `:cd //drives`.
pub const DRIVES_PATH: &str = "//drives";

/// Collapses "//", "/./", and "/x/../" and drops a trailing slash; the Drives folder's path
/// stays as it is.
pub fn normalize(path: &Path) -> PathBuf {
    let p = path.as_os_str().as_bytes();
    if p == DRIVES_PATH.as_bytes() {
        return PathBuf::from(DRIVES_PATH);
    }
    let mut out: Vec<u8> = Vec::with_capacity(p.len());
    for part in p.split(|&c| c == b'/').filter(|s| !s.is_empty()) {
        match part {
            b"." => {}
            b".." => out.truncate(out.iter().rposition(|&c| c == b'/').unwrap_or(0)),
            _ => {
                out.push(b'/');
                out.extend_from_slice(part);
            }
        }
    }
    if out.is_empty() {
        out.push(b'/');
    }
    PathBuf::from(OsStr::from_bytes(&out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order_reads_numbers_and_ignores_case_and_dots() {
        assert_eq!(natural_order(b"file2", b"file10"), Ordering::Less);
        assert_eq!(natural_order(b"file10", b"file9"), Ordering::Greater);
        assert_eq!(natural_order(b"apple", b"Banana"), Ordering::Less);
        assert_eq!(natural_order(b"a", b"ab"), Ordering::Less);
        assert_eq!(natural_order(b".bashrc", b"config"), Ordering::Less);
        assert_eq!(natural_order(b"x007", b"x8"), Ordering::Less);
        assert_ne!(natural_order(b"Readme", b"readme"), Ordering::Equal);
    }

    #[test]
    fn matching_words_in_smart_case() {
        assert!(matches(b"Holiday Photo 2024.jpg", "photo 24"));
        assert!(!matches(b"Holiday Photo 2024.jpg", "photo 25"));
        assert!(matches(b"anything", ""));
        assert!(matches(b"README.md", "read"));
        assert!(!matches(b"README.md", "Read"));
        assert!(matches(b"Holiday Photo.jpg", "Photo  jpg"));
    }

    #[test]
    fn sizes_times_and_modes() {
        assert_eq!(format_size(1), "1 byte");
        assert_eq!(format_size(999), "999 bytes");
        assert_eq!(format_size(1500), "1.5 kB");
        assert_eq!(format_size(2_000_000_000), "2.0 GB");
        // Zig rounds the shortest decimal half up: 1.25 and 1.15 (1.1499... in binary).
        assert_eq!(format_size(1250), "1.3 kB");
        assert_eq!(format_size(1150), "1.2 kB");
        assert_eq!(format_size(999_950), "1000.0 kB");
        // The columns' sizes, as the Zig build's golden images show them; 12800 bytes is
        // 12.5 K, which Zig rounds up and Rust's `{:.0}` rounds to even.
        assert_eq!(compact_size(1023), "1023 B");
        assert_eq!(compact_size(2048), "2.0 K");
        assert_eq!(compact_size(52_000), "51 K");
        assert_eq!(compact_size(12_800), "13 K");
        assert_eq!(compact_size(2_400_000), "2.3 M");
        assert_eq!(
            format_time(1_791_900_300 * 1_000_000_000, 0),
            "2026-10-13 14:05"
        );
        // Half a second before the epoch is 1969: floor, not truncation.
        assert_eq!(format_time(-500_000_000, 0), "—");
        assert_eq!(format_time(0, 3600), "1970-01-01 01:00");
        assert_eq!(format_mode(0o751), "rwxr-x--x");
    }

    #[test]
    fn paths() {
        assert_eq!(parent(Path::new("/home")), Path::new("/"));
        assert_eq!(parent(Path::new("/home/user")), Path::new("/home"));
        assert_eq!(basename(Path::new("/home/user")), b"user");
        assert_eq!(join(Path::new("/"), b"a"), Path::new("/a"));
        assert_eq!(join(Path::new("/x"), b"/a"), Path::new("/x//a"));
        assert!(!valid_name(b"a/b"));
        assert!(!valid_name(b".."));
        assert!(valid_name(b"..a"));
        assert_eq!(normalize(Path::new("//a/./b/../c/")), Path::new("/a/c"));
        assert_eq!(normalize(Path::new("/a/../..")), Path::new("/"));
        assert_eq!(normalize(Path::new(DRIVES_PATH)), Path::new("//drives"));
        assert!(is_within(Path::new("/a/b"), Path::new("/a")));
        assert!(!is_within(Path::new("/ab"), Path::new("/a")));
    }

    fn entry(kind: Kind, size: u64) -> Entry {
        Entry {
            kind,
            size,
            ..Entry::unknown(b"")
        }
    }

    #[test]
    fn relative_names() {
        let mut b = Builder::new();
        b.add(b"sub/dir/file.txt", entry(Kind::File, 1));
        b.add(b"top", entry(Kind::File, 1));
        let l = b.finish("/x");
        assert_eq!(l.base(&l.entries[0]), b"file.txt");
        assert_eq!(l.dir_of(&l.entries[0]), b"sub/dir");
        assert_eq!(l.dir_of(&l.entries[1]), b"");
        assert_eq!(l.base(&l.entries[1]), b"top");
        assert_eq!(l.path_of(&l.entries[0]), Path::new("/x/sub/dir/file.txt"));
    }

    fn listing(items: &[(&str, Kind, u64)]) -> Listing {
        let mut b = Builder::new();
        for &(name, kind, size) in items {
            let hidden = name.starts_with('.');
            b.add(
                name.as_bytes(),
                Entry {
                    hidden,
                    ..entry(kind, size)
                },
            );
        }
        b.finish("/x")
    }

    #[test]
    fn descending_keeps_folders_first_and_ties_go_by_name() {
        let l = listing(&[
            ("b.txt", Kind::File, 5),
            ("Zed", Kind::Dir, 0),
            ("a10.txt", Kind::File, 5),
            ("a9.txt", Kind::File, 7),
            ("art", Kind::Dir, 0),
        ]);
        let by = |key, descending| Sort {
            key,
            descending,
            folders_first: true,
        };
        assert_eq!(sort(&l, by(SortKey::Name, false), |_| ()), [4, 1, 3, 2, 0]);
        // Descending reverses within folders and within files, not folders first.
        assert_eq!(sort(&l, by(SortKey::Name, true), |_| ()), [1, 4, 0, 2, 3]);
        // Equal sizes fall back to natural name order.
        assert_eq!(sort(&l, by(SortKey::Size, false), |_| ()), [4, 1, 2, 0, 3]);
        let unmixed = Sort {
            folders_first: false,
            ..by(SortKey::Name, false)
        };
        assert_eq!(sort(&l, unmixed, |_| ()), [3, 2, 4, 0, 1]);
        // By type: the caller's key, then the name.
        let types = ["Text", "", "Text", "Archive", ""];
        assert_eq!(
            sort(&l, by(SortKey::Type, false), |i| types[i as usize]),
            [4, 1, 3, 2, 0]
        );
        let unmixed_types = Sort {
            key: SortKey::Type,
            ..unmixed
        };
        assert_eq!(
            sort(&l, unmixed_types, |i| types[i as usize]),
            [4, 1, 3, 2, 0]
        );
    }

    #[test]
    fn type_filter_globs_ignore_case_and_mime_wildcards() {
        let l = listing(&[
            ("Photo.JPG", Kind::File, 1),
            ("notes.txt", Kind::File, 1),
            ("diagram", Kind::File, 1),
            ("docs", Kind::Dir, 0),
            (".hidden.jpg", Kind::File, 1),
        ]);
        let order = [0, 1, 2, 3, 4];
        let f = TypeFilter {
            globs: vec!["*.jp[e]g".into(), "*.jpg".into()],
            mimes: vec!["image/*".into()],
        };
        let types: [&[&str]; 5] = [
            &[],
            &["text/plain"],
            &["image/svg+xml", "application/xml"],
            &[],
            &[],
        ];
        let names = |i: u32| types[i as usize].iter().copied();
        assert_eq!(filter(&l, &order, "", false, Some(&f), names), [0, 2, 3]);
        assert_eq!(filter(&l, &order, "", true, Some(&f), names), [0, 2, 3, 4]);
        assert_eq!(
            filter(&l, &order, "o", false, None, |_| std::iter::empty()),
            [0, 1, 3]
        );
        // A subclass's parent counts, ignoring case; "text/*" is not "text/plain"'s prefix
        // without its slash.
        let xml = TypeFilter {
            globs: vec![],
            mimes: vec!["Application/XML".into(), "tex*".into()],
        };
        assert_eq!(filter(&l, &order, "", false, Some(&xml), names), [2, 3]);
    }

    #[test]
    fn globs() {
        assert!(glob_match(b"*.so.[0-9]*", b"libx.so.1"));
        assert!(!glob_match(b"*.so.[0-9]*", b"libx.so.a"));
        assert!(glob_match(b"[!a]bc", b"xbc"));
        assert!(!glob_match(b"[!a]bc", b"abc"));
        assert!(glob_match(b"[]]", b"]"));
        assert!(!glob_match(b"a?c", b"ac"));
        assert!(glob_match(b"*", b""));
    }

    #[test]
    fn reading_follows_links_but_not_dangling_ones() {
        let dir = std::env::temp_dir().join(format!("strider-model-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join(".dot"), b"hello").unwrap();
        std::os::unix::fs::symlink("sub", dir.join("to-sub")).unwrap();
        std::os::unix::fs::symlink("nowhere", dir.join("dangling")).unwrap();
        let l = read(&dir).unwrap();
        let get = |name: &[u8]| *l.entries.iter().find(|e| l.name(e) == name).unwrap();
        assert_eq!(l.entries.len(), 4);
        let dot = get(b".dot");
        assert_eq!(
            (dot.kind, dot.size, dot.hidden, dot.link),
            (Kind::File, 5, true, false)
        );
        let sub = get(b"sub");
        assert_eq!((sub.kind, sub.size, sub.link), (Kind::Dir, 0, false));
        let link = get(b"to-sub");
        assert_eq!((link.kind, link.size, link.link), (Kind::Dir, 0, true));
        let dangling = get(b"dangling");
        assert_eq!((dangling.kind, dangling.link), (Kind::Other, true));
        assert_eq!(read(&dir.join(".dot")), Err(ReadError::NotDir));
        assert_eq!(read(&dir.join("missing")), Err(ReadError::FileNotFound));
        fs::remove_dir_all(&dir).unwrap();
    }
}
