//! lain-core: the out-of-process exec daemon.
//!
//! A msgpack-RPC server on a Unix socket, or on `AF_VSOCK` when argv asks for
//! it -- the protocol above the listener is identical either way, which is the
//! point: the same daemon serves a host over a filesystem socket and a microVM
//! guest over a hypervisor's virtio-vsock channel. The bind address arrives via
//! argv -- this binary NEVER computes its own path; path policy belongs to Ruby
//! (`Paths#runtime_dir`). Tracing goes to a file path given by argv, or
//! /dev/null when absent, and never to an inherited terminal: the Journal is
//! NDJSON and one stray diagnostic line interleaved into it breaks the
//! experiment record (the wound stays closed).
//!
//! Confinement is explicitly OUT of scope: `exec`'s env handling is an
//! override, not confinement (see `exec::merged_env`), and nothing in this
//! crate is a sandbox.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr)]

mod exec;
mod rpc;

use std::process::ExitCode;

use rpc::Accept;
use tokio_vsock::{VMADDR_CID_ANY, VsockAddr, VsockListener, VsockStream};

/// Bad invocation or an unopenable tracing path. There is no usage text on
/// purpose: this binary may never touch stdout/stderr, so a bad invocation is
/// an exit code, not a message.
const USAGE_ERROR: u8 = 2;
/// The socket could not be bound (stale file, missing dir, permissions), or the
/// vsock port could not be published -- an unreachable daemon is a failed bind
/// whichever half of it failed.
const BIND_ERROR: u8 = 1;

/// The vsock scheme, matched as an exact PREFIX and by nothing else. That makes
/// the disambiguation rule a single sentence: an argument beginning with these
/// six bytes is a vsock address, everything else is a filesystem path. A
/// "contains a colon" test would instead have swallowed relative paths like
/// `run:1/core.sock`; `Child` passes an absolute path, which cannot begin with
/// `vsock:` at all.
///
/// The scheme also REQUIRES the tracing-path argument, because that is the path
/// its port file sits beside and a vsock daemon nobody can discover is not
/// serving anything. Without it the invocation is refused outright rather than
/// left to fail later on an unwritable `/dev/null.port` -- which is a filesystem
/// accident, and one that disappears under the root uid a daemon inside a guest
/// generally carries, leaving it serving undiscoverably and littering `/`.
const VSOCK_SCHEME: &str = "vsock:";

/// `VMADDR_PORT_ANY`, which tokio-vsock does not re-export. It is `u32::MAX`,
/// **not** 0 -- on vsock, port 0 and every port below 1024 are privileged and
/// raise EACCES, so the TCP reflex of "bind port 0 for an ephemeral port" fails
/// here in a way that reads like a permissions bug rather than a wrong constant.
///
/// Being a real port number, it is also spellable: `vsock:4294967295` asks for
/// an ephemeral port by the long name. Harmless, and not worth a special case,
/// but it is why an explicit port is not a guarantee of a fixed one.
const VMADDR_PORT_ANY: u32 = u32::MAX;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(bind_argument) = args.next() else {
        return ExitCode::from(USAGE_ERROR);
    };
    let tracing_path = args.next();
    if init_tracing(tracing_path.as_deref().unwrap_or("/dev/null")).is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    // The bind argument is parsed on the far side of `init_tracing` so a
    // malformed one can be named in the log rather than only in an exit code.
    serve_forever(bind_argument, tracing_path)
}

/// Where the daemon listens, as argv asked for it.
enum Bind {
    Unix(String),
    /// The tracing path rides along because the vsock arm cannot be served
    /// without one: it is where the port file is published.
    Vsock {
        port: u32,
        tracing_path: String,
    },
}

impl Bind {
    fn parse(argument: &str, tracing_path: Option<String>) -> Option<Self> {
        let Some(requested) = argument.strip_prefix(VSOCK_SCHEME) else {
            return Some(Self::Unix(argument.to_string()));
        };
        let port = match requested {
            "" => VMADDR_PORT_ANY,
            // `u32::from_str` accepts a leading `+`, so `vsock:+5252` would
            // otherwise be a second spelling of `vsock:5252`. One address, one
            // spelling.
            signed if signed.starts_with('+') => return None,
            digits => digits.parse().ok()?,
        };
        Some(Self::Vsock {
            port,
            tracing_path: tracing_path?,
        })
    }
}

fn init_tracing(path: &str) -> std::io::Result<()> {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    tracing_subscriber::fmt()
        .with_ansi(false)
        .with_writer(std::sync::Mutex::new(file))
        .init();
    Ok(())
}

#[tokio::main]
async fn serve_forever(bind_argument: String, tracing_path: Option<String>) -> ExitCode {
    match Bind::parse(&bind_argument, tracing_path) {
        None => {
            tracing::error!(
                argument = bind_argument,
                "not a filesystem path, and not a vsock:<port> with the tracing path its port file sits beside"
            );
            ExitCode::from(USAGE_ERROR)
        }
        Some(Bind::Unix(path)) => serve_unix(&path).await,
        Some(Bind::Vsock { port, tracing_path }) => serve_vsock(port, &tracing_path).await,
    }
}

async fn serve_unix(socket_path: &str) -> ExitCode {
    match tokio::net::UnixListener::bind(socket_path) {
        Ok(listener) => {
            tracing::info!(socket_path, pid = std::process::id(), "lain-core listening");
            serve_with(listener).await
        }
        Err(error) => {
            tracing::error!(%error, socket_path, "could not bind the socket");
            ExitCode::from(BIND_ERROR)
        }
    }
}

