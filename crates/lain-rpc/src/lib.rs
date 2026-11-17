//! The msgpack-RPC envelope: the 4-element request array `[0, msgid, method,
//! params]` and its response `[1, msgid, error, result]` -- the same idiom the
//! Neovim client speaks (`lib/lain/frontend/neovim/rpc_thread.rb` is the
//! client side of it, not reusable as this server).
//!
//! Concurrent by design, as protocol contract rather than optimization: each
//! request on a connection is handled as an independent task, responses carry
//! the request's msgid, and they may complete out of order. The Ruby client
//! demuxes by msgid and depends on exactly that.
//!
//! Two error surfaces, deliberately distinct:
//! - a *decodable but invalid* request (non-array, bad arity, bad msgid,
//!   unknown method) gets an RPC error response -- the frame's id slot echoed
//!   verbatim when it carried one (junk included, see [`Request::parse`]), 0
//!   when it did not;
//! - *undecodable bytes* poison the stream (msgpack is self-delimiting, so a
//!   bad marker means the read position is unrecoverable): that connection
//!   closes, the server survives, other connections are unaffected.
//!
//! msgpack-RPC *notifications* (`[2, method, params]`) flow one way only: the
//! server pushes them through a connection's [`Push`], and one from a client
//! is answered as an invalid request (an arity error echoing the id slot), so
//! there is no silent no-reply path to maintain.

#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr, missing_docs)]

use std::convert::Infallible;
use std::future::Future;
use std::io;
use std::sync::Arc;

use bytes::{BufMut, BytesMut};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use rmpv::Value;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot};
use tokio::task::JoinSet;
use tokio_util::codec::{Decoder, Encoder, Framed};

mod push;
#[cfg(any(test, feature = "test-support"))]
pub mod support;

pub use push::{Closed, Push};
use push::{Outbox, PUSH_BUFFER};

/// Incremental msgpack decode with a frame ceiling. msgpack is
/// self-delimiting, so there is no framing to invent: a [`Scan`] walks the
/// pending value's headers, resuming where the last read left it, and only a
/// value whose whole extent has arrived goes to rmpv.
///
/// Two reasons it does not simply retry `rmpv::decode::read_value` until one
/// succeeds. A retry re-reads the frame from its first byte on every read,
/// quadratic in the frame. And rmpv believes a header's declared length, so 1
/// unfinished str32 grew the daemon by 112 MiB: harmless on a same-user Unix
/// socket, not on a network peer. The scan refuses a frame the moment its
/// headers say it will pass [`MAX_FRAME`].
///
/// rmpv is LENIENT about the reserved marker: 0xc1 decodes as `Value::Nil`
/// (rmpv 1.3.1, decode/value.rs), so lone garbage bytes surface as
/// decodable-but-invalid requests (an error response), not as poison, and the
/// scan agrees. What poisons the stream is a frame past the ceiling or too
/// deep. The depth cap is OURS, far below rmpv's default: at rmpv's own
/// MAX_DEPTH (1024) the recursive decode overflows a 2 MiB worker-thread stack
/// in debug builds BEFORE the limiter fires, aborting the whole daemon (found
/// the hard way by this crate's poison test).
pub(crate) struct Codec {
    ceiling: usize,
    scan: Scan,
    #[cfg(test)]
    scanned: usize,
}

impl Default for Codec {
    fn default() -> Self {
        Self {
            ceiling: MAX_FRAME,
            scan: Scan::default(),
            #[cfg(test)]
            scanned: 0,
        }
    }
}

/// The largest frame a peer may send, inclusive. Ruby's frames are a few
/// hundred bytes; a phone's answer is a few KiB.
const MAX_FRAME: usize = 1 << 20;

/// The largest frame before a hello succeeds: a hello carries a token and a
/// device name, a few hundred bytes, so an unpaired peer holds little.
const HELLO_FRAME: usize = 4 << 10;

/// See the [`Codec`] doc: protects the daemon's stack, not just the protocol.
/// NOTE the unit: rmpv burns ~2 depth units per actual nesting level, so 64
/// units admit ~32 levels of real nesting -- the probe sweep
/// (probes/c1/probe_depth_boundary.rb) measured params nesting 30 accepted /
/// 31 poisoned inside the `[0, id, method, params]` envelope, i.e. 32 total.
/// The scan stops at 64 real levels, looser on purpose, so rmpv's limit stays
/// the one that decides a whole frame.
const MAX_DECODE_DEPTH: usize = 64;

impl Decoder for Codec {
    type Item = Value;
    type Error = io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> io::Result<Option<Value>> {
        if src.is_empty() {
            return Ok(None);
        }
        let Some(extent) = self.scan.extent(src, self.ceiling)? else {
            return Ok(None);
        };
        #[cfg(test)]
        {
            self.scanned += self.scan.headers_read + extent;
        }
        self.scan = Scan::default();
        let frame = src.split_to(extent);
        rmpv::decode::read_value_with_max_depth(&mut &frame[..], MAX_DECODE_DEPTH)
            .map(Some)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
    }
}

#[cfg(test)]
impl Codec {
    /// Every byte this codec has examined: headers by the scan, frames by rmpv.
    pub(crate) fn scanned(&self) -> usize {
        self.scanned + self.scan.headers_read
    }
}

/// Progress through one pending frame: the bytes of it already walked, and
/// how many values each open container still owes, innermost last.
#[derive(Default)]
struct Scan {
    offset: usize,
    owed: Vec<u64>,
    #[cfg(test)]
    headers_read: usize,
}

/// One msgpack header: its own length, the opaque bytes after it (a string's,
/// a binary's, an extension's), and how many values it opens.
struct Header {
    len: usize,
    payload: usize,
    children: u64,
}

impl Scan {
    /// The length of the frame at the front of `src` once all of it has
    /// arrived; an error once its headers prove it passes `ceiling` or nests
    /// past the cap.
    fn extent(&mut self, src: &[u8], ceiling: usize) -> io::Result<Option<usize>> {
        if self.offset == 0 && self.owed.is_empty() {
            self.owed.push(1);
        }
        while !self.owed.is_empty() {
            let Some(header) = Header::read(&src[self.offset..]) else {
                return Ok(None);
            };
            #[cfg(test)]
            {
                self.headers_read += header.len;
            }
            let end = self.offset + header.len + header.payload;
            if end as u64 + header.children > ceiling as u64 {
                return Err(refusal(format!(
                    "a frame passes the {ceiling} byte ceiling"
                )));
            }
            if end > src.len() {
                return Ok(None);
            }
            self.offset = end;
            self.close_one(header.children)?;
        }
        Ok(Some(self.offset))
    }

    fn close_one(&mut self, children: u64) -> io::Result<()> {
        if let Some(owed) = self.owed.last_mut() {
            *owed -= 1;
        }
        if children > 0 {
            if self.owed.len() >= MAX_DECODE_DEPTH {
                return Err(refusal(format!(
                    "a frame nests past {MAX_DECODE_DEPTH} levels"
                )));
            }
            self.owed.push(children);
        }
        while self.owed.last() == Some(&0) {
            self.owed.pop();
        }
        Ok(())
    }
}

