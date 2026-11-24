//! The commands that change files: the register and the clipboard (yank, cut, paste), the
//! trash, deleting, renaming, creating, permissions and owners, and undo. Operations that take
//! time run as jobs (see [`tasks`](crate::tasks)); renames and new files are done at once.

use std::path::{Path, PathBuf};

use keywork::ClipboardData;
use keywork::prelude::*;
use keywork::tree::TextDecoration;
use strider_core::fsops::{self, Kind, Resolution};
use strider_core::keys::Key;
use strider_core::model;
use strider_core::uri;
use strider_machines::mode::{ModeEv, Prompt};

use crate::app::{self, Col, Strider};
use crate::ops::{self, Request};
use crate::{cache, dialogs, prompt, tasks};

/// The commands this module runs.
pub const NAMES: &[&str] = &[
    "yank",
    "cut",
    "paste",
    "paste-overwrite",
    "yank-path",
    "yank-name",
    "yank-dir",
    "trash",
    "delete",
    "restore",
    "empty-trash",
    "undo",
    "rename",
    "rename-append",
    "rename-insert",
    "create",
    "mkdir",
    "touch",
    "chmod",
    "chown",
    "trash-browse",
    "properties",
    "tasks",
    "task-down",
    "task-up",
    "task-pause",
    "task-cancel",
];

/// Runs one of [`NAMES`], with its arguments and the count typed before it.
pub fn run(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    name: &str,
    args: &str,
    count: Option<u32>,
) -> Result<()> {
    let n = count.unwrap_or(1) as usize;
    match name {
        "yank" | "cut" => take_targets(s, tx, name == "cut"),
        "paste" | "paste-overwrite" => paste(s, tx, name == "paste-overwrite"),
        "yank-path" | "yank-name" => yank_text(s, tx, name == "yank-path"),
        "yank-dir" => {
            let p = s.cur().path.to_string_lossy().into_owned();
            tx.set_clipboard(ClipboardData::new().with_text(&p));
            say(s, tx, format!("Copied {p}"), false)
        }
        "trash" => trash(s, tx),
        "delete" => delete(s, tx),
        "restore" => restore(s, tx),
        "empty-trash" => dialogs::confirm_empty_trash(s, tx),
        "undo" => {
            for _ in 0..n {
                undo_last(s, tx)?;
            }
            Ok(())
        }
        "rename" => rename(s, tx, args, Caret::Stem),
        "rename-append" => rename(s, tx, args, Caret::End),
        "rename-insert" => rename(s, tx, args, Caret::Start),
        "create" if !args.is_empty() => finish_create(s, tx, args),
        "create" => prompt::start(s, tx, Prompt::Create, "", 0, 0),
        "mkdir" | "touch" => {
            if args.is_empty() {
                return say(s, tx, format!("{name} needs a name"), true);
            }
            let name_ = unquote(args).trim_end_matches('/');
            let text = if name == "mkdir" {
                format!("{name_}/")
            } else {
                name_.to_owned()
            };
            finish_create(s, tx, &text)
        }
        "chmod" => chmod(s, tx, args),
        "chown" => chown(s, tx, args),
        "trash-browse" => {
            let files = home_trash(s).join("files");
            // The trash's folders exist once something was trashed; show it empty before.
            let _ = std::fs::create_dir_all(&files);
            app::cd(s, tx, files, None, true)
        }
        "properties" => {
            let paths = app::targets(s);
            if paths.is_empty() {
                return Ok(());
            }
            dialogs::properties(s, tx, paths)
        }
        "tasks" => tasks::toggle(s, tx),
        "task-down" => tasks::move_cursor(s, tx, n as isize),
        "task-up" => tasks::move_cursor(s, tx, -(n as isize)),
        "task-pause" => tasks::pause(s, tx),
        "task-cancel" => tasks::cancel(s, tx),
        _ => Ok(()),
    }
}

/// Says `text` in the status line.
fn say(s: &mut Strider, tx: &mut Txn<'_, Strider>, text: String, error: bool) -> Result<()> {
    s.notify(text, error);
    app::draw_status(s, tx)
}

fn unquote(s: &str) -> &str {
    let b = s.as_bytes();
    if b.len() >= 2 && (b[0] == b'"' || b[0] == b'\'') && b[b.len() - 1] == b[0] {
        &s[1..s.len() - 1]
    } else {
        s
    }
}

fn name_of(p: &Path) -> String {
    String::from_utf8_lossy(model::basename(p)).into_owned()
}

