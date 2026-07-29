//! Fuzzy matching for completion, over `nucleo-matcher`.
//!
//! A candidate set is built once and matched many times: that asymmetry is the
//! whole shape of the problem. Candidates change when the workspace does; the
//! query changes on every keystroke. So [`Candidates`] owns the batch and
//! [`Candidates::rank`] is the hot call, and the FFI boundary is crossed exactly
//! twice -- once to hand over the batch, once per query to hand back the whole
//! ranked result.
//!
//! `nucleo-matcher` is here rather than `skim` because Ruby owns the terminal.
//! `skim`'s *library* crate installs a `#[global_allocator]` and hard-depends on
//! `crossterm`, `tokio` and `ratatui`; it is a picker. This crate is
//! upstream-documented as "purely functional with no I/O or threading", and its
//! whole dependency set is `memchr` + `unicode-segmentation`. We want the
//! matcher, not the UI.
//!
//! No `magnus` type appears in any signature outside [`ffi`], so everything in
//! this file above that module is reachable from `cargo test` without an
//! embedded Ruby VM.
//!
//! ## Why nothing here can panic into Ruby
//!
//! A Rust panic unwinding across the FFI boundary is undefined behaviour, so
//! every panicking path `nucleo` documents is closed *by construction* rather
//! than by hoping:
//!
//! * `Matcher::fuzzy_match` asserts the haystack is at most `u32::MAX`
//!   codepoints. [`MAX_CANDIDATE_BYTES`] is checked in [`Candidates::new`], so a
//!   `Candidates` that violates it cannot be constructed and `rank` has no
//!   reachable assert.
//! * `Pattern::score` sums a `u16` per atom into a `u32`. [`MAX_QUERY_BYTES`]
//!   caps the atom count far below the 65536 needed to overflow it.
//! * There is no recursion in this module, and `nucleo`'s matrix is a single
//!   heap slab (`alloc_zeroed`, bounded by hardcoded constants) that degrades to
//!   greedy matching rather than growing -- so no input dimension reaches the
//!   stack at all.
//! * The thread-local scratch matcher is reached through `try_with` and
//!   `try_borrow_mut`, never the panicking `with`/`borrow_mut`.
//!
//! The candidate *count* is deliberately unbounded: it costs memory linearly and
//! nothing else, the Ruby Array it comes from is already that large, and any cap
//! would be a number invented to look careful.

use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::cell::RefCell;
use std::cmp::Reverse;
use thiserror::Error;
use unicode_segmentation::UnicodeSegmentation;

/// The longest candidate that may enter a set, in bytes.
///
/// A completion candidate is a path, a command, or a name; `PATH_MAX` is 4096
/// and nothing longer is a candidate a human is selecting from a menu. The
/// number is a safety bound first (see the module note on panics) and a policy
/// second, which is why exceeding it is a loud error at build time rather than a
/// silent skip at match time.
pub const MAX_CANDIDATE_BYTES: usize = 4096;

/// The longest query that may be matched, in bytes.
///
/// Generous for something typed a keystroke at a time, and small enough that the
/// per-atom `u16` scores `Pattern::score` sums cannot overflow its `u32`
/// accumulator.
pub const MAX_QUERY_BYTES: usize = 256;

/// A candidate rejected at build time. Its `Display` is the FFI-visible message.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum BuildError {
    /// A candidate exceeded [`MAX_CANDIDATE_BYTES`].
    #[error("candidate {index} is {len} bytes, over the {MAX_CANDIDATE_BYTES}-byte limit")]
    CandidateTooLong {
        /// Position of the offending candidate in the batch.
        index: usize,
        /// Its length in bytes.
        len: usize,
    },
}

/// A query rejected before matching. Its `Display` is the FFI-visible message.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum QueryError {
    /// The query exceeded [`MAX_QUERY_BYTES`].
    #[error("query is {len} bytes, over the {MAX_QUERY_BYTES}-byte limit")]
    TooLong {
        /// Its length in bytes.
        len: usize,
    },
}

