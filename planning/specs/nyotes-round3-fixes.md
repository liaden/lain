# nyotes round 3 fixes: one verdict, one bounds, durable run state, a phone

status: in-progress
commit-mode: orchestrator-commits
language: ruby, rust (T50 to T52 and T58 to T59)
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson); Rust cards add Raph Levien, Andrew Gallant, Frank McSherry, Ashley Williams

## Intent

Round 3 of the nyotes trial reached the first issue of `/implement-epic`. It then spent 48 human answers and about 1.8M input tokens on 1 logic-free skeleton. The cause is not 48 bugs. It is 8 root causes, each repeated across several layers. This plan replaces each repeated decision with 1 value and its algebra, and every layer reads that value:
- `Approval::Verdict` for every human answer, silence default and gate decision, parsed by 1 reply grammar. Ladder rungs keep answering `Escalation::Ruling`.
- `Sensitivity::Bounds`, 1 per agent.
- 1 journaled record of a stopped child.
- 1 run allowance.
- 1 digest-keyed signoff projection.
- 1 metered spawn path.
- 1 agenda of everything waiting on a human.

It cuts time and tokens. The judge becomes 1 tool-less request, and `ComposedTerm` admits more read-only shapes behind a replay gate. The epic reviewer gets a context pack and a round cap. Compaction follows the provider's cache profile.

It also lets the human answer from a phone (stream P, added by the user on 2026-11-03). A Tailscale-bound relay, an ntfy buzz and a sideloaded Dioxus app are fewer held calls than any hold policy.

Sources:
- `planning/nyotes-round3-sweep-research-2026-11.md` (the 8 classes).
- `planning/nyotes-implement-readiness-research-2026-11.md` (the branch and its leftovers).
- `planning/remote-surface-research-2026-08.md` (the phone).

ROADMAP item 74.

**Commit order.** Stream 0 (T1 to T5) lands first. Every other stream's root card depends on T1, per the user's ruling that the branch lands first.

## Grounding

**When and what.**
- Date: 2026-11-03. Base: `644ec6ae` on `main`.
- Branch `nyotes/implement-readiness` is at `e677e024` (worktree `/home/tara/w/ir`), 5 commits over main.
- 5 read-only sweep agents produced the research report. 6 more traced the production paths for this plan (judge, bounds, run state, control lines, epic, redaction and tokens). 1 opus agent reviewed the branch for durability. I re-read the sites the main claims rest on, listed under "Verified by me" below.

**Measured from the round 3 journals** (`~/.local/state/lain/sessions/9d832bf6a4ad/20261103T160611-1812006.ndjson`):
- 48 `awaiting_human` records.
- 88 tool calls refused with "this child cannot ask a human", all attributed by `child_progress` head to role `auto_approver`.
- 112 judge model calls.
- 0 cache reads on any call.

**Files checked, by stream:**
- Judge:
  - `lib/lain/approval/judge.rb:18,116-263`, `judged.rb:205,243-396`, `judge/facts.rb:96-110`, `ladder.rb:105-140`, `ladder/poisoning.rb:17-33`, `escalation.rb:262-278,428-478,835-864`, `composed_term.rb:386-530`, `remembered.rb:93-123`, `denial_breaker.rb`.
  - `lib/lain/shell/named.rb:7,37,178,680-1436`, `shell/verdict.rb:43-48,149`.
  - `lib/lain/cli/wiring.rb:926`, `cli/wiring/judge_source.rb`, `cli/switchboard.rb:421-561`, `cli/arms.rb:126`, `role/catalog.rb:47,124`, `prompt/templates/role/auto_approver.md`.
  - `lib/lain/bench/approval_replay.rb` and `approval_replay/`.
  - `lib/lain/oracle/model.rb:18,57`, `cli/backend/summarizer.rb:50-53` (the 1-completion pattern with `Provider::Journaled`).
- Bounds:
  - `lib/lain/sensitivity/roots.rb`, `sensitivity/policy.rb:141,233,375-379,501-505`, `cli/wiring/board_build.rb:95-112`.
  - `lib/lain/session.rb:670-680`, `middleware/confine_to_scope.rb`, `cli/tool_guard.rb:198-262,564-590`.
  - `lib/lain/confine/profiles.rb:55-133,210-298`, `confine/profile.rb:42-56,255-365,447-453`, `confine/mask_list.rb:79-84`, `confine/sandbox.rb:61`.
  - `lib/lain/shell/executable/resolver.rb`, `fresh.rb`, `worker_env.rb:51`, `isolation/leases.rb:120-210`, `crates/lain-fence/src/main.rs:106-129`.
- Run state:
  - `lib/lain/tools/subagent.rb:49-72,222,268-470,975-1376,1674-1991`, `tools/subagent/actor.rb`, `tools/subagent/lineage.rb:79,173,202-226`, `tools/subagent/progress.rb`.
  - `lib/lain/agent.rb:266,420,493,628-635,773-820`, `budget.rb`, `budget/ceilings.rb:12`, `middleware/skill_dispatch.rb:91-114`, `cli/epic_driver/issue_actor.rb:340-419`.
  - `lib/lain/provider/http/connection/middleware_stack.rb:129-185`, `provider/http/configuration.rb:111`, `provider/http/streaming.rb:94`, `agent/stop_reason.rb:83`.
  - The installed `faraday-2.14.1/lib/faraday/error.rb:188-194`.
  - `lib/lain/status_feed.rb:270,311,395,460-544`, `telemetry/child_progress.rb`, `event_log/kinds.rb`.
- Control lines:
  - `lib/lain/frontend/intake.rb:232,335-431`, `frontend/intake/disposition.rb`, `cli/command/registry.rb:61-93`, `cli/command/approve.rb:35-47`, `cli/wiring/intake_build.rb:46`, `cli/conductor.rb:175-186,298-305`.
  - `lib/lain/cli/epic_driver/factory.rb:60,514-530,749,876-900,1080-1235`, `supervisor.rb:82,440`.
  - `lib/lain/epic/submission.rb:139-185,435-460`, `frontend/approval_policy.rb:47-56,132-137`, `frontend/neovim/approval_view.rb:132,250,384,416`, `frontend/neovim/runtime/62_approval.lua:217-263`.
  - `lib/lain/epic/gate.rb:175-185,275-283,366,426,542,609-611`, `approval/parked/queue.rb:41,262,547-630,726-731`.
- Epic:
  - `lib/lain/epic/gate.rb:86,138-150,310,484,502`, `epic/signoff_queue.rb:321,331,388-413`, `epic/stage.rb:153-155`, `epic/gate/adjudicator.rb:85-141`, `cli/epic_submit.rb:940-955`, `forge/local_landing.rb:340-421`.
  - `lib/lain/tools/epic_review.rb:13-140`, `tools/epic_submit.rb:26`, `tools/epic_write.rb:70-81`, `epic/home/journaled.rb:125-147`, `review/review_verdict.rb:15`, `review/critique/documents.rb:87,140-160`, `cli/epic.rb:206-223,615-655`, `cli/epic_mount.rb:46,216,280,326`, `tools/ask_human.rb:829,844`.
- Redaction and tokens:
  - `lib/lain/middleware/redact_secret_reads.rb:66-125,272-315`, `sensitivity/ledger.rb:83-179`, `sensitivity/entropy.rb`, `sensitivity.rb:83,97-134,918-930,1056`, `sensitivity/masked.rb:25`.
  - `lib/lain/cache_profile.rb:81-87`, `compaction/cold.rb:46,100`, `compaction/scheduler.rb:149-153`, `compaction/need.rb:170`, `cli/compaction_profile.rb:24,103`, `cli/compaction_mount.rb:72`, `role/catalog.rb`, `usage.rb:31-37`, `budget/spent.rb:10`, `ledger.rb`.
- Algebra already present:
  - `Sensitivity::Roots#|`, pinned as a monoid and a meet semilattice in `spec/lain/sensitivity/roots_spec.rb:30-38`.
  - `Budget::Ceilings#meet`, with the laws in `spec/lain/budget/ceilings_spec.rb:28`.
  - `Approval::Ladder#+`, a first-decisive monoid with `Ladder[]` as identity.
  - `Sensitivity::Verdict#|`, a join on strictness.
  - `Usage#+`, `Budget::Spent#+` and `Sensitivity::Masked#+`. The law groups are in `spec/support/shared_examples/`: `monoid.rb`, `meet_semilattice.rb`, `elementwise.rb`, `incremental_fold.rb`, `monoid_homomorphism.rb` and `round_trip.rb`.

**Verified by me:**
- `Disposition.of` (`frontend/intake/disposition.rb:11-18`) and `Approve#perishable?` being the only one.
- `child_accounting` (`tools/subagent.rb:1983-1986`).
- `Gate#await` (`epic/gate.rb:609-611`).
- `Profile.workspace` building its reader with no `related:` (`confine/profile.rb:315-320`).
- The `--non-interactive` fail-open comment (`middleware/redact_secret_reads.rb:113-125`).
- The judge role's tools (`role/catalog.rb:47`).
- The CLI's Thor commands, which live in `exe/lain` (`watch` at line 1615).

**Where docs and code disagreed, and which won:**
- `planning/remote-surface-research-2026-08.md` named `AutoSurface`, `Lain::Notify`, `Approval::Risk` and `alters_outcome?` as hooks. All 4 are gone (`b24b2e62`, `c40ab419`, `46582847`). Code won: the phone answers at the asking rung (T55), and its `Codec` reuse needs a library split (T50), which the research missed.
- The research said Intake has 2 dispositions. `Disposition` has 4 kinds (`note`, `hold`, `refuse`, `run_now`), and only `Approve` reaches `run_now` during a run. Code won. The fix (T9) is unchanged.
- The research said about 30 config-read sites. There are 13 `Config.load(root:` sites, several of them injectable defaults. Code won. The config-pinning idea moved to Open decisions, since no harm from it was observed.
- The research said a judge approve is overruled after a paid call. That path (`Judge::Facts::Resolving`) runs only under the `judge_facts` arm, and the arm is off by default (`cli/arms.rb:126`). Code won. T19 still decides the bar before paying, because the arm is the studied variant.
- ROADMAP item 73 (round 2) shipped "one read-roots value per session". Round 3 shows a session-level value is not enough: a child, its parent and its judge each need their own. T13 to T17 extend it per agent.
- The branch's `test_layout.rb:37-40` comment says `manual` is reserved, but nothing refuses it in a layout. Code won. T4 adds the refusal.
- `CLAUDE.md`'s suite count (26,817) is stale: the suite is 32,417 examples (`nyotes-notes.md`, round 3, 09:14). The main session updates it at the end.

**Runtime premises, and how each was checked:**
- **Who makes the "cannot ask" refusals.** Probed from the journal: the `child_progress` records that name each refused turn as their head.
- **`Faraday::SSLError` is a sibling of `ConnectionFailed`.** Read in the installed gem source.
- **`ChildProgress` and `TurnUsage` carry no role or tokens.** Read.
- **Whether the 30 s judge clock runs during admission.** It is paused while the judge queues (`judge.rb:116-183`). Read.
- **A tool-less judge runs 1 provider call.** This is a design premise, and T18 makes it true with 1 request carrying the sealed role prompt, not `Oracle::Model` (see Rejected options).

**Rulings recorded on 2026-11-03, after a third review:**
- Postponed calls use the liftable deny (T9, design A): no grant, no new rung, and the breaker counts a postpone.
- Named build output is exempt from the tripwire's fresh_run_file signal (T14). Every other fresh exec still stops.
- The ntfy notification carries Open only (T56).
- The plan stays 1 plan.

## Algebra in this plan

Every new decision is a value with a law, pinned by an existing shared group. Laws over values built from `Roots` pass an extensional `equal:` and an `ancestor_of:`, as `spec/lain/sensitivity/roots_spec.rb:30-43` does, because `Roots` compares by identity.

| Value | Shape | Operation | Laws (shared group) | Card |
|---|---|---|---|---|
| `Approval::Verdict` | closed sum `Approve(note) \| Hold(note) \| Deny(note)`, note 1 String or nil | none: no card combines 2 verdicts | none; shareability and `coerce` are pinned | T6 |
| `Approval::Reply` | `parse(String) -> Verdict \| Unrecognised` | `parse(render(v)) == v` | `round_trip.rb` | T7 |
| `Approval::Silence` | a `Verdict` read from config | none (a constant) | none | T11 |
| `Sensitivity::Bounds` | product `reads`, `writes`, `children` (`Roots`) and `execs` (`ExecRules`), canonical at construction | `\|` componentwise; `lend` drops `children` | `monoid.rb`; `meet_semilattice.rb` with `meet: :\|`, `equal: ==`, `ancestor_of: <=`; the componentwise law stated directly | T13 |
| `Confine::ExecRules` | set of `(glob, root)` rules | `\|` set union | `monoid.rb` | T13 |
| `Approval::Judgement` | closed sum `Weighable(paths, facts) \| Unweighable(reason)`, `reason` from an enumerated set | none (matched exhaustively) | none | T19 |
| `Epic::Signoff` | journal projection to `{Partition => Standing(digest, verdict)}` | right-biased merge per partition (newest wins) | `incremental_fold.rb` with `combine`, a monoid homomorphism from the record list | T33 |
| run allowance | `Budget::Ceilings` held on the run | the newest grant replaces; only nesting meets (`Ceilings#meet`, existing laws) | `meet_semilattice.rb` (existing, for nesting) | T28 |
| `Journal::Projection::Usage` | `{(command, role) => Usage}` over `turn_usage` records that each name their command | pointwise `Usage#+` | `incremental_fold.rb`, `monoid_homomorphism.rb` | T31 |
| `Remote::Agenda` | a polled snapshot of items, a closed sum `ParkedCall \| GateQuestion \| Question` | `delta_since(cursor)`, cursor a generation counter | the replay law: applying the deltas since any cursor to that cursor's snapshot gives the current snapshot | T53 |
| `Usage`, `Budget::Spent`, `Sensitivity::Masked` | existing `+` | existing | `monoid.rb` (new pins) | T46 |

A case statement over verdict symbols or reason strings that one of these values replaces gets deleted, not wrapped.

## Compatibility

The user ruled on 2026-11-03: "We do not have to maintain backwards compatibility with prior sessions or within the code". The memory `old-sessions-disposable.md` (2026-10-28) records the same for journal bytes.

| Surface | Verdict | Evidence |
|---|---|---|
| Journal records: `GateDecision` (`approved` bool becomes `verdict`), `ChildProgress` (gains usage), `TurnUsage` (gains command and role), new `ChildStopped`, `QuestionAnswered`, `EpicReviewed`, `RunAllowance` | free to break | sessions are disposable (memory 2026-10-28, user ruling 2026-11-03); readers are in `lib/` only |
| `.lain/config.rb` keys: new `approval silence:`, `remote relay:`, `remote ntfy:`; `approval timeout:` unchanged | free to break (additive) | consumers: `~/dev/nyotes/.lain/config.rb` only |
| Model-facing tool schemas: `epic_submit.review` becomes a review id, `subagent.iterations` allowed on a spawn, new `epic_status`, `epic_show` | free to break | read by models only; skill prompts are in-repo |
| Slash commands: `/approve` answers in 1 entry when 1 call is pending; new `/deny`, `/clear`; `/stop`, `/held`, `/inbox` act during a run | free to break | human-facing; `docs/commands.md` (main session updates it) |
| nvim protocol: `62_approval.lua` gains `"hold <words>"` and approve with a note | free to break | the runtime ships in-repo; `spec/plugin/nvim_plugin_spec.rb` scans it |
| lain-core's RPC: a frame ceiling, a handler seam, an auth deadline, a relay subcommand | free to break | `lain-core` has no production caller (`ARCHITECTURE.md:2329`); its only client is `spec/support/core_daemon.rb`; `ping` keeps reporting lain-core's version |
| The phone wire (`crates/lain-wire`, `WIRE_VERSION = 1`) | new; versioned from the start | the relay answers a version mismatch with an error and keeps serving v1, because a sideloaded APK is not rebuilt when lain is (research §9, question 5) |
| The `lain` gem | free to break | no `Gemfile` under `~/dev` outside lain names it (grep, 2026-11-03), no release tags; memory `harness-vs-own-dev.md` |
| `Approval::Remembered` config allow/deny rules | must keep | the user's own approval rules; nothing in this plan replaces them |

No trade report was needed. Nothing must-keep blocks a simplification.

## Spike findings

| Question | Result | Evidence |
|---|---|---|
| Who made the 88 "cannot ask a human" refusals? | the judge's child (role `auto_approver`), all 88 | `child_progress` records whose `head` is each refused turn, `20261103T160611-1812006.ndjson` |
| Is `Faraday::SSLError` retried by the Faraday stack? | no: a sibling of `ConnectionFailed`, absent from `retry_exceptions` | `faraday-2.14.1/lib/faraday/error.rb:188-194`; `middleware_stack.rb:172-177` |
| Are the branch's 5 commits durable? | none needs a redo; 2 land as is, 3 need small fixes (T2 to T5) | the opus branch review, summarized in T1 to T5 |
| Can an actor's spawn record be written before its Agent? | yes: the spawn body depends on the policy, the parent head and the prompt digest, not the Agent | `tools/subagent/lineage.rb:79,173`; `actor.rb#launch` |
| Do the panel's law objections hold? | yes: a left-wins note join fails left identity and 10 commutativity pairs; `Roots` joins do not commute under `==` | the panel's probes `verdict_join_probe.rb`, `roots_equality_probe.rb` in the session scratchpad |
| Would an approval memory pay? | no: 96 judge-rung calls held 95 distinct keys, and 50 parks held 50 | the panel's `memory_repeat_probe.rb` over the round 3 journal |
| Can this box build the Android app? | no: `dx`, `adb`, `cargo-ndk` and an Android SDK are absent; `tailscale` is present | `which`, 2026-11-03; `~/dev/belle-curves/CLAUDE.md:9-10` shows the build commands |
| Can a Dioxus app join this workspace? | no: belle-curves' lock pulls `nu-ansi-term` 0.50.3, which `deny.toml` bans | `~/dev/belle-curves/Cargo.lock:2851`; `deny.toml` `[bans]` |

No code spike ran beyond the panel's probes. The APK build is a manual pass for the user.

## Shared files

Only the main session edits these. Cards hand back a 1-line diff.

- `CLAUDE.md`: the suite count; the GIT_DIR trap line already lands with T1.
- `ROADMAP.md`: item 74.
- `ARCHITECTURE.md`: the approval, bounds and remote-surface sections.
- `docs/commands.md`: `/implement-epic [SLUG]` (line 1187), `/deny`, `/clear`, `/approve`, `/stop`, `approval silence:`, `remote relay:`, `remote ntfy:`.
- `exe/lain`: the `usage` Thor command from T31.
- Root `Cargo.toml`: the `lain-wire` member.
- `.rubocop.yml`: any limit raise, each in its own commit with its reason.
- `spec/support/slow_files.rb`: T55's relay seam.

## Rejected options