fn refusal(message: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

impl Header {
    /// `None` until the whole header has arrived.
    fn read(bytes: &[u8]) -> Option<Self> {
        let marker = *bytes.first()?;
        let sized = |width: usize| -> Option<usize> {
            let field = bytes.get(1..=width)?;
            Some(
                field
                    .iter()
                    .fold(0, |sum, byte| (sum << 8) | usize::from(*byte)),
            )
        };
        let fixed = |len| Some(Self::leaf(len, 0));
        match marker {
            0x00..=0x7f | 0xc0..=0xc3 | 0xe0..=0xff => fixed(1),
            0x80..=0x8f => Some(Self::container(1, 2 * u64::from(marker & 0x0f))),
            0x90..=0x9f => Some(Self::container(1, u64::from(marker & 0x0f))),
            0xa0..=0xbf => Some(Self::leaf(1, usize::from(marker & 0x1f))),
            0xc4 | 0xd9 => Some(Self::leaf(2, sized(1)?)),
            0xc5 | 0xda => Some(Self::leaf(3, sized(2)?)),
            0xc6 | 0xdb => Some(Self::leaf(5, sized(4)?)),
            0xc7 => Some(Self::leaf(3, sized(1)?)),
            0xc8 => Some(Self::leaf(4, sized(2)?)),
            0xc9 => Some(Self::leaf(6, sized(4)?)),
            0xcc | 0xd0 => fixed(2),
            0xcd | 0xd1 => fixed(3),
            0xca | 0xce | 0xd2 => fixed(5),
            0xcb | 0xcf | 0xd3 => fixed(9),
            0xd4..=0xd8 => Some(Self::leaf(2, 1 << (marker - 0xd4))),
            0xdc => Some(Self::container(3, sized(2)? as u64)),
            0xdd => Some(Self::container(5, sized(4)? as u64)),
            0xde => Some(Self::container(3, 2 * sized(2)? as u64)),
            0xdf => Some(Self::container(5, 2 * sized(4)? as u64)),
        }
    }

    fn leaf(len: usize, payload: usize) -> Self {
        Self {
            len,
            payload,
            children: 0,
        }
    }

    fn container(len: usize, children: u64) -> Self {
        Self {
            len,
            payload: 0,
            children,
        }
    }
}

impl Encoder<Value> for Codec {
    type Error = io::Error;

    fn encode(&mut self, item: Value, dst: &mut BytesMut) -> io::Result<()> {
        rmpv::encode::write_value(&mut (&mut *dst).writer(), &item).map_err(io::Error::other)
    }
}

/// How many finished-but-unsent responses one connection may buffer before
/// its handler tasks start awaiting the writer.
const RESPONSE_BUFFER: usize = 64;

/// How long a failed accept waits before retrying. Some accept errors are
/// persistent (EMFILE/ENFILE when the fd table is full): without a pause the
/// error arm is a busy-loop pegging a core while serving nobody.
const ACCEPT_RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(100);

/// A duplex byte stream the codec can frame. Named because the same five
/// bounds are otherwise repeated at every signature below; nothing about the
/// protocol cares which address family delivered the bytes. `Send + 'static`
/// is what lets one connection become an independent task.
pub trait Wire: AsyncRead + AsyncWrite + Send + Unpin + 'static {}

impl<T: AsyncRead + AsyncWrite + Send + Unpin + 'static> Wire for T {}

/// The listener half of the transport seam: something that yields connections,
/// forever. The address is dropped here because `serve` has never used it.
///
/// `accept` must be cancel-safe: `serve`'s future is dropped mid-poll when it
/// loses `main`'s shutdown race, so an impl must not take a connection off the
/// kernel's queue and then await something that may never resolve -- that
/// connection is lost with no error anywhere.
///
/// WHY a local trait rather than `tokio_util::net::Listener`, which is exactly
/// this shape: it lives behind tokio-util's `net` feature, which this crate
/// does not carry (`Cargo.toml` takes `codec` only), and a foreign trait
/// cannot be implemented for a listener type another crate owns, which is
/// what a relay transport is likely to bring. A local trait is implementable
/// for anything.
///
/// `-> impl Future + Send` rather than `async fn`: the accept future is polled
/// inside `serve`'s, which is spawned, so the `Send` bound has to be part of
/// the contract instead of something each caller re-proves. The cost is an
/// implicit `Self: Sync` on any impl that holds `&self` across an await --
/// every listener here is `Sync`, but a listener with interior mutability is
/// rejected at its impl with a `future cannot be sent between threads` error
/// that names neither this bound nor the `&self` capture that needs it.
pub trait Accept {
    /// The byte stream one accepted connection speaks over.
    type Connection: Wire;

    /// The next connection, waiting for one.
    fn accept(&self) -> impl Future<Output = io::Result<Self::Connection>> + Send;

    /// Who is on the other end. Only a Unix socket can say; anything else is unknown.
    fn peer(_connection: &Self::Connection) -> Peer {
        Peer::default()
    }
}

impl Accept for UnixListener {
    type Connection = UnixStream;

    // Fully qualified: the inherent `accept` would otherwise be the one a
    // reader has to prove this is not calling.
    async fn accept(&self) -> io::Result<UnixStream> {
        UnixListener::accept(self)
            .await
            .map(|(stream, _address)| stream)
    }

    fn peer(connection: &UnixStream) -> Peer {
        match connection.peer_cred() {
            Ok(credentials) => Peer {
                uid: Some(credentials.uid()),
                pid: credentials.pid().and_then(|pid| u32::try_from(pid).ok()),
            },
            Err(error) => {
                tracing::warn!(%error, "could not read a peer's credentials");
                Peer::default()
            }
        }
    }
}

/// Who connected: a Unix socket's credentials, or nothing for any other transport.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Peer {
    /// The peer's user id.
    pub uid: Option<u32>,
    /// The peer's process id. A kernel that does not report one leaves it unknown.
    pub pid: Option<u32>,
}

/// What a handler is told about the connection a session belongs to.
#[derive(Clone, Debug)]
pub struct Conn {
    /// The process on the other end.
    pub peer: Peer,
    /// The way to send this connection frames the server chose to originate.
    pub push: Push,
}

/// What one connection carries from its start, or from its hello, to every
/// call it makes: who the peer is, and when the server must close it.
pub trait Session: Send + Sync + 'static {
    /// The session of a connection that needs no hello, or of a default hello.
    fn opened(conn: &Conn) -> Self;

    /// Resolves when the server should close the connection, dropping what is in flight.
    fn closed(&self) -> impl Future<Output = ()> + Send {
        std::future::pending()
    }
}

impl Session for () {
    fn opened(_: &Conn) -> Self {}
}

/// What a server answers beyond `ping`, which the server answers itself so
/// every handler reports the version the binary gave `serve`, which the Ruby
/// client pins.
///
/// `-> impl Future + Send` for the reason [`Accept`] gives: each call runs in
/// a spawned task.
pub trait Handler: Send + Sync + 'static {
    /// What a connection keeps between its calls.
    type Session: Session;

    /// When true, a connection's first request must be a `hello` this
    /// handler answers without an error, within the auth deadline.
    fn requires_hello(&self) -> bool {
        false
    }

    /// The answer to an admitting hello and the session the connection keeps.
    /// By default the opened session, with `hello` answered by [`Handler::call`].
    fn hello(
        &self,
        conn: &Conn,
        params: Vec<Value>,
    ) -> impl Future<Output = Result<(Value, Self::Session), RpcError>> + Send {
        async move {
            let session = Self::Session::opened(conn);
            let result = self.call(&session, "hello", params).await?;
            Ok((result, session))
        }
    }

    /// One request on an admitted connection.
    fn call(
        &self,
        session: &Self::Session,
        method: &str,
        params: Vec<Value>,
    ) -> impl Future<Output = Result<Value, RpcError>> + Send;
}

/// The most connections served at once: Ruby holds 1, each paired phone 1.
const MAX_CONNECTIONS: usize = 64;

/// How long a connection whose handler requires a hello may stay silent.
const AUTH_DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);

/// Accept loop: one task per connection, forever. A failed accept is logged
/// and retried after a pause -- a bad client (or a full fd table) must never
/// take the daemon down.
///
/// Generic, not `dyn`: one monomorphized loop per listener type, so the seam
/// costs no allocation on the per-connection path.
pub async fn serve<A: Accept, H: Handler>(
    listener: A,
    handler: H,
    version: &'static str,
) -> Infallible {
    let handler = Arc::new(handler);
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let lobby = Arc::new(Lobby::default());
    loop {
        match listener.accept().await {
            Ok(stream) => {
                let (push, outbox) = Push::channel();
                let conn = Conn {
                    peer: A::peer(&stream),
                    push,
                };
                admit(stream, conn, outbox, &handler, version, &slots, &lobby);
            }
            Err(error) => {
                tracing::warn!(%error, "accept failed; still listening");
                tokio::time::sleep(ACCEPT_RETRY_DELAY).await;
            }
        }
    }
}

/// A connection whose handler needs no hello takes a cap slot at once, and
/// one past [`MAX_CONNECTIONS`] is closed. One that needs a hello waits in
/// the [`Lobby`] and takes a slot only once admitted, so silent peers cannot
/// fill the cap ahead of a real one.
fn admit<C: Wire, H: Handler>(
    stream: C,
    conn: Conn,
    outbox: Outbox,
    handler: &Arc<H>,
    version: &'static str,
    slots: &Arc<Semaphore>,
    lobby: &Arc<Lobby>,
) {
    if handler.requires_hello() {
        let seat = lobby.seat();
        tokio::spawn(greet_then_serve(
            stream,
            conn,
            outbox,
            Arc::clone(handler),
            version,
            Arc::clone(slots),
            seat,
        ));
        return;
    }
    match Arc::clone(slots).try_acquire_owned() {
        Ok(slot) => {
            let framed = Framed::new(stream, Codec::default());
            let session = H::Session::opened(&conn);
            tokio::spawn(serve_connection(
                framed,
                outbox,
                Arc::clone(handler),
                version,
                session,
                slot,
            ));
        }
        Err(_full) => {
            tracing::warn!(MAX_CONNECTIONS, "at the connection cap; closing a new one");
        }
    }
}

/// The most connections waiting on their hello at once. When it is full the
/// oldest waiter is closed, not the newcomer: a flood of silent peers then
/// cycles through the seats while a real hello, answered at once, gets in.
const LOBBY_SEATS: usize = 8;

#[derive(Default)]
struct Lobby {
    waiting: std::sync::Mutex<Waiting>,
}

#[derive(Default)]
struct Waiting {
    next_id: u64,
    seats: std::collections::VecDeque<(u64, oneshot::Sender<()>)>,
}

/// A connection's place in the [`Lobby`]; dropping it gives the seat back.
struct Seat {
    lobby: Arc<Lobby>,
    id: u64,
    evicted: oneshot::Receiver<()>,
}

impl Lobby {
    fn waiting(&self) -> std::sync::MutexGuard<'_, Waiting> {
        self.waiting
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn seat(self: &Arc<Self>) -> Seat {
        let (evict, evicted) = oneshot::channel();
        let mut waiting = self.waiting();
        if waiting.seats.len() >= LOBBY_SEATS
            && let Some((_, oldest)) = waiting.seats.pop_front()
        {
            let _ = oldest.send(());
        }
        let id = waiting.next_id;
        waiting.next_id += 1;
        waiting.seats.push_back((id, evict));
        Seat {
            lobby: Arc::clone(self),
            id,
            evicted,
        }
    }
}

impl Drop for Seat {
    fn drop(&mut self) {
        let id = self.id;
        self.lobby
            .waiting()
            .seats
            .retain(|(seated, _)| *seated != id);
    }
}

