# Friction log

What building a keyboard-driven, ranger-style file manager on siv's
public API ran into, in the order found. Each entry says what happened,
what this project does about it, and its status:

- **Fixed** — siv changed in a labeled commit on its main branch (the
  submodule in `deps/siv` points at it).
- **Decide** — a question for siv's author (or the app's owner); the app
  works around it meanwhile. **Decided** — answered.
- **Noted** — minor, or about Zig or the platform rather than siv.

## Fixed in siv

1. **The Lua binding could not be linked statically.** siv's package
   offered libsiv-lua.so and the `siv` module (which links libsiv.so);
   siv-files already used libsiv.a through a build.zig detour. Embedding
   Lua for `init.lua` in a one-file program needed the binding as an
   object and the Lua C API as Zig declarations. *Fixed:* the package
   exports `siv-static` (the generated API with libsiv.a) and
   `siv-lua-static` (the binding's object, with the Lua it embeds, and
   `lua.h`, `lauxlib.h`, `lualib.h`, and `siv_lua.h` as Zig), and names
   the binding's NOTICES as `lua-notices` (siv, "lua, abi: modules for
   programs that link siv and its Lua binding statically", D23, D25).
   siv-files' detour could use `siv-static` too.

2. **A host could not hand Lua its own siv objects.** Handles in Lua are
   the binding's userdata, made only by binding calls, so `init.lua`
   could `require("siv")` but had no way to reach the application the
   program had made (for timers, jobs, notifications, D-Bus).
   *Fixed:* `siv_lua_push_handle(L, "app", handle)` pushes any handle the
   host made, never owned by Lua (same commit, D23). `fm.siv_app()` and
   `fm.siv_window()` use it.

3. **A view row handled keys before the application saw them.** A
   focused row's default handler took Space, Enter, the arrows, Home,
   End, and the page keys before its ancestors' handlers ran, and `bind`
   gets the row's body, so the keymap had to go on the body's parent,
   leaning on the row's shape. *Fixed* (decided by siv's author): keys
   have a capture phase, `siv_on_capture`, from C, Zig, and Lua (siv
   96d08f7, "ui, abi, lua: a capture phase for keys", D16). The keymap is
   a capture handler on the window's root; it handles what it binds and
   passes the rest, so prompts' editors type as before.

4. **Tests could not resize a window.** Column widths follow the
   window's width now, but siv's test API had no way to make the
   simulated compositor resize one. *Fixed:* `siv_test_resize` (siv
   9868565, "abi: siv_test_resize, the compositor resizing a window"),
   also `window:test_resize` in Lua.

5. **Typing crashed when a change handler built many nodes.** siv's
   editor read its node data after running the change handlers, which
   can move the tree's storage; the picker's results list, rebuilt on
   every keystroke in a big window, made it crash. *Fixed:* siv 4bb9cdf,
   "ui: read nothing of an editor after its change handlers ran", with a
   test that crashed before.

