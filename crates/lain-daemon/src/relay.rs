//! The phone relay: lain publishes its agenda, and a paired phone reads it and answers over the
//! tailnet.
//!
//! It runs as the daemon's worker, a child whose stdin is its end of a socket pair: the daemon
//! publishes each session's items stamped with that session, and the worker pushes each answer
//! back naming the session that owns the item. It also runs on its own with `--unix`, where lain
//! publishes on a socket and long-polls for answers. Either way it confines itself first, which
//! is why it is a process of its own: the daemon spawns runs and makes HTTPS calls, and no
//! ruleset that allows those would hold the listener the phone talks to.

mod agenda;
mod devices;

use std::collections::HashMap;
use std::convert::Infallible;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use lain_wire::{AgendaPage, Answer, AnswersPage, Cursor, Delta, Hello, WIRE_VERSION, Welcome};
use rmpv::Value;
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
use tokio::sync::oneshot;

pub(crate) use agenda::Stamp;
use agenda::{Agenda, REPLY_BUDGET, Refusal, Route, with_answer_id};
use devices::{Admitted, DevicesError, Paired, Roster};
pub(crate) use devices::{DevicesFile, Watcher};
use lain_rpc::{Accept, Conn, Handler, Push, RpcError, Session};

use crate::registry::Registry;

/// The version a ping to either of the relay's listeners reports.
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// How often the relay checks its devices file for a pair or a revoke.
pub(crate) const RELOAD_TICK: Duration = Duration::from_secs(1);

/// Why the relay would not start.
#[derive(Debug, thiserror::Error)]
pub(crate) enum StartError {
    #[error(
        "the relay listens only on this host's own tailscale0 address, or loopback for tests; {0} is neither"
    )]
    Listen(SocketAddr),
    #[error("--listen {0} is not an IP address and port; the relay resolves no names")]
    ListenUnparsable(String),
    #[error("cannot list this host's interfaces: {0}")]
    Interfaces(nix::Error),
    #[error(transparent)]
    Devices(#[from] DevicesError),
    #[error("{} is in use by a listening process", .0.display())]
    SocketInUse(PathBuf),
    #[error("{} exists and is not a socket", .0.display())]
    NotASocket(PathBuf),
    #[error("cannot bind {what}: {error}")]
    Bind { what: String, error: io::Error },
    #[cfg(target_os = "linux")]
    #[error("cannot confine the relay: {0}")]
    Confine(landlock::RulesetError),
    #[error("this kernel enforces no Landlock ruleset, and the relay does not run unconfined")]
    Unconfined,
    #[error("without --unix the relay serves the daemon on its stdin, which is not a socket: {0}")]
    NoUplink(io::Error),
}

impl StartError {
    /// A refusal of the command line or its files is a usage error, a socket
    /// that cannot be had a bind error, and a relay that cannot confine itself
    /// its own code, so a caller can tell the kernel is what refused.
    pub(crate) fn exit_code(&self) -> u8 {
        match self {
            Self::Listen(_) | Self::ListenUnparsable(_) | Self::Devices(_) | Self::NoUplink(_) => {
                crate::USAGE_ERROR
            }
            Self::Interfaces(_)
            | Self::SocketInUse(_)
            | Self::NotASocket(_)
            | Self::Bind { .. } => crate::BIND_ERROR,
            #[cfg(target_os = "linux")]
            Self::Confine(_) => crate::CONFINE_ERROR,
            Self::Unconfined => crate::CONFINE_ERROR,
        }
    }
}

/// A wildcard or LAN bind would put the relay in front of every peer that
/// can route to this host, and the tailnet is the only network it trusts.
pub(crate) fn listen_rule(
    address: SocketAddr,
    tailnet: &[IpAddr],
) -> Result<SocketAddr, StartError> {
    if address.ip().is_loopback() || tailnet.contains(&address.ip()) {
        Ok(address)
    } else {
        Err(StartError::Listen(address))
    }
}

fn tailscale0_addresses() -> Result<Vec<IpAddr>, StartError> {
    let interfaces = nix::ifaddrs::getifaddrs().map_err(StartError::Interfaces)?;
    Ok(interfaces
        .filter(|interface| interface.interface_name == "tailscale0")
        .filter_map(|interface| interface.address)
        .filter_map(|address| {
            address
                .as_sockaddr_in()
                .map(|v4| IpAddr::V4(v4.ip()))
                .or_else(|| address.as_sockaddr_in6().map(|v6| IpAddr::V6(v6.ip())))
        })
        .collect())
}

/// `relay [--unix <sock>] --listen <addr>:<port> --devices-file <path> [--trace <path>]`. Without
/// `--unix` the relay is the daemon's worker.
pub(crate) struct Config {
    pub(crate) unix: Option<PathBuf>,
    pub(crate) listen: String,
    pub(crate) devices_file: PathBuf,
    pub(crate) trace: Option<String>,
}

impl Config {
    /// None for a missing, repeated, unknown or unparsable flag.
    pub(crate) fn parse(mut args: impl Iterator<Item = String>) -> Option<Self> {
        let (mut unix, mut listen, mut devices_file, mut trace) = (None, None, None, None);
        while let Some(flag) = args.next() {
            let value = args.next()?;
            let slot = match flag.as_str() {
                "--unix" => &mut unix,
                "--listen" => &mut listen,
                "--devices-file" => &mut devices_file,
                "--trace" => &mut trace,
                _ => return None,
            };
            if slot.replace(value).is_some() {
                return None;
            }
        }
        Some(Self {
            unix: unix.map(PathBuf::from),
            listen: listen?,
            devices_file: PathBuf::from(devices_file?),
            trace,
        })
    }

    /// The directory the relay may write: its own socket's, which it removes on the way out.
    pub(crate) fn socket_dir(&self) -> Option<&Path> {
        self.unix.as_deref().map(|unix| {
            unix.parent()
                .filter(|dir| !dir.as_os_str().is_empty())
                .unwrap_or(Path::new("."))
        })
    }
}

/// Where lain reaches the relay: a socket it listens on, or the daemon's end of a socket pair.
enum LainSide {
    Listener(std::os::unix::net::UnixListener),
    Daemon(std::os::unix::net::UnixStream),
}

/// Both listeners and the paired devices, taken before the relay confines itself.
pub(crate) struct Bound {
    lain: LainSide,
    phone: std::net::TcpListener,
    watcher: Watcher,
    roster: Roster,
}

impl Bound {
    pub(crate) fn open(config: &Config) -> Result<Self, StartError> {
        let address = config
            .listen
            .parse()
            .map_err(|_| StartError::ListenUnparsable(config.listen.clone()))?;
        let listen = listen_rule(address, &tailscale0_addresses()?)?;
        let mut watcher = Watcher::new(DevicesFile::new(config.devices_file.clone()));
        watcher.file().check_directory()?;
        let roster = watcher.read()?;
        let bind_error = |what: String| move |error| StartError::Bind { what, error };
        let lain = match &config.unix {
            Some(unix) => {
                clear_stale_socket(unix)?;
                LainSide::Listener(
                    std::os::unix::net::UnixListener::bind(unix)
                        .map_err(bind_error(unix.display().to_string()))?,
                )
            }
            None => LainSide::Daemon(stdin_socket()?),
        };
        let phone = std::net::TcpListener::bind(listen).map_err(|error| {
            if let Some(unix) = &config.unix {
                let _ = std::fs::remove_file(unix);
            }
            bind_error(listen.to_string())(error)
        })?;
        Ok(Self {
            lain,
            phone,
            watcher,
            roster,
        })
    }

    /// The directory the relay may read: its devices file's own.
    pub(crate) fn devices_directory(&self) -> &Path {
        self.watcher.file().directory()
    }

    /// Takes a runtime context: tokio adopts the listeners here. A worker's future ends when its
    /// daemon hangs up; a relay on its own socket serves until it is signalled.
    pub(crate) fn serve(self) -> io::Result<impl Future<Output = ()>> {
        self.phone.set_nonblocking(true)?;
        let phone = TcpListener::from_std(self.phone)?;
        let (watcher, roster) = (self.watcher, self.roster);
        let lain = match self.lain {
            LainSide::Listener(listener) => {
                listener.set_nonblocking(true)?;
                Ok(UnixListener::from_std(listener)?)
            }
            LainSide::Daemon(stream) => {
                stream.set_nonblocking(true)?;
                Err(UnixStream::from_std(stream)?)
            }
        };
        Ok(async move {
            match lain {
                Ok(listener) => match serve(listener, phone, watcher, roster).await {},
                Err(daemon) => serve_worker(daemon, phone, watcher, roster).await,
            }
        })
    }
}

/// The worker's stdin, which the daemon made its end of a socket pair. A copy of the descriptor,
/// so taking it needs no `unsafe`.
fn stdin_socket() -> Result<std::os::unix::net::UnixStream, StartError> {
    use std::os::fd::AsFd;
    let fd = std::io::stdin()
        .as_fd()
        .try_clone_to_owned()
        .map_err(StartError::NoUplink)?;
    let stream = std::os::unix::net::UnixStream::from(fd);
    stream.local_addr().map_err(StartError::NoUplink)?;
    Ok(stream)
}

/// A socket file nothing answers on is what a relay that died leaves
/// behind, so it is removed; one a live process answers on, or a file that is
/// not a socket, is never touched.
fn clear_stale_socket(path: &Path) -> Result<(), StartError> {
    use std::os::unix::fs::FileTypeExt;
    let bind_error = |error| StartError::Bind {
        what: path.display().to_string(),
        error,
    };
    match std::fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(bind_error(error)),
        Ok(metadata) if !metadata.file_type().is_socket() => {
            Err(StartError::NotASocket(path.to_path_buf()))
        }
        Ok(_) => match std::os::unix::net::UnixStream::connect(path) {
            Ok(_) => Err(StartError::SocketInUse(path.to_path_buf())),
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                std::fs::remove_file(path).map_err(bind_error)
            }
            Err(error) => Err(bind_error(error)),
        },
    }
}

/// Every filesystem right is handled, so all but these grants are refused, for the calling
/// thread and every thread it spawns after: reads beneath the devices directory, which is listed
/// too because every reread checks what it holds, and writes beneath the socket directory of a
/// relay on its own socket. A worker's socket is already open, so it gets no write grant at all.
/// TCP binds and connects are handled with no rule, since the listener is already bound, and
/// signals and abstract sockets are scoped to the relay itself. Each of these applies as far as
/// the kernel's Landlock reaches; a kernel that enforces none of it is refused, because an
/// unconfined relay is not one we run.
#[cfg(not(target_os = "linux"))]
pub(crate) fn confine(_: &Path, _: Option<&Path>) -> Result<(), StartError> {
    Err(StartError::Unconfined)
}

