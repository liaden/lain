//! The paired phones: a file of device names and token digests that
//! `lain remote pair` and `lain remote revoke` rewrite, and the relay rereads.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use subtle::ConstantTimeEq;
use tokio::sync::watch;

/// Why the devices file or its directory was refused. Never names a digest.
#[derive(Debug, thiserror::Error)]
pub(crate) enum DevicesError {
    #[error("cannot read {}: {error}", path.display())]
    Unreadable { path: PathBuf, error: io::Error },
    #[error("the devices file {} is a symlink", .0.display())]
    Symlink(PathBuf),
    #[error("the devices file {} is open to group or others (mode {mode:o}); it must be 600", path.display())]
    Open { path: PathBuf, mode: u32 },
    #[error("line {line} of the devices file {} is not a device name and a token digest", path.display())]
    Malformed { path: PathBuf, line: usize },
    #[error("the devices file's directory {} is a symlink", .0.display())]
    DirectoryLinked(PathBuf),
    #[error(
        "the devices file's directory {} holds {entry}; it must hold only the devices file \
         and its staged writes, each a regular file with 1 link, because the relay may read \
         anything in it",
        directory.display()
    )]
    DirectoryShared { directory: PathBuf, entry: String },
}

/// The file `lain remote` rewrites by renaming a whole new one over it.
pub(crate) struct DevicesFile {
    path: PathBuf,
}

/// What changes when the file is replaced or rewritten.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    modified: (i64, i64),
    len: u64,
}

impl DevicesFile {
    pub(crate) fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    /// The relay is granted reads beneath this directory, not the file: a
    /// rename puts a new inode at the path, and a grant on the old one would
    /// lock the relay out after the first pair.
    pub(crate) fn directory(&self) -> &Path {
        self.path
            .parent()
            .filter(|dir| !dir.as_os_str().is_empty())
            .unwrap_or(Path::new("."))
    }

    /// The directory holds the file and the dot-prefixed files `lain remote`
    /// stages its writes in, and nothing else the relay's grant would expose:
    /// a subdirectory, a symlink, or a second link to a file elsewhere would
    /// each put that file under the grant.
    pub(crate) fn check_directory(&self) -> Result<(), DevicesError> {
        use std::os::unix::fs::MetadataExt;
        let directory = self.directory();
        let unreadable = |error| DevicesError::Unreadable {
            path: directory.to_path_buf(),
            error,
        };
        if std::fs::symlink_metadata(directory)
            .map_err(unreadable)?
            .file_type()
            .is_symlink()
        {
            return Err(DevicesError::DirectoryLinked(directory.to_path_buf()));
        }
        let name = self.path.file_name().unwrap_or_default().to_string_lossy();
        let staged = format!(".{name}.");
        for entry in std::fs::read_dir(directory).map_err(unreadable)? {
            let entry = entry.map_err(unreadable)?;
            let metadata = entry.metadata().map_err(unreadable)?;
            let entry = entry.file_name().to_string_lossy().into_owned();
            let named = entry == name || entry.starts_with(&staged);
            if !named || !metadata.is_file() || metadata.nlink() != 1 {
                return Err(DevicesError::DirectoryShared {
                    directory: directory.to_path_buf(),
                    entry,
                });
            }
        }
        Ok(())
    }

    /// Opened without following a symlink, and refused when anyone but its
    /// owner may read or write it.
    pub(crate) fn read(&self) -> Result<Roster, DevicesError> {
        use std::io::Read;
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        let path = self.path();
        let unreadable = |error| DevicesError::Unreadable {
            path: path.to_path_buf(),
            error,
        };
        let mut file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(nix::fcntl::OFlag::O_NOFOLLOW.bits())
            .open(path)
            .map_err(|error| {
                if error.raw_os_error() == Some(nix::errno::Errno::ELOOP as i32) {
                    DevicesError::Symlink(path.to_path_buf())
                } else {
                    unreadable(error)
                }
            })?;
        let mode = file.metadata().map_err(unreadable)?.mode() & 0o777;
        if mode & 0o077 != 0 {
            return Err(DevicesError::Open {
                path: path.to_path_buf(),
                mode,
            });
        }
        let mut text = String::new();
        file.read_to_string(&mut text).map_err(unreadable)?;
        Roster::parse(&text).map_err(|line| DevicesError::Malformed {
            path: path.to_path_buf(),
            line,
        })
    }

