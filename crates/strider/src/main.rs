use std::path::PathBuf;

use keywork::prelude::*;
use keywork::widgets::{SurfaceKind, TextKind};

fn main() -> keywork::Result<()> {
    let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()));
    let config_home =
        std::env::var_os("XDG_CONFIG_HOME").map_or_else(|| home.join(".config"), PathBuf::from);
    if let Ok(text) = std::fs::read_to_string(config_home.join("strider/config.json")) {
        let (_config, problems) = strider_core::config::parse(&text, &home);
        for p in problems {
            eprintln!("strider: config.json: {p}");
        }
    }

    let mut app = App::<()>::new();
    let window = app.open_window(WindowDesc::new("Strider"))?;
    app.update(window, |tx| {
        let root = widgets::surface(
            tx,
            tx.root(),
            Flex::column().padding(16.0).width(Dim::Fill).height(Dim::Fill),
            SurfaceKind::Background,
        )?;
        widgets::label(tx, root, "Strider", TextKind::Body).map(drop)
    })?;
    app.run(())
}
