//! Every action is a named command, run from a key's binding or the command line: a name,
//! then its arguments, with the count typed before the keys.

use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

use keywork::prelude::*;
use keywork::widgets;
use strider_core::model::Kind;
use strider_core::options::SortKey;
use strider_core::options::{INFOS, SetError};
use strider_machines::mode::{ModeEv, Prompt};

use crate::app::{self, Col, Strider};
use crate::prompt;

/// What Tab completes in a command's argument.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Complete {
    None,
    Path,
    Dir,
    Option,
    Sort,
}

/// A command: its name, and what its argument completes to.
pub struct Command {
    pub name: &'static str,
    pub complete: Complete,
}

const fn cmd(name: &'static str, complete: Complete) -> Command {
    Command { name, complete }
}

/// Every command, as the Zig build had them, for completion; those not ported yet
/// say so when run.
pub const COMMANDS: &[Command] = &[
    cmd("down", Complete::None),
    cmd("up", Complete::None),
    cmd("top", Complete::None),
    cmd("bottom", Complete::None),
    cmd("half-down", Complete::None),
    cmd("half-up", Complete::None),
    cmd("page-down", Complete::None),
    cmd("page-up", Complete::None),
    cmd("leave", Complete::None),
    cmd("enter", Complete::None),
    cmd("open", Complete::None),
    cmd("back", Complete::None),
    cmd("forward", Complete::None),
    cmd("cd", Complete::Dir),
    cmd("fuzzy", Complete::None),
    cmd("z", Complete::None),
    cmd("zi", Complete::None),
    cmd("cd-xdg", Complete::None),
    cmd("cd-media", Complete::None),
    cmd("trash-browse", Complete::None),
    cmd("preview-down", Complete::None),
    cmd("preview-up", Complete::None),
    cmd("search", Complete::None),
    cmd("search-back", Complete::None),
    cmd("search-next", Complete::None),
    cmd("search-prev", Complete::None),
    cmd("find", Complete::None),
    cmd("filter", Complete::None),
    cmd("toggle-mark", Complete::None),
    cmd("mark-all", Complete::None),
    cmd("unmark-all", Complete::None),
    cmd("invert-marks", Complete::None),
    cmd("visual", Complete::None),
    cmd("visual-end", Complete::None),
    cmd("escape", Complete::None),
    cmd("yank", Complete::None),
    cmd("cut", Complete::None),
    cmd("paste", Complete::None),
    cmd("paste-overwrite", Complete::None),
    cmd("yank-path", Complete::None),
    cmd("yank-name", Complete::None),
    cmd("yank-dir", Complete::None),
    cmd("trash", Complete::None),
    cmd("delete", Complete::None),
    cmd("restore", Complete::None),
    cmd("empty-trash", Complete::None),
    cmd("undo", Complete::None),
    cmd("rename", Complete::None),
    cmd("rename-append", Complete::None),
    cmd("rename-insert", Complete::None),
    cmd("bulk-rename", Complete::None),
    cmd("create", Complete::None),
    cmd("mkdir", Complete::None),
    cmd("touch", Complete::None),
    cmd("open-with", Complete::None),
    cmd("chmod", Complete::None),
    cmd("chown", Complete::None),
    cmd("shell", Complete::Path),
    cmd("shell-prompt", Complete::None),
    cmd("insert", Complete::None),
    cmd("terminal", Complete::Dir),
    cmd("reload", Complete::None),
    cmd("toggle-hidden", Complete::None),
    cmd("toggle-preview", Complete::None),
    cmd("toggle-icons", Complete::None),
    cmd("sort", Complete::Sort),
    cmd("sort-reverse", Complete::None),
    cmd("sort-dirs-first", Complete::None),
    cmd("set", Complete::Option),
    cmd("bookmark-set", Complete::None),
    cmd("bookmark-jump", Complete::None),
    cmd("bookmark-remove", Complete::None),
    cmd("tab-new", Complete::Dir),
    cmd("tab-close", Complete::None),
    cmd("tab-next", Complete::None),
    cmd("tab-prev", Complete::None),
    cmd("tab", Complete::None),
    cmd("drives", Complete::None),
    cmd("mount", Complete::None),
    cmd("unmount", Complete::None),
    cmd("eject", Complete::None),
    cmd("map", Complete::None),
    cmd("unmap", Complete::None),
    cmd("help", Complete::None),
    cmd("messages", Complete::None),
    cmd("tasks", Complete::None),
    cmd("menu", Complete::None),
    cmd("properties", Complete::None),
    cmd("column-wider", Complete::None),
    cmd("column-narrower", Complete::None),
    cmd("column-reset", Complete::None),
    cmd("task-down", Complete::None),
    cmd("task-up", Complete::None),
    cmd("task-pause", Complete::None),
    cmd("task-cancel", Complete::None),
    cmd("command", Complete::None),
    cmd("new-window", Complete::None),
    cmd("quit", Complete::None),
    cmd("quit-all", Complete::None),
    cmd("q", Complete::None),
    cmd("qa", Complete::None),
];