- **Patch each round 3 instance.** About 20 point fixes, and every unseen shape in the research report (`xargs`, `git diff`, a `.venv/bin`, an adopted actor) would still fail.
- **A separate `lain-rpc` or `lain-relay` crate.** The 2026-10-17 ruling keeps lain-core as the wire seed for the phone relay (`ARCHITECTURE.md:2326-2329`). T50 and T52 grow lain-core instead.
- **A lexicographic join on `Verdict`.** The first panel's fix holds as algebra, but no card combines 2 verdicts. Built when a caller needs it.
- **The agenda as a journal projection.** A parked call's input is never journaled, so credentials stay off disk (`queue.rb:375-379`), and a `tool_use_id` can park twice. The agenda polls, as `QueueSurface` does.
- **A new static `ReadTier` rung.** `ComposedTerm` is already the rule that approves a shell command with no human and no model, and only its allow earns the read-only profile (`confine/profiles.rb:120`). A new rung would run unconfined. T21 widens `ComposedTerm` instead.
- **An approval memory.** The round 3 journal held 1 repeat in 96 judge-rung calls and none in 50 parks. Memory would not pay.
- **Send opaque commands to the judge.** An opaque command's paths are unknown, so neither bounds nor masking can be checked. Widening `ComposedTerm` (T21) shrinks the opaque set instead.
- **A longer judge timeout.** The judge times out because its child spends the time on refused tool calls. T18 removes the calls.
- **Let the judge child park.** A judge that asks a human defeats the judge.
- **Codex-style prefix rules.** Prefix rules cannot reach inside `&&` chains or check bounds, and lain already parses bash with tree-sitter.
- **`Oracle::Model` for the judge.** It decodes JSON, retries a blank reply, sends no system prompt and forces a schema on ollama. T18 sends 1 request with the sealed prompt.
- **Release secrets by value across every command.** A value released for one file would print from any command. T43 releases by path.
- **Read `.lain/config.rb` from each worktree.** It would split one project's config across commits. See Open decisions.
- **Meter cancelled turns from partial usage.** A cancelled stream reports no usage. T18 removes the judge's cancelled calls, which were most of them.
- **Meter the bench graders** (`grader/rubric.rb:72`, `refuter.rb:30`). Bench-only. YAGNI.
- **A run-level token or dollar cap.** `--max-cost` exists; no trial has asked for more. YAGNI.
- **Keep an issue attempt's uncommitted tree across driver retries.** The issue branch carries committed work across attempts, and T24 keeps children's trees. An orchestrator that commits as it goes needs nothing more.
- **Grant the candidate desk, the `LANDING` checkout, a `CARGO_TARGET_DIR` outside the root and `~/go` toolchains.** None was hit in a trial. T13's bounds can take them when one is.
- **Flag fewer abbreviated git shas.** git abbreviates to 7 to 12 hex characters, under the detector's 20-character floor. Longer abbreviations are rare, and a 24-hex token can be a real key.
- **A `Verdict` with `Abstain`.** Abstain is the identity of `Ladder#+`. Folding it into `Verdict` would give the join 2 bottoms.
- **Package-relative mirrored levels for rspec and pytest monorepos.** No trial needs them. T2 only corrects the branch's claim that it generalizes.
- **Answer from the ntfy notification.** An approve needs the context the app shows, and a Deny button would need an HTTP surface on the relay. The notification carries Open only (T56, user ruling 2026-11-03).
- **The app inside this Cargo workspace.** Dioxus pulls a banned crate, and the app needs the Android toolchain. It gets its own repo (T58).

## Open decisions

- **Pin the project config on an epic.** Issue worktrees cut from `epic/<slug>` before a config commit lack that commit's `.lain/config.rb`, and the driver reads the root's. No observed harm, so no card.
- **An issue edited after its launch.** `IssueActor#approved!` checks the plan digest once, at launch. T35 reopens the gate on an edit, but a running issue keeps its launch-time plan. Revisit if a round shows an edit landing mid-run.
- **Spec-only cards.** T5 (the git-scrub guard) and T46 (monoid law pins) add tests over code that is already reachable. They have no production construction site by design.
- **The phone's wake latency and a paired-device timeout.** Research §9, question 1. Measure buzz-to-verdict in the manual pass before changing any timeout.

## Dependency graph

```mermaid
flowchart LR
  T1
  T1 --> T2
  T2 --> T3
  T1 --> T4
  T1 --> T5
  T1 --> T6
  T6 --> T7
  T4 --> T8
  T7 --> T8
  T7 --> T9
  T9 --> T10
  T9 --> T11
  T48 --> T11
  T9 --> T12
  T1 --> T13
  T13 --> T14
  T9 --> T15
  T13 --> T15
  T14 --> T16
  T15 --> T16
  T15 --> T17
  T25 --> T17
  T15 --> T18
  T18 --> T19
  T18 --> T20
  T16 --> T21
  T19 --> T21
  T20 --> T21
  T1 --> T23
  T23 --> T24
  T24 --> T25
  T4 --> T26
  T12 --> T26
  T24 --> T26
  T48 --> T26
  T12 --> T27
  T24 --> T28
  T28 --> T29
  T18 --> T30
  T23 --> T30
  T48 --> T30
  T18 --> T31
  T23 --> T31
  T1 --> T32
  T48 --> T33
  T8 --> T34
  T49 --> T34
  T49 --> T35
  T1 --> T36
  T34 --> T37
  T36 --> T37
  T1 --> T38
  T48 --> T38
  T4 --> T39
  T38 --> T39
  T12 --> T40
  T1 --> T41
  T1 --> T42
  T1 --> T43
  T1 --> T44
  T1 --> T45
  T1 --> T46
  T38 --> T47
  T8 --> T48
  T11 --> T49
  T33 --> T49
  T1 --> T50
  T6 --> T51
  T50 --> T52
  T51 --> T52
  T9 --> T53
  T48 --> T53
  T53 --> T54
  T11 --> T55
  T18 --> T55
  T52 --> T55
  T54 --> T55
  T55 --> T56
  T40 --> T57
  T52 --> T57
  T55 --> T57
  T52 --> T58
  T58 --> T59
  T52 --> T60
  T15 --> T61
  T43 --> T61
```

## Tasks

### Stream 0: the branch, landed and fixed

### T1: Land branch nyotes/implement-readiness on main          [risk: medium]

**Depends on:** none
**Files:** the 22 files of `git -C /home/tara/w/ir diff --stat main..e677e024`, applied as the 5 commits in order (f013ccc4, aa75a6c7, 80f427b3, e5a599c2, e677e024); `lib/lain/cli/command/implement_epic.rb` (the `mounted?` nit)
**Reuse:** the commits as written; `env.epic_driver.mounted?` (`Unmounted#mounted?`)
**Shared-file wiring:** `docs/commands.md:1187`: `/implement-epic [SLUG] [--width N]`
**Reachable from:** `CLI::Command::Registry` -> `ImplementEpic#call` -> `env.epic_driver.run`

**Acceptance criteria**

```gherkin
Scenario: the branch's behavior holds on main
  Given main with the 5 commits cherry-picked in order
  When the full suite runs at a load under 8
  Then the example count is at least 32,417 plus the branch's new examples, with 0 failures

Scenario: a mounted chat names its epic
  Given a chat mounted on epic "nyotes"
  When the human types "/implement-epic nyotes --width 1"
  Then the driver starts on "nyotes"
  And "/implement-epic other" is refused naming the mounted slug

Scenario: the slug check asks the mount, not nil
  Given an unmounted chat
  When the human types "/implement-epic nyotes"
  Then the refusal names the remedy, and implement_epic.rb never compares the slug to nil
```
Spec file: `spec/lain/cli/command/implement_epic_spec.rb`

**Stop and report if:**
- A cherry-pick conflicts with main beyond `644ec6ae`.
- `spec/lain/frontend/neovim/approval_view_spec.rb:483` fails because of path length. That is a known long-path flake, recorded in `nyotes-notes.md` (round 3, 09:14). Report it; do not fix it here.

### T2: Derive a flat level's package roots once, for both directions          [risk: low]

**Depends on:** T1
**Files:** `lib/lain/test_layout/mapping.rb`, `spec/lain/test_layout/mapping_spec.rb`
**Reuse:** the branch's `File.dirname(source_root)` package rule (`mapping.rb:125,156`); `@trees`
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicDriver::Factory` -> `Config.test_layout` -> `TestLayout::Mapping#test_path` and `#level_of`

**Acceptance criteria**

```gherkin
Scenario: the reverse lookup agrees with the forward one
  Given a cargo layout with source roots crates/store/src and crates/asr/src
  When test_path places issue "store-crate" at crates/store/tests/store-crate.rs
  Then level_of("crates/store/tests/store-crate.rs") answers the integration level

Scenario: the guard labels a package test as a test
  Given the same layout
  When the guard locates crates/asr/tests/x.rs
  Then it is not reported as outside the test tree
```
Spec file: `spec/lain/test_layout/mapping_spec.rb`

**Stop and report if:**
- `spec/lain/test_layout/guard_spec.rb` pins `:outside` for a package-relative path.

### T3: Read a cargo package from the layout's rule          [risk: low]

**Depends on:** T2
**Files:** `lib/lain/grader/test_harness/adapter/cargo.rb`, `spec/lain/grader/test_harness/adapter/cargo_spec.rb`
**Reuse:** `TestLayout::Mapping`'s package rule from T2; `Cargo#owner`
**Shared-file wiring:** none
**Reachable from:** `Grader::TestHarness::Adapter.for` -> `Adapter::Cargo#awaiting_subject?`

**Acceptance criteria**

```gherkin
Scenario: one definition of a package
  Given a test file crates/store/tests/store-crate.rs
  When the adapter asks which manifest it expects
  Then it answers crates/store/Cargo.toml by the layout's rule, with no src/tests segment split of its own

Scenario: a red integration test waits only on the subject
  Given an integration test that fails with E0425 naming store::Segment
  When the adapter checks whether it awaits the subject crate "store"
  Then it answers yes

Scenario: a typo in the test is not a valid red
  Given an integration test that fails with E0425 "cannot find function `helpr`" naming no item of crate "store"
  When the adapter checks whether it awaits the subject
  Then it answers no, and the red step reports the test does not load
```
Spec file: `spec/lain/grader/test_harness/adapter/cargo_spec.rb`

**Stop and report if:**
- rustc's E0425 message for a missing `store::x` does not name the crate path in the installed toolchain. In that case, record the real message in the spec.

### T4: Model acceptance as a value, and refuse a declared `manual` level          [risk: medium]

**Depends on:** T1
**Files:**
- `lib/lain/cli/epic_driver/acceptance.rb` (new)
- `lib/lain/cli/epic_driver/plan_subject.rb`
- `lib/lain/cli/epic_driver/issue_actor.rb`
- `lib/lain/test_layout.rb`
- `spec/lain/cli/epic_driver/acceptance_spec.rb` (new), `spec/lain/cli/epic_driver/plan_subject_spec.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`, `spec/lain/test_layout_spec.rb`

**Reuse:** the branch's `IssueTests::Red` and `Manual` (`factory.rb:1378-1401`); `Gate::Policy::HandsOff` (`epic/gate/policy.rb:172`)
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicDriver::IssueActor#adopted` -> `PlanSubject.of` -> `Acceptance.of(level, scenarios:)`

**Acceptance criteria**

```gherkin
Scenario: an issue's level parses once
  Given an issue whose Level is "manual" and whose scenarios name "scripts/fetch-models.sh --check"
  When PlanSubject reads it
  Then it carries Acceptance::Manual with those commands, and no code compares a level to "manual"

Scenario: a layout may not declare manual
  Given a .lain/config.rb whose tests line declares a level named manual
  When the layout loads
  Then loading refuses, naming the reserved level

Scenario: hands-off may not approve a manual issue
  Given a gate policy of hands_off and a manual issue
  When the implementation gate opens
  Then the issue parks for a human, and the reason names manual acceptance
```
Spec file: `spec/lain/cli/epic_driver/acceptance_spec.rb`, `spec/lain/test_layout_spec.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`

**Interface**

```ruby
module Lain::CLI::EpicDriver::Acceptance
  Tested = Data.define(:level)        # the red step writes and runs a test
  Manual = Data.define(:commands)     # the gate shows the diff and these commands
  def self.of(level, scenarios:) = ... # -> Tested | Manual
end
```

**Stop and report if:**
- `cli/epic_driver/factory.rb` must change to remove a `"manual"` comparison. Factory is T26's file. Hand back a 1-line diff instead.

### T5: Make the git-scrub guard see popen and array forms          [risk: low]

**Depends on:** T1
**Files:** `spec/git_fixture_scrub_discipline_spec.rb`, `spec/lain/review/deletability_spec.rb`, `spec/lain/dogfood_config_spec.rb`, `spec/lain/tripwire/hit_spec.rb`, `spec/lain/project/resolver_spec.rb`
**Reuse:** `SeedRepo::SCRUB`, `SeedRepo.git`
**Shared-file wiring:** none
**Reachable from:** deferred: a spec-only guard with no production path (see Open decisions)

**Acceptance criteria**

```gherkin
Scenario: the guard catches an unscrubbed popen
  Given a spec that runs IO.popen(["git", "ls-files"]) with no scrubbed env
  When the discipline spec scans spec/
  Then it reports that site

Scenario: the 4 hand-rolled scrubs use the shared one
  When the discipline spec scans spec/
  Then deletability_spec, dogfood_config_spec, tripwire/hit_spec and project/resolver_spec scrub through SeedRepo::SCRUB
```
Spec file: `spec/git_fixture_scrub_discipline_spec.rb`

**Stop and report if:**
- Another spec outside these 5 files shows up in the widened scan. List it; do not fix it here.

### Stream V: one verdict, one reply grammar, one silence rule, control lines

### T6: Add Approval::Verdict, a closed sum of what a human can answer          [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/approval/verdict.rb` (new), `spec/lain/approval/verdict_spec.rb` (new)
**Reuse:** `Sensitivity::Verdict`'s frozen `Data` shape (`sensitivity.rb:84-134`)
**Shared-file wiring:** none
**Reachable from:** `Approval::Reply.parse` (T7), which `Epic::Gate#call` (T8) and `Pending#decide` (T9) call on the production path

**Acceptance criteria**

```gherkin
Scenario: each variant answers what it is
  Given Approve(note: "ok"), Hold(note: "later") and Deny(note: "no")
  Then exactly one of approved?, held? and denied? is true for each

Scenario: a note is 1 string
  When Approve(note: "a; b") is built
  Then its note is "a; b", and a blank note is nil

Scenario: values are shareable
  Then Ractor.shareable? is true for each variant

Scenario: nothing else is a verdict
  When Verdict.coerce(true) or Verdict.coerce(:approve) is called
  Then it raises, naming the 3 variants
```
Spec file: `spec/lain/approval/verdict_spec.rb`

**Interface**

```ruby
module Lain::Approval::Verdict
  Approve = Data.define(:note)    # note: a frozen String, or nil when blank
  Hold    = Data.define(:note)
  Deny    = Data.define(:note)
  # each: #approved? #held? #denied?
  def self.coerce(value) = ...    # a variant, or raise ArgumentError
end
```

The first panel's lexicographic join is not built: no card combines 2 verdicts, so a join would pin laws nothing uses (YAGNI). Ladder rungs keep answering `Escalation::Ruling`. `Verdict` is the type of a human's answer, a silence default and a gate decision. Inside `CLI::EpicSubmit`, which defines its own `Verdict` (`cli/epic_submit.rb:410`), write `::Lain::Approval::Verdict`.

**Stop and report if:**
- A caller turns out to need a join. Name it, and add the lexicographic join with its laws then.

### T7: Parse every human reply through one grammar          [risk: medium]

**Depends on:** T6
**Files:** `lib/lain/approval/reply.rb` (new), `spec/lain/approval/reply_spec.rb` (new)
**Reuse:** the word sets in `Epic::GateReply` (`epic/submission.rb:139-185`) and `ApprovalPolicy::VERDICT`/`REASONED_NO` (`frontend/approval_policy.rb:47-56`); `spec/support/shared_examples/round_trip.rb`
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicSubmit#gate` -> `Epic::Gate#call` (T8), `Parked::Queue` -> `ApprovalPolicy` (T9), `ApprovalView#answer_row` (T10); each card swaps its parser for this one

**Acceptance criteria**

```gherkin
Scenario: a bare approve
  When "approve" is parsed
  Then it is Approve with no note

Scenario: an approve with a note
  When "approve, re-signed unchanged" is parsed
  Then it is Approve with the note "re-signed unchanged"

Scenario: a y
  When "y" is parsed
  Then it is Approve with no note

Scenario: an n with a reason
  When "n wrong crate name" is parsed
  Then it is Deny with the reason "wrong crate name"

Scenario: a deny with a colon
  When "deny: use lain epic status" is parsed
  Then it is Deny with the reason "use lain epic status"

Scenario: a hold with a note
  When "hold back after lunch" is parsed
  Then it is Hold with the note "back after lunch"

Scenario: a blank note is no note
  When "approve,   " is parsed
  Then it is Approve with a nil note

Scenario: a separator after the verdict word is dropped
  When "deny: wrong crate" and "deny, wrong crate" are parsed
  Then both are Deny with the note "wrong crate"

Scenario: an empty line is not a verdict
  When "" is parsed
  Then it is Unrecognised; the [y/N] policy, not the grammar, maps a blank line to deny (T9)

Scenario: an unknown first word is never a deny
  When "approvx" is parsed
  Then it is Unrecognised, and the caller asks again

Scenario: rendering is a normal form
  Then parse(render(v)) == v for every verdict, per the shared round-trip group
```
Spec file: `spec/lain/approval/reply_spec.rb`

**Interface**

```ruby
module Lain::Approval::Reply
  Unrecognised = Data.define(:text)
  def self.parse(line) = ...   # -> Verdict::Approve | Verdict::Hold | Verdict::Deny | Unrecognised
  def self.render(verdict) = ...
end
```

**Stop and report if:**
- A wave gate's `deny <id>: <reason>` form cannot be expressed as a per-id use of `parse`. Report the form; T8 owns it.

### T8: Gate replies parse through Reply and carry a Verdict          [risk: high]

**Depends on:** T4, T7
**Files:**
- `lib/lain/epic/submission.rb`, `lib/lain/epic/gate.rb`
- `lib/lain/epic/signoff_queue.rb`
- `lib/lain/cli/epic_submit.rb`
- `lib/lain/forge/local_landing.rb`
- `lib/lain/cli/epic_driver/issue_actor.rb`
- Specs: `spec/lain/epic/submission_spec.rb`, `spec/lain/epic/gate_spec.rb`, `spec/lain/epic/signoff_queue_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`

**Reuse:** `Gate::Answer`, `Gate::Outcome#for` (`gate.rb:275-283`)
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicSubmit#gate` (`cli/epic_submit.rb:690`) -> `Epic::Gate#call` -> `Reply.parse`

**Acceptance criteria**

```gherkin
Scenario: an approval with a note approves
  Given a parked research gate
  When the human replies "approve round 2 research, re-signed unchanged"
  Then the gate decision is Approve with that note, and nothing records "unrecognised"

Scenario: an unrecognised reply asks again
  When the human replies "aprove"
  Then the gate asks again with the reply instruction and records no decision

Scenario: a wave reply resolves per issue
  Given a wave gate for issues a, b, c
  When the human replies "approve; deny b: wrong crate; hold c"
  Then a is Approve, b is Deny with "wrong crate", c is Hold
  And the leading bare "approve" applies to every id the reply does not name, which the reply instruction says

```
Spec file: `spec/lain/epic/gate_spec.rb`, `spec/lain/epic/submission_spec.rb`

