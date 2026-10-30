//! Real checkout files for the tests that compare an answer over many sources.

use std::path::{Path, PathBuf};

/// The repository root, two levels above the crate.
pub fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The text of every `extension` file under `dirs` (relative to the checkout),
/// sorted by path, taking one in `every`. A file that is not UTF-8 is skipped.
pub fn sources(dirs: &[&str], extension: &str, every: usize) -> Vec<String> {
    let roots = dirs.iter().map(|dir| checkout().join(dir)).collect();
    let mut paths = walk(roots, extension, |dir| std::fs::read_dir(dir));
    paths.sort();
    paths
        .iter()
        .step_by(every)
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .collect()
}

/// This walks the live checkout, where a directory or entry can vanish between
/// listing and reading; that is skipped, not fatal.
fn walk<I>(
    mut pending: Vec<PathBuf>,
    extension: &str,
    read_dir: impl Fn(&Path) -> std::io::Result<I>,
) -> Vec<PathBuf>
where
    I: Iterator<Item = std::io::Result<std::fs::DirEntry>>,
{
    let mut paths = Vec::new();
    while let Some(dir) = pending.pop() {
        for path in vanished_is_empty(read_dir(&dir))
            .into_iter()
            .filter_map(vanished_is_none)
        {
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|ext| ext == extension) {
                paths.push(path);
            }
        }
    }
    paths
}

fn vanished_is_empty<I: Iterator<Item = std::io::Result<std::fs::DirEntry>>>(
    listing: std::io::Result<I>,
) -> Vec<std::io::Result<std::fs::DirEntry>> {
    match listing {
        Ok(entries) => entries.collect(),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(err) => panic!("cannot list a checkout directory: {err}"),
    }
}

fn vanished_is_none(entry: std::io::Result<std::fs::DirEntry>) -> Option<PathBuf> {
    match entry {
        Ok(entry) => Some(entry.path()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => None,
        Err(err) => panic!("cannot read a checkout entry: {err}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Error, ErrorKind};

    fn listing(
        dir: &Path,
    ) -> std::io::Result<std::vec::IntoIter<std::io::Result<std::fs::DirEntry>>> {
        if dir.ends_with("gone") {
            Err(Error::from(ErrorKind::NotFound))
        } else {
            Ok(std::fs::read_dir(dir)?.collect::<Vec<_>>().into_iter())
        }
    }

    fn tree() -> PathBuf {
        let root = std::env::temp_dir().join(format!("lain-test-sources-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("kept")).unwrap();
        std::fs::write(root.join("kept/a.rb"), "a").unwrap();
        root
    }

    #[test]
    fn a_directory_that_vanished_before_it_was_read_is_skipped() {
        let root = tree();

        let found = walk(vec![root.join("gone"), root.join("kept")], "rb", listing);

        assert_eq!(found, vec![root.join("kept/a.rb")]);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[should_panic(expected = "cannot list")]
    fn any_other_listing_error_still_panics() {
        walk(vec![PathBuf::from("x")], "rb", |_| {
            Err::<std::vec::IntoIter<_>, _>(Error::from(ErrorKind::PermissionDenied))
        });
    }
}
