//! The worker: counts what an operation has to do, then does it, source by source, as
//! fsops.zig does. It waits on the job's gate when the chart holds it or asks the host about a
//! conflict, and stops at the first error.

use std::ffi::OsString;
use std::fs::{self, File, FileTimes, Metadata, OpenOptions, Permissions};
use std::io::{self, Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{OnceLock, PoisonError};

use rustix::fs::{CWD, Mode, OFlags, RenameFlags};
use rustix::io::Errno;
use strider_core::fsops::{self, Conflict, Done, Finished, Kind, OpError, Resolution};
use strider_core::{model, trash};
use strider_machines::operation::{End, OpEv};

use super::{Request, Shared, lock};

/// Why an operation stopped, and the file that was about.
struct Fail(OpError, PathBuf);

type Res<T> = Result<T, Fail>;

fn fail(path: &Path, e: &io::Error) -> Fail {
    Fail(op_error(e), path.to_owned())
}

fn canceled() -> Fail {
    Fail(OpError::Canceled, PathBuf::new())
}

pub(super) fn op_error(e: &io::Error) -> OpError {
    match e.raw_os_error().unwrap_or(0) {
        libc::ENOENT | libc::ENOTDIR => OpError::FileNotFound,
        libc::EACCES | libc::EPERM | libc::EROFS => OpError::AccessDenied,
        libc::ENOSPC | libc::EDQUOT => OpError::NoSpace,
        libc::EEXIST => OpError::Exists,
        libc::ENOTEMPTY => OpError::NotEmpty,
        libc::ENAMETOOLONG => OpError::NameTooLong,
        libc::ENOMEM => OpError::OutOfMemory,
        libc::EINVAL => OpError::IntoItself,
        libc::EXDEV => OpError::CrossDevice,
        _ => OpError::Unexpected,
    }
}

pub(super) fn run(sh: &Shared) {
    let req = &sh.request;
    let mut w = Worker {
        sh,
        req,
        done: Vec::new(),
        created: Vec::new(),
        skipped: 0,
    };
    w.scan();
    sh.send(OpEv::Counted);
    let error = req
        .sources
        .iter()
        .enumerate()
        .try_for_each(|(i, src)| w.one(src, i))
        .err();
    let end = match &error {
        None => End::Done,
        Some(Fail(OpError::Canceled, _)) => End::Cancelled,
        Some(_) => End::Failed,
    };
    *lock(&sh.finished) = Some(Finished {
        kind: req.kind,
        sources: req.sources.clone(),
        dest: req.dest.clone(),
        targets: req.targets.clone(),
        error: error.map(|Fail(e, p)| (e, p)),
        done: w.done,
        created: w.created,
        skipped: w.skipped,
        items_done: sh.items_done.load(Ordering::Relaxed),
    });
    sh.send(OpEv::Ended(end));
}

struct Worker<'a> {
    sh: &'a Shared,
    req: &'a Request,
    done: Vec<Done>,
    created: Vec<Vec<u8>>,
    skipped: u32,
}

fn add(counter: &AtomicU64, n: u64) {
    counter.fetch_add(n, Ordering::Relaxed);
}

/// The names in a folder, without "." and "..", reading it without following a link to it
/// (so deleting a link never deletes what it points to). A read that fails part way ends the
/// list, as fsops' DirIter does.
fn children(dir: &Path) -> io::Result<Vec<OsString>> {
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let fd = rustix::fs::openat(CWD, dir, flags, Mode::empty())?;
    let names = rustix::fs::Dir::new(fd)?
        .map_while(Result::ok)
        .map(|e| e.file_name().to_bytes().to_vec())
        .filter(|n| n != b"." && n != b"..")
        .map(OsString::from_vec)
        .collect();
    Ok(names)
}

fn join(dir: &Path, name: &OsString) -> PathBuf {
    model::join(dir, name.as_bytes())
}

