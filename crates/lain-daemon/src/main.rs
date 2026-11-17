//! lain-daemon: the per-user daemon, a msgpack-RPC server on a Unix socket.
//!
//! The socket path, trace path and launch digest all arrive via argv: this binary NEVER computes
//! its own path, because path policy belongs to Ruby (`Paths#runtime_dir`). Tracing goes to a file,
//! never a terminal: the Journal is NDJSON and one stray diagnostic line breaks the experiment record.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr, missing_docs)]

use std::io;
use std::os::unix::fs::FileTypeExt;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use lain_rpc::{Handler, RpcError};
use rmpv::Value;

/// Bad invocation or an unopenable trace path. There is no usage text on purpose: this binary
/// may never touch stdout/stderr, so a bad invocation is an exit code, not a message.
const USAGE_ERROR: u8 = 2;
/// The socket could not be bound, or a live daemon already holds it.
const BIND_ERROR: u8 = 1;

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
}

impl Args {
    fn parse(mut args: impl Iterator<Item = String>) -> Option<Self> {
        let (mut socket, mut trace, mut launch_digest) = (None, None, None);
        while let Some(flag) = args.next() {
            let value = args.next()?;
            match flag.as_str() {
                "--socket" => socket = Some(PathBuf::from(value)),
                "--trace" => trace = Some(PathBuf::from(value)),
                "--launch-digest" => launch_digest = Some(value),
                _ => return None,
            }
        }
        Some(Self {
            socket: socket?,
            trace,
            launch_digest: launch_digest?,
        })
    }
}

fn main() -> ExitCode {
    let Some(args) = Args::parse(std::env::args().skip(1)) else {
        return ExitCode::from(USAGE_ERROR);
    };
    let trace = args.trace.as_deref().unwrap_or(Path::new("/dev/null"));
    if init_tracing(trace).is_err() {
        return ExitCode::from(USAGE_ERROR);
    }
    serve_unix(args)
}

/// What the daemon answers beyond `ping`, which `lain_rpc::serve` answers itself.
struct Daemon {
    launch_digest: String,
}

impl Handler for Daemon {
    type Session = ();

    async fn call(&self, _: &(), method: &str, _params: Vec<Value>) -> Result<Value, RpcError> {
        match method {
            "daemon.info" => Ok(Value::Map(vec![
                (Value::from("build_id"), Value::from(build_id())),
                (
                    Value::from("launch_digest"),
                    Value::from(self.launch_digest.as_str()),
                ),
            ])),
            other => Err(RpcError::UnknownMethod(other.to_string())),
        }
    }
}

fn init_tracing(path: &Path) -> io::Result<()> {
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
        .and_then(|()| tokio::net::UnixListener::bind(&args.socket));
    let listener = match bound {
        Ok(listener) => listener,
        Err(error) => {
            tracing::error!(%error, socket = %args.socket.display(), "could not bind the socket");
            return ExitCode::from(BIND_ERROR);
        }
    };
    tracing::info!(socket = %args.socket.display(), pid = std::process::id(), "lain-daemon listening");
    let handler = Daemon {
        launch_digest: args.launch_digest,
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
    use super::*;

    #[test]
    fn an_empty_or_missing_sha_reads_unknown() {
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", Some("")));
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", None));
        assert_eq!("0.1.0 abc123", build_id_of("0.1.0", Some("abc123")));
    }
}
