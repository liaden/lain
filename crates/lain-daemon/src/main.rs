//! lain-daemon: the per-user daemon, a msgpack-RPC server on a Unix socket.
//!
//! The socket path and trace path arrive via argv and the launch digests via the environment: this binary NEVER computes
//! its own path, because path policy belongs to Ruby (`Paths#runtime_dir`). Tracing goes to a file,
//! never a terminal: the Journal is NDJSON and one stray diagnostic line breaks the experiment record.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr, missing_docs)]

mod agenda_watch;
mod ntfy;
mod periodic;
mod registry;
mod relay;
mod spawner;
mod supervisor;

use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, OnceLock};

use lain_rpc::{Conn, Handler, Peer, Push, RpcError, Session};
use lain_wire::Register;
use rmpv::Value;
use tokio::sync::mpsc;

use registry::{Registration, Registry};
use supervisor::{Run, Supervisor};

/// Bad invocation or an unopenable trace path. There is no usage text on purpose: this binary
/// may never touch stdout/stderr, so a bad invocation is an exit code, not a message.
const USAGE_ERROR: u8 = 2;
/// The socket could not be bound, or a live daemon already holds it.
const BIND_ERROR: u8 = 1;
/// The relay could not confine itself, so it did not run.
const CONFINE_ERROR: u8 = 3;

/// The crate version and the git sha `rake daemon:build` stamps in.
fn build_id() -> String {
    build_id_of(env!("CARGO_PKG_VERSION"), option_env!("LAIN_GIT_SHA"))
}

/// An empty sha is a build outside a checkout, the same as none.
fn build_id_of(version: &str, sha: Option<&str>) -> String {
    format!(
        "{version} {}",
        sha.filter(|sha| !sha.is_empty()).unwrap_or("unknown")
    )
}

struct Args {
    socket: PathBuf,
    trace: Option<PathBuf>,
    /// What only a new build, another checkout or ruby, or the provider key added or removed changes;
    /// a daemon whose build digest differs is replaced.
    build_digest: String,
    /// The relay, devices file, review poll, ntfy topic and runs dir it runs with; a difference is
    /// told, never replaced. None when the environment held a build digest alone.
    settings_digest: Option<String>,
    /// The phone relay's listen address and devices file, given together or not at all.
    relay: Option<(String, PathBuf)>,
    /// The ntfy topic items still waiting after a minute are announced on; only a relay has items.
    ntfy: Option<String>,
    /// The ruby, the `exe/lain` and the log directory every run is started with, given together or
    /// not at all.
    run: Option<(PathBuf, PathBuf, PathBuf)>,
    /// Whether the user's review poll runs beside the projects' own; only a daemon that runs
    /// things can run it.
    poll_user: bool,
}

impl Args {
    /// `ntfy` is the topic from the environment: `/proc/<pid>/cmdline` is readable by every user and
    /// a topic is as good as a password to anyone who can post to it, so it never rides in argv.
    fn parse(
        mut args: impl Iterator<Item = String>,
        ntfy: Option<String>,
        launch_digest: Option<String>,
    ) -> Option<Self> {
        let (mut socket, mut trace) = (None, None);
        let (mut listen, mut devices) = (None, None);
        let (mut ruby, mut lain, mut runs) = (None, None, None);
        let mut poll_user = false;
        while let Some(flag) = args.next() {
            if flag == "--poll-user" {
                poll_user = true;
                continue;
            }
            let value = args.next()?;
            match flag.as_str() {
                "--socket" => socket = Some(PathBuf::from(value)),
                "--trace" => trace = Some(PathBuf::from(value)),
                "--relay" => listen = Some(value),
                "--devices-file" => devices = Some(PathBuf::from(value)),
                "--ruby" => ruby = Some(PathBuf::from(value)),
                "--lain" => lain = Some(PathBuf::from(value)),
                "--runs-dir" => runs = Some(PathBuf::from(value)),
                _ => return None,
            }
        }
        let run = match (ruby, lain, runs) {
            (Some(ruby), Some(lain), Some(runs)) => Some((ruby, lain, runs)),
            (None, None, None) => None,
            _ => return None,
        };
        if poll_user && run.is_none() {
            return None;
        }
        let relay = match (listen, devices) {
            (Some(listen), Some(devices)) => Some((listen, devices)),
            (None, None) => None,
            _ => return None,
        };
        if !ntfy.as_deref().is_none_or(is_topic_url) || (ntfy.is_some() && relay.is_none()) {
            return None;
        }
        let digests = launch_digest?;
        let (build_digest, settings_digest) = match digests.split_once(' ') {
            Some((build, settings)) => (build.to_string(), Some(settings.to_string())),
            None => (digests, None),
        };
        Some(Self {
            socket: socket?,
            trace,
            build_digest,
            settings_digest,
            relay,
            ntfy,
            run,
            poll_user,
        })
    }
}

/// The user's config accepts `HTTPS://host/topic`, since a URI's scheme has no case, so this does
/// too: refusing it here would end the whole daemon for a topic the config let through.
fn is_topic_url(url: &str) -> bool {
    url.split_once("://").is_some_and(|(scheme, _)| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}

/// The env var `Daemon::Launch` hands the daemon the ntfy topic in.
pub(crate) const NTFY_VAR: &str = "DAEMON_NTFY_TOPIC";

/// The one secret `Daemon::Launch` hands the daemon, only for its runs.
pub(crate) const PROVIDER_KEY_VAR: &str = "ANTHROPIC_API_KEY";

/// Where `Daemon::Launch` hands the daemon its build digest and its settings digest, in that order and
/// split by a space. The settings digest hashes the topic, so on a command line it would let a user
/// test guesses at the topic.
pub(crate) const DIGEST_VAR: &str = "DAEMON_LAUNCH_DIGEST";

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1).peekable();
    if args.next_if_eq("relay").is_some() {
        return relay(args);
    }
    let Some(args) = Args::parse(
        args,
        std::env::var(NTFY_VAR).ok(),
        std::env::var(DIGEST_VAR).ok(),
    ) else {
        return ExitCode::from(USAGE_ERROR);
    };
    let trace = args.trace.as_deref().unwrap_or(Path::new("/dev/null"));
    if init_tracing(trace, "daemon").is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    serve_unix(args)
}

/// `lain-daemon relay [--unix <sock>] --listen <addr>:<port> --devices-file <path> [--trace <path>]`.
///
/// Takes its sockets and reads the paired devices, then confines the process while it is still
/// one thread: Landlock binds the calling thread and the threads it spawns after, so the
/// runtime's workers start inside the ruleset.
fn relay(args: impl Iterator<Item = String>) -> ExitCode {
    let Some(config) = relay::Config::parse(args) else {
        return ExitCode::from(USAGE_ERROR);
    };
    let trace = config.trace.as_deref().unwrap_or("/dev/null");
    if init_tracing(Path::new(trace), "relay").is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    let started = relay::Bound::open(&config).and_then(|bound| {
        relay::confine(bound.devices_directory(), config.socket_dir()).inspect_err(|_| {
            if let Some(unix) = &config.unix {
                let _ = std::fs::remove_file(unix);
            }
        })?;
        Ok(bound)
    });
    match started {
        Ok(bound) => serve_relay(bound, config.unix.as_deref()),
        Err(error) => {
            tracing::error!(%error, "the relay did not start");
            ExitCode::from(error.exit_code())
        }
    }
}

#[tokio::main]
async fn serve_relay(bound: relay::Bound, socket: Option<&Path>) -> ExitCode {
    let code = match bound.serve() {
        Ok(relay) => {
            tracing::info!(pid = std::process::id(), "lain-daemon relay listening");
            tokio::select! {
                () = relay => ExitCode::SUCCESS,
                code = shutdown_signal() => code,
            }
        }
        Err(error) => {
            tracing::error!(%error, "could not adopt the relay's listeners");
            ExitCode::from(BIND_ERROR)
        }
    };
    if let Some(socket) = socket
        && let Err(error) = std::fs::remove_file(socket)
    {
        tracing::warn!(%error, "could not remove the relay's socket");
    }
    code
}

/// What the daemon answers beyond `ping`, which `lain_rpc::serve` answers itself. No local
/// method answers an approval or a question: answers come only from the phone or the chat itself.
struct Daemon {
    build_digest: String,
    settings_digest: Option<String>,
    registry: Arc<Registry>,
    owner_uid: u32,
    relay: PhoneRelay,
    runs: Arc<Supervisor>,
    /// Whether the env runs inherit holds the provider key, so a launch that has it can say why
    /// a kept daemon's runs cannot reach anthropic.
    provider_key: bool,
}

