//! A file chooser: the FileChooser portal's OpenFile, SaveFile, and SaveFiles
//! ([`services`](crate::services) takes the calls), served by a window of the app's own. It is
//! the app's three columns with every key, preview, and command, and a bar over the status
//! line: the request's filters and choices, the name to save as (or a path to type), and its
//! buttons. The request's lifecycle is the [`chooser`](strider_machines::chooser) statechart.
//!
//! Enter picks the file under the cursor, or the marked files when the request allows
//! several; on a folder it goes in, except when choosing folders, where it picks that folder.
//! l and double clicks go into folders and pick files. Escape (with nothing to clear) and q
//! cancel. The chooser is modal like vim: the name or path field is insert mode, the columns
//! normal mode; Escape goes from the field to the columns, and i, a, I, A, cc, and S come
//! back. The answer goes back as the portal's response: 0 with the URIs, 1 when the user
//! cancelled, 2 when the caller closed the request.

use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use keywork::Editor;
use keywork::dbus::{Array, Message, Value};
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, TextKind, Variant};
use plusthree::host::NoTimers;
use strider_core::keys::{self, Key};
use strider_core::model::{self, TypeFilter};
use strider_machines::chooser::{Chooser as Chart, ChooserEv, ChooserFx, Response};
use strider_machines::driver::Driver;
use strider_machines::keymap::KeyEv;

use crate::app::{self, Col, Strider};
use crate::folder::ChooserTypes;

/// File chooser windows' app id, for compositor rules (Hyprland's, say).
pub const APP_ID: &str = "dev.rockorager.Strider.Chooser";

/// Which call the request came as.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Kind {
    #[default]
    Open,
    Save,
    SaveFiles,
}

/// A filter as the request gave it: shown by name, and answered with as it came
/// (`current_filter`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Filter {
    pub name: String,
    /// 0 and a glob, or 1 and a MIME type.
    pub rules: Vec<(u32, String)>,
    pub types: TypeFilter,
}

/// A choice: a check box when it has no options (its value "true" or "false"), else a combo
/// box of them (its value an option's id).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Choice {
    pub id: String,
    pub label: String,
    /// Each option's id and label.
    pub options: Vec<(String, String)>,
    pub initial: String,
}

/// A FileChooser request as xdg-desktop-portal passes it: `handle o, app_id s,
/// parent_window s, title s, options a{sv}`.
#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    pub kind: Kind,
    /// The impl.portal.Request object's path, for Close.
    pub handle: String,
    pub app_id: String,
    pub parent_window: String,
    pub title: String,
    pub accept_label: String,
    pub modal: bool,
    pub multiple: bool,
    pub directory: bool,
    pub filters: Vec<Filter>,
    /// The filter shown, an index into `filters`.
    pub filter: Option<usize>,
    pub choices: Vec<Choice>,
    pub current_name: String,
    /// Where the window starts, and the name to put the cursor on there.
    pub folder: Option<PathBuf>,
    pub select: Option<Vec<u8>>,
    /// SaveFiles: the names to save in the folder picked.
    pub files: Vec<Vec<u8>>,
}

impl Request {
    /// A request of `kind` with no options.
    pub fn new(kind: Kind) -> Request {
        Request {
            kind,
            handle: String::new(),
            app_id: String::new(),
            parent_window: String::new(),
            title: String::new(),
            accept_label: String::new(),
            modal: true,
            multiple: false,
            directory: false,
            filters: Vec::new(),
            filter: None,
            choices: Vec::new(),
            current_name: String::new(),
            folder: None,
            select: None,
            files: Vec::new(),
        }
    }

    /// Reads a call's body; `None` when it is not `(osssa{sv})`. Options of the wrong type are
    /// left out, as the Zig build left them.
    pub fn parse(kind: Kind, body: &[Value]) -> Option<Request> {
        let [handle, app_id, parent, title, options] = body else {
            return None;
        };
        let options @ Value::Array(_) = options else {
            return None;
        };
        let mut r = Request::new(kind);
        r.handle = handle.as_str()?.to_owned();
        r.app_id = app_id.as_str()?.to_owned();
        r.parent_window = parent.as_str()?.to_owned();
        r.title = title.as_str()?.to_owned();
        // Chromium sends its "All Files" filter label as the title of a save dialog it gave
        // none (IDS_SAVEAS_ALL_FILES in select_file_dialog_linux_portal.cc); that is no title.
        if kind == Kind::Save && r.title == "All Files" {
            r.title.clear();
        }
        for (key, value) in options.dict_entries() {
            if let Some(key) = key.as_str() {
                r.option(key, value.unwrap_variants());
            }
        }
        Some(r)
    }

    fn option(&mut self, key: &str, v: &Value) {
        let flag = |v: &Value| match v {
            Value::Bool(b) => Some(*b),
            _ => None,
        };
        match key {
            "accept_label" => {
                if let Some(s) = v.as_str() {
                    self.accept_label = strip_mnemonic(s);
                }
            }
            "modal" => self.modal = flag(v).unwrap_or(true),
            "multiple" => self.multiple = flag(v).unwrap_or(false),
            "directory" => self.directory = flag(v).unwrap_or(false),
            "filters" => {
                self.filters = items(v).iter().filter_map(read_filter).collect();
            }
            "current_filter" => {
                let Some(f) = read_filter(v) else {
                    return;
                };
                // The same filter as one of `filters` (by name), else one more.
                match self.filters.iter().position(|x| x.name == f.name) {
                    Some(i) => self.filter = Some(i),
                    None => {
                        self.filters.push(f);
                        self.filter = Some(self.filters.len() - 1);
                    }
                }
            }
            "choices" => {
                self.choices = items(v).iter().filter_map(read_choice).collect();
            }
            "current_name" => self.current_name = v.as_str().unwrap_or("").to_owned(),
            "current_folder" => {
                if let Some(p) = byte_path(v).filter(|p| !p.is_empty()) {
                    self.folder = Some(PathBuf::from(std::ffi::OsStr::from_bytes(&p)));
                }
            }
            "current_file" => {
                if let Some(p) = byte_path(v).filter(|p| !p.is_empty()) {
                    let p = PathBuf::from(std::ffi::OsStr::from_bytes(&p));
                    self.folder = Some(model::parent(&p).to_owned());
                    let name = model::basename(&p).to_vec();
                    if self.current_name.is_empty() {
                        self.current_name = String::from_utf8_lossy(&name).into_owned();
                    }
                    self.select = Some(name);
                }
            }
            "files" => {
                self.files = items(v)
                    .iter()
                    .map_while(byte_path)
                    .filter(|n| !n.is_empty())
                    .map(|n| model::basename(Path::new(std::ffi::OsStr::from_bytes(&n))).to_vec())
                    .collect();
            }
            _ => {}
        }
    }

