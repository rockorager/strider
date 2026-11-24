//! Strider: a keyboard-driven file manager for Linux on Wayland.
//!
//!     strider [FOLDER or FILE ...] [--new-window] [--hidden] [--dark | --light]
//!
//! One instance serves every window: a second launch hands its folders to the first and
//! exits. A file on the command line is shown under the cursor in its folder.

mod app;
mod bookmarks;
mod cache;
mod columns;
mod commands;
mod dialogs;
mod drives;
mod folder;
mod instance;
mod menu;
mod opening;
mod ops;
mod picker;
mod preview;
mod prompt;
mod register;
mod scenes;
mod tabs;
mod tasks;
mod theme;

use std::path::PathBuf;
use std::sync::Arc;

use keywork::Launch;
use keywork::desktop::basedir::BaseDirs;
use keywork::desktop::localtime::Zone;
use keywork::desktop::mime::MimeDb;
use keywork::icons::MimeIcons;
use keywork::prelude::*;
use keywork::theme::Appearance;
use strider_core::config::Config;
use strider_core::keys::Keymap;

use app::{Col, Strider};

/// The app and its state, with `home` for `~`, the configuration given, and no window yet,
/// without running it; `scheme` is light or dark instead of the desktop's.
pub fn base(
    home: PathBuf,
    config: Config,
    zone: Zone,
    sync_reads: bool,
    state_dir: Option<PathBuf>,
    scheme: Option<Appearance>,
) -> Result<(App<Strider>, Strider)> {
    let mut app = App::<Strider>::new();
    // Names, sizes, and dates line up in a monospace face, as Fontconfig resolves the alias,
    // live, rather than in the desktop's sans-serif; colors are the desktop's or Omarchy's.
    let mut look = theme::Follow::new(&home);
    look.scheme = scheme;
    theme::follow(&mut app, &look);
    let mut keymap = Keymap::defaults();
    let problems = keymap.apply(&config);
    let db = Arc::new(MimeDb::load(&BaseDirs::from_env()));
    let mut state = Strider {
        options: config.options,
        keymap,
        home,
        zone,
        db,
        apps: None,
        icons: None,
        cache: cache::Cache::new(),
        sync_reads,
        lines: state_dir
            .as_deref()
            .map(strider_core::state::load_history)
            .unwrap_or_default(),
        widths: None,
        zoxide: picker::find_zoxide(),
        zoxide_last: PathBuf::new(),
        bookmarks: Vec::new(),
        drives: drives::Drives::default(),
        log: Vec::new(),
        ops: tasks::Ops::default(),
        look,
        state_dir,
        wins: Vec::new(),
        cur: 0,
        inputs: 0,
        config_message: problems.first().map(|p| format!("config.json: {p}")),
        launch: instance::Launch::default(),
    };
    for p in &problems {
        state.log_message(&format!("config.json: {p}"), true);
    }
    if let Some(dir) = state.state_dir.clone() {
        let (marks, skipped) = strider_core::state::load_bookmarks(&dir);
        state.bookmarks = marks;
        state.widths = strider_core::state::load_widths(&dir);
        for m in skipped {
            state.log_message(&m, true);
        }
    }
    app.on_icon_theme(load_icons);
    app.on_start(cache::start_watching);
    app.on_quit(tasks::quit);
    instance::install(&mut app);
    scenes::add(&mut app);
    Ok((app, state))
}

/// Builds the app with its window on `start`, with `home` for `~` and the configuration
/// given, without running it.
pub fn app_in(
    start: PathBuf,
    home: PathBuf,
    config: Config,
    zone: Zone,
    sync_reads: bool,
    state_dir: Option<PathBuf>,
) -> Result<(App<Strider>, Strider)> {
    let (mut app, mut state) = base(home, config, zone, sync_reads, state_dir, None)?;
    let window = app.open_window(app::window_desc())?;
    let ui = app.update(window, app::build)?;
    app::adopt(&mut state, window, ui, &start);
    app.update(window, |tx| app::show_start(&mut state, tx, start, None))?;
    Ok((app, state))
}

/// Loads the desktop's icon theme, when it is first known and whenever it changes, and draws
/// the rows again with its icons, in every window.
fn load_icons(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    // Without a window, the first to open loads it.
    let Some(window) = s.wins.first().map(|w| w.window) else {
        return Ok(());
    };
    let proxy = cx.proxy();
    let pool = cx.pool().clone();
    cx.load_icon_theme(window, move |s: &mut Strider, tx, theme| {
        s.icons = Some(MimeIcons::new(theme, pool, move || {
            let _ = proxy.post(receive_icons);
        }));
        app::others(tx, refresh_rows);
        if s.here(tx) {
            refresh_rows(s, tx)
        } else {
            Ok(())
        }
    });
    Ok(())
}

fn receive_icons(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    if s.icons.as_mut().is_some_and(MimeIcons::receive) {
        app::each(s, cx, refresh_rows)?;
    }
    Ok(())
}

fn refresh_rows(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    for col in [Col::Parent, Col::Current, Col::Preview] {
        keywork::widgets::refresh_rows(tx, s.ui.lists[col as usize])?;
    }
    Ok(())
}

const USAGE: &str = "usage: strider [FOLDER or FILE ...] [options]

  --new-window      open a new window even if one is open
  --hidden          show hidden files
  --dark, --light   choose the style instead of following the desktop
  --service         started by D-Bus activation
  --version         print the version

Keys: g? or F1 lists them; : opens the command line.
";

/// What the command line asks for.
#[derive(Debug, Default, PartialEq)]
struct Args {
    paths: Vec<String>,
    new_window: bool,
    service: bool,
    hidden: bool,
    scheme: Option<Appearance>,
}

/// Reads the command line, past the program's name: what it asks for, or what to print and
/// the status to exit with. Keywork's own flags, and the values of those that take one, are
/// left to Keywork.
fn parse_args(args: impl IntoIterator<Item = String>) -> std::result::Result<Args, (String, i32)> {
    let mut out = Args::default();
    let mut args = args.into_iter();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--hidden" => out.hidden = true,
            "--dark" => out.scheme = Some(Appearance::Dark),
            "--light" => out.scheme = Some(Appearance::Light),
            // Keywork lays out left to right only.
            "--rtl" => eprintln!("strider: --rtl is not supported; laying out left to right"),
            "--new-window" => out.new_window = true,
            "--service" | "--gapplication-service" => out.service = true,
            "--version" => {
                return Err((format!("strider {}\n", env!("CARGO_PKG_VERSION")), 0));
            }
            "--help" | "-h" => return Err((USAGE.to_owned(), 0)),
            _ if a.starts_with("--keywork-") => {
                if !a.contains('=') && a != "--keywork-list-scenes" {
                    args.next();
                }
            }
            _ if a.starts_with("--") => {
                return Err((format!("strider: unknown option {a}\n{USAGE}"), 2));
            }
            _ => out.paths.push(a),
        }
    }
    Ok(out)
}

