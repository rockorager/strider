//! What file operations are and say, without doing them: their kinds, the answers to a
//! conflict, their errors, what they did for undo, the titles and summaries the tasks view and
//! status line show, chmod(1)'s modes, and the free names "keep both" picks.

use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use crate::model;

/// `MoveBack` moves each source to the exact path in its targets (undoing a move); `Restore`
/// does the same from the trash and removes the info files.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Copy,
    Move,
    Link,
    Trash,
    Delete,
    Restore,
    MoveBack,
    Chmod,
    Chown,
}

impl Kind {
    /// "Copying", for progress.
    pub fn doing(self) -> &'static str {
        match self {
            Kind::Copy => "Copying",
            Kind::Move | Kind::MoveBack => "Moving",
            Kind::Link => "Linking",
            Kind::Trash => "Trashing",
            Kind::Delete => "Deleting",
            Kind::Restore => "Restoring",
            Kind::Chmod => "Changing permissions",
            Kind::Chown => "Changing owners",
        }
    }

    /// "copy", for "Could not copy …".
    pub fn verb(self) -> &'static str {
        match self {
            Kind::Copy => "copy",
            Kind::Move | Kind::MoveBack => "move",
            Kind::Link => "link",
            Kind::Trash => "move to the trash",
            Kind::Delete => "delete",
            Kind::Restore => "restore",
            Kind::Chmod => "change the permissions of",
            Kind::Chown => "change the owner of",
        }
    }
}

/// An answer to a conflict: the name a file would land on exists.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Resolution {
    Replace,
    Skip,
    /// Under a free name, with " (2)" before the extension.
    KeepBoth,
    /// Two folders become one, their contents' own conflicts asked about in turn.
    Merge,
    Cancel,
}

impl Resolution {
    /// What a policy (an answer for every conflict) answers for one conflict: merging is for
    /// two folders, so it replaces anything else, and replacing a folder with a folder merges
    /// them.
    pub fn for_conflict(self, both_dirs: bool) -> Resolution {
        match self {
            Resolution::Merge if !both_dirs => Resolution::Replace,
            Resolution::Replace if both_dirs => Resolution::Merge,
            r => r,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OpError {
    Canceled,
    FileNotFound,
    AccessDenied,
    NoSpace,
    Exists,
    InvalidName,
    IntoItself,
    NameTooLong,
    NotEmpty,
    CrossDevice,
    OutOfMemory,
    Unexpected,
}

impl OpError {
    pub fn describe(self) -> &'static str {
        match self {
            OpError::Canceled => "Canceled",
            OpError::FileNotFound => "No such file or folder",
            OpError::AccessDenied => "Permission denied",
            OpError::NoSpace => "No space left on the device",
            OpError::Exists => "A file with that name already exists",
            OpError::InvalidName => "Names cannot be empty or contain “/”",
            OpError::IntoItself => "A folder cannot be copied or moved into itself",
            OpError::NameTooLong => "The name is too long",
            OpError::NotEmpty => "The folder is not empty",
            OpError::CrossDevice => "It is on another device",
            OpError::OutOfMemory => "Out of memory",
            OpError::Unexpected => "Unexpected error",
        }
    }
}

/// What the host is asked about: `src` would land on `dst`, which exists.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Conflict {
    pub src: PathBuf,
    pub dst: PathBuf,
    pub src_dir: bool,
    pub dst_dir: bool,
    pub src_size: u64,
    pub dst_size: u64,
    /// Modification times in nanoseconds since the epoch.
    pub src_mtime: i64,
    pub dst_mtime: i64,
}

impl Conflict {
    /// Looks at both sides as they are now.
    pub fn of(src: &Path, dst: &Path) -> Conflict {
        let s = model::stat_entry(src, model::basename(src));
        let d = model::stat_entry(dst, model::basename(dst));
        Conflict {
            src: src.to_owned(),
            dst: dst.to_owned(),
            src_dir: s.kind == model::Kind::Dir,
            dst_dir: d.kind == model::Kind::Dir,
            src_size: s.size,
            dst_size: d.size,
            src_mtime: s.mtime,
            dst_mtime: d.mtime,
        }
    }
}

/// One thing an operation did, for undo.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Done {
    pub from: PathBuf,
    pub to: PathBuf,
    /// A copy that replaced an existing file, which undo cannot bring back.
    pub replaced: bool,
}

