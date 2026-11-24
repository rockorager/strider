//! Opening files and running commands: the default application from the desktop entries and
//! mimeapps.list, an application or a command to open with, shell commands on the targets,
//! the user's terminal, and renaming the targets in $EDITOR.
//!
//! Applications start detached, in a process group of their own, with an activation token
//! from the window when the compositor gives one, so their windows may take focus.

use std::ffi::OsString;
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;

use keywork::desktop::apps::{AppId, Applications};
use keywork::desktop::basedir::BaseDirs;
use keywork::desktop::desktop_entry::{Locale, Target};
use keywork::desktop::icon::{Icon as ThemeIcon, IconFormat, IconTheme};
use keywork::desktop::launch::spawn_detached;
use keywork::desktop::mime::MimeDb;
use keywork::prelude::*;
use strider_core::model::{self, Kind};
use strider_core::rename;

use crate::app::{self, Strider};
use crate::{commands, menu, ops, preview};

/// The most of a shell command's output kept to show.
const MAX_OUTPUT: usize = 64 * 1024;

/// Terminals for a command line (`-t`, an editor), with the arguments before the command, in
/// the order they are looked for on `$PATH`.
const SHELL_TERMINALS: &[&[&str]] = &[
    &["foot", "--"],
    &["alacritty", "-e"],
    &["kitty", "--"],
    &["wezterm", "start", "--"],
    &["ghostty", "-e"],
    &["gnome-terminal", "--wait", "--"],
    &["konsole", "-e"],
    &["xterm", "-e"],
];

/// Terminals for `Terminal=true` applications and `:terminal`, as the Zig build's apps.zig
/// knew them: a few more, and gnome-terminal without `--wait`, as nothing waits for them.
const APP_TERMINALS: &[&[&str]] = &[
    &["foot", "--"],
    &["alacritty", "-e"],
    &["kitty", "--"],
    &["wezterm", "start", "--"],
    &["ghostty", "-e"],
    &["gnome-terminal", "--"],
    &["ptyxis", "--"],
    &["konsole", "-e"],
    &["xfce4-terminal", "-x"],
    &["xterm", "-e"],
];

// --- Opening -------------------------------------------------------------------------------

/// `l` on a file, and `open`: one folder opens in place; files open with their default
/// applications, each application getting all of its files at once; files without one ask
/// which to use.
pub fn open_targets(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let paths = app::targets(s);
    if let [one] = paths.as_slice() {
        let cur = s.cur().current().copied();
        if s.cur().current_path().as_ref() == Some(one) {
            if cur.is_some_and(|e| e.kind == Kind::Dir) {
                return app::cd(s, tx, one.clone(), None, true);
            }
        } else if one.is_dir() {
            return app::cd(s, tx, one.clone(), None, true);
        }
    }
    if paths.is_empty() {
        return Ok(());
    }
    with_apps(s, tx, move |s, tx, apps| {
        let db = s.db.clone();
        let apps2 = apps.clone();
        work(
            s,
            tx,
            move || resolve(&apps2, &db, paths),
            move |s, tx, (groups, orphans): (Vec<(AppId, Vec<PathBuf>)>, Vec<PathBuf>)| {
                for (app, paths) in groups {
                    launch(s, tx, &apps, app, &paths)?;
                }
                if orphans.is_empty() {
                    return Ok(());
                }
                open_with_menu(s, tx, orphans)
            },
        )
    })
}

/// Each path's default application, the paths grouped by it in the order they came, and the
/// paths no application opens.
fn resolve(
    apps: &Applications,
    db: &MimeDb,
    paths: Vec<PathBuf>,
) -> (Vec<(AppId, Vec<PathBuf>)>, Vec<PathBuf>) {
    let mut groups: Vec<(AppId, Vec<PathBuf>)> = Vec::new();
    let mut orphans = Vec::new();
    for p in paths {
        let Some(app) = apps.default_for(&mime_of(db, &p), db) else {
            orphans.push(p);
            continue;
        };
        match groups.iter_mut().find(|(a, _)| *a == app) {
            Some((_, list)) => list.push(p),
            None => groups.push((app, vec![p])),
        }
    }
    (groups, orphans)
}

