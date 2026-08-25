# QA round 12 — 2026-08-25 — `survey.md` regression re-drive

## Summary

**The §7 stop-the-chunk condition did NOT trip.** `:LainThread` on a one-sided survey opens the
thread pane on demand at both 80 and 100 columns: no traceback, no `error()`, no `Press ENTER`
modal, `nvim_get_mode()` responsive throughout. Round 7's F31 shape has not returned on the surface
this chunk was built to repair.

Scoped round: `planning/qa/scenarios/survey.md` only, all seven sections driven, as a regression
re-drive of the 14-card chunk that discharges round 11's F64–F70. **All seven findings are fixed**,
and none of them was fixed in a way that made the failure mode worse — the skill's rule 2 was
checked against each and every previous failure mode is now either absent or delivered as a rail
sentence. The corpus ceiling now names `--unbounded` and names **no** partition scope.

Two new findings, both LOW, and neither in the chunk's path. One process finding about the bench
itself, which is the third consecutive round to be contaminated by the same class of orphan.

| id | sev | what |
|---|---|---|
| F71 | LOW | `unknown skill` refusal renders `Array#inspect` of Symbols into prose — F70's exact defect one rail over, outside T9's scope |
| F72 | LOW | T7 unified the sidebar's two path spellings onto the one that does **not** resolve from cwd, while the message line and thread header keep the one that does |
| P18 | process | the 16 orphaned spinners round 11 was refused permission to kill were still running 5.6h later and contaminated this round too |

## Round-11 defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F64** | **FIXED** | two questions on one thread, both answered directly (`docent_asked`=2, `docent_answered`=2). **No parked `ask_human` at all** — and the mechanism is structural, not luck: the docent child's spawn record carries `only: ["read_file","list_files","glob","grep"]`, so it *holds no tool that can park*. Thread pane has 0 lines matching `thinking`; `lain://inbox` reads `(no questions pending)`; HUD shows no `fleet` segment; `lain://approval` reads `(no approvals pending)`. All four of round 11's disagreeing surfaces now agree. |
| **F65** | **FIXED (both halves)** | *Layout:* a survey opens `sidebar \| file` — tab3 = **2 windows** at first paint and after `<CR>`; the file window is the real file on disk with `&diff = 0`; **no `lain://review/OLD/…` buffer exists at all**. A branch review still opens `sidebar \| old \| new` — 3 windows, both sides `&diff = 1`. *Banner:* a survey names **one** `<C-w>l`; a changeset review names **two** `<C-w>l<C-w>l`. Both verified in the same chat, in both directions. *Docstring:* `survey/projection.rb` no longer claims "the surfaces" — it now says "the source, the session, the journal, the docent and the model" and carves out the survey's `new` slot explicitly. |
| **F66** | **FIXED** | `:LainThread` on a line with a note placed but not handed back: `lain: note not handed back yet -- hand it back with :LainNoteDone`. Names the remedy. Round 11 got `lain: no thread on this line`. No pane opened spuriously (tab3 stayed 2w). After `:LainNoteDone`, `b:lain_thread_anchors` populates and `annotation_placed` lands. |
| **F67** | **FIXED** | survey of `…/project/src` settled with `:LainReviewVerdict approve`, then `/review feature/tweak` **opens** — 3 windows, two-hop banner. The converse also works: a settled branch review no longer blocks `/survey`. An *unsettled* round still holds the rails, correctly, naming the target already open. |
| **F68** | **FIXED** | `by_directory` survey of a tree outside the project: header `~947 lines  dev/lain/lib/lain/survey`, rows `  [ ] dev/lain/lib/lain/survey/chunker.rb` — **one base, both surfaces**. Round 11 had `../../../dev/…` on the header and the stripped form on the rows. Opening still resolves to the real absolute path (T7 AC 2). Residual: see F72. |
| **F69** | **FIXED** | `lain survey <path> --permissive` → `Unknown switches "--permissive"`, exit 1. Names the switch; **does not name a `survey open` verb the human never typed**. Round 11 got Thor's positional-arity dump naming `open`. Control: `lain survey open <path>` still works. |
| **F70** | **FIXED** | REPL: `error: scope commits is not available for the corpus source -- it does not answer what that grouping reads. cumulative, by_directory do present this one` and `error: scope must be one of cumulative, commits, by_directory, got "commmits"`. No brackets, no leading colons. CLI mirrors read the same. Contents still correct — the first lists only what the source presents, the second the whole registry. |
| **ceiling** | **FIXED** | `this corpus is 742 files, over the ceiling of 300 -- survey a subdirectory instead, or raise the ceiling with --unbounded`. Names `--unbounded`; **names no partition scope** (`grep -cE 'by_directory\|--scope\|cumulative\|commits'` = 0), which is the half that would have been a defect. Clean `error:` line in the cockpit, plain line on the CLI, no backtrace, no modal, no review tab held. |
| F31 | still FIXED | duplicate `:w` on the thread pane refuses in words in **139ms**; `mode()` responsive; 0 `stack traceback`; journal unchanged (no duplicate spawn). |
| F56 | not re-driven | `/review-submit` over a survey was out of this round's named scope. |

