# Spec — Behavioral & verification graders

> Status: `[exp]`, stub. Extends the M3c grader surface (`Grader::Fixture` 3c-5.3, `Grader::Rubric`
> 3c-5.4, the attested-context grader 3c-5 / `first-class-concepts §4`). Companion to `ROADMAP.md`
> (M3c + M5) and `planning/hn-agent-landscape-2026-07.md` (Tier-1 #1). Unit IDs `GR-<n>`.

## What it is

Three graders the field surfaced that Lain's content-addressed DAG + NDJSON Journal make uniquely
cheap. All operate **offline over the Journal** — none change the agent loop, and all are
`DryReplay`-substitutable (their inputs are recorded turns, not live calls). They are graders and
analyses, **not** an axis: they score arms, they are not themselves arms.

The premise these share is Lain's edge over flat-log harnesses: because every turn is
content-addressed with `spawned_from` lineage and each fact can trace to a `tool_result` digest, a
grader can attribute an observed signal **back to the turn that caused it** — which forum tools and
single-pass log scrapers structurally cannot.

## Units

- **GR-1 — Two-pass verification wrapper.** A generic decorator over any `Grader::Rubric` (or finding
  producer): a second, independent pass is prompted to *refute* each flagged finding; the finding
  counts only if it survives. This is the adversarial-verify / false-positive filter, reusable by
  every rubric grader on the bench — not specific to one experiment. Source: Traceforce pentester's
  "second verification agent"; mirrors Lain's own review-panel process.
  **Acceptance:** wrapping a rubric that emits N raw findings yields ≤ N verified findings, each
  carrying its refutation verdict; a fixture with a known-false finding is dropped; the verdicts are
  journaled and `DryReplay` reproduces the filtered set byte-identically.

- **GR-2 — Tool-steering detector.** A Journal analysis that diffs each tool's *declared*
  schema/description against its *observed selection frequency* across a run (or corpus of runs), and
  flags tools that win calls out of proportion to their stated purpose (the "vendor steering hidden
  in the tool description" case). Pure read over recorded `tool_use` events; no model call required
  for the base heuristic (an optional oracle pass can score description/behaviour mismatch).
  **Acceptance:** on a fixture where one tool's description over-claims and it is selected far above
  its share, the tool is flagged with its observed-vs-declared ratio; a well-behaved toolset produces
  no flags; deterministic over committed fixtures.

- **GR-3 — Frustration/repair grader with causal attribution.** Detects behavioural failure signals
  in a transcript — rephrase-loops, self-corrections, abandonment — as scored eval signals, then
  walks each signal **back through the DAG** (`diverge_at` / `spawned_from`) to the earlier turn that
  most plausibly caused it (e.g. a poorly-recovered tool failure several turns upstream). The
  attribution is the differentiator; the detection is the cheap part.
  **Acceptance:** on a fixture where a tool failure at turn *i* produces a rephrase-loop at turn
  *i+k*, the grader reports the signal at *i+k* and attributes it to turn *i*; the causal walk is over
  content-addressed lineage, not turn ordinal proximity; result is deterministic.

## Open questions

- **GR-1 locus.** Is the refutation pass an oracle (`specs/oracles.md` — haiku/ollama one-shot behind
  `ask_human`) or a full `Grader::Rubric`? Likely the oracle seam, so the cost shows in the
  decider-locus sweep (OR-4) and `DryReplay` substitutes recorded verdicts.
- **GR-3 signal taxonomy.** Which behavioural signals are mechanical (regex/loop-detection over the
  Journal) vs. need an oracle? Keep the mechanical floor deterministic; gate the fuzzy ones behind an
  oracle so the whole grader stays replayable.
- **Shared substrate.** GR-2 and GR-3 both want a "tool-call events + outcomes, indexed by lineage"
  projection of the Journal — the same projection the Journal-native retrieval work (M6, Tier-1 #4)
  needs. Build it once.
