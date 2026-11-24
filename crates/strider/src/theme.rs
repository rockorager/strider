//! Strider's look: Keywork's theme as the desktop gives it (light or dark, its accent, and
//! higher contrast), or the active Omarchy theme's colors, as siv gave them to the Zig
//! build, in the monospace family Fontconfig resolves.
//!
//! Both follow live. One inotify watcher covers each directory an Omarchy theme may be in
//! and its parent, since `omarchy-theme-set` replaces the theme directory itself, and the
//! Fontconfig configuration directory with its `conf.d`, which `omarchy-font-set` rewrites.
//! A change to the theme reads its palette again and dresses the window in it; one to
//! Fontconfig asks `fc-match` (a new process, so the new configuration) which family
//! `monospace` is now, since Keywork reads Fontconfig's configuration only once. The icon
//! theme needs nothing here: Omarchy sets GNOME's `icon-theme`, which Keywork hears through
//! the settings portal, and `main.rs` loads it again on `on_icon_theme`.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use keywork::desktop::watch::{DirWatcher, WatchId};
use keywork::prelude::*;
use keywork::theme::{
    Appearance, ColorRole, DesktopAppearance, Paint, Seeds, Theme, contrast_ratio,
};
use keywork::{FontFamily, Instant, Timer};
use strider_core::omarchy::{Key, Mode, Palette, Rgba, mix, theme_dirs};

use crate::app::Strider;

/// A switch writes several files and directories; they are read once, together.
const LATENCY: Duration = Duration::from_millis(100);

/// Strider's own paints, which no Keywork role names: [`Paint::App`] slots that the
/// desktop's theme fills from its grays and roles and an Omarchy theme from its palette.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    /// Behind the header and the status line.
    Chrome,
    /// The parent column, the most recessed.
    Parent,
    /// The current column, a step nearer.
    Current,
    /// The preview, on the page's own background.
    Preview,
    /// Text on the cursor's row, so folders' accent and marks' warning never sit on the
    /// selection's own color.
    Cursor,
}

impl Tone {
    pub fn paint(self) -> Paint {
        Paint::App(self as u8)
    }
}

/// The tones under the desktop's theme, in [`Tone`]'s order. The grays and roles resolve in
/// light and dark alike, as siv's compiled sidebar, secondary sidebar, and view colors did.
static DESKTOP_TONES: [Paint; 5] = [
    Paint::Role(ColorRole::Panel),
    Paint::Gray(3),
    Paint::Gray(2),
    Paint::Role(ColorRole::Background),
    Paint::Role(ColorRole::Text),
];

/// The tones in higher contrast, where the cursor's row is the solid accent.
static HIGH_CONTRAST_TONES: [Paint; 5] = [
    Paint::Role(ColorRole::Panel),
    Paint::Gray(3),
    Paint::Gray(2),
    Paint::Role(ColorRole::Background),
    Paint::Role(ColorRole::OnAccent),
];

/// The paints that go on every theme the window gets, kept for the life of the process
/// since a theme holds `'static` slices; the same paints give back the same slice, so a
/// switch back and forth adds nothing.
fn keep_paints(paints: [Paint; 5]) -> &'static [Paint] {
    static KEPT: Mutex<Vec<&'static [Paint]>> = Mutex::new(Vec::new());
    let mut kept = KEPT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(k) = kept.iter().find(|k| **k == paints) {
        return k;
    }
    let k: &'static [Paint] = Box::leak(Box::new(paints));
    kept.push(k);
    k
}

/// A family name kept for the life of the process, as [`FontFamily::Named`] takes one.
fn keep_name(name: String) -> &'static str {
    static KEPT: Mutex<Vec<&'static str>> = Mutex::new(Vec::new());
    let mut kept = KEPT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(k) = kept.iter().find(|k| **k == name) {
        return k;
    }
    let k: &'static str = name.leak();
    kept.push(k);
    k
}

fn color([r, g, b, a]: Rgba) -> keywork::Color {
    keywork::Color::srgba(r, g, b, a)
}

fn contrast(a: Rgba, b: Rgba) -> f32 {
    contrast_ratio(color(a), color(b))
}

