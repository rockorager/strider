//! What the preview column shows for the entry under the cursor: a folder's entries, a text
//! file's start with syntax coloring, or the entry's details.

use std::io::Read;
use std::path::Path;

use keywork::desktop::mime::MimeDb;
use strider_core::highlight::{self, Span};
use strider_core::model::Kind;
use strider_core::options::Options;

use crate::folder::Folder;

pub enum Preview {
    None,
    Folder(Box<Folder>),
    /// A text file's start: its lines, as byte ranges, and its coloring.
    Text {
        text: String,
        lines: Vec<std::ops::Range<usize>>,
        spans: Vec<Span>,
    },
    Info(String),
}

impl Preview {
    pub fn of(
        path: Option<&Path>,
        kind: Option<Kind>,
        options: &Options,
        db: &MimeDb,
        focus: Option<&[u8]>,
    ) -> Preview {
        let (Some(path), Some(kind), true) = (path, kind, options.preview) else {
            return Preview::None;
        };
        match kind {
            Kind::Dir => Preview::Folder(Box::new(Folder::read(path, options, db, focus))),
            Kind::File => text(path, options).unwrap_or_else(|| Preview::Info(String::new())),
            Kind::Other => Preview::Info(String::new()),
        }
    }
}

/// The start of a text file, colored; None for a file that is not text.
fn text(path: &Path, options: &Options) -> Option<Preview> {
    let mut data = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(u64::from(options.preview_max_bytes))
        .read_to_end(&mut data)
        .ok()?;
    if data.contains(&0) {
        return None;
    }
    // A read that ends inside a character keeps the characters before it.
    let text = match String::from_utf8(data) {
        Ok(t) => t,
        Err(e) => {
            let valid = e.utf8_error().valid_up_to();
            if e.utf8_error().error_len().is_some() {
                return None;
            }
            let mut data = e.into_bytes();
            data.truncate(valid);
            String::from_utf8(data).ok()?
        }
    };
    let name = path
        .file_name()
        .map_or(&b""[..], |n| std::os::unix::ffi::OsStrExt::as_bytes(n));
    let spans = match (options.syntax, highlight::detect(name, text.as_bytes())) {
        (true, Some(lang)) => highlight::highlight(lang, text.as_bytes()),
        _ => Vec::new(),
    };
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
    Some(Preview::Text { text, lines, spans })
}