pub fn by_name(name: &str) -> Option<&'static Command> {
    COMMANDS.iter().find(|c| c.name == name)
}

/// Runs a command line, "name args…", with the count typed before its keys, or before its
/// name at the prompt (":5down"). A bare number goes to that entry, as in vim. `from_key`
/// says it came from a binding rather than typed, which `filter` tells apart.
pub fn execute(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    line: &str,
    count: Option<u32>,
    from_key: bool,
) -> Result<()> {
    let line = line.trim_matches([' ', '\t']);
    if line.is_empty() {
        return Ok(());
    }
    let digits = line.bytes().take_while(u8::is_ascii_digit).count();
    if digits == line.len() {
        let n: usize = line.parse().unwrap_or(1);
        return app::move_cursor(s, tx, n.saturating_sub(1));
    }
    let (count, rest) = match line.as_bytes()[digits] {
        b' ' | b'\t' => (count, line),
        _ if digits > 0 => (line[..digits].parse().ok().or(count), &line[digits..]),
        _ => (count, line),
    };
    if rest.starts_with('!') {
        return not_yet(s, tx, "shell");
    }
    let (name, args) = rest
        .split_once([' ', '\t'])
        .map_or((rest, ""), |(n, a)| (n, a.trim_matches([' ', '\t'])));
    let n = count.unwrap_or(1) as usize;
    let cursor = s.cur().cursor;
    match name {
        "down" => app::move_cursor(s, tx, cursor.saturating_add(n)),
        "up" => app::move_cursor(s, tx, cursor.saturating_sub(n)),
        "top" => app::move_cursor(s, tx, count.map_or(0, |c| (c as usize).saturating_sub(1))),
        "bottom" => app::move_cursor(
            s,
            tx,
            count.map_or(usize::MAX, |c| (c as usize).saturating_sub(1)),
        ),
        "half-down" | "half-up" | "page-down" | "page-up" => {
            let rows = widgets::visible_items(tx, s.ui.lists[Col::Current as usize])?
                .len()
                .max(1);
            let step = if name.starts_with("half") {
                (rows / 2).max(1)
            } else {
                rows
            } * n;
            let pos = if name.ends_with("down") {
                cursor.saturating_add(step)
            } else {
                cursor.saturating_sub(step)
            };
            app::move_cursor(s, tx, pos)
        }
        "enter" | "open" => enter(s, tx),
        "leave" => {
            let here = s.cur().path.clone();
            match here.parent() {
                Some(up) => app::cd(
                    s,
                    tx,
                    up.to_owned(),
                    here.file_name().map(OsStrExt::as_bytes),
                    true,
                ),
                None => Ok(()),
            }
        }
        "back" | "forward" => {
            let pos = if name == "back" {
                s.history_pos.checked_sub(1)
            } else {
                Some(s.history_pos + 1)
            };
            match pos.and_then(|p| s.history.get(p).cloned().map(|path| (p, path))) {
                Some((p, path)) => {
                    s.history_pos = p;
                    app::cd(s, tx, path, None, false)
                }
                None => Ok(()),
            }
        }
        "cd" => cd(s, tx, args),
        "search" | "search-back" => {
            let back = name == "search-back";
            if args.is_empty() {
                let p = if back {
                    Prompt::SearchBack
                } else {
                    Prompt::Search
                };
                return prompt::start(s, tx, p, "", 0, 0);
            }
            s.last_search = args.to_owned();
            s.last_search_back = back;
            search_next(s, tx, false, 1)
        }
        "search-next" => search_next(s, tx, false, n),
        "search-prev" => search_next(s, tx, true, n),
        "find" => prompt::start(s, tx, Prompt::Find, "", 0, 0),
        "filter" => {
            if !from_key || !args.is_empty() {
                return prompt::set_filter(s, tx, args.to_owned(), None);
            }
            // From its key, the prompt opens on the filter there is, selected.
            let f = s.cur().filter.clone();
            prompt::start(s, tx, Prompt::Filter, &f, 0, f.len())
        }
        "command" => prompt::start(s, tx, Prompt::Command, args, args.len(), args.len()),
        "set" => set(s, tx, args),
        "map" | "unmap" => map(s, tx, name == "unmap", args),
        "toggle-hidden" => {
            s.options.show_hidden = !s.options.show_hidden;
            rearrange(s, tx)
        }
        "toggle-icons" => {
            s.options.icons = !s.options.icons;
            app::draw(s, tx)
        }
        "toggle-preview" => {
            s.options.preview = !s.options.preview;
            app::reload_preview(s, tx)?;
            app::draw(s, tx)
        }
        "sort" => {
            let mut words = args.split_whitespace();
            let Some(key) = words.next().and_then(SortKey::parse) else {
                s.notify(format!("Sort by what? {args}"), true);
                return app::draw_status(s, tx);
            };
            s.options.sort.key = key;
            s.options.sort.descending = words.next() == Some("reverse");
            rearrange(s, tx)
        }
        "sort-reverse" => {
            s.options.sort.descending = !s.options.sort.descending;
            rearrange(s, tx)
        }
        "sort-dirs-first" => {
            s.options.sort.folders_first = !s.options.sort.folders_first;
            rearrange(s, tx)
        }
        "reload" => {
            let path = s.cur().path.clone();
            let focus = s.cur().current_name().map(<[u8]>::to_vec);
            app::cd(s, tx, path, focus.as_deref(), false)
        }
        "visual" => app::send_mode(s, tx, ModeEv::Visual),
        "visual-end" => app::send_mode(s, tx, ModeEv::VisualEnd),
        "escape" => {
            if s.visual() {
                return app::send_mode(s, tx, ModeEv::VisualCancel);
            }
            if !s.cur().filter.is_empty() {
                return prompt::set_filter(s, tx, String::new(), None);
            }
            s.cur_mut().marks.clear();
            widgets::set_row_count(tx, s.ui.lists[Col::Current as usize], s.cur().len())?;
            app::draw_cursor(s, tx, Col::Current)?;
            app::draw_status(s, tx)
        }
        "toggle-mark" => {
            for _ in 0..n {
                if let Some(i) = s.cur().index(s.cur().cursor) {
                    if !s.cur_mut().marks.remove(&i) {
                        s.cur_mut().marks.insert(i);
                    }
                    s.cur_mut().cursor = (s.cur().cursor + 1).min(s.cur().len().saturating_sub(1));
                }
            }
            app::reload_preview(s, tx)?;
            app::draw(s, tx)
        }
        "mark-all" => {
            s.cur_mut().marks = s.cur().order.iter().copied().collect();
            app::draw(s, tx)
        }
        "quit" | "quit-all" => {
            tx.after(std::time::Duration::ZERO, |_, cx| {
                cx.quit();
                Ok(())
            });
            Ok(())
        }
        _ if by_name(name).is_some() => not_yet(s, tx, name),
        _ => {
            s.notify(format!("Unknown command: {name}"), true);
            app::draw_status(s, tx)
        }
    }
}

