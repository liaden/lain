//! Headless runs, each started from a closed set of kinds. The daemon builds every argv itself and
//! refuses whatever it cannot check, so no caller starts a process of its own writing.

use std::collections::{BTreeMap, HashSet};
use std::ffi::OsString;
use std::fs::File;
use std::future::Future;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::process::{ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use lain_rpc::RpcError;
use lain_wire::{AgendaItem, Delta, RunProfile, RunStart};
use nix::sys::signal::{Signal, killpg};
use nix::unistd::Pid;
use rmpv::Value;
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::registry::{ProcTable, Procs};
use crate::spawner::{Spawned, Spawner};

/// How long a stopped run's group has between TERM and KILL: past the chat's own 60 s shutdown
/// grace (`CLI::Shutdown::GRACE_DEFAULT`), so a KILL never cuts the cleanup it is doing.
pub(crate) const GRACE: Duration = Duration::from_secs(70);

/// The least time between 2 `lain daemon herdr-sync` starts, so a busy run costs herdr a call a
/// second and not one per park.
const SYNC_EVERY: Duration = Duration::from_secs(1);

/// A herdr-sync that has not ended by then is killed: a hung one would hold every later sync back.
const SYNC_BOUND: Duration = Duration::from_secs(30);

/// How long a start waits on the spawner's answer: a warmed fork answers in milliseconds and a
/// boot in about a second, so a spawner silent past this is wedged and the run starts by exec.
pub(crate) const SPAWN_BOUND: Duration = Duration::from_secs(10);

/// How often a run whose spawner went before reporting it is checked for, since nothing reports
/// its exit once its parent is gone.
const ORPHAN_POLL: Duration = Duration::from_secs(1);

/// How far up a session's parents the daemon looks for the run that started it.
const MAX_ANCESTORS: usize = 64;

/// `CLI::Backend::PROVIDERS`: a headless chat refuses any other only in a log nobody reads.
const PROVIDERS: [&str; 3] = ["anthropic", "ollama", "ollama-cloud"];

/// `CLI::EnvDefaults::READ`, provider first, in [`RunProfile`]'s field order.
const PROFILE_NAMES: [&str; 5] = [
    "LAIN_PROVIDER",
    "LAIN_MODEL",
    "LAIN_API_BASE",
    "LAIN_NUM_CTX",
    "LAIN_NUM_BATCH",
];

/// What every run is started with: `Daemon::Launch` decides each of them, and the env is the
/// daemon's own less what only the daemon may read.
#[derive(Clone)]
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
        root: PathBuf,
    },
    /// `lain queue poll` counts review requests across the forge, by the user's github settings or,
    /// with a root, by that project's own. Only the daemon's own timer starts it.
    ReviewPoll {
        root: Option<PathBuf>,
    },
    Chores {
        root: PathBuf,
    },
}

impl RunKind {
    fn from_request(
        kind: &str,
        args: &BTreeMap<String, String>,
        root: &str,
    ) -> Result<Self, RpcError> {
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
                Ok(Self::Epic {
                    slug: slug.clone(),
                    root: project_root(root)?,
                })
            }
            "review-poll" | "chores" => {
                if let Some(key) = args.keys().next() {
                    return Err(refused(
                        "bad_args",
                        format!("a {kind} run takes no args, not {:?}", clip(key)),
                    ));
                }
                if kind == "chores" {
                    Ok(Self::Chores {
                        root: project_root(root)?,
                    })
                } else {
                    Err(refused(
                        "bad_root",
                        "only the daemon's own timer starts a review-poll run".to_string(),
                    ))
                }
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
            Self::ReviewPoll { .. } => "review-poll",
            Self::Chores { .. } => "chores",
        }
    }

    /// Whether herdr lists it: the review poll is the daemon's own timer, with a workspace of its own.
    fn shown(&self) -> bool {
        !matches!(self, Self::ReviewPoll { .. })
    }

    /// The project the run works in; `None` for a kind that reads none.
    fn root(&self) -> Option<&Path> {
        match self {
            Self::Epic { root, .. } | Self::Chores { root } => Some(root),
            Self::ReviewPoll { root } => root.as_deref(),
        }
    }

    /// What follows `<ruby> <lain>`.
    fn argv(&self) -> Vec<OsString> {
        match self {
            Self::Epic { slug, root } => {
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
            Self::ReviewPoll { root } => {
                let mut argv: Vec<OsString> = vec!["queue".into(), "poll".into()];
                argv.extend(root.iter().flat_map(|root| ["--root".into(), root.into()]));
                argv
            }
            Self::Chores { .. } => vec!["todos".into(), "drain".into()],
        }
    }
}

/// The env a requester's profile sets, under the names `CLI::EnvDefaults::READ` reads. Env and
/// not argv, because an api base may carry credentials and an argv is in `ps`.
fn profile_env(profile: &RunProfile) -> Result<Vec<(OsString, OsString)>, RpcError> {
    if let Some(provider) = profile
        .provider
        .as_deref()
        .filter(|provider| !PROVIDERS.contains(provider))
    {
        return Err(refused(
            "bad_provider",
            format!(
                "run.start knows no provider {:?}; the providers are {}",
                clip(provider),
                PROVIDERS.join(", ")
            ),
        ));
    }
    let number = |value: Option<u32>| value.map(|value| value.to_string());
    let values = [
        profile.provider.clone(),
        profile.model.clone(),
        profile.api_base.clone(),
        number(profile.num_ctx),
        number(profile.num_batch),
    ];
    Ok(PROFILE_NAMES
        .into_iter()
        .zip(values)
        .filter_map(|(name, value)| Some((name.into(), value?.into())))
        .collect())
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
    pub(crate) pid: u32,
    pub(crate) started: SystemTime,
    pub(crate) ended: Option<i32>,
    pub(crate) log: PathBuf,
    /// Whether a session of the run has something parked or asked that only a human answers.
    pub(crate) blocked: bool,
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
            (
                Value::from("root"),
                self.kind.root().map_or(Value::Nil, path),
            ),
            (Value::from("pid"), Value::from(self.pid)),
            (Value::from("started"), Value::from(started)),
            (
                Value::from("status"),
                self.ended.map_or(Value::Nil, Value::from),
            ),
            (Value::from("log"), path(&self.log)),
            (Value::from("blocked"), Value::from(self.blocked)),
        ];
        if let RunKind::Epic { slug, .. } = &self.kind {
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
    /// The run process's own start, which tells it from a later process that reuses its pid.
    start: Option<String>,
    /// The sessions of this run now waiting on a human.
    blockers: usize,
}

