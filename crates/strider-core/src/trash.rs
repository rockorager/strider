//! The freedesktop.org trash: what is in it (the home trash and each mounted device's
//! `$topdir/.Trash/$uid` and `$topdir/.Trash-$uid`), with where each item was and when it was
//! deleted, finding where an item goes back to, and the info files trashing writes.

use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

use crate::model::{self, Listing};
use crate::options::{Sort, SortKey};

/// Where each entry of a trash listing came from, parallel to its entries.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Info {
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Item {
    /// Where it was; empty when its info file is missing or says nothing.
    pub original: PathBuf,
    /// DeletionDate as local wall-clock nanoseconds (written with no time zone), 0 if
    /// unknown.
    pub deleted: i64,
}

/// The trash directories to show: the home trash, then each mount point's that exists.
pub fn trash_dirs(home_trash: &Path, mount_points: &[PathBuf], uid: u32) -> Vec<PathBuf> {
    let mut out = vec![home_trash.to_owned()];
    for mp in mount_points {
        let top = crate::fsops::trim_slash(mp).as_os_str().as_bytes();
        for sub in [format!("/.Trash/{uid}"), format!("/.Trash-{uid}")] {
            let mut p = top.to_vec();
            p.extend_from_slice(sub.as_bytes());
            let p = PathBuf::from(OsStr::from_bytes(&p));
            if fs::symlink_metadata(&p).is_ok_and(|m| m.is_dir()) {
                out.push(p);
            }
        }
    }
    out
}

/// Lists every trash in `dirs`: a listing rooted at "/" whose names are the trashed files'
/// paths without the leading slash (so `path_of` gives where they are now), with the info
/// saying where they were. Hidden files are not hidden in the trash. Blocking.
pub fn list(dirs: &[PathBuf]) -> (Listing, Info) {
    let mut b = model::Builder::new();
    let mut info = Info::default();
    for dir in dirs {
        let files = dir.join("files");
        let Ok(read) = fs::read_dir(&files) else {
            continue;
        };
        for d in read.flatten() {
            let name = d.file_name().into_vec();
            let mut e = model::stat_entry(&d.path(), &name);
            e.hidden = false;
            let rel = model::join(&files, &name);
            b.add(&rel.as_os_str().as_bytes()[1..], e);
            info.items.push(read_item(dir, &name));
        }
    }
    (b.finish("/"), info)
}

fn read_item(dir: &Path, name: &[u8]) -> Item {
    let Ok(body) = fs::read(info_file(dir, name)) else {
        return Item::default();
    };
    let parsed = parse_info(&body);
    Item {
        original: decode_path(parsed.path).map_or_else(PathBuf::new, |p| absolute(dir, p)),
        deleted: parse_date(parsed.date),
    }
}

/// A recorded path made absolute: a device's own trash records paths relative to its top
/// directory.
fn absolute(dir: &Path, p: Vec<u8>) -> PathBuf {
    if p.first() == Some(&b'/') {
        return PathBuf::from(std::ffi::OsString::from_vec(p));
    }
    model::join(top_of(dir), &p)
}

fn info_file(dir: &Path, name: &[u8]) -> PathBuf {
    let mut file = name.to_vec();
    file.extend_from_slice(b".trashinfo");
    model::join(&dir.join("info"), &file)
}

/// The top directory a trash belongs to: "/x/.Trash-1000" → "/x", "/x/.Trash/1000" → "/x";
/// "" for the home trash.
pub fn top_of(dir: &Path) -> &Path {
    if model::basename(dir).starts_with(b".Trash-") {
        return model::parent(dir);
    }
    let up = model::parent(dir);
    if model::basename(up) == b".Trash" {
        return model::parent(up);
    }
    Path::new("")
}

/// Trash/files/NAME → Trash/info/NAME.trashinfo; None for a path not in a trash's files.
pub fn info_path_of(trashed: &Path) -> Option<PathBuf> {
    let files = model::parent(trashed);
    if model::basename(files) != b"files" {
        return None;
    }
    Some(info_file(model::parent(files), model::basename(trashed)))
}

/// Where a trashed file goes back to, from its info file.
pub fn original_path(trashed: &Path) -> Option<PathBuf> {
    let body = fs::read(info_path_of(trashed)?).ok()?;
    let p = decode_path(parse_info(&body).path)?;
    Some(absolute(model::parent(model::parent(trashed)), p))
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Parsed<'a> {
    pub path: &'a [u8],
    pub date: &'a [u8],
}

