# QA round 15 — 2026-08-27

## Summary

A full round: **all 17 scenarios in `planning/qa/scenarios/` were driven**, none dropped. The round
was scoped by the directory listing taken fresh at bring-up, not from any written count.

**Round 14's headline defect is fixed.** **F79** — a session whose subagent parked a question could
be neither forked nor resumed — no longer reproduces: with a question genuinely parked, both doors
exit 0 and the question `message`'s `causal_parents` resolves to a recorded `child_turn` (0
unresolved of 6 refs). The fix is the `ask_human` relay landed in commit `98571e69`.

**But that same relay introduced a new defect.** **F81 (MED-HIGH)**: a relayed child question is
journalled **twice** (the child's own record, plus the parent's relay citing it), while the parent's
own `ask_human` is journalled once. An answer clears one record, so **every subagent question leaves
one permanently stale inbox row**. With everything answered, `/inbox` correctly said
`(no questions pending)` while `inbox_count`, `lain://inbox` and `fleet` all disagreed. This is the
mechanism behind round 11's **F64**, which was filed as a docent-specific stall and is in fact
general.

Two scenarios that had never been driven got their first drive: **`shell-term-approval`** (written
during round 14, zero coverage) passed §0–§3a on every measured value, and **`memory-and-dogfood`**
was driven end to end for the first time. **`survey` §7 — the docent thread, owed since round 7 and
dropped by rounds 8, 9 and 10 — was driven and passes.**

`rails-blog` was reached with Rails installed (8.1.3.1, sandbox-contained) and produced the round's
most interesting *non*-defect: a single 112 KB tool result pins occupancy at 100% with
`head_bytes: 2`, so compaction has nothing to act on. Filed as **F82**, a context-economics finding,
after the decision path was cleared of blame.

**Three findings were withdrawn on the mechanism** rather than filed — see "Withdrawn". All five
close-out negatives passed, including `Gemfile.lock` byte-identical under a sandbox `GEM_HOME`.

| id | sev | what |
|---|---|---|
| **F81** | **MED-HIGH** | a relayed subagent question is journalled twice, so every answered subagent question leaves a permanently stale `lain://inbox` row and an `inbox_count` that never returns to 0 — introduced by F79's fix |
| **F82** | MEDIUM | one oversized tool result pins occupancy at 100% with an empty compactable head (`head_bytes: 2`); `approaching_window` fires with no possible action and nothing tells the human |
| F83 | LOW | `fleet` counts completed subagents forever — the HUD read `fleet 3` with all three children finished |
| P29 | process | the skill's own `grep -oE '...(KEY\|TOKEN)...' .envrc` capability check matches **comments**, and reported a key on a box whose `.envrc` says it has none |
| P30 | process | `drive.sh`/`peek.sh` resolve the chat pane by `grep -w ruby \| head -1`; a leftover probe session silently steals the drive |
| P31 | process | `cockpit-surfaces` §4b/§7's `<C-w>l` advice is wrong once a thread pane is open — the layout becomes sidebar \| thread \| file |
| P32 | process | `shell-term-approval` §3a's snippet is not executable as written (`exit_status` not `status`; `env:`/`timeout:` required) |
| P33 | process | `survey` §2's corpus figure is stale again (**749** files / 152,909 lines, not 742 or 748) |

---