/// The phone relay the daemon runs, as `daemon.info` reports it.
enum PhoneRelay {
    Off,
    Unavailable,
    Running(Arc<relay::Worker>),
}

impl PhoneRelay {
    fn state(&self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Running(worker) if worker.is_running() => "running",
            Self::Unavailable | Self::Running(_) => "unavailable",
        }
    }

    /// `spawn` starts the worker, given the relay's address and devices file, the registry and where
    /// it reports its items; `delay` is how long an item waits before the topic hears of it.
    fn start(
        args: &Args,
        registry: &Arc<Registry>,
        delay: std::time::Duration,
        spawn: impl FnOnce(
            &str,
            &Path,
            Arc<Registry>,
            mpsc::UnboundedSender<relay::Event>,
        ) -> io::Result<Arc<relay::Worker>>,
    ) -> Self {
        let Some((listen, devices)) = &args.relay else {
            return Self::Off;
        };
        let (events, announced) = mpsc::unbounded_channel();
        if let Some(topic) = &args.ntfy {
            let notifier = Arc::new(ntfy::Ntfy::new(topic.clone()));
            tokio::spawn(agenda_watch::run(announced, notifier, delay));
        }
        match spawn(listen, devices, Arc::clone(registry), events) {
            Ok(worker) => Self::Running(worker),
            Err(error) => {
                tracing::error!(%error, "could not start the relay worker");
                Self::Unavailable
            }
        }
    }
}

/// One local connection: who is on the other end, how to push to it, and the session it
/// registered, if any.
struct Caller {
    peer: Peer,
    push: Push,
    registration: OnceLock<Registration>,
    /// What the registered session has waiting on a human, for the run that started it.
    watch: OnceLock<supervisor::Watch>,
}

impl Session for Caller {
    fn opened(conn: &Conn) -> Self {
        Self {
            peer: conn.peer,
            push: conn.push.clone(),
            registration: OnceLock::new(),
            watch: OnceLock::new(),
        }
    }
}

impl Handler for Daemon {
    type Session = Caller;

    async fn call(
        &self,
        caller: &Caller,
        method: &str,
        params: Vec<Value>,
    ) -> Result<Value, RpcError> {
        if caller.peer.uid != Some(self.owner_uid) {
            tracing::warn!(code = "other_user", peer = ?caller.peer, method, "refused a call");
            return Err(RpcError::Refused {
                code: "other_user",
                message: "only the daemon's own user may call it".to_string(),
            });
        }
        match method {
            "daemon.info" => Ok(Value::Map(vec![
                (Value::from("build_id"), Value::from(build_id())),
                (
                    Value::from("build_digest"),
                    Value::from(self.build_digest.as_str()),
                ),
                (
                    Value::from("settings_digest"),
                    self.settings_digest.as_deref().map_or(Value::Nil, Value::from),
                ),
                (Value::from("relay"), Value::from(self.relay.state())),
                (Value::from("live_runs"), Value::from(self.runs.live())),
                (Value::from("provider_key"), Value::from(self.provider_key)),
            ])),
            "session.register" => self.register(caller, params).await.inspect_err(|error| {
                if let RpcError::Refused { code, message } = error {
                    tracing::warn!(code, peer = ?caller.peer, ?message, "refused a session.register");
                }
            }),
            "agenda.publish" => self.publish(caller, params).await,
            "session.list" => Ok(Value::Array(
                self.registry
                    .list()
                    .iter()
                    .map(registry::Record::to_value)
                    .collect(),
            )),
            "offer.send" => self.offer(params).await,
            "offer.reply" => self.offer_reply(caller, params),
            "run.start" => self.run_start(params).await.inspect_err(|error| {
                if let RpcError::Refused { code, .. } = error {
                    tracing::warn!(code, peer = ?caller.peer, "refused a run.start");
                }
            }),
            "run.list" => Ok(Value::Array(
                self.runs.list().iter().map(Run::to_value).collect(),
            )),
            "run.stop" => {
                let stop: lain_wire::RunStop = decoded(params, "run.stop takes [{id}]")?;
                self.runs.stop(&stop.id).await.map(|run| run.to_value())
            }
            other => Err(RpcError::UnknownMethod(other.to_string())),
        }
    }
}

impl Daemon {
    /// Forwarded stamped with the caller's registration, so an item belongs to the session and
    /// project the daemon checked, whatever the item says.
    async fn publish(&self, caller: &Caller, params: Vec<Value>) -> Result<Value, RpcError> {
        let registration = caller.registration.get().ok_or_else(|| RpcError::Refused {
            code: "not_registered",
            message: "register this connection before publishing".to_string(),
        })?;
        let worker = match &self.relay {
            PhoneRelay::Running(worker) => worker,
            PhoneRelay::Unavailable => {
                return Err(RpcError::Refused {
                    code: "relay_unavailable",
                    message: "the phone relay is unavailable".to_string(),
                });
            }
            PhoneRelay::Off => {
                return Err(RpcError::Refused {
                    code: "no_relay",
                    message: "the daemon runs no phone relay".to_string(),
                });
            }
        };
        let malformed = || RpcError::Refused {
            code: "bad_params",
            message: "agenda.publish takes [Delta] or [Delta, gate keys]".to_string(),
        };
        let mut params = params.into_iter();
        let delta = params.next().ok_or_else(malformed)?;
        let keys = params.next().unwrap_or(Value::Map(vec![]));
        if !keys.is_map() || params.next().is_some() {
            return Err(malformed());
        }
        let published = readable_delta(&delta)?;
        let stamp = relay::Stamp {
            session: registration.session_id().to_string(),
            project: registration.root().to_string(),
            registration: registration.registration(),
            pid: caller.peer.pid.unwrap_or_default(),
        };
        let answer = worker.publish(&stamp, delta, keys).await?;
        if let Some(watch) = caller.watch.get() {
            watch.published(&published);
        }
        Ok(answer)
    }

    async fn register(&self, caller: &Caller, params: Vec<Value>) -> Result<Value, RpcError> {
        if caller.registration.get().is_some() {
            return Err(already_registered());
        }
        let register: Register = decoded(params, "session.register takes [Register]")?;
        let registry = Arc::clone(&self.registry);
        let peer = caller.peer;
        // The process table may be read through `ps`, which blocks.
        let (registration, lineage) = tokio::task::spawn_blocking(move || {
            let registration = registry.register(peer, register)?;
            Ok::<_, RpcError>((
                registration,
                supervisor::lineage_of(peer.pid.unwrap_or_default()),
            ))
        })
        .await
        .map_err(|error| RpcError::Refused {
            code: "internal",
            message: format!("registration failed: {error}"),
        })??;
        registration.attach(caller.push.clone());
        caller
            .registration
            .set(registration)
            .map_err(|_raced| already_registered())?;
        let _first = caller.watch.set(self.runs.watch(lineage));
        Ok(Value::Nil)
    }
}

impl Daemon {
    /// Pushes the offer to the newest attended chat in its root and waits for that chat to say
    /// what it did. The request and row go to the chat unread.
    async fn offer(&self, params: Vec<Value>) -> Result<Value, RpcError> {
        let offer: lain_wire::Offer = decoded(params, "offer.send takes [Offer]")?;
        let Some(recipients) = self.registry.recipients(&offer.root) else {
            return Ok(offered(None, &[], None));
        };
        let pending = self.registry.open_offer(recipients.chosen.registration);
        let pushed = recipients.chosen.outlet.as_ref().is_some_and(|outlet| {
            outlet
                .send("offer", vec![offer_push(pending.id(), &offer)])
                .is_ok()
        });
        let reply = if pushed {
            pending.reply(registry::OFFER_REPLY).await
        } else {
            None
        };
        Ok(offered(Some(&recipients.chosen), &recipients.others, reply))
    }

    fn offer_reply(&self, caller: &Caller, params: Vec<Value>) -> Result<Value, RpcError> {
        let registration = caller.registration.get().ok_or_else(|| RpcError::Refused {
            code: "not_registered",
            message: "only a registered chat replies to an offer".to_string(),
        })?;
        registration.reply(decoded(params, "offer.reply takes [OfferReply]")?)?;
        Ok(Value::Nil)
    }
}

impl Daemon {
    /// A request naming anything the kind does not take learns which name it was.
    async fn run_start(&self, params: Vec<Value>) -> Result<Value, RpcError> {
        let usage = "run.start takes [{kind, root, args, profile}]";
        let [param] = <[Value; 1]>::try_from(params).map_err(|_| RpcError::Refused {
            code: "bad_params",
            message: usage.to_string(),
        })?;
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &param).map_err(|_| RpcError::Refused {
            code: "bad_params",
            message: usage.to_string(),
        })?;
        let start: lain_wire::RunStart =
            lain_wire::decode(&bytes).map_err(|error| RpcError::Refused {
                code: "bad_params",
                message: format!("{usage}: {}", clipped(&error.to_string())),
            })?;
        self.runs.start(start).await.map(|run| run.to_value())
    }
}

