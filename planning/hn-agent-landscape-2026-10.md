# The agent-harness field, September and October 2026: what two scans are worth to us

> **Status (2026-10-16):** proposed, not folded. Near-term-sequence item 60 in `ROADMAP.md`
> points here. No milestone row or axis row has been edited; each tier below says where its items
> would land, and folding them needs a per-item decision.

> Companion to [`hn-agent-landscape-2026-08.md`](hn-agent-landscape-2026-08.md), which reconciled
> the August scans. This doc covers the two scans since:
> [`references/hn-agent-landscape-2026-09-22.md`](../references/hn-agent-landscape-2026-09-22.md)
> (plan items 40 to 63) and
> [`references/hn-agent-landscape-2026-10-16.md`](../references/hn-agent-landscape-2026-10-16.md)
> (plan items 64 to 90). Per-thread evidence and the "→ Lain" readings live in those files
> (⚠️ LLM-generated, verifiable story IDs). Nothing here re-proposes what the August doc folded.

**Why this doc exists is, again, the first finding.** The 2026-09-22 scan proposed 24 plan items
and was committed without an INDEX entry, a `sources.md` line or a ROADMAP line, so for 4 weeks
it was invisible to anyone reading the plan. This doc reconciles it alongside the October scan.

**The two windows agree on the shape of what is missing.** As in August, almost nothing new is a
mechanism. The seams exist; what the field keeps surfacing is what Lain does not yet measure
(cost per solved task, intervals, calibration, time to stop), what it does not yet assert (a
child never outranks its spawner, a message never grants capability, a confined command cannot
reach the harness's own sockets), and which numbers it prints wrongly (the 5.5 price table).

---

## Tier 1: fixes with known answers

These need a card, not research. Each claim was checked in the tree on 2026-10-16.

| item | what | evidence in Lain | lands under |
|---|---|---|---|
| 64 | Price and window rows for the Claude 5.5 family, a prompt-size price tier, a freshness check | `lib/lain/price_book.rb:42-44` prices opus at $5/$25 and haiku at $1/$5; `lib/lain/context_window.rb:63` gives haiku 200k. The 5.5 launch pages give $4/$20, $2/$10, $0.10/$0.50 and a 1M haiku window | `## Near-term sequence`, beside item 32's pricing note |
| 65 | Wire pass for 5.5: `stop_details`, gate forced `tool_choice`, thinking-only `max_tokens` as a failed turn, `fallback` block, append-only render under preserved thinking | forced `tool_choice` set by structured output in `anthropic_encoding.rb`; Opus 5.5 rejects it with a 400 (launch docs) | `### M3b` (transport fork) |
| 66 | `max_cost`, a `:stuck` breaker, a fan-out width cap and shared subtree ceiling, and "a child never outranks its spawner" | `Agent::Budget` has `max_iterations` and `max_total_tokens` (nil by default); `Subagent` caps depth only | unparks M3c's "per-effect external-$ budget + recursive subagent ceiling" |
| 68 | `Compare` prints n, an interval, cost per attempt and per solved task, tokens per solved task, fallback share | `lib/lain/compare.rb` `Distribution` has n, mean, median, min, max | `### M3c` |
| 80 | Kill the whole process tree and prove it empty | `Shell::Out` and `Shell::Pipeline` signal the group; `planning/specs/bash-confinement.md:1129` lists the leak as a risk with no remedy | ROADMAP item 59 |

## Tier 2: research before planning

Each is a design fork the field has not measured and Lain can.

1. **DNS, UDP and control-plane reach under bash confinement** (item 79). The committed plan's fence
   limits TCP by port and blocks abstract sockets and signals, but the bwrap stage has no network
   namespace and Landlock does not govern UDP. OpenAI's agent escaped through DNS. Measure the
   three arms (TCP fence only, plus `--unshare-net`, plus an allowlist resolver) with a nonce-name
   and raw-UDP canary, and probe whether a confined command reaches Lain's input and approval
   sockets. Feeds item 59 before its cards are cut.
2. **A five-arm compaction sweep, scored on the cache** (item 74). Model summary, summary plus a
   findings note, CliffCompaction-style truncate-only (arXiv `2609.26779`, MIT repo), state-only
   rendering, notes plus a fresh window; trigger at none, 25%, 50%, or handoff. Nobody has measured
   the cache cost of any of them, and Lain's content-addressed Timeline is built to.
3. **Provenance labels against the approval judge** (item 83). A replay gateway that labels each
   argument with the Event it came from stopped 98.5% to 99.8% of hijacked calls; classifiers
   stopped 26% to 70%. Replay the public 121-case tamper corpus and Lain's journaled `bash` calls
   through labels, judge, and both. Extends the approval-layering research.
4. **A short spike: can a local model be a calibrated judge?** (item 72). Requires `logprobs` in
   `Provider::Ollama` first; then measure whether a 1-token verdict read from `qwen3:4b`
   probabilities is calibrated on journaled approval calls.

## Tier 3: bench additions, ordered by how much evidence each carries

| item | what | extends |
|---|---|---|
| 69 | Session header records served model id and release date, effort sent, harness digest and env hash, local weights digest and quant, isolation tier, reachable credentials, observed network | 58, item 31's freeze list |
| 70 | Scheduled drift canary with Livenerf's rule (99% interval in 2 consecutive windows, effect of at least 3 points), restarted on a model id change | 58 |
| 71 | Graders: refuse best-of-k, hash the grader, hide the arm label, verified tree digest, fault-injection arm with an at-most-once check, refusals as outcomes, catch items | 43 |
| 72 | Calibration (Brier, ECE) for every judge; a stand-in sweep; a Clopper-Pearson disagreement bound before a cheap model replaces an expensive one | 44 |
| 73 | Length-matched placebo and multiple-comparison correction for skill arms; canary-word render spec; instruction bytes before first tool call | 52 |
| 75 | Tool-result shape task, comment-stripping view arm, disclosure distractor axis, MCP description digest | 50, 57 |
| 76 | Code mode as an arm (`eval_ruby` does not exist yet) | M5 code mode |
| 77 | Effort as a cache-safe axis; per-spawn effort and model; the OpenAI-compatible provider ROADMAP names (absent from `lib/lain/provider/`); computed context size for hop-summing providers | 40, 56 |
| 78 | Memory keyed by subject against by source digest, graded on uptake and carryover | 61 |
| 81 | Tripwire: time from hit to stop, an arm where a hit refuses the next Provider call, no excluded environment, registry-recency signal | 59 |
| 82 | Launcher isolation tier with a floor; microVM guest with no NIC | 59 |
| 84 | Credential broker arm | 47 |
| 85 | Fork-and-flush and kill-and-resume fan-out arms; notes-to-fresh-instance ablation | 53, 55 |
| 86 | Delegation law covers messages; team@k arm | 53, 54 |
| 87 | Measure workspace lease cost and merge scaling before building | 28, 60 |
| 88 | Cheap-worker and router arms at equal dollars | 42 |
| 89 | Cache-hit by provider route; never-read cache writes | 56 |
| 90 | Unattended-loop levers as arms | new, M5 |
| 67 | Judge denial circuit breaker; flood arm | 46 |

---

## Reconciliation of the 2026-09-22 items against the plan

Checked 2026-10-16 against `ROADMAP.md`, `planning/specs/` and `lib/`. **24 items: 0 covered,
18 partial, 6 new.** 3 of the partial items cite code that has since moved.

| item | summary | status | evidence | would land under |
|---|---|---|---|---|
| 40 | Lead with cost at matched success, print the MDE, add an initial-context bytes column | partial | matched spend at ROADMAP.md:59-63; cost is a `Compare` metric (`compare.rb:157-165`); no initial-context column, no MDE | `### M3c` |
| 41 | Paired statistics in `Compare` | new | `compare.rb:122-146` `Distribution` has n, mean, median, min, max; refuses n<2 | `### M3c` |
| 42 | Score a mid-trajectory swap only with same-model control forks; `DryReplay` is not a swap scorer | new | no control arm in `bench/speculative.rb` or `decider_sweep.rb` (grep); no limit stated in ARCHITECTURE | `### M3c`, ARCHITECTURE Bench |
| 43 | Solve rate; tri-state outcome; grade from the Effect log; honeypots; impossible-task arm | partial | behavioral graders at ROADMAP.md:281-287; `Grader::ToolCallIndex` pairs calls with outcomes; no tri-state, honeypot or impossible-task arm | `### M3c` |
| 44 | Judge hygiene: no prior grade, different family, test-retest flip rate, enumerate facts | partial | (a) holds by construction in `grader/rubric.rb:11-16`, unpinned by a spec; (b) to (d) absent | `### M3c` |
| 45 | Compaction summary as `user` role is a privilege path | new | still true at `context/compact.rb:93` (was :91); no planted-instruction spec | `### M3c`, `### M5` |
| 46 | Give the approval judge loop-level state | partial, citation moved | `auto_surface.rb` deleted 2026-10-15; `CONTEXT_MODE = :fresh` at `approval/judge.rb:22` and `gate/adjudicator.rb:56`; `RememberedDenials` and the planned `Tripwire::Ledger` do not feed the judge | ROADMAP item 59 |
| 47 | Mask secrets in command output | partial, premise half wrong | `GUARDED_TOOLS = Set["read_file"]` still at `redact_secret_reads.rb:68`, but `WithholdAutomaticOutput` (2026-09-15) already withholds credential-shaped `bash` output after an automatic allow; missing: masking, human-approved calls, an enrolled-literal mask | secret boundary; bash-confinement follow-ups |
| 48 | Five-tier context sweep with a budget axis; journal recall invocation rate | partial | strategies exist (ROADMAP.md:1505-1509); no tier-by-budget sweep, no invocation-rate field | `### M6`, `### M3c` |
| 49 | State-only render arm | new | no such combinator in `lib/lain/context/` | `### M3c` |
| 50 | Deferred disclosure arms by toolset size; result-shape axis | partial | `bench/disclosure_sweep.rb` has upfront and deferred only | `### M3c` |
| 51 | Instruction framing and reminder cadence; contamination grader | partial | role-assignment axis row; `Context::Reminder` tail-injects; no cadence, disclaimer or contamination factor | `### M3c` |
| 52 | Skill lift with CI and negative-lift share; record instruction sources | partial | hermetic baseline proposed in item 31, unfolded; no instruction-source header field | `## Near-term sequence` |
| 53 | Sibling-visibility axis; model-heterogeneous teams | partial | decorrelation row names model-heterogeneous; no visibility arms | `### M5` |
| 54 | Delegation law; prohibited sequences | partial | `Toolset#only/#except` attenuate down (`toolset.rb:79-96`); no seam spec over spawn, no sequence primitive | `### M5` |
| 55 | State what a resume restores | new | no per-resume guarantee in ARCHITECTURE; the Workspace staleness ledger is the carrier | `### M4` |
| 56 | Validate the cache meter against the bill; attribute misses by gap | partial | `prefix_digests` journaled; no prediction-against-bill check | `### M3c` |
| 57 | Token-saving arms on the bill; tool-use precondition; MDE before a sweep | partial | `Bench::Variance` has no MDE or refusal | `### M3c` |
| 58 | Provider drift against harness drift | partial | served model journaled (`agent/accounting.rb:55`, from `anthropic_wire.rb:76`); no mismatch flag, no canary | `## Near-term sequence` |
| 59 | Local-arm discipline, 7 parts | partial | (g) covered (`ollama/encoding.rb:72-83`); (b) `prompt_eval_count` read but not compared; (a), (d), (e), (f) absent | `### M6` |
| 60 | Isolation rules: inference endpoint, `python3 -I`, tool-config run files, overlay by head | partial, citation moved | build-file residual is in `shell/programs.rb:22-31`, not `verdict.rb`; the bash-confinement plan covers hooks and run files; not the ollama port, `python3 -I`, `.yardopts`/`.rspec` | ROADMAP item 59 |
| 61 | Memory: Hybrid must beat Bm25; source-digest supersession; graders | partial | arms exist; no gate, no source-digest invalidation | `### M6` |
| 62 | Benchmark against own releases; grade optimiser output on a held-out safety set | new | no per-tag task set | `## Research tracks` |
| 63 | Over-ask rate by replaying journaled `bash`; env-prefix and delayed-write specs | partial | replay driver only proposed; env assignments abstain to a human (`shell/parse.rb:47`) with no named spec | ROADMAP item 59 |

Items 42 and 45 were checked for existing coverage by grep, not by reading every sweep file.

## Corrections to the source scans

- **Item 46** cited `lib/lain/approval/auto_surface.rb:25`. The file was deleted on 2026-10-15;
  the finding (a fresh-context judge) still holds at `approval/judge.rb:22`.
- **Item 47** said `bash` output is not scanned. `Middleware::WithholdAutomaticOutput` predates
  the scan and withholds credential-shaped output after an automatic allow. What is missing is
  masking rather than withholding, and coverage of human-approved calls.
- **Item 60** placed the build-file residual in `shell/verdict.rb`. It is in
  `shell/programs.rb:22-31`.
- **The October readers' egress finding was narrower than first reported.** One reader said the
  bash-confinement plan had no egress policy at all. The plan's fence does limit TCP by port and
  blocks abstract sockets and signals; the open channel is DNS and UDP, for want of a network
  namespace. Item 79 is written to the narrower claim.
