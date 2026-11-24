//! Drag and drop, as the Zig build's Dnd: what a drag from the current column carries, and
//! how each folder under the pointer takes it.
//!
//! A drag starts from a row of the current column with what commands act on (the visual
//! range, the marks, or the row), and a card of the file's icon and name ("3 items" for
//! several) under the pointer. Any folder takes it: a folder's row in any column, a column's
//! empty space or a file's row (its folder), a folder of the header path, or a tab (its
//! folder). The target under the pointer is outlined, the status line says "Move 3 items to
//! src", and the drop runs as a file operation, so conflicts, progress, and undo work as for
//! p. Within one filesystem a drop moves, across filesystems it copies; Shift moves, Ctrl
//! copies, Ctrl+Shift links. The folder the items are in, the items themselves, and folders
//! that cannot be written take nothing. Resting on a folder's row or a tab opens it, so a
//! drop can go deeper; resting near a column's top or bottom scrolls it (the
//! [`hover`](strider_machines::dnd) statechart). Escape gives the drag up. Files dragged in
//! from other applications, as `text/uri-list` or `x-special/gnome-copied-files`, are copied,
//! or moved when the drop asks to move.
//!
//! What the app drags is shared, so another of its windows knows; each window keeps the
//! target it outlines and its timers.

use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use keywork::app::dnd::{DndActions, DragData, DragIcon};
use keywork::input::BTN_LEFT;
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, TextKind};
use keywork::{Error, Timer};
use plusthree::host::{Scheduler, TimerToken};
use strider_core::fsops::Kind;
use strider_core::{model, uri};
use strider_machines::dnd::{DropEv, DropFx, Hover};
use strider_machines::driver::Driver;

use crate::app::{self, Col, Strider};
use crate::ops::Request;

pub const URI_LIST: &str = "text/uri-list";
pub const GNOME_COPIED: &str = "x-special/gnome-copied-files";

/// Where the pointer is on the drag's card, as the Zig build had it.
const HOTSPOT: f32 = 14.0;
/// How near a column's top or bottom a drag scrolls it.
const EDGE: f32 = 24.0;
/// How long the card shows in the window before it is the drag's icon, so a frame has drawn
/// it: Keywork's drag icon of a node is what the last frame drew there.
const CARD_FRAME: Duration = Duration::from_millis(40);

/// What a drop does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Move,
    Copy,
    Link,
}

impl Action {
    pub fn word(self) -> &'static str {
        match self {
            Action::Move => "Move",
            Action::Copy => "Copy",
            Action::Link => "Link",
        }
    }

    fn kind(self) -> Kind {
        match self {
            Action::Move => Kind::Move,
            Action::Copy => Kind::Copy,
            Action::Link => Kind::Link,
        }
    }
}

/// The app's own drag, from one window.
pub struct Source {
    pub window: WindowId,
    pub paths: Vec<PathBuf>,
    /// The folder they are in, and its filesystem.
    dir: PathBuf,
    dev: Option<u64>,
    /// Escape gave it up: Keywork cannot take the compositor's drag back, so it goes on to
    /// its end, and the app's windows take nothing of it.
    cancelled: bool,
}

/// What the windows share: the app's drag, and the modifiers last seen held, which pick what
/// a drop does.
#[derive(Default)]
pub struct Dragged {
    pub source: Option<Source>,
    pub ctrl: bool,
    pub shift: bool,
}

/// A node that takes drops.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    /// A folder's row: its column, and its position there.
    Row(Col, usize),
    /// A column's empty space, or a file's row: the folder it shows.
    Column(Col),
    /// A folder of the header path, by its place among the links.
    Crumb(usize),
    /// A tab, by index.
    Tab(usize),
}

