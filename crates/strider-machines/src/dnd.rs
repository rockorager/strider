//! A drag over one window's folders: the target under the pointer, outlined while it takes
//! the drop; resting on a folder that opens (a folder's row or a tab) opens it after
//! [`SPRING`]; resting near a column's top or bottom edge scrolls it a row every [`SCROLL`].
//!
//! The host decides what is under the pointer and whether it takes the drag, and sends
//! [`DropEv::Enter`] only when the target changes, so the outline and the timers start over
//! for a new target and carry on for the same one.

use std::time::Duration;

use plusthree::prelude::*;

/// How long a drag rests on a folder before it opens.
pub const SPRING: Duration = Duration::from_millis(700);
/// How often a drag near a column's edge scrolls it.
pub const SCROLL: Duration = Duration::from_millis(80);

#[derive(Context, Clone, Debug, Default)]
pub struct DropCtx {
    /// Which edge the drag rests near while it scrolls: -1 the top, 1 the bottom.
    pub edge: i8,
}

#[derive(Event, Clone, Debug, PartialEq, Eq)]
pub enum DropEv {
    /// The drag came onto a new target: whether it takes the drop, and whether resting on it
    /// opens it.
    Enter { takes: bool, springs: bool },
    /// Where the drag is on a row: near the column's top (-1), its bottom (1), or neither (0).
    Edge(i8),
    /// The drag left every target here, was dropped, or ended.
    Leave,
    /// Start the spring's timer, as a target that springs is entered.
    Arm,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DropFx {
    /// Outline the target the host holds, or take the outline off.
    Outline(bool),
    /// The drag rested on the target long enough: open it.
    Open,
    /// Scroll the column a row up (-1) or down (1).
    Scroll(i8),
}

/// A new target: outlined, its spring armed, when it takes the drop.
fn enter(takes: bool, springs: bool, enq: &mut Enq<'_, Hover>) -> Transition<Hover> {
    if !takes {
        return Transition::to(hover::states::REFUSED);
    }
    if springs {
        enq.raise(DropEv::Arm);
    }
    Transition::<Hover>::to(hover::states::TAKING)
        .reenter(true)
        .patch(|p| p.edge(0))
}

/// The drag moved near an edge, or away: scrolling starts, turns, or stops.
fn edge(edge: i8, now: i8) -> Option<Transition<Hover>> {
    match edge {
        0 => Some(Transition::to(hover::states::taking::scroll::STILL)),
        e if e == now => Some(Transition::stay()),
        e => Some(
            Transition::<Hover>::to(hover::states::taking::scroll::MOVING)
                .reenter(true)
                .patch(move |p| p.edge(e.signum())),
        ),
    }
}

plusthree::machine! {
    pub Hover { context: DropCtx, events: DropEv, effects: DropFx }
    id: "hover",
    delays: {
        spring: |_| SPRING,
        scroll: |_| SCROLL,
    },
    initial: idle,
    on: {
        DropEv::Enter { takes, springs } => |_, enq| self::enter(*takes, *springs, enq),
        DropEv::Leave => .idle,
    },
    states: {
        idle: {},
        refused: {},
        taking: {
            type: parallel,
            entry: |_, enq| enq.action(DropFx::Outline(true)),
            exit: |_, enq| enq.action(DropFx::Outline(false)),
            states: {
                spring: {
                    initial: off,
                    states: {
                        off: { on: { DropEv::Arm => armed } },
                        armed: {
                            after: {
                                spring => {
                                    target: off,
                                    actions: |_, enq| { enq.action(DropFx::Open); enq.raise(DropEv::Leave) },
                                },
                            },
                        },
                    },
                },
                scroll: {
                    initial: still,
                    states: {
                        still: {
                            on: { DropEv::Edge(e) => |_, _| (*e != 0).then(|| self::edge(*e, 0)).flatten() },
                        },
                        moving: {
                            on: { DropEv::Edge(e) => |a, _| self::edge(*e, a.context.edge) },
                            after: {
                                scroll => |a, enq| {
                                    enq.action(DropFx::Scroll(a.context.edge));
                                    Transition::to(hover::states::taking::scroll::MOVING).reenter(true)
                                },
                            },
                        },
                    },
                },
            },
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::driver::Driver;
    use plusthree::host::Recorder;

    /// The timer started last, and its delay.
    fn last(r: &Recorder) -> (plusthree::host::TimerToken, std::time::Duration) {
        let t = r.started().last().expect("a timer");
        (t.token, t.delay)
    }

    fn start() -> (Driver<Hover, u32>, Recorder) {
        (Driver::new(Hover::machine(), ()), Recorder::new())
    }

    // A folder's row that takes the drag is outlined and opens once the drag rests on it;
    // opening leaves it, so whatever is under the pointer then is a new target.
    #[test]
    fn resting_on_a_folder_opens_it() {
        let (mut d, mut r) = start();
        let fx = d.send(
            DropEv::Enter {
                takes: true,
                springs: true,
            },
            &mut r,
        );
        assert_eq!(fx, [DropFx::Outline(true)]);
        assert!(d.matches(hover::states::taking::spring::ARMED));
        let (token, delay) = last(&r);
        assert_eq!(delay, SPRING);
        assert_eq!(
            d.fire(token, &mut r),
            [DropFx::Open, DropFx::Outline(false)]
        );
        assert!(d.matches(hover::states::IDLE));
    }

    // Moving to another target starts over: the old outline goes, the new one comes, and
    // the spring waits its whole time again; a target that refuses gets neither, and
    // leaving takes the outline off.
    #[test]
    fn a_new_target_starts_over() {
        let (mut d, mut r) = start();
        let row = DropEv::Enter {
            takes: true,
            springs: true,
        };
        d.send(row.clone(), &mut r);
        let (first, _) = last(&r);
        assert_eq!(
            d.send(row, &mut r),
            [DropFx::Outline(false), DropFx::Outline(true)]
        );
        let (second, _) = last(&r);
        assert_ne!(first, second);
        assert_eq!(d.fire(first, &mut r), [], "the old spring was cancelled");
        let column = DropEv::Enter {
            takes: true,
            springs: false,
        };
        d.send(column, &mut r);
        assert!(d.matches(hover::states::taking::spring::OFF));
        let own = DropEv::Enter {
            takes: false,
            springs: true,
        };
        assert_eq!(d.send(own, &mut r), [DropFx::Outline(false)]);
        assert!(d.matches(hover::states::REFUSED));
        assert_eq!(d.send(DropEv::Leave, &mut r), []);
        assert!(d.matches(hover::states::IDLE));
    }

    // Near an edge a row at a time, the same way until the drag moves away or turns.
    #[test]
    fn near_an_edge_it_scrolls() {
        let (mut d, mut r) = start();
        d.send(
            DropEv::Enter {
                takes: true,
                springs: false,
            },
            &mut r,
        );
        assert_eq!(d.send(DropEv::Edge(0), &mut r), []);
        assert!(d.matches(hover::states::taking::scroll::STILL));
        d.send(DropEv::Edge(1), &mut r);
        let (t, delay) = last(&r);
        assert_eq!(delay, SCROLL);
        assert_eq!(d.fire(t, &mut r), [DropFx::Scroll(1)]);
        let (t, _) = last(&r);
        // The same edge keeps its timer.
        d.send(DropEv::Edge(1), &mut r);
        assert_eq!(d.fire(t, &mut r), [DropFx::Scroll(1)]);
        d.send(DropEv::Edge(-1), &mut r);
        let (t, _) = last(&r);
        assert_eq!(d.fire(t, &mut r), [DropFx::Scroll(-1)]);
        d.send(DropEv::Edge(0), &mut r);
        assert!(d.matches(hover::states::taking::scroll::STILL));
    }
}
