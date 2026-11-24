//! The window: a header with the path, three Miller columns (the parent folder, the current
//! one, and a preview of the entry under the cursor), the which-key popup, and a status line.
//! Keys go through the keymap statechart to commands; the mode statechart says which table
//! they are looked up in.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use keywork::desktop::localtime::Zone;
use keywork::desktop::mime::MimeDb;
use keywork::icons::MimeIcons;
use keywork::kind::{Box as BoxKind, Canvas};
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, ListDesc, SelectionMode, TextKind};
use keywork::{Error, FontFamily, FontSlant, TextSpan, Timer};

use plusthree::host::{Scheduler, TimerToken};
use strider_core::highlight::Class;
use strider_core::keys::{self, Key, Keymap, Mods};
use strider_core::model::{self, Kind};
use strider_core::options::Options;
use strider_machines::driver::Driver;
use strider_machines::keymap::{self, KeyEv, KeyFx};
use strider_machines::mode::{self, ModeEv, ModeFx};

use crate::cache::{self, Cache};
use crate::commands;
use crate::folder::Folder;
use crate::preview::Preview;

/// A row's height in the columns, as the Zig build had it.
pub const ROW_HEIGHT: f32 = 26.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Col {
    Parent,
    Current,
    Preview,
}

pub struct Ui {
    pub header: NodeId<Text>,
    pub panes: [NodeId<Stack>; 3],
    pub lists: [NodeId<BoxKind>; 3],
    /// A text preview's lines.
    pub preview_lines: NodeId<BoxKind>,
    pub preview_info: NodeId<Text>,
    pub status_mode: NodeId<Text>,
    pub status_left: NodeId<Text>,
    pub status_keys: NodeId<Text>,
    pub status_right: NodeId<Text>,
    pub which_key: NodeId<Flex>,
    /// What a column shows in place of rows: "Empty", or why it could not be read.
    pub messages: [NodeId<Text>; 3],
    /// The command line, under the status line while a prompt is open: its label, as `:`,
    /// and the text.
    pub line: NodeId<Flex>,
    pub line_label: NodeId<Text>,
    pub line_editor: NodeId<keywork::Editor>,
}

pub struct Strider {
    pub window: WindowId,
    pub ui: Ui,
    pub options: Options,
    pub keymap: Keymap,
    pub keys: Driver<keymap::Keymap, Timer>,
    pub mode: Driver<mode::Mode, Timer>,
    pub home: PathBuf,
    pub zone: Zone,
    pub db: Arc<MimeDb>,
    pub icons: Option<MimeIcons>,
    pub cache: Cache,
    /// The current folder, and its parent, which the columns show from the cache.
    pub cwd: PathBuf,
    pub parent_path: Option<PathBuf>,
    pub preview: Preview,
    /// Which preview read a file's result belongs to.
    pub preview_generation: u64,
    /// Read folders and files on the UI thread, so a scene's keys find them read: scenes
    /// render the same every time.
    pub sync_reads: bool,
    /// Back and forward through the folders visited.
    pub history: Vec<PathBuf>,
    pub history_pos: usize,
    /// Where a visual range started, as a position in the current folder's order.
    pub anchor: usize,
    /// A message for the status line, and whether it is an error.
    pub message: Option<(String, bool)>,
    /// The columns' width together, from layout; 0 before the first frame.
    pub width: f32,
    /// The width the parent column's names need, for `fit_parent`.
    pub parent_fit: f32,
    /// Where the cursor was as the prompt opened, for a search to start from and Escape to
    /// go back to.
    pub prompt_origin: usize,
    /// The entry the cursor was on as the prompt opened, which a filter keeps it on
    /// whenever it shows.
    pub prompt_entry: Option<Vec<u8>>,
    /// The last search's text and direction, for `n` and `N`.
    pub last_search: String,
    pub last_search_back: bool,
    /// Command lines typed, oldest first, and which one Up and Down are on.
    pub lines: Vec<String>,
    pub line_pos: usize,
    /// Where bookmarks, history, and column widths are kept; none in tests and scenes.
    pub state_dir: Option<PathBuf>,
    /// Which look at a typed path a result belongs to.
    pub probe: u64,
}

impl Strider {
    pub fn visual(&self) -> bool {
        self.mode.matches(mode::mode::states::selection::VISUAL)
    }

    /// The prompt the command line is open for.
    pub fn prompt(&self) -> Option<mode::Prompt> {
        self.mode
            .matches(mode::mode::states::line::OPEN)
            .then(|| self.mode.context().prompt)
    }

    /// The current folder, which the cache holds while a column shows it.
    pub fn cur(&self) -> &Folder {
        self.cache
            .get(&self.cwd)
            .expect("the current folder is cached")
    }

    pub fn cur_mut(&mut self) -> &mut Folder {
        self.cache
            .get_mut(&self.cwd)
            .expect("the current folder is cached")
    }

