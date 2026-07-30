# Chunk — a live door for the arm comparison

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Give `Bench::CLI#arm_report` a command-line door, so the arm comparison — three arms, a grader, an
isolation backend — can actually be run by a human instead of only by specs.

> **Corrected at execution time (B2 flagged it).** This line said *five* arms. That was wrong, and
> the number was borrowed from a different thing: `lain bench sweep` is the "deterministic
> five-arm **retrieval** eval (recall@k over the gold corpus)" (`bench/cli.rb:43`, `exe/lain:129`)
> — offline, no API, and unrelated to the orchestration arms. The orchestration roster is the
> three `ArmSweep` builds and documents as "three arms" (`arm_sweep.rb:7-8,130-141`):
> `Arm::SingleThread` (the CONTROL every arm is measured against), `Arm::OrchestratorWorker`, and
> `Arm::DualLedger`. B2 built those three, matching the Grounding's worked example.

**Open question for Joel — `Arm::AdaptiveRouter` is a fourth arm, and this chunk excludes it.**
There are four `Arm` subclasses in `lib/`; `ArmSweep` uses three. That exclusion is *defensible for
the replay sweep*, because `AdaptiveRouter` needs a live router answering per task
(`Oracle::Router.heuristic` or a model tier) and a recorded sweep cannot supply one. But this chunk
builds the **live** path, which is exactly where that dependency stops being an obstacle — so the
arm most excluded from the offline comparison may be the one that best justifies a live one. Its
own comment argues its cost visibility is the point ("a cheap model for an easy task, a strong one
for a hard task"), which is a claim only a live run can test. Not expanded into B2 unilaterally,
because it changes what the subcommand *is*; flagging for a decision. Closes the **bench
half** of ROADMAP Deviation 8 ("isolation reached no consumer"); the chat half was already closed
by the 2026-07-26 `--isolation` follow-up.

Split out of `chunk-vsock-exec-transport.md` during panel review: it shares no file, no dependency
edge, and no failure mode with the transport work, and unlike that chunk it **spends real API
money per run** and carries a human-gated manual check. Keeping them together would have put a
money-spending manual pass in front of a fully automatable chunk's done-gate.

**Out of scope:** `Bench::CLI#arm_sweep_report` (`lib/lain/bench/cli.rb:66`) is a *second*
doorless report — offline, deterministic, and arguably the more useful one to expose. It is
deliberately left alone here so this chunk stays one seam, and it means **no card in this chunk
"closes" Deviation 8 outright** — say "the live arm path" and not "the deviation."

## Grounding

Verified against the working tree on **2026-07-28**, including a correction the panel forced.

**The plan's first draft claimed "nothing in `lib/` constructs a spawn_seam."** That is **false**,
and it was used to size this work. `lib/lain/bench/arm_sweep/recordings.rb:80-93` constructs one,
in `lib/`, for the bench, with the widened `**` tail and the fresh-Agent-per-call rule:

```ruby
# ONE spawn seam driving all three arms: a fresh Agent per call (the mock
# is stateful) over a {Replay} provider and an empty toolset, mapping the
# widened spawn tail every arm speaks -- `timeline:`/`base_timeline:` to
# the Agent's root, `worker_env:` to its Session.
def seam
```

B1 is the **live sibling** of that method — replay provider swapped for a `Backend`-resolved one.
That is a much better starting point than a blank file, and it is the reuse target.

**All three of `arm_report`'s other collaborators also have `lib/` homes**, contrary to the panel's
reading that only spec-local constructions exist:

- `arms` — `lib/lain/bench/arm_sweep.rb:130-141` constructs `Arm::SingleThread`,
  `Arm::OrchestratorWorker`, and `Arm::DualLedger` with a `ZERO_CLOCK` and a `PriceBook`.
- `tasks` **and** `grader` — `lib/lain/bench/arm_tasks.rb` is `Enumerable` over tasks built from a
  fixture (`ArmTasks.new(fixture_path:)`, `#each`, `#procedural`, `#parallel`), and
  `#build_grader(id, gold_files)` (`arm_tasks.rb:170`) produces a `Grader::Fixture` per task —
  "no model in the loop", graded against gold files.

So B2 assembles from existing lib objects rather than inventing them. What genuinely does not
exist is an *entry point that assembles them* — hence B2 owning `lib/lain/bench/cli.rb`.

**The signature.** `arm_report(arms, tasks:, spawn_seam:, grader:, isolation: nil,
**backend_options)` (`lib/lain/bench/cli.rb:123`) already accepts `isolation:` and already
distinguishes an **unset** flag (no keyword passed at all, so `Arm::Driver` applies its own
default) from an explicit `"none"`. `#arm_isolation` (`bench/cli.rb:180`) documents that at
length, and `spec/lain/bench/cli_spec.rb:223-228` pins it.

**The trap that follows from it.** `Lain::CLI::IsolationBackend::DEFAULT == "none"`
(`isolation_backend.rb:77`), and `chat` wires it as a Thor `default:` (`exe/lain:257-261`). A Thor
`default:` makes `options[:isolation]` **never nil** — which would collapse exactly the
unset-vs-`"none"` distinction above. **This chunk's flag must carry no Thor default**, only
`BACKENDS` in its help text. Copying `chat`'s flag declaration verbatim is the wrong move here,
and it is the single easiest way to silently break a pinned behaviour.

**`exe/lain`'s boundary rule.** `exe/lain:80-85` states it: `Bench::CLI` assembles everything and
returns Strings; the Thor class parses flags and `say`s what comes back. `record`'s declarative
`RECORD_FLAGS` flag→keyword map (`exe/lain:112-114`) is the shape to match. Assembling arms,
tasks, and a grader inside `exe/lain` would violate this — hence the split between B2 and B3.

**A guard that does not cover this.** `spec/lain/cli/chat_flags_spec.rb` carries a mechanical check
that every `options[:...]` read is declared by some command — but it globs
`lib/lain/cli/**/*.rb` only (`chat_flags_spec.rb:38`), and this chunk's flag reads live in
`exe/lain`, which that spec merely `load`s. **The guard cannot fire for this work.** That matters
because the historical failure it was written for is exactly this shape: its own comment records
"four flags shipped unreachable... the `method_option` lines were orchestrator-owned and never
landed." B3 must carry its own reachability assertion rather than assume the guard has it.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (no change expected —
  `lain/bench` is already required at line 60), `lain.gemspec`, `.rubocop.yml`,
  `spec/spec_helper.rb`, `Rakefile`.
