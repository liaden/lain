//! Headless runs against the REAL binary (`CARGO_BIN_EXE_lain-daemon`): a run is a process
//! group the daemon starts, so only a real daemon shows its argv, env, group and exit.
#![forbid(unsafe_code)]

use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

/// Longer than any step needs on a loaded box.
const WAIT: Duration = Duration::from_secs(10);

const HELPER: &str = "a_run_helper_registers_then_exits_3";

/// A stand-in for ruby: it records what it was run with, then does what `PROBE_MODE` says.
const FAKE_RUBY: &str = r#"#!/bin/sh
printf '%s\0' "$@" > "$PROBE/argv.tmp" && mv "$PROBE/argv.tmp" "$PROBE/argv"
env > "$PROBE/env"
pwd > "$PROBE/cwd"
echo to-stdout
echo to-stderr >&2
case "$PROBE_MODE" in
  exit3) exit 3 ;;
  group) sleep 60 & echo $! > "$PROBE/grandchild"; wait ;;
  register) exec "$HELPER_EXE" --exact "$HELPER_NAME" --nocapture --test-threads 1 ;;
esac
"#;

struct Daemon {
    child: tokio::process::Child,
    dir: tempfile::TempDir,
    stream: UnixStream,
}

impl Daemon {
    fn probe(&self) -> PathBuf {
        self.dir.path().join("probe")
    }

    fn runs(&self) -> PathBuf {
        self.dir.path().join("state").join("runs")
    }

    fn lain(&self) -> PathBuf {
        self.dir.path().join("exe-lain")
    }

    fn project(&self) -> PathBuf {
        self.dir.path().join("project")
    }

    async fn request(&mut self, method: &str, params: Vec<Value>) -> (Value, Value) {
        request(&mut self.stream, method, params).await
    }

    async fn info(&mut self) -> Value {
        let (error, info) = self.request("daemon.info", vec![]).await;
        assert_eq!(Value::Nil, error);
        info
    }

    async fn start(&mut self, start: Value) -> (Value, Value) {
        self.request("run.start", vec![start]).await
    }

    async fn list(&mut self) -> Vec<Value> {
        let (error, runs) = self.request("run.list", vec![]).await;
        assert_eq!(Value::Nil, error);
        runs.as_array().expect("run.list is an array").clone()
    }

    async fn sessions(&mut self) -> Vec<Value> {
        let (error, sessions) = self.request("session.list", vec![]).await;
        assert_eq!(Value::Nil, error);
        sessions
            .as_array()
            .expect("session.list is an array")
            .clone()
    }

