//! lain-core: the msgpack-RPC wire seed.
//!
//! A msgpack-RPC server on a Unix socket, kept as the Ruby-to-Rust wire that a
//! phone relay and a code-mode handle store will grow methods on. Run plain it
//! answers `ping` and nothing else; run as `relay` it is the phone relay
//! (`relay.rs`). The socket path arrives via argv -- this
//! binary NEVER computes its own path; path policy belongs to Ruby
//! (`Paths#runtime_dir`). Tracing goes to a file path given by argv, or
//! /dev/null when absent, and never to an inherited terminal: the Journal is
//! NDJSON and one stray diagnostic line interleaved into it breaks the
//! experiment record (the wound stays closed).
//!
//! Nothing in this crate is a sandbox.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr)]

mod relay;

use std::process::ExitCode;

use lain_rpc::{Handler, RpcError};
use rmpv::Value;

/// Bad invocation or an unopenable tracing path. There is no usage text on
/// purpose: this binary may never touch stdout/stderr, so a bad invocation is
/// an exit code, not a message.
const USAGE_ERROR: u8 = 2;
/// The socket could not be bound (stale file, missing dir, permissions).
const BIND_ERROR: u8 = 1;
/// The relay could not confine itself, so it did not run.
const CONFINE_ERROR: u8 = 3;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(socket_path) = args.next() else {
        return ExitCode::from(USAGE_ERROR);
    };
    if socket_path == "relay" {
        return relay(args);
    }
    let tracing_path = args.next();
    if init_tracing(tracing_path.as_deref().unwrap_or("/dev/null")).is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    serve_unix(&socket_path)
}

/// The Ruby wire seed: `ping` and nothing else.
struct Core;

impl Handler for Core {
    type Session = ();

    async fn call(&self, _: &(), method: &str, _params: Vec<Value>) -> Result<Value, RpcError> {
        Err(RpcError::UnknownMethod(method.to_string()))
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
async fn serve_unix(socket_path: &str) -> ExitCode {
    match tokio::net::UnixListener::bind(socket_path) {
        Ok(listener) => {
            tracing::info!(socket_path, pid = std::process::id(), "lain-core listening");
            tokio::select! {
                never = lain_rpc::serve(listener, Core, env!("CARGO_PKG_VERSION")) => match never {},
                code = shutdown_signal() => code,
            }
        }
        Err(error) => {
            tracing::error!(%error, socket_path, "could not bind the socket");
            ExitCode::from(BIND_ERROR)
        }
    }
}

/// `lain-core relay --unix <sock> --listen <addr>:<port> --devices-file <path> [--trace <path>]`.
///
/// Binds both listeners and reads the paired devices, then confines the process while
/// it is still one thread: Landlock binds the calling thread and the threads
/// it spawns after, so the runtime's workers start inside the ruleset.
fn relay(args: impl Iterator<Item = String>) -> ExitCode {
    let Some(config) = relay::Config::parse(args) else {
        return ExitCode::from(USAGE_ERROR);
    };
    if init_tracing(config.trace.as_deref().unwrap_or("/dev/null")).is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    let started = relay::Bound::open(&config).and_then(|bound| {
        relay::confine(bound.devices_directory(), config.socket_dir()).inspect_err(|_| {
            let _ = std::fs::remove_file(&config.unix);
        })?;
        Ok(bound)
    });
    match started {
        Ok(bound) => serve_relay(bound, &config.unix),
        Err(error) => {
            tracing::error!(%error, "the relay did not start");
            ExitCode::from(error.exit_code())
        }
    }
}

#[tokio::main]
async fn serve_relay(bound: relay::Bound, socket: &std::path::Path) -> ExitCode {
    let code = match bound.serve() {
        Ok(relay) => {
            tracing::info!(pid = std::process::id(), "lain-core relay listening");
            tokio::select! {
                never = relay => match never {},
                code = shutdown_signal() => code,
            }
        }
        Err(error) => {
            tracing::error!(%error, "could not adopt the relay's listeners");
            ExitCode::from(BIND_ERROR)
        }
    };
    if let Err(error) = std::fs::remove_file(socket) {
        tracing::warn!(%error, "could not remove the relay's socket");
    }
    code
}

/// SIGTERM/SIGINT land here so shutdown goes THROUGH the runtime: returning
/// unwinds `#[tokio::main]` and the runtime drops every in-flight task with
/// its Drop glue. Dying to the default signal disposition would skip that,
/// which is how an earlier exec method orphaned its children; a future method
/// that owns a resource gets the same guarantee for free.
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
