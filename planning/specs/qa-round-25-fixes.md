# QA round 25 fixes: containment that holds, a recovery that recovers, and calls that say why

status: draft
commit-mode: orchestrator-commits
language: ruby (1 card edits nvim Lua: T37)
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson)

## Intent

Fix every finding in [`planning/qa-findings-round25-2026-10-16.md`](../qa-findings-round25-2026-10-16.md) rated MEDIUM
or higher, and every LOW or LOW-MED finding that has a known fix in a file this plan already opens, by the user's
ask: 2 HIGH, 2 MED-HIGH, all 14 MEDIUM, and the LOW to LOW-MED items with a fix in reach. 2 older LOWs open for a
3rd round (A23-a1, B23-1) are in. The Coverage table maps every finding to its card, and names the 9 left for round 26.
Roadmap: `ROADMAP.md` item 61.

Round 25's defects cluster around 4 missing concepts, and most cards follow from them:

| Missing concept | Findings it closes | Cards |
|---|---|---|
| a run with no human is still held to its lease | l25-1, l25-3 | T1, T57 |
| a response-log frame says which wire wrote it | j25-1, j25-4, j25-6 | T4 to T7 |
| a parked or ruled call carries the reason it reached the human | k25-1, f25-4, e25-4, g25-5 | T20 to T22, T50 |
| a child's environment is chosen, and what it prints is masked | a25-4, a25-6 | T2, T3, T56 |

**Sequencing with the bash-confinement plan.** `planning/specs/bash-confinement.md` (item 59) is in progress in
another session, with T24 uncommitted in the main checkout and T25 and T27 to T32 open. Cards T1 to T49 and T60 touch
none of its open files. Cards T50 to T59 need a file it is still editing (`tools/bash.rb`, `cli/wiring.rb`,
`cli/wiring/toolset_build.rb`, `cli/arms.rb`, `approval/judged.rb`) and depend on the node **BC**, "bash-confinement
is `status: done`". 2 of round 25's findings are its own open cards, so this plan has none for them:

- **a25-1** (the `--confine reader`, `--judge-facts` and `--tripwire` arms change nothing) closes when its T25, T27
  and T30 land. Integration checks re-drive it.
- **e25-1** is fixed here by T23, which must land before its T31 turns `--confine classes` on by default. The main
  session tells the confinement session so.

## Coverage

| finding | card | finding | card | finding | card |
|---|---|---|---|---|---|
| l25-1 HIGH | T1 | j25-1 HIGH | T4, T5 | e25-1 MED-HIGH | T23 |
| b25-8 MED-HIGH | T16 | a25-4 | T2, T3, T56 | a25-1 | confinement T25, T27, T30 |
| a25-2 | T33, T52 | a25-3, e25-3 | T54 | e25-2 | T55 |
| e25-4 | T21 | c25-1 | T14 | h25-10, h25-9 | T37 |
| h25-1, h25-3 | T36 | d25-1 | T29 | j25-6 | T7 |
| k25-1, f25-4 | T50 | l25-2 | T34 | l25-3 | T57 |
| a25-5 / A23-a1 | T32 | a25-6 | T2 | a25-7, b25-2 | T19 |
| b25-1, k25-2 | T17 | b25-3, d25-4 | T35 | c25-5, d25-5 | T24, T51 |
| b25-4, EOF authority | T61 | b25-6 | T62 | b25-7 | T45 |
| b25-5, B23-1, `/stop` wording | T27 | b25-9 | T18 | | |
| c25-2 | T15 | c25-3, g25-1 | T48 | c25-4 | T8 |
| c25-7 | T11 | d25-2 | T9 | d25-3 | T28 |
| d25-6 | T59 | e25-5, h25-2 | T41 | e25-6 | T31 |
| e25-7 | T49 | f25-1, f25-2, g25-4 | T25 | f25-3 | T26 |
| f25-7 | T30, T51 | g25-2 | T46 | g25-3 | T47 |
| g25-5 | T22 | h25-4 | T51 | h25-5, h25-6 | T38 |
| h25-7 | T39 | h25-8, "(1 issues)" | T40 | i25-1 | T42 |
| i25-2 | T43 | i25-4 | T44 | i25-5 | T58 |
| j25-2 | T53 | j25-3 | T13 | j25-4 | T6 |
| j25-5 | T10 | k25-3 | T12 | | |

**Left for round 26, with the reason:** i25-3 (a design change, Rejected options); b25-10 (survey sidebar and refusals
name a file from different bases: no fix shape located); c25-6 (`friction` wording, no owner traced); f25-5 (`/mode !`
in a repo with no commits shows a raw git error: not traced); k25-4 (`x` in a closed fold); fork d's smaller items
(a `read_file` refusal joined to a sizing note, `questions_consumed` journaled twice after SIGHUP); `land` on a done
issue exits 1 (refusal site not found); inbox rows reading `0s`.

## Preflight

The executor checks this before cutting any worktree:

1. **The main checkout holds no other session's uncommitted `lib/` or `spec/` edits.** On 2026-10-17, while this plan
   was written, a 2nd session had about 94 files modified in the main checkout (small rewrites such as
   `client&.close` to `client.close`, and a `CONTENT_SHAPES` constant in `sensitivity/regions.rb`), among them
   `frontend/input_pane.rb`, `frontend/input_pane/draft.rb`, `sensitivity/regions.rb`, `sensitivity.rb`,
   `approval/judge.rb`, `approval/rule.rb`, `cli/up.rb`, `cli/epic_driver/issue_actor.rb`,
   `provider/response_wal/reader.rb`, `isolation/working_branch.rb` and `isolation/verifier/command.rb`. If
   `git status --porcelain lib spec` lists anything beyond the confinement plan's open card, ask the user whether to
   wait for that session to commit. Never stash or commit another session's edits.
2. **Base SHA.** Cut every card's worktree from `main` as it stands after step 1, and record that SHA in the Execution
   log. Line numbers in this plan are from `963d53b9`; an implementer re-reads each cited site before editing it.
3. **BC.** Read `planning/specs/bash-confinement.md`'s `status:` line. Cards depending on **BC** wait until it reads
   `done`. BC is a precondition, not a card.

## Grounding

2026-10-17, at `963d53b9` plus the uncommitted confinement T24 (`lib/lain/tools/bash.rb`,
`spec/lain/tools/bash_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`).

6 Explore passes read the production path behind every finding, and each cited file:line was re-checked against the
tree. Citations that moved since the findings were written: `Exec.child_env` is `exec.rb:106-109` (not 79-101);
`partial_arms_report` is `bench/cli.rb:412` (not 409); the compact-keep check is `Compaction.validate_keep_last`
(`compaction.rb:61`).

Probed rather than read:

- **An ollama frame reassembles with the code that exists.** Feeding a 2-line NDJSON frame to
  `Provider::Ollama::StreamAssembler#feed` and its `#result` into `Decoding#build_response(body, 4096)` returned a
  `Lain::Response` with `[thinking, text "hello world"]` and `:end_turn`, on an instance with no journal
  (`~/tmp/lain/probe-r25/reassemble.rb`). So T5 needs a journal-free decode, not a new parser.
