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
    # A FRESH AGENT PER CALL, one provider and one Context for all of them. The
    # Agent is run state and an arm spawns several; the Context is a frozen
    # value whose whole point is that every agent renders the same prefix, so a
    # per-call one would break prompt-cache stability for no gain. RESOLUTION
    # HAPPENS AT CONSTRUCTION: an unknown provider name and a missing API key
    # are refusals the operator should meet before any arm runs, not n tasks
    # into a comparison.
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
      # @param toolset [Lain::Toolset] the capabilities every spawned agent gets
      # @param system [String, nil] `--system`, rendered INSTEAD of the project's
      #   prompt slots -- the one thing the backend does not read from its own
      #   options. Unset, the arms are taught {ArmSweep::FileBlocks::CONTRACT}
      #   instead, for the reason in the class doc.
      # @raise [Lain::CLI::UnknownProvider] on a name outside the advertised set
      # @raise [Lain::CLI::Backend::MissingAPIKey] resolving anthropic keyless
      def initialize(backend:, provider: nil, toolset: Toolset.new([]), system: nil)
        @provider = provider || backend.provider
        @context = backend.context(system_override: taught(system))
        @toolset = toolset
      end

      # What every agent this seam spawns will ask, so a report can ATTRIBUTE
      # itself. The one thing exposed off the resolved Context, and deliberately
      # not `@provider` or `@context` wholesale: the provider carries the
      # credential and base URL a report must never name, and a Context reader
      # would be a second door onto the flag set this class holds one copy of.
      #
      # @return [String] the resolved model name
      def model = @context.model

      # The widened `**` tail every arm speaks, mapped onto one Agent. The tail
      # is swallowed, not rejected: {Arm::AdaptiveRouter} spawns with
      # `model:`/`template:`, and a fixed-arity seam would crash an arm this one
      # does not yet serve.
      #
      # The keyword an arm passes TODAY and this seam still drops is
      # `spawned_from:`. No spawn seam anywhere honours it, so a bench worker's
      # root carries no lineage for {Consolidation} or {Grader::ToolCallIndex}
      # to walk back to the lead -- pre-existing, and shared with the replay
      # sibling.
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
      # @return [Lain::Agent] a fresh agent
      def call(journal:, workspace: Workspace.empty, timeline: nil, base_timeline: nil, worker_env: nil, **)
        Agent.new(provider: @provider, toolset: @toolset, context: @context,
                  journal:, workspace:, timeline: timeline || base_timeline,
                  session: session(worker_env))
      end

      private

      # BLANK IS UNSET, not "no system prompt". `--system ''` is truthy, so a
      # plain `||` would ship an empty prompt and leave that arm untaught.
      # {Blankness} rather than `strip`, for the reason written there: a lone
      # U+00A0 is not an instruction either.
      #
      # So NOTHING can currently ask for an UNTAUGHT arm. "Does teaching the
      # format matter?" is a fair question to put to a study bench, but it wants
      # a flag of its own rather than a blank string, which reads as a slip.
      def taught(system) = Blankness.blank?(system) ? ArmSweep::FileBlocks::CONTRACT : system

      # An unleased call lands on the process environment. Restated rather than
      # branched around, because a nil would reach the tools as a Session with
      # no cwd to resolve against.
      def session(worker_env) = Lain::Session.new(worker_env: worker_env || WorkerEnv.default)
    end
  end
end
