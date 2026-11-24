//! The folders read so far, by path, so going up, down, and back shows a folder at once from
//! memory, its cursor and marks where they were, while a read that is due runs behind it.
//! Each has a [`folder`](strider_machines::folder) statechart for its reads. Folders are read
//! on Keywork's blocking lane, and one inotify watcher follows every cached folder: a shown one
//! that changes is read again, others when next shown. One that cannot be watched is read again
//! when shown after `stale_ms`.

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

use keywork::desktop::watch::{DirWatcher, WatchId};
use keywork::prelude::*;
use keywork::{Instant, Timer};
use plusthree::host::NoTimers;
use strider_machines::driver::Driver;
use strider_machines::folder::{Folder as Chart, FolderEv, FolderFx};

use crate::app::{self, Col, Strider};
use crate::folder::{self, Folder, Listed};
use crate::preview::Preview;

/// How many folders no column shows stay cached.
const MAX_CACHED: usize = 64;
/// Changes to a folder within this long of the first are read together.
const LATENCY: Duration = Duration::from_millis(150);

pub struct Cached {
    pub folder: Folder,
    chart: Driver<Chart, ()>,
    watch: Option<WatchId>,
    /// When the last read came in.
    stamp: Option<std::time::Instant>,
    last_used: u64,
    /// Which read the result belongs to; a cancelled or overtaken read's is dropped.
    generation: u64,
    result: Option<Listed>,
}

pub struct Cache {
    pub dirs: HashMap<PathBuf, Cached>,
    /// The folders columns show.
    shown: Vec<PathBuf>,
    tick: u64,
    generation: u64,
    watcher: Option<DirWatcher>,
    /// The timer armed for the watcher's next batch, by its deadline.
    armed: Option<(Instant, Timer)>,
}

impl Cache {
    pub fn new() -> Cache {
        Cache {
            dirs: HashMap::new(),
            shown: Vec::new(),
            tick: 0,
            generation: 0,
            watcher: DirWatcher::new(LATENCY).ok(),
            armed: None,
        }
    }

    pub fn get(&self, path: &Path) -> Option<&Folder> {
        self.dirs.get(path).map(|c| &c.folder)
    }

    pub fn get_mut(&mut self, path: &Path) -> Option<&mut Folder> {
        self.dirs.get_mut(path).map(|c| &mut c.folder)
    }

    /// The folder at `path`, made if it is not cached, dropping the least recently used
    /// folders no column shows beyond the limit.
    pub fn entry(&mut self, path: &Path) -> &mut Folder {
        self.tick += 1;
        if !self.dirs.contains_key(path) {
            while self.dirs.len() >= MAX_CACHED {
                let Some(victim) = self
                    .dirs
                    .iter()
                    .filter(|(p, _)| !self.shown.contains(p))
                    .min_by_key(|(_, c)| c.last_used)
                    .map(|(p, _)| p.clone())
                else {
                    break;
                };
                let gone = self.dirs.remove(&victim).expect("found");
                if let (Some(w), Some(id)) = (&mut self.watcher, gone.watch) {
                    let _ = w.remove(id);
                }
            }
            self.dirs.insert(
                path.to_owned(),
                Cached {
                    folder: Folder::new(path),
                    chart: Driver::new(Chart::machine(), ()),
                    watch: None,
                    stamp: None,
                    last_used: 0,
                    generation: 0,
                    result: None,
                },
            );
        }
        let c = self.dirs.get_mut(path).expect("inserted");
        c.last_used = self.tick;
        &mut c.folder
    }
}

/// The folders the columns show: the current one, its parent, and a folder under the cursor.
fn wanted(s: &Strider) -> Vec<PathBuf> {
    let mut v = vec![s.cwd.clone()];
    v.extend(s.parent_path.clone());
    if let Preview::Folder(p) = &s.preview {
        v.push(p.clone());
    }
    v
}

/// Tells each folder whether a column shows it now, which starts the reads that are due.
pub fn show(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let now = wanted(s);
    let before = std::mem::replace(&mut s.cache.shown, now.clone());
    for path in before.iter().filter(|p| !now.contains(p)) {
        send(s, tx, path, FolderEv::Hide)?;
    }
    for path in now.iter().filter(|p| !before.contains(p)) {
        let f = s.cache.entry(path);
        // The sort or hidden files may have changed while no column showed it.
        if f.loaded {
            f.arrange(&s.options, None);
        }
        let c = &s.cache.dirs[path];
        let old = c.watch.is_none()
            && c.stamp.is_some_and(|t| {
                t.elapsed() > Duration::from_millis(u64::from(s.options.stale_ms))
            });
        send(s, tx, path, FolderEv::Show { old })?;
    }
    Ok(())
}

