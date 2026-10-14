#!/usr/bin/env python3
"""siv-columns against GNOME Files (Nautilus), measured from outside the
programs on a real sway session. See bench/README.md for the method.

    sudo python3 bench/run.py [--runs N] [--apps columns,nautilus] [--out DIR]
                              [--backend drm|headless] [--screenshots DIR]

Runs as root (sway on the KMS device, dropping the page cache); the file
managers run as the unprivileged user --user (Nautilus refuses root), with
fixtures from bench/fixtures.py in that user's home. Each run of each app
gets a fresh sway, session bus, and services, then: a cold start (page
cache dropped) and the 100 100-entry folder opened cold, a warm start
and the folder opened warm, idle windows, keyboard and scroll input in
that folder, and a filter typed.
Results go to DIR/<app>-<run>.json; report.py summarizes them.
"""

import argparse
import glob
import json
import os
import pwd
import shutil
import socket
import struct
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
W, H = 1280, 800
REFRESH_NS = 1e9 / 60.003

# Per app: the command, the screen rectangle (x0, y0, x1, y1) where its
# folder's rows are, how to go to a folder by typing, how to start
# filtering, and where the pointer rests to scroll. The rectangles come
# from screenshots at 1280x800: Nautilus's list right of the sidebar and
# below the column headers; siv-columns's middle (current folder) column.
APPS = {
    "columns": {
        "cmd": [os.environ.get("BENCH_COLUMNS", "/opt/siv-columns/bin/siv-columns"), "--light"],
        "rows": (168, 32, 640, 772),
        "goto": lambda path: [f"typeburst 15 :cd {path}"],
        "filter": ["key z", "key f"],
        "pointer": (400, 400),
    },
    "nautilus": {
        "cmd": ["nautilus"],
        "rows": (244, 84, 1264, 800),
        "goto": lambda path: ["key ctrl+l", f"typeburst 15 {path}"],
        "filter": [],
        "pointer": (760, 420),
    },
}
# Services the session bus may start: GVfs (which Nautilus uses and a
# GNOME session runs anyway). Not the accessibility bus, the portals, or
# LocalSearch/Tracker; see README.md.
SERVICES = ["org.gtk.vfs.Daemon", "org.gtk.vfs.Metadata", "org.gtk.vfs.UDisks2VolumeMonitor"]


def now():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


# Session: sway, the user's runtime directory and bus -----------------------------------------


