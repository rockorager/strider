//! The window's file operations: jobs started, their updates taken on the UI thread, their
//! conflicts asked about, and what is done when one finishes (recorded for undo, the folders
//! it touched read again, what it brought here selected, its summary in the status line); and
//! the tasks view (`w`), which lists the running ones and the last finished ones, with keys of
//! its own in mode Tasks.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::time::Duration;

use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, TextKind};
use keywork::{Error, Timer};
use strider_core::fsops::{Conflict, Finished, Kind, Resolution};
use strider_core::keys::{self, Key};
use strider_core::{model, undo};
use strider_machines::keymap::{KeyEv, Question};
use strider_machines::mode::{self, ModeEv};

use crate::app::{self, Clock, Strider};
use crate::ops::{Job, Request, State, Update};

/// How many finished operations the tasks view keeps.
pub const MAX_RECENT: usize = 20;

/// A job running, and whether to record it for undo (not when it is an undo itself).
pub struct Running {
    pub id: u64,
    pub job: Job,
    pub undoable: bool,
}

/// A finished operation, as the tasks view lists it.
pub struct Recent {
    pub title: String,
    /// What came of it, as the status line said.
    pub result: String,
    pub failed: bool,
    pub canceled: bool,
}

/// What the window keeps for file operations.
#[derive(Default)]
pub struct Ops {
    /// What yy and dd took, and whether pasting moves them.
    pub register: Vec<PathBuf>,
    pub cut: bool,
    pub undo: undo::Stack,
    /// Running, in the order they started.
    pub jobs: Vec<Running>,
    /// Finished, newest first.
    pub recent: Vec<Recent>,
    next_id: u64,
    /// The timer that reads progress while jobs run.
    timer: Option<Timer>,
    /// The tasks view, made the first time it opens, and the row it selects.
    panel: Option<(NodeId<Flex>, NodeId<Flex>)>,
    pub task_cursor: usize,
    /// Conflicts to ask about, by the job that found each; the first is being asked.
    pub asks: VecDeque<(u64, Conflict)>,
    /// The visual operator, y or d, that just acted, whose second key finishes it.
    pub visual_op: Option<u32>,
    /// The dialog open over the window.
    pub dialog: Option<crate::dialogs::Dialog>,
    /// The entry the rename prompt renames.
    pub rename_target: Option<PathBuf>,
    /// Holds the app's exit while cancelled jobs clean up.
    quit_hold: Option<keywork::QuitHold>,
}

/// Runs `request` on a thread of its own, its progress in the status line and the tasks view.
pub fn start(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    request: Request,
    undoable: bool,
) -> Result<()> {
    let proxy = tx.proxy().ok().map(std::sync::Mutex::new);
    let job = Job::start(request, move || {
        let Some(p) = &proxy else { return };
        let p = p.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = p.post(|s: &mut Strider, cx| {
            let window = s.window;
            cx.update(window, |tx| receive(s, tx))
        });
    });
    s.ops.next_id += 1;
    let id = s.ops.next_id;
    s.ops.jobs.push(Running { id, job, undoable });
    arm(s, tx);
    update(s, tx)
}

/// Reads progress every 100 ms while jobs run, as the Zig build did, and takes updates a wake
/// may not have brought, as before the app runs.
fn arm(s: &mut Strider, tx: &mut Txn<'_, Strider>) {
    if s.ops.timer.is_some() {
        return;
    }
    s.ops.timer = Some(tx.after(Duration::from_millis(100), |s: &mut Strider, cx| {
        s.ops.timer = None;
        let window = s.window;
        cx.update(window, |tx| {
            receive(s, tx)?;
            if !s.ops.jobs.is_empty() {
                arm(s, tx);
            }
            update(s, tx)
        })
    }));
}

/// Stops every job, as the window closes.
pub fn cancel_all(s: &Strider) {
    for r in &s.ops.jobs {
        r.job.cancel();
    }
}

/// The app is about to exit: every job stops, and the exit waits up to a second for them to
/// remove the files they were writing.
pub fn quit(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    if !s.ops.jobs.is_empty() {
        cancel_all(s);
        s.ops.quit_hold = Some(cx.hold_quit(Duration::from_secs(1)));
    }
    Ok(())
}