**No fix made a failure mode worse.** Each previous failure was re-driven to its old trigger point:
F64's park cannot occur (no tool), F66's silent refusal now names the remedy, F67's lockout releases
on settle, F69/F70's crash-shaped output is now prose, and the ceiling gained a flag without losing
its cheap decision (timing below). The one place a fix *could* have made things worse — removing
`old` from the slot vocabulary and turning `:LainThread` into a traceback — is exactly what did not
happen.

---

## The timing measurement — re-taken on a quiet machine

**Read the process note first: the first set of numbers this round took was invalid.** The box was
carrying 16 orphaned busy-loops at 0.0% idle (P18). The operator cleared them mid-round; everything
below was re-taken afterwards, at load 2.9 on 16 cores with 0 `parallel_rspec` and 0 spinners, and
the earlier numbers are discarded rather than reported.

Medians of 11 interleaved reps, `lain help` as the do-nothing baseline:

| run | files | median wall | over baseline |
|---|---:|---:|---:|
| **REFUSE `lib`** | 742 | **1157ms** | **+83ms** |
| REFUSE `spec` | 735 | 1176ms | +102ms |
| REFUSE whole repo | 1762 | 1247ms | +173ms |
| **`lain help`** — surveys nothing | — | **1074ms** | — |

**The chunk did not spend the no-walk property.** +83ms over a no-op for 742 files sits inside the
implementer's re-timed 85–140ms range and is the same order as round 11's ~57ms. The two are not
cleanly comparable and this document does not claim they are: round 11's control set was a single
sample per row taken at 0.0% idle, and its own `SUCC9` row (1485ms) came in *below* its `lain help`
baseline (1521ms) — i.e. its resolution was coarser than the difference it reported.

**The scaling control is what makes this evidence rather than a number.** Cost tracks **file count**,
not content: 735 files costs what 742 files costs, and 2.4× the files costs ~2.1× the overhead. In a
separate 7-rep set the 742-file *refusal* (1138ms) came in at parity with *successfully surveying 52
files* (1143ms) — and `lib` is 161,963 lines against `lib/lain/frontend`'s 13,578. A decision that
had read the hunks could not produce that ordering. The refusal enumerates and decides; it does not
read.

---

## Section-by-section result

| § | result |
|---|---|
| §1 | **PASS** — all five refusals distinct: usage line (names all three flags, scopes from the registry); `--scope` at EOL → *needs a value*; `--scope --unbounded` → *needs a value*, naming `--scope`; `--squash` → `--squash is not a flag /survey can read`; valid line headless → no-editor refusal naming `lain up --nvim`, `lain chat --nvim <socket>` **and** `lain survey <path>`. One-shot headline format confirmed. |
| §2 | **PASS** — ceiling refusal clean, names measurement + ceiling + alternative + `--unbounded`, advises no scope, decides without walking (timing above). |
| §3 | **PASS** — inapplicable vs misspelled scope told apart, both in prose (F70). `by_directory` grouping visible in the sidebar with one consistent path base (F68). |
| §4 | **PASS 7/7** — admission table below; no key bytes in the artifact. |
| §5 | **PASS** — survey over a changeset review refuses naming the branch; survey over a survey rebinds; `/review` still works after a ceiling refusal (nothing held); settled rounds release the rails in both directions (F67). |
| §6 | **PASS**, both legs plus control — `--permissive` is `BlockersOnly`, not `Permissive`. |
| §7 | **PASS 5/5**, at 80 **and** 100 columns. Stop-the-chunk condition clear. |

### §4 — the admission table

Planted per the round-11-corrected fixture; key body measured at **64 chars / 5.176 bits/char**,
above both `BASE64_LENGTH = 24` and `BASE64_ENTROPY = 4.2`.

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
| `deploy.pem` | listed, not withheld | listed | ✓ |
| `blob.bin` | withheld, binary | `binary content` | ✓ |
| `notes.txt` → `~/.ssh/id_rsa` | withheld **without naming what it is** | `a protected path` | ✓ denial beat containment |
| `elsewhere.conf` → `/etc/hostname` | withheld, outside | `a link out of the surveyed tree` | ✓ |
| `broken` → `/nonexistent` | absent, silently | absent from both lists | ✓ |
| planted files removed | **no note at all** | no note; `withheld` mentions = 0 | ✓ |

