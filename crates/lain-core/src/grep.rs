//! The `grep` method: walk a tree honouring its ignore rules, search each file
//! line by line, and report `{matches, capped}` where every match is
//! `{path, line_number, line}`.
//!
//! The three fields are `Tools::Grep`'s, deliberately: the Ruby tool already
//! yields `[label, line_no, line]` and formats it as `path:line:text`, so
//! moving it onto this transport is a swap, not a format migration.
//!
//! Out of process by the placement rule -- a directory walk is I/O, so it could
//! never have lived in `ext/lain`.

use std::ops::ControlFlow;
use std::path::Path;

use grep_regex::{RegexMatcher, RegexMatcherBuilder};
use grep_searcher::sinks::UTF8;
use grep_searcher::{BinaryDetection, Searcher, SearcherBuilder};
use ignore::WalkBuilder;
use rmpv::Value;
use thiserror::Error;

/// The output bound, mirroring `Tools::Grep::MAX_MATCHES`. Capped, never
/// silently truncated: [`Outcome::capped`] says which it was.
pub(crate) const MAX_MATCHES: usize = 200;

/// One decoded `grep` request. `pattern` is Rust regex syntax (see
/// [`build_matcher`]); `path` is a filesystem locator the caller has already
/// resolved -- this daemon never computes a path of its own.
#[derive(Debug, Clone)]
pub(crate) struct GrepParams {
    pub(crate) pattern: String,
    pub(crate) path: String,
    pub(crate) case_insensitive: bool,
    /// Whether the walk applies `.gitignore`/`.ignore` rules. **Off by
    /// default, deliberately**: the in-process `Tools::Grep` walks with
    /// `Dir.glob`, which has no notion of a `.gitignore` and cannot get one
    /// without the subprocess that tool exists to avoid. Defaulting this ON
    /// would make the SAME tool answer differently depending on whether a core
    /// client happened to be wired, which confounds the only comparison the
    /// bench cares about -- transport against transport. So the transport swap
    /// is behaviour-preserving, and VCS-aware search is a separate, opt-in
    /// capability that lands with its own before/after.
    pub(crate) respect_ignores: bool,
}

/// `path` is relative to the searched root for a directory target, and the
/// `path` param verbatim for a single-file target -- the same two labelling
/// rules `Tools::Grep#search` uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Match {
    pub(crate) path: String,
    pub(crate) line_number: u64,
    pub(crate) line: String,
}

#[derive(Debug)]
pub(crate) struct Outcome {
    pub(crate) matches: Vec<Match>,
    pub(crate) capped: bool,
}

#[derive(Debug, Error)]
pub(crate) enum ParamError {
    #[error("grep params must be a map")]
    NotMap,
    #[error("grep param keys must be strings")]
    KeyNotString,
    #[error("pattern must be a string")]
    Pattern,
    #[error("path must be a string")]
    Path,
    #[error("case_insensitive must be a boolean")]
    CaseInsensitive,
    #[error("respect_ignores must be a boolean")]
    RespectIgnores,
    #[error("pattern is required")]
    MissingPattern,
    #[error("path is required")]
    MissingPath,
    #[error("unknown grep param {0:?}")]
    UnknownKey(String),
}

#[derive(Debug, Error)]
pub(crate) enum GrepError {
    #[error("invalid pattern {pattern:?}: {source}")]
    Pattern {
        pattern: String,
        source: grep_regex::Error,
    },
    #[error("no such file or directory: {0}")]
    NoSuchPath(String),
    #[error("not readable: {0}")]
    NotReadable(String),
    #[error("could not open {path}: {kind}")]
    Unopenable {
        path: String,
        kind: std::io::ErrorKind,
    },
    #[error("the search task failed: {0}")]
    Join(tokio::task::JoinError),
}

impl GrepParams {
    pub(crate) fn from_value(value: &Value) -> Result<Self, ParamError> {
        let entries = value.as_map().ok_or(ParamError::NotMap)?;
        let empty = Draft::default();
        let draft = entries.iter().try_fold(empty, |mut draft, (key, value)| {
            let key = key.as_str().ok_or(ParamError::KeyNotString)?;
            draft.apply(key, value)?;
            Ok(draft)
        })?;
        Ok(Self {
            pattern: draft.pattern.ok_or(ParamError::MissingPattern)?,
            path: draft.path.ok_or(ParamError::MissingPath)?,
            case_insensitive: draft.case_insensitive,
            respect_ignores: draft.respect_ignores,
        })
    }
}

/// The half-built params: `pattern` and `path` are required, so they cannot be
/// absent from [`GrepParams`] itself and the fold needs somewhere to put them
/// until every entry has been seen.
#[derive(Default)]
struct Draft {
    pattern: Option<String>,
    path: Option<String>,
    case_insensitive: bool,
    respect_ignores: bool,
}

impl Draft {
    /// Unknown keys fail loudly, exactly as `exec`'s do: a typo'd param
    /// silently ignored would run a different search with no error.
    fn apply(&mut self, key: &str, value: &Value) -> Result<(), ParamError> {
        match key {
            "pattern" => self.pattern = Some(string(value, ParamError::Pattern)?),
            "path" => self.path = Some(string(value, ParamError::Path)?),
            "case_insensitive" => self.case_insensitive = flag(value, ParamError::CaseInsensitive)?,
            "respect_ignores" => self.respect_ignores = flag(value, ParamError::RespectIgnores)?,
            unknown => return Err(ParamError::UnknownKey(unknown.to_string())),
        }
        Ok(())
    }
}

fn string(value: &Value, error: ParamError) -> Result<String, ParamError> {
    value.as_str().map(str::to_string).ok_or(error)
}

