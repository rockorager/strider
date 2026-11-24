//! Dialogs, where a dialog beats the status line: confirming what cannot be undone (deleting
//! permanently, emptying the trash), a conflict in an operation of several items (both files
//! compared, a choice for every later conflict), and properties (the details, permissions as
//! check boxes and as a mode, the owner). Each is a card over the window, which it dims and
//! holds the input of, driven from the keyboard: buttons and check boxes carry mnemonics,
//! underlined, that work as keys (with Alt from a text field); Enter presses the focused
//! button (Cancel when a dialog opens; Apply in properties from anywhere else); Escape
//! cancels. Quick one-key questions (a single file's conflict, bookmarks) stay in the status
//! line.

use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;

use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::tree::{Color, TextDecoration};
use keywork::widgets::{self, TextKind, Variant};
use keywork::{Editor, Error, TextSpan};
use strider_core::fsops::{self, Conflict, Resolution};
use strider_core::keys::{self, Key};
use strider_core::model;

use crate::app::{self, Col, Strider};
use crate::ops::{self, Request};
use crate::{register, tasks};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    Cancel,
    Delete,
    EmptyTrash,
    Replace,
    Skip,
    KeepBoth,
    Merge,
    Apply,
    Overwrite,
}

/// What a dialog is for.
enum Purpose {
    /// What goes.
    Delete(Vec<PathBuf>),
    EmptyTrash,
    /// "Every conflict".
    Conflict {
        all: NodeId<Flex>,
    },
    Properties(Box<Properties>),
    /// A file chooser saving over files that exist.
    Overwrite,
}

struct Properties {
    /// What changes.
    paths: Vec<PathBuf>,
    mode_field: NodeId<Editor>,
    owner_field: NodeId<Editor>,
    /// Read, write, and run for the owner, the group, and others.
    boxes: [NodeId<Flex>; 9],
    recursive: Option<NodeId<Flex>>,
    /// The mode and owner as the dialog opened, to tell what changed.
    mode0: String,
    owner0: String,
}

/// The properties dialog's mode field, owner field, and check boxes.
pub type Fields = (NodeId<Editor>, NodeId<Editor>, [NodeId<Flex>; 9]);

/// The dialog open over the window.
pub struct Dialog {
    purpose: Purpose,
    /// The scrim that dims the window and holds the card.
    scrim: NodeId<Flex>,
    /// Buttons, each with its mnemonic and what it does.
    buttons: Vec<(NodeId<Flex>, char, Action)>,
}

impl Dialog {
    pub fn is_conflict(&self) -> bool {
        matches!(self.purpose, Purpose::Conflict { .. })
    }

    pub fn is_delete(&self) -> bool {
        matches!(self.purpose, Purpose::Delete(_))
    }

    pub fn is_properties(&self) -> bool {
        matches!(self.purpose, Purpose::Properties(_))
    }

    /// The properties dialog's mode field, owner field, and check boxes.
    pub fn property_fields(&self) -> Option<Fields> {
        match &self.purpose {
            Purpose::Properties(p) => Some((p.mode_field, p.owner_field, p.boxes)),
            _ => None,
        }
    }
}

/// Starts a dialog: a card titled `title` with `description` under it, over the window,
/// which it dims and holds the input of. Returns the scrim and the card, to fill.
fn begin(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    title: &str,
    description: &str,
) -> Result<(NodeId<Flex>, NodeId<Flex>)> {
    if s.wops.dialog.is_some() {
        dismiss(s, tx)?;
    }
    let root = tx
        .parent(s.ui.which_key)?
        .ok_or(Error::Other("the which-key popup is in the window"))?;
    let root = tx.downcast::<Stack>(root)?;
    let scrim = tx.flex(
        root,
        Flex::column()
            .width(Dim::Fill)
            .height(Dim::Fill)
            .align(keywork::Align::Center)
            .justify(keywork::tree::Justify::Center),
    )?;
    tx.set_background(scrim, Paint::Color(Color::srgba(0, 0, 0, 51)))?;
    let card = widgets::dialog_panel(tx, scrim, title, description)?;
    tx.set_modal(scrim, true)?;
    Ok((scrim, card))
}

/// The card's content, between its header and its actions, in rows closer together than
/// the card's own gap.
fn content(tx: &mut Txn<'_, Strider>, card: NodeId<Flex>) -> Result<NodeId<Flex>> {
    tx.flex(card, Flex::column().gap(6.0).width(Dim::Fill))
}

