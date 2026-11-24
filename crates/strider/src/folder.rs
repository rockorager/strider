//! A folder as a column shows it: its listing, read on a worker, the entries shown in their
//! order, the cursor, and the marks. The cursor and the marks are kept by name, so they
//! survive the folder being read again.

use std::collections::{BTreeSet, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use keywork::desktop::mime::MimeDb;
use strider_core::model::{self, Kind, Listing, ReadError};
use strider_core::options::{Options, Sort};

/// A read of a folder, done on a worker: the listing, each entry's MIME type, and the
/// entries sorted.
pub struct Listed {
    pub listing: Listing,
    pub error: Option<ReadError>,
    pub types: Vec<&'static str>,
    pub sorted: Vec<u32>,
    pub sort: Sort,
}

/// Reads `path`, guesses its entries' types by name, and sorts them by `sort`. It touches the
/// file system, so it runs on a worker.
pub fn read(path: &Path, db: &MimeDb, sort: Sort) -> Listed {
    let (listing, error) = match model::read(path) {
        Ok(l) => (l, None),
        Err(e) => (model::Builder::new().finish(path), Some(e)),
    };
    let types = listing
        .entries
        .iter()
        .map(|e| match e.kind {
            Kind::Dir => "inode/directory",
            _ => {
                let name = OsStr::from_bytes(listing.name(e));
                intern(db.guess(Path::new(name), None).mime)
            }
        })
        .collect();
    let sorted = model::sort(&listing, sort, |_| ());
    Listed {
        listing,
        error,
        types,
        sorted,
        sort,
    }
}

pub struct Folder {
    pub path: PathBuf,
    pub listing: Listing,
    /// Why it could not be read; the listing is empty then.
    pub error: Option<ReadError>,
    /// A read has come in.
    pub loaded: bool,
    /// Every entry, sorted by `sorted_by`.
    sorted: Vec<u32>,
    sorted_by: Option<Sort>,
    /// The entries shown, as indices into the listing, sorted and filtered.
    pub order: Vec<u32>,
    /// Each entry's MIME type, by listing index, for its icon.
    pub types: Vec<&'static str>,
    /// The cursor, as a position in `order`.
    pub cursor: usize,
    /// The entry the cursor is to be on once a read shows it.
    want: Option<Vec<u8>>,
    /// Marked entries, by listing index.
    pub marks: BTreeSet<u32>,
}

impl Folder {
    /// A folder not read yet.
    pub fn new(path: &Path) -> Folder {
        Folder {
            path: path.to_owned(),
            listing: model::Builder::new().finish(path),
            error: None,
            loaded: false,
            sorted: Vec::new(),
            sorted_by: None,
            order: Vec::new(),
            types: Vec::new(),
            cursor: 0,
            want: None,
            marks: BTreeSet::new(),
        }
    }

    /// Shows a read that came in, the cursor and the marks staying on the entries they were
    /// on.
    pub fn apply(&mut self, listed: Listed, options: &Options) {
        let marked: HashSet<Vec<u8>> = self
            .marks
            .iter()
            .map(|&i| {
                self.listing
                    .name(&self.listing.entries[i as usize])
                    .to_vec()
            })
            .collect();
        let focus = self
            .want
            .take()
            .or_else(|| self.current_name().map(<[u8]>::to_vec));
        self.listing = listed.listing;
        self.error = listed.error;
        self.types = listed.types;
        self.sorted = listed.sorted;
        self.sorted_by = Some(listed.sort);
        self.loaded = true;
        self.marks = (0..self.listing.entries.len() as u32)
            .filter(|&i| marked.contains(self.listing.name(&self.listing.entries[i as usize])))
            .collect();
        self.arrange(options, focus.as_deref());
    }

    /// Sorts and filters the entries again, keeping the cursor on `focus`, else on the entry
    /// it was on, else where it was.
    pub fn arrange(&mut self, options: &Options, focus: Option<&[u8]>) {
        let keep = focus
            .map(<[u8]>::to_vec)
            .or_else(|| self.current_name().map(<[u8]>::to_vec));
        if self.sorted_by != Some(options.sort) {
            self.sorted = model::sort(&self.listing, options.sort, |_| ());
            self.sorted_by = Some(options.sort);
        }
        self.order = model::filter(
            &self.listing,
            &self.sorted,
            "",
            options.show_hidden,
            None,
            |_| std::iter::empty(),
        );
        let found = keep.and_then(|name| self.position_of(&name));
        self.cursor = found
            .unwrap_or(self.cursor)
            .min(self.order.len().saturating_sub(1));
    }

    /// Puts the cursor on the entry named `name`, now or once a read shows it.
    pub fn focus(&mut self, name: &[u8]) {
        match self.position_of(name) {
            Some(pos) if self.loaded => self.cursor = pos,
            _ => self.want = Some(name.to_vec()),
        }
    }

    pub fn position_of(&self, name: &[u8]) -> Option<usize> {
        self.order
            .iter()
            .position(|&i| self.listing.name(&self.listing.entries[i as usize]) == name)
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    /// The listing index of the entry at `pos` in the order.
    pub fn index(&self, pos: usize) -> Option<u32> {
        self.order.get(pos).copied()
    }

    pub fn entry(&self, pos: usize) -> Option<&model::Entry> {
        self.index(pos).map(|i| &self.listing.entries[i as usize])
    }

    pub fn current(&self) -> Option<&model::Entry> {
        self.entry(self.cursor)
    }

    pub fn current_name(&self) -> Option<&[u8]> {
        self.current().map(|e| self.listing.name(e))
    }

    pub fn current_path(&self) -> Option<PathBuf> {
        self.current().map(|e| self.listing.path_of(e))
    }

    pub fn name(&self, pos: usize) -> &[u8] {
        self.entry(pos).map_or(b"", |e| self.listing.name(e))
    }

    pub fn type_at(&self, pos: usize) -> &'static str {
        self.index(pos)
            .map_or("application/octet-stream", |i| self.types[i as usize])
    }
}

/// MIME type names come from the database, which lives as long as the app; the few distinct
/// names are kept once, so entries hold a `&'static str`.
fn intern(mime: &str) -> &'static str {
    static NAMES: Mutex<Option<HashSet<&'static str>>> = Mutex::new(None);
    let mut names = NAMES.lock().unwrap_or_else(|e| e.into_inner());
    let names = names.get_or_insert_with(HashSet::new);
    if let Some(n) = names.get(mime) {
        return n;
    }
    let n: &'static str = Box::leak(mime.to_owned().into_boxed_str());
    names.insert(n);
    n
}
