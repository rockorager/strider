//! `file://` URIs and the `text/uri-list` format (RFC 2483), which other applications use for
//! dragged and copied files, and GNOME's `x-special/gnome-copied-files` ("copy" or "cut", then
//! the URIs), which tells a paste whether to move.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// Appends `path` as a `file://` URI, percent-encoding every byte that is not unreserved or a
/// slash.
pub fn push_file_uri(out: &mut String, path: &Path) {
    out.push_str("file://");
    for &b in path.as_os_str().as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) {
            out.push(char::from(b));
        } else {
            const HEX: &[u8; 16] = b"0123456789ABCDEF";
            out.push('%');
            out.push(char::from(HEX[usize::from(b >> 4)]));
            out.push(char::from(HEX[usize::from(b & 15)]));
        }
    }
}

/// The local path of a file URI, decoded; None for other schemes, remote hosts, and
/// malformed escapes.
pub fn file_path(uri: &str) -> Option<PathBuf> {
    const PREFIX: &str = "file://";
    let head = uri.get(..PREFIX.len())?;
    if !head.eq_ignore_ascii_case(PREFIX) {
        return None;
    }
    let mut rest = &uri.as_bytes()[PREFIX.len()..];
    // file://localhost/path and file:///path are local; others are not.
    if rest.len() >= 10 && rest[..10].eq_ignore_ascii_case(b"localhost/") {
        rest = &rest[9..];
    }
    if rest.first() != Some(&b'/') {
        return None;
    }
    let mut out = Vec::with_capacity(rest.len());
    let mut i = 0;
    while i < rest.len() {
        if rest[i] == b'%' {
            let hex = std::str::from_utf8(rest.get(i + 1..i + 3)?).ok()?;
            let v = u8::from_str_radix(hex, 16).ok()?;
            if v == 0 {
                return None;
            }
            out.push(v);
            i += 3;
        } else {
            out.push(rest[i]);
            i += 1;
        }
    }
    Some(PathBuf::from(OsStr::from_bytes(&out)))
}

/// The URIs of a `text/uri-list`: lines ending in CRLF (or LF), without comments and blank
/// lines.
pub fn lines(list: &str) -> impl Iterator<Item = &str> {
    list.split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l).trim_matches([' ', '\t']))
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
}

/// Splits `x-special/gnome-copied-files` into whether it is a cut and its URI lines.
pub fn gnome_copied(data: &str) -> (bool, &str) {
    let (first, rest) = data.split_once('\n').unwrap_or((data, ""));
    match first.trim_matches([' ', '\r', '\t']) {
        "cut" => (true, rest),
        "copy" => (false, rest),
        _ => (false, data),
    }
}

/// Files for the clipboard, in the types file managers read: `text/uri-list`,
/// `x-special/gnome-copied-files` (with "copy" or "cut" first, so a paste here or in GNOME
/// Files moves cut files), KDE's cut marker, and the paths as plain text.
pub fn clipboard(paths: &[PathBuf], cut: bool) -> Vec<(&'static str, String)> {
    let mut list = String::new();
    for p in paths {
        push_file_uri(&mut list, p);
        list.push_str("\r\n");
    }
    let mut gnome = String::from(if cut { "cut" } else { "copy" });
    for p in paths {
        gnome.push('\n');
        push_file_uri(&mut gnome, p);
    }
    let text = paths
        .iter()
        .map(|p| p.to_string_lossy())
        .collect::<Vec<_>>()
        .join("\n");
    vec![
        ("text/uri-list", list),
        ("x-special/gnome-copied-files", gnome),
        (
            "application/x-kde-cutselection",
            if cut { "1" } else { "0" }.into(),
        ),
        ("text/plain;charset=utf-8", text),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_uris_round_trip() {
        let mut out = String::new();
        push_file_uri(&mut out, Path::new("/home/me/a b%c/ü.txt"));
        assert_eq!(out, "file:///home/me/a%20b%25c/%C3%BC.txt");
        assert_eq!(file_path(&out).unwrap(), Path::new("/home/me/a b%c/ü.txt"));
        assert_eq!(file_path("file://localhost/x").unwrap(), Path::new("/x"));
        assert_eq!(file_path("file://host/x"), None);
        assert_eq!(file_path("https://x/y"), None);
        assert_eq!(file_path("file:///a%2"), None);
        assert_eq!(file_path("file:///a%00b"), None);
    }

    #[test]
    fn uri_lists_and_gnome_copied() {
        let got: Vec<_> = lines("# comment\r\nfile:///a\r\n\r\nfile:///b\n").collect();
        assert_eq!(got, ["file:///a", "file:///b"]);
        assert_eq!(
            gnome_copied("cut\nfile:///a\nfile:///b"),
            (true, "file:///a\nfile:///b")
        );
        assert_eq!(gnome_copied("file:///a"), (false, "file:///a"));
    }

    // What yy and dd put on the clipboard reads back as the same files, cut or not, in each
    // type a paste looks at.
    #[test]
    fn the_clipboard_types_read_back() {
        let paths = [PathBuf::from("/w/a b"), PathBuf::from("/w/c")];
        let items = clipboard(&paths, true);
        let get = |m: &str| items.iter().find(|(k, _)| *k == m).unwrap().1.clone();
        assert_eq!(get("text/uri-list"), "file:///w/a%20b\r\nfile:///w/c\r\n");
        let gnome = get("x-special/gnome-copied-files");
        let (cut, uris) = gnome_copied(&gnome);
        assert!(cut);
        let back: Vec<_> = lines(uris).filter_map(file_path).collect();
        assert_eq!(back, paths);
        assert_eq!(get("application/x-kde-cutselection"), "1");
        assert_eq!(get("text/plain;charset=utf-8"), "/w/a b\n/w/c");
        let copied = clipboard(&[PathBuf::from("/x")], false);
        assert!(!gnome_copied(&copied[1].1).0);
    }
}
