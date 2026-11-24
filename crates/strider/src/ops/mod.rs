//! File operations, run on threads of their own: copy, move (renaming, or copying then deleting
//! across file systems), link, trash, delete, restore and move back, chmod and chown. Each
//! [`Job`] has an [`operation`](strider_machines::operation) statechart for its control flow;
//! the worker thread here walks the files and does what the chart says.
//!
//! The host starts a job with a wake callback, which runs when updates wait for
//! [`Job::receive`] after none did; with Keywork it posts to the app through a `Proxy`, so the
//! updates are taken in dispatch on the UI thread. The callback may run on the worker thread
//! or, after the host's own `answer`, `pause`, or `cancel`, on the host's thread; it runs
//! outside the job's locks, so it may call the job back. Progress is not an update: the host
//! reads [`Job::progress`] when it draws, on a timer while jobs run, as the Zig build does.
//!
//! What fsops.zig preserves is preserved: a copied file keeps its permission bits (as its
//! creation mode, so the umask applies), its access and modification times; a folder its
//! permission bits; a symbolic link is copied as a link. Owners are not kept, nor folders'
//! times. A cancelled or failed copy removes the file it was writing; what was done before
//! stays.

#![allow(
    dead_code,
    reason = "the commands, tasks view, and dialogs use it as they are ported"
)]

pub mod owner;
#[cfg(test)]
mod tests;
mod worker;

use std::fs::{self, OpenOptions};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use keywork::desktop::basedir::BaseDirs;
use keywork::desktop::trash::{Trash, TrashItem};
use plusthree::host::NoTimers;
use strider_core::fsops::{Conflict, Finished, Kind, OpError, Resolution};
use strider_core::undo::{Pair, Reversal, Step};
use strider_core::{fsops, model};
use strider_machines::driver::Driver;
use strider_machines::operation::{End, OpEv, OpFx, Operation, operation::states};

use owner::Owner;

/// What to do: an operation and what it works on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub kind: Kind,
    /// Absolute paths.
    pub sources: Vec<PathBuf>,
    /// The folder copies, moves, and links go into; empty otherwise.
    pub dest: PathBuf,
    /// Restore and move back: where each source goes, parallel to `sources`.
    pub targets: Vec<PathBuf>,
    /// Trash and restore: the home trash (`$XDG_DATA_HOME/Trash`), which trashing files on
    /// its device uses, beside each mounted file system's.
    pub home_trash: PathBuf,
    /// chmod: the mode, as chmod(1) takes it, checked with [`fsops::parse_mode`] first.
    pub mode: String,
    /// chown: the new owner and group; None keeps one.
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    /// chmod and chown: into folders too.
    pub recursive: bool,
    /// The answer to every conflict, without asking, as paste-overwrite's replace.
    pub policy: Option<Resolution>,
}

impl Request {
    fn new(kind: Kind, sources: Vec<PathBuf>) -> Request {
        Request {
            kind,
            sources,
            dest: PathBuf::new(),
            targets: Vec::new(),
            home_trash: PathBuf::new(),
            mode: String::new(),
            uid: None,
            gid: None,
            recursive: false,
            policy: None,
        }
    }

    /// Copy, move, or link `sources` into the folder `dest`. A copy into the folder it comes
    /// from keeps both without asking; a move there does nothing.
    pub fn transfer(kind: Kind, sources: Vec<PathBuf>, dest: PathBuf) -> Request {
        Request {
            dest,
            ..Request::new(kind, sources)
        }
    }

    pub fn trash(sources: Vec<PathBuf>, home_trash: PathBuf) -> Request {
        Request {
            home_trash,
            ..Request::new(Kind::Trash, sources)
        }
    }

    /// Delete permanently.
    pub fn delete(sources: Vec<PathBuf>) -> Request {
        Request::new(Kind::Delete, sources)
    }

