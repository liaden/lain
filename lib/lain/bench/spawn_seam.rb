# frozen_string_literal: true

module Lain
  module Bench
    # The LIVE spawn seam: the `call(journal:, **spawn_opts) -> Agent` duck
    # every {Arm} drives, built from the SAME {Lain::CLI::Backend} `bench
    # record` and `lain chat` are built from, so `--provider`/`--model`/
    # `--temperature`/`--seed` mean one thing across every command. Sibling of
    # {ArmSweep::Recordings#seam}, which answers the same duck over a provider
    # replayed from a committed fixture.
    #
    # ONE OBJECT, NOT SIX FLAGS. The backend arrives resolved, so this seam
    # holds no second copy of the flag set and two arms cannot differ by a flag
    # nobody threaded.
    #
    # TWO SEAMS, ONE WORD, ONE NESTING LEVEL APART. `provider:` here is the
    # injected Provider OBJECT a spec passes; the backend's own `:provider`
    # OPTION is the `--provider` NAME to resolve. A spec reads
    # `new(backend: Backend.new({provider: "haiku", ...}), provider:)` with both
    # correct. The split exists because the specs of a money-spending seam must
    # never resolve a real client.
    #
    # A FRESH AGENT PER CALL, one provider for all of them, and ONE Context for
    # every call that does not route. The Agent is run state and an arm spawns
    # several; the Context is a frozen value whose whole point is that every
    # agent renders the same prefix, so an unrouted call answers the seam's own
    # Context itself, byte-identically. A routed one is the single exception,
    # and {#routed} says why it has to be. RESOLUTION HAPPENS AT CONSTRUCTION:
    # an unknown provider name and a missing API key are refusals the operator
    # should meet before any arm runs, not n tasks into a comparison.
    #
    # Capabilities and reporting come from {Bench::Harness}, per spawn.
    #
    # THE NAME IS VALIDATED ONLY ON THE RESOLVING PATH. {Lain::CLI::Backend}
    # validates its summarizer flag eagerly on the premise that `--provider`
    # refuses on every run because `#provider` always runs; this is the first
    # caller for which that is false, since an injected `provider`
    # short-circuits `#provider` and an explicit `--model` short-circuits the
    # model default that would otherwise validate it. Inject both and a nonsense
    # `--provider` is simply unused. Nothing pins that hole, so it is recorded
    # here.
    #
    # AN UNSET `--system` TEACHES THE TRAJECTORY CONTRACT; it does not fall back
    # to the project's prompt slots. The gold graders score a trajectory parsed
    # out of assistant text by {ArmSweep::FileBlocks}, so an arm never told that
    # format answers in prose and scores near zero on every task -- a report
    # reading as a suite nobody could do rather than one nobody was told the
    # rules of. Near, not exactly: an untaught arm still scores 0.500 on
    # `fix-off-by-one-loop`, because that task's `excludes:` check passes
    # vacuously against a file nobody wrote, which is the grader's hole and not
    # this seam's. The default is coalesced in {#taught} rather than declared as
    # the keyword's value because `exe/lain` reads the flag off an options hash:
    # an unset `--system` arrives as an explicit nil, which a keyword default
    # never sees.
    #
    # Two names here do not mean what they look like: `CLI` alone is
    # {Bench::CLI} and `Session` alone is {Bench::Session}, so the agent
    # runtime's {Lain::CLI::Backend} and {Lain::Session} are written in full.
    class SpawnSeam
      # An arm routed to a shared sibling template this seam cannot render. Its
      # own error rather than {CLI::Refusal}, because no argv spells a template:
      # it is a wiring fact between an arm and a seam, and the operator who
      # meets it typed nothing wrong.
      class UnroutableTemplate < Error; end

      # An arm task's answer is a whole file body (the FILE...END trajectory the
      # arm graders parse), not `record`'s one-line echo -- and a ceiling hit
      # ends the run as a `:max_tokens` failure rather than a short answer. So
      # deliberately larger than {CLI::RECORD_DEFAULTS}' 1024 rather than shared
      # with it: two commands, two answer shapes.
      #
      # The ceiling itself rides in on the backend, so this is what `bench arms`
      # DECLARES its `--max-tokens` default to be, in the namespace whose answer
      # shape justifies it.
      DEFAULT_MAX_TOKENS = 4096

      # @param backend [Lain::CLI::Backend] the resolved provider-and-Context
      #   seam the flags built; the ONE argument, so nothing here can hold a
      #   stale copy of a flag
      # @param provider [Lain::Provider, nil] injected in specs; nil resolves the
      #   real client (key-gated for anthropic by {Lain::CLI::Backend} itself)
      # @param tools [#call] `call(recorder:, journal:) -> Toolset`, asked once
      #   per spawn; see {Bench::Harness} for why the capabilities are a factory
      #   rather than one value. {Bench::Harness::NO_TOOLS} is the named empty arm.
      # @param system [String, nil] `--system`, rendered INSTEAD of the project's
      #   prompt slots -- the one thing the backend does not read from its own
      #   options. Unset, the arms are taught {ArmSweep::FileBlocks::CONTRACT}
      #   instead, for the reason in the class doc.
      # @param instrumentation [#call] `call(journal:, recorder:, worker_env:)
      #   -> Agent::Instrumentation`, asked once per spawn for the same reason.
      #   It takes the worker env because the run's guard stack is built over
      #   the checkout a lease cut, if it cut one.
      # @raise [Lain::CLI::UnknownProvider] on a name outside the advertised set
      # @raise [Lain::CLI::Backend::MissingAPIKey] resolving anthropic keyless
      # @param memory [#view] the project memory each spawned agent's view opens
      #   on; {Memory::ProjectStore::Null} keeps an arm's writes out of the
      #   operator's own project, which is what makes two sweeps comparable
      def initialize(backend:, provider: nil, tools: Harness::TOOLS, system: nil,
                     instrumentation: Harness::INSTRUMENTATION, memory: Memory::ProjectStore::Null)
        @provider = provider || backend.provider
        @context = backend.context(system_override: taught(system))
        @tools = tools
        @instrumentation = instrumentation
        @memory = memory
      end

      # What every agent this seam spawns will ask, so a report can ATTRIBUTE
      # itself. The one thing exposed off the resolved Context, and deliberately
      # not `@provider` or `@context` wholesale: the provider carries the
      # credential and base URL a report must never name, and a Context reader
      # would be a second door onto the flag set this class holds one copy of.
      #
      # @return [String] the resolved model name
      def model = @context.model

      # EVERY keyword an arm speaks, NAMED. There is no `**` tail any more, and
      # its absence is the point: a parameter this class documents is one
      # somebody decided what to do about, and `model:`/`template:` were
      # documented here by name while being swallowed.
      #
      # @param journal [#<<] where this run's {Telemetry::TurnUsage} lands, which
      #   is what prices exactly the turns this arm produced
      # @param workspace [Lain::Workspace] sent into the spawned Agent's Request,
      #   not stored; empty unless the task needs files
      # @param timeline [Lain::Timeline, nil] the agent's root, when the caller
      #   holds one directly ({Arm::DualLedger}'s per-step spawn)
      # @param base_timeline [Lain::Timeline, nil] the agent's root, when the
      #   caller only has a fresh root over another's store
      #   ({Arm::OrchestratorWorker}'s per-worker spawn); falls back to `timeline`
      # @param worker_env [Lain::WorkerEnv, nil] a lease's environment, threaded
      #   into the spawned {Lain::Session}; nil lands on the process environment
      # @param model [String, nil] {Arm::AdaptiveRouter}'s routed model; blank or
      #   absent keeps the seam's own Context, see {#routed}
      # @param template [String, nil] the other half of {Oracle::Router}'s
      #   answer, and the half this seam cannot render -- see {#refuse_template!}
      # @param spawned_from [String, nil] the lead turn this worker descends
      #   from; ACCEPTED AND DROPPED, see {#rooted}
      # @return [Lain::Agent] a fresh agent
      # @raise [UnroutableTemplate] on a routed sibling template
      def call(journal:, workspace: Workspace.empty, timeline: nil, base_timeline: nil,
               worker_env: nil, model: nil, template: nil, spawned_from: nil)
        recorder = @memory.view
        # Resolved ONCE: the Session the tools resolve paths against and the
        # guard stack the layout is held at must name the same checkout.
        env = worker_env || WorkerEnv.default
        Agent.new(provider: @provider, toolset: @tools.call(recorder:, journal:),
                  context: routed(model, template), workspace:,
                  timeline: rooted(timeline, base_timeline, spawned_from),
                  session: Lain::Session.new(worker_env: env),
                  instrumentation: @instrumentation.call(journal:, recorder:, worker_env: env))
      end

      private

      # The routed Context, and the ONE place this seam departs from "one
      # Context for every agent". An unrouted spawn answers `@context` ITSELF,
      # so the prefix every other arm renders is byte-identical; a routed one
      # takes a frozen copy through {Lain::Context#with_model}.
      #
      # THE DEPARTURE IS FORCED, and by a false negative rather than by
      # convenience. A seam that drops `model:` makes {Arm::AdaptiveRouter} and
      # {Arm::SingleThread} the same program over the same provider, Context
      # and model -- and against a real provider at temperature > 0 those two
      # columns differ by SAMPLING NOISE, which does not read as a duplicate.
      # It reads as a result. A bench manufacturing a false negative on its own
      # headline comparison has done something worse than leaving the arm
      # unwired.
      #
      # Blank is unset here for {#taught}'s reason: a router answering `""`
      # has not chosen a model, and reading that as one would render a Request
      # naming the empty string.
      def routed(model, template)
        refuse_template!(template)
        Blankness.blank?(model) ? @context : @context.with_model(model)
      end

      # `template` is {Oracle::Router::SCHEMA}'s "shared sibling template
      # prefix", and this seam has nowhere to put one: a sibling prefix is a
      # property of the rendered system blocks, and inventing that here would be
      # a second authority over what an arm renders, beside the backend that
      # already owns it.
      #
      # So it RAISES rather than being dropped. An arm routing against a seam
      # that cannot route fails at its first task, where the wiring is what a
      # reader suspects -- not at the report, where two arms quietly agreeing
      # reads as a finding. Blank passes, because blank is
      # {Oracle::Router.heuristic}'s own default and means "no template", which
      # is the whole of the path that exists today.
      def refuse_template!(template)
        return if Blankness.blank?(template)

        raise UnroutableTemplate,
              "this spawn was routed to the shared sibling template #{template.inspect}, and the bench " \
              "spawn seam renders no template: a sibling prefix is part of the system blocks the backend " \
              "builds, not a keyword this seam can forward. Route on model alone -- the heuristic router's " \
              "own default template is blank -- or give the Context a template seam first"
      end

      # Where `spawned_from` is dropped, and the drop is now one named place
      # rather than a swallowing `**`. Honouring it means writing a `:spawn`
      # event into the lead's Store -- {Tools::Subagent::Lineage}'s job, not
      # something a root Timeline can carry -- so a bench worker still has no
      # lineage for {Consolidation} or {Grader::ToolCallIndex} to walk back to
      # its lead. Pre-existing, shared with the replay sibling, and unchanged by
      # this card.
      def rooted(timeline, base_timeline, _spawned_from) = timeline || base_timeline

      # BLANK IS UNSET, not "no system prompt". `--system ''` is truthy, so a
      # plain `||` would ship an empty prompt and leave that arm untaught.
      # {Blankness} rather than `strip`, for the reason written there: a lone
      # U+00A0 is not an instruction either.
      #
      # So NOTHING can currently ask for an UNTAUGHT arm. "Does teaching the
      # format matter?" is a fair question to put to a study bench, but it wants
      # a flag of its own rather than a blank string, which reads as a slip.
      def taught(system) = Blankness.blank?(system) ? ArmSweep::FileBlocks::CONTRACT : system
    end
  end
end
