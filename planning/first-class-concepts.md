# First-class concepts — new nouns the Ruby+Rust substrate makes possible

> Exploratory brainstorm. These are *potential* first-class concepts — nouns that could become core
> to Lain — not committed scope. Each is grounded in a concrete mechanism (a Ruby feature, a Rust
> crate, an existing Lain primitive) so it is a design bet, not a vibe.

## What is actually rare about the substrate

Almost nobody has **all three** at once, and the good ideas fall out of the *combination*:

1. The entire conversation is a **content-addressed Merkle DAG** with O(1) `fork` and defined
   `meet` / `diverge_at`.
2. A **live Ruby coding shell** (`eval_ruby` against a persistent binding) where intermediate values
   *deliberately never enter context*.
3. A **Rust layer** that owns real persistent data structures in-process (magnus, pure) and large
   data out-of-process (`lain-core`, tokio).

The generalization of the plan's load-bearing insight (tool/context/orchestration are one pure
function): **cognition itself becomes a content-addressed, replayable, structurally-shared value** —
Ruby is the language you *manipulate* it in, Rust is the substrate it *lives* in.

---

## The two bets

### 1. Context management *is* incremental view maintenance — make it literal

**The reframing.** The rendered `Request` is a **materialized view** over an append-only log (the
Timeline); each turn is a **delta**. Prompt-caching, pruning, compaction, and recall — treated as
separate combinators today — are one problem the databases world solved decades ago:
**incremental view maintenance (IVM)**.

**Why it works *here specifically*.** IVM is only cheap if applying a delta is O(delta). Rust
persistent structures (`rpds` / `im`) with structural sharing give exactly that — a new turn shares
the whole prior spine, so the view recomputes only the suffix. Consequences:

- The prompt-cache breakpoint stops being a heuristic and becomes the **materialization boundary of
  the view**; cache invalidation is view-maintenance in the technical sense.
- Ruby expresses the view as a lazy `Enumerable` query over the DAG
  (`timeline.lazy.select { … }.compact_when { … }.fit(4096)`); Rust executes the walk.
- Because `Context#render` is pure and content-addressed, the **query plan itself is memoizable by
  digest** — "this strategy applied to this prefix" is cached across the whole bench.

**What it opens.** Context strategies become **query optimizers** reasoned about with real theory
(self-maintainability, delta propagation, view selection). "Which facts must survive for the view to
stay correct under this delta?" is a provenance question the Merkle structure already answers.

**Mechanism:** `rpds`/`im` (Rust) · `Enumerator::Lazy`, the monoid of Context combinators (Ruby) ·
existing `Timeline`, `Canonical`, cache-breakpoint placement.
**Prototype path:** Ruby-first — implement the IVM combinators over the pure-Ruby `Timeline` and
prove the laws; the Rust port is a later O(delta) speedup, not a prerequisite.
**Risk:** the reframing has to pay rent in *fewer* combinators and clearer invariants, not just a new
vocabulary. If it doesn't simplify the monoid, it's decoration.

### 2. The agent programs against out-of-context data through content-addressed handles

**The idea.** A tool result is a **handle** — a digest naming a Rust-owned value in `lain-core` — and
the code-mode Ruby binding manipulates handles, materializing bytes into context *only* for the final
small answer. `corpus = load_pubmed(query)` returns a handle to 10,000 abstracts the agent **never
loads**; `corpus.filter { … }.cluster.top(5)` are Rust ops over the boundary crossed in batches
(Rust placement rule 4); only five summaries ever enter the window.

**Why it's the medical-synthesis unlock.** The agent reasons over a corpus orders of magnitude larger
than any context window, because it *orchestrates a computation whose intermediate state lives in Rust
and is content-addressed*. Two properties fall out of the substrate that a normal interpreter can't
offer:

- **Cross-branch, cross-session memoization of cognition.** Every computed value is content-addressed,
  so "have I already computed `corpus.filter(X)`?" is an O(1) store lookup. Speculative branches share
  the *computed heap*, not just the conversation prefix.
