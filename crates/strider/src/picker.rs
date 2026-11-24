//! The picker: a query typed in the command line over the best of many candidates, for files
//! and folders below the current folder (gf, :fuzzy) and the folders zoxide knows (gz, :zi).
//! Candidates arrive in batches from a worker thread (a breadth-first walk, or `zoxide
//! query`), so the first results show while a big tree is still being read; each keystroke
//! scores them again, narrowing the last result when the query only grew.
//!
//! zoxide also hears of each folder shown, and `:z words` jumps to its best match.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use keywork::TextSpan;
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, TextKind};
use strider_core::fuzzy::{self, Match, Paths, Walk};
use strider_machines::mode::Prompt;

use crate::app::{self, Strider};
use crate::prompt;

/// Rows the panel shows at once.
pub const ROWS: usize = 10;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Files,
    Folders,
}

pub struct Picker {
    pub kind: Kind,
    /// The folder files are found below.
    pub(crate) root: PathBuf,
    pub(crate) paths: Paths,
    /// What the query matches, best first, and the buffer narrowing swaps in.
    pub(crate) matches: Vec<Match>,
    spare: Vec<Match>,
    query: String,
    pub(crate) selected: usize,
    /// The worker is still reading candidates.
    loading: bool,
    /// Which opening deliveries belong to.
    generation: u64,
    cancel: Arc<AtomicBool>,
}