    /// The run's row once its status is set.
    async fn ended(&mut self, id: &Value) -> Value {
        let deadline = tokio::time::Instant::now() + WAIT;
        loop {
            let listed = self.list().await;
            let row = listed
                .iter()
                .find(|row| &field(row, "id") == id)
                .expect("the run is listed")
                .clone();
            if !field(&row, "status").is_nil() {
                return row;
            }
            assert!(tokio::time::Instant::now() < deadline, "{row} never ended");
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}

/// A daemon that runs `FAKE_RUBY` for ruby, with `env` and nothing else of the test's own.
async fn daemon_with(mode: &str, env: &[(&str, &str)]) -> Daemon {
    spawned(mode, env, false).await
}

/// As [`daemon_with`], with a phone relay, so the daemon may be handed an ntfy topic.
async fn daemon_with_relay(mode: &str, env: &[(&str, &str)]) -> Daemon {
    spawned(mode, env, true).await
}

async fn spawned(mode: &str, env: &[(&str, &str)], relay: bool) -> Daemon {
    let dir = tempfile::tempdir().expect("tempdir");
    let ruby = dir.path().join("ruby");
    std::fs::write(&ruby, FAKE_RUBY).expect("write the fake ruby");
    std::fs::set_permissions(&ruby, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    std::fs::create_dir(dir.path().join("probe")).expect("the probe dir");
    std::fs::create_dir_all(dir.path().join("project").join(".git")).expect("a project");
    let probe = dir.path().join("probe");
    let mut command = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"));
    command
        .arg("--socket")
        .arg(dir.path().join("daemon.sock"))
        .arg("--trace")
        .arg(dir.path().join("daemon.trace"))
        .arg("--ruby")
        .arg(&ruby)
        .arg("--lain")
        .arg(dir.path().join("exe-lain"))
        .arg("--runs-dir")
        .arg(dir.path().join("state").join("runs"))
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("PROBE", &probe)
        .env("PROBE_MODE", mode)
        .env("HELPER_SOCKET", dir.path().join("daemon.sock"))
        .env("DAEMON_LAUNCH_DIGEST", "abc")
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    if relay {
        command
            .args(["--relay", &free_loopback_port(), "--devices-file"])
            .arg(devices_file(dir.path()));
    }
    let child = command.spawn().expect("spawn the daemon");
    let pid = child.id().expect("daemon pid");
    let stream = served_by(pid, &dir.path().join("daemon.sock")).await;
    Daemon { child, dir, stream }
}

/// An empty 0600 devices file alone in its 0700 directory, as the relay requires.
fn devices_file(dir: &Path) -> PathBuf {
    let remote = dir.join("remote");
    std::fs::create_dir(&remote).expect("the devices dir");
    std::fs::set_permissions(&remote, std::fs::Permissions::from_mode(0o700)).expect("chmod");
    let devices = remote.join("devices");
    std::fs::write(&devices, "").expect("the devices file");
    std::fs::set_permissions(&devices, std::fs::Permissions::from_mode(0o600)).expect("chmod");
    devices
}

fn free_loopback_port() -> String {
    std::net::TcpListener::bind("127.0.0.1:0")
        .expect("bind")
        .local_addr()
        .expect("addr")
        .to_string()
}

fn mode_of(path: &Path) -> u32 {
    std::fs::metadata(path)
        .expect("metadata")
        .permissions()
        .mode()
        & 0o777
}

fn trace_of(daemon: &Daemon) -> String {
    std::fs::read_to_string(daemon.dir.path().join("daemon.trace")).unwrap_or_default()
}

async fn daemon(mode: &str) -> Daemon {
    daemon_with(mode, &[]).await
}

fn encoded(request: &Value) -> Vec<u8> {
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, request).expect("encode");
    bytes
}

fn call_frame(method: &str, params: Vec<Value>) -> Value {
    Value::Array(vec![
        Value::from(0),
        Value::from(1),
        Value::from(method),
        Value::Array(params),
    ])
}

async fn try_request(
    stream: &mut UnixStream,
    method: &str,
    params: Vec<Value>,
    wait: Duration,
) -> Result<(Value, Value), String> {
    stream
        .write_all(&encoded(&call_frame(method, params)))
        .await
        .map_err(|error| error.to_string())?;
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0u8; 4096];
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

async fn request(stream: &mut UnixStream, method: &str, params: Vec<Value>) -> (Value, Value) {
    try_request(stream, method, params, WAIT)
        .await
        .unwrap_or_else(|error| panic!("{method}: {error}"))
}

async fn served_by(pid: u32, socket: &Path) -> UnixStream {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Ok(mut stream) = UnixStream::connect(socket).await
            && let Ok((_, result)) =
                try_request(&mut stream, "ping", vec![], Duration::from_millis(200)).await
            && result.as_map().is_some()
            && field(&result, "pid") == Value::from(pid)
        {
            return stream;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the daemon never answered on {}",
            socket.display()
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn field(map: &Value, name: &str) -> Value {
    map.as_map()
        .unwrap_or_else(|| panic!("{map} is not a map"))
        .iter()
        .find(|(key, _)| key.as_str() == Some(name))
        .map(|(_, value)| value.clone())
        .unwrap_or_else(|| panic!("no {name} in {map}"))
}

fn map(fields: &[(&str, Value)]) -> Value {
    Value::Map(
        fields
            .iter()
            .map(|(key, value)| (Value::from(*key), value.clone()))
            .collect(),
    )
}

fn epic(root: &Path, slug: &str) -> Value {
    map(&[
        ("kind", Value::from("epic")),
        ("root", Value::from(root.to_str().expect("a utf-8 root"))),
        ("args", map(&[("slug", Value::from(slug))])),
    ])
}

fn bare(kind: &str, root: &Path) -> Value {
    map(&[
        ("kind", Value::from(kind)),
        ("root", Value::from(root.to_str().expect("a utf-8 root"))),
    ])
}

async fn appeared(path: &Path) -> String {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        if let Ok(text) = std::fs::read_to_string(path)
            && !text.is_empty()
        {
            return text;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "{} never appeared",
            path.display()
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn pgid_of(pid: u32) -> u32 {
    let output = std::process::Command::new("ps")
        .args(["-o", "pgid=", "-p", &pid.to_string()])
        .output()
        .expect("run ps");
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("no pgid for {pid}"))
}

fn alive(pid: u32) -> bool {
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid as i32), None).is_ok()
}

fn refusal(error: &Value) -> String {
    error
        .as_str()
        .unwrap_or_else(|| panic!("{error} is not a refusal"))
        .to_string()
}

#[tokio::test]
async fn daemon_info_reports_no_live_runs_before_one_starts_and_1_while_it_runs() {
    let mut daemon = daemon("group").await;
    assert_eq!(Value::from(0), field(&daemon.info().await, "live_runs"));

    let project = daemon.project();
    let (error, run) = daemon.start(bare("chores", &project)).await;
    assert_eq!(Value::Nil, error);
    assert_eq!(Value::from(1), field(&daemon.info().await, "live_runs"));

    let (error, _) = daemon
        .request("run.stop", vec![map(&[("id", field(&run, "id"))])])
        .await;
    assert_eq!(Value::Nil, error);
    assert_eq!(Value::from(0), field(&daemon.info().await, "live_runs"));
}

#[tokio::test]
async fn an_epic_run_is_its_own_chat_in_its_own_group_with_its_output_in_its_log() {
    let mut daemon = daemon_with_relay(
        "group",
        &[
            ("ANTHROPIC_API_KEY", "sk-test"),
            ("DAEMON_NTFY_TOPIC", "https://ntfy.example/t"),
        ],
    )
    .await;
    let root = daemon.project().canonicalize().expect("the project");
    let (error, run) = daemon.start(epic(&root, "research-x")).await;
    assert_eq!(Value::Nil, error);

    let argv = appeared(&daemon.probe().join("argv")).await;
    let root_text = root.to_str().expect("utf-8").to_string();
    let lain = daemon.lain().to_str().expect("utf-8").to_string();
    assert_eq!(
        vec![
            lain.as_str(),
            "chat",
            "--root",
            &root_text,
            "--cwd",
            &root_text,
            "--non-interactive",
            "--approval",
            "auto",
            "--human",
            "remote",
            "--epic",
            "research-x",
            "--prompt",
            "/implement-epic research-x",
        ],
        argv.trim_end_matches('\0').split('\0').collect::<Vec<_>>()
    );
    assert_eq!(
        root_text,
        appeared(&daemon.probe().join("cwd")).await.trim()
    );

    let pid = field(&run, "pid").as_u64().expect("a pid") as u32;
    assert_eq!(pid, pgid_of(pid), "the run leads its own group");
    assert_ne!(pgid_of(daemon.child.id().expect("daemon pid")), pid);

    let env = appeared(&daemon.probe().join("env")).await;
    let names: Vec<&str> = env
        .lines()
        .filter_map(|line| line.split_once('=').map(|(name, _)| name))
        .collect();
    assert!(names.contains(&"ANTHROPIC_API_KEY"), "{names:?}");
    for withheld in ["DAEMON_NTFY_TOPIC", "DAEMON_LAUNCH_DIGEST"] {
        assert!(
            !names.contains(&withheld),
            "{withheld} reached the run: {names:?}"
        );
    }

    let log = PathBuf::from(field(&run, "log").as_str().expect("a log path"));
    assert_eq!(
        daemon.runs().join(format!(
            "{}.log",
            field(&run, "id").as_str().expect("an id")
        )),
        log
    );
    assert_eq!(0o600, mode_of(&log), "the log is the owner's alone");
    assert_eq!(
        0o700,
        mode_of(&daemon.runs()),
        "the runs dir is the owner's alone"
    );
    let written = appeared(&log).await;
    let deadline = tokio::time::Instant::now() + WAIT;
    let mut written = written;
    while !(written.contains("to-stdout") && written.contains("to-stderr")) {
        assert!(tokio::time::Instant::now() < deadline, "{written}");
        tokio::time::sleep(Duration::from_millis(25)).await;
        written = std::fs::read_to_string(&log).expect("the log");
    }
    assert_eq!(Value::from("epic"), field(&run, "kind"));
    assert_eq!(Value::from("research-x"), field(&run, "slug"));

    let (error, _) = daemon
        .request("run.stop", vec![map(&[("id", field(&run, "id"))])])
        .await;
    assert_eq!(Value::Nil, error);
}

#[tokio::test]
async fn an_unknown_kind_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let (error, _) = daemon.start(bare("shell", &project)).await;
    assert!(refusal(&error).contains("\"shell\""), "{error}");
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn a_start_naming_its_own_argv_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let mut start = bare("chores", &project);
    if let Value::Map(fields) = &mut start {
        fields.push((
            Value::from("argv"),
            Value::Array(vec![Value::from("/bin/sh")]),
        ));
    }
    let (error, _) = daemon.start(start).await;
    assert!(refusal(&error).contains("argv"), "{error}");
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn a_start_naming_its_own_approval_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let mut start = bare("chores", &project);
    if let Value::Map(fields) = &mut start {
        fields.push((Value::from("approval"), Value::from("bypass")));
    }
    let (error, _) = daemon.start(start).await;
    assert!(refusal(&error).contains("approval"), "{error}");
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn a_start_naming_its_own_env_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let mut start = bare("chores", &project);
    if let Value::Map(fields) = &mut start {
        fields.push((
            Value::from("env"),
            map(&[("LD_PRELOAD", Value::from("/x.so"))]),
        ));
    }
    let (error, _) = daemon.start(start).await;
    assert!(refusal(&error).contains("env"), "{error}");
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn an_arg_the_kind_does_not_take_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let starts = [
        map(&[
            ("kind", Value::from("epic")),
            ("root", Value::from(project.to_str().expect("utf-8"))),
            (
                "args",
                map(&[
                    ("slug", Value::from("x")),
                    ("approval", Value::from("bypass")),
                ]),
            ),
        ]),
        map(&[
            ("kind", Value::from("chores")),
            ("root", Value::from(project.to_str().expect("utf-8"))),
            ("args", map(&[("prompt", Value::from("rm -rf /"))])),
        ]),
    ];
    for start in starts {
        let (error, _) = daemon.start(start.clone()).await;
        assert!(!error.is_nil(), "{start} was accepted");
    }
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn a_slug_outside_a_to_z_0_to_9_and_dash_is_refused() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    for slug in ["", "-x", "../x", "Research", "a b", "a/b", "x;rm", "é"] {
        let (error, _) = daemon.start(epic(&project, slug)).await;
        assert!(
            refusal(&error).contains("[a-z0-9][a-z0-9-]*"),
            "{slug:?}: {error}"
        );
    }
    let (error, _) = daemon
        .start(map(&[
            ("kind", Value::from("epic")),
            ("root", Value::from(project.to_str().expect("utf-8"))),
        ]))
        .await;
    assert!(!error.is_nil(), "an epic with no slug was accepted");
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn a_root_with_no_lain_project_marker_is_refused() {
    let mut daemon = daemon("exit3").await;
    let bare_dir = daemon.dir.path().join("plain");
    std::fs::create_dir(&bare_dir).expect("a plain dir");
    let file = daemon.dir.path().join("a-file");
    std::fs::write(&file, "").expect("a file");
    let marked_inside = daemon.dir.path().join("nested");
    std::fs::create_dir_all(marked_inside.join("deeper").join(".lain")).expect("a nested marker");
    let file_marker = daemon.dir.path().join("file-marker");
    std::fs::create_dir(&file_marker).expect("a dir");
    std::fs::write(file_marker.join(".lain"), "").expect("a .lain that is a file");
    for root in [
        file_marker,
        bare_dir.clone(),
        file,
        daemon.dir.path().join("missing"),
        marked_inside,
        PathBuf::from("project"),
    ] {
        let (error, _) = daemon.start(bare("chores", &root)).await;
        assert!(!error.is_nil(), "{} was accepted", root.display());
    }
    let (error, _) = daemon.start(bare("chores", &bare_dir)).await;
    assert!(refusal(&error).contains("no .lain or .git"), "{error}");
    assert!(daemon.list().await.is_empty());

    std::fs::create_dir(bare_dir.join(".lain")).expect("a .lain marker");
    let (error, run) = daemon.start(bare("chores", &bare_dir)).await;
    assert_eq!(Value::Nil, error, "a .lain marker is a project");
    daemon.ended(&field(&run, "id")).await;
}

#[tokio::test]
async fn a_daemon_started_without_run_settings_refuses_every_run() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::create_dir_all(dir.path().join(".git")).expect("a project");
    let child = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.path().join("daemon.sock"))
        .env("DAEMON_LAUNCH_DIGEST", "abc")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    let mut stream = served_by(child.id().expect("pid"), &dir.path().join("daemon.sock")).await;
    let (error, _) = request(&mut stream, "run.start", vec![bare("chores", dir.path())]).await;
    assert!(refusal(&error).contains("--ruby"), "{error}");
}

#[tokio::test]
async fn a_run_that_exits_3_is_listed_with_status_3_and_its_log() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let (error, run) = daemon.start(bare("review-poll", &project)).await;
    assert_eq!(Value::Nil, error);
    let row = daemon.ended(&field(&run, "id")).await;
    assert_eq!(Value::from(3), field(&row, "status"));
    assert_eq!(field(&run, "log"), field(&row, "log"));
    assert_eq!(Value::from("review-poll"), field(&row, "kind"));
    assert_eq!(Value::from(0), field(&daemon.info().await, "live_runs"));
    let argv = appeared(&daemon.probe().join("argv")).await;
    assert_eq!(
        vec![daemon.lain().to_str().expect("utf-8"), "queue", "poll"],
        argv.trim_end_matches('\0').split('\0').collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn a_chores_run_drains_the_projects_todos() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let (error, run) = daemon.start(bare("chores", &project)).await;
    assert_eq!(Value::Nil, error);
    daemon.ended(&field(&run, "id")).await;
    let argv = appeared(&daemon.probe().join("argv")).await;
    assert_eq!(
        vec![daemon.lain().to_str().expect("utf-8"), "todos", "drain"],
        argv.trim_end_matches('\0').split('\0').collect::<Vec<_>>()
    );
}

#[tokio::test]
async fn a_run_that_registered_leaves_the_registry_when_it_exits() {
    let exe = std::env::current_exe().expect("this test binary");
    let mut daemon = daemon_with(
        "register",
        &[
            ("HELPER_EXE", exe.to_str().expect("utf-8")),
            ("HELPER_NAME", HELPER),
        ],
    )
    .await;
    let project = daemon.project();
    let (error, run) = daemon.start(bare("chores", &project)).await;
    assert_eq!(Value::Nil, error);

    let deadline = tokio::time::Instant::now() + WAIT;
    while daemon.sessions().await.is_empty() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the run never registered; its log: {:?}",
            std::fs::read_to_string(field(&run, "log").as_str().expect("log"))
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    std::fs::write(daemon.probe().join("release"), "").expect("release the run");

    let row = daemon.ended(&field(&run, "id")).await;
    assert_eq!(Value::from(3), field(&row, "status"));
    assert!(daemon.sessions().await.is_empty());
}

/// Run by the fake ruby under `register`, as the run itself: a no-op anywhere else.
#[test]
fn a_run_helper_registers_then_exits_3() {
    let (Ok(probe), Ok(socket)) = (std::env::var("PROBE"), std::env::var("HELPER_SOCKET")) else {
        return;
    };
    let register = lain_wire::Register {
        session_id: "headless".to_string(),
        pid: std::process::id(),
        host: "rainbow".to_string(),
        root: "/work".to_string(),
        cwd: "/work".to_string(),
        input_socket: None,
        journal: None,
        attended: false,
        started_at: "2026-11-17T10:00:00Z".to_string(),
    };
    let bytes = lain_wire::encode(&register).expect("encode");
    let register = rmpv::decode::read_value(&mut bytes.as_slice()).expect("a value");
    let mut stream = std::os::unix::net::UnixStream::connect(socket).expect("connect");
    stream
        .write_all(&encoded(&call_frame("session.register", vec![register])))
        .expect("send");
    let mut buffer = Vec::new();
    let reply = loop {
        let mut chunk = [0u8; 512];
        let read = stream.read(&mut chunk).expect("read");
        assert!(read > 0, "the daemon hung up");
        buffer.extend_from_slice(&chunk[..read]);
        if let Ok(Value::Array(reply)) = rmpv::decode::read_value(&mut &buffer[..]) {
            break reply;
        }
    };
    if !reply[2].is_nil() {
        std::process::exit(4);
    }
    let release = Path::new(&probe).join("release");
    for _ in 0..1000 {
        if release.exists() {
            std::process::exit(3);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    std::process::exit(5);
}

#[tokio::test]
async fn stopping_a_run_ends_its_whole_group() {
    let mut daemon = daemon("group").await;
    let project = daemon.project();
    let (error, run) = daemon.start(bare("chores", &project)).await;
    assert_eq!(Value::Nil, error);
    let grandchild: u32 = appeared(&daemon.probe().join("grandchild"))
        .await
        .trim()
        .parse()
        .expect("a pid");
    assert!(alive(grandchild));

    let (error, stopped) = daemon
        .request("run.stop", vec![map(&[("id", field(&run, "id"))])])
        .await;
    assert_eq!(Value::Nil, error);
    assert_eq!(Value::from(128 + 15), field(&stopped, "status"));
    let trace = trace_of(&daemon);
    let signalled: Vec<&str> = trace
        .lines()
        .filter(|line| line.contains("signalled a run's group"))
        .collect();
    assert_eq!(1, signalled.len(), "{trace}");
    assert!(signalled[0].contains("SIGTERM"), "{trace}");
    let deadline = tokio::time::Instant::now() + WAIT;
    while alive(grandchild) {
        assert!(
            tokio::time::Instant::now() < deadline,
            "the group outlived its stop"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn stopping_a_run_that_is_not_listed_is_refused() {
    let mut daemon = daemon("exit3").await;
    let (error, _) = daemon
        .request("run.stop", vec![map(&[("id", Value::from("nope"))])])
        .await;
    assert!(refusal(&error).contains("nope"), "{error}");
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn the_relay_worker_never_inherits_a_secret() {
    let dir = tempfile::tempdir().expect("tempdir");
    let remote = dir.path().join("remote");
    std::fs::create_dir(&remote).expect("the devices dir");
    std::fs::set_permissions(&remote, std::fs::Permissions::from_mode(0o700)).expect("chmod");
    let devices = remote.join("devices");
    std::fs::write(&devices, "").expect("the devices file");
    std::fs::set_permissions(&devices, std::fs::Permissions::from_mode(0o600)).expect("chmod");
    let listen = std::net::TcpListener::bind("127.0.0.1:0")
        .expect("bind")
        .local_addr()
        .expect("addr")
        .to_string();
    let child = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-daemon"))
        .arg("--socket")
        .arg(dir.path().join("daemon.sock"))
        .args(["--relay", &listen, "--devices-file"])
        .arg(&devices)
        .env("DAEMON_LAUNCH_DIGEST", "abc")
        .env("ANTHROPIC_API_KEY", "sk-test")
        .env("GH_TOKEN", "ghp-test")
        .env("SSH_AUTH_SOCK", "/tmp/agent.sock")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    let pid = child.id().expect("pid");
    let _stream = served_by(pid, &dir.path().join("daemon.sock")).await;

    let deadline = tokio::time::Instant::now() + WAIT;
    let worker = loop {
        if let [worker] = children_of(pid)[..] {
            break worker;
        }
        assert!(tokio::time::Instant::now() < deadline, "no relay worker");
        tokio::time::sleep(Duration::from_millis(25)).await;
    };
    let environment = std::fs::read(format!("/proc/{worker}/environ")).expect("read environ");
    let names: Vec<String> = String::from_utf8_lossy(&environment)
        .split('\0')
        .filter_map(|entry| Some(entry.split_once('=')?.0.to_string()))
        .collect();
    for secret in ["ANTHROPIC_API_KEY", "GH_TOKEN", "SSH_AUTH_SOCK"] {
        assert!(
            !names.iter().any(|name| name == secret),
            "the worker inherited {secret}"
        );
    }
}

#[cfg(target_os = "linux")]
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

#[tokio::test]
async fn a_run_started_through_a_symlink_carries_the_real_root() {
    let mut daemon = daemon("exit3").await;
    let link = daemon.dir.path().join("link");
    std::os::unix::fs::symlink(daemon.project(), &link).expect("a symlink");
    let (error, run) = daemon.start(epic(&link, "research-x")).await;
    assert_eq!(Value::Nil, error);
    daemon.ended(&field(&run, "id")).await;
    let real = daemon.project().canonicalize().expect("the project");
    let argv = appeared(&daemon.probe().join("argv")).await;
    let argv: Vec<&str> = argv.trim_end_matches('\0').split('\0').collect();
    assert_eq!(
        Some(&real.to_str().expect("utf-8")),
        argv.get(3),
        "{argv:?}"
    );
    assert_eq!(
        Value::from(real.to_str().expect("utf-8")),
        field(&run, "root")
    );
}

#[tokio::test]
async fn a_log_path_already_taken_is_refused_and_its_target_left_alone() {
    let mut daemon = daemon("exit3").await;
    let runs = daemon.runs();
    std::fs::create_dir_all(&runs).expect("the runs dir");
    let target = daemon.dir.path().join("target");
    std::fs::write(&target, "untouched").expect("a target");
    let pid = daemon.child.id().expect("daemon pid");
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("after the epoch")
        .as_secs();
    for since in now.saturating_sub(2)..now + 10 {
        std::os::unix::fs::symlink(&target, runs.join(format!("{since}-{pid}-1.log")))
            .expect("plant a symlink");
    }
    let project = daemon.project();
    let (error, _) = daemon.start(bare("chores", &project)).await;
    assert!(refusal(&error).contains("could not open"), "{error}");
    assert_eq!(
        "untouched",
        std::fs::read_to_string(&target).expect("the target")
    );
    assert!(daemon.list().await.is_empty());
}

#[tokio::test]
async fn stopping_a_run_that_has_ended_signals_nothing() {
    let mut daemon = daemon("exit3").await;
    let project = daemon.project();
    let (error, run) = daemon.start(bare("chores", &project)).await;
    assert_eq!(Value::Nil, error);
    daemon.ended(&field(&run, "id")).await;

    let (error, stopped) = daemon
        .request("run.stop", vec![map(&[("id", field(&run, "id"))])])
        .await;
    assert_eq!(Value::Nil, error);
    assert_eq!(Value::from(3), field(&stopped, "status"));
    let trace = trace_of(&daemon);
    assert!(trace.contains("a run ended"), "{trace}");
    assert!(!trace.contains("a run's group"), "{trace}");
}

#[tokio::test]
async fn a_refused_root_is_named_whole() {
    let mut daemon = daemon("exit3").await;
    let long = daemon
        .dir
        .path()
        .join("a".repeat(200))
        .join("b".repeat(200));
    let (error, _) = daemon.start(bare("chores", &long)).await;
    assert!(
        refusal(&error).contains(long.to_str().expect("utf-8")),
        "{error}"
    );
}

#[tokio::test]
async fn daemon_info_says_whether_the_daemon_holds_the_provider_key_never_its_value() {
    let mut keyed = daemon_with("exit3", &[("ANTHROPIC_API_KEY", "sk-test-value")]).await;
    let info = keyed.info().await;
    assert_eq!(Value::from(true), field(&info, "provider_key"));
    assert!(!info.to_string().contains("sk-test-value"), "{info}");

    let mut keyless = daemon("exit3").await;
    assert_eq!(
        Value::from(false),
        field(&keyless.info().await, "provider_key")
    );
}
