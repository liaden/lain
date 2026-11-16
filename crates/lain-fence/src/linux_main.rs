use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

use crate::rules::{self, Grants};
use crate::{netns, reap, seccomp};
use landlock::RulesetStatus;

pub(crate) const USAGE_ERROR: u8 = 125;
pub(crate) const NOT_ENFORCED: u8 = 126;
pub(crate) const EXEC_FAILED: u8 = 127;

enum Mode {
    Status,
    Exec {
        argv: Vec<String>,
        status_fd: Option<RawFd>,
    },
    Reap {
        argv: Vec<String>,
    },
}

struct Invocation {
    grants: Grants,
    mode: Mode,
}

pub(crate) fn main() -> ExitCode {
    match parse(std::env::args().skip(1)) {
        Ok(invocation) => run(invocation),
        Err(message) => fail(USAGE_ERROR, &message),
    }
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Invocation, String> {
    let mut grants = Grants::default();
    let mut status = false;
    let mut status_fd = None;
    let mut argv = Vec::new();
    let mut reap = false;
    let mut flags = Vec::new();
    while let Some(flag) = args.next() {
        if !matches!(flag.as_str(), "--" | "--reap-only") {
            flags.push(flag.clone());
        }
        match flag.as_str() {
            "--" => argv = args.by_ref().collect(),
            "--reap-only" => reap = true,
            "--status" => status = true,
            "--status-fd" => status_fd = Some(above_stdio(&flag, args.next())?),
            "--connect-port" => grants.connect_ports.push(number(&flag, args.next())?),
            "--exec-dir" => grants.exec_dirs.push(value(&flag, args.next())?),
            "--exec-file" => grants.exec_files.push(value(&flag, args.next())?),
            "--read-dir" => grants.read_dirs.push(value(&flag, args.next())?),
            "--write-dir" => grants.write_dirs.push(value(&flag, args.next())?),
            "--unix-dir" => grants.unix_dirs.push(value(&flag, args.next())?),
            "--private-net" => grants.private_net = true,
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    if reap {
        return reap_only(flags, argv).map(|mode| Invocation { grants, mode });
    }
    if grants.private_net && !grants.connect_ports.is_empty() {
        return Err("--private-net grants every port and takes no --connect-port".into());
    }
    let mode = match (status, status_fd, argv.is_empty()) {
        (true, None, true) => Mode::Status,
        (true, _, _) => return Err("--status runs nothing and takes no --status-fd".into()),
        (false, _, true) => return Err("no command after --".into()),
        (false, status_fd, false) => Mode::Exec { argv, status_fd },
    };
    Ok(Invocation { grants, mode })
}

fn reap_only(flags: Vec<String>, argv: Vec<String>) -> Result<Mode, String> {
    if !flags.is_empty() {
        return Err(format!(
            "--reap-only takes no other flag, got {}",
            flags.join(" ")
        ));
    }
    if argv.is_empty() {
        return Err("no command after --".into());
    }
    Ok(Mode::Reap { argv })
}

fn value(flag: &str, next: Option<String>) -> Result<String, String> {
    next.ok_or_else(|| format!("{flag} needs a value"))
}

fn number<T: std::str::FromStr>(flag: &str, next: Option<String>) -> Result<T, String> {
    let text = value(flag, next)?;
    text.parse()
        .map_err(|_| format!("{flag} {text}: not a valid number"))
}

fn above_stdio(flag: &str, next: Option<String>) -> Result<RawFd, String> {
    let fd: RawFd = number(flag, next)?;
    if fd < 3 {
        return Err(format!(
            "{flag} {fd}: must be 3 or above; 0 to 2 are stdio and a negative fd does not exist"
        ));
    }
    Ok(fd)
}

fn run(invocation: Invocation) -> ExitCode {
    match invocation.mode {
        Mode::Status => report(&invocation.grants),
        Mode::Exec { argv, status_fd } => fence(&invocation.grants, &argv, status_fd),
        Mode::Reap { argv } => match close_inherited(None) {
            Ok(()) => reap::run(&argv),
            Err(message) => fail(NOT_ENFORCED, &message),
        },
    }
}

fn report(grants: &Grants) -> ExitCode {
    if let Err(message) = private_net_holds(grants) {
        return fail(USAGE_ERROR, &message);
    }
    match enforce(grants) {
        Ok(enforcement) => {
            match std::io::stdout().write_all(enforcement.status.line().as_bytes()) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => fail(USAGE_ERROR, &format!("stdout: {error}")),
            }
        }
        Err(error) => refused(&error),
    }
}

fn fence(grants: &Grants, argv: &[String], status_fd: Option<RawFd>) -> ExitCode {
    let sink = match status_fd.map(take_fd).transpose() {
        Ok(sink) => sink,
        Err(message) => return fail(USAGE_ERROR, &message),
    };
    if let Err(message) = private_net_holds(grants) {
        return fail(USAGE_ERROR, &message);
    }
    if let Err(message) = close_inherited(sink.as_ref().map(AsRawFd::as_raw_fd)) {
        return fail(NOT_ENFORCED, &message);
    }
    let enforcement = match enforce(grants) {
        Ok(enforcement) => enforcement,
        Err(error) => return refused(&error),
    };
    if let Some(mut sink) = sink
        && let Err(error) = sink.write_all(enforcement.status.line().as_bytes())
    {
        return fail(USAGE_ERROR, &format!("--status-fd: {error}"));
    }
    if enforcement.ruleset == RulesetStatus::NotEnforced {
        return fail(NOT_ENFORCED, "landlock enforced nothing on this kernel");
    }
    let error = Command::new(&argv[0]).args(&argv[1..]).exec();
    fail(EXEC_FAILED, &format!("exec {}: {error}", argv[0]))
}

fn private_net_holds(grants: &Grants) -> Result<(), String> {
    if grants.private_net {
        netns::ensure_only_loopback()?;
    }
    Ok(())
}

fn enforce(grants: &Grants) -> Result<rules::Enforcement, rules::Error> {
    let mut enforcement = grants.restrict_self()?;
    let loaded = seccomp::install()
        .inspect_err(|error| complain(&format!("seccomp filter not installed: {error}")))
        .is_ok();
    for verdict in [
        seccomp::MEMFD_NOEXEC,
        seccomp::INET_SOCKET_TYPES,
        seccomp::IO_URING,
    ] {
        enforcement.status.seccomp_verdict(verdict, loaded);
    }
    Ok(enforcement)
}

fn refused(error: &rules::Error) -> ExitCode {
    let code = match error {
        rules::Error::NotAFile(..) => USAGE_ERROR,
        rules::Error::Ruleset(_) => NOT_ENFORCED,
    };
    fail(code, &error.to_string())
}

/// Reopened through /proc because that needs no unsafe, and before the domain
/// exists to refuse the open. The reopened file is close-on-exec.
fn take_fd(fd: RawFd) -> Result<File, String> {
    OpenOptions::new()
        .append(true)
        .open(format!("/proc/self/fd/{fd}"))
        .map_err(|error| format!("--status-fd {fd}: {error}"))
}

/// Listed through /proc before the domain exists, since close_range(2) has no
/// safe wrapper. A close error is ignored: the listing's own fd is already gone
/// by then, and Linux releases the fd even when close reports a failure.
fn close_inherited(keep: Option<RawFd>) -> Result<(), String> {
    let open: Vec<RawFd> = std::fs::read_dir("/proc/self/fd")
        .map_err(|error| format!("listing inherited fds: {error}"))?
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
        .filter(|fd| *fd > 2 && Some(*fd) != keep)
        .collect();
    for fd in open {
        let _ = nix::unistd::close(fd);
    }
    Ok(())
}

pub(crate) fn fail(code: u8, message: &str) -> ExitCode {
    complain(message);
    ExitCode::from(code)
}

#[expect(
    clippy::print_stderr,
    reason = "the fenced command's stderr is where its caller reads why it did not run, or ran with less"
)]
pub(crate) fn complain(message: &str) {
    eprintln!("lain-fence: {message}");
}