class Session:
    def __init__(self, backend, user):
        self.user = pwd.getpwnam(user)
        self.dir = f"/tmp/fm-bench-{os.getpid()}-{now()}"
        os.makedirs(self.dir, mode=0o711)
        with open(os.path.join(self.dir, "config"), "w") as f:
            f.write("output * mode 1280x800@60.003Hz position 0 0 scale 1\n"
                    "default_border none\ndefault_floating_border none\nfocus_follows_mouse no\n")
        env = {"PATH": "/usr/bin", "HOME": "/root", "XDG_RUNTIME_DIR": self.dir, "WLR_RENDERER": "vulkan",
               "WLR_RENDER_DRM_DEVICE": "/dev/dri/renderD128", "WLR_LIBINPUT_NO_DEVICES": "1"}
        if backend == "drm":
            env.update(WLR_BACKENDS="drm", WLR_DRM_DEVICES="/dev/dri/card1", LIBSEAT_BACKEND="noop")
        else:
            env.update(WLR_BACKENDS="headless")
        self.log = open(os.path.join(self.dir, "sway.log"), "w")
        self.sway = subprocess.Popen(["sway", "-c", os.path.join(self.dir, "config")], env=env, stdout=self.log,
                                     stderr=subprocess.STDOUT, start_new_session=True)
        self.wayland = os.path.join(self.dir, "wayland-1")
        for _ in range(500):
            socks = glob.glob(os.path.join(self.dir, "sway-ipc.*.sock"))
            if socks and os.path.exists(self.wayland):
                self.ipc_path = socks[0]
                try:
                    self.ipc("nop")
                    break
                except OSError:
                    pass
            time.sleep(0.01)
        else:
            raise RuntimeError("sway did not start")
        os.chmod(self.wayland, 0o666)
        self.root_env = {"PATH": "/usr/bin", "XDG_RUNTIME_DIR": self.dir, "WAYLAND_DISPLAY": "wayland-1"}
        # The user's session: its own runtime directory and session bus.
        self.rt = os.path.join(self.dir, "user")
        os.makedirs(self.rt, mode=0o700)
        os.chown(self.rt, self.user.pw_uid, self.user.pw_gid)
        svc = os.path.join(self.dir, "services")
        os.makedirs(svc)
        for name in SERVICES:
            shutil.copy(f"/usr/share/dbus-1/services/{name}.service", svc)
        with open(os.path.join(self.dir, "bus.conf"), "w") as f:
            f.write(f"""<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:path={self.rt}/bus</listen><auth>EXTERNAL</auth>
<servicedir>{svc}</servicedir><policy context="default"><allow send_destination="*" eavesdrop="true"/>
<allow eavesdrop="true"/><allow own="*"/></policy></busconfig>
""")
        home = self.user.pw_dir
        # Nautilus in its list view (GSettings in a key file, no dconf).
        conf = os.path.join(home, ".config", "glib-2.0", "settings")
        os.makedirs(conf, exist_ok=True)
        with open(os.path.join(conf, "keyfile"), "w") as f:
            f.write("[org/gnome/nautilus/preferences]\ndefault-folder-viewer='list-view'\n")
        subprocess.run(["chown", "-R", f"{user}:", os.path.join(home, ".config")])
        self.env = {"PATH": "/usr/bin", "HOME": home, "USER": user, "LANG": "C.UTF-8", "XDG_RUNTIME_DIR": self.rt,
                    "WAYLAND_DISPLAY": self.wayland, "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": f"unix:path={self.rt}/bus", "GSETTINGS_BACKEND": "keyfile"}
        self.bus = self.spawn(["dbus-daemon", "--config-file", os.path.join(self.dir, "bus.conf"), "--nofork"],
                              stderr=subprocess.DEVNULL)
        # Where the user can load it from.
        self.presshim = os.path.join(self.dir, "presshim.so")
        shutil.copy(os.path.join(OUT, "presshim.so"), self.presshim)
        os.chmod(self.presshim, 0o755)
        for _ in range(500):
            if os.path.exists(os.path.join(self.rt, "bus")):
                break
            time.sleep(0.01)
        # The services a desktop session already runs.
        for name in SERVICES:
            subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                            "org.freedesktop.DBus.StartServiceByName", f"string:{name}", "uint32:0"],
                           env=self.env, user=self.user.pw_uid, group=self.user.pw_gid, extra_groups=[],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)

    def spawn(self, cmd, env=None, **kw):
        return subprocess.Popen(cmd, env=env or self.env, user=self.user.pw_uid, group=self.user.pw_gid, extra_groups=[],
                                cwd=self.user.pw_dir, **kw)

    def ipc(self, cmd):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.ipc_path)
        data = cmd.encode()
        s.sendall(b"i3-ipc" + struct.pack("<II", len(data), 0) + data)
        hdr = b""
        while len(hdr) < 14:
            hdr += s.recv(14 - len(hdr))
        n = struct.unpack("<I", hdr[6:10])[0]
        body = b""
        while len(body) < n:
            body += s.recv(n - len(body))
        s.close()
        return json.loads(body)

    def user_pids(self):
        out = []
        for p in glob.glob("/proc/[0-9]*"):
            try:
                if os.stat(p).st_uid == self.user.pw_uid:
                    out.append(int(os.path.basename(p)))
            except FileNotFoundError:
                pass
        return out

    def stop(self):
        for pid in self.user_pids():
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        time.sleep(0.3)
        for pid in self.user_pids():
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        subprocess.run(["fusermount3", "-uz", os.path.join(self.rt, "gvfs")], stderr=subprocess.DEVNULL)
        try:
            os.killpg(self.sway.pid, 15)
            self.sway.wait(timeout=5)
        except Exception:
            os.killpg(self.sway.pid, 9)
        self.log.close()
        shutil.rmtree(self.dir, ignore_errors=True)


