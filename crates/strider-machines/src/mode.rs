//! The window's mode: normal, or visual, where the cursor's moves mark a range from where
//! it started. Its leaf names the key table keys are looked up in.

use plusthree::prelude::*;
use strider_core::config;

#[derive(Context, Clone, Debug, Default)]
pub struct ModeCtx {}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum ModeEv {
    /// Start a visual range at the cursor.
    Visual,
    /// End it, keeping the range marked.
    VisualEnd,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModeFx {
    /// Anchor a range at the cursor.
    StartRange,
    /// Mark the range and stop extending it.
    EndRange,
    /// The mode changed: drop pending keys, and draw the status line again.
    Changed,
}

plusthree::machine! {
    pub Mode { context: ModeCtx, events: ModeEv, effects: ModeFx }
    id: "mode",
    initial: normal,
    states: {
        normal: {
            on: { ModeEv::Visual => visual },
        },
        visual: {
            entry: |_, enq| { enq.action(ModeFx::StartRange); enq.action(ModeFx::Changed) },
            exit: |_, enq| { enq.action(ModeFx::EndRange); enq.action(ModeFx::Changed) },
            on: { ModeEv::VisualEnd => normal },
        },
    }
}

/// The key table for the mode a snapshot is in.
pub fn table(visual: bool) -> config::Mode {
    if visual {
        config::Mode::Visual
    } else {
        config::Mode::Normal
    }
}
