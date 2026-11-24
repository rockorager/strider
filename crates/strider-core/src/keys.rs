//! Keys as vim writes them ("gg", "<C-d>", "<Space>", "<S-Tab>"), and the keymap: sequences
//! of keys bound to command lines, per mode, with the prefixes the which-key popup lists.
//!
//! Pure data and lookups. The app turns its toolkit's key events into [`Key`]s and keeps the
//! keys pending; [`Keymap::lookup`] says what they mean so far.

use std::fmt::Write as _;

use crate::config::{Config, Mode};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Mods {
    pub ctrl: bool,
    pub alt: bool,
    /// The logo key, `D-` in vim notation.
    pub super_: bool,
    /// Only for keys that type nothing (Shift+Tab); a typed character carries its shift in
    /// the character ("G").
    pub shift: bool,
}

impl Mods {
    fn none(self) -> bool {
        self == Mods::default()
    }
}

/// A character's code point, or an XKB keysym (0xff00 and up) for keys that type nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Key {
    pub code: u32,
    pub mods: Mods,
}

impl Key {
    pub fn char(ch: u32) -> Key {
        Key {
            code: ch,
            mods: Mods::default(),
        }
    }

    /// A printable character without modifiers.
    pub fn is_char(self) -> bool {
        self.mods.none() && self.code < 0xff00 && self.code > 0x20
    }
}

/// The XKB keysyms the notation names.
pub mod sym {
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    pub const RETURN: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const HOME: u32 = 0xff50;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const PAGE_UP: u32 = 0xff55;
    pub const PAGE_DOWN: u32 = 0xff56;
    pub const END: u32 = 0xff57;
    pub const INSERT: u32 = 0xff63;
    pub const MENU: u32 = 0xff67;
    pub const KP_ENTER: u32 = 0xff8d;
    pub const F1: u32 = 0xffbe;
    pub const DELETE: u32 = 0xffff;
    pub const ISO_LEFT_TAB: u32 = 0xfe20;
}

const NAMES: [(&str, u32); 24] = [
    ("Space", ' ' as u32),
    ("CR", sym::RETURN),
    ("Enter", sym::RETURN),
    ("Return", sym::RETURN),
    ("Esc", sym::ESCAPE),
    ("Tab", sym::TAB),
    ("BS", sym::BACKSPACE),
    ("Backspace", sym::BACKSPACE),
    ("Del", sym::DELETE),
    ("Delete", sym::DELETE),
    ("Up", sym::UP),
    ("Down", sym::DOWN),
    ("Left", sym::LEFT),
    ("Right", sym::RIGHT),
    ("Home", sym::HOME),
    ("End", sym::END),
    ("PageUp", sym::PAGE_UP),
    ("PageDown", sym::PAGE_DOWN),
    ("Insert", sym::INSERT),
    ("Menu", sym::MENU),
    ("lt", '<' as u32),
    ("gt", '>' as u32),
    ("Bar", '|' as u32),
    ("Bslash", '\\' as u32),
];

fn is_function_key(code: u32) -> bool {
    (sym::F1..sym::F1 + 24).contains(&code)
}

/// The name [`format`] gives a keysym or character, if it has one.
fn name_of(code: u32) -> Option<&'static str> {
    if is_function_key(code) {
        return None;
    }
    NAMES.iter().find(|n| n.1 == code).map(|n| n.0)
}

/// The most keys a binding takes.
pub const MAX_KEYS: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseError {
    InvalidKey,
    /// More than [`MAX_KEYS`] keys.
    TooLong,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            ParseError::InvalidKey => "invalid key",
            ParseError::TooLong => "too many keys",
        })
    }
}

impl std::error::Error for ParseError {}

/// Parses vim key notation. A `<` with no `>` after it is the character.
pub fn parse(spec: &str) -> Result<Vec<Key>, ParseError> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < spec.len() {
        if out.len() == MAX_KEYS {
            return Err(ParseError::TooLong);
        }
        let rest = &spec[i..];
        if let Some(after) = rest.strip_prefix('<')
            && let Some(close) = after.find('>')
            && close > 0
        {
            out.push(parse_angle(&after[..close])?);
            i += close + 2;
            continue;
        }
        let ch = rest.chars().next().expect("i is inside spec");
        out.push(Key::char(ch as u32));
        i += ch.len_utf8();
    }
    Ok(out)
}