/// The runs this daemon started, live and ended, in the order they started.
pub(crate) struct Supervisor {
    settings: Option<Settings>,
    runs: Mutex<Vec<Entry>>,
    next: AtomicU64,
    /// `None` for a daemon that runs nothing, which has nothing to show.
    sync: Option<Arc<Coalescer>>,
    /// The warmed spawner runs are forked from; a run starts by exec while there is none up. The
    /// first caller's run starts it, so a daemon that never runs anything never boots one.
    spawner: Mutex<Option<Arc<Spawner>>>,
}

impl Supervisor {
    /// `None` is a daemon started without `--ruby`, `--lain` and `--runs-dir`, which runs nothing.
    pub(crate) fn new(settings: Option<Settings>) -> Arc<Self> {
        let sync = settings.clone().map(|settings| {
            Coalescer::new(SYNC_EVERY, move || herdr_sync(settings.clone(), SYNC_BOUND))
        });
        Arc::new(Self {
            settings,
            runs: Mutex::new(Vec::new()),
            next: AtomicU64::new(1),
            sync,
            spawner: Mutex::new(None),
        })
    }

    fn sync(&self) {
        if let Some(sync) = &self.sync {
            sync.request();
        }
    }

    /// Follows what 1 registered session has waiting on a human, for the run its `lineage` (the
    /// session's pid and its ancestors, each with its start) reaches.
    pub(crate) fn watch(self: &Arc<Self>, lineage: Vec<(u32, String)>) -> Watch {
        Watch {
            supervisor: Arc::clone(self),
            lineage,
            state: Mutex::new(Waiting::default()),
        }
    }

    /// The live run whose process is among `lineage`.
    fn run_among(&self, lineage: &[(u32, String)]) -> Option<String> {
        self.runs()
            .iter()
            .find(|entry| {
                entry.run.ended.is_none()
                    && lineage.iter().any(|(pid, start)| {
                        *pid == entry.run.pid && entry.start.as_ref() == Some(start)
                    })
            })
            .map(|entry| entry.run.id.clone())
    }

    /// A run is blocked while any of its sessions waits, so each session counts once.
    fn block(&self, id: &str, more: bool) {
        let shown = {
            let mut runs = self.runs();
            runs.iter_mut()
                .find(|entry| entry.run.id == id)
                .map(|entry| {
                    entry.blockers = if more {
                        entry.blockers + 1
                    } else {
                        entry.blockers.saturating_sub(1)
                    };
                    entry.run.blocked = entry.blockers > 0;
                    entry.run.kind.shown()
                })
        };
        if shown == Some(true) {
            self.sync();
        }
    }

    fn runs(&self) -> MutexGuard<'_, Vec<Entry>> {
        self.runs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A caller's request, forked from the spawner when one is up and started by exec when not.
    /// Must run inside the runtime, which reaps the run.
    pub(crate) async fn start(self: &Arc<Self>, request: RunStart) -> Result<Run, RpcError> {
        self.settings()?;
        let kind = RunKind::from_request(&request.kind, &request.args, &request.root)?;
        let env = self.env_with(profile_env(&request.profile)?);
        // Its own task, so a caller that hangs up mid-fork cannot drop a forked run unlisted.
        let supervisor = Arc::clone(self);
        tokio::spawn(async move { supervisor.launch(kind, env).await })
            .await
            .unwrap_or_else(|error| {
                Err(refused(
                    "spawn_failed",
                    format!("the start failed: {error}"),
                ))
            })
    }

    async fn launch(
        self: &Arc<Self>,
        kind: RunKind,
        env: Vec<(OsString, OsString)>,
    ) -> Result<Run, RpcError> {
        let (id, log, output) = self.open_run_log()?;
        let forked = match self.request_line(&kind, &env, &log) {
            Some(line) => self.fork(&line).await,
            None => None,
        };
        let (pid, process) = match forked {
            Some(forked) => forked,
            None => self.exec(&kind, &env, output)?,
        };
        Ok(self.supervise(id, kind, pid, log, process))
    }

    /// The daemon's own timer's run, which a caller's request cannot name. Always by exec: it
    /// runs once in minutes, and the timer has no caller to wait on a spawner. `root` is a
    /// [`project_root`] already checked, or `None` for the user's poll.
    pub(crate) fn start_review_poll(
        self: &Arc<Self>,
        root: Option<PathBuf>,
    ) -> Result<Run, RpcError> {
        let kind = RunKind::ReviewPoll { root };
        let (id, log, output) = self.open_run_log()?;
        let (pid, process) = self.exec(&kind, &self.env_with(Vec::new()), output)?;
        Ok(self.supervise(id, kind, pid, log, process))
    }

