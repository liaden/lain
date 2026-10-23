//! A seccomp filter for what Landlock's path and TCP rights cannot name.
//!
//! An executable memfd has no path a grant can name: a fenced process can
//! write any ELF into one and execveat(2) it. So memfd_create(2) is refused
//! unless the caller asks for `MFD_NOEXEC_SEAL`, which makes the memfd
//! unexecutable for its whole life.
//!
//! Landlock governs plain TCP connect and bind and nothing else on the
//! network, and seccomp can match a socket's domain, type and protocol but
//! never its address. So socket(2) is an allowlist: AF_UNIX and AF_NETLINK
//! open freely, AF_INET and AF_INET6 only as SOCK_STREAM with protocol 0 or
//! IPPROTO_TCP, and every other family, type and protocol is refused. A deny
//! list kept missing one: on kernel 7.1 with ABI 9, MPTCP and SMC over
//! AF_INET both connected to a port no grant named. TCP Fast Open connects
//! inside sendto, sendmsg and sendmmsg, past Landlock's connect hook, so any
//! send carrying `MSG_FASTOPEN` is refused, and so is setsockopt(2) of
//! `TCP_FASTOPEN_CONNECT`, a deferred Fast Open nothing fenced needs. io_uring can open and use sockets
//! without socket(2), so it is refused outright.

use std::collections::BTreeMap;

use nix::libc::{
    AF_INET, AF_INET6, AF_NETLINK, AF_UNIX, EPERM, IPPROTO_TCP, MFD_NOEXEC_SEAL, MSG_FASTOPEN,
    SOCK_CLOEXEC, SOCK_NONBLOCK, SOCK_STREAM, SYS_io_uring_enter, SYS_io_uring_register,
    SYS_io_uring_setup, SYS_memfd_create, SYS_sendmmsg, SYS_sendmsg, SYS_sendto, SYS_setsockopt,
    SYS_socket, TCP_FASTOPEN_CONNECT, c_int,
};
use seccompiler::{
    BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
    SeccompRule,
};

pub const MEMFD_NOEXEC: &str = "memfd_noexec";
pub const INET_SOCKET_TYPES: &str = "inet_socket_types";
pub const IO_URING: &str = "io_uring";

/// x32 calls carry this bit and pass the x86_64 arch check, so each refused
/// number is refused with it set as well.
#[cfg(target_arch = "x86_64")]
const X32_SYSCALL_BIT: i64 = 0x4000_0000;

/// x32 reaches sendmsg, sendmmsg and setsockopt through compat numbers of its
/// own, not through the native numbers with the x32 bit set.
#[cfg(target_arch = "x86_64")]
const X32_SENDMSG: i64 = 518 | X32_SYSCALL_BIT;
#[cfg(target_arch = "x86_64")]
const X32_SENDMMSG: i64 = 538 | X32_SYSCALL_BIT;
#[cfg(target_arch = "x86_64")]
const X32_SETSOCKOPT: i64 = 541 | X32_SYSCALL_BIT;

type Rules = BTreeMap<i64, Vec<SeccompRule>>;

/// Irreversible, like the Landlock domain. A kernel older than 6.3 has no
/// `MFD_NOEXEC_SEAL` and fails the sealed call itself, so no memfd is usable
/// there: a tool that needs one fails loudly rather than getting an executable
/// one, and the filter still counts as enforced.
pub fn install() -> Result<(), seccompiler::Error> {
    seccompiler::apply_filter_all_threads(&filter()?)
}

/// seccompiler kills the process on any syscall from a foreign arch, which
/// closes the i386 `int 0x80` route around every rule here. It also means a
/// 32-bit tool dies with SIGSYS under the fence, not with a 125, 126 or 127 exit.
fn filter() -> Result<BpfProgram, seccompiler::Error> {
    let mut rules = Rules::new();
    refuse(&mut rules, SYS_memfd_create, memfd_noexec()?);
    refuse(&mut rules, SYS_socket, unlisted_sockets()?);
    refuse(&mut rules, SYS_sendto, fast_open(3)?);
    refuse(&mut rules, SYS_sendmmsg, fast_open(3)?);
    refuse(&mut rules, SYS_sendmsg, fast_open(2)?);
    refuse(&mut rules, SYS_setsockopt, fast_open_connect()?);
    refuse_x32_compat(&mut rules)?;
    for io_uring in [
        SYS_io_uring_setup,
        SYS_io_uring_enter,
        SYS_io_uring_register,
    ] {
        refuse(&mut rules, io_uring, Vec::new());
    }
    let filter = SeccompFilter::new(
        rules,
        SeccompAction::Allow,
        SeccompAction::Errno(EPERM as u32),
        std::env::consts::ARCH.try_into()?,
    )?;
    Ok(filter.try_into()?)
}