/// Takes the jobs' updates: a conflict is asked about, a finished job is done with.
pub fn receive(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let jobs: Vec<(u64, Job)> = s.ops.jobs.iter().map(|r| (r.id, r.job.clone())).collect();
    for (id, job) in jobs {
        for u in job.receive() {
            match u {
                Update::Changed => {}
                Update::Ask(c) => {
                    s.ops.asks.push_back((id, c));
                    if s.ops.asks.len() == 1 {
                        ask_next(s, tx)?;
                    }
                }
                Update::Finished(f) => finish(s, tx, id, f)?,
            }
        }
    }
    update(s, tx)
}

/// Draws what shows the jobs: the status line, and the tasks view while it is open.
pub fn update(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    app::draw_status(s, tx)?;
    refresh(s, tx)
}

fn job(s: &Strider, id: u64) -> Option<&Job> {
    s.ops.jobs.iter().find(|r| r.id == id).map(|r| &r.job)
}

// Conflicts -----------------------------------------------------------------------------------

/// Asks about the first conflict waiting: a quick question in the status line for a single
/// file, a dialog comparing the two when there are more items, folders included.
fn ask_next(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some((id, c)) = s.ops.asks.front().cloned() else {
        return Ok(());
    };
    let Some(request) = job(s, id).map(|j| j.request().clone()) else {
        s.ops.asks.pop_front();
        return ask_next(s, tx);
    };
    if request.sources.len() > 1 || c.src_dir {
        return crate::dialogs::conflict(s, tx, &request, &c);
    }
    crate::bookmarks::ask(s, tx, Question::Conflict)
}

/// What the status line asks about a single file's conflict.
pub fn question(s: &Strider) -> String {
    let Some((_, c)) = s.ops.asks.front() else {
        return String::new();
    };
    format!(
        "“{}” exists: (r)eplace (s)kip (k)eep both{} (c)ancel — Shift for all",
        String::from_utf8_lossy(model::basename(&c.dst)),
        if c.src_dir && c.dst_dir {
            " (m)erge"
        } else {
            ""
        }
    )
}

/// Answers the conflict being asked about, for every later one too with `all`, and asks the
/// next.
pub fn answer(s: &mut Strider, tx: &mut Txn<'_, Strider>, r: Resolution, all: bool) -> Result<()> {
    if let Some((id, _)) = s.ops.asks.pop_front()
        && let Some(j) = job(s, id)
    {
        j.answer(r, all);
    }
    ask_next(s, tx)?;
    update(s, tx)
}

/// The key that answers a single file's conflict: r, s, k, m (two folders), or c, and
/// Shift for every later conflict; Escape cancels. Another key asks again.
pub fn answer_key(s: &mut Strider, tx: &mut Txn<'_, Strider>, key: Key) -> Result<()> {
    let Some((_, c)) = s.ops.asks.front().cloned() else {
        return app::draw_status(s, tx);
    };
    let ch = key
        .is_char()
        .then(|| char::from_u32(key.code))
        .flatten()
        .filter(char::is_ascii);
    let all = ch.is_some_and(|c| c.is_ascii_uppercase());
    let r = match ch.map(|c| c.to_ascii_lowercase()) {
        Some('r') => Some(Resolution::Replace),
        Some('s') => Some(Resolution::Skip),
        Some('k') => Some(Resolution::KeepBoth),
        Some('m') if c.src_dir && c.dst_dir => Some(Resolution::Merge),
        Some('c') => Some(Resolution::Cancel),
        _ if key.code == keys::sym::ESCAPE => Some(Resolution::Cancel),
        _ => None,
    };
    match r {
        Some(r) => answer(s, tx, r, all),
        None => crate::bookmarks::ask(s, tx, Question::Conflict),
    }
}

// Finishing -----------------------------------------------------------------------------------

