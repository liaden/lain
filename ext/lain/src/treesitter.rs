//! Pure, libruby-free RAW tree-sitter query over `ast-grep-language`'s bundled
//! grammars.
//!
//! Where `astgrep.rs` exposes the ergonomic metavariable *pattern* surface
//! (`def $NAME(...)`), this exposes tree-sitter's own S-expression query engine
//! directly: `(method name: (identifier) @name)`. An agent that knows the
//! grammar can name nodes and fields precisely, which the pattern surface
//! cannot express. The two share one grammar set -- the language is obtained via
//! `ast_grep_language::SupportLang::get_ts_language()`, so NO separate
//! `tree-sitter-*` grammar dependency is pulled in, and the runtime ABI matches
//! the grammars ast-grep already links (both resolve `tree-sitter 0.27.0`).
//!
//! Every call is observably STATELESS: parse an in-memory `&str`, run one
//! compiled query, return an owned `Vec<Capture>` in match-then-capture order.
//! The one thing kept between calls is a per-thread cache of compiled
//! queries, which changes cost and never an answer. There is no index handle to
//! keep, so -- unlike `Bm25` -- this needs no `TypedData` wrapper and makes no
//! `frozen_shareable` promise; the FFI wrapper just freezes the Ruby Array it
//! builds per call.
//!
//! Nothing in this layer touches `magnus`, so language parsing, capture
//! extraction, and malformed-query rejection are all unit-tested in `cargo test`
//! without an embedded Ruby VM.
//!
//! Byte offsets only. Byte -> line/column conversion is the Ruby wrapper's job.

use crate::local::{BoundedCache, with_local};
use crate::nogvl::{Cancel, Halted, Threshold};
use ast_grep_language::{LanguageExt, SupportLang};
use std::cell::{Cell, RefCell};
use std::ops::ControlFlow;
use std::rc::Rc;
use tree_sitter::{
    LanguageError, ParseOptions, Parser, Query, QueryCursor, QueryCursorOptions, StreamingIterator,
    Tree,
};

/// One named capture (`@name`) and where its node sits in the source. A single
/// query run yields these flat, in match-then-capture order: a raw tree-sitter
/// query's natural result is the capture, not a pattern's metavariable binding,
/// so there is no per-match grouping the way `astgrep::Match` has.
#[derive(Debug, PartialEq, Eq)]
pub struct Capture {
    /// The `@name` the query bound this node to (without the leading `@`).
    pub name: String,
    /// The exact source text of the captured node.
    pub text: String,
    /// Byte offsets into the source of the captured node.
    pub start: usize,
    pub end: usize,
}

/// Why a query could not run. `Display` IS the FFI-visible message: `BadQuery`
/// maps to the named `TreeSitter::BadQuery` (a `Lain::Error`); an unknown
/// language is a plain argument error at the boundary; `Backend` is the loud,
/// FFI-unreachable arm for a grammar/parser setup failure (an ABI mismatch would
/// surface here, but the pinned `tree-sitter` matches ast-grep's grammars).
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum QueryFailure {
    #[error("unknown language {0:?}")]
    UnknownLanguage(String),
    /// The S-expression does not compile to a valid tree-sitter query --
    /// unbalanced parens, an unknown node kind or field, a dangling `@capture`.
    /// A fat-fingered query gets a loud raise, never a silent zero-match.
    #[error("malformed query {query:?}: {reason}")]
    BadQuery { query: String, reason: String },
    /// Setting the grammar on the parser, or parsing the source, failed. Both
    /// are unreachable through the FFI surface (a known language always yields a
    /// valid grammar whose ABI matches the pinned runtime, and tree-sitter is
    /// error-tolerant so `parse` returns a tree for any input) -- but a future
    /// ABI drift must fail loudly here, not materialize an empty result.
    #[error("tree-sitter backend error: {0}")]
    Backend(String),
}

/// Parse a language moniker (`"ruby"`, case-insensitive) into a `SupportLang`.
fn parse_lang(lang: &str) -> Result<SupportLang, QueryFailure> {
    lang.parse()
        .map_err(|_| QueryFailure::UnknownLanguage(lang.to_string()))
}

