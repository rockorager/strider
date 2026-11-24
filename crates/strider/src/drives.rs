//! Drives: the Drives folder (`//drives`), which lists the drives and what is mounted where
//! users mount things, and mounting, unlocking, unmounting, and ejecting them through UDisks2
//! on the system bus.
//!
//! The list comes from UDisks2's `GetManagedObjects`, fetched again whenever it says something
//! changed (InterfacesAdded, InterfacesRemoved, PropertiesChanged), one fetch at a time.
//! Without UDisks2 it comes from the mount table, read again when the kernel marks
//! `/proc/self/mountinfo` changed. Each operation is a [`Job`](strider_machines::drives)
//! chart, whose calls allow interactive authorization, so polkit may ask the user.
//!
//! A drive's row stands for its mount point: "//drives/LABEL" goes there, a mount point's
//! parent is Drives, and the header names a folder on a drive by the drive's label.

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use keywork::Timer;
use keywork::dbus::{
    ALLOW_INTERACTIVE_AUTHORIZATION, Array, Bus, BusEvent, CallId, Error as BusError, MatchRule,
    Message, Value,
};
use keywork::desktop::mime::MimeDb;
use keywork::desktop::mounts::MountWatcher;
use keywork::prelude::*;
use plusthree::host::{Scheduler, TimerToken};
use strider_core::drives::{self as core, Drive, Object, Space, Volume};
use strider_core::model::{self, DRIVES_PATH};
use strider_core::options::Sort;
use strider_machines::driver::Driver;
use strider_machines::drives::{Job as Chart, JobEv, JobFx, Plan, Step};
use strider_machines::mode::Prompt;

use crate::app::{self, Col, Strider};
use crate::folder::Listed;
use crate::preview::{Info, Preview};

const UDISKS: &str = "org.freedesktop.UDisks2";
const ROOT: &str = "/org/freedesktop/UDisks2";
const OBJECT_MANAGER: &str = "org.freedesktop.DBus.ObjectManager";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const BUS_DRIVER: &str = "org.freedesktop.DBus";
const BLOCK: &str = "org.freedesktop.UDisks2.Block";
const FILESYSTEM: &str = "org.freedesktop.UDisks2.Filesystem";
const DRIVE: &str = "org.freedesktop.UDisks2.Drive";
const ENCRYPTED: &str = "org.freedesktop.UDisks2.Encrypted";

/// Polkit may ask the user, who may take their time.
const CALL_TIMEOUT: Duration = Duration::from_secs(24 * 3600);

/// The mounted drives' space, by their entries' names in Drives.
pub type Spaces = Arc<Mutex<HashMap<Vec<u8>, Space>>>;

/// The drives, where they come from, and the operations in flight.
#[derive(Default)]
pub struct Drives {
    /// Sorted by label when from UDisks2; in the mount table's order otherwise.
    pub list: Vec<Drive>,
    /// What UDisks2's drives' operations act on, by block path.
    volumes: Vec<Volume>,
    /// The mounted drives' space, by their entries' names, from the last read of Drives.
    space: Spaces,
    jobs: Vec<Job>,
    next_job: u64,
    /// The volume the passphrase prompt is for, and its label.
    unlock: Option<(String, String)>,
    bus: Option<Bus>,
    udisks: Udisks,
    mounts: Option<MountWatcher>,
    #[cfg(test)]
    fake: Option<Box<dyn Fake>>,
}

/// The state of the conversation with UDisks2.
#[derive(Default)]
struct Udisks {
    /// Its name has an owner, and its objects came.
    present: bool,
    fetch: Option<CallId>,
    /// A change came during a fetch: fetch again when it answers.
    stale: bool,
    /// Calls in flight, by the job that made them.
    calls: Vec<(CallId, u64)>,
}

/// An operation on a drive, from the command that started it to its last step.
struct Job {
    id: u64,
    /// The window that started it, which hears how it went and goes where it mounted.
    window: Option<WindowId>,
    chart: Driver<Chart, Timer>,
    label: String,
    /// Unlock and mount: the device; unmount: the file system's block.
    target: String,
    /// The encrypted volume, to unlock again after a wrong passphrase or to lock.
    backing: String,
    drive: String,
    power_off: bool,
    /// The passphrase, until the unlock call takes it.
    passphrase: Option<String>,
    /// What the last call answered: the cleartext device, or where it mounted.
    reply: Option<String>,
}

/// A stand-in for UDisks2 in tests: it answers each call at once, and says what its objects
/// are after.
#[cfg(test)]
pub trait Fake {
    /// Calls `member` on the object at `path`; the answer is what the call returns, or the
    /// D-Bus error's name and message.
    fn call(
        &mut self,
        path: &str,
        member: &str,
        passphrase: Option<&str>,
    ) -> std::result::Result<Option<String>, (String, String)>;
    fn objects(&self) -> Vec<Object>;
}

fn is_drives(path: &Path) -> bool {
    path == Path::new(DRIVES_PATH)
}

// The list -------------------------------------------------------------------------------------

/// New drives: the Drives folder is read again, and a folder on a drive that came or went has
/// its parent and header named anew.
pub fn set_list(s: &mut Strider, tx: &mut Txn<'_, Strider>, list: Vec<Drive>) -> Result<()> {
    if list == s.drives.list {
        return Ok(());
    }
    s.drives.list = list;
    let drives = PathBuf::from(DRIVES_PATH);
    if s.cache.get(&drives).is_some() {
        crate::cache::invalidate(s, tx, &drives)?;
    }
    app::others(tx, drives_changed);
    drives_changed(s, tx)
}

/// New drives from a callback, told in the first window, which tells the others; without a
/// window they are kept, and Drives is read anew when one shows it.
fn new_list(s: &mut Strider, cx: &mut Cx<'_, Strider>, list: Vec<Drive>) -> Result<()> {
    match s.wins.first().map(|w| w.window) {
        Some(first) => app::in_window(s, cx, Some(first), |s, tx| set_list(s, tx, list)),
        None => {
            if list != s.drives.list {
                s.drives.list = list;
                s.cache.dirs.remove(Path::new(DRIVES_PATH));
            }
            Ok(())
        }
    }
}

