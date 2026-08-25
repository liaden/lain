# Follow-ups banked by wave 1 of the survey-dogfood chunk

Recorded 2026-08-25, as wave 1 landed. Each of these was found *during* the wave, ruled
out of scope deliberately, and needs its own card with its own ACs and review.

## 1. Shorten the two grandfathered refusals (C1's ratchet)

`spec/refusal_delivery_discipline_spec.rb` holds a per-sentence amnesty naming exactly two
sentences that exceed `BAR = 80`:

- **`65_review.lua`** — `:LainReviewDone`'s wrong-buffer refusal, **162 columns**, more than
  double the budget. A wrong-buffer refusal is the most ordinary thing a human hits.
- **`51_thread.lua:660`** — **131 columns**, and this is the sentence the chunk plan cited as
  *the worked conversion to copy*. The exemplar was twice over the bar.

**The rationale, and it came from a failure rather than from theory:** C1 attempted the 162-column
one mid-flight and the obvious cut was the wrong cut — it dropped `:LainReviewVerdict`, the
*remedy*, and reddened a pre-existing example. Since `fitted` keeps head-and-tail, an over-long
refusal elides its own middle, which is where the instruction lives. The model to follow is C1's
109→61 rewrite: move the *why* into a Lua comment, keep the whole remedy on the rail.

Requirements: hold `BAR` including the `lain: ` prefix; measure in a real nvim with
`strdisplaywidth`, never statically (a static measure summing both branches of a ternary invented
a third phantom exceedance that did not exist); **delete the amnesty entries** rather than lower
them — the ratchet demands it and fails if you do not. Escalation clause: if a sentence cannot
reach 80 without losing its remedy, stop and say so rather than cutting the remedy.

## 2. Cross-check `Mode::Posture::READ_ONLY` against the shipped tools

`READ_ONLY` is the **only hand-maintained registration list in `lib/` with no derived
cross-check**. Omit a tool and it silently vanishes under `/mode plan`.

The four spec-side registration points already solve this: `ToolRegistry.shipped_names` globs
`lib/lain/tools/*.rb`, and `parallel_safety_spec.rb:138` asserts the partition matches it exactly,
so they announce themselves the moment a tool file appears. Do the same for `READ_ONLY` — every
name in it must be a shipped tool, and the read-only set enumerated exhaustively — and the one
silent failure mode in tool registration becomes a loud one. Better than documenting a longer
checklist, which is what the eight-point table was drifting toward.

## 3. Extract from `CLI::Wiring`, and carry the second-wire guard with it

`Wiring` sits at **109/110 `Metrics/ClassLength`** with no line left to trade. The next card
needing space there must extract, not shave.

**The extraction must carry the guard, or the debt gets paid without the reason it was incurred.**
C2 turned `wire_agent`'s `agent` local into `@agent` so a second late reader (`usage:`) was free.
That is correct for one agent per Wiring, but the old local *kept the thunks apart*: a second
`wire_agent` now retargets agent 1's `parent:` **and** `usage:` at agent 2, so agent 1 reports
agent 2's tokens — a silently wrong number, not a crash. Unreachable today (`chat_launch.rb:332`
builds a fresh Wiring before its single `#run`). One `raise unless @agent.nil?` fixes it and trips
`Metrics/AbcSize`, which is exactly why it waits for the extraction.

## 4. Language highlighting inside `lain://diff` — route (c) only

Full investigation at `planning/notes/diff-highlighting-investigation.md`. Scope narrowly to the
legacy `:syntax include` / `:syntax region` route driven from the diff header lain already writes.
**Never a treesitter query file** (that reverses `00_constants.lua:33-39`'s recorded
no-grammar-shipped decision) and **never a dependency on the third-party `diff` parser**, which
most configs do not have and whose own `injections.scm` does not inject hunk language anyway.
Must account for coexistence with `vim.treesitter.start()` on `FileType diff`, and must treat
`spec/support/tags.rb`'s silent `:nvim` exclusion as a first-class AC constraint — an assertion
here passes or fails by machine.

## 5. Oracle spend as its own labelled figure

`StatusFeed`'s `run_tokens` deliberately excludes `Telemetry::OracleAnswer`, because that field's
contract is equality with `Accounting#usage`. Oracle spend is real money and is currently reported
nowhere. It needs its own field with its own name — not an addend to a number that promises
parity.

## 6. Session-lifetime accounting across `--resume`

`Agent::Accounting` starts at `Usage.zero` and neither `Wiring` nor `AgentBuild` passes
`accounting:`, so `--resume` gives a fresh ledger over a resumed Timeline. `session_usage` now
says so honestly ("THIS RUN", with the exclusion spelled out in the description the model reads),
but the true lifetime figure is still unreachable. Building it is real work: it means reading
prior spend back from the journal and deciding what a "session" total means across a fork.

## 7. A tolerant wire-key decoder

`StatusFeed::JournaledUsage` is the fourth hand-spelling of `Usage`'s four wire keys, and
`Usage.from_anthropic_wire` exists to stop exactly that. It was not reused because it uses
`Integer()`, which raises, and a raise inside a `JournalTee` sink unwinds into the agent loop and
costs the turn. A decoder that is tolerant by construction would let all four sites converge.

## 8. Decide whether `Compaction::Source` should match by class too

`StatusFeed#turn_usage?` is now `event.is_a?(Telemetry::TurnUsage)`, per that file's own
convention (four class matches to one open duck). `Compaction::Source#turn_usage?` still uses the
two-method duck `#usage && #stop_reason`, panel-verified 2026-07-25 and documented. The divergence
is recorded in both files as deliberate. It is worth one card to decide whether the duck should
survive there, given it is the shape that shipped a defect one file over.
