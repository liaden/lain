//! The fence as a reaper only: `--reap-only` applies no domain, and on a stop
//! signal kills every process that descends from it.
//!
//! This test process makes itself a child subreaper, so anything the fence
//! leaves behind, alive or an unreaped zombie, is reparented here once the
//! fence exits. "The fence left nothing" is then "this process has no
//! children", which is why the tests in this file run one at a time.

use std::fs;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use nix::sys::prctl::set_child_subreaper;
use nix::sys::signal::{Signal, kill, killpg};
use nix::sys::wait::{WaitPidFlag, waitpid};
use nix::unistd::Pid;

const FENCE: &str = env!("CARGO_BIN_EXE_lain-fence");

/// Bounded three ways, since a reaper that fails here would otherwise hand
/// init an endless spawner: a counted loop, a per-user cap, and sleeps that
/// end on their own. The cap counts threads the user already runs, because
/// RLIMIT_NPROC does, and a busy box can be past any fixed number.
const FORK_LOOP: &str = r#"ulimit -u $(( $(ps -L -u "$(id -u)" --no-headers | wc -l) + 600 ))
setsid sh -c 'i=0; while [ $i -lt 500 ]; do sleep 30 & i=$((i+1)); done' &
sleep 30"#;

static SERIAL: Mutex<()> = Mutex::new(());

fn serial() -> MutexGuard<'static, ()> {
    let guard = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    set_child_subreaper(true).expect("subreaper");
    guard
}

fn reaper(script: &str) -> Command {
    let mut command = Command::new(FENCE);
    command
        .args(["--reap-only", "--", "sh", "-c", script])
        .env("LC_ALL", "C")
        .process_group(0);
    command
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

fn children(pid: u32) -> Vec<u32> {
    let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) else {
        return Vec::new();
    };
    tasks
        .filter_map(|task| fs::read_to_string(task.ok()?.path().join("children")).ok())
        .flat_map(|list| {
            list.split_whitespace()
                .filter_map(|pid| pid.parse().ok())
                .collect::<Vec<u32>>()
        })
        .collect()
}

fn descendants(root: u32) -> Vec<u32> {
    let mut found = Vec::new();
    let mut frontier = vec![root];
    while let Some(pid) = frontier.pop() {
        let next = children(pid);
        found.extend(&next);
        frontier.extend(next);
    }
    found
}

fn command_line(pid: u32) -> String {
    let raw = fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
    text(&raw).replace('\0', " ").trim().to_owned()
}

fn state(pid: u32) -> Option<char> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(") ")?.1.chars().next()
}

fn own_children() -> Vec<u32> {
    children(std::process::id())
}

fn wait_for(limit: Duration, mut ready: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if ready() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    ready()
}

fn exit_within(child: &mut Child, limit: Duration) -> Option<ExitStatus> {
    let mut status = None;
    wait_for(limit, || {
        status = child.try_wait().expect("try_wait");
        status.is_some()
    });
    status
}

/// A test that failed before its fence stopped must not leave its tree to the
/// next test's "no children" check, nor to init. Repeated because a spawner
/// still running between two kills can add a child the first kill missed.
fn sweep(fence: &mut Child) {
    let _ = killpg(Pid::from_raw(fence.id() as i32), Signal::SIGKILL);
    let _ = fence.wait();
    wait_for(Duration::from_secs(5), || {
        let left = descendants(std::process::id());
        for pid in &left {
            let _ = kill(Pid::from_raw(*pid as i32), Signal::SIGKILL);
        }
        for pid in own_children() {
            let _ = waitpid(Pid::from_raw(pid as i32), Some(WaitPidFlag::WNOHANG));
        }
        left.is_empty()
    });
}

fn stop_and_expect_nothing_left(fence: &mut Child, limit: Duration) {
    killpg(Pid::from_raw(fence.id() as i32), Signal::SIGTERM).expect("TERM the group");
    expect_nothing_left(fence, limit);
}

fn expect_nothing_left(fence: &mut Child, limit: Duration) {
    let status = exit_within(fence, limit);
    let left: Vec<String> = own_children().into_iter().map(command_line).collect();
    sweep(fence);

    let status = status.unwrap_or_else(|| panic!("fence still running after {limit:?}"));
    assert_eq!(status.signal(), Some(Signal::SIGTERM as i32), "{status:?}");
    assert!(left.is_empty(), "the fence left {left:?}");
}

#[test]
fn a_re_setsid_grandchild_dies_when_the_call_is_stopped() {
    let _serial = serial();
    let mut fence = reaper("setsid sleep 30 & sleep 30")
        .spawn()
        .expect("spawn fence");
    let started = wait_for(Duration::from_secs(5), || {
        descendants(fence.id())
            .into_iter()
            .filter(|pid| command_line(*pid) == "sleep 30")
            .count()
            == 2
    });
    if !started {
        sweep(&mut fence);
        panic!("both sleeps never started under the fence");
    }

    stop_and_expect_nothing_left(&mut fence, Duration::from_secs(2));
}

