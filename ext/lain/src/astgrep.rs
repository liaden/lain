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

/// Why a search or a dump could not run. `Display` IS the FFI-visible message:
/// `BadPattern` maps to the named `AstGrep::BadPattern`, and `DumpTooDeep` to
/// `Lain::Structural::Matcher::DumpCapped` -- both `Lain::Error` subclasses,
/// which is the crate's rule for every raise that is a DOMAIN refusal rather
/// than a bad argument, since a class outside that tree is one no
/// `rescue Lain::Error` site catches. An unknown language stays a plain
/// `ArgumentError`, because it IS a bad argument.
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
    /// [`dump`] refused: the CST nests past [`MAX_DUMP_DEPTH`]. Only [`dump`]
    /// returns this; [`search`]'s result is bounded by the match count, not by
    /// the tree's shape. It is the ONE dump bound that refuses -- running out of
    /// [`MAX_DUMP_BYTES`] truncates and discloses instead -- because depth is a
    /// stack-safety bound and there is no safe prefix to hand back.
    #[error("dump capped at {0} levels of nesting -- dump a smaller snippet")]
    DumpTooDeep(usize),
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

/// The most levels of CST nesting a dump will walk. Past it the dump is
/// REFUSED, which is what makes this bound different in kind from
/// [`MAX_DUMP_BYTES`].
///
/// This is a **stack safety** bound, not an output-size one -- exactly as
/// `prompt.rs`'s `MAX_DEPTH` is. [`write_node`] recurses once per level, and one
/// level costs about seven Rust frames (~1 KB of stack), so at the cap the walk
/// is bounded to roughly 700 frames. Unbounded it overflows: measured, a
/// 2000-level source aborts a debug `cargo test` thread outright ("has
/// overflowed its stack", SIGABRT), which the ~1 KB/level figure corroborates --
/// 2000 levels is 2-4 MB, the order of a test thread's whole stack. Under Ruby
/// that is worse than a crash: Ruby's guard-page handler longjmps through live
/// Rust frames, so no destructor runs and the `String` being built leaks.
///
/// There is no safe prefix to hand back from a walk that would blow the stack,
/// which is why this one refuses where the byte budget truncates.
///
/// 100 is threefold past real code (measured: the deepest CST branch across all
/// 877 Ruby files in this repository is 31), and low enough to fire BEFORE the
/// byte budget on a deeply nested source -- a chain 100 deep dumps to some
/// 25 KB, so a stack bound set where truncation would hit first would never
/// fire, and a stack bound that never fires guards nothing.
pub const MAX_DUMP_DEPTH: usize = 100;

/// How many bytes of dump text are built before the walk stops and discloses
/// the truncation. NOT a refusal: the caller gets the tree's outer structure
/// plus a `... capped at N bytes` line, the same truncate-and-disclose contract
/// `Tools::AstSearch`'s `MAX_MATCHES` has.
///
/// Truncating rather than refusing is deliberate and was got wrong once. Depth
/// alone does not bound the output -- the indent is written once per node at its
/// own depth, so the text is quadratic in depth and linear in node count, and a
/// 4 KB source of 2000 nested parens dumped to 12 MB. But refusing everything
/// past the budget took out ordinary files with it: 145 of this repo's 879 Ruby
/// files dump past 64 KiB, the smallest being a 7 KB spec, and the
/// dump-to-source ratio ranges from 3.5x to 11.8x, so a model cannot even tell
/// from a file's size whether it will fit. "Dump a smaller snippet" was a dead
/// end; the outer structure of the tree is the half that answers "what node
/// kind is this?" anyway.
///
/// 64 KiB is already ~16k tokens of node kinds, which is as much of a diagnostic
/// as a model's context should have to carry.
pub const MAX_DUMP_BYTES: usize = 64 * 1024;

/// One level of dump indentation. Written from a single reused buffer (see
/// [`write_node`]), never re-`repeat`ed per node.
const INDENT: &str = "  ";

/// A newline-delimited, indented dump of the CST node kinds. It exists so an
/// agent can SEE that `def self.x` is a `singleton_method` -- a different node
/// than the `method` its `def $NAME` pattern matches -- and self-correct rather
/// than trust a silent under-match.
///
/// Bounded at both ends, and the two bounds answer differently:
/// [`MAX_DUMP_BYTES`] TRUNCATES, appending the `... capped at N bytes`
/// disclosure that `Tools::AstSearch` also writes, while [`MAX_DUMP_DEPTH`]
/// REFUSES, because it is a stack bound with no safe prefix to return. Either
/// way, never a multi-megabyte `String` and never a blown stack.
pub fn dump(src: &str, lang: &str) -> Result<String, SearchError> {
    let lang = parse_lang(lang)?;
    let ast = AstGrep::new(src, lang);
    let mut out = String::new();
    let mut indent = String::new();
    match write_node(&ast.root(), &mut indent, &mut out) {
        Ok(()) => Ok(out),
        Err(Halt::Truncated) => {
            out.push_str(&format!("... capped at {MAX_DUMP_BYTES} bytes\n"));
            Ok(out)
        }
        Err(Halt::TooDeep) => Err(SearchError::DumpTooDeep(MAX_DUMP_DEPTH)),
    }
}