**Stop and report if:**
- `spec/lain/forge/` pins `approved: true/false` on a landing record. List it; it moves to `verdict`.
- `Gate#approved?` callers need more than this card's change. That set is T33's.

### T9: The parked queue decides a Verdict, and a hold postpones the call          [risk: high]

**Depends on:** T7
**Files:**
- `lib/lain/approval/parked/queue.rb`
- `lib/lain/approval/escalation.rb`
- `lib/lain/approval/denial_breaker.rb`
- `lib/lain/frontend/approval_policy.rb`
- `lib/lain/frontend/neovim/approval_view.rb`
- `lib/lain/cli/command/approve.rb`
- Specs: `spec/lain/approval/parked/queue_spec.rb`, `spec/lain/approval/escalation_spec.rb`, `spec/lain/approval/denial_breaker_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`, `spec/lain/cli/command/approve_spec.rb`, `spec/lain/middleware/gate_spec.rb`

**Reuse:**
- `Pending#decide` (`queue.rb:262-268`).
- `Escalation::Ruling.deny` with `final:`, `liftable:` and `told:` (`escalation.rb:91-171`). The gate already renders a liftable final deny (`middleware/gate.rb:92,188`).
- `Queue#remember` and `human_denial?` (`queue.rb:625-630,672`).
- `DenialBreaker` (`denial_breaker.rb`).

**Shared-file wiring:** none
**Reachable from:** `CLI::Switchboard#approvals` -> `Approval::Parked::Queue#adjudicate` -> `Pending#decide(verdict)` -> the Surfaces rung -> `Ruling.deny(final: true, liftable: true, told: ...)` -> `Middleware::Gate`

**Acceptance criteria**

```gherkin
Scenario: a reasoned deny reaches the agent
  Given a parked bash call
  When the human answers "n use lain epic status" at [y/N]
  Then the agent's tool result says denied with "use lain epic status"

Scenario: a blank answer still denies
  When the human answers with an empty line at [y/N]
  Then the call is denied, as today (approval_policy.rb:43-46)

Scenario: a hold postpones the call
  Given a parked bash call
  When the human answers "hold after lunch"
  Then the agent's tool result says the call is postponed by the human with "after lunch", and to issue it again later, when it will park for an answer
  And the agent's turn goes on

Scenario: a postpone is not a remembered denial
  Given a call postponed with "after lunch"
  When the agent issues the same call again
  Then it parks again for the human, and is not refused as a remembered denial

Scenario: postponing in a loop trips the breaker
  Given the same call postponed by the human 3 times for one requester
  When the agent issues it a 4th time
  Then the denial breaker counts each postpone as a denial, and trips at its usual threshold

Scenario: decide takes only a verdict
  When Pending#decide is called with true, false or a String
  Then it raises, and nothing is approved
  And ApprovalView#settled (approval_view.rb:422) passes a Verdict
```
Spec file: `spec/lain/approval/parked/queue_spec.rb`, `spec/lain/approval/denial_breaker_spec.rb`, `spec/lain/middleware/gate_spec.rb`

**Interface**

```ruby
Pending#decide(verdict, surface:, authority:)   # Verdict.coerce(verdict); a Hold settles as :postpone
Pending#decision                                 # :approve | :deny | :postpone
```

This is the user's ruling of 2026-11-03 (design A). There is no grant and no new rung. The Surfaces rung maps `:postpone` to the existing liftable final deny with a "postponed" `told:` clause. Only the queue knows Hold, so `human_denial?` skips it, and the breaker counts it as a denial.

**Stop and report if:**
- `cli/human_replies.rb` calls `Pending#decide` directly with a Boolean (the second panel cited `:1110`, which is `ApprovalView#decide`). Grep for every `decide(` caller and list any outside this card's Files.

### T10: The nvim approval view sends and reads Reply words          [risk: medium]

**Depends on:** T9
**Files:** `lib/lain/frontend/neovim/approval_view.rb`, `lib/lain/frontend/neovim/runtime/62_approval.lua`, `lib/lain/cli/human_replies.rb`, `spec/lain/frontend/neovim/approval_view_spec.rb`, `spec/lain/frontend/neovim/runtime/62_approval_spec.rb`, `spec/lain/cli/human_replies_spec.rb`
**Reuse:** `:LainDeny` (`62_approval.lua:217-263`); `ApprovalView#decide`, which `cli/human_replies.rb:1110` calls
**Shared-file wiring:** none
**Reachable from:** `Frontend::Neovim` -> `ApprovalView#answer_row` -> `Reply.parse` -> `Pending#decide`

**Acceptance criteria**

```gherkin
Scenario: approve with a note from nvim
  Given a call in lain://approval
  When the human runs :LainApprove looks fine
  Then the call is approved with the note "looks fine"

Scenario: postpone from nvim
  When the human runs :LainHold back soon on a call
  Then the call is postponed as T9 defines, and the agent is told so
```
Spec file: `spec/lain/frontend/neovim/approval_view_spec.rb`

**Stop and report if:**
- `spec/plugin/nvim_plugin_spec.rb` pins the command list in a way that needs a shared edit. Hand back the 1-line diff.

### T11: One silence rule for gates and parks, hold by default          [risk: high]

**Depends on:** T9, T48
**Files:**
- `lib/lain/approval/silence.rb` (new)
- `lib/lain/config.rb`, `lib/lain/config/builder.rb`
- `lib/lain/epic/gate.rb`, `lib/lain/approval/parked/queue.rb`
- `lib/lain/cli/switchboard.rb`, `lib/lain/cli/epic_submit.rb`
- `lib/lain/frontend/approval_policy.rb`, `lib/lain/cli/repl/approval_surfaces.rb`
- Specs: `spec/lain/approval/silence_spec.rb` (new), `spec/lain/config_spec.rb`, `spec/lain/epic/gate_spec.rb`, `spec/lain/approval/parked/queue_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`

**Reuse:** `Config::DEFAULT_APPROVAL_TIMEOUT`; `Gate::Outcome#for`
**Shared-file wiring:** `docs/commands.md`: document `approval silence: :hold | :deny`
**Reachable from:** `CLI::EpicSubmit#gate_timeout` and `CLI::Switchboard#approvals` -> `Approval::Silence.from(config)`

**Acceptance criteria**

```gherkin
Scenario: a silent wave gate holds each issue
  Given approval silence unset and a wave gate for 9 issues
  When the timeout passes with no answer
  Then all 9 are Hold("no answer within 900s"), none is denied, and the run reports them unsettled

Scenario: a silent park holds
  Given a parked bash call
  When the timeout passes
  Then the call is postponed as T9 defines: the agent's result says it is postponed for a human, its turn goes on, and the call waits in /inbox

Scenario: deny is a choice
  Given "approval silence: :deny" in .lain/config.rb
  When a gate times out
  Then each item is Deny("timeout")

Scenario: the prompts say what silence does
  Given approval silence unset
  Then the [y/N] prompt and the arrival line say "postpones in <window>", not "auto-denies in" (approval_policy.rb:305,312, approval_surfaces.rb:123)

Scenario: an interrupt still denies
  When the run is interrupted while a gate waits
  Then the decision is Deny("interrupted"), whatever the silence rule
```
Spec file: `spec/lain/approval/silence_spec.rb`, `spec/lain/epic/gate_spec.rb`

**Stop and report if:**
- A silent park cannot settle as postponed without a deny, because of `queue.rb:614`'s abandoned-call deny. Report the shape; silence must settle it as postponed.

### T12: Control commands act during a run, and /deny takes a reason          [risk: high]

**Depends on:** T9
**Files:**
- `lib/lain/frontend/intake.rb`, `lib/lain/frontend/intake/disposition.rb`, `lib/lain/frontend/stdin_pump.rb`
- `lib/lain/cli/command/registry.rb`, `lib/lain/cli/command/approve.rb`, `lib/lain/cli/command/held.rb`, `lib/lain/cli/command/inbox.rb`, `lib/lain/cli/command/stop.rb`, `lib/lain/cli/command/deny.rb` (new)
- `lib/lain/cli/wiring/intake_build.rb`
- Specs: `spec/lain/frontend/intake_spec.rb`, `spec/lain/frontend/stdin_pump_spec.rb`, `spec/lain/cli/command/registry_spec.rb`, `spec/lain/cli/command/approve_spec.rb`, `spec/lain/cli/command/deny_spec.rb` (new)

**Reuse:** `Disposition` (4 kinds); `Registry#perishable?`, `#refusal`; `Intake#lifts?` and its 2 callers (`intake.rb:232`, `stdin_pump.rb:282`); `Approval::Reply` (T7)
**Shared-file wiring:** `docs/commands.md`: `/deny <reason>`
**Reachable from:** `Frontend::StdinPump#forwarded` and `Frontend::Intake#deliver` -> `Disposition.of` -> `Registry#disposition(text)`

**Acceptance criteria**

```gherkin
Scenario: /held clear works while a slash command runs
  Given /implement-epic is running and a stray "y" is a held line
  When the human types "/held clear"
  Then the held line is dropped at once

Scenario: /inbox opens during a run
  When the human types "/inbox" while /implement-epic runs
  Then the inbox shows now, not after the run

Scenario: the stdin pump forwards control commands
  Given lain chat reading stdin while a turn runs
  When "/deny wrong tree" arrives on stdin
  Then it reaches the Intake as a control command, not as typeahead

Scenario: /deny with one pending call
  Given exactly one parked call
  When the human types "/deny use lain epic status"
  Then the call is denied with that reason, and the agent's result carries it

Scenario: /deny with several pending
  Given 2 parked calls
  When the human types "/deny wrong tree"
  Then lain asks which call, as /approve does, and denies the chosen one with the reason

Scenario: one question decides a line's kind
  Then Registry answers disposition(text) as one of :note, :hold, :control, :refuse
  And no command defines perishable?
```
Spec file: `spec/lain/frontend/intake_spec.rb`, `spec/lain/frontend/stdin_pump_spec.rb`, `spec/lain/cli/command/deny_spec.rb`

**Interface**

```ruby
# each command class
def self.disposition = :control   # or :hold, the default: held behind a run
Registry#disposition(text) # -> :note | :hold | :control | :refuse
```

`serves_replies?` stays. It answers a different question, whether a command reads the terminal itself, and `spec/reply_surface_discipline_spec.rb` pins it (`cli/human_replies.rb:1468-1490`). In this plan a "held line" is a typed line waiting behind a run. A tool call waiting for a later answer is "postponed" (T9).

**Stop and report if:**
- `Intake#lifts?` has a caller besides `/stop` and `StdinPump#forwarded`. List it before deleting.

### T13: Add Sensitivity::Bounds and its exec rule set, one per agent          [risk: high]

**Depends on:** T1
**Files:** `lib/lain/sensitivity/bounds.rb` (new), `lib/lain/confine/exec_rules.rb` (new), `spec/lain/sensitivity/bounds_spec.rb` (new), `spec/lain/confine/exec_rules_spec.rb` (new)
**Reuse:** `Sensitivity::Roots` (`roots.rb`); `Sensitivity::Rules` glob compilation (`sensitivity.rb:535`); `spec/support/shared_examples/monoid.rb`, `meet_semilattice.rb`
**Shared-file wiring:** none
**Reachable from:** `BoardBuild.session_policy` and `CLI::ToolGuard#leased`, which T15 changes to build it

**Acceptance criteria**

```gherkin
Scenario: bounds join componentwise
  Given bounds A (reads /p, writes /p) and B (reads /epic, execs target/** under /p)
  When A | B
  Then reads hold /p and /epic, writes hold /p, execs hold target/** under /p

Scenario: equal bounds are equal however they were built
  Given Bounds.of(reads: ["/tmp", "/usr"]) and Bounds.of(reads: ["/usr", "/tmp"])
  Then they are == and their digests match

Scenario: the laws hold
  Then Bounds and ExecRules each pass the shared monoid group with NONE as identity
  And Bounds passes the meet-semilattice group with meet: :|, equal: ==, ancestor_of: <=
  And for every component c, (a | b).c == a.c | b.c

Scenario: a child gets the parent's base, not its siblings
  Given parent bounds P holding child leases /w/c/a and /w/c/b
  When P.lend("/w/c/b") builds child b's bounds
  Then b reads P's base reads and /w/c/b, writes only /w/c/b, and does not read /w/c/a

Scenario: a parent reads its children's leases
  Then P.read?("/w/c/a/Cargo.toml") is true
```
Spec file: `spec/lain/sensitivity/bounds_spec.rb`, `spec/lain/confine/exec_rules_spec.rb`

**Interface**

```ruby
class Lain::Confine::ExecRules          # a set of (glob, root) rules
  NONE = ...
  def |(other) = ...; def exec?(path) = ...; def dirs = ...   # dirs: what lowers to lain-fence exec_dirs
end
class Lain::Sensitivity::Bounds
  NONE = ...
  def self.of(reads: [], writes: [], execs: Confine::ExecRules::NONE) = ...
  attr_reader :reads, :writes, :execs, :children
  def |(other) = ...; def <=(other) = ...
  def with_child(dir) = ...; def lend(dir) = ...
  def read?(path) = ...; def write?(path) = ...; def exec?(path) = ...
  def digest = ...   # over the canonical form: sorted spellings, nested roots dropped
end
```

T14 fills in the named rules. This card makes the type and its laws.

**Stop and report if:**
- `Roots#<=` is a preorder only (`roots_spec.rb` notes it), and the semilattice group needs a partial order. Canonicalise in Bounds; do not change Roots.

### T14: Name exec rules for build output and lain's own entry point          [risk: high]

**Depends on:** T13
**Files:** `lib/lain/confine/exec_rules.rb` (created by T13), `lib/lain/tripwire/resolution.rb`, `spec/lain/confine/exec_rules_spec.rb` (created by T13), `spec/lain/tripwire/resolution_spec.rb` (new)
**Reuse:** `Confine::ExecRules` (T13); `Landing`; the tripwire's `fresh_run_file` and `unresolved_exec` signals (`tripwire/resolution.rb`, `tripwire/hit.rb`)
**Shared-file wiring:** none
**Reachable from:** `Confine::Sandbox` -> `Profiles#for` -> `Profile.workspace` (T16), and `Tripwire::Resolution`, which reads the same rules

**Acceptance criteria**

```gherkin
Scenario: a fresh build's test binaries may run
  Given a project root /p and ExecRules::PROJECT
  Then exec?("/p/target/debug/deps/store-1a2b") is true
  And exec?("/p/node_modules/.bin/vitest") and exec?("/p/.venv/bin/pytest") are true
  And exec?("/p/src/main.rs") is false

Scenario: lain's own entry point is a named rule
  Then exec? is true for this checkout's exe/lain and for the lain shim that runs it
  And false for a RubyGems binstub named lain elsewhere on PATH

Scenario: the tripwire agrees with the sandbox
  Given cargo test runs target/debug/deps/x-hash, which the build just wrote
  Then the tripwire records no fresh_run_file stop signal for it, by the user's ruling of 2026-11-03 that named build output is exempt
  And any other fresh exec still records the stop signal, as the 2026-10-27 ruling requires
```
Spec file: `spec/lain/confine/exec_rules_spec.rb`, `spec/lain/tripwire/resolution_spec.rb`

**Stop and report if:**
- lain-fence's `exact_files` must name each binary, and it fails on a missing one (`crates/lain-fence/src/main.rs:106-129`). The rules must lower to `exec_dirs`. Report any rule that cannot.

### T15: Every layer reads the agent's Bounds          [risk: high]

**Depends on:** T9, T13
**Files:**
- `lib/lain/worker_env.rb`
- `lib/lain/sensitivity/policy.rb`
- `lib/lain/cli/tool_guard.rb`
- `lib/lain/session.rb`
- `lib/lain/middleware/confine_to_scope.rb`, `lib/lain/middleware/gate.rb`
- `lib/lain/approval/escalation.rb`
- `lib/lain/cli/wiring/board_build.rb`
- Specs: `spec/lain/worker_env_spec.rb`, `spec/lain/sensitivity/policy_spec.rb`, `spec/lain/session_spec.rb`, `spec/lain/middleware/confine_to_scope_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Reuse:** `Policy#confined` (`policy.rb:501-505`); `BoardBuild.read_roots`
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` -> `BoardBuild.session_policy` (the chat's bounds) and `CLI::ToolGuard#leased(worker_env)` (each child's, via `Bounds#lend`)

**Acceptance criteria**

```gherkin
Scenario: a child reads its own lease
  Given a reviewer child leased at /w/children/317dc2c7a3f3
  When it calls grep on /w/children/317dc2c7a3f3/README.md
  Then the call is not parked as outside the project

Scenario: reads agree
  Given an agent's bounds
  Then Policy#confined's read answer equals Bounds#read? for every path in the shared fixture set

Scenario: writes agree
  Given the same bounds
  Then Policy#confined's write answer, Session::Confined#holds? and ConfineToScope's write and cd answers equal Bounds#write? for every path in the fixture set

Scenario: one construction per agent
  Then WorkerEnv carries bounds, and no lib/ file builds Roots.of for an agent's checkout outside Bounds
```
Spec file: `spec/lain/sensitivity/policy_spec.rb`, `spec/lain/session_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

**Interface**

```ruby
WorkerEnv = Data.define(:cwd, :env, :checkout, :bounds)
Policy#confined(bounds)    # replaces confined(roots:)
```

`ConfineToScope` reads the board's scope, not the session's, on purpose (`middleware/confine_to_scope.rb` header). The writes scenario compares answers under one scope.

**Stop and report if:**
- `WorkerEnv` stops being `Ractor.shareable?` (`worker_env.rb:51`) with `bounds` in it.
- `spec/lain/seams/child_tool_guard_spec.rb` pins a refusal this card turns into an allow. List it.

### T16: The sandbox profiles read the agent's Bounds          [risk: high]

**Depends on:** T14, T15
**Files:**
- `lib/lain/confine/profile.rb`, `lib/lain/confine/profiles.rb`, `lib/lain/confine/mask_list.rb`, `lib/lain/confine/sandbox.rb`
- `lib/lain/shell/executable/fresh.rb`
- Specs: `spec/lain/confine/profile_spec.rb`, `spec/lain/confine/profiles_spec.rb`, `spec/lain/confine/mask_list_spec.rb`, `spec/lain/shell/executable/fresh_spec.rb`

**Reuse:** `Profile.reader`'s `related:`; `Profiles#placed`; `ExecRules` (T14)
**Shared-file wiring:** `ARCHITECTURE.md`: freshness now gates the read-only reader's exec only (user ruling 2026-11-03)
**Reachable from:** `Confine::Sandbox` (`sandbox.rb:61`) -> `Profiles#for(request)` -> `Profile.reader` / `Profile.workspace` with `bounds`

**Acceptance criteria**

```gherkin
Scenario: a judge-approved read sees the epic home
  Given an epic home lent to the session
  When a judged `ls ~/.local/state/lain/epics/<project>/nyotes` runs in the workspace profile
  Then it lists the directory

Scenario: cargo test binaries run
  Given a fresh worktree with no target/ at profile build
  When `cargo test` builds and runs target/debug/deps/x-hash
  Then the binary runs, by the PROJECT exec rule

Scenario: exec does not flip mid-run in the workspace
  Given ~/.cargo/bin/cargo granted at the start of a run
  When its ctime changes during the run
  Then a later cargo call in the workspace profile is still granted, and the tripwire records the change

Scenario: the reader still refuses a fresh binary
  Given the same change
  Then a ComposedTerm read-only call under the reader profile may not exec it
```
Spec file: `spec/lain/confine/profile_spec.rb`, `spec/lain/confine/profiles_spec.rb`, `spec/lain/shell/executable/fresh_spec.rb`

