# QA round 17 — 2026-09-14

**Scope: a FULL round** — no scope was named, so every scenario in the `planning/qa/scenarios/`
listing (18, enumerated at Phase 1). The spine, `secret-boundary`, `changeset-review`,
`subagents-and-backends`, `memory-and-dogfood`, `rails-blog` and `ollama-cloud-arm` were driven in
the main context. `epic-tier`, `survey`, and both shell scenarios ran in three parallel fork
contexts, each with its own sandbox (`~/tmp/lain-qa-round17-{epic,shell,survey}`) and tmux socket.
Their findings carry the ids `E*`, `V*` and `T*` in `records/fork-*-report.md` and are folded in
below. No timing claim below rests on a fork-overlap window: all four contexts shared one GPU slot.

**Bench:** `main` at `d073c232`. `/mnt/nvme` ollama 0.32.12, `qwen3-coder:30b`,
`OLLAMA_NUM_PARALLEL:1`, `OLLAMA_CONTEXT_LENGTH:32768`, `LAIN_NUM_BATCH=2048`. NVIM v0.12.4,
tmux 3.7b, podman emulating `docker`. Sandbox `~/tmp/lain-qa-round17`, left in place as evidence.
Round start `2026-09-14T17:15:35Z`.

**Desktop: the notifier no longer exists.** `Lain::Notify` was deleted on 2026-09-12 (`c40ab419`),
along with `LAIN_DESKTOP` and `--desktop`. It was proved by the negative on a server started
*without* `LAIN_DESKTOP`, with `dunstify` on `PATH`: a parked gated call raised `displayed=0
waiting=0`. The skill's fourth gate, `cockpit-surfaces` §5's withdrawal half, and `shell-terms` §5's
`dunstctl` negative are moot (P36).

---

## Summary

The loop works end to end and its artifacts pass:
- `rust-cli`'s `wordfreq` passes the driver oracle, and the planted compile error came back as a
  clean exit-101 diagnostic.
- `bowling-ruby` scores **5/5 oracles**.
- `rails-blog` built a working blog: **30 runs, 43 assertions, 0 failures**, all three resources
  routed.

Around that, the round found:
- **Six HIGH defects:**
  - bash output that is not pure ASCII tears the ask;
  - ollama's silent prompt truncation is invisible to every reader;
  - two telemetry records never reach the journal;
  - an allowlisted `cat` releases credential files with nobody asked;
  - a torn journal line opens an epic's stage boundary;
  - the one dangling tool call that F88 leaves permanently disables compaction.
- **Seven MED-HIGH defects**, among them `/rewind` silently undone by an in-flight run, compaction
  latching on a finished to-do list and then *un*-compacting, the summarizer re-keying the runner
  twice per call, and `lain consolidate` unable to find any chat lineage.

Round 16's F84 (`--windows`) is **fixed**. F86 and F87 are unchanged.

**Every scenario was driven, at least in part.** Drops within scenarios are named in the coverage
table with reasons: budget, or a capability gap with the check that established it.

| id | sev | what |
|---|---|---|
| **F88** | **HIGH** | any non-ASCII byte in `bash` output — a valid `✅` included — tears the ask after the command already ran |
| **F89** | **HIGH** | the dangling `tool_use` F88 leaves makes `elide-tools+summarize-conversation` refuse every later turn; compaction stalls at 94% and never recovers |
| **F90** | **HIGH** | ollama silently truncates an over-window prompt; lain journals the truncated count as occupancy (50%, then 16%) and the model loses its tools |
| **F91** | **HIGH** | `ComposedTerm` auto-approves `cat`/`grep` of credential files the `Sensitivity` table does not name — `config/master.key`, `~/.pgpass`, shell history (fork T1) |
| **F92** | **HIGH** | `shell_arm` and `isolation_lease` records go to the display `Channel` and never reach the journal (fork T2, confirmed for leases here) |
| **F93** | **HIGH** | a truncated `gate_decision` line reads as drained, so `lain epic submit` opens the next stage (fork E4) |
| **F94** | **MED-HIGH** | a completed to-do step latches `plan_step_completion` across asks, compacting every turn; the next `todo_write` un-compacts (22 → 109 messages in one call) |
| **F95** | **MED-HIGH** | summarizer/oracle requests drop the backend's `num_batch`/`num_ctx`, so every summarized tool result reloads the runner twice (29.4s vs 1.6s control) |
| **F96** | **MED-HIGH** | `/rewind` while a tool call is parked reports success, then the answered run re-commits every rewound turn |
| **F97** | **MED-HIGH** | two parallel one-shot spawns share one spawn digest: one `--windows` window, an interleaved `lain watch` |
| **F98** | **MED-HIGH** | `lain consolidate` can never find a chat lineage: it reads `turn` + `meta.spawned_from`, and chat journals `child_turn` |
| **F99** | **MED-HIGH** | a failed epic issue cannot be retried: its retained dirty lease holds the issue branch (fork E10) |
| **F100** | **MED-HIGH** | a timed-out epic gate never withdraws its question; four inbox readers disagree (fork E13) |
| F101 | MEDIUM | answering a subagent question from nvim leaves a ghost `human>` drawn mid-dispatch on every later ask |
| F102 | MEDIUM | a line typed during dispatch is consumed by the next `[y/N]` as a human denial, 19 ms after it appears |
| F103 | MEDIUM | one non-UTF-8 filename withholds a whole `list_files`/`glob` listing, naming only `(ArgumentError)` |
| F104 | MEDIUM | mode layers are lighters only: `+auto_approve` shows `AA` and approves nothing, `/goal` never sets `goal`, `notify` outlived its notifier |
| F105 | MEDIUM | `/goal off` typed mid-drive cannot stop a goal; it runs to the cap, then prints "goal off" |
| F106 | MEDIUM | a pending decided by another surface (`secret_oracle`, nvim) leaves a live-looking `[y/N]`; the human's `n` becomes a chat prompt |
| F107 | MEDIUM | `/undo` under `manual`/`plan` (write-set scope) refuses every first write, and after a posture change it blames paths the turn never touched |
| F108 | MEDIUM | the 7,000-line critique chunker has no production caller; `/critique` over an open review reads the dirty working tree |
| F109 | MEDIUM | `lain bench variance` refuses any local recording with usage ("no price"), while `bench arms` degrades the section |
| F110 | MEDIUM (gap) | `lain bench arms` refuses every non-Anthropic backend; the second remedy it names is a Ruby method argument |
| F111–F117 | MEDIUM | epic-tier E12, E8, E2, E5, E9, E11, E6 — see the fork section |
| F118–F130 | LOW | see the LOW table |
| P36 | **HIGH (process)** | the skill, sandbox, `method.md` and four scenarios still prescribe a deleted notifier |
| P37 | MEDIUM (process) | `nv.sh buf`/`bufs` joined lines with a literal `\n` — **fixed in this round** |
| P38 | MEDIUM (process) | the sandbox hid the operator's git identity, so every epic red-step commit failed — **fixed in this round** |
| P39 | MEDIUM (process) | five driver-caused hazards, all real, all folded into `method.md`/`SKILL.md` |