fn parse_angle(inner: &str) -> Result<Key, ParseError> {
    let mut mods = Mods::default();
    let mut rest = inner;
    // Modifier prefixes: C-, A-, M-, S-, D- (super).
    while rest.len() > 2 && rest.as_bytes()[1] == b'-' {
        match rest.as_bytes()[0].to_ascii_lowercase() {
            b'c' => mods.ctrl = true,
            b'a' | b'm' => mods.alt = true,
            b's' => mods.shift = true,
            b'd' => mods.super_ = true,
            _ => return Err(ParseError::InvalidKey),
        }
        rest = &rest[2..];
    }
    let mut code = 0;
    if rest.len() > 1
        && let Some(digits) = rest.strip_prefix(['F', 'f'])
        && let Some(f) = parse_decimal(digits)
        && (1..=24).contains(&f)
    {
        code = sym::F1 + f - 1;
    }
    if code == 0
        && let Some(n) = NAMES.iter().find(|n| n.0.eq_ignore_ascii_case(rest))
    {
        code = n.1;
    }
    if code == 0 {
        let mut chars = rest.chars();
        match (chars.next(), chars.next()) {
            (Some(ch), None) => code = ch as u32,
            _ => return Err(ParseError::InvalidKey),
        }
    }
    // A shifted character is the character: <S-a> is "A".
    if mods.shift && code < 0xff00 && code != ' ' as u32 {
        if code < 128 {
            code = (code as u8).to_ascii_uppercase() as u32;
        }
        mods.shift = false;
    }
    Ok(Key { code, mods })
}

/// A decimal number as Zig's `std.fmt.parseInt` reads one: an optional `+`, and `_` allowed
/// between digits.
fn parse_decimal(s: &str) -> Option<u32> {
    let s = s.strip_prefix('+').unwrap_or(s);
    if s.is_empty() || s.starts_with('_') || s.ends_with('_') {
        return None;
    }
    let mut n: u32 = 0;
    for c in s.chars().filter(|&c| c != '_') {
        n = n.checked_mul(10)?.checked_add(c.to_digit(10)?)?;
    }
    Some(n)
}

/// Writes keys in vim notation.
pub fn format(keys: &[Key]) -> String {
    let mut out = String::new();
    for &k in keys {
        write_key(&mut out, k);
    }
    out
}

fn write_key(out: &mut String, k: Key) {
    let plain = k.mods.none();
    let name = name_of(k.code);
    if plain && name.is_none() && k.code < 0xff00 && k.code > 0x20 {
        out.extend(char::from_u32(k.code));
        return;
    }
    // "<" alone reads as itself in angle notation too.
    if plain && matches!(char::from_u32(k.code), Some('<' | '>' | '|' | '\\')) {
        out.extend(char::from_u32(k.code));
        return;
    }
    out.push('<');
    if k.mods.ctrl {
        out.push_str("C-");
    }
    if k.mods.alt {
        out.push_str("A-");
    }
    if k.mods.super_ {
        out.push_str("D-");
    }
    if k.mods.shift {
        out.push_str("S-");
    }
    if is_function_key(k.code) {
        let _ = write!(out, "F{}", k.code - sym::F1 + 1);
    } else if let Some(name) = name {
        out.push_str(name);
    } else if k.code < 0xff00 {
        // Not a code point: the Zig wrote what it had and stopped.
        let Some(ch) = char::from_u32(k.code) else {
            return;
        };
        out.push(ch);
    } else {
        let _ = write!(out, "0x{:x}", k.code);
    }
    out.push('>');
}

// The keymap ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub mode: Mode,
    pub keys: Vec<Key>,
    /// A command line, as typed after ":".
    pub cmd: String,
    /// What the which-key popup shows; empty for none, when it shows `cmd`.
    pub desc: String,
}

/// What a sequence of keys means so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Match<'a> {
    /// The binding the keys complete, if any.
    pub exact: Option<&'a Binding>,
    /// Whether longer bindings start with the keys.
    pub prefix: bool,
}

