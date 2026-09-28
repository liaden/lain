# Chunk — local models, images, and a QA ladder that cannot be fooled by silence

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Two weeks of measurement against nine local models produced one structural finding: **ollama's failure
mode is silence** — HTTP 200, `done_reason: "stop"`, empty `content` or empty `tool_calls`, and a turn that
reads as an answer and contains nothing. Six independent defects share that shape. lain trusts those fields
today, so a parse failure is indistinguishable from a model that chose to say nothing.

This chunk makes silence a typed outcome, then builds the two capabilities that need it: **images** (a
`screenshot` tool whose bytes never touch the Timeline) and a **QA ladder** that reports rather than fixes,
orders its rungs cheapest-first, and treats "could not parse" as a finding rather than a pass. Along the way
it gives lain the three things the measurements proved it lacks: per-model capability discovery, per-skill
model choice, and a driver width that respects where the model actually runs.

Roadmap: entry 50. Evidence: `planning/specs/local-models-multimodal-qa/` (research, two spike write-ups,
`model-probes/REPORT-0.32.12.md`, `UPGRADE-ollama-0.34.4.md`, `NOTE-thp-and-offload.md`, `IMPLICATIONS.md`).

## Grounding

Verified 2026-09-28 by four parallel explorations against `main` at `ec396926`. What they changed about the
plan, because each of these would have produced a wrong card:

- **Empty replies need no new stop reason.** `Telemetry::MalformedResponse` (`lib/lain/telemetry/malformed_response.rb:54`)
  exists for "decoded cleanly, still unusable" and its `kind:` is the documented extension slot;
  `:malformed` is already in `StopReason::ALL` with a `FAILURE_REASONS` row (`lib/lain/agent.rb:58-62`).
  Today an empty reply yields `content: []`, `stop_reason: :end_turn` (`lib/lain/provider/ollama/decoding.rb:88-96,128-134`)
  and `Agent` silently settles (`lib/lain/agent/loop_machine.rb:48`). A new `StopReason` member would have
  forced a `loop_machine` event and a totality-spec change; it is not needed.
- **Prompt-prefix stability needs NO card.** `Workspace` renders into the *uncached suffix* — appended to the
  last user message by `Context::Reminder` (`lib/lain/context/reminder.rb:32-37`), documented at `:7-12` as
  deliberately avoiding the cached prefix. The only per-spawn prefix content is the system prompt via
  `Context#with_system` (`lib/lain/context.rb:89`), which is stable per spawn. The measured local
  prefix-reuse win is therefore already protected by the design that protects Anthropic's cache. Item 11 of
  `IMPLICATIONS.md` is closed by verification, not by work.
- **There is no `epic_driver/run.rb`.** `EpicDriver::Run` lives in `lib/lain/cli/epic_driver/factory.rb:633`;
  `WIDTH = 2` at `:639`, read at `:477`, `:834`, bounding live issue actors through `#room?` (`:921`).
- **`Provider::Admission` already serializes local requests to 1** per endpoint
  (`lib/lain/provider/admission.rb:96,296-305`), with `LAIN_PROVIDER_CONCURRENCY` overriding both ways
  (`:134`). At `WIDTH = 2` against local ollama the actors already serialize and the loser can raise
  `Admission::Busy` after a 300 s deadline — named in that file's own header at `:86-96`. A locality-derived
  driver width must therefore *defer* to this gate, not duplicate it.
- **A blob store already exists.** `Workspace::Snapshot::Blob` (`lib/lain/workspace/snapshot.rb:58-76`) is
  content-addressed raw bytes with git-style `blob <size>\0` domain separation over blake3, and
  `Event#payload_digest` (`lib/lain/event.rb:122,161-190`) is the existing out-of-line-body idiom.
  `lib/lain/sensitivity/regions.rb:364-365` records the hazard: a new kind of blob must pick its **own** tag
  or two namespaces silently merge. `Lain::Store` is in-memory (`lib/lain/session.rb:274-277`), so durability
  needs `Paths#container` (`lib/lain/paths.rb:270`).
- **The resolver seam exists.** `Middleware::Stack#insert_after` (`lib/lain/middleware.rb:95-98`) plus
  `Agent::ModelCaller` re-reading `env[:request]` at dispatch (`lib/lain/agent/model_caller.rb:36-40`) means
  journal-then-resolve needs no new seam. `JournalRequests` is at `lib/lain/middleware/journal_requests.rb:18-31`.
- **Skills already have a config surface**: front-matter parsed at `lib/lain/skill/catalog.rb:48-57` into
  `Skill = Data.define(:name, :description, :scaffold, :slots, :includes)` (`lib/lain/skill.rb:14`), with
  exactly three recognized keys and **no unknown-key refusal**. `RoleSpawn#call` is a 3-arity seam
  (`lib/lain/skill/role_spawn.rb:49-51`); the child's model comes from `ChildBuilder#child_context`
  (`lib/lain/tools/subagent.rb:1190-1191`), and `Bench::SpawnSeam#routed` (`lib/lain/bench/spawn_seam.rb:172-175`)
  already demonstrates the `Context#with_model` move.
- **One provider per run.** `Seam` holds a single provider (`lib/lain/tools/subagent.rb:779`), so per-skill
  model choice is *within* the run's provider. Cross-provider is an Open decision, not scope.
- **`.lain/config.toml` has an `[epics]` table** with `KEYS`/`TABLE`/`Refusal` unknown-key rejection
  (`lib/lain/config/epics.rb`), the worked idiom for a new `width` key.
- **Nothing reads `/api/show`'s `capabilities`** (`lib/lain/provider/ollama.rb:386-394,444-448`); the array is
  recorded in a cassette as a fixture only. `ContextWindow` (`lib/lain/context_window.rb`) is the house idiom
  for a per-model table with typed provenance (`PROBED`/`PUBLISHED`/`GUESSED`, `:227-230`).
- **`num_batch` has no default**: `lain chat --provider ollama` sends `options: {num_predict:}` alone, pinned
  by `spec/lain/cli_spec.rb:862`.
- **`keep_alive` is currently the encoder's example of a dropped unknown key**
  (`spec/lain/provider/ollama/encoding_spec.rb:73-79`) — implementing it inverts that spec's meaning.
- **Oracles**: `DEFAULT_MAX_TOKENS = 1024` (`lib/lain/oracle/model.rb:19`), no oracle ever sets `think`,
  `UndecodableAnswer` is caught by name nowhere and swallowed by five broad rescues, and there is no retry
  anywhere. Schema range/enum constraints are expressible today because `Definition#schema` is a
  `Tool::Input` subclass (`lib/lain/tools/bash.rb:143` is the precedent) — but changing a schema changes the
  oracle digest (`lib/lain/oracle/definition.rb:51-53`) and invalidates recorded replays.
- **Spike drift**: `SPIKE-images.md`'s survey is ~90% line-exact; three cosmetic drifts noted in the agent
  report (`compaction/tool_messages.rb:137` → `:28`; `neovim/buffers.rb:303-306` → `:307-309`; several ±3).
  None of the spike code is in the tree; both patches are unapplied by design.

Panel-reviewed 2026-09-28 (Torvalds/Evans/Metz/Schneeman/Patterson). Five blockers were raised and all five
fixed here: the vision gate was wired into `BaseTools.build`, which has no model (it moved to
`ToolsetBuild#capability_floor`); the attachment store was constructed by nobody and needed by two cards (T7
now owns one construction site); the image resolver anchored on a middleware that vanishes under
`--no-journal` and never reaches children (it moved to `Wiring#model_phase`); one card was a no-op and was
cut; and one acceptance criterion was already green before any change. Two fabricated dependency edges were
dropped, shortening the plan by a wave, and the QA ladder card was split in two.

