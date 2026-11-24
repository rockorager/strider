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
use keywork::theme::{ColorScheme, DesktopAppearance, Theme};
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

/// The app on the sample home, started in `start` under it, with times in UTC. Home, for
/// `~`, is the folder above the start, as the Zig build's test harness made it.
fn sample(name: &str, start: &str) -> Result<(App<Strider>, Strider)> {
    let start = fixture(name).join(start);
    let home = start.parent().map(Path::to_path_buf).unwrap_or_default();
    crate::app_in(start, home, Config::default(), Zone::utc(), true, None)
}

/// The app on the sample home, with the Omarchy theme `colors` active in it, as
/// `omarchy-theme-set` leaves one in `~/.local/state/omarchy/current/theme`.
fn sample_omarchy(name: &str, start: &str, colors: &str) -> Result<(App<Strider>, Strider)> {
    let home = fixture(name);
    let theme = home.join(".local/state/omarchy/current/theme");
    fs::create_dir_all(&theme).map_err(Error::app)?;
    fs::write(theme.join("colors.toml"), colors).map_err(Error::app)?;
    crate::app_in(
        home.join(start),
        home,
        Config::default(),
        Zone::utc(),
        true,
        None,
    )
}

/// The desktop's theme as the settings portal would make it for `desktop`, for scenes of
/// the desktop's dark and higher contrast.
fn desktop(app: &mut App<Strider>, desktop: DesktopAppearance) {
    app.desktop_theme(Some(Theme::default().follow_desktop(&desktop)));
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
    add_previews(app);
    add_operations(app);
    add_drives(app);
    add_pointer(app);
    add_choosers(app);
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
    // gf: files below, matched as typed, the second result selected.
    app.scene_app("picker", || {
        let (mut app, mut s) = sample("picker", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "jjgfzig<C-n><C-n><C-p>"))?;
        Ok((app, s))
    });
    // Three messages, errors in the error color, newest first.
    app.scene_app("messages", || {
        let (mut app, mut s) = sample("messages", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "/zzz<CR>jp:frobnicate<CR>"))?;
        for (i, m) in s.log.iter_mut().enumerate() {
            m.0 = 9 * 3600 + 41 * 60 + i as i64 * 7 - i64::from(s.zone.offset_at(0));
        }
        app.update(window, |tx| press(&mut s, tx, ":messages<CR>"))?;
        Ok((app, s))
    });
    app.scene_app("tabs", || {
        let (mut app, mut s) = sample("tabs", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "gnggjjl"))?;
        Ok((app, s))
    });
    app.scene_app("filter", || {
        let (mut app, mut s) = sample("filter", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "zfre"))?;
        Ok((app, s))
    });
    // The Menu key on build.zig: what applies to it, each item with its keys.
    app.scene_app("context-menu", || {
        let (mut app, mut s) = sample("context-menu", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "5j"))?;
        // Once the window has laid out, so the menu opens under the cursor's row.
        let header = s.ui.header;
        app.update(window, |tx| {
            let mut opened = false;
            app::on(tx, header, Resize, move |s: &mut Strider, tx, _| {
                if std::mem::replace(&mut opened, true) {
                    return Ok(());
                }
                press(s, tx, "<Menu>")
            })
        })?;
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
    // The Zig build's theme goldens: a marked file in a visual range, at the bottom of
    // work/src, under the desktop's dark and its higher contrast, and the cursor on the
    // first row in dark.
    let looks = [
        (
            "dark",
            DesktopAppearance {
                color_scheme: ColorScheme::PreferDark,
                ..Default::default()
            },
        ),
        (
            "high-contrast",
            DesktopAppearance {
                color_scheme: ColorScheme::PreferLight,
                high_contrast: true,
                ..Default::default()
            },
        ),
    ];
    for (name, look) in looks {
        app.scene_app(name, move || {
            let (mut app, mut s) = sample(name, "work/src")?;
            desktop(&mut app, look);
            let window = s.window;
            app.update(window, |tx| press(&mut s, tx, "G<Space>v"))?;
            Ok((app, s))
        });
    }
    app.scene_app("first-row-dark", || {
        let (mut app, mut s) = sample("first-row-dark", "work/src")?;
        desktop(
            &mut app,
            DesktopAppearance {
                color_scheme: ColorScheme::PreferDark,
                ..Default::default()
            },
        );
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "G<Space>v<Esc>gg"))?;
        Ok((app, s))
    });
    // The columns under Omarchy themes, dark and light, from tests/themes.
    let themes = [
        (
            "omarchy-tokyo-night",
            include_str!("../../../tests/themes/tokyo-night/colors.toml"),
        ),
        (
            "omarchy-catppuccin-latte",
            include_str!("../../../tests/themes/catppuccin-latte/colors.toml"),
        ),
    ];
    for (name, colors) in themes {
        app.scene_app(name, move || {
            let (mut app, mut s) = sample_omarchy(name, "work", colors)?;
            let window = s.window;
            app.update(window, |tx| press(&mut s, tx, "jjljj"))?;
            Ok((app, s))
        });
    }
}