- `lib/lain/bench.rb` (unit index) is owned by B1. `lib/lain/bench/cli.rb` is owned by B2.
  `exe/lain` is owned by B3. One card each; no wave has two cards touching one file.
- Deviation from the default process: none.

## Open decisions

None.

## Progress

| Card | Implemented | Panel verdict | On `main` |
|---|---|---|---|
| B1 | ✅ | APPROVE-WITH-FIXES → applied | ✅ `ea9b0eb` |
| B2 | ✅ | REQUEST-CHANGES → fixed → **APPROVE** | ✅ `30ff8de` |
| B3 | ✅ | APPROVE-WITH-FIXES → applied (+1 orchestrator ruling) | ✅ `16fc6be` |

**All three cards landed.** Integration checks 1–5 pass (see below); check 6 is the manual paid
run owed to Joel, and check 7 (ROADMAP) is the remaining orchestrator task.

Run alongside `chunk-vsock-exec-transport.md`; the two chunks share no file and interleave freely.

## Waves

```
Wave 1: B1
Wave 2: B2 (←B1)
Wave 3: B3 (←B2)
```

Critical path: **B1 → B2 → B3** — the whole chunk is the critical path. It is three sequential
cards by nature (a collaborator, an assembler, a door) and does not parallelize; run it alongside
another chunk rather than trying to widen it.

## Tasks