impl Match<'_> {
    pub const NONE: Match<'static> = Match {
        exact: None,
        prefix: false,
    };
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Keymap {
    bindings: Vec<Binding>,
}

impl Keymap {
    /// No bindings.
    pub fn new() -> Keymap {
        Keymap::default()
    }

    /// [`DEFAULT_BINDINGS`].
    pub fn defaults() -> Keymap {
        let mut km = Keymap::new();
        for &(mode, keys, cmd, desc) in DEFAULT_BINDINGS {
            km.map(mode, keys, cmd, desc)
                .expect("the default keymap parses");
        }
        km
    }

    /// Removes the config's `unmap` bindings, then binds its `keys` over what is left, so
    /// a user's binding wins. Each sequence that does not parse is skipped and named in the
    /// result; unmapping what is not bound is not a problem.
    pub fn apply(&mut self, config: &Config) -> Vec<String> {
        let mut problems = Vec::new();
        for (mode, spec) in &config.unmap {
            if let Err(e) = self.unmap(*mode, spec) {
                problems.push(format!("unmap: \"{spec}\": {e}"));
            }
        }
        for b in &config.keys {
            let desc = b.desc.as_deref().unwrap_or("");
            if let Err(e) = self.map(b.mode, &b.keys, &b.cmd, desc) {
                problems.push(format!("keys: \"{}\": {e}", b.keys));
            }
        }
        problems
    }

    /// Every binding, in the order first bound.
    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    /// Binds `spec` in `mode`, replacing what it was bound to.
    pub fn map(&mut self, mode: Mode, spec: &str, cmd: &str, desc: &str) -> Result<(), ParseError> {
        let keys = parse(spec)?;
        if keys.is_empty() {
            return Err(ParseError::InvalidKey);
        }
        let binding = Binding {
            mode,
            keys,
            cmd: cmd.to_owned(),
            desc: desc.to_owned(),
        };
        match self.find(mode, &binding.keys) {
            Some(i) => self.bindings[i] = binding,
            None => self.bindings.push(binding),
        }
        Ok(())
    }

    /// Removes the binding of `spec` in `mode`; false if there was none.
    pub fn unmap(&mut self, mode: Mode, spec: &str) -> Result<bool, ParseError> {
        let keys = parse(spec)?;
        let Some(i) = self.find(mode, &keys) else {
            return Ok(false);
        };
        self.bindings.remove(i);
        Ok(true)
    }

    fn find(&self, mode: Mode, keys: &[Key]) -> Option<usize> {
        self.bindings
            .iter()
            .position(|b| b.mode == mode && b.keys == keys)
    }

    /// What `keys` mean in `mode`; visual mode and the tasks view fall back to normal mode's
    /// bindings when they bind nothing that starts with the keys.
    pub fn lookup(&self, mode: Mode, keys: &[Key]) -> Match<'_> {
        let m = self.lookup_in(mode, keys);
        if mode != Mode::Normal && m == Match::NONE {
            return self.lookup_in(Mode::Normal, keys);
        }
        m
    }

    fn lookup_in(&self, mode: Mode, keys: &[Key]) -> Match<'_> {
        let mut m = Match::NONE;
        for b in &self.bindings {
            if b.mode != mode || !b.keys.starts_with(keys) {
                continue;
            }
            if b.keys.len() == keys.len() {
                m.exact = Some(b);
            } else {
                m.prefix = true;
            }
        }
        m
    }

    /// The bindings that continue `keys`, for the which-key popup: the mode's own before
    /// normal mode's, each next key once.
    pub fn continuations(&self, mode: Mode, keys: &[Key]) -> Vec<&Binding> {
        let modes: &[Mode] = if mode == Mode::Normal {
            &[Mode::Normal]
        } else {
            &[mode, Mode::Normal]
        };
        let mut out: Vec<&Binding> = Vec::new();
        for &md in modes {
            for b in &self.bindings {
                if b.mode != md || b.keys.len() <= keys.len() || !b.keys.starts_with(keys) {
                    continue;
                }
                let next = b.keys[keys.len()];
                if !out.iter().any(|o| o.keys[keys.len()] == next) {
                    out.push(b);
                }
            }
        }
        out
    }
}