---

## Round-16 items re-checked

| id | verdict | evidence |
|---|---|---|
| **F84** `--windows` opens nothing | **FIXED** | inside tmux, a spawn opened `subagent-a6bd8454`, which gained `[done]` when the child finished. But see F97: two spawns got one window |
| F85 bench pane resolution | not re-hit | no wrapped chat pane this round; `panes.sh` refused nothing wrongly |
| F86 `/introspect` window "unreported" | **UNCHANGED** | `/introspect` still lists `window` under `unreported` while `compaction_decision` carries `window_tokens: 32768, provenance: "probed"` |
| F87 `[lain:compaction stderr]` label | **UNCHANGED** | `rails-blog`: `[lain:compaction stderr] compaction is warranted (approaching_window) and nothing is droppable …` |
| check 5 (F81) | **HOLDS** on the TTY path | bowling: the relayed researcher question answered as prose, `inbox_count` 1→0, fleet `[]`. The nvim-answer path is F101 |
| check 6 (F83) | **HOLDS** | bowling `/critique` child finished, `fleet: []`, and the status line lost its segment |
| check 7 (F82) | **HOLDS** | `rails-blog` second session: the report printed once at 31,935/32,768 with `head_bytes: 2` |
| round 10 F62 (binary `read_file`) | **FIXED, confirmed** | `blob.bin` refused by name: `is not valid UTF-8, so its contents cannot be recorded…`; the ask survived. F88 is that fix missing from `bash` |
| round 10 F63 at `accept_edits` | **HOLDS** | `cat <P>` on `~/.ssh/id_qa`: exactly one `escalation` (`triage`, `deny`, `faulted=false`, reason names the argv word), nothing parked. The model then concluded "bash is not allowed in this environment" (T4 wording) |
| round 10 F63 under `/mode auto` | **known-open, reproduces** | the key was catted; its bytes are in the journal; zero escalation rungs; `/approve` → `no pending approvals`. Re-check only, not re-filed |

---

## HIGH

### F88 — `bash` output with any byte ≥ 0x80 tears the ask after the command ran — HIGH

**What happens.** A `bash` tool result containing a non-ASCII byte kills the ask with `error: string
is not convertible to UTF-8: "\xE2" from ASCII-8BIT to UTF-8`:
- the command has already run;
- no `tool_result` is committed;
- the chain is left with an assistant `tool_use` and no answer (`run_interrupted reason=torn`, head =
  that `tool_use`).

**This is not about invalid bytes.** Three triggers, all reproduced:

| command | bytes | result |
|---|---|---|
| `cat latin1.txt` (Latin-1 `é`) | invalid UTF-8 | torn, `"\xE9"` |
| `ls -la` in a dir holding `bad\xff\xfename.rb` | invalid UTF-8 | torn, `"\xFF"` |
| `bin/rails test \| grep … && echo "✅ All tests passing successfully"` | **valid UTF-8** (152 bytes, `valid_encoding? == true`) | torn, `"\xE2"` |

**Mechanism.** The local exec arm reads through `Mixlib::ShellOut`, whose captured stdout is
`ASCII-8BIT`. `Canonical#utf8` (`lib/lain/canonical.rb:109-116`) does
`string.encode(Encoding::UTF_8)` from ASCII-8BIT, which raises on any high byte, and
`Timeline#commit` hits it. `read_file` had exactly this defect and was fixed in `780c4a08`
("refuse a file whose bytes cannot become a turn"). `bash` has no equivalent: it neither re-tags
valid UTF-8 nor refuses by name.

**Ruled out.**
- The same session answers the next prompt normally, so this is not a dead session.
- It is not the command string: the emoji sits in the `tool_use` input too, and that committed fine
  on every earlier turn.
- It is not the stream: the pane rendered `[call_… stdout] ✅ All tests passing successfully`
  before the tear.

**Reproduction.** In any chat, ask for `bash`: `echo "✅ ok"`, and approve. Expect `error: string is
not convertible…`, then `run_interrupted torn` with the head on the `tool_use`.

**Why HIGH.** Emoji and accented output are ordinary: test runners, `git log` with non-ASCII
authors, any localised tool. The model never sees the result, and the dangling call is permanent
(F89).

**Fix shape.** Tag captured bytes UTF-8 when they are valid, and refuse the result by name (as
`read_file` does) when they are not. Pin it with a spec over a valid multibyte result and an
invalid one, both through `Timeline#commit`.

### F89 — one dangling `tool_use` disables composed compaction for the rest of the session — HIGH