/// An empty rule list refuses the call whatever its arguments.
fn refuse(rules: &mut Rules, number: i64, matching: Vec<SeccompRule>) {
    for number in numbers(number) {
        rules.insert(number, matching.clone());
    }
}

#[cfg(target_arch = "x86_64")]
fn numbers(native: i64) -> [i64; 2] {
    [native, native | X32_SYSCALL_BIT]
}

#[cfg(not(target_arch = "x86_64"))]
fn numbers(native: i64) -> [i64; 1] {
    [native]
}

#[cfg(target_arch = "x86_64")]
fn refuse_x32_compat(rules: &mut Rules) -> Result<(), seccompiler::Error> {
    rules.insert(X32_SENDMSG, fast_open(2)?);
    rules.insert(X32_SENDMMSG, fast_open(3)?);
    rules.insert(X32_SETSOCKOPT, fast_open_connect()?);
    Ok(())
}

#[cfg(not(target_arch = "x86_64"))]
fn refuse_x32_compat(_rules: &mut Rules) -> Result<(), seccompiler::Error> {
    Ok(())
}

fn memfd_noexec() -> Result<Vec<SeccompRule>, seccompiler::Error> {
    let unsealed = argument(1, masked(MFD_NOEXEC_SEAL), 0)?;
    Ok(vec![SeccompRule::new(vec![unsealed])?])
}

/// Each rule is an AND of conditions and the rules are ORed, so "not in this
/// list" is one rule of `Ne` conditions.
fn unlisted_sockets() -> Result<Vec<SeccompRule>, seccompiler::Error> {
    let mut rules = vec![none_of(0, &[AF_UNIX, AF_INET, AF_INET6, AF_NETLINK])?];
    let stream_types = [
        SOCK_STREAM,
        SOCK_STREAM | SOCK_NONBLOCK,
        SOCK_STREAM | SOCK_CLOEXEC,
        SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC,
    ];
    for domain in [AF_INET, AF_INET6] {
        for (index, allowed) in [(1, &stream_types[..]), (2, &[0, IPPROTO_TCP][..])] {
            let mut conditions = vec![argument(0, SeccompCmpOp::Eq, domain)?];
            conditions.extend(none_of_conditions(index, allowed)?);
            rules.push(SeccompRule::new(conditions)?);
        }
    }
    Ok(rules)
}

fn fast_open(flags_index: u8) -> Result<Vec<SeccompRule>, seccompiler::Error> {
    let fast_open = argument(
        flags_index,
        masked(MSG_FASTOPEN.unsigned_abs()),
        MSG_FASTOPEN,
    )?;
    Ok(vec![SeccompRule::new(vec![fast_open])?])
}

fn fast_open_connect() -> Result<Vec<SeccompRule>, seccompiler::Error> {
    Ok(vec![SeccompRule::new(vec![
        argument(1, SeccompCmpOp::Eq, IPPROTO_TCP)?,
        argument(2, SeccompCmpOp::Eq, TCP_FASTOPEN_CONNECT)?,
    ])?])
}

fn none_of(index: u8, allowed: &[c_int]) -> Result<SeccompRule, seccompiler::Error> {
    Ok(SeccompRule::new(none_of_conditions(index, allowed)?)?)
}

fn none_of_conditions(
    index: u8,
    allowed: &[c_int],
) -> Result<Vec<SeccompCondition>, seccompiler::Error> {
    allowed
        .iter()
        .map(|value| argument(index, SeccompCmpOp::Ne, *value))
        .collect()
}

fn masked(mask: u32) -> SeccompCmpOp {
    SeccompCmpOp::MaskedEq(u64::from(mask))
}

/// Every value compared here is a non-negative kernel constant, and every
/// argument is an int, so the low 32 bits are the whole of it.
fn argument(
    index: u8,
    op: SeccompCmpOp,
    value: c_int,
) -> Result<SeccompCondition, seccompiler::Error> {
    Ok(SeccompCondition::new(
        index,
        SeccompCmpArgLen::Dword,
        op,
        u64::from(value.unsigned_abs()),
    )?)
}
