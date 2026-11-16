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
//! - `--private-net`: any TCP bind and connect, inside a netns with only lo
//!
//! Without `--private-net`, TCP connect and bind are handled, so with no
//! `--connect-port` the command has no TCP at all, and it can never bind.
//! With it, the fence first refuses (exit 125) unless `/proc/self/net/dev`
//! lists only `lo`, then leaves Landlock's net rights unhandled, since no rule
//! can grant every port; the netns is the boundary, and nothing routes out of
//! it. It takes no `--connect-port`. The socket filter below still applies. Abstract Unix sockets and
//! signals are always scoped to the domain. A seccomp filter refuses
//! memfd_create(2) without `MFD_NOEXEC_SEAL`, since a memfd is executable
//! code no path grant can name; the status line reports it as `memfd_noexec`.
//! The same filter allows only Unix and netlink sockets and plain TCP over
//! IPv4 and IPv6, since Landlock governs TCP alone; it refuses any send with
//! `MSG_FASTOPEN`, which connects past Landlock, and the `TCP_FASTOPEN_CONNECT`
//! socket option; it refuses io_uring. Those read `inet_socket_types` and
//! `io_uring`.
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
//! granted paths that could not be opened, which therefore granted nothing, and
//! `"reap": true` says this build takes `--reap-only`. `private_net` says
//! whether `--private-net` is in force; its presence says the build takes it.
//!
//! `--reap-only -- cmd args...` takes no other flag, applies no domain and no
//! filter, and runs `cmd` as a child rather than exec'ing it, falling back to
//! `/bin/sh` for a file with no shebang as execvp does. On TERM, INT or HUP it
//! sends that signal to every process descended from it, re-setsid or not,
//! gives them a grace to exit, kills what is left, then dies of that signal.
//! When `cmd` exits on its own, its background children live on and the fence
//! exits with `cmd`'s status; an orphan that exits first is reaped meanwhile.
//! Inherited fds are closed still.
//!
//! Exit codes: 125 for a bad invocation, 126 when Landlock enforces nothing,
//! 127 when the exec itself fails. The command can exit 126 or 127 itself; only
//! the fence's own failures, and a seccomp filter it could not install, write a
//! `lain-fence:` line to stderr.
#![forbid(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr)]

#[cfg(target_os = "linux")]
mod linux_main;
#[cfg(target_os = "linux")]
mod netns;
#[cfg(target_os = "linux")]
mod reap;
#[cfg(target_os = "linux")]
mod rules;
#[cfg(target_os = "linux")]
mod seccomp;
#[cfg(target_os = "linux")]
mod status;

#[cfg(target_os = "linux")]
fn main() -> std::process::ExitCode {
    linux_main::main()
}

#[cfg(not(target_os = "linux"))]
#[expect(
    clippy::print_stderr,
    reason = "a caller reads why the fence did not run from its stderr"
)]
fn main() -> std::process::ExitCode {
    eprintln!("lain-fence: Linux only");
    std::process::ExitCode::from(2)
}
