//! lain-fence: run one command inside a Landlock domain built from argv.
//!
//! `lain-fence [grants] -- cmd args...` restricts itself, then execs `cmd`, so
//! the command and everything it spawns inherit the domain. The grants:
//!
//! - `--exec-dir D`: run and read files beneath D
//! - `--exec-file F`: run and read exactly F, a regular file
//! - `--read-dir D`: read files and list directories beneath D
//! - `--write-dir D`: read and write beneath D
//! - `--unix-dir D`: connect to Unix sockets beneath D
//! - `--connect-port P`: TCP connect to port P
//!
//! TCP connect and bind are always handled, so with no `--connect-port` the
//! command has no TCP at all, and it can never bind. Abstract Unix sockets and
//! signals are always scoped to the domain. A seccomp filter refuses
//! memfd_create(2) without `MFD_NOEXEC_SEAL`, since a memfd is executable
//! code no path grant can name; the status line reports it as `memfd_noexec`.
//! The filter kills any syscall from a foreign arch, so a 32-bit tool dies
//! with SIGSYS and no `lain-fence:` line, never with a 125, 126 or 127 exit.
//!
//! `Execute` governs execve(2) only. A granted loader such as `ld.so` runs any
//! ELF the command can read, so a read grant is an exec grant in practice.
//!
//! Every inherited fd above stderr is closed before the exec, so the command
//! cannot write forged lines into a trace or status pipe its caller reads.
//!
//! `--status` reports what the kernel would enforce for those grants, as one
//! JSON line on stdout, and runs nothing. `--status-fd N` (3 or above) writes
//! the same line to fd N just before the exec. `skipped` in that line lists the
//! granted paths that could not be opened, which therefore granted nothing.
//!
//! Exit codes: 125 for a bad invocation, 126 when Landlock enforces nothing,
//! 127 when the exec itself fails. The command can exit 126 or 127 itself; only
//! the fence's own failures, and a seccomp filter it could not install, write a
//! `lain-fence:` line to stderr.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr)]

mod rules;
mod seccomp;
mod status;

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode};

use landlock::RulesetStatus;
use rules::Grants;

const USAGE_ERROR: u8 = 125;
const NOT_ENFORCED: u8 = 126;
const EXEC_FAILED: u8 = 127;

enum Mode {
    Status,
    Exec {
        argv: Vec<String>,
        status_fd: Option<RawFd>,
    },
}

struct Invocation {
    grants: Grants,
    mode: Mode,
}

fn main() -> ExitCode {
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
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--" => argv = args.by_ref().collect(),
            "--status" => status = true,
            "--status-fd" => status_fd = Some(above_stdio(&flag, args.next())?),
            "--connect-port" => grants.connect_ports.push(number(&flag, args.next())?),
            "--exec-dir" => grants.exec_dirs.push(value(&flag, args.next())?),
            "--exec-file" => grants.exec_files.push(value(&flag, args.next())?),
            "--read-dir" => grants.read_dirs.push(value(&flag, args.next())?),
            "--write-dir" => grants.write_dirs.push(value(&flag, args.next())?),
            "--unix-dir" => grants.unix_dirs.push(value(&flag, args.next())?),
            _ => return Err(format!("unknown argument {flag}")),
        }
    }
    let mode = match (status, status_fd, argv.is_empty()) {
        (true, None, true) => Mode::Status,
        (true, _, _) => return Err("--status runs nothing and takes no --status-fd".into()),
        (false, _, true) => return Err("no command after --".into()),
        (false, status_fd, false) => Mode::Exec { argv, status_fd },
    };
    Ok(Invocation { grants, mode })
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
    }
}

fn report(grants: &Grants) -> ExitCode {
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

fn enforce(grants: &Grants) -> Result<rules::Enforcement, rules::Error> {
    let mut enforcement = grants.restrict_self()?;
    let loaded = seccomp::install()
        .inspect_err(|error| complain(&format!("seccomp filter not installed: {error}")))
        .is_ok();
    enforcement
        .status
        .seccomp_verdict(seccomp::MEMFD_NOEXEC, loaded);
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

fn fail(code: u8, message: &str) -> ExitCode {
    complain(message);
    ExitCode::from(code)
}

#[expect(
    clippy::print_stderr,
    reason = "the fenced command's stderr is where its caller reads why it did not run, or ran with less"
)]
fn complain(message: &str) {
    eprintln!("lain-fence: {message}");
}
