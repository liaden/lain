# The agent-harness field, mid-2026 — what the HN scan is worth to us

> **Folded in (2026-07-18):** Tier-1 #1 → `specs/graders.md` (GR-1..GR-3); Tier-1 #2 (guardrail
> stack), #3 (control-flow-as-code axis), #4 (Journal-native lineage-ranked retrieval) → `[exp]`
> fold-ins in `ROADMAP.md` (M3c/M5/M6) + axis-table rows. Tier-2/3 are tracked in `ROADMAP.md` as
> `[exp · parked]` fold-ins under their milestones: DSL/GBNF + external-$ budget + DELEGATE-52 → M3c;
> isolation/egress + summary-inheritance + DOWN/UP framing → M5; local-model fidelity / 26M / inference
> overhead → M6; spatial replay overlay → M4. "Worlds not mocks" stays digest-only (a framing rename,
> not roadmap-worthy).

> Companion to [`hn-harness-overhead-2026-07.md`](hn-harness-overhead-2026-07.md), which already
> mined one thread (48883275) into `specs/cache-economics.md` + `specs/oracles.md`. This doc covers
> the **rest** of a broader scan (past 7 days + a 90-day expansion, ~30 threads). Source digests and
> per-thread "→ Lain" hooks live in [`references/hn-agent-landscape-2026-07.md`](../references/hn-agent-landscape-2026-07.md)
> (⚠️ LLM-generated, verifiable IDs). This doc isolates only what is **additive** to the ROADMAP and
> says where it lands. It does **not** re-propose cache-write attribution, fork-the-parent,
> cache-sibling preludes, the "Hey" fixture, budget lint, or model-as-capability — those are the
> other doc's, already folded.

The scan's meta-finding is the same as the last one, now stated by a frontier lab and a peer-reviewed
paper both: **the harness is a first-order variable that swings the score with the model held fixed**
(`references/.../2605.23950`, "Stop Comparing LLM Agents Without Disclosing the Harness"). That is
Lain's founding A/B (ROADMAP § "one seam, many swept axes"). Nothing below changes the thesis; the
value is in specific arms, graders, and metrics the field surfaced that Lain does not yet name.

---

## Tier 1 — novel, aligned, cheap, and it lands on our weakest surface

### 1. Behavioral & verification graders — the biggest genuine gap `[new spec: graders.md]`

Graders are the least-covered surface in the bench (only `Grader::Fixture`/`Rubric` + the
attested-context grader exist). Three thread-grounded designs, all of which the DAG + Journal make
uniquely cheap for us:

- **Two-pass verification grader** (from Traceforce's pentester, and mirrored in our own review
  panels): a second pass confirms each flagged finding is *real* before it counts. This is not one
  arm — it is a **generic false-positive filter usable by every rubric grader on the bench**, and it
  is exactly the adversarial-verify pattern. Highest-value of the three.
- **Tool-steering detector** (belschak: an MCP whose *descriptions* quietly told the agent to prefer
  it): diff a tool's declared schema/description against its *observed selection frequency*; flag
  tools that win calls out of proportion to their stated purpose. Pure Journal analysis.
- **Frustration/repair grader with intra-session causal attribution** (Agnost; rajeevbakshi's point
  that frustration surfaces in msg 3 but the cause was a tool failure in msg 1): detect
  rephrase-loops / self-corrections / abandonment as *behavioral* eval signals, then walk the signal
  **back through the DAG** to the earlier turn that caused it. Flat-log competitors structurally
  cannot do the attribution; `diverge_at`/lineage is exactly the machinery (cf. CE-2's request-level
  attribution, reused at the turn level).

→ **Home:** new `planning/specs/graders.md` (GR-1..GR-3), referenced from M3c and the M5 grader work.

### 2. The guardrail *stack* on a small local model `[extends repair-middleware, hn §4]`

`hn-harness-overhead §4` already specced tool-call **repair** as a `Middleware` arm (`tolerant`,
`tolerant-and-tattling`). The Forge thread (id=48192383: an 8B model **53%→99%** on agentic tasks)
adds three things that arm doesn't yet have:

