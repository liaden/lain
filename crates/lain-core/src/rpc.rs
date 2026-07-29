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
//! msgpack-RPC *notifications* (`[2, method, params]`) are unsupported and
//! answered as invalid requests (an arity error echoing the id slot): the only
//! client we serve never sends one, and a silent no-reply path would be a
//! second contract to maintain for nobody.

use std::convert::Infallible;
use std::future::Future;
use std::io;

use bytes::{Buf, BufMut, BytesMut};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use rmpv::Value;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio_util::codec::{Decoder, Encoder, Framed};

use crate::{exec, grep};

/// Incremental msgpack decode. msgpack is self-delimiting, so there is no
/// framing to invent: try to read one value; `UnexpectedEof` means
/// need-more-bytes, any other decode error means the stream is poisoned.
///
/// rmpv is LENIENT about the reserved marker: 0xc1 decodes as `Value::Nil`
/// (rmpv 1.3.1, decode/value.rs), so lone garbage bytes usually surface as
/// decodable-but-invalid requests (an error response), not as poison. What
/// does poison the stream is `DepthLimitExceeded` -- and the depth cap here is
/// OURS, far below rmpv's default: at rmpv's own MAX_DEPTH (1024) the
/// recursive decode overflows a 2 MiB worker-thread stack in debug builds
/// BEFORE the limiter fires, aborting the whole daemon (found the hard way by
/// this crate's poison test). RPC frames are a few levels deep at most, so the
/// cap is generous for real traffic and turns a nesting bomb into a clean
/// connection close.
pub(crate) struct Codec;

/// See the [`Codec`] doc: protects the daemon's stack, not just the protocol.
/// NOTE the unit: rmpv burns ~2 depth units per actual nesting level, so 64
/// units admit ~32 levels of real nesting -- the probe sweep
/// (probes/c1/probe_depth_boundary.rb) measured params nesting 30 accepted /
/// 31 poisoned inside the `[0, id, method, params]` envelope, i.e. 32 total.
const MAX_DECODE_DEPTH: usize = 64;

impl Decoder for Codec {
    type Item = Value;
    type Error = io::Error;

    fn decode(&mut self, src: &mut BytesMut) -> io::Result<Option<Value>> {
        if src.is_empty() {
            return Ok(None);
        }
        let mut cursor = io::Cursor::new(&src[..]);
        match rmpv::decode::read_value_with_max_depth(&mut cursor, MAX_DECODE_DEPTH) {
            Ok(value) => {
                // read_value consumed exactly one whole value; drop those bytes.
                let consumed = usize::try_from(cursor.position()).map_err(io::Error::other)?;
                src.advance(consumed);
                Ok(Some(value))
            }
            Err(error) if is_incomplete(&error) => Ok(None),
            Err(error) => Err(io::Error::new(io::ErrorKind::InvalidData, error)),
        }
    }
}

