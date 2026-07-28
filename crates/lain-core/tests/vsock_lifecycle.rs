//! The shutdown contract on the VSOCK path, against the REAL binary.
//!
//! `tests/lifecycle.rs` proves SIGTERM-reaps-the-in-flight-child over a Unix
//! socket only. T4 factored the `tokio::select!` into `serve_with` and
//! monomorphized it per scheme, so on the vsock listener the same contract was
//! asserted by reading rather than by testing. Adopted from the T4 review
//! panel's probe.
//!
//! Skips rather than fails on a host without `AF_VSOCK`, for the reason
//! `vsock_listen.rs` documents at length; `LAIN_VSOCK_REQUIRED=1` turns the skip
//! into a failure.
#![forbid(unsafe_code)]

use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::AsyncWriteExt;
use tokio_vsock::{VMADDR_CID_ANY, VMADDR_CID_LOCAL, VsockAddr, VsockListener, VsockStream};

const VMADDR_PORT_ANY: u32 = u32::MAX;

async fn skip_without_vsock(scenario: &str) -> bool {
    if VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VMADDR_PORT_ANY)).is_ok() {
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

/// Gone from /proc, or a zombie (dead, awaiting init's reap) -- either way the
/// process is no longer running.
fn dead_or_zombie(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        Err(_) => true,
        // The state field follows the ") " that closes comm (which may itself
        // contain parens, hence rsplit).
        Ok(stat) => stat
            .rsplit(") ")
            .next()
            .is_some_and(|rest| rest.starts_with('Z')),
    }
}

async fn send_frame(stream: &mut VsockStream, frame: &Value) {
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, frame).expect("encode the frame");
    stream.write_all(&bytes).await.expect("send the frame");
}

fn exec_request(msgid: u32, script: &str) -> Value {
    let argv = Value::Array(vec![
        Value::from("sh"),
        Value::from("-c"),
        Value::from(script),
    ]);
    let params = Value::Map(vec![(Value::from("argv"), argv)]);
    Value::Array(vec![
        Value::from(0),
        Value::from(msgid),
        Value::from("exec"),
        Value::Array(vec![params]),
    ])
}

/// The vsock twin of `tests/lifecycle.rs`: shutdown must go THROUGH the runtime
/// on this listener too, or `kill_on_drop` never fires and the in-flight child
/// is orphaned.
#[tokio::test]
async fn sigterm_over_vsock_kills_the_in_flight_child_before_exit() {
    if skip_without_vsock("sigterm_over_vsock_kills_the_in_flight_child_before_exit").await {
        return;
    }
    let dir = tempfile::tempdir().expect("tempdir");
    let tracing_path = dir.path().join("trace.log");
    let port_path = dir.path().join("trace.log.port");
    let mut daemon = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
        .arg("vsock:")
        .arg(&tracing_path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    assert!(
        wait_until(5000, || port_path.exists()).await,
        "daemon never published its vsock port"
    );
    let port: u32 = std::fs::read_to_string(&port_path)
        .expect("port file")
        .parse()
        .expect("port");

    let mut client = VsockStream::connect(VsockAddr::new(VMADDR_CID_LOCAL, port))
        .await
        .expect("connect over AF_VSOCK");
    let pidfile = dir.path().join("pid");
    let script = format!("echo $$ > {} && exec sleep 30", pidfile.display());
    send_frame(&mut client, &exec_request(1, &script)).await;
    assert!(
        wait_until(5000, || {
            std::fs::read_to_string(&pidfile).is_ok_and(|pid| !pid.trim().is_empty())
        })
        .await,
        "child never wrote its pidfile"
    );
    let child_pid: u32 = std::fs::read_to_string(&pidfile)
        .expect("pidfile")
        .trim()
        .parse()
        .expect("pid");

    let daemon_pid = daemon.id().expect("daemon pid").to_string();
    assert!(
        std::process::Command::new("kill")
            .args(["-TERM", &daemon_pid])
            .status()
            .expect("send SIGTERM")
            .success()
    );
    tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("daemon did not exit on SIGTERM over vsock")
        .expect("daemon wait");

    let child_gone = wait_until(3000, || dead_or_zombie(child_pid)).await;
    if !child_gone {
        // Do not leak a 30s sleep on a red run.
        let _ = std::process::Command::new("kill")
            .args(["-KILL", &child_pid.to_string()])
            .status();
    }
    assert!(
        child_gone,
        "the in-flight child survived the daemon's SIGTERM over vsock -- \
         serve_with's shutdown arm did not reach kill_on_drop on this listener"
    );
}