/// A job ended: it goes to the tasks view's finished ones, onto the undo stack if it was
/// started as undoable and not cancelled, its summary to the status line, the cursor onto what
/// a paste brought here, and the folders it touched are read again.
fn finish(s: &mut Strider, tx: &mut Txn<'_, Strider>, id: u64, f: Finished) -> Result<()> {
    let Some(at) = s.ops.jobs.iter().position(|r| r.id == id) else {
        return Ok(());
    };
    let r = s.ops.jobs.remove(at);
    if s.ops.jobs.is_empty() {
        s.ops.quit_hold = None;
    }
    let was_asking = s.ops.asks.front().is_some_and(|(j, _)| *j == id);
    s.ops.asks.retain(|(j, _)| *j != id);
    if was_asking {
        crate::dialogs::dismiss_conflict(s, tx)?;
        if s.keys.context().question == Some(Question::Conflict) {
            let fx = s.keys.send(KeyEv::Reset, Clock { tx });
            app::apply_key_fx(s, tx, fx)?;
        }
        ask_next(s, tx)?;
    }
    let (msg, failed) = f.summary();
    let canceled = f.canceled();
    if s.ops.recent.len() >= MAX_RECENT {
        s.ops.recent.pop();
    }
    s.ops.recent.insert(
        0,
        Recent {
            title: r.job.request().title(),
            result: if msg.is_empty() {
                "Done".into()
            } else {
                msg.clone()
            },
            failed,
            canceled,
        },
    );
    if r.undoable && !canceled {
        s.ops.undo.push_op(f.kind, &f.done);
    }
    // A cut is pasted once.
    if f.kind == Kind::Move && s.ops.cut {
        crate::register::set(s, tx, Vec::new(), false)?;
    }
    if !msg.is_empty() {
        s.notify(msg, failed);
    }
    if f.error.is_none()
        && matches!(f.kind, Kind::Copy | Kind::Move)
        && f.dest == s.cwd
        && let Some(first) = f.created.first().cloned()
    {
        s.cur_mut().focus(&first);
    }
    // Folders the operation touched read again now.
    let mut touched: Vec<PathBuf> = Vec::new();
    if !f.dest.as_os_str().is_empty() {
        touched.push(f.dest.clone());
    }
    for p in f.sources.iter().chain(&f.targets) {
        touched.push(model::parent(p).to_owned());
    }
    if matches!(f.kind, Kind::Trash | Kind::Restore | Kind::Delete) {
        touched.push(crate::register::home_trash(s).join("files"));
    }
    touched.sort();
    touched.dedup();
    for p in &touched {
        crate::cache::invalidate(s, tx, p)?;
    }
    update(s, tx)
}

// The status line -----------------------------------------------------------------------------

/// The first job's progress, for the status line's right: "Copying 45%", "Moving: waiting".
pub fn progress_text(s: &Strider) -> Option<String> {
    let job = &s.ops.jobs.first()?.job;
    let verb = job.request().kind.doing();
    let p = job.progress();
    let by_bytes = (p.bytes_done * 100).checked_div(p.bytes_total);
    let by_items = (p.items_done * 100)
        .checked_div(p.items_total)
        .filter(|_| job.state() != State::Counting);
    Some(if job.is_paused() {
        format!("{verb}: paused")
    } else if job.state() == State::Asking {
        format!("{verb}: waiting")
    } else if let Some(pct) = by_bytes {
        format!("{verb} {pct}%")
    } else if let Some(pct) = by_items {
        format!("{verb} {}%", pct.min(100))
    } else {
        format!("{verb}…")
    })
}

/// The selected task, for the status line's left while the tasks view is open.
pub fn selected_text(s: &Strider) -> String {
    match task_at(s, s.ops.task_cursor) {
        Some(Task::Running(r)) => format!("{}: {}", r.job.request().title(), r.job.status()),
        Some(Task::Finished(f)) => format!("{}: {}", f.title, f.result),
        None => "No file operations yet".into(),
    }
}

// The tasks view ------------------------------------------------------------------------------

