# QA round 27, 2026-10-21

## Summary

This was a full round over all 22 scenarios in 13 forks (`a` to `m`), at most 4 at once, against `b5de73a4`. Each fork had its own sandbox, tmux socket and port range. That tree is 212 commits past round 26's `6054ba1d`: the round 26 fix plan (92 of 93 cards), the Rust DAG flip and the Rust hot paths. Every scenario was driven and none was dropped. `bench-arms` ran last with the local GPU to itself. The shared server had `OLLAMA_NUM_PARALLEL 1`, `OLLAMA_CONTEXT_LENGTH 32768` and `LAIN_NUM_BATCH=2048` throughout. No Anthropic key was set, so every paid Anthropic half is "not reached".

**Round 26 is almost entirely fixed.** b26-1, the HIGH, is fixed in all 4 places it was filed (forks b). Of the 2 MED-HIGHs, h26-1 changed shape without getting better (h27-4), and l26-1 is not fixed in effect (l27-4). Of about 75 round 26 items re-checked, about 60 are fixed.

**What is new sits in 4 places:**

- **A default launch dies at its first compaction cut** (b27-4, found by 5 forks). A chat with no `--max-tokens` gets T89's per-model ceiling, which holds the live window book, and the cut cannot make it Ractor-shareable. On ollama that is about 22 turns into an ordinary session. Every arm is affected: local, cloud, cockpit, plain chat and resume. `--max-tokens N` avoids it, and the rest of the round ran under that workaround.
- **`bench arms --confine reader` crashes on its first gated call** (l27-2). And the opaque-command refusal that closed l26-1 tells the arm to put the command in a script, which an arm did, writing outside its lease again (l27-4).
- **The epic driver works on stale trees.** A retry reuses a stale issue branch (h26-7, now with a mechanism), a code reviewer is leased a tree without the work it reviews (h27-2), and `land` offers a commit the human denied (h27-4).
- **Credentials still reach memory.** `memory_write` misses 5 common shapes and `memory_loaded` copies each one into every new session file (i27-1). A bare GitHub token typed at `you>` is kept raw in history (g27-3).

| id | sev | what |
|---|---|---|
| **b27-4** | **HIGH** | with no `--max-tokens`, the first committed compaction cut raises `Ractor::IsolationError` at `compaction/source.rb:1044` and ends the chat, on every arm |
| **l27-2** | **HIGH** | `bench arms --confine reader` dies at the first gated call: `undefined method 'to_journal' for Hash`, no report |
| l27-4 | MED-HIGH | the `LEASED_OPAQUE` refusal says "write a script in <lease> and run it"; an arm did, and rewrote a file in the launch repo |
| d27-5 | MEDIUM | `grep` on a single file withholds every match as `(malformed)` |
| d27-6 | MEDIUM | resume salvage recovers the answer but loses the human's prompt; the answer lands on the previous head (local and cloud) |
| i27-1 | MEDIUM | `memory_write` stores `{"password": ...}`, `PGPASSWORD=`, `MYSQL_PWD=`, URL userinfo and `Bearer`; `memory_loaded` copies them raw into every new session |
| b27-1 | MEDIUM | Ctrl-C right after Enter loses the submitted line, with nothing journaled and nothing said |
| f27-1 | MEDIUM | `/rewind` leaves the todo list, so rewound content reaches the next request through `<workspace>` |
| h26-7 | MEDIUM | a retry reuses a stale issue branch: `IssueActor#cut` ignores `from` for an owned branch |
| h27-4 | MEDIUM | `land`'s remedy offers an earlier attempt's commit the human denied |
| h27-2 | MEDIUM UX | a `reviewer_code` child is leased the committed tip, without the uncommitted implementation it was asked to review (3 of 3) |
| h27-3 | MEDIUM | gc can reap an unlanded issue's anchor because its own issue branch reaches it (code and a partial live run) |
| h27-1 | MEDIUM UX | a stale parked submission of an advanced stage is counted nowhere, and denying it withdraws the newer approval |
| i27-3 / k27-1 | MEDIUM, ruling | a chat's researcher runs under a ceiling of 24, not the role's 60 (2 forks) |
| i27-5 | MEDIUM UX | `lain improve` stores 51 notes, then prints only ollama's raw 400 JSON and exits 1 |
| m27-3 | MEDIUM UX | a worker that commits and then hits its ceiling has the commit declined, and nobody is told |
| k27-2 | MEDIUM UX, scope | in `checkout` scope the main agent writes outside the project with nobody asked; a child reading outside parks |
| a27-2 | MEDIUM UX | text the model writes beside a tool call never reaches the screen |
| the rest | LOW to LOW-MED | itemised under "Per-fork findings" |

**Rulings asked for:** i27-3 / k27-1 (should a child's iteration ceiling be drawn from the parent's room, as tokens are?), k27-2 (should `checkout` scope gate a write outside the project?).

## Round 26 defects re-checked

