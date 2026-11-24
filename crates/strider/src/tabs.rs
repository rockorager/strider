//! Tabs: each its own folder and history. The active tab's live in the window's state (`cwd`,
//! `history`, `history_pos`), so everything else reads them as one window's; the others wait
//! here, and switching swaps them. With two or more, the header shows them on the right, the
//! active one on the accent, each with a close button on the active and hovered ones.

use std::path::PathBuf;

use keywork::input::{BTN_LEFT, BTN_MIDDLE};
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::widgets::{self, TextKind};

use crate::app::{self, Strider};

#[derive(Clone, Debug, Default)]
pub struct Tab {
    pub cwd: PathBuf,
    pub history: Vec<PathBuf>,
    pub history_pos: usize,
}

impl Tab {
    pub fn new(path: PathBuf) -> Tab {
        Tab {
            history: vec![path.clone()],
            cwd: path,
            history_pos: 0,
        }
    }
}

/// Keeps the active tab's folder and history in its slot.
fn save(s: &mut Strider) {
    let t = Tab {
        cwd: s.cwd.clone(),
        history: s.history.clone(),
        history_pos: s.history_pos,
    };
    s.tabs[s.active] = t;
}

/// The folders other tabs show, which the cache keeps.
fn pin(s: &mut Strider) {
    s.cache.pinned = s
        .tabs
        .iter()
        .enumerate()
        .filter(|&(i, _)| i != s.active)
        .map(|(_, t)| t.cwd.clone())
        .collect();
}

/// Makes tab `i` the active one, showing its folder.
fn show(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize) -> Result<()> {
    s.active = i;
    let t = s.tabs[i].clone();
    s.history = t.history;
    s.history_pos = t.history_pos;
    pin(s);
    s.cache.entry(&t.cwd);
    app::cd(s, tx, t.cwd, None, false)
}

/// A new tab on `path`, after the others, and active; a file opens its folder with it under
/// the cursor.
pub fn open(s: &mut Strider, tx: &mut Txn<'_, Strider>, path: PathBuf) -> Result<()> {
    let path = strider_core::model::normalize(&path);
    let (dir, select) = if !path.is_dir() && path.exists() {
        let name = path.file_name().map(|n| n.as_encoded_bytes().to_vec());
        (strider_core::model::parent(&path).to_owned(), name)
    } else {
        (path, None)
    };
    if !dir.is_dir() && dir != std::path::Path::new(strider_core::model::DRIVES_PATH) {
        s.notify(format!("No such folder: {}", dir.display()), true);
        return app::draw_status(s, tx);
    }
    save(s);
    s.tabs.push(Tab::new(dir.clone()));
    if let Some(name) = select {
        s.cache.entry(&dir).focus(&name);
    }
    show(s, tx, s.tabs.len() - 1)
}

pub fn select(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize) -> Result<()> {
    if i >= s.tabs.len() || i == s.active {
        return Ok(());
    }
    save(s);
    show(s, tx, i)
}

/// Closes tab `i`; the active tab stays active unless it is the one closed. Closing the last
/// tab closes the window.
pub fn close(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize) -> Result<()> {
    if i >= s.tabs.len() {
        return Ok(());
    }
    if s.tabs.len() == 1 {
        return app::close_window(s, tx);
    }
    save(s);
    s.tabs.remove(i);
    s.hover = None;
    let active = if i < s.active || s.active >= s.tabs.len() {
        s.active - 1
    } else {
        s.active
    };
    show(s, tx, active)
}

/// A tab's label: its number and its folder's name, `~` for home.
pub fn label(s: &Strider, i: usize) -> String {
    let path = if i == s.active {
        &s.cwd
    } else {
        &s.tabs[i].cwd
    };
    let name = if *path == s.home {
        "~".into()
    } else {
        path.file_name()
            .map_or_else(|| "/".into(), |n| n.to_string_lossy().into_owned())
    };
    format!("{} {name}", i + 1)
}