async fn serve_vsock(port: u32, tracing_path: &str) -> ExitCode {
    // Clear the previous generation's port file BEFORE binding, so the
    // contract's one sentence -- "the file's existence is the readiness signal"
    // -- stays true instead of growing a "on a fresh path" caveat every consumer
    // would have to remember. Tracing paths are REUSED: `Child#tracing_path` is
    // a stable `runtime_dir/core-<project_hash>.log`, one per project, so
    // anything modelled on it restarts onto its own leftovers and a reader
    // polling for existence gets the dead daemon's port. There is no refusal to
    // save it either -- a vsock connect to a dead port SUCCEEDS on
    // vsock_loopback, so the symptom is a handshake timeout, not an error.
    //
    // Best-effort: a missing file is the normal case, and a file that cannot be
    // removed will fail again at publish, loudly and fatally.
    let _ = std::fs::remove_file(port_path(tracing_path));

    let listener = match VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, port)) {
        Ok(listener) => listener,
        Err(error) => {
            tracing::error!(%error, port, "could not bind the vsock port");
            return ExitCode::from(BIND_ERROR);
        }
    };
    // The requested port is not the bound port when it was VMADDR_PORT_ANY, so
    // the kernel is the only authority on which port is being served.
    let bound = match listener.local_addr() {
        Ok(address) => address.port(),
        Err(error) => {
            tracing::error!(%error, "could not read back the bound vsock port");
            return ExitCode::from(BIND_ERROR);
        }
    };
    if let Err(error) = publish_port(tracing_path, bound) {
        tracing::error!(%error, port = bound, "could not publish the port");
        return ExitCode::from(BIND_ERROR);
    }
    tracing::info!(
        vsock_port = bound,
        pid = std::process::id(),
        "lain-core listening"
    );
    serve_with(listener).await
}

/// Publish the bound port to `<tracing_path>.port`, whose EXISTENCE is the
/// readiness signal the Ruby side polls -- hence only ever after a successful
/// bind, since a file that appears first is a race rather than an optimization.
///
/// The rename is what makes it atomic, and that is not fastidiousness: an
/// ephemeral vsock port is a ten-digit number near `u32::MAX`, so every PREFIX
/// of one parses cleanly as an integer. A reader catching a streamed write
/// mid-flight would get `2`, `29`, `295`... with no parse error to rescue and
/// no way to tell it was short-changed, so the failure mode is a silently wrong
/// port and a baffling connect failure downstream. The temp file is a sibling
/// because `rename(2)` is atomic only within one filesystem.
///
/// Bare decimal, no padding: Ruby reads `Integer("012345")` as octal.
fn publish_port(tracing_path: &str, port: u32) -> std::io::Result<()> {
    let published = port_path(tracing_path);
    let staged = format!("{published}.{}.tmp", std::process::id());
    std::fs::write(&staged, port.to_string())?;
    std::fs::rename(&staged, &published)
}

/// One definition of the published path, so the pre-bind clear and the publish
/// cannot drift apart -- if they ever named different files, the clear would
/// silently stop protecting anything.
fn port_path(tracing_path: &str) -> String {
    format!("{tracing_path}.port")
}

/// The shutdown race, factored out of `serve_forever` because `rpc::serve` is
/// generic over its listener: the two listeners are different types, so one
/// `let listener = if ...` would not type-check. Monomorphized per scheme, and
/// `serve` still returns `Infallible`, so `match never {}` survives.
async fn serve_with(listener: impl Accept) -> ExitCode {
    tokio::select! {
        never = rpc::serve(listener) => match never {},
        code = shutdown_signal() => code,
    }
}

/// Legal here, rather than in `rpc`, precisely because `Accept` is crate-local:
/// `VsockListener` is a foreign type, so an orphan-rule-bound foreign trait
/// could never have carried this impl.
///
/// Cancel-safe as the trait requires -- `VsockListener::accept` is a `poll_fn`
/// over a `poll_accept` that takes the connection and wraps it inside a single
/// poll, so a dropped future never strands a connection off the kernel's queue.
impl Accept for VsockListener {
    type Connection = VsockStream;

    async fn accept(&self) -> std::io::Result<VsockStream> {
        VsockListener::accept(self)
            .await
            .map(|(stream, _address)| stream)
    }
}

/// SIGTERM/SIGINT land here so shutdown goes THROUGH the runtime: returning
/// unwinds `#[tokio::main]`, the runtime drops every in-flight task, and each
/// dropped exec task drops its `Child`, whose `kill_on_drop` fires. Dying to
/// the default signal disposition instead would skip all Drop glue and orphan
/// running children (probe_lifecycle: a `sleep 600` survived the daemon's
/// TERM).
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
        // No handler means no orderly path for this signal; log it and let
        // the other arm (or the default disposition) end the process.
        Err(error) => {
            tracing::error!(%error, "could not install a signal handler");
            std::future::pending::<()>().await;
        }
    }
}

// The SIGTERM/lifecycle contract is tested in tests/lifecycle.rs: it must
// drive the REAL binary (signal dispositions are process-wide), and only an
// integration test gets a guaranteed-fresh build of it via CARGO_BIN_EXE --
// a `target/debug/lain-core` found by path can be stale under `cargo test`,
// which builds the bin's test harness but not the plain binary.
