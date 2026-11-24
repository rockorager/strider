//! Archive listings for previews: ZIP (and its relatives: jar, epub, docx, ...) from its
//! central directory, and tar, plain or gzipped, by walking its headers. Every other format
//! is listed by libarchive's `bsdtar -tf`, which the app runs; [`parse_bsdtar`] reads what it
//! prints. Blocking: runs on a worker.

use std::fs::File;
use std::io::{self, Read};
use std::os::unix::fs::FileExt;
use std::path::Path;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub name: String,
    pub size: u64,
    pub dir: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Listing {
    pub entries: Vec<Entry>,
    /// There were more entries than the limit, or the archive ended early.
    pub truncated: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Zip,
    Tar,
    TarGz,
    /// Read by bsdtar.
    Other,
}

const ZIP_EXTS: &[&str] = &[
    ".zip", ".jar", ".apk", ".epub", ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp", ".whl",
    ".xpi", ".cbz", ".vsix", ".aar",
];
const OTHER_EXTS: &[&str] = &[
    ".tar.xz",
    ".txz",
    ".tar.zst",
    ".tzst",
    ".tar.bz2",
    ".tbz2",
    ".tbz",
    ".7z",
    ".rar",
    ".cbr",
    ".iso",
    ".xz",
    ".bz2",
    ".zst",
    ".lz",
    ".lzma",
    ".cpio",
    ".deb",
    ".rpm",
    ".cab",
    ".pkg.tar.zst",
    ".tar.lz",
    ".tar.lzma",
];

/// Reads at most this much of a tarball to list it.
const MAX_TAR_READ: u64 = 64 << 20;

/// The kind of archive a file name says, if any.
pub fn kind_of(name: &[u8]) -> Option<Kind> {
    if name.len() > 256 {
        return None;
    }
    let lower = name.to_ascii_lowercase();
    let ends = |e: &str| lower.ends_with(e.as_bytes());
    if ZIP_EXTS.iter().any(|e| ends(e)) {
        Some(Kind::Zip)
    } else if ends(".tar.gz") || ends(".tgz") {
        Some(Kind::TarGz)
    } else if ends(".tar") {
        Some(Kind::Tar)
    } else if OTHER_EXTS.iter().any(|e| ends(e)) {
        Some(Kind::Other)
    } else {
        None
    }
}

/// Lists up to `limit` entries of the ZIP or tar archive at `path`. [`Kind::Other`] is
/// bsdtar's to list, and fails with [`io::ErrorKind::Unsupported`].
pub fn list(path: &Path, kind: Kind, limit: usize) -> io::Result<Listing> {
    let mut l = Listing::default();
    match kind {
        Kind::Zip => list_zip(path, &mut l, limit)?,
        Kind::Tar => list_tar(path, &mut l, limit, false)?,
        Kind::TarGz => list_tar(path, &mut l, limit, true)?,
        Kind::Other => return Err(io::ErrorKind::Unsupported.into()),
    }
    Ok(l)
}

/// The listing in what `bsdtar -tf` printed, its own complaints left out; `truncated` says
/// its output was cut off.
pub fn parse_bsdtar(output: &[u8], truncated: bool, limit: usize) -> Listing {
    let mut l = Listing {
        entries: Vec::new(),
        truncated,
    };
    for line in output.split(|&b| b == b'\n') {
        if line.is_empty() || line.starts_with(b"bsdtar: ") {
            continue;
        }
        if l.entries.len() >= limit {
            l.truncated = true;
            break;
        }
        let dir = line.ends_with(b"/");
        let name = if dir { &line[..line.len() - 1] } else { line };
        l.entries.push(Entry {
            name: String::from_utf8_lossy(name).into_owned(),
            size: 0,
            dir,
        });
    }
    l
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "not a valid archive")
}

fn le16(b: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([b[at], b[at + 1]])
}

fn le32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

/// Reads the whole of `buf` at `off`, or fails.
fn read_at(f: &File, buf: &mut [u8], off: u64) -> io::Result<()> {
    f.read_exact_at(buf, off).map_err(|_| invalid())
}

