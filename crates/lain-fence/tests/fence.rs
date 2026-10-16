//! The fence binary, run for real against this kernel's Landlock.
//!
//! Whether to skip is decided from the kernel, never from the fence: asking
//! the binary under test would let a broken `--status` skip every enforcement
//! test and read as green.

use std::fs;
use std::io::Write;
use std::net::TcpListener;
use std::os::linux::net::SocketAddrExt;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{SocketAddr, UnixListener};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const FENCE: &str = env!("CARGO_BIN_EXE_lain-fence");

fn fence(args: &[&str]) -> Output {
    Command::new(FENCE)
        .args(args)
        .env("LC_ALL", "C")
        .output()
        .expect("spawn fence")
}

fn status(args: &[&str]) -> serde_json::Value {
    let out = fence(args);
    assert!(out.status.success(), "fence {args:?} failed: {out:?}");
    let text = String::from_utf8(out.stdout).expect("utf-8 status");
    assert_eq!(text.lines().count(), 1, "one status line, got {text:?}");
    serde_json::from_str(&text).expect("status is JSON")
}

/// The first kernel release of each Landlock ABI, from landlock(7).
const ABI_RELEASES: [(u64, (u64, u64)); 9] = [
    (1, (5, 13)),
    (2, (5, 19)),
    (3, (6, 2)),
    (4, (6, 7)),
    (5, (6, 10)),
    (6, (6, 12)),
    (7, (6, 15)),
    (8, (7, 0)),
    (9, (7, 1)),
];

fn kernel_abi() -> Result<u64, String> {
    let lsm = fs::read_to_string("/sys/kernel/security/lsm").unwrap_or_default();
    if !lsm.trim().split(',').any(|name| name == "landlock") {
        return Err(format!("Landlock is not an active LSM ({:?})", lsm.trim()));
    }
    let release = fs::read_to_string("/proc/sys/kernel/osrelease").expect("osrelease");
    let mut numbers = release
        .split(|c: char| !c.is_ascii_digit())
        .map(|n| n.parse::<u64>().unwrap_or(0));
    let version = (numbers.next().unwrap_or(0), numbers.next().unwrap_or(0));
    let abi = ABI_RELEASES
        .iter()
        .filter(|(_, first)| version >= *first)
        .map(|(abi, _)| *abi)
        .max();
    Ok(abi.unwrap_or(0))
}

/// Written past cargo's capture, which only intercepts the print macros, so a
/// skip shows in every run and never passes in silence.
fn too_old_for(min: u64, what: &str) -> bool {
    let reason = match kernel_abi() {
        Ok(abi) if abi >= min => return false,
        Ok(abi) => format!("needs Landlock ABI {min}, this kernel release offers {abi}"),
        Err(reason) => reason,
    };
    let _ = writeln!(std::io::stderr(), "SKIPPED {what}: {reason}");
    true
}

fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write script");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).expect("chmod");
    path
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn exec_is_limited_to_the_granted_dirs_and_files() {
    if too_old_for(4, "exec limits") {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let granted = script(dir.path(), "granted", "echo granted-ran");
    let other = script(dir.path(), "other", "echo other-ran");
    let (granted, other) = (granted.to_str().unwrap(), other.to_str().unwrap());

    let out = fence(&[
        "--exec-dir",
        "/usr",
        "--exec-file",
        granted,
        "--",
        "sh",
        "-c",
        "\"$1\"; \"$2\"",
        "sh",
        granted,
        other,
    ]);

    assert_eq!(text(&out.stdout), "granted-ran\n");
    assert!(text(&out.stderr).contains("Permission denied"), "{out:?}");
    assert!(!out.status.success());
}

#[test]
fn reads_are_limited_to_the_granted_dirs() {
    if too_old_for(4, "read limits") {
        return;
    }
    let project = tempfile::tempdir().expect("tempdir");
    let outside = tempfile::tempdir().expect("tempdir");
    let readme = project.path().join("README.md");
    let known_hosts = outside.path().join("known_hosts");
    fs::write(&readme, "inside\n").unwrap();
    fs::write(&known_hosts, "secret\n").unwrap();
    let project_dir = project.path().to_str().unwrap();
    let grants = [
        "--exec-dir",
        "/usr",
        "--read-dir",
        "/usr",
        "--read-dir",
        project_dir,
        "--write-dir",
        "/dev/null",
        "--",
    ];

    let outside_read = fence(&[&grants[..], &["cat", known_hosts.to_str().unwrap()]].concat());
    let inside_read = fence(&[&grants[..], &["cat", readme.to_str().unwrap()]].concat());

    assert!(!outside_read.status.success());
    assert!(
        text(&outside_read.stderr).contains("Permission denied"),
        "{outside_read:?}"
    );
    assert_eq!(text(&outside_read.stdout), "");
    assert_eq!(text(&inside_read.stdout), "inside\n");
}

#[test]
fn writes_are_limited_to_the_granted_dirs() {
    if too_old_for(4, "write limits") {
        return;
    }
    let project = tempfile::tempdir().expect("tempdir");
    let project_dir = project.path().to_str().unwrap();
    let target = project.path().join("new");

    let out = fence(&[
        "--exec-dir",
        "/usr",
        "--read-dir",
        project_dir,
        "--write-dir",
        "/dev/null",
        "--",
        "sh",
        "-c",
        "echo quiet > /dev/null && echo x > \"$1\"",
        "sh",
        target.to_str().unwrap(),
    ]);

    assert!(!out.status.success());
    assert!(text(&out.stderr).contains("Permission denied"), "{out:?}");
    assert!(!target.exists());
}

#[test]
fn tcp_connect_is_limited_by_port() {
    if too_old_for(4, "TCP port rules") {
        return;
    }
    let allowed = TcpListener::bind("127.0.0.1:0").expect("bind");
    let refused = TcpListener::bind("127.0.0.1:0").expect("bind");
    let allowed_port = allowed.local_addr().unwrap().port().to_string();
    let refused_port = refused.local_addr().unwrap().port().to_string();
    let connect = |port: &str| {
        fence(&[
            "--exec-dir",
            "/usr",
            "--connect-port",
            &allowed_port,
            "--",
            "bash",
            "-c",
            "echo hi > \"/dev/tcp/127.0.0.1/$1\"",
            "bash",
            port,
        ])
    };

    let through = connect(&allowed_port);
    let blocked = connect(&refused_port);
    let bound = fence(&[
        "--exec-dir",
        "/usr",
        "--read-dir",
        "/usr",
        "--connect-port",
        &allowed_port,
        "--",
        "python3",
        "-c",
        "import socket, sys; socket.socket().bind(('127.0.0.1', int(sys.argv[1])))",
        &allowed_port,
    ]);

    assert!(through.status.success(), "{through:?}");
    assert!(!bound.status.success());
    assert!(text(&bound.stderr).contains("PermissionError"), "{bound:?}");
    assert!(!blocked.status.success());
    assert!(
        text(&blocked.stderr).contains("Permission denied"),
        "{blocked:?}"
    );
}

#[test]
fn status_names_the_abi_and_each_requested_right() {
    let report = status(&["--status", "--exec-dir", "/usr", "--connect-port", "443"]);

    let abi = report["abi"].as_u64().expect("abi");
    let rights = report["rights"].as_object().expect("rights map");
    for right in [
        "execute",
        "read_file",
        "write_file",
        "connect_tcp",
        "abstract_unix_socket",
        "signal",
    ] {
        let verdict = rights.get(right).and_then(|v| v.as_str());
        assert!(
            matches!(verdict, Some("enforced" | "dropped")),
            "{right}: {verdict:?} in {report}"
        );
    }
    let expected = kernel_abi().unwrap_or(0);
    assert!(abi >= expected, "abi {abi}, kernel release says {expected}");
    if expected >= 9 {
        assert!(rights.values().all(|v| v == "enforced"), "{report}");
    }
}

#[test]
fn status_names_tcp_connect_and_bind_even_with_no_port_granted() {
    let report = status(&["--status", "--exec-dir", "/usr"]);

    for right in ["connect_tcp", "bind_tcp"] {
        assert!(report["rights"].get(right).is_some(), "{right} in {report}");
    }
}

#[test]
fn status_fd_gets_the_line_before_exec_and_the_command_cannot_reach_it() {
    if too_old_for(1, "the status fd") {
        return;
    }
    let out = Command::new("sh")
        .args(["-c", "exec \"$@\" 3>&1 1>/dev/null", "sh", FENCE])
        .args(["--status-fd", "3", "--exec-dir", "/usr", "--"])
        .args(["sh", "-c", "echo ran >&2; echo leaked >&3"])
        .env("LC_ALL", "C")
        .output()
        .expect("spawn sh");

    let line = text(&out.stdout);
    assert_eq!(line.lines().count(), 1, "{out:?}");
    let report: serde_json::Value = serde_json::from_str(&line).expect("JSON");
    assert!(report["abi"].is_u64(), "{report}");
    assert!(text(&out.stderr).contains("ran"), "{out:?}");
    assert!(!line.contains("leaked"));
}

#[test]
fn a_signal_cannot_leave_the_sandbox() {
    if too_old_for(6, "signal scoping") {
        return;
    }
    let mut outsider = Command::new("sleep")
        .arg("30")
        .spawn()
        .expect("spawn sleep");
    let pid = outsider.id().to_string();

    let out = fence(&[
        "--exec-dir",
        "/usr",
        "--",
        "sh",
        "-c",
        "kill -0 $$ && echo self-ok; kill -0 \"$1\"",
        "sh",
        &pid,
    ]);
    outsider.kill().expect("kill sleep");
    outsider.wait().expect("reap sleep");

    assert_eq!(text(&out.stdout), "self-ok\n");
    assert!(!out.status.success(), "{out:?}");
}

#[test]
fn an_abstract_socket_outside_cannot_be_reached() {
    if too_old_for(6, "abstract socket scoping") {
        return;
    }
    let name = format!("lain-fence-test-{}", std::process::id());
    let _listener = UnixListener::bind_addr(&SocketAddr::from_abstract_name(&name).unwrap())
        .expect("bind abstract socket");
    let client =
        "import socket, sys; socket.socket(socket.AF_UNIX).connect(b'\\0' + sys.argv[1].encode())";
    let Ok(unfenced) = Command::new("python3").args(["-c", client, &name]).output() else {
        eprintln!("skipped: abstract socket scoping needs python3 as its client");
        return;
    };

    let fenced = fence(&[
        "--exec-dir",
        "/usr",
        "--read-dir",
        "/usr",
        "--",
        "python3",
        "-c",
        client,
        &name,
    ]);

    assert!(unfenced.status.success(), "{unfenced:?}");
    assert!(!fenced.status.success());
    assert!(
        text(&fenced.stderr).contains("PermissionError"),
        "{fenced:?}"
    );
}

#[test]
fn with_no_port_granted_tcp_is_refused_both_ways() {
    if too_old_for(4, "TCP rules") {
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port().to_string();
    let bash = |script: &str| {
        fence(&[
            "--exec-dir",
            "/usr",
            "--read-dir",
            "/usr",
            "--",
            "bash",
            "-c",
            script,
            "bash",
            &port,
        ])
    };

    let connect = bash("echo hi > \"/dev/tcp/127.0.0.1/$1\"");
    let bind = fence(&[
        "--exec-dir",
        "/usr",
        "--read-dir",
        "/usr",
        "--",
        "python3",
        "-c",
        "import socket; socket.socket().bind(('127.0.0.1', 0))",
    ]);

    assert!(!connect.status.success());
    assert!(
        text(&connect.stderr).contains("Permission denied"),
        "{connect:?}"
    );
    assert!(!bind.status.success());
    assert!(text(&bind.stderr).contains("PermissionError"), "{bind:?}");
}

#[test]
fn an_inherited_fd_above_stderr_is_closed_before_exec() {
    if too_old_for(1, "fd closing") {
        return;
    }
    let out = Command::new("sh")
        .args(["-c", "exec \"$@\" 3>&1 4>&1 1>/dev/null", "sh", FENCE])
        .args(["--exec-dir", "/usr", "--"])
        .args(["sh", "-c", "echo forged >&3; echo forged >&4"])
        .env("LC_ALL", "C")
        .output()
        .expect("spawn sh");

    assert_eq!(text(&out.stdout), "");
    assert!(text(&out.stderr).contains("Bad file descriptor"), "{out:?}");
}

#[test]
fn a_status_fd_naming_stdio_is_refused() {
    for fd in ["0", "1", "2"] {
        let out = fence(&["--status-fd", fd, "--exec-dir", "/usr", "--", "true"]);

        assert_eq!(out.status.code(), Some(125), "{fd}: {out:?}");
        assert!(text(&out.stderr).starts_with("lain-fence: "), "{out:?}");
    }
}

#[test]
fn status_with_a_command_or_a_status_fd_is_a_usage_error() {
    let with_command = fence(&["--status", "--", "true"]);
    let with_fd = fence(&["--status", "--status-fd", "3"]);

    assert_eq!(with_command.status.code(), Some(125), "{with_command:?}");
    assert_eq!(with_fd.status.code(), Some(125), "{with_fd:?}");
}

#[test]
fn a_directory_is_refused_as_an_exec_file() {
    let out = fence(&[
        "--exec-dir",
        "/usr",
        "--exec-file",
        "/usr/bin",
        "--",
        "true",
    ]);

    assert_eq!(out.status.code(), Some(125), "{out:?}");
    assert!(
        text(&out.stderr).contains("--exec-file /usr/bin"),
        "{out:?}"
    );
}

#[test]
fn status_reports_a_granted_path_that_does_not_exist() {
    let report = status(&[
        "--status",
        "--read-dir",
        "/no/such/dir",
        "--read-dir",
        "/usr",
    ]);

    assert_eq!(report["skipped"], serde_json::json!(["/no/such/dir"]));
}

#[test]
fn an_exec_dir_grants_running_and_reading_but_not_writing_or_listing() {
    if too_old_for(4, "exec-dir rights") {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let tool = script(dir.path(), "tool", "echo tool-ran");
    let dir_path = dir.path().to_str().unwrap();
    let run = |command: &str| {
        fence(&[
            "--exec-dir",
            "/usr",
            "--exec-dir",
            dir_path,
            "--",
            "sh",
            "-c",
            command,
            "sh",
            dir_path,
        ])
    };

    let ran = run(&format!(
        "{} && grep -q tool-ran \"$1/tool\" && echo read-ok",
        tool.to_str().unwrap()
    ));
    let wrote = run("echo x > \"$1/new\"");
    let listed = run("ls \"$1\"");

    assert_eq!(text(&ran.stdout), "tool-ran\nread-ok\n", "{ran:?}");
    assert!(!wrote.status.success(), "{wrote:?}");
    assert!(!dir.path().join("new").exists());
    assert!(!listed.status.success(), "{listed:?}");
}

#[test]
fn a_read_dir_grants_listing() {
    if too_old_for(4, "read-dir listing") {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    fs::write(dir.path().join("visible"), "").unwrap();
    let dir_path = dir.path().to_str().unwrap();

    let listed = fence(&[
        "--exec-dir",
        "/usr",
        "--read-dir",
        dir_path,
        "--",
        "ls",
        dir_path,
    ]);

    assert_eq!(text(&listed.stdout), "visible\n", "{listed:?}");
}

#[test]
fn a_unix_socket_is_reachable_only_beneath_a_unix_dir() {
    if too_old_for(9, "Unix socket path rules") {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("sock");
    let _listener = UnixListener::bind(&path).expect("bind unix socket");
    let client = "import socket, sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])";
    let dir_path = dir.path().to_str().unwrap();
    let path = path.to_str().unwrap();
    let grants = ["--exec-dir", "/usr", "--read-dir", "/usr"];

    let refused = fence(&[&grants[..], &["--", "python3", "-c", client, path]].concat());
    let granted = fence(
        &[
            &grants[..],
            &["--unix-dir", dir_path, "--", "python3", "-c", client, path],
        ]
        .concat(),
    );

    assert!(!refused.status.success());
    assert!(
        text(&refused.stderr).contains("PermissionError"),
        "{refused:?}"
    );
    assert!(granted.status.success(), "{granted:?}");
}
