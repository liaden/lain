//! In-process servers and a client for driving them, shared by this crate's tests and its users'.

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

use crate::{Accept, Codec, Handler, Peer, RpcError, Wire};

/// The version the test servers report, apart from this crate's own.
pub const VERSION: &str = "7.7.7";

/// Long enough for a loaded CI box; a red-phase server that never answers
/// fails here rather than hanging the suite.
pub const RESPONSE_WAIT: Duration = Duration::from_secs(5);

/// A handler with a slow method and nothing else, so the
/// out-of-order completion contract stays provable with only `ping` in
/// production. Malformed params sleep for zero: the tests never need that error.
struct SlowCore;

impl Handler for SlowCore {
    type Session = ();

    async fn call(&self, _: &(), method: &str, params: Vec<Value>) -> Result<Value, RpcError> {
        if method == "sleep" {
            let millis = params.first().and_then(Value::as_u64).unwrap_or(0);
            tokio::time::sleep(Duration::from_millis(millis)).await;
            Ok(Value::Nil)
        } else {
            Err(RpcError::UnknownMethod(method.to_string()))
        }
    }
}

/// Every starter below hands its listener to the SAME `serve`; that is the
/// claim the seam makes, so the harness must not fork per transport.
fn spawn_server<L: Accept + Send + 'static>(listener: L, handler: impl Handler) {
    tokio::spawn(async move { match crate::serve(listener, handler, VERSION).await {} });
}

fn bind_in_tempdir() -> (tempfile::TempDir, PathBuf, tokio::net::UnixListener) {
    let dir = tempfile::tempdir().expect("tempdir for the test socket");
    let path = dir.path().join("core.sock");
    let listener = tokio::net::UnixListener::bind(&path).expect("bind the test socket");
    (dir, path, listener)
}

/// A server on a tempdir socket. The `TempDir` guard must outlive the
/// test, or the socket path vanishes underneath the server.
pub async fn start_server() -> (tempfile::TempDir, PathBuf) {
    let (dir, path, listener) = bind_in_tempdir();
    spawn_server(listener, SlowCore);
    (dir, path)
}

/// A server running `handler` on a tempdir socket.
pub async fn start_server_with(handler: impl Handler) -> (tempfile::TempDir, PathBuf) {
    let (dir, path, listener) = bind_in_tempdir();
    spawn_server(listener, handler);
    (dir, path)
}

/// A listener of an unrelated concrete type, wired into the same serve
/// loop: the compile-level proof that [`Accept`] is a seam and not a
/// rename. TCP is the cheapest witness available -- tokio's `net` feature
/// is already on, so it costs no dependency.
pub async fn start_tcp_server() -> SocketAddr {
    start_tcp_server_with(SlowCore).await
}

/// A TCP server running `handler`.
pub async fn start_tcp_server_with(handler: impl Handler) -> SocketAddr {
    let listener = TcpListener::bind(("127.0.0.1", 0))
        .await
        .expect("bind the test tcp listener");
    let address = listener.local_addr().expect("the bound address");
    spawn_server(listener, handler);
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

    fn peer(connection: &Self::Connection) -> Peer {
        L::peer(connection)
    }
}

/// The flag reads true once the synthetic failure has fired.
pub async fn start_flaky_server() -> (tempfile::TempDir, PathBuf, Arc<AtomicBool>) {
    start_flaky_server_with(SlowCore).await
}

/// A flaky server running `handler`.
pub async fn start_flaky_server_with(
    handler: impl Handler,
) -> (tempfile::TempDir, PathBuf, Arc<AtomicBool>) {
    let dir = tempfile::tempdir().expect("tempdir for the test socket");
    let path = dir.path().join("core.sock");
    let inner = tokio::net::UnixListener::bind(&path).expect("bind the test socket");
    let errored = Arc::new(AtomicBool::new(false));
    spawn_server(
        FlakyOnce {
            inner,
            errored: Arc::clone(&errored),
        },
        handler,
    );
    (dir, path, errored)
}

/// A client that frames msgpack-RPC the way a real peer does.
pub struct TestClient<C> {
    framed: Framed<C, Codec>,
}

impl TestClient<UnixStream> {
    /// Connects to a Unix socket.
    pub async fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path)
            .await
            .expect("connect to the server");
        Self {
            framed: Framed::new(stream, Codec::default()),
        }
    }
}

impl TestClient<TcpStream> {
    /// Connects to a TCP address.
    pub async fn connect_tcp(address: SocketAddr) -> Self {
        let stream = TcpStream::connect(address)
            .await
            .expect("connect to the tcp server");
        Self {
            framed: Framed::new(stream, Codec::default()),
        }
    }
}

impl<C: Wire> TestClient<C> {
    /// Frames an already connected stream.
    pub fn over(stream: C) -> Self {
        Self {
            framed: Framed::new(stream, Codec::default()),
        }
    }

    /// The next frame, or None once the server closed. Callers bring their own timeout.
    pub async fn next_frame(&mut self) -> Option<io::Result<Value>> {
        self.framed.next().await
    }

    /// Sends one frame.
    pub async fn send(&mut self, frame: Value) {
        self.framed.send(frame).await.expect("send a frame");
    }

    /// Bytes the codec would refuse to build: wire-level probes.
    pub async fn send_raw(&mut self, bytes: &[u8]) {
        use tokio::io::AsyncWriteExt;
        self.framed
            .get_mut()
            .write_all(bytes)
            .await
            .expect("send raw bytes");
    }

    /// The underlying stream.
    pub fn into_inner(self) -> C {
        self.framed.into_inner()
    }

    /// The next frame within [`RESPONSE_WAIT`].
    pub async fn recv(&mut self) -> Value {
        tokio::time::timeout(RESPONSE_WAIT, self.framed.next())
            .await
            .expect("timed out waiting for a response")
            .expect("connection closed without a response")
            .expect("decode a response frame")
    }

    /// Lockstep request/response for tests that need determinism; the
    /// out-of-order test drives `send`/`recv` by hand instead.
    pub async fn call(
        &mut self,
        msgid: u32,
        method: &str,
        params: Vec<Value>,
    ) -> (u32, Value, Value) {
        self.send(request(msgid, method, params)).await;
        response_parts(self.recv().await)
    }
}

/// A `[0, msgid, method, params]` request frame.
pub fn request(msgid: u32, method: &str, params: Vec<Value>) -> Value {
    Value::Array(vec![
        Value::from(0),
        Value::from(msgid),
        Value::from(method),
        Value::Array(params),
    ])
}

/// `[1, id, error, result]` -> `(id, error, result)` with the id slot
/// untouched -- error replies to junk-msgid frames echo the junk verbatim.
pub fn raw_response_parts(response: Value) -> (Value, Value, Value) {
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
pub fn response_parts(response: Value) -> (u32, Value, Value) {
    let (id, error, result) = raw_response_parts(response);
    let msgid = id
        .as_u64()
        .and_then(|id| u32::try_from(id).ok())
        .expect("msgid");
    (msgid, error, result)
}

/// The named field of a map result.
pub fn field(result: &Value, name: &str) -> Value {
    result
        .as_map()
        .expect("result is a map")
        .iter()
        .find(|(key, _)| key.as_str() == Some(name))
        .unwrap_or_else(|| panic!("missing field {name} in {result:?}"))
        .1
        .clone()
}
