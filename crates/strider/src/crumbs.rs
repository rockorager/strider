//! The header's path as links, as the Zig build's breadcrumbs: "~", "/", or within a drive
//! "Drives" and the drive's label, then each folder down to the current one, separated by
//! slashes, and the name under the cursor after them. The folders above the current one go
//! there when clicked (into a new tab with the middle button), underlined under the pointer,
//! and take dropped files.

use std::path::{Path, PathBuf};

use keywork::input::{BTN_LEFT, BTN_MIDDLE};
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use keywork::tree::TextDecoration;
use strider_core::model;

use crate::app::{self, Col, Strider};

/// What each window keeps: the segments shown, and each link's node and folder.
#[derive(Default)]
pub struct Crumbs {
    shown: Vec<(String, Option<PathBuf>)>,
    pub links: Vec<(NodeId<Text>, PathBuf)>,
}

/// The row of segments, before the name in the header's bar.
pub fn build(tx: &mut Txn<'_, Strider>, bar: NodeId<Flex>) -> Result<NodeId<Flex>> {
    let row = tx.flex(bar, Flex::row().align(keywork::Align::Center))?;
    tx.update_style(row, |st| {
        st.shrink = 1.0;
        st.min_width = 0.0;
    })?;
    tx.set_clip(row, true)?;
    Ok(row)
}

/// The folder of link `i`.
pub fn path(s: &Strider, i: usize) -> Option<PathBuf> {
    s.crumbs.links.get(i).map(|(_, p)| p.clone())
}

/// The segments of the current folder's path: each label, and the folder a link goes to;
/// the current folder's own is no link.
fn segments(s: &Strider) -> Vec<(String, Option<PathBuf>)> {
    let path = &s.cur().path;
    if *path == Path::new(model::DRIVES_PATH) {
        return vec![("Drives/".into(), None)];
    }
    if *path == crate::register::home_trash(s).join("files") {
        return vec![("Trash/".into(), None)];
    }
    let home = &s.home;
    let in_home = *home != Path::new("/") && model::is_within(path, home);
    let mut parts: Vec<(String, PathBuf)> = Vec::new();
    let mut root = false;
    let rest = match strider_core::drives::drive_of(&s.drives.list, path, home) {
        Some(d) => {
            parts.push(("Drives".into(), PathBuf::from(model::DRIVES_PATH)));
            parts.push((d.label.clone(), d.mount_point.clone()));
            path.strip_prefix(&d.mount_point).unwrap_or(Path::new(""))
        }
        None if in_home => {
            parts.push(("~".into(), home.clone()));
            path.strip_prefix(home).unwrap_or(Path::new(""))
        }
        None => {
            root = true;
            parts.push(("/".into(), PathBuf::from("/")));
            path.strip_prefix("/").unwrap_or(path)
        }
    };
    let mut at = parts.last().map(|p| p.1.clone()).unwrap_or_default();
    for part in rest.iter() {
        at.push(part);
        parts.push((part.to_string_lossy().into_owned(), at.clone()));
    }
    // The root's label is its own slash.
    let last = parts.len() - 1;
    let mut out = Vec::new();
    for (i, (label, to)) in parts.into_iter().enumerate() {
        if i > 1 || (i == 1 && !root) {
            out.push(("/".into(), None));
        }
        out.push((label, (i != last).then_some(to)));
    }
    if *path != Path::new("/") {
        out.push(("/".into(), None));
    }
    out
}

/// The path as the header reads it, as "~/work/src/" or "Drives/STICK/".
#[cfg(test)]
pub fn text(s: &Strider) -> String {
    segments(s).into_iter().map(|(label, _)| label).collect()
}

/// The header: the links, made again when the path changes, and the name under the cursor.
pub fn draw(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let segments = segments(s);
    if segments != s.crumbs.shown {
        make(s, tx, &segments)?;
        s.crumbs.shown = segments;
    }
    let name = String::from_utf8_lossy(s.cur().current_name().unwrap_or_default()).into_owned();
    tx.set_text(s.ui.header, &name)?;
    tx.set_text_spans(s.ui.header, &[])
}

