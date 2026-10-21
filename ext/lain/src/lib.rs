#![deny(clippy::print_stdout, clippy::print_stderr)]
#![deny(missing_docs)]
#![deny(rustdoc::broken_intra_doc_links, rustdoc::private_intra_doc_links)]
//! Output discipline is enforced at the crate root: `print_stdout` /
//! `print_stderr` are hard errors so no Rust code here can smear plain text
//! onto a stream the Ruby-side Journal may be parsing as NDJSON.
//!
//! **Documentation is enforced by two lints, and they cover different things.**
//! `missing_docs` here is only the `pub mod` tripwire: it fires on items
//! reachable as public API from this root, and every module below is private,
//! so its scope today is ZERO items. It bites the moment someone writes
//! `pub mod`; it is not a claim about current coverage, and on its own it would
//! not notice a deleted doc comment anywhere in this crate.
//!
//! The lint that actually bites today is scoped rather than global:
//! `clippy::missing_docs_in_private_items` is denied on `algebra`, `dag`,
//! `digest` and `graph`, the modules carrying this crate's ancestry structures
//! and the claims made about them -- `graph` and `algebra` carried the deny from
//! the moment each was declared, so nothing can land in them undocumented. All
//! four are at zero offenses, so the deny costs no doc-writing diff -- and
//! deleting any doc comment in them is a hard error (verified: removing
//! `meet`'s doc yields `error: missing documentation for a function`).
//! Crate-wide the same lint would report 109 and is deliberately NOT enabled:
//! filler comments on 109 items would be worse than none, while the modules
//! that carry a law are covered.
//!
//! What that documentation is FOR: an item carrying an ALGEBRAIC claim must name
//! the structure, the operation, and which suite proves it. There are two suites
//! and they prove different things -- `cargo test` proves the pure Rust
//! algorithm obeys a law, and `spec/lain/rust/*` proves the binding obeys it too
//! by running the shared example groups unchanged; agreement with the deleted
//! Ruby is the frozen corpus's (`ext/lain/corpus/`, read by `corpus.rs`). See the `dag` module's
//! own doc, which states that split once for the whole ancestry structure.

#[deny(clippy::missing_docs_in_private_items)]
mod algebra;
mod astgrep;
mod bm25;
mod canonical;
#[cfg(test)]
mod corpus;
#[deny(clippy::missing_docs_in_private_items)]
mod dag;
#[deny(clippy::missing_docs_in_private_items)]
mod digest;
mod event;
mod fuzzy;
#[deny(clippy::missing_docs_in_private_items)]
mod graph;
mod nogvl;
mod prompt;
mod read_text;
mod treesitter;

/// The lowercase-hex BLAKE3 digest of `bytes`.
///
/// Plain Rust, no `magnus` types, so `cargo test` covers the one hash Lain
/// uses for content-addressing without needing an embedded Ruby VM. `Canonical`
/// calls through the FFI wrapper below; this function is what is actually
/// under test.
fn blake3_hex(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

/// The extension's global allocator. Not in the unit-test build, which
/// installs its own per-thread counter (`dag`'s laziness tests).
#[cfg(not(test))]
mod heap {
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// The global allocator, `System` with a count of the bytes it holds live.
    ///
    /// A fiber dropped while suspended inside a call into Ruby is collected without
    /// being unwound, so a Rust frame waiting in it never runs its destructors and
    /// whatever it owns is never freed. That memory is invisible to every Ruby-side
    /// measure, so the count lives here, and `Lain::Ext::Probe.live_bytes` is how
    /// the reentry specs see a stranded allocation.
    struct Counting;

    /// Bytes allocated through [`Counting`] and not yet freed.
    pub(crate) static LIVE_BYTES: AtomicUsize = AtomicUsize::new(0);

    #[global_allocator]
    static ALLOCATOR: Counting = Counting;

    // SAFETY: every method forwards its arguments to `System` unchanged and
    // returns what `System` returned, so `System`'s guarantees are this
    // allocator's; the only addition is a relaxed counter, which allocates nothing.
    unsafe impl GlobalAlloc for Counting {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            // SAFETY: the caller's contract for `alloc`, passed through.
            let ptr = unsafe { System.alloc(layout) };
            if !ptr.is_null() {
                LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            }
            ptr
        }

        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            // SAFETY: the caller's contract for `alloc_zeroed`, passed through.
            let ptr = unsafe { System.alloc_zeroed(layout) };
            if !ptr.is_null() {
                LIVE_BYTES.fetch_add(layout.size(), Ordering::Relaxed);
            }
            ptr
        }

        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            // SAFETY: the caller's contract for `dealloc`, passed through.
            unsafe { System.dealloc(ptr, layout) };
            LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
        }

        unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            // SAFETY: the caller's contract for `realloc`, passed through.
            let moved = unsafe { System.realloc(ptr, layout, new_size) };
            if !moved.is_null() {
                LIVE_BYTES.fetch_add(new_size, Ordering::Relaxed);
                LIVE_BYTES.fetch_sub(layout.size(), Ordering::Relaxed);
            }
            moved
        }
    }
}

/// How deeply a Ruby structure may nest before the canonical reader refuses it.
///
/// This is a SAFETY bound, the same class of bound as `prompt.rs`'s `MAX_DEPTH`
/// and for the same measured reason: the reader recurses per container, and an
/// unbounded recursion over a hostile structure overflows the stack. Ruby's
/// guard-page handler turns that into a `SystemStackError`, which longjmps
/// through live Rust frames -- no destructor runs, and every allocation below
/// the jump leaks (measured on the prompt parser at 16 MB over 200 overflows).
/// Bounding the READ bounds everything downstream, because a `Canon` reaches
/// this crate only through the reader: `canonical::dump`, `canonical::digest`,
/// `canon_to_ruby`, and the `Canon` drop glue all recurse over the same tree, so
/// there is one limit here rather than four.
///
/// **100 is Ruby's own boundary, not a round number.** `Canonical.dump` ends in
/// `JSON.generate`, whose default `max_nesting` is 100, so 100 nested containers
/// is exactly the deepest structure the Ruby implementation can serialize --
/// verified on 4.0.6: depth 100 dumps, depth 101 raises `JSON::NestingError`.
/// Matching it makes the two implementations accept and refuse the same set of
/// structures, which is what parity means here; a lower bound would refuse
/// payloads Ruby serializes fine, and a higher one would accept structures Ruby
/// cannot dump at all. The deepest tree the canonical parity examples build is 3
/// (`spec/lain/rust/canonical_spec.rb`), so the bound is nowhere near real
/// payloads. `spec/lain/rust/canonical_spec.rb`'s "nesting depth" group pins
/// both sides of the boundary, so a JSON-gem change that moves Ruby's limit
/// fails there rather than drifting silently.
const MAX_CANON_DEPTH: usize = 100;

/// Enter one more container, answering the new depth -- or a message naming the
/// bound, when that would be one level too far.
///
/// Plain Rust with no `magnus` in its signature (the `validate_put` shape),
/// so `cargo test` covers the arithmetic the FFI reader depends on. The message
/// opens with `cannot canonicalize` because it is raised as
/// `Lain::Canonical::UnsupportedType`, whose whole family of messages -- and the
/// shared determinism group's `/cannot canonicalize/` matcher -- read that way.
fn descend(depth: usize) -> Result<usize, String> {
    let entered = depth + 1;
    if entered > MAX_CANON_DEPTH {
        return Err(format!(
            "cannot canonicalize a structure nested deeper than {MAX_CANON_DEPTH} levels"
        ));
    }
    Ok(entered)
}

/// The refusal of a NaN or an infinity, naming it as Ruby's `Float#to_s` does,
/// so the message is `Canonical`'s own. Plain Rust for the reason `descend` is.
fn non_finite(value: f64) -> String {
    let name = match value {
        v if v.is_nan() => "NaN",
        v if v > 0.0 => "Infinity",
        _ => "-Infinity",
    };
    format!("cannot canonicalize {name}")
}

/// How a [`Canon::Num`] text must be rebuilt as a Ruby value. `Canon::Num`
/// holds text a reader already rendered (an Integer's `#to_s` or a Float's
/// `JSON.generate`, see `canonical.rs`), so this classification is total on
/// that domain -- but the function is defined on ALL `&str` input, returning
/// `Err` for anything a reader could never emit. That is deliberate: it turns
/// "unreachable for reader-produced text" into a checked fact instead of an
/// assumption, so a future bug that hands this function un-rendered text
/// fails loudly instead of turning into a silent `NaN` or `nil`.
#[derive(Debug, PartialEq)]
enum NumClass {
    /// A JSON float text (contains `.`, `e`, or `E`), pre-parsed.
    Float(f64),
    /// An integer text that fits `i64`, pre-parsed.
    Small(i64),
    /// An integer text too large for `i64`. Kept as text -- Rust has no
    /// arbitrary-precision integer here, so the caller re-parses it through
    /// Ruby's own `String#to_i`, which is exactly what `canonical_dump`'s
    /// `Integer#to_s` inverts.
    Big,
}

fn classify_num(text: &str) -> Result<NumClass, String> {
    if text.contains(['.', 'e', 'E']) {
        return text
            .parse::<f64>()
            .map(NumClass::Float)
            .map_err(|e| format!("unparseable float text {text:?}: {e}"));
    }
    if let Ok(small) = text.parse::<i64>() {
        return Ok(NumClass::Small(small));
    }
    // Not an i64: valid only as a bignum if it is a non-empty run of ASCII
    // digits with an optional leading `-`. Anything else (garbage like
    // `"abc"` or `""`) must NOT fall through to Ruby's `String#to_i`, which
    // silently reads a numeric prefix and returns 0 for none at all.
    let digits = text.strip_prefix('-').unwrap_or(text);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        Ok(NumClass::Big)
    } else {
        Err(format!("unparseable integer text {text:?}"))
    }
}

/// A `Store#put` refused because one of the node's parent digests is absent
/// from the store -- the referential-integrity check at the public API
/// boundary. The message's family form (`no object <parent> in store`) matches
/// every other dangling-digest raise (see [`dag::DanglingDigest`]); the tail
/// names the refusal context. This `Display` IS the FFI-visible message,
/// byte-identical to the deleted Ruby `Store#validate_parents!`'s for plain
/// digests -- `{:?}` on a [`crate::digest::Digest`] renders as Ruby's
/// `String#inspect` does, the same contract `DanglingDigest` documents.
///
/// Prevention here is what makes the pure `dag.rs` walk arms unreachable via
/// the public API; they stay loud regardless (their cargo tests hand-corrupt
/// a StoreMap directly), same philosophy as `classify_num`'s garbage arm.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DanglingPut {
    parent: crate::digest::Digest,
    child: crate::digest::Digest,
    noun: &'static str,
}

impl std::fmt::Display for DanglingPut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "no {} {:?} in store: putting {:?} would dangle",
            self.noun, self.parent, self.child
        )
    }
}

impl std::error::Error for DanglingPut {}

/// A put refused because the object's claimed address is not the one its
/// content hashes to. Raised as `Store::DigestMismatch`. For a canonical
/// value whose tree holds a float the check is circular -- the float's text is
/// the one Ruby rendered -- so the conformance corpus (`ext/lain/corpus`), not
/// this, pins floats.
#[derive(Debug, Clone, PartialEq, Eq)]
struct DigestMismatch {
    claimed: crate::digest::Digest,
    actual: crate::digest::Digest,
}

impl std::fmt::Display for DigestMismatch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "object claims {:?} but its content addresses {:?}",
            self.claimed, self.actual
        )
    }
}

impl std::error::Error for DigestMismatch {}

/// `node`, unless the address its owner claimed differs from the one its
/// content hashes to here.
fn verified(
    node: dag::NodeData,
    claimed: crate::digest::Digest,
) -> Result<dag::NodeData, DigestMismatch> {
    if *node.digest() == claimed {
        Ok(node)
    } else {
        Err(DigestMismatch {
            claimed,
            actual: node.digest().clone(),
        })
    }
}

/// Why a `put` was refused. A dangling edge is `Store::MissingObject`, in the
/// deleted Ruby store's words; an envelope whose payload edge names something
/// other than its own payload is `Store::DigestMismatch`, a check that store
/// never made because a Ruby envelope never needed its body attached.
#[derive(Debug, Clone, PartialEq, Eq)]
enum PutRefusal {
    Dangling(DanglingPut),
    NotItsPayload {
        payload: crate::digest::Digest,
        child: crate::digest::Digest,
    },
}

impl std::fmt::Display for PutRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PutRefusal::Dangling(dangling) => dangling.fmt(f),
            PutRefusal::NotItsPayload { payload, child } => write!(
                f,
                "object {payload:?} in store is not the payload {child:?} addresses"
            ),
        }
    }
}

impl std::error::Error for PutRefusal {}

/// Whether `node` may enter `objects` at the public `put` boundary: every edge
/// [`dag::NodeData::edges`] names must already be present, in the map its arm
/// names. An edge held by neither map is `no object`, in the deleted Ruby
/// store's words; one held only by the other map is `no event` or `no member`, a
/// refusal that store's single map could not make, and without it a walk would
/// later raise over a digest `key?` says is there. The refusal names the FIRST
/// dangling edge, in the order the Ruby `Store#parent_edges` checked: render
/// parent, payload, then the causal set
/// in its pinned sorted order. Plain Rust over the locked objects -- the
/// caller holds the Store's lock across this check AND the insert, so a
/// concurrent put cannot race in between.
///
/// Every writer passes through here, `Timeline::commit` included. Its render
/// edge is the committing Timeline's own already-validated head, so that arm
/// is a formality -- but its causal parents are digests the CALLER supplies,
/// naming any object at all, so the node as a whole is not inductively safe
/// and this is the check that says so. The deleted Ruby reached the same guard
/// by committing through its `Store#put`.
fn validate_put(objects: &dag::Objects, node: &dag::NodeData) -> Result<(), DanglingPut> {
    match node
        .edges()
        .into_iter()
        .find(|(edge, arm)| !objects.holds(edge, *arm))
    {
        Some((edge, arm)) => Err(DanglingPut {
            parent: edge.clone(),
            child: node.digest().clone(),
            noun: if objects.contains(edge) {
                arm.noun()
            } else {
                "object"
            },
        }),
        None => Ok(()),
    }
}

/// `node` as the store keeps it: an envelope always carries its payload once
/// stored, so every walk can hand back a readable event. A detached envelope
/// takes the payload its edge names, which `validate_put` has already found.
fn carrying(objects: &dag::Objects, node: &dag::NodeData) -> Result<dag::NodeData, PutRefusal> {
    match node {
        dag::NodeData::Event(event) if event.payload.is_none() => objects
            .payload(&event.payload_digest)
            .and_then(|payload| event.attach(payload))
            .map(dag::NodeData::Event)
            .ok_or_else(|| PutRefusal::NotItsPayload {
                payload: event.payload_digest.clone(),
                child: event.digest.clone(),
            }),
        other => Ok(other.clone()),
    }
}

/// The whole `put` decision, as a pure function of the objects: validate,
/// insert if absent, and answer the address either way. Returns the objects
/// that result, never mutating the caller's -- `rpds` maps, so the unchanged
/// return is two `Arc` bumps, not a copy.
///
/// **Idempotent**, and that is a law, not an implementation detail: the address
/// IS the content, so a second put of the same node cannot mean anything
/// different from the first. Proven in `cargo test` (`put_tests`, this file)
/// against this function; that the Ruby-facing binding obeys the same law is
/// the separate business of the shared "a content-addressed store" group
/// (`spec/lain/rust/store_spec.rb`), and neither proof stands in for the other.
///
/// Split out of [`ffi::Store::insert`] so the law is provable with no `magnus`
/// in the signature and no embedded Ruby VM -- the same reason
/// `validate_put` is shaped this way. `Store::insert`
/// is then only the lock, held across this whole call so no concurrent write
/// can race between the check and the insert; its two callers, `Store::put`
/// and `Timeline::commit`, add only the error translation.
fn put_into(
    objects: &dag::Objects,
    node: &dag::NodeData,
) -> Result<(dag::Objects, crate::digest::Digest), PutRefusal> {
    let digest = node.digest().clone();
    // A digest already present skips validation: the store is append-only, so
    // its edges were checked when it first entered, and re-checking would
    // refuse a legitimate no-op whenever the caller's map has since changed.
    if objects.contains(&digest) {
        return Ok((objects.clone(), digest));
    }
    validate_put(objects, node).map_err(PutRefusal::Dangling)?;
    let kept = carrying(objects, node)?;
    Ok((objects.with(kept), digest))
}

/// Walk `count` render-parent edges back from `head`. `None` absorbs -- rewinding
/// past the root lands on the empty Timeline, exactly as the deleted Ruby
/// `Timeline#rewind` did -- while a digest that is present but absent from the
/// map is corruption and answers `Err`, kept distinct from a root.
///
/// Split out of [`ffi::Timeline::rewind`] for the reason `put_into` was split
/// out of `Store::put`, and for one more: the whole walk must run under ONE
/// lock (re-locking per step would let another thread's `commit` interleave
/// mid-rewind), and a pure function is what lets the caller hold that lock
/// across the walk and translate the failure into a Ruby exception only after
/// the guard has dropped. A `magnus::Error` built under a held guard means a
/// `const_get` -- Ruby code, which can raise and unwind through the guard --
/// inside the critical section.
///
/// **`digest.is_some()` is what bounds the walk by the CHAIN, not by the
/// caller's argument, and holding one lock across it is why that matters.**
/// `None` absorbs, so every step past the root is already a no-op -- but a bare
/// `remaining > 0` still spins through all of them, inside the critical section
/// and under the GVL, uninterruptible by any other thread. Measured at 2.06e9
/// steps/s, `rewind(2**62)` would hold the Store's mutex for roughly 71 years.
/// The extra condition costs one branch per step and makes the walk terminate at
/// the chain's length, which is the only number that was ever meaningful here.
fn rewind_to(
    map: &dag::StoreMap,
    head: Option<crate::digest::Digest>,
    count: i64,
) -> Result<Option<crate::digest::Digest>, dag::DanglingDigest> {
    let mut digest = head;
    let mut remaining = count;
    while remaining > 0 && digest.is_some() {
        digest = match digest {
            None => None,
            Some(current) => dag::parent_of(map, &current)?,
        };
        remaining -= 1;
    }
    Ok(digest)
}