## Round-14 and round-13 defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F79** (spawned session cannot fork/resume) | **FIXED** | question parked (`? researcher …`, prompt `human>`, `fleet 2`); `--fork SESSION@DIGEST` exit **0**, `--resume` exit **0**; the question `message`'s `causal_parents` resolves to a recorded `child_turn`; **0 unresolved of 6** refs across 82 digests. Control: a spawn that *answered* also forks (both doors exit 0). |
| **F78** (zero-usage turn zeroes occupancy) | **symptom does not reproduce; records UNVERIFIED** | see the F78 section below — the protected property held in both severing shapes, but neither documented `truncated_stream` kind could be provoked |
| **F73** (2nd concurrent cockpit deadlocks on E325) | **not re-driven** | the round used one cockpit at a time; not attempted, so not a verdict |
| F80 (`--isolation worktree` leases nothing in chat) | **FIXED, both halves** | help text now reads *"Isolation backend spawned subagents lease workers from, per dispatch (none, worktree); the main chat's own session is never isolated"*. And a spawned child **did** lease: its `child_turn` shows cwd contents `.git lib spec` — the committed tree only — while the parent's cwd carries untracked `README.md`/`notes.txt`. Reaped cleanly (no `.git/worktrees` residue). |
| F76 (`lain://approval` wraps mid-token) | **REPRODUCES** | buffer held `bash({"command" => "cd … && bundle install` / `--quiet"})` — `install --quiet` split across the wrap |
| F52 (approval trailer folds closed) | **REPRODUCES, unchanged** | line 1 `level=1 closed=-1` (record row OPEN), line 2 `closed=2`, line 3 `closed=3` — trailer and separator each fold on their own line |
| F16 (retry ordinals `1,2,3,3`) | **FIXED** | `attempt 1,2,3` then `attempt 4, giving up` — a higher ordinal |
| F58 (retry lines share one newline) | **FIXED** | 4 retry lines, 4 newline terminators |
| F17 (`lain://timeline` freezes) | **FIXED** | across two asks incl. a multi-line reply: timeline 1→6→8, request 1→631→649, diff 1→44→36 |
| F29 (`/inbox` drain swallows next command) | **FIXED, holding** | at a real parked `human>`: journal frozen at **197** and `message` at **5** across `/status`, `/inbox`, `/status`-after-`/inbox`, `/nonsense`; prose then landed as `payload={"answer" => …}` |
| F31 (thread pane `:w` refusal raises) | **FIXED** | second `:w` refused **in words** in **0s**, `blocking: v:false`, 0 tracebacks, journal unchanged |
| F66 (`:LainThread` before hand-back) | **FIXED and improved** | `b:lain_thread_anchors` `<unset>` pre-hand-back; refusal is now `lain: note not handed back yet -- hand it back with :LainNoteDone` (round 11 saw the unhelpful `no thread on this line`) |
| F34/T10 (focus after `<CR>`) | **FIXED** | focus stays on `lain://review` after `<CR>`; NEW window holds the real file |
| F38 (mark ack names a hash) | **FIXED** | `lain: marked reviewed: 1 hunk(s) of lib/bowling.rb` |
| F40 (answering at nvim orphans the TTY) | **FIXED** | `approval_pending=5 == approval_decision=5`; escalation `surfaces` rung shows both `(nvim)` and `(tty)`; after `:LainApprove` the chat pane printed `[call_s87awgfw stdout] HELLO` and moved to the next call |
| F74 (`stalled_stream` kills healthy turns) | **did not reproduce** | 0 `run_interrupted` across the rust session (18 turns) and the bowling session (39 turns). One `stalled stream` fired in the blog session and was **correct** — I had deliberately stripped the terminal frame's counts. |
| T5/T16 (refusal rail) | **FIXED** | a **227-char** refusal middle-elided to fit `v:echospace`=88 with the full sentence in `:messages`; a break-carrying refusal and a **60-line** refusal both non-blocking; **0** `stack traceback:` anywhere; RPC alive throughout |
| T14 (iteration ceiling per-ask) | **not reached** | the model completed `/create-plan` under 25 iterations, so the ceiling never fired. Ceiling constant confirmed at **25** via `/ruby`. |

---

## F81 — MED-HIGH — a relayed subagent question leaves a permanently stale inbox row

**What is wrong.** Every `ask_human` raised by a **subagent** is written to the journal as **two**
`message` records: the child's own, and the parent's relay citing the child's as its
`causal_parents`. The parent's *own* `ask_human` is written once. An answer clears one record, so
each relayed question leaves exactly one residue that no surface can ever discharge.

