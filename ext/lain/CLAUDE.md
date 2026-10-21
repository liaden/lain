# Working on `ext/lain` (the in-process Rust extension)

This crate is **pure and synchronous**. It exists for Rust's *data model* — ownership, cheap
immutability, structural sharing — not for speed. See `docs/rust-bindings.md` for the five tests
a capability must pass before it gets a binding at all.

Anything **async, I/O-bound, or isolation-relevant** belongs in `crates/lain-core` (tokio,
msgpack-RPC over a Unix socket), not here. Driving an async runtime from inside a magnus FFI call
while holding the GVL is a known footgun, and an "in-process sandbox" is not a sandbox.

## Toolchain

```bash
cargo test                                  # 287/287 on 2026-10-20 (`-p lain`); must not regress
cargo clippy --all-targets -- -D warnings   # warnings are errors
cargo doc --no-deps                         # clean; broken intra-doc links are denied
cargo fmt -- --check                        # pre-commit runs this, not `cargo fmt`
cargo deny check                            # wildcard versions are banned; pin every dep
bundle exec rake compile                    # builds into lib/lain/lain.so (gitignored)
```

All four run in `pre-commit` on **every** worktree, because `core.hooksPath` is unset and
`.git/hooks` is shared. There is no "I'll format it later."

> ⚠️ **`cargo test` never compiles the magnus surface, so a green `cargo test` is not a
> building crate.** Every `ffi` module here is `#[cfg(not(test))]` — `lib.rs`'s `mod ffi`,
> `prompt.rs:1397`, `fuzzy.rs:323`, `astgrep.rs:984`, `treesitter.rs:431`, and the whole of
> `nogvl/ffi.rs` — and there is no `tests/` directory and no doctest target, so under
> `--cfg test` the entire FFI layer is absent from the build graph. The comment above `lib.rs`'s `mod ffi` explains *why* the modules
> are gated (a magnus item needs an embedded Ruby VM that `cargo test` has no way to start) but never says what
> it costs you.
>
> What it costs: change a pure module's public shape and `cargo test` will pass while the
> crate does not build. Verified, not suspected — renaming one variant of `bm25.rs`'s
> `BuildError` gave `cargo test` 190 passed and `cargo check -p lain --lib`
> `error[E0599]`. It bites hardest on **error enums**, because `lib.rs`'s FFI match arms are
> exhaustive with no fallback, so adding a variant is an `E0004` that only the real build
> sees.
>
> So `cargo test` alone never clears a change to an enum, a `pub fn` signature, or anything
> `ffi` names. Run `cargo clippy --all-targets -- -D warnings` (which builds the lib without
> `--cfg test`) or `bundle exec rake compile` before believing you are green. This is exactly
> why a task card can say "shared-file wiring: none" and be wrong.

## Hard rules

- **Stable channel only. No `#![feature]`.** A subagent has already shipped `#![feature]` here
  and it does not build. If you reach for a nightly feature, the design is wrong.
- **No `forbid(unsafe_code)` here.** That rule is `crates/lain-core`'s
  (`crates/lain-core/src/main.rs:13`), not this crate's. `ext/lain` has 16 `unsafe {` blocks
  (`grep -rc 'unsafe {' ext/lain/src`, 2026-10-21). 9 are FFI-boundary calls in magnus's own
  unsafe API, 1 is the `rb_nogvl` call below, and the other 6 sit in the 2 counting global
  allocators, `lib.rs`'s `heap` (the extension's, behind `Lain::Ext::Probe.live_bytes`) and
  `dag.rs`'s test-only one, each an `unsafe impl GlobalAlloc` forwarding to `System`. None can be
  removed, and forbidding them would not compile. Every one carries a `SAFETY:` comment; that is
  the standard here. The root `CLAUDE.md`'s "NO `unsafe` in lain's Rust" means *do not hand-roll
  new unsafe* — reach for a crate — not that the existing FFI boundary is a defect.
