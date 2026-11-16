//! `--reap-only`: no domain, only a reaper over the command's whole tree.

use std::fs;
use std::io;
use std::os::raw::c_int;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::{Child, Command, ExitCode, ExitStatus};
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::prctl::set_child_subreaper;
use nix::sys::signal::{Signal, kill};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::{AccessFlags, Pid, access, getpid};
use signal_hook::consts::{SIGCHLD, SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;
use signal_hook::low_level::{emulate_default_handler, raise};

use crate::linux_main::{EXEC_FAILED, NOT_ENFORCED, complain, fail};

/// How long a stop may spend before the fence gives up and dies anyway: inside
/// Shell::Pipeline::DEFAULT_GRACE (3s), so the fence finishes its own KILL rounds
/// and exits on its own signal before the caller's group KILL lands on it.
const STOP_BUDGET: Duration = Duration::from_secs(2);

/// The part of `STOP_BUDGET` the tree gets to run its own stop handlers, such as
/// git removing index.lock; the rest is for the KILL rounds.
const STOP_GRACE: Duration = Duration::from_millis(1500);

const STOPS: [c_int; 3] = [SIGTERM, SIGINT, SIGHUP];

/// Marks this process a child subreaper, spawns argv, waits for it, and reaps any orphan
/// that exits meanwhile. On TERM, INT or HUP it stops the tree: the same signal to every
/// descendant, up to `STOP_GRACE` for the tree to exit on its own, then rounds of SIGKILL to
/// every descendant, each followed by waitpid(-1), until ECHILD or until `STOP_BUDGET` runs
/// out. A descendant forked while a round runs is found by the next one, and one that has
/// been killed cannot fork. A normal exit kills nothing.
/// Exits with the child's code, or re-raises its terminating signal.
pub fn run(argv: &[String]) -> ExitCode {
    if let Err(error) = set_child_subreaper(true) {
        return fail(
            NOT_ENFORCED,
            &format!("becoming a child subreaper: {error}"),
        );
    }
    // Registered before the spawn, so neither the child's exit nor a stop can arrive unseen.
    let mut signals = match Signals::new(STOPS.iter().chain([&SIGCHLD])) {
        Ok(signals) => signals,
        Err(error) => return fail(NOT_ENFORCED, &format!("handling stop signals: {error}")),
    };
    let mut child = match spawn(argv) {
        Ok(child) => child,
        Err(error) => return fail(EXEC_FAILED, &format!("exec {}: {error}", argv[0])),
    };
    loop {
        let arrived: Vec<c_int> = signals.wait().collect();
        // A stop sent to the whole group kills the child too, so the stop must win over its exit.
        if let Some(stop) = arrived.into_iter().find(|signal| STOPS.contains(signal)) {
            stop_tree(stop);
            return reraise(stop);
        }
        match reap_exited(&mut child) {
            Ok(Some(status)) => return pass_through(status),
            Ok(None) => {}
            Err(error) => return fail(EXEC_FAILED, &format!("waiting for {}: {error}", argv[0])),
        }
    }
}

/// posix_spawnp, unlike execvp, has no fallback for a file with no shebang, so
/// this gives it the one glibc's execvp gives: the resolved file under /bin/sh.
fn spawn(argv: &[String]) -> io::Result<Child> {
    match Command::new(&argv[0]).args(&argv[1..]).spawn() {
        Err(error) if error.raw_os_error() == Some(Errno::ENOEXEC as i32) => {
            Command::new("/bin/sh")
                .arg(on_path(&argv[0]))
                .args(&argv[1..])
                .spawn()
        }
        spawned => spawned,
    }
}

/// The file execvp would have run: the first executable match on PATH.
fn on_path(program: &str) -> PathBuf {
    if program.contains('/') {
        return PathBuf::from(program);
    }
    let path = std::env::var("PATH").unwrap_or_else(|_| "/bin:/usr/bin".into());
    path.split(':')
        .map(|dir| PathBuf::from(if dir.is_empty() { "." } else { dir }).join(program))
        .find(|file| file.is_file() && access(file, AccessFlags::X_OK).is_ok())
        .unwrap_or_else(|| PathBuf::from(program))
}

/// Orphans are reaped by pid, never by waitpid(-1), which could take the child's
/// status; and nix cannot decode a realtime signal, so the child's own status
/// comes from std.
fn reap_exited(child: &mut Child) -> io::Result<Option<ExitStatus>> {
    let own = Pid::from_raw(child.id().cast_signed());
    for orphan in children(getpid()).into_iter().filter(|pid| *pid != own) {
        let _ = waitpid(orphan, Some(WaitPidFlag::WNOHANG));
    }
    child.try_wait()
}

fn stop_tree(stop: c_int) {
    let me = getpid();
    let stop = Signal::try_from(stop).unwrap_or(Signal::SIGTERM);
    for pid in descendants(me) {
        let _ = kill(pid, stop);
    }
    if in_rounds(STOP_GRACE, reaped_all) {
        return;
    }
    let reaped = in_rounds(STOP_BUDGET.saturating_sub(STOP_GRACE), || {
        for pid in descendants(me) {
            let _ = kill(pid, Signal::SIGKILL);
        }
        reaped_all()
    });
    if !reaped {
        complain(&format!(
            "descendants still alive after {STOP_BUDGET:?} of stopping; leaving them"
        ));
    }
}

/// Repeats `round` until it reports done, for at most `budget`; returns whether it did.
fn in_rounds(budget: Duration, mut round: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + budget;
    loop {
        if round() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// Kills come before this in every round, so a pid it reaps is never killed after
/// its number could have been reused.
fn reaped_all() -> bool {
    loop {
        match waitpid(None::<Pid>, Some(WaitPidFlag::WNOHANG)) {
            Err(Errno::ECHILD) => return true,
            Ok(WaitStatus::StillAlive) | Err(_) => return false,
            Ok(_) => {}
        }
    }
}

fn pass_through(status: ExitStatus) -> ExitCode {
    match (status.code(), status.signal()) {
        (Some(code), _) => ExitCode::from(u8::try_from(code).unwrap_or(u8::MAX)),
        (None, Some(signal)) => reraise(signal),
        (None, None) => ExitCode::FAILURE,
    }
}

/// signal-hook's table has no realtime signals, and this process handles none,
/// so a plain raise gives those their default. The shell convention is left for
/// a signal whose default is to be ignored or stop.
fn reraise(signal: c_int) -> ExitCode {
    if emulate_default_handler(signal).is_err() {
        let _ = raise(signal);
    }
    ExitCode::from(u8::try_from(128 + signal).unwrap_or(u8::MAX))
}

fn descendants(root: Pid) -> Vec<Pid> {
    let mut found = Vec::new();
    let mut frontier = vec![root];
    while let Some(pid) = frontier.pop() {
        let next = children(pid);
        found.extend(&next);
        frontier.extend(next);
    }
    found
}

/// A pid gone between two reads has no children, which is the right answer.
fn children(pid: Pid) -> Vec<Pid> {
    let Ok(tasks) = fs::read_dir(format!("/proc/{pid}/task")) else {
        return Vec::new();
    };
    tasks
        .filter_map(|task| fs::read_to_string(task.ok()?.path().join("children")).ok())
        .flat_map(|list| {
            list.split_whitespace()
                .filter_map(|pid| pid.parse().ok())
                .map(Pid::from_raw)
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    /// Kills the whole tree on drop, so a failed assertion leaks nothing to init.
    struct Tree {
        child: Child,
        root: Pid,
    }

    impl Tree {
        fn spawn(script: &str, size: usize) -> Self {
            let child = Command::new("sh")
                .args(["-c", script])
                .spawn()
                .expect("spawn sh");
            let root = Pid::from_raw(child.id().cast_signed());
            let deadline = Instant::now() + Duration::from_secs(5);
            while descendants(root).len() < size && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            Self { child, root }
        }
    }

    impl Drop for Tree {
        fn drop(&mut self) {
            for pid in descendants(self.root) {
                let _ = kill(pid, Signal::SIGKILL);
            }
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    #[test]
    fn descendants_reach_past_the_first_generation() {
        let tree = Tree::spawn("sh -c 'sleep 30 & wait' & wait", 2);

        assert_eq!(descendants(tree.root).len(), 2);
    }

    #[test]
    fn rounds_that_never_finish_give_up_when_the_budget_runs_out() {
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = sender.send(in_rounds(Duration::from_millis(50), || false));
        });

        assert_eq!(receiver.recv_timeout(Duration::from_secs(2)), Ok(false));
    }

    #[test]
    fn rounds_stop_as_soon_as_one_finishes() {
        let mut rounds = 0;

        assert!(in_rounds(Duration::from_secs(1), || {
            rounds += 1;
            rounds == 3
        }));
        assert_eq!(rounds, 3);
    }
}
