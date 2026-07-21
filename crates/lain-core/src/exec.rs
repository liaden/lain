//! The `exec` method: spawn a subprocess, collect its output, enforce the
//! server-side timeout, and report `{stdout, stderr, exit_status, timed_out}`.
//! stdout/stderr are arbitrary bytes (msgpack `bin`, never `str`).

use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{ExitStatus, Stdio};
use std::time::Duration;

use rmpv::Value;
use thiserror::Error;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};
use tokio::sync::watch;
use tokio::task::JoinHandle;

/// One decoded `exec` request. `env` preserves wire order and the nil marker:
/// `Some` sets, `None` removes -- see [`merged_env`] for the contract.
///
/// Known protocol limitation, by design: argv, cwd, and env ride the wire as
/// msgpack `str`, so they must be valid UTF-8 -- OS-level non-UTF-8 bytes in a
/// command line or environment value are rejected loudly at decode
/// ([`ParamError`]), never lossy-converted in silence. Subprocess *output* is
/// `bin` and byte-clean; only the inputs carry this restriction. Revisit with
/// a bin-accepting param revision if a real caller ever needs one.
#[derive(Debug, Clone)]
pub(crate) struct ExecParams {
    pub(crate) argv: Vec<String>,
    pub(crate) cwd: Option<PathBuf>,
    pub(crate) env: Vec<(String, Option<String>)>,
    pub(crate) timeout_ms: Option<u64>,
}

#[derive(Debug)]
pub(crate) struct Outcome {
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) exit_status: i64,
    pub(crate) timed_out: bool,
}

#[derive(Debug, Error)]
pub(crate) enum ParamError {
    #[error("exec params must be a map")]
    NotMap,
    #[error("exec param keys must be strings")]
    KeyNotString,
    #[error("argv must be an array of strings")]
    Argv,
    #[error("argv must not be empty")]
    EmptyArgv,
    #[error("cwd must be a string")]
    Cwd,
    #[error("env must map string keys to string-or-nil values")]
    Env,
    #[error("timeout_ms must be a non-negative integer")]
    Timeout,
    #[error("unknown exec param {0:?}")]
    UnknownKey(String),
}

#[derive(Debug, Error)]
pub(crate) enum ExecError {
    // ParamError::EmptyArgv guards the wire path; this one guards direct
    // callers of run_with_base_env.
    #[error("argv must not be empty")]
    EmptyArgv,
    #[error("spawn failed: {0}")]
    Spawn(std::io::Error),
    #[error("waiting on the child failed: {0}")]
    Wait(std::io::Error),
}

impl ExecParams {
    pub(crate) fn from_value(value: &Value) -> Result<Self, ParamError> {
        let entries = value.as_map().ok_or(ParamError::NotMap)?;
        let empty = Self {
            argv: vec![],
            cwd: None,
            env: vec![],
            timeout_ms: None,
        };
        let params = entries.iter().try_fold(empty, |mut params, (key, value)| {
            let key = key.as_str().ok_or(ParamError::KeyNotString)?;
            params.apply(key, value)?;
            Ok(params)
        })?;
        if params.argv.is_empty() {
            return Err(ParamError::EmptyArgv);
        }
        Ok(params)
    }

    /// Unknown keys fail loudly: a typo'd param silently ignored would run the
    /// wrong command shape with no error.
    fn apply(&mut self, key: &str, value: &Value) -> Result<(), ParamError> {
        match key {
            "argv" => self.argv = string_array(value)?,
            "cwd" => self.cwd = optional_string(value, ParamError::Cwd)?.map(PathBuf::from),
            "env" => self.env = env_entries(value)?,
            "timeout_ms" => {
                self.timeout_ms = match value {
                    Value::Nil => None,
                    other => Some(other.as_u64().ok_or(ParamError::Timeout)?),
                }
            }
            unknown => return Err(ParamError::UnknownKey(unknown.to_string())),
        }
        Ok(())
    }
}

fn string_array(value: &Value) -> Result<Vec<String>, ParamError> {
    value
        .as_array()
        .ok_or(ParamError::Argv)?
        .iter()
        .map(|element| element.as_str().map(str::to_string).ok_or(ParamError::Argv))
        .collect()
}