/// One ranked candidate.
///
/// `positions` index **grapheme clusters**, not bytes and not codepoints,
/// because that is the unit `nucleo` matches in once `unicode-segmentation` is
/// on -- `e` + U+0301 is one position. Ruby's matching sequence is
/// `String#grapheme_clusters`; a highlighter that sliced by `chars` would cut
/// between a letter and its accent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hit {
    /// Position of the candidate in the batch it was built from.
    pub index: usize,
    /// Higher is better. Comparable only against hits from the same query.
    pub score: u32,
    /// Matched grapheme-cluster positions, sorted and deduplicated.
    pub positions: Vec<u32>,
}

/// An immutable batch of candidates, matched many times.
///
/// Holds nothing but owned `String`s -- no cell, no lock, no lazy cache, no Ruby
/// object -- which is what lets [`ffi::Fuzzy`] promise `frozen_shareable`. The
/// 135 KB scratch buffer `nucleo` needs lives in [`with_matcher`]'s thread-local
/// and is deliberately *not* a field here; see that function for why.
pub struct Candidates {
    items: Vec<String>,
}

// A tripwire, and a narrow one. It catches `Rc`, `RefCell`, raw pointers, and
// anything else that is not `Send + Sync`. It does **not** prove "nothing
// reachable is mutable": `Mutex<T>`, `AtomicUsize` and `OnceLock` are all
// `Send + Sync` *and* interior-mutable, and would sail through it. The
// `frozen_shareable` promise on `ffi::Fuzzy` still rests on the audit written
// into that type's doc comment, which a human has to read.
//
// It asserts on `Candidates` rather than on `ffi::Fuzzy`, which is the type
// actually carrying the attribute. That is structural, not an oversight: `ffi`
// is `#[cfg(not(test))]` and does not exist in the build that evaluates this.
// `Arc<Candidates>` is `Fuzzy`'s only field, so this is the reachable part of
// the claim -- which is why the narrow check is still worth having.
const _: () = {
    const fn assert_send<T: Send>() {}
    const fn assert_sync<T: Sync>() {}
    assert_send::<Candidates>();
    assert_sync::<Candidates>();
};

impl Candidates {
    /// Take ownership of a batch, refusing any candidate over
    /// [`MAX_CANDIDATE_BYTES`].
    pub fn new(items: Vec<String>) -> Result<Self, BuildError> {
        let offender = items
            .iter()
            .position(|item| item.len() > MAX_CANDIDATE_BYTES);
        match offender {
            Some(index) => Err(BuildError::CandidateTooLong {
                index,
                len: items[index].len(),
            }),
            None => Ok(Candidates { items }),
        }
    }

    /// The candidates, in the order they were given.
    pub fn items(&self) -> &[String] {
        &self.items
    }

    /// Rank every candidate against `query`, best first, keeping at most `limit`.
    pub fn rank(&self, query: &str, limit: Option<usize>) -> Result<Vec<Hit>, QueryError> {
        with_matcher(|matcher| self.rank_with(query, limit, matcher))
    }

