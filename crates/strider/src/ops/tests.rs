//! Real jobs on small temporary trees, answered the way a host answers them: through the
//! wake callback, `receive`, and `answer`.

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::time::Duration;

use strider_core::undo::{self, Stack};

use super::*;

/// A folder under the system's temporary folder, removed on drop.
struct Tmp(PathBuf);

impl Tmp {
    fn new() -> Tmp {
        static N: AtomicU32 = AtomicU32::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("strider-ops-{}-{n}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Tmp(dir)
    }

    /// A folder for the same tree on another file system, when the machine has one.
    fn elsewhere(&self) -> Option<PathBuf> {
        let shm = Path::new("/dev/shm");
        let here = fs::metadata(&self.0).ok()?.dev();
        let dir = shm.join(model::basename(&self.0).escape_ascii().to_string());
        (fs::metadata(shm).ok()?.dev() != here && fs::create_dir(&dir).is_ok()).then_some(dir)
    }

    fn p(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }

    fn has(&self, rel: &str) -> bool {
        fsops::exists(&self.p(rel))
    }

    fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.p(rel)).unwrap()
    }

    fn sh(&self, script: &str) {
        let ok = std::process::Command::new("sh")
            .arg("-c")
            .arg(script)
            .current_dir(&self.0)
            .status()
            .unwrap()
            .success();
        assert!(ok, "{script}");
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::process::Command::new("chmod")
            .arg("-R")
            .arg("u+rwx")
            .arg(&self.0)
            .status();
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn paths(t: &Tmp, rels: &[&str]) -> Vec<PathBuf> {
    rels.iter().map(|r| t.p(r)).collect()
}

/// Runs `req` to its end as a host would, answering each conflict with `answer`. Returns what
/// it did and the conflicts asked about.
fn run_with(
    req: Request,
    mut answer: impl FnMut(&Job, &Conflict) -> (Resolution, bool),
) -> (Finished, Vec<Conflict>) {
    let (tx, rx) = mpsc::channel();
    let job = Job::start(req, move || {
        let _ = tx.send(());
    });
    let mut asked = Vec::new();
    loop {
        rx.recv_timeout(Duration::from_secs(20))
            .expect("the job wakes the host");
        for u in job.receive() {
            match u {
                Update::Ask(c) => {
                    assert_eq!(job.state(), State::Asking);
                    let (r, all) = answer(&job, &c);
                    asked.push(c);
                    job.answer(r, all);
                }
                Update::Changed => {}
                Update::Finished(f) => {
                    assert!(matches!(job.state(), State::Ended(_)));
                    return (f, asked);
                }
            }
        }
    }
}

fn run(req: Request) -> Finished {
    run_with(req, |_, c| panic!("nothing to ask, but asked about {c:?}")).0
}

fn answering(r: Resolution, all: bool) -> impl FnMut(&Job, &Conflict) -> (Resolution, bool) {
    move |_, _| (r, all)
}

fn copy(t: &Tmp, sources: &[&str], dest: &str) -> Request {
    Request::transfer(Kind::Copy, paths(t, sources), t.p(dest))
}

fn mv(t: &Tmp, sources: &[&str], dest: &str) -> Request {
    Request::transfer(Kind::Move, paths(t, sources), t.p(dest))
}

// A copy into its own folder keeps both without asking; elsewhere each answer does what it
// says, and the conflict says what is on each side.
#[test]
fn conflicts_and_their_answers() {
    let t = Tmp::new();
    t.sh("mkdir a b && echo one > a/f.txt && echo two > b/f.txt && mkdir a/d b/d && echo x > a/d/x && echo y > b/d/y");

    let f = run(copy(&t, &["a/f.txt"], "a"));
    assert!(f.error.is_none() && t.has("a/f (2).txt"));
    assert_eq!(f.created, [b"f (2).txt".to_vec()]);

    let (f, asked) = run_with(
        copy(&t, &["a/f.txt"], "b"),
        answering(Resolution::Skip, false),
    );
    assert_eq!((f.skipped, t.read("b/f.txt").as_str()), (1, "two\n"));
    assert_eq!(f.summary().0, "Nothing changed: every item was skipped");
    assert_eq!(asked[0].src, t.p("a/f.txt"));
    assert_eq!(
        (asked[0].dst.clone(), asked[0].dst_size),
        (t.p("b/f.txt"), 4)
    );

    let (f, _) = run_with(
        copy(&t, &["a/f.txt"], "b"),
        answering(Resolution::Replace, false),
    );
    assert_eq!(t.read("b/f.txt"), "one\n");
    assert!(f.done[0].replaced);

    // Merging folders: both files end up in b/d, and the moved folder is gone.
    let (f, asked) = run_with(mv(&t, &["a/d"], "b"), answering(Resolution::Merge, false));
    assert!(asked[0].src_dir && asked[0].dst_dir);
    assert!(f.error.is_none() && t.has("b/d/x") && t.has("b/d/y") && !t.has("a/d"));

    let (f, _) = run_with(
        mv(&t, &["a/f.txt"], "b"),
        answering(Resolution::KeepBoth, false),
    );
    assert!(t.has("b/f (2).txt") && !t.has("a/f.txt"));
    assert_eq!(f.done[0].to, t.p("b/f (2).txt"));
}

// An answer for all is asked once; cancelling at a question stops there, leaving what was
// done before it and doing nothing after it.
#[test]
fn answers_for_all_and_cancel() {
    let t = Tmp::new();
    t.sh(
        "mkdir a b && for f in 1 2 3; do echo new > a/$f; done && echo old > b/2 && echo old > b/3",
    );
    let (f, asked) = run_with(
        copy(&t, &["a/1", "a/2", "a/3"], "b"),
        answering(Resolution::Replace, true),
    );
    assert_eq!(asked.len(), 1);
    assert!(f.error.is_none());
    assert_eq!(
        (t.read("b/2"), t.read("b/3")),
        ("new\n".into(), "new\n".into())
    );

    t.sh("rm -r b && mkdir b && echo old > b/2");
    let (f, asked) = run_with(
        copy(&t, &["a/1", "a/2", "a/3"], "b"),
        answering(Resolution::Cancel, false),
    );
    assert_eq!(asked.len(), 1);
    assert!(f.canceled());
    assert_eq!(f.summary(), ("Canceled".into(), false));
    assert!(t.has("b/1") && !t.has("b/3"));
    assert_eq!(t.read("b/2"), "old\n");
}

// A move into the folder a file is in does nothing; a copy there duplicates it.
#[test]
fn moving_into_its_own_folder_does_nothing() {
    let t = Tmp::new();
    t.sh("mkdir a && echo x > a/f");
    let f = run(mv(&t, &["a/f"], "a"));
    assert!(f.error.is_none() && f.done.is_empty());
    assert_eq!(f.summary().0, "");
    assert_eq!(fs::read_dir(t.p("a")).unwrap().count(), 1);
}

// Paste-overwrite: replace without asking, merging folders it would replace.
#[test]
fn paste_overwrite_replaces_and_merges() {
    let t = Tmp::new();
    t.sh(
        "mkdir -p a/d b/d && echo new > a/f && echo old > b/f && echo x > a/d/x && echo y > b/d/y",
    );
    let f = run(copy(&t, &["a/f", "a/d"], "b").with_policy(Resolution::Replace));
    assert!(f.error.is_none());
    assert_eq!(t.read("b/f"), "new\n");
    assert!(t.has("b/d/x") && t.has("b/d/y"));
}

// Copies keep what fsops keeps: files' and folders' permission bits (a folder's only once its
// contents are in, so a read-only one copies), files' modification and access times to the
// nanosecond, and links as links, dangling ones too.
#[test]
fn copying_a_tree_keeps_modes_times_and_links() {
    let t = Tmp::new();
    t.sh(
        "umask 022 && mkdir -p src/sub dst && echo a > src/run && chmod 755 src/run && echo b > src/sub/secret && \
         chmod 640 src/sub/secret && touch -d @981173106.123456789 src/sub/secret && \
         ln -s ../run src/sub/link && ln -s nowhere src/dangling && chmod 550 src/sub",
    );
    let f = run(copy(&t, &["src"], "dst"));
    assert!(f.error.is_none());
    let mode = |rel| fs::symlink_metadata(t.p(rel)).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode("dst/src/run"), 0o755);
    assert_eq!(mode("dst/src/sub/secret"), 0o640);
    assert_eq!(mode("dst/src/sub"), 0o550);
    // The source's access time changed as it was read; the copy has what it was before.
    let b = fs::metadata(t.p("dst/src/sub/secret")).unwrap();
    let touched = (981173106, 123456789);
    assert_eq!((b.mtime(), b.mtime_nsec()), touched);
    assert_eq!((b.atime(), b.atime_nsec()), touched);
    assert_eq!(
        fs::read_link(t.p("dst/src/sub/link")).unwrap(),
        Path::new("../run")
    );
    assert_eq!(
        fs::read_link(t.p("dst/src/dangling")).unwrap(),
        Path::new("nowhere")
    );
    assert_eq!(t.read("dst/src/sub/link"), "a\n");
    assert_eq!(f.done.len(), 1);
    assert_eq!(f.items_done, 6);
}

