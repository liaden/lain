# Survey dogfood supplement — 2026-08-25 — `/survey` over lain, on the cloud arm

Findings from the **paired** session described in
[`planning/survey-dogfood-2026-08-25.md`](survey-dogfood-2026-08-25.md): the human drives the
review at the keyboard, the agent reads state beside it. Not a `manual-qa` round — round 11
(`qa-findings-round11-2026-08-25.md`) drove `planning/qa/scenarios/survey.md` agent-driven on the
**local** arm and discharged it. This is the supplement that spends: `--provider ollama-cloud`,
lain's own tree as the subject.

**Numbering continues from F70**, not from F66 as the pairing plan's §6 predicted — that plan was
written before round 11 ran and consumed F64–F70.

## Setup, for the record

`gpt-oss:20b-cloud`, cockpit at 206x88 (nvim 145x87 / chat 60x87), launched through an absolute-path
shim sourcing `.envrc`. Branch `survey/dogfood-2026-08-25`. Journal
`~/.local/state/lain/sessions/90e709ee23c9/20260825T171316-1983356.ndjson`.

Free pre-checks from `ollama-cloud-arm.md` §1 passed: the missing-key refusal names the variable,
the URL and **which flag asked**; the plaintext refusal argues https in the arm's own terms.
`capability_degraded: prompt_caching` at session open is correct — `Deployment::Cloud` declines to
declare a cache it cannot demonstrate.

**One scenario correction, not a defect.** `ollama-cloud-arm.md` §1's third case predicts
`--provider ollama --summarizer-provider ollama-cloud --api-base http://127.0.0.1:11434` refuses.
It constructs, and should: `cli/backend/ollama_tier.rb:238` states the plaintext refusal is
unreachable from a summarizer tier because such a tier is handed no base at all, and §2 of the same
scenario already documents the corrected behaviour. Flag attribution is right — strip the key and
the refusal names `--summarizer-provider`. §1's bullet is stale and should be rewritten to §2's
account.

## Scenario checks discharged in passing

- **`ollama-cloud-arm.md` §3 — PASS.** The window resolves **128,000, `provenance: "published"`**,
  not the `CONSERVATIVE_FALLBACK` of 8,192 tagged `guessed`. Read from `compaction_decision` records
  in the journal (five of them, all agreeing), which is firmer than the status line by eye. This
  matters beyond the number: a `guessed` denominator would make `Compaction::Source` decline
  `:approaching_window` entirely, and a 1,729-file survey is exactly the shape that needs it.
- **`survey.md` §2 — PASS.** `/survey .` over lain's own root refused at **1,729 files** against the
  300 ceiling, and `#cumulative_advice` composed the narrowing remedy: *"this corpus is 1729 files,
  over the ceiling of 300 -- survey a subdirectory instead, or raise the ceiling with --unbounded"*.
  First time that refusal has fired on a tree it was written for, with a human reading it.
  `--unbounded` then opened all 1,729.

---

## F71 — WITHDRAWN — "which-key does not know the note keys"

**Withdrawn with its mechanism, before it was ever filed properly.** The observation was real —
`<leader>L` produced no listing of the note gestures — but the cause is not registration, and the
finding as first written would have sent someone to fix a plugin integration that is not broken.

**What the live editor says.** In the **stamped** review buffer (buffer 19, `exe/lain`) all five
keys are bound, each carrying its description:

```
 Lt :: lain: open the thread on this line
 LN :: lain: hand every note back
 Lb :: lain: blocker on this line (finish it, then <CR>)
 Lq :: lain: question on this line (finish it, then <CR>)
 Ln :: lain: note on this line (finish the sentence, then <CR>)
```

which-key is loaded (`pcall(require, "which-key")` → true) and will list these, because they exist
and carry `desc`. The prefix looked empty because the press happened in an **unstamped** buffer,
where `48_annotate.lua:618-627` has deliberately deleted them. The keys are advertised exactly
where they work; that is the design, stated in `lain.txt` and in the binder's own comment.

**What survives as a real question** is not which-key's, and it is F73: the human was in a buffer
they had every reason to believe was the review.

---

## F72 — MED-HIGH — `:LainNote`'s refusals are delivered as a Lua stack traceback

**What is wrong.** The refusal wording is good; the delivery is not. Verbatim from `:messages` in
the live cockpit:

```
Lua :command callback: lain: :LainNote needs a buffer lain has open for review
stack traceback:
	[C]: in function 'error'
	[string "<nvim>"]:2611: in function <[string "<nvim>"]:2607>
```

Under a `vim.notify` replacement (snacks.nvim here) the same refusal arrives as a notification
toast, so what the human actually sees is a plugin's popup and a traceback rather than lain's
sentence.

**Mechanism.** `48_annotate.lua:438` raises with `error("lain: ...", 0)`. The `0` correctly
suppresses *position* information, but a `nvim_create_user_command` callback that throws is still
reported by nvim with the `Lua :command callback:` prefix and a traceback appended. Level 0 is not
enough on this path; the same is true of the sibling refusals at `:442` and `:447`.

**Why this is not a new class of defect.** This is **round 7's F31 at a different site.** F31 was
the thread pane's `BufWriteCmd` refusal raising a traceback plus a `Press ENTER` modal, and round 11
verified it fixed for `:LainThread`. `:LainNote` has the same shape and did not get the same
treatment, which suggests F31 was fixed at the site rather than at the rule.

