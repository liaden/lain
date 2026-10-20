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
//! The one thing kept between calls is a per-thread `QueryCache` of compiled
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

use ast_grep_language::{LanguageExt, SupportLang};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use tree_sitter::{Parser, Query, QueryCursor, StreamingIterator};

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

/// All captures bound by running `query_src` against `src`, in match-then-capture
/// order. A valid query with no matches yields an empty `Vec` (not an error).
///
/// Built-in text predicates (`#eq?`, `#match?`) DO filter. But tree-sitter
/// treats an unknown/misspelled general predicate (`#nonsense?`, `#eqq?`) as
/// inert -- it compiles fine and is silently ignored, so a typo'd predicate
/// yields UNFILTERED results with no error. That is inherent to tree-sitter's
/// design (the host is expected to interpret general predicates) and this is the
/// explicitly "raw" surface, so it is not enforced here.
pub fn query(src: &str, lang: &str, query_src: &str) -> Result<Vec<Capture>, QueryFailure> {
    let lang = parse_lang(lang)?;
    let query = compiled(lang, query_src)?;
    run(&query, src, lang)
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

/// Compiled queries by language, then by query source.
///
/// `Query::new` resolves every name against the whole grammar, so it costs
/// milliseconds even for a one-node query, while running it on a short command
/// costs microseconds; `Shell::Parse` compiles the same constant query for every
/// command it classifies. A compiled `Query` carries no per-run state (that is
/// the `QueryCursor`, which stays per call), so a reused one answers exactly as
/// a fresh one does -- `a_cached_query_agrees_with_a_fresh_one` is the proof.
///
/// Keyed by language first so a hit is looked up by `&str` without allocating
/// the key. Only successes are stored, so a malformed query keeps raising and
/// cannot take a slot. A full cache stops admitting: every later query is
/// compiled on each call and stays uncached on that thread. The cap bounds
/// memory, not cost; a caller building queries from input still pays a
/// compile per call once the slots are gone.
struct QueryCache {
    compiled: HashMap<SupportLang, HashMap<String, Rc<Query>>>,
    len: usize,
    cap: usize,
}

impl QueryCache {
    fn new(cap: usize) -> Self {
        Self {
            compiled: HashMap::new(),
            len: 0,
            cap,
        }
    }

    fn get_or_compile(
        &mut self,
        lang: SupportLang,
        query_src: &str,
    ) -> Result<Rc<Query>, QueryFailure> {
        if let Some(hit) = self
            .compiled
            .get(&lang)
            .and_then(|by_src| by_src.get(query_src))
        {
            return Ok(Rc::clone(hit));
        }
        let query = Rc::new(compile(lang, query_src)?);
        // Admit until full, then never evict: the first queries a thread sees keep their slots.
        if self.len < self.cap {
            self.compiled
                .entry(lang)
                .or_default()
                .insert(query_src.to_string(), Rc::clone(&query));
            self.len += 1;
        }
        Ok(query)
    }
}

thread_local! {
    /// Per thread, so the cache needs no lock and holds `Rc` rather than `Arc`.
    /// What makes it safe under Ruby is the GVL plus `try_borrow_mut`, the same
    /// argument `fuzzy.rs`'s `MATCHER` makes. 64 is far above the handful of
    /// constant queries `lib/` passes.
    static QUERIES: RefCell<QueryCache> = RefCell::new(QueryCache::new(64));
}

/// The thread's cached compile of `query_src`, falling back to an uncached
/// compile if the thread-local is unreachable (during TLS teardown) or already
/// borrowed (re-entrancy). Neither is reachable from a Ruby method call, but
/// both are *panics* on the ergonomic API, and a panic here is undefined
/// behaviour.
fn compiled(lang: SupportLang, query_src: &str) -> Result<Rc<Query>, QueryFailure> {
    QUERIES
        .try_with(|cell| {
            cell.try_borrow_mut()
                .ok()
                .map(|mut cache| cache.get_or_compile(lang, query_src))
        })
        .ok()
        .flatten()
        .unwrap_or_else(|| compile(lang, query_src).map(Rc::new))
}

/// Every capture `compiled` binds in `src`, in match-then-capture order.
fn run(compiled: &Query, src: &str, lang: SupportLang) -> Result<Vec<Capture>, QueryFailure> {
    let ts_lang = lang.get_ts_language();
    let mut parser = Parser::new();
    parser
        .set_language(&ts_lang)
        .map_err(|err| QueryFailure::Backend(err.to_string()))?;
    let tree = parser
        .parse(src, None)
        .ok_or_else(|| QueryFailure::Backend(format!("parser produced no tree for {lang}")))?;

    let names = compiled.capture_names();
    let src_bytes = src.as_bytes();
    let mut cursor = QueryCursor::new();
    // tree-sitter 0.25+ hands back a StreamingIterator, not a std Iterator, so
    // this is a `while let Some(..) = it.next()` drive rather than a `for`/`map`
    // -- the borrow of the reused row buffer is what forbids a plain Iterator.
    let mut matches = cursor.matches(compiled, tree.root_node(), src_bytes);
    let mut out = Vec::new();
    while let Some(matched) = matches.next() {
        matched.captures().iter().for_each(|capture| {
            let node = capture.node;
            let range = node.byte_range();
            out.push(Capture {
                name: names[capture.index as usize].to_string(),
                // A captured node always lies on a char boundary of its own
                // `&str` source, so `utf8_text` cannot fail -- but if that
                // invariant ever broke it must fail LOUD (magnus turns the panic
                // into a Ruby exception), not silently return an empty capture,
                // per the crate's no-silent-corner rule.
                text: node
                    .utf8_text(src_bytes)
                    .expect("captured node lies on a char boundary of its own source")
                    .to_string(),
                start: range.start,
                end: range.end,
            });
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn a_second_compile_of_the_same_query_is_the_same_object() {
        let mut cache = QueryCache::new(64);
        let first = cache
            .get_or_compile(SupportLang::Ruby, "(method) @m")
            .unwrap();
        let second = cache
            .get_or_compile(SupportLang::Ruby, "(method) @m")
            .unwrap();
        assert!(Rc::ptr_eq(&first, &second));
    }

    #[test]
    fn the_same_source_in_another_language_is_a_separate_entry() {
        let mut cache = QueryCache::new(64);
        let ruby = cache
            .get_or_compile(SupportLang::Ruby, "(identifier) @i")
            .unwrap();
        let rust = cache
            .get_or_compile(SupportLang::Rust, "(identifier) @i")
            .unwrap();
        assert!(!Rc::ptr_eq(&ruby, &rust));
    }

    #[test]
    fn failures_are_not_stored_and_the_cap_holds() {
        let mut cache = QueryCache::new(64);
        assert!(matches!(
            cache.get_or_compile(SupportLang::Ruby, "(method name: @nope"),
            Err(QueryFailure::BadQuery { .. })
        ));
        assert!(matches!(
            cache.get_or_compile(SupportLang::Ruby, "(method)"),
            Err(QueryFailure::BadQuery { .. })
        ));

        let sources: Vec<String> = (0..65).map(|n| format!("(identifier) @c{n}")).collect();
        let firsts: Vec<Rc<Query>> = sources
            .iter()
            .map(|src| cache.get_or_compile(SupportLang::Ruby, src).unwrap())
            .collect();
        let kept: Vec<bool> = sources
            .iter()
            .zip(&firsts)
            .map(|(src, first)| {
                Rc::ptr_eq(
                    first,
                    &cache.get_or_compile(SupportLang::Ruby, src).unwrap(),
                )
            })
            .collect();

        assert!(
            kept[..64].iter().all(|&hit| hit),
            "the 2 failures took no slot"
        );
        assert!(!kept[64], "the 65th query is compiled but not kept");
    }

    #[test]
    fn a_cached_query_agrees_with_a_fresh_one() {
        let src = "a.save\nb.save\ndef total(x)\n  x\nend\n";
        let query_src = "(call receiver: (identifier) @recv) (method name: (identifier) @name)";
        let mut cache = QueryCache::new(64);
        let cached = cache.get_or_compile(SupportLang::Ruby, query_src).unwrap();
        let fresh = compile(SupportLang::Ruby, query_src).unwrap();
        let first = run(&cached, src, SupportLang::Ruby).unwrap();
        let reused = run(&cached, src, SupportLang::Ruby).unwrap();
        let expected = run(&fresh, src, SupportLang::Ruby).unwrap();
        assert_eq!(first, expected);
        assert_eq!(reused, expected);
        assert_eq!(expected.len(), 3, "2 receivers and 1 method name");
    }
}

#[cfg(not(test))]
pub mod ffi {
    use super::{Capture, QueryFailure, query as pure_query};
    use crate::ffi::{frozen_str, int, lookup_error};
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
    use magnus::{Error, RArray, Ruby, Value, prelude::*};

    /// `Lain::Ext::TreeSitter.query(src, lang, query)` -> a frozen Array of
    /// frozen capture Hashes `{ "name", "text", "start", "end" }`, one per
    /// `@capture` bound across every match, flat and in match-then-capture
    /// order. One FFI crossing: the whole result is materialized and frozen
    /// before returning, matching `AstGrep`'s frozen-hash style.
    pub fn query(ruby: &Ruby, src: Value, lang: Value, query_src: Value) -> Result<RArray, Error> {
        let (src, lang, query_src) = (
            text_of(ruby, src, "source")?,
            text_of(ruby, lang, "language")?,
            text_of(ruby, query_src, "query")?,
        );
        let (src, lang, query_src) = (src.read(ruby)?, lang.read(ruby)?, query_src.read(ruby)?);
        let queried = pure_query(&src, &lang, &query_src);
        // A refusal can run Ruby, so the arguments' Rust copies go first.
        drop((src, lang, query_src));
        let captures = match queried {
            Ok(captures) => captures,
            Err(err @ QueryFailure::BadQuery { .. }) => {
                return Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "TreeSitter", "BadQuery"],
                    move || err.to_string(),
                ));
            }
            Err(err @ QueryFailure::UnknownLanguage(_)) => {
                return Err(Error::new(ruby.exception_arg_error(), err.to_string()));
            }
            Err(err @ QueryFailure::Backend(_)) => {
                return Err(Error::new(ruby.exception_runtime_error(), err.to_string()));
            }
        };
        let out = ruby.ary_new_capa(captures.len());
        for capture in captures {
            out.push(build_capture(ruby, capture)?)?;
        }
        out.freeze();
        Ok(out)
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