/// A tab's nodes: itself, its label, and its close button.
pub type TabNodes = (NodeId<Flex>, NodeId<Text>, NodeId<Text>);

/// The tabs in the header, with two or more.
pub fn draw(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let row = s.ui.tabs;
    let old: Vec<_> = tx.children(row)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    s.tab_nodes.clear();
    if s.tabs.len() < 2 {
        return Ok(());
    }
    for i in 0..s.tabs.len() {
        let tab = tx.flex(
            row,
            Flex::row()
                .gap(2.0)
                .align(keywork::Align::Center)
                .padding(Insets::new(1.0, 2.0, 1.0, 8.0)),
        )?;
        tx.update_style(tab, |st| st.max_width = 180.0)?;
        tx.set_radius(tab, 4.0)?;
        let name = label(s, i);
        tx.set_label(tab, &name)?;
        let text = widgets::label(tx, tab, &name, TextKind::Small)?;
        tx.update_style(text, |st| {
            st.max_lines = 1;
            st.shrink = 1.0;
            st.min_width = 0.0;
        })?;
        // The close button's room is always kept, so labels stay put when it shows.
        let x = widgets::label(tx, tab, "✕", TextKind::Small)?;
        tx.update_style(x, |st| {
            st.width = Dim::Px(18.0);
            st.text_align = keywork::TextAlign::Center;
            st.shrink = 0.0;
        })?;
        tx.set_label(x, format!("Close {name}"))?;
        tx.on(x, PointerDown, move |s: &mut Strider, tx, ev| {
            match ev.data {
                EventData::Pointer { button, .. }
                    if button == BTN_MIDDLE
                        || button == BTN_LEFT && (s.active == i || s.hover == Some(i)) =>
                {
                    close(s, tx, i)
                }
                _ => Err(keywork::Error::Pass),
            }
        })?;
        tx.on(tab, PointerDown, move |s: &mut Strider, tx, ev| {
            match ev.data {
                EventData::Pointer { button, .. } if button == BTN_MIDDLE => close(s, tx, i),
                EventData::Pointer { button, .. } if button == BTN_LEFT => select(s, tx, i),
                _ => Ok(()),
            }
        })?;
        tx.on(tab, PointerEnter, move |s: &mut Strider, tx, _| {
            hover(s, tx, Some(i))
        })?;
        tx.on(tab, PointerLeave, move |s: &mut Strider, tx, _| {
            if s.hover == Some(i) {
                hover(s, tx, None)?;
            }
            Ok(())
        })?;
        s.tab_nodes.push((tab, text, x));
        style(s, tx, i)?;
    }
    Ok(())
}

fn hover(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: Option<usize>) -> Result<()> {
    let old = std::mem::replace(&mut s.hover, i);
    for t in [old, i].into_iter().flatten() {
        style(s, tx, t)?;
    }
    Ok(())
}

/// A tab's look: the active one on the accent, a hovered one raised, and the close button on
/// the active and hovered ones.
fn style(s: &Strider, tx: &mut Txn<'_, Strider>, i: usize) -> Result<()> {
    let Some(&(tab, text, x)) = s.tab_nodes.get(i) else {
        return Ok(());
    };
    let on = i == s.active;
    let hover = s.hover == Some(i);
    let (bg, fg) = match (on, hover) {
        (true, _) => (ColorRole::AccentFill, ColorRole::OnAccent),
        (false, true) => (ColorRole::ComponentHover, ColorRole::Text),
        (false, false) => (ColorRole::Component, ColorRole::TextMuted),
    };
    tx.set_background(tab, Paint::Role(bg))?;
    tx.set_color(text, Paint::Role(fg))?;
    tx.update_style(text, |st| st.font_weight = if on { 700.0 } else { 400.0 })?;
    tx.set_color(
        x,
        if on || hover {
            Paint::Role(fg)
        } else {
            Paint::Faded(fg, 0.0)
        },
    )
}