6. **No surfaces between the window and the view.** siv had one
   content surface (`view_bg`) and the window's beside it, the same
   color in high contrast, so the three columns could not each have a
   tone. *Fixed:* `sidebar_bg` and `secondary_sidebar_bg`, as libadwaita
   names them, distinct in all four variants with view text readable on
   both (siv 7116906, "ui, abi: sidebar surfaces, a step and two from the
   view"). The parent column is on the sidebar, the current column on
   the secondary sidebar, and the preview on the view.

7. **Dialogs could not be answered with a key.** siv's dialogs closed
   with Escape and took Tab, but their buttons had no mnemonics, so a
   keyboard-driven dialog had to be tabbed through. *Fixed:* buttons,
   toggles, and check boxes take a mnemonic, underlined, that presses
   them in a dialog (with Alt in a text field), siv 4a7c551, "widgets,
   abi: mnemonics for buttons, toggles, and check boxes in dialogs".

## Decided

8. **The application's name and id are placeholders** (decided: they
   stay until the user picks names): "Columns",
   `org.siv.Columns`, program `siv-columns`, Lua module `fm`, config in
   `$XDG_CONFIG_HOME/siv-columns/`. Renaming touches `App.app_id` and
   `App.program`, `build.zig`, `tools/desktop_files.zig`, `data/`, and
   the README. (siv-files' name is open too.)

9. **`f` closes as soon as one name matches** (decided: as ranger
   does), so the letters typed after the match run as commands (`fpho`
   reaches photo.png at `ph`, then `o` opens "Open with").
   `fm.set { find_auto_accept = false }` makes it wait for Enter.

10. **Messages go to the status line, not toasts** (decided: as in ranger
   and vim, errors belong in the status line of a keyboard-driven app;
   still so now that dialogs exist, which ask, never report).
   An error is in the error color; a message stays until the next key;
   `:messages` lists the last 200, newest first. The status line is a
   polite live region, so screen readers announce each one.

11. **Column widths** (decided: as they are). The parent column widens
   to its longest name up to a quarter of the window (`fit_parent`),
   taking the room from the preview, never the current column; under
   640 logical pixels (`narrow_width`) the parent column hides, and
   under two thirds of that the preview too. ranger instead keeps every
   column and truncates; yazi keeps its fixed ratio.

12. **The filter stays on `zf`** (decided: it matches ranger). yazi
    filters with `f`, but `f` is ranger's find here (item 9); `zf` is
    free of conflicts, and the filter and `/` search stay separate. A
    filter stays on its folder until Esc (the status line says so), as
    ranger's does.

13. **chmod is `=`, as in ranger; chmod and chown are not undone by `u`**
    (decided). Undo reverses what moved, not attributes; reversing them
    would mean recording every file's old mode and owner first.

14. **The tasks view is `w`, as in ranger** (decided), and an overlay
    rather than a column: it lists running operations, then the last 20
    finished ones (kept in memory, not across restarts). Pausing stops
    an operation at its next file or 4 MiB chunk; a copy paused mid-file
    keeps its partial target until it resumes or is cancelled (which
    removes it).

15. **zoxide is `gz`, fuzzy finding `gf`, and fzf is not used** (decided:
    they fit the `z` toggle prefix). yazi
    binds `z` and `Z`, but `z` is the prefix for toggles here (`zh`,
    `zf`, `zp`); `g` is "go" (`gh`, `gd`). The built-in finder walks
    100 000 entries in about 50 ms and scores a keystroke in a few
    milliseconds, in the window's own list with its highlighting and
    keys; fzf would need a terminal (or `--filter`, which scores the
    same way without the live list), so it would not clearly help.
    `.gitignore` is not read; hidden entries follow `zh`.

16. **Image previews read on siv's workers, outside the app's limit**
    (decided: fine, since superseded loads are cancelled). siv decodes
    images (`siv_image_load`) on its own threads, so the two-job limit
    on previews covers text, archives, renderers, and previewers but not
    images. Moving the cursor cancels the image load in flight
    (`siv_image_request_cancel` in `Preview.cancel`, which every new
    preview goes through), so only a decode already blocked in a read
    on a hung mount keeps one of siv's threads until the mount answers.
    Folder reads use siv's blocking lane (8 threads): previewing many
    folders on a hung mount can fill it. Neither has happened in
    testing; a per-application lane in siv would close both.

## Decide

17. **Resizing columns** (chosen here). The handles are the app's own,
    not nested `siv_split_pane`s: a split has two panes and a divider
    the app cannot hide, while the columns are three, any of which
    `narrow_width` or the options may hide. A chosen width wins over
    `ratio` and `fit_parent` until `z=`; it is a share of the window,
    so it follows resizes, and `narrow_width` still hides columns.
    Widths are kept across restarts (they are the user's layout, like
    a terminal's split sizes). Keys: `>` and `<` (free in ranger's
    keymap; vim's `Ctrl+W >` and `<` widen and narrow too) and `z=`.
    siv's split pane sets no resize cursor on its divider; these
    handles set `ew_resize` themselves.

18. **Which questions are dialogs** (chosen here). Dialogs: deleting
    permanently and emptying the trash (they cannot be undone, and a
    y/N in the status line is easy to answer by reflex); a conflict in
    an operation of several items or a folder (the two files compared
    side by side, and "every conflict" is a check box, not a hidden
    Shift); and properties (nine permission boxes, a mode, and an owner
    do not fit a status line). The status line keeps one-key questions:
    a single file's conflict, bookmarks, the passphrase prompt, and
    every message and error. The context menu acts on the selection
    when the clicked entry is in it, else moves the cursor there and
    drops the marks (GTK's and KDE's rule); its items are chosen per
    context, with init.lua's commands in a submenu.

## Noted

19. **siv is private, so `zig fetch` cannot reach it.** As in siv-files:
   a git submodule (`deps/siv`) and a path dependency; clone with
   `--recurse-submodules`.

20. **The focus ring.** siv draws a focus ring when focus moved by
   keyboard; focus returns to the cursor's row from a key handler when a
   prompt closes, so the ring appears then and not before (when focus
   came from creating the window). Both are siv's documented rule; the
   selection highlight is the cursor either way.

21. **Bulk rename waits for the editor.** `R` writes the names to a
   file, runs `$VISUAL`/`$EDITOR` in a terminal, and renames when the
   editor exits, so the terminal must stay in the foreground until then:
   foot, alacritty, kitty, wezterm, and ghostty do; gnome-terminal does
   with `--wait`, which the app passes. `fm.set { terminal = "...",
   editor = "...", editor_in_terminal = false }` covers the rest.

22. **Settling while a job waits for the user.** As in siv-files:
    `siv_test_settle` waits for running jobs, so a test cannot settle
    while a copy waits for the conflict question; the tests dispatch
    until the question shows.

23. **No monospace font in the tests.** The text preview asks for the
    generic `monospace` family; the headless tests load only Droid Sans,
    so their goldens show code in it. Real desktops get their monospace
    font.

24. **A large static binary.** ReleaseSafe with libsiv, its decoders,
    and Lua linked in is 46 MB unstripped (`-Doptimize=ReleaseSmall` or
    stripping makes it much smaller); it maps lazily, so startup does
    not pay for it.

25. **Driving the app on a headless sway.** With no keyboard attached,
    each `wtype` adds a virtual keyboard, so the seat gains its keyboard
    as wtype starts typing; without a pause (`wtype -s 300 ...`) the
    first press can arrive before siv has the keyboard and is lost. siv's
    own sway test pauses the same way; real keyboards are unaffected.

26. **Names several types claim are settled by content.** `*.ts` is
    Qt Linguist and MPEG transport stream at weight 50 and, from
    shared-mime-info 2.5 (Arch), TypeScript at 40. The app had taken the
    last line, so TypeScript showed as video. As the spec says, contested
    names now read their first 4 KiB on the listing's worker: the
    candidates' magic rules decide (sync bytes every 188 bytes are a
    stream), then text goes to a text candidate whose strong magic did
    not fail (GIO's looks-like-text check), so TypeScript wins over
    Linguist. Only names whose candidates content can tell apart pay
    the read (on Debian's database 41 names tie, among them `*.ogg`,
    `*.json`, and `*.m`), within the listing's 512-read budget. Older
    databases without a TypeScript type show `.ts` source as plain text,
    still highlighted by its extension.

27. **The columns are flat views** (fixed in siv, 404add3). A siv view
    draws a frame, and since siv 59d01d9 its scroll's corners are rounded
    to the frame's inner curve; replacing the view's visual left that
    clip, so a selected first row had round top corners over square
    bottom ones. Columns are surfaces edge to edge between separators,
    not boxes, so siv gained `SIV_VIEW_FLAT` (no border, radius, or
    inset) and the columns use it. The tasks view and the pickers keep
    their inset pill rows, rounded alike on every row.

28. **A click on a column's empty space does nothing** (chosen here,
    siv 5ef915e fixed the cause). siv's view sent the column an item's
    activation for item 0 when a press below the rows was released, so
    a click there entered the first folder or opened the first file.
    Now a click there only keeps focus in the current column. Nautilus,
    Dolphin, and Thunar clear their selection on such a click, but
    there the selection is made by clicking; marks here are made with
    keys, as in ranger, where they last until cleared (`Esc`, `:unmark-all`),
    so a stray click keeps them. The right button there still opens the
    folder's menu.

## Proposals: GUI affordances still missing

Places where the mouse or a visual cue should work, by the design
principle in the README, but does not yet. None is built; pick any.

- **The path in the header is plain text.** Each folder in it could be
  a breadcrumb: click to go there, drop files on it to move them there.
- **The mouse's back and forward buttons do nothing.** They could move
  through the tab's history, as `H` and `L` do.
- **No Ctrl+click or Shift+click.** Marking with the mouse could toggle
  one entry (Ctrl) or a range (Shift), and dragging on empty space
  could draw a selection rectangle.
- **Cut-off names have no tooltip.** A name ellipsized in its column
  could show in full under the pointer (and in the parent column, which
  truncates the most).
- **The status line is not clickable.** The operation's progress could
  open the tasks view, the sort and filter could open their menus, and
  "2 copied" could show what the register holds.
- **The which-key popup, the picker, and the tasks view ignore the
  pointer.** Their rows could be clicked to run the key, open the
  result, or select the task, and each running task could have pause
  and cancel buttons.
- **Rename happens in the command line.** It could edit the name in
  place, in the row (`r` and F2 alike), as GUI file managers do.
- **Only the current column has a context menu and takes drops on
  folders.** The parent and preview columns could do both, for the
  folders they show.
- **Tabs take no drops.** Dropping files on a tab could move or copy
  them into its folder.
- **The image preview is look-only.** A click could open the image; the
  wheel with Ctrl could zoom it.