**Mechanism.** The relay landed in `98571e69` ("ask_human: a child asks its parent, and the parent
relays") — the same change that fixes F79. The two records are distinguishable by `from`:

```
ts=22:46:54.373395Z  from=blake3:ab892a24…(the child)   digest=blake3:a2b9f493…  causal_parents=[blake3:46f87e36…(child_turn)]
ts=22:46:54.377887Z  from=blake3:53443cc9…(the parent)  digest=blake3:fb40e1ee…  causal_parents=[blake3:a2b9f493…(the child's record)]
```

versus the parent's own question, which is a single record:

```
ts=23:01:37.483219Z  from=blake3:53443cc9…  asked_by="lain"   (1 record, not 2)
```

**The evidence that rules out the innocent explanation.** The counts are exact and arithmetic:
**ASK=7, ANSWER=4** — three researcher questions × 2 records + one parent question × 1 = 7. With
*every* question answered and nothing live, the four readers disagree:

| reader | says | correct? |
|---|---|---|
| `/inbox` at `you>` | `(no questions pending)` | **yes** |
| status feed `inbox_count` | `3` | no |
| `lain://inbox` | 3 rows, each offering `-- <CR> or r opens the set (:LainOpen / :LainReply {answer})` | no |
| `:LainReply` on such a row | refuses: *"no question is awaiting a reply — it was answered already… **The inbox line offering it is stale: nothing you type here is recorded, and nothing is waiting on it.**"* | **yes, and it knows** |

That last row is what makes this a defect rather than a rendering lag: **the reply path already
detects the staleness and says so in words** — the row is still drawn, with a live affordance, and
still counted.

**Control.** The parent's own `ask_human` (single record) left **zero** residue: `inbox_count` went
2 → 3 → 3 as a second child question was asked and answered, never dropping. Answering the parent's
own question did clear it.

**Reproduction** (local bench, one cockpit):

```bash
# take one ordinary turn first, then:
you> @researcher[/critique] lib/bowling.rb      # child parks a question, prompt -> human>
human> <ordinary prose that does not start with '/'>   # answer it; child resumes and finishes
you> /inbox                                      # -> "(no questions pending)"
$QA/nv.sh buf 'lain://inbox' 12                  # -> still shows the answered question, with an affordance
ruby -rjson -e 'j=JSON.parse(STDIN.read); p j["inbox_count"]' < "$XDG_STATE_HOME/lain/status/<hash>/state.json"   # -> 1
```

**Fix shape.** Either the relay should not write a second `message`, or the inbox fold should key on
the question identity rather than the record so that one answer discharges both. What would pin it:
after answering N subagent questions with none live, `inbox_count == 0` and `lain://inbox` renders
its `(no questions pending)` placeholder — with a control that a parent's own question behaves
identically.

**This is round 11's F64, generalised.** F64 was filed as "a docent that parks an `ask_human`
strands the thread pane while the inbox, the HUD and `:LainReply` disagree." The disagreement is not
docent-specific and does not need a stall: it happens to every relayed subagent question, including
ones that are answered normally.

---

## F82 — MEDIUM — one oversized tool result pins the context with nothing to compact

**What is wrong.** A single tool result larger than the window's compactable head puts the run at
~100% occupancy permanently. `approaching_window` fires, and there is no action available, because
the oversized result lives in the tail `keep_last` retains — so the compactable head is empty.

**Mechanism, and why the decision path is NOT at fault.** Driven on the Rails subject with
`--compact-strategy elide-tools+summarize-conversation`. A `read_file` of a 112,892-byte file
produced a tool result of exactly that size; `request_sent` grew **19,470 → 114,952 → 133,804**
bytes. The decision at the top of the next turn:

```json
{"compacted":false,"signals":["approaching_window"],"head_bytes":2,"summary_hits":0,
 "summary_misses":0,"cold":true,"would_not_shrink":false,"window_tokens":32768,
 "used_tokens":32745,"provenance":"probed"}
```

`used_tokens` 32,745 of 32,768 is **99.93%**, and `provenance: "probed"` — so the denominator is
real and the signal legitimately fired. But **`head_bytes` is 2** (an empty JSON array) on this and
every other decision in the session. `Compaction::Boundary` computes
`raw = [messages.size - @keep_last, 0].max` (`boundary.rb:115`), and on a four-turn session
`keep_last` retains everything. There is nothing in the head to compact.

**What this rules out.** I traced and eliminated each innocent-looking alternative before filing:

- not the scheduler deferring on a warm cache — `Scheduler#evaluate` returns `COLD_FREE` when
  `cold:` is true (`scheduler.rb:149-155`), and ollama is always cold (`capability_degraded:
  prompt_caching`, `cold: true` on the record);
- not the strategy refusing to derive — `derivation_refusal_streak` is **0**;
- not a rewrite that would not shrink — `would_not_shrink` is **false**;
- not a guessed denominator withdrawing the signal — `provenance` is `probed`;
- not a stall — the turn completed correctly after ~4 minutes of prefill, with the machine 85% idle
  and the model resident; `provider_wait` recorded `waited_seconds: 135.826, in_flight: 1`.

**Why it is still a finding.** The run has no path back below the window and nothing says so. The
HUD reads `ctx 100%`, `compactions` stays 0, and `approaching_window` fires each turn with no
possible action. A human watching this cannot tell "compaction is working and has nothing to do"
from "compaction is broken" — it took a code read to tell them apart here.

**Feature gap alongside it.** There is no bound on a single tool result's contribution to the
retained tail. `read_file`'s `WHOLE_BOUND` is 262,144 bytes — comfortably more than the 32,768-token
window can hold — so a single in-bounds read can exceed the window by design.

**Reproduction.**

```bash
ruby -e 'File.write("big.rb", (1..1200).map{|i| "# line #{i}: " + ("lorem ipsum dolor sit amet " * 3)}.join("\n"))'
lain chat --provider ollama --model qwen3-coder:30b --compact-strategy elide-tools+summarize-conversation
you> Read big.rb in full with read_file. Then summarise what you saw in one sentence.
you> Now name one Rails convention, in one short sentence.
# -> decision 3: used_tokens 32745/32768, signals ["approaching_window"], head_bytes 2, compacted false
```

**Fix shape.** Either let the head reach into the retained tail when a single message exceeds some
fraction of the window, or surface the state — a rendered line when `approaching_window` fires with
an empty head, so the human learns the context is full and uncompactable rather than inferring it.

---

## F83 — LOW — `fleet` counts completed subagents forever

The HUD and the status feed read `fleet 3` with all three spawned children finished and their
results already folded into the parent's transcript. `fleet` never decrements. Same session as F81;
`state.json` showed `"fleet"` holding three digests after the last child returned its critique. Low
because nothing depends on it, but it is a second reader disagreeing with the record in the same
family as F81.

---

## Scenario coverage — all 17, from the directory listing

| scenario | driven | notes |
|---|---|---|
| `session-and-window` | **§1–§8 complete** | all 8 launch refusals exact; cold→warm re-resolution `8192/guessed` → `32768/probed`; the documented `used_tokens` lag confirmed 1/1; `capability_degraded` exactly 1; options asymmetry both halves; price table exact incl. both unpriced models raising; freshness lint incl. the 90/91 boundary and a genuinely deleted marker |
| `rust-cli` | **complete** | 5/5 definition-of-done (`the 3` / `cat 1`); deliberate break recovered — full multi-line rustc diagnostic survived as a tool result and the model self-corrected; three gated `bash` calls each re-prompted; read-before-write and denial refusals both fired by name |
| `bowling-ruby` | **§1–§3 complete** | **5/5 driver oracles**, incl. oracle 4. `/create-plan` finished under the ceiling. Wedge, `human>`, answer, return to `you>` all driven |
| `cockpit-surfaces` | **§1,§2,§3,§4,§4b,§5,§5b,§7,§8 driven; §6 half** | piggybacked on the bowling subject, not the smoke test. §4b's placement-order check — the one it exists for — **passes**: 5, 9, 2, 3, not positional. §6's UTF-8-reminder half not driven |
| `bench-arms` | **complete** | chat closed first. Grades 0.812 / 0.812 / 0.938; **non-zero token row for every arm** (233.9 / 442.1 / 3316.9); attribution header names fixture, model, `isolation: unset`; cost column **refuses** to price `qwen3-coder:30b` |
| `failure-injection` | **§1,§2,§3,§7–10 constants,§11a** | torn turn: 75 vs 76 turns under the same head + `1 line unparsed`; dangling edge refuses identically from **three** doors; flat-record damage lands in its own index space. Supervisor door **not driven** — recorded, not passed |
| `secret-boundary` | **§0,§1,§2,§7** | classifier table exact on all 7 rows incl. the `*.pub` carve-out and `out_of_scope`. §3–§6 not reached (budget) |
| `changeset-review` | **§0,§1, all three scopes** | base/head roles named distinctly in every refusal; `cumulative` / `commits` / `by_directory` visibly different |
| `subagents-and-backends` | **§1, plus F80's leasing half** | `--exec core` refused by name without advertising itself; worktree lease **observed** via the child's own cwd |
| `memory-and-dogfood` | **first end-to-end drive** | `memory_root`=39 paired with `turn_usage`=39; manifest rides `<workspace>`; `consolidate` no-ops **with a reason**; `improve --dry-run` renders over 11 friction signals, provider untouched; `bench sweep` five-arm recall@k offline (vector 0.667 > graph 0.438 > rest 0.333) |
| `rails-blog` | **§0 + the compaction act** | Rails 8.1.3.1 installed sandbox-contained; 78 files (not "hundreds" — see P33 family); reached 99.93% occupancy and produced **F82** |
| `repl-commands` | **§0,§1,§2 + the ten-command surface** | `/mode !` resets `accept_edits: notify, vi` → `plan: no layers` in ONE `mode_switch`; all four `/pin`-`/unpin` refusals carry the grammar. §6 (`/mode auto`) and §7/§8 not driven |
| `epic-tier` | **§1 + command and gate refusals** | four `[epics] home` refusals distinct and path-named; `[epics.gates]` names all four policies and the four-stage pipeline; `queue` shows itself as a **fold** (`folded 0 journals … 0 gate records`) |
| `survey` | **§1,§2,§7** | **§7 is the four-round debt and it passes** — answer rendered in the thread pane after ~25s while RPC gestures landed in **0s**; duplicate `:w` refused in words; `docent_asked`/`docent_answered` both journalled |
| `prompt-slots-and-roles` | **§1–§4, §6 free half** | override lands verbatim; `slot_fills`=0 confirms round 13's correction; top-level and role refusals are correctly **different** sentences. §6's paid half genuinely unreachable |
| `shell-term-approval` | **first drive: §0,§1,§2,§2a,§2b,§3,§3a** | every measured value reproduced, incl. the **newline row** (`separators=0`) and `PROGRAM_RUNNERS` at exactly 92 |
| `ollama-cloud-arm` | **§1,§2 (the free steps)** | missing-key refusal carries all four required elements; plaintext refusal argues in the arm's own terms. Paid steps not driven (budget, not capability) |

**Nothing was dropped.** What was not reached inside a driven scenario is named above with its
reason. The two "budget" reasons (`secret-boundary` §3–§6, `ollama-cloud-arm`'s paid steps) are
patience costs on a bench that was already up, not capability gaps, and are stated as such.

**The one genuine capability gap, with the check that established it:** `prompt-slots-and-roles` §6's
paid half needs `ANTHROPIC_API_KEY`, which is on no shell and in no `.envrc` on this box. Confirmed
three independent ways: `.envrc` mentions the name only inside a comment saying this desktop has
none; the environment has no such variable; and `lain up --provider anthropic` refused at pre-flight
with `ANTHROPIC_API_KEY is not set`. Round 14's claim stands.

---

## F78 re-check — symptom does not reproduce, records unverified

Round 14 filed F78 (a zero-usage `turn_usage` zeroing feed `occupancy` and `last_turn_usage`).
`failure-injection` §1a says the fix gates on `total_input_tokens` being positive and increments
`unmeasured_turns`. I built a severing proxy and drove **both** documented shapes:

| shape | what lain did |
|---|---|
| cut before any `done:true` frame, graceful FIN (`kind: "unterminated"`) | retried ×4, refused `end of file reached`; 2 × `run_interrupted`; **no turn committed** |
| terminal frame delivered with `prompt_eval_count`/`eval_count` stripped (confirmed stripped on the wire) (`kind: "counts_absent"`) | `stalled stream: no bytes for 31.0s, past the 30s stream_stall_timeout, with the connection still open` |

**The property F78 protects held in both**: `occupancy` stayed at `0.152679443359375` — the last
real reading — `run_tokens` stayed at 5005, and **no zero-usage `turn_usage` was ever written**, so
there was nothing to overwrite the real reading with.

**But**: **0** `truncated_stream` records in either variant, and `unmeasured_turns` never moved off
0. I could not reach either documented `kind`. **Reporting this as inconclusive on the records, not
as a pass.** What would settle it: a proxy that reproduces ollama's terminal frame byte-for-byte
minus the two count fields, so the assembler accepts it as terminal rather than waiting for more.

---

## Withdrawn — nearly filed, disproved by the mechanism

- **"compaction is broken at 100% occupancy."** The first reading of F82 was a defect in the
  decision path. `head_bytes: 2` plus `derivation_refusal_streak: 0` plus
  `Scheduler#evaluate`'s `COLD_FREE` branch showed the decision path is behaving correctly and there
  is simply nothing to compact. Refiled as F82, a context-economics finding, with the decision path
  explicitly cleared.
- **"`docent_answered` does not name the answerer."** `DocentAnswered` is
  `Data.define(:anchor_id, :question, :answer)` **by design** and joins to `docent_asked` — which
  does carry `role: "diff_docent"` — by `(anchor_id, question)`, the same pair the duplicate guard
  is keyed on (`docent.rb:983-990`). Documented scope.
- **"tier-1 tools check paths, contradicting CLAUDE.md."** A case-insensitive `grep -i sensitiv`
  reported 4 hits each in `grep.rb` and `glob.rb`. They are `case_insensitive` (the substring) and
  comments *explaining* the three-place boundary. `Sensitivity::Filter.new` appears **exactly once**
  in `lib/` (`policy.rb:120`). CLAUDE.md's claim holds.
- **"a 44-window review tab."** `nv.sh expr` emits no trailing newline, so two reads concatenated
  (`tab2=4` + `4`). Measured directly: 2 tabs, tab2 has 4 windows. See P34.
- **"`lain epic approve` has no refusal."** zsh word-splitting — `$c` unquoted became one argument
  and Thor answered `Could not find command "approve nosuch"`, which wears the shape of a real
  refusal. `method.md` documents this trap; I hit it anyway. The real refusals are excellent.

---

## Scenario corrections — expectations that were wrong, not defects

1. **`shell-term-approval` §0/§8: the arm IS observable today.** Both say the arm cannot be told
   from outside because the arm record "does not exist yet", so the only oracle is a command whose
   arms disagree. But the **triage rung journals the shell verdict** —
   `escalation.rb:538` builds `"shell verdict #{decision.name} -- …"` — and verdict→arm is
   deterministic (`bash.rb:139-141`, allow→term else→string). Confirmed in both directions in one
   session: `exit 3` → `shell verdict allow` → exit 127 (term); `echo "hello world"` →
   `shell verdict abstain … node kinds` → exit 0 with quotes consumed (string).
2. **`shell-term-approval` §3a's snippet is not executable** (P32): the member is `exit_status`, not
   `status`, and `Pipeline#call` requires `env:` and `timeout:`. Corrected values, measured:
   `exit_status: 126`, `stderr: "lain: tee: not permitted downstream of a pipe\n"`, `out.txt` never
   written, `tee` ∉ `STDIN_SAFE` (46 entries).
3. **`secret-boundary` §0's `HOME=""` warning is stale in the good direction.** It says the
   constructor "refuses `/` outright; `""` is the one to watch", implying `""` is accepted. Both
   refuse: `home must not be the filesystem root, got "/"` and `home must be an absolute path,
   got ""`.
4. **`secret-boundary` §0's four-export `HOME` recipe did not work on this box.** With
   `GEM_HOME`/`GEM_PATH` set as written, `bundle exec` failed
   `Could not find rubocop-thread_safety-0.7.3 in locally installed gems`. `Sensitivity.new` takes
   `home:` explicitly, so the classifier can be driven without redirecting `HOME` at all — which is
   also safer.
5. **`survey` §2's corpus figure is stale again** (P33): re-counted **749 files / 152,909 lines**
   (round 11: 742/161,963; round 14: 748). Line count fell while file count rose. The instruction to
   re-count rather than copy is the right one and should stay; the number in the table should
   probably go.
6. **`rails-blog` says `rails new` yields "hundreds of files".** Rails **8.1.3.1** with
   `--skip-bundle` yields **78 files / 20 `.rb` / 440 KB**. The scenario's premise (large tool
   results) still holds, but via file *size*, not file count.
7. **`repl-commands` §1 tells the driver to set `/mode auto`**, which `method.md` forbids outside the
   two sanctioned sections (§6 and `secret-boundary` §5). I drove the `!` reset from
   `accept_edits + notify + vi` instead, which tests the same property. The two documents should
   agree.
8. **`repl-commands` enumerates 20 commands; `/help` lists a 21st** — `/introspect`, which renders a
   report including an explicit "unreported" section naming what it cannot see.
9. **`cockpit-surfaces` §1's `lain://approval` fold note is out of date in the good direction.** It
   says driving §8 against that buffer "is exactly what T9/T12 are meant to add, not a claim that
   they already have". They have: `lain://approval` is fold-eligible now (`foldmethod=expr`,
   `foldminlines=0`) and §8 was driven against it.

