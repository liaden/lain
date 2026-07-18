//! Pure, libruby-free structural (AST) search over `ast-grep-core`.
//!
//! Every call is STATELESS: it parses an in-memory `&str`, matches a
//! metavariable pattern against the concrete syntax tree, and returns an owned
//! `Vec` of matches. There is no index handle to keep, so -- unlike `Bm25` --
//! this needs no `TypedData` wrapper and makes no `frozen_shareable` promise;
//! the FFI wrapper just freezes the Ruby Array it builds per call. `ast-grep-core`
//! matches the CST with ZERO filesystem access, which is exactly why the matcher
//! is legal in-process here (pure, synchronous, data-structure-shaped) while
//! recursive file-walking -- the I/O-shaped half -- would belong out of process.
//!
//! Nothing in this layer touches `magnus`, so parsing, capture extraction,
//! the comment/string structural-immunity, malformed-pattern rejection, and the
//! CST dump are all unit-tested in `cargo test` without an embedded Ruby VM.
//!
//! Byte offsets only. Byte -> line/column conversion is the Ruby wrapper's job;
//! we surface the node's own 0-based start line as a convenience but the pinned
//! contract is the byte range.

use ast_grep_core::meta_var::{MetaVarEnv, MetaVariable};
use ast_grep_core::{AstGrep, Doc, Language, Node, NodeMatch, Pattern};
use ast_grep_language::SupportLang;

/// A captured metavariable (`$NAME`) and where its node sits in the source.
#[derive(Debug, PartialEq, Eq)]
pub struct Capture {
    pub name: String,
    pub text: String,
    /// Byte offsets into the source of the captured node.
    pub start: usize,
    pub end: usize,
}

/// One structural match: the byte range of the whole matched node, its 0-based
/// start line, and every single-node capture the pattern bound.
#[derive(Debug, PartialEq, Eq)]
pub struct Match {
    pub start: usize,
    pub end: usize,
    pub line: usize,
    pub captures: Vec<Capture>,
}

/// Why a search could not run. `Display` IS the FFI-visible message: `BadPattern`
/// maps to the named `AstGrep::BadPattern` (a `Lain::Error`); an unknown language
/// is a plain argument error at the boundary.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum SearchError {
    #[error("unknown language {0:?}")]
    UnknownLanguage(String),
    /// The pattern does not parse to a single valid syntax node. `ast-grep-core`
    /// reports some malformed patterns as a hard `PatternError` and others as a
    /// tree with an embedded ERROR node (tree-sitter is error-tolerant), so both
    /// paths collapse here -- an LLM that fat-fingers a pattern gets a loud raise
    /// rather than a silent zero-match.
    #[error("malformed pattern {pattern:?}: {reason}")]
    BadPattern { pattern: String, reason: String },
}

/// Parse a language moniker (`"ruby"`, case-insensitive) into a `SupportLang`.
fn parse_lang(lang: &str) -> Result<SupportLang, SearchError> {
    lang.parse()
        .map_err(|_| SearchError::UnknownLanguage(lang.to_string()))
}

/// Build a matcher, rejecting a pattern that is a typo rather than a query.
///
/// Three checks, because tree-sitter is error-tolerant and `ast-grep-core`'s
/// `has_error()` only inspects the *extracted effective node*, not the whole
/// parse tree:
///
/// 1. `try_new` fails outright (a hard `PatternError`).
/// 2. The full parse tree carries an ERROR or MISSING node. `has_error()` alone
///    lets `")"`, `"def"`, `"class"` (top-level ERROR) and `"1 +"`, `"[1,"`
///    (MISSING-node recovery) through as a silent zero-match -- the worst
///    failure this tool can have.
///
/// But a broken tree is NOT sufficient on its own: a *valid, matching* metavar
/// pattern can still parse to a broken tree, because a metavar occupies a slot
/// the grammar wanted a concrete token in. In Ruby (no expando char) `class $N`
/// parses to an ERROR -- `$N` is a global variable where a Constant belongs --
/// yet ast-grep matches `class Foo` with it; `def $NAME($$$A)` parses with a
/// MISSING node yet is the canonical method pattern. So the broken-tree signal
/// only condemns a pattern that *also binds no metavariable* -- i.e. a purely
/// literal fragment that does not even parse, which is a typo, not a query.
fn build_pattern(pattern: &str, lang: SupportLang) -> Result<Pattern, SearchError> {
    let bad = |reason: String| SearchError::BadPattern {
        pattern: pattern.to_string(),
        reason,
    };
    let pat = Pattern::try_new(pattern, lang).map_err(|err| bad(err.to_string()))?;
    let processed = lang.pre_process_pattern(pattern);
    let broken = pat.has_error() || tree_is_broken(&AstGrep::new(processed.as_ref(), lang).root());
    if broken && !has_metavariable(pattern) {
        return Err(bad("does not parse to a valid syntax node".to_string()));
    }
    Ok(pat)
}