/// The sample home with real files to preview, as the Zig build's preview tests made them:
/// a 160×120 gradient PNG, a tarball made by tar, a one-page PDF, a few binary bytes, and
/// TypeScript beside an MPEG transport stream, both named `.ts`.
pub fn preview_fixture(name: &str) -> PathBuf {
    let home = fixture(name);
    let work = home.join("work");
    let mut px = Vec::with_capacity(160 * 120 * 4);
    for y in 0..120u32 {
        for x in 0..160u32 {
            px.extend([(x * 255 / 159) as u8, (y * 255 / 119) as u8, 180, 255]);
        }
    }
    let png = keywork::image::encode_png(160, 120, &px).expect("a PNG");
    fs::write(work.join("photo.png"), png).expect("the sample home");
    let tar = "mkdir -p pkg/lib && printf 'hello' > pkg/lib/a.txt && printf 'x' > pkg/b.txt && \
        tar --mtime=@1791900300 --owner=0 --group=0 --numeric-owner --sort=name -cf - pkg | \
        gzip -n > backup.tar.gz && rm -rf pkg";
    let made = std::process::Command::new("sh")
        .arg("-c")
        .arg(tar)
        .current_dir(&work)
        .status();
    assert!(made.is_ok_and(|s| s.success()), "the sample tarball");
    fs::write(work.join("report.pdf"), pdf()).expect("the sample home");
    fs::write(work.join("data.bin"), b"\x00\x01\x02binary\x00").expect("the sample home");
    fs::write(work.join("app.ts"), TYPESCRIPT).expect("the sample home");
    let mut stream = [0xffu8; 188 * 5];
    for k in 0..5 {
        stream[k * 188] = 0x47;
    }
    fs::write(work.join("clip.ts"), stream).expect("the sample home");
    std::os::unix::fs::symlink("nowhere", work.join("dangling")).expect("the sample home");
    let at = rustix::fs::Timestamps {
        last_access: rustix::fs::Timespec {
            tv_sec: 1_791_900_300,
            tv_nsec: 0,
        },
        last_modification: rustix::fs::Timespec {
            tv_sec: 1_791_900_300,
            tv_nsec: 0,
        },
    };
    rustix::fs::utimensat(
        rustix::fs::CWD,
        work.join("dangling"),
        &at,
        rustix::fs::AtFlags::SYMLINK_NOFOLLOW,
    )
    .expect("the sample home");
    for f in [
        "photo.png",
        "backup.tar.gz",
        "report.pdf",
        "data.bin",
        "app.ts",
        "clip.ts",
    ] {
        let f = File::open(work.join(f)).expect("the sample home");
        let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_791_900_300);
        f.set_times(FileTimes::new().set_modified(at).set_accessed(at))
            .expect("the sample home");
    }
    home
}

const TYPESCRIPT: &str = r#"import { readFile } from "node:fs/promises";

/** Reads a config. */
export async function load(path: string): Promise<number> {
    const text = await readFile(path, "utf8");
    return text.length; // bytes, roughly
}
"#;

/// A minimal one-page PDF with a filled rectangle, its offsets computed.
fn pdf() -> Vec<u8> {
    let mut w = b"%PDF-1.4\n".to_vec();
    let content = "0.2 0.4 0.8 rg 20 20 160 220 re f";
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 260] /Contents 4 0 R >>".to_owned(),
        format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len()
        ),
    ];
    let mut offsets = Vec::new();
    for (i, o) in objects.iter().enumerate() {
        offsets.push(w.len());
        w.extend(format!("{} 0 obj\n{o}\nendobj\n", i + 1).bytes());
    }
    let xref = w.len();
    w.extend(b"xref\n0 5\n0000000000 65535 f \n");
    for o in offsets {
        w.extend(format!("{o:010} 00000 n \n").bytes());
    }
    w.extend(format!("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n").bytes());
    w
}