/// The MIME type of the file at `path`: from its name, and when that is not enough, its
/// first bytes.
fn mime_of(db: &MimeDb, path: &Path) -> String {
    if path.is_dir() {
        return "inode/directory".into();
    }
    let mut head = Vec::new();
    if let Ok(f) = std::fs::File::open(path) {
        let _ = f.take(4096).read_to_end(&mut head);
    }
    db.guess(path, Some(&head)).mime.to_owned()
}

/// Runs `f` with the installed applications, reading them on a worker the first time.
fn with_apps<F>(s: &mut Strider, tx: &mut Txn<'_, Strider>, f: F) -> Result<()>
where
    F: for<'t> FnOnce(&mut Strider, &mut Txn<'t, Strider>, Arc<Applications>) -> Result<()>
        + 'static,
{
    if let Some(apps) = s.apps.clone() {
        return f(s, tx, apps);
    }
    let (dirs, db) = (base_dirs(s), s.db.clone());
    work(
        s,
        tx,
        move || Arc::new(Applications::load(&dirs, &db)),
        move |s, tx, apps: Arc<Applications>| {
            let apps = s.apps.get_or_insert(apps).clone();
            f(s, tx, apps)
        },
    )
}

/// Where applications and mimeapps.list are read from. Tests and scenes, which keep no
/// state, see only the sample home's, so they never start what is installed.
fn base_dirs(s: &Strider) -> BaseDirs {
    if s.state_dir.is_some() {
        return BaseDirs::from_env();
    }
    let home = s.home.clone().into_os_string();
    let mut dirs = BaseDirs::from_vars(|v| (v == "HOME").then(|| home.clone()));
    dirs.data_dirs.clear();
    dirs.config_dirs.clear();
    dirs
}

/// Runs `job` on a worker and `land` with its result, or both at once for scenes and tests
/// that read synchronously.
fn work<T, J, D>(s: &mut Strider, tx: &mut Txn<'_, Strider>, job: J, land: D) -> Result<()>
where
    T: Send + 'static,
    J: FnOnce() -> T + Send + 'static,
    D: for<'t> FnOnce(&mut Strider, &mut Txn<'t, Strider>, T) -> Result<()> + 'static,
{
    if s.sync_reads {
        return land(s, tx, job());
    }
    tx.spawn_blocking(job, app::here(land));
    Ok(())
}

/// Starts `app` on `paths`, in the user's terminal when its entry asks for one.
fn launch(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    apps: &Applications,
    app: AppId,
    paths: &[PathBuf],
) -> Result<()> {
    let entry = apps.get(app);
    let locale = Locale::from_env();
    let name = entry.name(&locale).unwrap_or(entry.id()).to_owned();
    let targets: Vec<Target<'_>> = paths.iter().map(|p| Target::Path(p)).collect();
    let mut argvs = match entry.exec_argvs(&targets, &locale) {
        Ok(a) => a,
        Err(e) => return say(s, tx, format!("Could not start {name}: {e}"), true),
    };
    if entry.terminal() {
        let term = terminal_for_app(env_terminal().as_deref(), on_path);
        for argv in &mut argvs {
            argv.splice(0..0, term.iter().map(OsString::from));
        }
    }
    let cwd = paths
        .first()
        .map_or_else(|| s.home.clone(), |p| model::parent(p).to_owned());
    spawn(tx, argvs, cwd, name);
    Ok(())
}

/// Starts each argument vector detached in `cwd`, once the window has an activation token
/// for them (or the compositor says it gives none); `name` is for the error.
fn spawn(tx: &mut Txn<'_, Strider>, argvs: Vec<Vec<OsString>>, cwd: PathBuf, name: String) {
    tx.activation_token(app::here(move |s, tx, token: Option<String>| {
        for argv in &argvs {
            if spawn_detached(argv, Some(&cwd), token.as_deref()).is_err() {
                return say(s, tx, format!("Could not start {name}"), true);
            }
        }
        Ok(())
    }));
}

/// Says `text` in the status line.
fn say(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    text: impl Into<String>,
    error: bool,
) -> Result<()> {
    s.notify(text, error);
    app::draw_status(s, tx)
}