fn optional_string(value: &Value, error: ParamError) -> Result<Option<String>, ParamError> {
    match value {
        Value::Nil => Ok(None),
        other => Ok(Some(other.as_str().map(str::to_string).ok_or(error)?)),
    }
}

/// Wire order is preserved so a later duplicate key wins, exactly as it would
/// applying the map's entries one by one.
fn env_entries(value: &Value) -> Result<Vec<(String, Option<String>)>, ParamError> {
    match value {
        Value::Nil => Ok(vec![]),
        other => other
            .as_map()
            .ok_or(ParamError::Env)?
            .iter()
            .map(|(key, value)| {
                let key = key.as_str().map(str::to_string).ok_or(ParamError::Env)?;
                // nil is remove, never empty-string (see merged_env).
                let value = match value {
                    Value::Nil => None,
                    set => Some(set.as_str().map(str::to_string).ok_or(ParamError::Env)?),
                };
                Ok((key, value))
            })
            .collect(),
    }
}

/// Run under the daemon's own inherited environment (the serving path).
pub(crate) async fn run(params: ExecParams) -> Result<Outcome, ExecError> {
    run_with_base_env(params, std::env::vars_os().collect()).await
}

/// The base env is injected so the merge is testable without mutating this
/// process's environment (`std::env::set_var` is unsafe, and this crate
/// forbids unsafe code).
pub(crate) async fn run_with_base_env(
    params: ExecParams,
    base_env: HashMap<OsString, OsString>,
) -> Result<Outcome, ExecError> {
    let mut child = spawn(&params, base_env)?;
    // Drain both pipes concurrently with the wait: a child that fills one
    // pipe's buffer would otherwise deadlock against our own wait.
    let (exited, exit_seen) = watch::channel(false);
    let stdout = drain(child.stdout.take(), exit_seen.clone());
    let stderr = drain(child.stderr.take(), exit_seen);
    let (status, timed_out) = wait_with_timeout(&mut child, params.timeout_ms).await?;
    // Capture ends HERE, at direct-child exit -- see the drain doc for why.
    let _ = exited.send(true);
    Ok(Outcome {
        stdout: stdout.await.unwrap_or_default(),
        stderr: stderr.await.unwrap_or_default(),
        exit_status: exit_status_of(status),
        timed_out,
    })
}

fn spawn(params: &ExecParams, base_env: HashMap<OsString, OsString>) -> Result<Child, ExecError> {
    let (program, args) = params.argv.split_first().ok_or(ExecError::EmptyArgv)?;
    let mut command = Command::new(program);
    command
        .args(args)
        .env_clear()
        .envs(merged_env(base_env, &params.env))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Its own process group (pgid == pid), the scope ShellOut gets from
        // Process.setsid: a timeout kill must take the whole tree, not just
        // the direct child (mixlib-shellout unix.rb kills child_pgid).
        .process_group(0)
        // Belt to the timeout's braces: a dropped handle (connection death,
        // handler panic) must not orphan a running child.
        .kill_on_drop(true);
    if let Some(cwd) = &params.cwd {
        command.current_dir(cwd);
    }
    command.spawn().map_err(ExecError::Spawn)
}

const READ_CHUNK: usize = 8192;

/// How much a post-exit sweep may collect before stopping regardless. The
/// sweep normally ends at the first not-ready read; this bound exists so a
/// grandchild writing full-tilt into an always-ready pipe cannot extend it
/// forever. Deliberately stricter than mixlib's final pass, which is
/// EAGAIN-bounded but not byte-bounded; unreachable for direct-child bytes
/// (default pipe capacity is half this cap, and the live drain runs while
/// the child does).
const SWEEP_LIMIT: usize = 128 * 1024;

