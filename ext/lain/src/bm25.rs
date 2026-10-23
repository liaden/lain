//! Pure, libruby-free BM25 index over the `bm25` crate.
//!
//! An index is built ONCE from a batch of `(id, text)` pairs (the FFI boundary
//! is crossed in one batch, per the crate's data-structure placement rules) and
//! is immutable thereafter -- no `upsert`/`remove` is exposed. Nothing here
//! touches `magnus`, so build, search, tie-breaking, and the query/document
//! token intersection are all unit-tested in `cargo test` without an embedded
//! Ruby VM; the FFI wrapper in `lib.rs` wraps a built index in a frozen,
//! `Ractor.shareable?` handle.
//!
//! `build_until` upserts into the engine one document at a time so a stop request can be
//! read between them; no upsert or remove is exposed to Ruby, so the index stays immutable.
//!
//! ## Interior-mutability audit (the `frozen_shareable` promise)
//!
//! The FFI wrapper marks the handle `frozen_shareable`, an unchecked promise to
//! magnus that nothing reachable can mutate through a shared reference. That is
//! honest here only because every type reachable from [`Bm25Index`] is plain,
//! owned, immutable-after-build state:
//!
//! - `bm25::SearchEngine<String, u32, SurfaceTokenizer>` holds an `Embedder`
//!   (`SurfaceTokenizer` + three `f32`s + `PhantomData`), a `Scorer` (two
//!   `std::collections::HashMap`s, one with `HashSet` values), and a
//!   `HashMap<String, String>` of documents. No `Cell`/`RefCell`/`Mutex`/
//!   `RwLock`/`OnceCell`/atomic/lazy cache anywhere among them (audited against
//!   `bm25` 2.3.2 `embedder.rs`, `scorer.rs`, `search.rs`).
//! - [`SurfaceTokenizer`] is a zero-size unit struct with no state.
//! - `order` and `doc_tokens` are our own owned maps.
//!
//! The one interior-mutability source in the crate -- the `cached`-memoized
//! `DefaultTokenizer` -- lives behind the `default_tokenizer` feature, which the
//! `Cargo.toml` dependency disables (`default-features = false`). We supply our
//! own tokenizer, so `cached`/`stop-words`/`rust-stemmers`/`deunicode` are never
//! compiled in and are unreachable by construction.

use crate::nogvl::{Cancel, Halted, Threshold};
use bm25::{Document, SearchEngine, SearchEngineBuilder, Tokenizer};
use std::collections::{BTreeSet, HashMap};

/// A deterministic surface tokenizer: lowercase, split on any non-alphanumeric
/// character, drop empties. No language detection, no stemming, no stopword
/// removal -- the surviving tokens are the literal words the model sees, which
/// is what makes a hit's matched-token list an honest `#why`. Determinism is the
/// point: the same text tokenizes identically in every process.
#[derive(Debug, Default, Clone)]
pub struct SurfaceTokenizer;

/// The free function behind [`SurfaceTokenizer::tokenize`], also used directly to
/// tokenize a query for the matched-token intersection. `char::is_alphanumeric`
/// and `str::to_lowercase` are Unicode-aware and deterministic, so a rare
/// medical term (`"dactinomycin"`) survives whole and case-folds stably.
pub fn tokenize(text: &str) -> Vec<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(str::to_lowercase)
        .collect()
}

impl Tokenizer for SurfaceTokenizer {
    fn tokenize(&self, input_text: &str) -> Vec<String> {
        tokenize(input_text)
    }
}

/// Why a batch could not become an index. Mapped to named Ruby errors at the FFI
/// boundary (`Bm25::EmptyCorpus`, `Bm25::DuplicateId`).
///
/// The `Display` text below IS the FFI-visible message: `lib.rs`'s
/// `Bm25::build` match arms hand-build the identical strings today, which a
/// later card can replace with `.to_string()`.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum BuildError {
    /// The batch had no pairs; there is nothing to search.
    #[error("cannot build a BM25 index from an empty corpus")]
    EmptyCorpus,
    /// Two pairs shared this id; the id would not address one document.
    #[error("duplicate document id {0:?}")]
    DuplicateId(String),
}

/// An immutable BM25 index over a fixed corpus.
pub struct Bm25Index {
    engine: SearchEngine<String, u32, SurfaceTokenizer>,
    /// id -> build-batch insertion index, the pinned equal-score tie-breaker.
    ///
    /// A `usize`, which is what `enumerate` hands us, so there is no cast that
    /// could wrap two documents onto the same key. (The `u32` in `SearchEngine`
    /// above is the crate's per-document term-count type, not a corpus bound --
    /// narrowing this map to match it was our own choice, and a mistake.)
    order: HashMap<String, usize>,
    /// id -> the document's surface token set, for the query intersection that
    /// explains each hit. Stored at build so search never re-tokenizes documents.
    doc_tokens: HashMap<String, BTreeSet<String>>,
}