`ExecRules` covers project-relative build output and lowers to lain-fence `exec_dirs`. The per-call `exec_files` from `Profiles#placed` still grant `:system` and `:user` programs. The 2 never cover the same path: `ExecRules` holds only paths under the root, and `placed` never grants `:project`.

The user ruled on 2026-11-03 that freshness gates only the reader. That reverses the workspace half of the October binary-identity ruling.

**Stop and report if:**
- The epic-home `ls` in round 3 ran under a profile other than the workspace one (the research left this open; 37 traced and 34 workspace profiles ran). Check the escalation record's rung first, and report if the scenario's premise is wrong.

### T17: A parent's bounds hold its children's leases          [risk: medium]

**Depends on:** T15, T25
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/sensitivity/bounds/cell.rb` (new), `lib/lain/sensitivity/policy.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/sensitivity/bounds/cell_spec.rb` (new)
**Reuse:** `Bounds#with_child`, `#lend` (T13); `lending` (`subagent.rb:402`); `Policy::Confined` (`policy.rb:225-236,501-505`)
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent#lending` -> the parent's `Bounds::Cell#swap { _1.with_child(lease_dir) }`, which the parent's `Policy::Confined` reads per call

**Acceptance criteria**

```gherkin
Scenario: an orchestrator reviews its dev's tree
  Given an orchestrator that spawned dev "skeleton" at /w/children/4bfe
  When the orchestrator reads /w/children/4bfe/Cargo.toml after the dev hands back
  Then the read is not parked as outside the project

Scenario: a sibling's tree stays out
  Given the orchestrator also spawned dev "store" at /w/children/9a1c
  Then "store" cannot read /w/children/4bfe

Scenario: one mutable cell
  Then a parent's bounds change only through its Bounds::Cell, and the cell holds a frozen Bounds at every read
```
Spec file: `spec/lain/tools/subagent_spec.rb`, `spec/lain/sensitivity/bounds/cell_spec.rb`

**Interface**

```ruby
class Lain::Sensitivity::Bounds::Cell   # the one mutable reference to an agent's Bounds
  def initialize(bounds) = ...
  def current = ...                     # a frozen Bounds
  def swap = ...                        # yields the current Bounds, stores the frozen result, under a Mutex
end
```

`Policy::Confined` is frozen at stack build, so it holds the cell, not a Bounds. The edge from T25 only serializes edits to `subagent.rb`.

**Stop and report if:**
- `Policy::Confined` must be `Ractor.shareable?` (a spec pins it). A Mutex-backed cell is not. Report the spec, and keep the cell outside the shareable value.

### Stream J: the judge

### T18: The judge is one tool-less, metered request          [risk: high]

**Depends on:** T15
**Files:**
- `lib/lain/approval/judge.rb`
- `lib/lain/cli/wiring/judge_source.rb`, `lib/lain/cli/wiring.rb`
- `lib/lain/role/catalog.rb`
- `lib/lain/prompt/templates/role/auto_approver.md`
- `lib/lain/bench/approval_replay/recorded_judge.rb`
- Specs:
  - `spec/lain/approval/judge_spec.rb`, `spec/lain/cli/wiring/judge_source_spec.rb`
  - `spec/lain/role_spec.rb`, `spec/lain/role/catalog_spec.rb`, `spec/lain/prompt/slots_spec.rb`
  - `spec/lain/seams/role_child_judge_spec.rb`, `spec/lain/seams/child_read_scope_spec.rb`
  - `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/tools/subagent_gate_spec.rb`
  - `spec/lain/status_feed/fleet_spec.rb`
  - `spec/lain/bench/approval_replay/recorded_judge_spec.rb`

**Reuse:** `Provider::Journaled` (`requester: :auto_approver`), as `cli/backend/summarizer.rb:50-53` wraps a provider; `Judge#question`, `#parse`, `Pause`; the sealed role prompt from `Prompt::Slots` (`prompt/slots.rb:71-113`); `Provider::Admission` with `queue: true`
**Shared-file wiring:** `spec/lain/epic/gate/adjudicator_spec.rb:775` pins `gate_adjudicator.only == auto_approver.only`; the main session changes that example to say the adjudicator keeps its tools while the judge has none
**Reachable from:** `CLI::Wiring` (`wiring.rb:926`) -> `JudgeSource.new(provider:, model:, journal:, timeout:)` -> `Approval::Judge`

**Acceptance criteria**

```gherkin
Scenario: one request per judgement
  Given a judged bash call
  When the judge rules
  Then exactly one provider request is sent, with the sealed auto_approver system prompt and no tool schemas
  And a blank reply is a defer, not a retry

Scenario: the judge's spend is on the record
  Then the session journal holds a request_sent and a turn_usage for that request, requester auto_approver

Scenario: the prompt carries what the judge used to read
  Then the question names the cwd, the requester's bounds' read roots, each named path's classification and the facts block
  And auto_approver.md says to rule on what is given

Scenario: the pause still covers admission
  Given the provider's admission width is full
  When the judge waits for a slot
  Then the 30 s clock does not run while it waits

Scenario: the role keeps its seal
  Then auto_approver stays in Role::Catalog with no tools, and its prompt stays sealed
```
Spec file: `spec/lain/approval/judge_spec.rb`, `spec/lain/cli/wiring/judge_source_spec.rb`, `spec/lain/role/catalog_spec.rb`

**Stop and report if:**
- `Role::Catalog` refuses an empty `only:`. Keep the role in the catalog with an empty list and report the validation, because leaving the catalog unseals the prompt (`prompt/slots.rb:108-113`).

### T19: Judged decides weighability once, before paying          [risk: high]

**Depends on:** T18
**Files:** `lib/lain/approval/judged.rb`, `lib/lain/approval/judgement.rb` (new), `lib/lain/shell/named.rb`, `lib/lain/approval/judge/facts.rb`, `spec/lain/approval/judged_spec.rb`, `spec/lain/approval/judgement_spec.rb` (new), `spec/lain/shell/named_spec.rb`, `spec/lain/approval/judge/facts_spec.rb`
**Reuse:** `Named::GIT_READ_ONLY` (`named.rb:717`); `Judged#unlooked`'s reasons and `Reach` (`judged.rb:56-65`); `Bounds` (T13); `Confine::MaskList` (`confine/mask_list.rb:10-14`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Switchboard#ladders` (`switchboard.rb:552`) -> `Judged#call` -> `Judgement.of(effect, bounds:, named:, facts:, masked:)`

**Acceptance criteria**

```gherkin
Scenario: git reads reach the model
  When Judged weighs "git status && git log && git branch -a" in a project
  Then the Judgement is Weighable, and .git is not a weighed path

Scenario: a git diff reaches the model
  When Judged weighs "git diff HEAD~1 -- crates/store" in a project
  Then the Judgement is Weighable

Scenario: a cd-relative grep reaches the model
  When Judged weighs "cd .lain-views && grep -c Given x.md" in a project
  Then the Judgement is Weighable

Scenario: a recursive grep over a masked secret reaches the model
  Given grep -rn over a tree holding .env, and a call that runs under a profile whose MaskList masks .env
  Then the Judgement is Weighable, and its facts say .env is masked from the output

Scenario: a recursive grep over an unmasked secret does not
  Given the same tree and a call that runs unconfined
  Then the Judgement is Unweighable(:protected_target)

Scenario: a secret below the mask's depth is not weighable
  Given grep -rn over a tree holding vendor/pkg/.env, which MaskList does not cover (mask_list.rb:13)
  Then the Judgement is Unweighable(:protected_target)

Scenario: a walk past the bound is still refused
  Given a recursive read that walks over 2000 entries
  Then the Judgement is Unweighable(:too_many)

Scenario: a barred call costs nothing
  Given the judge_facts arm on and a call whose bar is non-empty
  When Judged weighs it
  Then it is Unweighable(:barred) and no judge request is sent
```
Spec file: `spec/lain/approval/judgement_spec.rb`, `spec/lain/approval/judged_spec.rb`, `spec/lain/shell/named_spec.rb`

**Interface**

```ruby
module Lain::Approval::Judgement
  Weighable   = Data.define(:paths, :facts)
  Unweighable = Data.define(:reason)       # reason in REASONS
  REASONS = %i[opaque barred below_top outside protected_target too_many].freeze
  def self.of(effect, bounds:, named:, facts:, masked:) = ...
end
```

**Stop and report if:**
- Making `git log` weighable needs `Named` to stop implying `<cwd>/**` for git (`named.rb:831-835,1004-1011`), and `spec/lain/shell/named_spec.rb` pins that as a secret-boundary property. Report it: the profile's mask, not the walk, must then guard the output.
- `masked:` comes from the profile a judge allow will run under: the workspace profile whenever the workspace is on (`confine/profiles.rb:54-55,122`). If the workspace is off, `masked:` is false. Report it if `Profiles#for` cannot be asked before the ruling.

### T20: Score a ComposedTerm table against recorded verdicts and a hazard corpus          [risk: medium]

**Depends on:** T18
**Files:**
- `lib/lain/bench/approval_replay.rb`, `lib/lain/bench/approval_replay/score.rb`
- `spec/fixtures/sessions/approval_replay/hazards.ndjson` (new)
- Specs: `spec/lain/bench/approval_replay_spec.rb`, `spec/lain/bench/approval_replay/score_spec.rb`

**Reuse:** `Bench::ApprovalReplay`, `RecordedJudge`, `Score`; the fixtures in `spec/fixtures/sessions/approval_replay/`
**Shared-file wiring:** none
**Reachable from:** `exe/lain bench` -> `Bench::ApprovalReplay` with a `composed_term` arm that loads a candidate `PROGRAMS` table

**Acceptance criteria**

```gherkin
Scenario: the hazard corpus must abstain
  Given hazards.ndjson with sed w and e; find -exec, -execdir, -ok, -delete, -fprint, -fprintf and -fls; git -c, --output and --ext-diff, and git reads in a repo whose config sets core.pager, core.fsmonitor or diff.external; rg --pre and -z; sort --compress-program; grep --exclude-from
  When the composed_term arm replays it
  Then the report lists every hazard the candidate table admits

Scenario: the replay reports what a table changes
  Given session journals passed by path at run time
  When the arm replays them against today's table and a candidate
  Then the report lists the parks the candidate removes and each call it admits whose recorded verdict was a judge or human deny
```
Spec file: `spec/lain/bench/approval_replay_spec.rb`, `spec/lain/bench/approval_replay/score_spec.rb`

**Stop and report if:**
- The arm needs `~/.local/state` files in a spec. Specs use only `spec/fixtures`; the round 2 and round 3 replay is integration check 5.

### T21: Widen ComposedTerm, one program at a time, behind the replay          [risk: high]

**Depends on:** T16, T19, T20
**Files:** `lib/lain/approval/composed_term.rb`, `spec/lain/approval/composed_term_spec.rb`
**Reuse:** `ComposedTerm::PROGRAMS`, `Flags`, `Subcommands` (`composed_term.rb:380-455`); `Named::GIT_READ_ONLY`; `Bounds` (T13); `Confine::Profiles#for`, which already runs a ComposedTerm allow under the read-only profile (`confine/profiles.rb:120`)
**Shared-file wiring:** `ARCHITECTURE.md`: ComposedTerm's program list
**Reachable from:** `CLI::Wiring::BoardBuild` (`board_build.rb:185`) -> the Rules rung -> `ComposedTerm#decide`

**Acceptance criteria**

```gherkin
Scenario: the trial's greps run unparked
  Given auto mode in a project
  When an agent runs `cd .lain-views && grep -c "Given" a.md b.md`
  Then it runs under the read-only profile with no judge request and no park

Scenario: git reads are composed terms
  When an agent runs `git log --oneline -5 && git diff --stat`
  Then ComposedTerm allows it

Scenario: each new program has its hazards
  Then rg, git (read subcommands), find, sed -n and head/tail chains each have a flag table, and every hazard in hazards.ndjson abstains

Scenario: paths stay in bounds
  Given a grep whose path is outside the requester's bounds' reads
  Then ComposedTerm abstains
```
Spec file: `spec/lain/approval/composed_term_spec.rb`

**Stop and report if:**
- T20's replay of the round 2 and round 3 journals (integration check 5) lists a call the widened table admits whose recorded verdict was a deny. The user ruled on 2026-11-03 that the static tier ships only behind that replay. Narrow the table until the list is empty, or hand the list to the user.

### Stream R: run state and metering

T22 was removed after the first panel; its static rung became T21's widening of `ComposedTerm`.

### T23: Actor children are journaled children          [risk: high]

**Depends on:** T1
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/tools/subagent/actor.rb`, `lib/lain/tools/subagent/progress.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/tools/subagent/actor_spec.rb`, `spec/lain/supervisor_spec.rb`
**Reuse:** `Lineage#spawn` (`lineage.rb:79`); `Progress`; `OneShot#recording`'s failed-end pattern
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicDriver::IssueActor#call` -> `supervisor.adopt` -> `Tools::Subagent#launch_actor` -> `Lineage#spawn` before `build_child`

**Acceptance criteria**

```gherkin
Scenario: the orchestrator is metered
  Given /implement-epic launches an issue_orchestrator
  When it takes 3 turns
  Then the session journal holds its spawn, 3 child_progress records naming role issue_orchestrator, and a turn_usage per turn naming its spawn

Scenario: a failed build ends its spawn
  Given an actor whose Agent build raises
  Then its spawn has a failed end message, and no spawn is left open

Scenario: an actor gets an inbox
  Then the orchestrator's mailbox is live, addressed to its spawn
```
Spec file: `spec/lain/tools/subagent_spec.rb`, `spec/lain/tools/subagent/actor_spec.rb`

**Stop and report if:**
- `Actor#address` (= spawn digest) is read by `Supervisor` before launch in a way that needs the old order. List it.
- The second `Subagent` reopen trips `Metrics/ClassLength` (302). Extract `ChildBuilder` to a new `lib/lain/tools/subagent/child_builder.rb` in this card rather than raise the limit.

### T24: A stopped child is a journaled record that resumes in its own worktree          [risk: high]

**Depends on:** T23
**Files:**
- `lib/lain/tools/subagent.rb`, `lib/lain/tools/subagent/stops.rb` (new)
- `lib/lain/telemetry/child_stopped.rb` (new)
- `lib/lain/isolation/leases.rb`, `lib/lain/cli/resume.rb`
- Specs: `spec/lain/tools/subagent_spec.rb`, `spec/lain/tools/subagent/stops_spec.rb` (new), `spec/lain/telemetry/child_stopped_spec.rb` (new), `spec/lain/isolation/leases_spec.rb`

**Reuse:** `Stopped`, `Stops`, `Kept::Confined#relet` (`subagent.rb:975-1237`); `Leases::InPlace`
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent#perform` -> `Stops#keeping` on any stop -> `Telemetry::ChildStopped`; and `CLI::Resume` -> `Stops.from_journal`

**Acceptance criteria**

```gherkin
Scenario: a dev resumes where it stopped
  Given dev "skeleton" stopped at its ceiling with uncommitted files in /w/children/4bfe
  When the parent resumes "skeleton"
  Then the dev runs in /w/children/4bfe and its files are there

Scenario: a transport stop is resumable
  Given a child whose turn ended on an SSL EOF
  When the parent resumes it
  Then it continues from its last head in the same worktree

Scenario: stops survive a restart
  Given a session with a stopped child
  When the chat restarts with --resume
  Then the stopped child is listed and resumable

Scenario: a stopped worktree is not surrendered
  Then stopping a child neither removes nor reclaims its lease until it ends or the session closes
```
Spec file: `spec/lain/tools/subagent/stops_spec.rb`, `spec/lain/isolation/leases_spec.rb`

**Interface**

```ruby
Telemetry::ChildStopped = Data.define(:spawn, :label, :role, :head, :lease_path, :ceiling, :reason)
# reason in %i[iterations transport interrupted]
class Tools::Subagent::Stops
  def self.from_journal(records) = ...
end
```

**Stop and report if:**
- `spec/journalable_surface_spec.rb`'s `GenericBuild` cannot build `ChildStopped`. Report the field it chokes on.
- A kept worktree has no owner for its final reclaim when the session is abandoned. That is the unresolved lease question. Report the design before choosing.

### T25: A spawn may carry an iteration ceiling          [risk: low]

**Depends on:** T24
**Files:** `lib/lain/tools/subagent.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `resume_ceiling` (`subagent.rb:304`); the role's budget
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent#perform` -> `Input` validation

**Acceptance criteria**

```gherkin
Scenario: a review spawn asks for 40 iterations
  When the orchestrator spawns review with iterations: 40 and the reviewer role allows 60
  Then the child runs with 40, not the error "Iterations applies only to a resume"

Scenario: the role's budget bounds it
  When it asks for 400 and the role allows 60
  Then it runs with 60
```
Spec file: `spec/lain/tools/subagent_spec.rb`

Iterations are capped by the role's budget, as `resume_ceiling` does today. `Ceilings#attenuate` exempts iterations from the parent's meet on purpose (`budget/ceilings.rb:31-44`).

**Stop and report if:**
- `Choice::Input` or `Kept::Input` (`subagent.rb:1048,1268`) pin the absence for their own reasons.

### T26: /stop stops the epic driver mid-issue          [risk: high]

**Depends on:** T4, T12, T24, T48
**Files:** `lib/lain/cli/epic_driver/factory.rb`, `spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/command/stop_spec.rb`
**Reuse:** the `interrupt:` seam (`factory.rb:60`); `Asking#watching`; `Supervisor#retire`, `STOPPED_MIDTURN`; `Command::Stop` (T12 made it a control command)
**Shared-file wiring:** none
**Reachable from:** `Frontend::Intake` (`:control`) -> `Command::Stop#call` -> `env.epic_driver.stop` -> each live actor's `stop`

**Acceptance criteria**

```gherkin
Scenario: a stop during an issue
  Given /implement-epic running issue cargo-workspace mid-turn
  When the human types "/stop"
  Then the actor stops within one turn, its commits are anchored on the issue branch, and the run reports the issue unsettled with "stopped by the human"

Scenario: no gate opens for a stopped issue
  Then the implementation gate does not open for it

Scenario: a human stop ends the issue's lease
  Then the issue worktree's lease is released, unlike a ceiling or transport stop (T24), which keeps it for a resume
```
Spec file: `spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/command/stop_spec.rb`

