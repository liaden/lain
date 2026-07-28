# Working on `ext/lain` (the in-process Rust extension)

This crate is **pure and synchronous**. It exists for Rust's *data model* — ownership, cheap
immutability, structural sharing — not for speed. See the root `CLAUDE.md` section "Rust, and
which data structures earn a binding" for the five tests a structure must pass before it gets a
binding at all.

Anything **async, I/O-bound, or isolation-relevant** belongs in `crates/lain-core` (tokio,
msgpack-RPC over a Unix socket), not here. Driving an async runtime from inside a magnus FFI call
while holding the GVL is a known footgun, and an "in-process sandbox" is not a sandbox.

## Toolchain

```bash
cargo test                                  # 186/186 today; must not regress
cargo clippy --all-targets -- -D warnings   # warnings are errors
cargo doc --no-deps                         # clean; broken intra-doc links are denied
cargo fmt -- --check                        # pre-commit runs this, not `cargo fmt`
cargo deny check                            # wildcard versions are banned; pin every dep
bundle exec rake compile                    # builds into lib/lain/lain.so (gitignored)
```

All four run in `pre-commit` on **every** worktree, because `core.hooksPath` is unset and
`.git/hooks` is shared. There is no "I'll format it later."

## Hard rules

- **Stable channel only. No `#![feature]`.** A subagent has already shipped `#![feature]` here
  and it does not build. If you reach for a nightly feature, the design is wrong.
- **No `forbid(unsafe_code)` here.** That rule is `crates/lain-core`'s
  (`crates/lain-core/src/main.rs:13`), not this crate's. `ext/lain` has 10 `unsafe` blocks and
  they are FFI-boundary calls in magnus's own unsafe API plus `libc::dup` — they cannot be
  removed, and forbidding them would not compile. Every one carries a `SAFETY:` comment; that is
  the standard here. The root `CLAUDE.md`'s "NO `unsafe` in lain's Rust" means *do not hand-roll
  new unsafe* — reach for a crate — not that the existing FFI boundary is a defect.
- **Two doc lints, and only one of them bites today.** The crate-root `missing_docs` is just the
  `pub mod` tripwire: it only sees items reachable as public API from `lib.rs`, and every module
  here is private, so its scope is **zero items**. Do not read it as evidence the crate is
  documented — on its own it would not notice a doc comment deleted anywhere in `ext/lain`.
  The enforcing lint is **scoped**: `#[deny(clippy::missing_docs_in_private_items)]` sits on
  `mod dag;` and `mod digest;`, the modules carrying the algebraic claims. Both are already at
  zero offenses, so it cost no doc-writing diff, and deleting a doc comment in either is now a
  hard error. Crate-wide that lint would report 109 and stays off — filler comments on 109 items
  are worse than none. **If you add a module carrying a law, put the scoped deny on it too**;
  that, not the root deny, is what protects a documented claim.
- **Intra-doc links are a crate-root `deny`** (`rustdoc::broken_intra_doc_links`,
  `rustdoc::private_intra_doc_links`), and `cargo doc --no-deps` is clean. Note the trap that
  motivated it: a `[`link`]` into a **private** module (`ffi`, `dag`) does not resolve and only
  warns, so a doc comment can quietly rot. Use plain backticks for private items.
- **Output discipline is a crate-root `deny`.** `clippy::print_stdout` and `clippy::print_stderr`
  are hard errors. This is not fussiness: the Journal is NDJSON, it is the experiment record, and
  one stray line makes `JSON.parse` fail on that line. We learned it the hard way — the subscriber
  wrote to stderr and Bundler interleaved a plain-text warning into it. Diagnostics go through
  `tracing`, whose writer is a caller-supplied fd.
- **Pin every dependency.** `cargo deny` bans wildcards. `libc` is pinned at `0.2` for exactly
  this reason, and it is here solely for `dup(2)`.
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

## The two invariants that cost real debugging

