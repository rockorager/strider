//! The active [Omarchy](https://omarchy.org) theme's palette, resolved as Omarchy resolves it.
//!
//! Omarchy keeps its active theme in `~/.local/state/omarchy/current/theme/` (Omarchy 4), else
//! `~/.config/omarchy/current/theme/` (Omarchy 3.3), whose `colors.toml` holds a flat palette:
//! `mode`, `accent`, the backgrounds and foregrounds, the hues, and the terminal colors
//! `color0` to `color15`, some themes with legacy short names (`bg`, `fg`, `dark_bg`, ...).
//! [`Palette::parse`] fills every name the way Omarchy's `omarchy-theme-color` does, as siv
//! did for Strider: canonical names over legacy ones, ANSI colors as fallbacks, missing shades
//! mixed from the background, and the mode from `mode`, the legacy `theme_type`, a
//! `light.mode` file beside it, or the background's brightness. The app maps the result onto
//! its theme and watches the directory, which `omarchy-theme-set` replaces to switch themes.

use std::path::{Path, PathBuf};

/// Red, green, blue, and alpha.
pub type Rgba = [u8; 4];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Light,
    Dark,
}

/// The names of `colors.toml` that Strider reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Accent,
    Selection,
    Muted,
    Background,
    DarkBackground,
    DarkerBackground,
    LighterBackground,
    Foreground,
    DarkForeground,
    LightForeground,
    BrightForeground,
    Red,
    Yellow,
    Orange,
    Green,
    Cyan,
    Blue,
    Magenta,
    Purple,
    BrightRed,
    BrightYellow,
    BrightGreen,
    BrightCyan,
    BrightBlue,
    BrightMagenta,
    BrightPurple,
    Color0,
    Color1,
    Color2,
    Color3,
    Color4,
    Color5,
    Color6,
    Color7,
    Color8,
    Color9,
    Color10,
    Color11,
    Color12,
    Color13,
    Color14,
    Color15,
    Bg,
    DarkBg,
    DarkerBg,
    LighterBg,
    Fg,
    DarkFg,
    LightFg,
    BrightFg,
}

/// Every key with its name in `colors.toml`, in [`Key`]'s order.
const NAMES: [(Key, &str); 50] = {
    use Key::*;
    [
        (Accent, "accent"),
        (Selection, "selection"),
        (Muted, "muted"),
        (Background, "background"),
        (DarkBackground, "dark_background"),
        (DarkerBackground, "darker_background"),
        (LighterBackground, "lighter_background"),
        (Foreground, "foreground"),
        (DarkForeground, "dark_foreground"),
        (LightForeground, "light_foreground"),
        (BrightForeground, "bright_foreground"),
        (Red, "red"),
        (Yellow, "yellow"),
        (Orange, "orange"),
        (Green, "green"),
        (Cyan, "cyan"),
        (Blue, "blue"),
        (Magenta, "magenta"),
        (Purple, "purple"),
        (BrightRed, "bright_red"),
        (BrightYellow, "bright_yellow"),
        (BrightGreen, "bright_green"),
        (BrightCyan, "bright_cyan"),
        (BrightBlue, "bright_blue"),
        (BrightMagenta, "bright_magenta"),
        (BrightPurple, "bright_purple"),
        (Color0, "color0"),
        (Color1, "color1"),
        (Color2, "color2"),
        (Color3, "color3"),
        (Color4, "color4"),
        (Color5, "color5"),
        (Color6, "color6"),
        (Color7, "color7"),
        (Color8, "color8"),
        (Color9, "color9"),
        (Color10, "color10"),
        (Color11, "color11"),
        (Color12, "color12"),
        (Color13, "color13"),
        (Color14, "color14"),
        (Color15, "color15"),
        (Bg, "bg"),
        (DarkBg, "dark_bg"),
        (DarkerBg, "darker_bg"),
        (LighterBg, "lighter_bg"),
        (Fg, "fg"),
        (DarkFg, "dark_fg"),
        (LightFg, "light_fg"),
        (BrightFg, "bright_fg"),
    ]
};

/// A theme's colors with Omarchy's cascade applied, and its mode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Palette {
    pub mode: Mode,
    colors: [Option<Rgba>; NAMES.len()],
}

impl Palette {
    pub fn get(&self, k: Key) -> Option<Rgba> {
        self.colors[k as usize]
    }

