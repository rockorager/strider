//! The preview column: what is under the cursor, as soon as the cursor is on it. Folders show
//! their entries from the cache; text files their start with syntax coloring; images decode
//! at the size shown; archives list their entries; PDFs show their first page (poppler's
//! pdftoppm, else MuPDF's mutool) and videos a frame (ffmpegthumbnailer, else ffmpeg); binary
//! files show their start in hex; and other files their details.
//!
//! Everything about a file, down to its type and a link's target, is found in a job on a
//! worker, as the [`preview`](strider_machines::preview) statechart allows: at most two at
//! once, the newest waiting one winning. Each job has a generation: moving on kills the
//! programs it runs and drops its result. Until a job's result comes in, what showed before
//! stays. Scenes run jobs on the UI thread, so they render the same every time.

mod proc;

use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::Read;
use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use keywork::desktop::basedir::BaseDirs;
use keywork::desktop::desktop_entry::Locale;
use keywork::desktop::mime::{MimeDb, read_comment};
use keywork::desktop::thumbnail::{ThumbnailCache, ThumbnailSize};
use keywork::image::{DecodeError, DecodeOptions, Image, decode_image, image_size};
use keywork::prelude::*;
use plusthree::host::NoTimers;
use strider_core::archive;
use strider_core::highlight::{self, Class, Span};
use strider_core::model::{self, Entry, Kind};
use strider_machines::driver::Driver;
use strider_machines::preview::{Preview as Chart, PreviewEv, PreviewFx};

use crate::app::{self, Col, Strider};

pub enum Preview {
    None,
    /// A folder, from the cache.
    Folder(PathBuf),
    /// A text file's start, an archive's entries, or a binary file's start in hex.
    Text(Lines),
    /// Text that is no file, such as a command's output or the help.
    Output {
        title: String,
        lines: Lines,
    },
    /// An image, a PDF's page, or a video's frame, with the file's name, size, and date.
    Image {
        picture: Picture,
        caption: String,
    },
    Info(Info),
}

impl Preview {
    /// Text that is no file, colored by `spans` (byte ranges of `text`), as shell commands
    /// show their output. Show it with [`show_output`].
    pub fn output(title: impl Into<String>, text: impl Into<String>, spans: Vec<Span>) -> Preview {
        Preview::Output {
            title: title.into(),
            lines: Lines::new(text.into(), spans),
        }
    }

    /// The lines a text preview shows.
    pub fn lines(&self) -> Option<&Lines> {
        match self {
            Preview::Text(l) | Preview::Output { lines: l, .. } => Some(l),
            _ => None,
        }
    }
}

/// Text as the preview shows it: its lines, as byte ranges, and its coloring.
pub struct Lines {
    pub text: String,
    pub lines: Vec<Range<usize>>,
    pub spans: Vec<Span>,
}

impl Lines {
    pub fn new(text: String, spans: Vec<Span>) -> Lines {
        let mut lines = Vec::new();
        let mut start = 0;
        for (i, b) in text.bytes().enumerate() {
            if b == b'\n' {
                lines.push(start..i);
                start = i + 1;
            }
        }
        if start < text.len() {
            lines.push(start..text.len());
        }
        Lines { text, lines, spans }
    }
}

pub enum Picture {
    Decoded(Arc<Image>),
    /// An SVG document, which Keywork draws at the size it shows.
    File(PathBuf),
}