/// Sources shorter than this are queried with the GVL held. Releasing hands the
/// lock to any busy Ruby thread and waits out its time slice to get it back:
/// 20 ms beside a thread at `Tool::Offload`'s priority, 100 ms at 0, against
/// 0.2 ms for a `Shell::Parse` command. At the slowest rate measured over this
/// checkout's sources (859 us per KB, markdown sections) 32 KiB costs about 27 ms,
/// about 1 offload slice, so below it holding costs a busy thread no more than
/// releasing would cost the caller.
pub const HOLD_BELOW: Threshold = Threshold::new(32 * 1024);

/// All captures bound by running `query_src` against `src`, in match-then-capture
/// order, or [`Halted`] once `cancel` asks, during the parse or the matching. A
/// valid query with no matches yields an empty `Vec` (not an error).
///
/// Built-in text predicates (`#eq?`, `#match?`) DO filter. But tree-sitter
/// treats an unknown/misspelled general predicate (`#nonsense?`, `#eqq?`) as
/// inert -- it compiles fine and is silently ignored, so a typo'd predicate
/// yields UNFILTERED results with no error. That is inherent to tree-sitter's
/// design (the host is expected to interpret general predicates) and this is the
/// explicitly "raw" surface, so it is not enforced here.
pub fn query_until(
    src: &str,
    lang: &str,
    query_src: &str,
    cancel: &Cancel<'_>,
) -> Result<Result<Vec<Capture>, QueryFailure>, Halted> {
    let (lang, query) = match parse_lang(lang)
        .and_then(|lang| compiled(lang, query_src).map(|query| (lang, query)))
    {
        Ok(ready) => ready,
        Err(refused) => return Ok(Err(refused)),
    };
    run(&query, src, lang, cancel)
}

/// Compile `query_src` for `lang`, rejecting a query that binds no `@capture`.
///
/// Such a query can never emit output for ANY source -- an empty/whitespace/
/// comment-only query (zero patterns) or a structural query with no `@` (e.g.
/// `(method)`). That is a fat-fingered query, not a no-match, so it raises
/// rather than returning a silent `[]` -- the same worst-failure class the
/// astgrep guard fights. Safe against over-rejection BECAUSE a real query the
/// caller wants results from MUST bind >=1 capture; `(method) @m` on
/// non-matching source keeps returning `[]` (a genuine no-match), since it binds
/// one capture and merely finds nothing there.
fn compile(lang: SupportLang, query_src: &str) -> Result<Query, QueryFailure> {
    let bad = |reason: String| QueryFailure::BadQuery {
        query: query_src.to_string(),
        reason,
    };
    let compiled =
        Query::new(&lang.get_ts_language(), query_src).map_err(|err| bad(err.to_string()))?;
    if compiled.capture_names().is_empty() {
        return Err(bad(
            "query binds no @capture, so it can never yield a result".to_string(),
        ));
    }
    Ok(compiled)
}

thread_local! {
    /// Compiled queries by language, then by query source.
    ///
    /// `Query::new` resolves every name against the whole grammar, so it costs
    /// milliseconds even for a one-node query, while running it on a short command
    /// costs microseconds; `Shell::Parse` compiles the same constant query for every
    /// command it classifies. A compiled `Query` carries no per-run state (that is
    /// the `QueryCursor`, which stays per call), so a reused one answers exactly as
    /// a fresh one does -- `a_cached_query_agrees_with_a_fresh_one` is the proof.
    ///
    /// Per thread, so the cache needs no lock and holds `Rc` rather than `Arc`.
    /// It stays safe with the GVL released because `rb_nogvl` runs the job on
    /// the calling thread, so only that thread ever reaches its cache. 64 is far
    /// above the handful of constant queries `lib/` passes.
    static QUERIES: RefCell<BoundedCache<SupportLang, Query>> = RefCell::new(BoundedCache::new(64));
}

/// The thread's cached compile of `query_src`.
fn compiled(lang: SupportLang, query_src: &str) -> Result<Rc<Query>, QueryFailure> {
    with_local(
        &QUERIES,
        || BoundedCache::new(64),
        |cache| cache.get_or_insert_with(lang, query_src, || compile(lang, query_src)),
    )
}

/// Every capture `compiled` binds in `src`, in match-then-capture order.
fn run(
    compiled: &Query,
    src: &str,
    lang: SupportLang,
    cancel: &Cancel<'_>,
) -> Result<Result<Vec<Capture>, QueryFailure>, Halted> {
    let tree = match parse_until(src, lang, cancel)? {
        Ok(tree) => tree,
        Err(refused) => return Ok(Err(refused.into_failure(lang))),
    };
    captures_of(compiled, &tree, src, cancel).map(Ok)
}

