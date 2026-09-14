# T3 — Wire the fourth arm the architecture already claims ships

Worktree: `/home/tara/dev/lain/tmp/worktrees/08-t3`. No git commands were run.

## Files changed

| file | why |
|---|---|
| `lib/lain/bench/live_arms.rb` | `.build` now answers four arms: `Arm::AdaptiveRouter` takes the roster's shared `Arm::Instrument` and a `router:` defaulting to a new `.default_router` (`Oracle::Router.heuristic`); two new constants, `ROUTE_AFTER_CHARS` and `SHORT_MODEL` |
| `ARCHITECTURE.md` | `:885`'s "Four arms ship" is now true and left alone; `:1035`'s "`lain bench sweep` walks the words mechanically" corrected — no command enumerates combinator words, and `bench sweep` is the retrieval recall@k eval |
| `spec/lain/bench/live_arms_spec.rb` | ACs 1-3 plus the four-arm doc claim, now pinned against the roster rather than against the deletability row that used to pin it |
| `spec/lain/review/deletability_spec.rb` | the `adaptive_router` row removed whole, `KEYS` dropped with it |
| `spec/lain/bench/arms_report_spec.rb` | **outside the card's Files list** — two literal `"3 arms over N tasks"` assertions, see Surprises |

Build artifacts only, both gitignored: `lib/lain/lain.so` and `target/` (`rake compile`; a fresh worktree has no extension, the suite will not load without it).

## The wiring change itself

`LiveArms.build` gains one arm and one keyword:

    def self.build(price_book: PriceBook.default, decompose: DEFAULT_DECOMPOSE, router: default_router)
      instrument = Arm::Instrument.new(price_book:)
      [Arm::SingleThread.new(name: "single-thread", instrument:),
       Arm::OrchestratorWorker.new(name: "orchestrator-worker", instrument:, decompose:),
       Arm::DualLedger.new(name: "dual-ledger", instrument:),
       Arm::AdaptiveRouter.new(name: "adaptive-router", router:, instrument:)]
    end

`default_router` is a METHOD, not a constant, for `Seams`' own reason: `lain/bench` loads before
`lain/oracle` and `lain/provider`, so naming either at this file's load time is a boot-time NameError.
It routes `SHORT_MODEL` ("claude-haiku-4") below `ROUTE_AFTER_CHARS` (160) and
`Provider::Anthropic::DEFAULT_MODEL` at or above it. 160 sits inside the committed fixture's own span —
`spec/fixtures/arms/tasks.yml` prompts run 111 to 192 characters, so the suite splits 5/3 — because a
threshold the whole suite falls one side of would print a second copy of the control, which is the exact
failure `DEFAULT_DECOMPOSE` exists to keep off the orchestrator arm.

## Red run (part of the deliverable)

`bundle exec rspec spec/lain/bench/live_arms_spec.rb --seed 1`, before touching `live_arms.rb`:

    11 examples, 4 failures

    1) the architecture document's arm count names every arm the orchestration roster builds, in roster order
       Expected ["single_thread", "orchestrator_worker", "dual_ledger", "adaptive_router"]
          to eq ["single_thread", "orchestrator_worker", "dual_ledger"]

    2) .build — the orchestration roster, the control first answers the four orchestration topologies, single-thread leading
       Expected ["single-thread", "orchestrator-worker", "dual-ledger"]
          to eq ["single-thread", "orchestrator-worker", "dual-ledger", "adaptive-router"]

    3) .build — the adaptive router decides per task records one routing answer per run, against the oracle that answered it
    4) .build — the adaptive router decides per task routes a short task and a long one to different models
       (both raised inside lib/lain/arm/dual_ledger.rb — `.build.last` was still the dual-ledger arm,
        there being no fourth arm to route)

Right reason on all four: three arms where four were asked for, and no router on the roster at all.
The two `.altitude` groups and "carries none of the altitude arms" stayed green throughout, which is the
guard that the roster change did not leak into the decomposition comparison.

