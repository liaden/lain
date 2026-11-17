//! The phone relay against the REAL binary (`CARGO_BIN_EXE_lain-daemon`): the daemon's confined
//! worker, and `lain-daemon relay --unix` run on its own. Linux only, because only Landlock
//! confines the relay, and an unconfined relay refuses to run.
#![cfg(target_os = "linux")]
#![forbid(unsafe_code)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use lain_wire::{AgendaItem, Answer, Delta, Hello, Verdict, WIRE_VERSION};
use rmpv::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, UnixStream};

const TOKEN: &str = "a-paired-phone-token";

/// Longer than any reply needs on a loaded box.
const WAIT: Duration = Duration::from_secs(5);

/// A msgpack-RPC peer that keeps the pushes it reads while waiting for a reply.
struct Rpc<S> {
    stream: S,
    buffer: Vec<u8>,
    next_msgid: u32,
    pushes: Vec<(String, Vec<Value>)>,
}

impl<S: AsyncRead + AsyncWrite + Unpin> Rpc<S> {
    fn over(stream: S) -> Self {
        Self {
            stream,
            buffer: Vec::new(),
            next_msgid: 1,
            pushes: Vec::new(),
        }
    }

    async fn frame(&mut self, wait: Duration) -> Result<Value, String> {
        loop {
            let mut reader = &self.buffer[..];
            if let Ok(frame) = rmpv::decode::read_value(&mut reader) {
                let used = self.buffer.len() - reader.len();
                self.buffer.drain(..used);
                return Ok(frame);
            }
            let mut chunk = [0u8; 4096];
            let read = tokio::time::timeout(wait, self.stream.read(&mut chunk))
                .await
                .map_err(|_| "timed out waiting for a frame".to_string())?
                .map_err(|error| error.to_string())?;
            if read == 0 {
                return Err("the connection closed".to_string());
            }
            self.buffer.extend_from_slice(&chunk[..read]);
        }
    }

    fn keep_push(&mut self, frame: Value) -> Option<Value> {
        let Value::Array(parts) = frame else {
            return None;
        };
        if parts.first() == Some(&Value::from(2)) {
            let method = parts[1].as_str().unwrap_or_default().to_string();
            let params = parts[2].as_array().cloned().unwrap_or_default();
            self.pushes.push((method, params));
            None
        } else {
            Some(Value::Array(parts))
        }
    }

    async fn try_call(
        &mut self,
        method: &str,
        params: Vec<Value>,
    ) -> Result<(Value, Value), String> {
        let msgid = self.next_msgid;
        self.next_msgid += 1;
        let request = Value::Array(vec![
            Value::from(0),
            Value::from(msgid),
            Value::from(method),
            Value::Array(params),
        ]);
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &request).map_err(|error| error.to_string())?;
        self.stream
            .write_all(&bytes)
            .await
            .map_err(|error| error.to_string())?;
        loop {
            let frame = self.frame(WAIT).await?;
            if let Some(Value::Array(reply)) = self.keep_push(frame)
                && reply.get(1) == Some(&Value::from(msgid))
            {
                return Ok((reply[2].clone(), reply[3].clone()));
            }
        }
    }

    async fn call(&mut self, method: &str, params: Vec<Value>) -> (Value, Value) {
        self.try_call(method, params)
            .await
            .unwrap_or_else(|error| panic!("{method}: {error}"))
    }

    /// The next push, waiting up to `wait` for one.
    async fn push_within(&mut self, wait: Duration) -> Option<(String, Vec<Value>)> {
        while self.pushes.is_empty() {
            let frame = self.frame(wait).await.ok()?;
            self.keep_push(frame);
        }
        Some(self.pushes.remove(0))
    }
}

fn field(result: &Value, name: &str) -> Value {
    result
        .as_map()
        .unwrap_or_else(|| panic!("{result} is not a map"))
        .iter()
        .find(|(key, _)| key.as_str() == Some(name))
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| panic!("no {name} in {result}"))
}

fn value<T: serde::Serialize>(message: &T) -> Value {
    let bytes = lain_wire::encode(message).expect("encode a wire message");
    rmpv::decode::read_value(&mut bytes.as_slice()).expect("read it back")
}

fn message<T: serde::de::DeserializeOwned>(value: &Value) -> T {
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, value).expect("encode a value");
    lain_wire::decode(&bytes).expect("decode a wire message")
}