/// The home trash, `$XDG_DATA_HOME/Trash`; under the sample home in tests and scenes, which
/// keep no state.
pub fn home_trash(s: &Strider) -> PathBuf {
    if s.state_dir.is_none() {
        return s.home.join(".local/share/Trash");
    }
    keywork::desktop::basedir::BaseDirs::from_env()
        .data_home
        .join("Trash")
}

/// Whether the current folder is a trash's files, which hold no pastes.
pub fn in_trash(s: &Strider) -> bool {
    let p = &s.cwd;
    p.file_name().is_some_and(|n| n == "files")
        && p.parent()
            .and_then(Path::file_name)
            .is_some_and(|n| n == "Trash" || n.to_string_lossy().starts_with(".Trash"))
}

// The register --------------------------------------------------------------------------------

/// Puts `paths` in the register, to paste, and draws the rows that show it again.
pub fn set(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: Vec<PathBuf>,
    cut: bool,
) -> Result<()> {
    s.ops.register = paths;
    s.ops.cut = cut;
    app::others(tx, register_shown);
    register_shown(s, tx)
}

/// The rows and the status line, as the register changed: every window shows it.
fn register_shown(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    for col in [Col::Parent, Col::Current, Col::Preview] {
        keywork::widgets::refresh_rows(tx, s.ui.lists[col as usize])?;
    }
    app::draw_status(s, tx)
}

/// How a row's name looks for the register: struck through while cut, underlined while
/// copied.
pub fn decoration(s: &Strider, path: &Path) -> TextDecoration {
    if !s.ops.register.iter().any(|p| p == path) {
        TextDecoration::NONE
    } else if s.ops.cut {
        TextDecoration::STRIKETHROUGH
    } else {
        TextDecoration::UNDERLINE
    }
}

/// yy and dd: the targets into the register and onto the clipboard.
fn take_targets(s: &mut Strider, tx: &mut Txn<'_, Strider>, cut: bool) -> Result<()> {
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    let mut data = ClipboardData::new();
    for (mime, bytes) in uri::clipboard(&paths, cut) {
        data = data.with(mime, bytes);
    }
    tx.set_clipboard(data);
    let verb = if cut { "Cut" } else { "Copied" };
    let msg = match paths.as_slice() {
        [one] => format!("{verb} “{}”", name_of(one)),
        _ => format!("{verb} {} items", paths.len()),
    };
    set(s, tx, paths, cut)?;
    app::consume_targets(s, tx)?;
    say(s, tx, msg, false)
}

