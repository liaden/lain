//! `--private-net`, run for real: refused on a netns with a host interface,
//! and inside `bwrap --unshare-net` TCP works on lo while seccomp still
//! refuses datagrams and nothing routes out.
#![cfg(target_os = "linux")]

pub mod common;

use common::{FENCE, refused_with, skipped, text};
use std::fs;
use std::process::{Command, Output};

const GRANTS: [&str; 4] = ["--read-dir", "/", "--exec-dir", "/usr"];
const EACCES: &str = "13";
const EPERM: &str = "1";
const ENETUNREACH: &str = "101";

/// Exit 3 marks a refusal; the errno follows "refused".
const PROBE: &str = r#"
import socket, sys

def tcp_loopback():
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    client = socket.create_connection(server.getsockname(), timeout=5)
    peer, _ = server.accept()
    client.sendall(b"hi")
    return peer.recv(2) == b"hi"

def udp():
    socket.socket(socket.AF_INET, socket.SOCK_DGRAM).close()

def outside():
    socket.create_connection(("192.0.2.1", 443), timeout=5)

try:
    {"tcp_loopback": tcp_loopback, "udp": udp, "outside": outside}[sys.argv[1]]()
except OSError as e:
    print("refused", e.errno)
    sys.exit(3)
print("ok")
"#;

/// Decided from the kernel and bwrap, never from the fence under test.
fn cannot_run(what: &str) -> bool {
    if common::cannot_run(what) {
        return true;
    }
    let bwrap = Command::new("bwrap")
        .args(bwrap_prefix())
        .arg("true")
        .output();
    match bwrap {
        Ok(out) if out.status.success() => false,
        Ok(out) => skipped(what, &format!("bwrap --unshare-net failed: {out:?}")),
        Err(error) => skipped(what, &format!("bwrap is not runnable: {error}")),
    }
}

fn bwrap_prefix() -> [&'static str; 8] {
    [
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--unshare-net",
    ]
}

fn fenced_in_private_netns(fence_flags: &[&str], kind: &str) -> Output {
    Command::new("bwrap")
        .args(bwrap_prefix())
        .arg("--")
        .arg(FENCE)
        .args(fence_flags)
        .args(GRANTS)
        .args(["--", "python3", "-I", "-c", PROBE, kind])
        .env("LC_ALL", "C")
        .output()
        .expect("spawn bwrap")
}

fn private(kind: &str) -> Output {
    fenced_in_private_netns(&["--private-net"], kind)
}

fn host_has_only_lo() -> bool {
    let dev = fs::read_to_string("/proc/self/net/dev").unwrap_or_default();
    dev.lines()
        .skip(2)
        .filter_map(|line| line.split_once(':'))
        .all(|(name, _)| name.trim() == "lo")
}

#[test]
fn the_flag_on_a_netns_with_a_host_interface_exits_125() {
    if host_has_only_lo() {
        skipped(
            "private net on the host netns",
            "this test already runs in a lo-only netns",
        );
        return;
    }

    let out = Command::new(FENCE)
        .args(["--private-net", "--exec-dir", "/usr", "--", "true"])
        .output()
        .expect("spawn fence");

    assert_eq!(out.status.code(), Some(125), "{out:?}");
    let stderr = text(&out.stderr);
    assert!(stderr.starts_with("lain-fence: --private-net: "), "{out:?}");
    assert!(stderr.contains("not only lo"), "{out:?}");
}

#[test]
fn the_flag_on_the_host_netns_refuses_status_too() {
    if host_has_only_lo() {
        skipped(
            "private net status on the host netns",
            "this test already runs in a lo-only netns",
        );
        return;
    }

    let out = Command::new(FENCE)
        .args(["--status", "--private-net", "--exec-dir", "/usr"])
        .output()
        .expect("spawn fence");

    assert_eq!(out.status.code(), Some(125), "{out:?}");
    assert_eq!(text(&out.stdout), "", "{out:?}");
    assert!(text(&out.stderr).contains("not only lo"), "{out:?}");
}

#[test]
fn tcp_bind_and_connect_on_lo_work_in_a_private_netns() {
    if cannot_run("tcp on lo in a private netns") {
        return;
    }

    let out = private("tcp_loopback");

    assert_eq!(text(&out.stdout), "ok\n", "{out:?}");
    assert!(out.status.success(), "{out:?}");
}

#[test]
fn a_udp_socket_is_still_refused_in_a_private_netns() {
    if cannot_run("udp in a private netns") {
        return;
    }

    let out = private("udp");

    assert_eq!(refused_with(&out).as_deref(), Some(EPERM), "{out:?}");
}

#[test]
fn nothing_outside_is_reachable_from_a_private_netns() {
    if cannot_run("outside connect in a private netns") {
        return;
    }

    let out = private("outside");

    assert_eq!(refused_with(&out).as_deref(), Some(ENETUNREACH), "{out:?}");
}

#[test]
fn without_the_flag_tcp_on_lo_is_still_refused_in_a_private_netns() {
    if cannot_run("tcp without the flag in a private netns") {
        return;
    }

    let out = fenced_in_private_netns(&[], "tcp_loopback");

    assert_eq!(refused_with(&out).as_deref(), Some(EACCES), "{out:?}");
}

#[test]
fn status_says_whether_the_private_net_is_in_force() {
    if cannot_run("private net status") {
        return;
    }
    let shared = Command::new(FENCE)
        .args(["--status", "--exec-dir", "/usr"])
        .output()
        .expect("spawn fence");
    let private = Command::new("bwrap")
        .args(bwrap_prefix())
        .args([
            "--",
            FENCE,
            "--status",
            "--private-net",
            "--exec-dir",
            "/usr",
        ])
        .output()
        .expect("spawn bwrap");
    let parse = |out: &Output| -> serde_json::Value {
        assert!(out.status.success(), "{out:?}");
        serde_json::from_slice(&out.stdout).expect("status is JSON")
    };
    let (shared, private) = (parse(&shared), parse(&private));

    assert_eq!(shared["private_net"], serde_json::json!(false), "{shared}");
    assert_eq!(private["private_net"], serde_json::json!(true), "{private}");
    for right in ["connect_tcp", "bind_tcp"] {
        assert!(shared["rights"].get(right).is_some(), "{shared}");
        assert!(private["rights"].get(right).is_none(), "{private}");
    }
    assert_eq!(private["rights"]["inet_socket_types"], "enforced");
}

#[test]
fn the_flag_takes_no_connect_port() {
    let out = Command::new(FENCE)
        .args(["--private-net", "--connect-port", "443", "--", "true"])
        .output()
        .expect("spawn fence");

    assert_eq!(out.status.code(), Some(125), "{out:?}");
    assert!(text(&out.stderr).contains("--connect-port"), "{out:?}");
}
