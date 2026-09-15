# Round 18 research: subagent lineage, the fleet, memory and dogfood passes, bench

Tree: `main` at `90f081b9`. Read-only: code, `git log`/`git show`, planning docs and the fork reports
(`~/tmp/lain-qa-round18/records/fork-{subag,memory,review,epic}-report.md`). Nothing was run.
"Chunk" means `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`, and "Exec log"
means its Execution log.

Classification key: (a) a regression from the latest fix; (b) a gap outside the card's scope;
(c) pre-existing and untouched by the chunk; (d) by design, with a ruling owed or taken; (e) the
finding or scenario is wrong.

---

## The shared mechanism: when a `tool_use` turn reaches the session file

Four findings rest on this, so it is set out once. Every step below was read in code.

1. `Agent#run_loop` (`lib/lain/agent.rb:362-373`) wraps **one whole iteration** in
   `@instrumentation.turn_middleware`. An iteration is `step` (the model call plus
   `commit_and_account`) and then `transition`, and `transition` runs `perform_tools`
   (`agent.rb:558-563`, `:612-614`).
2. `Agent#commit_and_account` (`agent.rb:511-523`) commits the assistant turn to the in-memory
   Timeline. Inside the same `defer_stop` shield, `account` journals `TurnUsage`
   (`agent.rb:525-530`). The chat's instrumentation journal is `Memory::JournalMemoryRoot`
   (`cli/chronicle.rb:231-238`), which writes `memory_root` right after it
   (`memory/journal_memory_root.rb:41-47`). **Both records land before any tool runs.**
3. The **turn record** is written by `Middleware::JournalTurns#call` (`middleware/journal_turns.rb:27-31`).
   It calls `scribe.catch_up` only **after `downstream` returns**, which is after `perform_tools`
   has settled. This is wired as the chat's turn middleware in `cli/chronicle.rb:224-226`. The
   class doc says so: "every committed turn is durable BEFORE the next model call". It has been
   this shape since `a4c76fc4` ("Chat journals a durable, resumable session by default").
4. `:spawn` and `:message` events do not wait. The Lineage's `ChainWriter` observer is
   `Chronicle#observer` → `Scribe#call` → `Scribe#message` (`cli/chronicle.rb:143`,
   `session_record/scribe.rb:160-163, 253-255`), and it writes **synchronously at `put`**.

So for as long as a tool is dispatching, the file holds `turn_usage` and `memory_root` naming an
assistant turn it does not yet hold. Any record written during dispatch that cites the live head
cites an unwritten turn. That includes a `:spawn` (`lineage.rb:65, 70-71`) and a main-agent
`ask_human` question (`tools/ask_human.rb:960-964`).

**This was fixed once already, one level down.** Commit `b679ed46` (2026-08-27, round 14's F79,
"subagent: a parked question cites a head the record already carries") made a **child's** asker
and a **child's** nested spawn seam settle the child's `TurnFeed` before citing. See
`Chain#asking_handle` / `#spawning_handle` / `#settled` / `#promote` in `tools/subagent.rb:870-902`,
and `AskHuman::Parent#settled` (`ask_human.rb:452`). Its commit message:

> A child's turns reach the record through JournalTurns, which catches the scribe up AFTER the
> iteration. A parked ask never returns from perform_tools, so that catch-up never runs … A spawn
> record had the same exposure one level up.

The **top-level** parent was left out. The chat hands the seam `parent = -> { @agent.timeline }`
(`cli/wiring.rb:347-350`), a bare thunk whose `AskHuman::Parent.over` settler is `Null`
(`ask_human.rb:387-395`). The comment at `ask_human.rb:369-371` justifies that: "For the chat's own
asker it always does -- {CLI::Repl::Ask} catches the record up before it anchors anything". But
`Repl::Ask` catches up only on a **torn** ask (`cli/repl/ask.rb:62-76`), not before a question or a
spawn is written. **That comment's premise does not hold for a SIGKILL.**

**T22 knew the gap and routed around it in one reader only.** `Bench::Session::Lineages::InFlight`
(`bench/session/lineages.rb:199-289`, landed in T22 `ad045078`) says:

> A top-level spawn cites the parent's assistant turn that called it, and the scribe journals that
> turn only when its iteration returns -- after the child has run. So a live file, or one killed
> mid-spawn, holds a `:spawn` whose causal parent is on no record yet.

And at `lineages.rb:140-143`:

