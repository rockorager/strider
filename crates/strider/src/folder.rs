//! A folder as a column shows it: its listing, the entries shown in their order, the cursor,
//! and the marks.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use keywork::desktop::mime::MimeDb;
use strider_core::model::{self, Kind, Listing, ReadError};
use strider_core::options::Options;

pub struct Folder {
    pub path: PathBuf,
    pub listing: Listing,
    /// Why it could not be read; the listing is empty then.
    pub error: Option<ReadError>,
    /// The entries shown, as indices into the listing, sorted and filtered.
    pub order: Vec<u32>,
    /// Each entry's MIME type, by listing index, for its icon.
    pub types: Vec<&'static str>,
    /// The cursor, as a position in `order`.
    pub cursor: usize,
    /// Marked entries, by listing index.
    pub marks: BTreeSet<u32>,
}

impl Folder {
    /// Reads `path` and shows it with `options`, the cursor on `focus` when it is there.
    pub fn read(path: &Path, options: &Options, db: &MimeDb, focus: Option<&[u8]>) -> Folder {
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
                    leak_type(db.guess(Path::new(name), None).mime)
                }
            })
            .collect();
        let mut f = Folder {
            path: path.to_owned(),
            listing,
            error,
            order: Vec::new(),
            types,
            cursor: 0,
            marks: BTreeSet::new(),
        };
        f.arrange(options, focus);
        f
    }

    /// Sorts and filters the entries again, keeping the cursor on `focus`, else on the entry
    /// it was on, else where it was.
    pub fn arrange(&mut self, options: &Options, focus: Option<&[u8]>) {
        let keep = focus
            .map(<[u8]>::to_vec)
            .or_else(|| self.current_name().map(<[u8]>::to_vec));
        let sorted = model::sort(&self.listing, options.sort, |_| ());
        self.order = model::filter(
            &self.listing,
            &sorted,
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
fn leak_type(mime: &str) -> &'static str {
    use std::cell::RefCell;
    use std::collections::HashSet;
    thread_local! {
        static NAMES: RefCell<HashSet<&'static str>> = RefCell::new(HashSet::new());
    }
    NAMES.with(|names| {
        let mut names = names.borrow_mut();
        if let Some(n) = names.get(mime) {
            return *n;
        }
        let n: &'static str = Box::leak(mime.to_owned().into_boxed_str());
        names.insert(n);
        n
    })
}