    /// Move each trashed file, in a trash beside the home trash `home_trash`, back to its
    /// target, out of the trash with its info file.
    pub fn restore(trashed: Vec<PathBuf>, targets: Vec<PathBuf>, home_trash: PathBuf) -> Request {
        Request {
            targets,
            home_trash,
            ..Request::new(Kind::Restore, trashed)
        }
    }

    /// Move each source to its target exactly, undoing a move.
    pub fn move_back(sources: Vec<PathBuf>, targets: Vec<PathBuf>) -> Request {
        Request {
            targets,
            ..Request::new(Kind::MoveBack, sources)
        }
    }

    pub fn chmod(sources: Vec<PathBuf>, mode: String, recursive: bool) -> Request {
        Request {
            mode,
            recursive,
            ..Request::new(Kind::Chmod, sources)
        }
    }

    pub fn chown(sources: Vec<PathBuf>, owner: Owner, recursive: bool) -> Request {
        Request {
            uid: owner.uid,
            gid: owner.gid,
            recursive,
            ..Request::new(Kind::Chown, sources)
        }
    }

    /// Answers every conflict with `policy`.
    pub fn with_policy(self, policy: Resolution) -> Request {
        Request {
            policy: Some(policy),
            ..self
        }
    }

    /// "Copying 3 items to Music", for the tasks view.
    pub fn title(&self) -> String {
        fsops::title(self.kind, &self.sources, &self.dest)
    }
}

/// What a job tells the host, taken with [`Job::receive`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Update {
    /// [`Job::state`] changed: draw the task again.
    Changed,
    /// Ask the user, and answer with [`Job::answer`]; the worker waits until then.
    Ask(Conflict),
    /// The job ended, the last update it sends. Record it for undo if it was started as
    /// undoable and was not cancelled, read the folders it touched again, and show its
    /// summary.
    Finished(Finished),
}

/// Where a job is, as the tasks view shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    /// Counting the files and bytes to do.
    Counting,
    Running,
    /// Waiting for the answer to a conflict.
    Asking,
    /// Asked to cancel; the worker stops at its next item or chunk.
    Stopping,
    Ended(End),
}

/// Counts for a progress bar.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Progress {
    pub bytes_done: u64,
    /// Bytes to copy: counted for copies, and for moves once they must copy.
    pub bytes_total: u64,
    pub items_done: u64,
    pub items_total: u64,
    /// The name of the file being worked on.
    pub current: String,
    /// Bytes per second over the time the job ran, not counting pauses.
    pub bytes_per_sec: u64,
}

impl Progress {
    /// How far along, by bytes when there are bytes to count, else by items.
    pub fn percent(&self) -> u64 {
        let (done, total) = if self.bytes_total > 0 {
            (self.bytes_done, self.bytes_total)
        } else {
            (self.items_done, self.items_total)
        };
        (done * 100).checked_div(total).map_or(0, |p| p.min(100))
    }
}

/// A running operation. Clones share it; dropping them does not stop it.
#[derive(Clone)]
pub struct Job {
    shared: Arc<Shared>,
}

struct Shared {
    request: Request,
    chart: Mutex<Driver<Operation, ()>>,
    inbox: Mutex<Vec<Update>>,
    wake: Box<dyn Fn() + Send + Sync>,
    /// What the worker waits on: an answer, or the end of a pause.
    gate: Mutex<Gate>,
    turn: Condvar,
    /// Read without the gate's lock between chunks; written with it.
    cancel: AtomicBool,
    paused: AtomicBool,
    bytes_done: AtomicU64,
    bytes_total: AtomicU64,
    items_done: AtomicU64,
    items_total: AtomicU64,
    current: Mutex<String>,
    /// The conflict being asked about.
    conflict: Mutex<Option<Conflict>>,
    /// The worker's result, until the chart says it finished.
    finished: Mutex<Option<Finished>>,
    started: Instant,
}

