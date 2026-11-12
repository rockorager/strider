# Strider: a keyboard-driven file manager for Wayland. `just --list` shows
# the recipes. AGENTS.md holds the working conventions.
#
# `zig` is the compiler: bs for development builds, or upstream Zig where
# bs is not installed. `just zig=zig test` uses upstream Zig anyway, for a
# release build or what bs cannot compile.

zig := `command -v bs >/dev/null && echo bs || echo zig`

# `just setup` makes baskingspot-lint from github.com/baskingspot/nix at
# this commit: its script and its ast-grep rules.

rules_rev := "b246e853a3836a6279526db1d8f8fa54c14e6b7a"

# Where releases are published, as GitHub Releases: `just release` attaches
# each release's build to its tag, and `just fetch` installs the newest.

github := "rockorager/strider"

[private]
default:
    @just --list

[doc("Make baskingspot-lint in ~/.local/bin from its pin; `mise install` installs the rest")]
[group("build")]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    bin=$HOME/.local/bin
    rules=${XDG_CACHE_HOME:-$HOME/.cache}/strider/baskingspot-nix-{{ rules_rev }}
    if [ ! -d "$rules" ]; then
        rm -rf "$rules.tmp"
        git init -q "$rules.tmp"
        git -C "$rules.tmp" fetch -q --depth 1 https://github.com/baskingspot/nix {{ rules_rev }}
        git -C "$rules.tmp" checkout -q FETCH_HEAD
        mv "$rules.tmp" "$rules"
    fi
    mkdir -p "$bin"
    cat >"$bin/baskingspot-lint" <<EOF
    #!/usr/bin/env bash
    export BASKINGSPOT_RULES="$rules/pkgs/ast-grep-rules/rules"
    exec bash "$rules/pkgs/baskingspot-lint/baskingspot-lint.sh" "\$@"
    EOF
    chmod +x "$bin/baskingspot-lint"

[doc("Build strider into zig-out/bin/strider")]
[group("build")]
build *ARGS:
    {{ zig }} build {{ ARGS }}

[doc("Install a release build of strider, its desktop entry, and its icon under PREFIX")]
[group("build")]
install prefix="~/.local":
    zig build install -p {{ prefix }}