/// What a finished operation did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Finished {
    pub kind: Kind,
    pub sources: Vec<PathBuf>,
    pub dest: PathBuf,
    pub targets: Vec<PathBuf>,
    /// Why it stopped early, and the file that was about.
    pub error: Option<(OpError, PathBuf)>,
    /// What was done, in order.
    pub done: Vec<Done>,
    /// Names the operation made in `dest`, so the view can select them.
    pub created: Vec<Vec<u8>>,
    /// Items the user skipped.
    pub skipped: u32,
    /// Items done, as progress counted them (what chmod and chown summarize).
    pub items_done: u64,
}

impl Finished {
    pub fn canceled(&self) -> bool {
        matches!(self.error, Some((OpError::Canceled, _)))
    }

    /// What it did, as the status line says it, and whether that is an error. Empty when
    /// there is nothing to say.
    pub fn summary(&self) -> (String, bool) {
        if let Some((err, path)) = &self.error {
            if *err == OpError::Canceled {
                return ("Canceled".into(), false);
            }
            let msg = format!(
                "Could not {} “{}”: {}",
                self.kind.verb(),
                show(model::basename(path)),
                err.describe()
            );
            return (msg, true);
        }
        if let Kind::Chmod | Kind::Chown = self.kind {
            let what = if self.kind == Kind::Chmod {
                "permissions"
            } else {
                "owner"
            };
            let msg = match self.items_done {
                1 => format!(
                    "Changed the {what} of “{}”",
                    show(model::basename(&self.sources[0]))
                ),
                n => format!("Changed the {what} of {n} items"),
            };
            return (msg, false);
        }
        let n = self.done.len();
        if n == 0 && self.kind != Kind::Delete {
            let msg = if self.skipped != 0 {
                "Nothing changed: every item was skipped"
            } else {
                ""
            };
            return (msg.into(), false);
        }
        let what = match (self.done.as_slice(), self.sources.as_slice()) {
            ([one], _) => show(model::basename(&one.from)),
            (_, [one]) => show(model::basename(one)),
            _ => String::new(),
        };
        let single = n == 1 || (self.kind == Kind::Delete && self.sources.len() == 1);
        let cnt = if self.kind == Kind::Delete {
            self.sources.len()
        } else {
            n
        };
        let (one, many) = match self.kind {
            Kind::Copy => (format!("Copied “{what}”"), format!("Copied {cnt} items")),
            Kind::Move | Kind::MoveBack => {
                (format!("Moved “{what}”"), format!("Moved {cnt} items"))
            }
            Kind::Link => (format!("Linked “{what}”"), format!("Linked {cnt} items")),
            Kind::Trash => (
                format!("“{what}” moved to the trash"),
                format!("{cnt} items moved to the trash"),
            ),
            Kind::Delete => (format!("“{what}” deleted"), format!("{cnt} items deleted")),
            Kind::Restore => (
                format!("“{what}” restored"),
                format!("{cnt} items restored"),
            ),
            Kind::Chmod | Kind::Chown => unreachable!("summarized above"),
        };
        (if single { one } else { many }, false)
    }
}

/// What an operation does, for the tasks view: "Copying 3 items to Music".
pub fn title(kind: Kind, sources: &[PathBuf], dest: &Path) -> String {
    let what = match sources {
        [one] => format!("“{}”", show(model::basename(one))),
        _ => format!("{} items", sources.len()),
    };
    let dest = match trim_slash(dest).as_os_str().as_bytes() {
        b"" => "/".to_owned(),
        d => show(model::basename(Path::new(OsStr::from_bytes(d)))),
    };
    match kind {
        Kind::Copy => format!("Copying {what} to {dest}"),
        Kind::Move => format!("Moving {what} to {dest}"),
        Kind::Link => format!("Linking {what} in {dest}"),
        Kind::MoveBack => format!("Moving {what} back"),
        Kind::Trash => format!("Moving {what} to the trash"),
        Kind::Delete => format!("Deleting {what}"),
        Kind::Restore => format!("Restoring {what}"),
        Kind::Chmod => format!("Changing the permissions of {what}"),
        Kind::Chown => format!("Changing the owner of {what}"),
    }
}

fn show(name: &[u8]) -> String {
    String::from_utf8_lossy(name).into_owned()
}

/// "-R" before or after the rest of chmod's or chown's arguments.
pub fn recursive_flag(args: &str) -> (bool, &str) {
    let t = args.trim_matches(' ');
    if let Some(rest) = t.strip_prefix("-R ") {
        return (true, rest.trim_matches(' '));
    }
    if let Some(rest) = t.strip_suffix(" -R") {
        return (true, rest.trim_matches(' '));
    }
    (false, t)
}