#[derive(Default)]
struct Gate {
    answer: Option<Resolution>,
    paused_since: Option<Instant>,
    paused_for: Duration,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Job {
    /// Starts `request` on a thread of its own. `wake` runs when updates wait for
    /// [`receive`](Self::receive) after none did.
    pub fn start(request: Request, wake: impl Fn() + Send + Sync + 'static) -> Job {
        let policy = request.policy;
        let shared = Arc::new(Shared {
            request,
            chart: Mutex::new(Driver::new(Operation::machine(), policy)),
            inbox: Mutex::new(Vec::new()),
            wake: Box::new(wake),
            gate: Mutex::new(Gate::default()),
            turn: Condvar::new(),
            cancel: AtomicBool::new(false),
            paused: AtomicBool::new(false),
            bytes_done: AtomicU64::new(0),
            bytes_total: AtomicU64::new(0),
            items_done: AtomicU64::new(0),
            items_total: AtomicU64::new(0),
            current: Mutex::new(String::new()),
            conflict: Mutex::new(None),
            finished: Mutex::new(None),
            started: Instant::now(),
        });
        let worker = shared.clone();
        std::thread::Builder::new()
            .name("strider-op".into())
            .spawn(move || worker::run(&worker))
            .expect("a thread starts unless the system is out of them");
        Job { shared }
    }

    pub fn request(&self) -> &Request {
        &self.shared.request
    }

    /// Takes the updates that came since the last call, in order.
    pub fn receive(&self) -> Vec<Update> {
        std::mem::take(&mut *lock(&self.shared.inbox))
    }

    /// Answers the conflict asked about, and every later one too with `all`; cancel stops
    /// the job. Does nothing unless the job is asking.
    pub fn answer(&self, resolution: Resolution, all: bool) {
        self.shared.send(OpEv::Answer { resolution, all });
    }

    /// Holds the worker at its next item or chunk.
    pub fn pause(&self) {
        self.shared.send(OpEv::Pause);
    }

    pub fn resume(&self) {
        self.shared.send(OpEv::Resume);
    }

    /// Stops the job at its next item or chunk, at once if it is asking or paused. What was
    /// done stays done; a file being copied is removed.
    pub fn cancel(&self) {
        self.shared.send(OpEv::Cancel);
    }

    pub fn is_paused(&self) -> bool {
        lock(&self.shared.chart).matches(states::active::hold::PAUSED)
    }

    pub fn state(&self) -> State {
        let chart = lock(&self.shared.chart);
        if chart.matches(states::active::work::COUNTING) {
            State::Counting
        } else if chart.matches(states::active::work::RUNNING) {
            State::Running
        } else if chart.matches(states::active::work::ASKING) {
            State::Asking
        } else if chart.matches(states::STOPPING) {
            State::Stopping
        } else if chart.matches(states::DONE) {
            State::Ended(End::Done)
        } else if chart.matches(states::FAILED) {
            State::Ended(End::Failed)
        } else {
            State::Ended(End::Cancelled)
        }
    }

    /// "45%", "Paused", "Counting…": where the job is, for the tasks view.
    pub fn status(&self) -> String {
        if self.is_paused() {
            return "Paused".into();
        }
        match self.state() {
            State::Asking => "Waiting for an answer".into(),
            State::Counting => "Counting…".into(),
            _ => format!("{}%", self.progress().percent()),
        }
    }

    pub fn progress(&self) -> Progress {
        let sh = &self.shared;
        let paused = {
            let g = lock(&sh.gate);
            g.paused_for + g.paused_since.map_or(Duration::ZERO, |t| t.elapsed())
        };
        let ran = sh.started.elapsed().saturating_sub(paused).as_secs_f64();
        let bytes_done = sh.bytes_done.load(Ordering::Relaxed);
        Progress {
            bytes_done,
            bytes_total: sh.bytes_total.load(Ordering::Relaxed),
            items_done: sh.items_done.load(Ordering::Relaxed),
            items_total: sh.items_total.load(Ordering::Relaxed),
            current: lock(&sh.current).clone(),
            bytes_per_sec: if ran > 0.0 {
                (bytes_done as f64 / ran) as u64
            } else {
                0
            },
        }
    }
}

impl Shared {
    /// Steps the chart and carries out its effects, then wakes the host if updates came to
    /// an empty inbox.
    fn send(&self, ev: OpEv) {
        let wake = {
            let mut chart = lock(&self.chart);
            let fx = chart.send(ev, NoTimers);
            fx.into_iter().fold(false, |wake, f| self.apply(f) | wake)
        };
        if wake {
            (self.wake)();
        }
    }

