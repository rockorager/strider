//! Strider: a keyboard-driven file manager for Linux on Wayland.

mod app;
mod cache;
mod commands;
mod folder;
mod preview;
mod prompt;
mod scenes;

use std::path::PathBuf;
use std::sync::Arc;

use keywork::desktop::basedir::BaseDirs;
use keywork::desktop::localtime::Zone;
use keywork::desktop::mime::MimeDb;
use keywork::icons::MimeIcons;
use keywork::prelude::*;
use strider_core::config::Config;
use strider_core::keys::Keymap;
use strider_machines::driver::Driver;
use strider_machines::keymap::{self, KeyEv};
use strider_machines::mode;

use app::{Col, Strider};

/// Builds the window on `start`, with `home` for `~` and the configuration given, without
/// running it.
pub fn app_in(
    start: PathBuf,
    home: PathBuf,
    config: Config,
    zone: Zone,
    sync_reads: bool,
    state_dir: Option<PathBuf>,
) -> Result<(App<Strider>, Strider)> {
    let mut app = App::<Strider>::new();
    // Names, sizes, and dates line up in a monospace face, as Fontconfig resolves the alias,
    // live, rather than in the desktop's sans-serif.
    app.map_desktop_theme(|mut theme| {
        theme.fonts.ui = keywork::FontFamily::Monospace;
        theme
    });
    let window = app.open_window(
        WindowDesc::new("Strider")
            .app_id("dev.rockorager.Strider")
            .size(1000, 560),
    )?;
    let ui = app.update(window, app::build)?;
    let mut keymap = Keymap::defaults();
    let problems = keymap.apply(&config);
    let db = Arc::new(MimeDb::load(&BaseDirs::from_env()));
    let mut keys = Driver::new(keymap::Keymap::machine(), ());
    keys.send(
        KeyEv::SetDelay(std::time::Duration::from_millis(u64::from(
            config.options.which_key_delay,
        ))),
        plusthree::host::NoTimers,
    );
    let mut state = Strider {
        window,
        ui,
        options: config.options,
        keymap,
        keys,
        mode: Driver::new(mode::Mode::machine(), ()),
        home,
        zone,
        db,
        icons: None,
        cache: cache::Cache::new(),
        cwd: start.clone(),
        parent_path: None,
        preview: preview::Preview::None,
        preview_generation: 0,
        sync_reads,
        history: vec![start.clone()],
        history_pos: 0,
        anchor: 0,
        message: problems
            .first()
            .map(|p| (format!("config.json: {p}"), true)),
        width: 0.0,
        parent_fit: 0.0,
        prompt_origin: 0,
        prompt_entry: None,
        last_search: String::new(),
        last_search_back: false,
        lines: state_dir
            .as_deref()
            .map(strider_core::state::load_history)
            .unwrap_or_default(),
        line_pos: 0,
        state_dir,
        probe: 0,
    };
    // A start that is no folder leaves an empty current folder, which says why.
    state.cache.entry(&start);
    app.update(window, |tx| app::cd(&mut state, tx, start, None, false))?;
    app.on_icon_theme(load_icons);
    app.on_start(cache::start_watching);
    scenes::add(&mut app);
    Ok((app, state))
}

/// Loads the desktop's icon theme, when it is first known and whenever it changes, and draws
/// the rows again with its icons.
fn load_icons(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    let proxy = cx.proxy();
    let pool = cx.pool().clone();
    cx.load_icon_theme(s.window, move |s: &mut Strider, tx, theme| {
        s.icons = Some(MimeIcons::new(theme, pool, move || {
            let _ = proxy.post(receive_icons);
        }));
        refresh_rows(s, tx)
    });
    Ok(())
}

fn receive_icons(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    if s.icons.as_mut().is_some_and(MimeIcons::receive) {
        let window = s.window;
        cx.update(window, |tx| refresh_rows(s, tx))?;
    }
    Ok(())
}

fn refresh_rows(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    for col in [Col::Parent, Col::Current, Col::Preview] {
        keywork::widgets::refresh_rows(tx, s.ui.lists[col as usize])?;
    }
    Ok(())
}

fn main() -> Result<()> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
    let config_home =
        std::env::var_os("XDG_CONFIG_HOME").map_or_else(|| home.join(".config"), PathBuf::from);
    let (config, problems) = match std::fs::read_to_string(config_home.join("strider/config.json"))
    {
        Ok(text) => strider_core::config::parse(&text, &home),
        Err(_) => (Config::default(), Vec::new()),
    };
    for p in &problems {
        eprintln!("strider: config.json: {p}");
    }
    // Keywork's own flags, and the values of those that take one, are not the folder.
    let mut args = std::env::args().skip(1);
    let mut folder = None;
    while let Some(a) = args.next() {
        if a.starts_with("--keywork-") {
            if !a.contains('=') && a != "--keywork-list-scenes" {
                args.next();
            }
        } else if !a.starts_with("--") {
            folder = Some(a);
            break;
        }
    }
    let start = folder
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| home.clone());
    let start = std::path::absolute(&start).unwrap_or(start);
    let state_dir = std::env::var_os("XDG_STATE_HOME")
        .map_or_else(|| home.join(".local/state"), PathBuf::from)
        .join("strider");
    let (app, state) = app_in(start, home, config, Zone::local(), false, Some(state_dir))?;
    app.run(state)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

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
            if h.state().prompt().is_some() && !c.is_control() {
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
}