/// What each window keeps: the target outlined, the folder it stands for, and the hint.
pub struct Dnd {
    chart: Driver<Hover, Timer>,
    pub over: Option<Target>,
    outlined: Option<Target>,
    dest: PathBuf,
    dest_dev: Option<u64>,
    takes: bool,
    /// What the status line says while a drag rests on a target.
    pub hint: String,
    /// Where a column's scrolling is, by row.
    scroll_row: usize,
    /// The timer that starts the drag once the card is drawn.
    pending: Option<Timer>,
    /// The card while it shows, with the action it says.
    card: Option<Option<Action>>,
}

impl Dnd {
    pub fn new() -> Dnd {
        Dnd {
            chart: Driver::new(Hover::machine(), ()),
            over: None,
            outlined: None,
            dest: PathBuf::new(),
            dest_dev: None,
            takes: false,
            hint: String::new(),
            scroll_row: 0,
            pending: None,
            card: None,
        }
    }
}

/// A window's nodes for drags: a ring over each column, and the card a drag shows.
#[derive(Clone, Copy)]
pub struct Nodes {
    rings: [NodeId<Flex>; 3],
    pub card: NodeId<Flex>,
    card_icon: NodeId<keywork::Canvas>,
    card_label: NodeId<Text>,
    card_badge: NodeId<Text>,
}

/// Whether the app is dragging, and has not given the drag up.
#[cfg(test)]
pub fn dragging(s: &Strider) -> bool {
    s.dragged.source.as_ref().is_some_and(|d| !d.cancelled)
}

/// The rings, the card, and the columns' handlers, as the window is built.
pub fn build(
    tx: &mut Txn<'_, Strider>,
    panes: &[NodeId<Stack>],
    lists: &[NodeId<keywork::kind::Box>],
) -> Result<Nodes> {
    let mut rings = Vec::new();
    for &pane in panes {
        // Over the column while a drop would go into its folder.
        let ring = tx.flex(pane, Style::new().width(Dim::Fill).height(Dim::Fill))?;
        tx.set_pass_through(ring, true)?;
        tx.set_hidden(ring, true)?;
        rings.push(ring);
    }
    for (col, &list) in [Col::Parent, Col::Current, Col::Preview]
        .into_iter()
        .zip(lists)
    {
        app::on(tx, list, DragOver, move |s: &mut Strider, tx, ev| {
            let Some((target, dest)) = list_target(s, tx, col, ev.target)? else {
                return Err(Error::Pass);
            };
            over(s, tx, ev, target, dest)?;
            tx.set_drop_target(s.ui.panes[col as usize]);
            Ok(())
        })?;
        app::on(tx, list, DragLeave, move |s: &mut Strider, tx, _| {
            if matches!(s.dnd.over, Some(Target::Row(c, _) | Target::Column(c)) if c == col) {
                leave(s, tx)?;
            }
            Ok(())
        })?;
        app::on(tx, list, DragDrop, move |s: &mut Strider, tx, ev| {
            let Some((_, dest)) = list_target(s, tx, col, ev.target)? else {
                return Ok(());
            };
            dropped(s, tx, ev, dest)
        })?;
    }
    let current = lists[Col::Current as usize];
    app::on(tx, current, DragStart, move |s: &mut Strider, tx, ev| {
        let EventData::DragStart {
            button,
            position,
            modifiers,
            ..
        } = ev.data
        else {
            return Err(Error::Pass);
        };
        if button != BTN_LEFT || widgets::row_item(tx, ev.target)?.is_none() {
            return Err(Error::Pass);
        }
        s.dragged.ctrl = modifiers.contains(Modifiers::CTRL);
        s.dragged.shift = modifiers.contains(Modifiers::SHIFT);
        start(s, tx, position)
    })?;
    app::on(tx, current, DragEnd, |s: &mut Strider, tx, _| end(s, tx))?;
    let root = tx.root();
    // Without a compositor the drag never starts, and a release ends it.
    app::on(tx, root, PointerUp, |s: &mut Strider, tx, _| {
        if s.dragged.source.as_ref().map(|d| d.window) == tx.window() {
            end(s, tx)?;
        }
        Err(Error::Pass)
    })?;
    app::on(tx, root, KeyUp, |s: &mut Strider, tx, ev| {
        if let EventData::Key {
            keysym, modifiers, ..
        } = ev.data
        {
            modifiers_changed(s, tx, keysym, modifiers, false)?;
        }
        Err(Error::Pass)
    })?;

    // The card: the file's icon and name, and what a drop would do on the accent.
    let card = tx.flex(
        root,
        Flex::row()
            .gap(6.0)
            .align(keywork::Align::Center)
            .height(Dim::Px(28.0))
            .padding(Insets::new(0.0, 10.0, 0.0, 8.0))
            .absolute(keywork::tree::Anchors {
                left: Some(0.0),
                top: Some(0.0),
                ..Default::default()
            }),
    )?;
    tx.set_background(card, Paint::Role(ColorRole::Surface))?;
    tx.set_radius(card, 6.0)?;
    tx.set_pass_through(card, true)?;
    let card_icon = tx.canvas(card, Style::new().size(16.0, 16.0).shrink(0.0))?;
    let card_label = widgets::label(tx, card, "", TextKind::Body)?;
    tx.update_style(card_label, |st| {
        st.max_lines = 1;
        st.max_width = 220.0;
        st.min_width = 0.0;
        st.shrink = 1.0;
    })?;
    let card_badge = widgets::label(tx, card, "", TextKind::Small)?;
    tx.update_style(card_badge, |st| {
        st.font_weight = 700.0;
        st.padding = Insets::new(1.0, 6.0, 1.0, 6.0);
        st.margin = Insets::new(0.0, 0.0, 0.0, 2.0);
        st.shrink = 0.0;
    })?;
    tx.set_color(card_badge, Paint::Role(ColorRole::OnAccent))?;
    tx.set_radius(card_badge, 4.0)?;
    tx.set_hidden(card, true)?;
    Ok(Nodes {
        rings: rings.try_into().expect("three rings"),
        card,
        card_icon,
        card_label,
        card_badge,
    })
}

