//! Bookmarks: folders under a key each, kept in the state directory. `m` and a key sets one,
//! `'` and a key goes there (`''` back where the last jump came from), `dm` and a key removes
//! one. The keymap chart waits for the key; this answers it.

use std::path::PathBuf;

use keywork::prelude::*;
use strider_core::keys::{self, Key};
use strider_core::state;
use strider_machines::keymap::{KeyEv, Question};

use crate::app::{self, Clock, Strider};

/// Sets bookmark `key` to `path`, keeping its place if it had one, and saves them.
pub fn set(s: &mut Strider, key: char, path: PathBuf) {
    state::set_bookmark(&mut s.bookmarks, key, path);
    save(s);
}

fn save(s: &mut Strider) {
    if let Some(dir) = &s.state_dir
        && let Err(e) = state::save_bookmarks(dir, &s.bookmarks)
    {
        s.notify(format!("Cannot save the bookmarks: {e}"), true);
    }
}

pub fn get(s: &Strider, key: char) -> Option<PathBuf> {
    s.bookmarks
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, p)| p.clone())
}

/// Waits for the key a question is answered with.
pub fn ask(s: &mut Strider, tx: &mut Txn<'_, Strider>, q: Question) -> Result<()> {
    let fx = s.keys.send(KeyEv::Ask(q), Clock { tx });
    app::apply_key_fx(s, tx, fx)
}

/// What the status line asks while a key is awaited.
pub fn question_text(q: Question) -> &'static str {
    match q {
        Question::BookmarkSet => "Set a bookmark: press a key",
        Question::BookmarkJump => "Go to a bookmark: press its key",
        Question::BookmarkRemove => "Remove a bookmark: press its key",
        Question::EmptyTrash => "Empty the trash? Everything in it is deleted permanently. y/N",
        Question::Conflict => "",
    }
}

/// The bookmarks as the which-key popup lists them: each key and its folder.
pub fn hints(s: &Strider) -> Vec<(String, String)> {
    if s.bookmarks.is_empty() {
        return vec![(
            String::new(),
            "No bookmarks yet: m and a key sets one".into(),
        )];
    }
    s.bookmarks
        .iter()
        .map(|(k, p)| (k.to_string(), s.short_path(p)))
        .collect()
}

/// The key that answers a bookmark question; Escape declines.
pub fn answer(s: &mut Strider, tx: &mut Txn<'_, Strider>, q: Question, key: Key) -> Result<()> {
    if key.code == keys::sym::ESCAPE {
        return app::draw_status(s, tx);
    }
    let ch = key.is_char().then(|| char::from_u32(key.code)).flatten();
    match (q, ch) {
        (Question::BookmarkSet, Some(c)) => {
            set(s, c, s.cwd.clone());
            s.notify(format!("Bookmark '{c}' set"), false);
        }
        (Question::BookmarkJump, Some('\'' | '`')) => {
            return crate::commands::execute(s, tx, "back", None, false);
        }
        (Question::BookmarkJump, c) => match c.and_then(|c| get(s, c)) {
            Some(path) => return app::cd(s, tx, path, None, true),
            None => s.notify("No such bookmark", true),
        },
        (Question::BookmarkRemove, c) => {
            let before = s.bookmarks.len();
            s.bookmarks.retain(|(k, _)| Some(*k) != c);
            if s.bookmarks.len() == before {
                s.notify("No such bookmark", true);
            } else {
                save(s);
                s.notify("Bookmark removed", false);
            }
        }
        _ => {}
    }
    app::draw_status(s, tx)
}

/// A bookmark command's argument: one key.
pub fn key_arg(s: &mut Strider, args: &str) -> Option<char> {
    let mut chars = args.trim().chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => Some(c),
        _ => {
            s.notify("A bookmark is one key", true);
            None
        }
    }
}
