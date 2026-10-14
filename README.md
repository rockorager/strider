# Columns (siv-columns)

A fully keyboard-driven file manager for Linux on Wayland in the style of
ranger and yazi, built on [siv](https://github.com/rockorager/siv): the
parent folder, the current folder, and a live preview of the entry under
the cursor, side by side; vim keys; a command line; and Lua for
configuration. The mouse works, but nothing needs it.

![The three columns: the parent folder, src, and main.zig previewed with syntax coloring](tests/golden/columns-light.png)

The name is a placeholder (program `siv-columns`, app id
`org.siv.Columns`); see [FRICTION.md](FRICTION.md).

## Install

You need Zig 0.17.0 and the development files of libwayland-client,
xkbcommon, Fontconfig, and the Vulkan headers. On Arch:

```sh
sudo pacman -S --needed zig wayland libxkbcommon fontconfig vulkan-headers shared-mime-info
sudo pacman -S --needed udisks2 poppler   # optional: drives, PDF previews
```

(If your distribution's Zig is not 0.17.0, take it from ziglang.org.
libarchive's `bsdtar`, which lists archives other than zip and tar.gz,
comes with pacman.) siv is a private repository pinned as a git
submodule, so clone with your GitHub credentials and the submodule:

```sh
git clone --recurse-submodules https://ampcode.com/@rockorager/siv-columns
cd siv-columns
zig build run                         # try it from zig-out
zig build install --prefix ~/.local   # install for yourself
```

`zig build install --prefix ~/.local` installs `bin/siv-columns` (one
program: libsiv and its Lua binding are linked in), the desktop file
`share/applications/org.siv.Columns.desktop`, the icon, AppStream
metadata, a D-Bus service file for `org.siv.Columns`, and an example
configuration in `share/doc/siv-columns/init.lua`. `-Dfilemanager1=true`
also installs a service file for `org.freedesktop.FileManager1`, so other
applications' "Show in folder" starts it (only one file manager should).
`xdg-mime default org.siv.Columns.desktop inode/directory` makes it the
default for folders.

```
siv-columns [FOLDER or FILE ...] [--new-window] [--hidden]
            [--dark | --light] [--rtl] [--clean] [--config FILE]
```

One instance serves every window: running it again opens its folders as
tabs in the running one. A file on the command line is shown under the
cursor in its folder; from a terminal it starts in the terminal's folder.

## Keys

`g?` or F1 lists every binding and command in the preview column. After a
prefix (`g`, `s`, `d`, `y`, `z`, `'`, `m`) a popup shows what can follow.
Counts work where they make sense: `5j`, `3H`, `2u`; `10G` goes to the
tenth entry.

| Keys | |
| --- | --- |
| `j` `k` `h` `l`, arrows | down, up, the parent folder, enter or open |
| `gg` `G`, `Ctrl+d` `Ctrl+u`, `Ctrl+f` `Ctrl+b` | first, last, half pages, pages |
| `H` `L` | back and forward in the tab's history |
| `Enter`, `o` | open with the default application (mimeapps.list), open with… |
| `/` `?` `n` `N` | search forward and backward as you type, next, previous |
| `f` | jump by typing part of a name |
| `zf` | filter the folder |
| `Space`, `v`, `Ctrl+a`, `Esc` | mark and move down, visual selection, mark all, cancel and unmark |
| `yy` `dd` `p` `P` | copy, cut, paste, paste replacing |
| `yp` `yn` `yd` | copy the paths, the names, the folder's path |
| `dT` `Del`, `dD` `Shift+Del`, `u` | move to the trash, delete permanently (asks), undo |
| `r` `A` `I`, `R` | rename (the name without its extension selected, at the end, at the start), bulk rename in `$EDITOR` |
| `a` | new file, or folder with a trailing `/` (`a/b/c/` makes them all) |
| `zh`, `zp`, `zi` | hidden files, the preview, icons |
| `sn` `ss` `sm` `st` `se`, `sr` `sd` | sort by name, size, modified, type, extension; reverse; folders first |
| `m` + key, `'` + key, `''`, `dm` + key | set a bookmark, go to one, back, remove one |
| `gh` `g/` `gd` `gD` `gc` `gm` | home, root, Downloads, Documents, ~/.config, mounted media |
| `gx`, `dr` | the trash, restore from it |
| `gv` | drives: open, mount (asks for LUKS passphrases), with `:unmount` and `:eject` |
| `gn` `Ctrl+t`, `gt` `gT` `Tab`, `Alt+1`…`9`, `gq` `Ctrl+w` | tabs: new, next and previous, by number, close |
| `!`, `S` | run a shell command on the selection, a terminal here |
| `J` `K` | scroll the preview |
| `:` | the command line: Tab completes commands and paths, Up and Down recall history |
| `q`, `ZZ` | close the tab (the window with the last), quit |

What commands act on: the visual range, else the marked entries, else the
entry under the cursor. Copies and cuts go to the clipboard too (as GNOME
and KDE file managers put them), and `p` pastes what other file managers
copied. Files drag out of the current column, and drop into it or onto a
folder's row.

A file operation that meets a name already taken asks in the status line:
replace, skip, keep both, or merge folders, Shift for all of them.

## Previews

Folders show their entries; text files their start with syntax coloring
(Zig, C and C++, Rust, Go, Python, JavaScript and TypeScript, Lua, shell,
JSON, TOML, YAML, Markdown, diffs, and more); images decode on siv's
workers at the size the column shows them; archives list their entries
(zip and its relatives, tar and tar.gz directly, others with `bsdtar`);
PDFs show their first page (with poppler's `pdftoppm`); videos and other
files show a thumbnail another program cached, if any, or their details.
A preview starts the moment the cursor lands, and moving on cancels
decoding and reading that has not started.

## Configuration

`$XDG_CONFIG_HOME/siv-columns/init.lua` (`~/.config/siv-columns/init.lua`)
runs at startup in Lua 5.5, through siv's Lua binding. Nothing is
required; [data/init.lua](data/init.lua) is an annotated example.

```lua
local fm = require("fm")

fm.set { hidden = true, ratio = { 1, 3, 4 }, sort = "modified", sort_reverse = true }
fm.opt.scroll_off = 5

fm.map("n", "gp", "cd ~/Projects", "Projects")          -- keys run commands…
fm.map({ "n", "v" }, "<C-c>", "yank", "Copy")
fm.map("n", "gi", function(count)                         -- …or Lua functions
	fm.notify(#fm.selected() .. " targets")
end, "Count the targets")
fm.unmap("n", "dD")

fm.command("archive", function(args, count)               -- :archive name.tar.gz
	fm.exec("shell tar -czf " .. ("%q"):format(args) .. ' "$@"')
end, "Pack the targets")

fm.previewer { name = "*.csv", run = function(path, mime) return "…" end }
fm.previewer { mime = "video/*", cmd = { "mediainfo", "%s" } }

fm.on("cd", function(path) end)
fm.bookmark("p", os.getenv("HOME") .. "/Projects")

-- siv itself: timers, jobs, notifications, D-Bus…, on the running app.
local app = fm.siv_app()
app:timer_start(1000, function() fm.notify("a second later") end)
```

`fm` also has `get`, `cwd`, `hovered`, `selected`, `cd`, `exec` (any
command line), `notify`, and `siv_window`. Every option is also `:set
name value` while running (`:set hidden!` toggles); `:map` and `:unmap`
bind keys, `:lua` runs Lua. Options: `hidden`, `sort`, `sort_reverse`,
`dirs_first`, `ratio`, `icons`, `preview`, `preview_images`,
`preview_max_bytes`, `syntax`, `which_key_delay`, `scroll_off`,
`wrap_scan`, `find_auto_accept`, `confirm_delete`, `show_size`,
`terminal`, `editor`, `editor_in_terminal`, `shell`, `stale_ms`.

Bookmarks and the command history persist in
`$XDG_STATE_HOME/siv-columns/`.

## Desktop integration

- Light, dark, and high-contrast styles and the accent follow the desktop
  (every color is a siv theme token, syntax colors included); right to
  left layouts mirror the columns.
- Screen readers: the columns are lists whose focused row is the cursor,
  marked entries say so, the status line is a live region, prompts are
  labeled text fields (AT-SPI, through siv).
- Opening uses the desktop's MIME defaults (mimeapps.list); `o` offers
  every application for the type.
- Drives come from UDisks2: mount (polkit asks if it must), unmount,
  eject, and unlock encrypted volumes with a passphrase typed in a masked
  field.
- Other applications' "Show in folder" (org.freedesktop.FileManager1)
  opens the item under the cursor in a tab.
- The trash: browse every trash with `gx`, restore with `dr`,
  `:empty-trash`.

## Develop

```sh
zig build test                        # unit tests, and the app on siv's headless backend
SIV_UPDATE_GOLDEN=1 zig build test    # accept new golden images (tests/golden)
zig build bench                       # startup, memory, and navigating 100 000 entries
```

The headless tests drive the application through siv's public test API
— keys typed as a user types them, settling, captures compared with
golden images, and the semantics tree a screen reader reads — with the
test fonts in `tests/fonts` and the MIME and application data in
`tests/data`.

`deps/siv` pins siv. To move to a newer siv: `git -C deps/siv pull
origin main`, run the tests, and commit the submodule. Things siv could
do better, and decisions left to its author, are in
[FRICTION.md](FRICTION.md).

## Performance

`zig build bench` (ReleaseSafe, siv's headless backend with the system's
fonts, warm caches; a 4-core 2.6 GHz Xeon orb, October 2026):

| Measurement | Result |
| --- | --- |
| Startup to the first frame showing a 40-entry folder (its rows included) | 22 ms (UI thread CPU 11 ms) |
| Resident memory with that window open | 36 MiB (heap in use 19.8 MiB) |
| Idle for 2 s | no wakeups |
| A 100 100-entry folder: read, typed, and sorted | 245 ms, rows shown at 252 ms; the first frame at 26 ms |
| Memory for those entries | 8.0 MiB of heap (84 bytes each); 49 MiB resident in all |
| `j`, 300 times, each frame presented and the preview updated | 0.56 ms UI thread CPU per key (1.5 ms worst), each on the next 60 Hz frame |
| 100 `j`s queued at once (a held key) | 24 ms UI thread CPU in all |
| `G`, `gg` | 1.4 ms each |
| `Ctrl+f` (a page) | 0.9 ms (1.3 ms worst) |
| `/file-99999` typed, every keystroke searching all names | 20 ms for the eleven keystrokes |
| `Ctrl+a` marking all 100 100 | 1.1 ms |
| `sS` (by size, largest first, the cursor kept on its entry) | 57 ms |
| `zf-12` typed (filtering as you type) | 18 ms for the three keystrokes |

Rows are virtualized by siv's views, so a frame costs what is on screen,
not what is in the folder.

## License

MIT. siv and what it contains: `share/licenses/siv-columns/`.