- **Fork j's reproduction still fails on this tree**: `~/tmp/lain-qa-2026-10-16-j/records/salvage_ollama.rb` prints
  `recovered=true content=[]` (re-run in round 25's close-out).
- **The input pane defects reproduce in the spec harness** (Spike findings).
- **Every named reuse target exists**: `Escalation::Ruling` (`escalation.rb:89`, 9 members), `Landing.eventual`
  (`landing.rb:50`), `ResponseWal#open_frame(request_digest:)` (`response_wal.rb:174`), `CLI::Arms.from`
  (`arms.rb:25`), `Approval::Queue::Pending` (`queue.rb:130`), `RedactSecretReads::Rows::TRAILER`
  (`redact_secret_reads.rb:549`), `Draft#discard` (`input_pane/draft.rb:77`), `NonRoutable::RANGES`
  (`web_fetch.rb:132`), `ToolGuard.detached`/`held_in`/`child_stack` (`tool_guard.rb:341,260,247`),
  `EpicQueue::Advances` (`epic_queue.rb:298`), `Variance#guard_compaction!` (`variance.rb:153`),
  `RunClock#record_input` (`run_clock.rb:76`), `WorkingBranch::TRUNK` (`working_branch.rb:22`).

Files read: `lib/lain/cli/tool_guard.rb`, `lib/lain/bench/{cli,harness,spawn_seam,variance}.rb`,
`lib/lain/bench/session{,/loader}.rb`, `lib/lain/arm/driver.rb`, `lib/lain/exec{,/local,/core,/docker}.rb`,
`lib/lain/worker_env.rb`, `lib/lain/middleware/{redact_secret_reads,withhold_automatic_output,gate,remembered_denials,sensitivity,confine_to_scope}.rb`,
`lib/lain/session_record/salvage.rb`, `lib/lain/cli/resume{,/salvager,/mismatch_notices}.rb`,
`lib/lain/provider/{response_wal,ollama,anthropic,admission}.rb`, `lib/lain/provider/ollama/{stream_assembler,decoding,retry_tap}.rb`,
`lib/lain/provider/anthropic/retry_tap.rb`, `lib/lain/provider/spool/{null,rotating_frame}.rb`,
`lib/lain/cli/{chronicle,backend,chat_launch,pane_command,up,epic_queue,epic_submit,worktrees}.rb`,
`lib/lain/cli/backend/{ollama_tier,window_book,ceiling}.rb`, `lib/lain/cli/repl{,/ask,/approval_surfaces}.rb`,
`lib/lain/cli/conductor.rb`, `lib/lain/compaction{,/source,/source/held_cut}.rb`, `lib/lain/status_feed{,/fleet,/reading}.rb`,
`lib/lain/run_clock.rb`, `lib/lain/frontend/{input_pane,input_pane/draft,tty,approval_policy}.rb`,
`lib/lain/frontend/neovim/approval_view.rb`, `lib/lain/approval/{escalation,queue,judged,judge,composed_term,rule,rule_chain}.rb`,
`lib/lain/shell/{named,verdict,parse}.rb`, `lib/lain/shell/executable{,/resolver,/fresh}.rb`, `lib/lain/role{,/catalog}.rb`,
`lib/lain/prompt/slots.rb`, `lib/lain/agent{,/tool_runner}.rb`, `lib/lain/tool/cancellation.rb`,
`lib/lain/stop_reason.rb`, `lib/lain/response{,/failure}.rb`, `lib/lain/sensitivity{,/regions,/policy}.rb`,
`lib/lain/file_walk.rb`, `lib/lain/tools/{glob,list_files,web_fetch}.rb`, `lib/lain/tools/subagent/lineage.rb`,
`lib/lain/config{,/builder,/middleware}.rb`, `lib/lain/dsl_catalog.rb`, `lib/lain/cli/epic_driver/{factory,issue_actor}.rb`,
`lib/lain/epic/{submission,stage,advance}.rb`, `lib/lain/approval/gate/policy.rb`, `lib/lain/isolation/{gc,checkout,working_branch}.rb`,
`lib/lain/review/{session,submit/outbox}.rb`, `lib/lain/cli/command/review.rb`,
`lib/lain/frontend/neovim/runtime/{46_sidebar,47_diff,48_annotate}.lua`, `lib/lain/prompt/templates/skill/*/`,
`planning/qa/scenarios/{cockpit-surfaces,failure-injection,ollama-cloud-arm,prompt-slots-and-roles,secret-boundary,bench-arms}.md`,
`planning/specs/bash-confinement.md`.

Where docs and code disagreed:

- `cockpit-surfaces.md` §0 check 16 says Ctrl-C over a draft only discards it; `input_pane.rb:152-157` also forwards
  the interrupt. **The scenario wins** (user ruling, T16).
- `failure-injection.md` §1b says a severed reply fails the turn and strands the prompt; `ollama.rb:583-605` commits
  the fragment on purpose. **The code wins, with a mark** (user ruling, T9), and T60 corrects the scenario.
- `ToolGuard.detached`'s docstring (`tool_guard.rb:322-327`) says no detached run holds a gated tool; the bench's floor
  holds `bash`, `write_file` and `edit_file`. **The code is the fact**; T1 rewrites the doc.
- The comment above `Source#handoff` (`source.rb:514-518`) says a refusal with something droppable is told to
  compact; `stuck?` hands off anyway. **The comment wins** (T14).
- `ollama-cloud-arm.md` says retries are not journaled and `retry_tap.rb`'s docstring says it journals every retry.
  **The docstring wins** (T7).
- `Telemetry::ProviderRetry`'s docstring says a silent retry hides spend. It is never journaled. T7.
- `prompt-slots-and-roles.md` §5c calls a project `system.md` reaching the judge intended; round 24's T7 refused
  rewriting approval roles for the reason that applies here. **The refusal's reason wins** (T29).
- `Escalation::Bypass::TOLD` says a human must switch to `/mode ask`; `Gate::FINAL` wrapped around it says no approval
  will lift it. T26 drops the half the model cannot act on.

mempalace was unreachable this session (the MCP server failed to connect). Prior decisions come from the memory
files `approval-layering-direction.md`, `binary-identity-rulings-2026-10.md` and the new `qa-round-25-rulings.md`.

## Rulings

Asked 2026-10-17, answered by the user:

1. **b25-8:** Ctrl-C over a draft discards it and sends nothing; a Ctrl-C on an empty draft interrupts. (T16)
2. **d25-2:** a cut-off ollama reply stays on the chain, marked, and the model is told next turn. (T9)
3. **a25-4:** the child environment becomes an allowlist with an escape hatch, and `bash` output is masked on every
   call, human-approved included. This reverses the "human-approved output stays raw" ruling in
   `WithholdAutomaticOutput`. (T2, T3, T56)
4. **e25-1:** a `user`-class binary is trusted only when it shadows nothing on `PATH`. A planted non-shadowing name
   from an earlier session stays trusted; that gap is accepted. (T23)

Decided in planning, from the code:

- **d25-1:** an approval role's prompt is built without the project's slot fills, as round 24's T7 already refuses
  their role files. (T29)
- **h25-10:** a verdict refuses while any note is held, matching the existing blocker rule; it does not auto-flush
  notes the human may consider drafts. (T37)
- **i25-1:** the 2nd and later identical one-shot spawns get an adoption ordinal; the 1st keeps today's address, so
  cross-run reproducibility holds. This reverses the "accepted rather than fixed" ruling in `lineage.rb:40-50`. (T42)
- **e25-2:** under `--exec docker`, binaries are journalled unresolved with a reason. Resolving inside the container
  costs a 2nd `docker run` per call and cannot judge writability. Consequence: `ComposedTerm` abstains on docker calls
  under `--confine classes`. (T55)

## Compatibility

| Surface | Verdict | Evidence |
|---|---|---|
| The gem | not published | No release tag (`git tag` shows only `backup/main-pre-msg-rewrite-tag`); memory `harness-vs-own-dev.md` records no back-compat needed |
| Response-log (WAL) frame header | must keep old frames readable; new key additive | Crashed session files on disk are stored data. `ResponseWal::Reader` reads only `request_digest` from a header, so a frame without `wire` reads as `anthropic-sse`, today's only reassembly (T4) |
| Session header | additive; old headers readable | `arms` gains a reader (T52); a `middleware` section is added only when middleware is registered, the `arms_section` idiom, so an all-default header stays byte-identical (T53) |
| `escalation` journal record | free to break; additive | No lib reader; adds `note`, and `requester` on every record (T20, T24). `escalation_spec.rb:444-447` pins its absence and changes |
| `approval_pending` record | additive | Gains `notes` (T20) |
| `turn` record meta | additive | Gains `stop_reason` on a cut-off reply (T9) |
| `StopReason` enum | free to break | Internal; `stop_reason_spec.rb:40` and `agent_state_machine_spec.rb:94` sweep `ALL` and gain the new member (T8) |
| `grade_record` record | additive | Gains `arm`; old journals parse with it absent (T34) |
| `Escalation::Ruling`, `Queue::Pending` | free to break | Internal Data and class. New members are defaulted so the 10 spec files that call `Pending.new(` stay green |
| `Exec.child_env` result | free to break | Internal; `local_spec.rb:236-242` pins today's leak and inverts (T2) |
| CLI flags `--compact-keep/-bytes/-cap`, `--max-tokens`, `--num-ctx` | free to break | Stricter validation only (T32) |
| `.lain/config.rb` DSL | additive | New `env pass:` (T56) |
| Lua commands `:LainReviewVerdict` | free to break | Internal to the shipped runtime (T37) |
| Shipped skill templates | free to break | Copied into projects at use; no reader pins their text (T45) |
| `Tool::Cancellation` notices | free to break | Internal; adds one notice (T28) |

No trade report: no must-keep surface blocks a simplification.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| Does a resize with an idle draft print a 2nd header with no erase (b25-1)? | Yes, in the spec harness: `repainted` redraws with `@replaced` 0, so no `\e[1A\r\e[J` precedes it. Setting `@replaced` from the drawn header's row count before `redraw` fixes it; the 3 repaint examples stay green. True idle (`@idle`) takes the same path; no spec for it yet | spike worktree `spike/r25-pane`, `input_pane_spec.rb` 76 examples, 2 new failures before, green after; worktree removed |
| Does a sent draft line freeze the HUD (k25-2)? | Yes: 2 header publishes after `/stop\r` draw `""`. Setting `@below_echo = true` in `sent` after `forget_rows` draws `\r\e[Kfleet:2\n` then rewrites in place. 1 old example ("draws nothing over the rows once a line was sent") pins the freeze and must be rewritten | same |
| Can an ollama NDJSON frame be reassembled with existing code? | Yes, `StreamAssembler#feed`/`#result` then `Decoding#build_response` | `~/tmp/lain/probe-r25/reassemble.rb`, 2026-10-17 |

## Panel review

The Ruby panel returned APPROVE-WITH-FIXES and traced T1, T5 and T20 from `exe/lain` to their construction sites;
all 3 `Reachable from` lines held. What it changed:

- **T1** gained `LeasedPolicy`: `Gate#call` cannot tell a tier-gated call from a path-gated one, and `Unasked` would
  have refused in-lease work too. `bash` reads outside the lease and `NeverParking` are named out of scope.
- **T2**: Docker's crossing is `ChildEnv` filtered by `CROSSES`, so host paths still never cross into a container;
  `GIT_CONFIG_GLOBAL`/`NOSYSTEM` join KEEP (spec git depends on them); a grep-and-run step over the specs that spawn.
- **T12** depends on T2 and carries `LAIN_ENV_PASS`, closing a coupling neither card named.
- **T4** lists `provider/response_wal/reader.rb`, where `Entry` is built; **T5** defaults `reassembly:` and the wire,
  and lists `stranded_prompt_fold_spec.rb` and `chronicle_spec.rb`.
- **T60** waits on every card whose scenario it edits, and on **BC**.
- **T20** gained an escaping criterion: a planted path must not forge a prompt line.
- **Preflight** added: a 2nd session had about 94 files modified in the main checkout while this plan was written.
- **T3** gained a length floor and a fail-closed case for its literal backstop.
- **T24** split into T24 (requester) and T61 (abandoned call, EOF as fault); **T27** split into T27 and T62 (the nvim
  gesture). **T37** lists `annotate_spec.rb`; **T56** says a pass name is checked by shape only; **T9** covers a cut-off
  reply holding a `tool_use`; **T6** names where liveness is checked.

Not taken: an explicit lent marker on `WorkerEnv` (T2 infers "lent" as "differs from ENV"; nothing in `lib/` mutates
`ENV`, checked by grep), and stronger versions of the regression-only scenarios (kept as guards).

## Shared files

Only the main session edits these. Cards hand back 1-line diffs.

- `ROADMAP.md` (item 61 at planning; T60 hands back the "done" line)
- `.rubocop.yml`
- `spec/support/slow_files.rb`
- `planning/specs/bash-confinement.md` (no card edits it; the main session only reads its status for **BC**)

## Rejected options

- **Comment awareness in the region detector (c25-3):** a commented-out real secret (`# password: hunter2pass`) is
  still a leak, and is detected today. Reference awareness fixes the stock Rails line and keeps that one masked (T48).
- **Adopting `ssrf_filter` for `web_fetch` (e25-7):** its value is resolve-then-pin-the-IP, which replaces the
  transport; the finding is 8 missing table rows. `ipaddr` has no special-purpose registry. Rows added by hand (T49).
- **A shell-parser gem for the string arm (a25-3):** `Shell::Parse` already runs tree-sitter-bash through lain's own
  extension (`ext/lain/Cargo.toml:100`); `ruby_tree_sitter` duplicates it and `Shellwords` cannot see `&&` or pipes.
- **`Process.spawn(unsetenv_others: true)` for the env allowlist:** stdlib, but the env map also crosses the docker
  and lain-core wires, where a spawn option cannot go. One map for every backend (T2).
- **Comparing ctime against the session start for user binaries (e25-1, the finding's 2nd fix shape):** cannot catch
  a shim planted in an earlier session; the user ruled the shadowing rule only (T23).
- **Making a judge deny final:** `judged_spec.rb:93-96` pins it non-final, and final would tell the model "no approval
  will lift this", untrue while a human can switch mode (T50).
- **Stranding a cut-off reply (d25-2):** consistent only if every failure stop strands, a much larger change; ruled out
  by the user.
- **Showing a one-shot child's turns in a `--windows` pane (i25-3):** `LineageFilter` admits only messages by design;
  rendering `child_turn` is a feature, not a fix. No card.
- **Fixes not located or not worth a card:** `land` on a done issue exits 1 (refusal site not found), inbox rows read
  `0s`, k25-4 (`x` in a closed fold). Left for round 26.
- **A per-stage resolution for the judge from the string arm:** whether the judge sees string-arm stages is the
  confinement plan's T27 decision. T54 journals them only.
- **Resolving inside the docker container (e25-2):** a 2nd `docker run` per call, and writability cannot be judged from
  outside. Rejected for "unresolved, with a reason" (T55).

## Open decisions

1. **When BC lands.** Cards T50 to T59 wait on it. If the confinement plan stalls, the main session may ask the user
   to release individual post-BC cards whose files are no longer being edited there.

## Dependency graph

```mermaid
flowchart LR
  BC((bash-confinement done))
  T1 --> T3
  T2 --> T3
  T2 --> T44
  T2 --> T12
  T3 --> T24
  T3 --> T47
  T4 --> T5
  T5 --> T6
  T4 --> T7
  T5 --> T7
  T5 --> T8
  T8 --> T9
  T16 --> T17
  T17 --> T18
  T20 --> T21
  T23 --> T21
  T20 --> T22
  T21 --> T24
  T24 --> T61
  T20 --> T25
  T61 --> T26
  T61 --> T27
  T25 --> T27
  T1 --> T34
  BC --> T50
  T20 --> T50
  T50 --> T51
  T30 --> T51
  T24 --> T51
  BC --> T52
  T32 --> T52
  T52 --> T53
  T13 --> T53
  T5 --> T53
  BC --> T54
  T53 --> T55
  T31 --> T55
  BC --> T56
  T2 --> T56
  T41 --> T56
  T53 --> T56
  BC --> T57
  T34 --> T57
  T35 --> T57
  T55 --> T58
  BC --> T59
  BC --> T60
  T7 --> T60
  T9 --> T60
  T11 --> T60
  T14 --> T60
  T16 --> T60
  T21 --> T60
  T23 --> T60
  T27 --> T60
  T29 --> T60
  T30 --> T60
  T32 --> T60
  T36 --> T60
  T37 --> T60
  T38 --> T60
  T39 --> T60
  T40 --> T60
  T48 --> T60
  T57 --> T60
```

Cards with no incoming edge can start at once: T1, T2, T4, T10, T11, T13 to T16, T19, T20, T23, T28 to T33, T35 to T43, T45, T46, T48, T49, T62. **BC** is a precondition node, not a card (Preflight, step 3).

## Tasks

### T1: Hold a detached run to its lease, and refuse its reads outside it          [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/tool_guard.rb`, `lib/lain/bench/cli.rb`, `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/bench/harness_spec.rb`, `spec/lain/bench/cli_spec.rb`
**Reuse:** `ToolGuard.held_in` and `child_stack` (`tool_guard.rb:247-263`), `Middleware::ConfineToScope` with `wording: LEASE` and `Reach`; `Sensitivity::Policy::Null#confined(roots:)` and `Confined#gates?`; the `Unasked` rung (`tool_guard.rb:~175`) as the deny precedent
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench arms` to `Bench::CLI#arms_report` to `SpawnSeam` (`bench/spawn_seam.rb:99-150`) to `Harness::INSTRUMENTATION` (`bench/harness.rb:107-111`) to `ToolGuard.detached(journal:).call(worker_env)`, where `worker_env` comes from the worktree lease (`checkout:` set). Also `Consolidation#detached_guard`, `CLI::Improve#guard_stack`

**Acceptance criteria**

```gherkin
Scenario: an arm cannot write outside its worktree
  Given the guard stack Harness::INSTRUMENTATION builds for a worker_env leased at <tmp>/wt
  When the arm calls write_file with path <tmp>/outside.rb
  Then the call is refused with the lease wording naming <tmp>/wt, and <tmp>/outside.rb does not exist

Scenario: a bash cd out of the lease is refused
  When the arm runs bash "cd <tmp> && touch x"
  Then the call is refused naming the lease

Scenario: a read outside the lease is refused, not approved
  When the arm calls read_file /etc/hosts
  Then the call is refused with a sentence naming the lease and saying no human is attached, and nothing asks a human

Scenario: work inside the lease still runs unasked
  When the arm writes <tmp>/wt/lib/x.rb and runs bash "ls"
  Then both run with no approval asked

Scenario: a detached run with no lease is unchanged
  Given WorkerEnv.default (no checkout)
  Then the guard classes equal guards(board), as today

Scenario: the bench refusal no longer promises containment it lacks
  When bench arms runs writing tools without --isolation
  Then the refusal says what --isolation worktree confines (paths the tools name) and what it does not (opaque shell, until the sandbox applies)
```
Spec file: `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/bench/harness_spec.rb`, `spec/lain/bench/cli_spec.rb`

**Interface**

```ruby
module Lain::CLI::ToolGuard
  def self.held_for(worker_env, home:) = ... # [held_in(...)] when worker_env.checkout, else []

  # The gate policy for a leased detached run: approves what is gated only by its tool tier,
  # refuses what the lease's Sensitivity::Policy::Confined gates by path. Built by Detached#call
  # when worker_env.checkout is set; ApproveAll stays for a run with no lease.
  class LeasedPolicy
    def initialize(sensitivity:, lease:) = ...
    def call(effect, context) = ... # Ruling: allow, or deny with LEASED_READ naming the lease
  end
end
```

`Gate#call` cannot tell a tier-gated call from a path-gated one, so `LeasedPolicy` asks the same
`sensitivity.gates?(effect, cwd:, within:)` the gate asked. Its denial sentence names the lease and says the run has
no human to ask; it never reuses `Unasked::BECAUSE` ("spawned by an approval judge"), which is false for an arm.

**Not in scope, said in the refusal text (scenario 6):** a `bash` read outside the lease (`cat /etc/hosts`,
`cat ../x`). `ConfineToScope`'s `Reach` names only `cd` targets and written paths (`confine_to_scope.rb:63-66`), so an
opaque or reading shell stays open until the sandbox applies to bench arms (T57). `ToolGuard::NeverParking`, the judge's
read-only investigation children, is out of scope too: it holds no writing tool.

**Stop and report if:**
- `harness_spec.rb:66-77` (bench guard classes equal `detached`'s) can only pass by building the bench a guard list of its own: report before forking the two.
- `tool_guard_spec.rb:1061-1063` (a detached child's outside read runs) is the consolidate or improve path's real need: those runs read the project root, so check their worker_env has no checkout before changing the rung.

### T2: Pass a child only the environment it is meant to have          [risk: high]

**Depends on:** none
**Files:** `lib/lain/exec.rb`, `lib/lain/exec/child_env.rb` (new), `lib/lain/exec/docker.rb`, `lib/lain/sensitivity.rb` (the comment at line 808 naming the leak), `spec/lain/exec/child_env_spec.rb` (new), `spec/lain/exec/local_spec.rb`, `spec/lain/exec/core_spec.rb`, `spec/lain/exec/docker_spec.rb`, `spec/lain/grader/test_harness_spec.rb`
**Reuse:** `Exec::Docker::CROSSES` (`docker.rb:68`) and its doc on why an allowlist; the 4 existing scrub patterns (`exec.rb:68-95`)
**Shared-file wiring:** none
**Reachable from:** `Exec.child_env` is called by `Exec::Local#call` (`local.rb:71`), `Exec::Core#params` (`core.rb:99`), `Exec::Docker#crossing` (`docker.rb:204`), `Grader::TestHarness` (`test_harness.rb:97`) and `Isolation::Verifier::Command` (`verifier/command.rb:59`); `Exec.child_env` delegates to `Exec::ChildEnv::DEFAULT`

**Acceptance criteria**

```gherkin
Scenario: a secret in the process environment does not reach a child
  Given OLLAMA_API_KEY, SSH_AUTH_SOCK and GITHUB_TOKEN set in ENV
  When Exec::Local runs "env" under WorkerEnv.default
  Then none of the 3 names appears in the output

Scenario: the toolchain still works
  Given PATH, HOME, LANG, TERM, TMPDIR, LD_LIBRARY_PATH, GEM_HOME, MISE_* and CARGO_HOME in ENV
  Then each reaches the child with its value

Scenario: a variable the caller lent passes
  Given a WorkerEnv whose env adds DATABASE_URL (absent from ENV) or changes a value ENV holds
  Then the child sees the lent value

Scenario: a lent secret-shaped name still passes, because it was lent on purpose
  Given a WorkerEnv adding LAIN_LENT_TOKEN that ENV lacks
  Then the child sees it

Scenario: the human can name extra variables
  Given LAIN_ENV_PASS="RAILS_ENV,JAVA_HOME" and both set in ENV
  Then both reach the child, and a name in LAIN_ENV_PASS that matches the secret shape is refused at launch

Scenario: framework, loader and function scrubs still hold
  Then BUNDLE_GEMFILE, RUBYOPT, CDPATH, LD_PRELOAD, LD_AUDIT and BASH_FUNC_x%% are absent in the child, lent or not

Scenario: every backend decides the same environment
  Then Exec::Local and Exec::Core agree on the child env for one input
  And Docker's crossing is ChildEnv's output filtered by CROSSES, so no host path crosses into the container and a secret-shaped name crosses neither

Scenario: spec git keeps its isolated config
  Given GIT_CONFIG_GLOBAL and GIT_CONFIG_NOSYSTEM set in ENV, as spec/support/isolated_git_config.rb sets them
  Then both reach a child
```
Spec file: `spec/lain/exec/child_env_spec.rb`, `spec/lain/exec/local_spec.rb`, `spec/lain/exec/core_spec.rb`, `spec/lain/exec/docker_spec.rb`, `spec/lain/grader/test_harness_spec.rb`

**Interface**

```ruby
class Lain::Exec::ChildEnv
  # names the child always gets, from ENV
  KEEP = /\A(?:PATH|HOME|USER|LOGNAME|SHELL|PWD|TMPDIR|LANG|LC_[A-Z]+|TZ|TERM|COLORTERM|NO_COLOR|CI|GIT_CONFIG_(?:GLOBAL|NOSYSTEM)|
            LD_LIBRARY_PATH|GEM_[A-Z_]+|MISE_[A-Z_]+|CARGO_HOME|RUSTUP_HOME|XDG_[A-Z_]+|SSL_CERT_(?:FILE|DIR)|LAIN_[A-Z_]+)\z/x
  SECRET = /KEY|TOKEN|SECRET|PASSW|CREDENTIAL|AUTH_SOCK/  # dropped from ENV even if KEEP or PASS names it
  def initialize(pass: [], env: ENV) = ...
  # @param lent [Hash] WorkerEnv#env
  # @return [Hash] lent values for keys the caller added or changed, ENV values for kept names, nil for every other ENV name
  def call(lent) = ...
end
```

**Stop and report if:**
- `spec/lain/tools/bash_spec.rb` fails: it is the confinement session's open file. Its env examples (`LAIN_LENT`, the BUNDLE family) must stay green under this rule; report rather than edit it.
- The repo's own `bundle exec` inside a child (`grader/test_harness`) fails without a variable KEEP lacks: add it to KEEP with the reason in the commit, never widen SECRET's exceptions.
- `LAIN_` in KEEP would pass `LAIN_QA_*` or another suite variable a child should not get: name the exceptions.
- Before the first run, grep the specs that spawn through `Exec::Local`, `Exec::Core`, `Grader::TestHarness` or `Isolation::Verifier` (`grep -rln 'Exec::Local\|Exec::Core\|TestHarness\|Verifier::Command' spec`; about 58 files touch these) and run them; a variable one needs that is neither secret-shaped nor in KEEP is a stop, with its name.

### T3: Mask secrets in every bash result          [risk: high]

**Depends on:** T1, T2
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/middleware/withhold_automatic_output.rb` (its class doc's ruling), `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/middleware/withhold_automatic_output_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`
**Reuse:** `RedactSecretReads::Rows` (`:548-639`), `Sensitivity::Regions.detect`, `Sensitivity::Masking.render`, `Telemetry::SearchRedacted`'s shape; `Exec::ChildEnv::SECRET` (T2) for the literal backstop
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads` is in every guard stack `ToolGuard` builds (`tool_guard.rb` `layered`), main agent and children

**Acceptance criteria**

```gherkin
Scenario: a human-approved bash call's output is masked
  Given the production guard stack from ToolGuard, approval ask, a human approving bash "printenv"
  And the output holds ghp_ followed by 36 characters
  Then the tool result, the journal's tool_result and the display carry <redacted:1>, and a trailer says 1 region was masked
  And nothing parks asking to release it

Scenario: a session secret is masked even when no pattern matches it
  Given OLLAMA_API_KEY=abc123lowentropyvalue in the process ENV
  When a bash result contains abc123lowentropyvalue
  Then it is masked

Scenario: a short secret-named value is not a mask
  Given a secret-named variable whose value is shorter than 8 bytes, such as "1" or "true"
  Then bash results are not masked for it

Scenario: an unreadable environment fails closed
  Given reading the secret-named values raises
  Then the call's result is withheld with a reason, never returned raw

Scenario: clean output is untouched
  Then a bash result with no region is byte-identical and has no trailer

Scenario: the automatic-approval withhold still applies on top
  Given a call approved by a rule, not a human, whose output holds a region
  Then WithholdAutomaticOutput's behaviour is unchanged
```
Spec file: `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Stop and report if:**
- `tool_guard_spec.rb:1165-1196` pins human-approved bash output raw for a reason other than the old ruling (for example a test fixture that prints a secret on purpose).
- Masking needs the result shape of `Tools::Bash` to change: that file is the confinement session's.
- The live pane stream shows the raw value before the result: say so in the class doc; it is accepted, and not this card's to fix.

### T4: Name the wire on every response-log frame          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/response_wal.rb`, `lib/lain/provider/response_wal/reader.rb`, `lib/lain/provider/spool/null.rb`, `lib/lain/provider/spool/rotating_frame.rb`, `lib/lain/provider/ollama/retry_tap.rb`, `lib/lain/provider/anthropic/retry_tap.rb`, `lib/lain/provider/ollama.rb`, `lib/lain/provider/anthropic.rb`, `lib/lain/cli/chronicle.rb`, `spec/lain/provider/response_wal_spec.rb`, `spec/lain/provider/ollama/retry_tap_spec.rb`, `spec/lain/provider/anthropic/retry_tap_spec.rb`, `spec/lain/cli/chronicle_spec.rb`
**Reuse:** `ResponseWal#open_frame(request_digest:)` (`:174`), the frame header record (`:153-155`), `Reader::Entry`
**Shared-file wiring:** none
**Reachable from:** `CLI::Chronicle#spool` (`chronicle.rb:~123-131`) via `Wiring#spooled_provider` (`wiring.rb:758`) to `Backend#provider(spool:)` (`backend.rb:274-280`); each provider's retry tap opens the frame

**Acceptance criteria**

```gherkin
Scenario: an ollama frame says it is NDJSON
  Given a Provider::Ollama spooling through a real ResponseWal
  When it streams a reply
  Then the frame header holds "wire":"ollama-ndjson", and Reader's entry answers wire "ollama-ndjson"

Scenario: an anthropic frame says it is SSE
  Then an Anthropic frame's header holds "wire":"anthropic-sse"

Scenario: a non-streaming body says so
  Then a sync body's frame holds "wire":"ollama-json" or "anthropic-json"

Scenario: an old frame still reads
  Given a frame header with no wire key
  Then Reader's entry answers wire "anthropic-sse"
```
Spec file: `spec/lain/provider/response_wal_spec.rb`, `spec/lain/provider/ollama/retry_tap_spec.rb`, `spec/lain/provider/anthropic/retry_tap_spec.rb`, `spec/lain/cli/chronicle_spec.rb`

**Interface**

```ruby
class Lain::Provider::ResponseWal
  WIRES = %w[anthropic-sse anthropic-json ollama-ndjson ollama-json].freeze
  def open_frame(request_digest:, wire:) = ...
  Reader::Entry = Data.define(:request_digest, :bytes, :complete, :wire)
end
```

**Stop and report if:**
- A spool implementation outside `provider/spool/` and `chronicle.rb` receives `open_frame` (grep `open_frame` across `lib/`).
- `Entry` is built at 3 sites in `reader.rb` (around lines 79, 92, 107; the torn-tail one included) and the header is parsed into `Reader::Open` (line 44): `wire` needs a default at each, or the torn-tail entry breaks.

### T5: Reassemble a frame with the provider that wrote it, and refuse an empty one          [risk: high]

**Depends on:** T4
**Files:** `lib/lain/session_record/salvage.rb`, `lib/lain/provider/reassembly.rb` (new), `lib/lain/provider/ollama.rb`, `lib/lain/provider/ollama/decoding.rb`, `lib/lain/provider/anthropic.rb`, `lib/lain/cli/resume/salvager.rb`, `spec/lain/session_record/salvage_spec.rb`, `spec/lain/provider/reassembly_spec.rb` (new), `spec/lain/provider/ollama/decoding_spec.rb`, `spec/lain/seams/stranded_prompt_fold_spec.rb`, `spec/lain/cli/chronicle_spec.rb`
**Reuse:** `Ollama::StreamAssembler#feed`/`#result`, `Decoding#build_response(body, ceiling)` (probed, Grounding); the SSE path now inline in `Salvage#reassemble` (`salvage.rb:240-272`); the live path's silent-turn refusal (`decoding.rb:~140,219`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Resume#salvage` (`resume.rb:270-276`) builds `Salvager`, which builds `SessionRecord::Salvage.new(..., reassembly: Provider::Reassembly)`

**Acceptance criteria**

```gherkin
Scenario: a crashed ollama session is recovered whole
  Given a WAL frame written by Provider::Ollama holding thinking "hm" and text "hello world", complete
  And a request_sent with that digest and no turn after it
  When the session resumes
  Then the committed assistant turn holds the thinking block and the text "hello world", and the notice says recovered

Scenario: an ollama-cloud frame recovers the same way
  Given the frame from fork j's journal (records/salvage_ollama.rb's bytes)
  Then content is not empty

Scenario: a reassembly with no content is never called recovered
  Given a complete frame whose reassembly yields no content
  Then salvage commits nothing and returns Unreadable, whose notice says the response log held no answer and names the frame

Scenario: reassembly writes no journal record
  Then a prose tool call in a salvaged ollama frame is decoded without note_prose_tool_call writing anywhere

Scenario: the anthropic path is unchanged
  Then every existing salvage_spec example passes, the agreement example rewritten to call Provider::Reassembly
```
Spec file: `spec/lain/session_record/salvage_spec.rb`, `spec/lain/provider/reassembly_spec.rb`, `spec/lain/provider/ollama/decoding_spec.rb`

**Interface**

```ruby
module Lain::Provider::Reassembly
  # @return [Lain::Response]
  def self.call(entry, ceiling:) = ...  # dispatches on entry.wire; raises Unknown for a wire it lacks
end
# Salvage.new(entries:, frames:, timeline:, reassembly: Provider::Reassembly): the keyword defaults, and an
# entry that does not answer #wire reassembles as anthropic-sse, so stranded_prompt_fold_spec's bare
# Data.define(:request_digest, :bytes) frame and chronicle_spec's Salvage.new keep working.
```

**Stop and report if:**
- `Decoding#build_response` cannot run without the provider's `@journal` and the journal-free form needs `Provider::Ollama.new` with a live transport.
- The request's `max_tokens` (the `window_cut` ceiling) is absent from `request_sent`: report the field before inventing a default.

### T6: Close a crashed file that salvage could not recover          [risk: medium]

**Depends on:** T5
**Files:** `lib/lain/cli/resume/salvager.rb`, `lib/lain/cli/resume.rb`, `lib/lain/session_record/salvage.rb`, `spec/lain/cli/resume_spec.rb`
**Reuse:** `SessionClosed::REASONS`' `:salvaged` and its docstring; `Salvager#closing_records` (`salvager.rb:57-64`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Resume#salvage` (`resume.rb:270-276`)

**Acceptance criteria**

```gherkin
Scenario: an incomplete frame is reported once
  Given a crashed file whose WAL frame is incomplete and whose writer is dead
  When the session resumes twice
  Then the 1st resume prints the incomplete notice and appends session_closed reason salvaged with the head before
  And the 2nd resume prints neither the notice nor the open-file warning

Scenario: a live writer's file is never closed
  Given the file's writer is alive (the same liveness check open_notice uses, resume.rb:389-394, moved where salvage can call it)
  Then nothing is appended

Scenario: a fork never salvages
  Then resume_spec's fork example (around line 790) passes unchanged
```
Spec file: `spec/lain/cli/resume_spec.rb`

**Stop and report if:**
- `resume_spec.rb:585-600` (leaves the session open) pins an open file for a reason other than the old behaviour.

### T7: Journal every provider retry          [risk: low]

**Depends on:** T4, T5
**Files:** `lib/lain/provider/retry_narration.rb` (new), `lib/lain/provider/ollama/retry_tap.rb`, `lib/lain/provider/anthropic/retry_tap.rb`, `lib/lain/provider/anthropic.rb`, `spec/lain/provider/retry_narration_spec.rb` (new), `spec/lain/provider/ollama/retry_tap_spec.rb`, `spec/lain/provider/anthropic/retry_tap_spec.rb`
**Reuse:** the Ollama tap's `@journal` (`ollama.rb:238`); `Anthropic#initialize`'s `journal:`; `spec/journal_routing_discipline_spec.rb`'s rule
**Shared-file wiring:** none
**Reachable from:** `Backend#provider` passes `journal: run_journal` (`backend.rb:274-280`) to both providers, which pass it to their taps

**Acceptance criteria**

```gherkin
Scenario: an ollama retry reaches the record
  Given a Provider::Ollama whose transport fails once with 500, then succeeds
  Then the journal holds 1 provider_retry record and the display channel the same event

Scenario: an anthropic retry reaches the record
  Given a Provider::Anthropic whose transport returns 429 once
  Then the journal holds 1 provider_retry record

Scenario: an exhausted retry is journaled too
  Then the final failed attempt's provider_retry is journaled on both providers
```
Spec file: `spec/lain/provider/retry_narration_spec.rb`, `spec/lain/provider/ollama/retry_tap_spec.rb`, `spec/lain/provider/anthropic/retry_tap_spec.rb`

**Stop and report if:**
- `spec/journal_routing_discipline_spec.rb` objects to an event both journaled and on the display.

### T8: Say a reply filled the window, not that it hit max_tokens          [risk: medium]

**Depends on:** T5
**Files:** `lib/lain/stop_reason.rb`, `lib/lain/agent/loop_machine.rb`, `lib/lain/provider/ollama/decoding.rb`, `lib/lain/response.rb`, `lib/lain/response/failure.rb`, `lib/lain/cli/repl/ask.rb`, `spec/lain/stop_reason_spec.rb`, `spec/lain/agent_state_machine_spec.rb`, `spec/lain/provider/ollama/decoding_spec.rb`, `spec/lain/provider/ollama_spec.rb`, `spec/lain/response_spec.rb`, `spec/lain/cli/repl/ask_spec.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Decoding#window_cut?` (`decoding.rb:301`); `StopReason::TRUNCATED`'s event and failure entry as the pattern
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama#stream_body` to `Decoding#build_response`, read by `Agent` and by `CLI::Repl::Ask#settle`

**Acceptance criteria**

```gherkin
Scenario: a window cut is its own stop reason
  Given an ollama body with done_reason "length", a ceiling of 4096 and eval_count 1200
  Then the response's stop_reason is :context_full, and the turn_usage record says "context_full"

Scenario: the chat says what happened
  Then the error line reads that the reply filled the context window, with the window remedy, and never "model hit max_tokens"

Scenario: a spent ceiling is still max_tokens
  Given eval_count equals the ceiling
  Then stop_reason is :max_tokens and the message is unchanged

Scenario: every reader of a failure stop handles the new reason
  Then Arm::Driver and Subagent report :context_full by name
```
Spec file: `spec/lain/provider/ollama/decoding_spec.rb`, `spec/lain/cli/repl/ask_spec.rb`, `spec/lain/stop_reason_spec.rb`

**Stop and report if:**
- `Response#window_cut` has a reader other than `Ask#remedy_for` that cannot derive it from `stop_reason`.

### T9: Mark a cut-off reply, and tell the model next turn          [risk: medium]

**Depends on:** T8
**Files:** `lib/lain/agent.rb`, `spec/lain/agent_spec.rb`, `spec/lain/provider/ollama_streaming_spec.rb`
**Reuse:** `Agent#commit_and_account` (`agent.rb:566-578`); `Timeline#commit(meta:)`
**Shared-file wiring:** none
**Reachable from:** `Agent#transition` on a `:truncated` or `:context_full` response, in every agent the CLI builds

**Acceptance criteria**

```gherkin
Scenario: a severed reply is kept and marked
  Given an ollama stream with no done line, holding "partial answ"
  Then the committed assistant turn holds "partial answ", its turn record's meta holds stop_reason "truncated"
  And its content ends with a text block saying the reply was cut off before the model finished

Scenario: the next request tells the model
  When the human asks again
  Then the request's history holds that marker text after the fragment

Scenario: a complete reply has no marker
  Then an end_turn reply's content and meta are unchanged

Scenario: a cut-off reply holding a tool call is repaired, not replayed broken
  Given a severed stream that delivered a tool_use block before it ended
  Then the committed turn's tool_use gets a tool_result saying the reply was cut off and the call never ran, so the next request is well-formed
```
Spec file: `spec/lain/agent_spec.rb`, `spec/lain/provider/ollama_streaming_spec.rb`

**Stop and report if:**
- The marker block breaks a cache-stability spec (the content is part of the digest): report which.

### T10: Name the real lever when a cloud base is on loopback          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend/ollama_tier.rb`, `spec/lain/cli/backend/ollama_tier_spec.rb`
**Reuse:** `Provider::Admission.local?`, `Admission::ENV_KEY`
**Shared-file wiring:** none
**Reachable from:** `OllamaTier#startup_notices`, built by `Backend` for `--provider ollama-cloud`

**Acceptance criteria**

```gherkin
Scenario: a loopback cloud base says why its width is 1
  Given --provider ollama-cloud with base https://127.0.0.1:9443
  Then the notice says the base is a loopback address held to 1 request, and names LAIN_PROVIDER_CONCURRENCY, not LAIN_OLLAMA_CLOUD_CONCURRENCY

Scenario: plural
  Then a width of 1 reads "up to 1 cloud request at once"
```
Spec file: `spec/lain/cli/backend/ollama_tier_spec.rb`

**Stop and report if:**
- `admission_spec.rb:415-423` (a local endpoint ignores a declared width) must change: it must not.

### T11: Probe the window of a model chosen with /model          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/backend/window_book.rb`, `spec/lain/cli/backend/window_book_spec.rb`
**Reuse:** `WindowBook::Live`'s per-model `@vouched`; `REASK_LIMIT`; `WindowBook#lookup`
**Shared-file wiring:** none
**Reachable from:** `Backend#context_window` (`backend.rb:406`), read per turn by `Middleware::ResolveWindow`

**Acceptance criteria**

```gherkin
Scenario: a switched model gets its served window
  Given a session launched on qwen3-coder:30b whose probe served 32768
  When /model qwen3:4b and the probe for qwen3:4b serves 21432
  Then the window reads 21432 served, not 8192 guessed

Scenario: one probe per model
  Then a 2-turn run on one model still asks /api/ps once (recorded_run_spec)
```
Spec file: `spec/lain/cli/backend/window_book_spec.rb`

**Stop and report if:**
- `spec/lain/seams/recorded_run_spec.rb`'s single-`/api/ps` count changes.

### T12: Carry every operator variable into a cockpit pane          [risk: low]

**Depends on:** T2
**Files:** `lib/lain/cli/pane_command.rb`, `spec/lain/cli/pane_command_spec.rb`
**Reuse:** `RUNTIME_ENV` (`pane_command.rb:41`); the owners' constants for each name
**Shared-file wiring:** none
**Reachable from:** `CLI::Up` builds every pane through `PaneCommand.call`

**Acceptance criteria**

```gherkin
Scenario: the stall remedy reaches the chat pane
  Given LAIN_STREAM_STALL_TIMEOUT=600 in lain up's environment
  Then the chat pane's command exports it

Scenario: the human's pass list reaches the chat pane
  Given LAIN_ENV_PASS=RAILS_ENV in lain up's environment
  Then the chat pane's command exports it

Scenario: no operator variable is forgotten again
  Then a spec scanning lib/ and exe/ for LAIN_ literals finds each in PANE_ENV, RUNTIME_ENV or a named exclusion list (suite controls and LAIN_PREFLIGHT)
```
Spec file: `spec/lain/cli/pane_command_spec.rb`

**Stop and report if:**
- A scanned name is a secret: it goes on the exclusion list, never into the pane.

### T13: Refuse a middleware registration once, naming every missing method          [risk: low]

**Depends on:** none
**Files:** `lib/lain/config/middleware.rb`, `spec/lain/config/middleware_spec.rb`
**Reuse:** `Config::Middleware::Check.klass` (`middleware.rb:37-41`)
**Shared-file wiring:** none
**Reachable from:** `Config.middleware` (`config.rb:93`), read by `ChatLaunch#configured_middleware`

**Acceptance criteria**

```gherkin
Scenario: a turn class missing both methods
  Given an anonymous class registered for turn with neither #call nor #settle
  Then one refusal names "an anonymous class", #call and #settle, at the registration's line

Scenario: a Module passed where a Class goes
  Then the refusal says a middleware is a Class
```
Spec file: `spec/lain/config/middleware_spec.rb`

**Stop and report if:**
- none beyond the file's existing examples changing their substrings.

### T14: Hand off only when nothing past the held cut can be dropped          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compaction/source.rb`, `lib/lain/compaction/source/held_cut.rb`, `spec/lain/compaction/source_spec.rb`, `spec/lain/compaction/source/held_cut_spec.rb`
**Reuse:** `Reporting#droppable?` (already "droppable past the held cut that a rewrite would shrink", `source.rb:389,857`)
**Shared-file wiring:** none
**Reachable from:** `Agent#room_after` to `Compaction::Source#handoff` (`source.rb:528`)

**Acceptance criteria**

```gherkin
Scenario: a refusal after one cut, with turns droppable, compacts
  Given a session with 1 advance cut and 35 KB droppable past it
  When the provider refuses the render as over the window
  Then handoff returns false, and the next render advances the cut

Scenario: a refusal with nothing droppable still hands off
  Then the "handing off when no cut can make room" group (source_spec ~2861-3330) passes unchanged
```
Spec file: `spec/lain/compaction/source_spec.rb`, `spec/lain/compaction/source/held_cut_spec.rb`

**Stop and report if:**
- An example in the handoff group passes only because `holds_newest?` was true while something was droppable.
- A refusal loop appears: `Agent#room_after` must still allow one `:compaction` retry only.

### T15: Count a handoff as a compaction on the HUD          [risk: low]

**Depends on:** none
**Files:** `lib/lain/status_feed.rb`, `lib/lain/run_clock.rb`, `spec/lain/status_feed_spec.rb`, `spec/lain/run_clock_spec.rb`
**Reuse:** `Telemetry::CompactionCut` with `kind == "handoff"` (`held_cut.rb:49`)
**Shared-file wiring:** none
**Reachable from:** `StatusFeed#<<` and `RunClock#<<`, fed by the journal tee

**Acceptance criteria**

```gherkin
Scenario: a handoff counts
  Given a compaction_cut record of kind handoff reaching the feed
  Then compactions reads 1 and since_compaction resets

Scenario: an advance is not counted twice
  Given an advance's Compaction record and its compaction_cut
  Then compactions reads 1
```
Spec file: `spec/lain/status_feed_spec.rb`, `spec/lain/run_clock_spec.rb`

**Stop and report if:**
- Cuts do not reach the feed's tee in production (`Session#record_compaction_cut` writes `@journal << cut`; confirm the tee).

### T16: Discard a draft on Ctrl-C without interrupting the chat          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/input_pane.rb`, `lib/lain/frontend/input_pane/draft.rb`, `spec/lain/frontend/input_pane_spec.rb`
**Reuse:** `Draft#discard` (`draft.rb:77`)
**Shared-file wiring:** none
**Reachable from:** `lain input` (`exe/lain`) opens `InputPane`, whose signal handler calls `#signal`

**Acceptance criteria**

```gherkin
Scenario: Ctrl-C over a draft only clears it
  Given a draft "qq" in the input pane
  When Ctrl-C
  Then the draft is empty and no signal frame reaches the chat

Scenario: Ctrl-C on an empty draft interrupts
  When Ctrl-C again
  Then a signal frame named sigint reaches the chat

Scenario: no draft at all still goes to the chat
  Then input_pane_spec's "goes to the chat rather than interrupting the pane" passes unchanged
```
Spec file: `spec/lain/frontend/input_pane_spec.rb`

**Stop and report if:**
- A Ctrl-C mid-compose (C-g) reaches `#signal` through another path.

### T17: Retract the old header on a resize, and keep the HUD live after a sent line          [risk: medium]

**Depends on:** T16
**Files:** `lib/lain/frontend/input_pane.rb`, `spec/lain/frontend/input_pane_spec.rb`
**Reuse:** the spike's 2 one-line fixes (Spike findings): `@replaced` set in `repainted`, `@below_echo` set in `sent`; `retracted`'s `\e[nA\r\e[J`
**Shared-file wiring:** none
**Reachable from:** `InputPane#repainted` on a geometry tick and `#sent` on a typed line, in every `lain input` pane

**Acceptance criteria**

```gherkin
Scenario: a resize takes the old header back first
  Given a header drawn and an untouched draft
  When the window moves to 6 rows by 80
  Then the screen starts with "\e[1A\r\e[J" before the header is drawn again

Scenario: a resize at true idle does the same
  Given the pane idle (no prompt frame open) with a header drawn
  When the window moves
  Then no 2nd header stacks under the 1st

Scenario: the HUD stays live after a sent line
  Given /stop typed and sent while idle
  When 2 headers are published, fleet:2 then fleet:3
  Then the screen reads "\r\e[Kfleet:2\n\e7\e[1A\r\e[Kfleet:3\n\e8"

Scenario: the repaint guards hold
  Then one repaint per drag, more than 1 HUD print, and no repaint when still all pass
```
Spec file: `spec/lain/frontend/input_pane_spec.rb`

**Stop and report if:**
- The old example "draws nothing over the rows once a line was sent" pins a reason other than the frozen HUD: rewrite it to the new expectation only if not.

### T18: Clamp fleet rows at the pane's width          [risk: low]

**Depends on:** T17
**Files:** `lib/lain/frontend/input_pane.rb`, `lib/lain/status_feed/fleet.rb`, `lib/lain/status_feed/reading.rb`, `spec/lain/frontend/input_pane_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`, `spec/lain/status_feed/reading_spec.rb`
**Reuse:** `Fleet::Row.clamped`; `InputPane`'s `columns`
**Shared-file wiring:** none
**Reachable from:** `StatusFeed::Reading` publishes the header; `InputPane#headed` draws it

**Acceptance criteria**

```gherkin
Scenario: a wide pane shows a whole row
  Given a 120-column pane and a fleet row of 100 characters
  Then the row is drawn whole

Scenario: a narrow pane still clamps
  Given a 60-column pane
  Then the row is cut at 60

Scenario: nvim's status view is unchanged
  Then StatusView still clamps at 80
```
Spec file: `spec/lain/frontend/input_pane_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`, `spec/lain/status_feed/reading_spec.rb`

**Stop and report if:**
- `spec/refusal_width_discipline_spec.rb` reads `COLUMNS` as a bound on something other than the fleet row.

### T19: Echo a held line, and count a human> answer as input          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/repl.rb`, `lib/lain/cli/conductor.rb`, `spec/lain/cli/repl_spec.rb`, `spec/lain/cli/conductor_spec.rb`
**Reuse:** `Repl#read_line`'s `@tty.render_prompt_echo` under `@echo_input`; `RunClock#record_input`
**Shared-file wiring:** none
**Reachable from:** `Repl#next_text` (`repl.rb:183-188`) and `Conductor#read_reply` (`conductor.rb:236`)

**Acceptance criteria**

```gherkin
Scenario: a held prompt shows its you> line
  Given a line held while the model worked
  When it runs
  Then a you> echo of it is drawn before the reply

Scenario: an answer to a model's question resets idle
  Given ask_human waiting and the human answering at human>
  Then the HUD's idle restarts from that answer

Scenario: a [y/N] approval answer does not reset idle
  Then idle is unchanged by an approval answer
```
Spec file: `spec/lain/cli/repl_spec.rb`, `spec/lain/cli/conductor_spec.rb`

**Stop and report if:**
- `read_reply` serves approvals and questions through one call with no way to tell them apart.

### T20: Carry why a call reached the human to every approval surface          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/approval/queue.rb`, `lib/lain/telemetry/approval_pending.rb`, `lib/lain/frontend/approval_policy.rb`, `lib/lain/frontend/neovim/approval_view.rb`, `lib/lain/cli/repl/approval_surfaces.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/approval/queue_spec.rb`, `spec/lain/telemetry/approval_pending_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`
**Reuse:** `Judged::Deferred` (`judged.rb:112`) and `judge_deferred?` as the pattern (it stays, reading the notes); `Queue#admit` (`queue.rb:457`); `ApprovalPolicy::JUDGE_DEFERRED`
**Shared-file wiring:** none
**Reachable from:** `Escalation#rule` wraps the context it hands the bottom rung; `Queue#admit` reads it into `Pending`, built by `Switchboard` for every session

**Acceptance criteria**

```gherkin
Scenario: an abstaining rung's note reaches the prompt, the row and the record
  Given a ladder whose 2nd rung abstains with note "cat resolved to <root>/bin/cat (project)"
  When the call parks
  Then the TTY prompt, the lain://approval row, the chat arrival line and the approval_pending record each carry that note

Scenario: a call with no note is unchanged
  Then a park with no note renders as today, byte for byte

Scenario: the judge's defer still reads as before
  Then approval_policy_spec's and approval_view_spec's "the judge deferred this" examples pass

Scenario: a note never reaches the model
  Then the gate's refusal text to the model holds no note

Scenario: a planted path cannot forge a prompt line
  Given a note naming a path that holds "\e[2K" and a newline
  Then the TTY prompt, the lain://approval row and the chat arrival line each render it inspected, on one line
```
Spec file: `spec/lain/approval/escalation_spec.rb`, `spec/lain/approval/queue_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`

**Interface**

```ruby
Lain::Approval::Escalation::Ruling = Data.define(:verdict, :rung, :reason, :fault, :authority, :final, :told, :said, :rule, :note)
class Lain::Approval::Escalation::Noted < SimpleDelegator
  def parked_because = ... # Array<String>, the wrapped context's notes plus this one
end
class Lain::Approval::Queue::Pending
  def notes = ...          # Array<String>, frozen
end
```

**Stop and report if:**
- `queue_spec.rb:1127` (the exact `Pending#initialize` parameter list) is the only pin that changes; any other exact-shape pin is a signal the note is leaking somewhere it should not.
- `escalation_spec.rb:414`'s `Ruling#record` exact keys must gain `note` for every record: add it only when present.

### T21: Say which binary made a composed term park          [risk: medium]

**Depends on:** T20, T23
**Files:** `lib/lain/approval/rule.rb`, `lib/lain/approval/rule_chain.rb`, `lib/lain/approval/composed_term.rb`, `lib/lain/approval/escalation.rb`, `spec/lain/approval/composed_term_spec.rb`, `spec/lain/approval/rule_chain_spec.rb`, `spec/lain/approval/escalation_spec.rb`
**Reuse:** `ComposedTerm#vouched_names` and the resolved stages (`composed_term.rb:670-687`); `Escalation::Rules#ruling` (`escalation.rb:~416`)
**Shared-file wiring:** none
**Reachable from:** `Escalation::Rules` over the board's `RuleChain`, built by `BoardBuild` under `--confine classes|reader`

**Acceptance criteria**

```gherkin
Scenario: a project binary's park says why
  Given --confine classes, <root>/bin first on PATH, and cat planted there
  When the model runs "cat README.md" and it parks
  Then the prompt carries "cat resolved to <root>/bin/cat (project), shadowing /usr/bin/cat"

Scenario: a fresh binary says it is fresh
  Then a call to a file written this session carries "written this session"

Scenario: a rule that decides gives no note
  Then a ComposedTerm allow carries no note, and composed_term_spec's "leaves a project file to the judge" still expects decide to be nil
```
Spec file: `spec/lain/approval/composed_term_spec.rb`, `spec/lain/approval/rule_chain_spec.rb`, `spec/lain/approval/escalation_spec.rb`

**Interface**

```ruby
module Lain::Approval::Rule
  def why_not(call) = nil  # a rule that abstains may say why, for the human only
end
```

**Stop and report if:**
- `why_not` resolves the stages a 2nd time per call: memoise on `Rule::Call` instead.

### T22: Say which path rule gated a call          [risk: low]

**Depends on:** T20
**Files:** `lib/lain/middleware/gate.rb`, `spec/lain/middleware/gate_spec.rb`
**Reuse:** `Sensitivity::Verdict#explanation` (`sensitivity.rb:111`); `Sensitivity::Policy.path_in(effect)`; `Escalation::Noted` (T20)
**Shared-file wiring:** none
**Reachable from:** `Middleware::Gate#call`, in every guard stack

**Acceptance criteria**

```gherkin
Scenario: a credential-named read says so
  Given read_file .env.local, gated by the path policy
  When it parks
  Then the prompt and approval_pending carry "a credential-shaped name"

Scenario: an outside read says so
  Then read_file /opt/x parks with "outside the project"
```
Spec file: `spec/lain/middleware/gate_spec.rb`

**Stop and report if:**
- `Approval::PathGate#verdict_for` (`path_gate.rb:~55`) and the Gate can disagree on the explanation: they must use the same call.

### T23: Stop trusting a user binary that shadows another on PATH          [risk: high]

**Depends on:** none
**Files:** `lib/lain/approval/composed_term.rb`, `spec/lain/approval/composed_term_spec.rb`
**Reuse:** `Shell::Executable#shadowed` (the resolver lists later PATH hits, `resolver.rb:158-162`); `ComposedTerm#trusted_class?` (`composed_term.rb:679-687`)
**Shared-file wiring:** none
**Reachable from:** `BoardBuild` builds `ComposedTerm` over the T13 resolver under `--confine classes|reader`

**Acceptance criteria**

```gherkin
Scenario: a shim shadowing a system binary goes to the judge
  Given --confine classes and <tmp>/ubin/head ahead of /usr/bin/head on PATH, written before this session
  When the model runs "head -1 README.md"
  Then ComposedTerm abstains, and exec_resolution lists "shadowed":["/usr/bin/head"]

Scenario: a user binary that shadows nothing is still trusted
  Given <tmp>/ubin/rev, with no other rev on PATH
  Then ComposedTerm approves "rev README.md"

Scenario: a system binary is unchanged
  Then "cat README.md" resolving to /usr/bin/cat is approved
```
Spec file: `spec/lain/approval/composed_term_spec.rb`

**Stop and report if:**
- `composed_term_spec.rb:1210-1217` ("allows an unchanged user wrapper", which shadows `/usr/bin/cat`) is the only example that flips. Any other means a fixture relies on shadowing.
- The fix needs a new `Shell::Executable` member: that file is the confinement session's (T28).

### T24: Name the requester on every ladder record          [risk: medium]

**Depends on:** T3, T21
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/cli/tool_guard.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`
**Reuse:** `Queue::REQUESTER` (`queue.rb:40`); `Queue.requester_for`; `RememberedDenials#requester_of`
**Shared-file wiring:** none
**Reachable from:** `Switchboard` builds `Escalation`; `ToolGuard::NeverParking` builds the judge's investigation children

**Acceptance criteria**

```gherkin
Scenario: a main-agent escalation names its requester
  Given a main-agent call through the production ladder
  Then every escalation record carries "requester":"agent"

Scenario: the judge's own investigation calls name the judge
  Then a refused investigation call's record carries "requester":"auto_approver"
```
Spec file: `spec/lain/approval/escalation_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Stop and report if:**
- `escalation_spec.rb:444-447` ("leaves the requester off when the context names nobody") is not the only pin on absence.

### T61: Record an abandoned call, and sign an EOF answer as a fault          [risk: medium]

**Depends on:** T24
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/frontend/approval_policy.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`
**Reuse:** `Queue::ABANDONED_SURFACE`, `FAULT_SURFACE`; `Surfaces::AUTOMATIC` (`escalation.rb:774`), which gains `FAULT_SURFACE` (the queue already unions it separately, `queue.rb:322`)
**Shared-file wiring:** none
**Reachable from:** `Escalation#consult` (`escalation.rb:260`); `ApprovalPolicy#decide`, the plain-chat TTY surface

**Acceptance criteria**

```gherkin
Scenario: an abandoned call leaves a surfaces record
  Given a call parked at the human when its requester is stopped
  Then the journal holds an escalation record for the surfaces rung with verdict deny and authority automatic, and the stop still propagates

Scenario: EOF at the prompt is not a human's deny
  Given stdin at EOF while a call is asked
  Then the decision is signed with the fault surface, its authority is automatic, and the queue does not remember it as a human deny
```
Spec file: `spec/lain/approval/escalation_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`

**Stop and report if:**
- Recording on `Async::Stop` in `consult` needs more than an `ensure` that records and re-raises.
- `escalation_spec.rb:609-626` (surfaces and authority) pins `tty` authority for EOF for a reason other than the old behaviour.

### T25: Remember a human's deny by the file it lands on and by the exact call          [risk: high]

**Depends on:** T20
**Files:** `lib/lain/approval/queue.rb`, `lib/lain/middleware/remembered_denials.rb`, `spec/lain/approval/queue_spec.rb`, `spec/lain/middleware/remembered_denials_spec.rb`
**Reuse:** `Queue.resolved` (`queue.rb:386`), `Queue#denied`, `#named_files` (`:485-511`); `Landing.eventual` (`landing.rb:50`)
**Shared-file wiring:** none
**Reachable from:** `Switchboard` builds the queue; `RememberedDenials` is in every guard stack

**Acceptance criteria**

```gherkin
Scenario: a deny through a link holds for the target
  Given cfglink -> .env.local, and the human denied "cat cfglink"
  When the same requester calls read_file .env.local
  Then it is refused as remembered, naming the earlier deny

Scenario: a dangling link falls back to its spelling
  Then a deny of a dangling link is remembered by its lexical path only

Scenario: a protected bare name denied under bash is remembered
  Given the human denied bash "cat .env"
  When the same requester runs "head .env"
  Then it is refused as remembered

Scenario: an exact repeat of a denied call is refused
  Given the human denied bash "make deploy" (ordinary paths only)
  When the same requester sends "make deploy" again
  Then it is refused as remembered; "make test" still parks

Scenario: another requester is not affected
  Then a child's identical call parks as before
```
Spec file: `spec/lain/approval/queue_spec.rb`, `spec/lain/middleware/remembered_denials_spec.rb`

**Stop and report if:**
- `remembered_denials_spec.rb:155` (passes a path the session refuses outright, bash variant) is the only flip for the bare-name case.
- A spelling resolves into a different requester's lease.

### T26: Drop the half of the bypass refusal the model cannot act on          [risk: low]

**Depends on:** T61
**Files:** `lib/lain/approval/escalation.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`
**Reuse:** `Escalation::Bypass::TOLD` (`escalation.rb:722`); the human-facing advice already in `Bypass::REFUSED`
**Shared-file wiring:** none
**Reachable from:** `Switchboard` under `/mode bypass`

**Acceptance criteria**

```gherkin
Scenario: the refusal says one thing
  Given /mode bypass and a call the rules refuse
  Then the model's refusal says no approval is possible in this mode and not to re-send it, and holds no "switch to /mode ask"
  And the human's line still says how to switch
```
Spec file: `spec/lain/approval/escalation_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Stop and report if:**
- `switchboard_spec.rb` or `subagent_gate_spec.rb` assert the mode-switch half on the model's text.

### T27: Name the call, the time and the closer on approval lines          [risk: low]

**Depends on:** T61, T25
**Files:** `lib/lain/frontend/approval_policy.rb`, `lib/lain/cli/repl/approval_surfaces.rb`, `lib/lain/approval/queue.rb`, `lib/lain/frontend/neovim/approval_view.rb`, `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** `TTY#stamp` (`tty.rb:235`); `ApprovalPolicy::Asked`'s private `call`; `Pending#lapse` (`queue.rb:240`)
**Shared-file wiring:** none
**Reachable from:** `ApprovalPolicy` (plain chat), `Repl::ApprovalSurfaces::Arrivals` (cockpit chat pane), `Neovim::ApprovalView`

**Acceptance criteria**

```gherkin
Scenario: cockpit arrival and lapse lines carry the time
  Then an approval arrival and a lapse line in the chat pane start with HH:MM:SS

Scenario: a --no-nvim timeout names the call
  Then "denied after 60s with no answer" is led by the call it closed

Scenario: a stopped requester's call says so
  Then /stop over a parked call reads "closed: its requester was stopped", never "decided by abandoned"
```
Spec file: `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/frontend/tty_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`

**Stop and report if:**
- The lapse line is drawn by `TTY#close_prompt` in a way that needs `tty.rb` changed: report it; `tty.rb` is T62's.

### T62: Leave nvim out of a plain chat's question gesture          [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/tty.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** `TTY::Inbox::GESTURE` (`tty.rb:712`), `Inbox#document_for` (`:844-847`)
**Shared-file wiring:** none
**Reachable from:** `TTY#render_asked` (`tty.rb:357`) in a plain chat; `render_arrival` and the `/inbox` drain in a cockpit

**Acceptance criteria**

```gherkin
Scenario: a --no-nvim question does not mention nvim
  Given plain chat with no editor
  Then a model's question shows "type a reply" with no nvim clause

Scenario: a cockpit keeps both gestures
  Then the drain listing and the arrival render still name the nvim buffer
```
Spec file: `spec/lain/frontend/tty_spec.rb`

**Stop and report if:**
- GESTURE's other 7 spec readers (`repl_spec`, `input_pane_spec`, `inbox_view_spec`, `annotate_spec`, `rpc_thread_spec`, `review_spec`, `survey_subdirectory_spec`) read the plain-chat text rather than the constant; they must stay green.

### T28: Tell the model a call stopped while parked never ran          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent/tool_runner.rb`, `lib/lain/tool/cancellation.rb`, `lib/lain/telemetry/tool_cancelled.rb`, `spec/lain/agent/tool_runner_spec.rb`, `spec/lain/tool/cancellation_spec.rb`, `spec/lain/seams/tool_cancellation_spec.rb`, `spec/lain/telemetry/tool_cancelled_spec.rb`
**Reuse:** `ToolRunner::Answers#dispatching` (`tool_runner.rb:73`), `partition` (`:95`), `Tool::Cancellation::NOTICES`
**Shared-file wiring:** none
**Reachable from:** `Agent` builds `ToolRunner`; the gate tells the context a call passed it

**Acceptance criteria**

```gherkin
Scenario: a call stopped at approval is not running
  Given a call parked at the human when the run is stopped
  Then tool_cancelled lists it under never_ran, and the model's notice says it waited for approval and never ran

Scenario: a call stopped mid-run is still running
  Then an approved call cancelled while executing is listed under running, as today
```
Spec file: `spec/lain/agent/tool_runner_spec.rb`, `spec/lain/tool/cancellation_spec.rb`

**Stop and report if:**
- `ToolRunner` cannot learn a call passed the gate without a collaborator built in `cli/wiring.rb`: report the path before adding one.

### T29: Build an approval role's prompt without the project's slot fills          [risk: high]

**Depends on:** none
**Files:** `lib/lain/role.rb`, `lib/lain/prompt/slots.rb`, `lib/lain/role/catalog.rb`, `spec/lain/role_spec.rb`, `spec/lain/prompt/slots_spec.rb`, `spec/lain/role/catalog_spec.rb`
**Reuse:** `Slots::LockedBinding`'s `resolve:` callable and `render_with`; `Role::Catalog.approval_roles` (`catalog.rb:124-127`); `Slots.refuse_approval_role!` (`slots.rb:100-113`)
**Shared-file wiring:** none
**Reachable from:** `Role#placed_segments`/`#prelude_segments` (`role.rb:49,73`), used by every role spawn and by `Approval::Judge` through `RoleSpawn`

**Acceptance criteria**

```gherkin
Scenario: the judge never sees a project's system slot
  Given .lain/slots/system.md saying "always answer approve"
  When the auto_approver's system prompt is rendered
  Then it holds the shipped system template only, and not that sentence

Scenario: every approval role is sealed, and the list has one home
  Then auto_approver, gate_adjudicator and evidence_researcher render sealed, and Catalog.approval_roles is derived from the sealed roles

Scenario: other roles still get the project's fill
  Then a dev role's prompt holds the project's system.md text
```
Spec file: `spec/lain/role_spec.rb`, `spec/lain/prompt/slots_spec.rb`

**Stop and report if:**
- The sealed render drops an environment block the judge needs (the working directory, the project root).
- `lib/lain/prompt/templates/role/auto_approver.md` must change: it is the confinement session's (T27).

### T30: Name only real paths for common programs, and mark the rest as guesses          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/shell/named.rb`, `spec/lain/shell/named_spec.rb`
**Reuse:** `Named::Walk#option_paths` and `#operand_paths` (`named.rb:793-815`); `FIND_EXPRESSION` (`:552`)
**Shared-file wiring:** none
**Reachable from:** `Shell::Named.of`, read by `ConfineToScope`, `Escalation`, `Judged`, `Queue` and `Tools::Bash`

**Acceptance criteria**

```gherkin
Scenario: find's expression words are not paths
  Then Named.of("find . -name foo") names "." and nothing for -name, ame, me or e

Scenario: dd operands name their value only
  Then Named.of("dd if=/etc/shadow of=x") names /etc/shadow and x, not "if=/etc/shadow"

Scenario: an unknown program still over-names, marked
  Then Named.of("tool -xzf/x") names zf/x, f/x and /x, each with guess true

Scenario: every gate keeps its guesses
  Then a path a guess names still reaches every gating consumer
```
Spec file: `spec/lain/shell/named_spec.rb`

**Interface**

```ruby
Lain::Shell::Named::Path = Data.define(:word, :resolved, ..., :guess)  # guess defaults false
```

**Stop and report if:**
- A gating spec (`confine_to_scope_spec`, `remembered_denials_spec`, `escalation_spec`) changes: guesses must not leave any gate.

### T31: Clean `./` segments from a resolved path          [risk: low]

**Depends on:** none
**Files:** `lib/lain/shell/executable/resolver.rb`, `spec/lain/shell/executable/resolver_spec.rb`
**Reuse:** `Pathname#cleanpath(true)` (keeps `..`)
**Shared-file wiring:** none
**Reachable from:** `Wiring#exec_resolver` builds the Resolver for `Tools::Bash` and the ladder

**Acceptance criteria**

```gherkin
Scenario: a ./ program and a ./ PATH entry resolve clean
  Then "./bin/x" resolves to "<cwd>/bin/x", and PATH entry "./bin" gives "<cwd>/bin/x"

Scenario: .. is never folded
  Then resolver_spec's chain examples keeping ".." pass unchanged
```
Spec file: `spec/lain/shell/executable/resolver_spec.rb`

**Stop and report if:**
- The confinement session is editing `resolver.rb` (check its execution log before starting).

### T32: Refuse a fractional or non-positive compaction and ceiling flag          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb`, `lib/lain/cli/backend/ceiling.rb`, `lib/lain/compaction.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/backend_spec.rb`, `spec/lain/compaction_spec.rb`
**Reuse:** `Backend#refuse_compaction_flags!` and `#refuse_keep!` (`backend.rb:581-647`); `Backend::Ceiling`; `InvalidKeep`
**Shared-file wiring:** none
**Reachable from:** `ChatLaunch#call` (`chat_launch.rb:114`) calls `backend.refuse_compaction_flags!` before the journal opens

**Acceptance criteria**

```gherkin
Scenario: a bad compaction value is refused by name before launch
  When lain chat starts with --compact-keep 1.5, or --compact-bytes 0, or --compact-bytes -1, or --compact-cap 0
  Then each exits non-zero naming its flag, and no session file is written

Scenario: a fractional ceiling is refused
  When lain chat starts with --max-tokens 1.5 or --num-ctx 1.5
  Then each exits non-zero naming its flag

Scenario: a typed flag is checked even with --no-compact
  Then --no-compact --compact-bytes 0 is refused
```
Spec file: `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/backend_spec.rb`

**Stop and report if:**
- `Compaction.validate_keep_last`'s 3 callers (`Boundary`, `Context::Compact`, `Source`) pass a Float on purpose.

### T33: Refuse to compare runs under different bench arms          [risk: low]

**Depends on:** none
**Files:** `lib/lain/bench/variance.rb`, `lib/lain/bench/session.rb`, `lib/lain/bench/session/loader.rb`, `spec/lain/bench/variance_spec.rb`, `spec/lain/bench/session/loader_spec.rb`
**Reuse:** `Variance#guard_compaction!` (`variance.rb:153`) and its spec at `variance_spec.rb:252-262`
**Shared-file wiring:** none
**Reachable from:** `lain bench variance` builds `Bench::Variance` over `Session::Loader` recordings

**Acceptance criteria**

```gherkin
Scenario: unlike arms are refused
  Given one session with "arms":{"confine":"reader"} and one with no arms key
  Then bench variance exits non-zero saying the runs used different bench arms, naming both

Scenario: like arms compare
  Then 2 sessions with no arms key compare as today
```
Spec file: `spec/lain/bench/variance_spec.rb`

**Stop and report if:**
- `Recording` gains a required member: give `arms:` a `{}` default.

### T34: Keep a partial arm's surviving runs, and name the arm on its grades          [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/arm/driver.rb`, `lib/lain/telemetry/grade_record.rb`, `lib/lain/bench/cli.rb`, `spec/lain/arm/driver_spec.rb`, `spec/lain/telemetry/grade_record_spec.rb` (new), `spec/lain/bench/cli_spec.rb`
**Reuse:** `Driver#fold` (`driver.rb:~255-262`), `Failed#row`, `Measured`
**Shared-file wiring:** none
**Reachable from:** `Bench::CLI#arms_report` to `Arm::Driver`

**Acceptance criteria**

```gherkin
Scenario: one malformed task leaves the other 7 measured
  Given an arm whose task 2 ends malformed and tasks 1 and 3 to 8 pass
  Then its row reads 7 of 8 with the measured values, and a note "failed: malformed (task 2)"
  And its cost row says it covers 7 tasks

Scenario: an arm with every task failed reads as today
  Then driver_spec's all-failed example passes

Scenario: grades name their arm
  Then every grade_record carries "arm":"<arm name>", and partial_arms_report groups by it
```
Spec file: `spec/lain/arm/driver_spec.rb`, `spec/lain/bench/cli_spec.rb`

**Stop and report if:**
- The ranking compares a partial arm's mean with a complete arm's as if equal: show `n` and say so in the table, do not hide the arm.

### T35: Name the right tmux server in lain up's remedies, and adopt the input slot only for a chat that listens          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/up.rb`, `exe/lain`, `spec/lain/cli/up_spec.rb`
**Reuse:** `Tmux#argv` (`up.rb:265`); `Up.adopt_input` (`up.rb:1018`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `up` and `input`

**Acceptance criteria**

```gherkin
Scenario: the dead-pane remedy names the socket
  Given lain up -L qa
  Then the remedy reads "tmux -L qa kill-session -t lain"

Scenario: the default socket is unchanged
  Then up_spec's "tmux kill-session -t lain" example passes

Scenario: a bare lain input with no chat says so
  Given no chat listening on the derived socket
  Then lain input does not adopt the input slot, and says which socket it would wait on
```
Spec file: `spec/lain/cli/up_spec.rb`

**Stop and report if:**
- `lain up`'s own pane command relies on the bare `lain input` adopting the slot.

### T36: Check the stage boundary on every route that advances an epic          [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/epic_queue.rb`, `lib/lain/cli/epic_submit.rb`, `spec/lain/cli/epic_queue_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`
**Reuse:** `Approval::Gate::Policy::Boundary` (`gate/policy.rb:51-69`); `Epic::Stage#ensure_open!` (`epic/stage.rb:105-110`); `Epic::STAGES`
**Shared-file wiring:** none
**Reachable from:** `lain epic approve|deny` to `EpicQueue#drain` (`epic_queue.rb:128`); `lain epic submit` to `EpicSubmit#settled` (`epic_submit.rb:608`)

**Acceptance criteria**

```gherkin
Scenario: approving a later stage over a denied earlier one is refused
  Given research denied after epic_plan parked
  When lain epic approve <epic_plan digest>
  Then it exits non-zero naming the research stage, and journals no stage transition

Scenario: a digest parked in 2 partitions approves in stage order
  Given research and epic_plan parked under one digest
  Then approve moves research, then epic_plan

Scenario: an unattended submit meets the boundary first
  Given research not approved and no interactive stdin
  When lain epic submit epic_plan
  Then the refusal names the stage boundary, not stdin
```
Spec file: `spec/lain/cli/epic_queue_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`

**Stop and report if:**
- The fixtures that park a later stage alone (`epic_queue_spec.rb:83-100`, `:162-185`, `:336-350`, `:474-500`, `:687`; `epic_submit_spec.rb:566-603`) need more than earlier-stage approvals journaled.

### T37: Refuse to settle or replace a review while notes are held          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/46_sidebar.lua`, `lib/lain/frontend/neovim/runtime/48_annotate.lua`, `lib/lain/cli/command/review.rb`, `lib/lain/review/submit/outbox.rb`, `spec/lain/frontend/neovim/runtime/46_sidebar_spec.rb`, `spec/lain/frontend/neovim/annotate_spec.rb`, `spec/lain/cli/command/review_spec.rb`, `spec/refusal_delivery_discipline_spec.rb`
**Reuse:** `review_notes.first_blocker` (`48_annotate.lua:422`) and the verdict's blocker gate (`46_sidebar.lua:214-224`)
**Shared-file wiring:** none
**Reachable from:** `:LainReviewVerdict` in the review sidebar; `/review` through `Command::Review#wired`

**Acceptance criteria**

```gherkin
Scenario: a verdict with a held note is refused
  Given 3 notes placed and not handed back
  When :LainReviewVerdict approve
  Then it refuses "3 notes not handed back -- :LainNoteDone first", and the review stays open

Scenario: after hand-back the verdict goes through
  Then :LainNoteDone, then approve, journals 3 annotations and the verdict

Scenario: a 2nd /review with held notes is refused
  Then /review over an open round with held notes refuses with the same remedy, and journals nothing

Scenario: the outbox no longer over-claims
  Then the submit text says the verdict and the handed-back annotations are journaled
```
Spec file: `spec/lain/frontend/neovim/runtime/46_sidebar_spec.rb`, `spec/lain/cli/command/review_spec.rb`

**Stop and report if:**
- `46_sidebar_spec.rb:652-661` ("sends approve past a drawn note that is not a blocker") encodes a reason beyond the old rule.

### T38: Accept a red step only when its tests ran, failed, and nothing but tests was written          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/epic_driver/factory.rb`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`
**Reuse:** `IssueTests#failing`, `#carry` (`factory.rb:~1432,1466`); `Grader::TestHarness::Run#failed`/`#errors`; `Isolation::Checkout`
**Shared-file wiring:** none
**Reachable from:** `EpicDriver::Factory` builds `IssueTests` for the red step

**Acceptance criteria**

```gherkin
Scenario: tests that never load are not red
  Given a test file that raises on load (errors, no failed examples)
  Then the red step refuses, saying the tests did not load, with the error

Scenario: a red step that wrote the subject is refused
  Given the test_engineer also wrote lib/greet.rb
  Then the red step refuses, naming lib/greet.rb

Scenario: a real red still passes
  Then a run with 1 failed example and no stray file is accepted
```
Spec file: `spec/lain/cli/epic_driver/issue_tests_spec.rb`

**Stop and report if:**
- A fixture builds an errors-only run and expects it red.

### T39: Offer a retry only the branches that have not landed          [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/epic_driver/issue_actor.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`
**Reuse:** `Isolation::Checkout#ancestor?`; `Earlier#branches` (`issue_actor.rb:112-116`)
**Shared-file wiring:** none
**Reachable from:** `EpicDriver::IssueActor` on a retry

**Acceptance criteria**

```gherkin
Scenario: a landed branch is not offered
  Given 2 owned branches, one an ancestor of epic/<slug>
  Then the question lists only the other
```
Spec file: `spec/lain/cli/epic_driver/issue_actor_spec.rb`

**Stop and report if:**
- none.

### T40: Say why tests did not run, and count issues in the singular          [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/submission.rb`, `spec/lain/epic/submission_spec.rb`
**Reuse:** `Submission#tests_said` (`submission.rb:255-257`)
**Shared-file wiring:** none
**Reachable from:** `lain epic submit implementation`

**Acceptance criteria**

```gherkin
Scenario: no test run recorded
  Then the summary reads "tests: not run (no test run was recorded for this submission)"

Scenario: one issue
  Then a 1-issue graph reads "1 issue"
```
Spec file: `spec/lain/epic/submission_spec.rb`

**Stop and report if:**
- The fact string feeds a digest (it should not: `Contracts::Submission.check!` only).

### T41: Report a config error at the line that caused it          [risk: low]

**Depends on:** none
**Files:** `lib/lain/dsl_catalog.rb`, `lib/lain/config/builder.rb`, `spec/lain/dsl_catalog_spec.rb`, `spec/lain/config/builder_spec.rb`
**Reuse:** `Prism.parse` (gem `prism 1.9.0`, already locked); `Builder#located_at`; the `approval` verb's per-call validation (`builder.rb:126-129`)
**Shared-file wiring:** none
**Reachable from:** `Config::Builder.evaluate` and `DslCatalog.read`, on every `.lain/*.rb` load

**Acceptance criteria**

```gherkin
Scenario: an unclosed block names its opening line
  Given a config.rb whose line 1 opens "do" and never ends, 6 lines long
  Then the refusal's headline is config.rb:1

Scenario: an unknown gate policy names its own line
  Given epics do ... gate :research, :bogus on line 3
  Then the refusal names config.rb:3, not the epics line

Scenario: a message that does not parse falls back
  Then dsl_catalog_spec's raising-stub example passes
```
Spec file: `spec/lain/dsl_catalog_spec.rb`, `spec/lain/config/builder_spec.rb`

**Stop and report if:**
- The earliest Prism error is not the cause for some unbalanced input in the spec table.

### T42: Give identical one-shot twins their own address          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/tools/subagent/lineage.rb`, `spec/lain/tools/subagent/lineage_spec.rb`, `spec/lain/consolidation_spec.rb`
**Reuse:** `Lineage#adopted` and `recorded?` (`lineage.rb:~175-181`)
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent` builds `Lineage#spawn` for every spawn

**Acceptance criteria**

```gherkin
Scenario: 3 identical one-shots from one head are 3 lineages
  Given 3 sequential @dev[/qa] spawns with the same prompt from one head
  Then 3 distinct spawn digests, the 1st identical to today's address

Scenario: consolidate keeps them apart
  Then consolidate reports 3 runs
```
Spec file: `spec/lain/tools/subagent/lineage_spec.rb`, `spec/lain/consolidation_spec.rb`

**Stop and report if:**
- A replayed run gets different digests than its first recording (the adoption ordinal must come from the Store).

### T43: Find the trunk branch instead of assuming main          [risk: low]

**Depends on:** none
**Files:** `lib/lain/isolation/checkout.rb`, `lib/lain/cli/worktrees.rb`, `spec/lain/isolation/checkout_spec.rb`, `spec/lain/isolation/gc_spec.rb`
**Reuse:** `Isolation::Gc#initialize(trunk:)`; `WorkingBranch::TRUNK` as the last fallback
**Shared-file wiring:** none
**Reachable from:** `CLI::Worktrees#reaper` (`worktrees.rb:75-78`) builds `Gc`

**Acceptance criteria**

```gherkin
Scenario: a master repo is reaped against master
  Given a repo whose only trunk is master, and a worktree branch merged into it
  Then worktrees gc reaps it

Scenario: a probe that finds nothing never reaps
  Given no origin/HEAD, no init.defaultBranch and no main
  Then nothing is reaped, as today
```
Spec file: `spec/lain/isolation/checkout_spec.rb`, `spec/lain/isolation/gc_spec.rb`

**Stop and report if:**
- `Forge::LocalLanding` or `epic_finish` need the same probe to stay consistent: list them for a follow-up, do not widen.

### T44: Tell a child its real home in the account-database refusal          [risk: low]

**Depends on:** T2
**Files:** `lib/lain/sensitivity.rb`, `lib/lain/middleware/sensitivity.rb`, `spec/lain/sensitivity/policy_spec.rb`, `spec/lain/seams/child_read_scope_spec.rb`, `spec/lain/middleware/sensitivity_spec.rb`
**Reuse:** `Sensitivity::Policy#home`
**Shared-file wiring:** none
**Reachable from:** `Middleware::Sensitivity#refuse`, in every guard stack

**Acceptance criteria**

```gherkin
Scenario: the refusal names the real home
  Given a policy whose home is /home/u
  When a child reads /etc/passwd
  Then the refusal says the agent's home directory is /home/u, and holds no "$HOME"
```
Spec file: `spec/lain/middleware/sensitivity_spec.rb`, `spec/lain/sensitivity/policy_spec.rb`

**Stop and report if:**
- `Escalation`'s use of the same explanation (`escalation.rb:652,661`) renders it where no home is known.

### T45: Stop shipping lain's own paths in skill templates          [risk: low]

**Depends on:** none
**Files:** `lib/lain/prompt/templates/skill/create-plan/skill.md`, `lib/lain/prompt/templates/skill/create-plan/conventions.md`, `lib/lain/prompt/templates/skill/research-epic/conventions.md`, `lib/lain/prompt/templates/skill/plan-epic/conventions.md`, `lib/lain/prompt/templates/skill/create-epic-issues/conventions.md`, `lib/lain/prompt/templates/skill/iterate-epic/conventions.md`, `spec/lain/skill/shipped_skills_spec.rb`
**Reuse:** none
**Shared-file wiring:** none
**Reachable from:** `Skill::Catalog` ships these templates into a project

**Acceptance criteria**

```gherkin
Scenario: no shipped template cites the retired manifest or lain's plan path
  Then no file under prompt/templates/skill/ contains "require manifest" or "planning/specs/"
  And create-plan's template says to write the plan where the project's conventions name
```
Spec file: `spec/lain/skill/shipped_skills_spec.rb`

**Stop and report if:**
- none.

### T46: Count the symlinks a walk skipped          [risk: low]

**Depends on:** none
**Files:** `lib/lain/file_walk.rb`, `lib/lain/tools/glob.rb`, `lib/lain/tools/list_files.rb`, `spec/lain/file_walk_spec.rb`, `spec/lain/tools/glob_spec.rb`, `spec/lain/tools/list_files_spec.rb`
**Reuse:** `Tool::Bounds::WalkLimit#notice` and the trailer path through `BYTE_BOUND.fit(..., beside:)`
**Shared-file wiring:** none
**Reachable from:** `Tools::Glob` and `Tools::ListFiles`, in every toolset

**Acceptance criteria**

```gherkin
Scenario: glob says how many links it left out
  Given 2 symlinks under the root
  Then glob "**/*" ends with a trailer "2 symlinks skipped"

Scenario: no links, no trailer
  Then a walk with no symlinks has no such trailer
```
Spec file: `spec/lain/file_walk_spec.rb`, `spec/lain/tools/glob_spec.rb`, `spec/lain/tools/list_files_spec.rb`

**Stop and report if:**
- `WithholdSecretPaths` drops the trailer row.

### T47: Tell the model why a read came back masked          [risk: low]

**Depends on:** T3
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `Rows::TRAILER` (`redact_secret_reads.rb:549`); `#mask`'s 3 cases (declined, related, fresh deny)
**Shared-file wiring:** none
**Reachable from:** `RedactSecretReads#mask`, in every guard stack

**Acceptance criteria**

```gherkin
Scenario: a masked read says the file is readable and what was withheld
  Given a read_file whose 1 region the human declined to release
  Then the result ends with a trailer saying 1 region is masked as <redacted:1>, the file is inside the project, the release was declined, and to tell the user which file

Scenario: a timeout says it timed out
  Then a release that lapsed says so instead of "declined"
```
Spec file: `spec/lain/middleware/redact_secret_reads_spec.rb`

**Stop and report if:**
- Survey's `Projection` changes: the trailer belongs in `RedactSecretReads`, not `Masking`.

### T48: Leave a credential reference unmasked          [risk: medium]

**Depends on:** none
**Files:** `lib/lain/sensitivity/regions.rb`, `spec/lain/sensitivity/regions_spec.rb`
**Reuse:** `real_value?`, `PLACEHOLDER_VALUE`, `REFERENCE_CHECKED` (`regions.rb:139-142`)
**Shared-file wiring:** none
**Reachable from:** `Sensitivity::Regions.detect`, read by `RedactSecretReads` and the oracle

**Acceptance criteria**

```gherkin
Scenario: a reference is not a secret
  Then Regions.detect is empty for "password: ${DB_PASS}", "token = ENV.fetch(\"GITHUB_TOKEN\")", "password: ENV[\"X_PASS\"]" and the stock Rails line "#   password: Rails.application.credentials.dig(:smtp, :password),"

Scenario: a real value is still masked, commented or not
  Then "# password: hunter2pass" and "password: ${ghp_<36 chars>}" are each detected
```
Spec file: `spec/lain/sensitivity/regions_spec.rb`

**Stop and report if:**
- Any row of the accepted false-positive table (`regions_spec.rb:448-458`) flips.

### T49: Refuse the documentation and relay ranges in web_fetch          [risk: low]

**Depends on:** none
**Files:** `lib/lain/tools/web_fetch.rb`, `spec/lain/tools/web_fetch_spec.rb`
**Reuse:** `NonRoutable::RANGES` (`web_fetch.rb:132`)
**Shared-file wiring:** none
**Reachable from:** `Tools::WebFetch`, in the toolset

**Acceptance criteria**

```gherkin
Scenario: a documentation or relay address is refused before any connection
  When web_fetch is given http://192.0.2.1/, http://198.51.100.1/, http://203.0.113.1/, http://192.88.99.1/, http://[2001:db8::1]/, http://[ff02::1]/, http://[2001::1]/ or http://[100::1]/
  Then each is refused naming its range, and contacted is empty
```
Spec file: `spec/lain/tools/web_fetch_spec.rb`

**Stop and report if:**
- `spec/network_posture_spec.rb` routes through `NonRoutable`.

### T50: Show a judge's deny, and its unjudgeable abstain, to the human          [risk: medium]

**Depends on:** BC, T20
**Files:** `lib/lain/approval/judged.rb`, `lib/lain/telemetry/judge_approved.rb`, `lib/lain/frontend/decorators/judge_approved.rb`, `spec/lain/approval/judged_spec.rb`, `spec/lain/frontend/decorators/judge_approved_spec.rb`
**Reuse:** `Judged#approved`'s `show` (`judged.rb:165`); `Judged::Deferred`; `Escalation::Noted` (T20)
**Shared-file wiring:** none
**Reachable from:** `Switchboard#judged` builds `Approval::Judged` under `auto`

**Acceptance criteria**

```gherkin
Scenario: a judge deny shows a line and gives the model a reason
  Given auto, and the judge answering deny for "ls -la /home/u"
  Then the chat shows "the judge denied bash(ls -la /home/u)"
  And the model's refusal says the judge refused it and a human can still approve it

Scenario: an unjudgeable call says the judge did not look
  Given a call judgeable? refuses as opaque
  Then its parked row carries "the judge did not look: opaque"

Scenario: a deny stays non-final
  Then judged_spec's "applies a judge deny, not final" passes
```
Spec file: `spec/lain/approval/judged_spec.rb`

**Stop and report if:**
- `JudgeApproved` gaining a verdict member breaks `spec/journalable_surface_spec.rb`: add `JudgeDenied` instead.

### T51: Tell the judge a worktree child's own root, and name every requester          [risk: medium]

**Depends on:** T50, T30 (this plan), T24
**Files:** `lib/lain/approval/judged.rb`, `lib/lain/approval/judge.rb`, `spec/lain/approval/judged_spec.rb`, `spec/lain/approval/judge_spec.rb`
**Reuse:** `Judged#place_for` (`judged.rb:196-203`); `Sensitivity::Policy.base_of`; `Named::Path#guess` (T30); `Queue::REQUESTER`
**Shared-file wiring:** none
**Reachable from:** `Switchboard#judged`

**Acceptance criteria**

```gherkin
Scenario: a worktree child's call names its own root
  Given a dev child leased at <wt>
  Then the judge's prompt says project root <wt>, and names the human's checkout on its own line

Scenario: the judge's outside list holds no guesses
  Then "find . -name foo" lists no ame, me or e outside the root

Scenario: a main-agent judged record names its requester
  Then Judged's escalation record carries "requester":"agent"
```
Spec file: `spec/lain/approval/judged_spec.rb`, `spec/lain/approval/judge_spec.rb`

**Stop and report if:**
- `judged_spec.rb:229-236` pins the policy root for a reason other than the old behaviour.

### T52: Restore a resumed session's arms          [risk: medium]

**Depends on:** BC, T32
**Files:** `lib/lain/cli/arms.rb`, `lib/lain/cli/chat_launch.rb`, `lib/lain/cli/resume/mismatch_notices.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/cli/arms_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/resume/mismatch_notices_spec.rb` (new)
**Reuse:** `CompactionProfile`'s typed-over-recorded shape and `from_header`; `MismatchNotices#compaction_notices`
**Shared-file wiring:** none
**Reachable from:** `ChatLaunch#converse` passes `arms:` to the `Wiring` factory; `--resume` and `lain fork` share `ChatLaunch#recorded_header`

**Acceptance criteria**

```gherkin
Scenario: a resume keeps the recorded arms
  Given a session started with --confine reader
  When lain chat --resume <id> with no arm flags
  Then the new header records "confine":"reader", and the bash exec is the sandbox

Scenario: a typed flag wins and is noticed
  When --resume <id> --confine off
  Then confine is off and a mismatch notice names it
```
Spec file: `spec/lain/cli/arms_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/resume/mismatch_notices_spec.rb`

**Stop and report if:**
- `Arms.from` cannot tell "typed off" from "unset" without a nil-until-typed field: that is the expected change, not a stop; stop only if `exe/lain`'s flag defaults force a value.

### T53: Record trusted middleware's digest in the header          [risk: low]

**Depends on:** T52, T13, T5
**Files:** `lib/lain/config.rb`, `lib/lain/config/middleware.rb`, `lib/lain/session_record.rb`, `lib/lain/session_record/scribe.rb`, `lib/lain/cli/chronicle.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/session_record_spec.rb`, `spec/lain/config/middleware_spec.rb`, `spec/lain/cli/chronicle_spec.rb`
**Reuse:** `Project::Trust#digest` (`project/trust.rb:166-174`); `SessionRecord.header`'s `arms_section` idiom
**Shared-file wiring:** none
**Reachable from:** `Wiring` (`wiring.rb:352`) passes `middleware: backend.middleware.to_header` to `chronicle.start`

**Acceptance criteria**

```gherkin
Scenario: a session with trusted middleware records whose
  Given a trusted .lain/middleware.rb
  Then the header holds "middleware":{"project":"<trust digest>"}

Scenario: no middleware, no key
  Then a header with no registrations is byte-identical to today's
```
Spec file: `spec/lain/session_record_spec.rb`, `spec/lain/config/middleware_spec.rb`

**Stop and report if:**
- The digest must be recomputed outside `Project::Trust`.

### T54: Journal the stages of a command the verdict abstained on          [risk: high]

**Depends on:** BC
**Files:** `lib/lain/tools/bash.rb`, `lib/lain/shell/verdict.rb`, `spec/lain/tools/bash_spec.rb`, `spec/lain/shell/verdict_spec.rb`
**Reuse:** `Shell::Parse`'s stages; `Named::Walk`'s per-stage directory (`named.rb:624-711`); `RunFiles`; `Executable.unresolved`
**Shared-file wiring:** none
**Reachable from:** `Tools::Bash#perform` to `#resolve` (`bash.rb:348`), built by `BaseTools.build`

**Acceptance criteria**

```gherkin
Scenario: cd X && cargo run resolves cargo in X, for the record
  When the model runs "cd sub && cargo run"
  Then exec_resolution names cargo's absolute path with basis "parsed", cwd <root>/sub, and run_files naming sub/Cargo.toml

Scenario: an interpreter's run file reaches the journal
  When "ruby x.rb" runs
  Then exec_resolution holds ruby's path and run_files ["<root>/x.rb"]

Scenario: a parsed resolution never approves anything
  Then ComposedTerm's decision on "cd sub && cargo run" is unchanged, and the call still runs on the string arm

Scenario: builtins are not resolved
  Then cd and export stages are left out of the record
```
Spec file: `spec/lain/tools/bash_spec.rb`, `spec/lain/shell/verdict_spec.rb`

**Stop and report if:**
- `bash_spec.rb:1338-1348` (one unresolved entry for an abstained command) is not the only pair that flips.
- The judge facts (confinement T27) read `exec_resolution`: the `basis` field must keep them from treating a parsed stage as what ran.

### T55: Journal a docker call's binaries as unresolved, and say why          [risk: medium]

**Depends on:** T53, T31
**Files:** `lib/lain/shell/executable/resolver.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/shell/executable/resolver_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `Resolver::NULL` (`resolver.rb:347`); `Wiring#exec_resolver` (`wiring.rb:818-820`)
**Shared-file wiring:** none
**Reachable from:** `Wiring#exec_resolver` picks the resolver by `options[:exec]`

**Acceptance criteria**

```gherkin
Scenario: docker resolves nothing on the host
  Given --exec docker
  When the model runs "cat README.md"
  Then exec_resolution holds cat unresolved with anomaly container_backend, and no /usr/bin/cat

Scenario: the ladder abstains, as ruled
  Given --exec docker --confine classes
  Then ComposedTerm abstains on "cat README.md"
```
Spec file: `spec/lain/shell/executable/resolver_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Stop and report if:**
- `Shell::Executable`'s anomaly list is closed in a way that needs `executable.rb` changed beyond adding one member.

### T56: Let a project pass named variables to its children          [risk: medium]

**Depends on:** BC, T2, T41, T53
**Files:** `lib/lain/config/builder.rb`, `lib/lain/config.rb`, `lib/lain/exec/child_env.rb`, `lib/lain/exec/local.rb`, `lib/lain/exec/docker.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `spec/lain/config/builder_spec.rb`, `spec/lain/exec/child_env_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`
**Reuse:** `Exec::ChildEnv.new(pass:)` (T2); `ToolsetBuild`'s exec construction (`toolset_build.rb:202-209`)
**Shared-file wiring:** none
**Reachable from:** `ToolsetBuild` builds `Exec::Local`/`Exec::Docker` with `child_env: ChildEnv.new(pass: config.env_pass + LAIN_ENV_PASS)`

**Acceptance criteria**

```gherkin
Scenario: a project names its test variables
  Given .lain/config.rb with env pass: %w[DATABASE_URL RAILS_ENV]
  When bash runs "env"
  Then both reach the child

Scenario: a secret-shaped pass name is refused at load
  Given env pass: %w[AWS_SECRET_ACCESS_KEY]
  Then the config load refuses at that line, naming the shape

Scenario: the shape check is by name only, and the docs say so
  Then the env pass: docs say a name like DATABASE_URL can carry a credential in its value, and passing it is the project's decision
```
Spec file: `spec/lain/config/builder_spec.rb`, `spec/lain/exec/child_env_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`

**Stop and report if:**
- `Grader::TestHarness` or `Isolation::Verifier` need the project's pass list and have no config in reach: report rather than read config twice.

### T57: Give bench arms the confinement flags a chat has          [risk: medium]

**Depends on:** BC, T34, T35
**Files:** `exe/lain`, `lib/lain/bench/cli.rb`, `lib/lain/bench/harness.rb`, `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/harness_spec.rb`, `spec/lain/bench/arms_command_spec.rb`
**Reuse:** `CLI::Arms.from(options)`; `ExecFlags.declare`; the sandboxed exec `ToolsetBuild` builds (confinement T25)
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench arms` to `Bench::CLI#arms_report`, which builds `Harness::TOOLS` with the arms' exec

**Acceptance criteria**

```gherkin
Scenario: an arm run under --confine reader is sandboxed
  Given bench arms --isolation worktree --confine reader on a box with every layer
  Then each arm's bash exec is Exec::Sandboxed, and the run's header records the arm

Scenario: the refusal reflects real containment
  Then the bench refusal text says --confine reader contains opaque shell too
```
Spec file: `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/harness_spec.rb`

**Stop and report if:**
- `Harness::TOOLS` cannot take an exec without building through `ToolsetBuild`: report the seam.

### T58: Refuse an --isolation launch before the session directory exists          [risk: low]

**Depends on:** T55
**Files:** `lib/lain/cli/wiring.rb`, `lib/lain/cli/isolation_backend.rb`, `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/isolation_backend_spec.rb`
**Reuse:** `IsolationBackend::NotARepository`, `UnboundedSearch`
**Shared-file wiring:** none
**Reachable from:** `Wiring` resolves `IsolationBackend` (`wiring.rb:525-528`)

**Acceptance criteria**

```gherkin
Scenario: a refused --isolation leaves no directory
  Given --isolation worktree outside a git repository
  Then the launch refuses, and the project's session directory does not exist afterwards
```
Spec file: `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/isolation_backend_spec.rb`

**Stop and report if:**
- Splitting validation from construction needs the journal for a refusal record.

### T59: Tell the human when write records could not be read          [risk: low]

**Depends on:** BC
**Files:** `lib/lain/shell/executable/fresh.rb`, `lib/lain/cli/wiring/observers.rb`, `spec/lain/shell/executable/fresh_spec.rb`, `spec/lain/cli/wiring/observers_spec.rb`
**Reuse:** `Fresh.unknown`, `Fresh#degraded?`
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::Observers.register` builds `Fresh.for_lineage`

**Acceptance criteria**

```gherkin
Scenario: a torn file_written line is said once
  Given a resumed lineage with a torn file_written line
  Then one notice says write records could not be read and every path counts as fresh this session

Scenario: a clean lineage says nothing
  Then no notice
```
Spec file: `spec/lain/shell/executable/fresh_spec.rb`, `spec/lain/cli/wiring/observers_spec.rb`

**Stop and report if:**
- `fresh?`'s fail-closed answer would change: it must not.

### T60: Update the QA scenarios the fixes changed          [risk: low]

**Depends on:** BC, T7, T9, T11, T14, T16, T21, T23, T27, T29, T30, T32, T36, T37, T38, T39, T40, T48, T57
**Files:** `planning/qa/scenarios/cockpit-surfaces.md`, `planning/qa/scenarios/failure-injection.md`, `planning/qa/scenarios/ollama-cloud-arm.md`, `planning/qa/scenarios/prompt-slots-and-roles.md`, `planning/qa/scenarios/secret-boundary.md`, `planning/qa/scenarios/bench-arms.md`, `planning/qa/scenarios/session-and-window.md`, `planning/qa/scenarios/shell-term-approval.md`, `planning/qa/scenarios/epic-tier.md`, `planning/qa/scenarios/changeset-review.md`
**Reuse:** each card's acceptance criteria
**Shared-file wiring:** `ROADMAP.md` item 61 marked done
**Reachable from:** n/a (docs)

**Acceptance criteria**

```gherkin
Scenario: no scenario expects the old behaviour
  Then cockpit-surfaces §0 check 16 has no "FAILS as written" note
  And failure-injection §1b says a severed reply is committed, marked, and the model told
  And ollama-cloud-arm §6b counts provider_retry records in the journal
  And prompt-slots-and-roles §5c says a project's system.md never reaches an approval role
  And secret-boundary drops the g25-1 note and adds a bash-output masking check
  And bench-arms adds the launch repo's git status and a parent sentinel after each run
  And each scenario touched names round 26 as the re-check
```
Spec file: none (docs).

**Stop and report if:**
- A scenario section depends on a card that did not land: leave it and list it.
- Any scenario file is modified and uncommitted in the main checkout (round 25's own corrections, or confinement T32's `secret-boundary.md` and `bash-confinement.md`): it waits until those are committed.

## Integration checks

After the last card lands, on a quiet box (`pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` and
`pgrep -cf 'pre.commit (hook-impl|run)'` both read 0):

- `bundle exec rake pspec`: check the example COUNT against the last recorded run, not only failures.
- `bundle exec rubocop`; `bin/zeitwerk-census --check`; `bin/comment-census --check-tickets`; `bin/spec-census --check`
  (run the censuses at the base SHA first, so a pre-existing overage is not blamed on a card).
- `pre-commit run --all-files`.
- Re-run fork j's reproduction: `bundle exec ruby -Ilib ~/tmp/lain-qa-2026-10-16-j/records/salvage_ollama.rb` prints
  `recovered=true` with non-empty content.
- **Manual pass the user owes (round 26):** re-drive each closed finding by id. In particular:
  - l25-1: `bench arms --isolation worktree` from a scratch repo with a `.rb` in its parent; the parent file and the
    launch repo's `git status` are unchanged.
  - a25-4: an approved `printenv` in a chat with a planted `ghp_` token shows `<redacted:1>`, and `OLLAMA_API_KEY` is
    absent.
  - b25-8: Ctrl-C over a draft in a cockpit mid-ask; the cockpit survives.
  - a25-1 (confinement's cards): `--confine reader` runs bwrap; `--tripwire observe` writes a `tripwire` record.

## Execution log