    fn stamp(&self) -> Option<Stamp> {
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(&self.path).ok()?;
        Some(Stamp {
            device: metadata.dev(),
            inode: metadata.ino(),
            modified: (metadata.mtime(), metadata.mtime_nsec()),
            len: metadata.len(),
        })
    }
}

/// Each paired device's name and the digest of its token.
#[derive(Default)]
pub(crate) struct Roster(Vec<(Arc<str>, blake3::Hash)>);

impl Roster {
    /// `<name> <blake3 hex of the token>` per line; the 1-based number of the first bad line.
    fn parse(text: &str) -> Result<Self, usize> {
        text.lines()
            .enumerate()
            .map(
                |(index, line)| match line.split(' ').collect::<Vec<_>>()[..] {
                    [name, digest] if !name.is_empty() => blake3::Hash::from_hex(digest)
                        .map(|digest| (Arc::from(name), digest))
                        .map_err(|_| index + 1),
                    _ => Err(index + 1),
                },
            )
            .collect::<Result<_, _>>()
            .map(Self)
    }
}

/// The devices the relay admits now, each with the signal its connections
/// close on. A revoked device's signal is dropped, which closes them.
pub(crate) struct Paired {
    devices: Mutex<Vec<Device>>,
}

struct Device {
    name: Arc<str>,
    digest: blake3::Hash,
    live: watch::Sender<()>,
}

/// A connection admitted as one device. No `Debug`, so it cannot reach a log
/// beside a token.
pub(crate) struct Admitted {
    name: Arc<str>,
    live: watch::Receiver<()>,
}

impl Admitted {
    pub(crate) fn name(&self) -> &str {
        &self.name
    }

    /// Resolves once the device is revoked or paired again with another token.
    pub(crate) async fn revoked(&self) {
        let mut live = self.live.clone();
        while live.changed().await.is_ok() {}
    }
}

impl Paired {
    pub(crate) fn new(roster: Roster) -> Self {
        let paired = Self {
            devices: Mutex::new(Vec::new()),
        };
        paired.replace(roster);
        paired
    }

    fn devices(&self) -> MutexGuard<'_, Vec<Device>> {
        self.devices.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Every digest is compared, in constant time, so the time taken tells a
    /// peer nothing of which device or how much of one a guess matched.
    pub(crate) fn admit(&self, token: &str) -> Option<Admitted> {
        let guess = blake3::hash(token.as_bytes());
        let devices = self.devices();
        let mut found = None;
        for device in devices.iter() {
            if bool::from(device.digest.as_bytes().ct_eq(guess.as_bytes())) {
                found = Some(device);
            }
        }
        found.map(|device| Admitted {
            name: Arc::clone(&device.name),
            live: device.live.subscribe(),
        })
    }

    /// A device kept under the same name and digest keeps its connections;
    /// every other one is dropped, and its connections close.
    pub(crate) fn replace(&self, roster: Roster) {
        let mut devices = self.devices();
        let mut kept = std::mem::take(&mut *devices);
        *devices = roster
            .0
            .into_iter()
            .map(|(name, digest)| {
                let same = kept
                    .iter()
                    .position(|device| device.name == name && device.digest == digest);
                same.map_or_else(
                    || Device {
                        name,
                        digest,
                        live: watch::channel(()).0,
                    },
                    |index| kept.swap_remove(index),
                )
            })
            .collect();
    }
}

/// Rereads the devices file when its stamp changes.
pub(crate) struct Watcher {
    file: DevicesFile,
    seen: Option<Stamp>,
    refused: bool,
}

