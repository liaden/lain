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

/// The error and result slots of the reply to 1 request, or why none arrived within `wait`.
async fn try_request(
    stream: &mut UnixStream,
    method: &str,
    params: Vec<Value>,
    wait: Duration,
) -> Result<(Value, Value), String> {
    let request = Value::Array(vec![
        Value::from(0),
        Value::from(1),
        Value::from(method),
        Value::Array(params),
    ]);
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &request).map_err(|error| error.to_string())?;
    stream
        .write_all(&bytes)
        .await
        .map_err(|error| error.to_string())?;
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0u8; 512];
        let read = tokio::time::timeout(wait, stream.read(&mut chunk))
            .await
            .map_err(|_| "timed out waiting for a reply".to_string())?
            .map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("connection closed before a reply arrived".to_string());
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Ok(Value::Array(reply)) = rmpv::decode::read_value(&mut &buffer[..]) {
            return Ok((reply[2].clone(), reply[3].clone()));
        }
    }
}

/// The error and result slots of the reply to 1 request.
async fn request(stream: &mut UnixStream, method: &str, params: Vec<Value>) -> (Value, Value) {
    try_request(stream, method, params, Duration::from_secs(5))
        .await
        .unwrap_or_else(|error| panic!("{method}: {error}"))
}

/// The result slot of a successful reply, as a map of its fields.
async fn call(stream: &mut UnixStream, method: &str) -> Vec<(Value, Value)> {
    let (error, result) = request(stream, method, vec![]).await;
    assert_eq!(Value::Nil, error, "{method} answered with an error");
    let Value::Map(result) = result else {
        panic!("{method} result is not a map")
    };
    result
}

fn field(result: &[(Value, Value)], name: &str) -> Value {
    result
        .iter()
        .find(|(key, _)| key.as_str() == Some(name))
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| panic!("no {name} in {result:?}"))
}

/// The pid that answers a ping on a fresh connection, or None for anything short of a reply.
async fn pid_answering(socket: &Path) -> Option<u64> {
    let mut stream = UnixStream::connect(socket).await.ok()?;
    let (_, result) = try_request(&mut stream, "ping", vec![], Duration::from_millis(200))
        .await
        .ok()?;
    let Value::Map(result) = result else {
        return None;
    };
    field(&result, "pid").as_u64()
}

/// A connection to `daemon` itself. A listener left at the path, or one whose fd a sibling
/// test's fork still holds, accepts a connect that no daemon will answer, so only a ping
/// answered with the daemon's pid counts.
async fn served_by(daemon: &tokio::process::Child, socket: &Path) -> UnixStream {
    let pid = u64::from(daemon.id().expect("daemon pid"));
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while pid_answering(socket).await != Some(pid) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the daemon never answered on {}",
            socket.display()
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    UnixStream::connect(socket).await.expect("connect")
}

async fn connected(dir: &Path, digest: &str) -> (tokio::process::Child, UnixStream) {
    let daemon = spawn_daemon(dir, digest);
    let stream = served_by(&daemon, &dir.join("daemon.sock")).await;
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
    let mut stream = served_by(&daemon, &socket).await;
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

fn registration(session_id: &str, pid: u32) -> Value {
    Value::Map(vec![
        (Value::from("session_id"), Value::from(session_id)),
        (Value::from("pid"), Value::from(pid)),
        (Value::from("host"), Value::from("rainbow")),
        (Value::from("root"), Value::from("/work")),
        (Value::from("cwd"), Value::from("/work/lib")),
        (
            Value::from("input_socket"),
            Value::from("/run/lain/input.sock"),
        ),
        (Value::from("journal"), Value::Nil),
        (Value::from("attended"), Value::from(true)),
        (
            Value::from("started_at"),
            Value::from("2026-11-17T10:00:00Z"),
        ),
    ])
}

async fn listed(stream: &mut UnixStream) -> Vec<Value> {
    let (error, result) = request(stream, "session.list", vec![]).await;
    assert_eq!(Value::Nil, error, "session.list answered with an error");
    let Value::Array(sessions) = result else {
        panic!("session.list result is not an array: {result}")
    };
    sessions
}

fn fields_of(record: &Value) -> Vec<(Value, Value)> {
    let Value::Map(fields) = record.clone() else {
        panic!("a listed session is not a map: {record}")
    };
    fields
}

/// What `Liveness::Probe` reads as a start: field 22 of `/proc/<pid>/stat`.
fn proc_start_of(pid: u32) -> Option<String> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
    Some(fields.get(19)?.to_string())
}