/// The preview column's scenes, each on the preview fixture in work with the keys given.
fn add_previews(app: &mut App<Strider>) {
    let scenes = [
        // An image decoded at the size shown, its name, size, and date under it.
        ("preview-image", "fph"),
        ("preview-archive", "fba"),
        ("preview-hex", "fdat"),
        // The first page, by pdftoppm or mutool.
        ("preview-pdf", "frep"),
        // TypeScript by its contents, though *.ts names a video type first.
        ("preview-typescript", "fap"),
        // A link's details say where it goes.
        ("preview-link", "fdan"),
        // Details alone, for a PDF with image previews off.
        (
            "preview-details",
            ":set<Space>preview_images<Space>false<CR>frep",
        ),
        // Text scrolled four lines down by J.
        ("preview-scroll", "fbuJ"),
    ];
    for (name, keys) in scenes {
        app.scene_app(name, move || {
            let home = preview_fixture(name);
            let (mut app, mut s) = crate::app_in(
                home.join("work"),
                home,
                Config::default(),
                Zone::utc(),
                true,
                None,
            )?;
            let window = s.window;
            app.update(window, |tx| press(&mut s, tx, keys))?;
            Ok((app, s))
        });
    }
    // A file named as an image that is none: the card says so.
    app.scene_app("preview-unsupported", || {
        let (mut app, mut s) = sample("preview-unsupported", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "fph"))?;
        Ok((app, s))
    });
    // Text that is no file, as a shell command's output shows.
    app.scene_app("preview-output", || {
        let (mut app, mut s) = sample("preview-output", "work")?;
        let window = s.window;
        app.update(window, |tx| {
            let text = "$ ls\nbuild.zig\nREADME.md\n";
            let spans = vec![strider_core::highlight::Span {
                start: 0,
                end: 4,
                class: strider_core::highlight::Class::Comment,
            }];
            crate::preview::show_output(&mut s, tx, "ls", text, spans)
        })?;
        Ok((app, s))
    });
}

/// The drives of the Zig build's UDisks2 tests: a USB stick's plain file system and its
/// encrypted volume, neither mounted.
pub fn stick_drives() -> Vec<strider_core::drives::Drive> {
    let drive = |id: &str, label: &str, size| strider_core::drives::Drive {
        id: format!("/org/freedesktop/UDisks2/block_devices/{id}"),
        label: label.into(),
        removable: true,
        can_mount: true,
        can_eject: true,
        size,
        ..Default::default()
    };
    vec![
        drive("sdc1", "SECRET", 8_000_000_000),
        drive("sdb1", "STICK", 16_000_000_000),
    ]
}

fn add_drives(app: &mut App<Strider>) {
    // gv: the drives as a folder, the cursor on the encrypted one, which is not mounted.
    app.scene_app("drives", || {
        let (mut app, mut s) = sample("drives", "work")?;
        let window = s.window;
        app.update(window, |tx| {
            crate::drives::set_list(&mut s, tx, stick_drives())?;
            press(&mut s, tx, "gv")
        })?;
        Ok((app, s))
    });
    // The encrypted volume's passphrase, asked again after a wrong one, typed masked; in
    // an empty folder beside the one it mounts on, as the Zig build's test had it.
    app.scene_app("unlock", || {
        let home =
            std::env::temp_dir().join(format!("strider-scene-unlock-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        for d in ["home", "Secret"] {
            fs::create_dir_all(home.join(d)).map_err(Error::app)?;
        }
        let (mut app, mut s) = crate::app_in(
            home.join("home"),
            home,
            Config::default(),
            Zone::utc(),
            true,
            None,
        )?;
        let window = s.window;
        app.update(window, |tx| {
            let secret = stick_drives().remove(0);
            crate::drives::set_list(&mut s, tx, vec![secret.clone()])?;
            crate::drives::ask_passphrase(
                &mut s,
                tx,
                secret.id,
                secret.label,
                Some("Wrong passphrase. Try again."),
            )?;
            press(&mut s, tx, "hunter2")
        })?;
        Ok((app, s))
    });
}

/// The sample home with `prepare` run on it first, as a test's earlier steps would leave it,
/// and files the previews show filled with "x", as the Zig build's fixture filled them.
fn sample_prepared(
    name: &str,
    start: &str,
    prepare: impl FnOnce(&Path) -> std::io::Result<()>,
) -> Result<(App<Strider>, Strider)> {
    let home = fixture(name);
    for (f, size) in [("work/build.zig", 2048), ("work/docs/guide.md", 900)] {
        fs::write(home.join(f), vec![b'x'; size]).map_err(Error::app)?;
    }
    // The files' times, as the Zig build's fixture gave every file it made.
    let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_791_900_300);
    for f in [
        "work/build.zig",
        "work/docs/guide.md",
        "work/photo.png",
        "work/report.pdf",
        "work/backup.tar.gz",
        "work/run.sh",
        "work/a-very-long-file-name-that-does-not-fit-in-its-column.txt",
    ] {
        File::open(home.join(f))
            .and_then(|f| f.set_times(FileTimes::new().set_modified(at).set_accessed(at)))
            .map_err(Error::app)?;
    }
    prepare(&home).map_err(Error::app)?;
    crate::app_in(
        home.join(start),
        home,
        Config::default(),
        Zone::utc(),
        true,
        None,
    )
}

