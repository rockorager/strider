//! Every action is a named command, run from a key's binding or the command line: a name,
//! then its arguments, with the count typed before the keys.

use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;

use keywork::prelude::*;
use keywork::widgets;
use strider_core::model::Kind;
use strider_core::options::SortKey;
use strider_machines::mode::ModeEv;

use crate::app::{self, Col, Strider};

/// Runs a command line with the count typed before it.
pub fn execute(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    line: &str,
    count: Option<u32>,
) -> Result<()> {
    let line = line.trim();
    let (name, args) = line
        .split_once(char::is_whitespace)
        .map_or((line, ""), |(n, a)| (n, a.trim()));
    let n = count.unwrap_or(1) as usize;
    let cursor = s.current.cursor;
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
            let here = s.current.path.clone();
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
        "cd" => {
            let path = expand(s, args);
            app::cd(s, tx, path, None, true)
        }
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
            app::reload_preview(s);
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
            let path = s.current.path.clone();
            let focus = s.current.current_name().map(<[u8]>::to_vec);
            app::cd(s, tx, path, focus.as_deref(), false)
        }
        "visual" => app::send_mode(s, tx, ModeEv::Visual),
        "visual-end" => app::send_mode(s, tx, ModeEv::VisualEnd),
        "escape" => {
            s.current.marks.clear();
            widgets::set_row_count(tx, s.ui.lists[Col::Current as usize], s.current.len())?;
            app::draw_status(s, tx)
        }
        "toggle-mark" => {
            for _ in 0..n {
                if let Some(i) = s.current.index(s.current.cursor) {
                    if !s.current.marks.remove(&i) {
                        s.current.marks.insert(i);
                    }
                    s.current.cursor =
                        (s.current.cursor + 1).min(s.current.len().saturating_sub(1));
                }
            }
            app::reload_preview(s);
            app::draw(s, tx)
        }
        "mark-all" => {
            s.current.marks = s.current.order.iter().copied().collect();
            app::draw(s, tx)
        }
        "quit" | "quit-all" => {
            tx.after(std::time::Duration::ZERO, |_, cx| {
                cx.quit();
                Ok(())
            });
            Ok(())
        }
        "" => Ok(()),
        _ => {
            let known = strider_core::keys::DEFAULT_BINDINGS
                .iter()
                .any(|b| b.2.split_whitespace().next() == Some(name));
            let text = if known {
                format!("{name} isn't in the Rust build yet")
            } else {
                format!("Not a command: {name}")
            };
            s.notify(text, true);
            app::draw_status(s, tx)
        }
    }
}

/// Into the folder under the cursor. Opening files comes with the rest of opening.
fn enter(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(e) = s.current.current().copied() else {
        return Ok(());
    };
    let path = s.current.listing.path_of(&e);
    if e.kind == Kind::Dir {
        return app::cd(s, tx, path, None, true);
    }
    s.notify("Opening files isn't in the Rust build yet", true);
    app::draw_status(s, tx)
}

/// Sorts and filters the folders shown again, the cursors staying on their entries.
fn rearrange(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.current.arrange(&s.options, None);
    if let Some(p) = &mut s.parent {
        p.arrange(&s.options, None);
    }
    app::reload_preview(s);
    app::draw(s, tx)
}

/// A path as typed: `~` is home, and a relative one is under the current folder.
fn expand(s: &Strider, arg: &str) -> PathBuf {
    match arg {
        "" | "~" => s.home.clone(),
        a if a.starts_with("~/") => s.home.join(&a[2..]),
        a => s.current.path.join(a),
    }
}