/// A folder of the header path or a tab, which takes drops into its folder.
pub fn bind<K: keywork::tree::Kind>(
    tx: &mut Txn<'_, Strider>,
    node: NodeId<K>,
    target: Target,
) -> Result<()> {
    app::on(tx, node, DragOver, move |s: &mut Strider, tx, ev| {
        let Some(dest) = folder_of(s, target) else {
            return Err(Error::Pass);
        };
        over(s, tx, ev, target, dest)?;
        // The outline is the app's own: a node that is no widget shows Keywork's none.
        match target {
            Target::Crumb(_) => tx.set_drop_target(s.ui.crumbs),
            _ => tx.set_drop_target(node),
        }
        Ok(())
    })?;
    app::on(tx, node, DragLeave, move |s: &mut Strider, tx, _| {
        if s.dnd.over == Some(target) {
            leave(s, tx)?;
        }
        Ok(())
    })?;
    app::on(
        tx,
        node,
        DragDrop,
        move |s: &mut Strider, tx, ev| match folder_of(s, target) {
            Some(dest) => dropped(s, tx, ev, dest),
            None => Ok(()),
        },
    )
}

// Starting -----------------------------------------------------------------------------------

/// Drags the targets from the current column, the pointer at `at`: the card shows there, and
/// once a frame has drawn it, it is the drag's icon.
pub fn start(s: &mut Strider, tx: &mut Txn<'_, Strider>, at: Point) -> Result<()> {
    let paths = app::targets(s);
    let (Some(first), Some(window)) = (paths.first(), tx.window()) else {
        return Ok(());
    };
    let dir = model::parent(first).to_owned();
    s.dragged.source = Some(Source {
        window,
        dev: dev_of(&dir),
        dir,
        paths,
        cancelled: false,
    });
    show_card(s, tx, None)?;
    let card = s.ui.dnd.card;
    tx.update_style(card, |st| {
        st.position = keywork::tree::Position::Absolute(keywork::tree::Anchors {
            left: Some(at.x - HOTSPOT),
            top: Some(at.y - HOTSPOT),
            ..Default::default()
        });
    })?;
    if let Some(t) = s.dnd.pending.take() {
        tx.cancel_timer(t);
    }
    s.dnd.pending = Some(tx.after(CARD_FRAME, |s: &mut Strider, cx| app::back(s, cx, begin)));
    Ok(())
}

