//! Daemon lifecycle against the REAL binary (`CARGO_BIN_EXE_lain-core`, which
//! cargo builds fresh for integration tests -- a path-derived
//! `target/debug/lain-core` can be stale under `cargo test`). Signal handling
//! and argv are process-wide state, so they cannot be observed from an
//! in-process server.
#![forbid(unsafe_code)]

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

fn spawn_daemon(socket: &Path) -> tokio::process::Child {
    tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
        .arg(socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon")
}

async fn wait_until(deadline_ms: u64, mut probe: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + Duration::from_millis(deadline_ms);
    loop {
        if probe() {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn ping(stream: &mut UnixStream) -> Value {
    call(stream, "ping", vec![], Duration::from_secs(5)).await
}

async fn call(stream: &mut UnixStream, method: &str, params: Vec<Value>, wait: Duration) -> Value {
    let request = Value::Array(vec![
        Value::from(0),
        Value::from(1),
        Value::from(method),
        Value::Array(params),
    ]);
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &request).expect("encode the request");
    stream.write_all(&bytes).await.expect("send the request");

    // msgpack is self-delimiting, so "a whole value decoded" is the frame
    // boundary -- there is nothing else to wait for.
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0u8; 512];
        let read = tokio::time::timeout(wait, stream.read(&mut chunk))
            .await
            .unwrap_or_else(|_| panic!("timed out after {wait:?} waiting for the {method} reply"))
            .expect("read the reply");
        assert!(read > 0, "connection closed before a reply arrived");
        buffer.extend_from_slice(&chunk[..read]);
        if let Ok(value) = rmpv::decode::read_value(&mut &buffer[..]) {
            return value;
        }
    }
}

/// `[1, 1, nil, {version, pid}]`, pulled apart and checked whole.
fn assert_ping_reply(reply: &Value, daemon_pid: u32) {
    let Value::Array(elements) = reply else {
        panic!("reply is not an array: {reply}")
    };
    assert_eq!(4, elements.len(), "reply arity: {reply}");
    assert_eq!(Value::from(1), elements[0], "reply type");
    assert_eq!(Value::from(1), elements[1], "reply msgid");
    assert_eq!(Value::Nil, elements[2], "ping answered with an error");
    let Value::Map(result) = &elements[3] else {
        panic!("ping result is not a map: {reply}")
    };
    let field = |name: &str| {
        result
            .iter()
            .find(|(key, _)| key.as_str() == Some(name))
            .map(|(_, value)| value.clone())
            .unwrap_or_else(|| panic!("ping result lacks {name}: {reply}"))
    };
    assert_eq!(Value::from(env!("CARGO_PKG_VERSION")), field("version"));
    assert_eq!(Value::from(daemon_pid), field("pid"));
}

async fn connected_daemon(socket: &Path) -> (tokio::process::Child, UnixStream) {
    let daemon = spawn_daemon(socket);
    assert!(
        wait_until(5000, || socket.exists()).await,
        "daemon never bound its unix socket"
    );
    let stream = UnixStream::connect(socket).await.expect("connect");
    (daemon, stream)
}

#[tokio::test]
async fn the_argv_socket_answers_ping() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let (daemon, mut stream) = connected_daemon(&socket).await;
    let reply = ping(&mut stream).await;
    assert_ping_reply(&reply, daemon.id().expect("daemon pid"));
}

#[tokio::test]
async fn sigterm_shuts_an_answering_daemon_down_cleanly() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let (mut daemon, mut stream) = connected_daemon(&socket).await;
    let daemon_pid = daemon.id().expect("daemon pid");
    assert_ping_reply(&ping(&mut stream).await, daemon_pid);

    let term = std::process::Command::new("kill")
        .args(["-TERM", &daemon_pid.to_string()])
        .status()
        .expect("send SIGTERM");
    assert!(term.success());
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("daemon did not exit on SIGTERM")
        .expect("daemon wait");
    assert!(
        status.success(),
        "SIGTERM should go through the runtime and exit 0, got {status}"
    );
}

