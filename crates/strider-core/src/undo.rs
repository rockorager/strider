//! What can be undone: created folders and files, renames (one, or a batch as one step), and
//! copies, moves, trashes, and restores, as the (from, to) pairs their operations recorded.
//! Deleting permanently cannot be undone and is not recorded, nor are chmod and chown.
//!
//! Undoing never loses data: a copy is undone by moving the copies to the trash, not by
//! deleting them, and a restore by trashing what came back.

use std::path::PathBuf;

use crate::fsops::{self, Done};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Created,
    Renamed,
    Copied,
    Moved,
    Trashed,
    Restored,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pair {
    pub from: PathBuf,
    pub to: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Step {
    pub kind: Kind,
    pub pairs: Vec<Pair>,
}

/// How to reverse a step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reversal {
    /// Remove the folder or file that was created (refusing a folder that is no longer
    /// empty).
    Remove(PathBuf),
    /// Rename each `to` back to its `from`, newest first.
    RenameBack(Vec<Pair>),
    /// Run an operation, not itself recorded for undo: `kind` on `sources`, each going to its
    /// target for `MoveBack` and `Restore`.
    Run {
        kind: fsops::Kind,
        sources: Vec<PathBuf>,
        targets: Vec<PathBuf>,
    },
}

impl Step {
    /// "Undo Move to Trash", for menus.
    pub fn label(&self) -> &'static str {
        match self.kind {
            Kind::Created => "Undo New Folder",
            Kind::Renamed => "Undo Rename",
            Kind::Copied => "Undo Copy",
            Kind::Moved => "Undo Move",
            Kind::Trashed => "Undo Move to Trash",
            Kind::Restored => "Undo Restore",
        }
    }

    pub fn reversal(&self) -> Reversal {
        let tos = || self.pairs.iter().map(|p| p.to.clone()).collect();
        let froms = || self.pairs.iter().map(|p| p.from.clone()).collect();
        let run = |kind, targets| Reversal::Run {
            kind,
            sources: tos(),
            targets,
        };
        match self.kind {
            Kind::Created => Reversal::Remove(self.pairs[0].from.clone()),
            Kind::Renamed => Reversal::RenameBack(self.pairs.iter().rev().cloned().collect()),
            Kind::Copied | Kind::Restored => run(fsops::Kind::Trash, Vec::new()),
            Kind::Moved => run(fsops::Kind::MoveBack, froms()),
            Kind::Trashed => run(fsops::Kind::Restore, froms()),
        }
    }
}

/// The newest steps, at most [`Stack::MAX_STEPS`].
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stack {
    steps: Vec<Step>,
}

impl Stack {
    pub const MAX_STEPS: usize = 50;

    pub fn new() -> Stack {
        Stack::default()
    }

    pub fn top(&self) -> Option<&Step> {
        self.steps.last()
    }

    /// Takes the newest step, to reverse it.
    pub fn pop(&mut self) -> Option<Step> {
        self.steps.pop()
    }

    pub fn len(&self) -> usize {
        self.steps.len()
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }

    fn push(&mut self, kind: Kind, pairs: Vec<Pair>) {
        if self.steps.len() >= Self::MAX_STEPS {
            self.steps.remove(0);
        }
        self.steps.push(Step { kind, pairs });
    }

    pub fn push_created(&mut self, path: PathBuf) {
        self.push(
            Kind::Created,
            vec![Pair {
                from: path.clone(),
                to: path,
            }],
        );
    }

    /// A batch of renames, as one step; none is no step.
    pub fn push_renames(&mut self, pairs: Vec<Pair>) {
        if !pairs.is_empty() {
            self.push(Kind::Renamed, pairs);
        }
    }

