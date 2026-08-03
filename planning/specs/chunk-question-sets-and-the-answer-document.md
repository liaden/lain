# Question sets, and the answer document

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

`ask_human` is a single free-text string in and a single free-text string out. This chunk makes
it a **question set**: one tool call carrying several questions, each with a markdown body and a
closed option list, answered by the human as a **folded markdown document** they edit in place —
tick a checkbox, write indented prose beneath an option to say why, `:w` to submit. The document
is the artifact; the surfaces are ways of opening it. Because the model authors the question body
as markdown, it can reach for a table, a fenced diff, or a mermaid block to make the question
answerable, and that same markdown degrades to readable text on a surface with no renderer.

The chunk also reverses one capability policy on purpose: subagents may now ask the human. That
is what makes several sets pending at once — the case the inbox has always rendered for and the
reply path has never supported.

Satisfies ROADMAP § "The human is an actor — inbox, notifications, escalation", whose inbox half
landed 2026-07-17 and whose remaining `[exp]` tail is exactly this: richer inbox items, and
per-item targeting.

## Grounding

Verified 2026-07-30 against working tree (HEAD `9530b2f`) by seven Explore passes and one
adversarial panel pass over the draft.

**Re-verified 2026-08-03 at HEAD `8ef1c1f`** before execution. `lib/lain/tool/input.rb` and
`spec/lain/tool/input_spec.rb` are byte-unchanged, and `lib/lain.rb:24-25` still reads
`lain/guard` then `lain/telemetry` — wave 1 (T1, T2) is grounded as written. The interaction-modes
and approval-ladder chunks have since moved files later waves touch (`toolset_build.rb` +131,
`rpc_thread.rb` +148, `runtime.lua` +112, `human_replies.rb` +105, `wiring.rb` +69,
`subagent.rb` +130, `projection.rb` +15). The gap is **75 commits over 223 files**, not the
handful the diffstat above suggests.

A read-only pass over the 31 facts waves 5–6 rest on returned **6 verified, 21 moved, 3 false**.
Defects 1–5, `Projection#pending`'s envelope-only filter, the `:turn`-edge consumption rule,
`inbox_view.rb:104-107`'s `fetch("question", ...)`, and `Tool::Result`'s String-or-blocks gate all
verified **exactly** — the chunk's premises are intact. The four divergences that change a card's
meaning are absorbed onto the cards below and summarized here:

- **`@command_inbox` no longer lives in `HumanReplies`** (T9, T12). The rail is now an injected
  editor adapter — `#bind_editor` (`human_replies.rb:47`), defaulting to `NoEditor` (`:26-30`),
  with `editor_reply_loop` (`:166-168`) spawning only `if @editor.attached?`. The real
  `Thread::Queue` is `rpc_thread.rb:348`, wrapped by `Neovim::CommandInbox`
  (`neovim.rb:116,133-145`). The thread-affinity constraint is unchanged; only the path's name is.
- **The protocol is already `"5"`, and its history entry was never written** (T12). `neovim.rb:41`
  and `runtime.lua:15` both read `"5"` (landed `d125aba`), but the version-history comment at
  `neovim.rb:34-40` still stops at `"4"`. `neovim_runtime_spec.rb` hardcodes the number in
  **three** places (`:250,254,255`), not two.
- **A second gate now stands between a subagent and any tool** (T10). `ChildBuilder#permitted`
  (`subagent.rb:538-543`) intersects the child's toolset with `@seam.permits` and raises
  `NoCapability` if empty, so surviving the spawn policy's attenuation is no longer sufficient.
- **`Seam` is eight members, five defaulting to Null** (T10) — `provider, context_factory, parent,
  journal, supervisor, observer, gate_policy, permits` (`subagent.rb:419-431`), not the "last
  three" the card records.

**The tool.** `Tools::AskHuman` (182 lines) writes `{"question" => string}` as a `:message`
event to `to: "human"` and resolves a `Promise` with whatever `#reply` was handed
(`ask_human.rb:87-93`, `:104-114`). `Promise` constrains the resolved value not at all
(`promise.rb:32,47`). `Event::Projection#pending` filters on the **envelope** only — `kind`,
`to` — so body shape is free (`projection.rb:38-41,56-59`). `Payload` runs the body through
`Canonical.normalize`, which recurses through nested Arrays and Hashes and deep-freezes
(`canonical.rb:35-44`), so a structured body canonicalizes and stays `Ractor.shareable?`.

**The one hard type gate** is `Tool::Result` — content must be a `String` or an `Array` of
provider content blocks; a Hash raises `InvalidResult` (`lib/lain/tool.rb:221-251`). The model
therefore sees text regardless of how structured the record becomes.

**`Tool::Input` cannot express arrays or nested objects.** `JSON_TYPES` holds five scalars
(`tool/input.rb:45-51`); `property_schema` emits a flat Hash with no `items` and no recursion
(`:132-137`); `attribute(name, :array)` raises `Unknown type :array` at class-definition time.
`TodoWrite` already works around this by overriding `input_schema` with a hand-written Hash and
re-doing its enum check by hand in `perform` (`todo_write.rb:21-27,37-76,94-102`);
`improvement_write.rb:15-20` documents the same gap and settles for a comma-separated String.
This chunk widens the DSL and migrates `TodoWrite` onto it — two callers, and the drift the
widening closes is the one `lib/lain/tool/input.rb`'s own header claims not to have. Note the
emitted schema is **not** re-validated locally on the `input_model` path (`validate_input!`
returns early, `tool.rb:196-203`); the enforcer is the provider, which is sent `strict`.

**One `AskHuman` per session, and subagents are denied it.** The only production construction
site is `wiring.rb:184-188`; `HumanReplies` is injected that same object at `wiring.rb:291`, so
the tool the model calls and the reply seam are one object. `ToolsetBuild#build`
(`toolset_build.rb:78-83`) appends `ask_human` **after** the `base` union that both child seams
attenuate from, and the class comment states the policy: "a subagent must not be able to ask the
human directly" (`:25-28`). `AskHuman` also does not override `parallel_safe?` (default `false`),
so `ToolRunner` runs it as a barrier. N pending questions is therefore impossible today —
**a wiring invariant, not a mechanical one**: `@pending` is a per-instance ivar, and
`spec/lain/frontend/neovim/inbox_view_spec.rb:246-266` already stands up two `AskHuman`s with two
simultaneously-pending promises.

**Five defects, not three.** The draft of this plan listed three; the panel pass found two more,
and the two it found are the dangerous ones.

1. `ask_human.rb:92` overwrites `@pending` with no guard, orphaning the previous promise.
2. `human_replies.rb:86` attributes every queued item to the *current* `last_question&.from`.
3. `resolve_reply` (`:121-127`) resolves whatever `@pending` is, then `ensure`-shifts the inbox
   **head**, which need not be the item that answer belonged to.
4. `ask_human.rb:111` builds the A event with `causal_parents: [@last_question.digest]` — "most
   recently asked", not "the one being answered".
5. `perform` (`:150`) pushes `@last_question.digest` into `@answered_questions`, and
   `take_answered_questions` feeds the delivery commit's causal edge. A `:turn` edge is the
   **only** thing `Projection#pending` counts as consumption (`projection.rb:44-49`,
   `status_feed.rb:367-372`). Retire the wrong digest and the answered question sticks in the
   inbox forever while an unanswered one silently vanishes — which presents as "the inbox is
   haunted", not as a stale digest.

Defects 4 and 5 are aliasing bugs on `@last_question`; they are the reason `#reply` must name the
set it answers rather than relying on an ivar.

**`InboxView` reads the old body shape.** `inbox_view.rb:104-107` does
`body.fetch("question", "(no question text)")`. Any change to the Q body that drops that key
turns every inbox line into the placeholder, silently and for the whole chunk. T6 therefore keeps
a `"question"` key holding a rendered one-line summary of the set — which also preserves ruling 3
for free.

**The nvim surface, and what already exists.** `lain://inbox` already sets **one expr fold per
pending question**, older closed and newest open, `foldminlines=0`, with `]]`/`[[` on the same
boundaries (`runtime.lua:432-513`, `doc/lain.txt:254-269`). Folds install **only** when
`RECORD_START[b:lain_view] ~= nil` (`runtime.lua:494-500`) — so a new view gets no folds unless it
registers a predicate. `lain://compose` supplies the writable round trip to copy: `buftype =
"acwrite"` (because `nofile` refuses `:write` with E382 *before* any autocommand runs), a named
buffer (E32 otherwise), `filetype = "markdown"`, a stamp on the buffer, `BufWriteCmd` that
rpcrequests **first** and clears `modified` only on success, and `BufUnload` as the abandon
signal (`runtime.lua:386-428,588-597,657-691`; `compose.rb`). `lain://request` proves a writable
markdown `lain://` buffer is existing practice.

**Thread affinity across the seam.** `Promise` wraps `Async::Variable`, so it must be resolved on
the reactor thread. Editor commands arrive on the RPC thread and are handed over through the
`@command_inbox` `Thread::Queue` polled by a fiber (`human_replies.rb:135-143`); that is the only
legal hand-off. `Compose` is a **poor** model for the waiting half — its `#settle` parks the
prompt thread because a human pressed C-g and something is waiting. Nothing waits for a question.
Copy compose's *buffer* pattern, not its *settle* pattern.

**Two recorded decisions this chunk must respect.** `runtime.lua:53-55`: "a single lain
filetype, with `b:lain_view` naming the view, **never per-view filetypes**" — which is why the
question document is a *new* buffer rather than a re-typed `lain://inbox`. And
`notify.rb:11-13`: `ask_human` notifications are informational, "answering happens at a real
surface, never a notification click" — left standing (ruling 7).

