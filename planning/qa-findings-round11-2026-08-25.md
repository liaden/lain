# QA round 11 — 2026-08-25 — `survey.md`

## Summary

Scoped round: `planning/qa/scenarios/survey.md` only, driven end to end. **All seven sections were
driven**, including **§7, the docent thread pane owed since round 7 and dropped by rounds 8, 9 and
10** — that debt is discharged. Everything ran on the **local** `qwen3-coder:30b` arm; no metered
provider was touched, per the round's instruction. §1–§6 spent no model calls; §7 spent four.

**Round 7's F31 is FIXED** — the thread pane's `BufWriteCmd` refusal no longer raises: no
`stack traceback:`, no `Press ENTER` modal, and no RPC hang (`:w` returned in 0s against round 7's
two 120s timeouts). **F56 is FIXED** — `/review-submit` over a survey now reasons about a pull
request rather than reusing the local-branch wording.

Seven new findings. The headline is **F64**: when the docent parks a clarifying question instead of
answering, the thread pane stalls at `(thinking …)` permanently and **three surfaces disagree about
whether the question is live**. **F65** is the secret-boundary one: the `<CR>` gesture opens the raw
file, putting unreleased bytes on a cockpit surface that `Projection` masks everywhere else.

Two predicted defects **did not reproduce** and are withdrawn with their mechanisms, including one
where the scenario's own fixture is the thing at fault (§4's planted key is below both detector
gates, so the check passes for the wrong reason).

| id | sev | what |
|---|---|---|
| **F64** | **MED-HIGH** | a docent that parks an `ask_human` strands the thread pane at `(thinking …)` forever; inbox, HUD and `:LainReply` disagree about whether it is live |
| **F65** | **MEDIUM** | `<CR>` on a survey row opens the RAW file, showing unreleased secret bytes `Projection` masks everywhere else |
| F66 | MEDIUM | `:LainThread` refuses "no thread on this line" while the note marker sits on that exact line — the thread needs `:LainNoteDone` first, and nothing says so |
| F67 | MEDIUM | a chat that has surveyed can never open a changeset review again, even after the survey is **settled**; there is no release command |
| F68 | LOW-MED | `lain://review` strips leading `../` from file rows while group headers keep them — two path bases in one buffer, one of them unusable |
| F69 | LOW | `lain survey <path> --permissive` refuses with a raw Thor arity error naming a verb (`open`) the human did not type |
| F70 | LOW | REPL scope refusals render Ruby `Array#inspect` of Symbols into prose: `[:cumulative, :by_directory] do present this one` |

## Previous defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F31** | **FIXED** | second `:w` on the thread pane with nothing new typed: `:w` rc=0 in **0s**; `nvim_get_mode()` answered immediately (no modal); no `stack traceback:`; journal unchanged 30→30 (no duplicate spawn); refusal is a rail sentence — `lain: nothing has been typed under the conversation, so there is no question to ask -- write it below the last message and :w again`. Round 7 measured two `nvim --server` calls timing out at 120s each. |
| **F56** | **FIXED** | `/review-submit` over a survey: `this review was opened on survey of <path>, which has no pull request to post a review to -- the annotations and the verdict are on the journal either way. Run '/review <pull-request>' against the pull request itself to post one.` It names the survey and reasons about a **pull request**; the local-branch wording is gone. |

---

## F64 — MED-HIGH — a docent that asks a human strands the thread pane, and three surfaces disagree

**What is wrong.** When the docent subagent parks an `ask_human` instead of answering, the thread
pane is left at `(thinking -- the answer will replace this line)` indefinitely, `docent_answered`
never lands, and the placeholder stays in the conversation record permanently. Three surfaces then
give three different answers about whether the question is still live.

**The mechanism.** The docent arm answered with a `message` whose payload is
`{"asked_by":"diff_docent", ...}` and `"to":"human"` rather than a `child_turn` + `docent_answered`
pair. The thread pane's placeholder is only replaced on `docent_answered`, which never comes.

**The evidence that rules out "it was still computing".** The first exchange on the same thread
completed in **6s** (`docent_asked` 12:01:46 → `docent_answered` 12:01:52) and produced 2 `message`
+ 2 `child_turn` records. The second produced `docent_asked` 12:03:36 → `message` 12:03:37 →
`message` 12:03:42 and then **nothing for the remaining 6 minutes**, with the model resident
(`/api/ps` reported `qwen3-coder:30b` throughout) and no other load on the one slot.