In `rails-blog`'s first session (flags `--compact-strategy elide-tools+summarize-conversation
--summarizer-provider ollama`), F88 tore turn 216. From then on:
- Every `compaction_decision` carried `signals: ["approaching_window"]` and `compacted: false`.
- Each was preceded by `derivation_refused`: `… derives a chain the Messages API would reject: the
  tool_use "call_pronwqx8" in messages[28] is never answered`.
- The status feed read `derivation_refusal_streak: 3`, and the status line
  `qwen3-coder:30b compaction stalled ctx 94%`.
- Summaries were still paid for on each refusal: 9 `oracle_answer` records.

**Mechanism.** `Compaction::Derivation` (`derivation.rb:183`) validates the *derived* chain against
the Messages API's pairing rule. The source chain already carries the unanswered call, so every
derivation inherits it and is refused. Nothing repairs or elides an orphaned `tool_use`, so the
refusal is permanent. The *live* request keeps sending that unanswered call too, which ollama
tolerates and the Anthropic API would reject with a 400.

**Evidence.** Journal `…/aa55e66ae9f1/20260914T195958-3399448.ndjson`:
- `run_interrupted` at 20:23:26 has head `eceb638878` (assistant `text,tool_use`);
- the next turn is a user **text** turn;
- `derivation_refused` follows on every compacting turn after occupancy crossed 90%.

**Fix shape.** Either repair the orphan when a run tears (commit a synthetic `is_error` result
naming the tear), or have the derivation elide an unanswered call. The first also fixes the
Anthropic 400. Pin it with a torn-run spec asserting the next render is API-valid.

### F90 — provider-side prompt truncation is invisible; occupancy lies low — HIGH

**What happened.** In `failure-injection` §9 step 4, a full-cover window of the 300 KB `mid.rb` (the
scenario's own recipe) made a request of **330,522 bytes**. Ollama's log recorded
`msg="truncating input prompt" limit=16386 prompt=59969 keep=4 new=16386`. Readers downstream:

| turn | `input_tokens` journaled | `ctx` shown | request bytes |
|---|---|---|---|
| read the window | 16,386 | 50% | 330,522 |
| next turn | **5,142** | **16%** | 331,413 |

**Consequence.**
- The prompt was cut from the front, keeping 4 tokens: the system prompt and every tool schema were
  dropped.
- The model's next turn was literal `<function=list_files>…</tool_call>` text. It no longer had its
  tools, which a round would otherwise misfile as MODEL-1.
- No signal fired. `approaching_window` compares `used_tokens` against the window, and the
  provider's count is post-truncation, so the reader that would have warned is exactly the one that
  was lied to.

**Ruled out.**
- Not F82: F82 pins occupancy *high*; this one reads *low*.
- Not a guessed window: `provenance: "probed"`, `window_tokens: 32768`.
- Not a model reload: `/api/ps` was resident, and the log line names the truncation outright.

**Reproduction.** `--num-ctx` at the default 32,768, a 300 KB line-structured file, then
`read_file` with `offset: 1, limit: 6000`. Watch `input_tokens` fall below the previous turn's.

**Fix shape.**
- A pre-send estimate (`ProxyBytes::BYTES_PER_TOKEN`) against the served window that refuses or
  compacts before an over-window request.
- A `prompt_truncated` record when the provider's count falls far below the estimate.
- Make `WINDOW_BOUND`'s 1 MiB aware of the served window, since 1 MiB is ~6× a 32k window.

### F91 — allowlisted readers release credential files with no human, no mask — HIGH (fork T1)

`Approval::ComposedTerm` predicate 4 (`composed_term.rb`, "every word classifies ORDINARY")
auto-approves `cat`/`grep`/`wc` of any path the built-in `Sensitivity` table does not name.

**What it approved.** In a sweep (fork journal `20260914T191419-3335483.ndjson`):
`config/master.key`, `config/credentials.yml.enc`, `~/.pgpass`, a bare `id_rsa`,
`~/.bash_history`/`~/.zsh_history`, `~/.gem/credentials`, `~/.ssh/config`, the login keyring,
`rclone.conf`, `/etc/ssh/ssh_host_*_key`, and `/var/log/auth.log`. There is no project-root
predicate. Live:
- `call_igozymhe` (`cat config/master.key`), `call_9l88ebie` (`.pgpass`) and `call_wz32rq3f`
  (`grep TOKEN .bash_history`) each have a `rules` `allow`, `authority=automatic`, and no
  `approval_pending`.
- A fake `ghp_…` token came back verbatim.
- In the same session `cat .env` parked, so the gate was live.

**Why no mask.** `RedactSecretReads` guards `read_file` only (`redact_secret_reads.rb:68`), so what
`read_file` would have masked (`Regions.detect` flags the line) went out raw through `cat`. The
class's own floor — "never more permissive than a careful human reading the same command" — does
not hold, because the `Sensitivity` table was sized for a world where a human is still asked.

This round's own `wc -c a.txt` and `cat latin1.txt` were approved the same way. **Fix shape:** words
confined to the project root, and a named-credential tier sized for "nobody is asked".

### F92 — two telemetry records never reach the session journal — HIGH (fork T2, confirmed here)

**Mechanism.** `CLI::Wiring#run` builds the display channel (`wire_agent(channel:
Lain::Channel.new, …)`, `wiring.rb:282`) and the TTY drains it. The durable record is a separate
object, `LiveViews#journal` (the chronicle tee, `live_views.rb:129`). Several collaborators are
handed `channel` as their journal:
- the toolset (`wiring.rb:637`, so `Telemetry::ShellArm`);
- `fleet_isolation` (`wiring.rb:419`, so `Telemetry::IsolationLease`);
- the `Supervisor` (`:648`).

**Measured.**
- Fork: 0 `shell_arm` records against 20 `bash` calls, in attended, `/mode auto` and `--exec docker`
  sessions.
- Here: an `--isolation worktree` session where `git worktree list` showed the lease
  (`…/worktrees/2b669c5e6732/934280d739ac … locked`) appear and then disappear had **zero**
  `isolation_lease` records.

`wiring_spec.rb:3311` passes a recording channel straight into `ToolsetBuild`, which is why it is
green.

**Consequence.** `shell-terms` §6/§9 and `subagents-and-backends` §3 check 3 are unmeasurable, and
the experiment record cannot say which arm ran or what was leased. **Fix:** hand these collaborators
the chronicle tee, and pin it with a wiring spec reading the chronicle, not a stand-in.

### F93 — a truncated `gate_decision` line opens the stage boundary — HIGH (fork E4)

`SignoffQueue.from_journal` reads through `Journal.records`, which skips unparseable lines
(`signoff_queue.rb:284-287`). `epic/progress.rb:170-172` claims the rebuild "NEVER degrades to an
empty queue".

**Fork evidence.**
- With the parked `research` record intact, `lain epic submit epic_plan pol-adj2` refuses, rc=1.
- With that one line halved, the same submit returns **rc=0** and parks `epic_plan`, so research
  and `epic_plan` are parked at once.
- `lain epic queue` says "nothing parked" with a WARNING, rc=0.

This is `epic-tier` §9's fail-open, exactly as the scenario feared.

---

## MED-HIGH

### F94 — `plan_step_completion` latches across asks, then the history un-compacts — MED-HIGH

