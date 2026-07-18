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
  (news ages), labelled ⚠️ LLM-generated. First run: `hn-agent-landscape-2026-07.md`.
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
  ~1 link where there are hundreds.

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
