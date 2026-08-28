# QA round 14 — 2026-08-27

## Summary

The first round driven under the **corrected skill contract** — the user's instruction was that
`/manual-qa` drives every scenario in `planning/qa/scenarios/`, not a preplanned subset, and the
skill and README were rewritten mid-round to say so (see "What the round changed in the method").
Sixteen scenarios existed at bring-up, not the fourteen the skill hard-coded; a seventeenth
(`shell-term-approval`) was **written during this round** because the shell subsystem had no
scenario at all and the draft chunk's own card T10 for it had never been executed.

Two new defects. **F79 (HIGH)** — any session in which a subagent asks a question can be neither
`--fork`ed nor `--resume`d: the question `message` cites a `causal_parents` digest that is nowhere
in the journal, so the edge dangles by construction. This is round 5's F23 failure returning through
a different mechanism, and it was reproduced on two independent sessions with a clean control.
**F78 (MED-HIGH)** — a zero-usage `turn_usage` record silently resets the status feed's `occupancy`
to `0.0` **and** `Agent::Accounting#last_turn_usage` to `0`, which is the number compaction's `Need`
divides; `Accounting`'s own docstring names zero as "an empty context" and `observe` writes it
anyway.

**F73 (round 13, HIGH) reproduces unfixed.** A third defect, **F80 (MEDIUM)**, settles
`subagents-and-backends` §3's standing open question: `--isolation worktree` is accepted in a chat
and leases nothing, because no chat path spawns an actor — and the help text that used to say so has
been removed.

Confirmed working with evidence: F16, F17, F29, F31, F38, F66, T6, the `/mode !` reset, the
three-place secret boundary, every tool bound including both control pairs, and the iteration ceiling
on all three of its checks — the last now at **0 bytes of stderr** against the documented 226.

**Two long-standing debts were discharged in a second pass**, after an initial read that wrongly
treated "needs a model" as "unreachable": the **local-bench** scenarios (`subagents-and-backends`,
`memory-and-dogfood`) were driven on ollama, the **metered** arm was driven with the `OLLAMA_API_KEY`
that is in `.envrc`, and **`rails-blog` §2 — unreached in thirteen rounds — was reached without
Rails at all**, by taking the scenario's own advice that "a directive that reads large generated
files back" is what would drive it. Only `prompt-slots` §6's paid half remains genuinely
unreachable: there is no `ANTHROPIC_API_KEY` on this box.

| id | sev | what |
|---|---|---|
| **F79** | **HIGH** | a session whose subagent **parked a question** cannot be forked OR resumed — the question `message` cites a causal parent no record carries. A spawn that *answers* forks fine, which localises the fix |
| **F73** | **HIGH** | *(round 13, reproduces)* a second concurrent cockpit deadlocks its nvim on an E325 swap modal; the swap path is still an unscoped constant |
| **F78** | MED-HIGH | a zero-usage `turn_usage` resets feed `occupancy` to 0.0 and `last_turn_usage` to 0 — compaction's own input |
| F80 | MEDIUM | `--isolation worktree` is accepted in a chat and leases nothing — no chat path spawns an actor, and the help text no longer says so |
| F76 | LOW | *(round 13, reproduces)* `lain://approval` hard-wraps the command mid-token |
| P24 | process | `repl-commands.md` §0's fallthrough expectation contradicts a spec that pins the opposite |
| P25 | process | `survey.md` §2's corpus figure is stale (748 files now, not 742) |
| P26 | process | `cockpit-surfaces.md` §4 quotes the two-window changeset banner under a survey example |
| P27 | process | the new `shell-term-approval.md` shipped with a literal NUL byte, making it a binary file |
| P28 | process | two stray directories from a round-11/12 probe still sit in the lain checkout — P16's false positives are what camouflaged them |

## Round-13 defects and standing claims re-checked

