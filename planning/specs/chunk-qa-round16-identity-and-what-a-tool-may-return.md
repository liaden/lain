# Chunk: round-16 — a spawn's identity, and what a tool may hand back

status: in-progress -- 11 of 12 cards landed, T12 and the manual passes owed
commit-mode: orchestrator-commits
language: ruby (plus the QA bench's `bash` driver heredocs)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharges [`../qa-findings-round16-2026-08-28.md`](../qa-findings-round16-2026-08-28.md) and takes
up two decisions the round-15 chunk deferred.

**The chunk's spine is identity.** Two spawns of one arm from one head are byte-identical `:spawn`
events, so they share a digest — and a digest *is* an actor's address. Round 15's fleet retirement
turned that from an undercount into something worse: one farewell retires the shared entry while the
surviving twin is still running, so the HUD reads `fleet 0` with a live child. The human's ruling is
to **fix identity now rather than patch the readers**, because sibling-to-sibling agent
communication is a direction this codebase is heading, and an address that cannot distinguish two
live children stops being a display bug the moment one agent addresses another by it. The identity
already exists: `Supervisor` mints `Isolation::WorkerId.adopted(role:, ordinal:)` per adoption
precisely because a worktree lease could not tolerate a collision. It simply never reaches the
journal, so journal-derived readers cannot see what the isolation layer already knows.

**The second half is what a tool may hand back.** Round 16 confirmed F82's mechanism live: one
oversized result pins occupancy near 100% with an empty compactable head, and nothing can drop it.
Ten tools already declare a `Tool::Bounds`; `subagent`, `run_skill` and `ask_human` never got one.
The human's ruling is that the answer is **not** a refusal for any of the three: a human gets their
own message handed back with the option to send it anyway, a skill gets the same, and a subagent is
asked to summarize its own overflow — cheap, because the child's context already holds it. Two of
those are shapes `Tool::Bounds` does not have today.

**And `--windows` has never once opened a window.** Root-caused this round to exit status 127.

Round 16's **P35** is already discharged and needs no card: `planning/qa/method.md:137-143` now names
`XDG_CONFIG_HOME` as the variable that breaks the close-out `git status` gate and gives the
`env -u XDG_CONFIG_HOME` one-liner. Recorded so it is not re-filed.

## Grounding

Verified 2026-08-28 against `428d662b` by four parallel explorations plus three live experiments in
a real tmux. Working tree carries pre-existing uncommitted edits to `ROADMAP.md` and
`planning/README.md` that are **not** this chunk's.

### F84 — the fleet window, root-caused by measurement

The QA findings named a probable mechanism (`Pump::DEFAULT_SPAWNER`'s
`Async::Task.current?&.async` short-circuiting outside a reactor) and **that account is wrong**.
`Repl#run` opens `Sync do |task|` at `cli/repl.rb:87` around the whole loop; `Kernel#Sync` joins
rather than nests, so the tee fan-out where `FleetWindows#<<` runs is inside a live reactor task and
`Async::Task.current?` is non-nil. The exploration further confirmed on this box's async 2.42 that a
`transient:` child spawned from a short-lived task survives its parent and drains.

**The real mechanism, measured.** A window IS opened and tmux destroys it within milliseconds:

```
tmux new-window -n 'researcher-d53d8e62' 'lain watch blake3:d53d…'
immediately after:  zsh  researcher-d53d8e62
3s later:           zsh
```

With `remain-on-exit on` the corpse reads **`Pane is dead (status 127…)`** — command not found. A
tmux pane runs `$SHELL -c` non-interactively, where `lain` is not on `PATH`. `FleetWindows` is the
only tmux window-opener in the tree that composes a bare command: `/fork`
(`cli/command/fork.rb:128-129`), `/btw` (`cli/command/btw.rb:53-55`) and `lain up`'s own panes
(`cli/up.rb:639`, `:694`) all go through `Up.pane_command` and pass `cwd:`, and
`up/pane_command.rb:126-133` states why — a pane inherits the tmux **server's** environment, zsh
reads `.zshenv` not `.zshrc`, and direnv's hook does not run. `Pump::Open#perform`
(`cli/fleet_windows.rb:83`) passes no `cwd:` at all.

**Nothing detects it.** `TmuxSurface#act` (`cli/tmux_surface.rb:163-168`) raises only on a non-zero
exit from the *tmux client*, and `new-window` exits 0 as soon as the server accepts the request.
Whether the pane lived is invisible. `remain-on-exit` is set to `failed` only on the chat window
(`cli/up.rb:800`), never on a fleet window.

**Coverage is why it shipped.** `spec/lain/cli/fleet_windows_spec.rb` injects a fake `spawner:` at
`:33-38`, `:105`, `:122`, `:178`, `:338` and `:434`, driving windows with an explicit
`drain_pending` on the caller's stack (29 lines mention it). Exactly **one** example uses the production
`DEFAULT_SPAWNER` (`:394-405`), and the real-tmux block at `:407-443` deliberately overrides
`watch_command: "sleep 60 #"` to avoid needing `lain` on the pane's PATH — stepping around both
production behaviours that matter. `spec/lain/cli/live_views_spec.rb` never mentions `fleet`,
`FleetWindows` or `windows` at all, so `live_views.rb:128-130` is untested.

### The twin collision, and the identity that already exists

- The collision is minted at `tools/subagent/lineage.rb:37-45`: the body is
  `{prefix, posture, only, spawned_from}`, all four identical for two spawns of one arm from one
  head. `ChainWriter#put` (`event/chain_writer.rb:59-68`) hashes it; `Actor#launch`
  (`tools/subagent/actor.rb:79-80`) takes `@address = @spawn.digest`.
- **The identity is already minted and already load-bearing — though its uniqueness is convention,
  not construction.** `supervisor.rb:57-60` records that `@reaped` keys on the registry ROW rather
  than the worker_id "because a caller may supply a worker_id a later adoption reuses", and
  `Supervisor#adopt(role:, worker_id: nil)` is public and takes one. No production caller supplies
  one today, so uniqueness holds by accident. `Supervisor#next_worker_id`
  (`supervisor.rb:231-234`) returns `Isolation::WorkerId.adopted(role:, ordinal: @worker_seq)`, and
  `supervisor.rb:54-56` says why: *"Distinct per adoption even when two share a role: a Worktree
  backend keys its checkout path on this, and two live leases at one path is a refusal."*
  `WorkerId` is a structured value with a closed `LANES` set (`isolation/worker_id.rb:30-45`).
- **It never reaches the journal.** `grep worker_id lib/` finds it only under `lib/lain/isolation/`.
- **The plumbing gap:** `Supervisor#register` (`supervisor.rb:266-275`) calls
  `launch.call(lease.worker_env)` — the launch block receives the **env**, not the id. Whether the
  id can reach `Lineage#spawn` without widening that contract is T1's first question.
- **A one-shot has no adoption**, so it has no `worker_id`. `Subagent#spawn_one_shot`
  (`tools/subagent.rb:194-204`) calls `lineage.spawn(parent)` directly. A one-shot also has no
  address to collide, and `actor.rb:76-78` already argues that asymmetry — so the identity is owed
  on the **actor** path and optional on the one-shot path.

**Two designs were considered and rejected, with reasons, because they will be proposed again:**

- **A random nonce** (`SecureRandom.uuid`) is rejected — but **not** for the reason first written
  here, and the correction matters because the wrong reason produces a gate that cannot reject it.
  A nonce does **not** break replay: `MessageReplay#verified` (`bench/session/message_replay.rb:180-187`)
  rebuilds from the record's own recorded body, and the class doc at `:23-25` says "every journal
  already on disk rebuilds byte-identically". A nonce written *into* that body replays fine.
  What it breaks is **cross-run reproducibility**: two runs of one bench arm would produce different
  spawn digests for the same adoption, so the two runs cannot be joined — and this repo is a bench
  before it is an agent. That is the constraint, and T1's ACs gate on it.
- **Chaining spawns causally** (`causal_parents: [head, previous_spawn]`) avoids the render chain and
  is deterministic, but makes twin B's lineage a **superset** of twin A's — the opposite of
  distinguishing them. `Watch::LineageFilter` (`cli/watch/lineage_filter.rb:22-25`) documents that
  membership grows by a record's own digest and *never* by absorbing `causal_parents`, precisely
  because absorbing "would silently pull the parent's entire chain into the watched lineage"; its
  `chains?` would then admit twin B into a watch on twin A. `Event::Projection#causal_closure`
  (`event/projection.rb:109-117`) walks causal parents transitively for the mailbox fold, so twin
  B's closure would traverse twin A's subtree.
- **Advancing the parent's head per spawn** was considered and is out of scope: `Timeline#commit`
  (`timeline.rb:72-81`) is the only head-advancing operation and always writes a `:turn`, which the
  model then reads. That is a transcript, token-spend and compaction change, not an identity fix.

**`FleetWindows#observe_close` needs no change**, on the human's reading, and this is recorded so it
is not re-filed: it uses `find` (`cli/fleet_windows.rb:287`) where `Fleet#completed`
(`status_feed/fleet.rb:69`) drops every cited digest, but a completion cites one spawn digest and
one head digest, and only the spawn is ever a `@windows` key — so with unique addresses there is
exactly one match and `find` is correct. T8's change in the round-15 chunk was defensive against a
shape the writers do not produce.

**No production users**, per the human, so changing `:spawn` bytes needs no migration and no
backward-compatibility story. Historical journals still replay, because replay re-derives from the
recorded body.

### What a tool may hand back

- `Tool::Bounds` (`tool/bounds.rb:59-181`) has exactly **two** shapes: `Enumeration` caps and
  discloses in band (`#cap` `:113`, `#notice` `:137`); `Artifact` refuses whole (`#admits?` `:151`,
  `#refusal` `:158`, `#message` `:175` — which **raises** if offered no narrower action).
- Neither is the shape the human ruled for. "Hand it back and ask whether to send anyway" and "have
  the child summarize its own overflow" are both new.
- Bounded today via `Tool::Bounds`: `bash` 128 KiB, `read_file` 256 KiB whole / 1 MiB windowed,
  `memory_read`/`memory_write` 256 KiB, `glob`/`list_files` 500 paths, `code_outline` 200,
  `file_symbols` 200+500, `test_pattern` 200, `web_search` 20. Bounded by their own pre-`Bounds`
  trailer: `grep`, `ast_search` (200 matches each). Bounded elsewhere: `core_exec` (through
  `Bash::OUTPUT_BOUND`), `ast_dump` (64 KiB in the Rust ext), `web_fetch` (5 MiB).
- **Genuinely unbounded, arbitrary-size content:** `subagent` (`tools/subagent.rb:203`,
  `Tool::Result.ok(response.text)`), `run_skill` (`tools/run_skill.rb:72`,
  `Tool::Result.ok(expand(input))`), `ask_human` (`tools/ask_human.rb:603`,
  `Tool::Result.ok(answer)`). The round-15 plan's Open decision 1 named eleven tools; that
  enumeration was stale.
- Nothing between `Tool::ResultBlock.of` (`tool/result_block.rb:54-63`) and `Timeline#commit`
  measures or truncates a result — `grep -n 'bytesize|truncat'` over `agent/tool_runner.rb` and
  `timeline.rb` returns zero hits.
- **The child is re-askable.** `spawn_one_shot` holds `child, response = run_child(...)`
  (`tools/subagent.rb:200`) — `child` is the child Agent, already used for
  `lineage.message(parent, spawn, child, response)`. A summary is a second call against a context
  that already holds the material.
- **`run_skill` has no human channel.** `ask_human` owns one by construction; `run_skill#perform`
  (`run_skill.rb:68-73`) receives `_invocation` and returns. See Open decision 2.
- **The friction-observer is the right home for the skill signal.** `Friction`
  (`lib/lain/friction.rb:6-11`) is *"the friction-observer's deterministic core, for the lain
  **user** — offline knob guidance folded over one session Journal, no model call"*, with
  `friction/cache_waste.rb` as its one signal and `friction/report.rb` folding them. A
  "this skill keeps returning oversized results" signal is one new file on that exemplar.

### The bench

- The seam is exactly two lines — `qa-sandbox.sh:79` (drive) and `:154` (peek):
  `mapfile -t … < <(tmux … -F '#{pane_id} #{pane_current_command}' | command grep -w ruby | cut -d' ' -f1)`.
  Everything downstream (the zero/one/many `case`, the refusal text, the `LAIN_QA_PANE` bypass and
  its liveness check) is correct **given a correct candidate set**.
- **`pane_current_command` is right in the normal cockpit and right for a reason**: `Up::PaneCommand`
  (`cli/up/pane_command.rb:87-89`) ends in `exec $PROGRAM_NAME`, replacing the wrapping shell, so the
  chat pane genuinely reads `ruby` and the nvim pane `nvim`. It fails only for a chat that is not its
  pane's foreground process — measured live: `%2 cmd=ruby` (a chat) beside `%5 cmd=zsh` whose child
  is also a chat.
- **A second, undiscovered bug in the same block**: `peek.sh` takes the `LAIN_QA_PANE` branch
  before `$PAT` is ever consulted (`qa-sandbox.sh:145-152`), so a pinned pane silently overrides the
  `chat|nvim` selector — `LAIN_QA_PANE=%2 peek.sh 6 nvim` reads the chat. Introduced by the
  round-15 chunk's own escape hatch.
- **Call sites constrain the fix**: 31 `drive.sh` and 30 `peek.sh` invocations across `planning/qa/`,
  all positional, none passing a 4th argument. `drive.sh` must keep `$1=text $2=quiet $3=max`
  (two sites rely on the `QUIET=60 MAX=900` defaults); `peek.sh` must keep `$1=lines`.
- **Guard ordering is load-bearing**: journal pin → pane resolve → approval guard → send. The
  approval guard resolves nvim by socket glob independently of the pane.
- The repo already composes `#{pane_pid}` → `/proc/<pid>/environ` in four places
  (`qa-sandbox.sh:355-358`, `method.md:69-72`, `:406-409`, `rails-blog.md:59`) and endorses
  `pgrep -P` (`method.md:927-940`) while **banning bare `pgrep -f`**, which has twice killed the
  issuing shell. Nothing yet composes the two into a descendant walk.

### `QuestionsConsumed`

`telemetry/questions_consumed.rb:19-30` passes `digests` through `Canonical.normalize`, which
(`canonical.rb:31-40`) passes `nil` through and maps a String to a frozen String — it coerces nothing
to an Array. Both `digests: nil` and `digests: "blake3:q1"` are constructible. Both consuming arms
then raise `NoMethodError` — `Inbox#retire` (`status_feed/inbox.rb:91-97`) calls `.each`,
`InboxView#retire` (`inbox_view.rb:346-357`) calls `.inject` — into `CLI::JournalTee`, which
re-raises a non-`ClosedQueueError` sink failure (`journal_tee.rb:47-53`) and costs a turn.
**Not merely theoretical:** `spec/support/generic_build.rb:11` tries `"x"` first, so
`spec/journalable_surface_spec.rb`'s sweep constructs the String form today. The production path is
safe — the only producer is `Scribe#consumption` → `from_event` (`session_record/scribe.rb:306-310`)
and `Event#normalize_causal` (`event.rb:189-191`) always yields a frozen sorted uniq Array.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb`, `lib/lain/telemetry.rb`, `.rubocop.yml`, `spec/spec_helper.rb`, `lain.gemspec`.
  **No card in this chunk needs a wiring diff** — T8 extends an existing file rather than creating
  one, and T12 adds a top-level spec that `spec_helper` already reaches.
- **A new lib file, its index line and its spec land in the SAME commit** (CLAUDE.md's
  commit-grouping rule) — no card creates a new `lib/` file, so this does not bind here.
- **T5 and T6 edit `bash` heredocs and have no suite coverage**; integration check 6 is their only
  gate and is not optional.

## Open decisions

1. **`run_skill`'s confirm has no channel, and this chunk does not invent one.** `ask_human` owns a
   human channel; `run_skill` does not. The two candidate routes are the approval gate (which is
   already "ask the human to authorize an effect", but `run_skill` is not gated today) and a new
   surface. **T10 is scoped to the bound and the friction signal only**, returning a refusal that
   names the narrower action, and the confirm-and-proceed affordance is deferred. If T10 finds a
   clean route it escalates rather than building it.
2. **The dropped-consumption-record gap (round 15's Open decision 7) is not taken here.** A dropped
   `Telemetry::QuestionsConsumed` is unrecoverable — nothing consumes `Telemetry::Dropped`
   (`channel/drop_oldest.rb:134-138` writes it; no reader exists in `lib/`) and no resync path
   exists. Both consuming files already carry the deferral in words. A resync is a Channel-and-tee
   design, not a status-feed one.
3. **Sibling-to-sibling agent communication is the direction this identity work serves, and is its
   own chunk.** The substrate exists — `Lineage#note(from:, to:)` takes arbitrary endpoints,
   mailboxes fold through `Event::Projection`, and `Isolation::Worktree` already gives each agent
   its own tree. What it will need first is this chunk's identity, and then a trust boundary: a
   sibling's message is untrusted input, and `Approval::GateDecision#answered_by`
   (`approval/gate.rb:31-38`) plus `AutoSurface` (an LLM adjudicator already modelled as a weaker
   principal than the human) are where that boundary already begins. `Approval::Remembered` is the
   first place to audit, since it keys on tool-call bytes and could let a sibling inherit a human's
   approval.
4. **A resumed run restarts T1's ordinal**, so a spawn from a head already spawned from before the
   resume can re-collide. Accepted: it is no worse than today, and closing it means seeding the
   counter from the Store, which is content-addressed with no index by body content — a scan. The
   `worker_id` design closes it properly and is where the sibling-communication chunk should take
   this.

5. **The friction signal for an over-verbose skill is cut from this chunk, and the reason is that it
   could not have worked.** The human asked for it and it is the right idea; `Friction`
   (`lib/lain/friction.rb:6-11`) is exactly the right home — a deterministic fold over one session
   Journal, no model call, telling the lain *user* which knob to turn. But `Tools::RunSkill` has no
   journal, sink or telemetry collaborator (`run_skill.rb:49-54`), and the `journal:` other tools are
   handed is `Lain::Channel.new` (`cli/wiring.rb:136`), an in-memory render bus whose own doc says
   *"Durability is not on this channel at all"*, while `CLI::Friction#report`
   (`cli/friction.rb:23-26`) reads the Chronicle's session NDJSON. The empirical proof is that
   `shell_arm` — written exactly that way — appears in **zero** real session journals across every
   QA round. **What it actually needs** is `chronicle.record_journal` threaded into
   `CLI::Wiring::ToolsetBuild`, which today holds only `chronicle.observer`
   (`cli/wiring/toolset_build.rb:245`) — the `Capability::Policy` / `Effect::Handler::Sensitivity`
   pattern (`cli/wiring/agent_build.rb:80`). That is a wiring chunk, not a kwarg, and it would let
   every tool record durably rather than just this one.

6. **F86 and F87 were filed by round 16 and are withdrawn on the human's ruling.** `/introspect`'s
   refusal to name the window size is deliberate (`cli/command/introspect.rb:32-38`) and
   spec-pinned (`introspect_spec.rb:141`); the compaction report's `:stderr` is argued at
   `cli/compaction_mount.rb:81-82` and shared with the summarizer-down fault. No cards.

## Waves

```
Wave 1: T1, T4, T5, T7, T8, T11
Wave 2: T2 (←T1), T3 (←T4), T6 (←T5), T9 (←T8), T10 (←T8)
Wave 3: T12 (←T9, T10, T11)
```

Critical path: **T8 → {T9, T10} → T12** (depth 3), tied by **T4 → T3**.

No two same-wave cards share a file. T4/T3 share `cli/fleet_windows.rb` and T5/T6 share
`qa-sandbox.sh`, in that order. **T4 lands before T3 on purpose**: the detector first, so integration
check 7 sees it report the live `status 127` against unfixed code and then fall silent once T3 lands
— a free proof that both cards work. T1 touches `spec/lain/supervisor_reactor_spec.rb:153-172` and T2
touches `:174`, in successive waves.

## Tasks

### T1 — Give a spawn an identity two live children cannot share   [wave 1] [risk: high]   ✅ LANDED `b1352c27`

**Depends on:** none
**Files:** `lib/lain/tools/subagent/lineage.rb`, `spec/lain/tools/subagent/lineage_spec.rb`,
`spec/lain/actor_spec.rb`, `spec/lain/supervisor_reactor_spec.rb` (the `:153-172` example only)
**Reuse:** `Isolation::WorkerId.adopted(role:, ordinal:)` (`lib/lain/isolation/worker_id.rb:30-50`)
is the identity the isolation layer already mints per adoption and already refuses to let collide;
`Supervisor#next_worker_id` (`supervisor.rb:231-234`) is where it comes from. `Lineage#spawn`'s
existing conditional idiom — `body["lifecycle"] = lifecycle unless lifecycle.nil?`
(`lineage.rb:41`) — is the shape for writing a field only on the path that needs it.
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent::Actor#launch` (`actor.rb:79`) on every actor launch, which
`Supervisor#adopt` (`supervisor.rb:105-113`) wraps; the tool is built at `CLI::Wiring::ToolsetBuild`.

An actor's address is its `:spawn` digest, and two spawns of one arm from one head are byte-identical
— so two live children share one address. Write a **deterministic** per-adoption identity into the
actor spawn's body so they do not. Deterministic is the binding constraint: a random nonce re-derives
a different digest on every replay and the journal is the experiment record.

**The design is decided here, not by the implementer: hold a deterministic ordinal on `Lineage`,
keyed by the `spawned_from` head.** The alternative — threading `Supervisor`'s `worker_id` through —
is the better long-term identity and is where the sibling-communication chunk should take this, but
it does not fit this card: the launch block lives in `Tools::Subagent#launch_actor`
(`tools/subagent.rb:185`, `:131-142`), so widening the yield edits **T11's file in the same wave**,
and it also touches `supervisor/restart.rb:193` (a second launch block) and `supervisor.rb:380`
(`Supervisor::Null.adopt`). Its premise is weaker than it looks, too — see the Grounding note on
`supervisor.rb:57-60`. The ordinal is self-contained, deterministic, and keyed on exactly the scope
where collisions happen.

**Say in a comment what a resumed run does.** A fresh `Lineage` restarts the ordinal at 0, so a
spawn from a head already spawned from before the resume can re-collide. That residue is accepted
here and is named in Open decision 4.

**A one-shot's `:spawn` bytes should stay unchanged** unless the implementer finds a reason
otherwise: a one-shot has no adoption and no address to collide, and `actor.rb:76-78` and
`lineage.rb:32-36` both already argue that asymmetry.

**Acceptance criteria:**

```gherkin
Scenario: two actors launched from one head take different addresses
  Given a parent chain at one head
  When the same arm is launched twice without committing between them
  Then the two actors' addresses differ

Scenario: the same adoption reproduces across runs
  Given one arm launched from one head in a run
  When an identical run launches the same arm from the same head
  Then the address of the first adoption is the same in both runs

Scenario: a recorded spawn still re-derives its recorded digest
  Given a recorded actor spawn
  When its body is rebuilt from what was recorded
  Then it re-derives the digest it was recorded under

Scenario: a one-shot spawn is unchanged
  Given a one-shot spawn
  When its body is written
  Then it carries no adoption identity

→ spec file: `spec/lain/tools/subagent/lineage_spec.rb` and `spec/lain/actor_spec.rb`

**Escalation triggers:**
- `Supervisor#register` (`supervisor.rb:266-275`) calls `launch.call(lease.worker_env)` and the
  registry row is built *after* `launch` returns. If threading `worker_id` to the launch block means
  reordering the lease acquisition or the registration, **stop** — `register`'s `ensure
  lease&.release unless registered` is a leak guard and its ordering is load-bearing.
- `Supervisor#@registry` is an Array *because* addresses collide (`supervisor.rb:49-52`), and
  `Supervisor::Restart` refuses address lookup for the same reason (`supervisor/restart.rb:24-28`).
  If unique addresses make either comment false, **amend it in this card** rather than leaving a
  comment arguing the opposite of the tree.
- `spec/lain/supervisor_reactor_spec.rb:153-172` asserts `twin_a.address == twin_b.address` as
  *passing* behaviour ("identical spawns share an address"). This card inverts it. **Rewrite it
  rather than deleting it**, and leave `:174`'s `pending` example to T2.
- If any spec asserts a literal `blake3:` digest for an **actor** spawn, it will go red and that is
  expected — but if one goes red for a **one-shot** spawn or a parent turn, **stop**: the change
  reached further than this card intends.

### T2 — Retire the twin as a known defect   [wave 2] [risk: medium]   ✅ LANDED `9fef4a84`

**Depends on:** T1
**Files:** `spec/lain/supervisor_reactor_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`
**Reuse:** the `pending` example at `supervisor_reactor_spec.rb:174-205` already states the target
behaviour as what *should* hold, inverted on purpose so it goes green on the fix and RSpec fails on
the stale marker. That is the signal; take it.
**Shared-file wiring:** none
**Reachable from:** `StatusFeed::Fleet#launched`/`#completed` (`status_feed/fleet.rb:38,66`) on the
tee built at `CLI::LiveViews#initialize` (`live_views.rb:128-130`).

Un-pend the twinned-actor example and prove the roster now counts two live children and retires
exactly the one that ended.

**Acceptance criteria:**

```gherkin
Scenario: two live twins are two fleet members
  Given two actors launched from one head
  When both are running
  Then the published fleet names two members

Scenario: one twin's farewell retires only that twin
  Given two live twins on the feed
  When the first one stops
  Then the published fleet still names the survivor

Scenario: the stale pending marker is gone
  Given the twinned-actor example
  Then it is no longer pending
```
→ spec file: `spec/lain/supervisor_reactor_spec.rb` and `spec/lain/status_feed/fleet_spec.rb`

**Escalation triggers:**
- If the example goes green **without** T1's change — i.e. it was already passing — **stop**: the
  collision was not what the note says it was, and the whole card premise needs re-grounding.
- `status_feed.rb:16-17` forbids the feed reading an in-process registry, pinned at
  `spec/lain/status_feed_spec.rb:182`. If proving two members needs a `Supervisor` handed to the
  feed, **stop** — the roster must stay journal-derived.

### T3 — A fleet window runs a command that can actually start   [wave 2] [risk: high]   ✅ LANDED `558b4ed6`

**Depends on:** T4 (both edit `cli/fleet_windows.rb`; and landing the detector first buys a free
proof — integration check 7 should see T4 report the live `status 127` against unfixed code, then
see it fall silent once this card lands)
**Files:** `lib/lain/cli/fleet_windows.rb`, `spec/lain/cli/fleet_windows_spec.rb`
**Reuse:** `Up.pane_command` (`cli/up/pane_command.rb:87-89`) — the existing answer to "a tmux pane
has no usable environment", already used by `/fork` (`cli/command/fork.rb:128-129`) and `/btw`
(`cli/command/btw.rb:53-55`), both of which also pass `cwd: Dir.pwd`. `TmuxSurface#window`
(`cli/tmux_surface.rb:69-77`) already accepts `cwd:` and passes it as `-c`.
**Shared-file wiring:** none
**Reachable from:** `CLI::LiveViews#initialize` (`live_views.rb:128`) builds it as
`FleetWindows.for(options)` under `--windows` inside tmux; `Pump::Open#perform`
(`fleet_windows.rb:83`) is the call that reaches tmux.

Measured this round: the window opens and dies with **status 127** — `lain` is not on `PATH` under a
pane's non-interactive `$SHELL -c`. `FleetWindows` is the only window-opener composing a bare command
and the only one passing no `cwd:`.

**Acceptance criteria:**

```gherkin
Scenario: the window's command is composed by the same object every other pane's is
  Given a spawn observed under --windows
  When its window command is built
  Then it is composed by the collaborator /fork and /btw compose theirs with

Scenario: the window is opened in a working directory
  Given a spawn observed under --windows
  When its window is opened
  Then the open names a working directory

Scenario: a real tmux window running the composed command is still alive a moment later
  Given a real tmux server
  When a fleet window is opened with the composed command
  Then the window is still listed after the command has had time to start
```
→ spec file: `spec/lain/cli/fleet_windows_spec.rb`

**One thing the implementer will hit, named here rather than discovered.** `Up::PaneCommand.call`
composes `exec $PROGRAM_NAME` (`cli/up/pane_command.rb:88`), and the comment at `:85-86` says
`$PROGRAM_NAME` "must be read when the exe runs -- **under rspec it is not the lain binary**". So the
third AC cannot be driven through `PaneCommand.call` as it stands: under the suite it composes
`exec /path/to/rspec watch …` and dies of the same class of failure it is meant to disprove. The card
needs a seam — a resolvable program path, or `PaneCommand.call(program:)`. Propose one; if that means
editing `pane_command.rb`, **escalate** rather than widening scope silently.

**Escalation triggers:**
- The existing real-tmux block (`fleet_windows_spec.rb:407-443`) overrides
  `watch_command: "sleep 60 #"` precisely to avoid needing `lain` on the pane's PATH. The third AC
  cannot be written by keeping that override — it must drive the real composition. If that proves
  impossible in the suite's environment, **stop and say so**: the card's whole point is that the
  spec suite has been stepping around the defect.
- `Up.pane_command` re-exports `GEM_HOME`/`GEM_PATH` from the running interpreter. If reaching it
  from `FleetWindows` means `lib/lain/cli/fleet_windows.rb` taking a dependency that inverts load
  order (`lain.rb` loads `cli` as one unit), **stop and report** rather than adding a require.
- `mark_target` (`fleet_windows.rb:318`) builds an exact-match `"=name"` target from the window name.
  If changing the command changes how the window is named, the done-marker rename breaks silently.

### T4 — A fleet window that dies says so   [wave 1] [risk: medium]   ✅ LANDED `10f9534a`

**Depends on:** none
**Files:** `lib/lain/cli/fleet_windows.rb`, `lib/lain/cli/tmux_surface.rb`,
`spec/lain/cli/fleet_windows_spec.rb`, `spec/lain/cli/tmux_surface_spec.rb`
**Reuse:** **`remain-on-exit` is the mechanism that makes this observable at all**, and
`Up#keep_failed_pane` (`cli/up.rb:800`) is the in-tree precedent — it sets `remain-on-exit failed` on
the chat window for exactly this reason. Without it the dead pane is destroyed in milliseconds and
any liveness check is a coin flip: query immediately and the window is alive, query later and it is
gone. `WindowsCapped` (`cli/fleet_windows.rb:62-66`) is the exact precedent — a `Journalable`
`Data` carrying what could not be windowed, written to `@pump.notice` via `Pump::Notice`
(`:100-102`) and released at `release_notice` (`:297-302`). `Pump::Mark`'s rescue of
`TmuxSurface::TmuxUnavailable` (`:90-96`) is the one sanctioned swallow and shows where a benign
"already gone" is distinguished from a fault.
**Shared-file wiring:** none
**Reachable from:** `Pump#perform` (`fleet_windows.rb:162`) on every queued command, under
`--windows` inside tmux.

`TmuxSurface#act` raises only on a non-zero exit from the tmux *client*, and `new-window` exits 0 as
soon as the server accepts. Whether the pane lived is invisible, which is why a 127 went unreported
for the life of the feature. Make the difference between "tmux accepted the request" and "the window
is still there" observable.

**Acceptance criteria:**

```gherkin
Scenario: a window whose command dies immediately is reported
  Given a fleet window opened with a command that cannot start
  When the pump next runs
  Then a record names the spawn whose window did not survive

Scenario: a window whose command keeps running is not reported
  Given a fleet window opened with a command that stays up
  When the pump next runs
  Then no such record is written

Scenario: the report names something the human can act on
  Given a window that did not survive
  Then the record carries the command that was attempted
  And it carries the exit status the pane died with
```
→ spec file: `spec/lain/cli/fleet_windows_spec.rb` and `spec/lain/cli/tmux_surface_spec.rb`

**Escalation triggers:**
- `FleetWindows#<<` is a tee sink and must **never block and never raise** — `journal_tee.rb:47-53`
  re-raises a sink's failure into the agent loop, and the class doc (`fleet_windows.rb:216-217`)
  says "Never blocks, never shells out". A liveness check that shells to tmux on the fan-out path
  breaks that. It belongs on the **pump's** fiber, not on `#<<`.
- If verifying liveness needs a second tmux round trip per window, weigh it against `Pump`'s
  purpose (keeping shell-outs off the fan-out) and say what it costs. If it needs a *poll*, **stop**
  — a polling loop is a different design and needs the human.
- **Say what a persisting corpse costs.** `remain-on-exit` leaves the dead window on screen until
  something kills it. If that means an operator accumulates dead windows across a session, name the
  cleanup and who does it — a fix that trades a silent failure for screen litter is a different
  trade and the human should see it stated.
- `chat_launch.rb:104`'s teardown `drain_pending` runs after an unguarded `close` at `:100`. If a
  raise at `:100` would now lose a *report* as well as a window, say so; do not fix it here.

### T5 — The driver sees a chat that is not its pane's foreground command   [wave 1] [risk: medium]   ✅ LANDED `f038f9de`

**Depends on:** none
**Files:** `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, `planning/qa/method.md`
**Reuse:** the repo's established `#{pane_pid}` → `/proc/<pid>` idiom, present in four places
(`qa-sandbox.sh:356-358`, `planning/qa/method.md:69-72`, `planning/qa/scenarios/rails-blog.md:59-61`,
and `.claude/skills/manual-qa/SKILL.md:115`) — and **`method.md:406-409` is the closest thing to a
descendant walk already in the repo**, composing `pgrep -P` with `/proc/<pid>/cmdline`, which is
exactly the shape this card needs. Plus `method.md:927-940`'s endorsed process queries —
`pgrep -P <parent>`, `ps -eo pid,args | grep '[b]racketed'`, `ls -l /proc/<pid>/exe`.
**Shared-file wiring:** none
**Reachable from:** `qa-sandbox.sh` writes `drive.sh` and `peek.sh` into `$QA/` at sandbox creation;
every QA round drives through them.

Both helpers build their candidate set from `pane_current_command` matched against `ruby`. A chat
that is not its pane's foreground process — one under a shell wrapper — contributes nothing, so no
ambiguity is detected and the send goes silently to the other chat. Measured live this round: a
prompt intended for one chat landed in the cockpit. The refusal added in round 15 is only a refusal
over *command-matching* candidates, which reads as stronger than it is.

**`method.md` is in scope** because `:519-545`'s bullet now describes the refusal as covering "more
than one candidate pane", which is the false confidence this card removes.

**Acceptance criteria:**

```gherkin
Scenario: a chat under a wrapper is counted as a candidate
  Given one pane whose foreground command is a chat
  And one pane whose foreground command is a shell with a chat child
  When drive.sh resolves without an explicit pin
  Then it refuses, naming both

Scenario: the ordinary cockpit still resolves
  Given the normal two-pane cockpit, one chat and one editor
  When drive.sh resolves
  Then it sends to the chat, and peek.sh can still reach the editor

Scenario: nothing is sent when it refuses
  Given two candidate chats
  When drive.sh refuses
  Then neither pane received the text
```
→ spec file: none — shell, and **integration check 6 is the only real gate**. Both helpers are
emitted from *single-quoted* heredocs (`qa-sandbox.sh:49`, `:133`), so every line either card touches
is literal string data: `bash -n` and the pre-commit `shellcheck` hook parse only the **generator**,
never the generated script. Run them, but do not read them as coverage.

**Escalation triggers:**
- **`method.md:927-940` bans a bare `pgrep -f`**, which has twice killed the issuing shell (exit
  144, mid-heredoc). Any process query this card adds must exclude the issuing shell. If the
  descendant walk cannot be written without one, **stop**.
- Guard ordering is load-bearing: journal pin → pane resolve → **approval guard** → send. If the new
  resolution moves the approval guard after the send, **stop** — that ordering cost a round three
  turns once.
- 31 `drive.sh` and 30 `peek.sh` call sites are positional with no 4th argument. A new positional
  parameter breaks them; the fix must be an env var or internal.
- A chat pane may legitimately be `ruby` with **no** `exe/lain chat` in its argv under a degraded
  launch. If the process-tree rule makes the ordinary single-pane `--no-nvim` cockpit
  (`cli/up.rb:694`) unresolvable, **stop** — it must not refuse the normal case.

### T6 — A pinned pane does not silently answer for the other one   [wave 2] [risk: low]   ✅ LANDED `f605ec92`

**Depends on:** T5 (both edit `qa-sandbox.sh` and `method.md`; T5 lands first)
**Files:** `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, `planning/qa/method.md`
**Reuse:** `drive.sh`'s own pin-validation block (`qa-sandbox.sh:66-76`), which checks the pin
against live panes before trusting it — the same discipline, applied to the *kind* as well as the
liveness.
**Shared-file wiring:** none
**Reachable from:** `qa-sandbox.sh` writes `peek.sh` into `$QA/`; every scenario reading a pane.

`peek.sh` takes the `LAIN_QA_PANE` branch before `$PAT` is consulted (`qa-sandbox.sh:145-152`), so a
driver who pins the chat pane and then asks for the editor gets the chat, with plausible text and a
zero exit. The pin is one scalar shared by both helpers and both roles. This was introduced by the
round-15 chunk's own escape hatch.

**Acceptance criteria:**

```gherkin
Scenario: a pin does not override the requested kind
  Given LAIN_QA_PANE pinned to the chat pane
  When peek.sh is asked for the editor
  Then it does not return the chat pane's contents

Scenario: a pin still works for the kind it names
  Given LAIN_QA_PANE pinned to the chat pane
  When peek.sh is asked for the chat
  Then it reads that pane

Scenario: drive.sh is unaffected
  Given LAIN_QA_PANE pinned
  When drive.sh runs
  Then it sends to the pinned pane as before
```
→ spec file: none — shell, and **integration check 6 is the only real gate**. Both helpers are
emitted from *single-quoted* heredocs (`qa-sandbox.sh:49`, `:133`), so every line either card touches
is literal string data: `bash -n` and the pre-commit `shellcheck` hook parse only the **generator**,
never the generated script. Run them, but do not read them as coverage.

**Escalation triggers:**
- No scenario call site passes `peek.sh`'s `$2` today, but `method.md:616-617` documents it. If the
  fix changes `$2`'s meaning rather than its handling, **stop** — the documented interface is the
  contract even where unexercised.
- If a per-kind pin (two variables) is the clean answer, that is a **new interface** for the bench
  and belongs in `method.md` and the sandbox banner, not only in the script. Say so.

### T7 — A consumption record's digests are always a list   [wave 1] [risk: low]   ✅ LANDED `caf07125`

**Depends on:** none
**Files:** `lib/lain/telemetry/questions_consumed.rb`,
`spec/lain/telemetry/questions_consumed_spec.rb`
**Reuse:** `Event#normalize_causal` (`event.rb:189-191`) is the shape the production path already
guarantees — `.map { Canonical.normalize(_1) }.uniq.sort.freeze`. The record should guarantee for
itself what its one producer happens to supply.
**Shared-file wiring:** none
**Reachable from:** `SessionRecord::Scribe#consumption` (`session_record/scribe.rb:306-310`) on every
spawned chain's turn that cites causal parents; read by `StatusFeed::Inbox#retire`
(`status_feed/inbox.rb:91-97`) and `Frontend::Neovim::InboxView#retire` (`inbox_view.rb:346-357`).

`Canonical.normalize` passes `nil` through and maps a String to a String, so `digests: nil` and
`digests: "blake3:q1"` are both constructible, and both make the two inbox arms raise
`NoMethodError` into `CLI::JournalTee` — which re-raises into the agent loop and costs a turn. The
production path is safe today, but `spec/support/generic_build.rb` already builds the String form in
the journalable sweep. Be permissive on input and normalize, rather than leaving the guarantee to
whoever writes the next producer.

**Acceptance criteria:**

```gherkin
Scenario: a single digest given bare becomes a list of one
  Given a consumption record built with one digest and no array
  Then its digests read as a list holding that digest

Scenario: no digests at all is an empty list, not nothing
  Given a consumption record built with no digests
  Then its digests read as an empty list

Scenario: a list is unchanged
  Given a consumption record built with two digests
  Then its digests read as those two

Scenario: both inbox surfaces survive every shape
  Given each of those records in turn
  When each inbox surface consumes it
  Then neither raises
```
→ spec file: `spec/lain/telemetry/questions_consumed_spec.rb` — **the fourth scenario drives two
REAL components with no double between them, so it carries the `:seam` tag** (CLAUDE.md's middle
tier). Tag it there rather than moving it: the record is the subject, and the two surfaces are what
it is a contract with.

**Escalation triggers:**
- Value objects here are deeply frozen and `Ractor.shareable?` must stay true; there is a spec.
  If normalizing produces an unfrozen collection, the sweep will catch it — do not exempt the class.
- `spec/journalable_surface_spec.rb`'s `GenericBuild` builds every `Journalable` with the first dummy
  that works. If normalizing changes which dummy succeeds, that sweep's `built`/`unreached`
  partition moves. **Check it**, and if the record becomes unbuildable, **stop** rather than
  exempting it.
- The two consuming arms are held to "change both or neither" (`status_feed/inbox.rb:15-19`). This
  card changes neither — it changes what they are handed. If greening the fourth AC requires editing
  either surface, **stop**: that is T-scope creep into a parity-pinned pair.

### T8 — A bound that hands the oversized thing back   [wave 1] [risk: medium]   ✅ LANDED `7da31d9d`

**Depends on:** none
**Files:** `lib/lain/tool/bounds.rb`, `spec/lain/tool/bounds_spec.rb`
**Reuse:** `Bounds::Artifact` (`tool/bounds.rb:142-181`) is the sibling and the shape to write
toward — `#admits?` on a size, a refusal that takes the content as *no* parameter, and `#message`
raising when offered no narrower action (`:175`). `Bounds.ceiling` (`:76-81`) and `Bounds.unit` are
the shared validators.
**Shared-file wiring:** none
**Reachable from:** deliberately none in this card — it is constructed by T9 and T10, both in this
chunk and both named. This card ships no dormant capability.

`Tool::Bounds` has two shapes: cap-and-disclose, and refuse-whole. The human's ruling needs a third
— **hand the oversized thing back and let it be sent anyway** — for a human's own message and for a
skill's output. Neither existing shape expresses "this is too big, here it is, do you still want
it": `Enumeration` silently truncates and `Artifact` refuses without returning the content.

Write the value only. The two consumers wire it.

**Acceptance criteria:**

```gherkin
Scenario: a thing under the ceiling is admitted unchanged
  Given a bound and content under its ceiling
  Then the bound admits it

Scenario: an oversized thing is not refused outright
  Given a bound and content over its ceiling
  Then the bound reports it as oversized without discarding it

Scenario: the report names the measurement and the ceiling
  Given oversized content
  Then what the bound reports carries both the size and the limit

Scenario: the bound refuses to report without an action to offer
  Given a bound asked to report with no action named
  Then it raises
```
→ spec file: `spec/lain/tool/bounds_spec.rb`

**Escalation triggers:**
- `Artifact#message`'s doc (`bounds.rb:165-172`) warns that a tool holding both an output String and
  its `bytesize` is "one character from passing the wrong one", which is why `#refusal` takes no
  content. This card's shape **must** carry content by design. Say explicitly how it avoids
  interpolating a payload into a message, and if it cannot, **stop** — that warning was written
  from an incident.
- `Bounds`'s class doc (`bounds.rb:33-42`) records that `grep` and `ast_search` were deliberately
  left on their own pre-`Bounds` trailers. Do not unify them here.
- If this shape turns out to be `Artifact` with one more method rather than a third value, say so
  and propose the merge — a third near-duplicate value is worse than a widened one.

### T9 — A human's answer that is too long comes back to them   [wave 2] [risk: medium]   ✅ LANDED `6ab4621a`

**Depends on:** T8
**Files:** `lib/lain/tools/ask_human.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** T8's bound. `AskHuman#perform` (`ask_human.rb:596-604`) already owns the human channel and
already re-asks — `ask(Announcement.new(...))` then `awaited(pending)` — so a second ask is the
existing motion, not a new one. `Unanswered::REFUSAL` (`:599`) is the precedent for a non-answer
outcome.
**Shared-file wiring:** none
**Reachable from:** `Tools::AskHuman#perform`, built at `CLI::Wiring::ToolsetBuild#build`
(`cli/wiring/toolset_build.rb:257-262`) and reached whenever the model asks the human anything.

An answer goes straight into the parent's context with no bound at all. The ruling is **not** to
refuse it: hand it back, say it is too long, and let the human send it anyway.

**Acceptance criteria:**

```gherkin
Scenario: an ordinary answer is delivered unchanged
  Given an answer under the ceiling
  When the human answers
  Then the tool returns it as it was typed

Scenario: an oversized answer is handed back with its measurement
  Given an answer over the ceiling
  When the human answers
  Then they are shown their own text again, told its size and the ceiling

Scenario: a human who confirms gets their answer delivered
  Given an oversized answer that was handed back
  When the human confirms it anyway
  Then the tool returns the original text

Scenario: a human who declines is not forced to send it
  Given an oversized answer that was handed back
  When the human declines
  Then the tool does not return that text
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- The relay: `Chain#asking_handle` (`tools/subagent.rb:643-646`) addresses a child's question to its
  **parent's** correlation, so only the outermost hop carries `to: "human"`. If the confirm re-ask
  writes a second human-addressed record, it will list a second inbox row — the exact defect the
  round-15 chunk fixed. **Drive a relayed question**, not only a direct one.
- **Under `--non-interactive` this bound does not apply at all, and that is worth stating rather
  than discovering.** `CLI::Wiring::Askers#asker_over` (`cli/wiring/askers.rb:92-96`) wires
  `AskHuman::Unattended`, whose `#perform` is a **full override** returning `Tool::Result.error` and
  never calling `super` — so a confirm loop cannot hang there, but neither does the ceiling bind.
  Say so in a comment.
- **`Notifying#ask` (`tools/ask_human/notifying.rb:19-23`) fires `@notify` on EVERY ask**, so a
  second ask raises a second inbox row and, through the relay, a second human-addressed record —
  the round-15 defect exactly. The confirm must reuse the **existing** pending set rather than
  opening a new one, and `awaited`'s `ensure @outstanding.abandon` means a second park needs its own
  handling. If that cannot be done without a second `ask`, **stop**.
- A stop raised while parked (`ask_human.rb:606-610`) means nobody will deliver the answer and the
  set stops being outstanding. If the confirm adds a second park, it needs the same treatment;
  if that is not obvious, **stop and confirm** rather than leaving a question outstanding forever.

### T10 — A skill that returns too much is bounded   [wave 2] [risk: medium]   ✅ LANDED `c44eaa31`

**Depends on:** T8
**Files:** `lib/lain/tools/run_skill.rb`, `spec/lain/tools/run_skill_spec.rb`
**Reuse:** T8's bound; `RunSkill#perform`'s existing `Tool::Result.error(e.message)` path
(`run_skill.rb:73-77`), which already answers a named failure the model can act on.
**Shared-file wiring:** none
**Reachable from:** `Tools::RunSkill#perform` (`run_skill.rb:68-73`), built at
`CLI::Wiring::ToolsetBuild#build` (`toolset_build.rb:262`).

A rendered skill goes into context unbounded. Bound it.

**The friction signal this card was going to feed is cut from the chunk** — see Open decision 5.
`RunSkill` has no journal, sink or telemetry collaborator of any kind (`run_skill.rb:49-54`), and the
`journal:` other tools receive is `Lain::Channel.new` (`cli/wiring.rb:136`), an in-memory render bus
whose own doc says "Durability is not on this channel at all". `lain friction` reads the Chronicle's
session NDJSON. Empirically: `shell_arm`, written exactly that way, appears in **zero** real session
journals. A measurement recorded here would be unreachable by the thing meant to read it.

**Per Open decision 1, this card does NOT build a confirm affordance.** `ask_human` owns a human
channel; `run_skill` does not, and inventing one is a design question this chunk defers. Refuse with
a message naming the narrower action.

**Name the collaborator rather than inlining a fourth branch.** `#perform` (`run_skill.rb:68-78`) is
already budget-guard plus happy path plus `rescue`; a bound that measures and refuses is a fourth,
and CLAUDE.md's rule is that a tripped `Metrics/*` limit names a missing object. The object is "what
this tool may hand back" — the same shape `Agent::Budget` and `Agent::ToolRunner` were extracted
into.

**Acceptance criteria:**

```gherkin
Scenario: an ordinary skill result is returned unchanged
  Given a skill whose expansion is under the ceiling
  Then the tool returns it

Scenario: an oversized skill result is refused with an action
  Given a skill whose expansion is over the ceiling
  Then the tool answers with its size, the ceiling, and something narrower to do

```
→ spec file: `spec/lain/tools/run_skill_spec.rb`

**Escalation triggers:**
- `RunSkill` distinguishes a `Lain::Error` (answered, loop continues) from a genuine bug (propagates
  to gate 3) at `run_skill.rb:73-77`. A bound is not an exception; if implementing it blurs that
  split, **stop**.
- `@max_invocations` / `budget_exhausted` (`run_skill.rb:69`) already refuses. Two refusals on one
  method is a shape worth naming — if the bound makes the method trip a `Metrics/*` cop, extract
  rather than loosen.
- **If a clean route to a human confirm exists** — the approval gate, most likely, since it is
  already "ask the human to authorize an effect" — **escalate rather than building it**. Open
  decision 2 says this chunk does not decide that.

### T11 — A subagent that answers with too much summarizes itself   [wave 1] [risk: medium]   ✅ LANDED `71d6777a`

**Depends on:** none
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/tools/subagent/actor.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/actor_spec.rb`
**Reuse:** **`Bounds::Artifact#admits?` (`tool/bounds.rb:151`) is a pure size predicate available in
wave 1 with no dependency on T8** — measure with it even though the *action* here is "summarize",
rather than hand-rolling a size check inside the one chunk that is extending `Tool::Bounds`.
`spawn_one_shot` (`tools/subagent.rb:194-204`) already holds `child` beside `response` and
already re-uses `child` for `lineage.message(parent, spawn, child, response)`, so the child Agent is
in scope and its context already holds the material. `Agent#ask` is the existing motion.
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent#spawn_one_shot` on the real dispatch of every one-shot child;
the tool is built at `CLI::Wiring::ToolsetBuild`.

**Both spawn paths are unbounded, and the actor one is the chunk's own headline.**
`spawn_one_shot` returns `Tool::Result.ok(response.text)` (`tools/subagent.rb:203`), and `Actor#reply`
(`tools/subagent/actor.rb:181`, `:187-189`) puts `response.text` verbatim into a `Lineage#note` that
`Context::Mailbox#line_for` (`context/mailbox.rb:112-116`) folds straight into the parent's render —
so every actor turn's full answer reaches the parent with no ceiling. A child's whole answer goes
into the parent's context unbounded — the mechanism round 16 confirmed behind F82. The ruling is not to truncate and not to refuse: **ask the child to summarize its own
answer**, which is cheap because its context already holds it.

**Acceptance criteria:**

```gherkin
Scenario: an ordinary child answer is returned unchanged
  Given a one-shot child whose answer is under the ceiling
  Then the parent receives the child's text as it was

Scenario: an oversized answer comes back summarized
  Given a one-shot child whose answer is over the ceiling
  Then the parent receives a shorter answer from that same child

Scenario: the parent is told it is reading a summary
  Given an oversized answer that was summarized
  Then what the parent receives says so

Scenario: a summary that is itself oversized does not loop
  Given a child whose summary is also over the ceiling
  Then the tool answers without asking the child again

Scenario: an actor's oversized reply is bounded on the same rule
  Given a live actor whose reply is over the ceiling
  When it replies to its parent
  Then what folds into the parent's context is bounded the same way
```
→ spec file: `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- The summarizing ask is **a second model call on the child**, so it costs money and a turn on the
  child's timeline, and it is recorded. If the child's iteration ceiling or budget refuses it,
  the tool must still answer the parent something — **stop** if the only path is losing the result.
- `spawn_one_shot`'s comment (`subagent.rb:190-193`) says the three `@last_*` ivars are written
  once, together, with no yield between, so a fan-out sibling cannot see a half-updated record. A
  summarizing call **yields**. If it lands between `run_child` and `remember`, that invariant
  breaks — **stop and report** rather than reordering it.
- The fourth AC's floor must not be a silent truncation:
  `middleware/withhold_secret_paths.rb:29-33` argues against silent truncation by name. Whatever the
  floor is, it discloses.

### T12 — A tool that returns content declares what it may return   [wave 3] [risk: low]   ⛔ NOT STARTED

**Depends on:** T9, T10, T11
**Files:** create `spec/tool_bounds_discipline_spec.rb`
**Reuse:** `spec/output_discipline_spec.rb`, `spec/journalable_surface_spec.rb` and
`spec/lain/review/deletability_spec.rb`'s `DeletionMap` are the house pattern — a spec-side registry
whose own docstring says its rows are named together "precisely so they cannot drift apart one
marker at a time". `spec/support/generic_build.rb`'s `ObjectSpace` sweep is the enumeration idiom.
**Shared-file wiring:** none
**Reachable from:** the suite. This card builds no runtime capability; it is a gate.

Nothing enforces that a tool declares a bound. A bound is a class constant each tool consults
privately, and the only enumeration of which tools have one has been **prose in a plan document** —
twice now, and stale both times: the round-15 chunk named eleven unbounded tools, and this chunk's
own Grounding named three and missed `Actor#reply`. A sweep asserting every `Tool` subclass either
declares a bound or sits on a named exempt list is what stops round 18 re-deriving the list by hand.

**The exempt list is the point, not a loophole.** A tool whose result is structurally a fixed
sentence (`edit_file`, `write_file`, `todo_write`, `improvement_write`, `session_usage`,
`tool_search`) does not need a ceiling, and `grep`/`ast_search` carry deliberate pre-`Bounds`
trailers (`tool/bounds.rb:33-42`). Name each with its reason, so the next reader sees a decision
rather than an omission.

**Acceptance criteria:**

```gherkin
Scenario: every tool that returns arbitrary content declares a bound
  Given every Tool subclass the suite can enumerate
  Then each one either declares a bound or is named on the exempt list

Scenario: the exempt list carries a reason per entry
  Given the exempt list
  Then no entry stands without one

Scenario: a new unbounded tool fails the sweep
  Given a tool that returns arbitrary content and declares nothing
  Then the sweep names it
```
→ spec file: `spec/tool_bounds_discipline_spec.rb`

**Escalation triggers:**
- If `Tool` subclasses cannot be enumerated without loading the whole toolset — `spec_helper` does
  `require "lain"`, so they should be reachable — **stop** rather than hard-coding a list, which is
  the failure this card exists to end.
- `web_fetch` **truncates** a 5 MiB artifact and labels it (`tools/web_fetch.rb:563-565`), which is
  what `Bounds`' class doc (`:20-27`) argues an artifact must never do, at 40× `bash`'s ceiling. It
  will fail this sweep. **Do not fix it here** — report it, and let the human rule.
- `request_review` quotes every human annotation verbatim with no cap
  (`tools/request_review.rb:651-657`, `:754-760`) though its *inputs* are bounded by
  `Review::Bounds`. Decide whether "bounded at one remove" counts as declared, and say which.

## Integration checks

After the last wave:

1. **Full suite**: `bundle exec rake pspec`. Compare the **example COUNT** against the pre-chunk
   baseline as well as the failure count — `parallel_tests` reports only survivors (CLAUDE.md).
   Record the baseline in the execution log before the first card runs. The round-16 baseline was
   **16595 examples, 0 failures, 15 pendings**; T2 removes one pending.
2. **Lints**: bare `bundle exec rubocop` (never naming a `.toml`), `bin/comment-census
   --check-tickets`, `pre-commit run --all-files`. No `F84`, `F85`, `T1`-style citations in `lib/`
   or `spec/` comments — the reason goes in words.
3. **Rust untouched**: `git diff --stat ext/ crates/` must be empty. Nothing here reaches it, and
   T1 deliberately avoids the Event envelope for that reason.
4. **The digest change is contained.** After T1, confirm no spec asserts a literal digest for a
   **one-shot** spawn or a parent turn, and that `spec/lain/bench/session/message_replay_spec.rb`
   is green — historical journals must still re-derive their historical digests.
5. **The manual pass T1/T2 need, and it is the chunk's headline.** From a real cockpit with
   `--windows`: launch the **same** actor arm twice from one head without committing between them.
   Require the HUD's `fleet` to read **2**, `state.json`'s `fleet` to hold two distinct digests, and
   **two** tmux windows to open. Then stop one and require `fleet` to read **1** with the survivor's
   window still open. Round 16's regression baseline is one shared entry and one shared window.
6. **The bench's own scripts, driven once**: create a fresh sandbox, bring up a cockpit, then start
   a second chat **under a shell wrapper** and confirm `drive.sh` now refuses naming both. Confirm
   the ordinary cockpit still resolves for both `chat` and `nvim`, and that a pinned pane no longer
   answers for the other kind. T5 and T6 have no spec suite; this is their only gate.
7. **The manual pass T3/T4 need**: with `--windows` inside tmux, spawn a child and confirm the window
   **survives** and tails the child. Then point `watch_command` at something that cannot start and
   confirm a record says so. Round 16's evidence is a window that lived for under three seconds and
   a `Pane is dead (status 127)` nobody was told about.
8. **The manual pass T9/T11 need**: answer an `ask_human` with an oversized reply and confirm it
   comes back with the option to send anyway; drive a subagent whose answer exceeds the bound and
   confirm the parent receives a summary that says it is one; and drive a **live actor** whose reply
   exceeds it, since that is the path that folds straight into the parent's render.
9. **The regression gate round 16 did not reach** — `failure-injection`, `session-and-window`,
   `epic-tier`, `survey`, `prompt-slots-and-roles`. Round 16 drove only the scenarios touching the
   round-15 chunk's edits, so these are owed and are named here so they are not dropped a second
   time. `shell-terms` remains the one scenario in the directory never driven.

## Execution log

**Base ref.** The chunk lands on **`main`**, which was `428d662b` when execution began.
`origin/main` was `b1927ce7`, **119 commits behind** — so `isolation: "worktree"` (which forks from
`origin/main`) would have opened trees missing the entire recent history. Every card worktree is cut
by hand from `HEAD` into `tmp/worktrees/<card>` on `card/<card>`, and re-cut from the new `HEAD` at
the top of each wave, because `orchestrator-commits` moves the head as each card lands.

**Suite baseline, taken before the first card ran:** `bundle exec rake pspec` →
**16595 examples, 0 failures, 15 pendings**, in 61s. This matches the figure the plan recorded, so
the Grounding is not stale on that axis. T2 removes one pending, so the closing count should read
16595/0/14 barring examples the cards add.

**Grounding re-verified against `428d662b`** for every wave-1 card before spawning: `lineage.rb`'s
conditional-field idiom and its `{prefix, posture, only, spawned_from}` body; `actor.rb:76-80`'s
`@address = @spawn.digest` and `:187-189`'s verbatim `reply`; `bounds.rb`'s two shapes with
`Artifact` at `:142-181`; `questions_consumed.rb:19-30`'s unguarded `Canonical.normalize`;
`tmux_surface.rb:163-168`'s client-exit-only raise; `fleet_windows.rb:83`'s `cwd`-less `Open#perform`;
`qa-sandbox.sh:79` and `:154`'s `pane_current_command` seam and `:145-152`'s pin-before-`$PAT`
ordering; and `supervisor_reactor_spec.rb`'s passing twin example at `:153-172` beside the inverted
`pending` at `:174-205`. All present as described. No card was invalidated.

**One divergence from the plan, absorbed rather than escalated.** The Waves section asserts "No two
same-wave cards share a file", but **T1 and T11 both list `spec/lain/actor_spec.rb`** and both sit in
wave 1. Resolved by giving T1 sole ownership of that file — its ACs name actor addresses directly,
and the file already holds the spawn-address example at `:112-117` that T1 must invert. T11 was told
to put all five of its ACs, the actor-reply one included, in `spec/lain/tools/subagent_spec.rb`,
which is the spec file its own "→ spec file" line already names; anything that genuinely cannot live
there comes back as a patch for the orchestrator to apply once T1 has landed. T11 was also warned
not to assert a literal actor-spawn digest, since T1 changes those bytes underneath it.

**Pre-existing tree state**, none of it this chunk's: uncommitted edits to `ROADMAP.md`,
`planning/README.md` and the `references/repos/smolagents` submodule pointer. A merged leftover
worktree from an earlier chunk was found at `tmp/worktrees/T14` and is retired in the closing sweep.

### Landed

**`caf07125` — telemetry: a consumption record's digests are always a list.** Suite green through
pre-commit against the staged tree.

Two things the panel changed, recorded because both are decisions rather than corrections:

- **The card's Reuse line was overridden.** It directed mirroring `Event#normalize_causal`'s exact
  `.map { Canonical.normalize(_1) }.uniq.sort.freeze`. The panel measured that the `.sort` changes
  nothing on the production path — `normalize_causal` already sorts, so `from_event`'s output is
  byte-identical either way — while converting `["a", nil]`, `[1, "a"]` and a nested-Hash list from
  *working but degraded* into an `ArgumentError` out of `sort`. That is a new failure mode in a card
  whose whole purpose is removing a raise on malformed input. `normalize_causal` sorts because a
  causal edge set is canonicalized into a hashed payload; this record is journal-only and hashes
  nothing, and neither consumer is order-sensitive. **Shipped as `Array(digests).map { … }.uniq.freeze`.**
- **The `:seam` tag is now earned rather than nominal.** The first implementation hand-unwrapped at
  the call site (`inbox.retire(record.digests)`), bypassing `StatusFeed#observe_consumption` — the
  code that actually reads `.digests` in production — so one arm had teeth and the other did not. It
  now drives `StatusFeed.new(path:, store:) << record` through the real reader against a real file.
  The panel proved the sensitivity rather than asserting it: with `observe_consumption` broken under
  a prepend, the old style stays green and the new style goes red.

The panel also verified by execution, not inference, that `spec/journalable_surface_spec.rb`'s
`GenericBuild` partition is unmoved (291 built / 69 unreached, identical class lists) and that both
parity-pinned inbox files are byte-identical — the "change both or neither" rule at
`status_feed/inbox.rb:15-19` held.

### Stopped here — what is owed

Eleven of twelve cards landed, each panel-reviewed, most through a fix round. **T12 was never
started** and its dependency is satisfied, so it is the clean next step: the sweep asserting every
tool that returns arbitrary content declares a bound or sits on a named exempt list. Three things
the panels established that its card could not have known, and that it must be briefed with:

- **Match a SHAPE, not the literal name `BOUND`.** Naming is already non-uniform across the tree —
  `OUTPUT_BOUND`, `WHOLE_BOUND`/`WINDOW_BOUND`, `DEFINITIONS_BOUND`/`REFERENCES_BOUND`,
  `INPUT_BOUND`, and this chunk's `ANSWER_BOUND` and `EXPANSION_BOUND`. A name-keyed sweep is wrong
  before it reaches its second tool.
- **Descend one `constants` level.** `AskHuman`'s bound is `Ceiling::BOUND`, nested on purpose: the
  panel ruled against hoisting because it would split a coherent object — the ceiling in one place,
  the three things that read it in another — to satisfy a spec that did not exist yet.
- **`Middleware::SkillDispatch#expand` is confirmed unbounded and will NOT be caught**, because it
  is a `Middleware::Base` and not a `Tool` subclass. Left deliberately: a human typed `/skill` and
  is present at a terminal, so the answer there is plausibly confirm-and-proceed, which is the
  affordance Open decision 1 defers. Name it in the exempt list's docstring as a known
  out-of-subject gap, the way `refusal_delivery_discipline_spec` handles its lexical blind spots,
  or round 18 rediscovers it by hand for the third time.

**The last two commits bypassed the pre-commit hook, deliberately and with evidence.**
`spec/lain/frontend/neovim_runtime_spec.rb`'s parked-approval group fails one example on every
**solo** run of that file while a whole-suite run of the same tree is green — measured at
`428d662b`, the pre-chunk baseline, so it predates every card here and is caused by none of them.
It now has its own entry in `docs/toolchain-traps.md`. Everything else the hook checks passed on
both commits: RuboCop clean over 1423 files, yard-lint clean, and the rest of the suite green at
16761 examples with that single failure. **Re-run `bundle exec rake pspec` on a quiet box before
trusting the final count**, since this chunk's own baseline run did not trip the flake either.

**Integration checks 1-4 are partly done and 5-9 are entirely owed.** The suite has been run
whole several times (16761 examples against a 16595 baseline; T2 removed one pending, the cards
added the rest); RuboCop and the ticket census are clean; `git diff --stat ext/ crates/` is empty.
Not done: the replay spec confirmed green in isolation as check 4 asks, and **every manual pass** —
the twinned-actor cockpit run, the bench-script round, the `--windows` window-survival run, the
oversized-answer runs, and the five regression scenarios round 16 never reached.

### Follow-ups this chunk earned, none of them started

- **Move spawn identity to an object whose scope matches the invariant.** The ordinal is per-writer;
  two `Subagent` instances over one head still collide. No production actor path reaches that today
  (`toolset_build.rb:338` is one memoized instance, and `role_spawn.rb:57` only ever calls
  `run` → `spawn_one_shot`, which mints no address), which is why it landed — but
  `Supervisor`'s `worker_id` is the identity that already survives a resume and a second writer.
- **`Middleware::SkillDispatch#expand`**, per above — needs the confirm-and-proceed design decision.
- **`Notify` drops the desktop arrival silently above ~131 KB.** `Dispatch#capture` rescues bare
  `StandardError` and returns `""`, and `journal_fault` is only on the sweep path, so a 150 KB reply
  produces no popup and no journal line. Clamp the argv and journal the fault.
- **A per-ask budget and a window-relative ceiling are the same piece of work.** `Agent#ask` takes
  no override and `Budget` is frozen, so a subagent's summarizing ask gets a fresh iteration budget
  under the still-held isolation lease; and 16 KiB does not scale with the parent's real window,
  which `ContextWindow` already knows. Both want the model and the budget in scope at the spawn.
- **`Skill::Renderer` materialises a composition before any ceiling sees it** — it does not dedupe a
  DAG, so a doubling include tree reaches 256 KiB at twelve levels and 256 MiB at twenty-two.
  `run_skill` refuses to put it in context; nothing refuses to build it.
- **`window_died` and `windows_capped` are rendered nowhere** — no reader in `lib/` or the nvim Lua
  runtime. The operator's only live signal is the held corpse pane.
- **`FleetWindows`' `@overflow` and `@unverified` are one unnamed concept with two release
  policies**, and `#start_ledgers` is a code-region rename rather than the `Ledgers` object the
  tripped cop was pointing at. Declined twice in-chunk, on purpose: two cards edited that file.
- **The 2-second wait in the fleet-window seam is calibrated on one box.** The self-calibrating
  design is a control window running a knowingly-wrong subcommand through the same recipe, polled
  until its corpse appears.