// Compile-time shareability canary, mirroring `turn.rs`'s `TurnData` assertion:
// `Bm25`'s `frozen_shareable` promise (see `lib.rs` and this module's own
// interior-mutability audit above) is honest only if `Bm25Index` -- and every
// type it owns transitively -- holds no interior mutability. A `Cell`/
// `RefCell` regression anywhere in that graph would make it `!Sync` with no
// other signal; this catches that class of regression at compile time. It
// canNOT catch a `Mutex`/atomic field -- those ARE `Sync` despite being
// interior mutability -- so a `Mutex`/atomic addition stays prose-audited.
const _: fn() = || {
    fn assert_sync<T: Sync>() {}
    assert_sync::<Bm25Index>();
};

/// Batches under this many bytes are built with the GVL held. Releasing hands
/// the lock to any busy Ruby thread and waits out its time slice, about 20 ms
/// beside a thread at `Tool::Offload`'s priority, to get it back. A build costs
/// about 0.11 ms per KB, so 128 KiB costs about 14 ms, a stall budget of about half a slice rather than a measured crossover.
pub const HOLD_BUILD_BELOW: Threshold = Threshold::new(128 * 1024);

/// Indexes under this many documents are searched with the GVL held, for the
/// same reason. A search costs about 1 us per document, so 10,000 cost about 10 ms.
pub const HOLD_SEARCH_BELOW: Threshold = Threshold::new(10_000);

impl Bm25Index {
    /// How many documents the index holds.
    pub fn documents(&self) -> usize {
        self.order.len()
    }

    /// Build an index from a batch of `(id, text)` pairs, preserving insertion
    /// order as the tie-breaker. Empty batches and duplicate ids fail loudly.
    ///
    /// The crate's own batch build is one uninterruptible call, so this fits the
    /// average document length itself, exactly as the crate does, and adds the
    /// documents one at a time with a stop request read between them. The pairs
    /// are taken by value because the engine keeps each document, so a caller
    /// that may run again after a halt hands in a copy.
    pub fn build_until(
        pairs: Vec<(String, String)>,
        cancel: &Cancel<'_>,
    ) -> Result<Result<Self, BuildError>, Halted> {
        if pairs.is_empty() {
            return Ok(Err(BuildError::EmptyCorpus));
        }
        let mut order = HashMap::with_capacity(pairs.len());
        let mut doc_tokens = HashMap::with_capacity(pairs.len());
        let mut total_len = 0_u64;
        for (position, (id, text)) in pairs.iter().enumerate() {
            cancel.check()?;
            if order.contains_key(id) {
                return Ok(Err(BuildError::DuplicateId(id.clone())));
            }
            let tokens = tokenize(text);
            total_len += tokens.len() as u64;
            order.insert(id.clone(), position);
            doc_tokens.insert(id.clone(), tokens.into_iter().collect::<BTreeSet<_>>());
        }
        let avgdl = (total_len as f64 / pairs.len() as f64) as f32;
        let mut engine =
            SearchEngineBuilder::<String, u32, SurfaceTokenizer>::with_avgdl(avgdl).build();
        for (id, text) in pairs {
            cancel.check()?;
            engine.upsert(Document::new(id, text));
        }
        Ok(Ok(Self {
            engine,
            order,
            doc_tokens,
        }))
    }

    /// The top `k` hits for `query` as `(id, score, matched_tokens)`, ranked by
    /// descending BM25 score with equal-score ties broken by insertion order.
    ///
    /// We ask the crate for ALL matches (`limit = None`) and truncate ourselves.
    /// The crate sorts by score with a *stable* sort over a `HashSet`-ordered
    /// candidate set, so its equal-score order is per-process nondeterministic;
    /// truncating to `k` before imposing our deterministic order could drop the
    /// wrong tied document. Re-sorting the full set first makes the result
    /// byte-identical across processes.
    ///
    /// The crate scores every candidate in one call, so a stop request is read
    /// before and after that call and not inside it.
    pub fn search_until(
        &self,
        query: &str,
        k: usize,
        cancel: &Cancel<'_>,
    ) -> Result<Vec<(String, f32, Vec<String>)>, Halted> {
        cancel.check()?;
        let query_tokens: BTreeSet<String> = tokenize(query).into_iter().collect();
        let mut hits = self.engine.search(query, None);
        cancel.check()?;
        hits.sort_by(|a, b| {
            // `total_cmp` is a total order over f32 (no NaN unwrap); scores are
            // finite and non-negative here regardless.
            b.score.total_cmp(&a.score).then_with(|| {
                self.insertion(&a.document.id)
                    .cmp(&self.insertion(&b.document.id))
            })
        });
        Ok(hits
            .into_iter()
            .take(k)
            .map(|hit| {
                let matched = self
                    .doc_tokens
                    .get(&hit.document.id)
                    .map(|doc| doc.intersection(&query_tokens).cloned().collect())
                    .unwrap_or_default();
                (hit.document.id, hit.score, matched)
            })
            .collect())
    }