/// The drives changed: this window's folder on a drive that came or went has its parent and
/// header named anew.
fn drives_changed(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let up = parent_of(s, &s.cwd).map(|(p, _)| p);
    if up != s.parent_path {
        let cwd = s.cwd.clone();
        return app::cd(s, tx, cwd, None, false);
    }
    app::draw_header(s, tx)?;
    app::draw_status(s, tx)
}

/// The drives in the mount table, while UDisks2 does not run.
fn from_mount_table(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    let list = mount_table(s);
    new_list(s, cx, list)
}

fn mount_table(s: &mut Strider) -> Vec<Drive> {
    let Some(w) = &s.drives.mounts else {
        return Vec::new();
    };
    let mounts: Vec<core::Mount> = w
        .mounts()
        .iter()
        .map(|m| core::Mount {
            mount_point: m.mount_point.clone(),
            device: m.source.clone(),
            fstype: m.fs_type.clone(),
        })
        .collect();
    s.drives.volumes.clear();
    core::from_mounts(&mounts)
}

/// UDisks2's objects, as the drives they make.
#[cfg(test)]
fn from_objects(s: &mut Strider, tx: &mut Txn<'_, Strider>, objects: &[Object]) -> Result<()> {
    let (list, volumes) = core::from_udisks(objects);
    s.drives.volumes = volumes;
    set_list(s, tx, list)
}

/// UDisks2's objects, from a callback.
fn objects_came(s: &mut Strider, cx: &mut Cx<'_, Strider>, objects: &[Object]) -> Result<()> {
    let (list, volumes) = core::from_udisks(objects);
    s.drives.volumes = volumes;
    new_list(s, cx, list)
}

/// What reads the Drives folder when `path` is it: the drives as they are now, and where
/// their space goes.
pub fn reader(s: &Strider, path: &Path) -> Option<(Vec<Drive>, Spaces)> {
    is_drives(path).then(|| (s.drives.list.clone(), s.drives.space.clone()))
}

/// Reads a folder, or with `drives` the Drives folder: each mounted drive's space, which can
/// wait on its file system, so it runs on a worker.
pub fn read(path: &Path, db: &MimeDb, sort: Sort, drives: Option<(Vec<Drive>, Spaces)>) -> Listed {
    let Some((list, space)) = drives else {
        return crate::folder::read(path, db, sort);
    };
    let spaces: Vec<Option<Space>> = list
        .iter()
        .map(|d| d.mounted().then(|| space_of(&d.mount_point)).flatten())
        .collect();
    let mut map = space.lock().unwrap_or_else(|e| e.into_inner());
    map.clear();
    for (d, sp) in list.iter().zip(&spaces) {
        if let Some(sp) = sp {
            map.insert(core::entry_name(&d.label), *sp);
        }
    }
    let listing = core::listing(&list, &spaces);
    let sorted = model::sort(&listing, sort, |_| ());
    Listed {
        types: list.iter().map(Drive::icon_type).collect(),
        listing,
        error: None,
        sorted,
        sort,
    }
}

/// A mounted file system's size and the space left to its users.
fn space_of(path: &Path) -> Option<Space> {
    let st = rustix::fs::statfs(path).ok()?;
    let unit = if st.f_frsize > 0 {
        st.f_frsize as u64
    } else {
        st.f_bsize as u64
    };
    Some(Space {
        total: st.f_blocks * unit,
        free: st.f_bavail * unit,
    })
}

// The Drives folder ---------------------------------------------------------------------------

/// The drive the entry at `pos` of the folder `col` shows stands for, with its space.
fn drive_at(s: &Strider, col: Col, pos: usize) -> Option<(&Drive, Option<Space>)> {
    let f = s.folder(col).filter(|f| is_drives(&f.path))?;
    let name = f.entry(pos).map(|e| f.listing.name(e))?;
    let d = core::by_entry(&s.drives.list, name)?;
    let space = s
        .drives
        .space
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(name)
        .copied();
    Some((d, space))
}

/// Whether the current folder is Drives.
pub fn in_drives(s: &Strider) -> bool {
    is_drives(&s.cwd)
}

/// The drive under the cursor in Drives.
pub fn under_cursor(s: &Strider) -> Option<Drive> {
    drive_at(s, Col::Current, s.cur().cursor).map(|(d, _)| d.clone())
}

/// What a drive's row shows.
pub struct Row {
    /// Beside its name: its free space, or that it is not mounted.
    pub info: String,
    /// One that is not is muted, as a hidden file is.
    pub mounted: bool,
    /// A mounted drive's space, for the bar beside its free space.
    pub space: Option<Space>,
}

/// The row of the drive the entry at `pos` of the folder `col` shows, if it shows one.
pub fn row(s: &Strider, col: Col, pos: usize) -> Option<Row> {
    drive_at(s, col, pos).map(|(d, space)| Row {
        info: core::row_info(d, space),
        mounted: d.mounted(),
        space: space.filter(|sp| d.mounted() && sp.total != 0),
    })
}

/// The status line for the drive under the cursor in Drives.
pub fn status(s: &Strider) -> Option<String> {
    let (d, space) = drive_at(s, Col::Current, s.cur().cursor)?;
    Some(core::status(d, space))
}