// Modes ---------------------------------------------------------------------------------------

/// Whether `spec` is a mode chmod(1) takes: octal ("755"), or symbolic clauses separated by
/// commas ("u+x", "go-w", "a=rX", "+x").
pub fn parse_mode(spec: &str) -> bool {
    apply_mode(spec, 0o644, false, 0o022).is_some()
}

/// The permission bits `spec` makes of `old`, as chmod(1) does: X adds execute only to
/// folders and files executable by someone already; clauses without u, g, o, or a leave the
/// bits the umask masks alone. None if `spec` is not a mode.
pub fn apply_mode(spec: &str, old: u32, is_dir: bool, umask: u32) -> Option<u32> {
    if spec.is_empty() {
        return None;
    }
    if let Ok(m) = u32::from_str_radix(spec, 8) {
        if spec.len() > 4 || m > 0o7777 {
            return None;
        }
        // Like GNU chmod, a short octal mode keeps a folder's setuid and setgid bits.
        return Some(if is_dir && spec.len() < 4 {
            m | (old & 0o6000)
        } else {
            m
        });
    }
    let mut mode = old;
    for clause in spec.as_bytes().split(|&c| c == b',') {
        let mut i = 0;
        let mut who = 0;
        while let Some(c) = clause.get(i) {
            who |= match c {
                b'u' => 0o4700,
                b'g' => 0o2070,
                b'o' => 0o1007,
                b'a' => 0o7777,
                _ => break,
            };
            i += 1;
        }
        let masked = who == 0;
        if masked {
            who = 0o7777;
        }
        if i == clause.len() {
            return None;
        }
        while i < clause.len() {
            let action = clause[i];
            if !matches!(action, b'+' | b'-' | b'=') {
                return None;
            }
            i += 1;
            let mut bits = 0;
            while let Some(&c) = clause.get(i).filter(|c| !matches!(c, b'+' | b'-' | b'=')) {
                bits |= match c {
                    b'r' => 0o444,
                    b'w' => 0o222,
                    b'x' => 0o111,
                    b'X' if is_dir || mode & 0o111 != 0 => 0o111,
                    b'X' => 0,
                    b's' => 0o6000,
                    b't' => 0o1000,
                    _ => return None,
                };
                i += 1;
            }
            let keep = if masked { !umask } else { 0o7777 };
            let affected = bits & who & keep;
            mode = match action {
                b'+' => mode | affected,
                b'-' => mode & !affected,
                _ => (mode & !(who & keep)) | affected,
            };
        }
    }
    Some(mode & 0o7777)
}

// Names ---------------------------------------------------------------------------------------

/// `dir` without its trailing slash; "" for the root, so that joining a name with a slash
/// gives "/name".
pub fn trim_slash(dir: &Path) -> &Path {
    let d = dir.as_os_str().as_bytes();
    let t = match d {
        [_] => &d[..0],
        [rest @ .., b'/'] => rest,
        _ => d,
    };
    Path::new(OsStr::from_bytes(t))
}

/// `dir/stem (k).ext`, with ".tar.gz" and the like kept whole.
pub fn numbered(dir: &Path, name: &[u8], k: u32) -> PathBuf {
    let (mut stem, mut ext) = match name.iter().rposition(|&c| c == b'.') {
        None | Some(0) => (name, &name[name.len()..]),
        Some(d) => name.split_at(d),
    };
    if stem.ends_with(b".tar") {
        (stem, ext) = name.split_at(stem.len() - 4);
    }
    let mut out = trim_slash(dir).as_os_str().as_bytes().to_vec();
    out.push(b'/');
    out.extend_from_slice(stem);
    out.extend_from_slice(format!(" ({k})").as_bytes());
    out.extend_from_slice(ext);
    PathBuf::from(OsStr::from_bytes(&out))
}

/// `dir/name`, or with " (2)", " (3)", ... before the extension if that exists.
pub fn free_name(dir: &Path, name: &[u8]) -> Result<PathBuf, OpError> {
    let first = model::join(trim_slash(dir), name);
    if !exists(&first) {
        return Ok(first);
    }
    (2..10000)
        .map(|k| numbered(dir, name, k))
        .find(|p| !exists(p))
        .ok_or(OpError::Exists)
}