---

## Model behaviour — not lain defects

- **`qwen3-coder:30b` still emits no parallel tool calls. Re-measured.** Asked explicitly for three
  `bash` calls "in ONE message as three separate tool_use blocks", it emitted them strictly one per
  turn. `cockpit-surfaces` §5's "all at once" half and §8's two-parked-rows steps remain
  **undrivable with this model** — the single-pending path was driven and passes.
- **It silently drops pipeline stages.** Asked to run `cat README.md | tee out.txt`, it ran
  `cat README.md`. Any `shell-term-approval` row driven through the model can therefore assert
  something other than what was asked; drive `Verdict`/`Pipeline` through `/ruby` instead.
- **No literal `<function=` appeared this round**, across ~110 turns in five sessions. No session
  needed a restart.
- **The bowling artifact is correct (5/5 oracles) but its own spec is not.** The test
  *"returns 150 for a perfect game"* asserts **300** with perfect-game rolls — a mislabelled
  duplicate of the test above it — so the all-spares/150 case is uncovered by the model's own suite.
  Exactly the §3 question ("are the model's own specs meaningful or vacuous?"): mostly meaningful,
  with one silent hole.

---

## Process notes

- **P29 — the skill's own capability check matches comments.** `.claude/skills/manual-qa/SKILL.md`
  and `method.md` both prescribe
  `command grep -oE '[A-Z_]*(KEY|TOKEN)[A-Z_]*' .envrc` to establish whether a key exists. On this
  box it reports `ANTHROPIC_API_KEY` — from a **comment** reading *"This desktop has no
  ANTHROPIC_API_KEY anywhere"*. The check that is written to prevent a false "unreachable" can
  manufacture a false "reachable". Grep for an `export` of the name, or test the variable.
