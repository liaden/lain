//! The daemon's bind scheme, against the REAL binary (`CARGO_BIN_EXE_lain-core`,
//! which cargo builds fresh for integration tests). argv parsing, port policy,
//! and the port-file publish are all process-level behaviour, so an in-process
//! server cannot observe any of them.
//!
//! Most scenarios need a working `AF_VSOCK` on the host. They SKIP rather than
//! fail when it is absent, because `cargo test` runs unconditionally in the
//! pre-commit hook and a hard failure would break every Rust commit on a host
//! without vsock.
//!
//! **The limitation that comes with that, stated plainly:** Rust has no
//! RSpec-style skip, so a skipped scenario reports `ok` in the default output
//! and is indistinguishable there from one that ran. `cargo test -- --nocapture`
//! shows the `SKIP <scenario>` lines, and `LAIN_VSOCK_REQUIRED=1` converts every
//! skip into a failure -- that is how a host that is *supposed* to have vsock
//! proves the coverage actually ran, mirroring the suite's `LAIN_INTEGRATION=1`
//! idiom. Three scenarios never skip at all (`a_bare_path_still_binds_a_unix_socket`,
//! `a_malformed_scheme_is_refused_in_words_at_startup`,
//! `the_vsock_scheme_without_a_tracing_path_is_a_usage_error`), so a vsock-less
//! host is never a host with zero coverage of the scheme.
#![forbid(unsafe_code)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio_vsock::{VMADDR_CID_ANY, VMADDR_CID_LOCAL, VsockAddr, VsockListener, VsockStream};

/// `VMADDR_PORT_ANY`. Not re-exported by tokio-vsock, and NOT 0 -- port 0 and
/// every port below 1024 are privileged on vsock and raise EACCES, so the TCP
/// habit of "bind 0 for ephemeral" is exactly wrong here.
const VMADDR_PORT_ANY: u32 = u32::MAX;

// --- host capability ------------------------------------------------------

/// Can this host bind an `AF_VSOCK` socket? Answered by trying it, never by
/// parsing `lsmod`: `vsock_loopback` autoloads on the first socket(2), so the
/// module table is stale until something has already asked.
///
/// `async` with nothing awaited, deliberately: `VsockListener::bind` registers
/// the fd with the reactor and panics outside a runtime, so the signature is
/// where that requirement is stated.
async fn vsock_usable() -> bool {
    VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VMADDR_PORT_ANY)).is_ok()
}

/// True when the caller should return early. Prints the reason so the skip is
/// visible under `--nocapture`, and honours `LAIN_VSOCK_REQUIRED=1` by failing
/// instead -- a silent pass is not an acceptable skip.
async fn skip_without_vsock(scenario: &str) -> bool {
    if vsock_usable().await {
        return false;
    }
    assert!(
        std::env::var_os("LAIN_VSOCK_REQUIRED").is_none(),
        "LAIN_VSOCK_REQUIRED is set but this host cannot bind AF_VSOCK; \
         {scenario} could not run"
    );
    eprintln!("SKIP {scenario}: this host cannot bind AF_VSOCK");
    true
}

// --- driving the real binary ----------------------------------------------

/// A spawned `lain-core`, killed when it drops. Holds the tempdir so the
/// tracing file and its `.port` sibling outlive the spawn call.
struct Daemon {
    process: tokio::process::Child,
    dir: tempfile::TempDir,
}

