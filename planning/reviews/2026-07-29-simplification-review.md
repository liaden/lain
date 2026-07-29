# 2026-07-29 — Simplification & efficiency review

**Status: findings only — no code was changed.** Every claim below was made by a reviewer that
read the cited code, and the eight highest-impact claims were independently re-verified by an
adversarial pass that tried to refute them (verdicts noted inline). Line numbers are as of
`d0c7a3b`.

How it was produced: ten area reviewers (one per subsystem, each covering its specs), a
system-level architecture review grounded in ROADMAP/planning docs, a cross-cutting
code-smell/arity review seeded by a Prism scan of all 134 defs with ≥5 params, a Rust-depth
review, a Prism clone scan over `lib/` with a judgment pass on every hit, and the adversarial
verifier. A parallel session's subagent-subsystem audit is folded in as well.

**Headline.** The codebase is in much better shape than a 70k-line review usually finds: across
every area, WHAT-only comments are essentially absent, RuboCop-dodge micro-abstractions don't
exist (every `Metrics`-triggered extraction checked has a real second responsibility), and no
gem-replacement candidate survived scrutiny anywhere. The real findings are different in kind:
**seams built faster than callers arrive** (§1), **a handful of shipped defects** found along the
way (§2), **per-turn recomputation the content-addressed design was supposed to prevent** (§3),
**missing value objects behind the long parameter lists** (§4), and **duplication that wants the
extraction discipline the repo already practices** (§5).

---

## 0. Ranked shortlist — if only ten things get done