    /// [`rank`](Candidates::rank) with the scratch matcher supplied by the
    /// caller. Split out so a test can prove that a matcher reused across calls
    /// answers identically to a fresh one -- the property the thread-local rests
    /// on, stated as a test rather than as a comment.
    pub fn rank_with(
        &self,
        query: &str,
        limit: Option<usize>,
        matcher: &mut Matcher,
    ) -> Result<Vec<Hit>, QueryError> {
        if query.len() > MAX_QUERY_BYTES {
            return Err(QueryError::TooLong { len: query.len() });
        }
        // `Pattern::parse`, not `Pattern::new`: it is what gives fzf's query
        // language -- `^prefix`, `suffix$`, `'substring`, `!negated`, and
        // whitespace as AND -- for free, and the completion UI advertises that
        // syntax. `Smart` case and normalization mean a lowercase query is
        // case-insensitive and an accented one is not silently folded.
        //
        // "Whitespace" means the SPACE character and nothing else: upstream's
        // `pattern_atoms` splits on `' '`, so a tab or a newline in the query is
        // a literal char to be matched, and `"thing\t.rb"` therefore matches
        // nothing. A caller taking a query from a line editor should normalize
        // whitespace before it gets here.
        let pattern = Pattern::parse(query, CaseMatching::Smart, Normalization::Smart);

        let mut haystack: Vec<char> = Vec::new();
        let mut positions = Vec::new();
        let mut hits = Vec::new();
        for (index, item) in self.items.iter().enumerate() {
            positions.clear();
            segment_into(item, &mut haystack);
            let score = pattern.indices(Utf32Str::Unicode(&haystack), matcher, &mut positions);
            if let Some(score) = score {
                // Upstream appends each atom's indices without merging, so that a
                // caller can attribute them to their atom. A highlighter cannot,
                // and overlapping atoms would double-underline.
                positions.sort_unstable();
                positions.dedup();
                hits.push(Hit {
                    index,
                    score,
                    positions: positions.clone(),
                });
            }
        }

        // A total order, so the result does not depend on the sort being stable:
        // best score first, and equal scores in candidate order. That is the
        // whole of the determinism claim, and it is why the batch's insertion
        // order is worth preserving.
        hits.sort_unstable_by_key(|hit| (Reverse(hit.score), hit.index));
        if let Some(limit) = limit {
            hits.truncate(limit);
        }
        Ok(hits)
    }
}

/// Fill `buf` with one `char` per grapheme cluster of `text` -- the cluster's
/// first codepoint, which is the representative `nucleo` itself uses.
///
/// This exists instead of `Utf32Str::new` because that constructor is **not
/// index-space stable**. It returns `Ascii(str.as_bytes())`, and therefore BYTE
/// offsets, whenever the string's grapheme-leading chars all happen to be ASCII
/// -- true of `"ne\u{301}on"`, whose clusters lead with `n e o n`. Every other
/// input gives grapheme indices. Mixing the two silently mis-highlights any
/// accented candidate, so we take the one path unconditionally: positions are
/// grapheme indices, always, and `String#grapheme_clusters` is the Ruby
/// sequence they index.
///
/// Giving up the `Ascii` variant costs `nucleo`'s byte-wise prefilter on ASCII
/// haystacks. That is a deliberate trade of unmeasured speed for a single index
/// space, in the direction the crate's own rules point.
///
/// The representative is also a real limitation, inherited from upstream and
/// applied to needle and haystack alike: **only a cluster's FIRST codepoint is
/// matchable**. A query for a non-leading codepoint of a cluster never matches
/// -- searching for a single emoji inside a ZWJ sequence finds nothing, because
/// the sequence is one position whose representative is its first emoji. The
/// alternative is matching against a codepoint sequence and reporting positions
/// no highlighter can use, so this is the right trade; it just has to be
/// written down.
fn segment_into(text: &str, buf: &mut Vec<char>) {
    buf.clear();
    buf.extend(
        text.graphemes(true)
            .filter_map(|cluster| cluster.chars().next()),
    );
}

