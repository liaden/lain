//! lain-core: the out-of-process exec daemon.
//!
//! A msgpack-RPC server on a Unix socket. The socket path arrives via argv --
//! this binary NEVER computes its own path; path policy belongs to Ruby
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

/// Bad invocation or an unopenable tracing path. There is no usage text on
/// purpose: this binary may never touch stdout/stderr, so a bad invocation is
/// an exit code, not a message.
const USAGE_ERROR: u8 = 2;
/// The socket could not be bound (stale file, missing dir, permissions).
const BIND_ERROR: u8 = 1;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(socket_path) = args.next() else {
        return ExitCode::from(USAGE_ERROR);
    };
    let tracing_path = args.next().unwrap_or_else(|| "/dev/null".to_string());
    if init_tracing(&tracing_path).is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    serve_forever(socket_path)
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
async fn serve_forever(socket_path: String) -> ExitCode {
    let listener = match tokio::net::UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(error) => {
            tracing::error!(%error, socket_path, "could not bind the socket");
            return ExitCode::from(BIND_ERROR);
        }
    };
    tracing::info!(socket_path, pid = std::process::id(), "lain-core listening");
    tokio::select! {
        never = rpc::serve(listener) => match never {},
        code = shutdown_signal() => code,
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
