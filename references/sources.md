# Agent harness / context / memory — Source Survey

> **Researched:** 2026-07-10
> **Scope:** see `SCOPE.md`.

Where the knowledge for this domain lives. Unlike a scientific field (~90% arXiv), agent-harness
knowledge is split roughly: ~50% arXiv preprints, ~30% engineering writeups from labs
(Anthropic, Cognition, Chroma) that never become papers, and ~20% reference implementations whose
*code* carries design ideas their READMEs omit — verified the hard way on MemPalace.

## Summary

| Source | Channel | Accessible | Unique data | Adapter |
|--------|---------|-----------|-------------|---------|
| arXiv | LaTeX src | ✅ | full text, benchmarks, algorithms | `arxiv_download.sh` |
| Lab engineering blogs (Anthropic, Cognition, Chroma, Zed) | web | ✅ | design rationale never published as papers | WebFetch → hand-written `.md` |
| Reference implementations (MemPalace, Aider, OpenHands, smolagents, goose, SWE-agent) | git | ✅ | working design ideas absent from READMEs | submodule → `repos/` |
| ACL Anthology / conference PDFs | PDF | ⚠ some manual | peer-reviewed benchmarks | `pdf_to_rst.py` |
| HN discussion (stories + comments) | Algolia API + web | ✅ | practitioner reactions, failure cases, cross-links to blogs/repos not otherwise surfaced | `hn.algolia.com/api/v1` → WebFetch → dated `.md` synthesis |

## Per-source detail

### arXiv (primary)
- **Access:** `arxiv_download.sh <id...>` → LaTeX → RST in `papers/rst/`.
- **Unique data:** the 15 papers below — orchestration (incl. AB-MCTS tree search), memory
  benchmarks, CodeAct, GEPA, harness evaluation, context-file eval (AGENTS.md), constrained
  prompting (the Guardrail-to-Handcuff inversion).
- **Priority:** primary.

### Lab engineering writeups (complementary, high-signal)
- **Access:** WebFetch; hand-synthesized into topic docs / INDEX (not stored as RST).
- **Unique data:** Anthropic (multi-agent system, code-execution-with-MCP, Agent Skills), Cognition
  ("Don't Build Multi-Agents"), Chroma (Context Rot), Zed (Agent Client Protocol). These are where
  the *design rationale* lives and are cited throughout `planning/`.
- **Priority:** primary for rationale, but not peer-reviewed — treat as engineering evidence.

### Reference implementations (`repos/`)
- **Access:** `git submodule add <url> references/repos/<name>`.
- **Unique data:** the *code*. MemPalace's README named 4 competitors and 4 benchmarks; its source
  revealed the AAAK index dialect, "signal-not-gate" retrieval, a bitemporal SQLite knowledge
  graph, and a query-sanitizer for prompt contamination — **none prominent in the README.** This
  channel is where introspection pays off; prioritize reading retrieval/context/memory cores.
- **Priority:** primary. Done: MemPalace. To introspect: see `oss-inspiration.md`.

### HN discussion survey (complementary, recurring)
- **Access:** `https://hn.algolia.com/api/v1/search?query=…&tags=story&numericFilters=created_at_i>…,points>…`
  for stories; `…/api/v1/items/<id>` for a full nested comment tree. Digest into a **dated** `.md`
  (news ages), labelled ⚠️ LLM-generated. Runs: `hn-agent-landscape-2026-07.md` (first),
  `hn-agent-landscape-2026-08.md` (2026-07-18 → 2026-08-06).
- **Window each run from the previous run's date and write the delta**, not a re-survey. Carry the
  previous runs' story IDs as an exclusion set; the 2026-08 run excluded 27 and still shortlisted 42
  from 367.
- **Run a query-free sweep alongside the topic queries.** `search_by_date&tags=story` at a high
  `points>` floor catches what the topic terms miss, and it is not a marginal supplement: in the
  2026-08 run **10 of the 20 threads that made the writeup matched no topic query**, including the
  session-portability post, the Codex context-window cut and the Copilot-worm disclosure. Topic
  queries alone are a filter shaped like the *previous* run's vocabulary, so they systematically
  miss whatever the window is actually about.
- **⚠️ Algolia prefix-matches ONLY the last token of a query; earlier words need an exact token
  match.** This silently gutted the 2026-08 run's topic sweep: `"agent harness"` returns 6 hits and
  **does not find "Building an Advanced Agentic Harness"**, because `agent` ≠ `agentic` in
  non-final position. `"harness agent"` finds it (now `agent` is last and prefix-matches), and bare
  `"harness"` finds it among 16. Every 2–3 word query whose *non-final* word needed stemming —
  `agent loop`, `agent framework`, `agent sandbox isolation`, `LLM agent memory` — under-returned
  the same way, with no error and a plausible-looking hit count. **Prefer single-word queries**, or
  put the stem-needing term last, and accept the precision cost: bare `MCP`/`TUI`/`RAG` match inside
  URLs and author names, so a single-word sweep needs a title filter afterwards.
- **The query-free floor was set too high.** The 2026-08 run swept `points>250`, which structurally
  could not see a 122-point post. A second pass at `points>100` (query-free) plus stem-safe single
  words returned **566 stories the first sweep never produced, ~79 of them SCOPE-plausible** — an
  entire second tier the first pass was blind to. Sweep the 100–250 band.
- **Points are a poor relevance proxy in both directions.** The single best statement of grader
  discipline in the 2026-08 window came from a **59-point** Show HN's author comment; several
  700-point threads yielded nothing. Rank the shortlist by SCOPE fit, then read.
- **Unique data:** practitioner *reactions* — failure cases, benchmarking-methodology critiques, and
  outbound links to lab blogs / repos / arXiv that never reach the HN front page. The comment
  cross-links were higher-signal than several top-level stories (swyx's loopcraft taxonomy, zby's
  agent-memory-systems reviews, the yoloAI/Gondolin isolation repos).
- **Priority:** complementary; a periodic radar, not a canon. Treat as engineering evidence.
- **Gotchas (verified the hard way):** (1) an unencoded `>` in `numericFilters` is a **shell
  redirect** — URL-encode as `%3E`. (2) The Algolia item cache occasionally resolves a stale/ wrong
  story for an ID — verify the returned `title` matches. (3) Comment links are stored as
  **entity-encoded visible text** (`&#x2F;`), often **without an `http://` scheme** and with no
  `href` — `html.unescape` the text *before* regexing, and match scheme-less domains, or you find
  ~1 link where there are hundreds. (4) `http://export.arxiv.org/api/query` returns an **empty
  body** from this environment while `https://` works — vetting comment-mined arXiv IDs silently
  produced "NOT FOUND" for all ten until the scheme was changed.

## Recommended acquisition order

1. arXiv batch (automated) — done, 12 papers.
2. Reference-implementation code introspection — MemPalace done; Aider/OpenHands/smolagents/goose
   next (`oss-inspiration.md`).
3. Lab writeups — folded into `planning/` + INDEX as engineering evidence.

## Coverage gaps

- **No PHI-safe medical-corpus retrieval benchmark** exists in the pulled set; LongMemEval / LoCoMo /
  MemBench / ConvoMem are conversational. The medical transfer target needs its own fixture
  (flagged in the plan's open questions).
- **Harness-variance measurement** is asserted by 2605.23950 but no released harness *quantifies* it
  — this is Lain's opening (see INDEX, expert/community section).