| id | verdict | evidence |
|---|---|---|
| b26-1 | FIXED | fork b: idle `you>`, `command>` with an approval parked, a `--no-nvim` cockpit and plain `lain chat --no-nvim`. Each time the line cleared, nothing was journaled and the session lived. The gap left is b27-1 |
| b26-2 to b26-6 | FIXED | fork b |
| b25-6, b25-10 | FIXED | fork b at the filed sites; the same path is still named 2 ways elsewhere (b27-2) |
| h26-1 | DIFFERENT, not better | fork h: submitting the red sha is refused (T38). `land` now names attempt 1's commit, which the human denied (h27-4) |
| h26-2 | NOT REPRODUCED | fork h: Bundler did not rewrite the lockfile |
| h26-3, h26-4, h26-6, h26-8, h26-9, h26-10 | FIXED | fork h |
| h26-5 | FIXED for `[!]`; in-flight case open | fork h, h27-5 |
| h26-7 | REPRODUCED | fork h, with branch snapshots and a mechanism |
| l26-1 | NOT FIXED in effect | fork l: the literal routes are refused (the loop 94 times), and the refusal's own advice led out (l27-4) |
| l26-2 | FIXED for a small allowlisted read | fork l: `cat lib/x.rb` journals `profile reader` in all 4 arms; the scenario's 13 MB `sort` can never show `reader` (a scenario correction) |
| l26-3, l26-4, l26-5 | FIXED | fork l |
| l25-1 | HOLDS for named paths | fork l |
| g26-1 | grep half FIXED | fork g: `grep path .env` refused before anyone is asked; the `ast_search` half is as documented |
| g26-2 | FIXED for the named shapes | forks g and i, manual pass driven; residue is i27-1 |
| g26-3, g25-4 | FIXED | fork g |
| g26-4 | AS DOCUMENTED | fork g |
| a26-3 | FIXED | fork g, manual pass in the cockpit: chat pane, `lain://journal` and the record show `<redacted:1>`; fork a: 0 raw surfaces |
| i26-1 | NOT FIXED where the write guard misses | fork i, i27-1 |
| i26-2, i26-4 | FIXED | fork i |
| i26-3, i25-3 | AS DOCUMENTED | fork i |
| ENV-1 `cd` step | DRIVEN, refused | fork i: typed by the model for the first time in 3 rounds; each `cd <project> && ...` refused naming the worktree |
| m26-1 | FIXED | fork m, manual pass: after `kill -9` the next drainer stopped the orphan's verify group |
| m26-2, m26-3, m26-5, m26-6 | FIXED | fork m |
| m26-4 | FIXED in the renderer only | fork m, m27-1 |
| c26-1 | NOT FIXED in effect | fork c: T60's wording landed; "hello" after a handoff restated the old answer and ran 24 `session_usage` calls. Control with no handoff answered normally |
| c26-2 | NOT FIXED | fork c, c27-2 |
| c26-3 | FIXED | fork c, manual pass: 15 reads in 1 round, 1 `round_bounded`, answered, no handoff |
| c26-4, c25-6, c25-7 | FIXED | fork c |
| d26-1 to d26-7 | FIXED | fork d; d26-1's reattach line paints under the attach |
| d25-6 | BETTER | fork d |
| read_file sizing-note grammar | NOT FIXED | fork d |
| j25-1 | DIFFERENT, worse | forks d and j, d27-6 |
| e26-1, e26-2, e26-3 | FIXED | fork e |
| e25-1 | HOLDS | fork e: the reader sandbox stopped a planted program's network, with a positive control |
| `Shell::Named` env prefix and wrappers | NOT FIXED (as recorded) | fork e, e27-2 |
| f26-1 to f26-3, f26-5, f25-3 | FIXED | fork f |
| f26-4 | PARTLY FIXED | fork f, f27-4 |
| f25-7 | NOT FIXED | fork f: `grep -e pat`, `sed -i s/a/b/`, `rsync -av` still name non-paths |
| Spike doubled prefix | NOT FIXED | fork f |
| j26-1, j26-2, j26-3, j26-5, j25-5 | FIXED | fork j |
| j26-4 | FIXED for classes | fork j, j27-1 for modules |
| k26-1, k26-3, k26-4, k26-5, k26-10, k25-4, k25-1 | FIXED | fork k |
| k26-8 | FIXED | fork h, in passing |
| a26-1, a26-2, a26-5, a25-6 | FIXED | fork a |
| a26-4 | AS DOCUMENTED | fork a |
| a26-6 | NOT SEEN | fork a |
| introspect raw occupancy | FIXED | fork a |
| a resumed `/model` before the first reply (T70) | NOT SEEN | fork a: the decision reads `used_tokens` null |
| `max_tokens` manual pass | DRIVEN | fork a: ollama `served_window`, anthropic `table`, ollama-cloud `fallback`; fork c: `/critique` on a 32k window gave no `RESERVE_OVER` |
| two named children, one asker name | FIXED at the surfaces | fork i: rows read `ruby-counter (researcher)`; `approval_pending` still says `researcher` |
| `TTY#render_question` dead code | NOT DONE | fork b: 0 callers in `lib/`, 2 in a spec |
| symlink to `.env` leaking grep rows | NOT REPRODUCED | fork g |
| d24-7, k25-2, k26-6 to k26-9 | NOT RE-CHECKED | budget, or no judge fault occurred |

## Coverage

