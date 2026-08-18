# frozen_string_literal: true

module Lain
  module Bench
    # The LIVE spawn seam: the `call(journal:, **spawn_opts) -> Agent` duck every
    # {Arm} drives (see {Lain::Arm#run}), built from the SAME
    # {Lain::CLI::Backend} `bench record` and `lain chat` are built from. It is
    # the sibling of {ArmSweep::Recordings#seam}, which answers the same duck
    # over a provider replayed from a committed fixture; this one asks a real
    # backend, so `--provider`/`--model`/`--temperature`/`--seed` mean one thing
    # across every command and an unknown name raises the one
    # {Lain::CLI::UnknownProvider} from all of them.
    #
    # ONE OBJECT, NOT SIX FLAGS. The backend arrives resolved, so this seam holds
    # no second copy of the flag set and two arms cannot differ by a flag nobody
    # threaded -- the same single-argument shape {Lain::CLI::ChatLaunch} uses.
    #
    # TWO SEAMS, ONE WORD, ONE NESTING LEVEL APART. `provider:` here is the
    # injected Provider OBJECT a spec passes; the backend's own `:provider` OPTION
    # is the `--provider` NAME to resolve. The old `provider_name`/`provider`
    # spelling made that obvious and the shared word does not, so a spec reads
    # `new(backend: Backend.new({provider: "haiku", ...}), provider:)` with both
    # correct. The reason for the split is unchanged: the specs of a
    # money-spending seam must never resolve a real client.
    #
    # A FRESH AGENT PER CALL, one provider and one Context for all of them. The
    # Agent is run state (a Timeline, a Session, a loop position) and an arm
    # spawns several; the provider is a client, and the Context is a frozen
    # value whose whole point is that every agent renders the same prefix -- a
    # per-call Context would break prompt-cache stability for no gain.
    #
    # RESOLUTION HAPPENS AT CONSTRUCTION, not at the first spawn. An unknown
    # provider name and a missing API key are both refusals the operator should
    # meet before any arm runs, not n tasks into a comparison.
    #
    # THE NAME IS VALIDATED ONLY ON THE RESOLVING PATH, which is exactly the
    # production one. {Lain::CLI::Backend} justifies validating its summarizer
    # flag eagerly with "`--provider` refuses on every run because `#provider`
    # always runs"; this is the first caller for which that premise is false,
    # since an injected `provider` short-circuits `#provider` and an explicit
    # `--model` short-circuits the model default that would otherwise validate
    # it. Inject both and a nonsense `--provider` is simply unused. Nothing
    # pins that hole -- the spec which did asserted only that nothing was
    # raised on a shape production never builds -- so it is recorded here.
    #
    # AN UNSET `--system` TEACHES THE TRAJECTORY CONTRACT, it does not fall back
    # to the project's prompt slots. The gold graders score a trajectory parsed
    # out of assistant text by {ArmSweep::FileBlocks}, so an arm never told that
    # format answers in prose and scores near zero on every task -- a report
    # reading as a suite nobody could do rather than as a suite nobody was told
    # the rules of. Near, not exactly: an untaught arm still scores 0.500 on
    # `fix-off-by-one-loop`, because that task's `excludes:` check passes
    # vacuously against a file nobody wrote, which is the grader's own hole and
    # not this seam's. The default is coalesced HERE rather than declared as the
    # keyword's value because `exe/lain` reads the flag off an options hash: an
    # unset `--system` arrives as an explicit nil, which a keyword default never
    # sees. An explicit prompt still wins outright.
    #
    # Two names in this namespace do not mean what they look like: `CLI` alone
    # is {Bench::CLI} and `Session` alone is {Bench::Session}, so the agent
    # runtime's {Lain::CLI::Backend} and {Lain::Session} are written in full.
    class SpawnSeam
      # An arm task's answer is a whole file body (the FILE...END trajectory the
      # arm graders parse), not `record`'s one-line echo -- and a ceiling hit
      # ends the run as a `:max_tokens` failure rather than a short answer. So
      # this is deliberately larger than {CLI::RECORD_DEFAULTS}' 1024 rather
      # than shared with it: two commands, two answer shapes.
      #
      # The ceiling itself now rides in on the backend, so this is what
      # `bench arms` DECLARES its `--max-tokens` default to be -- one number, in
      # the namespace whose answer shape justifies it, rather than a second
      # default re-applied here for a caller who already resolved one.
      DEFAULT_MAX_TOKENS = 4096

      # @param backend [Lain::CLI::Backend] the resolved provider-and-Context
      #   seam the flags built; the ONE argument, so nothing here can hold a
      #   stale copy of a flag
      # @param provider [Lain::Provider, nil] injected in specs; nil resolves the
      #   real client (key-gated for anthropic by {Lain::CLI::Backend} itself)
      # @param toolset [Lain::Toolset] the capabilities every spawned agent gets
      # @param system [String, nil] `--system`, rendered INSTEAD of the project's
      #   prompt slots -- the one thing the backend does not read from its own
      #   options ({Lain::CLI::Backend#context} takes it as an override). Unset,
      #   the arms are taught {ArmSweep::FileBlocks::CONTRACT} instead of the
      #   project's slots, for the reason below.
      # @raise [Lain::CLI::UnknownProvider] on a name outside the advertised set
      # @raise [Lain::CLI::Backend::MissingAPIKey] resolving anthropic keyless
      def initialize(backend:, provider: nil, toolset: Toolset.new([]), system: nil)
        @provider = provider || backend.provider
        @context = backend.context(system_override: taught(system))
        @toolset = toolset
      end

      # What every agent this seam spawns will ask, so a report can ATTRIBUTE
      # itself ({Arm::Driver}'s header). The one thing exposed off the resolved
      # Context, and deliberately not `@provider` or `@context` wholesale: the
      # provider carries the credential and the base URL a report must never
      # name, and a Context reader would be a second door onto the flag set this
      # class exists to hold exactly one copy of.
      #
      # @return [String] the resolved model name
      def model = @context.model

      # The widened `**` tail every arm speaks, mapped onto one Agent:
      # `timeline:`/`base_timeline:` to the agent's root ({Arm::DualLedger}
      # passes the first, {Arm::OrchestratorWorker} a fresh root over the lead's
      # store as the second) and a lease's `worker_env:` to its {Lain::Session}.
      # The tail is swallowed, not rejected: {Arm::AdaptiveRouter} spawns with
      # `model:`/`template:`, and a fixed-arity seam would crash an arm this one
      # does not yet serve.
      #
      # The keyword an arm passes TODAY and this seam still drops is
      # `spawned_from:` ({Arm::OrchestratorWorker} sends `lead.head_digest`
      # with the fresh worker root). No spawn seam anywhere honours it, so a
      # bench worker's root carries no lineage for {Consolidation} or
      # {Grader::ToolCallIndex} to walk back to the lead -- pre-existing, shared
      # with the replay sibling, and named here because it is the one a reader
      # will actually meet.
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
      # plain `||` would ship an empty prompt and leave that arm untaught --
      # this class's own defect, reached through the flag that is meant to be
      # the way out of it, and spelled the way most operators read as "unset".
      # {Blankness} rather than `strip` for the reason written there: a lone
      # U+00A0 is not an instruction either.
      #
      # So NOTHING currently asks for an UNTAUGHT arm, and "does teaching the
      # format matter?" is a fair question to put to a study bench. It wants a
      # flag of its own (`--no-system`) rather than a blank string, which reads
      # as a slip rather than as an experiment.
      def taught(system) = Blankness.blank?(system) ? ArmSweep::FileBlocks::CONTRACT : system

      # An unleased call lands on the process environment -- {WorkerEnv.default},
      # restated here rather than branched around, because {Lain::Session}'s own
      # default is that same expression and a nil would reach the tools as a
      # Session with no cwd to resolve against.
      def session(worker_env) = Lain::Session.new(worker_env: worker_env || WorkerEnv.default)
    end
  end
end
