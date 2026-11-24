//! Keys on their way to commands: a count typed first, the keys of a sequence pending, and the
//! which-key popup that lists how they continue once `which_key_delay` has passed.
//!
//! The host looks each key up in the keymap with [`sequence`] of the pending keys and the new
//! one, and sends what it found; the machine keeps the pending keys and the count, and says
//! what to run.

use std::time::Duration;

use plusthree::prelude::*;
use strider_core::keys::{self, Key, MAX_KEYS};

#[derive(Context, Clone, Debug, Default)]
pub struct KeyCtx {
    /// The keys of a sequence typed so far.
    pub pending: Vec<Key>,
    /// The count typed before them.
    pub count: Option<u32>,
    /// How long a pending sequence waits before its continuations show.
    pub delay: Duration,
    /// What the next key answers, while one is awaited.
    pub question: Option<Question>,
}

/// A question the next key answers instead of going to a binding.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Question {
    /// The key to bookmark this folder under.
    BookmarkSet,
    /// The bookmark to go to; the bookmarks show after the delay.
    BookmarkJump,
    /// The bookmark to remove; the bookmarks show after the delay.
    BookmarkRemove,
    /// y to empty the trash.
    EmptyTrash,
    /// How to settle an operation's conflict: replace, skip, keep both, merge, cancel.
    Conflict,
}

impl Question {
    /// Whether the bookmarks show while it waits, as continuations do.
    fn hints(self) -> bool {
        matches!(self, Question::BookmarkJump | Question::BookmarkRemove)
    }
}