/// Takes the jobs' updates until each is asking, paused, or done, as the window would as
/// they come.
fn wait_jobs(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    for _ in 0..4000 {
        crate::tasks::receive(s, tx)?;
        if s.ops
            .jobs
            .iter()
            .all(|r| r.job.is_paused() || r.job.state() == crate::ops::State::Asking)
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    Ok(())
}

/// The file operations' dialogs, prompt, and tasks view, at the steps of the Zig build's
/// tests where its goldens were taken.
fn add_operations(app: &mut App<Strider>) {
    // r on build.zig: the name without its extension selected.
    app.scene_app("rename", || {
        let (mut app, mut s) = sample_prepared("rename", "work", |_| Ok(()))?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "fbur"))?;
        Ok((app, s))
    });
    // dD on guide.md, moved into work by the conflict's step.
    app.scene_app("confirm-delete", || {
        let (mut app, mut s) = sample_prepared("confirm-delete", "work", |home| {
            fs::rename(home.join("work/docs/guide.md"), home.join("work/guide.md"))?;
            fs::copy(home.join("work/photo.png"), home.join("work/photo (2).png"))?;
            Ok(())
        })?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "fgudD"))?;
        Ok((app, s))
    });
    // guide.md and photo.png cut in docs, pasted in work, where photo.png is: two items
    // move, so a dialog compares the two photos.
    app.scene_app("conflict", || {
        let (mut app, mut s) = sample_prepared("conflict", "work", |home| {
            let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_791_900_300);
            for f in ["build.zig", "photo.png"] {
                let to = home.join("work/docs").join(f);
                fs::copy(home.join("work").join(f), &to)?;
                File::open(&to)?.set_times(FileTimes::new().set_modified(at).set_accessed(at))?;
            }
            // docs's time in the status line, the same however long ago its files came.
            File::open(home.join("work/docs"))?
                .set_times(FileTimes::new().set_modified(at).set_accessed(at))
        })?;
        let window = s.window;
        app.update(window, |tx| {
            press(&mut s, tx, "ggjlggjvjdhp")?;
            wait_jobs(&mut s, tx)?;
            // As the Zig build's golden has it, before the watcher shows guide.md moved:
            // what it saw of the move so far is dropped, so the scene is the same every time.
            s.cache.drop_changes();
            Ok(())
        })?;
        Ok((app, s))
    });
    // Alt+Enter on build.zig, its owner a fixed one for the image.
    app.scene_app("properties", || {
        let (mut app, mut s) = sample_prepared("properties", "work", |_| Ok(()))?;
        let window = s.window;
        app.update(window, |tx| {
            press(&mut s, tx, "fbu<A-CR>")?;
            if let Some((_, owner, _)) = s.wops.dialog.as_ref().and_then(|d| d.property_fields()) {
                tx.set_text(owner, "tim:users")?;
            }
            Ok(())
        })?;
        Ok((app, s))
    });
    // big.bin copied into docs, then into assets, paused and cancelled from the tasks view.
    app.scene_app("tasks", || {
        let (mut app, mut s) = sample_prepared("tasks", "work", |home| {
            File::create(home.join("work/big.bin"))?.set_len(256 << 20)
        })?;
        let window = s.window;
        app.update(window, |tx| {
            press(&mut s, tx, "fbiyyfdoclp")?;
            wait_jobs(&mut s, tx)?;
            press(&mut s, tx, "hfaslpwpx")?;
            wait_jobs(&mut s, tx)
        })?;
        Ok((app, s))
    });
}