**Against the session's standing rule** (`survey-dogfood-2026-08-25.md` §5): "A refusal with
`stack traceback:` is **always** a finding, regardless of how good the sentence is." Filed on that
rule.

**Severity argument.** MED-HIGH rather than MEDIUM because it fires on the *most common* wrong
guess a human makes about this feature — trying to annotate a file that is not the review buffer —
and it fires as a traceback, which reads as "lain crashed" rather than "you are in the wrong
buffer". It is the first thing a new user of `/survey` will hit.

---

## F73 — MEDIUM — reading the code silently ends the review, and nothing says so

**Resolved from F73's open question.** The human reached `lib/lain.rb` with **`gf`**, from the
`require "lain"` line inside `exe/lain` — the stamped review buffer. So `open_changeset` never ran,
no stamp was ever owed on `lib/lain.rb`, and every mechanism above behaved exactly as designed.

**That is what makes it a finding rather than user error.** The design pulls in two directions and
the human is standing where they meet:

- `47_diff.lua:184` keeps the new side's `buftype = ""` **deliberately**, so it is THE FILE and not
  a scratch copy, "precisely so LSP and treesitter attach" (round 7's F34 notes). A real file buffer
  with LSP attached *invites* `gf`, `gd`, go-to-definition, tag jumps — the ordinary vocabulary of
  reading code.
- `48_annotate.lua:618-627` scopes the note keys to the stamp, so every one of those gestures
  silently ends the review, **in the same window, with no visual change** beyond the file content.

Reviewing code *is* reading code. The gesture that follows a `require` is not a mistake; it is the
review. But there is no indication — no statusline mark, no sign column, no title, nothing in the
sidebar — that the window stopped being the review, and the first feedback is **F72's traceback**.

**Compounded by F74**: the one documented gesture for "I am reading a file that should be in this
survey" is `<leader>Lsa`, and it is a silent no-op.

**What would settle it** is a decision, not a patch: either the review window advertises its own
membership (so leaving it is visible), or the note rail follows the human out (annotating any file
in the surveyed tree, which is what a *corpus* review arguably means), or the refusal at F72 teaches
the way back — "this buffer is not the review; press `<CR>` on a sidebar row". Today it does none of
the three.

---

## F74 — MEDIUM — `:LainSurveyAdd` is documented as working, acks success, and does nothing

**What is wrong.** `plugin/nvim/doc/lain.txt:330-336` documents the gesture in the present tense:

> `<leader>Lsa`, from a real file buffer, runs `:LainSurveyAdd`: it adds the file you are reading
> to a survey open in this chat.

It does not. There is **no `survey_add` route**. `HumanReplies::Gestures#routes`
(`lib/lain/cli/human_replies.rb:842-851`) carries exactly `open`, `pin`, `review_open`,
`review_mark`, `review_ask`, `approval`. Grepped across `lib/`, the only three occurrences of
`survey_add` are the `vim.rpcrequest` at `46_sidebar.lua:327` and two comments.

**And the no-op is indistinguishable from success.** `Router#call` is `@routes[verb]&.call(...)`
(`rpc_thread.rb:741`) — a silent no-op for an unknown verb — and the ack `respond(request.id, true)`
has already returned by then. So the key presses cleanly, reports success, and nothing happens.
There is no refusal to read and no journal record to check.

**The runtime is honest; the manual is not.** `46_sidebar.lua:283-290` states the situation plainly
— "today, ahead of B12, pressing this key sends `survey_add` into `RpcThread#command_inbox` for
nobody yet to drain" — and even explains why an unrouted verb cannot raise. The defect is that
`lain.txt` describes the finished feature, in the same register as every gesture that works, with a
further paragraph at `:353-359` detailing refusals and payload shape it never gets to exercise. A
reader has no way to tell this entry from a working one.

**Cheapest honest fix, pending B12:** mark the `lain.txt` entry as not yet wired, and have the
command refuse in words rather than ack. A gesture that says "not yet" is strictly better than one
that says nothing, and this is the entry a human reaches for at exactly the moment F73 strands them.

---

## F75 — MED-HIGH — the chat agent cannot see the human's notes, and does not know that it cannot

**What happened.** Asked in the chat pane, twice:

```
you>   What notes have I attached so far?
? lain Which notes are you referring to? Are you asking for a list of all notes stored in
       memory, or...
human> From the survey command and the stuff I have done within neovim
? lain You mentioned the "survey command" and the work done within Neovim. Could you clarify
       which s...
```

Two round trips, two parked `ask_human`s, no answer.

**The answer was available and is not reachable from where it was asked.** Traced end to end:

- A note is an extmark until `:LainNoteDone`, which sends the verb `review_notes`
  (`48_annotate.lua:564`), routed at `rpc_thread.rb:876` to `ReviewWrite.notes`.
- From there `Handover#wrote_annotation` (`review/handover.rb:365-369`) puts it in exactly two
  places: `@session.annotate(...)` — read by the **verdict policy** — and `@docent.hold(placed)`,
  which is what lets a **thread** open at that anchor.
- It reaches **neither** the Timeline, the Toolset, nor the Workspace. `Context#render` is
  `(Timeline, Toolset, Workspace) → Request`, and grepping `annotation` across `lib/lain/context*`
  and `lib/lain/workspace*` returns **nothing**.
- No tool exposes them either: nothing in `lib/lain/tools/` reads annotations
  (`request_review.rb` *opens* a review; it does not report one).

So the question is unanswerable by the chat agent **by construction**, not by accident of this
turn. The notes are visible to the verdict policy and to the docent, per anchor, and to nobody else.

**And in this session the true answer was simpler still:** `annotation_placed` count in the journal
is **0**. Nothing had been handed back — F73 is why — so the honest reply was "none yet, and here is
how to hand them back". Nothing on this path can produce that sentence.

**How much of this is the model.** Some. Round 11's F64 already recorded gpt-oss:20b "looping on
clarifying questions instead of acting", and this is that shape. But the model had no capability to
discover and no refusal to hit, so the clarifying loop is the only move left to it. **The lain half
is the missing capability and the missing refusal**; the looping is the model half, already known.

**Note the asymmetry this exposes.** `review_ask` lets the human ask the *docent* about the code.
Nothing lets anyone ask about the *human's own commentary* — the one artifact of a review that the
human produced and might reasonably want read back, summarised, or acted on.

---

## F76 — LOW-MED — `inbox_count` and the inbox buffer disagree

**Measured, same moment.** HUD state (`status/90e709ee23c9/state.json`) reads `"inbox_count": 2`.
The `lain://inbox` buffer, read in full over RPC, renders **one** question — the second one. The
first ("Which notes are you referring to...") appears nowhere in the buffer.

Same family as round 11's **F64**, which was two surfaces disagreeing about whether a docent
question was live; this is the chat's own `ask_human` path, and the disagreeing pair is the HUD
counter against the buffer.

**Not diagnosed further.** Whether the counter counts questions while the buffer renders sets, or
the first question was dropped from the buffer while still counted, is unresolved — recorded as a
measurement, not a mechanism.

---

## F77 — HIGH — asked for its own session usage, the agent FABRICATED a telemetry table

**What happened.** Asked in the chat pane: *"for my ollama backend session here what is my usage?"*
The reply was a confident, well-formatted metrics table — and **every value in it is invented**:

| the model reported | the truth |
|---|---|
| Model in use: **`llama3.1:latest`** | `gpt-oss:20b-cloud` — it named a model this session never touched |
| Memory: **~1.2 GiB**, "4 GiB allocation trimmed to 1 GiB" | not observable from the agent at all |
| CPU: **~0%** · RTT: **~150 ms** · Disk: **~500 MiB reads** · Network out: **~0.5 MiB** | all fabricated |
| "The last request finished about 3 seconds ago" | fabricated |

It then offered remediation for a deployment that does not exist here — `docker logs
<ollama-container>`, `systemctl status ollama`, a Prometheus `/metrics` endpoint.

**The true answer was in the journal, in the shape the question asked for.** Eight `turn_usage`
records, each carrying model, stop reason and exact counts:

- **8 turns**, all `gpt-oss:20b-cloud`
- **27,997 input tokens**, **2,376 output tokens**
- `cache_creation_input_tokens` and `cache_read_input_tokens` **0 on every turn** — correct, and
  itself the interesting number, since `Deployment::Cloud` declares `NO_CACHING`

So lain **had** the data, in a structured record, and the agent produced fiction instead.

**Same root cause as F75, worse failure mode.** F75 established that no tool and no context path
exposes session state to the chat agent. When asked about notes it looped on clarifying questions;
asked about usage it **confabulated**. Both follow from "no capability to answer, and no refusal to
hit" — but a clarifying question wastes a turn, while an invented telemetry table is *actively
harmful*: it is plausible, well-formatted, and indistinguishable from a real reading.

**Why HIGH on this bench specifically.** Token accounting is not incidental here — it is the
instrument. `planning/qa/` exists to establish that the record is unforgeable
(`failure-injection.md`'s whole premise), `bench-arms.md` asks whether an arm can "refuse a price it
cannot stand behind", and `Provider::Ollama::Deployment::Cloud` refuses to declare `prompt_caching`
precisely because it "cannot demonstrate a cache hit at all". An agent that will invent
`cache_read_input_tokens`-shaped prose on request contradicts that discipline from inside the
harness, and a human pasting that table into a findings doc would be recording fabricated
measurements as data.

**Note also there is no `/usage` or `/cost` command.** The REPL registry has 23 commands and none
reports session spend; the data lives in the journal and is reachable by `/ruby` only if the
inspection window is widened (E2). So the *human* is one step from this answer and the *agent* is
infinitely far from it, which is the same asymmetry E2 and F75 describe, now with a cost attached.

**Partly the model.** gpt-oss:20b's confabulation is its own; round 11's F64 already recorded this
model's habits. But the harness gave it no `usage` capability, no refusal, and no grounding, and the
question it was asked is one lain answers about itself in five places.
---

# Enhancement notes

Design asks from the session, kept apart from the findings above because nothing here is broken.

## E1 — the note input should grow into a real surface as the note gets long

**The ask.** Typing a long note on the cmdline is cramped. It should expand — into a floating window
or a scratch buffer — once the text outgrows a single line.

**Worth having, and the obvious implementation is the one the design already refused.**
`48_annotate.lua:428-433` states it: `:LainNote` is synchronous *deliberately*, where
`65_review.lua`'s `:LainAnnotate` prompts through `vim.ui.input`. That call is **asynchronous under
the dressing plugins that replace it** — and this cockpit is running one of them, snacks.nvim, which
is exactly a `vim.ui.input` replacement. The stated consequence: two overlapping prompts would put
the placement **sequence** at the mercy of how fast the human types, "and the sequence is this
card's whole output". Placement order is what `:LainNoteDone` hands back and what round 7's §4b
check measured (order 5, 9, 2, 3). So a naive `vim.ui.input` swap would trade a cramped input for a
corrupted record.

**But the constraint is narrower than it looks, and lain already ships the shape that satisfies it.**
The docent thread pane (`51_thread.lua`) is *already* "a real buffer you type into, `:w` to commit",
with its refusal semantics worked out and its `BufWriteCmd` raise fixed (round 7's F31, verified
round 11). That is the surface E1 is asking for, built, in this codebase, one file away.

What makes the thread pane safe is not that it is synchronous — it is not — but that it is **modal**:
one pane, one anchor, committed by an explicit `:w`. Ordering survives if the sequence number is
assigned when the editor **opens** rather than when it commits, or if only one note editor may be
open at a time. Either preserves "placement order is the output" without a cmdline.

**Two things that do not object:**

- **The data model.** `Wire.text` is `value && -value.to_s` (`review/wire.rb:39`) — interning only,
  no newline restriction — and the journal is NDJSON, which escapes a newline inside a JSON string.
  A multi-line body reaches `Lain::Review::Annotations` and the record intact.
- **The rendering.** The inline marker is right-aligned and names the **kind**, never the text —
  `:LainNote`'s own docstring says "the words themselves belong to the thread, not to the margin".
  So the margin already costs nothing for a note of any length; the display side of E1 is done.

**What would need deciding**, if this is picked up: where the sequence number is assigned, and
whether the small case keeps its cmdline. The cheapest shape that honours both the constraint and
the existing teaching behaviour is probably *cmdline by default, escape hatch to a pane* — the
cmdline entry also "leaves the command's name on screen, which is how the key teaches what it is a
shortcut for" (`48_annotate.lua:601`), and that is worth keeping for the short notes that are most
of them.

**Not implemented.** Recorded at the human's instruction.

## E2 — the chat should be able to introspect lain itself, its Ruby, and the live environment

**The ask.** The chat agent should be able to answer questions about the running system — lain's own
state, the Ruby objects in play, the defined environment — rather than only about files on disk.

**Most of this exists, for the human, and the asymmetry is the point.** `/ruby` (T22,
`cli/command/ruby.rb`) already does it, in three arities: bare opens an embedded IRB console over the
live binding, an expression renders its `inspect`, a path runs a file against the same binding.

What it inspects through is `CLI::InspectionBinding` — already built, already scoped, already
argued: frozen ("read-mostly is mechanical rather than a convention"), with `self` resolving exactly
`timeline`, `session`, `supervisor`, `status` and nothing wider, because "the binding is a window,
not the whole run". So E2 is not a blank-page design. It is the question of whether that window is
handed to the model as a tool, and if so which panes it has.

**What the agent has today is STATIC introspection only.** The toolset carries `ast_search`,
`ast_dump`, `code_outline`, `file_symbols` — all of which read **source**. Nothing reads **runtime**.

**`bash` is not the missing piece.** The model could already shell to `ruby -e`, but that is a fresh
process: it cannot see the live Timeline, the open `Review::Session`, the docent, or the
annotations. The value in E2 is precisely the in-process state, which is the one thing a subprocess
can never reach.

**Constraints and open questions anyone picking this up will meet:**

- **Purity is NOT a blocker, contrary to first appearance.** `Context#render` stays the pure
  `(Timeline, Toolset, Workspace) → Request`; a tool is an `Effect` evaluated at call time whose
  *result* lands on the Timeline like any other. Introspection does not threaten prompt-cache
  stability.
- **The real risk is the observer effect, and it is stated in the target's own docstring.**
  `InspectionBinding` is read-**mostly**, not a sandbox: "The collaborators' own methods stay
  callable -- this scopes the surface, it does not sandbox the objects." A model holding that
  binding can call a mutating method on the session. On a bench whose deliverable is the experiment
  record, and whose object of study is the loop, an agent able to perturb its own run is a different
  proposition from a human doing it deliberately at a REPL.
- **Frozen values make the reading half safe by construction.** Timeline events are deeply frozen
  (`Ractor.shareable?(event)`, with a spec). It is `session` and `supervisor` that carry live
  mutable behaviour.
- **First scope decision, and it is concrete: the review surface is not in the window today.**
  `InspectionBinding.for(env)` takes `timeline`, `session` (the *agent's*), `supervisor`, `status`.
  `Command::Env` (`cli/command/env.rb:6-8`) carries no review reader at all — the review lives behind
  `replies`. So **`/ruby` cannot answer F75's question either**: "what notes have I left" is not
  reachable from the binding as scoped, even for the human. Whether review state joins the window is
  the first thing E2 has to decide, and it is the same decision F75 needs.

**Not implemented.** Recorded at the human's instruction.

## E3 — language-aware highlighting in the surfaces that do not have it

**The ask.** Syntax highlighting for the language of the code being read, while reviewing under
`/survey`.

**Measured first, because part of this already works.** Every buffer holding real code in the live
cockpit is fully highlighted, treesitter attached:

| buf | name | `filetype` | treesitter |
|---|---|---|---|
| 19 | `exe/lain` (extensionless) | `ruby` | **active** |
| 28 | `lib/lain.rb` | `ruby` | **active** |
| 70 | `lib/lain/agent.rb` | `ruby` | **active** |

That includes `exe/lain`, which has no extension and is detected by shebang. So the file a `<CR>`
opens from a survey row is already language-highlighted — this is `47_diff.lua:184` keeping
`buftype = ""` deliberately "so LSP and treesitter attach", working as designed. (Buffer 70 also
reads `stamped = "new"`, and buffer 19's stamp has been correctly withdrawn — `open_changeset`'s
stamp/unstamp contract confirmed sound a second time, cf. F73.)

**The two surfaces that genuinely lack it:**

1. **`lain://diff` is `filetype=diff`.** It highlights the `+`/`-` structure and nothing about the
   language inside it. Currently loaded, it holds a JSON tool-call diff rendered with no JSON
   highlighting at all. A diff of Ruby would be the same. This is the surface where "the language
   within the buffer" is most literally missing.
2. **lain's own `filetype=lain` buffers** — journal, timeline, inbox, approval, and the `lain://review`
   sidebar. These carry one small hand-rolled regex syntax (`20_buffers.lua:131-137`: tool names,
   `blake3:` digests, roles, event kinds, ages, senders), and the module says plainly "no treesitter
   grammar shipped". Every group is `lain`-prefixed so a human's own syntax plugins cannot collide.
   The survey sidebar under this filetype is 1,729 rows of `[ ] path`, so what it would want is
   path/mark structure rather than a language.

**Open question, to be settled by the human:** which of the two the ask is about. They are different
pieces of work — (1) is treesitter language injection into a diff buffer, (2) is a grammar or
extended regex syntax for lain's own record format.

**Not implemented.** Recorded at the human's instruction.

## E4 — comment density has drifted 2–4x past the codebase's own stated exemplar

**The observation.** Reading the code during the survey: the comments are voluminous enough that the
eye skips them, they change the shape of the code, and at these line lengths the result reads as
walls of text rather than as code with notes.

**Measured, because the impression deserved numbers.**

| | |
|---|---|
| `lib/**/*.rb` comment lines | **66,764** |
| `lib/**/*.rb` code lines | **42,391** |
| ratio | **1.57 comment lines per code line** — 61% of non-blank `lib/` is comment |
| files where comments outnumber code | **482 of 678 (71%)** |
| median file ratio | 1.39 · p75 **2.04** · p90 **3.08** |
| longest unbroken comment block | **216 lines** (`status_feed.rb`); then 167, 147, 140, 126, 126 |
| 40-line viewports containing **zero** code | 4,015 of 95,741 (**4.2%**) |
| comment line width | median 76, p90 80 |
| nvim runtime Lua | 1.72:1 (`47_diff.lua` 370c/172L, `46_sidebar.lua` 234c/87L) |

**The sharpest form of it: the codebase has drifted from the exemplar it names.** `CLAUDE.md` says
"Comments are minimal, and explain WHY", "Comment only what is *forced*", and **"Match
`lib/lain/timeline.rb`"**. Measured:

| file | ratio | longest block |
|---|---|---|
| `lib/lain/timeline.rb` — **the stated exemplar** | **0.79** | **24** |
| `lib/lain/event.rb` | 0.93 | 24 |
| `lib/lain/canonical.rb` | 1.09 | 17 |
| median file in `lib/` | 1.39 | — |
| p90 file in `lib/` | 3.08 | — |
| worst (`review/vocabulary.rb`) | 7.90 (79c / 10L) | 21 |

In the exemplar, code outnumbers comment and no block exceeds 24 lines. The median file is **76%
denser** than it; the p90 file is **~4x**. So the rule as written is not the problem — the practice
has drifted from its own yardstick, and the drift is measurable rather than a matter of taste.

**The honest counterweight, because it is not one-sided.** Every finding in this document came out
of those comments. F72's severity rests on `48_annotate.lua:428-433` explaining *why* the cmdline is
synchronous; F74 exists only because `46_sidebar.lua:283-290` admits the verb is unrouted; E1's whole
constraint analysis and E2's observer-effect risk are both quotations. An agent doing forensics gets
extraordinary value from this prose — it is frequently the only place a decision's *reason* survives.

So the cost and the benefit fall on **different readers**: expensive for a human scanning for shape,
valuable for anyone (human or agent) reconstructing intent. On a bench whose deliverable is the
study record, that trade is not obviously wrong — but it is currently being made implicitly, at
2–4x the density the project documents.

**What is NOT in question:** the content. Nothing here argues the reasoning should be deleted; the
open question is placement and density — how much belongs at the point of code versus in
`ARCHITECTURE.md`, `docs/`, or a decision log, and whether the 100+ line blocks are load-bearing at
their current position.


### E4 revision — YARD is NOT what makes the walls

Corrected after the human noted that YARD documentation is useful and carries its own skimmable
shape. Re-measured with `@param`/`@return`/`@raise`/`@example`/`==`-section lines and their
continuations counted separately:

| | lines | share of comments |
|---|---:|---:|
| code | 42,391 | — |
| **YARD tag lines** | **6,801** | **10%** |
| **prose comment lines** | **59,963** | **90%** |

So the structured, skimmable half is a **tenth** of the comment mass, and excluding it barely moves
the ratio: **prose:code = 1.41** against 1.57 for all comments. The walls are prose, not
documentation — `review/vocabulary.rb` is 79 prose lines and **0** YARD lines over 10 lines of code;
`core/transport.rb` and `skill/library.rb` are likewise all-prose. `review/surface/neovim.rb` is 305
prose against 56 YARD.

This *strengthens* E4 rather than qualifying it: the part with a shape that supports skimming is not
the part that grew. Any density decision can leave YARD entirely alone and still be addressing 90%
of the mass.

**Not acted on.** Recorded at the human's instruction.

## E5 — plan-ticket references in comments (`T2`, `T15`, `CE-5`, `B12`) are structurally unresolvable

**The observation.** Comments cite identifiers like `T2` that came from implementation plans. Those
plans were ephemeral, and nobody can now say what the identifier means.

**Measured, and it is worse than forgotten — it is ambiguous.** Across `lib/**/*.rb` and the nvim
runtime Lua, comments carry **~182 distinct plan-style tokens in ~1,080 citations**. Taking the 40
most-cited and asking where each is actually *defined* (a heading or table row in `planning/`,
`docs/`, the repo's root markdown, or `~/.claude/plans/`):

| | tokens |
|---|---:|
| defined in **multiple** documents — ambiguous | **32** |
| defined **nowhere** | 3 (`OM-6` ×16, `N-1` ×10, `OM-3` ×8) |
| defined in exactly one place — resolvable | 5 |

**The mechanism: the ID namespace is per-plan and reused by every plan.** Each `planning/chunk-*.md`
numbers its own cards `T1…T22`, so a token is not a name, it is an offset into whichever document
you happen to open.

- `T3` — cited **35×** in `lib/`, "defined" in **36 different documents**.
- `T15` — cited **47×**, defined in 18.
- `T9` — cited 28×, defined in 29.
- `T2` — the human's own example — resolves to `hn-agent-landscape-2026-08.md:666`
  ("a prompt-cache **waste detector**") *and* to `~/.claude/plans/inherited-snacking-ritchie.md:213`
  ("Remove the silent FFI fallbacks"). Two unrelated meanings, no way to choose.

**And the canonical plan defines none of them.** `CLAUDE.md` opens by naming
`~/.claude/plans/jiggly-greeting-avalanche.md` as the approved design plan to read before making
architectural decisions. Grepped for card-heading definitions of `T`/`B`/`I`/`M`/`CE`/`OM` numbers,
it contains **zero**. The one document a reader is pointed at defines none of the identifiers the
code cites.

**The project already has an ID scheme that works, which is the useful contrast.** QA finding
numbers are globally unique across rounds and durably documented: `F31` → `qa-findings-round7-…md`,
`F50` → `round9`, `F64` → `round11`. A reader can resolve those. The difference is not rigour, it is
that F-numbers are allocated from **one** sequence into **durable** documents, while T-numbers are
allocated per-plan into documents that were consumed when the plan was executed.

**Interaction with E4.** These citations sit inside the 90% prose mass E4 measures, and they are the
subset with **negative** value: a reader who stops to resolve `T15` spends the interruption and gets
18 candidate answers. Unlike the rest of the prose — which E4 grants is often the only surviving
record of a decision's reason — an unresolvable ticket ID carries no reasoning at all, only the
suggestion that reasoning exists elsewhere.

**Not acted on.** Recorded at the human's instruction.

## E6 — coverage gap: no QA scenario drives prompts, templates, slots or roles

**Asked:** do the manual-QA scenarios cover the prompt/template/slot/role subsystem? **They do not.**

**Searched** all 15 scenarios plus `README.md`, `method.md` and `bench.md` for `Prompt::`, `Slots`,
`SkillSlots`, `LockedBinding`, `system.md`, `default.toml`, `Role::Catalog`, `templates/role` and
`--role`: **zero substantive hits**. Every "slot" in the scenarios is an *ollama server* slot
(`n_slots`, `OLLAMA_NUM_PARALLEL`) or an *nvim window* slot (`sidebar | OLD | NEW`); every "role" is
a base/head ref role, a message role, or a supervised-restart role name.

**What the subsystem is**, unreached: `Prompt` + `Prompt::Slots` (212 L) + `Prompt::SkillSlots` +
`Prompt::LockedBinding` (162 L), `prompt/templates/system.md.erb`, `prompt/default.toml`,
**14 role templates**, **9 skill template directories** (each with its own `skill`/`conventions`/
`focus`/`sidecar` shape), `Role` and `Role::Catalog`.

**Roles are exercised incidentally, never tested.** `epic-tier.md` spawns the gate adjudicator,
`survey.md` §7 spawns the diff-docent, `repl-commands.md:30` and `bowling-ruby.md:86` drive
`@role[/skill]` dispatch. That reaches **2 of 14** roles as a side effect of testing something else.

**Unit specs do exist** — `prompt/slots_spec.rb`, `skill_slots_spec.rb`, `locked_binding_spec.rb`,
`slot_journal_spec.rb`, `role_spec.rb`, `role_prelude_wiring_spec.rb`,
`frontend/prompt_composer_spec.rb`, `prompt_composer_degradation_spec.rb`, `cli/prompt_breaker_spec.rb`
— so this is not an uncovered subsystem. It is one covered **only** on one side of the seam.

**And the specs are narrow exactly where drift would hide.** `role_spec.rb` pins the
underscore-to-hyphen filename mapping for **3 of 14** roles, by name (`test_engineer`, `court_clerk`,
`dev`). Nothing iterates `Catalog::BUILT_INS`. Measured today, catalog and templates align **14/14
with no drift in either direction** — but nothing pins it, so a role added without a template, or a
template renamed, passes the suite and fails at spawn.

**Why this is the QA bench's own thesis case.** `planning/qa/README.md` opens with: "every defect it
has found so far lived in a seam that had specs on **both** sides." The prompt is precisely that
seam — template files on one side, slot machinery on the other, and what the model actually receives
in between. Unit specs drive `Slots.load` against `mktmpdir` fixtures; nothing verifies that the 14
shipped templates render into a real `Request`.

### The slots are a PROJECT EXTENSION API, which raises what the gap costs

The templates do not merely ship defaults — they declare **named holes a project fills to extend
lain**, at three levels (`prompt/slots.rb`):

| level | path a project writes | shipped side | known set |
|---|---|---|---|
| system | `.lain/slots/system.md` | `templates/system.md.erb`'s `<%= render("system") %>` | `KNOWN = %w[system]` |
| role | `.lain/slots/role/<name>.md` | 14 role templates | the shipped basenames ARE the known set |
| skill | `.lain/slots/skill/<skill>/<hole>.md` | 9 skill dirs, many holes each | shipped hole files |

The model is stated in the class docstring: *"Named HOLES in Lain's base prompt that a user fills
with markdown partials — the mental model is a Rails view partial, not a scripting language."* This
is a **public, user-facing extension surface**, and it is the documented way a project adapts the
agent to itself.

**It has refusal paths at every level, and they are the zero-model kind this bench prizes.** A file
naming an unknown slot raises `UnknownSlot` rather than being silently ignored — three sites in
`slots.rb` alone (`:103` top-level, `:114` role file, `:164` role render), plus the skill level.
`repl-commands.md` was written on exactly this rationale ("every refusal path is a zero-model-turn
path"), and none of these is driven.

**Purity is enforced and well unit-covered** — `LockedBinding` rejects `Time`, `rand` and friends
with `ImpureSlot` (`slots_spec.rb:43-88`), because a fill lives in the cached prefix and the render
must be a pure function of (fills, templates). That half is in good shape.

**The headline the gap actually costs: the cache floor is a SILENT threshold, and the extension
mechanism is what crosses it.** `slots.rb:17-20` says it outright — *"the shipped default is ~70
tokens, so the prefix silently will not cache until an override (plus tools) grows past the floor —
eligible-for-the-cache is not the same as cached."* Measured, `system.md.erb` is **364 bytes**. So:

- a project with no fills is **below** Anthropic's 4,096-token minimum cacheable prefix and pays
  full price every turn, with no error and nothing on any surface saying so;
- a project that fills slots crosses that floor at some unannounced point and starts caching.

That transition is **the** economically significant behaviour of this subsystem, it is invisible to
a unit spec by construction (it is a property of the assembled prompt against a live provider), and
**no scenario drives it.**

**And lain does not dogfood it.** There is no `.lain/slots/` directory in this repository, so the
extension point the project ships has never been exercised by the project itself — nor by any
scenario, which mention `.lain/slots` exactly zero times.

**Not acted on.** Recorded at the human's instruction.

## E7 — the "what unit?" question is ANSWERED for ollama cloud: there is no time window to show

**The standing question.** Show 5-hour and week-long usage on the tmux status line — blocked on not
knowing what the "unit type" was.

**It is answered, and the answer is negative rather than a number.** `references/ollama/cloud.md`
§2, measured 2026-08-24 (and it cost quota to get):

- **On a 200, ollama cloud returns no rate-limit vocabulary at all.** The complete header set is
  `alt-svc, content-length, content-type, date, server, set-cookie, traceparent, via,
  x-build-commit, x-build-time, x-cloud-trace-context, x-frame-options, x-request-id`. No
  `ratelimit-*`, no remaining counter, no quota counter.
- **Forcing a real 429** (32 concurrent `/api/chat` → 13 refusals against 19 successes; 30
  concurrent `/api/show` and 8 concurrent `/api/chat` both drew zero) surfaces five headers absent
  from every 200:

  | header | value | meaning |
  |---|---|---|
  | `retry-after` | 10–20, varying | seconds, integer form |
  | `x-ratelimit-max-concurrent` | 4 | requests the plan may have **running** |
  | `x-ratelimit-active` | 4 | running right now |
  | `x-ratelimit-queue-limit` | 15 | how many it will **queue** beyond those |
  | `x-ratelimit-queued` | 15 | queued right now |

- **No `x-ratelimit-reset`, no `RateLimit-Reset`, no remaining/limit pair.**

**So the unit is CONCURRENCY AND QUEUE DEPTH, not a bucket over time.** There is no 5-hour window
and no weekly window to read, in either direction — used or remaining. This is not "we still do not
know"; it is "the API exposes no such counter", which is a settled answer and closes the question as
posed.

**It is provider-dependent, which is the useful half.** Anthropic *does* publish one, and lain
already wires it: `provider/anthropic_wire.rb:69-70` sets `config.rate_limit_reset_header` and
`config.header_parser_block`. `Deployment::Cloud` leaves both knobs nil **deliberately** — its
docstring says naming a header vocabulary that has not been verified "would replace a working
default with a guess". So a windowed usage HUD is reachable on the Anthropic arm and structurally
unavailable on the ollama-cloud arm.

**What CAN be shown for ollama cloud, and the honesty constraint on it.** `turn_usage` is journaled
per turn with `ts`, `model`, `stop_reason` and an exact `usage` object
(`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`) —
F77 summed this session's eight turns to **27,997 in / 2,376 out** straight from the record. A 5-hour
or weekly figure is therefore computable as a **time-windowed fold over the journal**.

But such a number is **this machine's spend on this key**, not the plan's consumption: another
client using the same subscription is invisible to it. That distinction is the same one lain already
enforces for context windows — `provenance: published` versus `guessed` — and labelling a
locally-summed figure as "usage" without it would overclaim in exactly the way that tagging a guessed
window authoritative would. If this ships, the provenance belongs in the label.

**Mechanically it is small.** `state.json` carries no usage field today (`cache_deadline`, `fleet`,
`inbox_count`, `approvals_pending`, `occupancy`, `compactions`, `derivation_refusal_streak`,
`posture`, `layers`, `mode_lighter`, `elapsed`, `idle`, `since_compaction`). Adding one means a
`StatusFeed` measure plus one line in `Up::Hud::JQ_FILTER`.

---

## E8 — the tmux status line needs one trailing space

**The ask.** The HUD's last character is a `%` and it sits hard against the right edge; a trailing
space would let it breathe.

**Where it is.** `cli/up/hud.rb:77-83`, `JQ_FILTER`. The final two clauses are:

```jq
+ (if .occupancy then " ctx:\([(.occupancy * 100 | floor), 100] | min)%" else "" end)
+ (if (.mode_lighter // "") != "" then " " + .mode_lighter else "" end)
```

With no mode lighter set — the common case, and the state in this session — the rendered line ends
on the `%` of `ctx:NN%`.

**One note for whoever does it:** put the space **inside the jq expression** (a final `+ " "`)
rather than appending it to the tmux `status-right` option value, since trailing whitespace in an
option value is the more fragile of the two. The `fallback_status_right` branch (raw `cat` of
`state.json`, no jq) does not share the filter, so it would be unaffected either way.

**Not acted on.** Recorded at the human's instruction.

## E9 — the Rust admission test's rule #2 is narrower than its own headline, and parser generators are the case that exposes it

**The position.** "Rust is faster" is not sufficient — agreed, and the doc is right to refuse it.
But LALR and PEG generators in Rust offer a *better way to express* parts of this system, which
would simplify testing and extensibility. That is a **capability** argument, not a speed one, and
the admission test should be able to hear it.

**The doc half-agrees with itself already.** `docs/rust-bindings.md`'s headline is: "Rust is here
for its data model and **for capabilities Ruby has no good answer to**, not for speed." But rule #2
operationalises only the first half — "Ruby's object model makes it **asymptotically** worse… That
gap is the argument." A grammar DSL has no asymptotic story and is squarely a capability, so a
well-founded proposal fails a test whose headline admits it. That is a gap in the test, not in the
proposal.

**The in-tree evidence is stronger than expected: there is a FAMILY of hand-rolled grammars, and
they copy each other.**

| grammar | lines |
|---|---:|
| `Question` | 478 |
| `Epic::Document` | 442 |
| `Plan::Document` | 162 |
| `Gherkin::Parse` (`gherkin.rb:92`) | — |
| also parsing-shaped | `Review::Source` (588), `Skill::Invocation`, `Sensitivity::Regions` |

`Epic::Document`'s own docstring names the pattern: "**`Plan::Document`'s grammar idiom
throughout — module-scope regexes, one status map read both directions**", and cites
"`Gherkin::Parse::COLON_TOKEN`" as the precedent for how a malformed line is refused. **Three files
independently re-implementing one idiom is the tell** — a copied idiom is what a grammar declaration
exists to stop being copied.

**The property that makes the argument concrete.** `Epic::Document` maintains a **total round
trip**: "`parse_markdown(to_markdown(g))` is `g` by digest, or the emit is refused loudly naming the
value it cannot write… **Parse and emit refuse the same shapes, so a document that parses always
emits.**" That bidirectional totality is currently upheld by keeping *two hand-written regex sets in
agreement*, by discipline, in prose. It is exactly the kind of invariant a single grammar makes
structural rather than maintained — and it is property-testable, which is the "simplifies our
testing" claim in its most defensible form.

**The honest counterweight, which the decision should face.** Ruby is not empty-handed on parser
generators specifically: **`racc` is an LALR generator in the standard library** (it builds Ruby's
own parser), and `parslet` / `treetop` are PEG. So "Ruby has no good answer" is a much weaker claim
here than it is for persistent data structures. If the motivation is expression and testability
rather than throughput, racc or parslet delivers most of it with **no FFI boundary at all** — which
also sidesteps rules #3 and #4 entirely, since a per-parse crossing is precisely what those two
tests exist to interrogate.

**The strongest form of the Rust case, conversely:** the boundary already exists and already
contains a grammar runtime. `ext/lain` ships `ast-grep-language` with ~26 bundled tree-sitter
grammars, and `Shell::Parse` already crosses that boundary per tool call (N9). The five tests were
written to gate a **first** crossing; the marginal cost of one more grammar behind an existing,
already-hot binding is not what they assume. Tree-sitter additionally brings error recovery and
incremental parsing, which are capabilities rather than speed.

**What a revised rule #2 has to avoid.** If it is widened from "asymptotically worse" to "more
expressible", it must keep teeth, or it readmits every speed argument wearing an ergonomics coat.
The worked example above suggests where teeth could come from: does the alternative make a
**property structural** that is currently maintained by hand across two or more sites?
`Epic::Document`'s parse/emit totality passes that; a regex for `/skill args` (N10) does not.

**Recorded as a position to adjust over time, not a change.** The human's framing: the rule is right
to reject speed and should be able to hear expression.
