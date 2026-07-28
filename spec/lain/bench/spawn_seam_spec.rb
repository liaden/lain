# frozen_string_literal: true

# B1 (chunk-bench-arms-subcommand): the LIVE spawn seam -- the sibling of
# ArmSweep::Recordings#seam, whose provider is replayed from a committed
# fixture. This one resolves its provider through the SAME Lain::CLI::Backend
# `bench record` resolves `--provider` through, so a provider name means one
# thing across every bench command.
#
# Every example here injects a Provider::Mock: the seam's whole point is that it
# CAN build a money-spending client, so no spec is allowed to let it (the one
# example that skips the injection names a provider that is refused before any
# client is built).
RSpec.describe Lain::Bench::SpawnSeam do
  let(:provider) do
    Lain::Provider::Mock.new(
      responses: [text_response("done", model: "claude-sonnet-4",
                                        usage: Lain::Usage.new(input_tokens: 100, output_tokens: 20))]
    )
  end

  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }

  subject(:seam) { described_class.new(provider:, toolset:) }

  def journal = Lain::Channel.new

  # The bytes an agent would actually send. Two agents built by one seam must
  # render the same prefix -- that identity IS the prompt cache's premise -- so
  # this, not the Context's object identity, is the invariant worth asserting.
  def prefix(agent) = agent.context.render(timeline: agent.timeline, toolset: agent.toolset).cache_payload

  # The base Arm duck: `call(journal:, **spawn_opts) -> Agent`, a FRESH agent per
  # call because every provider -- Mock and live alike -- is stateful.
  describe "#call" do
    it "hands back a distinct agent per call" do
      expect(seam.call(journal:)).not_to be(seam.call(journal:))
    end

    # Asserted on UN-ASKED agents and on the STORE, because #ask returns a new
    # handle: a seam memoizing one shared root would still hand back two
    # different Timeline objects after one of them was driven, and an emptiness
    # check on the other would still pass. The store is what actually says the
    # two runs cannot see each other's turns.
    it "gives each agent its own timeline over its own store" do
      first = seam.call(journal:)
      second = seam.call(journal:)

      expect(first.timeline).not_to be(second.timeline)
      expect(first.timeline.store).not_to be(second.timeline.store)
    end

    it "keeps one run's turns out of another's store" do
      first = seam.call(journal:)
      second = seam.call(journal:)

      first.ask("hello")

      expect(second.timeline.to_a).to be_empty
      expect(second.timeline.store.size).to be_zero
    end

    # The capabilities B2 hands the arms through. Dropped, every arm still
    # completes and merely scores zero -- which a bench cannot tell apart from a
    # model that failed the task.
    it "gives every agent the injected toolset" do
      expect(seam.call(journal:).toolset).to be(toolset)
    end

    it "routes the agent's telemetry to the journal it was called with" do
      channel = journal
      seam.call(journal: channel).ask("hello")

      expect(channel.drain.grep(Lain::Telemetry::TurnUsage)).not_to be_empty
    end

    # The widened `**` tail every arm speaks: OrchestratorWorker passes
    # `base_timeline:` (a fresh root over the lead's store), DualLedger passes
    # `timeline:`, and an isolated arm passes the lease's `worker_env:`.
    it "roots the agent at a base timeline and carries a worker env into its session" do
      base = Lain::Timeline.empty(store: Lain::Store.new)
      worker_env = Lain::WorkerEnv.new(cwd: Dir.pwd, env: { "LAIN_ARM" => "worker-1" })

      agent = seam.call(journal:, base_timeline: base, worker_env:)

      expect(agent.timeline).to be(base)
      expect(agent.session.worker_env).to eq(worker_env)
    end

    it "roots the agent at an explicit timeline" do
      rooted = Lain::Timeline.empty(store: Lain::Store.new)
                             .commit(role: :user, content: [{ "type" => "text", "text" => "earlier" }])

      expect(seam.call(journal:, timeline: rooted).timeline.head).to eq(rooted.head)
    end

    # B10's adaptive router spawns with `model:`/`template:`; a fixed-arity seam
    # would reject those, so the tail is accepted and ignored rather than
    # crashing an arm this seam does not yet serve.
    it "accepts spawn-time options it does not use" do
      expect(seam.call(journal:, model: "claude-haiku-4", template: :sibling)).to be_a(Lain::Agent)
    end

    it "leaves an unisolated call on the process environment" do
      expect(seam.call(journal:).session.worker_env).to eq(Lain::WorkerEnv.default)
    end

    it "sends the workspace it was called with, and an empty one otherwise" do
      workspace = Lain::Workspace.new(reminders: ["the arm's brief"])

      expect(seam.call(journal:, workspace:).workspace).to be(workspace)
      expect(seam.call(journal:).workspace).to be(Lain::Workspace.empty)
    end
  end

  # The consumer's own duck rather than this spec's reading of it: the control
  # arm spawns through the seam, asks its task, and prices the run off the
  # journal the seam threaded into the agent.
  describe "driven by a real Arm" do
    it "satisfies the arm seam end to end" do
      grader = Lain::Grader::Fixture.new("settled") do |fixture|
        fixture.check("committed an assistant turn") { |timeline| timeline.to_a.map(&:role).include?("assistant") }
      end

      run = Lain::Arm::SingleThread.new(name: "control").run("do the task", spawn_seam: seam, grader:)

      expect(run.score).to eq(1.0)
      expect(run.total_tokens).to eq(120)
    end
  end

  # Resolution happens at construction, not at the first spawn: a name the
  # advertised set does not carry must be refused before any arm runs and before
  # any money is spent.
  describe "the provider name" do
    it "is refused by the CLI backend's own error when it is outside the advertised set" do
      expect { described_class.new(provider_name: "haiku") }
        .to raise_error(Lain::CLI::UnknownProvider, /haiku/)
    end

    it "names the advertised set in the refusal" do
      expect { described_class.new(provider_name: "haiku") }
        .to raise_error(Lain::CLI::UnknownProvider, /#{Regexp.escape(Lain::CLI::Backend::PROVIDERS.inspect)}/)
    end

    # Without this, a seam that never called Backend#provider at all -- handing
    # every live arm `Agent.new(provider: nil)` -- would pass this whole file:
    # the refusals above arrive from the Context's model resolution, not from
    # the provider's. The keyless gate is Backend's, and it fires only on the
    # path that actually builds a client, so it is the one assertion that says a
    # provider was resolved. No key is read, no client is built, nothing spends.
    it "resolves a real provider when none is injected, and is key-gated doing it" do
      with_env("ANTHROPIC_API_KEY" => nil) do
        expect { described_class.new }.to raise_error(Lain::CLI::Backend::MissingAPIKey, /ANTHROPIC_API_KEY/)
      end
    end

    # The limit of the refusal above, pinned rather than described: an injected
    # provider AND an explicit model reach neither Backend#provider nor its
    # model default, so the name is never validated. Production never injects,
    # so this is the specs' own case -- but it is a real hole in "resolution
    # happens at construction", and a silent one, so it is written down.
    it "is NOT validated when a provider object and a model are both given" do
      expect { described_class.new(provider:, provider_name: "haiku", model: "qwen3") }.not_to raise_error
    end
  end

  # The Context is the flags' other half: one Context for the whole seam, so
  # every agent it builds renders the same prefix (the prompt cache's premise)
  # and the sampler flags reach Request#extra exactly as `bench record`'s do.
  describe "the context" do
    it "carries the resolved model and the sampler flags to every agent" do
      seam = described_class.new(provider:, provider_name: "ollama", model: "qwen3", temperature: 0, seed: 7)

      context = seam.call(journal:).context

      expect(context.model).to eq("qwen3")
      expect(context.extra).to eq("temperature" => 0, "seed" => 7)
    end

    # The memo is right, but identity is not the rule -- CLI::Wiring builds
    # chat's children a fresh Context each -- so what is asserted is the rule
    # itself: two agents from one seam render the same prefix bytes.
    it "renders one identical prefix for every agent it builds" do
      expect(prefix(seam.call(journal:))).to eq(prefix(seam.call(journal:)))
    end

    it "renders the system prompt it was given rather than the project's slots" do
      seam = described_class.new(provider:, system: "you are an arm under comparison")

      expect(seam.call(journal:).context.system).to eq("you are an arm under comparison")
    end

    it "sizes the answer for a whole file body by default" do
      expect(seam.call(journal:).context.max_tokens).to eq(described_class::DEFAULT_MAX_TOKENS)
      expect(described_class::DEFAULT_MAX_TOKENS).to eq(4096)
    end

    it "takes an explicit ceiling over that default" do
      expect(described_class.new(provider:, max_tokens: 512).call(journal:).context.max_tokens).to eq(512)
    end
  end
end