fn list_zip(path: &Path, l: &mut Listing, limit: usize) -> io::Result<()> {
    let f = File::open(path)?;
    let size = f.metadata()?.len();
    if size < 22 {
        return Err(invalid());
    }
    // The end of central directory record is in the last 64 KiB + 22.
    let tail_len = size.min(65_557) as usize;
    let mut tail = vec![0; tail_len];
    read_at(&f, &mut tail, size - tail_len as u64)?;
    let eocd = (0..=tail_len - 22)
        .rev()
        .find(|&i| le32(&tail, i) == 0x0605_4b50)
        .ok_or_else(invalid)?;
    let count = usize::from(le16(&tail, eocd + 10));
    let cd_size = le32(&tail, eocd + 12);
    let cd_off = le32(&tail, eocd + 16);
    if u64::from(cd_off) + u64::from(cd_size) > size {
        return Err(invalid());
    }
    let mut cd = vec![0; cd_size as usize];
    read_at(&f, &mut cd, u64::from(cd_off))?;
    let mut p = 0;
    for _ in 0..count {
        if p + 46 > cd.len() || le32(&cd, p) != 0x0201_4b50 {
            break;
        }
        let entry_size = le32(&cd, p + 24);
        let name_len = usize::from(le16(&cd, p + 28));
        let extra_len = usize::from(le16(&cd, p + 30));
        let comment_len = usize::from(le16(&cd, p + 32));
        if p + 46 + name_len > cd.len() {
            break;
        }
        if l.entries.len() >= limit {
            l.truncated = true;
            break;
        }
        let name = &cd[p + 46..p + 46 + name_len];
        let dir = name.ends_with(b"/");
        l.entries.push(Entry {
            name: String::from_utf8_lossy(if dir { &name[..name_len - 1] } else { name })
                .into_owned(),
            size: u64::from(entry_size),
            dir,
        });
        p += 46 + name_len + extra_len + comment_len;
    }
    Ok(())
}

fn list_tar(path: &Path, l: &mut Listing, limit: usize, gz: bool) -> io::Result<()> {
    let f = File::open(path)?;
    if f.metadata()?.len() > MAX_TAR_READ {
        l.truncated = true;
    }
    let input = f.take(MAX_TAR_READ);
    if gz {
        walk_tar(flate2::read::GzDecoder::new(input), l, limit);
    } else {
        walk_tar(input, l, limit);
    }
    Ok(())
}

/// A tar header's number: octal digits, or base-256 for large sizes (GNU).
fn octal(field: &[u8]) -> u64 {
    if field.first().is_some_and(|b| b & 0x80 != 0) {
        return field[1..]
            .iter()
            .fold(0, |v, &b| v.wrapping_shl(8) | u64::from(b));
    }
    let mut v: u64 = 0;
    for &ch in field {
        if ch == 0 || ch == b' ' {
            if v != 0 {
                break;
            }
            continue;
        }
        if !(b'0'..=b'7').contains(&ch) {
            break;
        }
        v = v.wrapping_mul(8) + u64::from(ch - b'0');
    }
    v
}