/// Underlines `letter`'s first appearance in a label's text node.
fn underline(tx: &mut Txn<'_, Strider>, text: AnyNodeId, label: &str, letter: char) -> Result<()> {
    let Some(at) = label
        .char_indices()
        .find(|(_, c)| c.to_ascii_lowercase() == letter)
        .map(|(i, _)| i)
    else {
        return Ok(());
    };
    let text = tx.downcast::<Text>(text)?;
    tx.set_text_spans(
        text,
        &[TextSpan::new(at..at + letter.len_utf8()).decoration(TextDecoration::UNDERLINE)],
    )
}

/// The label's text node of a button or check box: the node after its first.
fn label_node(tx: &Txn<'_, Strider>, node: NodeId<Flex>) -> Result<Option<AnyNodeId>> {
    Ok(tx.children(node)?.nth(1))
}

fn button(
    tx: &mut Txn<'_, Strider>,
    actions: NodeId<Flex>,
    buttons: &mut Vec<(NodeId<Flex>, char, Action)>,
    label: &str,
    mnemonic: char,
    variant: Variant,
    action: Action,
) -> Result<()> {
    let b = widgets::button_variant(tx, actions, label, variant)?;
    // The buttons that are neither the default nor destructive are plain: the text color on
    // a component's gray, as GTK's are.
    if variant == Variant::Outline {
        let role = |r| Some(Paint::Role(r));
        widgets::set_overrides(
            tx,
            b,
            widgets::Overrides {
                background: role(ColorRole::Component),
                hover_background: role(ColorRole::ComponentHover),
                pressed_background: role(ColorRole::ComponentPressed),
                color: role(ColorRole::Text),
                border: role(ColorRole::Border),
                ..widgets::Overrides::default()
            },
        )?;
    }
    if let Some(t) = label_node(tx, b)? {
        underline(tx, t, label, mnemonic)?;
    }
    app::on(tx, b, Activate, move |s: &mut Strider, tx, _| {
        act(s, tx, action)
    })?;
    buttons.push((b, mnemonic, action));
    Ok(())
}

fn checkbox(
    tx: &mut Txn<'_, Strider>,
    parent: NodeId<Flex>,
    label: &str,
    mnemonic: Option<char>,
) -> Result<NodeId<Flex>> {
    let b = widgets::checkbox(tx, parent, label)?;
    if let (Some(m), Some(t)) = (mnemonic, label_node(tx, b)?) {
        underline(tx, t, label, m)?;
    }
    Ok(b)
}

/// A line of the card's text: "Key\tvalue" lines line up their values 110 pixels in.
fn lines(tx: &mut Txn<'_, Strider>, card: NodeId<Flex>, text: &str) -> Result<()> {
    let block = tx.flex(card, Flex::column().width(Dim::Fill))?;
    for l in text.lines() {
        let row = tx.flex(block, Flex::row().width(Dim::Fill))?;
        match l.split_once('\t') {
            Some((k, v)) => {
                let key = widgets::label(tx, row, k, TextKind::Body)?;
                tx.update_style(key, |st| {
                    st.width = Dim::Px(110.0);
                    st.shrink = 0.0;
                })?;
                let value = widgets::label(tx, row, v, TextKind::Body)?;
                tx.update_style(value, |st| st.min_width = 0.0)?;
            }
            None => {
                widgets::label(tx, row, l, TextKind::Body)?;
            }
        }
    }
    Ok(())
}

/// Shows the dialog, its first button (Cancel) focused, as GTK does: Enter then cancels,
/// Tab reaches the others, and each one's key presses it.
fn present(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    purpose: Purpose,
    scrim: NodeId<Flex>,
    buttons: Vec<(NodeId<Flex>, char, Action)>,
) -> Result<()> {
    if let Some(&(first, _, _)) = buttons.first()
        && !matches!(purpose, Purpose::Properties(_))
    {
        tx.focus(first)?;
    }
    // A dialog is driven from the keyboard: its focus shows from the start.
    tx.set_focus_visible(true)?;
    s.wops.dialog = Some(Dialog {
        purpose,
        scrim,
        buttons,
    });
    Ok(())
}