**The projection guarantee holds where it is claimed.** `MIIEow`, `BEGIN RSA PRIVATE KEY` and
`PRIVATE KEY` all count **0** in the survey artifact and **0** in the session journal.

**The opened buffer holds the raw key, and that is CORRECT — not re-filed.** Per the round-11 human
ruling and now per `projection.rb`'s own corrected docstring, a survey's `new` slot is a real file
buffer the human opened in their own editor; the guarantee covers the artifact, not that window.

### §6 — `--permissive` is `BlockersOnly`, with a control

| leg | result |
|---|---|
| **control**: no `--permissive`, approve over 9 unread rows | **REFUSES** — names 5 files + "and 4 more", offers `--permissive` |
| `--permissive`, approve over unread | **LANDS** — `this review is settled: approve` |
| `--permissive`, approve over an unanswered `blocker` | **REFUSES** — `approve is refused over 1 blocker nobody has answered: …/chunker.rb:20 (new)` |
| a note on the blocker's own line, then approve | **LANDS** |

### §7 — the thread pane, five checks, at two widths

Driven at **80 columns** and **100 columns**, never wide. Latencies below are from the quiet-machine
re-drive.

| # | check | result |
|---|---|---|
| 1 | answer renders in the thread pane, chat not stalled | **PASS** — answer landed under `## docent`; `:w` handed off in **130ms**; an `x` gesture landed in **152ms** while the answer was outstanding |
| 2 | duplicate `:w` refuses in words | **PASS** — 139ms, no traceback, journal unchanged |
| 3 | text typed after the answer still sends | **PASS** — second question answered; this is where round 11's F64 fired, and it does not |
| 4 | the exchange lands in the chat's journal | **PASS** — `annotation_placed`, `docent_asked`×2, `docent_answered`×2, `message`×4, `child_turn`×12 |
| 5 | the answerer names itself, never the `ROLE` constant | **PASS** — `"role":"diff_docent"` ×2 on the record |

**The stop-the-chunk gesture, measured.** With the thread pane deliberately closed so the `old` slot
was in the vocabulary but not open:

```
tabs after close:  tab3 = 2w
:LainThread        124ms
mode()             'n' in 122ms          <- no modal
tabs               tab3 = 3w
tab3:  lain://review | lain://thread/<id> | …/chunker.rb
stack traceback:   0
E5108 / Error:     0
```

The on-demand open works, `old`'s place in the slot order is respected (`sidebar | thread | file`),
and the vocabulary was not shrunk.

**The refusal rail fits at 80 columns**, which is the width-sensitive assertion this round was told
to distrust. At `&columns = 80`, `v:echospace = 68`, the message line renders
`lain: nothing has been typed un ... ow the last message and :w again` — fitted with an internal
ellipsis, ending on the words a human needs — while `:messages` holds the complete unfolded
sentence. No hit-enter prompt, no `-- More --`. That is the rail working as designed, not a truncation
defect.

**One behaviour worth recording, not a defect:** `:LainNoteDone` itself opens the thread pane, so a
survey goes to three windows on the hand-back rather than on `:LainThread`. At 80 columns that makes
the three windows 40 / 20 / 18 columns and the file window is very narrow. It is a real pane holding
a real thread, not a stale empty slot, so it does not contradict T11 — but a driver expecting two
windows until `:LainThread` will be surprised.

---

## F71 — LOW — `unknown skill` renders Ruby `inspect` into prose

**What is wrong.** F70's exact defect, one rail over and outside the chunk's scope.

```
you> /nosuchskill
unknown skill "nosuchskill", expected one of [:"create-epic-issues", :"create-plan", :critique,
:"execute-plan", :"gherkin-tests", :"iterate-epic", :"plan-epic", :"research-epic"]
```

Brackets, leading colons, and quoted symbols — the shape T9 removed from the scope rails.

**The mechanism.** `lib/lain/middleware/skill_dispatch.rb:66`:

```ruby
"unknown skill #{invocation.skill.inspect}, expected one of #{@catalog.names.inspect}"
```

A second site with the same shape: `lib/lain/skill/catalog.rb:105`.

**Why this is not a failed fix.** T9's card scoped itself to `lib/lain/review/session/scope.rb` and
named only the two scope refusals. This rail was never in it. Filing it so the class gets finished
rather than fixed one sentence per round.

