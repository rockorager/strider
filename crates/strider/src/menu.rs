//! Context menus: a right click on an entry or a column's empty space, or the Menu key and
//! Shift+F10 at the cursor's row, list what applies, each item a command with the keys bound
//! to it at its end, so the menu teaches the keymap. Choosing an item runs its command as a
//! key would. The open-with menu lists applications the same way.

use keywork::prelude::*;
use keywork::widgets::{self, Icon, Menu};
use strider_core::config::Mode;
use strider_core::keys;
use strider_core::model::Kind;
use strider_machines::mode::ModeEv;

use crate::app::{self, Col, ROW_HEIGHT, Strider};
use crate::commands;

/// What a menu is for: the targets, or the current folder's empty space.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Context {
    Entries,
    Folder,
}

/// Lets a right click on the current column open its menu.
pub fn bind(tx: &mut Txn<'_, Strider>, list: NodeId<keywork::kind::Box>) -> Result<()> {
    app::on(tx, list, ContextMenu, clicked)
}

/// A right click on an entry acts on the selection when the entry is in it, as other file
/// managers do; on another entry the range and marks go and the cursor moves there. On
/// empty space it is the folder's menu.
fn clicked(s: &mut Strider, tx: &mut Txn<'_, Strider>, ev: &Event) -> Result<()> {
    let EventData::ContextMenu { position, .. } = ev.data else {
        return Err(keywork::Error::Pass);
    };
    let Some(i) = widgets::row_item(tx, ev.target)?.filter(|&i| i < s.cur().len()) else {
        return open(s, tx, Context::Folder, position);
    };
    let in_selection = if s.visual() {
        let (lo, hi) = app::range(s);
        (lo..=hi).contains(&i)
    } else {
        s.cur().index(i).is_some_and(|k| s.cur().marks.contains(&k))
    };
    if !in_selection {
        if s.visual() {
            app::send_mode(s, tx, ModeEv::VisualCancel)?;
        }
        if !s.cur().marks.is_empty() {
            s.cur_mut().marks.clear();
            app::draw_column(s, tx, Col::Current)?;
        }
        app::move_cursor(s, tx, i)?;
    }
    open(s, tx, Context::Entries, position)
}

/// `:menu`: the menu at the cursor's row, or the folder's when it is empty.
pub fn at_cursor(s: &mut Strider, tx: &mut Txn<'_, Strider>) -> Result<()> {
    let ctx = if s.cur().len() == 0 {
        Context::Folder
    } else {
        Context::Entries
    };
    let at = cursor_point(s, tx)?;
    open(s, tx, ctx, at)
}

/// Under the cursor's row, a little in from the column's edge; the column's top without a
/// row.
fn cursor_point(s: &Strider, tx: &Txn<'_, Strider>) -> Result<Point> {
    let list = s.ui.lists[Col::Current as usize];
    let r = tx.window_rect(list)?;
    if s.cur().len() == 0 {
        return Ok(Point::new(r.x + 40.0, r.y + 20.0));
    }
    let scroll = tx.scroll_offset(widgets::list_viewport(tx, list)?)?;
    let y = r.y + (s.cur().cursor + 1) as f32 * ROW_HEIGHT - scroll.y;
    Ok(Point::new(r.x + 48.0, y.clamp(r.y, r.y + r.height)))
}

/// A menu's items as they are added, with the command each runs.
struct Items<'a> {
    s: &'a Strider,
    commands: Vec<String>,
}

impl Items<'_> {
    fn add(&mut self, menu: Menu, label: &str, cmd: &str) -> Menu {
        let menu = menu.item(self.next(cmd), label);
        self.keys(menu, cmd)
    }

    fn check(&mut self, menu: Menu, label: &str, cmd: &str, on: bool) -> Menu {
        let menu = menu.check(self.next(cmd), label, on);
        self.keys(menu, cmd)
    }

    fn next(&mut self, cmd: &str) -> usize {
        self.commands.push(cmd.to_owned());
        self.commands.len() - 1
    }

    /// The keys bound to `cmd` in normal mode at the item's end, as the keymap writes them.
    fn keys(&self, menu: Menu, cmd: &str) -> Menu {
        let bound = self
            .s
            .keymap
            .bindings()
            .iter()
            .find(|b| b.mode == Mode::Normal && b.cmd == cmd);
        match bound {
            Some(b) => menu.trailing(&keys::format(&b.keys)),
            None => menu,
        }
    }
}

/// Opens the menu for `ctx` at `at`, a point in the window.
fn open(s: &mut Strider, tx: &mut Txn<'_, Strider>, ctx: Context, at: Point) -> Result<()> {
    let mut items = Items {
        s,
        commands: Vec::new(),
    };
    let menu = match ctx {
        Context::Entries => entries(&mut items),
        Context::Folder => folder(&mut items),
    };
    let commands = items.commands;
    let menu = menu.on_command(move |s: &mut Strider, tx, i| match commands.get(i) {
        Some(cmd) if s.here(tx) => commands::execute(s, tx, &cmd.clone(), None, true),
        _ => Ok(()),
    });
    let list = s.ui.lists[Col::Current as usize];
    widgets::open_context_menu(tx, list, at, &menu)
}