### B1 — Build the live spawn seam [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/bench/spawn_seam.rb`, `spec/lain/bench/spawn_seam_spec.rb`;
modify `lib/lain/bench.rb`
**Reuse:** **`lib/lain/bench/arm_sweep/recordings.rb:80-93` (`#seam`) is the replay sibling of this
object** — the widened `**` tail, the `timeline:`/`base_timeline:` mapping to the Agent's root, the
`worker_env:` → `Session` mapping, and the fresh-Agent-per-call rule are all already worked out
there. Copy its shape; swap `Replay` for a provider resolved through `Lain::CLI::Backend` the way
`Bench::CLI#record` does (`bench/cli.rb:157-160`). `Arm#run`'s documented duck
(`lib/lain/arm.rb:100-120`) defines the required shape. Consider whether the two can share a
builder rather than diverge.
**Shared-file wiring:** none (`lib/lain/bench.rb` is card-owned; add
`require_relative "bench/spawn_seam"` **before** the existing `bench/cli` line, so B2's consumer
cannot hit a load-time `NameError`)

Produces the `call(journal:, **spawn_opts) -> Agent` callable every `Arm` needs, built from the
same backend flags `record` already understands.

**Acceptance criteria:**

```gherkin
Scenario: each call yields a fresh agent
  Given a spawn seam over a stubbed provider
  When it is called twice
  Then the two agents are distinct
  And neither shares the other's timeline

Scenario: the journal reaches the agent
  Given a spawn seam and a channel
  When an agent is spawned with that channel as its journal
  Then telemetry the agent emits arrives on that channel

Scenario: the widened spawn tail is honoured
  Given a spawn seam called with a base timeline and a worker env
  When the agent is built
  Then it is rooted at that timeline
  And its session carries that worker env

Scenario: an unknown provider name is refused by the existing authority
  Given a spawn seam configured with a provider name outside the advertised set
  When it is built
  Then it raises the same named error the CLI backend raises
```
→ spec file: `spec/lain/bench/spawn_seam_spec.rb`

**Escalation triggers:**
- Specs must not hit the network or spend money — drive `Provider::Mock`
  (`lib/lain/provider/mock.rb`). If a scenario appears to need a live provider, stop.
- If building the seam requires reaching into `Lain::CLI::Wiring` (`wiring.rb:170`
  `role_spawn_seam` is a third spawn-seam construction, for the *chat* path), stop — that couples
  the bench to the chat wiring and is a seam error, not a missing argument. It is named here only
  so it is not rediscovered and mistaken for the right reuse target.
- `Bench::Session` shadows `Lain::Session` inside this namespace — `recordings.rb:86-87` documents
  the trap and resolves it explicitly. If a `NoMethodError` on a Session appears, check this
  before anything else.

---

### B2 — Add an assembling entry point for the live arm comparison [wave 2] [risk: medium]

**Depends on:** B1
**Files:** modify `lib/lain/bench/cli.rb`; create `spec/lain/bench/arms_report_spec.rb`
**Reuse:** `Bench::CLI#arm_report` (`bench/cli.rb:123`) already exists, is spec-tested
(`spec/lain/bench/cli_spec.rb:177-271`), and already accepts `isolation:` — this card feeds it, and
must not reimplement it. `lib/lain/bench/arm_tasks.rb` supplies tasks **and** their per-task
`Grader::Fixture` (`#build_grader`, :170). `lib/lain/bench/arm_sweep.rb:130-141` is the worked
example of constructing the three arms. `#arm_isolation` (`bench/cli.rb:180`) already owns the
unset-vs-`"none"` distinction — pass through it, do not re-derive it.
**Shared-file wiring:** none

A `Bench::CLI` method that takes plain values (a fixture path, backend options, an optional
isolation name) and assembles arms, tasks, grader, and spawn seam into an `#arm_report` call,
returning the report String. This exists so `exe/lain` stays a flag parser, per the boundary rule
at `exe/lain:80-85`.

**Acceptance criteria:**

```gherkin
Scenario: the report is returned, never printed
  Given a fixture path and a stubbed provider
  When the arms report is requested
  Then a String is returned
  And nothing was written to stdout or stderr

Scenario: an unset isolation name passes no keyword at all
  Given the report is requested with no isolation name
  When the driver is built
  Then it received no isolation keyword
  And its own default applies

Scenario: an explicit "none" is passed through as a resolved backend
  Given the report is requested with the isolation name "none"
  When the driver is built
  Then it received a resolved backend, distinct from the unset case

Scenario: an unknown isolation name is refused before any arm runs
  Given the report is requested with a misspelled isolation name
  When it is invoked
  Then it raises naming the advertised set
  And no arm was executed
```
→ spec file: `spec/lain/bench/arms_report_spec.rb`