fn not_yet(s: &mut Strider, tx: &mut Txn<'_, Strider>, name: &str) -> Result<()> {
    s.notify(format!("{name} isn't in the Rust build yet"), true);
    app::draw_status(s, tx)
}

/// `n` and `N`: the last search's next match, `count` times, in its direction or against
/// it; past the end it wraps around only with `wrap_scan`.
fn search_next(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    reverse: bool,
    count: usize,
) -> Result<()> {
    if s.last_search.is_empty() {
        s.notify("No previous search", true);
        return app::draw_status(s, tx);
    }
    let back = s.last_search_back != reverse;
    let mut at = s.cur().cursor;
    for _ in 0..count.max(1) {
        let Some(next) = s.cur().find_match(&s.last_search, at, back, false) else {
            s.notify("No match", true);
            return app::draw_status(s, tx);
        };
        if !s.options.wrap_scan && (back && next > at || !back && next < at) {
            s.notify("Search hit the end", true);
            return app::draw_status(s, tx);
        }
        at = next;
    }
    app::move_cursor(s, tx, at)
}

/// `:cd`: a folder opens; a file opens its folder with the cursor on it. A path the cache
/// does not hold is looked at on a worker, so a slow file system never holds the keys.
fn cd(s: &mut Strider, tx: &mut Txn<'_, Strider>, arg: &str) -> Result<()> {
    let path = strider_core::model::normalize(&expand(s, arg));
    s.probe += 1;
    if s.cache.get(&path).is_some() {
        return app::cd(s, tx, path, None, true);
    }
    let probe = s.probe;
    let look = |path: PathBuf| {
        let kind = std::fs::metadata(&path).map(|m| m.is_dir()).ok();
        (path, kind)
    };
    let land =
        move |s: &mut Strider, tx: &mut Txn<'_, Strider>, (path, kind): (PathBuf, Option<bool>)| {
            if s.probe != probe {
                return Ok(());
            }
            match kind {
                Some(true) => app::cd(s, tx, path, None, true),
                Some(false) => {
                    let name = path.file_name().map(|n| n.as_bytes().to_vec());
                    let dir = strider_core::model::parent(&path).to_owned();
                    app::cd(s, tx, dir, name.as_deref(), true)
                }
                None => {
                    s.notify(format!("No such folder: {}", path.display()), true);
                    app::draw_status(s, tx)
                }
            }
        };
    if s.sync_reads {
        return land(s, tx, look(path));
    }
    tx.spawn_blocking(move || look(path), land);
    Ok(())
}

