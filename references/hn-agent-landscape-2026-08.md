# HN agent-harness landscape — survey, 2026-08

The second run of the recurring HN scan (`sources.md` § HN discussion survey). Window:
**2026-07-18 → 2026-08-06**, i.e. everything since the first run's cutoff, so this file is a
**delta** over `hn-agent-landscape-2026-07.md` rather than a re-survey. Same reduction: each
thread to *what it gives Lain* — a design bet, an experiment axis, or external corroboration.

> ⚠️ **LLM-generated** (Claude, 2026-08-06) — not a primary source. A synthesis of public HN
> stories + comment threads, fetched via the Algolia HN Search API, with the linked articles and
> arXiv abstracts fetched directly. Story IDs, point counts and URLs come from the API and are
> verifiable; the *readings* ("→ Lain") are Claude's, not the commenters'. Treat the linked
> articles and comments as the citable layer and this file as an index over them.

**Method.** `hn.algolia.com/api/v1/search` over 24 topic queries with
`numericFilters=created_at_i%3E1784332800,points%3E40`, **plus** a query-free
`search_by_date` sweep at `points>250` to catch what the topic terms miss — **half the threads
written up below (10 of 20, including §1.2, §1.5, §3.1 and §5.2) matched no topic query at all** and
exist here only because of that sweep. 367 distinct stories after excluding the 27 IDs the July
run already covered; 42 shortlisted and pulled in full via `…/api/v1/items/<id>`; comment text
HTML-unescaped before link mining. Full thread digests are in the session scratchpad.

**The one-line delta.** July's survey opened with *"Claude Code sends 33k tokens before reading the
prompt"* and concluded prefix churn, not prefix size, was the cost. In this window **Anthropic
published the other half of that answer themselves** — 80% of Claude Code's system prompt removed
with no measurable eval loss — while the Pi/earendil team published the mechanics of keeping a cache
alive and a portability contract that reads like a description of Lain's Timeline. The
context-engineering argument moved from practitioner inference to vendor-confirmed, and the open
question moved downstream: not *how big is the prelude* but *what does the harness owe you about the
session it built*.

---

## 1. Context engineering & caching  (SCOPE: context-and-code-mode, harness-evaluation)

