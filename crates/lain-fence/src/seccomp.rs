//! A seccomp filter that refuses an executable memfd.
//!
//! Landlock's Execute right governs paths, and a memfd has none a grant can
//! name: a fenced process can write any ELF into one and execveat(2) it. So
//! memfd_create(2) is refused unless the caller asks for `MFD_NOEXEC_SEAL`,
//! which makes the memfd unexecutable for its whole life.

use std::collections::BTreeMap;

use nix::libc::{EPERM, MFD_NOEXEC_SEAL, SYS_memfd_create};
use seccompiler::{
    BpfProgram, SeccompAction, SeccompCmpArgLen, SeccompCmpOp, SeccompCondition, SeccompFilter,
    SeccompRule,
};

pub const MEMFD_NOEXEC: &str = "memfd_noexec";

/// x32 calls carry this bit and pass the x86_64 arch check, so its number for
/// memfd_create is refused alongside the native one.
#[cfg(target_arch = "x86_64")]
const X32_SYSCALL_BIT: i64 = 0x4000_0000;

/// Irreversible, like the Landlock domain.
///
/// The rule is the same on every kernel. One older than 6.3 has no
/// `MFD_NOEXEC_SEAL` and fails the sealed call itself, so no memfd is usable
/// there: a tool that needs a memfd fails loudly rather than getting an
/// executable one, and the filter still counts as enforced.
pub fn install() -> Result<(), seccompiler::Error> {
    seccompiler::apply_filter_all_threads(&memfd_noexec()?)
}

/// seccompiler kills the process on any syscall from a foreign arch, which
/// closes the i386 `int 0x80` route to memfd_create. It also means a 32-bit
/// tool dies with SIGSYS under the fence, not with a 125, 126 or 127 exit.
fn memfd_noexec() -> Result<BpfProgram, seccompiler::Error> {
    let unsealed = SeccompCondition::new(
        1,
        SeccompCmpArgLen::Dword,
        SeccompCmpOp::MaskedEq(u64::from(MFD_NOEXEC_SEAL)),
        0,
    )?;
    let rules: BTreeMap<i64, Vec<SeccompRule>> = refused_numbers()
        .into_iter()
        .map(|number| Ok((number, vec![SeccompRule::new(vec![unsealed.clone()])?])))
        .collect::<Result<_, seccompiler::Error>>()?;
    let filter = SeccompFilter::new(
        rules,
        SeccompAction::Allow,
        SeccompAction::Errno(EPERM as u32),
        std::env::consts::ARCH.try_into()?,
    )?;
    Ok(filter.try_into()?)
}

#[cfg(target_arch = "x86_64")]
fn refused_numbers() -> Vec<i64> {
    vec![SYS_memfd_create, SYS_memfd_create | X32_SYSCALL_BIT]
}

#[cfg(not(target_arch = "x86_64"))]
fn refused_numbers() -> Vec<i64> {
    vec![SYS_memfd_create]
}