/// Whether anything, a dangling link too, is at `path`.
pub fn exists(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_as_chmod_takes_them() {
        let check = |spec, old, dir, want: Option<u32>| {
            assert_eq!(apply_mode(spec, old, dir, 0o022), want, "{spec} on {old:o}");
        };
        check("755", 0o644, false, Some(0o755));
        check("0600", 0o2755, true, Some(0o600));
        // Short octal modes keep a folder's setgid bit, as GNU chmod does.
        check("755", 0o2700, true, Some(0o2755));
        check("u+x", 0o644, false, Some(0o744));
        check("go-w", 0o666, false, Some(0o644));
        check("u=rw,go=", 0o777, false, Some(0o600));
        check("ug+rw,o-rwx", 0o604, false, Some(0o660));
        // X: execute only for folders and files someone may run already.
        check("a=rX", 0o644, false, Some(0o444));
        check("a=rX", 0o744, false, Some(0o555));
        check("a=rX", 0o700, true, Some(0o555));
        // Without u, g, o, or a, the umask's bits stay as they were.
        check("+w", 0o444, false, Some(0o644));
        check("+x", 0o644, false, Some(0o755));
        check("=r", 0o666, false, Some(0o444 | 0o022));
        check("g+s,+t", 0o755, true, Some(0o3755));
        check("u+x-w", 0o644, false, Some(0o544));
        for bad in ["", "u", "u+q", "8", "77777", "u+x,", "+x y"] {
            check(bad, 0o644, false, None);
        }
    }

    // A policy of merging replaces files, and one of replacing merges folders.
    #[test]
    fn policies_fit_the_conflict() {
        use Resolution::*;
        assert_eq!(Merge.for_conflict(false), Replace);
        assert_eq!(Merge.for_conflict(true), Merge);
        assert_eq!(Replace.for_conflict(true), Merge);
        assert_eq!(Replace.for_conflict(false), Replace);
        assert_eq!(Skip.for_conflict(true), Skip);
    }

    #[test]
    fn numbered_names_keep_extensions() {
        let n = |name: &str, dir: &str| numbered(Path::new(dir), name.as_bytes(), 2);
        assert_eq!(n("f.txt", "/a"), Path::new("/a/f (2).txt"));
        assert_eq!(n("x.tar.gz", "/a/"), Path::new("/a/x (2).tar.gz"));
        assert_eq!(n(".bashrc", "/"), Path::new("/.bashrc (2)"));
        assert_eq!(n("Makefile", "/a"), Path::new("/a/Makefile (2)"));
        assert_eq!(trim_slash(Path::new("/")), Path::new(""));
    }

    #[test]
    fn recursive_flags() {
        assert_eq!(recursive_flag(" -R 755"), (true, "755"));
        assert_eq!(recursive_flag("u+x -R"), (true, "u+x"));
        assert_eq!(recursive_flag("u+x"), (false, "u+x"));
    }

    fn finished(kind: Kind, sources: &[&str], done: &[(&str, &str)]) -> Finished {
        Finished {
            kind,
            sources: sources.iter().map(PathBuf::from).collect(),
            dest: PathBuf::from("/d"),
            targets: Vec::new(),
            error: None,
            done: done
                .iter()
                .map(|(f, t)| Done {
                    from: f.into(),
                    to: t.into(),
                    replaced: false,
                })
                .collect(),
            created: Vec::new(),
            skipped: 0,
            items_done: 0,
        }
    }

    #[test]
    fn summaries_and_titles() {
        let f = finished(Kind::Copy, &["/a/x", "/a/y"], &[("/a/x", "/d/x")]);
        assert_eq!(f.summary(), ("Copied “x”".into(), false));
        let mut f = finished(Kind::Delete, &["/a/x", "/a/y"], &[]);
        assert_eq!(f.summary().0, "2 items deleted");
        f.error = Some((OpError::AccessDenied, "/a/y".into()));
        assert_eq!(
            f.summary(),
            ("Could not delete “y”: Permission denied".into(), true)
        );
        let mut f = finished(Kind::Move, &["/a/x"], &[]);
        f.skipped = 1;
        assert_eq!(f.summary().0, "Nothing changed: every item was skipped");
        assert_eq!(
            title(Kind::Copy, &f.sources, Path::new("/home/me/Music/")),
            "Copying “x” to Music"
        );
        assert_eq!(
            title(Kind::Move, &[], Path::new("/")),
            "Moving 0 items to /"
        );
    }
}