/// The card is drawn: the compositor's drag starts with it as the icon, and it leaves the
/// window.
fn begin(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.dnd.pending = None;
    let card = s.ui.dnd.card;
    hide_card(s, tx)?;
    let Some(src) = s
        .dragged
        .source
        .as_ref()
        .filter(|d| !d.cancelled && Some(d.window) == tx.window())
    else {
        return Ok(());
    };
    let mut list = String::new();
    for p in &src.paths {
        uri::push_file_uri(&mut list, p);
        list.push_str("\r\n");
    }
    let text: Vec<String> = src.paths.iter().map(|p| p.display().to_string()).collect();
    let data = DragData::new(DndActions::COPY | DndActions::MOVE)
        .with(URI_LIST, list)
        .with("text/plain;charset=utf-8", text.join("\n"))
        .with_icon(DragIcon::node(card).hotspot(HOTSPOT, HOTSPOT));
    tx.start_drag(s.ui.lists[Col::Current as usize], data)
}

/// The drag ended, dropped or not: every window forgets it.
pub fn end(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if s.dragged.source.take().is_none() {
        return Ok(());
    }
    if let Some(t) = s.dnd.pending.take() {
        tx.cancel_timer(t);
    }
    hide_card(s, tx)?;
    app::others(tx, leave);
    leave(s, tx)
}

/// A key went down or up: the modifiers that pick what a drop does, and Escape, which gives
/// up this window's drag. True when the key was the drag's.
pub fn key(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    keysym: Keysym,
    modifiers: Modifiers,
) -> Result<bool> {
    modifiers_changed(s, tx, keysym, modifiers, true)?;
    let mine = s
        .dragged
        .source
        .as_ref()
        .is_some_and(|d| !d.cancelled && Some(d.window) == tx.window());
    if keysym != Keysym::ESCAPE || !mine {
        return Ok(false);
    }
    if let Some(d) = &mut s.dragged.source {
        d.cancelled = true;
    }
    if let Some(t) = s.dnd.pending.take() {
        tx.cancel_timer(t);
    }
    hide_card(s, tx)?;
    app::others(tx, leave);
    leave(s, tx)?;
    Ok(true)
}

fn modifiers_changed(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    keysym: Keysym,
    modifiers: Modifiers,
    down: bool,
) -> Result<()> {
    // The key's own modifier is not in the state it comes with yet, or still is.
    let (mut ctrl, mut shift) = (
        modifiers.contains(Modifiers::CTRL),
        modifiers.contains(Modifiers::SHIFT),
    );
    match keysym.0 {
        0xffe1 | 0xffe2 => shift = down,
        0xffe3 | 0xffe4 => ctrl = down,
        _ => {}
    }
    if (ctrl, shift) == (s.dragged.ctrl, s.dragged.shift) {
        return Ok(());
    }
    s.dragged.ctrl = ctrl;
    s.dragged.shift = shift;
    if s.dnd.over.is_some() && s.dnd.takes {
        set_hint(s, tx, action_for(s))?;
    }
    Ok(())
}

// The card -----------------------------------------------------------------------------------