| id | verdict | evidence |
|---|---|---|
| F73 (concurrent cockpit swap deadlock) | **REPRODUCES — unfixed** | two cockpits, two projects, two sockets: A answers `1+1`→`2`, B times out at 15s and is SIGTERM'd; B's pane carries E325 lines; both `lain-cockpit:%%start.swp` and `.swo` present at the unscoped constant path |
| F74 (`stalled_stream` kills healthy turns) | **did not reproduce** | zero `run_interrupted`/`stalled` across a clean 20-turn rust session, a 25-turn ceiling session, two full `bench arms` suites and ~10 further sessions. Not proof of a fix — the trigger was never characterised — but no occurrence this round |
| F76 (`lain://approval` wraps mid-token) | **REPRODUCES** | buffer held `... && echo -e \"h` / `ello world hello` — `hello` split across the wrap |
| F16 (retry ordinals `1,2,3,3`) | **FIXED** | blackhole probe rendered `attempt 1,2,3` then `attempt 4, giving up` — a *higher* ordinal |
| F17 (`lain://timeline` freezes) | **FIXED** | after 20 turns: timeline 40, request 1113, diff 44, journal 88 lines against 20 `turn_usage` / 20 `request_sent` |
| F29 (`/inbox` drain swallows the next command) | **FIXED, holding** | at a real parked `human>`: `/status`, `/inbox`, `/status`-after-`/inbox`, `/nonsense` — journal 70 and `message`=2 unchanged across all four |
| F31 (`:LainReviewDone` raises out of `BufWriteCmd`) | **FIXED** | empty thread `:w` returned in **123ms**, refused in words, `nvim_get_mode()` answered, 0 tracebacks, no modal |
| F38 (mark names a content hash, not the row) | **FIXED** | `lain: marked reviewed: 1 hunk(s) of lib/bowling.rb` |
| F64 (docent parks a question and strands the pane) | **did not reproduce** | both thread questions answered directly (25s, then 5s); zero parked `message` records |
| F66 (`:LainNote` alone anchors nothing) | **CONFIRMED as documented** | anchors `<unset>` after `:LainNote`, populated only after `:LainNoteDone` |
| T6 (window resolved once and memoized) | **ABSENT** | one cold session went `8192/guessed` → `32768/probed` |
| P9/P15 (`GEM_HOME` re-locks `Gemfile.lock`) | **HELD** | md5 `f51222770364686a2cb61b9845368b05` identical before and after |
| P21 (`slot_fills` is bench-only) | **CONFIRMED** | a plain `lain chat` with an override wrote 0 `slot_fills`; the override was visible on the `session` record instead |
| round-9 `num_batch` re-keys the runner | **CONFIRMED, third direction** | `bench arms` run 1 single-thread max **27.68s**, run 2 identical suite **1.35s** — and the model was verified resident at ctx=32768 before run 1, so warming through a chat is still insufficient (round 10's refinement holds) |

---

## F79 — HIGH — a spawn whose subagent PARKS A QUESTION can be neither forked nor resumed

**What is wrong.** Once a subagent asks the human a question, both continuation doors refuse:

```
cannot fork <session>: message record 6 (message) cites a causal parent this replay never landed:
no object "blake3:369b6be6…" in store: putting "blake3:91ecab96…" would dangle
```

`--resume` gives the same sentence with its own prefix. Exit 1 from both. This is the user-visible
shape of round 5's **F23** — a spawned session stranded with no continuation path at any point in
its history — returning through the newer `message_replay` index space.

**Mechanism.** The subagent's question is journaled as a `message` record of `kind: "message"` whose
`causal_parents` names a digest that **no record in the journal carries** — not a `turn`, not a
`child_turn`, not another `message`. `Bench::Session::MessageReplay` then correctly refuses to put a
record whose parent is absent. The refusal is honest; the defect is upstream, in whatever fails to
journal the record that digest addresses.

Full record map of a minimal reproducing session (16 lines, one ordinary turn then one spawn):

```
 9 turn         digest=e901a7d72a2f56   parent=5c3d947aa30e41
10 message      digest=68f46441af8ed8   kind=spawn     cp=[e901a7d72a2f56]   <- resolves
11-15 child_turn  digests 4fd8b2c1…, 14ef7204…, fa6e4b7d…, 15e39eee…, 52dd878d…
16 message      digest=91ecab96ce76a9   kind=message   cp=[369b6be676bfd8]   <- 369b6be6 is NOWHERE
```

**Evidence ruling out the innocent explanations.**

- **Not a damaged journal.** A full edge scan over `causal_parents`, `parent`, `from`, `to`,
  `head`, `source_head`, `derived_head` on the larger reproducing session read **75 digests present,
  31 referenced, 0 missing** — healthy by `bowling-ruby.md`'s own test — and it refused anyway.
- **Not a live/open session.** Refuses identically whether the session is being written or not.
- **Not the fork point.** Forking at two digests recorded *before* the first `message` record
  refuses with the **identical** record number and digest. `bowling-ruby.md` names this exactly:
  "if a refusal moves with the fork point, it is ordinary damage and not this." It does not move.
- **Not model contamination.** First seen on a session containing a `malformed_response`
  (`kind: "prose_tool_call"`), then reproduced on a **clean** session with `malformed=0`.
- **The control works.** A closed, never-spawned session (`message=0`, 46 turns) forks *and* resumes
  at **exit 0**, reaching `you>`.
- **The SECOND control localises it to the parked question, not to spawning.** A session that
  spawned and whose subagent **returned an answer** (`message=2`, `child_turn=4`, `turn=6`) forks
  **and** resumes at exit 0. Its final `message` cites *two* parents — the spawn message and the
  last `child_turn` — and **both resolve**:

  ```
  message     digest=4164f8b5…  kind="spawn"    cp=["9bb80736…"]                 <- resolves
  child_turn  x4
  message     digest=02d5821d…  kind="message"  cp=["4164f8b5…", "9a200ca2…"]    <- both resolve
  ```

  Against the failing case, whose single cited parent is absent:

  ```
  message     digest=91ecab96…  kind="message"  cp=["369b6be6…"]                 <- nowhere in the file
  ```

  **So the defect is in how a PARKED QUESTION's `causal_parents` is built, not in spawning.** That is
  the line to fix, and it is why the answer path has never shown this.
- On the larger session both digests the refusal named *were* present (one as a `turn` **and** its
  `turn_usage`), which is the F23-proper shape; on the minimal session the cited digest is genuinely
  absent. Both refuse. The absent-digest case is the sharper one and is what the fix should target.

**Reproduction.**
```bash
lain up --socket S --session x <proj> -- --provider ollama --model qwen3-coder:30b
#   you>  What is 2+2?                     (one ordinary turn first -- else there is nothing to fork at)
#   you>  @researcher[/critique] lib/sample.rb
#   ... let the subagent park its question
lain chat --fork   "<session>.ndjson@<head>" --provider ollama --model qwen3-coder:30b < /dev/null  # exit 1
lain chat --resume "<session>.ndjson"        --provider ollama --model qwen3-coder:30b < /dev/null  # exit 1
```

**Fix shape.** Build the parked question's `causal_parents` the way the *answer* path already builds
its own — the answer's message cites the spawn message and the last `child_turn`, both journaled, and
forks cleanly. The question's `from` (a `child_turn`) already resolves; only its `causal_parents`
does not. **What
would pin it:** a spawned session in which a subagent parks a question must `--fork` and `--resume`
at exit 0, with the never-spawned session kept as the control.

## F78 — MED-HIGH — a zero-usage turn silently zeroes occupancy and compaction's input

**What is wrong.** A `turn_usage` record carrying `input_tokens: 0` overwrites the status feed's
`occupancy` with `0.0` and `Agent::Accounting#last_turn_usage` with `0`, discarding the real
reading. `last_turn_usage` is what `Agent#occupancy` divides and what compaction's `Need` consumes,
so after such a turn the loop believes the context is empty.

**Mechanism.** `status_feed.rb:307` — `@occupancy = occupancy_of(usage, event.model)` is a
**replacement**, unconditional, on every record. `agent/accounting.rb:34` — `@last_turn_usage =
response.usage.total_input_tokens`, likewise unconditional. `last_turn_usage`'s own docstring says
`nil` before any turn is "distinct from zero, **which would read as an empty context**" — the hazard
is named on the attribute and then written by the setter three lines above it.

Note `run_tokens` is an *accrual* (`+=`) and therefore survives, so the feed ends up internally
inconsistent: it remembers the tokens and forgets the occupancy.

**Evidence.** Proven directly against the real objects, no model involved:

```
after healthy turn : occupancy=0.164306640625  run_tokens=5496
after zero-usage   : occupancy=0.0             run_tokens=5496
Accounting#last_turn_usage after healthy = 5384
Accounting#last_turn_usage after zero    = 0
```

**The trigger is the uncertain half, and this is stated as inconclusive rather than as a pass.**
Observed once in the wild: a session whose final assistant turn carried **293 characters of real
reply text**, joined by digest to a `turn_usage` reading `stop_reason: "unknown", input_tokens: 0,
output_tokens: 0` — an unbilled, content-bearing turn in the experiment record, which also left the
feed at `occupancy: 0.0` beside `run_tokens: 21105`. Five further sessions of the same shape did not
reproduce it, and a mid-stream sever was cleanly **retried** rather than committed (occupancy stayed
correct at 0.162), so the retry path is not the route. What would settle it: capture the ollama wire
for a turn whose final `done:true` frame is absent or carries an unrecognised `done_reason`.

**Fix shape.** Treat a zero/absent usage as *no reading* rather than as a reading of zero — the same
distinction `last_turn_usage`'s docstring already draws for `nil`. **What would pin it:** feeding a
zero-usage `TurnUsage` after a healthy one must leave both `occupancy` and `last_turn_usage`
unchanged.

## F73 — HIGH — reproduces, unfixed (round 13)

Re-driven deliberately at close-out, having run one cockpit at a time all round to avoid it.
Two cockpits on two different projects, two project hashes, two nvim sockets:

```
nvim-2d8910f1d583.sock: 2                                  <- cockpit A answers
nvim-7d304140802b.sock: Caught deadly signal 'SIGTERM'      <- cockpit B never answered (15s timeout)
pane %3: E325-ish lines = 2
swap: lain-cockpit:%%start.swp   lain-cockpit:%%start.swo
```

Round 13's mechanism stands: `cli/up/cockpit.rb:105`'s `SCRATCH_BUFFER = "file lain-cockpit://start"`
is a constant with no project scoping, so the swap path is a constant too. Fix shape unchanged —
`noswapfile`/`buftype=nofile` on the scratch buffer, or `-n` on the pane's nvim.

## F80 — MEDIUM — `--isolation worktree` is inert in chat, and the help text stopped saying so

**What is wrong.** `lain chat --isolation worktree` launches happily, resolves a real backend, hands
it to a real `Supervisor` — and then leases nothing, because **no chat path ever spawns an
actor-mode subagent**. An operator who passes it reasonably believes their subagents' files are
isolated. They are not.

**This settles `subagents-and-backends.md` §3's open question**, which the scenario states as "one of
the two is wrong" and asks a round to decide by driving. The answer is: **the wiring is live and the
spawn path is unreachable.**

**Mechanism, all four links checked.**

- `Tools::Subagent::Input` (`subagent.rb:11-14`) declares exactly **one** field, `prompt`. There is
  no `mode` field, so the JSON Schema the model sees cannot request an actor.
- `Tools::Subagent#initialize` (`subagent.rb:58`) defaults `mode: :one_shot`.
- Both chat-side construction sites — `cli/wiring/toolset_build.rb:292` and `skill/role_spawn.rb:57`
  — pass **no `mode:`**, so both take that default.
- `#call` (`subagent.rb:167`) reaches `adopt_actor` only `if @mode == :actor`, a construction-time
  value the model cannot influence. `adopt_actor`'s own `unless supervisor.running?` guard is
  therefore never consulted from a chat.

Meanwhile `cli/wiring.rb:184` really does build
`Supervisor.new(journal: channel, isolation: fleet_isolation(channel))`. The flag is not dead
globally — `bench arms --isolation` uses the same resolver — it is dead **on the chat path**.

**Evidence.** A real cockpit on a git repo, launched `--isolation worktree`, driven with
*"spawn a long-lived actor subagent that watches for my next instruction, then tell me its handle"*:

```
git worktree list      ->  /…/actorproj 783823f [master]      (the main checkout, nothing else)
isolation_lease records ->  0
the model's actual call ->  subagent: {"prompt":"Watch for the user's next instruction."}
the tool_result         ->  "I'm ready to assist you with the next instruction."
```

The model *reported* a handle (`subagent_1715984073_123456`) in prose. That is a hallucination, not
an actor address — `adopt_actor` returns `"actor launched: #{actor.address}"` and no such string
appears. **Do not read a model-reported handle as evidence of adoption**; read `git worktree list`
and the lease records.

**The scenario's premise is stale in the worse direction.** §3 quotes the help text as saying the
flag "is inert in chat today". That wording is **gone**; the shipped text is now:

```
Isolation backend actor-mode subagents lease workers from (none, worktree);
the main chat's own session is never isolated
```

which is true about the mechanism and silent about the thing that matters — that in a chat there are
no actor-mode subagents, so the flag governs nothing. The one sentence that used to warn an operator
has been removed while the inertness stayed.

**Fix shape.** Either expose `mode` on `Subagent::Input` (with the depth/`Supervisor` guards that
already exist behind it), or say plainly in the flag's description that it takes effect only for
`bench`/actor paths and not for a chat. **What would pin it:** a chat launched `--isolation worktree`
whose spawn either produces an `isolation_lease` naming `Isolation::Worktree`, or whose `--isolation`
help text tells the operator it will not.

## F76 — LOW — reproduces (round 13)

`lain://approval` hard-wraps the command mid-token, so a substring read of that buffer can miss:

```
agent  bash({"command" => "cd /home/tara/tmp/lain-qa-round14-2026-08-27/rustcli && echo -e \"h
  ello world hello\nfoo bar foo" | ./target/debug/wordfreq -n 2"})
```

`hello` is split across the wrap. A driver matching the command by substring must anchor on a prefix.

---

## What passed, with the evidence worth keeping

**The three-place secret boundary — all three places, 11/11 on the classifier.** `denied/:protected`
for a private key; the `.pub` carve-out reads **ordinary** (a false positive there is a session-killer
with no move available, and it is absent); `.env`/`.env.local`/`server.pem` `gated/:credential`;
`~/Downloads/x` `gated/:out_of_scope` — a *different reason*, travelling whole rather than collapsed
to a Boolean. Both directions of the home-anchoring hold: `<H>/.kube/config` denied while the
innocent twin `<S>/.kube/config` is **ordinary**. `~somebodyelse/.ssh/id_rsa` denied in **0.0ms** —
string substitution, no `getpwnam` stall. The filter kept only the ordinary row
(`reasons: [:credential, :protected]`); the mask turned `AWS_SECRET_ACCESS_KEY=wJalrX…` into
`<redacted:1>` while `PORT=3000` survived.

**Tool bounds, both shapes and both control pairs.** Ceilings live at `[262144, 1048576, 131072, 500]`.
`big.txt` (3 MB, line-structured) gets "read **part** of it"; `mid.rb` (300 KB) gets the full-cover
window — *different advice*, which is the whole design. `one.json` (1.2 MB, newline-free) gets the
byte-range advice with "one line alone is over the ceiling" naming a `head -c 100000` sized *under*
`bash`'s own 128 KiB ceiling; `mid.json` (300 KB, newline-free, under `WINDOW_BOUND`) correctly keeps
the full-cover advice, so the over-reach guard holds. `bash` refused at 200000 bytes **with
`exit status: 1` surviving** and no payload bytes. `list_files` and `glob` both returned 501 rows —
500 plus `... capped at 500 of 1200 paths`.

**The iteration ceiling, all three checks, better than documented.** 25 model calls stopped the ask
(`run_interrupted reason="torn"`), it was said in one line (`error: loop ran 25 iterations, ceiling
is 25`) at **0 bytes of stderr and 0 backtrace frames** — the doc records 226 bytes as the post-fix
figure — and the resumed session answered `alive` at exit 0.

**Record integrity.** 218 lines / 0 unparseable / 0 `journal_error`. A torn `turn` advertised
**45 turns under the same head digest plus `1 line unparsed`**, then refused on use naming the
record, its role and both digests, exit 1, 0 backtrace. A dangling edge refused identically from
`--fork`, `--resume` and `bench variance`; a bad prefix refused by name. Both malformed
`causal_parents` shapes (`[nil]`, and a digest beside a `nil`) refused as `Corrupt` naming the field
and its contract — **no `Store::MissingObject` and no bare `ArgumentError` escaped**.

**The refusal rail, all three axes.** Width: `v:echospace` 88 against a 100-column pane (matching
round 9 exactly), the 231-character verdict refusal middle-elided on the message line with the full
sentence in `:messages`. Breaks: `lain: alpha / bravo` displayed folded, both lines unfolded in
`:messages`. Height: 60 lines folded to one elided line with **no `-- More --`**. No blocking, no
tracebacks anywhere.

**`bench arms`.** All four header lines correct including `isolation: unset — Arm::NoIsolation leased
nothing`; grades 0.812/0.812/0.938 with non-zero tokens for **every** arm; `cost (USD)` refused by
name rather than printing `0.000000`, with the rest of the report intact; no credential or base URL
anywhere; no `StalledStreamError`.

**`/mode !`** wrote exactly one `mode_switch` (`auto`→`plan`, layers cleared in the same record) plus
the `policy_switch` `approve_all`→`deny_all` — **no intermediate ladder** of postures the session was
never in.

**`epic status`** reported `1/5 done`, kept the abandoned `i4` in the listing, kept it **blocking**
`i5`, and every cited blocker id was findable in the listing above it — the regression §2 exists for.
Two runs byte-identical. `for_all` proved itself via a control: with `research = "deferred"` the
submit still refused on **`epic_plan`**, a stage other than the one submitted.

**The survey/changeset split.** A survey opens 2 windows and its banner says one `<C-w>l`; a
changeset opens 3 (`lain://review` │ `lain://review/OLD/f.txt` │ the live file) and says
`<C-w>l<C-w>l`. `/review-submit` on a local branch refused naming the branch and the remedy with the
**journal unchanged** — it never reached for the network.

**`survey` §7, the docent thread — held.** The answer rendered in the thread pane while `:w` returned
in **133ms** and a gesture landed in **135ms** with the answer outstanding, so nothing blocked on the
provider round trip. A second `:w` with nothing typed refused in words, journal unchanged. The
exchange journaled as `annotation_placed` → `docent_asked` (`role: "diff_docent"`) → `docent_answered`
under one `anchor_id`.

**`shell-term-approval` §1/§2, first drive, measurements confirmed.** `MAX_BYTES` 4096;
`[broken?, covered?, uncovered.size] = [true, false, 1]` on an over-cap parse — the vacuous
`covered? == true` the layer exists to prevent is absent; `call(nil)` → `[:unparseable]`, never a
`NoMethodError`. All **17** verdict rows matched, including the newline row
(`stages=2 pipes=0 separators=0`), which the scenario calls its highest-value check because it is
what stops `echo hi | rm -rf /tmp/x` reaching `Open3.pipeline`. `PROGRAM_RUNNERS.size = 92`.

**The subjects.** `rust-cli`: 5/5 tests including all three required cases, behaviour oracle exact
(`the 3` / `cat 1`), and the model recovered from a real `cargo` compile error whose rustc diagnostic
survived intact as a tool result while `lain://journal` populated 1→30 lines. `bowling-ruby`:
**5/5 oracles**, including the load-bearing oracle 4 (133) and the tenth-frame case (30, not 60).

## The second pass — what the local and metered arms reached

Driven after the first write-up, because "needs a model" is not "unreachable": the local bench runs
ollama, and the cloud arm's key is in `.envrc`.

### `rails-blog` §2 — REACHED, for the first time in thirteen rounds, and without Rails

§2's premise is **result SIZE**, and round 8 recorded it as unreached even by the scenario built for
it: largest single tool result **4,713 bytes**, 40,306 total, **zero** cap disclosures. The section
itself names the way out — "a non-minimal app, **or a directive that reads large generated files
back**" — so a tree of generated files served instead of a Rails install:

```
  120045 bytes  bash          cap-disclosed=no
    4039 bytes  read_file     cap-disclosed=no
     350 bytes  list_files    cap-disclosed=no
      13 bytes  list_files    cap-disclosed=no
TOTAL: 4 results, 124,447 bytes
```

**120,045 bytes in one result — 25x round 8's largest-ever**, and *admitted* rather than refused
because it sits just under `bash`'s 131,072 ceiling, which is exactly the volume this section wanted.
No admitted result disclosed a cap, correctly: none exceeded its tool's bound. Driving a tool that
**does** cap-and-disclose confirms the other half — `grep` over ~2,400 matches returned 9,161 bytes
ending `... capped at 200 matches`.

So §2's question is answered: the bounding tools bound and say so; the non-bounding ones pass a large
result through whole, and 120 KB reaching the model with no disclosure is correct behaviour rather
than a leak. **This does not discharge §1** — round 13 did that — and it does not need Rails.

### `subagents-and-backends` — §1 and §2 driven, §3 settled as F80

§1's launch refusals all land, exit 1, zero backtrace: `unknown isolation backend "worktre",
expected one of ["none", "worktree"]`; a `NotARepository` naming the root, the boundary
(`/home/tara (home)`), the reason **and two remedies**; `unknown exec backend "dokcer"`. **`--exec
core` is refused by name and does not advertise itself as available** — the check that matters, since
`Exec::Core` is a real backend that a flag cannot hand a started client to. The docker client is on
this box, so the `Unavailable` arm was not reachable; recorded, not claimed.

§2's `one_shot` spawn answered correctly (3 ruby files, which is what the tree held), `spawned_from`
resolved, and the causal scan read **MISSING=0**. That session is what localised F79.

### `memory-and-dogfood` — §1, §2, §4, §5, §6

**§1 is the cost check and it passes.** The manifest rides `Workspace` as context, carrying one id
and one description per item and **no bodies**:

```
<workspace>Memory manifest, one "id | description" per item (call memory_read with an id to open its body):
suite | Test suite command
tmpdir | TMPDIR requirement
toolchain | Ruby version requirement for the project</workspace>
```

None of the three bodies appears. §2: `memory_read` and `memory_write` bounds are **equal** at
262,144, asserted rather than remembered. §6: `bench sweep` ran the offline five-arm recall@5 — vector
0.667, graph 0.438, bm25/hybrid/manifest 0.333 over 12 queries and 32 items — and was **byte-identical
across two runs**. §4: `consolidate --dry-run` correctly reported `no completed subagent lineages
found`. §5: `improve --dry-run` produced a real friction report naming an actionable signal
(`memory_write selected 21.00x its declared share`) and a `cache_waste` line that **refuses to quote a
saving** and says why — naming the `prompt_caching` degradation, the 7 priced calls with no cache to
serve, and that the dollars exclude `qwen3-coder:30b` because no price is recorded. That is the
honest-refusal shape working on the dogfood path.

### `ollama-cloud-arm` — §1–§4, one completion spent

**§1's refusals are the best-written in the round.** The missing-key one names the variable, **where
to get a key**, **which flag asked for it**, and the tmux-environment hint — all four:

```
OLLAMA_API_KEY is not set; Ollama Cloud needs an API key. Create one at
https://ollama.com/settings/keys; --provider ollama-cloud is what asked for it -- looked for in the
environment this pre-flight ran in, which is not the one a tmux server started elsewhere hands its
panes; export it here, or start that server from a shell that has it
```

The plaintext refusal argues in the arm's own terms — *"a subscription key sent in plaintext is an
exfiltrated key"* — and offers two remedies. The third case **constructs**, confirming the document's
corrected prediction that a non-chat tier resolves its own deployment's base rather than inheriting
`--api-base`. §2 constructs likewise, so a `gpu.internal` chat base does not capture the cloud
summarizer.

**§3 passes on one completion:** `window=128000 provenance="published"` — not the 8,192
`CONSERVATIVE_FALLBACK` tagged `guessed`, which would under-report occupancy ~16x *and* silently
disable `:approaching_window` compaction. `stop=end_turn in=3324 out=76 model=gpt-oss:20b-cloud`.
**The key appears nowhere in the journal**, checked before and after the paid turn.

**§4, 5 of 23 rows checked against `/api/show`** — sampled across families and including two 1M
claimants, per the section's warning not to sample one tag per family:

| row | table | `/api/show` |
|---|---:|---:|
| `gpt-oss:20b-cloud` | 128,000 | 131,072 |
| `gpt-oss:120b-cloud` | 128,000 | 131,072 |
| `deepseek-v4-pro:cloud` | 1,000,000 | 1,048,576 |
| `kimi-k3:cloud` | 1,000,000 | 1,048,576 |
| `glm-5.2:cloud` | 976,000 | 1,048,576 |

Every sampled row is **at or below** the weights, so the over-claim regression §4 was written about
(three rows, one by 3.8x) is absent on these five. Under-claiming errs safely — a conservative
denominator over-reports occupancy and compacts sooner. **18 rows were not checked**; this is a
sample, not a clearance of the table.

## Withdrawn before filing

- **"Streaming floods the surfaces past the bash bound."** The pane took ~2000 rows of `x`s, but
  `lain://journal` held **49 lines** and the NDJSON journal **0** `tool_output` bytes. Both durable
  surfaces are bounded; only the tmux alternate screen took the raw bytes, which is what live
  streaming is for.
- **"`request_sent.model` is always nil."** `RequestSent` is
  `Data.define(:digest, :payload, :stream, :extra, :prefix_digests, :prefix_chain_version)` — there
  is no `model` member. I was reading a key that does not exist.
- **"`compaction` records lose their strategy and trigger."** They carry
  `trigger: ["plan_step_completion"]` and `collapse_strategy: "eager"`; I probed the wrong key names.
- **"The HUD shows `idle` at a parked `human>` when it should elide."** Context-dependent and both
  behaviours are correct: a `/create-plan` spawn elided it (parent still dispatching), a
  `@researcher[/critique]` spawn showed `fleet 1 idle 6s` (parent genuinely idle). §7's stated
  assertion passed; `method.md`'s explanatory note describes the second case only.
- **"A lowercase `blocks:` link line is silently dropped from an epic."** It becomes description
  text, which is right — only capitalised kinds are link lines, and an unrecognised capitalised kind
  refuses by name with its line number and the writable set.

## Model behaviour — not lain defects

- **`<function=` as literal assistant text fired again**, on the `/create-plan` session (5
  occurrences). **New and worth recording: lain now DETECTS it** and journals
  `malformed_response {kind: "prose_tool_call", tool_name: "list_files", excerpt: …}`. Round 4 had no
  such record. The restart rule still applies — that session was abandoned.
- **`/create-plan` failed on the model, as `bowling-ruby.md` predicts.** It spawned researchers that
  looped on clarifying questions to `fleet 3` without writing a file. The implementation was driven
  with a direct prompt instead and scored 5/5.
- **`--prompt hi` regularly burns 16–19 iterations** on `ask_human`/`todo_write` loops before
  answering. Harmless, but it makes "one trivial turn" an unreliable unit of cost.
- The model emitted a **truncated sandbox path** (`lain-qa-round14-2026`, the date cut short) in a
  `bash` call. The allow-list gate refused it correctly; a deny-list would have waved it through,
  which is P8's point restated with a live example.

## What was NOT reached, and why

Named rather than left to look like coverage. The round drove **11 of 17** scenarios in whole or
substantial part; six were not driven at all.

| scenario | reached |
|---|---|
| `session-and-window` | **complete** — §1–§8, all three occupancy readers cross-checked and agreeing |
| `rust-cli` | **complete**, including the compile-error unhappy path |
| `failure-injection` | §1, §2, §3 (+ both malformed shapes), §7, §8 both shapes. **Not** §4, §6, §9–§12 |
| `cockpit-surfaces` | §1, §2, §3, §4 (full review flow), §7, approval surfaces. **Not** §4b's note rail on a survey, §6, §8 (fold state) |
| `bowling-ruby` | §1 (model-failed as predicted), §2's wedge (→ F79), §3 graded 5/5 |
| `bench-arms` | **complete**, with the warm control |
| `repl-commands` | §0, §1, §2, the `/mode !` reset, §6's sanctioned `auto`. **Not** §3–§5, §7, §8 |
| `epic-tier` | §0, §2, §3 (+ `for_all`). **Not** §1, §4–§8. **§9 is unreachable headless** — every gate policy needs an `asker`, so no `gate_decision` can be parked from a non-interactive CLI, and the fold-abort check cannot be set up without one. That is a real limitation of the scenario as written, not a skip |
| `survey` | §1, §2, §7 (the four-round docent debt, held). **Not** §3–§6, §8 |
| `changeset-review` | §0–§3, §5, §7. **Not** §4, §6, §8 |
| `secret-boundary` | §1 (11/11), §1b, §1c, and both remaining places of the split. **Not** §2, §5, §6, §7 |
| `prompt-slots-and-roles` | §1–§5 and §6's free half. **§6's paid half NOT reached — no `ANTHROPIC_API_KEY` on this box.** The free half settled the byte count (364 bytes ≈ 91 tokens against a 4096 floor); it does **not** stand in for the wire behaviour |
| `shell-term-approval` | §1, §2, §2a — the drivable-now core. **Not** §0, §3–§5, §11; §6–§10 are blocked on the chunk landing |
| `subagents-and-backends` | §1, §2, and §3 **settled** (→ F80). **Not** §4 (`--exec docker` end to end), §5 (`lain watch`), §6 (`--windows`) |
| `memory-and-dogfood` | §1, §2, §4, §5, §6. **Not** §3's full chain walk, §7 |
| `rails-blog` | **§2 REACHED for the first time in thirteen rounds**, without Rails. §1 stays discharged by round 13. **Not** §0, §3, §4, §5 — those need the Rails install this round did not do |
| `ollama-cloud-arm` | §1, §2, §3, §4 (5 of 23 rows). **1 completion spent** of the under-ten budget. **Not** §5's WAL, §6's 429, §7 |

**Every scenario in the directory was driven at least in part.** The first write-up of this round
listed four as "not driven"; that was wrong, and the correction is worth recording as a lesson rather
than quietly patched. Three of them (`subagents-and-backends`, `memory-and-dogfood`, `rails-blog`)
run on the **local** bench that was already up, and the fourth (`ollama-cloud-arm`) needed a key that
was sitting in `.envrc`. The driver had conflated "this scenario spends model calls" with "this
scenario is out of reach", and stopped one question short of asking what the bench in front of it
could already do.

The residue is honest and small: `prompt-slots` §6's paid half (no `ANTHROPIC_API_KEY` anywhere on
this box), `epic-tier` §9 (structurally unreachable headless), the Rails-dependent half of
`rails-blog`, and the later sections listed above. Those are the places to start next round.