**The three-way disagreement, all read at the same moment:**

| surface | says |
|---|---|
| `lain://inbox` | renders the question in full and offers `-- <CR> or r opens the set  (:LainOpen / :LainReply {answer})` |
| HUD | `qwen3-coder:30b ctx 59% fleet 1 idle 0s` — the arm counts as live |
| `:LainReply <text>` | `lain: no question set was named, so nothing here can be answered: no question is awaiting a reply -- it was answered already, or withdrawn when the run that asked it was stopped. **The inbox line offering it is stale: nothing you type here is recorded, and nothing is waiting on it.**` |
| the thread pane | `(thinking -- the answer will replace this line)` |

The refusal text **predicts its own defect** — it explains that the inbox line is stale rather than
the inbox being corrected. That is the finding: lain knows the inbox can go stale and answers in
prose instead of updating the buffer.

**Bounded, not fatal.** Typing a *new* question into the thread and `:w` still works and is answered
(`docent_answered` reached 2). So the damage is one orphaned exchange, not a dead thread. But the
orphan is permanent — the conversation buffer holds it at line 17, between two answered exchanges,
and replays with it.

**Reproduction.**
```
/survey <a real tree>
<CR> on a row; :LainNote note <text>; :LainNoteDone; :LainThread
append a question, :w                       # answers normally
append a second question, :w                # local model parks an ask_human here
```
The trigger is the model choosing to clarify; on `qwen3-coder:30b` it fired on the second question
of the thread. That choice is MODEL behaviour (see below) — **the finding is lain's handling of it.**

**Fix shape.** The thread pane needs a third state beside "thinking" and "answered": *waiting on
you*, naming where to answer. And whatever withdraws the pending must redraw `lain://inbox` and the
`fleet` segment rather than leaving `:LainReply` to apologise for them.

---

## F65 — MEDIUM — `<CR>` on a survey row opens the RAW file, unredacted

**What is wrong.** Opening a survey row puts the file's **real bytes on a cockpit surface**,
including regions `Survey::Projection` masks for every other consumer.

**The evidence, both directions.** Planted a tree holding a PEM with a high-entropy body (4 lines of
64-char base64, measured 5.176 bits/char, above `BASE64_ENTROPY = 4.2` and `BASE64_LENGTH = 24`):

- `Projection#project` over that file, asked through `/ruby` inside the live session, returns
  `"<redacted:1>\n<redacted:2>\n<redacted:3>\n<redacted:4>\n<redacted:5>\n-----END RSA PRIVATE KEY-----\n"`.
- The journal carries **zero** key bytes (`grep -c` on the key material = 0).
- The buffer lain opened on `<CR>` — `/home/tara/.../tree2/deploy.pem`, window 3 of tab 3 — holds
  `-----BEGIN RSA PRIVATE KEY----- | MIIEow…12345 | MIIEow…12345 | MIIEow…12345 | MIIEow…12345 | -----END RSA PRIVATE KEY-----`.

So lain has both renderings available and the surface shows the unmasked one, with nothing on
screen indicating that what you are reading is unprojected.

**Why it is a finding and not obviously by design.** `survey/projection.rb`'s own docstring says
"Above the source, the session, **the surfaces**, the journal and the docent see only released
bytes, so no survey artifact can carry an unreleased secret." An nvim window opened by lain's own
gesture is a surface by that sentence's plain reading.

**The nearest innocent explanation, stated fairly.** `projection.rb:62` says "With no approval
surface wired into a survey, the masked projection simply stands -- a human can always open their
own file in their own editor," and the chat banner documents this window as "the file where
`:LainNote` annotates" — annotation needs real line numbers. So this may be deliberate. **What would
settle it:** decide whether the docstring's "the surfaces" is meant to include the annotation pane,
and if it is not, say so there — a reader following that sentence today will conclude the cockpit
cannot show them an unreleased secret, and it can.

---

## F66 — MEDIUM — `:LainThread` refuses while the marker is visibly on the line

`:LainNote` draws the marker and **nothing reaches Ruby**. `:LainThread` on that same line then
answers `lain: no thread on this line` while a `● note` marker sits on it.

**Mechanism.** `review_thread.anchor_at` reads the `lain_thread_anchors` namespace, populated by
`review_thread.register`, which Ruby calls on the hand-back. Measured directly after `:LainNote`:

```
b:lain_thread_anchors            -> <unset>
extmarks in lain_thread_anchors  -> 0
extmarks in the note namespace   -> 1   ({'virt_text': [['● note','Comment']], 'virt_text_pos':'right_align'})
journal                          -> no annotation record at all
```

