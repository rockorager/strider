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
use crate::{bookmarks, columns, drives, menu, opening, picker, prompt, tabs};

/// What Tab completes in a command's argument.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Complete {
    None,
    Path,
    Dir,
    Option,
    Sort,
}

/// A command: its name, what it does, and what its argument completes to.
pub struct Command {
    pub name: &'static str,
    pub desc: &'static str,
    pub complete: Complete,
}

const fn cmd(name: &'static str, desc: &'static str, complete: Complete) -> Command {
    Command {
        name,
        desc,
        complete,
    }
}

/// Every command, for completion and help.
pub const COMMANDS: &[Command] = &[
    cmd("down", "Move down [count]", Complete::None),
    cmd("up", "Move up [count]", Complete::None),
    cmd("top", "First entry, or entry [count]", Complete::None),
    cmd("bottom", "Last entry, or entry [count]", Complete::None),
    cmd("half-down", "Half a page down", Complete::None),
    cmd("half-up", "Half a page up", Complete::None),
    cmd("page-down", "A page down", Complete::None),
    cmd("page-up", "A page up", Complete::None),
    cmd("leave", "The parent folder", Complete::None),
    cmd(
        "enter",
        "Enter the folder, or open the file",
        Complete::None,
    ),
    cmd("open", "Open the targets", Complete::None),
    cmd("back", "Back in history", Complete::None),
    cmd("forward", "Forward in history", Complete::None),
    cmd("cd", "Go to a folder (or a file's folder)", Complete::Dir),
    cmd(
        "fuzzy",
        "Find a file or folder below this one",
        Complete::None,
    ),
    cmd(
        "z",
        "Jump to zoxide's best folder for the words, or pick one",
        Complete::None,
    ),
    cmd("zi", "Pick a folder zoxide knows", Complete::None),
    cmd(
        "cd-xdg",
        "Go to an XDG user folder: DOWNLOAD, DOCUMENTS, …",
        Complete::None,
    ),
    cmd("cd-media", "Go to where drives mount", Complete::None),
    cmd("trash-browse", "Show the trash", Complete::None),
    cmd("preview-down", "Scroll the preview down", Complete::None),
    cmd("preview-up", "Scroll the preview up", Complete::None),
    cmd(
        "search",
        "Search forward (or for the argument)",
        Complete::None,
    ),
    cmd("search-back", "Search backward", Complete::None),
    cmd("search-next", "Next match", Complete::None),
    cmd("search-prev", "Previous match", Complete::None),
    cmd("find", "Jump by typing part of a name", Complete::None),
    cmd(
        "filter",
        "Show only names containing the text",
        Complete::None,
    ),
    cmd(
        "toggle-mark",
        "Mark or unmark, and move down",
        Complete::None,
    ),
    cmd("mark-all", "Mark every entry", Complete::None),
    cmd("unmark-all", "Unmark every entry", Complete::None),
    cmd("invert-marks", "Invert the marks", Complete::None),
    cmd("visual", "Visual selection", Complete::None),
    cmd(
        "visual-end",
        "End the visual selection, marking it",
        Complete::None,
    ),
    cmd(
        "escape",
        "Cancel: the filter, the visual range, the marks",
        Complete::None,
    ),
    cmd("yank", "Copy the targets", Complete::None),
    cmd("cut", "Cut the targets", Complete::None),
    cmd("paste", "Paste here", Complete::None),
    cmd("paste-overwrite", "Paste here, replacing", Complete::None),
    cmd("yank-path", "Copy the targets' paths", Complete::None),
    cmd("yank-name", "Copy the targets' names", Complete::None),
    cmd("yank-dir", "Copy the folder's path", Complete::None),
    cmd("trash", "Move the targets to the trash", Complete::None),
    cmd("delete", "Delete the targets permanently", Complete::None),
    cmd(
        "restore",
        "Restore the targets from the trash",
        Complete::None,
    ),
    cmd("empty-trash", "Empty the trash", Complete::None),
    cmd("undo", "Undo the last operation", Complete::None),
    cmd("rename", "Rename (to the argument)", Complete::None),
    cmd(
        "rename-append",
        "Rename, the caret at the end",
        Complete::None,
    ),
    cmd(
        "rename-insert",
        "Rename, the caret at the start",
        Complete::None,
    ),
    cmd(
        "bulk-rename",
        "Rename the targets in $EDITOR",
        Complete::None,
    ),
    cmd(
        "create",
        "New file, or folder with a trailing /",
        Complete::None,
    ),
    cmd("mkdir", "New folder", Complete::None),
    cmd("touch", "New file", Complete::None),
    cmd("open-with", "Open with an application", Complete::None),
    cmd(
        "chmod",
        "Permissions: chmod [-R] 755, u+x, go-w, a=rX…",
        Complete::None,
    ),
    cmd(
        "chown",
        "Owner: chown [-R] user, user:group, :group",
        Complete::None,
    ),
    cmd(
        "shell",
        "Run a shell command (-t in a terminal)",
        Complete::Path,
    ),
    cmd("shell-prompt", "Type a shell command", Complete::None),
    cmd(
        "insert",
        "Chooser: type the name or path (stem, start, end, or clear)",
        Complete::None,
    ),
    cmd("terminal", "A terminal in this folder", Complete::Dir),
    cmd("reload", "Read the folders again", Complete::None),
    cmd("toggle-hidden", "Show or hide hidden files", Complete::None),
    cmd("toggle-preview", "Show or hide the preview", Complete::None),
    cmd("toggle-icons", "Show or hide icons", Complete::None),
    cmd(
        "sort",
        "Sort by name, size, modified, type, extension [reverse]",
        Complete::Sort,
    ),
    cmd("sort-reverse", "Reverse the sort", Complete::None),
    cmd("sort-dirs-first", "Folders first, or not", Complete::None),
    cmd("set", "Set an option: set name value", Complete::Option),
    cmd(
        "bookmark-set",
        "Bookmark this folder under a key",
        Complete::None,
    ),
    cmd("bookmark-jump", "Go to a bookmark", Complete::None),
    cmd("bookmark-remove", "Remove a bookmark", Complete::None),
    cmd(
        "tab-new",
        "New tab (here, or at the argument)",
        Complete::Dir,
    ),
    cmd("tab-close", "Close the tab", Complete::None),
    cmd("tab-next", "Next tab", Complete::None),
    cmd("tab-prev", "Previous tab", Complete::None),
    cmd("tab", "Go to tab N", Complete::None),
    cmd("drives", "Show the drives", Complete::None),
    cmd("mount", "Mount a drive by name", Complete::None),
    cmd(
        "unmount",
        "Unmount the drive this folder is on (in Drives, the cursor's)",
        Complete::None,
    ),
    cmd(
        "eject",
        "Unmount and eject the drive this folder is on (in Drives, the cursor's)",
        Complete::None,
    ),
    cmd("map", "Bind keys: map [mode] keys command…", Complete::None),
    cmd("unmap", "Unbind keys: unmap [mode] keys", Complete::None),
    cmd("help", "Every key and command", Complete::None),
    cmd("messages", "Recent messages, newest first", Complete::None),
    cmd("tasks", "Open or close the tasks view", Complete::None),
    cmd("menu", "The context menu at the cursor", Complete::None),
    cmd(
        "properties",
        "The targets' details, permissions, and owner",
        Complete::None,
    ),
    cmd(
        "column-wider",
        "Widen the current column (or: column-wider parent)",
        Complete::None,
    ),
    cmd(
        "column-narrower",
        "Narrow the current column (or: column-narrower parent)",
        Complete::None,
    ),
    cmd(
        "column-reset",
        "Column widths from the ratio again",
        Complete::None,
    ),
    cmd("task-down", "The next task", Complete::None),
    cmd("task-up", "The previous task", Complete::None),
    cmd("task-pause", "Pause or resume the task", Complete::None),
    cmd(
        "task-cancel",
        "Cancel the task, or remove it when done",
        Complete::None,
    ),
    cmd("command", "Open the command line", Complete::None),
    cmd("new-window", "A new window here", Complete::None),
    cmd("quit", "Close the tab, or the window", Complete::None),
    cmd("quit-all", "Quit", Complete::None),
    cmd("q", "Close the tab, or the window", Complete::None),
    cmd("qa", "Quit", Complete::None),
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
    if let Some(cmd) = rest.strip_prefix('!') {
        let cmd = cmd.trim_matches(' ');
        if cmd.is_empty() {
            return Ok(());
        }
        return opening::run_shell(s, tx, cmd, false);
    }
    let (name, args) = rest
        .split_once([' ', '\t'])
        .map_or((rest, ""), |(n, a)| (n, a.trim_matches([' ', '\t'])));
    let n = count.unwrap_or(1) as usize;
    let cursor = s.cur().cursor;
    if let Some(why) = drives::refused(s, name) {
        s.notify(why, true);
        return app::draw_status(s, tx);
    }
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
        "enter" | "open" if drives::enter(s, tx)? => Ok(()),
        "enter" if crate::chooser::of(s).is_some() => crate::chooser::enter(s, tx),
        "open" if crate::chooser::of(s).is_some() => crate::chooser::open_targets(s, tx),
        "insert" => crate::chooser::insert_command(s, tx, args),
        "enter" => enter(s, tx),
        "open" => {
            opening::open_targets(s, tx)?;
            app::consume_targets(s, tx)
        }
        "open-with" => opening::open_with(s, tx, args),
        "shell" => opening::shell(s, tx, args),
        "shell-prompt" => prompt::start(s, tx, Prompt::Shell, "", 0, 0),
        "terminal" => {
            let folder = (!args.is_empty()).then(|| expand(s, args));
            opening::terminal(s, tx, folder)
        }
        "bulk-rename" => opening::bulk_rename(s, tx),
        "menu" => menu::at_cursor(s, tx),
        "leave" => {
            let here = s.cur().path.clone();
            // Drives is a top, as "/" is: each drive's root is below it.
            match drives::parent_of(s, &here) {
                Some((up, name)) => app::cd(s, tx, up, Some(&name), true),
                None => Ok(()),
            }
        }
        "drives" => drives::show(s, tx),
        "mount" => drives::mount_named(s, tx, args),
        "unmount" | "eject" => drives::unmount_named(s, tx, args, name == "eject"),
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
        "fuzzy" => picker::start(s, tx, picker::Kind::Files, args),
        "z" => picker::jump(s, tx, args),
        "zi" => {
            if args.is_empty() || s.zoxide.is_none() {
                picker::jump(s, tx, "")
            } else {
                picker::start(s, tx, picker::Kind::Folders, args)
            }
        }
        "bookmark-set" | "bookmark-jump" | "bookmark-remove" => {
            use strider_machines::keymap::Question;
            let q = match name {
                "bookmark-set" => Question::BookmarkSet,
                "bookmark-jump" => Question::BookmarkJump,
                _ => Question::BookmarkRemove,
            };
            if args.is_empty() || q == Question::BookmarkRemove {
                return bookmarks::ask(s, tx, q);
            }
            let Some(k) = bookmarks::key_arg(s, args) else {
                return app::draw_status(s, tx);
            };
            if q == Question::BookmarkSet {
                bookmarks::set(s, k, s.cwd.clone());
                return app::draw_status(s, tx);
            }
            match bookmarks::get(s, k) {
                Some(p) => app::cd(s, tx, p, None, true),
                None => {
                    s.notify("No such bookmark", true);
                    app::draw_status(s, tx)
                }
            }
        }
        "cd-xdg" => cd_xdg(s, tx, args),
        "cd-media" => {
            let user = std::env::var("USER").unwrap_or_default();
            let run_media = PathBuf::from(format!("/run/media/{user}"));
            let path = [run_media, "/media".into()]
                .into_iter()
                .find(|p| p.is_dir())
                .unwrap_or_else(|| "/mnt".into());
            app::cd(s, tx, path, None, true)
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
            app::others(tx, app::draw);
            app::draw(s, tx)
        }
        "preview-down" => crate::preview::scroll(s, tx, 4 * n as i32),
        "preview-up" => crate::preview::scroll(s, tx, -4 * n as i32),
        "toggle-preview" => {
            s.options.preview = !s.options.preview;
            app::others(tx, redraw);
            redraw(s, tx)
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
            // Nothing to clear: a file chooser is cancelled.
            if s.cur().marks.is_empty() && crate::chooser::cancel(s, tx)? {
                return Ok(());
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
        "unmark-all" => {
            s.cur_mut().marks.clear();
            app::draw(s, tx)
        }
        "invert-marks" => {
            let f = s.cur_mut();
            f.marks = f
                .order
                .iter()
                .copied()
                .filter(|i| !f.marks.contains(i))
                .collect();
            app::draw(s, tx)
        }
        "quit" | "q" if crate::chooser::cancel(s, tx)? => Ok(()),
        "quit" | "q" => {
            let active = s.active;
            tabs::close(s, tx, active)
        }
        "quit-all" | "qa" => app::close_all(s, tx),
        "new-window" => {
            let (cwd, me) = (s.cwd.clone(), tx.window());
            tx.defer(move |s, cx| match app::open_window(s, cx, cwd, None) {
                Ok(_) => Ok(()),
                Err(e) => app::in_window(s, cx, me, |s, tx| {
                    s.notify(format!("Cannot open a window: {e}"), true);
                    app::draw_status(s, tx)
                }),
            });
            Ok(())
        }
        "column-wider" | "column-narrower" => {
            let step = columns::STEP * n as f32;
            let delta = if name == "column-wider" { step } else { -step };
            columns::resize(s, tx, args.trim() == "parent", delta)
        }
        "column-reset" => columns::reset(s, tx),
        "help" => help(s, tx),
        "messages" => messages(s, tx),
        "tab-new" => {
            let path = if args.is_empty() {
                s.cwd.clone()
            } else {
                expand(s, args)
            };
            tabs::open(s, tx, path)
        }
        "tab-close" => {
            let active = s.active;
            tabs::close(s, tx, active)
        }
        "tab-next" => {
            let n = s.tabs.len();
            let to = count.map_or((s.active + 1) % n, |k| (k as usize).saturating_sub(1));
            tabs::select(s, tx, to)
        }
        "tab-prev" => {
            let n = s.tabs.len();
            tabs::select(s, tx, (s.active + n - 1) % n)
        }
        "tab" => {
            let k = args.parse().unwrap_or(count.unwrap_or(1) as usize);
            tabs::select(s, tx, k.saturating_sub(1))
        }
        _ if crate::register::NAMES.contains(&name) => {
            crate::register::run(s, tx, name, args, count)
        }
        _ => {
            s.notify(format!("Unknown command: {name}"), true);
            app::draw_status(s, tx)
        }
    }
}

/// `:help`: every key and every command, in the preview.
fn help(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    use std::fmt::Write;
    use strider_core::config::Mode;
    let mut out = String::from("KEYS\n\n");
    for b in s.keymap.bindings() {
        let mode = match b.mode {
            Mode::Normal => "  ",
            Mode::Visual => "v ",
            Mode::Tasks => "t ",
        };
        let keys = strider_core::keys::format(&b.keys);
        let _ = writeln!(out, "{mode}{keys:<10} {:<24} {}", b.cmd, b.desc);
    }
    out.push_str("\nCOMMANDS (type : and Tab completes)\n\n");
    for c in COMMANDS {
        let _ = writeln!(out, "  {:<18} {}", c.name, c.desc);
    }
    crate::preview::show_output(s, tx, "Keys and commands", &out, Vec::new())
}

/// `:messages`: the status line's recent messages in the preview, newest first, errors in
/// the error color.
fn messages(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    use std::fmt::Write;
    use strider_core::highlight::{Class, Span};
    // Not a message itself: it would list itself next time.
    if s.log.is_empty() {
        return crate::preview::show_output(s, tx, "Messages", "No messages yet.\n", Vec::new());
    }
    let mut out = String::from("MESSAGES (newest first)\n\n");
    let mut spans = Vec::new();
    for (time, error, text) in s.log.iter().rev() {
        let start = out.len();
        let day = (time + i64::from(s.zone.offset_at(*time))).rem_euclid(86_400);
        let _ = write!(
            out,
            "{:02}:{:02}:{:02}  {}",
            day / 3600,
            day / 60 % 60,
            day % 60,
            text.replace('\n', " ")
        );
        if *error {
            spans.push(Span {
                start,
                end: out.len(),
                class: Class::Removed,
            });
        }
        out.push('\n');
    }
    crate::preview::show_output(s, tx, "Messages", &out, spans)
}

/// `:cd-xdg NAME`: an XDG user folder, by its name (DOWNLOAD, DOCUMENTS, PICTURES, MUSIC,
/// VIDEOS, DESKTOP, …) or by its folder's name, as Documents.
fn cd_xdg(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    use keywork::desktop::places::{UserDir, UserDirs};
    let label = match args.to_ascii_uppercase().as_str() {
        "DOWNLOAD" => "Downloads",
        "DOCUMENTS" => "Documents",
        "PICTURES" => "Pictures",
        "MUSIC" => "Music",
        "VIDEOS" => "Videos",
        "DESKTOP" => "Desktop",
        _ => args,
    }
    .to_owned();
    let mut base = keywork::desktop::basedir::BaseDirs::from_env();
    base.home = s.home.clone();
    let dirs = UserDirs::load(&base);
    let found = UserDir::ALL
        .iter()
        .filter_map(|&d| dirs.get(d).map(|p| (d, p.to_owned())))
        .find(|(d, p)| {
            d.key().eq_ignore_ascii_case(args)
                || p.file_name().is_some_and(|n| n.to_string_lossy() == label)
        })
        .map(|(_, p)| p)
        .filter(|p| p.is_dir());
    match found {
        Some(p) => app::cd(s, tx, p, None, true),
        None => {
            s.notify(format!("There is no {label} folder"), true);
            app::draw_status(s, tx)
        }
    }
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
    if s.cache.get(&path).is_some()
        || path == std::path::Path::new(strider_core::model::DRIVES_PATH)
    {
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
    tx.spawn_blocking(move || look(path), app::here(land));
    Ok(())
}

/// `:set name value`, then the window as the options now say.
fn set(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    if args.trim().is_empty() {
        s.notify("set needs an option", true);
        return app::draw_status(s, tx);
    }
    match s.options.set_line(args) {
        Ok(name) => {
            // Set by hand: the next chooser takes it over the size remembered.
            if name == "chooser_size" {
                crate::chooser::forget_size(s);
            }
            apply_options(s, tx)
        }
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

/// Every window as the options say, after one changed.
pub fn apply_options(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    app::others(tx, options_here);
    options_here(s, tx)
}

fn options_here(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let delay = std::time::Duration::from_millis(u64::from(s.options.which_key_delay));
    let fx = s.keys.send(
        strider_machines::keymap::KeyEv::SetDelay(delay),
        app::Clock { tx },
    );
    app::apply_key_fx(s, tx, fx)?;
    app::layout(s, tx)?;
    rearrange_here(s, tx)
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

/// Completes a shell command's last word as a path, as far as the candidates agree.
pub fn complete_shell(s: &Strider, text: &str) -> (String, Vec<String>) {
    let at = text.rfind(' ').map_or(0, |i| i + 1);
    let (head, word) = text.split_at(at);
    finish(head, word, paths(s, word, false), false)
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

/// Completes a path by itself, as a chooser's path field takes one, as far as the
/// candidates agree; with `dirs_only`, folders alone.
pub fn complete_path(s: &Strider, text: &str, dirs_only: bool) -> (String, Vec<String>) {
    finish("", text, paths(s, text, dirs_only), false)
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

/// Into the folder under the cursor, or open the targets.
fn enter(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(e) = s.cur().current().copied() else {
        return Ok(());
    };
    if e.kind == Kind::Dir {
        let path = s.cur().listing.path_of(&e);
        return app::cd(s, tx, path, None, true);
    }
    opening::open_targets(s, tx)
}

/// Sorts and filters the folders shown again, the cursors staying on their entries.
/// Every window in the sort and with the hidden files the options now say.
fn rearrange(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    app::others(tx, rearrange_here);
    rearrange_here(s, tx)
}

fn rearrange_here(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let shown = [Some(s.cwd.clone()), s.parent_path.clone()];
    for path in shown.into_iter().flatten() {
        if let Some(f) = s.cache.get_mut(&path) {
            f.arrange(&s.options, None);
        }
    }
    app::reload_preview(s, tx)?;
    app::draw(s, tx)
}

/// The preview and the columns drawn again.
fn redraw(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    app::reload_preview(s, tx)?;
    app::draw(s, tx)
}

/// A path as typed: `~` is home, `$NAME` an environment variable, and a relative one is
/// under the current folder.
pub fn expand(s: &Strider, arg: &str) -> PathBuf {
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