#[cfg(target_os = "linux")]
pub(crate) fn confine(devices_dir: &Path, socket_dir: Option<&Path>) -> Result<(), StartError> {
    use landlock::{
        ABI, Access, AccessFs, AccessNet, Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus,
        Scope, path_beneath_rules,
    };
    const TARGET: ABI = ABI::V6;
    let status = Ruleset::default()
        .handle_access(AccessFs::from_all(TARGET))
        .and_then(|ruleset| ruleset.handle_access(AccessNet::from_all(TARGET)))
        .and_then(|ruleset| ruleset.scope(Scope::from_all(TARGET)))
        .and_then(|ruleset| ruleset.create())
        .and_then(|ruleset| {
            ruleset.add_rules(path_beneath_rules(
                [devices_dir],
                AccessFs::ReadFile | AccessFs::ReadDir,
            ))
        })
        .and_then(|ruleset| {
            ruleset.add_rules(path_beneath_rules(socket_dir, AccessFs::from_write(TARGET)))
        })
        .and_then(|ruleset| ruleset.restrict_self())
        .map_err(StartError::Confine)?;
    if status.ruleset == RulesetStatus::NotEnforced {
        return Err(StartError::Unconfined);
    }
    Ok(())
}

/// Lain's methods on the Unix socket, the phone's on TCP, over one agenda.
/// Each side is a separate handler, so neither can call the other's methods.
pub(crate) async fn serve(
    lain: UnixListener,
    phone: TcpListener,
    watcher: Watcher,
    roster: Roster,
) -> Infallible {
    let relay = Arc::new(Relay::new(roster));
    let reread = reread(watcher, Arc::clone(&relay));
    let lain = lain_rpc::serve(lain, Lain(Arc::clone(&relay)), VERSION);
    let phone = lain_rpc::serve(Tailnet(phone), Phone(relay), VERSION);
    tokio::select! {
        never = reread => match never {},
        never = lain => match never {},
        never = phone => match never {},
    }
}

async fn reread(mut watcher: Watcher, relay: Arc<Relay>) -> Infallible {
    loop {
        tokio::time::sleep(RELOAD_TICK).await;
        watcher.poll(&relay.paired);
    }
}

/// A worker's daemon side over its socket pair. A connection's stream lives as long as the
/// server's task for it, so when the daemon hangs up `gone` drops and the worker stops.
pub(crate) async fn serve_worker(
    daemon: UnixStream,
    phone: TcpListener,
    watcher: Watcher,
    roster: Roster,
) {
    let relay = Arc::new(Relay::new(roster));
    let (gone, hung_up) = oneshot::channel();
    let uplink = OnlyOnce(Mutex::new(Some(Uplink {
        stream: daemon,
        _gone: gone,
    })));
    let reread = reread(watcher, Arc::clone(&relay));
    let lain = lain_rpc::serve(uplink, Upstream(Arc::clone(&relay)), VERSION);
    let phone = lain_rpc::serve(Tailnet(phone), Phone(relay), VERSION);
    tokio::select! {
        never = reread => match never {},
        never = lain => match never {},
        never = phone => match never {},
        _ = hung_up => tracing::info!("the daemon hung up; the relay worker stops"),
    }
}

/// The 1 connection a worker serves lain on, handed out once.
struct OnlyOnce(Mutex<Option<Uplink>>);

impl Accept for OnlyOnce {
    type Connection = Uplink;

    async fn accept(&self) -> io::Result<Uplink> {
        let taken = self.0.lock().unwrap_or_else(PoisonError::into_inner).take();
        match taken {
            Some(uplink) => Ok(uplink),
            None => std::future::pending().await,
        }
    }
}

/// The worker's end of its socket pair, which says when it is dropped.
struct Uplink {
    stream: UnixStream,
    _gone: oneshot::Sender<()>,
}

impl AsyncRead for Uplink {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_read(context, buffer)
    }
}

impl AsyncWrite for Uplink {
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

    fn poll_shutdown(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(context)
    }
}

struct Relay {
    paired: Paired,
    agenda: Agenda,
    /// The daemon's connection, once it has published; where answers are pushed.
    uplink: OnceLock<Push>,
}

impl Relay {
    fn new(roster: Roster) -> Self {
        Self {
            paired: Paired::new(roster),
            agenda: Agenda::default(),
            uplink: OnceLock::new(),
        }
    }

    /// Hands an answer to the daemon under the id its session gave the item, naming that session.
    /// A relay on its own socket has no sessions and keeps answers for `answers.next` alone.
    fn route(&self, route: Option<Route>, answer: &Answer) {
        let (Some(route), Some(uplink)) = (route, self.uplink.get()) else {
            return;
        };
        let pushed = reply(&with_answer_id(answer.clone(), &route.local))
            .ok()
            .map(|answer| {
                uplink.send(
                    "answer",
                    vec![
                        Value::from(route.stamp.session),
                        Value::from(route.stamp.registration),
                        answer,
                    ],
                )
            });
        if !matches!(pushed, Some(Ok(()))) {
            tracing::warn!("could not hand an answer to the daemon");
        }
    }
}

/// The phone side's listener. The production impl of [`Accept`] for TCP, kept
/// apart from the test-only one on `TcpListener` itself.
struct Tailnet(TcpListener);

impl Accept for Tailnet {
    type Connection = TcpStream;

    /// Without no-delay, a reply written while an earlier one awaits its ack
    /// waits for the phone's delayed ack, about 40 ms on Linux.
    async fn accept(&self) -> io::Result<TcpStream> {
        let (stream, _address) = self.0.accept().await?;
        if let Err(error) = stream.set_nodelay(true) {
            tracing::warn!(%error, "could not set no-delay on a phone connection");
        }
        Ok(stream)
    }
}

struct Lain(Arc<Relay>);

impl Handler for Lain {
    type Session = ();

    async fn call(&self, _: &(), method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        let agenda = &self.0.agenda;
        match method {
            "agenda.publish" => {
                let delta = decoded::<Delta>(params, "agenda.publish takes [Delta]")?;
                let cursor = agenda
                    .publish(&delta, None, &HashMap::new())
                    .map_err(refused)?;
                Ok(Value::from(cursor))
            }
            "answers.next" => {
                let at = decoded::<Cursor>(params, "answers.next takes [Cursor]")?;
                let page = agenda.answers_after(at.cursor, at.epoch).await;
                reply(&AnswersPage {
                    epoch: agenda.epoch(),
                    cursor: page.cursor,
                    reset: page.reset,
                    answers: page.messages,
                })
            }
            _ => Err(RpcError::UnknownMethod(method.to_string())),
        }
    }
}

/// The daemon's side of a worker: publishes stamped with the registration they came from, and
/// word of a registration that left.
struct Upstream(Arc<Relay>);

/// The daemon's connection, kept so answers can be pushed on it.
struct Linked(Push);

impl Session for Linked {
    fn opened(conn: &Conn) -> Self {
        Self(conn.push.clone())
    }
}

impl Handler for Upstream {
    type Session = Linked;

    async fn call(
        &self,
        linked: &Linked,
        method: &str,
        params: Vec<Value>,
    ) -> Result<Value, RpcError> {
        let agenda = &self.0.agenda;
        match method {
            "agenda.publish" => {
                let shape = "agenda.publish takes [Stamp, Delta, Keys]";
                let [stamp, delta, keys] =
                    <[Value; 3]>::try_from(params).map_err(|_| bad_params(shape))?;
                let stamp = decoded::<Stamp>(vec![stamp], shape)?;
                let delta = decoded::<Delta>(vec![delta], shape)?;
                let keys = decoded::<HashMap<String, String>>(vec![keys], shape)?;
                self.0.uplink.get_or_init(|| linked.0.clone());
                let cursor = agenda
                    .publish(&delta, Some(&stamp), &keys)
                    .map_err(refused)?;
                Ok(Value::from(cursor))
            }
            "agenda.leave" => {
                let registration = params
                    .first()
                    .and_then(Value::as_u64)
                    .ok_or_else(|| bad_params("agenda.leave takes [registration]"))?;
                agenda.leave(registration);
                Ok(Value::Nil)
            }
            _ => Err(RpcError::UnknownMethod(method.to_string())),
        }
    }
}

struct Phone(Arc<Relay>);

/// A phone connection's device, closed when it is revoked.
struct Device(Option<Admitted>);

impl Session for Device {
    fn opened(_: &Conn) -> Self {
        Self(None)
    }

    async fn closed(&self) {
        match &self.0 {
            Some(admitted) => admitted.revoked().await,
            None => std::future::pending().await,
        }
    }
}

impl Handler for Phone {
    type Session = Device;

    fn requires_hello(&self) -> bool {
        true
    }

    async fn hello(
        &self,
        _: &Conn,
        params: Vec<Value>,
    ) -> Result<(Value, Self::Session), RpcError> {
        let hello = decoded::<Hello>(params, "hello takes [Hello]")?;
        let admitted = self.0.admit(&hello)?;
        let agenda = &self.0.agenda;
        let welcome = reply(&Welcome {
            wire_version: WIRE_VERSION,
            head: agenda.head(),
            epoch: agenda.epoch(),
        })?;
        Ok((welcome, Device(Some(admitted))))
    }

    async fn call(
        &self,
        session: &Self::Session,
        method: &str,
        params: Vec<Value>,
    ) -> Result<Value, RpcError> {
        let agenda = &self.0.agenda;
        let Some(device) = &session.0 else {
            return Err(RpcError::HelloRequired);
        };
        match method {
            "agenda.next" => {
                let at = decoded::<Cursor>(params, "agenda.next takes [Cursor]")?;
                let page = agenda.deltas_after(at.cursor, at.epoch).await;
                reply(&AgendaPage {
                    epoch: agenda.epoch(),
                    cursor: page.cursor,
                    reset: page.reset,
                    deltas: page.messages,
                })
            }
            "answer.send" => {
                let answer = decoded::<Answer>(params, "answer.send takes [Answer]")?
                    .stamped_by(device.name());
                let route = agenda.answer(&answer).map_err(refused)?;
                self.0.route(route, &answer);
                Ok(Value::Nil)
            }
            _ => Err(RpcError::UnknownMethod(method.to_string())),
        }
    }
}

/// `value` formatted, cut to 64 characters, so an id a phone chose cannot make a refusal huge.
fn clip(value: &impl std::fmt::Display) -> String {
    struct Bounded(String, usize);

    impl std::fmt::Write for Bounded {
        fn write_str(&mut self, text: &str) -> std::fmt::Result {
            for character in text.chars() {
                if self.1 == 64 {
                    self.0.push_str("...");
                    return Err(std::fmt::Error);
                }
                self.0.push(character);
                self.1 += 1;
            }
            Ok(())
        }
    }

    let mut bounded = Bounded(String::new(), 0);
    let _cut_short = std::fmt::write(&mut bounded, format_args!("{value}"));
    bounded.0
}