const WHITE: Rgba = [0xff; 4];
const BLACK: Rgba = [0, 0, 0, 0xff];

/// Black or white, whichever reads better on `bg`.
fn on_color(bg: Rgba) -> Rgba {
    if contrast(WHITE, bg) >= contrast(BLACK, bg) {
        WHITE
    } else {
        BLACK
    }
}

/// Secondary text: the foreground mixed toward the background, 5% at a time up to 40%, for
/// as long as it still reads (4.5:1) on every surface of `under`, as siv's `muted_fg`.
fn readable(fg: Rgba, bg: Rgba, under: &[Rgba]) -> Rgba {
    let mut best = fg;
    for step in 1..=8 {
        let c = mix(fg, bg, step as f32 * 0.05);
        if under.iter().any(|u| contrast(c, *u) < 4.5) {
            break;
        }
        best = c;
    }
    best
}

/// The cursor's row: Omarchy's `selection`, a stop on its ramp for selected text on the
/// background, tinted toward the accent until it stands out (1.2:1) from every surface of
/// `under` a row sits on, as the siv the Zig build pinned (752d328d) did.
fn selection(sel: Rgba, accent: Rgba, under: &[Rgba]) -> Rgba {
    (0..=12)
        .map(|step| mix(sel, accent, step as f32 * 0.05))
        .find(|c| under.iter().all(|u| contrast(*c, *u) >= 1.2))
        .unwrap_or_else(|| mix(sel, accent, 0.6))
}

fn appearance(mode: Mode) -> Appearance {
    match mode {
        Mode::Light => Appearance::Light,
        Mode::Dark => Appearance::Dark,
    }
}

/// An Omarchy theme's neutral ramp, from `background` to `bright_foreground`, with the
/// colors siv derived from it. None without a background and a foreground.
struct Ramp {
    bg: Rgba,
    fg: Rgba,
    dark_bg: Rgba,
    darker_bg: Rgba,
    lighter_bg: Rgba,
    muted: Rgba,
    selection: Rgba,
    on_selection: Rgba,
}

impl Ramp {
    fn of(p: &Palette, accent: Rgba) -> Option<Ramp> {
        let (bg, fg) = (p.get(Key::Background)?, p.get(Key::Foreground)?);
        // The palette's cascade fills the rest whenever the background is set.
        let get = |k| p.get(k).unwrap_or(bg);
        let (dark_bg, darker_bg) = (get(Key::DarkBackground), get(Key::DarkerBackground));
        let sel = selection(get(Key::Selection), accent, &[bg, dark_bg, darker_bg]);
        let bright = p.get(Key::BrightForeground).unwrap_or(fg);
        let on = if contrast(bright, sel) >= contrast(fg, sel) {
            bright
        } else {
            fg
        };
        Some(Ramp {
            bg,
            fg,
            dark_bg,
            darker_bg,
            lighter_bg: get(Key::LighterBackground),
            muted: p.get(Key::Muted).unwrap_or(fg),
            selection: sel,
            on_selection: if contrast(on, sel) >= 4.5 {
                on
            } else {
                on_color(sel)
            },
        })
    }

    /// The tones, as siv mapped them: the window and the current column in
    /// `dark_background`, the parent in `darker_background`, the preview in `background`.
    fn tones(&self) -> [Paint; 5] {
        [
            self.dark_bg,
            self.darker_bg,
            self.dark_bg,
            self.bg,
            self.on_selection,
        ]
        .map(|c| Paint::Color(color(c)))
    }
}

/// The palette's accent, else its foreground, else Keywork's indigo.
fn accent(p: &Palette) -> Rgba {
    p.get(Key::Accent)
        .or(p.get(Key::Foreground))
        .unwrap_or([0x3e, 0x63, 0xdd, 0xff])
}

