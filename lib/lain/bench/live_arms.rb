# frozen_string_literal: true

module Lain
  module Bench
    # Which topologies the live arm comparison puts side by side, how the
    # orchestrator among them splits a task up, and which model the router among
    # them sends each child to -- always against the {Arm::SingleThread}
    # control, since a comparison is only a comparison against one.
    #
    # A MODULE with a builder rather than a frozen constant map because
    # `lain/bench` loads BEFORE `lain/arm` (see lain.rb) -- these classes exist
    # at call time, not at this file's load time.
    #
    # Each arm keeps its own DEFAULT (real, monotonic) clock. {ArmSweep} zeroes
    # its clock because a replayed mock has no parallelism to time; a live run
    # has real fan-out, and zeroing it here would erase the measurement the
    # live path exists to take.
    module LiveArms
      # A path a task names: `lib/widget.rb`, `config/a.yml`, `lib/utils/slugify.rb`.
      # The trailing `[a-z]{2,4}` is what keeps a version string ("2.1.0") and a
      # sentence boundary out of the set.
      FILE_PATH = %r{\b[\w.-]+(?:/[\w.-]+)*\.[a-z]{2,4}\b}
      private_constant :FILE_PATH

      # ONE SUBTASK PER FILE THE TASK NAMES.
      #
      # {Arm::OrchestratorWorker::DEFAULT_DECOMPOSE} splits on LINES, and every
      # prompt in a committed {ArmTasks} fixture is a folded YAML scalar -- one
      # line, so one worker, so an orchestrator arm that never orchestrates and
      # a report column silently a second copy of the control. Inheriting that
      # default would have shipped a structurally inert arm on the path that
      # spends real money, which is why the replayed sibling injects its own.
      #
      # The FILE is the suite's own unit of independence: `gold_files` is keyed
      # by path, and a `:parallel` task is one whose every file's edit needs
      # zero context from any other.
      #
      # Each worker is briefed with the WHOLE task and told which file is its
      # share, rather than handed a bare path no one could act on. That does not
      # starve a worker of context on purpose -- measuring context-starvation
      # wants a different decomposition, and choosing one is a bench-methodology
      # decision, not this seam's to make.
      #
      # A task naming no path is not split at all: one worker doing the whole
      # thing beats N workers doing nothing.
      DEFAULT_DECOMPOSE = lambda do |task|
        paths = files_named(task)
        return [task.to_s] if paths.empty?

        paths.map { |path| "#{task}\n\nYour share of this task is #{path}, and only #{path}." }
      end

      # The files a task names, deduplicated, read by BOTH seams this module
      # hands the roster: the orchestrator's decomposition above and the
      # router's model choice below. One reader, so the two cannot disagree
      # about what makes a task big.
      def self.files_named(task) = task.to_s.scan(FILE_PATH).uniq
      private_class_method :files_named

      # The cheaper sibling a narrow task is routed to. ONE id and not a
      # per-provider table, because there is no general "a cheaper model than
      # this one" function to write: a roster whose backend cannot serve this
      # id is REFUSED at assembly instead of guessing.
      CHEAP_MODEL = "claude-haiku-4-5"

      # What a backend must have resolved for {.default_router} to route it: an
      # Anthropic id, since {CHEAP_MODEL} is one, and not {CHEAP_MODEL} itself,
      # which would put both branches on one model and bill a fourth arm to
      # reprint the control.
      ROUTABLE_MODEL = /\Aclaude-/
      private_constant :ROUTABLE_MODEL

      # A backend this roster's own router cannot route on. Its own error rather
      # than {CLI::Refusal} only in WHERE it is raised: the policy that knows
      # what is routable lives here, and `exe/lain` presents every {Lain::Error}
      # as a sentence, so an operator still meets a sentence and not a trace.
      class UnroutableBackend < Lain::Error; end

      # WHICH MODEL A CHILD RUNS UNDER: the capable branch is WHATEVER THE
      # BACKEND RESOLVED, so `--model` moves this arm exactly as it moves the
      # other three and only the cheap branch departs from it.
      #
      # The split is a PROPERTY OF THE TASK, the one {DEFAULT_DECOMPOSE} already
      # splits on and read through the same {files_named}: a task naming more
      # than one file is one whose edits have to stay consistent ACROSS files,
      # which is the work a bigger model is bought for. A threshold on task
      # LENGTH -- the obvious alternative -- is a number tuned to a corpus, and
      # on the committed suite it ranks backwards: the shortest task there names
      # three files while longer ones name a single file.
      #
      # @param capable [String] the backend's own resolved model
      # @param cheap [String] the model narrow tasks route to
      # @return [#call] the {Oracle::Heuristic} predicate
      def self.default_route(capable, cheap: CHEAP_MODEL)
        lambda do |inputs|
          files = files_named(inputs.fetch(:task))
          spread = files.size > 1
          { "model" => spread ? capable : cheap, "template" => "",
            "reason" => "task names #{files.size} file(s), #{spread ? "more than one" : "at most one"}" }
        end
      end

      # The heuristic tier {Arm::AdaptiveRouter} asks. The QUESTION stays
      # {Oracle::Router}'s -- template, schema and tier, and so the digest a
      # replay keys on -- while the POLICY is this roster's, exactly as
      # {DEFAULT_DECOMPOSE} is this roster's while the mechanism stays
      # {Arm::OrchestratorWorker}'s.
      #
      # `cheap_model:` is the operator's own answer to "what is cheaper than
      # this backend's model" -- ONE id, read literally, never a per-provider
      # table (see {ROUTABLE_MODEL}'s comment): there is no general "a cheaper
      # model than this one" function to write. Unset, a Claude `model` keeps
      # {CHEAP_MODEL}; unset on anything else there is nothing to fall back to.
      #
      # @param model [String] what the backend resolved
      # @param cheap_model [String, nil] `--cheap-model`, read literally
      # @return [Oracle::Heuristic]
      # @raise [UnroutableBackend] when no cheaper sibling is named or servable
      def self.default_router(model, cheap_model: nil)
        cheap = cheap_model || claude_default_cheap(model)
        refuse_unroutable!(model, cheap)
        Oracle::Heuristic.new(definition: Oracle::Router.definition, predicate: default_route(model, cheap:))
      end

      # {CHEAP_MODEL} is Anthropic's own, so it answers "what is cheaper than
      # this" only for a `model` that is itself Anthropic's.
      #
      # @param model [String] what the backend resolved
      # @return [String, nil] {CHEAP_MODEL}, or nil when `model` is not Claude's
      def self.claude_default_cheap(model)
        CHEAP_MODEL if model.to_s.match?(ROUTABLE_MODEL)
      end
      private_class_method :claude_default_cheap

      # Loudly, and BEFORE any arm runs. An unset `--cheap-model` on a backend
      # {CHEAP_MODEL} means nothing to, or a `--cheap-model` equal to `model`
      # itself, both mean the fourth arm cannot be told apart from the control
      # -- finding that out after three arms have billed against a real
      # provider is the expensive way to learn it.
      #
      # @param model [String] what the backend resolved
      # @param cheap [String, nil] the resolved cheap sibling, or nil when none
      #   was named and none could be assumed
      def self.refuse_unroutable!(model, cheap)
        if cheap.nil?
          raise UnroutableBackend,
                "the adaptive-router arm routes narrow tasks to a cheaper model, and this run resolved " \
                "#{model.to_s.inspect}, which is not a Claude model -- so this roster has no cheaper " \
                "sibling to name for it. Give `bench arms` an Anthropic --model, or a --cheap-model " \
                "naming a model this backend can serve"
        end

        return unless cheap == model.to_s

        raise UnroutableBackend,
              "the adaptive-router arm would send both branches to #{model.to_s.inspect}, running the " \
              "control twice under two names. Name a --cheap-model different from --model"
      end
      private_class_method :refuse_unroutable!

      # The two epic entries' labels. They differ in WHO answers the gates and in
      # nothing else, so the names are the only thing telling their rows apart.
      PROGRESSIVE = "epic-progressive"
      HANDS_OFF = "epic-hands-off"

      # What the altitude arms need and the orchestration arms do not: how a
      # plan gets written, who carries it, and one already-built driver per epic
      # entry -- each carrying the gate policy that entry is FOR, since the
      # policy belongs to the driver and never to the ladder.
      #
      # A value rather than nine keywords on {.altitude}: they arrive together,
      # they are threaded together, and a roster assembled from loose arguments
      # is one where two arms can differ by a seam nobody passed.
      # `grades` is what makes the epic rows READABLE. Both epic arms score by
      # rolling up the per-issue grades their driver's grading hook collected,
      # and an arm that rolled up none refuses -- correctly, but that prints
      # "not measured" in every cell. Unthreaded, the only roster this builds
      # could never show a four-arm comparison at all.
      Seams = Data.define(:planner, :actors, :supervisor, :progressive, :hands_off, :slug, :records,
                          :grading, :layout, :grades) do
        # `grading` and `layout` default to nil rather than to the objects they
        # stand for: `bench` loads BEFORE `arm` and `grader`, so a default naming
        # either here would be a boot-time NameError. {.altitude} resolves them
        # in a method body, where those units exist.
        def initialize(planner:, actors:, supervisor:, progressive:, hands_off:, slug:,
                       records: -> { [] }, grading: nil, layout: nil, grades: -> { {} })
          super
        end
      end

      # The DECOMPOSITION comparison `lain bench altitude` runs: the same work
      # entered at four different heights on {Arm::Ladder}, lowest rung first, so
      # the report reads from the cheapest entry to the richest.
      #
      # One instrument for all four, {.build}'s own rule and for its own reason:
      # a comparison is only a comparison if the clock and the price book are
      # shared.
      #
      # @param seams [Seams] what the planned and gated arms are driven by
      # @param price_book [Lain::PriceBook] prices every arm's journal
      # @return [Array<Lain::Arm>] one-shot, plan-only, then the two epic entries
      def self.altitude(seams:, price_book: PriceBook.default)
        instrument = Arm::Instrument.new(price_book:)
        [Arm::OneShot.new(instrument:, grading: seams.grading || Arm::OneShot::PASS_THROUGH),
         Arm::PlanOnly.new(instrument:, planner: seams.planner, actors: seams.actors,
                           supervisor: seams.supervisor, layout: seams.layout || TestLayout::None),
         *epic_entries(seams, instrument)]
      end

      # The two epic entries differ in ONE member -- which driver, and so which
      # gate policy -- so they are built from one expression rather than two that
      # could drift. Named because writing them out twice is what put
      # {.altitude} over Metrics/AbcSize.
      def self.epic_entries(seams, instrument)
        [[PROGRESSIVE, seams.progressive], [HANDS_OFF, seams.hands_off]].map do |(name, driver)|
          Arm::Epic.new(name:, driver:, slug: seams.slug, instrument:,
                        records: seams.records, grades: seams.grades)
        end
      end
      private_class_method :epic_entries

      # @param price_book [Lain::PriceBook] prices each arm's journal
      # @param decompose [#call] `call(task) -> Array<String>`, the orchestrator's
      #   split; the linear arms have nothing to decompose
      # @param model [String] what the backend this roster's seam was built from
      #   resolved. The routing arm's capable branch IS this string, so `--model`
      #   moves all four arms; without it the fourth would spend under an id
      #   nobody asked for while the report header named this one.
      # @param router [#ask, #definition] the tier {Arm::AdaptiveRouter} asks
      #   which model each child runs under; built from `model` (and
      #   `cheap_model`) when absent. The arm takes its `definition:` OFF this
      #   object rather than defaulting its own, so the journaled
      #   `oracle_digest` names the oracle that answered.
      # @param cheap_model [String, nil] `--cheap-model`, forwarded to
      #   {.default_router} when `router` is absent; ignored when `router` is
      #   given, since a caller bringing its own tier answers this question itself.
      # @return [Array<Lain::Arm>] single-thread control first
      # @raise [UnroutableBackend] when no `router` is given and `model` has no
      #   cheaper sibling named or servable
      def self.build(price_book: PriceBook.default, decompose: DEFAULT_DECOMPOSE,
                     model: Provider::Anthropic::DEFAULT_MODEL, router: nil, cheap_model: nil)
        # One instrument, so all four arms report wall-time off the same clock
        # and dollars off the same book -- the comparison is only a comparison
        # if the measuring is shared.
        instrument = Arm::Instrument.new(price_book:)
        [Arm::SingleThread.new(name: "single-thread", instrument:),
         Arm::OrchestratorWorker.new(name: "orchestrator-worker", instrument:, decompose:),
         Arm::DualLedger.new(name: "dual-ledger", instrument:),
         Arm::AdaptiveRouter.new(name: "adaptive-router", instrument:,
                                 router: router || default_router(model, cheap_model:))]
      end
    end
  end
end