/// `:open-with`: with an application's desktop file ID, or else a command line that gets the
/// targets as `$@`; without, the menu of applications that open them.
pub fn open_with(s: &mut Strider, tx: &mut Txn<'_, Strider>, arg: &str) -> Result<()> {
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    if arg.is_empty() {
        return open_with_menu(s, tx, paths);
    }
    let arg = arg.to_owned();
    with_apps(s, tx, move |s, tx, apps| match apps.find(&arg) {
        Some(app) => launch(s, tx, &apps, app, &paths),
        None => run_shell_args(s, tx, &format!("{arg} \"$@\" &"), &paths, How::Detached),
    })
}

/// The menu of applications that open the first of `paths`, at the cursor: its default,
/// then those for its type and its supertypes, or every application when none is. A folder
/// opens in a terminal first.
pub fn open_with_menu(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: Vec<PathBuf>,
) -> Result<()> {
    with_apps(s, tx, move |s, tx, apps| {
        let mime = mime_of(&s.db, &paths[0]);
        let folder = mime == "inode/directory";
        let list = apps_for(&apps, &s.db, &mime);
        if list.is_empty() && !folder {
            return say(s, tx, "No applications found", true);
        }
        let locale = Locale::from_env();
        let names: Vec<String> = list
            .iter()
            .map(|&a| {
                let e = apps.get(a);
                e.name(&locale).unwrap_or(e.id()).to_owned()
            })
            .collect();
        // The terminal's icon for a folder's first item, then each application's.
        let icons: Vec<String> = folder
            .then(|| "utilities-terminal".to_owned())
            .into_iter()
            .chain(
                list.iter()
                    .map(|&a| apps.get(a).icon(&locale).unwrap_or_default().to_owned()),
            )
            .collect();
        let theme = s.icons.as_ref().map(|i| Arc::clone(i.theme()));
        let chosen = move |s: &mut Strider, tx: &mut Txn<'_, Strider>, i: usize| match (folder, i) {
            (true, 0) => open_terminal(s, tx, &paths[0]),
            _ => match list.get(i - usize::from(folder)) {
                Some(&app) => launch(s, tx, &apps, app, &paths),
                None => Ok(()),
            },
        };
        work(
            s,
            tx,
            move || app_icons(theme.as_deref(), &icons),
            move |s, tx, icons| menu::open_with(s, tx, folder, &names, icons, chosen),
        )
    })
}

/// The icons the open-with menu shows, by the names applications' entries give: found in
/// `theme` in their own colors, as the Zig build's menu showed them, or read from the file a
/// path names; none where there is no such icon. It reads files, so it runs on a worker.
fn app_icons(theme: Option<&IconTheme>, names: &[String]) -> Vec<Option<ThemeIcon>> {
    let one = |name: &str| {
        let path = Path::new(name);
        let (path, format) = if path.is_absolute() {
            let format = match path.extension().and_then(|e| e.to_str()) {
                Some("png") => IconFormat::Png,
                Some("svg" | "svgz") => IconFormat::Svg,
                _ => return None,
            };
            (path.to_owned(), format)
        } else {
            let theme = theme.filter(|_| !name.is_empty())?;
            // Twice the menu's 16 px, for scale-2 outputs.
            let file = theme.lookup(&[name], 16, 2)?;
            (theme.path(file), theme.format(file))
        };
        ThemeIcon::load(&path, format).ok()
    };
    names.iter().map(|n| one(n)).collect()
}

/// The applications the open-with menu lists for `mime`: its default first, then those
/// associated with it or a supertype that menus show; failing any, every application menus
/// show, by name.
fn apps_for(apps: &Applications, db: &MimeDb, mime: &str) -> Vec<AppId> {
    let mut list: Vec<AppId> = apps.default_for(mime, db).into_iter().collect();
    let mut more = Vec::new();
    apps.open_with(mime, db, &mut more);
    for a in more {
        if !list.contains(&a) && !apps.get(a).no_display() {
            list.push(a);
        }
    }
    if list.is_empty() && mime != "inode/directory" {
        let locale = Locale::from_env();
        let name = |a: &AppId| {
            let e = apps.get(*a);
            e.name(&locale).unwrap_or(e.id()).to_lowercase()
        };
        list = apps.iter().filter(|&a| !apps.get(a).no_display()).collect();
        list.sort_by_cached_key(name);
    }
    list
}