/// `:set name value`, then the window as the options now say.
fn set(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    if args.trim().is_empty() {
        s.notify("set needs an option", true);
        return app::draw_status(s, tx);
    }
    match s.options.set_line(args) {
        Ok(_) => apply_options(s, tx),
        Err((name, e)) => {
            let why = match e {
                SetError::UnknownOption => "no such option",
                SetError::InvalidValue => "invalid value",
            };
            s.notify(format!("set {name}: {why}"), true);
            app::draw_status(s, tx)
        }
    }
}

/// The window as the options say, after one changed.
pub fn apply_options(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let delay = std::time::Duration::from_millis(u64::from(s.options.which_key_delay));
    let fx = s.keys.send(
        strider_machines::keymap::KeyEv::SetDelay(delay),
        app::Clock { tx },
    );
    app::apply_key_fx(s, tx, fx)?;
    app::layout(s, tx)?;
    rearrange(s, tx)
}

/// `:map [mode] keys command…` and `:unmap [mode] keys`.
fn map(s: &mut Strider, tx: &mut Txn<'_, Strider>, unmap: bool, args: &str) -> Result<()> {
    use strider_core::config::Mode;
    let mut words = args.split(' ').filter(|w| !w.is_empty());
    let mut first = words.next();
    let mode = match first.and_then(Mode::parse) {
        Some(m) => {
            first = words.next();
            m
        }
        None => Mode::Normal,
    };
    let rest = words.collect::<Vec<_>>().join(" ");
    let problem = match (first, unmap) {
        (None, true) => return Ok(()),
        (None, false) => Some("map needs keys and a command"),
        (Some(keys), true) => s.keymap.unmap(mode, keys).err().map(|_| "Invalid keys"),
        (Some(_), false) if rest.is_empty() => Some("map needs a command"),
        (Some(keys), false) => s
            .keymap
            .map(mode, keys, &rest, "")
            .err()
            .map(|_| "Invalid keys"),
    };
    if let Some(p) = problem {
        s.notify(p, true);
    }
    app::draw_status(s, tx)
}

