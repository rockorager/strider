//! The command line's prompts: what the mode chart's effects do to the window, the keys a
//! prompt takes before its text field does, the history Up and Down recall, and Tab
//! completion.

use keywork::prelude::*;
use keywork::widgets::{self, TextKind};
use keywork::{Error, theme::ColorRole, theme::Paint};
use strider_core::keys::{self, Key};
use strider_core::state;
use strider_machines::mode::{ModeEv, Prompt};

use crate::app::{self, Col, Strider};
use crate::commands;

/// Opens the command line for `p` with `text`, `anchor..head` of it selected.
pub fn start(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    p: Prompt,
    text: &str,
    anchor: usize,
    head: usize,
) -> Result<()> {
    app::send_mode(s, tx, ModeEv::Open(p))?;
    tx.set_text(s.ui.line_editor, text)?;
    tx.set_editor_selection(s.ui.line_editor, anchor, head)
}

/// The prompt's text as typed.
pub fn text(s: &Strider, tx: &Txn<'_, Strider>) -> Result<String> {
    Ok(tx.editor_text(s.ui.line_editor)?.to_string())
}

fn set_text(s: &Strider, tx: &mut Txn<'_, Strider>, text: &str) -> Result<()> {
    tx.set_text(s.ui.line_editor, text)?;
    tx.set_editor_selection(s.ui.line_editor, text.len(), text.len())
}

/// A key while a prompt is open. Enter, Escape (and Ctrl+C or Ctrl+[, as in a terminal),
/// Tab, and Up and Down are the prompt's; the rest go to its text field.
pub fn key(s: &mut Strider, tx: &mut Txn<'_, Strider>, p: Prompt, key: Key) -> Result<()> {
    let m = key.mods;
    let plain = !m.ctrl && !m.alt && !m.super_;
    if s.message.take().is_some() {
        app::draw_status(s, tx)?;
    }
    match key.code {
        keys::sym::ESCAPE if plain => app::send_mode(s, tx, ModeEv::Cancel),
        c if m.ctrl && (c == u32::from('c') || c == u32::from('[')) => {
            app::send_mode(s, tx, ModeEv::Cancel)
        }
        keys::sym::RETURN if plain => {
            let t = text(s, tx)?;
            app::send_mode(s, tx, ModeEv::Submit(t))
        }
        keys::sym::TAB if plain => {
            if p == Prompt::Command {
                complete(s, tx)?;
            }
            Ok(())
        }
        keys::sym::UP | keys::sym::DOWN if plain && p == Prompt::Command => {
            recall(s, tx, if key.code == keys::sym::UP { -1 } else { 1 })
        }
        _ => Err(Error::Pass),
    }
}

/// Shows the command line for `p`, empty, and gives it the keys.
pub fn open(s: &mut Strider, tx: &mut Txn<'_, Strider>, p: Prompt) -> Result<()> {
    s.prompt_origin = s.cur().cursor;
    s.prompt_entry = s.cur().current_name().map(<[u8]>::to_vec);
    s.line_pos = s.lines.len();
    tx.set_text(s.ui.line_label, p.label())?;
    tx.set_label(s.ui.line_editor, p.name())?;
    tx.set_text(s.ui.line_editor, "")?;
    tx.set_hidden(s.ui.which_key, true)?;
    tx.set_hidden(s.ui.line, false)?;
    lift_popup(s, tx, true)?;
    tx.focus(s.ui.line_editor)
}

/// Keeps the which-key popup above the command line while the line shows.
fn lift_popup(s: &Strider, tx: &mut Txn<'_, Strider>, line: bool) -> Result<()> {
    let bottom = if line { 76.0 } else { 36.0 };
    tx.update_style(s.ui.which_key, |st| {
        st.position = keywork::tree::Position::Absolute(keywork::tree::Anchors {
            right: Some(12.0),
            bottom: Some(bottom),
            ..Default::default()
        });
    })
}

/// Hides the command line, emptied, and gives the keys back to the folder.
pub fn close(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    tx.set_hidden(s.ui.line, true)?;
    tx.set_text(s.ui.line_editor, "")?;
    tx.set_hidden(s.ui.which_key, true)?;
    lift_popup(s, tx, false)?;
    tx.focus(s.ui.lists[Col::Current as usize])
}