    /// The window's title: the request's, else one for what it chooses.
    pub fn window_title(&self) -> &str {
        if !self.title.is_empty() {
            return &self.title;
        }
        match self.kind {
            Kind::Open if self.directory && self.multiple => "Choose Folders",
            Kind::Open if self.directory => "Choose a Folder",
            Kind::Open if self.multiple => "Open Files",
            Kind::Open => "Open a File",
            Kind::Save => "Save a File",
            Kind::SaveFiles => "Choose a Folder to Save In",
        }
    }

    fn accept_text(&self) -> &str {
        if !self.accept_label.is_empty() {
            return &self.accept_label;
        }
        match self.kind {
            Kind::Open if self.directory => "Choose",
            Kind::Open => "Open",
            Kind::Save | Kind::SaveFiles => "Save",
        }
    }

    /// Whether picking takes folders (OpenFile with directory, SaveFiles).
    pub fn picks_folders(&self) -> bool {
        self.kind == Kind::SaveFiles || (self.kind == Kind::Open && self.directory)
    }

    /// The filter the columns show, if any.
    pub fn types(&self) -> Option<&Filter> {
        // Filters only make sense for files.
        if self.picks_folders() {
            return None;
        }
        let i = self
            .filter
            .or_else(|| (!self.filters.is_empty()).then_some(0))?;
        self.filters.get(i)
    }

    /// The keys that matter here, in the path field while it is empty.
    fn hint(&self) -> &'static str {
        match self.kind {
            Kind::Open if self.directory && self.multiple => {
                "Enter chooses the folder under the cursor, or the marked ones · Space marks · \
                 l goes in · i types a path · Esc cancels"
            }
            Kind::Open if self.directory => {
                "Enter chooses the folder under the cursor · l goes in · i types a path · Esc \
                 cancels"
            }
            Kind::Open if self.multiple => {
                "Enter opens the file, or the marked ones · Space marks · i types a path · Esc \
                 cancels"
            }
            Kind::Open => "Enter opens the file · i types a path · Esc cancels",
            Kind::Save => "",
            Kind::SaveFiles => {
                "Enter chooses the folder under the cursor, else this folder · l goes in · \
                 i types a path · Esc cancels"
            }
        }
    }
}

fn items(v: &Value) -> &[Value] {
    v.as_array().map(Array::items).unwrap_or_default()
}

/// `(sa(us))`: a name and its rules.
fn read_filter(v: &Value) -> Option<Filter> {
    let Value::Struct(fields) = v else {
        return None;
    };
    let [name, rules] = fields.as_slice() else {
        return None;
    };
    let mut f = Filter {
        name: name.as_str()?.to_owned(),
        ..Filter::default()
    };
    for rule in items(rules) {
        let Value::Struct(r) = rule else {
            continue;
        };
        let [Value::U32(kind), pattern] = r.as_slice() else {
            continue;
        };
        let Some(pattern) = pattern.as_str() else {
            continue;
        };
        f.rules.push((*kind, pattern.to_owned()));
        if *kind == 0 {
            f.types.globs.push(pattern.to_lowercase());
        } else {
            f.types.mimes.push(pattern.to_owned());
        }
    }
    Some(f)
}

/// `(ssa(ss)s)`: an id, a label, options, and the initial value.
fn read_choice(v: &Value) -> Option<Choice> {
    let Value::Struct(fields) = v else {
        return None;
    };
    let [id, label, options, initial] = fields.as_slice() else {
        return None;
    };
    let options = items(options)
        .iter()
        .filter_map(|o| match o {
            Value::Struct(f) => match f.as_slice() {
                [a, b] => Some((a.as_str()?.to_owned(), b.as_str()?.to_owned())),
                _ => None,
            },
            _ => None,
        })
        .collect();
    Some(Choice {
        id: id.as_str()?.to_owned(),
        label: strip_mnemonic(label.as_str()?),
        options,
        initial: initial.as_str().unwrap_or("").to_owned(),
    })
}

/// An `ay` holding a NUL-terminated path, without the NUL.
fn byte_path(v: &Value) -> Option<Vec<u8>> {
    let a = v.as_array()?;
    let mut out = Vec::new();
    for b in a.items() {
        match b {
            Value::Byte(0) => break,
            Value::Byte(b) => out.push(*b),
            _ => return None,
        }
    }
    Some(out)
}

/// "_Open" is "Open": GTK's mnemonic marks, which the bar does not use; "__" is "_".
pub fn strip_mnemonic(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '_' {
            out.push(c);
        } else if chars.peek() == Some(&'_') {
            out.push('_');
            chars.next();
        }
    }
    out
}

// The chooser -------------------------------------------------------------------------------

/// A request and the window that serves it.
pub struct Chooser {
    /// Tells this chooser's type filter from another's on the folders they share.
    pub id: u64,
    pub window: WindowId,
    pub req: Request,
    /// The reply to the call, to fill in with the answer; none for a scene's chooser.
    call: Option<Message>,
    chart: Driver<Chart, ()>,
    pub bar: Option<Bar>,
    /// What the answer gives, once picked.
    picked: Vec<PathBuf>,
    /// The files the overwrite dialog asks about, and their folder.
    asking: (Vec<String>, PathBuf),
    /// Insert mode came from a key, which placed the caret itself: the field's focus event
    /// leaves its text alone.
    inserting: bool,
    /// The size it opened at, and the size it has now, in logical pixels.
    pub opened: [u32; 2],
    pub size: [u32; 2],
}

/// The bar's controls.
pub struct Bar {
    pub field: NodeId<Editor>,
    pub filter: Option<NodeId<Flex>>,
    /// Each choice's check box or combo box, as the request lists them.
    pub choices: Vec<NodeId<Flex>>,
    pub accept: NodeId<Flex>,
    pub cancel: NodeId<Flex>,
}

/// The chooser this window serves, if it is one.
pub fn of(s: &Strider) -> Option<&Chooser> {
    let window = s.wins.get(s.cur)?.window;
    s.services.choosers.iter().find(|c| c.window == window)
}

fn of_mut(s: &mut Strider) -> Option<&mut Chooser> {
    let window = s.wins.get(s.cur)?.window;
    s.services.choosers.iter_mut().find(|c| c.window == window)
}

/// Whether window `id` serves a chooser.
pub fn is_chooser(s: &Strider, id: WindowId) -> bool {
    s.services.choosers.iter().any(|c| c.window == id)
}

/// The size a new chooser opens at: the one the user last gave a chooser, else the
/// `chooser_size` option.
pub fn size(s: &Strider) -> [u32; 2] {
    s.services.size.unwrap_or(s.options.chooser_size)
}

/// `:set chooser_size`: the option wins over the size remembered again.
pub fn forget_size(s: &mut Strider) {
    s.services.size = None;
    if let Some(dir) = &s.state_dir {
        let _ = strider_core::state::save_chooser_size(dir, None);
    }
}