Measured facts the design rests on (see `REPORT-0.32.12.md`, `UPGRADE-ollama-0.34.4.md`): a 30B model
reload costs 16–20 s **and** discards the prefix cache (20.4 s cold vs 0.5 s warm on an 11k prompt); no two
≥16 GiB models are co-resident at 21.2 GiB usable; `qwen3-coder` wrongly passes 4 of 16 real violations
identically on both ollama builds; `laguna-xs-2.1` and `north-mini-code-1.0` score 32/32 on the QA items on
both builds; a single 219 KB screenshot base64-expands past the 262,144-byte compaction threshold
(`lib/lain/cli/backend.rb:73`).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`, `.rubocop.yml`,
  `spec/spec_helper.rb`, `spec/support/tool_registry.rb` (the `BUILDERS` roll call), `exe/lain` (flag
  declarations only — cards state the flag, the orchestrator adds it).
- `.lain/config.toml` key additions are card scope (each table class owns its own keys); `exe/lain` flags are
  not.
- Two commits already exist on branch `local-models-quick-wins` (`8d2ce30a`, `07a5e161`), written and green
  against this tree. T1 cherry-picks rather than rewrites them.
- No back-compat obligation: lain has no production users. Prefer deleting a concept to adding one beside it.
- **Deviation:** T19 is documentation-only. Its acceptance criteria are verified by reading the claims against
  the code and the measurements, not by a spec file, and it needs no panel review.

## Execution log

Base branch: **`main`**. Chunk opened at `ec396926`. `origin/main` is 488 commits behind `main`
(`b1927ce7`, 2026-08-25), so every worktree is cut by the orchestrator from `HEAD` — never by
`isolation: "worktree"`, which forks from `origin/main`.

Orchestrator decisions taken during execution:

- **T1 landed as a fast-forward, not a cherry-pick.** `main` was an ancestor of
  `local-models-quick-wins`, so `git merge --ff-only` put `8d2ce30a` and `07a5e161` on `main`
  keeping their original messages. `spec/lain/context_window_spec.rb`,
  `spec/lain/provider/ollama/encoding_spec.rb` and `spec/lain/provider/ollama_recorded_spec.rb`
  re-run green on `main` afterwards (140 examples). Branch `local-models-quick-wins` is now
  merged and retired.
- **`lib/lain/cli/wiring/toolset_build.rb` is promoted to an orchestrator-owned shared file.**
  Three cards touch it (T6's capability reader, T7's single `Attachment::Store` construction,
  T13's vision gate) and it is the file the panel already moved two decisions onto. T7 edits it
  directly, because its "one store serves the whole run" criterion is only provable through the
  real construction path; T6 and T13 hand back wiring diffs against T7's version.
- **T5 and T6 were pulled into wave 1** the moment T1 landed — their stated dependency on T1 was
  file ordering in the ollama encoder and its recorded spec, nothing more. T5 is held only behind
  T4, which shares `lib/lain/cli/backend.rb` and its spec with it.
- Agents run targeted `bundle exec rspec <files>` in their own worktree under a per-card
  `TMPDIR`; `rake pspec` is the orchestrator's alone, serialized, because `TMPDIR` is shared
  mutable state and a concurrent run makes a red suite unreadable.

Baseline for integration check 1: **20,731 examples, 1 pending** at `07a5e161` (`rspec --dry-run`,
2026-09-28, taken after T1 landed). CLAUDE.md's 20,511 figure is from 2026-09-20 and the tree has grown
since. The closing `rake pspec` compares its count against this number, not against CLAUDE.md's.

**Landing is serialized against agent activity, and that is a hook property, not a preference.**
`.pre-commit-config.yaml`'s `ruby-checks` hook is `bundle exec rake compile check`, which fans out
`parallel_rspec` one worker per core over the WHOLE suite -- so every commit runs the full suite, and
CLAUDE.md's rule that a red `pspec` is not evidence until nothing else is running applies to the commit
itself. The hook also autostashes repo-wide, which makes a concurrent worktree's `git status` lie. So
approved cards queue until the implementer wave is quiet, then land back to back, each as its own commit.

Cards landed on `main`:

- [x] **T1** — `8d2ce30a`, `07a5e161` (fast-forwarded)
- [x] **T2** — `28523b96` skills: an unknown front-matter key is refused, not ignored
- [x] **T9** — `a444124f` oracle: a secret-read verdict is canonical, its confidence in range
- [x] **T4** — `e39dda35` ollama: send num_batch 2048 by default, since the cost is paid anyway
- [x] **T6** — `23e71dfd` provider: a model's capabilities answer per model, not per endpoint
- [x] **T14** — `0e7720f2` epic driver: width derives from where the model runs, and refuses junk
- [x] **T7** — `24c22a62` attachments: one content-addressed blob, durable beside the session
- [x] **T3** — `72795315` ollama: a reply that says nothing is malformed, not a finished turn
- [x] **T12** — `47a801dd` qa: the report vocabulary, where a blank answer is never a pass
  (carries the `qa` → `QA` loader inflection and the matching CLAUDE.md correction, same commit)
- [x] **T21** — `7a4e25a3` epic driver: the width follows the endpoint the chat really dials
- [x] **T5** — `26c6b33d` ollama: keep_alive pins the runner, refusing what it cannot mean
- [x] **T19** — `3595e72c` docs: ollama 0.34.4 is what the box runs, and -b 1024 is the default
- [x] **follow-up 1** — `f9e8f607` backend: name the ollama-only endpoint helpers for the arm they answer
- [x] **T20** — `32cd772a` qa: read the diff, the cards and the claims they make
- [x] **T11** — `deea20b9` images: carry a picture as a digest, resolved on the way to the wire
- [x] **T16** — `cd62b5ec` qa: a ladder that climbs to a different model, cheapest rung first
- [x] **T17** — `8cd10876` qa: /qa runs a plan's criteria and writes a report, never a fix
- [x] **T18** — `1c529585` epic: a QA checkpoint in the blocking graph, before the next cluster
- [x] **T21** (opened during execution) — `7a4e25a3`
- [x] **follow-up 1** (the ollama-only rename) — `f9e8f607`
- plus `fdc30477` and one more, two spec-honesty fixes the censuses surfaced

**ALL TWENTY CARDS LANDED.** T10 was cut during planning; T21 was opened during execution by T14's panel.

## Integration checks — run 2026-09-28, all at `1c529585`

1. **`bundle exec rake pspec` at 12 workers: 21,229 examples, 0 failures, 13 pendings.** Baseline at
   chunk start was 20,731, so **+498 examples** and no truncation — the count is the check, because a
   dead worker reads as a pass.
2. **`bundle exec rubocop`: 1,782 files, no offenses**, at default metrics (no ceiling raised, no inline
   disable; the one `Metrics/AbcSize` trip in the chunk was answered by extracting a collaborator).
   `bin/comment-census --check-tickets`: PROJECT SCHEMES 0, UNCLASSIFIED 0. `--check-load-order`:
   UNCLASSIFIED 0. `bin/zeitwerk-census --check`: namespace 0, reference 0, cascade 0, unclassified 0 —
   which matters because this chunk added the `QA`, `Attachment` and `ContentAddressed::Blob` namespaces.
   `bin/spec-census --check`: `199 > 184`, **pre-existing and unchanged** — the chunk's net contribution
   is zero, twice verified by conversion rather than by documenting a false positive.
3. **`LAIN_OLLAMA=1` against live ollama 0.34.4: both specs the plan named as failing today now PASS.**
   `spec/lain/oracle/secret_read_spec.rb` 32/0 — T8 is why, and the diagnosis (the judge spending its
   whole ceiling on reasoning) was right: 16.6s and "unexpected end of input" before, 1.5s green after.
   The over-window and `keep_alive` contracts pass too. The one remaining live failure is
   `spec/integration/provider/ollama_spec.rb:145`, logged above as **not this chunk's** and exonerated
   three ways. `/api/ps` left empty.
4. **Manual pass, still owed by the human** — and read the "one tension" section above first: a default
   `/qa` will come back all-unsettled, which is the design working, so the pass tests the plumbing
   rather than the judgement. Report path is now `.lain/qa/<plan-path-flattened>-<base7>..<head12>.md`.
5. **Manual pass, still owed by the human** — one `/implement-epic` on a local provider confirming the
   driver carries one issue at a time and no `Admission::Busy` appears. Note T21 is what makes the
   derived width reach production; before it the seam was unwired.
6. **Re-run the probe harness's wire checks** — still owed, and cheap: `model-probes/wire.py` against
   the `format`+`tools` refusal T1 landed.

**What the panels caught that a green suite could not.** Recorded because the pattern is the finding:
every one of these was in code whose suite was green, and every one was found by the reviewer going to
ground truth rather than reading.

| card | found by | the defect |
|---|---|---|
| T5 | POSTing lain's own payload to the live server | `--keep-alive -1` is an HTTP 400 -- the value rides as a JSON String and Go's `ParseDuration` needs a unit. Every spec asserted lain's hash against lain's expectation. |
| T7 | 240 threaded runs at 17 bytes | concurrent `put` lost 5 of 6 writers to `ENOENT`; the partial path was keyed on pid alone, so every THREAD shared one temp file. |
| T3 | reading `StopReason::KNOWN` against the arm split | `:end_turn`/`:stop_sequence` from an ollama-compatible server let silence settle as SUCCESS -- the exact failure the card abolishes, surviving it. |
| T6 | the public constructor | `supports?(:too)` answered SUPPORTED via `String#include?`, because only the factory interned. |
| T12 | a blank-table sweep | four zero-width characters accepted as "evidence"; a JSON string in the fence read as a clean PASS. |
| T20 | parsing all 47 documents in `planning/specs/` | the card recogniser read 26 English prose headings as card ids across 11 documents, and round 2's new refusal turned that into a HARD REFUSAL of 5, two of them genuine card plans. |
| T8 | two overlapping asks on one shared oracle | a usage accumulator spanning a suspension point billed one ask for the other's tokens -- on the default compaction path, corrupting the record the bench's accounting reads. |
| T15 | driving a grandchild end to end | `config[:model]` was dead; the hand-back claimed it carried the model to a subtree. Deleting it left 354 examples green. |

Three of those were **regressions the fix round introduced**, caught only because the re-review re-derived
rather than re-read: T9's exact `inclusion:` disagreeing with `confident?`'s `.strip.downcase`, T20's new
`MalformedPlan` sitting on a recogniser that was never right, and T8's accumulator.

**Landing cost, measured.** Every commit runs the full suite through the hook. Across 14 commits the
flake rate under load ran about one retry per landing, peaking at four for T20 at load average 13.8 --
all four from families named in `docs/toolchain-traps.md`, and 149 examples green serially with the card
applied, proving the card innocent. Landing on a quiet box (load 1.9) went first try. **A flake ledger
that records by NAME is what made every one of those reds readable in under a minute.**

## The one tension the chunk did NOT resolve, found at the last card

**As shipped, a QA pass can never report a model-found defect.** Three decisions, each correct in
isolation, compose into it — and no single card could see it:

1. **T16's escalation rules believe a failure only when the model RAN something.** `executed-fail` and
   `corroborated-executed-fail` are the only two `report` rows; every unexecuted fail climbs, and at the
   top rung becomes `unsettled`. That conservatism is measured, not squeamish: `qwen3-coder` wrongly
   passes 4 of 16 real violations, `lfm2.5` 6 of 16, and a false blocker costs a whole fix round.
2. **T17's `qa` role holds `%i[read_file list_files glob grep]` and nothing else**, satisfying its own
   AC3 ("it holds only read and search tools"). A role that cannot run anything can never set
   `executed: true` — so those two rows are unreachable in production, and a `blocker` with them.
3. **T16's default binding ships `strong: false`**, so `unanimous-pass` cannot fire either until a human
   binds a measured rung.

**And the asymmetry runs in the UNSAFE direction, which is sharper than the above.** `unconfirmed-fail`
sits ABOVE `no-strong-voice` in `RULES`, so once a human binds a strong rung, that rung's unanimous
**inferred PASS is accepted as a clean pass** while its unanimous **inferred FAIL escalates into
nothing**. The `executed` requirement is applied to fails only — and the measured evidence is
specifically about models *wrongly passing* real violations (`qwen3-coder` 4 of 16, `lfm2.5` 6 of 16),
which is the one direction an unexecuted answer is permitted to settle. So the honest statement is not
"a shipped pass can never report a defect" but **"a shipped pass can never report a defect, and can
clear one"**. Measured end to end through the real `PlanCards`/`ClaimCheck`/`SessionTiers`/`Ladder`/`Report`
with only the model reply doubled.

A second consequence, same root: because `executed` is a self-report the code trusts absolutely and BOTH
the role prelude and the skill instruct the model never to set it, **the only production route to a filed
blocker is a model that disobeys its prompt.** The structural answer is a `Rung` member saying whether a
rung can execute, which `Escalation` discounts `executed` against — so the contradiction is
unrepresentable rather than merely documented.

Compose them and a default `/qa` pass returns **every criterion unsettled, a manual pass owed, and
nothing filed** — and even with a strong rung bound, a model rung can accept a criterion but never fail
one. What still works, and is not small: T20's **model-free** claim check is rung zero and does file
findings (a major for a card naming a file the diff never touched, a minor for a changed file no card
claims), and the ladder's record names every rung run and every escalation, so a pass is auditable.

**This is a plan defect, not an implementation one.** The spike built the role as "read-only **+ bash**,
unattended, report-only" (`local-models-multimodal-qa-HANDOFF.md:79`) and flagged the real hazard in the
same breath: "`unattended` + `bash` still parks at the gate in `ask` mode" (`:97`). T17's card carried the
worry forward as an escalation trigger but wrote AC3 as *read and search only*, which resolves the parking
hazard by removing the capability the escalation rules depend on. Nobody was wrong; the two criteria are
mutually exclusive and the plan never said so.

**Deliberately NOT patched here.** Adding `bash` to the `qa` role would re-open the parking hazard the
plan names, on the approval path this chunk otherwise leaves alone, at the last card of a nineteen-card
run. The honest ship is the conservative one — a pass that says "I could not settle this" rather than one
that invents a verdict — with the tension written down. Its own card, which must decide: a gated
execution capability for the qa role and what `unattended` does with it, or an `executed` that means
"cites evidence it read" rather than "ran", or an explicit statement that model rungs accept-or-escalate
and findings come from rung zero.

## The throwaway checkout is a RELEASE-correctness requirement, not an isolation one

The spike's first open question — QA runs in the epic's landing checkout and wants a detached, throwaway
one — was carried as an escalation trigger on two cards and answered twice, both times too narrowly.
T17 answered it by capability: the `qa` role holds `%i[read_file list_files glob grep]`, so nothing can
write and no throwaway checkout is needed for *isolation*. True, and not the whole question.

T18's panel found the branch that matters: `EpicDriver::Factory#landing_checkout` answers
`LandingCheckout::InPlace.new(root: @root)` when the chat already stands on `epic/<slug>`, and
`cluster_qa` then runs the ladder with `cwd: checkout.root == @root` — the human's live project checkout.
The hazard there is **not** a dirty tree (`QA::Changeset` reads commit-to-commit, so uncommitted work
cannot change the diff). It is a **false RELEASE**: a criterion can be acquitted on bytes the branch does
not carry, releasing a checkpoint for code nobody landed.

**Unreachable today**, because the shipped binding cannot acquit — the worst case is a finding whose
evidence will not reproduce. **Reachable the moment a caller lends a settling rung**, which is exactly
the `ladder:` keyword T18 added to make `OWING`'s advice true. So the two halves of that fix are in
tension by construction, and the requirement is:

> A pass whose verdict may RELEASE work must read a checkout that carries exactly the commits the release
> is about. Reading the live project checkout is safe only while nothing can acquit.

Its own card, with the `[qa]` config table that would let a project bind a settling rung — the two belong
together, because the config is what makes the hazard reachable.

