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
- **The HN channel feeds this one.** The 2026-08-18 run mined **20 arXiv IDs** out of comment
  threads; SCOPE vetting kept **7** and rejected 13 as non-goals (LoRA, *Textbooks Are All You
  Need*, LittleLearner — training/fine-tuning; a Turing-test study; interpretability of integer
  addition; a physics-census paper that arrived via an off-topic thread). The 7 landed as
  `2608.13122`, `2602.16284`, `2607.03502`, `2510.24941`, `2604.15726`, `2512.11280`, `2607.05147`
  — see INDEX. **Vet before downloading:** a comment-mined ID is a *mention*, not a citation, and
  the majority did not survive `SCOPE.md`'s non-goals.
- **⚠️ Use `https://export.arxiv.org/api/query`** for metadata vetting — `http://` returns an empty
  body from this environment and every ID silently reads as NOT FOUND (already recorded under the
  HN channel's gotchas; it bit again here and the `https` form worked for all 21 IDs).
- **Priority:** primary.

### Lab engineering writeups (complementary, high-signal)
- **Access:** WebFetch; hand-synthesized into topic docs / INDEX (not stored as RST).
- **Unique data:** Anthropic (multi-agent system, code-execution-with-MCP, Agent Skills, the
  >80% system-prompt removal), Cognition ("Don't Build Multi-Agents"), Chroma (Context Rot), Zed
  (Agent Client Protocol), **Databricks (coding-agent benchmark on their own multi-million-line
  codebase — the strongest third-party *measurement* of harness-induced cost variance: >2× cost per
  task at equal quality from swapping the harness alone)**. These are where the *design rationale*
  lives and are cited throughout `planning/`.
- **Priority:** primary for rationale, but not peer-reviewed — treat as engineering evidence.

### Reference implementations (`repos/`)
- **Access:** `git submodule add <url> references/repos/<name>`.
- **Unique data:** the *code*. MemPalace's README named 4 competitors and 4 benchmarks; its source
  revealed the AAAK index dialect, "signal-not-gate" retrieval, a bitemporal SQLite knowledge
  graph, and a query-sanitizer for prompt contamination — **none prominent in the README.** This
  channel is where introspection pays off; prioritize reading retrieval/context/memory cores.
- **Priority:** primary. Done: MemPalace. To introspect: see `oss-inspiration.md` — where
  **ThoughtDAG** is now the highest-value new candidate, being the closest external analogue to
  `Context#render` found so far (`hn-agent-landscape-2026-08-18.md` §2.3).

### HN discussion survey (complementary, recurring)
- **Access:**
  `https://hn.algolia.com/api/v1/search?query=…&tags=story&numericFilters=created_at_i>…,points>…`
  for stories; `…/api/v1/items/<id>` for a full nested comment tree. Digest into a **dated** `.md`
  (news ages), labelled ⚠️ LLM-generated. Runs: `hn-agent-landscape-2026-07.md` (first),
  `hn-agent-landscape-2026-08.md` (2026-07-18 → 2026-08-06),
  `hn-agent-landscape-2026-08-14.md` (2026-08-06 → 2026-08-14),
  `hn-agent-landscape-2026-08-18.md` (2026-08-13 → 2026-08-18).
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
- **Both corrections above were applied in the 2026-08-14 run and worked.** Single-word queries at
  `points>40` plus a query-free sweep at `points>100` returned 538 raw hits and **369 distinct
  stories in an 8-day window** — comparable to the 367 the 2026-08 run got from 19 days, which is
  the measure of how much the first sweep was missing. Note the exclusion set stops mattering once
  the window starts at the prior cutoff: **exactly 1 of 68 carried IDs reappeared**. Keep carrying
  it anyway; its job is guarding the boundary, not filtering the body.
- **Scale the `points>` floor to the WINDOW, not to the number written down.** The floors above
  were tuned on 8- and 19-day windows. The 2026-08-18 run covered **5 days** and dropped the
  query-free floor to **`points>50`**, which was the right call: the window's two most useful
  threads were a **41-point** cost thread and a **91-point** benchmarking post, both invisible at
  100. Yield held up — 581 raw hits, **318 distinct stories in 5 days** against 369 in 8 — so a
  short window does not mean a thin sweep, it means a lower cut. **Overlap the previous cutoff by
  a day** rather than starting exactly at it; the 2026-08-18 run started at 2026-08-13 against a
  2026-08-14 cutoff and re-caught exactly 1 story, which is what a guarded boundary looks like.
- **⚠️ Do NOT rank comments by LENGTH when digesting a thread — it is a worse proxy than points.**
  The 2026-08-18 run's digest script kept the **longest 45 comments per thread**, rendering only
  **1,327 of 5,838 comments (23%)** and silently discarding the rest. Length tracks rambling
  opinion, not value: the shapes this corpus most wants — a named command and what it
  mechanically does, a measured ablation, a repo link, one commenter correcting another with
  specifics — are usually SHORT, and were therefore structurally invisible. The miss was not
  hypothetical: the Pi compaction thread's comments name **four selectable compaction strategies**
  and a `/handoff`-to-a-new-session workflow, and none of it reached the first draft even though
  the thread was the run's most-quoted source. **Digest the whole tree**; if a thread must be cut,
  cut by depth or by subtree, never by comment length. Better still, extract by SHAPE first — grep
  every comment for `/command` tokens, numbers with units, and links — then read the remainder.
- **Audit a finished survey against the raw trees before folding it.** A cheap check that would have
  caught the above: count comments per thread, count how many the digest rendered, and list every
  fetched story whose id never appears in the written survey. The 2026-08-18 run had **5 fetched
  threads (568 comments) cited nowhere at all**, which is a different and more obvious failure than
  the sampling one and takes one script to detect.
- **Read the shortlist for METHOD comments, not only for topic matter.** Two of the highest-value
  items in the 2026-08-18 window were methodological asides on stories whose *subject* was
  mundane: a complete freeze-list for agent benchmarking buried in a reply to a model-comparison
  blog post, and a measured cache ablation buried in a compaction thread. Neither story's title
  predicts its best comment, which is the mechanical reason the shortlist has to be read rather
  than skimmed by headline.
- **The points floor has a measured miss rate, and it is not small.** The 2026-08-18 run was checked
  against a hand-supplied list of 14 stories: 6 already covered, 4 fetched-then-dropped, and **4 the
  sweep never returned — 3 of them below the floor at 17, 11 and 7 points.** Two were worth writing
  up, including a **7-point, zero-comment** post carrying a real controlled experiment (n=15) on
  whether agent-addressed documentation changes model behaviour. The third was correctly ignorable,
  which is the difficulty in one line: **you cannot tell which is which without looking.** What this
  corpus wants — small controlled experiments, Show HN implementations, arXiv links — is
  systematically *low-attention*, so the floor is biased against exactly the material with the best
  evidence-per-word. **Mitigations that cost little:** run one extra query-free pass with **no
  points filter** restricted to `show_hn` and to `url:arxiv.org`, and treat a human-supplied list
  as a *complement* to the sweep rather than a duplicate of it.
- **A shortlist pass can miss an in-sweep story too.** `arXiv:2608.13122` (250k-line GPU port,
  validation-centric agent workflow) was returned at 56 points and passed over on title alone; it
  turned out to be the strongest verification-loop source in the window. When a title names a
  *domain* rather than a mechanism, open it — the mechanism is what SCOPE matches on, and titles
  rarely carry it.
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
  story for an ID — verify the returned `title` matches. (3) **CORRECTED 2026-08-18 — mine the
  `href`, not the rendered text.** An earlier edition said comment links are stored as
  entity-encoded visible text "with no `href`". That is **wrong**, and believing it cost the
  2026-08-18 run real work (URLs recorded as unrecoverable, one "recovered" by search). Measured
  across all 36 threads of that window: **537 anchor tags, every one carrying a complete `href`**,
  while **151 had truncated anchor *text*** — HN elides long URLs for display only. Both href and
  text are entity-encoded (`&#x2F;` for `/`), so `html.unescape` is still needed — but parse
  `<a href="...">` and **ignore the anchor text**. The scheme-less-matching advice still applies to
  bare URLs typed in prose, which carry no anchor tag at all.
  (4) `http://export.arxiv.org/api/query` returns an **empty body** here while `https://` works — vetting comment-mined arXiv IDs silently
  produced "NOT FOUND" for all ten until the scheme was changed.

## Recommended acquisition order

1. arXiv batch (automated) — done. **26 papers** after the 2026-08-18 batch (7 from the first pass,
   2 from the comment re-audit, 2 more mined out of a surveyed repo's own citations).
2. Reference-implementation code introspection — MemPalace done; Aider/OpenHands/smolagents/goose
   next (`oss-inspiration.md`), plus **ThoughtDAG** as the newest candidate.
3. Lab writeups — folded into `planning/` + INDEX as engineering evidence.

## Coverage gaps

- **No PHI-safe medical-corpus retrieval benchmark** exists in the pulled set; LongMemEval / LoCoMo
  /
  MemBench / ConvoMem are conversational. The medical transfer target needs its own fixture
  (flagged in the plan's open questions).
- **Harness-variance measurement** is asserted by 2605.23950 but no released harness *quantifies* it
  — this is Lain's opening (see INDEX, expert/community section).