impl Daemon {
    fn spawn(bind_spec: &str, dir: tempfile::TempDir) -> Self {
        let tracing_path = dir.path().join("trace.log");
        let process = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
            .arg(bind_spec)
            .arg(&tracing_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("spawn the daemon");
        Self { process, dir }
    }

    fn tracing_path(&self) -> PathBuf {
        self.dir.path().join("trace.log")
    }

    /// SIGTERM and reap, so a restart runs against a genuinely dead predecessor
    /// rather than racing one on its way out.
    async fn terminate(&mut self) {
        let pid = self.process.id().expect("daemon pid").to_string();
        let _ = std::process::Command::new("kill")
            .args(["-TERM", &pid])
            .status();
        let _ = self.process.wait().await;
    }

    /// The readiness signal: the port file's EXISTENCE, published only after
    /// the bind succeeded.
    fn port_path(&self) -> PathBuf {
        self.dir.path().join("trace.log.port")
    }

    async fn await_port(&self) -> u32 {
        let path = self.port_path();
        assert!(
            wait_until(5000, || path.exists()).await,
            "daemon never published its port to {}",
            path.display()
        );
        let text = std::fs::read_to_string(&path).expect("read the port file");
        parse_port(&text)
    }
}

/// The consumer's half of the contract, spelled out so the test breaks if the
/// daemon ever pads, prefixes, or decorates the number. Ruby's `Integer` reads
/// a leading zero as octal, so "no leading zeros" is a real requirement and not
/// a style note.
fn parse_port(text: &str) -> u32 {
    assert!(
        !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()),
        "the port file must hold bare decimal digits, got {text:?}"
    );
    assert!(
        text == "0" || !text.starts_with('0'),
        "the port file must not be zero-padded (Ruby reads a leading zero as octal), got {text:?}"
    );
    text.parse().expect("the port file must fit in a u32")
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

async fn tracing_says(path: &Path, needle: &str) -> bool {
    wait_until(5000, || {
        std::fs::read_to_string(path).is_ok_and(|log| log.contains(needle))
    })
    .await
}

// --- the protocol, over whatever carries it -------------------------------

/// One `ping`, one reply, generic over the connection: the whole point of the
/// scheme is that the protocol above it does not change.
async fn ping<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Value {
    let request = Value::Array(vec![
        Value::from(0),
        Value::from(1),
        Value::from("ping"),
        Value::Array(vec![]),
    ]);
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &request).expect("encode the request");
    stream.write_all(&bytes).await.expect("send the request");

    // msgpack is self-delimiting, so "a whole value decoded" is the frame
    // boundary -- there is nothing else to wait for.
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0u8; 512];
        let read = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
            .await
            .expect("timed out waiting for the ping reply")
            .expect("read the ping reply");
        assert!(read > 0, "connection closed before a reply arrived");
        buffer.extend_from_slice(&chunk[..read]);
        if let Ok(value) = rmpv::decode::read_value(&mut &buffer[..]) {
            return value;
        }
    }
}

/// `[1, msgid, error, result]` -- pull `version` out of the result map.
fn version_of(reply: &Value) -> String {
    let Value::Array(elements) = reply else {
        panic!("reply is not an array: {reply}")
    };
    assert_eq!(elements[2], Value::Nil, "ping answered with an error");
    let Value::Map(result) = &elements[3] else {
        panic!("ping result is not a map: {reply}")
    };
    result
        .iter()
        .find(|(key, _)| key.as_str() == Some("version"))
        .and_then(|(_, value)| value.as_str())
        .expect("ping result carries a version")
        .to_string()
}

/// The answering daemon's own pid, which is the only field in a ping reply that
/// distinguishes one daemon from another.
fn pid_of(reply: &Value) -> u32 {
    let Value::Array(elements) = reply else {
        panic!("reply is not an array: {reply}")
    };
    let Value::Map(result) = &elements[3] else {
        panic!("ping result is not a map: {reply}")
    };
    result
        .iter()
        .find(|(key, _)| key.as_str() == Some("pid"))
        .and_then(|(_, value)| value.as_u64())
        .and_then(|pid| u32::try_from(pid).ok())
        .expect("ping result carries a pid")
}

async fn ping_over_vsock(port: u32) -> Value {
    let mut stream = VsockStream::connect(VsockAddr::new(VMADDR_CID_LOCAL, port))
        .await
        .expect("connect over AF_VSOCK");
    ping(&mut stream).await
}

// --- scenarios ------------------------------------------------------------