/// Why a CST walk stopped early. Internal control flow, not an error type: it
/// is what lets one `try_for_each` unwind the recursion for both bounds, and
/// [`dump`] decides which of the two becomes a refusal and which a disclosure.
#[derive(Debug)]
enum Halt {
    /// [`MAX_DUMP_DEPTH`] reached -- the stack bound.
    TooDeep,
    /// [`MAX_DUMP_BYTES`] spent -- what is written so far is the answer.
    Truncated,
}

/// Append `node`'s kind and every descendant's, one line each, indented by
/// depth -- bounded at both ends, and allocation-free per node.
///
/// `indent` is ONE buffer threaded through the whole walk: it grows by
/// [`INDENT`] on descent and truncates on ascent, including on the halt path,
/// so its length IS the current depth and no node builds a `" ".repeat(depth)`
/// of its own. Both bounds are checked BEFORE the node is written, so the text
/// never exceeds [`MAX_DUMP_BYTES`] (the disclosure line [`dump`] appends
/// afterwards is the one thing past it) and the recursion never goes deeper
/// than [`MAX_DUMP_DEPTH`] levels.
///
/// The root is level 1, so the buffer already holds `MAX_DUMP_DEPTH - 1`
/// indents when the deepest permitted node is written -- hence `>=` rather than
/// `>`, which admitted 101 levels while the refusal message promised 100.
fn write_node<D: Doc>(
    node: &Node<'_, D>,
    indent: &mut String,
    out: &mut String,
) -> Result<(), Halt> {
    if indent.len() >= MAX_DUMP_DEPTH * INDENT.len() {
        return Err(Halt::TooDeep);
    }
    let kind = node.kind();
    if out.len() + indent.len() + kind.len() + 1 > MAX_DUMP_BYTES {
        return Err(Halt::Truncated);
    }
    out.push_str(indent);
    out.push_str(&kind);
    out.push('\n');
    indent.push_str(INDENT);
    let walked = node
        .children()
        .try_for_each(|child| write_node(&child, indent, out));
    indent.truncate(indent.len() - INDENT.len());
    walked
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

    /// A source nested past [`MAX_DUMP_DEPTH`]. 4 KB of it dumped to 12 MB
    /// before the bound existed -- the indent alone is quadratic in depth.
    fn deeply_nested() -> String {
        format!("{}1{}", "(".repeat(2000), ")".repeat(2000))
    }

    #[test]
    fn a_dump_past_the_depth_cap_is_an_error_not_a_multi_megabyte_string() {
        assert!(matches!(
            dump(&deeply_nested(), "ruby"),
            Err(SearchError::DumpTooDeep(MAX_DUMP_DEPTH))
        ));
    }

    /// A source `levels` parens deep, and the deepest indent its dump reaches.
    fn nested(levels: usize) -> String {
        format!("{}1{}", "(".repeat(levels), ")".repeat(levels))
    }

    fn deepest_level(dumped: &str) -> usize {
        dumped
            .lines()
            .map(|line| (line.len() - line.trim_start().len()) / INDENT.len() + 1)
            .max()
            .unwrap_or(0)
    }

    #[test]
    fn the_deepest_accepted_dump_holds_exactly_max_dump_depth_levels() {
        // The cap's NUMBER is what the refusal message promises, so the boundary
        // has to be the number itself and not one either side of it. Found by
        // walking nesting upward rather than by hard-coding the parens-to-levels
        // ratio of one grammar.
        let deepest = (1..)
            .map(nested)
            .take_while(|src| dump(src, "ruby").is_ok())
            .last()
            .expect("some nesting is shallow enough to dump");

        assert_eq!(
            deepest_level(&dump(&deepest, "ruby").unwrap()),
            MAX_DUMP_DEPTH
        );
    }

    #[test]
    fn a_dump_past_the_output_cap_is_truncated_and_says_so() {
        // Shallow and wide: no branch is deep, so only the output budget bounds
        // it -- and that budget TRUNCATES and discloses, mirroring
        // `ast_search`'s "... capped at N matches" rather than refusing. The
        // model keeps the tree's outer structure, which is the half that answers
        // "what node kind is this?".
        let dumped = dump(&"x = 1\n".repeat(20_000), "ruby").unwrap();

        assert!(
            dumped.starts_with("program\n"),
            "dump began {:?}",
            &dumped[..40.min(dumped.len())]
        );
        assert!(dumped.ends_with(&format!("... capped at {MAX_DUMP_BYTES} bytes\n")));
        assert!(
            dumped.len() <= MAX_DUMP_BYTES + DISCLOSURE_HEADROOM,
            "dump was {} bytes",
            dumped.len()
        );
    }

    /// The disclosure line is appended AFTER the budget is spent, so a truncated
    /// dump may exceed [`MAX_DUMP_BYTES`] by exactly that line.
    const DISCLOSURE_HEADROOM: usize = 64;

    #[test]
    fn a_capped_dump_names_its_cap() {
        // The refusal message reaches the model verbatim through `ast_dump`'s
        // error Result, and the disclosure line through its ok one -- so the
        // number has to be IN both, mirroring `ast_search`'s "capped at N".
        let refusal = dump(&deeply_nested(), "ruby").unwrap_err().to_string();
        let truncated = dump(&"x = 1\n".repeat(20_000), "ruby").unwrap();

        assert!(refusal.starts_with("dump capped at "), "was {refusal:?}");
        assert!(truncated.contains("... capped at "), "no disclosure line");
    }

    #[test]
    fn the_walk_threads_one_indent_buffer_and_unwinds_it() {
        // The indent is written from a single buffer that grows on descent and
        // truncates on ascent -- never a fresh `" ".repeat(depth)` per node.
        // Empty at the end is the mechanical statement of that discipline, and
        // reusing the buffer for a second walk agrees with a fresh one.
        let ast = AstGrep::new("def self.x; end", SupportLang::Ruby);
        let mut indent = String::new();
        let mut first = String::new();
        write_node(&ast.root(), &mut indent, &mut first).unwrap();

        assert!(indent.is_empty(), "indent was {indent:?}");

        let mut second = String::new();
        write_node(&ast.root(), &mut indent, &mut second).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn a_capped_walk_still_unwinds_its_indent_buffer() {
        let ast = AstGrep::new(deeply_nested(), SupportLang::Ruby);
        let mut indent = String::new();
        let mut out = String::new();

        assert!(write_node(&ast.root(), &mut indent, &mut out).is_err());
        assert!(indent.is_empty(), "indent was {} bytes", indent.len());
    }

    #[test]
    fn dump_indents_two_spaces_per_level_of_nesting() {
        let dumped = dump("def self.x; end", "ruby").unwrap();
        let indents: Vec<usize> = dumped
            .lines()
            .map(|line| line.len() - line.trim_start().len())
            .collect();

        assert_eq!(indents[0], 0, "the root sits flush left");
        // Without this, a walk that never indented at all would pass.
        assert!(
            indents.iter().any(|width| *width == INDENT.len()),
            "no node sat one level in: {indents:?}",
        );
        assert!(
            indents.iter().all(|width| width % 2 == 0),
            "indents were {indents:?}",
        );
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
        let matches = pure_search(&src, &lang, &pattern).map_err(|err| raised(ruby, err))?;
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
        let text = pure_dump(&src, &lang).map_err(|err| raised(ruby, err))?;
        let string = ruby.str_new(&text);
        string.freeze();
        Ok(string)
    }

    /// The one place a [`SearchError`] becomes a Ruby exception, shared by both
    /// entry points so the class a given failure raises cannot drift between
    /// them. `Display` supplies every message (see [`SearchError`]).
    ///
    /// A bad pattern is the named `Lain::Ext::AstGrep::BadPattern`; an unknown
    /// language is a plain `ArgumentError`, because it is a bad argument rather
    /// than a domain refusal; and the depth cap is
    /// `Lain::Structural::Matcher::DumpCapped`.
    ///
    /// **Why the depth refusal names a Ruby-side class rather than a Ruby
    /// BUILTIN.** It first crossed as a `RangeError`, which was wrong twice
    /// over: it is not a `Lain::Error`, so no `rescue Lain::Error` site catches
    /// it, and a builtin cannot be told apart from an unrelated `RangeError`
    /// out of the same call -- `rescue RangeError` in the seam laundered
    /// "bignum too big to convert into 'long'" into a cap message naming no cap.
    /// Naming the wrapper's own class is the same shape `canonical.rs` uses for
    /// `Lain::Canonical::AmbiguousKey`: the vocabulary belongs to the Ruby unit
    /// this code implements, and looking it up at raise time keeps the ext free
    /// of any load-order dependency on it.
    fn raised(ruby: &Ruby, err: SearchError) -> Error {
        let message = err.to_string();
        match err {
            SearchError::BadPattern { .. } => {
                lookup_error(ruby, &["Lain", "Ext", "AstGrep", "BadPattern"], message)
            }
            SearchError::UnknownLanguage(_) => Error::new(ruby.exception_arg_error(), message),
            SearchError::DumpTooDeep(_) => lookup_error(
                ruby,
                &["Lain", "Structural", "Matcher", "DumpCapped"],
                message,
            ),
        }
    }
}