    pub fn folder(&self, col: Col) -> Option<&Folder> {
        match col {
            Col::Parent => self.parent_path.as_deref().and_then(|p| self.cache.get(p)),
            Col::Current => Some(self.cur()),
            Col::Preview => match &self.preview {
                Preview::Folder(p) => self.cache.get(p),
                _ => None,
            },
        }
    }

    pub fn notify(&mut self, text: impl Into<String>, error: bool) {
        self.message = Some((text.into(), error));
    }

    /// `path` as the header shows it: under home as `~/...`.
    pub fn short_path(&self, path: &Path) -> String {
        match path.strip_prefix(&self.home) {
            Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => path.display().to_string(),
        }
    }
}

/// Builds the window's tree.
pub fn build(tx: &mut Txn<'_, Strider>) -> Result<Ui> {
    let root = tx.stack(tx.root(), Style::new().width(Dim::Fill).height(Dim::Fill))?;
    let body = widgets::surface(
        tx,
        root,
        Flex::column().width(Dim::Fill).height(Dim::Fill),
        widgets::SurfaceKind::Background,
    )?;
    let bar = tx.flex(
        body,
        Flex::row()
            .width(Dim::Fill)
            .padding(Insets::new(6.0, 12.0, 6.0, 12.0)),
    )?;
    let header = widgets::label(tx, bar, "", TextKind::Body)?;
    tx.update_style(header, |s| s.max_lines = 1)?;

    let columns = tx.flex(body, Flex::row().width(Dim::Fill).grow(1.0))?;
    tx.on(columns, Resize, |s: &mut Strider, tx, ev| {
        if let EventData::Resize(size) = ev.data
            && size.width != s.width
        {
            s.width = size.width;
            layout(s, tx)?;
        }
        Ok(())
    })?;
    let (mut lists, mut panes, mut messages) = (Vec::new(), Vec::new(), Vec::new());
    for (col, gray) in [(Col::Parent, 3), (Col::Current, 2), (Col::Preview, 1)] {
        let pane = tx.stack(
            columns,
            Style::new()
                .height(Dim::Fill)
                .grow(1.0)
                .basis(Dim::Px(0.0))
                .min_width(0.0),
        )?;
        panes.push(pane);
        tx.set_background(pane, Paint::Gray(gray))?;
        let list = widgets::list(
            tx,
            pane,
            Style::new().width(Dim::Fill).height(Dim::Fill),
            ListDesc {
                selection: SelectionMode::Single,
                extent: Some(ROW_HEIGHT),
                keys_hide_hover: true,
                ..ListDesc::default()
            },
        )?;
        tx.set_label(list, ["Parent folder", "Folder", "Preview"][col as usize])?;
        widgets::set_type_ahead(tx, list, false)?;
        tx.on(list, RowNeeded, move |s: &mut Strider, tx, ev| {
            fill_row(s, tx, ev, col)
        })?;
        let message = widgets::label(tx, pane, "", TextKind::Muted)?;
        tx.update_style(message, |st| {
            st.width = Dim::Fill;
            st.padding = Insets::new(16.0, 8.0, 0.0, 8.0);
            st.text_align = keywork::TextAlign::Center;
        })?;
        messages.push(message);
        tx.on(list, Changed, move |s: &mut Strider, tx, _| {
            clicked(s, tx, col)
        })?;
        tx.on(list, Activate, move |s: &mut Strider, tx, _| {
            if col == Col::Current {
                commands::execute(s, tx, "enter", None, false)
            } else {
                Ok(())
            }
        })?;
        lists.push(list);
    }
    let preview_pane = panes[2];
    let preview_lines = widgets::list(
        tx,
        preview_pane,
        Style::new().width(Dim::Fill).height(Dim::Fill),
        ListDesc {
            selection: SelectionMode::None,
            ..ListDesc::default()
        },
    )?;
    tx.set_label(preview_lines, "Preview")?;
    widgets::set_type_ahead(tx, preview_lines, false)?;
    tx.on(preview_lines, RowNeeded, fill_line)?;
    let preview_info = widgets::label(tx, preview_pane, "", TextKind::Muted)?;
    tx.update_style(preview_info, |s| s.padding = Insets::all(16.0))?;

    let status = tx.flex(
        body,
        Flex::row()
            .width(Dim::Fill)
            .gap(12.0)
            .padding(Insets::new(4.0, 12.0, 4.0, 12.0)),
    )?;
    let status_mode = widgets::label(tx, status, "", TextKind::Small)?;
    tx.update_style(status_mode, |st| {
        st.font_weight = 700.0;
        st.padding = Insets::new(0.0, 5.0, 0.0, 5.0);
    })?;
    tx.set_background(status_mode, Paint::Role(ColorRole::AccentFill))?;
    tx.set_color(status_mode, Paint::Role(ColorRole::OnAccent))?;
    tx.set_radius(status_mode, 3.0)?;
    let status_left = widgets::label(tx, status, "", TextKind::Small)?;
    tx.update_style(status_left, |s| {
        s.grow = 1.0;
        s.max_lines = 1;
    })?;
    let status_keys = widgets::label(tx, status, "", TextKind::Small)?;
    let status_right = widgets::label(tx, status, "", TextKind::Small)?;

    let line = tx.flex(
        body,
        Flex::row()
            .width(Dim::Fill)
            .gap(4.0)
            .align(keywork::Align::Center)
            .padding(Insets::new(2.0, 8.0, 4.0, 8.0)),
    )?;
    let line_label = widgets::label(tx, line, ":", TextKind::Strong)?;
    tx.set_color(line_label, Paint::Role(ColorRole::AccentText))?;
    tx.update_style(line_label, |s| s.shrink = 0.0)?;
    let line_editor = widgets::text_field(tx, line, "")?;
    if let Some(field) = tx.parent(line_editor)? {
        tx.update_style(field, |s| {
            s.grow = 1.0;
            s.basis = Some(Dim::Px(0.0));
            s.min_width = 0.0;
        })?;
    }
    tx.set_label(line_editor, "Command")?;
    tx.on(line_editor, Changed, |s: &mut Strider, tx, _| {
        send_mode(s, tx, ModeEv::Edit)
    })?;
    tx.set_hidden(line, true)?;

    let which_key = widgets::surface(
        tx,
        root,
        Flex::column()
            .gap(4.0)
            .padding(12.0)
            .absolute(keywork::tree::Anchors {
                right: Some(12.0),
                bottom: Some(36.0),
                ..Default::default()
            }),
        widgets::SurfaceKind::Raised(2),
    )?;
    tx.set_hidden(which_key, true)?;

    // Keys go to the focused current column; the keymap hears them all first.
    tx.on(tx.root(), KeyCapture, key_down)?;
    let [parent, current, preview] = lists.try_into().expect("three lists");
    tx.focus(current)?;
    Ok(Ui {
        header,
        panes: panes.try_into().expect("three panes"),
        messages: messages.try_into().expect("three messages"),
        lists: [parent, current, preview],
        preview_lines,
        preview_info,
        status_mode,
        status_left,
        status_keys,
        status_right,
        which_key,
        line,
        line_label,
        line_editor,
    })
}

