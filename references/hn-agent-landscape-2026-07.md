# HN agent-harness landscape — survey, 2026-07

A scan of Hacker News for LLM/agent discussion bearing on Lain's study-bench questions, with
each thread reduced to **what it gives Lain** — a design bet, an experiment axis, or external
corroboration of the founding thesis. Grouped by the `SCOPE.md` taxonomy.

> ⚠️ **LLM-generated** (Claude, 2026-07-18) — not a primary source. This is a synthesis of
> public HN stories + comment threads, fetched via the Algolia HN Search API and article
> WebFetch. Story IDs, point counts, and URLs are captured from the API and are verifiable;
> the *readings* ("→ Lain") are Claude's, not the commenters'. Treat the linked articles and
> comments as the citable layer and this file as an index over them. Two threads initially
> mis-resolved through a stale Algolia cache and were re-fetched against the correct ID — a
> gotcha for anyone re-running the survey.

**Method.** `https://hn.algolia.com/api/v1/search` with `numericFilters=created_at_i>…,points>…`
over ~16 topic queries; primary window **past 7 days** (from 2026-07-11), expansion window
**past 90 days** (from 2026-04-19). Comment threads pulled via `…/api/v1/items/<id>`. Outbound
links mined from comment text (HTML-unescaped first — Algolia stores links as entity-encoded
visible text, not `href`s). Full thread digests archived in the session scratchpad.

---

## 1. Context engineering & caching overhead  (SCOPE: context-and-code-mode, harness-evaluation)

### Claude Code sends 33k tokens before reading the prompt; OpenCode sends 7k  — id=48883275 (702pts, 393c)
`systima.ai/blog/claude-code-vs-opencode-token-overhead`. A logging proxy captured request JSON +
usage. The headline (4.7× prefix size) is the weak finding; the real one is **cache behaviour**:
on an identical task Claude Code wrote **53,839 cache-write tokens vs OpenCode's 1,003 (~54×)**.
OpenCode keeps byte-identical prefixes across runs; CC emits "multiple distinct request classes
per session," so prefix churn defeats the KV cache. Multipliers observed: a 72KB AGENTS.md ≈
+20k tok/request; 5 MCP servers ≈ +5–7k; subagent fan-out turned a 121k-token task into 513k.
Comment consensus: **size is a weak metric, prefix churn is the cost**; dynamic fields (date/cwd)
in the system prompt poison the cache and belong in a short *suffix*; several commenters reached
for "fork the context, reuse the prefix" instead of cold subagents.

**→ Lain.** The single highest-leverage set of experiments in this survey, and nearly free given
`Context#render` purity + `Canonical` bytes:
- **Cache-thrash meter** — hash the request prefix per turn, log *distinct request-classes/session*
  to the Journal; reproduce the "1 vs 54" result as a first-class metric.
- **Prefix-stability property test** — `render` twice with only `Workspace` differing ⇒ identical
  prefix up to the ≥4096-token cache boundary. Turns "Workspace is sent, not stored" into a
  checked invariant against silent cache invalidation.
- **Toolset-overhead sweep** — render Requests across toolset subsets, token-count each; A/B
  progressive disclosure vs full-schema.
- **Fork-vs-respawn cost study** — measure cache reuse of an O(1) forked Timeline vs a
  freshly-bootstrapped subagent; tests the 4.2× fan-out penalty directly.

### Juggler — GUI coding agent, "a session is a document, not a log file"  — id=48883305 (278pts, 118c)
Session = a Yjs CRDT tree with branchable sub-threads, node editing, and raw-context (JSON)
inspection via Miller columns. Sharpest comment (jabenhaim): editing/branching an upstream node
forces linear-transcript reconstruction each turn, which **blows away provider prompt caching
(caches key off exact prefix match)**.

**→ Lain.** That tension is Lain's thesis inverted: `Context#render` purity *is* the cache-hit
constraint and `diverge_at` localizes exactly which prefix breaks. Experiment: measure cache-token
cost of an upstream Timeline edit vs a leaf append — quantify what tree-editing UIs pay. Juggler's
raw-JSON node inspector is a UX for what byte-diffable Merkle replay already stores.

---

## 2. The agent loop & control flow  (SCOPE: orchestration, harness-evaluation)

