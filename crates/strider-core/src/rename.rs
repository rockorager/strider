//! Batch rename: new names from find-and-replace or a template, and the checks that keep a
//! batch from colliding with itself or other files.

use std::collections::HashSet;
use std::fs;
use std::path::Path;

use crate::model;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Replace,
    Template,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Spec {
    pub mode: Mode,
    pub find: String,
    pub replace: String,
    /// `[N]` the name without its extension, `[E]` the extension, `[#]` the item's number
    /// from 1 (`[###]` pads it to three digits). Without `[E]`, the extension stays.
    pub template: String,
}

/// The new name of the item at `index`.
pub fn new_name(spec: &Spec, name: &[u8], index: usize) -> Vec<u8> {
    match spec.mode {
        Mode::Replace => replace(name, spec.find.as_bytes(), spec.replace.as_bytes()),
        Mode::Template => {
            let (stem, ext) = name.split_at(stem_length(name)); // ext with its dot
            let t = spec.template.as_bytes();
            let mut out = Vec::with_capacity(t.len() + name.len());
            let mut used_ext = false;
            let mut i = 0;
            while i < t.len() {
                if t[i..].starts_with(b"[N]") {
                    out.extend_from_slice(stem);
                    i += 3;
                } else if t[i..].starts_with(b"[E]") {
                    out.extend_from_slice(ext.get(1..).unwrap_or_default());
                    used_ext = true;
                    i += 3;
                } else if t[i..].starts_with(b"[#") {
                    let j = i + 1 + t[i + 1..].iter().take_while(|&&c| c == b'#').count();
                    if t.get(j) == Some(&b']') {
                        let width = j - i - 1;
                        out.extend_from_slice(format!("{:0width$}", index + 1).as_bytes());
                        i = j + 1;
                    } else {
                        out.push(t[i]);
                        i += 1;
                    }
                } else {
                    out.push(t[i]);
                    i += 1;
                }
            }
            if !used_ext {
                out.extend_from_slice(ext);
            }
            out
        }
    }
}

/// `name` with every occurrence of `find`, left to right and not overlapping, replaced.
fn replace(name: &[u8], find: &[u8], with: &[u8]) -> Vec<u8> {
    if find.is_empty() {
        return name.to_vec();
    }
    let mut out = Vec::with_capacity(name.len());
    let mut i = 0;
    while i < name.len() {
        if name[i..].starts_with(find) {
            out.extend_from_slice(with);
            i += find.len();
        } else {
            out.push(name[i]);
            i += 1;
        }
    }
    out
}

/// The length of the name without its extension: the last dot's, and ".tar.gz"'s whole.
fn stem_length(name: &[u8]) -> usize {
    match name.iter().rposition(|&c| c == b'.') {
        None | Some(0) => name.len(),
        Some(dot) if name[..dot].ends_with(b".tar") => dot - 4,
        Some(dot) => dot,
    }
}

/// Why the batch cannot be applied, or `None`: an invalid name, two items getting the same
/// name, or a name another file in the folder has. `new_names[i]` is `paths[i]`'s.
pub fn check<P: AsRef<Path>, N: AsRef<[u8]>>(paths: &[P], new_names: &[N]) -> Option<&'static str> {
    assert_eq!(paths.len(), new_names.len(), "a new name for each path");
    let olds: HashSet<&[u8]> = paths.iter().map(|p| model::basename(p.as_ref())).collect();
    let mut seen: HashSet<&[u8]> = HashSet::new();
    for (p, n) in paths.iter().zip(new_names) {
        let (p, n) = (p.as_ref(), n.as_ref());
        if !model::valid_name(n) {
            return Some("A new name is empty or has a “/”");
        }
        if !seen.insert(n) {
            return Some("Two items would get the same name");
        }
        // Its own name, or another item's, which moves out of the way.
        if n == model::basename(p) || olds.contains(n) {
            continue;
        }
        // Another file (not in the batch) has the name already.
        let target = model::join(model::parent(p), n);
        if fs::symlink_metadata(target).is_ok() {
            return Some("A new name is taken by another file");
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn template(t: &str) -> Spec {
        Spec {
            mode: Mode::Template,
            find: String::new(),
            replace: String::new(),
            template: t.into(),
        }
    }

    #[test]
    fn templates_and_replacing() {
        assert_eq!(
            new_name(&template("Trip [###]"), b"IMG_0042.JPG", 6),
            b"Trip 007.JPG"
        );
        assert_eq!(
            new_name(&template("[N]-[#].[E]"), b"notes.tar.gz", 0),
            b"notes-1.tar.gz"
        );
        // Too few #s to pad, an unclosed [#, and a dotfile has no extension.
        assert_eq!(new_name(&template("[#]_[##"), b".bashrc", 11), b"12_[##");
        let r = Spec {
            mode: Mode::Replace,
            find: "_".into(),
            replace: " ".into(),
            template: String::new(),
        };
        assert_eq!(new_name(&r, b"a_b_c.txt", 0), b"a b c.txt");
        let aa = Spec {
            find: "aa".into(),
            replace: "a".into(),
            ..r
        };
        assert_eq!(new_name(&aa, b"aaa", 0), b"aa");
    }

    #[test]
    fn batch_checks() {
        let missing = ["/nonexistent/a", "/nonexistent/b"];
        assert_eq!(
            check(&missing, &["x", "x"]),
            Some("Two items would get the same name")
        );
        assert_eq!(check(&missing, &["b", "a"]), None);
        assert!(check(&missing[..1], &["a/b"]).is_some());

        let dir = std::env::temp_dir().join(format!("strider-rename-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        for name in ["a", "b", "c"] {
            fs::write(dir.join(name), b"").unwrap();
        }
        let ab = [dir.join("a"), dir.join("b")];
        assert_eq!(
            check(&ab, &["c", "b"]),
            Some("A new name is taken by another file")
        );
        assert_eq!(check(&ab, &["b", "d"]), None);
        fs::remove_dir_all(&dir).unwrap();
    }
}