#[tokio::test]
async fn a_chat_registers_itself_and_is_listed_with_the_start_the_daemon_read() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut stream) = connected(dir.path(), "abc").await;
    let me = std::process::id();

    let (error, _) = request(
        &mut stream,
        "session.register",
        vec![registration("s1", me)],
    )
    .await;
    assert_eq!(Value::Nil, error);

    let sessions = listed(&mut stream).await;
    assert_eq!(1, sessions.len(), "{sessions:?}");
    let record = fields_of(&sessions[0]);
    assert_eq!(Value::from("s1"), field(&record, "session_id"));
    assert_eq!(Value::from(me), field(&record, "pid"));
    assert_eq!(Value::from("/work"), field(&record, "root"));
    assert_eq!(Value::from("/work/lib"), field(&record, "cwd"));
    assert_eq!(
        Value::from("/run/lain/input.sock"),
        field(&record, "input_socket")
    );
    assert_eq!(Value::Nil, field(&record, "journal"));
    assert_eq!(Value::from(true), field(&record, "attended"));
    assert_eq!(
        Value::from("2026-11-17T10:00:00Z"),
        field(&record, "started_at")
    );
    let start = field(&record, "start");
    match proc_start_of(me) {
        Some(expected) => assert_eq!(Value::from(expected), start),
        None => assert!(
            start.as_str().is_some_and(|s| s.starts_with('u')),
            "{start}"
        ),
    }
}

#[tokio::test]
async fn a_process_cannot_register_as_another() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (daemon, mut stream) = connected(dir.path(), "abc").await;
    let other = daemon.id().expect("daemon pid");

    let (error, _) = request(
        &mut stream,
        "session.register",
        vec![registration("s1", other)],
    )
    .await;
    assert!(
        error
            .as_str()
            .is_some_and(|text| text.contains(&other.to_string())),
        "{error}"
    );
    assert!(listed(&mut stream).await.is_empty());
    let trace = std::fs::read_to_string(dir.path().join("daemon.trace")).expect("the trace");
    assert!(trace.contains("not_the_caller"), "{trace}");
}

#[tokio::test]
async fn a_session_ends_when_its_connection_does() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut chat) = connected(dir.path(), "abc").await;
    let mut watcher = UnixStream::connect(dir.path().join("daemon.sock"))
        .await
        .expect("connect");

    let (error, _) = request(
        &mut chat,
        "session.register",
        vec![registration("s1", std::process::id())],
    )
    .await;
    assert_eq!(Value::Nil, error);
    assert_eq!(1, listed(&mut watcher).await.len());

    drop(chat);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !listed(&mut watcher).await.is_empty() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the session outlived its connection"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn a_connection_registers_once() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut stream) = connected(dir.path(), "abc").await;
    let me = std::process::id();

    let (error, _) = request(
        &mut stream,
        "session.register",
        vec![registration("s1", me)],
    )
    .await;
    assert_eq!(Value::Nil, error);
    let (error, _) = request(
        &mut stream,
        "session.register",
        vec![registration("s2", me)],
    )
    .await;
    assert!(
        error
            .as_str()
            .is_some_and(|text| text.contains("already registered")),
        "{error}"
    );
    assert_eq!(1, listed(&mut stream).await.len());
}

#[tokio::test]
async fn a_malformed_registration_is_refused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut stream) = connected(dir.path(), "abc").await;

    for params in [vec![], vec![Value::from("s1")], vec![Value::Map(vec![])]] {
        let (error, _) = request(&mut stream, "session.register", params.clone()).await;
        assert!(error.is_str(), "{params:?} got {error}");
    }
    assert!(listed(&mut stream).await.is_empty());
}

#[tokio::test]
async fn no_local_method_answers_anything() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut stream) = connected(dir.path(), "abc").await;

    for method in ["answer.send", "agenda.next", "answers.next", "hello"] {
        let (error, _) = request(&mut stream, method, vec![]).await;
        assert!(
            error
                .as_str()
                .is_some_and(|text| text.contains("unknown method")),
            "{method} got {error}"
        );
    }
}

#[tokio::test]
async fn a_session_id_cannot_forge_a_trace_line() {
    let dir = tempfile::tempdir().expect("tempdir");
    let (_daemon, mut chat) = connected(dir.path(), "abc").await;
    let mut other = UnixStream::connect(dir.path().join("daemon.sock"))
        .await
        .expect("connect");
    let me = std::process::id();

    let (error, _) = request(
        &mut chat,
        "session.register",
        vec![registration("s1\nFORGED a line", me)],
    )
    .await;
    assert_eq!(Value::Nil, error);
    let (error, _) = request(&mut other, "session.register", vec![registration("s2", me)]).await;
    assert!(
        error.as_str().is_some_and(|text| text.contains("FORGED")),
        "{error}"
    );

    let trace = std::fs::read_to_string(dir.path().join("daemon.trace")).expect("the trace");
    assert!(trace.contains("inside_a_session"), "{trace}");
    assert!(
        !trace.lines().any(|line| line.starts_with("FORGED")),
        "{trace}"
    );
}
