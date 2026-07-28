# frozen_string_literal: true

module Lain
  module Bench
    # The LIVE spawn seam: the `call(journal:, **spawn_opts) -> Agent` duck every
    # {Arm} drives (see {Lain::Arm#run}), built from the SAME backend flags
    # `bench record` understands. It is the sibling of
    # {ArmSweep::Recordings#seam}, which answers the same duck over a provider
    # replayed from a committed fixture; this one resolves a real provider
    # through {Lain::CLI::Backend}, so `--provider`/`--model`/`--temperature`/
    # `--seed` mean one thing across every bench command and an unknown name
    # raises the one {Lain::CLI::UnknownProvider} from all of them.
    #
    # A FRESH AGENT PER CALL, one provider and one Context for all of them. The
    # Agent is run state (a Timeline, a Session, a loop position) and an arm
    # spawns several; the provider is a client, and the Context is a frozen
    # value whose whole point is that every agent renders the same prefix -- a
    # per-call Context would break prompt-cache stability for no gain.
    #
    # `provider_name` is the `--provider` FLAG; `provider` is the injected
    # Provider OBJECT a spec passes -- {Bench::CLI#record}'s name-to-resolve /
    # object-to-inject split, kept here for the same reason: the specs of a
    # money-spending seam must never resolve one.
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
    # `model` short-circuits the model default that would otherwise validate it.
    # Inject both and a nonsense `provider_name` is simply unused. A spec pins
    # that hole rather than describing it.
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
      DEFAULT_MAX_TOKENS = 4096

      # @param provider [Lain::Provider, nil] injected in specs; nil resolves the
      #   real client (key-gated for anthropic by {Lain::CLI::Backend} itself)
      # @param toolset [Lain::Toolset] the capabilities every spawned agent gets
      # @param provider_name [String] the `--provider` flag
      # @raise [Lain::CLI::UnknownProvider] on a name outside the advertised set
      # @raise [Lain::CLI::Backend::MissingAPIKey] resolving anthropic keyless
      def initialize(provider: nil, toolset: Toolset.new([]), provider_name: "anthropic", api_base: nil,
                     model: nil, max_tokens: DEFAULT_MAX_TOKENS, system: nil, temperature: nil, seed: nil)
        backend = Lain::CLI::Backend.new(provider: provider_name, api_base:, model:, max_tokens:,
                                         temperature:, seed:)
        @provider = provider || backend.provider
        @context = backend.context(system_override: system)
        @toolset = toolset
      end

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
      # @return [Lain::Agent] a fresh agent
      def call(journal:, workspace: Workspace.empty, timeline: nil, base_timeline: nil, worker_env: nil, **)
        Agent.new(provider: @provider, toolset: @toolset, context: @context,
                  journal:, workspace:, timeline: timeline || base_timeline,
                  session: session(worker_env))
      end

      private

      # An unleased call lands on the process environment -- {WorkerEnv.default},
      # restated here rather than branched around, because {Lain::Session}'s own
      # default is that same expression and a nil would reach the tools as a
      # Session with no cwd to resolve against.
      def session(worker_env) = Lain::Session.new(worker_env: worker_env || WorkerEnv.default)
    end
  end
end