- **The one hand-rolled exception is the `rb_nogvl` call in `nogvl/ffi.rs`** (ruled
  2026-10-21). No crate releases the GVL with an unblocking function: magnus 0.9.3 wraps no GVL
  API, and its open PR 171 and lucchetto 0.4.0 both pass none, so a kill could not stop the work.
  The block is the call alone. Both callbacks are safe fns, because the `void*` they get is a slot
  index into a static table, never a pointer they dereference. A binding that needs the GVL
  released calls `nogvl::without_gvl` rather than adding a second block. Its job reads its stop
  request through `Cancel::requested` and returns `Halted`.
- **Two doc lints, and only one of them bites today.** The crate-root `missing_docs` is just the
  `pub mod` tripwire: it only sees items reachable as public API from `lib.rs`, and every module
  here is private, so its scope is **zero items**. Do not read it as evidence the crate is
  documented — on its own it would not notice a doc comment deleted anywhere in `ext/lain`.
  The enforcing lint is **scoped**: `#[deny(clippy::missing_docs_in_private_items)]` sits on
  `mod algebra;`, `mod dag;`, `mod digest;` and `mod graph;`, the modules carrying the algebraic
  claims. All are at zero offenses, and deleting a doc comment in any of them is a hard error.
  Crate-wide that lint would report 109 and stays off — filler comments on 109 items are worse
  than none. **If you add a module carrying a law, put the scoped deny on it too**;
  that, not the root deny, is what protects a documented claim.
- **Intra-doc links are a crate-root `deny`** (`rustdoc::broken_intra_doc_links`,
  `rustdoc::private_intra_doc_links`), and `cargo doc --no-deps` is clean. Note the trap that
  motivated it: a `[`link`]` into a **private** module (`ffi`, `dag`) does not resolve and only
  warns, so a doc comment can quietly rot. Use plain backticks for private items.
- **Output discipline is a crate-root `deny`.** `clippy::print_stdout` and `clippy::print_stderr`
  are hard errors. This is not fussiness: the Journal is NDJSON, it is the experiment record, and
  one stray line makes `JSON.parse` fail on that line. We learned it the hard way — a subscriber
  wrote to stderr and Bundler interleaved a plain-text warning into it. This crate emits no
  diagnostics of its own; an error crosses the boundary as a Ruby exception.
- **Pin every dependency.** `cargo deny` bans wildcards.
- **No crate here may own, drive, or interrogate a terminal — and none may read the
  environment to decide colour.** `NO_COLOR`, `FORCE_COLOR`, `TERM` and `isatty` are properties
  of the stream **Ruby** owns. Ruby resolves them and passes the answer across the boundary as
  an argument; `Lain::Ext::Prompt#render(vars, color:)` takes `color` as a **required** keyword
  for that reason, because a default would let a caller forget who is entitled to answer. This
  is the `anstyle`-over-`console` rule: `anstyle` is style *value types* with zero runtime
  dependencies and no env access, while `console`/`termcolor` decide colour for you from inside
  a `.so` you cannot see into. The rule is mechanical, not remembered —
  `deny.toml`'s `[bans] deny` list refuses `crossterm`, `termion`, `termwiz`, `console`,
  `termcolor`, `terminal_size` and `onig_sys` **workspace-wide**, so it binds
  `crates/lain-core` too. If a crate you want pulls one of them in, that crate is answering a
  question in the wrong process — stop, do not add an exception.