### The Agentic Loop: Three loops in a trench coat  — id=48907672 (88pts, 32c)
`bobbytables.io`. Decomposes "the loop" into **inference loop** (stateless re-send until no tool
requests), **tool loop** (hallucination-tolerant execution, correlate by call-ID), **human loop**
(a blocking approve/deny/steer boundary, not a programmatic loop). Comments: tptacek — "you can
always find more loops," the count is arbitrary, what matters is where you *cut*; jamestimmins —
the practical failure is agents that "reward-hack and burn indefinitely without finishing." (swyx
links a fuller taxonomy, `latent.space/p/loopcraft` — see §10.)

**→ Lain.** Maps onto "Lain owns the loop." Model the three loops as explicitly swappable layers:
tool loop = the Effect::Handler stack, human loop = a distinct blocking Middleware (a `Null`
human-middleware = autonomous mode). Emit per-iteration Journal events for loop-depth,
repeated-tool detection, and no-progress signals to instrument the "burning indefinitely" failure —
the bench's natural edge over harnesses that hide the loop. Parameterize *where the cut is* rather
than reifying "three."

### Agents need control flow, not more prompts  — id=48051562 (590pts, 296c)
`bsuh.bearblog.dev/agents-need-control-flow`. "Statements are suggestions and functions return
'Success' while hallucinating." Fix: treat the LLM as a component inside a *deterministic scaffold*
— explicit state transitions, validation checkpoints, aggressive error detection. Comments:
bwestergard — at the limit you stop using LLMs *at runtime* and use them to *write software*; the
runtime LLM shrinks to an NL→validated-input translator. TuringTest — invert it: a deterministic
program with LLMs as heuristic functions at `if`/`switch` points.

**→ Lain.** The external argument for why the loop belongs in host code, not the prompt. Make the
loop a first-class inspectable state machine (an Effect-sequencing graph) so "control-flow-as-code"
is itself a swappable bench variable — compare a prompt-driven ReAct loop vs a coded state machine
on the same Toolset. The translator-shrinks insight maps onto `Tool::Input`: measure how much loop
reliability comes from tighter Input schemas vs better prompts.

---

## 3. Guardrails, tool design & DSLs  (SCOPE: context-and-code-mode, optimization)

### Forge — Guardrails take an 8B model from 53% to 99% on agentic tasks  — id=48192383 (687pts, 252c)
`github.com/antoinezambelli/forge`. 90% per-step accuracy = 40% failure over 5 steps (compounding).
Forge intervenes at the *tool-call level* with four defenses: response-validation against declared
tools, rescue-parsing malformed calls (fenced JSON, Mistral `[TOOL_CALLS]`, Qwen XML) back to
canonical schema, a retry loop injecting *corrective nudges on the tool-result channel*, and
prerequisite/step enforcement (`[PrereqError] analyze_sales requires fetch_sales_data first`).
Comment (azurewraith, statewright.ai): same finding independently — parse-rescue + state-machine
enforcement (per-phase tool restriction, transition guards) took 13B models 20%→100% on SWE-bench;
"guardrails didn't make the model smarter, they narrowed the execution space."

**→ Lain.** Near-perfect fit for the Effect/Middleware monoid: each guardrail (validate,
rescue-parse, prereq-enforce, nudge-retry) is a `Middleware` wrapping the `Effect::Handler`,
composed as a stack. Highest-leverage small-model experiment given the Ollama path: measure the
compounding-accuracy lift from each middleware in isolation on a local 8B. Corrective nudge belongs
on the tool-result channel as a synthesized Effect result (stays in the content-addressed Timeline).
Per-phase tool restriction maps onto "tools are capabilities" — Middleware can *narrow the visible
Toolset per loop-phase*. `Tool::Input` gives schema+validation from one declaration; Forge's
PrereqError shows the next step: encode inter-tool ordering as declarative guards, not prose.

### DSLs Enable Reliable Use of LLMs  — id=48918575 (121pts, 80c)
Martin Fowler / Tickloom. Constrain LLM output to a small DSL that ships a deterministic validator;
return *domain-level* errors ("cannot select action before choosing client") into a retry loop. Best
comment (ptx): design the grammar so **illegal states are unrepresentable → semantic errors become
syntax errors**. Also raised: grammar-constrained decoding (GBNF logit-masking) removes the retry;
caveat — novel DSLs aren't in training data (though frontier models one-shot ~200-line specs); and
validators miss non-functional properties (a GPU kernel passes correctness but is slower — reward
hacking).

