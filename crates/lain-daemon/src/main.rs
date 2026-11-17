//! lain-daemon: the per-user daemon, a msgpack-RPC server on a Unix socket.
//!
//! The socket path, trace path and launch digest all arrive via argv: this binary NEVER computes
//! its own path, because path policy belongs to Ruby (`Paths#runtime_dir`). Tracing goes to a file,
//! never a terminal: the Journal is NDJSON and one stray diagnostic line breaks the experiment record.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr, missing_docs)]

mod registry;

use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, OnceLock};

use lain_rpc::{Conn, Handler, Peer, RpcError, Session};
use lain_wire::Register;
use rmpv::Value;

use registry::{Registration, Registry};

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

/// What the daemon answers beyond `ping`, which `lain_rpc::serve` answers itself. No local
/// method answers an approval or a question: answers come only from the phone or the chat itself.
struct Daemon {
    launch_digest: String,
    registry: Arc<Registry>,
    owner_uid: u32,
}

/// One local connection: who is on the other end, and the session it registered, if any.
struct Caller {
    peer: Peer,
    registration: OnceLock<Registration>,
}

impl Session for Caller {
    fn opened(conn: &Conn) -> Self {
        Self {
            peer: conn.peer,
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
            ])),
            "session.register" => self.register(caller, params).await.inspect_err(|error| {
                if let RpcError::Refused { code, message } = error {
                    tracing::warn!(code, peer = ?caller.peer, ?message, "refused a session.register");
                }
            }),
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
    let handler = Daemon {
        launch_digest: args.launch_digest,
        registry: Registry::new(registry::ProcTable),
        owner_uid,
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
    use super::*;

    const OWNER: u32 = 1000;

    fn caller(uid: Option<u32>) -> Caller {
        Caller {
            peer: Peer {
                uid,
                pid: Some(std::process::id()),
            },
            registration: OnceLock::new(),
        }
    }

    #[tokio::test]
    async fn a_peer_of_another_user_or_of_no_known_user_is_refused_every_method() {
        let daemon = Daemon {
            launch_digest: "abc".to_string(),
            registry: Registry::new(registry::ProcTable),
            owner_uid: OWNER,
        };
        for uid in [Some(0), Some(OWNER + 1), None] {
            for method in [
                "daemon.info",
                "session.list",
                "session.register",
                "answer.send",
            ] {
                match daemon.call(&caller(uid), method, vec![]).await {
                    Err(RpcError::Refused {
                        code: "other_user", ..
                    }) => {}
                    other => panic!("uid {uid:?} {method}: {other:?}"),
                }
            }
        }
        assert!(
            daemon
                .call(&caller(Some(OWNER)), "daemon.info", vec![])
                .await
                .is_ok()
        );
    }

    #[test]
    fn an_empty_or_missing_sha_reads_unknown() {
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", Some("")));
        assert_eq!("0.1.0 unknown", build_id_of("0.1.0", None));
        assert_eq!("0.1.0 abc123", build_id_of("0.1.0", Some("abc123")));
    }
}