/// msgpack has no "absent", so a caller that omitted an optional flag may send
/// an explicit nil; that reads as `false`, which is the default for both flags.
/// Anything that is neither nil nor a boolean is a caller bug and fails loudly,
/// the same way an unknown key does.
fn flag(value: &Value, error: ParamError) -> Result<bool, ParamError> {
    match value {
        Value::Nil => Ok(false),
        other => other.as_bool().ok_or(error),
    }
}

/// The walk and the per-file reads are blocking syscalls, so they go to the
/// blocking pool rather than onto a runtime worker. That is what keeps the
/// rest of the RPC surface answering while a search is in flight -- a walk run
/// inline would hold its worker for the whole search, and on a single-worker
/// runtime that is every other request on the daemon.
pub(crate) async fn run(params: GrepParams) -> Result<Outcome, GrepError> {
    tokio::task::spawn_blocking(move || search(&params))
        .await
        .map_err(GrepError::Join)?
}

fn search(params: &GrepParams) -> Result<Outcome, GrepError> {
    let root = Path::new(&params.path);
    let is_directory = readable_kind(&params.path)?;
    let matcher = build_matcher(params)?;
    let mut searcher = build_searcher();

    let mut files = walk(root, params.respect_ignores)
        .filter_map(|entry| {
            entry
                .inspect_err(|error| tracing::debug!(%error, "skipping an unwalkable entry"))
                .ok()
        })
        .filter(|entry| entry.file_type().is_some_and(|kind| kind.is_file()))
        .map(ignore::DirEntry::into_path);

    // One past the cap is all that is ever collected -- enough to know the
    // result was capped, without searching a file the cap has already
    // excluded. `Tools::Grep` spells the same bound `lazy.first(MAX + 1)`.
    let (ControlFlow::Break(mut found) | ControlFlow::Continue(mut found)) =
        files.try_fold(Vec::new(), |mut found, file| {
            let label = label_for(&file, root, is_directory, &params.path);
            collect_from(&mut searcher, &matcher, &file, label, &mut found);
            if found.len() > MAX_MATCHES {
                ControlFlow::Break(found)
            } else {
                ControlFlow::Continue(found)
            }
        });

    let capped = found.len() > MAX_MATCHES;
    found.truncate(MAX_MATCHES);
    Ok(Outcome {
        matches: found,
        capped,
    })
}

/// The two guards `Tools::Grep#problem_with` applies -- exists, and is
/// readable -- plus the answer to "directory?" that decides labelling.
///
/// Two syscalls rather than one, and the split is the point: `stat` cannot
/// answer readability, but `open` on a FIFO BLOCKS until a writer arrives, and
/// a grep aimed at one would then hold a blocking-pool thread forever with no
/// timeout to end it. So `stat` first, and open only the two shapes whose open
/// cannot block. Anything else -- FIFO, socket, device -- is left to the walk,
/// which yields it and then drops it for not being a regular file: an empty
/// result, which is what `Tools::Grep` returns for one too (`File.file?` is
/// false, so its glob has nothing to walk).
fn readable_kind(path: &str) -> Result<bool, GrepError> {
    let metadata = std::fs::metadata(path).map_err(|error| open_error(path, &error))?;
    if metadata.is_file() || metadata.is_dir() {
        std::fs::File::open(path).map_err(|error| open_error(path, &error))?;
    }
    Ok(metadata.is_dir())
}

fn open_error(path: &str, error: &std::io::Error) -> GrepError {
    use std::io::ErrorKind;
    match error.kind() {
        ErrorKind::NotFound => GrepError::NoSuchPath(path.to_string()),
        ErrorKind::PermissionDenied => GrepError::NotReadable(path.to_string()),
        other => GrepError::Unopenable {
            path: path.to_string(),
            kind: other,
        },
    }
}

/// `grep-regex` is the `regex` crate's finite automata, so match time is linear
/// in the subject and a pattern that backtracks catastrophically in a
/// PCRE-style engine cannot hang this daemon. Swapping in an engine with
/// backreferences or lookaround would give that property up.
fn build_matcher(params: &GrepParams) -> Result<RegexMatcher, GrepError> {
    RegexMatcherBuilder::new()
        .case_insensitive(params.case_insensitive)
        .build(&params.pattern)
        .map_err(|source| GrepError::Pattern {
            pattern: params.pattern.clone(),
            source,
        })
}

fn build_searcher() -> Searcher {
    SearcherBuilder::new()
        .line_number(true)
        // Binary content is not text to search, and reporting a match inside it
        // floods the turn with bytes no reader wants.
        //
        // `Tools::Grep` does NOT agree here, and the two ways it disagrees are
        // pinned as witnesses in `spec/lain/core/grep_parity_spec.rb` -- do not
        // "restore parity" by changing this line without reading them:
        //
        // - NUL bytes (divergence #5): `quit(0)` is buffer-granular, so this
        //   abandons the whole FILE, discarding matches that appeared BEFORE
        //   the NUL. Ruby keeps them, because a NUL decodes perfectly well.
        // - Invalid UTF-8 (divergence #6): the opposite direction. This reads
        //   straight past it, while `File.foreach` raises and Ruby's rescue
        //   ends the file at the bad line.
        //
        // So neither arm is a subset of the other, and no setting of this knob
        // alone reconciles them.
        .binary_detection(BinaryDetection::quit(0))
        .build()
}

/// The directory `.git` holds no content worth searching, and `Tools::Grep`
/// skips it by name for the same reason.
const GIT_DIR: &str = ".git";