    fn spawner(&self) -> Option<Arc<Spawner>> {
        self.spawner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Replaces `failed`, the spawner the caller saw fail, unless another start already has: 2
    /// starts that saw the same one fail boot 1 spawner between them. The one it replaces keeps
    /// reading its own end until its runs are reported.
    fn restart_spawner(&self, failed: Option<&Arc<Spawner>>) {
        let mut current = self.spawner.lock().unwrap_or_else(PoisonError::into_inner);
        let same = match (current.as_ref(), failed) {
            (Some(current), Some(failed)) => Arc::ptr_eq(current, failed),
            (None, None) => true,
            _ => false,
        };
        if same {
            *current = self.settings.as_ref().and_then(start_spawner);
        }
    }

    /// `None` when the run must start by exec. A stale spawner is replaced and the request
    /// retried once on the new one; a dead one is replaced for the next run.
    async fn fork(&self, line: &[u8]) -> Option<(u32, Process)> {
        for _ in 0..2 {
            let current = self.spawner();
            let Some(spawner) = current.as_ref().filter(|spawner| spawner.is_open()) else {
                self.restart_spawner(current.as_ref());
                return None;
            };
            match spawner.spawn(line, SPAWN_BOUND).await {
                Spawned::Forked { pid, exit } => return Some((pid, Process::Forked(exit))),
                Spawned::Stale => self.restart_spawner(Some(spawner)),
                Spawned::Refused(error) => {
                    tracing::warn!(error = %clip(&error), "the spawner refused a run");
                    return None;
                }
                Spawned::Gone => {
                    self.restart_spawner(Some(spawner));
                    return None;
                }
            }
        }
        None
    }

    /// The JSON line the spawner reads; `None` for a run whose argv, env or paths are not UTF-8,
    /// which JSON cannot carry.
    fn request_line(
        &self,
        kind: &RunKind,
        env: &[(OsString, OsString)],
        log: &Path,
    ) -> Option<Vec<u8>> {
        let settings = self.settings.as_ref()?;
        let argv = kind
            .argv()
            .iter()
            .map(|word| word.to_str().map(str::to_string))
            .collect::<Option<Vec<_>>>()?;
        let env = env
            .iter()
            .map(|(name, value)| Some((name.to_str()?.to_string(), value.to_str()?.into())))
            .collect::<Option<serde_json::Map<_, _>>>()?;
        let cwd = kind.root().unwrap_or(&settings.runs).to_str()?;
        let mut line = serde_json::to_vec(&serde_json::json!({
            "argv": argv,
            "env": env,
            "cwd": cwd,
            "log": log.to_str()?,
        }))
        .ok()?;
        line.push(b'\n');
        Some(line)
    }

    /// Whether the daemon was given what a run needs, without which it starts none.
    pub(crate) fn runs_anything(&self) -> bool {
        self.settings.is_some()
    }

    /// Whether the review poll of `root`, or the user's for `None`, is still running.
    pub(crate) fn review_poll_live(&self, root: Option<&Path>) -> bool {
        self.runs().iter().any(|entry| {
            entry.run.ended.is_none()
                && matches!(&entry.run.kind, RunKind::ReviewPoll { root: polled } if polled.as_deref() == root)
        })
    }

    fn settings(&self) -> Result<&Settings, RpcError> {
        self.settings.as_ref().ok_or_else(|| {
            refused(
                "no_runs",
                "this daemon was started without --ruby, --lain and --runs-dir, so it runs nothing"
                    .to_string(),
            )
        })
    }

    fn open_run_log(&self) -> Result<(String, PathBuf, File), RpcError> {
        let settings = self.settings()?;
        let id = self.next_id();
        let log = settings.runs.join(format!("{id}.log"));
        let output = open_log(&settings.runs, &log).map_err(|error| {
            refused(
                "no_log",
                format!("could not open {}: {error}", log.display()),
            )
        })?;
        Ok((id, log, output))
    }

    /// The requester's values win over the daemon's own, since the requester is who asked for the
    /// run. A requester on another provider takes none of the daemon's model, endpoint or runner
    /// knobs, which belong to the daemon's provider: the rule `CLI::RunProfile#over` keeps for a
    /// resumed chat.
    fn env_with(&self, requested: Vec<(OsString, OsString)>) -> Vec<(OsString, OsString)> {
        let own = self
            .settings
            .as_ref()
            .map_or(&[][..], |settings| &settings.env);
        let provider = |env: &[(OsString, OsString)]| {
            env.iter()
                .find(|(name, _)| name.to_str() == Some(PROFILE_NAMES[0]))
                .map(|(_, value)| value.clone())
        };
        let switched = provider(&requested).is_some_and(|asked| provider(own) != Some(asked));
        let replaced = |name: &OsString| {
            requested.iter().any(|(set, _)| set == name)
                || (switched
                    && PROFILE_NAMES
                        .iter()
                        .any(|profile| name.to_str() == Some(profile)))
        };
        let kept: Vec<_> = own
            .iter()
            .filter(|(name, _)| !replaced(name))
            .cloned()
            .collect();
        kept.into_iter().chain(requested).collect()
    }

    /// A run with no project starts in the runs directory, which the log's open creates.
    fn exec(
        &self,
        kind: &RunKind,
        env: &[(OsString, OsString)],
        output: File,
    ) -> Result<(u32, Process), RpcError> {
        let settings = self.settings()?;
        let errors = output
            .try_clone()
            .map_err(|error| refused("no_log", format!("could not open the run's log: {error}")))?;
        let child = tokio::process::Command::new(&settings.ruby)
            .arg(&settings.lain)
            .args(kind.argv())
            .current_dir(kind.root().unwrap_or(&settings.runs))
            .env_clear()
            .envs(env.iter().map(|(name, value)| (name, value)))
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
        Ok((pid, Process::Child(child)))
    }

    fn supervise(
        self: &Arc<Self>,
        id: String,
        kind: RunKind,
        pid: u32,
        log: PathBuf,
        mut process: Process,
    ) -> Run {
        let (report, exited) = watch::channel(None);
        let (stops, mut stop_asked) = mpsc::unbounded_channel();
        let run = Run {
            id: id.clone(),
            kind,
            pid,
            started: SystemTime::now(),
            ended: None,
            log,
            blocked: false,
        };
        self.runs().push(Entry {
            run: run.clone(),
            exited,
            stops,
            start: None,
            blockers: 0,
        });
        if run.kind.shown() {
            self.sync();
        }
        tracing::info!(id, pid, kind = run.kind.name(), root = ?run.kind.root(), forked = process.is_forked(), "started a run");
        let supervisor = Arc::clone(self);
        tokio::spawn(async move {
            // An exec'd child is read before `wait` reaps it, so its zombie is still readable; a forked
            // run that has already ended and been reaped by the spawner reads as None. `ps` may block.
            let start = tokio::task::spawn_blocking(move || {
                ProcTable.process(pid).map(|process| process.start)
            })
            .await
            .ok()
            .flatten();
            supervisor.started(&id, start.clone());
            let code = tokio::select! {
                code = process.wait(pid, start.as_deref()) => code,
                Some(()) = stop_asked.recv() => stopped(&mut process, pid, start.as_deref()).await,
            };
            supervisor.ended(&id, code);
            report.send_replace(Some(code));
        });
        run
    }

    fn next_id(&self) -> String {
        let since = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        let count = self.next.fetch_add(1, Ordering::Relaxed);
        format!("{since}-{}-{count}", std::process::id())
    }

    fn started(&self, id: &str, start: Option<String>) {
        if start.is_none() {
            tracing::warn!(
                id,
                "could not read the run's start, so it cannot be marked blocked"
            );
        }
        if let Some(entry) = self.runs().iter_mut().find(|entry| entry.run.id == id) {
            entry.start = start;
        }
    }

    fn ended(&self, id: &str, code: i32) {
        let shown = self
            .runs()
            .iter_mut()
            .find(|entry| entry.run.id == id)
            .map(|entry| {
                entry.run.ended = Some(code);
                entry.run.blocked = false;
                entry.run.kind.shown()
            });
        tracing::info!(id, code, "a run ended");
        if shown == Some(true) {
            self.sync();
        }
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

/// What 1 session has open, and the run it holds blocked while it does.
#[derive(Default)]
struct Waiting {
    open: HashSet<String>,
    blocking: Option<String>,
}

/// 1 registered session's agenda as the daemon saw it published. Dropping it, which the
/// connection's end does, frees the run it was holding blocked.
pub(crate) struct Watch {
    supervisor: Arc<Supervisor>,
    lineage: Vec<(u32, String)>,
    state: Mutex<Waiting>,
}

impl Watch {
    /// Items are tracked by id, so one a chat publishes again counts once.
    pub(crate) fn published(&self, delta: &Delta) {
        let mut waiting = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        waiting
            .open
            .extend(delta.added.iter().map(|item| id_of(item).to_string()));
        for id in &delta.settled {
            waiting.open.remove(id);
        }
        match (&waiting.blocking, waiting.open.is_empty()) {
            (None, false) => {
                if let Some(id) = self.supervisor.run_among(&self.lineage) {
                    self.supervisor.block(&id, true);
                    waiting.blocking = Some(id);
                }
            }
            (Some(id), true) => {
                self.supervisor.block(id, false);
                waiting.blocking = None;
            }
            _ => {}
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        let waiting = self.state.get_mut().unwrap_or_else(PoisonError::into_inner);
        if let Some(id) = waiting.blocking.take() {
            self.supervisor.block(&id, false);
        }
    }
}

fn id_of(item: &AgendaItem) -> &str {
    match item {
        AgendaItem::ParkedCall { id, .. }
        | AgendaItem::GateQuestion { id, .. }
        | AgendaItem::Question { id, .. } => id,
    }
}

/// `pid` and its ancestors with their starts, so a pid reused since is not taken for its
/// earlier owner; the walk stops at the first process the table cannot read. Reads the process
/// table, which may block.
pub(crate) fn lineage_of(pid: u32) -> Vec<(u32, String)> {
    let first = ProcTable.process(pid).map(|process| (pid, process));
    std::iter::successors(first, |(at, process)| {
        let parent = process
            .parent
            .filter(|&parent| parent != 0 && parent != *at)?;
        ProcTable.process(parent).map(|process| (parent, process))
    })
    .take(MAX_ANCESTORS)
    .map(|(at, process)| (at, process.start))
    .collect()
}

/// Runs an action when asked, and again at most once per period however often it is asked in
/// between: a request that arrives while one is waiting its turn joins it.
pub(crate) struct Coalescer {
    period: Duration,
    action: Box<dyn Fn() -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>,
    pacing: Mutex<Pacing>,
}

#[derive(Default)]
struct Pacing {
    running: bool,
    asked: bool,
    last: Option<Instant>,
}

impl Coalescer {
    pub(crate) fn new<F, Fut>(period: Duration, action: F) -> Arc<Self>
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        Arc::new(Self {
            period,
            action: Box::new(move || Box::pin(action())),
            pacing: Mutex::new(Pacing::default()),
        })
    }

    fn pacing(&self) -> MutexGuard<'_, Pacing> {
        self.pacing.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Does nothing outside a runtime, which is a daemon already on its way out.
    pub(crate) fn request(self: &Arc<Self>) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        {
            let mut pacing = self.pacing();
            if pacing.running {
                pacing.asked = true;
                return;
            }
            pacing.running = true;
        }
        let this = Arc::clone(self);
        runtime.spawn(async move { this.drain().await });
    }

    async fn drain(&self) {
        loop {
            let last = self.pacing().last;
            if let Some(last) = last {
                tokio::time::sleep_until(last + self.period).await;
            }
            {
                let mut pacing = self.pacing();
                pacing.asked = false;
                pacing.last = Some(Instant::now());
            }
            (self.action)().await;
            let mut pacing = self.pacing();
            if !pacing.asked {
                pacing.running = false;
                return;
            }
        }
    }
}

/// `lain daemon herdr-sync`, which reads `run.list` and shows it in herdr. It has no say over a
/// run, so a failure is a trace line and nothing more.
async fn herdr_sync(settings: Settings, bound: Duration) {
    let mut command = tokio::process::Command::new(&settings.ruby);
    command
        .arg(&settings.lain)
        .args(["daemon", "herdr-sync"])
        .env_clear()
        .envs(settings.env.iter().map(|(name, value)| (name, value)))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    match tokio::time::timeout(bound, command.status()).await {
        Ok(Ok(status)) if status.success() => {}
        Ok(Ok(status)) => tracing::warn!(%status, "herdr-sync failed"),
        Ok(Err(error)) => tracing::warn!(%error, "could not run herdr-sync"),
        Err(_) => tracing::warn!(?bound, "killed a herdr-sync that did not end"),
    }
}

/// A run's process: the daemon's own child, or one the spawner forked and reports on.
enum Process {
    Child(tokio::process::Child),
    Forked(watch::Receiver<Option<i32>>),
}

impl Process {
    fn is_forked(&self) -> bool {
        matches!(self, Self::Forked(_))
    }

    /// Whether its exit is still unknown, so its group is still its own to signal.
    fn running(&self) -> bool {
        match self {
            Self::Child(_) => true,
            Self::Forked(exit) => exit.borrow().is_none(),
        }
    }

    /// Its status; -1 when it cannot be known, as for a forked run whose spawner went first.
    async fn wait(&mut self, pid: u32, start: Option<&str>) -> i32 {
        match self {
            Self::Child(child) => match child.wait().await {
                Ok(status) => code_of(status),
                Err(error) => {
                    tracing::error!(%error, pid, "could not wait for a run");
                    -1
                }
            },
            Self::Forked(exit) => {
                if let Ok(code) = exit.wait_for(Option::is_some).await {
                    return code.unwrap_or(-1);
                }
                tracing::warn!(pid, "the spawner went before the run it forked ended");
                // A start never read means the run was gone when it was looked for, or `ps` failed
                // (macOS), and its pid alone could name a later process forever.
                let Some(start) = start else {
                    return -1;
                };
                while still(pid, start).await {
                    tokio::time::sleep(ORPHAN_POLL).await;
                }
                -1
            }
        }
    }
}

/// Whether `pid` is still the process that had `start`.
async fn still(pid: u32, start: &str) -> bool {
    let start = start.to_string();
    tokio::task::spawn_blocking(move || {
        ProcTable
            .process(pid)
            .is_some_and(|process| process.start == start)
    })
    .await
    .unwrap_or(false)
}

/// Called only by the task that owns `process`. A child is not reaped before this returns, so
/// its group is its own; a forked run's group is signalled only while its exit is unreported.
async fn stopped(process: &mut Process, pid: u32, start: Option<&str>) -> i32 {
    if process.running() {
        signal_group(pid, Signal::SIGTERM);
    }
    match tokio::time::timeout(GRACE, process.wait(pid, start)).await {
        Ok(code) => code,
        Err(_) => {
            if process.running() {
                signal_group(pid, Signal::SIGKILL);
            }
            process.wait(pid, start).await
        }
    }
}

/// `None`, with a trace line, when it cannot start: runs then start by exec.
fn start_spawner(settings: &Settings) -> Option<Arc<Spawner>> {
    Spawner::start(settings, crate::PROVIDER_KEY_VAR)
        .inspect_err(|error| tracing::warn!(%error, "could not start the spawner"))
        .ok()
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
pub(crate) fn project_root(root: &str) -> Result<PathBuf, RpcError> {
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
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use super::*;

    /// Ignores TERM in its whole group, noting each one, so only a KILL ends it.
    const STUBBORN: &str = r#"#!/bin/sh
[ "$2" = daemon ] && exit 0
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
                profile: Default::default(),
            })
            .await
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

    /// Lets the spawned sync task run every step it can without the clock moving.
    async fn settle() {
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_burst_of_sync_requests_runs_the_action_once_a_second_at_most() {
        let count = Arc::new(AtomicU64::new(0));
        let sync = Coalescer::new(Duration::from_secs(1), {
            let count = Arc::clone(&count);
            move || {
                let count = Arc::clone(&count);
                async move {
                    count.fetch_add(1, Ordering::Relaxed);
                }
            }
        });

        sync.request();
        settle().await;
        assert_eq!(
            1,
            count.load(Ordering::Relaxed),
            "the first request runs at once"
        );

        for _ in 0..10 {
            sync.request();
        }
        settle().await;
        tokio::time::advance(Duration::from_millis(999)).await;
        settle().await;
        assert_eq!(1, count.load(Ordering::Relaxed), "ran inside the second");

        tokio::time::advance(Duration::from_millis(1)).await;
        settle().await;
        assert_eq!(2, count.load(Ordering::Relaxed), "the burst is 1 run");

        tokio::time::advance(Duration::from_secs(60)).await;
        sync.request();
        settle().await;
        assert_eq!(
            3,
            count.load(Ordering::Relaxed),
            "a quiet minute waits for nothing"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_request_made_while_the_action_runs_runs_it_again_afterwards() {
        let started = Arc::new(AtomicU64::new(0));
        let gate = Arc::new(tokio::sync::Notify::new());
        let sync = Coalescer::new(Duration::from_secs(1), {
            let (started, gate) = (Arc::clone(&started), Arc::clone(&gate));
            move || {
                let (started, gate) = (Arc::clone(&started), Arc::clone(&gate));
                async move {
                    started.fetch_add(1, Ordering::Relaxed);
                    gate.notified().await;
                }
            }
        });

        sync.request();
        settle().await;
        sync.request();
        gate.notify_one();
        settle().await;
        tokio::time::advance(Duration::from_secs(1)).await;
        settle().await;

        assert_eq!(2, started.load(Ordering::Relaxed));
    }

    const HANGER: &str =
        "#!/bin/sh\n[ \"$2\" = daemon ] || exit 0\necho $$ >> \"$PROBE/syncs\"\nexec sleep 60\n";

    /// A stand-in ruby that waits for `release` in the probe dir, so a run stays live as long as a test needs.
    const SLEEPER: &str = "#!/bin/sh\n[ \"$2\" = daemon ] && exit 0\nwhile [ ! -e \"$PROBE/release\" ]; do sleep 0.05; done\n";

    fn settings_for(dir: &Path, script: &str) -> Settings {
        let ruby = dir.join("ruby");
        std::fs::write(&ruby, script).expect("script");
        std::fs::set_permissions(&ruby, std::fs::Permissions::from_mode(0o755)).expect("chmod");
        std::fs::create_dir_all(dir.join("probe")).expect("probe");
        Settings {
            ruby,
            lain: dir.join("lain"),
            runs: dir.join("runs"),
            env: vec![
                ("PATH".into(), std::env::var_os("PATH").unwrap_or_default()),
                ("PROBE".into(), dir.join("probe").into_os_string()),
            ],
        }
    }

    async fn lines_after(path: &Path, more_than: usize) -> Vec<String> {
        for _ in 0..500 {
            let lines: Vec<String> = std::fs::read_to_string(path)
                .unwrap_or_default()
                .lines()
                .map(str::to_string)
                .collect();
            if lines.len() > more_than {
                return lines;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("{} never had more than {more_than} lines", path.display())
    }

    #[tokio::test]
    async fn a_herdr_sync_that_hangs_is_killed_at_its_bound_and_a_later_request_syncs_again() {
        let dir = tempfile::tempdir().expect("tempdir");
        let settings = settings_for(dir.path(), HANGER);
        let sync = Coalescer::new(Duration::from_millis(10), move || {
            herdr_sync(settings.clone(), Duration::from_millis(200))
        });
        let syncs = dir.path().join("probe").join("syncs");

        sync.request();
        let first: u32 = lines_after(&syncs, 0).await[0].parse().expect("pid");
        let mut gone = false;
        for _ in 0..500 {
            gone = !alive(first);
            if gone {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(gone, "the hung sync outlived its bound");

        sync.request();
        assert_eq!(2, lines_after(&syncs, 1).await.len());
    }

    /// A live run, its supervisor, and what a test needs to end it.
    struct Live {
        supervisor: Arc<Supervisor>,
        run: Run,
        probe: PathBuf,
        _dir: tempfile::TempDir,
    }

    impl Live {
        async fn start() -> Self {
            let dir = tempfile::tempdir().expect("tempdir");
            let project = dir.path().join("project");
            std::fs::create_dir_all(project.join(".git")).expect("project");
            let supervisor = Supervisor::new(Some(settings_for(dir.path(), SLEEPER)));
            let run = supervisor
                .start(lain_wire::RunStart {
                    kind: "chores".to_string(),
                    root: project.to_str().expect("utf-8").to_string(),
                    args: Default::default(),
                    profile: Default::default(),
                })
                .await
                .expect("started");
            for _ in 0..500 {
                if supervisor.runs().iter().all(|entry| entry.start.is_some()) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            Self {
                supervisor,
                run,
                probe: dir.path().join("probe"),
                _dir: dir,
            }
        }

        fn blocked(&self) -> bool {
            self.supervisor.list()[0].blocked
        }

        async fn ended(&self) {
            std::fs::write(self.probe.join("release"), "").expect("release");
            for _ in 0..500 {
                if self.supervisor.live() == 0 {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            panic!("the run never ended");
        }
    }

    fn parking(id: &str) -> Delta {
        Delta {
            cursor: 0,
            added: vec![AgendaItem::ParkedCall {
                id: id.to_string(),
                requester: "main".to_string(),
                tool: "bash".to_string(),
                input: "ls".to_string(),
                cwd: "/work".to_string(),
                why: "outside the checkout".to_string(),
                postponed: false,
                asked_at: 1_793_000_000,
                session: "s".to_string(),
                project: "/work".to_string(),
            }],
            settled: vec![],
        }
    }

    #[tokio::test]
    async fn an_ancestor_with_a_runs_pid_but_not_its_start_does_not_block_it() {
        let live = Live::start().await;
        let imposter = live
            .supervisor
            .watch(vec![(live.run.pid, "not-its-start".to_string())]);
        imposter.published(&parking("p1"));
        assert!(!live.blocked());

        let session = live.supervisor.watch(lineage_of(live.run.pid));
        session.published(&parking("p2"));
        assert!(live.blocked());
        drop(session);
        assert!(!live.blocked());
        live.ended().await;
    }

    #[tokio::test]
    async fn a_session_under_a_run_that_has_ended_blocks_nothing() {
        let live = Live::start().await;
        let lineage = lineage_of(live.run.pid);
        live.ended().await;

        let session = live.supervisor.watch(lineage);
        session.published(&parking("p1"));

        assert!(!live.blocked());
        drop(session);
    }

    /// A spawner that takes a request and never answers it; a run started any other way notes its pid.
    const DEAF: &str = "#!/bin/sh\nif [ \"$3\" = spawner ]; then echo $$ > \"$PROBE/spawner\"; head -n 1 > \"$PROBE/asked\"; exec sleep 60; fi\n[ \"$2\" = daemon ] && exit 0\necho $$ > \"$PROBE/run\"\n";

    #[tokio::test(start_paused = true)]
    async fn a_spawner_that_does_not_answer_in_time_is_dropped_and_the_run_starts_by_exec() {
        let dir = tempfile::tempdir().expect("tempdir");
        let project = dir.path().join("project");
        std::fs::create_dir_all(project.join(".git")).expect("project");
        let probe = dir.path().join("probe");
        let supervisor = Supervisor::new(Some(settings_for(dir.path(), DEAF)));
        let chores = || lain_wire::RunStart {
            kind: "chores".to_string(),
            root: project.to_str().expect("utf-8").to_string(),
            args: Default::default(),
            profile: Default::default(),
        };
        let first = supervisor.start(chores()).await.expect("started");
        assert_eq!(
            first.pid,
            appeared(&probe.join("run"))
                .trim()
                .parse::<u32>()
                .expect("pid"),
            "the first run did not start by exec"
        );
        std::fs::remove_file(probe.join("run")).expect("clear the probe");
        let spawner: u32 = appeared(&probe.join("spawner"))
            .trim()
            .parse()
            .expect("pid");

        let starting = tokio::spawn({
            let supervisor = Arc::clone(&supervisor);
            let request = chores();
            async move { supervisor.start(request).await }
        });
        settle().await;
        assert!(appeared(&probe.join("asked")).contains("argv"));
        assert!(
            !starting.is_finished(),
            "the start did not wait for the spawner"
        );

        tokio::time::advance(SPAWN_BOUND).await;
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while !starting.is_finished() {
            assert!(
                std::time::Instant::now() < deadline,
                "the start never gave up"
            );
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        let run = starting.await.expect("joined").expect("started");
        let ran: u32 = appeared(&probe.join("run")).trim().parse().expect("pid");
        assert_eq!(run.pid, ran, "the run did not start by exec");
        assert!(reaped(spawner), "the deaf spawner was left running");
    }

    /// A project, a supervisor running `script` for ruby, and the probe dir the script writes to.
    fn spawning(script: &str) -> (tempfile::TempDir, Arc<Supervisor>, PathBuf, RunStart) {
        let dir = tempfile::tempdir().expect("tempdir");
        let project = dir.path().join("project");
        std::fs::create_dir_all(project.join(".git")).expect("project");
        let supervisor = Supervisor::new(Some(settings_for(dir.path(), script)));
        let probe = dir.path().join("probe");
        let chores = RunStart {
            kind: "chores".to_string(),
            root: project.to_str().expect("utf-8").to_string(),
            args: Default::default(),
            profile: Default::default(),
        };
        (dir, supervisor, probe, chores)
    }

    fn pid_in(path: &Path) -> u32 {
        appeared(path).trim().parse().expect("a pid")
    }

    /// Forks a run in a session of its own when it reads a request, and answers with its pid only
    /// once `go` exists in the probe dir. A run started by exec notes its pid in `execd`.
    const SLOW_ANSWER: &str = r#"#!/bin/sh
if [ "$3" = spawner ]; then
  echo $$ > "$PROBE/spawner"
  IFS= read -r line
  setsid sleep 25 & late=$!
  echo $late > "$PROBE/late"
  while [ ! -e "$PROBE/go" ]; do sleep 0.02; done
  echo "{\"pid\":$late}" >&0
  exec sleep 25
fi
[ "$2" = daemon ] && exit 0
echo $$ >> "$PROBE/execd"
exec sleep 25
"#;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_start_dropped_while_the_spawner_forks_still_lists_its_run() {
        let (_dir, supervisor, probe, chores) = spawning(SLOW_ANSWER);
        let first = supervisor.start(chores.clone()).await.expect("first");
        let _first = KillOnDrop(Some(first.pid));
        pid_in(&probe.join("spawner"));

        let mut start = Box::pin(supervisor.start(chores));
        let late = loop {
            tokio::select! {
                biased;
                _ = &mut start => panic!("the spawner answered before it was let"),
                () = tokio::time::sleep(Duration::from_millis(10)) => {}
            }
            if let Ok(late) = std::fs::read_to_string(probe.join("late"))
                && let Ok(late) = late.trim().parse::<u32>()
            {
                break late;
            }
        };
        drop(start);
        let _late = KillOnDrop(Some(late));
        std::fs::write(probe.join("go"), "").expect("let the spawner answer");

        for _ in 0..500 {
            if supervisor.list().iter().any(|run| run.pid == late) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("the fork of a dropped start was never listed");
    }

    /// As [`SLOW_ANSWER`], but the answer comes from a process in a session of its own, so it
    /// still arrives after the spawner is killed. A background job's stdin is /dev/null, so it
    /// writes to the socket through fd 3.
    const LATE_ANSWER: &str = r#"#!/bin/sh
if [ "$3" = spawner ]; then
  echo $$ > "$PROBE/spawner"
  exec 3<&0
  IFS= read -r line
  setsid sleep 25 & late=$!
  echo $late > "$PROBE/late"
  setsid sh -c 'while [ ! -e "$PROBE/go" ]; do sleep 0.02; done; echo "{\"pid\":$0}"' "$late" >&3 &
  exec sleep 25
fi
[ "$2" = daemon ] && exit 0
echo $$ >> "$PROBE/execd"
exec sleep 25
"#;

    #[tokio::test(start_paused = true)]
    async fn a_fork_answered_after_the_start_gave_up_is_killed_and_only_the_exec_run_lists() {
        let (_dir, supervisor, probe, chores) = spawning(LATE_ANSWER);
        let first = supervisor.start(chores.clone()).await.expect("first");
        let _first = KillOnDrop(Some(first.pid));
        pid_in(&probe.join("spawner"));

        let starting = tokio::spawn({
            let supervisor = Arc::clone(&supervisor);
            async move { supervisor.start(chores).await }
        });
        settle().await;
        let late = pid_in(&probe.join("late"));
        let _late = KillOnDrop(Some(late));
        tokio::time::advance(SPAWN_BOUND).await;
        for _ in 0..500 {
            if starting.is_finished() {
                break;
            }
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        let run = starting.await.expect("joined").expect("started");
        let _run = KillOnDrop(Some(run.pid));

        std::fs::write(probe.join("go"), "").expect("let the late answer through");
        for _ in 0..500 {
            if !alive(late) {
                break;
            }
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!alive(late), "the fork its start gave up on still runs");
        let listed: Vec<u32> = supervisor.list().iter().map(|run| run.pid).collect();
        assert_eq!(vec![first.pid, run.pid], listed);
    }

    /// The first spawner answers its first request stale and then reads nothing more, as a real
    /// one does; every later spawner forks each request in a session of its own.
    const STALE_FIRST: &str = r#"#!/bin/sh
if [ "$3" = spawner ]; then
  n=$(ls "$PROBE" | grep -c '^spawner\.')
  echo $$ > "$PROBE/spawner.$n"
  if [ "$n" = 0 ]; then IFS= read -r line; echo '{"stale":true}' >&0; exec sleep 25; fi
  while IFS= read -r line; do
    setsid sleep 25 & echo $! >> "$PROBE/forked"; echo "{\"pid\":$!}" >&0
  done
  exit 0
fi
[ "$2" = daemon ] && exit 0
echo $$ >> "$PROBE/execd"
exec sleep 25
"#;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn two_starts_at_a_stale_spawner_both_fork_from_1_fresh_spawner() {
        let (_dir, supervisor, probe, chores) = spawning(STALE_FIRST);
        let first = supervisor.start(chores.clone()).await.expect("first");
        let _first = KillOnDrop(Some(first.pid));
        let stale = pid_in(&probe.join("spawner.0"));
        let _stale = KillOnDrop(Some(stale));

        let (a, b) = tokio::join!(
            supervisor.start(chores.clone()),
            supervisor.start(chores.clone())
        );
        let (a, b) = (a.expect("a"), b.expect("b"));
        let _runs = (KillOnDrop(Some(a.pid)), KillOnDrop(Some(b.pid)));

        let mut forked: Vec<u32> = std::fs::read_to_string(probe.join("forked"))
            .unwrap_or_default()
            .lines()
            .map(|pid| pid.parse().expect("a pid"))
            .collect();
        forked.sort_unstable();
        let mut started = vec![a.pid, b.pid];
        started.sort_unstable();
        assert_eq!(started, forked, "a start fell back to exec");
        let fresh = pid_in(&probe.join("spawner.1"));
        let _fresh = KillOnDrop(Some(fresh));
        assert!(!probe.join("spawner.2").exists(), "a third spawner booted");
        assert!(alive(fresh), "the fresh spawner was torn down");
    }

    #[tokio::test]
    async fn starts_that_saw_the_same_spawner_fail_boot_1_spawner_between_them() {
        let dir = tempfile::tempdir().expect("tempdir");
        let script = "#!/bin/sh\n[ \"$3\" = spawner ] && exec sleep 25\nexit 0\n";
        let supervisor = Supervisor::new(Some(settings_for(dir.path(), script)));
        supervisor.restart_spawner(None);
        let failed = supervisor.spawner().expect("a spawner");

        supervisor.restart_spawner(Some(&failed));
        let fresh = supervisor.spawner().expect("a fresh spawner");
        supervisor.restart_spawner(Some(&failed));

        assert!(!Arc::ptr_eq(&failed, &fresh), "the failed spawner was kept");
        let current = supervisor.spawner().expect("a spawner");
        assert!(
            Arc::ptr_eq(&fresh, &current),
            "a second start booted another spawner"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_forked_run_whose_start_was_never_read_ends_when_its_spawner_goes() {
        let (spawner, exit) = watch::channel(None);
        drop(spawner);
        let mut process = Process::Forked(exit);

        let code = tokio::time::timeout(
            Duration::from_secs(3600),
            process.wait(std::process::id(), None),
        )
        .await;

        assert_eq!(
            Some(-1),
            code.ok(),
            "a live pid of unknown start kept it listed"
        );
    }

    #[tokio::test]
    async fn a_run_that_ends_while_its_session_still_waits_is_not_blocked() {
        let live = Live::start().await;
        let session = live.supervisor.watch(lineage_of(live.run.pid));
        session.published(&parking("p1"));
        assert!(live.blocked());

        live.ended().await;

        assert!(!live.blocked());
        drop(session);
    }
}
