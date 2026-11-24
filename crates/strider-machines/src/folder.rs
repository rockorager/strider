//! One cached folder's reads: the first read, which a column shows "Loading…" for and a
//! preview that moves on gives up; reads again when the folder changed on disk, at once while
//! a column shows it and when next shown otherwise; and an unwatched folder read again when a
//! column shows it after it has grown old.
//!
//! The host reads on a worker when the machine says [`FolderFx::Read`] and sends
//! [`FolderEv::Read`] when the read is done; the listing stays with the host.

use plusthree::prelude::*;

#[derive(Context, Clone, Debug, Default)]
pub struct FolderCtx {
    /// A column shows the folder.
    pub shown: bool,
    /// It changed while a read was in flight, which may have missed the change.
    pub again: bool,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum FolderEv {
    /// A column shows the folder; `old`: it is not watched, and its last read is older than
    /// `stale_ms`.
    Show { old: bool },
    /// No column shows it any more.
    Hide,
    /// The watcher saw it change.
    Changed,
    /// The read in flight is done; its result is the host's to apply.
    Read,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FolderFx {
    /// Read the folder on a worker.
    Read,
    /// Drop the read in flight: nothing waits for it.
    Cancel,
    /// Show the read that came in.
    Apply,
}

plusthree::machine! {
    pub Folder { context: FolderCtx, events: FolderEv, effects: FolderFx }
    id: "folder",
    initial: unread,
    on: {
        FolderEv::Hide => |_, _| Transition::stay().patch(|p| p.shown(false)),
    },
    states: {
        unread: {
            on: {
                FolderEv::Show { .. } => { target: loading, actions: |_, _| Some(FolderCtxPatch::default().shown(true)) },
            },
        },
        // The first read: there is nothing to show yet.
        loading: {
            entry: |_, enq| enq.action(FolderFx::Read),
            on: {
                FolderEv::Show { .. } => |_, _| Transition::stay().patch(|p| p.shown(true)),
                // A preview that moved on: nobody waits for it.
                FolderEv::Hide => |_, enq| {
                    enq.action(FolderFx::Cancel);
                    Transition::to(folder::states::UNREAD).patch(|p| p.shown(false).again(false))
                },
                FolderEv::Changed => |_, _| Transition::stay().patch(|p| p.again(true)),
                FolderEv::Read => |a, enq| Some(self::done(a, enq)),
            },
        },
        // Read again, while the last read shows.
        refreshing: {
            entry: |_, enq| enq.action(FolderFx::Read),
            on: {
                FolderEv::Show { .. } => |_, _| Transition::stay().patch(|p| p.shown(true)),
                FolderEv::Changed => |_, _| Transition::stay().patch(|p| p.again(true)),
                FolderEv::Read => |a, enq| Some(self::done(a, enq)),
            },
        },
        loaded: {
            initial: fresh,
            states: {
                fresh: {
                    on: {
                        FolderEv::Changed => [
                            { target: #folder.refreshing, guard: |a| a.context.shown },
                            { target: dirty },
                        ],
                        FolderEv::Show { old } => |_, _| Transition::to(if *old {
                            folder::states::REFRESHING
                        } else {
                            folder::states::loaded::FRESH
                        })
                        .patch(|p| p.shown(true)),
                    },
                },
                // Changed while no column showed it: read when one does.
                dirty: {
                    on: {
                        FolderEv::Show { .. } => { target: #folder.refreshing, actions: |_, _| Some(FolderCtxPatch::default().shown(true)) },
                    },
                },
            },
        },
    }
}

/// A read came in: show it, and read again if the folder changed meanwhile and a column
/// shows it.
fn done(a: &Args<'_, Folder>, enq: &mut Enq<'_, Folder>) -> Transition<Folder> {
    enq.action(FolderFx::Apply);
    let target = match (a.context.again, a.context.shown) {
        (true, true) => folder::states::REFRESHING,
        (true, false) => folder::states::loaded::DIRTY,
        (false, _) => folder::states::loaded::FRESH,
    };
    Transition::<Folder>::to(target)
        .reenter(true)
        .patch(|p| p.again(false))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::NoTimers;

    fn start() -> Driver<Folder, ()> {
        Driver::new(Folder::machine(), ())
    }

    // A change during a read may have been missed by it: the folder is read once more when
    // that read is in, while a column shows it, and not when none does.
    #[test]
    fn a_change_during_a_read_reads_again_after_it() {
        let mut d = start();
        assert_eq!(
            d.send(FolderEv::Show { old: false }, NoTimers),
            [FolderFx::Read]
        );
        assert!(d.send(FolderEv::Changed, NoTimers).is_empty());
        assert_eq!(
            d.send(FolderEv::Read, NoTimers),
            [FolderFx::Apply, FolderFx::Read]
        );
        assert!(d.matches(super::folder::states::REFRESHING));
        assert_eq!(d.send(FolderEv::Read, NoTimers), [FolderFx::Apply]);
        assert!(d.matches(super::folder::states::loaded::FRESH));

        // A change during a read again, and the folder hidden before it is in: the change
        // waits for the folder to be shown again.
        assert_eq!(d.send(FolderEv::Changed, NoTimers), [FolderFx::Read]);
        d.send(FolderEv::Changed, NoTimers);
        d.send(FolderEv::Hide, NoTimers);
        assert_eq!(d.send(FolderEv::Read, NoTimers), [FolderFx::Apply]);
        assert!(d.matches(super::folder::states::loaded::DIRTY));
        assert_eq!(
            d.send(FolderEv::Show { old: false }, NoTimers),
            [FolderFx::Read]
        );
    }

    // A shown folder that changes reads at once; a hidden one reads only when shown again;
    // an old unwatched one reads when shown, and a fresh one does not.
    #[test]
    fn changes_and_age() {
        let mut d = start();
        d.send(FolderEv::Show { old: false }, NoTimers);
        d.send(FolderEv::Read, NoTimers);
        assert_eq!(d.send(FolderEv::Changed, NoTimers), [FolderFx::Read]);
        d.send(FolderEv::Read, NoTimers);
        d.send(FolderEv::Hide, NoTimers);
        assert!(d.send(FolderEv::Changed, NoTimers).is_empty());
        assert_eq!(
            d.send(FolderEv::Show { old: false }, NoTimers),
            [FolderFx::Read]
        );
        d.send(FolderEv::Read, NoTimers);
        assert!(d.send(FolderEv::Show { old: false }, NoTimers).is_empty());
        assert_eq!(
            d.send(FolderEv::Show { old: true }, NoTimers),
            [FolderFx::Read]
        );
    }

    // A preview that moves on gives up a first read, and is read afresh when shown again; a
    // read again of a shown folder is not given up.
    #[test]
    fn hiding_cancels_only_a_first_read() {
        let mut d = start();
        d.send(FolderEv::Show { old: false }, NoTimers);
        assert_eq!(d.send(FolderEv::Hide, NoTimers), [FolderFx::Cancel]);
        assert!(d.matches(super::folder::states::UNREAD));
        assert_eq!(
            d.send(FolderEv::Show { old: false }, NoTimers),
            [FolderFx::Read]
        );
        d.send(FolderEv::Read, NoTimers);
        d.send(FolderEv::Changed, NoTimers);
        assert!(d.send(FolderEv::Hide, NoTimers).is_empty());
        assert!(d.matches(super::folder::states::REFRESHING));
    }
}