## Green runs

    bundle exec rspec spec/lain/bench/live_arms_spec.rb spec/lain/arm/adaptive_router_spec.rb \
                      spec/lain/oracle/router_spec.rb
    => 28 examples, 0 failures

    bundle exec rspec spec/lain/review/deletability_spec.rb
    => 18 examples, 0 failures            # was 19: one row fewer is one boot example fewer

    bundle exec rspec spec/lain/bench spec/lain/arm spec/lain/arm_spec.rb spec/lain/oracle spec/lain/review
    => 2168 examples, 0 failures, 11 pending   # the 11 are Review::Surface::Null's pre-existing pendings

    bundle exec rspec spec/docs_naming_spec.rb spec/lain/comment_census_spec.rb spec/output_discipline_spec.rb
    => 39 examples, 0 failures

    bundle exec rubocop -a <the four files>   => 1 offense, corrected (Layout/EmptyLines in the new spec)
    bundle exec rubocop <same>                => no offenses

`rake pspec` was NOT run, per instructions: five other agents share the box.

## exe/lain wiring diff (orchestrator-owned — NOT applied here)

`exe/lain:569-570`, replace:

    desc "arms FIXTURE", "Compare the three orchestration arms live over an ArmTasks fixture " \
                         "-- spends real API money"

with:

    desc "arms FIXTURE", "Compare the four orchestration arms live over an ArmTasks fixture " \
                         "-- spends real API money"

Nothing else in `exe/lain` needs to move: the registration `desc` at `:690-692` names subcommands, not
arms, and `no_commands` is untouched. My spec does NOT assert on `exe/lain` — an assertion over a file I
cannot edit would hand you a red suite — so this one line is verified by reading, and the doc half of
AC 4 is a real example (below).

## What I did to the deletability map, and how I verified it

- **Removed the `adaptive_router` row whole** (`Capability.new` at `:278` through its closing `),` at
  `:310`), not amended. A wired arm is not a deletable capability, so the row had nothing left to claim.
- **Dropped `adaptive_router` from `KEYS`** (now `:299`) in the same edit. The pair is deliberate — DERIVED
  `TESTABLE` against NAMED `KEYS` — so removing one without the other fails `#testable` and
  "covers every row the two plans declare deletable". Both are green.
- **Verified by reading, not by trusting green**, because the row's own comment warns that
  `lib/lain/oracle/router.rb` "is held on this list by a HUMAN and by nothing else": the DEFINED-here
  example cannot see it (there is no `module Oracle::Router` line to match) and the require-site example
  iterates `own`, so a path dropped from the list is never looked at. I re-read the file after the edit:
  the only surviving mention of the router anywhere in it is the header prose at `:41`, which cites
  `Oracle::Router` / `Frontend::Neovim::Router` as the worked example of why leaf-name matching would
  report a live file as dead. That sentence is an argument about the map's derivation, not a row claim,
  and it stays true, so I left it.
- **The `ARCHITECTURE.md` marker the row pinned did NOT go silently.** The row's `edits:` pinned the
  literal `arm/{single_thread,orchestrator_worker,dual_ledger,adaptive_router}.rb` into the doc, and that
  pin went with the row. It is replaced by something stronger in
  `spec/lain/bench/live_arms_spec.rb` — an example that reads `ARCHITECTURE.md`, pulls the file list out
  of the "Four arms ship (...)" sentence and asserts it equals `LiveArms.build.map { name.tr("-","_") }`,
  in roster order. The old pin said "deleting this file falsifies a sentence"; the new one says "the
  sentence and the roster agree", which is the claim this card was actually about, and it keeps working
  when a fifth arm lands.

## Surprises and fired triggers

1. **`spec/lain/bench/arms_report_spec.rb` is a fifth file the card did not name, and the change cannot be
   green without it.** Two assertions spell the roster size as a literal: `:106`'s
   `include("3 arms over 8 tasks")` and `:399`'s `include("3 arms over 2 tasks")` (the Driver's header
   states the count). I made the minimal edit — `3 arms` to `4 arms`, `adaptive-router` added to the
   same example's `include` chain, the example renamed to "all four arms", and one stale comment
   ("the three arms of the reuse target") corrected. Nobody else's card lists this file; T1 owns
   `driver_spec.rb`, T2 owns `cli_spec.rb`/`spawn_seam_spec.rb`. Drop the edit if you would rather own it,
   but the suite is red without it. It is the same shape of trap as the deletability row.