/// Why a parse produced no tree for a reason other than a stop request.
#[derive(Debug, thiserror::Error)]
pub enum ParseRefusal {
    /// tree-sitter refused the bundled grammar.
    #[error("{0}")]
    Grammar(LanguageError),
    /// The parser answered nothing though nobody asked it to stop.
    #[error("parser produced no tree")]
    NoTree,
}

impl ParseRefusal {
    fn into_failure(self, lang: SupportLang) -> QueryFailure {
        QueryFailure::Backend(match self {
            Self::Grammar(refused) => refused.to_string(),
            Self::NoTree => format!("parser produced no tree for {lang}"),
        })
    }
}

/// Reads the stop request for tree-sitter's progress callbacks, and remembers
/// whether it stopped one: a stopped parse answers no tree and a stopped query
/// cursor just runs out of matches, and neither may pass for a whole answer.
struct Watch<'c> {
    cancel: &'c Cancel<'c>,
    stopped: Cell<bool>,
}

impl<'c> Watch<'c> {
    fn over(cancel: &'c Cancel<'c>) -> Self {
        Self {
            cancel,
            stopped: Cell::new(false),
        }
    }

    fn tick(&self) -> ControlFlow<()> {
        match self.cancel.check() {
            Ok(()) => ControlFlow::Continue(()),
            Err(Halted) => {
                self.stopped.set(true);
                ControlFlow::Break(())
            }
        }
    }

    fn halted(&self) -> Result<(), Halted> {
        if self.stopped.get() {
            Err(Halted)
        } else {
            Ok(())
        }
    }

    fn tree_or_halt(
        &self,
        parsed: Result<Option<Tree>, LanguageError>,
    ) -> Result<Result<Tree, ParseRefusal>, Halted> {
        match parsed {
            Ok(Some(tree)) => Ok(Ok(tree)),
            Ok(None) => self.halted().map(|()| Err(ParseRefusal::NoTree)),
            Err(refused) => Ok(Err(ParseRefusal::Grammar(refused))),
        }
    }
}

thread_local! {
    /// One per thread, so a parse reuses the parser's allocations: `Shell::Parse`
    /// parses several times per command. The parse runs on the calling thread
    /// even with the GVL released.
    static PARSER: RefCell<Parser> = RefCell::new(Parser::new());
}

/// Parses `src` as `lang`, or gives up with [`Halted`] once `cancel` asks. Shared
/// with `astgrep`, which parses the same way.
pub fn parse_until(
    src: &str,
    lang: SupportLang,
    cancel: &Cancel<'_>,
) -> Result<Result<Tree, ParseRefusal>, Halted> {
    let watch = Watch::over(cancel);
    let mut progress = |_: &_| watch.tick();
    let bytes = src.as_bytes();
    let parsed = with_local(&PARSER, Parser::new, |parser| {
        parser.set_language(&lang.get_ts_language()).map(|()| {
            // A halted parse resumes on the next call unless the parser is reset.
            parser.reset();
            parser.parse_with_options(
                &mut |at, _| bytes.get(at..).unwrap_or_default(),
                None,
                Some(ParseOptions::new().progress_callback(&mut progress)),
            )
        })
    });
    watch.tree_or_halt(parsed)
}