## What the round changed in the method

Folded back, as the skill requires:

- **The skill no longer hard-codes the scenario set.** `.claude/skills/manual-qa/SKILL.md` Phase 1
  now takes the directory listing as the authority, with no counts or names baked in, and with no
  scope named the round drives **every** scenario in it. The tiers survive as ordering and budgeting
  guidance, explicitly not as a filter. The "owned rounds need a second invocation I cannot start"
  language is gone — that convention is what let scenarios slip round after round.
- **`planning/qa/README.md`** was rewritten to match, keeping the reasoning about which scenarios
  bring up their own subject as *sequencing* guidance.
- **`planning/qa/scenarios/shell-term-approval.md` is new** (17th scenario), written because the
  shell subsystem had none and the draft chunk's own card T10 for it was never executed. It is
  explicit about which sections are drivable today and which wait on `chunk-shell-term-approval.md`
  landing — §1/§2/§2a were driven this round and their measured tables confirmed.

### P29 — "unreachable" was asserted, not checked, and the guard now lives in three places

The round's own worst process error. Four scenarios were written up as "not driven" on a capability
reason that was false: `subagents-and-backends`, `memory-and-dogfood` and `rails-blog` all drive
against the **local ollama bench that was already up and warm**, and `ollama-cloud-arm`'s
`OLLAMA_API_KEY` was in the repo's own `.envrc`. The driver had conflated *"spends model calls"* with
*"out of reach"*. A single question from the operator produced a second pass that drove all four,
including `rails-blog` §2 — unreached in thirteen rounds.