/// The card for the app's drag: the file's icon and name ("3 items"), with what a drop would
/// do when `action` says.
pub fn show_card(s: &mut Strider, tx: &mut Txn<'_, Strider>, action: Option<Action>) -> Result<()> {
    let n = s.ui.dnd;
    let Some(src) = &s.dragged.source else {
        return Ok(());
    };
    let label = match &src.paths[..] {
        [one] => one
            .file_name()
            .map_or_else(|| "/".into(), |n| n.to_string_lossy().into_owned()),
        many => format!("{} items", many.len()),
    };
    let mime = match &src.paths[..] {
        [one] if one.is_dir() => "inode/directory",
        [one] => {
            let f = s.cur();
            one.file_name()
                .and_then(|name| f.position_of(name.as_encoded_bytes()))
                .map_or("text/plain", |pos| f.type_at(pos))
        }
        _ => "application/octet-stream",
    };
    let px = tx
        .theme(n.card_icon)
        .map(|t| t.len(t.styles.list.icon) as u32)
        .unwrap_or(16)
        .min(16);
    let painter = match &mut s.icons {
        Some(icons) => icons.painter(&s.db, mime, px),
        None => None,
    };
    tx.set_painter(n.card_icon, painter)?;
    tx.set_text(n.card_label, &label)?;
    let border = tx.theme(n.card)?.color(Paint::Role(ColorRole::Border));
    tx.set_border(n.card, border, 1.0)?;
    match action {
        Some(a) => {
            tx.set_text(n.card_badge, a.word())?;
            let fill = if a == Action::Move {
                ColorRole::AccentFill
            } else {
                ColorRole::Success
            };
            tx.set_background(n.card_badge, Paint::Role(fill))?;
            tx.set_hidden(n.card_badge, false)?;
        }
        None => tx.set_hidden(n.card_badge, true)?,
    }
    s.dnd.card = Some(action);
    tx.set_hidden(n.card, false)
}

/// The card leaves the window.
pub fn hide_card(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.dnd.card = None;
    tx.set_hidden(s.ui.dnd.card, true)
}

/// The icons came, or changed: the card shows its file's.
pub fn icons_changed(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    match s.dnd.card {
        Some(action) => show_card(s, tx, action),
        None => Ok(()),
    }
}

// Targets ------------------------------------------------------------------------------------

/// The target of a drag at `node` in column `col`, and its folder: a folder's row, or else
/// the folder the column shows. Drives and the trash take nothing.
fn list_target(
    s: &Strider,
    tx: &Txn<'_, Strider>,
    col: Col,
    node: AnyNodeId,
) -> Result<Option<(Target, PathBuf)>> {
    let Some(f) = s.folder(col) else {
        return Ok(None);
    };
    if f.path == Path::new(model::DRIVES_PATH) || is_trash(s, &f.path) {
        return Ok(None);
    }
    if let Some(pos) = widgets::row_item(tx, node)?
        && let Some(e) = f.entry(pos).filter(|e| e.kind == model::Kind::Dir)
    {
        return Ok(Some((Target::Row(col, pos), f.listing.path_of(e))));
    }
    Ok(Some((Target::Column(col), f.path.clone())))
}

/// The folder of a crumb or a tab.
fn folder_of(s: &Strider, target: Target) -> Option<PathBuf> {
    let path = match target {
        Target::Crumb(i) => crate::crumbs::path(s, i)?,
        Target::Tab(i) if i == s.active => s.cwd.clone(),
        Target::Tab(i) => s.tabs.get(i)?.cwd.clone(),
        _ => return None,
    };
    (path != Path::new(model::DRIVES_PATH) && !is_trash(s, &path)).then_some(path)
}

fn is_trash(s: &Strider, path: &Path) -> bool {
    *path == crate::register::home_trash(s).join("files")
}