impl Watcher {
    pub(crate) fn new(file: DevicesFile) -> Self {
        Self {
            file,
            seen: None,
            refused: false,
        }
    }

    pub(crate) fn file(&self) -> &DevicesFile {
        &self.file
    }

    pub(crate) fn read(&mut self) -> Result<Roster, DevicesError> {
        self.seen = self.file.stamp();
        self.file.read()
    }

    /// The directory is checked on every poll, since a file planted beside
    /// the devices file leaves its stamp alone. A directory refused, or a file
    /// that cannot be read, pairs nobody: a revoke must never be undone by a
    /// file the relay failed to read.
    pub(crate) fn poll(&mut self, paired: &Paired) {
        match self.file.check_directory() {
            Err(error) => self.refuse(paired, &error),
            Ok(()) if self.refused || self.file.stamp() != self.seen => self.reread(paired),
            Ok(()) => {}
        }
    }

    /// Logged once per refusal, not once per tick.
    fn refuse(&mut self, paired: &Paired, error: &DevicesError) {
        if !self.refused {
            tracing::warn!(%error, "no device is paired until the devices directory is fixed");
        }
        self.refused = true;
        paired.replace(Roster::default());
    }

    fn reread(&mut self, paired: &Paired) {
        self.refused = false;
        let roster = self.read().unwrap_or_else(|error| {
            tracing::warn!(%error, "the devices file is unreadable; no device is paired until it is fixed");
            Roster::default()
        });
        paired.replace(roster);
    }
}

