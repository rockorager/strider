//! Strider's services on the session bus, as the Zig build's FileManager1.zig and Portal.zig
//! served them, on the connection Keywork already has ([`Cx::session_bus`]):
//!
//! - `org.freedesktop.FileManager1`: other applications' "Show in folder" (ShowItems), "Open
//!   folder" (ShowFolders), and "Properties" (ShowItemProperties). The name is asked for with
//!   queueing and allowing replacement: a file manager that runs first keeps it, this one
//!   takes over when that one quits, and a file manager the user prefers can take it from
//!   this one.
//! - `org.freedesktop.impl.portal.desktop.strider`, the FileChooser portal backend:
//!   xdg-desktop-portal routes applications' OpenFile, SaveFile, and SaveFiles here when
//!   portals.conf names it (README.md); each call opens a chooser window
//!   ([`chooser`](crate::chooser)) and is answered when the user picks or cancels. The
//!   request's handle carries an `org.freedesktop.impl.portal.Request` object whose Close
//!   ends it (response 2).
//!
//! The bus starts the program for either name through its D-Bus service file, in service
//! mode, and one instance serves every window.

use std::path::PathBuf;

use keywork::dbus::{ArgDesc, BusEvent, InterfaceDesc, Message, MessageKind, MethodDesc, Value};
use keywork::prelude::*;
use strider_core::{model, uri};

use crate::app::{self, Strider};
use crate::chooser::{self, Chooser, Kind, Request};

pub const FILE_MANAGER: &str = "org.freedesktop.FileManager1";
pub const FILE_MANAGER_PATH: &str = "/org/freedesktop/FileManager1";
pub const PORTAL: &str = "org.freedesktop.impl.portal.desktop.strider";
pub const PORTAL_PATH: &str = "/org/freedesktop/portal/desktop";
pub const FILE_CHOOSER: &str = "org.freedesktop.impl.portal.FileChooser";
pub const REQUEST: &str = "org.freedesktop.impl.portal.Request";

const FILE_MANAGER_DESC: InterfaceDesc = {
    const ARGS: &[ArgDesc] = &[ArgDesc::new("URIs", "as"), ArgDesc::new("StartupId", "s")];
    InterfaceDesc {
        name: FILE_MANAGER,
        methods: &[
            MethodDesc::new("ShowFolders", ARGS, &[]),
            MethodDesc::new("ShowItems", ARGS, &[]),
            MethodDesc::new("ShowItemProperties", ARGS, &[]),
        ],
        signals: &[],
        properties: &[],
    }
};

const FILE_CHOOSER_DESC: InterfaceDesc = {
    const IN: &[ArgDesc] = &[
        ArgDesc::new("handle", "o"),
        ArgDesc::new("app_id", "s"),
        ArgDesc::new("parent_window", "s"),
        ArgDesc::new("title", "s"),
        ArgDesc::new("options", "a{sv}"),
    ];
    const OUT: &[ArgDesc] = &[
        ArgDesc::new("response", "u"),
        ArgDesc::new("results", "a{sv}"),
    ];
    InterfaceDesc {
        name: FILE_CHOOSER,
        methods: &[
            MethodDesc::new("OpenFile", IN, OUT),
            MethodDesc::new("SaveFile", IN, OUT),
            MethodDesc::new("SaveFiles", IN, OUT),
        ],
        signals: &[],
        properties: &[],
    }
};

const REQUEST_DESC: InterfaceDesc = InterfaceDesc {
    name: REQUEST,
    methods: &[MethodDesc::new("Close", &[], &[])],
    signals: &[],
    properties: &[],
};

/// `DBUS_NAME_FLAG_ALLOW_REPLACEMENT`.
const ALLOW_REPLACEMENT: u32 = 1;

/// The services' state: the chooser windows open, where the last one picked, and the size
/// the user last gave one.
#[derive(Default)]
pub struct Services {
    pub choosers: Vec<Chooser>,
    pub last_folder: Option<PathBuf>,
    pub size: Option<[u32; 2]>,
    /// The last chooser's id.
    pub next_id: u64,
}

/// Starts the services once the app runs, and hears their calls.
pub fn install(app: &mut App<Strider>) {
    app.on_start(start);
    app.on_session_bus(on_session);
}

/// Exports both objects and asks for their names; without a session bus, as in a container,
/// there are none.
fn start(s: &mut Strider, cx: &mut Cx<'_, Strider>) -> Result<()> {
    if let Some(dir) = &s.state_dir {
        s.services.size = strider_core::state::load_chooser_size(dir);
    }
    let Some(bus) = cx.session_bus() else {
        return Ok(());
    };
    let portal = bus
        .export(PORTAL_PATH, &[FILE_CHOOSER_DESC])
        .and_then(|()| bus.request_name(PORTAL, 0));
    if let Err(e) = portal {
        eprintln!("strider: not serving the file chooser portal: {e}");
    }
    let manager = bus
        .export(FILE_MANAGER_PATH, &[FILE_MANAGER_DESC])
        .and_then(|()| bus.request_name(FILE_MANAGER, ALLOW_REPLACEMENT));
    if let Err(e) = manager {
        eprintln!("strider: not serving FileManager1: {e}");
    }
    Ok(())
}

/// Sends `body` as the reply to `call`.
pub fn reply(cx: &mut Cx<'_, Strider>, call: &Message, body: Vec<Value>) {
    if let Some(bus) = cx.session_bus()
        && let Err(e) = bus.reply(call, body)
    {
        eprintln!("strider: replying on the session bus: {e}");
    }
}