/// The preview of the drive under the cursor in Drives: a mounted one's folder, and the size
/// of one that is not. False when the cursor is on no drive.
pub fn preview(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<bool> {
    if !s.options.preview || !is_drives(&s.cwd) {
        return Ok(false);
    }
    let Some((d, _)) = drive_at(s, Col::Current, s.cur().cursor) else {
        return Ok(false);
    };
    let d = d.clone();
    crate::preview::stop(s, tx)?;
    s.preview = if d.mounted() {
        Preview::Folder(d.mount_point)
    } else {
        Preview::Info(Info {
            rows: if d.size != 0 {
                vec![("Size", model::format_size(d.size))]
            } else {
                Vec::new()
            },
            title: d.label,
            note: Some("Not mounted. Opening it mounts it.".into()),
        })
    };
    Ok(true)
}

/// Where a path goes: a drive's entry in Drives ("//drives/LABEL") to its mount point.
pub fn resolve(s: &Strider, path: PathBuf) -> PathBuf {
    let drives = Path::new(DRIVES_PATH);
    match path.strip_prefix(drives) {
        Ok(name) if model::parent(&path) == drives && !name.as_os_str().is_empty() => {
            core::by_entry(&s.drives.list, name.as_os_str().as_bytes())
                .filter(|d| d.mounted())
                .map_or(path.clone(), |d| d.mount_point.clone())
        }
        _ => path,
    }
}

/// Where h goes from `path`, and the name of `path` there; none at the top.
pub fn parent_of(s: &Strider, path: &Path) -> Option<(PathBuf, Vec<u8>)> {
    core::parent_of(&s.drives.list, path)
}

/// l in Drives: a drive that is not mounted mounts; a mounted one opens. False elsewhere.
pub fn enter(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<bool> {
    let Some((d, _)) = drive_at(s, Col::Current, s.cur().cursor) else {
        return Ok(false);
    };
    let d = d.clone();
    if d.mounted() {
        app::cd(s, tx, d.mount_point, None, true)?;
    } else {
        mount(s, tx, &d)?;
    }
    Ok(true)
}

/// What a command cannot do in Drives, whose rows are drives, not files.
pub fn refused(s: &Strider, command: &str) -> Option<&'static str> {
    if !is_drives(&s.cwd) {
        return None;
    }
    Some(match command {
        "rename" | "rename-append" | "rename-insert" | "bulk-rename" => {
            "Rename files in a folder, not Drives"
        }
        "create" | "mkdir" | "touch" => "Make files in a folder, not Drives",
        "paste" | "paste-overwrite" | "paste-link" => "Paste into a folder, not Drives",
        _ => return None,
    })
}

// Commands -------------------------------------------------------------------------------------

/// `:drives`.
pub fn show(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    app::cd(s, tx, PathBuf::from(DRIVES_PATH), None, true)
}

/// `:mount NAME`: the first drive by that label (any, without one) goes to its mount point,
/// mounting it first.
pub fn mount_named(s: &mut Strider, tx: &mut Txn<'_, Strider>, name: &str) -> Result<()> {
    let found = s
        .drives
        .list
        .iter()
        .find(|d| name.is_empty() || d.label.eq_ignore_ascii_case(name))
        .cloned();
    match found {
        Some(d) if d.mounted() => app::cd(s, tx, d.mount_point, None, true),
        Some(d) if has_udisks(s) => mount(s, tx, &d),
        _ => say(s, tx, "No such drive", true),
    }
}

/// `:unmount` and `:eject`: in Drives the drive under the cursor, mounted or not (an unlocked
/// volume locks, an ejectable drive ejects); elsewhere the drive this folder is on, or the
/// mounted one named.
pub fn unmount_named(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    name: &str,
    eject: bool,
) -> Result<()> {
    let cursor = if name.is_empty() {
        drive_at(s, Col::Current, s.cur().cursor).map(|(d, _)| d.id.clone())
    } else {
        None
    };
    let here = s.cur().path.clone();
    let found = s
        .drives
        .list
        .iter()
        .find(|d| match &cursor {
            Some(id) => &d.id == id,
            None => {
                d.mounted()
                    && (name.is_empty() && model::is_within(&here, &d.mount_point)
                        || d.label.eq_ignore_ascii_case(name))
            }
        })
        .cloned();
    match found {
        Some(d) if has_udisks(s) => unmount(s, tx, &d, eject),
        Some(_) => say(s, tx, "Unmounting needs UDisks2", true),
        None => say(
            s,
            tx,
            "This folder is not on a drive that can be unmounted",
            true,
        ),
    }
}

fn say(s: &mut Strider, tx: &mut Txn<'_, Strider>, text: &str, error: bool) -> Result<()> {
    s.notify(text, error);
    app::draw_status(s, tx)
}

fn has_udisks(s: &Strider) -> bool {
    #[cfg(test)]
    if s.drives.fake.is_some() {
        return true;
    }
    s.drives.udisks.present
}

fn volume_of(s: &Strider, d: &Drive) -> Option<Volume> {
    s.drives.volumes.iter().find(|v| v.block == d.id).cloned()
}

/// Mounts the drive and goes there; a locked volume asks for its passphrase first.
fn mount(s: &mut Strider, tx: &mut Txn<'_, Strider>, d: &Drive) -> Result<()> {
    if !has_udisks(s) {
        return say(s, tx, "Mounting needs UDisks2", true);
    }
    let Some(v) = volume_of(s, d) else {
        return Ok(());
    };
    if v.locked {
        return ask_passphrase(s, tx, v.block, d.label.clone(), None);
    }
    start(s, tx, d, &v, Plan::Mount, None)
}

/// Unmounts the drive's file system, locks the encrypted volume it is on, and with `eject`
/// ejects or powers off its drive after. Tabs on the drive leave it first, so they do not
/// keep it busy.
fn unmount(s: &mut Strider, tx: &mut Txn<'_, Strider>, d: &Drive, eject: bool) -> Result<()> {
    let Some(v) = volume_of(s, d) else {
        return Ok(());
    };
    let eject = eject && (v.ejectable || v.can_power_off);
    let lock = !v.backing.is_empty();
    let plan = if d.mounted() {
        leave_mount(s, tx, d)?;
        Plan::Unmount { lock, eject }
    } else if lock {
        Plan::Lock { eject }
    } else if eject {
        Plan::Eject
    } else {
        return Ok(());
    };
    start(s, tx, d, &v, plan, None)
}

/// A drive is about to be unmounted: tabs on it, in every window, go to Drives, the cursor
/// on it.
fn leave_mount(s: &mut Strider, tx: &mut Txn<'_, Strider>, d: &Drive) -> Result<()> {
    let other = d.clone();
    app::others(tx, move |s, tx| leave_mount_here(s, tx, &other));
    leave_mount_here(s, tx, d)
}

fn leave_mount_here(s: &mut Strider, tx: &mut Txn<'_, Strider>, d: &Drive) -> Result<()> {
    let drives = PathBuf::from(DRIVES_PATH);
    let active = s.active;
    for (i, t) in s.tabs.iter_mut().enumerate() {
        if i != active && model::is_within(&t.cwd, &d.mount_point) {
            t.history.truncate(t.history_pos + 1);
            t.history.push(drives.clone());
            t.history_pos = t.history.len() - 1;
            t.cwd = drives.clone();
        }
    }
    if model::is_within(&s.cwd, &d.mount_point) {
        let name = core::entry_name(&d.label);
        app::cd(s, tx, drives, Some(&name), true)?;
    }
    Ok(())
}

// The passphrase ------------------------------------------------------------------------------

/// An encrypted volume asks for its passphrase in the command line, saying why when a try
/// failed.
pub fn ask_passphrase(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    block: String,
    label: String,
    failure: Option<&str>,
) -> Result<()> {
    if let Some(f) = failure {
        s.log_message(f, true);
    }
    let text = match failure {
        Some(f) => format!("{f} Unlock “{label}”"),
        None => format!("Unlock “{label}”"),
    };
    s.drives.unlock = Some((block, label));
    crate::prompt::start(s, tx, Prompt::Passphrase, "", 0, 0)?;
    s.message = Some((text, failure.is_some()));
    app::draw_status(s, tx)
}

/// Enter in the passphrase prompt: unlocks the volume it is for, then mounts it.
pub fn unlock(s: &mut Strider, tx: &mut Txn<'_, Strider>, passphrase: &str) -> Result<()> {
    s.message = None;
    let Some((block, _)) = s.drives.unlock.take() else {
        return app::draw_status(s, tx);
    };
    let Some(d) = s.drives.list.iter().find(|d| d.id == block).cloned() else {
        return app::draw_status(s, tx);
    };
    let Some(v) = volume_of(s, &d) else {
        return app::draw_status(s, tx);
    };
    start(s, tx, &d, &v, Plan::Unlock, Some(passphrase.to_owned()))
}

/// Escape in the passphrase prompt.
pub fn cancel_unlock(s: &mut Strider) {
    s.drives.unlock = None;
    s.message = None;
}

// Jobs ----------------------------------------------------------------------------------------

/// Starts the job for `plan` on drive `d`.
fn start(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    d: &Drive,
    v: &Volume,
    plan: Plan,
    passphrase: Option<String>,
) -> Result<()> {
    s.drives.next_job += 1;
    let id = s.drives.next_job;
    s.drives.jobs.push(Job {
        id,
        window: tx.window(),
        chart: Driver::new(Chart::machine(), ()),
        label: d.label.clone(),
        target: v.block.clone(),
        backing: if plan == Plan::Unlock {
            v.block.clone()
        } else {
            v.backing.clone()
        },
        drive: v.drive.clone(),
        power_off: !v.ejectable,
        passphrase,
        reply: None,
    });
    step(s, tx, id, JobEv::Start(plan))
}

/// Starts the job's timers on the loop, each calling back with its token.
struct JobClock<'a, 't> {
    tx: &'a mut Txn<'t, Strider>,
    id: u64,
}

impl Scheduler<Timer> for JobClock<'_, '_> {
    fn schedule(&mut self, delay: Duration, token: TimerToken) -> Timer {
        let id = self.id;
        self.tx.after(delay, move |s: &mut Strider, cx| {
            app::back(s, cx, |s, tx| {
                let Some(j) = s.drives.jobs.iter_mut().find(|j| j.id == id) else {
                    return Ok(());
                };
                let fx = j.chart.fire(token, JobClock { tx, id });
                apply(s, tx, id, fx)
            })
        })
    }

    fn cancel(&mut self, timer: Timer) {
        self.tx.cancel_timer(timer);
    }
}

/// Steps job `id`'s chart, and carries out what it asks.
fn step(s: &mut Strider, tx: &mut Txn<'_, Strider>, id: u64, ev: JobEv) -> Result<()> {
    let Some(j) = s.drives.jobs.iter_mut().find(|j| j.id == id) else {
        return Ok(());
    };
    let fx = j.chart.send(ev, JobClock { tx, id });
    apply(s, tx, id, fx)
}

fn apply(s: &mut Strider, tx: &mut Txn<'_, Strider>, id: u64, fx: Vec<JobFx>) -> Result<()> {
    for f in fx {
        let Some(j) = s.drives.jobs.iter_mut().find(|j| j.id == id) else {
            return Ok(());
        };
        match f {
            JobFx::Call(step) => call(s, tx, id, step)?,
            JobFx::Unlocked => {
                if let Some(clear) = j.reply.take() {
                    j.target = clear;
                }
                s.notify("Unlocked", false);
                app::draw_status(s, tx)?;
            }
            JobFx::Mounted => {
                if let Some(mp) = j.reply.take() {
                    app::cd(s, tx, PathBuf::from(mp), None, true)?;
                }
            }
            JobFx::Removable => {
                let text = format!("“{}” can be removed", j.label);
                say(s, tx, &text, false)?;
            }
            JobFx::Failed {
                step: Step::Unlock,
                detail,
            } => {
                let (block, label) = (j.backing.clone(), j.label.clone());
                let why = core::unlock_error(&detail).to_owned();
                ask_passphrase(s, tx, block, label, Some(&why))?;
            }
            JobFx::Failed { step, detail } => {
                let text = format!("Cannot {} “{}”: {detail}", step.verb(), j.label);
                say(s, tx, &text, true)?;
            }
            JobFx::NotUnlocked => say(s, tx, "Not unlocked", false)?,
            JobFx::Done => s.drives.jobs.retain(|j| j.id != id),
        }
    }
    Ok(())
}

/// Makes job `id`'s call for `step`; its answer comes to [`answer`].
fn call(s: &mut Strider, tx: &mut Txn<'_, Strider>, id: u64, step: Step) -> Result<()> {
    let Some(j) = s.drives.jobs.iter_mut().find(|j| j.id == id) else {
        return Ok(());
    };
    let (path, iface, member) = match step {
        Step::Unlock => (j.target.clone(), ENCRYPTED, "Unlock"),
        Step::Mount => (j.target.clone(), FILESYSTEM, "Mount"),
        Step::Unmount => (j.target.clone(), FILESYSTEM, "Unmount"),
        Step::Lock => (j.backing.clone(), ENCRYPTED, "Lock"),
        Step::Eject if j.power_off => (j.drive.clone(), DRIVE, "PowerOff"),
        Step::Eject => (j.drive.clone(), DRIVE, "Eject"),
    };
    let passphrase = if step == Step::Unlock {
        j.passphrase.take()
    } else {
        None
    };
    #[cfg(test)]
    if let Some(fake) = &mut s.drives.fake {
        let result = fake.call(&path, member, passphrase.as_deref());
        tx.after(Duration::ZERO, move |s: &mut Strider, cx| {
            app::back(s, cx, |s, tx| {
                let objects = s.drives.fake.as_ref().map(|f| f.objects());
                if let Some(objects) = objects {
                    from_objects(s, tx, &objects)?;
                }
                answer(s, tx, id, result)
            })
        });
        return Ok(());
    }
    let mut body = Vec::new();
    if let Some(p) = passphrase {
        body.push(Value::Str(p));
    }
    body.push(Value::Array(Array::dict([])));
    let sent = match (&mut s.drives.bus, s.drives.udisks.present) {
        (Some(bus), true) => Message::method_call(Some(UDISKS), &path, Some(iface), member)
            .and_then(|m| {
                let mut m = m.with_body(body);
                m.flags |= ALLOW_INTERACTIVE_AUTHORIZATION;
                bus.call(m)
            })
            .ok(),
        _ => None,
    };
    match sent {
        Some(c) => s.drives.udisks.calls.push((c, id)),
        None => {
            s.drives.jobs.retain(|j| j.id != id);
            say(s, tx, "UDisks2 is not available", true)?;
        }
    }
    Ok(())
}

/// A job's call answered: with what it returns, or the D-Bus error's name and message.
fn answer(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    id: u64,
    result: std::result::Result<Option<String>, (String, String)>,
) -> Result<()> {
    let ev = match result {
        Ok(reply) => {
            if let Some(j) = s.drives.jobs.iter_mut().find(|j| j.id == id) {
                j.reply = reply;
            }
            JobEv::Ok
        }
        Err((name, detail)) => JobEv::Error { name, detail },
    };
    step(s, tx, id, ev)
}

// Watching ------------------------------------------------------------------------------------

/// Reads the mount table and follows its changes, then asks UDisks2 for the drives, on the
/// app's loop. Not for tests and scenes, which have the drives they say.
pub fn start_watching(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    if let Ok(w) = MountWatcher::new() {
        let fd = w
            .as_fd()
            .try_clone_to_owned()
            .map_err(keywork::Error::app)?;
        s.drives.mounts = Some(w);
        cx.watch_fd(fd, keywork::Interest::PRIORITY, |s: &mut Strider, cx, _| {
            let changed = s
                .drives
                .mounts
                .as_mut()
                .is_some_and(|w| w.refresh().unwrap_or(false));
            if changed && !s.drives.udisks.present {
                from_mount_table(s, cx)?;
            }
            Ok(())
        })?;
        from_mount_table(s, cx)?;
    }
    let Ok(mut bus) = connect() else {
        return Ok(());
    };
    cx.attach_bus(&mut bus, system_bus, on_bus)?;
    s.drives.bus = Some(bus);
    fetch(s);
    Ok(())
}

/// The system bus, subscribed to UDisks2's signals.
fn connect() -> std::result::Result<Bus, BusError> {
    let mut bus = Bus::system()?;
    bus.set_timeout(CALL_TIMEOUT);
    let rules = [
        MatchRule::signal(OBJECT_MANAGER, "InterfacesAdded")
            .sender(UDISKS)
            .path(ROOT),
        MatchRule::signal(OBJECT_MANAGER, "InterfacesRemoved")
            .sender(UDISKS)
            .path(ROOT),
        MatchRule::signal(PROPERTIES, "PropertiesChanged").sender(UDISKS),
        MatchRule::signal(BUS_DRIVER, "NameOwnerChanged")
            .sender(BUS_DRIVER)
            .arg0(UDISKS),
    ];
    for rule in rules {
        bus.subscribe(rule)?;
    }
    Ok(bus)
}

fn system_bus(s: &mut Strider) -> &mut Bus {
    s.drives
        .bus
        .as_mut()
        .expect("the system bus stays while attached")
}

/// Asks UDisks2 for its objects, unless a fetch is on its way, which fetches again after.
fn fetch(s: &mut Strider) {
    let u = &mut s.drives.udisks;
    if u.fetch.is_some() {
        u.stale = true;
        return;
    }
    let Some(bus) = &mut s.drives.bus else {
        return;
    };
    let msg = Message::method_call(
        Some(UDISKS),
        ROOT,
        Some(OBJECT_MANAGER),
        "GetManagedObjects",
    );
    u.fetch = msg.and_then(|m| bus.call(m)).ok();
}

fn on_bus(s: &mut Strider, cx: &mut Cx<'_, Strider>, event: BusEvent) -> Result<()> {
    match event {
        BusEvent::Reply { call, result } if s.drives.udisks.fetch == Some(call) => {
            s.drives.udisks.fetch = None;
            if std::mem::take(&mut s.drives.udisks.stale) {
                fetch(s);
                return Ok(());
            }
            match result.ok().and_then(|m| m.body.into_iter().next()) {
                Some(all) => {
                    s.drives.udisks.present = true;
                    let objects = parse_objects(&all);
                    objects_came(s, cx, &objects)
                }
                // UDisks2 does not run: the mount table's drives.
                None => {
                    s.drives.udisks.present = false;
                    from_mount_table(s, cx)
                }
            }
        }
        BusEvent::Reply { call, result } => {
            let calls = &mut s.drives.udisks.calls;
            let Some(i) = calls.iter().position(|(c, _)| *c == call) else {
                return Ok(());
            };
            let (_, id) = calls.remove(i);
            let result = match result {
                Ok(m) => Ok(m.body.first().and_then(Value::as_str).map(str::to_owned)),
                Err(BusError::Remote { name, message }) => Err((name, message)),
                Err(e) => Err((keywork::dbus::error_names::FAILED.to_owned(), e.to_string())),
            };
            // In the window that started the job, or the one used last.
            let window = s
                .drives
                .jobs
                .iter()
                .find(|j| j.id == id)
                .and_then(|j| j.window)
                .filter(|w| s.wins.iter().any(|x| x.window == *w))
                .or_else(|| s.last_window());
            app::in_window(s, cx, window, |s, tx| answer(s, tx, id, result))
        }
        BusEvent::Signal { message, .. } => {
            if message.member.as_deref() == Some("NameOwnerChanged") {
                let owner = message.body.get(2).and_then(Value::as_str).unwrap_or("");
                if owner.is_empty() {
                    s.drives.udisks.present = false;
                    return from_mount_table(s, cx);
                }
            }
            fetch(s);
            Ok(())
        }
        BusEvent::Disconnected(_) => {
            s.drives.udisks.present = false;
            from_mount_table(s, cx)
        }
        _ => Ok(()),
    }
}

/// `a{oa{sa{sv}}}`: objects, their interfaces, and their properties.
fn parse_objects(all: &Value) -> Vec<Object> {
    let mut out = Vec::new();
    for (path, ifaces) in all.dict_entries() {
        let mut o = Object {
            path: path.as_str().unwrap_or_default().to_owned(),
            ..Object::default()
        };
        for (iface, props) in ifaces.dict_entries() {
            let iface = iface.as_str().unwrap_or_default();
            match iface {
                BLOCK => o.block = true,
                FILESYSTEM => o.filesystem = true,
                DRIVE => o.drive = true,
                ENCRYPTED => o.encrypted = true,
                _ => continue,
            }
            for (key, v) in props.dict_entries() {
                property(
                    &mut o,
                    iface,
                    key.as_str().unwrap_or_default(),
                    v.unwrap_variants(),
                );
            }
        }
        out.push(o);
    }
    out
}

fn property(o: &mut Object, iface: &str, key: &str, v: &Value) {
    let text = || v.as_str().unwrap_or_default().to_owned();
    let flag = || matches!(v, Value::Bool(true));
    match (iface, key) {
        (BLOCK, "Drive") => o.drive_path = text(),
        (BLOCK, "IdLabel") => o.label = text(),
        (BLOCK, "HintName") => o.hint_name = text(),
        (BLOCK, "HintIconName") => o.hint_icon = text(),
        (BLOCK, "HintIgnore") => o.hint_ignore = flag(),
        (BLOCK, "HintSystem") => o.hint_system = flag(),
        (BLOCK, "Size") => o.size = if let Value::U64(n) = v { *n } else { 0 },
        (BLOCK, "CryptoBackingDevice") => o.crypto_backing = text(),
        (ENCRYPTED, "CleartextDevice") => o.cleartext = text(),
        // aay: the first mount point is the one to show.
        (FILESYSTEM, "MountPoints") => {
            let first = v.as_array().and_then(|a| a.items().first());
            o.mount_point = first.map(byte_path).unwrap_or_default();
        }
        (DRIVE, "Ejectable") => o.ejectable = flag(),
        (DRIVE, "Removable") => o.removable = flag(),
        (DRIVE, "CanPowerOff") => o.can_power_off = flag(),
        _ => {}
    }
}

/// An `ay` holding a NUL-terminated path.
fn byte_path(v: &Value) -> PathBuf {
    use std::os::unix::ffi::OsStringExt;
    let bytes: Vec<u8> = v
        .as_array()
        .map(Array::items)
        .unwrap_or_default()
        .iter()
        .map_while(|b| match *b {
            Value::Byte(b) if b != 0 => Some(b),
            _ => None,
        })
        .collect();
    PathBuf::from(std::ffi::OsString::from_vec(bytes))
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use keywork::app::Headless;
    use keywork::desktop::localtime::Zone;
    use strider_core::config::Config;

    use super::*;

    const P: &str = "/org/freedesktop/UDisks2/";

    /// The Zig build's stand-in UDisks2: a USB stick with a plain file system (sdb1) and a
    /// LUKS volume (sdc1) whose passphrase is "hunter2", unlocked as dm-0. Calls are kept,
    /// as "Mount sdb1", for the test to read.
    struct FakeUdisks {
        mount_dir: PathBuf,
        secret_dir: PathBuf,
        mounted: bool,
        unlocked: bool,
        secret_mounted: bool,
        calls: Rc<RefCell<Vec<String>>>,
    }

    impl Fake for FakeUdisks {
        fn call(
            &mut self,
            path: &str,
            member: &str,
            passphrase: Option<&str>,
        ) -> std::result::Result<Option<String>, (String, String)> {
            let name = path.rsplit('/').next().unwrap_or_default();
            self.calls.borrow_mut().push(format!("{member} {name}"));
            let secret = name == "dm_2d0";
            match member {
                "Unlock" if passphrase != Some("hunter2") => Err((
                    "org.freedesktop.UDisks2.Error.Failed".into(),
                    "Error unlocking /dev/sdc1: Failed to activate device: Operation not \
                     permitted (No key available with this passphrase)"
                        .into(),
                )),
                "Unlock" => {
                    self.unlocked = true;
                    Ok(Some(format!("{P}block_devices/dm_2d0")))
                }
                "Mount" if secret => {
                    self.secret_mounted = true;
                    Ok(Some(self.secret_dir.display().to_string()))
                }
                "Mount" => {
                    self.mounted = true;
                    Ok(Some(self.mount_dir.display().to_string()))
                }
                "Unmount" if secret => {
                    self.secret_mounted = false;
                    Ok(None)
                }
                "Unmount" => {
                    self.mounted = false;
                    Ok(None)
                }
                "Lock" => {
                    self.unlocked = false;
                    Ok(None)
                }
                _ => Ok(None),
            }
        }

        fn objects(&self) -> Vec<Object> {
            let drive = format!("{P}drives/Stick");
            let mounted = |on: bool, dir: &Path| if on { dir.to_owned() } else { PathBuf::new() };
            let mut v = vec![
                Object {
                    path: format!("{P}block_devices/sdb1"),
                    block: true,
                    filesystem: true,
                    drive_path: drive.clone(),
                    label: "STICK".into(),
                    hint_system: false,
                    size: 16_000_000_000,
                    mount_point: mounted(self.mounted, &self.mount_dir),
                    ..Object::default()
                },
                Object {
                    path: format!("{P}block_devices/sdc1"),
                    block: true,
                    encrypted: true,
                    drive_path: drive.clone(),
                    label: "SECRET".into(),
                    hint_system: false,
                    size: 8_000_000_000,
                    cleartext: if self.unlocked {
                        format!("{P}block_devices/dm_2d0")
                    } else {
                        "/".into()
                    },
                    ..Object::default()
                },
                Object {
                    path: drive,
                    drive: true,
                    removable: true,
                    can_power_off: true,
                    ..Object::default()
                },
            ];
            if self.unlocked {
                v.push(Object {
                    path: format!("{P}block_devices/dm_2d0"),
                    block: true,
                    filesystem: true,
                    crypto_backing: format!("{P}block_devices/sdc1"),
                    label: "SECRET".into(),
                    mount_point: mounted(self.secret_mounted, &self.secret_dir),
                    ..Object::default()
                });
            }
            v
        }
    }

    /// The app in `root/home` (`root` its home) with the stand-in UDisks2, whose stick
    /// mounts on `root/Stick` and whose encrypted volume on `root/Secret`.
    fn start(name: &str) -> (Headless<Strider>, PathBuf, Rc<RefCell<Vec<String>>>) {
        let root =
            std::env::temp_dir().join(format!("strider-drives-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["home", "Stick", "Secret"] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        std::fs::write(root.join("Stick/on-the-stick.txt"), "0123456789").unwrap();
        std::fs::write(root.join("Secret/diary.txt"), "dear diary").unwrap();
        let (mut app, mut state) = crate::app_in(
            root.join("home"),
            root.clone(),
            Config::default(),
            Zone::utc(),
            false,
            None,
        )
        .unwrap();
        let calls = Rc::new(RefCell::new(Vec::new()));
        let fake = FakeUdisks {
            mount_dir: root.join("Stick"),
            secret_dir: root.join("Secret"),
            mounted: false,
            unlocked: false,
            secret_mounted: false,
            calls: calls.clone(),
        };
        let objects = fake.objects();
        state.drives.fake = Some(Box::new(fake));
        let window = state.window;
        app.update(window, |tx| from_objects(&mut state, tx, &objects))
            .unwrap();
        let mut h = app.headless(state).unwrap();
        h.settle().unwrap();
        (h, root, calls)
    }

    /// Types `text` as keys, Enter for `\n`; a character goes into an open prompt as text.
    fn typ(h: &mut Headless<Strider>, text: &str) {
        let window = h.state().window;
        for c in text.chars() {
            if h.state().prompt().is_some() && c != '\n' {
                h.perform(window, &keywork::app::tooling::Action::Type(c.to_string()))
                    .unwrap();
            } else {
                let sym = if c == '\n' {
                    Keysym::RETURN
                } else {
                    Keysym::from_char(c)
                };
                h.key(window, sym, Modifiers::NONE).unwrap();
            }
            h.settle().unwrap();
            // The stand-in answers on the next turn of the loop.
            h.advance(Duration::from_millis(1)).unwrap();
            h.settle().unwrap();
        }
    }

    fn drive<'a>(h: &'a Headless<Strider>, label: &str) -> &'a Drive {
        h.state()
            .drives
            .list
            .iter()
            .find(|d| d.label == label)
            .unwrap()
    }

    fn message(h: &Headless<Strider>) -> String {
        h.state().message.clone().map(|m| m.0).unwrap_or_default()
    }

    fn hovered(h: &Headless<Strider>) -> String {
        String::from_utf8_lossy(h.state().cur().current_name().unwrap_or_default()).into_owned()
    }

    // As the Zig build's test: gv lists the drives as a folder, l on the stick mounts it and
    // goes there; its root's parent is Drives and the header names it by its label; h goes
    // back to Drives on it, which is a top; :eject sends the tab out to Drives and powers the
    // stick off, as it is removable but not ejectable.
    #[test]
    fn mount_browse_unmount_and_power_off() {
        let (mut h, root, calls) = start("stick");
        assert_eq!(h.state().drives.list.len(), 2);
        let stick = drive(&h, "STICK");
        assert!(!stick.mounted() && stick.can_mount && stick.can_eject);

        typ(&mut h, "gv");
        assert_eq!(h.state().cwd, Path::new(DRIVES_PATH));
        assert_eq!(h.state().cur().len(), 2);
        assert_eq!(status(h.state()).as_deref(), Some("Not mounted   8.0 GB"));
        assert!(matches!(&h.state().preview, Preview::Info(i) if i.title == "SECRET"));
        assert_eq!(h.state().parent_path, None, "Drives is a top");

        typ(&mut h, "jl");
        assert_eq!(calls.borrow().as_slice(), ["Mount sdb1"]);
        assert_eq!(h.state().cwd, root.join("Stick"));
        assert_eq!(hovered(&h), "on-the-stick.txt");
        assert!(drive(&h, "STICK").mounted());
        assert_eq!(
            h.state().parent_path.as_deref(),
            Some(Path::new(DRIVES_PATH))
        );
        assert_eq!(crate::crumbs::text(h.state()), "Drives/STICK/");

        typ(&mut h, "h");
        assert_eq!(h.state().cwd, Path::new(DRIVES_PATH));
        assert_eq!(hovered(&h), "STICK");
        assert!(matches!(&h.state().preview, Preview::Folder(p) if *p == root.join("Stick")));
        assert!(status(h.state()).is_some_and(|s| s.contains(" free of ")));
        typ(&mut h, "h");
        assert_eq!(h.state().cwd, Path::new(DRIVES_PATH));
        typ(&mut h, "l");
        assert_eq!(h.state().cwd, root.join("Stick"));

        typ(&mut h, ":eject\n");
        assert_eq!(
            calls.borrow().as_slice(),
            ["Mount sdb1", "Unmount sdb1", "PowerOff Stick"]
        );
        assert_eq!(h.state().cwd, Path::new(DRIVES_PATH));
        assert_eq!(hovered(&h), "STICK");
        assert!(!drive(&h, "STICK").mounted());
        assert_eq!(message(&h), "“STICK” can be removed");
        let _ = std::fs::remove_dir_all(&root);
    }

    // As the Zig build's Drives rows: a mounted drive's used space shows as a bar beside its
    // free space, filled in proportion; one that is not mounted has none.
    #[test]
    fn a_mounted_drive_shows_its_usage_bar() {
        let (mut h, root, _) = start("bar");
        typ(&mut h, "gvjlh");
        assert_eq!(hovered(&h), "STICK");
        let window = h.state().window;
        // The bar, the row's fourth child, and how wide its fill is.
        let bar = |h: &mut Headless<Strider>, label: &str| {
            let rows = h
                .query(
                    window,
                    &keywork::app::tooling::NodeQuery {
                        label: Some(label.into()),
                        ..Default::default()
                    },
                )
                .unwrap();
            h.update(window, |tx| {
                for r in &rows {
                    let Some(bar) = tx.children(r.id)?.nth(3) else {
                        continue;
                    };
                    if tx.children(r.id)?.count() < 5 {
                        continue;
                    }
                    if tx.is_hidden(bar)? {
                        return Ok(None);
                    }
                    let used = tx.children(bar)?.next().unwrap();
                    return Ok(Some((tx.rect(bar)?.width, tx.rect(used)?.width)));
                }
                Ok(None)
            })
            .unwrap()
        };
        let sp = space_of(&root.join("Stick")).unwrap();
        let used = (sp.total - sp.free) as f32 / sp.total as f32;
        assert_eq!(bar(&mut h, "STICK"), Some((48.0, (48.0 * used).round())));
        assert_eq!(bar(&mut h, "SECRET"), None, "not mounted");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The labels of the items of every open menu.
    fn menu_items(h: &mut Headless<Strider>) -> Vec<String> {
        let query = keywork::app::tooling::NodeQuery {
            role: Some(keywork::Role::MenuItem),
            ..Default::default()
        };
        let mut labels = Vec::new();
        for w in h.windows() {
            labels.extend(h.query(w, &query).unwrap().into_iter().map(|n| n.label));
        }
        labels
    }

    // As the Zig build's context menu in Drives: a drive that is not mounted mounts, a
    // mounted one opens, here or in a tab or a terminal, and it unmounts and ejects as it
    // can; none of the file commands Drives refuses.
    #[test]
    fn the_menu_in_drives_is_the_drive_s() {
        let (mut h, root, _) = start("menu");
        typ(&mut h, "gv:menu\n");
        assert_eq!(hovered(&h), "SECRET");
        assert_eq!(menu_items(&mut h), ["Mount", "Eject"]);
        let window = h.state().window;
        h.key(window, Keysym::ESCAPE, Modifiers::NONE).unwrap();
        h.settle().unwrap();

        typ(&mut h, "jlh:menu\n");
        assert_eq!(hovered(&h), "STICK");
        assert_eq!(
            menu_items(&mut h),
            [
                "Open",
                "Open in a new tab",
                "Open terminal here",
                "Unmount",
                "Eject"
            ]
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    // :mount asks for the encrypted volume's passphrase in a masked field; a wrong one says
    // so and asks again; the right one unlocks and mounts the cleartext device and goes
    // there. Eject unmounts, locks, and powers the drive off.
    #[test]
    fn a_passphrase_unlocks_and_mounts_and_eject_locks() {
        let (mut h, root, calls) = start("luks");
        typ(&mut h, ":mount SECRET\n");
        assert_eq!(h.state().prompt(), Some(Prompt::Passphrase));
        assert_eq!(message(&h), "Unlock “SECRET”");

        typ(&mut h, "wrong\n");
        assert_eq!(h.state().prompt(), Some(Prompt::Passphrase));
        assert_eq!(message(&h), "Wrong passphrase. Try again. Unlock “SECRET”");
        assert!(h.state().message.as_ref().is_some_and(|m| m.1));

        typ(&mut h, "hunter2");
        assert_eq!(message(&h), "Wrong passphrase. Try again. Unlock “SECRET”");
        typ(&mut h, "\n");
        assert_eq!(h.state().prompt(), None);
        assert_eq!(h.state().cwd, root.join("Secret"));
        assert_eq!(hovered(&h), "diary.txt");
        assert_eq!(
            calls.borrow().as_slice(),
            ["Unlock sdc1", "Unlock sdc1", "Mount dm_2d0"]
        );
        assert!(drive(&h, "SECRET").mounted());

        typ(&mut h, ":eject\n");
        assert_eq!(h.state().cwd, Path::new(DRIVES_PATH));
        assert_eq!(
            calls.borrow()[3..],
            ["Unmount dm_2d0", "Lock sdc1", "PowerOff Stick"]
        );
        assert!(!drive(&h, "SECRET").mounted());
        let _ = std::fs::remove_dir_all(&root);
    }

    // GetManagedObjects' answer, as the bus decodes it: the interfaces drives read and the
    // properties in their variants, the mount point a NUL-terminated byte string.
    #[test]
    fn managed_objects_parse() {
        let entry = |k: Value, v: Value| Value::DictEntry(Box::new((k, v)));
        let bytes = |s: &str| {
            let mut items: Vec<Value> = s.bytes().map(Value::Byte).collect();
            items.push(Value::Byte(0));
            Value::Array(Array::new("y", items).unwrap())
        };
        let block = Array::dict([
            (
                "Drive".to_owned(),
                Value::Path(keywork::dbus::ObjectPath::new("/d/Stick").unwrap()),
            ),
            ("IdLabel".to_owned(), Value::str("STICK")),
            ("HintSystem".to_owned(), Value::Bool(false)),
            ("Size".to_owned(), Value::U64(16_000_000_000)),
        ]);
        let mounts = Value::Array(Array::new("ay", vec![bytes("/run/media/me/STICK")]).unwrap());
        let fs = Array::dict([("MountPoints".to_owned(), mounts)]);
        let ifaces = Value::Array(
            Array::new(
                "{sa{sv}}",
                vec![
                    entry(Value::str(BLOCK), Value::Array(block)),
                    entry(Value::str(FILESYSTEM), Value::Array(fs)),
                    entry(
                        Value::str("org.freedesktop.UDisks2.Partition"),
                        Value::Array(Array::dict([])),
                    ),
                ],
            )
            .unwrap(),
        );
        let path = Value::Path(keywork::dbus::ObjectPath::new("/b/sdb1").unwrap());
        let all = Value::Array(Array::new("{oa{sa{sv}}}", vec![entry(path, ifaces)]).unwrap());
        let objects = parse_objects(&all);
        assert_eq!(objects.len(), 1);
        let o = &objects[0];
        assert_eq!(o.path, "/b/sdb1");
        assert!(o.block && o.filesystem && !o.drive && !o.encrypted);
        assert_eq!(o.drive_path, "/d/Stick");
        assert_eq!(o.label, "STICK");
        assert!(!o.hint_system);
        assert_eq!(o.size, 16_000_000_000);
        assert_eq!(o.mount_point, Path::new("/run/media/me/STICK"));
    }

    // Without UDisks2, mounting says so; the mount table's drives still list.
    #[test]
    fn without_udisks() {
        let (mut h, root, _) = start("none");
        h.state_mut().drives.fake = None;
        typ(&mut h, ":mount STICK\n");
        assert_eq!(message(&h), "No such drive");
        typ(&mut h, "gvl");
        assert_eq!(message(&h), "Mounting needs UDisks2");
        let _ = std::fs::remove_dir_all(&root);
    }
}