/// Closes the dialog without acting, the keys back to the folder.
pub fn dismiss(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(d) = s.wops.dialog.take() else {
        return Ok(());
    };
    tx.set_modal(d.scrim, false)?;
    tx.remove(d.scrim)?;
    tx.focus(s.ui.lists[Col::Current as usize])
}

/// Closes a conflict's dialog whose job ended without an answer.
pub fn dismiss_conflict(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if s.wops.dialog.as_ref().is_some_and(Dialog::is_conflict) {
        dismiss(s, tx)?;
    }
    Ok(())
}

// Deleting -----------------------------------------------------------------------------------

/// Asks before deleting `paths` permanently.
pub fn confirm_delete(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: Vec<PathBuf>,
) -> Result<()> {
    let title = match paths.as_slice() {
        [one] => format!(
            "Delete “{}” permanently?",
            String::from_utf8_lossy(model::basename(one))
        ),
        _ => format!("Delete {} items permanently?", paths.len()),
    };
    let (scrim, card) = begin(
        s,
        tx,
        &title,
        "They will not go to the trash, and this cannot be undone; folders go with everything \
         in them.",
    )?;
    if paths.len() > 1 {
        let mut list: Vec<String> = paths
            .iter()
            .take(6)
            .map(|p| String::from_utf8_lossy(model::basename(p)).into_owned())
            .collect();
        if paths.len() > 6 {
            list.push(format!("and {} more", paths.len() - 6));
        }
        lines(tx, card, &list.join("\n"))?;
    }
    let actions = widgets::dialog_actions(tx, card)?;
    let mut buttons = Vec::new();
    button(
        tx,
        actions,
        &mut buttons,
        "Cancel",
        'c',
        Variant::Outline,
        Action::Cancel,
    )?;
    button(
        tx,
        actions,
        &mut buttons,
        "Delete",
        'd',
        Variant::Danger,
        Action::Delete,
    )?;
    present(s, tx, Purpose::Delete(paths), scrim, buttons)
}

pub fn confirm_empty_trash(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let (scrim, card) = begin(
        s,
        tx,
        "Empty the trash?",
        "Everything in it is deleted permanently; this cannot be undone.",
    )?;
    let actions = widgets::dialog_actions(tx, card)?;
    let mut buttons = Vec::new();
    button(
        tx,
        actions,
        &mut buttons,
        "Cancel",
        'c',
        Variant::Outline,
        Action::Cancel,
    )?;
    button(
        tx,
        actions,
        &mut buttons,
        "Empty the trash",
        'e',
        Variant::Danger,
        Action::EmptyTrash,
    )?;
    present(s, tx, Purpose::EmptyTrash, scrim, buttons)
}

// Saving over files -----------------------------------------------------------------------

/// The file chooser saving over files that exist (`names`, in `folder`).
pub fn confirm_overwrite(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    names: &[String],
    folder: &std::path::Path,
) -> Result<()> {
    let title = match names {
        [one] => format!("Replace “{one}”?"),
        _ => format!("Replace {} files?", names.len()),
    };
    let (it, s1, they) = if names.len() == 1 {
        ("It", "s", "it")
    } else {
        ("They", "", "they")
    };
    let text = format!(
        "{it} exist{s1} in {}; saving replaces what {they} hold{s1}.",
        s.short_path(folder)
    );
    let (scrim, card) = begin(s, tx, &title, &text)?;
    if names.len() > 1 {
        let mut list: Vec<String> = names.iter().take(6).cloned().collect();
        if names.len() > 6 {
            list.push(format!("and {} more", names.len() - 6));
        }
        lines(tx, card, &list.join("\n"))?;
    }
    let actions = widgets::dialog_actions(tx, card)?;
    let mut buttons = Vec::new();
    button(
        tx,
        actions,
        &mut buttons,
        "Cancel",
        'c',
        Variant::Outline,
        Action::Cancel,
    )?;
    button(
        tx,
        actions,
        &mut buttons,
        "Replace",
        'r',
        Variant::Danger,
        Action::Overwrite,
    )?;
    present(s, tx, Purpose::Overwrite, scrim, buttons)
}

// Conflicts ----------------------------------------------------------------------------------