#[test]
fn a_normal_exit_leaves_background_children_running() {
    let _serial = serial();
    let out = tempfile::NamedTempFile::new().expect("tempfile");
    let mut fence = reaper("sleep 30 & echo done")
        .stdout(Stdio::from(out.reopen().expect("reopen")))
        .spawn()
        .expect("spawn fence");

    let status = exit_within(&mut fence, Duration::from_secs(5));
    let sleeping: Vec<u32> = own_children()
        .into_iter()
        .filter(|pid| command_line(*pid) == "sleep 30" && state(*pid) != Some('Z'))
        .collect();
    sweep(&mut fence);

    assert_eq!(status.and_then(|s| s.code()), Some(0), "{status:?}");
    assert_eq!(fs::read_to_string(out.path()).expect("stdout"), "done\n");
    assert_eq!(sleeping.len(), 1, "the background sleep was not left alive");
}

#[test]
fn a_descendant_that_keeps_forking_is_still_reaped() {
    let _serial = serial();
    let mut fence = reaper(FORK_LOOP).spawn().expect("spawn fence");
    let forking = wait_for(Duration::from_secs(5), || {
        descendants(fence.id()).len() > 20
    });
    if !forking {
        sweep(&mut fence);
        panic!("the fork loop never got going under the fence");
    }

    stop_and_expect_nothing_left(&mut fence, Duration::from_secs(3));
}

#[test]
fn the_childs_exit_status_passes_through() {
    let _serial = serial();
    let out = reaper("exit 7").output().expect("spawn fence");

    assert_eq!(out.status.code(), Some(7), "{out:?}");
}

#[test]
fn reap_only_applies_no_landlock_domain_and_no_seccomp_filter() {
    let _serial = serial();
    let out = reaper("cat /etc/hostname").output().expect("spawn fence");

    assert!(out.status.success(), "{out:?}");
    assert_eq!(
        text(&out.stdout),
        fs::read_to_string("/etc/hostname").expect("hostname")
    );
}

#[test]
fn inherited_descriptors_are_still_closed() {
    let _serial = serial();
    let out = Command::new("sh")
        .args(["-c", "exec \"$@\" 5>&1 1>/dev/null", "sh", FENCE])
        .args(["--reap-only", "--", "sh", "-c", "echo forged >&5"])
        .env("LC_ALL", "C")
        .output()
        .expect("spawn sh");

    assert_eq!(text(&out.stdout), "");
    assert!(text(&out.stderr).contains("Bad file descriptor"), "{out:?}");
}

#[test]
fn reap_only_refuses_grants() {
    let _serial = serial();
    let out: Output = Command::new(FENCE)
        .args(["--reap-only", "--read-dir", "/tmp", "--", "true"])
        .output()
        .expect("spawn fence");

    assert_eq!(out.status.code(), Some(125), "{out:?}");
    let usage = text(&out.stderr);
    assert!(
        usage.contains("--reap-only") && usage.contains("--read-dir"),
        "{out:?}"
    );
}

#[test]
fn a_child_killed_by_its_own_signal_takes_the_fence_with_it() {
    let _serial = serial();
    for name in ["TERM", "KILL", "PIPE", "USR1", "RTMIN", "RTMIN+3"] {
        let script = format!("kill -s {name} $$");
        let bare = Command::new("sh")
            .args(["-c", &script])
            .status()
            .expect("bare sh");
        let mut fence = reaper(&script).spawn().expect("spawn fence");
        let status = exit_within(&mut fence, Duration::from_secs(5));
        sweep(&mut fence);

        assert!(
            bare.signal().is_some(),
            "{name} did not kill a bare sh: {bare:?}"
        );
        assert_eq!(
            status.map(|s| s.signal()),
            Some(bare.signal()),
            "{name}: {status:?}"
        );
    }
}

/// The fence is held stopped while the group TERM lands and the shell exits 0
/// from its trap, so it wakes with the stop and the exit both pending.
#[test]
fn a_stop_wins_over_the_childs_own_exit() {
    let _serial = serial();
    let mut fence = reaper("trap 'exit 0' TERM; setsid sleep 30 & sleep 30 & wait")
        .spawn()
        .expect("spawn fence");
    let pid = Pid::from_raw(fence.id() as i32);
    let started = wait_for(Duration::from_secs(5), || {
        descendants(fence.id())
            .into_iter()
            .filter(|pid| command_line(*pid) == "sleep 30")
            .count()
            == 2
    });
    let shell = children(fence.id()).into_iter().next();
    let held = started && kill(pid, Signal::SIGSTOP).is_ok() && {
        let _ = killpg(pid, Signal::SIGTERM);
        wait_for(Duration::from_secs(5), || {
            shell.and_then(state) == Some('Z')
        })
    };
    let _ = kill(pid, Signal::SIGCONT);
    if !held {
        sweep(&mut fence);
        panic!("the shell never exited from its trap while the fence was held");
    }

    expect_nothing_left(&mut fence, Duration::from_secs(2));
}
