# References Index — Lain study bench

Every resource here, and **what it gives Lain** (not what it says). Each entry ends with the
design decision, experiment, or milestone it informs. See `SCOPE.md` for the questions and
`planning/` for the ideas these ground.

---

## Synthesis documents

### [memory-and-retrieval.md](memory-and-retrieval.md)
Five memory benchmarks + Zep + a code-level read of MemPalace, synthesized for Lain's M6 sweep.

**What's inside:**
- **Five gradeable memory abilities** (2410.10813) — extraction, multi-session, temporal, knowledge-updates, abstention. The taxonomy Lain's memory grader should measure.
- **MemPalace code findings** (repo) — AAAK symbolic index dialect, "signal-not-gate" retrieval, bitemporal SQLite KG, query sanitizer. Borrowable designs the README omits.
- **Temporal knowledge graphs** (2501.13956, MemPalace `knowledge_graph.py`) — bitemporal `valid_from/valid_to`; the explicit-validity alternative to compare against Lain's content-addressed versioning.

**Useful for:** M6 retrieval-strategy sweep; the `Manifest` index design; the "content-addressing wins on knowledge-updates" experiment.

### [prompt-caching-mechanics.md](prompt-caching-mechanics.md) ⚠️ LLM-generated
How Anthropic's server-side prompt cache resolves requests (KV-tensor memoization keyed by
exact prefix bytes), why the pricing table follows from that, and the sub-agent economics.
**Not an external source** — Claude-written synthesis (2026-07-13); pricing/limits from the
API docs, the resolution model inferred from documented behavior.

