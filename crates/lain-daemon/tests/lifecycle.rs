//! The daemon's lifecycle against the REAL binary (`CARGO_BIN_EXE_lain-daemon`): signal
//! dispositions and exit codes are process-wide, so an in-process server cannot show them.
#![forbid(unsafe_code)]

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

fn spawn_daemon(dir: &Path, digest: &str) -> tokio::process::Child {
    tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.join("daemon.sock"))
        .arg("--trace")
        .arg(dir.join("daemon.trace"))
        .args(["--launch-digest", digest])
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

/// The result slot of a successful reply, as a map of its fields.
async fn call(stream: &mut UnixStream, method: &str) -> Vec<(Value, Value)> {
    let request = Value::Array(vec![
        Value::from(0),
        Value::from(1),
        Value::from(method),
        Value::Array(vec![]),
    ]);
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &request).expect("encode the request");
    stream.write_all(&bytes).await.expect("send the request");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0u8; 512];
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
            .await
            .expect("timed out waiting for a reply")
            .expect("read the reply");
        assert!(read > 0, "connection closed before a reply arrived");
        buffer.extend_from_slice(&chunk[..read]);
        if let Ok(Value::Array(reply)) = rmpv::decode::read_value(&mut &buffer[..]) {
            assert_eq!(Value::Nil, reply[2], "{method} answered with an error");
            let Value::Map(result) = reply[3].clone() else {
                panic!("{method} result is not a map")
            };
            return result;
        }
    }
}

fn field(result: &[(Value, Value)], name: &str) -> Value {
    result
        .iter()
        .find(|(key, _)| key.as_str() == Some(name))
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| panic!("no {name} in {result:?}"))
}

async fn connected(dir: &Path, digest: &str) -> (tokio::process::Child, UnixStream) {
    let daemon = spawn_daemon(dir, digest);
    let socket = dir.join("daemon.sock");
    assert!(
        wait_until(5000, || socket.exists()).await,
        "the daemon never bound its socket"
    );
    let stream = UnixStream::connect(&socket).await.expect("connect");
    (daemon, stream)
}

#[tokio::test]
async fn it_answers_ping_and_reports_its_build_and_launch_digest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (daemon, mut stream) = connected(dir.path(), "abc").await;

    let ping = call(&mut stream, "ping").await;
    assert_eq!(Value::from("0.1.0"), field(&ping, "version"));
    assert_eq!(
        Value::from(daemon.id().expect("daemon pid")),
        field(&ping, "pid")
    );

    let info = call(&mut stream, "daemon.info").await;
    let build = field(&info, "build_id");
    assert!(
        build.as_str().is_some_and(|id| id.starts_with("0.1.0 ")),
        "{build}"
    );
    assert_eq!(Value::from("abc"), field(&info, "launch_digest"));
}

#[tokio::test]
async fn a_second_daemon_on_the_same_socket_exits_1_and_the_first_keeps_serving() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_first, mut stream) = connected(dir.path(), "abc").await;

    let mut second = spawn_daemon(dir.path(), "def");
    let status = tokio::time::timeout(Duration::from_secs(5), second.wait())
        .await
        .expect("the second daemon did not exit")
        .expect("wait");
    assert_eq!(Some(1), status.code());
    let trace = std::fs::read_to_string(dir.path().join("daemon.trace")).expect("the trace");
    assert!(trace.contains("in use"), "{trace}");
    assert!(trace.contains("daemon.sock"), "{trace}");

    let info = call(&mut stream, "daemon.info").await;
    assert_eq!(Value::from("abc"), field(&info, "launch_digest"));
}

#[tokio::test]
async fn sigterm_exits_0_and_removes_the_socket() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (mut daemon, _stream) = connected(dir.path(), "abc").await;
    let pid = daemon.id().expect("daemon pid").to_string();

    let term = std::process::Command::new("kill")
        .args(["-TERM", &pid])
        .status()
        .expect("send SIGTERM");
    assert!(term.success());
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("the daemon did not exit on SIGTERM")
        .expect("wait");
    assert!(status.success(), "got {status}");
    assert!(
        !dir.path().join("daemon.sock").exists(),
        "the socket was left behind"
    );
}

#[tokio::test]
async fn a_socket_nothing_answers_on_is_cleared_and_served_on() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("daemon.sock");
    drop(std::os::unix::net::UnixListener::bind(&socket).expect("leave a stale socket"));
    assert!(socket.exists());

    let daemon = spawn_daemon(dir.path(), "abc");
    assert!(
        wait_until(5000, || {
            std::os::unix::net::UnixStream::connect(&socket).is_ok()
        })
        .await,
        "the daemon never served on the stale path"
    );
    let mut stream = UnixStream::connect(&socket).await.expect("connect");
    let ping = call(&mut stream, "ping").await;
    assert_eq!(
        Value::from(daemon.id().expect("daemon pid")),
        field(&ping, "pid")
    );
}

#[tokio::test]
async fn a_regular_file_at_the_socket_path_is_refused_and_left_alone() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("daemon.sock");
    std::fs::write(&socket, "mine").expect("write the file");

    let mut daemon = spawn_daemon(dir.path(), "abc");
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("the daemon did not exit")
        .expect("wait");
    assert_eq!(Some(1), status.code());
    assert_eq!("mine", std::fs::read_to_string(&socket).expect("the file"));
}

#[tokio::test]
async fn a_bad_invocation_exits_2() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("daemon.sock");
    let socket = socket.to_str().expect("utf-8 path");
    let bad: [&[&str]; 4] = [
        &[],
        &["--socket", socket],
        &["--socket", socket, "--launch-digest", "abc", "--bogus", "x"],
        &["--socket", socket, "--launch-digest"],
    ];
    for argv in bad {
        let mut daemon = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
            .args(argv)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("spawn the daemon");
        let status = tokio::time::timeout(Duration::from_secs(5), daemon.wait())
            .await
            .unwrap_or_else(|_| panic!("argv {argv:?} did not exit"))
            .expect("wait");
        assert_eq!(Some(2), status.code(), "argv {argv:?}");
    }
}