fn captures_of(
    compiled: &Query,
    tree: &Tree,
    src: &str,
    cancel: &Cancel<'_>,
) -> Result<Vec<Capture>, Halted> {
    let watch = Watch::over(cancel);
    let mut progress = |_: &_| watch.tick();
    let names = compiled.capture_names();
    let src_bytes = src.as_bytes();
    let mut cursor = QueryCursor::new();
    // tree-sitter 0.25+ hands back a StreamingIterator, not a std Iterator, so
    // this is a `while let Some(..) = it.next()` drive rather than a `for`/`map`
    // -- the borrow of the reused row buffer is what forbids a plain Iterator.
    let mut matches = cursor.matches_with_options(
        compiled,
        tree.root_node(),
        src_bytes,
        QueryCursorOptions::new().progress_callback(&mut progress),
    );
    let mut out = Vec::new();
    while let Some(matched) = matches.next() {
        matched.captures().iter().for_each(|capture| {
            let node = capture.node;
            let range = node.byte_range();
            out.push(Capture {
                name: names[capture.index as usize].to_string(),
                // A captured node always lies on a char boundary of its own
                // `&str` source, so `utf8_text` cannot fail -- but if that
                // invariant ever broke it must fail LOUD (the panic becomes a
                // Ruby exception), not silently return an empty capture, per
                // the crate's no-silent-corner rule.
                text: node
                    .utf8_text(src_bytes)
                    .expect("captured node lies on a char boundary of its own source")
                    .to_string(),
                start: range.start,
                end: range.end,
            });
        });
    }
    watch.halted().map(|()| out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_sources::{checkout, sources};

    /// Every test's view: a query nothing cancels.
    /// `Shell::Parse::MAX_BYTES`, the longest command it hands to a query.
    const SHELL_PARSE_CAP: usize = 4096;

    fn query(src: &str, lang: &str, query_src: &str) -> Result<Vec<Capture>, QueryFailure> {
        query_until(src, lang, query_src, &Cancel::never()).expect("nothing asked it to halt")
    }

    /// The query every caller ran before the cancellable one, kept as the oracle.
    fn captured_all(compiled: &Query, src: &str, lang: SupportLang) -> Vec<Capture> {
        let mut parser = Parser::new();
        parser.set_language(&lang.get_ts_language()).unwrap();
        let tree = parser.parse(src, None).unwrap();
        let names = compiled.capture_names();
        let mut cursor = QueryCursor::new();
        let mut matches = cursor.matches(compiled, tree.root_node(), src.as_bytes());
        let mut out = Vec::new();
        while let Some(matched) = matches.next() {
            for capture in matched.captures() {
                let range = capture.node.byte_range();
                out.push(Capture {
                    name: names[capture.index as usize].to_string(),
                    text: src[range.clone()].to_string(),
                    start: range.start,
                    end: range.end,
                });
            }
        }
        out
    }

    fn chunker_query(lang: &str, name: &str) -> String {
        let path = checkout().join(format!("lib/lain/structural/queries/{lang}/{name}.scm"));
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn the_cancellable_query_finds_what_the_plain_query_finds_over_this_checkouts_sources() {
        let corpora = [
            ("ruby", "symbols", sources(&["lib"], "rb", 8)),
            ("rust", "symbols", sources(&["ext/lain/src"], "rs", 1)),
            (
                "markdown",
                "sections",
                sources(&["docs", "planning"], "md", 8),
            ),
        ];
        let mut total = 0;
        for (lang, name, files) in &corpora {
            assert!(files.len() > 10, "read {} {lang} files", files.len());
            let query_src = chunker_query(lang, name);
            let support = parse_lang(lang).unwrap();
            let fresh = compile(support, &query_src).unwrap();
            for src in files {
                let captured = query(src, lang, &query_src).unwrap();
                assert_eq!(
                    captured,
                    captured_all(&fresh, src, support),
                    "{lang} {name}"
                );
                total += captured.len();
            }
        }
        assert!(total > 10_000, "only {total} captures compared");
    }

    #[test]
    fn a_raised_flag_halts_the_parse() {
        let src = "def m(a)\n  a.save\nend\n".repeat(2_000);
        assert_eq!(
            parse_until(&src, SupportLang::Ruby, &Cancel::raised()).err(),
            Some(Halted)
        );
        assert_eq!(
            query_until(&src, "ruby", "(method) @m", &Cancel::raised()),
            Err(Halted)
        );
    }

    #[test]
    fn a_shell_command_at_the_parse_cap_keeps_the_lock() {
        assert!(!HOLD_BELOW.releases(SHELL_PARSE_CAP));
    }

    #[test]
    fn a_raised_flag_halts_the_matches_over_a_parsed_tree() {
        let src = "def m(a)\n  a.save\nend\n".repeat(2_000);
        let compiled = compile(SupportLang::Ruby, "(method) @m").unwrap();
        let tree = parse_until(&src, SupportLang::Ruby, &Cancel::never())
            .unwrap()
            .unwrap();
        assert_eq!(
            captures_of(&compiled, &tree, &src, &Cancel::raised()),
            Err(Halted)
        );
        assert_eq!(
            captures_of(&compiled, &tree, &src, &Cancel::never())
                .unwrap()
                .len(),
            2_000
        );
    }

    #[test]
    fn a_refused_query_or_language_is_a_failure_not_a_halt() {
        assert!(matches!(
            query_until("x = 1", "ruby", "(method name: @nope", &Cancel::raised()),
            Ok(Err(QueryFailure::BadQuery { .. }))
        ));
        assert!(matches!(
            query_until("x = 1", "klingon", "(identifier) @i", &Cancel::raised()),
            Ok(Err(QueryFailure::UnknownLanguage(_)))
        ));
    }

    #[test]
    fn a_parser_with_no_tree_and_no_stop_is_a_backend_failure() {
        let (never, raised) = (Cancel::never(), Cancel::raised());
        let watch = Watch::over(&never);
        assert!(matches!(
            watch.tree_or_halt(Ok(None)),
            Ok(Err(ParseRefusal::NoTree))
        ));
        let stopped = Watch::over(&raised);
        assert!(stopped.tick().is_break());
        assert_eq!(stopped.tree_or_halt(Ok(None)).err(), Some(Halted));
    }

    #[test]
    fn captures_a_named_field_with_a_byte_range() {
        let src = "def total(x)\n  x\nend";
        let captures = query(src, "ruby", "(method name: (identifier) @name)").unwrap();

        let name = captures
            .iter()
            .find(|c| c.name == "name")
            .expect("a @name capture");
        assert_eq!(name.text, "total");
        assert!(name.start < name.end);
        // The capture's bytes address `total` in the source.
        assert_eq!(&src[name.start..name.end], "total");
    }

    #[test]
    fn ruby_method_is_the_method_node_kind() {
        // Parity with astgrep's CST dump: `def x` is a `method`. If tree-sitter
        // ever renamed the node this query would compile but match nothing, so
        // a non-empty result is what pins the kind name.
        let captures = query("def x; end", "ruby", "(method) @m").unwrap();
        assert_eq!(captures.len(), 1);
        assert_eq!(captures[0].name, "m");
    }

    #[test]
    fn malformed_query_is_a_bad_query_error() {
        assert!(matches!(
            query("def x; end", "ruby", "(method name: @nope"),
            Err(QueryFailure::BadQuery { .. })
        ));
    }

    #[test]
    fn unknown_node_kind_is_a_bad_query_error() {
        assert!(matches!(
            query("x = 1", "ruby", "(no_such_node) @n"),
            Err(QueryFailure::BadQuery { .. })
        ));
    }

    #[test]
    fn valid_query_with_no_matches_is_empty_not_an_error() {
        assert_eq!(query("x = 1", "ruby", "(method) @m").unwrap(), vec![]);
    }

    #[test]
    fn captureless_query_is_a_bad_query_error() {
        // A query binding no `@capture` can never emit output for ANY source, so
        // it is a fat-fingered query, not a no-match -- the same silent-[] worst
        // failure the astgrep guard fights. Covers empty/whitespace/comment-only
        // (zero patterns) and structurally-matching-but-unbound queries alike.
        [
            "",
            "   ",
            "; only a comment",
            "(method)",
            "[(method) (class)]",
        ]
        .iter()
        .for_each(|query_src| {
            assert!(
                matches!(
                    query("def x;end", "ruby", query_src),
                    Err(QueryFailure::BadQuery { .. })
                ),
                "capture-less query {query_src:?} must raise BadQuery, not a silent []",
            );
        });
    }

    #[test]
    fn unknown_language_is_an_error() {
        assert!(matches!(
            query("x = 1", "klingon", "(identifier) @i"),
            Err(QueryFailure::UnknownLanguage(lang)) if lang == "klingon"
        ));
    }

    #[test]
    fn multiple_captures_come_back_flat() {
        let captures = query(
            "a.save\nb.save\n",
            "ruby",
            "(call receiver: (identifier) @recv)",
        )
        .unwrap();
        let recvs: Vec<&str> = captures
            .iter()
            .filter(|c| c.name == "recv")
            .map(|c| c.text.as_str())
            .collect();
        assert_eq!(recvs, vec!["a", "b"]);
    }

    #[test]
    fn two_queries_are_identical() {
        let a = query(
            "def total(x)\n  x\nend",
            "ruby",
            "(method name: (identifier) @name)",
        )
        .unwrap();
        let b = query(
            "def total(x)\n  x\nend",
            "ruby",
            "(method name: (identifier) @name)",
        )
        .unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn a_cached_query_agrees_with_a_fresh_one() {
        let src = "a.save\nb.save\ndef total(x)\n  x\nend\n";
        let query_src = "(call receiver: (identifier) @recv) (method name: (identifier) @name)";
        let mut cache = BoundedCache::new(64);
        let cached = cache
            .get_or_insert_with(SupportLang::Ruby, query_src, || {
                compile(SupportLang::Ruby, query_src)
            })
            .unwrap();
        let fresh = compile(SupportLang::Ruby, query_src).unwrap();
        let first = run(&cached, src, SupportLang::Ruby, &Cancel::never())
            .unwrap()
            .unwrap();
        let reused = run(&cached, src, SupportLang::Ruby, &Cancel::never())
            .unwrap()
            .unwrap();
        let expected = run(&fresh, src, SupportLang::Ruby, &Cancel::never())
            .unwrap()
            .unwrap();
        assert_eq!(first, expected);
        assert_eq!(reused, expected);
        assert_eq!(expected.len(), 3, "2 receivers and 1 method name");
    }
}

#[cfg(not(test))]
pub mod ffi {
    use super::{Capture, HOLD_BELOW, QueryFailure, query_until};
    use crate::ffi::{frozen_str, int, lookup_error};
    use crate::nogvl::{Cancel, without_gvl_when};
    // The one string-boundary policy, shared with `fuzzy`, `prompt` and
    // `astgrep`. Same reason as `astgrep`'s: this binding's pinned contract is
    // byte offsets into the caller's own String, and magnus's `String`
    // conversion would silently transcode anything that is not already UTF-8,
    // leaving every `start`/`end` addressing a copy the caller cannot see.
    //
    // Same taxonomy split as `astgrep::ffi` documents at length: `BadQuery` is a
    // `Lain::Error` because a malformed S-expression is lain's vocabulary, while
    // the encoding refusal is Ruby's bare `EncodingError`. Rescuing `Lain::Error`
    // alone will not catch it.
    use crate::read_text::text_of;
    use magnus::{Error, RArray, RString, Ruby, Value, prelude::*};

    /// `Lain::Ext::TreeSitter.query(src, lang, query)` -> a frozen Array of
    /// frozen capture Hashes `{ "name", "text", "start", "end" }`, one per
    /// `@capture` bound across every match, flat and in match-then-capture
    /// order. One FFI crossing: the whole result is materialized and frozen
    /// before returning, matching `AstGrep`'s frozen-hash style.
    ///
    /// A source of `HOLD_BELOW` bytes or more is queried with the GVL
    /// released, so a kill or a raise stops it early; the arguments' Rust copies live in the job and are gone by the
    /// time a refusal runs Ruby.
    pub fn query(ruby: &Ruby, src: Value, lang: Value, query_src: Value) -> Result<RArray, Error> {
        let release = RString::from_value(src).is_some_and(|text| HOLD_BELOW.releases(text.len()));
        let queried = without_gvl_when(ruby, release, || {
            let (src, lang, query_src) = (
                text_of(ruby, src, "source")?,
                text_of(ruby, lang, "language")?,
                text_of(ruby, query_src, "query")?,
            );
            let (src, lang, query_src) = (src.read(ruby)?, lang.read(ruby)?, query_src.read(ruby)?);
            Ok(move |cancel: &Cancel<'_>| query_until(&src, &lang, &query_src, cancel))
        })?;
        let captures = queried.map_err(|err| raised(ruby, err))?;
        let out = ruby.ary_new_capa(captures.len());
        for capture in captures {
            out.push(build_capture(ruby, capture)?)?;
        }
        out.freeze();
        Ok(out)
    }

    fn raised(ruby: &Ruby, err: QueryFailure) -> Error {
        match err {
            QueryFailure::BadQuery { .. } => lookup_error(
                ruby,
                &["Lain", "Ext", "TreeSitter", "BadQuery"],
                move || err.to_string(),
            ),
            QueryFailure::UnknownLanguage(_) => {
                Error::new(ruby.exception_arg_error(), err.to_string())
            }
            QueryFailure::Backend(_) => Error::new(ruby.exception_runtime_error(), err.to_string()),
        }
    }

    fn build_capture(ruby: &Ruby, capture: Capture) -> Result<Value, Error> {
        let hash = ruby.hash_new();
        hash.aset(frozen_str(ruby, "name"), frozen_str(ruby, &capture.name))?;
        hash.aset(frozen_str(ruby, "text"), frozen_str(ruby, &capture.text))?;
        hash.aset(frozen_str(ruby, "start"), int(ruby, capture.start))?;
        hash.aset(frozen_str(ruby, "end"), int(ruby, capture.end))?;
        hash.freeze();
        Ok(hash.as_value())
    }
}