**1. The fd is `dup`'d, and we own only the dup.** `init_tracing` takes a caller-supplied fd and
calls `libc::dup` before `File::from_raw_fd`. Dropping the Rust side must never close the
descriptor Ruby still owns. Cloning `SharedWriter` is an `Arc` bump — never another `dup`, or
every event leaks an fd.

**2. `SharedWriter::write_all` is overridden deliberately.** The default implementation loops over
`write`, re-acquiring the mutex per partial write. stderr is usually a pipe or a tty, where
partial writes genuinely happen, so two `tracing` spans could interleave and tear a single NDJSON
line in half. The override holds the lock across the whole buffer. **Do not "simplify" it away** —
it looks redundant and is not, which is why the comment above it says so.

## Testing shape

Keep the logic in **plain Rust functions with no `magnus` types in their signatures**, and put the
FFI surface in a separate module. `build_env_filter` and `dup_writer` are the pattern: they are
unit-testable without an embedded Ruby VM, which is why `cargo test` runs at all. A function that
takes a `Ruby` or returns a `magnus::Error` cannot be tested in `cargo test`; push the decision out
of it and test the decision.

## When porting a Ruby structure down here (M4)

`Timeline` ships as pure Ruby first. The port is correct **only** when the existing `Regular` and
`MeetSemilattice` property tests pass unchanged against *both* implementations — that is the
acceptance test, and it is why the Ruby version is not deleted when the Rust one lands.

> ⚠️ **A magnus-wrapped `TypedData` object is not `Ractor.shareable?` for free.** `Ractor.shareable?(turn)`
> must stay `true` — it is the mechanical statement of "no reachable mutable state", and there is a
> spec. Establish shareability deliberately; do not weaken the spec to accommodate the port.

Batch across the boundary. A per-node FFI call in a DAG walk loses to plain Ruby, because
conversion cost dominates almost every naive binding. If a port is not asymptotically better, it is
not better.

### A ported structure inherits the Ruby declaration; it does not make its own

When the ported thing is algebraic — a semilattice, a monoid, a lattice — **the Ruby shared
example group is the authority on which laws exist**, and the Rust tests assert that same list.
`spec/support/shared_examples/meet_semilattice.rb` declares exactly four laws (idempotent,
commutative, associative, meet-below-both); `dag.rs` asserts those four, named to match, and
invents no fifth. This is not deference for its own sake: the two layers must not come to
disagree about what a law *is*, or the differential oracle has quietly forked.

So do not reach for a `trait Monoid` or `trait MeetSemilattice` to "make it official". An algebra
trait earns its place only when a **production** Rust function is generic over the structure and
genuinely needs to be — a trait written solely so tests can call it is indirection with a law
attached, and it invites a second, drifting declaration of the same laws. Until then: plain
`#[test]` functions named for the property, matching `dag.rs`.

**The two suites prove different things, and a doc comment must say which.**

| Suite | Proves | Notes |
|---|---|---|
| `cargo test` | the Rust **algorithm** obeys the law | plain functions, no `magnus`, no VM — a layer the Ruby suite cannot reach |
| `spec/lain/rust/*` | the Rust **binding** agrees with Ruby | runs the shared groups **unchanged**; the SOLE authority on cross-implementation agreement |

Never assert "Rust equals Ruby" inside `cargo test`. If a Rust test wants a Ruby value to compare
against, it belongs in RSpec — the port acceptance rule above depends on there being exactly one
such authority.

Testability follows the same rule the **Testing shape** section states: push the decision out of
the FFI method and test the decision. `put_into` was split out of `Store::put` for exactly this —
the method keeps the lock and the error translation, the pure function carries the idempotence law
and its proof.

**A law test asserts a declared law; everything else goes below the banner.** `dag.rs`'s and
`lib.rs`'s law blocks are fenced with a comment naming the Ruby group they inherit from, and
tests that merely characterize an implementation choice (`a_re_put_returns_early_without_revalidating_edges`
pins `put_into`'s `contains_key` shortcut) sit *outside* that fence, labelled as characterization.
A reader must never inherit a house rule as though it were one of the declared laws.

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