[doc("Install the newest release's build under PREFIX, without building")]
[group("build")]
fetch prefix="~/.local":
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="{{ prefix }}"
    prefix="${prefix/#\~/$HOME}"
    release=$(curl -fsS --retry 3 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/{{ github }}/releases/latest") ||
        { echo "no release of strider is published yet" >&2; exit 1; }
    build=$(jq -ce '[.assets[] | select(.name | test("^strider-.+-x86_64-linux\\.tar\\.gz$"))] | first // error' <<<"$release") ||
        { echo "$(jq -r .tag_name <<<"$release") has no build to install" >&2; exit 1; }
    name=$(jq -r .name <<<"$build")
    echo "$name of $(jq -r .tag_name <<<"$release"), built $(jq -r .created_at <<<"$build")"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --retry 3 -o "$tmp/strider.tar.gz" "$(jq -r .browser_download_url <<<"$build")"
    # GitHub records each asset's sha256 as it was uploaded.
    if [ "sha256:$(sha256sum "$tmp/strider.tar.gz" | cut -c1-64)" != "$(jq -r .digest <<<"$build")" ]; then
        echo "the download of $name is not the build published, so $prefix is left as it was" >&2
        exit 1
    fi
    mkdir "$tmp/root"
    tar -xzf "$tmp/strider.tar.gz" -C "$tmp/root"
    # A build for a CPU or a glibc this machine lacks dies before it says
    # its version.
    version=${name#strider-}
    version=${version%-x86_64-linux.tar.gz}
    out=$("$tmp/root/bin/strider" --version 2>&1) || true
    if [ "$out" != "strider $version" ]; then
        printf '%s does not say "strider %s" when run here, so %s is left as it was:\n%s\n' "$name" "$version" "$prefix" "$out" >&2
        exit 1
    fi
    # The desktop entry and D-Bus service files name the program by its
    # absolute path: the archive's @PREFIX@ becomes this prefix.
    grep -rlIF @PREFIX@ "$tmp/root" | while IFS= read -r file; do
        sed -i "s|@PREFIX@|$prefix|g" "$file"
    done
    (cd "$tmp/root" && find . -type f) | while IFS= read -r file; do
        mkdir -p "$(dirname "$prefix/$file")"
        cp "$tmp/root/$file" "$prefix/$file.new"
        # Each file goes in by a rename, so a strider running keeps the
        # one it started from, and an install cut short leaves no file
        # half written.
        mv -f "$prefix/$file.new" "$prefix/$file"
    done
    echo "installed $prefix/bin/strider"

[doc("Release origin/main: VERSION is patch (the default), minor, major, or X.Y.Z. Commit the version, build, push, and publish it")]
[group("build")]
release version="":
    #!/usr/bin/env bash
    set -euo pipefail
    die() {
        echo "$*" >&2
        exit 1
    }
    # gh signed in as an owner or collaborator of the repository.
    gh auth status >/dev/null 2>&1 || die "gh is not signed in to GitHub"
    git fetch -q --tags origin main
    base=$(git rev-parse origin/main)
    echo "origin/main is $(git log -1 --format='%h %s' "$base")"
    ahead=$(git rev-list --count origin/main..HEAD)
    if [ "$ahead" -gt 0 ]; then
        echo "HEAD has $ahead commits origin/main lacks, which this release leaves out" >&2
    fi
    # A release cut short finishes when run again: origin/main tagged
    # without its build, as a run that pushed but did not publish leaves
    # it, gets the build under that tag.
    tagged=$(git describe --exact-match --tags --match 'v[0-9]*' "$base" 2>/dev/null || true)
    # The tags are the versions, by semver: the newest one bumped, its
    # patch unless told minor or major, or the version given. A release
    # cut short keeps the version it was tagged.
    version="{{ version }}"
    last=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
    if [ -n "$tagged" ] && [[ $version =~ ^(|patch|minor|major)$ ]]; then
        version=${tagged#v}
    elif [[ $version =~ ^(|patch|minor|major)$ ]]; then
        IFS=. read -r major minor patch <<<"${last:-v0.0.0}"
        major=${major#v}
        case $version in
            major) version=$((major + 1)).0.0 ;;
            minor) version=$major.$((minor + 1)).0 ;;
            *) version=$major.$minor.$((patch + 1)) ;;
        esac
    fi
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$version is not patch, minor, major, or a version, MAJOR.MINOR.PATCH"
    tag=v$version
    name=strider-$version-x86_64-linux.tar.gz
    if [ -n "$tagged" ] && [ "$tagged" != "$tag" ]; then
        die "origin/main is $tagged already, not $tag"
    elif [ -z "$tagged" ]; then
        if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
            die "$tag is $(git rev-parse --short "$tag^{commit}") already"
        fi
        if [ "$(printf '%s\n' "$last" "$tag" | sort -V | tail -1)" != "$tag" ]; then
            die "$tag is older than the newest release, $last"
        fi
    fi
    # For checking the bump: semver's patch for fixes, minor for features,
    # major for what breaks. They are the release's notes too.
    prev=$(git tag -l 'v[0-9]*' --sort=-v:refname --merged "$base" | grep -vx "$tag" | head -1 || true)
    notes=$(git log --format='- %s' "${prev:+$prev..}$base")
    echo "releasing as $tag what came since ${prev:-the start}:"
    sed 's/^- /  /' <<<"$notes"
    # What GitHub holds under this tag, and whether origin has the tag.
    if assets=$(gh release view "$tag" -R {{ github }} --json assets --jq '.assets[].name' 2>/dev/null); then
        grep -qx "$name" <<<"$assets" && die "$tag is released already, with $name"
        die "$tag has a release without $name: delete it or attach the build by hand"
    fi
    pushed=$(git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null) || die "cannot list origin's tags"

    # The pushed commit alone, whatever this checkout holds, in a worktree
    # every release reuses: Zig's cache keys hold the sources' paths, so
    # only there does it find what the last release compiled. One another
    # clone made, or this clone forgot, starts over.
    src=${XDG_CACHE_HOME:-$HOME/.cache}/strider/release
    git worktree prune
    if [ -e "$src/.git" ] && [ "$(git -C "$src" rev-parse --git-common-dir 2>/dev/null)" -ef "$(git rev-parse --git-common-dir)" ]; then
        git -C "$src" checkout -q --force --detach "$base"
    else
        rm -rf "$src"
        git worktree add -q --detach "$src" "$base"
    fi
    # mise runs a checkout's own pins only once it is trusted.
    if command -v mise >/dev/null && [ -e "$src/mise.toml" ]; then
        mise trust -q "$src/mise.toml"
        (cd "$src" && mise install -q)
    fi
    # The release commit sets build.zig.zon's version, which strider
    # --version reports, unless origin/main says it already.
    sha=$base
    if [ -z "$tagged" ]; then
        sed -i "s/^    \.version = \".*\",\$/    .version = \"$version\",/" "$src/build.zig.zon"
        grep -q "^    \.version = \"$version\",\$" "$src/build.zig.zon" || die "build.zig.zon names no version to set"
        if ! git -C "$src" diff --quiet; then
            git -C "$src" commit -q -am "release: $version"
            sha=$(git -C "$src" rev-parse HEAD)
        fi
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # CI tests a commit only once it is pushed, so the release runs the
    # release commit's own build and tests first.
    (cd "$src" && just ci)
    # For x86-64-v3 (AVX2, 2013 on), not this machine's CPU: an orb's has
    # AVX-512, which laptops such as Lunar Lake lack, and strider built
    # for it dies there at its first such instruction.
    (cd "$src" && zig build install -Dcpu=x86_64_v3 \
        -Ddynamic-linker=/lib64/ld-linux-x86-64.so.2 -p "$tmp/root")
    # The desktop and D-Bus service files name the program by its absolute
    # path: @PREFIX@ in the archive, for `just fetch` to fill in.
    grep -rlIF "$tmp/root" "$tmp/root" | while IFS= read -r file; do
        sed -i "s|$tmp/root|@PREFIX@|g" "$file"
    done
    if grep -rlF "$tmp/root" "$tmp/root" >/dev/null; then
        die "a file installed names the build's prefix, $tmp/root"
    fi
    bin=$tmp/root/bin/strider
    strip "$bin"
    # It runs on other machines, so it must find their libraries, not the
    # paths of the one that built it (a Nix shell's, say).
    if grep -qE 'RPATH|RUNPATH' <<<"$(readelf -d "$bin")"; then
        die "strider names a library path; build outside a Nix shell"
    fi
    # Nor may it need a glibc newer than theirs, 2.38. The braces keep grep
    # finding nothing from passing for objdump failing, which pipefail
    # reports.
    glibc=$(objdump -T "$bin" | { grep -oE 'GLIBC_[0-9.]+' || true; } | sort -Vu | tail -1)
    if [ "$(printf '%s\n' "$glibc" GLIBC_2.38 | sort -V | tail -1)" != GLIBC_2.38 ]; then
        die "strider needs $glibc, newer than the 2.38 the desktops it is for have"
    fi
    out=$("$bin" --version 2>&1) || true
    [ "$out" = "strider $version" ] || die "strider does not say it is $version: $out"
    # Owned by root, so an install by root leaves no files of this uid.
    tar -C "$tmp/root" --owner=0 --group=0 --numeric-owner -czf "$tmp/$name" .
    echo "$name of ${sha:0:7}: $(du -h "$bin" | cut -f1) binary, $(du -h "$tmp/$name" | cut -f1) archive"

    # The release commit and its tag are pushed together or neither: main
    # moved since the fetch takes neither.
    if [ -z "$pushed" ]; then
        [ -n "$tagged" ] || git tag -a "$tag" -m "strider $version" "$sha"
        refs=("refs/tags/$tag")
        [ "$sha" = "$base" ] || refs+=("$sha:refs/heads/main")
        if ! git push -q --atomic origin "${refs[@]}"; then
            # Untagged again, so the next release is not numbered past it.
            [ -n "$tagged" ] || git tag -d "$tag" >/dev/null
            die "cannot push $tag; if main moved, run just release again"
        fi
    fi
    # Then its release, with the build attached.
    url=$(gh release create "$tag" "$tmp/$name" -R {{ github }} --verify-tag \
        --title "strider $version" --notes "$notes") ||
        die "$tag is pushed without its release: run just release again to publish it"
    # What just fetch downloads is what was built.
    digest=$(gh release view "$tag" -R {{ github }} --json assets --jq ".assets[] | select(.name == \"$name\") | .digest")
    [ "$digest" = "sha256:$(sha256sum "$tmp/$name" | cut -c1-64)" ] ||
        die "GitHub does not hold $name as uploaded ($digest)"
    echo "published $url"

[doc("Build and run strider on the Wayland display")]
[group("build")]
run *ARGS:
    {{ zig }} build run -- {{ ARGS }}

[doc("The unit and headless tests, on siv's headless backend: no display needed")]
[group("test")]
test *ARGS:
    {{ zig }} build test --summary failures {{ ARGS }}

[doc("Lint Zig, shell, Markdown, and this justfile: zig fmt, baskingspot-lint, shellcheck, shfmt, oxfmt, and just --fmt; bs lints with ziglint's rules as it builds")]
[group("lint")]
lint:
    zig fmt --check build.zig build.zig.zon src tests tools
    baskingspot-lint build.zig src tests tools
    shellcheck .agents/setup .agents/resume
    shfmt --diff .agents/setup .agents/resume
    oxfmt --check README.md AGENTS.md
    just --unstable --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt build.zig build.zig.zon src tests tools
    shfmt --write .agents/setup .agents/resume
    oxfmt README.md AGENTS.md
    just --unstable --fmt

[doc("The build, the tests, and lint; tests alone leave unused code unchecked")]
[group("ci")]
ci: build test lint