/// Whether `node` or any descendant is an ERROR or MISSING node -- the two ways
/// tree-sitter records "this did not parse cleanly", walked over the same
/// preprocessed source `Pattern::try_new` parsed.
fn tree_is_broken<D: Doc>(node: &Node<'_, D>) -> bool {
    node.is_error() || node.is_missing() || node.children().any(|child| tree_is_broken(&child))
}

/// Whether `pattern` binds at least one metavariable, by ast-grep's own rule
/// (see `ast-grep-language`'s `pre_process_pattern`): a `$` immediately followed
/// by an ASCII uppercase letter or `_` (covers `$A`, `$$A`, `$$$A`), or the
/// anonymous `$$$` ellipsis. A pattern with no metavariable is a literal
/// fragment; one with a metavariable is a structural query with a hole, which
/// ast-grep matches even when the surrounding tree does not parse cleanly.
fn has_metavariable(pattern: &str) -> bool {
    let named = pattern
        .as_bytes()
        .windows(2)
        .any(|pair| pair[0] == b'$' && (pair[1].is_ascii_uppercase() || pair[1] == b'_'));
    named || pattern.contains("$$$")
}

/// All structural matches of `pattern` in `src`, in source order. A valid
/// pattern with no matches yields an empty `Vec` (not an error).
pub fn search(src: &str, lang: &str, pattern: &str) -> Result<Vec<Match>, SearchError> {
    let lang = parse_lang(lang)?;
    let pat = build_pattern(pattern, lang)?;
    let ast = AstGrep::new(src, lang);
    let matches = ast
        .root()
        .find_all(&pat)
        .map(|matched| extract_match(&matched))
        .collect();
    Ok(matches)
}

/// Convert one borrowed `NodeMatch` into an owned [`Match`] before its backing
/// tree is dropped. Captures are sorted by name so two searches are identical.
fn extract_match<D: Doc>(matched: &NodeMatch<'_, D>) -> Match {
    let node = matched.get_node();
    let range = node.range();
    let env = matched.get_env();
    let mut captures: Vec<Capture> = env
        .get_matched_variables()
        .filter_map(|var| single_capture(env, var))
        .collect();
    captures.sort_by(|a, b| a.name.cmp(&b.name));
    Match {
        start: range.start,
        end: range.end,
        line: node.start_pos().line(),
        captures,
    }
}

/// A single-node capture (`$NAME`) as an owned [`Capture`]. Multi-captures
/// (`$$$A`) and dropped vars (`$_`) are structural glue, not named results, so
/// they are skipped -- the contract is named single-node captures.
fn single_capture<D: Doc>(env: &MetaVarEnv<'_, D>, var: MetaVariable) -> Option<Capture> {
    match var {
        MetaVariable::Capture(name, _) => env.get_match(&name).map(|node| {
            let range = node.range();
            Capture {
                name,
                text: node.text().into_owned(),
                start: range.start,
                end: range.end,
            }
        }),
        _ => None,
    }
}

/// A newline-delimited, indented dump of the CST node kinds. It exists so an
/// agent can SEE that `def self.x` is a `singleton_method` -- a different node
/// than the `method` its `def $NAME` pattern matches -- and self-correct rather
/// than trust a silent under-match.
pub fn dump(src: &str, lang: &str) -> Result<String, SearchError> {
    let lang = parse_lang(lang)?;
    let ast = AstGrep::new(src, lang);
    let mut out = String::new();
    write_node(&ast.root(), 0, &mut out);
    Ok(out)
}