**Escalation triggers:**
- The unset-vs-`"none"` distinction is pinned by `spec/lain/bench/cli_spec.rb:223-228` and
  documented at `bench/cli.rb:93-99`. If honouring it here appears to require changing
  `#arm_isolation` or `#arm_report`, **stop** — this card feeds them, it does not reshape them.
- Specs must not spend money or hit the network. If the assembly cannot be driven with
  `Provider::Mock`, stop rather than adding a live-provider spec.
- If `ArmTasks`' fixture format cannot express the tasks the arms need, stop and confirm before
  inventing a second task source — a second authority on "what a bench task is" is a seam error.

---

### B3 — Wire the `bench arms` subcommand [wave 3] [risk: medium]

**Depends on:** B2
**Files:** modify `exe/lain`; create `spec/lain/bench/arms_command_spec.rb`
**Reuse:** the `Bench < Thor` block (`exe/lain:86-131`), its `include Boundary` / `render {}`
idiom, and `record`'s declarative `RECORD_FLAGS` flag→keyword map (`exe/lain:112-114`).
`Lain::CLI::IsolationBackend::BACKENDS` supplies the help text's advertised set.
**Shared-file wiring:** none

Adds `bench arms` carrying `--isolation` and a fixture path. **This subcommand spends real API
money per run** — its description must say so, matching how `record` announces the same
("spends real API money", `exe/lain:96`).

**`--isolation` must be declared with NO Thor `default:`** — see Grounding. `chat`'s declaration
(`exe/lain:257-261`) sets `default: IsolationBackend::DEFAULT` and copying it here would make
`options[:isolation]` never nil, collapsing the unset-vs-`"none"` distinction B2 preserves.

**Acceptance criteria:**

```gherkin
Scenario: the subcommand is discoverable and declares its cost
  Given the bench help is requested
  When the output is read
  Then an arms subcommand is listed
  And its description says it spends real API money
  And its isolation flag's help names the advertised backends

Scenario: every flag the command reads is a flag it declares
  Given the arms subcommand's source
  When each option it reads is compared against its declared options
  Then every read option is declared

Scenario: an unset isolation flag reaches the entry point as nil
  Given the arms subcommand is invoked with no isolation flag
  When the entry point is called
  Then it receives no isolation name

Scenario: an unknown isolation name fails without running an arm
  Given the arms subcommand is invoked with a misspelled backend name
  When it is run
  Then it fails naming the advertised set
  And no arm was executed
```
→ spec file: `spec/lain/bench/arms_command_spec.rb`

**Escalation triggers:**
- The second scenario exists because `spec/lain/cli/chat_flags_spec.rb`'s mechanical
  declared-vs-read guard globs `lib/lain/cli/**/*.rb` only and **cannot cover `exe/lain`**. Do not
  delete it as redundant with that guard; it is not. If it seems impossible to assert without
  loading `exe/lain`, look at how `chat_flags_spec.rb` already loads it before giving up.
- Specs must not spend money: assert on wiring with a stubbed `Bench::CLI`, never by running a
  live arm.
- If a Thor `default:` on `--isolation` seems necessary to make the flag work, **stop** — that is
  the exact trap this card is written to avoid.

## Follow-ups raised in review (not this chunk's work)

- **`Arm::Driver`'s task seam discards task identity.** It takes `tasks: Array<String>`, so
  `Bench::CLI::SuiteGrader` reconstructs which task a run belongs to by **matching the run's
  user-turn prompt** — string archaeology standing in for an identifier. B2's panel measured the
  consequence: two tasks sharing a prompt both graded against the first one's gold and scored a
  false **1.000** on gold that was unsatisfiable. B2 now refuses duplicate prompts loudly, which
  closes the hole without fixing the seam. Giving the Driver a per-task identifier is the real fix
  and a card of its own. `SuiteGrader#grade` being byte-identical to `ArmSweep::GraderAdapter#grade`
  is the second signal that this dispatch wants one home.
