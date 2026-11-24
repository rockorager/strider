//! A file chooser request, from the FileChooser portal's call to its answer: the window shows
//! while the user chooses; saving over files that exist asks first; the answer goes back
//! once, as the portal's response, 0 with what was picked, 1 when the user cancelled (Escape,
//! q, the Cancel button, or closing the window), and 2 when the caller closed the request or
//! the window could not open. After the answer nothing changes it.
//!
//! The host keeps what was picked: it sends [`ChooserEv::Pick`] once it knows, and replies
//! with those paths on [`ChooserFx::Answer`] with [`Response::Picked`].

use plusthree::prelude::*;

/// The portal's response codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Response {
    /// The user picked: the URIs go with it.
    Picked = 0,
    /// The user cancelled.
    Cancelled = 1,
    /// The caller closed the request, or it could not go on.
    Ended = 2,
}

#[derive(Context, Clone, Debug, Default)]
pub struct ChooserCtx {}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum ChooserEv {
    /// The user picked, and nothing that exists is replaced without asking.
    Pick,
    /// The user picked, replacing files that exist: ask first.
    Ask,
    /// The overwrite dialog said Replace.
    Replace,
    /// The overwrite dialog was cancelled: back to the name, to type another.
    KeepEditing,
    /// Escape with nothing to clear, q, or the Cancel button.
    Cancel,
    /// The caller (or xdg-desktop-portal) closed the request object.
    Close,
    /// The window went, closed by the user or the compositor.
    WindowGone,
    /// The window could not open.
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChooserFx {
    /// Reply to the portal's call with this response.
    Answer(Response),
    /// Close the request's window; its type filter and request object go with it.
    CloseWindow,
    /// Show the overwrite dialog.
    AskOverwrite,
    /// Focus the name again.
    BackToName,
}

plusthree::machine! {
    pub Chooser { context: ChooserCtx, events: ChooserEv, effects: ChooserFx }
    id: "chooser",
    initial: open,
    states: {
        open: {
            initial: choosing,
            on: {
                ChooserEv::Cancel => |_, enq| Some(self::answer(Response::Cancelled, true, enq)),
                ChooserEv::Close => |_, enq| Some(self::answer(Response::Ended, true, enq)),
                // The window is gone already: nothing to close.
                ChooserEv::WindowGone => |_, enq| Some(self::answer(Response::Cancelled, false, enq)),
                ChooserEv::Failed => |_, enq| Some(self::answer(Response::Ended, false, enq)),
            },
            states: {
                choosing: {
                    on: {
                        ChooserEv::Pick => |_, enq| Some(self::answer(Response::Picked, true, enq)),
                        ChooserEv::Ask => |_, enq| {
                            enq.action(ChooserFx::AskOverwrite);
                            Transition::to(chooser::states::open::CONFIRMING)
                        },
                    },
                },
                // The overwrite dialog is open.
                confirming: {
                    on: {
                        ChooserEv::Replace => |_, enq| Some(self::answer(Response::Picked, true, enq)),
                        ChooserEv::KeepEditing => |_, enq| {
                            enq.action(ChooserFx::BackToName);
                            Transition::to(chooser::states::open::CHOOSING)
                        },
                    },
                },
            },
        },
        // Answered: the request is over.
        answered: {},
    }
}

/// The one answer, and the window closing with it unless it is gone.
fn answer(r: Response, close: bool, enq: &mut Enq<'_, Chooser>) -> Transition<Chooser> {
    enq.action(ChooserFx::Answer(r));
    if close {
        enq.action(ChooserFx::CloseWindow);
    }
    Transition::to(chooser::states::ANSWERED)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::NoTimers;

    fn start() -> Driver<Chooser, ()> {
        Driver::new(Chooser::machine(), ())
    }

    // A pick answers 0 and closes the window; anything after it, such as the window going
    // as it closes, answers nothing more. Catches: a second reply to the same call, which
    // the bus rejects and the caller never expects.
    #[test]
    fn a_pick_answers_once() {
        let mut d = start();
        assert_eq!(
            d.send(ChooserEv::Pick, NoTimers),
            [ChooserFx::Answer(Response::Picked), ChooserFx::CloseWindow]
        );
        assert!(d.matches(chooser::states::ANSWERED));
        for ev in [ChooserEv::WindowGone, ChooserEv::Cancel, ChooserEv::Close] {
            assert_eq!(d.send(ev, NoTimers), []);
        }
    }

    // Saving over a file asks first: Cancel there goes back to the name without answering,
    // Replace answers 0; the caller's Close or the user's Cancel while it asks answer too.
    // Catches: a file replaced without asking, a cancelled dialog cancelling the request.
    #[test]
    fn replacing_asks_first() {
        let mut d = start();
        assert_eq!(d.send(ChooserEv::Ask, NoTimers), [ChooserFx::AskOverwrite]);
        assert_eq!(
            d.send(ChooserEv::KeepEditing, NoTimers),
            [ChooserFx::BackToName]
        );
        assert!(d.matches(chooser::states::open::CHOOSING));
        // Replace means nothing unless the dialog asks.
        assert_eq!(d.send(ChooserEv::Replace, NoTimers), []);
        d.send(ChooserEv::Ask, NoTimers);
        assert_eq!(
            d.send(ChooserEv::Replace, NoTimers),
            [ChooserFx::Answer(Response::Picked), ChooserFx::CloseWindow]
        );

        let mut d = start();
        d.send(ChooserEv::Ask, NoTimers);
        assert_eq!(
            d.send(ChooserEv::Close, NoTimers),
            [ChooserFx::Answer(Response::Ended), ChooserFx::CloseWindow]
        );
    }

    // Cancelling answers 1 and closes the window; the window closed by the user answers 1
    // with nothing to close; the caller's Close answers 2; a window that could not open
    // answers 2. Catches: the wrong response code, closing a window that is gone.
    #[test]
    fn cancel_close_and_the_window_going() {
        let cases = [
            (
                ChooserEv::Cancel,
                vec![
                    ChooserFx::Answer(Response::Cancelled),
                    ChooserFx::CloseWindow,
                ],
            ),
            (
                ChooserEv::WindowGone,
                vec![ChooserFx::Answer(Response::Cancelled)],
            ),
            (
                ChooserEv::Close,
                vec![ChooserFx::Answer(Response::Ended), ChooserFx::CloseWindow],
            ),
            (ChooserEv::Failed, vec![ChooserFx::Answer(Response::Ended)]),
        ];
        for (ev, fx) in cases {
            let mut d = start();
            assert_eq!(d.send(ev, NoTimers), fx);
            assert!(d.matches(chooser::states::ANSWERED));
        }
    }
}