**Mechanism.** `Session#write_todos` sets `@plan_step_completed` when the completed count rises
(`session.rb:274`), and nothing clears it until the **next** `write_todos`. `Compaction::Source#decide`
compacts per render and returns `base` (the full chain) whenever no signal fires (`source.rb`
`defer`). So:
- Every turn after a completing `todo_write` compacts, including every turn of a *new, unrelated*
  ask. Each re-derives from the root, with `summary_hits 0` and misses climbing.
- A later `todo_write` that completes nothing clears the latch, and the **next request renders the
  full history**.

**Evidence, two sessions.**
- `rust-cli`: 9 consecutive `compaction trigger=["plan_step_completion"]` records spanning my next
  ask. Then a `todo_write` with identical statuses, and the request went from 21 → 59 messages,
  `input_tokens` 12,816 → 18,723, on a 33-byte tool result.
- `bowling`: 17 compactions. **Controlled repro:** "call `todo_write` re-writing the same two
  completed items" took the next request from 22 → **109** messages and 19,652 → **26,079** tokens
  (ctx 58% → 80%).

**Why it matters.**
- On a history larger than the window, the un-compaction sends an over-window request, which is
  F90's silent truncation.
- On a caching provider every flip breaks the prefix twice.
- The occupancy reading jumps with no signal in between.

**Fix shape.** Edge-trigger the signal (clear after one decision), and make a committed compaction
sticky until a threshold says otherwise.

### F95 — summarizer requests drop `num_batch`/`num_ctx`, re-keying the runner twice per call — MED-HIGH

`Oracle::Model#request_for` (`oracle/model.rb:69`) builds `extra:` from the structured-output schema
alone. It never carries the backend's `sampler_extra` (`backend.rb:554`). With `LAIN_NUM_BATCH=2048`
— which `bench.md` mandates — every summarized tool result (≥ 4,096 B) makes ollama reload to
`-b 512` for the oracle and back to `-b 2048` for the next turn.

**Control, same prompt (read a 10.5 KB file), two runs each:**

| env | runner loads per ask | oracle `wall_clock` |
|---|---|---|
| `LAIN_NUM_BATCH=2048` | **2, 2** | **29.38s, 29.28s** |
| `env -u LAIN_NUM_BATCH` | 1 (the switch), **0** | 2.65s, **1.63s** |

Ollama's log alternates `n_batch = 512` and `n_batch = 2048`: **53 runner loads** this round. Every
`provider_wait` of ~30s in the journals is this. The same drop applies to `--num-ctx`. This is the
F26/F10 class, now fully attributed: it is not contention, it is a re-key.

### F96 — `/rewind` with a tool call parked reports success and is silently undone — MED-HIGH

At `human>` with the parent's own `ask_human` parked, the three doors disagree:
- `/fork` refuses ("may still be making that call");
- `/undo` refuses ("a turn is in flight");
- `/rewind 3` answers `rewound 3 turns: f8f93647… -> 466da7ea…` and journals `rewound`.

Answering the question then **re-commits all three rewound turns verbatim** on top of the new head
(`8b8befbd`, `1d568d28`, `f8f93647`, journal lines 321–323), and the next request carries them
(`msgs=66`, last three are the rewound ask, its `tool_use`, and the answer). This is the scenario's
own "worst version of this bug: the head moving in the display while the context still carries the
discarded turns". **Fix:** `/rewind` shares `/fork`'s mid-tool door.

### F97 — concurrent one-shot spawns share one spawn digest — MED-HIGH

One turn with two `subagent` calls (lib/a, lib/b) journaled **two identical** `message kind=spawn`
records, `blake3:a6bd8454…`: same `from`, `causal_parents` and payload. The prompt is not in the
payload, and `adoption` is written only for actors (`tools/subagent/lineage.rb`).

`lineage.rb` justifies this: "a one-shot is adopted by nobody and addressed by nobody". That is false
on two shipped paths:
- `--windows` opened **one** window, `subagent-a6bd8454`, for two children;
- `lain watch blake3:a6bd8454` interleaves both children's results under one lineage.

Any fleet reader keyed by spawn digest collapses the twins. **Fix:** a counter for one-shots too, or
the prompt digest in the payload.

### F98 — `lain consolidate` cannot find a lineage in any chat session — MED-HIGH

`Consolidation#lineages` reads only `Journal.records(entries, type: "turn")` and recognises a
subagent root by `meta["spawned_from"]` (`consolidation.rb:60, 180-183`). Chat subagents are
journaled differently:
- as `child_turn` records whose root `payload.meta` is `{}`;
- with lineage carried on the `message kind=spawn` payload (`tools/subagent/lineage.rb:61`).

**Evidence.** A session manufactured exactly as `memory-and-dogfood` §4 says (two completed spawns:
`message/spawn`=2, `child_turn`=14, `message/message`=2) gives `consolidate: no completed subagent
lineages found.`, both dry and live, rc=0. That is the scenario's own warning: "a consolidation pass
that spawns nothing still exits 0".

Round 15 recorded "consolidate no-ops with a reason" against a session it did not check for
lineages. CLAUDE.md's "a fresh root whose `meta["spawned_from"]` names the parent's head" is also
false on this path; `grader/tool_call_index.rb:107` reads the same key.

### F99, F100 — epic driver retry wedge, timed-out gate never withdrawn — MED-HIGH (fork E10, E13)

**F99 (E10).** After a per-issue refusal the lease is retained for 7 days, locked and dirty. The
next `/implement-epic` fails: `lain/issue/tiny/greet could not be checked out … already used by
worktree at …/retained/…`. `lain worktrees gc` keeps it, and only `git worktree remove -f -f` gets
past.

**F100 (E13).** An implementation gate that timed out (`answered_by: timeout`, 300s) wrote no
`questions_consumed`. Afterwards:
- `lain://inbox` lists the question;
- `inbox_count` stays 1;
- answering it says "stale";
- `/inbox` then says "(no questions pending)" while `/status` says inbox 1;
- the status line keeps `fleet 1` long after the run printed "0 landed".

This is the F81/F83 shape returning through epic gates.

---

## MEDIUM

### F101 — an nvim-answered question leaves a ghost `human>` drawn on every later ask