/// A conflict in an operation of several items: both files side by side, and whether the
/// answer goes for every later conflict.
pub fn conflict(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    request: &Request,
    c: &Conflict,
) -> Result<()> {
    let title = format!(
        "“{}” already exists",
        String::from_utf8_lossy(model::basename(&c.dst))
    );
    let text = format!(
        "{} {} items into {}",
        request.kind.doing(),
        request.sources.len(),
        s.short_path(model::parent(&c.dst))
    );
    let (scrim, card) = begin(s, tx, &title, &text)?;
    let side = |dir: bool, size: u64, mtime: i64| {
        let tz = i64::from(s.zone.offset_at(mtime.div_euclid(1_000_000_000)));
        format!(
            "{}, modified {}",
            if dir {
                "a folder".into()
            } else {
                model::format_size(size)
            },
            model::format_time(mtime, tz)
        )
    };
    let body = format!(
        "There now\t{}\nComing in\t{}",
        side(c.dst_dir, c.dst_size, c.dst_mtime),
        side(c.src_dir, c.src_size, c.src_mtime)
    );
    let body_node = content(tx, card)?;
    lines(tx, body_node, &body)?;
    let all = checkbox(tx, body_node, "Do the same for every conflict", Some('a'))?;
    let actions = widgets::dialog_actions(tx, card)?;
    let mut buttons = Vec::new();
    let mut add = |tx: &mut Txn<'_, Strider>, label, m, v, a| {
        button(tx, actions, &mut buttons, label, m, v, a)
    };
    add(tx, "Cancel", 'c', Variant::Outline, Action::Cancel)?;
    add(tx, "Skip", 's', Variant::Outline, Action::Skip)?;
    add(tx, "Keep both", 'k', Variant::Outline, Action::KeepBoth)?;
    if c.src_dir && c.dst_dir {
        add(tx, "Merge", 'm', Variant::Outline, Action::Merge)?;
    }
    add(tx, "Replace", 'r', Variant::Solid, Action::Replace)?;
    present(s, tx, Purpose::Conflict { all }, scrim, buttons)
}

// Properties ---------------------------------------------------------------------------------

/// What a properties dialog shows, read on a worker (stat can wait on the file system).
struct Facts {
    paths: Vec<PathBuf>,
    mode: u32,
    uid: u32,
    gid: u32,
    size: u64,
    mtime: i64,
    dir: bool,
    ok: bool,
    same_mode: bool,
}

fn read_facts(paths: Vec<PathBuf>) -> Facts {
    let mut f = Facts {
        paths,
        mode: 0,
        uid: 0,
        gid: 0,
        size: 0,
        mtime: 0,
        dir: false,
        ok: false,
        same_mode: true,
    };
    for (i, p) in f.paths.iter().enumerate() {
        let Ok(m) = std::fs::metadata(p) else {
            continue;
        };
        let mode = m.permissions().mode() & 0o7777;
        if i == 0 {
            f.ok = true;
            f.mode = mode;
            f.uid = m.uid();
            f.gid = m.gid();
            f.mtime = m.mtime() * 1_000_000_000 + m.mtime_nsec();
        } else if mode != f.mode {
            f.same_mode = false;
        }
        if m.is_dir() {
            f.dir = true;
        } else {
            f.size += m.size();
        }
    }
    f
}

/// Properties of `paths`: read on a worker, then shown.
pub fn properties(s: &mut Strider, tx: &mut Txn<'_, Strider>, paths: Vec<PathBuf>) -> Result<()> {
    let land = |s: &mut Strider, tx: &mut Txn<'_, Strider>, f: Facts| {
        if f.ok {
            show_properties(s, tx, f)
        } else {
            s.notify("Its properties could not be read", true);
            app::draw_status(s, tx)
        }
    };
    if s.sync_reads {
        return land(s, tx, read_facts(paths));
    }
    tx.spawn_blocking(move || read_facts(paths), app::here(land));
    Ok(())
}

const WHO: [&str; 3] = ["Owner", "Group", "Others"];
const WHAT: [&str; 3] = ["Read", "Write", "Run"];

/// A text field `width` wide, holding `text`.
fn field(
    tx: &mut Txn<'_, Strider>,
    row: NodeId<Flex>,
    text: &str,
    width: f32,
    label: &str,
) -> Result<NodeId<Editor>> {
    let e = widgets::text_field(tx, row, "")?;
    if let Some(f) = tx.parent(e)? {
        tx.update_style(f, |st| {
            st.width = Dim::Px(width);
            st.grow = 0.0;
        })?;
    }
    tx.set_text(e, text)?;
    tx.set_label(e, label)?;
    Ok(e)
}