impl Default for Picker {
    fn default() -> Self {
        Picker {
            kind: Kind::Files,
            root: PathBuf::new(),
            paths: Paths::default(),
            matches: Vec::new(),
            spare: Vec::new(),
            query: String::new(),
            selected: 0,
            loading: false,
            generation: 0,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl Picker {
    /// The command line's label while the picker is open.
    pub fn label(&self) -> &'static str {
        match self.kind {
            Kind::Files => "files:",
            Kind::Folders => "zoxide:",
        }
    }

    pub fn name(&self) -> &'static str {
        match self.kind {
            Kind::Files => "Find a file or folder",
            Kind::Folders => "Jump to a folder",
        }
    }

    /// The selected result as an absolute path, a folder's ending in `/`.
    pub fn chosen(&self) -> Option<String> {
        let m = self.matches.get(self.selected)?;
        let rel = String::from_utf8_lossy(self.paths.get(m.index));
        Some(match self.kind {
            Kind::Files => format!("{}/{rel}", self.root.display()).replacen("//", "/", 1),
            Kind::Folders => format!("{rel}/"),
        })
    }

    /// Stops the worker reading candidates, as its window closes.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }

    fn stop(&mut self) {
        self.generation += 1;
        self.cancel.store(true, Ordering::Release);
        self.loading = false;
    }

    fn filter(&mut self, narrow: bool) {
        if narrow {
            std::mem::swap(&mut self.matches, &mut self.spare);
            fuzzy::filter(
                &self.paths,
                Some(&self.spare),
                self.query.as_bytes(),
                &mut self.matches,
            );
        } else {
            fuzzy::filter(&self.paths, None, self.query.as_bytes(), &mut self.matches);
        }
    }
}

/// Opens the picker for `kind` and starts reading candidates, with `query` typed.
pub fn start(s: &mut Strider, tx: &mut Txn<'_, Strider>, kind: Kind, query: &str) -> Result<()> {
    if s.prompt().is_some() {
        app::send_mode(s, tx, strider_machines::mode::ModeEv::Cancel)?;
    }
    let root = s.cwd.clone();
    let p = &mut s.picker;
    p.stop();
    *p = Picker {
        kind,
        root,
        generation: p.generation + 1,
        loading: true,
        ..Picker::default()
    };
    prompt::start(s, tx, Prompt::Pick, query, query.len(), query.len())?;
    set_query(s, tx, query)?;
    read(s, tx)
}

/// Reads the candidates on a worker thread, handing them over in batches; scenes read them
/// at once.
fn read(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let p = &s.picker;
    let (kind, root, hidden, generation) =
        (p.kind, p.root.clone(), s.options.show_hidden, p.generation);
    let zoxide = s.zoxide.clone().unwrap_or_else(|| "zoxide".into());
    let cancel = p.cancel.clone();
    if s.sync_reads {
        let mut batches = Vec::new();
        source(kind, &root, &zoxide, hidden, &cancel, |b, done| {
            batches.push((b, done));
        });
        for (b, done) in batches {
            deliver(s, tx, generation, b, done)?;
        }
        return Ok(());
    }
    let proxy = tx.proxy()?;
    let window = s.window;
    std::thread::spawn(move || {
        source(kind, &root, &zoxide, hidden, &cancel, |batch, done| {
            let _ = proxy.post(move |s: &mut Strider, cx| {
                app::in_window(s, cx, Some(window), |s, tx| {
                    deliver(s, tx, generation, batch, done)
                })
            });
        });
    });
    Ok(())
}

/// On the worker: the files below `root`, or zoxide's folders, in batches.
fn source(
    kind: Kind,
    root: &Path,
    zoxide: &Path,
    hidden: bool,
    cancel: &AtomicBool,
    mut sink: impl FnMut(Paths, bool),
) {
    match kind {
        Kind::Files => Walk {
            root,
            hidden,
            limit: 200_000,
            cancel,
            batch_size: 4096,
        }
        .run(sink),
        Kind::Folders => {
            let mut batch = Paths::default();
            // zoxide leaves out the folder it is asked from.
            let (zoxide, root) = (zoxide.to_string_lossy(), root.to_string_lossy());
            let argv = [&*zoxide, "query", "--list", "--exclude", &root];
            if let Some((0, out)) = run(&argv, Duration::from_secs(10), Some(cancel)) {
                for line in out.lines().filter(|l| !l.is_empty()) {
                    batch.push(line.as_bytes());
                }
            }
            sink(batch, true);
        }
    }
}

fn deliver(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    generation: u64,
    mut batch: Paths,
    done: bool,
) -> Result<()> {
    if s.picker.generation != generation || s.prompt() != Some(Prompt::Pick) {
        return Ok(());
    }
    let p = &mut s.picker;
    p.paths.append(&mut batch);
    if done {
        p.loading = false;
    }
    p.filter(false);
    p.selected = p.selected.min(p.matches.len().saturating_sub(1));
    draw(s, tx)
}

/// The query changed: narrows the last result when it only grew.
pub fn set_query(s: &mut Strider, tx: &mut Txn<'_, Strider>, q: &str) -> Result<()> {
    let p = &mut s.picker;
    let grew = !p.query.is_empty() && q.starts_with(&p.query);
    p.query = q.to_owned();
    p.filter(grew);
    p.selected = 0;
    draw(s, tx)
}

pub fn move_by(s: &mut Strider, tx: &mut Txn<'_, Strider>, delta: isize) -> Result<()> {
    let p = &mut s.picker;
    if p.matches.is_empty() {
        return Ok(());
    }
    p.selected = p
        .selected
        .saturating_add_signed(delta)
        .min(p.matches.len() - 1);
    draw(s, tx)
}

/// Stops reading and hides the panel.
pub fn close(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.picker.stop();
    tx.set_hidden(s.ui.picker, true)
}

/// Enter: a folder opens; a file shows in its folder.
pub fn submit(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(path) = s.picker.chosen() else {
        return Ok(());
    };
    match path.strip_suffix('/') {
        Some(dir) => app::cd(s, tx, PathBuf::from(dir), None, true),
        None => {
            let path = PathBuf::from(path);
            let name = path.file_name().map(|n| n.as_encoded_bytes().to_vec());
            let dir = path.parent().unwrap_or(Path::new("/")).to_owned();
            app::cd(s, tx, dir, name.as_deref(), true)
        }
    }
}

/// The panel: how many match, then a window of rows that keeps the selection in view, the
/// matched characters standing out.
fn draw(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let p = &s.picker;
    let panel = s.ui.picker;
    let old: Vec<_> = tx.children(panel)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    tx.set_hidden(panel, false)?;
    let what = match p.kind {
        Kind::Files => "files and folders",
        Kind::Folders => "folders zoxide knows",
    };
    let head = format!(
        "{} of {} {what}{}",
        p.matches.len(),
        p.paths.len(),
        if p.loading { " (reading…)" } else { "" }
    );
    widgets::label(tx, panel, head, TextKind::Small)?;
    if p.matches.is_empty() {
        let none = if p.loading {
            "Reading…"
        } else if p.kind == Kind::Folders && p.paths.is_empty() {
            "zoxide knows no folders yet"
        } else {
            "Nothing matches"
        };
        widgets::label(tx, panel, none, TextKind::Muted)?;
        return Ok(());
    }
    let top = (p.selected + 1).saturating_sub(ROWS);
    let end = p.matches.len().min(top + ROWS);
    for (i, m) in p.matches[top..end].iter().enumerate() {
        let i = top + i;
        let bytes = p.paths.get(m.index);
        let text = String::from_utf8_lossy(bytes);
        let selected = i == p.selected;
        let row = tx.flex(
            panel,
            Flex::row()
                .width(Dim::Fill)
                .padding(Insets::new(2.0, 6.0, 2.0, 6.0)),
        )?;
        tx.set_radius(row, 4.0)?;
        if selected {
            tx.set_background(row, Paint::Role(ColorRole::Selection))?;
        }
        let t = widgets::label(tx, row, &*text, TextKind::Body)?;
        tx.update_style(t, |st| st.max_lines = 1)?;
        let dir = text.ends_with('/') || p.kind == Kind::Folders;
        if dir {
            tx.set_color(t, Paint::Role(ColorRole::AccentText))?;
        }
        let mut pos = Vec::new();
        fuzzy::score(bytes, p.query.as_bytes(), Some(&mut pos));
        // Positions are bytes; the text shown replaced invalid UTF-8, so only valid names
        // get them.
        if std::str::from_utf8(bytes).is_ok() {
            let spans: Vec<_> = pos
                .iter()
                .map(|&at| {
                    let end = at + text[at..].chars().next().map_or(1, char::len_utf8);
                    TextSpan::new(at..end)
                        .color(Paint::Role(ColorRole::AccentText))
                        .weight(700.0)
                })
                .collect();
            tx.set_text_spans(t, &spans)?;
        }
    }
    Ok(())
}

// zoxide -------------------------------------------------------------------------------------

/// Where zoxide is on the PATH, if it is.
pub fn find_zoxide() -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|d| d.join("zoxide"))
        .find(|p| p.is_file())
}