// ---------------------------------------------------------------------------
// FFI surface.
//
// Everything below touches `magnus`/Ruby C symbols. It is compiled for the
// real cdylib build (`cargo build`) and checked by `cargo clippy`, but excluded
// from the unit-test binary (`cfg(test)`), which only exercises the pure Rust
// helpers above. This keeps `cargo test` from having to link libruby (this
// toolchain ships a static-only Ruby, and linking it into a test executable is
// both heavyweight and fragile), so plain `cargo test` needs no extra flags,
// dev-dependencies, or linker configuration.
// ---------------------------------------------------------------------------

#[cfg(not(test))]
mod ffi {
    use super::{NumClass, PutRefusal, blake3_hex, classify_num, put_into, verified};
    use crate::algebra::{
        CausalAncestry, Dominance, MaximalLowerBounds, MeetSemilattice, RenderAncestry,
    };
    use crate::canonical::{self, Canon};
    use crate::dag::{self, BlobData, CanonData, NodeData, StoreMap};
    use crate::digest::Digest;
    use crate::event::{EventData, InvalidKind, Kind, PayloadData, Role};
    use magnus::{
        DataTypeFunctions, Error, ExceptionClass, Fixnum, Float, Integer, RArray, RClass, RHash,
        RModule, RString, Ruby, Symbol, TryConvert, TypedData, Value, function, gc, method,
        prelude::*,
        r_hash::ForEach,
        scan_args::{get_kwargs, scan_args},
        typed_data::{self, Obj},
        value::{Opaque, Qfalse, Qtrue},
    };
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    /// `Lain::Canonical`'s content-addressing hash. Thin FFI wrapper over
    /// [`super::blake3_hex`]; the hashing itself is tested in `cargo test`
    /// without libruby, so this wrapper has nothing left to get wrong beyond
    /// reading the argument's bytes.
    ///
    /// Threads the argument's raw bytes rather than a UTF-8 `String`. blake3 is
    /// a function over bytes; typing the boundary as `String` would silently
    /// transcode (or reject) a future binary caller. `Canonical` passes a UTF-8
    /// JSON dump, so its bytes are unchanged.
    fn ffi_blake3_hex(bytes: RString) -> String {
        with_bytes(bytes, blake3_hex)
    }

    /// `read` over the String's raw bytes, whatever its encoding. The one
    /// borrow of a Ruby buffer here, shared by the hash and the blob reader, so
    /// its safety argument is made once. `read` must be plain Rust that never
    /// calls back into Ruby.
    fn with_bytes<R>(string: RString, read: impl FnOnce(&[u8]) -> R) -> R {
        // SAFETY: we do not call back into Ruby (which could move or free the
        // string) between borrowing the slice and `read` returning.
        read(unsafe { string.as_slice() })
    }

    /// Look up `name` as a constant of `scope`, which may be a Module or a
    /// Class -- `Lain`/`Ext`/`Canonical` are modules, `Store`/`Bm25`/`Turn`/
    /// `Timeline` are classes, and a `lookup_error` path interleaves both as
    /// it walks down. `RModule::const_get` and `RClass::const_get` do the
    /// identical lookup (Ruby's own `Module#const_get`, which `Class`
    /// inherits); this just picks whichever the value actually is, since a
    /// `TryConvert` to the wrong one of the two rejects the other's runtime
    /// type outright.
    fn scoped_const_get(ruby: &Ruby, scope: Value, name: &str) -> Result<Value, Error> {
        if let Some(module) = RModule::from_value(scope) {
            module.const_get(name)
        } else if let Some(class) = RClass::from_value(scope) {
            class.const_get(name)
        } else {
            Err(Error::new(
                ruby.exception_type_error(),
                // SAFETY: classname reads the object's class name; no Ruby
                // code runs meanwhile.
                format!("no implicit conversion of {} into Module", unsafe {
                    scope.classname()
                }),
            ))
        }
    }

    /// `Lain::Ext::Probe.live_bytes`: the Rust heap allocated right now (see
    /// `crate::heap`).
    fn live_bytes() -> usize {
        crate::heap::LIVE_BYTES.load(Ordering::Relaxed)
    }

    /// Build the exception named by `path` (a full constant path starting at
    /// `Lain`, e.g. `["Lain", "Canonical", "AmbiguousKey"]` or `["Lain", "Ext",
    /// "Store", "MissingObject"]`) with `message`. Looked up at raise-time
    /// (not ext-init) because the Ruby-side classes are defined after this
    /// extension loads; a lookup failure surfaces as the underlying
    /// `NameError`/`TypeError` rather than being swallowed.
    ///
    /// Absorbs what were two near-identical functions, `canonical_error`
    /// (`Lain::Canonical::<name>`, a two-segment walk after the root) and
    /// `ext_error` (`Lain::Ext::<class>::<error>`, three segments) -- they
    /// differed only in path depth, and every real caller is one of exactly
    /// those two shapes.
    ///
    /// The exception is built here, not by magnus at raise time, because both
    /// steps can run Ruby -- the lookup an autoload or a `const_missing`, the
    /// build the class's `#initialize` -- and a fiber dropped inside either
    /// would strand any Rust state alive across it. So `message` is rendered
    /// into a Ruby String first, and it is `'static` so it owns what it
    /// renders: whatever it captured is dropped with it, before either step. A
    /// caller must not hold Rust state of its own across this call either.
    pub(crate) fn lookup_error(
        ruby: &Ruby,
        path: &[&str],
        message: impl FnOnce() -> String + 'static,
    ) -> Error {
        let text = ruby.str_new(&message());
        let (last, init) = path
            .split_last()
            .expect("lookup_error path must be non-empty");
        let scope = init
            .iter()
            .try_fold(ruby.class_object().as_value(), |scope, segment| {
                scoped_const_get(ruby, scope, segment)
            });
        let looked = scope
            .and_then(|scope| scoped_const_get(ruby, scope, last))
            .and_then(ExceptionClass::try_convert);
        match looked {
            Ok(class) => class
                .new_instance((text,))
                .map_or_else(|failed| failed, Error::from),
            Err(lookup_failure) => lookup_failure,
        }
    }

    /// Read a Ruby value into a [`Canon`], applying `Canonical.normalize`'s rules
    /// and raising the matching `Lain::Canonical` error on anything JSON cannot
    /// represent. Numbers keep the text Ruby renders (see `canonical.rs`): an
    /// Integer as `#to_s` renders it, a Float via `JSON.generate`, so the bytes
    /// match Ruby's exactly even where Rust's float formatting would diverge.
    fn ruby_to_canon(ruby: &Ruby, value: Value) -> Result<Canon, Error> {
        let [canon] = ruby_to_canons(ruby, [value])?;
        Ok(canon)
    }

    /// [`ruby_to_canon`] over several values into one [`Reading`], so a tree
    /// already read waits there, not on this frame, while the next one calls
    /// into Ruby.
    fn ruby_to_canons<const N: usize>(
        ruby: &Ruby,
        values: [Value; N],
    ) -> Result<[Canon; N], Error> {
        let reading = Reading::start(ruby);
        let read = values
            .into_iter()
            .try_for_each(|value| read_canon(ruby, value, 0, &reading));
        let trees = reading.finish();
        // Keeps `reading` in this frame's memory, where the collector scans
        // it, until the conversion is done with it.
        std::hint::black_box(reading.as_value());
        read?;
        <[Canon; N]>::try_from(trees).map_err(|_| {
            Error::new(
                ruby.exception_runtime_error(),
                "Lain::Ext: a canonical reading finished with the wrong number of trees",
            )
        })
    }

    /// What a canonical conversion has built so far. A conversion calls into
    /// Ruby midway (`JSON.generate` on a Float, `#to_s` on a Symbol or a
    /// Bignum), and a fiber dropped while suspended there is never unwound, so
    /// the partial tree lives in an object the collector frees with the fiber.
    /// Holds no Ruby reference, so it needs no `mark`.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Reading", free_immediately)]
    struct Reading {
        /// Every finished value, innermost last: a container takes its own
        /// back off the end.
        values: RefCell<Vec<Canon>>,
        /// The keys of every Hash still being read, in the same order.
        keys: RefCell<Vec<String>>,
    }

    impl DataTypeFunctions for Reading {}

    impl Reading {
        fn start(ruby: &Ruby) -> Obj<Reading> {
            ruby.obj_wrap(Reading {
                values: RefCell::new(Vec::new()),
                keys: RefCell::new(Vec::new()),
            })
        }

        fn push(&self, canon: Canon) {
            self.values.borrow_mut().push(canon);
        }

        fn push_key(&self, key: String) {
            self.keys.borrow_mut().push(key);
        }

        fn mark(&self) -> (usize, usize) {
            (self.values.borrow().len(), self.keys.borrow().len())
        }

        fn values_since(&self, mark: (usize, usize)) -> Vec<Canon> {
            self.values.borrow_mut().split_off(mark.0)
        }

        fn pairs_since(&self, mark: (usize, usize)) -> Vec<(String, Canon)> {
            let keys = self.keys.borrow_mut().split_off(mark.1);
            keys.into_iter().zip(self.values_since(mark)).collect()
        }

        /// Everything read, emptying the holder whether or not the read
        /// succeeded, so only an abandoned reading outlives its call.
        fn finish(&self) -> Vec<Canon> {
            self.keys.borrow_mut().clear();
            std::mem::take(&mut *self.values.borrow_mut())
        }
    }

