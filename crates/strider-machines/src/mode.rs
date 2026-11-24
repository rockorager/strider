//! The window's mode, in two regions at once. The selection is normal, or visual, where the
//! cursor's moves mark a range from where it started; its leaf names the key table keys are
//! looked up in. The command line is closed, or open for a prompt, which takes the keys while
//! it is open. A prompt opened in visual mode leaves the range as it is, so a command typed
//! there works on it.

use plusthree::prelude::*;
use strider_core::config;

/// What the command line is open for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Prompt {
    /// A command line, as typed after `:`.
    #[default]
    Command,
    /// Search forward, the cursor following the first match as the text changes.
    Search,
    /// Search backward.
    SearchBack,
    /// Jump to a name by typing part of it.
    Find,
    /// Show only the names that match.
    Filter,
}

impl Prompt {
    /// The label before the text.
    pub fn label(self) -> &'static str {
        match self {
            Prompt::Command => ":",
            Prompt::Search => "/",
            Prompt::SearchBack => "?",
            Prompt::Find => "find:",
            Prompt::Filter => "filter:",
        }
    }

    /// What the text is, for assistive technology.
    pub fn name(self) -> &'static str {
        match self {
            Prompt::Command => "Command",
            Prompt::Search | Prompt::SearchBack => "Search",
            Prompt::Find => "Find",
            Prompt::Filter => "Filter",
        }
    }
}