## Follow-ups this chunk found but does not fix

Each is its own commit or card, deliberately, so nothing is smuggled into a diff that was reviewed
for something else.

1. **Rename `Backend#default_base`/`#endpoint` → `ollama_default_base`/`ollama_endpoint`.** `#default_base`
   answers `http://localhost:11434` for ANY provider that is not ollama-cloud, anthropic included; its
   honesty rests entirely on the single `ollama_chat? &&` at its one call site. It caught the orchestrator
   during T14's wiring and the panel blocked that before it shipped — a rename makes the misuse
   *unwritable* rather than merely commented against. Measured: three sites, all private, all inside
   `backend.rb`. `CLI::Review#default_base` and `exe/lain`'s `ModelFlags.endpoint` are unrelated names.
   **Blocked only on T8, which is editing that file.**
2. **`spec/integration/provider/ollama_spec.rb:133` fails 3 of 3 live**, on the terminal
   `expect(agent).to be_done`, with all four content assertions passing — the model calls echo, the input
   decodes as a Hash, the result lands in one user turn, the synthetic ids match. Exonerated from T5 three
   ways. That spec's own header says not to loosen it into flakiness but to escalate with the transcript.
3. **`ContentAddressed`'s receiver-directional `is_a?(self.class)` asymmetry is now live**, since T7 created
   the first production subclass: `parent == child` is true, `child == parent` false, `hash` equal, so a Hash
   answers by insertion order. The symmetric guard (`other.class == self.class`) touches
   `content_addressed_spec.rb`'s pinned refusals, so it is its own commit.
4. **`Sensitivity::Regions::Region` is still the hand-rolled second copy** of the blob framing. T7 extracted
   the first; migrating this one is clean and already spec-covered.
5. **`lib/lain/approval/secret_surface.rb:106`'s `.strip.downcase` is now redundant**, since T9 normalizes
   once at the boundary. Collapsing it puts a second security-relevant class in a diff, so: its own commit.
6. **ActiveModel's `:float` coercion turns a non-numeric `confidence` into `0.0`** before any validator runs,
   so a garbled oracle reply is journalled as a sincere zero-confidence answer — quietly polluting the
   calibration data `DEFAULT_THRESHOLD`'s own comment says should drive it. Predates this chunk.
7. **`bin/spec-census --check` is red on `main`** (`assertions: 199 > 184`), confirmed identical before this
   chunk by four independent agents. Nothing gates on it; the ceiling has drifted from reality.
8. **Nothing pins `SETTLES_AS_ANSWER` to `LoopMachine`** — a new terminal-success stop reason would need
   editing in two files with nothing failing. T3's reviewer's introspection probe is the ~6-line spec.
9. **`Gherkin::Scenario#mechanical` (the `# rubric` marker) already means "a human judges this"**, so the
   ladder card's `[visual]` would be a third spelling on one axis. Reconcile before T16 lands it.

**What landing taught, for the rest of the chunk.** The hook runs the whole suite, so each landing is a
suite run, and three separate reds had three different causes -- none of them the card:

1. **A truncated run reads as a failure with a plausible number.** T2's first attempt reported
   `18,860 examples, 1 failure` against a 20,731 baseline: ~1,900 examples short, the dead-worker
   signature CLAUDE.md names. Re-run on a quiet box: 20,733, green. **Always reconcile the count**
   -- the failure count alone would have sent someone hunting a defect that did not exist.
