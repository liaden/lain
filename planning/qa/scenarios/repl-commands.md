# Scenario: every command at the `you>` prompt

**What it exercises:** `Command::Registry` and the twelve commands nothing else drives — `/help`,
`/pin`, `/unpin`, `/keep`, `/btw`, `/rewind`, `/undo`, `/fork`, `/goal`, `/meta`, `/review-submit`,
`/introspect` — alongside the eleven that other scenarios touch only in passing (`/status`,
`/sessions`, `/mode`, `/model`, `/approve`, `/quit`, `/ruby`, `/inbox`, `/review`, `/survey`,
`/implement-epic`). Twelve plus eleven is the whole registry — twenty-three commands, pinned as a
literal roster at `spec/lain/cli/command/surface_spec.rb:143-147`. `/implement-epic` is driven end
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

**Read `method.md`'s standing rule about `/mode auto` first.** It says never to raise the posture to
`auto` during a round — correctly, because an approve-all gate answers every question the rest of
the method exists to ask. §6 is one of the two sanctioned exceptions, it is scoped to a throwaway
tree, and it exists to check that `auto` does what it claims **and no more**. Do not carry the
posture into another section: §6 ends with `/mode !`.

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
Before any turn: occupancy reads "no turn yet in this run" and review reads "none held by /review or
/survey". After a turn: occupancy is a percentage, the token rows are populated, and the cache-hit
row reads a ratio or "nothing billed on the way in yet" if nothing was. **Check the `unreported`
row names all three gaps by word, every time** — which provider is answering, how large the window
is and whether that size was measured or guessed, and a review the agent opened for itself via
`request_review` (the outbox `/introspect` reads holds only what `/review` and `/survey` put there).
A row that goes quiet instead of naming its gap, or a number that looks measured but was guessed, is
the failure this command exists to catch — read `cli/command/introspect.rb`'s class doc for the
fabrication this was written against.

`/mode` reports the posture and its active layers. The postures, most restrictive first, are
`plan`, `manual`, `accept_edits`, `auto`; the layers are `auto_approve`, `goal`, `notify`, `vi`.
Drive the full grammar:

```
you> /mode +notify        enable one layer, posture unchanged
you> /mode -notify        disable it
you> /mode +nosuchlayer   must name the four valid layers
you> /mode plan
you> /mode nosuchposture  must name the four postures, most restrictive first
you> /mode !              reset -- most restrictive posture, NO layers
```

**`/mode !` is a reset, not a step**, and the design note says why it leads: like `<Esc><Esc>` in
vim, its promise is that afterwards you know where you are. Set `accept_edits` plus two layers, then
`!`, then `/mode` — the report must show `plan` with **no** layers. `accept_edits` is not the top
rung, but it is two rungs above the floor, so the same reset still proves that `/mode !` drops every
layer **and** walks the posture all the way to `plan` in one move, not merely off whatever rung it
was on. (`method.md` sanctions raising the posture to `auto` in exactly two places, and §1 is
neither — see §6 for that drive.) A reset that keeps a layer, or that walks the posture down one
rung at a time, is the finding.

**And check the switch writes ONE record, not an intermediate ladder.** A `/mode !` from
`accept_edits` that journals `manual` on the way down to `plan` has written a posture the session was
never really in, and every later fold reads it as real.

**The prompt itself shows the posture, and it must follow `/mode` at the very next prompt.** This is
the half that had no check: `/mode` reporting correctly while the prompt shows a stale posture is two
surfaces disagreeing about the same state, which is the class of defect this whole scenario exists
for. Drive `/mode accept_edits`, then look at the prompt *before* typing anything else, then
`/mode !` and look again. The wiring hands the prompt composer the **live** mode switch rather than a
snapshotted posture precisely so this works; a prompt frozen at the posture the session started in
is the regression, and it is invisible to `/mode`.

**Each switch record names the toolset the flip resolved** — `toolset_digest` plus `tool_names`, read
*before* the flip applies, so the record describes the set the incoming posture declared and not the
outgoing one's. Two checks on the journal:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next; next unless r["type"]=="mode_switch";
  puts "#{r["from"]}->#{r["to"]} #{r["toolset_digest"]} (#{Array(r["tool_names"]).size} tools)"}' "$JOURNAL"