    fn set(&mut self, k: Key, c: Rgba) {
        self.colors[k as usize] = Some(c);
    }

    /// `k` from the first of `from` that is set, unless `k` is set.
    fn alias(&mut self, k: Key, from: &[Key]) {
        if self.get(k).is_some() {
            return;
        }
        if let Some(c) = from.iter().find_map(|f| self.get(*f)) {
            self.set(k, c);
        }
    }

    /// Reads a `colors.toml`. `light_marker`: a `light.mode` file lies beside it, the legacy
    /// way to mark a light theme. Values that are not `#rgb`, `#rrggbb`, or `#rrggbbaa`
    /// strings, and keys inside tables, are skipped.
    pub fn parse(text: &str, light_marker: bool) -> Palette {
        use Key::*;
        let mut p = Palette {
            mode: Mode::Dark,
            colors: [None; NAMES.len()],
        };
        let (mut mode, mut theme_type) = (None, None);
        let mut in_table = false;
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with('[') {
                in_table = true;
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let Some(value) = string(value.trim()) else {
                continue;
            };
            if in_table {
                continue;
            }
            match key.trim() {
                "mode" => mode = parse_mode(value),
                "theme_type" => theme_type = parse_mode(value),
                key => {
                    if let (Some((k, _)), Some(c)) =
                        (NAMES.iter().find(|(_, n)| *n == key), parse_hex(value))
                    {
                        p.set(*k, c);
                    }
                }
            }
        }

        // The cascade of omarchy-theme-color's resolve_theme_colors, in its order: canonical
        // names over legacy ones, ANSI colors as fallbacks.
        for (canonical, legacy) in [
            (Background, Bg),
            (DarkBackground, DarkBg),
            (DarkerBackground, DarkerBg),
            (LighterBackground, LighterBg),
            (Foreground, Fg),
            (DarkForeground, DarkFg),
            (LightForeground, LightFg),
            (BrightForeground, BrightFg),
        ] {
            p.alias(canonical, &[legacy]);
        }
        p.alias(Background, &[Color0]);
        p.alias(Foreground, &[Color7]);
        if let Some(c) = p.get(Background) {
            p.set(Color0, c);
        }
        if let Some(c) = p.get(Foreground) {
            p.set(Color7, c);
        }
        for (hue, ansi) in [
            (Red, Color1),
            (Green, Color2),
            (Yellow, Color3),
            (Blue, Color4),
            (Magenta, Color5),
            (Cyan, Color6),
            (BrightRed, Color9),
            (BrightGreen, Color10),
            (BrightYellow, Color11),
            (BrightBlue, Color12),
            (BrightMagenta, Color13),
            (BrightCyan, Color14),
        ] {
            p.alias(hue, &[ansi]);
        }
        p.alias(Magenta, &[Purple]);
        p.alias(LightForeground, &[Color7, Foreground]);
        p.alias(BrightForeground, &[Color15, Foreground]);
        p.alias(LighterBackground, &[Color0, Background]);
        p.alias(DarkForeground, &[Color8, Foreground]);
        p.alias(Muted, &[Color8, DarkForeground]);
        p.alias(Selection, &[Color8, Color0, Background]);
        p.alias(Orange, &[Yellow]);
        if let Some(b) = p.get(Background) {
            const BLACK: Rgba = [0, 0, 0, 0xff];
            if p.get(DarkBackground).is_none() {
                p.set(DarkBackground, mix(b, BLACK, 0.25));
            }
            if p.get(DarkerBackground).is_none() {
                p.set(DarkerBackground, mix(b, BLACK, 0.5));
            }
        }
        p.alias(Accent, &[Blue]);

        // Its mode: `mode`, the legacy `theme_type`, a light.mode file, the background's
        // brightness, dark.
        p.mode = mode.or(theme_type).unwrap_or(if light_marker {
            Mode::Light
        } else {
            match p.get(Background) {
                Some([r, g, b, _]) if u32::from(r) + u32::from(g) + u32::from(b) > 382 => {
                    Mode::Light
                }
                _ => Mode::Dark,
            }
        });
        p
    }

    /// The active theme's palette, from the first of [`theme_dirs`] with a `colors.toml`, or
    /// None when no Omarchy theme is active.
    pub fn read(home: &Path) -> Option<Palette> {
        theme_dirs(home).into_iter().find_map(|dir| {
            let text = std::fs::read_to_string(dir.join("colors.toml")).ok()?;
            Some(Palette::parse(&text, dir.join("light.mode").exists()))
        })
    }
}

