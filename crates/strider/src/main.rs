//! Strider: a keyboard-driven file manager for Linux on Wayland.

mod app;
mod commands;
mod folder;
mod preview;
mod scenes;

use std::collections::HashMap;
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
    let current = folder::Folder::read(&start, &config.options, &db, None);
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
        current,
        parent: None,
        preview: preview::Preview::None,
        history: vec![start],
        history_pos: 0,
        cursors: HashMap::new(),
        anchor: 0,
        message: problems
            .first()
            .map(|p| (format!("config.json: {p}"), true)),
        width: 0.0,
        parent_fit: 0.0,
    };
    app::reload_around(&mut state);
    app.update(window, |tx| app::draw(&mut state, tx))?;
    app.on_icon_theme(load_icons);
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
    let start = std::env::args()
        .skip(1)
        .find(|a| !a.starts_with("--"))
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| home.clone());
    let start = std::path::absolute(&start).unwrap_or(start);
    let (app, state) = app_in(start, home, config, Zone::local())?;
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
        )
        .unwrap();
        let window = state.window;
        let mut h = app.headless(state).unwrap();
        let press = |h: &mut keywork::app::Headless<Strider>, c: char| {
            h.key(window, Keysym::from_char(c), Modifiers::NONE)
                .unwrap();
            h.settle().unwrap();
        };

        press(&mut h, '2');
        press(&mut h, 'j');
        assert_eq!(h.state().current.cursor, 2);
        assert_eq!(h.state().current.name(2), b"src");

        press(&mut h, ' ');
        assert_eq!(h.state().current.marks.len(), 1);
        press(&mut h, 'g');
        h.key(window, Keysym::ESCAPE, Modifiers::NONE).unwrap();
        h.settle().unwrap();
        assert!(h.state().keys.matches(states::IDLE));
        assert_eq!(
            h.state().current.marks.len(),
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
        assert_eq!(h.state().current.path, home);
        let _ = std::fs::remove_dir_all(&home);
    }
}