/// The text changed: a search moves to its first match from where it started (or back
/// there), find too (closing on the only match, with `find_auto_accept`), and a filter
/// filters.
pub fn live(s: &mut Strider, tx: &mut Txn<'_, Strider>, p: Prompt) -> Result<()> {
    let t = text(s, tx)?;
    let origin = s.prompt_origin;
    match p {
        Prompt::Search | Prompt::SearchBack => {
            let found = s
                .cur()
                .find_match(&t, origin, p == Prompt::SearchBack, true);
            app::move_cursor(s, tx, found.unwrap_or(origin))
        }
        Prompt::Find => {
            if let Some(pos) = s.cur().find_match(&t, origin, false, true) {
                app::move_cursor(s, tx, pos)?;
            }
            if !t.is_empty() && s.options.find_auto_accept && s.cur().count_matches(&t) == 1 {
                app::send_mode(s, tx, ModeEv::Accept)?;
            }
            Ok(())
        }
        Prompt::Filter => {
            let entry = s.prompt_entry.clone();
            set_filter(s, tx, t, entry.as_deref())
        }
        Prompt::Command => Ok(()),
    }
}

/// Enter: a command line runs, kept in the history; a search is remembered for `n`, and
/// says so when nothing matches.
pub fn run(s: &mut Strider, tx: &mut Txn<'_, Strider>, p: Prompt, t: &str) -> Result<()> {
    match p {
        Prompt::Command => {
            if state::add_history(&mut s.lines, t)
                && let Some(dir) = &s.state_dir
                && let Err(e) = state::save_history(dir, &s.lines)
            {
                s.notify(format!("Cannot save the history: {e}"), true);
            }
            commands::execute(s, tx, t, None, false)
        }
        Prompt::Search | Prompt::SearchBack => {
            let back = p == Prompt::SearchBack;
            s.last_search = t.to_owned();
            s.last_search_back = back;
            if !t.is_empty() && s.cur().find_match(t, s.prompt_origin, back, true).is_none() {
                s.notify("No match", true);
            }
            app::draw_status(s, tx)
        }
        Prompt::Find | Prompt::Filter => app::draw_status(s, tx),
    }
}

/// Escape: a search or find goes back to where it started, and a filter comes off.
pub fn restore(s: &mut Strider, tx: &mut Txn<'_, Strider>, p: Prompt) -> Result<()> {
    match p {
        Prompt::Search | Prompt::SearchBack | Prompt::Find => {
            app::move_cursor(s, tx, s.prompt_origin)
        }
        Prompt::Filter => {
            let entry = s.prompt_entry.take();
            set_filter(s, tx, String::new(), entry.as_deref())
        }
        Prompt::Command => app::draw_status(s, tx),
    }
}

/// Shows only the current folder's names that match `filter`, or with "" every name, the
/// cursor on `focus` when it shows, else on the entry it was on.
pub fn set_filter(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    filter: String,
    focus: Option<&[u8]>,
) -> Result<()> {
    let options = s.options.clone();
    let f = s.cur_mut();
    f.filter = filter;
    f.arrange(&options, focus);
    app::reload_preview(s, tx)?;
    app::draw(s, tx)
}

/// Up and Down: the command lines typed before, and past the newest an empty line.
fn recall(s: &mut Strider, tx: &mut Txn<'_, Strider>, delta: isize) -> Result<()> {
    if s.lines.is_empty() {
        return Ok(());
    }
    let Some(pos) = s.line_pos.checked_add_signed(delta) else {
        return Ok(());
    };
    s.line_pos = pos.min(s.lines.len());
    let line = s.lines.get(s.line_pos).cloned().unwrap_or_default();
    set_text(s, tx, &line)
}

/// Tab: completes the command's name, then its argument, as far as every candidate goes,
/// and lists the candidates when there are several.
fn complete(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let t = text(s, tx)?;
    let (completed, candidates) = commands::complete(s, &t);
    if candidates.is_empty() {
        return Ok(());
    }
    if completed != t {
        set_text(s, tx, &completed)?;
    }
    if candidates.len() > 1 {
        show_candidates(s, tx, &candidates)
    } else {
        tx.set_hidden(s.ui.which_key, true)
    }
}

/// Lists completions in the which-key popup: up to 60, in up to three columns.
fn show_candidates(s: &Strider, tx: &mut Txn<'_, Strider>, candidates: &[String]) -> Result<()> {
    let popup = s.ui.which_key;
    let old: Vec<_> = tx.children(popup)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    let shown = &candidates[..candidates.len().min(60)];
    let cols = match shown.len() {
        n if n > 16 => 3,
        n if n > 6 => 2,
        _ => 1,
    };
    let grid = tx.flex(popup, Flex::row().gap(18.0))?;
    for chunk in shown.chunks(shown.len().div_ceil(cols)) {
        let col = tx.flex(grid, Flex::column().gap(2.0))?;
        for c in chunk {
            let n = widgets::label(tx, col, c, TextKind::Body)?;
            tx.set_color(n, Paint::Role(ColorRole::Text))?;
            tx.update_style(n, |st| {
                st.max_lines = 1;
                st.max_width = 240.0;
            })?;
        }
    }
    tx.set_hidden(popup, false)
}