    #[cfg(test)]
    fn build(pairs: Vec<(String, String)>) -> Result<Self, BuildError> {
        Self::build_until(pairs, &Cancel::never()).expect("nothing asked to stop")
    }

    #[cfg(test)]
    fn search(&self, query: &str, k: usize) -> Vec<(String, f32, Vec<String>)> {
        self.search_until(query, k, &Cancel::never())
            .expect("nothing asked to stop")
    }

    /// The insertion index of an id known to be in the corpus. Every id the
    /// engine returns was inserted at build, so the fallback is unreachable;
    /// `usize::MAX` sorts an impossible stray id last rather than panicking,
    /// and no position `enumerate` can produce collides with it.
    fn insertion(&self, id: &str) -> usize {
        self.order.get(id).copied().unwrap_or(usize::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_batch_or_index_below_the_threshold_keeps_the_lock_and_a_larger_one_releases_it() {
        assert!(!HOLD_BUILD_BELOW.releases(0));
        assert!(!HOLD_BUILD_BELOW.releases(128 * 1024 - 1));
        assert!(HOLD_BUILD_BELOW.releases(128 * 1024));
        assert!(!HOLD_SEARCH_BELOW.releases(0));
        assert!(!HOLD_SEARCH_BELOW.releases(9_999));
        assert!(HOLD_SEARCH_BELOW.releases(10_000));
    }

    #[test]
    fn an_index_counts_its_documents() {
        assert_eq!(Bm25Index::build(corpus()).unwrap().documents(), 4);
    }

    fn corpus() -> Vec<(String, String)> {
        vec![
            ("mat".into(), "the cat sat on the mat".into()),
            (
                "dact".into(),
                "dactinomycin is an antineoplastic chemotherapy drug".into(),
            ),
            (
                "imat".into(),
                "imatinib treats chronic myeloid leukemia".into(),
            ),
            (
                "aspirin".into(),
                "aspirin is a common analgesic and antiplatelet agent".into(),
            ),
        ]
    }

    #[test]
    fn tokenize_lowercases_and_splits_on_non_alphanumeric() {
        assert_eq!(
            tokenize("Dactinomycin, an ANTI-neoplastic drug!"),
            vec!["dactinomycin", "an", "anti", "neoplastic", "drug"]
        );
    }

    #[test]
    fn tokenize_drops_empties_and_keeps_unicode() {
        assert_eq!(tokenize("  étude   café  "), vec!["étude", "café"]);
        assert!(tokenize("   ,.;   ").is_empty());
    }

    #[test]
    fn build_rejects_an_empty_corpus() {
        // `Bm25Index` is deliberately not `Debug` (its `SearchEngine` field only
        // derives `Debug` when every generic does), so match the error rather
        // than `unwrap_err`, which would require `Debug` on the `Ok` type.
        assert!(matches!(
            Bm25Index::build(vec![]),
            Err(BuildError::EmptyCorpus)
        ));
    }

    #[test]
    fn build_rejects_duplicate_ids() {
        let built = Bm25Index::build(vec![("x".into(), "one".into()), ("x".into(), "two".into())]);
        assert!(matches!(built, Err(BuildError::DuplicateId(id)) if id == "x"));
    }

    #[test]
    fn exact_term_query_wins_and_explains() {
        let index = Bm25Index::build(corpus()).unwrap();
        let results = index.search("dactinomycin", 5);
        assert_eq!(results.first().map(|hit| hit.0.as_str()), Some("dact"));
        assert!(results[0].2.iter().any(|token| token == "dactinomycin"));
    }

    #[test]
    fn no_shared_tokens_returns_empty() {
        let index = Bm25Index::build(corpus()).unwrap();
        assert!(index.search("zzznonexistent qqquux", 5).is_empty());
    }

    #[test]
    fn results_are_bounded_by_k_and_descending() {
        let index = Bm25Index::build(corpus()).unwrap();
        let results = index.search("drug agent chemotherapy", 2);
        assert!(results.len() <= 2);
        assert!(results.windows(2).all(|pair| pair[0].1 >= pair[1].1));
    }

    #[test]
    fn matched_tokens_are_the_query_document_intersection() {
        let index = Bm25Index::build(corpus()).unwrap();
        let hit = index
            .search("chemotherapy drug for cats", 1)
            .into_iter()
            .next()
            .expect("a hit");
        assert_eq!(hit.0, "dact");
        // "chemotherapy" and "drug" are shared; "for"/"cats" are not in `dact`.
        assert_eq!(hit.2, vec!["chemotherapy".to_string(), "drug".to_string()]);
    }

    #[test]
    fn equal_scores_break_ties_by_insertion_order() {
        let index = Bm25Index::build(vec![
            ("first".into(), "identical body text here".into()),
            ("second".into(), "identical body text here".into()),
        ])
        .unwrap();
        let ids: Vec<String> = index
            .search("identical body text", 5)
            .into_iter()
            .map(|hit| hit.0)
            .collect();
        assert_eq!(ids, vec!["first".to_string(), "second".to_string()]);
    }

    // Display IS the FFI-visible message: `lib.rs`'s `Bm25::build` match arms
    // hand-build these exact texts today. Pin them so a later card can swap
    // those arms for `.to_string()` with no byte drift.
    #[test]
    fn build_error_display_is_the_exact_ffi_message() {
        assert_eq!(
            BuildError::EmptyCorpus.to_string(),
            "cannot build a BM25 index from an empty corpus"
        );
        assert_eq!(
            BuildError::DuplicateId("x".to_string()).to_string(),
            r#"duplicate document id "x""#
        );
    }

    #[test]
    fn build_error_is_a_std_error() {
        let boxed: Box<dyn std::error::Error> = Box::new(BuildError::EmptyCorpus);
        assert_eq!(
            boxed.to_string(),
            "cannot build a BM25 index from an empty corpus"
        );
    }

    // The tie-break key is the `usize` `enumerate` produced, so there is no
    // cast to wrap and no corpus bound to refuse. `position as u32` used to
    // restart at 0 past 2^32 documents, handing two documents the same key and
    // making the pinned insertion order silently not an order.
    #[test]
    fn the_tie_break_key_is_the_usize_position() {
        let index = Bm25Index::build(corpus()).expect("builds");
        let position: usize = index.insertion("dact");
        assert_eq!(position, 1);
        assert_eq!(index.insertion("mat"), 0);
        assert_eq!(index.insertion("aspirin"), 3);
        // The stray-id sentinel sorts last and is now genuinely out of reach:
        // no `enumerate` over a `Vec` can produce `usize::MAX`, whereas
        // `u32::MAX` was a legal position for a corpus that big.
        assert_eq!(index.insertion("not in the corpus"), usize::MAX);
    }

    #[test]
    fn two_builds_are_byte_identical() {
        let a = Bm25Index::build(corpus())
            .unwrap()
            .search("drug chemotherapy agent", 10);
        let b = Bm25Index::build(corpus())
            .unwrap()
            .search("drug chemotherapy agent", 10);
        assert_eq!(a, b);
    }

    #[test]
    fn a_build_asked_to_stop_halts_and_a_search_asked_to_stop_halts() {
        let cancel = Cancel::raised();
        assert!(Bm25Index::build_until(corpus(), &cancel).is_err());

        let index = Bm25Index::build(corpus()).unwrap();
        assert_eq!(index.search_until("drug", 5, &cancel), Err(Halted));
    }

    #[test]
    fn an_empty_batch_is_refused_even_when_a_stop_was_asked_for() {
        let built = Bm25Index::build_until(vec![], &Cancel::raised());
        assert!(matches!(built, Ok(Err(BuildError::EmptyCorpus))));
    }

    #[test]
    fn the_fitted_average_length_matches_the_crates_own_batch_build() {
        let pairs = corpus();
        let documents = pairs
            .iter()
            .map(|(id, text)| Document::new(id.clone(), text));
        let theirs =
            SearchEngineBuilder::<String, u32, SurfaceTokenizer>::with_tokenizer_and_documents(
                SurfaceTokenizer,
                documents,
            )
            .build();
        let ours = Bm25Index::build(pairs).unwrap();
        for query in ["drug", "the cat", "chronic leukemia agent"] {
            let expected: Vec<_> = theirs
                .search(query, None)
                .iter()
                .map(|hit| hit.score)
                .collect();
            let found: Vec<_> = ours
                .engine
                .search(query, None)
                .iter()
                .map(|hit| hit.score)
                .collect();
            assert_eq!(found, expected);
        }
    }
}
