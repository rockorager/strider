//! A drive job: the steps of mounting, unlocking, unmounting, locking, and ejecting a drive
//! through UDisks2, one call at a time, each started when the one before answers. Unlocking
//! mounts the cleartext device after; mounting just after an unlock is tried again while
//! UDisks2 has not yet probed the new device's file system; unmounting locks the encrypted
//! volume the file system is on and ejects (or powers off) its drive when asked. A polkit
//! prompt the user dismissed ends the job quietly.
//!
//! The host keeps what each call acts on (the block, the cleartext device a successful unlock
//! answered with, the drive), makes the call on [`JobFx::Call`], and sends its answer.

use std::time::Duration;

use plusthree::prelude::*;

/// How many times a mount just after an unlock is tried again, and how long apart.
pub const MOUNT_RETRIES: u8 = 10;
pub const RETRY_DELAY: Duration = Duration::from_millis(200);

/// What a job does, from its first step.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Plan {
    /// Mount, and go to where it mounted.
    #[default]
    Mount,
    /// Unlock with a passphrase, then mount.
    Unlock,
    /// Unmount; then lock the encrypted volume under it with `lock`; then eject with `eject`.
    Unmount {
        lock: bool,
        eject: bool,
    },
    /// Lock an unlocked volume that is not mounted, then eject with `eject`.
    Lock {
        eject: bool,
    },
    Eject,
}

/// A call to UDisks2.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Unlock,
    Mount,
    Unmount,
    Lock,
    /// Eject the drive, or power it off when it is not ejectable.
    Eject,
}

impl Step {
    /// The verb for "Cannot … the drive".
    pub fn verb(self) -> &'static str {
        match self {
            Step::Unlock => "unlock",
            Step::Mount => "mount",
            Step::Unmount => "unmount",
            Step::Lock => "lock",
            Step::Eject => "eject",
        }
    }
}

