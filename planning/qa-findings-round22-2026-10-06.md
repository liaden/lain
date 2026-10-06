# QA round 22, 2026-10-06

## Summary

A full round over **all 18** scenarios in `planning/qa/scenarios/`, driven in 10 contexts: 9 forks (`a` to `i`,
each with its own sandbox, tmux socket and port range, at most 4 running at once) and this context, which drove
`bench-arms`' refusals and investigated two forks' findings. **The user wound the round down at about 17:20 UTC**,
before the coordinator's live items ran, so `bench-arms`' live runs, `secret-boundary` §6's live oracle and
`rails-blog` §5's `/model` switch were not driven, and forks `d` and `i` stopped mid-scenario. Every scenario was
driven in part, and every gap is named in the coverage table.

**Round 21's fix plan mostly holds on its routes.** B-1 (closing an input pane), Fh-1 (the directive at message 0
survives the handoff), A-1, A-2/H-2 (a stopped `bash` is killed on both arms and under docker), C-1 to C-4, E-1,
E-5, E-6, G-1, G-2 (survey), G-3, G-5, G-6, G-7, G-8, D-1/B-3 and H-1 (for the 9 listed names) are all fixed.

**What is new is mostly the same pattern as every recent round: each fix closed one route and left the class open
one route over.**

- **F-6 (HIGH):** an ordinary advance cut summarizes the prompt of the ask that is still running.
- **D-4 (HIGH):** a docent on a local-branch changeset sends an unreleased credential to the model and the journal.
- **S-1 (MED-HIGH, 4 contexts):** H-1's name check lives only in `ComposedTerm`, so `read_file`, the survey corpus
  and a secret-named directory all still release low-entropy secrets.
- **T-1 (MEDIUM, 4 contexts):** malformed model output (a cut tool-call burst, a prose call, a bare `<tool_call>`)
  is still committed to the chain on 3 routes C-3's fix did not cover.