/// Scenario: a bare path still binds a Unix socket.
#[tokio::test]
async fn a_bare_path_still_binds_a_unix_socket() {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let _daemon = Daemon::spawn(&socket.to_string_lossy(), dir);
    assert!(
        wait_until(5000, || socket.exists()).await,
        "daemon never bound its unix socket"
    );

    let mut stream = UnixStream::connect(&socket).await.expect("connect");
    let reply = ping(&mut stream).await;
    assert_eq!(version_of(&reply), env!("CARGO_PKG_VERSION"));
}

/// Scenario: a vsock scheme binds a vsock listener.
#[tokio::test]
async fn a_vsock_scheme_binds_a_vsock_listener() {
    if skip_without_vsock("a_vsock_scheme_binds_a_vsock_listener").await {
        return;
    }
    let daemon = Daemon::spawn("vsock:", tempfile::tempdir().expect("tempdir"));
    let port = daemon.await_port().await;

    let reply = ping_over_vsock(port).await;
    assert_eq!(version_of(&reply), env!("CARGO_PKG_VERSION"));
}

/// Scenario: the daemon makes its port discoverable.
///
/// "Recoverable by the process that started it" is asserted by dialling the
/// published port and checking the answering daemon's OWN PID. Weaker
/// discriminators do not work here: `peer_addr` merely echoes the address just
/// dialled, and on `vsock_loopback` a connect to a dead port SUCCEEDS
/// (Staleness section 4), so neither the connect nor the address can tell a
/// right port from a wrong one. Even the version cannot -- ephemeral ports
/// ascend, so an off-by-one port may well be a sibling test's daemon answering
/// with the identical version. Only the pid is unique to this process.
#[tokio::test]
async fn the_daemon_makes_its_port_discoverable() {
    if skip_without_vsock("the_daemon_makes_its_port_discoverable").await {
        return;
    }
    let daemon = Daemon::spawn("vsock:", tempfile::tempdir().expect("tempdir"));
    let port = daemon.await_port().await;
    assert!(port >= 1024, "an ephemeral vsock port is never privileged");
    assert_ne!(
        port, VMADDR_PORT_ANY,
        "VMADDR_PORT_ANY was reported verbatim; local_addr was never consulted"
    );

    let reply = ping_over_vsock(port).await;
    assert_eq!(version_of(&reply), env!("CARGO_PKG_VERSION"));
    assert_eq!(
        pid_of(&reply),
        daemon.process.id().expect("daemon pid"),
        "the published port is served by some other process; it is not this daemon's port"
    );
    assert_eq!(
        siblings(daemon.dir.path()),
        vec!["trace.log".to_string(), "trace.log.port".to_string()],
        "the publish left its staging file behind"
    );
}