fn write_node<D: Doc>(node: &Node<'_, D>, depth: usize, out: &mut String) {
    out.push_str(&"  ".repeat(depth));
    out.push_str(&node.kind());
    out.push('\n');
    node.children()
        .for_each(|child| write_node(&child, depth + 1, out));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_a_named_metavariable_with_a_byte_range() {
        let matches = search("def total(x)\n  x\nend", "ruby", "def $NAME($$$A)").unwrap();
        assert_eq!(matches.len(), 1);

        let matched = &matches[0];
        assert!(matched.start < matched.end);

        let name = matched
            .captures
            .iter()
            .find(|c| c.name == "NAME")
            .expect("a NAME capture");
        assert_eq!(name.text, "total");
        assert!(name.start < name.end);
        // The capture's bytes address `total` in the source.
        assert_eq!(&"def total(x)\n  x\nend"[name.start..name.end], "total");
    }

    #[test]
    fn structural_match_ignores_comments_and_strings() {
        let src = "# remember to record.save the row\nnote = \"call record.save when ready\"\nrecord.save\n";
        let matches = search(src, "ruby", "$RECV.save").unwrap();
        assert_eq!(matches.len(), 1);
        let recv = matches[0]
            .captures
            .iter()
            .find(|c| c.name == "RECV")
            .expect("a RECV capture");
        assert_eq!(recv.text, "record");
    }

    #[test]
    fn malformed_pattern_is_a_bad_pattern_error() {
        assert!(matches!(
            search("x = 1", "ruby", "def ("),
            Err(SearchError::BadPattern { .. })
        ));
    }

    // The T2 catalog forms plus our own test patterns. Every one is a real,
    // matching structural query -- several (`class $N`, `class $C < $SUPER`)
    // parse to a tree with an ERROR node in Ruby because `$N` is a global var
    // where a Constant is expected, yet ast-grep matches with them. They MUST
    // stay accepted: the malformed-pattern guard rejects only broken patterns
    // that bind NO metavariable, so a metavariable pattern is never over-rejected.
    const KNOWN_GOOD_PATTERNS: &[&str] = &[
        "def $NAME($$$A)",
        "def self.$NAME($$$A)",
        "class $N",
        "module $N",
        "class $C < $SUPER",
        "include $M",
        "extend $M",
        "@$VAR",
        "$RECV.$NAME",
        "$NAME",
        "$RECV.save",
    ];

    #[test]
    fn known_good_patterns_are_never_rejected() {
        KNOWN_GOOD_PATTERNS.iter().for_each(|pattern| {
            assert!(
                !matches!(
                    search("record.save\n", "ruby", pattern),
                    Err(SearchError::BadPattern { .. })
                ),
                "known-good pattern {pattern:?} was wrongly rejected as BadPattern",
            );
        });
    }

    #[test]
    fn top_level_error_node_patterns_raise_not_silent_empty() {
        // `has_error()` alone misses these -- they parse to a top-level ERROR
        // node the extracted-pattern-node summary does not see. A silent `[]`
        // for a fat-fingered pattern is the worst failure this tool can have.
        [")", "def", "class"].iter().for_each(|pattern| {
            assert!(
                matches!(
                    search("record.save", "ruby", pattern),
                    Err(SearchError::BadPattern { .. })
                ),
                "pattern {pattern:?} must be BadPattern, not a silent []",
            );
        });
    }

    #[test]
    fn missing_node_recovery_patterns_raise_not_silent_empty() {
        // tree-sitter recovers from these by inserting a MISSING node, so they
        // carry no ERROR kind; the MISSING walk catches them. The metavariable
        // guard is what keeps this from also rejecting `def $NAME($$$A)`, whose
        // valid parse likewise carries a MISSING node.
        ["1 +", "[1,", "{a:"].iter().for_each(|pattern| {
            assert!(
                matches!(
                    search("x = 1", "ruby", pattern),
                    Err(SearchError::BadPattern { .. })
                ),
                "pattern {pattern:?} must be BadPattern, not a silent []",
            );
        });
    }

    #[test]
    fn valid_pattern_with_no_matches_is_empty_not_an_error() {
        assert_eq!(search("x = 1", "ruby", "$RECV.save").unwrap(), vec![]);
    }

    #[test]
    fn unknown_language_is_an_error() {
        assert!(matches!(
            search("x = 1", "klingon", "$A"),
            Err(SearchError::UnknownLanguage(lang)) if lang == "klingon"
        ));
    }

    #[test]
    fn dump_reveals_the_singleton_method_node() {
        let dumped = dump("def self.x; end", "ruby").unwrap();
        assert!(dumped.contains("singleton_method"), "dump was:\n{dumped}");
    }

    #[test]
    fn has_metavariable_distinguishes_queries_from_literals() {
        [
            "$A",
            "$$A",
            "$$$A",
            "$NAME",
            "@$VAR",
            "class $N",
            "$$$",
            "def $F(); end",
        ]
        .iter()
        .for_each(|pattern| assert!(has_metavariable(pattern), "{pattern:?} binds a metavar"));
        [
            ")",
            "def",
            "class",
            "def (",
            "record.save",
            "1 +",
            "[1,",
            "$lower",
        ]
        .iter()
        .for_each(|pattern| assert!(!has_metavariable(pattern), "{pattern:?} binds none"));
    }

    #[test]
    fn two_searches_are_identical() {
        let a = search("def total(x)\n  x\nend", "ruby", "def $NAME($$$A)").unwrap();
        let b = search("def total(x)\n  x\nend", "ruby", "def $NAME($$$A)").unwrap();
        assert_eq!(a, b);
    }
}
#[cfg(not(test))]
pub mod ffi {
    use super::{Capture, Match, SearchError, dump as pure_dump, search as pure_search};
    use crate::ffi::{frozen_str, int, lookup_error};
    use magnus::{Error, RArray, RString, Ruby, Value, prelude::*};