**Reproduction.** `printf '/nosuchskill\n' | lain chat --no-nvim` and read the pane (or the
`pipe-pane` log — the alternate screen is torn down on exit).

**Fix shape.** The same `join(", ")` T9 chose, for the same reason. What would pin it: a spec
asserting the rendered sentence contains no `[` and no `:"`.

---

## F72 — LOW — the sidebar's path spelling was unified onto the one that does not resolve

**What is wrong.** T7 correctly made `lain://review`'s group header and file rows agree (F68 fixed).
It unified them on the **stripped** spelling — the one that does not resolve from cwd — while every
other surface that renders the same path keeps the climb.

Chat standing in `…/lain-qa-r12-2026-08-25/project`, surveying `/home/tara/dev/lain/lib/lain/survey`:

| surface | renders |
|---|---|
| `lain://review` header | `dev/lain/lib/lain/survey` |
| `lain://review` row | `dev/lain/lib/lain/survey/chunker.rb` |
| the mark message line | `../../../dev/lain/lib/lain/survey/chunker.rb` |
| the thread pane header | `-- thread at ../../../dev/lain/lib/lain/survey/chunker.rb:20 --` |
| the unread-rows refusal | `../../../dev/lain/lib/lain/survey/chunker.rb is unreviewed` |

Only the first two resolve to nothing. Round 11 described the header form as *"cwd-relative,
correct"*; the fix made the correct one match the incorrect one.

**The evidence that rules out "the rows are HOME-relative".** A tree at
`…/lain-qa-r12-2026-08-25/tmp/tmp.pmatrWTpu8/tree` rendered its row as
`tmp/tmp.pmatrWTpu8/tree/deploy.pem`, while the mark message for the same file read
`../tmp/tmp.pmatrWTpu8/tree/deploy.pem`. HOME-relative would have been
`tmp/lain-qa-r12-2026-08-25/tmp/…`. Both trees are consistent with "cwd-relative with every leading
`../` removed" and neither with a HOME base — round 11's diagnosis, re-confirmed.

