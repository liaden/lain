use std::fs;
use std::io::Write;
use std::process::{Command, Output};

pub const FENCE: &str = env!("CARGO_BIN_EXE_lain-fence");

pub fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// Written past cargo's capture, so a skip shows in every run.
pub fn skipped(what: &str, reason: &str) -> bool {
    let _ = writeln!(std::io::stderr(), "SKIPPED {what}: {reason}");
    true
}

/// Decided from the kernel, never from the fence, so a broken fence cannot
/// skip its own tests.
pub fn cannot_run(what: &str) -> bool {
    let lsm = fs::read_to_string("/sys/kernel/security/lsm").unwrap_or_default();
    if !lsm.trim().split(',').any(|name| name == "landlock") {
        return skipped(
            what,
            "Landlock is not an active LSM, so the fence refuses to run anything",
        );
    }
    if Command::new("python3").arg("-c").arg("1").output().is_err() {
        return skipped(what, "python3 is not on PATH");
    }
    false
}

pub fn refused_with(out: &Output) -> Option<String> {
    text(&out.stdout)
        .strip_prefix("refused ")
        .map(|errno| errno.trim().to_string())
}

pub fn fence(args: &[&str]) -> Output {
    Command::new(FENCE)
        .args(args)
        .env("LC_ALL", "C")
        .output()
        .expect("spawn fence")
}

pub fn status(args: &[&str]) -> serde_json::Value {
    let out = fence(args);
    assert!(out.status.success(), "fence {args:?} failed: {out:?}");
    let text = String::from_utf8(out.stdout).expect("utf-8 status");
    assert_eq!(text.lines().count(), 1, "one status line, got {text:?}");
    serde_json::from_str(&text).expect("status is JSON")
}