/// The targets' paths or names, a line each, onto the clipboard as text.
fn yank_text(s: &mut Strider, tx: &mut Txn<'_, Strider>, paths_: bool) -> Result<()> {
    let paths = app::targets(s);
    let text = paths
        .iter()
        .map(|p| {
            if paths_ {
                p.to_string_lossy().into_owned()
            } else {
                name_of(p)
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    if text.is_empty() {
        return Ok(());
    }
    tx.set_clipboard(ClipboardData::new().with_text(&text));
    app::consume_targets(s, tx)?;
    let what = match (paths.len(), paths_) {
        (1, _) => text.as_str(),
        (_, true) => "the paths",
        (_, false) => "the names",
    };
    let msg = format!("Copied {what}");
    say(s, tx, msg, false)
}

/// p: pastes what the clipboard holds (what yy or dd put there, or files copied in another
/// file manager) here; without files on the clipboard, what yy or dd took.
fn paste(s: &mut Strider, tx: &mut Txn<'_, Strider>, replace: bool) -> Result<()> {
    if in_trash(s) {
        return say(s, tx, "Paste into a folder, not the trash".into(), true);
    }
    let dest = s.cur().path.clone();
    let offered = tx.clipboard_mimes();
    let Some(mime) = ["x-special/gnome-copied-files", "text/uri-list"]
        .into_iter()
        .find(|m| offered.iter().any(|o| o == m))
    else {
        return paste_register(s, tx, dest, replace);
    };
    let gnome = mime.starts_with("x-special");
    tx.read_clipboard(
        mime,
        app::here(
            move |s: &mut Strider, tx, data: Option<Vec<u8>>| match data {
                None => paste_register(s, tx, dest, replace),
                Some(bytes) => {
                    let text = String::from_utf8_lossy(&bytes);
                    let (cut, uris) = if gnome {
                        uri::gnome_copied(&text)
                    } else {
                        (false, &*text)
                    };
                    let paths: Vec<PathBuf> = uri::lines(uris).filter_map(uri::file_path).collect();
                    if paths.is_empty() {
                        return say(s, tx, "Only local files can be pasted here".into(), false);
                    }
                    let kind = if cut { Kind::Move } else { Kind::Copy };
                    transfer(s, tx, kind, paths, dest, replace)
                }
            },
        ),
    );
    Ok(())
}

/// Without files on the clipboard: what yy or dd took.
fn paste_register(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    dest: PathBuf,
    replace: bool,
) -> Result<()> {
    if s.ops.register.is_empty() {
        return say(s, tx, "Nothing to paste".into(), false);
    }
    let kind = if s.ops.cut { Kind::Move } else { Kind::Copy };
    let paths = s.ops.register.clone();
    transfer(s, tx, kind, paths, dest, replace)
}

fn transfer(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    kind: Kind,
    paths: Vec<PathBuf>,
    dest: PathBuf,
    replace: bool,
) -> Result<()> {
    let mut req = Request::transfer(kind, paths, dest);
    if replace {
        req = req.with_policy(Resolution::Replace);
    }
    tasks::start(s, tx, req, true)
}

/// The second key of yy, dd, dT, or dD after visual y or d, which acted at once: the same
/// key finishes the form; after d, T trashes and D deletes what it cut, which nothing moved
/// yet. True when the key was taken.
pub fn followup(s: &mut Strider, tx: &mut Txn<'_, Strider>, op: u32, key: Key) -> Result<bool> {
    let k = s.keys.context();
    if !k.pending.is_empty() || k.count.is_some() || k.question.is_some() || !key.is_char() {
        return Ok(false);
    }
    if key.code == op {
        return Ok(true);
    }
    let (t, d) = (u32::from('T'), u32::from('D'));
    if op != u32::from('d') || (key.code != t && key.code != d) {
        return Ok(false);
    }
    if s.ops.register.is_empty() || !s.ops.cut {
        return Ok(false);
    }
    let paths = std::mem::take(&mut s.ops.register);
    set(s, tx, Vec::new(), false)?;
    if key.code == t {
        let trash = home_trash(s);
        tasks::start(s, tx, Request::trash(paths, trash), true)?;
    } else {
        confirm_delete(s, tx, paths)?;
    }
    Ok(true)
}

// The trash and deleting ----------------------------------------------------------------------

fn trash(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if in_trash(s) {
        return delete(s, tx);
    }
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    let trash = home_trash(s);
    tasks::start(s, tx, Request::trash(paths, trash), true)?;
    app::consume_targets(s, tx)
}

fn delete(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    confirm_delete(s, tx, paths)?;
    // Out of visual mode, as every operator; the range stays marked, so cancelling the
    // dialog loses nothing.
    if s.visual() {
        app::send_mode(s, tx, ModeEv::VisualEnd)?;
    }
    Ok(())
}

/// Asks before deleting `paths` permanently, in a dialog, unless `confirm_delete` is off.
pub fn confirm_delete(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: Vec<PathBuf>,
) -> Result<()> {
    if !s.options.confirm_delete {
        return delete_now(s, tx, paths);
    }
    dialogs::confirm_delete(s, tx, paths)
}

/// Deletes `paths` permanently, as the dialog's Delete does.
pub fn delete_now(s: &mut Strider, tx: &mut Txn<'_, Strider>, paths: Vec<PathBuf>) -> Result<()> {
    tasks::start(s, tx, Request::delete(paths), false)?;
    app::consume_targets(s, tx)
}

/// Deletes everything in every trash, as the dialog's "Empty the trash" does.
pub fn empty_trash(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    match ops::empty_trash_request(&home_trash(s)) {
        Ok(req) => tasks::start(s, tx, req, false),
        Err(why) => say(s, tx, why.into(), false),
    }
}

fn restore(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    if !in_trash(s) {
        return say(s, tx, "Restore works in the trash (gx)".into(), true);
    }
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    match ops::restore_request(&paths) {
        Ok(req) => tasks::start(s, tx, req, true)?,
        Err(why) => s.notify(why, true),
    }
    app::consume_targets(s, tx)
}

// Undo ----------------------------------------------------------------------------------------

/// Reverses the newest step: a creation or renames at once, anything else as an operation,
/// not itself undoable.
fn undo_last(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(step) = s.ops.undo.pop() else {
        return say(s, tx, "Nothing to undo".into(), false);
    };
    match ops::undo(&step, &home_trash(s)) {
        ops::Undo::Start(req) => tasks::start(s, tx, req, false),
        ops::Undo::Done {
            message,
            error,
            select,
            touched,
        } => {
            s.notify(message, error);
            if let Some(p) = select
                && model::parent(&p) == s.cur().path
            {
                s.cur_mut().focus(model::basename(&p));
            }
            for p in &touched {
                cache::invalidate(s, tx, p)?;
            }
            app::draw_status(s, tx)
        }
    }
}

// Renaming and creating -----------------------------------------------------------------------

#[derive(Clone, Copy)]
enum Caret {
    /// The name without its extension selected (a folder's whole name).
    Stem,
    End,
    Start,
}

fn rename(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str, caret: Caret) -> Result<()> {
    let Some(e) = s.cur().current().copied() else {
        return Ok(());
    };
    let path = s.cur().listing.path_of(&e);
    if !args.is_empty() {
        return rename_to(s, tx, &path, unquote(args));
    }
    let name = name_of(&path);
    let stem = match name.rfind('.') {
        _ if e.kind == model::Kind::Dir => name.len(),
        Some(dot) if dot > 0 => dot,
        _ => name.len(),
    };
    let (anchor, head) = match caret {
        Caret::Stem => (0, stem),
        Caret::End => (stem, stem),
        Caret::Start => (0, 0),
    };
    s.wops.rename_target = Some(path);
    prompt::start(s, tx, Prompt::Rename, &name, anchor, head)
}

/// The rename prompt's Enter.
pub fn finish_rename(s: &mut Strider, tx: &mut Txn<'_, Strider>, name: &str) -> Result<()> {
    let Some(old) = s.wops.rename_target.take() else {
        return Ok(());
    };
    if name.is_empty() {
        return app::draw_status(s, tx);
    }
    rename_to(s, tx, &old, name)
}

/// Renames one file in place, recorded for undo, the cursor on it under its new name.
fn rename_to(s: &mut Strider, tx: &mut Txn<'_, Strider>, old: &Path, name: &str) -> Result<()> {
    match ops::rename_one(old, name.as_bytes()) {
        Err(why) => say(s, tx, why, true),
        Ok(new) => {
            if new != old {
                s.ops.undo.push_renames(vec![strider_core::undo::Pair {
                    from: old.to_owned(),
                    to: new,
                }]);
            }
            s.cur_mut().focus(name.as_bytes());
            let dir = model::parent(old).to_owned();
            cache::invalidate(s, tx, &dir)?;
            app::draw_status(s, tx)
        }
    }
}

/// The new-file prompt's Enter: "name" makes a file, "name/" a folder, and "a/b/c" the
/// folders on the way.
pub fn finish_create(s: &mut Strider, tx: &mut Txn<'_, Strider>, text: &str) -> Result<()> {
    if text.is_empty() {
        return app::draw_status(s, tx);
    }
    let is_dir = text.ends_with('/');
    let rel = text.trim_matches('/');
    if rel.is_empty() {
        return app::draw_status(s, tx);
    }
    let here = s.cur().path.clone();
    let full = model::join(&here, rel.as_bytes());
    if fsops::exists(&full) {
        return say(s, tx, "That name is taken".into(), true);
    }
    let parent = model::parent(&full).to_owned();
    // Folders on the way.
    let _ = std::fs::DirBuilder::new().recursive(true).create(&parent);
    let made = if is_dir {
        ops::make_dir(&parent, model::basename(&full))
    } else {
        ops::make_file(&parent, model::basename(&full))
    };
    if let Err(e) = made {
        return say(
            s,
            tx,
            format!("Could not create “{rel}”: {}", e.describe()),
            true,
        );
    }
    s.ops.undo.push_created(full);
    let first = rel.split('/').next().unwrap_or(rel);
    s.cur_mut().focus(first.as_bytes());
    cache::invalidate(s, tx, &here)?;
    app::draw_status(s, tx)
}

// Permissions and owners ----------------------------------------------------------------------

fn chmod(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    let (recursive, spec) = fsops::recursive_flag(args);
    if spec.is_empty() {
        return prompt::start(s, tx, Prompt::Command, "chmod ", 6, 6);
    }
    if !fsops::parse_mode(spec) {
        return say(
            s,
            tx,
            format!("Not a mode: {spec} (755, u+x, go-w, a=rX)"),
            true,
        );
    }
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    tasks::start(
        s,
        tx,
        Request::chmod(paths, spec.to_owned(), recursive),
        false,
    )?;
    app::consume_targets(s, tx)
}

fn chown(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    let (recursive, spec) = fsops::recursive_flag(args);
    if spec.is_empty() {
        return prompt::start(s, tx, Prompt::Command, "chown ", 6, 6);
    }
    let owner = match ops::owner::parse_owner(spec) {
        Ok(o) => o,
        Err(why) => return say(s, tx, why, true),
    };
    if owner.uid.is_none() && owner.gid.is_none() {
        return say(
            s,
            tx,
            "chown needs a user, user:group, or :group".into(),
            true,
        );
    }
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    tasks::start(s, tx, Request::chown(paths, owner, recursive), false)?;
    app::consume_targets(s, tx)
}