#[derive(Context, Clone, Debug, Default)]
pub struct JobCtx {
    pub lock_after: bool,
    pub eject_after: bool,
    /// Mounts tried again so far.
    pub retries: u8,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum JobEv {
    Start(Plan),
    /// The call answered.
    Ok,
    /// The call failed with D-Bus error `name` and its message, `detail`.
    Error {
        name: String,
        detail: String,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobFx {
    /// Make the call.
    Call(Step),
    /// Say it is unlocked (the mount follows).
    Unlocked,
    /// Go to where it mounted, which the call answered.
    Mounted,
    /// Say the drive can be removed.
    Removable,
    /// Say the step failed; an unlock asks for the passphrase again.
    Failed { step: Step, detail: String },
    /// The user dismissed the unlock's polkit prompt.
    NotUnlocked,
    /// The job is over: forget it.
    Done,
}

/// The user dismissed polkit's prompt.
fn dismissed(name: &str) -> bool {
    name.ends_with(".NotAuthorizedDismissed")
}

/// UDisks2 does not know the device's file system yet, as just after an unlock.
fn not_ready(name: &str) -> bool {
    [".UnknownMethod", ".UnknownInterface", ".UnknownObject"]
        .iter()
        .any(|s| name.ends_with(s))
}

/// A step failed: quietly when dismissed, else saying why.
fn failed(step: Step, name: &str, detail: &str, enq: &mut Enq<'_, Job>) -> Transition<Job> {
    if dismissed(name) {
        if step == Step::Unlock {
            enq.action(JobFx::NotUnlocked);
        }
    } else {
        let detail = if detail.is_empty() { name } else { detail };
        enq.action(JobFx::Failed {
            step,
            detail: detail.to_owned(),
        });
    }
    Transition::to(job::states::DONE)
}

/// What follows unmounting or locking: locking, ejecting, or the end.
fn after_unmount(lock: bool, eject: bool, enq: &mut Enq<'_, Job>) -> Transition<Job> {
    if lock {
        Transition::to(job::states::LOCKING)
    } else if eject {
        Transition::to(job::states::EJECTING)
    } else {
        enq.action(JobFx::Removable);
        Transition::to(job::states::DONE)
    }
}

plusthree::machine! {
    pub Job { context: JobCtx, events: JobEv, effects: JobFx }
    id: "job",
    delays: {
        retry: |_| RETRY_DELAY,
    },
    initial: idle,
    states: {
        idle: {
            on: {
                JobEv::Start(plan) => |_, _| match *plan {
                    Plan::Mount => Transition::to(job::states::MOUNTING),
                    Plan::Unlock => Transition::to(job::states::UNLOCKING),
                    Plan::Unmount { lock, eject } => Transition::to(job::states::UNMOUNTING)
                        .patch(move |p| p.lock_after(lock).eject_after(eject)),
                    Plan::Lock { eject } => Transition::to(job::states::LOCKING)
                        .patch(move |p| p.eject_after(eject)),
                    Plan::Eject => Transition::to(job::states::EJECTING),
                },
            },
        },
        unlocking: {
            entry: |_, enq| enq.action(JobFx::Call(Step::Unlock)),
            on: {
                JobEv::Ok => |_, enq| { enq.action(JobFx::Unlocked); Transition::to(job::states::MOUNTING) },
                JobEv::Error { name, detail } => |_, enq| self::failed(Step::Unlock, name, detail, enq),
            },
        },
        mounting: {
            entry: |_, enq| enq.action(JobFx::Call(Step::Mount)),
            on: {
                JobEv::Ok => |_, enq| { enq.action(JobFx::Mounted); Transition::to(job::states::DONE) },
                JobEv::Error { name, detail } => |a, enq| {
                    let retries = a.context.retries;
                    if self::not_ready(name) && retries < MOUNT_RETRIES {
                        Transition::to(job::states::WAITING).patch(move |p| p.retries(retries + 1))
                    } else {
                        self::failed(Step::Mount, name, detail, enq)
                    }
                },
            },
        },
        // Before mounting again.
        waiting: {
            after: { retry => mounting },
        },
        unmounting: {
            entry: |_, enq| enq.action(JobFx::Call(Step::Unmount)),
            on: {
                JobEv::Ok => |a, enq| self::after_unmount(a.context.lock_after, a.context.eject_after, enq),
                JobEv::Error { name, detail } => |_, enq| self::failed(Step::Unmount, name, detail, enq),
            },
        },
        locking: {
            entry: |_, enq| enq.action(JobFx::Call(Step::Lock)),
            on: {
                JobEv::Ok => |a, enq| self::after_unmount(false, a.context.eject_after, enq),
                JobEv::Error { name, detail } => |_, enq| self::failed(Step::Lock, name, detail, enq),
            },
        },
        ejecting: {
            entry: |_, enq| enq.action(JobFx::Call(Step::Eject)),
            on: {
                JobEv::Ok => |_, enq| { enq.action(JobFx::Removable); Transition::to(job::states::DONE) },
                JobEv::Error { name, detail } => |_, enq| self::failed(Step::Eject, name, detail, enq),
            },
        },
        done: { type: final, entry: |_, enq| enq.action(JobFx::Done) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::{Scheduler, TimerToken};

    /// Timers the tests fire by hand.
    #[derive(Default)]
    struct Timers(Vec<TimerToken>);

    impl Scheduler<TimerToken> for &mut Timers {
        fn schedule(&mut self, _: Duration, token: TimerToken) -> TimerToken {
            self.0.push(token);
            token
        }
        fn cancel(&mut self, timer: TimerToken) {
            self.0.retain(|&t| t != timer);
        }
    }

    fn error(name: &str, detail: &str) -> JobEv {
        JobEv::Error {
            name: name.into(),
            detail: detail.into(),
        }
    }

    // Unlocking mounts the cleartext device; a mount UDisks2 is not ready for yet is tried
    // again after the delay, then goes there.
    #[test]
    fn unlock_then_mount_with_a_retry() {
        let mut t = Timers::default();
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        assert_eq!(
            d.send(JobEv::Start(Plan::Unlock), &mut t),
            [JobFx::Call(Step::Unlock)]
        );
        assert_eq!(
            d.send(JobEv::Ok, &mut t),
            [JobFx::Unlocked, JobFx::Call(Step::Mount)]
        );
        let unknown = "org.freedesktop.DBus.Error.UnknownMethod";
        assert!(d.send(error(unknown, "no Filesystem"), &mut t).is_empty());
        assert!(d.matches(job::states::WAITING));
        let token = t.0.pop().expect("the retry's timer");
        assert_eq!(d.fire(token, &mut t), [JobFx::Call(Step::Mount)]);
        assert_eq!(d.context().retries, 1);
        assert_eq!(d.send(JobEv::Ok, &mut t), [JobFx::Mounted, JobFx::Done]);
    }

    // After ten retries the mount fails, saying why.
    #[test]
    fn retries_run_out() {
        let mut t = Timers::default();
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        d.send(JobEv::Start(Plan::Mount), &mut t);
        let unknown = "org.freedesktop.DBus.Error.UnknownObject";
        for _ in 0..MOUNT_RETRIES {
            d.send(error(unknown, ""), &mut t);
            let token = t.0.pop().expect("the retry's timer");
            d.fire(token, &mut t);
        }
        assert_eq!(
            d.send(error(unknown, ""), &mut t),
            [
                JobFx::Failed {
                    step: Step::Mount,
                    detail: unknown.into()
                },
                JobFx::Done
            ]
        );
    }

    // A wrong passphrase fails the unlock with UDisks2's words, for the prompt to ask again;
    // a dismissed polkit prompt says only that it is not unlocked, and a dismissed mount
    // nothing.
    #[test]
    fn failed_and_dismissed_unlocks() {
        let mut t = Timers::default();
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        d.send(JobEv::Start(Plan::Unlock), &mut t);
        let fx = d.send(
            error("org.freedesktop.UDisks2.Error.Failed", "No key available"),
            &mut t,
        );
        assert_eq!(
            fx,
            [
                JobFx::Failed {
                    step: Step::Unlock,
                    detail: "No key available".into()
                },
                JobFx::Done
            ]
        );
        let dismissed = "org.freedesktop.UDisks2.Error.NotAuthorizedDismissed";
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        d.send(JobEv::Start(Plan::Unlock), &mut t);
        assert_eq!(
            d.send(error(dismissed, ""), &mut t),
            [JobFx::NotUnlocked, JobFx::Done]
        );
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        d.send(JobEv::Start(Plan::Mount), &mut t);
        assert_eq!(d.send(error(dismissed, ""), &mut t), [JobFx::Done]);
    }

    // Ejecting an unlocked volume: unmount, lock, power off, then it can be removed; a plain
    // unmount says so at once; a lock that fails stops there.
    #[test]
    fn unmount_lock_eject() {
        let mut t = Timers::default();
        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        let plan = Plan::Unmount {
            lock: true,
            eject: true,
        };
        assert_eq!(
            d.send(JobEv::Start(plan), &mut t),
            [JobFx::Call(Step::Unmount)]
        );
        assert_eq!(d.send(JobEv::Ok, &mut t), [JobFx::Call(Step::Lock)]);
        assert_eq!(d.send(JobEv::Ok, &mut t), [JobFx::Call(Step::Eject)]);
        assert_eq!(d.send(JobEv::Ok, &mut t), [JobFx::Removable, JobFx::Done]);

        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        let plan = Plan::Unmount {
            lock: false,
            eject: false,
        };
        d.send(JobEv::Start(plan), &mut t);
        assert_eq!(d.send(JobEv::Ok, &mut t), [JobFx::Removable, JobFx::Done]);

        let mut d: Driver<Job, TimerToken> = Driver::new(Job::machine(), ());
        d.send(JobEv::Start(Plan::Lock { eject: true }), &mut t);
        let fx = d.send(error("x.Busy", "Device busy"), &mut t);
        assert_eq!(
            fx,
            [
                JobFx::Failed {
                    step: Step::Lock,
                    detail: "Device busy".into()
                },
                JobFx::Done
            ]
        );
    }
}