| id | sev | what |
|---|---|---|
| **F-6** | **HIGH** | an advance cut at `size - keep_last` summarizes the running ask's own prompt; the model then works from a summary that lost its instructions |
| **D-4** | **HIGH** | a docent on a local-branch changeset gets the raw hunk: an unreleased token reaches the model and the journal, while a note on the same line is masked |
| S-1 | MED-HIGH | `password.txt`, `secrets/prod`, `credentials/x` with low-entropy content: `cat` of a secret-named directory auto-approves, and `read_file` and the survey corpus release all of them |
| F-3 | MED-HIGH | a line typed during an ask is silently cut to 4,095 bytes (the kernel's cooked-mode line limit) |
| T-1 | MEDIUM | malformed model output still reaches the chain: a `max_tokens` cut after complete calls, a prose call after it is detected, a bare trailing `<tool_call>` |
| U-1 | MEDIUM | one invalid UTF-8 byte in a project's memory store kills every `lain chat` and the live `lain consolidate` with only `string is not valid UTF-8` |
| X-1 | MEDIUM | `--non-interactive` output is erased on a terminal: the alternate screen is entered unconditionally |
| A-9 | MEDIUM | an `:inherit` child (`/meta`) gets the parent's raw chain, not its compacted view, and is refused over the window |
| A-1 | MEDIUM | `bench variance` refuses any healthy session that had a per-result summarizer call |
| A-6 | MEDIUM | E-2 is said, not prevented: after `/rewind` onto a stranded prompt, the next line folds into it and a `write_file` re-runs |
| C-2 | MEDIUM | plain chat: approvals that park together are shown one at a time, but each 300 s timeout starts when it parks |
| F-1 | MEDIUM | `84adc3a5` refuses 2 of 8 overlapping strategy spellings at launch; the other 6 tear an ask with `Overlap` |
| F-4 | MEDIUM | elided attestations carry no tool name or path, so Fh-2's fix never runs under `elide-tools+summarize-conversation` |
| F-8 | MEDIUM | a handoff that cannot make room is still committed, replacing all history, and the ask is refused anyway |
| G-n3 | MEDIUM | G-4 one route over: a retried red step reuses its spawn address, and `lain://status` shows the running retry as `failed` |
| M-1 | MEDIUM | `bench arms` refusals for a missing fixture, a malformed fixture and an unknown `--isolation` leave the 159-byte journal (BA-1's second half one route over) |
| the rest | LOW to LOW-MED | itemised under "Per-context findings" |

## The HIGHs

### F-6: an advance cut summarizes the running ask

`Compaction::Boundary#snapped` (`lib/lain/compaction/boundary.rb:114`) places the cut at
`[messages.size - keep_last, 0].max` and moves it only to avoid splitting a tool pair. Nothing keeps the running
ask's prompt out of the dropped span. The handoff does keep it ("the ask itself", `ARCHITECTURE.md:415`), so the 2
strategies disagree about what an ask's prompt is worth.

**Evidence (fork `f`, 2 of 2):** an ask listing 12 files to audit ran past about 10 tool rounds. In the first
run, the list was summarized as "an audit was performed… no specific findings", and the model then read files
that were not on the list and skipped 2 that were. In the second, the list survived but the summary said no file
had been read. **Exposure:** with the default `keep_last` of 20, any ask over about 10 tool rounds.
**Coordinator check:** read `boundary.rb:105-120` and `ARCHITECTURE.md:409-425`; the asymmetry is as described.
**Fix shape:** clamp the cut at or before the running ask's first message, as the handoff does, and journal
`would_not_shrink` when that leaves nothing droppable. Pin it with a spec where `keep_last` is smaller than the
ask's own tool rounds. Evidence: `~/tmp/lain-qa-2026-10-06-f/records/fork-report.md`.

### D-4: a changeset docent sends an unreleased credential raw

`579ed4ea` (round 21's G-2 fix) quotes the asked-about line from the diff hunk, on the assumption that the hunk
is already masked. A survey masks its hunks; a local-branch review does not. Only a note's `anchor_text` is
masked (`review/source.rb:284-316`).

**Evidence (fork `d`):** a note on `creds.rb:2`, which holds a token never read or released, then a docent
question on it. The brief carried the raw line, hunk and context; the docent answered with the value; the value
appears 6 times in journal `sessions/121f2e1bbc61/20261006T162438-684397.ndjson`. **Controls:** 0
`read_released` records for `creds.rb`, and the note on the same line journaled `<redacted:1>`. The docent child
then parked a release prompt for bytes it already had. **Fix shape:** project the changeset's hunks through the
same masking the survey uses before any brief is built. Pin it with a docent spec over a changeset holding a
detector-positive line.

## The secret-name class (S-1), found by 4 contexts

`64de0b59` added a filename hint to `ComposedTerm` (`board_build.rb:409-420`) and nowhere else, and it tests the
basename only.

| route | result | context |
|---|---|---|
| `cat nameonly/password.txt` | parks (fixed) | `h`, `d` |
| `cat secrets/prod` (also `.secrets/`, `credentials/`, `private/`, `auth/`) | auto-approved, `hunter2` reaches the model | `h` |
| `read_file password.txt` | returns the bytes with nobody asked | `d`, `h` |
| `read_file secrets/prod` | returns `hunter2` | `h` |
| survey corpus over `password.txt`, `secrets/prod`, `credentials/x` | listed raw, so a docent brief would carry them | `i` |
| `cat AUTHORS` | parks (over-reach: "auth"); control `cat README` approves | `d` |

`Sensitivity` classifies all of them `ordinary`, so `bash` and `read_file` now disagree about the same file.
**Fix shape:** move the name hint, including directory components, into the `Sensitivity` table, where the gate,
the listing filter and the survey all read it, and drop it from `ComposedTerm`. Anchor the hint on whole words so
`AUTHORS` does not match.

## Malformed output on the chain (T-1), found by 4 contexts

`53228d8f` (round 21's C-3) journals a tool call cut at `max_tokens` only when no call in the reply completed.

- **C-1 / F-2:** a burst cut at `max_tokens` after some complete calls is journaled `stop_reason=tool_use`, keeps
  the cut `<tool_call>\n<function=…` as text, and writes no `malformed_response`. `decoding.rb:127` handles only a
  cut with no complete calls, and `:235` returns `tool_use` before reading `done_reason`. A hand curl confirms
  ollama sent `done_reason "length"` with 3 calls. 3 of 3 with `--max-tokens 70`; at the default cap, one ask for 2
  `touch` calls became 170 tool calls (`c`).
- **A-8:** a prose tool call is detected and said on screen, then committed and sent back. The next 2 requests
  carried 1, then 2 `<function=` messages, and the model repeated it. Control: after a restart, the same 3 prompts
  made real calls (`a`).
- **E-5:** a bare trailing `<tool_call>` at a normal stop is kept as answer text: in a parent's answer, in a
  child's result (`42.<tool_call>`), in an `improve` report, and in a chat answer. The cut detector runs only on
  `done_reason: length` and the prose detector needs a closed envelope (`decoding.rb:89`, `:126-128`) (`e`).

## Per-context findings

Full text, repros and evidence are in each fork's `~/tmp/lain-qa-2026-10-06-<x>/records/fork-report.md`.

| ctx | scenarios | findings |
|---|---|---|
| a | session-and-window, rust-cli, repl-commands | A-1 MEDIUM (`Provider::Journaled` wraps the summarizer tiers, `backend.rb:701`, `summarizer.rb:50`, `span_summarizer.rb:122`, so its `request_sent` breaks variance's 1:1 guard); A-6 MEDIUM; A-8 (T-1); A-9 MEDIUM (`spawn_policy.rb:96-115`, `Inherit#base_timeline = parent.fork`); A-3 LOW-MED (`--compact-keep 0` is an `ArgumentError` traceback; a refused `--compact-strategy` leaves a session file); A-2 LOW UX (`--api-base` beside `--provider anthropic` accepted and ignored); A-4, A-5, A-7 LOW UX (stacked header lines, `/rewind` calls ran calls "parked", `/introspect` says `0.0%` where the bench says "not measured") |
| b | bowling-ruby (5/5), cockpit-surfaces | U-1 (first found here); B-3 LOW-MED UX (the live header is drawn one row high, `input_pane.rb:247-257`, over the echoed line; 2 HUDs disagree); B-4 LOW-MED (after kill-pane and `lain input --name`, `@lain_input_pane` and the floor hook name the dead pane; `up.rb:356` re-arms on it); B-5 LOW (a child's answered question journals 2 `questions_consumed`, `ask_human.rb:827` and `scribe.rb:351`; reproduced by `g`); B-6 LOW (`Fleet::Row.clamped` appends after an overflowing wide char); B-7 to B-10 LOW UX |
| c | failure-injection, prompt-slots-and-roles | C-1 (T-1); C-2 MEDIUM (`approval_policy.rb:151`, `queue.rb:392`; the arrival notice is wired only in a cockpit, `approval_surfaces.rb:93-97`); C-3 LOW UX (`decided by abandoned`); C-4 LOW UX (corpse remedy lacks `-L S`, `up.rb:665`); C-5, C-6 LOW UX; r21 C-6 not fixed |
| d | secret-boundary, changeset-review (partial) | D-4 HIGH; D-1 (S-1); D-3 LOW-MED (a broken glob like `[abc` in a `sensitivity` rule loads and matches nothing); D-2 (S-1 over-reach); D-5 LOW UX (`/exit` answers `unknown skill` with a Symbol array, no `/quit`; also `g`'s G-n2); D-6 LOW (`a aws access key id`) |
| e | subagents-and-backends, memory-and-dogfood | U-1 one route over (live `consolidate` dies too; dry runs, `improvements`, `bench sweep`, `worktrees gc` survive); E-5 (T-1); E-2 LOW-MED UX (`lain watch` shows an answered and a killed child both `(stopped)`, `lineage.rb:99-103`); E-1 LOW (r21 E-9: refused launches still start `worktrees gc`); E-3 LOW (r21 E-7: deterministic 500 retried 4 times); E-6 LOW (`improve` stored 2 identical notes); E-7 LOW gap (a crashed lease moved to `retained/` is not journaled); r21 E-8 not fixed (16,397 against 16,384) |
| f | rails-blog | F-6 HIGH; F-3 MED-HIGH (`stdin_pump.rb:23-27`; a 9,939-byte line committed at 4,095 with no notice, 45,025 bytes whole at an idle prompt); F-1, F-2 (T-1), F-4, F-8 MEDIUM; F-5 LOW-MED UX (`--no-nvim`: a paste during `[y/N]` is read as "no" and discarded); F-7 LOW-MED UX (Fh-3 one route over); F-9 LOW-MED, inference (the `collapse` cut looks unreachable in a forward run: 17 cuts, 0 collapses) |
| g | epic-tier, ollama-cloud-arm | G-n3 MEDIUM (`c848b304` covers named lanes only; red step runs in the run's own lane, `tools/subagent/lineage.rb` `adoptable?`); G-n1 (X-1); G-n2 LOW UX (`/exit`, as D-5); G-n4 to G-n7 LOW (`epic land <sha>` reports the lock; `keep` offered when it is a dead end; only the first of 2 typos reported; an empty `sessions/<hash>/` after a config refusal; `/implement-epic` exits 0 with all 8 issues refused); r21 G-10, G-11 not fixed |
| h | shell-terms, shell-term-approval | S-1 (directory route, read side); X-1 (as H-3: `frontend/tty.rb:148-160`); H-2 LOW-MED gap (single-label hosts `http://metadata/` pass the `web_fetch` floor and a public 302 to one was followed to `getaddrinfo`; not reachable on this box, which has no search domain) |
| i | survey (partial) | S-1 (corpus route); I-2 LOW UX (the docent says "line 3", masked numbering, while the thread header says `keyed.rb:8`) |
| me | bench-arms (refusals only) | M-1 MEDIUM (below); M-2 LOW-MED UX (a malformed fixture refuses as a `Psych::SyntaxError` backtrace); M-3 LOW UX (`--journal` under an unwritable parent is an `Errno::EACCES` backtrace from `exe/lain:817`) |

### M-1: three `bench arms` refusals leave a journal

Exit 1 in each case, but `x1.ndjson` holds 159 bytes, 1 `capability_degraded` record. **Mechanism:** `ArmTasks.new`
is lazy (`bench/arm_tasks.rb:83-89`) and is first read at `bench/cli.rb:253`; the isolation name is resolved inside
`arm_report`. Both happen after `journaled_provider` writes the record (`bench/cli.rb:238`, `:597`), and the close at
`exe/lain:769-772` discards only a journal nobody wrote to. **Control:** the 4 refusals that fire before `:238` (no
`--isolation`, `--isolation` without `--journal`, no `--cheap-model`, cheap equal to model) and `--isolation none`
leave no file. **Fix shape:** load the fixture and resolve the isolation name before building the provider, or open
the journal lazily. **Repro:** `~/tmp/lain-qa-2026-10-06/records/arms-refusals{,2,3}.sh`.

### Withdrawn on the mechanism

- **`b`'s B-1, "the first `tmux attach` ends the session" (filed MED-HIGH), withdrawn by the coordinator.** The
  attach ran under util-linux `script` with a stdin that closed, and `script` turned that EOF into a typed Ctrl-D,
  which tmux delivered to the active input pane. A Ctrl-D there sends an `eof` frame (`input_pane.rb:345`) and ends
  the chat by design. Controls: `script` with stdin held open by a pipe survives 8 s; a `pty.fork` client that never
  writes survives; `tmux send-keys -t <input pane> C-d` on a headless cockpit ends the session in 2 s.
  Scripts: `~/tmp/lain-qa-2026-10-06/records/attach-probe{,2,3}.sh`.
- `a`: Ctrl-C at an idle `you>` ends the chat (documented, `docs/commands.md:49`); `web_fetch`/`web_search` run
  unapproved by design; a gated `cat server.pem` under `/mode auto` streaming to the chat pane (documented scope; 0
  key bytes in the session file).
- `c`: summarizer oracle `Admission::Busy` (documented); exit 0 from a failed `--prompt` run (the REPL ending on EOF).
- `f`: a bare `you>` mid-ask (the driver's own bracketed paste).
- `h`: an untrusted broken config refusing on syntax (trust is keyed on content, `project/trust.rb:11-13`).

## Round-21 defects re-checked

| id | verdict | evidence |
|---|---|---|
| B-1 (closing an input pane ends the chat) | **FIXED** | `b`: second client and primary pane killed, chat alive, 0 `session_closed`; respawned pane redraws |
| B-1's route over (a pane whose pty vanishes) | **FIXED** | `b`: `kill-server` idle, all exit; mid-ask, `grace_expired` at exactly 60 s. The 4 orphans found at round start predate `8ce8403c` |
| Fh-1 (handoff drops human turns) | **FIXED** | `f`: the directive at message 0 (OKAPI/SQLite) survives; no PostgreSQL |
| A-2 / H-2 (stop does not kill `bash`) | **FIXED** | `a`, `h`, `e`: string arm no file 25-30 s after `s`; term arm gone in 2 s; docker container gone in 1-7 s |
| A-1 (`/stop` after an nvim approval) | **FIXED** | `a` 50 ms, `b` 4 ms |
| C-1, C-2, C-4 | **FIXED** | `c`, `b`; C-2 better but answered through a handoff where ordinary compaction had room (`f`, `agent.rb:666`) |
| C-3 (cut tool call) | FIXED on its route; T-1 one route over | `c`, `f`, `a`, `e` |
| H-1 (credential names) | FIXED for 9 names on `bash`; S-1 one route over | `h`, `d`, `i` |
| E-1, E-5, E-6 | **FIXED** | `e` |
| E-3, E-4 | not reached | `e`: no clerk wrote a closed prose envelope; no pass hit the ceiling |
| E-7, E-8, E-9 | NOT FIXED | `e` |
| E-2 (`/rewind`) | said, not prevented | A-6 |
| G-1, G-6, G-7, G-8 | **FIXED** | `g`: red commits `155addf`, `e79e0d7`; landed `e9a0eff` in `landings/demo`, operator checkout untouched |
| G-2 (docent brief) | FIXED for a survey; D-4 on a changeset | `i`, `d` |
| G-3, G-5 | **FIXED** | `b`, `i` |
| G-4 | FIXED for named lanes; G-n3 on the red step | `g` |
| G-9 / Fv-4, G-10, G-11 | NOT FIXED | `i`, `g` |
| D-1 / B-3 (thread anchors) | **FIXED** | `b`, `d`; residue B-10 (an old thread window stays open) |
| B-2 (frozen header) | DIFFERENT, partly better | `b`: live, but drawn one row high (B-3) |
| B-4 | selection FIXED | `b`, `i` |
| Fh-3 | FIXED on its route; F-7 one route over | `f` |
| Fh-4 | on screen now, still not journaled | `f` |
| Fh-5, RB-1, RB-2 | **FIXED** | `f` |
| Fh-6 | FIXED on its spelling; reachable through F-1 | `f` |
| Fh-7 | NOT FIXED (not in the fix plan) | `f`, `b` |
| 84adc3a5 (two whole-span strategies) | 2 of 8 spellings | F-1 |
| F23 | **FIXED**, with control | `b` |
| A-3, F133 | **FIXED** | `d` |
| r21 D-2 (`read_file` on a link loop), r20 D-5/D-6 | unchanged | `d` |
| r21 A-4, A-5, r20 A-4, A-5 | NOT FIXED | `a` |
| r21 C-5, C-6 | NOT FIXED | `c` |
| BA-1 second half (refused run leaves a journal) | FIXED on its 4 routes; M-1 on 3 more | coordinator |
| M-1 (bench grades a malformed stop) | not driven | the live runs were cut by the wind-down |

## Model behaviour (not lain defects)

- Prose tool calls and bare `<tool_call>` tokens, in every context that ran a model (and T-1 is what keeps them on
  the chain).
- Reading memory items instead of calling `bash`, 3 explicit "call bash now" prompts in a row (`b`).
- Answering "reply ok" by starting the research-epic skill (`g`), and ending every `/goal` in iteration 1 (`a`).
- Running `bin/rails server -d` unasked (`f`), which daemonised puma outside tmux.
- Refusing from context instead of calling the tool (`a` §6), and claiming specs pass while 4 of 6 were red (`b`).

## Environment and process

**Box.** ollama 0.34.4 from `/mnt/nvme/opt`, pid 252763 (started 2026-10-03 16:52), `n_slots = 1`,
`OLLAMA_NUM_PARALLEL:1`, cold at round start, `qwen3-coder:30b ctx=32768` resident at close. Load stayed between
1.7 and 3.5 with 4 forks. No OOM, no runner re-key reported.

**At round start**, 4 `exe/lain input` processes from a 07:58 spec run were alive for 3 h 11 m with their pty and tmux
server gone, at about 0.2% CPU each. They predate `8ce8403c`; fork `b` showed the current binary exits. Killed by pid.

**Process lessons, folded into `planning/qa/method.md` under "Round 22":**

- Pass `--model qwen3-coder:30b` explicitly, every launch: `.envrc` resolved `qwen3:4b` (`b`).
- Never attach to a headless cockpit with a stdin that can close (`script ... </dev/null`): the EOF arrives as a
  Ctrl-D and ends the chat. Hold stdin open, or use a client that never writes.
- A gate that approves by command shape must refuse `rails server -d` and anything that daemonises. Round 17
  learned this, and fork `f` approved one again; its close-out then said no server had started. Take `ss -ltnp`
  over the round's ports at the fork's own close-out, not only the coordinator's.
- A gatekeeper must match each parked row on its own full text and refuse an elided row (`g` approved 2 calls the
  buffer had cut off). `g`'s `records/gatekeeper.rb` does this and is worth promoting.
- `drive.sh` refuses only while an approval is parked; a parked question lets the next prompt in as a held line (`d`).
- Paste with `paste-buffer -p` and no trailing newline, or a file becomes 1 prompt per line (`f`).
- With `env.sh` sourced, `git status` loses the operator's global excludes; run the repo negative with
  `env -u XDG_CONFIG_HOME` (`f`).
- A docker chat leaves podman's `catatonit` pause process under the sandbox runtime dir. 2 from round 21 (`e`, `h`)
  were still alive today; kill them at close-out.
- A heavy fork still runs out of turns: `a` and `b` hit 200, `g` went past it on interim notifications. 2
  scenarios per fork is the ceiling.

**Scenario corrections proposed** (not applied; each fork report lists them in full): `cockpit-surfaces` §0 check 2,
§4b, §5 (3 `bash` calls park one at a time, `tool_runner.rb:179-202`), §5 "retires exactly once", and its Ctrl-C at
`you>` line (`a`); `prompt-slots` §6 (tool schemas are 19,619 bytes on the wire, so the request is not under the
floor); `secret-boundary` §2 (25 entries, not 20), §4, §5c, §7; `subagents-and-backends` §2; `memory-and-dogfood` §4;
`epic-tier` §2b, §5a, §8, §10c, §10e, §12, §13b; `ollama-cloud-arm` §1, §3; `shell-terms` 4 stale claims and 3 new.

## Coverage: all 18 scenarios

| scenario | ctx | driven | not driven, and why |
|---|---|---|---|
| session-and-window | a | §1 to §9b on the ollama arms | §6 Anthropic wire half: `ANTHROPIC_API_KEY` unset, `.envrc` exports 0 `ANTHROPIC*` |
| rust-cli | a | one-shot, compile errors, Ctrl-C and `s`, ceiling | 2 gated calls in 1 turn never occurred |
| cockpit-surfaces | b | §0 to §8, both §5 postures, bell, `/inbox` at `command>` | detach/reattach (lost to the withdrawn B-1); re-arm over an older binary (none); plain guards 2 to 4, §7 GOAL mid-drive (budget); AA (method forbids) |
| bowling-ruby | b | §1 to §3, oracle **5/5**, F23 with control | `/meta summarizer` (budget) |
| bench-arms | me | 13 pre-spend refusal rows | **live runs 1 and 2, the M-1 named-failed-cell check, variance and set-aside: wound down by the user** |
| failure-injection | c | §1 to §12, both §12 controls, §11c with an attached client | §3 supervisor door (`Supervisor::Restart` has no caller); §8 `lain-core` (no build); §9 step 4 (16 KiB windows; reached in aggregate); §10 upper bound (unreachable by construction) |
| rails-blog | f | §0 to §5, sticky cut, handoff, Fh-1 | §1b `collapse` (F-9); `/pin` in a held range (open decision); **§5 `/model` switch: deferred to the coordinator, then wound down** |
| repl-commands | a | §0 to §9, first live `:LainGoalOff` | `/goal` cap (model ends in iteration 1); `/pin` ambiguity (~300 turns); pin under compaction (volume); `/keep` actors (no chat path) |
| epic-tier | g | §0 to §9, §10a, §10b, §10d deny, §10e, §12, §13a, §13c, §13b live | §11 without `--epic`, §13b second gc (budget); §11 fold failure inconclusive; `finish` (forge, by decision); adjudicated APPROVE never reached |
| secret-boundary | d | §0 to §5c, §7 | **§6 live oracle: needs `qwen3:4b`, deferred to the coordinator, then wound down**; §5c worktree-worker row (budget) |
| changeset-review | d | §1 to §4, §8, most of §5 | **§6 `/critique`, §7 `/review-submit`: wound down by the user**; `--permissive` re-open marks inconclusive |
| subagents-and-backends | e | §1 to §6 | actor mode, depth cap, nested third path (no chat path); daemon-stopped negative (podman has no daemon) |
| memory-and-dogfood | e | §1 to §6 | `StaleEmbeddings` (`bench sweep` has no `--model`); missing corpus (needs a repo edit); resumed-chat check, legacy authorless row (budget) |
| ollama-cloud-arm | g | steps 1 to 5, 6 paid completions | step 6, 429 saturation (by decision, burns quota) |
| survey | i | §1 to §6, §7 checks 1 to 6 and 7's line-8 half; `lib` 906 files, 187,968 lines | **§7 thread inside the key, quit with a docent running, docent on `password.txt`: wound down by the user** |
| prompt-slots-and-roles | c | §1 to §4b, §6 free half | §5 (spec-covered by its own text); §6 paid half (no Anthropic key) |
| shell-terms | h | §0 to §8 | §9 paid half (no Anthropic key) |
| shell-term-approval | h | §0 to §3a, §4a, §5 to §8, §10, §11 | §4b (owned by secret-boundary); §9 (history) |

Halves marked **Automated by** were skipped and rest on `spec/e2e`.

**Close-out negatives**, taken at 17:29 UTC with `XDG_*` unset and `HOME=/home/tara`:

- `find /home/tara/.local/state/lain -newermt 2026-10-06T15:09:37Z` = **0**; positive control (`-newermt 2026-09-01`) = **1322**.
- `git status --porcelain`: the baseline ` M references/repos/smolagents`, plus this file, `method.md` and `README.md`.
- `ls -d /home/tara/dev/lain/.lain` and `~/.lain`: neither exists.
- `dunstctl count displayed` / `waiting`: 0 / 0.
- No round tmux server is live; no `exe/lain` or sandbox nvim remains; 0 `lain` containers.
- **Found and killed by pid:** fork `f`'s daemonised puma on :3000 (`blog`, started by an approved `bin/rails server -d`
  at 16:09 UTC), fork `e`'s `catatonit`, and 2 `catatonit`s left by round 21's forks `e` and `h`. The operator's own
  podman pause process (pid 17324, since 2026-10-03) was left alone. Afterwards nothing listens on 3000, 3060 or
  21500 to 21599.
- Sandboxes `~/tmp/lain-qa-2026-10-06` and `-a` to `-i` are left in place as evidence.