fn refused_with(code: &'static str, message: impl Into<String>) -> RpcError {
    RpcError::Refused {
        code,
        message: message.into(),
    }
}

fn bad_params(shape: &str) -> RpcError {
    refused_with("bad_params", shape)
}

fn refused(refusal: Refusal) -> RpcError {
    match refusal {
        Refusal::AlreadySettled(id) => refused_with(
            "already_settled",
            format!("agenda item {:?} is already settled", clip(&id)),
        ),
        Refusal::NotOpen(id) => refused_with(
            "not_open",
            format!("agenda item {:?} is not open", clip(&id)),
        ),
        Refusal::TooLarge { what, bytes } => refused_with(
            "too_large",
            format!("{what} {bytes} bytes, over the relay's reply budget of {REPLY_BUDGET}"),
        ),
        Refusal::Unencodable => bad_params("the relay could not encode it"),
        Refusal::BadKey => {
            bad_params("a gate key names an item that is not a gate question in its delta")
        }
    }
}

impl Relay {
    /// The version is checked first so a phone on another version learns why,
    /// which tells it nothing about the token.
    fn admit(&self, hello: &Hello) -> Result<Admitted, RpcError> {
        if hello.wire_version != WIRE_VERSION {
            let advice = if hello.wire_version < WIRE_VERSION {
                "update the phone app"
            } else {
                "update lain"
            };
            return Err(refused_with(
                "wire_version",
                format!(
                    "wire version {} is not served; this relay speaks {WIRE_VERSION}: {advice}",
                    hello.wire_version
                ),
            ));
        }
        self.paired
            .admit(&hello.token)
            .ok_or_else(|| refused_with("bad_token", "the hello was refused"))
    }
}

/// The first param as a wire message. Only the decoded value travels on, so
/// a key or a shape the wire types do not name never reaches the other side.
fn decoded<T: DeserializeOwned>(params: Vec<Value>, shape: &'static str) -> Result<T, RpcError> {
    let raw = params.into_iter().next().ok_or_else(|| bad_params(shape))?;
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &raw).map_err(|_| bad_params(shape))?;
    lain_wire::decode(&bytes).map_err(|_| bad_params(shape))
}

/// A wire message as the msgpack value a handler answers with.
fn reply<T: Serialize>(message: &T) -> Result<Value, RpcError> {
    let unencodable = || bad_params("the relay could not encode its reply");
    let bytes = lain_wire::encode(message).map_err(|_| unencodable())?;
    rmpv::decode::read_value(&mut bytes.as_slice()).map_err(|_| unencodable())
}

/// The largest frame the worker's codec reads; a bigger one closes the daemon's connection to it,
/// which would end the relay for every session, so the daemon refuses such a publish itself.
const WORKER_FRAME: usize = 1 << 20;

/// The nesting the daemon decodes in a worker's frame, far under rmpv's own, which can overflow a
/// worker thread's stack before it refuses.
const WORKER_DEPTH: usize = 64;

/// The daemon's end of its relay worker: publishes go out as requests, and each answer comes
/// back as a push the daemon hands to the session that owns its item.
pub(crate) struct Worker {
    writer: Arc<tokio::sync::Mutex<OwnedWriteHalf>>,
    /// The publishes awaiting the worker's reply; None once the worker is gone.
    calls: Mutex<Option<Calls>>,
}

#[derive(Default)]
struct Calls {
    next: u32,
    waiting: HashMap<u32, oneshot::Sender<(Value, Value)>>,
}

impl Worker {
    /// Runs this binary as `relay --listen <listen> --devices-file <devices>`, with its end of a
    /// socket pair as stdin: under `forbid(unsafe_code)` a child gets no other extra descriptor.
    pub(crate) fn spawn(
        listen: &str,
        devices: &Path,
        trace: Option<&Path>,
        registry: Arc<Registry>,
    ) -> io::Result<Arc<Self>> {
        use std::process::Stdio;
        let (ours, theirs) = std::os::unix::net::UnixStream::pair()?;
        let mut command = tokio::process::Command::new(std::env::current_exe()?);
        command
            .args(["relay", "--listen", listen, "--devices-file"])
            .arg(devices);
        if let Some(trace) = trace {
            command.arg("--trace").arg(trace);
        }
        let mut child = command
            .env_clear()
            .stdin(Stdio::from(std::os::fd::OwnedFd::from(theirs)))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        drop(command);
        ours.set_nonblocking(true)?;
        let worker = Self::over(UnixStream::from_std(ours)?, registry);
        // The exit closes the worker's end of the socket, and the reader hangs up on that; this
        // task only reaps the child and records why it went.
        tokio::spawn(async move {
            match child.wait().await {
                Ok(status) => tracing::error!(%status, "the relay worker exited"),
                Err(error) => tracing::error!(%error, "could not wait for the relay worker"),
            }
        });
        Ok(worker)
    }

    /// A worker already running on the other end of `stream`, told of each registration that
    /// leaves so the items it held leave with it.
    pub(crate) fn over(stream: UnixStream, registry: Arc<Registry>) -> Arc<Self> {
        let (reader, writer) = stream.into_split();
        let worker = Arc::new(Self {
            writer: Arc::new(tokio::sync::Mutex::new(writer)),
            calls: Mutex::new(Some(Calls::default())),
        });
        let mut departures = registry.departures();
        tokio::spawn(Arc::clone(&worker).read(reader, registry));
        let leaving = Arc::clone(&worker);
        tokio::spawn(async move {
            while let Some(registration) = departures.recv().await {
                let params = vec![Value::from(registration)];
                if let Err(error) = leaving.call("agenda.leave", params).await {
                    tracing::warn!(%error, registration, "could not tell the relay a session left");
                }
            }
        });
        worker
    }

    pub(crate) fn is_running(&self) -> bool {
        self.calls().is_some()
    }

    fn calls(&self) -> MutexGuard<'_, Option<Calls>> {
        self.calls.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Every waiting publish learns the worker is gone, and every later one is refused at once.
    fn hang_up(&self) {
        self.calls().take();
    }

    /// `delta` as the registration `stamp` names published it, with the gate keys it shares
    /// items under; the worker's own reply or refusal.
    pub(crate) async fn publish(
        &self,
        stamp: &Stamp,
        delta: Value,
        keys: Value,
    ) -> Result<Value, RpcError> {
        self.call("agenda.publish", vec![reply(stamp)?, delta, keys])
            .await
    }

    async fn call(&self, method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        let (msgid, answered) = {
            let mut calls = self.calls();
            let calls = calls.as_mut().ok_or_else(unavailable)?;
            calls.next = calls.next.wrapping_add(1);
            let (answer, answered) = oneshot::channel();
            calls.waiting.insert(calls.next, answer);
            (calls.next, answered)
        };
        let frame = Value::Array(vec![
            Value::from(0),
            Value::from(msgid),
            Value::from(method),
            Value::Array(params),
        ]);
        let mut bytes = Vec::new();
        let encoded = rmpv::encode::write_value(&mut bytes, &frame);
        if encoded.is_err() || bytes.len() > WORKER_FRAME {
            self.forget(msgid);
            return Err(refused_with(
                "too_large",
                format!(
                    "the {method} is {} bytes, over the relay's frame ceiling of {WORKER_FRAME}",
                    bytes.len()
                ),
            ));
        }
        // Written from a task of its own: a session that hangs up mid-publish drops this future,
        // and a frame cut off halfway would end the worker's connection for every session.
        let writer = Arc::clone(&self.writer);
        let written =
            tokio::spawn(async move { writer.lock().await.write_all(&bytes).await }).await;
        if !matches!(written, Ok(Ok(()))) {
            self.forget(msgid);
            return Err(unavailable());
        }
        match answered.await {
            Ok((Value::Nil, result)) => Ok(result),
            Ok((error, _)) => Err(refused_with(
                "relay_refused",
                error.as_str().map_or_else(
                    || format!("the relay refused the {method}"),
                    |text| clip(&text),
                ),
            )),
            Err(_) => Err(unavailable()),
        }
    }

    fn forget(&self, msgid: u32) {
        if let Some(calls) = self.calls().as_mut() {
            calls.waiting.remove(&msgid);
        }
    }

    async fn read(self: Arc<Self>, mut reader: OwnedReadHalf, registry: Arc<Registry>) {
        let mut frames = Frames::default();
        let error = loop {
            match frames.next(&mut reader).await {
                Ok(frame) => self.take(frame, &registry),
                Err(error) => break error,
            }
        };
        tracing::error!(%error, "lost the relay worker's socket");
        self.hang_up();
    }

    fn take(&self, frame: Value, registry: &Registry) {
        let Value::Array(parts) = frame else {
            tracing::warn!("the relay worker sent a frame that is not an array");
            return;
        };
        match &parts[..] {
            [kind, msgid, error, result] if kind.as_u64() == Some(1) => {
                let waiting = msgid
                    .as_u64()
                    .and_then(|msgid| u32::try_from(msgid).ok())
                    .and_then(|msgid| self.calls().as_mut()?.waiting.remove(&msgid));
                if let Some(waiting) = waiting {
                    let _gone = waiting.send((error.clone(), result.clone()));
                }
            }
            [kind, method, params]
                if kind.as_u64() == Some(2) && method.as_str() == Some("answer") =>
            {
                deliver(params, registry);
            }
            _ => tracing::warn!("the relay worker sent a frame the daemon does not read"),
        }
    }
}

/// `[session, registration, answer]` pushed on to that registration's own connection, if it is
/// still registered.
fn deliver(params: &Value, registry: &Registry) {
    let params = params.as_array().map(Vec::as_slice).unwrap_or_default();
    let [session, registration, answer] = params else {
        tracing::warn!("the relay worker pushed an answer the daemon does not read");
        return;
    };
    let (Some(session), Some(registration)) = (session.as_str(), registration.as_u64()) else {
        tracing::warn!("the relay worker pushed an answer the daemon does not read");
        return;
    };
    let delivered = registry
        .outlet(session, registration)
        .map(|outlet| outlet.send("answer", vec![answer.clone()]));
    if !matches!(delivered, Some(Ok(()))) {
        tracing::warn!(session = clip(&session), "an answer's session is gone");
    }
}

fn unavailable() -> RpcError {
    refused_with("relay_unavailable", "the phone relay is unavailable")
}

/// Frames read from the worker, held to the ceiling its own codec holds the daemon to.
#[derive(Default)]
struct Frames {
    buffer: Vec<u8>,
}