2. **A FIFTH collateral site for T4, which neither sweep could have found.** `spec/lain/seams/over_window_request_spec.rb:242`
   asserts `chat_bodies.first["options"].keys` -- a **String** key read off the decoded body. Both sweeps
   searched the Ruby-symbol form `[:options]`, so the shape was invisible to them. Its comment ("`options`
   is the generation cap and nothing else") was a fourth false prose claim, corrected with it.
3. **A documented flake, caught by name.** `62_approval_spec.rb`'s two examples red under 12 workers are
   named verbatim in `docs/toolchain-traps.md`, whose entry says to budget one retry per landing. They
   passed on the retry. `spec/support_vsock_availability_spec.rb:66` ("leaks no descriptor across repeated
   probing") reddened once under load and passed serially -- **not** currently in that ledger, and a
   candidate for it if it recurs.

Commit subjects are capped at 72 characters by `bin/lint-commit-msg`, which runs at `commit-msg` -- i.e.
AFTER the suite has already passed. A subject one character over costs a full re-run, so count first.

**Orchestrator-applied edits owed at landing** (each folded into its own card's commit, never a
separate "fixups" commit):

- T4: `exe/lain`'s `--num-batch` prose (the card's named trigger), and `lib/lain/provider/ollama/encoding.rb:25-36`'s
  "Every key here is strictly opt-in", which the implementer found unprompted -- `num_batch` became opt-out.
- T6: `spec/lain/provider/ollama_spec.rb:53,96`, red from deleting `:thinking` from `Deployment::CAPABILITIES`;
  a `#model_capabilities(_model)` default on `Lain::Provider` and `:model_capabilities` on `Provider::Journaled`'s
  delegate list, so a non-ollama provider answers the message instead of forcing a `respond_to?` type check.
- T14: **RETRACTED -- the orchestrator's planned wiring was wrong, and the panel caught it before it landed.**
  `Backend#endpoint` was the wrong value: `#default_base` (`backend.rb:743`) answers
  `Provider::Ollama::Transport::DEFAULT_API_BASE` -- `http://localhost:11434` -- for ANY provider that is not
  ollama-cloud, anthropic included. Its only caller today is `shares_chat_runner?`, guarded by `ollama_chat?`,
  which is the guard that keeps it honest. Published as "the chat's endpoint", an anthropic run would have
  resolved localhost, read `Endpoint.local?` true, and taken `LOCAL_WIDTH = 1` -- silently halving every hosted
  epic run for a reason nothing in the output names. The wiring is now **T21**, below.

**Landing plan.** The six wave-1 cards touch mutually disjoint files, so there is no leaf-first constraint
among them and they land in any order, one commit each: T2, T3, T9, T4, T6, T14. Each commit runs the full
suite through the hook, so the box must be quiet first -- new spawns pause once the current reviews and fix
rounds resolve, rather than keeping the queue full at the cost of an unreadable suite.

Approved by the panel, queued to land:

- **T2** — APPROVE, no blockers, two NITs (message phrasing; a confirmation that keeping the refusal on
  `Catalog::Malformed` rather than `Config::Refusal` is right, since the latter is built around TOML
  `path:`/`table:` semantics a `skill.md` has no answer for). Probe confirmed non-String and `nil`
  front-matter keys raise loudly and that `nil` VALUES for known keys still load as before.
- **T9** — APPROVE after one fix round. Closes a live hole: `Approval::SecretSurface` compares
  `answer.confidence.to_f >= @threshold` (`secret_surface.rb:106`) with nothing re-checking range, so a
  reply of `confidence: 90, verdict: "approve"` cleared any threshold and released a secret. The oracle
  digest does move (an `inclusion:` is lifted into the emitted schema); no committed fixture is keyed on
  the old one, which **T8 inherits** -- `apply_enum` lifts only `options[:in]`, never `:message`, so a
  custom message and the constant extraction move it no further.
  The fix round caught a regression the first pass missed: an exact `inclusion:` disagreed with
  `confident?`'s deliberate `.strip.downcase`, so `"Approve"` became an oracle fault where it used to be
  approved. Normalization now happens on assignment via a `verdict=` override, making the STORED answer
  canonical rather than merely tolerated at one call site; `SCHEMA` owns `instance_method(:verdict=)` with
  `ActiveModel::Attributes` below it, and `Tool::Input` exposes no `write_attribute` to bypass it.
  A pleasant accident, verified: Ruby's `String#strip` is ASCII-only, so a NON-BREAKING space around
  `approve` is still refused rather than accepted as a lookalike -- it fails closed.

**Follow-up findings recorded here rather than fixed, each out of its card's scope:**

1. `lib/lain/approval/secret_surface.rb:106`'s `.strip.downcase` is now redundant, since T9 normalizes once
   at the boundary. Left deliberately: collapsing it would put a second security-relevant class into a diff
   that was on its last review round. Its own commit, saying why.
2. ActiveModel's `:float` coercion turns a non-numeric `confidence` (`"banana"`) into `0.0` BEFORE any
   validator runs, so a garbled reply is journalled as a sincere zero-confidence answer -- quietly polluting
   the calibration data `DEFAULT_THRESHOLD`'s own comment says should drive it. Predates this chunk;
   `true` coerces to `1.0` the same way.

## Open decisions

1. **Cross-provider per-skill models are out of scope.** `Seam` holds one provider; a skill naming a model
   from another provider's namespace raises. Whether to grow a provider-resolving seam is deferred.
2. **Default tier bindings ship empty.** The measured recommendations (`qwen3.8:27b` reviewer/vision,
   `laguna-xs-2.1` cheap rung, never `qwen3-coder` for verdicts, `lfm2.5` unusable on 0.34.4) go in the QA
   skill's `tiers` slot as documentation, not as hard-coded defaults — a project states its own binding.
3. **Blob retention/GC is deferred.** T7 writes durable blobs and records the gap; nothing prunes them yet.
   Named here so a reader does not read the absence as an oversight.
4. **Audio stays research-only.** No card. `research-media-qa-tiers.md` holds the findings.
5. **Collapsing the three verdict vocabularies is deferred.** `Approval::Escalation::Ruling::VERDICTS`
   (`allow/deny/abstain`), `Oracle::SecretRead`'s `approve/deny/defer` and `Review::VERDICTS` already spell
   one three-valued answer three ways. T12 adds a fourth (`pass/fail/unverified`) whose `unverified` is
   `abstain` again. With no back-compat obligation the right move is one vocabulary, but it touches the
   approval path this chunk otherwise leaves alone — T12 must state why its spelling differs rather than
   quietly adding to the pile.
6. **RESOLVED during execution -- an unknown capability PROCEEDS, and that narrows T13's criterion.**
   T6's reader answers three-valued: supported / unsupported / unknown. Unknown proceeds, so the gate
   refuses on `UNSUPPORTED` **only**. The argument is an asymmetry: `Deployment#model_metadata?` is
   `local?`, so every *hosted* model reads unknown by construction, while the measurements show hosted
   models (`glm-5.3-flash`, `deepseek-v4.1-flash`) DO have vision -- refusing on unknown would blind them
   with no way to discover the tool. And the two errors cost differently: offering a tool a model cannot
   use costs one loud turn, withholding one it can use is silent and permanent.
   The cost, stated rather than buried: a local model whose `/api/show` **failed** -- timeout, 404, 500,
   garbage body -- also reads unknown, and is offered a vision tool it may not have. The panel found this
   restated inside T6's docstring, which is the wrong place for it: a dependency's documentation may not
   redefine a consumer's acceptance criterion. T13's criterion above is amended to match, and T13 must
   read the policy from here rather than from the reader it consumes.

7. **The live `/model` switch still does not reach children** (`lib/lain/cli/switchboard.rb:220`). T10 does
   not change that; a skill's model is resolved from its front-matter over the run profile.

## Waves

```
Wave 1: T1, T2, T3, T4, T7, T9
Wave 2: T5 (←T1), T6 (←T1), T12 (←T3), T14, T15 (←T2)
Wave 3: T8 (←T5,T9), T11 (←T5,T7), T20 (←T12)
Wave 4: T13 (←T6,T11), T16 (←T8,T12,T15,T20)
Wave 5: T17 (←T15,T16,T20), T18 (←T14,T16), T19 (←T1,T4,T5,T6)
```

Critical path: **T3 → T12 → T20 → T16 → T17** (silence becomes typed → the QA vocabulary → the inputs QA
reads → the ladder → the surface that constructs all of it). Five deep; `T1 → T5 → T8 → T16 → T17` is the
same length through the oracle.

Several dependencies are **file ordering, not logic**: T5 and T6 wait on T1 because all three edit
`lib/lain/provider/ollama/encoding.rb` or `spec/lain/provider/ollama_recorded_spec.rb`; T8 waits on T5
(`lib/lain/cli/backend.rb`) and T9 (`spec/lain/oracle/secret_read_spec.rb`); T11 waits on T5 (the encoder).
An orchestrator that can prove no overlap may pull them earlier.

**Cut during panel review:** a card that would have made `Agent` react to an empty reply. It was a no-op —
`loop_machine` already has its `:malformed` event and `FAILURE_REASONS` already has the row, so the behaviour
falls out of T3 the moment the decoder says `:malformed`. Its two scenarios became regression criteria on T3.
Card ids are not contiguous as a result; nothing is missing.

## Tasks

### T1 — Cherry-pick the two parked correctness fixes onto main [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/context_window.rb`, `spec/lain/context_window_spec.rb`,
`lib/lain/provider/ollama/encoding.rb`, `spec/lain/provider/ollama/encoding_spec.rb`,
`spec/lain/provider/ollama_recorded_spec.rb`
**Reuse:** branch `local-models-quick-wins` commits `8d2ce30a` and `07a5e161` — both written against this
tree and green; `git cherry-pick` rather than retyping.
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama#complete` → `Encoding#encode` (the refusal) and
`CLI::Backend#context_window` → `ContextWindow#resolve` (the rows).

**Acceptance criteria:**

```gherkin
Scenario: a structured format and tools in one ollama request is refused
  Given a Request carrying a structured_output schema and a non-empty toolset
  When the ollama encoder encodes it
  Then it raises naming both fields, rather than emitting a payload whose tools are ignored

Scenario: the three new cloud models resolve to their published window
  Given the model id "glm-5.3:cloud"
  When the context window is resolved
  Then it answers 1000000 with published provenance, not the 8192 guess
```
→ spec files: `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/context_window_spec.rb`

**Escalation triggers:**
- The cherry-pick conflicts because another card already touched `encoding.rb` — stop; T1 must land first in
  its wave.
- `spec/lain/provider/ollama_recorded_spec.rb`'s second turn no longer sends tools as the parked commit
  arranged: the cassette records a request that *did* carry both, and replay matches on method+URI only.
  If a body matcher has appeared since, stop.

### T2 — Refuse a skill front-matter key nobody reads [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/skill/catalog.rb`, `spec/lain/skill/catalog_spec.rb`
**Reuse:** `Lain::Config::Epics::KEYS` + `Config::Refusal.unknown_keys` (`lib/lain/config/epics.rb`) as the
refusal idiom; `Skill::Catalog::Malformed` (`catalog.rb:21`) as the existing loud failure.
**Shared-file wiring:** none
**Reachable from:** `CLI::Backend#library` (`lib/lain/cli/backend.rb:511`, memoized) → `Skill::Library.load` → `Skill::Catalog.load`, on every run that resolves a skill.

**Acceptance criteria:**

```gherkin
Scenario: a typo in skill front-matter is refused rather than ignored
  Given a skill whose front-matter declares "slot" instead of "slots"
  When the catalog loads it
  Then it raises naming the unknown key, the skill, and the known keys

Scenario: the shipped skills still load
  Given the eight shipped skills
  When the catalog loads them
  Then every one is present with its description
```
→ spec file: `spec/lain/skill/catalog_spec.rb`

**Escalation triggers:**
- A shipped or `.lain/skills/` skill in this repo already carries an unrecognized key — that is a finding,
  not a fixture to edit silently; report it.
- T15 is the card that depends on this refusal (a typo'd `model:` must be loud, not ignored). If T15 has
  already landed, this card's refusal will red its fixtures — stop and re-cut rather than widening the
  known-key list to make them pass.

### T3 — A reply that says nothing becomes a typed outcome [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/decoding.rb`, `lib/lain/telemetry/malformed_response.rb`,
`spec/lain/provider/ollama/decoding_spec.rb`, `spec/lain/telemetry/malformed_response_spec.rb`,
`spec/lain/agent_spec.rb`
**Reuse:** `Telemetry::MalformedResponse` `kind:` (`lib/lain/telemetry/malformed_response.rb:54`) and its
existing `:prose_tool_call` precedent (`decoding.rb:78-84,109-112`); `StopReason::MALFORMED`, which
**already** has its `loop_machine` event (`lib/lain/agent/loop_machine.rb:53`) and its `FAILURE_REASONS` row
(`lib/lain/agent.rb:58-62`) — so the agent already fails loudly once the decoder says `:malformed`;
**`Lain::Blankness.blank?`** (`lib/lain/blankness.rb:22-32`) replacing the decoder's private byte-equality
`blank?` (`decoding.rb:179-181`), which this card DELETES.
**Shared-file wiring:** none
**Reachable from:** `Provider::Ollama#complete` → `Decoding#build_response` — the only construction point for
this arm, reached by every local turn.

**Acceptance criteria:**

```gherkin
Scenario: an empty reply is malformed, not a finished turn
  Given ollama answers 200 with empty content, no tool calls and no thinking
  When the provider decodes it
  Then the response stop reason is malformed
  And a MalformedResponse telemetry record of kind empty_answer names the model

Scenario: a truncated reply is recorded as well as stopped
  Given ollama answers with done_reason "length" and empty content
  When the provider decodes it
  Then the response stop reason is max_tokens
  And a MalformedResponse record of kind empty_answer is emitted, so a caller can tell a
    spent ceiling apart from a model that chose to stop

Scenario: whitespace-only content counts as nothing at all
  Given ollama answers with content of a single non-breaking space
  When the provider decodes it
  Then it is treated as an empty answer rather than as a text block

Scenario: the agent fails rather than settling on silence
  Given a provider that returns an empty reply
  When the agent runs a turn
  Then it settles failed, naming the malformed journal record, rather than reporting a finished turn
```
→ spec files: `spec/lain/provider/ollama/decoding_spec.rb`, `spec/lain/agent_spec.rb`

**Escalation triggers:**
- An existing spec asserts that an empty ollama reply settles as `:end_turn` — that is the behavior being
  deliberately reversed; stop and confirm rather than editing it quietly.
- `decoding.rb:169` ALREADY maps `done_reason: "length"` to `:max_tokens`, so the second scenario must fail
  on the RECORD, not on the stop reason. If it passes before any change, the AC is not pinning what is new.
- Swapping in `Blankness.blank?` changes an existing example's verdict for a zero-width or mojibake payload:
  report which, since the decoder's byte-equality was load-bearing somewhere.
- `Tools::Subagent#undeliverable` (`lib/lain/tools/subagent.rb:590-599`) already answers "it answered nothing
  when asked" on an empty child reply, BEFORE its malformed branch. If this card's change makes that path
  unreachable or double-reported, stop — one phrasing for one idea.
### T4 — Default `num_batch` on the ollama arm [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb`, `spec/lain/cli/backend_spec.rb`, `spec/lain/cli_spec.rb`
**Reuse:** `Backend#sampler_extra` (`backend.rb:724-729`) and its `.compact` discipline; `OLLAMA_ONLY_KEYS`
(`:44`); the measured rationale already written at `lib/lain/provider/ollama/encoding.rb:25-31`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Backend#context` → `#sampler_extra` → `Request#extra` → `Ollama::Encoding#encode_options`,
i.e. every ollama chat turn.

**Acceptance criteria:**

```gherkin
Scenario: an ollama chat sends a batch size without the human typing one
  Given a chat on the ollama provider with no --num-batch flag and no LAIN_NUM_BATCH
  When a turn is encoded
  Then the request options carry num_batch 2048 alongside num_predict

Scenario: a typed flag still wins
  Given --num-batch 512
  When a turn is encoded
  Then the request options carry num_batch 512

Scenario: the anthropic arm is unchanged
  Given a chat on the anthropic provider
  When a turn is encoded
  Then no num_batch reaches the request
```
→ spec files: `spec/lain/cli/backend_spec.rb`, `spec/lain/cli_spec.rb`

**Escalation triggers:**
- `spec/lain/cli_spec.rb:862` asserts the encoded options are exactly `[:num_predict]`, and
  `spec/lain/cli/backend_spec.rb` has sibling no-options examples. This card changes both expectations;
  confirm them rather than deleting the examples.
- **`exe/lain:456-462` argues the opposite in prose** — "A literal fallback would put an `options` object on
  every ollama request in the process, a wire change for callers that never asked for one." That comment
  becomes false here. It must be rewritten or deleted in the same commit (T19 owns the rest of `exe/lain`'s
  prose); leaving it standing as a false constraint is a lint failure of its own.
- `Oracle::SecretRead.tier(options:)` (`lib/lain/oracle/secret_read.rb:135-140`) exists so the judge shares
  the chat's runner knobs. A default resolved only in `Backend#sampler_extra` that the oracle's own resolver
  never sees reloads the runner twice (`backend.rb:288-291` measured 29.4 s vs 1.6 s) — check that path
  explicitly before claiming the card is done.

### T5 — `keep_alive` on the ollama request path [wave 2] [risk: medium]

**Depends on:** T1 (both edit the ollama encoder and its spec)
**Files:** `lib/lain/provider/ollama/encoding.rb`, `lib/lain/cli/run_profile.rb`, `lib/lain/cli/backend.rb`,
`lib/lain/cli/resume/mismatch_notices.rb`, `spec/lain/provider/ollama/encoding_spec.rb`,
`spec/lain/cli/run_profile_spec.rb`, `spec/lain/cli/backend_spec.rb`
**Reuse:** `THINK_KEY`'s shape — a top-level wire field carried on `Request#extra`, not a sampler key
(`encoding.rb:43,83-89`); `RunProfile::FIELDS` (`run_profile.rb:19`) and `EnvDefaults.string`
(`lib/lain/cli/env_defaults.rb:45`) for nil-on-unset.
**Shared-file wiring:** `exe/lain` — declare `--keep-alive` (string, no Thor default, matching the
`--num-batch` posture at `exe/lain:464-469`).
**Reachable from:** `CLI::Backend#sampler_extra` → `Request#extra` → `Ollama::Encoding#extra_flag_fields`, so a
plain `lain chat --provider ollama --keep-alive -1` pins the runner.

**Acceptance criteria:**

```gherkin
Scenario: a pinned model stays resident
  Given a chat started with --keep-alive -1 on the ollama provider
  When a turn is encoded
  Then the request carries keep_alive as a top-level field, not inside options

Scenario: silence sends nothing
  Given no --keep-alive flag and no LAIN_KEEP_ALIVE
  When a turn is encoded
  Then the payload carries no keep_alive key at all
```
→ spec files: `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- `spec/lain/provider/ollama/encoding_spec.rb:73-79` currently uses `"keep_alive" => "5m"` as its example of
  an **unknown key that must be dropped**. This card inverts that example's meaning — replace the example's
  unknown key with a genuinely unknown one and say so; do not simply delete the example.
- A sixth `RunProfile` field ripples further than expected (`FIELDS`, `exe/lain` ModelFlags twice,
  `Backend::OLLAMA_ONLY_KEYS`/`RUNNER_KEYS`, `mismatch_notices.rb:19` LABELS) — if any of those refuses a
  string-valued knob where every sibling is numeric, stop.

### T6 — Read a model's capabilities from the server [wave 2] [risk: medium]

**Depends on:** T1 (both touch `spec/lain/provider/ollama_recorded_spec.rb`)
**Files:** `lib/lain/provider/ollama/model_capabilities.rb` (new), `lib/lain/provider/ollama.rb`,
`lib/lain/provider/ollama/deployment.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`spec/lain/provider/ollama/model_capabilities_spec.rb`, `spec/lain/provider/ollama/deployment_spec.rb`,
`spec/lain/provider/ollama_recorded_spec.rb`
**Reuse:** `Transport#model_details` — the `/api/show` POST already wired
(`lib/lain/provider/ollama/transport.rb:129-131`), gated to local by `Deployment#model_metadata?`
(`deployment.rb:305`); `ContextWindow`'s typed-provenance idiom (`context_window.rb:227-230,352-377`) and its
`Declarative` inclusion validation; the committed cassette `spec/fixtures/vcr_cassettes/ollama_show.yml`,
which already records `capabilities: ["completion","tools","thinking"]`.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` → `Wiring::ToolsetBuild#initialize` (which already holds `backend:` and
`provider:`, `toolset_build.rb:170-178`) → memoized reader available to `#capability_floor`. T13 is its first
behavioral consumer, in this same chunk.

**Acceptance criteria:**

```gherkin
Scenario: a model's vision support is answered from the server
  Given a local ollama serving a model whose /api/show reports vision
  When the capabilities for that model are read
  Then vision is reported as supported, with probed provenance

Scenario: a server that cannot answer degrades honestly
  Given an /api/show call that fails or omits capabilities
  When the capabilities for that model are read
  Then the answer reports unknown provenance rather than asserting absence

Scenario: the cloud arm does not probe
  Given an ollama cloud deployment
  When the capabilities for a model are read
  Then no /api/show request is made and the answer is unknown

Scenario: thinking is answered per model rather than per provider
  Given two local models, one reporting thinking and one not
  When each is asked whether it supports thinking
  Then the answers differ, rather than both inheriting one provider-wide claim
```
→ spec file: `spec/lain/provider/ollama/model_capabilities_spec.rb`

**Escalation triggers:**
- `Deployment::CAPABILITIES` (`deployment.rb:99`) currently claims `thinking` for **every** ollama model —
  a provider-wide assertion the measurements disprove per model. This card should make `thinking` answer
  from the per-model reader and **delete** it from that constant, leaving it to hold wire-level facts only.
  If deleting it reddens `Provider#supports?` callers in a way that cannot be resolved inside this card,
  stop and report rather than leaving two sources of truth for one fact.
- An `/api/show` probe per turn regresses latency: `#context_window_tokens` is deliberately un-memoized and
  `spec/support/ollama_probe.rb:43-49` makes an N-turn cassette need N probes. Memoize per model; if a
  recorded spec reddens on probe counts, report it.
- If the reader is reached from anywhere that does not already hold the backend (for instance
  `BaseTools.build`, which takes no model at all), the seam is wrong — stop.
### T7 — One content-addressed blob, used for snapshots and attachments alike [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/content_addressed/blob.rb` (new), `lib/lain/attachment/store.rb` (new),
`lib/lain/workspace/snapshot.rb`, `lib/lain/paths.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`spec/lain/content_addressed/blob_spec.rb`, `spec/lain/attachment/store_spec.rb`,
`spec/lain/workspace/snapshot_spec.rb`
**Reuse:** `Workspace::Snapshot::Blob` (`lib/lain/workspace/snapshot.rb:58-76`) — this card EXTRACTS its
`"<tag> <size>\0"` blake3 construction rather than writing a third copy of it (`Sensitivity::Regions`'
`sensitive-region-v1` framing at `regions.rb:361-368` is the second), and has `Snapshot` use the extraction;
`ContentAddressed` (`lib/lain/content_addressed.rb:26`); `Paths#container` (`lib/lain/paths.rb:270`) beside
`sessions_dir` (`:275-277`); `Event#payload_digest` (`lib/lain/event.rb:122,161-190`) as the
reference-vs-inline idiom, including its loud `#body` refusal.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` → `Wiring::ToolsetBuild#initialize` constructs **one**
`Attachment::Store` per run against `Paths#container("attachments", key: project_hash)` and exposes it; T11's
middleware and T13's tool both take **that** object. This card owns the single construction site so the two
consumers cannot address different directories.

**Acceptance criteria:**

```gherkin
Scenario: bytes survive the process that wrote them
  Given an attachment written in one process
  When a second process opens the same project's store
  Then the bytes are fetched back byte-identically by digest

Scenario: one store serves the whole run
  Given a run wired from the real CLI construction path
  When the attachment store reached by the tool layer is compared with the one reached by the model stack
  Then they are the same object, addressing one directory

Scenario: an attachment digest cannot collide with a workspace blob digest
  Given identical bytes stored as a workspace snapshot blob and as an attachment
  When both digests are computed
  Then they differ, because each domain-separates with its own tag

Scenario: extracting the blob changed no existing digest
  Given a workspace snapshot of known bytes
  When its blob digest is computed after the extraction
  Then it equals the digest recorded before it

Scenario: a missing attachment refuses loudly
  Given a digest no store holds
  When its bytes are fetched
  Then it raises naming the digest and the store, rather than answering nil
```
→ spec files: `spec/lain/content_addressed/blob_spec.rb`, `spec/lain/attachment/store_spec.rb` (`:seam` — real
files), `spec/lain/workspace/snapshot_spec.rb` (the unchanged-digest regression)

**Escalation triggers:**
- `lib/lain/sensitivity/regions.rb:364-365` warns that reusing the `blob` tag silently merges namespaces. The
  extraction must keep Snapshot's existing tag byte-identical, or every recorded snapshot digest moves — if
  any committed fixture or spec pins one, stop.
- `Canonical.normalize` interns every String with `-@` (`lib/lain/canonical.rb:35`); if a digest reference
  ever carries raw bytes through it, the intern table grows without bound — that is the failure this card
  exists to prevent, so report any path that still does it.
- The store needs a retention story it does not have (Open decision 3). If a caller within this chunk would
  grow it unboundedly, stop.
### T8 — Give oracle answers a budget that fits a thinking model [wave 3] [risk: medium]

**Depends on:** T5 (`lib/lain/cli/backend.rb`), T9 (`spec/lain/oracle/secret_read_spec.rb`)
**Files:** `lib/lain/oracle/model.rb`, `lib/lain/cli/backend.rb`, `spec/lain/oracle/model_spec.rb`,
`spec/lain/oracle/secret_read_spec.rb`
**Reuse:** `Ollama::Encoding::THINK_KEY` (`encoding.rb:43`) — the `extra` channel an oracle already has but
never uses; `Provider#supports?` (`lib/lain/provider.rb:64`) for the arm check; `Backend#summarizer_max_tokens`
(`backend.rb:272-275`) as the existing ceiling idiom.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#secret_read` → `Oracle::SecretRead.tier` (`lib/lain/oracle/secret_read.rb:135-140`)
and `CLI::Backend::Summarizer#tier` — both live production oracle paths.

**Acceptance criteria:**

```gherkin
Scenario: an oracle over a thinking model does not spend its ceiling thinking
  Given an oracle tier on the ollama provider
  When it asks its question
  Then the request disables thinking, so the ceiling is spent on the answer

Scenario: an empty answer is retried once, then reported honestly
  Given a provider that returns an empty reply to an oracle's first ask
  When the oracle asks
  Then it retries once at the same ceiling
  And if the retry is also empty it raises an undecodable answer naming emptiness as the cause

Scenario: the anthropic arm is untouched
  Given an oracle tier on the anthropic provider
  When it asks its question
  Then the request carries no thinking field
```
→ spec file: `spec/lain/oracle/model_spec.rb`

**AMENDED during execution — the retry does NOT get "more room", and the original wording rested on an
assumption the measurement contradicts.** The card said "retried once with a larger ceiling". T8's panel
mutation-probed it: with thinking left on, the doubled 2048 ask came back empty too — the raise reads
literally `at 1024 tokens and again at 2048`. So doubling did not convert the case that motivated the card.
Separately, `mutant_no_retry_T8.rb` showed the live spec stays green with the retry removed entirely: what
fixes it is `think => false`, not the retry. The retry's remaining value is nondeterminism — a model that
said nothing once may say something the second time — and that value does not need a bigger ceiling.
Retrying at the same ceiling also dissolves the unclamped-ceiling hazard, since `Backend::Ceiling#tokens`
validates positivity only and nothing in `lib/lain/provider/` clamps `max_tokens`, so a doubled
`--summarizer-max-tokens` already at a model's output cap would have become a provider 400 naming a ceiling
the operator never chose.

**Escalation triggers:**
- `spec/lain/oracle/secret_read_spec.rb:240` is a live `:ollama` spec that fails on BOTH ollama builds today
  for exactly this reason — it should go green here. If it does not, the diagnosis was wrong; stop rather
  than loosening the example.
- A retry doubles an oracle's cost at every call site; `Approval::SecretSurface` is fail-closed on a clock
  (`lib/lain/approval/secret_surface.rb:123-124`). If the retry can exceed that bound, stop.
- `Oracle::Recorded` replays are digest-keyed; if adding `think` to `extra` changes a recorded oracle's
  digest and reddens a replay spec, report it — `extra` is excluded from `Request#cache_payload` but the
  oracle digest is computed separately.

### T9 — Constrain the answers an oracle will accept [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/oracle/secret_read.rb`, `spec/lain/oracle/secret_read_spec.rb`
**Reuse:** `Tool::Input`'s ActiveModel validations — `validates :timeout, numericality: {...}`
(`lib/lain/tools/bash.rb:143`) and `validates :stage, inclusion: {...}` (`lib/lain/tools/request_review.rb:103`)
are the in-repo precedents; `Tool::Input.apply_enum` (`lib/lain/tool/input.rb:438-441`) already lifts an
`inclusion:` into the emitted JSON Schema.
**Shared-file wiring:** none
**Reachable from:** `Approval::SecretSurface` → `SecretRead.tier` → `Definition#answer`, the live gate that
decides a secret read.

**Acceptance criteria:**

```gherkin
Scenario: a confidence outside the stated range is refused
  Given an oracle reply whose confidence is 90 where the schema means 0.0 to 1.0
  When the answer is built
  Then it raises an invalid answer rather than returning a schema-valid nonsense value

Scenario: a verdict outside the three allowed words is refused
  Given an oracle reply whose verdict is "maybe"
  When the answer is built
  Then it raises an invalid answer naming the allowed verdicts
```
→ spec file: `spec/lain/oracle/secret_read_spec.rb`

**Escalation triggers:**
- `Definition#digest` hashes `schema.to_json_schema` (`lib/lain/oracle/definition.rb:51-53`), and an
  `inclusion:` validator is lifted into the emitted schema — so this card **changes the oracle's digest** and
  invalidates recorded replays keyed on it. Find those replays first; if any committed fixture is keyed on
  the old digest, stop and report before re-recording.
- `Approval::SecretSurface` rescues broadly and abstains; a newly-raising validation must not turn a decided
  approval into an abstention that silently denies. Check that path explicitly.

### T11 — Carry images as digest references, resolved before dispatch [wave 3] [risk: high]

**Depends on:** T7, T5 (both edit the ollama encoder)
**Files:** `lib/lain/attachment/reference.rb` (new), `lib/lain/middleware/resolve_attachments.rb` (new),
`lib/lain/provider/ollama/encoding.rb`, `lib/lain/provider/anthropic_encoding.rb`, `lib/lain/cli/wiring.rb`,
`lib/lain/tools/subagent.rb`, `spec/lain/middleware/resolve_attachments_spec.rb`,
`spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `Wiring#model_phase` (`lib/lain/cli/wiring.rb:686-695`) — the composition point whose own comment
says why the model stack is assembled there and **not** in `Chronicle.instrumentation`, "which has no model
stack at all under `--no-journal`"; `Agent::ModelCaller`'s `inner.fetch(:request)` re-read
(`lib/lain/agent/model_caller.rb:36-40`); `Request#with` (a `Data`) -- **WRONG, corrected during execution: `Data#with` re-runs
`Request#initialize` -> `Canonical.normalize` -> `-@`, which interns the base64 SILENTLY, the exact
unbounded-intern cost the digest address exists to remove. T11 substituted through a decorator replacing
`#messages` only, leaving `#digest`/`#cache_payload` as the ADDRESSED request's so frame, signal and journal
name one turn. Do not "fix" that deviation back**;
`Context::Conversation::BLOCK_ROLES` (`lib/lain/context/conversation.rb:67-68`), which documents that a type
absent from it may ride any role — so `"image"` needs no whitelist change; T7's single store.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#model_phase` composes the resolver into the model stack for every run,
journalled or not; `Tools::Subagent::ChildBuilder` (`lib/lain/tools/subagent.rb:1130`) gives a child
`model_middleware: child_budget`, so this card also decides — explicitly — whether a child resolves.

**Acceptance criteria:**

```gherkin
Scenario: the journal records a reference and the provider receives bytes
  Given a message carrying an image reference block
  When a turn is dispatched
  Then the journalled request payload contains the digest and not the base64
  And the provider receives a block carrying the actual image data

Scenario: resolution does not depend on journalling
  Given a run started with no journal
  When a turn carrying an image reference is dispatched
  Then the provider still receives the resolved bytes

Scenario: a subagent's images resolve too
  Given a spawned child whose turn carries an image reference
  When the child dispatches
  Then the provider receives resolved bytes rather than a digest string

Scenario: ollama receives images in the array it expects
  Given a tool result carrying an image reference
  When the ollama encoder encodes the turn
  Then the image rides the images array on that message

Scenario: ten screenshots do not trip the compaction threshold
  Given ten exchanges each carrying one screenshot reference
  When the head's byte size is measured with Canonical.dump
  Then it stays below the 262144-byte compaction threshold
```
→ spec files: `spec/lain/middleware/resolve_attachments_spec.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/provider/ollama/encoding_spec.rb`

**Escalation triggers:**
- `Chronicle.instrumentation` returns an all-Null `Agent::Instrumentation` when the journal is nil
  (`lib/lain/cli/chronicle.rb:187-192`), so `JournalRequests` is absent under `--no-journal` and
  `insert_after` would have no anchor. If the card finds itself anchoring on that middleware, stop — compose
  in `model_phase` as the budget already does.
- A child's model stack is a single member (`subagent.rb:1130`). If the resolver is not added there, a
  subagent's image silently reaches the provider as a digest string. Decide and state it; do not leave it
  implicit.
- `Tool::ResultBlock::Text` copies any non-UTF-8 String wholesale (`lib/lain/tool/result_block.rb:193`); a
  reference block must not carry raw bytes through it.
- Anthropic and ollama disagree on image shape (`source.data` vs an `images` array). If one encoder cannot
  express a reference without the other's shape leaking into the neutral block, re-cut the seam.
### T12 — The QA report's vocabulary, where a blank answer is a finding [wave 2] [risk: medium]

**Depends on:** T3
**Files:** `lib/lain/qa.rb` (new), `lib/lain/qa/finding.rb` (new), `lib/lain/qa/answer.rb` (new),
`lib/lain/qa/report.rb` (new), `spec/lain/qa/finding_spec.rb`, `spec/lain/qa/answer_spec.rb`,
`spec/lain/qa/report_spec.rb`
**Reuse:** `planning/specs/local-models-multimodal-qa/spike-qa.patch` as the proven shape (`Qa::SEVERITIES`,
`HOLDING`, `TIERS`, `VERDICTS`, `RISKS`; a `Finding` refusing blank evidence at construction; a `Report`
parsing a fenced `qa-report` block); `Lain::Declarative` for enum validation at construction;
`Review::VERDICTS` (`lib/lain/review.rb`) as the sibling vocabulary to stay consistent with.
**Shared-file wiring:** none
**Reachable from:** deferred within this card — `Qa::Report` is constructed on the real path by T14's
`/qa` command, in this chunk.

**Acceptance criteria:**

```gherkin
Scenario: a finding without evidence cannot exist
  Given a finding built with blank evidence or a blank reproduction
  When it is constructed
  Then it raises, so an opinion cannot be filed as a finding

Scenario: an unreadable answer is unverified, never a pass
  Given a rung's reply that carries no parseable answer block
  When the answer is read
  Then its verdict is unverified
  And the report counts it as an unsettled criterion rather than a passing one

Scenario: a report with no findings still states what it ran
  Given a pass with three rungs run and two escalations
  When the report is rendered
  Then it names the rungs and escalations, so a pass is auditable
```
→ spec files: `spec/lain/qa/finding_spec.rb`, `spec/lain/qa/answer_spec.rb`, `spec/lain/qa/report_spec.rb`

**Escalation triggers:**
- **Three vocabularies for one three-valued answer already exist**: `Approval::Escalation::Ruling::VERDICTS =
  %i[allow deny abstain]` (`lib/lain/approval/escalation.rb:98` -- the plan first cited this one segment short;
  `Approval::Escalation::VERDICTS` is not defined), `Oracle::SecretRead::SCHEMA`'s
  `approve, deny, defer` (`secret_read.rb:60-61`), and `Review::VERDICTS`. If this card's `unverified` is
  `abstain` under a fourth spelling, stop and collapse rather than add — see Open decision 6.
- The spike refused a report with no fenced block rather than reading it as a pass. If that refusal makes a
  legitimate empty report unrepresentable, re-cut before inventing a second "empty" concept.

**What T7's panel proved, and what T11 and T13 still owe.** T7 proves the store is one object across reads
and across `#build`, and that its directory is `ProjectDir#container(KIND)`. It does NOT prove the criterion
the two consumers depend on, because neither consumer existed. `Attachment::Store.for` is public and
unguarded, so nothing structurally stops a second construction site. The consumers must therefore prove:

1. **Identity, not two path computations.** On one real `Wiring`, `middleware_store.equal?(tool_store)` -- `be`,
   never `eq` on `.root`. Two directories that merely compute alike is exactly what T7 exists to make
   unrepresentable. Note `Store` has no `==`, so `eq` would not mean what it looks like.
2. **The child route.** `role_spawn_seam(base)` copies the floor for spawned children, so T13 must show a
   CHILD's tool holds the same store object -- otherwise a subagent silently writes into a second directory.
3. **The `Canonical` invariant, stated precisely.** Raw bytes through `Canonical.normalize` would raise
   `UnsupportedType` (loud, fine); **base64 is valid UTF-8 and would be interned silently by `-@`**. So an
   encoded payload must never reach `Request.new` or `Context#render`. The digest reference may ride the
   Timeline -- one ~71-byte fstring per distinct blob, bounded by attachment count. The substitution belongs
   DOWNSTREAM of `Request` construction, in the provider-encoding stage: doing it inside `Context#render`
   would break the intern bound *and* `render`'s purity/cache-hit constraint at once.
4. `Wiring` delegates only `role_spawn, auto_surface`, so T11's route is `wiring.toolset_build.attachments`.

### T13 — A screenshot tool whose bytes never enter the timeline [wave 4] [risk: high]

**Depends on:** T6, T11
**Files:** `lib/lain/tools/screenshot.rb` (new), `lib/lain/tool/bounds.rb`, `lib/lain/cli/wiring.rb`,
`lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/bench/harness.rb`,
`spec/lain/tools/screenshot_spec.rb`, `spec/lain/tools/tool_surface_spec.rb`,
`spec/lain/tools/parallel_safety_spec.rb`, `spec/lain/bench/harness_spec.rb`
**Reuse:** `Tools::Bash` as the tier-3 exemplar — `requires_approval? = true` (`lib/lain/tools/bash.rb:255`)
and the class doc arguing the model-controls-the-string axis (`:5-8`); `Tool::Bounds::CEILINGS`
(`lib/lain/tool/bounds.rb:205-221`), one row per tool; T6's capability reader for the vision gate; T7's store
for the bytes; the Chrome DevTools protocol rather than the Chromium CLI, which exits 0 on a failed load
(`SPIKE-images.md`).
**Shared-file wiring:** `spec/support/tool_registry.rb` — add `screenshot` to `BUILDERS`;
`lib/lain/cli/wiring.rb` `BaseTools.build` is card scope (it is not on the shared list).
**Reachable from:** `Wiring::ToolsetBuild#capability_floor` (`toolset_build.rb:199`) — the gate belongs
there because that object holds `backend:` and therefore the session model; `BaseTools.build`
(`lib/lain/cli/wiring.rb:158-167`) takes `(recorder, exec:, verdict:, journal:)` and knows nothing about a
model, so the filter cannot live inside it.

**Acceptance criteria:**

```gherkin
Scenario: a page becomes an image the model can read
  Given a local page and a vision-capable session model
  When the model calls the screenshot tool
  Then the tool result carries an image reference
  And the bytes are fetchable from the attachment store

Scenario: a model KNOWN to lack vision is never offered the tool
  Given a session model whose capabilities report vision as unsupported
  When the toolset is built
  Then no screenshot tool is offered

Scenario: a model whose vision is unknown is still offered the tool
  Given a session model whose capabilities could not be probed
  When the toolset is built
  Then the screenshot tool IS offered, because unknown is not a no

Scenario: a failed page load is reported, not silently captured
  Given a URL that fails to load
  When the model calls the screenshot tool
  Then the tool result is an error naming the failure, rather than an image of an error page

Scenario: the tool is gated like every other model-controlled command
  Given a screenshot call
  When the gate inspects it
  Then it requires approval
```
→ spec files: `spec/lain/tools/screenshot_spec.rb` (`:seam` for the real browser), `spec/lain/tools/tool_surface_spec.rb`

**Escalation triggers:**
- `spec/lain/tools/tool_surface_spec.rb:12` holds `GATED = %w[bash]` with a comment that ungated is the
  default and gating must be argued for. Widening it needs that argument written into the spec, not just the
  list edited.
- `spec/tool_bounds_discipline_spec.rb:105-138` selects byte limits **by class**, never consulting `unit:`
  — so a pixel-denominated bound would be compared against byte rows. If this card needs a second unit, stop:
  that discipline spec must be fixed first, in its own card.
- `lib/lain/bench/harness.rb:42-55` partitions tools into WRITERS/READERS totally. A tool that writes only
  its own tmpdir is a judgement call the spec will force — make the call explicitly.
- `BaseTools.build` is also called by `lib/lain/bench/harness.rb:27` with only `recorder`/`journal`. Adding a
  required keyword to it breaks the bench and four specs — if the card finds itself changing that signature,
  the gate is in the wrong place.

### T14 — Stop the driver carrying more issues than the models can serve [wave 2] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/config/epics.rb`, `lib/lain/cli/epic_driver/factory.rb`,
`lib/lain/cli/command/implement_epic.rb`, `spec/lain/config/epics_spec.rb`,
`spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/command/implement_epic_spec.rb`
**Reuse:** `Config::Epics` `KEYS`/`TABLE`/`Refusal` (`lib/lain/config/epics.rb`) for the new `width` key;
`Provider::Admission::Endpoint.local?` (`lib/lain/provider/admission/endpoint.rb:102-110`) as the ONE
locality predicate — never a second; `Provider::Admission`'s header (`admission.rb:86-96`), which already
describes N local siblings queueing behind one another and raising `Admission::Busy` at sibling N.
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::ImplementEpic#call` → `env.epic_driver.run(width:)`
(`implement_epic.rb:36`) — the real `/implement-epic` path.

**Why this is not a second locality rule.** `Provider::Admission` already serializes local requests to one
per endpoint (`admission.rb:96,297-303`), so two local actors on the **same** model cost nothing extra — they
queue. What costs is what the probes measured: a model **swap** is 16–20 s and discards a prefix cache worth
about as much again. So the width this card resolves is a statement about *how many distinct models the run
would hold at once*, and the locality predicate only decides whether that scarcity applies at all. A hosted
endpoint keeps the existing default untouched.

**Acceptance criteria:**

```gherkin
Scenario: the derived default depends on where the model runs, not on a hard-coded number
  Given an epic run with no width flag and no configured width
  When the same run is resolved once against a local endpoint and once against a hosted one
  Then the local run carries fewer issues at once than the hosted run

Scenario: what the human typed always wins
  Given a configured width of 1 and a typed --width 3
  When the driver starts
  Then it carries three issues at a time

Scenario: a configured width outranks the derived default
  Given .lain/config.toml declaring width 4 and a local endpoint
  When the driver starts
  Then it carries four issues at a time

Scenario: an unknown key in the epics table is refused
  Given .lain/config.toml declaring widht = 2
  When the config is read
  Then it raises naming the unknown key and the known keys
```
→ spec files: `spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/config/epics_spec.rb`,
`spec/lain/cli/command/implement_epic_spec.rb`

**Escalation triggers:**
- `Arm::Epic` passes `width: nil` deliberately so "the driver's own default" applies
  (`lib/lain/arm/epic.rb:112,136`); a derived default silently changes every bench run. Decide and state it.
- `WIDTH`'s existing doc argues from human-gate latency and landing-queue conflict (`factory.rb:634-638`).
  This card adds model scarcity as a second reason. If both cannot be stated in one sentence, the constant
  should become two things — say which.
- If the resolved width ever exceeds what `Provider::Admission` will admit, actors queue against a 300 s
  deadline and the loser raises `Admission::Busy` as an issue failure. Stop rather than shipping a width that
  manufactures that.
- The driver holds no provider today (`Factory#initialize`, `factory.rb:401-403`) and reaches models only
  through `@toolset_build`. If answering "where does the model run" requires a new dependency edge into the
  Factory, name it rather than reaching through the subagent seam.
### T15 — Per-skill model choice, resolved at the spawn [wave 2] [risk: high]

**Depends on:** T2 (its unknown-key refusal is what makes a typo'd `model:` loud)
**Files:** `lib/lain/skill.rb`, `lib/lain/skill/catalog.rb`, `lib/lain/skill/role_spawn.rb`,
`lib/lain/middleware/skill_dispatch.rb`, `lib/lain/tools/subagent.rb`,
`lib/lain/prompt/templates/skill/*/skill.md`, `spec/lain/skill_spec.rb`,
`spec/lain/skill/role_spawn_spec.rb`, `spec/lain/middleware/skill_dispatch_spec.rb`
**Reuse:** `Bench::SpawnSeam#routed` (`lib/lain/bench/spawn_seam.rb:172-175`) — the exact
`Context#with_model` move, already justified in-tree; `Skill::Catalog.build` (`catalog.rb:48-57`) for the
fourth front-matter key; T2's unknown-key refusal so a typo'd `model:` is loud; `Role#child_context`
(`lib/lain/role.rb:57-60`), which shows the copy-only-what-changes discipline. **`Oracle::Router`
(`lib/lain/oracle/router.rb`) already answers "which model should this child run under"** and
`Arm::AdaptiveRouter` already threads that answer to a spawn — this card must either reuse it or state in
one line why a declared preference is a different question from a routed decision; two mechanisms for one
idea is the coupling the panel flags elsewhere.
**Shared-file wiring:** none
**Reachable from:** `Middleware::SkillDispatch#report_role_bound` (`skill_dispatch.rb:97-100`) →
`RoleSpawn#call` → `ChildBuilder#child_context` (`lib/lain/tools/subagent.rb:1190-1191`), i.e. a real
`@role/skill` invocation from the `you>` line.

**Acceptance criteria:**

```gherkin
Scenario: a skill that names a model is answered by that model
  Given a skill whose front-matter declares a model
  When it is invoked role-bound
  Then the spawned child's context carries that model
  And the parent's own model is unchanged

Scenario: a skill that names no model inherits the run's
  Given a skill with no model in its front-matter
  When it is invoked role-bound
  Then the child runs on the run profile's model

Scenario: a model from another provider is refused loudly
  Given a skill naming a model the run's provider does not serve
  When it is invoked
  Then it raises naming the skill, the model and the provider, rather than dispatching to a model that does not exist

Scenario: an inline skill has no spawn to give a model to
  Given a skill invoked inline rather than role-bound
  When it is dispatched
  Then it runs on the parent's model and the declared model is refused at load time rather than ignored at dispatch

Scenario: a caller can bind a spawn to a model without a skill declaring one
  Given a caller that spawns a role directly, naming a model
  When the child is built
  Then the child runs on that model
  And the same seam serves both a skill's declared model and a caller's chosen one
```
→ spec files: `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/middleware/skill_dispatch_spec.rb`

**Escalation triggers:**
- The window and price books are memoized for the run's ONE model (`Backend#context_window` at
  `backend.rb:357`, `Middleware::RequestBudget::Child` at `subagent.rb:1146-1150`). A child on a different
  model would measure occupancy and cost against the wrong book — if this card cannot resolve the book per
  child model, stop and report; shipping a miscounted budget is worse than no per-skill model.
- `RunProfile#to_header` (`run_profile.rb:92`) records the run's one model, so a resumed or forked session
  will not reproduce a per-skill override. Decide whether that is acceptable and say so.
- The QA ladder (T16) needs to bind several rungs of ONE ladder to several models; a model on a *skill* does
  not express that. If the spawn-level channel this card adds cannot serve both, say so — T16 depends on it.
- `execute-plan/skill.md:29` already instructs spawning with "a model matched to the card's risk" and
  `isolation: "worktree"`, **neither of which any tool schema accepts today**. If this card makes the first
  half real, the prose and the schema must stop disagreeing — report the gap rather than half-fixing it.

### T16 — The QA ladder: cheapest rung first, escalate to a different model [wave 4] [risk: high]

**Depends on:** T8, T12, T15 (the spawn-level model channel each rung binds to), T20
**Files:** `lib/lain/qa/ladder.rb` (new), `lib/lain/qa/escalation.rb` (new),
`lib/lain/qa/session_tiers.rb` (new), `spec/lain/qa/ladder_spec.rb`, `spec/lain/qa/escalation_spec.rb`,
`spec/lain/qa/session_tiers_spec.rb`
**Reuse:** `spike-qa.patch`'s ladder and its named escalation rules as the proven shape; T12's
`Answer`/`Finding`; T20's criteria and changeset; T15's spawn-level model channel, which is what binds a rung
to a model; T3's typed empty-answer outcome so a silent rung escalates instead of scoring.
**Shared-file wiring:** none
**Reachable from:** deferred within this card — the ladder is constructed on the real path by T17's `/qa`
command, in this chunk, with `SessionTiers` as the default binding.

**Acceptance criteria:**

```gherkin
Scenario: the cheap rung runs first and one model swap serves every criterion
  Given twelve criteria and a two-rung ladder
  When the ladder runs
  Then every criterion is asked at the cheap rung before any is asked at the strong rung

Scenario: a silent rung escalates rather than scoring
  Given a rung whose reply is empty or truncated
  When the ladder reads it
  Then the criterion escalates to the next rung, naming the length or emptiness as the reason

Scenario: agreement among cheap models is not enough to accept
  Given three cheap samples that unanimously pass a criterion
  And no strong-tier voice among them
  When the ladder decides
  Then the criterion is escalated rather than accepted

Scenario: an executed failure is reported without climbing
  Given a rung reporting a failure it actually executed
  When the ladder decides
  Then it reports the finding without spending a stronger model

Scenario: a criterion nothing could settle is a minor finding
  Given a criterion whose rungs are all exhausted or unavailable
  When the report is built
  Then the criterion appears as an unsettled minor finding, never as a pass

Scenario: each rung is bound to its own model
  Given a ladder whose cheap and strong rungs name different models
  When the ladder runs
  Then each rung's asks are answered by its own model
```
→ spec files: `spec/lain/qa/ladder_spec.rb`, `spec/lain/qa/escalation_spec.rb`,
`spec/lain/qa/session_tiers_spec.rb`

**Escalation triggers:**
- The measured evidence says `done_reason: "length"` must escalate to a **different model**, never the same
  model with a bigger budget (only qwen3:4b converted budget into an answer, and it found 6% of the bugs). If
  the ladder's rules permit a same-model retry, that contradicts the grounding — stop.
- `qwen3-coder:30b` wrongly passes 4 of 16 real violations identically on both ollama builds. If the ladder's
  default binding would ever place it as a verdict-holding rung, stop.
- **`Provider::Admission` serializes local requests to one per endpoint with a 300 s deadline**
  (`admission.rb:88-96`). Three samples across twelve criteria is ~36 serialized asks at the cheap rung
  alone; if a rung's budget can outlast that deadline, the loser raises `Admission::Busy` mid-pass. Bound the
  pass against the gate, not only against its own budget.
- Budgets are per rung; a rung that exhausts its budget mid-criterion must leave that criterion unsettled
  rather than half-scored. If the loop cannot express that, re-cut.

### T20 — Gather what QA checks: the diff, the cards, the claimed files [wave 3] [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/qa/claim_check.rb` (new), `lib/lain/qa/changeset.rb` (new),
`lib/lain/qa/plan_cards.rb` (new), `spec/lain/qa/claim_check_spec.rb`, `spec/lain/qa/changeset_spec.rb`,
`spec/lain/qa/plan_cards_spec.rb`
**Reuse:** `spike-qa.patch`'s three readers as the proven shape; T12's `Finding` for what a claim mismatch
becomes; the plan-document conventions this very chunk is written in (`**Files:**`, `[risk: x]`, gherkin
blocks) as the grammar `PlanCards` parses; lain's existing git reading for `base..HEAD`.
**Shared-file wiring:** none
**Reachable from:** deferred within this card — constructed on the real path by T17's `/qa` command, in this
chunk, which runs the claim check as its model-free first rung.

**Acceptance criteria:**

```gherkin
Scenario: a card that names a file the diff never touched is a finding
  Given a plan card naming a spec file
  And a changeset in which that file never appears
  When the claim check runs
  Then it reports a major finding naming the card and the missing file

Scenario: a changed file no card claims is carried as minor
  Given a changeset touching a file no card names
  When the claim check runs
  Then it reports a minor finding rather than holding the pass

Scenario: the criteria come from the plan, not from prose
  Given a plan document with three cards each carrying gherkin criteria
  When the cards are read
  Then each card's criteria, risk and claimed files are available separately

Scenario: a changeset is read from a real repository
  Given a base revision and a working head
  When the changeset is read
  Then it lists exactly the paths git reports as changed between them
```
→ spec files: `spec/lain/qa/claim_check_spec.rb`, `spec/lain/qa/changeset_spec.rb` (`:seam` — real git),
`spec/lain/qa/plan_cards_spec.rb`

**Escalation triggers:**
- The plan grammar this parses is a convention, not a schema; a plan written by hand may omit `**Files:**`
  entirely. A missing section must read as "claims nothing" rather than crashing the pass — if it cannot,
  say so.
- `Qa::Changeset` reads git in the checkout it is handed. If that is the epic's landing checkout rather than
  a throwaway one, it can observe a tree mid-merge — that is T17's open question surfacing here; stop rather
  than reading a dirty tree.
### T21 — Give the epic driver the endpoint it resolves width from [risk: medium]

**Opened during execution**, from T14's panel review. T14 shipped `Run.width_for` and an `endpoint:` seam that
production never fills, so AC1 -- the locality-derived default, the behaviour the card is named for -- is true
of the seam and false of `/implement-epic`, which still carries 2 against local ollama. That is the exact
pathology T14 exists to fix, so the card is not closed until this lands.

**Depends on:** T14
**Files:** `lib/lain/provider/admitted.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/cli/epic_driver/factory_spec.rb`
**Reuse:** `Provider::Admitted#resolved_endpoint` (`admitted.rb:61`, `anthropic.rb:114`, `ollama.rb:440`) --
documented verbatim as *"the endpoint THIS provider will really talk to, which is the only honest key"*, per-provider
correct, and **the same string `Admission.for` keys on**, so the driver and the gate agree by construction rather
than by coincidence. It is `private` today; this card makes it public. `spec/lain/cli/wiring_spec.rb:1787`
already spies `EpicDriver::Seams.new`.

**Explicitly NOT `Backend#endpoint`** -- see the retraction above. A card that reaches for it has taken the
wrong turn.

**Acceptance criteria:**

```gherkin
Scenario: a local epic run carries one issue at a time, through the real command
  Given /implement-epic on a backend whose provider resolves a local endpoint
  When the driver starts with no typed and no configured width
  Then it carries one issue at a time

Scenario: a hosted epic run is not halved
  Given /implement-epic on an anthropic backend with no --api-base
  When the driver starts with no typed and no configured width
  Then it carries the hosted default, because anthropic's resolved endpoint is not localhost

Scenario: the factory joins config, seam and derivation on the real path
  Given a Factory built with an endpoint seam and a config declaring no width
  When #run resolves
  Then the width is the derived one, exercised without an explicit width argument
```
→ spec files: `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/epic_driver/factory_spec.rb`

**Escalation triggers:**
- `assemble_surface(agent:, library:, window:)` (`wiring.rb:971`) does **not** hold `backend` -- it is a parameter
  of `build_repl` (`:947`). So this is not "one keyword": it needs one on `assemble_surface` too, in the one method
  `wiring.rb:35-40`'s own comment already calls awkward to move. If threading it there looks wrong, read that
  comment before working around it.
- The anthropic example is the point of the card, not a bonus: it is the assertion that catches the
  `Backend#default_base` mistake, and **no unit example on `width_for` can catch it**. If it cannot be written,
  stop.
- Making `resolved_endpoint` public widens a provider's surface. If a second caller wants it for something other
  than keying admission, that is a different question -- say so rather than generalising it.

### T17 — `/qa`, the qa role, and the optional step after execute-plan [wave 5] [risk: medium]

**Depends on:** T15, T16, T20
**Files:** `lib/lain/cli/command/qa.rb` (new), `lib/lain/cli/command/surface.rb`,
`lib/lain/role/catalog.rb`, `lib/lain/prompt/templates/role/qa.md` (new),
`lib/lain/prompt/templates/skill/qa/skill.md` (new), `lib/lain/prompt/templates/skill/qa/tiers.md` (new),
`lib/lain/prompt/templates/skill/execute-plan/skill.md`, `spec/lain/cli/command/qa_spec.rb`,
`spec/lain/role_spec.rb`, `spec/lain/skill/shipped_skills_spec.rb`
**Reuse:** `Role::Catalog::BUILT_INS` (`lib/lain/role/catalog.rb:19-84`) — 16 existing roles, the `only:` and
`unattended:` idiom; `CLI::Command::Args.parse` and the `--width` flag handling in
`lib/lain/cli/command/implement_epic.rb:59-74` as the flag idiom; T15's per-skill model so the `qa` skill
states its own rung models; `spike-qa.patch`'s `/qa PLAN --base REF` surface and `.lain/qa/<plan>-<head12>.md`
report path.
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Surface` registers `/qa`; a human typing `/qa planning/specs/foo.md`
constructs `Qa::PlanCards`, `Qa::Changeset`, `Qa::ClaimCheck`, `Qa::Ladder` (bound by `Qa::SessionTiers`) and
`Qa::Report` on the real path — this is the card that makes T12, T16 and T20 reachable, and at least one of
its acceptance criteria runs through that construction rather than an injected double.

**Acceptance criteria:**

```gherkin
Scenario: a human runs QA against a plan and gets a report on disk
  Given a plan document and a base revision
  When /qa is run
  Then a markdown report is written naming findings, rungs run and escalations
  And the reply states pass or hold with the finding counts

Scenario: QA reports and never fixes
  Given a QA run that finds a blocker
  When the run completes
  Then no file in the working tree has been modified by it

Scenario: the qa role cannot write
  Given the qa role
  When its toolset is built
  Then it holds only read and search tools
```
→ spec files: `spec/lain/cli/command/qa_spec.rb`, `spec/lain/role_spec.rb`

**Escalation triggers:**
- The spike's first open question: QA runs in the epic's landing checkout today and wants a detached,
  throwaway one. If `/qa` cannot get a read-only checkout without inventing isolation machinery, stop.
- `unattended: true` plus `bash` still parks at the approval gate in `ask` mode (spike finding). If the qa
  role parks, the whole ladder stalls — confirm the gate behavior before shipping.
- `spec/lain/skill/shipped_skills_spec.rb` pins skill prose against code constants; the qa skill's rules must stay
  in sync with `Qa::Escalation::RULES` or that spec will red — keep one source.

### T18 — The epic QA gate as a checkpoint in the blocking graph [wave 5] [risk: high]

**Depends on:** T16, T14
**Files:** `lib/lain/epic/qa_checkpoint.rb` (new), `lib/lain/cli/epic_driver/qa_gate.rb` (new),
`lib/lain/cli/epic_driver/factory.rb`, `lib/lain/cli/epic.rb`,
`spec/lain/epic/qa_checkpoint_spec.rb`, `spec/lain/cli/epic_driver/qa_gate_spec.rb`,
`spec/lain/cli/epic_driver/run_spec.rb`
**Reuse:** `Epic::Graph#add(discovered_from:)` (`lib/lain/epic/graph.rb:163-171`) — provenance, deliberately
not an edge; `Epic::Blockage.of` and `Run#ready` (`factory.rb:930-934`); `spike-qa.patch`'s `qa-gate-*` id
convention and its `Unaudited` Null; the spike's rejected alternatives (a new `Issue` field changes every
digest; a new `Epic::STAGES` member cannot sit between clusters of one stage).
**Shared-file wiring:** none
**Reachable from:** `EpicDriver::Factory` wires the real `QaGate` into `Run`, so `/implement-epic` runs
ready checkpoints before filling the next cluster.