/// The Zig build's chooser tests' home: `home` and `work` side by side, pictures, text
/// files, and a folder in `work`, every one modified at the same time.
pub fn chooser_fixture(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("strider-chooser-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    for d in ["home", "work", "work/src"] {
        fs::create_dir_all(root.join(d)).expect("the chooser fixture");
    }
    let files = [
        ("work/photo.png", 30),
        ("work/scan.jpg", 30),
        ("work/notes.txt", 3),
        ("work/report.txt", 3),
        ("work/build.zig", 3),
    ];
    for (f, size) in files {
        fs::write(root.join(f), vec![0u8; size]).expect("the chooser fixture");
    }
    let at = SystemTime::UNIX_EPOCH + Duration::from_secs(1_791_900_300);
    for p in ["home", "work", "work/src"]
        .into_iter()
        .chain(files.iter().map(|f| f.0))
    {
        let f = File::open(root.join(p)).expect("the chooser fixture");
        f.set_times(FileTimes::new().set_modified(at).set_accessed(at))
            .expect("the chooser fixture");
    }
    root
}

/// Firefox's Save Page As, as the Zig build's tests made it: its four filters and a
/// suggested name, in `work`.
pub fn firefox_save(root: &Path) -> crate::chooser::Request {
    use crate::chooser::{Filter, Kind, Request};
    let mut r = Request::new(Kind::Save);
    r.folder = Some(root.join("work"));
    r.current_name = "New Tab.html".into();
    for (name, glob) in [
        ("Web Page, complete", "*.html"),
        ("Web Page, HTML only", "*.htm"),
        ("Text Files", "*.txt"),
        ("All Files", "*"),
    ] {
        r.filters.push(Filter {
            name: name.into(),
            rules: vec![(0, glob.into())],
            types: strider_core::model::TypeFilter {
                globs: vec![glob.into()],
                mimes: Vec::new(),
            },
        });
    }
    r
}

/// The Zig build's chooser goldens: a chooser window for a request, with keys pressed in it.
fn add_choosers(app: &mut App<Strider>) {
    use crate::chooser::{Choice, Filter, Kind, Request};
    type Make = fn(&Path) -> Request;
    let open: Make = |root| {
        let mut r = Request::new(Kind::Open);
        r.folder = Some(root.join("work"));
        r
    };
    let picture: Make = |root| {
        let mut r = Request::new(Kind::Open);
        r.folder = Some(root.join("work"));
        r.title = "Insert a picture".into();
        r.accept_label = "Insert".into();
        r
    };
    let filters: Make = |root| {
        let mut r = Request::new(Kind::Open);
        r.folder = Some(root.join("work"));
        let filter = |name: &str, rules: &[(u32, &str)]| Filter {
            name: name.into(),
            rules: rules.iter().map(|(k, p)| (*k, (*p).to_owned())).collect(),
            types: strider_core::model::TypeFilter {
                globs: rules
                    .iter()
                    .filter(|r| r.0 == 0)
                    .map(|r| r.1.to_lowercase())
                    .collect(),
                mimes: rules
                    .iter()
                    .filter(|r| r.0 == 1)
                    .map(|r| r.1.to_owned())
                    .collect(),
            },
        };
        r.filters = vec![
            filter("Images", &[(0, "*.PNG"), (1, "image/jpeg")]),
            filter("Text", &[(0, "*.txt")]),
        ];
        r.choices = vec![
            Choice {
                id: "size".into(),
                label: "Size".into(),
                options: vec![
                    ("small".into(), "Small".into()),
                    ("large".into(), "Large".into()),
                ],
                initial: "large".into(),
            },
            Choice {
                id: "link".into(),
                label: "Link instead of copying".into(),
                options: Vec::new(),
                initial: "false".into(),
            },
        ];
        r
    };
    let save: Make = |root| {
        let mut r = Request::new(Kind::Save);
        r.folder = Some(root.join("work"));
        r.title = "Save the report".into();
        r.current_name = "report.txt".into();
        r
    };
    let save_as: Make = |root| {
        let mut r = firefox_save(root);
        r.title = "Save As".into();
        r
    };
    let scenes: [(&str, Make, &str); 7] = [
        ("chooser-open", picture, "fph"),
        ("chooser-filters", filters, ""),
        ("chooser-save", save, ""),
        ("chooser-normal", firefox_save, "<Esc>"),
        ("chooser-open-insert", open, "i"),
        ("chooser-narrow", save_as, ""),
        ("chooser-half", save_as, ""),
    ];
    for (name, make, keys) in scenes {
        app.scene_app(name, move || {
            let root = chooser_fixture(name);
            let (mut app, mut s) = crate::base(
                root.clone(),
                Config::default(),
                Zone::utc(),
                true,
                None,
                None,
            )?;
            let window = crate::chooser::open_in(&mut app, &mut s, make(&root))?;
            // Once the window has laid out and taken its focus, as a user's keys come.
            let header = s.ui.header;
            app.update(window, |tx| {
                let mut pressed = false;
                app::on(tx, header, Resize, move |s: &mut Strider, tx, _| {
                    if std::mem::replace(&mut pressed, true) {
                        return Ok(());
                    }
                    press(s, tx, keys)
                })
            })?;
            Ok((app, s))
        });
    }
}