// --- Terminals -----------------------------------------------------------------------------

fn env_terminal() -> Option<String> {
    std::env::var("TERMINAL").ok()
}

fn on_path(prog: &str) -> bool {
    keywork::desktop::desktop_entry::find_executable(prog)
}

/// The terminal a command line runs in, with the arguments before the command: the
/// `terminal` option, else `$TERMINAL`, else the first of [`SHELL_TERMINALS`] on `$PATH`.
pub fn terminal_command(
    option: &str,
    env: Option<&str>,
    on_path: impl Fn(&str) -> bool,
) -> Vec<String> {
    if !option.is_empty() {
        return split_exec(option);
    }
    if let Some(parts) = env.map(split_exec).filter(|p| !p.is_empty()) {
        return parts;
    }
    let found = SHELL_TERMINALS.iter().find(|k| on_path(k[0]));
    owned(found.copied().unwrap_or(&["xterm", "-e"]))
}

/// The user's terminal by itself, to open in a folder: the `terminal` option, else
/// `$TERMINAL`, each without the arguments before a command; else xdg-terminal-exec, else the
/// first of [`APP_TERMINALS`] on `$PATH`.
pub fn terminal_alone(
    option: &str,
    env: Option<&str>,
    on_path: impl Fn(&str) -> bool,
) -> Vec<String> {
    let given = if option.is_empty() {
        env.unwrap_or("")
    } else {
        option
    };
    let alone: Vec<String> = split_exec(given)
        .into_iter()
        .take_while(|x| !["--", "-e", "-x", "start"].contains(&x.as_str()))
        .collect();
    if !alone.is_empty() {
        return alone;
    }
    if on_path("xdg-terminal-exec") {
        return owned(&["xdg-terminal-exec"]);
    }
    let found = APP_TERMINALS.iter().find(|k| on_path(k[0]));
    owned(&[found.map_or("xterm", |k| k[0])])
}

/// The terminal a `Terminal=true` application runs in: `$TERMINAL`, with the argument its
/// terminal takes before a command (`-e` for one not known) unless it carries arguments of
/// its own; else xdg-terminal-exec, else the first of [`APP_TERMINALS`] on `$PATH`.
pub fn terminal_for_app(env: Option<&str>, on_path: impl Fn(&str) -> bool) -> Vec<String> {
    let mut words = env
        .unwrap_or("")
        .split([' ', '\t'])
        .filter(|w| !w.is_empty());
    if let Some(prog) = words.next() {
        let mut out = vec![prog.to_owned()];
        out.extend(words.map(str::to_owned));
        if out.len() > 1 {
            return out;
        }
        let base = prog.rsplit('/').next().unwrap_or(prog);
        match APP_TERMINALS.iter().find(|k| k[0] == base) {
            Some(k) => out.extend(owned(&k[1..])),
            None => out.push("-e".into()),
        }
        return out;
    }
    if on_path("xdg-terminal-exec") {
        return owned(&["xdg-terminal-exec"]);
    }
    owned(
        APP_TERMINALS
            .iter()
            .find(|k| on_path(k[0]))
            .copied()
            .unwrap_or(&["xterm", "-e"]),
    )
}

fn owned(words: &[&str]) -> Vec<String> {
    words.iter().map(|&w| w.to_owned()).collect()
}

/// `:terminal [folder]`: the user's terminal in the folder shown, or that one.
pub fn terminal(s: &mut Strider, tx: &mut Txn<'_, Strider>, folder: Option<PathBuf>) -> Result<()> {
    let folder = folder.unwrap_or_else(|| s.cur().path.clone());
    open_terminal(s, tx, &folder)
}

fn open_terminal(s: &mut Strider, tx: &mut Txn<'_, Strider>, folder: &Path) -> Result<()> {
    let argv = terminal_alone(&s.options.terminal, env_terminal().as_deref(), on_path);
    let argv = argv.into_iter().map(OsString::from).collect();
    spawn(tx, vec![argv], folder.to_owned(), "a terminal".into());
    Ok(())
}