/// Steps a folder's chart, and carries out what it asks.
fn send(s: &mut Strider, tx: &mut Txn<'_, Strider>, path: &Path, ev: FolderEv) -> Result<()> {
    let Some(c) = s.cache.dirs.get_mut(path) else {
        return Ok(());
    };
    let fx = c.chart.send(ev, NoTimers);
    for f in fx {
        match f {
            FolderFx::Read => read(s, tx, path)?,
            FolderFx::Cancel => {
                if let Some(c) = s.cache.dirs.get_mut(path) {
                    c.generation = 0;
                }
            }
            FolderFx::Apply => {
                let Some(c) = s.cache.dirs.get_mut(path) else {
                    continue;
                };
                if let Some(listed) = c.result.take() {
                    c.folder.apply(listed, &s.options);
                    c.stamp = Some(std::time::Instant::now());
                }
                redraw(s, tx, path)?;
            }
        }
    }
    Ok(())
}

/// Starts reading `path` on a worker, watching it first so no change slips between the read
/// and the watch.
fn read(s: &mut Strider, tx: &mut Txn<'_, Strider>, path: &Path) -> Result<()> {
    s.cache.generation += 1;
    let generation = s.cache.generation;
    let Some(c) = s.cache.dirs.get_mut(path) else {
        return Ok(());
    };
    c.generation = generation;
    if c.watch.is_none()
        && let Some(w) = &mut s.cache.watcher
    {
        c.watch = w.add(path).ok();
    }
    let (db, sort, owned) = (s.db.clone(), s.options.sort, path.to_owned());
    if s.sync_reads {
        c.result = Some(folder::read(&owned, &db, sort));
        return send(s, tx, path, FolderEv::Read);
    }
    tx.spawn_blocking(
        move || folder::read(&owned, &db, sort),
        move |s: &mut Strider, tx, listed| {
            let path = listed.listing.path.clone();
            match s.cache.dirs.get_mut(&path) {
                Some(c) if c.generation == generation => c.result = Some(listed),
                _ => return Ok(()),
            }
            send(s, tx, &path, FolderEv::Read)
        },
    );
    Ok(())
}

/// Draws the columns showing `path` again, after a read of it came in.
fn redraw(s: &mut Strider, tx: &mut Txn<'_, Strider>, path: &Path) -> Result<()> {
    if path == s.cwd {
        app::reload_preview(s, tx)?;
        app::draw(s, tx)?;
    } else if s.parent_path.as_deref() == Some(path) {
        app::draw(s, tx)?;
    } else if matches!(&s.preview, Preview::Folder(p) if p == path) {
        app::draw_column(s, tx, Col::Preview)?;
    }
    Ok(())
}

/// Follows the watcher's descriptor on the loop, once the app runs.
pub fn start_watching(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    let Some(w) = &s.cache.watcher else {
        return Ok(());
    };
    let fd = w
        .as_fd()
        .try_clone_to_owned()
        .map_err(keywork::Error::app)?;
    cx.watch_fd(fd, keywork::Interest::READABLE, |s: &mut Strider, cx, _| {
        if let Some(w) = &mut s.cache.watcher {
            // A failed read leaves the events queued, and the descriptor readable.
            let _ = w.read(cx.now());
        }
        deliver(s, cx)
    })?;
    Ok(())
}

/// Tells the folders the watcher saw change, and arms a timer for its next batch.
fn deliver(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    let Some(w) = &mut s.cache.watcher else {
        return Ok(());
    };
    let mut ids = Vec::new();
    w.take_changes(|id, _| ids.push(id));
    let deadline = w.deadline();
    let changed: Vec<PathBuf> = s
        .cache
        .dirs
        .iter()
        .filter(|(_, c)| c.watch.is_some_and(|id| ids.contains(&id)))
        .map(|(p, _)| p.clone())
        .collect();
    if !changed.is_empty() {
        let window = s.window;
        cx.update(window, |tx| {
            for path in &changed {
                send(s, tx, path, FolderEv::Changed)?;
            }
            Ok(())
        })?;
    }
    if s.cache.armed.map(|(d, _)| d) != deadline {
        if let Some((_, timer)) = s.cache.armed.take() {
            cx.cancel_timer(timer);
        }
        if let Some(deadline) = deadline {
            let delay = deadline.saturating_duration_since(cx.now());
            let timer = cx.after(delay, |s: &mut Strider, cx| {
                s.cache.armed = None;
                if let Some(w) = &mut s.cache.watcher {
                    w.fire(cx.now());
                }
                deliver(s, cx)
            });
            s.cache.armed = Some((deadline, timer));
        }
    }
    Ok(())
}
