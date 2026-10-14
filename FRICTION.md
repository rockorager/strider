# Friction log

What building a keyboard-driven, ranger-style file manager on siv's
public API ran into, in the order found. Each entry says what happened,
what this project does about it, and its status:

- **Fixed** — siv changed in a labeled commit on its main branch (the
  submodule in `deps/siv` points at it).
- **Decide** — a question for siv's author (or the app's owner); the app
  works around it meanwhile.
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

## Decide

3. **A view row handles keys before the application sees them.** A
   focused row's default handler takes Space, Enter, the arrows, Home,
   End, and the page keys before its ancestors' handlers run (siv
   delivers a node's `siv_on` handler, then its default, then bubbles).
   An application whose keys are its own — Space marks here, `j` and `k`
   move, Enter opens — needs its handler on the row itself, but `bind`
   gets the row's body, a child of the focused row. The app puts its key
   handler on `siv_node_get_related(body, .parent)`, which works with the
   public API but leans on the row's shape. Two ways siv could make this
   first-class: a capture phase (`siv_on` flag or `siv_on_capture`) so an
   ancestor sees keys before the focused node, as the DOM's capture does;
   or rows that hand keys to the view root's `siv_on` handler before
   their default. Keyboard-first applications (editors, terminals, this)
   would all use the first.

4. **The application's name and id are placeholders**: "Columns",
   `org.siv.Columns`, program `siv-columns`, Lua module `fm`, config in
   `$XDG_CONFIG_HOME/siv-columns/`. Renaming touches `App.app_id` and
   `App.program`, `build.zig`, `tools/desktop_files.zig`, `data/`, and
   the README. (siv-files' name is open too.)

5. **`f` closes as soon as one name matches, or waits for Enter?**
   ranger's find closes at the first unique match, so the letters typed
   after it run as commands (`fpho` reaches photo.png at `ph`, then `o`
   opens "Open with"). That surprised the tests and would surprise
   people, so the default waits for Enter (Escape goes back);
   `fm.set { find_auto_accept = true }` gives ranger's behavior.

6. **Messages go to the status line, not toasts.** The first version
   showed every message twice, in the status line and in a siv toast
   over the columns. The status line is a polite live region, so screen
   readers announce messages either way; toasts are gone. Errors are red
   in the status line. Say if errors should also toast.

## Noted

7. **siv is private, so `zig fetch` cannot reach it.** As in siv-files:
   a git submodule (`deps/siv`) and a path dependency; clone with
   `--recurse-submodules`.

8. **The focus ring.** siv draws a focus ring when focus moved by
   keyboard; focus returns to the cursor's row from a key handler when a
   prompt closes, so the ring appears then and not before (when focus
   came from creating the window). Both are siv's documented rule; the
   selection highlight is the cursor either way.

9. **Bulk rename waits for the editor.** `R` writes the names to a
   file, runs `$VISUAL`/`$EDITOR` in a terminal, and renames when the
   editor exits, so the terminal must stay in the foreground until then:
   foot, alacritty, kitty, wezterm, and ghostty do; gnome-terminal does
   with `--wait`, which the app passes. `fm.set { terminal = "...",
   editor = "...", editor_in_terminal = false }` covers the rest.

10. **Settling while a job waits for the user.** As in siv-files:
    `siv_test_settle` waits for running jobs, so a test cannot settle
    while a copy waits for the conflict question; the tests dispatch
    until the question shows.

11. **No monospace font in the tests.** The text preview asks for the
    generic `monospace` family; the headless tests load only Droid Sans,
    so their goldens show code in it. Real desktops get their monospace
    font.

12. **A large static binary.** ReleaseSafe with libsiv, its decoders,
    and Lua linked in is 46 MB unstripped (`-Doptimize=ReleaseSmall` or
    stripping makes it much smaller); it maps lazily, so startup does
    not pay for it.