/// A drag over `target`, which stands for the folder `dest`: outlined and accepted when it
/// takes the drop, with the hint and the timers; refused otherwise.
fn over(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    ev: &Event,
    target: Target,
    dest: PathBuf,
) -> Result<()> {
    // A drag from a window that closed ended with it.
    if let Some(d) = &s.dragged.source
        && !s.wins.iter().any(|w| w.window == d.window)
    {
        s.dragged.source = None;
    }
    if s.dragged.source.as_ref().is_some_and(|d| d.cancelled) {
        return Err(Error::Pass);
    }
    let own = s.dragged.source.is_some();
    let mime = if own {
        URI_LIST
    } else {
        match [URI_LIST, GNOME_COPIED]
            .into_iter()
            .find(|m| tx.drag_mimes().iter().any(|o| o == m))
        {
            Some(m) => m,
            None => return Err(Error::Pass),
        }
    };
    let action = hover(s, tx, target, dest)?;
    let Some(action) = action else {
        return Err(Error::Pass);
    };
    // Wayland has copy and move; a link is asked for as a copy and made here.
    let preferred = if action == Action::Move {
        DndActions::MOVE
    } else {
        DndActions::COPY
    };
    tx.accept_drag(mime, DndActions::COPY | DndActions::MOVE, preferred)?;
    if let (Target::Row(col, _), EventData::Drag { position, .. }) = (target, ev.data) {
        autoscroll(s, tx, col, position.y)?;
    }
    Ok(())
}

/// The drag is on `target`, which stands for the folder `dest`: a new target is outlined
/// when it takes the drop; the hint says what a drop does. What a drop does, or None when
/// the target takes nothing.
pub fn hover(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    target: Target,
    dest: PathBuf,
) -> Result<Option<Action>> {
    if s.dnd.over != Some(target) {
        s.dnd.over = Some(target);
        s.dnd.dest_dev = dev_of(&dest);
        s.dnd.takes = takes(s, &dest);
        s.dnd.dest = dest;
        if let Target::Row(_, pos) = target {
            s.dnd.scroll_row = pos;
        }
        let springs = matches!(target, Target::Row(..) | Target::Tab(_));
        let takes = s.dnd.takes;
        send(s, tx, DropEv::Enter { takes, springs })?;
    }
    if !s.dnd.takes {
        clear_hint(s, tx)?;
        return Ok(None);
    }
    let action = action_for(s);
    set_hint(s, tx, action)?;
    Ok(Some(action))
}

/// Whether `dest` takes the drag: not the folder the items are in, not one of them or a
/// folder inside one, and only a folder that can be written.
fn takes(s: &Strider, dest: &Path) -> bool {
    if let Some(src) = &s.dragged.source {
        if dest == src.dir {
            return false;
        }
        if src.paths.iter().any(|p| dest.starts_with(p)) {
            return false;
        }
    }
    rustix::fs::access(
        dest,
        rustix::fs::Access::WRITE_OK | rustix::fs::Access::EXEC_OK,
    )
    .is_ok()
}

/// Shift moves, Ctrl copies, both link; else a move within one filesystem and a copy
/// across, and a copy of another application's files.
fn action_for(s: &Strider) -> Action {
    let d = &s.dragged;
    match (d.ctrl, d.shift) {
        (true, true) => Action::Link,
        (true, false) => Action::Copy,
        (false, true) => Action::Move,
        _ => match &d.source {
            Some(src) if src.dev.is_some() && src.dev == s.dnd.dest_dev => Action::Move,
            _ => Action::Copy,
        },
    }
}

/// The drag left every target here, or ended.
pub fn leave(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    send(s, tx, DropEv::Leave)?;
    s.dnd.over = None;
    s.dnd.takes = false;
    clear_hint(s, tx)
}

fn set_hint(s: &mut Strider, tx: &mut Txn<'_, Strider>, action: Action) -> Result<()> {
    let what = match s.dragged.source.as_ref().map(|d| &d.paths[..]) {
        Some([one]) => format!(
            "“{}”",
            one.file_name()
                .map_or_else(|| "/".into(), |n| n.to_string_lossy())
        ),
        Some(many) => format!("{} items", many.len()),
        None => "the files".into(),
    };
    let dest = &s.dnd.dest;
    let name = if *dest == s.home {
        "~".into()
    } else {
        dest.file_name()
            .map_or_else(|| "/".into(), |n| n.to_string_lossy().into_owned())
    };
    let into = if action == Action::Link { "in" } else { "to" };
    let text = format!("{} {what} {into} {name}", action.word());
    if text != s.dnd.hint {
        s.dnd.hint = text;
        app::draw_status(s, tx)?;
    }
    Ok(())
}