/// An Omarchy theme as a Keywork theme in its mode: scales grown from its accent and
/// background, its red, yellow, and green for errors, marks, and executables, and the roles
/// Strider wears set to the colors siv gave its tokens. The accent is the theme's, whatever
/// the desktop's.
pub fn omarchy_theme(p: &Palette) -> Theme {
    use ColorRole::*;
    let mode = appearance(p.mode);
    let bg = p.get(Key::Background);
    let accent = accent(p);
    let seeds = Seeds {
        accent: color(accent),
        accent_dark: None,
        light: bg.filter(|_| mode == Appearance::Light).map(color),
        dark: bg.filter(|_| mode == Appearance::Dark).map(color),
        danger: p.get(Key::Red).map(color),
        warning: p.get(Key::Yellow).map(color),
        success: p.get(Key::Green).map(color),
    };
    let mut theme = Theme::from_colors(seeds).appearance(mode);
    let mut colors = vec![
        (AccentFill, accent),
        (AccentText, accent),
        (FocusRing, accent),
        (OnAccent, on_color(accent)),
    ];
    for (key, roles) in [
        (Key::Red, [Danger, DangerText]),
        (Key::Yellow, [Warning, WarningText]),
        (Key::Green, [Success, SuccessText]),
    ] {
        if let Some(c) = p.get(key) {
            colors.extend(roles.map(|r| (r, c)));
        }
    }
    if let Some(r) = Ramp::of(p, accent) {
        // Raised surfaces: a step toward the text in dark themes, the lightest surface in
        // light ones.
        let card = match mode {
            Appearance::Dark => r.lighter_bg,
            Appearance::Light => r.bg,
        };
        colors.extend([
            (Background, r.bg),
            (Panel, r.darker_bg),
            (Surface, card),
            (Component, r.lighter_bg),
            (ComponentHover, mix(r.lighter_bg, r.fg, 0.1)),
            (ComponentPressed, mix(r.lighter_bg, r.fg, 0.2)),
            (BorderSubtle, mix(r.bg, r.muted, 0.6)),
            (Border, r.muted),
            (Text, r.fg),
            (Caret, r.fg),
            (
                TextMuted,
                readable(r.fg, r.bg, &[r.bg, r.dark_bg, r.darker_bg]),
            ),
            (TextDisabled, mix(r.fg, r.bg, 0.5)),
            (Selection, r.selection),
            (SelectionHover, mix(r.selection, r.on_selection, 0.08)),
            (TextSelection, r.selection),
        ]);
    }
    let roles = theme.roles.get_mut(mode);
    for (role, c) in colors {
        roles[role] = Paint::Color(color(c));
    }
    theme
}

/// Whether `theme` follows a desktop that asks for higher contrast: Keywork hands the map
/// no reading, but [`Theme::follow_desktop`] makes muted text body text only then.
fn high_contrast(theme: &Theme) -> bool {
    theme.roles.light[ColorRole::TextMuted] == Paint::Role(ColorRole::Text)
}

/// What the window does to every theme it gets: text in monospace, or the family
/// Fontconfig names for it since the configuration changed, and Strider's tones. Under an
/// Omarchy theme, its mode, whatever the desktop prefers. In higher contrast the cursor's
/// row is the solid accent, and an Omarchy theme gives way to the desktop's in its mode, as
/// siv had it: Omarchy's themes have no high-contrast variant, and theirs would undo what
/// the user asked for.
pub fn map(
    palette: Option<&Palette>,
    font: Option<&'static str>,
) -> impl Fn(Theme) -> Theme + use<> {
    let mode = palette.map(|p| appearance(p.mode));
    let tones: &'static [Paint] = match palette.and_then(|p| Ramp::of(p, accent(p))) {
        Some(r) => keep_paints(r.tones()),
        None => &DESKTOP_TONES,
    };
    let family = font.map_or(FontFamily::Monospace, FontFamily::Named);
    move |theme| {
        let high = high_contrast(&theme);
        let mut theme = match (high, mode) {
            (true, Some(mode)) => {
                let desktop = DesktopAppearance {
                    high_contrast: true,
                    reduced_motion: theme.motion.reduced,
                    ..DesktopAppearance::default()
                };
                Theme::default().follow_desktop(&desktop).appearance(mode)
            }
            (false, Some(mode)) => theme.appearance(mode),
            (_, None) => theme,
        };
        if high {
            theme.roles.set(ColorRole::Selection, ColorRole::AccentFill);
            theme
                .roles
                .set(ColorRole::SelectionHover, ColorRole::AccentFillHover);
        }
        let tones = if high { &HIGH_CONTRAST_TONES } else { tones };
        theme.fonts.ui = family;
        theme.app_paints(tones, tones)
    }
}