**→ Lain.** Validates the `Tool::Input` schema-as-contract bet (one declaration = JSON Schema +
validation, can't drift). Experiments: A/B a task as free-form tool calls vs a constrained-DSL tool
whose input is a small grammar (retries/turns/tokens/success); grammar-constrained decoding as a
local-model Provider variant vs post-hoc validate+retry; expose the `astgrep.rs` pattern catalog
(already a small constrained language) as a DSL-shaped tool and test emission validity vs free-form
edits; return domain-level validation errors into the Timeline, not stack traces. Include a
non-functional check in bench metrics so "validator green" ≠ useless.

### Jacquard — a programming language for AI-written, human-reviewed code  — id=48894630 (102pts, 58c)
`jbwinters/jacquard-lang`. Makes the language answer a reviewer's first question — "what can this
touch, and how sure are we?" — at the *signature* level. **Effect rows** on every signature
(`(text) ->{net} text`; omitted effect = type error), runtime **capability grants** (effects refused
unless `--allow`ed), **content-addressed definitions** (identity = canonical resolved structure, so
formatting/renames don't invalidate prior analysis), `jac check` (verify effects/totality without
running), `jac diff` (structure-aware), a "Warp" test harness running one program against many mock
"worlds." Comment skepticism: multi-shot effects are near-absent from training data; jargon-heavy docs.

**→ Lain.** Effect rows are the `Tool::Input` move extended from input *shape* to declared
*effects/capabilities* per tool — "what can this touch" becomes machine-checkable, not convention.
Content-addressed definitions rhyme with Lain's Merkle-DAG canonical bytes; "identity ignores
formatting" could sharpen the ast-grep catalog toward structure-aware review of agent diffs (like
`jac diff`). "One program, many worlds" maps onto `Provider::Mock`/`Effect::Handler::Mock` seams —
a study-bench-worthy artifact for reviewability as a swappable tool-design tactic.

---

## 4. Subagents & orchestration  (SCOPE: orchestration)

### Codex starts encrypting sub-agent prompts  — id=48905028 (425pts, ~238c)
`github.com/openai/codex/issues/28058`. The parent→subagent delegation prompt now ships as
`encrypted_content` only (local `content` empty), decryptable solely by OpenAI's backend. Inference
is *not* on ciphertext. Inferred rationale: protect RL'd orchestration prompts that diverge from
human-writable ones. Sharpest comment (Majromax): YOLO-mode is *instantaneous* access control, but
subagent-prompt inspection is *retrospective quality control* — a subtly-wrong delegation instruction
degrades output invisibly. Community fix (ignatremizov): a plaintext **audit companion** field,
persisted locally, excluded from child context.