/// Reads the pipe while the direct child lives, then sweeps what is already
/// buffered and STOPS -- capture ends at direct-child exit, not at pipe EOF.
/// WHY: matching ShellOut's capture lifetime is the differential contract
/// (mixlib reads until the direct child is reaped, then does one final
/// `attempt_buffer_read`). Drain-to-EOF was rejected because a backgrounded
/// grandchild inherits the write end, which extends capture arbitrarily and
/// holds the RPC reply hostage until the orphan exits (C3 probes:
/// `(sleep 0.5; echo late) & echo early` captured the late bytes, and a
/// timed-out reply waited the full 5s of a surviving `sleep 5 &`).
fn drain(
    pipe: Option<impl AsyncReadExt + Unpin + Send + 'static>,
    mut exited: watch::Receiver<bool>,
) -> JoinHandle<Vec<u8>> {
    tokio::spawn(async move {
        let mut bytes = Vec::new();
        let Some(mut pipe) = pipe else {
            return bytes;
        };
        let mut chunk = vec![0u8; READ_CHUNK];
        let mut open = true;
        while open && !*exited.borrow() {
            tokio::select! {
                // A mid-stream read error keeps the bytes read so far:
                // partial output beats no output when the child dies messily.
                read = pipe.read(&mut chunk) => match read {
                    Ok(0) | Err(_) => open = false,
                    Ok(n) => bytes.extend_from_slice(&chunk[..n]),
                },
                _ = exited.changed() => {}
            }
        }
        if open {
            sweep_buffered(&mut pipe, &mut bytes).await;
        }
        bytes
    })
}

/// The final read after direct-child exit: bytes the child wrote before dying
/// are already in the kernel pipe buffer and return instantly; the first
/// not-ready read means only a grandchild's open write end remains, and that
/// is exactly where capture stops. `Duration::ZERO` still polls the read once
/// before the deadline, so ready data is never dropped.
async fn sweep_buffered(pipe: &mut (impl AsyncReadExt + Unpin), bytes: &mut Vec<u8>) {
    let mut chunk = vec![0u8; READ_CHUNK];
    let mut swept = 0;
    while swept < SWEEP_LIMIT {
        match tokio::time::timeout(Duration::ZERO, pipe.read(&mut chunk)).await {
            Ok(Ok(n)) if n > 0 => {
                bytes.extend_from_slice(&chunk[..n]);
                swept += n;
            }
            _ => return,
        }
    }
}

/// Timeout is server-side: at `timeout_ms` the child is killed
/// (kill-on-timeout) and the response says so; the wait after the kill reaps
/// it, so no orphaned children and no zombies.
async fn wait_with_timeout(
    child: &mut Child,
    timeout_ms: Option<u64>,
) -> Result<(ExitStatus, bool), ExecError> {
    let Some(ms) = timeout_ms else {
        return Ok((child.wait().await.map_err(ExecError::Wait)?, false));
    };
    match tokio::time::timeout(Duration::from_millis(ms), child.wait()).await {
        Ok(status) => Ok((status.map_err(ExecError::Wait)?, false)),
        Err(_elapsed) => settle_after_elapsed(child).await,
    }
}

/// `ExitStatusExt::signal` value for SIGKILL -- the only signal we ever send.
const SIGKILL: i32 = 9;

/// The timeout has elapsed: decide what ACTUALLY happened. `timed_out: true`
/// means exactly "we killed it", nothing else -- the Journal is the experiment
/// record, and a successful run recorded as a timeout is corrupted data
/// (probe_exec_hammer caught Elapsed racing a child that had already exited).
/// So: reap-if-exited first, and even after the kill the reaped status has the
/// last word -- a child that beat SIGKILL to a natural death in the
/// try_wait-to-kill window reports its own status, timed_out false.
async fn settle_after_elapsed(child: &mut Child) -> Result<(ExitStatus, bool), ExecError> {
    if let Ok(Some(status)) = child.try_wait() {
        return Ok((status, false));
    }
    kill_group(child);
    let status = child.wait().await.map_err(ExecError::Wait)?;
    Ok((status, status.signal() == Some(SIGKILL)))
}

