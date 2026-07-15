# Rust findings resolution: loud walks, idiomatic errors, domain types

status: in-progress
commit-mode: orchestrator-commits
language: rust
panel: Raph Levien, Andrew Gallant (burntsushi), Frank McSherry, Ashley Williams, Aaron Patterson


## Intent

Resolve both rounds of `ext/lain` findings: the preliminary analysis
(`planning/reviews/2026-07-15-rust-preliminary-analysis.md`, F.1–F.8) and the follow-up
naming/idiom/crates discussion (2026-07-15). One real divergence gets fixed loudly (silent
truncation on corrupt chains — including a silently-wrong `meet`), the loud-failure
inversions in "unreachable" arms go, the error types become idiomatic Rust (`thiserror`),
the FFI layer sheds its duplication and dishonest names, `TurnData`'s stringly-typed fields
become domain types, and the crate lands on edition 2024. Joel chose to INCLUDE the two
design-level deferrals (Digest newtype, Role enum) rather than ledger them; F.8 is an
orchestrator ledger amendment, not a card.

## Grounding

Verified 2026-07-15 against `main` (post-`5582e15`, all 22 cards of the previous plan
landed). Sources: direct read of all five `ext/lain/src/*.rs` files + `Cargo.toml` this
session; Explore verification of the Ruby-side surfaces.

- **F.1 divergence confirmed on all four walk paths.** Ruby raises
  `Store::MissingObject, "no object #{digest.inspect} in store"` (`lib/lain/store.rb:30-34`)
  from `ancestors` (`timeline.rb:80-89`), `meet` (:117-123), `ancestor_of?` (:108-113), AND
  `rewind` (:73-77 — each hop `fetch`es). Rust `dag::ancestor_arcs` (`dag.rs:23-33`)
  silently truncates; Rust `rewind` (`lib.rs:812-815`) uses `parent_of`, which returns
  `None` for an ABSENT digest — indistinguishable from running past the root, so a corrupt
  chain silently lands on the empty Timeline. `meet` over a truncated chain can return a
  wrong answer, which `diverge_at`'s cache-break localization would trust.
- **The corrupt-chain scenario is constructible via public API**: `Turn.new` (Ruby
  `turn.rb:19-26` and Ext alike) accepts any string as `parent:`; `rust/turn_spec.rb:64,74-77,87`
  already constructs `parent: "blake3:abc"`. No existing spec WALKS a dangling chain — the
  gap the property tests can't cover (they only generate valid chains via `say`/`commit`).
- **Pinned error-message surface** (what renames/messages must not break):
  `MissingObject` pinned as `/no object/` (`spec/lain/rust/store_spec.rb:30-31`);
  `InvalidRole` as `/must be one of/` (`rust/turn_spec.rb:13-14`); `CrossStore`,
  `EmptyCorpus` class-only; `DuplicateId` as `/x/` (`rust/bm25_spec.rb:30-32`); the
  canonical determinism group pins `/both a String and a Symbol/`,
  `/cannot canonicalize/`, `/hash keys must be/`, `/UTF-8/`
  (`spec/support/shared_examples/canonical_laws.rb:73-101`) against the RUBY
  `Lain::Canonical::*` classes, which the Rust FFI raises via raise-time lookup.
  **Nothing pins `Ext::Turn`/`Ext::Timeline` `#to_s`/`#inspect`** — F.8's ledger amendment
  is safe.
- **Message drift**: Rust `Store::fetch` and `Timeline::head` say
  `"no object {digest:?} in store"`; `checkout` (`lib.rs:792`) drops the `" in store"`
  tail. Ruby's `Timeline#initialize` head-check message also lacks the tail
  (`timeline.rb:32`) — match Ruby per-site, not blanket.
- **Build plumbing**: root `Cargo.toml` is a workspace (`members = ["./ext/lain"]`,
  resolver 2); `Cargo.lock` committed at root only; `deny.toml` at root — license allowlist
  includes MIT/Apache-2.0 (thiserror's whole tree: `thiserror`, `proc-macro2`, `quote`,
  `syn`, `unicode-ident` — all MIT/Apache, no deny change needed); pre-commit runs
  `cargo test`/`clippy`/`fmt`/`deny` from the repo root on every commit.
