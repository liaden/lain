# Round 18 research: context window, compaction, secondary calls, read state

Tree: `main` at `90f081b9`. Read-only research: no suite, chat or model was run. Line numbers are
at that SHA. "Chunk" means `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`, and
"exec log" means its `## Execution log`.

Journals re-read for this note (evidence is quoted from them, not only from the findings file):
- rails session 3: `~/tmp/lain-qa-round18/xdg/state/lain/sessions/c43136602081/20260915T125210-3709651.ndjson`
- bowling session 1: `~/tmp/lain-qa-round18/xdg/state/lain/sessions/2ad18f1344a1/20260915T104728-3233451.ndjson`
- `records/summ-req.json`, and the fork reports `fork-fail`, `fork-review`, `fork-subag` and `fork-repl`.

---

## F136 — `WindowBook::Live` stops re-asking after 3 probes, so a session stays at a guessed window

### 1. Mechanism, re-verified
- `WindowBook::Live#reresolve` (`lib/lain/cli/backend/window_book.rb:189-195`) returns early unless
  `asking_can_help?`. That predicate is `@reasks < REASK_LIMIT && !settled?` (`:202`), with
  `REASK_LIMIT = 3` (`:167`) counted per `Live` instance, which means per run.
- `Middleware::ResolveWindow#call` (`lib/lain/middleware/resolve_window.rb:31-34`) calls it once per
  agent-loop **iteration**. So a run makes 1 probe at launch plus 3 re-asks. That matches the psfake
  N=4 evidence ("`/api/ps` asked 4 times and then never again").
- `WindowBook#book` (`:236-245`) falls to `ContextWindow.default` when `narrowest(reported)` is nil.
  `qwen3-coder:30b` is not in the shipped table, so the answer is 8,192 `guessed`.