**Reproduction.** Bowling: answer a relayed question via `:LainReply`. The next three asks each drew
`qwen3-coder:30b ctx 80% idle 0s` / `human>` *mid-dispatch* before the reply. A line typed there got
`error: the question set blake3:77493d20… cannot be answered: no question is awaiting a reply …
nothing you type here is recorded`. **After that refusal the ghost stopped.**

**Mechanism.** `AnswerLoop#serve` (`human_replies.rb`) re-queues an item on any unwind. The TTY read
is torn down at each line's end, so a set answered by another surface is re-served on every
dispatched line until a human types into it and is refused. The comment calls the re-queue
"self-limiting — the next surface serves it once", which is false when nobody types. The ghost also
prints an `idle` segment during dispatch.

### F102 — typeahead becomes a human denial at the next approval

In a `--no-nvim` chat, a prompt typed while a turn was dispatching (a 34.7s summarizer wait, F95)
was consumed by the **next** `[y/N]` prompt:
- `approval_decision surface=tty verdict=deny latency=0.0197`;
- `escalation … "a surface refused this call … (tty)"`, authority human;
- the typed prompt text lost.

Only an exact `y`/`yes` would approve (`AFFIRMATIVE = /\Ay(es)?\z/i`), so the danger is a denial
signed as a person plus a lost prompt. `repl/line_scope.rb`'s own comment names the two-reader race
and says "the rule above is narrower".

### F103 — one non-UTF-8 filename withholds the whole listing

`list_files .` and `glob **` in a tree holding `bad\xff\xfename.rb` return
`list_files could not be checked for sensitive paths (ArgumentError); nothing was returned.`

**Mechanism.** `WithholdSecretPaths#sift` does `content.split(ROW)` (`withhold_secret_paths.rb:270`),
which raises `invalid byte sequence in UTF-8` before any per-row classification. The class comment
at `:281` describes handing a malformed reading over **unjoined** precisely so "the classifier
withholds exactly the row nobody can read" rather than the whole listing. That defence covers NUL
and not encoding. The survey walk does not share this path (fork V: it lists the name).

### F104 — mode layers change the prompt lighter and nothing else

**What happens.** `Mode::Resolution.for` "reads only `posture`" (`mode/resolution.rb`). No code
outside `mode/` reads layer membership; the only consumers are lighters (`prompt_composer.rb:407`,
`status_feed/mode_state.rb:56`).
- **`/mode +auto_approve`** shows `AA`, and a gated `git status` still parked for the human (journal:
  triage abstain, rules abstain, `approval_pending`). `Approval::AutoSurface` is wired from the
  `--auto-approve` **flag** (`toolset_build.rb:216`), not the layer.
- **`/goal`** never raises the `goal` layer: `/mode` read `accept_edits: no layers active` while a
  goal stood, and `cli/command/goal.rb` never touches layers.
- **`notify`** names the deleted notifier.
- **`vi`** does not reach Reline, which takes `vi_mode:` at construction.

**Why it matters.** `mode/layer.rb:78` says `:auto_approve` "turns Approval::AutoSurface on", and
`method.md` bans `+auto_approve` as a route to approve-all. Both are false on the path they
describe. The failure is safe-direction, but the lighter tells a human "auto-approve is on".

### F105 — `/goal off` cannot interrupt a running goal

With a 5-iteration cap and an objective the model cannot finish, `/goal off` was typed after
iteration 2. Iterations 3–5 still ran (`goal_iteration` 1–5 at 18:57:34–:41). Then `goal stopped:
loop ran 5 iterations`, and only then `goal off -- the driver stops re-prompting`. The line is
typeahead, read only once the driver yields the prompt. The scenario's third terminating condition
is unreachable from the TTY.

### F106 — a pending decided elsewhere leaves a live-looking `[y/N]`

**`--secret-oracle` reproduction.** The oracle approved `vendor/bundle.min.js` at
`19:23:59.400` (`surface=secret_oracle`, latency 39.6s: F95 plus the oracle's own `qwen3:4b`
eviction). The TTY kept
`"…/bundle.min.js": 1 sensitive region outstanding -- agent asks: approve read_file(…)? [y/N]` as
its last line for 40+ seconds. A human `n` typed at it became a **user prompt turn** `"n"`
(`19:24:39`), not a denial. The region had already been released.

The same thing happened with `.env` (the oracle denied; the prompt stayed drawn). With nvim's
`:LainApprove` the unterminated prompt line received the next stdout on the same line (`? [y/N]
[call_metbsf2q stdout] 68e9264 seed`).

**Also.** The oracle is **concurrent with**, not "ahead of", the human (the `--secret-oracle` help
text), so the human is prompted for reads the oracle then decides.

### F107 — `/undo` under write-set scope refuses every first write

**Pure `manual` session (control).**
- A turn that **created** `x.txt` refused as `x.txt was first written in that turn, and nothing
  recorded what it held before`.
- A turn that overwrote **committed** `keep.txt` refused with the same sentence.

So nothing a `manual`/`plan` session writes once is ever undoable, and "first written in that turn"
is false for a pre-existing tracked file.

**Mixed session.** After an `accept_edits` history, the refusal for a `manual` turn that wrote only
`e.txt` also blamed `c.txt` and `lib.rb`. That turn never touched either: `WriteSet#paths` returns
the session's cumulative write set (`snapshot/scope.rb:63`).

`accept_edits`' shadow-git undo worked in both directions. So did its `dirty`, `symlink` and
`directory` refusals, and `/undo skip`.

### F108 — the critique chunker is spec-only; `/critique` reads the working tree

`Review::Bounds#each_critique_chunk` (`review/bounds.rb:260`) and its 7,000-line ceiling have **no
caller outside `spec/`**. With a local-branch review open and `JUNKMARKER_UNCOMMITTED` appended to
`lib/tally.rb` (uncommitted), `/critique the changeset currently open for review` ran
`git status --porcelain` and `git diff lib/tally.rb`. The model read the junk: the journal's
`tool_result` carries `+JUNKMARKER_UNCOMMITTED`. `changeset-review` §6's premise ("the model is shown
the changeset, not the working tree") has no path that makes it true.

### F109 — `lain bench variance` refuses every local recording that has turns

- `lain bench record` against the local arm, two recordings → `…: no price for model
  "qwen3-coder:30b"; configure a fallback to degrade`, rc=1.
- The same pair with zero turns reports `cost 0.000000`.