/// A row of the tasks view: running operations first, in the order they started, then
/// finished ones, newest first.
pub enum Task<'a> {
    Running(&'a Running),
    Finished(&'a Recent),
}

pub fn task_count(s: &Strider) -> usize {
    s.ops.jobs.len() + s.ops.recent.len()
}

pub fn task_at(s: &Strider, i: usize) -> Option<Task<'_>> {
    match s.ops.jobs.get(i) {
        Some(r) => Some(Task::Running(r)),
        None => s.ops.recent.get(i - s.ops.jobs.len()).map(Task::Finished),
    }
}

pub fn is_open(s: &Strider) -> bool {
    s.mode.matches(mode::mode::states::selection::TASKS)
}

/// `tasks`: opens the view, or closes it.
pub fn toggle(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if is_open(s) {
        app::send_mode(s, tx, ModeEv::CloseTasks)?;
        if let Some((overlay, card)) = s.ops.panel {
            tx.set_hidden(overlay, true)?;
            clear(tx, card)?;
        }
        return app::draw_status(s, tx);
    }
    app::send_mode(s, tx, ModeEv::OpenTasks)?;
    s.ops.task_cursor = 0;
    let (overlay, _) = panel(s, tx)?;
    tx.set_hidden(overlay, false)?;
    update(s, tx)
}

