//! The phone relay: lain publishes its agenda on the Unix socket, and a paired
//! phone reads it and answers over the tailnet.

mod agenda;
mod devices;

use std::convert::Infallible;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use lain_wire::{AgendaPage, Answer, AnswersPage, Cursor, Delta, Hello, WIRE_VERSION, Welcome};
use rmpv::Value;
use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::net::{TcpListener, TcpStream, UnixListener};

use crate::rpc::{self, Accept, Handler, RpcError, Session};
use agenda::{Agenda, REPLY_BUDGET, Refusal};
use devices::{Admitted, DevicesError, DevicesFile, Paired, Roster, Watcher};

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
}

impl StartError {
    /// A refusal of the command line or its files is a usage error, a socket
    /// that cannot be had a bind error, and a relay that cannot confine itself
    /// its own code, so a caller can tell the kernel is what refused.
    pub(crate) fn exit_code(&self) -> u8 {
        match self {
            Self::Listen(_) | Self::ListenUnparsable(_) | Self::Devices(_) => crate::USAGE_ERROR,
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

/// `relay --unix <sock> --listen <addr>:<port> --devices-file <path> [--trace <path>]`.
pub(crate) struct Config {
    pub(crate) unix: PathBuf,
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
            unix: PathBuf::from(unix?),
            listen: listen?,
            devices_file: PathBuf::from(devices_file?),
            trace,
        })
    }

    pub(crate) fn socket_dir(&self) -> &Path {
        self.unix
            .parent()
            .filter(|dir| !dir.as_os_str().is_empty())
            .unwrap_or(Path::new("."))
    }
}