/// Opens a chooser window for `req`, answered with `call`, the reply to the call that asked
/// for it: in the folder it asked for, else where the last chooser picked, else home. A
/// window that cannot open answers 2.
pub fn open(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    req: Request,
    call: Option<Message>,
) -> Result<WindowId> {
    let window = match cx.open_window(desc(s, &req)) {
        Ok(window) => window,
        Err(e) => {
            if let Some(call) = call {
                crate::services::answer(cx, call, answer_body(Response::Ended, &[], &req, &[]));
            }
            return Err(e);
        }
    };
    let ui = cx.update(window, app::build)?;
    let (start, select) = adopt(s, window, ui, req, call);
    cx.update(window, |tx| first_show(s, tx, start, select))?;
    crate::instance::window_opened(s, cx);
    if s.icons.is_none() {
        crate::load_icons(s, cx)?;
    }
    Ok(window)
}

/// Opens a chooser window for `req` before the app runs, answering no call, for scenes.
pub fn open_in(app: &mut App<Strider>, s: &mut Strider, req: Request) -> Result<WindowId> {
    let window = app.open_window(desc(s, &req))?;
    let ui = app.update(window, app::build)?;
    let (start, select) = adopt(s, window, ui, req, None);
    app.update(window, |tx| first_show(s, tx, start, select))?;
    Ok(window)
}

/// What a chooser window opens as: the request's title, the chooser's app id, and the size
/// the user last gave a chooser, above the window that asked, modal unless the request says
/// otherwise. Its least size fits the columns and the bar on a 1366x768 screen, unless
/// `chooser_size` asks for less, as the Zig build's: Hyprland opens a floating dialog at it.
fn desc(s: &Strider, req: &Request) -> WindowDesc {
    let [w, h] = size(s);
    let [least_w, least_h] = s.options.chooser_size;
    WindowDesc::new(req.window_title())
        .app_id(APP_ID)
        .size(w, h)
        .min_size(least_w.min(800), least_h.min(500))
        .parent_window(&req.parent_window)
        .modal(req.modal)
}

/// Makes `window`, its tree built as `ui`, the app's and `req`'s; returns where it starts
/// and the name to put the cursor on there.
fn adopt(
    s: &mut Strider,
    window: WindowId,
    ui: app::Ui,
    mut req: Request,
    call: Option<Message>,
) -> (PathBuf, Option<Vec<u8>>) {
    if req.filter.is_none() && !req.filters.is_empty() {
        req.filter = Some(0);
    }
    let start = req
        .folder
        .clone()
        .or_else(|| s.services.last_folder.clone())
        .unwrap_or_else(|| s.home.clone());
    let select = req.select.clone();
    app::adopt(s, window, ui, &start);
    let opened = size(s);
    s.services.next_id += 1;
    s.services.choosers.push(Chooser {
        id: s.services.next_id,
        window,
        req,
        call,
        chart: Driver::new(Chart::machine(), ()),
        bar: None,
        picked: Vec::new(),
        asking: (Vec::new(), PathBuf::new()),
        inserting: false,
        opened,
        size: opened,
    });
    (start, select)
}

/// The window's first folder, with the bar.
fn first_show(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    start: PathBuf,
    select: Option<Vec<u8>>,
) -> Result<()> {
    build(s, tx)?;
    app::show_start(s, tx, start, select.as_deref())?;
    shown(s, tx)
}

/// Builds the bar in this window, between the columns and the status line: a row of the
/// request's filters and choices, which wraps, over a row of the name to save as (or a
/// path) and the buttons. Only the field gives way when the window is narrow, so the buttons
/// always show.
pub fn build(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(ch) = of(s) else {
        return Ok(());
    };
    let req = ch.req.clone();
    let status = tx
        .parent(s.ui.status_left)?
        .ok_or(keywork::Error::Other("the status line is in the window"))?;
    let status = tx.downcast::<Flex>(status)?;
    let body = tx
        .parent(status)?
        .ok_or(keywork::Error::Other("the status line is in the window"))?;
    let body = tx.downcast::<Flex>(body)?;
    let bar = tx.flex(
        body,
        Flex::column()
            .width(Dim::Fill)
            .gap(8.0)
            .padding(Insets::new(8.0, 12.0, 8.0, 12.0)),
    )?;
    tx.move_before(bar, status)?;
    tx.set_label(bar, "File chooser")?;
    let has_filter = !req.filters.is_empty() && !req.picks_folders();
    let mut filter = None;
    let mut choices = Vec::new();
    if has_filter || !req.choices.is_empty() {
        let opts = tx.flex(
            bar,
            Flex::row()
                .width(Dim::Fill)
                .gap(10.0)
                .align(keywork::Align::Center),
        )?;
        tx.update_style(opts, |st| st.wrap = true)?;
        if has_filter {
            let names: Vec<&str> = req.filters.iter().map(|f| f.name.as_str()).collect();
            let combo = widgets::combo_box(tx, opts, "Filter", &names, req.filter.or(Some(0)))?;
            limit_combo(tx, combo)?;
            app::on(tx, combo, Changed, |s: &mut Strider, tx, ev| {
                if let EventData::Index(i) = ev.data {
                    set_filter(s, tx, i)?;
                }
                Ok(())
            })?;
            filter = Some(combo);
        }
        for c in &req.choices {
            if c.options.is_empty() {
                let b = widgets::checkbox(tx, opts, &c.label)?;
                widgets::set_checked(tx, b, c.initial == "true")?;
                fixed(tx, b)?;
                choices.push(b);
                continue;
            }
            // The label and its combo box wrap together.
            let pair = tx.flex(opts, Flex::row().gap(6.0).align(keywork::Align::Center))?;
            let l = widgets::label(tx, pair, &c.label, TextKind::Body)?;
            fixed(tx, l)?;
            let labels: Vec<&str> = c.options.iter().map(|o| o.1.as_str()).collect();
            let selected = c.options.iter().position(|o| o.0 == c.initial).unwrap_or(0);
            let combo = widgets::combo_box(tx, pair, &c.label, &labels, Some(selected))?;
            limit_combo(tx, combo)?;
            choices.push(combo);
        }
    }
    let row = tx.flex(
        bar,
        Flex::row()
            .width(Dim::Fill)
            .gap(10.0)
            .align(keywork::Align::Center),
    )?;
    let name = if req.kind == Kind::Save {
        "Name"
    } else {
        "Path"
    };
    let l = widgets::label(tx, row, name, TextKind::Body)?;
    fixed(tx, l)?;
    let field = widgets::text_field(tx, row, req.hint())?;
    tx.set_label(field, name)?;
    // As tall as the Zig build's field, 24 px, its text the size it is.
    widgets::set_overrides(
        tx,
        field,
        widgets::Overrides {
            height: Some(24.0),
            ..widgets::Overrides::default()
        },
    )?;
    if let Some(f) = tx.parent(field)? {
        tx.update_style(f, |st| {
            st.width = Dim::Auto;
            st.grow = 1.0;
            st.shrink = 1.0;
            st.basis = Some(Dim::Px(0.0));
            st.min_width = 60.0;
        })?;
    }
    if req.kind == Kind::Save {
        tx.set_text(field, &req.current_name)?;
        // The name without its extension selected, ready to type over.
        tx.set_editor_selection(field, 0, stem(&req.current_name))?;
    }
    app::on(tx, field, Focus, |s: &mut Strider, tx, _| {
        field_focus(s, tx, true)
    })?;
    app::on(tx, field, Blur, |s: &mut Strider, tx, _| {
        field_focus(s, tx, false)
    })?;
    let cancel = widgets::button_variant(tx, row, "Cancel", Variant::Outline)?;
    let role = |r| Some(Paint::Role(r));
    widgets::set_overrides(
        tx,
        cancel,
        widgets::Overrides {
            background: role(ColorRole::Component),
            hover_background: role(ColorRole::ComponentHover),
            pressed_background: role(ColorRole::ComponentPressed),
            color: role(ColorRole::Text),
            border: role(ColorRole::Border),
            ..widgets::Overrides::default()
        },
    )?;
    fixed(tx, cancel)?;
    app::on(tx, cancel, Activate, |s: &mut Strider, tx, _| {
        step(s, tx, ChooserEv::Cancel)
    })?;
    let accept = widgets::button_variant(tx, row, req.accept_text(), Variant::Solid)?;
    fixed(tx, accept)?;
    app::on(tx, accept, Activate, |s: &mut Strider, tx, _| {
        accept_button(s, tx)
    })?;
    if let Some(ch) = of_mut(s) {
        ch.bar = Some(Bar {
            field,
            filter,
            choices,
            accept,
            cancel,
        });
    }
    // The window's size, which the next chooser opens at once the user changed it.
    let root = tx.root();
    app::on(tx, root, Resize, |s: &mut Strider, _tx, ev| {
        if let EventData::Resize(size) = ev.data
            && let Some(ch) = of_mut(s)
        {
            ch.size = [size.width.round() as u32, size.height.round() as u32];
        }
        Err(keywork::Error::Pass)
    })
}

