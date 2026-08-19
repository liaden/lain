# Chunk — the causal fold, and the surfaces that carry a refusal

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

Discharge QA round 5 (`planning/qa-findings-round5-2026-08-18.md`) at the level of its causes rather
than its symptoms. Three of the eight findings share one cause and one shape: **an edge, a surface or
a unit that the design treats as first-class and the implementation treats as second-class.** The
fold validates the causal edge without replaying it (F23, which strands any session that spawned);
the desktop notifier declares it notifies every approval and is structurally able to notify one
(F24); the echo rail is documented as message-area-width-bound and has no width-aware code at all
(F25). The remaining findings are small and land on top.

Roadmap line: this is the QA-discharge chunk following item 32 (the cost axis), and it closes the
first round of findings that reached `--fork`/`--resume` and the cockpit's approval and refusal
surfaces.

## Grounding

Verified 2026-08-18 against the working tree by four parallel exploration passes plus the round-5 QA
run itself. Where this section contradicts the QA findings doc, this section won.

**The fold (F23).** There are *two* rebuilders, not one: `Bench::Session::ChainFold`
(`lib/lain/bench/session/chain_fold.rb:21,28`) selects `TYPES = [turn, rewound]` and lands only
turns; `Bench::Session::MessageReplay` (`lib/lain/bench/session/message_replay.rb:123-132`) lands
`message` and `child_turn` in a second pass. `Loader#recording` (`lib/lain/bench/session/loader.rb:83-91`)
runs them strictly in that order, and its comment (`:77-80`) states the reason: a message's
`causal_parents` can name a turn. **The dependency runs both ways** — `lib/lain/agent.rb:433`
(`causal_parents: inbox.folded`) and `lib/lain/agent/tool_runner.rb:108-111,176-179` stamp a
*user-role turn* with `:message` digests — so the sequence is a cycle the ordering cannot satisfy.
`Store#validate_parents!` (`lib/lain/store.rb:92-98`) checks the whole `causal_parents` set on
`put`, and `ChainFold#recommitted` (`chain_fold.rb:79-85`) translates the resulting
`Store::MissingObject` into `Corrupt`. `MessageReplay` **already solves this exact cycle internally**
with a sweep-until-stalled solver (`message_replay.rb:81-112`) plus a `forced` remainder so the Store
raises the honest refusal; the cycle is unsolved only *across* the two passes.

This matches the approved design rather than extending it: `planning/specs/event-schema.md` records
"**Supervision / resume** = replay `render_parent` + `causal_parents` to a checkpoint (**one
mechanism**)". Today it is two mechanisms in sequence, one of which validates an edge set the other
owns.

**The gap is wrongly tested, not untested.** `spec/lain/bench/session/chain_fold_spec.rb:86-113` pins
the refusal as intended behaviour, and its own comment concedes "the message **is in the journal**,
but this fold has not replayed it into the store". That spec must be rewritten, deliberately. Its
end-to-end twin `spec/lain/cli/resume_spec.rb:794-816` is **legitimate** (it writes no `message`
record at all — genuinely dangling) and must keep passing. **No spec anywhere writes a journal
holding both a `message`/`child_turn` record and a `turn` citing it and asserts it loads** — that
absence is the coverage this chunk adds.

Structural constraint on any fix: `ChainFold` is not only landing objects, it verifies an *ordered*
chain — file order drives `rewound` checkouts (`chain_fold.rb:117-125`) and `@members`
(`:40-43,109`) feeds `Loader#on_chain?` (`loader.rb:124-126`) → `ResumeChain#prior_timeline`
(`resume_chain.rb:110-119`). A dependency-order sweep must not disturb either.

Secondary, found while grounding: `Resume#fork` rescues `Corrupt` **and** `Store::MissingObject`
(`lib/lain/cli/resume.rb:113-114`); `Resume#call`/`#rebuild` rescues only `Corrupt` (`:142-145`). A
`MessageReplay`-originated `MissingObject` on the `--resume` path therefore looks unrescued. No spec
covers it.

**The notifier (F24).** `Notify#sweep` (`lib/lain/notify.rb:212-215`) iterates the parked set with a
plain `each`; `#notify_about` → `#decide` → `#run` (`:298-303,224-226,338-344`) spawns one Thread and
immediately parks the fiber on `Thread::Queue#pop`, so element *N+1* is unreachable until element
*N*'s dunstify exits. `-t` is `Approval::Queue::DEFAULT_TIMEOUT * 1000` = **300 000 ms**
(`notify.rb:57`, `approval/queue.rb:40`), with a 305 s shellout backstop (`notify.rb:78,363-365`).
The class's own spec comment (`spec/lain/notify_spec.rb:306-311`) states the intent this contradicts:
"post-T15 this surface raises the notification for **EVERY** approval". `spec/lain/notify_spec.rb:285-305`
(`expect(fired.size).to eq(1)`) is the behavioural pin on single-flight and must be rewritten.

The precedent for the fix is in-repo: `Frontend::Neovim::ApprovalView` (`approval_view.rb:176-196,218`)
renders the parked set without blocking and takes its verdict out-of-band, and its comment
(`:205-211`) argues that `decide`'s Boolean return — not a pre-check — is the honest source. `Pending#decide`
(`approval/queue.rb:184-192`) is atomic with no yield point, so first-answer-wins already holds under
concurrency. No `Async::Semaphore`/`Barrier` exists anywhere in `lib/`; introducing one would be a new
primitive for this codebase.

**The echo rail (F25).** `_G.__lain.review_refused`
(`lib/lain/frontend/neovim/runtime/65_review.lua:33-38`) is a single `nvim_echo` with a `"lain: "`
prefix and **no chunking, no truncation, and no width awareness anywhere in the runtime Lua**. The
only mitigation in the codebase is "keep the sentence short", enforced by two length assertions
(`spec/lain/review/surface/neovim_spec.rb:337-343` `< 60`, `:432-440` `< 40`). `PARTLY_MARKED`
(`lib/lain/review/surface/neovim.rb:210-211`) and `ApprovalView`'s `UNSHOWN`/`UNKNOWN`/`SETTLED`
(`approval_view.rb:138-146`) ride the same rail with **no length pin** and run well over 200
characters. `lib/lain/review/surface/neovim.rb:186-203` records, verified against a real embedded
UI, that `nvim_echo` writes the **message area** (`&columns` wide × `&cmdheight`) and never reads the
window — so the binding number in the cockpit is the nvim pane's 110 columns. The round-5 finding
originally blamed the 40-column sidebar; that was wrong and has been corrected in the findings doc.

**The approval buffer (UX4).** Not an oversight — a recorded decision. `approval_view.rb:62-66` and
`runtime/00_constants.lua:19-23` both argue against priming it, on the ground that it "would put an
empty window on screen at every attach". The counter-argument is in the runtime itself:
`runtime/62_approval.lua:93` opens the window only `if rows > 0`, so a prime carrying zero rows
creates the buffer and takes no window. `ApprovalView` has no `initial` and names its buffer `BUFFER`
where the primed views use `NAME`. `Surfaces` does not hold it (`surfaces.rb:44-51`); it hangs off
`Neovim` (`neovim.rb:447`). Priming must go through `set_approval`, not `set_view`, or the buffer is
created without `b:lain_approval_rows` and its gestures are inert.

**Token units (UX5).** The proxy is not a divided estimate — it *is* the byte count, 1:1:
`Compaction::Scheduler#measure` (`lib/lain/compaction/scheduler.rb:216-219`) is
`Canonical.dump(messages).bytesize`. `used_tokens` is provider-measured but is
`Usage#total_input_tokens` (`lib/lain/usage.rb:46-48`) — the **three-way sum** including cache reads
and writes, not bare `input_tokens`. Blast radius is small in `lib/`: the only reader of
`tokens_before`/`tokens_after` is `Scheduler#costs` (`:281-283`); `RunClock` (`run_clock.rb:112`) and
`StatusFeed` (`status_feed.rb:299`) match on the class only. The same record already carries
`head_bytes`, honestly named, so `Telemetry::Compaction` is the outlier against a convention the
subsystem already has. There is **no schema layer**: `Telemetry::Journalable#to_journal`
(`lib/lain/telemetry.rb:17-36`) maps Data members to wire keys mechanically, so a rename is a
wire-format change with nothing to absorb it. `planning/specs/event-schema.md` does not govern
telemetry records and says nothing about units.

**read_file's one-line advice (UX7).** `self.too_large` (`lib/lain/tools/read_file.rb:511-513`)
decides from `File.size` before any open, and `narrower_for` (`:517`) branches on size alone.
`LONG_LINE_NARROWER` (`:103-111`) is reachable only from `LongLine#narrower` (`:349-365`), the wrong
side of the seam.

**The gap is narrower than the QA finding implied, and getting this boundary right is the whole
card.** `WHOLE_BOUND` is 256 KiB and `WINDOW_BOUND` is 1 MiB (`:66,72`), and `Window#read` builds
`LongLine.new(WINDOW_BOUND.limit, …)` (`:422`) whose `note` (`:340-344`) records an offending line
only when `chunk.bytesize > @ceiling`. So:

- **`size <= WINDOW_BOUND.limit` (the `FULL_COVER` branch): there is no bug.** A newline-free 300 KB
  file has a line 1 of 300 KB, which is under 1 MiB, so `LongLine` never fires and a full-cover
  window serves the file. `FULL_COVER` is correct advice and must not change.
- **`size > WINDOW_BOUND.limit` (the `PART_ONLY` branch): this is the bug**, and it is what QA
  actually hit (`one.json`, 1 200 003 bytes). Here a newline-free prefix proves line 1 exceeds
  `WINDOW_BOUND`, so every `offset`/`limit` window is refused in turn.