fn clear_hint(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if s.dnd.hint.is_empty() {
        return Ok(());
    }
    s.dnd.hint.clear();
    app::draw_status(s, tx)
}

/// What the status line says while a drag rests on a target here.
pub fn hint(s: &Strider) -> Option<&str> {
    (!s.dnd.hint.is_empty()).then_some(s.dnd.hint.as_str())
}

// Dropping -----------------------------------------------------------------------------------

/// A drop into `dest`: the app's own drag moves, copies, or links its paths; another
/// application's files are copied, or moved when the drop asks to move.
fn dropped(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: &Event, dest: PathBuf) -> Result<()> {
    let EventData::Dropped { action, .. } = ev.data else {
        return Ok(());
    };
    // As it was when the drag came over the target, from the modifiers held.
    s.dnd.dest_dev = dev_of(&dest);
    let ok = takes(s, &dest);
    let chosen = action_for(s);
    leave(s, tx)?;
    if !ok {
        return Ok(());
    }
    if let Some(src) = s.dragged.source.take() {
        if src.cancelled {
            return Ok(());
        }
        app::others(tx, leave);
        let req = Request::transfer(chosen.kind(), src.paths, dest);
        return crate::tasks::start(s, tx, req, true);
    }
    let Some((mime, data)) = tx.dropped() else {
        return Ok(());
    };
    let text = String::from_utf8_lossy(data).into_owned();
    let uris = if mime == GNOME_COPIED {
        uri::gnome_copied(&text).1
    } else {
        &text
    };
    let paths: Vec<PathBuf> = uri::lines(uris).filter_map(uri::file_path).collect();
    if paths.is_empty() {
        s.notify("Only local files can be pasted here", false);
        return app::draw_status(s, tx);
    }
    let kind = if s.dragged.ctrl && s.dragged.shift {
        Kind::Link
    } else if action.contains(DndActions::MOVE) {
        Kind::Move
    } else {
        Kind::Copy
    };
    crate::tasks::start(s, tx, Request::transfer(kind, paths, dest), true)
}

// The outline, opening, and scrolling ---------------------------------------------------------

/// Starts the window's timers on the loop, each calling back into the hover chart.
struct Clock<'a, 't> {
    tx: &'a mut Txn<'t, Strider>,
}

impl Scheduler<Timer> for Clock<'_, '_> {
    fn schedule(&mut self, delay: Duration, token: TimerToken) -> Timer {
        self.tx.after(delay, move |s: &mut Strider, cx| {
            app::back(s, cx, |s, tx| {
                let fx = s.dnd.chart.fire(token, Clock { tx });
                apply(s, tx, fx)
            })
        })
    }

    fn cancel(&mut self, timer: Timer) {
        self.tx.cancel_timer(timer);
    }
}

fn send(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: DropEv) -> Result<()> {
    let fx = s.dnd.chart.send(ev, Clock { tx });
    apply(s, tx, fx)
}

fn apply(s: &mut Strider, tx: &mut Txn<'_, Strider>, fx: Vec<DropFx>) -> Result<()> {
    let mut open = false;
    for f in fx {
        match f {
            DropFx::Outline(true) => {
                s.dnd.outlined = s.dnd.over;
                if let Some(t) = s.dnd.over {
                    outline(s, tx, t, true)?;
                }
            }
            DropFx::Outline(false) => {
                if let Some(t) = s.dnd.outlined.take() {
                    outline(s, tx, t, false)?;
                }
            }
            DropFx::Open => open = true,
            DropFx::Scroll(dir) => scroll(s, tx, dir)?,
        }
    }
    if open {
        spring(s, tx)?;
    }
    Ok(())
}