fn make(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    segments: &[(String, Option<PathBuf>)],
) -> Result<()> {
    let row = s.ui.crumbs;
    let old: Vec<_> = tx.children(row)?.collect();
    for n in old {
        tx.remove(n)?;
    }
    s.crumbs.links.clear();
    for (label, to) in segments {
        let n = keywork::widgets::label(tx, row, label, keywork::widgets::TextKind::Body)?;
        tx.set_color(n, Paint::Role(ColorRole::AccentText))?;
        tx.update_style(n, |st| {
            st.font_weight = 700.0;
            st.max_lines = 1;
            // Folders above give way first when the path is too long, so the current
            // folder stays whole.
            if to.is_some() {
                st.shrink = 1.0;
                st.min_width = 0.0;
            } else {
                st.shrink = 0.0;
            }
        })?;
        let Some(to) = to else {
            continue;
        };
        let i = s.crumbs.links.len();
        tx.set_label(n, label)?;
        tx.set_cursor(n, Some(keywork::CursorShape::Pointer))?;
        app::on(tx, n, PointerEnter, move |s: &mut Strider, tx, _| {
            hover(s, tx, i, true)
        })?;
        app::on(tx, n, PointerLeave, move |s: &mut Strider, tx, _| {
            hover(s, tx, i, false)
        })?;
        app::on(tx, n, PointerDown, move |s: &mut Strider, tx, ev| {
            let EventData::Pointer { button, .. } = ev.data else {
                return Err(keywork::Error::Pass);
            };
            if button != BTN_LEFT && button != BTN_MIDDLE {
                return Err(keywork::Error::Pass);
            }
            go(s, tx, i, button == BTN_MIDDLE)
        })?;
        // Files dragged onto a folder of the path go there; Drives is no folder.
        if *to != Path::new(model::DRIVES_PATH) {
            crate::dnd::bind(tx, n, crate::dnd::Target::Crumb(i))?;
        }
        s.crumbs.links.push((n, to.clone()));
    }
    Ok(())
}

/// Link `i` under the pointer, or not: underlined while it is.
pub fn hover(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize, on: bool) -> Result<()> {
    let Some(&(n, _)) = s.crumbs.links.get(i) else {
        return Ok(());
    };
    tx.update_style(n, |st| {
        st.text_decoration = if on {
            TextDecoration::UNDERLINE
        } else {
            TextDecoration::NONE
        };
    })
}

/// A click on link `i`: there, as h goes, the cursor on the folder it came from; with the
/// middle button, into a new tab.
fn go(s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize, tab: bool) -> Result<()> {
    let Some(to) = path(s, i) else {
        return Ok(());
    };
    if tab {
        crate::tabs::open(s, tx, to)?;
    } else {
        let came_from = s
            .cwd
            .strip_prefix(&to)
            .ok()
            .and_then(|rest| rest.iter().next())
            .map(|n| n.as_encoded_bytes().to_vec());
        app::cd(s, tx, to, came_from.as_deref(), true)?;
    }
    tx.focus(s.ui.lists[Col::Current as usize])
}

/// A drop's outline on link `i`, or its own look again.
pub fn outline(s: &Strider, tx: &mut Txn<'_, Strider>, i: usize, on: bool) -> Result<()> {
    let Some(&(n, _)) = s.crumbs.links.get(i) else {
        return Ok(());
    };
    let theme = tx.theme(n)?;
    let (bg, border) = if on {
        (
            Paint::Role(ColorRole::Selection),
            theme.color(Paint::Role(ColorRole::AccentFill)),
        )
    } else {
        (Paint::TRANSPARENT, keywork::Color::TRANSPARENT)
    };
    tx.set_background(n, bg)?;
    tx.set_radius(n, 4.0)?;
    tx.set_border(n, border, if on { 1.0 } else { 0.0 })
}
