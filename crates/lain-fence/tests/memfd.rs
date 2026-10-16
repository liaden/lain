//! The fence's seccomp filter against memfd exec, run for real on this kernel.
//!
//! The fenced command is python3, the interpreter the memfd probe was written
//! in, because its `os.memfd_create` passes the flags straight to the kernel
//! and its ctypes can make the raw x32 call.

use std::fs;
use std::io::Write;
use std::process::{Command, Output};

const FENCE: &str = env!("CARGO_BIN_EXE_lain-fence");

const MFD_CLOEXEC: u32 = 0x1;
const MFD_NOEXEC_SEAL: u32 = 0x8;
const EPERM: &str = "1";
const EINVAL: &str = "22";
const ENOSYS: &str = "38";

/// Exit 3 marks a refusal at memfd_create itself, not at the exec after it.
const PROBE: &str = r#"
import ctypes, os, sys
flags, route, then = int(sys.argv[1]), sys.argv[2], sys.argv[3]
if route == "x32":
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    fd = libc.syscall(ctypes.c_long(319 | 0x40000000), b"probe", ctypes.c_ulong(flags))
    err = ctypes.get_errno() if fd < 0 else 0
else:
    try:
        fd, err = os.memfd_create("probe", flags), 0
    except OSError as e:
        fd, err = -1, e.errno
if fd < 0:
    print("refused", err)
    sys.exit(3)
print("created")
sys.stdout.flush()
if then == "exec":
    with open("/usr/bin/true", "rb") as elf:
        os.write(fd, elf.read())
    os.execve(fd, ["true"], {})
"#;

const GRANTS: [&str; 7] = [
    "--exec-dir",
    "/usr",
    "--read-dir",
    "/usr",
    "--write-dir",
    "/dev/null",
    "--",
];

fn probe(fenced: bool, flags: u32, route: &str, then: &str) -> Output {
    let flags = flags.to_string();
    let python = ["python3", "-I", "-c", PROBE, &flags, route, then];
    let mut command = if fenced {
        let mut command = Command::new(FENCE);
        command.args(GRANTS).args(python);
        command
    } else {
        let mut command = Command::new(python[0]);
        command.args(&python[1..]);
        command
    };
    command.env("LC_ALL", "C").output().expect("spawn probe")
}

fn refused_with(out: &Output) -> Option<String> {
    text(&out.stdout)
        .strip_prefix("refused ")
        .map(|errno| errno.trim().to_string())
}

fn status() -> serde_json::Value {
    let out = Command::new(FENCE)
        .args(["--status", "--exec-dir", "/usr"])
        .output()
        .expect("spawn fence");
    assert!(out.status.success(), "fence --status failed: {out:?}");
    serde_json::from_slice(&out.stdout).expect("status is JSON")
}

/// Decided from the kernel, never from the fence, so a broken fence cannot
/// skip its own tests.
fn cannot_run(what: &str) -> bool {
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

/// Written past cargo's capture so a skip always shows.
fn skipped(what: &str, reason: &str) -> bool {
    let _ = writeln!(std::io::stderr(), "SKIPPED {what}: {reason}");
    true
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn memfd_exec_is_refused_at_memfd_create() {
    if cannot_run("memfd exec") {
        return;
    }

    let out = probe(true, MFD_CLOEXEC, "native", "exec");

    assert_eq!(refused_with(&out).as_deref(), Some(EPERM), "{out:?}");
    assert_eq!(out.status.code(), Some(3), "{out:?}");
}

#[cfg(target_arch = "x86_64")]
#[test]
fn memfd_exec_through_the_x32_abi_is_refused_too() {
    if cannot_run("x32 memfd exec") {
        return;
    }
    if refused_with(&probe(false, MFD_CLOEXEC, "x32", "stop")).as_deref() == Some(ENOSYS) {
        skipped("x32 memfd exec", "this kernel has no x32 ABI");
        return;
    }

    let out = probe(true, MFD_CLOEXEC, "x32", "exec");

    assert_eq!(refused_with(&out).as_deref(), Some(EPERM), "{out:?}");
    assert_eq!(out.status.code(), Some(3), "{out:?}");
}

#[test]
fn a_noexec_sealed_memfd_is_still_created() {
    if cannot_run("sealed memfd") {
        return;
    }
    let unfenced = probe(false, MFD_CLOEXEC | MFD_NOEXEC_SEAL, "native", "stop");
    if refused_with(&unfenced).as_deref() == Some(EINVAL) {
        skipped(
            "sealed memfd",
            "this kernel has no MFD_NOEXEC_SEAL (before 6.3)",
        );
        return;
    }

    let out = probe(true, MFD_CLOEXEC | MFD_NOEXEC_SEAL, "native", "stop");

    assert_eq!(text(&out.stdout), "created\n", "{out:?}");
    assert!(out.status.success(), "{out:?}");
}

#[test]
fn status_reports_the_memfd_filter() {
    let report = status();

    let verdict = &report["rights"]["memfd_noexec"];
    assert!(
        verdict == "enforced" || verdict == "dropped",
        "memfd_noexec: {verdict}, in {report}"
    );
}

#[test]
fn status_reads_enforced_when_the_refusal_is_seen() {
    if cannot_run("enforced verdict") {
        return;
    }
    let out = probe(true, MFD_CLOEXEC, "native", "stop");
    if refused_with(&out).as_deref() != Some(EPERM) {
        skipped("enforced verdict", "the filter did not refuse here");
        return;
    }

    assert_eq!(status()["rights"]["memfd_noexec"], "enforced");
}