    fn apply(&self, fx: OpFx) -> bool {
        match fx {
            OpFx::Ask => {
                let c = lock(&self.conflict)
                    .clone()
                    .expect("the worker set the conflict first");
                self.post(Update::Ask(c))
            }
            OpFx::Changed => self.post(Update::Changed),
            OpFx::Finished(_) => {
                let f = lock(&self.finished)
                    .take()
                    .expect("the worker set its result first");
                self.post(Update::Finished(f))
            }
            OpFx::Resolve(r) => {
                lock(&self.gate).answer = Some(r);
                self.turn.notify_all();
                false
            }
            OpFx::Hold => {
                let mut g = lock(&self.gate);
                g.paused_since = Some(Instant::now());
                self.paused.store(true, Ordering::Release);
                false
            }
            OpFx::Release | OpFx::Stop => {
                let mut g = lock(&self.gate);
                if let Some(t) = g.paused_since.take() {
                    g.paused_for += t.elapsed();
                }
                self.paused.store(false, Ordering::Release);
                if fx == OpFx::Stop {
                    self.cancel.store(true, Ordering::Release);
                }
                self.turn.notify_all();
                false
            }
        }
    }

    /// Queues an update; whether the inbox was empty.
    fn post(&self, u: Update) -> bool {
        let mut inbox = lock(&self.inbox);
        inbox.push(u);
        inbox.len() == 1
    }
}

// Right away, on the host's thread ------------------------------------------------------------

/// Creates the folder `name` in `dir`.
pub fn make_dir(dir: &Path, name: &[u8]) -> Result<PathBuf, OpError> {
    let p = valid_child(dir, name)?;
    fs::DirBuilder::new()
        .mode(0o755)
        .create(&p)
        .map_err(|e| worker::op_error(&e))?;
    Ok(p)
}

/// Creates the empty file `name` in `dir`.
pub fn make_file(dir: &Path, name: &[u8]) -> Result<PathBuf, OpError> {
    let p = valid_child(dir, name)?;
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o644)
        .open(&p)
        .map_err(|e| worker::op_error(&e))?;
    Ok(p)
}

fn valid_child(dir: &Path, name: &[u8]) -> Result<PathBuf, OpError> {
    if !model::valid_name(name) {
        return Err(OpError::InvalidName);
    }
    Ok(model::join(fsops::trim_slash(dir), name))
}

/// Removes an empty folder or a file, undoing creating it.
pub fn remove_empty(path: &Path) -> Result<(), OpError> {
    match fs::remove_dir(path) {
        Err(e) if e.raw_os_error() == Some(libc::ENOTDIR) => fs::remove_file(path),
        r => r,
    }
    .map_err(|e| worker::op_error(&e))
}

/// Renames a path to another in the same file system, refusing to replace a file there.
pub fn rename_path(from: &Path, to: &Path) -> Result<(), OpError> {
    use rustix::fs::{CWD, RenameFlags, renameat_with};
    renameat_with(CWD, from, CWD, to, RenameFlags::NOREPLACE)
        .map_err(|e| worker::op_error(&e.into()))
}