- **Vendored source needs a `NOTICE` entry; the licence allow-list does not cover it.**
  `deny.toml`'s `allow` list governs crates resolved from crates.io. Grammar, algorithms, or
  tables copied *into* this repository are outside its reach, and `ext/lain/NOTICE` is where
  their attribution lives (today: starship's prompt-format grammar, ISC).
- **`cargo fmt` before you commit**, not after the hook rejects you.

## Testing shape

Keep the logic in **plain Rust functions with no `magnus` types in their signatures**, and put the
FFI surface in a separate module. `validate_put` and `classify_num` are the pattern: they are
unit-testable without an embedded Ruby VM, which is why `cargo test` runs at all. A function that
takes a `Ruby` or returns a `magnus::Error` cannot be tested in `cargo test`; push the decision out
of it and test the decision.

## When porting a Ruby structure down here (M4)

Until 2026-10-20 the rule was the 2026-07-17 Ruby-first ruling: "`Timeline` ships as pure Ruby
first. The port is correct **only** when the existing `Regular` and `MeetSemilattice` property
tests pass unchanged against *both* implementations — that is the acceptance test, and it is why
the Ruby version is not deleted when the Rust one lands." It held while the Ruby was the only
statement of what the answers were.

It is reversed. The Ruby `Event`, `Store` and `Timeline` were deleted on 2026-10-20, because "a
differential test proves agreement, not correctness — if both sides share a wrong assumption it
passes green forever" (`planning/specs/simplify-13-rust-port.md`, 2026-09-12). A port is now
correct when 3 things hold, and the Ruby it replaces may then go:

- **The laws are stated natively**, as `proptest` properties in `cargo test`, under the same law
  names as the Ruby shared group (see below), and the shared groups still run unchanged in
  `spec/lain/rust/*` against the binding.
- **The Ruby's answers are frozen first**, as a conformance corpus under `ext/lain/corpus/`
  (5 NDJSON files, each held at the blake3 digest `MANIFEST.json` records). `src/corpus.rs` reads
  it in `cargo test`; `spec/conformance_corpus_spec.rb` reads it through the compiled extension.
  `MANIFEST.json`'s `ruby_oracle_retired` names the commit after which a vector stopped
  re-deriving from Ruby, and `divergences` lists every place the extension answers differently on
  purpose. Only the canonical vectors still have a Ruby to re-derive from.
- **The tests constrain the code**, measured by `bundle exec rake rust:mutants`: `cargo-mutants`
  over the address-computing and graph modules, failing unless the killed, unviable and missed
  counts equal `ext/lain/mutants-baseline.txt`.

> ⚠️ **A magnus-wrapped `TypedData` object is not `Ractor.shareable?` for free.** `Ractor.shareable?(turn)`
> must stay `true` — it is the mechanical statement of "no reachable mutable state", and there is a
> spec. Establish shareability deliberately; do not weaken the spec to accommodate the port.

Batch across the boundary. A per-node FFI call in a DAG walk loses to plain Ruby, because
conversion cost dominates almost every naive binding. If a port is not asymptotically better, it is
not better.

**One walk crosses per node, on purpose: the block form of `Ext::Timeline#ancestors`.** It is lazy
because its callers stop early (`take_while`, `find`), so a walk pays for the nodes it read and not
for the chain. Every other walk (`to_a`, `ancestor_digests`, `messages`) still crosses once with a
built Array. What makes the lazy one safe is where its state lives: the snapshot and the cursor are
in a `Lain::Ext::Timeline::Walk`, an object Ruby's collector owns, and each node's wrapper goes
straight to `rb_yield`. A new per-node crossing needs the same 2 reasons: a caller that stops early,
and state the collector can free.

**Rust never holds owned heap state across a call into Ruby.** A fiber dropped while suspended
inside that call is collected without being unwound, so a Rust frame waiting in it never runs its
destructors, and whatever it owns leaks where no Ruby-side measure can see it. A site that calls
into Ruby does one of 3 things:

- It makes every Ruby call before it builds any Rust state (`read_node`).
- It keeps its partial state in a holder the collector frees with the fiber (`Lain::Ext::Reading`
  for a canonical conversion, `Lain::Ext::Timeline::Walk` for a lazy walk).
- It refuses through a `Refusal` instead of building the exception itself. Building a `Lain`
  exception runs Ruby twice: the constant lookup can autoload, and the class's `#initialize` can
  run anything. So `lookup_error` renders its message into a Ruby String first, and its
  `message` closure is bound `FnOnce() -> String + 'static`. That bound is how the rule holds for
  what a message closure captures: the compiler refuses a closure that borrows caller state, so whatever it
  captures is owned and dropped once the message is rendered, before the lookup. A helper that
  still owns state when it refuses (`utf8`, `read_causal_parents`, `put_refusal` and their kin)
  returns `Refusal::Named(path, message)` or `Refusal::Built(error)`; the caller drops its state
  and only then raises.

`spec/support/reentry.rb` measures a site: it drops a suspended fiber 20 times and reads the live
Rust heap through `Lain::Ext::Probe.live_bytes`, which counts the global allocator in `lib.rs`'s
`heap` module. The bound is 1 payload. The `spec/lain/rust/*_reentry_spec.rb` files hold one
example per refusal reachable without a corrupt store (`refusal_reentry_spec.rb` has 12); a site
reachable only from a corrupt store, or covered by the `'static` bound alone, has none. A new
call into Ruby that a caller can reach gets its own example. The lazy walk is counted by
`Walk.live` instead, in `spec/lain/rust/timeline_spec.rb`.

### A ported algebraic structure keeps the Ruby law names; that is the whole contract

When the ported thing is algebraic — a semilattice, a monoid, a lattice — the Rust law tests carry
**the same law names** as the Ruby shared example group, and no others.
`spec/support/shared_examples/meet_semilattice.rb` names exactly four laws (idempotent,
commutative, associative, meet-below-both); `algebra.rs`'s `declare_meet_semilattice!` emits
those four, named to match, and invents no fifth. The names are the entire cross-language
contract: the two layers must not come to disagree about what a law *is*.

Do not reach for a `trait Monoid` or `trait MeetSemilattice` to "make it official". An algebra
trait earns its place only when a **production** Rust function is generic over the structure and
genuinely needs to be — a trait written solely so tests can call it is indirection with a law
attached, and it invites a second, drifting declaration of the same laws. `MeetSemilattice`
passed that test: `ffi`'s `Timeline::meet_via::<S>` and `Timeline::below_via::<S>` are generic
over it, and `Ext::Timeline#meet`, `#ancestor_of?`, `#dominator_meet`, `#dominates?` and the
`Ext::Dag::RenderAncestry` / `Ext::Dag::Dominance` singletons are those two functions at two
types. Clippy called the trait dead code until they were. The trait is sealed, and the macro that
writes the seal's impl is the same expansion that writes the law tests, so an order cannot claim
the structure without them. An order that is *not* a semilattice gets a different trait
(`CausalAncestry` implements `MaximalLowerBounds`), never a negative impl or a flag.

**The two suites prove different things, and a doc comment must say which.**

| Suite | Proves | Notes |
|---|---|---|
| `cargo test` | the Rust **algorithm** obeys the law | plain functions, no `magnus`, no VM — a layer the Ruby suite cannot reach |
| `spec/lain/rust/*` | the Rust **binding** obeys the same laws | runs the shared groups **unchanged** through the compiled extension |
| `src/corpus.rs` and `spec/conformance_corpus_spec.rb` | the extension answers what Ruby answered | the frozen corpus; the SOLE authority on agreement with the deleted Ruby |

Until 2026-10-20 the rule here was: "Never assert 'Rust equals Ruby' inside `cargo test`. If a Rust
test wants a Ruby value to compare against, it belongs in RSpec — the port acceptance rule above
depends on there being exactly one such authority" (from the 2026-07-27 algebra vocabulary chunk,
where a second Rust-native parity suite would have forked the differential oracle). The frozen
corpus broke it: `src/corpus.rs` compares Rust against Ruby's recorded answers inside
`cargo test`, and once the Ruby was deleted no live Ruby value is left to compare against in RSpec.
The reason survives as the rule: **there is exactly one authority on agreement with Ruby, and it
is the corpus.** A Rust test compares against a recorded vector, never against a value it computes
by re-implementing the Ruby, and a new disagreement goes into `MANIFEST.json`'s `divergences`
with its reason (through `spec/conformance/corpus_generator.rb`, which writes the manifest).

