//! Headless runs, each started from a closed set of kinds. The daemon builds every argv itself and
//! refuses whatever it cannot check, so no caller starts a process of its own writing.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::File;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use lain_rpc::RpcError;
use lain_wire::RunStart;
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use rmpv::Value;
use tokio::sync::{mpsc, watch};

/// How long a stopped run's group has between TERM and KILL: past the chat's own 60 s shutdown
/// grace (`CLI::Shutdown::GRACE_DEFAULT`), so a KILL never cuts the cleanup it is doing.
pub(crate) const GRACE: Duration = Duration::from_secs(70);

/// What every run is started with: `Daemon::Launch` decides each of them, and the env is the
/// daemon's own less what only the daemon may read.
pub(crate) struct Settings {
    pub(crate) ruby: PathBuf,
    pub(crate) lain: PathBuf,
    /// Where each run's log goes, as `<id>.log`.
    pub(crate) runs: PathBuf,
    pub(crate) env: Vec<(OsString, OsString)>,
}

/// The closed set of runs the daemon starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RunKind {
    /// `/implement-epic <slug>` in a headless chat whose asks go to the phone. Whether the epic
    /// exists is the chat's to say: where an epic lives is the project's config to decide.
    Epic {
        slug: String,
    },
    ReviewPoll,
    Chores,
}

impl RunKind {
    fn from_request(kind: &str, args: &BTreeMap<String, String>) -> Result<Self, RpcError> {
        match kind {
            "epic" => {
                if let Some(key) = args.keys().find(|key| key.as_str() != "slug") {
                    return Err(refused(
                        "bad_args",
                        format!("an epic run takes only a slug, not {:?}", clip(key)),
                    ));
                }
                let slug = args
                    .get("slug")
                    .ok_or_else(|| refused("bad_args", "an epic run needs a slug".to_string()))?;
                if !is_slug(slug) {
                    return Err(refused(
                        "bad_slug",
                        format!(
                            "the slug {:?} does not match [a-z0-9][a-z0-9-]*",
                            clip(slug)
                        ),
                    ));
                }
                Ok(Self::Epic { slug: slug.clone() })
            }
            "review-poll" | "chores" => {
                if let Some(key) = args.keys().next() {
                    return Err(refused(
                        "bad_args",
                        format!("a {kind} run takes no args, not {:?}", clip(key)),
                    ));
                }
                Ok(if kind == "chores" {
                    Self::Chores
                } else {
                    Self::ReviewPoll
                })
            }
            other => Err(refused(
                "unknown_kind",
                format!(
                    "run.start knows no kind {:?}; the kinds are epic, review-poll and chores",
                    clip(other)
                ),
            )),
        }
    }

    fn name(&self) -> &'static str {
        match self {
            Self::Epic { .. } => "epic",
            Self::ReviewPoll => "review-poll",
            Self::Chores => "chores",
        }
    }

    /// What follows `<ruby> <lain>`.
    fn argv(&self, root: &Path) -> Vec<OsString> {
        match self {
            Self::Epic { slug } => {
                let mut argv: Vec<OsString> = vec!["chat".into(), "--root".into(), root.into()];
                argv.extend(["--cwd".into(), root.into()]);
                argv.extend(
                    [
                        "--non-interactive",
                        "--approval",
                        "auto",
                        "--human",
                        "remote",
                    ]
                    .map(OsString::from),
                );
                argv.extend(["--epic".into(), slug.into(), "--prompt".into()]);
                argv.push(format!("/implement-epic {slug}").into());
                argv
            }
            Self::ReviewPoll => vec!["queue".into(), "poll".into()],
            Self::Chores => vec!["todos".into(), "drain".into()],
        }
    }
}

/// The grammar of an epic's directory name, `Epic::Home::NAME`.
fn is_slug(slug: &str) -> bool {
    let word = |byte: &u8| byte.is_ascii_lowercase() || byte.is_ascii_digit();
    slug.as_bytes().first().is_some_and(word)
        && slug.bytes().all(|byte| word(&byte) || byte == b'-')
}

