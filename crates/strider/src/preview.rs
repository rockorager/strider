//! What the preview column shows for the entry under the cursor: a folder's entries, a text
//! file's start with syntax coloring, or the entry's details.

use std::io::Read;
use std::path::{Path, PathBuf};

use strider_core::highlight::{self, Span};

pub enum Preview {
    None,
    /// A folder, from the cache.
    Folder(PathBuf),
    /// A file being read on a worker.
    Loading,
    /// A text file's start: its lines, as byte ranges, and its coloring.
    Text {
        text: String,
        lines: Vec<std::ops::Range<usize>>,
        spans: Vec<Span>,
    },
    Info(String),
}

/// What a file shows: its start, colored, when it is text. It touches the file system, so it
/// runs on a worker.
pub fn read_file(path: &Path, max_bytes: u32, syntax: bool) -> Preview {
    text(path, max_bytes, syntax).unwrap_or_else(|| Preview::Info(String::new()))
}

/// The start of a text file, colored; None for a file that is not text.
fn text(path: &Path, max_bytes: u32, syntax: bool) -> Option<Preview> {
    let mut data = Vec::new();
    std::fs::File::open(path)
        .ok()?
        .take(u64::from(max_bytes))
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
    let spans = match (syntax, highlight::detect(name, text.as_bytes())) {
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