    /// The recursive half of [`ruby_to_canon`], pushing exactly one value onto
    /// `reading`. `depth` counts the containers already entered, so the
    /// top-level value is read at 0 and every Array or Hash costs one level --
    /// see [`super::MAX_CANON_DEPTH`] for why the count is bounded at all and
    /// why the bound is Ruby's own.
    ///
    /// `true` and `false` are matched by identity, as `Canonical.normalize`'s
    /// `when` matches them, so a value's own `#==` is never asked.
    fn read_canon(ruby: &Ruby, value: Value, depth: usize, reading: &Reading) -> Result<(), Error> {
        let canon = if value.is_nil() {
            Canon::Null
        } else if Qtrue::from_value(value).is_some() {
            Canon::Bool(true)
        } else if Qfalse::from_value(value).is_some() {
            Canon::Bool(false)
        } else if let Some(integer) = Integer::from_value(value) {
            Canon::Num(integer_text(integer)?)
        } else if let Some(float) = Float::from_value(value) {
            canon_float(ruby, float, value)?
        } else if let Some(text) = coerce_text(ruby, value)? {
            Canon::Str(text)
        } else if let Some(array) = RArray::from_value(value) {
            let inner = enter_container(ruby, depth)?;
            let mark = reading.mark();
            array
                .into_iter()
                .try_for_each(|element| read_canon(ruby, element, inner, reading))?;
            Canon::Array(reading.values_since(mark))
        } else if let Some(hash) = RHash::from_value(value) {
            canon_hash(ruby, hash, enter_container(ruby, depth)?, reading)?
        } else {
            // SAFETY: classname reads the object's class name; no Ruby code runs
            // meanwhile.
            let class = unsafe { value.classname() }.into_owned();
            return Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "UnsupportedType"],
                move || format!("cannot canonicalize {class}"),
            ));
        };
        reading.push(canon);
        Ok(())
    }

    /// An Integer's decimal text. A Fixnum is formatted here, as `#to_s` would;
    /// only a Bignum still asks Ruby.
    fn integer_text(integer: Integer) -> Result<String, Error> {
        match Fixnum::from_value(integer.as_value()) {
            Some(fixnum) => Ok(fixnum.to_i64().to_string()),
            None => integer.funcall("to_s", ()),
        }
    }

    fn canon_float(ruby: &Ruby, float: Float, value: Value) -> Result<Canon, Error> {
        // JSON has no NaN/Infinity; a hash over one would not round-trip. Checked
        // before rendering so the error is `NonFiniteFloat`, not JSON's own.
        if !float.to_f64().is_finite() {
            return Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "NonFiniteFloat"],
                move || super::non_finite(float.to_f64()),
            ));
        }
        let json = ruby.class_object().const_get::<_, RModule>("JSON")?;
        Ok(Canon::Num(json.funcall("generate", (value,))?))
    }

    /// One level deeper, or the refusal [`super::descend`] worded. Raised as
    /// `Lain::Canonical::UnsupportedType`: the value genuinely cannot be
    /// canonicalized, it is the class every other "JSON cannot represent this"
    /// refusal in this reader uses, and it is a `Lain::Error` a caller can
    /// rescue (`Lain::Canonical` defines no `Error` of its own, so
    /// `UnsupportedType < Error` resolves lexically to `Lain::Error`).
    ///
    /// Ruby's own limit surfaces instead as the JSON gem's `JSON::NestingError`,
    /// whose text is the gem's to change -- so the two implementations refuse
    /// the same SET of structures but not with the same class hierarchy, and
    /// `rescue Lain::Error` sees only this one. Closing that is a `Canonical`
    /// change, tracked outside this crate.
    fn enter_container(ruby: &Ruby, depth: usize) -> Result<usize, Error> {
        super::descend(depth).map_err(|too_deep| {
            lookup_error(ruby, &["Lain", "Canonical", "UnsupportedType"], || too_deep)
        })
    }

    fn canon_hash(
        ruby: &Ruby,
        hash: RHash,
        depth: usize,
        reading: &Reading,
    ) -> Result<Canon, Error> {
        let mark = reading.mark();
        hash.foreach(|key: Value, val: Value| {
            reading.push_key(canon_key(ruby, key)?);
            read_canon(ruby, val, depth, reading)?;
            Ok(ForEach::Continue)
        })?;
        let object = canonical::build_object(reading.pairs_since(mark)).map_err(|ambiguous| {
            lookup_error(ruby, &["Lain", "Canonical", "AmbiguousKey"], move || {
                ambiguous.message()
            })
        })?;
        Ok(Canon::Object(object))
    }

    fn canon_key(ruby: &Ruby, key: Value) -> Result<String, Error> {
        if let Some(text) = coerce_text(ruby, key)? {
            Ok(text)
        } else {
            // SAFETY: see `ruby_to_canon`.
            let class = unsafe { key.classname() }.into_owned();
            Err(lookup_error(
                ruby,
                &["Lain", "Canonical", "UnsupportedType"],
                move || format!("hash keys must be String or Symbol, got {class}"),
            ))
        }
    }

    /// A validated UTF-8 `String`, transcoding from the string's own encoding
    /// exactly as `Canonical#utf8` does: `RString::to_string` takes the valid
    /// UTF-8 fast path or `rb_str_conv_enc`, and errors on bytes that are not
    /// convertible -- which is precisely when Ruby raises.
    fn validated_utf8(ruby: &Ruby, string: RString) -> Result<String, Error> {
        utf8(string).map_err(|refusal| refusal.raise(ruby))
    }

    /// [`validated_utf8`], with its refusal not yet raised.
    fn utf8(string: RString) -> Result<String, Refusal> {
        string.to_string().map_err(|_| {
            Refusal::Named(
                &["Lain", "Canonical", "UnsupportedType"],
                "string is not valid UTF-8".to_string(),
            )
        })
    }

    /// A refusal whose exception is not built yet. Building one can run Ruby
    /// (see [`lookup_error`]), so a call that owns Rust state carries its
    /// refusal out as one of these, lets the state drop, and only then raises.
    enum Refusal {
        /// A `Lain` exception, by constant path, and its message.
        Named(&'static [&'static str], String),
        /// An exception magnus already holds, which runs no Ruby until it is
        /// raised at the boundary.
        Built(Error),
    }

    impl From<Error> for Refusal {
        fn from(error: Error) -> Self {
            Refusal::Built(error)
        }
    }

    impl Refusal {
        fn missing(dangling: impl std::fmt::Display) -> Self {
            Refusal::Named(
                &["Lain", "Ext", "Store", "MissingObject"],
                dangling.to_string(),
            )
        }

        fn raise(self, ruby: &Ruby) -> Error {
            match self {
                Refusal::Named(path, message) => lookup_error(ruby, path, move || message),
                Refusal::Built(error) => error,
            }
        }
    }

    /// A String or Symbol coerced to a validated UTF-8 `String`, or `None` when
    /// the value is neither. Both branches -- a String's own bytes, a Symbol via
    /// `#to_s` -- are identical across `ruby_to_canon`, `canon_key`, and
    /// `read_role`; each caller supplies its own error for the `None` case.
    fn coerce_text(ruby: &Ruby, value: Value) -> Result<Option<String>, Error> {
        text_value(value)?
            .map(|text| validated_utf8(ruby, text))
            .transpose()
    }

    /// The Ruby half of [`coerce_text`]: a String as itself, a Symbol as its
    /// `#to_s`. Apart so a call reading several texts can take each from Ruby
    /// before it builds any Rust state: a fiber dropped inside `#to_s` is
    /// never unwound, so Rust state alive across it would be stranded.
    fn text_value(value: Value) -> Result<Option<RString>, Error> {
        if let Some(string) = RString::from_value(value) {
            Ok(Some(string))
        } else if let Some(symbol) = Symbol::from_value(value) {
            symbol.funcall("to_s", ()).map(Some)
        } else {
            Ok(None)
        }
    }

    /// `Lain::Ext.canonical_dump` -- the byte-identical twin of `Canonical.dump`,
    /// driving the shared `canonical determinism` group against this impl.
    fn canonical_dump(ruby: &Ruby, value: Value) -> Result<String, Error> {
        Ok(canonical::dump(&ruby_to_canon(ruby, value)?))
    }

    /// `Lain::Ext.canonical_digest` -- `"blake3:" + hex`, equal to
    /// `Canonical.digest` byte-for-byte. This is the entry the Rust `Turn` will
    /// hash through, and the one the digest-equality spec pins to Ruby.
    fn canonical_digest(ruby: &Ruby, value: Value) -> Result<String, Error> {
        Ok(canonical::digest(&ruby_to_canon(ruby, value)?))
    }

    // -----------------------------------------------------------------------
    // Turn / Store / Timeline: the content-addressed DAG.
    //
    // FFI-boundary decision: a Turn, a Store, and a Timeline each cross as an
    // OPAQUE HANDLE, never a serialized copy, and every DAG walk runs ENTIRELY
    // in Rust against the Store's `rpds` map. A method returns either a scalar,
    // one fresh handle, or a single Ruby Array built in one pass -- never one
    // FFI call per node, which is where a naive binding loses to plain Ruby.
    // `Turn` holds only immutable Rust state (an `Arc<EventData>`: no reachable
    // Ruby object), so `frozen_shareable` is honest once the handle is frozen.
    // `Timeline` is the one handle that references a Ruby object (its `Store`),
    // so it marks that reference and is deliberately NOT frozen_shareable --
    // exactly as the deleted Ruby `Timeline`, a frozen value over a mutable
    // Store, was itself not `Ractor.shareable?`.
    // -----------------------------------------------------------------------

    /// Map a pure-layer dangling-edge refusal onto
    /// `Lain::Ext::Store::MissingObject`. Two structs reach here and each one's
    /// `Display` IS the Ruby-visible message: [`dag::DanglingDigest`], byte-equal
    /// to the deleted Ruby `Store#fetch`'s (`ext/lain/corpus/errors.ndjson`), so a
    /// corrupt chain raises the same class and the same message from every walk;
    /// and [`super::DanglingPut`], byte-equal to the deleted Ruby
    /// `Store#validate_parents!`'s, so a write refused for a dangling edge
    /// reads the same whether it arrived through `Store#put` or `Timeline#commit`.
    /// Taking `impl Display` rather than one concrete type is what keeps those
    /// two messages built at one site instead of two.
    ///
    /// **Never call this -- or anything else that reaches Ruby -- while a
    /// `Store` guard is held.** It ends in `const_get`, which runs Ruby code:
    /// that can raise (unwinding through a live `MutexGuard`, which is how a
    /// mutex gets left in a state no Rust code chose), allocate, and trigger GC
    /// with the store's own lock held. Every walk in this module therefore has
    /// the same three-step shape -- compute a pure `Result` under the guard, let
    /// the guard drop, then translate -- and the walks that read a single node
    /// (`Store::fetch`, `Timeline::head`) bind the `Option` to a `let` for
    /// exactly that reason, since a temporary guard in a `?`-terminated
    /// expression lives to the end of the whole statement.
    fn missing_object(ruby: &Ruby, dangling: impl std::fmt::Display) -> Error {
        Refusal::missing(dangling).raise(ruby)
    }

    /// The `&Store` a `Timeline` names. Collapses the `store_ref(...)` call at
    /// every DAG-walking `Timeline` method into one named site.
    ///
    /// The lifetime is tied to the `&'a Timeline`, not left free, and that is
    /// the whole point of the signature. `TryConvert` hands back a reference
    /// into a Ruby object with an UNBOUNDED lifetime -- it will unify with
    /// whatever the call site asks for, `'static` included -- so the borrow is
    /// checked against nothing. Naming `'a` narrows it to the Timeline the
    /// store was reached through, which is the object whose `mark` roots that
    /// store `Value` in the first place.
    ///
    /// It narrows the claim rather than proving it: the `&Timeline` is itself
    /// derived from a `Value`, so what keeps the `Store` alive is still `mark`
    /// plus Ruby's conservative stack scanning, not the borrow checker. The
    /// signature makes a `&Store` outliving its Timeline unwritable; it does
    /// not make GC reachability a compile-time fact.
    fn store_ref<'a>(ruby: &Ruby, timeline: &'a Timeline) -> Result<&'a Store, Error> {
        TryConvert::try_convert(timeline.store_value(ruby))
    }

    /// A frozen Ruby String. Digests, roles, and reconstructed content strings
    /// are all frozen so a reconstructed `content`/`meta` tree is deeply
    /// immutable, as the deleted Ruby `Turn` was. Shared with the `astgrep`/`treesitter`
    /// bindings, whose per-call result Hashes are frozen the same way -- this is
    /// generic Ruby-value glue, not `Turn`-specific, so it lives here once.
    pub(crate) fn frozen_str(ruby: &Ruby, text: &str) -> Value {
        let string = ruby.str_new(text);
        string.freeze();
        string.as_value()
    }

    /// A Ruby Integer from a `usize`. Byte offsets and line/column numbers of an
    /// in-memory source string fit i64. Shared with the structural bindings.
    pub(crate) fn int(ruby: &Ruby, n: usize) -> Value {
        ruby.integer_from_i64(n as i64).as_value()
    }

    /// Rebuild a Ruby value from a [`Canon`], deeply frozen. Called on demand
    /// (e.g. `turn.content`), so the `Turn` handle itself never has to hold a
    /// Ruby reference -- which is what keeps it trivially `Ractor.shareable?`.
    /// Fallible only because [`num_to_ruby`] is: a `Canon::Num` this crate
    /// itself never wrote would otherwise be the sole silent corner of an
    /// FFI surface that is loud everywhere else.
    fn canon_to_ruby(ruby: &Ruby, canon: &Canon) -> Result<Value, Error> {
        Ok(match canon {
            Canon::Null => ruby.qnil().as_value(),
            Canon::Bool(true) => ruby.qtrue().as_value(),
            Canon::Bool(false) => ruby.qfalse().as_value(),
            Canon::Num(text) => num_to_ruby(ruby, text)?,
            Canon::Str(text) => frozen_str(ruby, text),
            Canon::Array(items) => {
                let array = ruby.ary_new_capa(items.len());
                for item in items {
                    array.push(canon_to_ruby(ruby, item)?)?;
                }
                array.freeze();
                array.as_value()
            }
            Canon::Object(pairs) => {
                let hash = ruby.hash_new();
                for (key, value) in pairs {
                    hash.aset(frozen_str(ruby, key), canon_to_ruby(ruby, value)?)?;
                }
                hash.freeze();
                hash.as_value()
            }
        })
    }

    /// Rebuild the Ruby number a [`Canon::Num`] text denotes, via the pure
    /// [`classify_num`] (cargo-tested without an embedded Ruby VM). A JSON
    /// float always carries `.`, `e`, or `E`; an integer never does -- so the
    /// text alone says which. Bignums round-trip through Ruby's own parser to
    /// keep arbitrary precision. `classify_num`'s `Err` arm is unreachable for
    /// text this crate produced itself (see `canonical.rs`'s `Canon::Num`
    /// docs) -- exactly why reaching it here must raise loudly rather than
    /// materialize `NaN` or `nil`.
    fn num_to_ruby(ruby: &Ruby, text: &str) -> Result<Value, Error> {
        match classify_num(text) {
            Ok(NumClass::Float(f)) => Ok(ruby.float_from_f64(f).as_value()),
            Ok(NumClass::Small(i)) => Ok(ruby.integer_from_i64(i).as_value()),
            Ok(NumClass::Big) => ruby.str_new(text).funcall("to_i", ()),
            Err(reason) => Err(Error::new(
                ruby.exception_runtime_error(),
                format!(
                    "Lain::Ext: {reason} -- Canon::Num text must be reader-produced, \
                     never handed to the FFI boundary unparsed"
                ),
            )),
        }
    }

    /// Read a role argument (String or Symbol) and validate it into a [`Role`],
    /// raising `Event::InvalidRole` on anything that is not a wire role.
    fn read_role(ruby: &Ruby, value: Value) -> Result<Role, Error> {
        let raw = match coerce_text(ruby, value)? {
            Some(text) => text,
            None => {
                // SAFETY: see ruby_to_canon.
                let class = unsafe { value.classname() }.into_owned();
                return Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Event", "InvalidRole"],
                    move || format!("role must be one of {}, got a {class}", Role::names()),
                ));
            }
        };
        // `InvalidRole`'s `Display` (see `turn.rs`) IS this message; no
        // hand-built duplicate to keep in sync with the pure error type.
        let parsed = raw.parse::<Role>();
        drop(raw);
        parsed.map_err(|invalid| {
            lookup_error(ruby, &["Lain", "Ext", "Event", "InvalidRole"], move || {
                invalid.to_string()
            })
        })
    }

    /// Read a kind argument (String or Symbol) into a [`Kind`], raising
    /// `Lain::Error` with Ruby's message, offender quoted as Ruby would.
    fn read_kind(ruby: &Ruby, value: Value) -> Result<Kind, Error> {
        type Read = fn(&Ruby, RString) -> Result<String, Error>;
        let (source, read): (RString, Read) = match text_value(value)? {
            Some(text) => (text, validated_utf8),
            None => (value.funcall("to_s", ())?, |_, text| text.to_string()),
        };
        if let Ok(kind) = read(ruby, source)?.parse::<Kind>() {
            return Ok(kind);
        }
        // `#inspect` is Ruby, so the refusal's text is read only once it returns.
        let inspected = value.funcall::<_, _, RString>("inspect", ());
        let offender = read(ruby, source).unwrap_or_default();
        let got = inspected
            .and_then(|inspected| inspected.to_string())
            .unwrap_or_else(|_| offender.clone());
        Err(lookup_error(ruby, &["Lain", "Error"], move || {
            InvalidKind(offender).message(&got)
        }))
    }

    /// A parent/head digest argument: `nil` (or absent) is a root/empty head, a
    /// String is a digest, anything else is a type error. This is the FFI-in
    /// boundary where a Ruby String becomes a [`Digest`].
    fn read_optional_digest(ruby: &Ruby, value: Option<Value>) -> Result<Option<Digest>, Refusal> {
        match value {
            None => Ok(None),
            Some(inner) if inner.is_nil() => Ok(None),
            Some(inner) => {
                let string = RString::from_value(inner).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "digest must be a String or nil",
                    )
                })?;
                Ok(Some(utf8(string)?.into()))
            }
        }
    }

    /// A meta argument, defaulting to `{}` when absent or nil.
    fn meta_or_empty(ruby: &Ruby, value: Option<Value>) -> Value {
        value
            .filter(|inner| !inner.is_nil())
            .unwrap_or_else(|| ruby.hash_new().as_value())
    }

    /// A causal_parents argument: ABSENT is the empty set, otherwise an Array
    /// whose every element is a digest String. Normalization (dedup, pinned
    /// sort order) happens in the pure layer, not here.
    ///
    /// **An explicit `nil` is refused, unlike `meta_or_empty` and
    /// `read_optional_digest` above.** The difference is what a nil MEANS at
    /// each site: a nil parent digest is a root and a nil meta is an empty
    /// table, both of them values this domain has a name for -- while a nil
    /// causal set is a caller who believes they are naming something. Reading
    /// it as "no causal parents" is a silent coercion, and it accepted input
    /// the deleted Ruby Timeline refused outright. Absent and nil are distinguished by
    /// matching `None` separately rather than by an `is_nil` guard, so a nil
    /// falls through to `RArray::from_value` and is refused as the non-Array it
    /// is, in the same message any other non-Array gets.
    fn optional_text_arg(ruby: &Ruby, value: Option<Value>) -> Result<Option<RString>, Error> {
        match value {
            Some(value) if !value.is_nil() => match text_value(value)? {
                Some(text) => Ok(Some(text)),
                None => Err(Error::new(
                    ruby.exception_type_error(),
                    "from and to must be a String, Symbol or nil",
                )),
            },
            _ => Ok(None),
        }
    }

    /// Apart from [`optional_text_arg`] so a caller can finish every Ruby call
    /// before the first Rust String exists.
    fn optional_utf8(text: Option<RString>) -> Result<Option<String>, Refusal> {
        text.map(utf8).transpose()
    }

    fn read_causal_parents(ruby: &Ruby, value: Option<Value>) -> Result<Vec<Digest>, Refusal> {
        match value {
            None => Ok(Vec::new()),
            Some(inner) => {
                let array = RArray::from_value(inner).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "causal_parents must be an Array of digest Strings",
                    )
                })?;
                array
                    .into_iter()
                    .map(|element| {
                        let string = RString::from_value(element).ok_or_else(|| {
                            Error::new(
                                ruby.exception_type_error(),
                                "causal_parents must contain only digest Strings",
                            )
                        })?;
                        Ok(Digest::from(utf8(string)?))
                    })
                    .collect()
            }
        }
    }

    /// A frozen node of the Timeline DAG, wearing the full Event envelope
    /// (T25's re-port: kind, both parent edges, correlation, and the carried,
    /// content-addressed payload). Holds only an `Arc<EventData>` -- pure
    /// immutable Rust, no Ruby reference -- so once frozen it is honestly
    /// `Ractor.shareable?` with no `mark` and no reachable mutable state.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Event", free_immediately, frozen_shareable)]
    struct Turn {
        inner: Arc<EventData>,
    }

    impl DataTypeFunctions for Turn {}

    impl PartialEq for Turn {
        fn eq(&self, other: &Self) -> bool {
            self.inner.digest == other.inner.digest
        }
    }

    impl Eq for Turn {}

    impl std::hash::Hash for Turn {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.inner.digest.hash(state);
        }
    }

    impl Turn {
        fn wrap(ruby: &Ruby, inner: Arc<EventData>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Turn { inner });
            obj.freeze();
            obj
        }

        fn new(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            if kw.get(ruby.to_symbol("kind")).is_some() {
                return Self::new_event(ruby, kw);
            }
            Self::new_turn(ruby, kw)
        }

        /// The kind-general constructor, mirroring the deleted Ruby `Event.new`. A
        /// payload_digest with no body builds a DETACHED envelope, whose body
        /// readers refuse.
        fn new_event(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            type OptionalArgs = (
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
            );
            let args = get_kwargs::<_, (Value,), OptionalArgs, ()>(
                kw,
                &["kind"],
                &[
                    "payload_digest",
                    "body",
                    "carried_payload",
                    "from",
                    "to",
                    "render_parent",
                    "causal_parents",
                    "correlation",
                ],
            )?;
            let (kind_value,) = args.required;
            let (
                digest_value,
                body_value,
                carried_value,
                from_value,
                to_value,
                parent_value,
                causal_value,
                correlation_value,
            ) = args.optional;
            let kind = read_kind(ruby, kind_value)?;
            let from = optional_text_arg(ruby, from_value)?;
            let to = optional_text_arg(ruby, to_value)?;
            let payload = Self::read_payload(ruby, kind, digest_value, body_value, carried_value)?;
            // The payload is Rust state, so every later refusal waits until it drops.
            let built = move || -> Result<Arc<EventData>, Refusal> {
                let from = optional_utf8(from)?;
                let to = optional_utf8(to)?;
                let render_parent = read_optional_digest(ruby, parent_value)?;
                let causal_parents = read_causal_parents(ruby, causal_value)?;
                let correlation = read_optional_digest(ruby, correlation_value)?;
                Ok(match payload {
                    Ok(payload) => EventData::new(
                        from,
                        to,
                        render_parent,
                        causal_parents,
                        correlation,
                        payload,
                    ),
                    Err(payload_digest) => EventData::detached(
                        kind,
                        from,
                        to,
                        render_parent,
                        causal_parents,
                        correlation,
                        payload_digest,
                    ),
                })
            };
            let inner = built().map_err(|refusal| refusal.raise(ruby))?;
            Ok(Turn::wrap(ruby, inner))
        }

        /// The payload to carry, or `Err` with the digest alone when only a
        /// digest was passed: the detached case.
        fn read_payload(
            ruby: &Ruby,
            kind: Kind,
            digest: Option<Value>,
            body: Option<Value>,
            carried: Option<Value>,
        ) -> Result<Result<Arc<PayloadData>, Digest>, Error> {
            let present = |value: Option<Value>| value.filter(|inner| !inner.is_nil());
            let argument_error =
                |message: &str| Error::new(ruby.exception_arg_error(), message.to_string());
            match (present(carried), present(digest), present(body)) {
                (Some(_), Some(_), _) | (Some(_), _, Some(_)) => Err(argument_error(
                    "carried_payload already names the digest and body; pass one, not both",
                )),
                (Some(carried), None, None) => {
                    let payload = Obj::<Payload>::try_convert(carried)?;
                    if payload.inner.kind == kind {
                        Ok(Ok(Arc::clone(&payload.inner)))
                    } else {
                        Err(argument_error(
                            "carried_payload's kind must match the event's kind",
                        ))
                    }
                }
                (None, passed, Some(body)) => {
                    let payload = PayloadData::new(kind, ruby_to_canon(ruby, body)?);
                    match read_optional_digest(ruby, passed) {
                        Err(refusal) => {
                            drop(payload);
                            Err(refusal.raise(ruby))
                        }
                        Ok(Some(named)) if named != payload.digest => {
                            Err(argument_error(&format!(
                                "payload_digest {} disagrees with the body's digest {}",
                                named.as_str(),
                                payload.digest.as_str()
                            )))
                        }
                        Ok(_) => Ok(Ok(payload)),
                    }
                }
                (None, Some(digest), None) => match read_optional_digest(ruby, Some(digest))
                    .map_err(|refusal| refusal.raise(ruby))?
                {
                    Some(digest) => Ok(Err(digest)),
                    None => Err(argument_error(
                        "an Event needs its payload: pass payload_digest or carried_payload",
                    )),
                },
                (None, None, None) => Err(argument_error(
                    "an Event needs its payload: pass payload_digest or carried_payload",
                )),
            }
        }

        fn new_turn(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            type OptionalArgs = (
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
                Option<Value>,
            );
            let args = get_kwargs::<_, (Value, Value), OptionalArgs, ()>(
                kw,
                &["role", "content"],
                &[
                    "parent",
                    "meta",
                    "correlation",
                    "causal_parents",
                    "from",
                    "to",
                ],
            )?;
            let (role_value, content_value) = args.required;
            let (parent_value, meta_value, correlation_value, causal_value, from_value, to_value) =
                args.optional;
            let role = read_role(ruby, role_value)?;
            let from = optional_text_arg(ruby, from_value)?;
            let to = optional_text_arg(ruby, to_value)?;
            let meta_value = meta_or_empty(ruby, meta_value);
            let [content, meta] = ruby_to_canons(ruby, [content_value, meta_value])?;
            // Content and meta are Rust state, so every later refusal waits
            // until they drop.
            let built = move || -> Result<_, Refusal> {
                let parent = read_optional_digest(ruby, parent_value)?;
                let correlation = read_optional_digest(ruby, correlation_value)?;
                let causal_parents = read_causal_parents(ruby, causal_value)?;
                let from = optional_utf8(from)?;
                let to = optional_utf8(to)?;
                let turn =
                    EventData::turn(role, content, parent, meta, correlation, causal_parents);
                Ok((turn, from, to))
            };
            let (turn, from, to) = built().map_err(|refusal| refusal.raise(ruby))?;
            // The sender and recipient live in the header, so they change the
            // digest while the payload is reused as built.
            let inner = match &turn.payload {
                Some(payload) if from.is_some() || to.is_some() => EventData::new(
                    from,
                    to,
                    turn.render_parent.clone(),
                    turn.causal_parents.clone(),
                    turn.correlation.clone(),
                    Arc::clone(payload),
                ),
                _ => turn,
            };
            Ok(Turn::wrap(ruby, inner))
        }

        fn from(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_text_value(ruby, &rb_self.inner.from)
        }

        fn to(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_text_value(ruby, &rb_self.inner.to)
        }

        fn body(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            match rb_self.inner.body() {
                Some(body) => canon_to_ruby(ruby, body),
                None => Ok(ruby.qnil().as_value()),
            }
        }

        fn carried_payload(ruby: &Ruby, rb_self: &Turn) -> Value {
            match &rb_self.inner.payload {
                Some(payload) => Payload::wrap(ruby, Arc::clone(payload)).as_value(),
                None => ruby.qnil().as_value(),
            }
        }

        fn optional_text_value(ruby: &Ruby, text: &Option<String>) -> Value {
            match text {
                Some(text) => frozen_str(ruby, text),
                None => ruby.qnil().as_value(),
            }
        }

        /// A carried-body field. A detached envelope raises `Lain::Error` in
        /// the deleted Ruby `Event#fetch_body`'s words: its body exists, under
        /// `payload_digest`, so a `nil` would be a lie. A carrying envelope
        /// built as a :turn always holds the key; a miss there raises all the
        /// same rather than materializing `nil`.
        fn body_field<'a>(ruby: &Ruby, rb_self: &'a Turn, key: &str) -> Result<&'a Canon, Error> {
            if rb_self.inner.payload.is_none() {
                let message = format!(
                    "{} carries no body; it lives in the Store under {}. This envelope was \
                     rebuilt from digests alone -- fetch that payload through a Store, or \
                     build it via Event.turn to carry one",
                    rb_self.inspect(),
                    rb_self.inner.payload_digest
                );
                return Err(lookup_error(ruby, &["Lain", "Error"], move || message));
            }
            rb_self.inner.body_field(key).ok_or_else(|| {
                Error::new(
                    ruby.exception_runtime_error(),
                    format!("Lain::Ext: a :turn event's carried body must hold {key:?}"),
                )
            })
        }

        fn role(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            match Self::body_field(ruby, rb_self, "role")? {
                Canon::Str(role) => Ok(frozen_str(ruby, role)),
                _ => Err(Error::new(
                    ruby.exception_runtime_error(),
                    "Lain::Ext: a :turn event's role must be a wire string",
                )),
            }
        }

        fn content(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            canon_to_ruby(ruby, Self::body_field(ruby, rb_self, "content")?)
        }

        fn parent(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_digest_value(ruby, &rb_self.inner.render_parent)
        }

        fn meta(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            canon_to_ruby(ruby, Self::body_field(ruby, rb_self, "meta")?)
        }

        fn digest(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, rb_self.inner.digest.as_str())
        }

        fn kind(ruby: &Ruby, rb_self: &Turn) -> Value {
            // A Symbol, as the deleted Ruby `Event#kind` was -- the wire string is what
            // the digest hashes; the Symbol is the loud in-process enum.
            ruby.to_symbol(rb_self.inner.kind.as_str()).as_value()
        }

        fn payload_digest(ruby: &Ruby, rb_self: &Turn) -> Value {
            frozen_str(ruby, rb_self.inner.payload_digest.as_str())
        }

        fn correlation(ruby: &Ruby, rb_self: &Turn) -> Value {
            Self::optional_digest_value(ruby, &rb_self.inner.correlation)
        }

        fn causal_parents(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            let array = ruby.ary_new_capa(rb_self.inner.causal_parents.len());
            for digest in &rb_self.inner.causal_parents {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            array.freeze();
            Ok(array.as_value())
        }

        fn optional_digest_value(ruby: &Ruby, digest: &Option<Digest>) -> Value {
            match digest {
                Some(digest) => frozen_str(ruby, digest.as_str()),
                None => ruby.qnil().as_value(),
            }
        }

        /// The envelope structure the digest was taken over, as the deleted Ruby
        /// `Event#payload` built it -- rendered from the SAME
        /// `payload_canon()` the digest hashed, so the two cannot drift. One
        /// field is patched on the way through: Ruby's hash holds `kind` as a
        /// SYMBOL (the wire string is what the digest hashes -- Canonical
        /// collapses Symbol/String), and the byte-parity spec compares with
        /// `eq`, where `:turn != "turn"`.
        fn payload(ruby: &Ruby, rb_self: &Turn) -> Result<Value, Error> {
            let Canon::Object(pairs) = rb_self.inner.payload_canon() else {
                // Unreachable: envelope_canon always builds an object. Loud
                // regardless -- classify_num's garbage-arm philosophy.
                return Err(Error::new(
                    ruby.exception_runtime_error(),
                    "Lain::Ext: the envelope canon must be an object",
                ));
            };
            let hash = ruby.hash_new();
            for (key, value) in &pairs {
                let rendered = if key == "kind" {
                    Self::kind(ruby, rb_self)
                } else {
                    canon_to_ruby(ruby, value)?
                };
                hash.aset(frozen_str(ruby, key), rendered)?;
            }
            hash.freeze();
            Ok(hash.as_value())
        }

        fn root_p(&self) -> bool {
            self.inner.root()
        }

        // to_s is the human-facing projection; inspect keeps the class-tagged,
        // debug-oriented form -- the same convention Ruby's DegradedSet uses.
        // Not a loud site: a debug string must not raise, so an (FFI-
        // unreachable) roleless body renders "?" rather than raising -- the
        // same convention as Timeline#to_s's "(?)" length.
        fn to_s(&self) -> String {
            let digest = self.inner.digest.as_str();
            let prefix = digest.get(..19).unwrap_or(digest);
            format!("{} {prefix}...", self.inner.role_str().unwrap_or("?"))
        }

        fn inspect(&self) -> String {
            format!("#<Lain::Ext::Event {}>", self.to_s())
        }
    }

    /// The kind-tagged body an envelope addresses by digest. Holds only an
    /// `Arc<PayloadData>` -- pure immutable Rust, no Ruby reference -- so it
    /// needs no `mark` and is `Ractor.shareable?` once frozen, like `Turn`.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Payload", free_immediately, frozen_shareable)]
    struct Payload {
        inner: Arc<PayloadData>,
    }

    impl DataTypeFunctions for Payload {}

    impl PartialEq for Payload {
        fn eq(&self, other: &Self) -> bool {
            self.inner.digest == other.inner.digest
        }
    }

    impl Eq for Payload {}

    impl std::hash::Hash for Payload {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.inner.digest.hash(state);
        }
    }

    impl Payload {
        fn wrap(ruby: &Ruby, inner: Arc<PayloadData>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Payload { inner });
            obj.freeze();
            obj
        }

        fn kind(ruby: &Ruby, rb_self: &Payload) -> Value {
            ruby.to_symbol(rb_self.inner.kind.as_str()).as_value()
        }

        fn body(ruby: &Ruby, rb_self: &Payload) -> Result<Value, Error> {
            canon_to_ruby(ruby, &rb_self.inner.body)
        }

        fn digest(ruby: &Ruby, rb_self: &Payload) -> Value {
            frozen_str(ruby, rb_self.inner.digest.as_str())
        }

        fn to_s(&self) -> String {
            let digest = self.inner.digest.as_str();
            let prefix = digest.get(..19).unwrap_or(digest);
            format!(
                "#<Lain::Ext::Payload {} {prefix}...>",
                self.inner.kind.as_str()
            )
        }
    }

    /// An append-only, content-addressed object database over two `rpds` maps,
    /// one keyspace (see `dag::Objects`). The maps are persistent (structural
    /// sharing), and the `Mutex` makes concurrent `put`s safe independently of
    /// the GVL. Holds no Ruby reference, so no `mark`; not shareable, because
    /// it is mutable.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Store", free_immediately)]
    struct Store {
        objects: Mutex<dag::Objects>,
    }

    impl DataTypeFunctions for Store {}

    impl Store {
        fn new(ruby: &Ruby) -> Obj<Self> {
            ruby.obj_wrap(Store {
                objects: Mutex::new(dag::Objects::empty()),
            })
        }

        fn locked(&self) -> std::sync::MutexGuard<'_, dag::Objects> {
            self.objects
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
        }

        /// The referential-integrity boundary every writer goes through: the
        /// lock, and [`super::put_into`], which carries the whole decision
        /// (refuse a node naming a digest the store does not hold, else insert
        /// if absent) along with its idempotence proof. ONE lock across check
        /// AND insert, so a concurrent write cannot land in the window; the
        /// guard drops before the caller turns the refusal into a Ruby
        /// exception, which is the discipline `missing_object` documents.
        ///
        /// `prelude` is put first under the same lock, and nothing lands
        /// unless both do: `Timeline::commit` puts a payload and then the
        /// envelope that addresses it, as one write.
        fn insert(
            &self,
            prelude: Option<&NodeData>,
            node: &NodeData,
        ) -> Result<Digest, PutRefusal> {
            let mut objects = self.locked();
            let before = match prelude {
                Some(first) => put_into(&objects, first)?.0,
                None => objects.clone(),
            };
            let (after, digest) = put_into(&before, node)?;
            *objects = after;
            Ok(digest)
        }

        /// Whether the store holds `digest`, in either map. The Ruby-facing
        /// `key?` converts its String argument through this.
        fn contains(&self, digest: &Digest) -> bool {
            self.locked().contains(digest)
        }

        /// The Ruby-facing `put`: read `object` into the arm it belongs to,
        /// then [`Store::insert`] plus the error translation.
        fn put(ruby: &Ruby, rb_self: &Store, object: Value) -> Result<String, Error> {
            let node = read_node(ruby, object)?;
            let inserted = rb_self.insert(None, &node);
            drop(node);
            let digest = inserted.map_err(|refusal| put_refused(ruby, refusal))?;
            // FFI-out boundary: the digest returns to Ruby as a String.
            Ok(digest.into())
        }

        /// What the crate can give back for each arm, since it holds no Ruby
        /// reference: an event, a payload, a blob's frozen binary bytes, or a
        /// deeply frozen canonical tree.
        fn fetch(ruby: &Ruby, rb_self: &Store, digest: RString) -> Result<Value, Error> {
            // The Rust copy of the key is gone before a miss's refusal reaches
            // Ruby, which quotes the key again from the Ruby String.
            let found = rb_self.locked().get(&Digest::from(digest.to_string()?));
            match found {
                Some(NodeData::Event(event)) => Ok(Turn::wrap(ruby, event).as_value()),
                Some(NodeData::Payload(payload)) => Ok(Payload::wrap(ruby, payload).as_value()),
                Some(NodeData::Blob(blob)) => {
                    let bytes = ruby.str_from_slice(&blob.bytes);
                    bytes.freeze();
                    Ok(bytes.as_value())
                }
                Some(NodeData::Canon(canon)) => canon_to_ruby(ruby, &canon.tree),
                None => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Store", "MissingObject"],
                    move || {
                        format!(
                            "no object {:?} in store",
                            Digest::from(digest.to_string().unwrap_or_default())
                        )
                    },
                )),
            }
        }

        /// Whether `digest` names an event, the only object a Timeline head
        /// or a walk can stand on.
        fn holds_event(&self, digest: &Digest) -> bool {
            self.locked().holds(digest, dag::Arm::Event)
        }

        fn key_p(&self, digest: String) -> bool {
            self.contains(&digest.into())
        }

        fn size(&self) -> usize {
            self.locked().size()
        }
    }

    /// The store arm `object` belongs to. An Ext event or payload is its own
    /// arm. Anything answering `#canonical` is addressed by that tree, and
    /// anything answering `#tag` and `#bytes` by the blob scheme; both have
    /// their digest recomputed here and compared with the one they claim. Any
    /// other object, an event of some other implementation included, answers
    /// neither and is refused rather than stored as a tree a fetch could not
    /// turn back into an event.
    fn read_node(ruby: &Ruby, object: Value) -> Result<NodeData, Error> {
        if let Ok(event) = <&Turn>::try_convert(object) {
            return Ok(NodeData::Event(Arc::clone(&event.inner)));
        }
        if let Ok(payload) = <&Payload>::try_convert(object) {
            return Ok(NodeData::Payload(Arc::clone(&payload.inner)));
        }
        let claimed_digest = || object.funcall::<_, _, RString>("digest", ());
        // Every call into Ruby comes before any Rust state is built, except the
        // tree's own conversion, which keeps its partial state in a `Reading`.
        let (node, claimed) = if object.respond_to("canonical", false)? {
            let tree: Value = object.funcall("canonical", ())?;
            let claimed = claimed_digest()?;
            let tree = ruby_to_canon(ruby, tree)?;
            (NodeData::Canon(Arc::new(CanonData::new(tree))), claimed)
        } else if object.respond_to("tag", false)? && object.respond_to("bytes", false)? {
            let tag: RString = object.funcall("tag", ())?;
            let bytes: RString = object.funcall("bytes", ())?;
            let claimed = claimed_digest()?;
            let tag = validated_utf8(ruby, tag)?;
            let blob = BlobData::new(&tag, with_bytes(bytes, <[u8]>::to_vec));
            (NodeData::Blob(Arc::new(blob)), claimed)
        } else {
            let class = object.class().inspect();
            return Err(Error::new(
                ruby.exception_type_error(),
                format!(
                    "a Store holds events, payloads, blobs and canonical values, not a {class}"
                ),
            ));
        };
        let claimed = match utf8(claimed) {
            Ok(claimed) => Digest::from(claimed),
            Err(refusal) => {
                drop(node);
                return Err(refusal.raise(ruby));
            }
        };
        verified(node, claimed).map_err(|mismatch| {
            lookup_error(
                ruby,
                &["Lain", "Ext", "Store", "DigestMismatch"],
                move || mismatch.to_string(),
            )
        })
    }

    /// A refused put as the Ruby exception its cause names.
    fn put_refused(ruby: &Ruby, refusal: PutRefusal) -> Error {
        put_refusal(refusal).raise(ruby)
    }

    /// [`put_refused`], with the exception not yet built.
    fn put_refusal(refusal: PutRefusal) -> Refusal {
        match refusal {
            PutRefusal::Dangling(dangling) => Refusal::missing(dangling),
            mislabelled @ PutRefusal::NotItsPayload { .. } => Refusal::Named(
                &["Lain", "Ext", "Store", "DigestMismatch"],
                mislabelled.to_string(),
            ),
        }
    }

    /// The state of one lazy `Timeline#ancestors` walk: a snapshot of the
    /// store's event map and the digest still to visit. A Ruby object so the
    /// collector frees it with a fiber dropped mid-walk (see `ancestors`).
    /// Holds no Ruby reference, so it needs no `mark`.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Timeline::Walk", free_immediately)]
    struct Walk {
        events: StoreMap,
        cursor: RefCell<Option<Digest>>,
    }

    /// Walks built and not yet dropped. The leak `Walk` exists to prevent is
    /// Rust memory, which no Ruby-side count can see, so the count lives here.
    static LIVE_WALKS: AtomicUsize = AtomicUsize::new(0);

    impl DataTypeFunctions for Walk {}

    impl Drop for Walk {
        fn drop(&mut self) {
            LIVE_WALKS.fetch_sub(1, Ordering::Relaxed);
        }
    }

    impl Walk {
        fn new(events: StoreMap, head: Option<Digest>) -> Self {
            LIVE_WALKS.fetch_add(1, Ordering::Relaxed);
            Walk {
                events,
                cursor: RefCell::new(head),
            }
        }

        /// `Walk.live`: how many walks hold a snapshot right now.
        fn live() -> usize {
            LIVE_WALKS.load(Ordering::Relaxed)
        }

        /// The next node, head first, or `None` past the root.
        fn step(&self) -> Result<Option<Arc<EventData>>, dag::DanglingDigest> {
            let Some(digest) = self.cursor.borrow_mut().take() else {
                return Ok(None);
            };
            let turn = dag::node(&self.events, &digest)?;
            *self.cursor.borrow_mut() = turn.render_parent.clone();
            Ok(Some(turn))
        }
    }

    /// An immutable `(head, store)` handle over the DAG. References the Store
    /// Ruby object (hence `mark`), so it is not shareable -- like Ruby's.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Timeline", free_immediately, mark)]
    struct Timeline {
        head: Option<Digest>,
        store: Opaque<Value>,
    }

    impl DataTypeFunctions for Timeline {
        fn mark(&self, marker: &gc::Marker) {
            marker.mark(self.store);
        }
    }

    impl PartialEq for Timeline {
        fn eq(&self, other: &Self) -> bool {
            self.head == other.head
        }
    }

    impl Eq for Timeline {}

    impl std::hash::Hash for Timeline {
        fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
            self.head.hash(state);
        }
    }

    impl Timeline {
        fn wrap(ruby: &Ruby, head: Option<Digest>, store: Value) -> Obj<Self> {
            let obj = ruby.obj_wrap(Timeline {
                head,
                store: store.into(),
            });
            obj.freeze();
            obj
        }

        fn store_value(&self, ruby: &Ruby) -> Value {
            ruby.get_inner(self.store)
        }

        // WHY hand-rolled rather than `scan_args`: this parse's actual
        // contract is "first positional arg, if present, must be a Hash;
        // `expected keyword arguments` otherwise" -- it accepts any
        // Hash-shaped value there, not only Ruby's own keyword-argument
        // calling convention. `scan_args`'s `Kw` machinery parses real
        // keyword args (the VM-tagged kwargs hash) and raises its own,
        // differently-worded errors on a bad shape; routing this site through
        // it risks changing the exact Ruby-observable arity/error text this
        // sweep must not touch (see the card's escalation trigger), for no
        // behavior gain. `rewind`'s single optional positional `Int` has no
        // such ambiguity, so it does take `scan_args` above.
        fn empty(ruby: &Ruby, args: &[Value]) -> Result<Obj<Self>, Error> {
            let store_value = match args.first() {
                None => Store::new(ruby).as_value(),
                Some(first) => {
                    let kw = RHash::from_value(*first).ok_or_else(|| {
                        Error::new(ruby.exception_arg_error(), "expected keyword arguments")
                    })?;
                    let parsed = get_kwargs::<_, (), (Option<Value>,), ()>(kw, &[], &["store"])?;
                    match parsed.optional.0 {
                        Some(store) => store,
                        None => Store::new(ruby).as_value(),
                    }
                }
            };
            // A non-Store store must fail loudly at construction, not on first
            // walk -- and the check runs through the same lifetime-tied
            // accessor every walk uses, which is why the handle is wrapped
            // first. A handle that raises here is discarded unreferenced.
            let timeline = Timeline::wrap(ruby, None, store_value);
            store_ref(ruby, &timeline)?;
            Ok(timeline)
        }

        fn new(ruby: &Ruby, kw: RHash) -> Result<Obj<Self>, Error> {
            let args = get_kwargs::<_, (Value, Value), (), ()>(kw, &["head_digest", "store"], &[])?;
            let (head_value, store_value) = args.required;
            let head = read_optional_digest(ruby, Some(head_value))
                .map_err(|refusal| refusal.raise(ruby))?;
            let timeline = Timeline::wrap(ruby, head, store_value);
            let store = store_ref(ruby, &timeline)?;
            validate_head(ruby, store, timeline.head.clone())?;
            Ok(timeline)
        }

        fn correlation(ruby: &Ruby, rb_self: &Timeline) -> Result<Value, Error> {
            let store = store_ref(ruby, rb_self)?;
            let correlation = Self::next_correlation(rb_self.head.as_ref(), store)
                .map_err(|refusal| refusal.raise(ruby))?;
            Ok(Turn::optional_digest_value(ruby, &correlation))
        }

        fn empty_p(&self) -> bool {
            self.head.is_none()
        }

        fn head_digest(ruby: &Ruby, rb_self: &Timeline) -> Value {
            match &rb_self.head {
                Some(digest) => frozen_str(ruby, digest.as_str()),
                None => ruby.qnil().as_value(),
            }
        }

        fn store(ruby: &Ruby, rb_self: &Timeline) -> Value {
            rb_self.store_value(ruby)
        }

        fn head(ruby: &Ruby, rb_self: &Timeline) -> Result<Value, Error> {
            match &rb_self.head {
                None => Ok(ruby.qnil().as_value()),
                Some(digest) => {
                    let store: &Store = store_ref(ruby, rb_self)?;
                    // Bound to a `let` so the guard drops before the `match`:
                    // the `None` arm calls into Ruby (see `missing_object`).
                    let found = store.locked().events.get(digest).map(Arc::clone);
                    match found {
                        Some(inner) => Ok(Turn::wrap(ruby, inner).as_value()),
                        None => Err(lookup_error(
                            ruby,
                            &["Lain", "Ext", "Store", "MissingObject"],
                            // `digest: &Digest`, transparent `Debug` -> same bytes.
                            {
                                let message = format!("no object {digest:?} in store");
                                move || message
                            },
                        )),
                    }
                }
            }
        }

        /// The signature is the deleted Ruby `Timeline#commit(role:, content:,
        /// meta:, causal_parents:)`'s. `causal_parents` is the set of events this turn
        /// folded -- absent means the empty set, and such a turn hashes
        /// exactly as it did before the keyword existed, because an empty
        /// array is what the envelope always serialized.
        fn commit(ruby: &Ruby, rb_self: Obj<Timeline>, kw: RHash) -> Result<Obj<Timeline>, Error> {
            let args = get_kwargs::<_, (Value, Value), (Option<Value>, Option<Value>), ()>(
                kw,
                &["role", "content"],
                &["meta", "causal_parents"],
            )?;
            let (role_value, content_value) = args.required;
            let (meta_value, causal_value) = args.optional;
            let role = read_role(ruby, role_value)?;
            let meta_value = meta_or_empty(ruby, meta_value);
            let [content, meta] = ruby_to_canons(ruby, [content_value, meta_value])?;
            let store_value = rb_self.store_value(ruby);
            // Content and meta are Rust state, so every refusal waits until they drop.
            let inserted = move || -> Result<Digest, Refusal> {
                let store: &Store = store_ref(ruby, &rb_self)?;
                let causal_parents = read_causal_parents(ruby, causal_value)?;
                let correlation = Self::next_correlation(rb_self.head.as_ref(), store)?;
                let turn = EventData::turn(
                    role,
                    content,
                    rb_self.head.clone(),
                    meta,
                    correlation,
                    causal_parents,
                );
                // Through the validating boundary, NOT past it. The render edge is
                // this Timeline's own validated head and needs no check, which is
                // what used to justify an unvalidated insert here -- but a causal
                // parent is a caller-supplied digest naming any object at all, so
                // that induction no longer covers the node. The deleted Ruby got
                // the same check for free by committing through its `Store#put`.
                let payload = turn
                    .payload
                    .as_ref()
                    .map(|payload| NodeData::Payload(Arc::clone(payload)));
                store
                    .insert(payload.as_ref(), &NodeData::Event(turn))
                    .map_err(put_refusal)
            };
            let digest = inserted().map_err(|refusal| refusal.raise(ruby))?;
            Ok(Timeline::wrap(ruby, Some(digest), store_value))
        }

        /// The chain identity to stamp on the next turn -- the port of
        /// `EventLog::ChainWriter.correlation_of` (TL-2: a chain is named by its
        /// root event's digest). The root cannot contain its own address, so
        /// it carries no correlation and every descendant inherits either the
        /// head's correlation or, when the head IS the root, the head's own
        /// digest. `None` only on an empty Timeline, exactly as the deleted Ruby's
        /// `head &&` guard. A head digest the store no longer holds is
        /// corruption and raises, the same loud arm every walk has.
        fn next_correlation(
            head: Option<&Digest>,
            store: &Store,
        ) -> Result<Option<Digest>, Refusal> {
            match head {
                None => Ok(None),
                Some(head_digest) => {
                    // The lookup is its own statement so the guard drops before
                    // `ok_or_else` reaches Ruby (see `missing_object`); chained
                    // onto the same expression, the temporary guard would still
                    // be alive when `const_get` ran.
                    let found = store.locked().events.get(head_digest).map(Arc::clone);
                    let node = found.ok_or_else(|| {
                        Refusal::missing(dag::DanglingDigest(head_digest.clone()))
                    })?;
                    Ok(Some(
                        node.correlation
                            .clone()
                            .unwrap_or_else(|| head_digest.clone()),
                    ))
                }
            }
        }

        // `fork` is O(1) because a Timeline handle is already an immutable
        // pointer into the shared, content-addressed Store -- there is no
        // subtree to copy. Returning `rb_self` unchanged IS the fork; the two
        // handles are indistinguishable, and later commits on either diverge
        // from here as ordinary content-addressed writes.
        fn fork(rb_self: Obj<Timeline>) -> Obj<Timeline> {
            rb_self
        }

        fn checkout(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            digest: Value,
        ) -> Result<Obj<Timeline>, Error> {
            let head =
                read_optional_digest(ruby, Some(digest)).map_err(|refusal| refusal.raise(ruby))?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(ruby, &rb_self)?;
            let head = validate_head(ruby, store, head)?;
            Ok(Timeline::wrap(ruby, head, store_value))
        }

        fn rewind(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            args: &[Value],
        ) -> Result<Obj<Timeline>, Error> {
            // `scan_args` raises ArgumentError on 2+ positional args where the
            // old hand-rolled parse silently ignored the extras. Deliberate:
            // the deleted Ruby `Lain::Timeline#rewind(count = 1)` enforced
            // this arity, so the swallowing was a latent Ruby/Ext divergence
            // -- cross-implementation parity outranked bug-for-bug preservation.
            let parsed = scan_args::<(), (Option<i64>,), (), (), (), ()>(args)?;
            let count = parsed.optional.0.unwrap_or(1);
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(ruby, &rb_self)?;
            // One locked read for the whole walk, matching dag.rs's own
            // single-locked-read doctrine: re-acquiring the Mutex per step
            // would let another thread's `commit` interleave mid-rewind. The
            // walk itself is `super::rewind_to`, a pure function, so the guard
            // drops with the block and the corruption case becomes a Ruby
            // exception only afterwards (see `missing_object`).
            let walked = {
                let map = store.locked();
                super::rewind_to(&map.events, rb_self.head.clone(), count)
            };
            let digest = walked.map_err(|e| missing_object(ruby, e))?;
            // `parent_of` validates the node stepped FROM, never the digest
            // landed ON: landing exactly on a dangle would hand back a poisoned
            // Timeline whose head the store does not hold. The deleted Ruby rewind
            // landed via #checkout, which validated -- so must we, same message form.
            // (A fresh, separate lock: the loop's guard above already dropped,
            // since std's Mutex is not reentrant. The drop-then-relock gap is
            // unobservable from Ruby: between the two locks there is no Ruby
            // dispatch point -- `validate_head` reaches `store.key_p` as a
            // direct Rust call, no funcall/IO/yield -- so this whole method
            // runs as one uninterrupted stretch under the GVL and no other
            // thread's `store.put` can land in between.)
            let digest = validate_head(ruby, store, digest)?;
            Ok(Timeline::wrap(ruby, digest, store_value))
        }

        /// Every walk below reads `store.locked()` in a statement of its own and
        /// translates on the NEXT line. That is not a style choice: written as
        /// one chained expression, the temporary `MutexGuard` outlives the
        /// `map_err` closure, so `missing_object`'s `const_get` would run --
        /// raising, allocating, and inviting GC -- with the store locked.
        ///
        /// `ancestors` is the one walk with a block form, and it is lazy: it
        /// wraps one node per yield, as the block asks, so a caller that stops
        /// early (`take_while`, `find`) pays only for the nodes it read. Three
        /// things make that safe:
        ///
        /// - The walk reads an O(1) snapshot of the persistent map, taken with
        ///   the lock held and released before the first yield, so the block
        ///   may run any Ruby, a `commit` on the same store included, against
        ///   the non-reentrant `std::sync::Mutex`.
        /// - The snapshot and the cursor live in a [`Walk`], an object Ruby's
        ///   collector owns, held only on this frame's stack. An Enumerator
        ///   stepped from outside (`next`, `peek`, `zip`) runs this frame on a
        ///   fiber, and a fiber dropped mid-walk is collected without
        ///   unwinding, so Rust memory owned by the frame would never be
        ///   freed; the `Walk` is freed with the fiber.
        /// - Each node's wrapper goes straight to `rb_yield`, so no Ruby value
        ///   sits on the Rust heap, which the conservative collector does not
        ///   scan, across a yield that can collect.
        fn ancestors(ruby: &Ruby, rb_self: Obj<Timeline>) -> Result<Value, Error> {
            // `enum_for` before the store is read keeps the no-block form O(1).
            if !ruby.block_given() {
                return Ok(rb_self.enumeratorize("ancestors", ()).as_value());
            }

            let events = store_ref(ruby, &rb_self)?.locked().events.clone();
            let walk = ruby.obj_wrap(Walk::new(events, rb_self.head.clone()));
            while let Some(turn) = walk.step().map_err(|e| missing_object(ruby, e))? {
                let _: Value = ruby.yield_value(Turn::wrap(ruby, turn))?;
            }
            // Keeps `walk` in this frame's memory, where the collector scans
            // it, until the loop is done with it.
            std::hint::black_box(walk.as_value());
            // Ruby's block form ends on a `while`, so it answers nil.
            Ok(ruby.qnil().as_value())
        }

        fn to_a(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = store_ref(ruby, rb_self)?;
            let walked = dag::ancestor_turns(&store.locked().events, rb_self.head.as_ref());
            let mut arcs = walked.map_err(|e| missing_object(ruby, e))?;
            arcs.reverse();
            turns_to_array(ruby, arcs)
        }

        /// `#messages(after: nil, onto: [])`: the projection a render sends,
        /// built from one walk under one lock. When `after` is an ancestor of
        /// the head, the turns after it, appended to `onto`; otherwise every
        /// turn, root first, and `onto` is dropped, so a stale prefix is never
        /// spliced.
        fn messages(ruby: &Ruby, rb_self: &Timeline, args: &[Value]) -> Result<RArray, Error> {
            let parsed = scan_args::<(), (), (), (), RHash, ()>(args)?;
            let kwargs = get_kwargs::<_, (), (Option<Value>, Option<RArray>), ()>(
                parsed.keywords,
                &[],
                &["after", "onto"],
            )?;
            let (after_value, onto) = kwargs.optional;
            let canonical: RModule = ruby
                .class_object()
                .const_get::<_, RModule>("Lain")?
                .const_get("Canonical")?;
            let store: &Store = store_ref(ruby, rb_self)?;
            let after =
                read_optional_digest(ruby, after_value).map_err(|refusal| refusal.raise(ruby))?;
            let (messages, adoptable) = {
                let walked = dag::turns_since(
                    &store.locked().events,
                    rb_self.head.as_ref(),
                    after.as_ref(),
                );
                drop(after);
                let (turns, reached) = walked.map_err(|e| missing_object(ruby, e))?;
                let prefix = onto.filter(|_| reached);
                MessageBuilder::new(ruby).messages(prefix, &turns)?
            };
            for built in adoptable {
                let _: Value = canonical.funcall("adopt", (built,))?;
            }
            Ok(messages)
        }

        fn ancestor_digests(ruby: &Ruby, rb_self: &Timeline) -> Result<RArray, Error> {
            let store: &Store = store_ref(ruby, rb_self)?;
            let walked = dag::ancestor_digests(&store.locked().events, rb_self.head.as_ref());
            let digests = walked.map_err(|e| missing_object(ruby, e))?;
            let array = ruby.ary_new_capa(digests.len());
            for digest in digests {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            Ok(array)
        }

        fn length(ruby: &Ruby, rb_self: &Timeline) -> Result<usize, Error> {
            let store: &Store = store_ref(ruby, rb_self)?;
            // `dag::length` folds the count over the walk, so a number costs no
            // `Vec<Arc<EventData>>`. The `let` also drops the guard before the
            // translation: the pure answer is computed under the lock, Ruby is
            // spoken to after it.
            let counted = dag::length(&store.locked().events, rb_self.head.as_ref());
            counted.map_err(|e| missing_object(ruby, e))
        }

        fn consumed(ruby: &Ruby, rb_self: &Timeline, digests: Value) -> Result<RArray, Error> {
            let wanted = read_causal_parents(ruby, Some(digests)).map_err(|r| r.raise(ruby))?;
            let store: &Store = store_ref(ruby, rb_self)?;
            let walked = dag::consumed(&store.locked().events, rb_self.head.as_ref(), &wanted);
            let found = walked.map_err(|e| missing_object(ruby, e))?;
            let array = ruby.ary_new_capa(found.len());
            for digest in found {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            Ok(array)
        }

        fn include_p(ruby: &Ruby, rb_self: &Timeline, digest: String) -> Result<bool, Error> {
            let needle: Digest = digest.into();
            let store: &Store = store_ref(ruby, rb_self)?;
            // Stops at the hit rather than walking to the root; guard dropped
            // before the error translation, as above.
            let found = dag::includes(&store.locked().events, rb_self.head.as_ref(), &needle);
            drop(needle);
            found.map_err(|e| missing_object(ruby, e))
        }

        /// The meet of this head and `other`'s in the order `S`: the production
        /// function generic over `algebra::MeetSemilattice` that the trait
        /// exists for. `meet` and `dominator_meet` are this at two types, and
        /// `Ext::Dag::RenderAncestry.meet` / `Ext::Dag::Dominance.meet` register
        /// it directly.
        ///
        /// The store check runs before the order is asked anything, so the
        /// cross-store refusal is the one `ensure_same_store` words whatever
        /// order is chosen. The answer wraps the `Option` directly: the digest
        /// came out of the store's own walk, so the head validation `checkout`
        /// adds for a caller-supplied digest has nothing to catch.
        fn meet_via<S>(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Obj<Timeline>, Error>
        where
            S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
        {
            ensure_same_store(ruby, &rb_self, other)?;
            let store_value = rb_self.store_value(ruby);
            let store: &Store = store_ref(ruby, &rb_self)?;
            // Locked read in its own statement, translated on the next line --
            // see `ancestors` for why the guard must be gone first.
            let walked = S::meet(&store.locked().events, &rb_self.head, &other.head);
            let common = walked.map_err(|e| missing_object(ruby, e))?;
            Ok(Timeline::wrap(ruby, common, store_value))
        }

        /// Whether this head is below `other`'s in the order `S` -- receiver
        /// below, argument above. `ancestor_of?` and `dominates?` are this at
        /// two types, and the `Ext::Dag` orders register it as `below?`.
        fn below_via<S>(ruby: &Ruby, rb_self: &Timeline, other: &Timeline) -> Result<bool, Error>
        where
            S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
        {
            ensure_same_store(ruby, rb_self, other)?;
            let store: &Store = store_ref(ruby, rb_self)?;
            let walked = S::below(&store.locked().events, &rb_self.head, &other.head);
            walked.map_err(|e| missing_object(ruby, e))
        }

        fn ancestor_of_p(ruby: &Ruby, rb_self: &Timeline, other: &Timeline) -> Result<bool, Error> {
            Self::below_via::<RenderAncestry>(ruby, rb_self, other)
        }

        fn meet(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Obj<Timeline>, Error> {
            Self::meet_via::<RenderAncestry>(ruby, rb_self, other)
        }

        /// The deepest common dominator over the UNION graph -- render and
        /// causal edges together -- which is the latest event no in-flight
        /// branch can bypass: the safe-compaction checkpoint, and this is its
        /// only implementation. A DIFFERENT operator from `meet` above over a
        /// different graph, not a widened one, which is why it is `meet_via` at
        /// `Dominance` rather than `RenderAncestry`.
        ///
        /// A meet that climbs all the way to the virtual root answers the EMPTY
        /// timeline: the root is a modelling artifact that never leaves
        /// `graph`, so a Ruby caller sees `checkout(nil)`.
        ///
        /// No memo. This handle is frozen and every call is one-shot; a query
        /// object holding a cache the caller keeps is a decision of its own.
        fn dominator_meet(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Obj<Timeline>, Error> {
            Self::meet_via::<Dominance>(ruby, rb_self, other)
        }

        /// The dominance order, asked of the receiver: does every path from
        /// the virtual root to `other`'s head pass through this one's? Shaped
        /// like `ancestor_of?` -- receiver below, argument above.
        ///
        /// It is exposed because it is the ORDER `dominator_meet` is a meet of,
        /// and it is strictly STRONGER than `ancestor_of?`: reachability asks
        /// whether SOME path arrives, dominance whether EVERY one does. The
        /// semilattice law "a meet sits below both operands" is a claim about
        /// this predicate, and checking it with the weaker one passes
        /// vacuously.
        fn dominates_p(ruby: &Ruby, rb_self: &Timeline, other: &Timeline) -> Result<bool, Error> {
            Self::below_via::<Dominance>(ruby, rb_self, other)
        }

        /// The common causal ancestors of the two heads that are not
        /// ancestors of another common one -- git merge-base's maximal lower
        /// bounds -- as a frozen Array of frozen digest Strings in digest order.
        ///
        /// An Array and NOT a Timeline, unlike every other meet-ish method
        /// here, because the answer's cardinality routinely exceeds one: a
        /// criss-cross fan-in leaves incomparable bounds and no greatest among
        /// them, which is why `algebra::CausalAncestry` implements
        /// `MaximalLowerBounds` rather than `MeetSemilattice`, and why nothing
        /// wraps the answer in a head. `Ext::Dag::CausalAncestry.meets`
        /// registers this same function.
        ///
        /// The boundary is crossed ONCE. `CausalAncestry::meets` names no
        /// `magnus` type, so it structurally cannot speak to Ruby per digest;
        /// it answers a finished `Vec<Digest>` and only then, with the store
        /// guard already dropped, is one Array built from it -- which is also
        /// what keeps `frozen_str`'s allocations (and any GC they invite) off
        /// the locked path, as `ancestors` explains.
        fn causal_meets(
            ruby: &Ruby,
            rb_self: &Timeline,
            other: &Timeline,
        ) -> Result<RArray, Error> {
            ensure_same_store(ruby, rb_self, other)?;
            let store: &Store = store_ref(ruby, rb_self)?;
            let walked = CausalAncestry::meets(&store.locked().events, &rb_self.head, &other.head);
            let bounds = walked.map_err(|e| missing_object(ruby, e))?;
            let array = ruby.ary_new_capa(bounds.len());
            for digest in &bounds {
                array.push(frozen_str(ruby, digest.as_str()))?;
            }
            // Frozen, so the answer is deeply immutable and `Ractor.shareable?`
            // -- the contract `Turn#causal_parents` already answers by.
            array.freeze();
            Ok(array)
        }

        fn diverge_at(
            ruby: &Ruby,
            rb_self: Obj<Timeline>,
            other: &Timeline,
        ) -> Result<Value, Error> {
            ensure_same_store(ruby, &rb_self, other)?;
            let store: &Store = store_ref(ruby, &rb_self)?;
            let walked = dag::meet(
                &store.locked().events,
                rb_self.head.as_ref(),
                other.head.as_ref(),
            );
            let common = walked.map_err(|e| missing_object(ruby, e))?;
            match common {
                None => Ok(ruby.qnil().as_value()),
                // `dag::meet` only ever returns a digest it found walking the
                // store's own ancestor chains (see `dag.rs`), so this second
                // lookup cannot miss for any well-formed Store. Post-T1 that
                // is exactly the shape a walk must not shrug off as `nil`: a
                // miss here means the Store mutated between the two locked
                // reads (or is corrupt in a way `meet` itself didn't catch),
                // and `Store::MissingObject` is the same loud answer every
                // other dangling-digest site in this module gives, not a
                // second, silent failure mode of its own.
                Some(digest) => {
                    // Its own statement, so the guard is gone before the loud
                    // arm reaches Ruby (see `missing_object`).
                    let found = store.locked().events.get(&digest).map(Arc::clone);
                    let Some(inner) = found else {
                        return Err(missing_object(ruby, dag::DanglingDigest(digest)));
                    };
                    Ok(Turn::wrap(ruby, inner).as_value())
                }
            }
        }

        // to_s is the human-facing projection; inspect keeps the class-tagged,
        // debug-oriented form -- the same convention Ruby's DegradedSet uses.
        fn to_s(ruby: &Ruby, rb_self: &Timeline) -> String {
            match &rb_self.head {
                None => "empty".to_string(),
                Some(digest) => {
                    let text = digest.as_str();
                    let prefix = text.get(..19).unwrap_or(text);
                    // `to_s`/`inspect` is not a loud walk site: a debug string
                    // must not raise. But a corrupt chain's length is unknowable,
                    // not zero, so it renders as `(?)` rather than a false `(0)`.
                    let length = store_ref(ruby, rb_self)
                        .ok()
                        .and_then(|store: &Store| {
                            dag::length(&store.locked().events, Some(digest)).ok()
                        })
                        .map(|count| count.to_string())
                        .unwrap_or_else(|| "?".to_string());
                    format!("{prefix}... ({length})")
                }
            }
        }

        fn inspect(ruby: &Ruby, rb_self: &Timeline) -> String {
            format!("#<Lain::Ext::Timeline {}>", Self::to_s(ruby, rb_self))
        }
    }

    /// Builds `Timeline#messages`' answer. Every Hash key and role is one frozen
    /// String per call rather than one per turn, and every message Hash and
    /// every Array it builds is collected for `Canonical.adopt`, so a render
    /// normalizing them finds them already produced instead of rebuilding
    /// them. Adopting is Ruby, so it waits until the builder, and the Rust
    /// state it holds, is gone.
    struct MessageBuilder<'r> {
        ruby: &'r Ruby,
        adoptable: RArray,
        strings: HashMap<String, Value>,
        // Roots every cached String: `strings` lives on the Rust heap, which
        // Ruby's collector does not scan, and a Hash may keep an equal interned
        // key in place of the one cached here.
        rooted: RArray,
    }

    impl<'r> MessageBuilder<'r> {
        fn new(ruby: &'r Ruby) -> Self {
            MessageBuilder {
                ruby,
                adoptable: ruby.ary_new(),
                strings: HashMap::new(),
                rooted: ruby.ary_new(),
            }
        }

        /// The messages, and every Array and message Hash in them still to be adopted.
        fn messages(
            mut self,
            prefix: Option<RArray>,
            turns: &[Arc<EventData>],
        ) -> Result<(RArray, RArray), Error> {
            let held = prefix.map_or(0, |prefix| prefix.len());
            let messages = self.ruby.ary_new_capa(held + turns.len());
            if let Some(prefix) = prefix {
                messages.concat(prefix)?;
            }
            for turn in turns {
                messages.push(self.message(turn)?)?;
            }
            messages.freeze();
            Ok((messages, self.adoptable))
        }

        fn message(&mut self, turn: &EventData) -> Result<Value, Error> {
            let (Some(Canon::Str(role)), Some(content)) =
                (turn.body_field("role"), turn.body_field("content"))
            else {
                return Err(Error::new(
                    self.ruby.exception_runtime_error(),
                    format!(
                        "Lain::Ext: turn {} carries no wire role and content to render",
                        turn.digest.as_str()
                    ),
                ));
            };
            // Sorted key order: an adopted Hash is returned by `normalize` as
            // is, so any other order would change every digest in silence.
            let message = self.ruby.hash_new();
            message.aset(self.string("content")?, self.tree(content)?)?;
            message.aset(self.string("role")?, self.string(role)?)?;
            message.freeze();
            self.adoptable.push(message)?;
            Ok(message.as_value())
        }

        fn tree(&mut self, canon: &Canon) -> Result<Value, Error> {
            match canon {
                Canon::Array(items) => {
                    let array = self.ruby.ary_new_capa(items.len());
                    for item in items {
                        array.push(self.tree(item)?)?;
                    }
                    array.freeze();
                    self.adoptable.push(array)?;
                    Ok(array.as_value())
                }
                Canon::Object(pairs) => {
                    let hash = self.ruby.hash_new();
                    for (key, value) in pairs {
                        hash.aset(self.string(key)?, self.tree(value)?)?;
                    }
                    hash.freeze();
                    Ok(hash.as_value())
                }
                scalar => canon_to_ruby(self.ruby, scalar),
            }
        }

        fn string(&mut self, text: &str) -> Result<Value, Error> {
            if let Some(cached) = self.strings.get(text) {
                return Ok(*cached);
            }
            let fresh = frozen_str(self.ruby, text);
            self.rooted.push(fresh)?;
            self.strings.insert(text.to_owned(), fresh);
            Ok(fresh)
        }
    }

    /// One FFI crossing for a whole chain: wrap each already-walked node into a
    /// frozen `Turn` handle and hand back a single Ruby Array.
    fn turns_to_array(ruby: &Ruby, arcs: Vec<Arc<EventData>>) -> Result<RArray, Error> {
        let array = ruby.ary_new_capa(arcs.len());
        for arc in arcs {
            array.push(Turn::wrap(ruby, arc))?;
        }
        Ok(array)
    }

    /// Raise `Store::MissingObject` unless `head` (when not a root/empty `None`)
    /// names an event the store holds. This is the landed-head validation both
    /// `checkout` and `rewind` perform before wrapping a Timeline, as every
    /// Ruby Timeline landed through `Timeline#initialize`'s check.
    ///
    /// Deliberately tail-less ("... in store" omitted): this mirrors the
    /// deleted Ruby `Timeline#initialize`, whose message was
    /// `no object #{digest.inspect}`, NOT `Store#fetch`'s longer form. The two
    /// Ruby sites differed, so the Ext sites match them per-site rather than
    /// unifying. A head the store holds as something other than an event
    /// says `no event`, the word `validate_put` uses for the same mismatch.
    /// Takes the head and answers it back, so a refused one has dropped
    /// before the refusal reaches Ruby.
    fn validate_head(
        ruby: &Ruby,
        store: &Store,
        head: Option<Digest>,
    ) -> Result<Option<Digest>, Error> {
        let Some(target) = head else { return Ok(None) };
        if store.holds_event(&target) {
            return Ok(Some(target));
        }
        let noun = if store.contains(&target) {
            "event"
        } else {
            "object"
        };
        // `{target:?}` is transparent, so the message is byte-identical to
        // the deleted Ruby `Timeline#initialize`'s.
        let message = format!("no {noun} {target:?}");
        drop(target);
        Err(lookup_error(
            ruby,
            &["Lain", "Ext", "Store", "MissingObject"],
            move || message,
        ))
    }

    /// Raise `Timeline::CrossStore` unless both Timelines name the SAME Store
    /// object. A `Store` defines no `==`, so Ruby `==` is `BasicObject`'s object
    /// identity -- exactly Ruby's `store.equal?(other.store)`. Named for what it
    /// does (raises), not merely what it checks -- every call site treats a
    /// return as "safe to proceed", never inspects an `Ok`/`Err` distinction by
    /// hand.
    ///
    /// WHY `unwrap_or(false)` here is safe (unlike `ruby_to_canon`'s equal
    /// checks): both operands are `Lain::Ext::Store` handles this crate wraps,
    /// not an arbitrary caller-supplied value, and the class defines no `==`
    /// override that could raise -- Ruby's own default is the C-level
    /// `rb_obj_equal` identity check, which cannot raise. Swallowing a
    /// hypothetical error here would only widen a `false` from "definitely
    /// different" to "different-or-erroring", and the fallthrough (`CrossStore`)
    /// is the correct outcome either way.
    fn ensure_same_store(ruby: &Ruby, a: &Timeline, b: &Timeline) -> Result<(), Error> {
        let same = a
            .store_value(ruby)
            .equal(b.store_value(ruby))
            .unwrap_or(false);
        if same {
            Ok(())
        } else {
            Err(lookup_error(
                ruby,
                &["Lain", "Ext", "Timeline", "CrossStore"],
                || "cannot compare Timelines backed by different stores".to_string(),
            ))
        }
    }

    /// A String or Symbol id/text field of a build pair, as a Ruby String. Ids
    /// arrive as Ruby Strings (a memory item's id); Symbols are accepted for the
    /// same reason `read_role` accepts them. Anything else is a loud type error.
    fn pair_field(ruby: &Ruby, value: Value, what: &str) -> Result<RString, Error> {
        match text_value(value)? {
            Some(text) => Ok(text),
            None => {
                // SAFETY: see ruby_to_canon; no Ruby code runs meanwhile.
                let class = unsafe { value.classname() }.into_owned();
                Err(Error::new(
                    ruby.exception_type_error(),
                    format!("{what} must be a String or Symbol, got a {class}"),
                ))
            }
        }
    }

    /// A frozen, immutable BM25 index. Wraps only `Arc<crate::bm25::Bm25Index>`
    /// -- no reachable Ruby object and, per the interior-mutability audit in
    /// `bm25.rs`, no `Cell`/`RefCell`/`Mutex`/lazy cache in any crate type it
    /// reaches (the one such source, the `cached`-memoized default tokenizer, is
    /// feature-disabled) -- so `frozen_shareable` is honest once frozen, exactly
    /// as it is for `Turn`.
    #[derive(TypedData)]
    #[magnus(class = "Lain::Ext::Bm25", free_immediately, frozen_shareable)]
    struct Bm25 {
        inner: Arc<crate::bm25::Bm25Index>,
    }

    impl DataTypeFunctions for Bm25 {}

    impl Bm25 {
        fn wrap(ruby: &Ruby, inner: Arc<crate::bm25::Bm25Index>) -> Obj<Self> {
            let obj = ruby.obj_wrap(Bm25 { inner });
            obj.freeze();
            obj
        }

        /// `Lain::Ext::Bm25.build(pairs)` -- one batch crossing of the FFI
        /// boundary. `pairs` is an Array of `[id, text]` two-element Arrays.
        /// Degenerate batches raise the named `Bm25::EmptyCorpus` /
        /// `Bm25::DuplicateId` errors from the pure builder.
        fn build(ruby: &Ruby, pairs: RArray) -> Result<Obj<Self>, Error> {
            // Every field's text is taken from Ruby before the batch exists.
            let fields = ruby.ary_new_capa(pairs.len() * 2);
            for pair_value in pairs.into_iter() {
                let pair = RArray::from_value(pair_value).ok_or_else(|| {
                    Error::new(
                        ruby.exception_type_error(),
                        "each pair must be a [id, text] Array",
                    )
                })?;
                if pair.len() != 2 {
                    return Err(Error::new(
                        ruby.exception_arg_error(),
                        format!("each pair must be [id, text], got {} elements", pair.len()),
                    ));
                }
                fields.push(pair_field(ruby, pair.entry(0)?, "id")?)?;
                fields.push(pair_field(ruby, pair.entry(1)?, "text")?)?;
            }
            // The batch is Rust state, so a refusal while it grows waits until it drops.
            let batch = (0..fields.len())
                .step_by(2)
                .map(|at| -> Result<(String, String), Refusal> {
                    let id = utf8(fields.entry(at as isize)?)?;
                    let text = utf8(fields.entry(at as isize + 1)?)?;
                    Ok((id, text))
                })
                .collect::<Result<Vec<_>, Refusal>>()
                .map_err(|refusal| refusal.raise(ruby))?;
            // The build runs with the GVL released, so a kill or a raise stops it
            // early; the batch is shared into the job, not copied per attempt.
            // Scoped so the batch is freed before a refusal looks up its Ruby class.
            let built = {
                let batch: Arc<[(String, String)]> = batch.into();
                let bytes = batch.iter().map(|(id, text)| id.len() + text.len()).sum();
                crate::nogvl::without_gvl_when(ruby, crate::bm25::releases_build(bytes), || {
                    let batch = Arc::clone(&batch);
                    Ok(move |cancel: &crate::nogvl::Cancel<'_>| {
                        crate::bm25::Bm25Index::build_until(&batch, cancel)
                    })
                })?
            };
            // `BuildError`'s `Display` (see `bm25.rs`) IS the FFI-visible
            // message for both variants; no hand-built duplicate to drift.
            match built {
                Ok(index) => Ok(Bm25::wrap(ruby, Arc::new(index))),
                Err(err @ crate::bm25::BuildError::EmptyCorpus) => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Bm25", "EmptyCorpus"],
                    move || err.to_string(),
                )),
                Err(err @ crate::bm25::BuildError::DuplicateId(_)) => Err(lookup_error(
                    ruby,
                    &["Lain", "Ext", "Bm25", "DuplicateId"],
                    move || err.to_string(),
                )),
            }
        }

        /// `#search(query, k)` -> up to `k` `[id, score, matched_tokens]` triples,
        /// ranked by descending score with insertion-order tie-breaking. One FFI
        /// crossing: the whole ranked result is built into a single frozen Array.
        ///
        /// Frozen all the way out -- the outer Array, each triple, and each
        /// token Array -- which is what the `astgrep`, `treesitter`, `fuzzy` and
        /// `prompt` bindings do, so no caller has to remember which result is
        /// the exception. The outer freeze is also what makes the whole answer
        /// `Ractor.shareable?`, not merely frozen a layer down.
        fn search(ruby: &Ruby, rb_self: &Bm25, query: String, k: usize) -> Result<RArray, Error> {
            let release = crate::bm25::releases_search(rb_self.inner.documents());
            let hits = crate::nogvl::without_gvl_when(ruby, release, || {
                let (index, query) = (Arc::clone(&rb_self.inner), query.clone());
                Ok(move |cancel: &crate::nogvl::Cancel<'_>| index.search_until(&query, k, cancel))
            })?;
            let out = ruby.ary_new_capa(hits.len());
            for (id, score, matched) in hits {
                let triple = ruby.ary_new_capa(3);
                triple.push(frozen_str(ruby, &id))?;
                triple.push(ruby.float_from_f64(f64::from(score)))?;
                let tokens = ruby.ary_new_capa(matched.len());
                for token in matched {
                    tokens.push(frozen_str(ruby, &token))?;
                }
                tokens.freeze();
                triple.push(tokens.as_value())?;
                triple.freeze();
                out.push(triple)?;
            }
            out.freeze();
            Ok(out)
        }
    }

    #[magnus::init]
    fn init(ruby: &Ruby) -> Result<(), Error> {
        let module = ruby.define_module("Lain")?;
        let ext = module.define_module("Ext")?;
        ext.define_singleton_method("blake3_hex", function!(ffi_blake3_hex, 1))?;
        ext.define_singleton_method("canonical_dump", function!(canonical_dump, 1))?;
        ext.define_singleton_method("canonical_digest", function!(canonical_digest, 1))?;
        let probe = ext.define_module("Probe")?;
        probe.define_singleton_method("live_bytes", function!(live_bytes, 0))?;
        // Built only by a canonical conversion; nothing constructs one from Ruby.
        ext.define_class("Reading", ruby.class_object())?
            .undef_default_alloc_func();

        // Subclass Lain::Error, which `lib/lain.rb` requires before this
        // extension loads (see `lain/error`, then `lain/lain`). No fallback to
        // StandardError: a load-order regression that broke that ordering must
        // fail loudly, here, at require time -- not re-parent every Ext error
        // under a class none of Lain's `rescue Lain::Error` sites catch.
        let lain_error = ruby
            .class_object()
            .const_get::<_, RModule>("Lain")
            .and_then(|m| m.const_get::<_, ExceptionClass>("Error"))?;

        let bm25 = ext.define_class("Bm25", ruby.class_object())?;
        bm25.define_error("EmptyCorpus", lain_error)?;
        bm25.define_error("DuplicateId", lain_error)?;
        bm25.define_singleton_method("build", function!(Bm25::build, 1))?;
        bm25.define_method("search", method!(Bm25::search, 2))?;

        // The starship-compatible prompt formatter. Its whole binding -- class,
        // errors, methods -- is defined in `prompt::ffi` rather than inline here,
        // because grammar, style vocabulary and FFI surface belong in one file;
        // this line is the registration, not the definition.
        crate::prompt::ffi::define(ruby, ext, lain_error)?;

        // The completion fuzzy matcher, on the same registration-not-definition
        // pattern: class, errors and methods all live in `fuzzy::ffi`, so the
        // matcher and its FFI surface stay in one file.
        crate::fuzzy::ffi::define(ruby, ext, lain_error)?;

        // Stateless structural search: no wrapped handle, so `AstGrep` is a bare
        // class with two singleton methods and one named error. `BadPattern`
        // subclasses `Lain::Error` like every other Ext error (see the Bm25 block
        // for why no fallback). The FFI wrappers live in `astgrep::ffi`.
        let astgrep = ext.define_class("AstGrep", ruby.class_object())?;
        astgrep.define_error("BadPattern", lain_error)?;
        astgrep.define_singleton_method("search", function!(crate::astgrep::ffi::search, 3))?;
        astgrep.define_singleton_method("dump", function!(crate::astgrep::ffi::dump, 2))?;

        // Stateless RAW tree-sitter query, the low-level twin of AstGrep: same
        // bare-class-plus-singleton shape, one named error. `BadQuery`
        // subclasses `Lain::Error` (see the Bm25 block for why no fallback).
        // The FFI wrapper lives in `treesitter::ffi`.
        let treesitter = ext.define_class("TreeSitter", ruby.class_object())?;
        treesitter.define_error("BadQuery", lain_error)?;
        treesitter.define_singleton_method("query", function!(crate::treesitter::ffi::query, 3))?;

        let turn = ext.define_class("Event", ruby.class_object())?;
        turn.define_error("InvalidRole", lain_error)?;
        turn.define_singleton_method("new", function!(Turn::new, 1))?;
        turn.define_method("role", method!(Turn::role, 0))?;
        turn.define_method("content", method!(Turn::content, 0))?;
        turn.define_method("parent", method!(Turn::parent, 0))?;
        // The render chain is the first-parent walk, so `parent` IS the render
        // edge -- both names answer it, as the deleted Ruby's `alias parent render_parent` did.
        turn.define_method("render_parent", method!(Turn::parent, 0))?;
        turn.define_method("meta", method!(Turn::meta, 0))?;
        turn.define_method("digest", method!(Turn::digest, 0))?;
        turn.define_method("kind", method!(Turn::kind, 0))?;
        turn.define_method("payload_digest", method!(Turn::payload_digest, 0))?;
        turn.define_method("correlation", method!(Turn::correlation, 0))?;
        turn.define_method("causal_parents", method!(Turn::causal_parents, 0))?;
        turn.define_method("payload", method!(Turn::payload, 0))?;
        turn.define_method("from", method!(Turn::from, 0))?;
        turn.define_method("to", method!(Turn::to, 0))?;
        turn.define_method("body", method!(Turn::body, 0))?;
        turn.define_method("carried_payload", method!(Turn::carried_payload, 0))?;
        turn.define_method("root?", method!(Turn::root_p, 0))?;
        turn.define_method("==", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("eql?", method!(<Turn as typed_data::IsEql>::is_eql, 1))?;
        turn.define_method("hash", method!(<Turn as typed_data::Hash>::hash, 0))?;
        turn.define_method("to_s", method!(Turn::to_s, 0))?;
        turn.define_method("inspect", method!(Turn::inspect, 0))?;

        let payload = ext.define_class("Payload", ruby.class_object())?;
        payload.define_method("kind", method!(Payload::kind, 0))?;
        payload.define_method("body", method!(Payload::body, 0))?;
        payload.define_method("digest", method!(Payload::digest, 0))?;
        payload.define_method("==", method!(<Payload as typed_data::IsEql>::is_eql, 1))?;
        payload.define_method("eql?", method!(<Payload as typed_data::IsEql>::is_eql, 1))?;
        payload.define_method("hash", method!(<Payload as typed_data::Hash>::hash, 0))?;
        payload.define_method("to_s", method!(Payload::to_s, 0))?;
        payload.define_method("inspect", method!(Payload::to_s, 0))?;

        let store = ext.define_class("Store", ruby.class_object())?;
        store.define_error("MissingObject", lain_error)?;
        store.define_error("DigestMismatch", lain_error)?;
        store.define_singleton_method("new", function!(Store::new, 0))?;
        store.define_method("put", method!(Store::put, 1))?;
        store.define_method("fetch", method!(Store::fetch, 1))?;
        store.define_method("key?", method!(Store::key_p, 1))?;
        store.define_method("size", method!(Store::size, 0))?;

        let timeline = ext.define_class("Timeline", ruby.class_object())?;
        timeline.define_error("CrossStore", lain_error)?;
        // Built only by `ancestors`; nothing constructs one from Ruby.
        let walk = timeline.define_class("Walk", ruby.class_object())?;
        walk.undef_default_alloc_func();
        walk.define_singleton_method("live", function!(Walk::live, 0))?;
        timeline.define_singleton_method("empty", function!(Timeline::empty, -1))?;
        timeline.define_singleton_method("new", function!(Timeline::new, 1))?;
        timeline.define_method("correlation", method!(Timeline::correlation, 0))?;
        timeline.define_method("empty?", method!(Timeline::empty_p, 0))?;
        timeline.define_method("head", method!(Timeline::head, 0))?;
        timeline.define_method("head_digest", method!(Timeline::head_digest, 0))?;
        timeline.define_method("store", method!(Timeline::store, 0))?;
        timeline.define_method("commit", method!(Timeline::commit, 1))?;
        timeline.define_method("fork", method!(Timeline::fork, 0))?;
        timeline.define_method("checkout", method!(Timeline::checkout, 1))?;
        timeline.define_method("rewind", method!(Timeline::rewind, -1))?;
        timeline.define_method("ancestors", method!(Timeline::ancestors, 0))?;
        timeline.define_method("ancestor_digests", method!(Timeline::ancestor_digests, 0))?;
        timeline.define_method("to_a", method!(Timeline::to_a, 0))?;
        timeline.define_method("messages", method!(Timeline::messages, -1))?;
        timeline.define_method("consumed", method!(Timeline::consumed, 1))?;
        timeline.define_method("length", method!(Timeline::length, 0))?;
        timeline.define_method("include?", method!(Timeline::include_p, 1))?;
        timeline.define_method("ancestor_of?", method!(Timeline::ancestor_of_p, 1))?;
        timeline.define_method("meet", method!(Timeline::meet, 1))?;
        timeline.define_method("&", method!(Timeline::meet, 1))?;
        timeline.define_method("diverge_at", method!(Timeline::diverge_at, 1))?;
        timeline.define_method("dominator_meet", method!(Timeline::dominator_meet, 1))?;
        timeline.define_method("dominates?", method!(Timeline::dominates_p, 1))?;
        timeline.define_method("causal_meets", method!(Timeline::causal_meets, 1))?;
        timeline.define_method("==", method!(<Timeline as typed_data::IsEql>::is_eql, 1))?;
        timeline.define_method("eql?", method!(<Timeline as typed_data::IsEql>::is_eql, 1))?;
        timeline.define_method("hash", method!(<Timeline as typed_data::Hash>::hash, 0))?;
        timeline.define_method("to_s", method!(Timeline::to_s, 0))?;
        timeline.define_method("inspect", method!(Timeline::inspect, 0))?;

        // The orders themselves, named: stateless classes whose singleton
        // methods take two `Ext::Timeline`s as elements. Each registers the
        // same generic function its timeline binding delegates to, so the two
        // spellings cannot come to answer differently. `CausalAncestry` gets
        // no `meet` because it has no greatest lower bound to give.
        let dag_orders = ext.define_module("Dag")?;
        let render_ancestry = dag_orders.define_class("RenderAncestry", ruby.class_object())?;
        render_ancestry
            .define_singleton_method("meet", function!(Timeline::meet_via::<RenderAncestry>, 2))?;
        render_ancestry.define_singleton_method(
            "below?",
            function!(Timeline::below_via::<RenderAncestry>, 2),
        )?;
        let dominance = dag_orders.define_class("Dominance", ruby.class_object())?;
        dominance.define_singleton_method("meet", function!(Timeline::meet_via::<Dominance>, 2))?;
        dominance
            .define_singleton_method("below?", function!(Timeline::below_via::<Dominance>, 2))?;
        let causal_ancestry = dag_orders.define_class("CausalAncestry", ruby.class_object())?;
        causal_ancestry.define_singleton_method("meets", function!(Timeline::causal_meets, 2))?;

        Ok(())
    }
}

#[cfg(test)]
mod num_class_tests {
    use super::{NumClass, classify_num};

    #[test]
    fn classifies_a_small_integer() {
        assert_eq!(classify_num("1").unwrap(), NumClass::Small(1));
    }

    #[test]
    fn classifies_a_negative_integer() {
        assert_eq!(classify_num("-3").unwrap(), NumClass::Small(-3));
    }

    #[test]
    fn classifies_decimal_float_text() {
        assert_eq!(classify_num("1.5").unwrap(), NumClass::Float(1.5));
    }

    #[test]
    fn classifies_exponent_float_text() {
        assert_eq!(classify_num("2e10").unwrap(), NumClass::Float(2e10));
    }

    #[test]
    fn classifies_a_bignum_beyond_i64() {
        // i64::MAX is 9223372036854775807; one digit further overflows it.
        assert_eq!(classify_num("99999999999999999999").unwrap(), NumClass::Big);
    }

    #[test]
    fn classifies_a_negative_bignum_beyond_i64() {
        assert_eq!(
            classify_num("-99999999999999999999").unwrap(),
            NumClass::Big
        );
    }

    #[test]
    fn rejects_non_numeric_garbage() {
        let err = classify_num("abc").expect_err("garbage text must not classify");
        assert!(err.contains("abc"), "unexpected message: {err}");
    }

    #[test]
    fn rejects_empty_text() {
        classify_num("").expect_err("empty text must not classify");
    }

    #[test]
    fn rejects_malformed_float_text() {
        // Contains '.' so it takes the float branch, but is not valid float text.
        let err = classify_num("1.2.3").expect_err("malformed float text must not classify");
        assert!(err.contains("1.2.3"), "unexpected message: {err}");
    }

    #[test]
    fn rejects_bare_sign_text() {
        classify_num("-").expect_err("a lone sign must not classify as a bignum");
    }
}

#[cfg(test)]
mod put_tests {
    use super::{DanglingPut, DigestMismatch, PutRefusal, put_into, validate_put, verified};
    use crate::canonical::{Canon, build_object};
    use crate::dag::{BlobData, CanonData, NodeData, Objects};
    use crate::digest::Digest;
    use crate::event::{EventData, Kind, Role};
    use std::sync::Arc;

    fn text(body: &str) -> Canon {
        Canon::Array(vec![Canon::Object(
            build_object(vec![("text".to_string(), Canon::Str(body.to_string()))]).unwrap(),
        )])
    }

    fn digest(text: &str) -> Digest {
        Digest::from(text.to_string())
    }

    fn event(body: &str, parent: Option<&Digest>) -> Arc<EventData> {
        EventData::turn(
            Role::User,
            text(body),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            Vec::new(),
        )
    }

    fn node(body: &str, parent: Option<&Digest>) -> NodeData {
        NodeData::Event(event(body, parent))
    }

    fn payload_of(node: &NodeData) -> NodeData {
        match node {
            NodeData::Event(event) => {
                NodeData::Payload(Arc::clone(event.payload.as_ref().expect("carried")))
            }
            other => panic!("expected an event, got {other:?}"),
        }
    }

    fn detached(event: &EventData) -> NodeData {
        NodeData::Event(EventData::detached(
            event.kind,
            None,
            None,
            event.render_parent.clone(),
            event.causal_parents.clone(),
            None,
            event.payload_digest.clone(),
        ))
    }

    fn put_all(objects: Objects, nodes: &[NodeData]) -> Objects {
        nodes.iter().fold(objects, |objects, node| {
            put_into(&objects, node).expect("a well-ordered put").0
        })
    }

    fn holding(nodes: &[&NodeData]) -> Objects {
        let ordered: Vec<NodeData> = nodes
            .iter()
            .flat_map(|node| [payload_of(node), (*node).clone()])
            .collect();
        put_all(Objects::empty(), &ordered)
    }

    #[test]
    fn accepts_a_root_whose_payload_is_present() {
        let root = node("a", None);
        let objects = put_all(Objects::empty(), &[payload_of(&root)]);
        assert_eq!(validate_put(&objects, &root), Ok(()));
    }

    #[test]
    fn accepts_a_child_whose_parent_is_present() {
        let root = node("a", None);
        let child = node("b", Some(root.digest()));
        let objects = put_all(holding(&[&root]), &[payload_of(&child)]);
        assert_eq!(validate_put(&objects, &child), Ok(()));
    }

    #[test]
    fn refuses_a_child_whose_parent_is_absent() {
        let absent = digest("blake3:absent");
        let child = node("b", Some(&absent));
        assert_eq!(
            validate_put(&Objects::empty(), &child),
            Err(DanglingPut {
                parent: absent,
                child: child.digest().clone(),
                noun: "object",
            })
        );
    }

    // The payload is a Store edge, checked after the render edge and before
    // the causal set -- the deleted Ruby `Store#parent_edges`' order.
    #[test]
    fn refuses_an_envelope_whose_payload_is_absent() {
        let root = node("a", None);
        let NodeData::Event(event) = &root else {
            panic!("built an event")
        };
        assert_eq!(
            validate_put(&Objects::empty(), &root),
            Err(DanglingPut {
                parent: event.payload_digest.clone(),
                child: event.digest.clone(),
                noun: "object",
            })
        );
    }

    // The causal set is a Store edge exactly as the render edge is (as in the
    // deleted Ruby `Store#parent_edges`); the refusal names the FIRST dangling edge, and
    // causal parents check in their pinned sorted order.
    #[test]
    fn refuses_a_child_whose_causal_parent_is_absent() {
        let root = node("a", None);
        let child = NodeData::Event(EventData::turn(
            Role::User,
            text("b"),
            Some(root.digest().clone()),
            Canon::Object(vec![]),
            None,
            vec![digest("blake3:msg-b"), digest("blake3:msg-a")],
        ));
        let objects = put_all(holding(&[&root]), &[payload_of(&child)]);
        assert_eq!(
            validate_put(&objects, &child),
            Err(DanglingPut {
                parent: digest("blake3:msg-a"),
                child: child.digest().clone(),
                noun: "object",
            })
        );
    }

    #[test]
    fn a_canonical_parent_is_an_edge_and_nothing_else_is() {
        let parent_tree = |parent: &str| {
            Canon::Object(
                build_object(vec![
                    ("id".to_string(), Canon::Str("a".to_string())),
                    ("parent".to_string(), Canon::Str(parent.to_string())),
                ])
                .unwrap(),
            )
        };
        let orphan = NodeData::Canon(Arc::new(CanonData::new(parent_tree("blake3:absent"))));
        let item = NodeData::Canon(Arc::new(CanonData::new(Canon::Str("item".to_string()))));
        assert_eq!(
            validate_put(&Objects::empty(), &orphan),
            Err(DanglingPut {
                parent: digest("blake3:absent"),
                child: orphan.digest().clone(),
                noun: "object",
            })
        );
        assert_eq!(validate_put(&Objects::empty(), &item), Ok(()));
    }

    #[test]
    fn a_causal_parent_that_is_a_payload_is_refused_as_no_event() {
        let root = node("a", None);
        let held = payload_of(&root);
        let child = NodeData::Event(EventData::turn(
            Role::User,
            text("b"),
            None,
            Canon::Object(vec![]),
            None,
            vec![held.digest().clone()],
        ));
        let objects = put_all(Objects::empty(), &[held.clone(), payload_of(&child)]);
        assert_eq!(
            validate_put(&objects, &child),
            Err(DanglingPut {
                parent: held.digest().clone(),
                child: child.digest().clone(),
                noun: "event",
            })
        );
    }

    #[test]
    fn a_render_parent_that_is_a_canonical_value_is_refused_as_no_event() {
        let tree = NodeData::Canon(Arc::new(CanonData::new(Canon::Str("item".to_string()))));
        let child = node("b", Some(tree.digest()));
        let objects = put_all(Objects::empty(), &[tree.clone(), payload_of(&child)]);
        assert_eq!(
            validate_put(&objects, &child),
            Err(DanglingPut {
                parent: tree.digest().clone(),
                child: child.digest().clone(),
                noun: "event",
            })
        );
    }

    #[test]
    fn a_payload_edge_or_canonical_parent_naming_an_event_is_refused_as_no_member() {
        let root = node("a", None);
        let NodeData::Event(event) = &root else {
            panic!("built an event")
        };
        let objects = holding(&[&root]);
        let pointing = NodeData::Event(EventData::detached(
            Kind::Turn,
            None,
            None,
            None,
            Vec::new(),
            None,
            event.digest.clone(),
        ));
        let tree = Canon::Object(
            build_object(vec![(
                "parent".to_string(),
                Canon::Str(event.digest.to_string()),
            )])
            .unwrap(),
        );
        let orphan = NodeData::Canon(Arc::new(CanonData::new(tree)));
        for child in [pointing, orphan] {
            assert_eq!(
                validate_put(&objects, &child),
                Err(DanglingPut {
                    parent: event.digest.clone(),
                    child: child.digest().clone(),
                    noun: "member",
                })
            );
        }
    }

    #[test]
    fn a_detached_envelope_is_stored_carrying_the_payload_its_edge_names() {
        let whole = node("a", None);
        let NodeData::Event(carrying) = &whole else {
            panic!("built an event")
        };
        let objects = put_all(Objects::empty(), &[payload_of(&whole), detached(carrying)]);
        match objects.get(whole.digest()) {
            Some(NodeData::Event(stored)) => assert_eq!(stored.body(), carrying.body()),
            other => panic!("expected the envelope, got {other:?}"),
        }
    }

    #[test]
    fn a_detached_envelope_whose_payload_edge_names_another_kind_is_refused() {
        let whole = node("a", None);
        let NodeData::Event(carrying) = &whole else {
            panic!("built an event")
        };
        let mislabelled = NodeData::Event(EventData::detached(
            Kind::Message,
            None,
            None,
            None,
            Vec::new(),
            None,
            carrying.payload_digest.clone(),
        ));
        let objects = put_all(Objects::empty(), &[payload_of(&whole)]);
        assert_eq!(
            put_into(&objects, &mislabelled).map(|(_, digest)| digest),
            Err(PutRefusal::NotItsPayload {
                payload: carrying.payload_digest.clone(),
                child: mislabelled.digest().clone(),
            })
        );
    }

    #[test]
    fn every_arm_shares_one_keyspace_and_one_count() {
        let root = node("a", None);
        let blob = NodeData::Blob(Arc::new(BlobData::new("blob", b"bytes".to_vec())));
        let tree = NodeData::Canon(Arc::new(CanonData::new(Canon::Str("tree".to_string()))));
        let objects = put_all(holding(&[&root]), &[blob.clone(), tree.clone()]);
        assert_eq!(objects.size(), 4);
        for held in [&root, &payload_of(&root), &blob, &tree] {
            assert!(objects.contains(held.digest()));
        }
    }

    #[test]
    fn a_blob_is_addressed_by_its_tagged_header() {
        // `Lain::Workspace::Snapshot::Blob.new(bytes: "puts 1\n").digest`.
        let blob = BlobData::new("blob", b"puts 1\n".to_vec());
        assert_eq!(
            blob.digest.as_str(),
            "blake3:c1fe670e201b743d8e4d2edc3fdf1441e07720eb15601312bcab7045ded1b3c0"
        );
        assert_ne!(
            BlobData::new("attachment", b"puts 1\n".to_vec()).digest,
            blob.digest
        );
    }

    #[test]
    fn a_claimed_digest_that_is_not_the_contents_is_refused() {
        let tree = NodeData::Canon(Arc::new(CanonData::new(Canon::Str("tree".to_string()))));
        let actual = tree.digest().clone();
        assert!(verified(tree.clone(), actual.clone()).is_ok());
        assert_eq!(
            verified(tree, digest("blake3:forged")).map(|node| node.digest().clone()),
            Err(DigestMismatch {
                claimed: digest("blake3:forged"),
                actual,
            })
        );
    }

    // -------------------------------------------------------------------
    // The store law. EXACTLY the two the Ruby group declares, and no third.
    //
    // `put` is idempotent, because the address IS the content, in both of the
    // forms `spec/support/shared_examples/store_laws.rb` asserts: the same
    // object twice, and two structurally equal objects built independently.
    // That file is the authority on which store laws exist -- everything under
    // this banner, down to the fence below, is a law and nothing else. Proven here
    // against the pure decision, with no `magnus` and no Ruby VM; that the
    // Rust BINDING obeys them is the business of `spec/lain/rust/store_spec.rb`,
    // and agreement with the deleted Ruby is the corpus's (`store.ndjson`).
    // -------------------------------------------------------------------

    #[test]
    fn putting_the_same_object_twice_is_idempotent() {
        let object = payload_of(&node("a", None));
        let (once, first) = put_into(&Objects::empty(), &object).expect("a payload put");
        let (twice, second) = put_into(&once, &object).expect("a re-put");
        assert_eq!(first, second);
        assert_eq!(twice.size(), 1);
    }

    #[test]
    fn structurally_equal_content_is_one_object() {
        // Two nodes built independently from the same body: content-addressing
        // means they share an address, so the second put cannot grow the store.
        let (once, first) =
            put_into(&Objects::empty(), &payload_of(&node("a", None))).expect("first put");
        let (twice, second) =
            put_into(&once, &payload_of(&node("a", None))).expect("an equal-content put");
        assert_eq!(first, second);
        assert_eq!(twice.size(), 1);
    }

    // -------------------------------------------------------------------
    // Characterization, NOT a law. Below the banner above deliberately.
    // -------------------------------------------------------------------

    // Characterizes the `contains` shortcut in `put_into`: a digest already
    // present returns early, so the re-put never revalidates its edges. The
    // shipped append-only `Store` cannot reach the objects this builds -- only
    // removing from a map can drop a parent out from under a child -- so this
    // pins an implementation choice, not a property of the store. It is NOT a
    // third store law: `store_laws.rb` declares two, and Rust asserts that same
    // two (see `ext/lain/CLAUDE.md`, "a ported structure inherits the Ruby
    // declaration"). Kept because the shortcut is what makes a re-put idempotent
    // against objects whose edges have since changed, and a future refactor that
    // dropped it would otherwise go unnoticed.
    #[test]
    fn a_re_put_returns_early_without_revalidating_edges() {
        let root = node("a", None);
        let child = node("b", Some(root.digest()));
        let with_child = put_all(holding(&[&root]), &[payload_of(&child), child.clone()]);
        let first = child.digest().clone();
        // Re-put against objects that no longer hold the parent: still
        // accepted, still one write, still the same address.
        let orphaned = Objects {
            events: with_child.events.remove(root.digest()),
            members: with_child.members.clone(),
        };
        let (again, second) = put_into(&orphaned, &child).expect("a re-put skips validation");
        assert_eq!(first, second);
        assert_eq!(again.size(), orphaned.size());
    }

    // The Display IS the FFI-visible message; the deleted Ruby `Store#put` pinned the same
    // bytes (`no object #{parent.inspect} in store: putting #{digest.inspect}
    // would dangle`), and `Digest`'s transparent `Debug` is what keeps the two
    // byte-identical for plain digests.
    #[test]
    fn dangling_put_message_matches_ruby_string_inspect() {
        let child = node("b", Some(&digest("blake3:absent")));
        let message = validate_put(&Objects::empty(), &child)
            .unwrap_err()
            .to_string();
        assert_eq!(
            message,
            format!(
                r#"no object "blake3:absent" in store: putting "{}" would dangle"#,
                child.digest()
            )
        );
    }
}

#[cfg(test)]
mod rewind_tests {
    use super::rewind_to;
    use crate::canonical::Canon;
    use crate::dag::{DanglingDigest, StoreMap};
    use crate::digest::Digest;
    use crate::event::{EventData, Role};
    use std::sync::Arc;

    fn node(body: &str, parent: Option<&Digest>) -> Arc<EventData> {
        EventData::turn(
            Role::User,
            Canon::Str(body.to_string()),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            Vec::new(),
        )
    }

    /// A three-node chain, root first.
    fn chain() -> (StoreMap, Vec<Arc<EventData>>) {
        let root = node("a", None);
        let middle = node("b", Some(&root.digest));
        let head = node("c", Some(&middle.digest));
        let map = [&root, &middle, &head]
            .into_iter()
            .fold(StoreMap::new_sync(), |map: StoreMap, event| {
                map.insert(event.digest.clone(), Arc::clone(event))
            });
        (map, vec![root, middle, head])
    }

    #[test]
    fn zero_steps_is_the_identity() {
        let (map, nodes) = chain();
        let head = Some(nodes[2].digest.clone());
        assert_eq!(rewind_to(&map, head.clone(), 0), Ok(head));
    }

    #[test]
    fn one_step_lands_on_the_render_parent() {
        let (map, nodes) = chain();
        assert_eq!(
            rewind_to(&map, Some(nodes[2].digest.clone()), 1),
            Ok(Some(nodes[1].digest.clone()))
        );
    }

    // Rewinding past the root lands on the empty Timeline rather than raising,
    // exactly as the deleted Ruby `Timeline#rewind` did -- `None` absorbs further steps.
    #[test]
    fn rewinding_past_the_root_absorbs_to_empty() {
        let (map, nodes) = chain();
        assert_eq!(rewind_to(&map, Some(nodes[2].digest.clone()), 3), Ok(None));
        assert_eq!(rewind_to(&map, Some(nodes[2].digest.clone()), 99), Ok(None));
        assert_eq!(rewind_to(&map, None, 1), Ok(None));
    }

    // The question the four tests above do not ask: what does TERMINATION cost?
    // The walk runs under the Store's mutex and the GVL, so a loop bounded by
    // the caller's count rather than by the chain is a mutex held for as long as
    // the caller cares to ask for -- `i64::MAX` steps at ~2e9 steps/s is on the
    // order of a century. Bounded by the chain, this returns in three steps. A
    // regression does not fail this test, it HANGS it, which is the loudest
    // signal available for a liveness property.
    #[test]
    fn a_rewind_far_past_the_root_terminates_at_the_chain_length() {
        let (map, nodes) = chain();
        assert_eq!(
            rewind_to(&map, Some(nodes[2].digest.clone()), i64::MAX),
            Ok(None)
        );
    }

    // A corrupt chain is NOT a root: the step off a digest the map does not hold
    // answers `Err`, which the FFI caller turns into `Store::MissingObject`
    // after its lock has dropped.
    #[test]
    fn a_dangling_edge_is_an_error_not_an_empty_timeline() {
        let absent = Digest::from("blake3:absent".to_string());
        assert_eq!(
            rewind_to(&StoreMap::new_sync(), Some(absent.clone()), 1),
            Err(DanglingDigest(absent))
        );
    }
}

#[cfg(test)]
mod non_finite_tests {
    use super::non_finite;

    #[test]
    fn names_the_value_as_ruby_float_to_s_does() {
        assert_eq!(non_finite(f64::NAN), "cannot canonicalize NaN");
        assert_eq!(non_finite(f64::INFINITY), "cannot canonicalize Infinity");
        assert_eq!(
            non_finite(f64::NEG_INFINITY),
            "cannot canonicalize -Infinity"
        );
    }
}

#[cfg(test)]
mod depth_tests {
    use super::{MAX_CANON_DEPTH, descend};

    #[test]
    fn descends_to_the_bound() {
        assert_eq!(descend(0), Ok(1));
        assert_eq!(descend(MAX_CANON_DEPTH - 1), Ok(MAX_CANON_DEPTH));
    }

    #[test]
    fn refuses_the_level_past_the_bound() {
        let err = descend(MAX_CANON_DEPTH).expect_err("one past the bound must be refused");
        assert_eq!(
            err,
            "cannot canonicalize a structure nested deeper than 100 levels"
        );
    }

    // The number is Ruby's, not ours: `JSON.generate`'s default `max_nesting`
    // is 100, so `Canonical.dump` refuses at 101 too (verified on 4.0.6, and
    // pinned live from both sides in rust/canonical_spec.rb). Restating it here
    // means a change to the constant has to be a deliberate edit to a test that
    // says where the number came from.
    #[test]
    fn the_bound_is_ruby_json_generates_own_max_nesting() {
        assert_eq!(MAX_CANON_DEPTH, 100);
    }

    #[test]
    fn refusal_stays_refusal_however_far_past_the_bound() {
        descend(MAX_CANON_DEPTH * 10).expect_err("a much deeper structure is refused too");
    }
}

#[cfg(test)]
mod blake3_tests {
    use super::blake3_hex;

    // Official BLAKE3 test vector for the empty input.
    #[test]
    fn hashes_the_empty_string() {
        assert_eq!(
            blake3_hex(b""),
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        );
    }

    // Official BLAKE3 test vector for a 1024-byte input -- the first size that
    // spans more than one 1024-byte chunk boundary, so it exercises the tree
    // hashing the empty-string vector never reaches. Real canonical dumps easily
    // exceed one chunk. Input is byte `i % 251`; the expected digest was checked
    // independently with `b3sum`.
    #[test]
    fn hashes_a_multi_chunk_input() {
        let input: Vec<u8> = (0..1024).map(|i| (i % 251) as u8).collect();
        assert_eq!(
            blake3_hex(&input),
            "42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7"
        );
    }

    #[test]
    fn is_deterministic() {
        assert_eq!(blake3_hex(b"lain"), blake3_hex(b"lain"));
    }

    #[test]
    fn differs_for_different_input() {
        assert_ne!(blake3_hex(b"lain"), blake3_hex(b"not lain"));
    }

    #[test]
    fn returns_lowercase_hex() {
        let hex = blake3_hex(b"lain");
        assert_eq!(hex, hex.to_lowercase());
        assert_eq!(hex.len(), 64);
    }
}