After `:LainNoteDone` the `annotation_placed` record appears and
`b:lain_thread_anchors` becomes `{'1': {'buf': 21, 'id': '68d800dc-…', 'rev': 'c1a96b69…'}}`.

`handover.rb:332` says "THE NOTE IS WHAT OPENS THE THREAD", which is true of the *hand-back* and not
of the gesture the human made. Nothing in `Ln`'s own help ("note on this line (finish the sentence,
then `<CR>`)") or in the chat banner mentions that a thread needs `:LainNoteDone` first.

**Fix shape.** Either register the anchor on placement, or have the refusal say which of the two
states it is in — `there is a note here but it has not been handed back yet; :LainNoteDone first`.

---

## F67 — MEDIUM — a chat that has surveyed can never review a branch again

`/review <branch>` refuses for the rest of the session once any survey has been opened, **including
after the survey has been settled by a verdict**:

```
:LainReviewVerdict approve   -> lain: this review is settled: approve
/review feature/tweak        -> error: survey of /home/tara/dev/lain/lib/lain/survey is already
                                open in this chat, and one chat draws one review at a time …
                                Run `lain review open <target>` for a text rendering outside this chat.
```

A settled review is not an open one in any sense the human can see — the verdict landed and the
rails handed back — but the guard still reads it as open. There is no `/review-close` or equivalent,
so the only exit is restarting the chat. **This is also why §5's own first leg is unreachable unless
it is driven before any survey**, which the scenario does not say (see process notes).

---

## F68 — LOW-MED — the sidebar renders two different path bases, one of them unusable

In one `lain://review` buffer at `by_directory` scope, with the chat standing in `$QA/project`:

```
~927 lines  ../../../dev/lain/lib/lain/survey        <- group header: cwd-relative, correct
  [ ] dev/lain/lib/lain/survey/chunker.rb            <- file row: leading ../../../ STRIPPED
```

`dev/lain/lib/lain/survey/chunker.rb` resolves from cwd to a path that does not exist.

**The evidence that rules out "the rows are HOME-relative".** A tree at
`/home/tara/tmp/lain-qa-survey-2026-08-25/tmp/tmp.iemI47G5i9/tree2/` rendered its row as
`tmp/tmp.iemI47G5i9/tree2/deploy.pem`. HOME-relative would be
`tmp/lain-qa-survey-2026-08-25/tmp/tmp.iemI47G5i9/tree2/deploy.pem`. Both trees are consistent with
"cwd-relative with every leading `../` removed" and neither is consistent with a HOME base.

Two other surfaces render the same path correctly, which is what makes this a rendering bug rather
than a policy: the OLD buffer is named
`lain://review/OLD/../../../dev/lain/lib/lain/survey/withheld.rb` and the thread header reads
`-- thread at ../../../dev/lain/lib/lain/survey/withheld.rb:12 --`.

---

## F69 — LOW — `lain survey --permissive` refuses as a Thor arity dump

```
$ lain survey /home/tara/dev/lain/lib/lain/survey --permissive
ERROR: "lain survey open" was called with arguments ["/home/tara/dev/lain/lib/lain/survey", "--permissive"]
Usage: "lain survey open PATH"
[exit=1]
```

The scenario asks only that the flag be "refused rather than silently accepted", and it is. But the
refusal is Thor's positional-arity error, it says nothing about *why* a survey has no `--permissive`
(there is no verdict to judge), and it names a verb — `open` — that the human did not type. The REPL
gets this right one rail over: `error: --squash is not a flag /survey can read`.

---

## F70 — LOW — Ruby `inspect` leaks into REPL refusal prose

```
error: scope :commits is not available for the corpus source -- it does not answer what that
grouping reads. [:cumulative, :by_directory] do present this one
error: scope must be one of [:cumulative, :commits, :by_directory], got "commmits"
```

The sentences are right and the *contents* are right (see §3 below — the first lists only the scopes
this source really presents, the second lists the whole registry). But `[:cumulative, :by_directory]`
is `Array#inspect` of Symbols dropped into prose. The CLI path says the same thing in words:
`Expected '--scope' to be one of cumulative, commits, by_directory; got commmits`.

---

## Withdrawn — two predicted defects that did not reproduce