**The parsing template is `Epic::Document`'s posture, not its fence handling.** Epic is total and
loud — "`parse_markdown(to_markdown(g))` is `g` by digest, or the emit is refused loudly naming
the value it cannot write. Nothing is silently reinterpreted in either direction"
(`epic/document.rb:15-20`), raising `MalformedDocument` on an unknown mark (`:305-310`). Plan
silently drops unrecognized lines (`plan/document.rb:48-63`). **But Epic does not solve
fence-awareness — it refuses fences outright** (`epic/document.rb:109`: a description "cannot hold
a ``` fence (the grammar reads it as the acceptance-criteria block)"). This chunk cannot refuse
fences, because a fenced diff or table is the point. Ruling 5 is how it escapes the problem
instead of solving it. **Nothing in the repo round-trips markdown through nvim**: `Epic::Home`
round-trips markdown through a file on disk with no editor invocation anywhere in
`lib/lain/epic/` or `lib/lain/plan/`, and `lain://compose` round-trips free text with no grammar.

**Where docs and code disagree.** `human_replies.rb:29-32,38-43` is written as if a subagent can
already enqueue a question while the human sits idle; no code path produces that. The comment
describes the state this chunk creates, so the chunk makes the comment true. `plugin/nvim/doc/lain.txt:216-218`
omits `:LainPin`, so the command list is already one behind, and
`plugin/nvim/lua/lain/init.lua:4` is stale at "protocol 3"; T17 owns both.

**Correction (2026-08-03, found by T6).** Three cards' escalation triggers (T1, T3, T6) name
`Oracle::Definition#digest` (`lib/lain/oracle/definition.rb:59`) as the prompt-cache prefix. **It
is not.** That method folds an *oracle's* own `schema.to_json_schema` and belongs to a separate
subsystem. The tools block the prompt cache actually sees is `Toolset#to_schema`
(`toolset.rb:133`), rendered into the Request at `context.rb:162` as `tools:`. `Toolset`'s own
comment states the property that matters: two toolsets are equal iff they present the same schema
bytes, "because the schema is the whole of what the model, and the prompt cache, can see." Read
any "does this move the cache prefix?" trigger as naming `Toolset#to_schema`. T1's and T3's drift
evidence still stands — both dumped every tool's `input_schema`, which is what the toolset schema
is built from.

## Rulings

Recorded so no card re-litigates them.

1. **A question set is one `ask_human` call carrying several questions.** The reason is cost, not
   taxonomy: `AskHuman` is not `parallel_safe?`, so N separate questions are N barriers — the
   human answers, the model round-trips, asks again. That is N model turns and N context renders
   for one decision. The set collapses it to one. The price is that the set resolves as a whole
   (ruling 9).
2. **The question buffer holds exactly one set — the one being answered.** New arrivals land in
   the inbox and never touch an open buffer. This makes the `RequestBuffer` clobber defect
   ("last-writer-wins on a buffer with two writers", `request_buffer.rb:36-42`) structurally
   unreachable rather than defended against.
3. **`lain://question` is a new buffer; `lain://inbox` is untouched.** The inbox keeps filetype
   `lain`, its six syntax groups, and its existing `RECORD_START` predicate. Its line shape —
   `sender  age  text` with two-space padding — is **preserved exactly**, because the fold
   predicate and the `lainSender`/`lainAge` syntax both key off it.
4. **The comment slot is indented prose beneath the option.** `planning/interface-integration.md:509-514`
   recommends HTML comments or `> [!NOTE]` callouts, but that bullet is about **annotating plan
   diffs**, where the annotation is a side-channel on someone else's text. Here the human is
   authoring the primary content, and prose is what a human types. The citation is noted as
   *not* supporting this ruling; the ruling stands on its own reason.
5. **The parser is given the set it is parsing: `parse(markdown, set) -> AnswerSet`.** The set is
   always known (T9 opens exactly one). The rendered body region is matched **literally** against
   the set's own bytes and skipped whole, so a fence containing `- [x]` or `##` cannot be read as
   grammar and an unbalanced fence the human types cannot swallow the document. This is the
   chunk's single largest correctness risk and this signature dissolves it.
6. **The question's content digest is the generation stamp.** Compose needed a hand-rolled
   counter; content-addressing supplies one. A write whose digest is not the pending set's is
   dropped, not reinterpreted.
7. **The TTY answer path is always live.** It renders an arrival note whose *pointer text*
   changes when nvim is attached, and it always prints the set's markdown and accepts a free-text
   reply on drain. It is **not** gated on whether nvim is attached. **Corrected 2026-08-03 (T14):
   an `attached?` predicate DOES exist now** — `NoEditor.attached?` (`human_replies.rb:55`),
   `CommandInbox#attached?` (`command_inbox.rb:47`), read at `human_replies.rb:261` to decide
   whether to spawn the editor-reply fiber. That is a legitimate use: it asks whether a *surface
   exists to poll*, not whether the human may answer. The ruling stands unchanged and so does its
   real reason — attachment is not a stable fact
   (nvim dies mid-session — that is why `Compose::Detached` exists), and `/inbox` works today
   regardless of editor. Two surfaces racing one pending is normal operation and already handled:
   `resolve_reply` rescues `AlreadyResolved` (`human_replies.rb:118-127`).
8. **dunst stays informational.** `notify.rb:11-13` stands.
9. **Submitting is never blocked, and an unanswered question says so.** One promise resolves the
   whole set, so `:w` answers all N including the untouched ones. Rather than refuse the write,
   `AnswerSet` represents "unanswered" explicitly and renders it to the model as unanswered — the
   model must be able to tell "declined" from "missed", and blocking a human's write to force an
   answer is the wrong lever.
10. **No answer timeout, and deregistration rides the supervisor lease.** A pending question stays
    pending; that is the honest state, and it is visible in the inbox. A dead agent's asker is
    dropped on the same lease expiry that already reaps its actor. A fail-open timeout (an error
    Result: "the human did not answer") is a reasonable future policy and is recorded as
    follow-up 1, not built here.
11. **`x` ticks on an option line and is vim's `x` everywhere else.** `runtime.lua:753` records
    why `p` was safe to shadow — "a **nomodifiable** buffer has no use for" paste. `lain://question`
    is `acwrite` and the human types prose into it, so an unconditional `x` map would break
    deleting a character while writing a comment. The map falls through to `normal! x` off option
    lines.
12. **`<CR>` opens a set from the inbox, and `r` is repointed to the same action.** One verb, one
    vocabulary; `r`'s single-line prompt does not survive as a fast path, because a set of N
    questions has no single-line answer.
13. **Mermaid rendering is out of scope, and what is deferred is named.** `interface-integration.md:175-200`
    concludes the inline path is "nearly free on the nvim side" via `snacks.image` (already
    installed) — the cost is a terminal switch from alacritty to kitty or ghostty. That switch is
    deferred; a mermaid fence degrades to a readable code block and nothing here may depend on it
    rendering.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb`, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/**`.
- New unit `lain/question` joins `lib/lain.rb` in the value-object region (after `lain/guard`,
  before `lain/telemetry`): it depends only on `Canonical`, `Guard`, and `Freezable`. A load-time
  `NameError` means the entry is too early.
- `lib/lain/frontend/neovim/runtime.lua` is a **serial resource**: T12, T13, T15, T16 each modify
  it and are in consecutive waves. Do not parallelize them.
- `lib/lain/cli/wiring.rb` is owned by **T11 alone**. T10 and T14 consume what T11 wires and must
  not edit it.

## Open decisions

None. The three the draft left to sub-agents are now rulings 9, 10, and 12.

## Measured costs and hazards found during execution

- **`ask_human`'s tools-block entry grows 502 → 2116 bytes, roughly +400 permanent prompt-cache
  prefix tokens**, paid on every request for the whole session. Measured by T6's panel against
  `git show HEAD:`: `name` and `strict` byte-identical, only `description` (219→748) and
  `input_schema` (218→1303) move, and no other tool's entry moves. This is the price of ruling 1
  and it is charged whether or not a question is ever asked. Worth revisiting if the description
  can teach the same affordance in fewer bytes.
- **Two cards in one wave can deadlock each other's commits.** Pre-commit stashes unstaged
  *tracked* changes but leaves *untracked* files in place, so when two sibling cards each add a
  new unit, each one's untracked spec needs the other's stashed index/manifest line and **neither
  can be committed first**. It presents as `NameError` inside "An error occurred while loading",
  with the surviving example count well below the real total — the dead-worker shape, not a
  failure list. The fix is to move one card's untracked files aside, commit the other, restore,
  and commit. Cheaper alternative next time: have the second card of a pair land its index line
  in the first card's commit.
- **A spec helper can quietly narrow what an entire file tests.** `human_replies_spec`'s
  `announced` helper builds inbox items from a raw `String`, so that whole file only ever
  exercised the bare-String path — which is why nothing went red when the drain started rendering
  `AnswerSet`s from an `Announcement`. Found by T14. The lesson generalizes past this file: when a
  suite stays green through a change that should have broken it, suspect the factory before the
  assertions.
- **The default suite has at least one intermittently failing example, and it is probably
  deadline-shaped.** Two commits in this chunk failed the pre-commit hook with exactly one
  failure, and in both cases the identical staged tree ran clean afterwards both serially and
  under `parallel_rspec`. T10 independently hit the same shape and localized it: `inbox_spec` and
  `human_replies_spec` carry **3-second deadlines**, pass in isolation, and fail when siblings
  load the machine — no subagent involved. That is consistent with both hook failures, which
  happened while other agents were running suites concurrently. Worth converting those deadlines
  to something load-tolerant, or the suite will keep producing false REDs under any parallel
  work. Until then: treat a single-failure hook run as suspect, but reproduce rather than assume.

## Built during execution, beyond the cards

**`spec/support/watchdog.rb` — a stuck-example detector.** Not on any card; added because this
chunk lost time three separate ways to the same failure shape, and Joel proposed the fix.

A hung example is indistinguishable from a slow one, and under `parallel_rspec` a hung worker
reports as **fewer examples, zero failures** — the same shape a healthy run has, only smaller.
This chunk hit that twice: an editor example that ran **7m28s at ~0% CPU** before a human noticed,
and an async example that could only pass or wedge, whose killed run printed `1 example, 0
failures`.

**The first one is the argument for the tool, because two confident diagnoses were both wrong.**
The orchestrator's was a mutex cycle across the RPC boundary; T16's replacement was a fiber parked
in epoll. T16's panel disproved both — `probe_fiber.rb` shows that inside a `Sync`,
`Fiber.current == @main_fiber` is false so `session.rb:59`'s yielding branch is taken, and on
ruby 4.0.6 / async 2.42 that branch **raises `FiberError`** rather than parking. `FiberError <
StandardError`, so the 7m28s was almost certainly that raise being swallowed and retried in a
loop. **Do not carry the "parked in epoll" story forward** — the diagnosis of *where* (the spec
harness, not the library) and the fix both stand, but the mechanism was misdescribed twice before
anyone had a stack to read, because the run never ended.

One supervisor thread per process watches a single slot the `around` hook rewrites per example —
**not** a thread per example, which measured 3:11 against the single supervisor's 2:22. No locks:
`parallel_tests` forks processes, so exactly one example is ever in flight, and a stale slot could
only ever fire at a genuinely slow test. The budget is **30s and it fails**, which is a
stuck-detector rather than a performance gate — p99 here is under a second and the slowest single
example in the heaviest file is ~0.6s. On a strike it names the example, the elapsed time, any live
nvim children, and 25 frames of every thread, so the report says what was waiting on what.

Verified against a real mutex deadlock and a blocked `IO#read` (both caught, exact frames), and
against 9443 examples with **zero false strikes**. It is the outermost `around`, which is why
`spec_helper` requires it ahead of the support glob — the hooks that spawn editors and daemons are
themselves `around`s, and a watchdog inside them would miss a hang in the spawn.

**Related policy Joel set, worth honouring in review:** any example over ~1s at p99 is too slow and
should be addressed on its own merits; the 30s budget is only where "slow" has clearly become
"stuck".

## Suite performance and allocations — MEASURED 2026-08-03, mostly negative results

Ran before proposing any work, and it collapsed the proposal: **the suite does not need
optimising, it needs invoking correctly.**

**The finding.** Serial `bundle exec rspec` is **155s**; `rake pspec` is **~30s** for the identical
9452 examples. The suite is subprocess-bound (44s user against **92s system**) because the
isolation/forge/workspace specs drive real `git` and the frontend specs drive real `nvim`/`tmux` —
which are the subjects under test, so the cost is not removable, but it parallelises almost
perfectly. CLAUDE.md documented the serial command as the default, which is what every run in this
chunk used. Fixed there, with the numbers.

**Worker count is already optimal and more is worse:** `-n 7` **18s**, `-n 12` 22s, `-n 16` 29s on
a 16-core box. The Rakefile's comment already explained why (each worker loads the whole suite, so
the ceiling is memory), and `spec_workers` was already right.

**Measured and rejected — do not retry these without new evidence:**
- `TMPDIR=/dev/shm`: **-8.6%** at suite scale (a microbenchmark promised 16.5%; the page cache
  already had it).
- `core.fsync=none` / `fsyncMethod=nothing`: **nothing**. Git here is spawn-bound (~5ms/spawn),
  not fsync-bound.
- **Mocking `git`**: the `shell_out_factory` seam already exists and the heavy specs already use
  it — for **failure injection**. The semantics under test are git's own, so a fake would test the
  fake. The one real inefficiency is that every example pays a 5-spawn `init_repo` even when it
  immediately replaces git with an exploding lambda; a copied template repo is 27.1ms → 3.5ms, but
  setup is only ~5% of those files' time, so it is worth ~2s of 155s.
- Sleeps: 37 calls, but the large ones (3600s, 60s, 30s) are inside stubs testing timeouts and
  never fire. Real waste is ~3s.

**Allocations: no hot-path problem found.** `Canonical.digest` — the genuine per-turn path, one per
`Timeline#commit` — is **24 allocations/call**. `Question::Set.from_body` is 178/call, but it runs
per *gesture* and per tool call, never per turn. The allocation-heaviest groups are spec-side
(`tty_spec` at 25.8% of 4.25M in its subset), not library code. `test-prof` ships `memory_prof`, so
none of this needed a new gem.

**If a real perf chunk is ever wanted**, the remaining levers are small and known: the template-repo
setup (~2s), the ~3s of genuine sleeps, and whatever `TAG_PROF`/`EVENT_PROF` turn up. The 5x was
free.

## Proposed next chunk — suite performance and allocations

Joel's call, to run **after T17 lands**. Recorded here with the data this chunk already gathered,
so the planning pass starts from measurements rather than guesses.

**Tooling already present, currently dormant** — no new dependencies needed to start:
`test-prof` (`TEST_STACK_PROF=1` flamegraphs via `stackprof`, `TAG_PROF=type`, `EVENT_PROF=...`,
all env-gated in `spec_helper.rb:23-26`), `stackprof`, and `benchmark-ips`. `spec/support/store_fetch_count.rb`
is the surviving artifact of a previous pass and is the shape to imitate. **No allocation profiler
is in the Gemfile** — `memory_profiler` is the likely addition.

**What this chunk measured, which is where to point it first:**
- Full suite **~2:04–2:22 wall** for **9443 examples** over 7 `parallel_rspec` workers.
- **p99 is already under a second**, and the slowest single example anywhere is ~0.6s
  (`worktree_handback_spec`). So the win is in aggregate churn, not in outliers — the heavy files
  are heavy by example *count*, not by any one example.
- `worktree_handback_spec` **28.7s over 72 examples**, `forge/promotion_spec` **10.7s over 32**:
  both shell out to real `git`, which is the largest single cost centre observed.
- **115 `:nvim` examples spawn real headless editors**, and they are opt-**out**, so they run in
  every default suite on any machine with nvim installed.
- **`inbox_spec`/`human_replies_spec` carry 3-second deadlines** that flake under machine load
  (see the hazards section). Making those load-tolerant belongs in this pass.

**Allocation angles this chunk newly exposes:** `Canonical.dump` string churn on the per-turn path;
digest interning (`-@`) applied inconsistently — T2 deliberately *dropped* an intern on a 64KiB
body, and `Evidence` interns short repeated values, so the policy is worth stating once; and the
nine new value objects this chunk added, none of which have been allocation-profiled on the hot
`Context#render` path that the prompt cache depends on.

