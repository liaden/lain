//! The daemon's end of `lain daemon spawner`, a Ruby process that has already paid for lain's boot
//! and forks each run from it. They speak JSON lines over a socket pair whose other end is the
//! spawner's stdin: a request is `{argv, env, cwd, log}`, and the answers are `{pid}` at the fork,
//! `{pid, status}` at the run's exit, `{stale: true}` once lain's own files changed, and `{error}`.

use std::collections::{HashMap, VecDeque};
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use nix::errno::Errno;
use nix::sys::signal::{Signal, kill, killpg};
use nix::unistd::Pid;
use serde::Deserialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{oneshot, watch};

use crate::supervisor::Settings;

/// How 1 request went.
pub(crate) enum Spawned {
    /// Forked; `exit` gets the status when the spawner reports it, and closes if the spawner goes
    /// first.
    Forked {
        pid: u32,
        exit: watch::Receiver<Option<i32>>,
    },
    /// Lain's files changed since the spawner booted: it forks nothing more.
    Stale,
    Refused(String),
    /// The spawner is gone, or did not answer in time.
    Gone,
}

#[derive(Deserialize)]
struct Answer {
    pid: Option<u32>,
    status: Option<i32>,
    #[serde(default)]
    stale: bool,
    error: Option<String>,
}

struct Shared {
    /// Whether it still takes requests.
    open: bool,
    /// The spawner answers requests in order, so the oldest waiting request owns the next answer.
    waiting: VecDeque<oneshot::Sender<Spawned>>,
    exits: HashMap<u32, watch::Sender<Option<i32>>>,
}

pub(crate) struct Spawner {
    writer: tokio::sync::Mutex<OwnedWriteHalf>,
    shared: Arc<Mutex<Shared>>,
    /// Kills the spawner through the task that reaps it, so a pid already reaped is never signalled.
    kill: Mutex<Option<oneshot::Sender<()>>>,
}

impl Spawner {
    /// Starts `<ruby> <lain> daemon spawner` with the run env less the provider key, which each
    /// request carries for its own run. Its output goes to `spawner.log` beside the runs dir.
    /// Must run inside the runtime.
    pub(crate) fn start(settings: &Settings, withheld: &str) -> io::Result<Arc<Self>> {
        let home = settings.runs.parent().unwrap_or(&settings.runs);
        let log = open_log(home)?;
        let (ours, theirs) = std::os::unix::net::UnixStream::pair()?;
        let mut child = tokio::process::Command::new(&settings.ruby)
            .arg(&settings.lain)
            .args(["daemon", "spawner"])
            .current_dir(home)
            .env_clear()
            .envs(
                settings
                    .env
                    .iter()
                    .filter(|(name, _)| name != withheld)
                    .map(|(name, value)| (name, value)),
            )
            .stdin(Stdio::from(std::os::fd::OwnedFd::from(theirs)))
            .stdout(log.try_clone()?)
            .stderr(log)
            .process_group(0)
            .spawn()?;
        ours.set_nonblocking(true)?;
        let (reader, writer) = UnixStream::from_std(ours)?.into_split();
        let shared = Arc::new(Mutex::new(Shared {
            open: true,
            waiting: VecDeque::new(),
            exits: HashMap::new(),
        }));
        tokio::spawn(read(reader, Arc::clone(&shared)));
        let (kill, killed) = oneshot::channel::<()>();
        let mut group = Unreaped(child.id());
        tokio::spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status,
                Ok(()) = killed => {
                    group.kill();
                    child.wait().await
                }
            };
            group.reaped();
            match status {
                Ok(status) => tracing::info!(%status, "the spawner exited"),
                Err(error) => tracing::warn!(%error, "could not wait for the spawner"),
            }
        });
        tracing::info!("started a spawner");
        Ok(Arc::new(Self {
            writer: tokio::sync::Mutex::new(writer),
            shared,
            kill: Mutex::new(Some(kill)),
        }))
    }

    fn shared(&self) -> MutexGuard<'_, Shared> {
        lock(&self.shared)
    }

    pub(crate) fn is_open(&self) -> bool {
        self.shared().open
    }

    /// 1 request, written whole: the spawner reaps only between whole lines. One not answered
    /// within `bound` kills the spawner, since a wedged one would hold every later start.
    pub(crate) async fn spawn(&self, line: &[u8], bound: Duration) -> Spawned {
        let (answer, answered) = oneshot::channel();
        {
            let mut writer = self.writer.lock().await;
            {
                let mut shared = self.shared();
                if !shared.open {
                    return Spawned::Gone;
                }
                shared.waiting.push_back(answer);
            }
            if let Err(error) = writer.write_all(line).await {
                tracing::warn!(%error, "could not write to the spawner");
                self.shared().open = false;
                return Spawned::Gone;
            }
        }
        match tokio::time::timeout(bound, answered).await {
            Ok(Ok(spawned)) => spawned,
            Ok(Err(_)) => Spawned::Gone,
            Err(_) => {
                tracing::warn!(
                    ?bound,
                    "the spawner did not answer in time, so it is killed"
                );
                self.shared().open = false;
                if let Some(kill) = self
                    .kill
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take()
                {
                    let _ = kill.send(());
                }
                Spawned::Gone
            }
        }
    }
}