/// Beyond the card's five: the published port file is never written through in
/// place. A torn read is a race no black-box test can provoke on demand, so
/// this pins the mechanism instead.
///
/// On POSIX a mode-0444 file can be RENAMED OVER -- rename needs write on the
/// containing directory, not on the victim -- but cannot be WRITTEN THROUGH.
/// A planted read-only port file therefore fails with EACCES the moment the
/// publish becomes a direct `fs::write`.
///
/// **Exactly what this does and does not discriminate**, so nobody reads more
/// into a green run than is there. It catches a plain `fs::write` to the final
/// path. It does NOT catch `remove_file` + `fs::write` (genuinely non-atomic,
/// and it passes), and it does NOT catch staging the temp file outside the
/// target directory (which breaks `rename(2)`'s same-filesystem requirement,
/// and passes here only because `/tmp` and the tempdir happen to share a
/// filesystem). The name says "never written through in place" because that is
/// the whole of the claim; atomicity itself rests on the code, reviewed.
#[tokio::test]
async fn the_port_file_is_never_written_through_in_place() {
    if skip_without_vsock("the_port_file_is_never_written_through_in_place").await {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let stale_path = dir.path().join("trace.log.port");
    let stale = "1";
    std::fs::write(&stale_path, stale).expect("plant a stale port file");
    std::fs::set_permissions(&stale_path, std::fs::Permissions::from_mode(0o444))
        .expect("make the stale port file read-only");

    // Existence cannot be the signal here -- the stale file already exists --
    // so wait for the content to turn over instead.
    let daemon = Daemon::spawn("vsock:", dir);
    assert!(
        wait_until(5000, || {
            std::fs::read_to_string(&stale_path).is_ok_and(|text| text != stale)
        })
        .await,
        "the daemon never replaced the read-only stale port file"
    );
    let port = parse_port(&std::fs::read_to_string(&stale_path).expect("read the port file"));
    assert_eq!(
        version_of(&ping_over_vsock(port).await),
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(
        siblings(daemon.dir.path()),
        vec!["trace.log".to_string(), "trace.log.port".to_string()],
        "the publish left its staging file behind"
    );
}

/// Sorted file names, so "no staging file survived" is one comparison.
fn siblings(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .expect("read the directory")
        .map(|entry| entry.expect("entry").file_name().to_string_lossy().into())
        .collect();
    names.sort();
    names
}

/// Scenario: two daemons started concurrently do not collide.
#[tokio::test]
async fn two_daemons_started_concurrently_do_not_collide() {
    if skip_without_vsock("two_daemons_started_concurrently_do_not_collide").await {
        return;
    }
    let first = Daemon::spawn("vsock:", tempfile::tempdir().expect("tempdir"));
    let second = Daemon::spawn("vsock:", tempfile::tempdir().expect("tempdir"));
    let (first_port, second_port) = tokio::join!(first.await_port(), second.await_port());
    assert_ne!(
        first_port, second_port,
        "both daemons claimed the same host-global vsock port"
    );

    // Both, after both bound: a port that only answers before the other daemon
    // starts would pass a sequential check and still have been displaced.
    assert_eq!(
        version_of(&ping_over_vsock(first_port).await),
        env!("CARGO_PKG_VERSION")
    );
    assert_eq!(
        version_of(&ping_over_vsock(second_port).await),
        env!("CARGO_PKG_VERSION")
    );
}

/// Scenario: a malformed scheme is refused in words at startup.
///
/// Needs no vsock support -- the argument is rejected before anything is bound,
/// so this scenario carries the scheme's coverage on a host without the kernel
/// transport.
#[tokio::test]
async fn a_malformed_scheme_is_refused_in_words_at_startup() {
    let mut daemon = Daemon::spawn("vsock:not-a-port", tempfile::tempdir().expect("tempdir"));
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.process.wait())
        .await
        .expect("daemon did not exit on a malformed scheme")
        .expect("daemon wait");
    assert_eq!(status.code(), Some(2), "a bad invocation is a usage error");
    assert!(
        tracing_says(&daemon.tracing_path(), "vsock:not-a-port").await,
        "the tracing file never named the offending argument"
    );
    assert!(
        !daemon.port_path().exists(),
        "a port file was published without a successful bind"
    );
}

/// Panel finding 4: the vsock scheme has nowhere to publish its port without a
/// tracing path, and that is a bad invocation rather than a runtime accident.
///
/// It used to fail as a side effect of `/dev/null.port.<pid>.tmp` being
/// unwritable in `/` -- which is a filesystem accident, not a rule, and one that
/// evaporates under the root uid a daemon inside a microVM guest generally
/// carries. Needs no vsock support: the refusal precedes the bind.
#[tokio::test]
async fn the_vsock_scheme_without_a_tracing_path_is_a_usage_error() {
    let mut daemon = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
        .arg("vsock:")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("the daemon did not exit without a tracing path")
        .expect("daemon wait");
    assert_eq!(
        status.code(),
        Some(2),
        "a vsock scheme with no tracing path is a usage error, not a bind error"
    );
}

/// Panel finding 1 (BLOCKER): the readiness signal must mean "THIS process
/// bound", so a previous generation's port file cannot outlive it.
///
/// Deterministic by construction -- the daemon is pointed at a port the test
/// already holds, so its bind CANNOT succeed. A stale port file that survives a
/// failed bind is a readiness signal for a daemon that never listened, and a
/// reader acting on it gets no refusal: a vsock connect to a dead port succeeds
/// on `vsock_loopback` (Staleness section 4), so the symptom is a handshake
/// timeout and a baffling silence.
#[tokio::test]
async fn a_stale_port_file_does_not_survive_a_failed_bind() {
    if skip_without_vsock("a_stale_port_file_does_not_survive_a_failed_bind").await {
        return;
    }
    let occupied = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VMADDR_PORT_ANY))
        .expect("hold a vsock port against the daemon");
    let taken = occupied.local_addr().expect("local address").port();

    let dir = tempfile::tempdir().expect("tempdir");
    let stale_path = dir.path().join("trace.log.port");
    std::fs::write(&stale_path, "2959000000").expect("plant a stale port file");

    let mut daemon = Daemon::spawn(&format!("vsock:{taken}"), dir);
    let status = tokio::time::timeout(Duration::from_secs(5), daemon.process.wait())
        .await
        .expect("the daemon did not exit though its port was already taken")
        .expect("daemon wait");
    assert_eq!(status.code(), Some(1), "a taken port is a bind error");
    assert!(
        !stale_path.exists(),
        "the dead daemon's port file outlived it, so existence no longer means a live bind"
    );
}

