//! The services on a private session bus, as the Zig build's tests/services.zig drove them
//! against a private dbus-daemon: FileManager1's three methods, and FileChooser requests
//! answered by keys and clicks in their windows.
//!
//! A FileChooser call is answered only once the user picks, so the test cannot wait for its
//! reply as [`Headless::bus_call`] does: the app calls its own portal object, as
//! xdg-desktop-portal would, and a hook on the app's session bus keeps the replies.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use keywork::app::Headless;
use keywork::app::tooling::{Action, NodeQuery, Target};
use keywork::dbus::{Array, BusEvent, CallId, Message, ObjectPath, Value};
use keywork::desktop::localtime::Zone;
use keywork::{Editor, Role};
use strider_core::config::Config;

use super::*;
use crate::app::{self, Strider};
use crate::scenes;

type H = Headless<Strider>;
type Replies = Rc<RefCell<Vec<(CallId, Vec<Value>)>>>;

/// The app on the chooser fixture, its main window on `home`, on a session bus of its own,
/// with `state` as its state folder; and where the replies to its own calls land.
fn start(name: &str, state: Option<PathBuf>) -> (H, PathBuf, WindowId, Replies) {
    let root = scenes::chooser_fixture(name);
    let (mut app, mut s) = crate::base(
        root.clone(),
        Config::default(),
        Zone::utc(),
        true,
        state,
        None,
    )
    .unwrap();
    let window = app.open_window(app::window_desc()).unwrap();
    let ui = app.update(window, app::build).unwrap();
    let home = root.join("home");
    app::adopt(&mut s, window, ui, &home);
    app.update(window, |tx| app::show_start(&mut s, tx, home, None))
        .unwrap();
    let replies: Replies = Rc::default();
    let keep = replies.clone();
    app.on_session_bus(move |_, _, ev| {
        if let BusEvent::Reply {
            call,
            result: Ok(m),
        } = ev
        {
            keep.borrow_mut().push((*call, m.body.clone()));
        }
        Ok(())
    });
    let mut h = app.headless_with_bus(s).unwrap();
    h.settle().unwrap();
    pump(&mut h);
    (h, root, window, replies)
}

/// Runs the app and routes what it sent on the bus until both are idle.
fn pump(h: &mut H) {
    for _ in 0..6 {
        h.bus_names().unwrap();
        h.settle().unwrap();
    }
}

fn uri(p: &Path) -> String {
    let mut u = String::new();
    strider_core::uri::push_file_uri(&mut u, p);
    u
}

fn bytes(p: &Path) -> Value {
    use std::os::unix::ffi::OsStrExt;
    let mut b: Vec<Value> = p
        .as_os_str()
        .as_bytes()
        .iter()
        .map(|&b| Value::Byte(b))
        .collect();
    b.push(Value::Byte(0));
    Value::Array(Array::new("y", b).unwrap())
}

fn folder(root: &Path, rel: &str) -> (&'static str, Value) {
    ("current_folder", bytes(&root.join(rel)))
}

fn filter(name: &str, rules: &[(u32, &str)]) -> Value {
    let rules = rules
        .iter()
        .map(|(k, p)| Value::Struct(vec![Value::U32(*k), Value::str(*p)]))
        .collect();
    Value::Struct(vec![
        Value::str(name),
        Value::Array(Array::new("(us)", rules).unwrap()),
    ])
}

fn firefox_save(root: &Path) -> Vec<(&'static str, Value)> {
    let filters = [
        ("Web Page, complete", "*.html"),
        ("Web Page, HTML only", "*.htm"),
        ("Text Files", "*.txt"),
        ("All Files", "*"),
    ]
    .iter()
    .map(|(n, g)| filter(n, &[(0, g)]))
    .collect();
    vec![
        folder(root, "work"),
        ("current_name", Value::str("New Tab.html")),
        (
            "filters",
            Value::Array(Array::new("(sa(us))", filters).unwrap()),
        ),
    ]
}