/// The details card: a title, lines of a key and a value, and a note under them.
#[derive(Default)]
pub struct Info {
    pub title: String,
    pub rows: Vec<(&'static str, String)>,
    pub note: Option<String>,
}

/// Programs a preview runs are killed after this long.
const PROGRAM_TIMEOUT: Duration = Duration::from_secs(15);
/// How much of a binary file the hex view shows.
const HEX_BYTES: usize = 1024;
/// How many entries of an archive are listed.
const ARCHIVE_LIMIT: usize = 2000;
const OCTET_STREAM: &str = "application/octet-stream";
const UNSUPPORTED: &str = "This image format is not supported";

// --- The job's lifecycle -------------------------------------------------------------------

/// The preview's job, as the app keeps it.
pub struct Jobs {
    chart: Driver<Chart, ()>,
    /// The job to start when the chart says.
    wanted: Option<Request>,
    /// The running job's flag, which kills its programs.
    cancel: Option<Arc<AtomicBool>>,
    result: Option<Preview>,
    /// What the job wanted or done is about, so the same entry again keeps what shows.
    key: Option<Key>,
}

impl Jobs {
    /// Stops the running job's programs, as its window closes.
    pub fn cancel(&self) {
        if let Some(c) = &self.cancel {
            c.store(true, Ordering::Release);
        }
    }
}

impl Default for Jobs {
    fn default() -> Jobs {
        Jobs {
            chart: Driver::new(Chart::machine(), ()),
            wanted: None,
            cancel: None,
            result: None,
            key: None,
        }
    }
}

/// What a file's preview depends on: the file as listed, and the options that change it.
#[derive(Clone, PartialEq, Eq)]
struct Key {
    path: PathBuf,
    size: u64,
    mtime: i64,
    options: (bool, u32, u32, bool),
}

/// Previews the entry `e` at `path`, which is no folder, on a worker. The same entry again,
/// unchanged and shown, keeps what shows.
pub fn show_file(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    path: PathBuf,
    e: Entry,
) -> Result<()> {
    let o = &s.options;
    let key = Key {
        path: path.clone(),
        size: e.size,
        mtime: e.mtime,
        options: (
            o.preview_images,
            o.preview_max_image_bytes,
            o.preview_max_bytes,
            o.syntax,
        ),
    };
    let idle = s
        .previews
        .chart
        .matches(strider_machines::preview::preview::states::IDLE);
    let shown = !matches!(s.preview, Preview::None | Preview::Folder(_));
    if idle && shown && s.previews.key.as_ref() == Some(&key) {
        return Ok(());
    }
    s.preview_generation += 1;
    s.previews.key = Some(key);
    s.previews.wanted = Some(request(s, tx, path, e));
    send(s, tx, PreviewEv::Start)
}

/// Moves on to what needs no job: the job there is stops, and its result is dropped.
pub fn stop(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    s.preview_generation += 1;
    s.previews.key = None;
    s.previews.wanted = None;
    send(s, tx, PreviewEv::Stop)
}

/// Shows text that is no file, such as a command's output, in place of what the preview
/// shows; see [`Preview::output`].
pub fn show_output(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    title: &str,
    text: &str,
    spans: Vec<Span>,
) -> Result<()> {
    stop(s, tx)?;
    s.preview = Preview::output(title, text, spans);
    crate::cache::show(s, tx)?;
    app::draw_preview(s, tx)
}

/// Steps the chart, and carries out what it asks.
fn send(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: PreviewEv) -> Result<()> {
    for fx in s.previews.chart.send(ev, NoTimers) {
        match fx {
            PreviewFx::Launch => launch(s, tx)?,
            PreviewFx::Kill => {
                if let Some(c) = s.previews.cancel.take() {
                    c.store(true, Ordering::Release);
                }
            }
            PreviewFx::Wait => {
                let title = s.previews.wanted.as_ref().map(|r| r.title());
                s.preview = Preview::Info(Info {
                    title: title.unwrap_or_default(),
                    note: Some("Waiting for the file system…".into()),
                    ..Info::default()
                });
                app::draw_preview(s, tx)?;
            }
            PreviewFx::Apply => {
                if let Some(p) = s.previews.result.take() {
                    // A folder that showed until now is no longer shown.
                    s.preview = p;
                    crate::cache::show(s, tx)?;
                    app::draw_preview(s, tx)?;
                }
            }
        }
    }
    Ok(())
}

/// Starts the job wanted: on a worker, or at once for a scene.
fn launch(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let Some(req) = s.previews.wanted.take() else {
        return Ok(());
    };
    let cancel = Arc::new(AtomicBool::new(false));
    s.previews.cancel = Some(cancel.clone());
    let generation = s.preview_generation;
    if s.sync_reads {
        s.previews.result = Some(load(&req, &cancel));
        return send(s, tx, PreviewEv::Done { current: true });
    }
    tx.spawn_blocking(
        move || load(&req, &cancel),
        app::here(move |s: &mut Strider, tx, preview| {
            let current = s.preview_generation == generation;
            if current {
                s.previews.cancel = None;
                s.previews.result = Some(preview);
            }
            send(s, tx, PreviewEv::Done { current })
        }),
    );
    Ok(())
}

/// Scrolls a text preview by `lines`, up when negative, at once.
pub fn scroll(s: &Strider, tx: &mut Txn<'_, Strider>, lines: i32) -> Result<()> {
    if s.preview.lines().is_none() {
        return Ok(());
    }
    let line = tx
        .measure_text(&Style::new().font_family(keywork::FontFamily::Mono), "X")?
        .height;
    let Some(view) = viewport(tx, s.ui.preview_lines)? else {
        return Ok(());
    };
    let at = tx.scroll_offset(view)?;
    let y = (at.y + lines as f32 * line).max(0.0);
    tx.set_scroll_offset(view, Point::new(at.x, y))
}

/// The scroll node a list's rows move in.
pub fn viewport<K: keywork::tree::Kind>(
    tx: &Txn<'_, Strider>,
    list: NodeId<K>,
) -> Result<Option<NodeId<Scroll>>> {
    Ok(tx
        .children(list)?
        .find_map(|n| tx.downcast::<Scroll>(n).ok()))
}

// --- Jobs ------------------------------------------------------------------------------------

/// What a job needs to preview a file, away from the app's state.
struct Request {
    path: PathBuf,
    entry: Entry,
    db: Arc<MimeDb>,
    images: bool,
    max_image_bytes: u32,
    max_bytes: u32,
    syntax: bool,
    /// The time zone's offset at the file's time, in seconds.
    tz: i64,
    /// The box an image shows in, in logical pixels, and the window's scale.
    width: f32,
    height: f32,
    scale: f32,
    /// `$XDG_CACHE_HOME`: the shared thumbnails and the pages Strider renders.
    cache_home: PathBuf,
}

impl Request {
    fn name(&self) -> &[u8] {
        model::basename(&self.path)
    }

