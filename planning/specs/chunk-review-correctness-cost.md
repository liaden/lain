# Chunk A: review fixes — correctness and cost

status: in-progress (panel-reviewed 2026-07-29; fix-then-ship edits applied; execution started 2026-07-29 from cc76ea4)
commit-mode: orchestrator-commits
language: ruby + rust
panel: Ruby — Torvalds, Evans, Metz, Schneeman, Patterson; Rust — Levien, Gallant, McSherry, Williams (one review agent embodies all; weigh per-card by the card's language)

## Intent

First of two chunks landing `planning/reviews/2026-07-29-simplification-review.md`: the shipped
defects (§2), the verified performance fixes (§3), the Rust idiom/safety work that is also a
prerequisite for later wiring (§10), `Tools::Grep`'s move to lain-core, and the ROADMAP/doc
record (§8). The panel split the original 38-card plan at the review's own section boundary;
the missing-objects/duplication half is `chunk-review-missing-objects.md` (Chunk B), which runs
**after this chunk lands** — B's grounding line numbers assume A's diffs. Card IDs are shared
across both docs (T1–T39) for traceability to the panel report; B holds T21–T38.

The Rust dag/canonical/event bindings stay **unwired** this chunk by Joel's ruling; T39 records
the parity gap and the unwired-seam triage as next-chunk ROADMAP items.

## Grounding

Verified 2026-07-29 against `d0c7a3b` by three exploration passes, the review's adversarial
verifier, and the plan panel's spot-checks (all claims carry file:line read that day):

- `spec/lain/cli/up_spec.rb` pins the `ruby-4.0.5` PATH literal at lines **298, 325, 333** (the
  `it` lines are 296/322/331) — T4 must update them; `fork_spec.rb:60` / `btw_spec.rb:38` call
  `Up.pane_command` and survive. CI is already on 4.0.6. `session_journals.rb:140`'s "MRI
  4.0.5, measured up to 5000 records" is a historical measurement — leave it alone.
- `spec/lain/request_spec.rb:220` ("invokes the digest primitive once per message plus one
  seed") and `:277` count `Canonical.digest`/`normalize` calls **per fresh Request** — a
  cross-request digest memo contradicts them as written. T19 is therefore measure-first.
- `spec/lain/session_record_spec.rb:196,230` pin that identical re-commit digests re-land
  after a `rewound` — a "stop at any already-written digest" walk breaks them; the
  take-while-until-`@head` design does not (verified against every pinned case). The invariant
  the rewrite depends on is stated as an *assumption* at `scribe.rb:156-158` and the `written:`
  ctor seed is unvalidated — hence T14's mandatory assertion.
- `Prompt::Slots#initialize` freezes shallowly at `slots.rb:131`; `@fills`/`@role_fills` are
  frozen at `:126-127` but `@templates`/`@role_templates`/`@skill_slots` are stored
  **unfrozen** (`:128-130`). No spec asserts `Slots` shareability (grepped). The purity raise
  is pinned for one call at `slots_spec.rb:278`; the repeat-call assertion is new in T15.
- The genuinely false comment about catalog/slots loading is `toolset_build.rb:90-92`
  ("Built over the same catalog + slots … **loaded once from the project root**") — false
  because `Catalog.load` fires twice and `Slots.load` three times per session. The "SAME
  agent" comment at `:89` is true and about RunSkill-vs-spawn; do not touch it.
- `Toolset` freezes at construction (`toolset.rb:33-34`, pinned by `toolset_spec.rb:20`);
  `#only`/`#except` return new instances. The chat path builds one Toolset per session
  (`toolset_build.rb:61-64`); the spawn paths (`role.rb:36`, `spawn_policy.rb:52`,
  `subagent.rb:395`) mint fresh instances per spawn.
- **The shipped compaction path is Derived**: `source.rb:152` builds `Source::Derived`, and
  `source/derived.rb:126` replays `Derivation.projected(derived.to_a)` — so the
  role/content projection exists at five-plus sites (`context.rb:157`, `head.rb:38`,
  `source.rb:231`, `derivation.rb:133-134`, `bench/plan_sweep/driver.rb:188`, variant at
  `context/mailbox.rb:81`), across **two lineages** (source timeline + derived timeline).
  T17's count assertion targets the Derived path.
- No compaction spec asserts `Canonical.dump` call **counts** (grepped `receive(:dump)`) —
  the only count-observing examples are `request_spec.rb:220,277` and `timeline_spec.rb:74`
  (a `Canonical.digest` stub count — the idiom for *dump/digest* counts, NOT for
  Store#fetch counts; no fetch-count idiom exists in the suite, so T14 builds one).
- `deny.toml` bans colour crates **by name**; tracing-subscriber's default `ansi` feature
  reaches `NO_COLOR` through an allowed crate (measured against tracing-subscriber 0.3.23).
  `journal_tracing_seam_spec.rb:43-53` guards its Rust-line assertion behind `if installed`
  — a new ESC assertion can pass vacuously if the install lost the `try_init` race.
- Timeline construction is scattered (14 sites, 12 files) — confirming the ruling to defer
  wiring. The Ext parity gap is wider than the review stated: `Ext::Store#put` is monomorphic
  (`&Turn`) while production stores six other duck-typed kinds; `Ext::Timeline#commit` lacks
  `causal_parents:` (three production sites pass it); payload is inline vs two-objects-per-
  turn (observable in `store.size` specs); `Ledger`'s block-form `#ancestors` would silently
  no-op. T39 records all of this in `planning/rust-parity-gap.md`.
- `lib/lain.rb:77` requires the extension unconditionally — the seam question is *which*
  implementation, never optionality.

**Design constraint from the interview (applies to every memo/cache card — T15, T16, T17,
T19):** prefer restructuring (compute once, thread the value) over caching. Where a cache is
the right shape, the card must state the key space, the memory bound, and the consistency
argument, and its ACs must include the hit-rate/bound justification. An honest "not worth
it" is an acceptable card outcome where marked.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `exe/lain`,
  `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `.rspec`, `Rakefile`, and the
  one-line `mod read_text;` in `ext/lain/src/lib.rs` (T11's wiring).
- `ext/lain/Cargo.toml` and `crates/lain-core/Cargo.toml` are owned by T7 in wave 1; T12
  adds lain-core deps in wave 2; no other card edits them.
- The Rust cards T7→T8→T9 serialize on `ext/lain/src/lib.rs`; do not parallelize them even
  if a wave slot is free. T11 runs in wave 3 beside T9 — it touches no `lib.rs` lines
  itself (the `mod` line is orchestrator wiring).
- **Wave rebase rule:** every wave's worktrees fork from post-previous-wave `main`.
  Consecutive waves deliberately edit the same files (e.g. `event.rs` in T10 then T8); a
  worktree forked stale will produce conflicts or, worse, silently revert a prior wave.
- Consciously deferred to Chunk B or the follow-up plan (do NOT build here): everything in
  §4/§5/§6 of the review (Chunk B), Thor-options `CLI::Flags`, `HashEnvelope`, vendored
  `provider/http` middle-man cleanup, sweep CLI doors, unwired-seam deletions, Rust
  Timeline/Store wiring.

## Open decisions

None at plan time. Three were opened and closed **during execution**, each because the panel
found the acceptance criterion itself wrong rather than the code. Recorded here because two of
them changed what the card ships:

- **T10 — AC withdrawn.** The AC demanded a `BuildError` for a corpus position beyond `u32`,
  which forced a Ruby-visible `Lain::Ext::Bm25::CorpusTooLarge` unreachable below ~206 GB of
  input, plus the `lib.rs` wiring the card claimed it did not need. The `u32` in
  `SearchEngine<String, u32, SurfaceTokenizer>` is the crate's per-document term-count type,
  **not** a corpus bound, so widening `order` to `usize` removes the cast, the error, the
  `u32::MAX` sentinel collision and the wiring together. "Wiring: none" became true rather
  than wrong. Orchestrator call.
- **T16 — memo declined on measurement.** Unmemoized `to_schema` on a 20-tool session toolset
  costs 224.89 µs; memoized, 0.26 µs. That is ~225 µs/turn against a multi-second round trip,
  three to four orders below the noise floor, bought with new reachable mutable state on a
  value object CLAUDE.md wants deeply frozen. Reverted; the card ships the measurement plus
  the wiring-level identity spec (one Toolset per session, `context.rb:162` renders it every
  turn). The chunk's restructure-over-cache constraint decided it.
- **T5 — cap semantics corrected.** "Returns within the cap" was read as *refuse*; the
  `ast_search` idiom it reuses *truncates and discloses*. Refusing rejected 145 of 879 repo
  files, the smallest 6970 B, with a dump-to-source ratio of 3.5x-11.8x that gives a model no
  cue for "dump a smaller snippet". Byte cap now truncates; the depth cap keeps refusing,
  because ~1 KB of stack per tree level makes it a stack-safety bound, not a size bound.

The pattern is worth carrying into Chunk B: an AC that names a mechanism ("memoize", "return
a BuildError") rather than an outcome is the one that turns out to be wrong.

## Progress (2026-07-29)

Landed on main, leaf-first, each verified green before the merge (ff-merge runs no hooks):
T2 `fbc11ac`, T3 `da41163`, T4 `2917179`, T6 `75c0bde`, T7, T18.

Panel findings a green suite did not catch, kept as the record of what review bought:

- **T1** — deleting the crashing fast path opened a worse hole: an `event: error` with no
  terminating blank line was buffered by `EventStreamParser`, never dispatched, and recorded
  as a *successful empty turn*. Loud became silent, in the Journal that is the experiment
  record. Fixed by an end-of-stream flush, then extended to `Anthropic::Transport` and
  `Bedrock::Transport`, which build their own handler and had the same hole on the path Lain
  actually runs.
- **T7** — the plan's own escalation trigger fired: `try_init` is global and the first example
  in the process wins, so the non-vacuity example written with the existing `if installed`
  guard would have passed over a file no Rust line wrote.
- **T14** — the rewrite advanced `@head` only after the loop, so a mid-`catch_up` journal
  failure left it stale and the retry re-journalled turns already on disk. A regression the
  card introduced, in exactly the failure mode the card existed to guard.
- **T18** — keying `write_calls` by digest silently dropped a write, because duplicate turn
  digests are a *supported* corpus: the scribe re-records the chain after every `rewound`.
- **T39** — five grounding facts were wrong, two of which feed Chunk B: Timeline construction
  is **16 sites in 12 files** (not 14), and **five** sites pass `causal_parents:` to `commit`
  (not three).

**T19 is closed as measured-and-declined** (6.16 ms/turn at n=500, 0.2% of a turn, against a
99.34% hit rate; the hit rate did not decide it, the key did, since consecutive renders share
no message objects). It surfaced a follow-up worth its own card: 48% of each rolling step is a
redundant second `Canonical.normalize`, and a prototype drops the chain 7.41 → 1.04 ms with
byte-identical digests. Needs a `Canonical.digest_normalized` entry point.

## Waves

Wave 1: T1, T2, T3, T4, T5, T6, T7, T10, T14, T16, T18, T39
Wave 2: T8 (←T7), T12 (←T7), T15, T17 (←T14), T19, T20 (←T14)
Wave 3: T9 (←T8), T11 (←T5), T13 (←T12)
Critical path: T7 → T8 → T9

## Tasks

### T1 — Delete the streaming error fast path that crashes on split chunks   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/provider/http/streaming.rb, lib/lain/provider/http/streaming/error_handling.rb, spec/lain/provider/http/streaming_spec.rb
**Reuse:** the SSE `:error` dispatch already present (`handle_sse`'s case arm at `streaming.rb:119-120`; `error_chunk?`/`handle_error_chunk` live at `error_handling.rb:27,39`; the dispatch order is `streaming.rb:104-114`); `EventStreamParser`'s buffering (`parser.feed`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an error event split across two on_data fragments raises the typed error
  Given a stubbed stream that delivers "event: error\n" and "data: {overloaded}\n\n" as two separate chunks
  When the provider consumes the stream
  Then Lain::Provider::HTTP::OverloadedError is raised, not NoMethodError
```
→ spec file: `spec/lain/provider/http/streaming_spec.rb`

```gherkin
Scenario: a bare JSON error body (non-SSE) still maps to a typed error
  Given a stubbed response body that is a raw {"error": ...} JSON object
  When the provider consumes the stream
  Then the json_error_payload? branch raises the mapped typed error
```
→ spec file: `spec/lain/provider/http/streaming_spec.rb`

The existing example at `streaming_spec.rb:72-85` (whole error in one chunk) must stay green
through the SSE-parser route. Delete `error_chunk?`/`handle_error_chunk` and their dispatch;
keep `json_error_payload?`/`handle_json_error_chunk`.

**Escalation triggers:**
- `handle_sse`'s `:error` branch does not fire for the one-chunk body at `streaming_spec.rb:78` — the dispatch order differs from the grounding's read; stop.
- This is vendored `ruby_llm` (`VENDOR.md`); if the fix requires touching more than these two files, stop — the vendor boundary may need a documented divergence note instead.

### T2 — Fix Structural::Patterns: gsub interpolation and the wrong query comment   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/structural/patterns.rb, lib/lain/structural/queries/ruby/symbols.scm, spec/lain/structural/patterns_spec.rb
**Reuse:** the existing `.fetch` examples in patterns_spec (all interpolation paths)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: interpolated values with backslash sequences appear verbatim in the pattern
  Given a catalog query interpolated with the value 'Foo\1Bar'
  When the pattern is rendered
  Then the rendered pattern contains the literal characters Foo\1Bar (gsub block form, no backreference expansion)
```
→ spec file: `spec/lain/structural/patterns_spec.rb`

Also: reword `symbols.scm:26-29` to the true discriminator (any `call` node; paren-less bare
identifiers are indistinguishable from local reads at this grammar level), and delete the
redundant `patterns_spec.rb:17-21` not_to-raise example (subsumed by the per-query examples).
(`Matcher` work moved to T5, which owns `matcher.rb` this wave.)

**Escalation triggers:**
- An existing example feeds a value containing backslash sequences and pins today's mangled output (grounding found none — re-grep) — stop; that would mean a caller depends on the bug.

### T3 — Runner and PlanSweep::Driver take a Context, fixing the system: drift   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/plan/runner.rb, lib/lain/bench/plan_sweep/driver.rb, spec/lain/bench/plan_sweep_spec.rb, spec/lain/plan/seam_policy_spec.rb
**Reuse:** `Context#with_pipeline` (lib/lain/context.rb:143) — documented as the pipeline-swap seam for `Agent::PipelineSource`; it is the right tool here because it copies `model`/`max_tokens`/`system` unchanged while swapping only the pipeline (`#with_model` at `:126` is the model seam). Do not go hunting for a doc that blesses it for this exact use — the fit is mechanical, not documented.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the sweep driver renders with the same system prompt as the runner it drives
  Given a Plan::Runner constructed with a system prompt
  When PlanSweep::Driver renders a step for the same plan
  Then the driver's rendered Request carries the same system prompt (parity assertion, not a byte count)
```
→ spec file: `spec/lain/bench/plan_sweep_spec.rb`

Both classes drop `(model:, max_tokens:, system:)` primitives for `context:` +
`with_pipeline`. All existing `plan_sweep_spec` and `seam_policy_spec` examples stay green.

**Escalation triggers:**
- `plan_sweep_spec.rb:62` (`linear_every.max > linear_thinned.max`) or `:76` (`reactive.tokens < linear_every.tokens`) flips because added system bytes shift the `REACTIVE_THRESHOLD = 250` crossover (driver.rb:52) — stop; the threshold constant may need retuning as a *deliberate*, commented change, not a silent one.

### T4 — Stop `lain up` pinning ruby-4.0.5   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/cli/up.rb, lib/lain/provider/http/configuration.rb, spec/lain/cli/up_spec.rb
**Reuse:** the WHY comments at `up.rb:62-69`, `command/fork.rb:80-87`, `command/btw.rb:39-41` explain the PATH re-export; keep the mechanism, fix the version
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: pane commands carry no hardcoded ruby version
  When Up.pane_command("chat") is composed
  Then the command does not match /ruby-\d+\.\d+\.\d+/ and re-exports the directory of the currently running ruby (RbConfig.ruby's bindir)
```
→ spec file: `spec/lain/cli/up_spec.rb`

Update the three literal-pinning assertions (`up_spec.rb:298,325,333`; their `it` lines are
296/322/331) to the new derivation. `fork_spec.rb:60` and `btw_spec.rb:38` (which call
`pane_command`) must stay green untouched. Fix the `configuration.rb:20` prose ("ruby-4.0.5
this project pins"). **Leave `session_journals.rb:140` alone** — "MRI 4.0.5, measured up to
5000 records" is a historical measurement, not a pin.

**Escalation triggers:**
- `RbConfig.ruby` under the spec runner resolves to a path outside `~/.rubies` — the derivation must still produce a working re-export for the dev box's real layout; stop and confirm the derivation rule rather than special-casing.

### T5 — Bound AstGrep.dump end-to-end; single-pass line derivation in Matcher   [wave 1] [risk: medium]

**Depends on:** none
**Files:** ext/lain/src/astgrep.rs, lib/lain/structural/matcher.rb, lib/lain/tools/ast_dump.rb, spec/lain/rust/astgrep_spec.rb, spec/lain/structural/matcher_spec.rb, spec/lain/tools/ast_dump_spec.rb
**Reuse:** `Tools::AstSearch`'s cap idiom (`ast_search_spec.rb:134` — "capped at N" disclosure, born from a +100MB RSS regression); `prompt.rs:60-86`'s `MAX_DEPTH` pattern for the CST walk bounds (`tree_is_broken`, `write_node`); `matcher_spec.rb:22` pins the current `.b` byte-prefix line derivation
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: dump output is linear in node count
  Given a source nested 2000 levels deep
  When AstGrep.dump runs
  Then it returns within the cap instead of a multi-megabyte string, and per-node indent is written without a per-node String allocation
```
→ Rust test beside `dump_reveals_the_singleton_method_node` (astgrep.rs:315-320)

```gherkin
Scenario: a dump over the cap is an error Result, not an uncaught exception
  Given a source whose dump would exceed the depth/output cap
  When the ast_dump tool runs
  Then Matcher#dump maps the new Rust cap error to a typed Ruby error, AstDump#perform rescues it (today it rescues ONLY Structural::Matcher::UnknownLanguage, ast_dump.rb:41-46), and the Result names the cap mirroring ast_search's "capped at N" wording
```
→ spec files: `spec/lain/tools/ast_dump_spec.rb`, `spec/lain/structural/matcher_spec.rb`

```gherkin
Scenario: line numbers are derived in one pass over the source
  Given a source with many matches across many lines
  When Matcher#match runs
  Then every match's line equals the current byte-count derivation, computed from newline offsets built once per source
```
→ spec file: `spec/lain/structural/matcher_spec.rb`

All existing astgrep.rs `mod tests` examples (lines 192-355) and the rust/tool specs stay
green (`include("singleton_method")` assertions live at `astgrep_spec.rb:64` and
`ast_dump_spec.rb:10,17`).

**Escalation triggers:**
- The tiny fixtures in the existing `include("singleton_method")` examples get truncated by the cap — the cap is far too low; stop.
- `cargo clippy -D warnings` objects to the chosen loop shape — resolve within clippy's suggestion, do not `#[allow]`.

### T6 — Derive the decider fixture's arm list from ARMS   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/bench/decider_sweep/fixture.rb, spec/lain/bench/decider_sweep_spec.rb
**Reuse:** `DeciderSweep::ARMS` (decider_sweep.rb:75) — the single authority
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a fixture missing an arm fails at load with MalformedCase
  Given ARMS gains a hypothetical extra arm (stubbed in the spec)
  When Fixture#build_case loads a case without it
  Then MalformedCase is raised at load time, not KeyError at replay
```
→ spec file: `spec/lain/bench/decider_sweep_spec.rb`

**Escalation triggers:**
- `ARMS` turns out to be intentionally wider than the fixture's list (an arm excluded on purpose beyond `"heuristic"`) — stop; the exclusion set must be named, not inferred.

### T7 — Trim tracing-subscriber's default features; state with_ansi(false)   [wave 1] [risk: low]

**Depends on:** none
**Files:** ext/lain/Cargo.toml, crates/lain-core/Cargo.toml, ext/lain/src/lib.rs (init_tracing region only, lines ~352-379), spec/lain/seams/journal_tracing_seam_spec.rb
**Reuse:** `crates/lain-core/src/main.rs:112`'s existing `.with_ansi(false)` as the stated-property precedent; the `if installed` guard shape already in `journal_tracing_seam_spec.rb:43-53`
**Shared-file wiring:** none (this card owns both Cargo.tomls this wave)

**Acceptance criteria:**

```gherkin
Scenario: no ANSI escape can reach the Journal from the extension — proven non-vacuously
  Given init_tracing installed on a Journal fd AND the example asserts installed is true (skipping with a named reason otherwise)
  When Ruby records and Rust spans interleave and at least one Rust-emitted line is present
  Then the merged file contains no ESC byte and every line parses as JSON (be_valid_ndjson)
```
→ spec file: `spec/lain/seams/journal_tracing_seam_spec.rb` (second example beside the existing one)

`default-features = false` with the minimal feature set (`fmt`, `json`, `env-filter`, `std`,
`smallvec`) in both crates; `nu-ansi-term` and `tracing-log` gone from `Cargo.lock`;
`.with_ansi(false)` added; a comment on the dependency line naming `ansi` as the excluded
thing (deny.toml cannot express feature bans). Existing `build_env_filter` and `dup_writer`
Rust tests (lib.rs:1910-2037) stay green.

**Escalation triggers:**
- The new example cannot guarantee `installed == true` in the suite's process (another spec won the `try_init` race) — do NOT let it pass vacuously over a Rust-line-free file; restructure (own process via a spawned ruby, or ordered install) or stop.
- The trimmed feature set fails to compile — add the *named* missing feature only, never revert to defaults.
- `Cargo.lock` churn touches crates beyond the tracing tree — stop; something else was floating.

### T8 — FFI safety in lib.rs: recursion bound, mutex discipline, store_ref lifetime, sorted-object constructor   [wave 2] [risk: high]

**Depends on:** T7
**Files:** ext/lain/src/lib.rs, ext/lain/src/canonical.rs, ext/lain/src/event.rs
**Reuse:** `prompt.rs:60-86` — the documented failure mode and the `MAX_DEPTH = 64` pattern ("one limit rather than four"); the compute-drop-then-talk-to-Ruby shape already in `Store::fetch` (lib.rs:1021-1024), `Timeline::head` (1136-1137), `rewind` (1246-1264)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a too-deep Ruby structure is refused, not overflowed
  Given a nested Array deeper than the bound
  When Lain::Ext.canonical_dump is called
  Then a Ruby exception naming the depth bound is raised, and 100 such calls do not grow RSS (no leaked Rust frames)
```
→ Rust test in lib.rs's tests module + spec file: `spec/lain/rust/canonical_spec.rb`

```gherkin
Scenario: no Ruby call happens while the Store mutex is held
  Given the ten sites at lib.rs:1008-1366 whose map_err closures call const_get under the guard
  When each is reshaped to yield a pure error value and translate after the guard drops
  Then all existing store/timeline specs and the four semilattice laws stay green
```
→ existing spec files: `spec/lain/rust/store_spec.rb`, `spec/lain/rust/timeline_spec.rb`

Also: tie `store_ref`'s lifetime to `&'a Timeline` (lib.rs:619-621) so the borrow `mark`
roots is compiler-enforced; add `Canon::object_from_sorted(&[(&'static str, Canon)])` in
`canonical.rs` (where `Canon` lives, canonical.rs:39) and use it at the three
compile-time-literal sites (`event.rs:162,217,366`), removing the `.expect()`s — this runs
per event, so per turn; reword the "load-bearing" comment at lib.rs:65.

**Escalation triggers:**
- The bound chosen for `ruby_to_canon` rejects a structure the existing canonical parity specs construct — the bound is too low for real payloads; stop and pick against the spec corpus.
- Dropping the guard before error translation changes any error *message* byte pinned by `spec/lain/rust/store_spec.rb:61-69`'s byte-identity examples — stop; the messages are contract.
- T10 (wave 1) already edited `event.rs` — fork from post-wave-1 main (the contract's rebase rule) or the sort/Ord changes get clobbered.

### T9 — dag.rs walks as iterators; batch the FFI consumers; freeze Bm25's array   [wave 3] [risk: medium]

**Depends on:** T8
**Files:** ext/lain/src/dag.rs, ext/lain/src/lib.rs
**Reuse:** the four semilattice laws in dag.rs's test module (named to match `meet_semilattice.rb`) — they are the acceptance harness; CLAUDE.md's Enumerable doctrine as the design statement
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: ancestor queries short-circuit
  Given a 10,000-turn chain whose target is one hop from head
  When ancestor_of / meet / include? run
  Then the walk visits O(answer) nodes, not O(chain) (asserted via the private walk iterator's unit test), and all four semilattice laws pass unchanged
```
→ Rust tests in dag.rs's existing test module

```gherkin
Scenario: Bm25#search returns a frozen Array like every sibling binding
  When search returns
  Then the outer Array is frozen (out.freeze at lib.rs:1563), matching astgrep/treesitter/fuzzy/prompt
```
→ spec file: `spec/lain/rust/bm25_spec.rb`

One private `fn walk(...) -> impl Iterator`; `ancestor_turns` becomes its `collect()`;
`Timeline::length`/`include_p`/`to_s` (lib.rs:1306-1320,1386) consume it without
materializing Vecs of Arcs.

**Escalation triggers:**
- Any `spec/lain/rust/timeline_spec.rb` example pins the exact Array identity/ordering of `ancestors` in a way the lazy walk changes — ordering is contract (head-first), identity is not; stop only on ordering.

### T10 — Rust small batch: casts, Ord, Role::names, thiserror, silent drain   [wave 1] [risk: low]

**Depends on:** none
**Files:** ext/lain/src/bm25.rs, ext/lain/src/digest.rs, ext/lain/src/event.rs, ext/lain/src/prompt.rs, crates/lain-core/src/exec.rs
**Reuse:** `thiserror` already used in five modules of the crate; the pinned insertion-order tie-break spec for bm25
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a corpus position beyond u32 is a BuildError, not a silent wrap
  When Bm25 build receives a position exceeding u32::MAX (unit-level, via try_from path)
  Then a BuildError is returned
```
→ Rust test in bm25.rs

Also, each with its existing tests staying green: derive `PartialOrd, Ord` on `Digest` and
replace `event.rs:316`'s manual comparator with `.sort()`; make `Role::names()` a `const`
single-sourced by a test over `Role::ALL`; convert `StyleError`/`ConfigError`
(prompt.rs:189-224) to `thiserror` **after checking their module docs for a stated reason
to hand-roll** (the other hand-rolled Displays in the crate each document why); log a
`tracing::error!` on `JoinError` at exec.rs:176-177 instead of `unwrap_or_default`'s silent
empty; reword digest.rs:22,108 "load-bearing" comments to say what work the thing does.
(`Canon::object_from_sorted` moved to T8, which owns `canonical.rs`.)

**Escalation triggers:**
- Derived `Ord` on `Digest` differs from the pinned byte order anywhere a test compares — stop; byte order is the contract.
- `prompt.rs`'s Displays turn out to have a stated hand-rolling reason — leave them, note it, move on.

### T11 — One read_text policy for every text-taking binding   [wave 3] [risk: medium]

**Depends on:** T5
**Files:** ext/lain/src/astgrep.rs, ext/lain/src/treesitter.rs, ext/lain/src/fuzzy.rs, ext/lain/src/prompt.rs, new ext/lain/src/read_text.rs, spec/lain/rust/astgrep_spec.rb, spec/lain/rust/treesitter_spec.rb, spec/lain/tools/ast_search_spec.rb, spec/lain/tools/code_outline_spec.rb, spec/lain/tools/file_symbols_spec.rb
**Reuse:** `fuzzy.rs:508-547` and `prompt.rs:1583-1624` — the two existing correct implementations; `prompt_spec.rb:72-112`'s "string boundary" group is the spec shape to copy verbatim; `fuzzy.rs:504-507` already files this hoist
**Shared-file wiring:** the one-line `mod read_text;` in `ext/lain/src/lib.rs` (orchestrator applies — keeps this card off the T7→T8→T9 lib.rs chain)

**Acceptance criteria:**

```gherkin
Scenario: a non-byte-transparent source is refused, not silently transcoded
  Given a UTF-16LE source string
  When AstGrep.search / AstGrep.dump / TreeSitter.query receive it
  Then an EncodingError naming the encoding is raised, so byte offsets can never index a transcoded copy
```
→ spec files: new "string boundary" groups in `spec/lain/rust/astgrep_spec.rb` and `spec/lain/rust/treesitter_spec.rb`

```gherkin
Scenario: the tool layer reports a refused encoding as an error Result
  Given a file with invalid UTF-8 bytes
  When ast_search / code_outline / file_symbols run on it
  Then the tool returns an error Result naming the problem (today only ast_search rescues, silently)
```
→ spec files: `spec/lain/tools/ast_search_spec.rb`, `code_outline_spec.rb`, `file_symbols_spec.rb`

fuzzy.rs and prompt.rs delegate to the shared function; their existing boundary specs stay
green byte-for-byte.

**Escalation triggers:**
- Existing tool specs feed the tools latin-1-ish fixtures that today "work" via transcoding — behavior change is user-visible; stop and list the affected fixtures before proceeding.

### T12 — lain-core grows a grep RPC   [wave 2] [risk: medium]

**Depends on:** T7
**Files:** crates/lain-core/src/rpc.rs, new crates/lain-core/src/grep.rs, crates/lain-core/Cargo.toml (adds `ignore`, `grep-regex`, `grep-searcher`)
**Reuse:** `exec.rs`'s process/timeout discipline as the module template; the `ping`/`exec` registration shape in rpc.rs:276-280; `deny.toml` licensing gates
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: grep over a tree respects ignore rules and caps matches
  Given a directory with .gitignore'd files and more than the cap of matches
  When the grep RPC runs with a pattern
  Then results exclude ignored files, stop at the cap, and report that the cap was hit
```
→ Rust tests in grep.rs

```gherkin
Scenario: a pathological regex cannot hang the daemon
  Given a regex and corpus that would backtrack catastrophically in a naive engine
  When the grep RPC runs
  Then it completes within the timeout budget (grep-regex is finite-automata) and the RPC surface stays responsive
```
→ Rust tests in grep.rs

Match result shape mirrors `Tools::Grep`'s current output fields (path, line number, line)
so T13 is a transport swap, not a format migration. Cap constant mirrors `MAX_MATCHES = 200`.

**Escalation triggers:**
- `cargo deny check` rejects a transitive license from the ignore/grep crates — stop with the tree; do not add an ignore entry unilaterally.
- The msgpack result for a large match set exceeds a frame size the RPC layer assumes — stop; framing is a design decision.

### T13 — Tools::Grep rides lain-core when a core client is wired   [wave 3] [risk: high]

**Depends on:** T12
**Files:** lib/lain/tools/grep.rb, spec/lain/tools/grep_spec.rb, new spec/lain/core/grep_parity_spec.rb
**Reuse:** `spec/support/shared_examples/exec_boundary_parity.rb` — the existing pattern for proving the in-process and out-of-process paths agree; `Core::Client` (lib/lain/core/client.rb) and the `:core` tag discipline (`spec/support/tags.rb:131`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: with no core client injected, grep behaves exactly as today
  Given a Tools::Grep with no core transport
  When it runs any existing spec scenario
  Then every existing grep_spec example passes unchanged (the Ruby path remains the default)
```
→ spec file: `spec/lain/tools/grep_spec.rb`

```gherkin
Scenario: with a core client, results are identical to the Ruby path
  Given the lain-core daemon built and a corpus with ignored files, caps, and multibyte content
  When the same search runs through both paths
  Then results agree via the shared parity examples
```
→ spec file: `spec/lain/core/grep_parity_spec.rb` (tagged :core)

**Escalation triggers:**
- Ruby-path and core-path results differ on ignore semantics (Dir.glob has no .gitignore awareness today) — parity on that axis is impossible by construction; stop and confirm which semantics win before writing the parity spec.
- `files_under` ends in a global `.sort` (grep.rb:109-116); making it lazy yields per-directory ordering — **a different match set inside the MAX_MATCHES cap**, i.e. a user-visible result change. If the cleanup cannot preserve the capped set, stop and split it out.
- Injecting the client requires widening a toolset construction signature beyond grep's own file — stop; that's a Wiring change belonging to the orchestrator.

### T14 — Bound Scribe#catch_up's walk; build the fetch-count spec helper   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/session_record/scribe.rb, spec/lain/session_record_spec.rb, new spec/support/store_fetch_count.rb
**Reuse:** `Timeline#ancestors`' lazy walk (timeline.rb:96-105); the verified invariant: `@written` is always the ancestor set of `@head` on the current chain (extends_written_chain!, retreat_to, and the resume seed at cli/resume.rb:30 all preserve it)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a second catch_up visits only the new turns
  Given a Scribe caught up to turn N on an instrumented store
  When catch_up runs after one more commit
  Then the walk fetches O(1) turns, not O(N) — counted via the new shared spec/support/store_fetch_count.rb helper (no fetch-count idiom exists in the suite today; this card builds it, T17/T20 reuse it)
```
→ spec file: `spec/lain/session_record_spec.rb`

Every pinned example stays green — especially `:196` and `:230` (identical re-commit digests
re-land after a rewound; the take-while-until-`@head` design must be used). **Mandatory:** an
inline assertion at the fix site that `@head` (when non-nil) is on the walked chain — the
rewrite structurally depends on an invariant that `scribe.rb:156-158` calls an assumption and
that the caller-supplied `written:` seed does not validate; the old filter degraded
gracefully, the new walk must fail loudly instead of silently journaling wrong turns.

**Escalation triggers:**
- Any path is found where `@head` is not on the current chain when catch_up runs (a fork/rewind sequence the grounding missed) — the assertion will catch it in specs; stop immediately.
- `middleware/journal_turns_spec.rb`'s duck-scribe examples start asserting call shapes the rewrite changes — stop; the middleware contract is not this card's to move.

### T15 — Slots and Catalog: load once, render once   [wave 2] [risk: medium]

**Depends on:** none
**Files:** lib/lain/prompt/slots.rb, lib/lain/cli/repl_middleware.rb, lib/lain/cli/command/surface.rb, lib/lain/cli/wiring/toolset_build.rb, spec/lain/prompt/slots_spec.rb, spec/lain/cli/repl_middleware_spec.rb, spec/lain/cli/wiring_spec.rb, spec/lain/cli/wiring/toolset_build_spec.rb
**Reuse:** `surface_spec.rb:52`'s "ONE memoized assembly — identity, not coincidence" idiom; `repl_middleware_spec.rb:77`'s existing injected-catalog seam (T9 precedent); `backend.rb:269`'s existing `@slots ||=` as the one instance to thread
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: one Catalog and one Slots per session
  Given a wired session
  Then the Skill::Catalog reaching /help, the repl stack, and Tools::RunSkill are the same object (equal?), and the Prompt::Slots reaching Backend#context, RoleSpawn, and RunSkill are the same object
```
→ spec file: `spec/lain/cli/wiring_spec.rb`

```gherkin
Scenario: repeated renders return the memoized value; impurity still raises every call
  Given a Slots instance
  Then slots.render.equal?(slots.render) is true, the memo Hash is seeded before initialize's freeze, and an impure slot raises ImpureSlot on every call including after successful renders of other slots (slots_spec.rb:278 pins one raise for one call; the repeat assertion is new)
```
→ spec file: `spec/lain/prompt/slots_spec.rb`

Cache justification (per the interview constraint): key space = the fixed slot/role/skill
names in one catalog; bound = catalog size, session-fixed; consistency = **this card freezes
`@templates`/`@role_templates`/`@skill_slots` at construction** — today `slots.rb:128-130`
stores them unfrozen and the trailing `freeze` at `:131` is shallow, so the frozen-input
argument does not hold until this card makes it hold. Fix the genuinely false clause at
`toolset_build.rb:90-92` ("loaded once from the project root" — false: Catalog loads twice,
Slots three times; the "SAME agent" sentence at `:89` is TRUE and stays).
`ReplMiddleware.build/.renderer` gain a `slots:` parameter (the `catalog:` precedent);
defaults remain for spec compatibility.

**Escalation triggers:**
- Freezing the template ivars breaks any existing example (a writer exists the grep missed) — stop; the memo's consistency argument would be void.
- Any spec constructs `ReplMiddleware` in a way the new keyword breaks — the default-kwarg path must keep `repl_middleware_spec.rb:39,48,62,92` green.
- Anything passes a `Slots` to `Ractor.make_shareable` (grep before starting) — a mutable memo Hash breaks it; stop.

### T16 — Memoize Toolset#to_schema   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/toolset.rb, spec/lain/toolset_spec.rb, spec/lain/cli/wiring_spec.rb
**Reuse:** `toolset_spec.rb:74` ("byte-identical across constructions") is the value contract; the memo-container-seeded-before-freeze pattern (the instance is frozen at toolset.rb:33-34, so lazy computation must write INTO a pre-seeded Hash/container, not assign an ivar)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the schema is computed once per Toolset instance, lazily
  Given a frozen Toolset
  Then to_schema.equal?(to_schema) is true, computation happens on first call (eager-at-construction would charge every #only/#except for a schema that may never render), and a Toolset produced by #only or #except computes its own fresh schema
```
→ spec file: `spec/lain/toolset_spec.rb`

```gherkin
Scenario: the memo actually pays — one session Toolset survives across turns
  Given the chat path (toolset_build.rb:61-64 builds the session toolset once)
  Then the Toolset the agent renders with is the same object across consecutive turns (identity assertion at the wiring level) — without this the memo is unfalsifiable
```
→ spec file: `spec/lain/cli/wiring_spec.rb`

Bound/hit-rate statement: one schema per live Toolset; the chat path holds one for the whole
session (hit on every render after the first); spawn paths (`role.rb:36`,
`spawn_policy.rb:52`, `subagent.rb:395`) mint fresh instances per spawn — each child pays
one compute, bounded by spawn count. `toolset_spec.rb:20` (frozen) and `:47` (#only returns
frozen) must stay green.

**Escalation triggers:**
- Any spec asserts Toolset is Ractor-shareable (grounding found none — re-grep) — the memo container would break it; stop.

### T17 — One walk and one dump per turn on the shipped render/compaction path   [wave 2] [risk: high]

**Depends on:** T14
**Files:** lib/lain/context.rb, lib/lain/compaction/source.rb, lib/lain/compaction/source/derived.rb, lib/lain/compaction/derivation.rb, lib/lain/compaction/head.rb, lib/lain/compaction/need.rb, lib/lain/compaction/scheduler.rb, spec/lain/context_spec.rb, spec/lain/compaction/source_spec.rb, spec/lain/compaction/head_spec.rb, spec/lain/compaction/need_spec.rb, spec/lain/compaction/scheduler_spec.rb
**Reuse:** the shipped path is **Derived** (`source.rb:152` → `source/derived.rb:126` → `Derivation.projected`); the role/content projection is byte-identical at `context.rb:157`, `head.rb:38`, `source.rb:231`, `derivation.rb:133-134` (plus the driver and mailbox variants); `Head` already stores `@bytesize` at construction (head.rb:82); `head_spec.rb:492-531`'s "value-object discipline" group is the staleness contract; T14's `spec/support/store_fetch_count.rb` helper for the count assertions
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: one full walk per lineage per rendered turn on the Derived path
  Given an agent turn flowing through Source::Derived into Context#render
  When the request is rendered
  Then Store#fetch fires once per chain entry per lineage (source timeline + derived timeline), counted via the shared helper — the projection is computed once per lineage and threaded to every consumer, not recomputed per consumer
```
→ spec file: `spec/lain/compaction/source_spec.rb` (count assertion) + `spec/lain/context_spec.rb` (behavioral parity)

```gherkin
Scenario: the compaction path stops re-dumping what Head already measured
  Given a committed turn on the compaction path
  When Need's threshold check and Scheduler's accounting run
  Then they read Head's stored bytesize instead of re-running Canonical.dump on the same messages (dump-count assertion via the timeline_spec.rb:74 stub idiom — correct here because it counts Canonical calls, not fetches), and every existing byte-value assertion (source_spec.rb:715 etc.) stays green
```
→ spec files: `spec/lain/compaction/need_spec.rb`, `spec/lain/compaction/scheduler_spec.rb`

Design per the interview constraint: **threading, not caching** — no memo on Timeline (a new
instance per commit makes per-instance memos near-useless); the walk's owner passes
turns/messages down. `Context#render`'s (timeline, toolset, workspace) purity is preserved.

**Escalation triggers:**
- The single-walk threading cannot be achieved without changing `Context#render`'s public signature — that is an architecture decision (the pure seam is the project's organizing idea); STOP and escalate with the options.
- `source_spec.rb`'s `shrinks?` byte assertions (strict `<` at the crossover, pinned "byte for byte") change value — stop; the bytes are contract.
- `scheduler.rb:188`'s `Ractor.make_shareable` interacts with a threaded projection object — verify shareability is preserved or stop.
- The non-derived (baseline) render path diverges behaviorally from the Derived path after the change — both must render byte-identically to today.

### T18 — Single-pass journal readers   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/grader/frustration_repair.rb, lib/lain/grader/tool_steering.rb, lib/lain/friction/report.rb, lib/lain/bench/session/loader.rb, lib/lain/bench/session/memory_replay.rb, lib/lain/consolidation.rb, matching specs under spec/lain/grader/, spec/lain/friction_spec.rb, spec/lain/bench/session/, spec/lain/consolidation_spec.rb
**Reuse:** `Grader::ToolCallIndex` (the object being shared); the inject-don't-construct rule CLAUDE.md states via Agent::Budget
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: one Friction report builds one ToolCallIndex
  Given a Friction::Report render over recorded entries
  Then FrustrationRepair and ToolSteering receive the report's index via a tool_call_index: keyword (defaulting to self-built when absent) and the same records are parsed once, not three times
```
→ spec file: `spec/lain/friction_spec.rb`

```gherkin
Scenario: session loading scans the record array once per query type
  Given a loaded bench session
  Then Loader#of_type answers from a group_by built at initialize (missing types default to []), memory_replay computes write_calls once per record, and Consolidation::Lineage's chain_root memoizes digest→root within one from_records call
```
→ spec files: the bench session specs, `spec/lain/consolidation_spec.rb`

All memos here are per-call/per-instance and bounded by input already in memory — no
cross-call caches (interview constraint satisfied by construction).

**Escalation triggers:**
- Any `of_type` caller depends on fresh-scan behavior for unknown types beyond the [] default — stop.

### T19 — prefix_digests: measure, then decide   [wave 2] [risk: medium]

**Depends on:** none
**Files:** lib/lain/request.rb (only if the measurement justifies), spec/lain/request_spec.rb, planning/reviews/2026-07-29-simplification-review.md (record the verdict in §3.6)
**Reuse:** `request_spec.rb:196-234`'s rolling-chain examples define the algorithm byte-for-byte; the compaction cost measurement idiom at source.rb:283-287
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the cost and the hit rate are measured before any code changes
  Given a representative replayed session (bench fixtures)
  When per-turn prefix_digests cost is measured across session lengths
  Then the card produces numbers: ms per turn at n=10/100/500 messages, plus the projected memory of a per-message digest table and its hit rate across consecutive Requests
```
→ measurement recorded in the card's commit message and the review doc §3.6

```gherkin
Scenario: a change lands only if the measurement justifies it, and renegotiates the count specs deliberately
  Given the measurement shows material per-turn cost AND a bounded consistent design exists
  When the fix lands
  Then request_spec.rb:220 and :277 are REWRITTEN (not deleted) to pin the new count contract, AmbiguousMarkerPosition still raises on repeat calls, and :295's deep-frozen/Ractor-shareable assertion stays green
```
→ spec file: `spec/lain/request_spec.rb`

"Not worth it" is an acceptable outcome — the deliverable is then the measurement plus a
§3.6 note, no code change.

**Escalation triggers:**
- The only workable design requires mutable state reachable from the frozen Request — breaks `:295`; stop, record, close as measured-and-declined.

### T20 — Restore early exit to the latent Timeline walks   [wave 2] [risk: low]

**Depends on:** T14
**Files:** lib/lain/timeline.rb, spec/lain/timeline_spec.rb
**Reuse:** `#ancestors`' lazy generator (timeline.rb:96-105); the append/pop work-stack discipline already commented in CausalAncestry#closure; T14's fetch-count helper
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: include? stops at the answer
  Given a long chain whose target digest is one hop from head
  When include? / ancestor_of? / meet's find-side run
  Then the walk visits O(answer) turns (counted via spec/support/store_fetch_count.rb), and topological_rank's queue is an index cursor, not Array#shift
```
→ spec file: `spec/lain/timeline_spec.rb`

All four semilattice law groups and the dominator memo group (`timeline_spec.rb:373-390`)
stay green. These methods have zero production callers today (verified) — the payoff is the
property-law suite and the speculative-branching future; keep the diff minimal.

**Escalation triggers:**
- The Rust parity specs (`spec/lain/rust/timeline_spec.rb`) compare behavior in a way the Ruby-side change diverges from Ext — parity outranks the optimization; stop.

### T39 — Write the record: doc drift, ROADMAP entries, the parity table, the triage item   [wave 1] [risk: low]

**Depends on:** none
**Files:** ARCHITECTURE.md, ROADMAP.md, lib/lain/compaction.rb (module doc only), new planning/rust-parity-gap.md, planning/reviews/2026-07-29-simplification-review.md (cross-link)
**Reuse:** the Rust-recon parity table (Ruby↔Ext method-by-method, the six duck-typed Store object kinds, the causal_parents/payload/block-form gaps) — reproduce it in planning/rust-parity-gap.md as the next chunk's grounding
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the docs stop lying
  When the stale claims are fixed
  Then ARCHITECTURE.md's isolation wiring status matches cli/isolation_backend.rb, the "~20 guarded event kinds" count is current, and compaction.rb's module doc names its twelve members and states which compaction design is the shipped path (Derived) vs the bench arm (Context::Compact) — the toolset_build.rb:90-92 false clause is T15's to fix in code
```
→ files above (prose)

```gherkin
Scenario: the ROADMAP gains the three ruled entries
  When ROADMAP.md is updated
  Then it contains: (1) an epic-tier entry recording what shipped and that it awaits the epic-orchestration review; (2) a next-chunk item for the Rust Timeline/Store parity gap + wiring decision, pointing at planning/rust-parity-gap.md; (3) a triage item for the 30 unwired seams (including the sweep doors and disclosure/Prepared deletion candidates) — "confirm each is still needed before wiring or deleting"
```
→ ROADMAP.md

**Escalation triggers:**
- ROADMAP's structure resists a clean place for the entries — propose placement in the commit message rather than restructuring the document.

## Integration checks

- `bundle exec rake compile && bundle exec rspec` — measure the example count against a
  pre-chunk serial run (the parallel-runner dead-worker trap in CLAUDE.md).
- `bundle exec rubocop` clean with **no** config changes (any Metrics trip = a missing
  collaborator, per CLAUDE.md — escalate, don't loosen).
- `cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt -- --check && cargo deny check`
  after every Rust-touching wave; verify `nu-ansi-term` is absent from Cargo.lock after T7.
- `bundle exec rake core:build && bundle exec rspec --tag core` (T12/T13's :core specs).
- `pre-commit run --all-files` before each orchestrator commit (the hook stashes unstaged
  tracked changes — commit in dependency order per CLAUDE.md).
- **Manual (Joel):** one `lain up` smoke pass on the new PATH derivation (T4) — panes must
  come up on 4.0.6; one `lain bench plan-sweep` determinism check after T3.