2. **The escalation that fired hardest: `SpawnSeam` swallows the routing answer, so on `bench arms` the
   fourth arm asks the SAME model the control does.** `bench/spawn_seam.rb:118`'s
   `call(journal:, workspace:, timeline:, base_timeline:, worker_env:, **)` takes `model:`/`template:` into
   its `**` tail and builds every child off the one Context the backend resolved — and `:95-98` documents
   that swallow, naming `Arm::AdaptiveRouter` as the arm it swallows for. So today the routed decision
   reaches the experiment record (a journaled `Telemetry::OracleAnswer`) and never reaches the child.
   I wired the arm anyway — the card is explicit, the arm is real, and the record is real — and wrote the
   limitation into `default_router`'s doc comment so the roster does not read as a comparison it does not
   yet make. **Making the arm meaningful needs a per-call Context on `SpawnSeam`, which is a change to
   that seam and not to this roster.** It is the exact shape of T5's `Disclosure::Upfront` finding (an arm
   that is runnable before it is meaningful), and it wants an owner.

3. **The oracle-digest trigger: checked, and clean.** `Oracle::Router.heuristic` builds over
   `definition(tier: :heuristic)`, which is `Oracle::Router.definition`'s own default — the same value
   `Arm::AdaptiveRouter`'s `definition:` keyword defaults to. So the journaled `oracle_digest` names the
   oracle that actually answered. There is a spec for it ("records one routing answer per run, against the
   oracle that answered it"). No recorded fixture anywhere addresses a router digest: `bench arms` is the
   live path, and the replay path (`ArmSweep`) builds its own three-arm roster and never calls
   `LiveArms.build`, so nothing became unreplayable.

4. **The shared-instrument trigger: honoured, and pinned.** The fourth arm takes `instrument:` from
   `build`. `Arm::AdaptiveRouter` is the ONLY arm on this roster whose `instrument:` carries a default
   (`Instrument.new`), so it is the one that could silently answer a second clock and a second price book —
   there is now an example asserting all four arms share one instrument object.

5. **The `grading:` load-order trigger did not fire.** `Arm::AdaptiveRouter#run` takes
   `(task, spawn_seam:, grader:, isolation:)` and no `grading:` at all, so `Seams`' nil default is not
   reached and the `bench/session` merge stays out of this card.

6. **Cost: `bench arms` does NOT now cost 4/3 of what it did — it costs about 1.12x.** Measured off the
   end-to-end report in `arms_report_spec` over the committed 8-task fixture: mean total tokens per task
   were single-thread 100.0, orchestrator-worker 212.5, dual-ledger 500.0 (812.5 total), and adaptive-router
   adds 100.0 for 912.5 — +12.3%, because the control-shaped arm is one ask per task and the heuristic
   router is local and free. Same ratio in the cost column: $0.004388 to $0.004928 per task on the default
   price book. `bench/cli.rb`'s `#arms_report` doc still says "budget a live `bench arms` at roughly five
   times the control arm's cost"; with the fourth arm it is roughly six. **That file is owned by another
   agent right now, so I did not touch it — it is a one-word wiring need.** (A model-tier router instead of
   the heuristic would add a real round trip per task; the default roster does not use one.)

7. **The `bench sweep` sentence.** Corrected rather than made true, as the card requires. The passage now
   says the free monoid's words are mechanically enumerable, that **no command does that today**, and that
   `lain bench sweep` is a different experiment sharing the word — the offline recall@k retrieval eval over
   the gold corpus. `README.md:736` already said "Four arms ship" and already described adaptive-router, so
   it needed nothing. `lib/lain/bench/cli.rb:59`'s "three orchestration arms" is correct as it stands: it
   documents `arm_sweep_report`, the REPLAY sweep, which really does run three.