    fn title(&self) -> String {
        String::from_utf8_lossy(self.name()).into_owned()
    }
}

fn request(s: &Strider, tx: &Txn<'_, Strider>, path: PathBuf, e: Entry) -> Request {
    // The preview's box less the image's padding and caption; before the first layout, a
    // guess.
    let (width, height) = match tx.rect(s.ui.panes[Col::Preview as usize]) {
        Ok(r) if r.width >= 16.0 => ((r.width - 16.0).max(16.0), (r.height - 40.0).max(16.0)),
        _ => (480.0, 480.0),
    };
    // Scenes and tests keep renders out of the user's cache.
    let cache_home = match s.state_dir {
        Some(_) => BaseDirs::from_env().cache_home,
        None => s.home.join(".cache"),
    };
    Request {
        path,
        entry: e,
        db: s.db.clone(),
        images: s.options.preview_images,
        max_image_bytes: s.options.preview_max_image_bytes,
        max_bytes: s.options.preview_max_bytes,
        syntax: s.options.syntax,
        tz: i64::from(s.zone.offset_at(e.mtime.div_euclid(1_000_000_000))),
        width,
        height,
        scale: tx.scale(),
        cache_home,
    }
}

/// What the file shows. It touches the file system and may run programs, so it runs on a
/// worker; `cancel` stops it.
fn load(req: &Request, cancel: &AtomicBool) -> Preview {
    if cancel.load(Ordering::Acquire) {
        return Preview::None;
    }
    let e = &req.entry;
    if e.kind != Kind::File {
        let ty = fs::symlink_metadata(&req.path)
            .ok()
            .and_then(|m| MimeDb::inode_type(m.file_type()))
            .unwrap_or("");
        return info(req, ty, None);
    }
    let name = req.name();
    let ty = file_type(&req.db, &req.path);
    let texty = is_texty(ty) || req.db.is_subclass(ty, "text/plain");
    let images = req.images;
    if images && model::thumbnailable(name) {
        if e.size > u64::from(req.max_image_bytes) {
            return info(
                req,
                ty,
                Some("Too large to preview (preview_max_image_bytes)"),
            );
        }
        return image(req, &req.path);
    }
    if let Some(kind) = archive::kind_of(name) {
        return list_archive(req, kind);
    }
    let pdf = ty == "application/pdf" || name.to_ascii_lowercase().ends_with(b".pdf");
    let video = ty.starts_with("video/");
    if pdf
        && images
        && let Some(r) = renderer(&[Renderer::Pdftoppm, Renderer::Mutool])
    {
        return render(req, r, cancel);
    }
    // A thumbnail another program cached, for videos and others.
    if !texty
        && images
        && let Some(thumb) = cached_thumbnail(req)
        && let Ok(picture) = decode(req, &thumb)
    {
        return Preview::Image {
            picture,
            caption: caption(req),
        };
    }
    if video && images {
        return match renderer(&[Renderer::Ffmpegthumbnailer, Renderer::Ffmpeg]) {
            Some(r) => render(req, r, cancel),
            None => info(
                req,
                ty,
                Some("Install ffmpegthumbnailer or ffmpeg to preview videos"),
            ),
        };
    }
    if pdf {
        let note = "Install poppler (pdftoppm) or MuPDF (mutool) to preview PDFs";
        return info(req, ty, images.then_some(note));
    }
    if e.size == 0 {
        return info(req, ty, Some("Empty file"));
    }
    // Programs, libraries, and other application data with no previewer show their start
    // in hex; text that only has an application type shows as text.
    if texty || ty.is_empty() || ty.starts_with("application/") {
        return read_text(req, ty);
    }
    info(req, ty, None)
}

/// The file's type by its name, and by its first bytes when the name cannot decide. Text
/// that no magic claims takes a text type its name could be, so `app.ts` is TypeScript and
/// not an MPEG transport stream.
fn file_type<'a>(db: &'a MimeDb, path: &Path) -> &'a str {
    let guess = db.guess(path, None);
    if guess.certain {
        return guess.mime;
    }
    let mut head = Vec::new();
    if File::open(path)
        .and_then(|f| f.take(db.sniff_len() as u64).read_to_end(&mut head))
        .is_err()
    {
        return guess.mime;
    }
    let text = !head.contains(&0) && std::str::from_utf8(trim_partial(&head)).is_ok();
    if text && db.sniff(&head).is_none() {
        let name = path.file_name().unwrap_or_default();
        if let Some(t) = db
            .globs(name)
            .as_slice()
            .iter()
            .find(|t| db.is_subclass(t, "text/plain"))
        {
            return t;
        }
    }
    db.guess(path, Some(&head)).mime
}