/// Completes a command line: a command's name, then its argument (folders, paths, options,
/// sort keys), as far as the candidates agree. Returns the line completed and the
/// candidates.
pub fn complete(s: &Strider, text: &str) -> (String, Vec<String>) {
    let Some(sp) = text.rfind(' ') else {
        let names = COMMANDS
            .iter()
            .filter(|c| c.name.starts_with(text))
            .map(|c| c.name.to_owned())
            .collect();
        return finish("", text, names, true);
    };
    let (head, word) = (&text[..=sp], &text[sp + 1..]);
    let name = text.split(' ').next().unwrap_or("");
    let kind = by_name(name).map_or(Complete::Path, |c| c.complete);
    let starting = |all: &mut dyn Iterator<Item = &str>| {
        all.filter(|c| c.starts_with(word))
            .map(str::to_owned)
            .collect()
    };
    let candidates = match kind {
        Complete::Option => starting(&mut INFOS.iter().map(|i| i.name)),
        Complete::Sort => {
            starting(&mut ["name", "size", "modified", "type", "extension"].into_iter())
        }
        Complete::None | Complete::Path | Complete::Dir => paths(s, word, kind == Complete::Dir),
    };
    finish(
        head,
        word,
        candidates,
        !matches!(kind, Complete::Path | Complete::Dir),
    )
}

/// The line with `word` grown to the candidates' longest common prefix, and a space after
/// the only one, unless it is a path, which may go on.
fn finish(head: &str, word: &str, candidates: Vec<String>, space: bool) -> (String, Vec<String>) {
    let Some(first) = candidates.first() else {
        return (format!("{head}{word}"), candidates);
    };
    let mut prefix = first.as_str();
    for c in &candidates[1..] {
        let common = prefix
            .char_indices()
            .zip(c.chars())
            .find(|((_, a), b)| a != b)
            .map_or(prefix.len().min(c.len()), |((i, _), _)| i);
        prefix = &prefix[..common];
    }
    let grown = if prefix.len() >= word.len() {
        prefix
    } else {
        word
    };
    let end = if candidates.len() == 1 && space {
        " "
    } else {
        ""
    };
    (format!("{head}{grown}{end}"), candidates)
}

/// Names in the folder `word` is in that start as its last part does, folders with a `/`
/// after, in natural order. Dotfiles only once a dot is typed.
fn paths(s: &Strider, word: &str, dirs_only: bool) -> Vec<String> {
    let (dir_part, name_part) = word.rfind('/').map_or(("", word), |i| word.split_at(i + 1));
    let dir = if dir_part.is_empty() {
        s.cur().path.clone()
    } else {
        expand(s, dir_part)
    };
    let Ok(read) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = read
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            if !name.starts_with(name_part) || name.starts_with('.') && !name_part.starts_with('.')
            {
                return None;
            }
            let is_dir = std::fs::metadata(e.path()).is_ok_and(|m| m.is_dir());
            if dirs_only && !is_dir {
                return None;
            }
            Some(format!("{dir_part}{name}{}", if is_dir { "/" } else { "" }))
        })
        .collect();
    names.sort_by(|a, b| strider_core::model::natural_order(a.as_bytes(), b.as_bytes()));
    names
}

/// Into the folder under the cursor. Opening files comes with the rest of opening.
fn enter(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(e) = s.cur().current().copied() else {
        return Ok(());
    };
    let path = s.cur().listing.path_of(&e);
    if e.kind == Kind::Dir {
        return app::cd(s, tx, path, None, true);
    }
    s.notify("Opening files isn't in the Rust build yet", true);
    app::draw_status(s, tx)
}

/// Sorts and filters the folders shown again, the cursors staying on their entries.
fn rearrange(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let shown = [Some(s.cwd.clone()), s.parent_path.clone()];
    for path in shown.into_iter().flatten() {
        if let Some(f) = s.cache.get_mut(&path) {
            f.arrange(&s.options, None);
        }
    }
    app::reload_preview(s, tx)?;
    app::draw(s, tx)
}

/// A path as typed: `~` is home, `$NAME` an environment variable, and a relative one is
/// under the current folder.
fn expand(s: &Strider, arg: &str) -> PathBuf {
    match arg {
        "" | "~" => s.home.clone(),
        a if a.starts_with("~/") => s.home.join(&a[2..]),
        a if a.starts_with('$') => {
            let end = a.find('/').unwrap_or(a.len());
            match std::env::var_os(&a[1..end]) {
                Some(v) => {
                    let mut p = v;
                    p.push(&a[end..]);
                    PathBuf::from(p)
                }
                None => PathBuf::from(a),
            }
        }
        a if a.starts_with('/') => PathBuf::from(a),
        a => s.cur().path.join(a),
    }
}