impl Worker<'_> {
    /// Waits while paused, then stops if cancelled.
    fn check(&self) -> Res<()> {
        let sh = self.sh;
        if sh.paused.load(Ordering::Acquire) {
            let mut g = lock(&sh.gate);
            while sh.paused.load(Ordering::Acquire) && !sh.cancel.load(Ordering::Acquire) {
                g = sh.turn.wait(g).unwrap_or_else(PoisonError::into_inner);
            }
        }
        if sh.cancel.load(Ordering::Acquire) {
            return Err(canceled());
        }
        Ok(())
    }

    fn set_current(&self, path: &Path) {
        *lock(&self.sh.current) = String::from_utf8_lossy(model::basename(path)).into_owned();
    }

    fn record(&mut self, from: &Path, to: &Path, replaced: bool) {
        self.done.push(Done {
            from: from.to_owned(),
            to: to.to_owned(),
            replaced,
        });
    }

    fn walks(&self) -> bool {
        match self.req.kind {
            Kind::Copy | Kind::Delete => true,
            Kind::Chmod | Kind::Chown => self.req.recursive,
            _ => false,
        }
    }

    /// Counts files and bytes, for progress. Moves within one file system and deletes count
    /// items only.
    fn scan(&self) {
        for src in &self.req.sources {
            if self.sh.cancel.load(Ordering::Acquire) {
                return;
            }
            self.scan_tree(src, self.req.kind == Kind::Copy, self.walks());
        }
    }

    /// Counts `path`, its bytes if `bytes`, and what is in it if `walk`.
    fn scan_tree(&self, path: &Path, bytes: bool, walk: bool) {
        let Ok(meta) = fs::symlink_metadata(path) else {
            return;
        };
        add(&self.sh.items_total, 1);
        if meta.is_file() && bytes {
            add(&self.sh.bytes_total, meta.len());
        }
        if !meta.is_dir() || !walk {
            return;
        }
        for name in children(path).unwrap_or_default() {
            if self.sh.cancel.load(Ordering::Acquire) {
                return;
            }
            self.scan_tree(&join(path, &name), bytes, walk);
        }
    }

    fn one(&mut self, src: &Path, index: usize) -> Res<()> {
        self.check()?;
        self.set_current(src);
        match self.req.kind {
            Kind::Copy | Kind::Move | Kind::Link => {
                let dest = &self.req.dest;
                // A folder into itself or below itself.
                if self.req.kind != Kind::Link && model::is_within(dest, src) {
                    return Err(Fail(OpError::IntoItself, src.to_owned()));
                }
                let same_dir = model::parent(src) == dest.as_path();
                if self.req.kind == Kind::Move && same_dir {
                    return Ok(());
                }
                let target = model::join(fsops::trim_slash(dest), model::basename(src));
                if let Some(t) = self.place(src, target, same_dir)? {
                    self.created.push(model::basename(&t).to_vec());
                }
                Ok(())
            }
            Kind::Trash => self.trash(src),
            Kind::Delete => self.delete_tree(src),
            Kind::Restore | Kind::MoveBack => self.restore(src, &self.req.targets[index]),
            // Links named on the command line are followed, as chmod(1) and chown(1) do;
            // links inside folders are not.
            Kind::Chmod | Kind::Chown => self.attr_tree(src, true),
        }
    }

    /// Asks the chart about `dst` existing, which applies its policy or asks the host, and
    /// waits for the answer, waking for a cancel too.
    fn resolve(&self, src: &Path, dst: &Path) -> Res<Resolution> {
        let c = Conflict::of(src, dst);
        let both_dirs = c.src_dir && c.dst_dir;
        *lock(&self.sh.conflict) = Some(c);
        lock(&self.sh.gate).answer = None;
        self.sh.send(OpEv::Conflict { both_dirs });
        let sh = self.sh;
        let mut g = lock(&sh.gate);
        loop {
            if sh.cancel.load(Ordering::Acquire) {
                return Err(canceled());
            }
            match g.answer.take() {
                Some(Resolution::Cancel) => return Err(canceled()),
                Some(r) => return Ok(r),
                None => g = sh.turn.wait(g).unwrap_or_else(PoisonError::into_inner),
            }
        }
    }

    fn free_name(&self, dir: &Path, name: &[u8]) -> Res<PathBuf> {
        fsops::free_name(dir, name).map_err(|e| Fail(e, model::join(dir, name)))
    }

    /// Copies, moves, or links `src` to `target`, resolving a conflict there. Returns where
    /// it went, or None if skipped.
    fn place(&mut self, src: &Path, mut target: PathBuf, duplicate: bool) -> Res<Option<PathBuf>> {
        let mut replaced = false;
        if fsops::exists(&target) {
            let r = if duplicate {
                Resolution::KeepBoth
            } else {
                self.resolve(src, &target)?
            };
            match r {
                Resolution::Skip => {
                    self.skipped += 1;
                    add(&self.sh.items_done, 1);
                    return Ok(None);
                }
                Resolution::Cancel => return Err(canceled()),
                Resolution::KeepBoth => {
                    target = self.free_name(model::parent(&target), model::basename(&target))?;
                }
                Resolution::Replace => {
                    // Moving a file onto itself (another name for it) does nothing.
                    if src == target {
                        return Ok(None);
                    }
                    self.delete_quiet(&target)?;
                    replaced = true;
                }
                Resolution::Merge => {
                    self.merge(src, &target)?;
                    self.record(src, &target, true);
                    return Ok(Some(target));
                }
            }
        }
        match self.req.kind {
            Kind::Move => self.move_to(src, &target)?,
            // A symbolic link to the source, by its absolute path.
            Kind::Link => {
                std::os::unix::fs::symlink(src, &target).map_err(|e| fail(src, &e))?;
                add(&self.sh.items_done, 1);
            }
            _ => self.copy_tree(src, &target)?,
        }
        self.record(src, &target, replaced);
        Ok(Some(target))
    }

    /// Copies or moves `src` to `target`, which is free.
    fn transfer(&self, src: &Path, target: &Path) -> Res<()> {
        if self.req.kind == Kind::Move {
            self.move_to(src, target)
        } else {
            self.copy_tree(src, target)
        }
    }

    /// Copies or moves the contents of folder `src` into folder `dst`, resolving conflicts
    /// inside; a move removes `src` afterwards, unless what was skipped is still in it.
    fn merge(&mut self, src: &Path, dst: &Path) -> Res<()> {
        if !fs::symlink_metadata(src).is_ok_and(|m| m.is_dir()) {
            // A file onto a folder or the reverse cannot merge: replace.
            self.delete_quiet(dst)?;
            return self.transfer(src, dst);
        }
        for name in children(src).map_err(|e| fail(src, &e))? {
            self.check()?;
            let (child_src, child_dst) = (join(src, &name), join(dst, &name));
            self.set_current(&child_src);
            if !fsops::exists(&child_dst) {
                self.transfer(&child_src, &child_dst)?;
                continue;
            }
            match self.resolve(&child_src, &child_dst)? {
                Resolution::Skip => self.skipped += 1,
                Resolution::Cancel => return Err(canceled()),
                Resolution::KeepBoth => {
                    let t = self.free_name(dst, name.as_bytes())?;
                    self.transfer(&child_src, &t)?;
                }
                Resolution::Replace => {
                    self.delete_quiet(&child_dst)?;
                    self.transfer(&child_src, &child_dst)?;
                }
                Resolution::Merge => self.merge(&child_src, &child_dst)?,
            }
        }
        if self.req.kind == Kind::Move {
            let _ = fs::remove_dir(src);
        }
        Ok(())
    }

    /// Renames `src` to `target`, or copies and deletes it on another file system.
    fn move_to(&self, src: &Path, target: &Path) -> Res<()> {
        match rustix::fs::renameat_with(CWD, src, CWD, target, RenameFlags::NOREPLACE) {
            Ok(()) => {
                add(&self.sh.items_done, 1);
                return Ok(());
            }
            Err(Errno::XDEV) => {}
            Err(e) => return Err(fail(src, &e.into())),
        }
        // Count the bytes now that they must be copied, the whole tree's.
        self.scan_tree(src, true, true);
        self.copy_tree(src, target)?;
        self.delete_tree(src)
    }

    fn copy_tree(&self, src: &Path, target: &Path) -> Res<()> {
        self.check()?;
        let meta = fs::symlink_metadata(src).map_err(|e| fail(src, &e))?;
        let mode = meta.mode() & 0o7777;
        let kind = meta.file_type();
        if kind.is_dir() {
            fs::DirBuilder::new()
                .mode(mode | 0o700)
                .create(target)
                .map_err(|e| fail(target, &e))?;
            add(&self.sh.items_done, 1);
            for name in children(src).map_err(|e| fail(src, &e))? {
                self.copy_tree(&join(src, &name), &join(target, &name))?;
            }
            let _ = fs::set_permissions(target, Permissions::from_mode(mode));
        } else if kind.is_symlink() {
            let to = fs::read_link(src).map_err(|e| fail(src, &e))?;
            std::os::unix::fs::symlink(to, target).map_err(|e| fail(target, &e))?;
            add(&self.sh.items_done, 1);
        } else if kind.is_file() {
            self.copy_file(src, target, mode, &meta)?;
        } else {
            // Devices, sockets, and pipes are not copied.
            add(&self.sh.items_done, 1);
        }
        Ok(())
    }

    /// Copies a file's bytes and times, removing the copy if that fails or is cancelled.
    fn copy_file(&self, src: &Path, target: &Path, mode: u32, meta: &Metadata) -> Res<()> {
        self.set_current(src);
        let input = File::open(src).map_err(|e| fail(src, &e))?;
        let out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(target)
            .map_err(|e| fail(target, &e))?;
        if let Err(f) = self.pump(&input, &out, src, target) {
            drop(out);
            let _ = fs::remove_file(target);
            return Err(f);
        }
        if let (Ok(a), Ok(m)) = (meta.accessed(), meta.modified()) {
            let _ = out.set_times(FileTimes::new().set_accessed(a).set_modified(m));
        }
        add(&self.sh.items_done, 1);
        Ok(())
    }

    /// copy_file_range in chunks, so that cancelling and progress work for large files (and
    /// reflinks or server-side copies happen where the file system offers them); read and
    /// write where it is refused.
    fn pump(&self, input: &File, out: &File, src: &Path, target: &Path) -> Res<()> {
        const CHUNK: usize = 4 << 20;
        let mut buf = Vec::new();
        loop {
            self.check()?;
            let n = if buf.is_empty() {
                match rustix::fs::copy_file_range(input, None, out, None, CHUNK) {
                    Ok(n) => n,
                    Err(Errno::INTR) => continue,
                    Err(Errno::XDEV | Errno::INVAL | Errno::OPNOTSUPP | Errno::NOSYS) => {
                        buf = vec![0; 128 * 1024];
                        continue;
                    }
                    Err(e) => return Err(fail(target, &e.into())),
                }
            } else {
                let n = match (&*input).read(&mut buf) {
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(fail(src, &e)),
                };
                (&*out).write_all(&buf[..n]).map_err(|e| fail(target, &e))?;
                n
            };
            if n == 0 {
                return Ok(());
            }
            add(&self.sh.bytes_done, n as u64);
        }
    }

    fn delete_tree(&self, path: &Path) -> Res<()> {
        self.check()?;
        match fs::remove_file(path) {
            Ok(()) => {
                add(&self.sh.items_done, 1);
                return Ok(());
            }
            Err(e) if matches!(e.raw_os_error(), Some(libc::EISDIR | libc::EPERM)) => {}
            Err(e) => return Err(fail(path, &e)),
        }
        for name in children(path).map_err(|e| fail(path, &e))? {
            self.delete_tree(&join(path, &name))?;
        }
        fs::remove_dir(path).map_err(|e| fail(path, &e))?;
        add(&self.sh.items_done, 1);
        Ok(())
    }

    /// Deletes what a replace overwrites, without counting it as progress.
    fn delete_quiet(&self, path: &Path) -> Res<()> {
        let before = self.sh.items_done.load(Ordering::Relaxed);
        self.delete_tree(path)?;
        self.sh.items_done.store(before, Ordering::Relaxed);
        Ok(())
    }

    /// The freedesktop.org trash: the file moves to Trash/files under a free name, with
    /// Trash/info/NAME.trashinfo saying where it was and when. Files on other devices go to
    /// that device's $topdir/.Trash-$uid, as the specification says.
    fn trash(&mut self, src: &Path) -> Res<()> {
        let (dir, top) =
            trash_dir_for(&self.req.home_trash, src).map_err(|e| Fail(e, src.to_owned()))?;
        let files = dir.join("files");
        let info_dir = dir.join("info");
        for d in [&files, &info_dir] {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(d)
                .map_err(|e| fail(d, &e))?;
        }
        // Claim a name by creating its info file exclusively, so that two trashes never claim
        // the same one.
        let name = model::basename(src);
        let mut claimed = None;
        for k in 1..10000 {
            let target = if k == 1 {
                model::join(&files, name)
            } else {
                fsops::numbered(&files, name, k)
            };
            let mut info_name = model::basename(&target).to_vec();
            info_name.extend_from_slice(b".trashinfo");
            let info = model::join(&info_dir, &info_name);
            let opened = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&info);
            match opened {
                // A file with no info: leave both alone.
                Ok(_) if fsops::exists(&target) => {
                    let _ = fs::remove_file(&info);
                }
                Ok(f) => {
                    claimed = Some((target, info, f));
                    break;
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(fail(&info, &e)),
            }
        }
        let Some((target, info, mut f)) = claimed else {
            return Err(Fail(OpError::Exists, src.to_owned()));
        };
        // Paths in a device's own trash are relative to its top directory.
        let s = src.as_os_str().as_bytes();
        let t = top.as_os_str().as_bytes();
        let recorded = if !t.is_empty() && model::is_within(src, &top) {
            s.get(t.len() + usize::from(t.len() > 1)..)
                .unwrap_or_default()
        } else {
            s
        };
        let _ = f.write_all(&trash::info_body(recorded, &local_now()));
        drop(f);
        if let Err(e) = self.move_to(src, &target) {
            let _ = fs::remove_file(&info);
            return Err(e);
        }
        self.record(src, &target, false);
        Ok(())
    }

    /// Moves a trashed file (in some Trash/files), or for move back any file, to `target`,
    /// resolving a conflict there; a restore removes the info file.
    fn restore(&mut self, from: &Path, target: &Path) -> Res<()> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(model::parent(target))
            .map_err(|e| fail(target, &e))?;
        let mut to = target.to_owned();
        if fsops::exists(target) {
            match self.resolve(from, target)? {
                Resolution::Skip => {
                    self.skipped += 1;
                    return Ok(());
                }
                Resolution::Cancel => return Err(canceled()),
                Resolution::KeepBoth => {
                    to = self.free_name(model::parent(target), model::basename(target))?
                }
                Resolution::Replace | Resolution::Merge => self.delete_quiet(target)?,
            }
        }
        self.move_to(from, &to)?;
        if self.req.kind == Kind::Restore
            && let Some(info) = trash::info_path_of(from)
        {
            let _ = fs::remove_file(info);
        }
        self.record(from, &to, false);
        Ok(())
    }

    /// chmod or chown on `path`, and below it when recursive.
    fn attr_tree(&self, path: &Path, follow: bool) -> Res<()> {
        self.check()?;
        let meta = if follow {
            fs::metadata(path)
        } else {
            fs::symlink_metadata(path)
        };
        let meta = meta.map_err(|e| fail(path, &e))?;
        let kind = meta.file_type();
        let changed = if self.req.kind == Kind::Chmod {
            // chmod cannot change a link's own bits.
            if kind.is_symlink() {
                Ok(())
            } else {
                let mode =
                    fsops::apply_mode(&self.req.mode, meta.mode() & 0o7777, kind.is_dir(), umask())
                        .ok_or_else(|| Fail(OpError::Unexpected, path.to_owned()))?;
                fs::set_permissions(path, Permissions::from_mode(mode))
            }
        } else if follow {
            std::os::unix::fs::chown(path, self.req.uid, self.req.gid)
        } else {
            std::os::unix::fs::lchown(path, self.req.uid, self.req.gid)
        };
        changed.map_err(|e| fail(path, &e))?;
        add(&self.sh.items_done, 1);
        if !self.req.recursive || !kind.is_dir() {
            return Ok(());
        }
        for name in children(path).map_err(|e| fail(path, &e))? {
            let child = join(path, &name);
            self.set_current(&child);
            self.attr_tree(&child, false)?;
        }
        Ok(())
    }
}