fn is_texty(t: &str) -> bool {
    const TEXTY: &[&str] = &[
        "application/json",
        "application/xml",
        "application/javascript",
        "application/x-shellscript",
        "application/toml",
        "application/x-yaml",
        "application/sql",
        "application/x-desktop",
        "inode/x-empty",
        "application/x-zerosize",
        "application/x-executable",
    ];
    t.starts_with("text/") || TEXTY.contains(&t) || t.ends_with("+xml") || t.ends_with("+json")
}

/// A card saying why the file shows nothing else.
fn failed(req: &Request, msg: &str) -> Preview {
    Preview::Info(Info {
        title: req.title(),
        rows: Vec::new(),
        note: Some(msg.into()),
    })
}

/// The file's details: type, size, date, permissions, and a link's target, then `note`.
fn info(req: &Request, ty: &str, note: Option<&str>) -> Preview {
    let e = &req.entry;
    let mut rows = Vec::new();
    let mut add = |k, v: String| {
        if !v.is_empty() {
            rows.push((k, v));
        }
    };
    add("Type", type_label(ty));
    if e.kind == Kind::File {
        add("Size", model::format_size(e.size));
    }
    add("Modified", model::format_time(e.mtime, req.tz));
    add("Permissions", model::format_mode(e.mode));
    if e.link
        && let Ok(target) = fs::read_link(&req.path)
    {
        add("Links to", target.display().to_string());
    }
    Preview::Info(Info {
        title: req.title(),
        rows,
        note: note.map(str::to_owned),
    })
}