**Standing policy to enforce while there:** any example over ~1s at p99 is too slow on its own
merits; the 30s watchdog budget is only the stuck-detector.

## Follow-ups (record as tickets, do not build here)

1. A fail-open answer timeout for a parked subagent question (ruling 10).
2. `snacks.image` + a kitty-protocol terminal, which would make mermaid render inline (ruling 13).
3. Whether `Notify#question` should carry the set's question count (ruling 8 keeps it
   informational; the *text* could still be richer).
4. **Whether `Tools::RequestReview` should follow `ask_human` out of the subagent denial list.**
   Added 2026-08-03 during execution. `toolset_build.rb:22-32` denies it because "it is an
   ask_human whose subject is a file, it PARKS until the human answers, and a child that could
   open one would hold an artifact's baton in a conversation nobody is watching." This chunk
   makes a child's park visible in the inbox and routable by digest, which retires the second and
   third clauses. The baton semantics are `Epic`'s and were not analyzed here, so T10 deliberately
   leaves the clause standing and the question open.
5. **Backfill the `neovim.rb` protocol version-history entry for `"5"`.** Folded into T12 rather
   than deferred, but recorded here because it is a pre-existing gap `d125aba` left, not something
   this chunk introduced.
6. **An array `length:` emits `minItems`/`maxItems` but its local ActiveModel message still says
   "maximum is 3 characters".** Found by T1's panel (NEW-2); not a one-line fix, since the message
   comes from `LengthValidator`. The schema the model sees is correct; only the local error prose
   is wrong.
7. **`Approval::Rule::Call.for` is a second `Input.build` caller whose failures are still
   unprefixed.** Pre-existing, and contained today by `Escalation`/`Oracle::Definition`. T1's
   expansion fixed the `Tool#call` path only.
9. **A user's `[[approval.deny_tool]] todo_write` is silently inert today, and would start being
   honoured if `todo_write` ever became gated.** Found by T3's trace. `Gate#handles?` is
   `effect.approval? || tool.requires_approval?` and `TodoWrite#requires_approval?` is `false`, so
   the ladder is never entered and `Rule::Call.for` never runs. Now that `TodoWrite` declares an
   `input_model`, the `Rules` rung *would* build a subject rather than abstain `Undeclared` — a
   correctness improvement, but nothing in the tree triggers it. Verified at runtime: `handles?`
   false, policy consulted for `[]`.
10. **`Tool#input_schema`'s raw-Hash branch, `Tool::SchemaValidator`, and `Tool#dig` now have no
    in-tree tool caller**, since every shipped `Lain::Tools::*` declares an `input_model`. Left in
    place deliberately — `Tool` is a public surface and a documented seam with no current caller
    is not dead code. Revisit only if the seam is ever declared private.
11. **`Risk::Keepsake.for` and `Remembered::Entry.for_call` read `input.attributes`, which leaks
    nested `Input` objects.** Found by T3's panel; `TodoWrite` is the first shipped
    array-of-objects input and therefore the first counterexample. Measured:
    `Ractor.shareable?(Risk.classify(todo_write_call))` is **false** (true for every flat-input
    tool), violating `Keepsake`'s stated invariant, and `Canonical.dump` raises `UnsupportedType`
    — after which `Persister#remember` would blame the wrong thing. Latent only because
    `TodoWrite` is ungated (see follow-up 9). The fix is `.attributes` → `.to_h`, since T1 made
    `to_h` plain data recursively — **but verify first that `to_h` and `.attributes` agree for
    every flat input**, or previously remembered approvals will silently stop matching.
    `remembered.rb:352`'s comment ("`Tool::Input` declares JSON scalars and nothing else") is now
    false and belongs in the same change.
12. **`blank_ok:` reports "can't be nil" when the field was simply omitted.** In
    `Tool::Input.require_field`'s `blank_ok` branch, so it affects every `blank_ok:` field, not
    just `todos`. Nothing was nil; the field was absent. A message naming the wrong condition is
    the kind of thing that costs someone an hour.
13. **`Gate#call:299` raises before `record(...)`, bypassing its own fail-closed ordering.** Found
    by T6's panel. `#ask(String)` now has five `ArgumentError` modes (unclosed fence, >64KiB,
    blank, invalid UTF-8, nil) which are rescued on the model path but not on the `#ask`-duck
    path. Latent only because the CLI hands `Gate` a `Prompt`, not an `AskHuman`. Owed to whoever
    first wires an `AskHuman` as a gate surface. T6's own view, which I share: **document, do not
    rescue** — a rescue there can only hand the human bytes the caller did not write.
14. **`notify.rb:144` needs a `--` separator before the question text in dunstify's argv.** A
    question whose summary begins with `-` is otherwise parsed as a flag. Outside T6's files.
    **Widened by T6's re-review:** the gap *is* reachable through the summary on the
    multi-question path, because the summary `strip`s — `"   -A hack,Yes\nmore"` becomes
    `"-A hack,Yes (+1 more)"` and `"  --help\n…"` becomes `"--help (+1 more)"`. Pre-T6 no body
    could start an argv element with `-`. Same exposure class, wider input set; the fix is still
    one `--` at `notify.rb:144`.
15. **`Approval::Gate#await` abandons its promise on timeout, which would permanently wedge a real
    `AskHuman` asker** once the single-set invariant is enforced — the abandoned set stays
    outstanding and every later `#ask` is refused. Not live today because production wires
    `CLI::Prompt`, not an `AskHuman`, as the gate surface. Found by T7. Related to follow-up 13:
    both are about `Gate` treating an `AskHuman` as an interchangeable prompt surface when it is
    now a stateful one.
16. **The document heading grammar is duplicated between `Question::DOCUMENT_HEADING` and
    `Question::Document::HEADING`**, because `Document` loads after `Question` and a value must
    not reach forward to its renderer. The duplication is loud (both sides name the other) and
    mechanically pinned (`document_spec.rb` iterates `KIND_LABELS.each_value`, so a new label is
    caught too). `Lain::Blankness` at `lain.rb:24` is now the precedent for the cleaner placement:
    a shared constant below both. Deliberately not moved during T5.
17. **`answer_set.rb:249` still refers to `Rules.fenced!` in prose**, which moved to
    `Question::Renderable` during T5's fix round. One stale comment reference; flagged, untouched.
27. **An abandoned set is never marked answered, so every later advance offers it first.** Found by
    T16's re-review. Ctrl-C or a timeout withdraws a set without it passing through `deliver`, so
    the editor's advance keeps handing it back. Loud rather than silent — the human sees the same
    question — but it is a loop they cannot advance out of without answering it.
26. **`InboxView`'s `@answered` is a tombstone Set beside `@pending`, and the pruning is
    unobservable from outside.** T16's panel makes the case for `Item#answered?` instead: one
    ordered collection, where "answered but not yet retired" is a property of the row rather than a
    second collection that must agree with the first. The leak it caused is fixed (`consume` now
    drops the tombstone with the row, pinned by a spec that reaches in on purpose because nothing
    black-box can see it), but the shape is what made the leak invisible.
25. **Returning the cursor to `lain://inbox` after the last set is submitted.** T16's AC3 changed
    shape: the advance is **silent** when nothing remains, because the only rail into the editor
    renders a `WarningMsg` and "you answered the last one" is not a warning. Asserted as no second
    document, no set held, no refusal, row still listed. Actually *focusing* the inbox needs a
    focusing lua entry point, which this chunk's cursor rule (`set_request` never focuses or jumps,
    so a re-render cannot steal the cursor mid-edit) puts outside T16's scope.
24. **Two "read until it settles" loops now exist side by side**, and they already disagree on
    wording: `Inbox#accepted` and `Reply#read` (`human_replies.rb`). This is not theoretical — the
    `Encoding::CompatibilityError` blocker T14's panel found lived *in that gap*, one line above
    the guard written to prevent it. The specific defect is closed; the duplication that produced
    it is not. Rated by a simplification pass as one of three cleanups worth doing inside this
    chunk rather than after it — deliberately **not** folded into T16, which is already carrying
    its own ACs plus the editor consumer and the `Surfaces` extraction. Do this next, with
    follow-ups 8 and 16.
23. **`Directory#size` counts names, not registrations**, so a registration stranded with zero
    names is invisible to the object's entire public surface — T10's spec had to reach for
    `@registrations` to see one. Found while proving that a raise inside `Actor#launch` no longer
    strands a registration. The leak is closed; the blind spot in the surface is not.
22. **May an epic child open a review?** `Tools::RequestReview`'s denial reason in
    `toolset_build.rb` was written as "an ask_human whose subject is a file, it PARKS until the
    human answers, and a child that could open one would hold an artifact's baton in a
    conversation nobody is watching." T10 rewrote it, because **parking no longer disqualifies** —
    a child's park is now visible in the inbox and routable by digest. The **baton** still does.
    Whether an epic child may open a review belongs to `Epic`, not here. Supersedes follow-up 4,
    which asked the same question from the other side.
21. **The inline `human>` path delivers a bare typed line where the drain and the editor both
    deliver a rendered document.** So what the model receives depends on which surface the human
    happened to use — the same reply arrives as prose in one case and as a rendered `AnswerSet` in
    the other two. Found by T14, which judged it a contract decision rather than a bug and
    recommends a card. Worth deciding deliberately: ruling 9 promises the model can tell declined
    from missed, and that promise is only kept on two of the three paths.
20. **`x` on a *closed fold* deletes the whole fold.** Vanilla vim — `x` is `dl`, an operator —
    verified against a control buffer carrying no lain map, and inherited faithfully rather than
    papered over. Not a defect; recorded so it is not re-discovered as one.
    (**Corrected 2026-08-03:** T13's hand-back also claimed "dot-repeat is lost on the
    fall-through". That was **backwards** — its panel showed `x` then `.` on prose works perfectly,
    because `normal!` loads the redo buffer. What was broken was `.` on the **tick** path, which
    silently replayed the previous real change onto an option line. Fixed in T13's own round; the
    textlock claim that motivated the wrong diagnosis is real (`E565`) but does not force the
    conclusion, since `operatorfunc` + `g@l` writes nothing under textlock.)
19. **Extract a `Surfaces` object out of `Frontend::Neovim`.** After T12 extracted `CommandInbox`
    into its own file, the class sits at **109/110** `Metrics/ClassLength` — one line of headroom,
    with no cop loosened. The next card that adds anything to `neovim.rb` must extract first, and
    `Surfaces` is the seam T12 named. Recorded so it is budgeted rather than discovered.
18. **Rename `HumanReplies`' `ask_human:` keyword to `directory:`.** It now receives an
    `AskHuman::Directory`, not an asker, so the name actively misleads on a seam three cards
    consume. Kept during T11 only because renaming would have broken a sibling's live
    `:nvim` specs mid-wave. Three call sites plus a spec helper.
8. **Split `Question::Rules`.** T2's panel judged it already two responsibilities — three
   `(body, subject)` reader functions against eleven `(value, field)` validators — but splitting
   while it has one caller yields a one-caller object. Split when T4's `Answer`/`AnswerSet` makes
   it the second caller, which is also when `Metrics/ModuleLength` starts to bind (~90 of 100).

## Waves

```
Wave 1: T1, T2
Wave 2: T3 (←T1), T4 (←T2), T6 (←T1,T2)
Wave 3: T5 (←T2,T4), T7 (←T6)
Wave 4: T8 (←T7), T9 (←T5)
Wave 5: T11 (←T8), T12 (←T9)
Wave 6: T10 (←T11), T13 (←T5,T12), T14 (←T4,T11)
Wave 7: T15 (←T13)
Wave 8: T16 (←T15)
Wave 9: T17 (←T16)
```

Critical path: **T2 → T4 → T5 → T9 → T12 → T13 → T15 → T16 → T17** (9 cards, the
document-and-editor chain).

## Tasks

### T1 — Teach `Tool::Input` array and nested-object fields   [wave 1] [risk: high]   ✅ LANDED `cd584a7`

**Depends on:** none
**Files:** `lib/lain/tool/input.rb`, `spec/lain/tool/input_spec.rb`
**Scope expanded during execution (2026-08-03), orchestrator-authorized:** also
`lib/lain/tool.rb`. `Input.build` **raises** for a failure with no per-attribute home — a
malformed array element, since only the raw input knows its index — which bypasses the `valid?`
path carrying the `invalid input for <tool>:` prefix. `Input` has no access to the tool name, so
the prefix cannot be restored from inside the card's two files. `validate_with_model` now routes
through `built_input`/`invalid!`, which also closes the **pre-existing** unprefixed unknown-key
path. Applied by the orchestrator with a spec.
**Reuse:** `apply_enum` (`tool/input.rb:153-156`) is the constraint-bridge idiom to extend.
`todo_write.rb:37-64` is the hand-written schema this must be able to express **exactly** — it
carries a `description` on every nested member and `additionalProperties => false` on both
levels.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an array-of-scalars field emits a typed items schema
  Given an Input declaring an array field of strings
  When its JSON schema is generated
  Then the property is type "array" with an items schema of type "string"

