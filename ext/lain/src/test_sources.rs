//! Real checkout files for the tests that compare an answer over many sources.

use std::path::{Path, PathBuf};

/// The repository root, two levels above the crate.
pub fn checkout() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// The text of every `extension` file under `dirs` (relative to the checkout),
/// sorted by path, taking one in `every`. A file that is not UTF-8 is skipped.
pub fn sources(dirs: &[&str], extension: &str, every: usize) -> Vec<String> {
    let mut paths = Vec::new();
    let mut pending: Vec<PathBuf> = dirs.iter().map(|dir| checkout().join(dir)).collect();
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|ext| ext == extension) {
                paths.push(path);
            }
        }
    }
    paths.sort();
    paths
        .iter()
        .step_by(every)
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .collect()
}