/// Renames `old` to `new_name` in its folder, with the message the status line shows when it
/// cannot. Returns the new path, which is `old` when the name did not change (nothing to
/// record for undo).
pub fn rename_one(old: &Path, new_name: &[u8]) -> Result<PathBuf, String> {
    if !model::valid_name(new_name) {
        return Err(OpError::InvalidName.describe().into());
    }
    let new = model::join(model::parent(old), new_name);
    if new == old {
        return Ok(new);
    }
    if fsops::exists(&new) {
        return Err(OpError::Exists.describe().into());
    }
    rename_path(old, &new).map_err(|e| {
        let name = String::from_utf8_lossy(model::basename(old));
        format!("Could not rename “{name}”: {}", e.describe())
    })?;
    Ok(new)
}

/// What a batch of renames did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Renamed {
    /// The renames that took effect, for undo as one step.
    pub done: Vec<Pair>,
    pub failed: usize,
    /// Files left under their temporary names: (original path, where it is now).
    pub stranded: Vec<(PathBuf, PathBuf)>,
}

impl Renamed {
    /// What the status line says, and whether it is an error; None when nothing changed.
    pub fn message(&self) -> Option<(String, bool)> {
        if !self.stranded.is_empty() {
            let n = self.stranded.len();
            return Some((
                format!("{n} items are left under temporary names; :messages says where"),
                true,
            ));
        }
        if self.failed != 0 {
            return Some((format!("{} items could not be renamed", self.failed), true));
        }
        (!self.done.is_empty()).then(|| (format!("Renamed {} items", self.done.len()), false))
    }
}

/// Renames several files, going through temporary names so that "a"→"b" and "b"→"a" work.
/// A rename whose new name is taken puts the file back under its old name.
pub fn rename_many(pairs: &[(PathBuf, PathBuf)]) -> Renamed {
    let mut out = Renamed::default();
    let mut staged = Vec::new();
    for (i, (from, to)) in pairs.iter().enumerate() {
        if from == to {
            continue;
        }
        let tmp_name = format!(".strider-rename-{}-{i}", std::process::id());
        let tmp = model::join(model::parent(from), tmp_name.as_bytes());
        match rename_path(from, &tmp) {
            Ok(()) => staged.push((tmp, from, to)),
            Err(_) => out.failed += 1,
        }
    }
    // rename_path refuses a name that is taken.
    for (tmp, from, to) in staged {
        if rename_path(&tmp, to).is_ok() {
            out.done.push(Pair {
                from: from.clone(),
                to: to.clone(),
            });
            continue;
        }
        out.failed += 1;
        if rename_path(&tmp, from).is_err() {
            out.stranded.push((from.clone(), tmp));
        }
    }
    out
}

/// What undoing a step is: done already, or an operation to start (not itself undoable).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Undo {
    Done {
        message: String,
        error: bool,
        /// A path to select once its folder reads again.
        select: Option<PathBuf>,
        /// Folders to read again.
        touched: Vec<PathBuf>,
    },
    Start(Request),
}

/// Undoes `step`, the undo stack's newest: a creation or renames at once, anything else as
/// an operation to start. Copies and restores go to the trash at `home_trash`.
pub fn undo(step: &Step, home_trash: &Path) -> Undo {
    match step.reversal() {
        Reversal::Remove(path) => {
            let touched = vec![model::parent(&path).to_owned()];
            let (message, error) = match remove_empty(&path) {
                Ok(()) => ("Undid creating it".to_owned(), false),
                Err(e) => (format!("Could not undo: {}", e.describe()), true),
            };
            Undo::Done {
                message,
                error,
                select: None,
                touched,
            }
        }
        Reversal::RenameBack(pairs) => {
            let failed = pairs
                .iter()
                .filter(|p| rename_path(&p.to, &p.from).is_err())
                .count();
            let (message, error) = match failed {
                0 => ("Undid the rename".to_owned(), false),
                _ => ("Some renames could not be undone".to_owned(), true),
            };
            let select = match pairs.as_slice() {
                [one] => Some(one.from.clone()),
                _ => None,
            };
            let touched = pairs
                .iter()
                .map(|p| model::parent(&p.from).to_owned())
                .collect();
            Undo::Done {
                message,
                error,
                select,
                touched,
            }
        }
        Reversal::Run {
            kind,
            sources,
            targets,
        } => Undo::Start(match kind {
            Kind::Trash => Request::trash(sources, home_trash.to_owned()),
            Kind::Restore => Request::restore(sources, targets, home_trash.to_owned()),
            _ => Request::move_back(sources, targets),
        }),
    }
}