thread_local! {
    /// `Matcher::new` eagerly allocates ~135 KB of reusable scratch and every
    /// matching method takes `&mut self`, so upstream's own guidance is to hold
    /// one and reuse it. Holding it in a *thread-local static* rather than in the
    /// wrapped object is what buys both halves of that trade-off: the allocation
    /// happens once per thread instead of once per keystroke, and the object
    /// stays free of interior mutability, so its `frozen_shareable` promise is
    /// still honest.
    ///
    /// What makes the sharing safe **today** is the GVL plus `try_borrow_mut`,
    /// not Ractors. `Ractor.shareable?(fuzzy)` is genuinely `true`, but calling
    /// any method on the handle from a non-main Ractor raises
    /// `Ractor::UnsafeError` -- nothing in this crate calls
    /// `rb_ext_ractor_safe`, so that is true of `Bm25#search` and every other
    /// binding here too, and it is a separate unmet piece of work rather than a
    /// property of this design. The thread-local would be the right shape once
    /// that lands, since each Ractor is its own thread; it is not the reason the
    /// design is correct now.
    ///
    /// The slab carries no semantic state between calls -- `Matcher::clone`
    /// deliberately hands back a *fresh* one -- and
    /// `a_reused_matcher_agrees_with_a_fresh_one` is the proof.
    static MATCHER: RefCell<Matcher> = RefCell::new(Matcher::new(Config::DEFAULT));
}

/// Run `f` against the thread's scratch matcher, falling back to a fresh one if
/// the thread-local is unreachable (during TLS teardown) or already borrowed
/// (re-entrancy). Neither is reachable from a Ruby method call, but both are
/// *panics* on the ergonomic API, and a panic here is undefined behaviour.
///
/// The `FnMut` bound looks wrong for something called once. It is what lets the
/// fallback call `f` after `try_with` has borrowed and released it, instead of
/// duplicating the body.
fn with_matcher<T>(mut f: impl FnMut(&mut Matcher) -> T) -> T {
    MATCHER
        .try_with(|cell| {
            cell.try_borrow_mut()
                .ok()
                .map(|mut matcher| f(&mut matcher))
        })
        .ok()
        .flatten()
        .unwrap_or_else(|| f(&mut Matcher::new(Config::DEFAULT)))
}

/// The `Lain::Ext::Fuzzy` binding.
///
/// Two crossings and no more: `.new` takes the whole candidate Array, `#match`
/// returns the whole ranked result. Nothing here is per-element, which is the
/// rule a naive binding breaks first.
#[cfg(not(test))]
pub mod ffi {
    use super::{BuildError, Candidates, Hit, QueryError};
    use crate::ffi::{frozen_str, int, lookup_error};
    // The one string-boundary policy, shared with `prompt`, `astgrep` and
    // `treesitter`. Candidate positions here index GRAPHEME CLUSTERS (see
    // `positions`), which only means anything because `read_text` guarantees the
    // clusters are the caller's own bytes and not a transcoded copy.
    use crate::read_text::read_text;
    use magnus::{
        DataTypeFunctions, Error, ExceptionClass, Integer, RArray, RHash, RModule, Ruby, TypedData,
        Value, function, method,
        prelude::*,
        scan_args::{get_kwargs, scan_args},
        typed_data::Obj,
    };
    use std::sync::Arc;

    /// A frozen candidate set, `Ractor.shareable?`.
    ///
    /// Wraps only `Arc<Candidates>`, which is a `Vec<String>` and nothing else --
    /// no `Cell`/`RefCell`/`Mutex`/`OnceCell`/atomic/lazy cache is reachable from
    /// it, and it holds no Ruby object. The one piece of mutable state this
    /// binding needs, `nucleo`'s 135 KB scratch matcher, is deliberately NOT a
    /// field: it lives in a thread-local (see `with_matcher`), so the handle
    /// carries no mutable state and the `frozen_shareable` promise stays honest.
    /// That placement is the whole reason this object can make the same claim
    /// `Bm25` does.
    ///
    /// This audit is the promise. `frozen_shareable` is unchecked, and the
    /// `assert_send`/`assert_sync` block above `Candidates` is a narrower
    /// tripwire than it looks -- see the comment there for what it does and does
    /// not catch.
    ///
    /// `Ractor.shareable?` being `true` is not the same as being *callable* from
    /// a Ractor: every method here raises `Ractor::UnsafeError` off the main
    /// Ractor, because no binding in this crate calls `rb_ext_ractor_safe`. That
    /// is crate-wide (`Bm25#search` included) and separately owed.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Fuzzy", free_immediately, frozen_shareable)]
    pub struct Fuzzy {
        inner: Arc<Candidates>,
    }

