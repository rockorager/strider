//! One instance serves every window, as in the Zig build: a later launch hands its folders,
//! as URIs, to the instance that runs and exits, through Keywork's
//! `org.freedesktop.Application` on the session bus. What each activation opens, the
//! `new-window` action, and running as a D-Bus activated service with an idle timeout.

use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use keywork::prelude::*;
use keywork::{Activation, KeepRunning, Timer};
use strider_core::{model, uri};

use crate::app::{self, Strider};

/// The app id, and the bus name the one instance owns.
pub const APP_ID: &str = "dev.rockorager.Strider";

/// How long a service waits for a window after its last activation before it exits, as the
/// Zig build's.
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(30);

/// How this process was started, which activations and the last window's closing heed.
#[derive(Default)]
pub struct Launch {
    /// `--new-window`: a window for this launch even when one is open.
    pub new_window: bool,
    /// `--service`: started by D-Bus activation, with no window until asked for one.
    pub service: bool,
    /// What keeps a service running with no window open until its first window opens, and
    /// the timer that lets it go when no window came.
    keep: Option<KeepRunning>,
    idle: Option<Timer>,
}

/// Runs `app` as a D-Bus activated service: with no window open until a call asks for one,
/// for as long as the idle timeout after its last activation, or until its windows close.
pub fn serve(app: &mut App<Strider>, s: &mut Strider) {
    s.launch.service = true;
    s.launch.keep = Some(app.keep_running());
}

/// Gives `app` what activations do, and the `new-window` action (the desktop entry's).
pub fn install(app: &mut App<Strider>) {
    app.on_activate(activated);
    app.add_action("new-window", |s: &mut Strider, cx, invoked| {
        let home = s.home.clone();
        let window = app::open_window(s, cx, home, None)?;
        cx.raise(window, invoked.token.as_deref())
    });
    app.on_start(|s: &mut Strider, cx| {
        arm_idle(s, cx);
        Ok(())
    });
}

/// The URIs a launch with `paths` opens: each path resolved against the working folder, as
/// a `file://` URI; what already names a scheme as it is.
pub fn uris(paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .map(|p| {
            if p.contains("://") {
                return p.clone();
            }
            let path = std::fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p));
            let path = std::path::absolute(&path).unwrap_or(path);
            let mut out = String::new();
            uri::push_file_uri(&mut out, &path);
            out
        })
        .collect()
}

/// Every activation: this launch's, another launch's, or the desktop's. URIs open a tab each
/// in the window used last, or a new window with `--new-window`; a plain launch opens a
/// window on the working folder when there is none, with `--new-window`, or for another
/// launch, and otherwise raises the window used last.
fn activated(s: &mut Strider, cx: &mut Cx<'_, Strider>, act: &Activation) -> Result<()> {
    activate(s, cx, &act.uris, act.remote, act.token.as_deref())
}

/// This launch alone, when the session bus could not settle which process runs: its own
/// activation, once the app starts.
pub fn alone(app: &mut App<Strider>, uris: Vec<String>) {
    app.on_start(move |s: &mut Strider, cx| activate(s, cx, &uris, false, None));
}

fn activate(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    uris: &[String],
    remote: bool,
    token: Option<&str>,
) -> Result<()> {
    // A service shows nothing until asked: D-Bus started it for the call that follows.
    if s.launch.service && !remote {
        return Ok(());
    }
    if let Some(timer) = s.launch.idle.take() {
        cx.cancel_timer(timer);
    }
    let window = if !uris.is_empty() {
        let paths: Vec<PathBuf> = uris.iter().filter_map(|u| uri::file_path(u)).collect();
        Some(show_paths(s, cx, &paths, s.launch.new_window && !remote)?)
    } else if s.wins.is_empty() || s.launch.new_window || remote {
        Some(app::open_window(s, cx, current_dir(&s.home), None)?)
    } else {
        s.last_window()
    };
    // This launch's own first window presents its token as it opens.
    if let Some(window) = window
        && remote
    {
        cx.raise(window, token)?;
    }
    arm_idle(s, cx);
    Ok(())
}

/// Shows these folders and files, a file in its folder under the cursor: a tab each in the
/// window used last, or a new window for the first. Returns the window that shows them.
pub fn show_paths(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    paths: &[PathBuf],
    new_window: bool,
) -> Result<WindowId> {
    let mut window = if new_window { None } else { s.last_window() };
    for p in paths {
        match window {
            None => {
                let (dir, select) = folder_of(p);
                window = Some(app::open_window(s, cx, dir, select)?);
            }
            Some(w) => {
                let p = p.clone();
                app::in_window(s, cx, Some(w), |s, tx| crate::tabs::open(s, tx, p))?;
            }
        }
    }
    match window {
        Some(w) => Ok(w),
        None => {
            let home = s.home.clone();
            app::open_window(s, cx, home, None)
        }
    }
}

/// The folder a window on `path` opens, and the name under its cursor: a file's folder,
/// with the file.
pub fn folder_of(path: &Path) -> (PathBuf, Option<Vec<u8>>) {
    let path = model::normalize(path);
    if !path.is_dir() && path.exists() {
        let name = path.file_name().map(|n| n.as_bytes().to_vec());
        (model::parent(&path).to_owned(), name)
    } else {
        (path, None)
    }
}

/// Started from a terminal: its folder; from a launcher, at `/`: home.
pub fn current_dir(home: &Path) -> PathBuf {
    match std::env::current_dir() {
        Ok(d) if d != Path::new("/") => d,
        _ => home.to_owned(),
    }
}

/// A service exits when no window came this long after its last activation: the timer drops
/// what keeps it running.
fn arm_idle(s: &mut Strider, cx: &mut Cx<'_, Strider>) {
    if s.launch.keep.is_none() {
        return;
    }
    if let Some(timer) = s.launch.idle.take() {
        cx.cancel_timer(timer);
    }
    s.launch.idle = Some(cx.after(IDLE_TIMEOUT, |s: &mut Strider, _| {
        s.launch.idle = None;
        s.launch.keep = None;
        Ok(())
    }));
}

/// A window opened: a service is in use, and quits once its last window closes, as the Zig
/// build's did.
pub fn window_opened(s: &mut Strider, cx: &mut Cx<'_, Strider>) {
    if let Some(timer) = s.launch.idle.take() {
        cx.cancel_timer(timer);
    }
    s.launch.keep = None;
}
