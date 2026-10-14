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

## Decided

6. **The application's name and id are placeholders** (decided: they
   stay until the user picks names): "Columns",
   `org.siv.Columns`, program `siv-columns`, Lua module `fm`, config in
   `$XDG_CONFIG_HOME/siv-columns/`. Renaming touches `App.app_id` and
   `App.program`, `build.zig`, `tools/desktop_files.zig`, `data/`, and
   the README. (siv-files' name is open too.)

7. **`f` closes as soon as one name matches** (decided: as ranger
   does), so the letters typed after the match run as commands (`fpho`
   reaches photo.png at `ph`, then `o` opens "Open with").
   `fm.set { find_auto_accept = false }` makes it wait for Enter.

8. **Messages go to the status line, not toasts** (decided: as in ranger
   and vim, errors belong in the status line of a keyboard-driven app).
   An error is in the error color; a message stays until the next key;
   `:messages` lists the last 200, newest first. The status line is a
   polite live region, so screen readers announce each one.

9. **Column widths** (decided: as they are). The parent column widens
   to its longest name up to a quarter of the window (`fit_parent`),
   taking the room from the preview, never the current column; under
   640 logical pixels (`narrow_width`) the parent column hides, and
   under two thirds of that the preview too. ranger instead keeps every
   column and truncates; yazi keeps its fixed ratio.

10. **The filter stays on `zf`** (decided: it matches ranger). yazi
    filters with `f`, but `f` is ranger's find here (item 7); `zf` is
    free of conflicts, and the filter and `/` search stay separate. A
    filter stays on its folder until Esc (the status line says so), as
    ranger's does.

11. **chmod is `=`, as in ranger; chmod and chown are not undone by `u`**
    (decided). Undo reverses what moved, not attributes; reversing them
    would mean recording every file's old mode and owner first.

12. **The tasks view is `w`, as in ranger** (decided), and an overlay
    rather than a column: it lists running operations, then the last 20
    finished ones (kept in memory, not across restarts). Pausing stops
    an operation at its next file or 4 MiB chunk; a copy paused mid-file
    keeps its partial target until it resumes or is cancelled (which
    removes it).

13. **zoxide is `gz`, fuzzy finding `gf`, and fzf is not used** (decided:
    they fit the `z` toggle prefix). yazi
    binds `z` and `Z`, but `z` is the prefix for toggles here (`zh`,
    `zf`, `zp`); `g` is "go" (`gh`, `gd`). The built-in finder walks
    100 000 entries in about 50 ms and scores a keystroke in a few
    milliseconds, in the window's own list with its highlighting and
    keys; fzf would need a terminal (or `--filter`, which scores the
    same way without the live list), so it would not clearly help.
    `.gitignore` is not read; hidden entries follow `zh`.

14. **Image previews read on siv's workers, outside the app's limit**
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

## Noted

15. **siv is private, so `zig fetch` cannot reach it.** As in siv-files:
   a git submodule (`deps/siv`) and a path dependency; clone with
   `--recurse-submodules`.

16. **The focus ring.** siv draws a focus ring when focus moved by
   keyboard; focus returns to the cursor's row from a key handler when a
   prompt closes, so the ring appears then and not before (when focus
   came from creating the window). Both are siv's documented rule; the
   selection highlight is the cursor either way.

17. **Bulk rename waits for the editor.** `R` writes the names to a
   file, runs `$VISUAL`/`$EDITOR` in a terminal, and renames when the
   editor exits, so the terminal must stay in the foreground until then:
   foot, alacritty, kitty, wezterm, and ghostty do; gnome-terminal does
   with `--wait`, which the app passes. `fm.set { terminal = "...",
   editor = "...", editor_in_terminal = false }` covers the rest.

18. **Settling while a job waits for the user.** As in siv-files:
    `siv_test_settle` waits for running jobs, so a test cannot settle
    while a copy waits for the conflict question; the tests dispatch
    until the question shows.

19. **No monospace font in the tests.** The text preview asks for the
    generic `monospace` family; the headless tests load only Droid Sans,
    so their goldens show code in it. Real desktops get their monospace
    font.

20. **A large static binary.** ReleaseSafe with libsiv, its decoders,
    and Lua linked in is 46 MB unstripped (`-Doptimize=ReleaseSmall` or
    stripping makes it much smaller); it maps lazily, so startup does
    not pay for it.

21. **Driving the app on a headless sway.** With no keyboard attached,
    each `wtype` adds a virtual keyboard, so the seat gains its keyboard
    as wtype starts typing; without a pause (`wtype -s 300 ...`) the
    first press can arrive before siv has the keyboard and is lost. siv's
    own sway test pauses the same way; real keyboards are unaffected.