/// Tells zoxide a folder was shown, on a worker, once per folder in a row.
pub fn zoxide_add(s: &mut Strider, tx: &mut Txn<'_, Strider>) {
    let Some(zoxide) = s.zoxide.clone() else {
        return;
    };
    if s.zoxide_last == s.cwd || s.sync_reads {
        return;
    }
    s.zoxide_last = s.cwd.clone();
    let path = s.cwd.to_string_lossy().into_owned();
    tx.spawn_blocking(
        move || {
            let zoxide = zoxide.to_string_lossy();
            run(
                &[&zoxide, "add", "--", &path],
                Duration::from_secs(10),
                None,
            )
        },
        |_: &mut Strider, _, _| Ok(()),
    );
}

/// `:z words`: zoxide's best folder for them; without words, the picker of its folders.
pub fn jump(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    let Some(zoxide) = s.zoxide.clone() else {
        s.notify(
            "zoxide is not installed (it is in most distributions' packages)",
            true,
        );
        return app::draw_status(s, tx);
    };
    if args.is_empty() {
        return start(s, tx, Kind::Folders, "");
    }
    let mut argv = vec![zoxide.to_string_lossy().into_owned()];
    argv.extend(["query", "--exclude"].map(str::to_owned));
    argv.push(s.cwd.to_string_lossy().into_owned());
    argv.push("--".into());
    argv.extend(args.split(' ').filter(|w| !w.is_empty()).map(str::to_owned));
    tx.spawn_blocking(
        move || {
            let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
            run(&argv, Duration::from_secs(10), None)
        },
        app::here(
            |s: &mut Strider, tx, out: Option<(i32, String)>| match out {
                Some((0, path)) if !path.trim().is_empty() => {
                    app::cd(s, tx, PathBuf::from(path.trim()), None, true)
                }
                _ => {
                    s.notify("zoxide knows no folder for that", true);
                    app::draw_status(s, tx)
                }
            },
        ),
    );
    Ok(())
}

/// Runs `argv`, killed after `timeout` or once `cancel` is set, and returns its exit status
/// and what it printed.
fn run(argv: &[&str], timeout: Duration, cancel: Option<&AtomicBool>) -> Option<(i32, String)> {
    let mut child = Command::new(argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut out = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut buf = String::new();
        let _ = std::io::Read::read_to_string(&mut out, &mut buf);
        buf
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait().ok()? {
            break status;
        }
        if Instant::now() > deadline || cancel.is_some_and(|c| c.load(Ordering::Acquire)) {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    Some((status.code().unwrap_or(-1), reader.join().ok()?))
}