/// The default keymap: ranger's and vim's keys. Each is (mode, keys, command, description).
pub const DEFAULT_BINDINGS: &[(Mode, &str, &str, &str)] = &[
    // Moving.
    (Mode::Normal, "j", "down", "Down"),
    (Mode::Normal, "k", "up", "Up"),
    (Mode::Normal, "h", "leave", "Parent folder"),
    (Mode::Normal, "l", "enter", "Enter or open"),
    (Mode::Normal, "<Down>", "down", "Down"),
    (Mode::Normal, "<Up>", "up", "Up"),
    (Mode::Normal, "<Left>", "leave", "Parent folder"),
    (Mode::Normal, "<Right>", "enter", "Enter or open"),
    (Mode::Normal, "<CR>", "open", "Open"),
    (Mode::Normal, "<BS>", "leave", "Parent folder"),
    (Mode::Normal, "gg", "top", "First entry"),
    (Mode::Normal, "G", "bottom", "Last entry"),
    (Mode::Normal, "<Home>", "top", "First entry"),
    (Mode::Normal, "<End>", "bottom", "Last entry"),
    (Mode::Normal, "<C-d>", "half-down", "Half a page down"),
    (Mode::Normal, "<C-u>", "half-up", "Half a page up"),
    (Mode::Normal, "<C-f>", "page-down", "Page down"),
    (Mode::Normal, "<C-b>", "page-up", "Page up"),
    (Mode::Normal, "<PageDown>", "page-down", "Page down"),
    (Mode::Normal, "<PageUp>", "page-up", "Page up"),
    (Mode::Normal, "H", "back", "Back in history"),
    (Mode::Normal, "L", "forward", "Forward in history"),
    (Mode::Normal, "J", "preview-down", "Scroll the preview down"),
    (Mode::Normal, "K", "preview-up", "Scroll the preview up"),
    // Going places.
    (Mode::Normal, "gh", "cd ~", "Home"),
    (Mode::Normal, "g/", "cd /", "Root"),
    (Mode::Normal, "gd", "cd-xdg DOWNLOAD", "Downloads"),
    (Mode::Normal, "gD", "cd-xdg DOCUMENTS", "Documents"),
    (Mode::Normal, "gc", "cd ~/.config", "~/.config"),
    (Mode::Normal, "gx", "trash-browse", "Trash"),
    (Mode::Normal, "gv", "drives", "Drives"),
    (Mode::Normal, "gm", "cd-media", "Mounted media"),
    (Mode::Normal, "gf", "fuzzy", "Find a file below"),
    (Mode::Normal, "gz", "zi", "Jump with zoxide"),
    (Mode::Normal, "g?", "help", "All keys"),
    (Mode::Normal, "<F1>", "help", "All keys"),
    // Tabs.
    (Mode::Normal, "gn", "tab-new", "New tab"),
    (Mode::Normal, "<C-t>", "tab-new", "New tab"),
    (Mode::Normal, "gt", "tab-next", "Next tab"),
    (Mode::Normal, "gT", "tab-prev", "Previous tab"),
    (Mode::Normal, "<Tab>", "tab-next", "Next tab"),
    (Mode::Normal, "<S-Tab>", "tab-prev", "Previous tab"),
    (Mode::Normal, "gq", "tab-close", "Close tab"),
    (Mode::Normal, "<C-w>", "tab-close", "Close tab"),
    (Mode::Normal, "<A-1>", "tab 1", "Tab 1"),
    (Mode::Normal, "<A-2>", "tab 2", "Tab 2"),
    (Mode::Normal, "<A-3>", "tab 3", "Tab 3"),
    (Mode::Normal, "<A-4>", "tab 4", "Tab 4"),
    (Mode::Normal, "<A-5>", "tab 5", "Tab 5"),
    (Mode::Normal, "<A-6>", "tab 6", "Tab 6"),
    (Mode::Normal, "<A-7>", "tab 7", "Tab 7"),
    (Mode::Normal, "<A-8>", "tab 8", "Tab 8"),
    (Mode::Normal, "<A-9>", "tab 9", "Tab 9"),
    // Searching.
    (Mode::Normal, "/", "search", "Search"),
    (Mode::Normal, "?", "search-back", "Search backward"),
    (Mode::Normal, "n", "search-next", "Next match"),
    (Mode::Normal, "N", "search-prev", "Previous match"),
    (Mode::Normal, "f", "find", "Jump to a name"),
    (Mode::Normal, "zf", "filter", "Filter the folder"),
    // Marking.
    (Mode::Normal, "<Space>", "toggle-mark", "Mark and move down"),
    (Mode::Normal, "v", "visual", "Visual selection"),
    (Mode::Normal, "V", "visual", "Visual selection"),
    (Mode::Normal, "<C-a>", "mark-all", "Mark everything"),
    (Mode::Normal, "<Esc>", "escape", "Cancel, unmark"),
    (Mode::Visual, "<Esc>", "visual-end", "Keep the range marked"),
    (Mode::Visual, "v", "visual-end", "Keep the range marked"),
    (Mode::Visual, "V", "visual-end", "Keep the range marked"),
    // Files.
    (Mode::Normal, "yy", "yank", "Copy"),
    (Mode::Normal, "dd", "cut", "Cut"),
    (Mode::Normal, "p", "paste", "Paste"),
    (Mode::Normal, "P", "paste-overwrite", "Paste, replacing"),
    (Mode::Normal, "yp", "yank-path", "Copy the path"),
    (Mode::Normal, "yn", "yank-name", "Copy the name"),
    (Mode::Normal, "yd", "yank-dir", "Copy the folder's path"),
    // Operators act on the range at once and leave visual mode, as in vim;
    // yy, dd, dT, and dD still work (the window finishes them).
    (Mode::Visual, "y", "yank", "Copy"),
    (Mode::Visual, "d", "cut", "Cut"),
    (Mode::Visual, "x", "cut", "Cut"),
    (Mode::Visual, "D", "trash", "Move to the trash"),
    (Mode::Visual, "X", "trash", "Move to the trash"),
    (Mode::Normal, "D", "trash", "Move to the trash"),
    (Mode::Normal, "dT", "trash", "Move to the trash"),
    (Mode::Normal, "dD", "delete", "Delete permanently"),
    (Mode::Normal, "dr", "restore", "Restore from the trash"),
    (Mode::Normal, "<Del>", "trash", "Move to the trash"),
    (Mode::Normal, "<S-Del>", "delete", "Delete permanently"),
    (Mode::Normal, "u", "undo", "Undo"),
    (Mode::Normal, "r", "rename", "Rename"),
    (Mode::Normal, "cw", "rename", "Rename"),
    (Mode::Normal, "A", "rename-append", "Rename at the end"),
    (Mode::Normal, "I", "rename-insert", "Rename at the start"),
    (Mode::Normal, "R", "bulk-rename", "Rename in $EDITOR"),
    (Mode::Normal, "<F2>", "rename", "Rename"),
    (Mode::Normal, "a", "create", "New file (or folder/)"),
    (Mode::Normal, "o", "open-with", "Open with…"),
    (Mode::Normal, "!", "shell-prompt", "Run a shell command"),
    (Mode::Normal, "S", "terminal", "Terminal here"),
    (Mode::Normal, "=", "chmod", "Change permissions"),
    (Mode::Normal, "w", "tasks", "Tasks"),
    (Mode::Normal, "<Menu>", "menu", "Context menu"),
    (Mode::Normal, "<S-F10>", "menu", "Context menu"),
    (Mode::Normal, "<A-CR>", "properties", "Properties"),
    (Mode::Normal, ">", "column-wider", "Widen the column"),
    (Mode::Normal, "<", "column-narrower", "Narrow the column"),
    (
        Mode::Normal,
        "z=",
        "column-reset",
        "Column widths from the ratio",
    ),
    // The tasks view.
    (Mode::Tasks, "j", "task-down", "Next task"),
    (Mode::Tasks, "<Down>", "task-down", "Next task"),
    (Mode::Tasks, "k", "task-up", "Previous task"),
    (Mode::Tasks, "<Up>", "task-up", "Previous task"),
    (Mode::Tasks, "p", "task-pause", "Pause or resume"),
    (Mode::Tasks, "<Space>", "task-pause", "Pause or resume"),
    (
        Mode::Tasks,
        "x",
        "task-cancel",
        "Cancel it, or remove it when done",
    ),
    (
        Mode::Tasks,
        "dd",
        "task-cancel",
        "Cancel it, or remove it when done",
    ),
    (Mode::Tasks, "<Esc>", "tasks", "Close"),
    (Mode::Tasks, "q", "tasks", "Close"),
    (Mode::Tasks, "w", "tasks", "Close"),
    (Mode::Normal, "<C-r>", "reload", "Reload"),
    // Views.
    (Mode::Normal, "zh", "toggle-hidden", "Hidden files"),
    (Mode::Normal, "<C-h>", "toggle-hidden", "Hidden files"),
    (Mode::Normal, "zp", "toggle-preview", "Preview column"),
    (Mode::Normal, "zi", "toggle-icons", "Icons"),
    (Mode::Normal, "sn", "sort name", "Sort by name"),
    (Mode::Normal, "ss", "sort size", "Sort by size"),
    (Mode::Normal, "sm", "sort modified", "Sort by modified"),
    (Mode::Normal, "st", "sort type", "Sort by type"),
    (Mode::Normal, "se", "sort extension", "Sort by extension"),
    (Mode::Normal, "sr", "sort-reverse", "Reverse the sort"),
    (Mode::Normal, "sd", "sort-dirs-first", "Folders first"),
    (Mode::Normal, "sN", "sort name reverse", "By name, reversed"),
    (
        Mode::Normal,
        "sS",
        "sort size reverse",
        "By size, largest first",
    ),
    (
        Mode::Normal,
        "sM",
        "sort modified reverse",
        "By modified, newest first",
    ),
    // Marks.
    (Mode::Normal, "m", "bookmark-set", "Set a bookmark"),
    (Mode::Normal, "'", "bookmark-jump", "Go to a bookmark"),
    (Mode::Normal, "`", "bookmark-jump", "Go to a bookmark"),
    (Mode::Normal, "dm", "bookmark-remove", "Remove a bookmark"),
    // Commands.
    (Mode::Normal, ":", "command", "Command line"),
    (Mode::Normal, ";", "command", "Command line"),
    (Mode::Normal, "q", "quit", "Close the tab or quit"),
    (Mode::Normal, "ZZ", "quit-all", "Quit"),
    (Mode::Normal, "ZQ", "quit-all", "Quit"),
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config;

    fn keys(spec: &str) -> Vec<Key> {
        parse(spec).unwrap()
    }

    // Shift+Tab confused with Tab, <lt> or <Space> read as letters, <S-a> kept as a shifted
    // "a" that no typed "A" matches, an unknown modifier accepted, or a bare "<" an error.
    #[test]
    fn parse_and_format() {
        let k = keys("gg");
        assert_eq!(k.len(), 2);
        assert_eq!(k[1].code, 'g' as u32);
        let k = keys("<C-d>");
        assert_eq!(k.len(), 1);
        assert!(k[0].mods.ctrl && k[0].code == 'd' as u32);
        let k = keys("<S-Tab><Space>x<lt>");
        assert_eq!(k.len(), 4);
        assert!(k[0].mods.shift && k[0].code == sym::TAB);
        assert_ne!(k[0], keys("<Tab>")[0]);
        assert_eq!(k[1].code, ' ' as u32);
        assert_eq!(k[3].code, '<' as u32);
        assert_eq!(format(&k), "<S-Tab><Space>x<");
        assert_eq!(format(&keys("<S-a><A-1><F2>")), "A<A-1><F2>");
        assert_eq!(parse("<C-xyz>"), Err(ParseError::InvalidKey));
        assert_eq!(parse("<Q-x>"), Err(ParseError::InvalidKey));
        // No closing ">", or nothing inside: the characters themselves.
        assert_eq!(keys("<>a<b"), keys("<lt><gt>a<lt>b"));
    }

    // An off-by-one in the limit: eight keys bind, the ninth does not.
    #[test]
    fn at_most_eight_keys() {
        assert_eq!(keys("abcdefgh").len(), 8);
        assert_eq!(parse("abcdefghi"), Err(ParseError::TooLong));
    }

    // A prefix not reported, a remap appended instead of replacing, visual mode not falling
    // back to normal mode, unmap leaving the binding, or the which-key popup listing normal
    // mode's <Esc> over visual mode's own.
    #[test]
    fn keymap_lookup_prefixes_and_visual_fallback() {
        let mut km = Keymap::new();
        km.map(Mode::Normal, "gg", "top", "Top").unwrap();
        km.map(Mode::Normal, "gh", "cd ~", "Home").unwrap();
        km.map(Mode::Normal, "j", "down", "Down").unwrap();
        km.map(Mode::Visual, "<Esc>", "visual-end", "").unwrap();
        km.map(Mode::Normal, "<Esc>", "escape", "").unwrap();
        km.map(Mode::Normal, "j", "down 1", "Down").unwrap();

        let m = km.lookup(Mode::Normal, &keys("g"));
        assert!(m.exact.is_none() && m.prefix);
        assert_eq!(km.continuations(Mode::Normal, &keys("g")).len(), 2);
        assert_eq!(
            km.lookup(Mode::Visual, &keys("j")).exact.unwrap().cmd,
            "down 1"
        );

        let cmds: Vec<&str> = km
            .continuations(Mode::Visual, &[])
            .iter()
            .map(|b| b.cmd.as_str())
            .collect();
        assert_eq!(cmds, ["visual-end", "top", "down 1"]);

        assert_eq!(km.unmap(Mode::Normal, "gg"), Ok(true));
        assert!(km.lookup(Mode::Normal, &keys("gg")).exact.is_none());
        assert_eq!(km.unmap(Mode::Normal, "gg"), Ok(false));
    }

    // A default that does not parse, two defaults with the same keys (the later silently
    // replacing the earlier), or <S-Tab> landing on <Tab>'s binding.
    #[test]
    fn defaults_parse_and_are_distinct() {
        let km = Keymap::defaults();
        assert_eq!(km.bindings().len(), DEFAULT_BINDINGS.len());
        assert_eq!(DEFAULT_BINDINGS.len(), 139);
        let cmd = |spec| {
            km.lookup(Mode::Normal, &keys(spec))
                .exact
                .unwrap()
                .cmd
                .as_str()
        };
        assert_eq!(cmd("<Tab>"), "tab-next");
        assert_eq!(cmd("<S-Tab>"), "tab-prev");
    }

    // A user binding over a default prefix losing the longer defaults (or not being found),
    // unmap not applied, a user binding not replacing a default, or a bad sequence aborting
    // the rest instead of being reported.
    #[test]
    fn config_applies_over_defaults() {
        let binding = |mode, keys: &str, cmd: &str, desc: Option<&str>| config::Binding {
            mode,
            keys: keys.into(),
            cmd: cmd.into(),
            desc: desc.map(Into::into),
        };
        let cfg = Config {
            keys: vec![
                binding(Mode::Normal, "g", "cd ~/Projects", None),
                binding(Mode::Normal, "<C-xyz>", "nothing", None),
                binding(Mode::Normal, "dd", "trash", None),
                binding(Mode::Visual, "j", "down 2", Some("Two")),
            ],
            unmap: vec![(Mode::Normal, "dD".into()), (Mode::Normal, "<Q-x>".into())],
            ..Config::default()
        };
        let mut km = Keymap::defaults();
        let problems = km.apply(&cfg);
        assert_eq!(problems.len(), 2, "{problems:?}");

        let m = km.lookup(Mode::Normal, &keys("g"));
        assert_eq!(m.exact.unwrap().cmd, "cd ~/Projects");
        assert!(m.prefix);
        assert_eq!(km.lookup(Mode::Normal, &keys("dD")), Match::NONE);
        let dd = km.lookup(Mode::Normal, &keys("dd")).exact.unwrap();
        assert_eq!((dd.cmd.as_str(), dd.desc.as_str()), ("trash", ""));
        let j = km.lookup(Mode::Visual, &keys("j")).exact.unwrap();
        assert_eq!((j.cmd.as_str(), j.desc.as_str()), ("down 2", "Two"));
        assert_eq!(
            km.lookup(Mode::Normal, &keys("j")).exact.unwrap().cmd,
            "down"
        );
        // "g" and visual "j" added, "dD" removed.
        assert_eq!(km.bindings().len(), DEFAULT_BINDINGS.len() + 1);
    }
}