/// A combo box as wide as its options, up to a limit, narrower when the window is.
fn limit_combo(tx: &mut Txn<'_, Strider>, combo: NodeId<Flex>) -> Result<()> {
    tx.update_style(combo, |st| {
        st.min_width = 120.0;
        st.max_width = 260.0;
        st.shrink = 1.0;
    })
}

/// Labels, boxes, and buttons keep their size; the field gives.
fn fixed<K: keywork::tree::Kind>(tx: &mut Txn<'_, Strider>, node: NodeId<K>) -> Result<()> {
    tx.update_style(node, |st| st.shrink = 0.0)
}

/// Where a name's extension starts: its length when it has none, or only a leading dot.
fn stem(name: &str) -> usize {
    match name.rfind('.') {
        Some(dot) if dot > 0 => dot,
        _ => name.len(),
    }
}

/// Once the window shows its first folder: Save starts in insert mode, in its name; the
/// others in normal mode, in the columns.
fn shown(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(ch) = of(s) else {
        return Ok(());
    };
    if let (Kind::Save, Some(bar)) = (ch.req.kind, &ch.bar) {
        tx.focus(bar.field)?;
    }
    app::draw_status(s, tx)
}

fn field(s: &Strider) -> Option<NodeId<Editor>> {
    of(s)?.bar.as_ref().map(|b| b.field)
}

/// Whether the name or path field has the keys: insert mode.
pub fn insert_mode(s: &Strider, tx: &Txn<'_, Strider>) -> bool {
    field(s).is_some_and(|f| tx.focused() == Some(f.any()))
}

/// The mode badge a chooser shows, as vim's: INSERT while typing the name or a path, NORMAL
/// while moving in the columns.
pub fn badge(s: &Strider, tx: &Txn<'_, Strider>) -> Option<&'static str> {
    of(s)?;
    Some(if insert_mode(s, tx) {
        "INSERT"
    } else {
        "NORMAL"
    })
}

/// The field's text, without spaces around it.
pub fn field_text(s: &Strider, tx: &Txn<'_, Strider>) -> String {
    field(s)
        .and_then(|f| tx.editor_text(f).ok().map(|t| t.to_string()))
        .map(|t| t.trim_matches(' ').to_owned())
        .unwrap_or_default()
}

fn set_field(s: &Strider, tx: &mut Txn<'_, Strider>, text: &str, caret: usize) -> Result<()> {
    if let Some(f) = field(s) {
        tx.set_text(f, text)?;
        tx.set_editor_selection(f, caret, caret)?;
    }
    Ok(())
}

/// Insert mode is the field having focus, however it got it (Escape, Tab, i, or a click):
/// the badge follows it. The path field starts from the folder shown, and empties again, to
/// show the keys, in normal mode.
fn field_focus(s: &mut Strider, tx: &mut Txn<'_, Strider>, gained: bool) -> Result<()> {
    let Some(ch) = of_mut(s) else {
        return Ok(());
    };
    let by_key = std::mem::take(&mut ch.inserting);
    if ch.req.kind != Kind::Save {
        if !gained {
            set_field(s, tx, "", 0)?;
            tx.set_hidden(s.ui.which_key, true)?;
        } else if !by_key && field_text(s, tx).is_empty() {
            let p = shown_path(s);
            set_field(s, tx, &p, p.len())?;
        }
    }
    app::draw_status(s, tx)
}

/// The folder shown, as the path field starts: `~` for home, and a slash to type a name
/// after.
fn shown_path(s: &Strider) -> String {
    let p = &s.cur().path;
    if p == Path::new("/") {
        return "/".into();
    }
    match p.strip_prefix(&s.home) {
        Ok(rest) if s.home != Path::new("/") && rest.as_os_str().is_empty() => "~/".into(),
        Ok(rest) if s.home != Path::new("/") => format!("~/{}/", rest.display()),
        _ => format!("{}/", p.display()),
    }
}

/// Where insert mode puts the caret.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Insert {
    /// As it was (at first, the stem selected): i.
    Keep,
    /// After the stem, before the extension: a.
    Stem,
    /// At the start: I.
    Start,
    /// At the end: A.
    End,
    /// An empty name: cc and S.
    Clear,
}

/// `:insert [stem|start|end|clear]`: the field, with the caret where vim's i, a, I, A, or
/// cc would put it.
pub fn insert_command(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    if of(s).is_none() {
        s.notify("Only a chooser has a name or path to type", true);
        return app::draw_status(s, tx);
    }
    let how = match args.trim() {
        "" => Insert::Keep,
        "stem" => Insert::Stem,
        "start" => Insert::Start,
        "end" => Insert::End,
        "clear" => Insert::Clear,
        _ => {
            s.notify("insert takes stem, start, end, or clear", true);
            return app::draw_status(s, tx);
        }
    };
    insert(s, tx, how)
}