fn show_properties(s: &mut Strider, tx: &mut Txn<'_, Strider>, f: Facts) -> Result<()> {
    let one = f.paths.len() == 1;
    let title = if one {
        String::from_utf8_lossy(model::basename(&f.paths[0])).into_owned()
    } else {
        format!("{} items", f.paths.len())
    };
    let (scrim, card) = begin(s, tx, &title, "")?;
    let mut info = format!("Location\t{}\n", s.short_path(model::parent(&f.paths[0])));
    if !f.dir || !one {
        let in_files = if f.dir {
            " in files, not counting folders"
        } else {
            ""
        };
        info += &format!("Size\t{}{in_files}\n", model::format_size(f.size));
    }
    if one {
        let tz = i64::from(s.zone.offset_at(f.mtime.div_euclid(1_000_000_000)));
        info += &format!("Modified\t{}\n", model::format_time(f.mtime, tz));
    }
    let card_ = card;
    let card = content(tx, card_)?;
    lines(tx, card, info.trim_end())?;

    // The mode, typed as chmod takes it (octal or symbolic), and the same as nine check
    // boxes.
    let mode0 = if f.same_mode {
        format!("{:04o}", f.mode)
    } else {
        String::new()
    };
    let row = |tx: &mut Txn<'_, Strider>, gap: f32| {
        tx.flex(card, Flex::row().gap(gap).align(keywork::Align::Center))
    };
    let mrow = row(tx, 10.0)?;
    widgets::label(tx, mrow, "Permissions", TextKind::Body)?;
    let mode_field = field(tx, mrow, &mode0, 120.0, "Mode, as chmod takes it")?;
    tx.update_style(mode_field, |st| st.font_family = keywork::FontFamily::Mono)?;
    let hint = widgets::label(
        tx,
        mrow,
        if f.same_mode {
            "755, u+x, go-w…"
        } else {
            "mixed: type a mode for all"
        },
        TextKind::Body,
    )?;
    tx.set_color(hint, Paint::Role(ColorRole::TextMuted))?;
    let mut boxes = Vec::new();
    for (r, who) in WHO.iter().enumerate() {
        let brow = row(tx, 14.0)?;
        let l = widgets::label(tx, brow, *who, TextKind::Body)?;
        tx.update_style(l, |st| {
            st.width = Dim::Px(80.0);
            st.shrink = 0.0;
        })?;
        for (k, what) in WHAT.iter().enumerate() {
            let bit = 0o400 >> (r * 3 + k);
            let b = checkbox(tx, brow, what, None)?;
            widgets::set_checked(tx, b, f.same_mode && f.mode & bit != 0)?;
            app::on(tx, b, Changed, |s: &mut Strider, tx, _| box_changed(s, tx))?;
            boxes.push(b);
        }
    }
    // The owner, as chown takes it.
    let owner0 = format!("{}:{}", user_name(f.uid), group_name(f.gid));
    let orow = row(tx, 10.0)?;
    let l = widgets::label(tx, orow, "Owned by", TextKind::Body)?;
    tx.update_style(l, |st| {
        st.width = Dim::Px(80.0);
        st.shrink = 0.0;
    })?;
    let owner_field = field(tx, orow, &owner0, 200.0, "Owner, user:group")?;
    let recursive = if f.dir {
        Some(checkbox(tx, card, "Apply to enclosed files", Some('e'))?)
    } else {
        None
    };
    let actions = widgets::dialog_actions(tx, card_)?;
    let mut buttons = Vec::new();
    button(
        tx,
        actions,
        &mut buttons,
        "Cancel",
        'c',
        Variant::Outline,
        Action::Cancel,
    )?;
    button(
        tx,
        actions,
        &mut buttons,
        "Apply",
        'a',
        Variant::Solid,
        Action::Apply,
    )?;
    app::on(tx, mode_field, Changed, |s: &mut Strider, tx, _| {
        mode_changed(s, tx)
    })?;
    // Typing goes to the mode, all of it selected.
    tx.set_editor_selection(mode_field, 0, mode0.len())?;
    tx.focus(mode_field)?;
    let props = Properties {
        paths: f.paths,
        mode_field,
        owner_field,
        boxes: boxes.try_into().expect("nine boxes"),
        recursive,
        mode0,
        owner0,
    };
    present(s, tx, Purpose::Properties(Box::new(props)), scrim, buttons)
}