    /// Records what a finished operation did. Copies that replaced a file are left out, since
    /// undo cannot bring the file back; deletes, chmod, chown, and undo's own moves back are
    /// not recorded. The host records only what it starts as undoable, and nothing of a
    /// cancelled operation.
    pub fn push_op(&mut self, kind: fsops::Kind, done: &[Done]) {
        let kind = match kind {
            fsops::Kind::Copy | fsops::Kind::Link => Kind::Copied,
            fsops::Kind::Move => Kind::Moved,
            fsops::Kind::Trash => Kind::Trashed,
            fsops::Kind::Restore => Kind::Restored,
            fsops::Kind::Delete
            | fsops::Kind::MoveBack
            | fsops::Kind::Chmod
            | fsops::Kind::Chown => {
                return;
            }
        };
        let pairs: Vec<Pair> = done
            .iter()
            .filter(|d| !(kind == Kind::Copied && d.replaced))
            .map(|d| Pair {
                from: d.from.clone(),
                to: d.to.clone(),
            })
            .collect();
        if !pairs.is_empty() {
            self.push(kind, pairs);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn done(from: &str, to: &str, replaced: bool) -> Done {
        Done {
            from: from.into(),
            to: to.into(),
            replaced,
        }
    }

    fn paths(v: &[&str]) -> Vec<PathBuf> {
        v.iter().map(PathBuf::from).collect()
    }

    // Each kind of step reverses as undo.zig's caller did: copies and restores go to the
    // trash, moves go back to where they were, trashes are restored there.
    #[test]
    fn steps_reverse() {
        let mut s = Stack::new();
        s.push_op(
            fsops::Kind::Copy,
            &[done("/a/x", "/b/x", false), done("/a/y", "/b/y", true)],
        );
        s.push_op(fsops::Kind::Move, &[done("/a/z", "/b/z", false)]);
        s.push_op(fsops::Kind::Trash, &[done("/a/w", "/T/files/w", false)]);
        s.push_op(fsops::Kind::Restore, &[done("/T/files/v", "/a/v", false)]);
        assert_eq!(s.top().unwrap().label(), "Undo Restore");
        let run = |kind, sources: &[&str], targets: &[&str]| Reversal::Run {
            kind,
            sources: paths(sources),
            targets: paths(targets),
        };
        assert_eq!(
            s.pop().unwrap().reversal(),
            run(fsops::Kind::Trash, &["/a/v"], &[])
        );
        assert_eq!(
            s.pop().unwrap().reversal(),
            run(fsops::Kind::Restore, &["/T/files/w"], &["/a/w"])
        );
        assert_eq!(
            s.pop().unwrap().reversal(),
            run(fsops::Kind::MoveBack, &["/b/z"], &["/a/z"])
        );
        // The copy that replaced a file is not undone: trashing it would lose the file it
        // replaced as well as the copy.
        assert_eq!(
            s.pop().unwrap().reversal(),
            run(fsops::Kind::Trash, &["/b/x"], &[])
        );
        assert!(s.pop().is_none());
    }

    // Renames go back newest first, so a chain a→b, b→c undoes to a; deletes and chmod are
    // not recorded, nor an operation that did nothing.
    #[test]
    fn renames_and_what_is_not_recorded() {
        let mut s = Stack::new();
        s.push_op(fsops::Kind::Delete, &[done("/a", "/a", false)]);
        s.push_op(fsops::Kind::Chmod, &[done("/a", "/a", false)]);
        s.push_op(fsops::Kind::MoveBack, &[done("/a", "/b", false)]);
        s.push_op(fsops::Kind::Copy, &[done("/a", "/b", true)]);
        s.push_renames(Vec::new());
        assert!(s.is_empty());
        let pair = |f: &str, t: &str| Pair {
            from: f.into(),
            to: t.into(),
        };
        s.push_renames(vec![pair("/d/a", "/d/b"), pair("/d/b", "/d/c")]);
        assert_eq!(
            s.pop().unwrap().reversal(),
            Reversal::RenameBack(vec![pair("/d/b", "/d/c"), pair("/d/a", "/d/b")])
        );
        s.push_created("/d/new".into());
        assert_eq!(
            s.pop().unwrap().reversal(),
            Reversal::Remove("/d/new".into())
        );
    }

    #[test]
    fn the_oldest_step_goes_past_the_limit() {
        let mut s = Stack::new();
        for i in 0..=Stack::MAX_STEPS {
            s.push_created(format!("/d/{i}").into());
        }
        assert_eq!(s.len(), Stack::MAX_STEPS);
        assert_eq!(s.steps[0].pairs[0].from, PathBuf::from("/d/1"));
    }
}