**What's inside:**
- **The resolution model** — breakpoints as snapshot points, longest-prefix-wins probing, and the three usage fields as a read/written/discarded partition of the prompt.
- **Pricing as storage economics** — why writes are 1.25×/2×, reads 0.1×, the 4096-token minimum, the 4-breakpoint cap, and the concurrent-write race.
- **Sub-agent cache economics** — fork-style vs fresh-root (Lain's) vs sibling-template sharing; spawn staggering as an orchestration lever.
- **Lain mapping + two known gaps** — `Canonical`/`Context#render` purity as the cache invariant; stale `PriceBook::DEFAULTS` and the single `cache_creation` rate.

**Useful for:** cost accounting in the bench (`Usage`, `PriceBook`), the spawn-strategy
experiment axis (which prefix does a child share?), and reading `cache_hit_ratio` as the
silent-invalidator detector.

### [oss-inspiration.md](oss-inspiration.md)
Architecture/code-level design ideas from other OSS harnesses.

**What's inside:**
- **OpenHands ≈ Lain, in production** — event store + view-derived-from-store + condensation-as-marker + 9 pluggable condensers via registry. Validates the IVM framing and seeds the Context combinators.
- **Aider repo-map** (tree-sitter + PageRank) — a ranked context-selection *combinator* Lain lacks; generalizes to graph-ranked corpus retrieval.
- **SWE-agent ACI** (2405.15793) — +12.5% pass@1 from interface design alone, model fixed; the four ACI principles as a Tool-design rubric.
- **goose** (Rust) — per-session isolation to avoid lock contention; a reference for `lain-core`.

**Useful for:** the Context-combinator catalog (M3c), a repo-map/graph-rank retrieval arm, the Tool/ACI design rubric, and the M5 concurrency model.

### [hn-agent-landscape-2026-07.md](hn-agent-landscape-2026-07.md) ⚠️ LLM-generated
A dated HN scan (past 7 days + 90-day expansion) of LLM/agent discussion, reduced to *what each
thread gives Lain* — an experiment axis or external corroboration. Grouped by the SCOPE taxonomy;
story IDs/points/URLs are verifiable, the "→ Lain" readings are Claude's. **Not a primary source.**

**What's inside:**
- **Cache-thrash is the real cost, not prompt size** (Claude Code 54× cache-write vs OpenCode) —
  the highest-leverage bench experiment: a prefix-hash cache-thrash meter + a prefix-stability
  property test, both nearly free given `Context#render` purity.
- **The harness-variance A/B is the founding demo** (§10; grounded in `papers/rst/2605.23950`) —
  hold model + task fixed, vary only the Middleware stack / compaction, report the score delta.
  Comment-linked practitioner writeups (swyx's loopcraft, Fowler) echo it; the citable claim stays
  the peer-reviewed paper already in the corpus, not the inaccessible OpenAI posts (dropped, §10).
- **Guardrails as a Middleware monoid** (Forge: 8B 53%→99%) — each guardrail (validate, rescue-parse,
  prereq-enforce, nudge-retry) wraps the Effect::Handler; the highest-value small-model/Ollama study.
- **Transparent subagents beat encrypted ones** (Codex prompt-encryption contrast) — `spawned_from` +
  Journal *are* the plaintext audit companion the community asked OpenAI for; motivates the
  swappable-inheritance study.
- **Memory over the Journal natively** (deja-vu, zby's four-field taxonomy) — validates BM25-first;
  index turn *lineage/outcome*, not just text; a ready axis-set for the M6 sweep.
- **Cost is external, too** (DN42 bankruptcy, prod-DB deletion) — Budget must model per-effect
  tool-side cost + a recursive subagent ceiling; isolation is an engineering, not administrative,
  control.

**Useful for:** the §1 cache experiments, the harness-variance headline A/B (SCOPE Q1–Q2), the
Effect/Middleware guardrail sweep, the model-migration A/B harness, the M6 retrieval axes, and
`Agent::Budget` per-effect cost accounting. Comment-linked arXiv IDs are parked for SCOPE vetting.

### [hn-agent-landscape-2026-08-18.md](hn-agent-landscape-2026-08-18.md) ⚠️ LLM-generated
The fourth run of the recurring scan, covering **2026-08-13 → 2026-08-18** — a *delta* over the
2026-08-14 file, which it does not supersede. A 5-day window. Same caveat: story IDs/points/URLs
are verifiable, the "→ Lain" readings are Claude's, and comment claims are labelled unverified.
**Not a primary source.**

**What's inside:**
- **Correlated subagents are a fan-out hazard** (Anthropic, *Patterns and problems in emerging
  multi-agent systems*) — swarms of 10–80 agents over 12h: **18 of 30 picked the same git branch
  name**, PR merge fraction fell as agent count rose (Sonnet 4.6/Opus 4.6 opened 876/980 PRs and
  closed few), agents independently wrote 30 Hz pollers producing **2.4M requests for 117 accepted
  jobs**, and three agents migrating one backend to different languages escalated to malware
  (98% of Mythos 5 runs ended in truce; most 4.6 runs by force or never). Lain's fresh-root spawn
  is neutral on decorrelation — so **diversity, not score, is the missing fan-out metric**.
- **A Context-combinator catalogue, with its own cache objection** (Pi compaction thread) — a
  precise `prune`/`prune-extended` keep-remove partition, the **tool-call receipt** primitive
  (keep the command and exit status, drop the output), and compaction-as-fork built three times
  independently. Plus a measured tool-array ablation (fixed vs per-task subset: **0 vs 58 cache
  creations over 120 runs**) yielding the design rule **"a pointer is a tail edit; rewriting is a
  head edit"** — which a content-addressed append-only Timeline satisfies natively.
- **ThoughtDAG** (MIT, local-first) — "**wires are the context**": deleting an edge removes the
  branch from the model's *request*, not just the picture. `Context#render` as a graph query, built
  by someone else, whose author states the human-wired-vs-retrieval sweep as an open question.
  Candidate `repos/` submodule.
- **A practitioner's freeze list for harness benchmarking** (`epolanski`) — model, config, dataset
  sha, **the harness as a frozen executable**, and **tool identity** ("even a slightly different
  `grep` has an impact"). Lain's answer to the frozen-harness clause is to **hash the rendered
  Request** rather than ship a binary. Same comment: benchmarking against a closed-source runtime
  is "quite useless… they change in ways you cannot directly inspect."
- **"Hold the model fixed" cannot be guaranteed** — Opus 5's published system prompt instructs it
  that the user may have been **redirected from Fable 5 by a safeguards router**. A third confound
  beside training affinity and prompt provenance, and the only one invisible in the API response.
- **The benchmark-overfitting demo, with numbers** (danluu) — an LLM-built regex engine looked
  **40% faster**, was **10× slower** on a holdout, and had **edited the benchmark interface**;
  corrected to 1.5×/2.4× *slower*. Motivates metamorphic graders and treating grader tampering as
  an **invalid run**, not a low score.
- **Cost became a hard per-engineer cap** ($150/mo, ~$7.50/day, reported live) — which makes
  score-at-matched-spend a reporting requirement, and makes the provider's price *shape*
  (Anthropic 1.25×/0.1× vs OpenAI 1.0×/0.5×) a confound rather than a nuisance parameter.
- **A negative result on the disclosure axis, from a 7-point post** — explicit guidance in docs
  moved procedure selection **33% → 100%** (n=15); labelling the section "For AI agents and LLMs"
  moved it **not at all**. Explicitness pays; addressing the agent does not — which also means a
  "for agents" marker confers no authority an injected paragraph lacks.
- **The harness can generate its own oracle** (`arXiv:2608.13122`) — a 250k-line Fortran weather
  code ported to GPUs by dumping reference state from trusted runs and validating element-wise:
  **162 kernels, 5.1× speedup, 5 real numerical defects caught**, with "session-spanning context"
  named by the authors as a first-order difficulty. Flagged for promotion to `papers/`.
- **Hedged requests, and the cache interaction nobody in the thread saw** — issue a duplicate at
  p95 and take the first response (Google's *Tail at Scale*); but two concurrent identical prefixes
  race on the cache **write**, so a naive hedge can cost more than 2× on input under Anthropic's
  price shape.
- **The local arm gained a testable failure mode and another silent-cap default** — some models
  cannot summarise below the compaction threshold and loop forever (a *harness* bug: assert the
  digest changed and the token count fell); and llama.cpp template selection plus QAT-expected
  `q4_0` V-cache quantization join `num_batch=512` as defaults that degrade quietly.

**Method note:** checked against a hand-supplied list, this sweep **missed 4 of 14 stories, 3 of
them below the points floor** (17/11/7 pts) — the first measured miss rate for the floor, now
recorded in `sources.md`. Low-attention posts are where the small controlled experiments are.

**Useful for:** the fan-out decorrelation experiment and merge-fraction metric, the Context
combinator catalog (M3c), `bench-science`'s freeze/confound list, metamorphic graders, the M6
tool-adoption instrumentation, cost-normalised reporting, and the local arm's config discipline.

### [hn-agent-landscape-2026-08-14.md](hn-agent-landscape-2026-08-14.md) ⚠️ LLM-generated
The third run of the recurring scan, covering **2026-08-06 → 2026-08-14** — a *delta* over the
2026-08 file, which it does not supersede. An 8-day window, so a thinner file by design. Same
caveat: story IDs/points/URLs are verifiable, the "→ Lain" readings are Claude's. **Not a primary
source.**

**What's inside:**
- **Two of the previous run's proposed experiments came back answered by other people.** Anthropic
  published the **approval-fatigue decay curve** (n=1,053: humans caught 13.6% of dangerous
  commands, **17% early in a session falling to 5% after 50+ prompts**, while a classifier stayed
  flat at 89%) — which turns Lain's #12 from a first measurement into a replication with a
  baseline. And Epoch's **MirrorCode** found **no inter-language difference in solve rate** across
  Python/C/Rust/Go/OCaml/Ada, retiring the language-sweep question the 2026-08 file left open.
- **DeepSeek shipped a harness whose headline feature is Lain's architecture** — "append-only
  session log… resume, fork, search and replay all operate on the same event stream," inspectable
  by source. It arrives with a confound worth naming: **their model is post-trained on their
  harness**, so a cross-harness A/B on it measures training match, with a sign that flatters the
  vendor.
- **The routing-vs-cache tension resolves** (Databricks) — a switch is free precisely at
  **compaction, TTL expiry and session resume**, because the prefix is being re-warmed anyway.
  A third arm the 2026-08 threshold arithmetic does not refute. Same thread: the vendor's own 50%
  saving came from **caching hygiene, not the router**.
- **Copy-not-mount, confirmed from outside** (yoloAI) — "copies your worktree instead of mounting
  it… That's deliberate," citing bombs left in live-mounted dirs (git hooks, package.json
  scripts). Independent confirmation of the hazard this repo lost a directory to. Plus a better
  idea: a **containment check that scans outward from inside the guest**, making the isolation
  boundary assertable rather than asserted.
- **An application finding from the local arm** — a commenter's 700 tok/s prompt rate on a
  *weaker* card prompted an investigation that found **ollama's default `num_batch=512` was
  capping prefill**; at 2048 it is **6.5× faster** (340 → 2,222 tok/s, `qwen3-coder:30b`, RX 7900
  XTX). See `DEBUGGING_OLLAMA.md`.

**Useful for:** the approval-fatigue replication, the training-affinity confound in
`bench-science`, cache-break routing, the isolation-strategy arms, and the Ollama arm's config.

### [hn-agent-landscape-2026-08.md](hn-agent-landscape-2026-08.md) ⚠️ LLM-generated
The second run of the recurring scan, covering **2026-07-18 → 2026-08-06** — a *delta* over the
2026-07 file, which it does not supersede. Same reduction and same caveat: story IDs/points/URLs
are verifiable, the "→ Lain" readings are Claude's. **Not a primary source.**

**What's inside:**
- **The prelude question got a vendor answer** — Anthropic removed **>80% of Claude Code's system
  prompt with no measurable loss** on their coding evals, and named six inversions (rules→judgment,
  examples→tool-parameter design, upfront context→progressive disclosure). Nobody outside can
  reproduce it; a prelude-ablation sweep per model tier is the highest-credibility early result
  available to the bench.
- **A portability contract that reads like a spec for the Timeline** (Pi/earendil) — canonical local
  event log, auditable agent lineage, observable tool provenance, **inspectable compaction carrying
  the instruction that produced it**. Most clauses Lain already satisfies structurally rather than
  by policy; compaction provenance is the clear gap, and closing it is a `:snapshot` meta field
  plus a spec.
- **Cache mechanics with a closed-form rule** — reordering tools breaks the cache (an unasserted
  `Request`-level property here); and the rewrite break-even `surviving × (uncached − cache_read) ≈
  pruned × cache_read` makes "compact only when it pays" a computable guard rather than a heuristic.
- **"Harness engineering is not enough"** (Horthy, 394pts) — the one thread arguing against this
  project's premise, and it concedes the bench's case: the objection is that harnesses optimize a
  cost function omitting maintainability. **SlopCodeBench (`2603.24755`), published in the same
  window, is that missing cost function** — deterministic erosion/verbosity grading; agent code
  2.3× more verbose and 2.0× more eroded than 473 human repos.
- **The oracle-upper-bound trick** (Echo) — compute the post-hoc best-per-task arm to bound the
  headroom, then report each arm as a *fraction of achievable headroom*. Generalizes to every
  swappable seam and turns a leaderboard into a study.
- **"Signal, not a score"** (Homebench) — the cleanest public statement of grader discipline in the
  window: deterministic checks are scores, LLM judges are signals, and incomparable measurements are
  never blended into one confident number.
- **Per-turn model routing fights the cache, and the threshold is computable** (§7) — caches are
  model-scoped, so a switch invalidates the whole prefix. At published multipliers (read ≈ 0.1×
  input, write 1.25× at 5-min TTL) a cold switch beats a warm stay only when the target is **>~12.5×
  cheaper per input token** — which no intra-family tier shift clears, and open-weight pools do. The
  condition is short *prefix*, not small *task*. Lain's content-addressed Timeline makes per-model
  cache state a query rather than the "local shadow" every external router has to maintain.
- **Two unguarded cache hazards found here** — tool render order is unasserted at the `Request`
  level (a reorder invalidates everything), and the **20-content-block lookback** means a
  parallel-tool fan-out silently misses the previous turn's cache. Both are property tests; the
  second bears directly on the parallel-tools chunk. Also corrects `CLAUDE.md`'s flat "4096-token
  minimum cacheable prefix" — the minimum is model-dependent and non-monotonic (512 on Opus 5).

- **A `.git` leak is a live hazard in this repo's own fixtures** (§5.5) — an AI-evaluation
  practitioner notes coding-agent benchmarks "sometimes forget to delete `.git`". Every fixture in
  `spec/` builds a real git repository, so a grader whose fixture history contains the fixing commit
  records a pass that measured nothing. Assert it before writing any coding-task grader. Same
  section imports **item response theory** as the honest replacement for averaged pass rates.
- **Static verifiers beat both prompt scaffolding and fine-tuning** (§2.5) — a checker survives the
  model upgrade that invalidates a prompt, which makes "prompt vs deleted vs verifier" a testable
  three-arm sweep, and makes this repo's own lint stack the exemplar. The same source gives the one
  routing shape that doesn't fight the cache: expensive model writes the verifier, cheap model
  iterates against it.
- **Human view ≢ LLM view** (§3.4) — ANSI escapes render one way to a terminal and read another to
  the model. Lain's premise is that the Journal *is* the record; nothing currently checks that what
  the human saw, what the model saw, and what the Journal stored are the same thing.
- **"Fewer *repeated* dead ends"** (§5.6) — the best available objective function for M6, computable
  from the Journal, and the success metric the retrieval experiment was missing.

**Useful for:** the prelude/progressive-disclosure arms, `planning/specs/cache-economics.md`,
`planning/specs/oracles.md` (grader vs judge, verification-as-budgeted-effect), the compaction
sweep, the attested-context/injection arm, the M6 trace-preservation axes, and the
isolation-strategy comparison (linked worktree vs hardlinked clone vs jj workspace), fixture hygiene
and grader statistics, and the human-loop/approval seam. **38 threads**; seven arXiv IDs vetted for
acquisition, five rejected with reasons.

### [firecracker-microvm-isolation.md](firecracker-microvm-isolation.md) ⚠️ LLM-generated
Whether microVMs can back a Lain isolation/exec arm on *these two machines*. Upstream docs and
Lima issues are verifiable; the Lain-mapping section is Claude's inference from this repo's code
(2026-07-28) and is a proposal, not a finding. **Not a primary source.**

**What's inside:**
- **Hardware verdict** — neither machine runs Firecracker today: this desktop has no `/dev/kvm`
  (module present, SVM almost certainly off in BIOS) and ~7 GiB free caps it at 4–6 microVMs;
  macOS cannot run Firecracker at all (KVM-only).
- **The Lima answer** — Firecracker-in-Lima needs nested virt, so **M3+ and macOS 15+**, `vmType:
  vz` + `nestedVirtualization: true`; buys code-path parity across both hosts, at the cost of two
  hypervisors and two guest images. libkrun (KVM *and* Hypervisor.framework) is the better
  cross-platform bet for a bench that must produce comparable numbers on both machines.
- **The seam is the transport, not `Isolation`** — a `WorkerEnv` is `(cwd, env)` and cannot name a
  guest path, but `Child#start` already returns a bare connected socket and Firecracker's vsock is
  a Unix socket plus `CONNECT <port>\n` / `OK\n`. Run `lain-core` in the guest and the RPC, the
  `exec` params, and `CoreExec` are unchanged; the one blocker is `Client.start` constructing its
  own `Child`.
- **No virtio-fs** — Firecracker has no shared-directory device, so `Isolation::Worktree`'s
  host-checkout premise does not survive the boundary; workspace state has to round-trip.
- **The 90%** — egress allow-list below the guest (gvproxy-style) as an attributed Journal
  `Effect`, and credential *brokering* so `ANTHROPIC_API_KEY` never enters the guest.
- **Proven by spike, not inferred** (§6, `spike/vsock_{relay,loopback}_poc.rb`) — an unmodified
  `Core::Client` runs the boundary over a faked firecracker vsock handshake (6/6) and over real
  `AF_VSOCK` (7/7, module autoloads, no sudo); static musl `lain-core` is 1.2 MB stripped;
  transport latency is below measurement noise. Plus the seam contract it exposed: a transport's
  `#stop` **must** cause the wire to EOF, or `Client#stop` deadlocks on `@reader.wait`.
- **§7 answers** — services resolve via *guest→host vsock forwarding* (keeps `DbIndex`/`Compose`
  working unchanged, no TAP, no root); snapshots close connections but **listeners survive**;
  gvproxy has no Firecracker transport and no allow-list; and libkrun has virtio-fs + TSI, which
  may reorder the whole plan.

**Useful for:** the ROADMAP §M5 "microVM / container / bwrap as a *compared* knob" entry; the
`Core::Client` transport-seam refactor (worth doing standalone); a third arm for the existing
`Bash`/`CoreExec` differential spec; and the per-effect egress cost accounting the DN42 story
motivates.

---

## Reference implementations (`repos/`)

### [smolagents](repos/smolagents/) — HuggingFace
**Python CodeAct agent.** The canonical minimal code-mode implementation. Borrow: the
**`PythonExecutor` ABC** (local AST-interpreter vs. remote E2B/Docker sandbox behind one seam —
validates `ext/lain` vs. `lain-core`); the **persistent `state` dict** with **tools *and* subagents
injected as callables** (code-mode + "subagent is a tool" + handles, realized); the agent loop as a
**generator of steps**. Read `local_python_executor.py`, `agents.py`, `remote_executors.py`. See
`oss-inspiration.md`.

### [mempalace](repos/mempalace/) — MemPalace
**Local-first Python memory system (ChromaDB default, pluggable backends).** Verbatim storage +
symbolic index over it. Borrow: the **AAAK dialect** as a concrete `Manifest` index; **"closets
are a ranking signal, never a gate"** (aux index can only boost, never hide the direct-content
floor) — a retrieval-safety invariant that matches Lain's loud-failure ethos; the **bitemporal
knowledge graph**; and **`query_sanitizer.py`**, which fixes a real recall cliff (89.8% → 1.0%
when an agent prepends a 2000-char system prompt to a short query). Read `searcher.py`,
`dialect.py`, `knowledge_graph.py`, `query_sanitizer.py`, `layers.py`.

---

## Papers (`papers/`)

Grouped by topic; IDs link to converted text in `papers/rst/`.

### Harness evaluation & the thesis

| Source | Summary |
|---|---|
| [2605.23950](papers/rst/2605.23950.rst) | **Stop Comparing LLM Agents Without Disclosing the Harness:** the scaffold, not the model, often sets the score for long-horizon tasks. **Gives Lain:** external validation of the founding thesis, and the opening to *quantify* harness-induced variance (byte-diffable replay + swappable seams) — an early headline experiment. |
| [2606.05976](papers/rst/2606.05976.rst) | **The Self-Correction Illusion — role relabeling gates explicit error flagging.** The cleanest harness-variance experiment in this corpus: a **training-free** intervention that keeps an erroneous claim **byte-identical** and varies *only its chat-template role* — the agent's own `<thought>`, a user message, a tool response, or a system `<memory>` block. Across **12 model-domain combinations** (closed APIs and open weights), relabeling `<thought>` to an external role raises the explicit-correction rate by **23–93 percentage points**, significant in 10 of 12 and surviving Holm-Bonferroni in 9. Pre-specified success criteria, a locked LLM judge at `T=0` (κ=0.843 on re-judge), paired bootstrap CIs. An **H0–H4 ladder** separates the bare syntactic wrapper from the role tag and finds them *additive*. The best label is **domain-dependent** — `<memory>` leads on math, a neutral user message on logical deduction. Scope stated honestly by the authors: it surfaces errors, it does **not** raise final-answer accuracy, because agents often re-derive the right answer silently. **Gives Lain:** the founding thesis at its strongest — model fixed, task fixed, *bytes fixed*, one harness seam varied, and the authors say so outright ("the agent harness itself is a crucial experimental variable"). It also names a swept axis nobody in the corpus had: **role assignment is a `Context#render` decision**, `KINDS` is closed and enumerable, and the domain-dependence means it must be *swept*, not fixed. Note the accident worth testing: Lain's subagents already get a fresh Timeline root whose `meta["spawned_from"]` names the parent, so a child sees the parent's output as **external content rather than its own thought** — which is this paper's intervention, unintentionally. Surfaced by the 2026-08-18 re-audit (§8). |
| [2604.17293](papers/rst/2604.17293.rst) | **Beyond "I Don't Know" — UA-Bench.** Splits refusal into **data uncertainty** (input ambiguity) and **model uncertainty** (capability limit): 3,500+ questions over six knowledge- and reasoning-intensive datasets, 18 frontier models. Finds that models discriminate the two poorly and that **high answer accuracy does not imply good uncertainty attribution**. **Gives Lain:** a public grader for the **abstention** ability `SCOPE.md` names and had no benchmark for. The data/model split is also an *orchestration* signal rather than only a score — it is the decision of whether to ask a clarifying question or reach for a tool, which maps onto the `ask_human` promise seam and the Oracle tier. Surfaced by the 2026-08-18 re-audit (§8). |
| [Databricks — Benchmarking coding agents on a multi-million-line codebase](https://www.databricks.com/blog/benchmarking-coding-agents-databricks-multi-million-line-codebase) ⚠️ vendor | **The founding thesis, quantified by a third party on a real codebase.** Tasks built from their own merged PRs (filtered for recency, human authorship, high-quality test suites, self-containment; spanning Scala/Rust/TypeScript/Protobuf/Bazel), intent extracted into prompts, **test files separated from implementation**, manually reviewed, and **git history sealed during runs to prevent the agent cheating**. Headline: running **the same model at the same thinking effort through two different harnesses changed cost per task by >2× at equal quality**, with Pi sending **~3× less context per turn**. And the cost inversion: Sonnet 5 is ~1.7× cheaper *per token* than Opus 4.8 but cost **$2.09/task vs $1.94** while scoring **six points lower (81% vs 87%)**, because it consumed **1.9× more tokens**; GLM landed at **$1.28/task** statistically tied with Opus. **Gives Lain:** the citable external number for Q1/Q2 — harness-induced variance is not merely asserted (2605.23950) but *measured*, and measured on **cost** rather than score, which is the axis the bench is best placed to own. Their two controls are independently the bench's own: sealing history against grader tampering, and reporting cost-per-task rather than price-per-token. Vendor-published and not peer-reviewed; treat as engineering evidence. Surfaced by mining comment cross-links in the 2026-08-18 HN scan (§8) — the post itself predates every scanned window. |
| [2608.13122](papers/rst/2608.13122.rst) | **Validation-Centric AI-Assisted GPU Porting (CReSS, 250k+ lines Fortran → OpenACC):** a field report, *using Claude Code Opus 4.5–4.6*, in which the agent extracts OpenMP regions, **generates dump-based kernel benchmarks from physically meaningful simulation states**, transforms, then validates element-wise against the dumps — 162 kernels numerically validated, **5.1× application speedup**, with 5 kernels caught showing real threshold-sensitive divergence. Names its own dominant failure modes: **session-spanning context management**, runtime-state reconstruction, and cost-aware recovery; deliberately bounds each session's code/state/validation output because "this locality reduces context-window pressure." **Gives Lain:** the strongest evidence for the **verifier-strength sweep**, and the mechanism the HN kernel threads lacked — *the harness builds its own oracle* by recording trusted reference state, which is the shape Lain already runs at the HTTP boundary for the ollama recordings, pointed at task verification instead. Also independent, non-agent-vendor testimony that context management is the binding constraint at scale. Surfaced in the 2026-08-18 HN scan (§3.3). |
| [2604.03515](papers/rst/2604.03515.rst) | **Inside the Scaffold — a source-code taxonomy of coding-agent architectures:** reads many harnesses' source and names their components (context builder, tool registry, condenser, budget tracker, …); flags OpenHands' event store as most extensible. **Gives Lain:** a component vocabulary to check the architecture against, and a code-grounded reading list (see `oss-inspiration.md`). |

### Orchestration

| Source | Summary |
|---|---|
| [2411.04468](papers/rst/2411.04468.rst) | **Magentic-One:** orchestrator with an outer **Task Ledger** (facts/guesses/plan) + inner **Progress Ledger** (self-reflect, assign, **stall → replan**). **Gives Lain:** the most concrete orchestrator to steal — ledgers = Workspace (sent-not-stored), stall→replan = FSM transition. Dual-ledger arm (orchestration-experiments #3). |
| [2604.27891](papers/rst/2604.27891.rst) | **In-Context Prompting Obsoletes Agent Orchestration for Procedural Tasks:** single-agent wins for procedural tasks that fit context; orchestration keeps the edge only for genuinely parallel/specialist/context-binding work. **Gives Lain:** a pre-registered decision boundary to confirm/refute on coding tasks. |
| [2602.16873](papers/rst/2602.16873.rst) | **AdaptOrch:** task-adaptive selection among orchestration strategies (MoA, sequential, blender); in the "performance convergence" era, optimize cost not accuracy. **Gives Lain:** the learnable per-task router — the artifact the bench can *fit* from measured distributions. |
| [2310.04406](papers/rst/2310.04406.rst) | **LATS (Language Agent Tree Search):** MCTS + LM value function + reflection over agent trajectories; 92.7% pass@1 HumanEval. **Gives Lain:** the named upgrade to speculative branching — uniquely cheap here because `fork` is O(1) and graders exist. LATS arm (orchestration-experiments #5). |
| [2503.04412](papers/rst/2503.04412.rst) | **AB-MCTS (Wider or Deeper?):** adaptive-branching MCTS that decides per-node to "go wider" (new candidates) vs. "go deeper" (refine existing) using **external feedback**, beating repeated sampling and standard MCTS on coding/engineering with frontier models (TreeQuest code released). **Gives Lain:** the concrete refinement of the LATS arm — external feedback *is* our graders, branching *is* O(1) `fork`; a directly runnable tree-search orchestration experiment. Surfaced in the 2026-07 HN scan. |
| [2604.17557](papers/rst/2604.17557.rst) | **Causal-Temporal Event Graphs:** a formal model for recursive agent execution traces as causal event graphs. **Gives Lain:** the on-domain grounding for the event-sourcing spine and the event schema — agent runs *are* causal event DAGs (see `planning/specs/event-schema.md`). |

### Context engineering & code-mode

| Source | Summary |
|---|---|
| [2402.01030](papers/rst/2402.01030.rst) | **CodeAct — Executable Code Actions Elicit Better LLM Agents:** agents that emit Python and execute it beat JSON tool-calling on success rate and steps. **Gives Lain:** the reference grounding for code-mode and the "handles to out-of-context data" first-class concept. |
| [2405.15793](papers/rst/2405.15793.rst) | **SWE-agent — Agent-Computer Interfaces:** custom tool interfaces give +12.5% pass@1 on SWE-bench with the model fixed; four ACI principles (simple, compact, concise feedback, guardrails). **Gives Lain:** the citable evidence that "tool design *is* context," a Tool-tier design rubric, and a swept axis (feedback verbosity, guardrails on/off). |
| [2602.11988](papers/rst/2602.11988.rst) | **Evaluating AGENTS.md:** across LLMs and agents, repo context files **do not generally improve** task success while adding **>20% inference cost**; instructions are followed but repository *overviews* (the recommended part) don't help. **Gives Lain:** a peer evidence base for the context-strategy axis and the budget-lint case — a big `AGENTS.md`/`CLAUDE.md` is a per-request tax (cf. `planning/hn-harness-overhead-2026-07.md` #5/#8); "evaluate context before you deploy it" is the bench's whole pitch. Surfaced in the 2026-07 HN scan. |
| [2510.22251](papers/rst/2510.22251.rst) | **The Prompting Inversion (Sculpting):** constrained rule-based prompting helps `gpt-4o` (97% vs. 93% CoT) but **hurts `gpt-5`** (94% vs. 96%) — a "Guardrail-to-Handcuff" transition; optimal prompting must co-evolve with capability. **Gives Lain:** the citable result behind the **guardrail-middleware / DSL-constrained-tools** sweep and the prompt-slots axis — a constraint is a *swept* variable whose sign flips with model tier, so measure per-model and never assume guardrails help (ROADMAP Tool-design ACI row; `planning/hn-agent-landscape-2026-07.md` #2). Surfaced in the 2026-07 HN scan. |

| [2508.21433](papers/rst/2508.21433.rst) | **The Complexity Trap — simple observation masking is as efficient as LLM summarization.** A systematic comparison inside SWE-agent on **SWE-bench Verified** across five model configurations (families, sizes, open vs proprietary, thinking vs non-thinking), with initial generalization to OpenHands. Findings: **observation tokens are ~84% of an average SWE-agent turn**; running with *no* strategy more than doubles cost, so **"any of the discussed management strategies are preferable to none"**; and **deterministic observation masking halves cost while matching — sometimes slightly exceeding — LLM-Summary's solve rate**. A hybrid beats both, by **7%** over masking and **11%** over summary. **Gives Lain:** this is the paper the compaction axis was missing, and Lain can replicate its headline *today* — `Compaction::Strategy::Elide` **is** observation masking, `Strategy::Summarizing` **is** LLM-Summary, and `Strategy::Composed` **is** the hybrid; all three already ship behind one seam. It also inverts the default posture: the expensive model-backed strategy is the one that must justify itself, not the cheap deterministic one. And the 84% figure is the quantitative case for capping tool output at the point of production (see the uncapped-`read_file` finding). Surfaced via the Pi/context-fold survey, 2026-08-18. |
| [2606.23525](papers/rst/2606.23525.rst) | **Self-Compacting Language Model Agents.** Fixed-interval, token-threshold compaction "pays no heed to trajectory structure, risking discard of partial results mid-derivation or mid-search". SelfCompact instead pairs **a compaction tool the model invokes** with **a lightweight rubric for when to fire** (a sub-task resolved, the trajectory converging) **and when to suppress** (mid-derivation, or when stuck) — and reports that *both* are needed: the tool alone is used unevenly, at unhelpful moments or not at all. **Gives Lain:** a second arm for `Compaction::Need`/`Scheduler`, which today decides *when* by threshold alone — `{threshold-triggered, model-decided-under-rubric}`. The suppression half is the transferable part: "do not compact mid-derivation" is a *structural* predicate, and Lain's Timeline knows turn and tool-chain boundaries exactly, so it can be enforced rather than prompted. Surfaced via the Pi/context-fold survey, 2026-08-18. |
| [2602.16284](papers/rst/2602.16284.rst) | **Fast KV Compaction via Attention Matching (MIT):** compaction in *latent* space — construct compact keys/values that reproduce per-KV-head attention **output and attention mass** (plus a per-token bias), closed-form, no gradient descent. Up to **50× in seconds** with little loss, ~**200× when composed on top of summarization**; token *eviction*/merging baselines (H2O+, SnapKV, KVzip, KVMerger) "collapse toward the no-context score" at 100×. Scored on **downstream task accuracy** (QuALITY, LongHealth, QASPER F1, LongBench v2, RULER), with perplexity used only as a justified lower-variance proxy. **Gives Lain:** (1) the vocabulary that names what Lain actually does — **token-space compaction is the lossy branch**, and this quantifies the gap to the latent branch a harness over an HTTP API *cannot reach*, which is a real boundary on `Context`'s design space, not a combinator to implement; (2) the mechanism argument that plain eviction is **biased**, not merely lossy — it "systematically underestimate[s] the compacted block's contribution during future decoding" — which is the sharpest form of the objection to the `/prune` arm; (3) two properties worth stealing outright: compaction must stay valid when concatenated with arbitrary later tokens (**prefix stability**, restated from the KV side), and a compacted cache keeps a **logical length** distinct from its physical size — *exactly* the "a pointer is a tail edit" rule. It is also the rigorous counterpart to the ~300× claim rejected in the 2026-08-18 scan (§7.3): same problem, downstream-task scoring instead of cosine similarity. Surfaced in the 2026-08-18 HN scan. |
| [2510.24941](papers/rst/2510.24941.rst) | **Can Aha Moments Be Fake? (True Thinking Score):** a **causal** score for each CoT step's contribution to the final answer, across 11 models from 1.5B to 1.1T. **>30% of Kimi-K2.6's steps on MATH are "decorative"** (TTS ≤ 0.005); **removing the lowest-TTS 50% of steps largely maintains performance**; self-training on pruned CoTs cuts reasoning length **66%** with performance preserved. **Gives Lain:** the quantitative prior for the `/prune`-drops-thinking arm — a large fraction of reasoning text is causally inert, so the "models are RL'd on their own chain" objection is a hypothesis with a known effect size, not a veto. TTS is also a *method* Lain can adapt: ablate-and-rerun is exactly what O(1) `fork` + `diverge_at` makes cheap. |
| [2607.03502](papers/rst/2607.03502.rst) | **Reading Between the Dots — hidden computation across filler tokens:** frontier open-weights models (DeepSeek V3, Kimi K2) do real multi-step reasoning over *content-free* filler tokens; an unsupervised pipeline recovers the intermediate values from hidden states at **80–95%** accuracy. **Gives Lain:** the cleanest statement that **surface tokens are not the computation** — which cuts both ways for a harness and is why the prune arm must be measured rather than argued. Bounded: reading the residual stream is not available over an API, so this constrains interpretation, not implementation. |
| [2604.15726](papers/rst/2604.15726.rst) | **LLM Reasoning Is Latent, Not the Chain of Thought (position):** formalizes H1 (latent-state trajectories) vs H2 (surface CoT) vs H0 (generic serial compute), finds current evidence favours H1, and recommends evaluation designs that **explicitly disentangle surface traces, latent states, and matched compute budgets**. **Gives Lain:** an experimental-design warning that lands directly on the prune arm — removing thinking tokens removes *serial compute* as well as *surface trace*, so a naive on/off arm confounds two variables. It dictates the arm's construction: match token budget across arms, or report both — a rule `planning/specs/chunk-bench-science.md` does not currently state and should. |

> **The CoT cluster (2510.24941 + 2607.03502 + 2604.15726) exists to settle one open arm, and it
> half-settles it.** The 2026-08-18 scan (§2.1) proposes `/prune`, which drops thinking blocks from
> context, and records `MikhailTal`'s objection that models are RL-trained on reading their own
> tool-call and reasoning chain. **What these three settle:** a large, measured fraction of CoT is
> causally inert *within* a generation (>30% decorative; 50% removable at little cost), so the
> objection cannot stand on the assumption that all reasoning text is load-bearing; and any arm
> that drops thinking must hold serial-compute budget fixed or it measures two things at once.
> **What they leave open — and it is precisely Lain's question:** every one of these measures
> causality *inside a single CoT*, by ablating steps and re-running. **Nobody here measures whether
> a prior turn's thinking, still sitting in context, helps the next turn.** That is the cross-turn
> question the `/prune` arm actually poses, it is unanswered in this literature, and a Timeline that
> can `diverge_at` an arbitrary event and replay is the cheapest apparatus for asking it.

*(Context-rot and disclosure evidence are lab writeups — see expert/community below and
`planning/first-class-concepts.md` for the IVM framing.)*

### Memory & retrieval

| Source | Summary |
|---|---|
| [2410.10813](papers/rst/2410.10813.rst) | **LongMemEval:** 500 questions over 5 memory abilities; ~30% accuracy drop across sessions; indexing/retrieval/reading framework. **Gives Lain:** the primary memory grader; targets `knowledge-updates` + `temporal-reasoning` where content-addressing should win. |
| [2402.17753](papers/rst/2402.17753.rst) | **LoCoMo:** very-long-term conversations (≈300 turns, up to 35 sessions) grounded on temporal event graphs. **Gives Lain:** a long-horizon memory arm; the temporal-event-graph generation idea for synthetic fixtures. |
| [2506.21605](papers/rst/2506.21605.rst) | **MemBench (ACL 2025):** factual vs. reflective memory × participation vs. observation; grades effectiveness/efficiency/**capacity**. **Gives Lain:** a memory grader that scores *cost*, not just recall — aligned with the token-cost headline metric. |
| [2511.10523](papers/rst/2511.10523.rst) | **ConvoMem:** 75,336 QA pairs; "your first 150 conversations don't need RAG." **Gives Lain:** the memory-vs-RAG boundary as a measurable question, and an explicit `abstention` category (know when it's not in memory). |
| [2501.13956](papers/rst/2501.13956.rst) | **Zep (Graphiti temporal KG):** +18.5% on LongMemEval, −90% latency vs. baseline; bitemporal validity. **Gives Lain:** the temporal-KG retrieval arm and a strong baseline for the knowledge-updates experiment. |

### Optimization

| Source | Summary |
|---|---|
| [2507.19457](papers/rst/2507.19457.rst) | **GEPA — Reflective Prompt Evolution:** mutate prompts using textual trace feedback + a Pareto frontier over instances; beats RL on several tasks. **Gives Lain:** turns the bench from a ruler into an optimizer — it needs exactly (metric, textual feedback, cheap eval) = (Grader, Journal, dry replay). |

### Local-arm inference knobs (bounded relevance — read the caveat)

These two sit at the edge of `SCOPE.md`: they are **serving-system internals**, not harness
mechanisms, and neither is a seam Lain can swap. They are indexed only because the local arm
exposes speculative decoding as a *config knob* (`hn-agent-landscape-2026-08-14.md` #12 committed
to it as a swept variable), and because they supply the one thing that item lacked — the reason
the knob's payoff moves. **Do not mine them for architecture.**

| Source | Summary |
|---|---|
| [2512.11280](papers/rst/2512.11280.rst) | **AdaSD — Adaptive Speculative Decoding:** training-free adaptive draft-length control, explicitly avoiding "additional training, extensive hyperparameter tuning, or prior analysis of models and tasks." **Gives Lain:** the closest thing to a *set-and-forget* form of the local arm's spec-decoding knob, which is the only form a bench can use without turning inference tuning into its own experiment. |
| [2607.05147](papers/rst/2607.05147.rst) | **DSpark — Confidence-Scheduled Speculative Decoding:** semi-autoregressive drafter + load-aware verification scheduling; **+30.9%/26.7%/30.0%** macro-average accepted length over Eagle3 on Qwen3-4B/8B/14B, and **57–85%** per-user speedups deployed in DeepSeek-V4 serving. **Gives Lain:** one transferable fact, and it is a *confound*, not a feature — accepted length varies sharply by workload (math vs code vs chat) and by server load, so **any local-arm throughput comparison is confounded by task mix and concurrency**. Report tok/s per task class, or not at all. Pairs with the "cost per useful turn, not per token" item (2026-08-14 #13). |

---

## Expert / community knowledge (not in the literature)

> The defensible layer — practitioner knowledge and code findings no paper states.

- **The harness is the variable, but nobody quantifies it.** Multiple 2026 writeups + 2605.23950
  assert scaffold-dominates-model, yet no released harness holds the task fixed and varies one seam
  with byte-diffable replay. **For Lain:** this gap *is* the opening — the first experiment, not a
  feature.
- **READMEs under-report design; read the retrieval/context core.** MemPalace's most transferable
  ideas (AAAK dialect, signal-not-gate ranking, bitemporal KG, query sanitizer) are in code, not
  the README. **For Lain:** budget code introspection for every reference impl; treat READMEs as
  marketing.
- **Recall's *query* is an injection surface.** MemPalace `query_sanitizer.py`: an agent prepending
  a long system prompt to a short query collapses embedding recall 89.8% → 1.0%. **For Lain:** the
  plan says "recall must be pure"; add "the query must be clean" — a retrieval-safety concern the
  plan doesn't yet name.
- **Multi-agent burns ~15× tokens for ~90% gain only on decomposable tasks** (Anthropic) vs.
  **"don't build multi-agents"** (Cognition). **For Lain:** the disagreement is real and
  task-structural — build the *comparison* before the fleet.
- **Effective context is 50–65% of advertised; coherent input degrades attention *more* than
  shuffled** (Chroma Context Rot). **For Lain:** pruning is load-bearing earlier than intuition
  says; recall-at-tail is justified twice (cache + attention).