fn props(s: &Strider) -> Option<&Properties> {
    match &s.wops.dialog.as_ref()?.purpose {
        Purpose::Properties(p) => Some(p),
        _ => None,
    }
}

/// The mode typed: the check boxes follow when it is one.
fn mode_changed(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(p) = props(s) else { return Ok(()) };
    let text = tx.editor_text(p.mode_field)?.to_string();
    let base = u32::from_str_radix(&p.mode0, 8).unwrap_or(0o644);
    let Some(mode) = fsops::apply_mode(&text, base, false, 0o022) else {
        return Ok(());
    };
    for (i, &b) in p.boxes.iter().enumerate() {
        widgets::set_checked(tx, b, mode & (0o400 >> i) != 0)?;
    }
    Ok(())
}

/// A check box flipped: the mode follows, in octal.
fn box_changed(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(p) = props(s) else { return Ok(()) };
    let mut mode = u32::from_str_radix(&p.mode0, 8).unwrap_or(0) & 0o7000;
    for (i, &b) in p.boxes.iter().enumerate() {
        if widgets::checked(tx, b)? {
            mode |= 0o400 >> i;
        }
    }
    let text = format!("{mode:04o}");
    let field = p.mode_field;
    tx.set_text(field, &text)?;
    tx.set_editor_selection(field, text.len(), text.len())
}

/// Apply: chmod and chown as operations, for what changed.
fn apply_properties(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(p) = props(s) else { return Ok(()) };
    let mode = tx.editor_text(p.mode_field)?.to_string();
    let owner = tx.editor_text(p.owner_field)?.to_string();
    let (mode, owner) = (mode.trim_matches(' '), owner.trim_matches(' '));
    let recursive = match p.recursive {
        Some(r) => widgets::checked(tx, r)?,
        None => false,
    };
    if !mode.is_empty() && !fsops::parse_mode(mode) {
        s.notify(format!("Not a mode: {mode} (755, u+x, go-w, a=rX)"), true);
        return app::draw_status(s, tx);
    }
    let ids = if owner != p.owner0 || recursive {
        match ops::owner::parse_owner(owner) {
            Ok(o) => Some(o),
            Err(why) => {
                s.notify(why, true);
                return app::draw_status(s, tx);
            }
        }
    } else {
        None
    };
    let paths = p.paths.clone();
    let mode_changed = !mode.is_empty() && (mode != p.mode0 || recursive);
    let mode = mode.to_owned();
    dismiss(s, tx)?;
    if mode_changed {
        tasks::start(s, tx, Request::chmod(paths.clone(), mode, recursive), false)?;
    }
    if let Some(o) = ids
        && (o.uid.is_some() || o.gid.is_some())
    {
        tasks::start(s, tx, Request::chown(paths, o, recursive), false)?;
    }
    Ok(())
}

fn user_name(uid: u32) -> String {
    name_by(|buf| {
        // SAFETY: every pointer is to a live local or to `buf`, whose length is passed.
        let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found = std::ptr::null_mut();
        let rc = unsafe { libc::getpwuid_r(uid, &mut pw, buf.as_mut_ptr(), buf.len(), &mut found) };
        (rc, (!found.is_null()).then_some(pw.pw_name))
    })
    .unwrap_or_else(|| uid.to_string())
}

fn group_name(gid: u32) -> String {
    name_by(|buf| {
        // SAFETY: as in user_name.
        let mut gr: libc::group = unsafe { std::mem::zeroed() };
        let mut found = std::ptr::null_mut();
        let rc = unsafe { libc::getgrgid_r(gid, &mut gr, buf.as_mut_ptr(), buf.len(), &mut found) };
        (rc, (!found.is_null()).then_some(gr.gr_name))
    })
    .unwrap_or_else(|| gid.to_string())
}

/// Calls a getpwuid_r-like function with a buffer, larger while it says ERANGE, and reads
/// the name it found, which points into the buffer.
fn name_by(
    mut f: impl FnMut(&mut [libc::c_char]) -> (libc::c_int, Option<*mut libc::c_char>),
) -> Option<String> {
    let mut buf = vec![0; 1024];
    loop {
        match f(&mut buf) {
            (libc::ERANGE, _) if buf.len() < 1 << 20 => buf.resize(buf.len() * 2, 0),
            (_, Some(name)) if !name.is_null() => {
                // SAFETY: the name is a NUL-terminated string in `buf`, which is alive.
                let c = unsafe { std::ffi::CStr::from_ptr(name) };
                return Some(c.to_string_lossy().into_owned());
            }
            _ => return None,
        }
    }
}

