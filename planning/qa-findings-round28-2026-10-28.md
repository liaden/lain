# QA round 28, 2026-10-28

## Summary

This was a full round over all 22 scenarios in 13 forks (`a` to `m`), at most 4 at once, against `955cf59b`. Each fork had its own sandbox, tmux socket and port range. That tree is 452 commits past round 27's `b5de73a4`. It carries the round 27 fix plan (T1 to T29), simplify-15 and simplify-16 (the carrier and record refactor), and the first half of simplify-08 (the bench's real toolset and new subcommands). Every scenario was driven and none was dropped. `bench-arms` ran last with the local GPU to itself. The shared server had `OLLAMA_NUM_PARALLEL 1`, `OLLAMA_CONTEXT_LENGTH 32768` and `LAIN_NUM_BATCH=2048` throughout. No Anthropic key was set, so every paid Anthropic half is "not reached".

**Round 27 is fixed where it was planned.** Both HIGHs are fixed. b27-4 was re-checked by 5 forks on every trigger: mid-ask, at the ask, at idle, under the 2 new strategies, in the cockpit and on the cloud arm. l27-2 is fixed too, with 32 grades under `--confine reader`. The MED-HIGH l27-4 is fixed in effect. Of the 15 round 27 MEDIUMs, 11 are fixed. 2 got worse: b27-1 (now b28-1) and h27-4 (now h28-3). 2 were not reached (h27-2, i27-5). Every LOW the fix plan left is still open, as recorded.

**What is new sits in 4 places:**

- **The `workspace` sandbox disagrees with the approval layer** (forks c, e, k and l, independently). An allow from the judge or a remembered rule runs under `workspace`. That profile cannot exec a program from mise or `~/.cargo` when the command takes the string arm, and every `bundle exec`, `npm test` and `ruby -e` does. It cannot read a `related` directory either. A human's own "always" answer is refused on every run, and the model is told to "ask the human to approve it". A read refusal never reaches the model as a sandbox refusal, and the bench journals the refused call as clean. The repo's own `bin/workspace-run` passes on the exact commands a chat refuses.
- **Memory with `sources` makes a project unresumable** (i28-4, HIGH). Once one `lain consolidate` or `memory_write` stores an item with `sources`, every later session in that project refuses `--resume`, `consolidate`, `improve`, `bench variance` and `compaction-sweep` with "the recorded view has been edited".
- **The secret boundary fails closed in the wrong place.** An approved release of a `.env` that existed at launch is refused at egress, which wedges the chat until `/rewind` (g28-3, introduced 2026-10-26). A declined release can never be undone (g28-1). Every lockfile read waits on a human, because every gem checksum is a "secret" (g28-2).
- **Records that say the wrong thing.** A crash that escapes, b27-4's kind included, is journaled `session_closed reason exit` (j28-4). A parked implementation gate is read by `land` as a denial (h28-3) and shows the human no test result (h28-4). A cloud chat summarizes on the local `qwen3:4b` with nothing said (x28-1). That swapped the shared runner twice this round and is how the round found it.