- **Sequence, not a single arm:** validate → rescue-parse (`[TOOL_CALLS]`/Qwen-XML/fenced-JSON back
  to canonical schema) → **prereq/step enforcement** (`[PrereqError] analyze needs fetch first`) →
  corrective-nudge-retry on the tool-result channel. Each is one `Middleware`; the monoid composes
  them (a chance to demonstrate associativity — compose two guardrails, show it holds).
- **The metric is *compounding accuracy*, not correct-call rate:** 90% per-step = 40% failure over
  5 steps. Measure the lift **per middleware, in isolation, on a local 8B** (the Ollama path is the
  right substrate — this is where the lift is visible; frontier models mask it).
- **Per-*phase* toolset narrowing** (azurewraith's "narrowed the execution space"): attenuation today
  is per-role/per-spawn (CE-4); a phase-guard narrows the *visible* Toolset within one agent as it
  transitions — "tools are capabilities" made dynamic mid-run.

⚠️ Same guardrail as §4: `Tool::Input` is **shape, not safety**. A repair/narrowing middleware is a
shape accommodation and must never sit where a validator that sounds like a security control could
reach it.

→ **Home:** promote repair-middleware to an M3c/M5 `[exp]` fold-in and add the compounding-accuracy
metric + phase-narrowing to it.

### 3. Control-flow-as-code vs prompt-driven loop — a missing axis `[new arm]`

"Agents need control flow, not more prompts" (id=48051562) + swyx's loopcraft: the field is
converging on **the loop belongs in host code, not the prompt** — the runtime LLM shrinks to an
NL→validated-input translator at `if`/`switch` points. Lain already *owns the loop*, but nothing
frames **coded state-machine vs prompt-driven ReAct** as a swept, comparable axis on the same
Toolset. It is a clean orchestration arm and it directly measures our thesis at the loop level:
"how much loop reliability is control-flow vs prompt, holding tools fixed."

Corollary metric (jamestimmins' "burning indefinitely"): emit per-iteration Journal events for
loop-depth, repeated-tool, and no-progress — the bench's edge over harnesses that hide the loop.

→ **Home:** `orchestration-experiments.md` + an Orchestration-row arm in the axis table.

### 4. Journal-native retrieval, ranked by lineage/outcome `[extends M6 sweep]`

deja-vu (id=48923111) indexes *past agent transcripts* for reuse; zby's review series frames every
memory system as a **four-field record** — *storage substrate · representational form · lineage ·
behavioral authority* — with the thesis **"storage does not imply activation"** (retrieving a turn ≠
letting it shape context — which is "capabilities, not permissions" restated for memory). Two
additive moves for the M6 sweep, both things only our DAG can do:

- **Index the Journal natively** as the memory corpus (deja-vu reverse-engineers logs we already own
  as content-addressed turns), with **index-time secret redaction** before any turn leaves the
  process (distinct from 5-3.5's write-refusal).
- **Rank hits by lineage/outcome, not just text:** prefer turns from *successful* `spawned_from`
  lineages over lexically-closer turns from abandoned branches (latchattack's critique of flat
  verbatim indexes — they can't tell what was rejected/obsolete). A hybrid BM25+lineage score.

zby's four-field record is also a ready **axis-set** for the retrieval sweep alongside LongMemEval's
abilities.

→ **Home:** `specs/memory-read-path.md` (or the M6 retrieval-sweep spec); fold-in bullet in M6.

---

## Tier 2 — worth doing, bigger or needs a decision

### 5. DSL / grammar-constrained tool interfaces
Fowler's "DSLs Enable Reliable Use of LLMs" + Jacquard (effect rows) + the ptx comment ("design the
grammar so illegal states are unrepresentable → semantic errors become syntax errors"). Three
sub-ideas, decreasing readiness: (a) **GBNF grammar-constrained decoding as a Provider variant**
(local models — masks illegal tokens, no retry) to compare against post-hoc `Tool::Input`
validate+retry; (b) expose the just-landed **ast-grep catalog as a DSL-shaped tool** and test
emission validity vs free-form edits; (c) a **per-tool declared-effects catalog** (Jacquard's effect
rows = the `Tool::Input` move extended from input *shape* to declared *capability*). Watch the
OsamaJaber trap: a validator-green result that is non-functional (slower kernel) is reward-hacking —
bench metrics need a non-functional check. → new tooling/DSL spec, or `research-scan` follow-up.

### 6. Isolation as a swappable backend; egress as an observable Effect; credential brokering
Clawk + yoloAI (most-cited repo, 22×) + Gondolin. Workspace-snapshots-as-Timeline-siblings is
already `first-class-concepts §7`. Genuinely new: (a) **isolation backend** (microVM / container /
bwrap) as a *compared* knob, not just an exec seam; (b) **egress allow-list as an observable
Effect** — every allowed/denied network attempt an attributed Journal event, turning "network
denials" into experiment data; (c) **credential brokering** — secrets stay host-side, proxied, never
enter the sandbox (fits "Workspace is sent, not stored" and keeps digests credential-free). Repeated
field lesson: the sandbox is the easy 10%; the policy engine + credential brokering are the 90%. →
`orchestration-model.md` or a new isolation spec (M5/M6 infra; lower urgency).

### 7. Per-effect *external* cost budget + recursive subagent ceiling
The DN42 bankruptcy (id=48500012, ~$6.5k): the cost that bankrupted the operator was **egress $**,
invisible to a token cap. `Agent::Budget` + CE-6 model tokens/$/wall-clock but not **tool-side
external cost** (egress/instance $) nor a **recursive spawn ceiling** (a child fanning out
unbounded). Add an `Effect`-cost dimension and a per-lineage budget that a mid-run hard-stop trips
before a bill lands. → extends `specs/cache-economics.md` CE-6.

---

## Tier 3 — small, parked, or confirming (pull when the milestone opens)

- **DELEGATE-52-style corruption eval** (id=48073246): 19 LLMs corrupt ~25% of a document over a long
  delegated edit; "agentic tool use didn't help" — but their harness was naive `read_file`/
  `write_file`, *exactly what we vary*. A long-workflow corruption fixture beside the "Hey" fixture;
  A/B naive vs structured edit tools. → `hn-harness-overhead §7` neighbourhood.
- **Loop DOWN/UP framing** (loopcraft): DOWN loops add safety on failure, UP loops add autonomy — a
  taxonomy for organizing the four middleware phases + the human-loop-as-blocking-Middleware, not an
  experiment. → `orchestration-model.md` framing note.
- **Small-model tool-call/template fidelity as a named metric**, and the speculative **26M
  tool-caller as a Provider variant** (Needle — "tool-calling is retrieval-and-assembly, not
  reasoning") + **in-process vs out-of-process *inference* overhead** (LibArgus argues the opposite
  of our exec split, for the inference hot loop). → beside the ollama infra.
- **Summary-inheritance** as a third named strategy on the CE-4 spawn-prefix axis (fresh-root /
  fork / **summary**).
- **Spatial "where did the agent work" replay overlay** (Mindwalk): the data exists (Workspace
  Timeline file-touch), the viz doesn't; nice-to-have. → `interface-integration.md`.
- **"Worlds not mocks"** (Sigil): our `Provider::Mock`/`Handler::Mock` *are* worlds — keep the
  substitution boundary at the Effect system, assert on the emitted Channel/Effect trace. A framing
  note, not new code.

## Confirmations — external validation, no action
- **The harness is the variable, with numbers** — 2605.23950 (peer-reviewed) is the citable version;
  practitioner writeups (loopcraft, Fowler's learning-loop) echo it. (The OpenAI harness-engineering
  posts that also echoed it were **dropped** — 403 + secondhand only; see the references doc §10.)
- **Transparent subagents beat encrypted ones** — Codex began encrypting delegation prompts
  (id=48905028); the community's requested fix (a plaintext audit companion, excluded from child
  context) is structurally what `spawned_from` + the Journal already are. Motivates the
  swappable-inheritance study (already CE-4) and a "delegation diff" observable.
- **Isolation is an engineering, not administrative, control** (prod-DB deletion, id=47911524;
  maxbond: "prompting is an administrative control") — validates "tools are capabilities, not
  permissions" and "an in-process sandbox is not a sandbox."
- **Local models are good now but the harness is the differentiator** (id=48555993) — template/
  tool-call fidelity is where local models silently break; our Ollama arm is aimed right.