**Withdrawn: "the ceiling's remedy advises `--scope commits`", and the `NoMethodError` behind it.**
`bounds.rb`'s own comment describes `NARROWING_CANDIDATES` being tried in registry order with
`ByCommit` first, and warns that a source with no `#commits` "died in `ownership` with a
`NoMethodError`". That guard has since been added — `cumulative_advice` now reads
`view.supports?(strategy) && fits?(view, strategy)`. Driven over `planning/` (114 files / 78,246
lines — under the file ceiling, over the line ceiling, so it reaches `cumulative_advice`):

```
the cumulative view is 94549 rendered lines, over the ceiling of 30000 -- and no other scope
presents it either, so there is no scope that presents this changeset whole
```

No crash, and it does not advise `commits`. **And the claim is independently true**: measured by
hand, `by_directory` over `planning/` puts 57 files / 56,234 lines in the `planning/specs` group
alone, over the 30,000-line ceiling — so there genuinely is no presenting scope. The sentence is
honest, not a fallback.

**Withdrawn: "a `.pem`'s key body renders in the clear."** The scenario's §4 fixture plants
`MIIEowIBAAKCAQEA0000` as the key body, and `Projection` leaves it verbatim while masking only the
`-----BEGIN…` line — which looks alarming and is correct. That body is **20 characters at 3.184
bits/char**, against `BASE64_LENGTH = 24` and `BASE64_ENTROPY = 4.2`; it fails **both** gates. The
4.2 floor is reasoned in `regions.rb`'s own comment ("paths and URLs are base64url-legal and sit at
4.0-4.2 -- at 4.0 the detector reported 41 `lib/` file paths as secrets"), and `Projection`'s
docstring names this residual explicitly. A realistic body (64 chars, 5.176 bits/char) is masked in
full. **This is a defect in the scenario, not in lain — and a dangerous one**, because a driver
checking for the presence of `<redacted:1>` ticks the box while the planted "key" sits in the clear
one line below. Fixed in the scenario (see process notes).

---

## Section-by-section result

| § | what it asks | result |
|---|---|---|
| §1 | four parse refusals told apart, headless no-editor refusal, one-shot | **PASS** — all five refusals distinct and correctly worded; the no-editor refusal names `lain up --nvim`, `lain chat --nvim <socket>` **and** `lain survey <path>`; headline format `surveying <root> at <scope> scope: <n> files` confirmed |
| §2 | ceiling refusal: clean, names measurement/ceiling/alternative, advises a valid scope, decides without walking | **PASS** on all four; see the timing table below. `--unbounded` presents 742 files in 2.8s |
| §3 | inapplicable vs misspelled scope | **PASS** — `commits` gets the corpus sentence + only the scopes this source presents; `commmits` gets the whole registry; `by_directory` opens and the grouping **is** visible in the sidebar |
| §4 | what the walk admits and withholds | **PASS 7/7** — first ever drive; see the table below |
| §5 | one review surface per chat | **PASS**, plus F67 |
| §6 | `--permissive` is `BlockersOnly`, not `Permissive` | **PASS**, both legs, with a control |
| §7 | the docent thread pane | **DRIVEN** — first time since it was written; F31 fixed; 4 of 5 checks pass; check 1's answer-render and non-stall both pass; F64 is what check 3 surfaced |

### §2 — the refusal decides on a file count alone

The scenario says to time it. A wall-clock number alone would have been worthless here (the box was
loaded — see process notes), so it was taken as a **control set**, all four samples sharing the same
load:

| run | files | wall |
|---|---:|---:|
| **REFUSE** `lib` | 742 | **1578ms** |
| SUCCEED `lib/lain/frontend` | 52 | 1676ms |
| SUCCEED `lib/lain/survey` | 9 | 1485ms |
| **`lain help`** — surveys nothing | — | **1521ms** |

The 742-file refusal costs **~57ms more than a command that does no survey at all**, and is *faster*
than surveying 52 files. ~1.5s is Ruby/bundler boot. It did not walk the tree.

The refusal itself: `this corpus is 742 files, over the ceiling of 300 -- survey a subdirectory
instead, or raise the ceiling` (`source/corpus.rb:403`, a pre-check that short-circuits before
`Bounds#check_cumulative!`). Clean, no backtrace, no modal, in both the CLI and the cockpit. It
names the measurement and the ceiling. **It does not name `--unbounded`** as the way to raise the
ceiling, and it names no specific subdirectory — worth a line in whatever chunk touches this, though
it is honest as far as it goes.