// A folder cannot go into itself; the error names it.
#[test]
fn a_folder_into_itself_fails() {
    let t = Tmp::new();
    t.sh("mkdir -p a/sub");
    let f = run(copy(&t, &["a"], "a/sub"));
    assert_eq!(f.error, Some((OpError::IntoItself, t.p("a"))));
    assert_eq!(
        f.summary().0,
        "Could not copy “a”: A folder cannot be copied or moved into itself"
    );
    assert!(!t.has("a/sub/a"));
}

// Across file systems a move copies, then deletes the original, counting the bytes it copies.
#[test]
fn moving_across_devices_copies_then_deletes() {
    let t = Tmp::new();
    let Some(other) = t.elsewhere() else {
        eprintln!("no second file system to move to");
        return;
    };
    t.sh("mkdir -p d/e && echo hello > d/e/f && chmod 600 d/e/f && ln -s e/f d/l");
    let req = Request::transfer(Kind::Move, vec![t.p("d")], other.clone());
    let (tx, rx) = mpsc::channel();
    let job = Job::start(req, move || {
        let _ = tx.send(());
    });
    let f = loop {
        rx.recv_timeout(Duration::from_secs(20)).unwrap();
        if let Some(Update::Finished(f)) = job.receive().pop() {
            break f;
        }
    };
    let moved = other.join("d");
    let ok = f.error.is_none()
        && !t.has("d")
        && fs::read_to_string(moved.join("e/f")).ok().as_deref() == Some("hello\n")
        && fs::metadata(moved.join("e/f"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777
            == 0o600
        && fs::read_link(moved.join("l")).ok().as_deref() == Some(Path::new("e/f"));
    let _ = fs::remove_dir_all(&other);
    assert!(ok, "{f:?}");
    assert_eq!(f.done[0].to, moved);
    assert_eq!(job.progress().bytes_total, 6);
    assert_eq!(job.progress().bytes_done, 6);
}

// A file on another device goes to that device's own trash, whose info file records its path
// relative to the device's top folder, and comes back from there.
#[test]
fn trashing_on_another_device() {
    let t = Tmp::new();
    let Some(other) = t.elsewhere() else {
        eprintln!("no second file system to trash on");
        return;
    };
    fs::write(other.join("f"), "x").unwrap();
    let f = run(Request::trash(vec![other.join("f")], t.p("home/Trash")));
    let uid = rustix::process::getuid().as_raw();
    let dir = Path::new("/dev/shm").join(format!(".Trash-{uid}"));
    let trashed = f.done.first().map(|d| d.to.clone());
    let info = trashed.as_deref().and_then(trash::info_path_of);
    let body = info
        .as_deref()
        .map(fs::read)
        .and_then(Result::ok)
        .unwrap_or_default();
    let restored = trashed.clone().map(|p| run(restore_request(&[p]).unwrap()));
    let back = fs::read_to_string(other.join("f")).ok();
    // Only what this test made: the device's trash may hold others' files.
    for p in trashed.into_iter().chain(info) {
        let _ = fs::remove_file(p);
    }
    for d in [dir.join("files"), dir.join("info"), dir.clone()] {
        let _ = fs::remove_dir(d);
    }
    let _ = fs::remove_dir_all(&other);
    assert!(f.error.is_none(), "{f:?}");
    assert_eq!(f.done[0].to.parent(), Some(dir.join("files").as_path()));
    let recorded = trash::parse_info(&body).path;
    assert!(
        !recorded.starts_with(b"/") && recorded.ends_with(b"/f"),
        "{body:?}"
    );
    assert!(restored.is_some_and(|r| r.error.is_none()));
    assert_eq!(back.as_deref(), Some("x"));
}

// Trashing writes the info file the specification asks for, a second file of the same name
// gets a free one, the trash lists both with where they were, and restoring puts each back
// and removes its info file.
#[test]
fn trash_and_restore() {
    let t = Tmp::new();
    t.sh("mkdir -p home/Trash work && echo hi > 'work/a b.txt' && mkdir work/dir && echo x > work/dir/x");
    let home_trash = t.p("home/Trash");
    let f = run(Request::trash(
        paths(&t, &["work/a b.txt", "work/dir"]),
        home_trash.clone(),
    ));
    assert!(f.error.is_none());
    assert_eq!(f.summary().0, "2 items moved to the trash");
    assert!(
        !t.has("work/a b.txt")
            && t.has("home/Trash/files/a b.txt")
            && t.has("home/Trash/files/dir/x")
    );
    let info = t.read("home/Trash/info/a b.txt.trashinfo");
    let path = format!("Path={}/work/a%20b.txt\n", t.0.display());
    assert!(
        info.starts_with("[Trash Info]\n") && info.contains(&path),
        "{info}"
    );
    let date = trash::parse_info(info.as_bytes()).date;
    assert!(trash::parse_date(date) != 0, "{info}");

    t.sh("echo again > 'work/a b.txt'");
    let f = run(Request::trash(
        paths(&t, &["work/a b.txt"]),
        home_trash.clone(),
    ));
    assert_eq!(f.done[0].to, t.p("home/Trash/files/a b (2).txt"));
    assert!(t.has("home/Trash/info/a b (2).txt.trashinfo"));

    let (l, info) = trash::list(std::slice::from_ref(&home_trash));
    let mut originals: Vec<_> = info.items.iter().map(|i| i.original.clone()).collect();
    originals.sort();
    assert_eq!(
        originals,
        paths(&t, &["work/a b.txt", "work/a b.txt", "work/dir"])
    );
    assert_eq!(
        l.path_of(&l.entries[0]).parent(),
        Some(t.p("home/Trash/files").as_path())
    );

    let trashed = paths(
        &t,
        &["home/Trash/files/a b (2).txt", "home/Trash/files/dir"],
    );
    let f = run(restore_request(&trashed).unwrap());
    assert!(f.error.is_none());
    assert_eq!(t.read("work/a b.txt"), "again\n");
    assert!(t.has("work/dir/x") && !t.has("home/Trash/files/dir"));
    assert!(
        !t.has("home/Trash/info/a b (2).txt.trashinfo") && !t.has("home/Trash/info/dir.trashinfo")
    );

    // The other one's place is taken now: keeping both restores it under a free name.
    let req = restore_request(&paths(&t, &["home/Trash/files/a b.txt"])).unwrap();
    let (f, asked) = run_with(req, answering(Resolution::KeepBoth, false));
    assert_eq!(asked.len(), 1);
    assert_eq!(f.done[0].to, t.p("work/a b (2).txt"));
    assert_eq!(t.read("work/a b (2).txt"), "hi\n");
    assert_eq!(
        restore_request(&paths(&t, &["work/a b.txt"])),
        Err("These items do not say where they came from")
    );
}

// Deleting removes trees and links, never what a link points to.
#[test]
fn deleting() {
    let t = Tmp::new();
    t.sh("mkdir -p d/e keep && echo x > d/e/f && echo k > keep/k && ln -s ../keep d/link && ln -s keep top");
    let f = run(Request::delete(paths(&t, &["d", "top"])));
    assert!(f.error.is_none());
    assert_eq!(f.summary().0, "2 items deleted");
    assert!(!t.has("d") && !t.has("top") && t.has("keep/k"));
    let f = run(Request::delete(paths(&t, &["missing"])));
    assert_eq!(f.error, Some((OpError::FileNotFound, t.p("missing"))));
}

// chmod as chmod(1): X only for folders and executables, -R into folders, links inside
// folders left alone; without -R only the item named.
#[test]
fn chmod_symbolic_modes() {
    let t = Tmp::new();
    t.sh("mkdir -p d/sub && echo > d/f && chmod 666 d/f && echo > d/x && chmod 744 d/x && chmod 700 d/sub && ln -s /etc/hostname d/link");
    let mode = |rel| fs::symlink_metadata(t.p(rel)).unwrap().permissions().mode() & 0o7777;
    let f = run(Request::chmod(paths(&t, &["d"]), "a=rX".into(), true));
    assert!(f.error.is_none());
    assert_eq!((mode("d"), mode("d/sub")), (0o555, 0o555));
    assert_eq!((mode("d/f"), mode("d/x")), (0o444, 0o555));
    assert_eq!(f.summary().0, "Changed the permissions of 5 items");
    let f = run(Request::chmod(paths(&t, &["d"]), "u+w,go-rx".into(), false));
    assert!(f.error.is_none());
    assert_eq!((mode("d"), mode("d/sub")), (0o700, 0o555));
    assert_eq!(f.summary().0, "Changed the permissions of “d”");
    run(Request::chmod(paths(&t, &["d/f"]), "755".into(), false));
    assert_eq!(mode("d/f"), 0o755);
}

// chown to one's own user and group, as anyone may.
#[test]
fn chown_to_oneself() {
    let t = Tmp::new();
    t.sh("mkdir -p d && echo > d/f");
    let uid = rustix::process::getuid().as_raw();
    let gid = rustix::process::getgid().as_raw();
    let owner = owner::parse_owner(&format!("{uid}:{gid}")).unwrap();
    let f = run(Request::chown(paths(&t, &["d"]), owner, true));
    assert!(f.error.is_none());
    assert_eq!(f.items_done, 2);
    assert_eq!(fs::metadata(t.p("d/f")).unwrap().gid(), gid);
}

// Links point at the source by its absolute path.
#[test]
fn linking() {
    let t = Tmp::new();
    t.sh("mkdir a b && echo x > a/f");
    let f = run(Request::transfer(Kind::Link, paths(&t, &["a/f"]), t.p("b")));
    assert_eq!(f.summary().0, "Linked “f”");
    assert_eq!(fs::read_link(t.p("b/f")).unwrap(), t.p("a/f"));
}

// Pausing holds a copy between chunks; cancelling then stops it and removes the file it was
// writing, leaving the source as it was.
#[test]
fn pause_then_cancel_mid_file() {
    let t = Tmp::new();
    t.sh("mkdir out && truncate -s 1G big");
    let (tx, rx) = mpsc::channel();
    let job = Job::start(copy(&t, &["big"], "out"), move || {
        let _ = tx.send(());
    });
    while job.progress().bytes_done == 0 {
        std::thread::yield_now();
    }
    job.pause();
    assert!(job.is_paused());
    assert_eq!(job.status(), "Paused");
    std::thread::sleep(Duration::from_millis(50));
    let held = job.progress().bytes_done;
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(
        job.progress().bytes_done,
        held,
        "a paused job copies nothing"
    );
    assert!(held < 1 << 30 && t.has("out/big"));
    job.cancel();
    let f = loop {
        rx.recv_timeout(Duration::from_secs(20)).unwrap();
        if let Some(Update::Finished(f)) = job
            .receive()
            .into_iter()
            .find(|u| matches!(u, Update::Finished(_)))
        {
            break f;
        }
    };
    assert!(f.canceled());
    assert_eq!(job.state(), State::Ended(End::Cancelled));
    assert!(!t.has("out/big") && t.has("big"));
}

/// Runs the undo of the stack's newest step.
fn undo_newest(stack: &mut Stack, home_trash: &Path) -> Option<Finished> {
    match undo(&stack.pop().unwrap(), home_trash) {
        Undo::Start(req) => Some(run(req)),
        Undo::Done { error, message, .. } => {
            assert!(!error, "{message}");
            None
        }
    }
}

// Undo reverses each kind of step: a move goes back, a copy goes to the trash, a trash is
// restored, a rename is renamed back, a new folder is removed.
#[test]
fn undo_reverses_operations() {
    let t = Tmp::new();
    t.sh("mkdir -p a b home/Trash && echo m > a/m && echo c > a/c && echo z > a/z");
    let home_trash = t.p("home/Trash");
    let mut stack = Stack::new();
    let record = |stack: &mut Stack, f: Finished| stack.push_op(f.kind, &f.done);

    record(&mut stack, run(mv(&t, &["a/m"], "b")));
    record(&mut stack, run(copy(&t, &["a/c"], "b")));
    record(
        &mut stack,
        run(Request::trash(paths(&t, &["a/z"]), home_trash.clone())),
    );
    let renamed = rename_one(&t.p("a/c"), b"c2").unwrap();
    stack.push_renames(vec![undo::Pair {
        from: t.p("a/c"),
        to: renamed,
    }]);
    stack.push_created(make_dir(&t.p("a"), b"new").unwrap());
    assert!(t.has("b/m") && t.has("b/c") && t.has("a/c2") && t.has("a/new") && !t.has("a/z"));

    assert!(undo_newest(&mut stack, &home_trash).is_none());
    assert!(!t.has("a/new"));
    assert!(undo_newest(&mut stack, &home_trash).is_none());
    assert!(t.has("a/c") && !t.has("a/c2"));
    let f = undo_newest(&mut stack, &home_trash).unwrap();
    assert_eq!((f.kind, t.read("a/z").as_str()), (Kind::Restore, "z\n"));
    let f = undo_newest(&mut stack, &home_trash).unwrap();
    assert_eq!(f.kind, Kind::Trash);
    assert!(!t.has("b/c") && t.has("home/Trash/files/c") && t.has("a/c"));
    let f = undo_newest(&mut stack, &home_trash).unwrap();
    assert_eq!(f.kind, Kind::MoveBack);
    assert!(t.has("a/m") && !t.has("b/m"));
    assert!(stack.is_empty());
}

// Renaming in a batch swaps names through temporary ones; a name taken by another file
// leaves that file under its old name and counts it as failed.
#[test]
fn batch_renames() {
    let t = Tmp::new();
    t.sh("echo a > a && echo b > b && echo c > c && echo taken > d");
    let r = rename_many(&[
        (t.p("a"), t.p("b")),
        (t.p("b"), t.p("a")),
        (t.p("c"), t.p("d")),
    ]);
    assert_eq!((t.read("a"), t.read("b")), ("b\n".into(), "a\n".into()));
    assert_eq!((t.read("c"), t.read("d")), ("c\n".into(), "taken\n".into()));
    assert_eq!((r.done.len(), r.failed), (2, 1));
    assert_eq!(
        r.message(),
        Some(("1 items could not be renamed".into(), true))
    );
    assert_eq!(
        rename_one(&t.p("a"), b"b"),
        Err("A file with that name already exists".into())
    );
    assert_eq!(
        rename_one(&t.p("a"), b"x/y"),
        Err("Names cannot be empty or contain “/”".into())
    );
    assert_eq!(make_file(&t.p(""), b"a"), Err(OpError::Exists));
    assert_eq!(remove_empty(&t.p("a")), Ok(()));
}