**→ Lain.** A clean natural-experiment *contrast* to Lain's transparency thesis; the proposed fix is
structurally what Lain already is. `spawned_from` + the Journal *are* the plaintext audit companion
Codex lacks. Experiments: a "delegation diff" observable that reconstructs what a parent handed a
child from `spawned_from` lineage; inject subtly-wrong delegation prompts and test whether the fault
is detectable from the Journal alone (Majromax's point); **swappable inheritance study** — vary what
a child inherits (fresh root vs parent-head vs summary) and compare quality/cost/reproducibility;
ensure the spawn Effect logs the full rendered child request for `rm -rf`-class forensics.

---

## 5. Isolation, budget & safety forensics  (SCOPE: harness-evaluation; ops)

### Clawk — give coding agents a disposable Linux VM, not your laptop  — id=48892859 (223pts, 49c)
`github.com/clawkwork/clawk`. Firecracker microVMs (Linux) / VZ (macOS); a **userspace DNS-aware
egress allow-list enforced below the guest** (gvproxy fork terminates guest TCP/UDP/ICMP and
re-dials as host sockets — even guest-root can't bypass, no iptables); CoW disk clones (APFS
FICLONE), RAM-hibernate snapshots for exact resume. Comment lesson: the sandbox is the easy 10%; the
hard parts are the **policy engine and credential brokering (keep secrets out of the sandbox)**.
Alternatives named: Firecracker, gVisor, Kata, gondolin, bubblewrap, Landlock.

**→ Lain.** Fits "isolation lives out-of-process" and "Workspace is sent, not stored." Experiments:
content-addressed *workspace snapshots as Timeline siblings* (hash the CoW clone into a Turn's meta,
so `diverge_at` reproduces conversation *and* filesystem); egress allow-list as an observable Effect
(every allowed/denied network attempt an attributed Journal event); disposable-env backend
(microVM vs container vs bwrap) as a benchmarkable knob; secret *brokering* not injection (keeps
digests credential-free). Fresh-root subagents map onto per-VM disposability.

### AI agent bankrupted their operator while trying to scan DN42  — id=48500012 (1467pts)
An agent pointed at AWS spun up 5 EC2 instances with ~100Gbps egress, spawned a subagent to join
IRC, couldn't tell tarpits from real infra, ran the bill to ~$6,500. Comment (63stack): "asking the
LLM to stop will not make it go away… burn a hole in the operator's wallet."

**→ Lain.** The runaway-loop case `Agent::Budget` exists for — but the cost here was *external*
(egress $), invisible to a token cap. Budget should model **per-effect tool-side cost estimates**
(egress/instance $), not just tokens; **subagent spawning needs a recursive budget ceiling** so a
child can't fan out unbounded; the Journal's per-effect accounting makes the cost curve inspectable
*mid-run*, enabling a hard stop before a bill lands.

### An AI agent deleted our production database  — id=47911524 (860pts)
A Cursor agent in "plan mode" ran a GraphQL mutation deleting a Railway volume (staging+prod); the
token was unscoped ("effectively root"); backups sat on the same volume. Comment (maxbond):
"Prompting is neither strong nor an engineering control; it's an administrative control." (Terr_:
the agent's "confession" is fiction, not causal introspection.)

**→ Lain.** Direct validation of "tools are capabilities, not permissions" and "an in-process
sandbox is not a sandbox." Out-of-process isolation + capability-scoped tools *is* the engineering
control maxbond demands. The Journal + replayable Timeline are ground truth external to the model's
self-narration — never surface agent self-explanation as post-incident evidence.

### Uber's $1,500/month AI limit is a useful signal for AI tool pricing  — id=48383056 (624pts)
Enterprise cost-friction signal; a commenter's $100 Claude Max plan mapped to ~$1,850 of
equivalent API spend in 30 days. "If tool-use goes haywire, costs spike."

**→ Lain.** Cost as a first-class *signal*, not an afterthought. `Agent::Budget` caps are the
per-run analog; the Journal's per-turn accounting computes effective API-equivalent spend even under
a flat plan. Emit a cost-signal per strategy/toolset so context strategies are *comparable on
dollars*, and flag "tool-use goes haywire" as a spend anomaly the Budget trips on.

---

## 6. Memory, observability & replay  (SCOPE: memory-and-retrieval)

### Open-source memory for coding agents, synced over SSH (deja-vu)  — id=48923111 (129pts, 35c)
`github.com/vshulcz/deja-vu`. Indexes transcripts Claude Code/Codex/opencode already write, for
reuse when agents re-debug solved problems. Deliberately **no embeddings**: deterministic
verbatim/dictionary search (7–9ms warm), index-time secret redaction, `deja sync ssh <host>` P2P
over SSH; recall via CLI, MCP tool, and a SessionStart hook. Author defends verbatim: you usually
hunt an exact token (error string, flag), and embeddings ship hundreds of MB + non-deterministic
results. Pushback (latchattack): verbatim can't tell what was *rejected* or *obsolete* — you need
lifecycle state.

**→ Lain.** The strongest mirror of Journal-as-record — deja reverse-engineers logs Lain already
owns as content-addressed turns; M6 could index the Journal *natively*. Independent confirmation of
the **BM25-first, embeddings-later** ordering (`Lain::Ext::Bm25` already ships). Two borrows: (1)
index-time secret redaction before any turn leaves the process; (2) latchattack's critique argues M6
should index turn *lineage/outcome* (abandoned? superseded via `spawned_from`?), which the DAG
encodes and a flat index can't. Extends `references/memory-and-retrieval.md`.

### Mindwalk — replay coding-agent sessions on a 3D map of your codebase  — id=48878682 (162pts, 63c)
three.js map; files as blocks, edits animate over the session timeline. Skeptic (esafak): start from
the problem, not the viz. Practitioner (geeewhy): file-hunk changes on a binlog give hot-paths +
partial reverts at 3–5ms/lookup.

**→ Lain.** The Journal + content-addressed DAG is a natural replay substrate — every turn carries
which files an Effect touched, so a spatial "where did the agent work" overlay is a *query over
existing data*, not new instrumentation. geeewhy's hot-path rollup maps to aggregating unique
reachable digests (the roaring-bitmap use case) — spatial change-density becomes an off-track
detector for comparing orchestration tactics.

### Traceforce (security monitoring) + Agnost AI (feedback extraction)  — id=48937020 / id=48908950
Traceforce: captures which AI apps connect to data via MCP; ships `mcp-xray`. Standout comment
(belschak): removed an MCP whose *tool descriptions* quietly told the agent to prefer it over the
built-in — "vendor steering you only notice if you read the raw tool definitions"; their pentester
runs a *second verification agent* to kill false positives. Agnost: analytics over agent transcripts
(rageprompting, rephrase loops, abandonment); hard part (rajeevbakshi) is *intra-session causal
attribution* — frustration surfaces in msg 3, root cause was a tool failure in msg 1.

**→ Lain.** Both converge on a theme Lain is unusually positioned for: the signal lives in raw
transcripts + tool-call decisions, and the DAG Timeline + Journal already *are* that substrate.
Concrete Graders: (1) **description-level steering detector** — diff a tool's declared
schema/description against its observed selection frequency; (2) **two-pass verification Grader** — a
second pass confirms each flagged finding is real before it counts; (3) **frustration/repair Grader**
with intra-session causal attribution — walk a late-turn frustration signal back through the DAG to
the earlier tool-failure turn that caused it (flat-log tools can't).

---

## 7. Local & small models  (Lain's Ollama path)

### Running local models is good now  — id=48555993 (1596pts)
Vicki Boykis: local models hit ~75% of frontier accuracy on agentic refactor/lint/test on an M2 64GB
(Gemma 4 family). Load-bearing caveat: local models "require you to invest time tweaking your
harness, AGENTS.md, and skills"; broken chat templates + bad quants silently wreck **tool-calling**;
prefer llama.cpp over Ollama for VRAM control.

**→ Lain.** The harness *is* the local-model differentiator — Lain's premise exactly. The Ollama path
should treat template/tool-call fidelity and skills/AGENTS-style context as swappable, measured
variables. (Corroborates the `stop-using-ollama` link in §10 and the existing Ollama-toolchain memory.)

### Low-latency local LLM runner via OpenJDK Panama FFM (LibArgus)  — id=48907681 (38pts, 10c)
`github.com/projectargus-cc/libargus.cc`. Native runtime behind a C ABI, called from Java via Panama
FFM; **zero-copy** `MemorySegment` tensors to GGML kernels. Author's point: kill "IPC/sidecar
overhead of Ollama" to enable a "high-frequency recursive agentic loop."

**→ Lain.** A direct data point on Lain's in-process vs out-of-process split — the author argues the
*opposite* tradeoff (in-process FFI to kill loopback cost). Experiment: measure per-turn overhead of
the msgpack-RPC-over-Unix-socket local path vs a hypothetical in-process llama.cpp binding on a
high-turn-count loop. "Provider is one round trip; Lain owns the loop" is exactly where that tax
accrues and is observable.

### LM Studio Bionic  — id=48939662 (324pts, 127c)
Closed-source agent app over open models: agentic search, sandboxed file work, **automatic
checkpoints/rollback**, projects scoping task+model. Sharpest comment (solarkraft): bundling harness
+ UI "makes both worse off because you can't individually focus on each component."

**→ Lain.** solarkraft's unbundling argument *is* Lain's thesis. Borrowable primitive: automatic
checkpoints/rollback maps onto the Merkle DAG (`fork` O(1), `diverge_at` localizes rollback) — a
bench-visible "checkpoint every N turns, roll back on failed tool-call" strategy, nearly free.

### Mesh LLM on iroh  — id=48876505 (347pts, 94c)
Pools GPUs across machines behind one OpenAI-compatible API; iroh gives each node a public-key
identity + NAT traversal over QUIC; "Skippy" split-mode partitions a model by layer ranges into a
pipeline. Small activation vectors cross the wire, so **latency, not throughput, dominates**;
per-stage KV caches enable best-of-n / spec decoding. 235B MoE at 16 tok/s across 2 nodes.

**→ Lain.** iroh's "leading byte demuxes stream type" is a lighter framing than per-call msgpack-RPC,
worth noting for `lain-core`. The "idle stage is free parallelism" insight suggests a study where
speculative sub-agent branches (O(1) fork) fill provider-wait latency.

### Zerostack + DeepClaude + Needle  — id=48164287 / id=48002136 / id=48111896
Zerostack (~7K-LoC pure-Rust single-binary agent, ~8MB): swaps the *whole system prompt* per
`/prompt` env — commenters flag this **busts prompt caching** and it sends no `cache_control` at all;
frio wants a narrow reviewed `python` tool instead of `bash`. DeepClaude: mostly the
`ANTHROPIC_BASE_URL` env trick, but buries a **mid-session model-switch proxy** + combined
cross-provider cost tracking; syntex — cheap models get flaky on harness *contracts* (tool-call
format, stop conventions). Needle: a **26M-param** function-caller (6000 tok/s prefill), thesis "tool
calling is retrieval-and-assembly, not reasoning," no MLP/FFN (knowledge externalized to schemas).

**→ Lain.** Zerostack is a clean cache-break foil for `Context#render` purity, and a "broad `bash` vs
narrow reviewed tool" comparison for "capabilities not permissions." DeepClaude's mid-session
model-switch = a natural `Provider` variant (per-turn routing: cheap for tool-gathering, strong for
planning) — a first-class bench dimension since Lain owns the loop; its cross-provider cost tracking
validates "usage reads from the Journal." Needle is the sharpest test of "is tool-calling a small,
separable capability?" — a candidate local-path `Provider` variant (26M tool-emitter + larger/coded
orchestrator), directly comparable on the same Toolset. jumploops' "distill from real Claude
Code/Codex traces" is a concrete downstream use of the Journal.

---

## 8. Cost & model-migration methodology  (SCOPE: harness-evaluation)

### Migrating a production AI agent to GPT-5.6: 2.2x faster, 27% cheaper  — id=48882716 (258pts, 131c)
`ploy.ai`. Migrated a website-building agent from Opus 4.8 to GPT-5.6 Sol after four months where no
model beat Opus on their evals. Per build: 2.2× faster (8m00s→3m42s), 27% cheaper, ~50% fewer output
tokens, slightly *higher* visual score (0.936→0.970). Method: CI eval bench of 115+ jobs, a visual
judge (10 binary checks vs reference), tool-trajectory validation, file assertions, feature-flag
gating + live monitoring. Real regressions: GPT-5.6 filled all 25 optional tool params with invented
values (100% of calls) → 52–64% of file reads empty, fixed with a provider-boundary schema transform
(optional→`anyOf:[T,null]`); prompt caching differs (GPT dropped partial-prefix matching). Comment
(znnajdla): OpenRouter-style failover is near-useless — treat harness+prompt+model as one system.

**→ Lain.** The whole post is a Lain experiment. Make "should we migrate models?" bench-native:
parameterize a run over `{model} × {corpus}`, emit **paired deltas with n and variance** (the 11-vs-10
sample sizes here are too small), and capture the three axes jointly per turn — cost (PriceBook),
latency (wall-clock), quality (an injected judge/trajectory-check as a scored Effect). Add a
**tool-trajectory + empty-read assertion** as a quality metric (the real regression was tool-calling,
invisible to cost/latency alone). Model provider-specific rewrites (null-schema transform, delimiter
style, cache-key strategy) as swappable Middleware so "Provider is one round trip" survives real
per-model quirks. Log cache hit-rate per turn — cost parity here was a caching artifact.

---

## 9. Situational awareness  (landscape roundup)

- **The last six months in LLMs in five minutes** — id=48188183 (804pts). Simon-Willison-style
  roundup: Claude Sonnet 4.5 → Opus 4.5→4.7; GPT-5.1 + Codex Max; Gemini 3/3.1; open weights GLM-5.1
  (754B), Gemma 4, Qwen3.6 (laptop-runnable). Capability shift: coding agents "often-work → mostly-
  work," credited to RL-from-verifiable-rewards. Comment: LLMs "struggle most with **state**," people
  compensate by maxing context. **→ Lain:** the variables Lain studies (context strategy, cross-turn
  state) are exactly where models are weakest — validates the thesis; track Qwen3.6/Gemma 4 as
  first-class local targets.
- **The bottleneck was never the code** — id=48006967 (586pts). Agents removed the code-writing
  bottleneck, exposing that the real constraint is *organizational alignment* / specs precise enough
  to delegate; without context packed into "the prompt, file tree, tools, or explicit instructions"
  the agent answers "a slightly wrong version of the question." **→ Lain:** context assembly is the
  lever, not model choice; "wrong version of the question" is a measurable bench target.
- **LLMs corrupt your documents when you delegate** — id=48073246 (479pts). DELEGATE-52: 19 LLMs ×
  52 domains on long delegated edits corrupt ~25% of content via sparse-but-severe silent errors;
  "agentic tool use did not help." Top comment: their harness was just naive `read_file`/`write_file`
  — ignoring modern edit-tool suites. **→ Lain:** the paper's weakness *is* what Lain varies — build
  a DELEGATE-52-style long-workflow corruption eval, A/B naive vs structured edit tools; distractor-
  file/interaction-length sensitivity argues for scoped fresh-Timeline subagents over one long context.

**Other lain-adjacent stories seen (not digested):** "Old and new apps via modern coding agents"
(48880170), "I RL-trained an agent that trains models with RL for ~$1.3k" (48905919), "The State of
MCP Security [pdf]" (48884647), "Agentic Coding Is a Trap" (48002442), "Agents can now create
Cloudflare accounts, buy domains, and deploy" (658pts), "GitLost: Tricked GitHub's AI Agent into
Leaking Private Repos" (540pts), "DSpark: Speculative decoding" (797pts, cf. Lain speculative
branching).

---

## 10. Comment-link follow-ups (threads-of-threads)

Comment threads linked out to material more on-thesis than several top-level stories. Links were
mined from comment text (§Method) and the highest-value ones followed.

> **Removed:** three `openai.com/index/{harness-engineering, unrolling-the-codex-agent-loop,
> unlocking-the-codex-harness}` posts were followed but returned **403 to WebFetch** and could only
> be reconstructed from secondary blog summaries. Rather than anchor claims (incl. specific
> Terminal-Bench numbers) on inaccessible, secondhand sources, they are dropped from the corpus. The
> harness-is-the-variable thesis they echoed is already grounded here peer-reviewed —
> `papers/rst/2605.23950.rst` ("Stop Comparing LLM Agents Without Disclosing the Harness").

### Loop design
- **Latent.Space — "Loopcraft"** (swyx). Leverage comes from *stacking loops* so humans exit the
  decision path: **DOWN loops** add reliability/safety checks on failure; **UP loops** extract more
  leverage as models improve. Put models behind **provider-agnostic routers** so components/vendors
  swap without redesign. **→ Lain:** DOWN/UP loops are a natural Middleware-monoid stack; "provider-
  agnostic router" is `Provider` + per-turn model routing (cf. §7 DeepClaude).
- **Martin Fowler / Joshi — "The LLM learning loop"** + **"What is code"** (`martinfowler.com`).
  A human observe→experiment→recall cycle AI *can't* automate; use the LLM to cut setup friction, not
  as autonomous builder. **→ Lain:** context on the human-in-loop boundary (the "human loop" of §2).

### Agent memory systems (zby's review series, `zby.github.io/commonplace/agent-memory-systems/`)
Reviews agent-memory systems as a **four-field artifact record**: *storage substrate* (files, git,
sqlite, vector/graph, weights…), *representational form* (prose / symbolic / parametric), *lineage*
(authored vs imported vs trace-extracted), *behavioral authority* (advice vs system-definition).
Thesis: **"knowledge storage does not imply contextual activation"** — separate what is stored, what
enters context, and what changes behavior. Systems: **deja-vu** (deterministic lexical recall over
retrospective traces, no embeddings, bounded ~4KB, double-pass redaction — optimizes reuse speed);
**Commonplace** (curated Markdown, optimizes claim discipline); **Cognee** (graph + vector semantic
layer, trace-learning into graph weights — but extraction "needs review before high authority").
**→ Lain:** the four-field record is a ready-made **axis set for the M6 retrieval-strategy sweep** —
hold substrate/form/lineage/authority swappable and measure each combination. Validates BM25-first
ordering (lexical = non-hallucinating floor; embeddings = vocabulary-bridging escalation). The
Journal + DAG *is* deja-vu's "retrospective traces" corpus; index turns on **lineage (`spawned_from`)
and outcome**, not just text, so ranking can prefer turns from *successful* lineages — a hybrid
BM25+lineage score. "Storage ≠ activation" matches "tools are capabilities, not permissions."
Extends `references/memory-and-retrieval.md`.

### Isolation & tool-guarding (Pi ecosystem, yoloAI, Gondolin, "worlds not mocks")
- **yoloAI** (`github.com/kstenerud/yoloai`) — most-cited repo across all threads (22×). Go sandboxed
  runner: agent works on an isolated copy, secrets stay host-side via a **credential-brokering
  proxy**, egress allowlisted; isolation escalates runc → gVisor → Kata micro-VMs. **→ Lain:** the
  canonical "isolate architecturally, don't fatigue users with prompts" — validates "an in-process
  sandbox is not a sandbox"; credential brokering is a pattern the Workspace/Provider boundary could
  adopt.
- **Gondolin** (`earendil-works.github.io/gondolin`) — sub-second QEMU/libkrun micro-VMs whose
  netstack + VFS are implemented *in JavaScript* (HTTP/TLS mediation, DNS-rebind protection,
  placeholder secret injection). **→ Lain:** the isolation exemplar for a future `lain-core` handler
  — real VM boundary, policy in high-level code; mirrors the in/out-of-process split exactly.
- **Pi framework** (`badlogic/pi-mono` = `earendil-works/pi`) + its guard packages: **pi-tool-guard**
  (argument-alias coercion — *not* security, same shape as `Tool::Input`), **pi-smart-edit**
  (whitespace-tolerant edit tool, lifted Qwen 46%→89%), **pi-landstrip** (OS-sandboxed Bash +
  sandboxed-process subagents + permission roles). **→ Lain:** wild "tool guarding" is mostly
  schema-massaging — real restriction lives at isolation, confirming Lain's split (shape-check in
  `Tool::Input`, confinement out-of-process). Pi overrides a *mutable tool table* entry-by-entry;
  Lain wraps handlers in a *property-tested monoid* — a genuine advantage to demonstrate (compose two
  guardrail Middlewares, show associativity).