`Bench::Variance` builds `Ledger.new(price_book: PriceBook.default)` (`variance.rb:113`), which
raises for any unpriced model, whereas `bench arms` degrades only its cost *section* (its scenario's
rule 1). The record→variance loop is unusable on the only arm this box has, and `ollama-cloud-arm`
§7 discusses variance numbers from exactly these arms.

### F110 — `lain bench arms` refuses every non-Anthropic backend (feature gap)

`--provider ollama --isolation worktree --journal …` refused:
`the adaptive-router arm routes narrow tasks to claude-haiku-4-5, and this run resolved
"qwen3-coder:30b", which it is no cheaper than …`.
- The refusal is pre-spend and correct as a guard (`live_arms.rb:116-127`, landed `2f79c971`
  today).
- "No cheaper than" is false for a local model: it is not the comparison.
- The second remedy — "pass a `router:` of your own to `Bench::CLI#arms_report`" — is unreachable
  from the CLI.

No `ANTHROPIC_API_KEY` is set on this box (`[ -n "${ANTHROPIC_API_KEY:-}" ]` false; `.envrc`
exports only `OLLAMA_API_KEY`), and `ollama-cloud` tags do not match `ROUTABLE_MODEL`. So
`bench-arms` cannot run here at all.

### F111–F117 — epic-tier (fork, MEDIUM; mechanisms in `records/fork-epic-report.md`)

| id | fork | what |
|---|---|---|
| F111 | E12 | the implementation gate opens over the red commit when the actor committed no work (`factory.rb:763-770`) |
| F112 | E8 | approving `research`/`epic_plan` from the queue never writes a `stage_transition`; status stays `stage research` (`epic_queue.rb:258-290`) |
| F113 | E2 | an unattended `submit` of a `hands_off` stage refuses because another stage is `interactive` (`policies.rb:235`), in jargon ("missing asker") |
| F114 | E5 | a parseable but malformed `gate_decision` (`"approved":"maybe"`) dies with ~30 frames of `ArgumentError` (`declarative.rb:152`) |
| F115 | E9 | the driver reads `[tests]` from the worktree, so the conventional gitignored `.lain/config.toml` blocks every issue (`factory.rb:869-874`) |
| F116 | E11 | gc reaps a fresh `landing` worktree as "landed on main" while an `--epic` cockpit is live (`gc.rb:~294`, missing the guard at `:417-419`) |
| F117 | E6 | `lain epic add/split/merge` silently deletes the preamble of `epic.md` |

---

## LOW

| id | what | evidence / mechanism |
|---|---|---|
| F118 | `--windows` outside `$TMUX` launches silently | `lain chat --windows` from a non-tmux shell: rc=0, `you>`, no warning; `FleetWindows.for` builds a Null. The scenario (§6) expects a refusal |
| F119 | `lain watch` needs the `blake3:` scheme; a bare hex prefix reads "no spawn matched" | `lain watch c81907db9d1c --session <file>` → no match; `blake3:c81907db9d1c` → lineage. `/pin`, `/rewind` and `--fork` all take bare hex. Without `--session` the refusal does not name the session it searched |
| F120 | `lain improvements --kind knob` with no knob items says "no improvements recorded yet" | 2 `doc` items exist; the filter-empty reads as store-empty |
| F121 | `/review feature --base --permissive` → `--base is not a flag /review can read` | `--base` is a flag it reads; the defect is a missing value. `lain survey` says "takes a value" for the same shape |
| F122 | `/rewind b7a9` refuses as `/rewind 1 lands on an assistant tool_use turn still awaiting its tool results … (nearest valid targets: 2)` | it restates a count the human did not type, and the results exist — they are only being rewound past |
| F123 | `--context-pipeline prune+prune` refusal ends `; … and "default" is reminder+cache-breakpoints` | the tail is relevant only when `default` is involved |
| F124 | `--resume` of a session still open in a live cockpit prints `was not gracefully closed` | the writer pid is alive; the sentence reads as a crash report |
| F125 | `/meta` writes whatever the model says to `.lain/meta/<slug>.rb` with no parse check; `/meta run` launches it | a prose reply became the script; `ruby -c` → SyntaxError; the window died status 1 |
| F126 | `ContextWindow::CLOUD_WINDOWS` ships two retired tags | `deepseek-v4-{flash,pro}:preview-cloud` → `/api/show`: "was retired at …". No row over-claims its `context_length` (21 checked) |
| F127 | `--exec` help says "`docker` refuses a PIPELINE" | `cat lib/b/b.rb \| wc -l` ran under `--exec docker` (string arm, `sh -c` in the container), exit 0 |
| F128 | `[sensitivity] exempt = [".*"]` loads and ungates every dot-named credential (`.env`, `sub/.env`) | the refusal only catches `*`, `**`, `~/`; `~/**` loads but lifts nothing; `**/*` is refused |
| F129 | `grep` silently skips a file with invalid UTF-8; the model reported "the only occurrence" | documented (`grep.rb:124`), but the result discloses no skipped count |
| F130 | survey V1/V2, shell T3–T6, epic E1/E3/E7/E15/E16 | V1: `lain survey` and `/survey` name the same file differently outside cwd. V2: a `master` repo's `/review <branch>` refuses on `main` without naming `--base`. T3: `web_fetch` has no 240.0.0.0/4 entry (a real SYN is sent). T4: a named triage deny reaches the model as generic `approval denied`. T5/T6: `[shell]` config edge cases. E1/E3/E7/E15/E16: epic wording, provenance, queue rows, chat-vs-epic config strictness |

---

## Withdrawn near-findings

- **"The HUD's `idle Ns` counts from the human's last input, not the agent's."** Documented at
  `prompt_composer.rb:411`.
- **"`--num-ctx` alone reads `provenance: guessed`."** Deliberate: `WindowBook#vouched_by`, "a
  `--num-ctx` the provider did not confirm is a REQUEST".
- **"`RefuseSecretWrites` let `AWS_SECRET_ACCESS_KEY=AKIA…` into `notes.md`."** It guards
  `memory_write`/`improvement_write` only, by design (`refuse_secret_writes.rb:20-26`). `memory_write`
  of the same body refused as `aws access key id`; `foo: bar` wrote. The scenario is wrong (below).