**Acceptance criteria:**

```gherkin
Scenario: a cluster's QA runs before the next cluster starts
  Given an epic whose graph holds a qa gate blocked by a cluster of issues
  When that cluster lands
  Then the gate runs before any issue it blocks is launched

Scenario: a holding finding becomes an issue that blocks the gate
  Given a gate run that returns a blocking finding
  When the gate settles
  Then a new issue is filed carrying the finding, blocking the gate
  And the gate re-runs after that issue lands

Scenario: a passing gate releases the next cluster
  Given a gate run with no holding findings
  When the gate settles
  Then the gate is done and the issues it blocked become startable
```
→ spec files: `spec/lain/cli/epic_driver/qa_gate_spec.rb`, `spec/lain/cli/epic_driver/run_spec.rb`

**Escalation triggers:**
- A fix issue whose id could be read as a checkpoint would make the gate block itself. The spike mints
  `qa-fix-<n>-<k>` precisely to prevent that — if the id scheme allows ambiguity, stop.
- `Run#drive` refolds greedily; a checkpoint that is ready but never run would deadlock the epic. Assert the
  refold path explicitly.
- If the gate needs the QA ladder to run against a checkout the driver does not hold, stop — that is T17's
  open question surfacing again at a harder site.

### T19 — Correct the ollama docs to the build we actually run [wave 5] [risk: low]