impl Frames {
    async fn next(&mut self, reader: &mut (impl AsyncRead + Unpin)) -> io::Result<Value> {
        loop {
            let mut unread = &self.buffer[..];
            match rmpv::decode::read_value_with_max_depth(&mut unread, WORKER_DEPTH) {
                Ok(frame) => {
                    let used = self.buffer.len() - unread.len();
                    self.buffer.drain(..used);
                    return Ok(frame);
                }
                Err(error) if !is_incomplete(&error) => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        error.to_string(),
                    ));
                }
                Err(_) => {}
            }
            if self.buffer.len() > WORKER_FRAME {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("a frame passes {WORKER_FRAME} bytes"),
                ));
            }
            self.buffer.reserve(64 << 10);
            if reader.read_buf(&mut self.buffer).await? == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
        }
    }
}

fn is_incomplete(error: &rmpv::decode::Error) -> bool {
    use rmpv::decode::Error::{InvalidDataRead, InvalidMarkerRead};
    matches!(
        error,
        InvalidMarkerRead(source) | InvalidDataRead(source) if source.kind() == io::ErrorKind::UnexpectedEof
    )
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use lain_rpc::Wire;
    use lain_rpc::support::TestClient;
    use lain_wire::{
        AgendaItem, AgendaPage, Answer, AnswersPage, Cursor, Delta, Hello, Verdict, WIRE_VERSION,
        Welcome,
    };
    use rmpv::Value;
    use tokio::io::AsyncReadExt;
    use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};

    use super::Stamp;
    use super::agenda::{LONG_POLL, MAX_TAIL, REPLY_BUDGET};
    use super::devices::tests::{devices_file, line, rewrite};
    use super::devices::{DevicesFile, Watcher};
    use super::{Config, RELOAD_TICK, StartError};
    use lain_rpc::support::{request, response_parts};

    const TOKEN: &str = "a-paired-phone-token";
    const PHONE: &str = "phone";
    const TABLET: &str = "tablet";
    const TABLET_TOKEN: &str = "a-paired-tablet-token";

    fn both_paired() -> String {
        line(PHONE, TOKEN) + &line(TABLET, TABLET_TOKEN)
    }

    /// Long enough for the relay to reread its devices file.
    const REREAD: Duration = Duration::from_secs(RELOAD_TICK.as_secs() + 1);

    /// How long a test waits to see that nothing arrives. Every test that waits on a real socket
    /// runs on real time: paused time jumps past bytes still in the kernel, and the wait for them
    /// times out first.
    const PROMPTLY: Duration = Duration::from_secs(1);

    /// The bound on a wait for something that must arrive, on a loaded box.
    const WAIT: Duration = Duration::from_secs(5);

    struct Peer<C> {
        framed: TestClient<C>,
        next_msgid: u32,
    }

    impl<C: Wire> Peer<C> {
        fn over(stream: C) -> Self {
            Self {
                framed: TestClient::over(stream),
                next_msgid: 1,
            }
        }

        async fn send(&mut self, method: &str, params: Vec<Value>) -> u32 {
            let msgid = self.next_msgid;
            self.next_msgid += 1;
            self.framed.send(request(msgid, method, params)).await;
            msgid
        }

        /// The next reply within `wait`, or None when nothing came.
        async fn reply_within(&mut self, wait: Duration) -> Option<(u32, Value, Value)> {
            let frame = tokio::time::timeout(wait, self.framed.next_frame())
                .await
                .ok()?;
            Some(response_parts(
                frame
                    .expect("a reply, not a close")
                    .expect("decode a reply"),
            ))
        }

        async fn reply(&mut self) -> (u32, Value, Value) {
            self.reply_within(WAIT)
                .await
                .expect("a reply within the wait")
        }

        /// The (error, result) of one call answered at once.
        async fn call(&mut self, method: &str, params: Vec<Value>) -> (Value, Value) {
            let msgid = self.send(method, params).await;
            let (replied, error, result) = self.reply().await;
            assert_eq!(msgid, replied, "the reply to {method}");
            (error, result)
        }

        /// True when the relay closes its end with nothing more to say.
        /// Whether a ping on this connection is answered without an error; false on a close.
        async fn pings(&mut self) -> bool {
            let msgid = self.send("ping", vec![]).await;
            match tokio::time::timeout(WAIT, self.framed.next_frame()).await {
                Ok(Some(Ok(frame))) => {
                    let (replied, error, _) = response_parts(frame);
                    replied == msgid && error == Value::Nil
                }
                _ => false,
            }
        }

        async fn closes(self) -> bool {
            let mut stream = self.framed.into_inner();
            let mut buffer = [0u8; 64];
            matches!(
                tokio::time::timeout(WAIT, stream.read(&mut buffer)).await,
                Ok(Ok(0) | Err(_))
            )
        }
    }

    /// A phone admitted by its hello, with the relay epoch the hello reported.
    struct Phone {
        peer: Peer<TcpStream>,
        epoch: Option<u64>,
    }

    impl Phone {
        async fn next(&mut self, cursor: u64) -> Page {
            let (error, result) = self
                .peer
                .call("agenda.next", vec![at(cursor, self.epoch)])
                .await;
            assert_eq!(Value::Nil, error, "agenda.next({cursor})");
            Page::of(&result)
        }

        async fn answer(&mut self, answer: &Answer) -> Value {
            self.peer.call("answer.send", vec![value(answer)]).await.0
        }
    }

    struct Relay {
        _dir: tempfile::TempDir,
        socket: PathBuf,
        phone: SocketAddr,
        devices: PathBuf,
    }

    /// Serves on listeners already bound, over the devices file at `devices`.
    fn spawn_relay(lain: UnixListener, phone: TcpListener, devices: &Path) {
        let mut watcher = Watcher::new(DevicesFile::new(devices.to_path_buf()));
        let roster = watcher.read().expect("read the devices file");
        tokio::spawn(async move { match super::serve(lain, phone, watcher, roster).await {} });
    }

    async fn connect(address: SocketAddr) -> Peer<TcpStream> {
        let stream = TcpStream::connect(address).await.expect("connect a phone");
        // Nagle holds a second small request for the relay's delayed ack, about 40 ms.
        stream.set_nodelay(true).expect("no delay");
        Peer::over(stream)
    }

    /// The (error, result) of a hello with `token`.
    async fn hello_with(peer: &mut Peer<TcpStream>, token: &str) -> (Value, Value) {
        peer.call("hello", vec![hello(token, WIRE_VERSION)]).await
    }

    fn refused() -> (Value, Value) {
        (Value::from("the hello was refused"), Value::Nil)
    }

    impl Relay {
        async fn start() -> Self {
            let dir = tempfile::tempdir().expect("a tempdir for the socket");
            let socket = dir.path().join("relay.sock");
            let lain = UnixListener::bind(&socket).expect("bind the unix socket");
            let phone = TcpListener::bind(("127.0.0.1", 0))
                .await
                .expect("bind loopback");
            let address = phone.local_addr().expect("the bound address");
            let devices = devices_file(dir.path(), &both_paired());
            spawn_relay(lain, phone, &devices);
            Self {
                _dir: dir,
                socket,
                phone: address,
                devices,
            }
        }

        async fn lain(&self) -> Peer<UnixStream> {
            Peer::over(
                UnixStream::connect(&self.socket)
                    .await
                    .expect("connect lain"),
            )
        }

        async fn stranger(&self) -> Peer<TcpStream> {
            connect(self.phone).await
        }

        async fn hello(&self) -> (Peer<TcpStream>, Value) {
            self.hello_as(TOKEN).await
        }

        async fn hello_as(&self, token: &str) -> (Peer<TcpStream>, Value) {
            let mut peer = self.stranger().await;
            let (error, result) = hello_with(&mut peer, token).await;
            assert_eq!(Value::Nil, error, "a phone with a paired token was refused");
            (peer, result)
        }

        async fn phone(&self) -> Phone {
            self.phone_as(TOKEN).await
        }

        async fn phone_as(&self, token: &str) -> Phone {
            let (peer, welcome) = self.hello_as(token).await;
            let welcome: Welcome = message(&welcome);
            Phone {
                peer,
                epoch: Some(welcome.epoch),
            }
        }
    }

    /// One `agenda.next` reply.
    #[derive(Debug, PartialEq)]
    struct Page {
        reset: bool,
        deltas: Vec<Delta>,
    }

    impl Page {
        fn of(result: &Value) -> Self {
            let page: AgendaPage = message(result);
            Self {
                reset: page.reset,
                deltas: page.deltas,
            }
        }

        fn cursors(&self) -> Vec<u64> {
            self.deltas.iter().map(|delta| delta.cursor).collect()
        }
    }

    fn at(cursor: u64, epoch: Option<u64>) -> Value {
        value(&Cursor { cursor, epoch })
    }

    fn field(result: &Value, name: &str) -> Value {
        result
            .as_map()
            .unwrap_or_else(|| panic!("{result:?} is not a map"))
            .iter()
            .find(|(key, _)| key.as_str() == Some(name))
            .unwrap_or_else(|| panic!("no {name} in {result:?}"))
            .1
            .clone()
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

    fn encoded_len(value: &Value) -> usize {
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, value).expect("encode a value");
        bytes.len()
    }

    fn hello(token: &str, wire_version: u32) -> Value {
        value(&Hello {
            wire_version,
            token: token.to_string(),
            cursor: 0,
        })
    }

    fn parked(id: &str) -> AgendaItem {
        parked_with(id, "rm -rf build")
    }

    fn parked_with(id: &str, input: &str) -> AgendaItem {
        AgendaItem::ParkedCall {
            id: id.to_string(),
            requester: "main".to_string(),
            tool: "bash".to_string(),
            input: input.to_string(),
            cwd: "/home/tara/dev/lain".to_string(),
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

    fn settling(id: &str) -> Value {
        value(&Delta {
            cursor: 0,
            added: vec![],
            settled: vec![id.to_string()],
        })
    }

    fn approve(id: &str) -> Answer {
        approve_noting(id, None)
    }

    fn approve_noting(id: &str, note: Option<String>) -> Answer {
        Answer::Call {
            id: id.to_string(),
            verdict: Verdict::Approve { note },
            device: None,
        }
    }

    /// An approval as lain receives it from the phone paired as [`PHONE`].
    fn answered(id: &str) -> Answer {
        approve(id).stamped_by(PHONE)
    }

    async fn publish(lain: &mut Peer<UnixStream>, delta: Value) -> Value {
        let (error, _) = lain.call("agenda.publish", vec![delta]).await;
        error
    }

    /// One `answers.next` reply, with its answers as they came over the wire.
    struct AnswerPage {
        page: AnswersPage,
        raw: Vec<Value>,
    }

    async fn answers_page(
        lain: &mut Peer<UnixStream>,
        cursor: u64,
        epoch: Option<u64>,
    ) -> AnswerPage {
        let (error, result) = lain.call("answers.next", vec![at(cursor, epoch)]).await;
        assert_eq!(Value::Nil, error, "answers.next({cursor})");
        AnswerPage {
            page: message(&result),
            raw: field(&result, "answers")
                .as_array()
                .expect("an answers array")
                .clone(),
        }
    }

    /// The first page for a lain that has seen no epoch yet.
    async fn first_answers(lain: &mut Peer<UnixStream>) -> AnswersPage {
        answers_page(lain, 0, None).await.page
    }

    fn config(dir: &Path, listen: &str) -> Config {
        Config {
            unix: Some(dir.join("relay.sock")),
            listen: listen.to_string(),
            devices_file: devices_file(dir, &both_paired()),
            trace: None,
        }
    }

    fn socket_of(config: &Config) -> &Path {
        config.unix.as_deref().expect("a relay on its own socket")
    }

    #[test]
    fn the_relay_listens_only_on_loopback_or_this_hosts_tailscale0_address() {
        let tailscale0 = [IpAddr::V4(Ipv4Addr::new(100, 101, 2, 3))];
        for refused in [
            "0.0.0.0:7820",
            "192.168.1.5:7820",
            "100.64.9.9:7820",
            "[::]:7820",
        ] {
            let address: SocketAddr = refused.parse().expect("an address");
            let error = super::listen_rule(address, &tailscale0)
                .expect_err(&format!("{refused} was allowed"));
            assert_eq!(
                format!(
                    "the relay listens only on this host's own tailscale0 address, or loopback for tests; {refused} is neither"
                ),
                error.to_string()
            );
        }
        for allowed in ["100.101.2.3:7820", "127.0.0.1:7820", "[::1]:7820"] {
            let address: SocketAddr = allowed.parse().expect("an address");
            assert!(
                super::listen_rule(address, &tailscale0).is_ok(),
                "{allowed} was refused"
            );
        }
    }

    #[test]
    fn a_refused_address_stops_the_relay_before_it_binds_anything() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let config = config(dir.path(), "0.0.0.0:0");
        let error = super::Bound::open(&config)
            .err()
            .expect("0.0.0.0 was allowed");
        assert!(matches!(error, StartError::Listen(_)), "{error}");
        assert!(!socket_of(&config).exists(), "the socket was bound anyway");
    }

    #[test]
    fn a_host_name_to_listen_on_is_refused_saying_why() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let error = super::Bound::open(&config(dir.path(), "localhost:7820"))
            .err()
            .expect("a host name was resolved");
        assert_eq!(
            "--listen localhost:7820 is not an IP address and port; the relay resolves no names",
            error.to_string()
        );
    }

    #[test]
    fn an_unconfined_relay_exits_apart_from_a_bind_failure() {
        let bind = StartError::Bind {
            what: "127.0.0.1:7820".to_string(),
            error: std::io::Error::other("in use"),
        };
        assert_ne!(bind.exit_code(), StartError::Unconfined.exit_code());
        assert_ne!(crate::USAGE_ERROR, StartError::Unconfined.exit_code());
    }

    #[test]
    fn a_devices_file_beside_other_files_stops_the_relay_before_it_binds() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let config = config(dir.path(), "127.0.0.1:0");
        std::fs::write(config.devices_file.with_file_name("notes"), "x").expect("a neighbour");
        let error = super::Bound::open(&config)
            .err()
            .expect("a shared devices directory was allowed");
        assert_eq!(crate::USAGE_ERROR, error.exit_code(), "{error}");
        assert!(!socket_of(&config).exists(), "the socket was bound anyway");
    }

    #[test]
    fn a_stale_socket_is_replaced_and_a_live_one_is_left_alone() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let config = config(dir.path(), "127.0.0.1:0");
        drop(std::os::unix::net::UnixListener::bind(socket_of(&config)).expect("a stale socket"));
        assert!(socket_of(&config).exists());
        let bound = super::Bound::open(&config).expect("the stale socket was not replaced");
        drop(bound);

        std::fs::remove_file(socket_of(&config)).expect("clear the socket");
        let live =
            std::os::unix::net::UnixListener::bind(socket_of(&config)).expect("a live socket");
        let error = super::Bound::open(&config)
            .err()
            .expect("a live socket was taken over");
        assert_eq!(
            format!(
                "{} is in use by a listening process",
                socket_of(&config).display()
            ),
            error.to_string()
        );
        assert!(
            std::os::unix::net::UnixStream::connect(socket_of(&config)).is_ok(),
            "the live socket was removed"
        );
        drop(live);
    }

    #[tokio::test]
    async fn a_phone_without_the_token_is_refused_and_closed_before_any_item() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        assert_eq!(Value::Nil, publish(&mut lain, adding(parked("p1"))).await);

        for guess in [
            "a-guessed-token",
            "",
            "a-paired-phone",
            "a-paired-phone-token-and-more",
        ] {
            let mut stranger = relay.stranger().await;
            let (error, result) = stranger
                .call("hello", vec![hello(guess, WIRE_VERSION)])
                .await;
            assert_eq!(
                (Value::from("the hello was refused"), Value::Nil),
                (error, result),
                "the guess {guess:?}"
            );
            assert!(stranger.closes().await, "a refused phone stayed connected");
        }
    }

    #[tokio::test]
    async fn the_phone_gets_only_its_own_methods_and_lain_only_its_own() {
        let relay = Relay::start().await;
        let mut phone = relay.phone().await;
        for method in ["agenda.publish", "answers.next"] {
            let (error, _) = phone.peer.call(method, vec![Value::from(0)]).await;
            assert_eq!(
                Value::from(format!("unknown method {method:?}")),
                error,
                "the phone reached {method}"
            );
        }
        let mut lain = relay.lain().await;
        for method in ["hello", "agenda.next", "answer.send"] {
            let (error, _) = lain.call(method, vec![Value::from(0)]).await;
            assert_eq!(
                Value::from(format!("unknown method {method:?}")),
                error,
                "lain reached {method}"
            );
        }
    }

    #[tokio::test]
    async fn a_replayed_answer_is_already_settled_and_lain_sees_one() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        publish(&mut lain, adding(parked("p1"))).await;
        let mut phone = relay.phone().await;

        assert_eq!(Value::Nil, phone.answer(&approve("p1")).await);
        assert_eq!(
            Value::from("agenda item \"p1\" is already settled"),
            phone.answer(&approve("p1")).await
        );

        let page = first_answers(&mut lain).await;
        assert_eq!((1, vec![answered("p1")]), (page.cursor, page.answers));
        lain.send("answers.next", vec![at(1, Some(page.epoch))])
            .await;
        assert_eq!(
            None,
            lain.reply_within(PROMPTLY).await,
            "lain saw a second answer"
        );
    }

    #[tokio::test]
    async fn a_replayed_answer_quotes_at_most_64_characters_of_its_id() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let long = "i".repeat(4096);
        publish(&mut lain, adding(parked(&long))).await;
        let mut phone = relay.phone().await;
        phone.answer(&approve(&long)).await;
        let quoted = format!("{}...", "i".repeat(64));
        assert_eq!(
            Value::from(format!("agenda item {quoted:?} is already settled")),
            phone.answer(&approve(&long)).await
        );
    }

    #[tokio::test]
    async fn an_id_lain_settled_cannot_be_answered() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        publish(&mut lain, adding(parked("p1"))).await;
        publish(&mut lain, settling("p1")).await;

        let mut phone = relay.phone().await;
        assert_eq!(
            Value::from("agenda item \"p1\" is already settled"),
            phone.answer(&approve("p1")).await
        );
    }

    #[tokio::test]
    async fn only_an_id_open_now_can_be_answered() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let mut phone = relay.phone().await;
        assert_eq!(
            Value::from("agenda item \"p1\" is not open"),
            phone.answer(&approve("p1")).await
        );
        publish(&mut lain, adding(parked("p1"))).await;
        assert_eq!(Value::Nil, phone.answer(&approve("p1")).await);
        assert_eq!(vec![answered("p1")], first_answers(&mut lain).await.answers);
    }

    #[tokio::test]
    async fn lain_receives_the_answer_the_relay_checked_not_the_phones_bytes() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        publish(&mut lain, adding(parked("x1"))).await;
        publish(&mut lain, adding(parked("x2"))).await;
        let mut phone = relay.phone().await;
        let approval = Value::Map(vec![(Value::from("Approve"), Value::Map(vec![]))]);
        let extra_key = Value::Map(vec![(
            Value::from("Call"),
            Value::Map(vec![
                (Value::from("id"), Value::from("x1")),
                (Value::from("verdict"), approval.clone()),
                (Value::from("smuggled"), Value::from("y".repeat(1000))),
            ]),
        )]);
        let positional = Value::Map(vec![(
            Value::from("Call"),
            Value::Array(vec![Value::from("x2"), approval]),
        )]);
        for raw in [extra_key, positional] {
            let (error, _) = phone.peer.call("answer.send", vec![raw]).await;
            assert_eq!(Value::Nil, error);
        }
        assert_eq!(
            vec![value(&answered("x1")), value(&answered("x2"))],
            answers_page(&mut lain, 0, None).await.raw
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_relay_confines_itself_to_its_devices_and_socket_directories() {
        let dir = tempfile::tempdir().expect("a dir");
        let socket_dir = tempfile::tempdir().expect("a socket dir");
        let devices = devices_file(dir.path(), &both_paired());
        let neighbour = dir.path().join("neighbour");
        std::fs::write(&neighbour, "not the relay's").expect("write a neighbour");
        let socket_path = socket_dir.path().to_path_buf();
        let devices_dir = devices.parent().expect("the devices dir").to_path_buf();

        // Landlock binds the calling thread, so the test confines only a thread of its own.
        let seen = std::thread::spawn(move || {
            super::confine(&devices_dir, Some(&socket_path)).expect("confine");
            (
                std::fs::read(&devices).is_ok(),
                std::fs::read(&neighbour).is_ok(),
                std::fs::write(socket_path.join("relay.sock.tmp"), "x").is_ok(),
                std::fs::write(devices.with_file_name("written"), "x").is_ok(),
            )
        })
        .join()
        .expect("the confined thread");
        assert_eq!((true, false, true, false), seen);
    }

    #[test]
    fn a_confined_relay_rereads_its_devices_after_a_pair_and_a_revoke() {
        let dir = tempfile::tempdir().expect("a dir");
        let devices = devices_file(dir.path(), &line(PHONE, TOKEN));
        let socket_dir = dir.path().join("run");
        std::fs::create_dir(&socket_dir).expect("the socket dir");
        let lain = std::os::unix::net::UnixListener::bind(socket_dir.join("relay.sock"))
            .expect("bind the unix socket");
        let phone = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind loopback");
        let address = phone.local_addr().expect("the bound address");

        // The rewrites come from a thread spawned before the relay confined
        // itself, as `lain remote` runs outside the relay's ruleset.
        let (ask, asked) = std::sync::mpsc::channel::<String>();
        let (done, finished) = std::sync::mpsc::channel::<()>();
        let written = devices.clone();
        let writer = std::thread::spawn(move || {
            for text in asked {
                rewrite(&written, &text);
                done.send(()).expect("say it is written");
            }
        });
        let devices_dir = devices.parent().expect("the devices dir").to_path_buf();
        // Connected before confining: the ruleset refuses the relay's thread any TCP connect,
        // and the kernel queues each until the relay accepts it.
        let [first, second, third] =
            [(); 3].map(|()| std::net::TcpStream::connect(address).expect("connect a phone"));
        let seen = std::thread::spawn(move || {
            super::confine(&devices_dir, Some(&socket_dir)).expect("confine");
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("a runtime");
            runtime.block_on(async move {
                let rewrite = |text: String| {
                    ask.send(text).expect("ask for a rewrite");
                    finished.recv().expect("the rewrite");
                };
                lain.set_nonblocking(true).expect("nonblocking");
                phone.set_nonblocking(true).expect("nonblocking");
                spawn_relay(
                    UnixListener::from_std(lain).expect("adopt"),
                    TcpListener::from_std(phone).expect("adopt"),
                    &devices,
                );
                let adopt = |stream: std::net::TcpStream| {
                    stream.set_nonblocking(true).expect("nonblocking");
                    stream.set_nodelay(true).expect("no delay");
                    Peer::over(TcpStream::from_std(stream).expect("adopt"))
                };
                let mut phone = adopt(first);
                let phone_admitted = hello_with(&mut phone, TOKEN).await.0 == Value::Nil;

                rewrite(both_paired());
                tokio::time::sleep(REREAD).await;
                let mut tablet = adopt(second);
                let paired = hello_with(&mut tablet, TABLET_TOKEN).await.0 == Value::Nil;

                rewrite(line(TABLET, TABLET_TOKEN));
                tokio::time::sleep(REREAD).await;
                let closed = phone.closes().await;
                let mut again = adopt(third);
                let refused_again = hello_with(&mut again, TOKEN).await == refused();
                let tablet_up = tablet.call("ping", vec![]).await.0 == Value::Nil;
                (phone_admitted, paired, closed, refused_again, tablet_up)
            })
        })
        .join()
        .expect("the confined relay");
        writer.join().expect("the writer");
        assert_eq!((true, true, true, true, true), seen);
    }

    #[tokio::test]
    async fn an_answer_names_the_device_that_sent_it_whatever_it_claimed() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        publish(&mut lain, adding(parked("p1"))).await;
        publish(&mut lain, adding(parked("p2"))).await;
        let mut phone = relay.phone().await;
        let mut tablet = relay.phone_as(TABLET_TOKEN).await;
        assert_eq!(Value::Nil, phone.answer(&approve("p1")).await);
        let claiming = approve("p2").stamped_by(PHONE);
        assert_eq!(Value::Nil, tablet.answer(&claiming).await);
        assert_eq!(
            vec![answered("p1"), approve("p2").stamped_by(TABLET)],
            first_answers(&mut lain).await.answers
        );
    }

    #[tokio::test]
    async fn a_revoked_device_is_closed_and_refused_while_another_keeps_answering() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        publish(&mut lain, adding(parked("p1"))).await;
        let mut phone = relay.phone().await;
        let mut tablet = relay.phone_as(TABLET_TOKEN).await;
        let waiting = phone
            .peer
            .send("agenda.next", vec![at(1, phone.epoch)])
            .await;
        assert_eq!(None, phone.peer.reply_within(PROMPTLY).await, "{waiting}");

        rewrite(&relay.devices, &line(TABLET, TABLET_TOKEN));
        tokio::time::sleep(REREAD).await;
        assert!(
            phone.peer.closes().await,
            "a revoked phone stayed connected"
        );
        let mut again = relay.stranger().await;
        assert_eq!(refused(), hello_with(&mut again, TOKEN).await);
        assert_eq!(Value::Nil, tablet.answer(&approve("p1")).await);
        assert_eq!(
            vec![approve("p1").stamped_by(TABLET)],
            first_answers(&mut lain).await.answers
        );
    }

    /// No socket here: real I/O lets paused time run ahead, which would hide
    /// a reread that waits longer than one tick.
    #[tokio::test(start_paused = true)]
    async fn a_revoke_is_read_within_one_tick() {
        async fn settle() {
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
        }
        let dir = tempfile::tempdir().expect("a dir");
        let devices = devices_file(dir.path(), &both_paired());
        let mut watcher = Watcher::new(DevicesFile::new(devices.clone()));
        let roster = watcher.read().expect("read the devices file");
        let relay = std::sync::Arc::new(super::Relay::new(roster));
        tokio::spawn(super::reread(watcher, std::sync::Arc::clone(&relay)));
        settle().await;

        rewrite(&devices, &line(TABLET, TABLET_TOKEN));
        tokio::time::advance(RELOAD_TICK - Duration::from_millis(1)).await;
        settle().await;
        assert!(
            relay.paired.admit(TOKEN).is_some(),
            "reread before its tick"
        );
        tokio::time::advance(Duration::from_millis(1)).await;
        settle().await;
        assert!(
            relay.paired.admit(TOKEN).is_none(),
            "a revoke was not read within one tick"
        );
        assert!(relay.paired.admit(TABLET_TOKEN).is_some());
    }

    #[tokio::test]
    async fn a_second_hello_on_an_admitted_connection_is_an_unknown_method() {
        let relay = Relay::start().await;
        let mut phone = relay.phone().await;
        assert_eq!(
            Value::from("unknown method \"hello\""),
            hello_with(&mut phone.peer, TOKEN).await.0
        );
    }

    #[tokio::test]
    async fn a_device_paired_while_the_relay_runs_is_admitted_after_the_reread() {
        let relay = Relay::start().await;
        let mut early = relay.stranger().await;
        assert_eq!(refused(), hello_with(&mut early, "a-new-watch-token").await);
        let mut phone = relay.phone().await;

        rewrite(
            &relay.devices,
            &(both_paired() + &line("watch", "a-new-watch-token")),
        );
        tokio::time::sleep(REREAD).await;
        relay.hello_as("a-new-watch-token").await;
        let (error, _) = phone.peer.call("ping", vec![]).await;
        assert_eq!(Value::Nil, error, "a pair closed a device it did not name");
    }

    async fn ping_version<C: Wire>(peer: &mut Peer<C>) -> Option<Value> {
        let (error, result) = peer.call("ping", vec![]).await;
        assert_eq!(Value::Nil, error);
        result
            .as_map()?
            .iter()
            .find(|(key, _)| key.as_str() == Some("version"))
            .map(|(_, version)| version.clone())
    }

    #[tokio::test]
    async fn both_listeners_ping_with_this_binarys_version() {
        let relay = Relay::start().await;
        let ours = Some(Value::from(env!("CARGO_PKG_VERSION")));
        assert_eq!(
            ours,
            ping_version(&mut relay.lain().await).await,
            "lain side"
        );
        assert_eq!(
            ours,
            ping_version(&mut relay.phone().await.peer).await,
            "phone side"
        );
    }

    #[tokio::test]
    async fn lain_publishes_the_phone_long_polls_and_its_answer_reaches_lain() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let waiting = lain.send("answers.next", vec![at(0, None)]).await;
        let mut phone = relay.phone().await;
        let polling = phone
            .peer
            .send("agenda.next", vec![at(0, phone.epoch)])
            .await;
        assert_eq!(
            None,
            phone.peer.reply_within(PROMPTLY).await,
            "an empty agenda answered"
        );

        let (error, _) = phone.peer.call("ping", vec![]).await;
        assert_eq!(
            Value::Nil,
            error,
            "a long-poll blocked a ping on its connection"
        );

        let mut publisher = relay.lain().await;
        let (error, cursor) = publisher
            .call("agenda.publish", vec![adding(parked("p1"))])
            .await;
        assert_eq!((Value::Nil, Value::from(1)), (error, cursor));

        let (msgid, error, result) = phone.peer.reply().await;
        assert_eq!((polling, Value::Nil), (msgid, error));
        let expected = Delta {
            cursor: 1,
            added: vec![parked("p1")],
            settled: vec![],
        };
        assert_eq!(
            Page {
                reset: false,
                deltas: vec![expected]
            },
            Page::of(&result)
        );

        assert_eq!(Value::Nil, phone.answer(&approve("p1")).await);
        let (msgid, error, result) = lain.reply().await;
        assert_eq!((waiting, Value::Nil), (msgid, error));
        let delivered: AnswersPage = message(&result);
        assert_eq!(
            (1, vec![answered("p1")]),
            (delivered.cursor, delivered.answers)
        );
    }

    #[tokio::test]
    async fn a_reconnecting_phone_gets_only_the_deltas_after_its_cursor() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for n in 1..=9 {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let mut phone = relay.phone().await;
        assert_eq!(vec![8, 9], phone.next(7).await.cursors());
    }

    #[tokio::test]
    async fn the_hello_reports_the_head_cursor_and_the_relay_epoch() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for n in 1..=3 {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let (_, welcome) = relay.hello().await;
        let welcome: Welcome = message(&welcome);
        assert_eq!((WIRE_VERSION, 3), (welcome.wire_version, welcome.head));
        let other = Relay::start().await;
        let (_, other_welcome) = other.hello().await;
        let other_welcome: Welcome = message(&other_welcome);
        assert_ne!(
            welcome.epoch, other_welcome.epoch,
            "2 relays share an epoch"
        );
    }

    fn snapshot(cursor: u64, ids: &[&str]) -> Page {
        Page {
            reset: true,
            deltas: vec![Delta {
                cursor,
                added: ids.iter().map(|id| parked(id)).collect(),
                settled: vec![],
            }],
        }
    }

    #[tokio::test]
    async fn a_cursor_past_the_head_gets_the_snapshot_at_once() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for n in 1..=3 {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        publish(&mut lain, settling("p2")).await;
        let mut phone = relay.phone().await;
        assert_eq!(snapshot(4, &["p1", "p3"]), phone.next(50).await);
    }

    #[tokio::test]
    async fn a_cursor_from_another_epoch_gets_the_snapshot() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for n in 1..=3 {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let mut phone = relay.phone().await;
        phone.epoch = phone.epoch.map(|epoch| epoch.wrapping_add(1));
        assert_eq!(snapshot(3, &["p1", "p2", "p3"]), phone.next(1).await);
    }

    #[tokio::test]
    async fn a_catch_up_is_paged_under_the_reply_budget() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let big = "z".repeat(500_000);
        assert_eq!(
            Value::Nil,
            publish(&mut lain, adding(parked_with("a", &big))).await
        );
        assert_eq!(Value::Nil, publish(&mut lain, settling("a")).await);
        assert_eq!(
            Value::Nil,
            publish(&mut lain, adding(parked_with("b", &big))).await
        );

        let mut phone = relay.phone().await;
        let first = phone.next(0).await;
        assert_eq!((false, vec![1, 2]), (first.reset, first.cursors()));
        let second = phone.next(2).await;
        assert_eq!((false, vec![3]), (second.reset, second.cursors()));
    }

    #[tokio::test]
    async fn a_delta_or_an_agenda_over_the_budget_is_refused_at_publish() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let huge = adding(parked_with("huge", &"z".repeat(REPLY_BUDGET)));
        let bytes = encoded_len(&huge);
        assert_eq!(
            Value::from(format!(
                "the delta is {bytes} bytes, over the relay's reply budget of {REPLY_BUDGET}"
            )),
            publish(&mut lain, huge).await
        );

        let half = "z".repeat(REPLY_BUDGET / 2);
        assert_eq!(
            Value::Nil,
            publish(&mut lain, adding(parked_with("a", &half))).await
        );
        let error = publish(&mut lain, adding(parked_with("b", &half))).await;
        let error = error.as_str().expect("an error");
        assert!(
            error.starts_with("the agenda would be ")
                && error.ends_with(&format!(
                    " bytes, over the relay's reply budget of {REPLY_BUDGET}"
                )),
            "{error}"
        );
        let mut phone = relay.phone().await;
        assert_eq!(vec![1], phone.next(50).await.cursors());
    }

    #[tokio::test]
    async fn a_cursor_older_than_the_kept_history_gets_the_snapshot() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let count = u64::try_from(MAX_TAIL).expect("a count") + 5;
        for n in 1..=count {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let mut phone = relay.phone().await;
        let page = phone.next(0).await;
        assert!(page.reset, "a cursor before the kept history was replayed");
        assert_eq!(vec![count], page.cursors());
        assert_eq!(
            usize::try_from(count).expect("a len"),
            page.deltas[0].added.len()
        );
        assert_eq!(
            vec![count],
            phone.next(count - 1).await.cursors(),
            "a cursor inside the kept history was reset"
        );
    }

    #[tokio::test]
    async fn answers_are_paged_and_one_over_the_budget_is_refused() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for id in ["a", "b", "c"] {
            publish(&mut lain, adding(parked(id))).await;
        }
        let mut phone = relay.phone().await;
        let half = Some("n".repeat(500_000));
        assert_eq!(
            Value::Nil,
            phone.answer(&approve_noting("a", half.clone())).await
        );
        assert_eq!(Value::Nil, phone.answer(&approve_noting("b", half)).await);
        let over = phone
            .answer(&approve_noting("c", Some("n".repeat(REPLY_BUDGET))))
            .await;
        assert!(
            over.as_str()
                .is_some_and(|error| error.starts_with("the answer is ")),
            "{over:?}"
        );

        let first = first_answers(&mut lain).await;
        assert_eq!((1, 1), (first.cursor, first.answers.len()));
        let second = answers_page(&mut lain, 1, Some(first.epoch)).await.page;
        assert_eq!((2, 1), (second.cursor, second.answers.len()));
    }

    #[tokio::test]
    async fn an_answer_cursor_older_than_the_kept_answers_resets() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        let count = MAX_TAIL + 5;
        for n in 0..count {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let mut phone = relay.phone().await;
        for n in 0..count {
            assert_eq!(Value::Nil, phone.answer(&approve(&format!("p{n}"))).await);
        }
        let page = first_answers(&mut lain).await;
        assert!(page.reset, "a cursor before the kept answers was replayed");
        let resumed = answers_page(&mut lain, page.cursor - 1, Some(page.epoch))
            .await
            .page;
        assert!(!resumed.reset, "a cursor inside the kept answers was reset");
    }

    #[tokio::test]
    async fn a_phone_on_another_wire_version_is_told_both_and_which_side_to_update() {
        let relay = Relay::start().await;
        for (version, advice) in [(1, "update the phone app"), (3, "update lain")] {
            let mut other = relay.stranger().await;
            let (error, _) = other.call("hello", vec![hello(TOKEN, version)]).await;
            assert_eq!(
                Value::from(format!(
                    "wire version {version} is not served; this relay speaks 2: {advice}"
                )),
                error
            );
            assert!(
                other.closes().await,
                "a phone on version {version} stayed connected"
            );
        }

        let mut phone = relay.phone().await;
        let (error, _) = phone.peer.call("ping", vec![]).await;
        assert_eq!(Value::Nil, error);
    }

    /// The agenda itself, so the window is paused time alone; over a socket it would be 30 real
    /// seconds.
    #[tokio::test(start_paused = true)]
    async fn a_long_poll_with_nothing_new_answers_empty_after_its_window() {
        let agenda = super::agenda::Agenda::default();
        let started = tokio::time::Instant::now();
        let page = agenda.deltas_after(0, Some(agenda.epoch())).await;
        let waited = started.elapsed();
        assert!(
            (LONG_POLL..LONG_POLL + PROMPTLY).contains(&waited),
            "{waited:?}"
        );
        assert_eq!(
            (false, 0, 0),
            (page.reset, page.cursor, page.messages.len())
        );
    }

    #[tokio::test]
    async fn dropped_long_polls_free_their_connection_slots() {
        // Lain's Unix side shares the connection code with the phone's, and a Unix close is seen
        // sooner than a loopback TCP one under load.
        let relay = Relay::start().await;
        for _ in 0..64 {
            let mut lain = relay.lain().await;
            lain.send("answers.next", vec![at(0, None)]).await;
            drop(lain);
        }
        let deadline = tokio::time::Instant::now() + WAIT;
        while !relay.lain().await.pings().await {
            assert!(
                tokio::time::Instant::now() < deadline,
                "a dropped long-poll held its slot"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// The worker run in-process, with `uplink` playing the daemon's end of its socket.
    struct Worker {
        _dir: tempfile::TempDir,
        uplink: Peer<UnixStream>,
        phone: SocketAddr,
        served: tokio::task::JoinHandle<()>,
    }

    fn stamp(session: &str, registration: u64) -> Value {
        value(&Stamp {
            session: session.to_string(),
            project: project_of(session),
            registration,
        })
    }

    /// The root `session` registered with, which no item names.
    fn project_of(session: &str) -> String {
        format!("/work/{session}")
    }

    fn source_of(item: &AgendaItem) -> (&str, &str) {
        match item {
            AgendaItem::ParkedCall {
                session, project, ..
            }
            | AgendaItem::GateQuestion {
                session, project, ..
            }
            | AgendaItem::Question {
                session, project, ..
            } => (session, project),
        }
    }

    fn no_keys() -> Value {
        Value::Map(vec![])
    }

    fn keyed(local: &str, key: &str) -> Value {
        Value::Map(vec![(Value::from(local), Value::from(key))])
    }

    fn gate(id: &str) -> AgendaItem {
        AgendaItem::GateQuestion {
            id: id.to_string(),
            requester: "main".to_string(),
            epic: "e".to_string(),
            stage: "review".to_string(),
            issues: vec!["i1".to_string()],
            question: "land the wave?".to_string(),
            asked_at: 1_793_000_000,
            session: "claimed-session".to_string(),
            project: "/claimed/project".to_string(),
        }
    }

    fn approve_gate(id: &str) -> Answer {
        Answer::Gate {
            id: id.to_string(),
            verdicts: vec![("i1".to_string(), Verdict::Approve { note: None })],
            device: None,
        }
    }

    fn id_of(item: &AgendaItem) -> &str {
        match item {
            AgendaItem::ParkedCall { id, .. }
            | AgendaItem::GateQuestion { id, .. }
            | AgendaItem::Question { id, .. } => id,
        }
    }

    /// The phone-facing id of the 1 parked call whose input is `input`.
    fn id_for_input(items: &[AgendaItem], input: &str) -> String {
        let ids: Vec<&str> = items
            .iter()
            .filter(
                |item| matches!(item, AgendaItem::ParkedCall { input: text, .. } if text == input),
            )
            .map(id_of)
            .collect();
        assert_eq!(1, ids.len(), "{items:?}");
        ids[0].to_string()
    }

    impl Worker {
        async fn start() -> Self {
            let dir = tempfile::tempdir().expect("a tempdir");
            let (ours, theirs) = UnixStream::pair().expect("a socket pair");
            let phone = TcpListener::bind(("127.0.0.1", 0))
                .await
                .expect("bind loopback");
            let address = phone.local_addr().expect("the bound address");
            let devices = devices_file(dir.path(), &both_paired());
            let mut watcher = Watcher::new(DevicesFile::new(devices));
            let roster = watcher.read().expect("read the devices file");
            let served = tokio::spawn(super::serve_worker(theirs, phone, watcher, roster));
            Self {
                _dir: dir,
                uplink: Peer::over(ours),
                phone: address,
                served,
            }
        }

        /// The error of 1 publish from the session registered as `registration`.
        async fn publish_with(
            &mut self,
            session: &str,
            registration: u64,
            delta: Value,
            keys: Value,
        ) -> Value {
            let stamp = stamp(session, registration);
            self.uplink
                .call("agenda.publish", vec![stamp, delta, keys])
                .await
                .0
        }

        async fn publish(&mut self, session: &str, registration: u64, item: AgendaItem) {
            let error = self
                .publish_with(session, registration, adding(item), no_keys())
                .await;
            assert_eq!(Value::Nil, error, "the publish for {session}");
        }

        async fn leave(&mut self, registration: u64) {
            let (error, _) = self
                .uplink
                .call("agenda.leave", vec![Value::from(registration)])
                .await;
            assert_eq!(Value::Nil, error, "registration {registration} leaving");
        }

        async fn phone(&self) -> Phone {
            let mut peer = connect(self.phone).await;
            let (error, welcome) = hello_with(&mut peer, TOKEN).await;
            assert_eq!(Value::Nil, error);
            let welcome: Welcome = message(&welcome);
            Phone {
                peer,
                epoch: Some(welcome.epoch),
            }
        }

        /// The next push on the uplink as its method, session, registration and answer.
        async fn pushed(&mut self) -> (String, String, u64, Answer) {
            let frame = tokio::time::timeout(WAIT, self.uplink.framed.next_frame())
                .await
                .expect("a push within the wait")
                .expect("a frame, not a close")
                .expect("decode a frame");
            let Value::Array(parts) = frame else {
                panic!("{frame} is not a frame")
            };
            assert_eq!(Value::from(2), parts[0], "not a push: {parts:?}");
            let params = parts[2].as_array().expect("push params");
            (
                parts[1].as_str().expect("a method").to_string(),
                params[0].as_str().expect("a session").to_string(),
                params[1].as_u64().expect("a registration"),
                message(&params[2]),
            )
        }
    }

    impl Phone {
        /// Every item open now, from a snapshot.
        async fn items(&mut self) -> Vec<AgendaItem> {
            let page = self.next(u64::MAX).await;
            assert!(page.reset, "{page:?}");
            page.deltas
                .into_iter()
                .flat_map(|delta| delta.added)
                .collect()
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_worker_confines_itself_to_reading_its_devices_directory() {
        let dir = tempfile::tempdir().expect("a dir");
        let elsewhere = tempfile::tempdir().expect("another dir");
        let devices = devices_file(dir.path(), &both_paired());
        let neighbour = dir.path().join("neighbour");
        std::fs::write(&neighbour, "not the relay's").expect("write a neighbour");
        let elsewhere = elsewhere.path().to_path_buf();
        let devices_dir = devices.parent().expect("the devices dir").to_path_buf();
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind loopback");
        let address = listener.local_addr().expect("the bound address");
        let mut outsider = std::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn sleep");
        let outsider_pid =
            nix::unistd::Pid::from_raw(i32::try_from(outsider.id()).expect("a pid that fits"));

        let seen = std::thread::spawn(move || {
            super::confine(&devices_dir, None).expect("confine");
            (
                std::fs::read(&devices).is_ok(),
                std::fs::read(&neighbour).is_ok(),
                std::fs::write(devices.with_file_name("written"), "x").is_ok(),
                std::fs::write(elsewhere.join("written"), "x").is_ok(),
                std::net::TcpStream::connect(address).is_ok(),
                nix::sys::signal::kill(outsider_pid, None).is_ok(),
            )
        })
        .join()
        .expect("the confined thread");
        let _ = outsider.kill();
        let _ = outsider.wait();
        assert_eq!((true, false, false, false, false, false), seen);
    }

    #[tokio::test]
    async fn the_same_local_id_from_two_sessions_is_two_items_each_answered_to_its_own() {
        let mut worker = Worker::start().await;
        worker.publish("sa", 1, parked_with("1", "for a")).await;
        worker.publish("sb", 2, parked_with("1", "for b")).await;
        let mut phone = worker.phone().await;
        let items = phone.items().await;
        let (for_a, for_b) = (id_for_input(&items, "for a"), id_for_input(&items, "for b"));
        assert_ne!(for_a, for_b);
        assert!(
            !items.iter().any(|item| id_of(item) == "1"),
            "the phone saw a session's own id: {items:?}"
        );

        assert_eq!(Value::Nil, phone.answer(&approve(&for_a)).await);
        assert_eq!(
            ("answer".to_string(), "sa".to_string(), 1, answered("1")),
            worker.pushed().await
        );
        assert_eq!(Value::Nil, phone.answer(&approve(&for_b)).await);
        assert_eq!(
            ("answer".to_string(), "sb".to_string(), 2, answered("1")),
            worker.pushed().await
        );
    }

    #[tokio::test]
    async fn each_item_carries_the_session_and_project_it_was_registered_with_not_its_own() {
        let mut worker = Worker::start().await;
        worker.publish("sa", 1, parked_with("1", "for a")).await;
        worker.publish("sb", 2, gate("g")).await;
        let mut phone = worker.phone().await;
        let mut sources: Vec<(String, String)> = phone
            .items()
            .await
            .iter()
            .map(|item| {
                let (session, project) = source_of(item);
                (session.to_string(), project.to_string())
            })
            .collect();
        sources.sort();
        assert_eq!(
            vec![
                ("sa".to_string(), project_of("sa")),
                ("sb".to_string(), project_of("sb")),
            ],
            sources
        );
    }

    #[tokio::test]
    async fn an_answer_reaches_only_the_session_holding_its_id_whatever_session_it_names() {
        let mut worker = Worker::start().await;
        worker.publish("sa", 1, parked_with("1", "for a")).await;
        worker.publish("sb", 2, parked_with("1", "for b")).await;
        let mut phone = worker.phone().await;
        let for_a = id_for_input(&phone.items().await, "for a");
        let Value::Map(mut answer) = value(&approve(&for_a)) else {
            panic!("an answer is a map")
        };
        let Some((_, Value::Map(fields))) = answer.first_mut() else {
            panic!("an answer names its variant")
        };
        fields.push((Value::from("session"), Value::from("sb")));
        let (error, _) = phone
            .peer
            .call("answer.send", vec![Value::Map(answer)])
            .await;
        assert_eq!(Value::Nil, error);

        assert_eq!(
            ("answer".to_string(), "sa".to_string(), 1, answered("1")),
            worker.pushed().await
        );
        assert!(
            tokio::time::timeout(
                Duration::from_millis(300),
                worker.uplink.framed.next_frame()
            )
            .await
            .is_err(),
            "a second session heard of the answer"
        );
    }

    #[tokio::test]
    async fn a_gate_is_shared_only_through_its_key_and_answered_to_its_newest_holder() {
        let mut worker = Worker::start().await;
        for (session, registration, local) in [("sa", 1, "ga"), ("sb", 2, "gb")] {
            let error = worker
                .publish_with(
                    session,
                    registration,
                    adding(gate(local)),
                    keyed(local, "digest"),
                )
                .await;
            assert_eq!(Value::Nil, error);
        }
        worker.publish("sc", 3, gate("ga")).await;

        let mut phone = worker.phone().await;
        let items = phone.items().await;
        assert_eq!(2, items.len(), "{items:?}");
        assert_eq!(
            Value::Nil,
            phone.answer(&approve_gate(id_of(&items[0]))).await
        );
        let (_, session, registration, answer) = worker.pushed().await;
        assert_eq!(("sb", 2), (session.as_str(), registration));
        assert_eq!(approve_gate("gb").stamped_by(PHONE), answer);
        assert_eq!(
            Value::Nil,
            phone.answer(&approve_gate(id_of(&items[1]))).await
        );
        let (_, session, _, answer) = worker.pushed().await;
        assert_eq!("sc", session);
        assert_eq!(approve_gate("ga").stamped_by(PHONE), answer);
    }

    #[tokio::test]
    async fn a_shared_gate_stays_open_until_its_last_holder_lets_go() {
        let mut worker = Worker::start().await;
        for (session, registration) in [("sa", 1), ("sb", 2), ("sc", 3)] {
            let error = worker
                .publish_with(
                    session,
                    registration,
                    adding(gate("g")),
                    keyed("g", "digest"),
                )
                .await;
            assert_eq!(Value::Nil, error);
        }
        let mut phone = worker.phone().await;

        worker.leave(3).await;
        let items = phone.items().await;
        assert_eq!(1, items.len(), "left by its newest holder of 3");
        assert_eq!(
            Value::Nil,
            worker.publish_with("sa", 1, settling("g"), no_keys()).await
        );
        assert_eq!(1, phone.items().await.len(), "settled by its oldest holder");

        assert_eq!(
            Value::Nil,
            phone.answer(&approve_gate(id_of(&items[0]))).await
        );
        let (_, session, registration, answer) = worker.pushed().await;
        assert_eq!(("sb", 2), (session.as_str(), registration));
        assert_eq!(approve_gate("g").stamped_by(PHONE), answer);
        worker.leave(2).await;
        assert_eq!(0, phone.items().await.len(), "its last holder left");
    }

    #[tokio::test]
    async fn a_session_settles_only_its_own_items() {
        let mut worker = Worker::start().await;
        worker.publish("sa", 1, parked("1")).await;
        assert_eq!(
            Value::Nil,
            worker.publish_with("sb", 2, settling("1"), no_keys()).await
        );
        let mut phone = worker.phone().await;
        assert_eq!(1, phone.items().await.len());
    }

    #[tokio::test]
    async fn a_session_that_leaves_takes_its_items_off_the_agenda() {
        let mut worker = Worker::start().await;
        worker.publish("sa", 1, parked_with("a1", "for a")).await;
        worker.publish("sb", 2, parked_with("b1", "for b")).await;
        worker.leave(2).await;
        let mut phone = worker.phone().await;
        let items = phone.items().await;
        assert_eq!(1, items.len(), "{items:?}");
        id_for_input(&items, "for a");
    }

    #[tokio::test]
    async fn a_gate_key_on_anything_but_a_gate_question_in_the_delta_is_refused() {
        let mut worker = Worker::start().await;
        for keys in [keyed("p1", "digest"), keyed("absent", "digest")] {
            let error = worker
                .publish_with("sa", 1, adding(parked("p1")), keys)
                .await;
            assert_eq!(
                Value::from("a gate key names an item that is not a gate question in its delta"),
                error
            );
        }
        let mut phone = worker.phone().await;
        assert!(phone.items().await.is_empty());
    }

    #[tokio::test]
    async fn the_worker_stops_when_its_daemon_hangs_up() {
        let worker = Worker::start().await;
        drop(worker.uplink);
        tokio::time::timeout(Duration::from_secs(5), worker.served)
            .await
            .expect("the worker kept serving after its daemon hung up")
            .expect("the worker task");
    }

    #[tokio::test]
    async fn the_worker_refuses_a_publish_without_a_stamp() {
        let mut worker = Worker::start().await;
        let (error, _) = worker
            .uplink
            .call("agenda.publish", vec![adding(parked("p1"))])
            .await;
        assert_eq!(
            Value::from("agenda.publish takes [Stamp, Delta, Keys]"),
            error
        );
    }

    fn nested(depth: usize) -> Value {
        (0..depth).fold(Value::Nil, |inner, _| Value::Array(vec![inner]))
    }

    #[tokio::test]
    async fn the_daemon_reads_a_shallow_frame_and_refuses_a_deep_one_without_recursing_into_it() {
        use tokio::io::AsyncWriteExt;
        for (depth, readable) in [(16, true), (super::WORKER_DEPTH * 2, false)] {
            let (mut ours, mut theirs) = UnixStream::pair().expect("a socket pair");
            let mut bytes = Vec::new();
            rmpv::encode::write_value(&mut bytes, &nested(depth)).expect("encode");
            ours.write_all(&bytes).await.expect("write");
            let read = super::Frames::default().next(&mut theirs).await;
            assert_eq!(readable, read.is_ok(), "depth {depth}: {read:?}");
        }
    }
}