/// The spawner's own group, killed whole when the daemon drops it unreaped (the daemon's exit
/// included): what the spawner itself started goes with it, while each run is in a session of its own.
struct Unreaped(Option<u32>);

impl Unreaped {
    /// Its pid is no longer the spawner's, so it is never signalled again.
    fn reaped(&mut self) {
        self.0 = None;
    }

    fn kill(&self) {
        let Some(group) = self.0.and_then(|pid| i32::try_from(pid).ok()) else {
            return;
        };
        if let Err(error) = killpg(Pid::from_raw(group), Signal::SIGKILL) {
            tracing::warn!(%error, group, "could not kill the spawner");
        }
    }
}

impl Drop for Unreaped {
    fn drop(&mut self) {
        self.kill();
    }
}

fn lock(shared: &Mutex<Shared>) -> MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Reads until the spawner hangs up. A stale spawner still reports the runs it forked, so its end
/// is read to the last of them; then each run it never reported has its `exit` closed.
async fn read(reader: OwnedReadHalf, shared: Arc<Mutex<Shared>>) {
    let mut lines = BufReader::new(reader).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => answered(&shared, &line),
            Ok(None) => break,
            Err(error) => {
                tracing::warn!(%error, "could not read the spawner");
                break;
            }
        }
    }
    let mut shared = lock(&shared);
    shared.open = false;
    shared.waiting.clear();
    shared.exits.clear();
}

fn answered(shared: &Mutex<Shared>, line: &str) {
    let Ok(answer) = serde_json::from_str::<Answer>(line) else {
        tracing::warn!(
            len = line.len(),
            "the spawner sent a line that is not an answer"
        );
        return;
    };
    let mut shared = lock(shared);
    match answer {
        Answer {
            pid: Some(pid),
            status: Some(status),
            ..
        } => match shared.exits.remove(&pid) {
            Some(exit) => {
                exit.send_replace(Some(status));
            }
            None => tracing::warn!(pid, "the spawner reported a run it never named"),
        },
        Answer {
            pid: Some(pid),
            status: None,
            ..
        } => {
            let (exit, exited) = watch::channel(None);
            shared.exits.insert(pid, exit);
            let forked = Spawned::Forked { pid, exit: exited };
            if !next(&mut shared, forked) {
                shared.exits.remove(&pid);
                abandon(pid);
            }
        }
        Answer { stale: true, .. } => {
            shared.open = false;
            for waiting in shared.waiting.drain(..) {
                let _ = waiting.send(Spawned::Stale);
            }
        }
        Answer {
            error: Some(error), ..
        } => {
            next(&mut shared, Spawned::Refused(error));
        }
        Answer { .. } => tracing::warn!("the spawner sent an empty answer"),
    }
}

/// A fork answered after its start gave up and started the run by exec instead: left alone it
/// would run twice, and unlisted. A forked run leads a session of its own, so its group is its own.
fn abandon(pid: u32) {
    tracing::warn!(pid, "killed a run forked after its start gave up on it");
    let Ok(group) = i32::try_from(pid) else {
        return;
    };
    // A child that has not reached its setsid yet leads no group, so it is killed by pid.
    let killed = match killpg(Pid::from_raw(group), Signal::SIGKILL) {
        Err(Errno::ESRCH) => kill(Pid::from_raw(group), Signal::SIGKILL),
        other => other,
    };
    if let Err(error) = killed {
        tracing::warn!(%error, pid, "could not kill a run forked after its start gave up on it");
    }
}

/// Whether a start was still waiting for it.
fn next(shared: &mut Shared, spawned: Spawned) -> bool {
    shared
        .waiting
        .pop_front()
        .is_some_and(|waiting| waiting.send(spawned).is_ok())
}

/// Owner-only, like the runs' own logs.
fn open_log(home: &Path) -> io::Result<std::fs::File> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(home)?;
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .custom_flags(nix::fcntl::OFlag::O_NOFOLLOW.bits())
        .open(home.join("spawner.log"))
}