/// The Zig build's goldens of the pointer, the narrow window, and the status line's error:
/// a drag over a folder and its card, a header link and a tab's close button under the
/// pointer, each as its test left the window, with the pointer's state set as it would be.
fn add_pointer(app: &mut App<Strider>) {
    use crate::dnd::{self, Action, Target};
    // build.zig dragged onto docs in the current column: docs outlined, the hint.
    fn over_docs(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
        press(s, tx, "fbu")?;
        dnd::start(s, tx, Point::new(200.0, 175.0))?;
        dnd::hide_card(s, tx)?;
        let pos = s.cur().position_of(b"docs").ok_or(Error::Other("docs"))?;
        let docs = s.cwd.join("docs");
        dnd::hover(s, tx, Target::Row(app::Col::Current, pos), docs)?;
        Ok(())
    }
    app.scene_app("drag-over-folder", || {
        let (mut app, mut s) = sample_prepared("drag-over-folder", "work", |_| Ok(()))?;
        let window = s.window;
        app.update(window, |tx| over_docs(&mut s, tx))?;
        Ok((app, s))
    });
    // The card alone, with what a drop on docs does: `--keywork-size 148x28`.
    app.scene_app("drag-icon", || {
        let (mut app, mut s) = sample_prepared("drag-icon", "work", |_| Ok(()))?;
        let window = s.window;
        app.update(window, |tx| {
            over_docs(&mut s, tx)?;
            dnd::show_card(&mut s, tx, Some(Action::Move))?;
            let card = s.ui.dnd.card;
            let root = tx.root();
            let others: Vec<_> = tx.children(root)?.filter(|&n| n != card.any()).collect();
            for n in others {
                tx.set_hidden(n, true)?;
            }
            tx.update_style(card, |st| {
                st.position = keywork::tree::Position::Absolute(keywork::tree::Anchors {
                    left: Some(0.0),
                    top: Some(0.0),
                    ..Default::default()
                });
            })
        })?;
        Ok((app, s))
    });
    // The path reads "~/src/"; the pointer on "~".
    app.scene_app("crumb-hover", || {
        let (mut app, mut s) = sample("crumb-hover", "work/src")?;
        let window = s.window;
        app.update(window, |tx| crate::crumbs::hover(&mut s, tx, 0, true))?;
        Ok((app, s))
    });
    // Three tabs, the second active; the pointer on the third's close button.
    app.scene_app("tab-close-hover", || {
        let (mut app, mut s) = sample("tab-close-hover", "work")?;
        let window = s.window;
        app.update(window, |tx| {
            press(&mut s, tx, "gnfsrlgnhfdoclgT")?;
            s.hover = Some(2);
            s.close_hover = Some(2);
            crate::tabs::style(&s, tx, 2)
        })?;
        Ok((app, s))
    });
    // `--keywork-size 600x560`: the parent column gives way first.
    app.scene_app("narrow", || {
        let (mut app, mut s) = sample("narrow", "work/src")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "hl"))?;
        Ok((app, s))
    });
    app.scene_app("status-error", || {
        let (mut app, mut s) = sample("status-error", "work")?;
        let window = s.window;
        app.update(window, |tx| press(&mut s, tx, "/zzz<CR>"))?;
        Ok((app, s))
    });
}