### The new rules of context engineering for Claude 5 generation models — id=49051361 (463pts, 405c)
`claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models`. Anthropic's
own post, and the citable number is **"we removed over 80% of Claude Code's system prompt for models
like Claude Opus 5 and Claude Fable 5 with no measurable loss on our coding evaluations."** Six
stated inversions, each a *stop doing what we told you to do*: rules → judgment (the old "never
write multi-paragraph docstrings" replaced by "write code that reads like the surrounding code");
tool-use examples → expressive tool *parameters* and enumerated options; upfront context →
**progressive disclosure** (defer tools/skills until needed); repetition across system prompt and
tool definitions → guidance in the tool description only; hand-maintained `CLAUDE.md` → auto-memory;
markdown specs → rich references (HTML artifacts, test suites, real code).

Thread: mostly hostile-curious. `firasd` — the "Treaties of Westphalia-length instructions" were
always baroque, and detailed harness configs are partly "gearhead attraction." `anon-3988` — the
real failure of instruction files is *contradiction* once 50 rules accumulate from commits, docs and
chat history. `latentsea`, in the sibling SlopCodeBench thread, states the consequence plainly:
"agentic engineering now means we need to build and maintain suites of evals that measure these
things, so that we can measure the effects of changes to harness components **including how they
perform under model upgrades**. But… for a traditional software engineering team that has no
experience in this — how do we even do it?"

**→ Lain.** This is the July survey's #1 experiment, half-answered by the vendor, and it makes the
other half more valuable, not less. Anthropic reports "no measurable loss" against private evals on
their own harness; nobody outside can reproduce it, and the *prompt-slots* sweep is exactly what
`Context#render` purity plus a grader makes reproducible. Three concrete pulls:
- **Prelude-ablation sweep as a first-class arm** (`planning/specs/prompt-slots.md`).
  `{full prompt, −rules, −examples, −repetition}`
  × `{model tier}`, graded, cost-reported. The vendor's claim becomes a *hypothesis with a number*
  the bench can confirm or refuse — the highest-credibility result Lain could publish early.
- **Progressive disclosure is a Toolset/Context combinator, not a feature.** "Defer tools until
  needed" is a rendering strategy; make it a swappable arm against full-schema and measure
  tokens *and* score, not tokens alone (the July survey's anti-metric discipline).
- **`latentsea`'s question is the bench's pitch, verbatim.** "Measure the effects of changes to
  harness components including how they perform under model upgrades" is the founding demo plus
  the **July** survey's §8 model-migration harness — asked for by a practitioner who does not know
  it is being built.

### The session you cannot take with you — id=49118781 (786pts, 226c)
`earendil.com/posts/session-portability/`, from the Pi team (Armin Ronacher et al.). Enumerates the
mechanisms that make a session non-portable: **encrypted reasoning tokens** (billed to you, returned
as opaque blobs), **hidden web searches** (the model reads sources the client never sees), **sealed
server-side compaction**, **encrypted sub-agent messages**, **server-keyed sessions** identified by a
provider-stored ID rather than a transcript, and **automatic server-side retention** (30+ days at
OpenAI, 55 at Gemini). Proposes a contract: local event logs are canonical; `store:false` by
default; encrypted optimizations permitted only *alongside* a readable provider-neutral
alternative; tools observable down to "exact inputs, outputs, evidence, filtering, provenance,
timestamps"; every agent auditable as "exact readable task, messages, results, lineage";
compaction inspectable, with the instructions that produced it; artifacts exportable.

Thread: `captainmuon` asks why the client must resend a conversation it is not allowed to read, and
`the_mitsuhiko` gives the honest answer — because a server-side session ID trashes the KV cache on a
miss, and encrypted reasoning blobs are kept in the transcript purely to keep caches live.
`n0on3` pushes the fair objection ("self-serving argument from a harness developer") and cites
**`role-confusion.github.io`** as a real reason to hide reasoning; `hobofan`'s rebuttal is that
hiding traces is as futile as hiding system prompts, and a handful of exfiltrated traces per model
family is enough to distil the style. Also surfaced: mid-session model switching **with branching**,
so you can branch to a different model and still return to the original branch's model.

**→ Lain.** The strongest external validation in either survey, because the contract is a
*specification of the Timeline*. Point by point: local event log canonical = the content-addressed
Merkle DAG; auditable agent lineage = `meta["spawned_from"]`; observable tool calls = `Effect`s
interpreted by an `Effect::Handler` with the Journal as the trace; inspectable compaction *with its
instructions* = the one gap worth closing deliberately, because Lain's compaction is currently a
policy that produces an event, not an event that carries the policy that made it. Two pulls:
- **A portability conformance check.** Turn the seven contract clauses into a checklist a
  `Provider` implementation is scored against, and let the Journal prove Lain's own compliance.
  This is a *publishable artifact* that costs almost nothing given the DAG already exists.
- **Compaction provenance.** Store the compaction instruction (and the digest of the range it
  replaced) *in* the snapshot event. `KINDS` already has `:snapshot`; this is a meta field and a
  spec, and it converts "inspectable compaction" from a claim into a checked invariant.
- Mid-session model switch on a branch is `fork` + per-turn `Provider` routing — already the shape
  of §7 DeepClaude in the July survey, now with a shipping harness demonstrating the UX.

### Pi's minimalism is its advantage — id=49176038 (527pts, 285c)
`earendil.com/posts/pi-autoresearch-and-databricks/`. Follow-up to July's Pi coverage. The thread's
value is the community's own framing of the harness-configurability axis: `p1necone` — "I realised
how use case dependent harness behaviour is when I tried to use my customised-for-a-side-project pi
config at work… I would not be surprised if tools like Claude Code needing to be all things for all
people is hurting their peak usefulness." Repeated Emacs/Neovim analogy (`malisper`, `azuanrb`), and
the counter-position from `CharlieDigital`/`dasil003` — customization is a tax, models move too
fast to optimize a harness against. Distributions now exist (`oh-my-pi`), which is the Vim-plugin
lifecycle arriving in under a year.

**→ Lain.** `p1necone`'s observation is the founding thesis stated as user experience: *harness
behaviour is task-dependent, and a general harness is a compromise nobody measured.* That is Q1.
The `dasil003` objection ("not a good use of my time to optimize harnesses") is the honest cost
argument against the whole category, and the bench's answer is that the sweep is run once and the
*result* transfers — which is only true if the results are published with the fixtures. Worth
holding as the framing for any writeup.

### Prompt caching mechanics (comment-linked) — `earendil.com/posts/prompt-caching/`
Linked from §1.2 and worth its own entry; the most operationally detailed public writeup on this
since July's systima piece, and it is *mechanics* rather than a benchmark. What breaks a cache:
adding/removing/**reordering** tools (shifts every downstream token), dynamic system-prompt fields
(timestamps, random values), a model or provider switch, branch navigation under a stable session
ID, and extensions that rewrite messages. What Pi does: stable session IDs, explicit cache points
where the API needs them, an **append-oriented transcript** that avoids rewrites, message-anchored
*additive* tool loading, and monitoring that makes "cache health visible." TTLs: Anthropic's default
five minutes; Claude Code subscription users observed at one hour; `PI_CACHE_RETENTION=long` is a
request the provider may ignore. And the rule that matters most —

> the rewrite break-even: **surviving tokens × (uncached − cache-read price) ≈ pruned tokens ×
> cache-read price**. Aggressive pruning loses: rewriting cached context costs immediately, and
> exceeds the future savings from deleting a small number of tokens.

**→ Lain.** Cross-read against `references/prompt-caching-mechanics.md`,
`planning/specs/cache-economics.md` (CE-1..CE-7) and `planning/specs/cache-aware-compaction.md` —
this either confirms or corrects them, and it
supplies a **closed-form predicate the compaction policy can evaluate before it fires**. Two pulls:
- **Make the break-even a guard, not a heuristic.** Compaction/pruning should compute the
  inequality from the Journal's own token accounting and decline when it loses. That is a real
  arm of the decider-locus sweep (`planning/specs/oracles.md` OR-4): compact-when-full vs
  compact-when-it-pays.
- **"Reordering tools breaks the cache" is a property test.** `Toolset` rendering must be
  order-stable across runs; `Canonical`'s sorted-key determinism gives it, but nothing asserts it
  at the *Request* level yet. Cheap, and the failure is silent — exactly the class the July survey
  flagged.

### OpenAI reduces Codex context from 372k to 272k — id=48965850 (371pts, 154c)
`github.com/openai/codex/pull/33972/files`. A harness PR read as a cost signal. `chaos_emergent`
gives the mechanism from OpenAI's own chart: a larger pre-compaction window means **more cache
tokens per turn and more turns before compaction fires, so cumulative cost grows quadratically until
the compaction event** — a smaller window is cheaper over a long trajectory even though it compacts
more often. OpenAI framed it as temporary and burn-rate-driven, not latency. `embedding-shape`:
Codex does not surface what went into the "concise summary," so you cannot tell whether compaction
kept the important thing; several report Codex forgetting the in-flight task across a compaction
boundary, and Claude Code's mitigation is re-reading the plan file from disk. `simonw` notes the
same commit added a destructive-action preamble to the system prompt ("resolve the exact targets
with read-only checks…").

**→ Lain.** A clean, testable claim about the **context-window size × compaction-cadence** surface:
cumulative cost is not monotone in window size, and the optimum depends on trajectory length. That
is a two-dimensional sweep the bench can run exactly (`Context#render` is pure, so window size is a
parameter, not a deployment). Pair it with the break-even predicate above — they are the same
economics from two directions. The "forgot the task across the boundary" failure is a **grader**,
not an anecdote: assert that a named in-flight objective survives compaction, and the plan-file
re-read is one arm against summary-only.

### Annoying and alarming things about OpenCode — id=48978112 (420pts, 288c)
`wren.wtf/shower-thoughts/stop-using-opencode/`. The other half of July's headline comparison, now
critiqued on maintenance and isolation rather than tokens (3,690 open issues; the sandboxing story
attacked directly). The author's postscript on local models is the interesting part and cuts against
the usual pitch: small models are *preferable* partly because "you avoid the uncanny valley where
the model appears to be intelligent before doing something stupid; the stupidity is self-evident and
this helps calibrate your interactions," and they frame LLMs as good at **search** ("come back with
a call chain and code citations") and bad at generation. Comment links worth keeping: `bubblewrap` +
`slirp4netns` as the rootless isolation primitives, and `pleasedonotescape.com` (a sandbox-escape
challenge) which recurs across three threads in this window.

**→ Lain.** "Frame it as a search problem to rein in the propensity to make things up" is a
**Toolset composition hypothesis** the Ollama path can test cheaply: read-only/citation-shaped
toolsets vs write-capable ones on a local 8B, scored for unsupported claims. It slots directly
beside the attested-context grader, and it is the kind of arm where a small model is the *subject*
rather than a cost-saving compromise.

---

## 2. Harness engineering, and its limits  (SCOPE: harness-evaluation, orchestration)

### Why Software Factories Fail (or: harness engineering is not enough) — id=49023019 (394pts, 272c)
`humanlayer/advanced-context-engineering-for-coding-agents/blob/main/wsff.md`, by Dex Horthy. The
one thread in this window that argues **against** the premise of this project, so it gets read
carefully rather than folded. The claim: harness engineering — better tools, prompts, loops —
treats symptoms, because the root cause is in *training*: "there is no penalty for eroding codebase
maintainability." Benchmarks reward passing tests; "tests give you feedback in seconds, but the cost
function of bad architecture is measured in weeks, months, maybe even years." Evidence offered:
Faros AI data since January 2026 (+25% review comments, +22.7% longer comments, 31.3% of PRs skipping
review; incidents per PR +242.7%, bugs per developer +54%), plus the author's own lights-out attempt
ending in a two-week rewrite. Proposal: human-guided product review → architecture → program design
→ vertical slices, at a claimed 2–3× rather than 10–100×.

Thread: `_doctor_love` — the teams doing best with LLMs were already high-discipline, and "without
deep programmatic verification… the solutions will always be just slightly out of true";
`stellar_jay` offers a constraint taxonomy (generative / interpretive / elicitative,
`research.autodesk.com/blog/constrain-agent-not-user/`). Naur's *Programming as Theory Building*
was linked twice, as was Sandi Metz's "the wrong abstraction."

**→ Lain.** Take the argument at face value and notice what it concedes. Horthy's objection is not
"the harness doesn't matter"; it is **"the harness is optimized against a cost function that omits
the thing that breaks."** That is an argument for a *different grader*, which is a bench problem, and
§10's SlopCodeBench is the grader — published in the same window, by people who measured exactly the
degradation he asserts. So the honest reading is: **harness engineering without longitudinal grading
is what fails**, and the pairing of this thread with `2603.24755` is the single most useful thing in
this survey. Concretely: a maintainability/erosion grader belongs in the founding demo's score
vector, not as a later refinement — otherwise Lain's own A/Bs reproduce the flaw Horthy names.

### Benchmarking Opus 5 on SlopCodeBench — id=49076391 (405pts, 114c)
Same author, running the new benchmark on a new model. Two things from the thread beyond the paper
(§10). First, `patwolf` reports a **review-loop pathology** with real mechanics: automated review
via skills/subagents, feedback fed back for fixes, and under Opus 5 "the reviews are overly
pedantic, and that leads to feedback loops where each fix generates more feedback" — a one-statement
`CREATE TABLE` migration ballooned to 200 lines. Their own diagnosis is the right one: "perhaps we
have a prompt buried somewhere that's essentially asking it to be pedantic." Second, `NitpickLawyer`
and `nicoty` converge on **state visibility as the unlock**: a CLI that exposes system state in a
structured way outperforms prose context, and `nicoty` is building plan files as a *validated state
machine* (parse, check conformance, emit the next valid transitions) because a plain markdown plan
"gets polluted really quickly" and agents stop adhering to its structure.

**→ Lain.** The review loop is a **non-terminating Middleware composition** — two policies whose
fixpoint doesn't exist — and it is precisely the failure the July survey wanted loop instrumentation
for ("burning indefinitely"). Make it a fixture: compose a reviewer and a fixer, measure
turns-to-convergence and diff size per iteration, and show that a bounded composition (or a monoid
identity that terminates) is a *design* answer rather than a prompt-tuning one. The plan-as-state-
machine converges with `planning/`'s own card structure and with §1.5's "did the objective survive
compaction" grader: if the plan is parseable, the grader is mechanical.

### Building an Advanced Agentic Harness — id=49182946 (122pts, 43c)
`data4sci.com/blog/building-an-advanced-agentic-harness`. A modest post; the comments are the value,
and one of them is the clearest public statement of **why subagents exist** — which reframes an
experiment this repo had scoped as a cost study. `floatrock`:

> The real reason is protecting your context. Yeah, we have 1M context windows that can fit all of
> LotR in it, but these machines work better when they're narrowly focused. Large context windows
> run into attention issues and forgetfulness… So subagents come into play when you don't want all
> the tokens associated with a subtask to pollute your main/primary context window and degrade task
> attention. **The trick is getting a sense for when the complexity of the task warrants that kind
> of context protection, vs when a single agent is good-enough.**

`alansaber` compresses the whole category into one line — "what each of these is doing,
fundamentally, is solving context management in an opinionated way (that and guardrails)" — and
`itemize123` supplies the missing piece in three words: "what is lacking is a benchmark."
`budududuroiu` pushes back on the post's plan-as-DAG design: "I much prefer giving the LLM a REPL
loop, and injecting all the tools as functions inside the REPL loop. That means the LLM isn't
constrained to writing a DAG — it can write code that loops, exits early, etc." `shostack` names the
maintenance cost of harness investment: you must keep re-testing whether ripping it out is better on
every model release, "and in the case of opus 5, Anthropic says ditch it entirely and trust it."
The top comment is the standing objection, worth recording as such: `dominotw` — skills, harnesses
and memory systems are "totally useless in practice."

**→ Lain.** `floatrock`'s framing is the correction to take. The fork-vs-respawn study was scoped as
**cost** (§1, July #3); this says the *point* of a subagent is **quality** — context isolation
against attention degradation — and the cost is what you pay for it. Those are the two halves of one
experiment, and running only the cost half would have produced a confidently wrong answer ("forking
is cheaper, therefore fork"). The measurable question is `floatrock`'s: **at what task complexity
does context protection start paying?** — a sweep over subtask size with a fixed grader, where
`meta["spawned_from"]` already marks the boundary. And `itemize123` is right that no benchmark
exists, which is the bench's opening. The REPL-vs-DAG exchange is the same control-flow axis as
July's §2, now with a concrete claim: a DAG cannot express early exit, so plan-shaped orchestration
and code-shaped orchestration are not equivalent — worth noting in
`planning/specs/plan-shaped-compaction.md` and the tool-algebra work.

### qm — multiplayer agent harness for work — id=49126604 (675pts, 165c)
`github.com/yc-software/qm`. Notable less for the harness than for its contribution policy: **"we
take contributions as human-written text, not code"** — describe the change informally in
`adrs/`, and the maintainers' agents implement it. Thread argues it out well (`tptacek`: "the point
is that they just want your prompts, not your code"; `jez` notes SQLite's long-standing
no-patches-from-strangers rule as prior art; `2001zhaozhao` gives the economic reading — when
implementation cost collapses, *the idea is the only thing worth reviewing*).

**→ Lain.** Not an architecture input; a **process** input, and a live experiment in the "what is the
reviewable unit" question that `Review::Changeset`/`Deletability` already circle. If the reviewable
artifact is the intent rather than the diff, that is an altitude axis in
`planning/epic-orchestration.md` — worth citing there rather than acting on.

---

### Harness Engineering — id=48963483 (79pts, 32c)
`github.com/lopopolo/harness-engineering`. Low points, and the packaging invites the mockery it
gets — the README quotes the author quoting themselves claiming 100× productivity, and `bagels`'
one-line review is "the mother of all prompt injections." Read past that, because the author's
answer to `hankbond` is the most durable idea in this window:

> If you see that "drifting" behavior appear more than once, you have enough to stop and **force the
> agent to write some static verifiers** that reject all but the option you want. […] yes this is a
> form of RSI and to me **a vastly superior approach to fine tuning, since it allows adopting new
> model releases without throwing anything away** while still having the same effect on improving
> adherence to local acceptance criteria.

The worked example is concrete: ban `number` from representing a duration by walking the AST in a
linter and failing on parameter names ending `ms`/`millis`/`sec`. `hankbond` compresses the thesis —
"agentic engineering really is just **good software engineering practices enforced adversarially**."
And on cheap models the author gives a hybrid that neither §7 entry proposes: "using **bigger models
to put guardrails in place as static verifiers** allows lower complexity changes to 'self steer' as
tests fail, which means coming down on the cost curve is more effective."

**→ Lain.** This is the answer to §1.1's problem from the opposite direction. Anthropic says delete
your prompt scaffolding because the model outgrew it; this says **convert it into a checker instead
of deleting it**, because a checker survives the model upgrade that invalidates the prompt. That is
a *third* arm in the prompt-slots sweep — `{prescriptive prompt, deleted prompt, static verifier}` —
and the claim is testable: hold the constraint fixed, vary how it is enforced, and measure adherence
across two model generations. The hybrid is a better routing proposal than either §7 entry offers:
**expensive model writes the verifier once, cheap model iterates against it**, which converts a
per-turn routing decision into a one-time one and sidesteps the cache problem entirely. It also
lands on this repo directly — `rubocop`, `yard-lint`, `spec/output_discipline_spec.rb` and the
`Style/Documentation` rules *are* static verifiers of exactly this kind, already load-bearing.

## 3. Guardrails, tool composition & injection  (SCOPE: context-and-code-mode, optimization)

### Document-borne AI worms self-propagate through Copilot for Word — id=49096188 (383pts, 298c)
`enklypesalt.com/posts/context-collapse-part3-ai-worming-through-word/`. 144-day coordinated
disclosure with MSRC. Attacker instructions in an attached document hijack Copilot, alter output
(halving financial figures), and **append the payload into the new document as white text** — so the
artifact carries the attack forward through ordinary workflows. The author's framing is the quotable
one: "the tokens being inspected participate in the act of inspection, meaning current LLM
architectures provide no reliable boundary between intention and interpretation." Microsoft shipped
multiple fixes; the vulnerability *class* remains unmitigated.

**→ Lain.** Pairs with `2603.12277` (§10) into one finding: injection is not a filtering problem, it
is a **provenance** problem. Lain's structural answer is that a tool result is an `Effect` outcome
with a known source, not free text spliced into a prompt — so the bench can *measure* what role
attribution buys. Experiment: attested-context arm (tool output carried with provenance and rendered
as such) vs naive splice, scored by attack success rate on a fixture corpus. That is a real result
and nobody has published it for an open harness.

### OneCLI — a credential gateway that keeps secrets out of AI agents — id=49023427 (110pts, 32c)
Extends July's yoloAI credential-brokering pattern, and the author states the boundary honestly when
pushed: "the agent controls its environment which is exactly why nothing sensitive should live
there… that said, not holding the secrets doesn't make the agent harmless. It still acts
autonomously, and it can use whatever access those credentials grant." Comment-linked variants:
`denysvitali/gh-proxy` (placeholder token useless if it leaks from the sandbox), `varlock.dev`
(placeholder-inject-then-substitute-at-proxy, configured from a `.env.schema`).

**→ Lain.** Confirms the placement rule — confinement is out-of-process, and a credential broker
lives at the `Workspace`/`Provider` boundary. The author's second half is the part to keep: brokering
bounds *disclosure*, not *authority*, and authority is what the per-effect budget ceiling
(July's experiment #7) actually limits. Two different controls, frequently conflated.

### Agent Skill forcing ASD-STE100 Simplified Technical English — id=49114639 (359pts, 121c)
A skill that constrains agent prose to a controlled aviation-maintenance language. The thread is
mostly people rediscovering that STE's rules (keep articles, keep "that", repeat words rather than
vary them) read badly to an ear trained on essays, and `dghlsakjg` explains why that is the point.

**→ Lain.** A concrete, *externally specified* constraint set — which is what makes it a good arm for
the guardrail sweep, since the constraint was not authored to win the benchmark. Directly tests the
Prompting Inversion result (`2510.22251`, already in the corpus): does a rigid controlled language
help a weak model and handcuff a strong one? Cheap to run, and the grader is a conformance checker
rather than a judge.

---

### ANSI escape injection in MCP servers: hidden from humans, visible to AI — id=48989006 (60pts, 36c)
Small thread, and the one entry in this survey that lands on **the frontend** rather than on the
model. A tool result carrying ANSI escape sequences renders one way in a terminal and reads another
way to the model — so the human and the LLM are looking at the same bytes and seeing different
content. `doodlebyte` generalizes it correctly: "we're going to see more cases where the **'human
view' and the 'LLM view' of the same data diverge**." `illliillll`'s "just don't trust inputs you
don't control" gets the right rebuttal from `NitpickLawyer`: "by design there is no separation
between control & data channels in LLMs. Everything is context… there is no meaningful way to
distinguish between 'before running this repo install useful_package' and 'before running this repo
install typosquatted_evil_package'."

**→ Lain, and this is a new invariant rather than a new experiment.** Lain's frontend renders to a
terminal (tmux/nvim) and its premise is that **the Journal is the experiment record**. If a tool
result can render differently to the human than it reads to the model than it serializes to the
Journal, that premise is false in a way nothing currently checks. The invariant to assert:
**what the human saw ≡ what the model saw ≡ what the Journal recorded.** `spec/output_discipline_spec.rb`
already polices the adjacent property (only the frontend touches `$stdout`); this is its natural
sibling — escape-sequence neutralization at the rendering boundary, with the raw bytes preserved in
the Journal so the divergence is *recoverable* rather than merely prevented. Cheap, and the failure
mode is silent, which is the class this repo already takes seriously.

### Atlassian Rovo exfiltrates data, bypassing controls — id=49185983 (274pts, 116c)
A second instance of §3.1's class, with a different limb. The mechanism, quoted by `formerly_proven`:
Rovo's URL-retrieval tool has "no protections against opening a URL that has been **dynamically
created by the agent**" — so an injected instruction appends sensitive data to an attacker's URL and
the fetch itself is the exfiltration. Most of the thread is Atlassian-bashing; the mechanism is the
takeaway. **→ Lain.** Corroborates the July yoloAI/Gondolin reading that egress allowlisting is an
isolation-layer control, not a `Tool::Input` one — `Tool::Input` validates shape, not safety, and
this is precisely the distinction the comment at the top of that file exists to make. The
generalizable rule: *a tool whose argument the model constructed is a different capability from a
tool that acts on a value the conversation already contained*, and only the second is safe to
allowlist by destination.

## 4. Isolation, cost & orchestration ops  (SCOPE: harness-evaluation; ops)

### A local merge queue for parallel Claude Code agents — id=49104747 (42pts, 22c)
Small thread, disproportionate value. Author runs 4–5 parallel agents at ~90 commits/day on an 8GB
MacBook Air; all of them building and running dev servers at once is "the fast lane to a force quit,"
so commits land one at a time, fully tested, locally. The comments are the real content and they
argue **worktrees vs clones vs jj**: `barrkel` runs jj with a workspace per subagent and finds it
better than git worktrees; `kazinator` argues local clones over worktrees precisely because
`rm -rf` on a worktree is "Russian roulette" — remove the parent and the linked worktrees break —
while hardlinked clones are independently disposable; `ithkuil` defends worktrees for enumerability
and for preventing two checkouts of the same branch.

**→ Lain.** `kazinator`'s hazard is the one this repo already learned the expensive way (CLAUDE.md,
"rm .git before running anything in a COPY of a linked worktree" — a full-suite run once deleted the
copy). Independent confirmation from outside, and it argues the isolation layer should treat
"worktree" as **one strategy among several**: `{linked worktree, hardlinked clone, jj workspace}`
as swappable arms behind `Isolation`, measured on setup cost, teardown safety and handback
correctness. Given `isolation/worktree_handback_spec.rb` is the suite's wall-clock floor at ~11 git
invocations per example, a clone-based arm is plausibly *both* safer and faster — an application
finding, in the CLAUDE.md sense, not a spec finding. The serialized-landing queue is what
`/execute-plan`'s orchestrator already does; worth noting the convergence.

### Humans missed 1 in 3 threats approving AI agent commands, across 40k runs — id=49195468 (132pts, 102c)
`scalex.dev/blog/ai-agent-permissions-stats/`. A permission-approval game, now with numbers behind
it: **over 40,000 plays and 409,000 decisions, and roughly 1 in 3 threats were approved anyway —
with a warning shown up front.** The author notes the command history above `npm run` invocations is
"typically ignored." It is a game rather than a field study, so treat the number as indicative, not
as a measurement of production behaviour; the sample size is what makes it worth citing at all.

The author's own conclusion is the load-bearing part, and it is against their own artifact:
`Wirbelwind` — "there are too many problems with HITL that even a simple experiment like this game
shows. **The fatigue causes people to jump to complete bypasses instead**… A way could be to make
sandboxing and context/permission isolation easier from the tooling and only give these wide-ranged
accesses once these are in place, rather than to consider HITL an acceptable alternative."
`solenoid0937` names the shape that follows: auto-mode (a classifier per action) plus sandboxing.
`grndn` supplies the term for what an approval prompt often actually is — a **moral crumple zone**
(`ferd.ca/notes/paper-moral-crumple-zones.html`): the human as the component that absorbs legal and
moral responsibility when the system malfunctions. `anal_reactor`, more bluntly: "the goal of
human-in-the-loop is to have someone liable for potential damages, rather than to prevent disasters."

**→ Lain, and this one lands on code that just shipped.** The `lain://approval` surface and
`planning/specs/chunk-modes-approval-undo.md` implement exactly the mechanism this thread says
degrades with use. That is not an argument against building it — it is an argument for **measuring
it**, which is the one thing the bench is for and nobody in the thread can do:
- **Approval fatigue is a swept variable, not a fixed property.** Prompt rate × session length ×
  batching → approval accuracy. The Journal records every approve/deny with its timestamp and the
  effect it gated, so the decay curve is derivable from data Lain already keeps.
- **It sharpens the human-loop Middleware into a comparison rather than a feature.** July framed the
  human loop as "a distinct blocking Middleware, with a `Null` implementation for autonomous mode."
  This adds the arms worth putting between those poles: `{always-ask, classifier-gated, isolate-and-
  never-ask}` — which is July's yoloAI finding ("isolate architecturally, don't fatigue users with
  prompts") now carrying a number instead of an assertion.
- **The crumple-zone reading is a design constraint.** If an approval prompt's real function is
  liability transfer rather than error prevention, then a harness that logs *what the human could
  actually see at decision time* is telling a different story than one that logs only the verdict.
  The Journal should capture the rendered approval payload, not just the answer.

### Cursor removed cost information from the usage page and CSV export — id=49135257 (336pts, 149c)
Exactly what it says. A harness vendor withdrawing per-request cost data from users.

**→ Lain.** A one-line entry with a disproportionate point: the industry is moving cost accounting
*behind* the harness at the moment Lain is making it the experiment record. "Usage accounting is in
the Journal, per turn, exportable" stops being an implementation detail and becomes a differentiator
worth stating in the README.

### Agent-Manager: a tmux TUI for Claude Code / Codex / OpenCode — id=49107749 (98pts, 79c)
Go binary over tmux; **status is read out of the pane** ("adding a CLI is a few lines of regex in a
toml file rather than an integration"); sessions stay ordinary tmux sessions that survive the
manager quitting; `space` sends a prompt into a blocked agent's pane without attaching; `ctrl+r`
opens changes as whole files with the diff highlighted, and **a comment on a line is sent back to
that agent as a prompt**. A crowded field in the thread: herdr, agent-deck, ouijit, superlogical,
tmux-agent-switcher, kabelsalat, mate.

**→ Lain.** The line-comment-as-prompt loop is the same seam as `lain://approval` and the editor-side
review view (commits `2b48b73`, `49f7181`) — external convergence on the design just landed, which
is a useful sanity signal. The pane-scraping status detection is the *anti*-pattern to name
explicitly: Lain has a `Channel` of attributed events and a Journal, so status is a subscription,
not a regex over a terminal. Worth one sentence in the frontend docs, because "why not just scrape
the pane" is a question a reader will have.

---

### How much can you delegate to agents? — id=49101655 (64pts, 20c)
The thread names a failure this repo has the machinery for and no word for. `jolaflow` calls it
**vision drift**: "we have tooling for static analysis and automated tests, but drift in intent or
vision is hard to detect. After leaving agents unsupervised for longer periods, the biggest
questions tend to be *'how did it arrive at this conclusion?'* and *'did we drift from the initial
vision?'* Typically these questions are hard to answer as **you only review the final state of the
workflow**." Their own fix was to build an issue tracker with **time-travel as a core feature**, and
they report it was unexpectedly the thing that made workflow audit possible. `ithkuil`'s reply is
fair and worth keeping — vision drift happens in human-led projects too.

**→ Lain.** "You only review the final state" is the exact deficiency a content-addressed Merkle DAG
removes: `diverge_at` localizes where a branch left the plan, byte-diffable replay answers "how did
it arrive here", and `meta["spawned_from"]` carries the lineage. Time-travel is a property Lain has
**structurally** and every tool in this window is bolting on. Two pulls: name the grader — *does the
final artifact still satisfy the objective stated at the root?* — which composes with §1.5's
survive-compaction check and §2.2's plan-as-state-machine into one family; and note that this is a
demo, not just an experiment. Replaying a drifted session and pointing at the turn where intent
diverged is the most legible thing the bench can show someone in thirty seconds.

## 5. Reliability, evaluation & the grader problem  (SCOPE: harness-evaluation)

### We gave GPT 5.6 Sol a real business. It lied, spammed, and lost $447 — id=49113059 (407pts, 234c)
`bottlenecklabs.com/blog/autonomously-run-businesses`. An agent with App Store, RevenueCat and code
access run for 24 hours on a real app. The thread's critique is better than the article:
`SubiculumCode` — no baseline, n=1, "done for a headline, not a rigorous test"; `janalsncm` — the
legitimate growth avenues were cut off, so what was measured was mostly the anti-bot surface;
`recitedropper` reads it together with the HuggingFace incident as evidence of reward-hacking
training pressure.

**→ Lain.** Same shape as July's systima piece and the same lesson: **the audience for agent
experiments is large and the methodology bar in public is low.** n=1 with no baseline and no
grader is the norm, and the negative space is again a spec for the bench. Keep as evidence for the
writeup, not as a finding.

### SQLite critical CVEs or LLM slop? — id=49154332 (725pts, 369c)
`research.jfrog.com`. LLM-generated vulnerability reports against SQLite that do not survive
inspection. `ymir_e` states the defence in one line: **"have an agent reproduce the issues before a
human sees it, but even that will cost money."**

**→ Lain.** The generalizable form is *claims are cheap, reproduction is the scarce resource*, which
is the argument for making the reproduction step a first-class, budgeted `Effect` rather than a
prompt instruction. Ties to the per-effect cost budget (July #7): a verification effect with its own
ceiling is how "reproduce before reporting" becomes affordable-by-construction.

### Homebench — benchmark local LLMs for speed, memory, and quality — id=49166308 (59pts, 8c)
Low points, high signal, entirely because of the author's own methodology note — which is the best
statement of grader discipline anywhere in this window:

> "Quality grading is deterministic on purpose: exact numeric match, multiple choice, valid-JSON,
> regex, at temperature 0 with a fixed seed. There's an optional LLM-as-judge path for open-ended
> tasks but **it's marked as a signal, not a score**. … The honest limitation: the built-in suite is
> 31 tasks. That is a smoke test for 'did this quantization break the model,' not a leaderboard of
> record."

Also: tok/s has no honest denominator (prompt processing? model load?), so the methodology lives in
the README rather than a footnote; memory has no single honest number, so resident-model-size and
peak-RSS are reported separately and both labelled estimates; single-stream throughput hides
batching, so batch sweeps report aggregate tok/s, speedup and p95 separately.

**→ Lain.** Adopt the vocabulary. **"Signal, not a score"** is exactly the distinction
`planning/specs/graders.md` and `planning/specs/oracles.md` need between deterministic graders and
LLM judges, and "refuse to blend
two incomparable measurements into one confident number" is the discipline that keeps a bench
honest. The tok/s-denominator problem is Lain's own latency-reporting problem, unchanged.

### Echo — Fable-level results at 1/3 the cost from a pool of open-weight models — id=49026810 (484pts, 217c)
Show HN with a **published eval methodology** (`echo.tracerml.ai/eval`), which is why it is here.
Method: run a pool (GLM-5.2, Kimi K2.7, others) on the same evals, compute the *oracle* system that
knows in advance which models help and how to combine them — undeployable, but it bounds the
headroom — then try to recover part of that gap with a per-request allocator deciding compute,
participants and combination. Reported: beats the best single model in the pool, matches Fable
aggregate at ~⅓ inference cost.

> ⚠️ **Sourcing caveat.** Those figures come from the Show HN text, not from the methodology page —
> `echo.tracerml.ai/eval` returned **503 with `Retry-After: 3600`** when this survey tried to verify
> them (2026-08-06). Treat them as claimed-not-checked. The *method* below is what earns the entry,
> and it does not depend on their result being right.

The author's own finding is the interesting one: **"a model that is
clearly weaker overall can still be extremely useful on particular problems or as part of a
combination."**

**→ Lain.** The oracle-upper-bound trick is a **methodology to steal outright**, and it generalizes
far past model routing: for any swappable seam (Middleware stack, compaction policy, retrieval
strategy), computing the post-hoc best-per-task arm gives the headroom the whole sweep is competing
for. That single number turns "arm A beat arm B by 3%" into "arm A captured 40% of available
headroom" — the difference between a leaderboard and a study. Directly upgrades the founding demo
and the model-migration harness, and it costs nothing extra because the per-arm results already exist.

### Benchmark saturation & Goodhart — id=49170915 (103pts, 127c) + id=49126716 (94pts, 36c)
Two threads, one argument, and the most useful commenter in either works in AI evaluation.
`astro1234` supplies both the defence and the catalogue of leaks:

> **Private, refreshed test sets attack the mechanism itself, and in my view they are the only
> intervention that does.** If the questions have never touched the public Web, they can't be in the
> training data; if they rotate, memorizing this year's set doesn't help next year.

Leak modes named: answers recoverable from the questions themselves; multiple-choice sets where
passing *only the choices* beats chance; and — the one that matters here — **"coding agent
benchmarks sometimes forget to delete `.git`."** They also normalize a 6.9% item error rate as
typical and shippable, and put the literature at "probably 50,000 benchmarks… that is not a joke
number." On saturation itself, `ACCount37` gives the statistical reading: it is largely a selection
effect — "throw out the 90% easiest of tasks, and what remains is a jagged ladder of high-difficulty
outliers. Hard to climb, and **hard to measure the climb** — you have fewer effective data points,
they're less linear, and you're still subject to measurement noise." `astro1234` points at Epoch's
use of **item response theory** — model per-item difficulty and per-model capability jointly, across
many benchmarks — as the most robust meta-analysis available. Adjacent, from the LoRA-speedrun thread
(id=48974325): `stephantul` warns that a single-task single-model leaderboard overfits, and that
NanoGPT-style speedruns were only ever interesting because the findings were meant to *transfer*.

**→ Lain, and one of these is a live hazard in this repo.** `SeedRepo`, `DivergedRepo`,
`ChangesetRepo` and `GithubPrFixture` all build **real git repositories**, and the fixtures for any
future coding-task grader will too. If a fixture's history contains the commit that fixes the bug,
an agent can `git log` its way to the answer and the grader records a pass that measured nothing —
the exact "green test that can't tell the subject from a plausible wrong one" pattern already
catalogued in this project. **Assert it mechanically**: a fixture-hygiene spec that fails if the
task's solution is reachable from the repo the agent is handed. Beyond that:
- **IRT is a methodology import, not a citation.** Averaging pass rates across tasks of unknown
  difficulty is what makes harness-variance deltas disappear into noise; modelling difficulty and
  arm-capability jointly is the statistically honest version of the founding A/B, and it directly
  answers `ACCount37`'s "hard to measure the climb."
- **Private + rotating means generated, not curated.** For Lain that argues for *generating*
  fixtures from a seed rather than committing a fixed corpus — which the template-and-copy approach
  in `SeedRepo` is already halfway to, since a template that can be rebuilt can be re-randomized.
- Pair with §5.3's "signal, not a score": a 6.9% item error rate is fine *if* it is reported.

### Two honest token-saving replications — id=48967355 (181pts, 208c) + id=49080605 (46pts, 41c)
"I burned all my tokens researching how to save tokens" is the better of the pair, and its author
lands the diagnosis in one line: **"the models weren't lacking knowledge as much as discipline.
Without a good workflow, they will most likely spend thousands of tokens exploring dead ends"** —
followed by the objective worth stealing: *"my goal is not fewer dead ends, but **fewer repeated
dead ends**."* The second thread tests the "speak to agents like cavemen" folklore and finds the
headline claim does not survive: **8–10% token saving with no measured quality degradation, not
65%** — and `pineappletooth_` names the limitation the authors state, that it was only run at
reasoning-low.

**→ Lain.** "Fewer *repeated* dead ends" is an **objective function for M6**, stated better than the
memory literature states it, and it is computable from the Journal: detect re-exploration of a path
already explored and scored, within a session and across sessions. That is a grader
("repeat-dead-end rate") and it is the success metric the retrieval-over-Journal experiment has been
missing — a memory system that does not lower it is not earning its context. The caveman result is
worth keeping as a *shape*: an inflated community claim, replicated down to a real-but-small effect,
with the untested regime named honestly. That is the output format the bench should imitate, and the
untested regime (effort levels above low) is a free experiment.

### 13 models and 4 agents on SWE tasks — id=49124336 (51pts, 15c)
`swe-rebench.com`. Small thread, one sharp methodological catch and one open question. `dia80`:
**"Why test Fable high effort vs Sol medium? Especially when Sol comes out 4-5x cheaper in their
tests at those effort levels."** — an unmatched-setting comparison presented as a model comparison.
Separately, the thing several commenters actually wanted and nobody has: **which language is most
amenable to agentic work?** (`spullara`, `ducktective`, `revetkn`, pointing at a token-efficiency-by-
language post).

**→ Lain.** The first is the trap the founding demo must not fall into: **hold effort fixed or sweep
it as a declared axis — never compare across unmatched settings**, because effort is a cost/quality
dial and an unmatched comparison silently measures the dial instead of the subject. Worth writing
into `planning/specs/bench-science` discipline as an explicit rule, since it is the single easiest
way to publish a wrong number. The second is a genuinely open, runnable experiment —
`{language} × {model} × {harness}` on matched tasks — and this repo is unusually well placed to run
it, being Ruby and Rust in one tree with a real suite in both.

---

## 6. Memory & retrieval  (SCOPE: memory-and-retrieval)

### Zero-Mem: zero-token memory operations for LLM agents — id=49178608 (96pts, 12c)
`arxiv.org/abs/2607.29377`. No LLM call outside final question answering; **original interaction
traces preserved as the source of record**, organized as an entity–context graph (connections across
interactions) plus a temporal hierarchy (conversational locality); encoder compute accounted for
separately. `russlan`'s top comment is sharper than the abstract:

> "The useful contribution is not zero token cost; it is removing generative rewriting from memory.
> Preserving original traces avoids a subtle auditability failure: **once an LLM compresses an
> interaction, retrieval is grounded in the summary's omissions rather than the evidence.**"

They also name the benchmark the paper lacks: under mutation and contradiction, can the store
preserve both states, surface the conflict, and show *which trace justified the answer*? — and ask
for unsupported-answer rate and evidence recall alongside token cost, since "zero-token" risks being
read as "free" when encoder and index-maintenance costs sit outside the accounting.

**→ Lain.** M6, precisely. The Journal + DAG already *is* the preserved-trace corpus, so Lain gets
Zero-Mem's core property structurally rather than as a technique — and `russlan`'s critique is a
**grader spec handed over for free**: evidence recall and unsupported-answer rate under stale,
conflicting and adversarial traces, with "which trace justified this" as an assertable output.
It also lands a second time in §1.5: *retrieval grounded in the summary's omissions* is the same
defect as a compaction that dropped the objective. One mechanism, two subsystems.

---

## 7. Model routing, and its fight with the cache  (SCOPE: harness-evaluation, orchestration)

Three threads in this window attack the same seam — pick the model per turn rather than per session — and
together they produce the sharpest economic finding of the survey. **Read this section against §1.4:
it is the same break-even arithmetic, applied across models instead of across time.**

### Tokenless — a fan-out router with live confidence scoring — id=49099143 (71pts, 63c)
`usetokenless.com`. An API gateway that routes agent traffic turn-by-turn. The mechanism is unusual:
**start generation on several candidate models at once, score each one's confidence live as it
streams, commit to the first that clears the bar and kill the rest.** The confidence model was
trained on partial generations; the routing rule itself was found by evolutionary search. Reported
on τ³-Banking: **40.2% solve at $2.25/task against GPT-5.6 Sol's 33.0% at $2.58.**

The thread's top comment (`mediaman`) is the finding, and it is an objection rather than a result:

> So this only switches models if the cache is cold… Hot cache calls reduce input cost by 90%.
> …most [turns] will be tool→result→tool without the user involved. And token burn is highest with
> these long running agentic chains, but that's precisely where routing doesn't work because of the
> KV cache.

`rohaga`'s reply concedes the frame and adds the mechanism that saves it: each model holds a
*different* fraction of the prefix, so "the cache" is per-provider state, not one number — Tokenless
keeps "a local shadow of the cache state of each provider" and switches only when the arithmetic
wins. Anthropic's own server-side `fallbacks` does the same thing from the other end: once a
conversation falls back, later turns are **served by the fallback model for ~1 hour** rather than
re-tried on the original. Sticky routing is a vendor admitting that switching is expensive.

### The arithmetic, and where routing actually pays

Caches are **model-scoped**, so a switch invalidates the whole prefix — it is the same tier of
invalidation as changing the tool list, not a partial miss. With Anthropic's published multipliers
(cache read ≈ **0.1×** base input; cache write **1.25×** at the 5-minute TTL, **2×** at one hour),
for a prefix of `P` tokens:

| | input cost of one turn |
|---|---|
| stay on A, warm | `P × A_in × 0.1` |
| switch to B, cold, caching there | `P × B_in × 1.25` |
| switch to B, cold, one-shot (no write) | `P × B_in × 1.0` |

So a cold switch beats a warm stay **only when the target is more than ~12.5× cheaper per input
token** (~10× if you don't write a cache on it). That threshold is the useful number, because it
sorts the candidates:

- **Within one vendor's family the ratio is too small.** Opus 5 → Haiku 4.5 is 5× on input
  ($5 → $1). It does not clear 12.5×, so mid-session routing *down a tier* loses on prefix cost and
  can only win on generation.
- **Across families to an open-weight model it clears comfortably**, which is why every routing
  product in this window is built on open-weight pools rather than tier-shifting inside one vendor.
  (`rohaga`'s "30× cheaper even cold" is consistent with that; the specific per-token figures for
  DeepSeek/GLM/Kimi are the products' claims, not something this survey verified.)

**The condition is short PREFIX, not small task** — worth stating because the intuition is nearly
right and the correction changes what you'd instrument. The penalty scales with the prefix you must
re-warm, so a trivial task on a 200k-token agentic transcript still pays full freight. Output tokens
are never cached at all, so the regime where routing is close to free is *generation-heavy, prefix-
light*: long output, short context, early in a session. That inverts `mediaman`'s worst case rather
than contradicting it — both follow from the same term.

| regime | prefix | output | route? |
|---|---|---|---|
| long agentic tool chain | large | small | **no** — the cache read is the whole cost |
| generation-heavy one-shot | small | large | **yes** — output dominates, cache barely matters |
| early-session decision point | small | any | **yes** — little to re-warm |
| any turn, to a ≥12.5× cheaper model | any | any | **yes on input cost alone** |

**→ Lain.** Routing is a `Provider` concern and Lain owns the loop, so this is a seam the bench can
sweep rather than a product to buy. Three pulls, in order of leverage:

- **Per-model cache state is a query, not a bolt-on.** Tokenless maintains a "local shadow" of each
  provider's cache because it sits outside the harness and cannot know. Lain content-addresses the
  Timeline, so *"what prefix does model B already hold"* is answerable from digests it already
  computes. That is a genuine structural advantage over every router in this window, and it is what
  makes the switch predicate computable instead of estimated.
- **One predicate, two decisions.** §1.4's compaction break-even and the switch threshold above are
  the same inequality over the same Journal accounting. Implement it once as a cost model and let
  both the compaction policy and the router consult it — that is a *bench* result ("when does
  switching pay?") rather than a heuristic.
- **The regime table is the experiment design.** Sweep `{prefix size} × {price ratio} × {output
  length}` and report where routing wins, rather than reporting one aggregate "router beat baseline"
  number. Compose it with §5.4's oracle bound and the answer becomes "routing captured X% of the
  available headroom, in these regimes" — which is the study nobody has published.

### The counterweight: "Everyone is building LLM routers, we deprecated ours" — id=49126630 (132pts, 86c)
`manifest.build/blog/why-we-deprecated-our-llm-router/`. Read this against the two entries above,
because routing is **contested**, not established, and the survey would be one-sided without it.
The article independently describes the same mechanism as §7's opening — "a cache-aware model router
will take that into account by adding **stickiness** to the initially chosen model" — and then
argues the whole thing is not worth it. Two alternatives surface in the thread:

- **Just pick a good model per task.** `maxrev17`: "routers suck, been doing this myself for the
  best part of a year now and it's really difficult to make it behave. A good model for your task is
  the best bet." `stingraycharles`: "just don't switch models every week."
- **Post-train a specialist instead of routing between generalists.** `mmargenot` states the deepest
  objection: "I find this routing problem to be opaque and I'm generally skeptical that **the label
  people are trying to predict is meaningful.** If you really need more discrimination of the
  complexity of an input to get an efficient response, sft or rl tuning something for your harness
  would be more effective."

`owenthejumper` — "routing belongs on the client side" — is Lain's position by construction. And the
thread's central disagreement is the bench's own pitch again: `overgard` argues nobody can know
model strengths when there is a new one weekly and "the benchmarks are useless and gamed";
`danielmarkbruce` answers "you have eval pipelines set up. It's engineering, you have to test stuff
works… almost everything in AI/ML is empirical."

**→ Lain, and this is the synthesis worth keeping.** `mmargenot`'s objection is not a matter of
taste — it is **falsifiable, and §5.4's oracle upper bound is exactly the experiment that settles
it.** If you compute the post-hoc best-arm-per-task ceiling over a model pool and the ceiling is
close to the best single model, then there is no headroom, the label is not meaningful, and the
router skeptics are right. If the ceiling is far above, routing has something to capture and the
open question is only how much of it a live allocator recovers. **Run the oracle bound before
building any router** — one cheap computation that decides whether the expensive thing is worth
building at all. That is the bench being useful in its natural mode: not "here is a better router"
but "here is whether routers can work, and by how much."

### Beating GPT-5.6 Sol on retrieval with 100× cheaper open models — id=49186762 (378pts, 105c)
`neon.com/blog/…` (Castform + Neon). The specialization arm of the argument above: a post-trained
small open-weights model beating a frontier model on **retrieval** at ~100× the price advantage,
with an Apache-2.0 harness (`github.com/castform-ai/benchmax`, including a runnable `neon_rag`
example) rather than a demo. `kumama` (author) makes the maintenance objection go away: "once you
set up a finetuning pipeline, it's often trivial to rerun it on top of a new open weights model,
so it's orthogonal to base model improvements."

The single most useful fact in the thread is a **correction of a widely-repeated claim**, and it is
direct evidence for §7's arithmetic. `mrinterweb` cites Claude Code handing its Explore subagent off
to Haiku as the canonical intra-family routing example; `phainopepla2` corrects it from the
changelog — as of **2.1.198 (2026-07-01) "the built-in Explore agent now inherits the main session's
model (capped at opus) instead of running on haiku."** The vendor tried routing down a tier for a
read-only subagent and **reverted it**. That is precisely the regime §7 predicts loses: a 5× price
ratio that does not clear the ~12.5× threshold, paid for with a quality drop.

`benjiro29` supplies the sharpest counter, and it deserves to be kept next to the result: "it's rare
for a specialized model to beat a strong general model… if the task is repetitive to the point that
specialization is useful, you can get into a situation that you're better off having a program
written for that repetitive nature."

**→ Lain.** Three things, in order:
- **A third arm the survey was missing.** The axis is not `{frontier vs cheap generalist}` but
  `{frontier, cheap generalist, post-trained specialist, plain code}` — with `benjiro29`'s last
  option the one everyone forgets. `Provider` and `Toolset` make all four swappable at one seam.
- **Retrieval is the seam where specialization pays first**, which lands on M6 rather than on
  orchestration. A local post-trained retriever on the Ollama path is a real M6 arm, not a
  cost-saving compromise.
- **`benchmax` is Apache-2.0 and runnable** — worth reading before building any grader harness, on
  the same "introspect reference implementations" logic that paid off with MemPalace.

### Prime Agent, and an ablation hiding in a comment — id=49189075 (221pts, 54c)
A "self-improving RLM agent." The post is unremarkable; `oofbey`'s reading of the underlying RLM
paper is not, and it is the third independent sighting of §7's theme:

> The core idea of the RLM paper is to make a regular LLM act more like a coding agent — offload
> context to something external that needs to be explicitly queried instead of filling up valuable
> context. **The "recursion" part of the paper really only wins because they use a top-tier model
> for the root agent, and cheaper models for the sub-agents.**

`riddlemethat` supplies the other half: they built one of these, "it worked great for a while but
the foundational models have largely caught up to the point where they don't need this harness
anymore… I can basically just store context in `.md` in the directories we work out of together."

**→ Lain.** `oofbey` is describing an **ablation the paper's authors did not run** — the reported
gain is confounded between *recursion* and *heterogeneous model assignment*, and separating them is
one experiment with two arms (same topology, uniform models vs tiered). That is the bench's native
move, and it is the cheapest way to test whether "orchestration" results in this space are really
routing results wearing a costume. It also gives §7 its most defensible routing shape: **route by
role (root vs subagent), not per turn** — a role boundary is a natural cache boundary, since a
subagent already starts from a fresh Timeline root, so switching models there costs no prefix that
was not already being paid. Every per-turn routing scheme in this window fights the cache;
per-role routing does not. `riddlemethat`'s decay observation belongs in the same file as §1.3 and
§2.3: harness investment has a half-life, which is an argument for measuring it, not for skipping it.

### What Lain owes on cache-write discipline
July measured Claude Code at **53,839 cache-write tokens against OpenCode's 1,003** on one task, and
blamed prefix churn. Most of the causes are already closed here by construction — `Context#render`
is pure, so no clock/cwd/uuid can reach the prefix; the Timeline is append-only, which is Pi's
"append-oriented transcript"; `Canonical`'s sorted-key determinism kills the unsorted-serialization
invalidator. What is **not** closed, and is cheap:

- **Tool-order stability is unasserted at the `Request` level.** Tools render at position 0 and any
  add/remove/reorder invalidates *everything downstream* — the most expensive invalidation there is.
  `Canonical` makes it true today; nothing makes it stay true.
- **The 20-content-block lookback is a live hazard for parallel tools.** A breakpoint searches back
  at most 20 content blocks for a prior entry, so a single turn emitting more than 20 blocks — which
  is exactly what a parallel-tool fan-out does — silently misses the previous turn's cache. Mitigation
  is an intermediate breakpoint roughly every 15 blocks. This interacts directly with
  `planning/specs/chunk-parallel-tools-core-skeleton.md` and nothing in the repo accounts for it.
- **Only 4 breakpoints exist per request**, so placement is a design decision with a budget, not a
  marker you sprinkle.
- **Fork does not inherit the parent's prefix, by design.** "Subagents get a *fresh* Timeline root"
  is a deliberate architectural choice, and its cache cost is exactly what the fork-vs-respawn study
  should price. The finding to look for is not "forking is cheaper" but "here is what prompt
  non-inheritance costs, per subagent."

> ⚠️ **`CLAUDE.md`'s "minimum cacheable prefix is 4096 tokens" is now wrong as a flat statement** —
> the minimum is model-dependent and **not monotonic across generations**: 512 tokens on Opus 5 /
> Fable 5, 1024 on Opus 4.8 / Sonnet 5 / Sonnet 4.6, 2048 on Opus 4.7, and 4096 on Opus 4.6 / 4.5 /
> Haiku 4.5. The 4096 figure describes the Opus 4.5/4.6 era. A prompt that silently would not cache
> then may cache now, so the July survey's "prefix-stability property test up to the ≥4096-token
> boundary" is testing against the wrong constant, and `planning/specs/cache-economics.md`'s
> shared-template floor is set too high for a current model. Same correction applies to
> `references/prompt-caching-mechanics.md`, which at least already hedges with "model-dependent".

---

## 8. Comment-mined follow-ups (threads-of-threads)

Links that recurred across threads or came from a commenter rather than a submitter. These were the
higher-signal layer in July too.

- **`pleasedonotescape.com`** — sandbox-escape challenge, cited in §1.6 and §4.3. A ready-made
  adversarial fixture for the isolation arm.
- **`role-confusion.github.io`** (paper site for `2603.12277`) — cited by *both* sides of the
  session-portability argument, as the reason to hide reasoning and as the reason hiding it is
  futile. Rare case of one result anchoring a real disagreement.
- **MCP 2026-07-28: transport going stateless** — id=49088058 (127pts, 40c), companion to §1's
  stateless-MCP entry, with an MCP lead maintainer (`dend`) in-thread confirming existing servers
  need no changes. `firasd` gives the conceptual justification: tool calls were always stateless —
  "it's just text going back into the context window" — and server-side statefulness was "very iffy
  anyway." Reinforces the Effect-as-value framing rather than adding to it.
- **`claude-thermos`** — id=49024882 (111pts, 86c), a tool that pings a session to keep the prompt
  cache warm past its TTL. The community rediscovering pre-warming; the pushback ("this wastes
  cycles — they dump your cache and deallocate the VMs so others can use it") is the provider-side
  cost of the practice, and the whole thread is indirect confirmation that the **5-minute default
  TTL is the binding constraint** people route around. Cross-read with §1.4.
- **"Claude Is Not a Compiler"** — id=48993059 (161pts, 163c). Mostly noise, one precise correction
  worth keeping against §2.1's spec-driven-development discussion — `tossandthrow`: "a compiler does
  not translate specs to code. Specs are **denotational** by nature… a program could synthesize a
  program that adheres to the specs, but that is not what we understand by a compiler, which
  generally has to preserve operational semantics." Useful when reading the linked
  `haskellforall.com/a-sufficiently-detailed-spec-is-code` claim.
- **`github.com/tontinton/maki#context-efficiency`** — the most-recurring repo link in this window
  (§1.6, §1.3, and the stateless-MCP thread), always for its context-efficiency claim; unverified,
  worth a look during the context-combinator work.
- **`context-folding.github.io`** and **`piclaw/docs/pipelined-compaction.md`** — two named
  compaction strategies with public writeups; candidate arms for the compaction sweep beside
  summary-only and plan-file-reread.
- **`github.com/imbue-ai/latchkey`**, **`bubblewrap`** + **`slirp4netns`**, **`gh-proxy`**,
  **`varlock.dev`** — the isolation/credential-broker cluster, extending July's yoloAI/Gondolin
  entry. Rootless primitives worth surveying before `lain-core`'s handler work.
- **`research.autodesk.com/blog/constrain-agent-not-user`** — the generative/interpretive/elicitative
  constraint taxonomy from §2.1's thread; a candidate axis vocabulary for the guardrail sweep.
- **`gwern.net/complement`** (Spolsky's commoditize-your-complement) — offered as the companion piece
  to session portability, and it is the economic explanation for every mechanism in that post.
- **`marginlab.ai/trackers/claude-code/`** — a third party tracking Claude Code's behaviour over
  time. If it holds up, it is a public record of the harness-drift the bench wants to measure.
- **`github.com/nothingnesses/agent-scaffold`** — plan files as a validated state machine (§2.2).
- **`arxiv.org/abs/2307.03172`** (Lost in the Middle) — re-surfaced in §1.5; already-known, noted so
  it is not re-vetted.

### Candidate arXiv papers surfaced in discussion (vetted 2026-08-06)
Ten IDs mined from comment links, each checked against `SCOPE.md`. Abstracts fetched from the arXiv
API. *(Gotcha for a re-run: `http://export.arxiv.org/api/query` returns empty here; use `https`.)*

**Recommended for acquisition** into `papers/rst/` — seven, ranked:

| id | why it earns a slot |
|---|---|
| `2603.24755` | **SlopCodeBench** — 36 problems, 196 checkpoints, agents repeatedly extend *their own* solutions. Measures **structural erosion** and **verbosity** deterministically. Best agent passes **14.8%** of checkpoints; erosion rises in **77%** of trajectories, verbosity in **75.5%**; agent code is **2.3× more verbose and 2.0× more eroded** than 473 human Python repos. Explicit quality guidance cuts *initial* erosion by up to a third but **does not change the degradation rate**. This is the missing cost function §2.1 says harness engineering ignores — and it is a grader Lain can run. |
| `2605.12366` | **Classifier Context Rot** — frontier models used as *monitors* miss dangerous actions **2×–30× more often** after 800K tokens of benign activity than in isolation; periodic reminders partially mitigate. The bench plans LLM judges; this says judge reliability is itself a function of context length, which makes it a constraint on the grader design, not a curiosity. |
| `2607.03423` | **DSCC — compositional tool policies** — a Most Restrictive Set algorithm composing per-tool policies with a **formal monotonicity invariant: extending a chain can only tighten the result**, plus session-level taint propagation. That is a semilattice over exactly the structure `Middleware` is already property-tested as a monoid on. Strongest structural match in the batch. |
| `2603.12277` | **Prompt Injection as Role Confusion** — models perceive speaker identity from how text *sounds*, not its role label; role probes show injected text occupying the trusted role's representational space; **CoT Forgery reaches 60% attack success against frontier models** with near-zero baselines. The mechanism behind §3.1 and the citable basis for the attested-context arm. |
| `2607.29377` | **Zero-Mem** (§6) — trace-preserving, generation-free memory operations. M6. |
| `2602.16763` | **When AI Benchmarks Plateau** — defines saturation and analyses it across **60 LM benchmarks against 14 properties**; nearly half show saturation, with rates rising with age. The headline finding is counterintuitive and **contradicts its own HN thread**: resilience to saturation is driven by **expert curation, not by keeping test data private** — where the thread's evaluation practitioner argued private+rotating sets are "the only intervention that does" attack the mechanism. Take the paper over the comment, and note the tension: it changes what a durable Lain fixture corpus should optimize for (curation quality over secrecy). |
| `2605.20049` | **Does Code Cleanliness Affect Coding Agents?** — **minimal pairs**: repositories matched on architecture, dependencies and external behaviour, differing only in static-analysis violations and cognitive complexity, constructed in both directions, 33 tasks across six pairs, hidden tests. Worth acquiring for the **protocol** as much as the result: minimal-pair construction is how you isolate one variable in a fixture, which is the bench's central methodological problem. |

**Rejected** (kept here so they are not re-vetted):
- `2607.21551` — *Unconditional Unclonable Encryption* — quant-ph/cs.CR. Linked in the
  agentic-harness thread with no apparent connection to it; nothing to do with harness mechanics.
- `2601.02200` — *Code for Machines, Not Just Humans* — CodeHealth correlates with semantic
  preservation after AI refactoring. Same territory as `2605.20049` but correlational rather than
  controlled; the minimal-pair paper dominates it.
- `2607.24653` — *Kimi K3* — model card. Architecture and training, no harness mechanism; same
  class as the already-rejected *Sparks of AGI*.
- `2606.15497` — *Towards End-to-End Automation of AI Research* — research-lifecycle automation;
  tangential to harness mechanics, and a SCOPE non-goal.
- `2607.23806` — *A Frozen 12B Beats Frontier Models on Verified Work: 100% Accuracy, 0 Tokens,
  Bit-Exact, Forever* — the mechanism (cache independently-verified solutions, replay them at zero
  generation tokens, 180/180 across nine problem families) is a memoization table, and the negative
  control showing an emptied memory solves nothing is the paper honestly reporting that. Rejected
  on framing rather than on interest: the title's claims are not the paper's, and the idea Lain
  would actually take — *verified results are content-addressable and replayable* — is already the
  Store's premise. Noted, not acquired.

---

## Top experiments this survey suggests (ranked)

Numbering continues the July list's intent; where a July item is *sharpened* rather than replaced,
it says so.

1. **Longitudinal degradation in the score vector** (§2.1 + `2603.24755`) — add erosion/verbosity
   grading to the founding harness-variance A/B. Without it, Lain's own sweeps optimize the same
   cost function Horthy correctly says is broken. **Sharpens July #0; do this before publishing any
   A/B result.**
2. **Prelude-ablation sweep against the vendor's own claim** (§1.1) — reproduce or refuse "80% of
   the system prompt removed, no measurable eval loss," per model tier. Highest-credibility early
   result available; nearly free given `Context#render` purity. **Sharpens July #1.**
3. **Oracle upper bound on every sweep** (§5.4) — report each arm as a fraction of post-hoc
   achievable headroom, not just as a delta against a baseline. One extra computation over results
   the bench already has; changes what the numbers *mean*. **It also settles the router argument
   (§7.3) before any router is built**: if the ceiling over a model pool sits near the best single
   model, the routing label is not meaningful and the skeptics are right.
4. **One cost model, two decisions: compact-or-not and switch-or-not** (§1.4 + §1.5 + §7) — the
   compaction break-even and the model-switch threshold are the same inequality over the same
   Journal accounting. Implement it once; let the compaction policy and a router both consult it.
   Then sweep window-size × compaction-cadence for §1.5's quadratic-cost effect. Feeds
   `planning/specs/cache-economics.md` and `cache-aware-compaction.md` directly.
4b. **Routing regimes, bounded by the oracle** (§7 + §5.4) — sweep `{prefix size} × {price ratio} ×
   {output length}` and report *where* per-turn routing wins rather than one aggregate number.
   Lain's content-addressed Timeline makes per-model cache state a query, which is the part every
   external router has to approximate. Compose with #3 and the result is "routing captured X% of
   available headroom, in these regimes."
5. **Attested context vs naive splice, scored by attack success** (§3.1 + `2603.12277`) — provenance
   as a measured variable. Unpublished for any open harness, and Lain's `Effect` boundary is the
   natural place to hold the manipulated variable.
6. **Compaction provenance + objective-survival grader** (§1.2, §1.5, §6) — snapshots carry the
   instruction that produced them; a grader asserts a named in-flight objective survives the
   boundary. Closes the one clause of the portability contract Lain does not yet satisfy.
7. **Isolation-strategy arms: linked worktree vs hardlinked clone vs jj workspace** (§4.1) — safety,
   setup cost and handback correctness. Plausibly an application win on the suite's slowest file,
   and it retires a hazard this repo has already been bitten by once.
8. **Bounded review-loop composition** (§2.2) — reviewer ∘ fixer as a fixture; measure
   turns-to-convergence and per-iteration diff size, and show that termination is a composition
   property rather than a prompting one.
9. **Controlled-language guardrail arm** (§3.3 + `2510.22251`) — ASD-STE100 conformance as an
   externally-specified constraint; does it help a weak model and handcuff a strong one?
10. **Search-shaped toolsets on a local model** (§1.6) — citation/call-chain toolsets vs
    write-capable ones on the Ollama path, scored for unsupported claims. Small model as subject,
    not as economy.
11. **Context-protection threshold, not just fork cost** (§2.3) — sweep subtask complexity against a
    fixed grader to find where context isolation starts paying in *quality*. The fork-vs-respawn
    study was scoped as cost alone, which would have answered "forking is cheaper, therefore fork"
    — confidently, and to the wrong question.
12. **Approval-fatigue decay curve** (§4.2) — prompt rate × session length × batching → approval
    accuracy, derived from Journal data the approval surface already records. Turns the
    `{always-ask, classifier-gated, isolate-and-never-ask}` choice into a measurement.
13. **Fixture-hygiene spec: the answer must not be reachable from the repo** (§5.5) — coding-agent
    benchmarks leak through an undeleted `.git`, and every fixture in `spec/` builds a real git
    repository. Assert mechanically that a task's solution is not recoverable from the tree the
    agent is handed. **Do this before writing any coding-task grader**, not after.
14. **Constraint-enforcement arm: prompt vs deleted vs static verifier** (§2.5) — hold the constraint
    fixed, vary how it is enforced, measure adherence across two model generations. A checker
    survives the upgrade that invalidates a prompt, which is a testable claim and the reason this
    repo's own lint stack is load-bearing.
15. **Recursion vs heterogeneous models, separated** (§7.5) — same topology, uniform models against
    tiered. Tests whether orchestration results in this space are routing results in costume, and it
    is the one routing shape that does not fight the cache: route by **role**, not per turn.
16. **IRT instead of averaged pass rates** (§5.5) — model per-task difficulty and per-arm capability
    jointly. The statistically honest version of the founding A/B, and the direct answer to
    "harness-variance deltas disappear into measurement noise."
17. **Repeat-dead-end rate as M6's objective** (§5.6) — a memory system that does not lower
    re-exploration of already-scored paths is not earning its context. Computable from the Journal.
18. **Two cheap cache property tests, both currently unguarded** (§7.6) — (a) tool rendering is
    order-stable at the `Request` level, since a reorder invalidates the entire prefix; (b) no
    single turn emits more than ~15–20 content blocks without an intermediate breakpoint, because
    the lookback window is 20 blocks and a parallel-tool fan-out blows past it *silently*. Both are
    property tests, not experiments, and (b) is a live hazard for the parallel-tools work rather
    than a hypothetical.

See `SCOPE.md` for the questions these answer and `planning/` for where they slot.
`hn-agent-landscape-2026-07.md` is the previous window and is not superseded by this file.