/// Splits a command line as a desktop entry's Exec is split: at spaces and tabs, with double
/// quotes grouping, inside which `\"`, `` \` ``, `\$`, and `\\` escape.
pub fn split_exec(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let (mut quoted, mut has) = (false, false);
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            match c {
                '"' => quoted = false,
                '\\' if chars.peek().is_some_and(|n| "\"`$\\".contains(*n)) => {
                    cur.extend(chars.next());
                }
                _ => cur.push(c),
            }
            continue;
        }
        match c {
            '"' => (quoted, has) = (true, true),
            ' ' | '\t' if has || !cur.is_empty() => {
                out.push(std::mem::take(&mut cur));
                has = false;
            }
            ' ' | '\t' => {}
            _ => cur.push(c),
        }
    }
    if has || !cur.is_empty() {
        out.push(cur);
    }
    out
}

// --- Shell commands ------------------------------------------------------------------------

/// How a shell command runs.
#[derive(Clone, Copy, PartialEq, Eq)]
enum How {
    /// Waited for on a worker, its output shown.
    Output,
    /// In a terminal, which waits for a key once it ends.
    Terminal,
    /// Started and left to run, as `:open-with` a command does.
    Detached,
}

/// `:!cmd` and `:shell [-t] cmd`: runs `cmd` with the shell in the current folder, the
/// targets as `$@` (and `%s`, `%f`, `%d` in the text), and shows what it printed; with `-t`
/// in a terminal.
pub fn run_shell(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    cmd: &str,
    in_terminal: bool,
) -> Result<()> {
    let paths = app::targets(s);
    let how = if in_terminal {
        How::Terminal
    } else {
        How::Output
    };
    run_shell_args(s, tx, cmd, &paths, how)?;
    app::consume_targets(s, tx)
}

/// `:shell [-t] cmd`, or the shell prompt without a command.
pub fn shell(s: &mut Strider, tx: &mut Txn<'_, Strider>, args: &str) -> Result<()> {
    let (term, cmd) = match args.strip_prefix("-t ") {
        Some(rest) => (true, rest.trim_matches(' ')),
        None => (false, args),
    };
    if cmd.is_empty() {
        return crate::prompt::start(s, tx, strider_machines::mode::Prompt::Shell, "", 0, 0);
    }
    run_shell(s, tx, cmd, term)
}

fn run_shell_args(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    cmd: &str,
    paths: &[PathBuf],
    how: How,
) -> Result<()> {
    let cwd = s.cur().path.clone();
    let line = expand(cmd, paths, &cwd);
    let sh = s.options.shell.clone();
    let mut argv: Vec<OsString> = Vec::new();
    if how == How::Terminal {
        let term = terminal_command(&s.options.terminal, env_terminal().as_deref(), on_path);
        argv.extend(term.into_iter().map(OsString::from));
    }
    let line = match how {
        How::Terminal => format!("{line}; printf '\\n[exit %s] ' $?; read -r _"),
        _ => line,
    };
    argv.extend([sh.clone(), "-c".into(), line, sh].map(OsString::from));
    argv.extend(paths.iter().map(|p| p.as_os_str().to_owned()));
    if how != How::Output {
        let what = if how == How::Terminal {
            "a terminal"
        } else {
            "it"
        };
        spawn(tx, vec![argv], cwd, what.into());
        return Ok(());
    }
    let cmd = cmd.to_owned();
    work(
        s,
        tx,
        move || capture(&argv, &cwd),
        move |s, tx, result| show_result(s, tx, &cmd, result),
    )
}

/// What a shell command printed: its last line in the status line, red if it failed, and
/// all of it in the preview; or, when it printed nothing and failed, its exit status.
fn show_result(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    cmd: &str,
    result: io::Result<(u8, Vec<u8>)>,
) -> Result<()> {
    let Ok((status, out)) = result else {
        return say(s, tx, "The shell could not run", true);
    };
    let out = String::from_utf8_lossy(&out);
    let out = out.trim_end_matches('\n');
    if out.is_empty() {
        if status != 0 {
            return say(s, tx, format!("“{cmd}” exited with {status}"), true);
        }
        return Ok(());
    }
    let last = out.rsplit('\n').next().unwrap_or(out);
    s.notify(last, status != 0);
    preview::show_output(s, tx, cmd, out, Vec::new())?;
    app::draw_status(s, tx)
}