/// Both listeners and the paired devices, taken before the relay confines itself.
pub(crate) struct Bound {
    lain: std::os::unix::net::UnixListener,
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
        clear_stale_socket(&config.unix)?;
        let bind_error = |what: String| move |error| StartError::Bind { what, error };
        let lain = std::os::unix::net::UnixListener::bind(&config.unix)
            .map_err(bind_error(config.unix.display().to_string()))?;
        let phone = std::net::TcpListener::bind(listen).map_err(|error| {
            let _ = std::fs::remove_file(&config.unix);
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

    /// Takes a runtime context: tokio adopts the listeners here.
    pub(crate) fn serve(self) -> io::Result<impl Future<Output = Infallible>> {
        self.lain.set_nonblocking(true)?;
        self.phone.set_nonblocking(true)?;
        let lain = UnixListener::from_std(self.lain)?;
        let phone = TcpListener::from_std(self.phone)?;
        Ok(serve(lain, phone, self.watcher, self.roster))
    }
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

/// Every filesystem right is handled, so all but these two grants are refused,
/// for the calling thread and every thread it spawns after. The devices
/// directory is listed too, because every reread checks what it holds. A kernel that
/// enforces none of it is refused too: an unconfined relay is not one we run.
#[cfg(not(target_os = "linux"))]
pub(crate) fn confine(_: &Path, _: &Path) -> Result<(), StartError> {
    Err(StartError::Unconfined)
}

#[cfg(target_os = "linux")]
pub(crate) fn confine(devices_dir: &Path, socket_dir: &Path) -> Result<(), StartError> {
    use landlock::{
        ABI, Access, AccessFs, Ruleset, RulesetAttr, RulesetCreatedAttr, RulesetStatus,
        path_beneath_rules,
    };
    const TARGET: ABI = ABI::V6;
    let status = Ruleset::default()
        .handle_access(AccessFs::from_all(TARGET))
        .and_then(|ruleset| ruleset.create())
        .and_then(|ruleset| {
            ruleset.add_rules(path_beneath_rules(
                [devices_dir],
                AccessFs::ReadFile | AccessFs::ReadDir,
            ))
        })
        .and_then(|ruleset| {
            ruleset.add_rules(path_beneath_rules(
                [socket_dir],
                AccessFs::from_write(TARGET),
            ))
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
    let relay = Arc::new(Relay {
        paired: Paired::new(roster),
        agenda: Agenda::default(),
    });
    let reread = reread(watcher, Arc::clone(&relay));
    let lain = rpc::serve(lain, Lain(Arc::clone(&relay)));
    let phone = rpc::serve(Tailnet(phone), Phone(relay));
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

struct Relay {
    paired: Paired,
    agenda: Agenda,
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
                Ok(Value::from(agenda.publish(delta).map_err(refused)?))
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

struct Phone(Arc<Relay>);

/// A phone connection's device, closed when it is revoked.
impl Session for Option<Admitted> {
    async fn closed(&self) {
        match self {
            Some(admitted) => admitted.revoked().await,
            None => std::future::pending().await,
        }
    }
}

impl Handler for Phone {
    type Session = Option<Admitted>;

    fn requires_hello(&self) -> bool {
        true
    }

    async fn hello(&self, params: Vec<Value>) -> Result<(Value, Self::Session), RpcError> {
        let hello = decoded::<Hello>(params, "hello takes [Hello]")?;
        let admitted = self.0.admit(&hello)?;
        let agenda = &self.0.agenda;
        let welcome = reply(&Welcome {
            wire_version: WIRE_VERSION,
            head: agenda.head(),
            epoch: agenda.epoch(),
        })?;
        Ok((welcome, Some(admitted)))
    }

    async fn call(
        &self,
        session: &Self::Session,
        method: &str,
        params: Vec<Value>,
    ) -> Result<Value, RpcError> {
        let agenda = &self.0.agenda;
        let Some(device) = session else {
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
                let answer = decoded::<Answer>(params, "answer.send takes [Answer]")?;
                agenda
                    .answer(&answer.stamped_by(device.name()))
                    .map_err(refused)?;
                Ok(Value::Nil)
            }
            _ => Err(RpcError::UnknownMethod(method.to_string())),
        }
    }
}

fn refused(refusal: Refusal) -> RpcError {
    match refusal {
        Refusal::AlreadySettled(id) => RpcError::AlreadySettled(id),
        Refusal::NotOpen(id) => RpcError::NotOpen(id),
        Refusal::TooLarge { what, bytes } => RpcError::TooLarge {
            what,
            bytes,
            budget: REPLY_BUDGET,
        },
        Refusal::Unencodable => RpcError::BadParams("the relay could not encode it"),
    }
}

impl Relay {
    /// The version is checked first so a phone on another version learns why,
    /// which tells it nothing about the token.
    fn admit(&self, hello: &Hello) -> Result<Admitted, RpcError> {
        if hello.wire_version != WIRE_VERSION {
            return Err(RpcError::WireVersion {
                peer: hello.wire_version,
                ours: WIRE_VERSION,
            });
        }
        self.paired.admit(&hello.token).ok_or(RpcError::BadToken)
    }
}

/// The first param as a wire message. Only the decoded value travels on, so
/// a key or a shape the wire types do not name never reaches the other side.
fn decoded<T: DeserializeOwned>(params: Vec<Value>, shape: &'static str) -> Result<T, RpcError> {
    let raw = params
        .into_iter()
        .next()
        .ok_or(RpcError::BadParams(shape))?;
    let mut bytes = Vec::new();
    rmpv::encode::write_value(&mut bytes, &raw).map_err(|_| RpcError::BadParams(shape))?;
    lain_wire::decode(&bytes).map_err(|_| RpcError::BadParams(shape))
}

/// A wire message as the msgpack value a handler answers with.
fn reply<T: Serialize>(message: &T) -> Result<Value, RpcError> {
    const UNENCODABLE: RpcError = RpcError::BadParams("the relay could not encode its reply");
    let bytes = lain_wire::encode(message).map_err(|_| UNENCODABLE)?;
    rmpv::decode::read_value(&mut bytes.as_slice()).map_err(|_| UNENCODABLE)
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use lain_wire::{
        AgendaItem, AgendaPage, Answer, AnswersPage, Cursor, Delta, Hello, Verdict, WIRE_VERSION,
        Welcome,
    };
    use rmpv::Value;
    use tokio::io::AsyncReadExt;
    use tokio::net::{TcpListener, TcpStream, UnixListener, UnixStream};
    use tokio_util::codec::Framed;

    use super::agenda::{LONG_POLL, MAX_TAIL, REPLY_BUDGET};
    use super::devices::tests::{devices_file, line, rewrite};
    use super::devices::{DevicesFile, Watcher};
    use super::{Config, RELOAD_TICK, StartError};
    use crate::rpc::Codec;
    use crate::rpc::support::{request, response_parts};

    const TOKEN: &str = "a-paired-phone-token";
    const PHONE: &str = "phone";
    const TABLET: &str = "tablet";
    const TABLET_TOKEN: &str = "a-paired-tablet-token";

    fn both_paired() -> String {
        line(PHONE, TOKEN) + &line(TABLET, TABLET_TOKEN)
    }

    /// Long enough for the relay to reread its devices file, in paused time.
    const REREAD: Duration = Duration::from_secs(RELOAD_TICK.as_secs() + 1);

    /// Longer than any reply needs and far shorter than [`LONG_POLL`], in paused time.
    const PROMPTLY: Duration = Duration::from_secs(1);

    struct Peer<C> {
        framed: Framed<C, Codec>,
        next_msgid: u32,
    }

    impl<C: crate::rpc::Wire> Peer<C> {
        fn over(stream: C) -> Self {
            Self {
                framed: Framed::new(stream, Codec::default()),
                next_msgid: 1,
            }
        }

        async fn send(&mut self, method: &str, params: Vec<Value>) -> u32 {
            let msgid = self.next_msgid;
            self.next_msgid += 1;
            self.framed
                .send(request(msgid, method, params))
                .await
                .expect("send a request");
            msgid
        }

        /// The next reply within `wait`, or None when nothing came.
        async fn reply_within(&mut self, wait: Duration) -> Option<(u32, Value, Value)> {
            let frame = tokio::time::timeout(wait, self.framed.next()).await.ok()?;
            Some(response_parts(
                frame
                    .expect("a reply, not a close")
                    .expect("decode a reply"),
            ))
        }

        async fn reply(&mut self) -> (u32, Value, Value) {
            self.reply_within(PROMPTLY)
                .await
                .expect("a reply within a second")
        }

        /// The (error, result) of one call answered at once.
        async fn call(&mut self, method: &str, params: Vec<Value>) -> (Value, Value) {
            let msgid = self.send(method, params).await;
            let (replied, error, result) = self.reply().await;
            assert_eq!(msgid, replied, "the reply to {method}");
            (error, result)
        }

        /// True when the relay closes its end with nothing more to say.
        async fn closes(self) -> bool {
            let mut stream = self.framed.into_inner();
            let mut buffer = [0u8; 64];
            matches!(
                tokio::time::timeout(PROMPTLY, stream.read(&mut buffer)).await,
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
        // Nagle holds a second small request for the relay's delayed ack,
        // a real 40 ms that paused time skips past.
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
            unix: dir.join("relay.sock"),
            listen: listen.to_string(),
            devices_file: devices_file(dir, &both_paired()),
            trace: None,
        }
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
        assert!(!config.unix.exists(), "the socket was bound anyway");
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
        assert!(!config.unix.exists(), "the socket was bound anyway");
    }

    #[test]
    fn a_stale_socket_is_replaced_and_a_live_one_is_left_alone() {
        let dir = tempfile::tempdir().expect("a tempdir");
        let config = config(dir.path(), "127.0.0.1:0");
        drop(std::os::unix::net::UnixListener::bind(&config.unix).expect("a stale socket"));
        assert!(config.unix.exists());
        let bound = super::Bound::open(&config).expect("the stale socket was not replaced");
        drop(bound);

        std::fs::remove_file(&config.unix).expect("clear the socket");
        let live = std::os::unix::net::UnixListener::bind(&config.unix).expect("a live socket");
        let error = super::Bound::open(&config)
            .err()
            .expect("a live socket was taken over");
        assert_eq!(
            format!("{} is in use by a listening process", config.unix.display()),
            error.to_string()
        );
        assert!(
            std::os::unix::net::UnixStream::connect(&config.unix).is_ok(),
            "the live socket was removed"
        );
        drop(live);
    }

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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
            super::confine(&devices_dir, &socket_path).expect("confine");
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
        let seen = std::thread::spawn(move || {
            super::confine(&devices_dir, &socket_dir).expect("confine");
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .start_paused(true)
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
                let mut phone = connect(address).await;
                let phone_admitted = hello_with(&mut phone, TOKEN).await.0 == Value::Nil;

                rewrite(both_paired());
                tokio::time::sleep(REREAD).await;
                let mut tablet = connect(address).await;
                let paired = hello_with(&mut tablet, TABLET_TOKEN).await.0 == Value::Nil;

                rewrite(line(TABLET, TABLET_TOKEN));
                tokio::time::sleep(REREAD).await;
                let closed = phone.closes().await;
                let mut again = connect(address).await;
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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
        let relay = std::sync::Arc::new(super::Relay {
            paired: super::Paired::new(roster),
            agenda: super::Agenda::default(),
        });
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

    #[tokio::test(start_paused = true)]
    async fn a_second_hello_on_an_admitted_connection_is_an_unknown_method() {
        let relay = Relay::start().await;
        let mut phone = relay.phone().await;
        assert_eq!(
            Value::from("unknown method \"hello\""),
            hello_with(&mut phone.peer, TOKEN).await.0
        );
    }

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
    async fn a_reconnecting_phone_gets_only_the_deltas_after_its_cursor() {
        let relay = Relay::start().await;
        let mut lain = relay.lain().await;
        for n in 1..=9 {
            publish(&mut lain, adding(parked(&format!("p{n}")))).await;
        }
        let mut phone = relay.phone().await;
        assert_eq!(vec![8, 9], phone.next(7).await.cursors());
    }

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
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

    #[tokio::test(start_paused = true)]
    async fn a_phone_on_another_wire_version_is_told_both_and_others_still_served() {
        let relay = Relay::start().await;
        let mut newer = relay.stranger().await;
        let (error, _) = newer.call("hello", vec![hello(TOKEN, 2)]).await;
        assert_eq!(
            Value::from("wire version 2 is not served; this relay speaks 1"),
            error
        );
        assert!(
            newer.closes().await,
            "a phone on version 2 stayed connected"
        );

        let mut phone = relay.phone().await;
        let (error, _) = phone.peer.call("ping", vec![]).await;
        assert_eq!(Value::Nil, error);
    }

    #[tokio::test(start_paused = true)]
    async fn a_long_poll_with_nothing_new_answers_empty_after_its_window() {
        let relay = Relay::start().await;
        let mut phone = relay.phone().await;
        let polling = phone
            .peer
            .send("agenda.next", vec![at(0, phone.epoch)])
            .await;
        assert_eq!(
            None,
            phone.peer.reply_within(LONG_POLL - PROMPTLY).await,
            "answered before the window closed"
        );
        let (msgid, error, result) = phone
            .peer
            .reply_within(2 * PROMPTLY)
            .await
            .expect("an answer");
        assert_eq!((polling, Value::Nil), (msgid, error));
        assert_eq!(
            Page {
                reset: false,
                deltas: vec![]
            },
            Page::of(&result)
        );
    }

    #[tokio::test(start_paused = true)]
    async fn dropped_long_polls_free_their_connection_slots() {
        // Lain's Unix side shares the connection code with the phone's, and a
        // Unix close is seen at once; a loopback TCP close under load can land
        // after paused time has already moved on.
        let relay = Relay::start().await;
        for _ in 0..64 {
            let mut lain = relay.lain().await;
            lain.send("answers.next", vec![at(0, None)]).await;
            drop(lain);
        }
        // Paused time moves only once every task is idle, so each close has been read by now.
        tokio::time::sleep(PROMPTLY).await;
        let mut late = relay.lain().await;
        let (error, _) = late.call("ping", vec![]).await;
        assert_eq!(Value::Nil, error, "a dropped long-poll held its slot");
    }
}
