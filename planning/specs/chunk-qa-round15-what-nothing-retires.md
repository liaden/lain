# Chunk: round-15 — what nothing ever takes out of the set

status: in-progress
commit-mode: orchestrator-commits
language: ruby (plus the QA bench's `bash` driver heredocs and its scenario prose)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharges [`../qa-findings-round15-2026-08-27.md`](../qa-findings-round15-2026-08-27.md).

**Two of the round's three defects are the same shape, and it is not the shape the findings
document named.** A digest is put into a standing set, and no code path ever takes it out:
`StatusFeed::Inbox`'s `@pending` for a relayed subagent question (**F81**), and `StatusFeed`'s
`@fleet` for a spawn that has finished (**F83**). The third (**F82**) is the same failure one
remove further out — the compaction path *computes* the fact that it has nothing to compact and
publishes it to no human, so `ctx 100%` cannot be told from `ctx 100% and broken`.

**F81's filed mechanism is wrong, and the correction is the chunk's most useful result.** The
findings say the relay writes two human-addressed records and "the relay should not write a second
`message`". It does not: `Chain#asking_handle` (`subagent.rb:643-646`) addresses a child's own
question to its **parent's** correlation, so only the outermost relay hop carries `to: "human"` and
`Inbox#arrived` (`status_feed/inbox.rb:73`) lists exactly one row per question. The residue is on
the **retire** side, and it is a collision between two designs that are each correct alone:
`ToolRunner#delivery` (`tool_runner.rb:232-234`) commits the answering turn citing the outermost
digest, and `SessionRecord::Scribe#child_turn` (`scribe.rb:249-256`) deliberately keeps a spawned
chain's turns **off the tee**, saying so in words — *"it is what keeps a `StatusFeed` … from
retiring an inbox question because a subagent committed a turn."* That rule was written when a
child addressed the human directly. After the relay landed (`98571e69`), the only turn that can
retire a child's question **is** the one that rule excludes. So the fix is neither "write one
record" nor "put child turns on the tee" — it is to promote the *consumption edges alone*.

**And the reason not to route the record that already exists is bandwidth, not correctness.**
`Telemetry::ChildTurn` (`telemetry/session_lifecycle.rb:147-163`) already carries a child turn's
`causal_parents`, and `Scribe#child_turn` (`scribe.rb:273-278`) already writes it — to `@journal`
only. Routing *that* onto the tee would work, and is the wrong trade:
`session_lifecycle.rb:141-146` measures those records at **47% of a journal with one trivial spawn
and 88% with eight**, so routing them puts a child's whole transcript across the nvim Channel every
turn to deliver one array of digests. The comment at `scribe.rb:249-256` gives a *different* reason
— that it would let a subagent's turn retire an inbox question — and that reason is the behaviour
this chunk is declaring to be the defect, so it cannot also be the justification. **The honest
statement is: route a narrow record because the wide one is too expensive, and amend the comment
that argues otherwise in the same change.**

By the human's ruling F83 is taken as the **W3 lifecycle design**, not as a ported predicate:
`CLI::FleetWindows#terminal?` (`fleet_windows.rb:289-292`) already answers "has this spawn
finished?", but it answers it by testing two unrelated record shapes inline, because a one-shot
completion and an actor farewell speak different vocabularies. Naming the vocabulary once is what
lets two readers agree.

## Grounding

Verified 2026-08-28 by four parallel explorations against `9ead317c` (`main`, clean but for an
untracked `references/repos/smolagents`). Line numbers are from that state.

**The round-14 chunk is `in-progress` and owns its own leftovers.** `T7` and `T8` both landed
(`98571e69`) and are fully wired, contrary to that chunk's execution log, which was written before
the commit and says T7 is "held" — checked at `subagent.rb:643-646` (`asking_handle` passes
`to:` and `escalation:`) and `subagent.rb:629-632` (`escalation_road`). This chunk therefore treats
the relay as shipped and does not re-land it.

**Most of round 15's process notes are already fixed in the tree** and must not be re-done. P29 is
corrected at `SKILL.md:225` and `method.md:994` (the `export`-anchored grep, with the loose form
retained only as a quoted negative). P32 is corrected at `shell-term-approval.md:322-332`
(`exit_status`, `env:`, `timeout:`, measured values). P33 is corrected at `survey.md:88` with an
explicit `RE-COUNT, never copy`. Scenario corrections 1, 3, 4 and 6 are likewise already in place
(`shell-term-approval.md:89-105`, `secret-boundary.md:61-74`, `rails-blog.md:10-19`). What survives
is listed per card below.

### F81 — the retire path, end to end

- `Inbox#arrived` — `status_feed/inbox.rb:73`:
  `@pending[event.digest] = true if event.to == INBOX_RECIPIENT && !@consumed.include?(event.digest)`.
  `INBOX_RECIPIENT = "human"` at `status_feed.rb:168`.
- `Inbox#retire` — `status_feed/inbox.rb:83-89` — and `#committed(head_digest)` — `:95` — walking
  the head's chain for `causal_parents` under a deliberately wide never-raise rescue (`:115-119`).
- The rule both surfaces are held to, stated at `status_feed/inbox.rb:20-26`: *"a `:message`'s
  `causal_parents` is lineage, not consumption — so the human answering does NOT retire their own
  question; the assistant commit that folds it in does."* The nvim half is the same predicate at
  `frontend/neovim/inbox_view.rb:271-273` and `:311-324`, and `inbox.rb:15-19` says **"Change both
  or neither."**
- The digest that gets cited: `AskHuman#emit_question` returns `@last_question.digest`, the
  **outermost** hop (`ask_human.rb:684-685`); `#record_answered` pushes exactly that
  (`ask_human.rb:602`); `ToolRunner#delivery` commits it as the turn's `causal_parents`
  (`tool_runner.rb:232-234`).
- Why it never arrives: `Scribe#call` routes `:turn` to `#child_turn` and everything else to
  `#message` (`scribe.rb:155-157`); `#message` writes to `@message_journal`, the tee the StatusFeed
  rides (`scribe.rb:248-250`); `#child_turn` (`scribe.rb:273-278`) writes to `@journal` **only**,
  with the reason stated at `scribe.rb:249-256` and weighed in the Intent above.
- **The tee is routed, not duplicated**: `scribe.rb:128-135` records that the tee's journal leg IS
  `journal`, so anything written to `@message_journal` also lands in the session file. T1's record
  has to earn its place in the record, not only on the wire.
- The parent's own question has no relay hop, its answering turn is the parent's own, and that turn
  reaches the inbox as a `Telemetry::TurnUsage` through `StatusFeed#observe_commit`
  (`status_feed.rb:292-295`) — which is exactly QA's control, and why it retires.
- **A question has no identity but its record digest.** `Outstanding::Pending` holds only `@digest`
  (`ask_human.rb:133-139`) and `Directory::Registration` keys by that string (`directory.rb:156-161`).
  `Question`'s `id` (`question.rb:4`) is a join key **inside** the answer document, not a record
  identity. So a fix cannot key on "the question" — only on an edge between records.
- **`ToolRunner` holds no journal**, and says so as a named debt at `tool_runner.rb:322-324`. The
  record therefore cannot be written there without paying that debt first; `Scribe` already holds
  both journals and is the site this chunk uses.

### F82 — the empty head

- `Boundary#snapped` — `compaction/boundary.rb:114-121`, `raw = [messages.size - @keep_last, 0].max`
  at `:115`. `DEFAULT_KEEP_LAST = 20` at `cli/backend.rb:76`, wired at `backend.rb:467`.
- `head_bytes == 2` is the **documented** empty reading, not a bug: `Head` measures
  `Canonical.dump([]).bytesize` unconditionally, argued at `compaction/head.rb:51-53` and restated
  at `compaction/source.rb:303-306`.
- The decision value: `Source::CompactionDecision = Data.define(:compacted, :signals, :head_bytes,
  :summary_hits, :summary_misses, :cold, :would_not_shrink, :window_tokens, :used_tokens,
  :provenance)` — `compaction/source.rb:64-68`, written at `#record` (`:480-486`) from `#defer`
  (`:429`) and `#commit` (`:458`).
- **`CompactionDecision` has zero consumers in `lib/`.** `StatusFeed#<<` (`status_feed.rb:224-248`)
  does not recognise it; `@compactions` moves only on `Telemetry::Compaction` (`status_feed.rb:233`)
  and `@derivation_refusal_streak` only on `DerivationRefused` (`:238`). So a field alone surfaces
  nothing — which is why this chunk takes the sink **and** the field, and why the field card is
  sequenced first (the data before the rendering of it).
- The existing route to a screen: `CLI::CompactionMount#diagnostics` —
  `cli/compaction_mount.rb:83`, `DIAGNOSTICS = "lain:compaction"` at `:90`, doctrine at `:76-83`
  (*"the frontend renders exactly one event … `Sink::IOAdapter` turns an IO-shaped `#puts` into
  one"*). The precedent for writing to it from inside compaction is
  `Strategy::Summarizing` at `compaction/strategy/summarizing.rb:194`.
- **The gap that makes this a real card:** that sink reaches `Backend::SpanSummarizer.resolve`
  (`cli/backend/span_summarizer.rb:59-60`) and from there only the *strategy* (`:81`).
  `Source#initialize` (`compaction/source.rb:224-226`) takes `journal:` and **no `sink:`**, so the
  one object holding the head, the need, the occupancy and the provenance together has no route to
  a human. `Head` explicitly disclaims the judgement (`head.rb:97-100`); `Boundary` explicitly
  refuses to raise (`boundary.rb:58-61`). `Source` is the owner.
- The nearest existing coverage is `spec/lain/compaction/source_spec.rb:924`, *"answers the base
  untouched even when a signal fires"* — it asserts the Context is handed back and nothing about
  what a human is told.
- The HUD's clamp is deliberate and stays: `cli/up/hud.rb:69` with the argument at `:39-45`
  (*"a pegged 100% reads as 'full', which is the one thing a human can act on"*).

### F83 — the fleet, and the lifecycle vocabulary

- `@fleet[event.digest] = true` at `status_feed.rb:409`, published as `@fleet.keys` at `:451`.
  Three `@fleet` sites in the whole subtree (`:211` init, `:409` add, `:451` read) and **no
  delete**. The `:message`/`:turn` arms of that same `case` both add *and* retire for the inbox.
- **It is the only published field of this shape.** `compactions` (`:233`) and `run_tokens`
  (`:322`) are monotonic *counters* whose docs argue for it; `fleet` is the only *set of identities*
  with an add path and no remove path.
- The completion records already carry the join: a one-shot writes
  `causal_parents: [spawn.digest, final]` with a `"result"` body (`tools/subagent/lineage.rb:57-62`);
  an actor farewell writes `lifecycle: "stopped"` citing `@address` (`tools/subagent/actor.rb:141`,
  `:187-189`).
- **The vocabulary is real but incomplete.** `launched` on the `:spawn`
  (`lineage.rb:37-44`, `actor.rb:79`), `settled` and `stopped` on a `:message`
  (`lineage.rb:71-74`, `actor.rb:141`, `:181`). A **one-shot completion speaks none of it** — it is
  recognised only by the presence of a `"result"` key. That asymmetry is why
  `FleetWindows#terminal?` (`fleet_windows.rb:289-292`) tests two unrelated shapes inline:
  `payload.key?("result") || payload["lifecycle"] == "stopped"`.
- Prior art for the retirement itself, on the same records:
  `FleetWindows#observe_close` — `cli/fleet_windows.rb:281-287` — finds the windowed digest among
  `causal_parents` and deletes it. Its `@seen` set (`:256-262`) is separate from `@windows`, which
  is what keeps a **redelivered** spawn a no-op while still allowing removal — the exact pair of
  properties `StatusFeed` needs, since `status_feed.rb:207-210` argues the Hash keying is what makes
  a replayed `:spawn` idempotent.
- **Liveness is modelled twice and neither is reachable from the feed.**
  `Supervisor::Registration#state` derives `:running`/`:stopped`/`:failed` from the live actor
  (`supervisor.rb:284-311`) and `Actor` carries `stopped?`/`dead?`/`launched?`
  (`actor.rb:117`, `:123`, `:150`) — both in-process, and `status_feed.rb:16-17` forbids the feed
  from reading an in-process registry, pinned at `spec/lain/status_feed_spec.rb:182`. **Any fix
  must be journal-derived.**
- `Subagent::Seam` (`subagent.rb:518-519`) has thirteen members and none is a state; its own doc
  (`:498-517`) says it is per-*tool* wiring, not per-*child*, so it structurally cannot carry one.
- **Round 11 deferred this on the human's explicit ruling** (`chunk-qa-round11-survey-surfaces.md:312-317`,
  *"Round 12 QA should expect `fleet 1` to persist"*). That ruling is superseded here by a second
  explicit ruling, recorded 2026-08-28: settle the lifecycle design rather than port a predicate.

**Adding a `lifecycle` marker to a one-shot completion is additive and backward-compatible, and
here is the evidence rather than the assertion.** `Bench::Session::MessageReplay#verified`
(`bench/session/message_replay.rb:180-187`) rebuilds each Event from **the record's own recorded**
`payload`/`from`/`to`/`causal_parents`/`correlation` (`#rebuilt`, `:215-223`) and compares against
the recorded digest — so a historical journal re-derives its historical digest no matter what
`Lineage#message` writes today. Replay, `--fork` and `--resume` are unaffected. Only *future*
completion `:message` records change, which is why T5's predicate must still accept the legacy
`"result"`-only shape. `Lineage#spawn`'s "bytes unchanged" note (`lineage.rb:32-36`) is about the
`:spawn` event and is not disturbed.

**One standing argument points the other way, and T6 reconciles it rather than ignoring it.**
`spec/lain/supervisor_reactor_spec.rb:283-290` says in words that landing the actor's lifecycle
marker when it landed *"was the cheap moment: events are content-addressed, so a later marker would
have changed digests under recorded journals."* The `MessageReplay` evidence above is why that
concern does not bind here.

**Where the lifecycle vocabulary may live, and where it may not.** Not under `lib/lain/tools/`.
`lain.rb` loads `lain/telemetry` at `:34`, `lain/status_feed` at `:61` and `lain/tools` at `:96`,
and `status_feed.rb:163-167` states the rule out loud — *"Spelled again rather than imported from
`{Tools::AskHuman::HUMAN}`: reaching into the Tools tree from this early-loading struct would
invert the dependency this class actually has, which is none."* There is no code reference to
`Tools::` from `status_feed.rb`, `status_feed/inbox.rb`, `event*` or `session_record*` anywhere in
the tree, and a first one would not raise at load — constant lookup is deferred, so it would simply
ship. **The vocabulary is a fact about journal records and both readers load after
`lain/telemetry`, so `lib/lain/telemetry/` is its home.**

**`StatusFeed` has ten lines of headroom and two cards want to grow it.** `.rubocop.yml:161` sets
`Metrics/ClassLength: Max: 125`; the class body from `status_feed.rb:151` measures **115**
non-comment, non-blank lines, and this repo carries no `.rubocop_todo.yml` — it passes on merit.
CLAUDE.md forbids raising the limit and says a tripped cop is a missing object. That object is
already named next door: **`StatusFeed::Inbox`** (`status_feed/inbox.rb`) is exactly "a standing set
with an arrival side and a retire side, extracted out of the feed", with `#bind_store` (`:56-59`)
as the late-binding precedent. `@fleet` is the same shape and has never been extracted. **T18
extracts it first**, which is what buys T2 and T8 their room.

### The bench

- **The driver scripts are heredoc bodies inside one file**, not standalone scripts:
  `.claude/skills/manual-qa/scripts/qa-sandbox.sh` writes `drive.sh` (`:49-101`), `peek.sh`
  (`:104-117`) and `nv.sh` (`:120-165`) into `$QA/` at sandbox creation. There is no `drive.sh`,
  `peek.sh` or `nv.sh` file to edit, and `method.md` lives at `planning/qa/method.md`, not in the
  skill.
- P30 is **open in the code and already documented in the prose**: `qa-sandbox.sh:58` and `:114`
  both resolve a pane by `grep -w ruby | head -1`; the hazard is written up at `method.md:481-486`.
  The same script already refuses on ambiguity for the *nvim socket* (`qa-sandbox.sh:71-82`,
  the `*)` arm exits 2) — so the fix has a local precedent and the asymmetry is the finding.
- P34 is **open and wider than filed**: `nv.sh`'s `expr` (`qa-sandbox.sh:155`) emits no trailing
  newline, and `bufs` (`:157`), `tabs` (`:158`), `buf` (`:160`) and `fold` (`:161`) share it. Only
  `msgs` (`:159`) escapes incidentally through its `tr`; `send` (`:156`) reads nothing.
- **P31 as filed is not reproducible against the documents.** `cockpit-surfaces.md` §7 (`:611-624`)
  contains no window-motion advice at all, and §4b contains no `<C-w>l`. What §4b *does* contain is
  a genuine contradiction round 15 did not report: `:353` comments the `<CR>` as opening
  `sidebar | OLD | NEW` and `:355-358` calls an empty OLD window "§4b's expected state", while §4
  (`:130-141`, corrected in round 14) measures a **survey** as two windows, sidebar and NEW. §4b is
  explicitly a survey (`:341`). Both cannot hold.
- **`failure-injection.md` §1b's `unterminated` recipe contradicts a shipped spec**, which is why
  round 15's F78 re-check found 0 records and reported "inconclusive". The scenario says to "sever
  before ANY frame carrying `done: true`" for `kind: "unterminated"` (`:94`) and to expect "exactly
  one `TruncatedStream` per severed request" (`:105`). `spec/lain/provider/ollama/stream_assembler_spec.rb:246-251`
  pins the opposite as deliberate: *"A mid-stream sever is cleanly RETRIED, so the abandoned attempt
  is not the turn — a record for it is noise."* The `counts_absent` half is drivable and the spec
  shows how (`:239-243`): a terminal frame with both counts stripped, on a stream that **closes**.
  Round 15's proxy left the connection open and got a `stalled stream` instead.
- **`/introspect` exists and the scenarios are off by one.** Registered at
  `cli/command/surface.rb:118`, twenty-one commands total, pinned as a literal at
  `spec/lain/cli/command/surface_spec.rb:143-147`. `repl-commands.md:3-6` enumerates 10 + 10 and
  `planning/qa/README.md:41` says "the ten others"/"twenty".
- **`repl-commands.md:78` drives `/mode auto` outside any sanctioned section.** `method.md:200-207`
  sanctions exactly two — `repl-commands.md` §6 and `secret-boundary.md` §5 — and that list is stale
  on the other side too: `shell-term-approval.md:603` is a `/mode auto` section, and
  `planning/qa/README.md:116` advertises `shell-terms.md` as covering `/mode auto`.
- **The merge left two scenarios for one subsystem.** `shell-terms.md` (608 lines, added
  `4357a2d9` on `main`) and `shell-term-approval.md` (685 lines, added `8f93c869` on the dogfood
  branch) both arrived through `9ead317c`. `planning/qa/README.md:109-136` declares the shell
  subsystem's coverage gap **twice, in adjacent sections**, each saying "the gap was invisible".
  Round 15 drove `shell-term-approval` only and reported "all 17 scenarios … none dropped" — the
  directory held 18 by then. The README's ordering prose (`:155-205`) gives `shell-terms` and
  `ollama-cloud-arm` no tier at all, and Known gaps (`:437-441`) still calls
  `shell-term-approval.md` undriven.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb`, `lib/lain/telemetry.rb` (the telemetry subtree's index), `.rubocop.yml`,
  `spec/spec_helper.rb`, `lain.gemspec`.
  **T1 and T5 each need one `require_relative` line in `lib/lain/telemetry.rb`** and neither may
  edit it; the orchestrator applies both. They are additive lines in the same list and do not
  conflict, but they land in the same wave, so apply them in card order.
  `lib/lain/status_feed.rb` is **not** on this list even though it indexes `status_feed/`: T18 has
  it under **Files** already and adds its own `require_relative "status_feed/fleet"` line there.
- **A new lib file, its index line and its spec land in the same commit** (CLAUDE.md's
  commit-grouping rule) — applies to T1, T5 and T18.
- Deviations from the default process, and they apply **only** to T9 and T12–T17:
  - **Those cards construct nothing and write no spec.** Their ACs are checkable by reading, so
    "→ spec file" is `none` by design rather than by omission, and the reviewer's job is to open
    every `file:line` the card cites and confirm the claim. That is the same shape round 11's T10,
    T14 and T15 took.
  - **They need no persona panel pass** — there is no object design to review. Review them for
    factual accuracy instead.
  - **T9 is the exception inside the exception**: it is an investigation whose *finding* may turn
    out to be a code defect. If it does, it escalates rather than growing a code scope (see its
    triggers), and the panel is owed the result.
  - T10 and T11 edit `bash` heredocs and have **no suite coverage at all**; integration check 8 is
    their only gate and it is not optional.

## Open decisions

1. **No bound on a single tool result's contribution to the retained tail — deliberately not taken
   here.** Nothing between `Tool::ResultBlock.of` (`tool/result_block.rb:56-62`) and
   `Timeline#commit` measures a result: `ToolRunner#delivery` has no size check, and no middleware
   truncates (the two that rewrite tool output — `withhold_secret_paths.rb:238`,
   `redact_secret_reads.rb:243` — refuse whole rather than truncate, and
   `withhold_secret_paths.rb:30-32` argues *against* silent truncation by name). `read_file`'s
   `WHOLE_BOUND` is 262,144 (`tools/read_file.rb:57`) against a 32,768-token window, and
   `subagent`, `run_skill`, `request_review`, `ast_dump`, `session_usage`, `tool_search`,
   `core_exec`, `improvement_write`, `todo_write`, `edit_file`, `write_file` carry no result bound
   at all. **The reason for deferring:** this changes what the *model* can see, not what the *human*
   is told, and the honest form of it is a policy question about `Tool::Bounds` across eleven tools
   — a chunk, not a card. It is owed, and F82's fix must not be read as having closed it.
2. **`Telemetry::ChildTurn` already carries the fact T1 promotes, and a second record is written
   anyway.** It is on the same path (`telemetry/session_lifecycle.rb:147-163`, written at
   `scribe.rb:275`). Routing *it* is rejected on **bandwidth** — 47% of a journal with one trivial
   spawn and 88% with eight (`session_lifecycle.rb:141-146`) — not on correctness. If a later chunk
   gives the tee a filtered leg, the narrow record becomes redundant and should go. Recorded so this
   is a decision with a stated cost rather than an oversight.
3. **The twinned-actor address collision is not fixed here.** Two spawns of one arm from the same
   head are byte-identical `:spawn` events, so they share a digest; `spec/lain/supervisor_reactor_spec.rb:178`
   is `pending` with the note that the fix belongs in `ChainWriter`. T8 retires **by address**, so
   twins continue to fold into one entry and that spec stays `pending`. Fixing it means putting a
   nonce in a content-addressed event, which is a Timeline decision, not a status-feed one.
4. **F52 is left alone.** Round 15 re-files the approval trailer folding on its own line as
   "REPRODUCES, unchanged", but `chunk-qa-round9-where-the-record-lives.md:116` records the human's
   ruling that this shape is deliberate and spec-pinned. No card. If it should stop being re-filed,
   that is a line in the scenario, and T16 may add it.
5. **F73 is still owed to a manual pass**, by the round-14 chunk, not this one. Round 15 ran one
   cockpit at a time and returned no verdict; that chunk's integration check 4 is the owner.
6. **Whether `shell-terms.md` and `shell-term-approval.md` merge or divide is T15's to answer**, but
   the *ruling* — that one subsystem does not get two scenarios silently — is settled. T15 must
   produce one of the two outcomes and say which, in the file; it may not leave both as they are.

## Waves

```
Wave 1: T1, T3, T5, T10, T12, T13, T14, T15, T17, T18
Wave 2: T2 (←T1), T4 (←T3), T6 (←T5), T7 (←T5), T9 (←T12), T11 (←T10)
Wave 3: T8 (←T5, T6, T18), T16 (←T11, T14, T15)
```

Critical path: **T5 → T6 → T8** (depth 3), tied by **T10 → T11 → T16**.

No two same-wave cards share a file. Several dependency edges exist for that reason alone rather
than for substance, and are marked as such on the cards: T3/T4 share `compaction/source.rb`;
T10/T11 share `qa-sandbox.sh` and `method.md`; T12/T9 share `cockpit-surfaces.md`. Two edges are
substantive: **T8 ← T18**, because T18 is what gives T8 an object to edit and keeps `StatusFeed`
under `Metrics/ClassLength`; and **T16 ← T14, T15**, because T16 records their rulings rather than
guessing them.

`status_feed.rb` is touched by T18 (wave 1) and T2 (wave 2) and by nothing in wave 3 — T8 edits the
extracted `status_feed/fleet.rb` instead. `method.md` has three interested cards and one owner per
wave: T10, then T11, then T16.

## Tasks

### T1 — Promote a child's consumption edges onto the tee, and nothing else   [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/telemetry/questions_consumed.rb`; modify
`lib/lain/session_record/scribe.rb`; create `spec/lain/telemetry/questions_consumed_spec.rb`;
modify `spec/lain/session_record/scribe_spec.rb`
**Reuse:** `Telemetry::ChildTurn` (`telemetry/session_lifecycle.rb:147-163`) is **the record this
one is a narrow substitute for** — it already carries a child turn's `causal_parents` on exactly
this path, and the Intent says why it is not routed instead. `Telemetry::Message.from_event`
(`session_lifecycle.rb:101-123`) is the shape to copy — a small `Journalable` value promoted off an
`Event`. `Scribe#message` (`scribe.rb:248-250`) is the existing write onto `@message_journal`; this
card adds a second, narrower one beside it in `#child_turn` (`scribe.rb:273-278`).
**Shared-file wiring:** one `require_relative "telemetry/questions_consumed"` line in
`lib/lain/telemetry.rb`
**Reachable from:** `SessionRecord::Scribe#call` (`scribe.rb:155-157`), reached on every spawned
chain's turn; the Scribe is installed as the `Event::ChainWriter` observer at
`CLI::Chronicle#observer` (`chronicle.rb:137`), and `@message_journal` is the tee built at
`CLI::LiveViews#initialize` (`live_views.rb:128-130`), which is where `StatusFeed` sits.

A spawned chain's `:turn` must stay off the tee — `scribe.rb:249-256` argues why and this card does
not disturb it. What goes onto the tee instead is the one fact the live inbox surfaces need and a
turn record is not: **which question digests this turn consumed**, taken from the turn Event's own
`causal_parents`, written only when that list is non-empty so an ordinary child turn costs nothing.

**Acceptance criteria:**

```gherkin
Scenario: a child's turn that answered a question publishes its consumption edges
  Given a Scribe whose message journal and record journal are distinct
  When a spawned chain commits a turn citing one question digest
  Then the message journal carries a record naming that digest
  And the record journal still carries the turn itself

Scenario: an ordinary child turn publishes nothing to the tee
  Given the same Scribe
  When a spawned chain commits a turn citing no causal parents
  Then the message journal is unchanged

Scenario: a spawned chain's turn record still never reaches the tee
  Given the same Scribe
  When a spawned chain commits a turn citing one question digest
  Then no turn record appears on the message journal

Scenario: the parent's own turns are unaffected
  Given a Scribe caught up over a parent render chain that answered a question
  When catch_up runs
  Then the message journal carries no consumption record from that path
```
→ spec file: `spec/lain/session_record/scribe_spec.rb`

```gherkin
Scenario: the record is journalable and names its digests
  Given a consumption record built over two digests
  When it is rendered to the journal
  Then the record's type names it and its digests are both present
```
→ spec file: `spec/lain/telemetry/questions_consumed_spec.rb`

**This card also amends two comments it makes false.** `scribe.rb:128-135` records the tee as
"ROUTED, not duplicated", and `scribe.rb:249-256` gives a reason for keeping child turns off the tee
that this chunk has just declared to be the defect. Both are edited here, in the same commit, to say
what is now true: a narrow consumption record is routed because the wide `ChildTurn` is too
expensive to be.

**Escalation triggers:**
- `spec/journalable_surface_spec.rb` is an `ObjectSpace` sweep over every `Journalable`, requiring a
  globally unique short-name discriminator and an NDJSON round trip, and it lists records its
  `GenericBuild` cannot construct as `unreached` (`:18-23`). Expect it to have an opinion about the
  new record; if it cannot be built generically, say so rather than exempting it.
- `spec/lain/frontend/neovim/inbox_view_spec.rb:1097` pins that **`TurnUsage` is the only Telemetry
  record answering both `#usage` and `#digest`**, and `:1079` that a "dual-field lookalike retires
  in neither" surface. If the new record ends up answering either of those messages, stop — it must
  be admissible by name, not by duck-typing, or it breaks the parity rule this chunk depends on.
- `scribe_spec.rb:248` (*"moves a real StatusFeed's inbox not at all, while the spawn still
  registers"*) asserts today's silence. This card makes that silence conditional. If the example
  cannot be re-expressed as "moves it not at all **for a turn citing nothing**", stop — that means
  the rule being changed is wider than this card believes.
- `Scribe#child_turn` is documented as written **once per digest** (`scribe.rb:257-263`) because
  content addressing makes equal turns one event. If a redelivered identical child turn would
  publish the consumption record twice, stop and confirm the intended idempotence before writing.

### T2 — A relayed question retires from both inbox surfaces   [wave 2] [risk: high]

**Depends on:** T1
**Files:** `lib/lain/status_feed.rb`, `lib/lain/status_feed/inbox.rb`,
`lib/lain/frontend/neovim/inbox_view.rb`, `spec/lain/status_feed/inbox_spec.rb`,
`spec/lain/status_feed_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`
**Reuse:** `Inbox#retire` (`status_feed/inbox.rb:83-89`) already takes an Enumerable of digests and
writes the standing `@consumed` set — the new record's digests go straight into it, no new
retirement logic. `InboxView#consume` (`inbox_view.rb:311-324`) is the mirror.
**Shared-file wiring:** none
**Reachable from:** `StatusFeed#<<` (`status_feed.rb:224-248`) on the tee built at
`CLI::LiveViews#initialize` (`live_views.rb:128-130`); `InboxView#update` (`inbox_view.rb:264-269`)
on the view built at `Frontend::Neovim::Buffers` (`buffers.rb:212`) and routed at `:273`.

Both readers admit the record T1 publishes and retire on it. **Change both or neither** —
`status_feed/inbox.rb:15-19` says so, and `inbox_view_spec.rb:1001-1097` is the parity spec that
enforces it.

**Acceptance criteria:**

```gherkin
Scenario: an answered subagent question stops being counted
  Given a relayed question listed in the inbox
  When the consumption record naming its outermost digest arrives
  Then the published inbox count is zero

Scenario: the parent's own question behaves identically
  Given a question the run's own asker addressed to the human
  When its answering turn is committed
  Then the published inbox count is zero

Scenario: an unanswered relayed question is still counted
  Given a relayed question listed in the inbox
  When an unrelated child turn commits
  Then the published inbox count is one
```
→ spec file: `spec/lain/status_feed/inbox_spec.rb` and `spec/lain/status_feed_spec.rb`

```gherkin
Scenario: the nvim buffer stops offering an answered relayed question
  Given lain://inbox listing one relayed question
  When the consumption record naming its outermost digest arrives
  Then the buffer renders its empty placeholder
  And no row offers a reply affordance

Scenario: the two surfaces agree over one record stream
  Given the single tee stream both surfaces ride
  When a relayed question is listed and then consumed
  Then the buffer's listed rows and the published count agree at every step
```
→ spec file: `spec/lain/frontend/neovim/inbox_view_spec.rb`

**Escalation triggers:**
- The pinned rule that **a reply `:message` retires nothing** (`status_feed/inbox.rb:20-26`,
  `inbox_view_spec.rb:142-160`) is not being changed. If greening these ACs requires retiring on the
  answer message, stop — that is a different design and needs the human's ruling.
- `Inbox#committed`'s chain walk carries a deliberately wide `rescue StandardError` under a
  never-raise promise (`status_feed/inbox.rb:97-119`). If the new arm needs its own rescue, stop and
  confirm — a second, narrower promise on the same object is how the two surfaces start disagreeing.
- `:LainReply` already refuses a stale row in words (`ask_human.rb:164-166`, reached via
  `directory.rb:55-59`) and `Gestures#named` (`inbox_view/gestures.rb:150-156`) has four distinct
  refusals because the directory's single sentence was wrong about live rows. If retiring correctly
  makes any of those four unreachable, stop and report which — a refusal with no path to it is
  dead code this chunk should delete deliberately, not orphan.

### T3 — Say in the record that there was nothing droppable   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compaction/source.rb`, `spec/lain/compaction/source_spec.rb`
**Reuse:** `would_not_shrink` (`compaction/source.rb:64-68`, argued at `:43-47`) is the exact
precedent — a field that exists so a reader can tell one kind of refusal from a plain defer. The
predicate is already computed: `Head#empty?` (`compaction/head.rb`), consulted at `source.rb:320`.
**Shared-file wiring:** none
**Reachable from:** `Compaction::Source#decide` → `#defer` → `#record` (`source.rb:314-323`,
`:427-431`, `:480-486`); the Source is constructed at `CLI::Backend#compaction_source`
(`backend.rb:464-471`) on every chat launch.

`CompactionDecision` already names nine facts about a deferring turn and cannot express the one
that mattered: the head was empty, so no strategy could have run whatever the signals said. `Head`
disclaims the judgement (`head.rb:97-100`) and `Boundary` refuses to raise (`boundary.rb:58-61`);
`Source` is the only object holding head, need, occupancy and provenance together.

**Acceptance criteria:**

```gherkin
Scenario: a deferring turn with an empty head says so
  Given a history shorter than keep_last
  And a signal that fires
  When the turn's compaction decision is journalled
  Then the decision reports nothing was droppable
  And it reports that it did not compact

Scenario: a deferring turn with a real head does not claim it
  Given a history longer than keep_last
  And no signal firing
  When the turn's compaction decision is journalled
  Then the decision does not report nothing droppable

Scenario: a compacting turn does not report it either
  Given a history that compacts
  When the turn's compaction decision is journalled
  Then the decision does not report nothing droppable
```
→ spec file: `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- `source_spec.rb:1488-1503` (*"the decision it journals"*) and `:626-660` assert the record's field
  set. A new field must be additive there; if any example asserts the decision's fields
  **exhaustively** and would need rewriting rather than extending, stop and say which — an
  exhaustive pin is a contract, not a fixture.
- `head_bytes == 2` for an empty head is deliberate (`head.rb:51-53`). If greening these ACs tempts
  a change to that reading, stop — the two facts are separate and the byte count is already correct.

### T4 — Tell the human the context is full and uncompactable   [wave 2] [risk: high]

**Depends on:** T3
**Files:** `lib/lain/compaction/source.rb`, `lib/lain/cli/backend.rb`,
`spec/lain/compaction/source_spec.rb`, `spec/lain/cli/backend_spec.rb`
**Reuse:** `Sink::IOAdapter` (`sink.rb:21-101`) and the reserved
`CLI::CompactionMount::DIAGNOSTICS = "lain:compaction"` (`compaction_mount.rb:83`, `:90`) — the one
route from `lib/` to an operator's screen, already namespaced for compaction.
`Strategy::Summarizing` (`compaction/strategy/summarizing.rb:194`, threaded at `:136-141`,
defaulting to `Sink::Null`) is the worked example of writing to it from inside compaction.
**Shared-file wiring:** none
**Reachable from:** `CLI::Backend#compaction_source` (`backend.rb:464-471`) constructs the Source on
every chat launch and already resolves the sink for `Backend::SpanSummarizer.resolve`
(`cli/backend/span_summarizer.rb:59-60`); this card passes that same sink into `Source.new` as well.
**The sink must arrive at the Source, not merely be available** — an AC below drives the real
construction path for exactly that reason.

Today `Source#initialize` (`source.rb:224-226`) takes `journal:` and no `sink:`, so the object that
discovers `head.empty? && need.needed?` can write a record and cannot say a word. `compaction_mount.rb:30-36`
already states the consequence in the abstract: *"with nowhere to say it, 'the summarizer is
unreachable' and 'compaction is off' are the same silence to an operator."* F82 is that sentence
happening.

**Acceptance criteria:**

```gherkin
Scenario: an empty head under a firing signal is reported once
  Given a session whose history is shorter than keep_last
  And an occupancy that fires the approaching-window signal
  When the turn's compaction decision is taken
  Then the operator is told the context is full and there is nothing to compact

Scenario: a deferring turn with no signal says nothing
  Given a session whose history is shorter than keep_last
  And an occupancy well under the threshold
  When the turn's compaction decision is taken
  Then the operator is told nothing

Scenario: a turn that really compacts says nothing about an empty head
  Given a history longer than keep_last that compacts
  When the turn's compaction decision is taken
  Then the operator is told nothing about an empty head

Scenario: a guessed window does not manufacture the report
  Given a session whose window was guessed rather than probed
  And a history shorter than keep_last
  When the turn's compaction decision is taken
  Then the operator is told nothing
```
→ spec file: `spec/lain/compaction/source_spec.rb`

```gherkin
Scenario: the chat's own construction hands the Source a live sink
  Given a backend built from ordinary chat options
  When it constructs the compaction source
  And that source defers on an empty head under a firing signal
  Then the run's own channel carries the report
```
→ spec file: `spec/lain/cli/backend_spec.rb`

**Two notes the implementer needs.** `Backend#compaction_source` **already takes `sink:`**
(`backend.rb:463`) and hands it only to `SpanSummarizer` — the wire missing is one argument, not a
new parameter. And `CompactionMount::DIAGNOSTICS` is `private_constant` (`compaction_mount.rb:91`),
so the AC above observes the `tool_use_id` on the emitted `Telemetry::ToolOutput` rather than
naming the constant.

**Escalation triggers:**
- **The "once per entry" latch needs a holder, and `Source` has no state to be one** — its only
  stateful members are `@idle` and `@scheduling`, and `#decide` runs per turn while `#defer` writes
  unconditionally (`source.rb:314-323`, `:427-431`). Name the small collaborator that remembers
  whether the condition was already reported, on the streak idiom `unmeasured_turns` already uses
  (`status_feed.rb:342`). If it cannot be added without tripping a `Metrics/*` cop on `Source`, stop
  — that is a second missing object and a decision, not an improvisation.
- `CLI::Backend` was measured at its `ClassLength` and `MethodLength` caps during round 9
  (recorded in `chunk-qa-round9-where-the-record-lives.md`), and CLAUDE.md forbids raising either.
  If threading the sink trips a `Metrics/*` cop, stop — the answer is an extracted collaborator, and
  which one is a decision worth confirming rather than improvising.
- The fourth AC assumes a guessed window has already had `approaching_window` withdrawn at
  `source.rb:353` (`need.without(...)`). If that withdrawal does not hold, stop — the report would
  fire on a denominator the system already refuses to act on, which is the round-3 defect this
  codebase has fixed once.

### T5 — Name what a spawn's lifecycle is, and when it has ended   [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/telemetry/spawn_lifecycle.rb`; create
`spec/lain/telemetry/spawn_lifecycle_spec.rb`
**Reuse:** the vocabulary already written — `"launched"` (`tools/subagent/lineage.rb:37-44`,
`tools/subagent/actor.rb:79`), `"settled"` (`actor.rb:181`), `"stopped"` (`actor.rb:141`) — and the
predicate `FleetWindows#terminal?` (`cli/fleet_windows.rb:289-292`) as the behaviour to lift, not to
copy. `Compaction::Boundary` is the shape to write toward: a frozen value that answers a question
and refuses to act on it.
**Shared-file wiring:** one `require_relative "telemetry/spawn_lifecycle"` line in
`lib/lain/telemetry.rb`, which is that subtree's index

**It goes under `telemetry/`, not under `tools/subagent/`, and the placement is load-bearing.**
`StatusFeed` loads at `lain.rb:61` and `Tools` at `:96`, and `status_feed.rb:163-167` forbids the
feed reaching into the Tools tree in so many words. A `Tools::Subagent::Lifecycle` constructed by T8
would be the first such reference in the tree and would not raise at load, so it would simply ship.
The vocabulary describes journal records, both readers load after `lain/telemetry`, and that is
where it belongs.
**Reachable from:** deliberately none in this card — it is constructed by T7 (`FleetWindows`) and
T8 (`StatusFeed`), both of which are in this chunk and both named. This card ships no dormant
capability: the two cards that construct it land in waves 2 and 3.

Three marks (`launched`, `settled`, `stopped`) live on `:spawn` and `:message` bodies, and a
**one-shot completion speaks none of them** — it is recognised only by a `"result"` key. So a reader
asking "has this spawn finished?" must test two unrelated shapes, which is what
`fleet_windows.rb:289-292` does inline. This card gives the question one owner: the closed
vocabulary, the terminal predicate, and the legacy `"result"`-only shape accepted by name so
historical journals keep answering.

**Acceptance criteria:**

```gherkin
Scenario: an actor farewell is terminal
  Given a record whose body marks the spawn stopped
  Then it is terminal

Scenario: an actor settling a turn is not terminal
  Given a record whose body marks the spawn settled
  Then it is not terminal

Scenario: a launch is not terminal
  Given a record whose body marks the spawn launched
  Then it is not terminal

Scenario: a one-shot completion carrying only a result is terminal
  Given a record whose body carries a result and no lifecycle mark
  Then it is terminal

Scenario: an ordinary tell is not terminal
  Given a record whose body carries neither a result nor a lifecycle mark
  Then it is not terminal

Scenario: an unknown mark is not terminal, and says it was not understood
  Given a record whose body carries a lifecycle mark outside the vocabulary
  Then it is not terminal
  And the object reports the mark it did not recognise
```
→ spec file: `spec/lain/telemetry/spawn_lifecycle_spec.rb`

**Escalation triggers:**
- `"settled"` is written on **every** actor turn (`actor.rb:181`), not only the last. If any AC here
  tempts treating it as terminal, stop — retiring a long-lived actor on its first reply is a worse
  defect than never retiring it, and it is the specific mistake this object exists to prevent.
- **This object must not raise.** Both consumers are per-turn status sinks riding
  `CLI::JournalTee`, which re-raises a sink's failure into the agent loop —
  `status_feed/inbox.rb:97-119` is an entire comment block about widening a rescue for exactly that
  reason, `status_feed.rb:297-305` is a second, and `fleet_windows.rb:289-292` cannot raise today.
  The sixth AC is written as "not terminal, and reports what it did not recognise" for this reason.
  If the implementation reaches for a raise instead, stop — a strict constructor for a caller that
  can afford one is a separate decision, not this card's.

### T6 — A one-shot's completion speaks the same lifecycle vocabulary   [wave 2] [risk: high]

**Depends on:** T5
**Files:** `lib/lain/tools/subagent/lineage.rb`, `spec/lain/tools/subagent/lineage_spec.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/supervisor_reactor_spec.rb` (the comment at
`:283-290` only)
**Reuse:** `Lineage#note`'s conditional write (`lineage.rb:71-74`) is the exact idiom —
`body["lifecycle"] = lifecycle unless lifecycle.nil?`. T5's vocabulary names the value.
**Shared-file wiring:** none
**Reachable from:** `Subagent#spawn_one_shot` (`tools/subagent.rb:194-206`) calls
`lineage.message(parent, spawn, child, response)` on the real dispatch of every one-shot child; the
tool is built at `CLI::Wiring::ToolsetBuild`.

`Lineage#message` (`lineage.rb:57-62`) writes `{"result" => ..., "final" => ...}` and no lifecycle
mark, which is the asymmetry T5 had to accept as a legacy shape. Writing the mark makes the
vocabulary closed going forward, so a reader keys on one field rather than on the presence of
another. **This changes the digest of future one-shot completion messages and no others** —
historical records keep theirs and T5's predicate still answers them.

**Acceptance criteria:**

```gherkin
Scenario: a one-shot completion carries a terminal lifecycle mark
  Given a one-shot child that returned a result
  When its completion message is written
  Then the message's body carries a lifecycle mark from the closed vocabulary
  And it still carries the result and the child's final head

Scenario: the completion's causal edges are unchanged
  Given a one-shot child that returned a result
  When its completion message is written
  Then it still cites the spawn and the child's final turn

Scenario: the spawn event's own bytes are unchanged
  Given a one-shot spawn
  When the spawn event is written
  Then it carries no lifecycle mark
```
→ spec file: `spec/lain/tools/subagent/lineage_spec.rb`

```gherkin
Scenario: a one-shot dispatch end to end still hands the parent its result
  Given a real one-shot spawn through the subagent tool
  When the child returns
  Then the parent receives the child's text as the tool's result
```
→ spec file: `spec/lain/tools/subagent_spec.rb`

**It also settles a comment that argues against it.** `spec/lain/supervisor_reactor_spec.rb:283-290`
says landing the actor's marker when it landed *"was the cheap moment: events are content-addressed,
so a later marker would have changed digests under recorded journals."* Grounding shows why that does
not bind — `MessageReplay#verified` re-derives a historical digest from the historical record — so
this card amends that comment rather than leaving a spec arguing the opposite of the tree.

**Escalation triggers:**
- **Any spec asserting a literal digest for a one-shot completion message will go red**, and that is
  the expected consequence, not a defect — but if one asserts a literal digest for the `:spawn`
  event or for a *parent* turn, stop: that means the change reached further than the completion
  message and the "additive and backward-compatible" premise in Grounding is wrong.
- `Lineage#spawn`'s note (`lineage.rb:32-36`) says `lifecycle` is written conditionally so a
  one-shot spawn's bytes are unchanged. If this card's edit makes that note false, stop — the note
  is load-bearing for `:spawn` idempotence in `FleetWindows` and `StatusFeed`.
- `FleetWindows#terminal?` (`fleet_windows.rb:289-292`) currently recognises a one-shot by
  `"result"`. Until T7 lands it must keep working against records that now carry both fields. If
  adding the mark changes what that predicate answers for any record, stop — T7 has not run yet.

### T7 — FleetWindows asks the lifecycle rather than re-deriving it   [wave 2] [risk: low]

**Depends on:** T5
**Files:** `lib/lain/cli/fleet_windows.rb`, `spec/lain/cli/fleet_windows_spec.rb`
**Reuse:** T5's object, replacing the inline two-shape test at `fleet_windows.rb:289-292`. The
surrounding `#observe_close` (`:281-287`) and the `@seen`/`@windows` split (`:256-262`) are
unchanged.
**Shared-file wiring:** none
**Reachable from:** `CLI::LiveViews#initialize` (`live_views.rb:128`) builds it as
`FleetWindows.for(options)` and puts it in the tee at `:129` — **but only under `lain up --windows`
inside tmux**: `FleetWindows.for` (`fleet_windows.rb:172-176`) returns a `Null` whose `#<<` is
`def <<(_event) = self` (`:53-56`) otherwise. That is correct and expected; it is stated here so no
reader mistakes the Null for this card's doing, and so integration check 8's `--windows` step is not
dropped as optional.

A behaviour-preserving substitution, and the point of it is that the next reader (T8) asks the same
object rather than growing a second copy of the predicate. **`#terminal?` is deleted, not left
beside its replacement** — otherwise this card has no gate that tells "substituted the object" from
"did nothing", since every existing example passes either way. Its existing examples
(`spec/lain/cli/fleet_windows_spec.rb:129-170`) already cover farewell, one-shot result,
tell-is-not-terminal, redelivered spawn and spawn-after-terminal, and must stay green unchanged.

**Acceptance criteria:**

```gherkin
Scenario: an actor farewell still closes its window
  Given a windowed actor spawn
  When its farewell arrives
  Then the window is marked done

Scenario: a one-shot result still closes its window
  Given a windowed one-shot spawn
  When its completion arrives
  Then the window is marked done

Scenario: an ordinary tell still closes nothing
  Given a windowed spawn
  When a plain message from it arrives
  Then no window is marked done

Scenario: a completion carrying both a result and a lifecycle mark closes its window once
  Given a windowed one-shot spawn
  When a completion carrying both arrives twice
  Then the window is marked done exactly once

Scenario: the predicate has one home
  Given the FleetWindows source
  Then it defines no terminal predicate of its own
```
→ spec file: `spec/lain/cli/fleet_windows_spec.rb`

**Escalation triggers:**
- Every existing example in `fleet_windows_spec.rb:129-170` must stay green **without edit**. If any
  needs rewording, the substitution changed behaviour and is no longer this card — stop and report
  which.
- The last AC is the card's only real gate — the other four pass today. If deleting `#terminal?`
  turns out to be impossible because something else calls it, stop and name that caller: a second
  consumer changes T5's design.

### T8 — A finished spawn leaves the fleet   [wave 3] [risk: high]

**Depends on:** T5, T6, T18
**Files:** `lib/lain/status_feed/fleet.rb`, `spec/lain/status_feed/fleet_spec.rb`,
`spec/lain/status_feed_spec.rb`, `spec/lain/supervisor_reactor_spec.rb`
**Reuse:** T5's lifecycle object for the predicate; `FleetWindows`'s `@seen`-beside-`@windows`
split (`cli/fleet_windows.rb:256-262`, `:281-287`) for the structure — a standing set that makes a
redelivered `:spawn` a no-op, and a separate live set that entries actually leave. The
`causal_parents` join is already in the completion records (`tools/subagent/lineage.rb:57-62`,
`tools/subagent/actor.rb:187-189`).
**Shared-file wiring:** none
**This card edits the object T18 extracted, not `StatusFeed` itself** — which is what keeps it
clear of `Metrics/ClassLength` (115 of 125 before T18) and gives the retirement one home.

**Reachable from:** `StatusFeed#observe` (`status_feed.rb:407-412`), delegating to the extracted
`Fleet`, on the tee built at
`CLI::LiveViews#initialize` (`live_views.rb:128-130`); published through `#observed`
(`status_feed.rb:450-457`) to `state.json`, and read by the HUD at `cli/up/hud.rb:70`, the tmux
script `plugin/tmux/scripts/lain-status:66`, `PromptComposer::RunState#fleet`
(`frontend/prompt_composer.rb:362-365`) and `CLI::Command::Status#counts`
(`cli/command/status.rb:53`).

`fleet` is the only published field that is a set of identities with an add path and no remove path.
This card gives it one, journal-derived — `status_feed.rb:16-17` forbids reaching into an in-process
registry and `spec/lain/status_feed_spec.rb:182` pins that.

**Acceptance criteria:**

```gherkin
Scenario: a finished one-shot leaves the fleet
  Given a spawn observed on the feed
  When its completion naming that spawn arrives
  Then the published fleet is empty

Scenario: a stopped actor leaves the fleet
  Given an actor spawn observed on the feed
  When its farewell naming that spawn arrives
  Then the published fleet is empty

Scenario: an actor that settles a turn stays in the fleet
  Given an actor spawn observed on the feed
  When it settles a turn
  Then the published fleet still names it

Scenario: a redelivered spawn never re-enters the fleet
  Given a spawn that was observed and then completed
  When the same spawn event is delivered again
  Then the published fleet stays empty

Scenario: a completion naming an unknown spawn changes nothing
  Given a spawn observed on the feed
  When a completion naming a different digest arrives
  Then the published fleet still names the observed spawn

Scenario: a completion for a spawn this feed never saw changes nothing
  Given a feed that observed no spawn
  When a completion arrives naming some digest
  Then the published fleet is empty
  And a later spawn of that digest is still listed
```
→ spec file: `spec/lain/status_feed/fleet_spec.rb` and `spec/lain/status_feed_spec.rb`

```gherkin
Scenario: a stopped actor retires from a real feed driven by the real journal
  Given a live supervisor running an actor that is launched and then stopped
  When that run's journal records are drained through a real StatusFeed
  Then the published fleet is empty
  And it is empty because the journal said so, not because nothing was ever observed
```
→ spec file: `spec/lain/supervisor_reactor_spec.rb`

The last AC replaces a weaker one the first draft carried — *"a feed with no events published
publishes an empty fleet"* — which is true of every implementation, correct or broken, and so
gates nothing. The in-process-registry rule it was meant to protect is already pinned at
`spec/lain/status_feed_spec.rb:182`.

**Escalation triggers:**
- `spec/lain/supervisor_reactor_spec.rb:267` is titled *"…stop never RETIRES the entry"* and
  `:297` asserts `[[actor.address]] * 3`. This card inverts both deliberately; rewrite them rather
  than deleting them, so the record shows what changed. If either turns out to be pinning something
  other than the fleet, stop.
- `spec/lain/status_feed_spec.rb:173` is titled *"does not grow on a :message or :turn event — only
  :spawn names a fleet member"*. That title now describes the bug. Reword it to what it should mean
  — that an ordinary message adds nothing — rather than deleting the example.
- `spec/lain/supervisor_reactor_spec.rb:178` is `pending` on the twinned-actor address collision and
  **must stay pending** (Open decision 3). If retiring makes it pass, stop and report: that means
  the retire is address-blind in a way the plan did not intend, and RSpec's stale-marker failure is
  the signal, not a nuisance.
- **The `:message` arm must be shape-tolerant.** `status_feed.rb:215-222` states the recognised set
  as five records matched by CLASS *plus anything answering `#kind`*, and `:241` dispatches on that
  alone — so a raw `Lain::Event`, which answers `#kind` and `#body` but **not** `#payload`, reaches
  this arm. `FleetWindows` survives only because it never sees Events. A `NoMethodError` here
  unwinds through `CLI::JournalTee` and costs a turn, which is the exact failure
  `status_feed/inbox.rb:105-114` widened a rescue for. If the arm cannot read both shapes without a
  rescue, stop and confirm the shape rather than adding a third wide rescue.
- `PromptComposer::RunState#fleet` (`frontend/prompt_composer.rb:362-365`) elides the segment at
  zero, and `spec/lain/frontend/prompt_composer_spec.rb:286` pins that. A fleet that now reaches
  zero mid-run makes that elision reachable where it was not. If any prompt example asserts the
  segment's persistence, stop and confirm the intended prompt behaviour with the human.

### T9 — Settle whether the unwrapped approval command is reachable   [wave 2] [risk: medium]

**Depends on:** T12 (both edit `planning/qa/scenarios/cockpit-surfaces.md`; T12 lands first)
**Files:** `planning/qa/scenarios/cockpit-surfaces.md`; and, only if the investigation finds a real
defect, `spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** commit `2398ec2d` ("approval: publish the command unwrapped, beside the rows") and the
round-14 chunk's T2 card (`chunk-qa-round14-escalation-and-isolation.md:522-577`), which rules that
F76 is **not** "stop hard-wrapping" but "a reader needs an unwrapped copy". The wrap itself is
`BODY = /.{1,#{WIDTH - INDENT.length}}/m` (cited at that chunk's `:121`).
**Shared-file wiring:** none
**Reachable from:** `Frontend::Neovim::ApprovalView`, built by `Frontend::Neovim::Buffers`; the
deliverable is a scenario section naming where a driver reads the unwrapped copy.

Round 15 re-checked F76 against a tree where `2398ec2d` had **already landed** and reported
"REPRODUCES", quoting a wrapped row. Either the driver read the rows rather than the unwrapped
publication, or T2 does not do what its message claims. **This card settles which, and its primary
output is the scenario text that stops a sixth round re-filing it.** If the fix is real and only
undocumented, no `lib/` change lands.

**Acceptance criteria:**

```gherkin
Scenario: the scenario names where an unwrapped command is read
  Given cockpit-surfaces' approval section
  When a driver follows it to check a long command
  Then it names the buffer or expression carrying the command unwrapped
  And it says that a wrapped row is expected and is not the finding

Scenario: the claim is grounded in a citation a reader can check
  Given that section
  Then it cites the file and line that publishes the unwrapped copy
```
→ spec file: none — prose. Verified by the reviewer opening each citation.

**Escalation triggers:**
- **If the unwrapped publication turns out not to exist on the real path**, stop and escalate rather
  than writing a scenario around it: that makes F76 a live defect and a code card this plan does not
  have, and it means the round-14 chunk shipped a green claim it does not hold — which is the exact
  failure mode that chunk was written to diagnose.
- `approval_view_spec.rb:554-557` is cited by the round-14 chunk as restating the wrap's
  deliberateness. If it contradicts what the investigation finds, stop and report the contradiction
  rather than editing either side.

### T10 — A driver names the pane it drives, or refuses   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, `planning/qa/method.md`
**Reuse:** the ambiguity refusal already in the same file — `qa-sandbox.sh:71-82`, whose `*)` arm
prints every candidate and `exit 2`s rather than guessing an nvim socket. This card applies that
same rule one surface over.
**Shared-file wiring:** none
**Reachable from:** `qa-sandbox.sh` writes `drive.sh` and `peek.sh` into `$QA/` at sandbox creation;
every QA round drives through them.

`grep -w ruby | head -1` (`qa-sandbox.sh:58` for `drive.sh`, `:114` for `peek.sh`) silently picks a
stranger pane. Round 15 typed a prompt intended for a probe into the cockpit and added a turn to the
subject session. The hazard is already written up at `method.md:481-486`; only the code is unfixed.
An explicit target must be passable, and an ambiguous match must refuse rather than choose.

**`method.md` is in scope because this card makes part of it stale.** `method.md:481-486` is the
write-up of this exact hazard, phrased as a standing warning to work around. Once the script
refuses, that paragraph must say what the script now does instead — a doc telling a driver to beware
a fixed defect is how the next round wastes a probe.

**Acceptance criteria:**

```gherkin
Scenario: an explicitly named pane is used
  Given a pane id supplied by the driver
  When drive.sh runs
  Then it sends to that pane and resolves nothing

Scenario: two candidate panes refuse rather than guess
  Given two panes whose current command matches
  And no pane supplied explicitly
  When drive.sh runs
  Then it exits non-zero naming every candidate
  And it sends nothing

Scenario: one candidate pane still works unchanged
  Given exactly one matching pane
  When drive.sh runs
  Then it sends to that pane

Scenario: peek.sh follows the same rule
  Given two panes matching the requested kind
  When peek.sh runs
  Then it exits non-zero naming every candidate
```
→ spec file: none — shell. Verified by `bash -n` on the generated scripts plus a driven sandbox.

**Escalation triggers:**
- `drive.sh`'s approval guard (`qa-sandbox.sh:64-83`) runs **before** any send and is what stops an
  accidental `Enter` from denying a parked call. If refactoring the pane resolution moves that guard
  after the send, stop — that ordering is load-bearing and cost a round three turns once.
- `peek.sh` resolves `nvim` as well as `ruby` (`qa-sandbox.sh:113`). If a uniform refusal makes the
  ordinary two-pane cockpit (nvim and repl in one window, per `method.md`) ambiguous by default,
  stop — the fix must not refuse the normal case.

### T11 — Every `nv.sh` read ends in a newline   [wave 2] [risk: low]

**Depends on:** T10 (both edit `qa-sandbox.sh` and `method.md`; T10 lands first)
**Files:** `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, `planning/qa/method.md`
**Reuse:** the `msgs` arm (`qa-sandbox.sh:157`), which already avoids the defect incidentally by
piping through `tr`.
**Shared-file wiring:** none
**Reachable from:** `qa-sandbox.sh` writes `nv.sh` into `$QA/`; every RPC read in every scenario goes
through it.

`nvim --remote-expr` writes no terminator, so two consecutive reads concatenate in a transcript.
Round 15 read `tab2=4` followed by a bare `4` as `tab2=44` and briefly believed in a 44-window tab —
a finding that had to be withdrawn. `expr` (`:155`) is the one filed; `bufs` (`:157`), `tabs`
(`:158`), `buf` (`:160`) and `fold` (`:161`) share it. `send` (`:156`) reads nothing and `msgs`
(`:159`) escapes through its `tr`.

**Acceptance criteria:**

```gherkin
Scenario: two consecutive expr reads do not concatenate
  Given nv.sh expr run twice against the same server
  When both outputs are captured to one transcript
  Then each value occupies its own line

Scenario: every remote-expr subcommand terminates its output
  Given nv.sh run with each of expr, bufs, tabs, buf and fold
  Then each output ends with a newline

Scenario: a value's own content is unchanged
  Given a multi-line buffer read
  Then its lines are unchanged apart from the added terminator
```
→ spec file: none — shell. Verified by `bash -n` plus a driven sandbox.

**Escalation triggers:**
- `method.md:498-501` documents this defect and tells a driver to echo a newline themselves. That
  paragraph is in this card's Files for exactly that reason: leaving it would double-space every
  read in the next round. If T10 has already rewritten the surrounding section, reconcile rather
  than re-adding.

### T12 — Settle how many windows a survey's review tab has   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `planning/qa/scenarios/cockpit-surfaces.md`
**Reuse:** §4's round-14 measurement (`cockpit-surfaces.md:130-141`), which distinguishes a
changeset (sidebar, OLD, NEW) from a survey (sidebar, NEW) and tells a driver to read the banner and
`winnr("$")` rather than either quoted number.
**Shared-file wiring:** none
**Reachable from:** prose; the deliverable is a scenario a driver can follow without contradicting
itself.

§4b is explicitly a survey (`:341`) yet its `<CR>` comment says `sidebar | OLD | NEW` (`:353`) and
its following paragraph (`:355-358`) calls an empty OLD window "§4b's expected state". §4 says a
survey has no old side and therefore two windows. **Round 15 did not report this**; it surfaced
during grounding, and it is the likely root of P31 as filed — a driver following §4b counts one
window too many and lands a motion in the wrong pane.

**Acceptance criteria:**

```gherkin
Scenario: the two sections agree on a survey's window count
  Given cockpit-surfaces §4 and §4b
  Then both describe a survey's review tab the same way

Scenario: the empty-OLD paragraph is resolved rather than left standing
  Given §4b
  Then it either drops the empty-OLD expectation or says which source produces one

Scenario: the motion advice is derivable, not quoted
  Given §4b
  Then it tells a driver to read the banner and the window count rather than a fixed motion
```
→ spec file: none — prose. Verified by the reviewer reading both sections against
`cockpit-surfaces.md:130-141`.

**Escalation triggers:**
- If driving a real survey shows **three** windows — that §4b was right and §4's round-14
  measurement is the stale one — stop and report. That inverts the card and makes the round-14
  correction wrong, which is worth a finding rather than a silent edit.

### T13 — Make the truncated-stream recipe drivable   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `planning/qa/scenarios/failure-injection.md`
**Reuse:** `spec/lain/provider/ollama/stream_assembler_spec.rb:239-243` is a working
`counts_absent` driver — a terminal frame with both counts stripped over a stream that **closes** —
and `:246-251` states the `unterminated` rule the scenario contradicts.
**Shared-file wiring:** none
**Reachable from:** prose; the deliverable is a §1b a driver can execute and get a verdict from.

Round 15 built both documented proxies and got **zero** `truncated_stream` records, reporting F78 as
"inconclusive on the records". The scenario is why. §1b tells a driver to sever before any
`done: true` frame and expect `kind: "unterminated"` (`:94`), and to expect "exactly one
`TruncatedStream` per severed request" (`:105`). The shipped behaviour is the opposite and is
deliberate: a mid-stream sever is **cleanly retried**, the abandoned attempt is not the turn, and a
record for it would be noise. Round 15's `counts_absent` proxy then left the connection open, so the
assembler waited for more and the round read a `stalled stream` instead.

**Acceptance criteria:**

```gherkin
Scenario: the unterminated expectation matches the shipped rule
  Given failure-injection §1b
  Then it says a cleanly retried sever journals no record
  And it cites where that rule is pinned

Scenario: the counts-absent recipe is executable
  Given §1b
  Then it says the terminal frame must arrive and the stream must close
  And a driver following it can distinguish this from a stalled stream

Scenario: the confirmation step expects the right number of records
  Given §1b's journal-reading snippet
  Then its stated expectation matches what each variant actually produces
```
→ spec file: none — prose. Verified by the reviewer against
`spec/lain/provider/ollama/stream_assembler_spec.rb:239-251`.

**Escalation triggers:**
- If a driven `counts_absent` proxy that closes its stream **still** produces no record, stop: the
  scenario is then not the only thing wrong and F78's records are a live defect, which is a code
  card this plan does not have.
- §1a's zero-usage half is a different finding with its own landed fix (`f925c2c7`, `79cc7594`).
  If correcting §1b tempts rewriting §1a, stop — round 15 confirmed §1a's protected property held
  in both shapes and that text is earning its place.

### T14 — The command surface is twenty-one, and `/mode auto` has one list of doors   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa/scenarios/repl-commands.md`
**Reuse:** `spec/lain/cli/command/surface_spec.rb:143-147` is the authoritative literal roster;
`cli/command/surface.rb:98-128` is registration order, which is `/help` listing order.
**Shared-file wiring:** none
**Reachable from:** prose; the deliverable is a scenario whose own enumeration survives the `/help`
comparison it instructs a driver to make.

Two corrections in one document pair. **The count:** `repl-commands.md:3-6` enumerates 10 + 10 and
omits `/introspect`, which is registered at `surface.rb:118` and makes twenty-one — and the scenario
tells a driver at `:39-42` that `/help` is the authority, so following it produces a 21st command
with no section. **The posture:** `repl-commands.md:78` instructs "Set `auto` plus two layers, then
`!`", which `method.md:200-207` forbids outside two sanctioned sections; and that sanction list is
stale in the other direction too, since `shell-term-approval.md:603` is itself a `/mode auto`
section. Round 15's driver hit this and drove the reset from `accept_edits` instead.

**Acceptance criteria:**

```gherkin
Scenario: the scenario's enumeration matches the registry
  Given repl-commands' opening enumeration
  Then it names every command the registry holds
  And its stated count matches

Scenario: /introspect has somewhere to be driven
  Given repl-commands
  Then some section drives /introspect and says what it should report

Scenario: the reset is driven without raising the posture to auto
  Given repl-commands §1
  Then it reaches the reset from a posture method.md already permits
  And it still proves that the reset drops every layer and the posture together
```
→ spec file: none — prose. Verified by the reviewer against `surface_spec.rb:143-147` and by
grepping the scenarios for `/mode auto`.

**`method.md` is deliberately NOT in this card's Files.** Three cards have a reason to edit it and
it gets one owner: T16, which runs last and can record every ruling at once. This card fixes §1 by
driving the reset from `accept_edits` — the posture round 15's driver used — rather than by asking
for a new sanction. **If §1 genuinely cannot prove the reset without `auto`, stop and hand T16 the
question** rather than editing `method.md` here.

**Escalation triggers:**
- `surface.rb:110-113` records that `#builtins` measures 17.0 against `Metrics/AbcSize`'s limit of
  17, so the next command added there trips the cop. If this card's grounding pass finds a
  twenty-second command already landed, stop — the roster literal and the cop are both about to
  move and that is a code question, not a doc one.
- Whether the approve-all rule should sanction a third section or bind harder is the human's call.
  Propose it to T16; do not decide it here.

### T15 — One subsystem, one scenario   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `planning/qa/scenarios/shell-terms.md`, `planning/qa/scenarios/shell-term-approval.md`
**Reuse:** each file's own "What it deliberately does NOT own" section — `shell-terms.md:16-22`
already disclaims the approval *surfaces* and points at `cockpit-surfaces.md`, which is the idiom
for dividing coverage without duplicating it.
**Shared-file wiring:** none
**Reachable from:** prose; the deliverable is a directory a driver can enumerate without driving the
same subsystem twice.

The merge at `9ead317c` brought both files in from different lineages: `shell-terms.md` (608 lines,
`4357a2d9`) and `shell-term-approval.md` (685 lines, `8f93c869`). Both are about
`lib/lain/shell/`; both were written as "the subsystem that had zero coverage". Round 15 drove one,
did not notice the other, and reported "all 17 scenarios … none dropped" against a directory holding
18. **Per Open decision 6 this card must produce one outcome or the other and say which in the
file** — either a merge, or an explicit division with each file disclaiming what the other owns.
It also harmonises `shell-term-approval.md` §0 (`:89-105`, "the arm IS observable") with §8
(`:522-534`, which correctly qualifies that to attended sessions only) — §0 currently overstates.

**Acceptance criteria:**

```gherkin
Scenario: no two scenarios claim the same subsystem without saying so
  Given the shell scenarios after this card
  Then either one file remains, or each names what the other owns

Scenario: the observability claim carries its own qualifier
  Given shell-term-approval §0
  Then it says the arm is inferable from the gate's record for attended sessions
  And it points at the section that drives the unattended hole

Scenario: a driver enumerating the directory knows what to run
  Given the shell scenarios after this card
  Then following them drives the subsystem once
```
→ spec file: none — prose. Verified by the reviewer diffing the two files' coverage claims.

**Escalation triggers:**
- Roughly half of `shell-term-approval.md` was written against an unlanded chunk and marked as such
  (`planning/qa/README.md:437-441`). If merging would silently drop sections that are predictions
  about unlanded work, stop — those are owed coverage, not duplication, and dropping them is a
  scope decision for the human.
- `planning/qa/README.md` is T16's to edit. Do not touch it here; hand T16 the ruling instead.

### T16 — The bench's index tells the truth about its own scenarios   [wave 3] [risk: low]

**Depends on:** T11, T14, T15
**Files:** `planning/qa/README.md`, `planning/qa/method.md`
**This card is `method.md`'s single owner for the sanction list**, and it runs last for that
reason: T14 may hand it a question about `repl-commands` §1, T15 decides whether
`shell-term-approval.md` §11 still exists to be sanctioned, and T10/T11 have already rewritten the
driver-script paragraphs. Verified: `method.md:200-207` sanctions only `repl-commands.md` §6 and
`secret-boundary.md` §5, while `shell-term-approval.md:603` is itself a `/mode auto` section and
`planning/qa/README.md:116` advertises `shell-terms.md` as covering `/mode auto`.

**Reuse:** the file's own standing rule at `:157-159` — *"the directory listing is the authority on
the set … never from a count or a list written down anywhere, including here"* — which is the
principle this card applies to the rest of the document.
**Shared-file wiring:** none
**Reachable from:** prose; this is the file the `manual-qa` skill defers to for a round's scope and
order.

Four stale claims, each verified: the shell subsystem's coverage gap is declared **twice** in
adjacent sections (`:109-136`), each saying "the gap was invisible"; the ordering prose
(`:155-205`) places fifteen of eighteen scenarios and gives `shell-terms` and `ollama-cloud-arm` no
tier at all; Known gaps (`:437-441`) still calls `shell-term-approval.md` undriven, which round 15
disproved; and `:41` repeats `repl-commands`' stale twenty. This card lands **after** T14 and T15 so
it records their rulings rather than guessing them.

**Acceptance criteria:**

```gherkin
Scenario: every scenario in the directory has a tier
  Given the ordering section
  Then every file in planning/qa/scenarios has a placement

Scenario: the shell subsystem's coverage is declared once
  Given the README
  Then it describes the shell scenarios' coverage in one place

Scenario: Known gaps does not name a driven scenario as undriven
  Given Known gaps
  Then shell-term-approval is recorded as driven, with its round

Scenario: the command count matches the registry
  Given the repl-commands row
  Then its count matches what the registry holds

Scenario: the /mode auto sanction list names every section that drives it
  Given method.md's standing /mode auto rule
  Then every scenario section that drives auto appears in its list
  And no listed section has been renamed or merged away
```
→ spec file: none — prose. Verified by the reviewer diffing the ordering section against
`ls planning/qa/scenarios/`.

**Escalation triggers:**
- If T15 merged the two shell scenarios, a README row, a Known-gaps entry **and possibly a
  `method.md` sanction line** now name a file that does not exist. Check the directory rather than
  the diff.
- The Known gaps entry for the fleet (Open decision 3's twinned-actor undercount) and any entry this
  chunk's code cards discharge should be revisited here. If T8 landed, `fleet` persisting is no
  longer expected behaviour and any text saying so is now wrong — but **do not edit an entry whose
  card has not landed**; wave 3 runs after this one.

### T17 — A lead sentence does not contradict its own correction   [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa/scenarios/rails-blog.md`
**Reuse:** the correction already in the file at `rails-blog.md:10-19`, which measures Rails 8.1.3.1
at 78 files / 20 `.rb` / 440 KB and re-founds the scenario's premise on tool-result **size**.
**Shared-file wiring:** none
**Reachable from:** prose.

`rails-blog.md:4` still leads with "generates **hundreds of files**, very large tool results, and
dozens of turns" — the claim its own round-15 correction six lines down disproves. A reader who
stops at the premise gets the wrong instruction, and the scenario's whole point is now the second
clause, not the first. This is a rewrite of the lead, not another correction stacked under it.

**Acceptance criteria:**

```gherkin
Scenario: the premise states what the scenario actually reaches
  Given rails-blog's opening
  Then it founds the scenario on tool-result size rather than file count

Scenario: the correction is folded in rather than left as an erratum
  Given rails-blog
  Then it carries no claim that its own later text disproves

Scenario: the compaction guidance survives the rewrite
  Given rails-blog
  Then it still says many medium results across many turns are what make compaction fire
```
→ spec file: none — prose. Verified by the reviewer reading the opening against `:10-19`.

**Escalation triggers:**
- `:10-19` also carries F82's mechanism (`head_bytes: 2` because the oversized result sits in the
  retained tail). T3 and T4 change what a human is told in that situation but **not** the mechanism.
  If rewriting tempts a claim that compaction now handles one enormous result, stop — Open decision
  1 says explicitly that it does not.

### T18 — Extract the fleet into the object the feed is missing   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/status_feed.rb`, create `lib/lain/status_feed/fleet.rb`, create
`spec/lain/status_feed/fleet_spec.rb`, `spec/lain/status_feed_spec.rb`
**Reuse:** **`StatusFeed::Inbox`** (`lib/lain/status_feed/inbox.rb`) is the exemplar and the sibling
— a standing set with an arrival side and a retire side, extracted out of the feed, delegated to
from `StatusFeed#observe` (`status_feed.rb:407-412`) and published through `#observed` (`:450-457`).
`Inbox#bind_store` (`inbox.rb:56-59`) is the late-binding precedent if one is ever needed.
`FleetWindows`'s `@seen`-beside-`@windows` split (`cli/fleet_windows.rb:256-262`) is the structure
the retirement in T8 will want, and this card leaves room for it without building it.
**Shared-file wiring:** one `require_relative "status_feed/fleet"` line in `lib/lain/status_feed.rb`,
which is that subtree's index
**Reachable from:** `StatusFeed#observe` (`status_feed.rb:409`) on the tee built at
`CLI::LiveViews#initialize` (`live_views.rb:128-130`), published to `state.json` by
`#publish_if_changed` (`:473-475`) and read by all four fleet readers named in T8.

**Behaviour-preserving, and it exists because two later cards cannot both fit.**
`.rubocop.yml:161` caps `Metrics/ClassLength` at 125 and `StatusFeed`'s body measures **115**
non-comment, non-blank lines from `status_feed.rb:151`; there is no `.rubocop_todo.yml`, so it
passes on merit today. T2 adds a record arm and routing, T8 adds a second standing set, an observe
arm, a retire path and a predicate call — and T8 is the chunk's last card, with nothing after it to
absorb a tripped cop. CLAUDE.md's rule is that a tripped `Metrics/*` limit names a missing object
rather than a limit to raise, and `@fleet` is the one field of this shape the feed never extracted:
three sites (`:211` init, `:409` add, `:451` read) and a Hash keyed by digest whose *only* stated
reason (`status_feed.rb:207-210`) is idempotence under replay.

**Acceptance criteria:**

```gherkin
Scenario: the published fleet is unchanged by the extraction
  Given a feed observing a spawn, a message and a turn
  Then the published fleet names exactly the spawn

Scenario: a redelivered spawn still grows no phantom entry
  Given a feed that observed a spawn
  When the same spawn event is delivered again
  Then the published fleet names it once

Scenario: a message and a turn still add nothing
  Given a feed observing only a message and a turn
  Then the published fleet is empty

Scenario: the fleet answers for itself
  Given the extracted object alone
  When it is asked what it holds after a spawn
  Then it answers without a StatusFeed
```
→ spec file: `spec/lain/status_feed/fleet_spec.rb` and `spec/lain/status_feed_spec.rb`

**Escalation triggers:**
- `spec/lain/status_feed_spec.rb:161-205` is the existing `describe "fleet"` block, and every one of
  its four examples must stay green **through the feed's public surface** — this card changes no
  behaviour, so an example that needs rewriting means the extraction moved something. Stop and say
  which.
- `spec/lain/status_feed_spec.rb:182` pins that the feed never reaches into an in-process registry,
  and `status_feed.rb:16-17` states it. If the extracted object gives anyone a seam to inject a live
  `Supervisor` through, stop — that seam is the thing the rule exists to prevent.
- If extracting `@fleet` does **not** bring the class under the cap with room for T2 and T8, stop and
  report the measured number: the chunk then needs a second extraction and that is a decision, not a
  card's improvisation.

## Integration checks

After the last wave:

1. **Full suite**: `bundle exec rake pspec`. Compare the **example COUNT** against the pre-chunk
   baseline as well as the failure count — `parallel_tests` reports only survivors (CLAUDE.md).
   Record the baseline in the execution log before the first card runs.
2. **Lints**: bare `bundle exec rubocop` (never naming a `.toml`), `bin/comment-census
   --check-tickets`, `pre-commit run --all-files`. The ticket ban applies to every comment this
   chunk writes: no `F81`, `F82`, `F83`, `P30`, `T5` in `lib/` or `spec/` — the reason goes in words.
3. **Rust untouched**: `git diff --stat ext/ crates/` must be empty. Nothing here reaches it.
4. **The parity check T2 exists to preserve**, run explicitly rather than trusted:
   `bundle exec rspec spec/lain/frontend/neovim/inbox_view_spec.rb -e "parity with StatusFeed"`.
   Both surfaces must agree at every step over the one stream the tee carries.
5. **The manual pass F81 needs, and it is the round's headline.** From a real cockpit: take one
   ordinary turn, spawn a subagent that parks a question, answer it as prose at `human>`, let the
   child finish. Then require **all four readers to agree at zero** — `/inbox` says
   `(no questions pending)`, `inbox_count` in `state.json` is `0`, `lain://inbox` renders its
   placeholder with no row offering `:LainReply`, and `:LainReply` on that buffer refuses because
   there is nothing listed rather than because a listed row is stale. Round 15's evidence is the
   regression baseline: `/inbox` correct, the other three reading 3. Run the **control** in the same
   session — the parent's own `ask_human`, answered — and require it to behave identically.
6. **The manual pass T8 needs**: in the same session, with every child finished and its result
   folded into the parent, require the HUD's `fleet` segment to be **absent** (it elides at zero,
   `prompt_composer.rb:362-365`) and `state.json`'s `fleet` to be `[]`. Round 15 read `fleet 3`.
7. **The manual pass T4 needs**: drive `rails-blog`'s reproduction — a single `read_file` of a
   ~112 KB file on a 32,768-token window — and require the chat pane to **say** the context is full
   and uncompactable. Round 15's evidence is that nothing was said while `head_bytes` was 2 and
   `approaching_window` fired every turn.
8. **The bench's own scripts, driven once**: create a fresh sandbox from `qa-sandbox.sh`, and check
   that `drive.sh` refuses with two candidate panes up and succeeds with one, and that two
   consecutive `nv.sh expr` reads land on two lines. T10 and T11 have no spec suite; this is their
   only gate. **T7's production path needs `--windows` inside tmux** to be exercised at all —
   `FleetWindows.for` returns a Null otherwise (`cli/fleet_windows.rb:172-176`) — so bring the
   cockpit up with it once and confirm a finished child's window is marked done.
9. **The layering guard this chunk's blockers turned on.** Confirm no new code reference to
   `Tools::` appears in `lib/lain/status_feed.rb`, `lib/lain/status_feed/`, `lib/lain/event*` or
   `lib/lain/session_record*` — `status_feed.rb:163-167` forbids it, and a violation would not raise
   at load, so nothing else would catch it. A `git diff` plus a grep for `Tools::` outside YARD
   `{...}` links is the whole check.
10. **`Metrics/ClassLength` on `StatusFeed`, measured rather than assumed.** It was 115 of 125
   before T18. Re-measure once T2 and T8 have landed; if the extraction did not buy enough room,
   that is a finding for the execution log, not a limit to raise.
11. **Regression gate** from `planning/qa/README.md`: `failure-injection` + `session-and-window` +
   `repl-commands` + `epic-tier` + `survey` + `prompt-slots-and-roles`. `failure-injection` and
   `repl-commands` are the two T13 and T14 edited, so drive them against the edited text.

## Execution log

**Base:** `main` at `9ead317c`. Every card branches from the branch head, re-cut per wave.
`origin/main` is `b1927ce7`, **92 commits behind** — an `isolation: "worktree"` fork would open a
tree missing this entire chunk's grounding, so every worktree is cut by hand from `HEAD`.

**Worktrees are named `r15-*`.** `tmp/worktrees/T14` already exists, on branch `card/T14`, holding
the round-14 chunk's unlanded T14 with uncommitted work in nine tracked files. That chunk owns it;
this one does not touch it, and namespaces around the id collision.

**Suite baseline, pre-chunk:** `16503 examples, 0 failures, 15 pendings` (58s, `rake pspec`).
Integration check 1 compares the example COUNT against this figure, not only the failure count.

**Grounding re-verified 2026-08-28 against `9ead317c`** for every wave-1 card. All citations hold;
drift is at most two lines (`scribe.rb`'s `#child_turn` doc block runs 252-276 rather than 249-256).
`StatusFeed` measures **115** non-comment non-blank lines from `status_feed.rb:151` against
`.rubocop.yml:161`'s `Max: 125`, and `bundle exec rubocop --only Metrics/ClassLength` reports zero
offenses — T18's premise confirmed rather than assumed.