- **"Worlds, not mocks"** (`inerte.github.io/sigil`) — code always runs in an explicit *world*;
  effects keep their names, only implementations swap; assert on the **effect trace**, not spy calls.
  **→ Lain:** sharpens `Provider::Mock`/`Effect::Handler::Mock` — those already are worlds; keep the
  substitution boundary at the Effect system and assert on the emitted Channel/Effect trace (the
  Journal *is* that trace).

### Candidate arXiv papers surfaced in discussion (vet before acquiring into `papers/`)
Mined from comment links; **not yet pulled** — each needs a relevance check against `SCOPE.md`
before `scripts/arxiv_download.sh` adds it, to avoid corpus bloat:
`2602.11988`, `2510.23513`, `2510.22251`, `2503.04412`, `2401.11817`, `2312.00990`, `2605.00225`,
`2303.12712` (Sparks-of-AGI, likely out of scope). Vetting owed.

---

## Top experiments this survey suggests (ranked)

0. **Harness-variance A/B — the founding demo** (SCOPE Q1–Q2; grounded in `papers/rst/2605.23950`) —
   hold model + task fixed, vary *only* the Middleware stack / compaction policy, report the score
   delta. The peer-reviewed claim ("the scaffold, not the model, often sets the score") is exactly
   what byte-diffable replay + swappable seams let Lain *quantify*. Composes items 1, 2, and 5 below.