- **`CanonError::message()` is called from `lib.rs:309`** — T3 must keep a `message()`
  surface (delegating to `Display`) to avoid editing `lib.rs` from wave 1's parallel card.
- **`Lain.hello` is load-bearing** (`spec/lain/seams/journal_tracing_seam_spec.rb`) — no
  card deletes it.
- **Docs-vs-code disagreement**: `dag.rs`'s own doc claims walks happen "in a single locked
  read"; `rewind` re-locks per step (F.5). Code loses; T4 fixes the code to match the doc.

## Rulings (from the 2026-07-15 interview + analysis discussion — DECIDED)

1. **F.6 Digest newtype is type-distinguishing, NOT shape-validating.** Ruby `Turn.new`
   accepts arbitrary parent strings and `rust/turn_spec.rb` constructs `parent: "blake3:abc"`
   (not a real 64-hex digest); a validating boundary would diverge from Ruby and break
   pinned specs. Validation is a joint Ruby+Rust follow-up — T5 proposes it as an R.* entry.
2. **F.6 and F.7 land in ONE card** (T5): both replace stringly-typed `TurnData` fields
   with domain types; digest BYTES on the wire must be unchanged.
3. **thiserror is adopted** (T3); the bm25 shareability audit gains compile-time `Sync`
   assertions (hand-rolled `const` fn, no new dep — `static_assertions` rejected as
   unnecessary for two assertions).
4. **`serde_json`/RFC-8785 canonicalizers are rejected for `Canon`** — byte-parity with
   Ruby's `JSON.generate` (ryu float formatting, JCS's ES6 number rendering both break it);
   T3 writes the WHY naming the rejected crates in `canonical.rs`'s module doc.
5. **Edition 2024 lands as the final card** (T6), after all code cards.
6. **F.8 is orchestrator bookkeeping**: amend R.4 in `planning/remaining-work.md` to add
   `Lain::Ext::Turn` and `Lain::Ext::Timeline` to its sweep list (Wave 0, no card).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `ext/lain/Cargo.toml` (dep lines,
  edition), root `Cargo.toml`, `Cargo.lock` (regenerated by the orchestrator when a dep
  lands), `deny.toml`, `lib/lain.rb`, `spec/spec_helper.rb`, `Gemfile`/`Gemfile.lock`,
  `.rubocop.yml`, `CLAUDE.md`, `ext/lain/CLAUDE.md`, `.pre-commit-config.yaml`,
  `planning/remaining-work.md` (single-writer R.* ledger).
- **Wave 0 (orchestrator, before any card):** amend R.4 per Ruling 6; commit this plan +
  its ROADMAP line.
- `ext/lain/src/lib.rs` is the contention surface: T1, T2, T4, T5 all touch it and are
  therefore strictly serialized across waves (T3 deliberately avoids it — see Grounding on
  `message()`).
- Every card's shell: `export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"`; verification is
  BOTH toolchains every time: `cargo test && cargo clippy --all-targets -- -D warnings &&
  cargo fmt -- --check` AND `bundle exec rake compile && bundle exec rspec`. Read
  `ext/lain/CLAUDE.md` before touching any Rust (stable channel only; output discipline is
  a crate-root deny; the pure/FFI test split is the testing shape).
- Rust ACs that live in `cargo test` name their test module; Ruby ACs name spec files.
  Both are red-first.