/// A hello-requiring connection: a small frame ceiling and the auth deadline
/// until its hello is admitted, then a cap slot and the full ceiling. A push
/// sent before admission waits in the outbox, which has no writer until the
/// welcome is sent, and is dropped with it when the hello is refused.
async fn greet_then_serve<C: Wire, H: Handler>(
    stream: C,
    conn: Conn,
    outbox: Outbox,
    handler: Arc<H>,
    version: &'static str,
    slots: Arc<Semaphore>,
    mut seat: Seat,
) {
    let mut framed = Framed::new(stream, Codec::default());
    framed.codec_mut().ceiling = HELLO_FRAME;
    let admitted = tokio::select! {
        greeted = tokio::time::timeout(AUTH_DEADLINE, greet(&mut framed, &conn, &*handler, &slots)) => {
            greeted.unwrap_or_else(|_elapsed| {
                tracing::warn!("no hello answered before the auth deadline; closing connection");
                None
            })
        }
        _ = &mut seat.evicted => {
            tracing::warn!("the lobby is full; closing its oldest connection");
            None
        }
    };
    drop(seat);
    let Some((slot, session)) = admitted else {
        return;
    };
    framed.codec_mut().ceiling = MAX_FRAME;
    serve_connection(framed, outbox, handler, version, session, slot).await;
}

type Sink<C> = SplitSink<Framed<C, Codec>, Value>;
type Stream<C> = SplitStream<Framed<C, Codec>>;

/// A response bound for the writer, with the in-flight slot it frees once written.
type Outgoing = (Value, OwnedSemaphorePermit);

/// How a connection's reading ended. Poison, a closed session and an
/// overflowed push queue drop the responses still in flight.
enum Ending {
    Finished,
    Poisoned,
    Closed,
}

/// One connection: a reader that spawns an independent task per request, and
/// a writer that sends responses in whatever order the tasks finish. On EOF
/// the writer sends the responses already finished and the pushes already
/// queued, and the requests still running are dropped: a peer that stopped sending is gone, and a long-poll
/// it left behind must not hold the connection's slot. On poison the writer
/// is aborted too -- the connection dies immediately and takes no response
/// with it, and a session that closes or a push queue that overflows ends it
/// the same way. The slot is held for the connection's life, so dropping it
/// frees the cap.
async fn serve_connection<C: Wire, H: Handler>(
    framed: Framed<C, Codec>,
    outbox: Outbox,
    handler: Arc<H>,
    version: &'static str,
    session: H::Session,
    _slot: OwnedSemaphorePermit,
) {
    let session = Arc::new(session);
    let (sink, mut inbound) = framed.split();
    let (responses, inbox) = mpsc::channel(RESPONSE_BUFFER);
    let mut writer = tokio::spawn(write_frames(sink, inbox, outbox.frames));
    let mut requests = JoinSet::new();
    let ending = tokio::select! {
        ending = read_requests(&mut inbound, &responses, &handler, version, &session, &mut requests) => ending,
        () = session.closed() => Ending::Closed,
        () = overflowed(&outbox.overflow) => Ending::Closed,
    };
    requests.shutdown().await;
    drop(responses);
    if matches!(ending, Ending::Finished) {
        // A peer that stopped sending may never read either, so the writer it
        // leaves blocked must still yield to a close.
        tokio::select! {
            _ = &mut writer => return,
            () = session.closed() => {}
            () = overflowed(&outbox.overflow) => {}
        }
    }
    writer.abort();
    let _ = writer.await;
}

async fn overflowed(overflow: &tokio::sync::Notify) {
    overflow.notified().await;
    tracing::warn!(PUSH_BUFFER, "a connection's push queue is full; closing it");
}

/// The connection's cap slot and session once the first request is a `hello`
/// the handler answered without an error. Anything else is answered, when it
/// can be, and refused.
///
/// The cap slot is taken before the handler sees the hello, so a hello past
/// the cap is refused before any of its side effects run.
async fn greet<C: Wire, H: Handler>(
    framed: &mut Framed<C, Codec>,
    conn: &Conn,
    handler: &H,
    slots: &Arc<Semaphore>,
) -> Option<(OwnedSemaphorePermit, H::Session)> {
    let Ok(frame) = next_frame(framed.next().await) else {
        return None;
    };
    let (response, admitted) = match Request::parse(frame) {
        Ok(request) if request.method == "hello" => {
            let msgid = request.msgid;
            match Arc::clone(slots).try_acquire_owned() {
                Ok(slot) => match handler.hello(conn, request.params).await {
                    Ok((result, session)) => (ok_response(msgid, result), Some((slot, session))),
                    Err(error) => (error_response(msgid, error), None),
                },
                Err(_full) => (error_response(msgid, RpcError::AtCapacity), None),
            }
        }
        Ok(request) => (error_response(request.msgid, RpcError::HelloRequired), None),
        Err((echo_id, error)) => (error_reply(echo_id, &error), None),
    };
    framed.send(response).await.ok().and(admitted)
}

fn next_frame(next: Option<io::Result<Value>>) -> Result<Value, Ending> {
    match next {
        Some(Ok(frame)) => Ok(frame),
        Some(Err(error)) => {
            tracing::warn!(%error, "the stream is poisoned; closing connection");
            Err(Ending::Poisoned)
        }
        None => Err(Ending::Finished),
    }
}

/// Takes an in-flight slot before reading each frame, so a peer with
/// [`RESPONSE_BUFFER`] responses unwritten is not read from until one is.
async fn read_requests<C: Wire, H: Handler>(
    inbound: &mut Stream<C>,
    responses: &mpsc::Sender<Outgoing>,
    handler: &Arc<H>,
    version: &'static str,
    session: &Arc<H::Session>,
    requests: &mut JoinSet<()>,
) -> Ending {
    let in_flight = Arc::new(Semaphore::new(RESPONSE_BUFFER));
    loop {
        let Ok(slot) = Arc::clone(&in_flight).acquire_owned().await else {
            return Ending::Finished;
        };
        while requests.try_join_next().is_some() {}
        match next_frame(inbound.next().await) {
            Ok(frame) => {
                let task = respond_to(
                    frame,
                    Arc::clone(handler),
                    version,
                    Arc::clone(session),
                    responses.clone(),
                    slot,
                );
                requests.spawn(task);
            }
            Err(ending) => return ending,
        }
    }
}

/// The connection's one writer, so a push and a response never interleave.
/// It ends with the responses: a handler may keep a clone of the [`Push`]
/// past the connection, so the push queue never says when to stop.
async fn write_frames<C: Wire>(
    mut sink: Sink<C>,
    mut inbox: mpsc::Receiver<Outgoing>,
    mut pushes: mpsc::Receiver<Value>,
) {
    loop {
        let (frame, _slot) = tokio::select! {
            outgoing = inbox.recv() => match outgoing {
                Some((response, slot)) => (response, Some(slot)),
                None => return write_queued(sink, pushes).await,
            },
            Some(push) = pushes.recv() => (push, None),
        };
        if sink.send(frame).await.is_err() {
            return;
        }
    }
}

/// Writes the pushes already queued when the responses end, and no more: a
/// handler pushing as fast as the peer reads would otherwise keep it open.
async fn write_queued<C: Wire>(mut sink: Sink<C>, mut pushes: mpsc::Receiver<Value>) {
    for _ in 0..pushes.len() {
        let Ok(push) = pushes.try_recv() else {
            return;
        };
        if sink.send(push).await.is_err() {
            return;
        }
    }
}

/// One request, one independent task: the send fails only when the connection
/// is already gone, and then there is nobody left to tell.
async fn respond_to<H: Handler>(
    frame: Value,
    handler: Arc<H>,
    version: &'static str,
    session: Arc<H::Session>,
    responses: mpsc::Sender<Outgoing>,
    slot: OwnedSemaphorePermit,
) {
    let response = match Request::parse(frame) {
        Ok(request) => request.dispatch(&*handler, version, &session).await,
        Err((echo_id, error)) => error_reply(echo_id, &error),
    };
    let _ = responses.send((response, slot)).await;
}

struct Request {
    msgid: u32,
    method: String,
    params: Vec<Value>,
}

impl Request {
    /// `[0, msgid, method, params]`, msgid a 32-bit unsigned integer (the
    /// msgpack-RPC contract our client demuxes by). A parse failure carries
    /// the frame's id SLOT to echo -- junk ids included, see [`echo_of`] --
    /// and 0 only when the frame carried no id slot at all. WHY not collapse
    /// junk to 0: msgid 0 is a LEGAL msgid, so an error reply claiming 0
    /// would collide with a legitimate in-flight msgid-0 request and
    /// misdeliver (probe_msgid_shapes' collision demo).
    fn parse(frame: Value) -> Result<Self, (Value, RpcError)> {
        let Value::Array(elements) = frame else {
            return Err((Value::from(0), RpcError::NotArray));
        };
        let echo = elements.get(1).map_or_else(|| Value::from(0), echo_of);
        let [kind, msgid, method, params]: [Value; 4] = elements
            .try_into()
            .map_err(|elements: Vec<Value>| (echo.clone(), RpcError::Arity(elements.len())))?;
        if kind.as_u64() != Some(0) {
            return Err((echo, RpcError::Kind(kind)));
        }
        let Some(msgid) = msgid.as_u64().and_then(|id| u32::try_from(id).ok()) else {
            return Err((echo, RpcError::Msgid(msgid)));
        };
        let Some(method) = method.as_str().map(str::to_string) else {
            return Err((echo, RpcError::MethodNotString));
        };
        let Value::Array(params) = params else {
            return Err((echo, RpcError::ParamsNotArray));
        };
        Ok(Self {
            msgid,
            method,
            params,
        })
    }

    async fn dispatch<H: Handler>(
        self,
        handler: &H,
        version: &'static str,
        session: &H::Session,
    ) -> Value {
        if self.method == "ping" {
            return ok_response(self.msgid, ping_result(version));
        }
        match handler.call(session, &self.method, self.params).await {
            Ok(result) => ok_response(self.msgid, result),
            Err(error) => error_response(self.msgid, error),
        }
    }
}

/// The most bytes of a client's value a reply carries back, in its id slot or its error text.
const ECHO_LIMIT: usize = 64;

