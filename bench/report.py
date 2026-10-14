#!/usr/bin/env python3
"""Summarizes bench/raw/*.json (run.py) as a Markdown table: for numbers
measured once per run, the median over runs and the worst run; for
latencies measured many times per run, the median and the worst of every
sample of every run.

    python3 bench/report.py [DIR] > table.md
"""
import glob
import json
import os
import statistics
import sys

DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw")
APPS = [("columns", "siv-columns"), ("nautilus", "Nautilus")]
runs = {a: [json.load(open(p)) for p in sorted(glob.glob(os.path.join(DIR, f"{a}-*.json")))] for a, _ in APPS}
for a in runs:
    runs[a] = [r for r in runs[a] if "error" not in r]


def get(r, path):
    for k in path.split("."):
        r = r[k]
    return r


def once(path, scale=1.0, fmt="{:.0f}", high_is_bad=True):
    """Median over runs, and the worst run."""
    def cell(a):
        xs = [get(r, path) * scale for r in runs[a]]
        if not xs:
            return "–"
        worst = max(xs) if high_is_bad else min(xs)
        return f"{fmt.format(statistics.median(xs))} ({fmt.format(worst)})"
    return cell


def pooled(path, fmt="{:.1f}"):
    """Median and maximum of every sample of every run."""
    def cell(a):
        xs = [x for r in runs[a] for x in get(r, path)]
        if not xs:
            return "–"
        return f"{fmt.format(statistics.median(xs))} ({fmt.format(max(xs))})"
    return cell


MIB = 1 / 1024
ROWS = [
    ("Cold start (page cache dropped): first frame, ms", once("cold.first_frame_ms")),
    ("Cold start: rows on screen, ms", once("cold.rows_ms")),
    ("Cold start: settled (icons, sizes), ms", once("cold.complete_ms")),
    ("Warm start: first frame, ms", once("warm.first_frame_ms")),
    ("Warm start: rows on screen, ms", once("warm.rows_ms")),
    ("Warm start: settled, ms", once("warm.complete_ms")),
    ("Memory after start: RSS, MiB", once("memory_start.app.rss_kib", MIB)),
    ("Memory after start: PSS, MiB (with child processes)", once("memory_start.app_tree.pss_kib", MIB)),
    ("Memory after start: GPU (VRAM + GTT), MiB", once("memory_start.app.gpu_kib", MIB)),
    ("Idle 10 s after start: wakeups/s", once("idle_start.app.wakeups_per_s", fmt="{:.1f}")),
    ("Open 100 100 entries, cold: rows on screen, ms", once("open_big_cold.rows_ms")),
    ("Open 100 100 entries, cold: settled, ms", once("open_big_cold.complete_ms")),
    ("Open 100 100 entries, warm: rows on screen, ms", once("open_big.rows_ms")),
    ("Open 100 100 entries, warm: settled, ms", once("open_big.complete_ms")),
    ("Open 100 100 entries, warm: CPU time, ms", once("open_big.cpu_ms")),
    ("Memory with 100 100 entries: RSS, MiB", once("memory_big.app.rss_kib", MIB)),
    ("Memory with 100 100 entries: PSS, MiB (with child processes)", once("memory_big.app_tree.pss_kib", MIB)),
    ("Idle 10 s with 100 100 entries: wakeups/s", once("idle_big.app.wakeups_per_s", fmt="{:.1f}")),
    ("Idle 10 s with 100 100 entries: CPU, %", once("idle_big.app.cpu_percent", fmt="{:.2f}")),
    ("Down, key to photon, ms (100 presses)", pooled("down_ms")),
    ("Down held (30/s for 2 s), key to photon, ms", pooled("down_held.latency_ms")),
    ("Down held: CPU per frame, ms", once("down_held.cpu_ms_per_frame", fmt="{:.2f}")),
    ("Down held: dropped frames", once("down_held.dropped")),
    ("Page Down, key to photon, ms", pooled("page_down_ms")),
    ("End, key to photon, ms", pooled("end_ms")),
    ("Home, key to photon, ms", pooled("home_ms")),
    ("Touchpad scroll (5 s): frames presented", once("scroll.frames", high_is_bad=False)),
    ("Touchpad scroll: dropped frames", once("scroll.dropped")),
    ("Touchpad scroll: worst frame interval, ms", once("scroll.interval_max_ms", fmt="{:.1f}")),
    ("Touchpad scroll: CPU per frame, ms", once("scroll.cpu_ms_per_frame", fmt="{:.2f}")),
    ("Wheel notch to photon, ms", pooled("wheel_ms")),
    ("Filter \"12345\" typed: each key to photon, ms", pooled("filter_key_ms")),
    ("Filter: last key to final result on screen, ms", once("filter.complete_ms")),
    ("Filter: CPU time while typing, ms", once("filter.cpu_ms")),
    ("Memory at the end: RSS, MiB", once("memory_end.app.rss_kib", MIB)),
]

print(f"Median (worst); {', '.join(f'{len(runs[a])} runs of {n}' for a, n in APPS)}.\n")
print("| Measurement | " + " | ".join(n for _, n in APPS) + " |")
print("| --- | " + " | ".join("---" for _ in APPS) + " |")
for label, cell in ROWS:
    print(f"| {label} | " + " | ".join(cell(a) for a, _ in APPS) + " |")

# Nautilus's GVfs services, outside its process.
svc = [r["memory_start"]["services"]["pss_kib"] * MIB for r in runs["nautilus"]]
svc_big = [r["idle_big"]["services"]["wakeups_per_s"] for r in runs["nautilus"]]
if svc:
    print(f"\nGVfs services after Nautilus started ({', '.join(runs['nautilus'][0]['services'])}): "
          f"PSS {statistics.median(svc):.1f} MiB (median), idle wakeups {statistics.median(svc_big):.1f}/s.")
