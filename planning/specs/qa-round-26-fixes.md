# QA round 26 fixes: a Ctrl-C that only clears, a lease that refuses what it cannot read, and records that agree with the screen

status: in-progress (panel-reviewed 2026-10-19)
commit-mode: orchestrator-commits
language: ruby (1 card edits nvim Lua: T11)
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

Fix every finding in [`planning/qa-findings-round26-2026-10-18.md`](../qa-findings-round26-2026-10-18.md) rated MEDIUM
or higher, the LOW to LOW-MED items with a fix in a file this plan already opens, and the round 25 items still open
(a25-6, c25-6, c25-7, f25-5, k25-4, b25-6, b25-10), by the user's ask of 2026-10-19. The Coverage table maps every
finding to its card and names what is left for round 27. Roadmap: `ROADMAP.md` item 65.

The user ruled 9 questions while this plan was written (memory `qa-round-26-rulings.md`):

| finding | ruling |
|---|---|
| b26-1 | Ctrl-C discards the typed line only; it never ends the cockpit over a non-empty line (round 25's ruling, now at a drawn prompt) |
| a25-6 | `LD_LIBRARY_PATH` leaves `ChildEnv::KEEP`; a machine that needs it passes it with `LAIN_ENV_PASS` |
| a26-3 | "always mask" covers the live display: the chat pane and `lain://journal` show what the record shows |
| h26-3 | an uninitialized constant the issue's subject will define counts as red; other load errors stay refused |
| l26-1 | a leased run with no human attached refuses any bash command whose paths cannot be read |
| i26-1 | fix at the source (no credential stored, `memory_read` masked); `memory_loaded` stays raw so resume replays exactly |
| d26-5 | the main agent is `agent`; every acting agent shows a name and the role or skill it runs under |
| c26-3 | a per-round result budget at production, a handoff that declines when it cannot help, and an opt-in stub arm for a committed round (after research, Spike findings) |
| `max_tokens` | split into a per-model output ceiling on the wire and one reply reserve the planners read |

Round 26's defects cluster around 4 missing concepts:

| Missing concept | Findings | Cards |
|---|---|---|
| a typed line belongs to the pane until it is sent | b26-1, b26-4 | T1, T2, T6 |
| a run with no human refuses what it cannot check | l26-1, g26-3, h26-1 | T20, T33, T36 to T38 |
| the screen shows what the record holds | a26-3, g26-2, l26-2, l26-4, d26-3, j26-2 | T27, T28, T50, T51, T22, T23, T64, T65 |
| a setting the human chose survives the session that chose it | a26-2, d26-1 | T58, T59, T3 |
| a reply's room is planned apart from its ceiling | c26-3, `max_tokens` | T87 to T89, T91, T92 to T94, T61 |

## Coverage

| finding | card | finding | card | finding | card |
|---|---|---|---|---|---|
| **b26-1 HIGH** | T1, T2 | h26-1 MED-HIGH | T36, T37, T38 | l26-1 MED-HIGH | T20 |
| g26-2 | T50, T51 | i26-1 | T50, T51 (ruled: source only) | m26-1 | T78, T79, T80 |
| h26-2 | T39 | h26-3 | T40 | h26-4 | T41 |
| l26-2 | T21, T22 | a26-2 | T58, T59 | c26-1 | T60 |
| c26-3 | T61, T92, T93, T94 | d26-1 | T3 | a25-6 | T26 |
| a26-3 | T27, T28 | b26-2 | T4 | b26-6 | T5 |
| b26-4 | T6 | b26-3 | T7 | b26-5 | T8 |
| b25-6 | T9 | b25-10 | T10 | k25-4 | T11 |
| k26-3 | T12 | k26-6 | T13 | k26-1 | T14 |
| d26-5, f26-1 | T15, T16 | f26-3 | T17 | f26-5 | T18 |
| f25-5 | T19 | c26-4 | T25 | l26-3, a26-5 | T24 |
| l26-4 | T21, T23 | l26-5 | T34 | e26-1 | T30 |
| e26-2 | T31 | e26-3 | T32 | g26-3 | T33 |
| f26-4 | T35 | k26-7 | T29 | h26-5 | T42 |
| h26-6 | T43 | h26-8 | T45 | h26-9 | T46 |
| h26-10 | T47 | `review` `--base` hint | T48 | k26-10 | T49 |
| d26-7 | T52 | g26-1 | T53 | k26-4 | T54 |
| k26-5 | T55 | f26-2 | T56 | f25-3 | T57 |
| c26-2 | T62 | a26-1 | T63 | j26-2 | T64 |
| d26-3 | T65 | d26-2 | T66 | d26-4 | T67 |
| d26-6 | T68 | c25-6 | T69 | c25-7 | T70 |
| j26-1, j26-5 | T71 | j26-3 | T72 | j26-4 | T73 |
| k26-8 | T74 | i26-2 | T75 | i26-4 | T76 |
| i26-5 | T77 | m26-2 | T81 | m26-3 | T82 |
| m26-4 | T83 | m26-5 | T84 | m26-6 | T85 |
| g26-4 (docs only) | T90 | every scenario note | T90 | `max_tokens` as reserve and ceiling (ruled) | T87, T88, T89, T91 |

**Left for round 27, with the reason:**

- **h26-7** (a retry reuses a stale issue branch): 3 candidate mechanisms in `IssueActor#cut`, `WorkingBranch#standing` and
  `Earlier#branches`, and the QA record does not say which fired. Re-drive with the branch state captured.
- **i26-3** (a worker path hashes its id against the process cwd): fixing it renames every existing worker worktree and
  compose project for a LOW finding. Rejected options.
- **a26-4** (a typed `--num-ctx` resolves `guessed`): deliberate, `cli/backend/window_book.rb:349-358` records why a
  number the provider did not confirm may not authorise a rewrite. T90 documents it as scope.
- **c26-5** (untyped compaction defaults are not in the header): round 20's RB-2 ruling keeps them out, pinned at
  `spec/lain/cli/backend_spec.rb:1744`. Rejected options.
- **a26-6** (a stream prefix lands mid-line): the finding is 1 clause and fork a's report has no record of it. The
  likely site is `Frontend::Decorators::ToolOutput#render` (`frontend/decorators.rb:66-69`); not filed until re-seen.
- **b26-3's resume half**: T7 keeps the note live; replaying it into a resumed thread needs the docent's records to
  carry the note, a format change for a LOW.

## Preflight

The executor checks this before cutting any worktree:

1. **The main checkout holds no other session's uncommitted `lib/` or `spec/` edits.** At planning time
   `git status --porcelain lib spec` was empty and the only uncommitted files were `planning/qa/` documents (QA round
   26's own edits, which T90 builds on) and untracked research notes. If `lib/` or `spec/` lists anything, ask the
   user before starting. Never stash or commit another session's edits.
2. **Commit QA round 26's documents first.** `planning/qa/README.md`, `planning/qa/method.md`, the 20 modified
   scenario files and `planning/qa-findings-round26-2026-10-18.md` are uncommitted. T90 edits the same scenarios.
   Ask the user to commit them (or to say they stay uncommitted, in which case T90 runs in the main checkout last).
3. **Base SHA.** Cut every card's worktree from `main` as it stands after step 2 and record that SHA in the Execution
   log. Line numbers here were read at `6054ba1d`; an implementer re-reads each cited site before editing it.
4. **Worktree and branch names.** `tmp/worktrees/r26-T<id>`, branch `card/r26-T<id>`.

## Grounding

2026-10-19, at `6054ba1d` (HEAD; `git status --porcelain lib spec` empty).

7 Explore passes read the production path behind every finding and reported current line numbers; their condensed
notes are the source of every citation below. Citations in the findings file that moved or were wrong:

- m26-2 cites `merge_coordinator/drain.rb:118`; the producing line is `:115` (`uniq` keeps the oldest entry).
- m26-1 cites `verifier/command.rb:31`; the lock is held at `:33`. The verify child is already `pgroup: true`
  (`shell/out.rb:206-211`); what is missing is any takeover of a stale holder.
- a26-4 cites `context_window.rb:431` (the generic fallback); the `--num-ctx` path is `window_book.rb:340-359`.
- c26-5 cites `compaction_profile.rb:52`, which is `schedule_or_default`.
- d26-4 is the child-question double record (B-5, `cockpit-surfaces.md:1166-1176`), not an ordinary answer:
  `Scribe#consumption` runs only for a spawned chain's turn (`session_record/scribe.rb:352-356`).
- b26-4 is Reline drawing its prompt on every row of a multi-line buffer (reline 0.7.0 `line_editor.rb:465`); lain
  holds the paste correctly and draws nothing of its own.
- k26-3's "no hint row" is wrong: the hint is `virt_lines` (`runtime/60_question.lua:35,77-80`), pinned at
  `60_question_spec.rb:110`. The refusal wording half stands.
- l26-2's "the bench ladder never produces a reader ruling" is wrong: `confinement_spec.rb:137` earns the reader
  profile for an in-lease `cat`. An outside `cat` abstains at `ComposedTerm` and runs traced. What is missing is the
  record: the per-agent journal holding `sandbox` records is drained by `Arm::Instrument#price` (`arm/instrument.rb:58`).
- k26-7 is fork k's `git -C sibling ... 2>&1`: the `2>&1` duplication makes `Shell::Named` call the command opaque.
- a26-5 does not reproduce: `bench variance <id>` exits 1 with `no session file at <id>`. Fork a's own note says the
  verb takes a path, not an id; T24 makes the refusal say so.

Probed rather than read:

- **The credential pattern** (`credential_patterns.rb:76`): all 6 compound shapes return no match today. A first
  replacement (word as the last identifier segment) matched all 6 but also refused 8 ordinary shapes such as
  `access_token = request.headers['X']` and `id_token: nil` (the panel's probe, `r26plan/probes/panel_t50.rb`), so
  T50 adds a literal-value test and makes both lists criteria.
- **Opaque commands**: `Shell::Named.of` returns `opaque=true, paths=[]` for `cd /p && for f in $(find .); do mv t
  "$f"; done`, `cd /out; touch y`, `(cd /out && touch y)`, `sh -c "cd /out && touch y"` and a newline-joined pair; it
  names `true && cd /out && touch y` (2026-10-19).
- **`related: %w[~]`**: `Sensitivity::Rules.relation` gives the shape sentence for `~` and the unspecific sentence for
  `~/` and `/`.
- **`epic show`**: Thor 1.5.0 `say "b"` prints `b\n`; `say "a\n"` prints `a\n`.
- **The b26-1 pane premise** is a spike (Spike findings).

Files read: every path a card names, plus `lib/lain/cli/tool_guard.rb`, `lib/lain/shell/named.rb`,
`lib/lain/approval/{escalation,judged,queue,composed_term}.rb`, `lib/lain/compaction/{source,boundary}.rb`,
`lib/lain/compaction/source/{held_cut,fallback}.rb`, `lib/lain/agent/tool_runner.rb`,
`lib/lain/bench/session/memory_replay.rb`, `lib/lain/telemetry/memory_loaded.rb`, `lib/lain/liveness.rb`.

Docs that disagree with code (each card or T90 fixes its own):

- `docs/commands.md:250` says Ctrl-C at the pane travels to the chat; false since round 25's T16.
- `docs/commands.md:422-424` and `:458-461` promise verified fast-forwards and one suite at a time; false with no verify
  configured (m26-4) and after a SIGKILL (m26-1).
- `docs/commands.md:1081-1084` shows `deny_tool "web_fetch"`, which is inert: `Gate#gated?` (`middleware/gate.rb:184-198`)
  never asks the policy about a tier-1 tool, and the `Remembered` rule lives only in the ladder (T30).
- `ARCHITECTURE.md:915` and `planning/specs/bash-confinement.md:51,102,266-275` keep `LD_LIBRARY_PATH` (T26 ruling).
- `ARCHITECTURE.md:597` says six guard layers; `tool_guard.rb:380-390` builds ConfineToScope plus 8.
- `ARCHITECTURE.md:1583` says `project_hash` is `SHA256(expand_path(...))`; the code realpaths (`paths.rb:314-319`).
- `planning/qa/scenarios/session-and-window.md:602` says `bench variance` ignores `arms`; `Variance#guard_arms!` refuses.
- `planning/specs/idle-compaction.md` T4 says a no-compaction header has no `compact_schedule`; it always has `turn`.
- `planning/qa/scenarios/greenfield-epic.md:420` says the free-text hint does not exist (k26-3 above).

## Compatibility

| Surface | Verdict | Evidence |
|---|---|---|
| The gem | not published | No release tag (`git tag` lists only `backup/main-pre-msg-rewrite-tag`); memory `harness-vs-own-dev.md`: no back-compat needed |
| Session header | additive | `"compact": false` is written only when compaction is off, so every other header stays byte-identical (T58). The loader's required keys do not change |
| `run_interrupted` record | additive enum | `REASONS` (`telemetry/run_interrupted.rb:38`) gains members (T64, T65); readers `cli/chronicle.rb:401`, `session_record/scribe.rb:286` and `status_feed.rb` take any member of the list |
| `provider_retry` record | additive | gains `path`, nil-defaulted so old lines load (T72) |
| `questions_consumed` record | fewer lines | a child's answer writes 1 record, not 2 (T67); consumers retire by digest, idempotent |
| `memory_loaded` record | unchanged | ruled raw (i26-1) |
| `Escalation::Ruling`, `Queue::Pending` | free to break | internal; new members defaulted (T57) |
| `asked_by` on questions | changes for new sessions | `lain` becomes `agent`, children their requester label (T15, T16); old sessions replay as recorded |
| Suite-lock holder line | additive | `pid=<n> command=<argv>` keeps its prefix (`command_spec` greps `pid=`) and gains `verify_pgid=` and `start=` (T80) |
| Merge spool entry | additive | a superseded entry completes as `declined` with detail (T81) |
| `Channel` | additive | `Channel::Tee` promoted from the private `Bench::ArmSweep::Tee` (T21) |
| `ChildEnv::KEEP` | free to break | internal regexp; `LAIN_ENV_PASS` is the supported way to pass a name (T26) |
| `.lain/config.rb` `deny_tool` | behaviour change | documented in `docs/commands.md:1081-1084` and inert today; T30 makes it act |
| CLI exit status of `lain epic submit` on deny, `lain epic finish` stopped | 0 becomes non-zero | nothing in `~/dev` scripts it (grep, 2026-10-19); T45 |
| CLI flag `--compact` | default removed | an untyped run still compacts; only the recorded value now wins on resume (T58) |
| Handoff document text | free to break | `PREAMBLE` and the rendered heading are outside the oracle definition; the `next_step` key and `TEMPLATE` are kept, so recorded answers keep their address (T60) |
| Shipped skill template `gherkin-tests/skill.md` | free to break | copied into projects at use (T40) |
| Lua `lain://question` `x` map | free to break | internal to the shipped runtime (T11) |
| `--max-tokens` default | behaviour change | 16,384 becomes a per-model ceiling; the header records the value and its source, so a resume and `bench variance` see it (T89). `bench record` and `bench arms` keep their typed defaults |
| `CLI::Arms` | additive members | `round_budget` (`off`, `static`, `window`; default `window`) and `round_stub` (`off`, `on`; default `off`). `Arms#to_header` writes every arm that is not `:off` (`cli/arms.rb:66-68`), so every new chat header gains `"round_budget": "window"`; 12 spec files that pin header hashes move with T93, which lists them. Bench arms record `off` and run with none (T93, T94) |
| `round_bounded` record | new | written only when a budget withholds or deduplicates (T92) |
| `compaction_decision` record | additive | a declined handoff is a new decision value (T61) |

No trade report: no must-keep surface blocks a simplification.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| Can the input pane see a non-empty line-editor buffer at Ctrl-C and clear it without forwarding (b26-1)? | Yes, behind a guard. Bare `editing?` is true for a stale Reline buffer when no prompt is drawn and broke 3 examples; `typing?` = not idle, drawn kind `you` or `command`, and `editing?` holds. Clearing is `@replaced = header_rows(@drawn)` then `redraw(Async::Task.current, @client, @held.over(@drawn))`: `redraw` stops the drawing task and its Reline read, and the new read starts empty. Not covered: bytes still in the kernel queue behind the Ctrl-C (they read as empty and forward), the multiline hint is not reprinted, rows above the cursor of a multiline buffer are not cleared. A plain `--no-nvim` chat ends at `you>` through `Conductor#deliver_idle` (`cli/conductor.rb:494-501`) whatever is typed | worktree `spike/r26-pane` from `6054ba1d`: `input_pane_spec.rb` 87 examples, 2 new failures before (a `signal` frame sent; the line read `half a thoughtd`), 0 after; `seams/input_pane_socket_spec.rb` 19 and 0 both times. Patch kept at the scratchpad `r26plan/spike-r26-pane.diff`; worktree removed |
| Why did 113 KB in one round defeat compaction (c26-3)? | The round alone was about 2.4 times the window. qwen3-coder:30b, window 32,768 (probed), `max_tokens` 16,384; the round's prompt was 7,492 tokens; its 15 `read_file` results were 5 files read 3 times each, 113,614 B at about 1.43 B per token, refused at 86,685 tokens. A handoff only removes history before the unanswered round, which is kept whole so every `tool_use` keeps its `tool_result`; it saved 255 tokens (86,685 to 86,430). Distinct bytes alone (36,568 B, about 25.6k tokens) plus context still miss by about 1% | session file `~/tmp/lain-qa-2026-10-18-c/xdg/state/lain/sessions/08422478a18d/20261018T165322-3008078.ndjson` lines 49 to 70 |
| How do other harnesses handle an oversized newest round? | None compacts it. They bound output where it is produced (Codex head and tail, Claude Code spills to a file) or clear older results and keep the newest (Anthropic `clear_tool_uses_20250919`, OpenCode's prune). The Complexity Trap paper measured deterministic masking of old observations matching LLM summary at half the cost. Summarizing the round in batches would cost 3 or 4 calls that must each fit the same window, and loses the exact text an edit needs | `references/papers/rst/2508.21433.rst` lines 68, 86, 165; `references/repos/smolagents/src/smolagents/agents.py` 1424-1441; platform.claude.com context-editing docs; the user chose a budget at production, a handoff guard and a stub arm (T92, T61, T94) |
| What should `max_tokens` be? | It did 2 jobs. Both wires enforce the window apart from the cap (ollama admits a prompt up to `num_ctx - 1` under `truncate:false` and cuts generation at the window, `done_reason length`; Anthropic 4.5+ accepts input plus cap over the window and stops `model_context_window_exceeded`), so a generous wire ceiling breaks nothing. As the planners' reserve, 16,384 of 32,768 starves them. Over 632 QA journals: qwen3-coder p50 62, p99 1,088, max 2,572 output tokens; glm-5.3 p50 161, p99 8,556, hit 16,384 twice in 304 turns. `max_tokens` is in `Request#digest` but not the prefix digests, and no provider cache keys on it | ollama `llm/llama_server.go` @36a6e994d2 (`completionPromptForRequest` 299-317, `boundedNumPredict` 124-136); platform.claude.com context-windows docs; probe script in the scratchpad `maxtok-usage.rb`; the user adopted the split (T87, T88, T89, T91) |

## Panel review

The Ruby panel returned REQUEST-CHANGES with 3 blockers and 9 should-fixes, traced T20, T92 and T93, T28 and T15 from
`exe/lain`, and confirmed the graph, every Files path, and about 30 cited lines (`Gate#gated?` never asks about a
tier-1 tool, `Answers#blocks` keeps call order, `record_delivery` marks an error result Withheld, the `Arms` members).
Its review and probes are in the planning scratchpad (`r26plan/panel.md`, `r26plan/probes/`). What it changed:

- **T92, T93 (blocker):** the budget could not reach `Agent::ToolRunner`: `Agent#built_tool_runner` (`agent.rb:521-526`)
  takes no budget, and bench agents come from `SpawnSeam`, never `Wiring#run`. T92 now adds `Agent.new(round_budget:)`,
  a policy that builds one budget per round from the Agent's own window and last usage (input and output), lists
  `agent.rb` and waits on T61; T93 wires the chat path and makes `bench arms` record and run `off`. Dedup now keys on
  the result's bytes, so read, edit, read of one file delivers both reads.
- **T27, T28 (blocker):** masking line by line would show a PEM key's tail, and `Masking.render` restarts its numbering
  per call. T27's masker gains a `Stream` that numbers across chunks and holds BEGIN to END; at the cap it masks the
  rest instead of flushing it. T28 names its seam (`Exec::*#child_env` plus the invocation's `worker_env`, read in
  `Bash#output_sink`) and gains PEM and unterminated-hold criteria.
- **T29 (blocker):** its premise was false: `git -C sibling log` is opaque without `2>&1`, because `DIRECTORY_LETTERS`
  defaults to `C`. Rescoped to a read-only `git -C <dir>` at medium risk, with `git -C /outside` still held.
- **T93, T94:** `Arms#to_header` writes every arm not `:off`, so the no-budget value is `off`, every new header gains
  `round_budget`, and T93 lists the 12 spec files that pin header hashes.
- **T15, T16, T2, T30:** missing files added (`tool_guard.rb`, `wiring.rb`, `board_build.rb`), with the order T20, T30,
  T15, T16, T57 over `tool_guard.rb` and T2 before T14. T30 gained an Interface: the Gate takes `denied_tools:`.
- **T15, T86:** `Requester` gained a `label` apart from its `name` (the denial key), one home for the bare-word rule,
  frozen members, and constants on the reopen.
- **T50:** the first regexp refused ordinary code (`access_token = request.headers['X']`, `id_token: nil`, 8 shapes
  in all) and missed `SECRET_KEY_BASE=`. The value must now look like a literal, and those lines are criteria.
- **T20:** `ruby -e` and `xargs` criteria, corrected advice, and both bench confinement branches; T22 records the
  policy in `run_arms` so `bench variance` does not pool runs from before T20.
- **T36:** an empty range is not red-only. **T80:** the stale-group notice goes to `drain.log` through a `notice:`.
- **T89:** the card applies its `exe/lain` default in its own worktree, lists `chat_flags_spec.rb` and `cli_spec.rb`,
  says what `/model` does to an untyped ceiling, and stops on the non-streaming read timeout.
- **Nits taken:** T21 defaults to a pass-everything predicate; T16 says the role once; T94 reuses
  `Session#withhold_rounds`; T26 probes before proposing the `CLAUDE.md` line; T92 says 1.31 bytes per token is the
  deliberate worst case.

Not taken: none.

## Shared files

Only the main session edits these. Cards hand back the exact text.

- `ROADMAP.md` (item 65 at planning; T90 hands back the "done" line)
- `CLAUDE.md` (T26: the `LD_LIBRARY_PATH` export line)
- `ARCHITECTURE.md` (T20, T26, T28, T50, T51, T60, T61, T64, T92, T94; and the stale counts named in Grounding, applied by T90)
- `docs/commands.md` (T1, T30, T45, T58, T80, T83, T89, T93)
- `exe/lain` (T14, T22, T45, T49, T58, T89, T93, T94)
- `.rubocop.yml`, `spec/support/slow_files.rb`

## Rejected options

- **Judging h26-2's stray writes by the child's write records alone:** `bash` journals only paths a command names, so
  `rm`, `git mv` and Bundler's rewrite leave no record; `issue_tests_spec.rb:279,288` pin `rm` and `git mv` as strays.
  T39 exempts the preset's own lockfile instead.
- **Masking the journaled `memory_loaded` copy (i26-1):** ruled out; it changes item digests, so every `memory_root`
  check and the replay version check would fail as edited.
- **Making the main agent `lain` everywhere (d26-5):** ruled out for `agent`.
- **A 4th window provenance for a typed `--num-ctx` (a26-4):** a number ollama did not confirm stays a request.
- **Recording untyped compaction defaults (c26-5):** RB-2 keeps an all-default header byte-identical.
- **A stable hash for worker ids (i26-3):** renames every leftover worktree and compose project for a LOW.
- **Teaching `Shell::Named` to keep a literal leading `cd` of an opaque parse (l26-1, the finding's 2nd shape):** still
  misses `cd x; y` and loops with no `cd`; ruled for refusing opaque commands outright.
- **A write-confined sandbox for bench arms (l26-1's real closure):** a separate design; `ruby x.rb` still writes
  anywhere after T20, and T20's refusal text does not claim otherwise.
- **Refusing every `memory_write` the region detector flags:** the `credential_patterns.rb:8-13` contract says the
  write side must not refuse prose; T50 widens the assignment shape only.
- **Threading an approval into `WithholdSecretPaths`'s filter (g26-1 option B):** touches the boundary's one
  classifier for a LOW-MED; T53 refuses before asking instead.
- **Changing the compaction `Boundary` rule (c26-2 option A):** moves every cut index and digest; T62 changes only
  what the summarizer is shown.
- **A `status` read of the suite-lock holder (m26-5's M half):** T84 writes the wait to `drain.log`; `status` is
  unchanged.
- **Summarizing an oversized round in batches (c26-3, the user's first idea):** 3 or 4 summarizer calls that must each
  fit the same 32k window, two thirds of the input duplicate text, and summaries cannot back an `edit_file`. Research
  above; the user chose T92, T61 and T94.
- **Fitting `max_tokens` to the window per request (OpenCode's `outputLimit`):** both wires already cut at the window,
  it would need the window inside the pure `Context#render`, and it moves `Request#digest` between arms that differ
  only in window.
- **Re-asking at a higher cap after a ceiling stop:** glm-5.3 hit the cap 2 times in 304 turns and qwen never came
  near it; continuing through prefill is a 400 on Anthropic 4.6 and later.

## Open decisions

1. **T90 has no production site**: it edits documents only, so its `Reachable from` is deferred by nature.
2. **bash-confinement §3's bypass leg** (QA round 26 process note): a scenario question only, no card. T90 leaves
   the scenario's note as it stands.

## Dependency graph

```mermaid
flowchart LR
  T1 --> T2
  T4 --> T5
  T2 --> T6
  T2 --> T14
  T4 --> T15
  T5 --> T15
  T7 --> T15
  T9 --> T15
  T14 --> T15
  T30 --> T15
  T8 --> T16
  T15 --> T16
  T16 --> T86
  T21 --> T22
  T21 --> T23
  T22 --> T24
  T26 --> T28
  T27 --> T28
  T20 --> T29
  T20 --> T30
  T28 --> T35
  T36 --> T37
  T36 --> T38
  T36 --> T39
  T39 --> T40
  T38 --> T41
  T41 --> T45
  T42 --> T45
  T40 --> T46
  T41 --> T46
  T45 --> T46
  T43 --> T49
  T28 --> T51
  T50 --> T51
  T51 --> T54
  T16 --> T57
  T19 --> T57
  T20 --> T57
  T30 --> T57
  T74 --> T57
  T58 --> T59
  T58 --> T63
  T25 --> T65
  T64 --> T65
  T16 --> T75
  T86 --> T76
  T78 --> T80
  T79 --> T80
  T82 --> T83
  T80 --> T84
  T79 --> T85
  T60 --> T88
  T87 --> T88
  T58 --> T89
  T63 --> T89
  T25 --> T61
  T61 --> T92
  T66 --> T92
  T87 --> T92
  T15 --> T93
  T22 --> T93
  T24 --> T93
  T58 --> T93
  T59 --> T93
  T89 --> T93
  T92 --> T93
  T61 --> T94
  T93 --> T94
  %% cards with no dependency and no dependent
  T3
  T10
  T11
  T12
  T13
  T17
  T18
  T31
  T32
  T33
  T34
  T47
  T48
  T52
  T53
  T55
  T56
  T62
  T67
  T68
  T69
  T70
  T71
  T72
  T73
  T77
  T81
  T91
  ALL[every other card] --> T90
```

## Tasks

Paths are under `lib/lain/` and `spec/lain/` unless they start with another top-level directory. Every card that
changes a user-visible sentence hands T90 the scenario line it makes stale.

### Cockpit and chat surfaces

### T1: Clear a typed line on Ctrl-C at a drawn prompt in the input pane          [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/input_pane.rb`, `spec/lain/frontend/input_pane_spec.rb`
**Reuse:** `InputPane#editing?` (`input_pane.rb:433`), `#redraw` (`:401-418`), `#header_rows`; the spike's patch (Spike findings): `return discarded_line if name == :sigint && typing?` in `#signal`, `typing?` = `!@idle && %w[you command].include?(@drawn["kind"]) && editing?`
**Shared-file wiring:** `docs/commands.md:51` (the `--grace` row) and `:250`: Ctrl-C over a typed line clears it in the pane and reaches no chat; over an empty line it goes to the chat as before
**Reachable from:** `exe/lain` `input` -> `Frontend::InputPane.open(...).run`; the run fiber (`input_pane.rb:120`) calls `#signal`

**Acceptance criteria**

```gherkin
Scenario: Ctrl-C over a typed line at you> clears it and the chat lives
  Given an input pane with a published prompt of kind "you"
  And the human has typed "half a thought"
  When the human presses Ctrl-C
  Then no signal frame reaches the chat
  And the pane redraws "you>" with an empty line

Scenario: Ctrl-C over a typed line at command> clears it and opens no countdown
  Given a published prompt of kind "command" with an approval parked
  And the human has typed "/stop"
  When the human presses Ctrl-C
  Then no signal frame reaches the chat

Scenario: Ctrl-C over an empty line still reaches the chat
  Given a published prompt of kind "you" and an empty line
  When the human presses Ctrl-C
  Then a signal frame named "sigint" reaches the chat
```
Spec file: `spec/lain/frontend/input_pane_spec.rb` (a PTY pane, like the `unpublished_pane` helper; the existing
describe "a signal the human sends the pane")

**Stop and report if:**
- `spec/lain/seams/input_pane_socket_spec.rb:510` or `:525` (an empty buffer at a parked approval forwards and draws
  the countdown) goes red.
- An approval (`[y/N]`) or `human>` kind needs the same clearing; the ruling names `you>` and `command>` only, so
  say so rather than widen `typing?`.
- A Ctrl-C right behind keystrokes Reline has not read yet forwards; record it in the card's report, do not chase it.

### T2: Clear a typed line on Ctrl-C at a plain chat's prompt          [risk: high]

**Depends on:** T1
**Files:** `lib/lain/cli/conductor.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/cli/conductor_spec.rb`
**Reuse:** `StdinPump#untouched?` (`frontend/stdin_pump.rb:176`), which the Conductor does not hold today and gets injected; the prompt republish the Conductor already does at `you>`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `chat --no-nvim` -> `CLI::Wiring#run` builds the `Conductor` with the `StdinPump`; Ctrl-C at `you>` -> `IdleSignals` -> `Conductor#deliver_idle` (`conductor.rb:494-501`)

**Acceptance criteria**

```gherkin
Scenario: Ctrl-C over a typed line at a plain chat's you> clears it
  Given a plain chat at "you>" with "half a thought" typed
  When the human presses Ctrl-C
  Then the line is empty, "you>" is drawn again, and no Intake signal is pushed

Scenario: Ctrl-C over an empty you> still ends the chat
  Given a plain chat at "you>" with nothing typed
  When the human presses Ctrl-C
  Then an Intake signal named sigint is pushed
```
Spec file: `spec/lain/cli/conductor_spec.rb`

**Stop and report if:**
- `spec/lain/seams/plain_chat_prompt_guards_spec.rb` pins Ctrl-C over typed text at `[y/N]` or `human>` as forwarding.
- `deliver_idle` runs while Reline's read still owns the buffer, so the Conductor cannot clear it without the
  pump's help; then the clearing belongs in `StdinPump` and the card's Files change.

### T3: Warn when `lain up` reattaches to a cockpit whose chat is gone          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/up.rb`, `spec/lain/cli/up_spec.rb`
**Reuse:** `Panes#option(CHAT)` (`up.rb:434`), `Panes#live` (`:439`), `warn_editorless_reattach` (`:1357`), `PaneCorpse#report`'s kill-session wording (`:706`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `up` -> `CLI::Up#call` (`up.rb:1094`) -> `reattach_session` (`:1330-1334`)

**Acceptance criteria**

```gherkin
Scenario: a reattach into a session whose recorded chat pane is gone says so
  Given a tmux session "lain" whose @lain_chat_pane is not among its live panes
  When lain up runs
  Then it warns that the chat has ended and names "tmux kill-session -t lain" to start fresh

Scenario: a reattach with a live chat warns about nothing new
  Given a session whose recorded chat pane is live
  When lain up runs
  Then no chat warning is printed
```
Spec file: `spec/lain/cli/up_spec.rb` (the `reattaching_up` helper, `:2298`)

**Stop and report if:**
- A session that recorded no pane ids (`up_spec` "arms nothing on a reattach into a session that records no pane ids")
  would now warn.

### T4: Say a lapse once when the `[y/N]` prompt already said it          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/repl/approval_surfaces.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`
**Reuse:** `Pending#drawn_at` (`approval/queue.rb:220`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Repl` -> `ApprovalSurfaces::Arrivals#sweep` (`approval_surfaces.rb:142`) -> `#lapse` (`:166`)

**Acceptance criteria**

```gherkin
Scenario: a call whose prompt drew lapses with one line
  Given a pending approval whose [y/N] prompt was drawn
  When its clock denies it
  Then the chat holds exactly one "denied after" line for it

Scenario: a call nobody drew still gets its lapse line
  Given a pending approval that was never drawn
  When its clock denies it
  Then Arrivals prints its lapse line
```
Spec file: `spec/lain/cli/repl/approval_surfaces_spec.rb`

**Stop and report if:**
- `spec/lain/seams/plain_chat_prompt_guards_spec.rb:553` (plain chat, no Arrivals) changes.

### T5: Say in the cockpit arrival line that the judge deferred a call          [risk: low]

**Depends on:** T4
**Files:** `lib/lain/cli/repl/approval_surfaces.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`
**Reuse:** `ApprovalPolicy::JUDGE_DEFERRED`, `Pending#judge_deferred?` (`approval/queue.rb:208`)
**Shared-file wiring:** none
**Reachable from:** `ApprovalSurfaces::Arrivals#announce` (`approval_surfaces.rb:154`)

**Acceptance criteria**

```gherkin
Scenario: a deferred call's arrival names the deferral
  Given a pending approval the judge deferred
  When Arrivals announces it
  Then the line includes the JUDGE_DEFERRED phrase the [y/N] prompt and lain://approval show
```
Spec file: `spec/lain/cli/repl/approval_surfaces_spec.rb`

**Stop and report if:**
- The deferral reaches the arrival through `notes` already for some rung, so it would print twice.

### T6: Drop a multi-line paste at an answer prompt in the pane          [risk: medium]

**Depends on:** T2
**Files:** `lib/lain/frontend/line_editor.rb`, `spec/lain/frontend/line_editor_spec.rb`
**Reuse:** `ApprovalPolicy::Asked#takes?` (`frontend/approval_policy.rb:~120`), the Intake refusal and hold
**Shared-file wiring:** none
**Reachable from:** `StdinPump#edited` -> `LineEditor#read` (`line_editor.rb:212-222`)

**Acceptance criteria**

```gherkin
Scenario: a pasted block at [y/N] is not drawn as rows of the prompt
  Given a drawn approval prompt "... [y/N] "
  When the human pastes "y\nrm -rf x"
  Then the screen shows the prompt once, the paste is held as a line for the next you>, and no decision is made

Scenario: a paste at you> keeps its rows
  Given a drawn "you>" prompt
  When the human pastes two lines
  Then both lines are in the buffer as today
```
Spec file: `spec/lain/frontend/line_editor_spec.rb`

**Stop and report if:**
- Reline offers no hook to tell a paste from typed newlines at an answer prompt, so the fix needs a Reline patch.

### T7: Keep the note a review thread was opened on when the docent answers          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/review/docent.rb`, `lib/lain/review/handover.rb`, `spec/lain/review/docent_spec.rb`, `spec/lain/review/handover_spec.rb`
**Reuse:** `Surface::Message`, `ThreadView::Entry`, the note's `kind` and `text` in `Handover#wrote_annotation` (`handover.rb:380-387`)
**Shared-file wiring:** none
**Reachable from:** `Review::Handover#wrote_annotation` -> `Docent#hold`; `Docent#render` (`docent.rb:475`)

**Acceptance criteria**

```gherkin
Scenario: the answer renders under the note
  Given a review note "why is this nil?" written on a hunk
  And the human asks the docent about that hunk
  When the docent's answer arrives
  Then the thread shows the note first, then the question, then the answer
```
Spec file: `spec/lain/review/docent_spec.rb`

**Stop and report if:**
- `Threads#replay` would have to change to keep a recorded session's threads byte-identical (that is b26-3's resume
  half, left for round 27).

### T8: Stop the fleet row clamp at the first cluster that does not fit          [risk: low]

**Depends on:** none
**Files:** `lib/lain/status_feed/fleet.rb`, `spec/lain/status_feed/fleet_spec.rb`
**Reuse:** `Ext::Prompt.width`
**Shared-file wiring:** none
**Reachable from:** `StatusFeed::Reading.fitted` (`status_feed/reading.rb:94-100`) -> `Fleet::Row.clamped` (`fleet.rb:365-373`)

**Acceptance criteria**

```gherkin
Scenario: a wide cluster that does not fit ends the row
  When Row.clamped("ab" + "中" * 5 + "x", columns: 8) runs
  Then it returns "ab中中…" and never a later narrow cluster after a skipped wide one
```
Spec file: `spec/lain/status_feed/fleet_spec.rb`

**Stop and report if:**
- The 4 examples at `fleet_spec.rb:609-628` need a changed expectation.

### T9: Name the typed reply gesture in a `--no-nvim` `/inbox` drain          [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/tty.rb`, `lib/lain/cli/human_replies.rb`, `spec/lain/frontend/tty_spec.rb`, `spec/lain/cli/human_replies_spec.rb`
**Reuse:** `TTY::Inbox::TYPED_GESTURE` (`tty.rb:725`), `@editor.attached?` (`human_replies.rb:59-64`)
**Shared-file wiring:** none
**Reachable from:** `/inbox` -> `CLI::Command::Inbox` -> `HumanReplies#drained` (`human_replies.rb:1527-1531`) -> `TTY#drain_inbox` (`tty.rb:397`)

**Acceptance criteria**

```gherkin
Scenario: a drain with no editor names the typed gesture
  Given a chat with no editor attached and 1 answered question in the inbox
  When the human types /inbox
  Then the listing names the typed gesture and never "ticking boxes is the nvim buffer"

Scenario: a drain with an editor keeps the nvim gesture
  Given an attached editor
  Then tty_spec "keeps the nvim buffer in the drain listing's gesture" passes unchanged
```
Spec file: `spec/lain/cli/human_replies_spec.rb`, `spec/lain/frontend/tty_spec.rb`

**Stop and report if:**
- `spec/reply_surface_discipline_spec.rb:25` forbids the new argument on `drain_inbox`.

### T10: Name a surveyed file the same way in the sidebar and in its refusals          [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/review_view.rb`, `spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** `ReviewView#displayed_path` (`review_view.rb:443`)
**Shared-file wiring:** none
**Reachable from:** `lain://review` `x` and open -> `ReviewView#unmarkable` (`:391`), `#naming` (`:395`), the `opened` report (`:370`)

**Acceptance criteria**

```gherkin
Scenario: a refusal names the row as the sidebar draws it
  Given a survey row whose path is "../tmp/a.rb", drawn as "tmp/a.rb"
  When the human presses x on that unread row
  Then the refusal names "tmp/a.rb"
  And the row still opens by "../tmp/a.rb"
```
Spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Stop and report if:**
- `review/surface/text.rb:169`'s copy of `displayed_path` has drifted from the view's.

### T11: Make `x` in a closed fold of `lain://question` say what it did          [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/60_question.lua`, `spec/lain/frontend/neovim/buffers_spec.rb`
**Reuse:** `tick_targets`, `question_bounds`, `vim.fn.foldclosed`, `_G.__lain.review_refused`
**Shared-file wiring:** none
**Reachable from:** the buffer-local `x` expr map (`60_question.lua:441`) -> `tick_or_delete` (`:~422`)

**Acceptance criteria**

```gherkin
Scenario: x on a closed question's heading deletes nothing
  Given lain://question with an older question folded closed
  When the cursor is on the closed fold and the human presses x
  Then no line is deleted and a message says to open the fold (zo) to tick an option

Scenario: x on an open option still ticks it
  Then buffers_spec "x ticks an option in lain://question" passes unchanged
```
Spec file: `spec/lain/frontend/neovim/buffers_spec.rb` (a new example that does not `zR` first)

**Stop and report if:**
- Opening the fold and ticking in one keypress is simpler than refusing; say so and pick it.

### T12: Tell a free-text question's stray line how to answer          [risk: low]

**Depends on:** none
**Files:** `lib/lain/question/document.rb`, `spec/lain/question/document_spec.rb`
**Reuse:** `Question#free_text?`, `Document::FREE_TEXT` ("write your answer below", `document.rb:49-51`)
**Shared-file wiring:** none
**Reachable from:** nvim `:w` on `lain://question` -> `QuestionView#wrote` -> `Document.parse_markdown` -> `Draft#line` (`document.rb:329-335`) -> `refuse_stray!` (`:~435-444`)

**Acceptance criteria**

```gherkin
Scenario: a column-0 line under a free-text question
  Given a free-text question in lain://question
  When the human writes "blue" at column 0 under it and saves
  Then the refusal says the answer goes on a line indented two spaces below the question, and names no option grammar

Scenario: a stray line under an options question keeps today's refusal
  Then document_spec's "neither an option line nor a comment" example passes unchanged
```
Spec file: `spec/lain/question/document_spec.rb`

**Stop and report if:**
- `Draft` cannot see its question's kind at `refuse_stray!`.

### T13: Round context occupancy the same way on every HUD          [risk: low]

**Depends on:** none
**Files:** `lib/lain/status_feed/reading.rb`, `lib/lain/frontend/prompt_composer.rb`, `spec/lain/status_feed/reading_spec.rb`, `spec/lain/frontend/prompt_composer_spec.rb`
**Reuse:** `StatusFeed::Reading#occupancy` (`reading.rb:246-249`, floor)
**Shared-file wiring:** none
**Reachable from:** the tmux status line via `StatusFeed::Reading`; the `you>` prompt via `PromptComposer#occupancy` (`prompt_composer.rb:354-359`)

**Interface**

```ruby
StatusFeed::Reading.percent(ratio) # => Integer, floor, clamped to 0..100
```

**Acceptance criteria**

```gherkin
Scenario: 0.995 reads 99% on both
  Given a window 99.5% full
  Then the status line reads "ctx:99%" and the you> prompt reads "99%"

Scenario: over-full reads 100%
  Given a ratio of 3.7
  Then both read 100%
```
Spec file: `spec/lain/status_feed/reading_spec.rb`, `spec/lain/frontend/prompt_composer_spec.rb`

**Stop and report if:**
- `prompt_composer_spec.rb:514` (0.384 -> "38%") is the only example that changes; any other is a surprise.

### T14: Wrap startup notices in a cockpit chat pane          [risk: low]

**Depends on:** T2
**Files:** `lib/lain/cli/wiring.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `TTY#render_warning`, `Wiring::ScreenNotices` (`wiring.rb:~395`)
**Shared-file wiring:** `exe/lain:1260-1261`: the startup notice block hands lines to the wiring instead of `say` (exact diff from the card)
**Reachable from:** `exe/lain` `chat` -> `CLI::ChatLaunch#call` -> `CLI::Wiring#run` (`wiring.rb:290-296`)

**Acceptance criteria**

```gherkin
Scenario: a long startup notice wraps to the pane
  Given a cockpit chat pane 60 columns wide and a startup notice of 140 characters
  When the chat starts
  Then the notice is printed once, wrapped at 60 columns

Scenario: the alternate screen does not print it twice
  Then wiring_spec's ScreenNotices examples pass unchanged
```
Spec file: `spec/lain/cli/wiring_spec.rb`

**Stop and report if:**
- A notice is raised before the tty exists and would be lost rather than printed raw.

### T15: Name every acting agent with one Requester value, the main agent `agent`          [risk: high]

**Depends on:** T4, T5, T7, T9, T14, T30
**Files:** `lib/lain/requester.rb` (new), `spec/lain/requester_spec.rb` (new), `lib/lain/cli/tool_guard.rb`, `lib/lain/approval/policy_switch.rb`, `lib/lain/approval/queue.rb`, `lib/lain/cli/wiring.rb`, `lib/lain/cli/wiring/askers.rb`, `lib/lain/tools/ask_human.rb`, `lib/lain/frontend/tty.rb`, `spec/lain/approval/policy_switch_spec.rb`, `spec/lain/approval/queue_spec.rb`, `spec/lain/cli/wiring_spec.rb`, `spec/lain/tools/ask_human_spec.rb`, `spec/lain/frontend/tty_spec.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/review/docent_spec.rb`, `spec/lain/cli/human_replies_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`
**Reuse:** `Approval::PolicySwitch::Requested` (the bare-word check, `policy_switch.rb:78-90`), `Queue.requester_for` (`queue.rb:387`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#wire_askers` (`wiring.rb:770`) and `ToolGuard::Asking` (`cli/tool_guard.rb:94-107`), both built by `CLI::Wiring#run`

**Interface**

```ruby
module Lain
  Requester = Data.define(:name, :label, :role, :skill)
  class Requester # constants and methods on the reopen, not inside the Data.define block
    NAME = /\A[\w-]+\z/ # the one home of the bare-word rule; PolicySwitch::Requested and T86's input read it
    # name: the wired identity remembered denials are keyed on; label: what surfaces show (defaults to name,
    # T86 lets a child adopt one). Every String member is frozen, so Ractor.shareable? holds.
    def self.main = new(name: "agent", label: "agent", role: nil, skill: nil)
    def key = name
    def to_s # "agent", "researcher" (role equal to label is said once), "parser-check (subagent)",
             # "dev-2 (dev, gherkin-tests)"
  end
end
```

**Acceptance criteria**

```gherkin
Scenario: the main agent asks a question as agent
  Given a chat whose main agent calls ask_human
  Then the arrival line reads "? agent ..." and the question's asked_by is "agent"

Scenario: approvals keep reading agent asks
  Then approval_policy_spec's "-- agent asks to run bash(...)" examples pass unchanged

Scenario: a forged name is refused
  When a Requester is built with name "a\nb"
  Then it raises, as Requested does today

Scenario: remembered denials stay keyed by name
  Given a denial remembered for requester "researcher"
  When a requester named "researcher" with a role asks again
  Then the denial applies
```
Spec file: `spec/lain/requester_spec.rb` (including `Ractor.shareable?`), `spec/lain/tools/ask_human_spec.rb`, `spec/lain/approval/queue_spec.rb`

**Stop and report if:**
- A journal reader (`bench/session`, `session_record/replay.rb`) parses `asked_by` or `requester` as anything but a
  String; the journal edge must stay a String.
- `tty.rb:328`'s "the agent asks:" turns out to be a different surface than the arrival line.

### T16: Show the role and skill a child runs under on every surface          [risk: medium]

**Depends on:** T8, T15
**Files:** `lib/lain/skill/role_spawn.rb`, `lib/lain/skill/invocation.rb`, `lib/lain/tools/subagent.rb`, `lib/lain/cli/tool_guard.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/telemetry/child_progress.rb`, `lib/lain/status_feed/fleet.rb`, `lib/lain/cli/fleet_windows.rb`, `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`, `spec/lain/cli/fleet_windows_spec.rb`
**Reuse:** `Lain::Requester` (T15), `RoleSpawn#named_for` (`role_spawn.rb:143`), `FleetWindows`'s unwired `role_for:` seam (`fleet_windows.rb:312`) and its name sanitizer (`:532`)
**Shared-file wiring:** none
**Reachable from:** `run_skill` -> `Skill::Invocation` -> `RoleSpawn#call` (`role_spawn.rb:84`) -> `Tools::Subagent` `ChildBuilder` (`subagent.rb:1495`); `FleetWindows.for(options)` (`fleet_windows.rb:312`) from `CLI::Wiring`

**Acceptance criteria**

```gherkin
Scenario: a skill's child names its role and skill when it asks
  Given run_skill "gherkin-tests" spawns a test_engineer child
  When the child parks a bash call
  Then the [y/N] prompt reads "test_engineer (gherkin-tests) asks to run bash(...)", the role said once because it is the name
  And approval_pending's requester is "test_engineer"

Scenario: a --windows title carries the role
  Given --windows and a researcher child
  Then its tmux window is named "researcher-<8 hex>", not "subagent-<8 hex>"

Scenario: the fleet row shows the skill
  Then the child's fleet row starts with its role and skill
```
Spec file: `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/cli/fleet_windows_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`

**Stop and report if:**
- Putting role or skill on the `:spawn` record would change spawn digests (`tools/subagent/lineage.rb:~60` says that
  is avoided); carry them on `child_progress` only.

### T86: Let a spawned child adopt a name          [risk: medium]

**Depends on:** T16
**Files:** `lib/lain/tools/subagent.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/tools/subagent_gate_spec.rb`
**Reuse:** `Lain::Requester` (T15), `Tool::Input` (one declaration for schema and validation)
**Shared-file wiring:** none
**Reachable from:** the model's `subagent` tool call -> `Tools::Subagent#perform` -> `ChildBuilder`

**Interface**

```ruby
# Tools::Subagent input gains an optional bare-word field:
#   name: String, optional, Requester::NAME and at most 24 characters; becomes the Requester's label, never its key
```

**Acceptance criteria**

```gherkin
Scenario: a named child shows its name
  When the model spawns a subagent with name "parser-check"
  Then its approval prompts read "parser-check (subagent) asks to run ..."
  And its Requester's label is "parser-check" while its name, the denial key, stays the wired "subagent"

Scenario: a name that would forge a line is refused before the spawn
  When the model passes name "x\n! agent asks"
  Then the call is refused by Tool::Input and no child is spawned
```
Spec file: `spec/lain/tools/subagent_spec.rb`

**Stop and report if:**
- Adding the field changes the rendered schema bytes of every toolset in a way the prompt-cache comment at
  `subagent.rb:85-90` says must not happen mid-session; then the field must be present from launch, never toggled.

### T17: Say which calls of a parked turn `/rewind` is waiting on          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/command/rewind.rb`, `spec/lain/cli/command/rewind_spec.rb`
**Reuse:** `Event.pending_tool_use?`
**Shared-file wiring:** none
**Reachable from:** `/rewind` -> `Command::Rewind#call` -> `#parked` (`rewind.rb:108-114`)

**Acceptance criteria**

```gherkin
Scenario: a turn of 3 calls, 1 still waiting
  Given the head turn holds bash, read_file and ask_human calls with no results yet
  When the human types /rewind 1
  Then the refusal says "this turn's 3 tool calls are still in flight (bash, read_file, ask_human)" and calls none of them parked
```
Spec file: `spec/lain/cli/command/rewind_spec.rb`

**Stop and report if:**
- The head turn can hold a call whose result was already committed (then the list must come from the undecided
  approvals instead, the M version).

### T18: Say plainly when every file-changing turn was already undone          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/command/undo.rb`, `spec/lain/cli/command/undo_spec.rb`
**Reuse:** `Undo::NOTHING` (`undo.rb:36`)
**Shared-file wiring:** none
**Reachable from:** `/undo` -> `Command::Undo#call` (`undo.rb:92-98`)

**Acceptance criteria**

```gherkin
Scenario: /undo after the last undo
  Given a session where 1 turn changed a file and /undo undid it
  When the human types /undo again
  Then the reply reads "nothing to undo: no file-changing turn is left" and never claims no turn changed a file
```
Spec file: `spec/lain/cli/command/undo_spec.rb`

**Stop and report if:**
- `undo_spec.rb:533` (the skip path) means "never" and "none left" need different sentences.

### T19: Refuse plan scope in a repository with no commit, once and in words          [risk: low]

**Depends on:** none
**Files:** `lib/lain/isolation/spike.rb`, `lib/lain/cli/switchboard.rb`, `spec/lain/isolation/spike_spec.rb`, `spec/lain/cli/switchboard_spec.rb`
**Reuse:** `Spike#head_of`'s `rev-parse --verify HEAD^{commit}` (`spike.rb:~122`)
**Shared-file wiring:** none
**Reachable from:** `/mode !` -> `Switchboard::Scoping#entering` (`switchboard.rb:~724-735`) -> `Isolation::Spike#acquire` (`spike.rb:70`)

**Acceptance criteria**

```gherkin
Scenario: /mode plan in a repository with no commits
  Given a git repository with no commit
  When the human types /mode !
  Then the reply reads "plan scope could not be entered: this repository has no commit yet; make one, then /mode plan"
  And it holds no git stderr and says "plan scope could" once
```
Spec file: `spec/lain/isolation/spike_spec.rb`, `spec/lain/cli/switchboard_spec.rb`

**Stop and report if:**
- `spec/lain/seams/plan_scope_spike_spec.rb:~300-312` needs more than its message expectation changed.

### T25: Say a prompt is waiting on an idle compaction summary          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent.rb`, `lib/lain/cli/repl.rb`, `spec/lain/agent_spec.rb`, `spec/lain/cli/repl_spec.rb`
**Reuse:** `Agent#dispatching?` (`agent.rb:296`), `TTY#render_note_waiting` (`frontend/tty.rb:262`)
**Shared-file wiring:** none
**Reachable from:** `Repl::IdleCompaction#tick` (`cli/repl/idle_compaction.rb:36`) -> `Agent#prepare_idle` (`agent.rb:311-318`); the next line -> `Repl#middleware_turn` -> `Agent#ask`

**Acceptance criteria**

```gherkin
Scenario: a line typed during an idle prepare
  Given an idle prepare is calling the summarizer
  When the human sends a line
  Then the chat prints "finishing a compaction summary before your prompt runs" once
  And the prompt runs after the summary lands, the prepare not aborted
```
Spec file: `spec/lain/cli/repl_spec.rb`, `spec/lain/agent_spec.rb` (the "#prepare_idle" describe, `:1838-1934`)

**Stop and report if:**
- `agent_spec.rb:1885` (a held lock makes `prepare_idle` return false) has to change.

### Bench, confinement and the bash child

### T20: Refuse a bash command a leased unattended run cannot read          [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/tool_guard.rb`, `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/bench/harness_spec.rb`
**Reuse:** `Shell::Named.of(...)#opaque?`, `LeasedPolicy::LEASED_READ` wording and its final-deny shape (`tool_guard.rb:258-265`), `Approval::Escalation::Triage#refused`'s use of `opaque?` (`approval/escalation.rb:663-671`), the cwd resolution `ConfineToScope#target` uses
**Shared-file wiring:** `ARCHITECTURE.md:563-566`: a leased arm with no human refuses any bash command whose paths cannot be read; an interpreter's own writes are still not confined
**Reachable from:** `exe/lain:903-911` `bench arms` -> `Bench::CLI#arms_report` -> `confinement_for` (`bench/cli.rb:522-534`), whose 2 branches (`Harness::INSTRUMENTATION`, `bench/harness.rb:110-112`, and `Confinement#instrumentation`, `harness/confinement.rb:90-94`) both reach `ToolGuard.detached` -> `Detached#call` (`tool_guard.rb:154`) -> `ToolGuard.leased` (`:354-361`) -> `LeasedPolicy`

**Acceptance criteria**

```gherkin
Scenario: an opaque loop in a leased arm is refused
  Given a bench arm leased the worktree W, with no human attached
  When the arm sends bash "cd /outside && for f in $(find . -name '*.rb'); do mv t \"$f\"; done"
  Then the call is refused with "this run is leased to W and no human is attached, so a command whose paths cannot be read is refused (a loop, $(...), cd then ;, sh -c, ruby -e, xargs); write a script in W and run it, or send the steps as separate calls"
  And no file outside W changes

Scenario: cd then ; is refused too
  When the arm sends bash "cd /outside; rm x"
  Then it is refused the same way

Scenario: an inline interpreter script is refused
  When the arm sends bash "ruby -e 'File.write(\"/outside/x\", 1)'" or "find . | xargs rm"
  Then each is refused the same way

Scenario: a plain command in the lease still runs
  When the arm sends bash "bundle exec rspec spec/x_spec.rb"
  Then it runs with no approval asked

Scenario: both confinement branches refuse
  Then the opaque loop is refused under bench arms --confine off and --confine reader
```
Spec file: `spec/lain/cli/tool_guard_spec.rb` (describe "LeasedPolicy", `:1278`), `spec/lain/bench/harness_spec.rb` (describe "an arm leased a worktree", `:209`, through the production `Harness::INSTRUMENTATION`)

**Stop and report if:**
- `spec/lain/middleware/confine_to_scope_spec.rb`'s "leaves an opaque command to the approval ladder" runs through
  `LeasedPolicy`; that example is the chat path and must stay green.
- A chat's leased child (`ToolGuard::Spawned`, `tool_guard.rb:130,312`) reaches `LeasedPolicy`; the refusal is for
  runs with no human only.

### T21: Promote the bench's tee channel to `Channel::Tee`          [risk: low]

**Depends on:** none
**Files:** `lib/lain/channel/tee.rb` (new), `spec/lain/channel/tee_spec.rb` (new), `lib/lain/bench/arm_sweep.rb`, `spec/lain/bench/arm_sweep_spec.rb`
**Reuse:** `Bench::ArmSweep::Tee` (`bench/arm_sweep.rb:157-168`), moved whole
**Shared-file wiring:** none
**Reachable from:** `Bench::ArmSweep` (its existing `journal_factory: -> { Tee.new(sink) }`, `arm_sweep.rb:138`)

**Interface**

```ruby
class Lain::Channel::Tee < Lain::Channel
  EVERY = ->(_event) { true }
  def initialize(sink, only: EVERY) # only: a predicate on the event
end
```

**Acceptance criteria**

```gherkin
Scenario: an event pushed to a tee reaches the sink and the channel
  Given a Channel::Tee over a sink
  When an event is pushed
  Then the sink holds it and a drain of the channel yields it

Scenario: the sweep is unchanged
  Then arm_sweep_spec's replan counts pass unchanged
```
Spec file: `spec/lain/channel/tee_spec.rb`

**Stop and report if:**
- `Channel` subclasses are frozen or Ractor-shared in a way a sink reference breaks.

### T22: Put a bench arm's sandbox records in the run journal          [risk: medium]

**Depends on:** T21
**Files:** `lib/lain/bench/harness/confinement.rb`, `lib/lain/bench/cli.rb`, `spec/lain/bench/harness/confinement_spec.rb`, `spec/lain/bench/arms_report_spec.rb`
**Reuse:** `Channel::Tee` (T21), `Confinement::Once` (`confinement.rb:27-39`), `ArmJournal`'s arm stamp (`arm/driver.rb:104-107`), `Telemetry::Sandbox`
**Shared-file wiring:** `exe/lain` `BENCH_CONFINE` (`~761-763`): "a read-only command whose paths stay in the checkout runs in the reader sandbox"
**Reachable from:** `Bench::CLI#arms_report` -> `confinement_for` (`bench/cli.rb:522-534`) -> `Confinement#apply` (`confinement.rb:67-72`)

**Acceptance criteria**

```gherkin
Scenario: a confined arm's bash calls are countable from the bench journal
  Given bench arms --confine reader --journal J over a 2-task suite
  When an arm runs "cat README.md" inside its worktree
  Then J holds a sandbox record with profile "reader", stamped with the arm and the task

Scenario: --confine off writes none
  Given --confine off
  Then J holds no sandbox record

Scenario: the run records that opaque commands are refused
  Then J's run_arms record says opaque commands were refused in the lease, so bench variance does not pool it with a run from before T20
```
Spec file: `spec/lain/bench/harness/confinement_spec.rb`, `spec/lain/bench/arms_report_spec.rb`

**Stop and report if:**
- `confinement_spec.rb:38` ("journalling to that agent's own journal") must stop holding; the per-agent record
  stays and the run journal gets a copy.
- `WORKTREE_REACH` (`bench/cli.rb:50-53`) is quoted by a spec that pins the old sentence.

### T23: Put a dual-ledger arm's ledger transitions in the run journal          [risk: low]

**Depends on:** T21
**Files:** `lib/lain/bench/live_arms.rb`, `spec/lain/bench/live_arms_spec.rb`
**Reuse:** `Channel::Tee` (T21), `Arm::DualLedger`'s `journal_factory:` (`arm/dual_ledger.rb:89-99`)
**Shared-file wiring:** none
**Reachable from:** `Bench::CLI#arms_report` -> `LiveArms.build` (`bench/live_arms.rb:~268-282`)

**Acceptance criteria**

```gherkin
Scenario: a live dual-ledger run leaves its transitions
  Given bench arms with the dual-ledger arm and --journal J
  When the arm replans once
  Then J holds the ledger_transition records, each stamped with the arm and the task
```
Spec file: `spec/lain/bench/live_arms_spec.rb`

**Stop and report if:**
- `arms_report` has no journal to pass when `--journal` is absent; then the factory stays the default.

### T24: Refuse bench inputs in words before any run starts          [risk: low]

**Depends on:** T22
**Files:** `lib/lain/bench/cli.rb`, `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/arms_report_spec.rb`
**Reuse:** `Refusal`, `preflighted_suite` (`bench/cli.rb:469-473`), the `unique_prompts!` shape (`:784-790`), `checked_path` (`:~607`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench arms` -> `Bench::CLI#arms_report`; `bench variance` -> `#variance_report` -> `session_paths`

**Acceptance criteria**

```gherkin
Scenario: a 1-task arm fixture
  When bench arms runs over a suite of 1 task
  Then it refuses "an arm fixture needs at least 2 tasks" and writes no run_arms record

Scenario: a session id where a path is wanted
  When bench variance runs with "abc123" and no such file exists
  Then it refuses naming that it takes session file paths, and that lain sessions lists them, with exit status 1
```
Spec file: `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/arms_report_spec.rb`

**Stop and report if:**
- `spec/lain/arm/driver_spec.rb:758` (the Driver's own `ArgumentError`) would change; it stays the library contract.

### T26: Take `LD_LIBRARY_PATH` out of the bash child's kept names          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/exec/child_env.rb`, `lib/lain/exec.rb`, `lib/lain/exec/docker.rb`, `spec/lain/exec/child_env_spec.rb`, `spec/lain/exec/local_spec.rb`, `docs/toolchain-traps.md`
**Reuse:** `ChildEnv.from(ENV, pass:)` and `LAIN_ENV_PASS` (`child_env.rb:41-44,93`)
**Shared-file wiring:** `CLAUDE.md:27`: add "a machine whose Ruby needs it in bash children also exports `LAIN_ENV_PASS=LD_LIBRARY_PATH`"; `ARCHITECTURE.md:915`: `LD_LIBRARY_PATH` is passed only by name
**Reachable from:** `CLI::ExecBackend.resolve` (`cli/exec_backend.rb:62`) -> `Exec::Local.new(child_env:)`; `Isolation::Verifier::Command#environment` (`isolation/verifier/command.rb:59`) via `Exec.child_env`

**Acceptance criteria**

```gherkin
Scenario: the child no longer inherits LD_LIBRARY_PATH
  Given the parent has LD_LIBRARY_PATH=/x
  When bash runs "printenv LD_LIBRARY_PATH"
  Then it prints nothing

Scenario: a pass list still lends it
  Given LAIN_ENV_PASS=LD_LIBRARY_PATH and LD_LIBRARY_PATH=/x
  Then bash prints /x
```
Spec file: `spec/lain/exec/local_spec.rb` (the "keeps LD_LIBRARY_PATH" example at `:215-219` inverts), `spec/lain/exec/child_env_spec.rb`

**Stop and report if:**
- Any spec that spawns a Ruby child (the verifier, `worker_checks`) fails to load OpenSSL without it on this box.
- The panel's probe found Ruby children load OpenSSL and lain on this box without it; probe again before proposing
  the `CLAUDE.md` line, and word it as "only where a child needs it".

### T27: Extract the bash output masker as a standalone unit with one numbering per command          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/sensitivity/text_mask.rb` (new), `spec/lain/sensitivity/text_mask_spec.rb` (new), `lib/lain/middleware/redact_secret_reads.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `RedactSecretReads::Output` (`redact_secret_reads.rb:748-769`), moved; `Sensitivity::Regions.detect`, `Sensitivity::Literals`, `Sensitivity::Masking.render` (whose numbering restarts per call, `masking.rb:38`)
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#printed` (`redact_secret_reads.rb:289-298`), built by `ToolGuard`'s `read_kwargs` (`cli/tool_guard.rb:480-495`)

**Interface**

```ruby
module Lain::Sensitivity
  class TextMask
    def initialize(secrets:)  # Sensitivity::Literals#to_a
    def call(text)            # => [masked_text, region_count], numbering from 1
    def stream                # => TextMask::Stream, numbering continues across #<< calls
  end
  class TextMask::Stream
    def <<(chunk)   # => the masked text safe to show now (complete lines; a PEM block only once closed)
    def finish      # => the rest, masked whole; never raw
  end
end
```

**Acceptance criteria**

```gherkin
Scenario: bash output is masked exactly as before
  Then every redact_secret_reads_spec bash example passes unchanged

Scenario: a stream numbers as the whole text does
  Given text holding 2 secrets on 2 lines
  When it is fed to a Stream in 3 chunks split mid-secret and finished
  Then the concatenated output equals TextMask#call(text)'s masked text, numbers included

Scenario: a PEM key split across chunks
  Given a private key whose BEGIN and END lines arrive in different chunks
  Then the Stream emits nothing of the key until END arrives, then emits it masked as one region
```
Spec file: `spec/lain/sensitivity/text_mask_spec.rb`

**Stop and report if:**
- `Output` reads middleware state (the ledger, the queue) that a standalone unit cannot hold.

### T28: Mask bash output on the live display          [risk: high]

**Depends on:** T26, T27
**Files:** `lib/lain/tools/bash.rb`, `lib/lain/exec/local.rb`, `lib/lain/exec/docker.rb`, `lib/lain/exec/sandboxed.rb`, `lib/lain/exec/capture.rb`, `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/middleware/withhold_automatic_output.rb`, `spec/lain/tools/bash_spec.rb`, `spec/lain/exec/local_spec.rb`
**Reuse:** `Sensitivity::TextMask#stream` (T27), `Sink::IOAdapter` (`sink.rb:97-103`), `Capture::Bounded#finish` (`exec/capture.rb:~75`, called at `shell/pipeline.rb:392`), `RedactSecretReads#session_secrets`'s inputs (`redact_secret_reads.rb:300-303`: the `ChildEnv` and the invocation's `worker_env.env`)
**Shared-file wiring:** `ARCHITECTURE.md:~1035-1042`: the chat pane and `lain://journal` show masked bash output
**Reachable from:** `CLI::Wiring` builds `Tools::Bash.new(exec:, ...)` (`cli/wiring.rb:161`) over the launch's exec backend, whose `ChildEnv` is the one the board's masker reads (`wiring.rb:949`); per call `Effect::Handler::Live#interpret` (`effect/handler/live.rb:41`) -> `Bash#runtime` (`bash.rb:428-432`) -> `#output_sink` (`:460-462`)

**Interface**

```ruby
Exec::Local#child_env, Exec::Docker#child_env, Exec::Sandboxed#child_env # => Exec::ChildEnv (Sandboxed delegates)
# Bash#output_sink wraps IOAdapter in a sink that feeds one TextMask::Stream per call,
# built from @exec.child_env and invocation.worker_env.env; Capture's finish (and the timeout path) calls its #finish
```

**Acceptance criteria**

```gherkin
Scenario: a planted token never reaches the pane
  Given a chat whose child env passes FOO=ghp_<36 chars>
  When an approved bash runs "printenv FOO"
  Then the tool_output events on the live channel carry <redacted:1> and never the raw value
  And the record's command_redacted numbering matches the live numbering

Scenario: a token split across two writes is still masked
  Given a command that prints the token in two writes 1 second apart
  Then no tool_output event carries any 8-byte run of the raw token

Scenario: a PEM key split across two writes
  Given a command printing a private key's first half, sleeping 1 second, then the rest
  Then no tool_output event carries any line of the key body

Scenario: a line still arrives before the command ends
  Given a command printing "a\n", sleeping 2 s, then printing "b\n"
  Then the event for "a" arrives before the command exits

Scenario: an unterminated hold is masked, never flushed raw
  Given a command printing "-----BEGIN PRIVATE KEY-----" and 70 KB with no END line
  Then what the stream emits at the hold cap and at exit is masked

Scenario: an output over 16,384 bytes streams masked
  Given a command printing 20,000 bytes holding a planted token
  Then the live events carry no raw token, and the model gets today's refusal
```
Spec file: `spec/lain/tools/bash_spec.rb` ("attributed live streaming", `:111-130`), `spec/lain/exec/local_spec.rb`

**Stop and report if:**
- `spec/lain/exec/capture_spec.rb:57-66` ("forwards every chunk to its own stream's sink") has to change; the masking
  sits in front of the sink, not in `Capture`.
- The invocation does not carry the `worker_env` whose `env` holds lent values; then name where it is and stop.
- A progress bar (no newline) shows nothing until exit; report the hold cap chosen.

### T29: Name the directory of a read-only `git -C`          [risk: medium]

**Depends on:** T20
**Files:** `lib/lain/shell/named.rb`, `spec/lain/shell/named_spec.rb`
**Reuse:** `Named::GIT_READ_ONLY` (`shell/named.rb:320-322`), `DIRECTORY_LETTERS` (`:329-336`, whose default `"C"` makes `-C` opaque for any program not listed), `DIRECTORY_LONG`
**Shared-file wiring:** none
**Reachable from:** `Approval::Judged#unlooked` (`approval/judged.rb:~244-256`), `ConfineToScope` and T20's `LeasedPolicy` via `Shell::Named.of`

The finding blamed `2>&1`; the panel's probe showed `git -C sibling log` is opaque without it and `git log 2>&1` is
not. The cause is `git -C`.

**Acceptance criteria**

```gherkin
Scenario: a read-only git -C names its directory
  When Shell::Named.of("git -C sibling log 2>&1") runs
  Then it is not opaque and its paths include "sibling"

Scenario: a writing git subcommand under -C stays opaque
  When Shell::Named.of("git -C sibling commit -m x") runs
  Then it is opaque

Scenario: git -C outside a lease is still held
  Given a leased run in W
  When it sends bash "git -C /outside log"
  Then ConfineToScope refuses it as outside the lease
```
Spec file: `spec/lain/shell/named_spec.rb`, `spec/lain/middleware/confine_to_scope_spec.rb`

**Stop and report if:**
- A global git option before `-C` (`git -c k=v -C dir log`) or after it changes which word is the subcommand.

### T30: Let a configured `deny_tool` refuse a tool that asks no approval          [risk: high]

**Depends on:** T20
**Files:** `lib/lain/middleware/gate.rb`, `lib/lain/cli/tool_guard.rb`, `lib/lain/cli/wiring/board_build.rb`, `lib/lain/shell/verdict.rb`, `spec/lain/middleware/gate_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`, `spec/lain/shell/verdict_spec.rb`
**Reuse:** `Approval::Remembered`'s `deny_tools`, `Gate#judged?` (`gate.rb:197`), the gate's closed contract (`Gate.closes!`)
**Shared-file wiring:** `docs/commands.md:1081-1084`: `deny_tool "web_fetch"` refuses it; `shell exclude:` covers bash only
**Reachable from:** `CLI::Wiring::BoardBuild` (`cli/wiring/board_build.rb:77`, the `Remembered` rules) -> `ToolGuard` builds the `Gate` (`cli/tool_guard.rb:402-405`) at the end of its stack

**Interface**

```ruby
Middleware::Gate.new(policy:, sensitivity:, denial:, denied_tools: Set[]) # names a trusted config denied by deny_tool
# Gate#gated? stays closed for tier-1 tools; a call whose tool is in denied_tools is refused before #gated? asks
```

**Acceptance criteria**

```gherkin
Scenario: deny_tool refuses web_fetch
  Given a trusted .lain/config.rb with approval do deny_tool "web_fetch" end
  When the model calls web_fetch
  Then the call is refused naming the config's deny, and no request leaves the box

Scenario: a tool with no deny is untouched
  Given no deny_tool line
  Then web_fetch runs with no approval asked, as today

Scenario: shell exclude says it is bash only
  Given shell exclude: %w[curl]
  When bash runs curl
  Then the refusal says the exclusion covers bash commands
```
Spec file: `spec/lain/middleware/gate_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb` (through `BoardBuild`, no double)

**Stop and report if:**
- `Gate.closes!` forbids a tier-1 tool reaching the policy and the deny must instead be its own middleware.

### T31: Note why a fresh path-named program was parked          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/approval/composed_term.rb`, `spec/lain/approval/composed_term_spec.rb`
**Reuse:** `ComposedTerm#executables` (`composed_term.rb:~683,702-705`), `#describe_binary` (`:696-704`), `Shell::Executable#fresh`
**Shared-file wiring:** none
**Reachable from:** `Approval::Escalation::Rules#call` (`approval/escalation.rb:~425`) -> `RuleChain#why_not` -> `ComposedTerm#why_not` (`composed_term.rb:514-520`)

**Acceptance criteria**

```gherkin
Scenario: a ./run.sh written this session parks with a note
  Given ./run.sh was written by write_file this session
  When bash "./run.sh" parks
  Then the pending's note says run.sh was written this session

Scenario: a flag-refused bare command still has no note
  Then composed_term_spec's "gives no note when a predicate other than the class one refuses" passes unchanged
```
Spec file: `spec/lain/approval/composed_term_spec.rb` (describe "why a call it leaves to the judge was left", `:1292`)

**Stop and report if:**
- Resolving stages for a refused call costs a second resolution per call (`:1367` pins once).

### T32: Say bash runs in the container under `--exec docker`          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/wiring/observers.rb`, `spec/lain/cli/wiring/observers_spec.rb`
**Reuse:** `Observers::Unconfined` (`observers.rb:11-32`)
**Shared-file wiring:** none
**Reachable from:** `ToolsetBuild#confined` (`cli/wiring/toolset_build.rb:322-333`) -> `Confine::Sandbox.degraded` -> `Observers::Unconfined`

**Acceptance criteria**

```gherkin
Scenario: the docker notice
  Given --exec docker
  When the chat starts
  Then the notice reads "bash runs in the docker container, not in the reader sandbox" and never "unconfined"

Scenario: a box with no bwrap keeps its notice
  Then observers_spec's missing-bwrap example passes unchanged
```
Spec file: `spec/lain/cli/wiring/observers_spec.rb`

**Stop and report if:**
- The degraded record's reason is the only signal and is free text; then match on `Exec::Docker` at the call site.

### T33: Refuse a confined child's bash read of an account file          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/sensitivity/policy.rb`, `spec/lain/sensitivity/policy_spec.rb`
**Reuse:** `Policy::Confined#account_denial` (`policy.rb:243-247`), `#home_advice` (`:249`), `Shell::Named.of(command, cwd:, home:)`
**Shared-file wiring:** none
**Reachable from:** `Middleware::Sensitivity#call` (`middleware/sensitivity.rb:74-77`) over a `Policy::Confined` built by `ToolGuard.confined`

**Acceptance criteria**

```gherkin
Scenario: cat /etc/passwd from a confined child
  Given a confined child
  When it runs bash "cat /etc/passwd"
  Then the call is refused with the same home advice read_file gets, and nothing parks

Scenario: the main agent's read stays gated
  Then policy_spec "leaves the main agent's read of /etc/passwd gated rather than refused" passes unchanged
```
Spec file: `spec/lain/sensitivity/policy_spec.rb` (`:1010-1061`)

**Stop and report if:**
- `policy_spec.rb:1056` (`write_file` not denied) changes.

### T34: Withhold a compare metric nothing measured          [risk: low]

**Depends on:** none
**Files:** `lib/lain/compare.rb`, `spec/lain/compare_spec.rb`
**Reuse:** `Compare#withheld` (`compare.rb:267`), `NO_PROMPT_CACHE`, `NO_COMPACTION_COST`, `Arm::Driver::Unmeasured`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench variance` -> `Bench::CLI#variance_report` -> `Variance#report` -> `Compare#report`

**Acceptance criteria**

```gherkin
Scenario: 2 unpriced runs with no cache and no compaction
  When their variance report prints
  Then it shows no "0.000000" and no "cache write tokens 0.0", and says which metrics were not measured
```
Spec file: `spec/lain/compare_spec.rb` (describe "the compaction columns", `~175`; "a cacheless provider", `:346`)

**Stop and report if:**
- A run that compacted with a real 0 cost delta would be withheld too.

### T35: Mark a builtin's resolution when the shell ran the builtin          [risk: low]

**Depends on:** T28
**Files:** `lib/lain/tools/bash.rb`, `spec/lain/tools/bash_spec.rb`
**Reuse:** `Verdict.builtin?`, `SHELL_BUILTINS` (`shell/verdict.rb:98-103`), the arm `arm_for` computes
**Shared-file wiring:** none
**Reachable from:** `Tools::Bash#perform` -> `#journal_resolution` (`bash.rb:~329-338`)

**Acceptance criteria**

```gherkin
Scenario: echo on the string arm
  When bash "echo a | tr a b" runs on the string arm
  Then its exec_resolution entry for echo is marked builtin, not "/usr/bin/echo"

Scenario: echo on the term arm
  When bash "echo a" runs on the term arm
  Then the entry still names the binary PATH found
```
Spec file: `spec/lain/tools/bash_spec.rb` (`:1410`, `:347`)

**Stop and report if:**
- The string arm under `--exec docker` runs a different shell whose builtins differ.

### Epic tier

### T36: Name a commit that holds only an issue's failing tests          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/epic/red_commit.rb` (new), `spec/lain/epic/red_commit_spec.rb` (new), `lib/lain/cli/epic_driver/factory.rb`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`
**Reuse:** `IssueTests#message` (`cli/epic_driver/factory.rb:1543`, moved here as the one home of the subject), `IssueTests#earlier` (`:1490`), `Isolation::Checkout#run`
**Shared-file wiring:** none
**Reachable from:** `IssueTests#call` (`factory.rb:1388`) writes the subject; T37 and T38 read it through `Forge::LocalLanding` and `CLI::EpicSubmit`

**Interface**

```ruby
module Lain::Epic
  class RedCommit
    def self.subject(target, digest) # "test: failing tests at <target>, from criteria <digest>"
    def initialize(git:, base:)       # Isolation::Checkout, the epic branch ref
    def only?(sha) # => true when merge-base(base, sha)..sha is non-empty and every commit in it carries the red subject
  end
end
```

**Acceptance criteria**

```gherkin
Scenario: an anchor holding only the red step's commit
  Given epic/demo and an issue branch whose one commit has the red subject
  Then RedCommit#only? is true for its tip

Scenario: an empty range is not red-only
  Given a sha that is the epic branch's base or an ancestor of it
  Then RedCommit#only? is false

Scenario: an anchor with an implementation commit on top
  Given that branch plus a commit "feat: greet"
  Then RedCommit#only? is false

Scenario: the red step still writes the same subject
  Then issue_tests_spec's commit message examples pass unchanged
```
Spec file: `spec/lain/epic/red_commit_spec.rb` (a real git repository, no double)

**Stop and report if:**
- A rebased red commit (retirement, `Factory::RedOnly`'s comment) can change its subject.

### T37: Never offer the failing-test commit as the one to approve at land          [risk: high]

**Depends on:** T36
**Files:** `lib/lain/forge/local_landing.rb`, `lib/lain/cli/epic_land.rb`, `spec/lain/forge/local_landing_spec.rb`, `spec/lain/cli/epic_land_spec.rb`
**Reuse:** `Epic::RedCommit` (T36), `LocalLanding#missing_approval` (`forge/local_landing.rb:227-230`), `#unapproved` (`:237-241`), the `unanchored` wording (`:232`), the injected-collaborator shape of `layout:` and `landings:` (`:62-71`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic land` -> `CLI::EpicLand#land` (`cli/epic_land.rb:48-53`) -> `#wired` (`:116`, builds `LocalLanding` at `:136`) -> `LocalLanding#anchored` (`:107-110`)

**Acceptance criteria**

```gherkin
Scenario: only the red commit is anchored
  Given issue greet's only anchored commit is its red step's
  When the operator runs lain epic land greet demo
  Then it refuses "only the failing-test commit is anchored for issue greet; re-run the issue" and names no sha to approve

Scenario: an approval of a red-only sha is refused at land
  Given an implementation gate approved the red-only sha
  When lain epic land runs
  Then it refuses and nothing moves to done

Scenario: a real implementation is still offered
  Then local_landing_spec "refuses an anchored commit no gate approved, naming lain epic submit implementation with its sha" passes unchanged
```
Spec file: `spec/lain/forge/local_landing_spec.rb`, `spec/lain/cli/epic_land_spec.rb` (through `EpicLand#wired`)

**Stop and report if:**
- `local_landing_spec.rb:360` (the ambiguity refusal) needs a third candidate state.

### T38: Refuse an implementation approval for a commit holding only failing tests          [risk: high]

**Depends on:** T36
**Files:** `lib/lain/cli/epic_submit.rb`, `spec/lain/cli/epic_submit_spec.rb`
**Reuse:** `Epic::RedCommit` (T36), `Artifacts#digest!` and `#commit!` (`cli/epic_submit.rb:236-256`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic submit implementation` -> `EpicSubmit.from_options` -> `Artifacts#digest!`

**Acceptance criteria**

```gherkin
Scenario: submitting the red sha as an implementation
  When the operator runs lain epic submit implementation demo --issue greet --digest <red-only sha>
  Then it refuses "that commit holds only greet's failing tests; re-run the issue" and opens no gate
```
Spec file: `spec/lain/cli/epic_submit_spec.rb`

**Stop and report if:**
- `epic_submit_spec.rb:195`, `:275` or `:286` builds its `commit_sha` fixture with the red subject.

### T39: Let the red step's run rewrite the preset's own lockfile          [risk: medium]

**Depends on:** T36
**Files:** `lib/lain/cli/epic_driver/factory.rb`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`
**Reuse:** `IssueTests#stray!` (`factory.rb:1468-1476`), `#tests_tree?` (`:1478`), `Layout#preset`
**Shared-file wiring:** none
**Reachable from:** `IssueActor#adopted` -> `IssueTests#call` (`factory.rb:1388`) -> `#fresh` (`:1411-1417`)

**Acceptance criteria**

```gherkin
Scenario: Bundler adds CHECKSUMS to a tracked Gemfile.lock
  Given an rspec project whose committed Gemfile.lock has no CHECKSUMS section
  When the test_engineer child runs bundle exec rspec and Bundler rewrites the lock
  Then the red step is not refused for Gemfile.lock and the red commit does not include it

Scenario: a real stray is still refused
  Then issue_tests_spec "refuses a deleted tracked file", "keeps a renamed path whole" and both "also wrote the subject" examples pass unchanged
```
Spec file: `spec/lain/cli/epic_driver/issue_tests_spec.rb`

**Stop and report if:**
- A preset has no single lockfile name (the Command adapter); then only rspec's `Gemfile.lock` is exempt and the card says so.

### T40: Count a missing constant the issue's subject will define as red          [risk: medium]

**Depends on:** T39
**Files:** `lib/lain/cli/epic_driver/factory.rb`, `lib/lain/prompt/templates/skill/gherkin-tests/skill.md`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`
**Reuse:** `IssueTests#failing` (`factory.rb:1452-1460`), `TestGeneration::Record#verdict` rule `:no_source` (`gherkin/test_generation.rb:~54-83`, from `TestLayout::Guard#undefined` and `Guard.unwritten`), `PlanSubject` (`cli/epic_driver/plan_subject.rb:55`)
**Shared-file wiring:** none
**Reachable from:** `IssueTests#call` -> `#fresh` -> `#failing` -> `Grader::TestHarness#run` (`rspec --format json`)

**Acceptance criteria**

```gherkin
Scenario: describe Greeting before Greeting exists
  Given the issue's subject is lib/greeting.rb, not yet written
  And the generated test is RSpec.describe Greeting with 1 example
  When the red step runs it
  Then it is committed as red, the run's only error being "uninitialized constant Greeting"

Scenario: a load error for another file stays refused
  Then issue_tests_spec "refuses tests that never load, quoting the load error, and commits nothing" (a require_relative of missing_order) passes unchanged

Scenario: a misspelt constant when the subject exists stays refused
  Given lib/greeting.rb defines Greeting and the test describes Greting
  Then the red step refuses it as not loading
```
Spec file: `spec/lain/cli/epic_driver/issue_tests_spec.rb`

**Stop and report if:**
- The rspec JSON keeps the NameError text only inside `messages`, with no constant name a regexp can pull out reliably.

### T41: Let the adjudicated gate's researcher read its own epic's home          [risk: medium]

**Depends on:** T38
**Files:** `lib/lain/cli/epic_submit.rb`, `spec/lain/cli/epic_submit_spec.rb`
**Reuse:** `Epic::Home.resolve(config:, paths:, root:, slug:)` (`epic/home.rb:76-85`), `ToolGuard.detached(roots:)`, `Policy::Confined#confined(roots:)` (`sensitivity/policy.rb:198`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic submit` -> `EpicSubmit.from_options` (`cli/epic_submit.rb:~472-481`) -> `Adjudication.pair(..., tool_middleware: guard(root))` (`:479`, `guard` at `:553`)

**Acceptance criteria**

```gherkin
Scenario: the evidence researcher reads the plan under epics home :xdg
  Given epics home: :xdg and an adjudicated research gate for epic demo
  When the evidence researcher reads its brief's plans/<id>.md
  Then the read is not parked and gate_evidence holds the plan's text

Scenario: another epic's home still parks
  When it reads epic other's research.md
  Then the read is outside its roots
```
Spec file: `spec/lain/cli/epic_submit_spec.rb` (through `from_options`)

**Stop and report if:**
- `epic_submit_spec.rb:1599-1632` (the `Brief` paths) must change.

### T42: Name the remedy for an abandoned issue when an epic cannot finish          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/epic_finish.rb`, `spec/lain/cli/epic_finish_spec.rb`
**Reuse:** `Report#residual_tally` (`cli/epic.rb:759-765`), `Lain::Epic::STORED_STATUSES`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic finish` -> `EpicFinish#finish` (`cli/epic_finish.rb:84-90`) -> `#finished!` (`:95-103`)

**Acceptance criteria**

```gherkin
Scenario: an abandoned issue blocks finish
  Given epic demo with issue b abandoned and every other issue done
  When lain epic finish runs
  Then it refuses naming b as abandoned, and says to mark it done or remove it from epic.md, never to land it

Scenario: an in-flight issue keeps the land remedy
  Then epic_finish_spec's in_flight example passes unchanged
```
Spec file: `spec/lain/cli/epic_finish_spec.rb`

**Stop and report if:**
- An abandoned issue can be landed by some verb this card did not find.

### T43: Say in `epic status` when the stage it names is not open          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/epic.rb`, `spec/lain/cli/epic_spec.rb`
**Reuse:** `Epic::Stage#ensure_open!` (`epic/stage.rb:104-110`), `Approval::SignoffQueue.from_journal`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic status` -> `CLI::Epic#status` -> `Report#preamble` (`cli/epic.rb:730-733`)

**Acceptance criteria**

```gherkin
Scenario: research approval withdrawn
  Given epic demo whose research gate was approved, then the approval withdrawn
  When lain epic status runs
  Then it still prints "stage epic_plan" and adds "epic_plan is not open: research is not approved"
```
Spec file: `spec/lain/cli/epic_spec.rb`

**Stop and report if:**
- `spec/lain/epic/progress_spec.rb:320-340` has to change; `Progress#summary`'s text stays.

### T45: Refuse `epic finish` with no remote in words, and exit non-zero on a denial          [risk: medium]

**Depends on:** T41, T42
**Files:** `lib/lain/cli/epic_finish.rb`, `lib/lain/cli/epic_submit.rb`, `spec/lain/cli/epic_finish_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`
**Reuse:** `Forge::Promotion::Remote#heads` or `git remote`, `exe/lain`'s `exit_status` (`:106`)
**Shared-file wiring:** `exe/lain` `epic submit` and `epic finish`: `render` becomes `exit_status` with the status the card's result names (exact diff from the card); `docs/commands.md`: a denied or unanswered gate exits 1
**Reachable from:** `exe/lain` `epic finish` -> `EpicFinish#finish`; `epic submit` -> `EpicSubmit::Verdict#denied` (`cli/epic_submit.rb:~365-395`)

**Acceptance criteria**

```gherkin
Scenario: finish with no remote
  Given a repository with no remote
  When lain epic finish demo runs
  Then it refuses "this repository has no remote; finish it with lain epic finish demo --local" and never says inconsistent_journal

Scenario: a denied gate
  When lain epic submit research demo is answered n
  Then it prints the denial and exits 1

Scenario: a deferred gate is not a failure
  When the gate is deferred
  Then it exits 0
```
Spec file: `spec/lain/cli/epic_finish_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`

**Stop and report if:**
- The String-returning contract of `Verdict` (pinned at `epic_submit_spec.rb:365-375`, `:873`) must change to carry a
  status; then the status rides beside the String.

### T46: Put the epic slug in every remedy the epic commands print          [risk: low]

**Depends on:** T40, T41, T45
**Files:** `lib/lain/cli/epic_finish.rb`, `lib/lain/cli/epic_driver/factory.rb`, `lib/lain/cli/epic_submit.rb`, `spec/lain/cli/epic_finish_spec.rb`, `spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`
**Reuse:** the forms already right: `forge/local_landing.rb:219,263`, `cli/epic_land.rb:85`
**Shared-file wiring:** none
**Reachable from:** `EpicFinish#stopped` (`epic_finish.rb:139-145`, `rerun` at `:170`, `:220`); `Factory::STRANDED` (`factory.rb:783`, formatted at `:1286`); `epic_submit.rb:233`, `:255`, `:663`

**Acceptance criteria**

```gherkin
Scenario: with 2 epics, every printed remedy runs as printed
  Given epics demo and other
  When finish stops, a run strands an issue, or submit refuses
  Then each remedy names demo, and running it does not refuse as ambiguous
```
Spec file: `spec/lain/cli/epic_finish_spec.rb` (`:243`), `spec/lain/cli/epic_driver/run_spec.rb` (`:662`, `:818`), `spec/lain/cli/epic_submit_spec.rb`

**Stop and report if:**
- A remedy is printed where the slug is not in scope.

### T47: Name every bad `gate` in the block form of `epics do`          [risk: low]

**Depends on:** none
**Files:** `lib/lain/config/builder.rb`, `spec/lain/config/builder_spec.rb`
**Reuse:** `Epics::Gates.check!` (`config/epics/gates.rb:~51-66`), `Refusal`'s array `key:`
**Shared-file wiring:** none
**Reachable from:** `Config.load` -> `Config::Builder` (`config/builder.rb:80`) -> `#gates_from` (`:248-266`)

**Acceptance criteria**

```gherkin
Scenario: 2 bad gate lines
  Given epics do; gate :resarch, :auto; gate :plan, :sometimes; end
  When the config loads
  Then one refusal names both lines and both problems

Scenario: one bad gate line reads as today
  Then builder_spec's single-error examples pass unchanged
```
Spec file: `spec/lain/config/builder_spec.rb`

**Stop and report if:**
- `spec/lain/config/epics/gates_spec.rb:68`, `:77` or `:266` changes.

### T48: Suggest `--base` when `lain review feature` finds no default base          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/review.rb`, `lib/lain/cli/command/review.rb`, `spec/lain/cli/review_spec.rb`, `spec/lain/cli/command/review_spec.rb`
**Reuse:** the chat side's rescue of `Review::Source::UnknownRef` (`cli/command/review.rb:~302-311`), moved to one home
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `review` -> `CLI::Review#present` (`cli/review.rb:93`) -> `Target#resolve` (`:205`); `/review` -> `CLI::Command::Review#resolved_target`

**Acceptance criteria**

```gherkin
Scenario: a repository whose trunk is master
  Given a repository with branches master and feature and no main
  When lain review feature runs
  Then it refuses naming that there is no default base and to pass --base <ref>

Scenario: the chat side keeps its hint
  Then command/review_spec.rb:346-365 pass unchanged
```
Spec file: `spec/lain/cli/review_spec.rb`, `spec/lain/cli/command/review_spec.rb`

**Stop and report if:**
- The two surfaces resolve targets through different classes, so one shared rescue would change the chat's flow.

### T49: Print an epic document byte for byte          [risk: low]

**Depends on:** T43
**Files:** `lib/lain/cli/epic.rb`, `spec/lain/cli/epic_spec.rb`
**Reuse:** `CLI::Epic#show` (`cli/epic.rb:222-226`)
**Shared-file wiring:** `exe/lain:540-541`: `epic show` prints with `$stdout.write` (or `say(text, nil, false)`), not `render`'s `say`
**Reachable from:** `exe/lain` `epic show` -> `CLI::Epic#show`

**Acceptance criteria**

```gherkin
Scenario: a document with no trailing newline
  Given epic.md whose last byte is not a newline
  When lain epic show demo runs
  Then stdout equals the file's bytes exactly
```
Spec file: `spec/lain/cli/epic_spec.rb` (a byte-exact CLI example)

**Stop and report if:**
- `epic show` has a second output path (paging) that adds its own newline.

### T52: Say the evidence researcher informs approvals          [risk: low]

**Depends on:** none
**Files:** `lib/lain/prompt/slots.rb`, `spec/lain/prompt/slots_spec.rb`
**Reuse:** `Role::Catalog.approval_roles`
**Shared-file wiring:** none
**Reachable from:** `Prompt::Slots#refuse_approval_role!` (`prompt/slots.rb:~108-112`) on every role slot read

**Acceptance criteria**

```gherkin
Scenario: a project slot file for evidence_researcher
  Given .lain/prompts/roles/evidence_researcher.md
  When the slots load
  Then the refusal says evidence_researcher informs approvals, and auto_approver's still says it decides them
```
Spec file: `spec/lain/prompt/slots_spec.rb` (`:358-370`)

**Stop and report if:**
- `spec/lain/role_spec.rb:308` or `:377` pins the shared sentence.

### Secret boundary and memory

### T50: See a credential name inside a compound identifier, assigned a literal          [risk: high]

**Depends on:** none
**Files:** `lib/lain/credential_patterns.rb`, `spec/lain/credential_patterns_spec.rb`, `spec/lain/middleware/refuse_secret_writes_spec.rb`, `spec/lain/frontend/intake/discretion_spec.rb`, `spec/lain/sensitivity/regions_spec.rb`
**Reuse:** the encoding contract (`credential_patterns.rb:20-28`), the write-side rule that prose is never refused (`:8-13`), the panel's probe `r26plan/probes/panel_t50.rb` in the planning scratchpad (copy its lines into the spec)
**Shared-file wiring:** `ARCHITECTURE.md:597`: the guard stack is ConfineToScope plus 8 layers, not 6
**Reachable from:** `Middleware::RefuseSecretWrites` (`PATTERNS`, `refuse_secret_writes.rb:38`), built by `ToolGuard` (`cli/tool_guard.rb:385`); also `Frontend::Intake::Discretion` (`discretion.rb:20,27`) and `Sensitivity::Regions` (`regions.rb:122,281`)

The word may be the last segment of a compound identifier, and the value must look like a literal: a quoted string,
or a bare token of at least 6 characters that is not `nil`, `true` or `false`, does not start with `@`, `$`, `ENV`,
`params`, `request`, `<%` or a call, and is not followed by `(`, `[` or `.`.

**Acceptance criteria**

```gherkin
Scenario: compound credential lines are refused by memory_write
  When the model calls memory_write with a body holding any one of "AWS_SECRET_ACCESS_KEY=abc123def", "DB_PASSWORD=hunter2pass", "GITHUB_TOKEN=ghx_abc123", "OPENAI_API_KEY=sk-abc123", "STRIPE_SECRET=abc123def", "SECRET_KEY_BASE=abc123def456" or "export SLACK_TOKEN=xoxb-abc123"
  Then each call is refused naming a credential assignment

Scenario: ordinary code is not refused
  When the body holds any one of "token_count = 5", "max_tokens: 100", "note: remember this", "access_token = request.headers['X']", "id_token: nil", "refresh_token: params[:refresh]", "auth_token = SecureRandom.hex", "reset_password = true", "confirm_password: string", "page_token = resp.next" or "client_secret: <%= ENV['X'] %>"
  Then memory_write stores it

Scenario: a typed you> line follows the same table
  Then discretion_spec keeps "note: the build is green" in history and withholds "DB_PASSWORD=hunter2pass"
```
Spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb` (the sample table, `:91-99`), `spec/lain/credential_patterns_spec.rb` (the literal copy `:6-15` and `:29-35` move with it; `:170-175` inverts)

**Stop and report if:**
- `regions_spec.rb:59-62` or any detector example changes its reason name in a way a journal reader keys on.
- `confirm_password: string` and `DB_PASSWORD=hunter2pass` cannot be told apart by value shape alone; report which
  side gives.

### T51: Mask `memory_read`'s body          [risk: high]

**Depends on:** T28, T50
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/tools/memory_read_spec.rb`
**Reuse:** `Sensitivity::TextMask` (T27), the fail-closed precedent with no release (`consolidation.rb:255`, `cli/improve.rb:127`)
**Shared-file wiring:** `ARCHITECTURE.md:1025-1040`: `memory_read` joins the readers the mask step covers, body only, no release
**Reachable from:** `ToolGuard` (`cli/tool_guard.rb:386`) wraps `Tools::MemoryRead`, wired at `cli/wiring.rb:160` for chat and `consolidation.rb:188` for the clerk

**Acceptance criteria**

```gherkin
Scenario: a credential already in the store is masked on read
  Given a project store holding an item whose body has "DB_PASSWORD=hunter2pass"
  When a fresh chat's model calls memory_read for it
  Then the result shows <redacted:1> in place of the value and keeps the author line

Scenario: a clean body reads unchanged
  Given an item "the build uses rake pspec"
  Then memory_read returns it byte for byte

Scenario: the clerk's read is masked too
  When lain consolidate reads the same item
  Then it sees <redacted:1>
```
Spec file: `spec/lain/middleware/redact_secret_reads_spec.rb` (through `ToolGuard`'s stack), `spec/lain/tools/memory_read_spec.rb`

**Stop and report if:**
- A body like `token_count = 123456` is masked; the T50 shape must not reach the region detector's `NAME_HINT` path in
  a way that masks ordinary code, and the card reports the false-positive rate on the repo's own memory store.

### T53: Refuse a search of one gated file before asking anyone          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/middleware/withhold_secret_paths.rb`, `spec/lain/middleware/withhold_secret_paths_spec.rb`
**Reuse:** `Sensitivity::Policy#gates?` (`sensitivity/policy.rb:406`), `Policy#judge`
**Shared-file wiring:** none
**Reachable from:** `ToolGuard`'s stack, where `WithholdSecretPaths` sits outside `Gate` (`cli/tool_guard.rb:384-390`)

**Acceptance criteria**

```gherkin
Scenario: grep names a gated file as its path
  When the model calls grep with path ".env"
  Then it is refused before any approval is asked, with "searching a gated file returns nothing; use read_file on it to ask for a release"
  And no approval_pending is written

Scenario: a directory grep is unchanged
  Then withhold_secret_paths_spec's directory examples pass unchanged
```
Spec file: `spec/lain/middleware/withhold_secret_paths_spec.rb` (`:131-138` changes from "1 match withheld" to the refusal)

**Stop and report if:**
- `spec/lain/sensitivity/policy_spec.rb:940` (a related directory stays ungated) changes.

### T54: Stop the masked-read trailer claiming a file is inside the project          [risk: low]

**Depends on:** T51
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `RedactSecretReads::Trailer.line` (`redact_secret_reads.rb:610-613`)
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#mask` -> `Trailer.append`

**Acceptance criteria**

```gherkin
Scenario: a masked read under a related directory
  Given related: %w[~/dev/app] and a secret in ~/dev/app/.env.example
  When read_file masks it
  Then the trailer says the file is readable and never that it is inside the project
```
Spec file: `spec/lain/middleware/redact_secret_reads_spec.rb` (`:853-862`)

**Stop and report if:**
- The trailer text is an oracle or cache key somewhere.

### T55: Refuse `related: %w[~]` as the home directory          [risk: low]

**Depends on:** none
**Files:** `lib/lain/sensitivity.rb`, `spec/lain/sensitivity_spec.rb`
**Reuse:** `Sensitivity::Rules.relation`'s `UNSPECIFIC` check (`sensitivity.rb:562`)
**Shared-file wiring:** none
**Reachable from:** `Config.load` -> `sensitivity do related ... end` -> `Sensitivity::Rules.rule` (`sensitivity.rb:~540-545`) -> `relation` (`:555-565`)

**Acceptance criteria**

```gherkin
Scenario: a bare tilde
  Given sensitivity do related "~" end
  Then the refusal says it must name a specific tree, not the home directory
```
Spec file: `spec/lain/sensitivity_spec.rb` (`:1633-1636`)

**Stop and report if:**
- `spec/lain/seams/related_read_spec.rb:101` changes.

### T56: Tell the model a denial was remembered          [risk: low]

**Depends on:** none
**Files:** `lib/lain/middleware/remembered_denials.rb`, `spec/lain/middleware/remembered_denials_spec.rb`
**Reuse:** `PATH_DENIED`, `CALL_DENIED` (`remembered_denials.rb:34-35`)
**Shared-file wiring:** none
**Reachable from:** `ToolGuard`'s stack -> `RememberedDenials#call` (`remembered_denials.rb:55-63`)

**Acceptance criteria**

```gherkin
Scenario: a bare n remembered
  Given the human denied list_files on secrets/ with no reason
  When the model asks for the same path again
  Then the model reads that a human denied this path earlier this session, beside 'approval denied for tool "list_files"'

Scenario: a first denial reads as today
  Then the bare text for a fresh n is unchanged
```
Spec file: `spec/lain/middleware/remembered_denials_spec.rb` (`:53-57` changes)

**Stop and report if:**
- `cockpit-surfaces.md:978-993` or `shell-terms.md:75` quote a remembered repeat as the bare text; T90 updates them.

### T57: Promise "no approval will lift this" only where none can          [risk: medium]

**Depends on:** T16, T19, T20, T30, T74
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/middleware/gate.rb`, `lib/lain/approval/judged.rb`, `lib/lain/cli/tool_guard.rb`, `spec/lain/middleware/gate_spec.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/approval/judged_spec.rb`, `spec/lain/cli/switchboard_spec.rb`
**Reuse:** `Escalation::Ruling` (`escalation.rb:90`), `Gate::FINAL` (`gate.rb:83-84`), `Gate#refusal` (`:150-153`)
**Shared-file wiring:** none
**Reachable from:** `Gate#refusal` for every final ruling: `Triage` protected paths (`escalation.rb:653-658`), the rules rung (`:464`), `Bypass` (`:766-771`), `Judged::Unattended` (`judged.rb:133`), `LeasedPolicy` (`cli/tool_guard.rb:262`)

**Interface**

```ruby
Ruling = Data.define(..., :liftable) # true when a human in ask could approve the same call
```

**Acceptance criteria**

```gherkin
Scenario: a bypass deny a human could lift
  Given approval bypass and a barred call
  Then the model reads the Bypass told sentence once, with no "no approval will lift this" and "do not re-send" said once

Scenario: a protected path stays unliftable
  Given a write to .git/config
  Then the refusal still says no approval will lift this
```
Spec file: `spec/lain/middleware/gate_spec.rb` (`:134-160`), `spec/lain/approval/escalation_spec.rb` (`:1372-1383`, `:1423-1427`)

**Stop and report if:**
- `Middleware::Sensitivity::FINAL` (`middleware/sensitivity.rb:48`, "no approval can lift this") is on the same path;
  it is correct for a denied path and stays.

### Compaction, session record and resume

### T58: Record `--no-compact` and honour it on resume          [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/compaction_profile.rb`, `lib/lain/cli/backend.rb`, `lib/lain/cli/chat_launch.rb`, `lib/lain/session_record.rb`, `spec/lain/cli/compaction_profile_spec.rb`, `spec/lain/cli/backend_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/session_record_spec.rb`, `spec/lain/cli/resume_spec.rb`
**Reuse:** `CompactionProfile::FLAGS`, `.typed`, `.from_header`, `#over`, `#to_header`; `MismatchNotices#compaction_notices` (`cli/resume/mismatch_notices.rb:76`) iterates `FLAGS`, so a new member gets its notice
**Shared-file wiring:** `exe/lain:1022`: `--compact` loses `default: true`; `docs/commands.md:63`: an untyped resume keeps the recorded choice
**Reachable from:** `exe/lain` `chat` -> `CLI::ChatLaunch` (`chat_launch.rb:80`, `#compaction` at `:240`, `#backend` at `:227`) -> `Backend#compaction?` (`backend.rb:560`) and `#compaction_header` (`:616`) -> `CLI::Wiring` (`wiring.rb:356`) -> the Scribe's header

**Acceptance criteria**

```gherkin
Scenario: --no-compact is recorded
  When lain chat --no-compact starts
  Then the header holds "compact": false

Scenario: a default run's header is unchanged
  When lain chat starts with no compaction flag
  Then the header holds no "compact" key, byte-identical to today's

Scenario: an untyped resume keeps compaction off
  Given a session recorded with --no-compact
  When lain --resume runs it with no compaction flag
  Then it writes 0 compaction_decision records and says the recording ran without compaction

Scenario: a typed --compact over it says so
  When lain --resume --compact runs it
  Then compaction runs and the resume notice names the change
```
Spec file: `spec/lain/cli/chat_launch_spec.rb` (through `ChatLaunch`, no double), `spec/lain/session_record_spec.rb` (`:1080` inverts), `spec/lain/cli/backend_spec.rb` (`:1728`)

**Stop and report if:**
- `chat_launch_spec.rb:809`, `:185` or `:1035` pass `compact: false` in an options hash that bypasses the profile; they
  move to the profile, and any other caller doing the same is a reachability gap.
- The loader's required keys would have to change.

### T59: Refuse to pool a compacted run with an uncompacted one          [risk: medium]

**Depends on:** T58
**Files:** `lib/lain/bench/variance.rb`, `lib/lain/bench/session.rb`, `lib/lain/bench/session/loader.rb`, `spec/lain/bench/variance_spec.rb`, `spec/lain/bench/session/loader_spec.rb`
**Reuse:** `Variance#guard_schedule!` (`bench/variance.rb:166`) as the template, `Loader#header_field`, `RequiredKeys.read`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench variance` -> `Bench::CLI#variance_report` -> `build_variance` -> `Variance`

**Acceptance criteria**

```gherkin
Scenario: one recording off, one on
  Given a recording with "compact": false and one with no compact key
  When bench variance runs over both
  Then it refuses naming that one ran without compaction

Scenario: the shipped variance fixtures still pool
  Then the fixtures under spec/fixtures/sessions/variance/ (no compact key) pool as today
```
Spec file: `spec/lain/bench/variance_spec.rb` (`:315` changes: a recording that named the turn schedule and one with compaction off no longer pool)

**Stop and report if:**
- `Bench::Session::Recording`'s explicit `initialize` (`bench/session.rb:204-226`) is built positionally anywhere.

### T60: End a handoff document by deferring to the newest human message          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/oracle/handoff/document.rb`, `spec/lain/oracle/handoff/document_spec.rb`, `spec/lain/oracle/handoff_spec.rb`
**Reuse:** `Handoff::Document#to_s` (`oracle/handoff/document.rb:16`), `PREAMBLE` (`oracle/handoff.rb:123-124`)
**Shared-file wiring:** `ARCHITECTURE.md:420-425`: the rendered heading "Where the work stood"; the field stays `next_step`
**Reachable from:** `Agent#retry_refused` -> `Source#handoff` -> `Source::Fallback#call` -> `Oracle::Handoff.document` -> `Document#to_s`

**Acceptance criteria**

```gherkin
Scenario: the document yields to the human
  When a handoff document renders
  Then its preamble says the human's newest message takes precedence and the old work resumes only if asked
  And the heading reads "Where the work stood"

Scenario: recorded answers keep their address
  Then the oracle's TEMPLATE and SCHEMA bytes are unchanged, so a recorded handoff answer replays
```
Spec file: `spec/lain/oracle/handoff/document_spec.rb` (`:26-27`), `spec/lain/oracle/handoff_spec.rb` (`:33`, `:50`)

**Stop and report if:**
- `Oracle::Definition`'s digest reads `PREAMBLE` or `HEADINGS`.
- `spec/lain/seams/handoff_spec.rb:251` or `spec/lain/compaction/source_spec.rb:3001` assert the heading text; they
  move with it.

### T62: Keep a trailing human prompt out of the summarized span          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compaction/strategy/summarize_conversation.rb`, `spec/lain/compaction/strategy/summarize_conversation_spec.rb`
**Reuse:** `SummarizeConversation#propose_claims` (`strategy/summarize_conversation.rb:~59`), `Compaction::ToolMessages`
**Shared-file wiring:** none
**Reachable from:** `Compaction::Source#context_for` -> `Derivation::Plan.over` (`compaction/derivation.rb:327-328`) -> `Strategy::Summarizing#propose_ranges`

**Acceptance criteria**

```gherkin
Scenario: the cut falls between a prompt and its answer
  Given a chain whose last dropped message is the human's "add a test" and whose first kept message is its answer
  When summarize-conversation proposes its span
  Then "add a test" is kept verbatim outside the span, and the summary never says a prompt went unanswered
```
Spec file: `spec/lain/compaction/strategy/summarize_conversation_spec.rb`

**Stop and report if:**
- Excluding the message moves a `compaction_cut` digest that resume replays; then stop, because cuts are recorded.

### T63: Say when `--api-base` reaches no provider the chat uses          [risk: low]

**Depends on:** T58
**Files:** `lib/lain/cli/backend.rb`, `spec/lain/cli/backend_spec.rb`
**Reuse:** `OllamaTier.claims_base?` (`cli/backend/ollama_tier.rb:119`), `Backend#ollama_base` (`backend.rb:745`), the startup notices
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#run` -> `Backend#startup_notices`

**Acceptance criteria**

```gherkin
Scenario: anthropic chat, ollama summarizer
  When lain chat --provider anthropic --api-base http://h:11434 starts
  Then a startup notice says --api-base reaches the ollama summarizer only, not the anthropic chat

Scenario: anthropic chat with --no-compact
  When it also has --no-compact
  Then the notice says --api-base reaches nothing
```
Spec file: `spec/lain/cli/backend_spec.rb` (`"which arm --api-base reaches"`, `:224-246`, stays green)

**Stop and report if:**
- The notice would print for an ollama chat, where the base is used.

### T64: Journal a request the provider rejected by its own status          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent/stop_reason.rb`, `lib/lain/telemetry/run_interrupted.rb`, `spec/lain/agent/stop_reason_spec.rb`, `spec/lain/telemetry/run_interrupted_spec.rb`
**Reuse:** `StopReason::RULES`, `transport?` (`stop_reason.rb:47-53`), `RoundTripFailure`/`Status` (`provider/error_wrapping.rb`)
**Shared-file wiring:** `ARCHITECTURE.md:626-629`: the reasons list gains `rejected`
**Reachable from:** `CLI::Conductor` (`conductor.rb:~312`) journals `Agent::StopReason.for(cause)`

**Acceptance criteria**

```gherkin
Scenario: HTTP 404 from the provider
  Given the provider answers 404
  Then run_interrupted carries reason "rejected" and the status, not "torn"

Scenario: an unplaceable failure
  Then stop_reason_spec "says torn for anything it cannot place" passes unchanged
```
Spec file: `spec/lain/agent/stop_reason_spec.rb` (`:71-72` inverts for 401 and 404)

**Stop and report if:**
- A reader of `REASONS` (`cli/chronicle.rb:401`, `session_record/scribe.rb:286`, `status_feed.rb`, a bench classifier)
  switches on the members rather than accepting the list.

### T65: Journal an ask that ended on a cut-off or refused reply          [risk: medium]

**Depends on:** T25, T64
**Files:** `lib/lain/cli/repl/ask.rb`, `lib/lain/telemetry/run_interrupted.rb`, `spec/lain/cli/repl/ask_spec.rb`, `spec/lain/cli/repl_spec.rb`
**Reuse:** `Ask#record_interruption` (`cli/repl/ask.rb:104,116`): `@chronicle.catch_up` then `@chronicle.interrupted(head:, reason:)`
**Shared-file wiring:** none
**Reachable from:** `CLI::Repl` -> `Repl::Ask#settle` (`ask.rb:62-66`) -> `#say_failure` (`:84-90`)

**Acceptance criteria**

```gherkin
Scenario: a reply cut off at max_tokens
  Given the model's reply stops with stop_reason truncated
  When the ask settles
  Then 1 run_interrupted record names reason "truncated" and the head
  And repl_spec "reports an answer cut off at max_tokens" passes unchanged
```
Spec file: `spec/lain/cli/repl/ask_spec.rb`

**Stop and report if:**
- A failed stop is already journaled by another path (the Conductor) and this would write it twice.

### T66: Tell `read_file` how many windows a large file takes          [risk: low]

**Depends on:** none
**Files:** `lib/lain/tools/read_file.rb`, `lib/lain/tool/bounds.rb`, `spec/lain/tools/read_file_spec.rb`, `spec/lain/tool/bounds_spec.rb`
**Reuse:** `ReadFile::Sample#advice` (`read_file.rb:613-618`), `ReadFile.too_large` (`:569`), `#narrower_for` (`:584`)
**Shared-file wiring:** none
**Reachable from:** `Tools::ReadFile::Whole#read` -> `ReadFile.too_large`

**Acceptance criteria**

```gherkin
Scenario: a 3 MB file
  When read_file refuses a 3,000,000-byte file whose lines average 60 bytes
  Then the advice names the limit per window and about how many windows cover the file, and suggests grep or a structural read first when that number is over 20

Scenario: the ceiling names its unit
  Then the refusal reads "over the ceiling of 16384 bytes"
```
Spec file: `spec/lain/tools/read_file_spec.rb`, `spec/lain/tool/bounds_spec.rb`

**Stop and report if:**
- `spec/lain/tools/subagent_spec.rb:1034-1045` builds its own `Artifact` with a `unit:` and would read "bytes bytes".

### T67: Write a child's answered question as consumed once          [risk: low]

**Depends on:** none
**Files:** `lib/lain/session_record/scribe.rb`, `spec/lain/session_record/scribe_spec.rb`
**Reuse:** `Scribe#consumption` (`session_record/scribe.rb:352-356`), `AskHuman#retired` (`tools/ask_human.rb:826-832`)
**Shared-file wiring:** none
**Reachable from:** `Scribe#child_turn` (`scribe.rb:~332`) for every spawned chain's turn

**Acceptance criteria**

```gherkin
Scenario: a child asks and is answered
  When the child's answering turn is recorded
  Then the session file holds 1 questions_consumed record for that digest
```
Spec file: `spec/lain/session_record/scribe_spec.rb` (`:292`, `:318`, `:345`, `:357`)

**Stop and report if:**
- `spec/lain/tools/subagent_spec.rb:3393-3440` or `spec/lain/status_feed/inbox_spec.rb` count 2.

### T68: List a session of another format as unloadable          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/sessions.rb`, `lib/lain/cli/resume/selector.rb`, `spec/lain/cli/sessions_spec.rb`
**Reuse:** `SessionRecord.current_format?` (`session_record.rb:87`), `Resume::Selector::PREDATES` and `OTHER_FORMAT` (`cli/resume/selector.rb:19-20`), `#header_reason` (`:101-106`, made public)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `sessions` -> `CLI::Sessions#listing` (`sessions.rb:25`) -> `Row#to_s` (`:107-113`)

**Acceptance criteria**

```gherkin
Scenario: a format-2 file
  Given a session file whose header says format 2
  When lain sessions runs
  Then its row says it is another format and cannot be resumed
```
Spec file: `spec/lain/cli/sessions_spec.rb`

**Stop and report if:**
- `spec/lain/cli/resume/selector_spec.rb` pins `header_reason` as private.

### T69: Count calls in `lain friction` without calling unpriced ones priced          [risk: low]

**Depends on:** none
**Files:** `lib/lain/friction/report.rb`, `spec/lain/friction/cache_waste_spec.rb`
**Reuse:** `@waste.unpriced_models`
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `friction` -> `Friction::Report` (`friction/report.rb:293`)

**Acceptance criteria**

```gherkin
Scenario: 113 calls, none priced
  Then the report reads "113 main-agent calls, 0 priced" beside the no-price note
```
Spec file: `spec/lain/friction/cache_waste_spec.rb` (`:868`)

**Stop and report if:**
- A priced and an unpriced model in one journal cannot be told apart per call.

### T70: Re-ask a switched model's window once it has served          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/backend/window_book.rb`, `spec/lain/cli/backend/window_book_spec.rb`
**Reuse:** `Live#switched_book` (`window_book.rb:251-263`), `#ask_again?` (`:265`), `REASK_LIMIT`, `Live#vouch`
**Shared-file wiring:** none
**Reachable from:** `/model` -> `Live#book_for` (`window_book.rb:~237`); `Middleware::ResolveWindow#call` -> `Live#reresolve`

**Acceptance criteria**

```gherkin
Scenario: /model to a model not yet resident
  Given /api/ps lists no runner for qwen3:4b when /model switches to it
  When the first response from qwen3:4b arrives
  Then the book asks /api/ps again before the next request, and the HUD reads the probed window, not "8192 guessed"

Scenario: an empty /api/ps during a swap does not spend the budget
  Then window_book_spec's re-ask budget examples pass unchanged
```
Spec file: `spec/lain/cli/backend/window_book_spec.rb` (`:320-420`)

**Stop and report if:**
- The re-ask after the first response would add a `/api/ps` to `spec/lain/seams/recorded_run_spec.rb`'s one-probe run.

### Providers, the judge and subagents

### T71: Make the ollama width notices say true things          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend/ollama_tier.rb`, `spec/lain/cli/backend/ollama_tier_spec.rb`
**Reuse:** `OllamaTier#loopback_notice` (`ollama_tier.rb:227-230`), the plain-width sentence (`:239-241`), `#startup_notices` (`:~160-165`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#run` -> `Backend#startup_notices` -> `OllamaTier#startup_notices`

**Acceptance criteria**

```gherkin
Scenario: the loopback notice
  Given a loopback ollama base with a declared width of 4 and LAIN_PROVIDER_CONCURRENCY unset
  Then the notice says the base is held to 1 request and to set LAIN_PROVIDER_CONCURRENCY to override it

Scenario: the retired variable
  Given LAIN_OLLAMA_CLOUD_CONCURRENCY=4 in the environment
  Then a startup notice says it was retired, is ignored, and names LAIN_PROVIDER_CONCURRENCY
```
Spec file: `spec/lain/cli/backend/ollama_tier_spec.rb` (`:471` changes; `:443` "#startup_notices")

**Stop and report if:**
- The retired-name notice should cover more retired variables; list them and keep to the one.

### T72: Name the path a provider retry was for          [risk: low]

**Depends on:** none
**Files:** `lib/lain/telemetry/provider_retry.rb`, `lib/lain/provider/retry_narration.rb`, `lib/lain/frontend/decorators/provider_retry.rb`, `spec/lain/provider/retry_narration_spec.rb`, `spec/lain/frontend/decorators/provider_retry_spec.rb`
**Reuse:** `env[:url]` as `RetryTap` already reads it nil-safely (`provider/ollama/retry_tap.rb`)
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama` (`ollama.rb:651` wires the retry blocks) -> `RetryTap#exhausted_block` -> `RetryNarration#exhausted` (`retry_narration.rb:29-31`)

**Acceptance criteria**

```gherkin
Scenario: the window probe fails
  Given /api/ps is unreachable
  Then the provider_retry record names path "/api/ps" and the chat line names it too

Scenario: an old journal line loads
  Given a provider_retry line with no path
  Then it loads with path nil
```
Spec file: `spec/lain/provider/retry_narration_spec.rb`, `spec/lain/frontend/decorators/provider_retry_spec.rb`

**Stop and report if:**
- `spec/lain/bench/cli/run_recorder_spec.rb` compares provider_retry records byte for byte.

### T73: Print a config-defined middleware class by its own name          [risk: low]

**Depends on:** none
**Files:** `lib/lain/config/middleware.rb`, `spec/lain/config/middleware_spec.rb`
**Reuse:** `Config::Middleware#describe` (`config/middleware.rb:50`)
**Shared-file wiring:** none
**Reachable from:** `Config.load` -> `Config::Builder` (`builder.rb:80`, `instance_eval`) -> `Config::Middleware` refusal (`middleware.rb:41`)

**Acceptance criteria**

```gherkin
Scenario: class Foo defined in .lain/config.rb with no #call
  When the config loads
  Then the refusal names "Foo", never "#<Class:0x...>::Foo"
```
Spec file: `spec/lain/config/middleware_spec.rb` (`:86-91` stays for the anonymous case)

**Stop and report if:**
- The prefix is not always `#<Class:...>::` (a nested module in the config).

### T74: Note a judge fault on the parked call          [risk: low]

**Depends on:** none
**Files:** `lib/lain/approval/judged.rb`, `spec/lain/approval/judged_spec.rb`
**Reuse:** `Escalation::Noted`, as `Judged#unjudged` uses it (`judged.rb:232-235`)
**Shared-file wiring:** none
**Reachable from:** `Approval::Judged#faulted` (`judged.rb:239-242`), on the default `auto` ladder built by `CLI::Wiring::BoardBuild`

**Acceptance criteria**

```gherkin
Scenario: the judge times out
  Given the judge does not answer within its bound
  Then the parked call's notes read "the judge could not be asked (it timed out or failed)"
  And the exception text stays in the journal only
```
Spec file: `spec/lain/approval/judged_spec.rb` (beside `:243`, reading `pending.notes`)

**Stop and report if:**
- The fault reaches the queue through another rung that already notes it.

### T75: Run the read-only judge without leasing a worktree          [risk: medium]

**Depends on:** T16
**Files:** `lib/lain/skill/role_spawn.rb`, `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/approval/gate/adjudicator_spec.rb`
**Reuse:** `Isolation::Leases.new` with its `Null` backend (`isolation/leases.rb:169`), `Leases::InPlace` (`:120-149`)
**Shared-file wiring:** none
**Reachable from:** `Approval::Judge` takes `role_spawn.never_parking` (`approval/judge.rb:118`); also `approval/gate/adjudicator.rb:515`

**Acceptance criteria**

```gherkin
Scenario: a judged call under --isolation worktree
  Given lain chat --isolation worktree
  When the judge rules on a call
  Then git worktree list is unchanged during and after the ruling

Scenario: the epic adjudicator still reads its evidence
  Then adjudicator_spec passes unchanged
```
Spec file: `spec/lain/skill/role_spawn_spec.rb` (`:132`)

**Stop and report if:**
- The adjudicator needs a checkout of its own as its cwd.

### T76: Refuse a research workspace that cannot be made, in words          [risk: low]

**Depends on:** T86
**Files:** `lib/lain/tools/subagent.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Kept::Refused` (`tools/subagent.rb:934`), the `SystemCallError` conversion in `admitted` (`:1036-1042`)
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent` `Kept#scratched` (`subagent.rb:1027`) -> `Isolation::Scratch#acquire` (`isolation/scratch.rb:31-35`)

**Acceptance criteria**

```gherkin
Scenario: the scratch root is not writable
  Given a scratch root the process cannot write
  When the model spawns a kept researcher
  Then it reads "the research workspace could not be created at <dir>: permission denied", with no "@ dir_s_mkdir"
```
Spec file: `spec/lain/tools/subagent_spec.rb`

**Stop and report if:**
- The lazy raise reaches the model through a path other than `Effect::Handler::Live#run`'s rescue.

### T77: Flush `lain watch` output as it arrives          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/watch.rb`, `spec/lain/cli/watch_spec.rb`
**Reuse:** the `Journal`'s `@io.sync = true` (`journal.rb:175`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain:1299` `watch` -> `CLI::Watch.new(sink: $stdout).run`

**Acceptance criteria**

```gherkin
Scenario: watch to a file
  Given lain watch writing to a file
  When a record arrives
  Then the line is in the file before watch exits
```
Spec file: `spec/lain/cli/watch_spec.rb` (an IO whose `flush` is counted)

**Stop and report if:**
- Flushing per line costs measurably on a long journal; flush per batch then.

### Merge coordinator

### T78: Let a caller learn the pid of a command `Shell::Out` spawned          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/shell/out.rb`, `spec/lain/shell/out_spec.rb`
**Reuse:** `Shell::Out#spawn` (`shell/out.rb:206-211`, `pgroup: true`)
**Shared-file wiring:** none
**Reachable from:** `Isolation::Verifier::Command#call` (`isolation/verifier/command.rb:62`), T80

**Interface**

```ruby
Shell::Out#run_command(..., on_spawn: ->(pid) {}) # called once, after spawn, before the wait
```

**Acceptance criteria**

```gherkin
Scenario: the callback sees the group leader
  When a command runs with on_spawn
  Then the callback gets the pid, which is also the process group id
```
Spec file: `spec/lain/shell/out_spec.rb`

**Stop and report if:**
- The `shell_out_factory` fakes in `landing_queue`, `candidate_desk` and `verifier_spec.rb:50` would raise on the new
  keyword; default it.

### T79: Hand a lock's stale holder line to whoever takes the lock next          [risk: high]

**Depends on:** none
**Files:** `lib/lain/file_lock.rb`, `spec/lain/file_lock_spec.rb`
**Reuse:** `FileLock#claimed` (`file_lock.rb:101-112`), `#hold`
**Shared-file wiring:** none
**Reachable from:** `SuiteLock.for` (`isolation/suite_lock.rb:15-23`) -> `Verifier::Command` (`command.rb:33`)

**Interface**

```ruby
FileLock#hold(notice: ..., reclaim: ->(previous_holder_line) {}) { |note| ... }
# reclaim runs after flock succeeds and before truncate, only when the file held a line
# (a clean release truncates, so a line there is a dead holder's); note appends to the holder line
```

**Acceptance criteria**

```gherkin
Scenario: a holder killed with SIGKILL
  Given a process that holds the lock is killed with SIGKILL
  When another process takes the lock
  Then reclaim receives the dead holder's line

Scenario: a clean release leaves nothing to reclaim
  Then reclaim is not called after a holder released normally
```
Spec file: `spec/lain/file_lock_spec.rb` (a real child process, killed)

**Stop and report if:**
- `spec/lain/isolation/suite_lock_spec.rb` "naming no holder after the release" changes.

### T80: Kill an orphaned verify before the next drainer verifies          [risk: high]

**Depends on:** T78, T79
**Files:** `lib/lain/isolation/verifier/command.rb`, `lib/lain/isolation/verifier.rb`, `lib/lain/isolation/landing_queue.rb`, `spec/lain/isolation/verifier/command_spec.rb`
**Reuse:** T78's `on_spawn`, T79's `reclaim:` and `note`, `Liveness::Probe#start_of` (`liveness.rb:36-67`), `Shell::Out`'s TERM-then-KILL of a group (`shell/out.rb:260-295`, extracted or mirrored); a `notice:` on `Command`, passed by `Verifier.from` (`landing_queue.rb:110`), as `Drain.for` already takes one, so nothing under `lib/lain/isolation` writes to stderr
**Shared-file wiring:** `docs/commands.md:458-461`: a SIGKILLed drainer's verify is stopped by the next suite-lock holder
**Reachable from:** `lain land drain` -> `MergeCoordinator::Drain#call` -> `LandingQueue#verified` -> `Drain::Stopwatch#call` (`drain.rb:144`) -> `Verifier::Command#call`

**Acceptance criteria**

```gherkin
Scenario: a drainer killed mid-verify
  Given drainer A's verify is running and A is killed with SIGKILL
  When drainer B takes the suite lock
  Then A's verify process group is gone before B's verify starts
  And the holder line B writes reads pid=<B> ... verify_pgid=<n> start=<ticks>

Scenario: a reused pid is not killed
  Given the recorded verify_pgid now belongs to a process with another start time
  When B takes the lock
  Then nothing is killed

Scenario: an unreadable /proc kills nothing
  Given the start time cannot be read
  Then nothing is killed and B's drain.log says so, through the notice Command now takes
```
Spec file: `spec/lain/isolation/verifier/command_spec.rb` ("runs while holding the suite lock" keeps its `pid=` grep)

**Stop and report if:**
- The group's leader is gone but members remain; the check then needs each member's pgrp and its `TMPDIR`
  (`lain-verify-<sha12>`), and the card reports whether that is reliable.

### T81: Decline a superseded spool entry instead of landing it          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/isolation/merge_coordinator/drain.rb`, `spec/lain/isolation/merge_coordinator/drain_spec.rb`
**Reuse:** `Isolation::Checkout#ancestor?` (`isolation/checkout.rb:103`), `Spool#complete`, `WorkerHandoff::Report`'s `:declined`
**Shared-file wiring:** none
**Reachable from:** `lain land drain` -> `Drain#call` (`drain.rb:88`) -> `#batches` -> `next_batch` (`:115`)

**Acceptance criteria**

```gherkin
Scenario: an amended branch enqueued twice
  Given entry 1 for worker w at sha A, then entry 2 for w at sha B where A is not an ancestor of B
  When the drainer runs
  Then entry 1 completes declined "superseded by entry 2" and only B lands

Scenario: a continuation still lands both
  Then drain_spec "two entries for one worker lands them in separate batches, the later waiting for the next" passes unchanged
```
Spec file: `spec/lain/isolation/merge_coordinator/drain_spec.rb`

**Stop and report if:**
- The drainer has no git handle at `next_batch` without constructing one.

### T82: Check the project config is trusted before enqueueing a landing          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/land.rb`, `spec/lain/cli/land_spec.rb`
**Reuse:** `Land#usable!` (`cli/land.rb:123-126`), `Config.load(root:)` (memoised), `Project::Trust::Untrusted`'s message
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `land enqueue` -> `CLI::Land#enqueue` (`land.rb:64-74`)

**Acceptance criteria**

```gherkin
Scenario: an untrusted config
  Given .lain/config.rb is not trusted
  When lain land enqueue runs
  Then it refuses naming the file and lain trust, and nothing is queued, anchored or spawned
```
Spec file: `spec/lain/cli/land_spec.rb`

**Stop and report if:**
- `Config.load` has side effects (writes) at enqueue time.

### T83: Say when a landing ran no verification          [risk: low]

**Depends on:** T82
**Files:** `lib/lain/cli/land.rb`, `spec/lain/cli/land_spec.rb`
**Reuse:** `CLI::EpicLand#verified`'s "verification skipped: <detail>" (`cli/epic_land.rb:99-103`), `Verifier::Skipped::DETAIL`
**Shared-file wiring:** `docs/commands.md:422-424`: with no verify configured a branch fast-forwards unverified, and `wait` says so
**Reachable from:** `exe/lain` `land wait` -> `Land#wait` (`land.rb:96-110`) -> `#told` (`:213-218`)

**Acceptance criteria**

```gherkin
Scenario: no verify configured
  Given no verify command is configured
  When a branch lands and lain land wait reads the result
  Then it prints "landed at <sha>" and "verification skipped: no verification is configured", exit 0
```
Spec file: `spec/lain/cli/land_spec.rb` ("#wait", `:173-262`)

**Stop and report if:**
- `:skipped` is also NOTHING_LANDED's outcome (`landing_queue.rb:29`) on a moved report.

### T84: Say in the drain log that a drainer waits on another repo's suite lock          [risk: low]

**Depends on:** T80
**Files:** `lib/lain/isolation/verifier/command.rb`, `spec/lain/isolation/verifier/command_spec.rb`
**Reuse:** `FileLock#hold(notice:)`, `#waiting_on` (`file_lock.rb:92-98`), the `notice:` T80 gives `Command`
**Shared-file wiring:** none
**Reachable from:** `Verifier.from` (built at `landing_queue.rb:110`) -> `Command#call`

**Acceptance criteria**

```gherkin
Scenario: another repository holds the suite lock
  Given the suite lock is held by another process for 6 seconds
  When a drainer's verify waits on it
  Then drain.log holds "waiting on pid=<n> command=<...> for the suite lock (<path>)" once
```
Spec file: `spec/lain/isolation/verifier/command_spec.rb`

**Stop and report if:**
- `epic land` would print the notice to a surface that has none today.

### T85: Name the lock path once in a lock refusal          [risk: low]

**Depends on:** T79
**Files:** `lib/lain/file_lock.rb`, `lib/lain/paths.rb`, `spec/lain/file_lock_spec.rb`, `spec/lain/paths_spec.rb`
**Reuse:** `SystemCallError.new(nil, e.errno).message`
**Shared-file wiring:** none
**Reachable from:** `CLI::Land#usable!` -> `FileLock#holder` (`file_lock.rb:57-61`) -> `Unreadable` (`:16-18`); `Paths::Unwritable` (`paths.rb:30-34`)

**Acceptance criteria**

```gherkin
Scenario: a mode 000 lock file
  When lain land enqueue runs
  Then the refusal reads "cannot use the lock <path>: Permission denied" with the path once
```
Spec file: `spec/lain/file_lock_spec.rb` (`:142-156`)

**Stop and report if:**
- `spec/lain/cli/land_spec.rb:303-334`'s one-line status check changes.

### Documents

### T90: Bring the QA scenarios in line with what this plan landed          [risk: low]

**Depends on:** every other card
**Files:** `planning/qa/scenarios/*.md`, `planning/qa/README.md`, `planning/specs/bash-confinement.md`, `planning/specs/idle-compaction.md`
**Reuse:** each card's report of the scenario lines it made stale
**Shared-file wiring:** `ROADMAP.md` item 65 marked done; `ARCHITECTURE.md:597`, `:1583` stale counts and wording from Grounding
**Reachable from:** deferred: documents, no production site

**Acceptance criteria**

```gherkin
Scenario: no scenario quotes a fixed defect as current
  When grep -n "round 26" planning/qa/scenarios/*.md runs
  Then every hit either states the fixed behaviour with its card id or names the round 27 item it waits on

Scenario: the docs lint passes
  Then bin/lint-gherkin-docs passes on every changed planning file
```
Spec file: none (documents); the check is the 2 commands above

**Stop and report if:**
- A scenario's expected text disagrees with what a card landed; the card's spec wins and the scenario follows.

### The window: a reply reserve, an output ceiling, and a round that cannot fit

These cards come from the 2 research passes in Spike findings. `max_tokens` did 2 jobs: the wire ceiling (the most a
reply may cost) and the planners' reserve (the room a reply needs). They separate here. c26-3 is fixed at its cause
(a round budget at production), at its symptom (a handoff that cannot help declines), and for rounds already committed
(an opt-in stub arm).

### T87: Compute one reply reserve from the window and the output ceiling          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/reply_reserve.rb` (new), `spec/lain/reply_reserve_spec.rb` (new), `lib/lain/compaction/need.rb`, `spec/lain/compaction/need_spec.rb`
**Reuse:** `ContextWindow`'s resolution and provenance (`context_window.rb:226,372`)
**Shared-file wiring:** none
**Reachable from:** `Compaction::Need` (`compaction/need.rb:87,131`), built for every chat by `Compaction::Source` from `CLI::Wiring`

**Interface**

```ruby
module Lain
  ReplyReserve = Data.define(:tokens, :basis) do
    # tokens = min(ceiling, max(4_096, window / 8)); basis names the window's provenance
    def self.for(window:, ceiling:)
  end
end
```

**Acceptance criteria**

```gherkin
Scenario: a 32,768-token window with a 16,384 ceiling
  Then the reserve is 4,096

Scenario: a 262,144-token window with a 32,768 ceiling
  Then the reserve is 32,768

Scenario: the compaction trigger leaves the reserve free
  Given a 32,768-token window
  Then ApproachingWindow fires at 28,672 prompt tokens, the earlier of 0.9 of the window and window minus reserve
```
Spec file: `spec/lain/reply_reserve_spec.rb`, `spec/lain/compaction/need_spec.rb`

**Stop and report if:**
- A guessed window (`provenance` guessed) would move the trigger; a guessed window keeps today's 0.9 only.

### T88: Reserve the reply reserve, not the whole cap, in critique and handoff          [risk: medium]

**Depends on:** T60, T87
**Files:** `lib/lain/review/critique.rb`, `lib/lain/oracle/handoff.rb`, `spec/lain/review/critique_spec.rb`, `spec/lain/oracle/handoff_spec.rb`
**Reuse:** `ReplyReserve` (T87), `Critique::Budget` (`review/critique.rb:234-243`), `Oracle::Handoff::RESERVED_TOKENS` (`oracle/handoff.rb:82`)
**Shared-file wiring:** none
**Reachable from:** `/critique` -> `Review::Critique` -> `Budget`; `Source::Fallback#call` -> `Oracle::Handoff`

**Acceptance criteria**

```gherkin
Scenario: a critique on a 32k window
  Given a 32,768-token window and max_tokens 16,384
  Then Critique::Budget plans with 4,096 reserved, and RESERVE_OVER no longer fires for a diff that fits in 28k tokens

Scenario: the handoff's own call keeps its fixed reserve
  Then Oracle::Handoff's summarizer call reserves what its own 1,024-token cap needs, unchanged
```
Spec file: `spec/lain/review/critique_spec.rb`, `spec/lain/oracle/handoff_spec.rb`

**Stop and report if:**
- `RESERVED_TOKENS` is part of the handoff oracle's definition digest; then it stays and the card says why.

### T89: Set the output ceiling per model, with `--max-tokens` as an override          [risk: high]

**Depends on:** T58, T63
**Files:** `lib/lain/output_ceiling.rb` (new), `spec/lain/output_ceiling_spec.rb` (new), `lib/lain/cli/backend.rb`, `lib/lain/cli/backend/ceiling.rb`, `lib/lain/session_record.rb`, `spec/lain/cli/backend_spec.rb`, `spec/lain/session_record_spec.rb`, `spec/lain/cli/chat_flags_spec.rb`, `spec/lain/cli_spec.rb`
**Reuse:** `ContextWindow`'s shipped table and its served-window lookup, `Backend#max_tokens` (`backend.rb:761`), `Ceiling`'s refusal of non-positive values
**Shared-file wiring:** `exe/lain:421` and `:465-468`: `--max-tokens` defaults to unset (auto) instead of 16,384; `docs/commands.md`: the ceiling comes from the model, and `--max-tokens` overrides it. The card applies the `exe/lain` diff in its own worktree, so `chat_flags_spec.rb:161-164` and `cli_spec.rb:1132,1152` (which pin 16,384) run against it, and hands the diff back
**Reachable from:** `exe/lain` `chat` -> `CLI::ChatLaunch` -> `Backend#max_tokens` -> `Context.new(max_tokens:)` (`backend.rb:391`); children inherit it (`context.rb:168-170`)

**Interface**

```ruby
module Lain
  OutputCeiling = Data.define(:tokens, :source) do # source: :typed, :table, :served_window, :cloud_default
    def self.for(model:, window:, typed: nil)
  end
end
```

**Acceptance criteria**

```gherkin
Scenario: an Anthropic 4.6+ model with no flag
  When lain chat starts on claude-opus-4-6 with no --max-tokens
  Then requests carry max_tokens 128,000 and the header records ceiling source "table"

Scenario: a local ollama model with no table entry
  Given a served window of 32,768
  Then requests carry max_tokens 32,768, source "served_window"

Scenario: an ollama cloud model with no table entry
  Then requests carry max_tokens 32,768, source "cloud_default"

Scenario: a typed flag wins
  When lain chat --max-tokens 4096 starts
  Then requests carry 4,096, source "typed"

Scenario: a guessed window never clamps the ceiling
  Given the window resolves "guessed" at 8,192
  Then the ceiling is not clamped to 8,192

Scenario: /model re-resolves an untyped ceiling
  Given a chat started with no --max-tokens
  When /model switches to a model with another table entry
  Then the next request carries the new model's ceiling, and a typed --max-tokens would have stayed
```
Spec file: `spec/lain/output_ceiling_spec.rb`, `spec/lain/cli/backend_spec.rb` (through `Backend`, no double)

**Stop and report if:**
- `bench record` (1,024) and `bench arms` (4,096) defaults go through the same path; they keep their typed values.
- A pre-4.5 Anthropic model in the table would get input plus ceiling over its window and a 400; clamp those to the
  window or send the beta header, and say which.
- A 128,000 ceiling on lain's own non-streaming request path meets its read timeout; name the path and its timeout.

### T91: Read Anthropic's window stop as a full context          [risk: low]

**Depends on:** none
**Files:** `lib/lain/stop_reason.rb`, `lib/lain/provider/anthropic_wire.rb`, `spec/lain/stop_reason_spec.rb`, `spec/lain/provider/anthropic_wire_spec.rb`
**Reuse:** `StopReason::CONTEXT_FULL`, the ollama side's window cut (`provider/ollama/decoding.rb:288-300`)
**Shared-file wiring:** none
**Reachable from:** `Provider::Anthropic` -> `AnthropicWire` decoding of `stop_reason`

**Acceptance criteria**

```gherkin
Scenario: model_context_window_exceeded
  Given an Anthropic reply with stop_reason "model_context_window_exceeded"
  Then lain records stop_reason context_full and the chat says the window filled, never "raise --max-tokens"
```
Spec file: `spec/lain/provider/anthropic_wire_spec.rb`, `spec/lain/stop_reason_spec.rb`

**Stop and report if:**
- The stop reason enum in the vendored SDK does not expose the member (`stop_reason.rb:9` says it is beta-only); then
  match the raw string.

### T61: Decline a handoff the kept set alone cannot fit          [risk: high]

**Depends on:** T25
**Files:** `lib/lain/agent.rb`, `lib/lain/compaction/source.rb`, `lib/lain/compaction/source/held_cut.rb`, `lib/lain/middleware/request_budget.rb`, `spec/lain/compaction/source_spec.rb`, `spec/lain/compaction/source/held_cut_spec.rb`, `spec/lain/middleware/request_budget_spec.rb`
**Reuse:** `RequestBudget::Ask#fixed_tokens`'s proportional share (`middleware/request_budget.rb:~170`), the refusal's exact `prompt_tokens` and `window_tokens` (`WindowExceeded`), `HeldCut#handoff_ranges` and `#unanswered_round` (`held_cut.rb:290,300`)
**Shared-file wiring:** `ARCHITECTURE.md:417-431`: the fallback declines when what it must keep already overflows
**Reachable from:** `Agent#attempt` (`agent.rb:711`) -> `#retry_refused` (`:725`) -> `#room_after` -> `#handed_off` (`:746`) -> `Source#handoff` (`compaction/source.rb:601-611`)

**Acceptance criteria**

```gherkin
Scenario: the round 26 shape
  Given a 32,768-token window and an unanswered round of 113,614 bytes, refused at 86,685 prompt tokens
  When the agent retries the refusal
  Then no summarizer call is made, no handoff is committed, the history is kept
  And a compaction_decision record says the handoff was declined because the kept set is about 85,000 tokens
  And the ask ends with a refusal saying the newest tool round alone is about 85,000 tokens; read fewer files at once or use offset and limit

Scenario: a handoff that helps still runs
  Then source_spec "commits one handoff cut and answers that it made room" passes unchanged
```
Spec file: `spec/lain/compaction/source_spec.rb` (the "handoff" describe, `:2885-3400`), `spec/lain/middleware/request_budget_spec.rb`

**Stop and report if:**
- `source_spec.rb:3190` (a second refusal over a chain the first handoff covered) changes meaning.

### T92: Hold a tool round's results to a budget, in call order          [risk: high]

**Depends on:** T61, T66, T87
**Files:** `lib/lain/tool/round_budget.rb` (new), `spec/lain/tool/round_budget_spec.rb` (new), `lib/lain/telemetry/round_bounded.rb` (new), `lib/lain/agent.rb`, `lib/lain/agent/tool_runner.rb`, `lib/lain/tool.rb`, `lib/lain/tools/read_file.rb`, `lib/lain/tools/grep.rb`, `lib/lain/tools/glob.rb`, `lib/lain/tools/list_files.rb`, `lib/lain/tools/memory_read.rb`, `spec/lain/agent/tool_runner_spec.rb`, `spec/lain/agent_spec.rb`, `spec/lain/session_spec.rb`
**Reuse:** `ToolRunner#run`, `Answers#blocks` (call order, `agent/tool_runner.rb:60-120,208`), `Agent#built_tool_runner` (`agent.rb:521-526`), `Tool::Bounds.offer` for the wording, `Tool::Bounds::RESULT_BYTES`, `ReplyReserve` (T87), `Session#record_delivery`'s Withheld mark for an error result (`session.rb:227-233`), `Sink::Null` as the shape of the default
**Shared-file wiring:** `ARCHITECTURE.md`: a round's results are bounded as a whole; `tool/bounds.rb:188`'s comment changes in the card
**Reachable from:** `Agent.new(round_budget:)` -> `Agent#built_tool_runner` -> `Agent::ToolRunner#run`, once per round with the Agent's own window and last usage. Until T93 wires a policy, every Agent gets `RoundBudget::NONE`, which changes nothing

**Interface**

```ruby
module Lain::Tool
  class RoundBudget
    # A policy the Agent holds; it builds one budget per round, because the room depends on the last turn.
    NONE = ...   # delivers everything, journals nothing
    def self.window   # bytes = (window - last_input - last_output - reserve) * 1.31, the worst-case density in
                      # tool/bounds.rb:192 on purpose: a bound errs toward withholding
    def self.static   # 2 * RESULT_BYTES whatever the window
    def for(window:, usage:, reserve:) # => a budget for this round
  end
  # budget#call(blocks, calls) => blocks in call order. Identical result bytes (by digest) after the first
  # become "same result as call <id>"; a re-runnable result past the budget becomes is_error.
end
# Tool#rerunnable? => false by default; true for read_file, grep, glob, list_files, memory_read
```

**Acceptance criteria**

```gherkin
Scenario: the round 26 shape under the window budget
  Given a 32,768-token window, a last turn of 7,492 input tokens and a 4,096 reserve
  And a round of 15 read_file calls over 5 files, each read 3 times
  When the round's results are assembled
  Then each file's first result is delivered while the budget lasts, in call order
  And each later result with identical bytes reads "same result as call <id>"
  And a result past the budget is is_error "not delivered: this round reached its <N>-byte budget (window 32768 tokens); re-request it in a later round, or narrower with offset and limit"
  And 1 round_bounded record names the basis, the budget, and the ids delivered, deduplicated and withheld

Scenario: a read, an edit, a read of the same file
  Given a round reading app.rb, editing it, and reading it again
  Then both reads are delivered whole, because their bytes differ

Scenario: a withheld read is not counted as read
  Given read_file of app.rb was withheld
  When the model then calls edit_file on app.rb
  Then edit_file refuses it as not read, as for any error result

Scenario: a subagent's result is never withheld
  Given a round holding a subagent call and reads past the budget
  Then the subagent's result is delivered and counts against the budget

Scenario: the order calls finish in does not matter
  Given the same round whose calls finish in 2 different orders
  Then the delivered set is the same
```
Spec file: `spec/lain/tool/round_budget_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`, `spec/lain/agent_spec.rb` (an `Agent` built with `round_budget: RoundBudget.window`, no double for the budget)

**Stop and report if:**
- Answering a duplicate as "same result as call <id>" breaks a provider's pairing rule (every `tool_use` still gets
  its own `tool_result`; only the text is short).
- The Agent does not hold the last turn's input and output tokens at the point it runs the tools.

### T93: Choose the round budget per chat, and record it          [risk: medium]

**Depends on:** T15, T22, T24, T58, T59, T89, T92
**Files:** `lib/lain/cli/arms.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/cli/arms_spec.rb`, `spec/lain/cli/wiring_spec.rb`, `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/session/loader_spec.rb`, `spec/lain/bench/variance_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/chronicle_spec.rb`, `spec/lain/cli/command/fork_spec.rb`, `spec/lain/cli/resume/mismatch_notices_spec.rb`, `spec/lain/cli/resume_spec.rb`, `spec/lain/session_record_spec.rb`, `spec/lain/telemetry/run_arms_spec.rb`
**Reuse:** `CLI::Arms` (`cli/arms.rb`: `SETS` weakest first, `from`, `from_header`, `to_header`, which writes every arm not `:off`, `:66-68`), `MismatchNotices` for a resume
**Shared-file wiring:** `exe/lain`: a `--round-budget off|static|window` chat flag beside `--confine`; `bench arms` (`exe/lain:907-911`) builds its Arms with `round_budget: "off"`, since bench agents come from `SpawnSeam`, not `Wiring#run`; `docs/commands.md`: the flag. The card applies the `exe/lain` diff in its own worktree for its runs and hands it back
**Reachable from:** `exe/lain` `chat` -> `CLI::Arms.from(options)` -> `CLI::Wiring#run` (`wiring.rb:264`) -> `#agent_over` (`:619-627`) -> `Agent.new(round_budget:)` (T92)

**Acceptance criteria**

```gherkin
Scenario: the default
  When lain chat starts with no flag
  Then the main agent's round budget is window, and the header records "round_budget": "window"

Scenario: off
  When lain chat --round-budget off starts
  Then no result is ever withheld, no round_bounded record is written, and the header records no round_budget

Scenario: a resume keeps the recorded budget
  Given a session recorded with static
  When it resumes with no flag
  Then the budget is static

Scenario: bench arms records what it runs
  When bench arms runs
  Then its run_arms record holds no round_budget, because its agents run with none
```
Spec file: `spec/lain/cli/arms_spec.rb`, `spec/lain/cli/wiring_spec.rb` (through `Wiring#run`, no double)

**Stop and report if:**
- `Arms.new` with every keyword spelled out (`chronicle_spec.rb:293`, `chat_launch_spec.rb:1288`) is also used in `lib/`.
- `Bench::Variance#guard_arms!` refuses recordings that differ only in this arm in a way that breaks the shipped
  variance fixtures.

### T94: Stub the newest round's largest results to fit, as an opt-in arm          [risk: high]

**Depends on:** T61, T93
**Files:** `lib/lain/compaction/strategy/stub_round.rb` (new), `spec/lain/compaction/strategy/stub_round_spec.rb` (new), `lib/lain/compaction/tool_messages.rb`, `lib/lain/session.rb`, `lib/lain/cli/arms.rb`, `spec/lain/compaction/tool_messages_spec.rb`, `spec/lain/session_spec.rb`, `spec/lain/cli/arms_spec.rb`
**Reuse:** `Oracle::Handoff.gist` ("result for X, N bytes, starts: ..."), `Strategy::Elide` (the deterministic control), `Compaction::ToolMessages` (`tool_messages.rb:15-19`, which says block masking is a different seam: this card adds it), `Session#withhold_rounds` (`session.rb:213`) to mark stubbed reads
**Shared-file wiring:** `exe/lain`: `--round-stub off|on` (default off, so `Arms#to_header` writes it only when on); `ARCHITECTURE.md`: the block-level seam. The card applies the `exe/lain` diff in its own worktree for its runs and hands it back
**Reachable from:** `Agent#retry_refused` after T61 declines a handoff, when the arm is on -> the stub strategy over the committed round

**Acceptance criteria**

```gherkin
Scenario: a committed round over the window, arm on
  Given --round-stub on and a committed unanswered round that alone overflows the window
  When the provider refuses the request
  Then the largest results in that round are replaced, each paired with its call, by "result for read_file(x), N bytes, starts: ...; withheld to fit; re-read with offset and limit"
  And no model call is made for it
  And each stubbed read is marked withheld, so edit_file refuses until it is re-read
  And the retried request fits

Scenario: arm off
  Given --round-stub off
  Then T61's refusal is the outcome
```
Spec file: `spec/lain/compaction/strategy/stub_round_spec.rb`, `spec/lain/session_spec.rb`

**Stop and report if:**
- Stubbing a block inside a committed turn changes that turn's digest in a way the Timeline cannot express as a
  derivation (compaction rewrites by cut, not in place); then the stub must ride on a cut, and the card says how.
- The prompt-cache prefix before the round changes.

## Integration checks

After the last card lands, on a quiet box (`pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` and
`pgrep -cf '[p]re-commit (hook-impl|run)'` both read 0):

- `bundle exec rake pspec`: check the example COUNT against the base SHA's run, not only failures.
- `bundle exec rubocop`; `bin/zeitwerk-census --check`; `bin/comment-census --check-tickets`; `bin/spec-census --check`
  (run the censuses at the base SHA first, so a pre-existing overage is not blamed on a card).
- `pre-commit run --all-files`.
- `bin/lint-gherkin-docs planning/specs/qa-round-26-fixes.md`.
- **Manual pass the user owes (round 27):** re-drive each closed finding by id. In particular:
  - b26-1: in a cockpit, type `half a thought` at an idle `you>` and at `command>` with an approval parked, press
    Ctrl-C; the line clears and the journal holds no `session_closed`. Repeat in `lain chat --no-nvim`.
  - l26-1: fork l's `records/run-esc.sh` against `records/escape.yml`; `parent/sentinel.rb` and the launch repo's
    `git status` are unchanged, and the arm's journal shows the refusal.
  - c26-3: fork c's rails-blog §2 ask that issued 15 reads; the round is bounded, a `round_bounded` record is written,
    and the ask completes or ends with T61's refusal, never a wasted handoff.
  - a26-3: an approved `printenv` with a planted token shows `<redacted:1>` in the chat pane and `lain://journal`.
  - h26-1: fork h's red-only issue; `lain epic land` refuses with "re-run the issue" and names no sha.
  - g26-2: `memory_write` of `DB_PASSWORD=hunter2pass` is refused; a store item planted with it reads masked.
  - m26-1: SIGKILL a drainer mid-verify, enqueue again; `ps` shows 1 verify group at a time.
  - `max_tokens`: a header on each arm records the ceiling and its source; a `/critique` on a 32k window no longer
    reports `RESERVE_OVER` for a diff that fits.

## Execution log

- 2026-10-19 start. Base `main` at `23ebc111` (QA round 26 documents committed first, per Preflight 2, on the
  user's answer). `git worktree list`: only `/home/tara/dev/lain 23ebc111 [main]`. `git status --porcelain lib spec`
  empty. Grounding still true: `6054ba1d..23ebc111` touches only `planning/`.
- Hook checks (`.pre-commit-config.yaml`), as commands an agent runs on its own paths: `bundle exec rubocop <paths>`;
  `bundle exec yard-lint <path>` per changed Ruby file; `bundle exec rspec <spec paths>`; `bin/lint-gherkin-docs
  <plan>` for plan docs; trailing whitespace and end-of-file on every file. The hook's `ruby-checks` runs
  `rake compile check`, which is the full `pspec` plus `rubocop`, so a commit is the full-suite run (about 60s to 90s).
  The suite cannot run beside other tests (shared `TMPDIR`); each worktree gets its own `TMPDIR` under `~/tmp/lain/`.
  A worktree has no `lib/lain/lain.so`; it is copied from the main checkout at cut. Paths needing user approval:
  none known.
