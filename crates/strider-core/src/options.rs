//! Options: what `config.json` and `:set` change. Without a configuration these are what you
//! get.

use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SortKey {
    Name,
    Size,
    Modified,
    Type,
    Extension,
}

impl SortKey {
    /// A sort's name, or one of its aliases (`natural`, `mtime`, `mime`, `ext`).
    pub fn parse(t: &str) -> Option<SortKey> {
        Some(match t {
            "name" | "natural" => SortKey::Name,
            "size" => SortKey::Size,
            "modified" | "mtime" => SortKey::Modified,
            "type" | "mime" => SortKey::Type,
            "extension" | "ext" => SortKey::Extension,
            _ => return None,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Sort {
    pub key: SortKey,
    pub descending: bool,
    /// Folders before files whatever the order, as file managers do.
    pub folders_first: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Options {
    /// Show entries whose names start with a dot.
    pub show_hidden: bool,
    pub sort: Sort,
    /// Widths of the parent, current, and preview columns, as shares (ranger's
    /// column_ratios).
    pub ratio: [f32; 3],
    /// The parent column widens to show its longest name, up to a quarter of the window,
    /// taking the room from the preview.
    pub fit_parent: bool,
    /// Logical pixels: a window narrower than this hides the parent column, and one
    /// narrower than two thirds of it the preview too.
    pub narrow_width: u32,
    /// The size a file chooser window asks for, in logical pixels, until the user resizes
    /// one (that size is remembered).
    pub chooser_size: [u32; 2],
    /// Themed icons beside names.
    pub icons: bool,
    /// The preview column.
    pub preview: bool,
    /// Image previews (decoded at the size shown).
    pub preview_images: bool,
    /// How much of a text file a preview reads.
    pub preview_max_bytes: u32,
    /// Image files larger than this show their details instead.
    pub preview_max_image_bytes: u32,
    /// Syntax coloring in text previews.
    pub syntax: bool,
    /// Milliseconds before the which-key popup shows after a prefix; 0 shows it at once.
    pub which_key_delay: u32,
    /// Rows kept visible above and below the cursor.
    pub scroll_off: u32,
    /// Searches wrap around the end.
    pub wrap_scan: bool,
    /// f: close the prompt as soon as one name matches, as ranger does; off, Enter closes
    /// it.
    pub find_auto_accept: bool,
    /// Ask before deleting permanently.
    pub confirm_delete: bool,
    /// Sizes in the current column.
    pub show_size: bool,
    /// The terminal for $EDITOR and shell commands, as a command line that the program
    /// follows ("foot", "kitty --"); empty finds one.
    pub terminal: String,
    /// The editor for bulk renames; empty uses $VISUAL, then $EDITOR, then vi.
    pub editor: String,
    /// Whether the editor is a terminal program (run in `terminal`).
    pub editor_in_terminal: bool,
    /// The shell for ! commands.
    pub shell: String,
    /// Re-read a shown folder that is not watched when it is older than this many
    /// milliseconds.
    pub stale_ms: u32,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            show_hidden: false,
            sort: Sort {
                key: SortKey::Name,
                descending: false,
                folders_first: true,
            },
            ratio: [1.0, 3.0, 4.0],
            fit_parent: true,
            narrow_width: 640,
            chooser_size: [960, 640],
            icons: true,
            preview: true,
            preview_images: true,
            preview_max_bytes: 128 * 1024,
            preview_max_image_bytes: 64 * 1024 * 1024,
            syntax: true,
            which_key_delay: 300,
            scroll_off: 3,
            wrap_scan: true,
            find_auto_accept: true,
            confirm_delete: true,
            show_size: true,
            terminal: String::new(),
            editor: String::new(),
            editor_in_terminal: true,
            shell: "sh".into(),
            stale_ms: 2000,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Boolean,
    Number,
    String,
    Sort,
    Ratio,
    Size,
}

pub struct Info {
    pub name: &'static str,
    pub kind: Kind,
    pub desc: &'static str,
}

/// The options `config.json` and `:set` know, with what each means.
pub const INFOS: &[Info] = &[
    Info {
        name: "hidden",
        kind: Kind::Boolean,
        desc: "Show hidden files",
    },
    Info {
        name: "sort",
        kind: Kind::Sort,
        desc: "Sort by: name, size, modified, type, extension",
    },
    Info {
        name: "sort_reverse",
        kind: Kind::Boolean,
        desc: "Reverse the sort",
    },
    Info {
        name: "dirs_first",
        kind: Kind::Boolean,
        desc: "Folders before files",
    },
    Info {
        name: "ratio",
        kind: Kind::Ratio,
        desc: "Column widths, e.g. [1, 3, 4]",
    },
    Info {
        name: "fit_parent",
        kind: Kind::Boolean,
        desc: "Widen the parent column to fit its names",
    },
    Info {
        name: "narrow_width",
        kind: Kind::Number,
        desc: "Hide the parent column below this window width",
    },
    Info {
        name: "chooser_size",
        kind: Kind::Size,
        desc: "File chooser window size, e.g. [960, 640]",
    },
    Info {
        name: "icons",
        kind: Kind::Boolean,
        desc: "Icons beside names",
    },
    Info {
        name: "preview",
        kind: Kind::Boolean,
        desc: "The preview column",
    },
    Info {
        name: "preview_images",
        kind: Kind::Boolean,
        desc: "Image previews",
    },
    Info {
        name: "preview_max_bytes",
        kind: Kind::Number,
        desc: "How much of a text file a preview reads",
    },
    Info {
        name: "preview_max_image_bytes",
        kind: Kind::Number,
        desc: "Larger images show their details",
    },
    Info {
        name: "syntax",
        kind: Kind::Boolean,
        desc: "Syntax coloring in previews",
    },
    Info {
        name: "which_key_delay",
        kind: Kind::Number,
        desc: "Milliseconds before the key hints show",
    },
    Info {
        name: "scroll_off",
        kind: Kind::Number,
        desc: "Rows kept visible around the cursor",
    },
    Info {
        name: "wrap_scan",
        kind: Kind::Boolean,
        desc: "Searches wrap around",
    },
    Info {
        name: "find_auto_accept",
        kind: Kind::Boolean,
        desc: "f jumps to a single match at once",
    },
    Info {
        name: "confirm_delete",
        kind: Kind::Boolean,
        desc: "Ask before deleting permanently",
    },
    Info {
        name: "show_size",
        kind: Kind::Boolean,
        desc: "Sizes in the current column",
    },
    Info {
        name: "terminal",
        kind: Kind::String,
        desc: "Terminal command for editors and shells",
    },
    Info {
        name: "editor",
        kind: Kind::String,
        desc: "Editor for bulk renames",
    },
    Info {
        name: "editor_in_terminal",
        kind: Kind::Boolean,
        desc: "Run the editor in the terminal",
    },
    Info {
        name: "shell",
        kind: Kind::String,
        desc: "Shell for ! commands",
    },
    Info {
        name: "stale_ms",
        kind: Kind::Number,
        desc: "Re-read unwatched folders older than this",
    },
];

pub fn info(name: &str) -> Option<&'static Info> {
    INFOS.iter().find(|i| i.name == name)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SetError {
    UnknownOption,
    InvalidValue,
}

impl Options {
    /// Sets an option from its value in `config.json`: a boolean, a whole number, a string,
    /// a sort's name, three non-negative shares for `ratio`, or a width of at least 200 and a
    /// height of at least 150 for `chooser_size`.
    pub fn set_json(&mut self, name: &str, value: &Value) -> Result<(), SetError> {
        let info = info(name).ok_or(SetError::UnknownOption)?;
        let bad = SetError::InvalidValue;
        match info.kind {
            Kind::Boolean => *self.bool_mut(name) = value.as_bool().ok_or(bad)?,
            Kind::Number => {
                *self.number_mut(name) = value
                    .as_u64()
                    .and_then(|n| u32::try_from(n).ok())
                    .ok_or(bad)?;
            }
            Kind::String => *self.string_mut(name) = value.as_str().ok_or(bad)?.to_owned(),
            Kind::Sort => self.sort.key = value.as_str().and_then(SortKey::parse).ok_or(bad)?,
            Kind::Ratio => {
                let shares = value.as_array().filter(|a| a.len() == 3).ok_or(bad)?;
                let mut r = [0.0; 3];
                for (x, v) in r.iter_mut().zip(shares) {
                    *x = v.as_f64().filter(|f| *f >= 0.0).ok_or(bad)? as f32;
                }
                self.ratio = r;
            }
            Kind::Size => {
                let wh = value.as_array().filter(|a| a.len() == 2).ok_or(bad)?;
                let side = |v: &Value, min: u64| {
                    v.as_u64()
                        .filter(|n| *n >= min)
                        .and_then(|n| u32::try_from(n).ok())
                };
                self.chooser_size = [side(&wh[0], 200).ok_or(bad)?, side(&wh[1], 150).ok_or(bad)?];
            }
        }
        Ok(())
    }

    /// Sets an option as `:set` takes it: `name value` or `name=value`; a boolean's bare
    /// name turns it on, `noname` off, and `name!` flips it. Returns the option's name.
    pub fn set_line<'a>(&mut self, line: &'a str) -> Result<&'a str, (&'a str, SetError)> {
        let line = line.trim_start_matches([' ', '=']);
        let end = line.find([' ', '=']).unwrap_or(line.len());
        let (mut name, rest) = line.split_at(end);
        let rest = rest.trim_start_matches([' ', '=']).trim_end();
        let mut value = (!rest.is_empty()).then_some(rest);
        let boolean = |n: &str| info(n).is_some_and(|i| i.kind == Kind::Boolean);
        if let Some(n) = name.strip_suffix('!') {
            name = n;
            value = None;
        } else if let Some(n) = name.strip_prefix("no").filter(|n| boolean(n)) {
            name = n;
            value = Some("false");
        } else if value.is_none() && boolean(name) {
            value = Some("true");
        }
        self.set_text(name, value)
            .map(|()| name)
            .map_err(|e| (name, e))
    }

    /// Sets an option from typed text: a boolean (`true`, `on`, `yes`, `1`, or their
    /// opposites; none flips it), a whole number, a string, a sort's name, three shares
    /// for `ratio` ("1 3 4", "1,3,4"), or a size for `chooser_size` ("960x640").
    pub fn set_text(&mut self, name: &str, value: Option<&str>) -> Result<(), SetError> {
        let info = info(name).ok_or(SetError::UnknownOption)?;
        let bad = SetError::InvalidValue;
        match info.kind {
            Kind::Boolean => {
                let v = match value {
                    Some(t) => parse_bool(t).ok_or(bad)?,
                    None => !*self.bool_mut(name),
                };
                *self.bool_mut(name) = v;
            }
            Kind::Number => *self.number_mut(name) = value.ok_or(bad)?.parse().map_err(|_| bad)?,
            Kind::String => *self.string_mut(name) = value.unwrap_or("").to_owned(),
            Kind::Sort => self.sort.key = value.and_then(SortKey::parse).ok_or(bad)?,
            Kind::Ratio => {
                let mut words = value
                    .ok_or(bad)?
                    .split([' ', ',', ':', '{', '}'])
                    .filter(|w| !w.is_empty());
                let mut r = [0.0; 3];
                for x in &mut r {
                    let w: f32 = words.next().ok_or(bad)?.parse().map_err(|_| bad)?;
                    if w < 0.0 {
                        return Err(bad);
                    }
                    *x = w;
                }
                self.ratio = r;
            }
            Kind::Size => {
                self.chooser_size =
                    crate::state::parse_chooser_size(value.ok_or(bad)?.as_bytes()).ok_or(bad)?;
            }
        }
        Ok(())
    }

    fn bool_mut(&mut self, name: &str) -> &mut bool {
        match name {
            "hidden" => &mut self.show_hidden,
            "sort_reverse" => &mut self.sort.descending,
            "dirs_first" => &mut self.sort.folders_first,
            "fit_parent" => &mut self.fit_parent,
            "icons" => &mut self.icons,
            "preview" => &mut self.preview,
            "preview_images" => &mut self.preview_images,
            "syntax" => &mut self.syntax,
            "wrap_scan" => &mut self.wrap_scan,
            "find_auto_accept" => &mut self.find_auto_accept,
            "confirm_delete" => &mut self.confirm_delete,
            "show_size" => &mut self.show_size,
            "editor_in_terminal" => &mut self.editor_in_terminal,
            _ => unreachable!("{name} is in INFOS as a boolean"),
        }
    }

    fn number_mut(&mut self, name: &str) -> &mut u32 {
        match name {
            "narrow_width" => &mut self.narrow_width,
            "preview_max_bytes" => &mut self.preview_max_bytes,
            "preview_max_image_bytes" => &mut self.preview_max_image_bytes,
            "which_key_delay" => &mut self.which_key_delay,
            "scroll_off" => &mut self.scroll_off,
            "stale_ms" => &mut self.stale_ms,
            _ => unreachable!("{name} is in INFOS as a number"),
        }
    }

    fn string_mut(&mut self, name: &str) -> &mut String {
        match name {
            "terminal" => &mut self.terminal,
            "editor" => &mut self.editor,
            "shell" => &mut self.shell,
            _ => unreachable!("{name} is in INFOS as a string"),
        }
    }
}

/// A boolean as typed: `true`, `on`, `yes`, or `1`, and their opposites, in any case.
pub fn parse_bool(t: &str) -> Option<bool> {
    let is = |words: [&str; 4]| words.iter().any(|w| w.eq_ignore_ascii_case(t));
    if is(["true", "on", "yes", "1"]) {
        Some(true)
    } else if is(["false", "off", "no", "0"]) {
        Some(false)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // :set's grammar, as vim's: the "no" prefix only for booleans (so "notes" is no
    // option rather than "tes" turned off), "!" flipping, a bare boolean turning on.
    #[test]
    fn set_lines() {
        let mut o = Options::default();
        assert_eq!(o.set_line("hidden"), Ok("hidden"));
        assert!(o.show_hidden);
        assert_eq!(o.set_line("nohidden"), Ok("hidden"));
        assert!(!o.show_hidden);
        o.set_line("hidden!").unwrap();
        o.set_line("hidden!").unwrap();
        assert!(!o.show_hidden);
        o.set_line("icons=OFF").unwrap();
        assert!(!o.icons);
        o.set_line("sort mtime").unwrap();
        assert_eq!(o.sort.key, SortKey::Modified);
        o.set_line("ratio 1,2 , 5").unwrap();
        assert_eq!(o.ratio, [1.0, 2.0, 5.0]);
        o.set_line("chooser_size 960x640").unwrap();
        assert_eq!(o.chooser_size, [960, 640]);
        o.set_line("shell fish -c").unwrap();
        assert_eq!(o.shell, "fish -c");
        assert_eq!(o.set_line("which_key_delay=0"), Ok("which_key_delay"));
        assert_eq!(o.which_key_delay, 0);

        let before = o.clone();
        assert_eq!(o.set_line("notes"), Err(("notes", SetError::UnknownOption)));
        assert_eq!(
            o.set_line("noratio"),
            Err(("noratio", SetError::UnknownOption))
        );
        for bad in [
            "hidden maybe",
            "scroll_off",
            "scroll_off -1",
            "ratio 1 2",
            "ratio 1 -2 3",
            "chooser_size 100x640",
            "sort colour",
        ] {
            assert_eq!(
                o.set_line(bad).map_err(|e| e.1),
                Err(SetError::InvalidValue),
                "{bad}"
            );
        }
        assert_eq!(o, before, "a bad value changes nothing");
    }
}
