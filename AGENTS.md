# Strider

A keyboard-driven file manager for Linux on Wayland, in Zig 0.17.1, on the
[siv](https://github.com/rockorager/siv) GUI toolkit.

## Toolchain

- Zig 0.17.1 exactly. bs refuses any other release.
- [bs](https://github.com/baskingspot/bs) compiles development builds. It
  takes `zig build`'s commands and flags and needs upstream `zig` 0.17.1 on
  `PATH` for the std library and for C sources. Release builds use upstream
  `zig build`. Where bs is not installed, as for someone building from the
  README, the recipes use upstream `zig`.
- bs lints as it compiles: `.bs.zon` turns on ziglint's rules, as
  compile errors in `build.zig`, `src`, `tests`, and `tools`, the files a
  build reaches. So `just build` and `just test` fail on a finding, and
  there is no separate ziglint.
- mise and just set up development. `mise install` installs what
  `mise.toml` pins (zig, bs, just, shellcheck, shfmt, ast-grep, oxfmt;
  `mise.lock` holds their checksums), for the orb setup, CI, and
  `just release` alike, and `just setup` makes `baskingspot-lint` in
  `~/.local/bin` from the commit of the baskingspot ast-grep rules the
  justfile pins (`rules_rev`). To move a pin, change it there and run
  `mise lock --platform linux-x64,linux-arm64` or `just setup`.
- In an orb, `.agents/setup` installs siv's system libraries and mise,
  then runs both, and links mise's shims into `~/.local/bin`, since the
  agent's shells do not activate mise.

## Commands

The justfile is the interface. `just --list` shows every recipe.

```sh
just setup          # baskingspot-lint, from its pin
just build          # zig-out/bin/strider
just install        # a release build, desktop entry, and icon in ~/.local
just release [BUMP] # release origin/main: patch, minor, major, or X.Y.Z
just fetch          # install the published build, no compiler
just run            # on the Wayland display
just test           # siv's headless backend; no display needed
just lint           # zig fmt, baskingspot-lint, shellcheck, shfmt, oxfmt, just --fmt
just fmt            # format what lint checks
just ci             # build, test, and lint
just zig=zig test   # any recipe with upstream Zig instead of bs
```

## Writing Zig

- Load the `zig-017` skill (`.agents/skills/zig-017`, vendored from
  baskingspot/skills at 6888cc2 by way of parcel) before writing Zig, and
  follow its style. Check APIs against the pinned toolchain's std
  (`zig env`), not memory.
- bs's lint (ziglint's rules) runs in every build, and
  `baskingspot-lint`, the org's ast-grep rules, in `just lint`. Fix a finding rather than suppress it, unless the rule's
  own note names the exception.

## Releasing

CI tests each push to GitHub. After a push, `just release BUMP` releases
origin/main from an orb. It lists the commits since the last tag, then
commits `release: X.Y.Z`, setting `build.zig.zon`'s version, which
`strider --version` reports; runs `just ci` on it; builds it; pushes the
commit to main and its tag `vX.Y.Z` in one atomic push; and publishes a
GitHub release of the tag with the build attached and those commits as
its notes. A release cut short finishes when run again; one that finds
main moved pushes nothing. `just fetch` installs the newest, once its
download matches the sha256 GitHub recorded and `strider --version` names
it.

Versions follow semver strictly from the start: 0.x has no exemption, so
what breaks bumps the major even now. The bump is the highest any commit
since the last tag needs:

- `major`: what makes a user act or lose something. A key, command,
  option, or `strider` argument removed or doing something else; settings,
  bookmarks, or history a new build cannot read; a Lua API removed or
  changed; a higher floor for the system it runs on (glibc, CPU,
  libraries).
- `minor`: something new, with nothing old breaking. A key, command,
  view, option, or Lua function added.
- `patch`: fixes alone, adding no behaviour.

Release only when asked. Choose the bump from the commits the recipe
lists, read for what changed for the user rather than from their
subjects, and say which you chose and why. When it is between two, take
the higher. `just release X.Y.Z` names a version outright; never bump
`build.zig.zon` by hand.

Releasing needs `gh` signed in as someone who can push to
rockorager/strider. The build is for x86-64-v3 (AVX2), not the orb's CPU,
whose AVX-512 laptops lack, and may link no glibc symbol newer than 2.38,
which `just release` checks.