Scenario: an array-of-objects field emits a closed, described items schema
  Given an Input declaring an array field whose elements have a required string and a string
  When its JSON schema is generated
  Then the items schema is an object naming both, each carrying its declared description,
    with only the first required and additionalProperties false

Scenario: element values are coerced, not passed through raw
  Given an Input declaring an array of objects with an integer member
  When it is built from a payload whose member arrived as the String "30"
  Then that member reads back as the Integer 30

Scenario: a malformed element is refused by name
  Given an Input declaring an array of objects with a required member
  When it is built from a payload with one element missing that member
  Then InvalidInput is raised naming the field and the element index

Scenario: an enum on an element member reaches the emitted schema
  Given an array-of-objects field whose member has an inclusion validator
  Then the items schema carries that enum
```
→ spec file: `spec/lain/tool/input_spec.rb`

**Escalation triggers:**
- `spec/lain/tool/input_spec.rb:77-93` asserts the WHOLE schema Hash structurally, and
  `:178-217` asserts property key **order** is declaration order. Extending both is expected; if
  either existing shape changes, stop — that is a regression.
- `Oracle::Definition` folds `schema.to_json_schema` into a `Canonical.digest`
  (`lib/lain/oracle/definition.rb:59`), and the tools block is the prompt-cache prefix. If any
  **existing** tool's emitted schema changes by one byte, stop and name which tool.
- `attribute(name, :array)` raises in the ActiveModel registry. If the approach registers a
  custom `ActiveModel::Type`, confirm `fields[name.to_s] = { type: type.to_s }` still yields a
  JSON type the emitter can read — a stringified object silently emitting `"string"` is the
  failure mode.

---

### T2 — `Question` and `QuestionSet` value objects   [wave 1] [risk: medium]   ✅ LANDED `9fbae30`

**Depends on:** none
**Files:** `lib/lain/question.rb`, `lib/lain/question/set.rb`, `spec/lain/question_spec.rb`,
`spec/lain/question/set_spec.rb`
**Reuse:** `Lain::Guard` (`lib/lain/guard.rb:8-16`) — a frozen value object must never
`include ActiveModel::Validations` itself. The three freezing verbs from
`approval/gate/adjudicator/evidence.rb:150-160`. `WorkerEnv` (`lib/lain/worker_env.rb:29-38`) is
the deep-freeze exemplar.
**Shared-file wiring:** `require_relative "lain/question"` in `lib/lain.rb`, after `lain/guard`
and before `lain/telemetry`.

**Acceptance criteria:**

```gherkin
Scenario: a question set is deeply frozen and shareable
  Given a set of two questions, one single-select and one multi-select
  Then the set is deeply frozen and Ractor.shareable?

Scenario: a set round-trips through a canonical body
  Given a question set
  When it is converted to a body Hash and rebuilt from that Hash
  Then the rebuilt set equals the original

Scenario: the body Hash canonicalizes
  Given a question set converted to a body Hash
  When it is passed to Canonical.normalize
  Then it normalizes without raising and the result is deeply frozen

Scenario: option ids are unique within a question
  When a question is built with two options sharing an id
  Then ArgumentError is raised naming the duplicated id

Scenario: a set refuses zero questions
  When a set is built with an empty question list
  Then ArgumentError is raised

Scenario: an oversized body is refused, never truncated
  When a question is built with a body beyond the documented maximum
  Then ArgumentError is raised naming the size
```
→ spec files: `spec/lain/question_spec.rb`, `spec/lain/question/set_spec.rb`

**Escalation triggers:**
- The body must **not** be clamped the way `Evidence` clamps (`evidence.rb:157-160`). A clamped
  body can end mid-fence, and a document carrying an unterminated ``` fence is exactly the
  failure ruling 5 exists to prevent. `Evidence` clamps because of the NDJSON line; clamp at the
  journal render if needed, and refuse loudly here.
- `Canonical.normalize` accepts only nil/true/false/Integer/finite Float/String/Symbol as leaves
  (`canonical.rb:35-44`); Hash keys must be String or Symbol, and a Hash holding both `:a` and
  `"a"` raises `AmbiguousKey`. If the body shape needs any other leaf type, stop.
- A constant assigned **inside** a `Data.define(...) do ... end` block binds to the enclosing
  module, not the Data class (`evidence.rb:80-82`). Reopen the class after the block.
- If `Ractor.shareable?` is false, the offender is almost certainly an interpolated or
  `Symbol#to_s`-derived String. `be_deeply_frozen`'s failure message names the offending path.

---

### T3 — Migrate `TodoWrite` onto the widened field DSL   [wave 2] [risk: medium]   ✅ LANDED `9bd5a26`

**Depends on:** T1
**Files:** `lib/lain/tools/todo_write.rb`, `spec/lain/tools/todo_write_spec.rb`
**Reuse:** the array-of-objects field from T1. `improvement_write.rb:21-33` is the
inclusion-validator-to-enum pattern that replaces the hand-rolled status check at
`todo_write.rb:94-102`.
**Shared-file wiring:** none

**Landed-T1 note (2026-08-03) — the AC you must add, and why.** T1's panel found that
`blank_ok: true` did not work on an array field: `[]` was refused. That matters here because
**`todo_write.call({"todos" => []})` succeeds on main today** — it reports "todo list replaced
with 0 item(s)", which is how an agent clears its list — and the first cut of the DSL would have
turned it into an error Result. The schema-equality AC **cannot see this**: the panel removed
`blank_ok: true` and the emitted schema stayed byte-identical while behaviour changed. Schema
bytes are not behaviour, and this card's headline AC only checks bytes.

So: **`spec/lain/tools/todo_write_spec.rb` currently has zero occurrences of an empty todos
list.** Add an AC pinning `TodoWrite.call({"todos" => []})` on the **real tool**, asserting the
existing success shape, alongside the byte-equality one. T1 already ships a group building the
exact declaration this card will use (sourcing `TodoWrite::STATUSES` so it cannot drift) — lift
it, and keep `blank_ok: true` on `todos`. Note that `blank_ok:` now **raises** unless `required:`
is also declared.

**Acceptance criteria:**

```gherkin
Scenario: the emitted schema is unchanged by the migration
  Given TodoWrite's input schema before and after the migration
  Then the two are equal, including key order and every nested description

Scenario: a bad status is refused before perform runs
  When todo_write is called with a status outside the three allowed words
  Then InvalidInput is raised naming the offending status

Scenario: perform receives coerced items rather than a raw Hash
  When todo_write is called with a well-formed list
  Then the session's written todos match the input in order
```
→ spec file: `spec/lain/tools/todo_write_spec.rb`

**Escalation triggers:**
- **The contract changes here, deliberately.** `todo_write_spec.rb:184-187` pins "reports an
  error Result rather than writing", but under `input_model` `Tool#call` raises `InvalidInput`
  before `perform` runs (`tool.rb:196-210`) — no Result can be returned. Renegotiate that spec to
  a raise as part of this card; the handler converts it downstream (`tool.rb:22-26`). Do **not**
  keep the hand-rolled check to preserve the old shape — that is declining the card.
- The schema-equality AC is the point. If the emitted schema *must* change to pass, stop: T1's
  emitter cannot express what `TodoWrite` already promises the model, and that is T1's defect.

---

### T4 — `Answer` and `AnswerSet` value objects   [wave 2] [risk: medium]   ✅ LANDED `2cbc745`

**Depends on:** T2
**Files:** `lib/lain/question/answer.rb`, `lib/lain/question/answer_set.rb`,
`spec/lain/question/answer_spec.rb`, `spec/lain/question/answer_set_spec.rb`
**Reuse:** the T2 freezing and Guard idioms. `NOTHING_AT_ALL`
(`approval/gate/adjudicator/evidence.rb:83`, with `.blank?` at `:105-107`) — the repo's
whitespace predicate, which exists because a U+00A0 answer once passed `strip != ""` and let a
bare APPROVE through. **Any "did the human actually write a comment" test must use that
predicate, not `strip.empty?`.**
**Shared-file wiring:** index line in `lib/lain/question.rb`.

**Landed-T2 note (2026-08-03).** `Question::Rules` is ~90 lines against `Metrics/ModuleLength`'s
100, so the next shared validation rule does **not** fit there — give it a new home rather than
loosening the cop (CLAUDE.md forbids the loosening). `Question::Fence` and `Rules` nest inside
`Question` because `Metrics/ClassLength` excludes nested modules; that was verified empirically,
not assumed. Reuse `Rules.textual`, `Rules.required`, `Rules.string_keyed` and `Rules.members!`
rather than re-deriving them, and note that `include Enumerable` on a `Data` shadows `Data#to_h` —
`AnswerSet` will hit it exactly as `Set` did, and `Set` now pins its `to_h` with a direct spec.

**Acceptance criteria:**

```gherkin
Scenario: an answer set renders to the text the model receives
  Given a set answering one single-select with a comment and one multi-select without
  When it is rendered for the model
  Then the text names each question, its chosen labels, and the comment

Scenario: an unanswered question renders as unanswered
  Given a set where one question was left untouched
  When it is rendered for the model
  Then that question is named and reported as unanswered, not omitted

Scenario: a whole-set free-text answer is representable
  Given a set answered as unstructured prose rather than by selection
  When it is rendered for the model
  Then the prose is carried and the record distinguishes it from a selection

Scenario: a whitespace-only comment is no comment
  Given an answer whose comment is a non-breaking space
  Then the answer reports no comment

Scenario: an answer set is deeply frozen and shareable
  Then the set is deeply frozen and Ractor.shareable?

Scenario: an answer names a question that is not in the set
  When an answer set is built citing an unknown question id
  Then ArgumentError is raised naming the id

Scenario: a single-select question refuses two selections
  When an answer selects two options for a single-select question
  Then ArgumentError is raised naming the question
```
→ spec files: `spec/lain/question/answer_spec.rb`, `spec/lain/question/answer_set_spec.rb`

**Escalation triggers:**
- The rendered text becomes `Tool::Result` content, which must be a String
  (`lib/lain/tool.rb:221-251`). If the rendering wants to be an Array of content blocks, stop —
  no tool in the repo uses that arm.
- Rulings 7 and 9 both depend on this card's shape: the free-text arm is what the TTY always uses
  (T14) and "unanswered" is what ruling 9 promises the model. If either cannot be represented
  without a second class, stop rather than inventing one downstream.

---

### T5 — `Question::Document`: render a set, parse the edit back   [wave 3] [risk: high]   ✅ LANDED `263047e`

**Depends on:** T2, T4
**Files:** `lib/lain/question/document.rb`, `spec/lain/question/document_spec.rb`
**Reuse:** `Epic::Document`'s **posture** — module-scope regexes, one mark map read both
directions (`STATUS_MARKS`/`MARK_STATUSES`, `epic/document.rb:26-47`), `MalformedDocument` naming
the line (`:305-310`), and the `STRIPPED_BYTES` enumeration of byte shapes that break a round
trip (`:88-128`). Do **not** copy its fence handling: it refuses fences (`:109`), which this
document cannot.
**Shared-file wiring:** index line in `lib/lain/question.rb`.

**Landed-T2 note (2026-08-03) — two things settled upstream, and one open question for you.**
`Question::Fence` already enforces CommonMark fence balance on a question body at construction
(≥3 backticks or tildes, closed only by the same character at ≥ length, ≤3-space indent), so a
body reaching you **cannot** carry an unterminated fence. That removes one failure mode from this
card, but **not** the one ruling 5 exists for: a body may still contain `- [x]` and `##` lines,
and the literal-match-and-skip-whole design is still what makes them safe. Question ids are
refused if whitespace-padded, so a backtick-delimited code span cannot silently re-read one id as
another. **Open for you to rule:** ids differing only by case are both currently accepted. If your
grammar case-folds anywhere on the way back, say so and T2's `distinct!` needs to fold too —
decide it explicitly rather than inheriting it.

**Acceptance criteria:**

```gherkin
Scenario: parsing takes the set it is parsing
  Given a rendered document and the set it was rendered from
  When they are parsed together
  Then an answer set for that set is returned

Scenario: the round trip is identity for an arbitrary answer set
  Given an arbitrary answer set rendered onto its question set
  When the markdown is parsed back against that same question set
  Then the result equals the answer set it was rendered from

Scenario: re-rendering a parsed document is byte-identical
  Given a rendered document parsed and rendered again
  Then the two renderings are byte-identical

Scenario: a ticked checkbox becomes a selection
  Given a rendered set whose second option line has been ticked
  When the markdown is parsed
  Then the answer set selects exactly that option

Scenario: indented prose beneath an option becomes that option's comment
  Given a rendered set with an option ticked and two indented lines beneath it
  When the markdown is parsed
  Then the answer carries both lines as the comment for that option

Scenario: a question body containing grammar-shaped text is never read as grammar
  Given a set whose question body contains a fenced block holding "- [x] no" and "## no"
  When the document is rendered and parsed back
  Then no selection was taken from the fence and the parse succeeds

Scenario: an unbalanced fence typed by the human cannot swallow the document
  Given a rendered set where the human's comment contains a lone ``` line
  When the markdown is parsed
  Then later questions still parse and their selections are recovered