| id | sev | what |
|---|---|---|
| **i28-4** | **HIGH** | a memory item with `sources` makes every later session in the project unresumable; replay rebuilds items without `sources` |
| k28-4 (with c28-1, l28-7) | MED-HIGH | a judge- or rule-approved string-arm command under `workspace` cannot exec mise or `~/.cargo` programs; a human's "always" is refused every time |
| g28-3 | MED-HIGH | approving the release of a `.env` present at launch is refused at egress and wedges the chat until `/rewind` |
| b28-1 (with f28-3) | MEDIUM | keys plus a Ctrl-C in 1 write lose the keys and end the chat, cockpit and plain chat (b27-1, worse) |
| k28-1 | MEDIUM | `workspace` and `reader` cannot read a `related` directory, and the refusal reaches the model as a plain "Permission denied" |
| l28-8 | MEDIUM | the bench journal records a sandbox-refused exec as `refused []` |
| j28-4 | MEDIUM | a raising user middleware kills the chat; any escaped crash is journaled `session_closed reason exit` |
| j28-2 | MEDIUM, security UX | trust keyed on `config.rb` bytes follows a `load` of a sibling file into any repo with the same bytes |
| h28-3 | MEDIUM | `land` reads a parked implementation gate as a denial and tells the human to re-run the issue (T17's filter) |
| h28-4 | MEDIUM UX | a parked implementation gate shows no test result; an errored suite was approved with nothing on screen |
| c28-2 | MEDIUM | the round budget withholds reads from about 80% of the window; compaction cannot fire before 87.5% |
| c28-3 | MEDIUM | an over-window prompt is refused when a handoff would answer it (RB-3 on a new path) |
| c28-4 | MEDIUM UX | eliding a tool call drops the prose answer that shares its message |
| g28-1 | MEDIUM UX | a declined or lapsed release is final for the session, and the model is still told to ask |
| g28-2 | MEDIUM UX | every lockfile read parks: Gemfile.lock 110 regions, yarn.lock 2033 (with c28-6) |
| b28-2 | MEDIUM, ruling | `x` marks a never-opened review row as reviewed once anything loaded its hunks |
| x28-1 | MEDIUM UX | a cloud or Anthropic chat sends eager summaries to the local `qwen3:4b`, with no notice and no header field |
| the rest | LOW to LOW-MED | itemised under "Per-fork findings" |

**Rulings asked for:**

- **b28-2:** does a row count as read when lain computed its hunks, or only when a human opened it?
- **x28-1:** should the summarizer follow the chat's provider, or stay local and be announced?
- **j28-2:** may a trust grant cross projects?
- **b28-6:** should a lapse ring the bell a second time?
- **k28-4 family:** should an allow on the string arm grant the resolved programs, or should the refusal route to a human?

**An incident.** Fork b's `$QA` came up empty in a zsh subshell (`source env.sh | grep ...`). At 08:27, `git add -A && git commit` therefore ran in the lain checkout. No commit landed, because the hook's `cargo test` failed. The hook's end-of-file and whitespace fixers did rewrite 41 untracked or modified files of the user's. Fork b restored them from the index and unstaged back to the baseline.

The coordinator checked the repair 2 ways. The fixer patch applies forward and not in reverse, so every file holds its original bytes. The porcelain also equals the baseline.

Residue:
- 2 empty session dirs and a bumped `locks/suite.lock` mtime under the real `~/.local/state/lain`;
- a rewritten `tmp/parallel_runtime_rspec.log`;
- 2 pre-commit stash files.

The evidence is in the coordinator scratchpad under `incident/`. The brief gained a `: "${QA:?}"` guard after wave 1.

## Round 27 defects re-checked

| id | verdict | evidence |
|---|---|---|
| b27-4 | FIXED | fork a: cockpit cut mid-ask, cut at the ask, idle prepare and apply, `truncate-cumulative` and `summarizing-flat` cuts, every chat lived. Forks b, c, d, k: default launches committed 1, 3, 4 and 10 sessions' worth of cuts |
| l27-2 | FIXED | fork l: `--confine reader` gives exit 0, 32 grades, 12 `sandbox` records all `profile reader` |
| l27-4 | FIXED in effect | fork l: the `$(find parent)` script never reached the parent; the refusal no longer advises a script, and a script written during the run is refused |
| d27-5, d27-6, d27-1 | FIXED | fork d; d27-6 also checked after a tool continuation, no duplicate turn |
| i27-1 | FIXED | fork i through a real chat, 7 shapes refused; fork g, the write side |
| b27-1 | DIFFERENT, worse | forks b and f: now b28-1. Keys and Ctrl-C in 1 write end the session, not just the line |
| f27-1 | FIXED | fork f, including the resumed `/btw` half |
| h26-7, h27-1, h27-3 | FIXED | fork h |
| h27-4 | FIXED on hand-made anchors, worse in effect | fork h: names no denied commit, but the same filter drops a parked one (h28-3) |
| h27-2 | NOT REACHED | fork h: no orchestrator spawned `reviewer_code` in 2 runs; guard read at `cli/wiring/toolset_build.rb:65-88,543-552` |
| i27-3 / k27-1 | FIXED | forks i and k: "loop ran 60 iterations, ceiling is 60" |
| i27-5 | NOT REACHED | fork i: needs a session larger than the window |
| i27-6 | PARTLY | fork i: 1 pass, 3 distinct notes; not driven at size |
| i27-2 | FIXED | fork i: both `auto_approver` spawns left out of consolidate |
| m27-1, m27-3 | FIXED | fork m |
| k27-2 | FIXED | fork k: `write_file` and a bash redirect outside park with the outside-project note, under `ask` and `auto` |
| a27-1, a27-2 | FIXED | fork a; a27-2 also seen by fork b |
| c27-3 | FIXED | fork c |
| c26-1 | DIFFERENT, better | fork c: "hello" after a handoff got a greeting and 0 tool calls |
| c26-2 / c27-2 | FIXED for the shape reached | fork c; the neighbouring cost is c28-4 |
| c26-3 | NOT REACHED | fork c, budget |
| g27-1, g27-2, g27-3 | FIXED | fork g |
| a26-3 | INCONCLUSIVE | fork g: the plain chat's scrollback was gone after `/quit`; records held 0 planted bytes |
| e27-1 | FIXED | fork e: the notice names the missing `lain-fence` (printed twice, a nit) |
| j26-3 | FIXED | fork j |
| f25-3 / T57 | FIXED, with a gap | fork f: the final deny's way out (`/mode ask`) is in the journal only |
| Left by the fix plan, still open | NOT FIXED | b27-2 (b, m), b27-5 (b), d27-2, d27-3, d27-4, d27-7 (d), e27-2 and i27-4 (e), f25-7, f27-2 to f27-5 (f), h27 nits (h), j27-1, j27-2 (j), m27-2 (m), l27-1, l27-3, l27-5, l27-7 (l), c27-2's nit, the `ast_search` numbering nit |
| b27-3, h27-5, l27-6 | NOT REACHED | budget for b27-3 and h27-5; no arm failed every task for l27-6 |

## Coverage

| scenario | fork | driven | not driven, and why |
|---|---|---|---|
| session-and-window | a | whole, every b27-4 trigger; §7b step 4 for the first time | §3 cold row ran against a stand-in proxy (12 forks keep the model loaded); §2's retry line is unreachable on ollama and the Anthropic path needs `ANTHROPIC_API_KEY` (unset, checked); §9 spawn inheritance is spec-owned |
| rust-cli | a | whole | the stall clock: no stall happened |
| bowling-ruby | b | §1 to §3: oracle 5/5, wedge fork and resume, control | the summarizer declaration |
| cockpit-surfaces | b | §0 checks 1, 2, 10, 11, 13; partly 3 to 8, 16; §1 to §4b; §5 with 3 parallel calls; §6; §7 partly | §0 checks 9, 12, 14, 15, the Stop section, the countdown, §5 plain-chat guards, §5b, §8 (turn limit); fleet item 1, the grandchild (unreachable from a chat) |
| rails-blog | c | every section; §2's premise reached through the ceilings | the declined handoff (T61, c26-3), the reverse pin, typing during an idle prepare (budget); K23-1 stall (this model wraps every answer in `todo_write`); collapse (spec-only); T70 correction after the switched model's first reply |
| failure-injection | d | §1 to §12 | supervisor door (no caller); §10 decline (unreachable by construction); §12 prefill timing (inconclusive, shared slot) |
| prompt-slots-and-roles | d | §1 to §5c, §6 free half | §5 (spec-covered); §6 paid half (`ANTHROPIC_API_KEY` unset, checked) |
| shell-terms | e | §0 to §8 | §9 paid half (`ANTHROPIC_API_KEY` unset, checked; local reduction only) |
| bash-confinement | e | §1 to §6, §3b and the docker ENTRYPOINT fallback for the first time | the `--confine reader` control was inconclusive (the judge deferred); 2 docker fallbacks (budget) |
| shell-term-approval | f | §0 to §3a, §4a, §4c, §5, §7, §7a, §11 | §4b, §6, §8 to §10 by the scenario's own division; §7's `.env` and in-root link rows (budget) |
| repl-commands | f | §0 to §9 | 4-hex ambiguity (about 300 turns); several budget legs listed in fork f's report |
| secret-boundary | g, j | §0 to §9 at least in part; §9b by fork j | §4b (owned by changeset-review); §3b items 4, 5 (would walk `/`); partials for budget |
| epic-tier | h | §0 to §13; §10d, §12b and the parked-gate chain for the first time | §10a, §10b, Ctrl-C between issues, remote finish, gc under a live lease (budget) |
| changeset-review | h | §0 to §8 | §6 per-child token record (budget) |
| subagents-and-backends | i | §1 to §6 | daemon stop (podman has none); depth cap and actor items (unreachable from chat); §2c items 5, 7 (budget) |
| memory-and-dogfood | i | §1 to §6 | clerk overwrite legs (i28-4 refused the session first); StaleEmbeddings (no CLI path) |
| config-middleware | j | every step, in a live cockpit | none |
| ollama-cloud-arm | j | §1 to §6b, 19 cloud window rows | §5 cloud salvage cut (budget); §6b on a real plan below the width (no Free key; TLS stub) |
| greenfield-epic | k | every section; §6.3, §6.4, §7.9 and §7.11's stall for the first time | sub-legs that passed in round 27 (budget) |
| merge-coordinator | m | §0 to §8; §5 live for the first time | the verify-timeout kill (budget) |
| survey | m | §1 to §7 | `/survey /` (the brief forbids a walk of `/`) |
| bench-arms | l | every refusal, full run, reader and workspace runs, set-aside, SIGINT, the new subcommands | priced report (`ANTHROPIC_API_KEY` unset); memory-sweep (l28-9); judge-scale (needs a key or per-scale journals) |

## The HIGH

### i28-4: a memory item with `sources` makes the project unresumable

**What is wrong.** After 1 `lain consolidate`, whose clerk rows carry `sources`, every new chat in that project refuses `lain chat --resume`. It also refuses `lain consolidate`, `lain improve --dry-run` (fork i), `lain bench variance` and `bench compaction-sweep` (fork l). The refusal reads "the memory_loaded record names version blake3:bc84… but its items address blake3:f3d7…; the recorded view has been edited". A `memory_write` from the chat model can pass `sources` too (`tools/memory_write.rb:55`).

**Mechanism.** `bench/session/memory_replay.rb:211-223` (`item_from`) rebuilds each item from id, description, body and author. `Memory::Item` includes `sources` in what it writes (`memory/item.rb:54,74`). The rebuilt view's version therefore never matches. The cause is `79ea6106`, "record source digests on items".

**Control.** Session `20261028T143542` was opened before the clerk items existed. It resumes and answers with exit 0.

**Why the suite missed it.** The replay specs build items without `sources`. A 2-component disagreement inside one record, which is the simplify-16 risk the brief named.

## The MED-HIGHs

### k28-4 (with c28-1, l28-7): a string-arm allow cannot run a home-installed toolchain

**What is wrong.** Every automatic allow, from the judge or a remembered rule, earns the `workspace` profile (`confine/profiles.rb:118`). A command the shell verdict abstains on takes the string arm. `Tools::Bash#resolve` hands over resolved programs only when the verdict allows (`tools/bash.rb:368-371`), so `exec_files` and `install_bins` grant nothing (`confine/profiles.rb:131-139,156-159,212-214`). `~/.cargo/bin` and the mise installs are on the read list only (`confine/profile.rb:50-56`). The verdict abstains on `bundle exec rspec`, `bundle install`, `npm test`, `ruby -e`, `node x.js`, `python3 -m pytest` and any `a; b`.

**Seen 4 ways.**
- Fork k: during `/research-epic`, glm-5.3 wrote "cargo/rustc are hard-refused by the session sandbox" into a `research.md` that was then approved.
- Fork c: `bin/rails test` was refused. Its remedy says to ask a human, and no route exists, since a retry is judged and refused again.
- Fork e: a remembered `allow "bash", command: "ruby hello.rb"`, which is exactly what answering "always" writes, is refused on every run.
- Fork l: 0 of 4 bench arms could run a committed `ruby bin/sum.rb`.

**Control.** `cargo --version` alone takes the term arm and runs; `cargo --version; echo done` is refused (fork k). A human approval runs the same program under `traced` (forks c, k).

**The checker hides it.** `bin/workspace-run --root $QA/rb -- ruby hello.rb` prints `42`, because it resolves the term whatever the verdict (`bin/workspace-run:104-111`). That is the check `525e4018` used to show that "a project's own tests run".

### g28-3: an approved release is refused at egress and wedges the chat

**Repro.** Put `.env` on disk before launch. In `lain chat --approval ask`, ask for `read_file .env` and answer `y` at the path gate and `y` at the release. The journal then reads `read_released`, `request_sent`, `egress_refused` and `run_interrupted`. Every later request is refused until `/rewind`, and after `--resume` too.

**Control.** A file created after launch (`.env.two`) releases fine.

**Mechanism.** `HistoryLiterals` lists the sensitive files on disk at launch (`history_literals.rb:7-17`). `Secrets::Egress.of` marks their values refused (`secrets/egress.rb:36-44`), and `EgressGuard#refuse_known` refuses any request carrying one (`egress_guard.rb:109-112`). `RedactSecretReads#release` (`redact_secret_reads.rb:454-464`) never tells the guard, and neither file names the other.

It came in with `bf959175` on 2026-10-26. It fails closed, so nothing leaks, but the release prompt becomes a trap.

## The MEDIUMs

### b28-1 (with f28-3): keys and a Ctrl-C in 1 write end the chat

`tmux send-keys 'hello' Enter C-c`, or `'abc' C-c`, at an idle `you>` ends the session: `session_closed reason exit`, no user turn. That held 2 of 2 times in the cockpit (fork b) and in a plain `lain chat` (fork f).

**Control.** Sent as `abc`, a 1 s pause, then `C-c`, the draft clears and the chat lives.

**Mechanism.** The input pane (`input_pane/uncooked.rb:6-18`), Reline (`reline-0.7.0/lib/reline/io/ansi.rb:284`) and `frontend/line_editor.rb:209` all leave ISIG on without NOFLSH. On Ctrl-C the kernel discards the unread bytes before the reader sees them. `InputPane#signal` (`input_pane.rb:154-160`) and `Intake#interrupt` (`intake.rb:255-262`) then see an empty draft and pass the signal on, which ends the chat at `you>`.

**Better or worse.** Worse than b27-1: round 27 lost the line, while this loses the session. A paste followed by a quick Ctrl-C is enough.

### k28-1: a sandboxed command cannot read a `related` directory, and is not told why

With `sensitivity related: %w[$QA/sib]`, an allowed `cat $QA/sib/src/m1.rs` gives "Permission denied", and `git -C $QA/sib log` gives "not a git repository". Both carry `refusals: []`, so the model sees no sandbox wording; glm-5.3 spent 4 calls and 3 human approvals debugging a healthy repository. `read_file` on the same file returns it (control). The same shape appears for `ls /home/tara/dev` (fork e), and for `config/master.key` under `bypass` (fork g).

**Mechanism.** `Profile.reader` read dirs are the root, the linked git dir, `SYSTEM_READ` and `HOME_READ` (`confine/profile.rb:219-223`). Nothing under `confine/` reads `related`. `Exec::Sandboxed#worded` phrases only `record.refusals`, which holds execs (`exec/sandboxed.rb:180-195`).

### l28-8: the bench journal records a sandbox-refused exec as clean

For the refused `ruby bin/sum.rb` call, the `sandbox` record reads `profile workspace refused [] created_sealed []`. `Telemetry::Sandbox#refused` holds only pre-spawn refusals (`exec/sandboxed.rb:113-116`, `telemetry/sandbox.rb:17-20`). The EACCES lives in an `exec_record` (`sandboxed.rb:213`), which `26a76510` does not copy into the run journal. A `--confine workspace` run cannot tell a refusal from success, and the bench keeps no session files.

### j28-4: a raising middleware kills the chat, and the journal records a clean exit

A `tool` or `model` user middleware whose `call` raises ends a one-shot chat with exit 1 and a backtrace (`tool_runner.rb:460`, `model_caller.rb:39`). In the cockpit, the pane reads "Pane is dead (status 1)". The journal ends `session_closed reason "exit"`, with no `run_interrupted`, which is the same record a normal quit writes.

**Mechanism.** `cli/chat_launch.rb:121-127` closes with `:exit` in an `ensure`, and `telemetry/session_closed.rb:39` has no reason for an exception. `middleware.rb:132-134` contains no member's exception. Every escaped crash, b27-4 included, has been journaled as a clean exit.

### j28-2: a trust grant follows a loader into other repos

`repo3/.lain/config.rb` is `load File.join(__dir__, "extra", "x.rb")`, trusted. `repo4` was never trusted, but has the same `config.rb` bytes and its own `extra/x.rb`. Its payload runs under `LAIN_PREFLIGHT=1 lain chat`. A repo with different bytes is refused (control).

`project/trust.rb:13-19` keys on content and excludes loaded files; both halves are documented. But the prompt asks about "this project", and nothing says the grant crosses projects. Ruling asked.

### h28-3: `land` reads a parked implementation gate as a denial

**Repro.** Set `gate :implementation, :deferred` and run `/implement-epic` until `lain epic queue` lists the implementation gate. `lain epic land greet demo` then says "no worker commit is anchored ... re-run the issue through the epic driver", and exits 1. That is false: `refs/lain/worker/issue.demo.greet.1-75a0104dd199` holds bc4b5f4, and gc kept it.

**Mechanism.** `Approvals.from` (`forge/local_landing.rb:354-359`) maps the latest implementation `gate_decision` to its `approved` value. A deferred park journals `approved: false`, so `denied?` (`:386`) is true. T17's `offerable` (`:242-252`) then drops the commit, and `missing_approval` (`:232-237`) prints the text. `SignoffQueue` reads the same record as parked, so 2 readers disagree about 1 record.

**Control.** After `lain epic approve <digest>`, the same `land` lands.

**Better or worse.** Worse than h27-4. Following the remedy starts attempt 2 and supersedes a commit the human has not read.

### h28-4: a parked implementation gate shows no test result

`lain epic queue` shows `question: <not recoverable from the journal>` and `evidence: <none -- no spike ran>`, while `tests_ran` for that commit reads `1 error`. A deferred gate journals no question, so g23-3's test line never reaches the unattended reviewer the deferred policy exists for. Fork h approved a broken commit with nothing on screen saying so.

### c28-2: the round budget withholds reads in a band where compaction never fires

At `used 26,211 / 32,768`, a 7,283-byte read came back "not delivered: this round reached its 3132-byte budget ... re-request it in a later round", and the retry got a smaller budget (2,997). The budget is sized at 1.31 bytes per token (`tool/round_budget.rb:48-55`, `oracle/handoff.rb:72`). Compaction fires only at 90% or at the window less a 4,096 reserve (`compaction/need.rb:104-121`). Every decision in between read `signals []` with 25 KB droppable. `lain friction` independently flags the 2 reads as a `rephrase_loop`.

### c28-3: an over-window prompt is refused when a handoff would answer it

The repro is at `~/tmp/lain-qa-2026-10-28-c/records/c28-3-repro.ndjson`: `--compact-strategy elide-tools+summarize-conversation --compact-keep 4 --num-ctx 32768`, then 45 KB fillers f1 f2 f3 f4 f1 f2, "hello", f3 f4 f1. The last f1 is refused (`would_not_shrink true`, 153 droppable bytes, `run_interrupted over_window`), and the human is told to `/rewind`. The next prompt hands off and is answered.

**Mechanism.** `room_after` (`agent.rb:819-829`) asks for a handoff first. It declines because the previous decision still read droppable (`compaction/source.rb:428,657`). The retry renders identical bytes, and `attempt` re-raises (`agent.rb:801`) without asking for the handoff again. This is RB-3 back on a new path, reproduced twice.

### c28-4: eliding a tool call drops the prose answer beside it

`ToolMessages.tool?` (`compaction/tool_messages.rb:22-28`) counts a message as a tool message if any block is a tool call. Its comment calls this a known limitation. qwen3-coder attaches `todo_write` to nearly every answer, so after a cut each 800 to 900 character explanation became `[calls todo_write] (elided -- no summary was taken)`. Asked to quote one, the model replied "NOT VISIBLE".

### g28-1: a declined release is final for the session

Answer `n` at a release, then tell the model you changed your mind: the re-read comes back masked, with no prompt and no `source_masked`. The decline memory only grows (`redact_secret_reads.rb:395-411,476`), a lapse counts as a decline (`:441-443`), and no command clears it. The trailer still says "Tell the user which file you need unmasked" (`:661-674`). It says the same under a `related` directory, which is never released.

### g28-2 (with c28-6): every lockfile read waits for a human

Region counts: Gemfile.lock 110, Cargo.lock 166, package-lock.json 237, poetry.lock 255, yarn.lock 2033. A 30-line slice of Gemfile.lock parked on `20 sensitive regions outstanding` under `ask`, and under `auto` with no judge record, while `grep` masks the same lines without stopping. A hex digest is a secret by design (`entropy.rb:8-20`), and `Regions#qualifies?` accepts a secret-shaped value whatever its key (`regions.rb:291-295`). Round 27's dotenv digest exemption is for name hints only, so it does not reach here.

### b28-2: `x` marks a never-opened row as reviewed (ruling)

The "nothing has read it" refusal fires only for a row with no hunk keys and `read == false` (`frontend/neovim/review_view.rb:378-393`). `read` is `file.chunked?` (`:453`). A parsed changeset file is always chunked (`review/source.rb:218`), so on a changeset review every unopened row can be marked (fork h). A surveyed file is chunked once anything has called `hunks` (`lazy_file.rb:114,128`).

Fork b marked 3 unopened survey rows. Fork m did not reproduce that in 8 survey shapes, and which call loaded those hunks is not established, so the survey half is inconclusive. Either "read" means "lain computed it", and cockpit-surfaces §4 is stale, or an approve can certify files nobody opened.

### x28-1: a cloud chat summarizes on the local model, unannounced

`cli/backend.rb:77` sets `DEFAULT_SUMMARIZER_PROVIDER = "ollama"`. `tier_default_model` (`:835`) takes the chat's model only when the providers match. Otherwise it takes `Provider::Ollama::DEFAULT_MODEL`, `qwen3:4b` (`provider/ollama.rb:76`, `ollama_tier.rb:208`).

| chat | summarizer |
|---|---|
| ollama-cloud glm-5.3 | ollama qwen3:4b |
| anthropic | ollama qwen3:4b |
| ollama qwen3-coder:30b | ollama qwen3-coder:30b |

**Live evidence.** Fork k's `oracle_answer` with model `qwen3:4b` took 12.089 s. The shared server logged a 12.075 s `/api/chat` ending 08:38:58, with `qwen3:4b` loading at 08:38:50 and `qwen3-coder` reloading after. It happened again at 09:04:25. Fork c noticed the swaps; the coordinator traced them; fork j confirmed the mechanism.

**On a box with no local ollama** (`unshare -rn`), the summary gets ConnectionFailed and the chat carries on with the raw result, with no screen line.

The comment at `backend.rb:73-77` says local is deliberate, and that "the tier is journalled". The session header carries no summarizer tier. The epic adjudicator falls back the same way when only `LAIN_PROVIDER` is set (fork h).

## Per-fork findings, LOW to LOW-MED

| id | sev | what | mechanism |
|---|---|---|---|
| a28-1 | LOW UX | `bench variance` names `compaction schedule` when compaction was off in one run | first differing axis wins, `bench/session.rb:304-311`; fork l reproduced |
| a28-2 | LOW | a launch against a host that never answers waits for 3 probes, 6.94 s | `/api/tags` probe added in `24431147`; `window_book.rb:155-165` says 1 probe |
| a28-3 | LOW UX | closing a plain chat's window while a child works leaves the process 60 s with no terminal | `cli/signals.rb:25` treats HUP as TERM, which opens the human countdown |
| a28-4 | LOW nit | `price_book.rb:23` says cache reads cost 0.1x; the rows from `3ec5ecff` are 0.05x and 0.025x | not checked against published rates |
| b28-3 | LOW | a stale `command>` stays in the input pane after the parked call settles; a typed line becomes a note | not confirmed; `cli/human_replies.rb:766`, `input_pane.rb:369` |
| b28-4 | LOW | the fleet row shows the role, not the child's given name | `tools/subagent.rb:351-353` passes `@announces_as` |
| b28-5 | LOW | a home with only `plans/x.md` counts as an epic; `lain://status` mounts it | `cli/epic.rb:392-397`; fork h confirmed from the CLI |
| b28-6 | LOW, ruling | a lapse rings a second bell | `Arrivals#lapse` (`approval_surfaces.rb:166`) calls `render_summons` (`:90`) |
| b28-7 | LOW | a stuck child's completion record names only `Lain::Budget::Exceeded` | fork i confirmed; `lain watch` shows `(failed)` (i28-5) |
| c28-5 | LOW | `lain friction` blames compaction knobs for 6 prefix rewrites, 3 of them `/rewind` and `/model` | `friction/report.rb:36,207-211` |
| c28-6 | LOW | see g28-2 | |
| d28-1 | LOW-MED UX | the model copies lain's "(a tool call written as text was withheld)" and lain shows it as an answer | `WITHHELD_CALL` in assistant content, `provider/ollama/decoding.rb:119,176-181` |
| d28-2 | LOW | `read_file`'s over-ceiling advice gives 2 disagreeing figures (184 windows vs 201 lines) | `tools/read_file.rb:598` vs `:622` |
| d28-3 | LOW UX | `grep` on a directory names hits relative to it; the description says only "file:line" | `tools/grep.rb:104-108,243-247` |
| d28-4 | LOW | `(human> closed ...)` appended to the countdown line with no newline | cosmetic |
| e28-1 | LOW-MED | the tripwire cannot see a planted binary refused before spawn, so `--tripwire stop` lets the run continue | `Hit.of_sandbox` reads only `created_sealed`, `tripwire/hit.rb:89-91`; term-arm refusal at `exec/sandboxed.rb:114-117` |
| e28-3 | LOW-MED | `--exec docker` on an image with an ENTRYPOINT runs `actionlint cat README.md` for an approved `cat README.md` | no `--entrypoint`, `exec/docker.rb:222-224` |
| f28-1 | LOW-MED | `grep -n /etc/shadow README.md` is a final deny and a tripwire signal | `shell/named.rb:20-22` names the pattern; `searched` (`:701`) knows better |
| f28-2 | LOW | `/pin` of a pinned turn journals the pin again | `/unpin` refuses its no-op (control) |
| f28-4 | LOW | `/goal off` during iteration 1 pins the objective on the way out; `/meta` then worked from the dead goal | `cli/goal_driver.rb:291-296`, `cli/command/meta.rb:125` |
| g28-4 | LOW | the egress refusal's `/rewind 1` hint is refused by `/rewind` | counts message positions, `egress_guard.rb:132` |
| g28-5 | LOW | `request_sent` with the full payload is journaled for a request the guard refused | |
| g28-6 / j28-3 | LOW UX | in a plain chat, the oracle's held request and the "oracle will not help" notice appear only after the human answered the read | bound at `cli/wiring.rb:376`, hold not traced |
| h28-1 | LOW-MED | `lain review` prints file names and commit subjects raw: `evil\e[2K\rinnocent.rb` shows as `innocent.rb` | `review/surface/text.rb:156,169` only call `Utf8.legible` |
| h28-2 | LOW UX | `--digest 8b6b677` refused as "not a commit" | requires 40 to 64 hex, `cli/epic_submit.rb:269-272` |
| h28-5 | LOW | `lain://status` stale through an `/implement-epic` run | refreshed by the next chat turn |
| h28-6 | LOW UX | the per-commit view shows the red commit as "(no hunks reachable here)" | |
| h28-7 | LOW | a finished epic reports `stage issue_plan -- 2/2 done` | |
| i28-1 | LOW-MED UX | a researcher's written files are not named to the parent; it searched `/tmp` | `isolation/scratch.rb:70-73` returns `""` |
| i28-2 | LOW docs | a chat's subagent leases scratch, not a worktree; `docs/commands.md:146-147` says otherwise | `cli/wiring/toolset_build.rb:515-516` |
| i28-3 | LOW | the clerk stored `API_KEY=<redacted:1>` as a fact | `refuse_secret_writes.rb` refuses a placeholder only for an id read masked this session |
| i28-5 | LOW UX | `lain watch` renders every failed child as `(failed)` | |
| j28-5 | LOW gap | a `model` middleware never sees the summarizer's calls | 3 `http` lines, 2 `model` lines |
| k28-2 | LOW-MED | every `git -C <dir>` stage resolves to nothing and trips `unresolved_exec strong` | `run_files.rb:56,186`, `resolver.rb:76-77`; `named.rb:536-541` already reads `-C` |
| k28-3 | LOW-MED UX | in `lain://question`, `x` cannot tick an option with a comment under it, unless it is the last option; it deletes the `-` | `60_question.lua:341-356,421-433`; fork h confirmed |
| l28-2 | LOW-MED | `bench variance` and `compaction-sweep` crash with a raw `ArgumentError` on a resumed session | no resolver, `bench/session.rb:356`, `loader.rb:34-37` |
| l28-3 | LOW | `ci95` is an unclamped t-interval: grades `-5.853..6.853` | `compare/stats.rb:39-47` |
| l28-4 | LOW UX | a repeat-guard stop reports as `failed at the ceiling` | |
| l28-5 | LOW-MED | with no `--labels`, failures default to `reasoning` or `environment`; `unattributed` reads 0 | `compare/attribution.rb`, `arm/driver.rb:134` |
| l28-6 | LOW UX | `wins` on tokens means spending more; an unpaired task blames the wrong arm; `not priced` 3 times | |
| l28-9 | LOW-MED | `bench memory-sweep --provider ollama` is overwritten with `anthropic` and refused for a flag never typed | `exe/lain:1219` |
| m28-1 | LOW-MED | a `--non-interactive` `@dev` worker can never hand back; its `git commit` is denied | non-interactive refuses unjudged calls; the judge note says git "reads" the object store |

### Withdrawn or not filed

- fork b, the `auto_approver` spawn record carries `role` and `unattended`, against cockpit-surfaces fleet item 6. Fork i confirmed it and that the judge stays out of the fleet tree. It is a scenario correction.
- fork f, composed_term approving `wc -l` and `cat` under `ask`: by design.
- fork h, `submit implementation` accepting gates for finished issues, gc keeping a fast-forwarded branch: hand-made shapes only.
- fork m, a second enqueue while the first is queued reports `was already on main`: observed once.
- fork e nits: the `tripwire` record's `stop` reads `would_stop` beside a real `tripwire_stop`; the `deny_tool "web_fetch"` refusal uses bash wording; a human deny's reason does not say which surface; `web_fetch` waits out a timeout on a percent-encoded loopback host.
- fork l nits: `bench tree` headed `lain_c_l_i:bench`; variance prints `0.000340276 hours`.

## Third-party behaviour

- **qwen3-coder:30b.** It writes tool calls as prose at about 15 chained reads (forks d, i, m), loops `todo_write`, `session_usage` and `epic_write` into the ceilings, and calls tools when told not to. It claimed "All tests pass" over 17 failed rspec runs and "fully functional" over a red Rails suite. It overwrote README.md when asked for `notes/bell.txt`, and read a sandbox refusal as an OS permission problem. An ESC in its tool arguments broke ollama's tool-call parser (fork b).
- **glm-5.3 (cloud).** It ignores the oracle's `format` schema, so every answer is `UndecodableAnswer`; `gpt-oss:120b-cloud` decodes. It turned a sandbox refusal into a project constraint (k28-4), and never told the user to restart after creating the epic.
- **qwen3:4b as the local secret oracle.** `bench oracle-calibration` gives 122 of 150 secret paths wrongly approved, hard negatives 27 of 30, Brier 0.3902, FAIL. `--secret-oracle` defaults to off.

## Process notes

Folded into `planning/qa/method.md` under "Round 28".

## Scenario corrections owed

Each fork's section 6 lists the wrong predictions it found; none is a lain defect. They are folded into the scenario files in this round's close-out, and method changes into `method.md`'s Round 28 section. The fork reports are in `~/tmp/lain-qa-2026-10-28-coord/records/fork-<letter>-report.md`.

## Close-out

- Every fork killed what it started, by pid, and found its ports free. 1 stray podman `catatonit` (4002579) was fork i's, killed by fork i.
- `env -u XDG_CONFIG_HOME git status --porcelain` equals the 39-line baseline at every fork's close-out and at the coordinator's.
- `find ~/.local/state/lain -newermt <round start>` prints the 4 entries from fork b's incident and nothing else, against a control of 1,922.
- No `.lain` in the checkout, no `~/.lain`, dunst 0 and 0.
- Sandboxes `~/tmp/lain-qa-2026-10-28-{a..m}` and the coordinator records in `~/tmp/lain-qa-2026-10-28-coord/records/` (every fork's report, the announce log, the ollama log) are left in place.