/// A FileChooser call as xdg-desktop-portal makes it, from the app to its own portal
/// object; returns at once with the call, and the request's handle.
fn call(
    h: &mut H,
    member: &str,
    title: &str,
    options: Vec<(&'static str, Value)>,
) -> (CallId, String) {
    thread_local!(static SERIAL: std::cell::Cell<u32> = const { std::cell::Cell::new(0) });
    let n = SERIAL.with(|c| {
        c.set(c.get() + 1);
        c.get()
    });
    let handle = format!("/org/freedesktop/portal/desktop/request/1_42/t{n}");
    let msg = Message::method_call(Some(PORTAL), PORTAL_PATH, Some(FILE_CHOOSER), member)
        .unwrap()
        .with_body(vec![
            Value::Path(ObjectPath::new(&handle).unwrap()),
            Value::str("org.example.Editor"),
            Value::str("wayland:caller-handle"),
            Value::str(title),
            Value::Array(Array::dict(
                options.into_iter().map(|(k, v)| (k.to_owned(), v)),
            )),
        ]);
    let id = h.with_cx(|_, cx| cx.session_bus().unwrap().call(msg).unwrap());
    pump(h);
    (id, handle)
}

/// The chooser window open, and its field.
fn chooser(h: &H) -> (WindowId, NodeId<Editor>) {
    let ch = h
        .state()
        .services
        .choosers
        .last()
        .expect("a chooser window");
    (ch.window, ch.bar.as_ref().expect("its bar").field)
}

/// What the portal answered: the response, the URIs, the choices, and the filter's name.
#[derive(Debug, Default)]
struct Answer {
    response: u32,
    uris: Vec<String>,
    choices: Vec<(String, String)>,
    filter: String,
}

/// The answer to `id`, which must have come; the chooser's window went with it.
fn answered(h: &mut H, replies: &Replies, id: CallId) -> Answer {
    pump(h);
    let m = replies
        .borrow()
        .iter()
        .find(|(c, _)| *c == id)
        .map(|(_, m)| m.clone())
        .expect("the request was answered");
    assert!(h.state().services.choosers.is_empty(), "the chooser went");
    let mut a = Answer {
        response: m[0].as_u32().unwrap(),
        ..Answer::default()
    };
    for (k, v) in m[1].dict_entries() {
        let v = v.unwrap_variants();
        match k.as_str().unwrap() {
            "uris" => {
                a.uris = v
                    .as_array()
                    .unwrap()
                    .items()
                    .iter()
                    .map(|u| u.as_str().unwrap().to_owned())
                    .collect();
            }
            "choices" => {
                for c in v.as_array().unwrap().items() {
                    let Value::Struct(f) = c else { panic!() };
                    a.choices
                        .push((f[0].as_str().unwrap().into(), f[1].as_str().unwrap().into()));
                }
            }
            "current_filter" => {
                let Value::Struct(f) = v else { panic!() };
                a.filter = f[0].as_str().unwrap().into();
            }
            _ => {}
        }
    }
    a
}

fn pending(replies: &Replies, id: CallId) -> bool {
    !replies.borrow().iter().any(|(c, _)| *c == id)
}

/// Types `text` in `window`: characters as typed text, `\n`, `\t`, and `\x1b` as keys.
fn typ(h: &mut H, window: WindowId, text: &str) {
    for c in text.chars() {
        let sym = match c {
            '\n' => Keysym::RETURN,
            '\t' => Keysym::TAB,
            '\x1b' => Keysym::ESCAPE,
            c => {
                h.perform(window, &Action::Type(c.to_string())).unwrap();
                h.settle().unwrap();
                continue;
            }
        };
        h.key(window, sym, Modifiers::NONE).unwrap();
        h.settle().unwrap();
    }
    pump(h);
}

fn tap(h: &mut H, window: WindowId, role: Role, label: &str) {
    let q = NodeQuery::role_label(role, label);
    h.perform(window, &Action::Tap(Target::Node(q))).unwrap();
    pump(h);
}

fn node(h: &mut H, window: WindowId, role: Role, label: &str) -> keywork::app::tooling::NodeInfo {
    let found = h
        .query(window, &NodeQuery::role_label(role, label))
        .unwrap();
    found
        .into_iter()
        .next()
        .unwrap_or_else(|| panic!("no {role:?} {label:?}"))
}

fn win(h: &H, window: WindowId) -> &app::Win {
    h.state().wins.iter().find(|w| w.window == window).unwrap()
}

/// The folder window `window` shows, and the entries it shows.
fn shown(h: &H, window: WindowId) -> (PathBuf, Vec<String>) {
    let w = win(h, window);
    let f = h.state().cache.get(&w.cwd).unwrap();
    let names = (0..f.len())
        .map(|i| String::from_utf8_lossy(f.name(i)).into_owned())
        .collect();
    (w.cwd.clone(), names)
}

fn hovered(h: &H, window: WindowId) -> String {
    let w = win(h, window);
    let f = h.state().cache.get(&w.cwd).unwrap();
    String::from_utf8_lossy(f.current_name().unwrap_or(b"")).into_owned()
}

fn insert_mode(h: &H, window: WindowId, field: NodeId<Editor>) -> bool {
    h.focused(window).unwrap() == Some(field.any())
}

fn field_text(h: &mut H, window: WindowId, field: NodeId<Editor>) -> String {
    h.update(window, |tx| Ok(tx.editor_text(field)?.to_string()))
        .unwrap()
}

fn badge(h: &mut H, window: WindowId) -> String {
    let n = win(h, window).ui.status_mode;
    h.tree(window).unwrap().text_content(n).unwrap().to_owned()
}

fn message(h: &H, window: WindowId) -> String {
    win(h, window)
        .message
        .as_ref()
        .map(|m| m.0.clone())
        .unwrap_or_default()
}

// FileManager1 --------------------------------------------------------------------------------

fn show(h: &mut H, member: &str, path: &Path) -> Message {
    let uris = Value::Array(Array::new("s", vec![Value::str(uri(path))]).unwrap());
    let msg = Message::method_call(
        Some(FILE_MANAGER),
        FILE_MANAGER_PATH,
        Some(FILE_MANAGER),
        member,
    )
    .unwrap()
    .with_body(vec![uris, Value::str("")]);
    let reply = h.bus_call(msg).unwrap();
    h.settle().unwrap();
    reply
}

// Other applications' "Show in folder", "Open folder", and "Properties": ShowItems shows a
// folder under the cursor in its parent, in a new tab; ShowFolders opens the folder itself;
// ShowItemProperties puts the file under the cursor. Both names are taken. Calls with the
// wrong arguments or method are refused. Catches: a method mapped to the wrong action, a
// folder opened where it should be shown, URIs lost, the call left unanswered.
#[test]
fn file_manager1_shows_items_folders_and_properties() {
    let (mut h, root, main, _) = start("fm1", None);
    std::fs::create_dir_all(root.join("Projects/siv")).unwrap();
    let names = h.bus_names().unwrap();
    assert!(names.iter().any(|n| n == FILE_MANAGER), "{names:?}");
    assert!(names.iter().any(|n| n == PORTAL), "{names:?}");

    let reply = show(&mut h, "ShowItems", &root.join("Projects/siv"));
    assert_eq!(reply.kind, keywork::dbus::MessageKind::MethodReturn);
    assert_eq!(win(&h, main).tabs.len(), 2);
    assert_eq!(shown(&h, main).0, root.join("Projects"));
    assert_eq!(hovered(&h, main), "siv");

    show(&mut h, "ShowFolders", &root.join("Projects/siv"));
    assert_eq!(win(&h, main).tabs.len(), 3);
    assert_eq!(shown(&h, main).0, root.join("Projects/siv"));

    show(&mut h, "ShowItemProperties", &root.join("work/notes.txt"));
    assert_eq!(win(&h, main).tabs.len(), 4);
    assert_eq!(hovered(&h, main), "notes.txt");
    assert_eq!(h.windows(), vec![main]);

    let bad = Message::method_call(
        Some(FILE_MANAGER),
        FILE_MANAGER_PATH,
        Some(FILE_MANAGER),
        "ShowFolders",
    )
    .unwrap()
    .with_body(vec![Value::str("file:///tmp")]);
    let reply = h.bus_call(bad).unwrap();
    assert_eq!(
        reply.error_name.as_deref(),
        Some("org.freedesktop.DBus.Error.InvalidArgs")
    );
    let unknown = Message::method_call(
        Some(FILE_MANAGER),
        FILE_MANAGER_PATH,
        Some(FILE_MANAGER),
        "Frobnicate",
    )
    .unwrap();
    let reply = h.bus_call(unknown).unwrap();
    assert!(reply.error_name.is_some());
    let _ = std::fs::remove_dir_all(&root);
}

// With no window open, as a service started for the call, ShowItems opens one on the item's
// folder with the item under the cursor. Catches: a call that shows nothing without a window.
#[test]
fn file_manager1_opens_a_window_when_none_is() {
    let (mut h, root, main, _) = start("fm1-none", None);
    h.request_close(main).unwrap();
    h.settle().unwrap();
    assert!(h.windows().is_empty());
    show(&mut h, "ShowItems", &root.join("work/scan.jpg"));
    let windows = h.windows();
    assert_eq!(windows.len(), 1);
    assert_eq!(shown(&h, windows[0]).0, root.join("work"));
    assert_eq!(hovered(&h, windows[0]), "scan.jpg");
    let _ = std::fs::remove_dir_all(&root);
}

// FileChooser ---------------------------------------------------------------------------------

// One file: the folder asked for, the accept label without its mnemonic, the title; Enter on
// a folder goes in, Enter on a file picks it. Several: marks pick them, in order, and the
// next chooser starts where the last picked. Folders: Enter picks the folder under the
// cursor. A double click on a file picks it. Catches: the wrong folder, the wrong file, a
// folder picked where a file was asked for, marks ignored, the window left open.
#[test]
fn open_one_file_several_and_folders() {
    let (mut h, root, main, replies) = start("chooser-open", None);
    let work = root.join("work");
    let (one, _) = call(
        &mut h,
        "OpenFile",
        "Insert a picture",
        vec![
            folder(&root, "work"),
            ("accept_label", Value::str("_Insert")),
        ],
    );
    let (w, _) = chooser(&h);
    assert_eq!(shown(&h, w).0, work);
    node(&mut h, w, Role::Button, "Insert");
    node(&mut h, w, Role::Button, "Cancel");
    assert_eq!(
        h.state().services.choosers[0].req.window_title(),
        "Insert a picture"
    );
    typ(&mut h, w, "fph");
    assert_eq!(hovered(&h, w), "photo.png");
    typ(&mut h, w, "fsr\nh");
    assert_eq!(shown(&h, w).0, work);
    assert!(pending(&replies, one));
    typ(&mut h, w, "fph\n");
    let a = answered(&mut h, &replies, one);
    assert_eq!(a.response, 0);
    assert_eq!(a.uris, [uri(&work.join("photo.png"))]);
    assert_eq!(h.windows(), vec![main]);

    let (several, _) = call(
        &mut h,
        "OpenFile",
        "",
        vec![("multiple", Value::Bool(true))],
    );
    let (w, _) = chooser(&h);
    assert_eq!(shown(&h, w).0, work, "where the last chooser picked");
    typ(&mut h, w, "fno fsc \n");
    let a = answered(&mut h, &replies, several);
    assert_eq!(
        a.uris,
        [uri(&work.join("notes.txt")), uri(&work.join("scan.jpg"))]
    );

    let (folders, _) = call(
        &mut h,
        "OpenFile",
        "",
        vec![folder(&root, "work"), ("directory", Value::Bool(true))],
    );
    let (w, _) = chooser(&h);
    node(&mut h, w, Role::Button, "Choose");
    typ(&mut h, w, "fsr\n");
    let a = answered(&mut h, &replies, folders);
    assert_eq!(a.uris, [uri(&work.join("src"))]);

    let (clicked, _) = call(&mut h, "OpenFile", "", vec![folder(&root, "work")]);
    let (w, _) = chooser(&h);
    let row = node(&mut h, w, Role::ListItem, "build.zig")
        .center()
        .unwrap();
    h.click(w, row.x, row.y).unwrap();
    assert!(
        pending(&replies, clicked),
        "one click only moves the cursor"
    );
    // The second press picks, and the window is gone by its release.
    let _ = h.click(w, row.x, row.y);
    let a = answered(&mut h, &replies, clicked);
    assert_eq!(a.uris, [uri(&work.join("build.zig"))]);
    let _ = std::fs::remove_dir_all(&root);
}

// Filters: the first shows only the files it admits (a glob in any case, a MIME type) and
// every folder; another shows others; the main window shows the folder unfiltered once the
// chooser is done. Choices come back as the bar left them, a check box by a click, with the
// filter shown. Catches: filters hiding folders, a glob matched by case, a filter left on
// the main window's folder, choices or the filter missing from the answer.
#[test]
fn filters_hide_files_and_choices_come_back() {
    let (mut h, root, main, replies) = start("chooser-filters", None);
    let work = root.join("work");
    let filters = Value::Array(
        Array::new(
            "(sa(us))",
            vec![
                filter("Images", &[(0, "*.PNG"), (1, "image/jpeg")]),
                filter("Text", &[(0, "*.txt")]),
            ],
        )
        .unwrap(),
    );
    let sizes = Value::Array(
        Array::new(
            "(ss)",
            vec![
                Value::Struct(vec![Value::str("small"), Value::str("Small")]),
                Value::Struct(vec![Value::str("large"), Value::str("Large")]),
            ],
        )
        .unwrap(),
    );
    let choices = Value::Array(
        Array::new(
            "(ssa(ss)s)",
            vec![
                Value::Struct(vec![
                    Value::str("size"),
                    Value::str("Size"),
                    sizes,
                    Value::str("large"),
                ]),
                Value::Struct(vec![
                    Value::str("link"),
                    Value::str("_Link instead of copying"),
                    Value::Array(Array::new("(ss)", Vec::new()).unwrap()),
                    Value::str("false"),
                ]),
            ],
        )
        .unwrap(),
    );
    let (id, _) = call(
        &mut h,
        "OpenFile",
        "",
        vec![
            folder(&root, "work"),
            ("filters", filters),
            ("choices", choices),
        ],
    );
    let (w, _) = chooser(&h);
    assert_eq!(shown(&h, w).1, ["src", "photo.png", "scan.jpg"]);
    node(&mut h, w, Role::ComboBox, "Filter");
    node(&mut h, w, Role::ComboBox, "Size");
    // Another filter: the text files.
    let combo = h.state().services.choosers[0]
        .bar
        .as_ref()
        .unwrap()
        .filter
        .unwrap();
    h.with_cx(|s, cx| {
        app::in_window(s, cx, Some(w), |s, tx| {
            keywork::widgets::set_combo_selected(tx, combo, Some(1))?;
            crate::chooser::set_filter(s, tx, 1)
        })
    })
    .unwrap();
    h.settle().unwrap();
    assert_eq!(shown(&h, w).1, ["src", "notes.txt", "report.txt"]);
    tap(&mut h, w, Role::CheckBox, "Link instead of copying");
    typ(&mut h, w, "fno\n");
    let a = answered(&mut h, &replies, id);
    assert_eq!(a.response, 0);
    assert_eq!(a.uris, [uri(&work.join("notes.txt"))]);
    assert_eq!(
        a.choices,
        [
            ("size".to_owned(), "large".to_owned()),
            ("link".to_owned(), "true".to_owned())
        ]
    );
    assert_eq!(a.filter, "Text");
    // The main window, in work, shows every entry.
    typ(&mut h, main, ":cd ../work\n");
    assert_eq!(shown(&h, main).1.len(), 6);
    let _ = std::fs::remove_dir_all(&root);
}

// A new name: the name field has the keys, its stem selected, so typing replaces the stem.
// A name that exists asks first: Escape keeps the chooser, Replace answers; Chromium's "All
// Files" title is no title. Enter on a file in the columns saves over it, asking again.
// Several files: a folder, the names in it. Catches: a file replaced without asking, the
// dialog's Cancel cancelling the request, the stem not selected, SaveFiles' names lost.
#[test]
fn save_asks_before_replacing_and_saves_several() {
    let (mut h, root, _, replies) = start("chooser-save", None);
    let work = root.join("work");
    let (fresh, _) = call(
        &mut h,
        "SaveFile",
        "Save the report",
        vec![
            folder(&root, "work"),
            ("current_name", Value::str("report.txt")),
        ],
    );
    let (w, field) = chooser(&h);
    assert!(insert_mode(&h, w, field));
    node(&mut h, w, Role::Button, "Save");
    typ(&mut h, w, "summary\n");
    let a = answered(&mut h, &replies, fresh);
    assert_eq!(a.response, 0);
    assert_eq!(a.uris, [uri(&work.join("summary.txt"))]);

    let (over, _) = call(
        &mut h,
        "SaveFile",
        "All Files",
        vec![("current_file", bytes(&work.join("report.txt")))],
    );
    let (w, field) = chooser(&h);
    assert_eq!(
        h.state().services.choosers[0].req.window_title(),
        "Save a File"
    );
    assert_eq!(hovered(&h, w), "report.txt");
    typ(&mut h, w, "\n");
    assert!(win(&h, w).wops.dialog.is_some());
    node(&mut h, w, Role::Button, "Replace");
    typ(&mut h, w, "\x1b");
    assert!(win(&h, w).wops.dialog.is_none());
    assert!(pending(&replies, over));
    assert!(insert_mode(&h, w, field), "back to the name");
    // Tab goes to the columns (normal mode); Enter on the file there saves over it.
    typ(&mut h, w, "\t");
    assert!(!insert_mode(&h, w, field));
    typ(&mut h, w, "\n");
    assert!(win(&h, w).wops.dialog.is_some());
    tap(&mut h, w, Role::Button, "Replace");
    let a = answered(&mut h, &replies, over);
    assert_eq!(a.uris, [uri(&work.join("report.txt"))]);

    let names = Value::Array(
        Array::new(
            "ay",
            vec![bytes(Path::new("a.txt")), bytes(Path::new("b.txt"))],
        )
        .unwrap(),
    );
    let (many, _) = call(
        &mut h,
        "SaveFiles",
        "",
        vec![folder(&root, "work"), ("files", names)],
    );
    let (w, _) = chooser(&h);
    typ(&mut h, w, "fsr\n");
    let a = answered(&mut h, &replies, many);
    assert_eq!(
        a.uris,
        [uri(&work.join("src/a.txt")), uri(&work.join("src/b.txt"))]
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Escape clears the marks first, then cancels (1); the Cancel button cancels; Close on the
// request object answers 2 after its own reply, and the window goes. Catches: Escape
// cancelling with marks to clear, Close left unanswered or answered with the wrong code.
#[test]
fn escape_and_cancel_cancel_and_close_ends() {
    let (mut h, _root, main, replies) = start("chooser-cancel", None);
    let (esc, _) = call(&mut h, "OpenFile", "", Vec::new());
    let (w, _) = chooser(&h);
    typ(&mut h, w, " ");
    assert_eq!(h.state().cache.get(&win(&h, w).cwd).unwrap().marks.len(), 1);
    typ(&mut h, w, "\x1b");
    assert!(pending(&replies, esc));
    typ(&mut h, w, "\x1b");
    let a = answered(&mut h, &replies, esc);
    assert_eq!(a.response, 1);
    assert!(a.uris.is_empty());

    let (button, _) = call(&mut h, "SaveFile", "", Vec::new());
    let (w, _) = chooser(&h);
    tap(&mut h, w, Role::Button, "Cancel");
    assert_eq!(answered(&mut h, &replies, button).response, 1);

    let (closed, handle) = call(&mut h, "OpenFile", "", Vec::new());
    chooser(&h);
    let close = Message::method_call(Some(PORTAL), &handle, Some(REQUEST), "Close").unwrap();
    let reply = h.bus_call(close).unwrap();
    assert_eq!(reply.kind, keywork::dbus::MessageKind::MethodReturn);
    assert_eq!(answered(&mut h, &replies, closed).response, 2);
    assert_eq!(h.windows(), vec![main]);
    // The request object went with it.
    let close = Message::method_call(Some(PORTAL), &handle, Some(REQUEST), "Close").unwrap();
    let reply = h.bus_call(close).unwrap();
    assert!(reply.error_name.is_some());
    let _ = std::fs::remove_dir_all(&_root);
}

// Saving is modal like vim: insert mode in the name first, the stem selected; Escape goes to
// normal mode, where keys move in the columns; i comes back with the stem still selected; I,
// a, A, cc, and S put the caret at the start, after the stem, at the end, or clear the name,
// over the keymap's rename, create, and terminal; clicks choose the mode too. A path in the
// name saves in that folder. Escape twice cancels; q in normal mode cancels. Catches: keys
// typed into the name moving the columns or the reverse, a mode key running its command,
// the badge out of step with the focus.
#[test]
fn save_has_vims_modes() {
    let (mut h, root, _, replies) = start("chooser-modes", None);
    let work = root.join("work");
    let (saved, _) = call(&mut h, "SaveFile", "", firefox_save(&root));
    let (w, field) = chooser(&h);
    assert!(insert_mode(&h, w, field));
    assert_eq!(badge(&mut h, w), "INSERT");
    typ(&mut h, w, "\x1b");
    assert!(!insert_mode(&h, w, field));
    assert_eq!(badge(&mut h, w), "NORMAL");
    assert!(pending(&replies, saved));
    typ(&mut h, w, "gg");
    assert_eq!(hovered(&h, w), "src");
    typ(&mut h, w, "i");
    assert!(insert_mode(&h, w, field));
    typ(&mut h, w, "page");
    assert_eq!(field_text(&mut h, w, field), "page.html");
    typ(&mut h, w, "\x1bImy-\x1ba-2");
    assert_eq!(field_text(&mut h, w, field), "my-page-2.html");
    typ(&mut h, w, "\x1bAx");
    assert_eq!(field_text(&mut h, w, field), "my-page-2.htmlx");
    typ(&mut h, w, "\x1bcc");
    assert!(insert_mode(&h, w, field));
    assert_eq!(field_text(&mut h, w, field), "");
    typ(&mut h, w, "x\x1bS");
    assert_eq!(field_text(&mut h, w, field), "");
    assert!(h.state().wins.len() == 2, "S ran no terminal, a no create");
    // Clicks choose the mode too.
    let row = node(&mut h, w, Role::ListItem, "src").center().unwrap();
    h.click(w, row.x, row.y).unwrap();
    pump(&mut h);
    assert!(!insert_mode(&h, w, field));
    assert_eq!(badge(&mut h, w), "NORMAL");
    tap(&mut h, w, Role::TextInput, "Name");
    assert!(insert_mode(&h, w, field));
    assert_eq!(badge(&mut h, w), "INSERT");
    typ(&mut h, w, "src/../src/new.txt\n");
    let a = answered(&mut h, &replies, saved);
    assert_eq!(a.response, 0);
    assert_eq!(a.uris, [uri(&work.join("src/new.txt"))]);

    let (twice, _) = call(&mut h, "SaveFile", "", firefox_save(&root));
    let (w, _) = chooser(&h);
    typ(&mut h, w, "\x1b\x1b");
    assert_eq!(answered(&mut h, &replies, twice).response, 1);
    let (quit, _) = call(&mut h, "SaveFile", "", firefox_save(&root));
    let (w, _) = chooser(&h);
    typ(&mut h, w, "\x1bq");
    assert_eq!(answered(&mut h, &replies, quit).response, 1);
    let _ = std::fs::remove_dir_all(&root);
}

// Open and folder choosers type a path in insert mode: normal mode first, the field empty
// (its placeholder the keys); i fills it with the folder shown, ~ for home; Escape empties
// it. Tab completes as :cd does, the candidates shown when several fit; Enter on a folder
// goes there in normal mode; nothing there is an error, still in insert mode; a file is
// picked. Choosing folders refuses a file's path and picks a folder's. SaveFiles saves in
// the folder typed. Catches: a typed path ignored or resolved against the wrong folder, a
// file picked where a folder was asked for.
#[test]
fn open_and_folder_choosers_type_a_path() {
    let (mut h, root, _, replies) = start("chooser-path", None);
    let work = root.join("work");
    let (opened, _) = call(&mut h, "OpenFile", "", vec![folder(&root, "work")]);
    let (w, field) = chooser(&h);
    assert!(!insert_mode(&h, w, field));
    assert_eq!(badge(&mut h, w), "NORMAL");
    assert_eq!(field_text(&mut h, w, field), "");
    typ(&mut h, w, "i");
    assert!(insert_mode(&h, w, field));
    assert_eq!(field_text(&mut h, w, field), "~/work/");
    typ(&mut h, w, "\x1b");
    assert!(!insert_mode(&h, w, field));
    assert_eq!(field_text(&mut h, w, field), "");
    assert!(pending(&replies, opened));
    typ(&mut h, w, "isr\t");
    assert_eq!(field_text(&mut h, w, field), "~/work/src/");
    typ(&mut h, w, "\n");
    assert_eq!(shown(&h, w).0, work.join("src"));
    assert!(!insert_mode(&h, w, field));
    typ(&mut h, w, "cc../\t");
    assert_eq!(field_text(&mut h, w, field), "../");
    let which = win(&h, w).ui.which_key;
    let tree = h.tree(w).unwrap();
    assert!(!tree.is_hidden(which).unwrap(), "the candidates show");
    typ(&mut h, w, "nothing\n");
    assert!(insert_mode(&h, w, field));
    assert!(pending(&replies, opened));
    assert!(message(&h, w).starts_with("No such file or folder"));
    typ(&mut h, w, "\x1b");
    assert_eq!(field_text(&mut h, w, field), "");
    typ(&mut h, w, "S../no\t");
    assert_eq!(field_text(&mut h, w, field), "../notes.txt");
    typ(&mut h, w, "\n");
    let a = answered(&mut h, &replies, opened);
    assert_eq!(a.uris, [uri(&work.join("notes.txt"))]);

    let (folders, _) = call(
        &mut h,
        "OpenFile",
        "",
        vec![folder(&root, "work"), ("directory", Value::Bool(true))],
    );
    let (w, _) = chooser(&h);
    typ(&mut h, w, "Anotes.txt\n");
    assert_eq!(message(&h, w), "Choose a folder");
    typ(&mut h, w, "\x1bcc");
    typ(&mut h, w, &format!("{}\n", work.join("src").display()));
    let a = answered(&mut h, &replies, folders);
    assert_eq!(a.uris, [uri(&work.join("src"))]);

    let names = Value::Array(Array::new("ay", vec![bytes(Path::new("a.txt"))]).unwrap());
    let (many, _) = call(
        &mut h,
        "SaveFiles",
        "",
        vec![folder(&root, "work"), ("files", names)],
    );
    let (w, _) = chooser(&h);
    typ(&mut h, w, "Asrc\n");
    let a = answered(&mut h, &replies, many);
    assert_eq!(a.uris, [uri(&work.join("src/a.txt"))]);

    let (twice, _) = call(&mut h, "OpenFile", "", vec![folder(&root, "work")]);
    let (w, _) = chooser(&h);
    typ(&mut h, w, "i\x1b\x1b");
    assert_eq!(answered(&mut h, &replies, twice).response, 1);
    let _ = std::fs::remove_dir_all(&root);
}

// A narrow window keeps its buttons on screen, and its parent column before its preview;
// the compositor's close cancels; a size the user gives a chooser is the next one's, kept in
// the state folder. Catches: buttons pushed out of a narrow window, a closed window leaving
// its caller waiting, the size forgotten or not saved.
#[test]
fn narrow_windows_closing_and_the_size_kept() {
    let state = std::env::temp_dir().join(format!("strider-chooser-state-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&state);
    std::fs::create_dir_all(&state).unwrap();
    let (mut h, root, main, replies) = start("chooser-narrow", Some(state.clone()));
    let (narrow, _) = call(&mut h, "SaveFile", "Save As", firefox_save(&root));
    let (w, field) = chooser(&h);
    for (width, height) in [(600, 400), (360, 240), (960, 1040)] {
        h.resize(w, width, height, 1.0).unwrap();
        h.settle().unwrap();
        for label in ["Cancel", "Save"] {
            let r = node(&mut h, w, Role::Button, label).rect;
            assert!(
                r.width > 20.0 && r.x >= 0.0 && r.x + r.width <= width as f32,
                "{label} at {width}: {r:?}"
            );
        }
        if width == 600 {
            let parent = win(&h, w).ui.panes[0];
            let preview = win(&h, w).ui.panes[2];
            let tree = h.tree(w).unwrap();
            assert!(!tree.is_hidden(parent).unwrap() && tree.is_hidden(preview).unwrap());
        }
    }
    assert!(insert_mode(&h, w, field));
    typ(&mut h, w, "\x1b");
    assert!(pending(&replies, narrow));
    typ(&mut h, w, "\x1b");
    assert_eq!(answered(&mut h, &replies, narrow).response, 1);

    let (closed, _) = call(&mut h, "OpenFile", "", firefox_save(&root));
    let (w, _) = chooser(&h);
    h.request_close(w).unwrap();
    assert_eq!(answered(&mut h, &replies, closed).response, 1);
    assert_eq!(h.windows(), vec![main]);

    // The size the user gave: the last chooser's, here 960x1040 resized to 820x560.
    std::fs::remove_file(state.join("chooser")).ok();
    let (sized, _) = call(&mut h, "OpenFile", "", Vec::new());
    let (w, _) = chooser(&h);
    assert_eq!(h.state().services.choosers[0].opened, [960, 1040]);
    h.resize(w, 820, 560, 1.0).unwrap();
    // Laid out at that size, as a frame does.
    h.render(w).unwrap();
    typ(&mut h, w, "\x1b");
    answered(&mut h, &replies, sized);
    assert_eq!(
        strider_core::state::load_chooser_size(&state),
        Some([820, 560])
    );
    let (again, _) = call(&mut h, "OpenFile", "", Vec::new());
    let (w, _) = chooser(&h);
    let img = h.render(w).unwrap();
    assert_eq!((img.width(), img.height()), (820, 560));
    typ(&mut h, w, "\x1b");
    answered(&mut h, &replies, again);
    // :set chooser_size wins over the size remembered, which is forgotten.
    typ(&mut h, main, ":set chooser_size 700x500\n");
    assert_eq!(strider_core::state::load_chooser_size(&state), None);
    let (set, _) = call(&mut h, "OpenFile", "", Vec::new());
    assert_eq!(h.state().services.choosers[0].opened, [700, 500]);
    let (w, _) = chooser(&h);
    typ(&mut h, w, "\x1b");
    answered(&mut h, &replies, set);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&state);
}

// What gets installed names what the program serves: each D-Bus service file the name the
// bus starts the program for, in service mode, and the portal file the portal's name and
// interface. Catches: a name renamed in the code but not in the files, which leaves
// xdg-desktop-portal or the bus unable to find the program.
#[test]
fn the_installed_files_name_the_services() {
    let services = [
        (
            include_str!("../../../../data/org.freedesktop.impl.portal.desktop.strider.service"),
            PORTAL,
        ),
        (
            include_str!("../../../../data/org.freedesktop.FileManager1.service"),
            FILE_MANAGER,
        ),
        (
            include_str!("../../../../data/dev.rockorager.Strider.service"),
            crate::instance::APP_ID,
        ),
    ];
    for (file, name) in services {
        assert!(file.starts_with("[D-BUS Service]\n"), "{file}");
        assert!(file.contains(&format!("\nName={name}\n")), "{file}");
        assert!(
            file.contains("\nExec=@PREFIX@/bin/strider --service\n"),
            "{file}"
        );
    }
    let portal = include_str!("../../../../data/strider.portal");
    assert!(
        portal.contains(&format!("\nDBusName={PORTAL}\n")),
        "{portal}"
    );
    assert!(
        portal.contains(&format!("\nInterfaces={FILE_CHOOSER}\n")),
        "{portal}"
    );
    let chooser = include_str!("../../../../data/dev.rockorager.Strider.Chooser.desktop");
    assert_eq!(
        format!("{}.Chooser", crate::instance::APP_ID),
        crate::chooser::APP_ID
    );
    assert!(chooser.contains("\nNoDisplay=true\n"), "{chooser}");
}
