//! One file operation (copy, move, link, trash, delete, restore, move back, chmod, chown)
//! from start to end, while a worker does the work. The worker counts what there is to do,
//! then does it; a conflict (the name a file would land on exists) waits for an answer, unless
//! an earlier answer was for every conflict or the operation started with one, as
//! paste-overwrite starts with replace. Pausing holds the worker at its next item or chunk,
//! asking or not; cancelling stops it there, or at once when it waits for an answer. Whatever
//! the chart says last, the worker's own end decides how the operation ended: one that finished
//! as it was cancelled is done.
//!
//! Errors are not asked about: as in the Zig build, the first one ends the operation, leaving
//! what was done done. Progress is not stepped through the chart either; the host reads the
//! worker's counters when it draws.

use plusthree::prelude::*;
use strider_core::fsops::Resolution;

#[derive(Context, Clone, Debug, Default)]
pub struct OpCtx {
    /// The answer for every conflict from now on.
    pub policy: Option<Resolution>,
}

/// How the worker ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum End {
    Done,
    Failed,
    Cancelled,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum OpEv {
    /// The worker counted what there is to do and is doing it.
    Counted,
    /// The worker found a conflict and waits for its answer; `both_dirs`: a folder would land
    /// on a folder.
    Conflict {
        both_dirs: bool,
    },
    /// The host's answer to the conflict asked about, for every later one too with `all`.
    Answer {
        resolution: Resolution,
        all: bool,
    },
    Pause,
    Resume,
    Cancel,
    /// The worker is done, however it ended.
    Ended(End),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpFx {
    /// Show the conflict the worker waits on.
    Ask,
    /// The worker goes on with this answer.
    Resolve(Resolution),
    /// Hold the worker at its next item or chunk.
    Hold,
    /// Let a held worker go on.
    Release,
    /// Stop the worker at its next item or chunk, or at once if it waits for an answer or is
    /// held.
    Stop,
    /// The state the tasks view shows changed: counting, asking, paused, or stopping.
    Changed,
    Finished(End),
}

plusthree::machine! {
    pub Operation { context: OpCtx, events: OpEv, effects: OpFx, input: Option<Resolution> }
    id: "operation",
    init: |policy: &Option<Resolution>| OpCtx { policy: *policy },
    initial: active,
    on: {
        OpEv::Ended(end) => |_, _| Transition::to(match end {
            End::Done => operation::states::DONE,
            End::Failed => operation::states::FAILED,
            End::Cancelled => operation::states::CANCELLED,
        }),
    },
    states: {
        active: {
            type: parallel,
            on: { OpEv::Cancel => stopping },
            states: {
                work: {
                    initial: counting,
                    states: {
                        counting: {
                            exit: |_, enq| enq.action(OpFx::Changed),
                            on: { OpEv::Counted => running },
                        },
                        running: {
                            on: {
                                OpEv::Conflict { both_dirs } => |a, enq| match a.context.policy {
                                    Some(p) => {
                                        enq.action(OpFx::Resolve(p.for_conflict(*both_dirs)));
                                        Transition::stay()
                                    }
                                    None => Transition::to(operation::states::active::work::ASKING),
                                },
                            },
                        },
                        asking: {
                            entry: |_, enq| { enq.action(OpFx::Ask); enq.action(OpFx::Changed) },
                            exit: |_, enq| enq.action(OpFx::Changed),
                            on: {
                                OpEv::Answer { resolution: Resolution::Cancel, .. } => #operation.stopping,
                                OpEv::Answer { resolution, all } => |_, enq| {
                                    let (r, all) = (*resolution, *all);
                                    enq.action(OpFx::Resolve(r));
                                    Transition::to(operation::states::active::work::RUNNING)
                                        .patch(move |p| if all { p.policy(Some(r)) } else { p })
                                },
                            },
                        },
                    },
                },
                hold: {
                    initial: going,
                    states: {
                        going: { on: { OpEv::Pause => paused } },
                        paused: {
                            entry: |_, enq| { enq.action(OpFx::Hold); enq.action(OpFx::Changed) },
                            on: {
                                OpEv::Resume => {
                                    target: going,
                                    actions: |_, enq| { enq.action(OpFx::Release); enq.action(OpFx::Changed); None },
                                },
                            },
                        },
                    },
                },
            },
        },
        // Asked to stop; waiting for the worker to see it.
        stopping: {
            entry: |_, enq| { enq.action(OpFx::Stop); enq.action(OpFx::Changed) },
        },
        done: { type: final, entry: |_, enq| enq.action(OpFx::Finished(End::Done)) },
        failed: { type: final, entry: |_, enq| enq.action(OpFx::Finished(End::Failed)) },
        cancelled: { type: final, entry: |_, enq| enq.action(OpFx::Finished(End::Cancelled)) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use operation::states::{self, active::hold, active::work};
    use plusthree::host::NoTimers;

    fn start(policy: Option<Resolution>) -> Driver<Operation, ()> {
        let mut d = Driver::new(Operation::machine(), policy);
        assert_eq!(d.send(OpEv::Counted, NoTimers), [OpFx::Changed]);
        d
    }

    fn conflict(d: &mut Driver<Operation, ()>, both_dirs: bool) -> Vec<OpFx> {
        d.send(OpEv::Conflict { both_dirs }, NoTimers)
    }

    fn answer(d: &mut Driver<Operation, ()>, resolution: Resolution, all: bool) -> Vec<OpFx> {
        d.send(OpEv::Answer { resolution, all }, NoTimers)
    }

    // Each conflict is asked about until an answer is for all of them; after that, merging
    // replaces files and replacing merges folders, as fsops' policy does.
    #[test]
    fn answers_for_all_conflicts() {
        let mut d = start(None);
        assert_eq!(conflict(&mut d, false), [OpFx::Ask, OpFx::Changed]);
        assert!(d.matches(work::ASKING));
        assert_eq!(
            answer(&mut d, Resolution::Skip, false),
            [OpFx::Changed, OpFx::Resolve(Resolution::Skip)]
        );
        assert_eq!(conflict(&mut d, false), [OpFx::Ask, OpFx::Changed]);
        answer(&mut d, Resolution::Merge, true);
        assert_eq!(
            conflict(&mut d, false),
            [OpFx::Resolve(Resolution::Replace)]
        );
        assert_eq!(conflict(&mut d, true), [OpFx::Resolve(Resolution::Merge)]);
        assert!(d.matches(work::RUNNING));
    }

    // Paste-overwrite starts with replace: nothing is asked, and two folders merge.
    #[test]
    fn a_starting_policy_asks_nothing() {
        let mut d = start(Some(Resolution::Replace));
        assert_eq!(
            conflict(&mut d, false),
            [OpFx::Resolve(Resolution::Replace)]
        );
        assert_eq!(conflict(&mut d, true), [OpFx::Resolve(Resolution::Merge)]);
        let mut d = start(Some(Resolution::KeepBoth));
        assert_eq!(
            conflict(&mut d, true),
            [OpFx::Resolve(Resolution::KeepBoth)]
        );
    }

    // Cancel as an answer stops the worker and is not remembered; the worker's end then says
    // the operation was cancelled.
    #[test]
    fn cancel_as_an_answer_stops() {
        let mut d = start(None);
        conflict(&mut d, false);
        let fx = answer(&mut d, Resolution::Cancel, true);
        assert_eq!(fx, [OpFx::Changed, OpFx::Stop, OpFx::Changed]);
        assert!(d.matches(states::STOPPING));
        assert_eq!(
            d.send(OpEv::Ended(End::Cancelled), NoTimers),
            [OpFx::Finished(End::Cancelled)]
        );
        assert!(d.send(OpEv::Pause, NoTimers).is_empty());
    }

    // Pausing is apart from asking: a paused operation can be asked, answered, and cancelled,
    // and resuming releases the worker only from a pause.
    #[test]
    fn pause_resume_and_cancel() {
        let mut d = start(None);
        assert!(d.send(OpEv::Resume, NoTimers).is_empty());
        assert_eq!(d.send(OpEv::Pause, NoTimers), [OpFx::Hold, OpFx::Changed]);
        assert!(d.send(OpEv::Pause, NoTimers).is_empty());
        conflict(&mut d, false);
        assert!(d.matches(work::ASKING) && d.matches(hold::PAUSED));
        answer(&mut d, Resolution::Skip, false);
        assert!(d.matches(hold::PAUSED));
        assert_eq!(
            d.send(OpEv::Resume, NoTimers),
            [OpFx::Release, OpFx::Changed]
        );
        d.send(OpEv::Pause, NoTimers);
        // Stopping wakes a held worker itself, so no release comes first.
        assert_eq!(d.send(OpEv::Cancel, NoTimers), [OpFx::Stop, OpFx::Changed]);
        assert!(d.send(OpEv::Cancel, NoTimers).is_empty());
        assert!(d.send(OpEv::Resume, NoTimers).is_empty());
    }

    // The worker's end decides: one that finished before it saw the cancel is done, and a
    // failure while counting is a failure.
    #[test]
    fn the_worker_says_how_it_ended() {
        let mut d = start(None);
        d.send(OpEv::Cancel, NoTimers);
        assert_eq!(
            d.send(OpEv::Ended(End::Done), NoTimers),
            [OpFx::Finished(End::Done)]
        );
        assert!(d.matches(states::DONE));
        let mut d: Driver<Operation, ()> = Driver::new(Operation::machine(), None);
        assert_eq!(
            d.send(OpEv::Ended(End::Failed), NoTimers),
            [OpFx::Changed, OpFx::Finished(End::Failed)]
        );
        // An answer nobody asked for does nothing.
        let mut d = start(None);
        assert!(answer(&mut d, Resolution::Replace, true).is_empty());
        assert_eq!(conflict(&mut d, false), [OpFx::Ask, OpFx::Changed]);
    }
}