- **P30 — a leftover probe session steals the drive.** `drive.sh` and `peek.sh` resolve the chat
  pane with `grep -w ruby | head -1`. With a probe `lain chat` still alive, `drive.sh` typed a
  prompt into the **cockpit** instead of the probe. Kill probe windows before the cockpit, or
  target the pane explicitly.
- **P31 — `<C-w>l` is wrong once a thread pane exists.** `cockpit-surfaces` §4/§4b say `<C-w>l`
  reaches the file. With a `lain://thread/<uuid>` window open the review tab is
  sidebar \| thread \| file, and one motion lands in the thread. Verified with a control: with no
  thread pane the layout is 2 windows and one motion is correct. **Unresolved**: a thread window
  appeared twice, with different uuids, without `<leader>Lt` being pressed; `<CR>` on an annotated
  row does **not** reproduce it. Recorded as inconclusive.
- **P32 / P33** — see "Scenario corrections" 2 and 5.
- **P34 — `nv.sh expr` emits no trailing newline**, so two consecutive reads concatenate in a
  transcript. This manufactured an apparent 44-window tab. Worth a `\n` in the helper.
- **A whole-pane grep for `[y/N]` false-positives forever.** An answered approval line stays on
  screen, so an approval detector must read only the **last non-blank** line. Cost two wasted
  probes before I fixed it.
