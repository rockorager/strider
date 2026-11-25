//! `strider --version` says which commit a build is of, unless it is a release: a build of
//! the commit tagged with its version, or one `just release` makes (STRIDER_RELEASE set, as
//! its commit is tagged only once it is built). Without git, or outside a checkout, the
//! version stands alone.

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
    // A commit or a tag that moves builds again.
    if let Some(git_dir) = git(dir, &["rev-parse", "--absolute-git-dir"]) {
        let git_dir = Path::new(&git_dir);
        println!("cargo::rerun-if-changed={}", git_dir.join("HEAD").display());
        println!(
            "cargo::rerun-if-changed={}",
            git_dir.join("packed-refs").display()
        );
        println!(
            "cargo::rerun-if-changed={}",
            git_dir.join("refs/tags").display()
        );
        if let Some(head) = git(dir, &["symbolic-ref", "-q", "HEAD"]) {
            println!("cargo::rerun-if-changed={}", git_dir.join(head).display());
        }
    }
    let release = std::env::var_os("STRIDER_RELEASE").is_some()
        || git(dir, &["tag", "--points-at", "HEAD"])
            .is_some_and(|tags| tags.lines().any(|t| t == format!("v{version}")));
    let suffix = match git(dir, &["rev-parse", "--short=7", "HEAD"]) {
        Some(hash) if !release => format!("-dev+{hash}"),
        _ => String::new(),
    };
    println!("cargo::rustc-env=STRIDER_VERSION={version}{suffix}");
}