/// A type as people read it, "PNG image", from the shared MIME database's description.
fn type_label(ty: &str) -> String {
    if ty.is_empty() {
        return String::new();
    }
    let dirs: Vec<PathBuf> = BaseDirs::from_env()
        .data_search()
        .map(|d| d.join("mime"))
        .collect();
    read_comment(dirs, ty, &Locale::from_env()).unwrap_or_else(|| ty.to_owned())
}

fn caption(req: &Request) -> String {
    format!(
        "{}  ·  {}  ·  {}",
        req.title(),
        model::format_size(req.entry.size),
        model::format_time(req.entry.mtime, req.tz)
    )
}

// --- Images ----------------------------------------------------------------------------------

fn image(req: &Request, path: &Path) -> Preview {
    match decode(req, path) {
        Ok(picture) => Preview::Image {
            picture,
            caption: caption(req),
        },
        Err(msg) => failed(req, msg),
    }
}

/// The image at `path`, decoded no larger than the box it shows in; or why not.
fn decode(req: &Request, path: &Path) -> std::result::Result<Picture, &'static str> {
    let svg = path
        .extension()
        .is_some_and(|x| x.eq_ignore_ascii_case("svg") || x.eq_ignore_ascii_case("svgz"));
    if svg {
        return Ok(Picture::File(path.to_owned()));
    }
    let data = fs::read(path).map_err(|_| "This image could not be read")?;
    let options = DecodeOptions {
        target: Some((
            (req.width * req.scale) as u32,
            (req.height * req.scale) as u32,
        )),
        ..DecodeOptions::default()
    };
    match decode_image(&data, &options) {
        Ok(image) => Ok(Picture::Decoded(Arc::new(image))),
        Err(DecodeError::Unknown) => Err(UNSUPPORTED),
        Err(_)
            if image_size(&data, &options)
                .is_ok_and(|(w, h)| u64::from(w) * u64::from(h) > options.max_pixels) =>
        {
            Err("This image is too large to preview")
        }
        Err(_) => Err("This image could not be read"),
    }
}

/// The largest thumbnail of the file another program saved in the shared cache, if it is
/// newer than the file.
fn cached_thumbnail(req: &Request) -> Option<PathBuf> {
    let path = std::path::absolute(&req.path).ok()?;
    let uri = keywork::desktop::uri::file_uri(&path);
    let cache = ThumbnailCache::at(req.cache_home.join("thumbnails"));
    ThumbnailSize::ALL.iter().rev().find_map(|&size| {
        let thumb = cache.path(&uri, size);
        let modified = fs::metadata(&thumb).ok()?.modified().ok()?;
        let ns = modified
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_nanos();
        (ns >= u128::try_from(req.entry.mtime).unwrap_or(0)).then_some(thumb)
    })
}

/// Programs that render a PDF's first page or a video's frame to PNG.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Renderer {
    Pdftoppm,
    Mutool,
    Ffmpegthumbnailer,
    Ffmpeg,
}

impl Renderer {
    fn program(self) -> &'static str {
        match self {
            Renderer::Pdftoppm => "pdftoppm",
            Renderer::Mutool => "mutool",
            Renderer::Ffmpegthumbnailer => "ffmpegthumbnailer",
            Renderer::Ffmpeg => "ffmpeg",
        }
    }

    fn pdf(self) -> bool {
        matches!(self, Renderer::Pdftoppm | Renderer::Mutool)
    }
}

/// The first of `choices` installed.
fn renderer(choices: &[Renderer]) -> Option<Renderer> {
    choices.iter().copied().find(|r| proc::on_path(r.program()))
}

fn non_empty(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|m| m.len() > 0)
}