#[cfg(test)]
pub(super) mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use super::{DevicesFile, Paired, Watcher};

    pub(crate) fn line(name: &str, token: &str) -> String {
        format!("{name} {}\n", blake3::hash(token.as_bytes()).to_hex())
    }

    /// Written beside the file and renamed over it, as `lain remote` does.
    pub(crate) fn rewrite(path: &Path, text: &str) {
        let staged = path.with_file_name(".devices.staged");
        std::fs::write(&staged, text).expect("write the staged devices");
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600)).expect("chmod");
        std::fs::rename(&staged, path).expect("rename the devices file in");
    }

    pub(crate) fn devices_file(dir: &Path, text: &str) -> PathBuf {
        let remote = dir.join("remote");
        std::fs::create_dir(&remote).expect("the devices dir");
        std::fs::set_permissions(&remote, std::fs::Permissions::from_mode(0o700)).expect("chmod");
        let path = remote.join("devices");
        rewrite(&path, text);
        path
    }

    fn paired(text: &str) -> (tempfile::TempDir, DevicesFile) {
        let dir = tempfile::tempdir().expect("a tempdir");
        let path = devices_file(dir.path(), text);
        (dir, DevicesFile::new(path))
    }

    fn both() -> String {
        line("pixel", "pixel-token") + &line("tablet", "tablet-token")
    }

    #[test]
    fn a_token_admits_the_device_it_was_paired_as_and_no_other() {
        let (_dir, file) = paired(&both());
        let paired = Paired::new(file.read().expect("read the devices"));
        let name = |token: &str| {
            paired
                .admit(token)
                .map(|admitted| admitted.name().to_string())
        };
        assert_eq!(Some("pixel".to_string()), name("pixel-token"));
        assert_eq!(Some("tablet".to_string()), name("tablet-token"));
        for guess in ["", "pixel", "pixel-token-and-more", "pixel token"] {
            assert_eq!(None, name(guess), "the guess {guess:?}");
        }
    }

    #[test]
    fn the_file_holds_a_digest_and_the_token_itself_does_not_match_as_one() {
        let digest = blake3::hash(b"pixel-token").to_hex().to_string();
        let (_dir, file) = paired(&format!("pixel {digest}\n"));
        let paired = Paired::new(file.read().expect("read"));
        assert!(
            paired.admit(&digest).is_none(),
            "the stored digest worked as a token"
        );
        assert!(paired.admit("pixel-token").is_some());
    }

    #[test]
    fn an_empty_file_pairs_no_device() {
        let (_dir, file) = paired("");
        assert!(Paired::new(file.read().expect("read")).admit("").is_none());
    }

    #[test]
    fn a_malformed_line_is_refused_by_its_number() {
        for bad in ["pixel\n", "pixel abc\n", "pixel tablet extra\n"] {
            let (_dir, file) = paired(&(line("tablet", "t") + bad));
            let error = file.read().err().expect("a malformed file was read");
            assert_eq!(
                format!(
                    "line 2 of the devices file {} is not a device name and a token digest",
                    file.path().display()
                ),
                error.to_string(),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn a_devices_file_others_can_read_is_refused_by_name() {
        let (_dir, file) = paired(&both());
        std::fs::set_permissions(file.path(), std::fs::Permissions::from_mode(0o640))
            .expect("chmod");
        let error = file.read().err().expect("a 0640 devices file was read");
        assert_eq!(
            format!(
                "the devices file {} is open to group or others (mode 640); it must be 600",
                file.path().display()
            ),
            error.to_string()
        );
    }

    #[test]
    fn a_devices_file_that_is_a_symlink_is_refused_by_name() {
        let (dir, file) = paired(&both());
        let link = dir.path().join("remote").join("link");
        std::os::unix::fs::symlink(file.path(), &link).expect("symlink");
        let error = DevicesFile::new(link.clone())
            .read()
            .err()
            .expect("a symlinked devices file was read");
        assert_eq!(
            format!("the devices file {} is a symlink", link.display()),
            error.to_string()
        );
    }

    #[test]
    fn the_directory_must_hold_only_the_devices_file_and_its_staged_writes() {
        let (dir, file) = paired(&both());
        std::fs::write(dir.path().join("remote").join(".devices.abc123"), "x").expect("staged");
        assert!(file.check_directory().is_ok(), "a staged write was refused");

        std::fs::write(dir.path().join("remote").join("notes"), "x").expect("a neighbour");
        let error = file
            .check_directory()
            .expect_err("a shared directory was allowed");
        assert_eq!(
            shared(&dir.path().join("remote"), "notes"),
            error.to_string()
        );
    }

    fn shared(directory: &Path, entry: &str) -> String {
        format!(
            "the devices file's directory {} holds {entry}; it must hold only the devices file \
             and its staged writes, each a regular file with 1 link, because the relay may read \
             anything in it",
            directory.display()
        )
    }

    #[test]
    fn the_directory_refuses_a_subdirectory_a_hardlink_and_a_symlink() {
        type Plant = fn(&Path, &Path);
        let plants: [(&str, Plant); 4] = [
            (".devices.d", |remote, _| {
                std::fs::create_dir(remote.join(".devices.d")).expect("a subdirectory");
            }),
            (".devices.h", |remote, outside| {
                std::fs::hard_link(outside, remote.join(".devices.h")).expect("a hardlink");
            }),
            (".devices.s", |remote, outside| {
                std::os::unix::fs::symlink(outside, remote.join(".devices.s")).expect("a symlink");
            }),
            ("devices", |remote, outside| {
                std::fs::hard_link(remote.join("devices"), outside).expect("a second link");
            }),
        ];
        for (entry, plant) in plants {
            let (dir, file) = paired(&both());
            let remote = dir.path().join("remote");
            let outside = dir.path().join("outside");
            if entry != "devices" {
                std::fs::write(&outside, "not the relay's").expect("an outside file");
            }
            plant(&remote, &outside);
            let error = file
                .check_directory()
                .expect_err(&format!("{entry} was allowed"));
            assert_eq!(shared(&remote, entry), error.to_string());
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_file_planted_after_start_pairs_nobody_until_it_is_gone() {
        let (dir, file) = paired(&both());
        let mut watcher = Watcher::new(file);
        let paired = Paired::new(watcher.read().expect("read"));
        let pixel = paired.admit("pixel-token").expect("pixel");
        let outside = dir.path().join("outside");
        std::fs::write(&outside, "not the relay's").expect("an outside file");
        let planted = dir.path().join("remote").join(".devices.planted");
        std::fs::hard_link(&outside, &planted).expect("a hardlink");

        watcher.poll(&paired);
        assert!(
            tokio::time::timeout(PROMPTLY, pixel.revoked())
                .await
                .is_ok()
        );
        assert!(
            paired.admit("tablet-token").is_none(),
            "a shared directory paired a device"
        );

        std::fs::remove_file(&planted).expect("remove the plant");
        watcher.poll(&paired);
        assert!(
            paired.admit("tablet-token").is_some(),
            "the fixed directory was not reread"
        );
    }

    #[test]
    fn a_devices_directory_that_is_a_symlink_is_refused() {
        let dir = tempfile::tempdir().expect("a tempdir");
        devices_file(dir.path(), &both());
        let link = dir.path().join("linked");
        std::os::unix::fs::symlink(dir.path().join("remote"), &link).expect("symlink");
        let error = DevicesFile::new(link.join("devices"))
            .check_directory()
            .expect_err("a symlinked directory was allowed");
        assert_eq!(
            format!(
                "the devices file's directory {} is a symlink",
                link.display()
            ),
            error.to_string()
        );
    }

    /// Longer than any wake-up needs, in paused time.
    const PROMPTLY: Duration = Duration::from_secs(1);

    #[tokio::test(start_paused = true)]
    async fn a_revoke_closes_that_device_alone_and_refuses_its_token() {
        let (_dir, file) = paired(&both());
        let paired = Paired::new(file.read().expect("read"));
        let pixel = paired.admit("pixel-token").expect("pixel");
        let tablet = paired.admit("tablet-token").expect("tablet");

        paired.replace(file_roster(&line("tablet", "tablet-token")));
        assert!(
            tokio::time::timeout(PROMPTLY, pixel.revoked())
                .await
                .is_ok(),
            "the revoked device was not told"
        );
        assert!(
            tokio::time::timeout(PROMPTLY, tablet.revoked())
                .await
                .is_err(),
            "a revoke reached another device"
        );
        assert!(
            paired.admit("pixel-token").is_none(),
            "a revoked token admitted"
        );
        assert!(paired.admit("tablet-token").is_some());
    }

    #[tokio::test(start_paused = true)]
    async fn a_device_paired_again_with_a_new_token_drops_the_old_one() {
        let (_dir, file) = paired(&both());
        let paired = Paired::new(file.read().expect("read"));
        let old = paired.admit("pixel-token").expect("pixel");
        paired.replace(file_roster(
            &(line("pixel", "pixel-new") + &line("tablet", "tablet-token")),
        ));
        assert!(tokio::time::timeout(PROMPTLY, old.revoked()).await.is_ok());
        assert!(paired.admit("pixel-token").is_none());
        assert!(paired.admit("pixel-new").is_some());
    }

    fn file_roster(text: &str) -> super::Roster {
        let (_dir, file) = paired(text);
        file.read().expect("read")
    }

    #[test]
    fn the_watcher_rereads_a_file_renamed_over_the_old_one() {
        let (_dir, file) = paired(&line("tablet", "tablet-token"));
        let path = file.path().to_path_buf();
        let mut watcher = Watcher::new(file);
        let paired = Paired::new(watcher.read().expect("read"));
        assert!(paired.admit("pixel-token").is_none());

        rewrite(&path, &both());
        watcher.poll(&paired);
        assert!(
            paired.admit("pixel-token").is_some(),
            "the pair was not reread"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_file_that_turns_unreadable_pairs_nobody() {
        let (_dir, file) = paired(&both());
        let path = file.path().to_path_buf();
        let mut watcher = Watcher::new(file);
        let paired = Paired::new(watcher.read().expect("read"));
        let pixel = paired.admit("pixel-token").expect("pixel");

        rewrite(&path, "pixel not-a-digest\n");
        watcher.poll(&paired);
        assert!(
            tokio::time::timeout(PROMPTLY, pixel.revoked())
                .await
                .is_ok()
        );
        assert!(paired.admit("tablet-token").is_none());
    }
}