#[tokio::test]
async fn the_shipped_binary_refuses_the_test_only_sleep() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let (_daemon, mut stream) = connected_daemon(&socket).await;
    // Well under the 5s asked for: a sleep that ran would time out here instead.
    let reply = call(
        &mut stream,
        "sleep",
        vec![Value::from(5000)],
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(
        Value::Array(vec![
            Value::from(1),
            Value::from(1),
            Value::from("unknown method \"sleep\""),
            Value::Nil,
        ]),
        reply
    );
}

#[tokio::test]
async fn an_unfinished_frame_past_the_ceiling_closes_its_connection_only() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let (daemon, mut flood) = connected_daemon(&socket).await;

    // A str32 header that declares 1 byte past the 96 MiB sent, so the frame never finishes.
    let declared: u32 = (96 << 20) + 1;
    let mut header = vec![0xdb];
    header.extend_from_slice(&declared.to_be_bytes());
    let chunk = vec![b'x'; 64 << 10];
    let mut sent = 0usize;
    let mut refused = flood.write_all(&header).await.is_err();
    while !refused && sent < 96 << 20 {
        refused = flood.write_all(&chunk).await.is_err();
        sent += chunk.len();
    }
    let mut buffer = [0u8; 16];
    let read = tokio::time::timeout(Duration::from_secs(5), flood.read(&mut buffer))
        .await
        .expect("the flooded connection stayed open");
    assert!(
        matches!(read, Ok(0) | Err(_)),
        "the flooded connection answered instead of closing: {read:?}"
    );

    let mut healthy = UnixStream::connect(&socket).await.expect("connect");
    assert_ping_reply(&ping(&mut healthy).await, daemon.id().expect("daemon pid"));
}

/// A relay on loopback with a 0600 devices file pairing nobody, tracing to `trace`.
fn spawn_relay(dir: &Path, listen: &str) -> tokio::process::Child {
    use std::os::unix::fs::PermissionsExt;
    let remote = dir.join("remote");
    std::fs::create_dir(&remote).expect("the devices dir");
    let devices = remote.join("devices");
    std::fs::write(&devices, "").expect("write the devices file");
    std::fs::set_permissions(&devices, std::fs::Permissions::from_mode(0o600)).expect("chmod");
    tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
        .arg("relay")
        .arg("--unix")
        .arg(dir.join("relay.sock"))
        .args(["--listen", listen, "--devices-file"])
        .arg(&devices)
        .arg("--trace")
        .arg(dir.join("trace.log"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the relay")
}

fn no_new_privs(pid: &str) -> String {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).expect("read status");
    status
        .lines()
        .find(|line| line.starts_with("NoNewPrivs:"))
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .expect("a NoNewPrivs line")
}

#[tokio::test]
async fn the_relay_confines_itself_and_removes_its_socket_on_sigterm() {
    assert_eq!(
        "NoNewPrivs: 0",
        no_new_privs("self"),
        "the test runner already has no_new_privs, so the relay's own cannot be seen"
    );
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("relay.sock");
    let mut relay = spawn_relay(dir.path(), "127.0.0.1:0");
    assert!(
        wait_until(5000, || socket.exists()).await,
        "the relay never bound its unix socket"
    );
    let pid = relay.id().expect("relay pid").to_string();
    assert_eq!(
        "NoNewPrivs: 1",
        no_new_privs(&pid),
        "the relay is not confined"
    );

    let term = std::process::Command::new("kill")
        .args(["-TERM", &pid])
        .status()
        .expect("send SIGTERM");
    assert!(term.success());
    let status = tokio::time::timeout(Duration::from_secs(5), relay.wait())
        .await
        .expect("the relay did not exit on SIGTERM")
        .expect("relay wait");
    assert!(status.success(), "SIGTERM should exit 0, got {status}");
    assert!(!socket.exists(), "the relay left its socket behind");
}

#[tokio::test]
async fn a_relay_told_to_listen_on_a_host_name_says_why_and_exits_2() {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut relay = spawn_relay(dir.path(), "localhost:7820");
    let status = tokio::time::timeout(Duration::from_secs(5), relay.wait())
        .await
        .expect("the relay did not exit")
        .expect("relay wait");
    assert_eq!(Some(2), status.code());
    let trace = std::fs::read_to_string(dir.path().join("trace.log")).expect("the trace");
    assert!(
        trace.contains(
            "--listen localhost:7820 is not an IP address and port; the relay resolves no names"
        ),
        "{trace}"
    );
}