/// Ignore rules come from `ignore`, which is ripgrep's own resolver for the
/// `.gitignore`/`.ignore` precedence hierarchy -- not a thing to re-derive.
/// **Every source of them is switched by `respect_ignores`, which is off by
/// default** (see [`GrepParams::respect_ignores`] for why). All five are named
/// rather than reached through `standard_filters`, because that switch also
/// carries `hidden`, and dotfile searching is a decision this walk makes
/// unconditionally -- coupling the two would silently stop searching dotfiles
/// the day someone turned ignores on.
///
/// `parents` is named because the rule it governs is the one a reader forgets:
/// ignore files ABOVE the searched root. Without it a search of a directory
/// that happens to sit inside a repository would answer differently from the
/// same search on a copy of that directory elsewhere. Pinned in both
/// directions by
/// `an_ignore_file_above_the_root_filters_only_when_ignores_are_respected`.
///
/// Three further defaults are overridden deliberately:
/// - `hidden(false)`: dotfiles ARE searched, matching `Tools::Grep`'s
///   `File::FNM_DOTMATCH` walk. `.git` is then excluded by name rather than by
///   being hidden (ripgrep's `--hidden` has the same gap).
/// - `require_git(false)`: when ignores ARE respected, a `.gitignore` is
///   honoured whether or not the tree happens to sit in a git repository, so
///   the result does not change underneath a caller who runs the same search in
///   a copy of the tree.
/// - `sort_by_file_path`: the cap makes ordering observable -- which 200
///   matches come back is part of the answer -- and the Journal is the
///   experiment record, so directory order is not good enough. This ordering is
///   **divergence #2**, and it is deliberate: `Tools::Grep` walks depth-first,
///   so `a/b.txt` precedes `a.txt` there and follows it here, and under
///   `MAX_MATCHES` the two arms return DIFFERENT SUBSETS rather than the same
///   matches reordered. Changing it to match Ruby reddens
///   `DIVERGES on walk order` in `spec/lain/core/grep_parity_spec.rb`; the
///   decision to leave it standing is recorded on `Lain::Tools::Grep` itself.
///
/// `follow_links` is absent, so it keeps ripgrep's default of NOT following
/// symlinks -- **divergence #7**. `Tools::Grep`'s `Dir.glob` does follow a
/// symlinked file and reports the same bytes twice, under both labels. Turning
/// this on to "match Ruby" reddens `DIVERGES on symlinks`, and would also let a
/// link out of the tree pull in content from outside the searched root.
///
/// The root itself is never filtered (`ignore` exempts depth 0), so naming an
/// ignored file explicitly still searches it.
fn walk(root: &Path, respect_ignores: bool) -> ignore::Walk {
    WalkBuilder::new(root)
        .hidden(false)
        .require_git(false)
        .git_ignore(respect_ignores)
        .git_global(respect_ignores)
        .git_exclude(respect_ignores)
        .ignore(respect_ignores)
        .parents(respect_ignores)
        .filter_entry(|entry| entry.file_name() != GIT_DIR)
        .sort_by_file_path(Path::cmp)
        .build()
}

/// A directory target labels each hit by its path relative to the walked root;
/// a single-file target labels its hits with the `path` param verbatim, so a
/// caller that sent a relative spelling gets it back. Both rules are
/// `Tools::Grep#search`'s.
///
/// Lossy for a path that is not valid UTF-8: results ride the wire as msgpack
/// `str`, the same restriction `exec` puts on its inputs.
fn label_for(file: &Path, root: &Path, is_directory: bool, given: &str) -> String {
    if is_directory {
        file.strip_prefix(root)
            .unwrap_or(file)
            .to_string_lossy()
            .into_owned()
    } else {
        given.to_string()
    }
}

/// Appends this file's matches, stopping the moment the cap is one past.
///
/// A file that cannot be searched is skipped rather than failing the whole
/// request -- a real grep skips what it cannot read. The `UTF8` sink errors on
/// a line that is not valid UTF-8, which ends that file's search and keeps
/// what came before it.
fn collect_from(
    searcher: &mut Searcher,
    matcher: &RegexMatcher,
    file: &Path,
    label: String,
    found: &mut Vec<Match>,
) {
    let sink = UTF8(|line_number, line| {
        found.push(Match {
            path: label.clone(),
            line_number,
            line: chomp(line).to_string(),
        });
        Ok(found.len() <= MAX_MATCHES)
    });
    if let Err(error) = searcher.search_path(matcher, file, sink) {
        tracing::debug!(%error, file = %file.display(), "skipping an unsearchable file");
    }
}

