//! Runs a machine for a host on plusthree's [`Driven`]: steps it, starts and stops its
//! timers through the host's [`Scheduler`] as it goes, and hands back the machine's own
//! effects.

use plusthree::host::{Driven, NoTimers, Scheduler, TimerToken};
use plusthree::prelude::*;

/// A machine with its snapshot and the host's handles `H` for its timers.
pub struct Driver<T: Types + 'static, H> {
    driven: Driven<'static, T, H>,
}

impl<T: Types, H> Driver<T, H> {
    /// Starts `machine` with `input`. Strider's machines start no timer in their initial
    /// states, so this needs no host yet; what they ask for as they start is dropped, since
    /// the app draws everything once it has built.
    pub fn new(machine: &'static Machine<T>, input: T::Input) -> Self
    where
        T::Error: std::fmt::Debug,
    {
        let mut driven = Driven::start(machine, input, NoTimers)
            .expect("a machine's first step fails only on a bug");
        driven.effects_mut().drain().for_each(drop);
        Driver { driven }
    }

    pub fn context(&self) -> &T::Context {
        self.driven.snapshot().context()
    }

    pub fn matches(&self, s: impl StateKey<T>) -> bool {
        self.driven.snapshot().matches(s)
    }

    /// Steps the machine with `event`, starting and stopping timers through `timers`.
    pub fn send(&mut self, event: T::Event, timers: impl Scheduler<H>) -> Vec<T::Effect> {
        self.driven.step(event, timers);
        self.actions()
    }

    /// The timer started for `token` is due. One the machine cancelled or armed again
    /// since, whose callback was already queued, does nothing.
    pub fn fire(&mut self, token: TimerToken, timers: impl Scheduler<H>) -> Vec<T::Effect> {
        match self.driven.fire(token, timers) {
            Some(_) => self.actions(),
            None => Vec::new(),
        }
    }

    fn actions(&mut self) -> Vec<T::Effect> {
        // Strider's machines raise, emit, log, and spawn nothing the host must carry out:
        // what they ask for goes through their own effects.
        self.driven
            .effects_mut()
            .drain()
            .filter_map(|e| match e {
                Effect::Action(a) => Some(a),
                _ => None,
            })
            .collect()
    }
}
