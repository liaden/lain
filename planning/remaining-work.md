# Remaining Work — Lain (post-M3b), task-level breakdown

> **Purpose.** A task-sized inventory of everything in `jiggly-greeting-avalanche.md` not yet built,
> for folding into `ROADMAP.md`. Each **unit** is scoped to roughly one subagent hand-off and carries
> an **acceptance** criterion (how you know it's done). Hard dependencies are noted; sequencing and
> prioritization are yours. Units are labelled `M<band>-<stream>.<n>` for easy reference.

## Status snapshot

`main` @ `aa9bc5d` — **560 examples, 0 failures**, RuboCop clean at default metrics, `cargo test`
6/6. Done: **M0, M1** (pre-session), **M1b, M2, M3a, M3b** (this session). **The vehicle (agent) is
complete; the bench (the deliverable) is not.** Until M3c lands you can run the agent but cannot
compare strategies — the project's entire point — so M3c is the highest-leverage remaining band.

**House rules every unit inherits** (from `CLAUDE.md`): no `next`/`break`/`redo`; never loosen a
`Metrics/*` limit (extract a collaborator); internal requires live in `lain.rb`/unit indexes, never
in leaf files (specs load via `require "lain"` in spec_helper — a new file, its index line, and its
spec land in the same commit); nothing in `lib/`
touches `$stdout`/`$stderr` outside `lib/lain/frontend/`; value objects deeply frozen
(`Ractor.shareable?` stays true); comments explain WHY; ActiveSupport/`Enumerable`/Null-Object/SOLID
welcome; commit leaf-first with terse messages, no trailers. Fan-out via git worktrees, `--ff-only`
merges, lead owns `lib/lain.rb`/gemspec/`Gemfile`/`.rubocop.yml`/`CLAUDE.md`/`spec_helper`/pre-commit.

---

## P — Provisional cleanup (close before trusting the transport; needs a Console key)

- **P.1 — Re-record the transport cassette.** Replace synthetic
  `spec/fixtures/vcr_cassettes/anthropic_raw_streaming_tool_use.yml` with one recorded via
  `LAIN_RECORD=1` against the real API (synthetic prompt only — never medical content).
  **Acceptance:** `:vcr` parse-proof passes against the *recorded* cassette; synthetic file deleted.
- **P.2 — Run the `:live` differential once.** `AnthropicRaw` vs SDK oracle, identical
  `Lain::Response`. **Acceptance:** `LAIN_LIVE=1 … rspec` green for the differential example
  (verification step 5 actually satisfied, not just written).
- **P.3 — Confirm the real reset-header name.** Read `anthropic-ratelimit-*-reset` off a live 429.
  **Acceptance:** `AnthropicRaw`'s `rate_limit_reset_header` set to the confirmed header; retry spec
  still journals exactly one `ProviderRetry`.

---

## R — Deferred findings from the whole-chunk review (2026-07-13, daf5baf..f3a6480)

Ten findings; seven fixed in the follow-up round (`28c6b80`..`f3a6480`). These three were
deliberately deferred, not dropped:

- **R.1 — Rolling-hash `prefix_digests` chain.** `Request#prefix_digests` recomputes a full
  `Canonical.digest` per marker with no reuse across overlapping prefixes, so per-turn journaling
  cost is O(turns²) per session. The real fix is redesigning the chain as a rolling hash
  (`entry = H(prev_entry, canonical(message))`) — that **changes recorded digest values**, so it
  needs a chain-version marker and `Bench::Rewrites` tolerance for both formats (it already
  tolerates `nil` for pre-chain journals). The cheap intra-call strip-once reuse was considered
  and deliberately skipped in favor of doing this properly. **Acceptance:** journaling cost per
  turn is O(1) amortized in message count; `Rewrites` reads old and new journals; divergence
  localization unchanged.
- **R.2 — Structural workspace provenance.** `Context::Recall` decides workspace-block provenance
  by string-prefix matching on `Workspace::OPENING_TAG`, so genuine user text starting with the
  literal tag is silently excluded from recall queries. Replace with a structural
  `"workspace" => true` block key, stripped before the wire exactly like `"cache"` (touches
  Workspace render, the encoder's strip, and `Request#prefix_digests`' marker-stripping).
  **Acceptance:** a user message that literally starts with `<workspace>` still feeds the recall
  query; the wire payload carries no `"workspace"` key.
- **R.3 — `RequestSent` double normalization.** `Middleware::JournalRequests` normalizes the
  payload and `Event::RequestSent.new` normalizes it again. Minor; fold into R.1's touching of
  that seam. **Acceptance:** one `Canonical.normalize` pass per journaled request.

## R — Deferred findings from the code-review/Ollama/test-infra plan (2026-07-14)

- **R.4 — `to_s`/`inspect` split across value objects (Ruling 9 sweep theme).** Five value
  objects alias `inspect` to a debug-shaped `to_s` (`#<Lain::Foo …>`), conflating the two exactly
  the way DegradedSet did before T5 split them: **`Request`** (`request.rb`), **`Turn`**
  (`turn.rb`), **`Toolset`** (`toolset.rb`), **`Provider`** (`provider.rb`, inherited by every
  backend), and **`Memory::Bm25`** (`bm25.rb`). The convention T5 set is `to_s` → the
  human-readable projection (DegradedSet's joined capability list), `inspect` → the class-tagged
  `#<…>` debug form. The sweep also covers **`Lain::Ext::Turn`** and **`Lain::Ext::Timeline`**
  (`ext/lain/src/lib.rs`), whose `to_s`/`inspect` are likewise debug-shaped aliases — nothing
  pins their rendering (verified 2026-07-15), so the split is safe there too. Deferred rather
  than fixed in place because (a) `Request` and `Turn` are the
  identity spine — a `to_s` that flows into an interpolated journal/error string is a byte-risk
  the sweep must not take unilaterally — and (b) applying the split to only the non-spine three
  would reintroduce the very inconsistency the theme exists to remove; one card should do all five
  uniformly with the interpolation audit. **Acceptance:** each of the five defines `to_s` as a
  human projection and `inspect` as the `#<…>` debug form (no `alias inspect to_s`); no journaled
  or digested byte changes (the spine two verified against a recorded journal/cassette).
- **R.5 — Ollama `:thinking` capability.** qwen3 emits `message.thinking` fragments under
  `think: true`; `Provider::Ollama` neither sends `think` nor declares `:thinking`, though T17's
  StreamAssembler already accumulates thinking fragments (forward-compatible). Wire the option
  through `Request#extra`, declare the capability, and map fragments to the thinking content
  block the Anthropic path produces. **Acceptance:** a `think: true` round trip yields a thinking
  block in `Response#content`; the capability gate sees `:thinking`; non-think runs unchanged.
- **R.6 — Ollama tool-result correlation is `tool_name`-only.** Native `/api/chat` has no
  `tool_call_id`; Lain's synthesized ids exist only on our side, and results encode to
  `role:"tool"` + `tool_name`. Two parallel calls to the SAME tool in one turn are therefore
  wire-ambiguous to the model (Lain's own loop stays unambiguous via synthesized ids). Documented
  in `Ollama::Encoding`'s WHY. Revisit if a bench task shows models misattributing results.
  **Acceptance:** either upstream grows ids (track ollama/ollama) or the encoder documents a
  measured mitigation (e.g. result ordering guarantee) pinned by a spec.
- **R.7 — `bench record` lacks provider/sampler selection.** `Lain::Bench::CLI` constructs its
  own `Provider::Anthropic` and takes no `--provider`/`--temperature`/`--seed`; exe/lain's
  `LainCLI::Backend` resolution (T18) is the reusable piece. Wiring it in makes an Ollama temp-0
  arm recordable. **Acceptance:** `bench record --provider ollama --temperature 0 --seed N`
  records a session whose header carries the extra and replays dry.

## R — Deferred findings from the rust-findings-resolution plan (2026-07-15)

- **R.8 — (Optional) shape-validate digest addresses at the constructors.** DOWNGRADED
  2026-07-15: the safety half shipped as put-time referential integrity (`Store#put` refuses a
  dangling parent in both implementations, byte-identical message — see `store.rb` /
  `lib.rs`), which actually prevents corrupt chains; constructor shape-checking cannot (a
  well-formed digest that was never put sails through any shape check). What remains is
  address *hygiene* only: `Turn.new` still accepts a malformed parent string (`"blake3:abc"`),
  which now fails at `put` rather than at construction — one step later than ideal, loud
  either way. **Scope if taken:** joint Ruby+Rust shape check (`blake3:` + 64 lowercase hex)
  at `Turn#initialize` and Ext `read_optional_digest`, byte-identical error. **Caveat:** breaks
  the pinned `parent: "blake3:abc"` fixtures in `rust/turn_spec.rb` (they must move to real
  digests in the same card). Low value now; take it only bundled with other constructor work.

---

## M3c — Algebra, seams, and the grader (THE BENCH)

### Stream 3c-1 · `Lain::Algebra` (property-tested laws)
- **3c-1.1 — Extract the law harness into `Lain::Algebra`.** Give the monoid/semilattice laws a
  named home; decide (open decision #2) whether tools *include* it or it stays test-only.
  *Builds on:* `spec/support/shared_examples/monoid.rb`, `lib/lain/usage.rb`, `lib/lain/middleware.rb`.
  **Acceptance:** `Usage`, `Middleware`, and `Timeline`'s meet-semilattice all consume the shared
  law group; no duplicated property-test machinery remains.

### Stream 3c-2 · `Context` combinators under `>>`
- **3c-2.1 — Combinator base + `>>` composition.** An endomorphism on the message list with
  pass-through identity; `a >> b` composes associatively. *Builds on:* `lib/lain/context.rb`
  (`#render` already pure), 3c-1 law group. **Acceptance:** associativity + identity property-tested
  via the shared monoid group; `#render` stays pure (same args → identical bytes).
- **3c-2.2 — `Prune` combinator** (keep last N / by predicate). **Acceptance:** unit spec over a
  Timeline; byte-diffable output; declares its `requires`.
- **3c-2.3 — `Compact` combinator** (summarize at a token threshold). **Acceptance:** unit spec;
  purity held; degrades loudly if the provider lacks a needed capability (ties to 3c-4).
- **3c-2.4 — `CacheBreakpoints` combinator.** Places markers ~every 15 blocks (20-block lookback
  trap) and respects the 4096-token minimum-cacheable-prefix. **Acceptance:** a spec asserting a
  timestamp/volatile tail does **not** invalidate the cached prefix; breakpoints land at the right
  indices. *(This unit is the seam Recall (5-3) orders itself after.)*
- **3c-2.5 — Reminder-injection combinator** (Workspace tail). **Acceptance:** injected reminder
  rides the uncached suffix, never rewrites the cached prefix; purity held.

### Stream 3c-3 · The other two middleware phases
- **3c-3.1 — `turn` phase.** Wrap each agent turn (budget, iteration ceiling, interrupt hook,
  speculative-fork point). *Builds on:* `lib/lain/middleware.rb`, `lib/lain/agent.rb` (already wires
  `model_`/`tool_middleware`). **Acceptance:** `turn_middleware:` Stack threads each turn; monoid
  laws green; an existing gate-7 (bounded loop) spec still passes through it.
- ✅ **3c-3.2 — `repl` phase.** *(Found already built 2026-07-13: `exe/lain` wires `repl_middleware` through `dispatch`.)* Wrap each REPL command. **Acceptance:** `repl_middleware:` Stack green
  under the monoid group; `exe/lain` command path routes through it.

### Stream 3c-4 · Capability machine-checking
- **3c-4.1 — `:strict`/`:degrade` policy resolver.** A combinator's `requires` vs a provider's
  `capabilities`; `:strict` raises, `:degrade` no-ops loudly + journals the degradation. *Builds on:*
  `lib/lain/provider.rb` (`CAPABILITIES`/`require!` exist), `lib/lain/journal.rb`. **Acceptance:** a
  combinator requiring `:thinking` against a provider lacking it raises under `:strict`, journals one
  degradation record under `:degrade`.
- **3c-4.2 — `Compare` capability guard.** Refuse to compare two runs whose degraded sets differ.
  **Acceptance:** a spec where mismatched degraded sets makes `Compare` raise rather than report.

### Stream 3c-5 · The bench
- **3c-5.1 — `Bench::DryReplay`.** Re-render a recorded Timeline under a different `Context`/`encode`;
  byte-diff. *Builds on:* `lib/lain/handler/recorded.rb` (done), Journal, pure `#render`.
  **Acceptance:** replaying a recorded session under an identity Context reproduces byte-identical
  Requests; under a different Context, a deterministic diff.
- **3c-5.2 — `Bench::LiveReplay` (sequential first).** Re-run against the API. **Acceptance:** runs a
  recorded task live and records fresh Usage/Journal; `n:` sweeps deferred to the concurrency choice
  (5-0).
- **3c-5.3 — `Grader::Fixture`.** Deterministic tasks, hard assertions. **Acceptance:** a fixture task
  scores pass/fail deterministically over a `DryReplay` output.
- **3c-5.4 — `Grader::Rubric`.** LLM judge in a separate context window against explicit criteria;
  `#why` mandatory. **Acceptance:** returns a score + explanation; runs `:vcr`/`:live`-tagged, never
  hits the network untagged.
- **3c-5.5 — `Compare` over distributions.** Report distributions over n runs (single-run A/B is
  noise); fold in `Ledger`/`PriceBook` (done) for cost + the 3c-4.2 guard. **Acceptance:** produces a
  distributional report (tokens, cache-hit, cost, grader score) over n≥2 runs.
- **3c-5.6 — Speculative branching.** Fork at a node, run N trajectories, score, keep best. *Builds
  on:* O(1) `Timeline#fork`, a grader. **Acceptance:** a spec forks one node into N, scores via a
  `Grader::Fixture`, selects the max — beam-search shape demonstrated.

**Fan-out:** {3c-1, 3c-4} small/independent; {3c-2, 3c-3} independent of each other; 3c-5 stacks on
3c-2 + Recorded[done]. 3c-5.6 needs a grader (3c-5.3).

---

## M4 — Timeline in Rust, and Neovim (two independent workstreams)

### Stream 4-1 · Persistent Merkle DAG in `ext/lain`
- **4-1.1 — Port `Canonical` digest to Rust** (`blake3`/`indexmap` for stable ordering).
  **Acceptance:** Rust digest == Ruby `Canonical.digest` byte-for-byte over the existing test
  vectors.
- **4-1.2 — Port `Store` (content-addressed, structural sharing)** with `im`/`rpds`. **Acceptance:**
  the `Regular` store property tests pass against the Rust impl unchanged.
- **4-1.3 — Port `Turn`/`Timeline` behind the existing interface.** **Acceptance:** the `Regular` +
  `MeetSemilattice` shared example groups pass against **both** Ruby and Rust impls;
  `Ractor.shareable?(turn)` stays true for the magnus `TypedData` (the port's real acceptance test).
- **4-1.4 — Cache-break localization.** Walk two chains, return the first differing digest.
  **Acceptance:** given two divergent Timelines, returns the exact break node; O(1) on digests.
- **4-1.5 — Speculative-branch support in the Rust DAG.** **Acceptance:** N-way fork over the shared
  Store stays O(1); `child.meet(parent)` correct.

### Stream 4-2 · Neovim frontend
- **4-2.0 — VERIFY RPC direction first** (open decision #6): can `Neovim.attach_unix` *serve* inbound
  `rpcrequest`, or must nvim `jobstart` the Ruby handler? **Acceptance:** a spike answering the
  question in prose before any design; use remote *modules*, not deprecated remote plugins.
- **4-2.1 — Journal-subscribing Neovim frontend skeleton.** Spawn `nvim --listen`, attach.
  **Acceptance:** renders Journal events into a buffer; agent knows nothing of it.
- **4-2.2 — Read-only buffers** (`lain://timeline`, `lain://workspace`, `lain://diff`).
  **Acceptance:** each reflects live state.
- **4-2.3 — Editable `lain://request` + `:LainResend`.** The one interface idea that can't be done as
  well otherwise. **Acceptance:** editing the buffer and resending re-renders the diff of what
  changed.

---

## M5 — Orchestration, memory, code mode

### Stream 5-0 · Concurrency model (gates 5-1, 5-4)
- ✅ **5-0.1 — Spike `Async` × `Mixlib::ShellOut`.** *(Done 2026-07-13: cooperates — idle-child measurement; see docs/concurrency.md; 5-0.3 re-verifies under stdout-flood.)* Does the fiber scheduler hook `io_select`, or does
  a `bash` tool stall the reactor (`unix.rb:282`/`:406`)? **Acceptance:** a spike proving either
  fibers work or shellouts must offload to a thread; decision recorded in `docs/concurrency.md`.
- **5-0.2 — Prototype effects-via-`Fiber` vs handler objects.** Multi-shot resumption vs stack-trace
  clarity. **Acceptance:** both prototyped behind the identical `Middleware` API; a recommendation.
- **5-0.3 — Adopt the chosen model** (likely fibers; `Store` lock reconsidered). **Acceptance:** the
  loop runs under the model with real structured cancellation on `max_iterations`/cost/interrupt.

### Stream 5-1 · `Tool::Subagent`
- **5-1.1 — Fresh-root spawn over shared Store** with `meta["spawned_from"]`. **Acceptance:** child
  Timeline never contains the parent's prompt chain; `child.meet(parent)` is empty; causal lineage
  reconstructable from `spawned_from`.
- **5-1.2 — Attenuated toolset** (`toolset.only(:read_file)`). **Acceptance:** child cannot invoke a
  tool it wasn't handed; possession-is-authorization holds.
- **5-1.3 — `context: :fresh | :inherit`** (`:inherit` == `parent.fork`). **Acceptance:** both modes;
  fork mode is O(1).
- **5-1.4 — Within-turn concurrency** (gather all results, commit one turn — gate 2). *Needs 5-0.*
  **Acceptance:** async subagents finishing out of order still land all `tool_result`s in one user
  turn.

### Stream 5-2 · `Tool::Todo`
- ✅ **5-2.1 — Todo tool riding the Workspace.** *(Done 2026-07-13: `todo_write` on the Session reminders channel.)* *Builds on:* `lib/lain/workspace.rb` (sent-not-stored).
  **Acceptance:** todos render into the Request tail, never append to the Timeline, don't resurrect
  on rewind.

### Stream 5-3 · Memory + recall
- ✅ **5-3.1 — Content-addressed memory index** (root hash bumps per write; Journal records live root
  per turn). *(Classes 2026-07-13; wiring 2026-07-15: `Session::Loader` replays per-turn roots and
  verifies the journaled chain — `planning/specs/memory-read-path.md`.)* **Acceptance:** dry replay
  recalls against the exact recorded snapshot — recall is pure.
- ✅ **5-3.2 — `Manifest` index** (one-line descriptions in context, `memory_read(id)` for body).
  *(Classes 2026-07-13; wiring 2026-07-15: manifest rides `Session#reminders`, `memory_read` in the
  chat toolset — `planning/specs/memory-read-path.md`.)* **Acceptance:** deterministic, cache-stable,
  no embeddings; `Hit#why` populated.
- ✅ **5-3.3 — `Bm25` index** *(Done 2026-07-13: `bm25` crate in-process via `ext/lain`, not tantivy; `Memory::Bm25` + shared "a memory search index" law group.)* (`tantivy`, via the exec boundary or in-process to start). **Acceptance:**
  exact drug/gene-name queries return correct hits with `#why`.
- ✅ **5-3.4 — `Context::Recall` combinator** *(Done 2026-07-13.)* ordered *after* `CacheBreakpoints` (3c-2.4). **Acceptance:**
  auto-injected recall lands at the message tail, never invalidates the cached prefix.
- ✅ **5-3.5 — 🔒 secret write-refusal.** *(Done 2026-07-13: deterministic patterns + injectable oracle seam; PHI heuristics deferred to the oracle (OR-1).)* `Lain.middleware.tool` refuses `memory_write` of PHI/keys,
  journaled. **Acceptance:** a write attempt is refused and journaled, not silently stored.

### Stream 5-4 · `edit_file` + code mode
- ✅ **5-4.1 — `edit_file` with `str_replace` + read-before-write contract.** *(Done 2026-07-13: first real consumer of Tool::Contracts, over the T11 Session read-set.)* *Builds on:* the contract
  mechanism in `lib/lain/tool.rb`. **Acceptance:** an edit without a prior same-session read of the
  file fails the precondition (Eiffel-strict raise → error result).
- **5-4.2 — Server-side context-editing arm** (comparison against client-side `Prune`, 3c-2.2).
  **Acceptance:** both arms measurable by `Compare`; capability-guarded (3c-4).
- **5-4.3 — Code mode (`eval_ruby`, persistent binding, tools as methods).** *Needs the exec boundary
  (6-1).* **Acceptance:** intermediate results never enter context; a multi-step task runs in one
  eval turn. *(Plan calls this the highest-leverage item for medical synthesis.)*

---

## M6 — Rust round two, and the retrieval sweep

### Stream 6-1 · Out-of-process exec boundary (`crates/lain-core`)
- **6-1.1 — `lain-core` tokio crate + msgpack-RPC over a Unix socket** (same transport as Neovim).
  **Acceptance:** Ruby drives a round trip to the crate over the socket; `crates/` exists.
- **6-1.2 — Sandboxed exec boundary.** **Acceptance:** `bash`/exec runs out-of-process with the
  isolation `Mixlib::ShellOut` cannot provide (the honest security boundary).
- **6-1.3 — One Rust-implemented `Tool` + parallel CPU-bound tools.** **Acceptance:** a Rust tool
  round-trips through the same `Tool` interface; parallel tools measurably concurrent.

### Stream 6-2 · Retrieval sweep (the highest-value measurement)
- **6-2.1 — `Vector` index** (HNSW/`usearch`; open decision #8: embedding provider). **Acceptance:**
  `#search` returns k hits with `#why`; nondeterminism documented.
- **6-2.2 — `Hybrid` index** (rank fusion). **Acceptance:** beats `Bm25` and `Vector` alone on the
  bench's recall@k for a fixture corpus.
- **6-2.3 — `Graph` index** (`[[wikilink]]` seeds + N-hop, `petgraph`). **Acceptance:** cheap,
  explainable hits with `#why`.
- **6-2.4 — Sweep all five strategies through the bench.** recall@k, tokens-on-recall, cache-hit,
  grader score — as distributions. *Needs bench (M3c) + memory (5-3).* **Acceptance:** a `Compare`
  report ranking `Manifest`/`Bm25`/`Vector`/`Hybrid`/`Graph` distributionally — the project's most
  direct transfer artifact.

---

## Consolidated open decisions

1. **Retire `Provider::Anthropic` (SDK oracle) when?** Keep until the forked path holds; retiring
   loses the dry-diff. *(M3c/transport)*
2. **`Algebra`: included module vs test-only harness.** *(3c-1.1)*
3. **Client-side `Prune`/`Compact` vs server-side context editing** — both as comparison arms; the
   combinator interface must not assume client-side. *(3c-2, 5-4.2)*
4. **Concurrency model** — fibers vs threads; spike `Mixlib::ShellOut` × `IO.select` first. *(5-0.1)*
5. **Effects via `Fiber` vs handler objects.** *(5-0.2)*
6. **Neovim RPC direction** — verify serve-inbound vs jobstart before designing. *(4-2.0)*
7. **Pull (`memory_search`) vs push (`Context::Recall`)** — empirical, ask the bench. *(5-3)*
8. **Embedding provider for `Vector`** — local model likely (keeps PHI off the wire). *(6-2.1)*
9. **`gemini`/`bedrock` providers?** Only if a medical A/B needs them (no oracle for either).

---

## Dependency / fan-out map (hard edges only)

```
P.1–P.3 provisional ── independent, cheap, anytime (needs key)
3c-1 algebra ─┐
3c-4 cap-policy┤ small, independent
3c-2 combinators ─────► 3c-5 bench (DryReplay needs Recorded[done]+pure render)
3c-3 middleware phases ── independent
                         3c-5.6 spec-branch needs a grader (3c-5.3)
4-1 Rust Timeline ── independent (Ruby ref + property tests are the gate)
4-2 Neovim ── independent (needs Journal[done]; 4-2.0 verify RPC FIRST)
5-0 concurrency ──► 5-1 subagents, 5-4.3 code mode
5-2 todo ── independent (Workspace[done])
5-3 memory ──► needs 3c-2.4 (Recall after CacheBreakpoints); feeds 6-2
6-1 exec boundary ──► 5-4.3 code mode, 6-2 heavy indexes
6-2 retrieval sweep ── needs bench[M3c] + memory[5-3] + exec[6-1]
```

**Natural parallel front after P.*:** 3c-{1,2,3,4} fan out; 4-1 and 4-2 alongside; 5-2 is a quick
independent win. **Critical path to the thesis:** bench (3c-5) → memory (5-3) → retrieval sweep
(6-2). Sequence the rest around keeping that path moving.