Scenario size table re-measured and **confirmed exactly**: `lib` 742/161,963, `lib/lain/frontend`
52/13,578, `lib/lain/review` 45/10,722, `lib/lain/survey` 9/1,343.

### §4 — the admission table, first ever drive

Planted per the scenario, surveyed, and the banner's disclosure block read:

```
surveying …/tree at cumulative scope: 2 files
withheld 3 paths, not surveyed:
  blob.bin: binary content
  elsewhere.conf: a link out of the surveyed tree
  notes.txt: a protected path
[ ] deploy.pem
[ ] plain.rb
```

| path | expected | actual | |
|---|---|---|---|
| `plain.rb` | listed | listed | ✓ |
| `deploy.pem` | **listed**, masked | listed; projection verified separately | ✓ |
| `blob.bin` | withheld, binary | `binary content` | ✓ |
| `notes.txt` → `~/.ssh/id_rsa` | withheld **as the secret**, not as `outside` | `a protected path` | ✓ denial beat containment |
| `elsewhere.conf` → `/etc/hostname` | withheld, outside | `a link out of the surveyed tree` | ✓ |
| `broken` → `/nonexistent` | absent, silently | absent from both lists | ✓ |
| a tree with none of them | **no note at all** | no note at all, `withheld` mentions = 0 | ✓ |

**No secret leak**: `BEGIN OPENSSH PRIVATE KEY`, `BEGIN RSA PRIVATE KEY`, `MIIE` and `PRIVATE KEY`
all count **0** in the survey output over a tree symlinking a real 3,434-byte `~/.ssh/id_rsa`.

The scenario expects `notes.txt` to be disclosed "as the private key it is"; it is disclosed as
`a protected path`. That is **better** than the scenario asks — naming it as a key would itself
disclose what the denial exists to hide — and the important half holds: it is not disclosed as
`outside`, so denial is tested before containment.

### §6 — `--permissive` is `BlockersOnly`, and the control proves it

| leg | result |
|---|---|
| `--permissive`, approve over an unread changeset | **LANDS** — `lain: this review is settled: approve` |
| **control**: no `--permissive`, approve over 45 unread rows | **REFUSES** — names 5 files + "and 40 more", and offers `--permissive` as the remedy |
| `--permissive`, approve over an unanswered `blocker` | **REFUSES** — `approve is refused over 1 blocker nobody has answered: …/chunker.rb:20 (new) -- answer each one with a note on that same line, which is what resolves it` |
| a note on the blocker's own line, then approve | **LANDS** |

The control is what makes leg 1 evidence rather than a coincidence: without it, "approve landed"
is equally consistent with "there was nothing unread to refuse over."

### §7 — the thread pane, five checks

| # | check | result |
|---|---|---|
| 1 | answer renders in the thread pane, not the chat; chat not stalled | **PASS** — answer landed under `## docent`; chat pane unchanged; while the answer was outstanding (journal 15→21→30) an `x` gesture landed in **1s** and marked 9 hunks |
| 2 | a second `:w` with nothing new refuses in words | **PASS** — and **F31 is fixed**; journal unchanged 30→30 |
| 3 | text typed after the answer still sends | **PASS** — third question answered (`docent_answered`=2). The *second* is F64 |
| 4 | the exchange lands in the chat's journal | **PASS** — `annotation_placed`, `docent_asked`, `docent_answered`, plus `message`×2 and `child_turn`×2 |
| 5 | the answerer names itself, never the `ROLE` constant | **PASS** — record carries `"role":"diff_docent"`, and `docent.rb:429` is `arm_role(answerer) = answerer.respond_to?(:role) ? answerer.role : ANONYMOUS_ARM`. **Caveat:** with only the shipped arm driven, this round cannot *distinguish* the self-report from the constant by observation; the evidence is the code path plus a non-`anonymous_arm` record |

The model-facing `tools/request_review.rb` path was not re-driven — the scenario says its
`Handover::Unattended::NO_DOCENT` answer is deliberate and not a finding.

---

## Model behaviour — not lain defects

- **`qwen3-coder:30b` parks clarifying questions instead of answering.** It did this on the second
  docent question of a thread, having answered the first one directly. This is the documented
  "loops on clarifying questions instead of acting" behaviour. It is the *trigger* for F64; the
  finding is lain's handling, not the model's choice.
- No literal `<function=` appeared in any transcript this round, so no session was restarted for
  contamination.
- Docent answers were coherent and on-topic. §7 asserts on none of their content, per §8.

---

## Bench preconditions recorded

