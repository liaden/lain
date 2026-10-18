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