/// What the window wears, and the watcher that keeps it current.
pub struct Follow {
    home: PathBuf,
    fontconfig: PathBuf,
    /// The active Omarchy theme's palette, or None without one.
    pub palette: Option<Palette>,
    /// The family `monospace` resolves to since Fontconfig's configuration changed; None
    /// before, when Keywork's own resolution of `monospace` holds.
    font: Option<&'static str>,
    watcher: Option<DirWatcher>,
    themes: Vec<WatchId>,
    fonts: Vec<WatchId>,
    /// The timer armed for the watcher's next batch, by its deadline.
    armed: Option<(Instant, Timer)>,
    /// Light or dark as `--light` or `--dark` chose, instead of the desktop's.
    pub scheme: Option<Appearance>,
}

impl Follow {
    /// Reads the Omarchy theme under `home`, if one is active.
    pub fn new(home: &Path) -> Follow {
        let config = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home.join(".config"));
        Follow {
            home: home.to_owned(),
            fontconfig: config.join("fontconfig"),
            palette: Palette::read(home),
            font: None,
            watcher: None,
            themes: Vec::new(),
            fonts: Vec::new(),
            armed: None,
            scheme: None,
        }
    }

    /// What the windows wear from the theme the desktop's settings make.
    fn map(&self) -> impl Fn(Theme) -> Theme + use<> {
        let map = map(self.palette.as_ref(), self.font);
        let scheme = self.scheme;
        move |theme| {
            map(match scheme {
                Some(a) => theme.appearance(a),
                None => theme,
            })
        }
    }

    /// Watches each directory again, and stops watching those watched before, so a theme
    /// directory replaced since is watched for what it holds now.
    fn rewatch(&mut self) {
        let Some(w) = &mut self.watcher else {
            return;
        };
        let mut add = |dirs: Vec<PathBuf>| -> Vec<WatchId> {
            dirs.iter().filter_map(|d| w.add(d).ok()).collect()
        };
        let themes = add(theme_dirs(&self.home)
            .into_iter()
            .flat_map(|d| [d.parent().map(Path::to_owned), Some(d)])
            .flatten()
            .collect());
        let fonts = add(vec![
            self.fontconfig.clone(),
            self.fontconfig.join("conf.d"),
        ]);
        let old = [
            std::mem::replace(&mut self.themes, themes),
            std::mem::replace(&mut self.fonts, fonts),
        ];
        for id in old.into_iter().flatten() {
            let _ = w.remove(id);
        }
    }
}

/// Dresses the app's windows in the Omarchy theme, if one is active, and follows changes to
/// it and to Fontconfig once the app runs.
pub fn follow(app: &mut App<Strider>, look: &Follow) {
    if let Some(p) = &look.palette {
        app.desktop_theme(Some(omarchy_theme(p)));
    }
    app.map_desktop_theme(look.map());
    app.on_start(start);
}

/// Dresses the windows in what [`Follow`] holds now.
fn wear(s: &mut Strider, cx: &mut Cx<'_, Strider>) {
    let look = &s.look;
    cx.map_desktop_theme(look.map());
    cx.set_desktop_theme(Some(match &look.palette {
        Some(p) => omarchy_theme(p),
        None => Theme::default(),
    }));
}

fn start(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    s.look.watcher = DirWatcher::new(LATENCY).ok();
    s.look.rewatch();
    let Some(w) = &s.look.watcher else {
        return Ok(());
    };
    let fd = std::os::fd::AsFd::as_fd(w)
        .try_clone_to_owned()
        .map_err(keywork::Error::app)?;
    cx.watch_fd(fd, keywork::Interest::READABLE, |s: &mut Strider, cx, _| {
        if let Some(w) = &mut s.look.watcher {
            // A failed read leaves the events queued, and the descriptor readable.
            let _ = w.read(cx.now());
        }
        deliver(s, cx)
    })?;
    Ok(())
}