// Events -------------------------------------------------------------------------------------

fn act(s: &mut Strider, tx: &mut Txn<'_, Strider>, action: Action) -> Result<()> {
    let Some(d) = &s.wops.dialog else {
        return Ok(());
    };
    match action {
        Action::Cancel => cancel(s, tx),
        Action::Delete => {
            let Purpose::Delete(paths) = &d.purpose else {
                return Ok(());
            };
            let paths = paths.clone();
            dismiss(s, tx)?;
            register::delete_now(s, tx, paths)
        }
        Action::EmptyTrash => {
            dismiss(s, tx)?;
            register::empty_trash(s, tx)
        }
        Action::Replace | Action::Skip | Action::KeepBoth | Action::Merge => {
            let all = match d.purpose {
                Purpose::Conflict { all } => widgets::checked(tx, all)?,
                _ => false,
            };
            dismiss(s, tx)?;
            let r = match action {
                Action::Replace => Resolution::Replace,
                Action::Skip => Resolution::Skip,
                Action::KeepBoth => Resolution::KeepBoth,
                _ => Resolution::Merge,
            };
            tasks::answer(s, tx, r, all)
        }
        Action::Apply => apply_properties(s, tx),
        Action::Overwrite => {
            dismiss(s, tx)?;
            crate::chooser::overwrite_confirmed(s, tx)
        }
    }
}

/// Escape or Cancel: nothing happens, but a conflict cancels its operation, as in the status
/// line.
fn cancel(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(d) = &s.wops.dialog else {
        return Ok(());
    };
    let (delete, conflict) = (d.is_delete(), d.is_conflict());
    let overwrite = matches!(d.purpose, Purpose::Overwrite);
    dismiss(s, tx)?;
    // Back to the name, to type another.
    if overwrite {
        return crate::chooser::keep_editing(s, tx);
    }
    if delete {
        s.notify("Not deleted", false);
    }
    if conflict {
        return tasks::answer(s, tx, Resolution::Cancel, false);
    }
    app::draw_status(s, tx)
}

/// A key while a dialog is open, before the focused control has it: Escape cancels, a
/// mnemonic presses its button or flips its check box (with Alt in a text field), and Enter
/// applies the properties unless a button has focus. Fails with [`Error::Pass`] for the
/// focused control's keys.
pub fn key(s: &mut Strider, tx: &mut Txn<'_, Strider>, key: Key) -> Result<()> {
    let Some(d) = &s.wops.dialog else {
        return Err(Error::Pass);
    };
    let m = key.mods;
    let focused = tx.focused();
    let on_button = d.buttons.iter().any(|(b, _, _)| Some(b.any()) == focused);
    let in_field = match &d.purpose {
        Purpose::Properties(p) => {
            focused == Some(p.mode_field.any()) || focused == Some(p.owner_field.any())
        }
        _ => false,
    };
    if key.code == keys::sym::ESCAPE && !m.ctrl && !m.alt && !m.super_ {
        return cancel(s, tx);
    }
    if key.code == keys::sym::RETURN && !m.ctrl && !m.alt && !m.super_ {
        if d.is_properties() && !on_button {
            return apply_properties(s, tx);
        }
        return Err(Error::Pass);
    }
    let letter = (key.code < 128)
        .then(|| char::from_u32(key.code))
        .flatten()
        .filter(char::is_ascii_alphabetic)
        .map(|c| c.to_ascii_lowercase());
    let plain = key.is_char() && !in_field;
    let alt = m.alt && !m.ctrl && !m.super_;
    let Some(letter) = letter.filter(|_| plain || alt) else {
        return Err(Error::Pass);
    };
    if let Some(&(_, _, action)) = d.buttons.iter().find(|(_, c, _)| *c == letter) {
        return act(s, tx, action);
    }
    let flip = match &d.purpose {
        Purpose::Conflict { all } if letter == 'a' => Some(*all),
        Purpose::Properties(p) if letter == 'e' => p.recursive,
        _ => None,
    };
    match flip {
        Some(b) => {
            let on = widgets::checked(tx, b)?;
            widgets::set_checked(tx, b, !on)
        }
        None if plain => Ok(()),
        None => Err(Error::Pass),
    }
}