/// A PDF's first page or a video's frame, at the preview's width, as a PNG in
/// `$XDG_CACHE_HOME/strider/previews`, named by the file's path, time, and the width.
fn render(req: &Request, r: Renderer, cancel: &AtomicBool) -> Preview {
    let w = req.width.max(64.0) as u32;
    let mut h = std::hash::DefaultHasher::new();
    req.path.hash(&mut h);
    req.entry.mtime.hash(&mut h);
    w.hash(&mut h);
    let dir = req.cache_home.join("strider/previews");
    let prefix = dir.join(format!("{:016x}", h.finish()));
    let png = prefix.with_extension("png");
    if !non_empty(&png) {
        let _ = fs::create_dir_all(&dir);
        let options = proc::Options {
            max_output: 4096,
            kill_after: None,
            cancel: Some(cancel),
            timeout: Some(PROGRAM_TIMEOUT),
        };
        let run = |argv: &[&std::ffi::OsStr]| proc::run(argv, &options).is_ok();
        let (ws, scale) = (w.to_string(), format!("scale={w}:-2"));
        let (file, png_s, prefix_s) = (req.path.as_os_str(), png.as_os_str(), prefix.as_os_str());
        let os = |s: &'static str| std::ffi::OsStr::new(s);
        let ran = match r {
            Renderer::Pdftoppm => run(&[
                os("pdftoppm"),
                os("-f"),
                os("1"),
                os("-l"),
                os("1"),
                os("-singlefile"),
                os("-png"),
                os("-scale-to-x"),
                ws.as_ref(),
                os("-scale-to-y"),
                os("-1"),
                file,
                prefix_s,
            ]),
            Renderer::Mutool => run(&[
                os("mutool"),
                os("draw"),
                os("-q"),
                os("-o"),
                png_s,
                os("-w"),
                ws.as_ref(),
                os("-F"),
                os("png"),
                file,
                os("1"),
            ]),
            Renderer::Ffmpegthumbnailer => run(&[
                os("ffmpegthumbnailer"),
                os("-i"),
                file,
                os("-o"),
                png_s,
                os("-s"),
                ws.as_ref(),
                os("-c"),
                os("png"),
                os("-t"),
                os("10%"),
            ]),
            // A few seconds in, past a fade from black; short videos have no frame there,
            // so then the first.
            Renderer::Ffmpeg => {
                let frame = |at: &[&std::ffi::OsStr]| {
                    let mut argv = vec![
                        os("ffmpeg"),
                        os("-nostdin"),
                        os("-v"),
                        os("error"),
                        os("-y"),
                    ];
                    argv.extend_from_slice(at);
                    argv.extend([
                        os("-i"),
                        file,
                        os("-frames:v"),
                        os("1"),
                        os("-vf"),
                        scale.as_ref(),
                        png_s,
                    ]);
                    run(&argv)
                };
                let ran = frame(&[os("-ss"), os("3")]);
                if ran && !non_empty(&png) && !cancel.load(Ordering::Acquire) {
                    frame(&[]);
                }
                ran
            }
        };
        if cancel.load(Ordering::Acquire) {
            // What a killed renderer left is no page.
            let _ = fs::remove_file(&png);
            return Preview::None;
        }
        if !ran {
            return failed(
                req,
                if r.pdf() {
                    "The PDF renderer could not run"
                } else {
                    "The video thumbnailer could not run"
                },
            );
        }
        if !non_empty(&png) {
            return failed(
                req,
                if r.pdf() {
                    "This PDF could not be rendered"
                } else {
                    "No frame could be taken from this video"
                },
            );
        }
    }
    image(req, &png)
}

// --- Text ------------------------------------------------------------------------------------

/// The file's start: as text, colored, or in hex when it is not text.
fn read_text(req: &Request, ty: &str) -> Preview {
    let want = req.entry.size.min(u64::from(req.max_bytes));
    let mut data = Vec::new();
    let read = File::open(&req.path).and_then(|f| f.take(want).read_to_end(&mut data));
    if read.is_err() {
        return failed(req, "This file could not be read");
    }
    let head = &data[..data.len().min(8192)];
    if head.contains(&0) || std::str::from_utf8(trim_partial(head)).is_err() {
        let bytes = &data[..data.len().min(HEX_BYTES)];
        let lines = hex_dump(&type_for_hex(ty), req.entry.size, bytes);
        return Preview::Text(lines);
    }
    // Cut at the last whole line or character.
    if data.len() as u64 == want
        && req.entry.size > want
        && let Some(nl) = data.iter().rposition(|&b| b == b'\n')
    {
        data.truncate(nl + 1);
    }
    let valid = trim_partial(&data).len();
    data.truncate(valid);
    strip_cr(&mut data);
    let text = String::from_utf8_lossy(&data).into_owned();
    let lang = highlight::detect(req.name(), &text.as_bytes()[..text.len().min(8192)]);
    let spans = match (req.syntax, lang) {
        (true, Some(lang)) => highlight::highlight(lang, text.as_bytes()),
        _ => Vec::new(),
    };
    Preview::Text(Lines::new(text, spans))
}