- `OLLAMA_NUM_PARALLEL:1` and `n_slots = 1` — the contention precondition every reading here
  assumes. Both still 1 on this box.
- Runner resident at `ctx=32768` throughout §7; warmed **through a lain request**, not through
  ollama, per `bench.md`. Warm turn: 24s cold-ish first call, then 6s for the first docent answer.
- `nvim` v0.12.4 (above the 0.11 minimum).

## Sandbox and close-out

Sandbox `~/tmp/lain-qa-survey-2026-08-25`, tmux `-L lain-qa-survey-2026-08-25`. All three cockpit
panes verified carrying the four redirected `XDG_*`, the redirected `TMPDIR`, and `LAIN_DESKTOP=0`
(checked positively — each pane reported `1` for the `LAIN_DESKTOP=0` grep, not merely "it was
exported"). `~/.lain` absent before act 0.

**The round ran fully muted.** No act needed the approval notifier — nothing in `survey.md` gates a
tool call — so `LAIN_DESKTOP=0` was exported before the tmux server started and no act was exempted.
Proved by the negative: `dunstctl count displayed` and `waiting` both **0** at close-out.

| close-out check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-08-25T11:43:34Z'` | **0** |
| positive control, `-newermt '2026-08-01'` | **6817** — so the 0 is evidence, not a spelling accident |
| `git -C /home/tara/dev/lain status --porcelain` | **byte-identical to the baseline taken before act 0** |
| `ls -d /home/tara/dev/lain/.lain` | prints nothing |
| tmux server / stray `exe/lain` processes | gone / none |
| `dunstctl count displayed` / `waiting` | 0 / 0 |

**No code bandaids were applied — there is nothing to revert.** The two workarounds this round used
were procedural, not edits: inserting `:LainNoteDone` between the note and `:LainThread` (F66), and
relaunching the cockpit to reach §5's first leg (F67). Both are now written into the scenario.

The ollama server started for §7 was left running; `OLLAMA_KEEP_ALIVE=5m` evicts the model on its
own. The sandbox directory is left in place as evidence.

---

## Process notes — folded back into the scenario

`planning/qa/scenarios/survey.md` was corrected in six places. Every one of them is a **prediction
the first drive falsified**, which is exactly what the README says a first drive should expect:

1. **The scope vocabulary is `cumulative|commits|by_directory`**, not `whole|commits|directories`.
   Read off `Partition::STRATEGIES` (`partition.rb:177`).
2. **`Survey::Walk` does not shell to plain `git ls-files`** — it includes untracked files. Measured:
   `planning/qa` listed **19** files against `git ls-files`' 18, the extra being the untracked
   `scenarios/survey.md`. The §2 size table is unaffected (`lib` has 0 untracked) but the instrument
   the scenario names is wrong.
3. **§4's planted key is below both detector gates** and must be replaced with a realistic
   high-entropy body, or the check passes for the wrong reason. This is the most dangerous of the six.
4. **§4's `notes.txt` expectation** should be "withheld without naming what it is", not "as the
   private key it is".
5. **§5 must be driven BEFORE any survey is opened** — F67 means a chat that has surveyed can never
   reach §5's first leg.
6. **§7 needs `:LainNoteDone` between the note and `:LainThread`** (F66), or the section stops at
   "no thread on this line".

**One method note**, added to `planning/qa/method.md`: a wall-clock claim on a loaded box can still
be made honestly by taking it as a **control set** rather than an absolute — §2's four-sample table
above answers "did it walk the tree" with the box at 0% idle, because all four samples share the
load and the no-op baseline is one of them. This is the cheap general form of round 9's
control-not-re-measurement lesson.

**The quiet-machine gate FAILED this round and was not cleared.** 16 orphaned
`while :; do :; done` spinners at ~90% CPU each, ~1h07m old, all reparented to init, left by an
agent's tmux race test in `$HOME/tmp/lain`; load average 17.3, 0.0% idle. The driver was not
permitted to kill them and the operator did not clear them during the round. **No timing claim in
this document rests on an absolute wall-clock number** — §2's is a control set, and §7's latencies
are reported only as ordinals (6s vs >6min) where the gap is three orders of magnitude. This is the
second consecutive round to find orphaned spinners from other agents' work (round 10 found 24).

## Coverage

`survey.md` is now **7 of 7 sections driven**, from 0. The docent-thread debt carried since round 7
is discharged. No other scenario was in scope; the `rails-blog` owned round remains owed and the
rotation does not advance on account of this round.
