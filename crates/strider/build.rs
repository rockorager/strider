//! `strider --version` says what `git describe` does of the commit built, less the tag's
//! `v`: `0.3.0` on a release's tag, `0.3.0-17-g276df80` 17 commits after it. A build `just
//! release` makes (STRIDER_RELEASE set, as its commit is tagged only once it is built), or
//! one without git or outside a checkout, says the workspace's version.

use std::path::Path;
use std::process::Command;

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

fn main() {
    println!("cargo::rerun-if-env-changed=STRIDER_RELEASE");
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let version = env!("CARGO_PKG_VERSION");
    // A commit or a tag that moves builds again. A worktree has its own HEAD, and shares
    // the refs with the repository's.
    let dirs = (
        git(dir, &["rev-parse", "--absolute-git-dir"]),
        git(
            dir,
            &["rev-parse", "--path-format=absolute", "--git-common-dir"],
        ),
    );
    if let (Some(git_dir), Some(common)) = dirs {
        let (git_dir, common) = (Path::new(&git_dir), Path::new(&common));
        for path in [
            git_dir.join("HEAD"),
            common.join("packed-refs"),
            common.join("refs/tags"),
        ] {
            println!("cargo::rerun-if-changed={}", path.display());
        }
        if let Some(head) = git(dir, &["symbolic-ref", "-q", "HEAD"]) {
            println!("cargo::rerun-if-changed={}", common.join(head).display());
        }
    }
    let described = match std::env::var_os("STRIDER_RELEASE") {
        Some(_) => None,
        None => git(dir, &["describe", "--tags", "--match", "v[0-9]*"]),
    };
    let version = described
        .as_deref()
        .and_then(|d| d.strip_prefix('v'))
        .unwrap_or(version);
    println!("cargo::rustc-env=STRIDER_VERSION={version}");
}