#[derive(Event, Clone, Debug, PartialEq)]
pub enum KeyEv {
    /// A key, with what the keymap binds to [`sequence`] of the pending keys and it: the
    /// command of a binding of exactly those keys, and whether longer bindings start with them.
    Key {
        key: Key,
        exact: Option<String>,
        prefix: bool,
    },
    /// Forget the pending keys and the count, as when the mode changes.
    Reset,
    /// Take the next key as the answer to a question.
    Ask(Question),
    /// `which_key_delay` changed.
    SetDelay(Duration),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeyFx {
    /// Run a binding's command with the count typed before it.
    Run {
        cmd: String,
        count: Option<u32>,
    },
    /// These keys mean nothing together: say so, so a key that does nothing is not silent.
    Unbound(Vec<Key>),
    /// The key is not the keymap's: leave it to the focused widget, as Tab moving focus.
    Pass,
    /// Show the pending keys' continuations, or show them again for more keys.
    ShowHints,
    HideHints,
    /// The pending keys or the count changed: draw the status line again.
    Status,
    /// The key that answers a question (Escape among them, which declines).
    Answer(Question, Key),
}

/// The keys to look up for `key` after `pending`: a sequence at its longest starts over.
pub fn sequence(pending: &[Key], key: Key) -> Vec<Key> {
    let mut seq = if pending.len() >= MAX_KEYS {
        Vec::new()
    } else {
        pending.to_vec()
    };
    seq.push(key);
    seq
}

fn is_escape(key: Key) -> bool {
    key.code == keys::sym::ESCAPE && !key.mods.ctrl
}

/// A key with nothing pending: a digit of the count, a binding, the start of a sequence, or
/// nothing.
fn idle_key(
    a: &Args<'_, Keymap>,
    enq: &mut Enq<'_, Keymap>,
    key: Key,
    exact: &Option<String>,
    prefix: bool,
) -> Transition<Keymap> {
    let count = a.context.count;
    enq.action(KeyFx::Status);
    if key.is_char() && (u32::from('1')..=u32::from('9')).contains(&key.code)
        || key.code == u32::from('0') && count.is_some()
    {
        let digit = key.code - u32::from('0');
        let n = count.unwrap_or(0).saturating_mul(10).saturating_add(digit);
        return Transition::<Keymap>::stay().patch(move |p| p.count(Some(n)));
    }
    match exact {
        Some(cmd) if !prefix => {
            enq.action(KeyFx::Run {
                cmd: cmd.clone(),
                count,
            });
            Transition::<Keymap>::stay().patch(|p| p.count(None))
        }
        _ if prefix => {
            let target = if a.context.delay.is_zero() {
                keymap::states::pending::HINTING
            } else {
                keymap::states::pending::WAITING
            };
            Transition::<Keymap>::to(target).patch(move |p| p.pending(vec![key]))
        }
        _ => {
            if key.is_char() {
                enq.action(KeyFx::Unbound(vec![key]));
            }
            if key.code == keys::sym::TAB && key.mods == keys::Mods::default() {
                enq.action(KeyFx::Pass);
            }
            Transition::<Keymap>::stay().patch(|p| p.count(None))
        }
    }
}

/// A key after others: Escape drops them; otherwise it runs a binding, goes on with a longer
/// sequence, or ends one that means nothing.
fn pending_key(
    a: &Args<'_, Keymap>,
    enq: &mut Enq<'_, Keymap>,
    key: Key,
    exact: &Option<String>,
    prefix: bool,
) -> Transition<Keymap> {
    enq.action(KeyFx::Status);
    let idle = || {
        Transition::<Keymap>::to(keymap::states::IDLE).patch(|p| p.pending(Vec::new()).count(None))
    };
    if is_escape(key) {
        return idle();
    }
    let seq = sequence(&a.context.pending, key);
    match exact {
        Some(cmd) if !prefix => {
            enq.action(KeyFx::Run {
                cmd: cmd.clone(),
                count: a.context.count,
            });
            idle()
        }
        _ if prefix => {
            if a.matches(keymap::states::pending::HINTING) {
                enq.action(KeyFx::ShowHints);
                Transition::<Keymap>::stay().patch(move |p| p.pending(seq))
            } else {
                Transition::<Keymap>::to(keymap::states::pending::WAITING)
                    .reenter(true)
                    .patch(move |p| p.pending(seq))
            }
        }
        _ => {
            enq.action(KeyFx::Unbound(seq));
            idle()
        }
    }
}

/// Waits for the key that answers `q`, showing the bookmarks after the delay for the
/// questions that list them.
fn ask(q: Question) -> Transition<Keymap> {
    let target = if q.hints() {
        keymap::states::asking::WAITING
    } else {
        keymap::states::asking::QUIET
    };
    Transition::<Keymap>::to(target)
        .reenter(true)
        .patch(move |p| p.question(Some(q)).pending(Vec::new()).count(None))
}

plusthree::machine! {
    pub Keymap { context: KeyCtx, events: KeyEv, effects: KeyFx }
    id: "keymap",
    delays: {
        which_key: |a| a.context.delay,
    },
    initial: idle,
    on: {
        KeyEv::SetDelay(delay) => |_, _| {
            let delay = *delay;
            Transition::stay().patch(move |p| p.delay(delay))
        },
    },
    states: {
        idle: {
            on: {
                KeyEv::Key { key, exact, prefix } => |a, enq| self::idle_key(a, enq, *key, exact, *prefix),
                KeyEv::Reset => |_, enq| {
                    enq.action(KeyFx::Status);
                    Transition::stay().patch(|p| p.count(None))
                },
                KeyEv::Ask(q) => |_, _| self::ask(*q),
            },
        },
        asking: {
            exit: |_, enq| { enq.action(KeyFx::HideHints); enq.action(KeyFx::Status) },
            on: {
                KeyEv::Key { key, .. } => |a, enq| {
                    if let Some(q) = a.context.question {
                        enq.action(KeyFx::Answer(q, *key));
                    }
                    Transition::to(keymap::states::IDLE).patch(|p| p.question(None))
                },
                KeyEv::Reset => |_, _| Transition::to(keymap::states::IDLE).patch(|p| p.question(None)),
                KeyEv::Ask(q) => |_, _| self::ask(*q),
            },
            initial: waiting,
            states: {
                waiting: {
                    entry: |_, enq| enq.action(KeyFx::Status),
                    after: { which_key => hinting },
                },
                hinting: {
                    entry: |_, enq| enq.action(KeyFx::ShowHints),
                },
                quiet: {
                    entry: |_, enq| enq.action(KeyFx::Status),
                },
            },
        },
        pending: {
            exit: |_, enq| { enq.action(KeyFx::HideHints); enq.action(KeyFx::Status) },
            on: {
                KeyEv::Key { key, exact, prefix } => |a, enq| self::pending_key(a, enq, *key, exact, *prefix),
                KeyEv::Reset => |_, _| Transition::to(keymap::states::IDLE).patch(|p| p.pending(Vec::new()).count(None)),
            },
            initial: waiting,
            states: {
                waiting: {
                    after: { which_key => hinting },
                },
                hinting: {
                    entry: |_, enq| enq.action(KeyFx::ShowHints),
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

    fn ch(c: char) -> Key {
        Key::char(u32::from(c))
    }

    fn key(k: Key, exact: Option<&str>, prefix: bool) -> KeyEv {
        KeyEv::Key {
            key: k,
            exact: exact.map(str::to_owned),
            prefix,
        }
    }

    fn start(delay: u64) -> (Driver<Keymap, u32>, Recorder) {
        let mut d = Driver::new(Keymap::machine(), ());
        let mut r = Recorder::new();
        d.send(KeyEv::SetDelay(Duration::from_millis(delay)), &mut r);
        (d, r)
    }

    fn runs(fx: &[KeyFx]) -> Vec<(String, Option<u32>)> {
        fx.iter()
            .filter_map(|f| match f {
                KeyFx::Run { cmd, count } => Some((cmd.clone(), *count)),
                _ => None,
            })
            .collect()
    }

    // 3dd runs "cut" with 3 and forgets the count; "0" alone is a key, not a count, but "10"
    // is ten.
    #[test]
    fn counts_reach_the_command_that_ends_the_sequence() {
        let (mut d, mut r) = start(300);
        d.send(key(ch('3'), None, false), &mut r);
        d.send(key(ch('d'), None, true), &mut r);
        assert_eq!(d.context().pending, [ch('d')]);
        let fx = d.send(key(ch('d'), Some("cut"), false), &mut r);
        assert_eq!(runs(&fx), [("cut".into(), Some(3))]);
        assert!(fx.contains(&KeyFx::HideHints));
        assert_eq!((d.context().pending.len(), d.context().count), (0, None));

        let fx = d.send(key(ch('0'), Some("first"), false), &mut r);
        assert_eq!(runs(&fx), [("first".into(), None)]);
        d.send(key(ch('1'), None, false), &mut r);
        d.send(key(ch('0'), None, false), &mut r);
        let fx = d.send(key(ch('j'), Some("down"), false), &mut r);
        assert_eq!(runs(&fx), [("down".into(), Some(10))]);
    }

    // The hints wait for the delay, which another key of the sequence starts again; once
    // they show, more keys redraw them without waiting.
    #[test]
    fn hints_show_after_the_delay_restarted_by_each_key() {
        let (mut d, mut r) = start(300);
        d.send(key(ch('g'), None, true), &mut r);
        let running = |r: &Recorder| r.running().map(|t| (t.token, t.delay)).collect::<Vec<_>>();
        let [(first, delay)] = running(&r)[..] else {
            panic!("one timer")
        };
        assert_eq!(delay, Duration::from_millis(300));
        d.send(key(ch('x'), None, true), &mut r);
        let [(second, _)] = running(&r)[..] else {
            panic!("one timer")
        };
        assert_ne!(first, second, "the timer starts again");
        // The first timer's callback, already queued, does nothing.
        assert!(d.fire(first, &mut r).is_empty());
        r.fired(second);
        assert_eq!(d.fire(second, &mut r), [KeyFx::ShowHints]);
        let fx = d.send(key(ch('y'), None, true), &mut r);
        assert!(fx.contains(&KeyFx::ShowHints));
        assert!(running(&r).is_empty());
    }

    #[test]
    fn no_delay_shows_hints_at_once_and_escape_drops_the_keys() {
        let (mut d, mut r) = start(0);
        let fx = d.send(key(ch('g'), None, true), &mut r);
        assert!(fx.contains(&KeyFx::ShowHints));
        let esc = Key {
            code: keys::sym::ESCAPE,
            mods: keys::Mods::default(),
        };
        // Escape ends the sequence whatever the keymap says of it.
        let fx = d.send(key(esc, Some("escape"), false), &mut r);
        assert!(runs(&fx).is_empty());
        assert!(fx.contains(&KeyFx::HideHints));
        assert!(d.matches(keymap::states::IDLE));
    }

    // A question takes the next key whatever it is bound to, Escape too; the bookmarks show
    // after the delay only for the questions that pick one.
    #[test]
    fn questions_take_the_next_key() {
        let (mut d, mut r) = start(300);
        d.send(KeyEv::Ask(Question::BookmarkSet), &mut r);
        assert_eq!(r.running().count(), 0, "no hints for setting one");
        let fx = d.send(key(ch('j'), Some("down"), false), &mut r);
        assert!(fx.contains(&KeyFx::Answer(Question::BookmarkSet, ch('j'))));
        assert!(runs(&fx).is_empty());
        assert!(d.matches(keymap::states::IDLE));
        assert_eq!(d.context().question, None);

        d.send(KeyEv::Ask(Question::BookmarkJump), &mut r);
        let [t] = r.running().map(|t| t.token).collect::<Vec<_>>()[..] else {
            panic!("one timer")
        };
        r.fired(t);
        assert_eq!(d.fire(t, &mut r), [KeyFx::ShowHints]);
        let esc = Key {
            code: keys::sym::ESCAPE,
            mods: keys::Mods::default(),
        };
        let fx = d.send(key(esc, Some("escape"), false), &mut r);
        assert!(fx.contains(&KeyFx::Answer(Question::BookmarkJump, esc)));
        assert!(fx.contains(&KeyFx::HideHints));
    }

    // A sequence that ends in nothing is reported whole; a lone unbound arrow is not, and
    // only a plain Tab goes on to the widgets.
    #[test]
    fn unbound_keys() {
        let (mut d, mut r) = start(300);
        d.send(key(ch('g'), None, true), &mut r);
        let fx = d.send(key(ch('!'), None, false), &mut r);
        assert!(fx.contains(&KeyFx::Unbound(vec![ch('g'), ch('!')])));
        let up = Key {
            code: keys::sym::UP,
            mods: keys::Mods::default(),
        };
        let fx = d.send(key(up, None, false), &mut r);
        assert!(
            !fx.iter()
                .any(|f| matches!(f, KeyFx::Unbound(_) | KeyFx::Pass))
        );
        let tab = Key {
            code: keys::sym::TAB,
            mods: keys::Mods::default(),
        };
        assert!(d.send(key(tab, None, false), &mut r).contains(&KeyFx::Pass));
    }
}