/// Sends a file chooser's answer: `ret`, the reply to its call made when the call came, with
/// `body`.
pub fn answer(cx: &mut Cx<'_, Strider>, ret: Message, body: Vec<Value>) {
    if let Some(bus) = cx.session_bus()
        && let Err(e) = bus.send(ret.with_body(body))
    {
        eprintln!("strider: answering a file chooser: {e}");
    }
}

/// Stops exporting a request's object at `handle`.
pub fn unexport(cx: &mut Cx<'_, Strider>, handle: &str) {
    if let Some(bus) = cx.session_bus()
        && !handle.is_empty()
    {
        bus.unexport(handle);
    }
}

fn on_session(s: &mut Strider, cx: &mut Cx<'_, Strider>, event: &BusEvent) -> Result<()> {
    let BusEvent::MethodCall(msg) = event else {
        return Ok(());
    };
    if msg.kind != MessageKind::MethodCall {
        return Ok(());
    }
    let path = msg.path.as_ref().map_or("", |p| p.as_str());
    let member = msg.member.as_deref().unwrap_or("");
    let interface = msg.interface.as_deref();
    if path == FILE_MANAGER_PATH && interface.is_none_or(|i| i == FILE_MANAGER) {
        return file_manager(s, cx, msg, member);
    }
    if path == PORTAL_PATH && interface.is_none_or(|i| i == FILE_CHOOSER) {
        return file_chooser(s, cx, msg, member);
    }
    if interface.is_none_or(|i| i == REQUEST) && member == "Close" {
        let handle = path.to_owned();
        reply(cx, msg, Vec::new());
        // The reply to Close goes first, then the request's answer, 2.
        return chooser::close_request(s, cx, &handle);
    }
    Ok(())
}

fn refuse(cx: &mut Cx<'_, Strider>, msg: &Message, name: &str, text: &str) {
    if let Some(bus) = cx.session_bus() {
        let _ = bus.reply_error(msg, name, text);
    }
}

/// ShowFolders, ShowItems, ShowItemProperties: answered first, as the caller does not wait
/// for the windows; URIs that are not files are left out.
fn file_manager(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    msg: &Message,
    member: &str,
) -> Result<()> {
    use keywork::dbus::error_names;
    if !matches!(member, "ShowFolders" | "ShowItems" | "ShowItemProperties") {
        refuse(cx, msg, error_names::UNKNOWN_METHOD, "no such method");
        return Ok(());
    }
    let (paths, token) = match msg.body.as_slice() {
        [Value::Array(uris), Value::Str(token)] if uris.elem().as_str() == "s" => {
            let paths: Vec<PathBuf> = uris
                .items()
                .iter()
                .filter_map(Value::as_str)
                .filter_map(uri::file_path)
                .collect();
            (paths, token.clone())
        }
        _ => {
            refuse(
                cx,
                msg,
                error_names::INVALID_ARGS,
                "expected a list of URIs and a startup ID (as, s)",
            );
            return Ok(());
        }
    };
    reply(cx, msg, Vec::new());
    if paths.is_empty() {
        return Ok(());
    }
    let token = Some(token.as_str());
    if member == "ShowFolders" {
        let window = crate::instance::show_paths(s, cx, &paths, false)?;
        return cx.raise(window, token);
    }
    // ShowItemProperties: the item under the cursor, its details in the preview.
    show_items(s, cx, &paths, token)
}

/// Each item (folders too) under the cursor in its folder, a tab each in the window used
/// last, or in a new window.
fn show_items(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    paths: &[PathBuf],
    token: Option<&str>,
) -> Result<()> {
    let mut window = s.last_window();
    for p in paths {
        let target = model::normalize(p);
        let folder = model::parent(&target).to_owned();
        let name = model::basename(&target).to_vec();
        match window {
            Some(w) => app::in_window(s, cx, Some(w), |s, tx| {
                s.cache.entry(&folder).focus(&name);
                crate::tabs::open(s, tx, folder)
            })?,
            None => window = Some(app::open_window(s, cx, folder, Some(name))?),
        }
    }
    match window {
        Some(w) => cx.raise(w, token),
        None => Ok(()),
    }
}

/// OpenFile, SaveFile, SaveFiles: a chooser window, answered later; its Request object
/// takes Close meanwhile.
fn file_chooser(
    s: &mut Strider,
    cx: &mut Cx<'_, Strider>,
    msg: &Message,
    member: &str,
) -> Result<()> {
    use keywork::dbus::error_names;
    let kind = match member {
        "OpenFile" => Kind::Open,
        "SaveFile" => Kind::Save,
        "SaveFiles" => Kind::SaveFiles,
        _ => {
            refuse(cx, msg, error_names::UNKNOWN_METHOD, "no such method");
            return Ok(());
        }
    };
    let Some(req) = Request::parse(kind, &msg.body) else {
        refuse(
            cx,
            msg,
            error_names::INVALID_ARGS,
            "expected a handle, an app ID, a parent window, a title, and options (osssa{sv})",
        );
        return Ok(());
    };
    if !req.handle.is_empty()
        && let Some(bus) = cx.session_bus()
        && let Err(e) = bus.export(&req.handle, &[REQUEST_DESC])
    {
        eprintln!("strider: the file chooser request {}: {e}", req.handle);
    }
    let handle = req.handle.clone();
    if chooser::open(s, cx, req, Some(Message::method_return(msg))).is_err() {
        unexport(cx, &handle);
    }
    Ok(())
}

#[cfg(test)]
mod tests;