/// The type over a hex view: as people read it, or "Binary file" when it is not known.
fn type_for_hex(ty: &str) -> String {
    if ty.is_empty() || ty == OCTET_STREAM {
        "Binary file".into()
    } else {
        type_label(ty)
    }
}

/// The start of a binary file as `hexdump -C` shows it, under its type and size: the
/// offset, 16 bytes in hex, and those that are printable.
fn hex_dump(label: &str, size: u64, bytes: &[u8]) -> Lines {
    use std::fmt::Write;
    let mut out = String::new();
    let mut spans = Vec::new();
    let mut span = |start: usize, end: usize, class| spans.push(Span { start, end, class });
    if !label.is_empty() {
        let _ = write!(out, "{label}, {}\n\n", model::format_size(size));
        span(0, out.len(), Class::Heading);
    }
    for (row_no, row) in bytes.chunks(16).enumerate() {
        let start = out.len();
        let _ = write!(out, "{:08x}", row_no * 16);
        span(start, start + 8, Class::Comment);
        for k in 0..16 {
            if k % 8 == 0 {
                out.push(' ');
            }
            match row.get(k) {
                Some(b) => {
                    let _ = write!(out, " {b:02x}");
                }
                None => out.push_str("   "),
            }
        }
        out.push_str("  |");
        let a = out.len();
        out.extend(row.iter().map(|&b| {
            if (0x20..0x7f).contains(&b) {
                b as char
            } else {
                '.'
            }
        }));
        span(a, out.len(), Class::String);
        out.push_str("|\n");
    }
    if size > bytes.len() as u64 {
        let _ = writeln!(
            out,
            "… the first {} bytes of {}",
            bytes.len(),
            model::format_size(size)
        );
    }
    Lines::new(out, spans)
}

/// An archive's entries, a line each, folders colored like keywords and sizes like
/// comments.
fn list_archive(req: &Request, kind: archive::Kind) -> Preview {
    let listed = match kind {
        archive::Kind::Other => list_bsdtar(&req.path),
        _ => archive::list(&req.path, kind, ARCHIVE_LIMIT)
            .map_err(|_| "This archive could not be read"),
    };
    match listed {
        Ok(l) => Preview::Text(archive_lines(&l)),
        Err(msg) => failed(req, msg),
    }
}

fn list_bsdtar(path: &Path) -> std::result::Result<archive::Listing, &'static str> {
    if !proc::on_path("bsdtar") {
        return Err("Install libarchive (bsdtar) to list this archive");
    }
    let options = proc::Options {
        max_output: 1 << 20,
        kill_after: Some(4 << 20),
        cancel: None,
        timeout: None,
    };
    let argv = ["bsdtar".as_ref(), "-tf".as_ref(), path.as_os_str()];
    let r = proc::run(&argv, &options).map_err(|_| "This archive could not be read")?;
    if r.status != 0 && r.output.is_empty() {
        return Err("This archive could not be read");
    }
    Ok(archive::parse_bsdtar(&r.output, r.truncated, ARCHIVE_LIMIT))
}

fn archive_lines(l: &archive::Listing) -> Lines {
    let mut text = String::new();
    let mut spans = Vec::new();
    for e in &l.entries {
        let start = text.len();
        text.push_str(&e.name);
        if e.dir {
            text.push('/');
            spans.push(Span {
                start,
                end: text.len(),
                class: Class::Keyword,
            });
        }
        if !e.dir && e.size != 0 {
            text.push_str("  ");
            let at = text.len();
            text.push_str(&model::format_size(e.size));
            spans.push(Span {
                start: at,
                end: text.len(),
                class: Class::Comment,
            });
        }
        text.push('\n');
    }
    if l.truncated {
        text.push_str("…\n");
    }
    if l.entries.is_empty() {
        text.push_str("(empty archive)\n");
    }
    Lines::new(text, spans)
}