// The trash -----------------------------------------------------------------------------------

/// The user's trashes: the home trash at `home_trash` (`$XDG_DATA_HOME/Trash`, or the sample
/// home's in tests and scenes), and each mounted file system's.
pub fn trash_of(home_trash: &Path) -> Trash {
    let mut dirs = BaseDirs::from_env();
    dirs.data_home = model::parent(home_trash).to_owned();
    Trash::new(&dirs)
}

/// The items of `trash` that the files `trashed`, each in some trash's `files/`, are,
/// parallel to them: None for a file no info file speaks for. Reads only the trashes they are
/// in.
pub fn trash_items(trash: &Trash, trashed: &[PathBuf]) -> Vec<Option<TrashItem>> {
    let mut items = Vec::new();
    for dir in trash.dirs() {
        let files = dir.files();
        if trashed.iter().any(|p| model::parent(p) == files) {
            let _ = dir.list(&mut items);
        }
    }
    trashed
        .iter()
        .map(|p| items.iter().find(|i| i.file_path() == *p).cloned())
        .collect()
}

/// Lists every trash for the trash view: a listing rooted at "/" whose names are the trashed
/// files' paths without the leading slash (so `path_of` gives where they are now), and the
/// items, saying where each was and when it was deleted, parallel to its entries. Hidden
/// files are not hidden in the trash. Blocking: run it on a worker.
pub fn list_trash(home_trash: &Path) -> (model::Listing, Vec<TrashItem>) {
    let mut items = Vec::new();
    // A trash that cannot be read leaves the others listed.
    for dir in trash_of(home_trash).dirs() {
        let _ = dir.list(&mut items);
    }
    let mut b = model::Builder::new();
    for item in &items {
        let path = item.file_path();
        let mut e = model::stat_entry(&path, item.name.as_bytes());
        e.hidden = false;
        b.add(&path.as_os_str().as_bytes()[1..], e);
    }
    (b.finish("/"), items)
}

/// Restoring trashed files, in the trashes beside `home_trash`, to where they were, leaving
/// out those whose info files do not say; Err with the status line's message when none do.
pub fn restore_request(trashed: &[PathBuf], home_trash: &Path) -> Result<Request, &'static str> {
    let items = trash_items(&trash_of(home_trash), trashed);
    let (sources, targets): (Vec<PathBuf>, Vec<PathBuf>) = trashed
        .iter()
        .zip(items)
        .filter_map(|(p, item)| Some((p.clone(), item?.original)))
        .unzip();
    if sources.is_empty() {
        return Err("These items do not say where they came from");
    }
    Ok(Request::restore(sources, targets, home_trash.to_owned()))
}

/// Deleting everything in every trash, files and info files; Err with the status line's
/// message when there is nothing.
pub fn empty_trash_request(home_trash: &Path) -> Result<Request, &'static str> {
    let mut items = Vec::new();
    for dir in trash_of(home_trash).dirs() {
        for d in [dir.files(), dir.info()] {
            let Ok(read) = fs::read_dir(&d) else { continue };
            items.extend(
                read.flatten()
                    .map(|e| model::join(&d, e.file_name().as_bytes())),
            );
        }
    }
    if items.is_empty() {
        return Err("The trash is empty");
    }
    Ok(Request::delete(items))
}