/// Reads what the watcher saw change, and arms a timer for its next batch.
fn deliver(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    let Some(w) = &mut s.look.watcher else {
        return Ok(());
    };
    let mut ids = Vec::new();
    w.take_changes(|id, _| ids.push(id));
    let deadline = w.deadline();
    let look = &mut s.look;
    let theme = ids.iter().any(|id| look.themes.contains(id));
    let fonts = ids.iter().any(|id| look.fonts.contains(id));
    if theme || fonts {
        look.rewatch();
    }
    // Between removing one theme and renaming the next in, there is none: the one worn
    // stays until the next reads.
    if theme
        && let Some(p) = Palette::read(&look.home)
        && look.palette.as_ref() != Some(&p)
    {
        look.palette = Some(p);
        wear(s, cx);
    }
    // On any window's lane: the font is everyone's.
    if fonts && let Some(window) = s.wins.first().map(|w| w.window) {
        cx.spawn_blocking(window, monospace, |s: &mut Strider, tx, font| {
            if font.is_some() && font != s.look.font {
                s.look.font = font;
                tx.defer(|s, cx| {
                    wear(s, cx);
                    Ok(())
                });
            }
            Ok(())
        });
    }
    if s.look.armed.map(|(d, _)| d) != deadline {
        if let Some((_, timer)) = s.look.armed.take() {
            cx.cancel_timer(timer);
        }
        if let Some(deadline) = deadline {
            let delay = deadline.saturating_duration_since(cx.now());
            let timer = cx.after(delay, |s: &mut Strider, cx| {
                s.look.armed = None;
                if let Some(w) = &mut s.look.watcher {
                    w.fire(cx.now());
                }
                deliver(s, cx)
            });
            s.look.armed = Some((deadline, timer));
        }
    }
    Ok(())
}