// --- Keys ----------------------------------------------------------------------------------

/// A key event as the keymap writes keys: a typed character, or a keysym with modifiers.
/// Modifier keys alone are none.
pub fn key_of(keysym: Keysym, modifiers: Modifiers) -> Option<Key> {
    let raw = keysym.0;
    if (0xffe1..=0xffee).contains(&raw) || raw == 0xfe03 || raw == 0 {
        return None;
    }
    let (ctrl, alt, sup, shift) = (
        modifiers.contains(Modifiers::CTRL),
        modifiers.contains(Modifiers::ALT),
        modifiers.contains(Modifiers::SUPER),
        modifiers.contains(Modifiers::SHIFT),
    );
    if !ctrl
        && !alt
        && !sup
        && let Some(c) = keysym.to_char()
        && (c as u32) >= 0x20
        && c as u32 != 0x7f
    {
        return Some(Key::char(c as u32));
    }
    let mut mods = Mods {
        ctrl,
        alt,
        super_: sup,
        shift: false,
    };
    let mut code = raw;
    if code == keys::sym::ISO_LEFT_TAB {
        code = keys::sym::TAB;
        mods.shift = true;
    } else if code == keys::sym::KP_ENTER {
        code = keys::sym::RETURN;
    } else if code >= 0x0100_0000 {
        code -= 0x0100_0000;
    }
    if code >= 0xff00 {
        mods.shift = mods.shift || shift;
    } else if code < 128 && ctrl && !shift {
        code = u32::from((code as u8).to_ascii_lowercase());
    }
    Some(Key { code, mods })
}

fn key_down(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: &Event) -> Result<()> {
    let EventData::Key {
        keysym, modifiers, ..
    } = ev.data
    else {
        return Err(Error::Pass);
    };
    let Some(key) = key_of(keysym, modifiers) else {
        return Err(Error::Pass);
    };
    press(s, tx, key)
}

/// A key, as the keymap writes keys: to the open prompt, or through the keymap to a
/// command. Fails with [`Error::Pass`] for a key the focused widget should have.
pub fn press(s: &mut Strider, tx: &mut Txn<'_, Strider>, key: Key) -> Result<()> {
    if let Some(p) = s.prompt() {
        return crate::prompt::key(s, tx, p, key);
    }
    if s.message.take().is_some() {
        draw_status(s, tx)?;
    }
    let seq = keymap::sequence(&s.keys.context().pending, key);
    let found = s.keymap.lookup(mode::table(s.visual()), &seq);
    let event = KeyEv::Key {
        key,
        exact: found.exact.map(|b| b.cmd.clone()),
        prefix: found.prefix,
    };
    let fx = s.keys.send(event, Clock { tx });
    apply_key_fx(s, tx, fx)
}

/// Starts the keymap's timers on the loop, each calling back with its token.
pub struct Clock<'a, 't> {
    pub tx: &'a mut Txn<'t, Strider>,
}

