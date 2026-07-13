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

## Per-source detail

### arXiv (primary)
- **Access:** `arxiv_download.sh <id...>` → LaTeX → RST in `papers/rst/`.
- **Unique data:** the 12 papers below — orchestration, memory benchmarks, CodeAct, GEPA,
  harness evaluation.
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