/// Runs `argv` in `cwd` to its end, with standard input from /dev/null, and returns its exit
/// status (128 and the signal for one that killed it) and the first [`MAX_OUTPUT`] bytes it
/// wrote to standard output and error together.
fn capture(argv: &[OsString], cwd: &Path) -> io::Result<(u8, Vec<u8>)> {
    let (mut reader, writer) = io::pipe()?;
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..])
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer);
    let mut child = cmd.spawn()?;
    // The command holds the pipe's writing end, which would keep the read from ending.
    drop(cmd);
    let mut out = Vec::new();
    (&mut reader)
        .take(MAX_OUTPUT as u64)
        .read_to_end(&mut out)?;
    // Drain the rest, so a long output does not block the command.
    io::copy(&mut reader, &mut io::sink())?;
    let status = child.wait()?;
    use std::os::unix::process::ExitStatusExt;
    let code = status
        .code()
        .map_or_else(|| 128 + status.signal().unwrap_or(0) as u8, |c| c as u8);
    Ok((code, out))
}

/// `cmd` with `%s` the targets, `%f` the first, and `%d` the current folder, each quoted for
/// the shell; any other `%` stays as typed.
pub fn expand(cmd: &str, paths: &[PathBuf], cwd: &Path) -> String {
    let mut out = String::with_capacity(cmd.len());
    let mut chars = cmd.chars().peekable();
    while let Some(c) = chars.next() {
        let which = match chars.peek() {
            Some(&w @ ('s' | 'f' | 'd')) if c == '%' => w,
            _ => {
                out.push(c);
                continue;
            }
        };
        chars.next();
        let quoted: Vec<String> = match which {
            'd' => vec![quote(cwd)],
            'f' => paths.iter().take(1).map(|p| quote(p)).collect(),
            _ => paths.iter().map(|p| quote(p)).collect(),
        };
        out.push_str(&quoted.join(" "));
    }
    out
}

/// `path` in single quotes for the shell, a quote in it as `'\''`.
fn quote(path: &Path) -> String {
    let text = String::from_utf8_lossy(path.as_os_str().as_bytes());
    format!("'{}'", text.replace('\'', "'\\''"))
}

// --- Bulk rename ---------------------------------------------------------------------------

/// `:bulk-rename`: the targets' names, one a line, in the editor; when it closes, line `i`
/// is target `i`'s new name.
pub fn bulk_rename(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let paths = app::targets(s);
    if paths.is_empty() {
        return Ok(());
    }
    let mut body = Vec::new();
    for p in &paths {
        let name = model::basename(p);
        if name.contains(&b'\n') {
            return say(
                s,
                tx,
                "Names with line breaks cannot be renamed in an editor",
                true,
            );
        }
        body.extend_from_slice(name);
        body.push(b'\n');
    }
    let tmp = ["XDG_RUNTIME_DIR", "TMPDIR"]
        .iter()
        .find_map(std::env::var_os)
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let file = tmp.join(format!("strider-rename-{}-{nanos}.txt", std::process::id()));
    if write_private(&file, &body).is_err() {
        return say(s, tx, "Could not write the list of names", true);
    }
    let editor = if s.options.editor.is_empty() {
        ["VISUAL", "EDITOR"]
            .iter()
            .find_map(|v| std::env::var(v).ok())
            .unwrap_or_else(|| "vi".into())
    } else {
        s.options.editor.clone()
    };
    let mut argv: Vec<String> = Vec::new();
    if s.options.editor_in_terminal {
        argv = terminal_command(&s.options.terminal, env_terminal().as_deref(), on_path);
    }
    argv.extend(split_exec(&editor));
    let mut argv: Vec<OsString> = argv.into_iter().map(OsString::from).collect();
    argv.push(file.clone().into_os_string());
    app::consume_targets(s, tx)?;
    s.notify(
        "Editing the names: save and quit the editor to rename",
        false,
    );
    app::draw_status(s, tx)?;
    let edit = move || {
        let status = Command::new(&argv[0])
            .args(&argv[1..])
            .stdout(Stdio::null())
            .status();
        let edited = std::fs::read(&file).ok();
        let _ = std::fs::remove_file(&file);
        (status.is_ok_and(|st| st.success()), edited)
    };
    let land = move |s: &mut Strider, tx: &mut Txn<'_, Strider>, (ok, edited)| {
        let text: Option<Vec<u8>> = edited;
        match (ok, text) {
            (false, _) => say(s, tx, "The editor failed; nothing was renamed", true),
            (true, None) => say(s, tx, "The list could not be read back", true),
            (true, Some(text)) => apply_bulk(s, tx, &paths, &text),
        }
    };
    tx.spawn_blocking(edit, app::here(land));
    Ok(())
}

