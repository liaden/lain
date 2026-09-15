# frozen_string_literal: true

require "tmpdir"

# How a bench agent is WIRED. Its own file because it is what BOTH
# agent-construction sites default to: the recorder-sharing, the guard stack and
# the write/read partition below are properties of the WIRING rather than of
# either caller, and a claim asserted inside one caller's spec is a claim the
# other one can quietly stop honouring.
RSpec.describe Lain::Bench::Harness do
  let(:journal) { Lain::Channel.new }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:worker_env) { Lain::WorkerEnv.default }

  describe "the capabilities" do
    it "builds the chat's own capability floor rather than a second list" do
      floor = Lain::Toolset.new(Lain::CLI::Wiring::BaseTools.build(Lain::Memory::Recorder.new))

      expect(described_class::TOOLS.call(recorder:, journal:).digest).to eq(floor.digest)
    end

    it "builds an empty toolset on the named empty arm" do
      expect(described_class::NO_TOOLS.call(recorder:, journal:).to_a).to be_empty
    end

    # The two arms of one duck must fail equally loudly on a keyword neither
    # knows. NO_TOOLS used to swallow a `**`, one screen from the seam this
    # chunk removed one from.
    it "refuses an unknown keyword on both arms, not just the one that reads them" do
      expect { described_class::TOOLS.call(memory: recorder) }.to raise_error(ArgumentError)
      expect { described_class::NO_TOOLS.call(memory: recorder) }.to raise_error(ArgumentError)
    end
  end

  # The partition is what makes a tool added to the floor a RED example rather
  # than a silent promotion to "safe", which is the whole worth of naming a
  # write set at all.
  describe "the write partition" do
    let(:floor) { described_class::TOOLS.call(recorder:, journal:).names }

    it "covers every tool on the floor" do
      expect((described_class::WRITERS + described_class::READERS).sort).to eq(floor.sort)
    end

    it "classifies no tool twice" do
      expect(described_class::WRITERS & described_class::READERS).to be_empty
    end

    it "says the floor can write" do
      expect(described_class.writes?(described_class::TOOLS.call(recorder:, journal:))).to be(true)
    end

    it "says the empty arm cannot" do
      expect(described_class.writes?(described_class::NO_TOOLS.call(recorder:, journal:))).to be(false)
    end
  end

  describe "the reporting" do
    subject(:wiring) { described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env:) }

    # THE BLOCKER THIS FILE EXISTS FOR. CLAUDE.md: tier-1 read_file/grep/glob/
    # list_files do not check paths, "because the boundary is one place a reader
    # can find". A bench arm holds all four, so it gets the SAME place every
    # other run with no chat behind it gets -- asserted against that object's
    # own answer rather than against a list retyped here, which is the only
    # assertion a later tightening of `detached` cannot drift away from.
    it "guards a bench run exactly as an unchatted production run is guarded" do
      production = Lain::CLI::ToolGuard.detached(journal:).call(worker_env)

      expect(wiring.tool_middleware.to_a.map(&:class)).to eq(production.to_a.map(&:class))
    end

    it "holds all six guards and the gate, not the write refusal alone" do
      expect(wiring.tool_middleware.to_a.map(&:class)).to eq(
        [Lain::Middleware::ConfineToScope, Lain::Middleware::RefuseSecretWrites, Lain::Middleware::RedactSecretReads,
         Lain::Middleware::WithholdSecretPaths, Lain::Middleware::GuardTestLayout,
         Lain::Middleware::WithholdAutomaticOutput, Lain::Middleware::Sensitivity, Lain::Middleware::Gate]
      )
    end

    # A release ledger shared across arms is the same cross-arm contamination
    # the per-spawn recorder exists to prevent, so the board is per agent where
    # Consolidation memoizes one for its whole run.
    it "builds a fresh board per agent" do
      other = described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env:)
      ledger = ->(wired) { wired.tool_middleware.to_a.grep(Lain::Middleware::RedactSecretReads).first.ledger }

      expect(ledger.call(wiring)).not_to be(ledger.call(other))
    end

    it "records every outbound request, innermost" do
      expect(wiring.model_middleware.to_a).to include(an_instance_of(Lain::Middleware::JournalRequests))
    end

    it "pairs each turn with the memory root in force when it rendered" do
      expect(wiring.journal).to be_a(Lain::Memory::JournalMemoryRoot)
    end

    # Reachable, and only by a caller that supplies its own source -- see the
    # constant's own comment for why nothing here can honestly default it.
    it "leaves the per-turn context source injectable and Null by default" do
      expect(wiring.pipeline_source).to be(Lain::Agent::PipelineSource::Null)
    end
  end

  # The guard stack over a REAL tier-1 read, so the claim is about what the
  # boundary does to a credential rather than about which classes are in a list.
  describe "a tier-one read through the guards", :seam do
    let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }

    around { |example| Dir.mktmpdir { |made| @dir = made and example.run } }

    def read(path)
      env = Lain::WorkerEnv.new(cwd: @dir, env: {})
      stack = described_class::INSTRUMENTATION.call(journal:, recorder:, worker_env: env).tool_middleware
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => path })
      session = Lain::Session.new(worker_env: env)
      stack.call({ effect:, tool: Lain::Tools::ReadFile.new, context: session }) do |inner|
        invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: inner.fetch(:context))
        inner.merge(result: Lain::Tools::ReadFile.new.call(inner.fetch(:effect).input, invocation))
      end
    end

    # THE BLOCKER, AS BEHAVIOUR. Before this, the harness wired
    # RefuseSecretWrites alone, so a bench arm holding all four tier-1 read
    # tools could read a credential straight into the model's context -- and
    # from there, through JournalRequests, into the recorded session file on
    # disk that `bench variance` loads and an operator shares. The mask is what
    # means those bytes never exist above the middleware at all.
    it "masks a credential out of a tier-one read before it can reach a Request" do
      path = File.join(@dir, ".env").tap { |file| File.write(file, "API_KEY=#{api_key}\n") }

      content = read(path).fetch(:result).content

      expect(content).not_to include(api_key)
      expect(content).to include("API_KEY=", "<redacted:1>")
    end

    it "records the masking, so the run can say what it withheld" do
      path = File.join(@dir, ".env").tap { |file| File.write(file, "API_KEY=#{api_key}\n") }
      read(path)

      expect(journal.drain.grep(Lain::Telemetry::ReadRedacted)).not_to be_empty
    end

    # The other half: guarding must not turn an ordinary read into a refusal,
    # or a bench arm would score zero for a reason nobody could see.
    it "leaves an ordinary read untouched" do
      path = File.join(@dir, "notes.txt").tap { |file| File.write(file, "ordinary\n") }

      expect(read(path).fetch(:result).content).to include("ordinary")
    end
  end
end