impl Scheduler<Timer> for Clock<'_, '_> {
    fn schedule(&mut self, delay: std::time::Duration, token: TimerToken) -> Timer {
        self.tx.after(delay, move |s: &mut Strider, cx| {
            let window = s.window;
            cx.update(window, |tx| {
                let fx = s.keys.fire(token, Clock { tx });
                apply_key_fx(s, tx, fx)
            })
        })
    }

    fn cancel(&mut self, timer: Timer) {
        self.tx.cancel_timer(timer);
    }
}

pub fn apply_key_fx(s: &mut Strider, tx: &mut Txn<'_, Strider>, fx: Vec<KeyFx>) -> Result<()> {
    let mut pass = false;
    for f in fx {
        match f {
            KeyFx::Run { cmd, count } => commands::execute(s, tx, &cmd, count, true)?,
            KeyFx::Unbound(seq) => {
                let mode = if s.visual() { "visual" } else { "normal" };
                s.notify(
                    format!("{} isn't bound in {mode} mode", keys::format(&seq)),
                    false,
                );
                draw_status(s, tx)?;
            }
            KeyFx::Pass => pass = true,
            KeyFx::ShowHints => show_which_key(s, tx)?,
            KeyFx::HideHints => tx.set_hidden(s.ui.which_key, true)?,
            KeyFx::Status => draw_status(s, tx)?,
        }
    }
    if pass { Err(Error::Pass) } else { Ok(()) }
}

/// Steps the mode, and carries out what it asks.
pub fn send_mode(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: ModeEv) -> Result<()> {
    let fx = s.mode.send(ev, plusthree::host::NoTimers);
    for f in fx {
        match f {
            ModeFx::StartRange => s.anchor = s.cur().cursor,
            ModeFx::EndRange => {
                let (lo, hi) = range(s);
                for pos in lo..=hi {
                    if let Some(i) = s.cur().index(pos) {
                        s.cur_mut().marks.insert(i);
                    }
                }
            }
            ModeFx::Changed => {
                let fx = s.keys.send(KeyEv::Reset, Clock { tx });
                apply_key_fx(s, tx, fx)?;
                // New rows clear the list's cursor, which focus would put on the first row.
                widgets::set_row_count(tx, s.ui.lists[Col::Current as usize], s.cur().len())?;
                draw_cursor(s, tx, Col::Current)?;
            }
            ModeFx::OpenLine(p) => crate::prompt::open(s, tx, p)?,
            ModeFx::CloseLine => crate::prompt::close(s, tx)?,
            ModeFx::Live(p) => crate::prompt::live(s, tx, p)?,
            ModeFx::Run(p, text) => crate::prompt::run(s, tx, p, &text)?,
            ModeFx::Restore(p) => crate::prompt::restore(s, tx, p)?,
        }
    }
    draw_status(s, tx)
}

/// The visual range, as positions in the current folder's order.
pub fn range(s: &Strider) -> (usize, usize) {
    let (a, c) = (
        s.anchor.min(s.cur().len().saturating_sub(1)),
        s.cur().cursor,
    );
    (a.min(c), a.max(c))
}

fn show_which_key(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let pending = s.keys.context().pending.clone();
    let table = mode::table(s.visual());
    let mut hints: Vec<(String, String)> = Vec::new();
    for b in s.keymap.continuations(table, &pending) {
        let rest = &b.keys[pending.len()..];
        let next = keys::format(&rest[..1]);
        let desc = if rest.len() > 1 {
            "+more"
        } else if b.desc.is_empty() {
            &b.cmd
        } else {
            &b.desc
        };
        hints.push((next, desc.to_owned()));
    }
    let popup = s.ui.which_key;
    let old: Vec<_> = tx.children(popup)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    let title = widgets::label(tx, popup, keys::format(&pending), TextKind::Strong)?;
    tx.set_color(title, Paint::Role(ColorRole::AccentText))?;
    // Up to three columns of keys and descriptions, filled down each.
    let cols = if hints.len() > 16 {
        3
    } else if hints.len() > 6 {
        2
    } else {
        1
    };
    let rows = hints.len().div_ceil(cols);
    let grid = tx.flex(popup, Flex::row().gap(12.0))?;
    for chunk in hints.chunks(rows.max(1)) {
        let keys_col = tx.flex(grid, Flex::column().gap(3.0))?;
        let descs = tx.flex(grid, Flex::column().gap(3.0))?;
        for (k, d) in chunk {
            let kn = widgets::label(tx, keys_col, k, TextKind::Strong)?;
            tx.set_color(kn, Paint::Role(ColorRole::AccentText))?;
            let dn = widgets::label(tx, descs, d, TextKind::Body)?;
            tx.update_style(dn, |st| {
                st.max_lines = 1;
                st.max_width = 240.0;
            })?;
        }
    }
    tx.set_hidden(popup, false)
}

// --- Folders -------------------------------------------------------------------------------