fn clipped(text: &str) -> String {
    text.chars().take(200).collect()
}

/// What the chat was pushed: the offer's id to reply with, and the request and row as sent.
fn offer_push(offer_id: u64, offer: &lain_wire::Offer) -> Value {
    let map = |fields: &std::collections::BTreeMap<String, Value>| {
        Value::Map(
            fields
                .iter()
                .map(|(key, value)| (Value::from(key.as_str()), value.clone()))
                .collect(),
        )
    };
    Value::Map(vec![
        (Value::from("offer_id"), Value::from(offer_id)),
        (Value::from("request"), map(&offer.request)),
        (Value::from("row"), map(&offer.row)),
    ])
}

/// `offer.send`'s answer: the chat chosen, the others in the root, and the chat's reply; a
/// chat that never replied is `silent`, and a root with no chat is `none`.
fn offered(
    chosen: Option<&registry::Record>,
    others: &[registry::Record],
    reply: Option<lain_wire::OfferReply>,
) -> Value {
    let outcome = match (chosen, &reply) {
        (None, _) => "none".to_string(),
        (Some(_), None) => "silent".to_string(),
        (Some(_), Some(reply)) => reply.outcome.clone(),
    };
    let field = reply.and_then(|reply| reply.field);
    Value::Map(vec![
        (
            Value::from("session"),
            chosen.map_or(Value::Nil, registry::Record::to_value),
        ),
        (
            Value::from("others"),
            Value::Array(others.iter().map(registry::Record::to_value).collect()),
        ),
        (Value::from("outcome"), Value::from(outcome)),
        (Value::from("field"), field.map_or(Value::Nil, Value::from)),
    ])
}

fn already_registered() -> RpcError {
    RpcError::Refused {
        code: "registered",
        message: "this connection already registered a session".to_string(),
    }
}

/// A publisher on an older wire learns which field it lacks, not the worker's own call shape.
fn readable_delta(delta: &Value) -> Result<lain_wire::Delta, RpcError> {
    let unreadable = |reason: String| RpcError::Refused {
        code: "bad_params",
        message: format!("agenda.publish could not read its Delta: {reason}"),
    };
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, delta).map_err(|error| unreadable(error.to_string()))?;
    lain_wire::decode::<lain_wire::Delta>(&bytes).map_err(|error| unreadable(error.to_string()))
}

fn decoded<T: serde::de::DeserializeOwned>(params: Vec<Value>, usage: &str) -> Result<T, RpcError> {
    let malformed = || RpcError::Refused {
        code: "bad_params",
        message: usage.to_string(),
    };
    let [param] = <[Value; 1]>::try_from(params).map_err(|_| malformed())?;
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &param).map_err(|_| malformed())?;
    lain_wire::decode(&bytes).map_err(|_| malformed())
}

/// Each line opens with `role[pid]`, since the daemon and its relay worker write 1 file.
fn init_tracing(path: &Path, role: &str) -> io::Result<()> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    tracing_subscriber::fmt()
        .with_writer(std::sync::Mutex::new(file))
        .event_format(Tagged {
            tag: format!("{role}[{}]", std::process::id()),
            inner: tracing_subscriber::fmt::format().with_ansi(false),
        })
        .init();
    Ok(())
}

struct Tagged<F> {
    tag: String,
    inner: F,
}

impl<S, N, F> tracing_subscriber::fmt::FormatEvent<S, N> for Tagged<F>
where
    S: tracing::Subscriber + for<'lookup> tracing_subscriber::registry::LookupSpan<'lookup>,
    N: for<'writer> tracing_subscriber::fmt::FormatFields<'writer> + 'static,
    F: tracing_subscriber::fmt::FormatEvent<S, N>,
{
    fn format_event(
        &self,
        context: &tracing_subscriber::fmt::FmtContext<'_, S, N>,
        mut writer: tracing_subscriber::fmt::format::Writer<'_>,
        event: &tracing::Event<'_>,
    ) -> std::fmt::Result {
        write!(writer, "{} ", self.tag)?;
        self.inner.format_event(context, writer, event)
    }
}

/// A socket file nothing answers on is what a daemon that died leaves behind, so it is removed;
/// one a live process answers on, or a file that is not a socket, is never touched.
fn clear_stale_socket(path: &Path) -> io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
        Ok(metadata) if !metadata.file_type().is_socket() => {
            Err(io::Error::new(io::ErrorKind::AlreadyExists, "not a socket"))
        }
        Ok(_) => match std::os::unix::net::UnixStream::connect(path) {
            Ok(_) => Err(io::Error::new(io::ErrorKind::AddrInUse, "socket in use")),
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                std::fs::remove_file(path)
            }
            Err(error) => Err(error),
        },
    }
}

#[tokio::main]
async fn serve_unix(args: Args) -> ExitCode {
    let bound = clear_stale_socket(&args.socket)
        .and_then(|()| tokio::net::UnixListener::bind(&args.socket))
        .and_then(|listener| Ok((listener, owner_of(&args.socket)?)));
    let (listener, owner_uid) = match bound {
        Ok(bound) => bound,
        Err(error) => {
            tracing::error!(%error, socket = %args.socket.display(), "could not bind the socket");
            return ExitCode::from(BIND_ERROR);
        }
    };
    tracing::info!(socket = %args.socket.display(), pid = std::process::id(), "lain-daemon listening");
    let registry = Registry::new(registry::ProcTable);
    let relay = PhoneRelay::start(
        &args,
        &registry,
        agenda_watch::DELAY,
        |listen, devices, registry, events| {
            relay::Worker::spawn(listen, devices, args.trace.as_deref(), registry, events)
        },
    );
    let runs = start_supervisor(args.run, run_env(std::env::vars_os()));
    spawn_review_polls(&runs, &registry, args.poll_user, periodic::POLL_EVERY);
    let handler = Daemon {
        build_digest: args.build_digest,
        settings_digest: args.settings_digest,
        registry,
        owner_uid,
        relay,
        runs,
        provider_key: std::env::var_os(PROVIDER_KEY_VAR).is_some(),
    };
    let code = tokio::select! {
        never = lain_rpc::serve(listener, handler, env!("CARGO_PKG_VERSION")) => match never {},
        code = shutdown_signal() => code,
    };
    if let Err(error) = std::fs::remove_file(&args.socket) {
        tracing::warn!(%error, "could not remove the socket");
    }
    code
}

/// The runs' supervisor, with its spawner already booting so the first run forks from a warm one.
/// Must run inside the runtime.
fn start_supervisor(
    run: Option<(PathBuf, PathBuf, PathBuf)>,
    env: Vec<(std::ffi::OsString, std::ffi::OsString)>,
) -> Arc<Supervisor> {
    let runs = Supervisor::new(run.map(|(ruby, lain, runs)| supervisor::Settings {
        ruby,
        lain,
        runs,
        env,
    }));
    runs.warm();
    runs
}

/// The review polls' timer, which reads the registered roots afresh each `every`; `None` for a
/// daemon that runs nothing.
fn spawn_review_polls<P: registry::Procs>(
    runs: &Arc<Supervisor>,
    registry: &Arc<Registry<P>>,
    poll_user: bool,
    every: std::time::Duration,
) -> Option<tokio::task::JoinHandle<()>> {
    if !runs.runs_anything() {
        return None;
    }
    let polled = Arc::clone(registry);
    Some(tokio::spawn(periodic::poll_every(
        Arc::clone(runs),
        every,
        poll_user,
        move || polled.polled_roots(),
    )))
}

/// A run gets the daemon's own env, which `Daemon::Launch` allowlisted, less the topic and the
/// digest: those are the daemon's alone.
fn run_env(
    env: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
    env.filter(|(name, _)| name != NTFY_VAR && name != DIGEST_VAR)
        .collect()
}

/// The socket the daemon just bound is owned by its effective uid, read without `unsafe` `geteuid`.
fn owner_of(socket: &Path) -> io::Result<u32> {
    std::fs::metadata(socket).map(|metadata| metadata.uid())
}

/// SIGTERM/SIGINT land here so shutdown goes THROUGH the runtime: returning unwinds
/// `#[tokio::main]` and the runtime drops every in-flight task with its Drop glue, where the
/// default disposition would skip it and orphan whatever a task owned.
async fn shutdown_signal() -> ExitCode {
    use tokio::signal::unix::SignalKind;
    tokio::select! {
        () = wait_for(SignalKind::terminate()) => {}
        () = wait_for(SignalKind::interrupt()) => {}
    }
    tracing::info!("shutting down on signal");
    ExitCode::SUCCESS
}

