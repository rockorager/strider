//! The preview's job: a file under the cursor is read, listed, rendered, or decoded on a
//! worker, and at most [`MAX_JOBS`] such jobs run at once, so previews stuck on a slow or hung
//! file system cannot take the workers that read folders. A job wanted while the slots are
//! taken waits, and a newer one replaces it. Moving on kills the running job, whose slot
//! stays taken until it is done, and drops its result.
//!
//! The host keeps the job wanted and the running job's cancel flag: it starts the one on
//! [`PreviewFx::Launch`] and raises the other on [`PreviewFx::Kill`], and sends
//! [`PreviewEv::Done`] for every job that ends, killed or not.

use plusthree::prelude::*;

/// Preview jobs that may run at once.
pub const MAX_JOBS: u8 = 2;

#[derive(Context, Clone, Debug, Default)]
pub struct PreviewCtx {
    /// Jobs holding a slot: the preview's own and those killed that have not ended yet.
    pub running: u8,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum PreviewEv {
    /// Preview a file with a job, in place of the job there is.
    Start,
    /// Show what needs no job, such as a folder: the job there is goes.
    Stop,
    /// A job ended; `current`: it is the preview's own, not one it killed.
    Done { current: bool },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreviewFx {
    /// Start the job wanted on a worker.
    Launch,
    /// Kill the running job's programs, and drop its result.
    Kill,
    /// Say the job wanted waits for a slot.
    Wait,
    /// Show the job's result.
    Apply,
}

plusthree::machine! {
    pub Preview { context: PreviewCtx, events: PreviewEv, effects: PreviewFx }
    id: "preview",
    initial: idle,
    states: {
        idle: {
            on: {
                PreviewEv::Start => |a, enq| Some(self::start(a.context.running, enq)),
                PreviewEv::Done { .. } => |a, _| Some(self::freed(a.context.running)),
            },
        },
        // The job wanted waits for a slot.
        waiting: {
            on: {
                PreviewEv::Start => |_, enq| { enq.action(PreviewFx::Wait); Transition::stay() },
                PreviewEv::Stop => idle,
                // Only a killed job ends here, so its slot is the wanted job's.
                PreviewEv::Done { .. } => |_, enq| {
                    enq.action(PreviewFx::Launch);
                    Transition::to(preview::states::RUNNING)
                },
            },
        },
        running: {
            on: {
                PreviewEv::Start => |a, enq| {
                    enq.action(PreviewFx::Kill);
                    Some(self::start(a.context.running, enq))
                },
                PreviewEv::Stop => |_, enq| {
                    enq.action(PreviewFx::Kill);
                    Transition::to(preview::states::IDLE)
                },
                PreviewEv::Done { current: true } => |a, enq| {
                    enq.action(PreviewFx::Apply);
                    let running = a.context.running.saturating_sub(1);
                    Transition::to(preview::states::IDLE).patch(move |p| p.running(running))
                },
                PreviewEv::Done { current: false } => |a, _| Some(self::freed(a.context.running)),
            },
        },
    }
}

/// A job is wanted: it starts when a slot is free, and waits otherwise.
fn start(running: u8, enq: &mut Enq<'_, Preview>) -> Transition<Preview> {
    if running < MAX_JOBS {
        enq.action(PreviewFx::Launch);
        Transition::<Preview>::to(preview::states::RUNNING)
            .reenter(true)
            .patch(move |p| p.running(running + 1))
    } else {
        enq.action(PreviewFx::Wait);
        Transition::to(preview::states::WAITING)
    }
}

/// A job ended, and its slot is free.
fn freed(running: u8) -> Transition<Preview> {
    Transition::<Preview>::stay().patch(move |p| p.running(running.saturating_sub(1)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::NoTimers;

    fn start() -> Driver<Preview, ()> {
        Driver::new(Preview::machine(), ())
    }

    // Moving over files faster than they preview: each move kills the job before, which
    // holds its slot until it ends; the third waits, the newest wanted job replaces it, and
    // it starts when a killed job ends. Only the current job's result shows.
    #[test]
    fn at_most_two_jobs_and_the_newest_waiting_wins() {
        let mut d = start();
        assert_eq!(d.send(PreviewEv::Start, NoTimers), [PreviewFx::Launch]);
        assert_eq!(
            d.send(PreviewEv::Start, NoTimers),
            [PreviewFx::Kill, PreviewFx::Launch]
        );
        assert_eq!(
            d.send(PreviewEv::Start, NoTimers),
            [PreviewFx::Kill, PreviewFx::Wait]
        );
        assert_eq!(d.send(PreviewEv::Start, NoTimers), [PreviewFx::Wait]);
        assert_eq!(
            d.send(PreviewEv::Done { current: false }, NoTimers),
            [PreviewFx::Launch]
        );
        assert_eq!(d.send(PreviewEv::Done { current: false }, NoTimers), []);
        assert_eq!(
            d.send(PreviewEv::Done { current: true }, NoTimers),
            [PreviewFx::Apply]
        );
        assert!(d.matches(preview::states::IDLE));
        assert_eq!(d.context().running, 0);
    }

    // Moving on to a folder kills the job, and a late end of it shows nothing.
    #[test]
    fn stopping_drops_the_result() {
        let mut d = start();
        d.send(PreviewEv::Start, NoTimers);
        assert_eq!(d.send(PreviewEv::Stop, NoTimers), [PreviewFx::Kill]);
        assert!(
            d.send(PreviewEv::Done { current: false }, NoTimers)
                .is_empty()
        );
        assert_eq!(d.context().running, 0);
    }
}