/// The view's card, over the middle of the columns, made the first time.
fn panel(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<(NodeId<Flex>, NodeId<Flex>)> {
    if let Some(p) = s.ops.panel {
        return Ok(p);
    }
    let root = tx
        .parent(s.ui.which_key)?
        .ok_or(Error::Other("the which-key popup is in the window"))?;
    let root = tx.downcast::<Stack>(root)?;
    let overlay = tx.flex(
        root,
        Flex::column()
            .width(Dim::Fill)
            .height(Dim::Fill)
            .align(keywork::Align::Center)
            .justify(keywork::tree::Justify::Center),
    )?;
    let card = widgets::surface(
        tx,
        overlay,
        Flex::column()
            .gap(6.0)
            .width(Dim::Fill)
            .padding(Insets::new(12.0, 16.0, 12.0, 16.0)),
        widgets::SurfaceKind::Card,
    )?;
    tx.update_style(card, |st| st.max_width = 720.0)?;
    tx.set_radius(card, 8.0)?;
    tx.set_label(card, "Tasks")?;
    tx.set_hidden(overlay, true)?;
    s.ops.panel = Some((overlay, card));
    Ok((overlay, card))
}

fn clear(tx: &mut Txn<'_, Strider>, node: NodeId<Flex>) -> Result<()> {
    let old: Vec<_> = tx.children(node)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    Ok(())
}

fn text(
    tx: &mut Txn<'_, Strider>,
    parent: NodeId<Flex>,
    t: &str,
    kind: TextKind,
    role: ColorRole,
) -> Result<NodeId<Text>> {
    let n = widgets::label(tx, parent, t, kind)?;
    tx.set_color(n, Paint::Role(role))?;
    tx.update_style(n, |st| st.max_lines = 1)?;
    Ok(n)
}

/// Builds the view's rows again while it is open: each running task's title, state,
/// progress, and current file; each finished one's title and what came of it.
fn refresh(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if !is_open(s) {
        return Ok(());
    }
    let n = task_count(s);
    s.ops.task_cursor = s.ops.task_cursor.min(n.saturating_sub(1));
    let (_, card) = panel(s, tx)?;
    clear(tx, card)?;
    let head = widgets::label(tx, card, "Tasks", TextKind::Heading)?;
    tx.update_style(head, |st| st.font_weight = 700.0)?;
    if n == 0 {
        text(
            tx,
            card,
            "No file operations yet: copies, moves, and deletes show here.",
            TextKind::Body,
            ColorRole::TextMuted,
        )?;
    }
    for i in 0..n {
        let selected = i == s.ops.task_cursor;
        let task = task_at(s, i).expect("in range");
        let title = match &task {
            Task::Running(r) => r.job.request().title(),
            Task::Finished(f) => f.title.clone(),
        };
        let row = tx.flex(
            card,
            Flex::column()
                .gap(4.0)
                .width(Dim::Fill)
                .padding(Insets::new(6.0, 10.0, 6.0, 10.0)),
        )?;
        tx.set_radius(row, 6.0)?;
        if selected {
            tx.set_background(row, Paint::Role(ColorRole::Selection))?;
        }
        tx.set_label(row, &title)?;
        let line = tx.flex(
            row,
            Flex::row()
                .gap(12.0)
                .width(Dim::Fill)
                .align(keywork::Align::Center),
        )?;
        let t = text(tx, line, &title, TextKind::Body, ColorRole::Text)?;
        tx.update_style(t, |st| {
            st.font_weight = 700.0;
            st.grow = 1.0;
            st.basis = Some(Dim::Px(0.0));
            st.min_width = 0.0;
        })?;
        let muted = if selected {
            ColorRole::Text
        } else {
            ColorRole::TextMuted
        };
        match task {
            Task::Running(r) => {
                let job = &r.job;
                let paused = job.is_paused();
                let st = text(
                    tx,
                    line,
                    &job.status(),
                    TextKind::Small,
                    if paused {
                        ColorRole::WarningText
                    } else {
                        ColorRole::AccentText
                    },
                )?;
                tx.update_style(st, |st| st.shrink = 0.0)?;
                let p = job.progress();
                widgets::progress(tx, row, &title, Some(p.percent() as f32 / 100.0))?;
                let mut detail = String::new();
                if p.bytes_total > 0 {
                    detail += &format!(
                        "{} of {}   ",
                        model::format_size(p.bytes_done),
                        model::format_size(p.bytes_total)
                    );
                }
                if p.items_total > 0 {
                    detail += &format!("{} of {} items   ", p.items_done, p.items_total);
                }
                detail += &p.current;
                text(tx, row, &detail, TextKind::Small, muted)?;
            }
            Task::Finished(f) => {
                let label = if f.failed {
                    "Failed"
                } else if f.canceled {
                    "Canceled"
                } else {
                    "Done"
                };
                let role = if f.failed {
                    ColorRole::DangerText
                } else {
                    ColorRole::TextMuted
                };
                let st = text(tx, line, label, TextKind::Small, role)?;
                tx.update_style(st, |st| st.shrink = 0.0)?;
                let role = if f.failed {
                    ColorRole::DangerText
                } else {
                    muted
                };
                text(tx, row, &f.result, TextKind::Small, role)?;
            }
        }
    }
    let hint = text(
        tx,
        card,
        "j k move   p pause or resume   x cancel, or remove a finished task   Esc close",
        TextKind::Small,
        ColorRole::TextMuted,
    )?;
    tx.update_style(hint, |st| st.padding = Insets::new(4.0, 0.0, 0.0, 0.0))
}

/// `task-down` and `task-up`.
pub fn move_cursor(s: &mut Strider, tx: &mut Txn<'_, Strider>, delta: isize) -> Result<()> {
    let n = task_count(s);
    if n == 0 {
        return Ok(());
    }
    s.ops.task_cursor = s.ops.task_cursor.saturating_add_signed(delta).min(n - 1);
    update(s, tx)
}

/// The task the view selects; with the view closed, the first running.
fn selected(s: &Strider) -> usize {
    if is_open(s) { s.ops.task_cursor } else { 0 }
}

/// `task-pause`: pauses the task, or resumes it.
pub fn pause(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    match task_at(s, selected(s)) {
        None => s.notify("No task is running", false),
        Some(Task::Finished(_)) => s.notify("That task is done", false),
        Some(Task::Running(r)) => {
            if r.job.is_paused() {
                r.job.resume();
            } else {
                r.job.pause();
            }
        }
    }
    update(s, tx)
}

/// `task-cancel`: cancels the task, or in the view takes a finished one off the list.
pub fn cancel(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let at = selected(s);
    match task_at(s, at) {
        None => s.notify("No task is running", false),
        Some(Task::Running(r)) => r.job.cancel(),
        Some(Task::Finished(_)) => {
            if is_open(s) {
                let k = at - s.ops.jobs.len();
                s.ops.recent.remove(k);
            }
        }
    }
    update(s, tx)
}