    impl DataTypeFunctions for Fuzzy {}

    impl Fuzzy {
        /// `Lain::Ext::Fuzzy.new(candidates)` -- one batch crossing. Raises the
        /// named `Fuzzy::CandidateTooLong` from the pure builder.
        fn new(ruby: &Ruby, candidates: RArray) -> Result<Obj<Self>, Error> {
            let batch = candidates
                .into_iter()
                .enumerate()
                .map(|(index, value)| read_text(ruby, value, || format!("candidate {index}")))
                .collect::<Result<Vec<String>, Error>>()?;

            // `BuildError`'s `Display` IS the Ruby-visible message; there is no
            // second wording here to drift from the Rust test.
            let inner = Candidates::new(batch).map_err(|err| match err {
                BuildError::CandidateTooLong { .. } => lookup_error(
                    ruby,
                    &["Lain", "Ext", "Fuzzy", "CandidateTooLong"],
                    err.to_string(),
                ),
            })?;

            let obj = ruby.obj_wrap(Fuzzy {
                inner: Arc::new(inner),
            });
            obj.freeze();
            Ok(obj)
        }

        /// The candidates, frozen, in the order they were given. Rebuilt per call
        /// rather than cached, exactly as `Prompt#settings` is, so the handle
        /// never holds a Ruby reference -- which is what keeps it shareable.
        ///
        /// So this is **O(n) Ruby String allocations every call**: 100k
        /// candidates means 100k Strings. It is for inspection and for rebuilding
        /// a set, not for the per-keystroke path -- `#match` already returns the
        /// candidate text on each hit, so a completion loop never needs to call
        /// this.
        fn candidates(ruby: &Ruby, rb_self: &Fuzzy) -> Result<RArray, Error> {
            let items = rb_self.inner.items();
            let out = ruby.ary_new_capa(items.len());
            items
                .iter()
                .try_for_each(|item| out.push(frozen_str(ruby, item)))?;
            out.freeze();
            Ok(out)
        }

        fn size(rb_self: &Fuzzy) -> usize {
            rb_self.inner.items().len()
        }

        /// `#match(query, limit: nil)` -> the whole ranked result, one crossing.
        ///
        /// `limit` is optional because `nil` has an honest meaning here -- every
        /// hit -- unlike `Prompt#render`'s `color:`, where a default would let a
        /// caller forget who is entitled to answer.
        fn match_query(ruby: &Ruby, rb_self: &Fuzzy, args: &[Value]) -> Result<RArray, Error> {
            let parsed = scan_args::<(Value,), (), (), (), RHash, ()>(args)?;
            let (query,) = parsed.required;
            let kwargs =
                get_kwargs::<_, (), (Option<Value>,), ()>(parsed.keywords, &[], &["limit"])?;
            let limit = read_limit(ruby, kwargs.optional.0)?;
            let query = read_text(ruby, query, || "query".to_string())?;

            let hits = rb_self.inner.rank(&query, limit).map_err(|err| match err {
                QueryError::TooLong { .. } => lookup_error(
                    ruby,
                    &["Lain", "Ext", "Fuzzy", "QueryTooLong"],
                    err.to_string(),
                ),
            })?;

            let out = ruby.ary_new_capa(hits.len());
            hits.iter()
                .try_for_each(|hit| out.push(hit_to_ruby(ruby, rb_self, hit)?))?;
            out.freeze();
            Ok(out)
        }
    }