#[derive(Context, Clone, Debug, Default)]
pub struct ModeCtx {
    /// The prompt the command line is open for, or was last.
    pub prompt: Prompt,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum ModeEv {
    /// Start a visual range at the cursor.
    Visual,
    /// End it, keeping the range marked; `Visual` again does the same.
    VisualEnd,
    /// End it without marking the range, as Escape and changing folders do.
    VisualCancel,
    /// Open the command line for a prompt, or switch the open one to it.
    Open(Prompt),
    /// The prompt's text changed.
    Edit,
    /// Enter, with the prompt's text.
    Submit(String),
    /// Escape: close the prompt and undo what its text did as it was typed.
    Cancel,
    /// Close the prompt, keeping what its text did, as find does on its only match.
    Accept,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ModeFx {
    /// Anchor a range at the cursor.
    StartRange,
    /// Mark the range and stop extending it.
    EndRange,
    /// The mode changed: drop pending keys, and draw the status line again.
    Changed,
    /// Show the command line for the prompt, and give it the keys.
    OpenLine(Prompt),
    /// Hide the command line, empty it, and give the keys back to the folder.
    CloseLine,
    /// Act on the text as it is typed: move to a match, or filter.
    Live(Prompt),
    /// Carry out the prompt with its text.
    Run(Prompt, String),
    /// Undo what the text did as it was typed.
    Restore(Prompt),
}

plusthree::machine! {
    pub Mode { context: ModeCtx, events: ModeEv, effects: ModeFx }
    id: "mode",
    type: parallel,
    states: {
        selection: {
            initial: normal,
            states: {
                normal: {
                    on: { ModeEv::Visual => visual },
                },
                visual: {
                    entry: |_, enq| { enq.action(ModeFx::StartRange); enq.action(ModeFx::Changed) },
                    exit: |_, enq| enq.action(ModeFx::Changed),
                    on: {
                        ModeEv::Visual => |_, enq| {
                            enq.action(ModeFx::EndRange);
                            Transition::to(mode::states::selection::NORMAL)
                        },
                        ModeEv::VisualEnd => |_, enq| {
                            enq.action(ModeFx::EndRange);
                            Transition::to(mode::states::selection::NORMAL)
                        },
                        ModeEv::VisualCancel => normal,
                    },
                },
            },
        },
        line: {
            initial: closed,
            states: {
                closed: {
                    on: {
                        ModeEv::Open(p) => |_, _| {
                            let p = *p;
                            Transition::to(mode::states::line::OPEN).patch(move |c| c.prompt(p))
                        },
                    },
                },
                open: {
                    entry: |a, enq| {
                        enq.action(ModeFx::OpenLine(a.context.prompt));
                        enq.action(ModeFx::Changed)
                    },
                    exit: |_, enq| { enq.action(ModeFx::CloseLine); enq.action(ModeFx::Changed) },
                    on: {
                        ModeEv::Open(p) => |_, enq| {
                            let p = *p;
                            enq.action(ModeFx::OpenLine(p));
                            Transition::stay().patch(move |c| c.prompt(p))
                        },
                        ModeEv::Edit => |a, enq| {
                            enq.action(ModeFx::Live(a.context.prompt));
                            Transition::stay()
                        },
                        ModeEv::Submit(text) => |a, enq| {
                            enq.action(ModeFx::Run(a.context.prompt, text.clone()));
                            Transition::to(mode::states::line::CLOSED)
                        },
                        ModeEv::Cancel => |a, enq| {
                            enq.action(ModeFx::Restore(a.context.prompt));
                            Transition::to(mode::states::line::CLOSED)
                        },
                        ModeEv::Accept => closed,
                    },
                },
            },
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::NoTimers;

    fn start() -> Driver<Mode, ()> {
        Driver::new(Mode::machine(), ())
    }

    // A prompt opened in visual mode leaves the range alone: closing it neither marks the
    // range nor leaves visual mode, so a command typed there still sees the range.
    // `v` again and visual-end mark the range; Escape and changing folders do not.
    #[test]
    fn visual_ends_marking_or_not() {
        let mut d = start();
        for end in [ModeEv::Visual, ModeEv::VisualEnd] {
            assert!(
                d.send(ModeEv::Visual, NoTimers)
                    .contains(&ModeFx::StartRange)
            );
            assert!(d.send(end, NoTimers).contains(&ModeFx::EndRange));
            assert!(d.matches(mode::states::selection::NORMAL));
        }
        d.send(ModeEv::Visual, NoTimers);
        let fx = d.send(ModeEv::VisualCancel, NoTimers);
        assert_eq!(fx, [ModeFx::Changed]);
        assert!(d.send(ModeEv::VisualEnd, NoTimers).is_empty());
    }

    #[test]
    fn a_prompt_over_visual_keeps_the_range() {
        let mut d = start();
        d.send(ModeEv::Visual, NoTimers);
        let fx = d.send(ModeEv::Open(Prompt::Command), NoTimers);
        assert_eq!(fx, [ModeFx::OpenLine(Prompt::Command), ModeFx::Changed]);
        assert!(d.matches(mode::states::selection::VISUAL));
        let fx = d.send(ModeEv::Submit("chmod +x".into()), NoTimers);
        assert!(fx.contains(&ModeFx::Run(Prompt::Command, "chmod +x".into())));
        assert!(fx.contains(&ModeFx::CloseLine));
        assert!(!fx.contains(&ModeFx::EndRange));
        assert!(d.matches(mode::states::selection::VISUAL));
        assert!(d.matches(mode::states::line::CLOSED));
    }

    // Edits act for the prompt open; once it closes, a late edit (the editor emptied as the
    // line closes) does nothing. Escape undoes what the edits did; find's only match closes it
    // without undoing.
    #[test]
    fn edits_cancel_and_accept() {
        let mut d = start();
        assert!(d.send(ModeEv::Edit, NoTimers).is_empty());
        d.send(ModeEv::Open(Prompt::Search), NoTimers);
        assert_eq!(
            d.send(ModeEv::Edit, NoTimers),
            [ModeFx::Live(Prompt::Search)]
        );
        // Switching prompts while open shows the new one without closing.
        let fx = d.send(ModeEv::Open(Prompt::Filter), NoTimers);
        assert_eq!(fx, [ModeFx::OpenLine(Prompt::Filter)]);
        // The line closes first, as exits run before a transition's actions.
        let fx = d.send(ModeEv::Cancel, NoTimers);
        assert_eq!(
            fx,
            [
                ModeFx::CloseLine,
                ModeFx::Changed,
                ModeFx::Restore(Prompt::Filter)
            ]
        );
        assert!(d.send(ModeEv::Edit, NoTimers).is_empty());

        d.send(ModeEv::Open(Prompt::Find), NoTimers);
        let fx = d.send(ModeEv::Accept, NoTimers);
        assert!(fx.contains(&ModeFx::CloseLine));
        assert!(
            !fx.iter()
                .any(|f| matches!(f, ModeFx::Restore(_) | ModeFx::Run(..)))
        );
    }
}