| # | Action | Section | Effort | Confidence |
|---|--------|---------|--------|-----------|
| 1 | Decide the unwired-seam inventory: doors for roadmapped seams, deletion for ruled-out ones (4,353 lines / 30 files with zero production callers) | §1.1 | M | high |
| 2 | Fix the five shipped defects: streaming error crash, `gsub` interpolation, PlanSweep dropping `system:`, `up.rb` pinning ruby-4.0.5, `AstGrep.dump`'s quadratic output blowup | §2 | S each | high (all verified) |
| 3 | Memoize the render path: `Timeline#messages` by head digest + `Toolset#to_schema` — three full walks and ~30 schema rebuilds per turn today | §3.1 | M | high |
| 4 | Fix `Scribe#catch_up` O(n²) — full timeline re-walk per tool-loop iteration | §3.2 | M | high (verified incl. fix) |
| 5 | Memoize `Prompt::Slots#render*` — full ERB parse + Prism purity walk per subagent spawn | §3.3 | S | high (verified) |
| 6 | Widen `Compare::Run` to a `metrics:` hash; collapse the five hand-rolled sweep folds (~330 lines) | §1.3 | M | high |
| 7 | `Agent#initialize`: accept `ModelCaller`/`ToolRunner`/`Accounting` instead of their six pass-through ingredients | §4.1 | M | high |
| 8 | Extract the shared arm substrate (`timed`/price/lease duplicated ×3–4 — the bench's comparison metrics agree by copy today) | §5.2 | M | high |
| 9 | Split `telemetry.rb` (1,660 lines, 18 module reopenings) into the index+directory convention everything else follows | §5.6 | M | high |
| 10 | Delete/shrink the low-value tests (§6) and land the doc-drift fixes (§8) | §6, §8 | S | high |

---

## 1. Architecture: premature and wrong abstractions

### 1.1 The unwired-seam inventory — 4,353 lines with zero production callers

Thirty files in `lib/` are reachable only from their own specs (grep-verified per constant,
comments excluded). The bench's premise is "swap a strategy, run both, compare" — these seams
exist while the doors that would let anything swap them do not. Largest units:

| Unit | Lines | Situation |
|---|---|---|
| `approval/gate.rb` + `gate/policy.rb` + `gate/adjudicator.rb` + `adjudicator/{evidence,outcome}.rb` | 1,051 | No ROADMAP mention; ~1,900 lines of spec; zero callers |
| `bench/arm_sweep.rb` + subfiles | 491 | `Bench::CLI#arm_sweep_report` exists but no Thor door; ROADMAP §19 calls it "still doorless" |
| `bench/decider_sweep.rb` + subfiles | 422 | ROADMAP calls it "the headline experiment"; no CLI method, no door |
| `supervisor/restart.rb` | 382 | ROADMAP §10 flagship |
| `bench/disclosure_sweep.rb` + `toolset/disclosure.rb` + `tools/tool_search.rb` | 332 | ROADMAP §13 **ruled the disclosure arms out** during planning; the machinery shipped anyway |
| `compaction/prepared.rb` | 230 | Built to pair with `Context::Compact`; orphaned by the chunk-16 migration (§1.4) |
| ~15 more (`bench/speculative.rb`, `grader/{verified,refuter}.rb`, `context/{prune,dedupe_tool_calls,purge_failed_inputs}.rb`, `core/child.rb`, `core/transport/vsock.rb`, `tools/core_exec.rb`, `arm/adaptive_router.rb`, `plan/calibration.rb`, `gherkin/test_generation.rb`, `embedder/static.rb`, …) | ~1,445 | Mixed |

Notably, `Bench::Speculative` has zero callers while `ARCHITECTURE.md:656-658` names it as the
payoff of the whole content-addressed design — the architecture document's flagship claim is
unexercised. The Rust side has the same shape: ~2,200 lines (`dag.rs`, `digest.rs`,
`canonical.rs`, `event.rs`, plus the Turn/Store/Timeline FFI in `lib.rs`) are a parity-tested
shadow implementation with **zero production callers** — of the whole `Lain::Ext` surface,
`lib/` uses exactly six things: `blake3_hex`, `Bm25`, `AstGrep`, `TreeSitter`, `Fuzzy`,
`Prompt` (§10.2). Also: the word "Gate" now names four objects (`Effect::Handler::Gate` live,
`Approval::Gate` unwired, `Oracle::MemorySave::Gate`, plus `Approval::Queue` vs
`Approval::SignoffQueue` as two approval queues).

**Recommendation.** Split the list in two. (a) Seams with a ROADMAP story and a plausible
near-term caller get a **door in the same commit as the seam** (see §2.5 — `DeciderSweep` and
`DisclosureSweep` are fully spec'd but unreachable without throwaway Ruby). (b) Seams whose
future was ruled against (`disclosure_sweep` machinery, `Compaction::Prepared`) get deleted; the
spec and git history are the record. Then add a lint spec — a `lib/` class with zero
`lib/`+`exe/` references and no explicit marker fails — so the inventory can't silently regrow.
The `chunk-derived-context-timeline.md:171` F7 catalogue already tracked nine of these; the
count roughly doubled since. **Effort:** S (lint) / S (deletions) / M (doors). **Confidence:** high.

### 1.2 The epic tier shipped ahead of its own approval gate

`lib/lain/epic/` (1,837) + `cli/epic.rb` (441) + `cli/epic_queue.rb` (353) + the sign-off half of
`approval/` (~1,347) = **3,978 lines, 6.6% of `lib/`**, landed over the last few days. ROADMAP
contains the string "epic" zero times; the grounding doc `planning/epic-orchestration.md:3-4`
still reads "Status: draft — awaiting Joel's review (gate 1 of the very flow it describes)."
Over a quarter of what shipped (`Approval::Gate` + adjudicator) has no caller in either the epic
CLI or the chat path.

**Recommendation.** Before anything else in this document: a ROADMAP entry describing what
shipped and what it waits on. Until the map matches the territory, no single-implementation seam
in the repo can be judged "justified by committed direction." **Effort:** S (doc) / L (unwind if
that's the ruling). **Confidence:** high on the facts.

### 1.3 `Compare::Run` is the wrong abstraction — five sweeps prove it

`Compare::Run` (`compare.rb:24-45`) closes the metric set at `(usage, cost, score, degraded)`.
Four of the five sweep drivers document in their own class comments why they could not reuse it
(`bench/sweep.rb:12-18`, `bench/disclosure_sweep.rb:20-26`, `bench/arm_sweep/report.rb:8-19`,
`bench/plan_sweep/report.rb`), each re-rolling the same fold — measurements → per-arm
`Distribution` per metric → titled table — for ~330 lines of report code total. `Compare::Table`
was already extracted once from two byte-identical copies; the fold is the remaining duplication.

**Recommendation.** Widen `Compare::Run` to `(name, metrics: Hash<Symbol, Numeric>, degraded:)`
with `usage`/`cost`/`score` as named metric builders, and one `Compare#report(order:, sections:)`
absorbing all five folds. Sweeps shrink to axis definitions — which is what ROADMAP's
"one seam, many swept axes" and the parked experiment DSL (`ROADMAP.md:506-517`) assume exists.
**Effort:** M. **Confidence:** high.

### 1.4 Compaction's migration stopped halfway

Chunk 16 moved compaction to a derived second lineage and explicitly ruled out retiring
`Context::Compact`. Result: two live designs. The chat path runs `Source::Derived` +
`Compaction::Derivation`; `Context::Compact` survives with two callers
(`plan/linear_rewrite.rb:106`, `bench/plan_sweep/driver.rb:157`). Meanwhile `Compaction::Head`
and `Compaction::Boundary` still document themselves as `Context::Compact`'s collaborators
(`head.rb:6,63,133,147`; `boundary.rb:6,111`) while their live caller is `Source#decide`;
`Compaction::Prepared` is orphaned entirely; and `compaction.rb:16-22`'s module doc says the
module has one member when it has twelve.

**Recommendation.** Either finish the migration (retire `Context::Compact`, re-home
`Head`/`Boundary` under `Derivation`, delete `Prepared`) or state in `compaction.rb` which design
is the shipped path and which is the bench arm. **Effort:** M. **Confidence:** high.

### 1.5 What was checked and judged correct as built

For calibration: the `ChatLaunch` → `Wiring` → `Repl` chain (each layer owns a real ordering
guarantee; no pass-throughs found in `cli/`), `Compaction`'s `Head`/`Need`/`Cold`/`Scheduler`
split, `Store`'s locking and O(1) lookup, `Timeline::Dominators`' memoization, `Canonical`'s
measured allocation choices, `Toolset`'s attenuation model, the vendored `provider/http/` split
files (every one has a real responsibility per VENDOR.md's claim), the `Consolidate`-area
strategy seams, and the entire compaction/memory area (the one area with effectively zero
findings). Every `Agent::Budget`-style extraction checked has independent responsibility.

---

## 2. Shipped defects (found incidentally; all verified)

1. **Streaming error-path crash.** `provider/http/streaming/error_handling.rb:39-42`:
   `handle_error_chunk` does `chunk.split("\n")[1].delete_prefix("data: ")` on the raw Faraday
   fragment. When a TCP boundary splits `event: error\n` from its `data:` line, `[1]` is `nil` →
   uncaught `NoMethodError` in place of the typed error. Verified: the `event_stream_parser` gem's
   `:error` dispatch in the same file already handles the identical event with correct
   cross-fragment buffering, so the raw fast path can be deleted outright. Keep
   `json_error_payload?` — raw JSON bodies would mis-parse as SSE. The one covering spec delivers
   the whole body in one WebMock chunk and still passes after the fix. Inherited from vendored
   `ruby_llm`. **Effort:** S. **Verified: CONFIRMED.**

2. **`gsub` replacement-string interpolation.** `structural/patterns.rb:43` uses
   `pattern.gsub(token, value)`; Ruby expands `\1`/`\&`/`\\` in the *replacement* even with a
   plain-String pattern (verified live in a 4.0.6 REPL). Reachable from model-supplied input
   today: `Tools::AstSearch::Input#name` is an unconstrained string that flows into
   `interpolate`, so a backslash-bearing name silently corrupts the ast-grep pattern. Fix is the
   block form: `pattern.gsub(token) { value }`. **Effort:** S. **Verified: CONFIRMED.**

3. **Bench-fidelity drift: PlanSweep drops `system:`.** `plan/runner.rb:139` rebuilds
   `Context.new(model:, max_tokens:, system:, pipeline:)`; `bench/plan_sweep/driver.rb:181`
   rebuilds it *without* `system:` — a swept plan renders a different prompt than the same plan
   under `Plan::Runner`. Root cause is carrying `(model, max_tokens, system)` as loose primitives
   instead of a `context:`; `Context#with_pipeline` (`context.rb:143`) already exists and makes
   the divergence unrepresentable. **Effort:** S. **Confidence:** high.

4. **`lain up` spawns every pane on the forbidden Ruby.** `cli/up.rb:71` hardcodes
   `export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"` — the exact version CLAUDE.md documents as
   intermittently crashing the VM (`[BUG] should have cvar cache entry`). Every tmux pane `lain
   up` creates re-execs under 4.0.5. The toolchain bump missed it. (Also stale prose at
   `provider/http/configuration.rb:20`.) **Effort:** S. **Confidence:** high.

5. **Two sweeps are unreachable.** `DeciderSweep` and `DisclosureSweep` are implemented and
   spec'd (46 passing examples) but appear in neither `bench/cli.rb` nor `exe/lain` — a
   researcher cannot run either without throwaway Ruby. (Subject to the §1.1 ruling: door for
   decider, likely deletion for disclosure.) **Effort:** S. **Confidence:** high.

6. **Fixture arm-list drift trap.** `bench/decider_sweep/fixture.rb:47` hand-types the arm list
   as a `%w[...]` literal instead of deriving it from `ARMS` (`decider_sweep.rb:75`); adding an
   arm produces a bare `KeyError` at replay instead of the load-time `MalformedCase` the class
   exists to guarantee. **Effort:** S. **Confidence:** medium.

7. **`AstGrep.dump` output is quadratic in nesting depth, uncapped, in production.**
   `ext/lain/src/astgrep.rs:185` does `"  ".repeat(depth)` per node → O(depth²) output bytes.
   Measured through the built extension: a ~10 KB input at 5,000 nesting levels yields a
   **75.1 MB** frozen Ruby String; 50,000 levels did not complete in 120 s. Reachable through
   ordinary tool use (`Structural::Matcher#dump` → `tools/ast_search.rb`), and unlike
   `Tools::Grep` (`MAX_MATCHES = 200`) there is no output bound. Fix: loop the indent instead of
   allocating per node, then cap depth or total output with a loud `SearchError`. **Effort:** S.
   **Verified: measured.** (The related unbounded-recursion issue is §10.1 item 2.)

---

## 3. Performance and efficiency

### 3.1 The render path bypasses the Merkle DAG (architecture-level)

Per live chat turn the conversation history is walked and rebuilt three times —
`compaction/source.rb:193-194` (`timeline.to_a` + projection), `context.rb:157` (the same walk
and the same projection again), `request.rb:26` (`Canonical.normalize` re-normalizing content
that `event/payload.rb:24` already normalized and froze at commit time). A fourth per-turn
rebuild: `toolset.rb:99-101` re-derives ~23–30 JSON Schemas from ActiveModel reflection
(`tool/input.rb:103-110`) and deep-normalizes them on every `Context#render`, even though
`Toolset` and its tools are frozen — these are precisely the bytes that must be
cache-prefix-stable, recomputed instead of memoized.

The message list for a head digest is by construction the parent's list plus one element — the
guarantee `Ledger` already exploits (`ledger.rb:112-119`). The projection
`timeline.to_a.map { role/content }` appears verbatim in four places (`context.rb:157`,
`compaction/head.rb:38`, `bench/plan_sweep/driver.rb:188`, variant at `context/mailbox.rb:81`).

**Recommendation.** `Timeline#messages`, memoized by head digest (fixes the duplication and the
recomputation in one move), plus a digest-keyed memo for `Toolset#to_schema`. The cost shape is
already measured (`compaction/source.rb:283-287`: 3.6 ms per turn on an 84 KB history, "wasted on
every turn"); on a `DryReplay` sweep over thousands of recorded turns this is the dominant cost.
**Effort:** M. **Confidence:** high.

### 3.2 `SessionRecord::Scribe#catch_up` is O(n²) per session — the hottest real finding

`middleware/journal_turns.rb:29-31` calls `@scribe.catch_up(@timeline.call)` on **every
tool-loop iteration**; `scribe.rb:81` then does `timeline.to_a` (full head-to-root walk, one
`Store#fetch` under `Monitor#synchronize` per step) and rejects the already-written prefix. For
a session with N turns, iteration *i* re-walks ~i turns.

**Verified fix** (hand-traced against every pinned case in `session_record_spec.rb`): `@written`
is provably always the ancestor set of `@head` on the current chain — `extends_written_chain!`,
`retreat_to`, and the resume seed (`cli/resume.rb:30`) all preserve it — so walk backward and
stop at the boundary: `timeline.ancestors.lazy.take_while { |t| t.digest != @head }.to_a.reverse`
(nil `@head` → walk to root). Caveat from the verifier: the fixed version *depends* on that
invariant structurally where the old filter degraded gracefully, so add a comment or assertion at
the fix site. **Effort:** M. **Verified: CONFIRMED.**

### 3.3 `Prompt::Slots#render*` re-parses ERB + re-walks Prism per subagent spawn

`prompt/slots.rb:136-169` rebuilds a `LockedBinding`, re-runs `ERB.new(...).result`, and re-runs
the full Prism purity walk on every call; called per spawn via `role.rb:49-52` →
`tools/subagent.rb:432`. The purity checker is a default-reject allowlist, so renders are
provably pure functions of state frozen at construction — the class's own comments assert the
byte-identity that makes caching safe. Verified: cooperative-fiber concurrency only (no lock
needed); the memo Hash must be created **before** `initialize` calls `freeze` (mutating contents
after freeze is fine; reassigning the ivar is not); freeze cached strings defensively since all
callers will share one object. **Effort:** S. **Verified: CONFIRMED.**

### 3.4 `Skill::Catalog` / `Prompt::Slots` loaded 2–3× per session against their own contract

`catalog.rb:34-40` documents "the one disk read"; in fact `Catalog.load` fires at
`cli/command/surface.rb:35` *and* via the default-kwarg in `ReplMiddleware.renderer`
(`repl_middleware.rb:36`, reached from `toolset_build.rb:92` every session). `Prompt::Slots.load`
fires three times (`surface.rb:55` path, `toolset_build.rb:92` path, `backend.rb:269`) and has
**no injectable parameter anywhere** today. `toolset_build.rb`'s comment claiming the repl and
`run_skill` share "the SAME construction" is wrong. Verified; fix is threading one instance
through `Wiring` (needs a new `slots:` parameter on `ReplMiddleware.build`/`.renderer` — the
`catalog:` precedent already exists). Startup-time cost only, but it's a documented invariant
being violated. **Effort:** S–M. **Verified: CONFIRMED.**

### 3.5 One `Friction::Report#render` parses the same Journal slice three times

`friction/report.rb:83` builds a `ToolCallIndex`; `FrustrationRepair#signals`
(`frustration_repair.rb:84-87`) and `ToolSteering#flags` (`tool_steering.rb:124-131`) each build
their own from the same entries — no injection seam. Add an optional `tool_call_index:` keyword
to both, defaulting to internal construction. **Effort:** M. **Confidence:** high.

### 3.6 `Request#prefix_digests` — O(n²) digests per session, fix is Ruby-side caching

`request.rb:136-239` computes ~n `Canonical.digest` calls per turn (each a full normalize +
`JSON.generate` + blake3 over one message), so O(n²) per session — after
`strip_cache_markers` (`request.rb:233-239`) has already rebuilt a parallel tree of every
message. The cache-breakpoint chain is capped at 4 entries, yet every message up to the deepest
cut is digested. Messages are `Canonical`-normalized and deeply frozen at commit, so a
per-message digest is a pure function of an immutable value — memoize it (e.g. a digest side
table keyed by object identity or content hash) and the quadratic collapses with no FFI. Same
family: the compaction path runs six full-history `Canonical.dump`s per turn (`head.rb:82`,
`need.rb:58` re-dumping what `Head` just dumped, `source.rb:343` ×2, `scheduler.rb:212-213`) —
memoizing the dump on the frozen `Head` removes ~4 of 6. **Effort:** S–M. **Confidence:** high
(from the Rust-depth reviewer's migration analysis, §10.3, which concluded these are caching
problems, not porting problems).

### 3.7 Smaller confirmed items

- `Consolidation::Lineage.from_records` (`consolidation.rb:164-184`): `chain_root` re-walks
  parent pointers per record with no memo — O(L²) on lineage depth. Memoize `digest → root`.
  **S, medium.**
- `Bench::Session::Loader#of_type` (`loader.rb:118-120`): fresh linear scan per call, ~8 call
  sites per session load. `group_by` once in `initialize`. Related: `memory_replay.rb:53-67`
  computes `write_calls(record)` twice per write-bearing turn. **S, high.**
- `Structural::Matcher#match` (`matcher.rb:82-94`): per-match `byteslice(0, start).count("\n")`
  → O(n·L) per tool call. Precompute newline offsets once per source. **S, medium.**
- `Plan::Calibration#drift_table` (`calibration.rb:123-135`): recomputes each size-class
  distribution per chunk — O(n²). **Verified CONFIRMED but currently cold** (no CLI wires
  `#render`; only `seam_decision.rb` calls `median_turns`). Fix when wiring it. **S.**
- `Timeline#include?`/`#ancestor_of?`/`#meet` (`timeline.rb:107-138`): `ancestor_digests` is a
  plain `.map`, materializing the full chain and defeating `#ancestors`' streaming; and
  `Dominators::Tree#topological_rank` (`timeline.rb:400-409`) uses `frontier.shift` — O(n²)
  Kahn's. **Both verified CONFIRMED but with zero production callers today** — they speed the
  property-law suite and the speculative-branching future, nothing live. Fix opportunistically
  (`ancestors.any? { }` short-circuits on a plain Enumerator; index-cursor for the queue). **S.**

---

## 4. Long parameter lists → missing abstractions

From a Prism scan: 134 defs in `lib/` with ≥5 params. `Metrics/ParameterLists:
CountKeywordArgs: false` means nothing mechanical polices this axis. Most of the list is fine —
composition roots (`Wiring`, `TTY`, `Compaction::Source`, `Surface`) and `Data.define` records
whose arity *is* the wire shape were checked and explicitly cleared. The real findings:

### 4.1 `Agent#initialize` — 18 params, 6 of them pure pass-through ★

`agent.rb:73`: six keywords (`provider:`, `model_middleware:`, `handler:`, `tool_middleware:`,
`tool_observer:`, `journal:`) are never stored — they exist only to be relayed one hop into
`ModelCaller`, `ToolRunner`, and `Accounting`, which `Agent` constructs itself
(`agent.rb:214,234`; grep confirms no `@journal`/`@provider` ivar exists). The collaborators
were extracted as real objects but the constructor still assembles them, so `Agent` knows what a
middleware stack is made of and every new knob widens its surface. Accept the three
collaborators; the spec-compatible path is accepting `model_caller:`/`accounting:` *in addition*
with defaults built from the old keywords, then deprecating. (~40 specs construct by the old
names.) **Effort:** M (L with spec migration). **Confidence:** high.

### 4.2 Two data clumps the codebase found and then reified as Hashes

- **Instrumentation clump**: (`journal:`, middlewares, `tool_observer:`, `transition_listener:`,
  `pipeline_source:`) — already bundled as `CompactionMount#agent_kwargs` (`compaction_mount.rb:52`)
  and `Chronicle#telemetry_kwargs` (`chronicle.rb:124,255`), then poked with
  `.fetch(:journal) { Null }`, `.slice(:journal)` (`tool_guard.rb:33`), and `.merge`. Make it
  `Agent::Instrumentation = Data.define(...)` with all-Null defaults and `#with`. Do after 4.1
  (they overlap on `journal:` and the middlewares). **M, medium.**
- **Child-spawn clump**: (`provider`, `context_factory`, `parent`, `journal`, `supervisor`,
  `observer`) — already bundled as `ToolsetBuild#child_seam_kwargs` (`toolset_build.rb:83`),
  splatted into `Tools::Subagent` (14 params, `subagent.rb:93`), `RoleSpawn` (9 params,
  `role_spawn.rb:32` — which stores 8 ivars just to re-thread them), and `ChildBuilder`
  (`subagent.rb:350`). The comment at `toolset_build.rb:9-12` states the principle ("a triple
  passed identically at every call is state an object is missing") and then implements it as a
  Hash. Make it `Spawn::Seam = Data.define(...)`; `Subagent` 14→8, `RoleSpawn` 9→3. **M, high.**

### 4.3 Backend flag sextet

`(provider_name:, api_base:, model:, max_tokens:, temperature:, seed:)` carried loose through
`bench/cli.rb:193` and `bench/spawn_seam.rb:55` only to be handed to `Backend.new` on the next
line, while the chat path already passes `Backend.new(options)` — two call styles for one
object. Both should take `backend:`. **S, high.**

### 4.4 `(model:, max_tokens:, system:)` primitives

`plan/runner.rb:68` and `bench/plan_sweep/driver.rb:76` — this is the clump that already caused
defect §2.3. Both should take `context:` and use `Context#with_pipeline`. **S, high.**

### 4.5 Vendored HTTP payload set

Eight keywords re-declared through `provider.rb:94` → `:154` → `anthropic/chat.rb:39` with one
transformation between them. A `WirePayload` value object collapses the middle signature —
lower priority, vendored code. **M, medium.**

---

## 5. Duplication and anti-patterns

Byte-identical duplication was found both by area reviewers and by a Prism clone scan (bodies
hashed with comments/whitespace stripped); every group below was judged individually — four
groups (Enumerable `#each` ducks, Null-Object `#each`, single-ivar freeze constructors ×2) were
ruled **idioms, not to be coupled**, and are omitted.

### 5.1 Provider family (anthropic ↔ bedrock ↔ ollama ↔ embedder)

`anthropic.rb` and `bedrock.rb` duplicate byte-for-byte: the rate-limit reset-header parser
(anthropic.rb:48-64 / bedrock.rb:38-54), `APIError`/`APIStatusError`, `#wire_payload`,
`#normalize_tool_inputs`, `#build_usage`, `#build_response`, `#wrap_error` — the
`AnthropicEncoding` shared-module pattern applied to the request side but never the response
side. Both files carry the same open question about which rate-limit header governs backoff — a
fix to one arm silently misses the other. Bedrock also reimplements `RetryTap` inline. The clone
scan showed the family is wider: `#wrap_error` ×4 and the `APIStatusError` initializer ×4 extend
to `provider/ollama.rb` and `embedder/ollama.rb`; `#build_config` is identical between the two
ollama files; and Ollama's divergences look unintended (no `channel:`, so no retry journaling;
no timeout/retry envelope override).

**Recommendation** (verified against specs that rescue by nested-constant identity):
- `Provider::HTTP::ErrorWrapping` concern whose `included do` defines per-class
  `APIError`/`APIStatusError` plus `#wrap_error`, parameterized on the base error class. **M.**
- `Usage.from_anthropic_wire(hash)` on `Usage` itself — the third copy of `#build_usage` is
  `session_record/salvage.rb:250`, which decodes the same wire shape and isn't a Provider, so
  the value object is the right home. **S.**
- A shared response-handling module (or `Provider::HTTP::Backend` base owning the
  `config || build_config` / `transport || Transport.new` bracket) for the rest, making each
  divergence a deliberate override. **M.**

### 5.2 The arm family — bench metrics agree by copy

`#timed` is byte-identical ×4 (`single_thread.rb:81`, `adaptive_router.rb:112`,
`dual_ledger.rb:132`, `orchestrator_worker.rb:146`), and because it discards the block's value,
two call sites use a mutable-capture workaround. The `Ledger.from_journal(...)` pricing line ×3,
the `Run.new(...)` tail ×4, the lease/reclaim/`ensure`-surrender bracket ×3, and
`DEFAULT_CLOCK` ×2 complete the set. These are the bench's headline metrics (`elapsed`,
`ledger`) agreeing across arms by copy-paste; no test catches disagreement.

**Recommendation.** `Arm::Instrument = Data.define(:clock, :price_book)` with
`#timed { } → [elapsed, result]` and `#price(journal)`; `Arm#leased(isolation:) { }` for the
bracket; drop `AdaptiveRouter::DEFAULT_CLOCK`. Each arm loses 3 params and ~15 lines. **M, high.**

### 5.3 CLI: session resolution and tmux

- **Three byte-identical `resolve`/`dir`/`SessionNotFound` sets** (`friction.rb:13,31-37`,
  `improve.rb:40,194-200`, `consolidate.rb:13,57-63`) — while `cli/session_journals.rb`'s
  40-line class comment argues for exactly this consolidation and names these files as intended
  adopters; only `epic.rb`/`epic_queue.rb` migrated. Counting `Resume::Selector`, `Sessions`,
  and `Watch`, there are six session-discovery mechanisms. Extract `CLI::SessionSelector`, fold
  into `SessionJournals`, and consider a `CLI::JournalPass` base for the three commands (same
  resolve → records → dry-run/run → render shape). **S, high.**
- **Two independent tmux clients**: `up.rb:236-247` and `tmux_surface.rb:163-177` each define
  `act` (byte-identical), `run`, `socket_flag`, `TmuxUnavailable`. `TmuxSurface` becomes the one
  client; `Up` injects it (its `shell_out_factory` seam makes this a two-line change). **S, high.**
- **`.lain/` resolved by string literal in five Ruby places** (`status_feed.rb:443`,
  `cli/up.rb:260`, `frontend/tty.rb:90`, plus the nvim/tmux plugins) despite `Paths` being "the
  one naming authority"; plus two near-identical `.lain/` DSL loaders (`summarizer.rb:21-29` vs
  `isolation/services.rb:24-31`, same class modulo names, same unsandboxed `instance_eval`
  posture). A `ProjectDir` locator + a `DslCatalog` base; `wiring.rb:145-149` already flags a
  project-root flag as a coming need. **S, high.**

### 5.4 Flag argument → nil collaborators (`Consolidate`/`Improve`)

`consolidate.rb:42` / `improve.rb:139`: `report_for(selector, dry_run: false)` selects between
two unrelated behaviors, and the flag propagates upward into
`provider: (backend.provider unless options[:dry_run])` — four collaborators defaulted to `nil`
with a hand-rolled call-time `require!` (`consolidation.rb:54,145`), the exact posture
`Command::Surface` documents itself as rejecting. Replace with a `Provider::Unreachable` Null
(raises "assembled for --dry-run" on `#complete`), required keywords, and separate
`#report`/`#dry_report` methods. The two classes are also structurally the same class (~60
duplicated lines). **M, high.**

### 5.5 Demeter chains and the clock

- `env.agent.timeline.head_digest` and friends: nine 2-3-hop chains across six command classes
  (`btw.rb:76`, `meta.rb:127`, `fork.rb:50,101`, `pin.rb:109-110`, `unpin.rb:28`,
  `rewind.rb:30`, `inspection_binding.rb:24`, `keep.rb:53`), plus
  `env.chronicle.catch_up(env.agent.timeline)` duplicated ×3. `Env` claims to be "the one value
  a command reads its collaborators through" — give it `#head_digest`, `#timeline`,
  `#journal_path`, and `#checkpoint`. **S, high.**
- The monotonic clock is defined eleven times (5 named constants, 6 inline lambdas), and
  `frontend/neovim/compose.rb:218,229` bypasses injection entirely. One `Lain::Clock::MONOTONIC`
  / `::WALL` leaf file. **S, high.**

### 5.6 `telemetry.rb` — cohesive namespace, wrong file shape

1,660 lines, 34 `Data.define` records, 21 guards, **zero cross-block references**
(grep-verified) — not a god object, so don't restructure the classes. But it reopens
`module Telemetry` 18 times purely to reset the `Metrics/ModuleLength` budget, each reopening
with a preamble justifying itself, and it's the only 400+-line concept in `lib/` that never
became a directory index. Mechanical split: `telemetry.rb` keeps `Journalable`/`Guard` and
becomes the index; one record+guard per `lib/lain/telemetry/*.rb`. Also extract the duplicated
fixed-point `#decimal` helper (`telemetry.rb:936-940` vs `:1321`) as `Telemetry.fixed_point`.
**M (mechanical), high.**

### 5.7 Remaining extraction verdicts from the clone scan

| Group | Verdict / home | Effort |
|---|---|---|
| `#problem_with` ×3 (`read_file.rb:60`, `code_outline.rb:85`, `file_symbols.rb:81`) + the `resolved_path` pattern ×3 | Shared `Tools::PathCheck` collaborator or mixin; `file_symbols.rb:78-80` already names the sharing in prose | S |
| `#validated` ×2 (`compaction/head.rb:140`, `boundary.rb:152`) | One `Compaction.validate_keep_last`; Boundary's "cannot drift" comment is aspirational — it can, and `Source#validated_keep_last` already builds a **throwaway `Head`** to reach the rule | S/M |
| `#text_of` ×3 (`auto_surface.rb:119`, `adjudicator.rb:286`, `command/meta.rb:200`) + 3 more adapted copies in bench | `Tool::Result#text` — all six sites operate on the same duck | S |
| Strategy freeze constructors (`elide.rb:68`, `identity.rb:25`) | `prepend Freezable` — **the abstraction already exists** (`freezable.rb`) and is used elsewhere; cheapest fix in the batch | S |
| `#summarize` ×2 (`cli/improve.rb:94`, `consolidation.rb:228`) | `Journal.block_trace(block)` — one concept, two docstrings explaining the same rationale | S |
| `#attributable?`/`#mine?` (`cli/epic.rb:327`, `epic/progress.rb:109`) | `Epic.attributable?(record, slug)` — one domain rule, two names | S |
| `#tier` ×2 (`backend/summarizer.rb:41`, `span_summarizer.rb:88`) | `Backend::TierFactory` or mixin — both docstrings argue the two tiers "cannot come to mean different things" | S/M |
| `#blocks` ×2 (`memory_replay.rb:69`, `tool_call_index.rb:126`) | `Journal.content_blocks(record)` — neutral home, respecting `ToolCallIndex`'s explicit anti-coupling comment | S |
| `render_scenario` ×2 (`gherkin/approval.rb:172`, `test_generation.rb:85`) | `Gherkin::Scenario#to_gherkin` | S |
| Pipeline duck check ×4 (`linear_rewrite.rb:128`, `context.rb:194`, `scheduler.rb:189`, `prepared.rb:161`) | One `Context.resolve_pipeline(pipeline, workspace)` | S/M |
| Wrap/`to_h` whole-value pair (`message_envelope.rb:20`, `middleware/env.rb:32`) | Borderline: both doc-comments cross-reference each other as one concept; a small `HashEnvelope` module, or leave documented | S |
| Digest-prefix `match?` ×3 (`pin.rb:95`, `rewind.rb:126`, `fork_point.rb:66`) | One `CLI::DigestPrefix.match?` — correctness-sensitive rule (a prior bug was exactly a partial-scheme match) restated three times | S |

### 5.8 Smaller smells

- **RpcThread's four callback lambdas** (`rpc_thread.rb:210`): `on_death:`/`on_resend:`/
  `on_compose_write:`/`on_compose_abandon:` jointly answer "what did the editor do" — one
  `Listener` object with a Null, not four hand-defaulted lambdas. **S, medium.**
- **Middle men**: `provider/http/provider.rb:75-120` (six instance methods forwarding to
  `self.class`; `configured?` re-implements rather than forwards — live duplication risk);
  `chronicle.rb` hand-writes five forwards where `delegate ... to: :scribe` says it in one line.
  Cosmetic. **S.**
- **Thor `options` hash** read in 17 files; `options[:jounal]` returns `nil` and every reader
  treats it as "off" — a fail-open typo in the layer deciding whether the experiment record gets
  written. `options.fetch` at the boundary or a `CLI::Flags` value object. **M, medium.**
- `provider/http/message.rb:27`: same silent-typo shape on a bare options Hash; vendored, low
  priority. **S.**

---

## 6. Low-value tests to delete or shrink

Deletions (high confidence unless noted):

| Spec | Reason |
|---|---|
| `spec/lain/middleware/env_spec.rb:78-106` | Byte-for-byte duplicate of `middleware_spec.rb:38-44`'s monoid property test (whose `observe` already wraps through `Env`) — doubles property-test runtime for zero coverage |
| `spec/lain/event_spec.rb:123-126` | Shallow ivar-freeze check strictly subsumed by adjacent `be_deeply_frozen`/`be_ractor_shareable` |
| `spec/lain/rust/timeline_spec.rb:229-231` | Asserts `Method` object non-identity — unobservable by any caller; content-pinning examples adjacent |
| `spec/lain/structural/patterns_spec.rb:17-21` | `not_to raise_error` over six queries that each have a stronger rendered-output example |
| `spec/lain/tools/subagent_sibling_template_probes_spec.rb:88-98` (P3), `:253-258` (P12) | Duplicate `subagent_spec.rb:224-235` and `:373-379`; keep P1–P2, P4–P11, P13–P14 (independently confirmed by two reviewers) |
| `spec/lain/agent/accounting_spec.rb:73-81` | Exact duplicate of `:27-36` under a different name |
| `spec/lain/agent/loop_machine_spec.rb:43-46` | Near-duplicate `Agent::STATES` snapshot; keep the `contain_exactly` version in `agent_spec.rb:426-434` |
| `spec/lain/arm/adaptive_router_spec.rb:122` | Asserts absent method names on an unrelated class by guessing |
| `spec/lain/oracle/{prune_scoring_spec.rb:43-46, router_spec.rb:66-69, summarize_spec.rb:33-35}` | Digest-stability = `Canonical` purity, already pinned in `canonical_spec.rb:38`; keep the adjacent tier-folding tests |
| `spec/lain/agent/request_override_spec.rb:77-93` | 500-iteration thread-stress duplicate of the deterministic race test above it; delete or shrink to ~20 |
| `spec/lain/agent/pipeline_source_spec.rb:23-25` | Strictly weaker than the identity assertion at `:15-17` |
| `spec/lain/improvement_spec.rb:32-34` | Tests `Data.define`'s unconditional freeze |
| `spec/lain/arm/ledger_state_spec.rb:25-27` | Tests `Data.define` value equality (medium confidence) |
| `spec/lain/compare_spec.rb:124-126`, `spec/lain/bench/variance_spec.rb:72-75`, `spec/lain/arm/driver_spec.rb:34-36` | stdout-discipline restatements; the AST-level `output_discipline_spec.rb` is the real enforcement |
| `spec/lain/compare_spec.rb:136-140` | 4 of 5 label checks duplicated; merge the fifth into the adjacent example |
| `spec/lain/bench/speculative_spec.rb:60-64` | "Deterministic" rerun of a pure function with no nondeterminism source |
| `spec/lain/bench/dry_replay_spec.rb:30-32` | Asserts on its own mock capture; subsumed by `#steps == 2` (low) |
| `spec/lain/cli/backend_spec.rb:174-184` | Re-pins the researcher tool set through a one-line delegation; the set is pinned at the right seam in `role_prelude_wiring_spec.rb:125-133`, and the very next example proves the delegation |
| `spec/lain/memory/item_spec.rb:66-68` | Tests Ruby's `private_constant` mechanism (low) |
| `spec/lain/frontend/prompt_composer_degradation_spec.rb:124-159` | Count-only duplicates of `prompt_composer_spec.rb:183-205`'s warn-once assertions |

Fix rather than delete:

- `spec/lain/bench/arm_sweep_spec.rb:104-109` — contains an **empty `each_with_index` loop that
  asserts nothing**; a reordering regression passes silently. Write the real per-section
  ordering assertion. Same file `:70-74`: anchor "titled sections" with `/^#{metric}\n/`.
- `spec/lain/arm/driver_spec.rb:47-53` — parses `Compare::Table`'s exact column format to test
  `Driver`; a rendering change breaks it with no `Driver` bug. Loosen to a regex near arm names.
- `instance_variable_get` reach-through in `spec/lain/cli/compaction_mount_spec.rb:33-38`
  (three chained ivars) and `spec/lain/cli/wiring/toolset_build_spec.rb:34-40` (two) — brittle
  against renames; give the classes a narrow introspection seam or assert via observable events.
- Five tool specs repeat ~150-200 lines of identical WorkerEnv path-resolution scaffolding
  (`read_file_spec.rb:96-126`, `list_files_spec.rb:72-119`, `ast_search_spec.rb:157-225`,
  `code_outline_spec.rb:104-153`, `file_symbols_spec.rb:127-177`) — `shared_examples`, keeping
  all coverage. (Pairs with the `PathCheck` extraction in §5.7.)
- `spec/lain/cli/backend_spec.rb` error-class examples ×4 (`expect(X).to be < Lain::Error`) —
  optional `shared_examples` consolidation, low priority.

Coverage gaps flagged while auditing (the inverse of this section, reported for honesty):

- `Lain::Core::Child` has **no spec at all** — `Unreachable`'s connect budget,
  died-vs-still-booting, the mutex-guarded idempotent `#reap`, `Errno::ESRCH` in `#term` are all
  unexercised (exhaustive grep). A `:core`-tagged `child_spec.rb` can reuse `client_spec.rb`'s
  `fake_daemon` scaffolding. **M.**
- `Repl::ApprovalSurfaces` — no spec constructs it with live `approvals:`/`notifier:`/
  `auto_surface:`; the three-fiber fan-out in `#watch` is untested. **M.**

---

## 7. Comments

The review was asked to find WHAT-only comments to delete. Across all ten areas: **essentially
none exist.** The house discipline (WHY-comments citing measured numbers, card IDs, and crash
reproductions) is applied consistently. The findings are the two inverses:

- **A wrong comment**: `structural/queries/ruby/symbols.scm:26-29` claims the query matches
  calls "with an explicit receiver"; it matches any `call` node — the project's own spec fixture
  (`compute(...)` receiverless) proves it. Reword to the real discriminator: any `call` node;
  paren-less bare identifiers are indistinguishable from local reads at this grammar level. **S.**
- **A comment doing a refactor's job**: `arm/orchestrator_worker.rb:106` packs two calls into one
  argument list whose correctness depends on left-to-right evaluation, then spends 14 lines
  (`:89-102`) explaining it. Two named locals (`result`, `report`) make the order visible;
  the design-rationale comment stays. **S.** Similarly `bench/sweep.rb:188-191` (`recall_tokens`
  drills `.call(...).last["content"].last` — name the intermediates). **S.**
- Comments that acknowledge duplication instead of extracting it (`adaptive_router.rb:110`,
  `boundary.rb:152`, `rewind.rb:123-125`, `up.rb:258`) — resolved by the §5 extractions.

---

## 8. Documentation drift (one cleanup commit)

- `ARCHITECTURE.md` isolation "Wiring status": claims nothing in `cli/` constructs
  `Worktree`/`DbIndex`/`Compose` and no flag selects one — stale since chunk 14
  (`cli/isolation_backend.rb:126,164,173`, `--isolation`).
- `compaction.rb:16-22`: "{Need} … this module's only member" — it has twelve.
- `ARCHITECTURE.md:956`: "~20 guarded event kinds" — 33 records, 21 guards.
- `cli/wiring/toolset_build.rb` comment claiming `run_skill` shares "the SAME construction" as
  the repl's renderer — false today (§3.4).
- `provider/http/configuration.rb:20`: "ruby-4.0.5 this project pins" (prose only; the
  executable version of this bug is §2.4).
- ROADMAP: no entry for the epic tier (§1.2) — the highest-priority doc fix.

**Landed** (chunk A, T39), with two counts corrected against the code on the way in:
`compaction.rb` has **eleven** members, not twelve (`Lain::Compaction.constants` — the list is
`Boundary Cold Derivation DerivationAudit Head Need Prepared Scheduler Source Strategy
SummarySnapshot`, matching the eleven `require_relative`s in `compaction.rb`); and `telemetry.rb`
defines **34** journalable kinds, not 33 (the 33rd count misses `RequestResent`, which subclasses
the `RequestSent` *event* at `telemetry.rb:275` and journals its own `request_resent` type). The
21-guard figure is right. `ARCHITECTURE.md:956` also claimed every journal record is one of them,
which is false: `SessionRecord` writes `session`/`turn`/`rewound` (`session_record.rb:31-33`) and
`Journal` writes `journal_error` (`journal.rb:261`). The three ROADMAP entries are items 22–24,
and the parity work is grounded in `planning/rust-parity-gap.md`. The
`cli/wiring/toolset_build.rb` clause is a code fix (T15), not a doc one.

---

## 9. Idiomatic Ruby, idiomatic Rust, and the gem question

**Ruby.** The verdict across every reviewer: strongly idiomatic by the repo's own standard —
Enumerable/Enumerator used where they should be, Null Objects instead of nil guards, injected
collaborators, loud failure. The deviations are exactly the findings above (§4's pass-throughs
and clumps, §5's copies) — style-consistent code whose *boundaries* drifted, not unidiomatic
code.

**Gem replacement: nothing qualified.** Checked and rejected with reasons: `concurrent-ruby`
(thread-based; the codebase is fiber-based on `async` and already ruled it out at
`channel/drop_oldest.rb:36-39`), a stats gem for `Compare::Distribution` (would coerce
`BigDecimal`/`Integer` to Float), the `gherkin` gem (grammar non-fit), TOML/XDG gems for
`Config`/`Paths` (the narrow contracts — "refuse unknown keys in the one table we own" — aren't
what the gems do), generic globbing/diffing for the file tools (per-tool caps and structural
matching are the point), and the vendored `ruby_llm` fork (documented rationale in VENDOR.md:
upstream flattens multi-block content the Timeline cannot lose). The one *adoption* candidate
found: `ActiveSupport`'s `delegate` for `Chronicle`'s hand-written forwards (§5.8).

**Rust.** See §10.

---

## 10. Rust: idioms, binding set, and Ruby→Rust candidates

Every `.rs` file was read in full; findings marked *(measured)* were reproduced through the
built `lib/lain/lain.so`. `crates/lain-core` is correctly scoped (its whole RPC surface —
`ping`, `exec`, pipe draining, `killpg`, vsock — is async/IO-shaped; nothing wants to move
in-process), and Cargo/deny hygiene is otherwise clean: no unused deps, every pin justified,
`default-features = false` correctly applied to `bm25` and `toml`.

### 10.1 Idiomatic-Rust findings, ranked

1. **`ext/lain` reads `NO_COLOR` from inside the `.so` — through a feature the ban list cannot
   see.** `tracing-subscriber`'s default `ansi` feature compiles `nu-ansi-term` into the
   extension, and `Layer::default()` consults `NO_COLOR` to decide colour — the exact rule
   `ext/lain/CLAUDE.md` states and `deny.toml` enforces against `console`/`termcolor` by crate
   name; a feature of an allowed crate walks past a name-based ban. `lain-core` defends with
   `.with_ansi(false)` (`main.rs:112`); `ext/lain` does not — only the JSON formatter's
   incidental behavior keeps escapes out of the Journal. Fix: `default-features = false,
   features = ["fmt", "json", "env-filter", "std", "smallvec"]` in both crates plus
   `.with_ansi(false)` at `lib.rs:368`, and a comment on the dependency line naming `ansi` as
   the excluded thing (deny.toml can't express feature bans). **S, high.**
2. **Unbounded recursion over caller-supplied structures** in `ruby_to_canon`/`canon_to_ruby`/
   `write_canon`/`Canon`'s recursive `Drop` (`lib.rs:464-500,646-670`, `canonical.rs:114-144`)
   and the astgrep CST walks (`astgrep.rs:103-105,184-190`) — while `prompt.rs:60-86` documents
   this exact failure (overflow in Rust frames → `SystemStackError` longjmps past destructors →
   leak) and bounds every one of its own walks with `MAX_DEPTH = 64`. *(Measured: 100
   overflowed `canonical_dump` calls leaked 10.6 MB RSS, unreclaimed by full GC.)* The canonical
   side is latent (nothing calls it — §10.2) but is a **blocker for wiring it**; the astgrep
   walks are in production. Fix: one bound at `ruby_to_canon` (the single entry) + one on the
   CST walks, copying `prompt.rs`'s pattern. **M, high.**
3. **`AstGrep.dump` quadratic output** — promoted to shipped-defect §2.7. **S.**
4. **Byte offsets can index a string the caller never had.** `astgrep.rs:366-371,423` and
   `treesitter.rs:272-277` take `String` via magnus's blanket conversion, which transcodes
   anything that isn't UTF-8/US-ASCII — so the returned byte offsets index the transcoded copy
   while `Structural::Matcher#line_for` counts newlines in the *caller's* source. Silently wrong
   `line`/`byte_range` for ISO-8859-1/UTF-16 sources. `fuzzy.rs:508-547` and
   `prompt.rs:1583-1624` already solved this with an encoding-refusing `read_text`, and
   `fuzzy.rs:504-507` already files the "hoist shared `read_text` into `crate::ffi`" follow-up —
   now with a third caller and a correctness reason. Also removes a source-sized copy per call.
   **S–M, high (med on real-world reachability).**
5. **`dag.rs` materializes where an iterator composes** — the repo's Enumerable doctrine applied
   to Ruby but not its Rust port. `ancestor_digests` builds two Vecs to discard both; `meet`
   materializes four then `.find`s over one; `ancestor_of` materializes the whole chain before
   `.any()`; `Timeline::length`/`include_p`/`to_s` (`lib.rs:1306-1320,1386`) build full Vecs of
   `Arc`s to call `.len()`/`.any()`/render. One private `fn walk(...) -> impl Iterator` fixes
   all of it; the semilattice law tests hold unchanged, which is what makes it safe. **M, high.**
6. **Ruby is called while the `Store` mutex is held at ten sites** (`lib.rs:1008-1366` — the
   `missing_object`/`lookup_error` closures run `const_get` and allocate under the guard), in a
   crate whose own `rewind` comment (`lib.rs:1270-1275`) reasons carefully about the
   non-reentrant `Mutex`. A finalizer touching the same `Store` under GC self-deadlocks.
   `Store::fetch`/`head`/`rewind` already show the correct compute-drop-then-talk-to-Ruby shape;
   apply it uniformly. **M, med-high (hazard real, reachability remote today).**
7. **`store_ref` launders a lifetime** (`lib.rs:619-621`): caller-chosen `'a` tied to nothing —
   sound only because `Timeline::mark` roots the store, which the comment doesn't say. Tie the
   borrow to `&'a Timeline` so the compiler enforces it. **S, med.**
8. **`Bm25#search` returns the one unfrozen outer Array** in the API *(measured)*; every other
   binding freezes it. `out.freeze()`. The `Timeline#ancestors`/`to_a` arrays are also unfrozen
   — arguably right for sortable collections, but state the choice. **S, high.**
9. **`as` casts:** `bm25.rs:115` `position as u32` silently wraps on a >4B-token corpus and
   corrupts the *pinned* insertion-order tie-break — `u32::try_from` + `BuildError`. Consider
   `deny(clippy::cast_possible_truncation)` with documented allows for the two safe casts. **S.**
10. **`tracing`/`tracing-subscriber` serve exactly one demo function** (`hello`,
    `lib.rs:383-387`) yet pull five transitive deps into the `.so`. The seam is deliberate and
    spec'd — keep it — but the feature trim (item 1) is the cheap half; decide whether production
    Rust will ever emit spans. **S.**
11. Batched smaller items: derive `Ord` on `Digest` (then `event.rs:316`'s manual sort is
    `.sort()`); `Canon::object_from_sorted` for the three compile-time-literal `IndexMap` +
    duplicate-check + `sort_keys()` sites in `event.rs` (per-event = per-turn cost);
    `Role::names()` allocates per error (`const` it); `StyleError`/`ConfigError` hand-roll
    `Display` with no stated reason in a crate that uses `thiserror` five modules over;
    `exec.rs:176-177` `unwrap_or_default()` turns a panicked drain task into silent empty output
    — one `tracing::error!` closes the crate's only silent corner. **All S.**

Housekeeping: `digest.rs:22`, `digest.rs:108`, and `lib.rs:65` use "load-bearing" in comments.

### 10.2 Is the binding set right?

Judged against the five rules (pure+sync / asymptotically better / hot per-turn / batched /
survives shared tests): **fuzzy** passes all five (rule 4 exemplar — two crossings); **bm25**,
**astgrep**, **treesitter**, **prompt** pass (per-tool-call or per-keystroke rather than
per-turn, honestly noted). **dag/canonical/event fail rule 3 by the widest possible margin**:
`grep` for `Ext::Timeline|Ext::Store|Ext::Turn|canonical_dump|canonical_digest` in `lib/`
returns nothing — ~2,200 lines of parity-tested shadow implementation that run zero times in
production. This is *not* the deliberately-kept dual Timeline (that doctrine is about keeping
both implementations); this is **neither side of the port being wired differently** — Ruby does
all the work. One reverse flag: `ext/lain/CLAUDE.md` opens "this crate is pure and synchronous,"
but `init_tracing`/`SharedWriter` (`lib.rs:300-379`) do a `dup(2)`, a process-global subscriber
install, and blocking writes under a `Mutex` — small and deliberate, but the purity claim is
overstated by one sentence.

### 10.3 Should Ruby code move into Rust? The skeptical answer: nothing new qualifies

The two things the five rules select are already written in Rust, parity-spec'd, and unwired;
the biggest measurable per-turn wins are Ruby-side memoizations needing no FFI (§3.1, §3.6).

- **Wire `Canonical.dump` to Rust? No — as a straight swap it plausibly loses.** Same recursive
  descent and per-node key sort as Ruby (a constant factor, and "Rust is faster" is not a
  reason), and `ruby_to_canon` does one Ruby `funcall` **per Integer and per Float**
  (`lib.rs:477,512-513`) — the per-element crossing rule 4 forbids. The real win is the *count*
  of dumps (§3.6). If a Rust step is still wanted, the narrower shape that satisfies rule 4 is
  `canonical_bytesize` (five call sites want a byte count, not a String) — file as
  "measure first". Blocker either way: the recursion bound (§10.1 item 2), since wiring makes
  the leak reachable from model-supplied tool-result JSON.
- **Wire `Ext::Timeline`/`Store` into production? Qualifies on rules 1/3/4/5, weakly on 2** —
  `Cargo.toml`'s own note says the HAMT's structural sharing is "LATENT today"; what Rust buys
  now is a constant factor (one locked read + one batched Array vs n `Monitor#synchronize` + two
  Arrays per walk). It's *finishing a landed port*, not a new migration, with three concrete
  blockers: `Ext::Timeline` implements neither `causal_meets` nor `dominator_meet` nor
  `CausalAncestry`/`Dominators` (not drop-in); the two Stores don't validate the same thing
  (`payload_digest` validation deliberately absent on the Rust side, `lib.rs:176-180`); and the
  lock-across-Ruby fix (§10.1 item 6) should land first. The honest trigger is the roadmap item
  `Cargo.toml` already names: speculative branching with per-branch snapshots, which is what
  turns the HAMT from latent into rule 2's actual argument.
  **Followed up in `planning/rust-parity-gap.md`** (ROADMAP item 23's grounding), which walks the
  two surfaces method by method and finds the gap wider than three blockers: `Ext::Store#put` is
  monomorphic where production stores six other duck-typed kinds, `Ext::Timeline#commit` takes no
  `causal_parents:` (five `lib/` sites pass one), the payload is inline rather than a second
  stored object, and `Ext::Timeline#ancestors` has no block form — so `Ledger`'s
  `timeline.ancestors { … }` (`ledger.rb:117`) would price every timeline at zero in silence.
- **`Request#prefix_digests`, `Compaction::Head`'s deep copy: Ruby caching problems, not ports**
  (§3.6; and `head.rb:81`'s `copy: true` may be buying nothing since `Canonical.normalize`
  already freezes every node — worth one measurement).
- **`Memory::Manifest#search`**: passes every rule except hot (per `memory_read` call) — and the
  right question is whether `Manifest` should exist at all next to `Bm25` (two retrieval scorers
  sharing one law group, one already Rust), not whether to port it.
- **`Tools::Grep`**: fails rule 1 (filesystem I/O) — belongs in `lain-core` if anywhere
  (`ignore` + `grep-regex`), low priority since it's already bounded. Its `files_under`
  materializing the full recursive glob is a Ruby cleanup, not a port.
- **Watch-list:** speculative branching (the HAMT trigger); `causal_meets`/`dominator_meet` via
  `petgraph` only if the Ext Timeline lands *and* a bench shows them hot; re-measure
  `Canonical.dump` after the Ruby memoizations; `rb_ext_ractor_safe` as the precondition for any
  parallel-arm bench (no binding is callable off the main Ractor today, recorded in
  `ext/lain/CLAUDE.md:160-166`).

---

## Appendix: what ran

| Reviewer | Model | Scope |
|---|---|---|
| Core spine | Sonnet (+sub-agent) | event/timeline/canonical/store/context/algebra/structural/request/middleware/effect/channel/sink + specs |
| Agent/orchestration | Sonnet (4 sub-reviews) | agent/supervisor/arm/epic/oracle/plan/gherkin/session/session_record + specs |
| CLI ×2 | Sonnet | all of cli/ + status_feed/notify/config/paths + specs |
| Provider/frontend | Sonnet | provider/ (incl. vendored http/), frontend/, journal + specs |
| Bench/telemetry | Sonnet | bench/grader/compare/improvement/telemetry/consolidation + specs |
| Compaction/memory | Sonnet | compaction/summarizer/context_window/memory + specs (zero substantive findings) |
| Tools/approval | Sonnet (+2 sub-agents) | tool/tools/approval/skill/prompt + specs |
| Isolation/Rust area | Sonnet | isolation/core/workspace/worker_env + all .rs + specs |
| Architecture | Opus | ROADMAP/planning/ARCHITECTURE + load-order manifest + core seams |
| Code smells/arity | Opus | Prism arity scan (134 defs ≥5 params) + anti-pattern catalog |
| Rust depth | Opus | idiomatic-Rust audit, binding-set judgment, Ruby→Rust candidates |
| Clone judgment | Sonnet | 14 Prism clone groups, individually verdicted |
| Adversarial verifier | Sonnet | 8 top claims re-derived from code; all CONFIRMED (2 with zero-caller caveats) |
| Peer session | — | subagent subsystem audit (folded into §6) |