/// The drag rested on a folder's row or a tab: it opens, and whatever is under the pointer
/// then is a new target.
fn spring(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let target = s.dnd.over.take();
    let dest = std::mem::take(&mut s.dnd.dest);
    s.dnd.takes = false;
    match target {
        Some(Target::Tab(i)) => crate::tabs::select(s, tx, i),
        Some(_) => app::cd(s, tx, dest, None, true),
        None => Ok(()),
    }
}

fn outline(s: &mut Strider, tx: &mut Txn<'_, Strider>, target: Target, on: bool) -> Result<()> {
    match target {
        Target::Row(col, _) => widgets::refresh_rows(tx, s.ui.lists[col as usize]),
        Target::Column(col) => {
            let ring = s.ui.dnd.rings[col as usize];
            if on {
                let accent = tx.theme(ring)?.color(Paint::Role(ColorRole::AccentFill));
                tx.set_border(ring, accent, 2.0)?;
            }
            tx.set_hidden(ring, !on)
        }
        Target::Crumb(i) => crate::crumbs::outline(s, tx, i, on),
        Target::Tab(i) => crate::tabs::style(s, tx, i),
    }
}

/// A column's row as it is filled: outlined while a drop would go into its folder.
pub fn fill_row(
    s: &Strider,
    tx: &mut Txn<'_, Strider>,
    row: NodeId<Flex>,
    fresh: bool,
    col: Col,
    pos: usize,
) -> Result<()> {
    if fresh {
        let ring = tx.flex(
            row,
            Style::new().absolute(keywork::tree::Anchors {
                left: Some(0.0),
                top: Some(0.0),
                right: Some(0.0),
                bottom: Some(0.0),
            }),
        )?;
        tx.set_radius(ring, 4.0)?;
        tx.set_pass_through(ring, true)?;
    }
    let Some(ring) = tx.children(row)?.nth(4) else {
        return Ok(());
    };
    let ring = tx.downcast::<Flex>(ring)?;
    let on = s.dnd.outlined == Some(Target::Row(col, pos));
    if on {
        let accent = tx.theme(ring)?.color(Paint::Role(ColorRole::AccentFill));
        tx.set_border(ring, accent, 2.0)?;
    }
    tx.set_hidden(ring, !on)
}

/// A tab's look while a drop would go into its folder: raised, in an accent border.
pub fn tab_look(s: &Strider, tx: &mut Txn<'_, Strider>, tab: NodeId<Flex>, i: usize) -> Result<()> {
    let on = s.dnd.outlined == Some(Target::Tab(i));
    let accent = tx.theme(tab)?.color(Paint::Role(ColorRole::AccentFill));
    if on {
        tx.set_background(tab, Paint::Role(ColorRole::ComponentHover))?;
    }
    tx.set_border(tab, accent, if on { 2.0 } else { 0.0 })
}

/// Near a column's top or bottom edge, the column scrolls a row at a time while the drag
/// rests there.
fn autoscroll(s: &mut Strider, tx: &mut Txn<'_, Strider>, col: Col, y: f32) -> Result<()> {
    let view = tx.window_rect(s.ui.lists[col as usize])?;
    let edge = if y < view.y + EDGE {
        -1
    } else if y > view.y + view.height - EDGE {
        1
    } else {
        0
    };
    send(s, tx, DropEv::Edge(edge))
}

fn scroll(s: &mut Strider, tx: &mut Txn<'_, Strider>, dir: i8) -> Result<()> {
    let Some(Target::Row(col, _)) = s.dnd.over else {
        return Ok(());
    };
    let n = s.folder(col).map_or(0, crate::folder::Folder::len);
    let row = s
        .dnd
        .scroll_row
        .saturating_add_signed(isize::from(dir))
        .min(n.saturating_sub(1));
    s.dnd.scroll_row = row;
    widgets::scroll_to_item(tx, s.ui.lists[col as usize], row)?;
    if row == 0 || row + 1 >= n {
        send(s, tx, DropEv::Edge(0))?;
    }
    Ok(())
}

fn dev_of(path: &Path) -> Option<u64> {
    std::fs::metadata(path).ok().map(|m| m.dev())
}