/// Changes the current folder, the cursor on `focus` or where it was last, and records it in
/// the history. A cached folder shows at once; one not read yet shows "Loading…".
pub fn cd(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    path: PathBuf,
    focus: Option<&[u8]>,
    record: bool,
) -> Result<()> {
    let path = model::normalize(&path);
    if !path.is_dir() {
        s.notify(format!("{} is not a folder", s.short_path(&path)), true);
        return draw_status(s, tx);
    }
    if s.visual() {
        send_mode(s, tx, ModeEv::VisualCancel)?;
    }
    let f = s.cache.entry(&path);
    if let Some(name) = focus {
        f.focus(name);
    }
    s.cwd = path.clone();
    s.parent_path = path.parent().map(Path::to_owned);
    if let (Some(p), Some(name)) = (s.parent_path.clone(), path.file_name()) {
        s.cache
            .entry(&p)
            .focus(std::os::unix::ffi::OsStrExt::as_bytes(name));
    }
    if record {
        s.history.truncate(s.history_pos + 1);
        s.history.push(path);
        s.history_pos = s.history.len() - 1;
    }
    reload_preview(s, tx)?;
    draw(s, tx)
}

/// Shows what is under the cursor in the preview: a folder from the cache, or a file read on
/// a worker; then tells the cache which folders the columns show.
pub fn reload_preview(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.preview_generation += 1;
    let generation = s.preview_generation;
    let entry = s.cur().current().copied();
    let path = s.cur().current_path();
    s.preview = match (entry, path, s.options.preview) {
        (Some(e), Some(path), true) if e.kind == Kind::Dir => Preview::Folder(path),
        (Some(e), Some(path), true) if e.kind == Kind::File && s.sync_reads => {
            crate::preview::read_file(&path, s.options.preview_max_bytes, s.options.syntax)
        }
        (Some(e), Some(path), true) if e.kind == Kind::File => {
            let (max, syntax) = (s.options.preview_max_bytes, s.options.syntax);
            tx.spawn_blocking(
                move || crate::preview::read_file(&path, max, syntax),
                move |s: &mut Strider, tx, preview| {
                    if s.preview_generation != generation {
                        return Ok(());
                    }
                    s.preview = preview;
                    draw_preview(s, tx)
                },
            );
            Preview::Loading
        }
        (Some(_), Some(_), true) => Preview::Info(String::new()),
        _ => Preview::None,
    };
    cache::show(s, tx)
}

/// Moves the cursor to `pos` in the current folder, and shows what is under it.
pub fn move_cursor(s: &mut Strider, tx: &mut Txn<'_, Strider>, pos: usize) -> Result<()> {
    let pos = pos.min(s.cur().len().saturating_sub(1));
    if pos == s.cur().cursor && !matches!(s.preview, Preview::None) {
        return Ok(());
    }
    s.cur_mut().cursor = pos;
    reload_preview(s, tx)?;
    if s.visual() {
        widgets::set_row_count(tx, s.ui.lists[Col::Current as usize], s.cur().len())?;
    }
    draw_cursor(s, tx, Col::Current)?;
    draw_preview(s, tx)?;
    draw_header(s, tx)?;
    draw_status(s, tx)
}

fn clicked(s: &mut Strider, tx: &mut Txn<'_, Strider>, col: Col) -> Result<()> {
    let list = s.ui.lists[col as usize];
    let Some(pos) = widgets::list_cursor(tx, list)? else {
        return Ok(());
    };
    // The list also says so when the app moved its selection, which changes nothing here.
    if s.folder(col).is_none_or(|f| f.cursor == pos) {
        return Ok(());
    }
    match col {
        Col::Current => move_cursor(s, tx, pos),
        Col::Parent => {
            let parent = s
                .folder(Col::Parent)
                .expect("a parent column with a cursor");
            let Some(path) = parent
                .entry(pos)
                .filter(|e| e.kind == Kind::Dir)
                .map(|e| parent.listing.path_of(e))
            else {
                return draw_cursor(s, tx, col);
            };
            cd(s, tx, path, None, true)
        }
        Col::Preview => {
            let Some(path) = s
                .folder(Col::Preview)
                .and_then(|f| f.entry(pos).map(|e| f.listing.path_of(e)))
            else {
                return Ok(());
            };
            let (dir, name) = (
                path.parent().map(Path::to_owned),
                path.file_name()
                    .map(|n| std::os::unix::ffi::OsStrExt::as_bytes(n).to_vec()),
            );
            match dir {
                Some(dir) => cd(s, tx, dir, name.as_deref(), true),
                None => Ok(()),
            }
        }
    }
}

// --- Drawing -------------------------------------------------------------------------------

/// Draws everything: after a change of folder, an option, or the sort.
pub fn draw(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let fit = fit_width(s, tx)?;
    if fit != s.parent_fit {
        s.parent_fit = fit;
    }
    layout(s, tx)?;
    for col in [Col::Parent, Col::Current] {
        draw_column(s, tx, col)?;
    }
    draw_preview(s, tx)?;
    draw_header(s, tx)?;
    draw_status(s, tx)
}