- **`Bench::CLI` is at exactly 110/110 on `Metrics/ClassLength`.** Zero headroom: the next card that
  adds a line trips the cop. B3 clears it (it touches `exe/lain`, not `bench/cli.rb`), so this was
  deliberately not scheduled before B3. `SuiteGrader` — 19 lines, a genuine object with a
  documented responsibility — is the ready-made extraction to `lib/lain/bench/suite_grader.rb`.
- **The report header cannot be attributed to its configuration.** It reads `Arm driver — 3 arms
  over 8 tasks`: no fixture path, no provider, no model, no isolation name. `Arm::Driver` owns that
  header, so B2 could not reshape it — but the manual pass produces the first artifact anyone will
  want to file, and an unattributable bench report is a weak experiment record.
- **`DEFAULT_DECOMPOSE`'s file-path heuristic matches method calls on user fixtures.** Clean on the
  committed fixture, but `"Handle the response.body and the request.path uniformly"` fans out two
  ways with briefs naming non-files, as does `Node.js`. `decompose:` is injectable, so there is an
  escape hatch; the limit deserves a sentence in the comment.
- **Dropping `.uniq` from `DEFAULT_DECOMPOSE` survives mutation.** A prompt naming the same file
  twice would spawn duplicate workers. No committed task repeats a path, so no spec can see it.

## Integration checks

After the last wave, before the chunk is called done:

1. `bundle exec rspec` — green.
2. `bundle exec rubocop`.
3. `pre-commit run --all-files`.
4. `exe/lain bench help` lists `arms` and its description says it spends real API money.
5. `exe/lain bench arms --isolation nope --journal <path> <fixture>` fails naming the advertised
   set, having run no arm and spent nothing. **`--journal <path>` is required in this command**
   (added at execution time): `--isolation` leases workers and B2 refuses to lease with nowhere to
   record it, so without `--journal` the run stops at *that* refusal instead of the backend-name
   one this check is about. **Second caveat (B3 found it):** the backend-name refusal holds only
   when the provider resolves. Run keyless on the default provider, `SpawnSeam`'s API-key gate
   fires *before* the isolation resolver — argument-evaluation order in `bench/cli.rb:164-166` —
   so the message is about the missing key, not the backend set. Either export a placeholder key
   or pass `--provider ollama`, and then it prints
   `unknown isolation backend "nope", expected one of ["none", "worktree"]`, exit 1, no arm run.
   Both refusals are correct and both precede spend; only the *order* is surprising, and it is the
   same ordering family already ruled defensible for the journal-vs-name refusal.
6. **Manual pass owed to Joel** (nothing automated covers it, by design — the specs are forbidden
   from spending money): run `bench arms` once for real against a live provider with
   `--isolation worktree --journal <path>`, and confirm the report renders on **stdout**, the
   lease telemetry lands as parseable NDJSON in the file `--journal` names, and the spend is what
   was expected.

   **Read this before running it — the shape of this check changed during execution.** B3 first
   wrote the journal to **stderr**, which violates `lib/lain/journal.rb:23` ("the fd is the
   Journal's own … and **NEVER stderr**") and `ARCHITECTURE.md:603`. The panel drove a real run and
   showed why the invariant exists: Thor's error output shares that fd by construction, so
   `2> leases.ndjson` interleaved a gem warning and a `Lain::Error` message into the stream and
   `JSON.parse` failed on both lines — the repo's own stated wound. Worse for this check
   specifically, a **failing** paid run writes 0 bytes to stdout, so an operator who redirected
   stderr to capture the telemetry would get an empty terminal and a silent failure *after*
   spending. Hence the explicit `--journal PATH` through `Journal.open`: stdout carries the report,
   stderr carries errors, and the NDJSON gets its own fd.

   Two things worth eyeballing while you are in there, since only a live run shows them: whether
   the three arms' costs are separable enough to be worth the spend, and whether the
   orchestrator-worker arm's fan-out (one worker per file path the task names) looks sane against
   the real tasks rather than the fixture.
7. Update the ROADMAP: record that the **live arm path** now has a CLI door, and that
   `Bench::CLI#arm_sweep_report` remains doorless — Deviation 8 is narrowed, not closed.