/// An id slot echoes when it is a scalar of at most [`ECHO_LIMIT`] bytes, and
/// is Nil otherwise: a reply must not cost a peer's frame twice, and Nil can
/// never collide with a u32 msgid.
fn echo_of(id: &Value) -> Value {
    let small = match id {
        Value::String(text) => text.as_bytes().len() <= ECHO_LIMIT,
        Value::Binary(bytes) => bytes.len() <= ECHO_LIMIT,
        Value::Array(_) | Value::Map(_) | Value::Ext(..) => false,
        Value::Nil | Value::Boolean(_) | Value::Integer(_) | Value::F32(_) | Value::F64(_) => true,
    };
    if small { id.clone() } else { Value::Nil }
}

/// `value` formatted, cut to [`ECHO_LIMIT`] characters. Formatting stops at
/// the cut, so a huge value is never rendered whole.
fn clip(value: &impl std::fmt::Display) -> String {
    struct Bounded(String, usize);

    impl std::fmt::Write for Bounded {
        fn write_str(&mut self, text: &str) -> std::fmt::Result {
            for character in text.chars() {
                if self.1 == ECHO_LIMIT {
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

fn ok_response(msgid: u32, result: Value) -> Value {
    Value::Array(vec![Value::from(1), Value::from(msgid), Value::Nil, result])
}

fn error_response(msgid: u32, message: impl std::fmt::Display) -> Value {
    error_reply(Value::from(msgid), message)
}

/// The id slot of an error reply is any `Value`: parse errors echo whatever
/// rode the frame's id slot (see [`Request::parse`]).
fn error_reply(id: Value, message: impl std::fmt::Display) -> Value {
    Value::Array(vec![
        Value::from(1),
        id,
        Value::from(message.to_string()),
        Value::Nil,
    ])
}

fn ping_result(version: &str) -> Value {
    Value::Map(vec![
        (Value::from("version"), Value::from(version)),
        (Value::from("pid"), Value::from(std::process::id())),
    ])
}

/// What a handler or the framing answers a request with instead of a result;
/// its text is the error slot a client reads.
#[derive(Debug, Error)]
pub enum RpcError {
    /// The frame was not an array.
    #[error("request is not an array")]
    NotArray,
    /// The frame had the wrong number of elements.
    #[error("request has {0} elements, expected 4")]
    Arity(usize),
    /// The frame's type slot was not 0.
    #[error("request type must be 0, got {}", clip(.0))]
    Kind(Value),
    /// The msgid was not a 32-bit unsigned integer.
    #[error("request msgid must be a 32-bit unsigned integer, got {}", clip(.0))]
    Msgid(Value),
    /// The method slot was not a string.
    #[error("request method must be a string")]
    MethodNotString,
    /// The params slot was not an array.
    #[error("request params must be an array")]
    ParamsNotArray,
    /// No such method.
    #[error("unknown method {:?}", clip(.0))]
    UnknownMethod(String),
    /// A call came before the connection's hello.
    #[error("the first request must be hello")]
    HelloRequired,
    /// The server had no room for another connection.
    #[error("the server is at its connection cap")]
    AtCapacity,
    /// A handler's own refusal. The code names the reason for the handler's logs and tests;
    /// the client reads only the message.
    #[error("{message}")]
    Refused {
        /// A stable name for the reason.
        code: &'static str,
        /// The text the client sees.
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    use bytes::{BufMut, BytesMut};
    use rmpv::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::sync::watch;
    use tokio_util::codec::Decoder;

    use super::support::{
        RESPONSE_WAIT, TestClient, VERSION, field, raw_response_parts, request, response_parts,
        start_flaky_server, start_server, start_server_with, start_tcp_server,
    };
    use super::{
        ACCEPT_RETRY_DELAY, Codec, Conn, Handler, MAX_CONNECTIONS, Peer, Push, RESPONSE_BUFFER,
        RpcError, Session, Wire,
    };

    /// The whole protocol surface a transport has to carry, as one value: a
    /// ping's version and the error slot of a refused method. Two transports
    /// agreeing on this pair is the differential the seam is judged by.
    async fn ping_and_refusal<C: Wire>(client: &mut TestClient<C>) -> (Value, Value) {
        let (msgid, error, result) = client.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected ping error: {error:?}");
        let version = field(&result, "version");

        let (msgid, error, _) = client.call(2, "exec", vec![]).await;
        assert_eq!(2, msgid);
        (version, error)
    }

    fn millis(ms: u64) -> Vec<Value> {
        vec![Value::from(ms)]
    }

    const CEILING: usize = 1 << 20;

    #[test]
    fn the_codec_never_buffers_an_unfinished_frame_past_the_ceiling() {
        let declared: u32 = 96 << 20;
        let mut buffer = BytesMut::new();
        buffer.put_u8(0xdb);
        buffer.put_u32(declared);
        let mut codec = Codec::default();
        let chunk = [b'x'; 4096];
        let mut fed = 0usize;
        let refused = loop {
            assert!(
                buffer.len() <= CEILING,
                "the codec holds {} bytes of one frame",
                buffer.len()
            );
            if codec.decode(&mut buffer).is_err() {
                break true;
            }
            if fed >= declared as usize {
                break false;
            }
            buffer.extend_from_slice(&chunk);
            fed += chunk.len();
        };
        assert!(refused, "the codec accepted a 96 MiB frame");
    }

    #[test]
    fn a_frame_arriving_in_small_reads_is_scanned_linearly() {
        let payload = "x".repeat(CEILING - 64);
        let frame = request(1, "echo", vec![Value::from(payload.as_str())]);
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &frame).expect("encode the frame");
        assert!(bytes.len() <= CEILING);

        let mut codec = Codec::default();
        let mut buffer = BytesMut::new();
        let mut decoded = None;
        for chunk in bytes.chunks(4096) {
            buffer.extend_from_slice(chunk);
            decoded = codec
                .decode(&mut buffer)
                .expect("a frame under the ceiling");
        }
        assert_eq!(Some(frame), decoded);
        assert!(buffer.is_empty());
        assert!(
            codec.scanned() < 2 * CEILING,
            "scanned {} bytes to decode a {} byte frame",
            codec.scanned(),
            bytes.len()
        );
    }

    #[test]
    fn a_frame_of_many_small_values_is_scanned_linearly() {
        let values = vec![Value::from(1); 256 << 10];
        let frame = request(1, "echo", vec![Value::Array(values)]);
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &frame).expect("encode the frame");

        let mut codec = Codec::default();
        let mut buffer = BytesMut::new();
        let mut decoded = None;
        for chunk in bytes.chunks(4096) {
            buffer.extend_from_slice(chunk);
            decoded = codec
                .decode(&mut buffer)
                .expect("a frame under the ceiling");
        }
        assert_eq!(Some(frame), decoded);
        assert!(
            codec.scanned() <= 2 * bytes.len() + 4096,
            "scanned {} bytes to decode a {} byte frame",
            codec.scanned(),
            bytes.len()
        );
    }

    fn str32_frame(len: usize) -> BytesMut {
        let payload = len - 5;
        let mut frame = BytesMut::new();
        frame.put_u8(0xdb);
        frame.put_u32(u32::try_from(payload).expect("a str32 length"));
        frame.put_bytes(b'x', payload);
        frame
    }

    #[test]
    fn a_frame_of_exactly_the_ceiling_decodes_and_one_byte_more_is_refused() {
        let mut exact = str32_frame(CEILING);
        assert!(matches!(
            Codec::default().decode(&mut exact),
            Ok(Some(Value::String(_)))
        ));
        let mut over = str32_frame(CEILING + 1);
        assert!(Codec::default().decode(&mut over).is_err());
    }

    #[test]
    fn an_array_header_declaring_more_values_than_the_ceiling_holds_is_refused() {
        let mut header = BytesMut::new();
        header.put_u8(0xdd);
        header.put_u32(u32::MAX);
        assert!(Codec::default().decode(&mut header).is_err());
    }

    /// Claims ping too, to show it cannot take ping from the server.
    struct Echo;

    impl Handler for Echo {
        type Session = ();

        async fn call(&self, _: &(), method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
            match method {
                "echo" => Ok(Value::Array(params)),
                "ping" => Ok(Value::from("the handler's ping")),
                unknown => Err(RpcError::UnknownMethod(unknown.to_string())),
            }
        }
    }

    #[tokio::test]
    async fn a_handler_answers_its_methods_beside_the_servers_ping() {
        let (_dir, path) = start_server_with(Echo).await;
        let mut client = TestClient::connect(&path).await;

        let (_, error, result) = client.call(1, "ping", vec![]).await;
        assert!(error.is_nil(), "unexpected ping error: {error:?}");
        assert_eq!(Value::from(VERSION), field(&result, "version"));

        let params = vec![Value::from(7), Value::from("seven")];
        let (msgid, error, result) = client.call(2, "echo", params.clone()).await;
        assert_eq!(
            (2, Value::Nil, Value::Array(params)),
            (msgid, error, result)
        );

        let (msgid, error, result) = client.call(3, "nope", vec![]).await;
        assert_eq!(
            (3, Value::from("unknown method \"nope\""), Value::Nil),
            (msgid, error, result)
        );
    }

    /// Accepts a hello whose first param is "letmein", and never answers one
    /// that says "slow". Echoes once admitted.
    struct Gatekeeper;

    impl Handler for Gatekeeper {
        type Session = ();

        fn requires_hello(&self) -> bool {
            true
        }

        async fn call(&self, _: &(), method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
            match (method, params.first().and_then(Value::as_str)) {
                ("hello", Some("letmein")) => Ok(Value::from("welcome")),
                ("hello", Some("slow")) => std::future::pending().await,
                ("echo", _) => Ok(Value::Array(params)),
                _ => Err(RpcError::UnknownMethod(method.to_string())),
            }
        }
    }

    type Live = Arc<std::sync::Mutex<std::collections::HashMap<String, watch::Sender<()>>>>;

    /// Mints a session named by the hello's first param. `whoami` answers that
    /// name, and dropping a name's sender is what closes its connections.
    struct Badges(Live);

    struct Badge {
        name: String,
        live: watch::Receiver<()>,
    }

    impl Session for Option<Badge> {
        fn opened(_: &Conn) -> Self {
            None
        }

        async fn closed(&self) {
            match self {
                Some(badge) => {
                    let mut live = badge.live.clone();
                    while live.changed().await.is_ok() {}
                }
                None => std::future::pending().await,
            }
        }
    }

    impl Handler for Badges {
        type Session = Option<Badge>;

        fn requires_hello(&self) -> bool {
            true
        }

        async fn hello(
            &self,
            _: &Conn,
            params: Vec<Value>,
        ) -> Result<(Value, Self::Session), RpcError> {
            let name = params
                .first()
                .and_then(Value::as_str)
                .ok_or(RpcError::Refused {
                    code: "bad_token",
                    message: "the hello was refused".to_string(),
                })?
                .to_string();
            let mut live = self.0.lock().expect("the live map");
            let sender = live
                .entry(name.clone())
                .or_insert_with(|| watch::channel(()).0);
            let badge = Badge {
                name,
                live: sender.subscribe(),
            };
            Ok((Value::from("welcome"), Some(badge)))
        }

        async fn call(
            &self,
            session: &Self::Session,
            method: &str,
            _params: Vec<Value>,
        ) -> Result<Value, RpcError> {
            match (method, session) {
                ("whoami", Some(badge)) => Ok(Value::from(badge.name.as_str())),
                ("big", Some(_)) => Ok(Value::from("x".repeat(64 << 10))),
                _ => Err(RpcError::UnknownMethod(method.to_string())),
            }
        }
    }

    #[tokio::test(start_paused = true)]
    async fn each_connection_keeps_its_hello_session_and_closes_alone() {
        let live = Live::default();
        let (_dir, path) = start_server_with(Badges(Arc::clone(&live))).await;
        let mut a = TestClient::connect(&path).await;
        let mut b = TestClient::connect(&path).await;
        for (client, name) in [(&mut a, "a"), (&mut b, "b")] {
            let (_, error, _) = client.call(1, "hello", vec![Value::from(name)]).await;
            assert_eq!(Value::Nil, error, "the hello as {name}");
        }
        let (_, _, a_is) = a.call(2, "whoami", vec![]).await;
        let (_, _, b_is) = b.call(2, "whoami", vec![]).await;
        assert_eq!((Value::from("a"), Value::from("b")), (a_is, b_is));

        live.lock().expect("the live map").remove("a");
        assert!(closes(a).await, "a closed session left its connection open");
        let (_, error, b_is) = b.call(4, "whoami", vec![]).await;
        assert_eq!(
            (Value::Nil, Value::from("b")),
            (error, b_is),
            "closing a took b with it"
        );
    }

    /// The replies a client had not read when its session closed are dropped,
    /// not written: a revoked peer learns nothing more.
    #[tokio::test(start_paused = true)]
    async fn a_closed_session_drops_the_replies_it_had_not_written() {
        let live = Live::default();
        let (_dir, path) = start_server_with(Badges(Arc::clone(&live))).await;
        let mut a = TestClient::connect(&path).await;
        let (_, error, _) = a.call(1, "hello", vec![Value::from("a")]).await;
        assert_eq!(Value::Nil, error);
        let asked = u32::try_from(RESPONSE_BUFFER).expect("a count");
        for msgid in 2..2 + asked {
            a.send(request(msgid, "big", vec![])).await;
        }
        // Paused time moves only once every task is idle, so by now each reply
        // is written or waiting on the socket the client is not reading.
        tokio::time::sleep(Duration::from_secs(1)).await;
        live.lock().expect("the live map").remove("a");
        tokio::time::sleep(Duration::from_secs(1)).await;

        let mut bytes = Vec::new();
        let mut stream = a.into_inner();
        tokio::time::timeout(RESPONSE_WAIT, stream.read_to_end(&mut bytes))
            .await
            .expect("the connection closed")
            .expect("read until the close");
        let mut rest = bytes.as_slice();
        let mut replies = 0;
        while rmpv::decode::read_value(&mut rest).is_ok() {
            replies += 1;
        }
        assert!(
            replies < asked,
            "all {replies} replies were written after the session closed"
        );
    }

    async fn closes<C: Wire>(client: TestClient<C>) -> bool {
        let mut stream = client.into_inner();
        let mut buffer = [0u8; 16];
        matches!(
            tokio::time::timeout(RESPONSE_WAIT, stream.read(&mut buffer)).await,
            Ok(Ok(0) | Err(_))
        )
    }

    /// A raw client whose checks never wait, so a check cannot move a paused clock.
    struct Probe(std::os::unix::net::UnixStream);

    impl Probe {
        fn connect(path: &std::path::Path) -> Self {
            let stream = std::os::unix::net::UnixStream::connect(path).expect("connect");
            stream.set_nonblocking(true).expect("nonblocking");
            Self(stream)
        }

        fn from_client(client: TestClient<tokio::net::UnixStream>) -> Self {
            Self(client.into_inner().into_std().expect("a std stream"))
        }

        fn send(&mut self, frame: &Value) {
            let mut bytes = Vec::new();
            rmpv::encode::write_value(&mut bytes, frame).expect("encode the frame");
            self.send_raw(&bytes);
        }

        fn send_raw(&mut self, bytes: &[u8]) {
            std::io::Write::write_all(&mut self.0, bytes).expect("send raw bytes");
        }

        /// Drains any replies; true once the server has closed its end.
        fn is_closed(&mut self) -> bool {
            let mut buffer = [0u8; 4096];
            loop {
                match std::io::Read::read(&mut self.0, &mut buffer) {
                    Ok(0) => return true,
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return false,
                    Err(_) => return true,
                }
            }
        }

        async fn closes_at_the_deadline_not_before(&mut self) {
            tokio::time::sleep(Duration::from_millis(4900)).await;
            assert!(!self.is_closed(), "closed before the 5 s deadline");
            tokio::time::sleep(Duration::from_millis(200)).await;
            assert!(self.is_closed(), "still open after the 5 s deadline");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_connection_with_no_hello_closes_at_the_five_second_deadline() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        Probe::connect(&path)
            .closes_at_the_deadline_not_before()
            .await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_hello_the_handler_never_answers_still_closes_at_the_deadline() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut probe = Probe::connect(&path);
        probe.send(&request(1, "hello", vec![Value::from("slow")]));
        probe.closes_at_the_deadline_not_before().await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_hello_in_time_opens_the_connection_and_the_full_ceiling() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "hello", vec![Value::from("letmein")]).await;
        assert_eq!((Value::Nil, Value::from("welcome")), (error, result));

        tokio::time::sleep(Duration::from_secs(10)).await;
        let (msgid, error, _) = client.call(2, "ping", vec![]).await;
        assert_eq!((2, Value::Nil), (msgid, error));
        let large = vec![Value::from("x".repeat(64 << 10))];
        let (_, error, result) = client.call(3, "echo", large.clone()).await;
        assert_eq!((Value::Nil, Value::Array(large)), (error, result));
    }

    #[tokio::test(start_paused = true)]
    async fn a_frame_before_hello_has_a_small_ceiling() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut probe = Probe::connect(&path);
        let token = Value::from("x".repeat(64 << 10));
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &request(1, "hello", vec![token]))
            .expect("encode the hello");
        probe.send_raw(&bytes[..bytes.len() - 1]);
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(
            probe.is_closed(),
            "a 64 KiB frame before hello was buffered"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_first_frame_that_is_not_an_accepted_hello_is_refused_and_closed() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut early = TestClient::connect(&path).await;
        let (msgid, error, _) = early.call(1, "ping", vec![]).await;
        assert_eq!(
            (1, Value::from("the first request must be hello")),
            (msgid, error)
        );
        let mut early = Probe::from_client(early);

        let mut wrong = TestClient::connect(&path).await;
        let (_, error, _) = wrong.call(1, "hello", vec![Value::from("guess")]).await;
        assert!(!error.is_nil(), "a refused hello answered without an error");
        let mut wrong = Probe::from_client(wrong);

        tokio::time::sleep(Duration::from_secs(1)).await;
        assert!(
            early.is_closed(),
            "a ping before hello left the connection open"
        );
        assert!(
            wrong.is_closed(),
            "a refused hello left the connection open"
        );
    }

    /// Pings over a raw stream, so a closed connection reads as false rather than a panic.
    async fn answers_ping(path: &std::path::Path) -> bool {
        let Ok(mut stream) = tokio::net::UnixStream::connect(path).await else {
            return false;
        };
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &request(1, "ping", vec![])).expect("encode");
        if stream.write_all(&bytes).await.is_err() {
            return false;
        }
        let mut buffer = [0u8; 64];
        matches!(
            tokio::time::timeout(RESPONSE_WAIT, stream.read(&mut buffer)).await,
            Ok(Ok(read)) if read > 0
        )
    }

    #[tokio::test]
    async fn a_connection_past_the_cap_is_closed_until_a_slot_frees() {
        let (_dir, path) = start_server().await;
        let mut held = Vec::new();
        for msgid in 0..MAX_CONNECTIONS {
            let mut client = TestClient::connect(&path).await;
            let msgid = u32::try_from(msgid).expect("a msgid");
            let (_, error, _) = client.call(msgid, "ping", vec![]).await;
            assert!(
                error.is_nil(),
                "connection {msgid} under the cap was refused"
            );
            held.push(client);
        }
        let over = TestClient::connect(&path).await;
        assert!(closes(over).await, "a connection past the cap was served");

        drop(held.pop());
        let freed = tokio::time::timeout(RESPONSE_WAIT, async {
            while !answers_ping(&path).await {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(freed.is_ok(), "a closed connection never freed its slot");
    }

    #[tokio::test]
    async fn a_huge_id_slot_or_method_is_neither_echoed_nor_quoted_whole() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let huge_id = Value::from("x".repeat(CEILING - 64));
        client
            .send(Value::Array(vec![
                Value::from(0),
                huge_id,
                Value::from("ping"),
                Value::Array(vec![]),
            ]))
            .await;
        let reply = client.recv().await;
        let mut bytes = Vec::new();
        rmpv::encode::write_value(&mut bytes, &reply).expect("encode the reply");
        assert!(
            bytes.len() <= 256,
            "a {} byte reply to a huge id",
            bytes.len()
        );
        let (id, error, _) = raw_response_parts(reply);
        assert_eq!(Value::Nil, id, "a huge id slot is not echoed");
        assert!(!error.is_nil());

        let (_, error, _) = client.call(1, &"m".repeat(4096), vec![]).await;
        let message = error.as_str().expect("error is a string");
        assert!(
            message.len() <= 128,
            "a {} byte error for a long method",
            message.len()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_flood_of_silent_connections_cannot_lock_out_a_hello() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut silent: Vec<Probe> = (0..MAX_CONNECTIONS + 8)
            .map(|_| Probe::connect(&path))
            .collect();
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "hello", vec![Value::from("letmein")]).await;
        assert_eq!((Value::Nil, Value::from("welcome")), (error, result));
        let (msgid, error, _) = client.call(2, "ping", vec![]).await;
        assert_eq!((2, Value::Nil), (msgid, error));

        tokio::time::sleep(Duration::from_secs(1)).await;
        let newest = silent.last_mut().expect("a silent connection");
        assert!(
            !newest.is_closed(),
            "the newest silent connection was closed"
        );
        assert!(
            silent[0].is_closed(),
            "the oldest silent connection kept its seat"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_hello_past_the_connection_cap_gets_an_error_not_a_welcome() {
        let (_dir, path) = start_server_with(Gatekeeper).await;
        let mut admitted = Vec::new();
        for _ in 0..MAX_CONNECTIONS {
            let mut client = TestClient::connect(&path).await;
            let (_, error, result) = client.call(1, "hello", vec![Value::from("letmein")]).await;
            assert_eq!((Value::Nil, Value::from("welcome")), (error, result));
            admitted.push(client);
        }
        let mut over = TestClient::connect(&path).await;
        let (_, error, result) = over.call(1, "hello", vec![Value::from("letmein")]).await;
        assert_eq!(
            (
                Value::from("the server is at its connection cap"),
                Value::Nil
            ),
            (error, result)
        );
    }

    /// Never answers, so every request it is given stays in flight.
    struct Hang {
        entered: Arc<AtomicUsize>,
    }

    impl Handler for Hang {
        type Session = ();

        async fn call(
            &self,
            _: &(),
            _method: &str,
            _params: Vec<Value>,
        ) -> Result<Value, RpcError> {
            self.entered.fetch_add(1, Ordering::SeqCst);
            std::future::pending().await
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_connection_holds_at_most_a_buffer_of_unanswered_requests() {
        let entered = Arc::new(AtomicUsize::new(0));
        let hang = Hang {
            entered: Arc::clone(&entered),
        };
        let (_dir, path) = start_server_with(hang).await;
        let stream = tokio::net::UnixStream::connect(&path)
            .await
            .expect("connect");
        let (_replies, mut requests) = stream.into_split();
        let mut flood = Vec::new();
        for msgid in 0..50_000 {
            rmpv::encode::write_value(&mut flood, &request(msgid, "hang", vec![]))
                .expect("encode a request");
        }
        let sender = tokio::spawn(async move { requests.write_all(&flood).await });

        let filled = tokio::time::timeout(RESPONSE_WAIT, async {
            while entered.load(Ordering::SeqCst) < RESPONSE_BUFFER {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await;
        assert!(filled.is_ok(), "the buffer of requests never filled");
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert_eq!(RESPONSE_BUFFER, entered.load(Ordering::SeqCst));
        assert!(
            !sender.is_finished(),
            "the server kept reading a peer with a full buffer of unanswered requests"
        );
    }

    #[tokio::test]
    async fn the_unix_path_pings_and_refuses_unknown_methods() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        assert_eq!(
            (Value::from(VERSION), Value::from("unknown method \"exec\"")),
            ping_and_refusal(&mut client).await
        );
    }

    #[tokio::test]
    async fn exec_is_refused_as_an_unknown_method_and_the_daemon_stays_up() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let argv = Value::Array(vec![Value::from("true")]);
        let params = vec![Value::Map(vec![(Value::from("argv"), argv)])];
        let (msgid, error, result) = client.call(4, "exec", params).await;
        assert_eq!(4, msgid);
        let message = error.as_str().expect("error is a string").to_string();
        assert!(
            message.contains("exec"),
            "error names the method: {message}"
        );
        assert!(result.is_nil());

        let (msgid, error, _) = client.call(5, "ping", vec![]).await;
        assert_eq!(5, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
    }

    #[tokio::test]
    async fn a_listener_of_another_type_serves_the_same_protocol() {
        let (_dir, path) = start_server().await;
        let mut unix = TestClient::connect(&path).await;
        let mut tcp = TestClient::connect_tcp(start_tcp_server().await).await;
        // Same `serve`, same `serve_connection`: nothing was duplicated to
        // make TCP work, so the two answers must be indistinguishable.
        assert_eq!(
            ping_and_refusal(&mut unix).await,
            ping_and_refusal(&mut tcp).await
        );
    }

    #[tokio::test]
    async fn a_transient_accept_error_does_not_kill_the_daemon() {
        let (_dir, path, errored) = start_flaky_server().await;

        // The connection sits in the backlog across the retry delay, so this
        // client is served by the accept AFTER the synthetic failure.
        let dialed = Instant::now();
        let mut client = TestClient::connect(&path).await;
        let (msgid, error, _) = client.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert!(
            errored.load(Ordering::SeqCst),
            "the error arm never ran, so this exercised the happy path only"
        );
        // Not a timing race: the backlogged connection cannot be served until
        // the sleep completes, so a busy-retry (no pause, a core pegged on a
        // persistent EMFILE) answers measurably sooner and fails here.
        assert!(
            dialed.elapsed() >= ACCEPT_RETRY_DELAY,
            "the retry skipped its delay: answered in {:?}",
            dialed.elapsed()
        );

        // Still accepting: the error arm retried rather than left the loop.
        let mut later = TestClient::connect(&path).await;
        let (msgid, error, _) = later.call(2, "ping", vec![]).await;
        assert_eq!(2, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
    }

    #[tokio::test]
    async fn ping_answers_version_and_pid() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let (msgid, error, result) = client.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(Value::from(VERSION), field(&result, "version"));
        // The server runs in-process for tests, so its pid is ours.
        assert_eq!(Value::from(std::process::id()), field(&result, "pid"));
    }

    #[tokio::test]
    async fn in_flight_requests_complete_out_of_order_matched_by_msgid() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let sent = Instant::now();
        client.send(request(1, "sleep", millis(300))).await;
        client.send(request(2, "ping", vec![])).await;
        let (first_msgid, first_error, first_result) = response_parts(client.recv().await);
        let (second_msgid, second_error, second_result) = response_parts(client.recv().await);
        assert!(first_error.is_nil(), "unexpected error: {first_error:?}");
        assert!(second_error.is_nil(), "unexpected error: {second_error:?}");
        assert_eq!(2, first_msgid, "the ping answers first");
        assert_eq!(Value::from(VERSION), field(&first_result, "version"));
        assert_eq!(1, second_msgid, "the sleep answers second, msgid intact");
        assert!(second_result.is_nil());
        // Without this a sleep that ignored its duration could still lose the race to ping.
        assert!(
            sent.elapsed() >= Duration::from_millis(300),
            "the sleep answered in {:?}, before its 300ms",
            sent.elapsed()
        );
    }

    #[tokio::test]
    async fn decodable_invalid_requests_get_error_responses() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;

        // Non-array: no msgid to echo, so the error response carries 0.
        client.send(Value::from("not a request")).await;
        let (msgid, error, result) = response_parts(client.recv().await);
        assert_eq!(0, msgid);
        assert!(!error.is_nil(), "expected an error response");
        assert!(result.is_nil());

        // Bad arity, but the frame carries a salvageable msgid: echo it.
        client
            .send(Value::Array(vec![
                Value::from(0),
                Value::from(9),
                Value::from("ping"),
            ]))
            .await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(9, msgid, "recoverable msgid is echoed");
        assert!(!error.is_nil());

        // Unknown method: a full well-formed frame, so the msgid echoes.
        client.send(request(7, "nope", vec![])).await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(7, msgid);
        let message = error.as_str().expect("error is a string").to_string();
        assert!(
            message.contains("nope"),
            "error names the method: {message}"
        );

        // The reserved marker 0xc1: rmpv leniently decodes it as nil, so it
        // is a decodable-but-invalid request (error response, msgid 0), NOT
        // poison. Pinned so an rmpv strictness change shows up here.
        client.send_raw(&[0xc1]).await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(0, msgid);
        assert!(!error.is_nil());

        // The connection survived all four.
        let (msgid, error, _) = client.call(3, "ping", vec![]).await;
        assert_eq!(3, msgid);
        assert!(error.is_nil());
    }

    #[tokio::test]
    async fn non_u32_msgids_get_error_replies_not_silent_remaps() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;

        // Baseline: u32::MAX is a legal msgid and echoes intact.
        let (msgid, error, _) = client.call(u32::MAX, "ping", vec![]).await;
        assert_eq!(u32::MAX, msgid);
        assert!(error.is_nil());

        // msgpack-RPC msgid is a 32-bit unsigned int; anything else in the id
        // slot is a decodable-but-invalid request: an error reply echoing the
        // offending id verbatim, never a dispatched success claiming msgid 0
        // (probe_msgid_shapes' silent-remap defect).
        let bad_ids = [
            Value::from(1u64 << 40),
            Value::from(-1),
            Value::from("abc"),
            Value::from(true),
            Value::Nil,
            Value::from(1.5),
        ];
        for bad in bad_ids {
            client
                .send(Value::Array(vec![
                    Value::from(0),
                    bad.clone(),
                    Value::from("ping"),
                    Value::Array(vec![]),
                ]))
                .await;
            let (echoed, error, result) = raw_response_parts(client.recv().await);
            assert_eq!(bad, echoed, "the offending id echoes verbatim");
            assert!(!error.is_nil(), "id {bad:?} draws an error, not a success");
            assert!(result.is_nil());
        }

        // The collision probe_msgid_shapes demonstrated: a legitimate msgid-0
        // request in flight beside a huge-msgid frame. The msgid-0 success must
        // stay unambiguous -- exactly one response claims id 0.
        let huge_id = Value::from(1u64 << 40);
        client
            .send(Value::Array(vec![
                Value::from(0),
                huge_id.clone(),
                Value::from("sleep"),
                Value::Array(millis(50)),
            ]))
            .await;
        client.send(request(0, "sleep", millis(50))).await;
        let first = raw_response_parts(client.recv().await);
        let second = raw_response_parts(client.recv().await);
        let (huge, zero) = if first.0 == huge_id {
            (first, second)
        } else {
            (second, first)
        };
        assert_eq!(huge_id, huge.0, "no both-claim-msgid-0 collision");
        assert!(
            !huge.1.is_nil(),
            "the huge-msgid frame errors instead of dispatching"
        );
        assert_eq!(Value::from(0), zero.0);
        assert!(
            zero.1.is_nil(),
            "the legitimate msgid-0 sleep succeeds: {:?}",
            zero.1
        );
    }

    #[tokio::test]
    async fn undecodable_bytes_close_the_connection_but_not_the_server() {
        let (_dir, path) = start_server().await;
        let mut healthy = TestClient::connect(&path).await;
        let (msgid, error, _) = healthy.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil());

        // A nesting bomb: 2000 nested fixarray-of-one markers blow the
        // codec's depth cap -- a decode error with no recoverable read
        // position, i.e. genuinely undecodable bytes. (Lone garbage markers
        // do NOT poison: rmpv decodes even reserved 0xc1, see the Codec doc.)
        let mut poisoner = tokio::net::UnixStream::connect(&path)
            .await
            .expect("connect");
        poisoner
            .write_all(&[0x91; 2000])
            .await
            .expect("write garbage");
        let mut buf = [0u8; 16];
        let read = tokio::time::timeout(RESPONSE_WAIT, poisoner.read(&mut buf))
            .await
            .expect("timed out waiting for the poisoned connection to close")
            .expect("read after poisoning");
        assert_eq!(0, read, "the poisoned connection closes without a response");

        // Other connections are unaffected, existing and new alike.
        let (msgid, error, _) = healthy.call(2, "ping", vec![]).await;
        assert_eq!(2, msgid);
        assert!(error.is_nil());
        let mut third = TestClient::connect(&path).await;
        let (msgid, error, _) = third.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil());
    }

    /// Answers each call with the peer its session saw open, as `[uid, pid]`
    /// (nil for an unknown half), and its hello with the peer the hello saw.
    struct Introspect {
        hello: bool,
    }

    impl Session for Peer {
        fn opened(conn: &Conn) -> Self {
            conn.peer
        }
    }

    fn peer_value(peer: Peer) -> Value {
        Value::Array(vec![
            peer.uid.map_or(Value::Nil, Value::from),
            peer.pid.map_or(Value::Nil, Value::from),
        ])
    }

    impl Handler for Introspect {
        type Session = Peer;

        fn requires_hello(&self) -> bool {
            self.hello
        }

        async fn hello(
            &self,
            conn: &Conn,
            _params: Vec<Value>,
        ) -> Result<(Value, Self::Session), RpcError> {
            Ok((peer_value(conn.peer), Peer::opened(conn)))
        }

        async fn call(
            &self,
            session: &Self::Session,
            _method: &str,
            _params: Vec<Value>,
        ) -> Result<Value, RpcError> {
            Ok(peer_value(*session))
        }
    }

    fn socket_owner(path: &std::path::Path) -> u32 {
        std::os::unix::fs::MetadataExt::uid(
            &std::fs::metadata(path).expect("the socket's metadata"),
        )
    }

    #[tokio::test]
    async fn a_session_sees_the_uid_and_pid_of_its_unix_peer() {
        let (_dir, path) = start_server_with(Introspect { hello: false }).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "who", vec![]).await;
        assert_eq!(Value::Nil, error);
        // The server runs in-process, so the peer connecting to it is this process.
        let expected = peer_value(Peer {
            uid: Some(socket_owner(&path)),
            pid: Some(std::process::id()),
        });
        assert_eq!(expected, result);
    }

    #[tokio::test]
    async fn a_hello_sees_the_peer_that_sent_it() {
        let (_dir, path) = start_server_with(Introspect { hello: true }).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, welcome) = client.call(1, "hello", vec![]).await;
        assert_eq!(Value::Nil, error);
        let expected = peer_value(Peer {
            uid: Some(socket_owner(&path)),
            pid: Some(std::process::id()),
        });
        assert_eq!(expected, welcome);
    }

    #[tokio::test]
    async fn a_tcp_peer_has_no_uid_or_pid() {
        let address = crate::support::start_tcp_server_with(Introspect { hello: false }).await;
        let mut client = TestClient::connect_tcp(address).await;
        let (_, error, result) = client.call(1, "who", vec![]).await;
        assert_eq!(Value::Nil, error);
        assert_eq!(peer_value(Peer::default()), result);
    }

    #[tokio::test]
    async fn a_wrapped_listener_still_reports_its_peer() {
        let (_dir, path, _errored) =
            crate::support::start_flaky_server_with(Introspect { hello: false }).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "who", vec![]).await;
        assert_eq!(Value::Nil, error);
        let expected = peer_value(Peer {
            uid: Some(socket_owner(&path)),
            pid: Some(std::process::id()),
        });
        assert_eq!(expected, result);
    }

    /// Refuses every method with its own code and text.
    struct Refuser;

    impl Handler for Refuser {
        type Session = ();

        async fn call(
            &self,
            _: &(),
            _method: &str,
            _params: Vec<Value>,
        ) -> Result<Value, RpcError> {
            Err(RpcError::Refused {
                code: "nope",
                message: "this handler refuses".to_string(),
            })
        }
    }

    #[tokio::test]
    async fn a_refusal_reaches_the_client_as_its_message() {
        let (_dir, path) = start_server_with(Refuser).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "anything", vec![]).await;
        assert_eq!(
            (Value::from("this handler refuses"), Value::Nil),
            (error, result)
        );
    }

    thread_local! {
        // Per thread because a current-thread test runs the server's tasks on its own thread.
        static LINES_DROPPED: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    }

    /// A session holding its connection's Push, counting its drops on this thread.
    struct Line(Push);

    impl Session for Line {
        fn opened(conn: &Conn) -> Self {
            Self(conn.push.clone())
        }
    }

    impl Drop for Line {
        fn drop(&mut self) {
            LINES_DROPPED.with(|dropped| dropped.set(dropped.get() + 1));
        }
    }

    /// A handler whose methods push to their own connection or a joined one.
    #[derive(Default)]
    struct Switchboard {
        joined: std::sync::Mutex<std::collections::HashMap<String, Push>>,
        accepted: Arc<AtomicUsize>,
    }

    fn chunk() -> Value {
        Value::from("x".repeat(8 << 10))
    }

    fn push_frame(method: &str, params: Vec<Value>) -> Value {
        Value::Array(vec![
            Value::from(2),
            Value::from(method),
            Value::Array(params),
        ])
    }

    fn count(params: &[Value]) -> u64 {
        params.first().and_then(Value::as_u64).unwrap_or(0)
    }

    impl Handler for Switchboard {
        type Session = Line;

        async fn call(
            &self,
            session: &Line,
            method: &str,
            params: Vec<Value>,
        ) -> Result<Value, RpcError> {
            let gone = |_| RpcError::Refused {
                code: "gone",
                message: "that connection is gone".to_string(),
            };
            match method {
                "join" => {
                    let name = params.first().and_then(Value::as_str).unwrap_or_default();
                    let mut joined = self.joined.lock().expect("the joined map");
                    joined.insert(name.to_string(), session.0.clone());
                    Ok(Value::Nil)
                }
                "tell" => {
                    let name = params.first().and_then(Value::as_str).unwrap_or_default();
                    let said = params.get(1).cloned().unwrap_or(Value::Nil);
                    let target = self.joined.lock().expect("the joined map")[name].clone();
                    target.send("answer", vec![said]).map_err(gone)?;
                    Ok(Value::Nil)
                }
                "burst" => {
                    for _ in 0..count(&params) {
                        session.0.send("chunk", vec![chunk()]).map_err(gone)?;
                    }
                    Ok(chunk())
                }
                "flood" => {
                    let target = match params.get(1).and_then(Value::as_str) {
                        Some(name) => self.joined.lock().expect("the joined map")[name].clone(),
                        None => session.0.clone(),
                    };
                    for _ in 0..count(&params) {
                        if target.send("chunk", vec![chunk()]).is_ok() {
                            self.accepted.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                    Ok(Value::Nil)
                }
                unknown => Err(RpcError::UnknownMethod(unknown.to_string())),
            }
        }
    }

    #[tokio::test]
    async fn a_push_reaches_its_own_connection_and_no_other() {
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut a = TestClient::connect(&path).await;
        let mut b = TestClient::connect(&path).await;
        let mut c = TestClient::connect(&path).await;
        for (client, name) in [(&mut a, "a"), (&mut b, "b")] {
            let (_, error, _) = client.call(1, "join", vec![Value::from(name)]).await;
            assert_eq!(Value::Nil, error, "{name} joined");
        }

        let tell = vec![Value::from("b"), Value::from(42)];
        let (_, error, _) = c.call(2, "tell", tell).await;
        assert_eq!(Value::Nil, error);

        assert_eq!(push_frame("answer", vec![Value::from(42)]), b.recv().await);
        for client in [&mut a, &mut c] {
            let (msgid, error, _) = client.call(9, "ping", vec![]).await;
            assert_eq!((9, Value::Nil), (msgid, error), "a stray push came first");
        }
    }

    #[tokio::test]
    async fn a_client_that_never_reads_is_closed_at_the_push_bound_and_others_go_on() {
        let switchboard = Switchboard::default();
        let accepted = Arc::clone(&switchboard.accepted);
        let (_dir, path) = start_server_with(switchboard).await;
        let mut slow = TestClient::connect(&path).await;
        let mut other = TestClient::connect(&path).await;

        slow.send(request(1, "flood", vec![Value::from(300)])).await;
        let mut stream = slow.into_inner();
        let mut written = Vec::new();
        tokio::time::timeout(RESPONSE_WAIT, stream.read_to_end(&mut written))
            .await
            .expect("the slow connection was closed")
            .expect("read until the close");
        assert_eq!(256, accepted.load(Ordering::SeqCst));

        let (msgid, error, _) = other.call(2, "ping", vec![]).await;
        assert_eq!((2, Value::Nil), (msgid, error));
    }

    #[tokio::test]
    async fn pushes_and_responses_arrive_as_whole_frames() {
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut client = TestClient::connect(&path).await;
        let (bursts, per_burst) = (20, 4);
        for msgid in 0..bursts {
            client
                .send(request(msgid, "burst", vec![Value::from(per_burst)]))
                .await;
        }
        let (mut pushes, mut replies) = (0, 0);
        while replies < bursts || pushes < bursts * per_burst {
            let frame = client.recv().await;
            if frame.as_array().and_then(|parts| parts.first()) == Some(&Value::from(2)) {
                assert_eq!(push_frame("chunk", vec![chunk()]), frame);
                pushes += 1;
            } else {
                let (_, error, result) = response_parts(frame);
                assert_eq!((Value::Nil, chunk()), (error, result));
                replies += 1;
            }
        }
        assert_eq!((bursts, bursts * per_burst), (replies, pushes));
    }

    #[tokio::test]
    async fn a_push_frame_from_a_client_is_refused_as_a_request() {
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut client = TestClient::connect(&path).await;

        client
            .send(push_frame("answer", vec![Value::from(1)]))
            .await;
        let (id, error, _) = raw_response_parts(client.recv().await);
        assert_eq!(
            (
                Value::from("answer"),
                Value::from("request has 3 elements, expected 4")
            ),
            (id, error)
        );

        client
            .send(Value::Array(vec![
                Value::from(2),
                Value::from(5),
                Value::from("ping"),
                Value::Array(vec![]),
            ]))
            .await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(
            (5, Value::from("request type must be 0, got 2")),
            (msgid, error)
        );
    }

    /// Pushes from every hello and admits only "letmein".
    struct Herald;

    impl Handler for Herald {
        type Session = Line;

        fn requires_hello(&self) -> bool {
            true
        }

        async fn hello(&self, conn: &Conn, params: Vec<Value>) -> Result<(Value, Line), RpcError> {
            let token = params.first().cloned().unwrap_or(Value::Nil);
            let _queued = conn.push.send("early", vec![token.clone()]);
            if token.as_str() == Some("letmein") {
                Ok((Value::from("welcome"), Line(conn.push.clone())))
            } else {
                Err(RpcError::Refused {
                    code: "bad_token",
                    message: "the hello was refused".to_string(),
                })
            }
        }

        async fn call(&self, _: &Line, method: &str, _: Vec<Value>) -> Result<Value, RpcError> {
            Err(RpcError::UnknownMethod(method.to_string()))
        }
    }

    #[tokio::test]
    async fn a_push_from_a_hello_waits_for_the_welcome() {
        let (_dir, path) = start_server_with(Herald).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, result) = client.call(1, "hello", vec![Value::from("letmein")]).await;
        assert_eq!((Value::Nil, Value::from("welcome")), (error, result));
        assert_eq!(
            push_frame("early", vec![Value::from("letmein")]),
            client.recv().await
        );
    }

    #[tokio::test]
    async fn a_push_from_a_refused_hello_never_reaches_the_peer() {
        let (_dir, path) = start_server_with(Herald).await;
        let mut client = TestClient::connect(&path).await;
        let (_, error, _) = client.call(1, "hello", vec![Value::from("guess")]).await;
        assert_eq!(Value::from("the hello was refused"), error);
        let after = tokio::time::timeout(RESPONSE_WAIT, client.next_frame())
            .await
            .expect("the refused connection closed");
        assert!(
            !matches!(after, Some(Ok(_))),
            "a refused peer read {after:?}"
        );
    }

    /// Counts warnings on the thread it is the default for.
    struct Warnings(Arc<AtomicUsize>);

    impl tracing::Subscriber for Warnings {
        fn enabled(&self, _: &tracing::Metadata<'_>) -> bool {
            true
        }

        fn new_span(&self, _: &tracing::span::Attributes<'_>) -> tracing::span::Id {
            tracing::span::Id::from_u64(1)
        }

        fn record(&self, _: &tracing::span::Id, _: &tracing::span::Record<'_>) {}

        fn record_follows_from(&self, _: &tracing::span::Id, _: &tracing::span::Id) {}

        fn event(&self, event: &tracing::Event<'_>) {
            if *event.metadata().level() == tracing::Level::WARN {
                self.0.fetch_add(1, Ordering::SeqCst);
            }
        }

        fn enter(&self, _: &tracing::span::Id) {}

        fn exit(&self, _: &tracing::span::Id) {}
    }

    #[tokio::test]
    async fn an_overflow_warns_once_for_its_connection() {
        let warnings = Arc::new(AtomicUsize::new(0));
        let _default = tracing::subscriber::set_default(Warnings(Arc::clone(&warnings)));
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut slow = TestClient::connect(&path).await;

        slow.send(request(1, "flood", vec![Value::from(300)])).await;
        let mut stream = slow.into_inner();
        let mut written = Vec::new();
        tokio::time::timeout(RESPONSE_WAIT, stream.read_to_end(&mut written))
            .await
            .expect("the slow connection was closed")
            .expect("read until the close");
        assert_eq!(1, warnings.load(Ordering::SeqCst));
    }

    /// A raw stream's frames until the server closes it.
    async fn frames_until_close(mut stream: tokio::net::UnixStream) -> Vec<Value> {
        let mut bytes = Vec::new();
        tokio::time::timeout(RESPONSE_WAIT, stream.read_to_end(&mut bytes))
            .await
            .expect("the connection closed")
            .expect("read until the close");
        let mut rest = bytes.as_slice();
        std::iter::from_fn(|| rmpv::decode::read_value(&mut rest).ok()).collect()
    }

    #[tokio::test]
    async fn pushes_queued_when_the_peer_stops_sending_are_still_written() {
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut client = TestClient::connect(&path).await;
        let pushes = 100;
        client
            .send(request(1, "burst", vec![Value::from(pushes)]))
            .await;
        tokio::time::sleep(Duration::from_millis(200)).await;
        let mut stream = client.into_inner();
        stream.shutdown().await.expect("half-close");

        let frames = frames_until_close(stream).await;
        let pushed = frames
            .iter()
            .filter(|frame| {
                frame.as_array().and_then(|parts| parts.first()) == Some(&Value::from(2))
            })
            .count();
        assert_eq!((pushes + 1, pushes), (frames.len(), pushed));
    }

    #[tokio::test]
    async fn an_overflow_closes_a_half_closed_peer_that_never_reads() {
        let (_dir, path) = start_server_with(Switchboard::default()).await;
        let mut stuck = TestClient::connect(&path).await;
        let mut other = TestClient::connect(&path).await;
        let (_, error, _) = stuck.call(1, "join", vec![Value::from("stuck")]).await;
        assert_eq!(Value::Nil, error);
        stuck
            .send(request(2, "flood", vec![Value::from(100)]))
            .await;
        tokio::time::sleep(Duration::from_millis(200)).await;
        let mut stream = stuck.into_inner();
        stream.shutdown().await.expect("half-close");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let dropped = LINES_DROPPED.with(std::cell::Cell::get);

        let flood = vec![Value::from(300), Value::from("stuck")];
        let (_, error, _) = other.call(3, "flood", flood).await;
        assert_eq!(Value::Nil, error);

        let closed = tokio::time::timeout(RESPONSE_WAIT, async {
            while LINES_DROPPED.with(std::cell::Cell::get) == dropped {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await;
        assert!(closed.is_ok(), "the overflow left the unread session open");
        assert_eq!(dropped + 1, LINES_DROPPED.with(std::cell::Cell::get));
        drop(stream);
    }
}