/// Reads into `buf` until it is full or the input ends: how much it read, or None when the
/// input fails, as a corrupt gzip stream does.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> Option<usize> {
    let mut got = 0;
    while got < buf.len() {
        match r.read(&mut buf[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
    Some(got)
}

/// Skips `n` bytes; whether they were all there.
fn skip(r: &mut impl Read, n: u64) -> bool {
    io::copy(&mut r.take(n), &mut io::sink()).is_ok_and(|got| got == n)
}

/// The text before the first NUL.
fn until_nul(b: &[u8]) -> &[u8] {
    b.iter().position(|&c| c == 0).map_or(b, |n| &b[..n])
}

/// Lists the entries of a tar stream; one that ends early lists what came before, truncated.
fn walk_tar(mut r: impl Read, l: &mut Listing, limit: usize) {
    let mut hdr = [0u8; 512];
    let mut long_name: Option<Vec<u8>> = None;
    loop {
        match read_full(&mut r, &mut hdr) {
            Some(512) => {}
            Some(0) => return,
            _ => {
                l.truncated = true;
                return;
            }
        }
        if hdr.iter().all(|&b| b == 0) {
            return;
        }
        let size = octal(&hdr[124..136]);
        let typeflag = hdr[156];
        let padded = size.div_ceil(512) * 512;
        if matches!(typeflag, b'L' | b'x' | b'g') {
            // A GNU long name, or pax headers (whose path= we read).
            let mut body = vec![0; size.min(1 << 20) as usize];
            let got = read_full(&mut r, &mut body).unwrap_or(0);
            if !skip(&mut r, padded - got as u64) {
                l.truncated = true;
                return;
            }
            body.truncate(got);
            if typeflag == b'L' {
                long_name = Some(until_nul(&body).to_vec());
            } else if typeflag == b'x' {
                for rec in body.split(|&b| b == b'\n') {
                    if let Some(k) = rec.windows(6).position(|w| w == b" path=") {
                        long_name = Some(rec[k + 6..].to_vec());
                    }
                }
            }
            continue;
        }
        let mut name = match long_name.take() {
            Some(n) => n,
            None => {
                let base = until_nul(&hdr[..100]);
                let prefix = if &hdr[257..262] == b"ustar" {
                    until_nul(&hdr[345..500])
                } else {
                    b""
                };
                if prefix.is_empty() {
                    base.to_vec()
                } else {
                    [prefix, b"/", base].concat()
                }
            }
        };
        let dir = typeflag == b'5' || name.ends_with(b"/");
        if name.len() > 1 && name.ends_with(b"/") {
            name.pop();
        }
        if name.starts_with(b"./") {
            name.drain(..2);
        }
        if !name.is_empty() && name != b"." {
            if l.entries.len() >= limit {
                l.truncated = true;
                return;
            }
            l.entries.push(Entry {
                name: String::from_utf8_lossy(&name).into_owned(),
                size: if dir { 0 } else { size },
                dir,
            });
        }
        if !skip(&mut r, padded) {
            l.truncated = true;
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn archive_kinds_by_name() {
        assert_eq!(kind_of(b"book.EPUB"), Some(Kind::Zip));
        assert_eq!(kind_of(b"src.tar.gz"), Some(Kind::TarGz));
        assert_eq!(kind_of(b"a.tar"), Some(Kind::Tar));
        assert_eq!(kind_of(b"pkg.tar.zst"), Some(Kind::Other));
        assert_eq!(kind_of(b"notes.txt"), None);
    }

    // Archives the system's tools made list their files with sizes and their folders, from
    // a tarball plain and gzipped, and a zip when zip is installed.
    #[test]
    fn lists_archives_made_by_the_systems_tools() {
        let dir = std::env::temp_dir().join(format!("strider-archive-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src/sub")).unwrap();
        std::fs::write(dir.join("src/a.txt"), "hello").unwrap();
        std::fs::write(dir.join("src/sub/b.txt"), "x").unwrap();
        let sh = |cmd: &str| {
            Command::new("sh")
                .arg("-c")
                .arg(cmd)
                .current_dir(&dir)
                .status()
                .is_ok_and(|s| s.success())
        };
        assert!(sh("tar -czf t.tar.gz src && tar -cf t.tar src"));
        let mut cases = vec![("t.tar.gz", Kind::TarGz), ("t.tar", Kind::Tar)];
        if sh("zip -qr t.zip src 2>/dev/null || python3 -m zipfile -c t.zip src") {
            cases.push(("t.zip", Kind::Zip));
        }
        for (name, kind) in cases {
            let l = list(&dir.join(name), kind, 100).unwrap();
            let a = l.entries.iter().find(|e| e.name == "src/a.txt");
            assert_eq!(a.map(|e| e.size), Some(5), "{name}");
            assert!(
                l.entries.iter().any(|e| e.name == "src/sub" && e.dir),
                "{name}"
            );
            assert!(!l.truncated, "{name}");
            let short = list(&dir.join(name), kind, 1).unwrap();
            assert!(short.truncated && short.entries.len() == 1, "{name}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn bsdtar_output() {
        let l = parse_bsdtar(b"pkg/\npkg/a.txt\nbsdtar: Error exit delayed\n", false, 10);
        assert_eq!(
            l.entries,
            [
                Entry {
                    name: "pkg".into(),
                    size: 0,
                    dir: true
                },
                Entry {
                    name: "pkg/a.txt".into(),
                    size: 0,
                    dir: false
                },
            ]
        );
    }
}