- **A helper resolving a pane by window NAME gets nvim** — `lain up` puts nvim and the repl in one
  window called `chat`.
- **The zsh word-splitting trap fired again** (the ninth recorded instance family), in
  `lain epic <subcommand> <arg>`. It produced a Thor "Could not find command" that reads exactly
  like a real refusal.
- **The approval gate was driven under a stated allow-list with an audit log**
  (`$QA/records/gate-log.txt`): a command was approved only if every absolute path it named resolved
  under `$QA` and its verb was inspection/test. `bundle install --quiet` was **denied** on that rule
  — the `cd` was inside the sandbox but `bundle install` writes to `GEM_HOME`, which is not, and
  that is the P9 mechanism. 6 approve / 2 deny over the rust session, 5/5 pending-vs-decision in the
  bowling session.
- **`docker` on this box is podman** emulating the Docker CLI. Recorded because
  `subagents-and-backends` §4 and `shell-term-approval` §9 both key on it.

---

## Bench and close-out

**Bench.** `/mnt/nvme` ollama 0.32.12, up since 2026-08-25, `OLLAMA_CONTEXT_LENGTH=32768`,
`OLLAMA_KV_CACHE_TYPE=q8_0`, `OLLAMA_FLASH_ATTENTION=1`, Vulkan. `qwen3-coder:30b`, resident at
`ctx=32768` for most of the round. `OLLAMA_NUM_PARALLEL` is **unset** in the server's environ (so
ollama's default) and no serve log was available to read `n_slots` — the server was started by an
earlier session, not by this round. **Every contention reading in the scenarios assumes
`n_slots = 1`; this round could not confirm it**, so no contention conclusion rests on it. The one
`provider_wait` record observed read `in_flight: 1`.

