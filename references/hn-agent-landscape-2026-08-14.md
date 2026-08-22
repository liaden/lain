# HN agent-harness landscape — survey, 2026-08-14

The third run of the recurring HN scan (`sources.md` § HN discussion survey). Window:
**2026-08-06 → 2026-08-14**, i.e. everything since the second run's cutoff, so this file is a
**delta** over `hn-agent-landscape-2026-08.md` rather than a re-survey. Same reduction: each
thread to *what it gives Lain* — a design bet, an experiment axis, or external corroboration.

> ⚠️ **LLM-generated** (Claude, 2026-08-14) — not a primary source. A synthesis of public HN
> stories + comment threads, fetched via the Algolia HN Search API. Story IDs, point counts and
> URLs come from the API and are verifiable; the *readings* ("→ Lain") are Claude's, not the
> commenters'. Treat the linked articles and comments as the citable layer and this file as an
> index over them.

**Method.** `hn.algolia.com/api/v1/search` over 27 **single-word** topic queries at `points>40`,
plus a query-free `search_by_date` sweep at **`points>100`** — both corrections the previous run
wrote down and this run applied (multi-word queries under-return because Algolia prefix-matches
only the last token; the 2026-08 run's `points>250` floor was blind to a whole tier). 538 raw
hits, **369 distinct stories**, of which exactly **one** was already covered — the window starts
at the prior cutoff, so the exclusion set barely bites and its real job is guarding the boundary.
24 shortlisted by SCOPE fit and pulled in full via `…/api/v1/items/<id>`; comment text
HTML-unescaped before link mining. Full thread digests are in the session scratchpad.

**The window is short — 8 days against the previous run's 19** — so this is a thinner file by
design. Rank by what changed, not by how much.

**The one-line delta.** The 2026-08 survey ended with a list of experiments Lain could run that
nobody had. In this window **two of them came back with other people's numbers**: Anthropic
published the approval-fatigue decay curve (§3.1, n=1,053, 17%→5% across a session), and Epoch's
MirrorCode answered the programming-language question the last survey flagged as open (§5.1, no
inter-language difference in solve rate). Meanwhile DeepSeek shipped a harness whose headline
feature is an append-only event log with fork/replay (§2.1) — which is Lain's Timeline, built by a
frontier lab, and it arrives with a confound worth naming: **their model is post-trained on their
harness.**

---

## 1. Cost, caching and the routing seam  (SCOPE: harness-evaluation, optimization)

### Managing AI Coding Costs at Scale — id=49214468 (315pts, 268c)
`databricks.com/blog/managing-ai-coding-costs-scale`. Vendor post about their Omnigent
meta-harness, and the comments are worth more than the article — including a reply from
`ankitmathur`, who works on the router and answers the cache objection the 2026-08 survey built
its §7 around:

> the router takes in the task description and infers what models and harnesses are available and
> makes a recommendation **up-front**… it's only changed halfway through if there's a major delta
> in complexity… **1. The cache is generally reset after a compaction — this is the best time to
> make a switch if you want. 2. In many cases, the max duration of a cache is 1h, so if a session
> is being resumed after a long time, that's also a good time to re-assess the complexity.**

`Terretta` supplies the counterweight and quotes Databricks against itself: auto-routing "is shown
to destroy the single largest token cost they found," while their own text says "simple tuning of…
caching settings… 50% reduction in… costs, with no observed quality degradation." So the measured
win is caching hygiene, and routing is the part being marketed.

Two more worth keeping. `habosa` enumerates why AI pricing is unlike anything priced before, and
the third item is the one that lands on this repo: **"Nobody, not even the model provider, knows
what your request will cost before it returns. You're writing a blank check every time you hit
enter."** And `lazarie`, on a 900k-LoC codebase they claim is 99% AI-written: **"less than 5% of
wall time is an AI doing reasoning or coding, 95% is running the verification deterministically."**

**→ Lain.** `ankitmathur`'s two switch points **resolve the §7 tension rather than restating it**,
and they are the useful correction to the last survey's threshold arithmetic. That analysis
concluded routing loses because a switch invalidates the prefix — true, but it treated the prefix
as always warm. It is not: compaction resets it, and the TTL expires. **At those two moments the
switch is free**, because you are paying the re-warm regardless. Three pulls:
- **Route at cache-break boundaries, as a named arm.** `{never switch, switch per turn, switch
  only at compaction/TTL/resume}` — the third is new, costs nothing on the cache term, and is the
  only one the §7 arithmetic does not already refute. Lain knows exactly when compaction fires and
  content-addresses the prefix, so the predicate is computable rather than estimated.
- **Rank caching hygiene above routing in the sweep order.** `Terretta`'s catch is that the
  vendor's own 50% came from cache settings, not the router. If a cheap fix dominates the
  expensive one, measure it first — and Lain's cache-economics specs already have the machinery.
- **`habosa`'s blank cheque is the Journal's pitch.** Cost is unknowable *before* the call, which
  is exactly why recording it per turn afterwards is worth something. Pairs with the 2026-08
  survey's Cursor entry (a vendor withdrawing cost data) into one line for the README.

`lazarie`'s 95%-verification split is worth holding as a hypothesis about where harness design
actually pays: if wall time is dominated by deterministic verification rather than inference, then
orchestrating verification is the harness's main job and token-efficiency work is a rounding
error. That is a measurable claim and Lain can measure it on itself.

### Message your other Claude Code sessions — id=49222824 (172pts, 72c)
`code.claude.com/docs/en/cross-session-messaging`. Anthropic ships session-to-session messaging.
Most of the thread is "I already built this," which is itself the signal (`tengada1`: "so much
personal, almost disposable software being made"). Three comments matter.

`simonw` states a want that is a specification:

> I'm fed up with compaction. I want my agent to get compacted **but also retain full access to
> the prior conversation via search and tool calls** — I want it to know "the requirements for X
> were discussed in detail previously in conversation C51E31CE…" and have a tool that lets it
> dispatch a subagent to find those details again. Do any of the coding agents have this already?

`eigenblake` gives the token argument for shared persistent sessions over subagents: "some skills
just take too much of a token penalty to invoke… **One agent pays the cost of that large skill
once**, and you don't have to keep paying for it in input tokens for the rest of that
conversation." And `deviantintegral` names the security consequence: the feature "totally breaks
sandbox / VM isolation if you have Remote Control enabled… not just within sessions on a single
machine, but can send commands to any session accessible by your account."

**→ Lain.** `simonw`'s question has a structural answer here and it is worth treating as the demo
rather than as a feature request. Compaction that *replaces* history is lossy by construction; a
content-addressed Timeline lets a snapshot stand in the rendered prompt while the full events
remain reachable and searchable by digest. That is **compaction as a rendering choice rather than
a destructive edit**, and it composes with the 2026-08 survey's compaction-provenance item (#6):
if the snapshot carries both the instruction that produced it and the digest range it replaced,
"go re-read what was actually said" is a tool call, not an archaeology project. `simonw` asking
publicly for the thing the architecture already implies is the strongest signal in this section.

`deviantintegral`'s point generalizes into an invariant Lain should not violate on its own
orchestration path: **a channel between agents is an authority edge**, and if two isolated
workspaces can message each other, the isolation boundary is whatever the weaker of the two allows.

---

## 2. Harness architecture  (SCOPE: harness-evaluation, orchestration)

### DeepSeek Harness developer preview — id=49285244 (715pts, 286c)
`deepseek.com/harness/en/`, `github.com/deepseek-ai/deepseek-harness`. A frontier lab shipping an
open coding harness. The landing-page feature that the thread fixates on, quoted by both
`SwellJoe` and `kamranjon`:

> Every run is traceable. Everything the model sees is recorded in an **append-only session log**:
> system prompts, reasoning, tool calls and results, subagent scheduling, and every context
> injection. In the Trajectory view, you can inspect these records **by source**. **Resume, fork,
> search, and replay all operate on the same event stream.**

`SwellJoe` reads it as the differentiator: "That's a killer feature, IMHO, and one that US models
won't allow you to do, as their traces are encrypted, obfuscated" (cf. §3.3). `z_rho_one` supplies
the fact that matters most and is buried: **"DeepSeek V4 models are post-trained on DSH."**
Architecturally it is Pi-like — minimal core, everything a plugin — on top of Cordis v4, a plugin
lifecycle system with RAII-style cleanup handlers (`ef2k`, and `badlogic` from the Pi team giving
a fair critique of the cross-plugin DI). `vhantz` lands the sharpest objection in the thread:

> this repository has a "skill" definition that consists in instructing the LLM to run pre-commit
> checks. But we have solved this a long time ago, it's called **git hooks**. I do not understand
> why they don't simply wire those instructions as testable, reusable, deterministic code routines
> in the git tool call itself.

`iambenm`'s rebuttal is the honest one: hooks don't survive a clone, blindly installing them is a
supply-chain risk, and what you are often trying to constrain is *the LLM's* action rather than
the repository's state.

**→ Lain, and this is the most direct external validation in any of the three surveys.** "Append-only
event log; resume, fork, search and replay all operate on the same event stream" is a description
of `Event`/`Store`/`Timeline` written by someone who has never seen it. Inspecting records **by
source** is the attribution `Channel` already carries. Three pulls, and the third is new:
- **Stop treating the traceable-DAG as a differentiator and start treating it as table stakes with
  a better implementation.** DSH has the log; Lain has the log *content-addressed*, which is what
  makes `fork` O(1) and `diverge_at` meaningful. The claim to defend is not "we record everything"
  but "we can tell you exactly where two runs diverged and what it cost."
- **`vhantz`'s objection is the 2026-08 survey's static-verifier item (#14) restated by a
  skeptic**, and it is the same argument from `harness-engineering`: a checker survives the model
  upgrade that invalidates a prompt. That this keeps arriving independently, from people annoyed
  rather than persuaded, raises its priority.
- **"Post-trained on their own harness" is a confound the bench must name.** If a lab trains a
  model against a specific harness, then a harness A/B on that model measures *training match* as
  much as harness quality, and the effect has the sign that flatters the vendor. This is a new
  axis: **hold the harness fixed and vary the model's training affinity**, or at minimum report
  it, because a cross-harness comparison that ignores it is measuring the wrong thing. Nothing in
  `planning/specs/bench-science` covers this yet, and it is the kind of silent methodology error
  the last survey's §5.7 (unmatched effort settings) was written to prevent.

### Mistral patent for "code implemented tool calls" — id=49243397 (233pts, 198c)
`patentsgazette.uspto.gov/…/US12670045`. Most of the thread is a software-patent argument; the
mechanism is the takeaway, and `HarHarVeryFunny` reconstructs it from the confusing diagram: the
model emits **a code block containing multiple tool invocations**; a server executes that block in
a sandbox, resolving contained tool calls (some locally, some by calling back to the client) and
returns the final result. `dev_dan_2` describes building the same thing independently, for control
and monitoring reasons: "every interaction with the outside world happens at one place only."

Comment-linked prior art worth keeping: Cloudflare's `code-mode` and `code-mode-mcp` posts,
OpenAI's programmatic-tools guide, Microsoft's agent-framework code-interpreter docs, Anthropic's
advanced-tool-use post, and `huggingface/smolagents` — which is already checked out under
`references/repos/`.

**→ Lain.** This is the REPL-vs-DAG axis from the 2026-08 survey (§2.3, `budududuroiu`'s "a DAG
cannot express early exit") now with a patent claim staked on the code-mode side and a named
corpus of implementations. Two things follow. First, `2402.01030` (**CodeAct**) is already in the
paper corpus and is the citable evidence, so the arm is grounded rather than speculative:
`{JSON tool calls, code-mode block}` × `{model tier}` on matched tasks, scored on steps and
tokens. Second, the mechanism is a **`Toolset` rendering strategy plus an `Effect::Handler`**, not
a new primitive — which is the useful thing to notice, because it means Lain can run the
comparison without a redesign. Note also the placement rule bites here exactly as written: the
code block executes in a sandbox, i.e. **out of process**, never in `ext/lain`.

---

## 3. Approval, isolation and what the trace leaks  (SCOPE: harness-evaluation; ops)

### Auto mode is now the default in Claude Code — id=49239021 (291pts, 313c)
`claude.com/blog/auto-mode-default-in-claude-code`. **The single most valuable citation in this
window**, because Anthropic ran the study the 2026-08 survey listed as experiment #12 and
published numbers. Quoted by `ta-run` from the announcement:

> We hired **1,053 paid testers** through a research vendor for a coding study. The testers caught
> the dangerous command just **13.6%** of the time (143 of 1,053), while auto mode blocked **89%**
> of the same commands (937 of 1,053). Head to head, auto mode blocked **800 commands that a human
> approved**, while humans blocked only 6 that auto mode allowed. **As sessions got longer, humans
> did worse: they blocked about 17% of dangerous commands early in a session, dropping to about 5%
> after 50 or more prior prompts, while auto mode's block rate stayed flat regardless of session
> length.**

`sunleash` reverse-engineered the classifier, and the architecture is as interesting as the result:

> The model first classifies the safety of the command **in isolation, no thinking involved**.
> Sonnet 5. Goes to second stage only if it's likely unsafe, in which case the model next considers
> your intent (your prompt, CLAUDE.md and any answers to the questions). **The model doesn't
> receive the full transcript to reduce surface area of the prompt injection.** It mostly receives
> your prompts and main model's tool use blocks. So any text in files, website fetch or bash
> command output doesn't influence the decision in any way.

Consequences the thread draws out: `npm install` is always classified safe, so the *main* model is
relied on to have read `package.json` first — and auto mode is therefore **not available with
Haiku as the main model**. `dgunay` names a failure the numbers don't cover: the classifier is
also Claude, so it approves things that are not *dangerous* but are *misaligned* — "Manual review
is the last line of defense I have here." `raesene9` reports a server-side classifier change
silently breaking a working security-research process, which is an argument for policy you can
read. `Silhouette` asks the question the announcement invites: if neither humans nor the
classifier are reliable, what does that say about how many dangerous commands are attempted daily?

**→ Lain, and this is a rare case of an experiment being *answered* rather than merely
corroborated.** The decay curve is real and now has a shape: **17% → 5% across ~50 prompts**. What
that changes:
- **The approval-fatigue sweep is now a replication with a published baseline**, which is a much
  stronger result than a first measurement. Lain's Journal records every approve/deny with its
  timestamp and the effect it gated, so the curve is derivable from data already kept — and the
  interesting question moves to the one Anthropic did *not* answer: does **batching** approvals, or
  varying the prompt rate, flatten it? That is the `{always-ask, classifier-gated,
  isolate-and-never-ask}` comparison with a real y-axis.
- **The restricted-view classifier is a design to steal, and it is a Middleware.** "The classifier
  does not receive the full transcript, to reduce prompt-injection surface" is precisely the
  boundary discipline `Sensitivity::Policy` and `Gate` already embody — one place that decides,
  fed a deliberately narrow input. Making the gate's input a *declared projection* of the Timeline
  (prompts + tool_use blocks, never tool results) is a small change with a stated threat model,
  and it is testable: inject an instruction into a tool result and assert the verdict is unmoved.
- **`dgunay`'s distinction belongs in the score vector.** Danger and misalignment are different
  failures, and a classifier trained on the first will pass the second. A grader that only counts
  destructive commands would rate auto mode perfect while it approves work the user did not want —
  the same "green test that can't tell the subject from a plausible wrong one" pattern this repo
  already catalogues.
- **`raesene9` is the argument for local policy.** A gate whose rules live in `.lain/` and change
  only when the user changes them is a real property, not a fallback, and worth one line in the
  README next to Journal cost accounting.

### Docker Sandboxes — id=49239751 (692pts, 393c)
`docker.com/products/docker-sandboxes/`. Docker ships agent sandboxes; the thread is a census of
what practitioners already run, and it is the densest isolation material in any of the three
surveys. The comment that lands hardest on this repo is `kstenerud` (yoloAI, already cited in the
2026-07 survey):

> One difference from your setup: **yoloAI copies your worktree instead of mounting it.** The agent
> works on the copy, you `yoloai diff`, and `yoloai apply` replays the commits into your real repo.
> **That's deliberate.** Docker's own security docs talk about the dangers of bombs being left
> behind in a live-mounted dir (git hooks, package.json scripts, Makefiles…).

`sparsesignal` runs a QEMU/KVM VM per project with nftables dropping anything aimed at the host,
the LAN or private addresses, and — the part worth stealing — **"it also ships a containment check
that scans outward from inside the guest, so the network boundary is something you can verify."**
`SwellJoe`'s `flar` uses `bubblewrap` with the system bind-mounted read-only and is "nearly instant
to start because it's just a namespace." `dist-epoch` prices the strategies: a VM per agent costs
~512MB RSS idle, LXC containers ~50MB, so they run one VM with many containers inside.
`AlotOfReading` asks the question that defeats simple permission models: "a bash tool that spawns
`cat` is different than one that spawns an ssh client."

**→ Lain.** `kstenerud`'s copy-not-mount is **independent confirmation of a hazard this repo
learned by losing a directory to it** (CLAUDE.md: a full-suite run from a copied linked worktree
deleted the copy, because `.git` was a pointer file to the original's admin dir). Two people now
arrive at "copy, diff, apply" from opposite directions. That strengthens the isolation-strategy
arms item (2026-08 #7) and sharpens it: the arms are `{linked worktree, hardlinked clone, copy +
replay, jj workspace}`, and the axes are setup cost, teardown safety, **handback correctness** and
now RSS, which `dist-epoch` shows differs by 10× across strategies.

`sparsesignal`'s containment check is the better idea and it is cheap: **a boundary you can assert
from the inside**. Lain has seam specs that drive real resources; an isolation seam that runs
*inside* the sandbox and tries to reach the host, the LAN and the parent repo — and fails the spec
if it succeeds — turns "isolated" from a claim into a test. That is the same move as
`spec/output_discipline_spec.rb`, applied to confinement.

`AlotOfReading`'s question is the case for the doctrine already written down: **tools are
capabilities, not permissions**. A `bash` tool that can spawn anything is one capability with
unbounded authority, and no classifier over its argument string fixes that. Worth citing in the
Tool-tier docs as the externally-stated version of the rule.

### Stealing reasoning traces from proprietary LLM APIs — id=49257876 (694pts, 306c)
`stolen-thoughts.com`. The attack, as `quantumgarbage` summarizes: encrypted chain-of-thought
blocks returned to clients **can be replayed across sessions, users and models**; take a trace from
a frontier model, replay it into a weaker sibling, jailbreak the sibling, and recover the stronger
model's hidden reasoning in plaintext — without attacking the strong model or tripping its
anti-distillation safeguards. `simonw` notes the obvious fix (per-model keys) and that the paper
reports all three providers have since blocked it. `glub` reports the same trick against Codex's
encrypted *compaction*, needing only a two-sentence injected developer prompt, and concludes:
"There's nothing unique in there and I still don't understand why they decided to encrypt it."

**→ Lain.** Direct continuation of the 2026-08 survey's §1.2 session-portability contract, and it
converts one clause from principle to demonstration: **encrypted reasoning blobs are a portability
cost that buys less confidentiality than claimed.** For the portability conformance check (2026-08
#2), this supplies a scored dimension with evidence behind it — a provider that returns opaque
blobs fails the "readable provider-neutral alternative" clause *and* turns out not to have secured
much. `glub`'s compaction result is the sharper one for this repo: if the compaction record is
worth encrypting to a vendor and contains nothing sensitive, then Lain's plan to store compaction
provenance in the snapshot event costs nothing and is strictly better than the shipping practice.

---

## 4. Local models, and the Ollama arm  (SCOPE: harness-evaluation, optimization)

### Muse Glimmer: 30B optimized for always-on local agent workflows — id=49241679 (1203pts, 633c)
`research.meta.ai/blog/introducing-muse-glimmer-open-agentic-model`. The top story of the window by
a wide margin, and the one with a direct experimental tie to this repo: **Muse Glimmer was
benchmarked locally on 2026-08-14** alongside `qwen3-coder:30b`, `qwen3.8:27b` and
`nemotron-3.5-lightning:30b` on the RX 7900 XTX. The thread supplies an external comparison point
from `jakswa`, running the unsloth GGUF on a **7900XT (20GB)** through llama.cpp/Vulkan:

> unsloth/Muse-Glimmer-30B-GGUF:UD-Q4_K_XL runs on my 7900XT barely… Sits at 19GB VRAM w/ 4
> parallel 113k context slots, all layers on GPU, and at **700 tok/s prompt, and ~36 tok/s
> generation**… edit2: I'm up to **~60 tok/s** on empty context with `--spec-type draft-dflash`.

Locally measured on the XTX through ollama: **34.7 tok/s decode** — within 4% of `jakswa`'s 36 on
a weaker card, which is the cross-check that makes the rest of their comment worth trusting.
`cmrdporcupine` confirms from the architecture side that it is **dense, not MoE**, which is exactly
what the local numbers show (34.7 tok/s against `qwen3-coder:30b`'s 119.3, same VRAM class).
`hypfer`, having used it: "I am fairly confident that it is not competing in the coding space…
its actual selling point appears to be a different take on guardrails and safety alignment," and
notes it is "very confident, regardless of whether it is actually correct." `andy99` reports the
opposite of the usual complaint — it is "much more efficient with its thinking" than Qwen, which
rehashes.

**→ Lain, and one item here is an application finding rather than a reading.** `jakswa`'s **700
tok/s prompt** against a first local measurement of 78 tok/s prompted a direct investigation, and
the gap was **ollama's default `num_batch=512`**: raising it to 2048 took `qwen3-coder:30b`
prefill from ~360 to **~2,200 tok/s, a 6× improvement from one option**, with decode unaffected
(it is bandwidth-bound per token). That is a configuration defect in the bench's own local arm —
every prefill number measured before it was describing ollama's default batching rather than the
GPU — and prefill is what a tool-call turn with a large context actually pays. It belongs in
`DEBUGGING_OLLAMA.md` next to the existing env-var notes. Beyond that:
- **Speculative decoding is an unexplored axis with a large reported effect.** `jakswa` gets
  36 → ~60 tok/s from `--spec-type draft-dflash`. If that transfers, the local arm's cost model
  changes materially, and it is a *harness-side* knob — which makes it a legitimate swept variable
  rather than a vendor number.
- **`hypfer` and `andy99` together argue for a thinking-token accounting.** "Confident regardless
  of correctness" and "more efficient with its thinking" are both statements about tokens spent
  before the answer, and neither is visible in a tok/s figure. The 2026-08 survey adopted
  Homebench's "tok/s has no honest denominator"; this is the same problem one level up — **cost
  per *useful* turn, not per token** — and the Journal already has the numbers to compute it.
- The `Aurornis`/`hypfer` disagreement about whether the model is any good at coding is exactly
  the kind of claim the bench exists to settle rather than repeat.

---

## 5. Evaluation, and a question that got answered  (SCOPE: harness-evaluation)

### What's the best programming language for coding agents? — id=49245936 (260pts, 188c)
`danluu.com/pl-tokens/`. The 2026-08 survey (§5.7) recorded this as "a genuinely open, runnable
experiment… and this repo is unusually well placed to run it, being Ruby and Rust in one tree."
It is now substantially answered, by `tadamcz` citing Epoch's **MirrorCode** (`epoch.ai/MirrorCode`):

> We studied this question pretty systematically… comparing **Python, C, Rust, Go, OCaml, and Ada
> across 19 very long-horizon tasks**, for Claude Opus 4.7 and GPT-5.5. > In our results, there was
> **little sign of inter-language differences in solve rates, for any model**… This suggests that
> AI models have learned generalized programming skills, rather than pattern-matching syntax…
> Conditional on solving a target, we found a **small effect on token usage** (Ada ~25% more than
> average).

`KingMob` generalizes the methodological point, and it is the durable one:

> considering a language's token efficiency is almost certainly incorrect, since it's only a local
> optima for input/output of the code. **Most session tokens are spent elsewhere**… If anyone
> remembers TOON… it was much more compact, but when researchers examined **whole-session
> effects, it was a wash**, because harnesses wasted more tokens than it saved dealing with it.

The thread's own theory, from `jillesvangurp`, `serf` and `SwellJoe`, is that what matters is not
tokens but **the verification loop**: statically typed compiled languages win because the compiler
is a fast, deterministic checker, and "LLMs like to produce a lot of JS and python that silently
fails in a graceful way." `eterm` supplies the fair methodological objection — MirrorCode agents
cannot download dependencies or search, and "it seems unnatural to air-gap them for evaluation."

**→ Lain.** Take the answer and retire the experiment in its original form: **language choice is
not a promising axis for solve rate**, and running a `{language} × {model} × {harness}` sweep to
rediscover a null result would be a poor use of the bench. What survives is better:
- **`KingMob`'s whole-session rule is a discipline, not an anecdote.** A local token win that
  loses at session scope is the same shape as the caveman-prompting replication (8–10%, not 65%)
  and the compaction break-even. Write it into `planning/specs/bench-science` as a standing rule:
  **no token-efficiency claim is admissible unless measured over a whole session.**
- **The real axis is verification-loop latency and strictness, not syntax.** That is swappable
  without changing language — test-first vs test-after, compiler-in-the-loop vs not, lint tiers —
  and it is measurable in one tree. It also converges with `lazarie`'s 95%-verification claim
  (§1.1) and with the static-verifier arm (2026-08 #14), which is three independent routes to the
  same experiment.
- **`eterm`'s objection is a fixture-design constraint** with a hygiene edge: air-gapped tasks
  measure recall, connected tasks measure search-and-integrate, and they are different skills.
  Declare which one a grader is measuring — and note this cuts against the 2026-08 fixture-hygiene
  item (#13) rather than with it, since network access is one more path by which an answer becomes
  reachable.

---

## What to do with this

Ordered by leverage. Numbers continue the 2026-08 file's list where they extend an existing item.

1. **Fix the local arm's prefill config, and record it** (§4.1) — `num_batch=2048` is a measured
   **6×** on prefill (~360 → ~2,200 tok/s, `qwen3-coder:30b`, RX 7900 XTX). Every earlier local
   prefill figure measured ollama's default batching. Belongs in `DEBUGGING_OLLAMA.md`. Done
   as of this survey; the note is what remains.
2. **Route only at cache-break boundaries** (§1.1, extends 2026-08 #4b) — compaction, TTL
   expiry and session resume are the moments a model switch costs nothing on the prefix term.
   A third arm the §7 arithmetic does not refute, and Lain can compute the predicate exactly.
3. **Name the training-affinity confound** (§2.1) — DeepSeek V4 is post-trained on DeepSeek
   Harness. A cross-harness A/B on such a model measures training match, with a sign that
   flatters the vendor. Add to `planning/specs/chunk-bench-science.md`. (**Correction 2026-08-18:**
   this line originally said "alongside the unmatched-effort rule" in that spec. There is no such
   rule there — the word "effort" does not occur in the file. The confound set is unwritten, which
   is why item 20 of the 2026-08-18 run proposes writing it.)
4. **Replicate the approval-fatigue curve against a published baseline** (§3.1, upgrades
   2026-08 #12) — 17% → 5% across ~50 prompts, n=1,053. The open question Anthropic left is
   whether batching or prompt rate flattens it, which is the arm that matters.
5. **Make the approval gate's input a declared projection** (§3.1) — prompts and tool_use blocks,
   never tool results, with a stated threat model. Testable: inject into a tool result, assert the
   verdict is unmoved.
6. **Assert containment from inside** (§3.2) — an isolation seam that runs in the sandbox and
   tries to reach the host, the LAN and the parent repo, failing if it succeeds. Turns "isolated"
   into a test, the way `output_discipline_spec.rb` did for stdout.
7. **Add copy-and-replay to the isolation arms, and price RSS** (§3.2, extends 2026-08 #7) —
   `{linked worktree, hardlinked clone, copy + replay, jj workspace}`, now with independent
   confirmation of the mounted-directory hazard this repo already paid for, and a 10× RSS spread
   between strategies.
8. **Whole-session rule for token-efficiency claims** (§5.1) — no such claim is admissible
   unless measured over a session. TOON, caveman prompting and language choice are three
   instances of the same error.
9. **Retire the language sweep; run the verification-loop sweep instead** (§5.1) — MirrorCode
   found no inter-language solve-rate difference across six languages and two models. What the
   thread actually argues for is checker latency and strictness, which is swappable in one tree.
10. **Compaction that preserves reach** (§1.2) — `simonw`'s request is the Timeline's demo:
    snapshot in the rendered prompt, full events still addressable and searchable. Composes with
    compaction provenance (2026-08 #6).
11. **Code-mode as a Toolset rendering arm** (§2.2) — `{JSON tool calls, code-mode block}`,
    grounded in `2402.01030` (CodeAct, already in the corpus) and now with a patent claim and a
    named implementation corpus around it. Executes out of process, per the placement rule.
12. **Speculative decoding on the local arm** (§4.1) — a reported 36 → ~60 tok/s from
    `--spec-type draft-dflash`. Harness-side knob, so a legitimate swept variable.
13. **Cost per useful turn, not per token** (§4.1) — thinking-token verbosity differs sharply
    between models and is invisible in tok/s. The Journal already holds what is needed.

See `SCOPE.md` for the questions these answer and `planning/` for where they slot.
`hn-agent-landscape-2026-07.md` and `hn-agent-landscape-2026-08.md` are the previous windows and
are not superseded by this file.