Scenario: an unknown line is refused, never reinterpreted
  Given a rendered set with a stray unindented line inserted mid-question
  When the markdown is parsed
  Then MalformedDocument is raised naming the line number

Scenario: a mangled checkbox mark is refused by name
  Given a rendered set where a checkbox mark has been replaced with "?"
  Then MalformedDocument is raised naming the mark and the legal marks

Scenario: arity is recoverable from the text alone
  Given a rendered document
  Then a single-select question's options are distinguishable from a multi-select question's,
    and each question's boundary is recoverable, without consulting the set
```
→ spec file: `spec/lain/question/document_spec.rb`

**Escalation triggers:**
- Ruling 5 is what makes the fence ACs achievable: the body region is matched **literally**
  against the set's own bytes and skipped whole. If the implementation finds itself writing a
  fence-state tracker, stop — that is the design this ruling exists to avoid, and it owns a
  failure mode (unbalanced fence) a human can produce by typing.
- The last AC exists for T13: the `x` keymap must know an option's siblings and its question's
  arity from buffer text alone, with no RPC. If arity cannot be encoded in the text, stop — T13
  is unbuildable as specified.
- If round-trip identity can only pass by normalizing the human's whitespace, say exactly what
  is normalized and pin it. Epic enumerates its stripped bytes for this reason.

---

### T6 — `AskHuman` accepts and emits question sets   [wave 2] [risk: high]   ✅ LANDED `8c48a5c`

**Depends on:** T1, T2
**Files:** `lib/lain/tools/ask_human.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** T1's array-of-objects field for the questions list; T2's `QuestionSet` body
conversion. `Event::ChainWriter#put` (`event/chain_writer.rb:66-75`) is unchanged — the body is
just richer. `lineage.rb:78-83` is the precedent for a body-level discriminator a reader keys on
without parsing prose.
**Shared-file wiring:** none

**Landed-T2 note (2026-08-03) — a constructor you may have expected is gone.**
`Question.new(options: [{...hash...}])` no longer accepts raw Hashes; `Rules.members!` gives
`Question#choices` and `Set#asked` one strict policy, so **`Question::Set.from_body` is the way in
from raw data**. Build `Option`/`Question` objects explicitly or go through `from_body`. Also:
`to_body` returns a fresh copy, so merging the `"question"` summary key into it is safe and does
not touch the frozen set.

**Acceptance criteria:**

```gherkin
Scenario: a set is emitted as one message addressed to the human
  Given ask_human is called with two questions in one set
  When the tool emits
  Then one :message event is addressed to "human" carrying both questions

Scenario: the body still carries a one-line summary under the old key
  Given an emitted question set
  Then the body's "question" key holds a single-line summary of the set

Scenario: the emitted body rebuilds the set
  Given an emitted question set
  When the event body is read back through QuestionSet
  Then the rebuilt set equals what was asked

Scenario: a bare question still works
  Given ask_human is called with a single question and no options
  Then the set holds one free-text question and the human's typed reply resolves it

Scenario: the model receives text, not a Hash
  Given a question set answered with one selection and a comment
  When the tool call completes
  Then the tool result is ok and its content is a String naming the selection

Scenario: the description teaches the affordance
  Then the tool's description states that the question body is markdown, how to choose
    between one question and several, and that options are optional
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- The `"question"` summary key is **not** decorative: `inbox_view.rb:104-107` falls back to
  `"(no question text)"` without it, which would blank every inbox line from this wave until T15.
  If the summary cannot be a single line, stop — ruling 3 pins the inbox line shape exactly.
- `ask_human_spec.rb:57-63` asserts `store.size == before_size + 2` (envelope plus out-of-line
  payload). If a richer body changes that count, stop: the payload is no longer one object.
- `Oracle::Definition#digest` folds this tool's schema (`oracle/definition.rb:59`) and the tools
  block is the prompt-cache prefix. This card **moves those bytes on purpose**; confirm nothing
  else in the tools block moves with it.
- Do **not** touch `@pending`'s shape or `#reply`'s signature here; T7 owns both.

---

### T7 — `#reply` names the set it answers   [wave 3] [risk: high]   ✅ LANDED `fe64985`

**Depends on:** T6
**Files:** `lib/lain/tools/ask_human.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** `take_answered_questions` (`ask_human.rb:133-137`) already accumulates a *list* of
digests, so the delivery-commit side is already shaped for this. `Approval::Queue::Pending`
(`approval/queue.rb:67-79`) is the prior art for a decided-once object.
**Scope note:** this card fixes the **aliasing** defects (4 and 5) and enforces the
single-pending invariant (defect 1). It does **not** make one asker hold N pendings — no
production path does that, because `parallel_safe?` is false and T10 gives each child its own
asker. Routing across askers is T8's job.

**Acceptance criteria:**

```gherkin
Scenario: the A event cites the question it answers
  Given a set that has been asked and answered
  Then the answer event names that set's event among its causal parents

Scenario: the delivery commit retires the answered set
  Given a set asked and answered
  When the answered digests are handed over
  Then they name that set, and the projection stops listing it once a turn cites it

Scenario: replying to a set that is not pending fails loudly
  When a reply names a digest with no pending promise
  Then NoPendingQuestion is raised naming the digest

Scenario: replying twice to one set is refused
  Given a set already answered
  When a second reply names the same digest
  Then Promise::AlreadyResolved is raised and nothing is written to the Store

Scenario: asking while a question is outstanding fails loudly
  Given a set already pending on this asker
  When another set is asked on the same asker
  Then it is refused, and the first promise is still pending
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- Defect 5 is the one that presents as "the inbox is haunted": a `:turn` causal edge is the
  **only** consumption signal (`projection.rb:44-49`), so retiring the wrong digest strands the
  answered question and silently vanishes an unanswered one. Its AC must observe the projection,
  not just the returned digest list.
- `spec/lain/approval/gate_probe_spec.rb:174-178` pins "does not silently cross-resolve when one
  AskHuman-shaped asker serves two gates", commented `# last-write-wins, AskHuman's shape`. The
  last AC here **removes** last-write-wins. If that spec asserts the old behaviour is correct
  rather than merely current, stop and confirm.
- `#reply`'s signature changes and its two callers (`human_replies.rb:122,139`) belong to T11.
  Coordinate through the orchestrator; do not edit them here.

---

### T8 — `AskHuman::Directory`: digest → owning asker   [wave 4] [risk: medium]   ✅ LANDED `6c274a0`

**Depends on:** T7
**Files:** `lib/lain/tools/ask_human/directory.rb`,
`spec/lain/tools/ask_human/directory_spec.rb`
**Reuse:** `Sink::Null` / `Supervisor::Null` as the Null Object idiom, so no caller writes
`if directory`. `Event::Projection#pending` (`projection.rb:56-59`) remains the authority on
*what* is pending; this object answers only *who owns it*.
**Shared-file wiring:** index line at the bottom of `lib/lain/tools/ask_human.rb`, beside the
existing `notifying` require.

**Acceptance criteria:**

```gherkin
Scenario: an answer reaches the asker that asked
  Given two askers each holding one pending set
  When an answer names the first set's digest
  Then the first asker resolved it and the second is untouched

Scenario: an unknown digest is refused, not guessed
  When an answer names a digest no registered asker holds
  Then NoPendingQuestion is raised naming the digest

Scenario: a resolved set is no longer routable
  Given a set already answered through the directory
  When a second answer names it
  Then the directory refuses it without touching any asker

Scenario: a deregistered asker's questions are no longer routable
  Given an asker that has been deregistered
  When an answer names one of its sets
  Then the directory refuses it naming the digest

Scenario: the null directory satisfies the same duck
  Given the null directory
  Then it answers the same messages and routes nothing
```
→ spec file: `spec/lain/tools/ask_human/directory_spec.rb`

**Escalation triggers:**
- Ruling 10 says deregistration rides the supervisor lease that already reaps the actor. This
  card provides the *mechanism* (a deregister message) and must not reach into `Supervisor` to
  call it — `Registration` is `(role, actor, lease)` and `Actor`'s `@agent` is private, so the
  Supervisor cannot see a toolset. If this card finds itself widening `Supervisor`, stop: that is
  T10's seam.
- Registration must not keep a dead agent's asker alive by holding a strong reference the lease
  cannot drop. If the ownership direction is unclear from the code, surface it.

---

### T9 — `Neovim::QuestionView`: the Ruby half of the round trip   [wave 4] [risk: high]   ✅ LANDED `6d7691c`

**Depends on:** T5
**Files:** `lib/lain/frontend/neovim/question_view.rb`,
`spec/lain/frontend/neovim/question_view_spec.rb`
**Reuse:** `Neovim::Compose` for its *buffer* discipline — failure returned as a notice string
rather than a boolean (`compose.rb:96-103`), and "NOTHING IS EVER SUBMITTED THAT THE HUMAN DID
NOT SEE" (`:30`). Substitute the set's content digest for `@generation` (ruling 6). Do **not**
copy `#settle`: it parks the prompt thread because something is waiting, and nothing waits for a
question.
**Shared-file wiring:** index line in `lib/lain/frontend/neovim.rb`.

**Acceptance criteria:**

```gherkin
Scenario: a written document resolves the set it was opened for
  Given a set opened in the view
  When the edited lines are written back citing that set's digest
  Then the parsed answer set is handed on exactly once

Scenario: a write citing a stale digest is dropped
  Given a set opened, answered, and a second set opened
  When a write arrives citing the first set's digest
  Then it is dropped and the second set stays open

Scenario: abandoning the buffer leaves the set pending
  Given a set open in the view
  When the buffer is abandoned
  Then the set is still pending and the human is told nothing was submitted

Scenario: a malformed document is reported and the edits survive
  Given a set open in the view
  When the written lines fail the grammar
  Then no answer is handed on, the failure names the offending line, and the view does not
    re-render over the human's text

Scenario: the hand-off crosses threads the way the editor's other commands do
  Given a write arriving on the RPC thread
  Then the answer is handed on through the same queue-and-fiber path other editor commands use,
    never resolved directly on the RPC thread
```
→ spec file: `spec/lain/frontend/neovim/question_view_spec.rb`

**Escalation triggers:**
- `Promise` wraps `Async::Variable` and must be resolved on the reactor thread. Resolving from the
  RPC thread will pass a unit spec and fail in a live session. **Corrected 2026-08-03:** the
  hand-off is no longer `human_replies.rb:135-143`. `HumanReplies` now holds an injected editor
  adapter (`#bind_editor`, `:47`; `NoEditor` default, `:26-30`) and polls it from
  `editor_reply_loop` (`:166-168`) via `pop_command` (`:218-222`); the `Thread::Queue` itself is
  `rpc_thread.rb:348`, wrapped by `Neovim::CommandInbox` (`neovim.rb:116,133-145`). Follow that
  path — the constraint is unchanged, only its address.
- `Compose` clears nothing at open, deliberately: `compose.rb:214-221` records that clearing the
  queue at open was a cross-thread check-then-act bug. Read it before reaching for a clear.
- This card must not resolve promises directly; it hands the answer set to an injected callable.
  If it needs the Directory, that is orchestrator wiring.

---

### T10 — Let subagents ask the human   [wave 6] [risk: high]   ✅ LANDED `f7c2943`

**Depends on:** T11
**Files:** `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/tools/subagent.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Subagent::Seam` (`subagent.rb:413-431`) is the documented home for a shared
collaborator — "a seventh collaborator is one member and one wiring line rather than four edits".
`ChildBuilder#child_union` (`:564-568`) propagates the union to grandchildren.

**Corrected 2026-08-03 — read before starting.** `Seam` is now **eight** members —
`provider, context_factory, parent, journal, supervisor, observer, gate_policy, permits` — of
which **five** default to Nulls (`:427-431`), not the "last three" this card recorded; only the
first three are required. More importantly, **the toolset union alone no longer decides what a
child may call.** `47ade63` added a second gate: `ChildBuilder#permitted` (`:538-543`) intersects
the child's toolset with `@seam.permits` and raises `NoCapability` if the result is empty. A
subagent gets `ask_human` only if it survives **both** the spawn policy's attenuation and the
session posture's `Permits`. Today that costs nothing — `ask_human` is already listed in
`Posture::READ_ONLY` (`mode/posture.rb:147`) and the other three rungs use `Permits::All` — so no
permit-list edit is needed. Do not assume it; add an AC that pins it, so a future posture change
cannot silently mute a child's questions.
**Shared-file wiring:** none. **`lib/lain/cli/wiring.rb` belongs to T11** — consume what it
wires; do not edit it.

