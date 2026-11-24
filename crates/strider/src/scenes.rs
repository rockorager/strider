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
    crate::app_in(home.join(start), home, Config::default(), Zone::utc())
}

/// Presses keys as a user would, through the keymap.
fn press(s: &mut Strider, tx: &mut Txn<'_, Strider>, spec: &str) -> Result<()> {
    for key in strider_core::keys::parse(spec).map_err(|_| Error::Other("a scene's keys"))? {
        let seq = strider_machines::keymap::sequence(&s.keys.context().pending, key);
        let found = s
            .keymap
            .lookup(strider_machines::mode::table(s.visual()), &seq);
        let ev = strider_machines::keymap::KeyEv::Key {
            key,
            exact: found.exact.map(|b| b.cmd.clone()),
            prefix: found.prefix,
        };
        let fx = s.keys.send(ev, app::Clock { tx });
        let _ = app::apply_key_fx(s, tx, fx);
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