/// Normal mode to insert mode.
fn insert(s: &mut Strider, tx: &mut Txn<'_, Strider>, how: Insert) -> Result<()> {
    let (Some(f), Some(kind)) = (field(s), of(s).map(|c| c.req.kind)) else {
        return Ok(());
    };
    // The path field fills as it takes focus; done here, as the focus event comes after.
    if kind != Kind::Save && field_text(s, tx).is_empty() {
        let p = shown_path(s);
        set_field(s, tx, &p, p.len())?;
    }
    if tx.focused() != Some(f.any())
        && let Some(ch) = of_mut(s)
    {
        ch.inserting = true;
    }
    tx.focus(f)?;
    // A path is typed at its end; only a name keeps its selection.
    let at_end = how == Insert::Keep && kind != Kind::Save;
    if how != Insert::Keep || at_end {
        let text = tx.editor_text(f)?.to_string();
        let at = match how {
            Insert::Clear | Insert::Start => 0,
            Insert::Keep | Insert::End => text.len(),
            Insert::Stem if kind != Kind::Save => text.len(),
            Insert::Stem => stem(&text),
        };
        if how == Insert::Clear {
            tx.set_text(f, "")?;
        }
        tx.set_editor_selection(f, at, at)?;
    }
    app::draw_status(s, tx)
}

/// A key in a chooser window before the keymap has it; `None` when it is the keymap's. In
/// insert mode Enter takes the field, Escape goes to the columns, and Tab goes to them from
/// a name or completes a path; other keys are the field's. In normal mode Tab goes to the
/// field, and i, a, I, A, cc, and S go to insert mode, over what the keymap binds to them
/// (create, rename, terminal).
pub fn key(s: &mut Strider, tx: &mut Txn<'_, Strider>, key: Key) -> Option<Result<()>> {
    let ch = of(s)?;
    let kind = ch.req.kind;
    let m = key.mods;
    let plain = !m.ctrl && !m.alt && !m.super_ && !m.shift;
    if insert_mode(s, tx) {
        return Some(match key.code {
            keys::sym::RETURN if plain => {
                let typed = field_text(s, tx);
                if kind == Kind::Save {
                    save_as(s, tx, &typed)
                } else {
                    go_path(s, tx, &typed)
                }
            }
            // Escape leaves insert mode for the columns, as in vim; Escape there cancels
            // once nothing is left to clear.
            keys::sym::ESCAPE if plain => tx.focus(s.ui.lists[Col::Current as usize]),
            keys::sym::TAB if plain && kind == Kind::Save => {
                tx.focus(s.ui.lists[Col::Current as usize])
            }
            keys::sym::TAB if plain => complete_path(s, tx),
            _ => Err(keywork::Error::Pass),
        });
    }
    if key.code == keys::sym::TAB && plain {
        let f = field(s)?;
        return Some(tx.focus(f));
    }
    if s.visual() || crate::tasks::is_open(s) {
        return None;
    }
    let k = s.keys.context();
    if k.count.is_some() || k.question.is_some() || !key.is_char() || m.ctrl || m.alt || m.super_ {
        return None;
    }
    let c = char::from_u32(key.code)?;
    let how = match (k.pending.as_slice(), c) {
        ([], 'i') => Insert::Keep,
        ([], 'a') => Insert::Stem,
        ([], 'I') => Insert::Start,
        ([], 'A') => Insert::End,
        ([], 'S') => Insert::Clear,
        ([p], 'c') if *p == Key::char(u32::from('c')) => Insert::Clear,
        _ => return None,
    };
    let fx = s.keys.send(KeyEv::Reset, app::Clock { tx });
    Some(app::apply_key_fx(s, tx, fx).and_then(|()| insert(s, tx, how)))
}

/// Tab in the path field: the longest common start of the names that fit, the candidates
/// shown when there are several.
fn complete_path(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let text = field_text(s, tx);
    let folders = of(s).is_some_and(|c| c.req.picks_folders());
    let (completed, candidates) = crate::commands::complete_path(s, &text, folders);
    if candidates.is_empty() {
        return Ok(());
    }
    if completed != text {
        set_field(s, tx, &completed, completed.len())?;
    }
    if candidates.len() > 1 {
        crate::prompt::show_candidates(s, tx, &candidates)
    } else {
        tx.set_hidden(s.ui.which_key, true)
    }
}

/// Shows filter `i`: the folder this window shows filters by it.
pub fn set_filter(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize) -> Result<()> {
    let Some(ch) = of_mut(s) else {
        return Ok(());
    };
    if i >= ch.req.filters.len() {
        return Ok(());
    }
    ch.req.filter = Some(i);
    apply_types(s);
    app::reload_preview(s, tx)?;
    app::draw(s, tx)
}

/// Puts this window's chooser's filter on the folder it shows; the others it showed lose it.
/// Nothing in other windows.
pub fn apply_types(s: &mut Strider) {
    let Some(ch) = of(s) else {
        return;
    };
    let (owner, filter) = (ch.id, ch.req.types().map(|f| f.types.clone()));
    let cwd = s.cwd.clone();
    let db = s.db.clone();
    let options = s.options.clone();
    for (path, c) in s.cache.dirs.iter_mut() {
        let f = &mut c.folder;
        let mine = f.chooser.as_ref().is_some_and(|t| t.owner == owner);
        if *path == cwd && path != Path::new(model::DRIVES_PATH) {
            let same = mine && f.chooser.as_ref().map(|t| &t.filter) == filter.as_ref();
            if !same {
                f.chooser = filter.clone().map(|filter| {
                    Arc::new(ChooserTypes {
                        owner,
                        filter,
                        db: db.clone(),
                    })
                });
                f.arrange(&options, None);
            }
        } else if mine {
            f.chooser = None;
            f.arrange(&options, None);
        }
    }
}

/// Takes the filter of chooser `owner` off every folder, which shows unfiltered again.
fn drop_types(s: &mut Strider, owner: u64) {
    let options = s.options.clone();
    for c in s.cache.dirs.values_mut() {
        let f = &mut c.folder;
        if f.chooser.as_ref().is_some_and(|t| t.owner == owner) {
            f.chooser = None;
            f.arrange(&options, None);
        }
    }
}

fn accept_button(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(kind) = of(s).map(|c| c.req.kind) else {
        return Ok(());
    };
    let typed = field_text(s, tx);
    if kind == Kind::Save {
        save_as(s, tx, &typed)
    } else if !typed.is_empty() {
        go_path(s, tx, &typed)
    } else {
        open_targets(s, tx)
    }
}

// Picking -----------------------------------------------------------------------------------