async fn wait_for(kind: tokio::signal::unix::SignalKind) {
    match tokio::signal::unix::signal(kind) {
        Ok(mut stream) => {
            stream.recv().await;
        }
        Err(error) => {
            tracing::error!(%error, "could not install a signal handler");
            std::future::pending::<()>().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use std::time::Duration;

    use lain_rpc::Accept;
    use lain_rpc::support::{TestClient, request, response_parts};
    use lain_wire::{AgendaItem, Answer, Delta, Hello, Verdict, WIRE_VERSION};
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
    use tokio::net::{TcpListener, UnixStream};

    use super::*;

    const OWNER: u32 = 1000;
    const TOKEN: &str = "a-paired-phone-token";
    const WAIT: Duration = Duration::from_secs(5);

    /// A connection whose credentials the test chooses, so 1 test process can hold 2 sessions.
    struct Forged {
        stream: UnixStream,
        peer: Peer,
    }

    impl AsyncRead for Forged {
        fn poll_read(
            mut self: Pin<&mut Self>,
            context: &mut Context<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.stream).poll_read(context, buffer)
        }
    }

    impl AsyncWrite for Forged {
        fn poll_write(
            mut self: Pin<&mut Self>,
            context: &mut Context<'_>,
            bytes: &[u8],
        ) -> Poll<io::Result<usize>> {
            Pin::new(&mut self.stream).poll_write(context, bytes)
        }

        fn poll_flush(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.stream).poll_flush(context)
        }

        fn poll_shutdown(
            mut self: Pin<&mut Self>,
            context: &mut Context<'_>,
        ) -> Poll<io::Result<()>> {
            Pin::new(&mut self.stream).poll_shutdown(context)
        }
    }

    struct Doorway(tokio::sync::Mutex<mpsc::UnboundedReceiver<Forged>>);

    impl Accept for Doorway {
        type Connection = Forged;

        async fn accept(&self) -> io::Result<Forged> {
            match self.0.lock().await.recv().await {
                Some(forged) => Ok(forged),
                None => std::future::pending().await,
            }
        }

        fn peer(connection: &Forged) -> Peer {
            connection.peer
        }
    }

    /// The production handler served over [`Doorway`].
    struct Served(mpsc::UnboundedSender<Forged>);

    impl Served {
        fn start(daemon: Daemon) -> Self {
            let (door, entries) = mpsc::unbounded_channel();
            let doorway = Doorway(tokio::sync::Mutex::new(entries));
            tokio::spawn(async move { match lain_rpc::serve(doorway, daemon, "0.1.0").await {} });
            Self(door)
        }

        fn connect(&self, uid: Option<u32>, pid: u32) -> TestClient<UnixStream> {
            let (ours, theirs) = UnixStream::pair().expect("a socket pair");
            let peer = Peer {
                uid,
                pid: Some(pid),
            };
            self.0
                .send(Forged {
                    stream: theirs,
                    peer,
                })
                .expect("the server is listening");
            TestClient::over(ours)
        }
    }

    fn daemon(registry: Arc<Registry>, relay: PhoneRelay) -> Daemon {
        Daemon {
            build_digest: "abc".to_string(),
            settings_digest: Some("def".to_string()),
            registry,
            owner_uid: OWNER,
            relay,
            runs: Supervisor::new(None),
            provider_key: false,
        }
    }

    /// A process of its own, so a session it stands for is no other session's child.
    fn sleeper() -> tokio::process::Child {
        tokio::process::Command::new("sleep")
            .arg("60")
            .kill_on_drop(true)
            .spawn()
            .expect("spawn sleep")
    }

    fn registration(session_id: &str, pid: u32, root: &str) -> Value {
        Value::Map(vec![
            (Value::from("session_id"), Value::from(session_id)),
            (Value::from("pid"), Value::from(pid)),
            (Value::from("host"), Value::from("rainbow")),
            (Value::from("root"), Value::from(root)),
            (Value::from("cwd"), Value::from("/work/lib")),
            (Value::from("input_socket"), Value::Nil),
            (Value::from("journal"), Value::Nil),
            (Value::from("attended"), Value::from(true)),
            (
                Value::from("started_at"),
                Value::from("2026-11-17T10:00:00Z"),
            ),
        ])
    }

    fn value<T: serde::Serialize>(message: &T) -> Value {
        let bytes = lain_wire::encode(message).expect("encode a wire message");
        rmpv::decode::read_value(&mut bytes.as_slice()).expect("read it back")
    }

    fn message<T: serde::de::DeserializeOwned>(value: &Value) -> T {
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, value).expect("encode a value");
        lain_wire::decode(&bytes).expect("decode a wire message")
    }

    fn parked(id: &str, input: &str) -> AgendaItem {
        AgendaItem::ParkedCall {
            id: id.to_string(),
            requester: "main".to_string(),
            tool: "bash".to_string(),
            input: input.to_string(),
            cwd: "/work".to_string(),
            why: "outside the checkout".to_string(),
            postponed: false,
            asked_at: 1_793_000_000,
            session: "claimed-session".to_string(),
            project: "/claimed/project".to_string(),
        }
    }

    fn adding(item: AgendaItem) -> Value {
        value(&Delta {
            cursor: 0,
            added: vec![item],
            settled: vec![],
        })
    }

    fn approve(id: &str) -> Answer {
        Answer::Call {
            id: id.to_string(),
            verdict: Verdict::Approve { note: None },
            device: None,
        }
    }

    async fn call(client: &mut TestClient<UnixStream>, method: &str, params: Vec<Value>) -> Value {
        let (_, error, _) = client.call(1, method, params).await;
        error
    }

    /// A session registered as `session_id` in `root` for `process`.
    async fn session_in(
        served: &Served,
        session_id: &str,
        process: &tokio::process::Child,
        root: &str,
    ) -> TestClient<UnixStream> {
        let pid = process.id().expect("a pid");
        let mut client = served.connect(Some(OWNER), pid);
        let error = call(
            &mut client,
            "session.register",
            vec![registration(session_id, pid, root)],
        )
        .await;
        assert_eq!(Value::Nil, error, "{session_id} did not register");
        client
    }

    async fn session(
        served: &Served,
        session_id: &str,
        process: &tokio::process::Child,
    ) -> TestClient<UnixStream> {
        session_in(served, session_id, process, "/work").await
    }

    /// Where the news of items goes when a test does not listen for it.
    fn unheard() -> mpsc::UnboundedSender<relay::Event> {
        mpsc::unbounded_channel().0
    }

    /// The worker in-process, over a devices file pairing [`TOKEN`]; its phone address.
    fn worker(
        dir: &Path,
        registry: &Arc<Registry>,
        events: mpsc::UnboundedSender<relay::Event>,
    ) -> (Arc<relay::Worker>, std::net::SocketAddr) {
        use std::os::unix::fs::PermissionsExt;
        let remote = dir.join("remote");
        std::fs::create_dir(&remote).expect("the devices dir");
        let devices = remote.join("devices");
        let digest = blake3::hash(TOKEN.as_bytes()).to_hex();
        std::fs::write(&devices, format!("phone {digest}\n")).expect("the devices file");
        std::fs::set_permissions(&devices, std::fs::Permissions::from_mode(0o600)).expect("chmod");
        let mut watcher = relay::Watcher::new(relay::DevicesFile::new(devices));
        let roster = watcher.read().expect("read the devices");
        let phone = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        phone.set_nonblocking(true).expect("nonblocking");
        let phone = TcpListener::from_std(phone).expect("adopt");
        let address = phone.local_addr().expect("the phone address");
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        tokio::spawn(relay::serve_worker(theirs, phone, watcher, roster));
        (
            relay::Worker::over(ours, Arc::clone(registry), events),
            address,
        )
    }

    /// The daemon over an in-process worker, and that worker's phone address.
    async fn with_worker(dir: &Path) -> (Served, std::net::SocketAddr) {
        let registry = Registry::new(registry::ProcTable);
        let (worker, phone) = worker(dir, &registry, unheard());
        let served = Served::start(daemon(registry, PhoneRelay::Running(worker)));
        (served, phone)
    }

    async fn phone(address: std::net::SocketAddr) -> TestClient<tokio::net::TcpStream> {
        let mut phone = TestClient::connect_tcp(address).await;
        let hello = value(&Hello {
            wire_version: WIRE_VERSION,
            token: TOKEN.to_string(),
            cursor: 0,
        });
        assert_eq!(Value::Nil, phone.call(1, "hello", vec![hello]).await.1);
        phone
    }

    /// Every item open now, from a snapshot.
    async fn items(phone: &mut TestClient<tokio::net::TcpStream>) -> Vec<AgendaItem> {
        let at = value(&lain_wire::Cursor {
            cursor: u64::MAX,
            epoch: None,
        });
        let (_, error, result) = phone.call(2, "agenda.next", vec![at]).await;
        assert_eq!(Value::Nil, error);
        let page: lain_wire::AgendaPage = message(&result);
        page.deltas
            .into_iter()
            .flat_map(|delta| delta.added)
            .collect()
    }

    fn id_for_input(items: &[AgendaItem], wanted: &str) -> String {
        items
            .iter()
            .find_map(|item| match item {
                AgendaItem::ParkedCall { id, input, .. } if input == wanted => Some(id.clone()),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no item for {wanted} in {items:?}"))
    }

    /// The `[method, params]` of the next frame, which must be a push.
    async fn pushed(client: &mut TestClient<UnixStream>) -> (Value, Vec<Value>) {
        let frame = client.recv().await;
        let Value::Array(parts) = frame else {
            panic!("{frame} is not a frame")
        };
        assert_eq!(Value::from(2), parts[0], "not a push: {parts:?}");
        (
            parts[1].clone(),
            parts[2].as_array().expect("params").clone(),
        )
    }

    fn argv(flags: &[&str]) -> impl Iterator<Item = String> + use<> {
        ["--socket", "/run/d.sock"]
            .into_iter()
            .chain(flags.iter().copied())
            .map(str::to_string)
            .collect::<Vec<_>>()
            .into_iter()
    }

    /// What `Daemon::Launch` puts in the daemon's environment: its build digest, then its settings digest.
    fn digest() -> Option<String> {
        Some("abc def".to_string())
    }

    #[test]
    fn the_launch_digest_comes_from_the_environment_and_never_from_the_command_line() {
        let args = Args::parse(argv(&[]), None, digest()).expect("parse");
        assert_eq!(
            ("abc", Some("def")),
            (args.build_digest.as_str(), args.settings_digest.as_deref())
        );
        assert!(
            Args::parse(argv(&[]), None, None).is_none(),
            "a daemon with no digest started"
        );
        let flags = ["--launch-digest", "abc"];
        assert!(Args::parse(argv(&flags), None, digest()).is_none());
    }

    #[test]
    fn a_digest_with_no_settings_part_reports_no_settings_digest() {
        let args = Args::parse(argv(&[]), None, Some("abc".to_string())).expect("parse");
        assert_eq!(
            ("abc", None),
            (args.build_digest.as_str(), args.settings_digest.as_deref())
        );
    }

    #[test]
    fn what_a_run_is_started_with_is_given_whole_or_not_at_all() {
        let whole = ["--ruby", "/r", "--lain", "/l", "--runs-dir", "/runs"];
        let run = Args::parse(argv(&whole), None, digest())
            .expect("parse")
            .run
            .expect("run settings");
        assert_eq!(
            (Path::new("/r"), Path::new("/l"), Path::new("/runs")),
            (run.0.as_path(), run.1.as_path(), run.2.as_path())
        );
        assert!(
            Args::parse(argv(&[]), None, digest())
                .expect("parse")
                .run
                .is_none()
        );
        for part in [&whole[..2], &whole[..4], &whole[2..]] {
            assert!(
                Args::parse(argv(part), None, digest()).is_none(),
                "{part:?}"
            );
        }
    }

    const RUNS: [&str; 6] = ["--ruby", "/r", "--lain", "/l", "--runs-dir", "/runs"];

    fn polling(flags: &[&str]) -> Option<Args> {
        let flags: Vec<&str> = RUNS.into_iter().chain(flags.iter().copied()).collect();
        Args::parse(argv(&flags), None, digest())
    }

    #[test]
    fn the_users_review_poll_runs_only_when_asked() {
        assert!(polling(&["--poll-user"]).expect("parse").poll_user);
        assert!(!polling(&[]).expect("parse").poll_user);
    }

    #[test]
    fn the_users_review_poll_takes_no_value() {
        let args = polling(&["--poll-user", "--socket", "/other.sock"]).expect("parse");
        assert!(args.poll_user);
        assert_eq!(Path::new("/other.sock"), args.socket);
    }

    #[test]
    fn the_users_review_poll_with_no_run_settings_is_a_bad_invocation() {
        assert!(Args::parse(argv(&["--poll-user"]), None, digest()).is_none());
    }

    fn asking_for_its_project_poll(root: &str) -> Register {
        Register {
            session_id: "asking".to_string(),
            pid: std::process::id(),
            host: "rainbow".to_string(),
            root: root.to_string(),
            cwd: root.to_string(),
            input_socket: None,
            journal: None,
            attended: true,
            started_at: "2026-11-19T10:00:00Z".to_string(),
            project_poll: true,
        }
    }

    fn me() -> Peer {
        Peer {
            uid: None,
            pid: Some(std::process::id()),
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_daemons_supervisor_has_a_spawner_running_before_any_run() {
        let dir = tempfile::tempdir().expect("tempdir");
        let ruby = dir.path().join("ruby");
        std::fs::write(
            &ruby,
            "#!/bin/sh\n[ \"$3\" = spawner ] && echo $$ > \"$PROBE/spawner\" && exec sleep 25\nexit 0\n",
        )
        .expect("script");
        std::fs::set_permissions(&ruby, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .expect("chmod");
        std::fs::create_dir(dir.path().join("probe")).expect("probe");
        let env = vec![
            ("PATH".into(), std::env::var_os("PATH").unwrap_or_default()),
            ("PROBE".into(), dir.path().join("probe").into_os_string()),
        ];

        let runs = start_supervisor(
            Some((ruby, dir.path().join("lain"), dir.path().join("runs"))),
            env,
        );

        let mut pid = None;
        for _ in 0..500 {
            pid = std::fs::read_to_string(dir.path().join("probe/spawner"))
                .ok()
                .and_then(|text| text.trim().parse::<i32>().ok());
            if pid.is_some() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let pid = pid.expect("a spawner started with no run asked for");
        assert!(runs.list().is_empty());
        let _ = nix::sys::signal::killpg(
            nix::unistd::Pid::from_raw(pid),
            nix::sys::signal::Signal::SIGKILL,
        );
    }

    #[tokio::test(start_paused = true)]
    async fn the_timer_polls_a_project_a_chat_registers_from_the_next_period_and_not_the_user() {
        let (dir, runs, polls) = periodic::tests::noting();
        let root = periodic::tests::project(&dir, "api");
        let registry = Registry::new(registry::ProcTable);
        let timer = spawn_review_polls(&runs, &registry, false, Duration::from_secs(300))
            .expect("a daemon that runs things has the timer");
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        assert!(runs.list().is_empty(), "a poll with nothing asking");
        let _chat = registry
            .register(me(), asking_for_its_project_poll(&root))
            .expect("registered");
        tokio::time::advance(Duration::from_secs(300)).await;
        periodic::tests::until("the project's poll at 300 s", || {
            !periodic::tests::polled(&polls).is_empty()
        })
        .await;
        let root = periodic::tests::canonical(&root);
        assert_eq!(
            vec![format!("queue poll --root {root}|{root}")],
            periodic::tests::polled(&polls)
        );
        timer.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn the_timer_polls_the_user_only_when_asked_to() {
        let (dir, runs, polls) = periodic::tests::noting();
        let registry = Registry::new(registry::ProcTable);
        let timer = spawn_review_polls(&runs, &registry, true, Duration::from_secs(300))
            .expect("a daemon that runs things has the timer");
        periodic::tests::until("the user's poll at 0 s", || {
            !periodic::tests::polled(&polls).is_empty()
        })
        .await;
        let runs_dir = periodic::tests::canonical(dir.path().join("runs").to_str().expect("utf-8"));
        assert_eq!(
            vec![format!("queue poll|{runs_dir}")],
            periodic::tests::polled(&polls)
        );
        timer.abort();
    }

    #[tokio::test]
    async fn a_daemon_that_runs_nothing_has_no_timer() {
        let registry = Registry::new(registry::ProcTable);
        assert!(
            spawn_review_polls(
                &Supervisor::new(None),
                &registry,
                true,
                Duration::from_secs(300)
            )
            .is_none()
        );
    }

    const RELAY: [&str; 4] = ["--relay", "127.0.0.1:0", "--devices-file", "/d/devices"];

    #[test]
    fn an_ntfy_topic_in_the_environment_rides_with_the_relay_it_announces_for() {
        let args =
            Args::parse(argv(&RELAY), Some("http://n/t".to_string()), digest()).expect("parse");
        assert_eq!(Some("http://n/t"), args.ntfy.as_deref());
        assert!(
            Args::parse(argv(&RELAY), None, digest())
                .expect("parse")
                .ntfy
                .is_none()
        );
    }

    #[test]
    fn an_ntfy_topic_is_never_taken_from_the_command_line_where_every_user_can_read_it() {
        let flags: Vec<&str> = RELAY.into_iter().chain(["--ntfy", "http://n/t"]).collect();
        assert!(Args::parse(argv(&flags), None, digest()).is_none());
    }

    #[test]
    fn an_ntfy_topic_without_a_relay_is_a_bad_invocation() {
        assert!(Args::parse(argv(&[]), Some("http://n/t".to_string()), digest()).is_none());
    }

    #[test]
    fn an_ntfy_topic_that_is_not_http_or_https_is_a_bad_invocation() {
        for topic in ["ftp://n/t", "file:///etc/passwd", "n/t", "", "httpx://n/t"] {
            assert!(
                Args::parse(argv(&RELAY), Some(topic.to_string()), digest()).is_none(),
                "{topic:?} was accepted"
            );
        }
    }

    #[test]
    fn a_topic_the_user_config_accepts_with_capitals_in_its_scheme_is_accepted() {
        for topic in ["https://n/t", "HTTPS://ntfy.sh/x", "Http://n/t"] {
            assert!(
                Args::parse(argv(&RELAY), Some(topic.to_string()), digest()).is_some(),
                "{topic:?} killed the daemon"
            );
        }
    }

    /// A topic that answers 200 to each request and hands the request's text on.
    fn stub_topic() -> (String, std::sync::mpsc::Receiver<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let url = format!("http://{}/qa", listener.local_addr().expect("addr"));
        let (heard, requests) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            while let Ok((mut stream, _)) = listener.accept() {
                let mut text = Vec::new();
                let mut chunk = [0_u8; 1024];
                while !text.windows(4).any(|window| window == b"\r\n\r\n") {
                    match stream.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(got) => text.extend_from_slice(&chunk[..got]),
                    }
                }
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                );
                let _ = heard.send(String::from_utf8_lossy(&text).into_owned());
            }
        });
        (url, requests)
    }

    #[tokio::test]
    async fn a_daemon_given_a_topic_posts_once_for_an_item_that_waits_and_names_the_id_the_phone_sees()
     {
        let dir = tempfile::tempdir().expect("a tempdir");
        let (url, requests) = stub_topic();
        let args = Args::parse(argv(&RELAY), Some(url), digest()).expect("the flags parse");
        let registry = Registry::new(registry::ProcTable);
        let mut address = None;
        let relay = PhoneRelay::start(
            &args,
            &registry,
            Duration::from_millis(50),
            |_, _, registry, events| {
                let (worker, phone) = worker(dir.path(), &registry, events);
                address = Some(phone);
                Ok(worker)
            },
        );
        let served = Served::start(daemon(Arc::clone(&registry), relay));
        let process = sleeper();
        let mut chat = session(&served, "sa", &process).await;
        let error = call(
            &mut chat,
            "agenda.publish",
            vec![adding(parked("1", "secret input"))],
        )
        .await;
        assert_eq!(Value::Nil, error);

        let mut phone = phone(address.expect("the worker started")).await;
        let id = id_for_input(&items(&mut phone).await, "secret input");
        let request = tokio::task::spawn_blocking(move || requests.recv_timeout(WAIT))
            .await
            .expect("the wait")
            .expect("a POST within the wait");
        assert!(request.starts_with("POST /qa "), "{request}");
        assert!(
            request.contains(&format!("lain-remote://item/{id}")),
            "{request}"
        );
        assert!(!request.contains("secret input"), "{request}");
    }

    #[tokio::test]
    async fn a_chat_restarted_in_another_process_is_another_item_though_its_ids_repeat() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let registry = Registry::new(registry::ProcTable);
        let (events, mut heard_from) = mpsc::unbounded_channel();
        let (worker, _) = worker(dir.path(), &registry, events);
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let (before, after) = (sleeper(), sleeper());

        let mut first = session(&served, "sa", &before).await;
        assert_eq!(
            Value::Nil,
            call(&mut first, "agenda.publish", vec![adding(parked("1", "x"))]).await
        );
        let opened = opening(heard(&mut heard_from).await);
        drop(first);
        assert!(matches!(
            heard(&mut heard_from).await,
            relay::Event::Left { .. }
        ));

        let mut second = session(&served, "sa", &after).await;
        assert_eq!(
            Value::Nil,
            call(
                &mut second,
                "agenda.publish",
                vec![adding(parked("1", "x"))]
            )
            .await
        );
        let restarted = opening(heard(&mut heard_from).await);
        assert_ne!(opened.twin, restarted.twin, "2 processes share an item");
    }

    fn opened_with(id: &str, twin: &str) -> relay::Event {
        relay::Event::Opened(relay::Opened {
            id: id.to_string(),
            twin: twin.to_string(),
            kind: relay::Kind::ParkedCall,
            requester: "main".to_string(),
        })
    }

    #[tokio::test]
    async fn an_item_report_that_is_not_the_shape_the_worker_makes_never_reaches_the_watch() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let (events, mut heard_from) = mpsc::unbounded_channel();
        let _worker = relay::Worker::over(ours, Arc::clone(&registry), events);
        let mut worker_end = TestClient::over(theirs);
        let (id, twin) = ("0123456789abcdef", "ab".repeat(32));
        let huge = "a".repeat(450_000);
        let forged = [
            opened_with(&huge, &huge),
            opened_with(id, &huge),
            opened_with(&huge, &twin),
            opened_with(id, &twin[..63]),
            opened_with(id, &format!("{}g", &twin[..63])),
            opened_with(&id[..15], &twin),
            opened_with("0123456789abcdefa", &twin),
            opened_with("0123456789abcdeg", &twin),
            opened_with("0123456789ABCDEF", &twin),
            opened_with(id, &twin.to_uppercase()),
            relay::Event::Closed { id: huge.clone() },
            relay::Event::Left { id: huge.clone() },
            relay::Event::Left {
                id: "0123456789ABCDEF".to_string(),
            },
            relay::Event::Closed {
                id: id[..15].to_string(),
            },
            relay::Event::Closed {
                id: "../../etc/passwd".to_string(),
            },
        ];
        for event in forged.iter().chain([&opened_with(id, &twin)]) {
            worker_end
                .send(Value::Array(vec![
                    Value::from(2),
                    Value::from("item"),
                    Value::Array(vec![value(event)]),
                ]))
                .await;
        }
        assert_eq!(opened_with(id, &twin), heard(&mut heard_from).await);

        let mut long = opened_with(id, &twin);
        if let relay::Event::Opened(opened) = &mut long {
            opened.requester = "r".repeat(900_000);
        }
        worker_end
            .send(Value::Array(vec![
                Value::from(2),
                Value::from("item"),
                Value::Array(vec![value(&long)]),
            ]))
            .await;
        let relay::Event::Opened(bounded) = heard(&mut heard_from).await else {
            panic!("an opening was expected")
        };
        assert_eq!(64, bounded.requester.chars().count());
    }

    fn gate_item(id: &str) -> AgendaItem {
        AgendaItem::GateQuestion {
            id: id.to_string(),
            requester: "epic gate".to_string(),
            epic: "e".to_string(),
            stage: "review".to_string(),
            issues: vec![],
            question: "land it?".to_string(),
            asked_at: 1_793_000_000,
            session: "claimed".to_string(),
            project: "/claimed".to_string(),
        }
    }

    async fn heard(events: &mut mpsc::UnboundedReceiver<relay::Event>) -> relay::Event {
        tokio::time::timeout(WAIT, events.recv())
            .await
            .expect("news of an item within the wait")
            .expect("the channel stays open")
    }

    fn opening(event: relay::Event) -> relay::Opened {
        match event {
            relay::Event::Opened(opened) => opened,
            other => panic!("{other:?}, expected an opening"),
        }
    }

    #[tokio::test]
    async fn two_chats_and_a_shared_gate_are_three_items_and_a_reconnect_opens_none_anew() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let registry = Registry::new(registry::ProcTable);
        let (events, mut heard_from) = mpsc::unbounded_channel();
        let (worker, address) = worker(dir.path(), &registry, events);
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let (process_a, process_b) = (sleeper(), sleeper());
        let mut a = session(&served, "sa", &process_a).await;
        let mut b = session(&served, "sb", &process_b).await;

        let gate_key = |local: &str| Value::Map(vec![(Value::from(local), Value::from("digest"))]);
        let sent = [
            call(
                &mut a,
                "agenda.publish",
                vec![adding(parked("1", "from a"))],
            )
            .await,
            call(
                &mut b,
                "agenda.publish",
                vec![adding(parked("1", "from b"))],
            )
            .await,
            call(
                &mut a,
                "agenda.publish",
                vec![adding(gate_item("ga")), gate_key("ga")],
            )
            .await,
            call(
                &mut b,
                "agenda.publish",
                vec![adding(gate_item("gb")), gate_key("gb")],
            )
            .await,
        ];
        assert_eq!(vec![Value::Nil; 4], sent);

        let mut news = Vec::new();
        for _ in 0..3 {
            news.push(opening(heard(&mut heard_from).await));
        }
        let mut phone = phone(address).await;
        let seen = items(&mut phone).await;
        let mut phone_ids: Vec<&str> = seen
            .iter()
            .map(|item| match item {
                AgendaItem::ParkedCall { id, .. }
                | AgendaItem::GateQuestion { id, .. }
                | AgendaItem::Question { id, .. } => id.as_str(),
            })
            .collect();
        let mut told: Vec<&str> = news.iter().map(|opened| opened.id.as_str()).collect();
        phone_ids.sort_unstable();
        told.sort_unstable();
        assert_eq!(3, seen.len(), "{seen:?}");
        assert_eq!(
            phone_ids, told,
            "the daemon was told ids the phone does not hold"
        );

        let first_of_a = news
            .iter()
            .find(|opened| opened.id == id_for_input(&seen, "from a"))
            .expect("a's call")
            .clone();
        drop(a);
        // Only its own call leaves: b still holds the gate.
        assert_eq!(
            relay::Event::Left {
                id: first_of_a.id.clone()
            },
            heard(&mut heard_from).await
        );
        let mut again = session(&served, "sa", &process_a).await;
        let error = call(
            &mut again,
            "agenda.publish",
            vec![adding(parked("1", "from a"))],
        )
        .await;
        assert_eq!(Value::Nil, error);
        let reopened = opening(heard(&mut heard_from).await);
        assert_ne!(first_of_a.id, reopened.id);
        assert_eq!(
            first_of_a.twin, reopened.twin,
            "the reconnect looks like another item"
        );
    }

    #[tokio::test]
    async fn news_of_an_item_from_the_worker_reaches_the_watch() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let (events, mut heard_from) = mpsc::unbounded_channel();
        let _worker = relay::Worker::over(ours, Arc::clone(&registry), events);
        let mut worker_end = TestClient::over(theirs);
        let news = relay::Event::Closed {
            id: "0123456789abcdef".to_string(),
        };
        worker_end
            .send(Value::Array(vec![
                Value::from(2),
                Value::from("item"),
                Value::Array(vec![value(&news)]),
            ]))
            .await;
        assert_eq!(news, heard(&mut heard_from).await);
    }

    /// An offer for `root`, sent by a connection that never registered.
    fn offer_for(root: &str) -> Value {
        Value::Map(vec![
            (Value::from("root"), Value::from(root)),
            (
                Value::from("request"),
                Value::Map(vec![(Value::from("kind"), Value::from("pr"))]),
            ),
            (
                Value::from("row"),
                Value::Map(vec![(Value::from("id"), Value::from("pr:fuze/api#12"))]),
            ),
        ])
    }

    /// `offer.send`'s answer, read with no deadline of its own, since the daemon's bound is the one under test.
    async fn offered_answer(sender: &mut TestClient<UnixStream>) -> Value {
        let frame = sender
            .next_frame()
            .await
            .expect("an answer")
            .expect("a frame");
        let (_, error, result) = response_parts(frame);
        assert_eq!(Value::Nil, error);
        result
    }

    fn outcome_and_session(answer: &Value) -> (Value, Value) {
        let field = |name: &str| {
            answer
                .as_map()
                .expect("a map")
                .iter()
                .find(|(key, _)| key.as_str() == Some(name))
                .map(|(_, value)| value.clone())
                .expect(name)
        };
        let session = field("session");
        let session_id = session
            .as_map()
            .and_then(|record| {
                record
                    .iter()
                    .find(|(key, _)| key.as_str() == Some("session_id"))
            })
            .map_or(Value::Nil, |(_, id)| id.clone());
        (field("outcome"), session_id)
    }

    #[tokio::test]
    async fn an_offer_the_chat_never_replies_to_is_silent_once_the_bound_passes() {
        let served = Served::start(daemon(Registry::new(registry::ProcTable), PhoneRelay::Off));
        let process = sleeper();
        let mut chat = session(&served, "mute", &process).await;
        let mut sender = served.connect(Some(OWNER), std::process::id());
        tokio::time::pause();
        sender
            .send(request(1, "offer.send", vec![offer_for("/work")]))
            .await;
        let (method, _) = pushed(&mut chat).await;
        assert_eq!(Value::from("offer"), method);
        assert_eq!(
            (Value::from("silent"), Value::from("mute")),
            outcome_and_session(&offered_answer(&mut sender).await)
        );
    }

    #[tokio::test]
    async fn an_offer_whose_chat_leaves_before_replying_is_silent() {
        let served = Served::start(daemon(Registry::new(registry::ProcTable), PhoneRelay::Off));
        let process = sleeper();
        let mut chat = session(&served, "leaving", &process).await;
        let mut sender = served.connect(Some(OWNER), std::process::id());
        tokio::time::pause();
        sender
            .send(request(1, "offer.send", vec![offer_for("/work")]))
            .await;
        pushed(&mut chat).await;
        drop(chat);
        assert_eq!(
            (Value::from("silent"), Value::from("leaving")),
            outcome_and_session(&offered_answer(&mut sender).await)
        );
    }

    #[tokio::test]
    async fn a_peer_of_another_user_or_of_no_known_user_is_refused_every_method() {
        let served = Served::start(daemon(Registry::new(registry::ProcTable), PhoneRelay::Off));
        for uid in [Some(0), Some(OWNER + 1), None] {
            let mut client = served.connect(uid, std::process::id());
            for method in [
                "daemon.info",
                "session.list",
                "session.register",
                "agenda.publish",
                "answer.send",
                "offer.send",
                "offer.reply",
            ] {
                assert_eq!(
                    Value::from("only the daemon's own user may call it"),
                    call(&mut client, method, vec![]).await,
                    "uid {uid:?} {method}"
                );
            }
        }
        let mut owner = served.connect(Some(OWNER), std::process::id());
        assert_eq!(Value::Nil, call(&mut owner, "daemon.info", vec![]).await);
    }

    #[tokio::test]
    async fn the_same_local_id_from_2_sessions_is_answered_to_each_session_alone() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (served, phone_address) = with_worker(dir.path()).await;
        let (process_a, process_b) = (sleeper(), sleeper());
        let mut a = session(&served, "sa", &process_a).await;
        let mut b = session(&served, "sb", &process_b).await;
        for (client, input) in [(&mut a, "for a"), (&mut b, "for b")] {
            let error = call(client, "agenda.publish", vec![adding(parked("1", input))]).await;
            assert_eq!(Value::Nil, error);
        }

        let mut phone = phone(phone_address).await;
        let items = items(&mut phone).await;
        assert_eq!(2, items.len(), "{items:?}");
        let (_, error, _) = phone
            .call(
                3,
                "answer.send",
                vec![value(&approve(&id_for_input(&items, "for a")))],
            )
            .await;
        assert_eq!(Value::Nil, error);

        let (method, params) = pushed(&mut a).await;
        assert_eq!(Value::from("answer"), method);
        assert_eq!(
            approve("1").stamped_by("phone"),
            message::<Answer>(&params[0])
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(300), b.next_frame())
                .await
                .is_err(),
            "session B heard of A's answer"
        );

        let (_, error, _) = phone
            .call(
                4,
                "answer.send",
                vec![value(&approve(&id_for_input(&items, "for b")))],
            )
            .await;
        assert_eq!(Value::Nil, error);
        let (_, params) = pushed(&mut b).await;
        assert_eq!(
            approve("1").stamped_by("phone"),
            message::<Answer>(&params[0])
        );
    }

    #[tokio::test]
    async fn a_session_that_goes_away_takes_its_items_off_the_agenda() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (served, phone_address) = with_worker(dir.path()).await;
        let (process_a, process_b) = (sleeper(), sleeper());
        let mut a = session(&served, "sa", &process_a).await;
        let mut b = session(&served, "sb", &process_b).await;
        assert_eq!(
            Value::Nil,
            call(&mut a, "agenda.publish", vec![adding(parked("1", "for a"))]).await
        );
        assert_eq!(
            Value::Nil,
            call(&mut b, "agenda.publish", vec![adding(parked("1", "for b"))]).await
        );
        drop(b);

        let mut phone = phone(phone_address).await;
        let deadline = tokio::time::Instant::now() + WAIT;
        let mut left = items(&mut phone).await;
        while left.len() > 1 && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(25)).await;
            left = items(&mut phone).await;
        }
        assert_eq!(1, left.len(), "{left:?}");
        id_for_input(&left, "for a");
    }

    #[tokio::test]
    async fn the_phone_sees_each_items_registered_session_and_root_not_what_it_claims() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (served, phone_address) = with_worker(dir.path()).await;
        let process = sleeper();
        let mut chat = session_in(&served, "sa", &process, "/registered/root").await;
        assert_eq!(
            Value::Nil,
            call(&mut chat, "agenda.publish", vec![adding(parked("1", "x"))]).await
        );

        let mut phone = phone(phone_address).await;
        let items = items(&mut phone).await;
        let [
            AgendaItem::ParkedCall {
                session, project, ..
            },
        ] = &items[..]
        else {
            panic!("{items:?}")
        };
        assert_eq!(
            ("sa", "/registered/root"),
            (session.as_str(), project.as_str())
        );
    }

    #[tokio::test]
    async fn an_item_from_an_older_wire_is_refused_naming_the_field_it_lacks() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (served, _) = with_worker(dir.path()).await;
        let process = sleeper();
        let mut chat = session(&served, "sa", &process).await;
        let mut item = value(&parked("1", "x"));
        if let Value::Map(variant) = &mut item
            && let Some((_, Value::Map(fields))) = variant.first_mut()
        {
            fields.retain(|(key, _)| !matches!(key.as_str(), Some("session" | "project")));
        }
        let delta = Value::Map(vec![
            (Value::from("cursor"), Value::from(0)),
            (Value::from("added"), Value::Array(vec![item])),
            (Value::from("settled"), Value::Array(vec![])),
        ]);

        let error = call(&mut chat, "agenda.publish", vec![delta]).await;
        assert!(
            error
                .as_str()
                .is_some_and(|text| text.contains("missing field `session`")),
            "{error}"
        );
    }

    #[tokio::test]
    async fn a_publish_reaches_the_worker_stamped_with_the_registration_not_the_payload() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let worker = relay::Worker::over(ours, Arc::clone(&registry), unheard());
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let process = sleeper();
        let mut chat = session(&served, "sa", &process).await;

        let mut claimed = adding(parked("p1", "x"));
        if let Value::Map(fields) = &mut claimed {
            fields.push((Value::from("project"), Value::from("other")));
            fields.push((Value::from("session"), Value::from("forged")));
        }
        chat.send(request(9, "agenda.publish", vec![claimed])).await;

        let mut worker_end = TestClient::over(theirs);
        let forwarded = worker_end.recv().await;
        let Value::Array(parts) = forwarded else {
            panic!("{forwarded} is not a frame")
        };
        assert_eq!(Value::from("agenda.publish"), parts[2]);
        let params = parts[3].as_array().expect("params");
        assert_eq!(3, params.len(), "{params:?}");
        let stamp: relay::Stamp = message(&params[0]);
        assert_eq!(
            ("sa", "/work"),
            (stamp.session.as_str(), stamp.project.as_str())
        );
        assert_eq!(Value::Map(vec![]), params[2], "no gate keys were given");
        worker_end
            .send(Value::Array(vec![
                Value::from(1),
                parts[1].clone(),
                Value::Nil,
                Value::from(1),
            ]))
            .await;
        let (msgid, error, result) = response_parts(chat.recv().await);
        assert_eq!((9, Value::Nil, Value::from(1)), (msgid, error, result));
    }

    #[tokio::test]
    async fn an_answer_for_an_earlier_registration_of_a_session_id_is_not_delivered() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let worker = relay::Worker::over(ours, Arc::clone(&registry), unheard());
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let process = sleeper();
        drop(session(&served, "sa", &process).await);
        let deadline = tokio::time::Instant::now() + WAIT;
        while !registry.list().is_empty() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the first registration never ended"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        let mut again = session(&served, "sa", &process).await;

        let mut worker_end = TestClient::over(theirs);
        let answer_for = |registration: u64| {
            Value::Array(vec![
                Value::from(2),
                Value::from("answer"),
                Value::Array(vec![
                    Value::from("sa"),
                    Value::from(registration),
                    value(&approve("1")),
                ]),
            ])
        };
        worker_end.send(answer_for(1)).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(300), again.next_frame())
                .await
                .is_err(),
            "an answer for the first registration reached the second"
        );
        worker_end.send(answer_for(2)).await;
        let (method, params) = pushed(&mut again).await;
        assert_eq!(Value::from("answer"), method);
        assert_eq!(approve("1"), message::<Answer>(&params[0]));
    }

    #[tokio::test]
    async fn a_relay_that_is_gone_refuses_a_publish_as_unavailable() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let worker = relay::Worker::over(ours, Arc::clone(&registry), unheard());
        drop(theirs);
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let process = sleeper();
        let mut chat = session(&served, "sa", &process).await;
        let error = tokio::time::timeout(
            WAIT,
            call(&mut chat, "agenda.publish", vec![adding(parked("p1", "x"))]),
        )
        .await
        .expect("the publish never answered");
        assert_eq!(Value::from("the phone relay is unavailable"), error);
    }

    #[tokio::test]
    async fn a_publish_past_the_workers_frame_ceiling_is_refused_and_the_relay_serves_on() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (served, _) = with_worker(dir.path()).await;
        let (process_a, process_b) = (sleeper(), sleeper());
        let deep_root = format!("/{}", "r".repeat(600 << 10));
        let mut a = session_in(&served, "sa", &process_a, &deep_root).await;
        let mut b = session(&served, "sb", &process_b).await;

        let error = call(
            &mut a,
            "agenda.publish",
            vec![adding(parked("1", &"x".repeat(500 << 10)))],
        )
        .await;
        assert!(
            error
                .as_str()
                .is_some_and(|text| text.contains("frame ceiling")),
            "{error}"
        );
        assert_eq!(
            Value::Nil,
            call(&mut b, "agenda.publish", vec![adding(parked("1", "small"))]).await
        );
        let (_, _, info) = b.call(2, "daemon.info", vec![]).await;
        assert_eq!(
            Value::from("running"),
            lain_rpc::support::field(&info, "relay")
        );
    }

    #[tokio::test]
    async fn a_session_that_hangs_up_mid_publish_leaves_the_workers_socket_whole() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let worker = relay::Worker::over(ours, Arc::clone(&registry), unheard());
        let served = Served::start(daemon(Arc::clone(&registry), PhoneRelay::Running(worker)));
        let (process_a, process_b) = (sleeper(), sleeper());
        let mut a = session(&served, "sa", &process_a).await;
        let mut b = session(&served, "sb", &process_b).await;

        let large = adding(parked("big", &"x".repeat(900 << 10)));
        a.send(request(5, "agenda.publish", vec![large])).await;
        // The worker end reads nothing yet, so the large frame stalls in the socket.
        tokio::time::sleep(Duration::from_millis(200)).await;
        drop(a);
        tokio::time::sleep(Duration::from_millis(200)).await;
        b.send(request(
            6,
            "agenda.publish",
            vec![adding(parked("small", "y"))],
        ))
        .await;

        let mut worker_end = TestClient::over(theirs);
        let mut inputs = Vec::new();
        while inputs.len() < 2 {
            let frame = worker_end.recv().await;
            let Value::Array(parts) = frame else {
                panic!("{frame} is not a frame")
            };
            if parts[2] == Value::from("agenda.publish") {
                let delta: Delta = message(&parts[3].as_array().expect("params")[1]);
                let AgendaItem::ParkedCall { id, .. } = &delta.added[0] else {
                    panic!("not a parked call")
                };
                inputs.push(id.clone());
            }
            worker_end
                .send(Value::Array(vec![
                    Value::from(1),
                    parts[1].clone(),
                    Value::Nil,
                    Value::from(1),
                ]))
                .await;
        }
        assert_eq!(vec!["big", "small"], inputs);
        let (msgid, error, _) = response_parts(b.recv().await);
        assert_eq!((6, Value::Nil), (msgid, error));
    }

    #[test]
    fn an_empty_or_missing_sha_reads_unknown() {
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", Some("")));
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", None));
        assert_eq!("0.1.0 abc123", build_id_of("0.1.0", Some("abc123")));
    }
}
