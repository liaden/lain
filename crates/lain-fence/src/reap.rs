//! `--reap-only`: no domain, only a reaper over the command's whole tree.

use std::fs;
use std::os::raw::c_int;
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, ExitCode, ExitStatus};
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::prctl::set_child_subreaper;
use nix::sys::signal::{Signal, kill};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::{Pid, getpid};
use signal_hook::consts::{SIGCHLD, SIGHUP, SIGINT, SIGTERM};
use signal_hook::iterator::Signals;
use signal_hook::low_level::{emulate_default_handler, raise};

use crate::{EXEC_FAILED, NOT_ENFORCED, complain, fail};

/// How long a stop may spend killing and reaping before the fence gives up and
/// dies anyway: inside Shell::Pipeline::DEFAULT_GRACE (3s), so the fence still
/// exits on its own signal before the caller's group KILL lands on it.
const STOP_BUDGET: Duration = Duration::from_secs(2);

const STOPS: [c_int; 3] = [SIGTERM, SIGINT, SIGHUP];

/// Marks this process a child subreaper, spawns argv, waits for it, and on TERM, INT or HUP
/// stops the tree: rounds of SIGKILL to every descendant, each followed by waitpid(-1), until
/// ECHILD or until `STOP_BUDGET` runs out. A descendant forked while a round runs is found by
/// the next one, and one that has been killed cannot fork. A normal exit kills and reaps nothing.
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
    let mut child = match Command::new(&argv[0]).args(&argv[1..]).spawn() {
        Ok(child) => child,
        Err(error) => return fail(EXEC_FAILED, &format!("exec {}: {error}", argv[0])),
    };
    loop {
        let arrived: Vec<c_int> = signals.wait().collect();
        // A stop sent to the whole group kills the child too, so the stop must win over its exit.
        if let Some(stop) = arrived.into_iter().find(|signal| STOPS.contains(signal)) {
            stop_tree();
            return reraise(stop);
        }
        match child.try_wait() {
            Ok(Some(status)) => return pass_through(status),
            Ok(None) => {}
            Err(error) => return fail(EXEC_FAILED, &format!("waiting for {}: {error}", argv[0])),
        }
    }
}

fn stop_tree() {
    let me = getpid();
    let reaped = in_rounds(STOP_BUDGET, || {
        for pid in descendants(me) {
            let _ = kill(pid, Signal::SIGKILL);
        }
        reaped_all()
    });
    if !reaped {
        complain(&format!(
            "descendants still alive after {STOP_BUDGET:?} of killing; leaving them"
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
    use std::process::Child;
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