- **"The PEM mask leaves the key body."** The fixture's body is 14 chars, under the entropy detector's
  24. Against generated RSA/Ed25519 PEMs every base64 line was masked. An OpenSSH key's first body line
  (the public header) and the END marker stay visible; recorded as a scenario note, not a leak.
- **"The thread pane opened by itself."** By design (`51_thread.lua` `review_thread.refresh`); it is
  what renumbered windows under my keys (P39).
- **"The model's `thinking` is dropped from turns."** It is recorded; my reduction read `text`.
- **"The oracle was answered after the human."** It is a concurrent surface; the human won the race.
  The live defect is the stale prompt (F106).
- **"`survey` sidebar rows use a different path base."** Deliberate since `02885580`, except for V1's
  one-shot/cockpit asymmetry.
- **"`/btw` failed."** It degrades correctly with no tmux client, printing the command to run; that
  command worked, and `/keep` → `lain sessions` → `--resume` answered from the kept turns
  (`PELICAN`).

---

## Model behaviour (not lain defects)

- **`qwen3-coder:30b` now emits parallel tool calls.** Six `tool_use` blocks came in one message
  when asked for "one per turn", and two `subagent` calls in one message. That contradicts
  `cockpit-surfaces` §5's "the house model cannot produce this shape"; multi-pending approvals are
  now drivable.
- **Literal `<function=…>` text:** once on a clean transcript (restarted), twice in the shell fork.
  Once it was caused by F90 truncation rather than by the model.
- **`bowling`:**
  - the researcher re-asked the same clarifying question twice;
  - `/create-plan` and `/execute-plan` burned the 25-iteration ceiling;
  - 4 of the model's own 12 specs have wrong expected values (the implementation is right);
  - it asked to `gem install rspec` (denied) and hallucinated a failing critique of a 5/5 scorer.
- **`subagents`:** it invented an actor handle (`lib_file_lister`) for a one-shot, and miscounted
  4 files as 6.
- **`--no-journal` chat:** it tried `rails --version` and `mkdir -p docs` for "reply ok".
- **`/goal`:** it emitted `<DONE>` before `GOAL_COMPLETE`.
- **`/meta`:** it wrote prose instead of a script (F125).
- **After a triage deny,** it concluded "bash is not allowed in this environment" and routed around
  it with `ask_human` (T4 wording).

---

## Process

### P36 — the round's procedure prescribes a deleted surface — HIGH (process)

`c40ab419` (2026-09-12) deleted `Lain::Notify`. `SKILL.md` Phase 2's "fourth gate" and Phase 6's
"clear the desktop", `qa-sandbox.sh`'s banner, `cockpit-surfaces` §5 (three paragraphs on
withdrawal), `shell-terms` §5, `shell-term-approval` and `rails-blog` all still prescribe
`LAIN_DESKTOP` and dunst checks. A round following them spends an act asserting a notifier that
cannot exist, and records a pass for a withdrawal nothing performs.

**Folded:** `SKILL.md` Phase 2/6 and the sandbox banner are rewritten. **Owed:** the four scenario
passages.

### P37 — `nv.sh buf`/`bufs` returned one line with literal `\n` — MEDIUM (process, fixed)

`'\n'` in a vimscript single-quoted string is a backslash-n. **Fixed** in `qa-sandbox.sh` (`"\n"`),
and verified against a headless nvim.

### P38 — the sandbox hid the git identity — MEDIUM (process, fixed)

The redirected `XDG_CONFIG_HOME` hid `~/.config/git/config`, so the epic driver's red commit failed
"Author identity unknown". **Fixed:** `qa-sandbox.sh` seeds a throwaway identity.

### P39 — driver hazards, each real this round — MEDIUM (process, folded)

1. **A `ps | grep` kill loop killed its own shell** (exit 144): the 9th recorded instance.
2. **A prefix allow-list (`bin/rails…`) approved `bin/rails server -d`**, daemonising puma on :3000
   outside tmux. Killed by pid; allow-lists must name subcommands.
3. **Helpers that refuse only on `[y/N]` still type into `human>` and into typeahead.** Two prompts
   became answers or denials; one `/fork` became an approval answer.
4. **`:2wincmd w` landed in an auto-opened thread pane** and typed text in insert mode. Recovered by
   undo, nothing sent.
5. **A `pathcount.rb` survived `kill %1`** and stayed listening on :21436 until close-out.

**Folded:** `method.md` gains a stale-`[y/N]` rule, a `human>`/typeahead rule and a thread-pane rule;
`SKILL.md` Phase 6 gains a port/daemon check.

---

## Scenario corrections owed (not applied — the list is the work item)

- **`session-and-window`** §9: the `lain up … --context-pipeline <typo>` pre-flight is **driven**
  (refuses, no session created).
- **`rust-cli`:** nothing.
- **`bowling-ruby`** §2: `--fork` prints no `SESSION@DIGEST` banner.
- **`cockpit-surfaces`:**
  - §5: the notifier half is moot (P36);
  - "the house model does not emit parallel tool calls" is stale;
  - §8's continuation-line case is now drivable.
- **`failure-injection`:**
  - §8: refusals name absolute paths, not `./`;
  - §9 step 4's full-cover window is F90's trigger on a 32k window;
  - §12: the oracle call **is** journaled now (`oracle_answer` + `provider_wait`), and the ~30s wait
    is F95, not contention.
- **`bench-arms`:**
  - arms now have a tool floor and need `--isolation worktree --journal`;
  - there are four arms, not three;
  - "empty toolset, single-turn" is stale;
  - non-Anthropic backends are refused (F110).
- **`repl-commands`:**
  - the `/help` roster is 23 (matches);
  - `/meta run a loop for me` is refused as an invalid slug, not read as launching `a`;
  - the goal sentinel is `GOAL_COMPLETE`, not `<DONE>`;
  - §2's ambiguous-prefix refusal is unreachable without ~300 turns (no 4-hex collision in 116);
  - §6's `+auto_approve` claim is F104.
- **`prompt-slots-and-roles`:** 16 shipped roles, not 14.
- **`secret-boundary`:**
  - §0's four `HOME` exports **worked** this round;
  - §5's `notes.md` write probe is wrong (`write_file` is unguarded by design; drive `memory_write`);
  - §4: grep the fixture *body*, not only `BEGIN PRIVATE KEY`, and use a realistic key;
  - §6's blackhole row is undrivable: `Oracle::SecretRead.tier` hard-codes `localhost:11434` and
    `qwen3:4b`, with no endpoint seam.