    /// `Lain::Ext::AstGrep.search(src, lang, pattern)` -> a frozen Array of
    /// frozen match Hashes `{ "start", "end", "line", "captures" }`, where
    /// `captures` maps each `$NAME` to `{ "text", "start", "end" }`. One FFI
    /// crossing: the whole result is materialized and frozen before returning.
    pub fn search(
        ruby: &Ruby,
        src: String,
        lang: String,
        pattern: String,
    ) -> Result<RArray, Error> {
        let matches = match pure_search(&src, &lang, &pattern) {
            Ok(matches) => matches,
            Err(err @ SearchError::BadPattern { .. }) => {
                return Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "AstGrep", "BadPattern"],
                    err.to_string(),
                ));
            }
            Err(err @ SearchError::UnknownLanguage(_)) => {
                return Err(Error::new(ruby.exception_arg_error(), err.to_string()));
            }
        };
        let out = ruby.ary_new_capa(matches.len());
        for matched in matches {
            out.push(build_match(ruby, matched)?)?;
        }
        out.freeze();
        Ok(out)
    }

    fn build_match(ruby: &Ruby, matched: Match) -> Result<Value, Error> {
        let hash = ruby.hash_new();
        hash.aset(frozen_str(ruby, "start"), int(ruby, matched.start))?;
        hash.aset(frozen_str(ruby, "end"), int(ruby, matched.end))?;
        hash.aset(frozen_str(ruby, "line"), int(ruby, matched.line))?;
        let captures = ruby.hash_new();
        for capture in matched.captures {
            captures.aset(
                frozen_str(ruby, &capture.name),
                build_capture(ruby, capture)?,
            )?;
        }
        captures.freeze();
        hash.aset(frozen_str(ruby, "captures"), captures.as_value())?;
        hash.freeze();
        Ok(hash.as_value())
    }

    fn build_capture(ruby: &Ruby, capture: Capture) -> Result<Value, Error> {
        let hash = ruby.hash_new();
        hash.aset(frozen_str(ruby, "text"), frozen_str(ruby, &capture.text))?;
        hash.aset(frozen_str(ruby, "start"), int(ruby, capture.start))?;
        hash.aset(frozen_str(ruby, "end"), int(ruby, capture.end))?;
        hash.freeze();
        Ok(hash.as_value())
    }

    /// `Lain::Ext::AstGrep.dump(src, lang)` -> a frozen String of the CST node
    /// kinds, the companion capability that lets an agent inspect the tree and
    /// fix a pattern that silently under-matched.
    pub fn dump(ruby: &Ruby, src: String, lang: String) -> Result<RString, Error> {
        match pure_dump(&src, &lang) {
            Ok(text) => {
                let string = ruby.str_new(&text);
                string.freeze();
                Ok(string)
            }
            Err(err) => Err(Error::new(ruby.exception_arg_error(), err.to_string())),
        }
    }
}