**Landed-T11 seam (2026-08-03) — this is what you consume; `wiring.rb` is already done.**
`Wiring` passes `askers: @askers` through the existing `ToolsetBuild.new` call, and
`toolset_build.rb` already receives it (`askers: Askers.unwired` plus a private reader).
**You need exactly one message: `askers.enrol(child_handle) → Enrolled(asker:, registration:)`.**
Do not edit `wiring.rb`.

**The release hook is reachable without widening `Supervisor`.** `Supervisor#stop → #farewell →
registration.actor.stop` runs for **every** row including crashed ones, and `Actor#stop` is inside
this card's own subtree — so hold the child's `Registration` on the actor and `deregister` in
`#stop`, which rides the same lease that reaps it (ruling 10, no reaper invented). Three caveats
T11 measured and did not paper over:
- **`enrol` inside the launch block.** A launch that raises never registers a row, so enrolling
  outside it registers an asker nothing will ever release.
- **`#reap_crashed` releases only at teardown**, so a crashed child's registration lives until the
  supervisor stops. That is a leak, never a dangling route — the trade T8 chose deliberately.
- **Releasing at crash time would need a `Supervisor` hook.** Flagged, not built. If this card
  concludes it needs one, stop and surface it rather than adding it.

**T11's panel verified that chain in the code** (`supervisor.rb:163-192`, crashed rows included)
and added two things you must honour:
- **`deregister` has to go in an `ensure`.** `Actor#stop` opens with
  `raise NotLaunched unless launched?` and `return @farewell if @stopped`, so a `deregister` in
  the method body is skipped by **both** guards — an unlaunched or already-stopped actor would
  never release.
- **`Supervisor#stop`'s `each` has no rescue**, so one raising `Actor#stop` strands every later
  row's release. Do not add a rescue to `Supervisor` (that is widening it); just know that your
  `#stop` must not raise, which is another reason for the `ensure`.

**Landed-T8 constraint (2026-08-03): whoever holds the lease must hold the `Registration`.**
Ownership in the directory is one-way and **strong** — Directory → Registration → asker, with the
asker holding nothing back. A weak map was considered and rejected, because it would let an
outstanding question stop being routable at a GC's discretion; the deliberate trade is that the
failure mode is a **leak, never a dangling route**, and `deregister` is the only release. So a
child's `Registration` has to be held by whatever already owns that child's lifetime, and released
on the same lease expiry that reaps its actor (ruling 10). If this card cannot reach a lifetime
hook without widening `Supervisor`, stop and surface it — T8 deliberately did not.

**Retention is bounded by registration lifetime, not by session length.** T8's panel found the
first cut leaked: answered digests were held as tombstones the `Directory` owned, and `#forget`
skipped them because a tombstone is not `equal?` to its registration — three answered sets left
three entries behind after `deregister`, for the life of the process. Fixed structurally: the
names now live **inside** the `Registration` (`digest => Open | Answered`) and the `Directory`
owns only the list of registrations, so dropping a registration drops its names with it. The
deliberate consequence, spec'd: after `deregister`, a previously answered digest reports
**unknown** rather than *already answered* — the asker is gone, so "no record of this" is the
honest answer.

**Acceptance criteria:**

```gherkin
Scenario: a subagent holds an asker of its own
  Given a spawned child
  Then its toolset offers ask_human

Scenario: a child's question reaches the human's arrival surface
  Given a child that asks a question set
  Then it lands on the same arrival queue a parent's question does, attributed to the child

Scenario: a child's question is attributed to the child
  Given a child that asks a question set
  Then the pending message names the child as sender, not the parent

Scenario: parent and child can be pending at once
  Given a parent and a child each with one pending set
  Then both are pending and the inbox projection lists both

Scenario: a grandchild inherits the capability
  Given a child that spawns its own child
  Then the grandchild's toolset offers ask_human

Scenario: each asker is registered under its own questions
  Given a parent and a child each with a pending set
  When each set's digest is looked up in the directory
  Then each resolves to the asker that asked it
```
→ spec files: `spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- The arrival AC is the one that decides whether this capability ships working. Announcement
  lives in `AskHuman::Notifying`, **not** `AskHuman` — a plain asker writes the Store event and
  nothing else. `Projection#pending` reads the Store, so every other AC here passes with a child
  whose questions never reach the TTY, dunst, or `HumanReplies#pending?` (`human_replies.rb:33`).
  A green suite with a silent child is the failure to avoid.