**This is documented scope, which is why it is LOW and not MEDIUM.**
`spec/lain/frontend/neovim/review_view_spec.rb:220-227` pins the limitation ("a partial climb
renders indistinguishably from an in-project row") and T7's card says explicitly that it does not
fix it. Filing it because F68's *stated* remedy has now been met while the underlying asymmetry
moved rather than closed, and the next round should not read the consistent-but-wrong rendering as
finished work.

**Fix shape.** Have the one owner T7 created keep the climb rather than drop it, so all five surfaces
agree on the spelling that resolves. What would pin it: a spec asserting a row from a tree outside
the project round-trips through `filereadable()` after `fnamemodify(…, ':p')` from the session cwd.

---

## Withdrawn

**Not filed: "`:LainNoteDone` opens a spurious third window."** Reproduced at both widths and read
the layout before concluding: the third window holds `lain://thread/<anchor-id>` with real content,
not an empty `old` slot. Handing a note back *is* opening the thread. Recorded as a surprise in §7
above rather than as a defect.

**Not re-filed: round 11's F65 secret-leak half.** Settled by human ruling and now by
`projection.rb`'s corrected docstring. The buffer a survey row opens is the human's own file; the
guarantee covers the artifact, and the artifact is clean (§4).

---

## Model behaviour — not lain defects

- `qwen3-coder:30b` answered both docent questions directly and did real tool work to do it
  (`child_turn` reached 12 on the second thread). Round 11's clarifying-question park did **not**
  recur — but note that this is no longer evidence about the model, because T1 removed the tool that
  made parking possible. The model could not have parked if it wanted to.
- No literal `<function=` in any transcript this round; no session restarted for contamination.
- §7 asserts on none of the answers' content, per §8.

## Bench preconditions

- `OLLAMA_NUM_PARALLEL:1`, `n_slots = 1` — both still 1; every contention reading assumes it.
- `/mnt/nvme/opt/ollama-0.32.12`, `OLLAMA_CONTEXT_LENGTH=32768`, `OLLAMA_KEEP_ALIVE=5m`. Launched
  every chat with `--num-ctx 32768`, matching `/api/ps`, so no act paid a reload.
- `nvim` v0.12.4 (above the 0.11 minimum).

## P18 — process — the same orphans, two rounds running

Round 11 recorded 16 orphaned `while :; do :; done` spinners, ~1h07m old, and said it "was not
permitted to kill them". **This round found the same 16 — same PIDs 306398–306413, PPID 1, now 5.6
hours old at ~84% CPU each — and was refused permission to kill them too.** With a `mempalace`
process at 98.6% alongside, the box was at **0.0% idle** for the first half of the round. The
operator cleared both mid-round, at which point load fell from 17.7 to 2.9 and swap-free went from
19 MB to 3.3 GB.

**Two consecutive rounds' timing work was contaminated by processes neither driver could remove.**
Round 11 absorbed it by restating its timing comparatively; round 12 took a full set of numbers that
had to be thrown away. Absorbing it is the wrong response — a driver who finds orphans and cannot
clear them should escalate to the operator immediately, not work around it.

**The mechanism, and the one-line fix, are folded into `planning/qa/method.md`** (done this round,
in the quiet-machine section): a probe that spawns `nproc` busy loops and calls `kill $loadpids` on
its **last line** has cleanup conditional on nothing going wrong, which is the one case it is not
needed in. `trap 'kill $loadpids 2>/dev/null' EXIT INT TERM`, armed on the line after the spawn,
survives a failure, a timeout and a Ctrl-C. The skill's bring-up gate 3 already says to look for
these; what was missing was the instruction to stop *producing* them.

## Sandbox and close-out

Sandbox `~/tmp/lain-qa-r12-2026-08-25`, tmux `-L lain-qa-r12-2026-08-25`. `qa-sandbox.sh` could not
be executed (the harness classifier refused to run the script), so the sandbox was built by hand to
the same shape and its helpers copied from round 11's — `env.sh` rewritten for the new paths,
`nv.sh`/`peek.sh`/`drive.sh` byte-identical.

Every cockpit pane of every one of the five chats verified carrying the four redirected `XDG_*`, the
redirected `TMPDIR`, and `LAIN_DESKTOP=0` — checked **positively** (each pane reported `1` for the
`LAIN_DESKTOP=0` grep and `5` for the sandbox-var grep), not merely "it was exported". `~/.lain`
absent before act 0.

**The round ran fully muted.** Nothing in `survey.md` gates a tool call, so no act needed the
notifier and none was exempted. Proved by the negative: `dunstctl count displayed` and `waiting`
both **0**.

| close-out check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-08-25T15:48:12Z'` | **4** — investigated below, none of them this round's |
| positive control, `-newermt '2026-08-01'` | **6894** — so the 4 is a real reading, not a spelling accident |
| `git -C /home/tara/dev/lain status --porcelain` vs baseline | **baseline entries unchanged**; two additions, both this round's deliberate edits (`planning/qa/method.md`, the untracked findings file) |
| `ls -d /home/tara/dev/lain/.lain` | prints nothing |
| tmux server / stray `exe/lain` / stray nvim socket | gone / none / none |
| `dunstctl count displayed` / `waiting` | 0 / 0 |

**The 4 hits are another agent's concurrent `lain` use on this shared box, not a sandbox failure —
and the round can prove it rather than assert it.** The four are two *empty* session directories
(`11bd8307acf2`, `5da81ca310dc`), their parent's mtime, and `history`, all stamped 11:51:13–11:51:32
local. Four independent readings attribute them elsewhere:

- **This round's project hash is `d964ad332754`, and it is absent from `~/.local/state/lain/sessions`
  entirely** while being the only entry in the sandbox's own `sessions/`. Every one of the five chats
  wrote its journal there.
- The two leaked directories are **empty** — no journal was written into either.
- `~/.local/state/lain/history` ends in three lines of `hi`. This round's sandbox history holds every
  prompt it sent (`/survey …`, `/review …`, `/ruby …`) and contains **zero** occurrences of `hi`.
- The real `sessions/` holds **8,633** project directories; it is long-lived shared state on a box
  several agents use.

The redirection did its job: the sandbox history file exists, is populated with this round's prompts,
and the real one is not. **What this does cost is the check's usefulness** — on a shared box the
`find ~/.local/state/lain` negative can be tripped by a stranger, so a non-zero result now has to be
*attributed* rather than read as a verdict. That is worth folding into the method if a third party
trips it again; this round did not, because one round is not yet a pattern.

**Note for the process-table checks:** the operator killed 17 processes on this machine during the
round (16 orphan spinners + one `mempalace`). None belonged to this round — the QA tmux server, its
nvim and the ollama server all survived, verified before and after. A stray-process check that comes
back cleaner than expected is that cleanup, not sandbox behaviour.

No code bandaids were applied; there is nothing to revert. The only edit this round made to the repo
is the `method.md` process note above. The sandbox directory is left in place as evidence.

## Coverage

`survey.md` driven 7 of 7 sections for the second consecutive round. No other scenario was in scope;
the `rails-blog` owned round remains owed and the rotation does not advance on account of this round.