fn main() -> Result<()> {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err((text, status)) => {
            if status == 0 {
                print!("{text}");
            } else {
                eprint!("{text}");
            }
            std::process::exit(status);
        }
    };
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
    let config_home =
        std::env::var_os("XDG_CONFIG_HOME").map_or_else(|| home.join(".config"), PathBuf::from);
    let (mut config, problems) =
        match std::fs::read_to_string(config_home.join("strider/config.json")) {
            Ok(text) => strider_core::config::parse(&text, &home),
            Err(_) => (Config::default(), Vec::new()),
        };
    for p in &problems {
        eprintln!("strider: config.json: {p}");
    }
    if args.hidden {
        config.options.show_hidden = true;
    }
    let state_dir = std::env::var_os("XDG_STATE_HOME")
        .map_or_else(|| home.join(".local/state"), PathBuf::from)
        .join("strider");
    let (mut app, mut state) = base(
        home,
        config,
        Zone::local(),
        false,
        Some(state_dir),
        args.scheme,
    )?;
    state.launch.new_window = args.new_window;
    state.launch.service = args.service;
    // Settled before any window maps: a second launch hands its folders over and exits.
    let uris = instance::uris(&args.paths);
    match app.launch(instance::APP_ID, uris.clone()) {
        Ok(Launch::First) => {}
        Ok(Launch::Forwarded) => return Ok(()),
        Err(e) => {
            eprintln!("strider: the session bus: {e}; this instance serves no other");
            instance::alone(&mut app, uris);
        }
    }
    app.on_start(drives::start_watching);
    app.run(state)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use strider_machines::mode;

    use super::*;
    use strider_machines::keymap::keymap::states;

    // Keys travel the whole way a user's do: a key event through the keymap statechart, the
    // which-key timer on the loop, and the command it ends in. "g" waits for its second key
    // and shows the hints only once which_key_delay has passed; "h" then goes home. A count
    // reaches the command: "2j" moves two down. Escape in the middle of a sequence drops it
    // without running the escape command, which would clear the marks.
    #[test]
    fn keys_reach_commands_through_the_keymap() {
        let home = scenes::fixture("keys");
        let (app, state) = app_in(
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
        let press = |h: &mut keywork::app::Headless<Strider>, c: char| {
            h.key(window, Keysym::from_char(c), Modifiers::NONE)
                .unwrap();
            h.settle().unwrap();
        };

        press(&mut h, '2');
        press(&mut h, 'j');
        assert_eq!(h.state().cur().cursor, 2);
        assert_eq!(h.state().cur().name(2), b"src");

        press(&mut h, ' ');
        assert_eq!(h.state().cur().marks.len(), 1);
        press(&mut h, 'g');
        h.key(window, Keysym::ESCAPE, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        assert!(h.state().keys.matches(states::IDLE));
        assert_eq!(
            h.state().cur().marks.len(),
            1,
            "Escape ended the sequence, and ran nothing"
        );

        press(&mut h, 'g');
        assert!(h.state().keys.matches(states::pending::WAITING));
        h.advance(Duration::from_millis(299)).unwrap();
        assert!(h.state().keys.matches(states::pending::WAITING));
        h.advance(Duration::from_millis(2)).unwrap();
        assert!(h.state().keys.matches(states::pending::HINTING));
        press(&mut h, 'h');
        assert!(h.state().keys.matches(states::IDLE));
        assert_eq!(h.state().cur().path, home);
        let _ = std::fs::remove_dir_all(&home);
    }

    // Folders are read on a worker and watched: a file made in the folder shown appears once
    // the watcher's batch is in, with the cursor kept on its entry; back in a folder left, the
    // cursor is where it was.
    #[test]
    fn folders_follow_changes_and_keep_their_cursors() {
        let home = scenes::fixture("watch");
        let work = home.join("work");
        let (app, state) = app_in(
            work.clone(),
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
        assert!(h.state().cur().loaded);
        let press = |h: &mut keywork::app::Headless<Strider>, c: char| {
            h.key(window, Keysym::from_char(c), Modifiers::NONE)
                .unwrap();
            h.settle().unwrap();
        };
        // On "build.zig", the sixth entry.
        for _ in 0..5 {
            press(&mut h, 'j');
        }
        assert_eq!(h.state().cur().current_name(), Some(&b"build.zig"[..]));

        // "aaa.txt" sorts before it, after "a-very-long-…" ('-' is before 'a').
        std::fs::write(work.join("aaa.txt"), "new").unwrap();
        for _ in 0..10 {
            h.advance(Duration::from_millis(50)).unwrap();
            h.settle().unwrap();
            if h.state().cur().position_of(b"aaa.txt").is_some() {
                break;
            }
        }
        assert_eq!(h.state().cur().position_of(b"aaa.txt"), Some(4));
        assert_eq!(h.state().cur().current_name(), Some(&b"build.zig"[..]));

        // Into src, onto main.zig, out and in again: the cursor is still on main.zig.
        press(&mut h, 'g');
        press(&mut h, 'g');
        press(&mut h, 'j');
        press(&mut h, 'j');
        press(&mut h, 'l');
        assert_eq!(h.state().cwd, work.join("src"));
        press(&mut h, 'G');
        assert_eq!(h.state().cur().current_name(), Some(&b"main.zig"[..]));
        press(&mut h, 'h');
        assert_eq!(h.state().cwd, work);
        assert_eq!(h.state().cur().current_name(), Some(&b"src"[..]));
        press(&mut h, 'l');
        assert_eq!(h.state().cur().current_name(), Some(&b"main.zig"[..]));
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Types `text` as keys, Enter for `\n`, Tab for `\t`, Escape for `\x1b`, and
    /// Backspace for `\x08`, letting each key's work finish. A character goes into an open
    /// prompt as typed text, which a key event without text does not carry.
    fn typ(h: &mut keywork::app::Headless<Strider>, window: WindowId, text: &str) {
        for c in text.chars() {
            // The window's own prompt, not the one handlers last acted on.
            let open = h
                .state()
                .wins
                .iter()
                .find(|w| w.window == window)
                .is_some_and(|w| w.mode.matches(mode::mode::states::line::OPEN));
            if open && !c.is_control() {
                h.perform(window, &keywork::app::tooling::Action::Type(c.to_string()))
                    .unwrap();
                h.settle().unwrap();
                continue;
            }
            let sym = match c {
                '\n' => Keysym::RETURN,
                '\t' => Keysym::TAB,
                '\x1b' => Keysym::ESCAPE,
                '\x08' => Keysym::BACKSPACE,
                c => Keysym::from_char(c),
            };
            h.key(window, sym, Modifiers::NONE).unwrap();
            h.settle().unwrap();
        }
    }

    fn line(h: &mut keywork::app::Headless<Strider>, window: WindowId) -> String {
        let editor = h.state().ui.line_editor;
        h.update(window, |tx| Ok(tx.editor_text(editor)?.to_string()))
            .unwrap()
    }

    // The prompts, typed as a user types them, as the Zig build's tests did: zf filters
    // as you type and Enter keeps it, / searches in what it shows, Escape takes it off; f
    // jumps to the only match; :set and :cd complete with Tab, Up recalls the line, and :cd
    // to a file shows it in its folder.
    #[test]
    fn prompts_filter_search_find_and_complete() {
        let home = scenes::fixture("prompts");
        let work = home.join("work");
        let (app, state) = app_in(
            work.clone(),
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
        let all = h.state().cur().len();
        let hovered = |h: &keywork::app::Headless<Strider>| {
            String::from_utf8_lossy(h.state().cur().current_name().unwrap_or(b"")).into_owned()
        };
        let message = |h: &keywork::app::Headless<Strider>| {
            h.state()
                .message
                .as_ref()
                .map(|m| m.0.clone())
                .unwrap_or_default()
        };

        typ(&mut h, window, "zfre");
        assert_eq!(h.state().prompt(), Some(mode::Prompt::Filter));
        assert_eq!(h.state().cur().len(), 2);
        assert_eq!(hovered(&h), "README.md");
        // A capital letter matches its case only.
        typ(&mut h, window, "\x08\x08RE");
        assert_eq!(h.state().cur().len(), 1);
        // Enter keeps the filter, and keys work on what it shows.
        typ(&mut h, window, "\n");
        assert_eq!(h.state().prompt(), None);
        assert_eq!(h.state().cur().filter, "RE");
        typ(&mut h, window, "/run\n");
        assert_eq!(message(&h), "No match");
        // Escape takes it off.
        typ(&mut h, window, "\x1b");
        assert_eq!(h.state().cur().len(), all);
        typ(&mut h, window, "/run\n");
        assert_eq!(hovered(&h), "run.sh");
        // n wraps around to the same, the only match.
        typ(&mut h, window, "ggn");
        assert_eq!(hovered(&h), "run.sh");
        // Escape in the prompt cancels it, back to every entry.
        typ(&mut h, window, "zfzzz");
        assert_eq!(h.state().cur().len(), 0);
        typ(&mut h, window, "\x1b");
        assert_eq!(h.state().cur().len(), all);
        assert_eq!(hovered(&h), "run.sh");
        // A search cancelled goes back where it started.
        typ(&mut h, window, "gg/doc");
        assert_eq!(hovered(&h), "docs");
        typ(&mut h, window, "\x1b");
        assert_eq!(hovered(&h), "assets");

        // f jumps to the only match without Enter; with find_auto_accept off, Enter closes.
        typ(&mut h, window, "fph");
        assert_eq!(hovered(&h), "photo.png");
        assert_eq!(h.state().prompt(), None);
        typ(&mut h, window, ":set nofind_auto_accept\nfRE");
        assert_eq!(hovered(&h), "README.md");
        assert_eq!(h.state().prompt(), Some(mode::Prompt::Find));
        typ(&mut h, window, "\n");
        assert_eq!(h.state().prompt(), None);

        // :set with Tab completion.
        typ(&mut h, window, ":set\t");
        assert_eq!(line(&mut h, window), "set ");
        typ(&mut h, window, "hid\t");
        assert_eq!(line(&mut h, window), "set hidden ");
        typ(&mut h, window, "\n");
        assert!(h.state().options.show_hidden);
        assert!(h.state().cur().position_of(b".hidden").is_some());
        // Paths complete too, and Up recalls the line.
        typ(&mut h, window, ":cd ../Mu\t");
        assert_eq!(line(&mut h, window), "cd ../Music/");
        typ(&mut h, window, "\n");
        assert_eq!(h.state().cwd, home.join("Music"));
        typ(&mut h, window, ":");
        h.key(window, Keysym::UP, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        assert_eq!(line(&mut h, window), "cd ../Music/");
        typ(&mut h, window, "\x1b:frobnicate\n");
        assert_eq!(message(&h), "Unknown command: frobnicate");
        // A file goes to its folder with the cursor on it; nowhere says so.
        typ(&mut h, window, ":cd ../work/README.md\n");
        assert_eq!(h.state().cwd, work);
        assert_eq!(hovered(&h), "README.md");
        typ(&mut h, window, ":cd nowhere\n");
        assert!(message(&h).ends_with("/work/nowhere"), "{}", message(&h));

        // A prompt opened in visual mode leaves the range alone, for Escape to mark.
        typ(&mut h, window, "ggVj:\x1b");
        assert!(h.state().visual());
        assert!(h.state().cur().marks.is_empty());
        typ(&mut h, window, "\x1b");
        assert!(!h.state().visual());
        assert_eq!(h.state().cur().marks.len(), 2);
        let _ = std::fs::remove_dir_all(&home);
    }

    // As the Zig build's test: gf finds files below, best first, and Enter shows a file in its
    // folder or opens a folder; Ctrl+N and Ctrl+P move; gz and :z ask a stand-in zoxide, which
    // hears of each folder shown.
    #[test]
    fn picker_and_zoxide() {
        use std::os::unix::fs::PermissionsExt;
        let home = scenes::fixture("picker");
        let h_ = home.display();
        std::fs::create_dir_all(home.join("bin")).unwrap();
        let script = format!(
            r#"#!/bin/sh
case "$1" in
add) echo "$3" >> "{h_}/zoxide.log" ;;
query) if [ "$2" = "--list" ]; then printf '%s\n' "{h_}/Music" "{h_}/Documents" "{h_}/work/docs"
  else for a; do last=$a; done; case "$last" in doc*) echo "{h_}/work/docs" ;; *) exit 1 ;; esac; fi ;;
esac
"#
        );
        let zoxide = home.join("bin/zoxide");
        std::fs::write(&zoxide, script).unwrap();
        std::fs::set_permissions(&zoxide, std::fs::Permissions::from_mode(0o755)).unwrap();
        let (app, mut state) = app_in(
            home.join("work"),
            home.clone(),
            Config::default(),
            Zone::utc(),
            false,
            None,
        )
        .unwrap();
        state.zoxide = Some(zoxide);
        let window = state.window;
        let mut h = app.headless(state).unwrap();
        h.settle().unwrap();
        let ctrl = |h: &mut keywork::app::Headless<Strider>, c: char| {
            h.key(window, Keysym::from_char(c), Modifiers::CTRL)
                .unwrap();
            h.settle().unwrap();
        };
        let hovered = |h: &keywork::app::Headless<Strider>| {
            String::from_utf8_lossy(h.state().cur().current_name().unwrap_or(b"")).into_owned()
        };

        typ(&mut h, window, "gf");
        assert_eq!(h.state().prompt(), Some(mode::Prompt::Pick));
        // The walk runs on its thread; settle until it is in.
        for _ in 0..100 {
            if h.state().picker.paths.len() >= 12 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            h.settle().unwrap();
        }
        assert!(h.state().picker.paths.len() >= 12);
        typ(&mut h, window, "mainz");
        let p = &h.state().picker;
        assert_eq!(p.paths.get(p.matches[0].index), b"src/main.zig");
        typ(&mut h, window, "\n");
        assert_eq!(h.state().prompt(), None);
        assert_eq!(h.state().cwd, home.join("work/src"));
        assert_eq!(hovered(&h), "main.zig");

        typ(&mut h, window, "hgf");
        for _ in 0..100 {
            if !h.state().picker.paths.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            h.settle().unwrap();
        }
        typ(&mut h, window, "util");
        assert!(
            h.state()
                .picker
                .chosen()
                .unwrap()
                .ends_with("/work/src/util/")
        );
        typ(&mut h, window, "\n");
        assert_eq!(h.state().cwd, home.join("work/src/util"));

        typ(&mut h, window, "hhgfzig");
        ctrl(&mut h, 'n');
        ctrl(&mut h, 'n');
        ctrl(&mut h, 'p');
        assert_eq!(h.state().picker.selected, 1);
        typ(&mut h, window, "\x1b");
        assert_eq!(h.state().prompt(), None);

        let log = std::fs::read_to_string(home.join("zoxide.log")).unwrap_or_default();
        assert!(log.contains("/work/src\n"), "{log}");
        assert!(log.contains("/work/src/util\n"), "{log}");

        typ(&mut h, window, "gz");
        for _ in 0..200 {
            if h.state().picker.paths.len() == 3 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            h.settle().unwrap();
        }
        assert_eq!(h.state().picker.paths.len(), 3);
        typ(&mut h, window, "mus\n");
        assert_eq!(h.state().cwd, home.join("Music"));
        typ(&mut h, window, ":z doc\n");
        for _ in 0..200 {
            if h.state().cwd == home.join("work/docs") {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            h.settle().unwrap();
        }
        assert_eq!(h.state().cwd, home.join("work/docs"));
        typ(&mut h, window, ":z nothing\n");
        for _ in 0..200 {
            if h.state().message.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            h.settle().unwrap();
        }
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("zoxide knows no folder for that")
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // m and a key bookmarks the folder; ' shows the bookmarks after the delay, and the key
    // goes there; '' goes back; dm removes one.
    #[test]
    fn bookmarks() {
        let home = scenes::fixture("bookmarks");
        let (app, state) = app_in(
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
        typ(&mut h, window, "ma");
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("Bookmark 'a' set")
        );
        typ(&mut h, window, "ggjjl");
        assert_eq!(h.state().cwd, home.join("work/src"));
        typ(&mut h, window, "'");
        assert!(h.state().keys.context().question.is_some());
        h.advance(Duration::from_millis(301)).unwrap();
        let popup = h.state().ui.which_key;
        assert!(!h.update(window, |tx| tx.is_hidden(popup)).unwrap());
        typ(&mut h, window, "a");
        assert_eq!(h.state().cwd, home.join("work"));
        typ(&mut h, window, "''");
        assert_eq!(h.state().cwd, home.join("work/src"));
        typ(&mut h, window, "dma");
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("Bookmark removed")
        );
        typ(&mut h, window, "'a");
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("No such bookmark")
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // As the Zig build's test: gn opens a tab where the window is, gt and Alt+2 switch, each
    // tab keeps its folder and history, a bookmark works across them, and gq closes one.
    // Then sorting by size and hidden files, the cursor kept on its entry.
    #[test]
    fn tabs_sorting_and_hidden_files() {
        let home = scenes::fixture("tabs");
        let work = home.join("work");
        let (app, state) = app_in(
            work.clone(),
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
        let hovered = |h: &keywork::app::Headless<Strider>| {
            String::from_utf8_lossy(h.state().cur().current_name().unwrap_or(b"")).into_owned()
        };
        typ(&mut h, window, "magn");
        assert_eq!(h.state().tabs.len(), 2);
        assert_eq!(h.state().active, 1);
        typ(&mut h, window, "ggjjl");
        assert_eq!(h.state().cwd, work.join("src"));
        typ(&mut h, window, "gt");
        assert_eq!(h.state().active, 0);
        assert_eq!(h.state().cwd, work);
        h.key(window, Keysym::from_char('2'), Modifiers::ALT)
            .unwrap();
        h.settle().unwrap();
        assert_eq!(h.state().cwd, work.join("src"));
        // The second tab's history: back goes to where it started.
        typ(&mut h, window, "H");
        assert_eq!(h.state().cwd, work);
        typ(&mut h, window, "L'a");
        assert_eq!(h.state().cwd, work);
        typ(&mut h, window, "''");
        assert_eq!(h.state().cwd, work.join("src"));
        typ(&mut h, window, "gq");
        assert_eq!(h.state().tabs.len(), 1);
        assert_eq!(h.state().cwd, work);

        // Sorting by size, largest first, folders still first.
        typ(&mut h, window, "sS");
        assert_eq!(
            h.state().options.sort.key,
            strider_core::options::SortKey::Size
        );
        typ(&mut h, window, "gg3j");
        assert_eq!(hovered(&h), "report.pdf");
        typ(&mut h, window, "sn");
        // zh shows hidden files; the cursor stays on its entry.
        typ(&mut h, window, "zh");
        assert!(h.state().cur().position_of(b".hidden").is_some());
        assert_eq!(hovered(&h), "report.pdf");
        typ(&mut h, window, "zh");
        assert!(h.state().cur().position_of(b".hidden").is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

    // As the Zig build's test: dragging a handle, < and > with counts, column-narrower parent,
    // the 80 px least, a narrow window dropping the parent and the widths coming back, the
    // widths kept for the next start, and z= forgetting them.
    #[test]
    fn column_handles_and_widths() {
        use keywork::input::BTN_LEFT;
        let home = scenes::fixture("resize");
        let state_dir = home.join(".local/state/strider");
        let start = |home: &std::path::Path| {
            let (app, state) = app_in(
                home.join("work/src"),
                home.to_owned(),
                Config::default(),
                Zone::utc(),
                false,
                Some(home.join(".local/state/strider")),
            )
            .unwrap();
            let window = state.window;
            let mut h = app.headless(state).unwrap();
            h.settle().unwrap();
            (h, window)
        };
        let width = |h: &mut keywork::app::Headless<Strider>, window, col: Col| {
            let pane = h.state().ui.panes[col as usize];
            h.render(window).unwrap();
            h.update(window, |tx| Ok(tx.rect(pane)?.width)).unwrap()
        };
        let line = |h: &mut keywork::app::Headless<Strider>, window, which: usize| {
            let line = h.state().ui.handles[which].1;
            h.render(window).unwrap();
            h.update(window, |tx| Ok(tx.rect(line)?.width)).unwrap()
        };
        let drag = |h: &mut keywork::app::Headless<Strider>, window, which: usize, dx: f32| {
            let node = h.state().ui.handles[which].0;
            h.render(window).unwrap();
            let r = h.update(window, |tx| tx.rect(node)).unwrap();
            let (x, y) = (r.x + r.width / 2.0, r.y + 200.0);
            h.pointer_move(window, x, y).unwrap();
            h.settle().unwrap();
            h.pointer_button(window, BTN_LEFT, true).unwrap();
            for k in 1..5 {
                h.pointer_move(window, x + dx * k as f32 / 4.0, y).unwrap();
            }
            h.settle().unwrap();
            h.pointer_button(window, BTN_LEFT, false).unwrap();
            h.settle().unwrap();
        };
        let near = |a: f32, b: f32| (a - b).abs() <= 1.0;

        let (mut h, window) = start(&home);
        // Fitted: a quarter for work's long names, 3/8 for the current.
        assert_eq!(width(&mut h, window, Col::Parent), 250.0);
        assert_eq!(width(&mut h, window, Col::Current), 375.0);
        // The pointer over a handle lights its line.
        let node = h.state().ui.handles[1].0;
        h.render(window).unwrap();
        let r = h.update(window, |tx| tx.rect(node)).unwrap();
        h.pointer_move(window, r.x + 3.0, 300.0).unwrap();
        h.settle().unwrap();
        assert_eq!(line(&mut h, window, 1), 2.0);
        // Dragging the first boundary 60 px right widens the parent; the current column's far
        // edge stays.
        drag(&mut h, window, 0, 60.0);
        assert!(near(width(&mut h, window, Col::Parent), 310.0));
        assert!(near(width(&mut h, window, Col::Current), 315.0));
        assert_eq!(line(&mut h, window, 0), 2.0);
        h.pointer_move(window, 900.0, 300.0).unwrap();
        h.settle().unwrap();
        assert_eq!(line(&mut h, window, 0), 1.0);
        // The second boundary takes from the preview.
        drag(&mut h, window, 1, -40.0);
        assert!(near(width(&mut h, window, Col::Current), 275.0));
        assert!(near(width(&mut h, window, Col::Parent), 310.0));
        // > and < by 32 px, with counts; a column keeps 80 px.
        typ(&mut h, window, ">");
        assert!(near(width(&mut h, window, Col::Current), 307.0));
        typ(&mut h, window, "2<");
        assert!(near(width(&mut h, window, Col::Current), 243.0));
        typ(&mut h, window, ":column-narrower parent\n");
        assert!(near(width(&mut h, window, Col::Parent), 278.0));
        typ(&mut h, window, "20<");
        assert!(near(width(&mut h, window, Col::Current), 80.0));
        typ(&mut h, window, "5>");
        assert!(near(width(&mut h, window, Col::Current), 240.0));
        // A narrow window still drops the parent, and the widths come back.
        h.resize(window, 600, 560, 1.0).unwrap();
        h.render(window).unwrap();
        h.settle().unwrap();
        let parent = h.state().ui.panes[0];
        assert!(h.update(window, |tx| tx.is_hidden(parent)).unwrap());
        h.resize(window, 1000, 560, 1.0).unwrap();
        h.settle().unwrap();
        assert!(near(width(&mut h, window, Col::Parent), 278.0));
        assert_eq!(
            std::fs::read_to_string(state_dir.join("columns")).unwrap(),
            "0.2780 0.2400\n"
        );
        drop(h);

        // The next start keeps them; z= goes back to the ratio and forgets them.
        let (mut h, window) = start(&home);
        assert!(near(width(&mut h, window, Col::Parent), 278.0));
        assert!(near(width(&mut h, window, Col::Current), 240.0));
        typ(&mut h, window, "z=");
        assert_eq!(width(&mut h, window, Col::Parent), 250.0);
        assert_eq!(width(&mut h, window, Col::Current), 375.0);
        assert!(!state_dir.join("columns").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    // Opening and commands, without starting what is installed: l on a text file starts the
    // sample home's default application for it (a script that writes down its arguments),
    // detached; ! runs a shell command on the target, its last line in the status line, all
    // of it in the preview, and keeps it in the history as "shell …"; bulk-rename renames
    // as the editor (sed, here) leaves the list.
    #[test]
    fn opening_files_and_running_commands() {
        use std::os::unix::fs::PermissionsExt;
        let home = scenes::fixture("opening");
        let work = home.join("work");
        std::fs::write(work.join("todo.txt"), "hello\n").unwrap();
        let opener = home.join("fake-open");
        let opened = home.join("opened");
        std::fs::write(
            &opener,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" > {}.tmp\nmv {0}.tmp {0}\n",
                opened.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&opener, std::fs::Permissions::from_mode(0o755)).unwrap();
        let apps = home.join(".local/share/applications");
        std::fs::create_dir_all(&apps).unwrap();
        std::fs::write(
            apps.join("fake.desktop"),
            format!(
                "[Desktop Entry]\nType=Application\nName=Fake\nExec={} %F\nMimeType=text/plain;application/octet-stream;\n",
                opener.display()
            ),
        )
        .unwrap();
        std::fs::create_dir_all(home.join(".config")).unwrap();
        std::fs::write(
            home.join(".config/mimeapps.list"),
            "[Default Applications]\ntext/plain=fake.desktop;\napplication/octet-stream=fake.desktop;\n",
        )
        .unwrap();
        let (app, state) = app_in(
            work.clone(),
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

        typ(&mut h, window, ":cd todo.txt\nl");
        assert_eq!(h.state().cur().current_name(), Some(&b"todo.txt"[..]));
        for _ in 0..100 {
            if opened.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let args = std::fs::read_to_string(&opened).expect("the default application started");
        assert_eq!(args.trim_end(), work.join("todo.txt").display().to_string());

        typ(&mut h, window, "!cat %f; echo done\n");
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("done")
        );
        assert!(matches!(h.state().preview, preview::Preview::Output { .. }));
        assert_eq!(
            h.state().lines.last().map(String::as_str),
            Some("shell cat %f; echo done")
        );

        h.state_mut().options.editor = "sed -i s/todo/done/".into();
        h.state_mut().options.editor_in_terminal = false;
        typ(&mut h, window, ":bulk-rename\n");
        for _ in 0..100 {
            h.settle().unwrap();
            if work.join("done.txt").exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(work.join("done.txt").exists() && !work.join("todo.txt").exists());
        assert_eq!(
            h.state().message.as_ref().map(|m| m.0.as_str()),
            Some("Renamed 1 items")
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // --- File operations, as the Zig build's tests drove them -------------------------------

    type H = keywork::app::Headless<Strider>;

    /// The app on a fresh sample home, in `work`, settled.
    fn ops_app(name: &str) -> (H, WindowId, PathBuf) {
        ops_app_with(name, |_| {})
    }

    /// The same, with `prepare` run on the home before the app reads it.
    fn ops_app_with(name: &str, prepare: impl FnOnce(&std::path::Path)) -> (H, WindowId, PathBuf) {
        let home = scenes::fixture(name);
        prepare(&home);
        let (app, state) = app_in(
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
        (h, window, home)
    }

    /// Lets the jobs run until each is done, asking, or paused, taking their updates.
    fn wait_ops(h: &mut H) {
        for _ in 0..3000 {
            h.settle().unwrap();
            let s = h.state();
            if s.ops.jobs.iter().all(|r| {
                r.job.is_paused() || r.job.state() == ops::State::Asking && !s.ops.asks.is_empty()
            }) {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("the file operations did not finish");
    }

    fn hovered(h: &H) -> String {
        String::from_utf8_lossy(h.state().cur().current_name().unwrap_or(b"")).into_owned()
    }

    fn message(h: &H) -> String {
        h.state()
            .message
            .as_ref()
            .map(|m| m.0.clone())
            .unwrap_or_default()
    }

    fn dialog_is(h: &H, f: fn(&dialogs::Dialog) -> bool) -> bool {
        h.state().wops.dialog.as_ref().is_some_and(f)
    }

    fn mode_of(p: &std::path::Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).unwrap().permissions().mode() & 0o7777
    }

    // Marks, yy into the register and onto the clipboard, p pasting the copies; a visual
    // range cut with d and pasted where one of its files is: two items, so a dialog compares
    // the two, a ticks "every conflict" and k keeps both. dT trashes and u restores; dD asks
    // in a dialog whose keys never reach the columns, c and Escape keep the file, d deletes it.
    // Catches: the register or the clipboard not set, a paste going nowhere, conflicts never
    // asked, undo not recorded, a delete without asking.
    #[test]
    fn copy_cut_paste_trash_undo_delete() {
        let (mut h, window, home) = ops_app("ops");
        let work = home.join("work");
        // Nothing yet.
        typ(&mut h, window, "p");
        assert_eq!(message(&h), "Nothing to paste");
        typ(&mut h, window, "fbu  ");
        assert_eq!(h.state().cur().marks.len(), 2);
        assert_eq!(hovered(&h), "README.md");
        typ(&mut h, window, "yy");
        assert!(h.state().cur().marks.is_empty());
        assert_eq!(h.state().ops.register.len(), 2);
        assert_eq!(message(&h), "Copied 2 items");
        let gnome = h.clipboard_data("x-special/gnome-copied-files").unwrap();
        let gnome = String::from_utf8(gnome).unwrap();
        assert!(gnome.starts_with("copy\nfile://"), "{gnome}");
        assert!(h.clipboard_data("text/uri-list").is_some());
        typ(&mut h, window, "ggjl");
        assert_eq!(h.state().cwd, work.join("docs"));
        typ(&mut h, window, "p");
        wait_ops(&mut h);
        assert!(work.join("docs/build.zig").exists() && work.join("docs/photo.png").exists());
        assert!(work.join("build.zig").exists());
        assert_eq!(message(&h), "Copied 2 items");
        // The cursor on the first thing the paste brought.
        assert_eq!(hovered(&h), "build.zig");

        typ(&mut h, window, "ggjvj");
        assert!(h.state().visual());
        assert_eq!(app::targets(h.state()).len(), 2);
        typ(&mut h, window, "d");
        assert!(!h.state().visual());
        assert!(h.state().ops.cut);
        typ(&mut h, window, "hp");
        wait_ops(&mut h);
        assert!(dialog_is(&h, dialogs::Dialog::is_conflict));
        typ(&mut h, window, "ak");
        assert!(h.state().wops.dialog.is_none());
        wait_ops(&mut h);
        assert!(work.join("guide.md").exists());
        assert!(work.join("photo (2).png").exists());
        assert!(!work.join("docs/guide.md").exists());
        assert_eq!(std::fs::read_dir(work.join("docs")).unwrap().count(), 1);
        // A cut is pasted once.
        assert!(h.state().ops.register.is_empty());

        let trashed = home.join(".local/share/Trash/files/guide.md");
        typ(&mut h, window, "fgudT");
        wait_ops(&mut h);
        assert!(!work.join("guide.md").exists() && trashed.exists());
        typ(&mut h, window, "u");
        wait_ops(&mut h);
        assert!(work.join("guide.md").exists() && !trashed.exists());

        typ(&mut h, window, "fgudD");
        assert!(dialog_is(&h, dialogs::Dialog::is_delete));
        typ(&mut h, window, "jc");
        assert!(h.state().wops.dialog.is_none());
        assert_eq!(message(&h), "Not deleted");
        assert_eq!(hovered(&h), "guide.md");
        typ(&mut h, window, "dD\x1b");
        assert!(work.join("guide.md").exists());
        typ(&mut h, window, "dDd");
        wait_ops(&mut h);
        assert!(!work.join("guide.md").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    // Visual operators act at once and leave visual mode; their second key finishes the
    // two-key form (vdd, vyy) instead of starting another; after vd, T trashes and D deletes
    // the range rather than cutting it. Delete trashes; Shift+Delete asks, out of visual mode
    // with the range marked; Enter in the dialog presses Cancel, Tab and Enter Delete.
    // Catches: the second key running a command of its own, vdT moving nothing or leaving the
    // register full, Enter deleting.
    #[test]
    fn visual_operators_and_their_second_keys() {
        let (mut h, window, home) = ops_app("visual-ops");
        let work = home.join("work");
        let trash = home.join(".local/share/Trash/files");
        typ(&mut h, window, "fbavjD");
        wait_ops(&mut h);
        assert!(!h.state().visual());
        assert!(trash.join("backup.tar.gz").exists() && trash.join("build.zig").exists());
        typ(&mut h, window, "u");
        wait_ops(&mut h);
        assert!(work.join("backup.tar.gz").exists() && work.join("build.zig").exists());

        typ(&mut h, window, "fbavjd");
        assert!(!h.state().visual());
        assert!(h.state().ops.cut && h.state().ops.register.len() == 2);
        typ(&mut h, window, "ggjlp");
        wait_ops(&mut h);
        assert!(work.join("docs/backup.tar.gz").exists() && !work.join("build.zig").exists());

        typ(&mut h, window, "hfphvdd");
        assert!(h.state().keys.context().pending.is_empty());
        assert!(h.state().ops.cut && h.state().ops.register.len() == 1);
        assert!(work.join("photo.png").exists());
        typ(&mut h, window, "vdT");
        wait_ops(&mut h);
        assert!(!work.join("photo.png").exists() && trash.join("photo.png").exists());
        assert!(h.state().ops.register.is_empty());

        typ(&mut h, window, "fRvdD");
        assert!(dialog_is(&h, dialogs::Dialog::is_delete));
        typ(&mut h, window, "d");
        wait_ops(&mut h);
        assert!(!work.join("README.md").exists());

        typ(&mut h, window, "fre");
        assert_eq!(hovered(&h), "report.pdf");
        h.key(window, Keysym::DELETE, Modifiers::NONE).unwrap();
        wait_ops(&mut h);
        assert!(trash.join("report.pdf").exists());

        typ(&mut h, window, "fshv");
        h.key(window, Keysym::DELETE, Modifiers::SHIFT).unwrap();
        h.settle().unwrap();
        assert!(dialog_is(&h, dialogs::Dialog::is_delete));
        assert!(!h.state().visual());
        typ(&mut h, window, "c");
        assert!(work.join("run.sh").exists());
        assert_eq!(h.state().cur().marks.len(), 1);
        typ(&mut h, window, "\x1b");
        typ(&mut h, window, "dD");
        h.key(window, Keysym::RETURN, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        assert!(h.state().wops.dialog.is_none());
        assert_eq!(message(&h), "Not deleted");
        typ(&mut h, window, "dD");
        h.key(window, Keysym::TAB, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        h.key(window, Keysym::RETURN, Modifiers::NONE).unwrap();
        wait_ops(&mut h);
        assert!(h.state().wops.dialog.is_none() && !work.join("run.sh").exists());
        let _ = std::fs::remove_dir_all(&home);
    }

    // r selects the name without its extension, so typing replaces it; u undoes the rename;
    // a makes a file, or with a trailing slash folders, the cursor on what it made, and u
    // undoes that too. Catches: the caret or selection in the wrong place, renames or new
    // files not recorded for undo, the cursor left behind.
    #[test]
    fn rename_and_create() {
        let (mut h, window, home) = ops_app("rename");
        let work = home.join("work");
        typ(&mut h, window, "fbur");
        assert_eq!(h.state().prompt(), Some(mode::Prompt::Rename));
        assert_eq!(line(&mut h, window), "build.zig");
        typ(&mut h, window, "make\n");
        assert!(work.join("make.zig").exists());
        assert_eq!(hovered(&h), "make.zig");
        typ(&mut h, window, "u");
        assert!(work.join("build.zig").exists() && !work.join("make.zig").exists());
        assert_eq!(message(&h), "Undid the rename");
        typ(&mut h, window, "anew.txt\n");
        assert!(work.join("new.txt").is_file());
        assert_eq!(hovered(&h), "new.txt");
        typ(&mut h, window, "adeep/er/\n");
        assert!(work.join("deep/er").is_dir());
        assert_eq!(hovered(&h), "deep");
        typ(&mut h, window, "anew.txt\n");
        assert_eq!(message(&h), "That name is taken");
        typ(&mut h, window, "u");
        assert!(!work.join("deep/er").exists());
        typ(&mut h, window, ":mkdir \"two words\"\n:touch t.txt\n");
        assert!(work.join("two words").is_dir() && work.join("t.txt").is_file());
        typ(&mut h, window, ":rename a/b\n");
        assert_eq!(message(&h), "Names cannot be empty or contain “/”");
        let _ = std::fs::remove_dir_all(&home);
    }

    // = opens the command line with chmod; modes go to the targets, into folders with -R;
    // a bad mode or user says so; chown to oneself works, to root needs root. Catches: the
    // wrong targets, -R ignored, the summary wrong.
    #[test]
    fn chmod_and_chown() {
        let (mut h, window, home) = ops_app("perms");
        let work = home.join("work");
        std::fs::write(work.join("assets/logo.svg"), "x").unwrap();
        assert_eq!(mode_of(&work.join("build.zig")), 0o644);
        typ(&mut h, window, "fbu=");
        assert_eq!(line(&mut h, window), "chmod ");
        typ(&mut h, window, "u+x,go-r\n");
        wait_ops(&mut h);
        assert_eq!(mode_of(&work.join("build.zig")), 0o700);
        assert_eq!(message(&h), "Changed the permissions of “build.zig”");
        typ(&mut h, window, " gg :chmod -R a-w\n");
        wait_ops(&mut h);
        assert_eq!(mode_of(&work.join("assets")), 0o555);
        assert_eq!(mode_of(&work.join("assets/logo.svg")), 0o444);
        assert_eq!(mode_of(&work.join("build.zig")), 0o500);
        assert_eq!(message(&h), "Changed the permissions of 3 items");
        typ(&mut h, window, "gg:chmod -R u+w\n");
        wait_ops(&mut h);
        assert_eq!(mode_of(&work.join("assets")), 0o755);
        typ(&mut h, window, ":chmod u+q\n");
        assert!(message(&h).starts_with("Not a mode: u+q"));
        let (uid, gid) = (rustix::process::getuid(), rustix::process::getgid());
        typ(
            &mut h,
            window,
            &format!(":chown {}:{}\n", uid.as_raw(), gid.as_raw()),
        );
        wait_ops(&mut h);
        assert_eq!(message(&h), "Changed the owner of “assets”");
        typ(&mut h, window, ":chown nosuchuser\n");
        assert_eq!(message(&h), "No such user: nosuchuser");
        if !uid.is_root() {
            typ(&mut h, window, ":chown 0\n");
            wait_ops(&mut h);
            assert_eq!(
                message(&h),
                "Could not change the owner of “assets”: Permission denied"
            );
        }
        let _ = std::fs::remove_dir_all(&home);
    }

    // The tasks view: empty at first; a copy paused from it stays paused, resumes and
    // finishes, listed as done; a second copy cancelled from it leaves nothing; x takes a
    // finished task off the list, j moves, q closes. Catches: pause not holding the worker,
    // finished tasks not kept, the view's keys going to the columns.
    #[test]
    fn the_tasks_view() {
        // 256 MiB: 64 of the copy's 4 MiB chunks, so a pause lands mid-copy.
        let (mut h, window, home) = ops_app_with("tasks", |home| {
            std::fs::File::create(home.join("work/big.bin"))
                .unwrap()
                .set_len(256 << 20)
                .unwrap();
        });
        let work = home.join("work");
        typ(&mut h, window, "w");
        assert!(tasks::is_open(h.state()));
        assert_eq!(tasks::selected_text(h.state()), "No file operations yet");
        typ(&mut h, window, "\x1b");
        assert!(!tasks::is_open(h.state()));

        typ(&mut h, window, "fbiyyfdocl");
        // The paste, the view, and the pause in one go, before the copy can finish.
        for c in ['p', 'w', 'p'] {
            h.key(window, Keysym::from_char(c), Modifiers::NONE)
                .unwrap();
        }
        h.settle().unwrap();
        assert_eq!(h.state().ops.jobs.len(), 1);
        let job = h.state().ops.jobs[0].job.clone();
        assert!(job.is_paused());
        assert!(tasks::selected_text(h.state()).starts_with("Copying “big.bin” to docs"));
        // The pause holds the worker at its next chunk: one in flight still lands.
        std::thread::sleep(Duration::from_millis(100));
        let at = job.progress().bytes_done;
        std::thread::sleep(Duration::from_millis(300));
        assert_eq!(job.progress().bytes_done, at);
        typ(&mut h, window, "p");
        wait_ops(&mut h);
        assert_eq!(h.state().ops.recent.len(), 1);
        assert_eq!(h.state().ops.recent[0].result, "Copied “big.bin”");

        typ(&mut h, window, "\x1bhfbiyyfasl");
        for c in ['p', 'w', 'p', 'x'] {
            h.key(window, Keysym::from_char(c), Modifiers::NONE)
                .unwrap();
        }
        wait_ops(&mut h);
        assert!(h.state().ops.recent[0].canceled);
        assert!(!work.join("assets/big.bin").exists());
        assert!(tasks::is_open(h.state()));
        typ(&mut h, window, "jx");
        assert_eq!(h.state().ops.recent.len(), 1);
        assert!(h.state().ops.recent[0].canceled);
        typ(&mut h, window, "q");
        assert!(!tasks::is_open(h.state()));
        let _ = std::fs::remove_dir_all(&home);
    }

    // Alt+Enter: the mode selected, typing replaces it and the boxes follow; a box flipped
    // writes the mode back; Enter applies as a chmod; Escape leaves without a change; Alt+a
    // applies from a text field. Catches: boxes and mode out of step, keys reaching the
    // columns, Apply changing nothing.
    #[test]
    fn the_properties_dialog() {
        let (mut h, window, home) = ops_app("props");
        let file = home.join("work/build.zig");
        assert_eq!(mode_of(&file), 0o644);
        typ(&mut h, window, "fbu");
        h.key(window, Keysym::RETURN, Modifiers::ALT).unwrap();
        h.settle().unwrap();
        assert!(dialog_is(&h, dialogs::Dialog::is_properties));
        let (mode_field, _, boxes) = h
            .state()
            .wops
            .dialog
            .as_ref()
            .and_then(dialogs::Dialog::property_fields)
            .unwrap();
        let text = |h: &mut H| {
            h.update(window, |tx| Ok(tx.editor_text(mode_field)?.to_string()))
                .unwrap()
        };
        let checked = |h: &mut H, i: usize| {
            h.update(window, |tx| keywork::widgets::checked(tx, boxes[i]))
                .unwrap()
        };
        assert_eq!(text(&mut h), "0644");
        for c in "755".chars() {
            h.perform(window, &keywork::app::tooling::Action::Type(c.to_string()))
                .unwrap();
            h.settle().unwrap();
        }
        assert_eq!(text(&mut h), "755");
        assert!(checked(&mut h, 2));
        // The group's write box, flipped as a click would.
        h.update(window, |tx| {
            let on = keywork::widgets::checked(tx, boxes[4])?;
            keywork::widgets::set_checked(tx, boxes[4], !on)?;
            tx.emit(keywork::Event::new(keywork::EventKind::Changed, boxes[4]));
            Ok(())
        })
        .unwrap();
        h.settle().unwrap();
        assert_eq!(text(&mut h), "0775");
        h.key(window, Keysym::RETURN, Modifiers::NONE).unwrap();
        wait_ops(&mut h);
        assert!(h.state().wops.dialog.is_none());
        assert_eq!(mode_of(&file), 0o775);
        assert_eq!(hovered(&h), "build.zig");

        h.key(window, Keysym::RETURN, Modifiers::ALT).unwrap();
        h.settle().unwrap();
        for c in "700".chars() {
            h.perform(window, &keywork::app::tooling::Action::Type(c.to_string()))
                .unwrap();
        }
        h.key(window, Keysym::ESCAPE, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        assert!(h.state().wops.dialog.is_none());
        assert_eq!(mode_of(&file), 0o775);
        h.key(window, Keysym::RETURN, Modifiers::ALT).unwrap();
        h.settle().unwrap();
        for c in "go-w".chars() {
            h.perform(window, &keywork::app::tooling::Action::Type(c.to_string()))
                .unwrap();
        }
        h.key(window, Keysym::from_char('a'), Modifiers::ALT)
            .unwrap();
        wait_ops(&mut h);
        assert_eq!(mode_of(&file), 0o755);
        let _ = std::fs::remove_dir_all(&home);
    }

    // --- Windows and activation, as the Zig build's App and main.zig had them ---------------

    use keywork::dbus::{Array, Message, Value};

    /// An `org.freedesktop.Application` call on the instance, as a later launch makes it.
    fn application_call(member: &str, paths: &[PathBuf]) -> Message {
        let data = Value::Array(Array::dict(Vec::new()));
        let body = if member == "Open" {
            let paths: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
            let uris = instance::uris(&paths).into_iter().map(Value::Str).collect();
            vec![Value::Array(Array::new("s", uris).unwrap()), data]
        } else {
            vec![data]
        };
        Message::method_call(
            Some(instance::APP_ID),
            "/dev/rockorager/Strider",
            Some("org.freedesktop.Application"),
            member,
        )
        .unwrap()
        .with_body(body)
    }

    /// The app on a sample home with no window yet, launched on a session bus of its own
    /// with the paths `paths` names under the home, as `main` launches it.
    fn launched(
        name: &str,
        service: bool,
        paths: impl FnOnce(&std::path::Path) -> Vec<PathBuf>,
    ) -> (H, PathBuf) {
        let home = scenes::fixture(name);
        let (app, mut state) = base(
            home.clone(),
            Config::default(),
            Zone::utc(),
            false,
            None,
            None,
        )
        .unwrap();
        state.launch.service = service;
        let mut h = app.headless_with_bus(state).unwrap();
        let paths: Vec<String> = paths(&home)
            .iter()
            .map(|p| p.display().to_string())
            .collect();
        let launch = h.launch(instance::APP_ID, instance::uris(&paths));
        assert_eq!(launch.unwrap(), Launch::First);
        h.settle().unwrap();
        (h, home)
    }

    fn win(h: &H, window: WindowId) -> &app::Win {
        h.state()
            .wins
            .iter()
            .find(|w| w.window == window)
            .expect("an open window")
    }

    // A launch's folders and files open in one window, a file in its folder under the
    // cursor, the last path active; a later launch's folders become tabs in the window used
    // last, and a later plain launch opens a window of its own, as in the Zig build. Catches:
    // activations going nowhere, every Open making a window, the wrong window taking the
    // tabs, a file opened as a folder.
    #[test]
    fn launches_open_windows_and_hand_their_folders_over() {
        let (mut h, home) = launched("launch", false, |home| {
            vec![home.join("work/build.zig"), home.join("Music")]
        });
        let work = home.join("work");
        let windows = h.windows();
        assert_eq!(windows.len(), 1);
        let first = windows[0];
        assert_eq!(win(&h, first).tabs.len(), 2);
        assert_eq!(win(&h, first).cwd, home.join("Music"));
        assert_eq!(win(&h, first).tabs[0].cwd, work);
        typ(&mut h, first, ":tab 1\n");
        assert_eq!(win(&h, first).cwd, work);
        assert_eq!(h.state().cur().current_name(), Some(&b"build.zig"[..]));

        // A later launch with a folder: a tab in this window.
        let docs = [home.join("Documents")];
        h.bus_call(application_call("Open", &docs)).unwrap();
        h.settle().unwrap();
        assert_eq!(h.windows(), vec![first]);
        assert_eq!(win(&h, first).tabs.len(), 3);
        assert_eq!(win(&h, first).cwd, home.join("Documents"));

        // A later plain launch: a window of its own, on the folder the instance runs in.
        h.bus_call(application_call("Activate", &[])).unwrap();
        h.settle().unwrap();
        let windows = h.windows();
        assert_eq!(windows.len(), 2);
        let second = windows[1];
        assert_eq!(win(&h, second).cwd, instance::current_dir(&home));
        assert_eq!(win(&h, second).tabs.len(), 1);

        // Folders go to the window used last: the first, once it has a key.
        h.key(first, Keysym::from_char('j'), Modifiers::NONE)
            .unwrap();
        h.settle().unwrap();
        let desktop = [home.join("Desktop")];
        h.bus_call(application_call("Open", &desktop)).unwrap();
        h.settle().unwrap();
        assert_eq!(win(&h, first).tabs.len(), 4);
        assert_eq!(win(&h, first).cwd, home.join("Desktop"));
        assert_eq!(win(&h, second).tabs.len(), 1);
        // Then the second, once it has one.
        h.key(second, Keysym::from_char('j'), Modifiers::NONE)
            .unwrap();
        h.settle().unwrap();
        h.bus_call(application_call("Open", &desktop)).unwrap();
        h.settle().unwrap();
        assert_eq!(win(&h, first).tabs.len(), 4);
        assert_eq!(win(&h, second).tabs.len(), 2);
        assert_eq!(win(&h, second).cwd, home.join("Desktop"));
        let _ = std::fs::remove_dir_all(&home);
    }

    // A plain launch opens a window on the folder it runs in; the `new-window` action, as
    // the desktop entry's, opens one on home. Catches: the first launch showing nothing, the
    // action unregistered or opening where the last window is.
    #[test]
    fn a_plain_launch_and_the_new_window_action() {
        let (mut h, home) = launched("plain-launch", false, |_| Vec::new());
        let windows = h.windows();
        assert_eq!(windows.len(), 1);
        assert_eq!(win(&h, windows[0]).cwd, instance::current_dir(&home));
        let call = Message::method_call(
            Some(instance::APP_ID),
            "/dev/rockorager/Strider",
            Some("org.freedesktop.Application"),
            "ActivateAction",
        )
        .unwrap()
        .with_body(vec![
            Value::str("new-window"),
            Value::Array(Array::new("v", Vec::new()).unwrap()),
            Value::Array(Array::dict(Vec::new())),
        ]);
        h.bus_call(call).unwrap();
        h.settle().unwrap();
        let windows = h.windows();
        assert_eq!(windows.len(), 2);
        assert_eq!(win(&h, windows[1]).cwd, home);
        let _ = std::fs::remove_dir_all(&home);
    }

    // Each window has its own folder, tabs, keys, and prompt; what they share, the register,
    // shows in every one. Closing a window's last tab closes only that window, as does the
    // compositor's close button; the last window's closing quits. Catches: a key acting on
    // another window, state shared that should not be, the register shown only where it was
    // taken, `q` quitting the app with windows left, a closed window's state left behind.
    #[test]
    fn windows_keep_their_own_state_and_close_alone() {
        let (mut h, first, home) = ops_app("windows");
        let work = home.join("work");
        typ(&mut h, first, ":new-window\n");
        let windows = h.windows();
        assert_eq!(windows.len(), 2);
        let second = windows[1];
        assert_eq!(win(&h, second).cwd, work);

        // Keys reach the window they are pressed in.
        typ(&mut h, second, "h");
        assert_eq!(win(&h, second).cwd, home);
        assert_eq!(win(&h, first).cwd, work);
        typ(&mut h, second, "gn");
        assert_eq!(win(&h, second).tabs.len(), 2);
        assert_eq!(win(&h, first).tabs.len(), 1);
        typ(&mut h, first, ":");
        let open = |h: &H, w| win(h, w).mode.matches(mode::mode::states::line::OPEN);
        assert!(open(&h, first));
        assert!(!open(&h, second));
        typ(&mut h, first, "\x1b");

        // The register is everyone's.
        typ(&mut h, first, "fbuyy");
        assert_eq!(h.state().ops.register.len(), 1);
        let right = win(&h, second).ui.status_right;
        let text = h.tree(second).unwrap().text_content(right).unwrap();
        assert!(text.contains("1 copied"), "{text}");

        // q closes the second window's tab, then the window, and only it.
        typ(&mut h, second, "q");
        assert_eq!(win(&h, second).tabs.len(), 1);
        typ(&mut h, second, "q");
        assert_eq!(h.windows(), vec![first]);
        assert_eq!(h.state().wins.len(), 1);
        assert!(!h.quit_requested());
        typ(&mut h, first, "gg");
        assert_eq!(h.state().cur().cursor, 0);

        // The compositor's close button too.
        typ(&mut h, first, ":new-window\n");
        let third = h.windows()[1];
        h.request_close(third).unwrap();
        h.settle().unwrap();
        assert_eq!(h.windows(), vec![first]);
        assert_eq!(h.state().window_ids(), vec![first]);
        assert!(!h.quit_requested());

        // :qa closes them all, which quits.
        typ(&mut h, first, ":new-window\n");
        assert_eq!(h.windows().len(), 2);
        typ(&mut h, first, ":qa\n");
        assert!(h.windows().is_empty());
        assert!(h.quit_requested());
        let _ = std::fs::remove_dir_all(&home);
    }

    // A conflict is asked about in the window whose paste found it, not the others; that
    // window closing cancels it while the app goes on; the last window closing quits, and the
    // quit cancels the jobs left. Catches: a question in the wrong window or in every one, a
    // job left waiting on a closed window forever, jobs running on after the quit.
    #[test]
    fn jobs_ask_in_their_window_and_stop_with_it() {
        // A build.zig in docs, for a paste of work's to find there.
        let (mut h, first, home) = ops_app_with("window-jobs", |home| {
            std::fs::write(home.join("work/docs/build.zig"), "old").unwrap();
        });
        typ(&mut h, first, ":new-window\n");
        let second = h.windows()[1];
        typ(&mut h, second, "fbuyyfdoclp");
        wait_ops(&mut h);
        assert_eq!(h.state().ops.asks.len(), 1);
        assert_eq!(h.state().ops.asking, Some(second));
        let asked = |h: &H, w| {
            win(h, w).keys.context().question == Some(strider_machines::keymap::Question::Conflict)
        };
        assert!(asked(&h, second));
        assert!(!asked(&h, first));
        let job = h.state().ops.jobs[0].job.clone();
        // Keys answer the question now: the close button closes it.
        h.request_close(second).unwrap();
        h.settle().unwrap();
        assert_eq!(h.windows(), vec![first]);
        for _ in 0..400 {
            h.settle().unwrap();
            if h.state().ops.jobs.is_empty() {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            job.state(),
            ops::State::Ended(strider_machines::operation::End::Cancelled)
        );
        assert!(h.state().ops.asks.is_empty());
        assert!(h.state().ops.recent[0].canceled);
        assert!(!h.quit_requested());

        typ(&mut h, first, "fbuyyfdoclp");
        wait_ops(&mut h);
        assert_eq!(h.state().ops.asking, Some(first));
        let job = h.state().ops.jobs[0].job.clone();
        h.request_close(first).unwrap();
        for _ in 0..400 {
            h.settle().unwrap();
            if h.quit_requested() {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(h.quit_requested());
        assert_eq!(
            job.state(),
            ops::State::Ended(strider_machines::operation::End::Cancelled)
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // Started by D-Bus activation, the instance shows no window until the call that started
    // it asks for one, and quits once its last window closes, as the Zig build's did; with no
    // window asked for, it quits after the idle timeout. Catches: a service exiting before
    // its call came, a window it was not asked for, a service that never exits.
    #[test]
    fn a_service_waits_for_its_activation() {
        let (mut h, home) = launched("service", true, |_| Vec::new());
        assert!(h.windows().is_empty());
        assert!(!h.quit_requested());
        h.advance(Duration::from_secs(10)).unwrap();
        assert!(!h.quit_requested());
        h.bus_call(application_call("Open", &[home.join("work")]))
            .unwrap();
        h.settle().unwrap();
        let windows = h.windows();
        assert_eq!(windows.len(), 1);
        assert_eq!(win(&h, windows[0]).cwd, home.join("work"));
        // Its idle timeout passes with a window open: it stays.
        h.advance(instance::IDLE_TIMEOUT).unwrap();
        assert!(!h.quit_requested());
        h.request_close(windows[0]).unwrap();
        h.settle().unwrap();
        assert!(h.quit_requested());
        let _ = std::fs::remove_dir_all(&home);

        let (mut h, home) = launched("service-idle", true, |_| Vec::new());
        h.advance(instance::IDLE_TIMEOUT - Duration::from_millis(1))
            .unwrap();
        assert!(!h.quit_requested());
        h.advance(Duration::from_millis(2)).unwrap();
        assert!(h.quit_requested());
        let _ = std::fs::remove_dir_all(&home);
    }

    // The command line as main.zig read it, less what init.lua needed: paths, the options,
    // and Keywork's flags left to Keywork. Catches: a Keywork flag's value taken for a
    // folder, --version without Cargo's version, an unknown option let through.
    #[test]
    fn the_command_line() {
        let args = |a: &[&str]| parse_args(a.iter().map(|s| (*s).to_owned()));
        let a = args(&[
            "--keywork-scene",
            "columns",
            "a",
            "--hidden",
            "--new-window",
            "--dark",
            "--rtl",
            "b",
        ])
        .unwrap();
        assert_eq!(a.paths, ["a", "b"]);
        assert!(a.hidden && a.new_window && !a.service);
        assert_eq!(a.scheme, Some(Appearance::Dark));
        assert!(args(&["--gapplication-service"]).unwrap().service);
        assert_eq!(
            args(&["--version"]),
            Err((format!("strider {}\n", env!("CARGO_PKG_VERSION")), 0))
        );
        assert_eq!(args(&["-h"]), Err((USAGE.to_owned(), 0)));
        let (text, status) = args(&["--clean"]).unwrap_err();
        assert_eq!(status, 2);
        assert!(text.starts_with("strider: unknown option --clean\n"));
    }
}