    /// Read the `limit:` keyword. Absent or `nil` means every hit.
    ///
    /// Hand-rolled rather than declared as `Option<Option<usize>>`, because
    /// magnus's own conversion is quietly wrong in both directions here: it
    /// accepts `limit: 1.5` and truncates it to `1`, and it turns `limit: -1`
    /// into `RangeError: can't convert negative integer to unsigned`, a message
    /// that never names `limit:` and reads like an internal fault. Every other
    /// entry point in this binding fails loudly and says which argument was
    /// wrong; this one now does too.
    ///
    /// A Float is refused rather than truncated. Ruby's own `Array#take(1.5)`
    /// does truncate, so this is deliberately *stricter* than the nearest core
    /// method: a fractional `limit:` in a completion menu is a caller's
    /// arithmetic bug, and silently rounding it hides the bug at the one place
    /// that could still report it.
    fn read_limit(ruby: &Ruby, value: Option<Value>) -> Result<Option<usize>, Error> {
        let Some(value) = value.filter(|value| !value.is_nil()) else {
            return Ok(None);
        };
        let integer = Integer::from_value(value).ok_or_else(|| {
            // SAFETY: as in `read_text` -- `classname` borrows from the object,
            // which is rooted for the duration of this call, and no Ruby code
            // runs meanwhile.
            let class = unsafe { value.classname() }.into_owned();
            Error::new(
                ruby.exception_type_error(),
                format!("limit: must be an Integer or nil, got {class}"),
            )
        })?;
        let count = integer.to_i64().map_err(|_| {
            Error::new(
                ruby.exception_range_error(),
                "limit: is too large to be a result count".to_string(),
            )
        })?;
        usize::try_from(count).map(Some).map_err(|_| {
            Error::new(
                ruby.exception_arg_error(),
                format!("limit: must not be negative, got {count}"),
            )
        })
    }

    /// One hit as a frozen Hash. String keys, matching the `astgrep`/`treesitter`
    /// result shape rather than Bm25's positional tuples: four fields is past the
    /// point where `hit[3]` reads as anything.
    fn hit_to_ruby(ruby: &Ruby, fuzzy: &Fuzzy, hit: &Hit) -> Result<Value, Error> {
        let positions = ruby.ary_new_capa(hit.positions.len());
        hit.positions
            .iter()
            .try_for_each(|position| positions.push(ruby.integer_from_u64(u64::from(*position))))?;
        positions.freeze();

        let out = ruby.hash_new();
        out.aset(
            frozen_str(ruby, "candidate"),
            frozen_str(ruby, &fuzzy.inner.items()[hit.index]),
        )?;
        out.aset(frozen_str(ruby, "index"), int(ruby, hit.index))?;
        out.aset(
            frozen_str(ruby, "score"),
            ruby.integer_from_u64(u64::from(hit.score)),
        )?;
        out.aset(frozen_str(ruby, "positions"), positions.as_value())?;
        out.freeze();
        Ok(out.as_value())
    }

    /// Register `Lain::Ext::Fuzzy` and its two named errors. Called from
    /// `lib.rs`'s `init`; the class definition lives here so the matcher and its
    /// binding stay in one file.
    pub fn define(ruby: &Ruby, ext: RModule, lain_error: ExceptionClass) -> Result<(), Error> {
        let fuzzy = ext.define_class("Fuzzy", ruby.class_object())?;
        fuzzy.define_error("CandidateTooLong", lain_error)?;
        fuzzy.define_error("QueryTooLong", lain_error)?;
        fuzzy.define_singleton_method("new", function!(Fuzzy::new, 1))?;
        fuzzy.define_method("candidates", method!(Fuzzy::candidates, 0))?;
        fuzzy.define_method("size", method!(Fuzzy::size, 0))?;
        fuzzy.define_method("match", method!(Fuzzy::match_query, -1))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths() -> Vec<String> {
        vec![
            "lib/lain/frontend/tty.rb".to_string(),
            "lib/lain/tools/bash.rb".to_string(),
        ]
    }

    fn ranked(candidates: &Candidates, query: &str) -> Vec<String> {
        candidates
            .rank(query, None)
            .expect("query within bounds")
            .into_iter()
            .map(|hit| candidates.items()[hit.index].clone())
            .collect()
    }

    #[test]
    fn the_frontend_path_ranks_first_for_ttyrb() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        assert_eq!(
            ranked(&candidates, "ttyrb").first().map(String::as_str),
            Some("lib/lain/frontend/tty.rb")
        );
    }

