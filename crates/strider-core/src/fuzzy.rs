//! Fuzzy finding: the paths below a folder, walked on a worker, and a score for a path
//! against a query in the spirit of fzf: every character of each space-separated word in
//! order, in the tightest window that holds them, with bonuses for matches at word starts,
//! after slashes, in runs, and in the base name, and a cost for gaps. Smart case, as the rest
//! of the program: a capital letter makes the query exact.
//!
//! Paths and queries are bytes, as Linux names are, and positions are byte offsets.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// Paths in one buffer, so a walk of many thousands costs two allocations, not one each.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Paths {
    bytes: Vec<u8>,
    /// Where each path ends in `bytes`; path i starts where path i - 1 ends.
    ends: Vec<usize>,
}

impl Paths {
    pub fn len(&self) -> usize {
        self.ends.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    /// Path `i`. Panics past the end.
    pub fn get(&self, i: usize) -> &[u8] {
        let start = if i == 0 { 0 } else { self.ends[i - 1] };
        &self.bytes[start..self.ends[i]]
    }

    pub fn push(&mut self, path: &[u8]) {
        self.bytes.extend_from_slice(path);
        self.ends.push(self.bytes.len());
    }

    /// Moves every path of `other` to the end, leaving `other` empty.
    pub fn append(&mut self, other: &mut Paths) {
        let base = self.bytes.len();
        self.bytes.append(&mut other.bytes);
        self.ends.extend(other.ends.drain(..).map(|e| base + e));
    }
}

// Scoring ---------------------------------------------------------------------------------

const SCORE_MATCH: i32 = 16;
const BONUS_BOUNDARY: i32 = 8;
const BONUS_SLASH: i32 = 10;
const BONUS_CAMEL: i32 = 7;
const BONUS_RUN: i32 = 6;
const BONUS_BASE: i32 = 12;
const PENALTY_GAP_START: i32 = 3;
const PENALTY_GAP: i32 = 1;

/// The most positions [`score`] reports.
pub const MAX_POSITIONS: usize = 64;

fn eq(a: u8, b: u8, exact: bool) -> bool {
    if exact {
        a == b
    } else {
        a.eq_ignore_ascii_case(&b)
    }
}

fn boundary_bonus(text: &[u8], i: usize) -> i32 {
    if i == 0 {
        return BONUS_SLASH;
    }
    let prev = text[i - 1];
    let ch = text[i];
    if prev == b'/' {
        BONUS_SLASH
    } else if matches!(prev, b'_' | b'-' | b'.' | b' ') {
        BONUS_BOUNDARY
    } else if prev.is_ascii_lowercase() && ch.is_ascii_uppercase() {
        BONUS_CAMEL
    } else if !prev.is_ascii_alphanumeric() && ch.is_ascii_alphanumeric() {
        BONUS_BOUNDARY
    } else {
        0
    }
}

/// One word against `text`: None if its characters are not all there in order. Positions go
/// to `pos`, as many as fit under [`MAX_POSITIONS`].
fn score_word(
    text: &[u8],
    word: &[u8],
    exact: bool,
    mut pos: Option<&mut Vec<usize>>,
) -> Option<i32> {
    if word.is_empty() {
        return Some(0);
    }
    // The first place the whole word fits, scanning forward...
    let mut j = 0;
    let mut end = None;
    for (i, &ch) in text.iter().enumerate() {
        if eq(ch, word[j], exact) {
            j += 1;
            if j == word.len() {
                end = Some(i);
                break;
            }
        }
    }
    let end = end?;
    // ...then back from its end, for the tightest window.
    let mut start = end;
    let mut k = word.len();
    for i in (0..=end).rev() {
        if eq(text[i], word[k - 1], exact) {
            k -= 1;
            if k == 0 {
                start = i;
                break;
            }
        }
    }
    // A folder's name is its base name, though it ends in a slash.
    let without_slash = text.strip_suffix(b"/").unwrap_or(text);
    let base_at = without_slash
        .iter()
        .rposition(|&c| c == b'/')
        .map_or(0, |s| s + 1);
    let mut total = 0;
    let mut prev: Option<usize> = None;
    let mut w = 0;
    for t in start..=end {
        if w == word.len() {
            break;
        }
        if !eq(text[t], word[w], exact) {
            continue;
        }
        total += SCORE_MATCH + boundary_bonus(text, t);
        if let Some(p) = prev {
            if p + 1 == t {
                total += BONUS_RUN;
            } else {
                // At most 20, so the cast cannot truncate.
                total -= PENALTY_GAP_START + PENALTY_GAP * (t - p - 2).min(20) as i32;
            }
        }
        if let Some(pos) = pos.as_deref_mut()
            && pos.len() < MAX_POSITIONS
        {
            pos.push(t);
        }
        prev = Some(t);
        w += 1;
    }
    if start >= base_at {
        total += BONUS_BASE;
    }
    Some(total)
}

/// `query`'s score for `text`, higher is better, or None if a word does not match. With
/// `pos`, the matched byte offsets of `text` (for highlighting) are added to it.
pub fn score(text: &[u8], query: &[u8], mut pos: Option<&mut Vec<usize>>) -> Option<i32> {
    let exact = query.iter().any(u8::is_ascii_uppercase);
    let mut total = 0;
    for word in query.split(|&c| c == b' ').filter(|w| !w.is_empty()) {
        total += score_word(text, word, exact, pos.as_deref_mut())?;
    }
    Some(total)
}

/// A path that matched: its index in [`Paths`] and its [`score`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match {
    pub index: usize,
    pub score: i32,
}