/// The entries Enter picks from, in the order the folder shows them: the visual range, else
/// the marked entries, else the one under the cursor; each with whether it is a folder.
fn selected(s: &Strider) -> Vec<(PathBuf, bool)> {
    let f = s.cur();
    let at = |pos: usize| {
        f.entry(pos)
            .map(|e| (f.listing.path_of(e), e.kind == model::Kind::Dir))
    };
    if s.visual() {
        let (lo, hi) = app::range(s);
        return (lo..=hi).filter_map(at).collect();
    }
    if !f.marks.is_empty() {
        return (0..f.len())
            .filter(|&pos| f.index(pos).is_some_and(|i| f.marks.contains(&i)))
            .filter_map(at)
            .collect();
    }
    at(f.cursor).into_iter().collect()
}

/// l and double clicks: into a folder, else what Enter does.
pub fn enter(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if let Some(e) = s.cur().current().copied()
        && e.kind == model::Kind::Dir
    {
        let path = s.cur().listing.path_of(&e);
        return app::cd(s, tx, path, None, true);
    }
    open_targets(s, tx)
}

/// Enter: picks what is under the cursor (or marked), or goes into a folder when picking
/// files.
pub fn open_targets(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(req) = of(s).map(|c| c.req.clone()) else {
        return Ok(());
    };
    let sel = selected(s);
    let marked = s.visual() || !s.cur().marks.is_empty();
    let several = req.multiple && (sel.len() > 1 || (sel.len() == 1 && marked));
    let current = s.cur().current().copied();
    let current_path = s.cur().current_path();
    match req.kind {
        Kind::Open | Kind::SaveFiles if req.picks_folders() => {
            let mut paths: Vec<PathBuf> = if several {
                sel.into_iter().filter(|e| e.1).map(|e| e.0).collect()
            } else {
                match (current, current_path) {
                    (Some(e), Some(p)) if e.kind == model::Kind::Dir => vec![p],
                    _ => Vec::new(),
                }
            };
            // Nothing that is a folder: the folder shown.
            if paths.is_empty() {
                paths.push(s.cwd.clone());
            }
            if req.kind == Kind::SaveFiles {
                return save_into(s, tx, paths.swap_remove(0));
            }
            answer(s, tx, paths)
        }
        Kind::Open | Kind::SaveFiles => {
            if several {
                let paths: Vec<PathBuf> = sel.into_iter().filter(|e| !e.1).map(|e| e.0).collect();
                if paths.is_empty() {
                    return say(s, tx, "Only folders are marked: mark files to open them");
                }
                return answer(s, tx, paths);
            }
            let (Some(e), Some(p)) = (current, current_path) else {
                return Ok(());
            };
            if e.kind == model::Kind::Dir {
                return app::cd(s, tx, p, None, true);
            }
            answer(s, tx, vec![p])
        }
        Kind::Save => {
            let (Some(e), Some(p)) = (current, current_path) else {
                let typed = field_text(s, tx);
                return save_as(s, tx, &typed);
            };
            if e.kind == model::Kind::Dir {
                return app::cd(s, tx, p, None, true);
            }
            // A file: saving over it, by that name.
            let name = String::from_utf8_lossy(model::basename(&p)).into_owned();
            set_field(s, tx, &name, name.len())?;
            save_as(s, tx, &name)
        }
    }
}

fn say(s: &mut Strider, tx: &mut Txn<'_, Strider>, text: impl Into<String>) -> Result<()> {
    s.notify(text, true);
    app::draw_status(s, tx)
}

#[derive(PartialEq, Eq)]
enum PathKind {
    Missing,
    File,
    Dir,
}

fn path_kind(p: &Path) -> PathKind {
    match std::fs::metadata(p) {
        Ok(m) if m.is_dir() => PathKind::Dir,
        Ok(_) => PathKind::File,
        Err(_) => PathKind::Missing,
    }
}

/// Enter on a typed path (Open and folder choosers): a folder is gone to (or, choosing
/// folders, picked), a file picked; nothing there stays in insert mode with an error.
pub fn go_path(s: &mut Strider, tx: &mut Txn<'_, Strider>, typed: &str) -> Result<()> {
    let Some(req) = of(s).map(|c| c.req.clone()) else {
        return Ok(());
    };
    if typed.is_empty() {
        return say(s, tx, "Type a path");
    }
    let p = model::normalize(&crate::commands::expand(s, typed));
    match path_kind(&p) {
        PathKind::Missing => say(s, tx, format!("No such file or folder: {typed}")),
        PathKind::Dir if req.kind == Kind::SaveFiles => save_into(s, tx, p),
        PathKind::Dir if req.picks_folders() => answer(s, tx, vec![p]),
        PathKind::Dir => {
            // Normal mode, in that folder.
            tx.focus(s.ui.lists[Col::Current as usize])?;
            app::cd(s, tx, p, None, true)
        }
        PathKind::File if req.picks_folders() => say(s, tx, "Choose a folder"),
        PathKind::File => answer(s, tx, vec![p]),
    }
}

/// Saves as `name` in the folder shown, asking before replacing a file. A path, as Emacs
/// takes one ("~/Documents/a.pdf" or "../a.pdf"), saves in that folder, which must exist.
pub fn save_as(s: &mut Strider, tx: &mut Txn<'_, Strider>, name: &str) -> Result<()> {
    if name.is_empty() {
        return say(s, tx, "Type a name to save as");
    }
    let p = if name.contains('/') {
        if name.ends_with('/') {
            return say(s, tx, "Type a name after the folder");
        }
        let full = model::normalize(&crate::commands::expand(s, name));
        if path_kind(model::parent(&full)) != PathKind::Dir {
            return say(s, tx, "No such folder");
        }
        full
    } else {
        if s.cwd == Path::new(model::DRIVES_PATH) {
            return say(s, tx, "Save in a folder, not Drives");
        }
        if name == "." || name == ".." {
            return say(s, tx, "Not a name for a file");
        }
        s.cwd.join(name)
    };
    match path_kind(&p) {
        PathKind::Missing => answer(s, tx, vec![p]),
        // A folder by that name: go in, as other choosers do.
        PathKind::Dir => app::cd(s, tx, p, None, true),
        PathKind::File => {
            let base = String::from_utf8_lossy(model::basename(&p)).into_owned();
            let folder = model::parent(&p).to_owned();
            ask(s, tx, vec![p], vec![base], folder)
        }
    }
}

/// SaveFiles: the request's names in `folder`, asking before replacing; with no names, the
/// folder itself.
fn save_into(s: &mut Strider, tx: &mut Txn<'_, Strider>, folder: PathBuf) -> Result<()> {
    let Some(files) = of(s).map(|c| c.req.files.clone()) else {
        return Ok(());
    };
    let mut paths = Vec::new();
    let mut existing = Vec::new();
    for n in &files {
        let p = folder.join(std::ffi::OsStr::from_bytes(n));
        if path_kind(&p) != PathKind::Missing {
            existing.push(String::from_utf8_lossy(n).into_owned());
        }
        paths.push(p);
    }
    if files.is_empty() {
        paths.push(folder.clone());
    }
    if existing.is_empty() {
        return answer(s, tx, paths);
    }
    ask(s, tx, paths, existing, folder)
}

