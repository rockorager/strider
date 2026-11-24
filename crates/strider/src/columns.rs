//! The columns' widths chosen by hand: dragging the handles on the column boundaries, or `<`
//! and `>` (column-narrower, column-wider). The parent's and the current column's widths are
//! kept as shares of the window, for the next start in the state directory's `columns`; the
//! preview takes the rest. column-reset goes back to the ratio.

use keywork::CursorShape;
use keywork::input::BTN_LEFT;
use keywork::prelude::*;
use keywork::theme::{ColorRole, Paint};
use strider_core::state;

use crate::app::{self, Strider};
use crate::theme::Tone;

/// How wide a column boundary is to grab: a 1 px line in the middle, each side on its
/// column's surface.
pub const HANDLE_WIDTH: f32 = 7.0;
/// No column gets narrower than this by dragging or `<` and `>`.
pub const MIN_COLUMN: f32 = 80.0;
/// How far `<` and `>` move a boundary.
pub const STEP: f32 = 32.0;

/// A handle's nodes: itself and its line.
pub type Handle = (NodeId<Flex>, NodeId<Flex>);

/// A boundary being dragged: which, where the pointer started, and the parent's and current
/// column's widths then.
#[derive(Clone, Copy, Debug)]
pub struct Drag {
    which: usize,
    x0: f32,
    widths: [f32; 2],
}

/// Builds handle `which` (0 between the parent and the current column, 1 between the current
/// column and the preview) in `parent`, between the columns of tones `sides`.
pub fn build_handle(
    tx: &mut Txn<'_, Strider>,
    parent: NodeId<Flex>,
    which: usize,
    sides: [Tone; 2],
) -> Result<Handle> {
    let node = tx.flex(
        parent,
        Flex::row().width(Dim::Px(HANDLE_WIDTH)).height(Dim::Fill),
    )?;
    tx.update_style(node, |st| st.shrink = 0.0)?;
    let side = |tx: &mut Txn<'_, Strider>, tone: Tone| -> Result<()> {
        let b = tx.flex(node, Flex::row().grow(1.0).height(Dim::Fill))?;
        tx.update_style(b, |st| st.basis = Some(Dim::Px(0.0)))?;
        tx.set_background(b, tone.paint())
    };
    side(tx, sides[0])?;
    let line = tx.flex(node, Flex::row().height(Dim::Fill))?;
    side(tx, sides[1])?;
    tx.set_cursor(node, Some(CursorShape::EwResize))?;
    tx.on(node, PointerDown, move |s: &mut Strider, tx, ev| {
        match ev.data {
            EventData::Pointer {
                button, position, ..
            } if button == BTN_LEFT => {
                s.drag = Some(Drag {
                    which,
                    x0: position.x,
                    widths: widths(s, tx)?,
                });
                style(s, tx, which)
            }
            _ => Err(keywork::Error::Pass),
        }
    })?;
    tx.on(node, PointerMove, move |s: &mut Strider, tx, ev| {
        let (Some(d), EventData::Pointer { position, .. }) = (s.drag, ev.data) else {
            return Err(keywork::Error::Pass);
        };
        if d.which != which {
            return Err(keywork::Error::Pass);
        }
        let delta = position.x - d.x0;
        let mut w = d.widths;
        if which == 0 {
            // The boundary moves; the current column's other edge stays.
            w[0] += delta;
            w[1] -= delta;
        } else {
            w[1] += delta;
        }
        set(s, tx, w, false)
    })?;
    for kind in [PointerUp, PointerCancel] {
        tx.on(node, kind, move |s: &mut Strider, tx, _| {
            if s.drag.take().is_none() {
                return Err(keywork::Error::Pass);
            }
            // Kept for the next start once the drag ends.
            if let Some(w) = s.widths {
                save(s, Some(w));
            }
            style(s, tx, which)
        })?;
    }
    tx.on(node, PointerEnter, move |s: &mut Strider, tx, _| {
        s.handle_hover = Some(which);
        style(s, tx, which)
    })?;
    tx.on(node, PointerLeave, move |s: &mut Strider, tx, _| {
        if s.handle_hover == Some(which) {
            s.handle_hover = None;
        }
        style(s, tx, which)
    })?;
    let handle = (node, line);
    style_line(tx, line, false)?;
    Ok(handle)
}

/// The line: the separator at rest, the accent and twice as wide under the pointer or while
/// dragged.
fn style(s: &Strider, tx: &mut Txn<'_, Strider>, which: usize) -> Result<()> {
    let lit = s.handle_hover == Some(which) || s.drag.is_some_and(|d| d.which == which);
    style_line(tx, s.ui.handles[which].1, lit)
}

fn style_line(tx: &mut Txn<'_, Strider>, line: NodeId<Flex>, lit: bool) -> Result<()> {
    tx.update_style(line, |st| {
        st.width = Dim::Px(if lit { 2.0 } else { 1.0 });
        st.shrink = 0.0;
    })?;
    tx.set_background(
        line,
        Paint::Role(if lit {
            ColorRole::AccentFill
        } else {
            ColorRole::BorderSubtle
        }),
    )
}

/// The parent's and the current column's widths as laid out.
fn widths(s: &Strider, tx: &Txn<'_, Strider>) -> Result<[f32; 2]> {
    let [parent, current, _] = s.ui.panes;
    let parent = if tx.is_hidden(parent)? {
        0.0
    } else {
        tx.rect(parent)?.width
    };
    Ok([parent, tx.rect(current)?.width])
}

/// Makes the parent and current columns `w` wide, clamped so every shown column keeps
/// `MIN_COLUMN`, as the user's choice; `persist` keeps it for the next start.
fn set(s: &mut Strider, tx: &mut Txn<'_, Strider>, mut w: [f32; 2], persist: bool) -> Result<()> {
    let total = s.width;
    if total <= 0.0 {
        return Ok(());
    }
    let room = total - 2.0 * HANDLE_WIDTH - MIN_COLUMN;
    w[0] = w[0].clamp(MIN_COLUMN, MIN_COLUMN.max(room - MIN_COLUMN));
    w[1] = w[1].clamp(MIN_COLUMN, MIN_COLUMN.max(room - w[0]));
    let shares = [w[0] / total, w[1] / total];
    s.widths = Some(shares);
    if persist {
        save(s, Some(shares));
    }
    app::layout(s, tx)
}

/// Keeps the widths for the next start, or with `None` forgets them.
fn save(s: &mut Strider, w: Option<[f32; 2]>) {
    if let Some(dir) = &s.state_dir
        && let Err(e) = state::save_widths(dir, w)
    {
        s.notify(format!("Cannot save the column widths: {e}"), true);
    }
}

/// `<` and `>`: widens (or narrows, with a negative `delta`) the current column, or the
/// parent; the room comes from the preview.
pub fn resize(s: &mut Strider, tx: &mut Txn<'_, Strider>, parent: bool, delta: f32) -> Result<()> {
    let mut w = widths(s, tx)?;
    w[usize::from(!parent)] += delta;
    set(s, tx, w, true)
}

/// column-reset: the widths from the ratio again.
pub fn reset(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.widths = None;
    save(s, None);
    app::layout(s, tx)
}
