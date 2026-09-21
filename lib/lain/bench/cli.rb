# frozen_string_literal: true

module Lain
  module Bench
    # All of `exe/lain bench`'s assembly, behind returned values: the exe parses
    # flags, calls these methods, and `say`s the Strings -- nothing here prints.
    # Every refused input is a {Lain::Error} -- {Refusal} with the path context
    # only this layer still holds, {Session::Corrupt} on a bad file,
    # {MissingAPIKey} from the key gate -- so the exe rescues Lain::Error ALONE
    # and a programmer bug's ArgumentError stays a loud crash.
    class CLI
      # The user's own input turned away: a missing file, a directory with no
      # sessions, a zero or fractional run count, an occupied output path, a
      # set of recordings {Variance} cannot compare.
      class Refusal < Error; end

      # `bench record` spends real money by construction; refusing keyless up
      # front beats a transport error n prompts in.
      class MissingAPIKey < Error; end

      # One source for the record defaults, so the flag help and the library
      # behavior cannot drift. `max_tokens` is the FLAG's declared default --
      # the ceiling arrives already resolved inside the {Lain::CLI::Backend},
      # so this is what the command declares rather than a second default
      # {#record} re-applies.
      #
      # No `model` here on purpose: `--model` is declared with no default so
      # that {Lain::CLI::Backend} resolves the SELECTED provider's own, and a
      # copy of anthropic's answer sitting in this hash was read by nothing.
      RECORD_DEFAULTS = { runs: 2, max_tokens: 1024 }.freeze

      # The isolation backends that actually CONTAIN a write -- the ones that
      # cut a checkout of their own, so a `write_file` inside a lease lands
      # there and not in the tree the command was started from.
      #
      # ENUMERATED, not `IsolationBackend::BACKENDS - [DEFAULT]`. Subtraction is
      # derived fail-OPEN: a backend added upstream would be classified as
      # containing by nobody's decision, on the one axis where being wrong ships
      # a flag that looks like isolation and is not. So an unadvertised name
      # defaults to UNCONTAINED, and a spec reddens when the advertised set
      # grows past this list -- the shape {Harness::WRITERS} already uses.
      #
      # `none` is absent on purpose: it leases over the SHARED process
      # environment and cuts nothing.
      CONTAINING_BACKENDS = %w[worktree].freeze

      # What `--memory` may name. `empty` is the default and the comparable
      # one: a run that started from whatever the operator's project happened
      # to remember is not comparable with the same run a week later, so a
      # sweep starts from the empty version unless it is told otherwise.
      # `project` measures recall against the real store instead.
      MEMORIES = %w[empty project].freeze

      # The three-section {Variance} report over recorded session files.
      #
      # A run that measured nothing is named rather than averaged in: a
      # recording set aside as failed, or one a killed process left with no
      # header, has nothing to load, and a turn whose stream was cut short
      # answers with no usage at all, which a mean would read as a free run.
      #
      # @param sources [Array<String>] paths; a directory means every
      #   `*.ndjson` under it, in sorted filename order
      # @param price_book [Lain::PriceBook]
      # @return [String] never printed here
      # @raise [Refusal] on a missing or empty source, a recording that cannot
      #   replay, or fewer than two recordings
      def variance_report(sources, price_book: PriceBook.default)
        read = session_paths(sources).map { |path| [path, Journal.records(File.foreach(path)).to_a] }
        aside, measured = read.partition { |path, records| set_aside_reason(path, records) }
        set_aside = aside.map { |path, records| "#{path}: #{set_aside_reason(path, records)}" }
        recordings = measured.map { |path, records| load_session(path, records) }
        build_variance(recordings, measured.map(&:first), price_book, set_aside).report
      end

      # The five-arm retrieval sweep: a deterministic, offline recall@k eval
      # over the committed gold corpus, ranked with a tokens-on-recall column.
      # No provider, no money, no network -- the vector arm reads committed
      # fixture embeddings -- so unlike {#record} this needs neither a
      # {Lain::CLI::Backend} nor the key gate.
      #
      # @param k [Integer] retrieval depth (recall@k)
      # @return [String] the Compare-style report; never printed here
      # @raise [Refusal] on a k that is not a positive whole number
      # rubocop:disable Naming/MethodParameterName -- `k` is the pinned recall@k name.
      def sweep_report(k: Sweep::DEFAULT_K) = Sweep.new(k: check_k(k)).report
      # rubocop:enable Naming/MethodParameterName

      # The three orchestration arms (single-thread control, orchestrator-worker,
      # dual-ledger) over the ArmTasks suite, replayed offline through committed
      # recordings -- no provider, no money, no network, byte-identical across
      # runs. The paths are explicit rather than a lib-to-spec fixture coupling.
      #
      # @return [String] the Compare-style report; never printed here
      def arm_sweep_report(tasks_path:, recordings_path:)
        ArmSweep.new(tasks_path:, recordings_path:).report
      end

      # The shape x density plan sweep: six arms (linear/fork x
      # every/thinned/none) over one fixed plan and its scripted runs, replayed
      # offline like {#arm_sweep_report}.
      #
      # @return [String] the Compare-style report; never printed here
      def plan_sweep_report(plan_path:, runs_path:)
        PlanSweep.new(plan_path:, runs_path:).report
      end

      # The live arm comparison ({Arm::Driver}): every arm runs the same task
      # suite, and each arm leases its workers from the backend `isolation`
      # names -- so the arms are compared under ONE confinement rather than
      # whichever each happened to construct.
      #
      # `isolation` is the `--isolation` FLAG, not a backend object. It resolves
      # through the ONE {Lain::CLI::IsolationBackend} chat resolves through, so
      # a name means the same thing from either command.
      #
      # AN UNSET FLAG IS NOT `--isolation none`. Unset leaves {Arm::Driver}'s
      # own default, {Arm::NoIsolation}, whose lease carries no {WorkerEnv} at
      # all; `none` resolves an {Isolation::Null}, a real backend leasing the
      # shared process environment. That distinction is what tells a report's
      # reader whether a run was isolated by a backend or never leased anything.
      #
      # PASS A REAL `journal:` WITH ANY NAME BUT nil. The resolver decorates by
      # NEED, so a resolve with no journal (or a {Channel::Null}) hands back a
      # BARE backend emitting no {Telemetry::IsolationLease} record at all -- an
      # isolated run nothing can observe. For chat that is merely quiet; on the
      # bench, where the record IS the deliverable, it is not a run worth
      # reporting.
      #
      # @param arms [Array<Arm>] the topologies under comparison
      # @param tasks [Array<String>] the suite each arm runs
      # @param spawn_seam [#call] the agent/child factory threaded into every arm
      # @param grader [#grade] scores each run's Timeline
      # @param isolation [String, nil] the `--isolation` name; nil keeps the
      #   Driver's own default. Reaches the Driver TWICE and for two different
      #   jobs: resolved into the backend every arm leases from, and verbatim as
      #   the header's label
      # @param fixture [String, nil] the suite's own path, for the report header;
      #   the Driver is handed PROMPTS, so this is the only way it can name where
      #   they came from
      # @param model [String, nil] what the arms were configured to ask, for the
      #   same header; {SpawnSeam#model} answers it on the assembled path
      # @param backend_options [Hash] forwarded verbatim to
      #   {Lain::CLI::IsolationBackend.resolve}; ITS signature owns those
      #   defaults, so restating them here would be a second authority
      # @param journal [#<<, nil] READ TWICE, by two different consumers of one
      #   record: the resolver decorates the backend with it so lease telemetry
      #   lands, and {Arm::Driver} journals every arm's grade into it. Named
      #   rather than left riding `backend_options`, because a keyword the
      #   resolver merely forwards could never also reach the Driver
      # @return [String] never printed here
      # @raise [Lain::CLI::IsolationBackend::Unknown] on a name outside the
      #   resolver's advertised set
      # @raise [ArgumentError] on backend options with no name to resolve
      def arm_report(arms, tasks:, spawn_seam:, grader:, isolation: nil, journal: nil, fixture: nil, model: nil,
                     **backend_options)
        # Absent, NO keyword at all on either side, so each one's own default
        # stands -- {Arm::Driver}'s Null channel here, and {#arm_isolation}'s
        # deliberate refusal of options given with no name to resolve them for.
        journaling = { journal: }.compact
        # `isolation_name:` is the operator's own word, and the only thing that
        # can NAME the backend: every name resolves to the same
        # {Isolation::Journal} decorator once `--isolation` requires a journal,
        # so a class name renders `none` and `worktree` identically.
        Arm::Driver.new(arms, tasks:, spawn_seam:, grader:, fixture:, model:, isolation_name: isolation,
                              **journaling,
                              **arm_isolation(isolation, **backend_options, **journaling)).report
      end

      # The live arm comparison, ASSEMBLED: the entry point `bench arms` sits
      # on. Everything {#arm_report} needs is built here from plain values, so
      # `exe/lain` stays a flag parser and never names an Arm, a Grader, or a
      # Provider itself.
      #
      # THIS SPENDS REAL API MONEY per run: every arm asks a real provider once
      # per task, and the dual-ledger arm asks about
      # {Arm::DualLedger::DEFAULT_MAX_STEPS} times on essentially every task --
      # its ceiling is the typical case, not the worst one, so budget a live
      # `bench arms` at roughly NINE times the control arm's cost rather than at
      # one ask per task. Measured over the committed suite: single-thread 8,
      # orchestrator-worker 17, dual-ledger 40, adaptive-router 8 -- 73 calls
      # against the control's 8. The routing arm adds about an eighth of the
      # total and less in dollars, since the tasks it routes cheaply are the
      # ones a small model is priced for.
      #
      # `isolation` is the `--isolation` NAME, and nil means UNSET, not "none";
      # a SET name REQUIRES `journal:`, and {#lease_options} says why.
      #
      # @param fixture_path [String] the committed {ArmTasks} suite the arms run
      # @param backend [Lain::CLI::Backend] the resolved provider-and-Context
      #   seam the flags built, forwarded whole to {SpawnSeam}
      # @param isolation [String, nil] the `--isolation` name; nil keeps
      #   {Arm::Driver}'s own default
      # @param journal [#<<, nil] where the resolved backend's
      #   {Telemetry::IsolationLease} records land; REQUIRED with an `isolation`
      # @param decompose [#call] how the orchestrator arm splits a task up; see
      #   {LiveArms::DEFAULT_DECOMPOSE} for why the arm's own default is wrong here
      # @param router [#ask, #definition, nil] the tier the adaptive-router arm
      #   asks which model each child runs under; nil builds the default from
      #   the model `backend` resolved, which is what keeps that arm on the
      #   operator's `--model`. A caller on a backend the default cannot route
      #   ({LiveArms::UnroutableBackend}) passes its own here.
      # @param cheap_model [String, nil] `--cheap-model`, read literally and
      #   forwarded to {LiveArms.build} when `router` is absent; the model id
      #   the routing arm sends single-file tasks to. Ignored when `router` is
      #   given.
      # @param price_book [Lain::PriceBook] prices every arm's journal
      # @param spawn_options [Hash] forwarded verbatim to {SpawnSeam}; ITS
      #   signature owns those defaults, including the unset `system:` that
      #   teaches the arms the FILE/END trajectory format the gold graders
      #   parse -- untaught, every arm scores near zero, floored only by one
      #   task's vacuously-passing `excludes:`
      # @return [String] the Driver's report; never printed here. INTERRUPTED
      #   (Ctrl-C), it is instead the PARTIAL report over whatever runs graded
      #   before the interrupt arrived -- see {#partial_arms_report}
      # @raise [Refusal] on an `isolation` with no journal, or a suite whose
      #   tasks share a prompt
      # @raise [LiveArms::UnroutableBackend] when the resolved model has no
      #   cheaper sibling named, or the server says it has not got the one
      #   named, and no `router` was given
      # @param memory [String, nil] `--memory`: what each arm's view starts from
      # @raise [ArmTasks::MissingFixture] when the suite path is not there
      # @raise [Lain::CLI::UnknownProvider] on a provider name outside the set
      # @raise [Lain::CLI::IsolationBackend::Unknown] on an isolation name outside it
      def arms_report(fixture_path:, backend:, isolation: nil, journal: nil,
                      decompose: LiveArms::DEFAULT_DECOMPOSE, router: nil, cheap_model: nil,
                      price_book: PriceBook.default, memory: nil, **spawn_options)
        # Declared before anything that could be interrupted, so the rescue
        # below always has an Array to report on rather than the bare local a
        # Ctrl-C before the first grade would otherwise leave nil.
        graded = []
        refuse_unisolated_writes!(spawn_options.fetch(:tools, Harness::TOOLS), isolation:, flag: isolating_flag)
        suite = ArmTasks.new(fixture_path:)
        # Named rather than inlined, because the header's `model:` has to be THE
        # seam's own answer -- a second resolution off `backend` could disagree
        # with what actually ran. The ROSTER reads the same answer: the routing
        # arm's capable branch is that model, so all four arms run what the
        # operator asked for and only the cheap branch departs from it.
        spawn_options = journaled_provider(backend, journal, spawn_options)
        LiveArms.refuse_unservable!(spawn_options.fetch(:provider), cheap_model) if router.nil?
        spawn_seam = SpawnSeam.new(backend:, memory: memory_store(memory), **spawn_options)
        # {Grader::Journaling} REUSED rather than a bespoke observer: it already
        # does exactly what an interrupt handler needs -- pass the {Grade}
        # through unchanged and journal a {Telemetry::GradeRecord} beside it --
        # so wrapping {SuiteGrader} in one, with `graded` standing in for a
        # journal, is what lets `graded` grow one entry per run AS THE DRIVER
        # completes it. {Arm::Driver} wraps whatever `grader:` it is handed in
        # a SECOND {Grader::Journaling} of its own, over the real `journal:`
        # from {#lease_options} -- so this changes nothing about what that
        # journal records.
        grader = Grader::Journaling.new(inner: SuiteGrader.new(suite), journal: graded,
                                        subject_digest: :head_digest.to_proc)
        arm_report(LiveArms.build(price_book:, decompose:, model: spawn_seam.model, router:, cheap_model:),
                   tasks: suite.map(&:prompt), spawn_seam:, fixture: fixture_path, model: spawn_seam.model,
                   grader:, **lease_options(isolation:, journal:))
      rescue Interrupt
        partial_arms_report(graded)
      end

      # The four-arm DECOMPOSITION comparison ({Altitude}): the same work entered
      # at four heights on {Arm::Ladder}, over a suite whose tasks sit on a size
      # axis, reported per size.
      #
      # THIS SPENDS MORE THAN `bench arms` DOES, and by a wide margin: the two
      # epic arms drive a whole epic per task -- planning, gating and landing
      # every issue -- so budget it against the epic's issue count rather than
      # against one ask per task. {Altitude} says so through `sink` before the
      # first arm runs, which is why that warning is not part of the returned
      # report: a report is pasted into an issue, where a spend warning would
      # read as a property of the experiment rather than of the command.
      #
      # `seams` ARRIVES BUILT, and that is a real boundary rather than a
      # convenience. The two epic arms are driven by {CLI::EpicDriver::Factory},
      # which needs a chat's own wiring -- a mount, a chronicle, a skill library
      # and a toolset build -- and none of those exist inside `bench`. So the
      # caller that HAS them assembles the seams and hands them over; see
      # {LiveArms::Seams}.
      #
      # `isolation` is the `--isolation` NAME, and nil means UNSET, not "none",
      # exactly as it does for {#arms_report}; a SET name still REQUIRES a
      # `journal:`, and {#lease_options} says why.
      #
      # @param fixture_path [String] the committed {Altitude} suite the arms run
      # @param backend [Lain::CLI::Backend] the resolved provider-and-Context seam
      # @param seams [LiveArms::Seams] what the planned and gated arms are driven by
      # @param grader [#grade] the fallback grader for an arm that builds none of
      #   its own; the one-shot arm binds a {Grader::LeaseHarness} to its own
      #   lease through `seams.grading` instead
      # @param sink [#puts] where the cost warning is said, BEFORE the first arm
      # @param isolation [String, nil] the `--isolation` name; nil leases nothing
      # @param journal [#<<, nil] where lease telemetry lands; REQUIRED with an `isolation`
      # @param price_book [Lain::PriceBook] prices every arm's journal
      # @param spawn_options [Hash] forwarded verbatim to {SpawnSeam}
      # @return [String] the report; never printed here
      # @raise [Refusal] on an `isolation` with no journal
      # @raise [Altitude::MissingFixture] when the suite path is not there
      # @raise [Altitude::MalformedTask, Error] on a suite it cannot fold
      def altitude_report(fixture_path:, backend:, seams:, grader:, sink: Sink::Null.new,
                          isolation: nil, journal: nil, price_book: PriceBook.default, **spawn_options)
        refuse_unisolated_writes!(spawn_options.fetch(:tools, Harness::TOOLS), isolation:, flag: isolating_flag)
        Altitude.new(fixture_path:, spawn_seam: SpawnSeam.new(backend:, **spawn_options), grader:, sink:,
                     arms: LiveArms.altitude(seams:, price_book:),
                     **altitude_isolation(isolation, journal)).report
      end

      # Record `runs` fresh live sessions of one task file (user prompts, one
      # per line, blank lines skipped) into `out/<i>.ndjson`, each a full
      # Session a later {#variance_report} can load.
      #
      # THE TOOLLESS HARNESS IS THIS COMMAND'S DEFAULT, and that is a ruling
      # rather than the accident it used to be. `bench record` leases nothing --
      # it has no `--isolation`, no worker env and no checkout of its own -- so
      # a toolset that can write would act in the operator's own tree, and
      # {#refuse_unisolated_writes!} refuses that pair wherever it is
      # representable. {RunRecorder} itself defaults to the real floor, because
      # a caller holding an isolated environment should get the harness; the
      # COMMAND is what declines to be the thing that runs it unisolated.
      #
      # Provider and Context come from the SAME {Lain::CLI::Backend} the chat
      # path is handed, so `--provider`/`--temperature`/`--seed` mean one thing
      # across commands. The sampler flags ride the Context into Request#extra,
      # and the recorded HEADER carries them. ONE OBJECT, NOT SIX FLAGS: a sweep
      # assembled from loose flags is a sweep where two runs can differ by one
      # nobody threaded, and on a bench the record IS the deliverable.
      #
      # TWO SEAMS, ONE WORD, ONE NESTING LEVEL APART, so it is written down
      # rather than left to be re-derived: `provider:` HERE is the injected
      # Provider OBJECT (nil asks the backend for the real, money-gated one),
      # while the backend's own `:provider` OPTION is the `--provider` NAME to
      # resolve. A spec reads
      # `record(backend: Backend.new({provider: "gemini"}), provider:)` on one
      # line, and both are correct.
      #
      # @param taskfile [String] path to the task file: prompts one per line,
      #   blank lines skipped
      # @param out [String] directory the recorded sessions are written into, as
      #   `out/<i>.ndjson`
      # @param backend [Lain::CLI::Backend] the resolved provider-and-Context seam
      # @param runs [Integer] how many fresh sessions to record; refused (not
      #   truncated) if fractional or below one, since this command spends
      #   money per run and a sweep of zero must not read as instant success
      # @param system [String, nil] `--system`, rendered INSTEAD of the project's
      #   prompt slots and attributed as such
      # @param provider [Lain::Provider, nil] injected in specs; nil asks the
      #   backend for the real recording client, behind the money gate below
      # @param tools [#call] what each recorded run may DO; the toolless harness
      #   by default, for the reason above
      # @param instrumentation [#call] what each recorded run REPORTS through,
      #   the per-turn Context source included
      # @param memory [String, nil] `--memory`: what each run's view starts from
      # @return [Array<String>] one line per run, in run order: the written
      #   session path, or for a run whose round trip failed, the path it was
      #   set aside under and why
      # @raise [Refusal] when no run recorded at all, naming each set aside
      def record(taskfile:, out:, backend:, runs: RECORD_DEFAULTS.fetch(:runs),
                 system: nil, provider: nil, tools: Harness::NO_TOOLS,
                 instrumentation: Harness::INSTRUMENTATION, memory: nil)
        refuse_unisolated_writes!(tools, isolation: nil, flag: nil)
        runs = check_runs(runs)
        current_run = RunRecorder::CurrentRun.new
        run_recorder = recorder_for(backend:, system:, memory:, tools:, instrumentation:, current_run:,
                                    provider: provider || recording_provider(backend, current_run),
                                    prompts: prompts_from(taskfile))
        said = (1..runs).to_h do |index|
          path = File.join(out, "#{index}.ndjson")
          [path, run_recorder.record(path)]
        end
        raise Refusal, ["no run recorded", *said.values].join("\n") if said.none? { |path, line| path == line }

        said.values
      end

      private

      # The attribution must name what ACTUALLY rendered: `--system` renders
      # instead of the slots, and `SlotFills.from` owns that distinction.
      def recorder_for(backend:, system:, memory:, **rest)
        RunRecorder.new(context: backend.context(system_override: system),
                        attribution: Telemetry::SlotFills.from(backend.slots, override: system),
                        memory: memory_store(memory), **rest)
      end

      # `--memory`, resolved. Unset and `empty` are the same answer, which is
      # why the flag carries no Thor default: a run that names nothing starts
      # from the empty version, and the record says so either way.
      #
      # @param name [String, nil]
      # @raise [Refusal] on a name outside {MEMORIES}
      # Keyed to the PROJECT's root and never to `Dir.pwd`, the invariant
      # {CLI::Wiring#project_memory} states: a sweep run from a subdirectory
      # must measure recall against the memory of the project it is in, not
      # against an empty store nobody wrote to.
      def memory_store(name)
        return Memory::ProjectStore::Null if name.nil? || name == "empty"
        if name == "project"
          return Memory::ProjectStore.new(
            project_dir: ProjectDir.new(root: ::Lain::Project::Resolver.default_project.root)
          )
        end

        raise Refusal, "--memory #{name} is not a memory source; #{MEMORIES.join(" or ")}"
      end

      # What {#arms_report} says instead of the comparison when Ctrl-C
      # arrives mid-run: every run in `graded` finished and was scored before
      # the interrupt, so the money already spent buys a table rather than
      # nothing -- and PARTIAL says outright that no arm past this point ran.
      #
      # A plain run/pass/score table, not {Arm::Driver}'s per-metric one: a
      # {Telemetry::GradeRecord} carries no arm name (the Driver folds THAT
      # in only once every arm's every task has finished), so a row here is a
      # completed GRADE, in the order it landed, rather than a completed arm.
      def partial_arms_report(graded)
        rows = graded.each_with_index.map do |record, index|
          [(index + 1).to_s, record.pass.to_s,
           format("%.3f", record.score)]
        end
        "Arm driver -- PARTIAL, interrupted after #{graded.size} graded run#{"s" unless graded.size == 1}\n" \
          "#{Compare::Table.new(headers: %w[run pass score], rows:)}"
      end

      # The isolation half of the {#arm_report} call, and the one place the
      # unset name stays unset: nil with nothing to journal passes NO keyword at
      # all, so {Arm::Driver}'s own default stands.
      #
      # A SET name REQUIRES a journal. {Lain::CLI::IsolationBackend} decorates
      # BY NEED, so resolving with none hands back a bare backend emitting no
      # {Telemetry::IsolationLease} at all -- and manufacturing a Channel here
      # instead would emit the records into a sink nobody drains, the same
      # unobservable run one layer down. The operator hears this at the door
      # rather than from an empty result after a paid run.
      #
      # A journal with NO name goes through UNACCOMPANIED on purpose, so
      # {#arm_isolation}'s refusal is what says the telemetry would never
      # arrive; a second guard here would be a second authority to drift.
      def lease_options(isolation:, journal:)
        return { journal: }.compact if isolation.nil?

        raise Refusal, "--isolation #{isolation} leases workers and has no journal to record them in" if journal.nil?

        { isolation:, journal: }
      end

      # Named once, so the commands that can offer it quote one sentence and the
      # help text cannot drift from the refusal.
      def isolating_flag = "--isolation #{CONTAINING_BACKENDS.join("|")} --journal PATH"

      # THE PAIR THIS BENCH MAY NOT RUN: a capability set that can act outside
      # the run's own memory, with nothing isolating where it acts.
      #
      # {#lease_options}'s shape, and deliberately so -- an operator meets one
      # idiom rather than two. That guard refuses a named isolation with nowhere
      # to record its leases; this one refuses tools with nowhere to contain
      # them. Both name the flags that fix them, and both fire at the door
      # rather than after a paid run.
      #
      # IT FIRES FIRST, uniformly, at all three assembly methods: a refusal that
      # a wiring mistake elsewhere could get in front of is not a guard. The one
      # thing that is deliberately NOT its business is a name outside the
      # advertised set; see {#uncontained?}.
      #
      # It is UNREPRESENTABLE rather than merely documented, which is the
      # standard this project already holds its secret boundary to: an
      # unisolated arm leases through {Arm::NoIsolation} and runs in the
      # operator's own checkout, and the floor carries `bash` behind
      # {Effect::Handler::Live} with no gate in front of it.
      #
      # @param tools [#call] the capability factory the run would be built with
      # @param isolation [String, nil] the `--isolation` name; nil is UNSET
      # @param flag [String, nil] what the operator can type to fix it, or nil
      #   where the command offers no isolation at all
      # @raise [Refusal] on the unsafe pair
      def refuse_unisolated_writes!(tools, isolation:, flag:)
        return unless uncontained?(isolation)
        # Asked of a BUILT set rather than of the factory: what a run may do is
        # a property of the tools, and a caller may inject a factory of its own.
        # Called with the FULL documented signature -- an injected factory that
        # honours the contract must not raise a bare ArgumentError from inside a
        # guard, where it would render as a backtrace instead of this method's
        # own clean Refusal.
        return unless Harness.writes?(tools.call(recorder: Memory::Recorder.new,
                                                 journal: Channel::Null.instance))

        raise Refusal, "this run's tools can write (#{Harness::WRITERS.join(", ")}) and " \
                       "#{uncontained(isolation)} where they write, so they would act in the working tree " \
                       "this command was run from#{"; add #{flag}" unless flag.nil?}"
      end

      # Unset, or an ADVERTISED backend that contains nothing. A name outside
      # the advertised set is deliberately NOT this guard's business:
      # {Lain::CLI::IsolationBackend::Unknown} names the whole set and is the
      # diagnosis a typo needs, so it has to speak first -- a safety refusal
      # quoting `--isolation nope does not isolate` would answer a question
      # nobody asked and hide the one they did.
      def uncontained?(isolation)
        return true if isolation.nil?

        Lain::CLI::IsolationBackend::BACKENDS.include?(isolation) && !CONTAINING_BACKENDS.include?(isolation)
      end

      # Says which of the two ways the run is uncontained, because "no
      # --isolation" and "--isolation none" are different mistakes and only one
      # of them looks like a typo.
      def uncontained(isolation)
        isolation.nil? ? "nothing isolates" : "--isolation #{isolation} does not isolate"
      end

      # {Altitude} takes a resolved BACKEND (or none), where {#arm_report} takes
      # the pair. Both guards are reused rather than restated: {#lease_options}
      # refuses a set name with nowhere to record its leases, and
      # {#arm_isolation} refuses options given with no name to resolve them for.
      # The `:isolation` key is dropped between them because the first answers it
      # as a NAME and the second takes it as the positional argument.
      def altitude_isolation(name, journal)
        arm_isolation(name, **lease_options(isolation: name, journal:).except(:isolation))
      end

      # The `isolation:` keyword {Arm::Driver} is built with -- or NO keyword at
      # all when the flag is unset, so the Driver stays the one authority on what
      # "no isolation" means (see {#arm_report}).
      #
      # Options with no name to resolve CRASH rather than being dropped: a
      # silent drop would make the resolver's own unknown-key guard depend on an
      # unrelated argument, and a `journal:` the run will never use is a report
      # missing the lease telemetry its caller asked for, with nothing said.
      def arm_isolation(name, **backend_options)
        return { isolation: Lain::CLI::IsolationBackend.resolve(name, **backend_options) } unless name.nil?
        return {} if backend_options.empty?

        raise ArgumentError, "isolation options #{backend_options.keys.inspect} were given with no isolation " \
                             "name to resolve them for; an unisolated arm run leases through Arm::NoIsolation " \
                             "and consults no backend"
      end

      def session_paths(sources)
        Array(sources).flat_map do |source|
          File.directory?(source) ? directory_sessions(source) : [checked_path(source)]
        end
      end

      # Dir.children, not Dir.glob: a directory name carrying glob
      # metacharacters ("run[1]") must not be parsed as a pattern. Sorted, so
      # the report's 1..n ordinals stay deterministic. An empty directory is
      # its own refusal -- falling through to Variance's "at least two" would
      # hide the typo'd path.
      def directory_sessions(dir)
        names = Dir.children(dir).select { |name| name.end_with?(".ndjson") }.sort
        raise Refusal, "no *.ndjson session files under #{dir}" if names.empty?

        names.map { |name| File.join(dir, name) }
      end

      def checked_path(source)
        raise Refusal, "no session file at #{source}" unless File.file?(source)

        source
      end

      # Corrupt's own message names a digest, but only this layer still holds
      # the path -- and an experimenter with a directory of n sessions needs to
      # know WHICH file to regenerate.
      #
      # The MissingObject arm is DEFENSIVE, and kept: the Loader translates
      # every store refusal it can currently be made to raise, but that property
      # lives in two classes this one cannot see, and it was believed and false
      # once already. Landed as Corrupt rather than carried as itself, so this
      # command speaks ONE refusal type whichever arm fires.
      def load_session(path, records)
        replayable(Session.load(records), path)
      rescue Session::Corrupt, Store::MissingObject => e
        raise Session::Corrupt, "#{path}: #{e.message}"
      end

      # DryReplay's 1:1 guard (an orphan request_sent) otherwise fires while
      # Variance constructs, after the paths are gone; probing here converts
      # it to a Refusal naming the ONE file to regenerate.
      def replayable(recording, path)
        recording.dry_replay
        recording
      rescue ArgumentError => e
        raise Refusal, "#{path}: #{e.message}"
      end

      # The one arms provider, built over the journal the comparison records
      # into, so its own records land beside the grades -- and that journal
      # told once what the arms' context needs that this provider lacks. A
      # provider the caller injected is the caller's to have wired.
      def journaled_provider(backend, journal, spawn_options)
        return spawn_options if spawn_options.key?(:provider)

        journal ||= Channel::Null.instance
        provider = backend.provider(journal:)
        Capability::Policy.for(:degrade, journal:).resolve(backend.context, provider)
        spawn_options.merge(provider:)
      end

      # Why a session file is listed rather than measured, or nil when it is
      # measured. A file with no header was never finished; the reason a
      # failed one was set aside is recorded inside it.
      def set_aside_reason(path, records)
        return failed_reason(records) if RunRecorder.failed?(path)
        return "no session header" if records.none? { |record| record["type"] == Session::HEADER_TYPE }

        "no usage recorded beside a truncated stream" if unmeasured?(records)
      end

      def failed_reason(records)
        failure = records.find { |record| record["type"] == "recording_failed" }
        failure ? "failed recording (#{failure["error_class"]}: #{failure["message"]})" : "failed recording"
      end

      # A stream cut short answers with no usage at all; only the pair says
      # the zero is not a measurement.
      def unmeasured?(records)
        records.any? { |record| record["type"] == "truncated_stream" } &&
          records.select { |record| record["type"] == "turn_usage" }
                 .all? { |record| record["usage"].to_h.values.grep(Numeric).all?(&:zero?) }
      end

      # Variance's construction-time guards (n>=2) speak in recordings; the
      # experimenter typed paths, so restore them to the message.
      #
      # Compare's two COMPARABILITY guards are here for the same reason and were
      # not: each names the runs it refused ("manual → plan vs manual → auto",
      # "[] vs [:prompt_caching]") and neither names a file, so pointing this at
      # a directory of a dozen sessions refused with nothing to act on. Both are
      # Lain::Errors rather than ArgumentErrors, which is how they sailed past
      # the narrower rescue this widens.
      def build_variance(recordings, paths, price_book, set_aside)
        Variance.new(recordings:, price_book:, set_aside:)
      rescue ArgumentError, Error => e
        refused = paths.empty? ? e.message : "#{paths.join(", ")}: #{e.message}"
        raise Refusal, [*set_aside, refused].join("\n")
      end

      # This command spends money per run: a sweep of zero must not read as
      # instant success, and a fractional count must refuse rather than truncate
      # -- `Integer(2.5)` quietly books 2, so the parse goes through the String.
      def check_runs(runs)
        count = Integer(runs.to_s, exception: false)
        raise Refusal, "the run count must be a whole number, got #{runs}" if count.nil?
        raise Refusal, "record needs at least one run; a sweep of #{count} records nothing" if count < 1

        count
      end

      # Refusal parity with {#check_runs}: a fractional k must refuse rather
      # than truncate -- `Integer(2.5)` quietly scores recall@2 -- and recall@0
      # retrieves nothing.
      # rubocop:disable Naming/MethodParameterName -- pinned recall@k name.
      def check_k(k)
        depth = Integer(k.to_s, exception: false)
        raise Refusal, "k must be a whole number, got #{k}" if depth.nil?
        raise Refusal, "k must be at least 1; recall@#{depth} retrieves nothing" if depth < 1

        depth
      end
      # rubocop:enable Naming/MethodParameterName

      def prompts_from(taskfile)
        raise Refusal, "no task file at #{taskfile}" unless File.file?(taskfile)

        prompts = File.readlines(taskfile, chomp: true).map(&:strip).reject(&:empty?)
        raise Refusal, "task file #{taskfile} holds no prompts" if prompts.empty?

        prompts
      end

      # The recording client, asked of the ONE backend chat asks -- so every
      # `--provider` name resolves to the same RAW (vendored-transport) client a
      # lossless HTTP recording needs.
      #
      # The keyless refusal is RESTATED, not re-implemented: the backend's own
      # gate fires first, but it speaks in the chat's voice. `record` is the
      # command that spends per run, so the operator hears that instead -- one
      # gate, two audiences.
      #
      # Built over the run that is recording, so a truncated stream or a wait
      # lands in that run's own file.
      def recording_provider(backend, current_run)
        backend.provider(journal: current_run)
      rescue Lain::CLI::Backend::MissingAPIKey
        raise MissingAPIKey, "bench record calls the real API and spends money; set ANTHROPIC_API_KEY to run it"
      end

      # Grades a run against THE TASK IT WAS GIVEN. {Arm::Driver} threads ONE
      # `#grade` duck through every arm and every task while {ArmTasks} carries
      # a gold {Grader::Fixture} PER TASK, so something has to dispatch -- and a
      # `grade(timeline)` call carries exactly one usable key: the run's own
      # user turns, one of which is verbatim the prompt the Driver handed the
      # arm, since every arm asks the task text unchanged.
      #
      # {ArmSweep::GraderAdapter} is the replayed sibling; it needs no dispatch
      # because that sweep drives the arms itself, one task at a time.
      #
      # A timeline naming no task in the suite is a WIRING bug, not a zero
      # score: scored as zero it would look like an arm that failed every task,
      # which is the one reading a bench must never invent.
      class SuiteGrader
        def initialize(suite)
          @suite = unique_prompts!(suite)
        end

        # @param timeline [Timeline] the run to score
        # @return [Grader::Grade]
        def grade(timeline) = task_for(asked_in(timeline)).grader.grade(ArmSweep.trajectory(timeline))

        private

        # {ArmTasks} enforces a unique `id`, NOT a unique `prompt`, and the
        # fixture path is user input. Dispatching by prompt across a duplicate
        # resolves BOTH tasks' runs to the first, scoring the second's gold
        # against the first's trajectory and reporting the difference as a
        # score. Refused here, where the assumption is made, before any arm runs.
        def unique_prompts!(suite)
          shared = suite.group_by(&:prompt).values.select { |tasks| tasks.size > 1 }
          return suite if shared.empty?

          raise Refusal, "arm tasks #{shared.flatten.map(&:id).sort.inspect} share a prompt, and the grader " \
                         "dispatches by prompt -- their gold could not be told apart"
        end

        def task_for(asked)
          @suite.find { |task| asked.include?(task.prompt) } ||
            raise(ArgumentError, "graded a timeline whose user turns name no task in the suite")
        end

        def asked_in(timeline)
          timeline.to_a.select { |turn| turn.role == "user" }
                       .flat_map(&:content).filter_map { |block| block["text"] }
        end
      end
      private_constant :SuiteGrader
    end
  end
end

# After the class body: RunRecorder reopens CLI (and raises CLI::Refusal), and
# nothing above needs it before runtime.