/// Scores `candidates` (all of `paths`, or a previous result to narrow) against `query` into
/// `out`, best first; shorter paths win ties, then earlier ones (the walk is breadth first,
/// so shallower ones). An empty query keeps every candidate in its order.
pub fn filter(paths: &Paths, candidates: Option<&[Match]>, query: &[u8], out: &mut Vec<Match>) {
    out.clear();
    let mut consider = |index: usize| {
        if let Some(score) = score(paths.get(index), query, None) {
            out.push(Match { index, score });
        }
    };
    match candidates {
        Some(cs) => cs.iter().for_each(|m| consider(m.index)),
        None => (0..paths.len()).for_each(consider),
    }
    if query.is_empty() {
        return;
    }
    out.sort_unstable_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then_with(|| paths.get(a.index).len().cmp(&paths.get(b.index).len()))
            .then_with(|| a.index.cmp(&b.index))
    });
}

// Walking ---------------------------------------------------------------------------------

/// A breadth-first walk of `root`, meant for a worker thread: see [`Walk::run`].
#[derive(Clone, Copy, Debug)]
pub struct Walk<'a> {
    pub root: &'a Path,
    /// Hidden entries too (`.git` never).
    pub hidden: bool,
    /// Stops after this many paths.
    pub limit: usize,
    /// Stops when set, from another thread.
    pub cancel: &'a AtomicBool,
    /// Paths per batch handed to the sink.
    pub batch_size: usize,
}