/// Panel finding 1, in the shape a reader actually meets it: `Child#tracing_path`
/// is a stable `runtime_dir/core-<project_hash>.log`, one per project and reused
/// every run, so anything modelled on it restarts onto its own leftovers.
///
/// **A residual window survives this fix and is NOT the daemon's to close --
/// escalated, see `.handback-T4.md`.** The pre-bind clear runs inside the daemon
/// process, so it cannot happen until fork/exec/runtime-init has finished.
/// Measured on this host: at t=0 after spawn the stale file is still present
/// with the dead port, and only by t=10ms does it hold the live one. A reader
/// that starts polling for EXISTENCE at spawn time -- which is exactly what
/// `VsockDaemon` does -- can therefore still read the previous generation's
/// port. Only the party that reuses the path can close that: it must unlink the
/// port file BEFORE spawning. This test consequently pins what the daemon does
/// own -- that a restart republishes its own port -- and deliberately does not
/// assert the window shut.
#[tokio::test]
async fn a_restart_on_the_same_tracing_path_republishes_its_own_port() {
    if skip_without_vsock("a_restart_on_the_same_tracing_path_republishes_its_own_port").await {
        return;
    }
    let mut first = Daemon::spawn("vsock:", tempfile::tempdir().expect("tempdir"));
    let dead_port = first.await_port().await;
    first.terminate().await;

    // Hold the dead daemon's port. The kernel REUSES a just-freed ephemeral
    // vsock port -- measured: a restart was handed the identical number back --
    // so "the republished port differs" is a sound assertion only while the old
    // one is unavailable. Skip rather than fail if something else claimed it
    // first; a race in the test's own setup is not a finding about the daemon.
    let Ok(_holder) = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, dead_port)) else {
        eprintln!(
            "SKIP a_restart_on_the_same_tracing_path_republishes_its_own_port: \
             another process took the freed port first"
        );
        return;
    };

    let restarted = Daemon::spawn("vsock:", first.dir);
    let port_path = restarted.port_path();
    assert!(
        wait_until(5000, || {
            std::fs::read_to_string(&port_path).is_ok_and(|text| text != dead_port.to_string())
        })
        .await,
        "the restarted daemon never republished over the stale port file"
    );
    let port = parse_port(&std::fs::read_to_string(&port_path).expect("read the port file"));
    assert_eq!(
        pid_of(&ping_over_vsock(port).await),
        restarted.process.id().expect("daemon pid"),
        "the republished port is not served by the restarted daemon"
    );
}