/// The sink hands back the line WITH its terminator; `Tools::Grep` reports
/// `line.chomp`, and a trailing newline in every match would be a format
/// difference the moment T13 formats these as `path:line:text`.
fn chomp(line: &str) -> &str {
    let line = line.strip_suffix('\n').unwrap_or(line);
    line.strip_suffix('\r').unwrap_or(line)
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use rmpv::Value;

    use super::{GrepParams, MAX_MATCHES, Outcome, run};
    use crate::rpc::support::{TestClient, field, request, response_parts, start_server};

    fn write(dir: &Path, relative: &str, contents: &str) {
        let path = dir.join(relative);
        std::fs::create_dir_all(path.parent().expect("a parent directory"))
            .expect("create the fixture directory");
        std::fs::write(path, contents).expect("write the fixture file");
    }

    fn lines(count: usize, text: &str) -> String {
        std::iter::repeat_n(text, count)
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn params(path: &Path, pattern: &str) -> GrepParams {
        GrepParams {
            pattern: pattern.to_string(),
            path: path.to_string_lossy().into_owned(),
            case_insensitive: false,
            respect_ignores: false,
        }
    }

    async fn grep(path: &Path, pattern: &str) -> Outcome {
        run(params(path, pattern))
            .await
            .expect("the search succeeds")
    }

    /// The same search with the opt-in VCS-aware walk. Everything else about
    /// the request is identical, so a difference between this and [`grep`] can
    /// only be the ignore rules.
    async fn grep_respecting_ignores(path: &Path, pattern: &str) -> Outcome {
        let mut respecting = params(path, pattern);
        respecting.respect_ignores = true;
        run(respecting).await.expect("the search succeeds")
    }

    fn paths(outcome: &Outcome) -> Vec<String> {
        outcome
            .matches
            .iter()
            .map(|found| found.path.clone())
            .collect()
    }

    /// A tree with an ignored file, an ignored directory, a dotfile, a `.git`
    /// directory and one file holding more matches than the cap -- the whole
    /// AC-1 fixture, so the tests below each assert one claim about it.
    fn fixture() -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir for the fixture tree");
        let root = dir.path();
        write(root, ".gitignore", "ignored.txt\nvendor/\n");
        write(root, "ignored.txt", "needle in an ignored file\n");
        write(root, "vendor/dep.txt", "needle in an ignored directory\n");
        write(root, ".git/config", "needle in the git directory\n");
        write(root, ".hidden.txt", "needle in a dotfile\n");
        write(root, "kept.txt", &lines(MAX_MATCHES + 50, "needle"));
        dir
    }

    /// THE DEFAULT, and the reason `respect_ignores` exists. `Tools::Grep`'s
    /// in-process walk is `Dir.glob`, which searches a `.gitignore`'d file like
    /// any other; if this daemon skipped them by default then wiring a core
    /// client would silently change what the same tool returns, and the
    /// transport arm would no longer be measuring the transport.
    ///
    /// The `kept.txt` assertion is first and is not decoration: "the ignored
    /// files ARE present" is a claim about a non-empty result, and this is what
    /// makes a walk that never ran fail instead of pass.
    #[tokio::test]
    async fn ignore_rules_are_off_by_default_so_the_walk_matches_tools_grep() {
        let dir = fixture();
        let found = paths(&grep(dir.path(), "needle").await);
        assert!(
            found.iter().any(|path| path == "kept.txt"),
            "the tracked file was not searched at all: {found:?}"
        );
        assert!(
            found.iter().any(|path| path == "ignored.txt"),
            "a .gitignore'd file must still be searched by default, as Dir.glob does: {found:?}"
        );

        // A SECOND search, and the different pattern is the point rather than
        // convenience: `vendor/` sorts after `kept.txt`, whose 250 matches trip
        // the cap first, so a "needle" search never reaches the directory at
        // all. That is the cap behaving correctly, and asserting the directory
        // claim on that result would be measuring MAX_MATCHES rather than the
        // ignore rules. "an ignored" matches only the two ignored files, so
        // this search is nowhere near the cap.
        let uncapped = paths(&grep(dir.path(), "an ignored").await);
        assert!(
            uncapped.iter().any(|path| path == "ignored.txt"),
            "the search found nothing at all: {uncapped:?}"
        );
        assert!(
            uncapped.iter().any(|path| path.starts_with("vendor")),
            "a .gitignore'd directory must still be searched by default: {uncapped:?}"
        );
    }

    /// The rule a reader forgets: an ignore file ABOVE the searched root. Every
    /// other test here puts the `.gitignore` inside the root, so nothing else
    /// covers `parents`, and the consequence is user-visible -- a directory
    /// that happens to sit inside a repository would otherwise answer
    /// differently from a copy of it somewhere else.
    ///
    /// Both directions, because only the pair makes this a decision rather than
    /// an accident of which flags happen to be off.
    #[tokio::test]
    async fn an_ignore_file_above_the_root_filters_only_when_ignores_are_respected() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), ".gitignore", "secret.txt\n");
        let root = dir.path().join("nested");
        write(&root, "secret.txt", "needle in a file the parent ignores\n");
        write(&root, "plain.txt", "needle in a file nobody ignores\n");

        let default = paths(&grep(&root, "needle").await);
        assert!(
            default.iter().any(|path| path == "plain.txt"),
            "nothing was searched at all: {default:?}"
        );
        assert!(
            default.iter().any(|path| path == "secret.txt"),
            "a .gitignore ABOVE the root must not filter a default search: {default:?}"
        );

        let respecting = paths(&grep_respecting_ignores(&root, "needle").await);
        assert!(
            respecting.iter().any(|path| path == "plain.txt"),
            "nothing was searched at all: {respecting:?}"
        );
        assert!(
            !respecting.iter().any(|path| path == "secret.txt"),
            "respect_ignores: true must honour a parent's .gitignore: {respecting:?}"
        );
    }

    #[tokio::test]
    async fn a_gitignored_file_or_directory_is_excluded_when_ignores_are_respected() {
        let dir = fixture();
        let found = paths(&grep_respecting_ignores(dir.path(), "needle").await);
        // Asserted FIRST: an exclusion claim over an empty result is vacuous,
        // so the test has to show the walk ran before it shows what it left out.
        assert!(
            found.iter().any(|path| path == "kept.txt"),
            "the tracked file was not searched at all: {found:?}"
        );
        assert!(
            !found.iter().any(|path| path == "ignored.txt"),
            "a .gitignore'd file was searched: {found:?}"
        );
        assert!(
            !found.iter().any(|path| path.starts_with("vendor")),
            "a .gitignore'd directory was searched: {found:?}"
        );
    }

    #[tokio::test]
    async fn the_git_directory_is_skipped_but_other_dotfiles_are_searched() {
        let dir = fixture();
        let found = paths(&grep(dir.path(), "needle").await);
        assert!(
            !found.iter().any(|path| path.starts_with(".git/")),
            "the .git directory was searched: {found:?}"
        );
        assert!(
            found.iter().any(|path| path == ".hidden.txt"),
            "dotfiles must be searched, as Tools::Grep's FNM_DOTMATCH walk does: {found:?}"
        );
    }

    #[tokio::test]
    async fn more_matches_than_the_cap_stop_at_the_cap_and_say_so() {
        let dir = fixture();
        let outcome = grep(dir.path(), "needle").await;
        assert_eq!(
            MAX_MATCHES,
            outcome.matches.len(),
            "the cap bounds the result"
        );
        assert!(
            outcome.capped,
            "a capped result must say so rather than truncate silently"
        );
    }

    #[tokio::test]
    async fn a_result_under_the_cap_is_not_reported_capped() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "small.txt", &lines(MAX_MATCHES, "needle"));
        let outcome = grep(dir.path(), "needle").await;
        assert_eq!(MAX_MATCHES, outcome.matches.len());
        assert!(
            !outcome.capped,
            "exactly the cap is not capped -- there is nothing left out"
        );
    }

    #[tokio::test]
    async fn a_match_carries_the_relative_path_the_line_number_and_the_chomped_line() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "src/deep.txt", "one\ntwo needle\nthree\n");
        let outcome = grep(dir.path(), "needle").await;
        let found = outcome.matches.first().expect("one match");
        assert_eq!("src/deep.txt", found.path, "labelled relative to the root");
        assert_eq!(2, found.line_number, "line numbers are 1-based");
        assert_eq!("two needle", found.line, "the line is chomped");
    }

    #[tokio::test]
    async fn a_single_file_target_is_labelled_with_the_path_as_given() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "solo.txt", "a needle\n");
        let file = dir.path().join("solo.txt");
        let outcome = grep(&file, "needle").await;
        assert_eq!(
            vec![file.to_string_lossy().into_owned()],
            paths(&outcome),
            "a file target keeps the caller's spelling"
        );
    }

    #[tokio::test]
    async fn case_insensitivity_is_off_by_default_and_honoured_when_asked() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "case.txt", "Needle\n");
        assert!(grep(dir.path(), "needle").await.matches.is_empty());
        let mut insensitive = params(dir.path(), "needle");
        insensitive.case_insensitive = true;
        let outcome = run(insensitive).await.expect("the search succeeds");
        assert_eq!(1, outcome.matches.len());
    }

    /// The decode half of the same claim: absent and explicit-nil both mean
    /// off, and a value that is neither nil nor a boolean fails loudly rather
    /// than being coerced into a search the caller did not ask for.
    #[test]
    fn respect_ignores_defaults_off_and_refuses_a_value_that_is_not_a_boolean() {
        let absent = GrepParams::from_value(&grep_map("/tmp", "needle", None))
            .expect("a map without the key decodes");
        assert!(!absent.respect_ignores, "absent means off");

        let nil =
            GrepParams::from_value(&flagged_map(Value::Nil)).expect("an explicit nil decodes");
        assert!(
            !nil.respect_ignores,
            "msgpack has no absent, so nil reads as the default"
        );

        let wrong = GrepParams::from_value(&flagged_map(Value::from("yes")))
            .expect_err("a string is not a boolean");
        assert_eq!("respect_ignores must be a boolean", wrong.to_string());
    }

    /// `case_insensitive` decodes through the same [`flag`] helper, and after
    /// that refactor nothing pinned ITS nil tolerance -- mutating
    /// `Value::Nil => Ok(false)` to an error reddened only the `respect_ignores`
    /// test above, leaving a shared helper half-covered. `Tools::Grep` resolves
    /// this default on the Ruby side too, so both ends agree deliberately
    /// rather than by luck.
    #[test]
    fn case_insensitive_decodes_nil_as_off_through_the_same_helper() {
        let nil = GrepParams::from_value(&grep_map_with_case(Value::Nil))
            .expect("an explicit nil decodes");
        assert!(
            !nil.case_insensitive,
            "msgpack has no absent, so nil reads as the default"
        );

        let wrong = GrepParams::from_value(&grep_map_with_case(Value::from(1)))
            .expect_err("an integer is not a boolean");
        assert_eq!("case_insensitive must be a boolean", wrong.to_string());
    }

    fn grep_map_with_case(case_insensitive: Value) -> Value {
        Value::Map(vec![
            (Value::from("pattern"), Value::from("needle")),
            (Value::from("path"), Value::from("/tmp")),
            (Value::from("case_insensitive"), case_insensitive),
        ])
    }

    fn flagged_map(respect_ignores: Value) -> Value {
        Value::Map(vec![
            (Value::from("pattern"), Value::from("needle")),
            (Value::from("path"), Value::from("/tmp")),
            (Value::from("respect_ignores"), respect_ignores),
        ])
    }

    /// How long the pathological search gets. `(a+)+$` over this corpus is
    /// 2^80 steps per line for a backtracking engine, so it would not finish in
    /// the lifetime of the universe, let alone this budget; a finite-automata
    /// engine does it in tens of milliseconds. Nothing lives between the two,
    /// which is why a wall clock can decide it at all.
    const PATHOLOGICAL_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

    /// `(a+)+$` against long runs of `a` that end in something else: the anchor
    /// never matches, so a backtracking engine tries every partition of the run
    /// before giving up. Sized to take long enough that the interleaving
    /// assertion below is about scheduling and not about noise.
    ///
    /// `probe.txt` is what keeps the test honest: it DOES match, so a run that
    /// never opened a file fails instead of passing on an empty result.
    const PATHOLOGICAL_LINES: usize = 40_000;

    fn pathological_corpus(dir: &Path) {
        write(
            dir,
            "bomb.txt",
            &lines(PATHOLOGICAL_LINES, &format!("{}b", "a".repeat(80))),
        );
        write(dir, "probe.txt", "aaa\n");
    }

    #[tokio::test]
    async fn a_pathological_pattern_completes_and_leaves_the_daemon_responsive() {
        let dir = tempfile::tempdir().expect("tempdir");
        pathological_corpus(dir.path());
        let (_socket_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;

        let started = std::time::Instant::now();
        client
            .send(request(
                1,
                "grep",
                vec![grep_map(&dir.path().to_string_lossy(), "(a+)+$", None)],
            ))
            .await;
        client.send(request(2, "ping", vec![])).await;

        // The ping overtakes the search, exactly as the fast exec overtakes the
        // slow one. It can only do so because the walk went to the blocking
        // pool: these tests run on the CURRENT-THREAD runtime, so a search done
        // inline would hold the single worker and this frame could not even be
        // read until the search finished.
        let (first, error, _) = response_parts(client.recv().await);
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(
            2, first,
            "the ping waited on the search -- the walk is holding the runtime worker"
        );

        let (second, error, result) = response_parts(client.recv().await);
        assert_eq!(1, second);
        assert!(error.is_nil(), "unexpected grep error: {error:?}");
        assert_eq!(
            1,
            field(&result, "matches")
                .as_array()
                .expect("matches is an array")
                .len(),
            "only probe.txt matches -- and it must, or the corpus went unread"
        );
        assert_eq!(Value::from("probe.txt"), match_field(&result, 0, "path"));
        assert!(
            started.elapsed() < PATHOLOGICAL_BUDGET,
            "the search took {:?} -- an engine that backtracks would not finish at all",
            started.elapsed()
        );
    }

    fn grep_map(path: &str, pattern: &str, case_insensitive: Option<bool>) -> Value {
        let mut entries = vec![
            (Value::from("pattern"), Value::from(pattern)),
            (Value::from("path"), Value::from(path)),
        ];
        if let Some(yes) = case_insensitive {
            entries.push((Value::from("case_insensitive"), Value::from(yes)));
        }
        Value::Map(entries)
    }

    fn match_field(result: &Value, index: usize, name: &str) -> Value {
        field(
            &result
                .as_map()
                .expect("result is a map")
                .iter()
                .find(|(key, _)| key.as_str() == Some("matches"))
                .expect("a matches field")
                .1
                .as_array()
                .expect("matches is an array")[index],
            name,
        )
    }

    #[tokio::test]
    async fn grep_over_the_wire_answers_matches_and_capped() {
        let dir = fixture();
        let (_socket_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let map = grep_map(&dir.path().to_string_lossy(), "needle", None);
        let (msgid, error, result) = client.call(1, "grep", vec![map]).await;
        assert_eq!(1, msgid);
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert_eq!(Value::from(true), field(&result, "capped"));
        assert_eq!(
            MAX_MATCHES,
            field(&result, "matches")
                .as_array()
                .expect("matches is an array")
                .len()
        );
        assert_eq!(Value::from(".hidden.txt"), match_field(&result, 0, "path"));
        assert_eq!(Value::from(1), match_field(&result, 0, "line_number"));
        assert_eq!(
            Value::from("needle in a dotfile"),
            match_field(&result, 0, "line")
        );
    }

    fn wire_paths(result: &Value) -> Vec<String> {
        let matches = field(result, "matches");
        matches
            .as_array()
            .expect("matches is an array")
            .iter()
            .map(|found| {
                field(found, "path")
                    .as_str()
                    .expect("a path string")
                    .to_string()
            })
            .collect()
    }

    /// The param has to survive the WHOLE decode path, not merely exist on the
    /// struct. Both directions are asserted against one running daemon, so the
    /// only difference between the two calls is the key itself -- a
    /// `Draft::apply` arm that was never wired up, or a walker that ignores the
    /// decoded field, fails here and nowhere else on the wire.
    #[tokio::test]
    async fn respect_ignores_rides_the_wire_and_decides_what_comes_back() {
        let dir = fixture();
        let (_socket_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;
        let root = dir.path().to_string_lossy().into_owned();

        let respecting = Value::Map(vec![
            (Value::from("pattern"), Value::from("needle")),
            (Value::from("path"), Value::from(root.clone())),
            (Value::from("respect_ignores"), Value::from(true)),
        ]);
        let (_, error, result) = client.call(1, "grep", vec![respecting]).await;
        assert!(error.is_nil(), "unexpected error: {error:?}");
        let found = wire_paths(&result);
        assert!(
            found.iter().any(|path| path == "kept.txt"),
            "nothing was searched at all: {found:?}"
        );
        assert!(
            !found.iter().any(|path| path == "ignored.txt"),
            "respect_ignores: true must skip the .gitignore'd file: {found:?}"
        );

        let (_, error, result) = client
            .call(2, "grep", vec![grep_map(&root, "needle", None)])
            .await;
        assert!(error.is_nil(), "unexpected error: {error:?}");
        assert!(
            wire_paths(&result).iter().any(|path| path == "ignored.txt"),
            "omitting the key must keep Dir.glob's semantics over the wire too"
        );
    }

    #[tokio::test]
    async fn an_invalid_pattern_and_a_missing_path_are_error_replies_not_closes() {
        let dir = tempfile::tempdir().expect("tempdir");
        let (_socket_dir, path) = start_server().await;
        let mut client = TestClient::connect(&path).await;

        let bad_pattern = grep_map(&dir.path().to_string_lossy(), "(unclosed", None);
        let (msgid, error, _) = client.call(1, "grep", vec![bad_pattern]).await;
        assert_eq!(1, msgid);
        assert!(!error.is_nil(), "an invalid pattern must be an error reply");

        let missing: PathBuf = dir.path().join("nope");
        let gone = grep_map(&missing.to_string_lossy(), "needle", None);
        let (msgid, error, _) = client.call(2, "grep", vec![gone]).await;
        assert_eq!(2, msgid);
        let message = error.as_str().expect("error is a string").to_string();
        assert!(
            message.contains("no such file or directory"),
            "the message mirrors Tools::Grep's: {message}"
        );

        // Unknown params fail loudly, as exec's do.
        let typo = Value::Map(vec![
            (Value::from("pattern"), Value::from("needle")),
            (
                Value::from("path"),
                Value::from(dir.path().to_string_lossy().into_owned()),
            ),
            (Value::from("case_sensitive"), Value::from(true)),
        ]);
        let (msgid, error, _) = client.call(3, "grep", vec![typo]).await;
        assert_eq!(3, msgid);
        assert!(!error.is_nil(), "an unknown param must be an error reply");

        // The connection survived all three.
        let (msgid, error, _) = client.call(4, "ping", vec![]).await;
        assert_eq!(4, msgid);
        assert!(error.is_nil());
    }
}

// The hazard family behind `readable_kind`'s stat-then-open split. These were
// panel probes first: the fix shipped with no test at all, and the review's
// mutation audit showed that reverting `readable_kind` to a single `File::open`
// left every other test in this file green. The regression they exist to catch
// is a blocking-pool thread parked forever inside `open(2)` -- and there is no
// timeout anywhere that can recover it (see the `run` doc), so nothing else
// would ever notice.
//
// Every probe runs `search` on a PLAIN OS THREAD with a channel deadline rather
// than under tokio, deliberately: a parked blocking-pool thread makes the tokio
// runtime's own shutdown hang, so a tokio-hosted version reports "test timed
// out" instead of naming which path parked.
#[cfg(test)]
mod probe_hazards {
    use std::os::unix::fs::symlink;
    use std::path::Path;
    use std::sync::mpsc;
    use std::time::Duration;

    use super::{GrepParams, search};

    const DEADLINE: Duration = Duration::from_secs(3);

    fn write(dir: &Path, relative: &str, contents: &str) {
        std::fs::write(dir.join(relative), contents).expect("write the fixture file");
    }

    enum Answer {
        Matches(usize),
        Error(String),
        Parked,
    }

    /// Runs `search` off-runtime and refuses to wait forever. `Parked` is the
    /// finding: it means the call is inside a blocking syscall no timeout can
    /// end, which is exactly the defect the handback claims to have fixed.
    fn probe(path: &Path, pattern: &str) -> Answer {
        let params = GrepParams {
            pattern: pattern.to_string(),
            path: path.to_string_lossy().into_owned(),
            case_insensitive: false,
            respect_ignores: false,
        };
        let (tx, rx) = mpsc::channel();
        // Detached on purpose: if it IS parked, joining would hang the probe.
        std::thread::spawn(move || {
            let _ = tx.send(match search(&params) {
                Ok(outcome) => Answer::Matches(outcome.matches.len()),
                Err(error) => Answer::Error(error.to_string()),
            });
        });
        rx.recv_timeout(DEADLINE).unwrap_or(Answer::Parked)
    }

    fn describe(answer: &Answer) -> String {
        match answer {
            Answer::Matches(count) => format!("ok, {count} matches"),
            Answer::Error(message) => format!("error: {message}"),
            Answer::Parked => "PARKED -- blocking-pool thread lost forever".to_string(),
        }
    }

    fn assert_not_parked(label: &str, answer: Answer) {
        assert!(
            !matches!(answer, Answer::Parked),
            "{label}: {}",
            describe(&answer)
        );
    }

    fn mkfifo(path: &Path) {
        let status = std::process::Command::new("mkfifo")
            .arg(path)
            .status()
            .expect("mkfifo runs");
        assert!(status.success(), "mkfifo failed for {}", path.display());
    }

    // ---- 1. the root itself is a hazardous kind -------------------------

    #[test]
    fn probe_fifo_as_the_root_does_not_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        let fifo = dir.path().join("pipe");
        mkfifo(&fifo);
        assert_not_parked("a FIFO named as the grep root", probe(&fifo, "needle"));
    }

    #[test]
    fn probe_unix_socket_as_the_root_does_not_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        let socket = dir.path().join("sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
        assert_not_parked("a unix socket named as the grep root", probe(&socket, "x"));
    }

    #[test]
    fn probe_character_device_as_the_root_does_not_park() {
        // /dev/zero would yield NUL bytes forever if it were ever opened and
        // read; the stat-first guard must keep it out of the searcher.
        assert_not_parked(
            "/dev/zero as the grep root",
            probe(Path::new("/dev/zero"), "x"),
        );
    }

    #[test]
    fn probe_symlink_to_a_fifo_does_not_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        let fifo = dir.path().join("pipe");
        mkfifo(&fifo);
        let link = dir.path().join("link");
        symlink(&fifo, &link).expect("symlink");
        assert_not_parked("a symlink to a FIFO", probe(&link, "needle"));
    }

    #[test]
    fn probe_symlink_loop_is_an_error_not_a_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        symlink(&b, &a).expect("symlink a->b");
        symlink(&a, &b).expect("symlink b->a");
        let answer = probe(&a, "needle");
        assert_not_parked("a symlink loop", answer);
    }

    // ---- 2. the hazardous kind is INSIDE the searched tree --------------

    #[test]
    fn probe_a_fifo_inside_the_tree_does_not_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "kept.txt", "needle\n");
        mkfifo(&dir.path().join("pipe"));
        let answer = probe(dir.path(), "needle");
        assert_not_parked("a FIFO sitting inside the searched tree", answer);
    }

    #[test]
    fn probe_a_symlink_to_a_fifo_inside_the_tree_does_not_park() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "kept.txt", "needle\n");
        let fifo = dir.path().join("pipe");
        mkfifo(&fifo);
        symlink(&fifo, dir.path().join("link")).expect("symlink");
        assert_not_parked(
            "a symlink to a FIFO inside the tree",
            probe(dir.path(), "needle"),
        );
    }

    #[test]
    fn probe_dev_as_a_searched_tree_does_not_park() {
        // The nastiest realistic case: a caller greps a mount full of device
        // nodes and FIFOs. Bounded to /dev/mqueue-free ground by using /dev
        // itself, which on Linux holds char devices, block devices, sockets
        // and at least one FIFO under normal operation.
        assert_not_parked(
            "/dev walked as a directory",
            probe(Path::new("/dev"), "zzz-no-such-needle"),
        );
    }

    // ---- 3. permissions and disappearance ------------------------------

    #[test]
    fn probe_unreadable_directory_is_an_error_not_a_park() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir");
        let closed = dir.path().join("closed");
        std::fs::create_dir(&closed).expect("mkdir");
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o000)).expect("chmod");
        let answer = probe(&closed, "needle");
        let described = describe(&answer);
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o755)).expect("restore");
        assert!(
            described.contains("not readable"),
            "an unreadable directory must be a loud error, got: {described}"
        );
    }

    #[test]
    fn probe_unreadable_file_inside_the_tree_is_skipped_not_fatal() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "kept.txt", "needle\n");
        write(dir.path(), "closed.txt", "needle\n");
        let closed = dir.path().join("closed.txt");
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o000)).expect("chmod");
        let answer = probe(dir.path(), "needle");
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o644)).expect("restore");
        assert!(
            matches!(answer, Answer::Matches(1)),
            "one readable file must still be reported: {}",
            describe(&answer)
        );
    }

    /// TOCTOU: `readable_kind` stats, then opens. If the path becomes a FIFO
    /// in between, the open blocks and the guard is bypassed. This probe races
    /// a swapper thread against repeated searches to show whether the window
    /// is reachable in practice.
    #[test]
    fn probe_regular_file_swapped_for_a_fifo_between_stat_and_open() {
        let dir = tempfile::tempdir().expect("tempdir");
        let target = dir.path().join("target");
        let fifo = dir.path().join("staged-fifo");
        let plain = dir.path().join("staged-plain");
        mkfifo(&fifo);
        std::fs::write(&plain, "needle\n").expect("write");

        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let flag = stop.clone();
        let (fifo_path, plain_path, target_path) = (fifo.clone(), plain.clone(), target.clone());
        let swapper = std::thread::spawn(move || {
            while !flag.load(std::sync::atomic::Ordering::Relaxed) {
                let _ = std::fs::rename(&plain_path, &target_path);
                let _ = std::fs::hard_link(&fifo_path, target_path.with_extension("tmp"));
                let _ = std::fs::rename(target_path.with_extension("tmp"), &target_path);
                let _ = std::fs::rename(&target_path, &plain_path);
            }
        });

        let mut parked = false;
        for _ in 0..200 {
            if matches!(probe(&target, "needle"), Answer::Parked) {
                parked = true;
                break;
            }
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        let _ = swapper.join();
        // Recorded, not asserted red: the window is genuinely narrow. What
        // matters for the review is whether it is reachable AT ALL, because
        // there is no timeout anywhere that can recover the thread if it is.
        assert!(
            !parked,
            "the stat/open window was hit -- a thread is parked"
        );
    }
}

