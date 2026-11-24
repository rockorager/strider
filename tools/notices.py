#!/usr/bin/env python3
"""Writes NOTICES to stdout: the licences of what the strider binary
compiles in, for `just release` to ship in share/doc/strider.

It walks Cargo's resolved graph from the strider crate along the
dependencies that build into the binary on x86-64 Linux (not build
scripts' or tests'), and gives each crate its licence files as they are
in its source: LICENSE*, COPYING*, and NOTICE*, also those further down,
such as the libxkbcommon licence in keywork-platform."""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TARGET = "x86_64-unknown-linux-gnu"
NAMES = ("LICENSE", "LICENCE", "COPYING", "NOTICE", "UNLICENSE")
SKIP = {"tests", "test", "benches", "examples", "target", ".git", "fuzz"}


def licence_files(top):
    found = []
    stack = [top]
    while stack:
        d = stack.pop()
        for p in sorted(d.iterdir()):
            if p.is_dir():
                if p.name not in SKIP:
                    stack.append(p)
            elif p.name.upper().startswith(NAMES) and p.suffix not in (".rs", ".py", ".toml"):
                found.append(p)
    return sorted(found)


def main():
    meta = json.loads(
        subprocess.run(
            ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", TARGET],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )
    packages = {p["id"]: p for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    members = set(meta["workspace_members"])
    start = next(i for i in members if packages[i]["name"] == "strider")
    seen, todo = set(), [start]
    while todo:
        i = todo.pop()
        if i in seen:
            continue
        seen.add(i)
        # A macro runs as the compiler does; none of it is in the binary.
        if any("proc-macro" in t["kind"] for t in packages[i]["targets"]):
            continue
        for dep in nodes[i]["deps"]:
            if any(k["kind"] is None for k in dep["dep_kinds"]):
                todo.append(dep["pkg"])
    out = sys.stdout
    out.write("strider compiles in the code below, under the licences that follow each.\n")
    bare = []
    texts = {}
    shipped = [packages[i] for i in seen - members]
    shipped = [p for p in shipped if not any("proc-macro" in t["kind"] for t in p["targets"])]
    for p in sorted(shipped, key=lambda p: (p["name"], p["version"])):
        top = Path(p["manifest_path"]).parent
        files = licence_files(top)
        out.write(f"\n{'=' * 72}\n{p['name']} {p['version']} ({p.get('license') or 'no licence named'})\n")
        if p.get("repository"):
            out.write(f"{p['repository']}\n")
        if not files:
            bare.append(p["name"])
        for f in files:
            text = f.read_text(errors="replace").strip()
            name = f"{p['name']}'s {f.relative_to(top)}"
            if text in texts:
                out.write(f"\n--- {f.relative_to(top)}: as {texts[text]}\n")
            else:
                texts[text] = name
                out.write(f"\n--- {f.relative_to(top)}\n\n{text}\n")
    if bare:
        print(f"no licence file in {', '.join(bare)}; NOTICES names their licences only", file=sys.stderr)


main()
