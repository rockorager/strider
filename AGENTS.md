# Strider

A keyboard-driven file manager for Linux on Wayland, in Zig 0.17.0, on the
[siv](https://github.com/rockorager/siv) GUI toolkit.

## Commands

The justfile is the interface. `just --list` shows every recipe.

```sh
just build          # zig-out/bin/strider
just install        # a release build, desktop entry, and icon in ~/.local
just release [BUMP] # release origin/main: patch, minor, major, or X.Y.Z
just fetch          # install the published build, no compiler
just run            # on the Wayland display
just test           # siv's headless backend; no display needed
just ci             # build and test
```

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