// `walk`'s doc comment argues that `sort_by_file_path` is required because the
// cap makes ordering observable -- which 200 matches come back is part of the
// answer. Deleting that line used to kill zero tests: it was the lone survivor
// of the review's 11-mutation audit, and the wire test's ".hidden.txt is first"
// assertion passed only because this filesystem's readdir order happened to
// agree.
//
// The two here do different jobs, and only the first is the pin: deleting
// `sort_by_file_path` turns `probe_results_are_sorted_regardless_of_creation_order`
// red and leaves `probe_the_nested_fixture_that_diverges_from_ruby` GREEN on
// this filesystem, because with one directory and one file readdir happens to
// hand back the order a sorted walk would. So the second is a witness, not a
// guard -- it records the fixture on which `Tools::Grep` and this walk disagree
// (`["a.txt", "a/b.txt"]` against `["a/b.txt", "a.txt"]`), which is a fact T13
// needs and not a regression this file can catch.
#[cfg(test)]
mod probe_ordering {
    use std::path::Path;

    use super::{GrepParams, run};

    fn write(dir: &Path, relative: &str, contents: &str) {
        let path = dir.join(relative);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
        std::fs::write(path, contents).expect("write");
    }

    async fn labels(dir: &Path) -> Vec<String> {
        run(GrepParams {
            pattern: "needle".to_string(),
            path: dir.to_string_lossy().into_owned(),
            case_insensitive: false,
            respect_ignores: false,
        })
        .await
        .expect("the search succeeds")
        .matches
        .into_iter()
        .map(|found| found.path)
        .collect()
    }