/// Kill-on-timeout has ShellOut's SCOPE: the whole process group, so no
/// grandchild survives or is orphaned by a timeout (mixlib kills
/// `child_pgid`; ours is straight SIGKILL rather than mixlib's TERM-3s-KILL
/// grace, keeping `timed_out` == "died to OUR SIGKILL" decidable). The child
/// was spawned as its own group leader, so pgid == pid. On the non-timeout
/// path there is deliberately NO group kill -- a backgrounded grandchild
/// outliving a successful command is legal shell behavior, and mixlib leaves
/// it too (unix.rb `reap`: grandchildren "will have been adopted by init so
/// we can't reap them even if we wanted to (we don't)").
fn kill_group(child: &mut Child) {
    let group = child
        .id()
        .and_then(|pid| i32::try_from(pid).ok())
        .map(nix::unistd::Pid::from_raw);
    let killed = group.is_some_and(|pgid| {
        nix::sys::signal::killpg(pgid, nix::sys::signal::Signal::SIGKILL).is_ok()
    });
    if !killed {
        // Group already gone (or the child exited in the race window): fall
        // back to the direct child so the wait after us still settles.
        let _ = child.start_kill();
    }
}

/// The exit code when there is one; the shell convention 128+signal when the
/// child died to a signal (a timed-out child reports 137, SIGKILL); -1 in the
/// only-theoretical case of neither.
fn exit_status_of(status: ExitStatus) -> i64 {
    status.code().map_or_else(
        || status.signal().map_or(-1, |signal| i64::from(128 + signal)),
        i64::from,
    )
}

