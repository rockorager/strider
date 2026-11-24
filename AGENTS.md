# Strider

A keyboard-driven file manager for Linux on Wayland, in Rust, on
[Keywork](https://tangled.org/rockorager.dev/keywork), a Wayland-only GUI
toolkit, with its behavior written as
[plusthree](https://tangled.org/rockorager.dev/plusthree) statecharts. It
was written in Zig on [siv](https://github.com/rockorager/siv) before; this
build took its place with the same program (`strider`), app id
(`dev.rockorager.Strider`), D-Bus names, and state files
(`$XDG_STATE_HOME/strider`, read as the Zig build wrote them).
`config.json` replaced the Zig build's `init.lua`.

## Toolchain

- Rust as `rust-toolchain.toml` names it, with rustfmt and clippy; rustup
  installs it. The workspace `Cargo.toml` names the same floor as
  `rust-version`.
- `mise install` installs what `mise.toml` pins (just, shellcheck, shfmt,
  oxfmt; `mise.lock` holds their checksums), for the orb setup, CI, and
  `just release` alike. To move a pin, change it there and run
  `mise lock --platform linux-x64,linux-arm64`.
- Keywork is a git dependency pinned by rev in the workspace `Cargo.toml`
  until it is on crates.io; plusthree comes from crates.io. Move a pin
  there, then `cargo update -p NAME`.
- The build links nothing but libc: no system libraries, no C. Keywork
  loads libfontconfig and libvulkan at run time. Keep it that way.
- In an orb, `.agents/setup` installs from apt what the program and the
  tests load and call (Fontconfig, Mesa's Vulkan drivers, shared-mime-info,
  dbus, pdftoppm, bsdtar, ffmpeg), then mise and rustup, links their
  binaries into `~/.local/bin`, since the agent's shells do not activate
  them, and warms the build with `just test`.

## Commands

The justfile is the interface. `just --list` shows every recipe.

```sh
just build          # target/debug/strider
just install        # a release build, desktop entries, icon, D-Bus services, and portal in ~/.local
just release [BUMP] # release origin/main: patch, minor, major, or X.Y.Z
just fetch          # install the published build, no compiler
just run            # on the Wayland display
just test           # Keywork's headless backend; no display needed
just lint           # clippy -D warnings, rustfmt, shellcheck, shfmt, oxfmt, just --fmt
just fmt            # format what lint checks
just ci             # build, test, and lint
```

`just install PREFIX true` also installs a D-Bus service file for
`org.freedesktop.FileManager1`, which only one file manager should have.
The desktop and service files in `data/` name the program as
`@PREFIX@/bin/strider`; the install fills in its prefix, and a release's
archive keeps `@PREFIX@` for `just fetch` to fill in.

## Layout

- `crates/strider-core`: the model and the formats, no I/O beyond files:
  options and `config.json` (`options.rs`, `config.rs`), the default keys
  and key notation (`keys.rs`), state files (`state.rs`), entries, sorting,
  and MIME types (`model.rs`), fuzzy matching, syntax highlighting,
  archives, drives, file operations' plans, rename, undo, URIs, and
  Omarchy themes.
- `crates/strider-machines`: every statechart, as `plusthree::machine!`:
  the mode (`mode.rs`), the keymap's pending keys (`keymap.rs`), a folder's
  reading and watching, previews, file operations, drives, drag and drop,
  and the chooser. A machine's context holds small control data; events
  come in, its effects (`*Fx` enums) go out, and it does no I/O.
  `driver::Driver` steps one for the app and hands its timers to the host.
- `crates/strider`: the app. `main.rs` reads the command line and
  `config.json` and runs the instance; `app.rs` holds `Strider`, the one
  state; `commands.rs` the command table and what each runs; the window's
  parts (`columns.rs`, `crumbs.rs`, `tabs.rs`, `tasks.rs`, `picker.rs`,
  `prompt.rs`, `menu.rs`, `dialogs.rs`), `preview.rs`, `ops/`, `drives.rs`,
  `opening.rs`, `dnd.rs`, `theme.rs`, `instance.rs` (one instance on the
  session bus), `services.rs` (FileManager1 and the FileChooser portal),
  `chooser.rs`, and `scenes.rs`.
- `data/`: the desktop entries, D-Bus service files, portal file, icon,
  and AppStream metadata. `tests/golden`: the Zig build's headless
  captures, which the scenes reproduce; their text is in Droid Sans
  (`tests/fonts`), the one font those tests loaded, with the MIME and
  application data in `tests/data`. `tests/themes`: Omarchy themes the
  scenes and tests read. `docs/screenshots`: the README's, each the scene
  of a like name rendered at 1280x800 (`light.png` is `columns`,
  `dark-text.png` `dark`, `menu.png` `context-menu`, `hex.png`
  `preview-hex`, `image-preview.png` `preview-image`, and
  `archive-preview.png` `preview-archive`).

## Writing Rust

- Edition 2024. `cargo clippy -D warnings` and `cargo fmt` pass on every
  commit; `just ci` checks both.
- Behavior goes in a statechart in `strider-machines`: what waits for
  what, modes, retries, and timers. Plain structs beside them hold the
  bookkeeping (entries, marks, the register), and the app carries out the
  effects. One way in: a Keywork handler turns a key, a click, or a reply
  from a worker into a machine event, steps the machine through its
  `Driver`, and runs the effects that come out. Nothing that previews or
  navigates touches the file system on the UI thread.
- Keep dependencies few, each with a reason in its `Cargo.toml`.
- A stateful type is its own module named for it. Tests sit at the bottom
  of the file they cover, or in a `tests.rs` beside it.
- Comments and messages are plain, full sentences.

## Keywork, scenes, and tests

- Keywork's API: read its source in
  `~/.cargo/git/checkouts/keywork-*/<rev>/crates/`, with its AGENTS.md and
  examples there.
- UI tests run the app on Keywork's headless backend (`app.headless`) in a
  sample home (`scenes::fixture`), press keys as a user does, settle, and
  check what the window shows and what happened on disk. Machines are tested by
  stepping their `Driver` with events and checking the effects. The
  services' tests run against a private dbus-daemon.
- A scene is a state of the window that renders and tests share
  (`scenes.rs`; `strider --keywork-list-scenes` lists them). Render one
  headless with
  `target/debug/strider --keywork-snap /abs/out.png --keywork-scene NAME --keywork-size 1000x560`,
  the size of `tests/golden`'s images, and compare it by eye with the
  golden of the same name after a visual change. Renders are not compared
  by pixels in the tests.

## Releasing

CI tests each push to GitHub. After a push, `just release BUMP` releases
origin/main from an orb. It lists the commits since the last tag, then
commits `release: X.Y.Z`, setting the workspace `Cargo.toml`'s version,
which `strider --version` reports; runs `just ci` on it; builds it; pushes
the commit to main and its tag `vX.Y.Z` in one atomic push; and publishes
a GitHub release of the tag with the build attached and those commits as
its notes. A release cut short finishes when run again; one that finds
main moved pushes nothing. `just fetch` installs the newest, once its
download matches the sha256 GitHub recorded and `strider --version` names
it.

Versions follow semver strictly from the start: 0.x has no exemption, so
what breaks bumps the major even now. The bump is the highest any commit
since the last tag needs:

- `major`: what makes a user act or lose something. A key, command,
  option, or `strider` argument removed or doing something else; settings,
  bookmarks, or history a new build cannot read; a configuration API
  removed or changed; a higher floor for the system it runs on (glibc,
  CPU, libraries).
- `minor`: something new, with nothing old breaking. A key, command,
  view, option, or configuration entry added.
- `patch`: fixes alone, adding no behaviour.

Release only when asked. Choose the bump from the commits the recipe
lists, read for what changed for the user rather than from their
subjects, and say which you chose and why. When it is between two, take
the higher. `just release X.Y.Z` names a version outright; never bump
`Cargo.toml`'s version by hand.

Releasing needs `gh` signed in as someone who can push to
rockorager/strider. The build is for x86-64-v3 (AVX2), not the orb's CPU,
whose AVX-512 laptops lack, and may link no glibc symbol newer than 2.38,
which `just release` checks.