Testability follows the same rule the **Testing shape** section states: push the decision out of
the FFI method and test the decision. `put_into` was split out of `Store::put` for exactly this —
the method keeps the lock and the error translation, the pure function carries the idempotence law
and its proof.

**A law test asserts a declared law; everything else goes below the banner.** `algebra.rs`'s law
modules are macro-emitted and `lib.rs`'s law block is fenced with a comment naming the Ruby group
it inherits from; tests that merely characterize an implementation choice
(`a_re_put_returns_early_without_revalidating_edges` pins `put_into`'s `contains_key` shortcut)
sit *outside* that fence, labelled as characterization. A reader must never inherit a house rule
as though it were one of the declared laws.

## Scratch buffers go in a thread-local, not in the wrapped object

Plenty of good crates hand you a reusable scratch allocation and take `&mut self` for it.
`nucleo`'s `Matcher` is the case in hand: ~135 KB allocated eagerly, every matching method
`&mut self`, and upstream's own guidance is to hold one and reuse it rather than pay the
allocation per call. Put it in a field and the handle now reaches interior mutability, and
`frozen_shareable` — which is an *unchecked promise*, not a checked one — becomes a lie.

The answer is not to choose between reuse and shareability. Put the scratch in a
`thread_local!` static, keep the wrapped struct plain owned data, and both hold at once: the
allocation happens once per thread instead of once per call, and nothing mutable is reachable
*from the object*. `fuzzy.rs`'s `with_matcher` is the exemplar.

**What makes that safe today is the GVL plus `try_borrow_mut`, not Ractors.** Say it that way,
because the Ractor version of the argument is not available to us yet: no binding in this crate
calls `rb_ext_ractor_safe`, so while `Ractor.shareable?(handle)` is `true`, *calling any method
on it* from a non-main Ractor raises `Ractor::UnsafeError` — `Bm25#search` included. Shareable
and callable are different properties, and only the first one is true here. The thread-local is
the right shape for the day the second becomes true, since each Ractor is its own thread; do
not write that down as the reason it is correct now.

Three obligations come with it, and they are what make it honest rather than clever:

- **Reach the thread-local through `try_with` and `try_borrow_mut`, never `with`/`borrow_mut`.**
  Those panic — on TLS teardown and on re-entrancy respectively — and a panic unwinding into
  Ruby is undefined behaviour. The fallback allocates a fresh one; taking an `FnMut` is what
  lets both paths share the body.
- **Prove that reuse is observationally pure**, with a test that runs the same input through a
  reused scratch and a fresh one and asserts the same answer
  (`a_reused_matcher_agrees_with_a_fresh_one`). Without it, "the slab carries no semantic
  state" is a remembered claim about someone else's crate.
- **Do not let a `Send + Sync` assertion stand in for the interior-mutability audit.** A
  `const _: () = { assert_send::<T>(); assert_sync::<T>(); }` block is worth keeping — it
  catches `Rc`, `RefCell` and raw pointers — but it proves far less than it looks like it
  proves: `Mutex<T>`, `AtomicUsize` and `OnceLock` are all `Send + Sync` *and* interior-mutable,
  and sail straight through. `frozen_shareable` still rests on a written audit that a human
  read. Comment the block with what it actually catches, because a false mechanical claim is
  worse than no claim at all — the next person trusts it.

## An upstream constructor is not a contract; pin the index space with a test

Anything that hands back positions — match indices, spans, offsets — has an index space, and
the caller has to know whether it counts bytes, codepoints, or grapheme clusters. Upstream may
not be consistent about it. `nucleo`'s `Utf32Str::new` returns grapheme indices, *except* for a
string that is not ASCII but whose clusters all lead with an ASCII char (`"ne\u{301}on"`),
where it silently falls back to `Ascii(str.as_bytes())` and reports byte offsets. Verified, not
suspected; it would have mis-highlighted every accented candidate, and nothing would have
failed.

So: build the haystack yourself when the constructor branches, choose one index space, and
write the test that *states* it (`positions_index_grapheme_clusters_even_when_every_cluster_leads_with_ascii`)
rather than one that merely exercises the happy path. Then say which space it is in the doc
comment, in the Ruby terms the consumer will use — `String#grapheme_clusters` here, byte
offsets in `astgrep.rs`. Two bindings in this crate already disagree on that question, which is
fine as long as each says so.
