//! `$XDG_CONFIG_HOME/strider/config.json`: options, keys, and bookmarks.
//!
//! ```json
//! {
//!   "options": { "hidden": false, "sort": "name", "ratio": [1, 3, 4] },
//!   "keys": {
//!     "n": { "gp": "cd ~/Projects", "gs": { "cmd": "cd ~/Pictures/Screenshots", "desc": "Screenshots" } },
//!     "v": { "<C-c>": "yank" }
//!   },
//!   "unmap": { "n": ["dD"] },
//!   "bookmarks": { "p": "~/Projects" }
//! }
//! ```
//!
//! A key runs a command line, the same as typed after `:`, and shows its description in the
//! key hints. A mistake costs only the entry it is in: [`parse`] keeps the rest and says what
//! it skipped.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::options::{Options, SetError};

/// The key tables a binding goes in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Normal,
    Visual,
    /// The tasks view.
    Tasks,
}

impl Mode {
    /// `n`, `v`, or `t`, as `:map` takes them.
    pub fn parse(t: &str) -> Option<Mode> {
        Some(match t {
            "n" => Mode::Normal,
            "v" => Mode::Visual,
            "t" => Mode::Tasks,
            _ => return None,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Binding {
    pub mode: Mode,
    /// The key sequence, in vim's notation (`gp`, `<C-c>`).
    pub keys: String,
    /// The command line it runs.
    pub cmd: String,
    pub desc: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Config {
    pub options: Options,
    /// Bindings added over the defaults, in the file's order.
    pub keys: Vec<Binding>,
    /// Default bindings removed.
    pub unmap: Vec<(Mode, String)>,
    pub bookmarks: Vec<(char, PathBuf)>,
}

/// Reads a config file's text. `home` expands a bookmark's leading `~`. The second value
/// names each entry skipped and why, for the window to show; malformed JSON skips everything.
pub fn parse(text: &str, home: &Path) -> (Config, Vec<String>) {
    let mut config = Config::default();
    let mut problems = Vec::new();
    let root = match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(root)) => root,
        Ok(_) => return (config, vec!["the config is not a JSON object".into()]),
        Err(e) => return (config, vec![format!("the config is not valid JSON: {e}")]),
    };
    for (section, value) in &root {
        let Some(map) = value.as_object() else {
            problems.push(format!("\"{section}\" is not an object"));
            continue;
        };
        match section.as_str() {
            "options" => options(&mut config, map, &mut problems),
            "keys" => keys(&mut config, map, &mut problems),
            "unmap" => unmap(&mut config, map, &mut problems),
            "bookmarks" => bookmarks(&mut config, map, home, &mut problems),
            _ => problems.push(format!("unknown section \"{section}\"")),
        }
    }
    (config, problems)
}

fn options(config: &mut Config, map: &Map<String, Value>, problems: &mut Vec<String>) {
    for (name, value) in map {
        match config.options.set_json(name, value) {
            Ok(()) => {}
            Err(SetError::UnknownOption) => problems.push(format!("unknown option \"{name}\"")),
            Err(SetError::InvalidValue) => {
                problems.push(format!("option \"{name}\" can't be {value}"))
            }
        }
    }
}

/// Each mode's table, or reports it as unknown.
fn modes<'a>(
    map: &'a Map<String, Value>,
    section: &str,
    problems: &mut Vec<String>,
) -> Vec<(Mode, &'a Value)> {
    let mut out = Vec::new();
    for (name, value) in map {
        match Mode::parse(name) {
            Some(mode) => out.push((mode, value)),
            None => problems.push(format!("{section}: unknown mode \"{name}\" (n, v, or t)")),
        }
    }
    out
}

fn keys(config: &mut Config, map: &Map<String, Value>, problems: &mut Vec<String>) {
    for (mode, table) in modes(map, "keys", problems) {
        let Some(table) = table.as_object() else {
            problems.push("keys: a mode's keys are an object".into());
            continue;
        };
        for (keys, value) in table {
            let (cmd, desc) = match value {
                Value::String(cmd) => (Some(cmd.as_str()), None),
                Value::Object(o) => (
                    o.get("cmd").and_then(Value::as_str),
                    o.get("desc").and_then(Value::as_str),
                ),
                _ => (None, None),
            };
            match cmd {
                Some(cmd) if !keys.is_empty() => config.keys.push(Binding {
                    mode,
                    keys: keys.clone(),
                    cmd: cmd.to_owned(),
                    desc: desc.map(str::to_owned),
                }),
                _ => problems.push(format!(
                    "keys: \"{keys}\" needs a command, or {{ \"cmd\": ..., \"desc\": ... }}"
                )),
            }
        }
    }
}

fn unmap(config: &mut Config, map: &Map<String, Value>, problems: &mut Vec<String>) {
    for (mode, list) in modes(map, "unmap", problems) {
        let Some(list) = list.as_array() else {
            problems.push("unmap: a mode's keys are a list".into());
            continue;
        };
        for keys in list {
            match keys.as_str() {
                Some(k) => config.unmap.push((mode, k.to_owned())),
                None => problems.push(format!("unmap: {keys} is not a key sequence")),
            }
        }
    }
}

fn bookmarks(
    config: &mut Config,
    map: &Map<String, Value>,
    home: &Path,
    problems: &mut Vec<String>,
) {
    for (key, value) in map {
        let mut chars = key.chars();
        let (Some(c), None) = (chars.next(), chars.next()) else {
            problems.push(format!("bookmarks: \"{key}\" is not one character"));
            continue;
        };
        let path = match value.as_str() {
            Some("~") => Some(home.to_owned()),
            Some(p) => match p.strip_prefix("~/") {
                Some(rest) => Some(home.join(rest)),
                None => Some(PathBuf::from(p)).filter(|p| p.is_absolute()),
            },
            None => None,
        };
        match path {
            Some(p) => config.bookmarks.push((c, p)),
            None => problems.push(format!(
                "bookmarks: \"{key}\" needs an absolute path or one under ~"
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::options::SortKey;

    // A bad entry is skipped and named, and the entries around it, in the same section and
    // after it, still apply: a mistake must not cost the rest of the file.
    #[test]
    fn a_bad_entry_skips_only_itself() {
        let text = r#"{
            "options": { "hidden": true, "ratio": [1, -2, 3], "sort": "mtime", "scroll_off": 4.5, "colour": 1 },
            "keys": {
                "n": { "gp": "cd ~/Projects", "gs": { "cmd": "cd ~/Shots", "desc": "Screenshots" }, "gx": 3 },
                "x": { "a": "b" },
                "t": { "P": { "desc": "no command" } }
            },
            "unmap": { "n": ["dD", 7] },
            "bookmarks": { "p": "~/Projects", "r": "/", "ab": "/tmp", "q": "relative" }
        }"#;
        let (c, problems) = parse(text, Path::new("/home/me"));

        let mut sort = Options::default().sort;
        sort.key = SortKey::Modified;
        assert_eq!(
            c.options,
            Options {
                show_hidden: true,
                sort,
                ..Options::default()
            }
        );
        assert_eq!(
            c.keys,
            [
                Binding {
                    mode: Mode::Normal,
                    keys: "gp".into(),
                    cmd: "cd ~/Projects".into(),
                    desc: None
                },
                Binding {
                    mode: Mode::Normal,
                    keys: "gs".into(),
                    cmd: "cd ~/Shots".into(),
                    desc: Some("Screenshots".into()),
                },
            ]
        );
        assert_eq!(c.unmap, [(Mode::Normal, "dD".into())]);
        assert_eq!(
            c.bookmarks,
            [
                ('p', PathBuf::from("/home/me/Projects")),
                ('r', PathBuf::from("/"))
            ]
        );
        // ratio, scroll_off, colour; gx, mode x, P; 7; ab, q.
        assert_eq!(problems.len(), 9, "{problems:#?}");
    }

    #[test]
    fn chooser_size_has_a_floor() {
        let (c, problems) = parse(
            r#"{ "options": { "chooser_size": [199, 150] } }"#,
            Path::new("/"),
        );
        assert_eq!(c.options.chooser_size, [960, 640]);
        assert_eq!(problems.len(), 1);
        let (c, problems) = parse(
            r#"{ "options": { "chooser_size": [200, 150] } }"#,
            Path::new("/"),
        );
        assert_eq!(c.options.chooser_size, [200, 150]);
        assert!(problems.is_empty());
    }
}