/// Asks before replacing `names` in `folder`; Replace answers with `paths`.
fn ask(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: Vec<PathBuf>,
    names: Vec<String>,
    folder: PathBuf,
) -> Result<()> {
    if let Some(ch) = of_mut(s) {
        ch.picked = paths;
        ch.asking = (names, folder);
    }
    step(s, tx, ChooserEv::Ask)
}

/// Picked: response 0 with these paths, and the next chooser starts in this folder.
fn answer(s: &mut Strider, tx: &mut Txn<'_, Strider>, paths: Vec<PathBuf>) -> Result<()> {
    if let Some(ch) = of_mut(s) {
        ch.picked = paths;
    }
    step(s, tx, ChooserEv::Pick)
}

/// The overwrite dialog said Replace.
pub fn overwrite_confirmed(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    step(s, tx, ChooserEv::Replace)
}

/// The overwrite dialog was cancelled.
pub fn keep_editing(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    step(s, tx, ChooserEv::KeepEditing)
}

/// Escape with nothing to clear, q, and the Cancel button: a chooser window is cancelled.
/// Returns false in other windows.
pub fn cancel(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<bool> {
    if of(s).is_none() {
        return Ok(false);
    }
    step(s, tx, ChooserEv::Cancel)?;
    Ok(true)
}

/// The caller closed the request at `handle`: answered with 2, the window goes.
pub fn close_request(s: &mut Strider, cx: &mut Cx<'_, Strider>, handle: &str) -> Result<()> {
    let Some(window) = s
        .services
        .choosers
        .iter()
        .find(|c| !c.req.handle.is_empty() && c.req.handle == handle)
        .map(|c| c.window)
    else {
        return Ok(());
    };
    app::in_window(s, cx, Some(window), |s, tx| step(s, tx, ChooserEv::Close))
}

/// Steps this window's chooser, and carries out what it asks.
fn step(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: ChooserEv) -> Result<()> {
    let Some(ch) = of_mut(s) else {
        return Ok(());
    };
    let fx = ch.chart.send(ev, NoTimers);
    for f in fx {
        match f {
            ChooserFx::Answer(r) => {
                let Some(ch) = of(s) else {
                    continue;
                };
                let values = choice_values(ch, tx);
                let body = answer_body(r, &ch.picked, &ch.req, &values);
                if r == Response::Picked {
                    s.services.last_folder = Some(s.cwd.clone());
                }
                if let Some(call) = of_mut(s).and_then(|c| c.call.take()) {
                    tx.defer(move |_, cx| {
                        crate::services::answer(cx, call, body);
                        Ok(())
                    });
                }
            }
            ChooserFx::CloseWindow => {
                let window = s.window;
                if let Some(i) = s.services.choosers.iter().position(|c| c.window == window) {
                    let ch = s.services.choosers.remove(i);
                    let handle = ch.req.handle.clone();
                    end(s, &ch);
                    tx.defer(move |_, cx| {
                        crate::services::unexport(cx, &handle);
                        Ok(())
                    });
                    app::others(tx, app::draw);
                }
                app::close_window(s, tx)?;
            }
            ChooserFx::AskOverwrite => {
                let Some((names, folder)) = of(s).map(|c| c.asking.clone()) else {
                    continue;
                };
                crate::dialogs::confirm_overwrite(s, tx, &names, &folder)?;
            }
            ChooserFx::BackToName => {
                if let Some(f) = field(s) {
                    tx.focus(f)?;
                }
            }
        }
    }
    Ok(())
}

/// Window `id` closed: its chooser is cancelled, unless it was answered.
pub fn window_closed(s: &mut Strider, cx: &mut Cx<'_, Strider>, id: WindowId) {
    let Some(i) = s.services.choosers.iter().position(|c| c.window == id) else {
        return;
    };
    let mut ch = s.services.choosers.remove(i);
    for f in ch.chart.send(ChooserEv::WindowGone, NoTimers) {
        if let (ChooserFx::Answer(r), Some(call)) = (f, ch.call.take()) {
            crate::services::answer(cx, call, answer_body(r, &[], &ch.req, &[]));
        }
    }
    end(s, &ch);
    crate::services::unexport(cx, &ch.req.handle);
    // The other windows show the folders it filtered unfiltered.
    for w in s.window_ids() {
        if w != id {
            let _ = app::in_window(s, cx, Some(w), app::draw);
        }
    }
}

/// After the answer: the folders lose the filter, and a size the user gave the window is
/// the next chooser's, kept across starts.
fn end(s: &mut Strider, ch: &Chooser) {
    drop_types(s, ch.id);
    let [w, h] = ch.size;
    if ch.size != ch.opened && w >= 200 && h >= 150 {
        s.services.size = Some(ch.size);
        if let Some(dir) = &s.state_dir {
            let _ = strider_core::state::save_chooser_size(dir, Some(ch.size));
        }
    }
}

/// Each choice's id and value, as the bar shows it: "true" or "false" for a check box, an
/// option's id for a combo box.
fn choice_values(ch: &Chooser, tx: &Txn<'_, Strider>) -> Vec<String> {
    ch.req
        .choices
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let node = ch.bar.as_ref().and_then(|b| b.choices.get(i).copied());
            if c.options.is_empty() {
                let on = match node {
                    Some(n) => widgets::checked(tx, n).unwrap_or(false),
                    None => c.initial == "true",
                };
                return if on { "true" } else { "false" }.to_owned();
            }
            node.and_then(|n| widgets::combo_selected(tx, n).ok().flatten())
                .and_then(|k| c.options.get(k))
                .map_or_else(|| c.initial.clone(), |o| o.0.clone())
        })
        .collect()
}