- **`changeset-review`:**
  - scopes are `cumulative|commits|by_directory`, not `whole|by_commit`;
  - the default base is hard-coded `main` (V2);
  - §6 is F108;
  - §0's `git rm bin/../bin/tally` deletes nothing.
- **`subagents-and-backends`:**
  - the chat subagent tool is one-shot only (actor mode is wired just for the epic orchestrator), so
    §3's actor, nested-spawn-at-a-third-path and depth-cap checks are unreachable from chat;
  - leases are random-id paths, not worker-id keyed, so there is no reap-before-add;
  - gc **keeps** a dirty crashed lease for 7 days rather than discarding it;
  - under podman there is no daemon to stop.
- **`memory-and-dogfood`:**
  - `improvement_write` is not in a chat toolset (only `lain improve` writes);
  - §4 is F98;
  - the sweep numbers are identical to round 15.
- **`rails-blog`:**
  - Rails 8.1.3.1 installs in 26s;
  - a `.bundle/config` `path` makes `bin/rails` work with **no `GEM_HOME` in lain's environment**,
    which sidesteps P9;
  - §0's composed strategy is blocked by F89.
- **`ollama-cloud-arm`:** §3's window is confirmed; there are 23 `CLOUD_WINDOWS` rows, 2 retired
  (F126).
- **`epic-tier`, `survey`, `shell-terms`, `shell-term-approval`:** the fork reports carry theirs.

---

## Coverage — the directory listing is the authority: 18 scenarios

| scenario | driven | what, and the reason for anything not driven |
|---|---|---|
| `session-and-window` | **yes, all §1–§9b** | pass. The `lain up` pipeline pre-flight was driven for the first time |
| `rust-cli` | **yes** | driver oracle pass. Compile error at exit 101 intact; `lain://journal` populated. Ctrl-C mid-call not driven (budget) |
| `bowling-ruby` | **yes** | 5/5 oracles; wedge, fork (head + mid), resume and control all exit 0; 0 unresolved causal refs |
| `cockpit-surfaces` | **mostly** | §1–§4b, §5b, §7 and §8 (fold shape) pass. §5 notifier: moot (P36). §6: invalid-UTF-8 prime passes, but the planted name never reached a view until F88/F103; `lain://status` epic defence was not driven here (fork §11 drove the buffer). §8 continuation-line: not driven (budget) |
| `bench-arms` | **refused, capability** | F110. No `ANTHROPIC_API_KEY` (checked); the router arm refuses ollama and ollama-cloud |
| `failure-injection` | **mostly** | §1, §2, §3 (three doors × dangling / malformed / turn), §4, §5, §6, §7 (stderr **0 bytes**), §8, §9 steps 1–4, §10 constants and §11a/b/c driven. §1a/§1b counts-absent proxy not driven (budget). The §3 supervisor door is unreachable from chat (no actor path). §9 step 5 was lost to F90. §10's upper bound (a 5 MiB `web_fetch`) not driven (network/budget). §12 was replaced by `provider_wait` + F95's control |
| `repl-commands` | **yes** | §0–§9. Not driven: §2's ambiguity refusal (unreachable), §2's pin-survives-compaction effect (budget), the §3b write-set caveat (F107 blocks it), and §4's actor-running `/keep` refusal (no actor path) |
| `prompt-slots-and-roles` | **yes, §1–§4, §6 free half** | §6's paid half: capability gap, no `ANTHROPIC_API_KEY` (checked) |
| `epic-tier` | **fork, mostly** | `finish` is a capability gap (`gh auth status`: not logged in). `--width 2`, Ctrl-C between issues and stale attach token not driven (budget) |
| `survey` | **fork, all** | 0 new defects, 2 LOW; F67, F68 and F56 fixed |
| `shell-terms` | **fork, first drive ever** | all but §9 (no Anthropic key; void anyway until F92) |
| `shell-term-approval` | **fork, all** | §4b is owned by secret-boundary §5 |
| `secret-boundary` | **yes, §0–§7** | §6's blackhole row undrivable (no endpoint seam) |
| `changeset-review` | **yes, §0–§8** | §5 notes on both sides, strict/permissive, parser; §6 = F108; §7 instant refusal (no strace) |
| `subagents-and-backends` | **yes, §1, §2, §3 (one-shot lease), §4, §5, §6** | actor/nested/depth unreachable from chat; the docker timeout (`sleep 600`) not driven (budget); window-close-doesn't-kill not driven (children had finished) |
| `memory-and-dogfood` | **yes, §1–§6** | §2's refusal read through the library, not a live 300 KiB write |
| `rails-blog` | **yes, partly** | Blog built and graded (30/43/0). §1 compaction at scale **not reached**: session 1 stalled on F89; session 2 (read-only volume) hit F82's `nothing_droppable` at 31,935 tokens, with F95 making each turn ~60s. §2 max result 6,578 B (round 14 already reached §2). §3 gate under volume, §4 ceiling and §5 `lain friction` driven (cacheless wording correct, no paths). `/model` mid-session not driven |
| `ollama-cloud-arm` | **yes, §1–§5** | 3 completions spent (one wasted on the model's `limit: -1`). §6 saturation skipped on its own advice |

---

## Negatives

| check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-09-14T17:15:35Z'` | **0** (control `-newermt 2026-09-01`: **1243**); forks also 0 |
| `env -u XDG_CONFIG_HOME git -C "$LAIN_REPO" status --porcelain` vs baseline | **identical** (` M references/repos/smolagents`, `?? sites`) |
| `ls -d $LAIN_REPO/.lain`, `ls -d ~/.lain` | **absent** |
| `dunstctl count displayed` / `waiting` | **0 / 0** |
| stray processes / ports | one `pathcount.rb` on :21436 found and killed. `puma` on :3000 killed mid-round. No lain/nvim from any round socket. `podman ps -a` empty. `fleet` worktrees back to one |
| `OLLAMA_API_KEY` bytes in any journal, WAL or output | **0** (checked with the value, never printed) |
| secret-boundary §7 grep outside the fixture | hits only in: the driver's own typed `AKIA…` prompts and `memory_write` input; the `/mode auto` cat (known-open); the pane capture log; and the Reline input history. No hit from any masked `read_file` path. The driver's generated real keys were deleted |