fn write_private(path: &Path, data: &[u8]) -> io::Result<()> {
    use std::io::Write;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?
        .write_all(data)
}

/// Renames `paths` as the edited list `text` says, all or none: each changed name goes
/// through a temporary one, so names can swap.
fn apply_bulk(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    paths: &[PathBuf],
    text: &[u8],
) -> Result<()> {
    let pairs = match bulk_pairs(paths, text) {
        Ok(p) => p,
        Err(why) => return say(s, tx, why, true),
    };
    if pairs.is_empty() {
        return say(s, tx, "No names changed", false);
    }
    let renamed = ops::rename_many(&pairs);
    for (from, now) in &renamed.stranded {
        s.log_message(
            &format!("{} is left as {}", from.display(), now.display()),
            true,
        );
    }
    // The renames that took effect, undone together.
    s.ops.undo.push_renames(renamed.done.clone());
    if let Some((text, error)) = renamed.message() {
        s.notify(text, error);
    }
    commands::execute(s, tx, "reload", None, false)
}

/// The renames an edited list asks for, as (from, to) pairs of the names that changed, or
/// why none is done: a line count that does not match, an invalid name, or a name two items
/// or another file would share.
pub fn bulk_pairs(
    paths: &[PathBuf],
    text: &[u8],
) -> std::result::Result<Vec<(PathBuf, PathBuf)>, String> {
    let end = text.iter().rposition(|&c| c != b'\n').map_or(0, |i| i + 1);
    let text = &text[..end];
    let names: Vec<&[u8]> = text.split(|&c| c == b'\n').collect();
    if names.len() != paths.len() {
        return Err(format!(
            "The list has {} lines for {} names; nothing was renamed",
            names.len(),
            paths.len()
        ));
    }
    if let Some(why) = rename::check(paths, &names) {
        return Err(format!("{why}; nothing was renamed"));
    }
    Ok(paths
        .iter()
        .zip(names)
        .filter(|(p, n)| model::basename(p) != *n)
        .map(|(p, n)| (p.clone(), model::join(model::parent(p), n)))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    // %s is every target and %f the first, %d the folder, each quoted so a name with spaces
    // or a quote stays one word; any other % is left alone.
    #[test]
    fn expansion_quotes_targets() {
        let paths = [PathBuf::from("/w/a b"), PathBuf::from("/w/it's")];
        let cwd = Path::new("/w");
        assert_eq!(
            expand("tar czf x.tgz %s", &paths, cwd),
            r"tar czf x.tgz '/w/a b' '/w/it'\''s'"
        );
        assert_eq!(
            expand("echo %f in %d", &paths, cwd),
            "echo '/w/a b' in '/w'"
        );
        assert_eq!(expand("date +%Y%% 100%", &paths, cwd), "date +%Y%% 100%");
        assert_eq!(expand("echo %s", &[], cwd), "echo ");
    }

    // The option beats $TERMINAL, which beats what is on $PATH, found in the Zig build's
    // order; `:terminal` drops the arguments before a command.
    #[test]
    fn terminal_fallback_order() {
        let has = |names: &'static [&'static str]| move |p: &str| names.contains(&p);
        assert_eq!(
            terminal_command("kitty --", Some("foot"), has(&["xterm"])),
            ["kitty", "--"]
        );
        assert_eq!(
            terminal_command("", Some("foot -e"), has(&[])),
            ["foot", "-e"]
        );
        assert_eq!(
            terminal_command("", None, has(&["xterm", "kitty", "alacritty"])),
            ["alacritty", "-e"]
        );
        assert_eq!(terminal_command("", Some(""), has(&[])), ["xterm", "-e"]);
        assert_eq!(
            terminal_alone("wezterm start --", None, has(&[])),
            ["wezterm"]
        );
        assert_eq!(
            terminal_alone("", None, has(&["foot", "xdg-terminal-exec"])),
            ["xdg-terminal-exec"]
        );
        assert_eq!(
            terminal_for_app(Some("/usr/bin/kitty"), has(&[])),
            ["/usr/bin/kitty", "--"]
        );
        assert_eq!(terminal_for_app(Some("st"), has(&[])), ["st", "-e"]);
        assert_eq!(terminal_for_app(None, has(&["konsole"])), ["konsole", "-e"]);
    }

    #[test]
    fn exec_lines_split_with_quotes() {
        assert_eq!(
            split_exec(r#"env "A B" prog --flag="x\"y" "" end"#),
            ["env", "A B", "prog", "--flag=x\"y", "", "end"]
        );
    }

    // A list must keep its line count; invalid names, two items getting one name, and a
    // name another file has refuse the whole batch; unchanged lines rename nothing, and two
    // items may swap names.
    #[test]
    fn bulk_lists_parse_and_refuse_collisions() {
        let dir = std::env::temp_dir().join(format!("strider-bulk-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for n in ["a", "b", "other"] {
            std::fs::write(dir.join(n), "").unwrap();
        }
        let paths = [dir.join("a"), dir.join("b")];
        let pairs = |t: &str| bulk_pairs(&paths, t.as_bytes());
        assert_eq!(pairs("a\nc\n").unwrap(), [(dir.join("b"), dir.join("c"))]);
        assert_eq!(
            pairs("b\na").unwrap(),
            [
                (dir.join("a"), dir.join("b")),
                (dir.join("b"), dir.join("a"))
            ]
        );
        assert!(pairs("a\nb\n").unwrap().is_empty());
        assert!(pairs("a\n").unwrap_err().contains("1 lines for 2 names"));
        assert!(pairs("a\nb\nc\n").is_err());
        assert!(pairs("x\nx\n").unwrap_err().contains("same name"));
        assert!(pairs("a\nother\n").unwrap_err().contains("taken"));
        assert!(pairs("a\nx/y\n").is_err());
        assert!(pairs("a\n\n").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The menu lists the default first, then the rest for the type, without the entries
    // menus hide; a type nothing opens lists every shown application by name.
    #[test]
    fn open_with_lists_the_default_first() {
        let root = std::env::temp_dir().join(format!("strider-apps-{}", std::process::id()));
        let (config, data) = (root.join("config"), root.join("applications"));
        std::fs::create_dir_all(&config).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        let entry = |id: &str, name: &str, extra: &str| {
            let text = format!(
                "[Desktop Entry]\nType=Application\nName={name}\nExec=true %F\nMimeType=text/plain;\n{extra}"
            );
            std::fs::write(data.join(id), text).unwrap();
        };
        entry("editor.desktop", "Editor", "");
        entry("viewer.desktop", "Viewer", "");
        entry("helper.desktop", "Helper", "NoDisplay=true\n");
        std::fs::write(
            config.join("mimeapps.list"),
            "[Default Applications]\ntext/plain=viewer.desktop;\n",
        )
        .unwrap();
        let db = MimeDb::from_dirs(Vec::<PathBuf>::new());
        let apps =
            Applications::load_from(&[config.as_path()], std::slice::from_ref(&data), &[], &db);
        let ids = |list: Vec<AppId>| -> Vec<String> {
            list.iter().map(|&a| apps.get(a).id().to_owned()).collect()
        };
        assert_eq!(
            ids(apps_for(&apps, &db, "text/plain")),
            ["viewer.desktop", "editor.desktop"]
        );
        assert_eq!(
            ids(apps_for(&apps, &db, "application/x-nothing")),
            ["editor.desktop", "viewer.desktop"]
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