/// 1 run the daemon started; `ended` is its exit status, 128 plus the signal when one ended it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Run {
    pub(crate) id: String,
    pub(crate) kind: RunKind,
    pub(crate) root: PathBuf,
    pub(crate) pid: u32,
    pub(crate) started: SystemTime,
    pub(crate) ended: Option<i32>,
    pub(crate) log: PathBuf,
}

impl Run {
    pub(crate) fn to_value(&self) -> Value {
        let path = |path: &Path| Value::from(path.to_string_lossy().into_owned());
        let started = self
            .started
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let mut fields = vec![
            (Value::from("id"), Value::from(self.id.as_str())),
            (Value::from("kind"), Value::from(self.kind.name())),
            (Value::from("root"), path(&self.root)),
            (Value::from("pid"), Value::from(self.pid)),
            (Value::from("started"), Value::from(started)),
            (
                Value::from("status"),
                self.ended.map_or(Value::Nil, Value::from),
            ),
            (Value::from("log"), path(&self.log)),
        ];
        if let RunKind::Epic { slug } = &self.kind {
            fields.push((Value::from("slug"), Value::from(slug.as_str())));
        }
        Value::Map(fields)
    }
}

struct Entry {
    run: Run,
    exited: watch::Receiver<Option<i32>>,
    /// To the task that owns the child, which alone signals its group: it has not reaped the
    /// child while it holds the request, so the group cannot be another's yet.
    stops: mpsc::UnboundedSender<()>,
}

/// The runs this daemon started, live and ended, in the order they started.
pub(crate) struct Supervisor {
    settings: Option<Settings>,
    runs: Mutex<Vec<Entry>>,
    next: AtomicU64,
}

impl Supervisor {
    /// `None` is a daemon started without `--ruby`, `--lain` and `--runs-dir`, which runs nothing.
    pub(crate) fn new(settings: Option<Settings>) -> Arc<Self> {
        Arc::new(Self {
            settings,
            runs: Mutex::new(Vec::new()),
            next: AtomicU64::new(1),
        })
    }

    fn runs(&self) -> MutexGuard<'_, Vec<Entry>> {
        self.runs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Must run inside the runtime, which reaps the run.
    pub(crate) fn start(self: &Arc<Self>, request: RunStart) -> Result<Run, RpcError> {
        let settings = self.settings.as_ref().ok_or_else(|| {
            refused(
                "no_runs",
                "this daemon was started without --ruby, --lain and --runs-dir, so it runs nothing"
                    .to_string(),
            )
        })?;
        let kind = RunKind::from_request(&request.kind, &request.args)?;
        let root = project_root(&request.root)?;
        let id = self.next_id();
        let log = settings.runs.join(format!("{id}.log"));
        let output = open_log(&settings.runs, &log).map_err(|error| {
            refused(
                "no_log",
                format!("could not open {}: {error}", log.display()),
            )
        })?;
        let errors = output.try_clone().map_err(|error| {
            refused(
                "no_log",
                format!("could not open {}: {error}", log.display()),
            )
        })?;
        let mut child = tokio::process::Command::new(&settings.ruby)
            .arg(&settings.lain)
            .args(kind.argv(&root))
            .current_dir(&root)
            .env_clear()
            .envs(settings.env.iter().map(|(name, value)| (name, value)))
            .stdin(Stdio::null())
            .stdout(output)
            .stderr(errors)
            .process_group(0)
            .spawn()
            .map_err(|error| {
                refused("spawn_failed", format!("could not start the run: {error}"))
            })?;
        let pid = child
            .id()
            .ok_or_else(|| refused("spawn_failed", "the run exited unseen".to_string()))?;
        let (report, exited) = watch::channel(None);
        let (stops, mut stop_asked) = mpsc::unbounded_channel();
        let run = Run {
            id: id.clone(),
            kind,
            root,
            pid,
            started: SystemTime::now(),
            ended: None,
            log,
        };
        self.runs().push(Entry {
            run: run.clone(),
            exited,
            stops,
        });
        tracing::info!(id, pid, kind = run.kind.name(), root = %run.root.display(), "started a run");
        let supervisor = Arc::clone(self);
        tokio::spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status,
                Some(()) = stop_asked.recv() => stopped(&mut child, pid).await,
            };
            let code = match status {
                Ok(status) => code_of(status),
                Err(error) => {
                    tracing::error!(%error, id, "could not wait for a run");
                    -1
                }
            };
            supervisor.ended(&id, code);
            report.send_replace(Some(code));
        });
        Ok(run)
    }

    fn next_id(&self) -> String {
        let since = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let count = self.next.fetch_add(1, Ordering::Relaxed);
        format!("{since}-{}-{count}", std::process::id())
    }

    fn ended(&self, id: &str, code: i32) {
        if let Some(entry) = self.runs().iter_mut().find(|entry| entry.run.id == id) {
            entry.run.ended = Some(code);
        }
        tracing::info!(id, code, "a run ended");
    }

    pub(crate) fn list(&self) -> Vec<Run> {
        self.runs().iter().map(|entry| entry.run.clone()).collect()
    }

    /// The runs still running: a daemon replaced while it has some can no longer list or stop them.
    pub(crate) fn live(&self) -> usize {
        self.runs()
            .iter()
            .filter(|entry| entry.run.ended.is_none())
            .count()
    }

    /// TERM to the run's group, then KILL once [`GRACE`] has passed; answers once it has ended.
    /// A run that has ended has no task left to take the request, so nothing is signalled.
    pub(crate) async fn stop(&self, id: &str) -> Result<Run, RpcError> {
        let (stops, mut exited) = self
            .runs()
            .iter()
            .find(|entry| entry.run.id == id)
            .map(|entry| (entry.stops.clone(), entry.exited.clone()))
            .ok_or_else(|| refused("no_run", format!("there is no run {:?}", clip(id))))?;
        if stops.send(()).is_ok() {
            let _gone = exited.wait_for(Option::is_some).await;
        }
        self.find(id)
            .ok_or_else(|| refused("no_run", format!("there is no run {:?}", clip(id))))
    }

    fn find(&self, id: &str) -> Option<Run> {
        self.runs()
            .iter()
            .find(|entry| entry.run.id == id)
            .map(|entry| entry.run.clone())
    }
}