- `toolset_build.rb:22-32` denies this on purpose (the comment moved and grew; `#build` is now
  `:193-198`, appending `[research_subagent(base), ask_human, run_skill] + epic.tools` after
  `base`). The same sentence denies `RunSkill` for a *different* reason ("nor to render a skill
  scaffold back into a conversation that is not the one the human is having"). Reverse **only**
  the `ask_human` half; if the code shape makes them inseparable, stop.
- **Corrected 2026-08-03: that comment now denies a third tool, and denies it for *this card's*
  reason.** `Tools::RequestReview` was added to the same list because "it is an ask_human whose
  subject is a file, it PARKS until the human answers, and a child that could open one would hold
  an artifact's baton in a conversation nobody is watching." This chunk dissolves two thirds of
  that rationale — a child's park is now visible in the inbox and routable by digest. **Do not
  reverse `RequestReview` here anyway**: its baton semantics are `Epic`'s, not this chunk's, and
  widening scope to it is a decision the plan has not made. Reverse `ask_human` only, leave the
  `RequestReview` clause standing, and note in your hand-back that its stated reason is now
  partly stale — the orchestrator records it as a follow-up.
- Ruling 10 says no timeout: a parked child stays parked, visibly. If this card concludes that is
  untenable, stop and surface it rather than inventing a policy.
- `Seam` is explicitly not `Ractor.shareable?` and does not aspire to be (`subagent.rb:390-395`).
  Adding a member must not change that claim in either direction without saying so.

---

### T11 — `HumanReplies` and `Wiring` resolve through the directory   [wave 5] [risk: medium]   ✅ LANDED `3f45bfa`

**Depends on:** T8
**Files:** `lib/lain/cli/human_replies.rb`, `lib/lain/cli/wiring.rb`,
`spec/lain/cli/human_replies_spec.rb`
**Reuse:** the directory from T8. `Wiring#announce` (`wiring.rb:193-196`) is the narrowest place
to widen what the notify seam carries — today it enqueues a bare String and fires
`@notifier.question(agent: "lain", ...)` with a hardcoded agent name.
**Landed-T7 note (2026-08-03) — your real blocker, found by T7's panel.**
`#reply(answer, digest = @outstanding.digest)` is **transitional**: the default exists so this
card's two call sites keep working until you convert them. **Do not treat the default as safe.**
The single-set invariant fixes *which set is outstanding*, not *which set the answer was written
for*: cancel a question, ask a different one, then `reply(answer)`, and the cancelled question's
answer resolves the **new** set with A's causal edge citing it. This is **not** a regression —
HEAD did the same through the orphaned promise — but it is live, and the path is **stale
`InboxItem`s**: a Ctrl-C stops `answer_loop` before `resolve_reply`'s `@inbox.shift`, so the item
survives into the next drain and the human answers a question that is no longer outstanding.

So this card owes two things, not one: make `digest` **required** and take it from `#ask`'s return
value, **and** make an abandon retire its inbox item. Fixing the signature alone leaves the human
answering a ghost. Related: `NoPendingQuestion` is now reachable (abandon makes it live) and
`resolve_reply` rescues only `AlreadyResolved`, so a human answering a listed-but-abandoned item
currently reads "no question is awaiting a reply" — true, but not what they need to be told.

**Also corrected:** T7's hand-back claims several children can share one `AskHuman` today. They
cannot — one `@ask_human` exists (`wiring.rb:141`) and reaches only the top-level toolset, since
`research_subagent` and `role_spawn_seam` both receive `base`, which excludes it. That is what T10
changes.

**Scope note:** this card **owns `wiring.rb` for the whole chunk**. It constructs the directory,
injects it where the single `@ask_human` used to go, and widens `announce` so an arrival carries
its set and asker. T10 and T14 consume that and must not edit this file.

**Acceptance criteria:**

```gherkin
Scenario: each inbox item reports its own sender
  Given two pending sets from two different askers
  When the inbox is listed
  Then each item names the asker that asked it

Scenario: answering one item retires that item, not the head
  Given two pending sets
  When the second is answered
  Then the second is retired and the first is still listed

Scenario: a set with no matching pending promise is refused loudly
  When an answer names a set that is no longer pending
  Then the human is told, and no item is retired

Scenario: the arrival queue carries the set, not a bare string
  Given a set announced through the notify seam
  Then the enqueued item carries the set's digest and its asker

Scenario: the desktop notification names the asking agent
  Given a set announced by a named asker
  Then the notification names that asker rather than a hardcoded name
```
→ spec file: `spec/lain/cli/human_replies_spec.rb`

**Escalation triggers:**
- `human_replies.rb:96-97` records that `.to_s` on the read is deliberate armor: "EOF returns
  nil, and an empty answer is honest where `Tool::Result.ok(nil)` would raise". Do not remove
  that coercion without replacing the property it protects.
- `resolve_reply`'s `ensure @inbox.shift` is defect 3. Fixing it changes which item a blank
  answer leaves listed — `human_replies_spec.rb` pins "keeps a blank-answered question listable".
  Confirm that spec still means what it says under digest-addressed retirement.
- Two surfaces racing one pending is **normal** and already handled: `resolve_reply` rescues
  `AlreadyResolved` (now `:156`). Do not add mutual exclusion between the TTY and the editor.
- **Corrected 2026-08-03.** Defect 2 is now **two** sites, not one: `:119` (`answer_loop`) and
  `:148` (`drained_questions`) both attribute via `@ask_human.last_question&.from`. Fix both; an
  AC that only covers one leaves the inbox mis-attributing on the other path. Line references in
  this card have all moved — `resolve_reply` is `:154-160`, the `.to_s` armor is `:126-132`,
  `#pending?` is `:66`, and the two `#reply` call sites are `:155` and `:182`.
- `serve_editor_command` (`:182`) now pre-guards on `@ask_human.pending?` before replying. Under
  digest-addressed routing that predicate asks the wrong object — "does *this* asker have
  something pending" is not "is *this digest* answerable". Route the guard through the directory
  or drop it; leaving it makes a child's question unanswerable from the editor whenever the parent
  has nothing pending.

---

### T12 — `lain://question`: the writable, folded markdown buffer   [wave 5] [risk: high]   ✅ LANDED `39085d0`

**Depends on:** T9
**Files:** `lib/lain/frontend/neovim/runtime.lua`,
`lib/lain/frontend/neovim/rpc_thread.rb`, `lib/lain/frontend/neovim.rb`,
`spec/lain/frontend/neovim_runtime_spec.rb`
**Reuse:** `compose_buf` (`runtime.lua:386-428`) verbatim for the buffer shape — `acwrite`
(because `nofile` refuses `:write` with E382 before any autocommand runs), a set name (E32
otherwise), `bufhidden = "hide"` so `BufUnload` signals abandon, `filetype = "markdown"`.
`set_compose` (`:588-597`) for the render entry point and its open-a-split-only-if-unwindowed
idempotence. `BufWriteCmd` (`:657-677`) for the write — **rpcrequest first, `modified = false`
only on success**. `RenderQueue::Command` (`rpc_thread.rb:41`) is arity-agnostic, so a fifth
entry point is one constant plus one `post_` method. `RECORD_START` (`runtime.lua:76-91`) is
where the fold predicate registers.
**Shared-file wiring:** none

**Landed-T9 findings (2026-08-03) — the first one decides whether this card's central AC is real.**

1. **`RpcThread#dispatch` acks `lain_command` with `true` *before* calling `Router`**, so a route's
   return value can **never** reach the editor. If the question write is routed that way, a
   `MalformedDocument` cannot propagate as an rpcrequest failure, `error()` never fires, and the
   buffer is silently marked unmodified over text the grammar refused — the exact opposite of
   "the write fails naming the line, the buffer stays modified, and the text is unchanged". This
   card must call `view.wrote(lines, digest)` **before** the ack and answer
   `respond(id, nil, failure)` on refusal. T9 shaped `#wrote` to *return* the failure message
   rather than raise, precisely so this is expressible.
2. **`RenderInlet#refusable` hands back `Compose::DETACHED`** ("composing needs an attached
   editor") for **every** refused open, which is the wrong sentence for a question. Parameterize
   it or return a `QuestionView::DETACHED`.

Also owed by this card, per T9's hand-back: `RenderInlet#open_question` plus its lua entry point,
and the view's construction and hand-out in `neovim.rb`. The `question_answered` verb branch in
`HumanReplies` belongs to T11.

**Landed-T5 constraint (2026-08-03) — do not miss this.** `Question::Document` normalizes exactly
one thing: every line read is `rstrip`ped. A **tab-indented** line is **refused by name**, not
silently dedented, because the comment slot is two-space-indented prose and a tab cannot be
mapped onto that without guessing what the human meant. So `lain://question` **must set
`expandtab` and `shiftwidth=2` on the buffer**, or a human whose own config indents with tabs
writes a comment that the grammar then refuses on `:w`. That is a buffer-option line in
`question_buf`, and it is the difference between the comment slot working and being unusable for
half the people who have a vimrc.

**Acceptance criteria:**

```gherkin
Scenario: a set opens as a markdown buffer holding its rendered document
  Given a pending question set
  When it is opened
  Then lain://question holds the rendered markdown with filetype markdown

Scenario: the document folds one fold per question
  Given an opened set of three questions
  Then the buffer carries three folds, one per question

Scenario: writing the buffer submits it
  Given an opened set whose buffer has been edited
  When the buffer is written
  Then the edited lines and the set's digest reach Ruby

Scenario: a malformed document leaves the buffer dirty with the human's text
  Given an opened set edited into a shape the grammar refuses
  When the buffer is written
  Then the write fails naming the line, the buffer stays modified, and the text is unchanged

Scenario: a write that cannot reach lain leaves the buffer dirty
  Given an opened set
  When the write cannot reach lain
  Then the buffer stays modified and the human is told it was not saved

Scenario: closing the buffer signals abandon
  Given an opened set
  When the buffer is unloaded
  Then the abandon signal reaches Ruby carrying the set's digest

Scenario: the protocol handshake stays in lockstep
  When the frontend attaches
  Then no protocol mismatch is reported
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb`

**Escalation triggers:**
- **Folds do not come for free.** They install only when `RECORD_START[b:lain_view] ~= nil`
  (`runtime.lua:494-500`). Without a `QUESTION` predicate the human gets whatever their own
  markdown config does, and the Intent's "folded" claim is false. One entry, one fold per
  question — the inbox precedent.
- The parse must run **synchronously inside the `BufWriteCmd` rpcrequest**, so a
  `MalformedDocument` propagates as an rpcrequest failure and `error()`
  (`runtime.lua:665-673`) leaves the buffer modified with the human's text intact. That is what
  makes T9's "edits survive" AC true rather than aspirational.
- The protocol bump is **not optional** and must be atomic: `neovim.rb:41` (`PROTOCOL`), its
  version-history comment at `:34-40`, and `runtime.lua:15` (`RUNTIME_PROTOCOL`) in one commit.
  No spec parses the lua to assert lockstep — grep for `RUNTIME_PROTOCOL` in `spec/` returns
  nothing — so a Ruby-only bump fails only in the `:nvim`-tagged suite. Run it.
- **Corrected 2026-08-03: the current protocol is `"5"`, not `"4"`, so this card bumps to `"6"`.**
  `d125aba` (open a review in the attached editor) took it to `"5"` but **never added a `"5":`
  line to the version-history comment** — it still ends at `"4"`. Backfill that missing entry in
  the same edit as the `"6"` one; a history that skips a version is worse than none, and this card
  is the first to notice. `neovim_runtime_spec.rb` hardcodes the number in **three** places
  (`:250` in a description string, `:254`, `:255`) — all three move.
- `runtime.lua:408-414` records a deliberate, unfixed `acwrite` limitation: `:wall` and autosave
  plugins fire the write on half-typed text. The question buffer inherits it. Compose chose not
  to defend against it; diverging needs a reason.
- `:nvim` specs are excluded by a config-level **filter**, not a per-example skip
  (`spec/support/tags.rb:85-95`), because a `before(:each)` skip runs too late and leaves a
  `Process.kill("TERM", nil)`. Do not convert the filter to a skip.

---

### T13 — Tick an option with `x`   [wave 6] [risk: medium]   ✅ LANDED `c94a20c`

**Depends on:** T5, T12
**Files:** `lib/lain/frontend/neovim/runtime.lua`,
`spec/lain/frontend/neovim/buffers_spec.rb`
**Reuse:** buffer-local `vim.keymap.set` from a cleared-augroup `BufEnter`, exactly as the inbox
reply maps are bound (`runtime.lua:727-733`). `cached_lines` (`runtime.lua:452-462`) rather than
a fresh whole-buffer read per keypress — the fold surface already pays for that cache. The mark
vocabulary and the arity encoding come from T5's grammar.
**Shared-file wiring:** none

**Landed-T5 caveat (2026-08-03), verbatim from its hand-back:** a question body may legally
contain a line matching `OPTION` (T5's AC 6 requires exactly that — `- [x] no` inside a fence), so
the scan must require the backticked id (`- [ ] \`id\` label`) and/or take only the last
blank-or-indent-separated run of option lines before the next heading — ticking a body line
cannot corrupt anything silently (the next `:w` refuses it loudly, naming the line), but it will
read to the human as a broken keymap.

Arity is in the heading — `## \`id\` (choose one|choose any|write your answer below)` — and T5's
spec ships a working buffer-text-only `scan` helper to port to lua. A body cannot contain a line
matching that full heading pattern; `Question` refuses it at construction.

**Acceptance criteria:**

```gherkin
Scenario: x ticks the option under the cursor
  Given an open question document with the cursor on an unticked option
  When x is pressed
  Then that option's checkbox is ticked and no RPC was sent

Scenario: x unticks a ticked option
  Given the cursor on a ticked option
  When x is pressed
  Then that option's checkbox is cleared

Scenario: a single-select question keeps at most one tick
  Given a single-select question with its first option ticked
  When x is pressed on the second option
  Then the second is ticked and the first is cleared

Scenario: a multi-select question accumulates ticks
  Given a multi-select question with one option ticked
  When x is pressed on another option
  Then both are ticked

Scenario: x elsewhere behaves as vim's x
  Given the cursor on a prose line the human is writing
  When x is pressed
  Then the character under the cursor is deleted
```
→ spec file: `spec/lain/frontend/neovim/buffers_spec.rb`

**Escalation triggers:**
- Ruling 11 is the whole shape of this card. `runtime.lua:753` records why shadowing `p` was
  safe — "a **nomodifiable** buffer has no use for" paste — and `lain://question` is `acwrite`
  with the human typing prose into it. The fall-through to `normal! x` is not optional.
- Sibling-clearing needs the option's question and its arity from **buffer text alone**, with no
  RPC. T5's last AC guarantees that. If it turns out not to, stop — this card is unbuildable and
  the defect is T5's.
- `buffers_spec.rb:260` pins "keeps the motions and the inbox reply keys buffer-local, never
  global". The same must hold here.

---

### T14 — The TTY points at the editor, and always answers   [wave 6] [risk: medium]   ✅ LANDED `4016094`

**Depends on:** T4, T11
**Files:** `lib/lain/frontend/tty.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** `TTY::Inbox#arrival` (`tty.rb:517-520`) is already the one-line arrival note.
`TTY::Inbox#drain` (`:524-532`) already lists and reads through an injected reader. T4's
whole-set free-text answer is what a typed reply becomes.
**Shared-file wiring:** none. `lib/lain/cli/wiring.rb` belongs to T11.

**Acceptance criteria:**

```gherkin
Scenario: the arrival note points at the editor when one is attached
  Given an nvim frontend is attached
  When a question set arrives
  Then the TTY prints one line naming the asker and pointing at the nvim inbox

Scenario: the arrival note stays one line regardless of set size
  When a set of five questions arrives
  Then the arrival note is still a single line

Scenario: draining prints the set's markdown
  Given a pending question set
  When the human drains the inbox
  Then the set's markdown is printed

Scenario: a typed reply answers the whole set, editor or not
  Given a pending set and an attached editor
  When the human types a reply at the TTY instead
  Then the set resolves carrying that reply as an unstructured answer

Scenario: the record distinguishes a typed answer from a selection
  Given a set answered by typed prose
  Then the answer record reports it as unstructured
```
→ spec file: `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- Ruling 7: the answer path is **never** gated on editor attachment. There is no `attached?`
  predicate in `lib/lain/frontend/` or `lib/lain/cli/`, attachment is not stable (nvim dies
  mid-session — hence `Compose::Detached`), and `/inbox` works today regardless of editor. If
  this card finds itself asking "is nvim attached" for anything but the pointer text, stop.
- `tty_spec.rb` pins "renders exactly one line naming the question and pointing at /inbox" by
  asserting the output contains no `"\n"`. The pointer text changes; the one-line property must
  not.
- Printing a set's markdown makes the drain multi-line where it was one line per item. Confirm
  the existing drain ACs still hold, or say which changed and why.

---

### T15 — `<CR>` in the inbox opens that set   [wave 7] [risk: medium]   ✅ LANDED `39d84c9`

**Depends on:** T13
**Files:** `lib/lain/frontend/neovim/runtime.lua`,
`lib/lain/frontend/neovim/inbox_view.rb`,
`spec/lain/frontend/neovim/inbox_view_spec.rb`
**Landed-T12 constraint (2026-08-03): `Frontend::Neovim` has one line of headroom.** T12
extracted `CommandInbox` into its own file during its fix round, taking the class from 110/110 to
**109/110** `Metrics/ClassLength`, with no cop loosened. If this card adds anything to
`neovim.rb`, extract `Surfaces` first (follow-up 19) rather than loosening the cop.

**Landed-T10 requirement (2026-08-03) — you close the other half of a defect already half-fixed.**
`correlation_of` is the chain ROOT digest and an `:inherit` child is `parent.fork`, so a child and
its parent share a root **permanently** and render identical sender columns. `:inherit` is the
**default** for a `@role` spawn, so this is the common path. The TTY half is closed: `InboxItem`
now prefers the asker's name over `event.from`. **`Neovim::InboxView` is not** — it never sees an
`InboxItem`; it folds the record stream and builds its row from `event.from` directly. Measured
against the real view: a parent and an `:inherit` child are still indistinguishable there.

Closing it needs the asker's **name riding the record** — the Q event itself — so the view can read
it. `spec/lain/tools/subagent_spec.rb` carries a **PINNED PENDING** example that fails today for
exactly this reason and goes green when you land it; do not delete it, un-pend it. Ruling 3 still
binds: the line shape (`sender  age  text`, two-space padding) is preserved exactly — you are
changing what fills the sender column, not its shape.

**Reuse:** `:LainPin` (`runtime.lua:749-767`) is the recorded precedent, and its comment states
the rule: "The LINE rides as the argument, never a digest ... the Ruby side's own line → digest
index is the only thing that can name the turn — and that index is built by the same pass that
produced the lines, so it cannot disagree with what the human is looking at." `InboxView`'s
`@pending` is already digest-keyed and ordered (`inbox_view.rb:49,78-82`), so the index is
`@pending.keys` — it just is not exposed, and `Item` carries no digest.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: pressing enter on an item opens that set
  Given two pending sets listed in the inbox
  When the cursor is on the second and enter is pressed
  Then the second set's document opens

Scenario: r opens the same set enter does
  Given a pending set under the cursor
  When r is pressed
  Then the same document opens

Scenario: the line index cannot disagree with the rendered lines
  Given a rendered inbox
  When the line index is asked for each line in turn
  Then each answer is the digest of the item rendered on that line

Scenario: enter on the empty-state placeholder does nothing
  Given an empty inbox
  When enter is pressed
  Then nothing opens and no RPC is sent

Scenario: the inbox line shape is unchanged
  Given a pending set
  Then its line still reads sender, age, and the set's summary with the existing padding
```
→ spec file: `spec/lain/frontend/neovim/inbox_view_spec.rb`

**Escalation triggers:**
- Ruling 3: the inbox line shape is **preserved exactly**. `RECORD_START[INBOX]`
  (`runtime.lua:87`) matches `"  %d+[smh]  "` and the `lainSender` syntax group anchors on the
  same two-space padding; `buffers_spec.rb:174,202` pin both. If naming the set's question count
  cannot fit without moving that padding, drop the count — the shape wins.
- Ruling 12 repoints `r` as well as `<CR>`, and `lain.txt:217` documents the old behaviour. Both
  keys must invoke the same *command* a human could type by hand, which is why the current code
  routes through `:LainReply` rather than calling the function directly
  (`runtime.lua:709-733`). `inbox_view_spec.rb:242` pins that property; preserve it under the new
  command.

---

### T16 — After submit, move to the next set or back to the inbox   [wave 8] [risk: medium]   ✅ LANDED `1b13402`

**Depends on:** T15
**Files:** `lib/lain/frontend/neovim/runtime.lua`,
`lib/lain/frontend/neovim/question_view.rb`,
`spec/lain/frontend/neovim/question_view_spec.rb`
**Reuse:** T9's view state machine; `set_compose`'s window handling (`runtime.lua:588-597`),
which opens a split only when the buffer has no window.

**⚠️⚠️ GATE (2026-08-03, T15's panel) — wiring the consumer makes a wrong-document bug live.
Fix this in the SAME card, or do not wire it.**

`InboxView::Renderings` holds the last **two** renderings and resolves a gesture by matching the
**height** the editor reports. Its `HELD = 2` comment claims that is safe because the render queue
drains everything in one tick, so the screen is always the newest rendering or the one before it.
**That justification is false.** `RenderQueue` drains once per RPC tick, so a burst posts
arbitrarily many renders between drains and the screen can be *k* renderings behind. Probed:
`[d1,d2]` → retire → `[d2]` → arrive → `[d2,d3]`; the human's rendering ages out, the height
**aliases**, and `open(1, showing: 2)` returns `opened? == true` **with the wrong document in the
editor**. It reports success.

The height is a weak key and the repo already has the strong one: `SET_COMPOSE` and `SET_QUESTION`
both carry a **generation stamp**, and `SET_VIEW` does not. **Stamp the inbox buffer and send that
back with the gesture instead of the line count.** The fix is inside `Renderings` plus a keyword at
two call sites — its panel judged that the object earned itself precisely because both remaining
bugs live entirely inside its twelve lines.

Two optional polish items from the same review: fold `shown(...)&.at(line)` into a
`Renderings#digest_at(line, showing)`, and state the "every caller holds `InboxView`'s lock"
invariant that lets `Renderings` be lock-free.

**⚠️ Landed-T15 requirement (2026-08-03) — THIS CARD OWNS THE CONSUMER, and without it the
chunk ships two dead keybindings.**

T15 wired `<CR>` and `r` to `:LainOpen`, which sends `["open", [line]]` onto the editor rail. **No
consumer pops it.** `HumanReplies#serve_editor_command` dispatches on `reply`,
`question_answered` and `review_done` only, so an `"open"` verb is popped and **silently
discarded** — pressing enter on an inbox item does nothing whatsoever in a live session. Every
piece below that seam is built and tested (`InboxView#open(line)` resolves line → digest → body →
`Question::Set.from_body` → `QuestionView#open` and answers an `Opened(digest, report)`), and
`["pin", [line]]` has sat in the same state since B4.

T15 could not close it because the wiring needs `buffers.rb`, `neovim.rb` and a `HumanReplies`
consumer, none of which it owned. **It is three wires, not one** (T15's panel counted them):
production `Buffers` builds `InboxView.new(store:)` — no `questions:` — so the view resolves to
`Unwired` and **refuses**; `Buffers` has no `#open` (it has `#pin`); and `Neovim` exposes no
`buffers` reader. T15's specs inject `questions:` directly, which is what hid this. Budget for all
three. **You need exactly that same machinery** for "submitting with
another set pending loads the next one", so build it once, here, and make it serve both gestures.
**Add `lib/lain/cli/human_replies.rb`, `lib/lain/frontend/neovim/buffers.rb` and
`lib/lain/frontend/neovim.rb` to your scope**, and pin the end-to-end path: enter on an inbox item
opens that set's document. Retire `pin`'s dead verb too if it falls out cheaply; say so if it does
not.

**`Frontend::Neovim` has one line of `Metrics/ClassLength` headroom (109/110)** and you are now
certain to add to it — extract `Surfaces` (follow-up 19) **first**, rather than discovering the
cop at the end.

**Landed-T9 constraint (2026-08-03) — how the next set must be loaded.** `QuestionView` holds a
**non-reentrant** `Mutex` across guard-and-swap, and `@submit.call` runs **inside** it. So the
next set must be opened by the **rail's consumer** — the fiber that pops the hand-off queue —
**never** by the `submit` callable and never from inside `#wrote`. Re-entry does not hang: it
raises `ThreadError: deadlock; recursive locking`, loudly and immediately. T9's panel wired the
production shape (consumer pops, then opens the next set) and confirmed this card's ACs are
reachable that way, with both sets intact. It cannot chain synchronously.

**Landed-T9 constraint (2026-08-03): re-focusing an existing window is the lua half's job now.**
`QuestionView#open` **refuses** while a set is open — two notices, `ALREADY_OPEN` for the same
digest and `OCCUPIED` for a different one — and does **not** post on refusal. That is ruling 2
enforced in code rather than asserted in prose: it is what makes the `RequestBuffer` clobber
(`request_buffer.rb:36-42`) structurally unreachable instead of merely un-attempted. The
consequence is that Ruby will never re-post over a half-ticked document, so if the human has the
question buffer open and asks to open it again, **lua** must focus the existing window. Do not
"fix" this by relaxing the Ruby guard.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: submitting with another set pending loads the next one
  Given two pending sets and the first open
  When the first is submitted
  Then the buffer holds the second set's document

Scenario: the next set is the one the inbox lists next
  Given three pending sets and the first open
  When the first is submitted
  Then the set loaded is the one the inbox lists first among those remaining

Scenario: submitting the last set returns to the inbox
  Given one pending set, open
  When it is submitted
  Then the question buffer is left and the inbox is shown

Scenario: a set arriving while one is open does not disturb it
  Given an open set being edited
  When a new set arrives
  Then the open buffer is unchanged and the new set is listed in the inbox

Scenario: abandoning does not advance
  Given two pending sets and the first open
  When the first is abandoned rather than submitted
  Then no next set is loaded and the first is still pending
```
→ spec file: `spec/lain/frontend/neovim/question_view_spec.rb`

**Escalation triggers:**
- Ruling 2 is what makes the fourth AC hold. If a new arrival can reach the open buffer by any
  path, the `RequestBuffer` clobber defect (`request_buffer.rb:36-42`) has been reintroduced.
- Advancing must not steal the cursor at any moment other than a submit. `set_request`
  deliberately "never focuses or jumps to the buffer, so a re-render can't steal the cursor
  mid-edit" (`runtime.lua:567-571`).

---

### T17 — Document the question document   [wave 9] [risk: low]   ✅ LANDED `a83477d`

**Depends on:** T16
**Files:** `docs/commands.md`, `plugin/nvim/doc/lain.txt`,
`plugin/nvim/lua/lain/init.lua`, `ROADMAP.md`, `spec/plugin/nvim_plugin_spec.rb`
**Landed-T12 note (2026-08-03):** `plugin/nvim/doc/lain.txt` still reads "PROTOCOL 5"; the
constant is now `"6"`. T12 backfilled the missing `"5"` entry in `neovim.rb`'s own version history,
so the doc is the only place left behind. Remember the distinction this card already records:
numbers stating the CURRENT contract move, numbers recording when a feature LANDED do not.

**Reuse:** the existing `/inbox` entry (`docs/commands.md:275-277`), the nvim doc's command list
(`plugin/nvim/doc/lain.txt:216-218`) and folds section (`:254-269`).
**Shared-file wiring:** one-line ROADMAP index entry (numbered 27), applied by the orchestrator.

**Acceptance criteria:**

```gherkin
Scenario: the nvim doc describes the question buffer
  Then lain.txt names lain://question, the x mapping, :w to submit, and enter from the inbox

Scenario: the documented command list matches the runtime
  Given every command runtime.lua defines
  Then lain.txt names each one, including :LainPin

Scenario: the current-version protocol numbers match the constant
  Given lain.txt's protocol references
  Then those stating the CURRENT contract version equal Frontend::Neovim::PROTOCOL,
    and those recording when a feature landed are unchanged
```
→ spec file: `spec/plugin/nvim_plugin_spec.rb` (extend; it already reads `PROTOCOL` symbolically
at `:274`)

**Escalation triggers:**
- `spec/docs_naming_spec.rb` is **not** the right home: its `DOCS` set is README / CLAUDE /
  ARCHITECTURE / `docs/**/*.md`, it reads neither `lain.txt` nor `ROADMAP.md`, and it enforces
  one rule (retired-name proximity). The command-list AC needs a new guard that parses `define(`
  out of `runtime.lua`.
- **Corrected 2026-08-03 (T12, verified against `d125aba`): every `PROTOCOL n` marker in
  `lain.txt` moves together.** This card originally claimed `6.5 COMPOSING A MESSAGE (PROTOCOL 4)`
  was a historical record of when compose landed and must stay `4`. It is not: `d125aba` moved
  **every** heading including 6.5, so those markers are current-contract version stamps, not
  landing records. T12 moved all four to `6` on that precedent, and
  `spec/plugin/nvim_plugin_spec.rb` now asserts the **count** of markers, because `include` is
  case-sensitive and satisfied by one — which is how three of them drifted unnoticed through the
  `"5"` bump. The distinction this card still owes is elsewhere in the doc's prose, not in the
  headings.
- `plugin/nvim/lua/lain/init.lua:4` is already stale at "protocol 3". Either keep it honest or
  remove the number; a comment that cannot be kept current is worse than none.

## Outcome (closed 2026-08-03)

**All 17 cards landed, as 17 commits on `main`** (`9fbae30`..`a83477d`), each through the
pre-commit hook's full parallel suite. Every card was panel-reviewed; **11 of 17 needed a fix
round**, and 6 needed two.

**Integration checks, all green:**

| Check | Result |
|---|---|
| `bundle exec rspec` | **9452 examples, 0 failures, 2 pending** (baseline 8972, **+480**) |
| `bundle exec rspec --tag nvim` | 133, 0 failures |
| `spec/output_discipline_spec.rb` | 3, 0 failures |
| `bundle exec rubocop` | 1064 files, **0 offenses**, `.rubocop.yml` untouched |
| `rake compile` | ok |
| `cargo test` | 277 passed, 0 failed |
| `cargo clippy --all-targets -- -D warnings` | clean |
| `pre-commit run --all-files` | every hook Passed |
| `Ractor.shareable?` on the question values | 5 examples, 0 failures |
| Worktrees / branches | back to pre-chunk state |

**Prompt-cache prefix: exactly one tool moved.** Dumped all 27 tools' emitted schemas at
`8ef1c1f` and at `a83477d` and diffed: **only `AskHuman`** (and its `Notifying` subclass, which
shares the schema). **`TodoWrite` did not move a byte** despite being migrated off a hand-written
schema onto the new DSL — which was the whole point of that card.

**No `Metrics/*` limit was loosened anywhere.** Nine objects the plan never named exist because a
cop tripped and an object was extracted instead: `Blankness`, `Question::Fence`,
`Question::Renderable`, `AskHuman::Announcement`, `AskHuman::Outstanding`, `Neovim::CommandInbox`,
`InboxView::Renderings`, `Pending`/`Reply`, `Askers`, `ChildBuilder::Child`, `Surfaces`.

**The pattern worth carrying out of this chunk.** Roughly seven defects were found by a panel
noticing that *an assertion could not observe the property it named*: a schema pin that stays
byte-identical while behaviour changes; `blank_ok` silently rejecting `[]`; a spec helper building
bare Strings so a whole file never exercised the real path; `Enumerable#one?` counting truthy
elements rather than cardinality; a fold spec that `zM`s before reading the at-rest state; an
arrival AC that could only pass or **hang**; a tombstone-pruning spec green either way. When a
suite stays green through a change that should have broken it, suspect the assertion before the
code.

## Integration checks

After the last wave:

- `bundle exec rspec` — full default suite. Measure the example count against the pre-chunk
  count; `parallel_tests` reports only surviving examples, so a drop with zero failures means a
  dead worker, not a clean run. **Pre-chunk baseline, measured 2026-08-03 at HEAD `8ef1c1f`:
  8972 examples, 0 failures, 2 pending, 2m07s.** The closing count must exceed this; a count at
  or below it with zero failures is a dead worker.
- `bundle exec rspec --tag nvim` — the protocol lockstep and every buffer contract live here.
  **Corrected 2026-08-03 (found by T12): these are NOT excluded by default.** `spec/support/tags.rb:91-95`
  excludes `:nvim` only when `LAIN_NVIM=0` **or** `nvim` is absent from `PATH` — it is opt-**out**,
  not opt-in. nvim is installed on this machine, so every count in this chunk, baseline included,
  already ran them. Run this form anyway to confirm the tag is exercised, and use `LAIN_NVIM=0`
  when you want the fast path.
- `bundle exec rubocop -a` (never `-A` — see CLAUDE.md) and `pre-commit run --all-files`.
- `bundle exec rake compile && cargo test && cargo clippy --all-targets -- -D warnings`.
- `spec/output_discipline_spec.rb` must stay green.
- `Ractor.shareable?` on `QuestionSet` and `AnswerSet` via `be_deeply_frozen`.
- Confirm no existing tool's emitted JSON schema changed (T1/T3), and that `ask_human`'s change
  is the only movement in the tools-block cache prefix (T6).

**Manual passes owed to Joel** (named so they do not silently drop):

1. `lain chat --nvim` — a set of three questions with mixed single/multi select. Tick with `x`,
   write comments, `:w`, and confirm the agent received what you meant.
2. In that same buffer, put the cursor on a comment line and press `x` — confirm it deletes a
   character (ruling 11).
3. A second set arriving while the first is open — confirm the open buffer is undisturbed and the
   new set lands in the inbox.
4. Submit with another set pending; confirm the next autoloads. Submit the last; confirm the
   return to the inbox.
5. A subagent asking a question — confirm the arrival note, the dunst notification, and the inbox
   line all attribute it to the **child**.
6. `lain chat` with no nvim — confirm a structured question is answerable and does not deadlock
   (ruling 7). Then the same with nvim attached but answered at the TTY instead.
7. A question body containing a fenced mermaid block and a fenced `- [x]` line — confirm it
   degrades to a readable code block and no selection is taken from the fence.