> A file with a spawn in flight cannot pass [Loader#recording] -- its `memory_root` names the
> unwritten turn, as its `turn_usage` does.

No card and no Exec-log entry records this as a follow-up.

---

## F134 — `lain consolidate` persists nothing (HIGH, M1)

### 1. Mechanism, re-verified

The finding is **correct but incomplete**: wiring a journal alone would not make the memories
loadable.

- `CLI::Consolidate.from_options` (`cli/consolidate.rb:29-36`) builds
  `Consolidation.new(provider:, recorder: Memory::Recorder.new, context:, slots:)` with no
  `journal:`. `Consolidation#initialize` defaults `journal: Channel::Null.instance`
  (`consolidation.rb:48-49`).
- The clerk's `memory_write` goes into that in-process Recorder (`consolidation.rb:100, 120-123`).
  Its `turn_usage`/`memory_root` go through `JournalMemoryRoot` onto Null (`:103`). Guard refusals
  and masks go to the raw Null too (`:105-115`).
- **Why a journal is not enough.** Memory survives a process only through
  `Bench::Session::MemoryReplay`. It replays `memory_write` `tool_use` inputs out of **`turn`
  records** and verifies them against `memory_root` (`bench/session/memory_replay.rb:40-49, 70-75`).
  A fresh chat always starts from `Memory::Recorder.new`; only `--resume` inherits
  (`cli/wiring.rb:328-333`). The clerk's turns live on a fresh Timeline over a new `Store`
  (`consolidation.rb:98`) and are never scribed. So even a real journal would hold usage and roots
  but no replayable writes, and no chat would ever load that file.
- **Precision.** lain's own output is `consolidate: ran a court_clerk pass over N lineage(s)`
  followed by each clerk's text (`cli/consolidate.rb:54-60`). "Written a durable memory … ID: …" is
  the **model's** prose, which lain relays.
- No `spec/lain/cli/consolidate_spec.rb` exists. `spec/lain/consolidation_spec.rb:13-46` injects a
  Recorder and `journal: []` and inspects them in-process.

### 2. Recent changes

- **Established:** `ef4cfb9f` (2026-07-21, "Add court-clerk pass …"). `recorder: Memory::Recorder.new`
  with no journal has been there from the first commit. `029410d6` added `Provider::Unreachable`
  for dry runs and left the recorder alone.
- **The most recent change is T22, `ad045078`.** It moved `Consolidation` onto
  `Bench::Session::Lineages` (`cli/consolidate.rb:72`), and that is what made the pass find
  lineages (F98). **Before T22 the pass found none, so this discard was unreachable.**

### 3. Why

- **M5 in `planning/archive/chunk-gherkin-meta-agents-plan-compaction.md:589`:**
  `✅ LANDED … follow-up: pass an opened Journal so clerk WriteRefused/MemoryRoot land durably`.
  The durability gap was **known and deferred at landing, in 2026-07**. That follow-up covers the
  journal only, not a load path.
- M5's ACs are in-process: "two memories land in the index" (`:614-618`).
- T22's intent was reading lineages, not persistence. Its AC1 stops at `--dry-run … names two
  lineages` (chunk `:2321-2324`).
- `planning/qa/scenarios/memory-and-dogfood.md:174-177` has asked since round 9 (`07e0bef2`) to
  "read them back with `memory_read` in a **fresh** session". Under the chain-scoped memory design
  (`wiring.rb:328-333`) that step **cannot pass**.

### 4. Classification

**(b) with a (c) core.** The discard is pre-existing since `ef4cfb9f`, with a durability follow-up
owed since M5. T22 exposed it by making the pass reachable. The scenario's "fresh session" step is
**(e)**: it assumes a cross-session memory the design does not have.

### 5. Constraints and open questions

- **Keep:** fresh-root clerk spawns ("FRESH-ROOT IS NOT NEGOTIABLE", `consolidation.rb:9-13`); the
  clerk's own guard stack via `CLI::ToolGuard.detached` (`:15-23`); required collaborators
  (`:32-36`); `Provider::Unreachable` for `--dry-run` (`cli/consolidate.rb:20-24`).
- **Keep:** memory's integrity proof. A `memory_root` must pair with a replayable write in a `turn`
  record (`memory_replay.rb:6-19`). A side store that skips this has no Merkle check.
- **Specs that pin today's shape:** `spec/lain/consolidation_spec.rb` (the injected recorder and
  `journal: []`), `spec/lain/bench/session/lineages_spec.rb`, and
  `spec/lain/bench/session/loader_spec.rb:675-721` (the `memory_root` chain).
- **Open (human):** which session is meant to see consolidated memory?
  - (i) a new session file the pass writes, scribing the clerk turns, that a `--resume` chains to;
  - (ii) the source session's chain, appended to;
  - (iii) a project-level store that `Wiring#run_state` loads for fresh chats. This is a new memory
    scope; today "Nothing moves memory between chains".
- **Open:** should `lain improve` get the same journal? `CLI::Improve#initialize` also defaults
  `journal: Channel::Null.instance` (`cli/improve.rb:146`), so its guard refusals vanish too. Its
  notes do reach `improvements.ndjson`.
- **Open:** T22 review S4 (Exec log `:492-493`) found adopted actors are not lineages to
  `Lineages`, so about 140 of 194 epic child turns are invisible to consolidate. Decide whether a
  persistence fix should wait for that scope.

---

## F135 — a SIGKILL mid one-shot spawn strands the session (HIGH, SB1)

### 1. Mechanism, re-verified

The finding is **correct but incomplete**: the `:spawn` record is only the first refusal the load
reaches.

- `Lineage#spawn` (`tools/subagent/lineage.rb:64-72`) writes `causal_parents: [head]` where
  `head = parent.head_digest`, the live assistant `tool_use` turn. The observer writes it at once
  (shared mechanism, point 4), while the turn record waits for `JournalTurns` (point 3).
- **Why every door refuses.** `CLI::Resume#rebuild`, `#fork` and bench `variance` all call
  `Bench::Session::Loader#recording` on the **whole file** before salvage or checkout
  (`cli/resume.rb:113-116, 139-143, 165-167`). `MessageReplay#forced_put` raises
  `message record N … cites a causal parent this replay never landed` (`message_replay.rb:123-128`).
  So the fork point cannot matter, which is F23's signature.
- **The layer underneath.** Once the spawn is past, `Recording.new(... memory:)`
  (`loader.rb:74-81, 308-310`) replays memory. `MemoryReplay#agree!` raises
  `memory_root record names turn …, which is not in the turn chain` for a root naming an unwritten
  turn (`memory_replay.rb:112-116`). `Lineages` says the same (`lineages.rb:140-143`).
  - **Inference (not driven):** by this code, a SIGKILL during **any** tool dispatch leaves such a
    `memory_root`, whether the tool is `bash`, a parked approval or a main-agent `ask_human`, and
    would refuse too. `messages` is evaluated before `memory`, which is why SB1 saw the message
    error first.
  - Salvage cannot help either. It treats a `turn_usage` after the last `request_sent` as proof the
    turn committed and returns `Nothing` (`session_record/salvage.rb:17-23, 60-65`).
  - **Verify this before scoping the fix.** If true, the class is "crash mid-tool", not
    "crash mid-spawn".

### 2. Recent changes

- `causal_parents: [head].compact` dates from `77af3363` ("tools: Add Subagent tool …").
- T12 `afb5e73f` (2026-09-14) changed only the body, adding `"task" => Canonical.digest(prompt)`
  (`lineage.rb:66-67`), not the citation.
- T4 `69df4d08` routed seam records to `durable_journal` and dropped the actor lifecycle's second
  journal leg (`subagent.rb:298-303`). It did not touch write order.
- `JournalTurns`' post-iteration catch-up dates from `a4c76fc4`.
- The child-level fix is `b679ed46`. The top-level reader workaround is T22's `Lineages::InFlight`
  (`ad045078`).

### 3. Why

- Per-iteration durability is a stated design: "durable BEFORE the next model call"
  (`journal_turns.rb:5-8`). The scribe writes only render-chain turns it can walk, append-only,
  refusing divergence (`scribe.rb:12-14, 165-187`).
- `b679ed46` fixed the child and nested levels on purpose. `ask_human.rb:369-371` records the belief
  that the chat level was already covered.
- T22 found the top-level gap, but its card scope was reading lineages. It took the narrow route,
  "An open file skips only an in-flight top-level spawn; any other damage refuses by path"
  (`ad045078` message), and left the resume, fork and variance loaders strict.
- **The strictness is itself a ruling.** Chunk Open decision 3 (`:294-299`): "Already-damaged
  journals are not healed … Healing history would mean a render-time pairing combinator, which the
  validator's 'reports, never repairs' stance argues against. The human's call." And
  `MessageReplay`'s doc: "a record whose edges never land anywhere in the file still refuses"
  (`message_replay.rb:37-42`).
- T3 (`04a9d40a`) made a **torn head on disk** repairable at load: `Resume#settled` projects a
  `Cancellation`, and "A torn head no longer refuses at all" (`cli/resume/mid_tool.rb:11-17`;
  T3 AC "the resumed session still repairs its head the same way", chunk `:810-813`). That repair
  applies only when the `tool_use` turn **is on disk**.

### 4. Classification

**(b).** This is a gap outside T12, T4 and T22. T22 knew it (`lineages.rb:199-214`) and did not
record it as a follow-up. The mechanism is pre-existing (`a4c76fc4` plus `77af3363`), and the
parent level was the known remainder of `b679ed46`. It is not a regression.

### 5. Constraints and open questions

- **Two fix shapes, each with a precedent.**
  - **A. Promote before citing.** Give the top-level seam and main asker a settling handle, as
    `b679ed46` did for children: `chronicle.catch_up(live)` before `Lineage#spawn` and
    `AskHuman#emit_question`. The `tool_use` turn is then on disk before anything cites it. A crash
    then leaves a torn head that T3's load-side `Cancellation` already repairs, and the file stays
    "reports, never repairs".
    - Constraints: `Scribe`'s `WrittenChain` prefix invariant and `Diverged` refusal
      (`scribe.rb:28-33, 49-114`). The later `JournalTurns` catch-up must stay idempotent; it is,
      since the append point advances per turn (`scribe.rb:69-80, 328-330`).
    - `Scribe#rewound` and `/rewind` interplay (`scribe.rb:189-212`; T3's in-flight refusal).
    - `Salvage`'s target rule would now see a written turn, which is consistent with its "atom"
      reading.
    - This also corrects `ask_human.rb:369-371`.
  - **B. Commit-time journaling.** Catch up inside or right after `commit_and_account`. This fixes
    every crash mid-tool, including the memory-root inference above. But it moves a
    durability-path fsync into the `defer_stop` shield (`agent.rb:499-523`) and changes when
    `JournalTurns` has anything to do.
- **Loader-side tolerance** (the finding's second shape) conflicts with Open decision 3 and
  `MessageReplay`'s refusal contract. It would also have to tolerate `memory_root`/`turn_usage`
  naming the unwritten turn, which T22's `InFlight` does via a `turn_usage` witness
  (`lineages.rb:238-281`). **Do not relitigate without the human.**
- **Specs pinning the current order:** `spec/lain/middleware/journal_turns_spec.rb`,
  `spec/lain/session_record/scribe_spec.rb` (incl. `:380` twin dedupe, `:395` child usage),
  `spec/lain/bench/session/lineages_spec.rb:138-256` (the whole "session still being written"
  block depends on the gap existing), `spec/lain/bench/session/loader_fixpoint_spec.rb:243-296`
  (never-landed refusals), `spec/lain/tools/ask_human_spec.rb` and `spec/lain/tools/subagent_spec.rb`
  (`b679ed46`'s depth-three examples), `spec/lain/cli/resume_spec.rb:263-275` (open session loads),
  `spec/lain/agent_spec.rb` (the `commit_and_account` atom).
- **Open (human):**
  - Fix at the writer (A or B) or tolerate at the reader?
  - If the memory-root inference holds, is the scope "any crash mid-tool"?
  - If the writer is fixed, should `Lineages::InFlight` be retired? It would become dead tolerance.

---

## F137 — a failed one-shot child never journals completion; the spawn precedes the lease (MED-HIGH, C3/E18-9/SB2)

### 1. Mechanism, re-verified

The finding is **correct**. One claim is overstated.

- `Subagent#spawn_one_shot` (`tools/subagent.rb:238-247`): `lineage.spawn` (`:243`), then
  `run_child` (`:244`), then `lineage.message` (`:245`). No `ensure`. A raise from `run_child`
  (ceiling, provider 400, lease refusal) propagates. The tool handler turns it into an error Result,
  and `Review::Critique#answer` rescues it (`review/critique.rb:183-184`).
- **The lease comes after the spawn.** `run_child` → `isolation.hold` → `Leases#hold` →
  `@backend.acquire(worker)` (`isolation/leases.rb:196-204`), all after `:243`. A refused acquire
  has already journaled a `:spawn` for a child that never existed. `Leases#hold`'s `ensure`
  surrenders only a lease it got (`:203`).
- **Retirement is completion-only.** `StatusFeed` `:spawn` → `Fleet#launched`, `:message` →
  `Fleet#completed` (`status_feed.rb:450-455`). `completed` needs `SpawnLifecycle#terminal?`
  (`status_feed/fleet.rb:66-71`), which is `@mark == STOPPED || @result`
  (`status_feed/spawn_lifecycle.rb:91-93`). `FleetWindows#observe_close` has the same gate
  (`cli/fleet_windows.rb:417-422`).
- **Overstated:** "Consolidate and lineage readers see open spawns". `Lineages` yields only
  **completed** lineages (`lineages.rb:164-180`), so a failed spawn is silently **absent**, neither
  seen nor refused. In an open file, T22's `InFlight` is what keeps it from refusing.

### 2. Recent changes

- The order spawn → run → message dates from `77af3363`. The lease moved inside `run_child` in
  `994f894d` (2026-08-27, "a spawned child runs in a leased environment"), **after** the existing
  spawn line. Nothing in that commit discusses the order.
- The completion's `"lifecycle" => STOPPED` is from the round-15 W3 lifecycle design
  (`planning/archive/chunk-qa-round15-what-nothing-retires.md:45-49, 137-175`).
- T12 `afb5e73f` changed the spawn body only. T4 `69df4d08` routed the seam journal. Neither
  touched the failure path.

### 3. Why

- Round 15 ruled on F83, the "W3 lifecycle design", on the human's explicit ruling. It superseded
  round 11's deferral and kept retirement journal-derived: "Any fix must be journal-derived"
  (`fleet.rb:24-26`; archive `:163-166`). Its scope was **finished** children. The failure path was
  never in its ACs.
- `Lineage#message`'s doc: "Written UNCONDITIONALLY … a one-shot child is done for good"
  (`lineage.rb:85-92`).
- `SpawnLifecycle`'s doc: "A 'result' key names a one-shot's completion body (only
  `Lineage#message` ever writes one, and it **always writes a finished child**)" … "whoever adds the
  next one should read this comment before assuming the inference still holds"
  (`spawn_lifecycle.rb:66-80`).
- `994f894d`'s rationale for leasing inside `run_child`: "Every one-shot dispatch runs in a leased
  environment, and the lease is taken UNCONDITIONALLY" (`subagent.rb:252-262`).
- `planning/qa/scenarios/subagents-and-backends.md:111-112` states the principle for the depth
  refusal: "A depth refusal that journals a spawn has created a child that does not exist, and every
  later fold counts it". `depth_exceeded` honours it (`subagent.rb:153, 205, 314`); the lease
  refusal does not.

### 4. Classification

**(c)**, with the lease half a **(c)** from `994f894d`. The chunk never touched either. Round 17
reported F83 as holding on the success path only, and the finding says so.

### 5. Constraints and open questions

- **Vocabulary.** `SpawnLifecycle::MARKS = [LAUNCHED, SETTLED, STOPPED]` is closed, and an unknown
  mark reads **non-terminal** and lands on `#unrecognized` (`spawn_lifecycle.rb:25-35, 57-64`).
  - A new `"failed"` mark without extending `MARKS` would silently never retire.
  - Reusing `STOPPED` plus a `"result"` carrying the error collides with the "always writes a
    finished child" reading.
  - Deciding this is a change to round 15's ruled design. **Ask.**
- **Readers of a completion:**
  - `Lineages#completions` requires `"final"` (`lineages.rb:176-180`), and `child_turns` walks it
    (`:192-196`). A lease refusal has no child head.
  - A failure completion carrying `"final"` would be **clerked by consolidate**, fed to improve,
    and read by friction (`Grader::ToolCallIndex`).
  - Decide whether failed lineages are lineages. Friction arguably wants them; consolidate
    probably does not.
- **Identity (T12 Open decision 5, chunk `:303-307`).** Identical-prompt twins share one spawn
  digest, and `Fleet#completed` drops **every** cited digest (`fleet.rb:53-60`). One twin's failure
  completion retires the shared entry while the other runs. That is accepted today for success; say
  whether it is accepted for failure.
- **Replay.** A new completion shape re-derives from its own recorded body
  (`message_replay.rb:180-187`), so there is no historical digest risk (round-15 archive verified
  this).
- **Reordering the lease before the spawn:**
  - the spawn must still precede anything a `--windows` pane or `lain watch` tails;
  - the spawn digest is the watch address (`lineage.rb:36-46`);
  - the actor path's `Supervisor#adopt` already leases first (`subagent.rb:216-222`), which is the
    precedent.
- **Spawn-before-message is load-bearing for re-entrancy.** The records ride locals across the IO
  yield (`subagent.rb:225-230`); an `ensure` must keep that.
- **Specs:** `spec/lain/status_feed/fleet_spec.rb`, `spec/lain/status_feed/spawn_lifecycle_spec.rb`,
  `spec/lain/cli/fleet_windows_spec.rb`, `spec/lain/tools/subagent/lineage_spec.rb` (T12's pinned
  bodies), `spec/lain/tools/subagent_spec.rb`, `spec/lain/bench/session/lineages_spec.rb`,
  `spec/lain/seams/one_shot_handback_spec.rb`, `spec/lain/isolation/leases_spec.rb` (`Leases#hold`'s
  surrender).
- **Shared with F135:** a crash writes nothing in an `ensure`, so F137's crash trigger is F135's to
  fix, not F137's.

---

## F166 (consolidate/improve half) — passes re-send released secret bytes, defaulting to Anthropic (MEDIUM, M2)

### 1. Mechanism, re-verified

- **Default provider.** `JournalPassFlags.declare` sets `--provider` `default: "anthropic"`
  (`exe/lain:1130-1141`) for both `consolidate` and `improve` (`:1143-1149`).
- **What reaches the prompt.**
  - `Consolidation::Scaffold#render_turn` summarizes only `text` blocks and `called <name>` for
    `tool_use` (`consolidation.rb:163-175`). `tool_result` blocks are dropped, so a released region
    reaches the clerk **only where the child echoed it in its own text**, as the fork's child did.
  - `CLI::Improve`'s scaffold has the same `summarize` (`cli/improve.rb:99-109`) over parent `turn`
    records plus lineage child turns.
- Neither pass re-runs region detection over its scaffold. The detached guard masks what the
  **clerk** reads with `read_file` (`consolidation.rb:15-23`), not what the scaffold carries.

### 2. Recent changes

- T22 `ad045078` put child turns into both scaffolds by finding lineages. Before it, consolidate
  had no lineages, and improve could not see child work.
- The anthropic default is old (`c0511c3f` for improve, the `146d9879` mount for consolidate).

### 3. Why

- The clerk-guard design covers writes and reads **by the clerk** ("THE GUARD DOES NOT COME FREE",
  `consolidation.rb:15-23`).
- The release was the human's, for the source session's model. No record ties a release to
  re-export.

### 4. Classification

**(b)**: exposed by T22's reach, on a pre-existing default and scaffold. The boundary ruling belongs
to the secret researcher.

### 5. Constraints and open questions

- **Keep:** `Provider::Unreachable` for dry runs (`cli/consolidate.rb:20-24`, `cli/improve.rb:117-129`).
- **Keep:** `ToolGuard.detached`'s "nobody at a surface" fail-closed masking (`cli/tool_guard.rb:153-171`).
- **Open (secret researcher and human):**
  - mask the scaffold through `Sensitivity::Regions`;
  - refuse a remote provider over a session with released regions;
  - or drop the `anthropic` default for journal passes, to match `LAIN_*` env or the recorded
    header.

---

## F167 — the hybrid sweep arm ≈ bm25 (MEDIUM, M3)

### 1. Mechanism, re-verified

The finding is **correct, with one nuance**.

- `Memory::Hybrid#ranked` fuses each arm's **unbounded** search (`memory/hybrid.rb:88-93`).
  `hit_for` sums `1/(RRF_K + rank)` over the sources present (`:100-105`), with `RRF_K = 60`
  (`:30`).
- `Memory::Vector#search` returns every **positive-cosine** item (`memory/vector.rb:51-56, 87-94`).
  That is "all 32" on the committed embeddings, but it is not by construction.
- A bm25 noise hit is therefore also in the vector list and earns two contributions, where a
  vector-only gold item earns one. At `RRF_K = 60` the rank differences are tiny, so presence in
  both arms dominates.

### 2. Recent changes

- `ef40a5a2` (2026-07-15, "memory: Add Hybrid search arm …") and the sweep `1e6701d0`.
- Only comment sweeps since (`8e3f4b38`, `2071f088`). Untouched by the chunk.

### 3. Why

- The design is **rank-only, a paper constant, never corpus-fit**: "a value FIT to a corpus would
  make one run's ranking depend on which corpus tuned it" (`hybrid.rb:22-29`).
- **The result was known and reported at landing.** `ROADMAP.md:458-460`: "bm25 = hybrid = manifest
  .333 — **hybrid did not beat vector** on this corpus (RRF dilution when one arm dominates),
  reported honestly rather than gamed; the corpus/fusion question is a follow-up, not a re-run."
- `planning/specs/chunk-spine-agents-sweep-nvim.md:885` records the T20 landing ("the close-out
  hybrid≥ check is Joel's to eyeball").
- Panel amendment `:151-153`: "hybrid earns its place" was dropped from unit AC "(it tests the
  fixture, not the code; keeping it as a unit AC incentivizes corpus-gaming)".
- Escalation `:925`: "flip the hybrid≥ assertion — stop; corpus or fusion needs rework, not a
  loosened AC".

### 4. Classification

**(d)/(c).** Pre-existing, with a follow-up owed since 2026-07-15. The finding's new contribution is
the mechanism: double-counting bm25 noise through an exhaustive vector list, rather than generic
"dilution".

### 5. Constraints and open questions

- **Do not tune `RRF_K` to the corpus** (`hybrid.rb:26-29`).
- **Do not add a hybrid ≥ unit assertion**, per the panel amendment. `spec/lain/bench/sweep_spec.rb:12-16`
  says so.
- `spec/lain/memory/hybrid_spec.rb:54-66` pins "the doc both arms agree is second above either
  arm's own top pick", which is **exactly the property** that produces F167. Bounding or weighting
  will touch it.
- The sweep report must stay byte-deterministic (`sweep_spec.rb`, scenario §6).
- **Open (human):** is this a fusion rework (a bounded candidate list, score-weighted fusion) or a
  corpus change? Either changes the committed ranking that rounds 14–18 recorded as stable.

---

## F168 — `memory_write` `description`/`id` unbounded (MEDIUM, M4)

### 1. Mechanism, re-verified

The finding is **correct**.

- `MemoryWrite#too_large` measures `input.body.bytesize` only (`tools/memory_write.rb:85-90`).
- `Memory::Item` validates only a non-blank id and single-line id and description
  (`memory/item.rb:39-47`).
- The manifest renders into the workspace reminder on every request via
  `Memory::Manifest.new(index).to_reminder` (`session.rb:544`).
- "`/rewind` does not remove a memory item": `/rewind` and `Agent#rewind` never touch the recorder
  (no reference in `cli/command/rewind.rb` or `agent.rb`). This matches, though it was not driven.

### 2. Recent changes

- The body bound came with `036e6ec0` (2026-08-18, "tools: refuse a whole artifact too big to read,
  before reading it"). Untouched by the chunk.
- T24 (`4cf30b98`) makes an over-window prompt a refusal, which is why one huge description now
  wedges every later request rather than being silently truncated.

### 3. Why

- The bound is paired with `memory_read` so a write cannot store what a read refuses: "A ceiling on
  the read ALONE would be an asymmetry with no way out" (`memory_write.rb:14-21`; `036e6ec0`
  message).
- The **manifest** was never the thing being protected, so id and description were out of that
  card's reason.
- CLAUDE.md: `Tool::Input` validations "check shape, not safety".

### 4. Classification

**(c)**, with its consequence sharpened by T24.

### 5. Constraints and open questions

- **Refuse by name with narrower moves** (`Tool::Bounds::Artifact#refusal`, `memory_write.rb:26-33`).
- **Refuse before `Memory::Item`,** so nothing is hashed or stored (`:82-84`).
- A length bound can live in the tool or in `Item`'s declaration. `Item` is also rebuilt by
  `MemoryReplay#writes` (`memory_replay.rb:49-55`), so an `Item`-level bound would make an
  **already-recorded** oversized write refuse on resume. Keep it at the tool.
- **Specs:** `spec/lain/tools/memory_write_spec.rb` (the exact 256 KiB boundary pair) and
  `spec/lain/memory/item_spec.rb`.
- **Open:** what bound? It could be per-line (the manifest line) or per-manifest total. The fork
  proposes protecting the manifest.

---

## F169 — `lain watch` never concludes on a crashed session (MEDIUM, SB3)

### 1. Mechanism, re-verified

The finding is **correct**.

- `Watch#follow` stops only when `closed_by?` sees `session_closed` (`cli/watch.rb:77-87`).
  `Tail#each` is "Infinite by design" (`:156-157`).
- `announce_wait` speaks only for an empty file (`:67-71`). `conclude`'s no-match line runs only
  after `follow` returns (`:95-100`), so a typo against a crashed file hangs silently.
- A matched watch of a **completed** spawn also runs until `session_closed`, which is the class
  doc's stated stop (`:5-9`).
- The writer pid is in the filename. `Resume::WRITER_PID` and `#alive?` already use it
  (`cli/resume.rb:317-350`).

### 2. Recent changes

- T26 `c3ccaa39` (F119) changed only `conclude(path)`, so the no-match names the file
  (`watch.rb:95-100`), and bare-hex selectors. It also added F124's writer-pid liveness check to
  **Resume**, not to Watch.
- Established by `0250afc7` (2026-07-23). The zero-byte refusal came with `e7b50a55`.
- `79face26` added the exe's `rescue Interrupt → exit 0` "Ctrl-C ends a tail of a SIGKILL'd
  (never-closed) session -- clean exit, no backtrace" (`exe/lain:87-96`).

### 3. Why

- The stop rule is a deliberate read-only-tail design: "stops at the session_closed record"
  (`watch.rb:5-12`).
- **The crashed case was known in July and answered with Ctrl-C, not a conclusion** (`79face26`).
- `e7b50a55` handled only the zero-byte "nothing is writing it" case, because "the session_closed
  record that ends #follow can never arrive" (`watch.rb:135-146`). A non-empty crashed file has the
  same property and was never handled.
- T4's shutdown fix (`69df4d08`; Exec log `:394-395`, "session_closed is always written") narrows
  the trigger to SIGKILL and crashes.
- FleetWindows by design never kills a window; "a watch that exits cleanly still closes its own
  window" (`fleet_windows.rb:7-10, 44-51`).

### 4. Classification

**(c)**, a known limitation answered by Ctrl-C since `79face26`. Not touched by T26 beyond wording.

### 5. Constraints and open questions

- **Read-only by construction** (`watch.rb:9-12`; spec "holds no Store, no provider, and no
  Channel"). A liveness probe must not write.
- **Two liveness idioms disagree on EPERM.** `Resume#alive?` treats EPERM as **dead** "rather than
  probing someone else's process" (`cli/resume.rb:336-349`). `LeaseLock::ProcessTable#exists?`
  treats EPERM as **live** and adds a start-time check against pid reuse
  (`isolation/lease_lock.rb:108-160`). Pick one, and do not add a third.
- **A live empty file is legitimately tailed** (`watch.rb:60-66`). Don't conclude on "no writer" for
  an empty `--session` without the same wording.
- Concluding at the watched lineage's **completion** would change the `--windows` pane lifecycle
  (panes close on clean exit, `fleet_windows.rb:44-51`) and the `[done]` title mark. This is a UX
  ruling.
- **Specs:** `spec/lain/cli/watch_spec.rb` (`:99` exits 0 on session_closed; `:213-231` tailing a
  live file; `:333-346` no-match; `:394-415` zero-byte), `spec/lain/cli/fleet_windows_spec.rb`. No spec
  pins the exe's `rescue Interrupt` arm (grep of `spec/lain/cli_spec.rb` finds none).
- **Open:** conclude on a dead writer only, or also at the watched lineage's terminal record? And
  what exit status does "writer died, spawn never completed" get?

---

## F170 — a malformed `.lain/services.rb` kills every chat with a backtrace (MEDIUM, SB4)

### 1. Mechanism, re-verified

The finding is **correct and slightly wider** than filed.

- `Services::Builder.build` is `instance_eval(source, path, 1)` with no rescue
  (`isolation/services/builder.rb:36-40`). `DslCatalog.load` calls it bare (`dsl_catalog.rb:34-37`).
- Unknown verbs and the retired `redis` verb raise `Lain::Error` (`builder.rb:60-77`). A wrong
  keyword raises `ArgumentError` out of `Services::Compose.new(**)`/`Postgres.new(**)` (`:48-49`).
  A syntax error raises `SyntaxError` (a `ScriptError`, not a `StandardError`).
- `IsolationBackend#backend` is `with_compose(with_databases(journalled(concrete)))` for **every**
  backend, `none` included (`cli/isolation_backend.rb:135, 194-205`). The exe's `chat` rescues only
  `Lain::Error` (`exe/lain:1095-1102`).
- **Sibling, not driven:** `Summarizer::Catalog.load` rides the same `DslCatalog.load`, and
  `Backend#summary_oracle` loads it (`cli/backend.rb:586-589`). A broken `.lain/summarizers.rb` very
  likely has the same shape.

### 2. Recent changes

- `DslCatalog` was extracted in `cdeff0c4`. Services loading for all backends came with `324cbafc`,
  and the one-backend injection with `994f894d`. Redis retirement was `3adfabfe`, and `e1ecc9df`
  handled paths.
- Untouched by the chunk.

### 3. Why

- "The file is the user's OWN Ruby, `instance_eval`'d with no sandbox -- shape, not safety"
  (`isolation/services.rb:12-15`).
- "The keywords a call takes are exactly the value object's, so the DSL and the declaration cannot
  drift" (`builder.rb:10-12`). The **ArgumentError is the drift guard**, just not translated.
- "A BAD FLAG IS REFUSED HERE, NOT AT THE FIRST ACQUIRE" (`isolation_backend.rb:24-30`) is why
  loading at launch is deliberate.
- For the summarizer sibling: "It stays loud on purpose -- rescuing inside the catalog would hide a
  broken summarizer forever" (`spec/lain/summarizer/builder_spec.rb:234-238`).

### 4. Classification

**(c).**

### 5. Constraints and open questions

- **Loud, not swallowed.** Translate to a `Lain::Error` naming the path and line. Never rescue into
  an empty catalog.
- **Keep:** launch-time refusal. **Keep:** decoration by need.
- `spec/lain/summarizer/builder_spec.rb:229-232` pins `raise_error(ArgumentError, /bodyless…/)` out
  of `load_catalog`. A `DslCatalog.load`-level translation flips it, so do it per-Builder or update
  that pin deliberately.
- `spec/lain/isolation/services_spec.rb:67-100` pins the existing named refusals.
- **Open:** should `--isolation none` read `.lain/services.rb` at all? The fork's "related
  observation" says `with_compose` decorates Null deliberately (`isolation_backend.rb:13-17`). That
  is a ruling, not this defect.

---

## F177 — `--cheap-model nonesuch:1b` is accepted (LOW)

### 1. Mechanism, re-verified

The finding is **correct**.

- `LiveArms.default_router` → `refuse_unroutable!` refuses only nil or "equal to `--model`"
  (`bench/live_arms.rb:119-159`).
- "a --cheap-model naming a model this backend can serve" (`:150`) is advice in a refusal sentence.
- `CHEAP_MODEL`'s comment claims "a roster whose backend cannot serve this id is REFUSED at
  assembly" (`:60-63`), but the check is lexical: `ROUTABLE_MODEL = /\Aclaude-/` (`:66-71`).

### 2. Recent changes

T16 `13b5e71c` (2026-09-14).

### 3. Why

T16's design: "Add `--cheap-model ID`, read literally"; refuse unset on non-Claude, and refuse equal
(chunk `:1855-1861`). Its three ACs are exactly those. No servability AC. Escalation: "must not add"
a per-provider sibling table (`:1888-1889`; `live_arms.rb:59-63`).

### 4. Classification

**(b)**, outside T16's ACs. The `:60-63` comment over-claims.

### 5. Constraints and open questions

- No per-provider table.
- Refuse before spend, which is the whole point of `refuse_unroutable!` (`:135-139`).
- A servability probe (ollama `/api/show`, which `Provider::Ollama` already has, `ollama.rb:279`,
  `ollama/transport.rb:122`) must not run under specs' offline posture, and must not exist for
  Anthropic.
- **Specs:** `spec/lain/bench/live_arms_spec.rb`, `spec/lain/bench/arms_report_spec.rb`,
  `spec/lain/cli_spec.rb`.

---

## F178 — Ctrl-C of `bench arms` prints a raw `Interrupt`, and no partial report (LOW)

### 1. Mechanism, re-verified

- `exe/lain` `arms` wraps `Bench::CLI#arms_report` in `render`, which rescues only `Lain::Error`
  (`exe/lain:81-85, 636-647`).
- `arms_report` returns the report String only at the end (`bench/cli.rb:206-220`), so nothing
  partial exists to print.
- Leases: `Leases#hold`'s `ensure` surrenders (`isolation/leases.rb:196-204`), but an `Interrupt`
  raised through the Async reactor may not unwind every fiber's `ensure`. The "3 locked leases" were
  not traced in code here.

### 2. Recent changes

T16 `13b5e71c` touched `arms` flags only. Untouched otherwise.

### 3. Why

- The precedent for Interrupt is `exit_status` for `watch` (`exe/lain:87-96`, `79face26`), not
  applied to report commands.
- F164 (E18-6) is the same raw-`Interrupt` class in epic gates.

### 4. Classification

**(c).**

### 5. Constraints and open questions

- Only the frontend prints (output discipline). A partial report needs `arms_report` to expose the
  graded-so-far fold rather than print.
- **Open:** is a partial comparison table meaningful? The report compares arms over equal task sets.

---

## F195 — a child's masked-read release says `requester: "agent"` (LOW, M5)

### 1. Mechanism, re-verified

The finding is **correct**.

- `ToolGuard.child_stack` passes `requester:` only into the Gate's `Asking` policy
  (`cli/tool_guard.rb:126-129`).
- `RedactSecretReads` is built from `read_kwargs` (`:206-210`) and adjudicates with
  `carried.fetch(:context)` (`middleware/redact_secret_reads.rb:299`).
- `Approval::Queue#requester_for` falls back to the session default `"agent"`
  (`approval/queue.rb:201, 277-279`).

### 2. Recent changes

- `requester:` on the child stack: `3ab0c175` (2026-09-14, pre-chunk).
- T15 `0cf8d2f1` normalised `Asking`. `requester_for` dates from `dc322485` (2026-08-18).

### 3. Why

`requester_for`'s doc: "ONE queue serves the whole fleet … The CALL says so instead, through the
context the policy seam already threads" (`queue.rb:269-276`). The read guard never threads it.
"One ledger per run is the board's invariant" (`tool_guard.rb:107-110`).

### 4. Classification

**(c)/(b).**

### 5. Constraints

- **Keep:** the one ledger and one queue (`tool_guard.rb:107-110`).
- Thread `requester` through the context, as `Asking#requested` does. Don't add a second queue.

---

## F196 — `improvements --project <no match>` says "none recorded yet"; a torn mid-file line is dropped (LOW, M6/M7)

### 1. Mechanism, re-verified

The finding is **correct**.

- `CLI::Improvements#empty_render` returns "no improvements recorded yet" whenever the **scoped**
  set is empty (`cli/improvements.rb:120-128`).
- `read` uses `Journal.records`, which skips unparseable lines (`:110-114`; `journal.rb:113-126`).

### 2. Recent changes

T26 `c3ccaa39` (F120) added only the kind branch (`:127`).

### 3. Why

- The comment is deliberate: "An empty STORE (or an empty PROJECT scope) says so plainly".
- T26's F120 item names `--kind` only (chunk `:2615-2616`).
- The skip contract: the chunk Grounding says it "has **no production caller**" and "an unparseable
  line is always damage" (`:131-133`). "Code won" on that disagreement (`:249`). T5 retired it for
  the sign-off folds, and T22 for lineages (`lineages.rb:91-113`). Improvements were in neither.

### 4. Classification

**(b).**

### 5. Constraints

- Tolerate a torn **last** line, as the killed-writer rule does (`lineages.rb:91-113`, T5's
  `SessionJournals`).
- **Spec:** `spec/lain/cli/improvements_spec.rb`.

---

## F197 — 16 near-duplicate notes; the missing-embeddings refusal misnames its file (LOW, M8/M9)

### 1. Mechanism

- `Improvement::Sink#append` appends with no key (`improvement.rb:122-150`).
- `Sweep#existing!` raises `MissingCorpus, "no sweep corpus file at #{path}"` for either path
  (`bench/sweep.rb:229-237`).
- `lain bench sweep` exposes only `-k` (`exe/lain:565-567`).

### 2–4. History and classification

- Sweep: `1e6701d0`, `66db99b3`. Improvement sink: `c0511c3f`. Untouched by the chunk.
- **(c).** The scenario itself asks whether the refusal is "a feature gap worth filing"
  (`memory-and-dogfood.md:240-242`).

### 5. Constraints

- Improvement notes carry `evidence_digests`, so a dedupe key must not drop evidence.
- **Open:** is dedupe the sink's job or the improver persona's?

---

## F198 — gc keeps a clean crashed lease 7 days; the refusal omits the worker id; move-aside is unjournaled (LOW, SB7)

### 1. Mechanism, re-verified

- **Retention.** `Gc#holding` reads a dead-pid lock as not held (`isolation/gc.rb:287-292`), so
  `settle` → `moved?` false → `unmoved` → "nothing has landed since it was cut; retained until …"
  (`:298-325`).
- **Move-aside.** `Leftover#move_aside` relocates with
  `LeaseLock::Retained.at(entry.lock.aged_from(@clock.call))` (`worktree/leftover.rb:49-56`). A
  live-pid lock carries no retention stamp, so the clock restarts at the move. `Leftover` holds no
  journal.
- **Refusal.** `Refused.from_git` (`isolation/worktree.rb:86`) names no worker.

### 2. Recent changes

- **T10 `4b0778f8`** (2026-09-14) introduced the unmoved-checkout rule: "Gc reaped a fresh checkout
  still at its cut point as landed on main; a checkout whose reflog never moved, or cannot be read,
  is kept for retain_days".
- **Before T10, a clean crashed checkout at trunk's tip was reaped immediately as "landed".**

### 3. Why

- T10's AC2, "a fresh checkout at its cut point is not reaped as landed", is chunk `:1444-1447`.
  It was motivated by F116, a live **unlocked** landing checkout reaped mid-cockpit. T19 later locks
  that checkout (`51b0be4d`).
- Gc's doc: "what gc cannot judge it keeps, which `retain_days` still bounds" (`gc.rb:309-314`).

### 4. Classification

- The retention bullet is **(a) by design**: T10's deliberate conservative trade, which now also
  catches dead-lock checkouts.
- The worker-id and journaling bullets are **(c)**.

### 5. Constraints and open questions

- **Never reap a live or unlocked landing checkout** (F116; `gc_spec.rb` "calls work reachable from
  main landed" must still reap a moved checkout).
- **Use `LeaseLock::ProcessTable#verdict`'s** conservative rule (an unreadable start time reads as
  live, `lease_lock.rb:108-113`).
- Scrub `GIT_INDEX_FILE` in fixtures (CLAUDE.md trap).
- **Open:** may a lock whose verdict is `:dead` on a clean, unmoved checkout be reaped at once,
  given T19 now locks the landing checkout?

---

## Cross-finding

### Shared root causes

1. **Records written during a tool dispatch cite a turn the file does not yet hold** (the shared
   mechanism above). Round 14's F79 fixed it for children (`b679ed46`), T22 tolerated it in one
   reader (`Lineages::InFlight`), and the top-level writer was never fixed.
   - Covers **F135** directly.
   - Covers F137's crash trigger.
   - By code reading, and not driven, extends to any SIGKILL mid-tool, through `memory_root`
     (`memory_replay.rb:112-116`) and a main-agent `ask_human`, whose `ask_human.rb:369-371`
     comment is wrong for a crash.
   - **Also feeds F169:** such a crash leaves no `session_closed`, so every watch pane of that
     session hangs.
2. **The one-shot lifecycle has no failure arm.** `spawn_one_shot` has no `ensure`, the vocabulary
   is closed at launched/settled/stopped, and the lease is taken after the spawn record.
   - Covers **F137** (fleet, `[done]`, watch).
   - Covers the "child that never existed" record.
   - Interacts with **F134/F166**: whether failed lineages are consolidated or improved.
3. **The offline journal passes were built in-process and never given a durable destination**
   (`Channel::Null` defaults in `Consolidation` and `CLI::Improve`, with the M5 follow-up owed since
   July). T22 made them reachable.
   - Covers **F134**.
   - Covers the refusal-visibility half of **F166**.
   - Covers **F196**'s silent skip, which is the same "read whole or refuse" discipline T5 and T22
     applied elsewhere.
4. **Only `Lain::Error` is mapped at the exe.** Non-`Lain::Error` raises from user-authored DSL files
   (F170), and `Interrupt` from report commands (F178, and F164 in epic), escape as backtraces.
   `exit_status` for `watch` is the one precedent.
5. **No liveness question is asked of a session's writer outside `Resume`.** This covers F169, and
   F198's dead-lock retention asks the lease-lock variant. Two idioms exist, disagreeing on EPERM.

### Which fixes cover which findings

| fix | covers | notes |
|---|---|---|
| Settle the top-level record before any citation (a `b679ed46`-style handle on the chat's seam and main asker), or journal the `tool_use` turn at commit | F135; F137's crash row; by inference every crash mid-tool | A crash then leaves a torn head that T3's load-side `Cancellation` already repairs. Consider retiring `Lineages::InFlight`. |
| `ensure`-written terminal completion plus lease-before-spawn in `spawn_one_shot` | F137 (error, ceiling, 400, lease refusal) | Needs a vocabulary ruling (`SpawnLifecycle::MARKS`), and a ruling on whether failed lineages feed consolidate, improve and friction. |
| Watch concludes on a dead writer, with one shared liveness idiom | F169; the SB3 `lain sessions` "open" note; likely a sibling of F198 | Must stay read-only. |
| A durable destination for journal passes (session file with scribed clerk turns, or a new store) plus a real journal | F134; F166's refusal visibility | Needs the human's scope ruling first (chain-scoped vs project memory). |
| Translate DSL load errors to a named `Lain::Error` | F170 and, by the shared loader, `.lain/summarizers.rb` | Mind `summarizer/builder_spec.rb:229-232`. |
| Rescue `Interrupt` in report commands | F178 (and F164's class) | A partial report is a separate question. |

### Decisions not to relitigate without the human

- **Open decision 3** (heal-at-reader is "the human's call").
- **Open decision 5** (identical twins share one spawn digest).
- **Round 15's W3 lifecycle ruling** (journal-derived retirement over a closed vocabulary).
- **The M6 panel amendment** (no hybrid≥ unit AC, no corpus-fit `RRF_K`).
- **"FRESH-ROOT IS NOT NEGOTIABLE"** for the clerk.
- **T10's "a checkout at its cut point has not landed".**
- **T16's "no per-provider cheap-model table".**