/// The width the parent column needs for its longest names: the dozen longest in bytes are
/// measured, in the bold a marked name takes, with the row around them.
fn fit_width(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<f32> {
    let Some(p) = s.folder(Col::Parent) else {
        return Ok(0.0);
    };
    let mut names: Vec<&[u8]> = p
        .order
        .iter()
        .map(|&i| p.listing.base(&p.listing.entries[i as usize]))
        .collect();
    names.sort_unstable_by_key(|n| std::cmp::Reverse(n.len()));
    let style = Style::new().font_weight(700.0);
    let mut widest: f32 = 0.0;
    for name in names.iter().take(12) {
        widest = widest.max(
            tx.measure_text(&style, &String::from_utf8_lossy(name))?
                .width,
        );
    }
    if widest == 0.0 {
        return Ok(0.0);
    }
    let icon = if s.options.icons { 16.0 + 6.0 } else { 0.0 };
    Ok(widest + 1.0 + 8.0 + 3.0 + 6.0 + icon + 6.0 + 10.0)
}

/// The columns' widths from `ratio` and the width there is: a narrow window drops the parent
/// column, then the preview, and with `fit_parent` the parent widens to fit its names, up to a
/// quarter of the width, taking the room from the preview.
pub fn layout(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let o = &s.options;
    let r = o.ratio;
    let w = s.width;
    let narrow = o.narrow_width as f32;
    let show_parent = r[0] > 0.0 && (w == 0.0 || w >= narrow);
    let show_preview = o.preview && r[2] > 0.0 && (w == 0.0 || w >= narrow * 2.0 / 3.0);
    let [parent, current, preview] = s.ui.panes;
    let total = r[0] + r[1].max(0.1) + r[2];
    if show_parent && show_preview && o.fit_parent && w > 0.0 && s.parent_fit > 0.0 {
        let share = w * r[0] / total;
        let parent_px = s.parent_fit.clamp(share, share.max(w / 4.0));
        let current_px = w * r[1].max(0.1) / total;
        for (pane, px) in [(parent, parent_px), (current, current_px)] {
            tx.update_style(pane, |st| {
                st.grow = 0.0;
                st.shrink = 0.0;
                st.width = Dim::Px(px);
                st.basis = None;
            })?;
        }
    } else {
        for (pane, grow) in [(parent, r[0]), (current, r[1].max(0.1))] {
            tx.update_style(pane, |st| {
                st.grow = grow;
                st.shrink = 1.0;
                st.width = Dim::Auto;
                st.basis = Some(Dim::Px(0.0));
            })?;
        }
    }
    tx.update_style(preview, |st| {
        st.grow = r[2];
        st.basis = Some(Dim::Px(0.0));
    })?;
    tx.set_hidden(parent, !show_parent)?;
    tx.set_hidden(preview, !show_preview)
}

/// Fills a column's rows again and places its cursor.
pub fn draw_column(s: &Strider, tx: &mut Txn<'_, Strider>, col: Col) -> Result<()> {
    let n = s.folder(col).map_or(0, Folder::len);
    widgets::set_row_count(tx, s.ui.lists[col as usize], n)?;
    draw_cursor(s, tx, col)
}

pub fn draw_cursor(s: &Strider, tx: &mut Txn<'_, Strider>, col: Col) -> Result<()> {
    let list = s.ui.lists[col as usize];
    let message = match s.folder(col) {
        Some(f) => match f.error {
            Some(model::ReadError::AccessDenied) => "Permission denied",
            Some(model::ReadError::FileNotFound) => "Not found",
            Some(model::ReadError::NotDir) => "Not a folder",
            Some(_) => "Cannot read this folder",
            None if !f.loaded => "Loading…",
            None if f.len() == 0 => "Empty",
            None => "",
        },
        None => "",
    };
    tx.set_text(s.ui.messages[col as usize], message)?;
    tx.set_hidden(s.ui.messages[col as usize], message.is_empty())?;
    match s.folder(col) {
        Some(f) if f.len() > 0 => {
            widgets::select_item(tx, list, f.cursor)?;
            widgets::scroll_to_item(tx, list, f.cursor)
        }
        _ => widgets::clear_selection(tx, list),
    }
}

fn draw_preview(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let list = s.ui.lists[Col::Preview as usize];
    let (folder, text, info) = match &s.preview {
        Preview::Folder(_) => (true, false, false),
        Preview::Text { .. } => (false, true, false),
        Preview::Info(_) => (false, false, true),
        Preview::None | Preview::Loading => (false, false, false),
    };
    tx.set_hidden(list, !folder)?;
    if !folder {
        tx.set_hidden(s.ui.messages[Col::Preview as usize], true)?;
    }
    tx.set_hidden(s.ui.preview_lines, !text)?;
    tx.set_hidden(s.ui.preview_info, !info)?;
    match &s.preview {
        Preview::Folder(_) => draw_column(s, tx, Col::Preview)?,
        Preview::Text { text, lines, .. } => {
            // Lines run on past the column's edge, as in an editor, rather than wrapping: the
            // rows are as wide as the longest line.
            let mono = Style::new().font_family(FontFamily::Mono);
            let longest = lines
                .iter()
                .max_by_key(|r| r.len())
                .map_or("", |r| &text[r.clone()]);
            let size = tx.measure_text(&mono, longest)?;
            let line = tx.measure_text(&mono, "X")?.height;
            let list = s.ui.preview_lines;
            widgets::set_list_extent(tx, list, Some(line))?;
            widgets::set_row_width(tx, list, Some(size.width + 24.0))?;
            widgets::set_row_count(tx, list, lines.len())?;
            widgets::scroll_to_item(tx, list, 0)?;
        }
        Preview::Info(t) => tx.set_text(s.ui.preview_info, t)?,
        Preview::None | Preview::Loading => {}
    }
    Ok(())
}

/// Fills a text preview's row with line `index` and its coloring.
fn fill_line(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: &Event) -> Result<()> {
    let EventData::Row { index, row, fresh } = ev.data else {
        return Ok(());
    };
    if fresh {
        tx.update_style(row, |st| st.padding = Insets::new(0.0, 12.0, 0.0, 12.0))?;
        let t = tx.text(row, "")?;
        tx.update_style(t, |st| {
            st.font_family = FontFamily::Mono;
            st.max_lines = 1;
            st.text_overflow = keywork::TextOverflow::Clip;
        })?;
    }
    let Preview::Text { text, lines, spans } = &s.preview else {
        return Ok(());
    };
    let Some(range) = lines.get(index).cloned() else {
        return Ok(());
    };
    let Some(node) = tx.children(row)?.next() else {
        return Ok(());
    };
    let node = tx.downcast::<Text>(node)?;
    tx.set_text(node, &text[range.clone()])?;
    let first = spans.partition_point(|sp| sp.end <= range.start);
    let line_spans: Vec<TextSpan> = spans[first..]
        .iter()
        .take_while(|sp| sp.start < range.end)
        .map(|sp| {
            span_for(
                sp.class,
                sp.start.max(range.start) - range.start..sp.end.min(range.end) - range.start,
            )
        })
        .collect();
    tx.set_text_spans(node, &line_spans)
}

/// A syntax class's look, from the theme's colors, so it follows light, dark, and the
/// Omarchy theme.
fn span_for(class: Class, range: std::ops::Range<usize>) -> TextSpan {
    let span = TextSpan::new(range);
    let role = |r| Paint::Role(r);
    match class {
        Class::Keyword | Class::Heading => span.color(role(ColorRole::AccentText)).weight(700.0),
        Class::Type => span.color(role(ColorRole::AccentText)),
        Class::String | Class::Added => span.color(role(ColorRole::SuccessText)),
        Class::Number => span.color(role(ColorRole::WarningText)),
        Class::Comment => span
            .color(role(ColorRole::TextMuted))
            .slant(FontSlant::Italic),
        Class::Removed => span.color(role(ColorRole::DangerText)),
        Class::Punct => span.color(role(ColorRole::TextMuted)),
    }
}

/// The header: the path of the entry under the cursor, its folder in the accent color.
pub fn draw_header(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let dir = s.short_path(&s.cur().path);
    let dir = if dir.ends_with('/') {
        dir
    } else {
        format!("{dir}/")
    };
    let name = String::from_utf8_lossy(s.cur().current_name().unwrap_or_default());
    tx.set_text(s.ui.header, format_args!("{dir}{name}"))?;
    let span = TextSpan::new(0..dir.len())
        .color(Paint::Role(ColorRole::AccentText))
        .weight(700.0);
    tx.set_text_spans(s.ui.header, &[span])
}

/// The status line: the mode, a message or the entry's details, the keys pending, and where
/// the cursor is.
pub fn draw_status(s: &Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let visual = s.visual();
    tx.set_text(s.ui.status_mode, if visual { "VISUAL" } else { "" })?;
    tx.set_hidden(s.ui.status_mode, !visual)?;
    let (left, role) = match (&s.message, s.cur().current()) {
        (Some((m, error)), _) => (
            m.clone(),
            if *error {
                ColorRole::DangerText
            } else {
                ColorRole::Text
            },
        ),
        (None, Some(e)) => {
            let kind = match e.kind {
                Kind::Dir => 'd',
                Kind::File if e.link => 'l',
                Kind::File => '-',
                Kind::Other if e.link => 'l',
                Kind::Other => '?',
            };
            let size = if e.kind == Kind::Dir {
                String::new()
            } else {
                format!("{}   ", model::format_size(e.size))
            };
            let tz = s.zone.offset_at(e.mtime.div_euclid(1_000_000_000));
            let time = model::format_time(e.mtime, i64::from(tz));
            (
                format!("{kind}{}   {size}{time}", model::format_mode(e.mode)),
                ColorRole::TextMuted,
            )
        }
        (None, None) if s.cur().error.is_some() => {
            ("Cannot read this folder".into(), ColorRole::TextMuted)
        }
        (None, None) => (String::new(), ColorRole::TextMuted),
    };
    tx.set_text(s.ui.status_left, &left)?;
    tx.set_color(s.ui.status_left, Paint::Role(role))?;
    let k = s.keys.context();
    let count = k.count.map(|n| n.to_string()).unwrap_or_default();
    tx.set_text(
        s.ui.status_keys,
        format_args!("{count}{}", keys::format(&k.pending)),
    )?;

    let mut right = String::new();
    if visual {
        let (lo, hi) = range(s);
        right += &format!("{} in range   ", hi - lo + 1);
    }
    if !s.cur().marks.is_empty() {
        right += &format!("{} marked   ", s.cur().marks.len());
    }
    if !s.cur().filter.is_empty() {
        right += &format!("filter: {}   ", s.cur().filter);
    }
    if s.options.show_hidden {
        right += "hidden   ";
    }
    let sort = s.options.sort;
    if sort.key != strider_core::options::SortKey::Name || sort.descending {
        let name = format!("{:?}", sort.key).to_lowercase();
        right += &format!("{name}{}   ", if sort.descending { " ↓" } else { "" });
    }
    let n = s.cur().len();
    right += &if n == 0 {
        "0/0".into()
    } else {
        format!("{}/{n}", s.cur().cursor + 1)
    };
    tx.set_text(s.ui.status_right, &right)
}

/// Fills a column's row with entry `index`: its icon, its name in the color of its kind,
/// and in the current column its size.
fn fill_row(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: &Event, col: Col) -> Result<()> {
    let EventData::Row { index, row, fresh } = ev.data else {
        return Ok(());
    };
    if fresh {
        tx.update_style(row, |st| st.gap = 6.0)?;
        let mark = tx.flex(row, Style::new().size(3.0, ROW_HEIGHT - 8.0).shrink(0.0))?;
        tx.set_radius(mark, 1.5)?;
        let theme = tx.theme(row)?;
        let icon = theme.len(theme.styles.list.icon);
        tx.canvas(row, Style::new().size(icon, icon))?;
        let name = widgets::label(tx, row, "", TextKind::Body)?;
        tx.update_style(name, |st| {
            st.grow = 1.0;
            st.max_lines = 1;
        })?;
        let size = widgets::label(tx, row, "", TextKind::Small)?;
        tx.update_style(size, |st| st.max_lines = 1)?;
    }
    let theme = tx.theme(row)?;
    let px = theme.len(theme.styles.list.icon) as u32;
    let mime = s
        .folder(col)
        .map_or("application/octet-stream", |f| f.type_at(index));
    let painter = match &mut s.icons {
        Some(icons) => icons.painter(&s.db, mime, px),
        None => None,
    };
    let Some(f) = s.folder(col) else {
        return Ok(());
    };
    let Some(e) = f.entry(index).copied() else {
        return Ok(());
    };
    let name = String::from_utf8_lossy(f.listing.name(&e)).into_owned();
    let marked = f.index(index).is_some_and(|i| f.marks.contains(&i))
        || col == Col::Current && s.visual() && (range(s).0..=range(s).1).contains(&index);
    let cursor = f.cursor == index;
    let role = if cursor {
        ColorRole::Text
    } else if marked {
        ColorRole::WarningText
    } else if e.kind == Kind::Dir {
        ColorRole::AccentText
    } else if e.hidden {
        ColorRole::TextMuted
    } else if e.mode & 0o111 != 0 && e.kind == Kind::File {
        ColorRole::SuccessText
    } else {
        ColorRole::Text
    };
    let size = match e.kind {
        Kind::File if col != Col::Parent && s.options.show_size => model::compact_size(e.size),
        Kind::Other if e.link && col != Col::Parent && s.options.show_size => "broken link".into(),
        _ => String::new(),
    };
    let mut parts = tx.children(row)?;
    let (Some(mark), Some(canvas), Some(name_node), Some(size_node)) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Ok(());
    };
    let mark = tx.downcast::<Flex>(mark)?;
    tx.set_background(
        mark,
        if marked {
            Paint::Role(ColorRole::Warning)
        } else {
            Paint::TRANSPARENT
        },
    )?;
    let (canvas, name_node, size_node) = (
        tx.downcast::<Canvas>(canvas)?,
        tx.downcast::<Text>(name_node)?,
        tx.downcast::<Text>(size_node)?,
    );
    tx.set_painter(canvas, if s.options.icons { painter } else { None })?;
    tx.set_hidden(canvas, !s.options.icons)?;
    tx.set_text(name_node, &name)?;
    tx.set_color(name_node, Paint::Role(role))?;
    tx.update_style(name_node, |st| {
        st.font_weight = if marked { 700.0 } else { 400.0 }
    })?;
    tx.set_text(size_node, &size)?;
    tx.set_hidden(size_node, size.is_empty())?;
    tx.set_label(row, &name)
}