/// Env override, NOT confinement: the override map is merged over the child's
/// inherited environment, so a variable the overrides omit still reaches the
/// child. The ONE removal lever is an explicit nil value -- a msgpack nil
/// REMOVES the key (the `WorkerEnv` explicit-nil scrub, `worker_env.rb:14-18`);
/// nil is remove, never empty-string. Nothing here is a sandbox, and true
/// confinement is a later chunk's problem, not this merge's.
fn merged_env(
    base: HashMap<OsString, OsString>,
    overrides: &[(String, Option<String>)],
) -> HashMap<OsString, OsString> {
    overrides.iter().fold(base, |mut merged, (key, value)| {
        match value {
            Some(value) => {
                merged.insert(key.into(), value.into());
            }
            None => {
                merged.remove(OsStr::new(key));
            }
        }
        merged
    })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::ffi::OsString;

    use rmpv::Value;

    use super::{ExecParams, Outcome, run_with_base_env};
    use crate::rpc::support::{TestClient, exec_map, exec_params, field, start_server};

    fn sh(script: &str) -> Vec<String> {
        vec!["sh".to_string(), "-c".to_string(), script.to_string()]
    }

    fn params(argv: Vec<String>) -> ExecParams {
        ExecParams {
            argv,
            cwd: None,
            env: vec![],
            timeout_ms: None,
        }
    }

    async fn run_direct(params: ExecParams, base: HashMap<OsString, OsString>) -> Outcome {
        run_with_base_env(params, base)
            .await
            .expect("exec succeeds")
    }

    #[tokio::test]
    async fn exec_round_trips_bytes_and_status() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let (msgid, error, result) = client
            .call(
                1,
                "exec",
                exec_params(&["sh", "-c", "echo out; echo err >&2; exit 3"]),
            )
            .await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(Value::Binary(b"out\n".to_vec()), field(&result, "stdout"));
        assert_eq!(Value::Binary(b"err\n".to_vec()), field(&result, "stderr"));
        assert_eq!(Value::from(3), field(&result, "exit_status"));
        assert_eq!(Value::from(false), field(&result, "timed_out"));
    }

    #[tokio::test]
    async fn timeout_kills_the_child_server_side() {
        let (_dir, path) = start_server().await;
        let scratch = tempfile::tempdir().expect("scratch dir");
        let pidfile = scratch.path().join("pid");
        // `exec` keeps the pid in the file equal to the pid the server kills.
        let script = format!("echo $$ > {} && exec sleep 100", pidfile.display());
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client
            .call(
                1,
                "exec",
                vec![exec_map(&["sh", "-c", &script], &[], Some(100))],
            )
            .await;
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(Value::from(true), field(&result, "timed_out"));
        let pid: u32 = std::fs::read_to_string(&pidfile)
            .expect("the child wrote its pidfile before the timeout")
            .trim()
            .parse()
            .expect("pidfile holds a pid");
        assert!(
            !std::path::Path::new(&format!("/proc/{pid}")).exists(),
            "the child was killed and reaped, not orphaned"
        );
    }

    #[tokio::test]
    async fn nil_env_scrubs_an_inherited_variable_over_the_wire() {
        // HOME is inherited by the in-process test server, standing in for the
        // daemon's own env (set_var is unsafe, and unsafe is forbidden here).
        assert!(
            std::env::var_os("HOME").is_some(),
            "precondition: HOME is in the daemon env"
        );
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        // ${HOME-absent} (no colon): "absent" only when UNSET, so removal
        // stays distinguishable from empty-string.
        let map = exec_map(
            &["sh", "-c", "echo \"${HOME-absent}\""],
            &[("HOME", None)],
            None,
        );
        let (_, error, result) = client.call(1, "exec", vec![map]).await;
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(
            Value::Binary(b"absent\n".to_vec()),
            field(&result, "stdout")
        );
    }

    #[tokio::test]
    async fn a_nil_env_value_removes_the_key_never_empty_string() {
        let mut base: HashMap<OsString, OsString> = std::env::vars_os().collect();
        base.insert("SECRET".into(), "sekrit".into());
        let argv = sh("echo \"${SECRET-absent}\"");

        let inherited = run_direct(params(argv.clone()), base.clone()).await;
        assert_eq!(
            b"sekrit\n".to_vec(),
            inherited.stdout,
            "the base env reaches the child"
        );

        let mut scrubbed = params(argv.clone());
        scrubbed.env = vec![("SECRET".to_string(), None)];
        let removed = run_direct(scrubbed, base.clone()).await;
        assert_eq!(b"absent\n".to_vec(), removed.stdout, "nil removes the key");

        let mut emptied = params(argv);
        emptied.env = vec![("SECRET".to_string(), Some(String::new()))];
        let empty = run_direct(emptied, base).await;
        assert_eq!(
            b"\n".to_vec(),
            empty.stdout,
            "empty-string sets; only nil removes"
        );
    }

    #[tokio::test]
    async fn subprocess_output_round_trips_arbitrary_bytes() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client
            .call(
                1,
                "exec",
                exec_params(&["sh", "-c", r"printf '\377\000\376'"]),
            )
            .await;
        assert!(error.is_nil(), "unexpected error: {error:?}");
        // 0xff is not valid UTF-8: the Binary variant assertion IS the
        // bin-not-str contract.
        assert_eq!(
            Value::Binary(vec![0xff, 0x00, 0xfe]),
            field(&result, "stdout")
        );
    }

    #[tokio::test]
    async fn a_child_that_already_exited_when_the_timeout_fired_is_not_reported_timed_out() {
        // probe_exec_hammer's 1-in-20 defect: Elapsed fired, but the child had
        // already exited. Truth wins: its real status, timed_out false.
        let mut child = super::spawn(&params(sh("exit 7")), std::env::vars_os().collect())
            .expect("spawn the child");
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let (status, timed_out) = super::settle_after_elapsed(&mut child)
            .await
            .expect("settle");
        assert_eq!(
            7,
            super::exit_status_of(status),
            "the child's own status is reported"
        );
        assert!(
            !timed_out,
            "a child that exited on its own must never be recorded as timed out"
        );
    }

    #[tokio::test]
    async fn a_child_still_running_at_the_timeout_is_killed_and_reported_timed_out() {
        let mut child = super::spawn(
            &params(vec!["sleep".to_string(), "100".to_string()]),
            std::env::vars_os().collect(),
        )
        .expect("spawn the child");
        let pid = child.id().expect("child pid");
        let (status, timed_out) = super::settle_after_elapsed(&mut child)
            .await
            .expect("settle");
        assert_eq!(137, super::exit_status_of(status), "killed by our SIGKILL");
        assert!(timed_out, "timed_out true means exactly: we killed it");
        assert!(
            !std::path::Path::new(&format!("/proc/{pid}")).exists(),
            "killed and reaped"
        );
    }

    /// Gone from /proc, or a zombie awaiting init's reap -- no longer running.
    fn dead_or_zombie(pid: u32) -> bool {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Err(_) => true,
            Ok(stat) => stat
                .rsplit(") ")
                .next()
                .is_some_and(|rest| rest.starts_with('Z')),
        }
    }

    async fn wait_until(deadline_ms: u64, mut probe: impl FnMut() -> bool) -> bool {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(deadline_ms);
        loop {
            if probe() {
                return true;
            }
            if tokio::time::Instant::now() >= deadline {
                return false;
            }
            tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        }
    }

    #[tokio::test]
    async fn capture_ends_at_direct_child_exit_not_at_grandchild_eof() {
        // C3 differential, symptom 1: ShellOut captures "early\n" -- capture
        // ends when the DIRECT child exits. A backgrounded grandchild's later
        // bytes are not part of the command's output.
        let outcome = run_direct(
            params(sh("(sleep 0.5; echo late) & echo early")),
            std::env::vars_os().collect(),
        )
        .await;
        assert_eq!(0, outcome.exit_status);
        assert!(!outcome.timed_out);
        assert_eq!(
            b"early\n".to_vec(),
            outcome.stdout,
            "bytes a grandchild writes after the direct child exits are not captured"
        );
    }

    #[tokio::test]
    async fn the_reply_is_not_held_hostage_by_a_surviving_grandchild() {
        // C3 differential, symptom 2: bash replies in ~0.02s; draining the
        // pipes to EOF held the reply for the orphan's full 3s sleep.
        let started = std::time::Instant::now();
        let outcome = run_direct(
            params(sh("echo started; sleep 3 &")),
            std::env::vars_os().collect(),
        )
        .await;
        let elapsed = started.elapsed();
        assert_eq!(b"started\n".to_vec(), outcome.stdout);
        assert_eq!(0, outcome.exit_status);
        assert!(
            elapsed < std::time::Duration::from_millis(1500),
            "reply held for {elapsed:?} by a grandchild that outlives the command"
        );
    }

    #[tokio::test]
    async fn timeout_kills_the_whole_process_group_not_just_the_direct_child() {
        // C3 differential, symptom 3: mixlib kills child_pgid so grandchildren
        // die with the timeout; killing only the direct child orphans them.
        // The grandchild drops its pipe ends so this pins kill SCOPE alone,
        // independent of the capture-lifetime symptoms.
        let scratch = tempfile::tempdir().expect("scratch dir");
        let gcfile = scratch.path().join("grandchild");
        let script = format!(
            "sleep 30 >/dev/null 2>&1 & echo $! > {}; wait",
            gcfile.display()
        );
        let mut timed = params(sh(&script));
        timed.timeout_ms = Some(200);
        let started = std::time::Instant::now();
        let outcome = run_direct(timed, std::env::vars_os().collect()).await;
        let elapsed = started.elapsed();
        assert!(outcome.timed_out, "we killed it");
        assert!(
            elapsed < std::time::Duration::from_secs(2),
            "timed-out reply held for {elapsed:?}"
        );
        let grandchild: u32 = std::fs::read_to_string(&gcfile)
            .expect("grandchild pidfile")
            .trim()
            .parse()
            .expect("grandchild pid");
        let gone = wait_until(1000, || dead_or_zombie(grandchild)).await;
        if !gone {
            // Do not leak a 30s sleep on a red run.
            let _ = std::process::Command::new("kill")
                .args(["-KILL", &grandchild.to_string()])
                .status();
        }
        assert!(
            gone,
            "the grandchild survived the timeout kill -- the kill must have \
             ShellOut's process-group scope"
        );
    }

    #[tokio::test]
    async fn exec_runs_in_the_given_cwd() {
        let scratch = tempfile::tempdir().expect("scratch dir");
        let mut in_scratch = params(sh("pwd -P"));
        in_scratch.cwd = Some(scratch.path().to_path_buf());
        let outcome = run_direct(in_scratch, std::env::vars_os().collect()).await;
        let expected = format!(
            "{}\n",
            scratch
                .path()
                .canonicalize()
                .expect("canonicalize")
                .display()
        );
        assert_eq!(expected.into_bytes(), outcome.stdout);
    }
}