/// Called only by the task that owns `child`, before it has reaped it.
async fn stopped(child: &mut tokio::process::Child, pid: u32) -> std::io::Result<ExitStatus> {
    signal_group(pid, Signal::SIGTERM);
    match tokio::time::timeout(GRACE, child.wait()).await {
        Ok(status) => status,
        Err(_) => {
            signal_group(pid, Signal::SIGKILL);
            child.wait().await
        }
    }
}

fn signal_group(pid: u32, signal: Signal) {
    let Ok(group) = i32::try_from(pid) else {
        return;
    };
    match killpg(Pid::from_raw(group), signal) {
        Ok(()) => tracing::info!(pid, ?signal, "signalled a run's group"),
        Err(error) => tracing::warn!(%error, pid, ?signal, "could not signal a run's group"),
    }
}

fn code_of(status: ExitStatus) -> i32 {
    status
        .code()
        .or_else(|| status.signal().map(|signal| 128 + signal))
        .unwrap_or(-1)
}

/// An absolute directory with `.lain/` or `.git` at its top, the markers a lain project has.
fn project_root(root: &str) -> Result<PathBuf, RpcError> {
    let bad = |why: String| refused("bad_root", format!("the root {:?} {why}", clip_path(root)));
    let path = Path::new(root);
    if !path.is_absolute() {
        return Err(bad("is not an absolute path".to_string()));
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| bad(format!("cannot be read: {error}")))?;
    if !canonical.is_dir() {
        return Err(bad("is not a directory".to_string()));
    }
    let lain = std::fs::symlink_metadata(canonical.join(".lain")).is_ok_and(|meta| meta.is_dir());
    let git = std::fs::symlink_metadata(canonical.join(".git")).is_ok();
    if !(lain || git) {
        return Err(bad(
            "is not a lain project: no .lain or .git at its top".to_string()
        ));
    }
    Ok(canonical)
}

/// Owner-only, since a run's output may quote what it read.
fn open_log(dir: &Path, log: &Path) -> std::io::Result<File> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(log)
}

fn refused(code: &'static str, message: String) -> RpcError {
    RpcError::Refused { code, message }
}

/// A root, cut at the longest path the kernel resolves.
fn clip_path(text: &str) -> String {
    text.chars().take(4096).collect()
}

