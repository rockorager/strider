//! Scenes: states of the window that renders and tests share, on a sample home made the way
//! the Zig build's headless tests made theirs, so the two builds' renders compare.
//!
//! `strider --keywork-snap /abs/out.png --keywork-scene columns --keywork-size 1000x560`

use std::fs::{self, File, FileTimes};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use keywork::Error;
use keywork::desktop::localtime::Zone;
use keywork::prelude::*;
use strider_core::config::Config;

use crate::app::{self, Strider};

const ZIG_SOURCE: &str = r#"const std = @import("std");

/// Adds two numbers.
pub fn add(a: u32, b: u32) u32 {
    return a + b; // no overflow check
}

test "add" {
    try std.testing.expectEqual(@as(u32, 5), add(2, 3));
}
"#;

const README: &str = "# Work\n\nNotes about **the project**, with `code` and a [link](https://example.org).\n\n- one\n- two\n";

/// The sample home: a few folders beside `work`, which scenes start in.
pub fn fixture(name: &str) -> PathBuf {
    let home = std::env::temp_dir().join(format!("strider-scene-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    let dirs = [
        "Desktop",
        "Documents",
        "Music",
        "work",
        "work/assets",
        "work/src",
        "work/docs",
        "work/src/util",
    ];
    for d in dirs {
        fs::create_dir_all(home.join(d)).expect("the sample home");
    }
    let files: [(&str, usize); 12] = [
        ("notes.txt", 1200),
        ("work/build.zig", 2048),
        ("work/README.md", 4200),
        ("work/report.pdf", 2_400_000),
        ("work/photo.png", 300_000),
        ("work/backup.tar.gz", 52_000),
        ("work/run.sh", 80),
        (
            "work/a-very-long-file-name-that-does-not-fit-in-its-column.txt",
            10,
        ),
        ("work/.hidden", 5),
        ("work/src/main.zig", 0),
        ("work/src/App.zig", 300),
        ("work/docs/guide.md", 900),
    ];
    for (f, size) in files {
        fs::write(home.join(f), vec![0u8; size]).expect("the sample home");
    }
    fs::write(home.join("work/src/main.zig"), ZIG_SOURCE).expect("the sample home");
    fs::write(home.join("work/README.md"), README).expect("the sample home");
    fs::set_permissions(home.join("work/run.sh"), fs::Permissions::from_mode(0o755))
        .expect("the sample home");
    let at = |secs| SystemTime::UNIX_EPOCH + Duration::from_secs(secs);
    let touch = |p: &Path, secs| {
        let f = File::open(p).expect("the sample home");
        f.set_times(
            FileTimes::new()
                .set_modified(at(secs))
                .set_accessed(at(secs)),
        )
        .expect("the sample home");
    };
    for d in dirs.iter().chain(&["work/src/main.zig"]) {
        touch(&home.join(d), 1_791_900_300);
    }
    touch(&home.join("work/README.md"), 1_790_000_000);
    home
}

/// The app on the sample home, started in `start` under it, with times in UTC.
fn sample(name: &str, start: &str) -> Result<(App<Strider>, Strider)> {
    let home = fixture(name);
    crate::app_in(
        home.join(start),
        home,
        Config::default(),
        Zone::utc(),
        true,
        None,
    )
}

/// Presses keys as a user would, through the keymap. While a prompt is open, a character
/// is typed into it, as its text field would take it.
fn press(s: &mut Strider, tx: &mut Txn<'_, Strider>, spec: &str) -> Result<()> {
    // One key at a time, as a sequence is at most eight keys: `<...>` or a character.
    let mut rest = spec;
    while let Some(c) = rest.chars().next() {
        let len = match (c, rest.find('>')) {
            ('<', Some(end)) => end + 1,
            _ => c.len_utf8(),
        };
        let (one, more) = rest.split_at(len);
        rest = more;
        let [key] = strider_core::keys::parse(one).map_err(|_| Error::Other("a scene's keys"))?[..]
        else {
            return Err(Error::Other("a scene's keys"));
        };
        if s.prompt().is_some()
            && (key.is_char() || key == strider_core::keys::Key::char(u32::from(' ')))
            && let Some(c) = char::from_u32(key.code)
        {
            let editor = s.ui.line_editor;
            let text = format!("{}{c}", tx.editor_text(editor)?);
            tx.set_text(editor, &text)?;
            tx.set_editor_selection(editor, text.len(), text.len())?;
            app::send_mode(s, tx, strider_machines::mode::ModeEv::Edit)?;
            continue;
        }
        match app::press(s, tx, key) {
            Err(Error::Pass) => {}
            r => r?,
        }
    }
    Ok(())
}

pub fn add(app: &mut App<Strider>) {
    // The README's first view: into src, onto main.zig, its text colored.
    app.scene_app("columns", || {
        let (mut app, mut s) = sample("columns", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "jjljj"))?;
        Ok((app, s))
    });
    app.scene_app("visual", || {
        let (mut app, mut s) = sample("visual", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "3jVjj"))?;
        Ok((app, s))
    });
    app.scene_app("hidden", || {
        let (mut app, mut s) = sample("hidden", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "zhG"))?;
        Ok((app, s))
    });
    // :set completes and runs, then a path completes, the line left open.
    app.scene_app("command-line", || {
        let (mut app, mut s) = sample("command-line", "work")?;
        let window = s.window;
        app.update(window, |tx| {
            press(&mut s, tx, ":set<Space>hidden<CR>:cd<Space>../Mu<Tab>")
        })?;
        Ok((app, s))
    });
    // Tab with several commands that start so: as far as they agree, and the list.
    app.scene_app("completion", || {
        let (mut app, mut s) = sample("completion", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, ":so<Tab>"))?;
        Ok((app, s))
    });
    app.scene_app("filter", || {
        let (mut app, mut s) = sample("filter", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "zfre"))?;
        Ok((app, s))
    });
    app.scene_app("which-key", || {
        let (mut app, mut s) = sample("which-key", "work")?;
        s.keys.send(
            strider_machines::keymap::KeyEv::SetDelay(Duration::ZERO),
            plusthree::host::NoTimers,
        );
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "g"))?;
        Ok((app, s))
    });
}
