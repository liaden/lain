# QA round 19 — 2026-09-21

## Summary

A full round over **all eighteen** scenarios in `planning/qa/scenarios/`, driven in ten contexts
(the spine here, nine forks with their own sandboxes). **Every scenario was driven; none was
dropped.** Two sections that had been owed for several rounds were reached: `survey` §7 (the docent
thread pane, dropped by three consecutive rounds) and `rails-blog` §1b, whose over-window handoff
was driven end to end for apparently the first time.

**The round's headline is one defect found independently by four contexts: the ollama arm never puts
a generation cap on the wire.** `max_tokens` is journaled and never sent; `num_predict` does not
occur anywhere in `lib/`. Measured consequence: a single task decoded **85,150 tokens against a
declared 4,096** and kept generating ~13 minutes after its client process was killed. With
`n_slots = 1` it starves every other session on the box, and nothing times it out — the stall clock
arms on silence, so a pre-first-byte starve is exempt by construction. It is the direct cause of
this round's 450 s waits, and of one context's 846 s zero-byte turn.

Three other HIGHs: an ordinary-named **symlink** inside the project root pointing at a `gated` file
is auto-approved with nobody asked (round 18's F131 one route further on); `lain chat --root PATH`
is silently ignored, so a project's `.lain/slots/` never loads; and a detected `malformed_response`
is a **silent write-off delivered as a successful result** — lain journals the malformed call, then
hands the raw `<function=…>` envelope back as the child's answer, because the record has no consumer
anywhere in `lib/`.

**What is in good shape.** `session-and-window` passed on every one of its twelve sections. The
approval ladder, the review flow, the refusal rail and the nvim-first cockpit surfaces all held
exactly as documented, including every refusal's *delivery* (zero `stack traceback` at any site).
F173 is fixed and the handoff fallback works. The bowling subject scored **5/5 oracles on the
model's first attempt**, including the load-bearing oracle 4.

**No wall-clock figure in this round is a measurement.** `n_slots = 1`, `OLLAMA_NUM_PARALLEL:1`,
and up to ~15 concurrent `exe/lain` processes; three contexts independently measured multi-minute
waits against a *resident* model. Only the `bench arms` run at the very end had the box to itself.

| id | sev | what |
|---|---|---|
| **Ff-1 / Fv-1** | **HIGH** | the ollama arm sends neither `max_tokens` nor `options.num_predict`, so generation is uncapped; the journal records a 4096 cap that was never sent |
| **Fs-1** | **HIGH** | an in-root symlink under an ordinary name is auto-approved by `ComposedTerm`, releasing a `gated` file's bytes with no human asked |
| **Fv-2** | **HIGH** | `lain chat --root PATH` is ignored: `.lain/slots/` never loads and sessions file under the cwd-detected root |
| **Fp-1** | **HIGH** | a detected `malformed_response` is a silent write-off delivered as a successful result; the record has zero consumers in `lib/` |
| **Fm-1** | **MED-HIGH** | `lain consolidate` reports a successful pass over a recorder root that provably did not move (F134 half-reproduces) |
| **Fx-1** | **MED-HIGH** | a `plan`-scope write wedges `/undo` for the rest of the session — lain's own leased spike is classified `outside_root` |
| **Fk-1** | **MED-HIGH** | a credential typed at `you>` is written verbatim to `lain/history` *after* the user is told "nothing was written" |
| **Fv-3** | **MED-HIGH** | a running child cannot be stopped: `/stop` answers `no ask is running` beside a fleet row reading `running` |
| **Fp-3** | **MED-HIGH** | one task hitting the iteration ceiling aborts the whole `bench arms` run — 13 completed grades discarded, no report, 11 locked worktrees left |
| Ff-2 | MEDIUM | a `message` record missing a required key escapes every door as a raw `KeyError` with 19 frames instead of `Corrupt` |
| Ff-3 | MEDIUM | when chat *and* input panes both die only the chat corpse is reported, and the advice leads to a keyboard-less cockpit |
| Fb-1 | MEDIUM | the session header records `compact_fallback` but never `compact_strategy`; `bench variance` has no strategy guard |
| Fr-1 | MEDIUM | `summary_hits`/`summary_misses` cannot distinguish a healthy under-threshold run from a dead summarizer |
| Fm-2 | MEDIUM | the consolidate path does not detect a prose tool call the chat path journals for identical bytes |
| Fp-2 | MEDIUM (UX) | a tmux layout change erases the input pane's HUD row; nothing repaints it until the next ask |
| Fc-2 | LOW-MED | `/review` with a detached editor prints three gestures against a buffer that cannot exist, then contradicts itself |
| Fv-4 | LOW-MED | two different path bases on adjacent surfaces |
| Fr-2 | LOW | a non-zero command exit yields `is_error: false`, so the standard "what failed" reduction misses every failing `bash` |
| Fk-4, Fv-5, Fv-6, Fx-2, Fx-3, Fm-3…7, Fs-3…5, Ff-4 | LOW | wording, stale doc constants, and instrument drift — itemised in the per-context files |

Full per-finding detail, with mechanisms and reproductions, is in
`~/tmp/lain-qa-2026-09-21/records/` (one file per context, 2,868 lines). This file carries the
round-level result.

## Round-18 defects re-checked

| id | verdict | evidence |
|---|---|---|
| F173 | **FIXED** | `rails-blog` §1b reached end to end: crossed at 34,129 tokens against a 32,768 window, one `compaction_cut kind=handoff`, ask **answered**, no `run_interrupted`. Reproduced F173's exact precondition (`head_bytes: 2` on all thirteen decisions) and the handoff rescued it |
| F136 | **not reproduced** | `provenance: "probed"` from the first decision |
| F134 | **half fixed** | it now *finds* lineages (F98 stays fixed) but stores nothing: store 1 line before and after, both `memory_root` records carrying an identical root → **Fm-1** |
| F131 | **inconclusive** | the ordinary-name case parks correctly under `checkout ask`; its `ComposedTerm` arm is the symlink route, filed as **Fs-1** |
| F137 | **inconclusive** | 5 spawns, 5 completions, nothing dangling, fleet back to 0 — but all five *succeeded*, so the failed-child path is untested |
| F132, F135 | **not driven** | out of the driving context's sections; budget |
| F154 | superseded | the flag band now carries `num_batch` to non-chat commands; only 3 runner reloads all round, one of them a required control |
| F16, F58, F90, F91, F92, F93, F98, F104, F112, F117, F118, F121, F123, F125, F126, F128, F63, F31, F56, F64→, F66, F67, F68, F97, F108, T6, T10/F34, T16/F22, F38, F23 | **FIXED / hold** | each driven this round; itemised in the per-context files |
| F64 | **not reproduced** | zero parked questions; recorded as not-reproduced rather than fixed, since this round's stall symptom came from Ff-1 |
| F17 | **not reproduced** | views moved across three separate asks (`timeline` 2→6, `request` 560→607, `diff` 560→43) |

## The four HIGHs

### Ff-1 / Fv-1 — the ollama arm sends no generation cap

`Provider::Ollama::Encoding#encode` (`provider/ollama/encoding.rb:64-68`) never reads
`request.max_tokens`; `SAMPLER_KEYS` (`:35`) has no `num_predict`; `num_predict` occurs **zero
times in all of `lib/`**. `anthropic_encoding.rb:105` *does* send it, so this is an arm asymmetry,
not a policy.

The captured `POST /api/chat` body carries keys
`["messages","model","options","stream","tools","truncate"]` with `options` = `{"num_batch"=>2048}`
— no cap of any kind — while the matching `request_sent` records `"max_tokens" => 4096`.

**Evidence against the innocent explanations.** Not a journal-only omission: the whole body was
captured off the wire by a listener. Not a broken encoder: `num_batch` is present, and
`truncate=false` shows F90's fix on the same wire. Not ollama capping anyway: one task decoded
85,150 tokens, passing the whole 32,768 context and releasing at `truncated = 1`. Not contention:
15 tasks launched / 14 completed, exactly one in flight, model `RESIDENT ctx=32768`, a single
`-b 2048` start and no thrash.

**It composes into an unbounded cross-session stall.** The stall clock arms on the first tick, so a
pre-first-byte starve is exempt by design; one context's turn sat **846 s with zero bytes and no
tear-down**, another **4 m 09 s** against a resident model before `Faraday::TimeoutError`. A
runaway also outlived its own client by ~13 minutes. Every other encode decision in that file
carries a written rationale; `max_tokens` carries none, which suggests omission rather than choice.

*Fix shape:* map `max_tokens` to `options.num_predict` in the ollama encoder. What would pin it: a
spec asserting the encoded body carries the cap, and a cross-arm spec asserting both encoders agree
on which request fields survive.

### Fs-1 — an in-root symlink under an ordinary name is auto-approved

`ComposedTerm` approves a read of `readme2.txt` — an ordinary-looking name that is a symlink to a
`gated` file — **with nobody asked**. `ordinary_words?` classifies the literal word, because
`Sensitivity` makes no syscall by contract (`sensitivity.rb:17`), while `confined?` in the same
object *does* `realpath` (`board_build.rb:430`). So an out-of-root link is caught and an in-root one
is not; the only remaining backstop is `plain_content?`, which needs `Regions` to recognise the
bytes.

Four rows in one `/ruby` call, with controls both ways: `.env.local` (gated) → abstains;
`readme2.txt` (symlink to it) → **APPROVED**; `secrets.txt` (ordinary name, `API_KEY=` content) →
abstains; `README.md` → approved.

The lexical hole is documented — but every reason `sensitivity.rb:21-27` gives is about the
*read-refusal* path ("costs one prompt"). `ComposedTerm` is a round-18 rung that **approves**, and
`shell-terms` §7's negative-control table has no symlink row.

### Fv-2 — `lain chat --root PATH` is ignored

Its own help says *"Treat PATH as this run's project root, instead of detecting one by walking up
from the working directory"*. Paired runs differing only in cwd, both passing `--root`, are
byte-identical: from outside the project, its `.lain/slots/system.md` override is **absent** from
`session.system`, and the session files under the hash of the *cwd's* root. Passing `--cwd` as well
changes nothing.

Mechanism: `cli/backend.rb:484` calls `Skill::Library.load` with no `root:`, so it defaults to
`Dir.pwd`. Side effect: every `UnknownSlot` typo refusal silently does not run, which is the
mechanism `prompt-slots-and-roles` exists to guard. This contradicts CLAUDE.md's "root is the
authority boundary (what `.lain/` governs)". `lain up`'s positional form works.

### Fp-1 — a detected malformed response is a silent write-off delivered as a result

lain now **detects** the local model emitting a tool call as prose, and journals it — new this round
and a genuine improvement:

```json
{"type":"malformed_response","kind":"prose_tool_call","model":"qwen3-coder:30b",
 "tool_name":"read_file","excerpt":"<function=read_file>\n<parameter=path>\nlib/bowling.rb\n…"}
```

It then returns the raw envelope to the parent **as the child's answer**:
`{"lifecycle":"stopped","result":"I'll review the bowling.rb file… <function=read_file>…</tool_call>"}`.

`Telemetry::MalformedResponse` has **zero consumers in `lib/`** — `grep -rn` finds only the producer
(`provider/ollama/decoding.rb:101`) and an unrelated doc reference. With no `tool_calls`,
`decoding.rb:153-160` returns `END_TURN`, which `agent/loop_machine.rb:46` maps to the **healthy**
arm; the prose becomes a text block (`decoding.rb:119-122`), `Response#text` joins it, and
`tools/subagent.rb:256` returns it as `Tool::Result.ok(...)`.

The detector's refusal to repair is deliberate and documented (`decoding.rb:86-95`), and
`telemetry/malformed_response.rb:22-27` states the consequence in writing — "the ask is a silent
write-off". **The defect is that nothing above the detector owns the record.**

*Evidence against the innocent explanation:* lain parsed the envelope well enough to name
`tool_name: "read_file"`, so it had what it needed to fail the ask by name; the parent chain stayed
clean (0 assistant turns containing `<function=`) and the session worked normally afterwards. The
human's `/critique` was answered with a tool call presented as a critique.

*Fix shape:* give the record a consumer — a `prose_tool_call` should reach `LoopMachine`'s `:failed`
arm, and a one-shot whose only output was a malformed envelope should complete `lifecycle: "failed"`
with no `"result"`, which the fleet already renders as `failed`
(`status_feed/fleet.rb:178-182`).

## Fp-3 — MED-HIGH — one task hitting the iteration ceiling aborts the whole `bench arms` run

Driven at the very end of the round with the box to itself (99.2% idle, model resident at
ctx=32768, 2 stray `exe/lain` processes) — the round's only clean measurement conditions:

```bash
lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b \
  --cheap-model qwen3:4b --isolation worktree --journal "$QA/records/arms.ndjson"
```

After 2 m 36 s it **exited 1** with a single line and produced **no report at all** — the report
file is 38 bytes and holds only:

```
loop ran 25 iterations, ceiling is 25
```

**What was lost.** The journal shows the run had already graded **13** tasks
(`grade_record: 13`, `isolation_lease: 30`, `capability_degraded: 4`) out of 32 (4 arms × 8 tasks).
None of that reaches the operator: no grade table, no token ledger, no cost column, and no
attribution header — which is to say every single thing `bench-arms.md` exists to check.

**Why this is a defect and not the ceiling working.** T14's whole point is that the iteration
ceiling bounds **one ask** and is survivable — `method.md`: "the check is not 'did it stop' but
'did it say so, and did the session survive saying it'". A task is one ask. One task looping should
end that task with a low grade and let the driver continue; instead it is fatal to the run.

**Evidence against the nearest innocent explanations.** Not a crash: exit 1, one clean line, zero
backtrace frames. Not "nothing ran": 13 `grade_record`s are in the journal. Not bad flags: all four
pre-spend refusals passed first (below), and the run got 2 m 36 s in. Not contention: the box was
idle and the model resident.

**A second observation, separable:** the process left **11 worktrees `locked`** behind —
two under `worktrees/<hash>/` and nine under `worktrees/<hash>/retained/`. The `retained/` path
reads deliberate (a post-mortem affordance); the two outside it do not, and nothing released them
on the abort path.

*Fix shape:* catch the ceiling at the task boundary in the arm driver, grade the task as failed and
continue; print the report over whatever completed. What would pin it: a spec driving one task to
the ceiling and asserting the report still renders every arm.

**The pre-spend refusals all passed**, exit 1 with zero frames, each naming its remedy: the tool
floor without `--isolation`/`--journal`; `--journal` without `--isolation`; no `--cheap-model` on a
non-Claude model (**F110's fix holds** — it now names the flag rather than a Ruby method argument);
and `--cheap-model` equal to `--model`. `--provider` resolution also holds — with `LAIN_PROVIDER`
scrubbed, an unnamed provider resolves to `anthropic` and refuses
`ANTHROPIC_API_KEY is not set` (see **P-5**: unscrubbed, the sandbox inherits it and this check
silently passes for the wrong reason).

## Inconclusive — recorded as inconclusive, not as a pass

**`/stop` may not stop the loop when a call is parked.** Once, at 11:44:57Z, `/stop` journaled
`run_interrupted reason="stopped"` and printed *"the ask was stopped -- the session is still open"*,
and **18 ms later** a `request_sent` appeared, followed by four more, five new turns, and a fresh
`approval_pending` at 11:45:15Z. The queue explanation is ruled out — the last assistant turn held
exactly one `tool_use` block, and those were new model calls.

**Two controlled reproductions failed to reproduce it**: `/stop` at a parked approval with no
children, and again with ended children in the fleet, each gave 0 new `request_sent` over 90 s, a
cleared approval and a prompt back at `you>`. So the honest verdict is inconclusive.

What would settle it: the state at 11:44:57 that neither reproduction recreated was a *live* child
mid-dispatch (the fleet then showed three children and `+1 more`). Drive `/stop` while a child is
genuinely running rather than ended — which is also the state **Fv-3** reports as unstoppable, so
the two are probably one defect.

## Model behaviour — not lain defects

- `qwen3-coder:30b` emitted a prose tool call on the **first substantive ask of a clean session**
  (corroborating round 8's overturning of the "only when contaminated" theory). lain now detects it;
  what it does next is **Fp-1**.
- The model looped on test-running: after writing a correct `bowling.rb` it asked to run
  `rspec spec/bowling_spec.rb`, `ruby test_bowling.rb`, `ruby debug_bowling.rb` in turn against files
  it had not created.
- It did **not** need the `/create-plan` fallback this round — a directive ask produced a 5/5
  artifact in one turn.

## Process notes

- **P-1 (HIGH, bench).** `method.md`'s sanctioned recipe for clearing cockpit nvims is **box-wide**
  and unscoped. One context ran it at 07:13:59 and **killed six sandboxes' cockpits at once** — the
  driver identified itself unprompted, and the signature is decisive: six of seven sandboxes lost
  *only* their nvim (9–15 MB) while every `lain chat` ruby and the 310 MB `llama-server` survived, a
  pattern the OOM killer cannot produce. In a round with parallel forks — 17, 18 and 19 all — this
  recipe is destructive, and any "nvim RPC refused / cockpit wedged" finding from a parallel round
  is suspect. Scope it with `command grep -F "$XDG_RUNTIME_DIR"` after the non-destructive
  stale-socket probe.
- **P-2 (MEDIUM, bench), found independently by five contexts.** `drive.sh`/`peek.sh` cannot drive a
  **stock** cockpit: `panes.sh`'s `qa_is_lain` matches `lain input` as well as `lain chat`, so every
  `lain up` is ambiguous and both helpers refuse. Worse, pinning the *chat* pane swallows the send
  silently — the text never reaches the rail, the journal never moves, and `drive.sh` reports an
  ordinary `[journal N -> N lines in 60s]` success. `lain up` already records
  `@lain_chat_pane`/`@lain_input_pane`/`@lain_editor_pane` as session options (`cli/up.rb:348`); the
  helpers should read those. One-line fix.
- **P-3 (MEDIUM, bench).** `$QA/answer.sh:13` is `[ "$1" = deny ] && cmd=LainDeny` — every other
  argument selects **approve**, so `n`, `N` and `no` all approve silently. It failed in the
  permissive direction during `secret-boundary` and released a private key the driver had refused,
  one step from a false HIGH. This is a gate helper; it must fail closed.
- **P-4 (MEDIUM, bench).** The documented capability check
  `command grep -nE '^…export…(KEY|TOKEN)' .envrc` **prints the key's value**, despite `method.md`
  labelling it "names only -- NEVER print a value". It leaked `OLLAMA_API_KEY` into three contexts'
  transcripts. Use `-cE`, or `| cut -d= -f1`.
- **P-5 (MEDIUM, bench).** The sandbox inherits `LAIN_PROVIDER=ollama` from the repo's own
  `.envrc:12` (it is unset in a bare login shell, and `qa-sandbox.sh` does not set it). It silently
  voids any check whose premise is "nothing names a provider" — `epic-tier` §3's missing-key check,
  and `bench arms`' provider-resolution claim, which only holds with the variable scrubbed. Neither
  `env.sh` nor `isolation.sh` mentions `LAIN_*`.
- **P-6.** `qa-sandbox.sh` redirects `XDG_CONFIG_HOME`, hiding the box's `init.defaultBranch`, so
  sandbox repos are `master` while scenarios claim `main`.
- **P-7.** `$QA/env.sh` reinstalls Ruby (423 MB) into a redirected `HOME`.
- **P-8.** This round's tasking to the shell context **inverted README's duplicate rule**. The two
  shell files defer the shared ground (the config table, the no-prompt positive, the docker
  pipeline, the `web_fetch` strings) **to** `shell-terms.md`, not away from it. The fork followed
  the files, which was right. README should say which way round it goes in one sentence.
- **P-9.** A context was **denied permission** to run `ollama stop qwen3-coder:30b` — the narrowest
  possible reclaim of a runaway generation (model eviction only). It did not work around the denial
  and the runaway released itself 6 minutes later. If a round is expected to reclaim an orphaned
  generation, that permission needs to exist up front. **Escalated to the operator.**
- The b=512 runner reload at 11:21:55Z was the spine's own required `env -u LAIN_NUM_BATCH` control
  for `session-and-window` §6. It is accounted for and is not unexplained thrash. Only 3 reloads
  occurred all round, against round 18's 65 minutes of alternation.

## Coverage — every scenario in the directory

Enumerated fresh from `ls planning/qa/scenarios/` at round start: **18 files**.

| scenario | driven | notes |
|---|---|---|
| `session-and-window` | **full** | all twelve sections pass; no drift in any quoted figure |
| `rust-cli` | **full** | the compile-error unhappy path passed cleanly — model read `E0580` and restored the file byte-identically |
| `bowling-ruby` | **full but §1 substituted** | **5/5 oracles on the first attempt**; F23 both doors + control. `/create-plan` not driven as written — a directive ask was used instead |
| `cockpit-surfaces` | **§0–§5 + refusal rail; §4b and §6/§7 partial** | §4b (note rail) not driven — budget. Still the one part of this file no round has placed a note in |
| `bench-arms` | **refusals full; metered run aborted** | all four pre-spend refusals exact, 0 frames. The full run was driven last with the box idle and **aborted on the iteration ceiling after 13 grades** → **Fp-3**. The grade table, token ledger, cost column and attribution header are therefore **undriven this round** |
| `failure-injection` | **partial** | §5 full incl. the supervisor door owed since round 9. §1a/1b/4/6/7/9/12 not reached — budget (caused by Ff-1) |
| `secret-boundary` | **§0–§5b, §7** | the boundary holds; §6 (`--secret-oracle`) deferred to avoid evicting the shared model — the one section still owed |
| `changeset-review` | **§0–§8 less §6's Ctrl-C** | three first drives |
| `subagents-and-backends` | **§1–§4, §6 launch** | `lain watch` (§5) not reached — the largest single gap. `actor` mode recorded unreachable from chat, not filed |
| `memory-and-dogfood` | **full** | F134 verdict; consolidate burst bounded and declared |
| `rails-blog` | **§1, §1b, §5** | **§1b driven end to end, apparently for the first time.** §3 (gate under volume) not reached — a deliberate trade to reach §1b |
| `repl-commands` | **partial** | §4/§6/§7/§9 not reached — budget |
| `epic-tier` | **partial** | §12 not driven: `gh` is authenticated on the host but the sandbox redirects `XDG_CONFIG_HOME`; creating a repo under the operator's account is outward-facing and unauthorized |
| `survey` | **full** | **§7 driven — the debt owed since round 7.** §4's artifact half partial |
| `prompt-slots-and-roles` | **§1–§4, §6 free half** | §6's paid half is a **proven capability gap**: `ANTHROPIC_API_KEY` unset and 0 exported matches in `.envrc` |
| `shell-terms` | **zero-model surface full** | §9 skipped per README's own "cut §9 first". Model-spending sections not reached — budget |
| `shell-term-approval` | **zero-model surface full** | all 17 §2 verdict rows, all 10 §1 arm rows, the whole 22-row §4 audit, 31 `web_fetch` rows |
| `ollama-cloud-arm` | **steps 1–5** | reachable after all: `OLLAMA_API_KEY` **is** exported in `.envrc`. 4 cloud completions against a budget of ten; step 6's metered half skipped on the scenario's own instruction |

**Re-counted, since the docs drift:** `lib/` is now **871 files / 180,987 lines** (the docs say
~780/~164,000). The command registry is **24**, not 23. `memory-and-dogfood` §2's stated 256 KiB
ceiling is really 16,384 bytes. `failure-injection` §8's ceilings are stale.

## What the round taught the method

Folded back into `planning/qa/method.md` and the scenarios (see the commit beside this file):
the scoped nvim-kill recipe, the three-pane driving rule and the `@lain_input_pane` pin, the
`grep -cE` key check, the `answer.sh` fail-closed fix, and the `LAIN_*` note in the isolation gate.