/// A 0600 devices file pairing `phone` with [`TOKEN`], alone in its 0700 directory.
fn devices_file(dir: &Path, mode: u32) -> PathBuf {
    let remote = dir.join("remote");
    std::fs::create_dir(&remote).expect("the devices dir");
    std::fs::set_permissions(&remote, std::fs::Permissions::from_mode(0o700)).expect("chmod");
    let devices = remote.join("devices");
    let digest = blake3::hash(TOKEN.as_bytes()).to_hex();
    std::fs::write(&devices, format!("phone {digest}\n")).expect("write the devices file");
    std::fs::set_permissions(&devices, std::fs::Permissions::from_mode(mode)).expect("chmod");
    devices
}

fn free_loopback_port() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    listener
        .local_addr()
        .expect("the bound address")
        .to_string()
}

fn spawn_daemon(dir: &Path, listen: &str, devices: &Path) -> tokio::process::Child {
    tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.join("daemon.sock"))
        .arg("--trace")
        .arg(dir.join("daemon.trace"))
        .args([
            "--launch-digest",
            "abc",
            "--relay",
            listen,
            "--devices-file",
        ])
        .arg(devices)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon")
}

/// A connection the daemon with `pid` answers a ping on; a connect alone may reach a listener
/// a sibling test's fork still holds.
async fn served_by(pid: u32, socket: &Path) -> Rpc<UnixStream> {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Ok(stream) = UnixStream::connect(socket).await {
            let mut rpc = Rpc::over(stream);
            if let Ok((_, result)) = rpc.try_call("ping", vec![]).await
                && result.as_map().is_some()
                && field(&result, "pid") == Value::from(pid)
            {
                return rpc;
            }
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the daemon never answered on {}",
            socket.display()
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// The relay state `daemon.info` reports.
async fn relay_state(daemon: &mut Rpc<UnixStream>) -> Value {
    let (error, info) = daemon.call("daemon.info", vec![]).await;
    assert_eq!(Value::Nil, error);
    field(&info, "relay")
}

/// Polls `daemon.info` until the relay reads `state`, for up to [`WAIT`].
async fn relay_reaches(daemon: &mut Rpc<UnixStream>, state: &str) -> bool {
    let deadline = tokio::time::Instant::now() + WAIT;
    while relay_state(daemon).await != Value::from(state) {
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    true
}

/// The children of `pid`, read from every process's stat.
fn children_of(pid: u32) -> Vec<u32> {
    std::fs::read_dir("/proc")
        .expect("read /proc")
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse::<u32>().ok())
        .filter(|child| {
            std::fs::read_to_string(format!("/proc/{child}/stat"))
                .ok()
                .and_then(|stat| {
                    let after = stat.rsplit_once(')')?.1.to_string();
                    after.split_whitespace().nth(1)?.parse::<u32>().ok()
                })
                == Some(pid)
        })
        .collect()
}

async fn the_worker_of(daemon_pid: u32) -> u32 {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let [worker] = children_of(daemon_pid)[..] {
            return worker;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the daemon started no relay worker"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn status_line(pid: &str, name: &str) -> String {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).expect("read status");
    status
        .lines()
        .find(|line| line.starts_with(name))
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .unwrap_or_else(|| panic!("no {name} line"))
}

/// A phone admitted by the worker, retrying while the worker is still binding.
async fn phone(listen: &str) -> Rpc<TcpStream> {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Ok(stream) = TcpStream::connect(listen).await {
            stream.set_nodelay(true).expect("no delay");
            let mut phone = Rpc::over(stream);
            let hello = value(&Hello {
                wire_version: WIRE_VERSION,
                token: TOKEN.to_string(),
                cursor: 0,
            });
            let (error, _) = phone.call("hello", vec![hello]).await;
            assert_eq!(Value::Nil, error, "the paired phone was refused");
            return phone;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the worker never listened on {listen}"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn registration(session_id: &str) -> Value {
    Value::Map(vec![
        (Value::from("session_id"), Value::from(session_id)),
        (Value::from("pid"), Value::from(std::process::id())),
        (Value::from("host"), Value::from("rainbow")),
        (Value::from("root"), Value::from("/work")),
        (Value::from("cwd"), Value::from("/work")),
        (Value::from("input_socket"), Value::Nil),
        (Value::from("journal"), Value::Nil),
        (Value::from("attended"), Value::from(true)),
        (
            Value::from("started_at"),
            Value::from("2026-11-17T10:00:00Z"),
        ),
    ])
}

fn parked(id: &str) -> AgendaItem {
    AgendaItem::ParkedCall {
        id: id.to_string(),
        requester: "main".to_string(),
        tool: "bash".to_string(),
        input: "rm -rf build".to_string(),
        cwd: "/work".to_string(),
        why: "outside the checkout".to_string(),
        postponed: false,
        asked_at: 1_793_000_000,
        session: "claimed-session".to_string(),
        project: "/claimed/project".to_string(),
    }
}

fn adding(item: AgendaItem) -> Value {
    value(&Delta {
        cursor: 0,
        added: vec![item],
        settled: vec![],
    })
}

fn approve(id: &str) -> Answer {
    Answer::Call {
        id: id.to_string(),
        verdict: Verdict::Approve { note: None },
        device: None,
    }
}

#[tokio::test]
async fn the_daemon_runs_its_relay_confined_and_hands_the_phones_answer_to_the_session() {
    assert_eq!(
        "NoNewPrivs: 0",
        status_line("self", "NoNewPrivs:"),
        "the test runner already has no_new_privs, so the worker's own cannot be seen"
    );
    let dir = tempfile::tempdir().expect("tempdir");
    let devices = devices_file(dir.path(), 0o600);
    let listen = free_loopback_port();
    let daemon_process = spawn_daemon(dir.path(), &listen, &devices);
    let daemon_pid = daemon_process.id().expect("daemon pid");
    let mut session = served_by(daemon_pid, &dir.path().join("daemon.sock")).await;

    let worker = the_worker_of(daemon_pid).await.to_string();
    assert_eq!("NoNewPrivs: 1", status_line(&worker, "NoNewPrivs:"));
    let environment = std::fs::read(format!("/proc/{worker}/environ")).expect("read environ");
    let names: Vec<String> = String::from_utf8_lossy(&environment)
        .split(' ')
        .filter_map(|entry| Some(entry.split_once('=')?.0.to_string()))
        .collect();
    assert!(names.is_empty(), "the worker inherited {names:?}");
    assert!(relay_reaches(&mut session, "running").await);

    assert_eq!(
        Value::Nil,
        session
            .call("session.register", vec![registration("s1")])
            .await
            .0
    );
    let (error, _) = session
        .call("agenda.publish", vec![adding(parked("p1"))])
        .await;
    assert_eq!(Value::Nil, error, "the publish was refused");

    let mut phone = phone(&listen).await;
    let at = value(&lain_wire::Cursor {
        cursor: u64::MAX,
        epoch: None,
    });
    let (error, page) = phone.call("agenda.next", vec![at]).await;
    assert_eq!(Value::Nil, error);
    let page: lain_wire::AgendaPage = message(&page);
    let [AgendaItem::ParkedCall { id, .. }] = &page.deltas[0].added[..] else {
        panic!("{page:?}")
    };
    let (error, _) = phone.call("answer.send", vec![value(&approve(id))]).await;
    assert_eq!(Value::Nil, error, "the answer was refused");

    let (method, params) = session
        .push_within(WAIT)
        .await
        .expect("the answer was pushed to the session");
    assert_eq!("answer", method);
    let answer: Answer = message(&params[0]);
    assert_eq!(approve("p1").stamped_by("phone"), answer);
}

#[tokio::test]
async fn a_publish_before_registering_is_refused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let devices = devices_file(dir.path(), 0o600);
    let daemon_process = spawn_daemon(dir.path(), &free_loopback_port(), &devices);
    let daemon_pid = daemon_process.id().expect("daemon pid");
    let mut session = served_by(daemon_pid, &dir.path().join("daemon.sock")).await;

    let (error, _) = session
        .call("agenda.publish", vec![adding(parked("p1"))])
        .await;
    assert!(
        error.as_str().is_some_and(|text| text.contains("register")),
        "{error}"
    );
}

#[tokio::test]
async fn a_worker_that_cannot_start_leaves_the_daemon_serving_with_the_relay_unavailable() {
    let dir = tempfile::tempdir().expect("tempdir");
    let devices = devices_file(dir.path(), 0o644);
    let daemon_process = spawn_daemon(dir.path(), &free_loopback_port(), &devices);
    let daemon_pid = daemon_process.id().expect("daemon pid");
    let mut session = served_by(daemon_pid, &dir.path().join("daemon.sock")).await;

    assert!(
        relay_reaches(&mut session, "unavailable").await,
        "the relay still reads {}",
        relay_state(&mut session).await
    );
    let (error, _) = session.call("ping", vec![]).await;
    assert_eq!(Value::Nil, error, "the daemon stopped serving");
    assert_eq!(
        Value::Nil,
        session
            .call("session.register", vec![registration("s1")])
            .await
            .0
    );
    let (error, _) = session
        .call("agenda.publish", vec![adding(parked("p1"))])
        .await;
    assert!(
        error
            .as_str()
            .is_some_and(|text| text.contains("unavailable")),
        "{error}"
    );
    let trace = std::fs::read_to_string(dir.path().join("daemon.trace")).expect("the trace");
    let refusal = trace
        .lines()
        .find(|line| line.contains("open to group or others"))
        .unwrap_or_else(|| panic!("{trace}"));
    assert!(refusal.starts_with("relay["), "{refusal}");
    assert!(
        trace
            .lines()
            .any(|line| line.starts_with(&format!("daemon[{daemon_pid}] "))),
        "{trace}"
    );
}

#[tokio::test]
async fn a_daemon_started_without_a_relay_reports_it_off() {
    let dir = tempfile::tempdir().expect("tempdir");
    let daemon_process = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.path().join("daemon.sock"))
        .args(["--launch-digest", "abc"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    let daemon_pid = daemon_process.id().expect("daemon pid");
    let mut session = served_by(daemon_pid, &dir.path().join("daemon.sock")).await;
    assert_eq!(Value::from("off"), relay_state(&mut session).await);
    assert!(children_of(daemon_pid).is_empty());
}

#[tokio::test]
async fn a_relay_flag_without_a_devices_file_exits_2() {
    let dir = tempfile::tempdir().expect("tempdir");
    let mut daemon = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.path().join("daemon.sock"))
        .args(["--launch-digest", "abc", "--relay", "127.0.0.1:0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    let status = tokio::time::timeout(WAIT, daemon.wait())
        .await
        .expect("the daemon did not exit")
        .expect("wait");
    assert_eq!(Some(2), status.code());
}

#[tokio::test]
async fn the_worker_exits_when_its_daemon_is_killed() {
    let dir = tempfile::tempdir().expect("tempdir");
    let devices = devices_file(dir.path(), 0o600);
    let mut daemon_process = spawn_daemon(dir.path(), &free_loopback_port(), &devices);
    let daemon_pid = daemon_process.id().expect("daemon pid");
    let _session = served_by(daemon_pid, &dir.path().join("daemon.sock")).await;
    let worker = the_worker_of(daemon_pid).await;

    daemon_process.kill().await.expect("kill the daemon");
    let deadline = tokio::time::Instant::now() + WAIT;
    while Path::new(&format!("/proc/{worker}")).exists()
        && !status_line(&worker.to_string(), "State:").contains("zombie")
    {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the worker outlived its daemon"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// `relay --unix` on loopback with a 0600 devices file, tracing to `trace.log`.
fn spawn_relay(dir: &Path, listen: &str) -> tokio::process::Child {
    let devices = devices_file(dir, 0o600);
    tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
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

#[tokio::test]
async fn a_standalone_relay_confines_itself_and_removes_its_socket_on_sigterm() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("relay.sock");
    let mut relay = spawn_relay(dir.path(), "127.0.0.1:0");
    let deadline = tokio::time::Instant::now() + WAIT;
    while !socket.exists() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the relay never bound its unix socket"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let pid = relay.id().expect("relay pid").to_string();
    assert_eq!("NoNewPrivs: 1", status_line(&pid, "NoNewPrivs:"));

    let term = std::process::Command::new("kill")
        .args(["-TERM", &pid])
        .status()
        .expect("send SIGTERM");
    assert!(term.success());
    let status = tokio::time::timeout(WAIT, relay.wait())
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
    let status = tokio::time::timeout(WAIT, relay.wait())
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