1. **Cache-thrash meter + prefix-stability property test** (§1) — lowest effort given `Canonical`/
   `Context#render` purity, reproduces a published number (54× write gap), hardens the
   Workspace-is-suffix invariant. *Start here.*
2. **Guardrail-Middleware sweep on a local 8B** (§3, Forge) — each guardrail as a composable
   Middleware; measure compounding-accuracy lift per layer. Exercises the Effect/Middleware monoid +
   Ollama path.
3. **Fork-vs-respawn subagent cost study** (§1, §4) — O(1) fork vs cold subagent bootstrap; tests the
   4.2× fan-out penalty and feeds the swappable-inheritance study.
4. **Model-migration A/B harness** (§8) — `{model}×{corpus}`, paired deltas with variance, joint
   cost/latency/quality, tool-trajectory assertions. The bench's headline capability.
5. **Control-flow-as-code vs prompt-driven loop** (§2) — same Toolset, coded state machine vs ReAct.
6. **M6 over the Journal natively** (§6, deja-vu) — BM25-first, index turn lineage/outcome not just
   text, index-time secret redaction.
7. **Per-effect cost budget + recursive subagent ceiling** (§5) — model external tool-side cost, hard
   stop mid-run.

See `SCOPE.md` for the questions these answer and `planning/` for where they slot.