/// Whether there is something to paste; the register comes with the operations.
fn can_paste(_s: &Strider) -> bool {
    false
}

/// The targets' menu: opening, the clipboard, renaming, trashing, and a shell command.
fn entries(it: &mut Items<'_>) -> Menu {
    let s = it.s;
    let paths = app::targets(s);
    let one = paths.len() == 1;
    let dir = one
        && !s.visual()
        && s.cur().marks.is_empty()
        && s.cur().current().is_some_and(|e| e.kind == Kind::Dir);
    let mut m = Menu::new();
    if dir {
        let p = paths[0].display();
        m = it
            .add(m, "Open", "enter")
            .icon(Icon::themed("folder-open", Icon::Folder));
        m = it.add(m, "Open in a new tab", &format!("tab-new {p}"));
        m = it.add(m, "Open terminal here", &format!("terminal {p}"));
    } else {
        m = it.add(m, "Open", "open");
    }
    m = it.add(m, "Open with…", "open-with").separator();
    m = it.add(m, "Copy", "yank");
    m = it.add(m, "Cut", "cut");
    m = it.add(m, "Paste here", "paste");
    if !can_paste(s) {
        m = m.disabled();
    }
    let copy = if one {
        "Copy the path"
    } else {
        "Copy the paths"
    };
    m = it.add(m, copy, "yank-path").separator();
    m = if one {
        it.add(m, "Rename…", "rename")
    } else {
        it.add(m, "Rename in the editor…", "bulk-rename")
    };
    m = it.add(m, "Properties…", "properties").separator();
    m = it
        .add(m, "Move to the trash", "trash")
        .icon(Icon::themed("user-trash", Icon::Trash));
    m = it.add(m, "Delete permanently…", "delete").separator();
    it.add(m, "Run a shell command…", "shell-prompt")
}

/// The folder's menu: making, pasting, a terminal, what shows, and the sort.
fn folder(it: &mut Items<'_>) -> Menu {
    let s = it.s;
    let sort = s.options.sort;
    let mut sorts = Menu::new();
    for (label, key, cmd) in [
        ("Name", strider_core::options::SortKey::Name, "sort name"),
        ("Size", strider_core::options::SortKey::Size, "sort size"),
        (
            "Modified",
            strider_core::options::SortKey::Modified,
            "sort modified",
        ),
        ("Type", strider_core::options::SortKey::Type, "sort type"),
        (
            "Extension",
            strider_core::options::SortKey::Extension,
            "sort extension",
        ),
    ] {
        sorts = it.check(sorts, label, cmd, sort.key == key);
    }
    sorts = sorts.separator();
    sorts = it.check(sorts, "Reverse", "sort-reverse", sort.descending);
    sorts = it.check(
        sorts,
        "Folders first",
        "sort-dirs-first",
        sort.folders_first,
    );

    let mut m = it.add(Menu::new(), "New file or folder…", "create");
    m = it.add(m, "Paste here", "paste");
    if !can_paste(s) {
        m = m.disabled();
    }
    m = it.add(m, "Select everything", "mark-all").separator();
    m = it.add(m, "Open terminal here", "terminal");
    m = it
        .add(m, "Run a shell command…", "shell-prompt")
        .separator();
    m = it.check(m, "Hidden files", "toggle-hidden", s.options.show_hidden);
    m = m.submenu("Sort by", sorts).separator();
    m = it.add(m, "Reload", "reload");
    it.add(m, "Tasks", "tasks")
}

/// The open-with menu at the cursor: applications named `names`, numbered from 1, after a
/// Terminal item for a `folder`. `chosen` hears the item's index.
pub fn open_with<F>(
    s: &mut Strider,
    tx: &mut Txn<'_, Strider>,
    folder: bool,
    names: &[String],
    chosen: F,
) -> Result<()>
where
    F: for<'t> FnMut(&mut Strider, &mut Txn<'t, Strider>, usize) -> Result<()> + 'static,
{
    let terminal = folder.then(|| "Terminal".to_owned());
    let mut menu = Menu::new();
    for (i, name) in terminal.iter().chain(names).enumerate() {
        // An underscore in a name is no mnemonic: the digit is.
        let item = Menu::new().item(i, &name.replace('_', "__"));
        let item = if i < 9 {
            item.trailing(&(i + 1).to_string())
        } else {
            item
        };
        let mut entries = item.entries().to_vec();
        if i < 9 {
            entries[0].mnemonic = char::from_digit(i as u32 + 1, 10);
        }
        menu.extend(entries);
    }
    let mut chosen = chosen;
    let menu = menu.on_command(
        move |s: &mut Strider, tx, i| {
            if s.here(tx) { chosen(s, tx, i) } else { Ok(()) }
        },
    );
    let at = cursor_point(s, tx)?;
    widgets::open_context_menu(tx, s.ui.lists[Col::Current as usize], at, &menu)
}