impl Walk<'_> {
    /// Walks `root` breadth first, handing paths (relative to the root; folders end in "/")
    /// to `sink` in batches of `batch_size`, with `true` on the last, which may be empty and
    /// always comes, even after a cancel. Skips `.git`, and hidden entries unless `hidden`;
    /// does not follow links into folders; skips folders it cannot read.
    pub fn run(&self, mut sink: impl FnMut(Paths, bool)) {
        let mut queue: Vec<Vec<u8>> = vec![Vec::new()];
        let mut head = 0;
        let mut count = 0;
        let mut batch = Paths::default();
        'outer: while head < queue.len() {
            let rel = std::mem::take(&mut queue[head]);
            head += 1;
            let Ok(entries) = std::fs::read_dir(self.root.join(OsStr::from_bytes(&rel))) else {
                continue;
            };
            for entry in entries {
                if self.cancel.load(Ordering::Acquire) {
                    break 'outer;
                }
                let Ok(entry) = entry else { break };
                let name = entry.file_name();
                let name = name.as_bytes();
                if name == b".git" || (!self.hidden && name.starts_with(b".")) {
                    continue;
                }
                // The entry's own type: a link to a folder is not one.
                let dir = entry.file_type().is_ok_and(|t| t.is_dir());
                let mut child = rel.clone();
                child.extend_from_slice(name);
                if dir {
                    child.push(b'/');
                }
                batch.push(&child);
                if dir {
                    queue.push(child);
                }
                count += 1;
                if count >= self.limit {
                    break 'outer;
                }
                if batch.len() >= self.batch_size {
                    sink(std::mem::take(&mut batch), false);
                }
            }
        }
        sink(batch, true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(list: &[&str]) -> Paths {
        let mut p = Paths::default();
        list.iter().for_each(|s| p.push(s.as_bytes()));
        p
    }

    #[test]
    fn every_words_characters_in_order_in_smart_case() {
        let s = |t: &str, q: &str| score(t.as_bytes(), q.as_bytes(), None);
        assert!(s("src/main.zig", "mz").is_some());
        assert!(s("src/main.zig", "zm").is_none());
        assert!(s("src/main.zig", "main src").is_some());
        assert!(s("src/main.zig", "main docs").is_none());
        assert!(s("README.md", "readme").is_some());
        assert!(s("README.md", "Readme").is_none());
        assert_eq!(s("anything", ""), Some(0));
    }

    // Each pair names a rule of the ranking; losing a bonus or a cost flips one.
    #[test]
    fn word_starts_runs_and_the_base_name_rank_first() {
        let better = |a: &str, b: &str, q: &str| {
            let sa = score(a.as_bytes(), q.as_bytes(), None).unwrap();
            let sb = score(b.as_bytes(), q.as_bytes(), None).unwrap();
            assert!(sa > sb, "{a} ({sa}) should beat {b} ({sb}) for {q}");
        };
        // A run beats scattered letters.
        better("src/main.zig", "src/my_animal_index.zig", "main");
        // The base name beats a folder on the way.
        better("docs/notes/main.txt", "main/docs/notes.txt", "main");
        // A word start beats the middle of a word.
        better("src/file_view.zig", "src/fileview.zig", "fv");
        // camelCase starts count.
        better("src/FileView.zig", "src/fileview.zig", "fv");
        // Tight beats spread out.
        better("a/build.zig", "b/u/i/l/d.zig", "build");
    }

    // Exact scores, worked by hand, so the constants and the gap cost match the Zig build's
    // ranking, and a folder's trailing slash does not cost it the base-name bonus.
    #[test]
    fn scores_and_positions() {
        let mut pos = Vec::new();
        // m after '/': 16 + 10; z after '.': 16 + 8; a gap of 3 skipped: -(3 + 3);
        // the window starts in the base name: +12.
        assert_eq!(score(b"src/main.zig", b"mz", Some(&mut pos)), Some(56));
        assert_eq!(pos, [4, 9]);
        // d after '/': 16 + 10, in the base name "docs": +12.
        assert_eq!(score(b"src/docs/", b"d", None), Some(38));
    }

    #[test]
    fn filter_ranks_breaks_ties_and_narrows_a_previous_result() {
        let p = paths(&[
            "docs/",
            "src/",
            "src/util/",
            "src/main.zig",
            "src/util/strings.zig",
            "docs/manual.md",
            "README.md",
        ]);
        let mut out = Vec::new();
        filter(&p, None, b"", &mut out);
        assert_eq!(out.len(), 7);
        filter(&p, None, b"ma", &mut out);
        assert_eq!(p.get(out[0].index), b"src/main.zig");
        assert_eq!(p.get(out[1].index), b"docs/manual.md");
        let prev = out.clone();
        filter(&p, Some(&prev), b"man", &mut out);
        assert_eq!(out.len(), 2);
        // Now the run of three wins.
        assert_eq!(p.get(out[0].index), b"docs/manual.md");
        let prev = out.clone();
        filter(&p, Some(&prev), b"manu", &mut out);
        assert_eq!(out.len(), 1);

        // Equal scores (38 each): the shorter first, then the earlier.
        let p = paths(&["src/x.zig", "src/x.zi", "src/x.zag"]);
        filter(&p, None, b"x", &mut out);
        let order: Vec<usize> = out.iter().map(|m| m.index).collect();
        assert_eq!(order, [1, 0, 2]);
    }

    #[test]
    fn walks_breadth_first_skipping_git_hidden_and_links_in_batches() {
        use std::fs;
        let root = std::env::temp_dir().join(format!("strider-fuzzy-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for d in ["a/b", ".git/objects", ".hidden"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        for f in [
            "top",
            "a/mid",
            "a/b/deep",
            ".git/HEAD",
            ".hidden/x",
            ".dotfile",
        ] {
            fs::write(root.join(f), "").unwrap();
        }
        // A link to a folder is listed as itself and not walked into.
        std::os::unix::fs::symlink("a", root.join("ln")).unwrap();
        let cancel = AtomicBool::new(false);
        for hidden in [false, true] {
            let mut all = Paths::default();
            let mut batches = 0;
            let mut done = false;
            let walk = Walk {
                root: &root,
                hidden,
                limit: 200_000,
                cancel: &cancel,
                batch_size: 2,
            };
            walk.run(|mut batch, last| {
                assert!(!done, "a batch after the last");
                all.append(&mut batch);
                batches += 1;
                done = last;
            });
            assert!(done);
            assert!(batches >= 3);
            let mut names: Vec<&str> = (0..all.len())
                .map(|i| std::str::from_utf8(all.get(i)).unwrap())
                .collect();
            // Breadth first: every depth before the next; within a folder, the directory's
            // order, so sort each depth to compare.
            let depth = |s: &str| s.trim_end_matches('/').matches('/').count();
            let depths: Vec<usize> = names.iter().map(|s| depth(s)).collect();
            assert!(depths.is_sorted(), "not breadth first: {names:?}");
            names.sort_by_key(|s| (depth(s), *s));
            let want: &[&str] = if hidden {
                &[
                    ".dotfile",
                    ".hidden/",
                    "a/",
                    "ln",
                    "top",
                    ".hidden/x",
                    "a/b/",
                    "a/mid",
                    "a/b/deep",
                ]
            } else {
                &["a/", "ln", "top", "a/b/", "a/mid", "a/b/deep"]
            };
            assert_eq!(names, want);
        }
        fs::remove_dir_all(&root).unwrap();
    }
}