/// A caller's text, cut short before it goes back in a message.
fn clip(text: &str) -> String {
    text.chars().take(64).collect()
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::time::Duration;

    use super::*;

    /// Ignores TERM in its whole group, noting each one, so only a KILL ends it.
    const STUBBORN: &str = r#"#!/bin/sh
trap 'echo term >> "$PROBE/term"' TERM
(trap '' TERM; exec sleep 60) &
echo $! > "$PROBE/grandchild"
while :; do wait; done
"#;

    /// KILLs the run's group unless the test saw it end, so a failing run never outlives the test.
    struct KillOnDrop(Option<u32>);

    impl Drop for KillOnDrop {
        fn drop(&mut self) {
            if let Some(pid) = self.0 {
                signal_group(pid, Signal::SIGKILL);
            }
        }
    }

    /// A zombie passes `kill(pid, 0)`, so only its state tells it from a live process; `ps` reads
    /// it on Linux and macOS alike, and prints nothing for a pid that is gone.
    fn alive(pid: u32) -> bool {
        let output = std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .expect("run ps");
        let state = String::from_utf8_lossy(&output.stdout);
        let state = state.trim();
        !state.is_empty() && !state.starts_with('Z')
    }

    /// Waits in real time while holding the only runtime thread, so the paused clock cannot move.
    fn appeared(path: &Path) -> String {
        for _ in 0..500 {
            if let Ok(text) = std::fs::read_to_string(path)
                && !text.is_empty()
            {
                return text;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("{} never appeared", path.display())
    }

    fn reaped(pid: u32) -> bool {
        (0..500).any(|_| {
            std::thread::sleep(Duration::from_millis(10));
            !alive(pid)
        })
    }

    #[tokio::test(start_paused = true)]
    async fn a_stop_sends_the_group_term_then_kill_70_seconds_later() {
        let dir = tempfile::tempdir().expect("tempdir");
        let probe = dir.path().join("probe");
        let project = dir.path().join("project");
        std::fs::create_dir(&probe).expect("probe");
        std::fs::create_dir_all(project.join(".git")).expect("project");
        let ruby = dir.path().join("ruby");
        std::fs::write(&ruby, STUBBORN).expect("script");
        std::fs::set_permissions(&ruby, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        let supervisor = Supervisor::new(Some(Settings {
            ruby,
            lain: dir.path().join("lain"),
            runs: dir.path().join("runs"),
            env: vec![
                ("PATH".into(), std::env::var_os("PATH").unwrap_or_default()),
                ("PROBE".into(), probe.clone().into_os_string()),
            ],
        }));
        let run = supervisor
            .start(lain_wire::RunStart {
                kind: "chores".to_string(),
                root: project.to_str().expect("utf-8").to_string(),
                args: Default::default(),
            })
            .expect("started");
        let mut group = KillOnDrop(Some(run.pid));
        let grandchild: u32 = appeared(&probe.join("grandchild"))
            .trim()
            .parse()
            .expect("pid");

        let began = tokio::time::Instant::now();
        let stopping = tokio::spawn({
            let supervisor = Arc::clone(&supervisor);
            let id = run.id.clone();
            async move { supervisor.stop(&id).await }
        });
        let term = probe.join("term");
        for _ in 0..500 {
            if term.exists() {
                break;
            }
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!("term\n", appeared(&term));
        tokio::time::advance(Duration::from_secs(69)).await;
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        std::thread::sleep(Duration::from_millis(200));
        assert!(!stopping.is_finished(), "the stop ended before 70 s");
        assert!(alive(run.pid) && alive(grandchild), "killed before 70 s");
        assert_eq!(1, supervisor.live());

        tokio::time::advance(Duration::from_secs(1)).await;
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !stopping.is_finished() {
            assert!(
                std::time::Instant::now() < deadline,
                "the stop never ended after its KILL"
            );
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        let stopped = stopping.await.expect("joined").expect("stopped");
        assert!(
            began.elapsed() >= Duration::from_secs(70),
            "killed after {:?}",
            began.elapsed()
        );
        assert_eq!(Some(128 + 9), stopped.ended);
        group.0 = None;
        assert!(reaped(grandchild), "the group outlived its KILL");
        assert_eq!(0, supervisor.live());
    }
}
