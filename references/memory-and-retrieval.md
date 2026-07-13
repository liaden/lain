# Memory & retrieval — synthesis for Lain's M6 sweep

Five benchmarks, one temporal-KG system, and a code-level read of MemPalace, synthesized for the
question the plan calls "likely the highest-value thing the bench ever measures": which retrieval
strategy wins, on what ability, at what token cost — and where Lain's content-addressed, versioned,
PHI-constrained memory should *win rather than merely claim elegance*.

## The abilities a memory grader must separate

LongMemEval (2410.10813) is the anchor taxonomy — five abilities, and current systems drop ~30%
across sessions:

1. **Information extraction** — is the fact retrievable at all.
2. **Multi-session reasoning** — synthesize across sessions.
3. **Temporal reasoning** — order and time-scope facts.
4. **Knowledge updates** — a later fact supersedes an earlier one.
5. **Abstention** — know when the answer is *not* in memory (ConvoMem, 2511.10523, makes this a
   first-class category; critical for medical synthesis).

MemBench (2506.21605) adds an orthogonal cut — factual vs. reflective memory, participation vs.
observation — and, valuably for Lain, grades **capacity/efficiency**, not just recall. LoCoMo
(2402.17753) supplies the long-horizon extreme (≈300 turns / 35 sessions, grounded on temporal
event graphs — a reusable recipe for synthetic fixtures that keeps PHI off the wire).

**For Lain:** adopt LongMemEval as the primary grader; add ConvoMem's abstention and MemBench's
capacity axis. `knowledge-updates` and `temporal-reasoning` are the two where content-addressing
should measurably win.

## Two architectures for the "knowledge-updates / temporal" win

The plan claims content-addressed, versioned memory handles knowledge-updates natively (a
superseded fact is a new root hash; the old value stays addressable). Two external designs are the
baselines to beat:

- **Zep / Graphiti (2501.13956)** — a **bitemporal knowledge graph**: entities and typed edges
  carry validity intervals, so "what was true as-of T" is a graph query. +18.5% on LongMemEval,
  −90% latency vs. a full-context baseline. Cloud, Neo4j.
- **MemPalace `knowledge_graph.py`** — the same idea, local and free: SQLite triples
  `ENTITY —predicate→ ENTITY` with `valid_from / valid_to`, queried `as_of` a date, each edge
  linking back to the verbatim drawer. Explicitly framed as "what competes with Zep's temporal KG."

**For Lain:** run *both* as arms — explicit bitemporal validity (Zep/MemPalace style) vs. Lain's
implicit versioning-by-content-address — on the LongMemEval knowledge-updates split. The plan's
"what did I believe at turn N" (Journal records the live memory root per turn) is the same query as
Zep's `as_of`; the experiment is whether content-addressing gets it for free where the KG pays with
schema.

## MemPalace, read at the code level — borrowable designs the README omits

Introspecting `references/repos/mempalace/` (not the README) surfaced four ideas worth stealing:

### 1. The AAAK index dialect — a concrete `Manifest`
`dialect.py` defines a compact symbolic summary format any LLM reads without a decoder:
```
Zettel:  ZID:ENTITIES|topic_keywords|"key_quote"|WEIGHT|EMOTIONS|FLAGS
Tunnel:  T:ZID<->ZID|label
```
It is an explicitly **lossy pointer layer** (`closets`) over verbatim content (`drawers`) — you
scan thousands of compressed pointers in-context and only open the drawer you need. This *is* the
plan's `Manifest` index ("one-line descriptions in context; `memory_read(id)` for the body"),
already designed. The **Tunnel** notation (`T:ZID<->ZID`) is literally Lain's `[[wikilink]]` Graph
index. **For Lain:** a battle-tested schema for the `Manifest` and `Graph` arms — including that the
index is *cache-stable* precisely because it is a deterministic projection of content.

### 2. "Signal, never a gate" — a retrieval-safety invariant
From `searcher.py`: the verbatim-content query is the **floor** and always runs; the auxiliary
index (`closets`) only adds a **rank boost** when it agrees — it can *never filter out* a drawer
the direct path would have found. "Weak closets (regex extraction on narrative content) can only
help, never hide." **For Lain:** this is the loud-failure / Null-Object ethos applied to recall —
an index bug degrades ranking, never suppresses truth. Adopt it as a hard rule for every retrieval
arm, so a broken index can't silently hide a fact (unacceptable for medical work).

### 3. BM25 as a *candidate-local reranker*, plus candidate-union
`_bm25_scores` computes IDF over the **returned candidate set**, not a global corpus, so BM25
reorders vector hits by within-candidate discriminativeness. `candidate_strategy="union"` widens the
pool's *source* by merging BM25-only hits the vector search missed (carried with `distance=None`),
then hybrid-ranks the union; a **recency fallback** covers lexical-match failure. **For Lain:** a
clean hybrid design for the `Hybrid` arm that needs no global BM25 index — reranking, not a second
retrieval system.

### 4. The query is an injection surface — `query_sanitizer.py`
A real, sharp failure (their Issue #333): an agent prepends a 2000-char system prompt to a 10–50
char query; the embedding is dominated by the prompt; recall collapses **89.8% → 1.0%** silently.
Staged mitigation (passthrough ≤200 chars → question-mark extraction → tail sentence → truncation)
recovers to 70–89%. **For Lain:** the plan says "recall must be pure"; this adds "the *query* must
be clean." A contaminated query is a silent recall cliff the bench should measure and a sanitizer
the pipeline should include — retrieval safety the plan doesn't yet name.

### 5. L0–L3 wake-up stack — progressive disclosure for memory
`layers.py`: L0 identity (~100 tok, always) · L1 essential story (~500–800, always) · L2 on-demand
per wing/topic · L3 full semantic search. Wake-up ≈600–900 tokens, "leaves 95%+ of context free."
**For Lain:** progressive disclosure applied specifically to *memory* with concrete budgets —
complements the Agent Skills tool-disclosure axis and the IVM framing (only materialize the layer
the delta needs).

## What to run (M6)

| Arm | Source of design | Where it should win |
|---|---|---|
| `Manifest` (AAAK-style symbolic index) | MemPalace `dialect.py` | cache-stability, cheap, deterministic — the default |
| `BM25` / `Hybrid` (candidate-local rerank + union) | MemPalace `searcher.py` | exact drug/gene names; lexical > semantic |
| `Temporal KG` (bitemporal validity) | Zep, MemPalace `knowledge_graph.py` | temporal-reasoning, knowledge-updates |
| `Content-addressed versioning` (Lain-native) | the plan | knowledge-updates *for free*, replayable `as_of` |
| `Vector` / graph-expansion | LongMemEval baselines | multi-session semantic recall |

Grade all arms on the LongMemEval abilities + ConvoMem abstention, scored as **recall@k and tokens
spent on recall**, as distributions. Enforce "signal-not-gate" and query sanitization across every
arm. Keep every fixture synthetic — PHI must never enter a committed cassette or memory store.
