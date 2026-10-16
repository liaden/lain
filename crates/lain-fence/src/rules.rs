//! The command line's grants, turned into a Landlock domain on this process.
//!
//! Every filesystem right is handled, so anything not granted here is refused:
//! the grants are an allowlist, never a denylist.

use std::fs::{File, FileType, OpenOptions};
use std::os::unix::fs::OpenOptionsExt;

use landlock::{
    ABI, Access, AccessFs, AccessNet, BitFlags, NetPort, PathBeneath, Ruleset, RulesetAttr,
    RulesetCreated, RulesetCreatedAttr, RulesetError, RulesetStatus, Scope,
};
use nix::fcntl::OFlag;

use crate::status::{Requested, Status};

/// Pinned rather than read from the kernel, so an older kernel drops the newer
/// rights visibly in the status line instead of the request shrinking to fit.
const TARGET: ABI = ABI::V9;

#[derive(Default)]
pub struct Grants {
    pub exec_dirs: Vec<String>,
    pub exec_files: Vec<String>,
    pub read_dirs: Vec<String>,
    pub write_dirs: Vec<String>,
    pub unix_dirs: Vec<String>,
    pub connect_ports: Vec<u16>,
}

pub struct Enforcement {
    pub status: Status,
    pub ruleset: RulesetStatus,
}

#[derive(Debug)]
pub enum Error {
    /// An `--exec-file` that is a directory would grant everything beneath it.
    NotAFile(String, String),
    Ruleset(RulesetError),
}

impl From<RulesetError> for Error {
    fn from(error: RulesetError) -> Self {
        Error::Ruleset(error)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::NotAFile(path, why) => write!(f, "--exec-file {path}: {why}"),
            Error::Ruleset(error) => write!(f, "landlock: {error}"),
        }
    }
}

impl Grants {
    pub fn requested(&self) -> Requested {
        Requested {
            fs: AccessFs::from_all(TARGET),
            net: AccessNet::ConnectTcp | AccessNet::BindTcp,
            scope: Scope::AbstractUnixSocket | Scope::Signal,
        }
    }

    /// Irreversible: this process and everything it execs stay inside the domain.
    pub fn restrict_self(&self) -> Result<Enforcement, Error> {
        let requested = self.requested();
        let ruleset = Ruleset::default()
            .handle_access(requested.fs)?
            .handle_access(requested.net)?
            .scope(requested.scope)?;
        let mut created = ruleset.create()?;
        for port in &self.connect_ports {
            created = created.add_rule(NetPort::new(*port, AccessNet::ConnectTcp))?;
        }
        let mut skipped = Vec::new();
        let read = AccessFs::ReadFile | AccessFs::ReadDir;
        created = beneath(
            created,
            &self.exec_dirs,
            AccessFs::Execute | AccessFs::ReadFile,
            &mut skipped,
        )?;
        created = exact_files(created, &self.exec_files)?;
        created = beneath(created, &self.read_dirs, read, &mut skipped)?;
        created = beneath(
            created,
            &self.write_dirs,
            AccessFs::from_write(TARGET) | read,
            &mut skipped,
        )?;
        created = beneath(
            created,
            &self.unix_dirs,
            AccessFs::ResolveUnix.into(),
            &mut skipped,
        )?;
        let restriction = created.restrict_self()?;
        Ok(Enforcement {
            status: Status::new(&requested, restriction.landlock, &skipped),
            ruleset: restriction.ruleset,
        })
    }
}

/// A path that cannot be opened grants nothing, so it is reported as skipped
/// rather than refused: the command simply gets less.
fn beneath(
    mut created: RulesetCreated,
    paths: &[String],
    access: BitFlags<AccessFs>,
    skipped: &mut Vec<String>,
) -> Result<RulesetCreated, Error> {
    for path in paths {
        match open_path(path) {
            Ok((file, kind)) => {
                // The landlock crate narrows these itself, but records it as a
                // partial enforcement, which a caller may rightly refuse.
                let granted = if kind.is_dir() {
                    access
                } else {
                    access & AccessFs::from_file(TARGET)
                };
                created = created.add_rule(PathBeneath::new(file, granted))?;
            }
            Err(_) => skipped.push(path.clone()),
        }
    }
    Ok(created)
}

fn exact_files(mut created: RulesetCreated, paths: &[String]) -> Result<RulesetCreated, Error> {
    for path in paths {
        let file = match open_path(path) {
            Ok((file, kind)) if kind.is_file() => file,
            Ok(_) => return Err(Error::NotAFile(path.clone(), "not a regular file".into())),
            Err(error) => return Err(Error::NotAFile(path.clone(), error.to_string())),
        };
        created = created.add_rule(PathBeneath::new(
            file,
            AccessFs::Execute | AccessFs::ReadFile,
        ))?;
    }
    Ok(created)
}

/// The kind is read from the opened descriptor, so a path swapped between the
/// check and the rule cannot turn a file grant into a directory grant.
fn open_path(path: &str) -> std::io::Result<(File, FileType)> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(OFlag::O_PATH.bits())
        .open(path)?;
    let kind = file.metadata()?.file_type();
    Ok((file, kind))
}