**Why it matters more than a missed scenario:** a scenario written off as unreachable stops being a
gap anyone can see, which is precisely the failure the "dropping a scenario is a decision" rule
already exists to prevent — arriving by a different door. And Phase 5's own wording helped: it
blesses "ran out of budget" as an acceptable reason, which made *any* stated reason feel sufficient.

**Folded back into all three durable documents, because a findings file is discharged and deleted
while these are not:**

- **`SKILL.md` Phase 5** — a reason of the form "it needs X" is a **claim you check before writing**,
  with the three commands that check it, and the statement that the bench already up is the default
  answer. A local model call is a budget cost, not a capability gap.
- **`method.md`** — a new standing section, *"Unreachable is a claim about the bench, and it is
  checked, not assumed"*, splitting budget (free to assert) from capability (must be established),
  with the checks; plus the generalisation that **a scenario's stated subject is usually one way to
  satisfy its premise, not the only one** — which is how §2 was reached with no Rails.
- **`README.md`** — the coverage note claiming §2 unreached is corrected in place rather than left to
  send the next round looking for a Rails install it does not need.

The one gap that survived the second pass is stated the way the new rule asks: `prompt-slots` §6's
paid half needs `ANTHROPIC_API_KEY`, which is on no shell and in no `.envrc` on this box — checked,
not assumed.