- **Handles are `Ractor.shareable` by construction** (they're digests, not mutable objects), so the
  immutability spec'd as a correctness guard becomes the enabler of zero-copy parallel exploration.

**Mechanism:** `lain-core` msgpack-RPC handles, a Polars-style lazy relation in Rust · `eval_ruby`
persistent binding, `method_missing`/delegation to forward ops to Rust (Ruby) · existing
content-addressed Store, code mode.
**Prototype path:** needs the Rust exec/data boundary (M5/M6 substrate). De-risk in Ruby with a
handle wrapper over in-memory data first, to shake out the interaction model before committing the
RPC surface.
**Risk:** the handle abstraction has to stay *ergonomic* in code mode — if the agent constantly has to
materialize to inspect, the context savings evaporate. First-class noun: `Handle` / `Ref`.
**Reference implementation:** smolagents (`references/repos/smolagents/`) already does the ergonomic
half — a persistent `state` dict with **tools *and subagents* injected as callables**, only
`_print_outputs` returning to context, behind a `PythonExecutor` ABC whose *remote* impls (E2B,
Docker) confirm the exec boundary belongs out of process. Its `local` AST-interpreter is the
cautionary case: a serious in-process sandbox its own authors still offload past — evidence for
`lain-core`, not `ext/lain`, as the trust boundary.

---

## Four more to brainstorm

### 3. Git-for-its-own-mind, as an agent *capability*

The bench forks trajectories *for* the agent; nobody gives forking *to* the agent. Expose the O(1)
DAG ops as tools: `fork_and_try(hypothesis)`, `rewind_to(digest)`, `what_did_I_believe_at(turn)`,
`diff_branches(a, b)`. The agent does **counterfactual meta-cognition on its own history** — "go back
to before I assumed the schema was normalized, take the other branch, compare." Ruby's `Binding` /
`TracePoint` / `ObjectSpace` make the *code-mode* state introspectable the same way the Timeline makes
the *conversation* state introspectable.
**Mechanism:** existing `fork`/`diverge_at`/`rewind` exposed as `Tool`s · `Binding`/`TracePoint`
(Ruby). **Prototype:** trivial once M4 exposes the DAG; can demo in Ruby today. **Risk:** giving the
agent time-travel may increase wandering — measure it against a control on the bench.

### 4. Attested context — context that cannot lie about where it came from

Every fact in the rendered prompt carries its **digest-chain** back to the `tool_result` that produced
it. Because the store is a Merkle DAG this is *structural*, not prose: a fact with no path to a
tool_result digest is, by construction, a hallucination, and a grader can **verify** that
mechanically. For medical synthesis this is the correctness spine — provenance stops being a citation
you hope is real and becomes a property the render step enforces, in the same spirit as the
output-discipline AST guard.
**Mechanism:** blake3 digest chains through the Store · a `Context` combinator that annotates blocks
with lineage · a grader that walks the chain. **Prototype:** Ruby-first over the existing Store.
**Risk:** attestation granularity — a "fact" is fuzzier than a turn; needs a crisp unit to attest.

### 5. Structural memory — recall by the *shape* of the reasoning

BM25 is lexical, vectors are semantic. The DAG enables a third modality nobody uses: **analogical /
procedural recall by subtree shape**. "The last time my trajectory looked like
`[read → grep → read → edit → test-fail]`, what did I do next?" is a subgraph-isomorphism query
(`petgraph`) over the Store, not an embedding lookup. Procedural memory keyed on the *form* of a
situation — a fifth arm for the M6 retrieval sweep that BM25/Vector/Hybrid/Graph can't express.
**Mechanism:** `petgraph` isomorphism (Rust) · trajectory-shape extraction from the Timeline.
**Prototype:** the shape-matching can be crude in Ruby first. **Risk:** subgraph isomorphism is
expensive in general; needs a cheap shape-hash to prefilter (content-addressing helps).

### 6. The self-crystallizing toolset

A successful code-mode fragment gets **crystallized into a named, digest-versioned capability**. The
toolset *grows* by freezing cognition that worked, with full provenance (this tool = this fragment,
born at this turn, from this trajectory). New swept axis: does an agent that accretes a personal,
versioned standard library outperform one with a fixed toolset — and does crystallizing *raise* the
correct-call rate the way a good hand-written description does?
**Mechanism:** content-addressed fragments promoted to `Tool`s · the existing capability model.
**Prototype:** Ruby-first; the loop is "detect reuse → propose crystallization → version by digest."
**Risk:** crystallizing bad fragments compounds error; needs the grader in the loop before promotion.
Connects to TODO.md's "promote ad-hoc scripts to helper tools."

### 7. The Workspace Timeline — a second content-addressed DAG, for files

**The idea.** Pair the conversation Timeline (the *cognition* DAG) with a **Workspace Timeline** — a
content-addressed DAG of *file-system snapshots*, one per file-modifying tool, linked to the turn
that produced it. Cline proves the value with a **shadow git repo** (snapshot the workspace after
each edit; restore to any step, untracked files included, user's git untouched). Lain can do it
**natively and better**, because the `Store` is already content-addressed — a snapshot is just
another blob keyed at a turn, no second git repo required.

**Why it's more than Cline's version.** Cline's two timelines are separate systems (editor messages +
a shadow git). In Lain they are *the same content-addressed substrate*:

- **Independent rewind of either axis** — *restore files, keep conversation* (retry an implementation
  with full context); *restore conversation, keep files* (re-prompt against good code); *restore
  both*. All three are `rewind` / `diverge_at` on the appropriate DAG.
- **`diverge_at` localizes a file divergence** exactly as it localizes a cache break — "the first
  turn where the workspace differs" is one walk.
- **Speculative branching extends to the workspace for free** — fork N trajectories and each carries
  its own snapshots, sharing the unchanged prefix by structural sharing, so beam-search over agent
  behavior includes the *files*, not just the conversation.

**The approval-economics lever.** Cheap per-step rollback is *why* auto-approve is safe ("the cost of
a mistake drops to nearly zero"). So the Workspace Timeline couples directly to `Handler::Approving`
/ `--yolo`: with per-step snapshots, tier-3 `bash` can run unattended because undo is one `rewind`.
The plan treats approval and history separately; this ties them into a swept axis — approval
strictness × checkpoint granularity → speed vs. safety.

**Mechanism:** content-address file snapshots into the existing `Store`, keyed by turn digest ·
`rewind` / `diverge_at` (have them) · a `workspace_snapshot` `Effect` after mutating tools.
**Prototype:** Ruby-first over the existing Store; no Rust needed. **Risk:** snapshot cost on large
trees (Cline warns of this) — snapshot deltas, and content-addressing dedups unchanged files by
construction. **Provenance:** Cline `checkpoints.mdx`, `checkpoint-restore.ts` (see
`references/oss-inspiration.md`).

---

## Cross-cutting

Every concept is a consequence of the same two facts: **content-addressed + pure**, and **a coding
shell whose values don't touch context**. #1 (IVM) gives the *theory* to make context management
principled instead of heuristic; #2 (handles) gives the *capability* — reasoning over corpora larger
than any window — that nothing else in the plan reaches. Those are the two to build toward first.

## De-risking

| Concept | Substrate needed | De-risk in Ruby first? |
|---|---|---|
| 1. Context as IVM | pure-Ruby Timeline (have it) | **Yes** — prove combinator laws before the Rust O(delta) port |
| 2. Handles / out-of-context data | M5/M6 Rust boundary | Partly — handle wrapper over in-memory data to fix the ergonomics |
| 3. Git-for-its-mind | M4 DAG exposure | **Yes** — demo as tools today |
| 4. Attested context | existing Store | **Yes** |
| 5. Structural memory | `petgraph` (M6) | Partly — crude shape-match in Ruby |
| 6. Self-crystallizing toolset | capability model (have it) | **Yes** — grader must gate promotion |
| 7. Workspace Timeline | existing content-addressed Store | **Yes** — snapshot files into the Store keyed by turn; `rewind` exists |