- Commit messages: no card-ID prefixes (Joel's standing rule) — describe the change.

## Open decisions

None. (Scope, roster, edition, newtype validation posture all settled in the interview.)

## Waves

Wave 1: T1, T3   (disjoint files: T1 = dag.rs + lib.rs + specs; T3 = canonical.rs + turn.rs + bm25.rs)
Wave 2: T2 (←T1)
Wave 3: T4 (←T1, T2, T3)
Wave 4: T5 (←T3, T4)
Wave 5: T6 (←T1, T2, T3, T4, T5)
Critical path: T1 → T2 → T4 → T5 → T6

## Tasks

### T1 — Make DAG walks raise on dangling digests          [wave 1] [risk: high] ✅ landed 2dea1f5 (panel: APPROVE-WITH-FIXES → fixed → APPROVE; probe found Ext rewind landing on a dangle unvalidated — now pinned in both implementations)

**Depends on:** none
**Files:** modify `ext/lain/src/dag.rs`, `ext/lain/src/lib.rs` (walk call sites:
`ancestors`/`to_a`/`ancestor_digests`/`length`/`include?`/`ancestor_of?`/`meet`/
`diverge_at`/`rewind`, plus the `checkout` message-drift line); modify
`spec/lain/rust/timeline_spec.rb`, `spec/lain/timeline_spec.rb` (the Ruby twin pins the
same behavior so the two implementations cannot re-diverge)
**Reuse:** the existing `ext_error(ruby, "Store", "MissingObject", ...)` builder
(`lib.rs:386-397`); the public-API corrupt-chain recipe from Grounding
(`Turn.new(parent: <absent digest>)` → `store.put` → `checkout`); Ruby's message format
`"no object #{digest.inspect} in store"` (`store.rb:34`)
**Shared-file wiring:** none

F.1. `dag::ancestor_arcs` currently ends the walk silently when a parent digest is absent
from the map; `parent_of` conflates absent-digest with root. Change the pure layer to make
corruption an error: the walk returns `Result<Vec<Arc<TurnData>>, DanglingDigest>` (a small
error struct naming the missing digest — **hand-rolled `Display`/`std::error::Error`, NOT
thiserror**: the dependency lands with wave-1 sibling T3's orchestrator wiring and does not
exist in this card's worktree), and the rewind path distinguishes "digest absent" (error)
from "parent is None" (root — keeps absorbing per Ruby `timeline.rb:75`). Note the one
existing pure test that encodes the bug being fixed:
`parent_of_steps_back_one_and_stops_at_the_root` asserts
`parent_of(&map, "blake3:absent") == None` — it flips to asserting `Err(DanglingDigest)`
for the absent case (root-stop stays `Ok(None)`). The FFI
layer maps `DanglingDigest` to `Lain::Ext::Store::MissingObject` with the exact Ruby
message (`no object "<digest>" in store` — note Ruby uses `String#inspect`, Rust `{:?}`;
verify byte-equality for plain digests). Fix `checkout`'s drifted message while in that
error family: it mirrors Ruby `Timeline#initialize`'s tail-less form (`timeline.rb:32`), so
ADD a comment noting the deliberate asymmetry instead of "fixing" it — match Ruby per-site.
`meet`/`ancestor_of?`/`diverge_at` propagate the error rather than computing over a
truncated chain (the wrong-answer case in the findings doc). Pure-layer tests cover every
walk against a hand-corrupted map; Ruby-side specs pin BOTH implementations with the same
corrupt-store recipe (Ext spec asserts the Ext classes; the Ruby twin already passes —
pinning it is what locks the parity).

**Acceptance criteria:**

```gherkin
Scenario: a dangling parent fails every walk loudly, in both implementations
  Given a store holding a head turn whose parent digest was never put
  When ancestors, to_a, ancestor_digests, length, include?, or rewind walks the chain
  Then each raises Store::MissingObject naming the missing digest (message /no object .* in store/)
```
→ spec file: `spec/lain/rust/timeline_spec.rb` (Ext) and `spec/lain/timeline_spec.rb` (Ruby twin)

```gherkin
Scenario: the two implementations agree on the error message bytes
  Given dangling parent digests "blake3:absent" and one containing a double-quote
  When the Ext walk and the Ruby walk each raise
  Then the two MissingObject messages are EQUAL strings (not merely regex-matching) —
       Ruby's String#inspect and Rust's {:?} must render these cases identically; digests
       containing control characters are out of scope with a WHY comment (escape styles
       genuinely differ; both still raise)
```
→ spec file: `spec/lain/rust/timeline_spec.rb`

```gherkin
Scenario: meet and diverge_at never compute over a truncated chain
  Given two timelines sharing a corrupt ancestry (dangling parent below their fork point)
  When meet, ancestor_of?, or diverge_at runs
  Then it raises Store::MissingObject rather than returning a wrong or empty answer
```
→ spec file: `spec/lain/rust/timeline_spec.rb`

```gherkin
Scenario: rewind still absorbs past the root
  Given a well-formed two-turn timeline
  When rewind(5) runs
  Then it lands on the empty timeline without error (both implementations, unchanged)
```
→ spec file: `spec/lain/rust/timeline_spec.rb` (existing example stays green)

```gherkin
Scenario: the pure walk reports the missing digest
  Given a StoreMap whose chain references an absent digest
  When ancestor_arcs / the rewind lookup runs
  Then it returns Err(DanglingDigest) carrying that digest, and Ok on well-formed chains
```
→ test module: `ext/lain/src/dag.rs` `#[cfg(test)] mod tests`

**Escalation triggers:**
- Any EXISTING spec goes red because it walks a chain containing a fabricated parent that
  was never `put` (grep `parent:` in `spec/lain/rust/` — `turn_spec.rb:64,74-77,87`
  construct such turns; if any of them is *walked* rather than merely inspected, the card's
  premise about spec reachability is wrong — stop and report, do not rewrite those specs).
- `spec/lain/rust/speculative_spec.rb` (diverge_at/branching) fails for any reason other
  than a genuinely corrupt fixture — diverge_at's happy path must be byte-identical; stop.
- The Ruby twin spec CANNOT be pinned with the same recipe (e.g. Ruby raises a different
  class than `Lain::Store::MissingObject` from some walk) — the parity claim in the
  findings doc was wrong; stop and re-ground.

### T2 — Remove the silent FFI fallbacks          [wave 2] [risk: medium] ✅ landed 9bcf762 (panel: APPROVE; ancestry pin confirmed regression-only — init fallback was dead under normal load order)

**Depends on:** T1
**Files:** modify `ext/lain/src/lib.rs`; modify `spec/lain/rust/store_spec.rb` (or the most
fitting existing rust spec — implementer locates) for the error-ancestry pin
**Reuse:** the pure-function testing shape (`build_env_filter`/`blake3_hex` pattern,
`ext/lain/CLAUDE.md` "Testing shape"); `canonical.rs`'s `Canon::Num` docs (why number text
is Ruby-rendered)
**Shared-file wiring:** none

F.2 + F.3 + the `unwrap_or`-family NITs. (1) `num_to_ruby` (`lib.rs:442-453`): extract the
classification decision (float-text vs i64 vs bignum) into a pure, cargo-tested function in
lib.rs's pure section; the FFI arm raises a Ruby `RuntimeError` naming the unparseable text
instead of materializing `NaN`/`nil` — these arms are unreachable for reader-produced text,
which is exactly why reaching one must be loud. (2) `init` (`lib.rs:1068-1072`): drop the
`unwrap_or_else(StandardError)` fallback — propagate the `Lain::Error` lookup failure so a
load-order regression fails at require time; pin the now-guaranteed ancestry from Ruby.
(3) Sweep the same-family NITs for consistency: the `qtrue`/`qfalse` `.equal().unwrap_or(false)`
checks and `Timeline::to_s`'s `unwrap_or(0)` get either the loud treatment or a one-line
WHY stating why swallow-to-default is genuinely safe there (implementer's call, stated).

**Acceptance criteria:**

```gherkin
Scenario: Ext error classes are Lain::Error descendants, guaranteed at load
  Given the compiled extension is loaded through lib/lain.rb's manifest
  When Store::MissingObject, Turn::InvalidRole, Timeline::CrossStore, Bm25::EmptyCorpus ancestry is inspected
  Then each includes Lain::Error (the silent StandardError re-parenting is impossible)
```
→ spec file: `spec/lain/rust/store_spec.rb` (or sibling — one example covering the four)

```gherkin
Scenario: number-text classification is total and loud
  Given the pure classifier
  When fed reader-produced texts ("1", "-3", "1.5", "2e10", a >i64 bignum string) and garbage ("abc", "")
  Then reader-produced texts classify correctly and garbage returns Err (never NaN, never a silent nil)
```
→ test module: `ext/lain/src/lib.rs` `#[cfg(test)]` (pure section)

**Escalation triggers:**
- Before dropping init's fallback, verify the one direct-load path: grep for
  `require "lain/lain"` — expected hits are `lib/lain.rb` (after `lain/error`) and
  `spec/lain/seams/journal_tracing_seam_spec.rb:6`. The panel already traced the latter:
  `.rspec`'s `--require spec_helper` runs the full manifest before any spec file, so the
  seam spec's require is an idempotent no-op and `Lain::Error` is always defined first —
  a clean pass looks exactly like that. STOP only if the grep turns up a NEW direct-load
  path, or `rake compile`/require actually fails after the drop; then the fix becomes
  "raise at first error construction instead of init", and say so.
- Any pinned digest/byte-parity spec moves — number rendering must be byte-identical;
  the classifier extraction must not change what's emitted, only what happens on garbage.

### T3 — Make the pure error types idiomatic and mechanize the shareability audit   [wave 1] [risk: low] ✅ landed eac15a1 (panel: APPROVE, 2 NITs noted, none actionable)

**Depends on:** none
**Files:** modify `ext/lain/src/canonical.rs`, `ext/lain/src/turn.rs`, `ext/lain/src/bm25.rs`
**Reuse:** pinned message regexes (Grounding: `/both a String and a Symbol/` at
`canonical_laws.rb:73`, `/must be one of/` at `rust/turn_spec.rb:13-14`, `/x/` at
`rust/bm25_spec.rb:30-32`); the bm25 interior-mutability audit prose (`bm25.rs` module doc)
**Shared-file wiring:** `thiserror = "2"` dep line in `ext/lain/Cargo.toml` + `Cargo.lock`
regen — orchestrator applies (license tree is MIT/Apache, already on `deny.toml`'s
allowlist; no deny change)

Round-2 idiom findings, pure files only (deliberately NO `lib.rs` edits — wave-1 sibling
T1 owns that file; `InvalidRole` KEEPS its tuple field, because `lib.rs:482` reads
`invalid.0` and may not be edited from this card — T4 later switches that site to Display).
(1) Idiomatic errors, with the Display text being the FFI-VISIBLE message so it becomes the
single source T4 can wire the raise sites to: `thiserror` on `CanonError`
(`#[error("{0:?} is both a String and a Symbol key")]`) and `BuildError`
(`#[error("cannot build a BM25 index from an empty corpus")]` /
`#[error("duplicate document id {0:?}")]` — the exact texts `lib.rs`'s match arms
hand-construct today); `InvalidRole` gets a HAND-IMPLEMENTED `Display` + `std::error::Error`
instead of thiserror, because its message interpolates `ROLES.join(", ")` and hardcoding
the list in a derive attribute would double-source it — write that WHY at the impl.
`CanonError::message()` REMAINS as a thin delegation to `Display` so `lib.rs:309` compiles
untouched. (2) `Canon` derives `Eq` (it is
float-free — `Num` is text). (3) `impl Display for Canon` delegating to `dump` (free
`to_string()`; `dump` stays the named domain entry). (4) The serde-rejection WHY: one
sentence in `canonical.rs`'s module doc naming `serde_json` (ryu float formatting) and
RFC-8785/JCS (ES6 number rendering) as evaluated-and-rejected for byte-parity reasons.
(5) Compile-time shareability assertions: a hand-rolled `const` Sync assertion for
`Bm25Index` and `TurnData` (catches `Cell`/`RefCell` regressions — they are `!Sync`), with
a comment stating what it can't catch (`Mutex`/atomics are `Sync`; those stay prose-audited).

**Acceptance criteria:**

```gherkin
Scenario: error messages survive the thiserror migration byte-for-byte
  Given the canonical determinism shared group and the rust turn/bm25 specs
  When the full Ruby suite runs
  Then every pinned message regex passes unchanged (no spec edits)
```
→ spec file: existing — `spec/lain/rust/{canonical,turn,bm25}_spec.rb` + `spec/support/shared_examples/canonical_laws.rb` consumers, green unchanged

```gherkin
Scenario: the pure error types are std errors whose Display IS the FFI-visible message
  Given CanonError, InvalidRole, BuildError values
  When formatted via Display and dyn Error
  Then each renders the exact message text the FFI raise sites emit today (so T4 can
       replace those hand-built strings with Display), and Canon's Display equals dump()
```
→ test module: `ext/lain/src/{canonical,turn,bm25}.rs` `#[cfg(test)]` (new Display examples, red first)

```gherkin
Scenario: interior mutability cannot silently return
  Given the const Sync assertions on Bm25Index and TurnData
  When a Cell/RefCell field is introduced (demonstrated in the red step, then reverted)
  Then the crate fails to compile
```
→ test module: compile-time (`ext/lain/src/bm25.rs`, `ext/lain/src/turn.rs`) — red step is evidence in the hand-back, not a committed test

**Escalation triggers:**
- thiserror's derive cannot reproduce a pinned message byte-for-byte (e.g. the `{0:?}`
  formatting of `AmbiguousKey` differs from Ruby's `inspect` for some key) — do not loosen
  a spec regex; stop and show the divergent bytes.
- `TurnData` turns out NOT to be `Sync` today (the assertion is immediately red for a real
  reason, not a demo) — that invalidates the `frozen_shareable` promise on `Turn` itself;
  stop, this is a shipped-bug finding, not a chore.

### T4 — Rename, dedup, and align the FFI layer          [wave 3] [risk: medium] ✅ landed d306fbb (panel: APPROVE-WITH-FIXES, mechanical round only; orchestrator accepted rewind's scan_args arity as a deliberate Ruby-parity exception to the zero-change AC)

**Depends on:** T1, T2, T3
**Files:** modify `ext/lain/src/lib.rs`, `ext/lain/src/dag.rs`
**Reuse:** `magnus::scan_args` (already imported for `get_kwargs`); the `locked()` guard
idiom (`lib.rs:618-623`); T1's settled error shapes; T3's Display impls (the single-source
message texts this card wires the raise sites to)
**Shared-file wiring:** none

The round-2 mechanical sweep, zero behavior change. Renames: `same_store` →
`ensure_same_store` (it raises; the name must say so), `ancestor_arcs` → `ancestor_turns`
(name the meaning, not the `Arc` representation — `ancestor_digests` is the pattern),
`utf8` → `validated_utf8`. Dedup: a `store_ref` helper collapsing the ~14
`TryConvert::try_convert(rb_self.store_value(ruby))` sites; one
`lookup_error(ruby, path: &[&str], message)` absorbing `canonical_error` + `ext_error` —
walk all but the last segment as `RModule`/`RClass` const_gets, resolve the last as the
`ExceptionClass` (the two existing fns differ only in path depth; do not invent a third
shape). Idiom: `scan_args` for
`Timeline::empty`'s and `rewind`'s hand-rolled variadic parsing; pick ONE infallible-push
style (`?` everywhere or documented `let _ =` — state the choice). **Wire the raise sites
to T3's Display impls** — the panel found `read_role`'s Some-arm and `Bm25::build`'s match
arms hand-construct duplicate copies of the message text that nothing keeps in sync with
the pure error types: replace them with `invalid.to_string()` / `err.to_string()` (the
None-arm of `read_role`, which has no error value, keeps its hand-built "got a {class}"
form), and this removes the `invalid.0` tuple access. `CanonError::message()` stays
permanently as T3's thin Display delegation — do NOT chase its removal into canonical.rs
(out of this card's files; the delegation is harmless). WHY comments: `fork` returning
self (F.4 — the
handle-design sentence at the site); `SharedWriter::file()` hiding a lock acquisition
behind a noun (rename to `locked_file()` or comment). F.5: `rewind` binds `store.locked()`
once before the loop, matching `dag.rs`'s single-locked-read doctrine (T1 will already
have touched this loop — rebase the fix on its shape).

*Orchestrator scope addition (from T2's hand-back, 2026-07-15):* `diverge_at`'s
`unwrap_or_else(|| ruby.qnil()...)` after its second `store.locked().get(&digest)` is the
same silent-nil shape T2 swept elsewhere — post-T1, `meet`'s result digest is guaranteed
present, so the lookup "can't fail", which is exactly the loud-failure-inversion pattern:
make it loud or write the one-line WHY.

**Acceptance criteria:**

```gherkin
Scenario: the sweep changes zero behavior
  Given the full Ruby suite and cargo test suite before and after
  When both run after the sweep
  Then example counts and outcomes are identical with no spec/test edits, and clippy/fmt stay clean
```
→ spec file: whole suite (Ruby + cargo), unchanged

```gherkin
Scenario: the dishonest names are gone
  Given the crate source
  When grepped for `fn same_store`, `fn ancestor_arcs`, `fn utf8(`
  Then zero hits remain, and `ensure_same_store`/`ancestor_turns`/`validated_utf8` exist
```
→ test module: grep gate (orchestrator verifies at merge; no committed test)

**Escalation triggers:**
- Any rename forces a Ruby-visible change (a `define_method` name or error message) — the
  sweep is internal-only; if a Ruby surface moves, stop.
- `scan_args` cannot express `Timeline::empty`'s optional-kwargs-with-default shape without
  changing its Ruby-observable arity/errors (currently `expected keyword arguments` on a
  non-Hash arg) — keep the hand-rolled parse for that one site with a WHY, and say so.

### T5 — Replace TurnData's stringly-typed fields with domain types   [wave 4] [risk: high]

**Depends on:** T3, T4
**Files:** create `ext/lain/src/digest.rs`; modify `ext/lain/src/turn.rs`,
`ext/lain/src/dag.rs`, `ext/lain/src/lib.rs`, `ext/lain/src/canonical.rs` (only if
`digest()`'s return type moves — prefer leaving it `String`-returning and wrapping at the
`TurnData` boundary)
**Reuse:** T3's thiserror idiom for any new error; the pinned parity surfaces (digest
byte-vectors in `rust/turn_spec.rb`/`rust/canonical_spec.rb`; `/must be one of/` in
`rust/turn_spec.rb:13-14`); Ruling 1 (type-distinguishing, NOT shape-validating)
**Shared-file wiring:** the new `digest.rs` module line in `ext/lain/src/lib.rs`'s `mod`
list is T5's own edit (lib.rs is in its Files), not orchestrator wiring

F.6 + F.7 as one type-tightening pass. (1) `Digest` newtype (`digest.rs`):
`struct Digest(String)` with `Display`, `Deref`/`as_str`, `From<String>`/`Into<String>` at
the FFI boundary only — per Ruling 1 it does NOT validate shape (Ruby accepts arbitrary
parent strings; `rust/turn_spec.rb` builds `parent: "blake3:abc"`). Adopt it in
`TurnData.{digest,parent}`, `StoreMap` keys, and every `dag.rs` signature — after this, a
bare `String` cannot be passed where a digest is meant (the `parent_of(map, "blake3:absent")`
call in dag's own tests becomes a deliberate `Digest::from`). Propose the validation
upgrade (joint Ruby+Rust, shape-checking `parent:` at both constructors) as an R.* entry in
the hand-back. (2) `Role` enum (`turn.rs`): `enum Role { User, Assistant }` with `as_str`,
replacing the `ROLES` array + `validate_role` with `Role::try_from(&str)` returning the
existing `InvalidRole` (T3's thiserror shape); `read_role` maps through it; the
`"must be one of user, assistant"` message text and the serialized role strings are
byte-identical, so no digest moves.

**Acceptance criteria:**

```gherkin
Scenario: digests are byte-identical across the type change
  Given the existing digest byte-vector and Ruby-parity specs
  When the full Ruby suite runs
  Then rust/turn_spec, rust/canonical_spec, rust/timeline_spec, rust/store_spec pass with zero spec edits
```
→ spec file: existing `spec/lain/rust/*_spec.rb`, green unchanged

```gherkin
Scenario: the type system rejects a bare string where a digest is meant
  Given a call site passing a raw String to a dag walk or TurnData field
  When the crate compiles
  Then it fails to compile (demonstrated red in the hand-back, then expressed via Digest::from)
```
→ test module: compile-time evidence + `ext/lain/src/digest.rs` `#[cfg(test)]` (Display/round-trip)

```gherkin
Scenario: role validation is unchanged at the Ruby surface
  Given Turn.new with role :system and role "user"
  When construction runs
  Then :system raises InvalidRole matching /must be one of/ and "user" constructs — existing examples green
```
→ spec file: `spec/lain/rust/turn_spec.rb` (existing examples, unchanged)

**Escalation triggers:**
- ANY digest byte moves (a parity spec or byte-vector fails) — the newtype must be a
  transparent wrapper; a moved byte means it leaked into serialization; stop immediately
  (identity-spine territory, same rule as the Ruby side's canonical.rb).
- The `Digest` newtype wants `Hash`-map ergonomics that force `Borrow<str>` gymnastics
  making call sites WORSE than the bare `String` — the finding's premise (strictly clearer)
  fails; stop and show the ugliest three call sites before proceeding.
- Role-enum adoption changes the `role()` FFI return or the payload serialization in any
  byte — stop.

### T6 — Migrate the crate to edition 2024          [wave 5] [risk: low]

**Depends on:** T1, T2, T3, T4, T5
**Files:** modify `ext/lain/src/*.rs` (whatever `cargo fix --edition` + manual review
requires — expected small: possibly `unsafe` attribute syntax, prelude changes)
**Reuse:** the full verification battery (both toolchains); `ext/lain/CLAUDE.md`'s
stable-channel rule (edition 2024 needs rustc ≥ 1.85 — verify the installed toolchain
FIRST; if it's older, the card is a no-op report, not an upgrade of rustc)
**Shared-file wiring:** `edition = "2024"` in `ext/lain/Cargo.toml` and (if needed)
`resolver`/workspace lines in root `Cargo.toml` — orchestrator applies

Evaluate-and-migrate, sequenced last so it sweeps settled code. Run
`cargo fix --edition --allow-dirty` in the worktree, review every change it proposes
(reject anything that alters behavior — this is a syntax/idiom migration, not a refactor),
flip the edition via the orchestrator wiring diff, and prove the battery green. The
`#![deny(clippy::print_stdout, clippy::print_stderr)]` crate-root attribute and the
`unsafe` blocks in `lib.rs` (fd dup, `RString::as_slice`) are the likely touch points —
edition 2024 makes some `unsafe` requirements stricter, which is aligned with this crate's
posture; take the stricter form.

**Acceptance criteria:**

```gherkin
Scenario: the crate builds and behaves identically on edition 2024
  Given the edition flip and cargo fix output applied
  When cargo test, clippy -D warnings, fmt --check, cargo deny, rake compile, and the full Ruby suite run
  Then all pass with zero Ruby spec edits and zero cargo test edits
```
→ spec file: whole battery (both toolchains), unchanged

**Escalation triggers:**
- Installed stable rustc < 1.85 (edition 2024 unsupported) — do NOT upgrade the toolchain
  from a card; report the version and stop (toolchain upgrades are Joel's call).
- `cargo fix --edition` proposes a change in `unsafe` semantics around the fd-dup or
  `as_slice` blocks that is more than syntactic — those two blocks carry load-bearing
  SAFETY comments; stop and show the proposed diff rather than accepting it.

## Integration checks

After the last wave, on the merged tree:

1. `cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt -- --check &&
   cargo deny check` — green at edition 2024.
2. `bundle exec rake compile && bundle exec rspec` — full suite green (1385+ examples),
   zero spec regressions.
3. `pre-commit run --all-files`.
4. Grep gates: `grep -rn "fn same_store\|fn ancestor_arcs\|fn utf8(" ext/lain/src` → zero;
   `grep -n "unwrap_or(f64::NAN)\|unwrap_or_else(|_| ruby.qnil()" ext/lain/src/lib.rs` →
   zero; `grep -n "StandardError" ext/lain/src/lib.rs` → zero (the init fallback is gone).
5. `planning/remaining-work.md`: R.4 amended with the two Ext classes (Wave 0); any new
   R.* entries from T5's validation proposal folded (orchestrator, single writer).
6. **Manual (Joel):** read the corrupt-chain specs (`spec/lain/rust/timeline_spec.rb` +
   `spec/lain/timeline_spec.rb` additions) — they encode the F.1 divergence story and are
   the guard the property tests structurally cannot provide; confirm the recipe reads as
   the real threat model.