fn is_incomplete(error: &rmpv::decode::Error) -> bool {
    use rmpv::decode::Error::{InvalidDataRead, InvalidMarkerRead};
    match error {
        InvalidMarkerRead(inner) | InvalidDataRead(inner) => {
            inner.kind() == io::ErrorKind::UnexpectedEof
        }
        _ => false,
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
pub(crate) trait Wire: AsyncRead + AsyncWrite + Send + Unpin + 'static {}

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
/// does not carry (`Cargo.toml` takes `codec` only) -- and enabling it would
/// not be enough anyway, because `VsockListener` is a foreign type and
/// `Listener` a foreign trait, so the orphan rule forbids the impl the vsock
/// work needs. A local trait is implementable for anything.
///
/// `-> impl Future + Send` rather than `async fn`: the accept future is polled
/// inside `serve`'s, which is spawned, so the `Send` bound has to be part of
/// the contract instead of something each caller re-proves. The cost is an
/// implicit `Self: Sync` on any impl that holds `&self` across an await --
/// every listener here is `Sync`, but a listener with interior mutability is
/// rejected at its impl with a `future cannot be sent between threads` error
/// that names neither this bound nor the `&self` capture that needs it.
pub(crate) trait Accept {
    type Connection: Wire;

    fn accept(&self) -> impl Future<Output = io::Result<Self::Connection>> + Send;
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
}

/// Accept loop: one task per connection, forever. A failed accept is logged
/// and retried after a pause -- a bad client (or a full fd table) must never
/// take the daemon down.
///
/// Generic, not `dyn`: one monomorphized loop per listener type, so the seam
/// costs no allocation on the per-connection path.
pub(crate) async fn serve(listener: impl Accept) -> Infallible {
    loop {
        match listener.accept().await {
            Ok(stream) => {
                tokio::spawn(serve_connection(stream));
            }
            Err(error) => {
                tracing::warn!(%error, "accept failed; still listening");
                tokio::time::sleep(ACCEPT_RETRY_DELAY).await;
            }
        }
    }
}

type Sink<C> = SplitSink<Framed<C, Codec>, Value>;
type Stream<C> = SplitStream<Framed<C, Codec>>;

/// One connection: a reader that spawns an independent task per request, and
/// a writer that sends responses in whatever order the tasks finish. On EOF
/// the writer drains in-flight responses before closing; on poison it is
/// aborted -- the connection dies immediately and takes no response with it.
async fn serve_connection<C: Wire>(stream: C) {
    let (sink, mut inbound) = Framed::new(stream, Codec).split();
    let (responses, inbox) = mpsc::channel(RESPONSE_BUFFER);
    let writer = tokio::spawn(write_responses(sink, inbox));
    let poisoned = read_requests(&mut inbound, &responses).await;
    drop(responses);
    if poisoned {
        writer.abort();
    }
    let _ = writer.await;
}

/// Returns true when the stream was poisoned by undecodable bytes, false on a
/// clean EOF.
async fn read_requests<C: Wire>(inbound: &mut Stream<C>, responses: &mpsc::Sender<Value>) -> bool {
    loop {
        match inbound.next().await {
            Some(Ok(frame)) => {
                tokio::spawn(respond_to(frame, responses.clone()));
            }
            Some(Err(error)) => {
                tracing::warn!(%error, "undecodable bytes poison the stream; closing connection");
                return true;
            }
            None => return false,
        }
    }
}

async fn write_responses<C: Wire>(mut sink: Sink<C>, mut inbox: mpsc::Receiver<Value>) {
    while let Some(response) = inbox.recv().await {
        if sink.send(response).await.is_err() {
            return;
        }
    }
}

/// One request, one independent task: the send fails only when the connection
/// is already gone, and then there is nobody left to tell.
async fn respond_to(frame: Value, responses: mpsc::Sender<Value>) {
    let response = match Request::parse(frame) {
        Ok(request) => request.dispatch().await,
        Err((echo_id, error)) => error_reply(echo_id, &error),
    };
    let _ = responses.send(response).await;
}

struct Request {
    msgid: u32,
    method: String,
    params: Vec<Value>,
}

impl Request {
    /// `[0, msgid, method, params]`, msgid a 32-bit unsigned integer (the
    /// msgpack-RPC contract our client demuxes by). A parse failure carries
    /// the frame's id SLOT to echo verbatim -- junk ids included -- and 0 only
    /// when the frame carried no id slot at all. WHY verbatim rather than
    /// collapsing junk to 0: msgid 0 is a LEGAL msgid, so an error reply
    /// claiming 0 would collide with a legitimate in-flight msgid-0 request
    /// and misdeliver (probe_msgid_shapes' collision demo).
    fn parse(frame: Value) -> Result<Self, (Value, RpcError)> {
        let Value::Array(elements) = frame else {
            return Err((Value::from(0), RpcError::NotArray));
        };
        let echo = elements.get(1).cloned().unwrap_or_else(|| Value::from(0));
        let [kind, msgid, method, params]: [Value; 4] = elements
            .try_into()
            .map_err(|elements: Vec<Value>| (echo.clone(), RpcError::Arity(elements.len())))?;
        if kind.as_u64() != Some(0) {
            return Err((echo, RpcError::Kind(kind)));
        }
        let Some(msgid) = msgid.as_u64().and_then(|id| u32::try_from(id).ok()) else {
            return Err((echo.clone(), RpcError::Msgid(echo)));
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

    async fn dispatch(self) -> Value {
        match self.method.as_str() {
            "ping" => ok_response(self.msgid, ping_result()),
            "exec" => match run_exec(&self.params).await {
                Ok(outcome) => ok_response(self.msgid, exec_result(outcome)),
                Err(message) => error_response(self.msgid, message),
            },
            "grep" => match run_grep(&self.params).await {
                Ok(outcome) => ok_response(self.msgid, grep_result(outcome)),
                Err(message) => error_response(self.msgid, message),
            },
            unknown => error_response(self.msgid, RpcError::UnknownMethod(unknown.to_string())),
        }
    }
}

async fn run_exec(params: &[Value]) -> Result<exec::Outcome, String> {
    let map = params
        .first()
        .ok_or("exec takes one params element, a map")?;
    let decoded = exec::ExecParams::from_value(map).map_err(|error| error.to_string())?;
    exec::run(decoded).await.map_err(|error| error.to_string())
}

async fn run_grep(params: &[Value]) -> Result<grep::Outcome, String> {
    let map = params
        .first()
        .ok_or("grep takes one params element, a map")?;
    let decoded = grep::GrepParams::from_value(map).map_err(|error| error.to_string())?;
    grep::run(decoded).await.map_err(|error| error.to_string())
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

fn ping_result() -> Value {
    Value::Map(vec![
        (
            Value::from("version"),
            Value::from(env!("CARGO_PKG_VERSION")),
        ),
        (Value::from("pid"), Value::from(std::process::id())),
    ])
}

fn exec_result(outcome: exec::Outcome) -> Value {
    Value::Map(vec![
        (Value::from("stdout"), Value::Binary(outcome.stdout)),
        (Value::from("stderr"), Value::Binary(outcome.stderr)),
        (Value::from("exit_status"), Value::from(outcome.exit_status)),
        (Value::from("timed_out"), Value::from(outcome.timed_out)),
    ])
}

/// `matches` plus the `capped` flag, and every match is the three fields
/// `Tools::Grep` already yields -- path, line number, line -- so the Ruby side
/// swaps its transport without changing what it formats. Paths and lines are
/// msgpack `str`, unlike exec's `bin` output: a grep result is text by
/// construction (binary files are detected and skipped).
fn grep_result(outcome: grep::Outcome) -> Value {
    Value::Map(vec![
        (
            Value::from("matches"),
            Value::Array(outcome.matches.into_iter().map(match_result).collect()),
        ),
        (Value::from("capped"), Value::from(outcome.capped)),
    ])
}

fn match_result(found: grep::Match) -> Value {
    Value::Map(vec![
        (Value::from("path"), Value::from(found.path)),
        (Value::from("line_number"), Value::from(found.line_number)),
        (Value::from("line"), Value::from(found.line)),
    ])
}

#[derive(Debug, Error)]
pub(crate) enum RpcError {
    #[error("request is not an array")]
    NotArray,
    #[error("request has {0} elements, expected 4")]
    Arity(usize),
    #[error("request type must be 0, got {0}")]
    Kind(Value),
    #[error("request msgid must be a 32-bit unsigned integer, got {0}")]
    Msgid(Value),
    #[error("request method must be a string")]
    MethodNotString,
    #[error("request params must be an array")]
    ParamsNotArray,
    #[error("unknown method {0:?}")]
    UnknownMethod(String),
}

#[cfg(test)]
pub(crate) mod support {
    use std::io;
    use std::net::SocketAddr;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use rmpv::Value;
    use tokio::net::{TcpListener, TcpStream, UnixStream};
    use tokio_util::codec::Framed;

    use super::{Accept, Codec, Wire};

    /// Long enough for a loaded CI box; a red-phase server that never answers
    /// fails here rather than hanging the suite.
    pub(crate) const RESPONSE_WAIT: Duration = Duration::from_secs(5);

    /// Every starter below hands its listener to the SAME `serve`; that is the
    /// claim the seam makes, so the harness must not fork per transport.
    fn spawn_server<L: Accept + Send + 'static>(listener: L) {
        tokio::spawn(async move { match super::serve(listener).await {} });
    }

    /// A server on a tempdir socket. The `TempDir` guard must outlive the
    /// test, or the socket path vanishes underneath the server.
    pub(crate) async fn start_server() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().expect("tempdir for the test socket");
        let path = dir.path().join("core.sock");
        let listener = tokio::net::UnixListener::bind(&path).expect("bind the test socket");
        spawn_server(listener);
        (dir, path)
    }

    /// A listener of an unrelated concrete type, wired into the same serve
    /// loop: the compile-level proof that [`Accept`] is a seam and not a
    /// rename. TCP is the cheapest witness available -- tokio's `net` feature
    /// is already on, so it costs no dependency, and unlike the AF_VSOCK
    /// listener this seam exists for it needs no kernel module or hypervisor.
    pub(crate) async fn start_tcp_server() -> SocketAddr {
        let listener = TcpListener::bind(("127.0.0.1", 0))
            .await
            .expect("bind the test tcp listener");
        let address = listener.local_addr().expect("the bound address");
        spawn_server(listener);
        address
    }

    impl Accept for TcpListener {
        type Connection = TcpStream;

        async fn accept(&self) -> io::Result<TcpStream> {
            TcpListener::accept(self)
                .await
                .map(|(stream, _address)| stream)
        }
    }

    /// Fails its first accept, then delegates. The accept-error arm is a
    /// behavioural invariant (log, pause, never crash) with no natural trigger
    /// -- EMFILE cannot be arranged in-process -- so the seam supplies one.
    struct FlakyOnce<L> {
        inner: L,
        errored: Arc<AtomicBool>,
    }

    impl<L: Accept + Sync> Accept for FlakyOnce<L> {
        type Connection = L::Connection;

        async fn accept(&self) -> io::Result<Self::Connection> {
            // The swap flips the flag on the error branch and nowhere else, so
            // a test reading it knows the error arm ran -- not merely that
            // `accept` was called.
            if self.errored.swap(true, Ordering::SeqCst) {
                self.inner.accept().await
            } else {
                Err(io::Error::other("synthetic accept failure"))
            }
        }
    }

    /// The flag reads true once the synthetic failure has fired.
    pub(crate) async fn start_flaky_server() -> (tempfile::TempDir, PathBuf, Arc<AtomicBool>) {
        let dir = tempfile::tempdir().expect("tempdir for the test socket");
        let path = dir.path().join("core.sock");
        let inner = tokio::net::UnixListener::bind(&path).expect("bind the test socket");
        let errored = Arc::new(AtomicBool::new(false));
        spawn_server(FlakyOnce {
            inner,
            errored: Arc::clone(&errored),
        });
        (dir, path, errored)
    }

    pub(crate) struct TestClient<C> {
        framed: Framed<C, Codec>,
    }

    impl TestClient<UnixStream> {
        pub(crate) async fn connect(path: &Path) -> Self {
            let stream = UnixStream::connect(path)
                .await
                .expect("connect to the server");
            Self {
                framed: Framed::new(stream, Codec),
            }
        }
    }

    impl TestClient<TcpStream> {
        pub(crate) async fn connect_tcp(address: SocketAddr) -> Self {
            let stream = TcpStream::connect(address)
                .await
                .expect("connect to the tcp server");
            Self {
                framed: Framed::new(stream, Codec),
            }
        }
    }

    impl<C: Wire> TestClient<C> {
        pub(crate) async fn send(&mut self, frame: Value) {
            self.framed.send(frame).await.expect("send a frame");
        }

        /// Bytes the codec would refuse to build: wire-level probes.
        pub(crate) async fn send_raw(&mut self, bytes: &[u8]) {
            use tokio::io::AsyncWriteExt;
            self.framed
                .get_mut()
                .write_all(bytes)
                .await
                .expect("send raw bytes");
        }

        pub(crate) async fn recv(&mut self) -> Value {
            tokio::time::timeout(RESPONSE_WAIT, self.framed.next())
                .await
                .expect("timed out waiting for a response")
                .expect("connection closed without a response")
                .expect("decode a response frame")
        }

        /// Lockstep request/response for tests that need determinism; the
        /// out-of-order test drives `send`/`recv` by hand instead.
        pub(crate) async fn call(
            &mut self,
            msgid: u32,
            method: &str,
            params: Vec<Value>,
        ) -> (u32, Value, Value) {
            self.send(request(msgid, method, params)).await;
            response_parts(self.recv().await)
        }
    }

    pub(crate) fn request(msgid: u32, method: &str, params: Vec<Value>) -> Value {
        Value::Array(vec![
            Value::from(0),
            Value::from(msgid),
            Value::from(method),
            Value::Array(params),
        ])
    }

    /// `[1, id, error, result]` -> `(id, error, result)` with the id slot
    /// untouched -- error replies to junk-msgid frames echo the junk verbatim.
    pub(crate) fn raw_response_parts(response: Value) -> (Value, Value, Value) {
        let Value::Array(mut parts) = response else {
            panic!("response is not an array: {response:?}")
        };
        assert_eq!(4, parts.len(), "response arity");
        assert_eq!(Value::from(1), parts[0], "response type");
        let result = parts.pop().expect("result element");
        let error = parts.pop().expect("error element");
        let id = parts.pop().expect("id element");
        (id, error, result)
    }

    /// `[1, msgid, error, result]` -> `(msgid, error, result)`, asserting the
    /// envelope shape and a u32 msgid.
    pub(crate) fn response_parts(response: Value) -> (u32, Value, Value) {
        let (id, error, result) = raw_response_parts(response);
        let msgid = id
            .as_u64()
            .and_then(|id| u32::try_from(id).ok())
            .expect("msgid");
        (msgid, error, result)
    }

    pub(crate) fn field(result: &Value, name: &str) -> Value {
        result
            .as_map()
            .expect("result is a map")
            .iter()
            .find(|(key, _)| key.as_str() == Some(name))
            .unwrap_or_else(|| panic!("missing field {name} in {result:?}"))
            .1
            .clone()
    }

    pub(crate) fn exec_params(argv: &[&str]) -> Vec<Value> {
        vec![exec_map(argv, &[], None)]
    }

    pub(crate) fn exec_map(
        argv: &[&str],
        env: &[(&str, Option<&str>)],
        timeout_ms: Option<u64>,
    ) -> Value {
        let mut entries = vec![(
            Value::from("argv"),
            Value::Array(argv.iter().map(|arg| Value::from(*arg)).collect()),
        )];
        if !env.is_empty() {
            let pairs = env
                .iter()
                .map(|(key, value)| (Value::from(*key), value.map_or(Value::Nil, Value::from)))
                .collect();
            entries.push((Value::from("env"), Value::Map(pairs)));
        }
        if let Some(ms) = timeout_ms {
            entries.push((Value::from("timeout_ms"), Value::from(ms)));
        }
        Value::Map(entries)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;
    use std::time::Instant;

    use rmpv::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::support::{
        RESPONSE_WAIT, TestClient, exec_params, field, raw_response_parts, request, response_parts,
        start_flaky_server, start_server, start_tcp_server,
    };
    use super::{ACCEPT_RETRY_DELAY, Wire};

    /// The whole protocol surface a transport has to carry, as one value: a
    /// ping's version and an exec's stdout. Two transports agreeing on this
    /// pair is the differential the seam is judged by.
    async fn ping_and_exec<C: Wire>(client: &mut TestClient<C>) -> (Value, Value) {
        let (msgid, error, result) = client.call(1, "ping", vec![]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected ping error: {error:?}");
        let version = field(&result, "version");

        let (msgid, error, result) = client
            .call(2, "exec", exec_params(&["sh", "-c", "echo hi"]))
            .await;
        assert_eq!(2, msgid);
        assert!(error.is_nil(), "unexpected exec error: {error:?}");
        (version, field(&result, "stdout"))
    }

    #[tokio::test]
    async fn the_unix_path_pings_and_execs_unchanged() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        assert_eq!(
            (
                Value::from(env!("CARGO_PKG_VERSION")),
                Value::Binary(b"hi\n".to_vec())
            ),
            ping_and_exec(&mut client).await
        );
    }

    #[tokio::test]
    async fn a_listener_of_another_type_serves_the_same_protocol() {
        let (_dir, path) = start_server().await;
        let mut unix = TestClient::connect(&path).await;
        let mut tcp = TestClient::connect_tcp(start_tcp_server().await).await;
        // Same `serve`, same `serve_connection`: nothing was duplicated to
        // make TCP work, so the two answers must be indistinguishable.
        assert_eq!(
            ping_and_exec(&mut unix).await,
            ping_and_exec(&mut tcp).await
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
        assert_eq!(
            Value::from(env!("CARGO_PKG_VERSION")),
            field(&result, "version")
        );
        // The server runs in-process for tests, so its pid is ours.
        assert_eq!(Value::from(std::process::id()), field(&result, "pid"));
    }

    #[tokio::test]
    async fn in_flight_requests_complete_out_of_order_matched_by_msgid() {
        let (_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        client
            .send(request(1, "exec", exec_params(&["sh", "-c", "sleep 0.3"])))
            .await;
        client
            .send(request(2, "exec", exec_params(&["true"])))
            .await;
        let (first_msgid, first_error, _) = response_parts(client.recv().await);
        let (second_msgid, second_error, _) = response_parts(client.recv().await);
        assert!(first_error.is_nil(), "unexpected error: {first_error:?}");
        assert!(second_error.is_nil(), "unexpected error: {second_error:?}");
        assert_eq!(2, first_msgid, "the fast command answers first");
        assert_eq!(
            1, second_msgid,
            "the slow command answers second, msgid intact"
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

        // Decodable exec with invalid params (no argv): an error reply, not a close.
        client
            .send(request(11, "exec", vec![Value::Map(vec![])]))
            .await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(11, msgid);
        assert!(!error.is_nil());

        // The reserved marker 0xc1: rmpv leniently decodes it as nil, so it
        // is a decodable-but-invalid request (error response, msgid 0), NOT
        // poison. Pinned so an rmpv strictness change shows up here.
        client.send_raw(&[0xc1]).await;
        let (msgid, error, _) = response_parts(client.recv().await);
        assert_eq!(0, msgid);
        assert!(!error.is_nil());

        // The connection survived all five.
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
        // exec in flight beside a huge-msgid frame. The msgid-0 success must
        // stay unambiguous -- exactly one response claims id 0.
        let huge_id = Value::from(1u64 << 40);
        client
            .send(Value::Array(vec![
                Value::from(0),
                huge_id.clone(),
                Value::from("exec"),
                Value::Array(exec_params(&["sh", "-c", "echo huge"])),
            ]))
            .await;
        client
            .send(request(0, "exec", exec_params(&["sh", "-c", "echo zero"])))
            .await;
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
            "the huge-msgid frame errors instead of executing"
        );
        assert_eq!(Value::from(0), zero.0);
        assert!(
            zero.1.is_nil(),
            "the legitimate msgid-0 exec succeeds: {:?}",
            zero.1
        );
        assert_eq!(Value::Binary(b"zero\n".to_vec()), field(&zero.2, "stdout"));
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
}