**Depends on:** T1, T4, T5, T6
**Files:** `docs/providers/ollama.md`, `DEBUGGING_OLLAMA.md`, `lib/lain/provider/ollama/encoding.rb`
(comment only), `spec/lain/provider/ollama_spec.rb` (comment only)
**Shared-file wiring:** `exe/lain` — the `--num-batch` `desc:` string at `:456-469` still tells the human
that ollama's default is 512 and that a literal fallback would be a wire change; T4 makes both false. The
orchestrator applies the corrected wording this card supplies.
**Reuse:** `planning/specs/local-models-multimodal-qa/UPGRADE-ollama-0.34.4.md` — the measured comparison,
the dense-vs-MoE prefill split, the GPU-contention lesson and the upstream issue map.
**Reachable from:** documentation; no production construction. Its correctness gate is that the claims match
the code and the measurements.

**Acceptance criteria:**

```gherkin
Scenario: the docs name the build the box runs
  Given docs/providers/ollama.md and DEBUGGING_OLLAMA.md
  When a reader looks up the installed version
  Then they find 0.34.4 with the 0.32.12 rollback path, not a 0.32.1 install instruction

Scenario: the batch-size claim matches the server
  Given the documented llama-server default
  When compared against an observed launch line
  Then the documented default is 1024, with the always-send-2048 policy stated separately
```
→ spec file: none (documentation). Verified by `bin/comment-census --check-tickets` staying clean and by the
integration checks below.