pub fn parse_info(body: &[u8]) -> Parsed<'_> {
    let mut p = Parsed::default();
    let mut in_section = false;
    for raw in body.split(|&c| c == b'\n') {
        let line = raw.trim_ascii();
        if line.first() == Some(&b'[') {
            in_section = line == b"[Trash Info]";
            continue;
        }
        if !in_section {
            continue;
        }
        if let Some(v) = line.strip_prefix(b"Path=") {
            p.path = v;
        }
        if let Some(v) = line.strip_prefix(b"DeletionDate=") {
            p.date = v;
        }
    }
    p
}

/// Percent-decodes a trashinfo Path.
pub fn decode_path(s: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'%' && i + 2 < s.len() {
            let hex = std::str::from_utf8(&s[i + 1..i + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(s[i]);
            i += 1;
        }
    }
    Some(out)
}

/// The info file for `recorded` (the path, relative to the device's top directory in a
/// device's own trash) deleted at `date` (local time, YYYY-MM-DDThh:mm:ss).
pub fn info_body(recorded: &[u8], date: &str) -> Vec<u8> {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = b"[Trash Info]\nPath=".to_vec();
    for &b in recorded {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(b);
        } else {
            out.extend_from_slice(&[b'%', HEX[usize::from(b >> 4)], HEX[usize::from(b & 15)]]);
        }
    }
    out.extend_from_slice(b"\nDeletionDate=");
    out.extend_from_slice(date.as_bytes());
    out.push(b'\n');
    out
}

/// "2026-10-13T14:05:09" as nanoseconds of that wall-clock time; 0 if it is not one.
pub fn parse_date(s: &[u8]) -> i64 {
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        std::str::from_utf8(s.get(r)?).ok()?.parse().ok()
    };
    let parsed = (|| {
        if s.len() < 19 {
            return None;
        }
        let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
        let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
        if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
            return None;
        }
        Some((days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se) * 1_000_000_000)
    })();
    parsed.unwrap_or(0)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// Sorts a trash listing's indices by deletion date (modified) or original location (any
/// other key), then by name.
pub fn sort_indices(l: &Listing, info: &Info, order: &mut [u32], s: Sort) {
    order.sort_unstable_by(|&a, &b| {
        let (ia, ib) = (&info.items[a as usize], &info.items[b as usize]);
        let ord = match s.key {
            SortKey::Modified => ia.deleted.cmp(&ib.deleted),
            _ => ia.original.as_os_str().cmp(ib.original.as_os_str()),
        }
        .then_with(|| {
            let (ea, eb) = (&l.entries[a as usize], &l.entries[b as usize]);
            model::natural_order(l.base(ea), l.base(eb))
        })
        .then_with(|| a.cmp(&b));
        if s.descending { ord.reverse() } else { ord }
    });
}

impl Info {
    /// Where entry `index` came from; an empty item past the end.
    pub fn get(&self, index: u32) -> Item {
        self.items.get(index as usize).cloned().unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trash_info() {
        let p = parse_info(
            b"[Trash Info]\nPath=/home/me/a%20b.txt\nDeletionDate=2026-10-13T14:05:09\n",
        );
        assert_eq!(decode_path(p.path).unwrap(), b"/home/me/a b.txt");
        assert_eq!(
            model::format_time(parse_date(p.date), 0),
            "2026-10-13 14:05"
        );
        assert_eq!(parse_date(b"2026-13-13T14:05:09"), 0);
        assert_eq!(
            top_of(Path::new("/media/usb/.Trash-1000")),
            Path::new("/media/usb")
        );
        assert_eq!(
            top_of(Path::new("/media/usb/.Trash/1000")),
            Path::new("/media/usb")
        );
        assert_eq!(
            top_of(Path::new("/home/me/.local/share/Trash")),
            Path::new("")
        );
        // Keys outside the section do not count.
        assert_eq!(parse_info(b"Path=/x\n[Other]\nPath=/y\n").path, b"");
    }

    #[test]
    fn info_bodies_round_trip() {
        let body = info_body("dir/a b%ü.txt".as_bytes(), "2026-10-13T14:05:09");
        let text = String::from_utf8(body.clone()).unwrap();
        assert_eq!(
            text,
            "[Trash Info]\nPath=dir/a%20b%25%C3%BC.txt\nDeletionDate=2026-10-13T14:05:09\n"
        );
        assert_eq!(
            decode_path(parse_info(&body).path).unwrap(),
            "dir/a b%ü.txt".as_bytes()
        );
        assert_eq!(
            info_path_of(Path::new("/t/Trash/files/a b")).unwrap(),
            Path::new("/t/Trash/info/a b.trashinfo")
        );
        assert_eq!(info_path_of(Path::new("/t/Trash/a")), None);
    }
}