**Machine.** 93.1% idle at bring-up, **zero** orphaned spinners, zero stray cockpits, `parallel_rspec`
0. Re-checked mid-round at 85.4% idle before the only timing claim (F82's prefill), and at that point
the model was resident and no other work was running.

**Desktop.** The **entire round ran muted**. `LAIN_DESKTOP=0` was exported before every `tmux
new-session` and verified per pane (`1` on every pane of every server, including after the server was
restarted for the Rails `GEM_HOME`). `dunstify` **is** on `PATH` — the sandbox rebuilds `PATH` but
ends it in `:$PATH` — so the mute was doing real work. **No act ran with the notifier on**, so the
desktop-notifier half of `cockpit-surfaces` §5 (three-at-once, withdrawal) was **not driven**; it is
also undrivable with this model, which cannot produce two coexisting pendings. Proof by the
negative: `dunstctl count displayed` = **0** and `waiting` = **0** at close-out against a 0/0
baseline — and approvals are raised `-u critical`, which never auto-expires, so any that fired would
still be on screen.

**Close-out negatives, all five.**

```
find ~/.local/state/lain -newermt '2026-08-27T22:19:24Z' | wc -l   ->    0   (the assertion)
find ~/.local/state/lain -newermt '2026-08-19'           | wc -l   -> 1768   (positive control)
find ~/.local/state/lain -newermt '2026-01-01'           | wc -l   -> 9436   (second control)

git -C /home/tara/dev/lain status --porcelain   -> byte-identical to the baseline taken before act 0
                                                   (3 lines, same 3 paths, taken in a clean shell)
md5sum Gemfile.lock  before: f51222770364686a2cb61b9845368b05
                     after:  f51222770364686a2cb61b9845368b05     (P9 held under a sandbox GEM_HOME)
ls -d /home/tara/dev/lain/.lain                 -> absent          (invisible to the other two)
dunstctl count displayed / waiting              -> 0 / 0
```

The sandbox is left in place as evidence at `~/tmp/lain-qa-2026-08-27-r15`, including
`records/gate-log.txt` (every approval decision with its reason), `records/findings-so-far.md`
(the running notes), the two severing proxies, and every journal.