/// The family Fontconfig's configuration now makes `monospace`, then `monospace` itself for
/// characters it lacks; None without `fc-match`.
fn monospace() -> Option<&'static str> {
    let out = std::process::Command::new("fc-match")
        .args(["-f", "%{family[0]}", "monospace"])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let name = String::from_utf8(out.stdout).ok()?;
    let name = name.trim();
    (!name.is_empty()).then(|| keep_name(format!("{name}, monospace")))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use keywork::Color;
    use keywork::desktop::localtime::Zone;
    use keywork::theme::ColorScheme;
    use strider_core::config::Config;

    use super::*;

    const TOKYO_NIGHT: &str = include_str!("../../../tests/themes/tokyo-night/colors.toml");
    const LATTE: &str = include_str!("../../../tests/themes/catppuccin-latte/colors.toml");

    /// The theme a window gets from `base` on a desktop that prefers `desktop`, through
    /// `map`, as Keywork derives it.
    fn worn(palette: Option<&Palette>, desktop: DesktopAppearance) -> Theme {
        let base = palette.map_or_else(Theme::default, omarchy_theme);
        map(palette, None)(base.follow_desktop(&desktop))
    }

    fn prefers(color_scheme: ColorScheme) -> DesktopAppearance {
        DesktopAppearance {
            color_scheme,
            ..DesktopAppearance::default()
        }
    }

    // The colors the Zig build's goldens show under Tokyo Night and Catppuccin Latte: the
    // columns' backgrounds, folders in the accent, marks, executables, and the cursor's row,
    // Tokyo Night's own selection and Latte's tinted toward its accent until it shows on the
    // parent column. The theme's mode holds whatever the desktop prefers.
    #[test]
    fn omarchy_colors_reach_what_strider_wears() {
        let tokyo = Palette::parse(TOKYO_NIGHT, false);
        let t = worn(Some(&tokyo), prefers(ColorScheme::PreferLight));
        let at = |t: &Theme, p| t.color(p).to_srgba8();
        let hex = |c: u32| Color::hex(c).to_srgba8();
        assert_eq!(t.appearance, Appearance::Dark);
        for (paint, want) in [
            (Tone::Chrome.paint(), 0x13141c),
            (Tone::Parent.paint(), 0x0e0e14),
            (Tone::Current.paint(), 0x13141c),
            (Tone::Preview.paint(), 0x1a1b26),
            (Tone::Cursor.paint(), 0xc0caf5),
            (ColorRole::Text.paint(), 0xa9b1d6),
            (ColorRole::AccentText.paint(), 0x7aa2f7),
            (ColorRole::WarningText.paint(), 0xe0af68),
            (ColorRole::SuccessText.paint(), 0x9ece6a),
            (ColorRole::DangerText.paint(), 0xf7768e),
            (ColorRole::Selection.paint(), 0x292e42),
        ] {
            assert_eq!(at(&t, paint), hex(want), "{paint:?}");
        }
        let latte = Palette::parse(LATTE, false);
        let t = worn(Some(&latte), prefers(ColorScheme::PreferDark));
        assert_eq!(t.appearance, Appearance::Light);
        assert_eq!(at(&t, ColorRole::Selection.paint()), hex(0xbbc5dd));
        assert_eq!(at(&t, Tone::Parent.paint()), hex(0xd7d8dc));
        assert_eq!(at(&t, ColorRole::AccentText.paint()), hex(0x1e66f5));
    }

    // Without Omarchy the desktop decides light or dark and the accent; in higher contrast
    // the cursor's row is the solid accent, and an Omarchy theme gives way to Keywork's own
    // in its mode.
    #[test]
    fn the_desktop_decides_without_omarchy_and_in_higher_contrast() {
        let dark = DesktopAppearance {
            accent: Some(Color::hex(0x2f7d4f)),
            ..prefers(ColorScheme::PreferDark)
        };
        let t = worn(None, dark);
        assert_eq!(t.appearance, Appearance::Dark);
        assert_ne!(t.accent, Theme::default().accent, "the desktop's accent");
        assert_eq!(t.fonts.ui, FontFamily::Monospace);
        assert_eq!(
            t.color(Tone::Preview.paint()),
            t.color(ColorRole::Background.paint())
        );

        let high = DesktopAppearance {
            high_contrast: true,
            ..DesktopAppearance::default()
        };
        let tokyo = Palette::parse(TOKYO_NIGHT, false);
        let t = worn(Some(&tokyo), high);
        assert_eq!(t.appearance, Appearance::Dark);
        assert_eq!(
            t.color(ColorRole::Selection.paint()),
            t.color(ColorRole::AccentFill.paint())
        );
        assert_eq!(
            t.color(Tone::Cursor.paint()),
            t.color(ColorRole::OnAccent.paint())
        );
        assert_ne!(
            t.color(ColorRole::Text.paint()).to_srgba8(),
            Color::hex(0xa9b1d6).to_srgba8()
        );
    }

    // omarchy-theme-set swaps the theme directory: it removes the current one and renames
    // the next into its place. The window follows, dark to light.
    #[test]
    fn the_window_follows_an_omarchy_theme_switch() {
        let home = crate::scenes::fixture("omarchy-switch");
        let current = home.join(".local/state/omarchy/current");
        std::fs::create_dir_all(current.join("theme")).unwrap();
        std::fs::write(current.join("theme/colors.toml"), TOKYO_NIGHT).unwrap();
        let (app, state) = crate::app_in(
            home.join("work"),
            home.clone(),
            Config::default(),
            Zone::utc(),
            false,
            None,
        )
        .unwrap();
        let window = state.window;
        let mut h = app.headless(state).unwrap();
        h.settle().unwrap();
        let theme = |h: &mut keywork::app::Headless<Strider>| {
            h.update(window, |tx| Ok((*tx.theme(tx.root())?).clone()))
                .unwrap()
        };
        assert_eq!(theme(&mut h).appearance, Appearance::Dark);

        std::fs::create_dir_all(current.join("next")).unwrap();
        std::fs::write(current.join("next/colors.toml"), LATTE).unwrap();
        std::fs::remove_dir_all(current.join("theme")).unwrap();
        std::fs::rename(current.join("next"), current.join("theme")).unwrap();
        for _ in 0..40 {
            h.advance(Duration::from_millis(50)).unwrap();
            h.settle().unwrap();
            if theme(&mut h).appearance == Appearance::Light {
                break;
            }
        }
        let t = theme(&mut h);
        assert_eq!(t.appearance, Appearance::Light);
        assert_eq!(
            t.color(Tone::Preview.paint()).to_srgba8(),
            Color::hex(0xeff1f5).to_srgba8()
        );
        let _ = std::fs::remove_dir_all(&home);
    }
}