### P24 — `repl-commands.md` §0's fallthrough expectation is wrong

The scenario says an unregistered `/word` "must reach the model as prose, **not** produce an
'unknown command' error". Measured with a control: `/nosuchcommand please just say hello` produces
`unknown skill "nosuchcommand", expected one of […]` with the journal **unchanged** (55→55), while
bare prose reaches the model (55→62, answered `Hello!`). `spec/lain/middleware/skill_dispatch_spec.rb:103`
pins the current behaviour by name — *"an unknown skill is reported, not sent to the model"* — so the
**document is stale, not lain**, and the loud refusal is the better behaviour by this codebase's own
lights. Correct §0.

### P25 — `survey.md` §2's corpus figure is stale

The table says `lib` is 742 files; `git ls-files --cached --others --exclude-standard` now reads
**748**, and the refusal correctly reported 748 against the ceiling of 300. The mechanism is right;
the number aged. Re-measure figures in that table when driving it.

### P26 — `cockpit-surfaces.md` §4 quotes the wrong banner for its own example

§4 says "`/survey ./lib` — a **subdirectory** survey" and then quotes the `<C-w>l<C-w>l` banner and
"the slots are sidebar, OLD, NEW". Measured: a **survey** opens 2 windows and its banner says one
`<C-w>l`; the two-motion, three-window form is the **changeset** case. Both behaviours are correct —
the banner adapts — but a driver following §4 over a survey will count the wrong windows.

