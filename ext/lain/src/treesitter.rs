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
//! the grammars ast-grep already links (both resolve `tree-sitter 0.26.11`).
//!
//! Every call is STATELESS: parse an in-memory `&str`, run one compiled query,
//! return an owned `Vec<Capture>` in match-then-capture order. There is no index
//! handle to keep, so -- unlike `Bm25` -- this needs no `TypedData` wrapper and
//! makes no `frozen_shareable` promise; the FFI wrapper just freezes the Ruby
//! Array it builds per call.
//!
//! Nothing in this layer touches `magnus`, so language parsing, capture
//! extraction, and malformed-query rejection are all unit-tested in `cargo test`
//! without an embedded Ruby VM.
//!
//! Byte offsets only. Byte -> line/column conversion is the Ruby wrapper's job.

use ast_grep_language::{LanguageExt, SupportLang};
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
    let ts_lang = lang.get_ts_language();

    let compiled = Query::new(&ts_lang, query_src).map_err(|err| QueryFailure::BadQuery {
        query: query_src.to_string(),
        reason: err.to_string(),
    })?;

    // A query that binds no `@capture` can never emit output for ANY source --
    // an empty/whitespace/comment-only query (zero patterns) or a structural
    // query with no `@` (e.g. `(method)`). That is a fat-fingered query, not a
    // no-match, so it raises rather than returning a silent `[]` -- the same
    // worst-failure class T1's astgrep guard fights. Safe against over-rejection
    // BECAUSE a real query the caller wants results from MUST bind >=1 capture;
    // `(method) @m` on non-matching source keeps returning `[]` (a genuine
    // no-match), since it binds one capture and merely finds nothing here.
    if compiled.capture_names().is_empty() {
        return Err(QueryFailure::BadQuery {
            query: query_src.to_string(),
            reason: "query binds no @capture, so it can never yield a result".to_string(),
        });
    }

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
    let mut matches = cursor.matches(&compiled, tree.root_node(), src_bytes);
    let mut out = Vec::new();
    while let Some(matched) = matches.next() {
        matched.captures.iter().for_each(|capture| {
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
        // failure T1's astgrep guard fights. Covers empty/whitespace/comment-only
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
}

#[cfg(not(test))]
pub mod ffi {
    use super::{Capture, QueryFailure, query as pure_query};
    use crate::ffi::{frozen_str, int, lookup_error};
    use magnus::{Error, RArray, Ruby, Value, prelude::*};

    /// `Lain::Ext::TreeSitter.query(src, lang, query)` -> a frozen Array of
    /// frozen capture Hashes `{ "name", "text", "start", "end" }`, one per
    /// `@capture` bound across every match, flat and in match-then-capture
    /// order. One FFI crossing: the whole result is materialized and frozen
    /// before returning, matching `AstGrep`'s frozen-hash style.
    pub fn query(
        ruby: &Ruby,
        src: String,
        lang: String,
        query_src: String,
    ) -> Result<RArray, Error> {
        let captures = match pure_query(&src, &lang, &query_src) {
            Ok(captures) => captures,
            Err(err @ QueryFailure::BadQuery { .. }) => {
                return Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "TreeSitter", "BadQuery"],
                    err.to_string(),
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