**Escalation triggers:**
- `docs/providers/ollama.md` records a 6.5x-vs-1.31x prefill discrepancy it calls "currently unreconciled".
  This card must not quietly pick a side — if the new measurements resolve it, say how; if not, keep the
  contradiction visible.
- Comments citing "0.32.12" for behavior re-verified on 0.34.4 should have their version updated, not their
  claims deleted — the over-window body and `truncate: false` are unchanged.

## Integration checks

1. `bundle exec rake pspec` green at 12 workers, with the example COUNT compared against the pre-chunk
   baseline — a dead worker reads as a pass (CLAUDE.md).
2. `bundle exec rubocop` clean at default metrics; `bin/comment-census --check-tickets` and
   `--check-load-order` clean; `bin/zeitwerk-census` clean (this chunk adds several new namespaces).
3. `LAIN_OLLAMA=1 bundle exec rspec --tag ollama` against a live 0.34.4 server: the two specs that fail today
   on both builds (`spec/lain/oracle/secret_read_spec.rb:240`, `spec/integration/provider/ollama_spec.rb:106`)
   must pass — T8 is the reason the first one should.
   **A THIRD live failure was found during execution and is not this chunk's**, logged here so the check is
   not read as clean: `spec/integration/provider/ollama_spec.rb:133`, "a live tool-call turn through the
   Agent", fails **3 of 3** under `LAIN_OLLAMA=1` on the final `expect(agent).to be_done`. All four content
   assertions before it pass — the model does call echo, the input decodes as a Hash, the result lands in one
   user turn, the synthetic ids match — only the terminal state is not reached. T5's panel exonerated that
   card three ways: the request's `extra` is `{"temperature" => 0, "seed" => 42}` and never touches
   `CLI::Backend`; the old two-line `extra_flag_fields` and the new `FLAG_FIELDS` table are byte-identical
   across nine inputs including `think => false`/`nil`; and it fails run alone with T5's describe and its
   hook absent. The spec's own header says not to loosen it into flakiness but to escalate with the
   transcript, so it wants an owner. **Its own card, not a fix folded into anything here.**
4. **Manual pass the human must run:** `/qa` against a real plan document with a local model, confirming the
   report lands at `.lain/qa/<plan>-<head12>.md`, that nothing in the working tree was modified, and that a
   deliberately-broken acceptance criterion is caught rather than passed. **Expect minutes, not seconds**:
   local requests serialize one at a time at the admission gate, so three samples over a dozen criteria is
   dozens of sequential asks plus one model swap per rung. Record the wall clock — if a pass cannot finish
   inside `Provider::Admission`'s 300 s per-request deadline, that is a finding about the ladder's budgets,
   not about the box.
5. **Manual pass:** one `/implement-epic` run on a local provider confirming the driver carries one issue at
   a time and no `Admission::Busy` appears in the journal.
6. Re-run the probe harness's wire checks (`planning/specs/local-models-multimodal-qa/model-probes/wire.py`)
   after T1 to confirm lain now refuses the combination the server still mishandles.