    /// Files CREATED in reverse-sorted order must still come back sorted. A
    /// walk that trusts readdir returns creation order on ext4/tmpfs, so this
    /// is the assertion `sort_by_file_path` actually earns.
    #[tokio::test]
    async fn probe_results_are_sorted_regardless_of_creation_order() {
        let dir = tempfile::tempdir().expect("tempdir");
        let names = ["zebra.txt", "mango.txt", "cherry.txt", "apple.txt"];
        for name in names {
            write(dir.path(), name, "needle\n");
        }
        let found = labels(dir.path()).await;
        let mut sorted = found.clone();
        sorted.sort();
        assert_eq!(
            sorted, found,
            "results must be sorted, not in readdir order -- the cap makes \
             WHICH matches come back part of the answer"
        );
    }

    /// The same claim across directory boundaries, which is where the sort has
    /// to be per-directory-and-depth-first rather than a flat sort. This is
    /// also the fixture that shows Ruby and Rust genuinely DISAGREE (see
    /// probe_ruby_parity.rb): `Tools::Grep` sorts one flat list of full paths,
    /// where "a.txt" < "a/b.txt" because '.' < '/'; `ignore` sorts per
    /// directory and descends, so "a/b.txt" comes first.
    #[tokio::test]
    async fn probe_the_nested_fixture_that_diverges_from_ruby() {
        let dir = tempfile::tempdir().expect("tempdir");
        write(dir.path(), "a.txt", "needle\n");
        write(dir.path(), "a/b.txt", "needle\n");
        let found = labels(dir.path()).await;
        assert_eq!(
            vec!["a/b.txt".to_string(), "a.txt".to_string()],
            found,
            "ignore walks depth-first per directory; Ruby's flat sort of full \
             paths puts a.txt FIRST. With the cap in play this decides which \
             200 matches a capped result contains."
        );
    }
}