| scenario | fork | driven | not driven, and why |
|---|---|---|---|
| session-and-window | a | whole | §7b step 4: the prepare took no summary, and under `summarize-conversation` the model turned every no-tool ask into `todo_write` loops. §7b steps 1, 2, 3, 5 pass only under a typed `--max-tokens` (b27-4) |
| rust-cli | a | whole, after a resume with `--max-tokens` | none |
| bowling-ruby | b | whole: oracle 5/5, F23 fork and resume exit 0 | none |
| cockpit-surfaces | b | §0 checks 1, 2, 8, 9, 11, 12, 16; §1 to §4b whole; §5; §5b; §6; plain paste guard; mode lighter | fleet tree and checks 3 to 7, 10, 13 to 15 (the model would not spawn on demand); 3 parallel calls (the model made 1); §8 and plain guards 1 to 3, 5 (budget); silent `[y/N]` under `+notify` (a driver error let a prompt answer a parked question); automated halves relied on |
| rails-blog | c | §0 to §5 | §1b `/rewind` below a cut and F94 (budget); collapse (spec-only); §2's premise was not reached (largest delivered result 5,201 bytes) |
| failure-injection | d | §1 to §12 | §8's two-arm line is stale (1 arm driven); §10's decline path is unreachable by construction; the supervisor door has no caller |
| prompt-slots-and-roles | d | §1 to §5c, §6 free half | §5 (spec-covered); §6 paid half: `ANTHROPIC_API_KEY` unset, checked |
| shell-terms | e | §0 to §8, §6 under ask and bypass, §7 under podman | §9 paid: `ANTHROPIC_API_KEY` unset (a local reduction reads term arm 15 of 19) |
| bash-confinement | e | §1 to §6; §3 under `ask` | none |
| shell-term-approval | f | §0 to §3a, §4a, §4c under 3 levels, §5, §6 claim 5, §7, §7a, §11 | §4b, §8, §9, §10 live by the scenario's own division; §7's exempted `.env` row (budget) |
| repl-commands | f | §0 to §9, including §8's `/meta` generation (missed in round 26) | 4-character prefix ambiguity (about 300 turns), K23-1 pin effect, write-set undo fallback, `/keep` with actors (budget); §7 cap leg (unreachable on this model) |
| secret-boundary | g | §0 to §8 | §2 rooted pattern with no root (unreachable); §3b items 2, 4, §4b second note, §4b2 items 5, 6, 9, §5c worker leg (budget); §5b live spellings (the model stops after 1 refusal; 22 rows through `Shell::Named`); §6 fault rows (no seam) |
| survey | g | §1 to §5, §7 items 1 to 7 except as noted | §6 `--permissive` (budget, after a 200-turn stop); F64 park (the model never parked); a duplicate `:w` while pending (timing) |
| epic-tier | h | §0 to §13 except as noted | §1c steps 4 and 6, §4b, §4c, §10d timeout leg, §12 remote finish, §13a write-time guards, §13b post-merge reap (budget) |
| changeset-review | h | §0 to §5, §7, §8 | §4b and §6 (budget); §5 `x` positive case |
| subagents-and-backends | i | §1 to §6 | stopping the daemon (podman has none); §2b beyond the ceiling shape (no 60-iteration run, i27-3); §2c items 2, 5, 6, §3 item 5, §4 docker, §5 EmptySelector and NoSession (budget; round 26 passed them); actor items (unreachable from chat) |
| memory-and-dogfood | i | §1 to §6 | 3 resolution forms, torn-session refusal, resume isolation, `/rewind` past a write, bad UTF-8 row (budget; round 26 passed them) |
| config-middleware | j | steps 1 to 6 | none |
| ollama-cloud-arm | j | §1 to §6b, 10 cloud completions | §5 SIGKILL mid-stream control (budget; round 26 drove it); §6b on a real plan below the width (no Free key; a TLS stub stood in) |
| greenfield-epic | k | §1 to §5, §6.1, §6.2, §6.5 to §6.10, §7 most, to an approved research gate, about 70 cloud completions | §6.3, §6.4 (the child stopped at the clamped ceiling, k27-1); §7.9 (turn budget); §7.11 forced stall (inconclusive: glm-5.3 never leaves a 3 s gap) |
| merge-coordinator | m | §0 to §4, §6, §7, §8 | §5 by code read only, 2nd round running: needs an approved epic issue; schedule it in the epic-tier fork |
| bench-arms | l | every refusal, a default live run (32 grades), the escape run, reader runs, the ceiling cell, variance set-aside, SIGINT | the built-in anthropic `--provider` leg (`LAIN_PROVIDER` leaked in from the fork's shell); a warm second run for wall time (no outlier appeared) |

## The HIGHs

### b27-4: a default launch dies at its first compaction cut

**What is wrong.** A chat launched with no `--max-tokens` ends with `Ractor::IsolationError` the first time compaction commits a cut.

**Mechanism.** `CLI::Backend#max_tokens` (`cli/backend.rb:835`) returns `OutputCeiling::PerModel.new(window: context_window)` when nothing is typed (T89, `3ad9e1ca`, 2026-10-19). That object holds the live `WindowBook::Live`, clock Proc included (`output_ceiling.rb:93-103`). `Compaction::Source#flattened_twin` (`source.rb:993`) flattens the model slot and copies the ceiling unchanged, and `BASE_PROVIDER` (`source.rb:1043-1045`) then calls `Ractor.make_shareable` over a Proc that closes on the twin. Nothing catches it, and the chat exits 1. Coordinator-checked at all 4 sites.

**Trigger.** Any cut commit. On ollama, `timely?` (`source.rb:923`) commits as soon as history passes `keep_last` 20, because ollama confirms a cold cache on every turn, so an ordinary session dies about 22 turns in at about 30% occupancy (fork a). An idle-offered cut does it after about 2 minutes (fork b). It fired in-turn in 4 rails-blog sessions (fork c), on the cloud arm with `gpt-oss:20b-cloud` (fork j), and through `/btw`'s printed command, which carries no `--max-tokens` (fork f).

**Evidence that rules out the innocent explanations.** Same flags plus `--max-tokens 32768` (or 16384) commit `compaction_cut advance`, prepare and apply at idle, and keep running, in forks a, c and j. Not an OOM: peak 90.7 MB (fork a). A library check with the same lambda shape raises with the per-model ceiling and passes with `max_tokens: 4096` (fork b).

**Why the suite missed it.** Specs build a fixed ceiling. The default launch path is the only place the per-model one is made.

**Reach.** A fresh subagent has no compaction Source (`tools/subagent.rb:1144-1148`), so it cannot hit this. An inherit child of a parent that holds cuts is built from the same context factory and would (fork i, by code read). Bench arms leave `pipeline_source` at `Null` and cannot reach it (fork l). `--resume` drops a typed `--max-tokens` (a27-1), so a resume re-arms it.

**Reproduction.** `records/chat.sh r1 --compact-bytes 3000 --compact-keep 2 --compact-schedule turn --compact-strategy elide-tools+summarize-conversation --summarizer-provider ollama` in `~/tmp/lain-qa-2026-10-21-c`, then 4 asks of the form "Plain text only, no tools, no questions: write four paragraphs about the history of X". Or a default `lain up` session of about 22 turns.

**Fix shape.** Flatten the ceiling with the model in `flattened_twin` (or freeze `PerModel` to a value at the twin). Pin it with a `Source` spec over a Context built by `CLI::Backend` with no `--max-tokens` and no double, and make `/btw`'s printed command and `--resume` carry the recorded ceiling.

### l27-2: `bench arms --confine reader` crashes at the first gated call

**What is wrong.** A reader-profile bench run dies with a raw `NoMethodError: undefined method 'to_journal' for Hash` and writes no report.

**Mechanism.** Under reader, the bench builds the approval ladder over each arm's own journal channel (`bench/harness/confinement.rb`). `Telemetry::Escalation.write` (`telemetry/escalation.rb:25`, since `da728e6b`, 2026-10-19) pushes `record.to_journal.merge(...)`, a plain Hash, onto that channel. `Arm::Instrument#price` (`arm/instrument.rb:58`) drains it and maps `to_journal` over every entry. Coordinator-checked.

**Evidence.** A probe on `price` saw 2 `escalation` Hashes per gated call. A task with no tool calls doesn't crash. The default arm ran the same fixture to 32 grades, and round 26 ran reader to 32 grades on the tree before `da728e6b`.

**Fix shape.** Push the record object and let the channel's reader call `to_journal`, or have `price` accept an already-journaled Hash. Pin it with a reader-arm spec that makes 1 `bash` call.

## The MED-HIGH

### l27-4: the opaque-command refusal tells the arm how to escape

T20 refuses the literal routes: the `for ... $(find)` loop 94 times, `sh -c` every time, an outside `write_file` and `list_files`. The refusal text, `LEASED_OPAQUE` (`cli/tool_guard.rb:250-252`), ends "write a script in <lease> and run it". The adaptive-router arm wrote the refused loop verbatim into `<lease>/add_loop.sh`, ran `bash add_loop.sh` (exit 0), and rewrote `parent/sentinel.rb` and the launch repo's tracked `lib/x.rb` at 01:10:16Z. A second worktree did the same with `echo x > parent/escape-sh.txt`. Captures: `~/tmp/lain-qa-2026-10-21-l/records/esc-calls.txt`, `launch-repo.diff`, `sentinel.as-written-by-arm`.

Fix shape: drop the script advice from the refusal, and treat a program written this session (the tripwire already records `fresh_program`) as opaque in a leased run.

## The MEDIUMs

### d27-5: `grep` on a single file is always withheld

`printf 'alpha line\nbeta line\n' > gdir/g.txt`, then `grep beta gdir/g.txt` returns `1 match withheld (malformed)`; the control `grep beta gdir` returns `g.txt:2:beta line`. `withhold_secret_paths.rb:353-366` joins a single-file row onto the file itself (`/p/gdir/g.txt/gdir/g.txt`), `Sensitivity::Policy#listed_judge` calls `#landed` (`policy.rb:630-640`), and `Landing.of` raises `Errno::ENOTDIR` through a file, which reads as malformed. The comment's "can only be stricter" became "always withheld" when landing resolution arrived. Fork g notes secret-boundary §4b2 item 7 already lists a relative single-file grep as withheld; an absolute path masks correctly. Fix: classify the target file's own path when the target is a file.

### d27-6: resume salvage loses the human's prompt

A prompt's user `turn` is journaled only together with its reply: `request_sent`, then the user turn, then the assistant turn. A real SIGKILL mid-stream leaves `request_sent` and no user turn. Salvage (`session_record/salvage.rb`) then commits the recovered answer onto the replayed head, and the prompt is in no turn. Fork d: the answer `iota` parented on a chain-file tool result. Fork j, on the cloud: the recovered turn's digest differs from the original's and its `render_parent` is null. Control (fork j): a cut after a tool continuation's `request_sent` recovers a digest equal to the original's, so j25-1 holds on that shape. Round 26's "digest equals the original's" used a cut that kept the user turn. Fix: rebuild the user turn from the `request_sent` payload, which carries the prompt.

### i27-1: credential shapes the memory write guard misses

`CredentialPatterns::WRITE` (`credential_patterns.rb:60-80`) misses `{"password": "..."}` (the assignment rule needs the separator straight after the word), `PGPASSWORD=` (the `(?<![A-Za-z0-9])` lookbehind), `MYSQL_PWD=`, `scheme://user:pw@host` and `Authorization: Bearer` (no rows). `memory_write` of the JSON shape returned `wrote memory item "dbjson"`, and the next fresh chat's session file held that value and 4 other planted fake values in `memory_loaded`. The read side masks all 5 as `<redacted:1>`. `DB_PASSWORD=hunter2pass` is refused, so g26-2 holds for the shapes it named. Related, fork g, g27-3: the write table has no GitHub token row, so a bare 36-character `ghp_` token typed at `you>` sits raw in `$XDG_STATE_HOME/lain/history`. Fix: run the read side's region detector on writes, and move issuer-fixed rows (GitHub) into the write table.

### b27-1: Ctrl-C right after Enter loses the line

Sent as `"<line>"`, Enter and C-c in 1 tmux command. `LineEditor.typed?` (`line_editor.rb:111`) reads Reline's buffer, which still holds the accepted line until the next read (its own comment at `:100-105`). In the input pane, `InputPane#typing?` (`input_pane.rb:166-168`) goes to `redrawn_whole`, which stops the draw task; in the plain chat, `StdinPump#typed?` (`stdin_pump.rb:180`) is true and `Intake#interrupt` (`intake.rb:255-262`) withdraws the prompt. 2 losses in the cockpit and 1 in the plain chat, each against a control line with no Ctrl-C that was committed; with 0.3 s between Enter and Ctrl-C the line arrives. This is the round 26 follow-up "a prompt-scoped `StdinPump#typed?`".

### f27-1: `/rewind` leaves the todo list

`Session#rewound_to` (`session.rb:202-206`) moves back the read set and memory view, not the todos, and `Replay#restore_todos` (`session_record/replay.rb:148`) folds every `todo_snapshot` in the file whatever chain wrote it. After `/rewind 50` to an empty session, the next request held 1 message plus a `<workspace>` todo list naming the rewound code word TULIP, and the model answered TULIP. A kept and resumed `/btw` fork answered "IRIS,TULIP", though TULIP was rewound before the fork.

### h26-7: a retry reuses a stale issue branch

`epic/demo` moved `c26e4ee` to `fdabdbe`. On the retry, the fresh issue was cut at `fdabdbe`; shout reused `lain/issue/demo/shout` at `c26e4ee`, with no delete question, so its red commit and gated commit sit on the stale base and `tests_ran` measured a tree that would never land. `Earlier#branches` (`cli/epic_driver/issue_actor.rb:113-118`) drops the branch from the question because its tip is an ancestor of `epic/<slug>`, and `IssueActor#cut` (`:389-396`) calls `WorkingBranch.owned(from:)`, whose `standing(owned_only)` (`isolation/working_branch.rb:184-187, 347-349`) reuses an owned branch and ignores `from`. Snapshots: `~/tmp/lain-qa-2026-10-21-h/records/branches-*.txt`. Fix: fast-forward a reused branch whose tip is an ancestor of `from`.

### h27-4: `land` names a denied attempt

shout's attempt 2 anchored only its red commit. `lain epic land shout demo` then said to approve `22f21e02...`, attempt 1's commit, which the human denied at 00:18:42, whose `tests_ran` read `0 passed 1 error`, and whose branch the retry deleted. `LocalLanding#missing_approval` (`forge/local_landing.rb:232-237`) offers every anchored implementation sha from every attempt and filters only red-only ones. Fix: the newest attempt's anchors only, skipping a sha whose newest gate decision is a deny.

### h27-2: the code reviewer reviews a tree without the work

The orchestrator wrote `lib/greeting.rb` uncommitted, then spawned `reviewer_code` on it. The reviewer's lease was cut from the committed tip; its `read_file lib/greeting.rb` got `no such file` and it asked the human. Same for shout and wave, 3 of 3. Nothing in `issue_orchestrator.md` says a child sees only committed work, and the spawn names no commit. Fix: commit before spawning a reviewer, or lease from the orchestrator's working tree.

### h27-3: gc can strand an approved commit

`Isolation::Gc` counts any local branch as safe elsewhere (`isolation/gc.rb:14-17, 127-134`), while `LocalLanding#anchored` admits only an anchored commit (`:107-109`). A live gc reaped `refs/lain/worker/issue.demo.shout.2-...` as "folded into lain/issue/demo/shout" while shout was unlanded. The full chain (deferred implementation gate, gc, approve, land) was not run end to end. Reproduction: `gate :implementation, :deferred`, run an issue to its parked gate, `lain worktrees gc`, `lain epic approve <digest>`, `lain epic land <id>`.

### h27-1: a stale parked submission blocks a stage invisibly

Research v1 parked, v2 approved, output `research completed, epic_plan started`. Status then read `0 gates parked` beside `epic_plan is not open: research still holds parked sign-offs`, and denying v1, the remedy offered, withdrew v2's approval. `Refold#parked_at` counts only `watched(stage)` (`epic/progress.rb:179-187`).

### i27-3 / k27-1: a chat's researcher gets 24 iterations, not 60 (ruling)

`Ceilings#attenuate` (`budget/ceilings.rb:31-42`, since `56cb1269` and `a4478302`, 2026-10-19) meets the role's 60 (`role/catalog.rb:37`) with what the parent ask has left of 25 (`budget.rb:12`), so the role's 60 is unreachable from any chat and a later spawn gets less. Fork i's researcher stopped at `loop ran 24 iterations, ceiling is 24`; fork k's warned "5 of 24 iterations remain" and stopped itself after 23 of 60 files, which blocked greenfield-epic §6.3 and §6.4. It undoes the 2026-10-08 trial fix for researchers that lost their work at 25, and `role/catalog.rb:33` still says research "gets a ceiling above the default". Nothing on screen says the ceiling was clamped. Ruling needed: "a child never outranks its spawner" against "a researcher needs 60".

### i27-5: `lain improve` swallows its own count

Over 4 lineages the pass ran 346 s, grew past the 32k window, and ollama refused with `exceed_context_size_error`. The terminal showed only the raw JSON body and exit 1, while `improvements.ndjson` went from 0 to 51 lines. `cli/improve.rb:229-234` rescues `Budget::Exceeded` and `Response::Failed`, not `Provider::Ollama::WindowExceededError` (`provider/ollama.rb:68,458`). `lain consolidate` has the same shape. Fix: rescue `Lain::WindowExceeded` and say how many were stored.

### m27-3: a worker's commit is declined at the ceiling and nobody is told

When a chat worker commits and then raises at its ceiling, `Leases#hold` hands the lease back from `ensure` (`isolation/leases.rb:207-217`); the surrender's "work anchored on the ref; no merge was attempted" is dropped and only the partial answer reaches the parent (`tools/subagent.rb:400-401`). spawn.2 committed `5cb052a`, hit the ceiling, and the journal has `handback declined` with the ref while the pane has no bracketed handback line. Controls: an uncommitted spawn and a committed one under the ceiling both got their line. Fix: append the surrender's summary to the ceiling message.

### k27-2: `checkout` scope writes outside the project with nobody asked (ruling)

During `/research-epic` the judge approved `rm -rf /tmp/frugirl-spike && cargo new ...` with cwd `/tmp`, and `write_file /tmp/frugirl-spike/src/main.rs` then ran with no escalation record. A non-interactive `--approval ask` one-shot wrote `$QA/parent/ctl/outside.txt` with 0 escalations, the only trace "1 path outside ... went unrecorded". `ARCHITECTURE.md:674` documents checkout scope as unconfined, `ConfineToScope` confines only plan scope and leases, and the outside-project gate (`sensitivity/policy.rb:255-260`) covers only reading tools for confined sessions. So a child reading outside the project parks while the main agent writing outside it does not. Documented scope, filed as UX with a ruling asked. The spike repo was moved into `~/tmp/lain-qa-2026-10-21-k/records/tmp-frugirl-spike-evidence/`.

### a27-2: text beside a tool call never reaches the screen

In a turn that both writes text and calls a tool, the text is journaled and never drawn, in the plain chat and the cockpit's chat pane. The journal held the requested paragraphs; the human saw only "I've completed the paragraph". `render_response` (`frontend/tty.rb:307`) draws only the final response.

## Per-fork findings, LOW to LOW-MED

| fork | findings |
|---|---|
| a | a27-1 LOW-MED (`--resume` drops a typed `--max-tokens` with no notice, `cli/resume/mismatch_notices.rb:14`, while the same resume names a changed `--compact-keep`; re-arms b27-4; fork c saw it too as c27-3) |
| b | b27-2 LOW (one file named `tally/lib/tally.rb` in the sidebar and unread-row refusal and `../tally/lib/tally.rb` in the not-handed-back and blocker refusals and the thread header); b27-3 LOW (after `c` cancels the close countdown, 2 header rows stack; the round 26 "status line twice" follow-up); b27-5 LOW UX (a skill or docent child's fleet row shows the start of its prompt, `# critique Review what...`) |
| c | c27-2 LOW-MED (c26-2 survives when the answer carries a tool call: T62's `unanswered_prompt_kept`, `strategy/summarize_conversation.rb:69-75`, checks the outer span, and `ToolMessages.conversational_runs`, `tool_messages.rb:50-54`, then splits it); LOW nit (the dedup result says "same result as call call_riwx07s2") |
| d | d27-1 LOW-MED UX (`--root P` launched from another directory files the session under the launch directory's hash, `paths.rb:258`, `journal.rb:104`, so `lain sessions` and `--resume` in P cannot see it); d27-2 LOW-MED (`read_file`'s advice `head -c 16384` on a 1-line file cost 16,488 tokens, 50% of a 32k window; `bounds.rb:191-195` claims 40% at worst); d27-3 LOW (`NARROWER`, `round_budget.rb:18`, has a row only for `read_file`); d27-4 LOW (a stopped `ask_human` is told "its effects may be partly applied"); d27-7 LOW UX (a first prompt that alone overflows the window is offered `/rewind`, `/unpin` or a narrower read); `lain sessions` says "1 turns" |
| e | e27-1 LOW-MED UX (a missing `lain-fence` is announced as "the box lacks landlock": `Confine::Probe#gap_for`, `confine/probe.rb:83-88`, records the real reason and `Confine::Sandbox#unsandboxed`, `confine/sandbox.rb:69`, drops it; `lain-fence --status` reads ABI 9); e27-2 LOW (env prefixes, `timeout`, `nice`, `time`, `npm test`, `bundle --version`, `echo $HOME`, `cd lib; ls` still read opaque and are refused in a leased unattended run; `named.rb:538` treats `bundle --version` as running a program; `git status` lists `status` as a path) |
| f | f27-2 LOW (an all-digit digest prefix is a count to `/rewind`, `rewind.rb:121`, and a digest to `/pin`; `0012` in a long session would rewind by 12); f27-3 LOW (`/fork` says "a question is parked" when an approval is); f27-4 LOW (a builtin journals `resolved: null, builtin: true` and still names `/usr/bin/echo` and class `system`); f27-5 LOW UX (a call parked for a credential says "no rule had an opinion" and shows no note) |
| g | g27-3 LOW-MED (above, under i27-1); g27-1 LOW-MED (the dotenv rule masks ordinary environment lines: `NAME_HINT`, `regions.rb:51`, holds `session`, and `Entropy.high?` on a whole path value, `regions.rb:299`; 7 regions in 1 `printenv`, 5 false; `token_count = 123456` and `blake3:` digests are masked too); g27-2 LOW UX (`RoundBudget::Pass#answer`, `tool/round_budget.rb:139-141`, dedups on the masked content, so 4 different secret outputs were "same result as call ..."); LOW nit (an `ast_search` value is `<redacted:1>` in the row and `<redacted:2>` in its capture) |
| h | h27-5 LOW-MED gap (an in-flight issue that cannot land cannot be retired: `[!]` is overridden, removing it makes every command refuse, and `Discovered from:` silently folds it into another issue's done); LOW nits: an unreadable epic home prints raw `Permission denied @ dir_initialize`; a `denied blake3:...` line names no policy; "delete removes all 1 of these"; `land` checks the landing lease before approval |
| i | i27-2 LOW-MED (`lain consolidate` and `improve` read the approval judge's spawn as a lineage, `bench/session/lineages.rb:174-178`, and the clerk stored "Approved ruby syntax check for lib/b/big.rb" as a memory); i27-4 LOW-MED (`rustc --version` journals `tripwire unresolved_exec strong would_stop` every run, through rustup's proxy exec); i27-6 LOW (`improvement_write` stores byte-identical notes: 51 notes, 4 distinct); `questions_consumed` twice for a relayed child question (check against d26-4); `/quit` while a question waits says "a reply prompt" beside `command>` |
| j | j27-1 LOW (a Module middleware refusal still prints `#<Class:0x...>::Mo`, `config/middleware.rb:38` uses `inspect` and not `describe`); j27-2 LOW gap (the window probe never runs user `http` entries, `provider/ollama/transport.rb:231`, while the comment at `:225-227` says otherwise) |
| l | l27-6 LOW-MED UX (a wholly failed arm's `n` counts failures, `2 of 2`; a partial arm's counts survivors, `1 of 2`); l27-1 LOW (2 refusals leave a 159-byte journal); l27-3 LOW (a default-arm run writes no `run_arms`, so `"opaque": "refused"` is never recorded); l27-5 LOW UX (variance numbers survivors 1 and 2 beside files `1.ndjson`, `3.ndjson`); l27-7 LOW (a SIGINT run prints the partial report and exits 0) |
| m | m27-1 LOW-MED (no verify configured stores `verification: null`, so `wait` never says `verification skipped`: T83 changed only `cli/land.rb` and `Batch#judged?`, `batch.rb:56, 70`, drops `:skipped`); m27-2 LOW UX (a failed verify prints its command shell-escaped) |

### Withdrawn or not filed

- **A parent re-running a `list_files` a human had denied to a child** (fork g): deny memory is per requester, by design.
- **a26-3's first attempt** (fork g): the planted tokens were 40 characters and below the detector; re-driven with 36-character ones, it passes.
- **"The judge approved" lines after a manual approval** (fork m): separate repeat calls.
- **A SIGTERM gc "inconclusive"** (fork l): the CLI gc ran without `env.sh`; under the sandbox env it reaped correctly.
- **The round-budget withholding an 8,283-byte file that would fit later** (fork c): matches "delivered while the budget lasts".
- **h26-2** (fork h): Bundler did not rewrite the lockfile, so not reproducible here.

## Third-party behaviour

- **qwen3-coder:30b.** Calls `ask_human` after nearly every instruction and deny (forks b, h); runs `todo_write` despite "no tools" and then loops `session_usage` to the ceiling once every todo is done (forks a, c); writes tool calls as prose and then repeats lain's own "a tool call written as text was withheld" sentence as its answer (forks d, f, i, j, l); loops `rustc --version` 20 times and `memory_read` on a masked item 13 times (fork i); invents a skill `run_skill context_strategy` (fork e); appends the rendered `<workspace>` block to a `write_file` body (fork g); writes 4 wrong expectations into its own 13 specs, and `/critique` calls a 5/5 scorer buggy (fork b); a red step re-runs a failing spec to the 25-call ceiling until a project slot says "stop once red" (fork h).
- **qwen3-coder:30b as the handoff summarizer** invented progress ("Tag storage implemented using PostgreSQL jsonb column") and carried it through 3 generations (fork c).
- **qwen3:4b as the secret oracle** approved `vault-pass.txt`, `config/master.key`, `server.pem`, `.env.local` and `notes/config.txt` at 0.9; lain applied none (fork g). As the router's cheap branch it ran out of the bench's 4,096-token default on 2 tasks (fork l).
- **glm-5.3 (cloud)** batches 10 reads per round, built a throwaway Rust project in `/tmp`, and the judge approved an `rm -rf` outside the project; judge latency 19 to 29 s (fork k).

## Process notes

Folded into `method.md` under "Round 27".

- **b27-4 changes how every long session must launch.** Until it is fixed, pass `--max-tokens 32768` on every launch and every `--resume`, and append it to `/btw`'s printed command. Record 1 untyped control when a section tests the default.
- **Fork l's sandbox leaked 3 files**: a `sed` `w` flag wrote a 133-byte scrap into the repo root, and a CLI `lain worktrees gc` run without `env.sh` wrote 2 empty files under the real `~/.local/state/lain/gc/`. The coordinator removed all 3 after reading them. The `gc` directory's mtime still reads newer than the round start, with no new file in it; that is the only residue.
- **Planted GitHub tokens must be `ghp_` plus exactly 36 characters**, or the detector never matches and a check passes vacuously (fork g).
- **Fork g hit the 200-turn limit** on secret-boundary plus survey and was resumed; give secret-boundary its own fork.
- **In an `ask` session the user turn is journaled only with its reply**, so wait on a bare `you>` or a parked call, never on a quiet journal (fork f). An 8 s quiet window sent a prompt mid-ask as a note for the agent; use 15 s or more (fork d).
- **zsh**: quote every value on a launch line (`?` in a URL globs), use a function for a command with arguments, and `${=a}` to split a variable (forks g, h).
- **`@lain_input_pane` is a session option**: `show-options -t <session> -v`, not `-gv` (fork c).
- **Gatekeepers**: anchor danger patterns to the command word (a `puma` gem path denied a `wc`), split on `;` only outside quotes, and set `ENV["QA_SOCK"]` inside the script (forks b, c, h).
- **Seed the sandbox git identity with `--file "$XDG_CONFIG_HOME/git/config"`**: `git config --global` stayed in the sandbox only because this box has no `~/.gitconfig` (fork m).
- **Restart a body-dumping proxy into a fresh directory**, or its `req-NNNN` numbering overwrites earlier dumps (fork i).
- **ollama-cloud-arm §6b's TLS stub certificate had expired**; fork j regenerated it for 30 days at `~/tmp/lain-qa-2026-10-21-j/records/stub`.
- **Runner swaps announced:** `/model qwen3:4b` 23:34 to 23:36 (forks a, c), a `--num-ctx 8192` probe 23:19 (fork c), the secret oracle burst 00:07 to 00:13Z (fork g).

## Scenario corrections owed

The forks proposed these and the coordinator has not yet folded them into the scenario files; the fix plan's documentation card should.

- **rails-blog**: §0 attestation now ends `(elided -- no summary was taken)`; §1b every compaction act needs `--max-tokens` until b27-4 is fixed; §5's switch line wording.
- **session-and-window**: the 2 new arms in the header, the new resume and variance wording, the `fallback` ceiling source on ollama-cloud.
- **failure-injection**: §2 and §3 refusals print full quoted digests; §9 "Windows add up: ..."; §1b's salvage cut must drop the prompt (d27-6); drop §8's two-arm line.
- **ollama-cloud-arm**: §5 adds the prompt-dropping salvage cut.
- **bash-confinement**: §3 only 2 of 3 calls park under `ask`; §6 the header always has `arms`, and `capability_degraded` precedes the header.
- **shell-term-approval**: the verdict constants moved to `Shell::Programs` (`programs.rb:41-94`); `base_tools.rb` is gone (`WebFetch.new` at `cli/wiring.rb:156`); Triage abstains on a bare `cat .netrc`.
- **secret-boundary**: §4d item 4 `%w[~]` gets the unspecific sentence; §5 the bypass retype refusal is a different sentence by design; §5 `read_file ~/.netrc` is refused outright; §6 D-3's `.env.local` waits for the human; §2 use a gated glob that does not overlap the name rule.
- **survey**: §1 a one-shot from another directory names rows relative to the cwd.
- **subagents-and-backends / memory-and-dogfood**: `request_sent` now carries the main agent's whole payload; children journal `turn_usage` without `memory_root`; the error is `Lain::Budget::Exceeded`; a one-shot `lain watch` is 2 lines; §2b and greenfield-epic §6 say 60 (i27-3).
- **greenfield-epic**: §6.8 the in-project write is refused by the lease; §4.8 the record is `source_masked`; §6 the lease is `Isolation::Spike` under `extends`.
- **epic-tier**: §10e h26-7 reproduced with its mechanism; §12 h27-4; §5d clean approve driven; §10a T40 driven.
- **bench-arms**: l26-2's 13 MB `sort` cannot show `reader` (ComposedTerm approves nothing over 64 KiB, `cli/wiring/board_build.rb:408`).
- **cockpit-surfaces**: §0 check 16 adds "Enter then an immediate Ctrl-C"; count header rows after `c`.
- **config-middleware**: step 3 Module refusal; step 6 the probe skips `http` entries.
- **merge-coordinator**: §5 has had no live drive for 2 rounds; schedule it in the epic-tier fork.

## Close-out

Every fork killed its own processes, tmux server, listeners and sandbox `catatonit`, and reported its negatives. The coordinator stopped the ollama server it started (pid 238112). No port in 22100 to 23399 or 11434 listens, and the only `catatonit` is the operator's (99149). `env -u XDG_CONFIG_HOME git status --porcelain` matches the baseline byte for byte, `git worktree list` reads 1 line, and there is no `.lain` in the checkout, no `~/.lain` and no `~/.config/lain`. dunst reads 0 and 0. `find ~/.local/state/lain -newermt 2026-10-21T22:42:24Z` prints only the `gc` directory (fork l's leak, its files removed), against a control of 187. `/tmp/frugirl-spike` is gone. Every sandbox `~/tmp/lain-qa-2026-10-21-<a..m>` is left in place as evidence, each with its `records/fork-report.md`.