/// `s` without a UTF-8 sequence cut off at its end.
fn trim_partial(s: &[u8]) -> &[u8] {
    // The last character's first byte, at most three bytes back.
    let Some(lead) = (s.len().saturating_sub(4)..s.len())
        .rev()
        .find(|&i| s[i] & 0xc0 != 0x80)
    else {
        return s;
    };
    let need = match s[lead] {
        0xf0..=0xf4 => 4,
        0xe0..=0xef => 3,
        0xc2..=0xdf => 2,
        _ => 1,
    };
    if s.len() - lead < need { &s[..lead] } else { s }
}

/// Drops the carriage return of each CRLF.
fn strip_cr(data: &mut Vec<u8>) {
    let mut w = 0;
    for i in 0..data.len() {
        if data[i] == b'\r' && data.get(i + 1) == Some(&b'\n') {
            continue;
        }
        data[w] = data[i];
        w += 1;
    }
    data.truncate(w);
}

#[cfg(test)]
mod tests {
    use super::*;

    // The hex view lines up as hexdump -C does, under the type and size, and says how
    // much of a larger file it shows; the Zig build's test text.
    #[test]
    fn hex_dump_matches_hexdump() {
        let l = hex_dump("Binary file", 10, b"\x00\x01\x02binary\x00");
        assert_eq!(
            l.text,
            "Binary file, 10 bytes\n\n00000000  00 01 02 62 69 6e 61 72  79 00                    |...binary.|\n"
        );
        let l = hex_dump("", 2000, &[b'a'; 17]);
        assert!(l.text.ends_with("|a|\n… the first 17 bytes of 2.0 kB\n"));
    }

    // Keys faster than previews: each move kills the job before it, at most two run, and
    // only the last entry's preview shows once they are done. An archive then lists its
    // entries with their sizes.
    #[test]
    fn moving_on_quickly_shows_only_the_last_preview() {
        let home = crate::scenes::preview_fixture("moving-on");
        let (app, state) = crate::app_in(
            home.join("work"),
            home.clone(),
            strider_core::config::Config::default(),
            keywork::desktop::localtime::Zone::utc(),
            false,
            None,
        )
        .unwrap();
        let window = state.window;
        let mut h = app.headless(state).unwrap();
        h.settle().unwrap();
        let keys = |h: &mut keywork::app::Headless<Strider>, c: char, n: usize| {
            for _ in 0..n {
                h.key(window, Keysym::from_char(c), Modifiers::NONE)
                    .unwrap();
            }
            h.settle().unwrap();
        };
        keys(&mut h, 'j', 10);
        assert_eq!(h.state().cur().current_name(), Some(&b"photo.png"[..]));
        assert!(
            matches!(&h.state().preview, Preview::Image { caption, .. } if caption.starts_with("photo.png"))
        );
        assert!(
            h.state()
                .previews
                .chart
                .matches(strider_machines::preview::preview::states::IDLE)
        );
        assert_eq!(h.state().previews.chart.context().running, 0);
        keys(&mut h, 'k', 5);
        assert_eq!(h.state().cur().current_name(), Some(&b"backup.tar.gz"[..]));
        let text = h.state().preview.lines().map(|l| l.text.clone());
        assert_eq!(
            text.as_deref(),
            Some("pkg/\npkg/b.txt  1 byte\npkg/lib/\npkg/lib/a.txt  5 bytes\n")
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    // A read cut inside a character keeps the characters before it; an invalid byte stays
    // for the binary check to find.
    #[test]
    fn partial_characters() {
        assert_eq!(trim_partial("aé".as_bytes()), "aé".as_bytes());
        assert_eq!(trim_partial(&"aé".as_bytes()[..2]), b"a");
        assert_eq!(trim_partial(&"a€".as_bytes()[..3]), b"a");
        assert_eq!(trim_partial(b"a\xff"), b"a\xff");
    }
}