- `Provider::Ollama#context_window_tokens` (`provider/ollama.rb:319-329`) answers nil in two cases it
  does not tell apart: "server answered, nothing resident" (psfake's `{"models":[]}`) and "server
  unreachable or timed out".
- `Compaction::Source#need_for` (`compaction/source.rb:507-512`) withdraws `:approaching_window`
  unless `resolution.authoritative?`.

**The finding is accurate. One consequence it does not name:** `Review::Critique::Budget.for`
(`review/critique.rb:222-227`) refuses `/critique` with `UNVOUCHED` on a guessed window. So F136 also
disables `/critique` for the rest of such a session.

### 2. Most recent change
- **Not touched by the round-17 chunk.** No card lists `window_book.rb`, and its last functional
  change predates the chunk. `git log` on the file: `05c972ed`, `1fea6fb0`, `2071f088` and
  `8e3f4b38` are comment or fold commits; `b2516601` added the cloud windows.
- **Established by `2301a03d`** (2026-08-18, "cli: refuse a --num-ctx the model cannot serve, and let
  the window correct itself"). That is T6 of `planning/archive/chunk-qa-round3-defects.md`, whose
  intent was "The book stops being a permanent answer". `REASK_LIMIT`, `Live` and `ResolveWindow` all
  arrived in that one commit (`git log -S REASK_LIMIT`).
- **Adjacent follow-up from T24's re-review** (exec log): "`WindowBook` keeps a stale smaller
  runner's context after ollama reloads a bigger one, so occupancy reads about 100% and compaction
  can fire early." This is the same object from the other side: once `probed`, it never asks again.

### 3. Why it is this way
- **The limit is a deliberate behaviour change from T6's fix round.** Before `8e3f4b38` stripped the
  ticket id, the spec comment read "T6 FIX ROUND, and a behaviour change made deliberately".
  Today's `window_book_spec.rb` says: "'Re-resolves until authoritative' silently means 'never
  stops' for the users least able to diagnose it … Measured against a black-holed host at 2.003s
  per re-resolution … a ten-tool-call turn paid +20s for a number that was never going to arrive."
- **Why three.** The in-code reason (`window_book.rb:159-162`): "ollama fixes a runner's context at
  LOAD time and the first request is what loads it, so an answer that is coming arrives by the
  second iteration's refresh; the third is slack for a first request that failed."
- **Why giving up keeps a guess.** "Giving up is not settling: … an exhausted budget still
  authorises no rewrite" (`:164-166`). That guard is also why F136 turns compaction off rather than
  mis-firing it.
- **What the limit protects against.** `docs/providers/ollama.md:141-148` states the cost model: a
  black-holed host costs 2,002 ms per probe, while "A merely *down* ollama is unaffected: it answers
  ECONNREFUSED in ~0.3 ms".
- **Where the premise breaks.** It assumes the chat's own first request is the only thing touching
  the server. F154 contention, a `--secret-oracle` or summarizer on another local model, or a
  `KEEP_ALIVE` eviction all break that assumption.

### 4. Classification
**(c) Pre-existing, never touched by the chunk.** The bound is a deliberate design decision whose
stated premise the round falsified. F154 made it reachable on this box.

### 5. Constraints and open questions
**Constraints:**
- **The black-holed-host bound must survive.** A fix must not bring back a ~2 s probe per iteration.
  Because `context_window_tokens` returns nil for both "answered, empty" and "timed out", any rule
  that separates them needs a provider-side change. Both provider and book specs pin the nil
  contract.
- **Per-turn agreement is the invariant** (`resolve_window.rb` header, and round 3 T6's escalation
  trigger): re-resolve once per turn, never per read. The three readers (`StatusFeed`,
  `Compaction::Source`, `Agent#occupancy`) share one book **object**.
- **A guess must never authorise a rewrite.** Pinned by
  `window_book_spec.rb` "keeps the exhausted answer a guess, so it still authorises nothing".
- **Specs that pin the current count:**
  - `spec/lain/cli/backend/window_book_spec.rb`, "the budget on re-asking": `asked == 4` after 10
    re-asks, and "still upgrades a guess that arrives inside the budget".
  - `spec/lain/seams/window_self_correction_spec.rb`, which by its own comment "holds the limit up
    from BELOW (drop it to 2 and these examples red), while the never-settle group holds it from
    above".
  - `spec/lain/seams/recorded_run_spec.rb`, whose cassette holds exactly ONE `/api/ps` for a two-turn
    run, so an authoritative answer must stop asking.
- `docs/providers/ollama.md:146` documents "`1 + REASK_LIMIT` probes per session" and would need
  restating.
- A `num_ctx` that clamps a reported window keeps `probed` (`window_book.rb:270-273`); that ruling is
  from round 3 T6's escalation triggers.

**Open questions for the human:**
- Should the budget count **wall time spent on probes that timed out** rather than attempts? The
  documented harm is the timeout cost, not the attempt count.
- Should a T24 over-window 400, which carries the server's `n_ctx` (`provider/ollama.rb:384-387`), be
  allowed to vouch for the window? Today it only becomes a reading (`Accounting#observe_refusal`).
- Should the stale-smaller-runner follow-up from T24's re-review share the fix? Both are "the book
  stops listening to the server".

---

## F173 — compaction cannot make room once the `keep_last` tail approaches the window

### 1. Mechanism, re-verified, with corrections
**Confirmed.**
- `Head.new(messages: held_cut.remaining, keep_last: @derived.keep_last, pins:)`
  (`compaction/source.rb:473`) measures only the span past the held cut and before the last
  `keep_last` (default 20, `cli/backend.rb:87`). Nothing inside the tail is droppable.
- `Scheduler::Rewrite#shrinks?` is `after < before` (`compaction/scheduler.rb:71`), a strict saving
  of any size. `Source#weigh` (`:560-575`) therefore commits a rewrite that moves a few hundred
  bytes, recorded `compacted: true`.
- `HeldCut.holds?` (`source/held_cut.rb:40-42`) holds a cut only while `at.fetch(cut.digest) <
  boundary`, the keep_last boundary. A cut can never reach into the tail.

**Confirmed from the journals.**
- Bowling: cuts at 11:19:08, 11:19:29, 11:20:54 and 11:22:01, the last moving `63697→63553`
  (`head_bytes: 1009`). Then `window_pressure` at 33,718, and 33,771 on later asks.
- Rails 3:
  - 13:00:27, a composed cut `66625→47202` (b5150d23), refused at 33,105.
  - 13:02:07 and 13:03:39, each `bytes_before 47347→46930` / `47314→46897` (`head_bytes: 745`),
    refused at 33,129 and 33,122.

**Mechanism the finding does not name: the same cut is re-committed on every stuck ask. This is a T7 × T24 interaction.**
- In rails 3, `compaction_cut digest=fada27bd` was committed at head `7677e117` (13:02:07), and again
  with the **same digest and parent** at head `a047bbe6` (13:03:39).
- Each time, `Agent#withdrawing` (`agent.rb:336-341`) put the head back to `6816cff1`
  (`run_interrupted head=6816cff1`), because the asked user turn was still the head.
- The cut's commit head therefore left the chain, `HeldCut.holds?` failed on `at.key?(cut.head)`, the
  cut retreated to b5150d23, and the next ask re-derived and re-committed fada27bd.
- So the 417-byte "advance" is really a retreat and re-advance per ask. It is not a fresh cut each
  time.
- In bowling, `93142d2b` was re-committed the same way after `/rewind` (11:22:01 at `98485fab`, then
  11:28:14 at `1b7081e8`).

**Corrections to the finding's wording.**
- **"The refusal still names 'compaction' as the remedy"** is true only while the last decision had
  something droppable: `MOVES.fetch(@compaction.droppable?)` (`middleware/request_budget.rb:35-40, 76`).
  - Rails 3: every decision had `nothing_droppable: false` (`head_bytes: 745`), so every refusal led
    with compaction. True there.
  - Bowling: the decisions after 11:22:03 read `nothing_droppable: true, head_bytes: 2`, so later
    refusals used `MOVES[false]` ("…Nothing older can be compacted yet, so make room with
    /rewind…"). Only the first refusal named compaction.
- **"The second names a launch flag (`--compact-keep`)" is wrong about the refusal.**
  `RequestBudget::MOVES` names compaction, `/rewind`, `/unpin` and a narrower read, and never
  `--compact-keep`. The flag appears in a **different surface**, `Source::Diagnosis#remedy`
  (`source.rb:274-278`): "unpin a turn, lower --compact-keep, or start a new session". That is the
  stderr `lain:compaction` stall line, printed once on the edge when `nothing_droppable &&
  approaching_window` (`Reporting#record`, `:307-314`). Bowling's post-11:22 decisions meet that
  condition. The pane recordings (`bowl-chatpane`, `rails3-chatpane`) are 3–4 bytes, so neither
  surface's text could be re-read.
- **"Every stuck ask still pays one summarizer call"** is not supported by the rails 3 journal: there
  is no `oracle_answer` between 13:01 and 13:04. It may hold elsewhere, but it is unverified here.

### 2. Most recent change
- **T7 `acfed808`** (held cut, `HeldCut`, `CompactionCut`).
- **T24 `4cf30b98`**:
  - `truncate: false`, `RequestBudget`, `Accounting#observe_refusal`, the prompt withdrawal;
  - the `droppable?` added to `Source::Reporting` (`source.rb:298-309`) to choose the refusal words.
- **`keep_last` as a message count** dates to the derived-context work (`Compaction.validate_keep_last`,
  `compaction.rb:38-80`) and `DEFAULT_KEEP_LAST = 20` (`cli/backend.rb:84-87`). Neither chunk changed
  it.
- **Prior art for this shape:**
  - **F82**, round 15: "one oversized tool result pins the context with nothing to compact".
  - Round 15's chunk (`planning/archive/chunk-qa-round15-what-nothing-retires.md:280-291`) gave it the
    stall report and deferred the bound.
  - Round 16's chunk bounded `subagent`/`run_skill`/`ask_human` results.

### 3. Why it is this way
- **T7's rulings (exec log, "T7 review rulings").**
  - "A cut holds while the head it was **committed at** is on the chain; 'the cut wins over
    `keep_last`' is dropped."
  - The card's intent: "The cut advances only when a signal fires again and the span after the cut
    is droppable."
  - `held_cut.rb:18-19` gives the boundary rule's reason: it "keeps a resume under a larger
    `--compact-keep` from collapsing turns keep_last retains".
- **T7 Open decision S4, owed.** "held replacements never re-collapse, so ten cuts under
  summarize-conversation render ten summaries, with no remedy once the window fills past the cut."
  - `ARCHITECTURE.md` (added by `acfed808`) restates it: "Two consequences are open decisions rather
    than behaviour: held replacements are never re-collapsed, so summaries accumulate one per
    advance…".
  - It is listed again under the Close-out's "Human decisions still owed".
- **T24's redesign (exec log).** Ruling: send `truncate: false`, so the server "refuses an
  over-window prompt with HTTP 400 carrying the exact prompt count", and `RequestBudget` supplies "a
  believed reading so compaction fires".
  - The card's own escalation trigger foresaw this shape: "A refusal that repeats every turn with
    nothing compactable is F82's shape. If compaction (T7's cut) would have shrunk the request, the
    budget must not fire before the pipeline runs."
  - The redesign honours the ordering, since the provider refuses after render. It cannot make a
    tail-only overflow compactable.
- **The `droppable?` choice of words** is T24's own. `RequestBudget` comment (`:32-34`): "Offered
  over an empty head, compaction is the one move that cannot happen."
- **Open decision 2** (chunk `:289-293`): "A window-relative `read_file`/tool result bound (F90's
  third leg) is deferred. `Tool::Invocation` carries no window … T24 makes an over-window request
  **visible and refused before send**, which is the harm." T24's card: "**Open decision 2 stands**".
- **Round 15 deferral 1** (`chunk-qa-round15-what-nothing-retires.md:280-291`): "No bound on a single
  tool result's contribution to the retained tail — deliberately not taken here … a policy question
  about `Tool::Bounds` across eleven tools — a chunk, not a card. It is owed, and F82's fix must not
  be read as having closed it."
- **Withdrawal scope** (`agent.rb:221-227`): "only while that text is still the head: a tool round
  that ran before a later refusal in the same ask is work that happened, and stays."

### 4. Classification
**(b) A gap outside the cards' scope, known and deferred.** Round 15's deferral and round 17's Open
decision 2 both name it, and T7's S4 ruling is still owed.
- T24 made the wedge **visible** as a refusal, where it used to be silent truncation. That is by
  design, not a regression.
- The re-commit-per-ask detail is a T7 × T24 interaction neither card considered, since T7 predates
  T24's withdrawal. It is (b) as well: a cost and a noisy record, not a wrong render.

### 5. Constraints and open questions
**Constraints:**
- **The Timeline stays lossless and the derivation non-recursive.** T7 card: "If the derivation
  itself has to hold a derived head to meet the ACs, stop — that is the ruled-out design."
- **Do not relitigate "the cut wins over `keep_last`" is dropped** (T7 ruling) without the human.
  A fix that elides tool results *inside* the tail reopens exactly that question, and
  `HeldCut.holds?`'s boundary rule (the `--compact-keep` resume guarantee) must hold or be restated.
- **Compaction must stay Ractor-shareable.** Pipelines are `Ractor.make_shareable`, and the cut lives
  in `Source`, never captured in a pipeline (T7 escalation trigger; `derived.rb:15-23`).
- **No estimate before send.** The T24 redesign removed the calibration after measured failure
  (3.3x token/byte variance). A byte-budget tail ("N messages or M bytes") must not quietly
  reintroduce a token estimate that decides refusals.
- **`shrinks?` is a strict saving on purpose** (`source.rb:51-56`: "a byte-NEUTRAL rewrite is
  declined too"). A minimum-fraction floor is a new policy, and a bench arm reads `compacted`.
- **Specs that pin current behaviour:**
  - `spec/lain/compaction/source_spec.rb`: held-cut groups, "extends the derived chain turn by turn
    while a committed cut holds", the retreat-on-rewind group, `would_not_shrink`.
  - `spec/lain/compaction/derivation_spec.rb`: the cut and no-cut negatives,
    `derivation_spec.rb:524`.
  - `spec/lain/compaction/boundary_spec.rb` and `head_spec.rb`: the keep_last cut.
  - `spec/lain/middleware/request_budget_spec.rb:101-147`: MOVES wording by `droppable?`.
  - `spec/lain/seams/over_window_request_spec.rb:106-113, 166-181`: "compacts against the refused
    prompt's exact count".
  - `spec/lain/session_record/replay_spec.rb`: a resume folds cuts.

**Open questions for the human:**
- **Rule on S4.** Should held replacements be re-collapsible, which amounts to a cut of cuts?
- Should the tail bound be window-relative, i.e. Open decision 2 generalised from per-tool to
  per-tail?
- Should a withdrawal (or a head move below a cut's commit head that only removed an unanswered user
  turn) keep the cut rather than retreat it? This would stop the re-commit-per-ask.
- Should the refusal name the `/rewind` count that would fit, as the finding proposes? That needs a
  token figure per turn the journal does not hold; only request-level counts exist.

---

## F199 — a read no model saw still counts complete for `edit_file`

### 1. Mechanism, re-verified
- `ReadFile::Read#deliver` (`tools/read_file.rb:162-167`) calls `session.record_read(path, complete:)`
  at tool **execution**, before the tool result is committed or sent.
- A window covering the whole file counts complete (`edit_file.rb:69-72`; `read_file.rb:77`).
- `Session#record_read` (`session.rb:134-140`) adds to `ReadSet`, which is add-only by design
  (`session.rb:574-597`).
- `Agent#withdrawing` (`agent.rb:336-341`) only resets `@timeline`, and only when the asked text is
  still the head. In FI-2's reproduction the tool round stayed on the head, so nothing was withdrawn.
- `Agent#rewind` (`agent.rb:322-332`) moves the timeline and calls `reopen!`. It touches neither the
  Session nor Accounting.
- `SessionRecord::Replay` (`session_record/replay.rb:84`) folds every `session_read` back, so a
  `--resume` carries the unseen read too.
- The `edit_file` contract (`edit_file.rb:81-83`) asks only `session.read?`.

**The finding is accurate.** Two additions:
- **The hole predates T24.** Before `truncate: false`, ollama silently truncated the same request, and
  the model also never saw the lines. The fork report says as much: "`/rewind` past any read has the
  same hole, and it predates T24".
- **It also survives `--resume`** through replay.

### 2. Most recent change
- **`ReadSet`'s add-only design.** Established in `08b9ab01` (2026-07-13, "Add Lain::Session for
  per-run read-set") and `e3246254` (journal/replay). Windows were added in `04282fef`/`036e6ec0`
  (2026-08-18), with "a window covering the whole file records a COMPLETE read".
  - `9b1494d9` (2026-09-12) folded the journalling decorator into Session.
- **Round 17 chunk.** No card touches `session.rb`'s read-set (T7 edits `session.rb` for cuts only).
  T24 `4cf30b98` added `withdrawing`, which deliberately keeps a tool round on the head.

### 3. Why it is this way
- **`session.rb:574-593`**: "THREE add-only sets, never a flag per path, and that is the whole design:
  membership, completeness and masking only ever move forward, so a sibling fiber cannot race a
  complete read backwards into a partial one … over-strict on purpose, and NOT to be fixed with a
  delete." The last clause is written about masking. The monotonicity argument, parallel-safe
  sibling reads, applies to completeness too.
- **T24** (`agent.rb:221-227`): "a tool round that ran before a later refusal in the same ask is work
  that happened, and stays."
- **The read-before-edit contract's purpose** (`edit_file.rb:73-76`): "editing it would clobber lines
  you never saw." That is the premise the hole defeats.

### 4. Classification
**(c) Pre-existing, never touched by the chunk.** T24 made it the ordinary route on a 32k window
(FI-2 "Why it matters"), but did not create it.

### 5. Constraints and open questions
**Constraints:**
- **`ReadSet` monotonicity is load-bearing** for parallel read fibers.
  - Pinned by `spec/lain/session_spec.rb:85-89` ("never downgrades a complete read when the same path
    is later read partially") and `:874-875` (no record replays as a downgrade).
  - The fix shape "undo the record on withdrawal and rewind" collides with that. "Key the read set
    to the producing turn" (reads valid only while their result turn is on the chain) does not
    remove members, but it is a new design that must be argued against the header.
- **Masking stays add-only** (`record_masked_read`, `Telemetry::ReadRedacted` replay) whatever
  happens to completeness.
- **Replay parity.** Whatever retracts or scopes a read must reach `--resume`
  (`session_record/replay.rb:84`, `spec/lain/session_record/replay_spec.rb`).
- **T24's tool-round-stays rule** is pinned by `spec/lain/agent_spec.rb:1017-1021`.
- **Children have their own fresh Session** (`tools/subagent.rb:1096-1102`) and must stay isolated.

**Open questions for the human:**
- Is "a read counts once its result is on the current chain" the rule? And "delivered" meaning the
  model answered a request carrying it, which is a stricter rule that also covers the tool-round-stays
  case with no rewind?
- Should a read whose result was compacted (elided or summarized) keep counting complete? The model
  once saw it. This is a consistency question the same rule would have to answer.

---

## F152 — the ollama-cloud summarizer never summarizes, and the failure leaves no record

### 1. Mechanism, re-verified
- `Oracle::Model#structured_answer_format` (`oracle/model.rb:91-96`) sends the schema whenever
  `@provider.supports?(:structured_output)`.
- `Provider::Ollama::Deployment::CAPABILITIES = %i[streaming thinking structured_output]`
  (`provider/ollama/deployment.rb:99`) is returned for **both** deployments (`:288`).
- `records/summ-req.json` shows `extra.structured_output.schema` sent to `gpt-oss:20b-cloud`.
- `JsonDecoder#call` (`model.rb:100-104`) raises `UndecodableAnswer`.
- `Oracle::Eager#fire` (`oracle/eager.rb:74-93`) rescues `ScriptError, StandardError,
  SystemStackError` and holds nothing.
- `Recorded::Journaling#ask` (`oracle/recorded.rb:112-122`) journals an `OracleAnswer` only after
  `await` succeeds.
- `Summarizer#tier` (`cli/backend/summarizer.rb:49-54`) wraps `Provider::Journaled`, so
  `request_sent` lands before dispatch.
- `Oracle::Summarize::TEMPLATE` (`oracle/summarize.rb`) never asks for JSON in prose. It relies
  entirely on the format constraint.

**Accurate, with one nuance.** "Nothing is journaled but a paid `request_sent`" is **the designed
failure signal**, not an oversight: see §3. What is missing is a record that tells a decode failure
from a capacity skip.

### 2. Most recent change
- **T14 `bfe984e9`** touched `oracle/model.rb`, but only the `extra:` merge, putting the schema over
  the caller's options (`model.rb:75`). No behaviour change for this finding.
- **Established by:**
  - `a0655c6e` (2026-08-17), "oracle: ask for structured output where the provider offers it";
  - `fb0c74f9` (2026-08-20), "oracle: journal the model round trips the oracle tiers make";
  - `db6698c0` (2026-07-21), `Oracle::Eager` containment;
  - `08b28bf0` (2026-08-24) and `7acae692` (2026-09-12), one `Deployment` value with identical
    capabilities.

### 3. Why it is this way
- **`a0655c6e`'s message:** "qwen3-coder answered the summarizer in markdown, raised
  UndecodableAnswer, and every span stayed uncollapsed -- while ollama had declared structured_output
  all along." So structured output was the chosen fix for exactly this failure on the local arm. It
  was never verified on the hosted arm.
- **`fb0c74f9`'s message:** "an eager summary refused by a busy gate now leaves a request with no
  answer beside it. The answer's absence is the signal." `eager.rb:23-29`: "That PAIR is the skip,
  and the shape to read the journal for."
- **Containment is the task boundary's purpose** (`eager.rb:17-21`): "Oracles have no rejection
  channel, so there is nowhere for the failure to go." `oracle/summarize.rb`: "A tier that is absent
  or down is a MISS, not an error".
- **`deployment.rb:93-99`:** "IDENTICAL on both arms, which is the point of the cut: same encoder,
  same decoder, same wire, so the only variables that moved are hosted-ness and model class." So
  per-deployment capabilities are a deliberate experimental-control decision.
- **Precedent inside the repo** (`oracle/secret_read.rb:69-78`): the secret-read template ends by
  asking for JSON because "a template that asks only for a verdict gets exactly what it asked for …
  raised {Oracle::UndecodableAnswer} 4 times out of 4 … since a fault journals no
  {Telemetry::OracleAnswer} the confidence data … never accrued either. No other template in the
  repo says 'JSON'." The silence of a decode fault is therefore already known and accepted there.
- **`cli/backend.rb:38-43`** (`InvalidCeiling`): "{Oracle::Eager}'s task boundary swallows that BY
  DESIGN, leaving 'compaction quietly stopped summarizing' as the only symptom."

### 4. Classification
**(c) Pre-existing behaviour the chunk never touched.** The silent rescue and the absence-as-signal
record are by design (d-flavoured). The hosted model ignoring the schema is a new fact against a
capability that is declared per deployment rather than per model.

### 5. Constraints and open questions
**Constraints:**
- **The turn must never wait on or die from a summary** (`Eager` containment,
  `spec/lain/oracle/eager_spec.rb`). `queue: false` is the eager tier's alone
  (`summarizer.rb:34-43`).
- **The Anthropic path's request bytes stay unchanged.** `spec/lain/oracle/model_spec.rb:71-127` pins
  byte identity, and this was T14's escalation trigger.
- **`Deployment::CAPABILITIES` identical on both arms** is a stated control. A per-model capability
  is a new axis the human should approve.
- **Replay keys.** `OracleAnswer` is what `Recorded.from_journal` replays. A new failure record must
  not be read as an answer; `Recorded#ask` raises `Unrecorded` on a missing one.
- **Pinned shapes:** `spec/lain/oracle/eager_spec.rb` (the request-without-answer example from
  `fb0c74f9`) and `spec/lain/oracle/model_spec.rb:59, :100`.

**Open questions for the human:**
- Journal a failed fire (for example `oracle_failed` with the error class), which amends the
  "absence is the signal" ruling? Or keep that ruling and fix by asking for JSON in the template, the
  secret-read precedent?
- Should a JSON-in-text fallback decoder exist? It changes what counts as an "answer" for replay.

---

## F154 — `LAIN_NUM_BATCH` is read only by `lain chat`

### 1. Mechanism, re-verified
- `ModelFlags.throughput` declares `:num_batch`/`:num_ctx` with
  `default: EnvDefaults.numeric("LAIN_NUM_BATCH")` (`exe/lain:778-789`). `ModelFlags.declare` is called
  for `chat` only (`exe/lain:1033`).
- `Backend#sampler_extra` (`cli/backend.rb:602-606`) reads `@options[key]`, so a command whose options
  hash lacks `:num_batch` sends none.
- **Commands affected:**
  - `bench arms`: `ARMS_FLAGS` (`exe/lain:630-631, 641`).
  - `epic submit` adjudication: `EpicSubmit::Adjudication.flags` (`cli/epic_submit.rb:601-604`).
  - `consolidate` and `improve`: `JournalPassFlags` (`exe/lain:1130-1149`); `consolidate.rb:30-34`
    and `improve.rb:125-128` use `backend.context`.
  - **Also `bench record`**, which the finding omits: `RECORD_FLAGS` (`exe/lain:553`).
- `PaneCommand` forwards `LAIN_NUM_BATCH` to panes (`cli/pane_command.rb:28`), so chat panes are fine.

**Accurate. `bench record` belongs on the list too.**

### 2. Most recent change
- **T14 `bfe984e9`**: `tier_options`, `RUNNER_KEYS` and `OLLAMA_ONLY_KEYS` for secondary tiers
  inside a chat.
- **T16 `13b5e71c`** touched `bench arms` for `--cheap-model` without adding throughput flags.
- The env-default-in-Thor shape predates both.

### 3. Why it is this way
- **T14's scope.** Its "Reachable from" names only the chat's three tiers: `summary_oracle`,
  `SpanSummarizer#tier` and `SecretRead.tier`. The design: "It carries them only when the tier's
  model **equals the chat's model** on the same ollama endpoint: the one case where a mismatch reloads
  the chat's runner (F95)." F95 was filed about summarizer/oracle requests (round 17 findings
  `:299-315`). No other command was in either the finding or the card.
- **T14 escalation trigger:** "`SecretRead`'s `qwen3:4b` evicts the chat's model on one GPU. This card
  fixes `-b`, not residency."
- **Why the env is read in the exe** (`exe/lain:766-777`): a Thor default that resolves to nil when
  unset keeps "the payload stays byte-identical"; "a LITERAL default … puts an `options` object on
  every ollama request in the process". `Backend#sampler_extra` (`:596-601`): "an encoder-side default
  would put an `options` object on every ollama request".
- **`EnvDefaults`' header:** "The environment may say how the model answers; it may never say what
  lain is allowed to do". `num_batch` falls on the permitted side.

### 4. Classification
**(b) A gap left outside T14's scope.** The card did not know; neither the findings nor the card
mention non-chat commands. Method now records it as a process rule (P41; `planning/qa/method.md:473-480`,
uncommitted in the working tree).

### 5. Constraints and open questions
**Constraints:**
- **A flagless run sends no `options`.** Pinned by `spec/lain/cli/backend_spec.rb`'s no-options
  example, which `exe/lain:776-777` names, and T14's "a flagless run still sends no options".
- **Ollama-only keys never reach the Anthropic wire** (`OLLAMA_ONLY_KEYS`; T14's "an Anthropic tier
  never receives ollama options", pinned in `backend_spec.rb`/`model_spec.rb`).
- **Keep the env read out of `Backend`, in the exe `default:` slot.** A `Backend` that reads `ENV`
  would make lib specs depend on the QA box's exported `LAIN_NUM_BATCH`.
- **Metrics.** `CLI::Backend` sits at its ClassLength cap (chunk Orchestrator contract), and the exe
  bands exist because of cop pressure (`exe/lain:715-725`).
- **Residency is out of scope**, per T14. The `bench arms` routing arm's `--cheap-model` is a
  different model and will evict regardless.

**Open questions for the human:**
- Should every model-calling command declare `ModelFlags.throughput`, or should there be one shared
  flag band? It adds `--num-ctx` too, which changes those commands' window semantics.
- Should `bench arms`/`bench record` record `num_batch` in their session header for comparability?

---

## F160 — critique children: reads unbounded by the window, raw 400 JSON, no `RequestBudget`

### 1. Mechanism, re-verified
- **Model phase.** `Wiring#model_phase` (`cli/wiring.rb:557-560`) is the only construction of
  `Middleware::RequestBudget`. Children are built in `Tools::Subagent`'s `spawn_agent`
  (`tools/subagent.rb:1120-1128`) with no `model_middleware:` and `journal: Channel::Null.instance`.
- **Error text.** `Provider::Ollama` raises `WindowExceededError.new(wrapped.message, …)`
  (`provider/ollama.rb:375-376`), whose message is the raw JSON body.
- **Critique path.** `Review::Critique#answer` (`review/critique.rb:178-185`) rescues `StandardError`
  and uses `e.message` as the chunk's text, and `#rendered` merges it verbatim (`:202-208`).
- **Read budget.** It is a heuristic only: `Budget#room` (`critique.rb:239`) is
  `(window - reserved - skeleton) / READ_SHARE` with `READ_SHARE = 2` (`:56-59`). Nothing enforces
  the other half.

**Accurate.** On the subagent path, SB2 adds that the parent model's `tool_result` is the same raw
JSON, which is F137's neighbourhood.

### 2. Most recent change
- **T21 `3ec1dc79`** (critique, `READ_SHARE`, window-sized chunks).
- **T24 `4cf30b98`** (`truncate: false`, which is what makes a child's overflow a 400 rather than a
  silent truncation; `RequestBudget` on the main stack only).

### 3. Why it is this way
- **T21 design:** "Chunks are sized to the child's window. Without this, every chunk child re-creates
  F90 on a local model … and **T24 does not cover child requests**."
- **T21 code** (`critique.rb:27-30`): "a chunk's content may take only half of what that leaves,
  because a child told it may read has every read's result ride its NEXT request."
- **T24 escalation trigger:** "**Child agents.** A child's requests are not journaled (`request_sent`
  is main-agent only). If the budget must cover children (T21's chunk children), stop and name the
  construction site." The exec log records no escalation on it, so children stayed uncovered.
- **Open decision 2:** per-tool window-relative bounds deferred; `Tool::Invocation` carries no
  window (`tool/invocation.rb:16`).
- **Why the child journal is Null, a deliberate decision** (`subagent.rb:1113-1119`): "a child's in
  the parent's file would read as the parent's: salvage would pair it with the parent's in-flight
  `request_sent`, cache-waste would count it, and the ledger would price it as the parent's spend."
  Grounding §3 of the chunk says the same.

### 4. Classification
**(b) A gap outside the cards' scope, and known.** T21's text and T24's trigger both name it, and
Open decision 2 deferred the read bound. The raw-JSON text is a consequence of T24's
`truncate: false` meeting T21's generic `rescue` (a message nobody worded), not a regression in
either card's own ACs.

### 5. Constraints and open questions
**Constraints:**
- **A child's `window_pressure` must not reach the parent's tee unscoped.** `StatusFeed#observe_refusal`
  (`status_feed.rb:307, 317-319`) takes ANY `WindowPressure` as the HUD's occupancy, so a child's
  record would overwrite the parent's reading. The same applies to salvage and cache-waste pairing
  (`subagent.rb:1113-1119`).
- **`RequestBudget` takes `compaction:` for its words.** Children have no compaction source; the Null
  `PipelineSource.droppable?` is false (`agent/pipeline_source.rb`), which yields the "withdrawn …
  /rewind" wording. That is wrong for a child nobody can `/rewind`.
- **Pinned by T21:**
  - `spec/lain/review/critique_spec.rb:172-181` pins that a failed child's `e.message` appears in the
    findings ("the provider fell over").
  - `:241-250` pins "under 60% of the window" for first requests.
  - `spec/lain/seams/critique_over_held_review_spec.rb`.
- **T21 escalation trigger:** "If sizing needs `Bounds` to split one file's hunks across chunks,
  stop." Also `spec/tool_bounds_discipline_spec.rb`.
- **No pre-send estimate** (T24 redesign ruling).

**Open questions for the human:**
- Take Open decision 2 now, as window-relative read bounds (at least for `diff_critic`)? Or compose a
  child-side budget whose record goes to the seam's journal, not the tee?
- What should a chunk that died over-window say? A worded refusal naming the chunk, or a retry at a
  narrower share?

---

## F161 — `/pin` of a `tool_use` turn disables compaction

### 1. Mechanism, re-verified
- **What bare `/pin` picks.** `Pin::Target#last_assistant` (`cli/command/pin.rb:67-72`) picks the
  newest assistant turn. At a parked `ask_human`, that is the `tool_use` turn.
- **What the reply promises.** `Pin#call` (`:108-112`) answers "compaction keeps this turn".
- **Derivation.** `Source#pinned` (`compaction/source.rb:451-455`) maps pins to messages, and
  `Derived::PinCuts` (`source/derived.rb:292-344`) cuts ranges around them. When the matching
  `tool_result` falls inside a collapsed range, `Derivation` validates its projection, raises
  `Derivation::Invalid`, and `Derived#refused` journals `derivation_refused` with a rising
  `consecutive` (`derived.rb:176-190, 216-220`).
- **What renders.** The turn falls back to the held or uncompacted render (`source.rb:566`).
- **Documented** at `derived.rb:36-42`: "a session pinned that way stops compacting for as long as the
  pin stands".

**Accurate.** Not fully silent: after a streak of 2 (`STALLED_STREAK`, `derived.rb:55`) the prompt
line and HUD say "compaction stalled", which R5 saw.

### 2. Most recent change
- **No round-17 card touched pins.** `pin.rb` history: `58566764` (2026-07-25, "session: pin turns the
  compactor must not touch"), `d839c822`, `8e3f4b38`, `9b1494d9`.
- **The refusal-not-400 behaviour** came from `ef736543` (2026-07-27, "compaction: render every chat
  turn through the derived chain").
- **T7 `acfed808`** added the sibling case S5.

### 3. Why it is this way
- **Follow-up 14** of `planning/archive/chunk-derived-context-timeline.md:1791-1797`: "A pin inside the
  span can strand its tool counterpart, producing a 400 … The repair is a design decision about pin
  semantics: a pin that would strand its counterpart either **drags the counterpart along** or is
  **dropped with it**. That belongs to `Context::PinnedMessages`, not to the compaction path, which is
  why no card in this chunk took it." The same plan's manual check 2 (`:1676-1681`): "The refusal is
  correct behaviour, not a failure of this pass."
- **`pin.rb:12-14`:** "A bare `/pin` names the LAST ASSISTANT TURN, because that is what an operator
  has just read and wants kept". The class header also still says "Making the mark actually protect
  anything is a later card's job".
- **T7 Open decision S5, owed** (exec log and Close-out): "a `/pin` on a turn inside a held range is
  silently ignored." `ARCHITECTURE.md`: "a pin placed inside a range a held cut already collapsed does
  not bring that turn back."

### 4. Classification
**(c) Pre-existing, with a design ruling owed** (follow-up 14's pin semantics). The UX default of
bare `/pin` at a parked `tool_use` was never revisited.

### 5. Constraints and open questions
**Constraints:**
- **`spec/lain/context/compact_spec.rb:200-222`** is a characterization spec: "WHEN THE PIN SEMANTICS
  ARE DECIDED, this example must go red and be deleted".
- **`spec/lain/compaction/source_spec.rb:1843-1872`** ("refuses rather than shipping a pinned tool_use
  whose answer was collapsed") and `:1363-1374` (the unpinned validity claim, stated honestly).
- **Pins are cut points, not shields** (`derived.rb:25-34`). The derivation takes no pin policy by
  design, and the fix belongs in `Context::PinnedMessages` per follow-up 14.
- **`/pin` is an IDENTITY, not a count** (`pin.rb:16-24`, `MIN_PREFIX`).
- **Pins replay via `SessionPin` records.** A pair-pin semantics must replay identically.

**Open questions for the human:**
- **Rule on follow-up 14:** drag the counterpart along, or refuse a lone `tool_use`/`tool_result` pin
  by name?
- **Rule on S5** alongside it, since both are "what a pin means against a collapsed range".
- Should bare `/pin` skip an assistant turn whose `tool_use` is unanswered?

---

## F201 — `bench record` never journals `truncated_stream`

### 1. Mechanism, re-verified, with a correction
- `Provider::Ollama#note_truncated_stream` (`provider/ollama.rb:516-521`) writes to `@journal`.
- **The finding's citation (`ollama.rb:223`, the constructor default) is not the effective cause.**
  `Backend#provider` passes `journal: run_journal` (`cli/backend.rb:188-190`, `:464`), and
  `RunJournal#<<` forwards to `Backend#journal` (`summarizer.rb:66-70`). That is
  `@journal || Channel::Null.instance` (`cli/backend.rb:274`), bound only inside `#pipeline_source`
  (`:381-383`).
- `Bench::CLI#record` (`bench/cli.rb:313-326`, `recording_provider` `:548-552`) never calls
  `pipeline_source`, so `backend.journal` is Null.
- `RunRecorder#record` (`bench/cli/run_recorder.rb:42-57`) opens each run's `Journal` separately and
  hands it only to the Agent's instrumentation (`:84-88`).
- So `truncated_stream` **and** `provider_wait` from the provider are lost on this path, on both
  Ollama and Anthropic (`anthropic.rb` takes the same `journal:`).
- **Second half.** No bench reader consumes `truncated_stream` (no hit under `lib/lain/bench`), so
  journaling alone would not stop `bench variance` averaging an all-zero `turn_usage` in as 0.

### 2. Most recent change
- **Not touched by the round-17 chunk.** T4 covered the chat wiring only.
- **Established by:**
  - `c752c0b5` (2026-07-25): the `Backend#journal` Null-until-bound comment;
  - `84dbac23` (2026-08-20, "provider: record what a caller waited for a busy local endpoint"):
    `journal:` / `run_journal`;
  - `b08fa3f8` (2026-08-27): the `TruncatedStream` witness.
- **Sibling follow-up recorded by the chunk** (exec log, "Follow-ups found in flight", T9's review):
  "`Bench::CLI::RunRecorder` never journals `capability_degraded`, so the cache-ratio withholding only
  fires on hand-built journals." This is the same class, on the same object, and was not carded.

### 3. Why it is this way
- **`cli/backend.rb:269-274`:** "Bound by the first {#pipeline_source} call (the run has exactly one
  wiring site) and the Null channel until then, so a path that never wires compaction -- **bench**,
  `--no-journal` -- reads a destination rather than a nil to guard." So Null on the bench path is
  named, but as a Null-Object convenience, not a ruling that bench records need no provider records.
- **`backend.rb:455-463`:** per-event resolution exists so the chat provider does not "hold
  {Channel::Null} for the whole session: every wait served, none recorded, nothing raised". That is
  exactly the failure that remains on the bench path.
- **`b08fa3f8`'s message:** the join key exists because "one Provider serves several tiers whose
  records interleave on one channel".
- **`RunRecorder`:** "One run, one journal, one file"; the provider is built once for N runs
  (`bench/cli.rb:319, 324`).

### 4. Classification
**(c) Pre-existing, not touched by the chunk.** The F92 class, with a sibling follow-up already on
record from T9's review.

### 5. Constraints and open questions
**Constraints:**
- **One provider serves N runs, with one journal per run.** The provider's destination must follow
  the current run, which is `RunJournal`'s per-event resolution idiom, not capture at construction.
- **Each session file must stay loadable** (`Session::Loader`; FI-9 is related). The header is
  written after the run (`run_recorder.rb:65`).
- **Recorded sessions must stay comparable.** A new record type in a bench file must not change what
  `bench variance` compares for existing recordings.
- **`spec/lain/bench/cli/run_recorder_spec.rb`** and
  `spec/lain/provider/ollama/stream_assembler_spec.rb` / `spec/lain/telemetry/truncated_stream_spec.rb`
  cover the parts separately. No spec covers the bench path's provider journal.

**Open questions for the human:**
- Should `bench variance` exclude, or flag, a run whose `turn_usage` is all-zero with a
  `truncated_stream` beside it? That is a bench-validity ruling.
- Fold the `capability_degraded` follow-up into the same card?

---

## F203 (LOW) — a refused count survives `/rewind`; the "withdrawn" wording

### 1. Mechanism, re-verified
**Reading.**
- `Agent#call_model` rescues `WindowExceeded` and calls
  `accounting.observe_refusal(prompt_tokens:)` (`agent.rb:576-584`).
- `Accounting#observe_refusal` (`agent/accounting.rb:54-57`) sets `@last_turn_usage`.
- `StatusFeed#observe_refusal` (`status_feed.rb:317-319`) mirrors it.
- `Agent#rewind` (`agent.rb:322-332`) does not touch Accounting.
- `Source#context_for` receives `usage: accounting.last_turn_usage` (`agent.rb:596-598`), so
  `approaching_window` fires on a count for a chain no longer on the head.

**Pre-existing half.** A **normal** reading also survived `/rewind` before T24.
`cli/command/introspect.rb:58-62` documents it: "`last_turn_usage` is written only by `#observe`, so a
`/rewind` that drops the turn this measured leaves the reading where it stood." Since T24 that
comment is stale: `observe_refusal` writes it too. T24 made the surviving number larger than any
answered turn could produce.

**Wording.**
- `RequestBudget#refusal` picks `MOVES.fetch(@compaction.droppable?)` (`request_budget.rb:74-79`), and
  `MOVES[false]` says "and it was withdrawn".
- Whether `Agent#withdrawing` actually withdrew (`agent.rb:338`, only when `@timeline.equal?(asked)`)
  is invisible to the middleware.
- **Confirmed in bowling:** the refusal at 11:22:03 came after a tool round (`run_interrupted
  head=98485fab`, a tool-result head), and the next decision had `nothing_droppable: true`.

**Accurate.**

### 2. Most recent change
- **T24 `4cf30b98`**: `observe_refusal`, `withdrawing`, `MOVES`, `Reporting#droppable?`.

### 3. Why it is this way
- **T24 ruling (exec log):** "a believed reading so compaction fires"; `accounting.rb:44-50`: "Without
  it compaction's approaching-window signal goes on reading the last ANSWERED turn and never fires,
  and every later prompt is refused the same way."
- **The withdrawal's scope** (`agent.rb:221-227`), as quoted under F199.
- **The `MOVES` split** (`request_budget.rb:32-34`) keys on "whether the refused render left
  compaction anything to drop". It was never meant to report the withdrawal, and the wording
  conflates the two.

### 4. Classification
**(b) for the wording**, an edge T24 did not consider. **(c) pre-existing for the reading surviving
`/rewind`**, amplified by T24.

### 5. Constraints and open questions
**Constraints:**
- **Keep the T24 behaviour that a refused count is believed.** Pinned by
  `spec/lain/seams/over_window_request_spec.rb:166-181` ("compacts against the refused prompt's exact
  count") and `spec/lain/agent/accounting_spec.rb`.
- **Wording specs:**
  - `spec/lain/middleware/request_budget_spec.rb:113-122` and
    `spec/lain/seams/over_window_request_spec.rb:106-113` pin "withdrawn" for `droppable? == false`.
  - `spec/lain/agent_spec.rb:1017-1021` pins that the tool round stays.
- **A resumed session reads `nil` as absence, not zero** (`accounting.rb:66-68`). Clearing on rewind
  must reset to nil, never to 0.
- **`StatusFeed` must agree with `Agent#occupancy`** (`over_window_request_spec.rb:183`, "is measured
  the same by the Agent and by the status feed"). Anything cleared on rewind must clear in both.

**Open questions for the human:**
- On rewind, clear the reading, or tag it with the head it measured?
- Should `RequestBudget` learn whether the ask withdrew, which means the Agent tells the middleware?
  Or should the wording drop "withdrawn" altogether?

---

## Cross-finding

### Shared root causes

1. **Nothing owns window-relative size below the request level.**
   - Open decision 2 (per-tool bounds) and round 15's "retained tail" deferral are one missing owner.
   - **Findings:** F173 (a tail over budget), F160 (child reads), F199's route (a full-cover window
     read that no 32k request can carry), and F203's trigger.
   - T24 made each of them **visible**, as a 400 plus `window_pressure` where there used to be silent
     truncation, without making any **recoverable**.

2. **The chat's model-phase wiring exists only on the main agent's stack.**
   - `RequestBudget` (F160), the run journal binding (`Backend#journal` via `pipeline_source`, F201) and
     `num_batch` (the `ModelFlags.throughput` declaration, F154) are each wired at one chat-only site.
   - Children, `bench record`/`arms`, `epic submit`, `consolidate` and `improve` fall to Null or nil
     defaults.
   - Same class as round 17's F92 and F95: a fix at the site that was driven, not at the owner.

3. **State measured about a chain is not scoped to the chain.**
   - The `ReadSet` (F199), `Accounting#last_turn_usage` (F203) and `WindowBook::Live`'s re-ask count
     (F136) are all per-run.
   - A rewind, a withdrawal or a runner reload changes what they describe, and they do not follow.
   - T7 did scope the compaction cut to the chain (`HeldCut`), and that is the precedent. But its
     commit-head rule interacts badly with T24's withdrawal (F173's re-commit per ask).

4. **Silence is the designed failure signal on secondary paths.**
   - `Eager`'s "absence is the signal" (F152), `Channel::Null` defaults (F201) and the child's Null
     journal (F160).
   - Each is deliberate and documented, and each loses the one record that would explain the failure
     of a run the operator paid for.

5. **Owed pin and compaction semantics.** T7 S4, T7 S5 and derived-context follow-up 14. F161 and
   F173 cannot be closed properly without those rulings.

### What one fix would cover
- **A window-relative bound (Open decision 2, taken as a tail or result budget):** F173 directly; F160
  for `diff_critic` reads; the route into F199 and F203. It needs the human's S4 ruling and a
  re-ruling of "cut wins over keep_last" if the tail becomes elidable.
- **One "model-calling command" wiring helper** (throughput flags + a per-run provider journal): F154
  and F201, and the T9 `capability_degraded` follow-up. It would not cover children (F160), because
  the child journal's Null is a separate deliberate ruling.
- **Chain-scoped run state** (a reading and a read-set keyed to the head or the producing turn): F199
  and F203's reading, plus making a cut survive a pure withdrawal (F173's re-commit).
- **Pin semantics ruling** (follow-up 14 + S5): F161.
- **Standalone fixes:**
  - F136, a re-ask policy that separates timeouts from answered-empty (F154's fix removes its trigger
    on this box but not in general);
  - F152, a failure record and/or a JSON template;
  - F203's wording.
