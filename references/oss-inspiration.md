# OSS harness inspiration — design ideas read at the code/architecture level

> Companion to `INDEX.md`. Ideas from other open-source agent harnesses, filtered to *mechanisms
> Lain doesn't already have* or *external validation of bets it has made*. Per the MemPalace
> lesson, prefer the retrieval/context/tool core over the README. Status: architecture-level for the
> projects below; deeper source introspection (submodule) flagged where it would pay.

## The striking one: OpenHands is already Lain's architecture, in production

OpenHands (All-Hands-AI) uses an **event store, not a message array**; the LLM-facing view is
computed from the store by a `View` class; **condensation inserts markers rather than deleting
events**, so the full audit trail survives and the view is always *derivable from the store plus
compaction actions*. Compaction is opt-in, agent-initiated, and tracked as an
`AgentCondensationAction` event. There are **nine pluggable condenser strategies composable into
pipelines via a registry**.

Map to Lain, almost one-to-one:

| OpenHands | Lain |
|---|---|
| event store, immutable events | content-addressed `Store` (Merkle DAG) |
| `View` derived from store | `Context#render`, pure function of the Timeline |
| condensation inserts a marker, never deletes | "a compaction is a new node, not a destructive edit" |
| 9 pluggable condensers via registry | the Context-combinator **monoid** |
| `AgentCondensationAction` tracked as an event | the Journal recording a compaction turn |

**What it gives Lain:** (1) strong external validation that "prompt = view over an append-only event
store" works at production scale — this is exactly the **IVM framing** in
`planning/first-class-concepts.md`; (2) a concrete **initial catalog of ~9 condenser strategies** to
seed the Context combinators rather than inventing them; (3) confirmation that condensation-as-event
(not destructive edit) is the right call. **Next:** submodule + read the condenser registry and the
`View` derivation to lift the nine strategies as named combinators.

## Aider — the repo-map (tree-sitter + PageRank): a context combinator Lain lacks

Aider's signature move: parse every file with **tree-sitter** to extract symbol *definitions* and
*references*, build a directed graph (edge referencing-file → defining-file, weight 1.0; self-loops
0.1 so isolated symbols still rank), run **PageRank with personalization toward the current chat
files**, sort, and accumulate symbols until the **token budget** is exhausted. Instead of dumping
files, it renders a ranked *skeleton* of the most relevant definitions.

**What it gives Lain:** a concrete, pure **Context combinator** — `(repo, focus, budget) → ranked
symbol map` — that is exactly the shape of `Context#render` and a natural swept axis (repo-map vs.
naive file dump vs. code-API). It generalizes beyond code: PageRank over a *citation/entity graph*
is a retrieval strategy for the medical corpus (rank abstracts by graph centrality personalized to
the query). **Next:** submodule + read `aider/repomap.py` for the ranking and caching details;
the token-budget accumulation is the same "fit(budget)" primitive the IVM combinators need.

## SWE-agent — ACI: Lain's thesis with a citable number

SWE-agent (Yang et al., NeurIPS 2024, [2405.15793](papers/rst/2405.15793.rst)) coins the
**Agent-Computer Interface**: apply HCI discipline to the *agent's* tools. Fixed model, **+12.5%
pass@1 on SWE-bench from interface design alone**. Four principles:

1. Actions simple and easy for the agent to understand.
2. Actions compact and efficient.
3. Environment feedback **informative but concise**.
4. **Guardrails mitigate error propagation and hasten recovery.**

**What it gives Lain:** the empirical spine of "tool design *is* context." These four are a **rubric
for Lain's `Tool` and tool-tier design** and a swept axis (verbose vs. concise feedback; with vs.
without guardrails). The number (+12.5%, model fixed) is the cleanest external evidence that the
bench is measuring something real. Pairs with the tool-*disclosure* axis in the research scan —
disclosure is *which* tools the model sees; ACI is *how each tool speaks back*.

## goose (Block) — the Rust reference for Lain's out-of-process layer

A **Cargo workspace** (Rust crates) + TS/Electron UI; MCP-based **Extensions** as the uniform tool
interface; **per-session `ExtensionManager`/`ToolMonitor`/channels to avoid global lock
contention**; ACP support in 2.0; subagents.

**What it gives Lain:** a production Rust agent to study for the `lain-core` boundary — especially
*per-session isolation to avoid lock contention*, which echoes Lain's `Store` monitor and
channel-per-consumer split, and validates deferring a global concurrency model in favor of
per-session ownership. Its ACP adoption reinforces the ACP-as-frontend note in the research scan.
**Next:** read goose's session store and channel model when Lain picks its concurrency model (M5).

## smolagents (HuggingFace) — CodeAct, and the executor as a swappable seam

Reading `references/repos/smolagents/src/smolagents/{local_python_executor,agents,remote_executors}.py`:

- **CodeAct via a restricted AST interpreter, not `exec`.** `evaluate_ast` walks the Python AST
  node-by-node; safety is by construction — an `authorized_imports` allowlist,
  `DANGEROUS_MODULES`/`DANGEROUS_FUNCTIONS` denylists, a ban on dunder-attribute access, gated
  `import_module`. **But the authors don't trust it:** the local executor is the fast/unsafe path,
  and `RemotePythonExecutor` subclasses (E2B, Docker, Modal, Blaxel) provide the real isolation.
  **For Lain:** this is the plan's "an in-process sandbox is not a sandbox" — *confirmed by a
  project that built the restricted interpreter and still offloaded to a sandbox.* The load-bearing
  abstraction is the **`PythonExecutor` ABC** (`send_variables`, `send_tools`,
  `__call__(code_action) -> CodeOutput`) with local + remote impls behind one seam — exactly Lain's
  `ext/lain`-vs-`lain-core` split. Adopt the seam; treat the local AST-interpreter as a *comparison
  arm*, never the trust boundary.
- **The persistent `state` dict is the persistent binding — and tools + subagents are injected into
  it as callables.** `state = {"__name__": "__main__"}`; `send_variables(state)` seeds it; each call
  mutates it so variables persist across code-actions; and
  `send_tools({**self.tools, **self.managed_agents})` puts **tools *and managed subagents*** into the
  namespace as plain functions the executed code calls. **For Lain:** a working realization of
  code-mode + "a subagent is a tool" + handles — the child agent is a *name in scope* the Ruby would
  call, and intermediate values live in the binding, never in context. `_print_outputs` (truncated
  to 50k) is the only thing that returns — the "intermediate results never enter context" property
  with a concrete budget.
- **The agent loop is a generator of steps** (`run(stream=True) → _run_stream` yields each step).
  **For Lain:** validation of the Enumerable ethos — a yielding loop composes; `final_answer(x)` is
  exit-as-tool-call, with `final_answer_checks` callbacks gating acceptance.

## Cline — checkpoints: a *second* content-addressed timeline, for the workspace

Reading `docs/core-workflows/checkpoints.mdx` and `sdk/packages/core/src/session/checkpoint-restore.ts`
(read via shallow clone; not vendored — large TS repo):

- **A shadow git repository.** After each file-modifying tool, Cline commits the whole workspace to a
  git repo *separate from the user's* — clean user history, captures untracked files too, persists
  across sessions. Filesystem time-travel to complement conversation time-travel.
- **Files and conversation are two timelines, independently rewindable** — the sharp abstraction,
  from the restore menu: **Restore Files** (revert code, keep conversation), **Restore Task Only**
  (revert conversation, keep code), **Restore Files & Task** (both). **For Lain, genuinely
  additive:** the Timeline is the *cognition* DAG; Cline shows you also want a *workspace* DAG,
  linked per step but independently `rewind`-able — and Lain can do it **better than a shadow git
  repo**, because the `Store` is already content-addressed: a file snapshot is just another
  content-addressed blob keyed at a turn, and `diverge_at` localizes a file divergence the same way
  it localizes a cache break. A new noun: the **Workspace Timeline** (distinct from the
  sent-not-stored `Workspace` state).
- **Cheap rollback changes the approval economics.** "The cost of a mistake drops to nearly zero" —
  checkpoints are what make auto-approve practical. **For Lain:** checkpointing and
  `Handler::Approving` / `--yolo` are *coupled* — per-step workspace snapshots let tier-3 `bash` run
  in yolo mode safely because restore is one operation. A design lever the plan doesn't yet connect.

## Meta-source: a source-code taxonomy of harnesses

"Inside the Scaffold: A Source-Code Taxonomy of Coding Agent Architectures"
([2604.03515](papers/rst/2604.03515.rst)) reads the *source* of many harnesses and classifies their
components (context builder, tool registry, permission resolver, budget tracker, condenser, …). It
independently names OpenHands' event store as the most extensible context model.

**What it gives Lain:** a component vocabulary to check Lain's architecture against, and a map of
which harness does each part best — the reading list for further introspection, grounded in code
rather than marketing.

## To introspect next (submodule + read the core)

| Project | Read | Why for Lain |
|---|---|---|
| OpenHands | condenser registry, `View` derivation | lift 9 condenser strategies as Context combinators |
| Aider | `repomap.py` | the PageRank repo-map as a Context combinator + token-fit primitive |
| ~~smolagents~~ ✓ done (above) | — | executor-as-seam, state-as-binding, subagents-as-callables |
| Codex CLI (Rust) | sandbox (seccomp/landlock), approval modes | the tier-3 `bash` exec boundary + `Handler::Approving` |
| ~~Cline~~ ✓ done (above, read not vendored) | — | the Workspace Timeline; approval economics |
| SWE-agent | `commands/` (the ACI tools) | how concise feedback + guardrails are actually implemented |

> Adding these as submodules touches `.gitmodules` (a repo commitment) — do it deliberately, one at
> a time, when actually reading the core, the way MemPalace was pulled.