/// Where Omarchy keeps the active theme, newest layout first.
pub fn theme_dirs(home: &Path) -> [PathBuf; 2] {
    [
        home.join(".local/state/omarchy/current/theme"),
        home.join(".config/omarchy/current/theme"),
    ]
}

/// A TOML basic or literal string's contents; other values are None.
fn string(value: &str) -> Option<&str> {
    let q = value.chars().next().filter(|c| matches!(c, '"' | '\''))?;
    value[1..].split(q).next()
}

fn parse_mode(t: &str) -> Option<Mode> {
    match t {
        "light" => Some(Mode::Light),
        "dark" => Some(Mode::Dark),
        _ => None,
    }
}

fn parse_hex(s: &str) -> Option<Rgba> {
    let h = s.strip_prefix('#')?;
    if !h.bytes().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let byte = |x: &str| u8::from_str_radix(x, 16).ok();
    Some(match h.len() {
        3 => {
            let d = |i: usize| byte(&h[i..=i].repeat(2));
            [d(0)?, d(1)?, d(2)?, 0xff]
        }
        6 => [byte(&h[0..2])?, byte(&h[2..4])?, byte(&h[4..6])?, 0xff],
        8 => [
            byte(&h[0..2])?,
            byte(&h[2..4])?,
            byte(&h[4..6])?,
            byte(&h[6..8])?,
        ],
        _ => return None,
    })
}

/// `a` mixed toward `b` by `k`, rounded as siv rounds.
pub fn mix(a: Rgba, b: Rgba, k: f32) -> Rgba {
    std::array::from_fn(|i| (f32::from(a[i]) * (1.0 - k) + f32::from(b[i]) * k + 0.5) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use Key::*;

    const fn hex(c: u32) -> Option<Rgba> {
        Some([(c >> 16) as u8, (c >> 8) as u8, c as u8, 0xff])
    }

    // siv's "legacy names, ANSI fallbacks, and the mode without a mode key", with the values
    // it expects.
    #[test]
    fn legacy_names_and_ansi_fallbacks() {
        let p = Palette::parse(
            "bg = \"#eff1f5\"\nfg = \"#4c4f69\"\ncolor1 = \"#d20f39\"\ncolor4 = \"#1e66f5\"\n",
            false,
        );
        assert_eq!(p.mode, Mode::Light);
        assert_eq!(p.get(Background), hex(0xeff1f5));
        assert_eq!(p.get(Red), hex(0xd20f39));
        // The accent falls back to blue, which falls back to color4.
        assert_eq!(p.get(Accent), hex(0x1e66f5));
        // Missing shades are Omarchy's: the background mixed 25% toward black.
        assert_eq!(p.get(DarkBackground), hex(0xb3b5b8));
        // Canonical names win over legacy ones, whatever their order in the file.
        let p = Palette::parse("bg = \"#ffffff\"\nbackground = \"#000000\"\n", false);
        assert_eq!(p.get(Background), hex(0x000000));
    }

    #[test]
    fn mode_comes_from_mode_then_theme_type_then_marker_then_brightness() {
        assert_eq!(
            Palette::parse("background = \"#000000\"", true).mode,
            Mode::Light
        );
        assert_eq!(
            Palette::parse("theme_type = \"light\"\nbackground = \"#000000\"", false).mode,
            Mode::Light
        );
        assert_eq!(
            Palette::parse("mode = \"dark\"\ntheme_type = \"light\"", true).mode,
            Mode::Dark
        );
        // 128 * 3 = 384 is past the 382 midpoint; 127 * 3 = 381 is not.
        assert_eq!(
            Palette::parse("background = \"#808080\"", false).mode,
            Mode::Light
        );
        assert_eq!(
            Palette::parse("background = \"#7f7f7f\"", false).mode,
            Mode::Dark
        );
    }

    // Keys in a table belong to it, not to the palette; short hex forms expand.
    #[test]
    fn tables_are_skipped_and_short_hex_expands() {
        let p = Palette::parse("accent = '#f80'\n[extra]\nred = \"#ff0000\"\n", false);
        assert_eq!(p.get(Accent), hex(0xff8800));
        assert_eq!(p.get(Red), None);
    }
}