### P27 — the new scenario shipped with a NUL byte

`shell-term-approval.md` was written with a *literal* NUL inside a probe documenting NUL handling,
which made the file `data` rather than text and broke `grep`, `git diff` and every text tool a driver
reads it with. Fixed in place by spelling it `$(printf \x00)`. Worth a standing note: a scenario that
documents a control character must spell it as an escape the shell expands, never embed it.

### P28 — a two-round-old leak in the checkout, hidden by P16's own noise

`not/absolute/.local/state/nvim/nvim.log` and `.local/state/nvim/nvim.log` sit in the lain checkout,
both dated **2026-08-23 19:08** — four days before this round, so round 11 or 12 left them. They are
empty nvim logs created by an `XDG_STATE_HOME` given a **relative** value: one literally
`not/absolute` (a fixture testing `Paths#present`'s "a non-absolute value is treated as unset" rule),
one `.local/state`. nvim then resolved its log directory against the process cwd, which was the
checkout.

**Why two rounds of close-out missed them, and this is the part worth keeping.** They are *not*
gitignored — `git check-ignore` matches no rule — so `git status --porcelain` shows them plainly. But
`method.md`'s P16 warns that running that check in a shell which has sourced the sandbox env produces
false positives, because a redirected `XDG_CONFIG_HOME` hides git's global ignore. What P16 does not
say, and what this round found by hitting it, is the consequence: **those false positives camouflage
true ones.** Run in the sandbox shell, this round's diff showed six real entries buried among
`.envrc`, `.claude/settings.local.json`, `.local/`, `not/` and two `references/papers` paths — and a
driver scanning that list reasonably writes the whole tail off as "P16 again". Re-run clean, the diff
is exactly six lines and every one is deliberate.

**So the close-out rule needs its second half stated:** take the baseline in a clean shell *and*
compare in a clean shell, and never triage the diff by eye against a remembered list of P16's usual
suspects. The three negatives are only as good as the shell they run in.

Left in place rather than deleted — they are another round's artifact, not this one's, and the
operator should decide. Removing them is `rm -rf not .local` from the checkout root.

### The `pgrep -f` self-kill trap did not fire

For the first time in several rounds. `ps -eo pid,args | command grep '[l]ain-cockpit://start'` was
used throughout, per round 13's recipe. One near-miss of a different kind: a helper script run
without `$QA` exported ran `tmux -L "" kill-server`, which targeted the **default** tmux socket
rather than the round's. It errored harmlessly (`/tmp/tmux-1000` is a directory), but on a box where
the operator had a default-socket server it would have killed it. Driver scripts should refuse on an
unset `$QA_SOCK` rather than passing an empty `-L`.

## Close-out

| check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-08-27T10:35:20Z'` | **0** |
| positive control, `-newermt '2026-08-01'` | **7364** (so the 0 is evidence, not a mis-spelled timestamp) |
| `git -C /home/tara/dev/lain status --porcelain` vs the pre-act-0 baseline | two diffs, **both deliberate**: `SKILL.md` and the new scenario |
| `ls -d /home/tara/dev/lain/.lain` | absent |
| `Gemfile.lock` md5 | `f51222770364686a2cb61b9845368b05`, identical to baseline |
| `dunstctl count displayed` / `waiting` | **0 / 0** — the whole round ran with `LAIN_DESKTOP=0` verified in every pane, and approvals are `-u critical` so any that fired would still be on screen |
| QA tmux server, stray `lain` processes | killed / none |

Preconditions recorded: `qwen3-coder:30b` on the `/mnt/nvme` ollama 0.32.12,
`OLLAMA_CONTEXT_LENGTH=32768`, `OLLAMA_KEEP_ALIVE=5m`, runner `-c 32768 -b 2048 -ub 2048`,
**`-np 1` — so `n_slots` is 1** and every contention reading in the scenarios remains valid.
Machine quiet at bring-up: 92.4% idle, **no orphaned spinners** (the first clean gate in four
rounds). nvim 0.12.4, above the stated 0.11 minimum. The sandbox is left in place at
`~/tmp/lain-qa-round14-2026-08-27` (41 MB) as evidence.