class Injector:
    def __init__(self, env):
        self.proc = subprocess.Popen([os.path.join(OUT, "inject")], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        if self.proc.stdout.readline().strip() != "ready":
            raise RuntimeError("inject failed to start")

    def send(self, cmd):
        """Sends one command; returns the flush time of each event it made."""
        self.proc.stdin.write(cmd + "\n")
        verb, arg = (cmd.split(" ", 1) + [""])[:2]
        n = {"typeburst": len(arg.split(" ", 1)[-1]), "keyburst": int(arg.split()[1]) if verb == "keyburst" else 0,
             "scrollburst": int(arg.split()[-1]) if verb == "scrollburst" else 0}.get(verb, 1)
        self.proc.stdin.flush()
        return [int(self.proc.stdout.readline().split()[1]) for _ in range(n)]

    def stop(self):
        self.proc.stdin.close()
        self.proc.wait()


class Capture:
    """Screen frames over a phase (capture.c)."""

    def __init__(self, env, path):
        self.path = path
        self.proc = subprocess.Popen([os.path.join(OUT, "capture"), path], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)
        if self.proc.stdout.readline().strip() != "ready":
            raise RuntimeError("capture failed to start")

    def stop(self, keep=None):
        self.proc.stdin.close()
        self.proc.wait()
        d = open(self.path, "rb").read()
        if keep:
            shutil.move(self.path, keep)
        else:
            os.unlink(self.path)
        w, h = struct.unpack("<II", d[4:12])
        n = (len(d) - 12) // (8 + w * h)
        rec = np.frombuffer(d[12:12 + n * (8 + w * h)], np.uint8).reshape(n, 8 + w * h)
        times = rec[:, :8].copy().view("<u8")[:, 0].astype(np.int64)
        return times, rec[:, 8:].reshape(n, h, w)


def analyze(times, frames, rect, t0, presents):
    """When rows appeared and when the screen stopped changing, from frames
    captured over a phase that started at t0 (the first frame is the state
    before). Rows: the first frame after t0 whose rows rectangle has at
    least half the dark (text) pixels of the final frame and at least half
    as many blocks changed from before as the final frame has (so the old
    folder with a moved cursor does not count). Complete: the first frame from which the rectangle stays equal to
    the final frame (fewer than 0.2% of its 4x4 blocks differ).

    A captured frame's time is when sway committed it; it reaches the
    screen at the next vblank, which is the presentation time presshim saw
    for the app's frame in it: each time becomes the app's first
    presentation at or after it (within a refresh)."""
    pres = np.array(sorted(tp for _, tp in presents), np.int64)

    def photon(t):
        i = np.searchsorted(pres, t)
        return int(pres[i]) if i < len(pres) and pres[i] - t < REFRESH_NS * 1.5 else int(t)

    x0, y0, x1, y1 = (v // 4 for v in rect)
    reg = frames[:, y0:y1, x0:x1].astype(np.int16)
    dark = (reg < 140).sum(axis=(1, 2))
    final = reg[-1]
    differs = (np.abs(reg - final) > 24).mean(axis=(1, 2)) >= 0.002
    changed = (np.abs(reg - reg[0]) > 24).mean(axis=(1, 2))
    after = times > t0
    rows = next((i for i in range(len(times)) if after[i] and changed[i] >= max(0.002, changed[-1] / 2) and dark[i] >= dark[-1] / 2), None)
    last_diff = max([i for i in range(len(times)) if differs[i]], default=0)
    complete = min(last_diff + 1, len(times) - 1)
    return {
        "rows_ms": (photon(times[rows]) - t0) / 1e6 if rows is not None else None,
        "complete_ms": (photon(max(times[complete], t0)) - t0) / 1e6,
        "frames_captured": int(after.sum()),
        "final_dark_blocks": int(dark[-1]),
    }


# Presentation log (presshim.so) ------------------------------------------------------


class Shim:
    def __init__(self, path):
        self.path = path
        self.pos = 0
        self.commits = {}  # seq -> (surface, t)
        self.presented = {}  # seq -> t
        self.xdg = {}
        self.toplevel_xdg = set()

    def poll(self):
        try:
            with open(self.path) as f:
                f.seek(self.pos)
                data = f.read()
        except FileNotFoundError:
            return
        end = data.rfind("\n") + 1
        self.pos += end
        for line in data[:end].splitlines():
            p = line.split()
            if p[0] == "C":
                self.commits[int(p[3])] = (int(p[1]), int(p[2]))
            elif p[0] == "P":
                self.presented[int(p[1])] = int(p[2])
            elif p[0] == "X":
                self.xdg[int(p[1])] = int(p[2])
            elif p[0] == "T":
                self.toplevel_xdg.add(int(p[1]))

    def main(self):
        return {self.xdg[x] for x in self.toplevel_xdg if x in self.xdg}

    def presents(self, t0=0, t1=1 << 63):
        main = self.main()
        out = [(self.commits[s][1], tp) for s, tp in self.presented.items()
               if s in self.commits and self.commits[s][0] in main and t0 <= tp <= t1]
        return sorted(out, key=lambda x: x[1])

    def first_present_after(self, t, timeout=2.0):
        deadline = time.monotonic() + timeout
        while True:
            self.poll()
            c = [(tc, tp) for tc, tp in self.presents() if tc >= t]
            if c:
                return min(c)[1]
            if time.monotonic() > deadline:
                return None
            time.sleep(0.003)

    def last_commit(self):
        return max((tc for _, tc in self.commits.values()), default=0)


# /proc ------------------------------------------------------------------------------


def children(pid):
    out, todo = [], [pid]
    while todo:
        p = todo.pop()
        for t in glob.glob(f"/proc/{p}/task/*/children"):
            try:
                kids = [int(k) for k in open(t).read().split()]
            except OSError:
                continue
            out += kids
            todo += kids
    return out


def tasks(pids):
    """CPU ns and context switches of each live thread of pids, by tid."""
    out = {}
    for pid in pids:
        for task in glob.glob(f"/proc/{pid}/task/*"):
            try:
                cpu = int(open(task + "/schedstat").read().split()[0])
                ctx = sum(int(l.split()[1]) for l in open(task + "/status") if "ctxt_switches" in l)
                out[task] = (cpu, ctx)
            except (OSError, IndexError):
                pass
    return out


def window(pid_groups, seconds):
    """CPU % and wakeups/s of each group of processes over an idle window;
    threads that exit keep their last sample."""
    a = {k: tasks(pids()) for k, pids in pid_groups.items()}
    seen = {k: {} for k in pid_groups}
    end = time.monotonic() + seconds
    t0 = now()
    while time.monotonic() < end:
        for k, pids in pid_groups.items():
            seen[k].update(tasks(pids()))
        time.sleep(0.25)
    dt = (now() - t0) / 1e9
    out = {}
    for k in pid_groups:
        b = {**seen[k], **tasks(pid_groups[k]())}
        cpu = sum(c - a[k].get(t, (0, 0))[0] for t, (c, _) in b.items())
        ctx = sum(x - a[k].get(t, (0, 0))[1] for t, (_, x) in b.items())
        busiest = sorted(((x - a[k].get(t, (0, 0))[1], t) for t, (_, x) in b.items()), reverse=True)[:3]
        out[k] = {"cpu_percent": 100 * cpu / 1e9 / dt, "wakeups_per_s": ctx / dt,
                  "busiest": [[comm(t), n / dt] for n, t in busiest if n > 0]}
    return out


def comm(task):
    try:
        return open(task + "/comm").read().strip()
    except OSError:
        return "?"


def cpu_ns(pid):
    return sum(c for c, _ in tasks([pid]).values())


def memory(pids):
    """RSS and PSS (KiB) summed over pids, and GPU memory of their DRM clients."""
    rss = pss = 0
    gpu = {}
    for pid in pids:
        try:
            rss += next(int(l.split()[1]) for l in open(f"/proc/{pid}/status") if l.startswith("VmRSS"))
            pss += next(int(l.split()[1]) for l in open(f"/proc/{pid}/smaps_rollup") if l.startswith("Pss:"))
        except (OSError, StopIteration):
            continue
        for fd in glob.glob(f"/proc/{pid}/fdinfo/*"):
            try:
                info = dict(l.split(":", 1) for l in open(fd) if ":" in l)
            except OSError:
                continue
            if "drm-client-id" in info:
                gpu[info["drm-client-id"].strip()] = sum(int(info[k].split()[0]) for k in ("drm-memory-vram", "drm-memory-gtt") if k in info)
    return {"rss_kib": rss, "pss_kib": pss, "gpu_kib": sum(gpu.values())}


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else None


# One run of one app -------------------------------------------------------------------


class Run:
    def __init__(self, app, args):
        self.name = app
        self.app = APPS[app]
        self.args = args
        self.result = {"app": app}
        self.s = Session(args.backend, args.user)
        self.inj = Injector(self.s.root_env)
        # The pointer rests where neither app shows a hover: below
        # Nautilus's sidebar items, in siv-columns's parent column under
        # its two entries.
        self.inj.send("move 120 780")
        self.fixtures = os.path.join(self.s.user.pw_dir, "fixtures")
        self.proc = None

    def capture(self):
        return Capture(self.s.root_env, os.path.join(self.s.dir, "capture.bin"))

    def settle(self, quiet=1.0, limit=15.0, since=0):
        """Waits until the app has neither committed nor used more than 5%
        of a core for `quiet` seconds (a busy UI thread commits nothing)."""
        end = time.monotonic() + limit
        hist = []
        while time.monotonic() < end:
            self.shim.poll()
            t = now()
            hist.append((t, cpu_ns(self.pid)))
            old = [c for tt, c in hist if tt <= t - quiet * 1e9]
            if old and t - max(self.shim.last_commit(), since) > quiet * 1e9 and hist[-1][1] - old[-1] < 0.05 * quiet * 1e9:
                return True
            time.sleep(0.05)
        return False

    def start(self, cold):
        """Starts the app on the small folder; returns startup measurements."""
        log = os.path.join(self.s.rt, f"presshim-{now()}.log")
        open(log, "w").close()
        os.chown(log, self.s.user.pw_uid, self.s.user.pw_gid)
        self.shim = Shim(log)
        if cold:
            subprocess.run(["sync"])
            with open("/proc/sys/vm/drop_caches", "w") as f:
                f.write("3\n")
            time.sleep(1.0)
        cap = self.capture()
        env = dict(self.s.env, LD_PRELOAD=self.s.presshim, PRESSHIM_LOG=log)
        self.app_log = open(os.path.join(self.s.dir, "app.log"), "a")
        t0 = now()
        self.proc = self.s.spawn(self.app["cmd"] + [os.path.join(self.fixtures, "small")], env=env,
                                 stdout=self.app_log, stderr=subprocess.STDOUT)
        self.pid = self.proc.pid
        first = None
        deadline = time.monotonic() + 30
        while first is None and time.monotonic() < deadline:
            self.shim.poll()
            p = self.shim.presents()
            first = p[0][1] if p else None
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} exited at startup")
            time.sleep(0.002)
        self.settle(1.0, 15)
        times, frames = cap.stop(self.keep("start-cold" if cold else "start-warm"))
        self.shim.poll()
        a = analyze(times, frames, self.app["rows"], t0, self.shim.presents())
        return {"first_frame_ms": (first - t0) / 1e6, "rows_ms": a["rows_ms"], "complete_ms": a["complete_ms"]}

    def quit(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        time.sleep(0.5)

    def app_pids(self):
        return [self.pid] + children(self.pid)

    def service_pids(self):
        mine = set(self.app_pids()) | {self.s.bus.pid}
        return [p for p in self.s.user_pids() if p not in mine]

    def mem(self):
        return {"app": memory([self.pid]), "app_tree": memory(self.app_pids()), "services": memory(self.service_pids())}

    def idle(self, seconds=10):
        return window({"app": self.app_pids, "services": self.service_pids}, seconds)

    def latency(self, cmd, count, gap):
        out = []
        for _ in range(count):
            t = self.inj.send(cmd)[0]
            tp = self.shim.first_present_after(t)
            if tp is not None:
                out.append((tp - t) / 1e6)
            time.sleep(gap)
        return out

    def burst(self, cmd):
        """Frame times, CPU per frame, and per-event latency over a burst of input."""
        c0 = cpu_ns(self.pid)
        t0 = now()
        ts = self.inj.send(cmd)
        t1 = now()
        c1 = cpu_ns(self.pid)
        time.sleep(0.3)
        self.shim.poll()
        pres = self.shim.presents(t0, t1 + 50_000_000)
        tp = [p for _, p in pres]
        iv = sorted((b - a) / 1e6 for a, b in zip(tp, tp[1:]))
        lat = []
        for t in ts:
            c = [p for tc, p in pres if tc >= t]
            if c:
                lat.append((min(c) - t) / 1e6)
        return {"frames": len(tp), "seconds": (t1 - t0) / 1e9, "interval_p50_ms": pct(iv, 0.5), "interval_p99_ms": pct(iv, 0.99),
                "interval_max_ms": iv[-1] if iv else None, "dropped": sum(max(0, round(d * 1e6 / REFRESH_NS) - 1) for d in iv),
                "cpu_ms_per_frame": (c1 - c0) / 1e6 / len(tp) if tp else None, "cpu_ms": (c1 - c0) / 1e6, "latency_ms": lat}

    def keep(self, name):
        if self.args.keep_captures and self.result["run"] == 0:
            return os.path.join(self.args.keep_captures, f"{self.name}-{name}.cap")

    def shot(self, name):
        if self.args.screenshots and self.result["run"] == 0:
            subprocess.run(["grim", os.path.join(self.args.screenshots, f"{self.name}-{name}.png")], env=self.s.root_env)

    def open_big(self, name):
        """Opens the 100 100-entry folder by typing its path."""
        for c in self.app["goto"](os.path.join(self.fixtures, "big")):
            self.inj.send(c)
        time.sleep(0.5)
        self.settle(0.5, 5)
        cap = self.capture()
        c0 = cpu_ns(self.pid)
        t0 = self.inj.send("key Return")[0]
        self.settle(2.0, 90, since=t0)
        c1 = cpu_ns(self.pid)
        times, frames = cap.stop(self.keep(name))
        self.shim.poll()
        out = analyze(times, frames, self.app["rows"], t0, self.shim.presents())
        out["cpu_ms"] = (c1 - c0) / 1e6
        return out

    def run(self):
        r = self.result
        # Cold: the page cache dropped before the start, so the program, its
        # libraries, and the folder's metadata come from the disk.
        r["cold"] = self.start(cold=True)
        r["open_big_cold"] = self.open_big("big-cold")
        self.quit()
        r["warm"] = self.start(cold=False)
        self.shot("start")
        r["renderer"] = "vulkan" if any("libvulkan_radeon" in l for l in open(f"/proc/{self.pid}/maps")) else "other"
        r["memory_start"] = self.mem()
        r["idle_start"] = self.idle()
        r["services"] = sorted({open(f"/proc/{p}/comm").read().strip() for p in self.service_pids()})

        # Warm: every entry's metadata in the kernel's caches.
        big = os.path.join(self.fixtures, "big")
        for e in os.scandir(big):
            e.stat(follow_symlinks=False)
        r["open_big"] = self.open_big("big-warm")
        self.shot("big")
        r["memory_big"] = self.mem()
        r["idle_big"] = self.idle()

        # Keys and scrolling in it.
        r["down_ms"] = self.latency("key Down", 20, 0.25)
        self.settle(0.5)
        r["down_held"] = self.burst("keyburst 33 60 Down")
        self.settle(0.5)
        r["page_down_ms"] = self.latency("key Page_Down", 10, 0.3)
        end, home = [], []
        for _ in range(5):
            end += self.latency("key End", 1, 0.4)
            home += self.latency("key Home", 1, 0.4)
        r["end_ms"], r["home_ms"] = end, home
        self.inj.send("move %d %d" % self.app["pointer"])
        time.sleep(0.3)
        self.settle(0.5)
        r["scroll"] = self.burst("scrollburst 30 120 600")
        self.settle(1.0)
        self.shot("scrolled")
        r["wheel_ms"] = self.latency("wheel 1", 15, 0.25)
        self.inj.send("key Home")
        self.settle(1.0)

        # A filter typed: "12345" matches one name.
        for c in self.app["filter"]:
            self.inj.send(c)
        time.sleep(0.3)
        self.settle(0.5)
        cap = self.capture()
        c0 = cpu_ns(self.pid)
        ts = self.inj.send("typeburst 150 12345")
        self.settle(2.0, 30, since=ts[-1])
        c1 = cpu_ns(self.pid)
        times, frames = cap.stop(self.keep("filter"))
        self.shim.poll()
        pres = self.shim.presents(ts[0])
        r["filter_key_ms"] = [(min(p for tc, p in pres if tc >= t) - t) / 1e6 for t in ts if any(tc >= t for tc, _ in pres)]
        r["filter"] = analyze(times, frames, self.app["rows"], ts[-1], pres)
        r["filter"]["cpu_ms"] = (c1 - c0) / 1e6
        self.shot("filter")
        r["memory_end"] = self.mem()

    def finish(self):
        if self.proc and self.proc.poll() is None:
            self.quit()
        self.inj.stop()
        self.app_log.close()
        self.result["app_log"] = open(os.path.join(self.s.dir, "app.log")).read()[-3000:]
        self.s.stop()
        return self.result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--apps", default="columns,nautilus")
    ap.add_argument("--out", default=os.path.join(HERE, "raw"))
    ap.add_argument("--backend", default="drm")
    ap.add_argument("--user", default="fmbench")
    ap.add_argument("--screenshots", default=None, help="directory for screenshots of the first run")
    ap.add_argument("--keep-captures", default=None, help="directory for the screen captures of the first run")
    args = ap.parse_args()
    for d in (args.screenshots, args.keep_captures):
        if d:
            os.makedirs(d, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)
    for run in range(args.runs):
        for app in args.apps.split(","):
            r = Run(app, args)
            r.result["run"] = run
            try:
                r.run()
            except Exception as e:
                r.result["error"] = repr(e)
            finally:
                res = r.finish()
            res["loadavg"] = os.getloadavg()
            with open(os.path.join(args.out, f"{app}-{run}.json"), "w") as f:
                json.dump(res, f, indent=1)
            print(f"{app:9} run {run}: cold rows {res.get('cold', {}).get('rows_ms')}, big {res.get('open_big', {}).get('complete_ms')}"
                  f" {res.get('error', '')}", file=sys.stderr)


if __name__ == "__main__":
    main()
