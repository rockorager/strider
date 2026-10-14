#!/usr/bin/env python3
"""Creates the benchmark's folders under DIR (default ~/fm-bench-fixtures):

  small/  40 entries: 8 folders and 32 files of mixed kinds
  big/    100 100 entries: file-0 ... file-99999 in seven kinds, every third
          with a size, and folder-0, folder-1000, ... (the same folder as
          tests/bench.zig's makeFolder)

Files are sparse (ftruncate), so the folders take little space.
"""
import os
import sys

EXT = ["txt", "pdf", "png", "zig", "tar.gz", "flac", "md"]


def make(base):
    small = os.path.join(base, "small")
    os.makedirs(small, exist_ok=True)
    for name in ["Archive", "Documents", "Music", "Photos", "Projects", "Receipts", "Scans", "src"]:
        os.makedirs(os.path.join(small, name), exist_ok=True)
        open(os.path.join(small, name, "notes.txt"), "w").write("notes\n")
    names = ["README.md", "build.zig", "notes.txt", "todo.txt", "budget.csv", "report.pdf", "photo.png",
             "logo.svg", "song.flac", "backup.tar.gz", "main.c", "main.zig", "config.toml", "data.json",
             "index.html", "style.css", "script.sh", "Makefile", "LICENSE", "invoice-2026-09.pdf",
             "invoice-2026-10.pdf", "slides.odp", "letter.odt", "sheet.ods", "video.mp4", "track.mp3",
             "archive.zip", "diagram.png", "screenshot.png", "paper.pdf", "draft.md", "log.txt"]
    for i, name in enumerate(names):
        with open(os.path.join(small, name), "w") as f:
            f.write(f"{name}: line {i}\n" * (i + 1))
    big = os.path.join(base, "big")
    if os.path.isdir(big) and len(os.listdir(big)) == 100_100:
        return
    os.makedirs(big, exist_ok=True)
    for i in range(100_000):
        p = os.path.join(big, f"file-{i}.{EXT[i % len(EXT)]}")
        fd = os.open(p, os.O_WRONLY | os.O_CREAT, 0o644)
        if i % 3 == 0:
            os.ftruncate(fd, i * 37)
        os.close(fd)
        if i % 1000 == 0:
            os.makedirs(os.path.join(big, f"folder-{i}"), exist_ok=True)


if __name__ == "__main__":
    make(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/fm-bench-fixtures"))
