//! Running other programs from workers and waiting for them, as previews do: bsdtar for
//! archive listings, and the renderers of PDF pages and video frames. A program that is
//! cancelled or runs too long is killed with every process it started.

use std::ffi::OsStr;
use std::io::{self, Read};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::process::{Pid, Signal, kill_process, kill_process_group};

pub struct Output {
    /// The exit status, or 128 plus the signal, or 127 if it could not run.
    pub status: u8,
    /// Standard output and error, at most the limit asked for.
    pub output: Vec<u8>,
    /// More output was cut off, or the program was stopped.
    pub truncated: bool,
}

pub struct Options<'a> {
    /// Keep at most this much output; the rest is read and dropped.
    pub max_output: usize,
    /// Stop reading, and end the program, after this much output.
    pub kill_after: Option<usize>,
    /// Set from another thread to stop: the program and every process it started are
    /// killed, as it runs in a process group of its own.
    pub cancel: Option<&'a AtomicBool>,
    /// Killed the same way after this long.
    pub timeout: Option<Duration>,
}

/// Runs `argv`, searched on `$PATH`, to completion with standard input from /dev/null,
/// collecting what it writes. Blocking.
pub fn run(argv: &[&OsStr], opts: &Options<'_>) -> io::Result<Output> {
    let (program, args) = argv.split_first().ok_or(io::ErrorKind::InvalidInput)?;
    let (mut reader, writer) = io::pipe()?;
    let watched = opts.cancel.is_some() || opts.timeout.is_some();
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(writer.try_clone()?)
        .stderr(writer);
    if watched {
        cmd.process_group(0);
    }
    let spawned = cmd.spawn();
    // The command holds the pipe's writing end, which would keep the read from ending.
    drop(cmd);
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(Output {
                status: 127,
                output: Vec::new(),
                truncated: false,
            });
        }
        Err(e) => return Err(e),
    };
    let pid = Pid::from_child(&child);
    let deadline = opts.timeout.map(|t| Instant::now() + t);
    let (mut out, mut truncated, mut total) = (Vec::new(), false, 0);
    let mut buf = [0u8; 16 * 1024];
    loop {
        if watched {
            // Wake now and then to see whether to stop.
            let mut fds = [PollFd::new(&reader, PollFlags::IN)];
            let tick = Timespec {
                tv_sec: 0,
                tv_nsec: 100_000_000,
            };
            let ready = poll(&mut fds, Some(&tick));
            let stop = opts.cancel.is_some_and(|c| c.load(Ordering::Acquire))
                || deadline.is_some_and(|d| Instant::now() >= d);
            if stop {
                let _ = kill_process_group(pid, Signal::KILL);
                truncated = true;
                break;
            }
            if matches!(ready, Ok(0) | Err(rustix::io::Errno::INTR)) {
                continue;
            }
        }
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        total += n;
        let room = opts.max_output.saturating_sub(out.len());
        truncated |= n > room;
        out.extend_from_slice(&buf[..n.min(room)]);
        if opts.kill_after.is_some_and(|k| total >= k) {
            let _ = kill_process(pid, Signal::TERM);
            truncated = true;
            break;
        }
    }
    drop(reader);
    let status = child.wait()?;
    let status = match (status.code(), status.signal()) {
        (Some(code), _) => code as u8,
        (None, Some(sig)) => 128 + sig as u8,
        (None, None) => 127,
    };
    Ok(Output {
        status,
        output: out,
        truncated,
    })
}

/// Whether `prog` is an executable on `$PATH`, or at that path when it names one.
pub fn on_path(prog: &str) -> bool {
    let executable = |p: &Path| rustix::fs::access(p, rustix::fs::Access::EXEC_OK).is_ok();
    if prog.contains('/') {
        return executable(Path::new(prog));
    }
    let path = std::env::var_os("PATH").unwrap_or_else(|| "/usr/bin:/bin".into());
    std::env::split_paths(&path)
        .any(|dir| !dir.as_os_str().is_empty() && executable(&dir.join(prog)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sh(script: &str, opts: &Options<'_>) -> Output {
        run(&["sh".as_ref(), "-c".as_ref(), script.as_ref()], opts).unwrap()
    }

    const PLAIN: Options<'static> = Options {
        max_output: 64 * 1024,
        kill_after: None,
        cancel: None,
        timeout: None,
    };

    // A preview that moves on must not wait for its renderer: cancelling or timing out
    // kills the program and what it started, which would otherwise hold the pipe open.
    #[test]
    fn a_cancelled_or_timed_out_program_is_killed_with_what_it_started() {
        let t0 = Instant::now();
        let cancel = AtomicBool::new(true);
        let r = sh(
            "sleep 30 & sleep 30",
            &Options {
                cancel: Some(&cancel),
                ..PLAIN
            },
        );
        assert_eq!(r.status, 128 + 9);
        let r = sh(
            "sleep 30",
            &Options {
                timeout: Some(Duration::from_millis(200)),
                ..PLAIN
            },
        );
        assert_eq!(r.status, 128 + 9);
        assert!(t0.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn collects_output_and_status() {
        let r = sh("echo hi; echo err >&2; exit 3", &PLAIN);
        assert_eq!(r.status, 3);
        assert_eq!(r.output, b"hi\nerr\n");
        let missing = run(&["/nonexistent/program".as_ref()], &PLAIN).unwrap();
        assert_eq!(missing.status, 127);
    }
}