**Stop and report if:**
- `Supervisor#stop` must be called (it kills the reactor; `Command::Stop`'s comment avoids it). Use the per-actor stop.
- `lib/lain/cli/command/stop.rb` needs a change beyond T12's. It is T12's file; hand back a 1-line diff.

### T27: An early answer waits for the prompt it can answer          [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/frontend/intake.rb`, `spec/lain/frontend/intake_spec.rb`
**Reuse:** generations (`intake.rb:395,421-431`); `Reply.parse`
**Shared-file wiring:** none
**Reachable from:** `Frontend::Intake#publish` -> offer the held reply to the new answer prompt

**Acceptance criteria**

```gherkin
Scenario: a y typed before [y/N] draws
  Given /approve sent and its [y/N] not drawn yet
  When the human types "y" and then the prompt draws
  Then the y answers that prompt, and nothing is held as a chat prompt

Scenario: only a verdict word carries over
  When the human types "what is this" before the prompt draws
  Then it stays held as a chat prompt
```
Spec file: `spec/lain/frontend/intake_spec.rb`

**Stop and report if:**
- `spec/lain/frontend/intake_spec.rb` pins generation 0 never answering as a typeahead safety property. Report the example's name.

### T28: The skill's allowance belongs to the run          [risk: medium]

**Depends on:** T24
**Files:**
- `lib/lain/agent.rb`
- `lib/lain/middleware/skill_dispatch.rb`
- `lib/lain/telemetry/run_allowance.rb` (new)
- `lib/lain/cli/resume.rb`
- Specs: `spec/lain/agent_spec.rb`, `spec/lain/middleware/skill_dispatch_spec.rb`, `spec/lain/telemetry/run_allowance_spec.rb` (new), `spec/lain/cli/resume_spec.rb`

**Reuse:** `Budget::Allowance#grant`; `ceilinged` (`agent.rb:635`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Repl` -> `Middleware::SkillDispatch#call` -> `Agent#allow(ceilings)`, journaled as `RunAllowance`; `CLI::Resume` reads it back

**Acceptance criteria**

```gherkin
Scenario: a plain re-ask keeps the skill's ceiling
  Given /create-epic-issues granted 25 + 3 per issue for 26 issues (103)
  When the run is interrupted and the human re-asks with a plain prompt
  Then the ceiling is 103, not 25

Scenario: a resumed chat keeps it
  When the chat restarts with --resume
  Then the same allowance applies

Scenario: a later skill's grant replaces the earlier one
  Given /plan-epic's grant and then /create-epic-issues' larger grant
  Then the run's ceiling is /create-epic-issues', not the smaller of the two
```
Spec file: `spec/lain/agent_spec.rb`, `spec/lain/cli/resume_spec.rb`

The newest grant replaces the last one. Only a nested ceiling, such as a child under its parent, combines by `meet`.

**Stop and report if:**
- A skill ending must end its allowance, and `SkillDispatch` cannot see the end. Report what marks the end.

### T29: Retry a dropped transport at the Agent          [risk: high]

**Depends on:** T28
**Files:** `lib/lain/agent.rb`, `lib/lain/agent/stop_reason.rb`, `spec/lain/agent_spec.rb`, `spec/lain/agent/stop_reason_spec.rb`
**Reuse:** `StopReason.transport?` (`stop_reason.rb:83`); `Telemetry::ProviderRetry`; `configuration.rb:111` backoff values
**Shared-file wiring:** none
**Reachable from:** `Agent#attempt` (`agent.rb:773`) -> a transport retry around `model_caller.call`

**Acceptance criteria**

```gherkin
Scenario: an SSL EOF mid-run is retried
  Given a provider that raises Faraday::SSLError "unexpected eof" once, then answers
  When the agent takes a step
  Then the step completes, a provider_retry record is journaled, and the iteration count rises by 1, not 2

Scenario: a mid-stream EOF is retried from a fresh request
  Given a stream that ends early inside flush_stream once
  Then the step re-sends the same rendered request and shows no duplicate text

Scenario: retries are bounded
  Given a provider that always drops
  Then after 4 attempts with backoff the run stops with reason transport

Scenario: a 503 is Faraday's to retry
  Given a provider that answers 503
  Then the Agent does not retry it on top of Faraday's retries
```
Spec file: `spec/lain/agent_spec.rb`, `spec/lain/agent/stop_reason_spec.rb`

The Agent retries only `Faraday::SSLError` and a mid-stream EOF, through a new `StopReason.dropped?`. `StopReason.transport?` also covers 429, 5xx and `ConnectionFailed`, which Faraday already retries (`middleware_stack.rb:135,178-183`). Keying on it would multiply attempts, about 4 by 4.

**Stop and report if:**
- `spec/lain/provider/http/stall_protection_spec.rb` pins that a stall is not retried. Report it; a stall and a drop may need different answers.

### T30: Children report usage and context fill to the status bar          [risk: medium]

**Depends on:** T18, T23, T48
**Files:**
- `lib/lain/telemetry/child_progress.rb`, `lib/lain/tools/subagent/progress.rb`
- `lib/lain/status_feed.rb`, `lib/lain/status_feed/fleet.rb`, `lib/lain/status_feed/reading.rb`
- Specs: `spec/lain/telemetry/child_progress_spec.rb`, `spec/lain/status_feed_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`

**Reuse:** `Agent#occupancy`; `ContextWindow#occupancy` (`context_window.rb:448`); `Usage#+`
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent::Progress#turned` -> `ChildProgress(usage:, occupancy:, ceiling:)` -> `StatusFeed#observe` -> `Reading`

**Acceptance criteria**

```gherkin
Scenario: the fullest child shows beside fleet
  Given a dev at 41% of its window and a reviewer at 63%
  Then the status bar reads "fleet:2 max:63%" and ctx still shows only the main chat

Scenario: a child near its ceiling shows
  Given a reviewer at iteration 23 of 25
  Then its fleet row reads 23/25
```
Spec file: `spec/lain/status_feed_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`

**Stop and report if:**
- `frontend/neovim/status_view.rb:195-201` or `status_feed/fleet_windows.rb:361` match `ChildProgress` fields positionally. List them for a follow-up.

### T31: Fold usage by command and role          [risk: medium]

**Depends on:** T18, T23
**Files:**
- `lib/lain/journal/projection/usage.rb` (new)
- `lib/lain/cli/usage.rb` (new)
- `lib/lain/telemetry/turn_usage.rb`
- `lib/lain/agent/accounting.rb`
- `spec/fixtures/sessions/usage/round3_slice.ndjson` (new)
- Specs: `spec/lain/journal/projection/usage_spec.rb` (new), `spec/lain/cli/usage_spec.rb` (new), `spec/lain/telemetry/turn_usage_spec.rb`

**Reuse:** `Journal::Projection::Lineage`'s shape; `::Lain::Usage#+`, `::Lain::Usage.zero`; `spec/support/shared_examples/incremental_fold.rb`, `monoid_homomorphism.rb`
**Shared-file wiring:** `exe/lain`: `def usage(selector) = exit_status { Lain::CLI::Usage.new(selector:, sink: $stdout).run }` beside `watch` (line 1615)
**Reachable from:** `exe/lain usage` -> `CLI::Usage#run` -> `Journal::Projection::Usage.over(records)`

**Acceptance criteria**

```gherkin
Scenario: every usage record names its command and role
  Given /create-epic-issues running with a reviewer child
  Then each turn_usage record carries command "create-epic-issues" and the requester's role

Scenario: the round 3 table comes from lain
  Given the committed round3_slice.ndjson fixture
  When the human runs `lain usage <that file>`
  Then it prints input and output tokens per command and role, equal to the expected figures committed beside the fixture

Scenario: the fold is lawful
  Then the projection passes incremental_fold with combine, and folding halves then combining equals the whole
  And it reads turn_usage records only, so no usage is counted twice
```
Spec file: `spec/lain/journal/projection/usage_spec.rb`, `spec/lain/cli/usage_spec.rb`

Inside `Journal::Projection` and `CLI`, the class named `Usage` shadows `Lain::Usage`. Root-qualify `::Lain::Usage` there (the CLAUDE.md trap).

**Stop and report if:**
- `Accounting` cannot see the current command. Report where the skill's name is in scope.

### T32: Show sub-second tool times in ms          [risk: low]

**Depends on:** T1
**Files:** `lib/lain/frontend/decorators/tool_called.rb`, `spec/lain/frontend/decorators/tool_called_spec.rb`
**Reuse:** `ToolCalled#tail` (`tool_called.rb:28`)
**Shared-file wiring:** none
**Reachable from:** `Frontend::TTY` -> `Decorators::ToolCalled#tail`

**Acceptance criteria**

```gherkin
Scenario: a few milliseconds
  When a tool ends after 0.004 s
  Then the line ends "ok 4ms"

Scenario: just under a second
  When a tool ends after 0.9994 s
  Then the line ends "ok 999ms"

Scenario: over a second
  When a tool ends after 15.31 s
  Then the line ends "ok 15.3s"
```
Spec file: `spec/lain/frontend/decorators/tool_called_spec.rb`

**Stop and report if:**
- An e2e cassette under `spec/fixtures/vcr_cassettes/e2e/` asserts "0.0s". List it.

### Stream E: the epic

### T33: Signoff is a digest-keyed projection          [risk: high]

**Depends on:** T48
**Files:** `lib/lain/epic/signoff.rb` (new), `spec/lain/epic/signoff_spec.rb` (new)
**Reuse:** `SignoffQueue::Partition`; the `GateDecision` record from T48; `spec/support/shared_examples/incremental_fold.rb`
**Shared-file wiring:** none
**Reachable from:** `Epic::SignoffQueue.from_journal`, which T49 changes to read it

**Acceptance criteria**

```gherkin
Scenario: newest decision per partition wins
  Given an approve of issue a at D1 and then a deny of a at D1
  Then Signoff#standing(a) is Deny at D1

Scenario: a digest is part of the answer
  Given research approved at R1
  Then Signoff#approved?(research, R2) is false and Signoff#approved?(research, R1) is true

Scenario: the fold is lawful
  Then the projection passes incremental_fold with combine (right-biased merge per partition), and its states are Ractor.shareable?
```
Spec file: `spec/lain/epic/signoff_spec.rb`

**Interface**

```ruby
class Lain::Epic::Signoff   # a journal projection: .unit, .over(records), #step, #combine
  Standing = Data.define(:digest, :verdict)   # verdict: Approval::Verdict
  def standing(partition) = ...   # Standing or nil
  def approved?(partition, digest) = ...
end
```

**Stop and report if:**
- A deferred decision must be tracked here to keep `combine` a homomorphism. The park-and-drain half belongs to `SignoffQueue`; report it if it cannot stay out.

### T48: A gate decision records a Verdict, and every reader reads it          [risk: high]

**Depends on:** T8
**Files:**
- `lib/lain/epic/gate.rb`, `lib/lain/epic/signoff_queue.rb`, `lib/lain/epic/progress.rb`, `lib/lain/epic/gate/adjudicator.rb`
- `lib/lain/forge/local_landing.rb`
- `lib/lain/epic/submission.rb`, `lib/lain/epic/gate/policy.rb`
- `lib/lain/cli/epic.rb`, `lib/lain/cli/epic_queue.rb`, `lib/lain/cli/epic_submit.rb`
- `lib/lain/frontend/neovim/planning_view.rb`, `lib/lain/frontend/neovim/status_view.rb`
- `lib/lain/status_feed.rb`
- `lib/lain/telemetry/awaiting_human.rb`
- Specs, every spec that writes `approved` on a gate decision (`grep -rlE 'gate_decision|GateDecision' spec | xargs grep -l approved`, 2026-11-03):
  - `spec/journalable_surface_spec.rb`, `spec/lain/arm/epic_spec.rb`, `spec/lain/bench/epic_metrics_spec.rb`
  - `spec/lain/cli/epic_driver/factory_spec.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`, `spec/lain/cli/epic_driver/run_spec.rb`
  - `spec/lain/cli/epic_finish_spec.rb`, `spec/lain/cli/epic_land_spec.rb`, `spec/lain/cli/epic_mount_spec.rb`, `spec/lain/cli/epic_queue_spec.rb`, `spec/lain/cli/epic_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`
  - `spec/lain/cli/repl/ask_spec.rb`, `spec/lain/cli/resume/selector_spec.rb`, `spec/lain/cli/session_journals_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`
  - `spec/lain/epic/gate/adjudicator_spec.rb`, `spec/lain/epic/gate/policies_spec.rb`, `spec/lain/epic/gate/policy_spec.rb`, `spec/lain/epic/gate_registry_spec.rb`, `spec/lain/epic/gate_regression_spec.rb`, `spec/lain/epic/gate_spec.rb`
  - `spec/lain/epic/progress_spec.rb`, `spec/lain/epic/signoff_queue_spec.rb`, `spec/lain/epic/stage_spec.rb`, `spec/lain/epic/submission_spec.rb`
  - `spec/lain/forge/local_landing_spec.rb`
  - `spec/lain/frontend/neovim/planning_view_spec.rb`, `spec/lain/frontend/neovim/status_view_spec.rb`, `spec/lain/frontend/neovim/surfaces_spec.rb`
  - `spec/lain/status_feed_spec.rb`, `spec/lain/tools/epic_submit_spec.rb`

**Reuse:** `Epic::GateDecision` (`gate.rb:86`); `Approval::Verdict` (T6)
**Shared-file wiring:** none
**Reachable from:** `Epic::Gate#call` -> `GateDecision.new(verdict:)` -> the journal; each reader above

**Acceptance criteria**

```gherkin
Scenario: a decision carries its verdict
  When a gate decides Hold with a note
  Then the journaled gate_decision has verdict "hold" and the note, and no approved boolean

Scenario: hold is a type, not a surface string
  Then no file under lib/ compares a gate surface to "held"

Scenario: readers agree on a held issue
  Given a held issue
  Then lain epic status, the planning view, the status bar's inbox count and the landing approvals all show it held, not denied
```
Spec file: `spec/lain/epic/signoff_queue_spec.rb`, `spec/lain/forge/local_landing_spec.rb`, `spec/lain/cli/epic_queue_spec.rb`

**Stop and report if:**
- A spec outside this list writes `approved:` on a gate record under another key. Add it to the hand-back.

### T49: SignoffQueue, Gate and Stage read the Signoff projection          [risk: high]

**Depends on:** T11, T33
**Files:** `lib/lain/epic/signoff_queue.rb`, `lib/lain/epic/stage.rb`, `lib/lain/epic/gate.rb`, `lib/lain/epic/gate/policy.rb`, `lib/lain/cli/epic.rb`, `lib/lain/cli/epic_submit.rb`, `lib/lain/epic/progress.rb`, `lib/lain/forge/local_landing.rb`, `spec/lain/epic/signoff_queue_spec.rb`, `spec/lain/epic/progress_spec.rb`, `spec/lain/forge/local_landing_spec.rb`, `spec/lain/epic/stage_spec.rb`, `spec/lain/epic/gate_spec.rb`, `spec/lain/epic/gate/policy_spec.rb`
**Reuse:** `Epic::Signoff` (T33); `SignoffQueue#standing?`
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicSubmit` and `Epic::Stage#boundary` -> `SignoffQueue#standing?(partition, digest)` -> `Signoff#approved?`

**Acceptance criteria**

```gherkin
Scenario: an edited research.md does not open epic_plan
  Given research approved at digest R1
  When research.md is edited to digest R2
  Then epic_plan's stage boundary reports research unapproved at R2

Scenario: a deny revokes everywhere
  Given an issue approved at D and then denied at D
  Then Gate, SignoffQueue and lain epic status all answer not approved

Scenario: one fold of gate decisions
  Then LocalLanding::Approvals.from, CLI::EpicSubmit's latest, held? and expired, and Epic::Progress read Epic::Signoff, and no other lib/ file folds gate_decision records

Scenario: held_gate reads the newest decision
  Given an issue approved and then denied
  Then a graph edit of it is not refused as gated
```
Spec file: `spec/lain/epic/signoff_queue_spec.rb`, `spec/lain/epic/stage_spec.rb`, `spec/lain/epic/gate_spec.rb`

**Stop and report if:**
- `Adjudicator`'s refusal of a second terminal verdict (`adjudicator.rb:85-141`) is still needed once the projection revokes. Report whether to keep it.

### T34: A review result is bound to the digests it read          [risk: high]

**Depends on:** T8, T49
**Files:** `lib/lain/epic/review_result.rb` (new), `lib/lain/tools/epic_review.rb`, `lib/lain/tools/epic_submit.rb`, `lib/lain/epic/submission.rb`, `spec/lain/epic/review_result_spec.rb` (new), `spec/lain/tools/epic_review_spec.rb`, `spec/lain/tools/epic_submit_spec.rb`, `spec/lain/epic/submission_spec.rb`
**Reuse:** `Review::ReviewVerdict(verdict, changeset_digest)` (`review/review_verdict.rb:15`); `Submission.issue_plan` digests
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicMount` -> `Tools::EpicReview#call` -> journal `EpicReviewed`; `Tools::EpicSubmit#call(review: id)` -> `Submission#gate_question`

**Acceptance criteria**

```gherkin
Scenario: a stale verdict says so
  Given round 9's approve on epic.md at E9
  When epic.md is edited to E10 and submitted quoting round 9
  Then the gate question shows the verdict marked "reviewed E9, gating E10: stale"

Scenario: the gate shows the open findings
  Given a revise with 3 must-fix and 5 minor findings
  Then the gate question lists the 3 must-fix whole and counts the 5 minor, with no mid-list "..."

Scenario: submit takes a review id
  Then epic_submit's review input is the id of an EpicReviewed record, and free text is refused
```
Spec file: `spec/lain/epic/review_result_spec.rb`, `spec/lain/tools/epic_submit_spec.rb`

**Stop and report if:**
- The reviewer's free text has no machine-readable must-fix list. Then the card adds a closing block to the review instructions (`epic_review.rb:16-22`). Report the format first.

### T35: An edit to an approved artifact reopens its gate          [risk: medium]

**Depends on:** T49
**Files:** `lib/lain/tools/epic_write.rb`, `lib/lain/epic/home/journaled.rb`, `spec/lain/tools/epic_write_spec.rb`, `spec/lain/epic/home/journaled_spec.rb`
**Reuse:** `SignoffQueue#standing?`; `refuse_open_review!` (`journaled.rb:125-147`)
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicMount#epic_write` -> `Tools::EpicWrite#call` -> `Home::Journaled::Artifact#write`

**Acceptance criteria**

```gherkin
Scenario: rewriting an approved issue
  Given contract-types-ports approved at its wave gate
  When the agent rewrites it with epic_write
  Then a reopen decision is journaled, lain epic status shows it awaiting a gate, and the tool result says the issue needs resubmitting

Scenario: the next gate lists it
  When the agent submits the next wave
  Then the question lists contract-types-ports as reopened by an edit
```
Spec file: `spec/lain/tools/epic_write_spec.rb`

**Stop and report if:**
- A reopen must count as a deny in the fold, and `local_landing`'s `Approvals` reads it as a human deny. Report the record shape.

### T36: Record every human answer where the next agent can read it          [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/tools/ask_human.rb`, `lib/lain/telemetry/question_answered.rb` (new), `spec/lain/tools/ask_human_spec.rb`, `spec/lain/telemetry/question_answered_spec.rb` (new)
**Reuse:** `Telemetry::AwaitingHuman`, `QuestionsConsumed` (`ask_human.rb:829,844`); `Question::Answer`
**Shared-file wiring:** none
**Reachable from:** `Tools::AskHuman#call` -> journal `QuestionAnswered(question, answer, requester, epic_slug)`

**Acceptance criteria**

```gherkin
Scenario: a reviewer's question is on the record
  Given a reviewer in epic nyotes asks about owner blessings
  When the human answers "yes, both"
  Then the journal holds the question text, the answer text, the requester role and the slug

Scenario: a credential in an answer is withheld
  When the human answers with a line holding an API key
  Then the journaled answer masks the key, through the same filter the Intake uses for history
```
Spec file: `spec/lain/tools/ask_human_spec.rb`

**Stop and report if:**
- The Intake's credential filter cannot be reached from `ask_human`. Report where it lives.

### T37: Give epic_review a context pack and a round cap          [risk: high]

**Depends on:** T34, T36
**Files:** `lib/lain/tools/epic_review.rb`, `lib/lain/review/critique/documents.rb`, `lib/lain/epic/review_pack.rb` (new), `spec/lain/tools/epic_review_spec.rb`, `spec/lain/epic/review_pack_spec.rb` (new), `spec/lain/review/critique/documents_spec.rb`
**Reuse:** `Epic::Graph#waves`, `#blocked_by`, `#blockers`; `Brief#to_s`; `EpicReviewed` from T34; `QuestionAnswered` from T36
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicMount` -> `Tools::EpicReview#call` -> `Epic::ReviewPack.for(graph, home, journal, stage:, wave:)` -> `Documents`

**Acceptance criteria**

```gherkin
Scenario: the reviewer knows the layout
  Given wave 3 of 6 under review
  Then the pack lists every wave's ids, marks which are written, and says the verdict covers wave 3's ids only
  And a reference to a wave 5 issue is judged against epic.md, not reported missing

Scenario: answered questions are evidence
  Given the human answered the owner-blessing question in round 6
  Then rounds 7 and later receive it in the pack

Scenario: a second round reads the diff
  Given round 1's findings and the files changed since
  Then round 2's pack carries round 1's findings and the diff, and the issue files unchanged since round 1 only by digest

Scenario: rounds are capped
  Given 2 rounds already run on wave 3
  When the agent calls epic_review again for wave 3
  Then the tool refuses, telling it to submit and quote the open findings
```
Spec file: `spec/lain/epic/review_pack_spec.rb`, `spec/lain/tools/epic_review_spec.rb`

**Interface**

```ruby
Epic::ReviewPack = Data.define(:layout, :scope_ids, :answers, :prior, :diff)
Epic::ReviewPack.for(graph, home, journal, stage:, wave:)  # -> ReviewPack
Tools::EpicReview::ROUNDS = 2
```

**Stop and report if:**
- `Documents` inlines every file (`documents.rb:140-160`) and the pack does not shrink a round 2 request. Measure the round 2 request bytes before and after on the nyotes epic home; report if the cut is under 30%.

### T38: Read epic status and issues through tools          [risk: medium]

**Depends on:** T1, T48
**Files:**
- `lib/lain/tools/epic_status.rb` (new), `lib/lain/tools/epic_show.rb` (new)
- `lib/lain/cli/epic_mount.rb`
- `lib/lain/prompt/templates/skill/plan-epic/skill.md`, `lib/lain/prompt/templates/skill/create-epic-issues/skill.md`
- Specs: `spec/lain/tools/epic_status_spec.rb` (new), `spec/lain/tools/epic_show_spec.rb` (new), `spec/lain/cli/epic_mount_spec.rb`, `spec/lain/skill/shipped_skills_spec.rb`

**Reuse:** `CLI::Epic#status`, `#show`, `#progress` (`cli/epic.rb:206-223`)
**Shared-file wiring:** none
**Reachable from:** `CLI::EpicMount` -> `[Tools::EpicStatus.new(homes:), Tools::EpicShow.new(homes:)]` beside `EpicWrite` (`epic_mount.rb:46`)

**Acceptance criteria**

```gherkin
Scenario: the skill reads waves without bash
  Given a mounted chat
  When the agent calls epic_status
  Then it gets the stage, the waves with their ids and the gate state, with no bash call and no park

Scenario: an issue view without bash
  When the agent calls epic_show with id store-crate
  Then it gets the rendered issue view

Scenario: the skills name the tools
  Then plan-epic and create-epic-issues name epic_status and epic_show, and neither tells the agent to run `lain epic`
```
Spec file: `spec/lain/tools/epic_status_spec.rb`, `spec/lain/skill/shipped_skills_spec.rb`

**Stop and report if:**
- `CLI::Epic#status` writes to `$stdout` (output discipline). It must return a String; report it if it does not.

### T39: End /create-epic-issues with a readiness check          [risk: medium]

**Depends on:** T4, T38
**Files:** `lib/lain/epic/readiness.rb` (new), `lib/lain/tools/epic_status.rb` (created by T38), `lib/lain/prompt/templates/skill/create-epic-issues/skill.md`, `spec/lain/epic/readiness_spec.rb` (new), `spec/lain/tools/epic_status_spec.rb` (created by T38)
**Reuse:** `PlanSubject.of`; `Acceptance.of` (T4); `Config.test_layout`; `TestLayout::Mapping#test_path`
**Shared-file wiring:** none
**Reachable from:** `Tools::EpicStatus#call(readiness: true)` -> `Epic::Readiness.of(graph, layout, mount)`

**Acceptance criteria**

```gherkin
Scenario: an unplaceable issue is named before implementation
  Given a cargo layout and an issue whose Subject is Cargo.toml at Level unit
  When readiness runs
  Then it reports that issue unplaceable with the layout's reason, and the counts of tested and manual issues

Scenario: a missing layout names the line to add
  Given no tests line in .lain/config.rb and a Cargo.toml subject
  Then readiness reports the missing layout and proposes "tests preset: :cargo, source_roots: [...]" from the issues' subjects

Scenario: the skill closes on it
  Then create-epic-issues' last step calls epic_status with readiness and quotes its result
```
Spec file: `spec/lain/epic/readiness_spec.rb`

**Stop and report if:**
- `PlanSubject.of` needs the driver's factory to run. Readiness must not start a driver; report the coupling.

### T40: /clear restarts the chat fresh in the same cockpit          [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/cli/command/clear.rb` (new), `lib/lain/cli/command/registry.rb`, `lib/lain/cli/up.rb`, `spec/lain/cli/command/clear_spec.rb` (new), `spec/lain/cli/up_spec.rb`
**Reuse:** `Up#run_chat` (`up.rb:1325-1329`, `respawn-pane -k`); the socket naming (`up.rb:1206`); `CLI::EpicMount` resolution
**Shared-file wiring:** `docs/commands.md`: `/clear`
**Reachable from:** `CLI::Command::Registry` -> `Command::Clear#call` -> `Up.respawn_chat(session)`

**Acceptance criteria**

```gherkin
Scenario: clear then implement
  Given a cockpit whose chat ran /create-epic-issues
  When the human types "/clear"
  Then the chat pane restarts with a fresh session file, the input and nvim panes stay, and the epic is mounted again

Scenario: outside a cockpit
  Given a plain `lain chat`
  When the human types "/clear"
  Then it refuses, naming /rewind 0 as the in-place way to empty the context
```
Spec file: `spec/lain/cli/command/clear_spec.rb`

**Stop and report if:**
- The chat process cannot ask its own tmux server to respawn its pane without killing itself mid-reply. Report the sequencing.

### T41: The ask_human question shows whole in the chat pane          [risk: low]

**Depends on:** T1
**Files:** `lib/lain/frontend/tty.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** `TTY#arrival`, `#announce` (`tty.rb:806-809`); `InboxRow.one_line`
**Shared-file wiring:** none
**Reachable from:** `Frontend::TTY#announce` -> the question's lines

**Acceptance criteria**

```gherkin
Scenario: a 4-line question
  Given a dev asks "approve, alt-path, or skip?" with 3 lines of context
  Then the chat pane shows all 4 lines under the "?" marker, each wrapped to the pane width
```
Spec file: `spec/lain/frontend/tty_spec.rb`

**Stop and report if:**
- `tty.rb`'s `one_line` exists to stop a control character from scribbling the pane. Keep the control-character strip and drop only the line join.

### Stream S: redaction

### T42: Model ids are not secrets          [risk: low]

**Depends on:** T1
**Files:** `lib/lain/sensitivity/entropy.rb`, `spec/lain/sensitivity/entropy_spec.rb`
**Reuse:** `predictable?`, `slash_joined_words?`, `WORD_SEGMENT`
**Shared-file wiring:** none
**Reachable from:** `Sensitivity::Regions.detect` -> `Entropy.high?`

**Acceptance criteria**

```gherkin
Scenario: a GGUF model id
  Then Entropy.high?("bartowski/GLM-4-9B-Chat-GGUF") is false

Scenario: a mixed-case org and model id
  Then Entropy.high?("HuggingFaceTB/SmolLM2-360M-Instruct-GGUF") is false

Scenario: a real token is still flagged
  Then Entropy.high?("ghp_6Fz9qL2vX8mN4pR7tY1wK3sD5hJ0aB2cE4gI") is true
```
Spec file: `spec/lain/sensitivity/entropy_spec.rb`

**Stop and report if:**
- A credential fixture in `spec/lain/sensitivity/` matches the new shape. Report it.

### T43: An approved bash read releases the files it names          [risk: high]

**Depends on:** T1
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/sensitivity/ledger.rb`, `lib/lain/sensitivity/text_mask.rb`, `spec/lain/sensitivity/ledger_spec.rb`, `spec/lain/sensitivity/text_mask_spec.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`
**Reuse:** `Ledger#release`, `#released?`; `RedactSecretReads#adjudicate`; `Shell::Named` paths
**Shared-file wiring:** none
**Reachable from:** `CLI::ToolGuard` stack -> `Middleware::RedactSecretReads#guarded` -> `printed` with the call's approved paths

**Acceptance criteria**

```gherkin
Scenario: an approved cat returns its bytes
  Given a human approved `cat .lain/config.rb`
  When the output holds a high-entropy value from that file
  Then the agent sees the bytes, and a ReadReleased record names the path

Scenario: the release is per path
  Given that release
  When another command prints the same value from another file
  Then it is masked

Scenario: a judged approve releases nothing
  Given the judge approved the same cat
  Then the output is masked as today
```
Spec file: `spec/lain/sensitivity/ledger_spec.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`

**Stop and report if:**
- `TextMask` and `Regions` digest a region differently. Then a release cannot match. Report the 2 functions.

### T44: Exempt lockfiles by pattern          [risk: low]

**Depends on:** T1
**Files:** `lib/lain/sensitivity.rb`, `spec/lain/sensitivity_spec.rb`
**Reuse:** `CHECKSUMS`, `Rule.named` (`sensitivity.rb:918-919`)
**Shared-file wiring:** none
**Reachable from:** `Sensitivity::Policy` -> `Sensitivity::Rules#classify`

**Acceptance criteria**

```gherkin
Scenario: the newer lockfiles hold checksums
  Then checksums? is true for uv.lock, flake.lock, Package.resolved, mix.lock, pubspec.lock, deno.lock, go.work.sum and .terraform.lock.hcl
```
Spec file: `spec/lain/sensitivity_spec.rb`

**Stop and report if:**
- `sensitivity_spec.rb:795-797` pins `flake.lock` as not checksums for a stated reason. Report the reason before flipping it.

### Stream C: tokens

### T45: Compact earlier when the provider caches nothing          [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/cli/compaction_profile.rb`, `lib/lain/cli/compaction_mount.rb`, `spec/lain/cli/compaction_profile_spec.rb`, `spec/lain/cli/compaction_mount_spec.rb`
**Reuse:** `CacheProfile::NO_CACHING`; `WINDOW_DIVISOR` (`compaction_profile.rb:24`); `Need.new(byte_threshold:)`
**Shared-file wiring:** none
**Reachable from:** `CLI::CompactionMount` -> `CompactionProfile#need(cache_profile:)`

**Acceptance criteria**

```gherkin
Scenario: no cache, smaller head
  Given a provider whose cache profile is NO_CACHING and a 131072-token window
  Then the byte threshold is a window/8 share, half the cached provider's window/4

Scenario: a caching provider is unchanged
  Given the Anthropic profile
  Then the threshold is window/4 as today

Scenario: an explicit --compact-bytes wins
  Then the flag's value is used for either profile
```
Spec file: `spec/lain/cli/compaction_profile_spec.rb`

**Stop and report if:**
- The summarizer's own cost on the local model makes window/8 a net loss on the round 3 replay. Measure 1 nyotes session with `Bench::CompactionSweep` before landing, in tokens and in wall time (a local ollama reuses its KV prefix, so an earlier compaction costs prefill time), and report if the token saving is under 10% or the wall time grows.

### T46: Pin the monoid laws on Usage, Spent and Masked          [risk: low]

**Depends on:** T1
**Files:** `spec/lain/usage_spec.rb`, `spec/lain/budget/spent_spec.rb`, `spec/lain/sensitivity/masked_spec.rb`, `lib/lain/sensitivity/masked.rb`
**Reuse:** `spec/support/shared_examples/monoid.rb`; `Usage.zero`, `Spent.zero`, `Masked.plain("")`
**Shared-file wiring:** none
**Reachable from:** deferred: law specs over values already on the production path (see Open decisions); `Masked` gains a named `ZERO` only if the law needs one

**Acceptance criteria**

```gherkin
Scenario: the three are monoids
  Then Usage, Budget::Spent and Sensitivity::Masked each pass the shared monoid group over generated values
```
Spec file: `spec/lain/usage_spec.rb`, `spec/lain/budget/spent_spec.rb`, `spec/lain/sensitivity/masked_spec.rb`

**Stop and report if:**
- A law fails. That is a production defect: report it with the counterexample, and do not weaken the law.

### T47: Name lain's epic home in the chat's first context          [risk: low]

**Depends on:** T38
**Files:** `lib/lain/cli/epic_mount.rb`, `spec/lain/cli/epic_mount_spec.rb`
**Reuse:** the mount's `homes:`
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` -> `CLI::EpicMount` -> the workspace line it renders

**Acceptance criteria**

```gherkin
Scenario: a fresh chat finds its epic
  Given a chat mounted on nyotes
  Then the rendered workspace names the epic slug, its home path and the epic tools, so the agent never guesses .lain/epics/nyotes
```
Spec file: `spec/lain/cli/epic_mount_spec.rb`

**Stop and report if:**
- The workspace render is pure (`Context#render`) and the mount cannot reach it without breaking purity. Report the seam.

### Stream P: answering from the phone

The user pulled the remote surface into this plan on 2026-11-03 ("we will see fewer of those [holds] if we consider pulling that in as one chunk of functionality here"). The scope is approve plus context, and the wake path is a self-hosted ntfy. The design follows `planning/remote-surface-research-2026-08.md` §6.2 and §10, re-grounded at `644ec6ae` and reviewed by 2 panels:
- **Each phone is a paired device** with its own token, revocable at once (T60).
- **The relay is lain-core,** per the 2026-10-17 ruling. It gets a frame ceiling and an auth deadline (T50), then a `relay` subcommand bound to a tailnet address (T52). Ruby dials it over a Unix socket, and the phone dials it over the tailnet.
- **Push in both directions is long-poll methods,** so the request and response contract does not change.
- **The phone answers at the asking rung,** like the terminal, with authority `:human` and surface `"remote"`. The August research's rung model (`AutoSurface`, `Notify`, `Risk`, `alters_outcome?`) was deleted (`b24b2e62`, `c40ab419`, `46582847`).
- **The app lives in its own repo,** `~/dev/lain-remote`, as belle-curves and pitchcraft do. Dioxus pulls `nu-ansi-term`, which `deny.toml` bans workspace-wide. Only `lain-wire` is shared, as a git dependency pinned to a commit.
- **An ntfy notification carries only "Open"**, a deep link into the app. Every answer is given in the app, and the notification never carries input text or a token.

Cards T50 to T57 are Rust or Ruby in this repo. T58 and T59 run in `~/dev/lain-remote`, and their commits land there.

### T50: Harden lain-core's RPC for a network peer          [risk: high]

**Depends on:** T1
**Files:** `crates/lain-core/src/rpc.rs`, `crates/lain-core/src/main.rs`, `crates/lain-core/tests/lifecycle.rs`
**Reuse:** `Codec`, the envelope, `Accept`, `serve`, the test-only TCP `Accept` (`rpc.rs:53-92,144,165,279-290,388-400,617`)
**Shared-file wiring:** none
**Reachable from:** `crates/lain-core/src/main.rs` -> `serve(listener, handler)`

**Acceptance criteria**

```gherkin
Scenario: a frame has a ceiling
  Given lain-core listening
  When a client sends 96 MiB of one unfinished str32 frame
  Then the connection is closed once the frame passes the ceiling (1 MiB), and the codec's buffered byte count never exceeds the ceiling

Scenario: decoding is linear
  When a 1 MiB frame arrives in 4 KiB reads
  Then a counting decoder reports under 2 MiB of bytes scanned in total

Scenario: a handler seam
  Given serve(listener, handler) with a handler that answers "ping" and "echo"
  Then both answer, an unknown method answers UnknownMethod, and ping still reports lain-core's own version

Scenario: an auth deadline
  Given a connection whose handler requires a hello
  When no hello arrives within 5 s
  Then the connection is closed
```
Spec file: `crates/lain-core/src/rpc.rs` (its `#[cfg(test)]` module), `crates/lain-core/tests/lifecycle.rs`

The 2026-10-17 ruling keeps lain-core as the wire seed for the phone relay (`ARCHITECTURE.md:2326-2329`, `crates/lain-core/src/main.rs:3-5`). So the relay grows inside lain-core (T52), and no new RPC crate is made. The panel's probe grew lain-core's memory from 4 MiB to 116 MiB with 1 unfinished frame (`r2_codec_unbounded_frame_probe.rb`). That was harmless on a same-user Unix socket, and it is not harmless on a tailnet.

**Stop and report if:**
- The Ruby `Core::Client`'s `PROTOCOL_VERSION` pin (`lib/lain/core/client.rb:18`) must move. Report it; a ping version change breaks `spec/support/core_daemon.rb`.

### T51: Define the wire types the phone and lain share          [risk: medium]

**Depends on:** T6
**Files:** `crates/lain-wire/Cargo.toml` (new), `crates/lain-wire/src/lib.rs` (new), `crates/lain-wire/tests/fixtures/` (new)
**Reuse:** serde with `rmp-serde`
**Shared-file wiring:** root `Cargo.toml`: add `"./crates/lain-wire"` to `members`
**Reachable from:** `crates/lain-core` (T52) and the app's client crate (T58), the 2 places that encode and decode it

**Acceptance criteria**

```gherkin
Scenario: every message round-trips
  Given each Hello, AgendaItem variant, Delta and Answer variant
  When it is encoded to msgpack and decoded
  Then it equals the original, and encodes to the bytes committed in crates/lain-wire/tests/fixtures/

Scenario: a wave gate is one item
  Given a wave gate for issues a, b and c
  Then it is 1 GateQuestion carrying 3 issue ids, and its Answer carries a verdict per issue id
```
Spec file: `crates/lain-wire/src/lib.rs` (its `#[cfg(test)]` module)

**Interface**

```rust
pub struct Hello { pub wire_version: u32, pub token: String, pub cursor: u64 }
pub enum AgendaItem {
    ParkedCall { id: String, requester: String, tool: String, input: String, cwd: String, why: String, postponed: bool, asked_at: i64 },
    GateQuestion { id: String, requester: String, epic: String, stage: String, issues: Vec<String>, question: String, asked_at: i64 },
    Question { id: String, requester: String, question: String, options: Vec<String>, asked_at: i64 },
}
pub enum Verdict { Approve { note: Option<String> }, Hold { note: Option<String> }, Deny { note: Option<String> } }
pub enum Answer {
    Call { id: String, verdict: Verdict },
    Gate { id: String, verdicts: Vec<(String, Verdict)> },        // per issue id
    Question { id: String, option: Option<String>, text: Option<String> },
}
pub struct Delta { pub cursor: u64, pub added: Vec<AgendaItem>, pub settled: Vec<String> }
pub const WIRE_VERSION: u32 = 1;
```

**Stop and report if:**
- `rmp-serde`'s encoding of an enum differs from what Ruby's `msgpack` gem can produce for the same fixture. Pin a map encoding on both sides and report it.

### T52: lain-core serves the phone over the tailnet          [risk: high]

**Depends on:** T50, T51
**Files:** `crates/lain-core/src/main.rs`, `crates/lain-core/src/relay.rs` (new), `crates/lain-core/src/relay/agenda.rs` (new), `crates/lain-core/Cargo.toml`
**Reuse:** `serve(listener, handler)` and the auth deadline (T50); `lain_wire`; lain-core's `forbid(unsafe_code)` and output-discipline lints (`main.rs:11-12`)
**Shared-file wiring:** none
**Reachable from:** `lain up` (T57) -> `lain-core relay --unix <sock> --listen <addr>:<port> --token-file <path>`

**Acceptance criteria**

```gherkin
Scenario: the relay binds only a tailnet or loopback address
  When it is started with --listen 0.0.0.0:7820, a LAN address such as 192.168.1.5:7820, or a 100.64.0.0/10 address that is not this host's tailscale0 address
  Then it exits non-zero, naming the rule: this host's own tailscale0 address, or loopback for tests

Scenario: a phone without the token is refused
  Given a relay on 127.0.0.1 for the test
  When a client sends a Hello with a wrong token
  Then the connection is closed before any agenda item is sent, and the token is compared with a constant-time function (the subtle crate's ConstantTimeEq)

Scenario: the phone cannot publish
  When a TCP client calls agenda.publish or answers.next
  Then it gets UnknownMethod: the Unix handler serves lain's methods, and the TCP handler serves only hello, agenda.next and answer.send

Scenario: an answer settles once
  When a phone replays an answer.send for an id already settled
  Then the relay answers already-settled, and lain sees 1 answer

Scenario: the relay confines itself
  Then after binding, the relay process holds a Landlock ruleset that allows reading only its devices file and writing only its Unix socket's directory

Scenario: lain publishes, the phone long-polls, the phone answers
  Given lain connected on the unix socket and a phone client on TCP with the token
  When lain calls agenda.publish with a Delta adding a ParkedCall
  Then the phone's pending agenda.next(cursor) call returns it
  And the phone's answer.send reaches lain's pending answers.next call

Scenario: a reconnecting phone resumes
  Given a phone that saw cursor 7 and dropped
  When it calls agenda.next(7) after reconnecting
  Then it receives only the deltas after 7

Scenario: the version is checked
  When a phone sends Hello with wire_version 2
  Then the relay answers an error naming both versions, and keeps serving version 1 clients
```
Spec file: `crates/lain-core/src/relay.rs` (its `#[cfg(test)]` module, a loopback seam)

Push in either direction uses long-poll methods (`agenda.next(cursor)`, `answers.next(cursor)`). They fit the existing out-of-order, msgid-demuxed request and response contract. Notification frames stay refused (`rpc.rs:20-23`), and `Core::Client#deliver` keeps dropping non-response frames (`client.rb:216-220`).

**Stop and report if:**
- A long-poll held open blocks `serve`'s other requests on the same connection. Out-of-order completion is pinned by `rpc.rs`'s sleep test; report it if that test does not cover it.

### T53: One agenda of everything waiting on a human          [risk: high]

**Depends on:** T9, T48
**Files:** `lib/lain/remote/agenda.rb` (new), `spec/lain/remote/agenda_spec.rb` (new)
**Reuse:** `Approval::Parked::Queue#each` and `Approval::Postponed` (T9); `CLI::HumanReplies` and its `InboxItem` (`human_replies.rb:21`); the poll shape of `Approval::Parked::QueueSurface` (`parked/queue_surface.rb:21,62`)
**Shared-file wiring:** none
**Reachable from:** `Approval::RemoteSurface` (T55) -> `Remote::Agenda.new(queue:, postponed:, replies:)`

**Acceptance criteria**

```gherkin
Scenario: the agenda lists every kind
  Given a parked bash call, a postponed call, a deferred wave gate and an ask_human question
  Then a snapshot lists 4 items: 2 ParkedCall (1 postponed), 1 GateQuestion and 1 Question

Scenario: answering routes to the owner
  When the agenda answers the gate item with Deny(note: "wrong crate") for issue b
  Then the gate records that deny for b, as it would from /inbox

Scenario: a settled item leaves
  When the bash call is approved at the desk
  Then the next delta settles its id

Scenario: deltas replay to the present
  Given the deltas since cursor 0
  When they are applied in order to an empty item set
  Then the result equals the current snapshot, from any starting cursor and its snapshot
```
Spec file: `spec/lain/remote/agenda_spec.rb`

**Interface**

```ruby
module Lain::Remote
  class Agenda   # polls; not a journal projection, because a parked call's input is never journaled (queue.rb:375-379)
    ParkedCall   = Data.define(:id, :requester, :tool, :input, :cwd, :why, :postponed, :asked_at)
    GateQuestion = Data.define(:id, :requester, :epic, :stage, :issues, :question, :asked_at)
    Question     = Data.define(:id, :requester, :question, :options, :asked_at)
    def snapshot = ...                 # frozen items, each with a minted id
    def delta_since(cursor) = ...      # [cursor', added, settled]; cursor is a generation counter
    def answer(id, answer) = ...       # routes to Pending#decide, the gate, or the question's directory
  end
end
```

Ids are minted per item, because a `tool_use_id` can park twice (`queue.rb:381-384`). The agenda has 1 reader, the remote surface. `/inbox`, `lain://inbox` and the status bar's count keep their own lists; moving them onto the agenda is not in this plan.

**Stop and report if:**
- A deferred epic gate is not reachable from `HumanReplies` in a chat that did not raise it. Report where the gate's question lives.

### T54: Show the phone a masked view of each item          [risk: high]

**Depends on:** T53
**Files:** `lib/lain/remote/agenda/view.rb` (new), `spec/lain/remote/agenda/view_spec.rb` (new)
**Reuse:** the board's secrets source (`cli/wiring/board_build.rb:242`, `Sensitivity::HistoryLiterals` and the child env); `Sensitivity::TextMask` for those known values; `Sensitivity::Regions.detect` for a literal typed into a command; `Pending#outstanding` (`queue.rb:153`)
**Shared-file wiring:** none
**Reachable from:** `Approval::RemoteSurface#publish` -> `Remote::Agenda::View.of(item, secrets:)`

**Acceptance criteria**

```gherkin
Scenario: a known secret in a command is masked
  Given a parked bash call whose input holds a value from the board's secrets
  Then the remote view masks it, with the rest of the command intact

Scenario: a literal key in a command is masked
  Given a parked bash call with "curl -H 'Authorization: Bearer ghp_6Fz9qL2vX8mN4pR7tY1wK3sD5hJ0aB2cE4gI'"
  Then the remote view masks the token, by the region detector

Scenario: secret releases stay at the desk
  Given a parked read_file with outstanding regions
  Then the remote view omits it, and the desk still shows it

Scenario: a humans-only call goes to the phone
  Given a pending whose humans_only? is true
  Then the remote view includes it, because humans_only? bars an oracle and the phone is a human
```
Spec file: `spec/lain/remote/agenda/view_spec.rb`

**Stop and report if:**
- `Regions.detect` flags so much of an ordinary command that the view is unreadable. Report the shapes.

### T55: The phone answers at the asking rung          [risk: high]

**Depends on:** T11, T18, T52, T54
**Files:**
- `lib/lain/approval/remote_surface.rb` (new), `lib/lain/remote/wire.rb` (new), `lib/lain/core/transport/unix.rb` (new)
- `lib/lain/cli/repl/approval_surfaces.rb`, `lib/lain/cli/repl.rb`, `lib/lain/cli/wiring.rb`
- `lib/lain/config.rb`, `lib/lain/config/builder.rb`
- `spec/fixtures/wire/` (new)
- Specs: `spec/lain/approval/remote_surface_spec.rb` (new), `spec/lain/remote/wire_spec.rb` (new), `spec/lain/core/transport/unix_spec.rb` (new), `spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/cli/repl_spec.rb`, `spec/lain/config_spec.rb`

**Reuse:** `Approval::Parked::QueueSurface#watch` (`parked/queue_surface.rb:21,62`); `Core::Client` (`lib/lain/core/client.rb:14`); `Remote::Agenda`, `Remote::Agenda::View`; the `Repl` -> `ApprovalSurfaces` path (`wiring.rb:972`, `repl.rb:125-126`)
**Shared-file wiring:** `docs/commands.md`: `remote relay:` and `remote ntfy:` config keys
**Reachable from:** `CLI::Wiring#repl_over` -> `Repl.new(remote:)` -> `ApprovalSurfaces.new(remote:)` -> `#watch` (`approval_surfaces.rb:73`) -> `Approval::RemoteSurface` when `remote relay:` is set

**Acceptance criteria**

```gherkin
Scenario: a parked call answered from the phone
  Given remote relay set and a loopback lain-core relay with a test client
  When a bash call parks
  Then the client receives it, and its Approve runs the call with authority human and surface "remote" in the escalation record

Scenario: the first answer wins
  When the desk and the phone both answer the same call
  Then the first answer settles it, and the other gets "already settled"

Scenario: Ruby and Rust encode alike
  Then the Ruby encoding of each wire fixture equals the bytes in crates/lain-wire/tests/fixtures/

Scenario: no relay, no surface
  Given remote relay unset
  Then ApprovalSurfaces#watch returns the same surfaces it returns today

Scenario: a dead relay degrades
  Given the relay is down
  Then the desk keeps working, and a capability_degraded record names the remote surface
```
Spec file: `spec/lain/approval/remote_surface_spec.rb`, `spec/lain/cli/repl/approval_surfaces_spec.rb`

`spec/lain/approval/remote_surface_spec.rb` is a seam against the built relay. Gate it like the `:core` tier, and list it in `spec/support/slow_files.rb` through the main session.

**Stop and report if:**
- The remote surface needs the board's secrets (`board_build.rb:242`) and they do not reach `Repl`. Report the path they take.

### T56: Buzz the phone through ntfy when something waits          [risk: medium]

**Depends on:** T55
**Files:** `lib/lain/remote/ntfy.rb` (new), `lib/lain/approval/remote_surface.rb` (created by T55), `spec/lain/remote/ntfy_spec.rb` (new), `spec/lain/approval/remote_surface_spec.rb` (created by T55)
**Reuse:** `Remote::Agenda#delta_since`; `Net::HTTP`
**Shared-file wiring:** none
**Reachable from:** `Approval::RemoteSurface` -> `Remote::Ntfy#notify(item)` when `remote ntfy:` is set

**Acceptance criteria**

```gherkin
Scenario: an unanswered item buzzes after the delay
  Given remote ntfy "http://100.101.102.103:8090/lain-x7" and a delay of 60 s
  When a call has waited 60 s unanswered
  Then one POST reaches the topic with a title naming the kind and the requester, and no input text

Scenario: the notice carries 1 action and no secret
  Then its only action is "Open", a view action to lain-remote://item/<id>
  And neither the relay token nor any input text appears in the message

Scenario: an item answered first does not buzz
  When the call is answered at the desk at 30 s
  Then no POST is sent
```
Spec file: `spec/lain/remote/ntfy_spec.rb`

Per the user's ruling of 2026-11-03, the notification opens the app, and every answer is given there. The relay grows no HTTP surface.

**Stop and report if:**
- ntfy rejects a view action whose URL scheme is not http or https. Then link to the app's intent URL, and report it.

### T57: lain up runs the relay in its own pane          [risk: medium]

**Depends on:** T40, T52, T55
**Files:** `lib/lain/cli/up.rb`, `spec/lain/cli/up_spec.rb`
**Reuse:** `Up`'s pane layout; `Gateway::TokenFile` (`lib/lain/gateway/token_file.rb`)
**Shared-file wiring:** none
**Reachable from:** `exe/lain up` -> `CLI::Up#run` -> a hidden tmux window running `lain-core relay`

**Acceptance criteria**

```gherkin
Scenario: the relay runs with the cockpit
  Given remote relay "100.64.0.1:7820" in .lain/config.rb
  When `lain up` starts
  Then a tmux window in the cockpit session runs the relay, and killing the session stops it

Scenario: pairing survives a restart
  Given a token file written on the first lain up
  When the cockpit restarts
  Then the relay reads the same token, and the phone does not pair again

Scenario: a missing tailnet address is named
  Given the address is not on any local interface
  Then lain up says so and starts without the relay
```
Spec file: `spec/lain/cli/up_spec.rb`

`lain up` ends in `Kernel.exec` of tmux attach (`up.rb:204,263`), so it cannot own a child. The tmux session owns the relay, as it owns the chat pane.

**Stop and report if:**
- `rake core:build` does not put `lain-core` where `lain up` can find it. Report which path it should use.

### T58: Start the lain-remote app with a tested client core          [risk: medium]

**Depends on:** T52
**Files:** `~/dev/lain-remote/Cargo.toml` (new), `~/dev/lain-remote/Dioxus.toml` (new), `~/dev/lain-remote/src/main.rs` (new), `~/dev/lain-remote/src/client.rs` (new), `~/dev/lain-remote/CLAUDE.md` (new)
**Reuse:** belle-curves' Dioxus 0.7 setup (`~/dev/belle-curves/Cargo.toml`, `Dioxus.toml`, `CLAUDE.md`); `lain-wire` as a git dependency pinned to a commit
**Shared-file wiring:** none
**Reachable from:** the app's `main` -> `client::Session::connect(addr, token)`

**Acceptance criteria**

```gherkin
Scenario: the client core runs against a loopback relay
  Given lain-core's relay on 127.0.0.1 with a token, found through LAIN_CORE_BIN (default ~/dev/lain/target/debug/lain-core)
  When `cargo test` runs in ~/dev/lain-remote
  Then the client connects, lists a published item, answers it, and resumes from its cursor after a forced drop

Scenario: the desktop build runs
  Then `dx build --platform desktop` succeeds, or `cargo build` if dx is not installed
```
Spec file: `~/dev/lain-remote/src/client.rs` (its `#[cfg(test)]` module)

**Stop and report if:**
- `LAIN_CORE_BIN` is unset and the default path has no binary. The tests must skip with a message naming `rake core:build`, not fail.
- `dx` or the Android SDK is needed for the tests. They are not installed on this box (checked 2026-11-03). Keep the tests on the client core.

### T59: The app shows each item with its context and answers it          [risk: medium]

**Depends on:** T58
**Files:** `~/dev/lain-remote/src/ui/agenda.rs` (new), `~/dev/lain-remote/src/ui/item.rs` (new), `~/dev/lain-remote/src/ui/settings.rs` (new)
**Reuse:** `client::Session` (T58); belle-curves' component layout
**Shared-file wiring:** none
**Reachable from:** the app's `main` -> `App` -> the agenda route, and the deep link `lain-remote://item/<id>` -> the item route

**Acceptance criteria**

```gherkin
Scenario: the agenda lists what waits
  Given 3 published items
  Then the agenda screen lists them newest first, each with its kind, requester and age

Scenario: an item shows its context
  When the human opens a ParkedCall
  Then it shows the command, the cwd, the requester and the judge's or rung's reason

Scenario: an answer carries a note
  When the human taps Deny and types "wrong tree"
  Then the relay receives Deny(note: "wrong tree") for that id

Scenario: a deep link opens the item
  When the app opens from lain-remote://item/<id>
  Then the item's screen shows, after connecting
```
Spec file: `~/dev/lain-remote/src/ui/item.rs` (its `#[cfg(test)]` module, over the view state, not the renderer)

**Stop and report if:**
- Dioxus 0.7 mobile has no deep-link hook without platform code. Report it and leave deep links to the manual pass.

### T60: Pair and revoke a phone          [risk: high]

**Depends on:** T52
**Files:** `lib/lain/cli/remote.rb` (new), `lib/lain/remote/devices.rb` (new), `crates/lain-core/src/relay/devices.rs` (new), `spec/lain/cli/remote_spec.rb` (new), `spec/lain/remote/devices_spec.rb` (new)
**Reuse:** `Gateway::TokenFile`'s file mode and atomic write (`lib/lain/gateway/token_file.rb`); `AtomicFile`
**Shared-file wiring:** `exe/lain`: `def remote(verb, name = nil) = exit_status { Lain::CLI::Remote.new(verb:, name:, sink: $stdout).run }`
**Reachable from:** `exe/lain remote pair <name>` and `exe/lain remote revoke <name>` -> `CLI::Remote` -> `Remote::Devices` (the relay rereads the file on change)

**Acceptance criteria**

```gherkin
Scenario: pairing makes a device token
  When the human runs `lain remote pair pixel`
  Then a new random token for device "pixel" is written to the devices file with mode 0600, and printed once with the relay address for the app's settings

Scenario: a revoked device is refused at once
  Given device "pixel" paired and connected
  When the human runs `lain remote revoke pixel`
  Then the relay closes pixel's connection and refuses its next Hello, and other devices keep working

Scenario: answers name the device
  When pixel approves a call
  Then the escalation record's surface is "remote:pixel"

Scenario: a stored token is not the token
  Then the devices file holds a hash of each token, never the token
```
Spec file: `spec/lain/remote/devices_spec.rb`, `spec/lain/cli/remote_spec.rb`, `crates/lain-core/src/relay/devices.rs` (its `#[cfg(test)]` module)

**Stop and report if:**
- The relay cannot reread the devices file without a restart. Report the reload signal it needs.

### T61: A headless run masks a sensitive read nobody can release          [risk: high]

**Depends on:** T15, T43
**Files:** `lib/lain/middleware/redact_secret_reads.rb`, `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`
**Reuse:** `RedactSecretReads::Unqueued` (`redact_secret_reads.rb:113-125`); the approval ruling that a headless `auto` refuses what nobody settles
**Shared-file wiring:** none
**Reachable from:** `CLI::ToolGuard` (`--non-interactive`) -> `Middleware::RedactSecretReads.new(queue: Unqueued)`

**Acceptance criteria**

```gherkin
Scenario: no human, no release
  Given a --non-interactive run
  When read_file returns a file with a sensitive region
  Then the region is masked, the tool result says no human is attached to release it, and no read_released record is written

Scenario: the gate and the release agree
  Then a --non-interactive run denies at the gate and masks at the release, and tool_guard_spec pins both halves together
```
Spec file: `spec/lain/middleware/redact_secret_reads_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`

The comment at `redact_secret_reads.rb:113-125` calls this the last fail-open in a headless run and defers the flip to a measurement. The approval ruling already settles it: a headless run refuses what nobody settles.

**Stop and report if:**
- A bench or QA arm depends on a headless run reading sensitive bytes. List it.

## Integration checks

1. `bundle exec rake pspec` at a load under 8. Compare the example count with the start count plus the new examples, with 0 failures.
2. `bundle exec rubocop`, `bin/comment-census --check-tickets`, `bin/zeitwerk-census --check`, `bin/spec-census --check`.
3. `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo deny check` for `crates/lain-wire` and the grown `crates/lain-core`, and `bundle exec rake core:build && bundle exec rspec --tag core`.
4. `bin/hot-path-bench --check`. T29 touches the request path, and T15 and T16 touch the bash-call path.
5. The T20 replay over the round 2 and round 3 session journals (`~/.local/state/lain/sessions/9d832bf6a4ad/`, `~/.local/state/lain/trial-archive/nyotes-round2/`), with T21's table as the candidate. It must list no admitted call recorded as denied, or the user accepts each row. It also reports the parks removed.
6. Manual pass, owed by the user, in a nyotes round 4 cockpit:
   - `/create-epic-issues` ends with a readiness report.
   - `/clear` then `/implement-epic nyotes` starts in the same cockpit.
   - The first issue runs with the human answering under 10 parks.
   - `/stop` stops it mid-issue.
   - `lain usage <session>` prints the orchestrator's and the judge's tokens.
7. Manual phone pass, owed by the user:
   - Install `dx`, the Android SDK and NDK, and run an ntfy server on the tailnet.
   - Build and sideload the APK from `~/dev/lain-remote` (`dx build --platform android --release`).
   - Set `remote relay:` and `remote ntfy:`.
   - Answer a parked call, a wave gate and an ask_human question from the phone, away from the desk.
   - Time buzz to verdict (Open decisions).
8. Main session: update `docs/commands.md`, `ARCHITECTURE.md`, the `CLAUDE.md` suite count, and `ROADMAP.md` item 74.

## Execution log
- Run started 2026-11-03. Base main at 0cbc7664 (2 plan commits over the plan's base 644ec6ae). Branch nyotes/implement-readiness at e677e024, merge-base 644ec6ae.
- Start state: 87 worktrees and branches from earlier plans (card/T*, BD, EXT, FLK, HARNESS, TIM); left alone. Snapshots in the scratchpad (start-status.txt, start-worktrees.txt, start-branches.txt).
- Pre-staged user work unstaged for the run. Re-stage at close-out: git add .gitmodules references/repos/cliffcompaction references/repos/pi
- Hook: pre-commit hygiene hooks, shellcheck, cargo fmt/clippy/test (rust files), cargo deny (Cargo/deny files), `bundle exec rake compile check` (rubocop whole repo + pspec, about 90s), yard-lint --staged, bin/lint-gherkin-docs (planning/specs), bin/lint-commit-msg (commit-msg), bin/lint-price-freshness. Example count: tmp/parallel_runtime_rspec.log or the hook log's first pass.
- Agent checks on own paths: bundle exec rubocop <paths>; bundle exec yard-lint <paths>; cargo fmt --check, cargo clippy --all-targets -- -D warnings, cargo test (Rust cards).
- Ratchet specs: bundle exec rspec spec/*_spec.rb (top-level scanners: output discipline, zeitwerk, comment census, git scrub discipline, lain_spec membership).
- Build outputs a worktree needs: lib/lain/lain.so, tmp/parallel_runtime_rspec.log; Rust cards also target/ is rebuilt per worktree (CARGO_TARGET_DIR own).
- Locks: tmp/gate.lock and tmp/suite.lock (repo tmp/). Test-runner pattern for wait-quiet: 'rspec|parallel_rspec|cargo test|rake (pspec|check)'.
- Worktree prefix: tmp/worktrees/nr3-T<id>, branch card/nr3-T<id>. Each worktree TMPDIR=$HOME/tmp/lain/nr3-T<id>.
- Memory 15 GB: at most 5 agents at once, landing counted.
- No path needs user approval.
- T1 5 commits cherry-picked to main (28d830af..82fb48f2); suite green 32432/0, 15 pending (land/T1-cherry-1.log). Remaining T1 work: the mounted? nit.
- T1 started 16:56, cut at 82fb48f2
- T6 started 16:56, cut at 82fb48f2
- T4 started 16:56, cut at 82fb48f2
- T13 started 16:56, cut at 82fb48f2
- T23 started 16:56, cut at 82fb48f2
- T2 started 16:59, cut at 91b323c0
- T5 started 16:59, cut at 91b323c0
- T6 handed back (8 green, NameError red); medium review started.
- T1 nit handed back (16/1 red, 1256/0 green); docs wiring applied in worktree; medium review started.
- T1 review APPROVE-WITH-FIXES (mechanical, docs prose); main fixed docs/commands.md:1193.
- T6 review 1 APPROVE-WITH-FIXES: 1 substantive (non-String note accepted), 3 mechanical; fix round sent, second review follows.
- T1 landing 1 red (land/T1-1.hook.keep): 32433/1, workspace_profile_spec "passes one spec file with the example count an unconfined run reports" STARVED at load 28.3 (30s watchdog), seed 45651. Already on the known-flake list (2026-11-02): a repeat, so a follow-up card. Flake check running.
- T13 handed back (NameError red; 29 card, 382 with ratchet, green). Note for T14: a literal exec glob lowers to its parent dir. High review queued behind the flake check.
- T6 fix round handed back (10/1 red on the note type, 346/0 green). Second review queued behind the flake check.
- T2 handed back (29/2 red, 29/0 + 460 related + 336 ratchet green). Low review queued.
- T1 flake check: green alone and 3 of 3 at seed 45651 on base 91b323c0. Repeat of a listed flake: follow-up card FU-1 (workspace_profile example-count seam starves its 30s watchdog under pspec load; 2 reds in 2 rounds). Landing T1 attempt 2.
- T5 handed back (6/2 red, 433/0 green). Low review queued.
- Build outputs list gains target/release/lain-fence (wiring_spec and toolset_build_spec go red without it); copied into all nr3 worktrees.
- T4 handed back scenarios 1-2 (268/0 green); scenario 3 (hands_off parks a manual issue) needs the gate. Ruling: scope change, lib/lain/epic/gate/policy.rb and its spec join T4, plus cli/epic_submit.rb or epic/submission.rb only if the acceptance must ride the submit; factory.rb changes come back as a wiring diff the main session applies (T26 not in flight).
- T1 landing 2 red (land/T1-2.hook.keep): 32433/1, subagent_concurrency_spec "gathers every result into ONE user message in tool_use order, however the children finish" (order go-3 go-1 go-2), seed 35578. Listed flake (2026-09-21): green alone and 3 of 3 on base. Repeat: follow-up card FU-2. Landing attempt 3.
- T23 handed back (5/4 red; 383 card, 1696 related green). Ruling: 1 progress row per committed turn accepted; every row must attribute to the role, on the row or via its spawn. High review queued.
- T1 landed 8aac10aa (attempt 3)
- T1 cleanup done. Example count: a passing hook prints none; parallel_rspec exits non-zero on a lost worker; runtime log named 1204 of 1209 spec files (5 excluded tiers).
- 17:18 reviews started: T13 high, T23 high, T2 low, T5 low, T6 second.
- T6 review 2 APPROVE; main applied the private-method nit (10/0, rubocop clean). Landing.
- T2 low review APPROVE-WITH-FIXES: scenario 2 untested in guard_spec. Scope change: guard_spec joins T2; fix sent (red against base mapping.rb required).
- T5 low review APPROVE-WITH-FIXES, mechanical: guard checks the constant's spelling at the call site; ruled accept, with comments at the guard and the 2 redundant merges, and the unscanned forms named. Fixes sent.
- T4 scope-3 handed back (236/4 red; 6802/0 green incl. 9 wiring now passing). Medium review (opus) started.
- T6 landed b0c26abc (attempt 1)
- T6 landed b0c26abc. T7 started 17:21, cut at b0c26abc.
- T5 fixes verified (comments only, 433/0). Landing.
- T2 fix round: guard_spec example red against base mapping.rb (46/1), green 571/0; keyed by level name. Approved; lands after T5.
- T5 landed 9065ac88 (attempt 1)
- T13 high review REQUEST-CHANGES: read? omits writes; lend lends unleased dirs; lease spelling skips realpath; 8 of 26 mutants survive; literal glob lowers to parent (fix in T13, not T14); plus 4 nits. Fix round 1 sent; second review follows.
- T2 landed 40cbd0ce (attempt 1)
- T3 started 17:29, cut at 40cbd0ce
- T43 started 17:29, cut at 40cbd0ce
- T2 landed 40cbd0ce.
- T7 handed back (load error red; 15/0, 1185 related green). Medium review started.
- T43 stopped before code: gate's ruling reaches only WithholdAutomaticOutput::Carried, which does not forward it (verified, withhold_automatic_output.rb:127, gate.rb:252). Scope change: withhold_automatic_output.rb and its spec join T43. Lockfile gap (Scan skips lockfile checksums, TextMask does not) goes to T44's brief.
- T23 high review APPROVE-WITH-FIXES: real journal confirms the role ruling (1 dispatch row with role, 6 turn rows name the spawn). Substantive: Async::Stop during build leaks an open spawn and the grant. Fix round 1 sent with 6 mechanical items; restart_spec.rb joins. Second review follows.
- T7 medium review REQUEST-CHANGES: round trip breaks on punctuation-led notes; approve? and approve... approved; thin round-trip population; word table unpinned. Rulings (safe side, coordinator): approval word takes only a . or ! tail; an approval note needs a comma, colon or dash separator (approve it is Unrecognised); deny and hold keep any punctuation tail and the bare-space note. T8 must know this. Fix round 1 sent; second review follows, with mutation runs owed.
- T3 handed back the crate-naming check (41/2 red, 444/0 green); scenario 1 not done (Cargo has no layout). Ruling: use Cargo#owner (nearest Cargo.toml walk, cargo's own rule) and delete the src/tests split; no adapter or factory change.
- T13 fix round 1: 8 of 9 items done (39/7 red, 39/0 green, 6 mutants killed). Item 8 needs Roots.spellings public: roots.rb joins T13 for that 1 change.
- T13 item 8 done (392/0). Second review (same opus reviewer) started 17:32.
- T7 fix round 1 handed back (35/4 red, 35/0 + 1205 green; word table a pin, no red). Second review started 17:33.
- T3 ruling corrected: the nearest-manifest walk mis-names the manifest for a crate not yet created (the only reader is selection_for's error). adapter.rb and its spec join T3 (mapping.rb if a public method is needed); Cargo gets the layout's package rule; factory wiring by main.
- T23 fix round stopped on scope: lineage.rb and bin/demo-supervision join T23 (OneShot gains a launched lifecycle so actors reuse recording). Items 2,3,4,7 done.
- T7 review 2 APPROVE-WITH-FIXES (7 mutants all red, probe clean); 2 mechanical nits sent. Note for T8: a deny or hold keeps leading punctuation in its note (n!! x gives note "! x"), and approve-with-a-note needs a comma, colon or dash.
- T4 medium review (opus) REQUEST-CHANGES: factory_spec (slow) red; manual park writes no awaiting_human; acceptance parsed 3 times in production; gate fact commands unpinned; 5 stale comments. Rulings: route manual park through Deferred; factory wiring passes subject.acceptance; commands are When/Then backticked spans only; planning view's denied reading is T48's if pre-existing. Fix round 1 sent; second review follows.
- T13 review 2 APPROVE-WITH-FIXES (34 of 35 mutants killed, every back-out red); 3 mechanical items sent. For T14: a rule whose root is reached through a symlink misses the real landing (probe 4f, nr3-T13 tmp/probes).
- T7 nits done (1205/0). Landing.
- T7 landed 2ba0130e (attempt 1)
- T7 landed 2ba0130e. T9 started 17:41, cut at 2ba0130e (opus).
- T13 round 2 items done (19/2 red, 611/0 green). Landing.
- T3 handed back the layout route (96/8 red, 480/0 green); main applied the factory.rb:1350 wiring (rubocop clean). Medium review started.
- T9 stopped before code: breaker never hears a postpone (only Judged calls DenialBreaker#denied); 5 specs pass Booleans to Pending#decide. Scope change: switchboard.rb (2 lines) and those 5 specs join T9; no Boolean shim.
- T13 landed 22edfb51 (attempt 1)
- T13 cleanup done.
- T14 started 17:46, cut at 22edfb51 (opus). T3 medium review started.
- T23 fix round done (5/2 red, lineage_spec unknown keyword red; 1735/0 green; demo exits 0). Second review started 17:47.
- T43 handed back (219/6 red, 34/2 red after switch; 311/0 + 3605/0 green). Deviation: ruling passes up as env[:ruling] (forwarding broke tool_guard_spec's delegator-depth pin). High review (opus) started; hot-path-bench owed before landing.
- T3 medium review APPROVE-WITH-FIXES: substantive regression (bare cargo preset makes package_dir answer . so the error names the root manifest); layout rule and factory wiring unpinned (mutants survive). Ruling: package_dir answers only under a package's own roots, else nil and fallback. factory_spec joins T3. Fix round sent; second review follows.
- Overlap: T3 and T4 both now touch factory_spec.rb and factory.rb (different lines). The later landing applies by git apply -3 from its own cut sha; re-check its wiring against main before landing.
- T14 handed back (28/8 red, 551/0 green), stop condition fired: an exec dir of node_modules/.bin denies its own symlinks under lain-fence. Rulings: widen to node_modules/** (links point inside node_modules; per-link targets drift); tripwire/ledger.rb and cli/wiring/observers.rb join T14 so production passes the rules; only fresh_run_file exempt, but report whether cargo test's unresolved_exec stops the agent.
- T3 fix round done (20/3 red for item 1; items 2-4 proved by mutants; 583/0 green). Second review started 17:52.
- T4 fix round 1 done (459/12 red, 4176/0 green). Scope change: epic/gate/policies.rb and epic_driver/run_spec.rb join T4. factory.rb:1224 wiring (acceptance:) applied in worktree. Second review started 17:52.
- T23 review 2 APPROVE (8 of 10 mutants red, 2 caught by older specs; every back-out red; real journal 1 spawn, 7 progress, 3 usage). Landing.
- T14 rulings done (129/5 red, 132/0 + 850/0 green). cargo test binary only records unresolved_exec (only refused_exec stops); would_stop noise on every honest cargo test becomes follow-up FU-3. High review queued behind the T23 landing.
- T23 landed dff0946e (attempt 1)
- T23 landed dff0946e. T24 started 18:00, cut at dff0946e (opus). T14 high review started.
- T3 review 2 APPROVE-WITH-FIXES (regression fixed, 4 of 5 mutants red); 1 spec for deepest-wins sent.
- T9 handed back (1144/25 red; 4987/0 green over 108 files incl. e2e cockpit_approval). Bare wait/stop at [y/N] now hold. High review (opus) started. Docs owed: docs/commands.md hold [note] at [y/N].
- T3 review 2 fix done (deepest-wins pinned with a/src and a/tests/z/src; 422/0). Landing.
- T24 stopped on its lease-owner condition. User ruling (2026-11-03): Hybrid. A stopped child keeps its live lease while the session runs and resumes in the same worktree; Conductor#close surrenders held leases; after an abandoned session, --resume cuts a fresh worktree from the stop's anchor plus snapshot. conductor.rb and its spec join T24; resume wiring to the live Subagent; exe/lain lines come back as wiring.
- T43 high review APPROVE-WITH-FIXES: only a human approve releases (real wiring verified); env[:ruling] sound. Substantive: unbounded whole-file scan on release (12 MB wc -c 2.64s vs 0.29s); released surface recorded as the rung name. 8 surviving mutants; 3 false texts. Fix round sent; second review follows. Main owes planning/qa/scenarios/secret-boundary.md 4f (a human-approved cat releases).
- T4 review 2 APPROVE-WITH-FIXES: substantive, IssueActor defaults acceptance so the factory wiring is unpinned (M12). Fix round 2 sent with GATE_PARKED wording as a factory wiring diff; third review follows.
- T14 high review REQUEST-CHANGES: link-out run file exempted while lain-fence refuses it; ExecRules.lain on the tripwire exempts a fresh exe/lain; lease checkouts uncovered (180 of 349 real cwds). Rulings: lease checkouts move to T15 via the agent's Bounds; tripwire gets project rules only. Real history: 0 of 134 fresh run files exempted; the cargo test noise is unresolved_exec (never stops), follow-up FU-3. Fix round sent; second review follows.
- Plan note for T15: cover each lease checkout's exec rules through the agent's Bounds (from T14 review).
- T3 landed 15f63347 (attempt 1)
- T3 landed 15f63347.
- T14 fix round done (each red recorded; 855/0 green). Second review started 18:14.
- T9 high review APPROVE-WITH-FIXES (real tmux drive: hold, reissue, y ran it; 12 of 13 mutants red). Rulings: at [y/N] only 'hold' is a hold, wait/stop are chat lines again; a hold at a secret-release prompt postpones (no run-long decline). Scope: approval_replay/approver.rb and redact_secret_reads.rb (release decision lines only; T43 overlaps that file) join T9. Fix round sent; second review follows.
- T4 round 3 handed back (factory_spec 34 red without wiring; ladder_spec fix unconfirmed). Scope widened: plan_only.rb and spec, policies_spec, ladder_spec. Rebasing the worktree onto main was denied by the permission classifier (reset --hard); T4 lands by the standard 3-way patch instead. Third review started 18:16.
- T14 review 2 APPROVE-WITH-FIXES (13 of 14 mutants red; real fence and resolver probes agree). 1 spec sent.
- T14 last spec done (6/1 red, 138/0 green). Landing.
- T14 landing 1 never ran its hook: wait-quiet counted T43's xargs (its args name bundle exec rspec) while that xargs waited on the gate; deadlock for 30 min. Local wait-quiet now skips xargs, env, nice, ionice. Re-landing T14.
- T14 landed 005621ae (attempt 2)
- T44 started 18:58, cut at 005621ae
- T42 started 18:58, cut at 005621ae
- T14 landed 005621ae (attempt 2).
- T9 fix round: items 1,2,5,6,7 done (408/9 red). Items 3,4 approved: redact_secret_reads.rb line 483 and a Trailer::REASONS key; plain_chat_prompt_guards_spec joins; [y/N] tail unchanged; 'hold on' as a hold accepted.
- T43 fix round done (385/20 red; 385/0, 6075/0 wide; 19 mutants killed). escalation.rb and spec joined (Ruling gains surface). Dropped directory and pattern filters. Second review started 18:59; hot-path-bench owed before landing.
- T44 handed back (395/8 red, 736/0 green). TextMask gap (cat on a lockfile masks more than read_file) becomes FU-4 after T43 lands. Low review started.
- T4 review 3 APPROVE (13 mutants dead, back-outs red, 1045/0). Patch checked against main (3-way clean over T3's factory edits). Landing.
19:04 T9 round 2: item 3 broke 4 specs (2 stand-in Verdicts lack postponed?); ruled: add postponed? = false to both, no respond_to?
19:05 T44 review (low): REQUEST-CHANGES, mechanical: oracle paths.yml flake.lock/mix.lock class none -> checksums; sent to impl; no re-review needed
- T4 landed 82438dac (attempt 1)
19:05 T4 landed 82438dac (1210 of 1215 runtime files)
19:06 T8 started (worktree nr3-T8 from 82438dac)
19:06 T8 ruling: scenario 1 reply has no separator, Unrecognised under T7; spec uses separator form, Reply not loosened
19:06 T44 fix done (oracle fixture); landing attempt 1
19:07 T42 impl done (2 files, red 2 of 34, green 2421/0); low review queued until T44 landing releases the gate
19:09 T43 review 2 (high): APPROVE-WITH-FIXES, 3 mechanical (trailer names read_file; cap+binary specs kill 2 survivors; reflow 2 comments); no third review
- T44 landed b93101f2 (attempt 1)
19:12 T44 landed b93101f2