    #[test]
    fn a_hit_names_the_positions_that_matched() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        let hits = candidates.rank("tty", None).expect("query within bounds");
        let hit = hits.first().expect("tty matches the frontend path");
        assert_eq!(
            matched_text(&candidates.items()[hit.index], &hit.positions),
            "tty"
        );
    }

    /// Slice a candidate by the grapheme positions a hit reports -- what a
    /// highlighter does, and therefore the only honest check that the positions
    /// mean what the docs say.
    fn matched_text(candidate: &str, positions: &[u32]) -> String {
        candidate
            .graphemes(true)
            .enumerate()
            .filter(|(i, _)| u32::try_from(*i).is_ok_and(|i| positions.contains(&i)))
            .map(|(_, cluster)| cluster)
            .collect()
    }

    #[test]
    fn positions_are_sorted_and_deduplicated() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        let hits = candidates.rank("rb b", None).expect("query within bounds");
        for hit in &hits {
            let mut expected = hit.positions.clone();
            expected.sort_unstable();
            expected.dedup();
            assert_eq!(hit.positions, expected);
        }
    }

    #[test]
    fn a_non_matching_candidate_is_excluded() {
        let candidates =
            Candidates::new(vec!["lib/lain/tools/bash.rb".to_string()]).expect("within bounds");
        assert!(
            candidates
                .rank("zzzz", None)
                .expect("query within bounds")
                .is_empty()
        );
    }

    #[test]
    fn one_call_ranks_five_hundred_candidates() {
        let items: Vec<String> = (0..500)
            .map(|i| format!("lib/lain/thing_{i:03}.rb"))
            .collect();
        let candidates = Candidates::new(items).expect("candidates within bounds");
        assert_eq!(
            candidates
                .rank("thing", None)
                .expect("query within bounds")
                .len(),
            500
        );
    }

    #[test]
    fn ties_break_by_candidate_order_and_repeat_identically() {
        let items = vec![
            "alpha/x.rb".to_string(),
            "beta/x.rb".to_string(),
            "gamma/x.rb".to_string(),
        ];
        let candidates = Candidates::new(items).expect("candidates within bounds");
        let first = candidates.rank("x.rb", None).expect("query within bounds");
        let second = candidates.rank("x.rb", None).expect("query within bounds");

        assert_eq!(first, second);
        let scores: Vec<u32> = first.iter().map(|hit| hit.score).collect();
        assert_eq!(scores.len(), 3);
        assert!(
            scores.windows(2).all(|pair| pair[0] == pair[1]),
            "the three candidates must score identically, got {scores:?}"
        );
        assert_eq!(
            first.iter().map(|hit| hit.index).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn an_empty_batch_is_valid_and_matches_nothing() {
        let candidates = Candidates::new(vec![]).expect("an empty batch is valid");
        assert!(candidates.items().is_empty());
        assert!(
            candidates
                .rank("anything", None)
                .expect("query within bounds")
                .is_empty()
        );
    }

    #[test]
    fn an_empty_query_keeps_every_candidate_in_order() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        assert_eq!(ranked(&candidates, ""), paths());
    }

    #[test]
    fn limit_truncates_the_ranked_result() {
        let items: Vec<String> = (0..20).map(|i| format!("thing_{i}.rb")).collect();
        let candidates = Candidates::new(items).expect("candidates within bounds");
        assert_eq!(
            candidates
                .rank("thing", Some(5))
                .expect("query within bounds")
                .len(),
            5
        );
    }

    #[test]
    fn an_over_long_candidate_is_refused_at_build() {
        let long = "x".repeat(MAX_CANDIDATE_BYTES + 1);
        let err = Candidates::new(vec!["ok".to_string(), long])
            .err()
            .expect("an over-long candidate is refused");
        assert_eq!(
            err,
            BuildError::CandidateTooLong {
                index: 1,
                len: MAX_CANDIDATE_BYTES + 1
            }
        );
    }

    #[test]
    fn an_over_long_query_is_refused() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        let query = "q".repeat(MAX_QUERY_BYTES + 1);
        assert_eq!(
            candidates.rank(&query, None).unwrap_err(),
            QueryError::TooLong {
                len: MAX_QUERY_BYTES + 1
            }
        );
    }

    // `Utf32Str::new` would return `Ascii(str.as_bytes())` for this candidate --
    // it is not ASCII, but every cluster LEADS with an ASCII char -- and report
    // byte offsets `[0, 4, 5]` where every other input gets grapheme indices.
    // That is the defect `segment_into` exists to close, so this test states the
    // index space rather than merely exercising it.
    #[test]
    fn positions_index_grapheme_clusters_even_when_every_cluster_leads_with_ascii() {
        // "n" + "e" + U+0301 + "o" + "n" -- 6 bytes, 5 codepoints, 4 graphemes.
        let neon = "ne\u{301}on".to_string();
        let candidates = Candidates::new(vec![neon.clone()]).expect("candidates within bounds");
        let hits = candidates.rank("non", None).expect("query within bounds");
        let hit = hits.first().expect("non matches neon");

        assert_eq!(neon.len(), 6);
        assert_eq!(neon.chars().count(), 5);
        assert_eq!(neon.graphemes(true).count(), 4);
        assert_eq!(hit.positions, vec![0, 2, 3]);
        assert_eq!(matched_text(&neon, &hit.positions), "non");
    }

    // CR+LF is UAX#29's only cluster rule that fires on pure ASCII (GB3), so an
    // ASCII candidate can still have fewer graphemes than bytes. The index space
    // has to hold there too, which is why there is no `is_ascii()` fast path.
    #[test]
    fn positions_index_grapheme_clusters_across_an_ascii_crlf() {
        let crlf = "a\r\nb".to_string();
        let candidates = Candidates::new(vec![crlf.clone()]).expect("candidates within bounds");
        let hits = candidates.rank("ab", None).expect("query within bounds");
        let hit = hits.first().expect("ab matches a-crlf-b");

        assert_eq!(crlf.len(), 4);
        assert_eq!(crlf.graphemes(true).count(), 3);
        assert_eq!(hit.positions, vec![0, 2]);
        assert_eq!(matched_text(&crlf, &hit.positions), "ab");
    }

    #[test]
    fn the_fzf_prefix_anchor_is_honoured() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        assert_eq!(ranked(&candidates, "^lib").len(), 2);
        assert!(ranked(&candidates, "^tty").is_empty());
    }

    #[test]
    fn the_fzf_negation_operator_is_honoured() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        assert_eq!(
            ranked(&candidates, "rb !tools"),
            vec!["lib/lain/frontend/tty.rb".to_string()]
        );
    }

    // The thread-local scratch matcher is only honest if reusing it is
    // observationally pure. This is that claim, as a test.
    #[test]
    fn a_reused_matcher_agrees_with_a_fresh_one() {
        let candidates = Candidates::new(paths()).expect("candidates within bounds");
        let mut reused = Matcher::new(Config::DEFAULT);

        let warm = candidates
            .rank_with("lib", None, &mut reused)
            .expect("query within bounds");
        assert!(!warm.is_empty());
        let again = candidates
            .rank_with("tty", None, &mut reused)
            .expect("query within bounds");
        let fresh = candidates
            .rank_with("tty", None, &mut Matcher::new(Config::DEFAULT))
            .expect("query within bounds");

        assert_eq!(again, fresh);
    }
}
