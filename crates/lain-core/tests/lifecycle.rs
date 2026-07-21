//! Daemon lifecycle against the REAL binary (`CARGO_BIN_EXE_lain-core`, which
//! cargo builds fresh for integration tests -- a path-derived
//! `target/debug/lain-core` can be stale under `cargo test`). Signal handling
//! is process-wide state, so it cannot be observed from an in-process server.
#![forbid(unsafe_code)]

use std::process::Stdio;
use std::time::Duration;

use rmpv::Value;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

/// One encoded msgpack-RPC frame onto the socket; these tests never need to
/// read a response (the pidfile is the observable).
async fn send_frame(stream: &mut UnixStream, frame: &Value) {
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

#[tokio::test]
async fn sigterm_with_a_child_in_flight_kills_the_child_before_exit() {
    // probe_lifecycle's orphan: a daemon dying to an unhandled SIGTERM skips
    // every Drop, so kill_on_drop never fires and the child runs on.
    let dir = tempfile::tempdir().expect("tempdir");
    let socket = dir.path().join("core.sock");
    let mut daemon = tokio::process::Command::new(env!("CARGO_BIN_EXE_lain-core"))
        .arg(&socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn the daemon");
    assert!(
        wait_until(5000, || socket.exists()).await,
        "daemon never bound its socket"
    );

    let mut client = UnixStream::connect(&socket).await.expect("connect");
    let pidfile = dir.path().join("pid");
    let script = format!("echo $$ > {} && exec sleep 30", pidfile.display());
    send_frame(&mut client, &exec_request(1, &script)).await;
    let wrote = wait_until(5000, || {
        std::fs::read_to_string(&pidfile).is_ok_and(|pid| !pid.trim().is_empty())
    })
    .await;
    assert!(wrote, "child never wrote its pidfile");
    let child_pid: u32 = std::fs::read_to_string(&pidfile)
        .expect("pidfile")
        .trim()
        .parse()
        .expect("pid");

    let daemon_pid = daemon.id().expect("daemon pid").to_string();
    let term = std::process::Command::new("kill")
        .args(["-TERM", &daemon_pid])
        .status()
        .expect("send SIGTERM");
    assert!(term.success());
    tokio::time::timeout(Duration::from_secs(5), daemon.wait())
        .await
        .expect("daemon did not exit on SIGTERM")
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
        "the in-flight child survived the daemon's SIGTERM -- orphaned \
         (kill_on_drop never ran)"
    );
}