```

Every `mode_switch` line must carry a non-null `toolset_digest` — it is a required attribute, so a
null means some caller journalled without one and the validation was bypassed. And the digest must
**change across a posture flip that changes the tools**: `plan` and `auto` resolving to the same
digest means the record is reading a live slot rather than the resolution, which would file each
flip under the previous posture's tools. Cross-check one digest against the session header's
toolset digest to confirm they are comparable values and not different shapes.

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

**Every refusal on the digest path says the grammar out loud.** That is deliberate and it is the
thing to check: a refusal that says only "no turn matching …" leaves a human guessing whether they
typed a prefix, a full digest or an index. Confirm the grammar sentence is present on **all four**
refusals above, including the ambiguity one:

```
you> /pin <a 4-char prefix matching two turns>   -> "…is ambiguous on this session's chain: <a, b>"
```

Manufacture the ambiguity deliberately — run enough turns that two digests share four hex characters,
or pick a shorter shared prefix. It is the one refusal that cannot be provoked by typing nonsense,
and so the one most likely never to have run.

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

**The one that has to be driven deliberately:** a rewind that lands on an assistant `tool_use` turn
still awaiting its tool results must refuse by name. Manufacture it — start a turn that calls a
gated tool, leave the approval parked, and rewind onto it from another surface. The refusal shares
its vocabulary with `/fork`'s `MID_TOOL` door and with `failure-injection.md` §2's torn head; check
all three say the same thing about the same shape, because three different sentences for one state
is how a human learns to distrust all of them.

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
the first `/undo` above, the second must say *the only*, not *the latest of 2*.

**Verify the effect, not the message**, as with `/pin`: read the files. Both directions must work —
a turn that **created** a file has that file **deleted** by the undo, and a turn that **deleted** one
has it restored. The success line distinguishes them (`restored …; deleted …`), and a turn needing
neither says `no file needed putting back` rather than claiming a move.

### The refusals, which are where this command earns its keep

Every one lands **before anything moves**, and the last sentence of the blocked refusal says so
(`Nothing was changed.`) — confirm that is true by reading the tree after each refusal, because a
refusal that has already half-applied is the worst failure available here.

1. **A turn in flight.** `cannot undo while a turn is in flight: a tool call may still be parked, and
   it could write after the files are put back`. Manufacture it from a second surface while an
   approval sits parked.
2. **A live supervised worker.** `cannot undo while <role> (<worker_id>) is still running and may be
   writing; let it settle or stop it first` — and it must **name** the worker, role and id both. Drive
   it with a subagent running (`subagents-and-backends.md` has the launch).
3. **A blocked path.** The refusal names **each** path and why, from a closed list of seven reasons:
   `dirty` (changed since that turn), `symlink`, `directory` (something in the way the turn did not
   make), `outside_root`, `ignored` (`.gitignore`'d, so nothing recorded what it held), `unrecorded`
   (first written in that turn), `nested_repository`. The cheap three to provoke by hand are
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

**One scope caveat to read in the output, not in the code.** A turn recorded under the **write-set**
scope appends `Only files lain's own tools wrote were restored: that turn ran under the write-set
scope, which records nothing a shell did.` Drive one turn in each posture — the snapshot scope
follows the posture — and confirm the caveat appears on the write-set one and **not** on the
shadow-git one. A caveat printed unconditionally is as bad as one never printed: it teaches a human
to distrust a complete restore.

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

## 5 — `/review-submit`, with nothing to submit

```
you> /review-submit        with nothing open
you> /survey ./lib
you> /review-submit        with a SURVEY open -- a survey has no pull request
```

Two distinct refusals; "nothing is open" and "there is nowhere to post" have nothing alike as
remedies and must not share a sentence. `changeset-review.md` §7 drives the third case (a local
branch review) and the no-network check; do not repeat it here.

## 6 — `/mode auto`: reaching an approve-all gate, once, deliberately

One of the two exceptions to `method.md`'s standing prohibition, in a throwaway tree with nothing
sensitive in it beyond the fixture `secret-boundary.md` §0 builds. §1 drove the `/mode` *grammar*;
this section drives what the top rung actually does to the gate, which nothing else here reaches.

```
you> /mode auto
you> /mode
```

Check four things and then stop:

1. `/mode` reflects it — an `auto` that does not show up in the posture report is a hidden state
   change, and the HUD lighter must read `AUTO` too (`cockpit-surfaces.md` §7). `accept_edits`'s
   lighter is the empty string, so `AUTO` appearing is the only visible difference and its absence
   is the finding.
2. A gated `bash` now runs without a prompt. That is the claim.
3. **Nothing parks.** `auto` **replaces** the ladder rather than short-circuiting it —
   `Mode::Resolution` hands the Gate `ApproveAll` in the ladder's place — so the queue is still
   built and `/approve` still drains it, it simply never receives anything. Type `/approve` after
   the unprompted call and it must answer `no pending approvals`, and the journal must carry no
   escalation rungs for that call. A parked-and-auto-drained call and a never-parked one look
   identical at the prompt and are not the same session.
4. **A `denied` path is still refused.** `read_file` on the fixture key must fail under `auto`
   exactly as it does at `accept_edits`: `Middleware::Sensitivity` runs *ahead of* the gate, so no
   policy can lift it. Type the path **resolved and absolute**, for the reason `secret-boundary.md`
   §5 gives — a `~` or a `$HOME` is not expanded on the `read_file` arm. The `bash` spelling of the
   same probe (`cat` on that path) is §5's and goes through a different rung; drive it there, and
   read §5 before assuming the two answer alike. Running the `read_file` half in both places is
   deliberate, because a regression could land in the command surface rather than in the boundary.

Then `/mode !` and confirm the floor is back — posture `plan`, no layers — before anything else in
the round. **`!` lands on `plan`, which permits reads only**, so type `/mode accept_edits` to get the
round's default back before §7, whose `/goal` drives edits and would otherwise be refused by the
posture rather than by anything under test.

## 7 — `/goal`: the only loop a command starts

```
you> /goal                          with none set: "no standing goal -- /goal <objective> to set one"
you> /goal make lib.rb have a #size method
```

The reply names the three terminating conditions:
`goal set: <objective> -- driving after each turn until <DONE>, the cap, or /goal off`. **All three
must actually terminate it** — drive each in its own session:

| how it ends | how to drive it |
|---|---|
| the model says done | give it a one-step objective it can finish |
| the cap | give it an objective it cannot finish, and count the turns |
| `/goal off` | type it mid-drive |

`/goal off` must yield `goal off -- the driver stops re-prompting; type your next line at you>` and
the **next** prompt must actually be a `you>` read, not another driven turn. A driver that gets one
more prompt in after `off` is the finding, and it is exactly the shape that makes a runaway loop
expensive.

The cap is the one to record numerically: **note how many turns it ran and what that cost**. Nothing
else in `planning/qa/` records tokens per act, and a self-driving loop is where that gap is most
expensive.

Also confirm the `goal` **layer** appears in `/mode` while a goal is standing, and clears when it
ends — the layer and the driver are two objects and this is the only place they are checked against
each other.

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

**Review the generated script before running it.** The usage line says so and the round should obey
it — `/meta` generates something that then executes, and a QA round that pipes a model's output
straight into a launch is the one act in this whole directory that can damage the sandbox.

## 9 — The one structural property, and how to see it

`Registry#serves_replies?` asks whether a command is **itself** a reply surface — one that opens its
own `human>` read over the pending questions. Exactly one command answers yes: `/inbox`. It matters
because a reply loop started *around* such a line would read the same stdin the command is reading.

`cockpit-surfaces.md` §5b drives `/inbox`'s own drain. What belongs **here** is the negative: with a
question parked, type a **different** command at the `human>` prompt — `/status`, `/pin`, `/mode` —
and confirm each runs and returns to the `human>` read with the question still parked. A command
that swallows the parked question, or that drops the reply loop, is the failure, and it can only be
seen by driving commands that are *not* `/inbox`.