**The exact, bounded test is therefore confined to that branch:** absence of any `\n` in the first
`WINDOW_BOUND.limit + 1` bytes proves line 1 > `WINDOW_BOUND` and hence that `LongLine` will fire —
exact, not heuristic, because that is the same ceiling `LongLine` measures against. `Whole#capped`
(`:220-222`) already owns the bounded `File.read(path, N)` primitive with its encoding and
frozen-string gotchas.

Spec impact, corrected: `spec/lain/tools/read_file_spec.rb:523-532` ("never reads the file it
refuses") uses `sparse("huge.bin", whole_ceiling * 8)` = 2 MiB — the `PART_ONLY` branch — so it WILL
be probed and must be rewritten to bound the read rather than forbid it. `:534-541` uses
`sparse("huge.rb", whole_ceiling + 1)` = 256 KiB + 1 — the `FULL_COVER` branch — and is **unaffected**;
it must keep passing unchanged, which is the guard that this card did not over-reach.

**`lain up` (UX6).** `up.rb` builds a command string (`:302`, `PaneCommand.call`) and never
constructs a backend, so a construction refusal can only surface from inside the pane.
`keep_failed_pane` (`:466`) writes `remain-on-exit failed` and its comment (`:415-465`) already
reasons carefully about the write's timing; the residual — tmux's dead-pane banner consuming the
pane's first line — is tmux's own and cannot be fixed from inside the pane.

**Not reached by round 5, and not in this chunk:** `rails-blog.md` in full, and therefore compaction
at scale, `lain friction`'s `cache_waste` analyzer against a real broken prefix, and the deliberate
`elide+summarizing` `Overlap` raise.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `.pre-commit-config.yaml`.
- `ROADMAP.md` is also orchestrator-owned for this chunk: T13 supplies its prose as a wiring diff,
  because the orchestrator separately adds this plan's own index line and the two edits collide.
- Deviation: **T4 carries a mandatory spec-rewrite review.** It rewrites
  `spec/lain/notify_spec.rb:285-305`, an example that pins current behaviour deliberately. The panel
  must see the before/after of that example specifically, not just the diff stat.
- **Withdrawn during panel review, and recorded because the plan asserted the opposite:**
  `spec/lain/bench/session/chain_fold_spec.rb:86-113` must **NOT** be rewritten. Its `let(:records)`
  is `…to_a.map { |turn| Lain::SessionRecord.turn(turn) }` — **turn records only** — and the cited
  message is put into a throwaway store the fold never uses. Its prose comment ("the message is in
  the journal") describes the intent, not the fixture. Mechanically it is the same legitimate
  dangling case as `resume_spec.rb:794-816`, it will still refuse correctly after T1, and it must
  keep passing. An earlier draft of this plan instructed an agent to rewrite it, which would have
  deleted real coverage with the panel's blessing.

## Open decisions

- **The orchestration-DAG surface is deliberately OUT OF SCOPE** (decided at interview, 2026-08-18).
  No `lain://` buffer renders subagent structure: no frontend file references `child_turn`, `spawn`
  or message events, and `StatusFeed#observed` (`lib/lain/status_feed.rb:457`) publishes
  `@fleet.keys` from a `{spawn_digest => true}` set (`:388`), so even the source holds no parent/child
  edges. Building it is a real causal-edge projection, not a rendering of existing state. **T13
  records the gap and corrects `ROADMAP.md:635`**, which currently calls `lain://timeline` "(the
  DAG)" while `TimelineView` renders a linear first-parent chain. Deferred, not forgotten.
- **Journal wire compatibility for the UX5 rename is accepted** (decided at interview): old journals
  keep their old field names and are not migrated. T8 must state this in the record's docstring so a
  reader of a pre-chunk journal is not misled. No back-compat shim ships.
- Whether `Notify` should eventually correlate verdicts through `dunstctl` rather than parsing
  `dunstify` stdout is **not decided and not in scope**; T4 keeps the existing stdout mechanism and
  changes only when the fiber waits.
- **RESOLVED at execution (2026-08-19, orchestrator + user): the correlation work is SCHEDULED, not
  deferred.** T4 keeps its scope exactly as written below, and the second limb of F24 lands as a new
  card **T4b** (wave 2, depends on T4), which correlates verdicts through `--printid`/`dunstctl` and
  withdraws a popup whose pending a sibling settled. The stale-popup trade described below is
  therefore transitional within this chunk rather than a shipped state. The paragraph is kept
  unedited because T4's own scope boundary is still exactly what it says.
- **T4 therefore discharges only HALF of F24, deliberately, and this must not be read as a full
  fix.** F24 has two limbs: the notifier can only show one approval at a time, *and* it goes on
  displaying a command that has already been decided (findings doc, the 18:46 observation). T4 fixes
  the first. It does not WITHDRAW a popup whose pending a sibling settled, because withdrawal needs
  the `dunstctl`/`--printid` correlation deferred above. Consequence to accept knowingly: with
  `-u critical` (never auto-expires) and `-t 300000`, three gated calls can now leave three live
  notifications on screen for up to 305 s, some showing decided commands. That is more stale popups
  than today, not fewer. If that trade is unacceptable, the correlation work must be scheduled
  instead of deferred — decide before executing T4, not after.
- **T8's pricing question is open and its card must not proceed past it silently.**
  `Compaction::Scheduler#cost_saved`/`#cost_spent` (`lib/lain/compaction/scheduler.rb:290-302`)
  already feed the byte proxy into `Usage.new(input_tokens:)` / `Usage.new(cache_creation_input_tokens:)`
  and price it at a per-TOKEN rate. So the two units are not merely named alike — they are already
  being combined, and the resulting dollar figures overstate by roughly the bytes-per-token ratio.
  Either T8 converts at the pricing boundary with a stated divisor (making the numbers honest and
  the type distinction enforceable), or it renames only and leaves the arithmetic as it is (making
  the type distinction unenforceable). **The card states the fork and stops; the orchestrator
  decides.** Shipping a "cannot be combined" type while `cost_saved` combines them is not an option.
- **RESOLVED at execution (2026-08-19, orchestrator + user): T8 takes the CONVERT branch, with a
  value object.** Three parts, all in T8's scope:
  1. A small deeply-frozen `Data` value object for the proxy measurement -- `Ractor.shareable?` like
     every other value here -- so a byte count cannot be passed where a token count is expected. Its
     `#to_tokens` is the ONLY crossing, and it is the one named call site a reader audits.
  2. Rename the proxy fields to say bytes on **both** records (`Telemetry::Compaction`'s
     `tokens_before`/`tokens_after` and `Telemetry::SeamDecision`'s `tokens_removed`/`tokens_after`),
     and follow `Plan::SeamDecision`'s reads. Old journals are not migrated; the docstrings say so.
  3. Convert at the pricing boundary in `Scheduler#cost_saved`/`#cost_spent` with a **stated,
     documented divisor**, so the dollars stop overstating and the type's promise is true.
  **No scalar `Tokens` type.** `Usage` is already the token value object -- a frozen `Data` with four
  Integer token fields, a `+` that raises `TypeError` on a non-`Usage`, and `total_input_tokens`. A
  second token type competing with it would have to retype `Usage`'s fields to be enforceable, which
  reaches the provider parse paths, `StatusFeed#occupancy_of`'s re-derivation from journaled string
  keys (`status_feed.rb:346-352`), `Ledger`, `Compare` and the bench sweeps -- a much larger change
  buying the one guarantee `#to_tokens` already gives at a single site. **`Usage` is not modified.**
  **Money representation is NOT changed.** A "track cost in cents" directive was raised and withdrawn
  once the measurement was in: `PriceBook::Price` is BigDecimal end to end and `per_mtok` divides the
  per-million quote by 1e6 exactly (`price_book.rb:10-31`), so the Float drift integer sub-units
  normally prevent does not exist here; and a per-token rate is a sub-cent fraction ($3/Mtok =
  0.0003 cents), so integer cents could not hold it losslessly anyway. Cost stays `BigDecimal`
  dollars. T8 must not introduce a money type.

## Waves

Wave 1: T1, T4, T5, T7, T8, T9, T11, T12, T13   (no unmet deps)
Wave 2: T2 (←T1), T4b (←T4), T6 (←T7), T10 (←T9)

Critical path: **two waves**; the longest chains are T1→T2, T4→T4b, T7→T6 and T9→T10, all of length
2. T1 and T4 are the highest-risk cards and both sit in wave 1 with a single follower each.

T4b was added at execution (2026-08-19) when the Open decisions fork on F24's second limb was
resolved toward scheduling the correlation work rather than deferring it. It shares `lib/lain/notify.rb`
and `spec/lain/notify_spec.rb` with T4, which is exactly why it is sequenced behind it rather than
run beside it; it is the only wave-2 card touching those files.

An earlier draft ran three waves with T5→T6→T7, which the panel correctly called an inflated
critical path: T7 had no semantic dependency on T6, only a file collision on
`lib/lain/frontend/neovim/approval_view.rb`, and it parked the least-grounded card at the tail. The
collision is resolved by ownership instead of sequencing — **T7 owns `approval_view.rb` entirely**
(both the priming and bringing its own constants under the width bar), and T6 owns the discipline
spec plus `review/surface/neovim.rb`. T6 now depends on T7 because the spec it adds would be red
until T7's constants land.

Same-wave file conflicts checked: T9 and T10 both touch `lib/lain/cli/up.rb` and are sequenced for
that reason. No other file appears in two same-wave cards.

## Tasks

### T1 — Reach a fixpoint over both record sets when rebuilding a session   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/bench/session/loader.rb`, `lib/lain/bench/session/chain_fold.rb`,
`lib/lain/bench/session/message_replay.rb`; modify
`spec/lain/bench/session/loader_spec.rb`, `spec/lain/bench/session/message_replay_spec.rb`; create
`spec/lain/bench/session/loader_fixpoint_spec.rb`
**Reuse:** `MessageReplay`'s sweep-until-stalled solver (`message_replay.rb:81-112`) — `landed`,
`swept`, **`resolvable?` (`:110-112`)** and `forced` — which already resolves this cycle among flat
events; `ChainFold`'s `verified_turn`/`@members`/`rewound_checkout`
(`chain_fold.rb:40-43,109,117-125`), which must keep working unchanged; `Loader#store`
(`loader.rb`), already the one shared store both passes write into.
**Shared-file wiring:** none
**Reachable from:** `Bench::Session::Loader#recording` — which has **three** production
constructors, all of which this card changes: `CLI::Resume#load_recording` (`lib/lain/cli/resume.rb:156`,
reached from `CLI::ChatLaunch#resumed_run`, `chat_launch.rb:168-172`, for both `--fork` and
`--resume`); `Supervisor::Restart#replay` (`lib/lain/supervisor/restart.rb:128`, "THE M2 code path");
and `Bench::Session.load` (`lib/lain/bench/session.rb:188`) via `Bench::CLI#load_session`
(`lib/lain/bench/cli.rb:319-323`).

**Do the fixpoint inside `Loader`; do not introduce a new class.** An earlier draft created a
`Bench::Session::Fold` that merged the two passes. The panel cut it as speculative generality that
inherits all of the risk: `Loader#recording` already memoizes `chain_fold` and `replayed` against one
shared store, so alternating them to a fixpoint needs no new file, no index edit, and no rewrite of
`ChainFold`'s ordered-chain contract. Advance the chain as far as it can go, land every flat event
whose parents are present, and repeat until neither moves; then force the remainder so the failure
is raised honestly.

**Two mechanics are load-bearing and are the reason this card is high-risk:**

1. **Pre-check; never advance speculatively.** `Timeline#commit` (`lib/lain/timeline.rb:66-75`)
   `put`s the payload *before* the envelope, and only the envelope's `put` runs
   `Store#validate_parents!` (`store.rb:92-98`). So discovering a dangling parent by attempting a
   commit and rescuing — which is what `ChainFold#recommitted` (`chain_fold.rb:79-85`) does today —
   **leaves an orphaned `Event::Payload` in the store**, and in a fixpoint loop it does so once per
   sweep. Decide reachability with the `resolvable?` shape (`store.key?` over
   `[render_parent, *causal_parents]`) and keep the rescue for the final forced pass only.
2. **One refusal currency: `Corrupt`.** The forced pass must translate `Store::MissingObject` into
   `Corrupt` for flat events exactly as `recommitted` already does for turns. Otherwise which
   exception a damaged journal raises becomes an accident of whether the stuck record happened to be
   a turn or a message — and the three callers above rescue different sets.

**The record index space must not silently renumber.** `ChainFold` indexes turn+rewound records
only (`chain_fold.rb:28,49`), which is what makes "turn record 26 (user)" mean something to a human
and is what `chain_fold_spec.rb:110` pins as "turn record 1". Keep that index space for turn
refusals; give flat-event refusals their own clearly-labelled space rather than merging the two.

**Acceptance criteria:**

```gherkin
Scenario: a turn citing a message the journal records loads
  Given a journal holding a message record and a later turn citing that message in causal_parents
  When the session is loaded
  Then the recording builds and the turn is on the chain
  And no error is raised

Scenario: the same journal loads whichever order its records appear in
  Given a journal holding a turn and a message citing each other, written in each order in turn
  When each is loaded
  Then both recordings expose the same timeline head and the same messages in file order

Scenario: a genuinely dangling causal parent is still refused as Corrupt
  Given a journal holding a turn citing a digest no record in the file carries
  When the session is loaded
  Then Corrupt is raised naming the turn record index, its role, and the unresolved digest

Scenario: a dangling parent under a message record is refused as Corrupt too
  Given a journal holding a message citing a digest no record in the file carries
  When the session is loaded
  Then Corrupt is raised rather than Store::MissingObject

Scenario: a session that spawned can be forked and resumed
  Given a recorded session containing child_turn and message records
  When it is forked at its head and separately resumed
  Then both succeed

Scenario: rebuilding leaves no unreferenced payload behind
  Given a journal whose first attempt to advance the chain is blocked by an unlanded message
  When the session is loaded
  Then the store holds no payload whose event was never committed
```
→ spec files: `spec/lain/bench/session/loader_fixpoint_spec.rb` (all but the fifth),
`spec/lain/cli/resume_spec.rb` (the fifth, alongside the existing legitimate-refusal example)

**Escalation triggers:**
- `spec/lain/bench/session/chain_fold_spec.rb:86-113` **must keep passing unchanged.** Its fixture is
  turn records only (`.map { |turn| Lain::SessionRecord.turn(turn) }`) and the cited message goes
  into a throwaway store, so it is a legitimate dangling case despite its prose comment. If you find
  yourself editing it, stop — an earlier draft of this plan wrongly told you to.
- `spec/lain/cli/resume_spec.rb:794-816` must also keep passing, for the same reason. If either goes
  green because it stopped raising, stop.
- `Loader`'s ordering comment (`loader.rb:77-80`) states that `timeline:` must be the first keyword
  evaluated so the store is populated before messages land. After this card that sequencing is
  neither necessary nor sufficient. **Update the comment in this card** — leaving it reads as a live
  invariant to the next person.
- If `rewound` records can name a message digest, the ordering assumption is wider than this card
  scoped — stop rather than widening `verified_target` (`chain_fold.rb:134-140`).
- If `Loader#on_chain?` / `ResumeChain#prior_timeline` behaviour changes for any existing fixture,
  stop: `@members` is load-bearing beyond this card.
- If the fixpoint needs more than one alternation to converge on any real recorded session, say so
  in the hand-back — it means the cycle is deeper than the two-phase shape assumed here.

### T2 — Make every caller of the session rebuild refuse by name          [wave 2] [risk: low]

**Depends on:** T1
**Files:** modify `lib/lain/cli/resume.rb`, `lib/lain/bench/cli.rb`,
`lib/lain/supervisor/restart.rb`; modify `spec/lain/cli/resume_spec.rb`,
`spec/lain/bench/cli_spec.rb`, `spec/lain/supervisor/restart_spec.rb`
**Reuse:** the existing dual rescue at `resume.rb:113-114` and its comment (`:107-112`), which
already states why `Store::MissingObject` needs catching beside `Corrupt`; `Refusal`'s existing
message shape (`resume.rb:145,175-177`).
**Shared-file wiring:** none
**Reachable from:** the three production constructors named in T1 — `CLI::ChatLaunch` → `Resume#call`
/ `#fork`; `Bench::CLI#load_session` (`bench/cli.rb:319-323`); `Supervisor::Restart#replay`
(`supervisor/restart.rb:128`).

A damaged journal must refuse by name from **every** door, not just `--fork`. Today `Resume#rebuild`
rescues only `Corrupt` (`resume.rb:142-145`) while `#fork` rescues `Corrupt` and
`Store::MissingObject` (`:113-114`); `Bench::CLI#load_session` rescues `Corrupt` only; and
`Supervisor::Restart` — the M2 restart path — has **no rescue at all** (`grep -n rescue
lib/lain/supervisor/restart.rb` is empty), so a damaged journal takes a supervised restart down with
a raw backtrace.

T1 makes `Corrupt` the single currency; this card makes every caller handle it, and keeps the
belt-and-braces `Store::MissingObject` rescue so a future escape is still named rather than raw.

**Acceptance criteria:**

```gherkin
Scenario: resume refuses a damaged journal by name
  Given a journal with an unresolvable causal parent
  When the session is resumed
  Then it exits 1 naming the session and the unresolved digest
  And stderr carries no backtrace frames

Scenario: the bench refuses the same journal by name
  Given that journal
  When a bench command loads it
  Then it reports the same refusal rather than raising

Scenario: a supervised restart survives a damaged journal
  Given that journal
  When the supervisor attempts its restart replay
  Then the failure is reported as a named refusal
  And the supervisor does not die with an unrescued exception
```
→ spec files: `spec/lain/cli/resume_spec.rb`, `spec/lain/bench/cli_spec.rb`,
`spec/lain/supervisor/restart_spec.rb`

**Escalation triggers:**
- **Whether this card has any reachable behaviour is decided by T1's implementer.** If T1 made every
  damaged journal raise `Corrupt` before it reaches any caller, the `Store::MissingObject` arms here
  are unreachable. Do not manufacture a fixture that cannot occur in production — report it and
  scope this card to the supervisor gap, which is real either way.
- `Supervisor::Restart` has no rescue today, so adding one changes restart semantics under failure.
  If rescuing changes whether a restart is retried or abandoned, stop: that is a supervision policy
  decision above this card.

### T3 — (withdrawn during decomposition; folded into T1's acceptance criteria)

### T4 — Let the notifier raise every approval without waiting on the last  [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/notify.rb`; modify `spec/lain/notify_spec.rb`
**Reuse:** `Notify#run`'s existing `Thread` + `Thread::Queue` pair (`notify.rb:338-344`) — keep the
Thread for the shellout and stop `pop`-ing it inline; `Frontend::Neovim::ApprovalView`'s
raise-now/decide-later shape (`approval_view.rb:176-196,218`) and the argument at `:205-211` that
`decide`'s Boolean return is the honest source rather than a pre-check; `@raised` /
`QueueSurface::Pruning` (`notify.rb:155-156`) for the seen-set, which stays unchanged.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` (`lib/lain/cli/wiring.rb:354`, `Lain::Notify.for(desktop:, journal:)`)
→ `CLI::Repl::ApprovalSurfaces#watch` (`approval_surfaces.rb:105`), which spawns the notifier fiber
in every non-`--yolo` chat.

A pending must get its desktop notification when it parks, not when the previous one is answered.
The surface keeps every property it has today: it never consumes the queue, it never raises a second
notification for a pending it is already showing, and it fails closed on anything that is not a
literal approve. What changes is only that an in-flight wait no longer blocks the next raise.

**`pending.decide` MUST stay on the reactor fiber. This is the card's central constraint and an
earlier draft of this plan got it exactly wrong**, asserting that `Pending#decide` is "atomic with no
yield point, so first-answer-wins already holds under concurrency". Read what the source actually
claims (`lib/lain/approval/queue.rb:176-181`): single-shot resolution is safe without a lock *"only
because … two **fibers** cannot both pass the guard"*. That is a fiber argument, not a thread
argument. Calling `decide` from the shellout Thread breaks it twice over:

1. Two OS threads can both pass the `decided?` guard (the GVL switches between bytecode
   instructions), and the loser reaches `@promise.resolve`, which raises `AlreadyResolved`
   (`lib/lain/promise.rb:32-36`) inside a bare `Thread.new` nobody joins — a swallowed exception and
   a silently lost verdict.
2. `Promise#resolve` → `Async::Variable#resolve` signals an `Async::Condition`, which resumes fibers
   owned by the **reactor thread**. Resuming a fiber from a foreign thread is a `FiberError`.

So the shape is: the Thread runs the shellout and does nothing else; the completed verdict crosses
back over the existing `Thread::Queue`; and the **sweep loop drains finished results** and calls
`pending.decide` itself, on the reactor fiber, exactly as it does today.

**Acceptance criteria:**

```gherkin
Scenario: two approvals parked together both raise notifications
  Given two pendings parked while the first notification is still unanswered
  When the notifier sweeps
  Then two notifications have been raised
  And neither pending has been consumed from the queue

Scenario: the answer to one in-flight notification decides only that call
  Given two notifications in flight
  When the first returns approve
  Then that pending is approved and the second is still undecided

Scenario: a pending settled by another surface mid-flight loses the race cleanly
  Given a pending whose notification is in flight
  When a sibling surface decides it and the notification then returns a verdict
  Then the sibling's decision stands and its surface is unchanged
  And the notifier raises no exception and records no decision of its own

Scenario: a verdict is applied on the reactor fiber, not the shellout thread
  Given a notification whose shellout completes on its own thread
  When its verdict is applied
  Then the decision is taken by the watching fiber
  And no fiber is resumed from a foreign thread

Scenario: the surface still fails closed
  Given a notification whose shellout returns a dismissal, an empty string, or raises
  When it completes
  Then the pending is denied with surface "dunst"
```
→ spec file: `spec/lain/notify_spec.rb`

**Escalation triggers:**
- `spec/lain/notify_spec.rb:285-305` (`expect(fired.size).to eq(1)`) is the deliberate pin on
  single-flight and will fail. Rewriting it is in scope and is the mandatory-review item in the
  Orchestrator contract. **Be honest about what the replacement can assert.** That example works
  *because* its factory settles the sibling while the first notification blocks
  (`notify_spec.rb:290-293`); once notifications are concurrent the second popup is already
  dispatched, so "a pending settled by a sibling gets no popup" is genuinely unattainable in the
  raise-then-settle window. The `notify_about` re-check (`notify.rb:298-303`) degrades from a
  guarantee to a best-effort narrowing. Assert the race outcome (the sibling's decision stands,
  nothing raises), not the popup count — and do not fake the old property with a sleep.
- `spec/lain/frontend/approval_policy_spec.rb:177-300` is a `:seam` example driving a **real**
  `Lain::Notify` with a latching shellout and asserting `prompts.size == 2` and two `tty` surfaces.
  If it becomes timing-sensitive, stop — do not paper over it with a sleep.
- If you find yourself reaching for `Async::Semaphore` or `Async::Barrier`, stop and escalate:
  neither exists anywhere in `lib/` today and introducing a new concurrency primitive is a design
  decision above this card.
- **Fail-closed must keep a witness that is not a double.** The production path depends on
  `Mixlib::ShellOut::CommandTimeout` landing in `capture`'s bare `rescue StandardError`
  (`notify.rb:350-356`) at 305 s; an injected factory that raises proves only that the rescue exists.
  `spec/lain/frontend/approval_policy_spec.rb:177-300` is the `:seam` that drives a real `Notify` —
  keep it honest rather than only avoiding breaking it.
- Confirm `Mixlib::ShellOut` places each child in its own process group before relying on the 305 s
  backstop with N shellouts in flight: `shellout_timeout_seconds` (`notify.rb:363-365`) SIGTERMs a
  process **group**, and if the group were shared the reaper would kill every live notification.
- `@raised` is `compare_by_identity` and will now be read while N threads hold references to the same
  `Pending`s. It must remain touched only by the sweep fiber; note that in a comment.
- `spec/approval_consumer_discipline_spec.rb` is a Ripper lint over `lib/` allowlisting `.dequeue`
  receivers by file. If your change adds a `dequeue` anywhere in `notify.rb`, you have taken the
  wrong approach — this surface must stay non-consuming.

### T4b — Withdraw a notification whose approval somebody else answered   [wave 2] [risk: high]

**Depends on:** T4
**Files:** modify `lib/lain/notify.rb`; modify `spec/lain/notify_spec.rb`
**Reuse:** T4's sweep-drains-results shape, which is the only place a verdict may be applied and is
therefore the only place a withdrawal may be ordered; `@raised` / `QueueSurface::Pruning`
(`notify.rb:155-156`), already the per-pending seen-set this card extends into a per-pending handle
map; `Backend`/`Null` (`notify.rb:367-380`), the existing "no dunstify on PATH, every method a
documented no-op" object, which is where a desktop that cannot withdraw must degrade to; `#capture`'s
bare `rescue StandardError` (`notify.rb:350-356`), which already turns any shellout failure into a
fail-closed empty answer.
**Shared-file wiring:** none
**Reachable from:** the same path as T4 — `CLI::Wiring` (`lib/lain/cli/wiring.rb:354`) →
`CLI::Repl::ApprovalSurfaces#watch` (`approval_surfaces.rb:105`) — in every non-`--yolo` chat.

**This card exists because the correlation work was SCHEDULED rather than deferred** (Open decisions,
resolved 2026-08-19). T4 alone makes the notifier raise every approval concurrently and knowingly
leaves the second limb of F24 open: with `-u critical` (exempt from auto-expiry by the freedesktop
spec, and this desktop's dunst honours it — `notify.rb:59-77` records the hand-verification) and
`-t 300000`, three gated calls can leave three live popups on screen for up to 305 s, some naming a
command a sibling surface already decided. **T4 must not be treated as shipped until this card
lands**; the two together are F24.

When a pending this surface raised a notification for is settled by another surface, the popup must
go away. Nothing else changes: the surface still never consumes the queue, still never raises a
second notification for a pending it is already showing, still fails closed on anything that is not a
literal `APPROVE`, and still applies every verdict on the reactor fiber (T4's central constraint,
which this card inherits whole).

**The mechanism is an empirical question and the card requires it be answered by measurement, not by
recall.** `dunstctl` and `dunstify` are both on PATH on this box (verified 2026-08-19). Two shapes
are plausible and the implementer must establish which actually works against the real dunst before
building on it, and record the transcript of that check in the hand-back:

1. **Self-assigned replace id.** `dunstify -r ID` lets the CALLER choose the notification id rather
   than reading one back, so no stdout parsing is added and `#capture`'s single-value contract is
   untouched. Withdrawal is then `dunstctl close ID` (or a replacing `dunstify -r ID -t 1` with no
   actions). Preferred if it holds, precisely because it adds no second thing to parse.
2. **`--printid` correlation.** Read the id dunstify prints and key the handle map on it. **Check
   what `--printid` does to stdout when `-A` actions are also present** — `#decide` reads
   `shell_out.stdout.to_s.strip` as the action key (`notify.rb:225,350-356`), so an id printed onto
   the same stream would be read as "not APPROVE" and silently deny every approval. If you cannot
   separate the two values cleanly, this shape is disqualified; say so and take shape 1.

**Withdrawal is ordered from the sweep fiber, never from the shellout Thread.** The handle map is
touched only by the sweep, exactly as `@raised` is (T4's own escalation trigger says so, and this
card widens the same map's job). The shellout Thread's only remaining role is to run one command and
push its result — closing the popper out from under it makes the blocked `dunstify -A` exit with
empty stdout, which lands in the existing fail-closed path and reaches `pending.decide` as a deny
that **returns false** because `Pending#decide` guards on `decided?` (`approval/queue.rb:184-186`).
That losing return is the correlation's own witness and must be asserted, not assumed.

**Degrade, never wedge.** A desktop where the withdrawal command is absent, fails, or closes nothing
must leave the surface exactly as T4 left it — a stale popup is a worse UX than today's block, but a
notifier that raises out of a withdrawal is a session with no desktop approvals at all, which is the
failure class T4's own trigger names. Withdrawal is best-effort in the `@tmux.run`-vs-`@tmux.act`
sense (`up.rb`'s existing degrade convention).

**Acceptance criteria:**

```gherkin
Scenario: a popup for a pending a sibling settled is withdrawn
  Given two pendings, each with a notification raised and in flight
  When a sibling surface decides the first
  Then the next sweep withdraws the first notification
  And the second notification is left alone

Scenario: the withdrawn notification's own late verdict changes nothing
  Given a withdrawn notification whose shellout then returns a verdict
  When that result is drained
  Then the sibling's decision still stands
  And this surface records no decision of its own and raises nothing

Scenario: withdrawal is ordered on the reactor fiber
  Given a notification being withdrawn
  When the withdrawal command is issued
  Then it is issued by the watching fiber
  And no fiber is resumed from a foreign thread

Scenario: a desktop that cannot withdraw still approves and denies
  Given a withdrawal command that is absent or fails
  When a pending is settled by a sibling
  Then the surface raises nothing
  And a subsequent approval on another pending is still decided normally

Scenario: nothing is withdrawn for a pending this surface decided itself
  Given a notification whose own Approve action returns first
  When its verdict is applied
  Then the pending is approved
  And no withdrawal command is issued for it

Scenario: the surface still never consumes the queue
  Given any sequence of raises, verdicts and withdrawals
  When the queue is inspected
  Then no pending was dequeued by this surface
```
→ spec file: `spec/lain/notify_spec.rb`

**Escalation triggers:**
- **Establish the mechanism before writing the implementation.** If neither `-r`/`dunstctl close` nor
  `--printid` can withdraw a live `-u critical -A ...` popup on this box, stop and escalate: the
  card's premise is that withdrawal is reachable at all, and the Open-decisions resolution that
  scheduled this work assumed it.
- If `--printid` shares stdout with the action key, do **not** parse them apart with a regex and hope
  — take the self-assigned-id shape instead, or stop. `#decide`'s "the answer isn't APPROVE" signal
  (`notify.rb:41-45`) is a fail-closed default, so a parse that goes wrong denies approvals silently.
- `spec/lain/frontend/approval_policy_spec.rb:177-300` is the `:seam` driving a **real** `Lain::Notify`
  with a latching shellout. T4's trigger already says not to paper over it with a sleep; the same
  holds here, and this card must not make it timing-sensitive either.
- If you reach for `Async::Semaphore` or `Async::Barrier`, stop — the same trigger as T4, for the
  same reason: neither exists in `lib/` today.
- `spec/approval_consumer_discipline_spec.rb` still applies: a `dequeue` appearing in `notify.rb` means
  the approach is wrong.
- Withdrawal must not fire for a pending that merely TIMED OUT on the queue's own clock while this
  surface's shellout is still inside its 305 s backstop — `Approval::Queue`'s timeout denies at
  surface `"timeout"` (`notify.rb:69-77`) and that is a legitimate settle. If distinguishing "settled
  by a sibling" from "settled by the queue's timeout" changes what is withdrawn, say which you chose
  and why in the hand-back; both are settled pendings and both leave a stale popup.

### T5 — Make the refusal rail width-aware so a refusal cannot page      [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/runtime/65_review.lua`; modify
`spec/lain/frontend/neovim_runtime_spec.rb`; modify
`planning/qa-findings-round5-2026-08-18.md` (correct F25's mechanism note) and
`planning/qa/scenarios/cockpit-surfaces.md` (§4's width table)
**Shared-file wiring:** none
**Reuse:** the measured account at `lib/lain/review/surface/neovim.rb:186-203` — `nvim_echo` writes
the message area, `&columns` wide over `&cmdheight` lines, and never reads the window; the existing
`nvim_get_mode().blocking` witness idiom used at `runtime/46_sidebar.lua:207-208` and in
`planning/qa/scenarios/cockpit-surfaces.md`.
**Reachable from:** `RuntimeLoader` installs `65_review.lua` at attach; every refusal from
`:LainReviewVerdict` (`46_sidebar.lua:213-218`), `:LainReviewDone` (`65_review.lua:117,122`),
`:LainNoteDone` (`48_annotate.lua:417-419`) and the approval `y`/`n` gesture
(`62_approval.lua:114-115`) routes through `_G.__lain.review_refused`.

`review_refused` must not raise a hit-enter prompt regardless of the sentence it is handed. The full
sentence must remain retrievable — `:messages` history is not allowed to lose information the human
needs — and the rail must stay traceback-free. A refusal that fits is unchanged.

**The two requirements are in tension under the current call, so the card names a viable mechanism
rather than leaving it to be discovered.** `nvim_echo(chunks, true, {})` (`65_review.lua:36-38`)
uses `history = true`, which *displays* as well as records — so writing the full sentence to history
is exactly what pages. The known-viable shape is to separate the two: record the complete sentence
to `:messages` without displaying it (`silent echomsg`, which appends to history and does not page),
then display a single line that fits. Any mechanism achieving both is acceptable; this one is
offered so the card is not a research task.

**Acceptance criteria:**

```gherkin
Scenario: a refusal longer than the message area does not block the editor
  Given an editor whose columns are narrower than a refusal sentence
  When that refusal is delivered on the rail
  Then nvim_get_mode reports blocking false
  And no "Press ENTER" prompt is raised

Scenario: the full sentence survives even when the echoed form is shortened
  Given a refusal too long for one message line
  When it is delivered
  Then the complete sentence is readable in :messages

Scenario: a short refusal is delivered unchanged
  Given a refusal that fits the message area
  When it is delivered
  Then the echoed text equals the sentence with its "lain: " prefix and nothing else

Scenario: the rail stays traceback-free
  Given any refusal delivered on the rail
  When :messages is read
  Then it contains no "stack traceback"
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb` (live-nvim examples; drive width by setting
`&columns` on the embedded UI)

**Escalation triggers:**
- If the only way you can stop the paging is to raise `&cmdheight` permanently, stop: that steals a
  screen line from the cockpit for every session and is a layout decision above this card.
- `spec/lain/frontend/neovim_runtime_spec.rb:1035-1048` and `spec/lain/review/surface/neovim_spec.rb:344-361`
  already assert `ok == true` plus a traceback-free `:messages` for refusals that *fit*. If your
  change alters what those read, stop.
- If a truncated echo would drop the remedy clause (the part naming what to do next) rather than
  incidental prose, stop and escalate — a refusal that names a condition but not its remedy is the
  loop this whole rail exists to break.
- If you can satisfy the no-paging AC or the full-sentence-in-`:messages` AC but not both, **stop and
  escalate rather than dropping one.** Both are the point; a fix that stops the modal by discarding
  the sentence has traded one silence for another.

### T6 — Pin the width of every sentence that rides the refusal rail     [wave 2] [risk: high]

**Depends on:** T7
**Files:** create `spec/refusal_width_discipline_spec.rb`; modify `lib/lain/review/surface/neovim.rb`
(T7 owns `lib/lain/frontend/neovim/approval_view.rb` and brings its constants under the bar)
**Reuse:** the two existing length assertions (`spec/lain/review/surface/neovim_spec.rb:337-343`
`< 60`, `:432-440` `< 40`) as the convention being generalized; the repo's existing
mechanical-discipline specs — `spec/output_discipline_spec.rb`,
`spec/desktop_discipline_spec.rb`, `spec/approval_consumer_discipline_spec.rb` — as the shape to
match (a spec that reads `lib/` and fails on a violation, with a stated allowlist).
**Shared-file wiring:** none
**Reachable from:** the constants are rendered by `Review::Surface::Neovim#mark`/`#verdict`
(`review/surface/neovim.rb:295`) and `ApprovalView#row_for`/`#outcome`
(`approval_view.rb:138-146`), both on the live cockpit path.

T5 stops a long refusal from blocking; this card stops refusals from *being* long, which is the
property the codebase already half-enforces. Today `PARTLY_MARKED` (`review/surface/neovim.rb:210-211`)
exceeds 200 characters with no pin at all, while its siblings are pinned under 60.

**Measure the RENDERED sentence, not the constant.** `MARKED`, `PARTLY_MARKED` and `ApprovalView`'s
`UNSHOWN`/`UNKNOWN`/`SETTLED` are `format` templates carrying `%<generation>s`, `%<line>s`,
`%<given>s`, `%<verdicts>s`. A bar checked against the template measures something *shorter* than
what `nvim_echo` receives — `%<verdicts>s` expands to `approve/deny`, `%<line>s` to digits — so a
template-based spec goes green while the rendered sentence pages. Substitute representative values
before measuring, and say in the spec why.

**Deriving the subject set is the hard part and is why this card is high-risk.** The repo's existing
discipline specs (`output_discipline_spec.rb`, `desktop_discipline_spec.rb`) are Ripper *syntactic*
scans — they match a method call or a receiver. "Every constant delivered through `review_refused`"
is a *dataflow* property crossing Ruby → `RpcThread#review_refused` (`rpc_thread.rb:393`) → the
`REVIEW_REFUSED` Lua eval (`:75`) → `65_review.lua:36`, and there is no AST pattern for it. A
mechanical approximation that is honest about being one — e.g. every refusal constant in a class that
sends `review_refused` — is acceptable; a hand-maintained list is not.

**Acceptance criteria:**

```gherkin
Scenario: every refusal that rides the rail fits the stated bar once rendered
  Given the set of refusals delivered through review_refused
  When each is rendered with representative substitutions and its "lain: " prefix
  Then each is within the bar the spec states

Scenario: a new over-long refusal is caught rather than shipped
  Given a refusal constant added to a class that sends review_refused
  When it renders longer than the bar
  Then the spec fails naming that constant, its rendered length, and its file
```
→ spec file: `spec/refusal_width_discipline_spec.rb`

**Escalation triggers:**
- If a sentence cannot be brought under the bar without dropping its remedy clause, stop and
  escalate — raise the bar deliberately rather than silently truncating meaning.
- If the constant set cannot be enumerated without hard-coding a list that will silently go stale
  as new refusals are added, stop: a discipline spec that misses new violations is worse than none,
  and this repo's existing discipline specs all derive their subject set from `lib/`.
- The shortened sentences must still name their condition **and** their remedy. That is a review
  criterion, not an assertion — if a sentence cannot keep both under the bar, escalate rather than
  quietly dropping the remedy.
- If the only derivation you can find is a hand-written list of constants, stop: a discipline spec
  that misses the next violation is worse than none, and this card exists to stop the bar rotting.

### T7 — Prime `lain://approval`, and bring its own refusals under the width bar [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/approval_view.rb`,
`lib/lain/frontend/neovim/surfaces.rb`, `lib/lain/frontend/neovim.rb`; modify
`spec/lain/frontend/neovim_buffers_spec.rb`, `spec/lain/frontend/neovim/surfaces_spec.rb`,
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `ApprovalView::EMPTY` (`approval_view.rb:79`), which already exists and is already the
at-rest projection — it is simply unreachable at attach; `RpcThread#post_approval`
(`rpc_thread.rb:412-414`), the non-blocking `refusable` post that must carry the prime so the buffer
gets `b:lain_approval_rows`; `runtime/62_approval.lua:93`'s `if rows > 0` guard, which is why a
zero-row prime creates the buffer without taking a window.
**Shared-file wiring:** none
**Reachable from:** `Frontend::Neovim` attach → `Surfaces#prime` (`surfaces.rb:74-79`), which runs on
the drain thread at every cockpit attach.

At rest the cockpit shows six primed views and `lain://approval` does not exist, so a human looking
for the approval surface finds no buffer. `Surfaces#prime`'s own docstring states the principle it
violates. Priming must go through `set_approval` (not `set_view`), must not open a window, and must
not change what the first real render does.

This card **owns `approval_view.rb` for the chunk**, so it also brings that file's own refusal
sentences — `UNSHOWN`, `UNKNOWN`, `SETTLED` (`approval_view.rb:138-146`), multi-clause `format`
templates well over 200 characters that ride the same echo rail as T5's — under the width bar T6
then enforces. Measure the rendered form, not the template: `%<verdicts>s` expands to
`approve/deny`, `%<line>s` to digits.

**Priming is a wiring fact, so it must be proven through the wiring.** UX4's cause is precisely that
`Surfaces` does not hold the `ApprovalView` — it is built in `Neovim#build_round_trips`
(`neovim.rb:443-448`) while `Surfaces#prime` iterates `[@journal_view, @buffers]` plus
`@request_buffer` (`surfaces.rb:74-79`). A `Surfaces` constructed *in a spec* with an approval view
injected will prime happily whether or not `Neovim#attach` ever wires one, so a doubled-RPC example
cannot witness this defect.

**Acceptance criteria:**

```gherkin
Scenario: the approval buffer exists at rest with its placeholder
  Given a freshly attached cockpit with no approval pending
  When the buffer list is read
  Then lain://approval exists and holds "(no approvals pending)"

Scenario: priming takes no window
  Given a freshly attached cockpit with no approval pending
  When the window layout is read
  Then no window is showing lain://approval

Scenario: the first real approval still renders and is still answerable
  Given a primed, empty approval buffer
  When a pending arrives
  Then the buffer shows its row and the y gesture decides it

Scenario: this view's own refusals fit the message area
  Given each refusal this view delivers, rendered with representative substitutions
  When it is measured with its "lain: " prefix
  Then it is within the width bar
```
→ spec files: `spec/lain/frontend/neovim_buffers_spec.rb` (**the first three, live nvim, driven
through the real attach path** — it is tagged `:nvim`, constructs the real
`Frontend::Neovim` and calls `frontend.run`, and already holds the sibling example "primes every
read-only view with its at-rest projection before any event flows" at `:94-104`, which is precisely
the assertion this card extends; a doubled `Surfaces` cannot witness the wiring this card fixes);
`spec/lain/frontend/neovim/approval_view_spec.rb` (the rendered-width example)

**Escalation triggers:**
- `ApprovalView#initialize` sets `@shown = nil` deliberately so the first sweep renders even an empty
  queue (`approval_view.rb:158-161`). If priming makes the first sweep skip, you have changed a
  documented invariant — stop.
- `spec/lain/frontend/neovim/surfaces_spec.rb:35-44` and
  `spec/lain/frontend/neovim_runtime_spec.rb:1365-1377` both pin the primed set as **exactly six
  names** with `contain_exactly`. Updating the first is in scope; the second belongs to T5's file in
  wave 1, so if it needs changing, hand the one-line diff to the orchestrator rather than editing it.
- **`Neovim#build_round_trips` (`neovim.rb:443-448`) constructs the `ApprovalView`, and whether that
  happens before `Surfaces#prime` runs on the drain thread was NOT traced during grounding.** Trace
  it first, before writing anything. If `prime` can run with `@approval_view` still nil, that
  ordering is the real defect and reordering construction is a bigger change than this card scoped —
  stop and escalate.
- `spec/lain/frontend/neovim/approval_view_spec.rb` pins the current wording of the constants this
  card shortens; updating those expectations is in scope, but confirm the new wording.

### T8 — Name the compaction proxy in bytes, and stop it being summable with measured tokens [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/telemetry/compaction.rb`, `lib/lain/compaction/scheduler.rb`; create
`spec/lain/telemetry/compaction_spec.rb` (the mirrored path does not exist yet — the record is
currently spec'd only in aggregate); modify
`spec/lain/compaction/scheduler_spec.rb`, `spec/lain/compaction/journaling_spec.rb`,
`spec/lain/compaction/source_spec.rb`, `spec/lain/telemetry_spec.rb`, `spec/lain/run_clock_spec.rb`,
`spec/lain/status_feed_spec.rb`; modify `lib/lain/telemetry/seam_decision.rb`,
`lib/lain/plan/seam_decision.rb` and `spec/lain/plan/seam_decision_spec.rb` (the declared sibling —
see below)

*(An earlier draft also listed `README.md`, `planning/qa/method.md`,
`planning/qa/scenarios/session-and-window.md` and `planning/qa/scenarios/rails-blog.md`. Verified:
`grep -rn "tokens_before\|tokens_after" README.md planning/qa/` returns **nothing** — those docs read
`window_tokens`/`used_tokens`, which this card must NOT rename. They are removed so no agent invents
edits to justify them.)*
**Reuse:** `head_bytes` on the very same `CompactionDecision` record
(`lib/lain/compaction/source.rb:95-99`) — the honest naming convention already exists in this
subsystem and this card extends it; `Compaction::Scheduler::Rewrite` (`scheduler.rb:70-75`), the
single producer of both figures, created at `:216-219` and read only at `:270-274,281-283`.
**Shared-file wiring:** none
**Reachable from:** `Compaction::Scheduler` on every compacting turn; the record is written by
`Scheduler#accounting` (`scheduler.rb:270-274`) into the session journal that `lain friction` and
`lain bench` read.

Two different units are both called "tokens" in one NDJSON stream: `tokens_before`/`tokens_after` are
a canonical-byte-length proxy (1:1 with bytes), while `used_tokens`/`window_tokens` on the sibling
record are provider-measured. Dividing the first by the second reads 80% where every other reader
says 32%. Rename the proxy fields to say bytes, and make the two kinds structurally
non-interchangeable so no future arithmetic can mix them.

Old journals keep their old field names and are **not** migrated (see Open decisions); the record's
docstring must say so.

**The sibling record is in scope, because the codebase explicitly ties them.**
`lib/lain/telemetry/seam_decision.rb:48` says the record "matches the sibling {Compaction} record,
which carries `tokens_before` and `tokens_after` for the same self-contained-audit reason", and
`Plan::SeamDecision` (`lib/lain/plan/seam_decision.rb:73,79,98-101`) is a genuine **reader** —
`chunk.tokens_before - chunk.tokens_after`, then `rewrite_cost(chunk.tokens_after, …)`. Renaming one
half of a declared pair relocates UX5's confusion instead of removing it.

**The pricing collision is this card's open fork and it must be resolved before implementation.**
`Scheduler#cost_saved`/`#cost_spent` (`lib/lain/compaction/scheduler.rb:290-302`) already do
`Usage.new(input_tokens: [before - after, 0].max)` and
`Usage.new(cache_creation_input_tokens: after)` — feeding the **byte** proxy into provider-measured
fields and pricing it at a per-**token** rate. So the units are not merely confusable in the record;
they are already being combined in production, and the dollar figures overstate by roughly the
bytes-per-token ratio. See Open decisions: either convert at the pricing boundary with a stated
divisor, or rename only and drop the non-combinable type. **Do not ship a type that forbids the
combination while `cost_saved` performs it.**

**Acceptance criteria:**

```gherkin
Scenario: the compaction record names its unit
  Given a compaction that shrank a span
  When its journal record is read
  Then the before and after figures are named in bytes
  And no field on the record is called tokens

Scenario: the sibling seam-decision record names the same unit the same way
  Given a seam decision record carrying the same proxy
  When its journal record is read
  Then its before and after figures are named in bytes too

Scenario: the compaction cost figures still reconcile with the resolved pricing decision
  Given a compaction priced against a model with a known rate
  When cost_saved and cost_spent are computed
  Then they follow the pricing decision recorded in Open decisions
  And a local model still reports honest zeros
```
→ spec files: `spec/lain/compaction/scheduler_spec.rb`,
`spec/lain/telemetry/compaction_spec.rb`

**Escalation triggers:**
- `Telemetry::Journalable#to_journal` (`lib/lain/telemetry.rb:17-36`) maps Data members to wire keys
  mechanically — there is no schema layer to absorb a rename. If you find yourself adding one, stop:
  that is a much larger design change.
- `spec/lain/status_feed_spec.rb:52-53,714` construct `Telemetry::Compaction` with keyword
  arguments, so a **retype** breaks them and not only a rename. Check both spellings.
- `StatusFeed#occupancy_of` (`status_feed.rb:346-352`, `INPUT_TOKEN_FIELDS` at `:211-217`) re-derives
  the three-way input-token sum from journaled string keys — a second parse path. If your change
  touches the measured side at all, that path must follow.
- Do **not** rename `used_tokens`/`window_tokens`: they are measured and honestly named already, and
  the QA scenarios' jq one-liners read them.
- **Stop at the pricing fork.** If Open decisions has not been resolved when you reach
  `scheduler.rb:290-302`, do not choose for yourself — the two branches produce different dollar
  figures on every compaction record this bench has ever written.

### T9 — Refuse a bad `lain up` before a pane exists to lose the message  [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/up.rb`, `lib/lain/cli/chat_launch.rb` (or wherever the `chat`
command's option surface lives — locate it first); modify `spec/lain/cli/up_spec.rb` and the chat
command's own spec
**Reuse:** the launch-level refusals already proven to fire before stdin is read — `--num-ctx`,
`--api-base`, `--compact-strategy`, the missing-API-key check — all of which refuse at construction
by name with exit 1 and no backtrace (verified across 19 refusals in QA round 5); `exe/lain:924`'s
existing `rescue Lain::Error => e; raise Thor::Error, e.message`, which already turns a `Lain::Error`
raised out of `launch_plan` into a clean one-line exit with no backtrace.
**Shared-file wiring:** none
**Reachable from:** `CLI::Up#call` (`up.rb:240`), the entry point for every `lain up`.

A construction refusal — a missing API key, an unknown provider, a bad `--num-ctx` — currently
reaches the operator only from inside a dying tmux pane, where tmux's dead-pane banner eats its first
line. `lain up` should discover it on the operator's own terminal before creating a session at all.

**`Up` must not learn to parse chat's flags, and the seam has to respect that.** `up.rb:296-302`
records the decision in as many words: *"`@chat_args` is the exe's `-- ARGS` trailing capture —
already `chat`'s own flags to validate, never Up's … Up never parses or knows the flag names."* An
earlier draft of this card required `up` to reproduce chat's construction refusals from `up.rb`
alone, which is impossible without parsing and which its own prose forbade.

**The shape that respects it: give `chat` a construction-only check and have `up` invoke it with the
argument vector it already builds, verbatim.** `up` passes `@chat_args` through untouched — exactly
as it already does when building the pane command — reads the exit status and stderr, and raises a
`Lain::Error` carrying that stderr, which `exe/lain:924` renders cleanly. No flag parsing in `Up`, no
duplicated refusal logic, one construction path. Any seam meeting those three properties is
acceptable.

**Acceptance criteria:**

```gherkin
Scenario: a construction refusal is delivered before any tmux session exists
  Given lain up invoked with arguments chat would refuse at construction
  When it runs
  Then it exits non-zero printing the refusal on its own stdout or stderr
  And no tmux session was created
  And stderr carries no backtrace frames

Scenario: a valid invocation is unaffected
  Given lain up invoked with arguments chat accepts
  When it runs
  Then the session is created and the chat pane is spawned as before

Scenario: the pre-flight does not consult the network
  Given lain up invoked with an unreachable api-base but otherwise valid arguments
  When it runs
  Then it still creates the session
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- The third scenario is the boundary and is easy to get wrong: `--api-base` failures are
  **turn-level, not launch-level** (`planning/qa/scenarios/failure-injection.md` §5), and a
  pre-flight that refuses an unreachable endpoint would stop the cockpit from opening for a
  temporarily-down model server. If you cannot separate construction failure from reachability
  failure, stop and escalate.
- `up_spec.rb` has a recorded history of load-induced flakes and the CLAUDE.md rule is to record
  flakes by NAME, never by line. If an existing example there fails, check the named-flake list in
  CLAUDE.md before assuming a regression.
- If pre-flighting requires constructing a real provider client (and therefore a credential), stop:
  the check must be construction-only.
- If your design has `Up` inspecting, splitting or interpreting any element of `@chat_args`, stop —
  that contradicts the decision recorded at `up.rb:296-302` and is the trap this card was rewritten
  to avoid.

### T10 — Surface what a chat pane died of, when it dies immediately      [wave 2] [risk: medium]

**Depends on:** T9
**Files:** modify `lib/lain/cli/up.rb`; modify `spec/lain/cli/up_spec.rb`
**Reuse:** `keep_failed_pane` (`up.rb:466`) and its `remain-on-exit failed`, which is what leaves a
corpse to read at all; `@tmux.run` vs `@tmux.act` (best-effort vs raising) as the existing degrade
convention; the tmux facts measured in QA round 5 — the server survives, the pane reads
`pane_dead=1 pane_dead_status=1`, and the banner costs exactly the first line; **`exe/lain:924`'s
`rescue Lain::Error => e; raise Thor::Error, e.message`**, which is the seam that lets this card stop
the exec without editing `exe/lain`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Up#call`, after `spawn_chat_pane` (`up.rb:345`) and before it execs
`tmux attach`.

T9 removes the refusals `up` can predict; this covers the ones it cannot — a pathological login
shell, an unexpected crash, an exec failure. If the chat pane is dead shortly after being spawned,
`lain up` should say so on the operator's own terminal, with whatever the pane holds, rather than
attaching them to a corpse or exiting silently.

Capture must read the pane's scrollback, not only its visible region, since tmux's banner has
already displaced the first line of the visible area.

**How to stop the attach without touching `exe/lain`.** The exec is unconditional in the exe
(`exe/lain:915-923`: `plan = …launch_plan(…)` then `Kernel.exec(*plan.argv)`), so a card that tried
to return a "don't attach" flag would have to edit a file outside this chunk's scope. It does not
need to: the exe already wraps that block in `rescue Lain::Error => e; raise Thor::Error, e.message`
(`:924-925`), so **raising a `Lain::Error` out of `launch_plan` both skips the exec and prints one
clean line with no backtrace.** Carry the captured pane text in that error's message.

**Acceptance criteria:**

```gherkin
Scenario: a chat pane that dies at once is reported on the operator's terminal
  Given a chat command that exits non-zero immediately
  When lain up runs
  Then it exits non-zero
  And it prints what the pane held, including the pane's first line
  And it does not exec tmux attach

Scenario: a healthy cockpit is not delayed noticeably
  Given a chat command that starts normally
  When lain up runs
  Then it attaches as before
  And the added wait is bounded by the stated threshold

Scenario: an older tmux without remain-on-exit still launches
  Given a tmux too old to hold a dead pane
  When the chat pane dies at once
  Then lain up still exits without raising an unhandled error
```
→ spec file: `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- `lain up` **execs** `tmux attach` and replaces its own process, and that exec lives in `exe/lain`,
  which is **not** in this card's Files and not in the chunk's shared-file list. If your design needs
  to edit `exe/lain`, stop and escalate — the `Lain::Error` path above exists precisely so it does
  not have to.
- A fixed wait on every launch is a tax on the common case. If the only way to detect death is to
  sleep the full threshold even when the pane is healthy, stop and escalate rather than shipping a
  slower `lain up`.
- On tmux < 3.2 `remain-on-exit failed` is skipped by design (`up.rb:455-465`), so the pane may be
  gone before it can be read. Degrade the way `keep_failed_pane` does — best-effort, never fail
  `lain up` for a diagnostic.

### T11 — Refuse a one-line file with advice it can act on                [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/tools/read_file.rb`; modify `spec/lain/tools/read_file_spec.rb`
**Reuse:** `LONG_LINE_NARROWER` (`read_file.rb:103-111`) — the correct sentence already exists and is
already sized against `Tools::Bash`'s ceiling; `Whole#capped` (`:220-222`), which already owns the
bounded `File.read(path, N)` primitive together with its encoding and frozen-string gotchas;
`Tool::Bounds::Artifact#refusal` (`tool/bounds.rb:166`), whose signature takes a size and no content
and must stay that way.
**Shared-file wiring:** none
**Reachable from:** `Tools::ReadFile#call` in the default toolset — the first refusal a model meets
when it reads an oversized minified bundle or one-line JSON.

A whole-file read of a single enormous line **over 1 MiB** is currently told to use `offset`/`limit`,
which count lines and therefore cannot narrow it; the model spends a round trip to reach the correct
refusal. The test is exact and bounded, not heuristic, and applies **only** to the `PART_ONLY`
branch: absence of any `\n` within `WINDOW_BOUND.limit + 1` bytes proves line 1 exceeds
`WINDOW_BOUND`, the same ceiling `LongLine` measures against.

**A newline-free file UNDER `WINDOW_BOUND` is not a bug and must keep its `FULL_COVER` advice** — a
full-cover window serves it. Widening this card to that branch would replace correct advice with a
refusal.

**Scan incrementally; do not slurp.** The probe must read in small blocks and stop at the first
`\n`, so an ordinary source file costs one block. `Whole#capped` (`:220-222`) is `File.read(path, N)`
— a single slurp — so reuse its encoding and frozen-string handling, **not** its shape: a 1 MiB
String allocated on every oversized refusal is a per-refusal megabyte on the tier-1 hot path, which
is the opposite of what `Whole#read`'s docstring (`:113-124`) promises. The worst case (a genuinely
newline-free prefix) is `WINDOW_BOUND.limit + 1` bytes read in blocks, never held at once.

**Match `LongLine`'s predicate exactly, or state the residual.** `LongLine` refuses when
`chunk.bytesize > @ceiling` over chunks from `File.foreach(path, WINDOW_BOUND.limit + 1)`
(`:341-342,421-423`), and a line of exactly `limit + 1` bytes *including* its `\n` arrives whole and
**is** refused. So a naive "is there a `\n` within `limit + 1` bytes?" probe answers *yes* for that
file and would offer a window `Window` then refuses — reintroducing the two-round-trip loop this card
exists to close. Align the boundary or record the off-by-one as a known residual.

The refusal must still carry no payload bytes, and the file must still never be fully materialised.

**Acceptance criteria:**

```gherkin
Scenario: a one-line file over the window ceiling is told to take a byte range
  Given a newline-free file larger than the window ceiling
  When it is read with no window
  Then the refusal names a byte range and says one line alone is over the ceiling
  And it does not advise offset and limit

Scenario: a newline-free file under the window ceiling still gets a full-cover window
  Given a newline-free file over the whole-read ceiling but under the window ceiling
  When it is read with no window
  Then the refusal offers a full-cover window
  And a full-cover window of that file then succeeds

Scenario: a many-line file is still offered a window
  Given a line-structured file over the whole-read ceiling but under the window ceiling
  When it is read with no window
  Then the refusal offers a full-cover window

Scenario: the refusal still carries none of the file's bytes
  Given a one-line file whose content is a recognisable sentinel
  When it is refused
  Then the refusal contains no part of that sentinel

Scenario: deciding costs a bounded read, not a materialised file
  Given a line-structured file far larger than the window ceiling
  When it is refused
  Then the probe stops at the first newline
  And no single allocation holds more than one block of it

Scenario: a line exactly at the window ceiling is not offered a window that fails
  Given a file whose first line is exactly the window ceiling plus one byte including its newline
  When it is read with no window
  Then it is not advised to use offset and limit
```
→ spec file: `spec/lain/tools/read_file_spec.rb`

**Escalation triggers:**
- `spec/lain/tools/read_file_spec.rb:523-532` asserts `File.read` is **never** called with the
  refused path, unqualified by length, so even a one-byte probe fails it. Rewriting it to bound the
  read rather than forbid it is in scope; **weakening it to assert nothing is not**. Confirm the
  replacement.
- `:534-541` uses `sparse("huge.rb", whole_ceiling + 1)` = 256 KiB + 1, a newline-free file in the
  `FULL_COVER` branch. It must keep passing **unchanged**. If your change makes it fail, you have
  widened the probe into the branch that has no bug — stop and re-read the ceilings.
- The probe belongs in `narrower_for`, **not** in `Whole#read` — with it confined to the PART_ONLY
  branch, `Whole#read`'s "never opened, let alone materialised" claim (`read_file.rb:113-124`) stays
  true for every file it decides, and `FULL_COVER`'s loop rationale (`:84-86`) stays true too. If
  your change makes either docstring false, you have put the probe in the wrong place.
- `spec/support/shared_examples/tier_one_read_contract.rb:68-87` includes a "one line and no
  separator anywhere" shape whose assertion derives error-ness from size alone. If your change makes
  that shared example fail, the contract is wider than this card — stop.

### T12 — Render a retry backoff a human can read                        [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/frontend/decorators/provider_retry.rb`; modify
`spec/lain/frontend/decorators/provider_retry_spec.rb`
**Reuse:** `Telemetry::ProviderRetry` (`lib/lain/telemetry/turn_stream.rb:104-107`), the single Data
type both providers push (`provider/ollama/retry_tap.rb:118,130`,
`provider/anthropic/retry_tap.rb:42,53`), so one decorator change covers both.
**Shared-file wiring:** none
**Reachable from:** the frontend's decorator chain renders `Telemetry::ProviderRetry` live on screen
during any retrying request; QA round 5 read it from a real ollama session.

`will_retry_in` arrives as a raw Float from the retry middleware and is interpolated directly at
`provider_retry.rb:35`, producing `retrying in 0.14368744774438316s`. The line is otherwise correct —
the attempt ordinals are right, and the give-up line names a higher ordinal than the last retry.

**Acceptance criteria:**

```gherkin
Scenario: a backoff is rendered to a readable precision
  Given a retry event whose backoff is 0.14368744774438316 seconds
  When it is rendered
  Then the rendered line shows a short rounded duration, not the raw float

Scenario: the give-up line is unchanged
  Given a retry event with no backoff
  When it is rendered
  Then it reads "giving up" and names its attempt ordinal

Scenario: a whole-second backoff does not gain a misleading decimal tail
  Given a retry event whose backoff is exactly 2 seconds
  When it is rendered
  Then the duration reads as a plain short value
```
→ spec file: `spec/lain/frontend/decorators/provider_retry_spec.rb`

**Escalation triggers:**
- QA round 5 pinned the ordinal sequence `1, 2, 3, 4` as the fix for round 4's F16, and
  `planning/qa/scenarios/session-and-window.md` §2 asserts it. If your change touches `attempt` at
  all, stop — only the duration is in scope.

### T13 — Record the orchestration-DAG gap and stop the roadmap overselling it [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `planning/qa/README.md` (known-gaps section)
**Reuse:** the existing "Known gaps — what no scenario covers" section of `planning/qa/README.md`,
which already records untested surfaces in exactly this form.
**Shared-file wiring:** `ROADMAP.md` — supply the prose for the buffer-surface line as a one-line
diff for the orchestrator to apply (it also adds this plan's index line; the two edits collide).
**Reachable from:** deferred: documentation only. This card deliberately builds no capability — the
DAG surface is out of scope by interview decision (see Open decisions), and this card exists so the
deferral is legible rather than looking like an oversight.

`ROADMAP.md:635` describes `lain://timeline` as "(the DAG)". It is not: `Buffers::TimelineView`
renders a linear first-parent chain from one head, and **no frontend file references `child_turn`,
`spawn` or message events at all**. `StatusFeed#observed` (`status_feed.rb:457`) publishes
`@fleet.keys` over a `{spawn_digest => true}` map (`:388`), so the fleet reaches the HUD as an
integer and no parent/child edge is available to any surface. QA round 5 ran a session with
`fleet 2` live and 29 `child_turn` plus 10 `message` records journaled, and nothing outside the
journal showed any of it.

**Acceptance criteria:**

```gherkin
Scenario: the known-gaps list names the missing surface
  Given planning/qa/README.md
  When its known-gaps section is read
  Then it records that no scenario covers subagent structure because no surface renders it
  And it names what a future scenario would need to drive

Scenario: the roadmap no longer calls the timeline buffer the DAG
  Given ROADMAP.md's neovim buffer surface line
  When it is read
  Then it describes lain://timeline as the first-parent chain it renders
  And it records the DAG surface as unbuilt
```
→ spec file: none — documentation only; verified by the integration checks below.

**Escalation triggers:**
- If `ROADMAP.md`'s line turns out to describe a surface that *does* exist somewhere this grounding
  missed, stop and escalate rather than editing the roadmap to match a wrong belief.
- Do not add a roadmap item committing to build the DAG surface — the interview deferred it without
  scheduling it.

## Integration checks

After the last wave:

1. `bundle exec rake pspec` green, and **check the example COUNT against a serial run** — a dead
   worker reports "fewer examples, 0 failures, non-zero exit", the same shape as an OOM kill.
2. `bundle exec rubocop` (bare — never name a `.toml` on the command line) and `pre-commit run
   --all-files`.
3. `bundle exec rspec --tag seam` — T4 and T7 both touch surfaces whose real behaviour lives in
   `:seam` examples driving live nvim and a real `Notify`. **Run this on a quiet box**: these are the
   239 examples CLAUDE.md measures at 54s of a 155s serial run, they drive real `git`/`tmux`/`nvim`
   against fixtures under a shared `$TMPDIR`, and a concurrent suite run makes a different example
   fail each time. Check `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` is 0 first.
4. **A manual pass the human must do, because no spec can reach it:** re-run the round-5 regression
   pair — `planning/qa/scenarios/failure-injection.md` and
   `planning/qa/scenarios/session-and-window.md` — plus the specific probes this chunk discharges:
   - fork **and** resume a session that spawned (F23) — the control is a session with no `message`
     records, which already forks;
   - three gated `bash` calls in one turn with `dunstify` on PATH, confirming three notifications
     and that answering one on the desktop decides that call (F24, T4) — and, with T4b landed,
     that answering one call at the TTY or in the editor makes its desktop popup GO AWAY while the
     other two stay up (F24's second limb);
   - `:LainReviewVerdict approve` over a partially reviewed changeset in a real cockpit, checking
     `nvim_get_mode().blocking` is false and `:messages` holds the full sentence (F25);
   - `lain://approval` present at rest with no window taken (UX4);
   - `lain up` with a missing API key, and with a chat command that dies at once (T9, T10).
5. Confirm the QA docs this chunk edits still describe the shipped behaviour: `planning/qa/method.md`,
   `planning/qa/scenarios/session-and-window.md`, `planning/qa/scenarios/cockpit-surfaces.md`,
   `planning/qa/scenarios/rails-blog.md`, `planning/qa/README.md`, and
   `planning/qa-findings-round5-2026-08-18.md`.
6. Verify the deferral is legible: `planning/qa/README.md` names the DAG-surface gap and `ROADMAP.md`
   no longer calls `lain://timeline` "the DAG".