/// The trash a file goes to: the home trash if the file is on its device, else
/// $topdir/.Trash/$uid (if the administrator made it) or $topdir/.Trash-$uid on the file's
/// device. Also returns that device's top directory ("" for the home trash).
fn trash_dir_for(home_trash: &Path, src: &Path) -> Result<(PathBuf, PathBuf), OpError> {
    let dev = |p: &Path| fs::symlink_metadata(p).ok().map(|m| m.dev());
    let src_dev = dev(src).ok_or(OpError::FileNotFound)?;
    // The home trash may not exist yet: its nearest existing ancestor.
    let home_dev = home_trash.ancestors().find_map(dev);
    if home_dev == Some(src_dev) {
        return Ok((home_trash.to_owned(), PathBuf::new()));
    }
    // The top directory: the highest ancestor on the same device.
    let mut top = model::parent(src);
    while top.as_os_str().len() > 1 {
        let up = model::parent(top);
        if dev(up) != Some(src_dev) {
            break;
        }
        top = up;
    }
    let uid = rustix::process::getuid().as_raw();
    let t = fsops::trim_slash(top).as_os_str().as_bytes();
    // $topdir/.Trash must be a sticky folder, not a link.
    let admin = model::join(Path::new(std::ffi::OsStr::from_bytes(t)), b".Trash");
    let sticky = fs::symlink_metadata(&admin).is_ok_and(|m| m.is_dir() && m.mode() & 0o1000 != 0);
    let dir = if sticky {
        admin.join(uid.to_string())
    } else {
        model::join(
            Path::new(std::ffi::OsStr::from_bytes(t)),
            format!(".Trash-{uid}").as_bytes(),
        )
    };
    Ok((dir, top.to_owned()))
}

/// Local time now, as the trash specification writes it (YYYY-MM-DDThh:mm:ss).
fn local_now() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    keywork::desktop::localtime::Zone::local()
        .to_local(secs)
        .to_string()
}

/// The process's umask, read once from /proc: the umask call would change it while reading
/// it.
fn umask() -> u32 {
    static UMASK: OnceLock<u32> = OnceLock::new();
    *UMASK.get_or_init(|| {
        let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
        status
            .lines()
            .find_map(|l| l.strip_prefix("Umask:\t"))
            .and_then(|v| u32::from_str_radix(v.trim(), 8).ok())
            .unwrap_or(0o022)
    })
}