/// The reply's body, `ua{sv}`: the response, and with a pick the URIs, the choices, the
/// filter shown, and for OpenFile that the files may be written.
pub fn answer_body(r: Response, paths: &[PathBuf], req: &Request, values: &[String]) -> Vec<Value> {
    let mut results = Vec::new();
    if r == Response::Picked {
        let uris = paths
            .iter()
            .map(|p| {
                let mut u = String::new();
                strider_core::uri::push_file_uri(&mut u, p);
                Value::Str(u)
            })
            .collect();
        results.push((
            "uris".to_owned(),
            Value::Array(Array::new("s", uris).expect("strings")),
        ));
        if !req.choices.is_empty() {
            let pairs = req
                .choices
                .iter()
                .zip(values)
                .map(|(c, v)| Value::Struct(vec![Value::str(&c.id), Value::str(v)]))
                .collect();
            results.push((
                "choices".to_owned(),
                Value::Array(Array::new("(ss)", pairs).expect("pairs")),
            ));
        }
        if let (Some(i), false) = (req.filter, req.picks_folders())
            && let Some(f) = req.filters.get(i)
        {
            let rules = f
                .rules
                .iter()
                .map(|(k, p)| Value::Struct(vec![Value::U32(*k), Value::str(p)]))
                .collect();
            results.push((
                "current_filter".to_owned(),
                Value::Struct(vec![
                    Value::str(&f.name),
                    Value::Array(Array::new("(us)", rules).expect("rules")),
                ]),
            ));
        }
        if req.kind == Kind::Open {
            results.push(("writable".to_owned(), Value::Bool(true)));
        }
    }
    vec![Value::U32(r as u32), Value::Array(Array::dict(results))]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(entries: Vec<(&str, Value)>) -> Value {
        Value::Array(Array::dict(
            entries.into_iter().map(|(k, v)| (k.to_owned(), v)),
        ))
    }

    fn bytes(p: &str) -> Value {
        let mut b: Vec<Value> = p.bytes().map(Value::Byte).collect();
        b.push(Value::Byte(0));
        Value::Array(Array::new("y", b).unwrap())
    }

    fn body(title: &str, options: Vec<(&str, Value)>) -> Vec<Value> {
        vec![
            Value::Path(keywork::dbus::ObjectPath::new("/r/1").unwrap()),
            Value::str("org.example.App"),
            Value::str("wayland:x"),
            Value::str(title),
            dict(options),
        ]
    }

    fn filter(name: &str, rules: &[(u32, &str)]) -> Value {
        let rules = rules
            .iter()
            .map(|(k, p)| Value::Struct(vec![Value::U32(*k), Value::str(*p)]))
            .collect();
        Value::Struct(vec![
            Value::str(name),
            Value::Array(Array::new("(us)", rules).unwrap()),
        ])
    }

    // Every option the Zig build read, as xdg-desktop-portal passes them: mnemonics gone
    // from labels, the current file's folder and name, SaveFiles' names, filters with globs
    // lowercased, a current filter matched by name or added, and choices. Catches: an option
    // read under the wrong key or type, a byte path keeping its NUL, a current filter added
    // twice.
    #[test]
    fn a_request_reads_as_the_portal_sends_it() {
        let filters = Value::Array(
            Array::new(
                "(sa(us))",
                vec![
                    filter("Images", &[(0, "*.PNG"), (1, "image/jpeg")]),
                    filter("Text", &[(0, "*.txt")]),
                ],
            )
            .unwrap(),
        );
        let options = Value::Array(
            Array::new(
                "(ss)",
                vec![
                    Value::Struct(vec![Value::str("small"), Value::str("Small")]),
                    Value::Struct(vec![Value::str("large"), Value::str("Large")]),
                ],
            )
            .unwrap(),
        );
        let choices = Value::Array(
            Array::new(
                "(ssa(ss)s)",
                vec![
                    Value::Struct(vec![
                        Value::str("size"),
                        Value::str("_Size"),
                        options,
                        Value::str("large"),
                    ]),
                    Value::Struct(vec![
                        Value::str("link"),
                        Value::str("_Link instead of copying"),
                        Value::Array(Array::new("(ss)", Vec::new()).unwrap()),
                        Value::str("false"),
                    ]),
                ],
            )
            .unwrap(),
        );
        let r = Request::parse(
            Kind::Open,
            &body(
                "Insert",
                vec![
                    ("accept_label", Value::str("_Insert")),
                    ("multiple", Value::Bool(true)),
                    ("modal", Value::Bool(false)),
                    ("filters", filters),
                    ("current_filter", filter("Text", &[(0, "*.txt")])),
                    ("choices", choices),
                    ("current_folder", bytes("/home/u/work")),
                ],
            ),
        )
        .unwrap();
        assert_eq!(r.handle, "/r/1");
        assert_eq!(r.parent_window, "wayland:x");
        assert_eq!(r.accept_label, "Insert");
        assert!(r.multiple && !r.modal && !r.directory);
        assert_eq!(r.filters.len(), 2);
        assert_eq!(r.filters[0].types.globs, ["*.png"]);
        assert_eq!(r.filters[0].types.mimes, ["image/jpeg"]);
        assert_eq!(r.filters[0].rules[0], (0, "*.PNG".to_owned()));
        assert_eq!(r.filter, Some(1));
        assert_eq!(r.choices[0].label, "Size");
        assert_eq!(r.choices[0].options[1], ("large".into(), "Large".into()));
        assert_eq!(r.choices[1].label, "Link instead of copying");
        assert_eq!(r.folder.as_deref(), Some(Path::new("/home/u/work")));
        assert_eq!(r.window_title(), "Insert");

        // A current filter by another name is one more; the current file names the folder,
        // the name under the cursor, and the name to save as; Chromium's "All Files" is no
        // title.
        let r = Request::parse(
            Kind::Save,
            &body(
                "All Files",
                vec![
                    ("current_filter", filter("PDF", &[(1, "application/pdf")])),
                    ("current_file", bytes("/home/u/a.pdf")),
                ],
            ),
        )
        .unwrap();
        assert_eq!(r.filters.len(), 1);
        assert_eq!(r.filter, Some(0));
        assert_eq!(r.folder.as_deref(), Some(Path::new("/home/u")));
        assert_eq!(r.select.as_deref(), Some(&b"a.pdf"[..]));
        assert_eq!(r.current_name, "a.pdf");
        assert_eq!(r.window_title(), "Save a File");
        assert_eq!(r.accept_text(), "Save");

        let files = Value::Array(Array::new("ay", vec![bytes("a.txt"), bytes("x/b.txt")]).unwrap());
        let r = Request::parse(Kind::SaveFiles, &body("", vec![("files", files)])).unwrap();
        assert_eq!(r.files, [b"a.txt".to_vec(), b"b.txt".to_vec()]);
        assert!(r.picks_folders());
        assert_eq!(r.window_title(), "Choose a Folder to Save In");

        // The wrong signature is refused.
        assert!(Request::parse(Kind::Open, &[Value::str("/r")]).is_none());
        assert!(Request::parse(Kind::Open, &body("", vec![])[..4]).is_none());
    }

    #[test]
    fn titles_labels_and_mnemonics() {
        assert_eq!(strip_mnemonic("_Open"), "Open");
        assert_eq!(strip_mnemonic("Save__As"), "Save_As");
        let mut r = Request::new(Kind::Open);
        assert_eq!((r.window_title(), r.accept_text()), ("Open a File", "Open"));
        r.multiple = true;
        assert_eq!(r.window_title(), "Open Files");
        r.directory = true;
        assert_eq!(
            (r.window_title(), r.accept_text()),
            ("Choose Folders", "Choose")
        );
        r.multiple = false;
        assert_eq!(r.window_title(), "Choose a Folder");
        assert_eq!(stem("report.txt"), 6);
        assert_eq!(stem(".bashrc"), 7);
        assert_eq!(stem("Makefile"), 8);
    }
}
