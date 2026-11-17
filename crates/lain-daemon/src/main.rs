//! lain-daemon: the per-user daemon, a msgpack-RPC server on a Unix socket.
//!
//! The socket path, trace path and launch digest all arrive via argv: this binary NEVER computes
//! its own path, because path policy belongs to Ruby (`Paths#runtime_dir`). Tracing goes to a file,
//! never a terminal: the Journal is NDJSON and one stray diagnostic line breaks the experiment record.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr, missing_docs)]

mod registry;
mod relay;

use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, OnceLock};

use lain_rpc::{Conn, Handler, Peer, Push, RpcError, Session};
use lain_wire::Register;
use rmpv::Value;

use registry::{Registration, Registry};

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
    launch_digest: String,
    /// The phone relay's listen address and devices file, given together or not at all.
    relay: Option<(String, PathBuf)>,
}

impl Args {
    fn parse(mut args: impl Iterator<Item = String>) -> Option<Self> {
        let (mut socket, mut trace, mut launch_digest) = (None, None, None);
        let (mut listen, mut devices) = (None, None);
        while let Some(flag) = args.next() {
            let value = args.next()?;
            match flag.as_str() {
                "--socket" => socket = Some(PathBuf::from(value)),
                "--trace" => trace = Some(PathBuf::from(value)),
                "--launch-digest" => launch_digest = Some(value),
                "--relay" => listen = Some(value),
                "--devices-file" => devices = Some(PathBuf::from(value)),
                _ => return None,
            }
        }
        let relay = match (listen, devices) {
            (Some(listen), Some(devices)) => Some((listen, devices)),
            (None, None) => None,
            _ => return None,
        };
        Some(Self {
            socket: socket?,
            trace,
            launch_digest: launch_digest?,
            relay,
        })
    }
}

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1).peekable();
    if args.next_if_eq("relay").is_some() {
        return relay(args);
    }
    let Some(args) = Args::parse(args) else {
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
    launch_digest: String,
    registry: Arc<Registry>,
    owner_uid: u32,
    relay: PhoneRelay,
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

    fn start(args: &Args, registry: &Arc<Registry>) -> Self {
        let Some((listen, devices)) = &args.relay else {
            return Self::Off;
        };
        match relay::Worker::spawn(listen, devices, args.trace.as_deref(), Arc::clone(registry)) {
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
}

impl Session for Caller {
    fn opened(conn: &Conn) -> Self {
        Self {
            peer: conn.peer,
            push: conn.push.clone(),
            registration: OnceLock::new(),
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
                    Value::from("launch_digest"),
                    Value::from(self.launch_digest.as_str()),
                ),
                (Value::from("relay"), Value::from(self.relay.state())),
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
        let stamp = relay::Stamp {
            session: registration.session_id().to_string(),
            project: registration.root().to_string(),
            registration: registration.registration(),
        };
        worker.publish(&stamp, delta, keys).await
    }

    async fn register(&self, caller: &Caller, params: Vec<Value>) -> Result<Value, RpcError> {
        if caller.registration.get().is_some() {
            return Err(already_registered());
        }
        let register = decoded_register(params)?;
        let registry = Arc::clone(&self.registry);
        let peer = caller.peer;
        // The process table may be read through `ps`, which blocks.
        let registration = tokio::task::spawn_blocking(move || registry.register(peer, register))
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
        Ok(Value::Nil)
    }
}

fn already_registered() -> RpcError {
    RpcError::Refused {
        code: "registered",
        message: "this connection already registered a session".to_string(),
    }
}

fn decoded_register(params: Vec<Value>) -> Result<Register, RpcError> {
    let malformed = || RpcError::Refused {
        code: "bad_params",
        message: "session.register takes [Register]".to_string(),
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
    let relay = PhoneRelay::start(&args, &registry);
    let handler = Daemon {
        launch_digest: args.launch_digest,
        registry,
        owner_uid,
        relay,
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
    use tokio::sync::mpsc;

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
            launch_digest: "abc".to_string(),
            registry,
            owner_uid: OWNER,
            relay,
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

    /// The worker in-process, over a devices file pairing [`TOKEN`]; its phone address.
    async fn worker(
        dir: &Path,
        registry: &Arc<Registry>,
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
        let phone = TcpListener::bind(("127.0.0.1", 0)).await.expect("bind");
        let address = phone.local_addr().expect("the phone address");
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        tokio::spawn(relay::serve_worker(theirs, phone, watcher, roster));
        (relay::Worker::over(ours, Arc::clone(registry)), address)
    }

    /// The daemon over an in-process worker, and that worker's phone address.
    async fn with_worker(dir: &Path) -> (Served, std::net::SocketAddr) {
        let registry = Registry::new(registry::ProcTable);
        let (worker, phone) = worker(dir, &registry).await;
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
    async fn a_publish_reaches_the_worker_stamped_with_the_registration_not_the_payload() {
        let registry = Registry::new(registry::ProcTable);
        let (ours, theirs) = UnixStream::pair().expect("a socket pair");
        let worker = relay::Worker::over(ours, Arc::clone(&registry));
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
        let worker = relay::Worker::over(ours, Arc::clone(&registry));
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
        let worker = relay::Worker::over(ours, Arc::clone(&registry));
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
        let worker = relay::Worker::over(ours, Arc::clone(&registry));
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
