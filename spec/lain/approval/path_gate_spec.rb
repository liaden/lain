# frozen_string_literal: true

require "async"
require "tmpdir"

# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module PathGateSpecSupport
  # Answers through the real {Lain::Oracle::SecretRead.definition}, approving
  # with confidence, and keeps every question it was asked.
  class ApprovingOracle
    attr_reader :asks

    def initialize
      @definition = Lain::Oracle::SecretRead.definition
      @asks = []
    end

    def ask(inputs = {})
      @asks << inputs
      @definition.answer("verdict" => "approve", "confidence" => 0.95)
    end
  end
end

RSpec.describe Lain::Approval::PathGate do
  let(:sensitivity) { Lain::Sensitivity.new(home: "/home/tester", cwd: "/home/tester/project", rules: Lain::Sensitivity::Rules.empty) }
  let(:gate) { described_class.new(Lain::Sensitivity::Policy.new(sensitivity:)) }

  def pending(tool, input)
    effect = Struct.new(:name, :input, :tool_use_id).new(tool, input, "tu_1")
    Lain::Approval::Queue::Pending.new(effect:, requester: "agent", clock: -> { 0.0 })
  end

  describe "#path_for" do
    it "names the path of a gated read" do
      expect(gate.path_for(pending("read_file", { "path" => ".env.local" }))).to eq(".env.local")
    end

    it "answers nil for an ordinary path" do
      expect(gate.path_for(pending("read_file", { "path" => "lib/lain.rb" }))).to be_nil
    end

    it "answers nil for a denied path, which is refused before anything parks" do
      expect(gate.path_for(pending("read_file", { "path" => ".netrc" }))).to be_nil
    end

    it "answers nil for a tool that names no path" do
      expect(gate.path_for(pending("bash", { "command" => "cat .env" }))).to be_nil
    end

    %w[glob grep list_files ast_search file_symbols].each do |tool|
      it "names the path of a gated #{tool}" do
        expect(gate.path_for(pending(tool, { "path" => ".env.local" }))).to eq(".env.local")
      end
    end

    # The oracle is shown a path and a tool, never the content or command, so
    # only a call that merely reads the path may be judged from it.
    it "answers nil for a write, an edit, and a bash whose cwd is gated" do
      calls = [pending("write_file", { "path" => ".env.local", "content" => "x" }),
               pending("edit_file", { "path" => ".env.local" }),
               pending("bash", { "cwd" => ".ssh", "command" => "rm -rf ~" })]

      expect(calls.map { |call| gate.path_for(call) }).to all(be_nil)
    end

    it "answers nil when the path is not a String" do
      expect(gate.path_for(pending("read_file", { "path" => 3 }))).to be_nil
    end
  end

  # The gate parked the call on where its path LANDS, so this must judge the
  # landing too, against the cwd the parked call resolved from; otherwise a
  # link to a gated file is handed to a surface that never sees the path.
  describe "a link to a gated file" do
    around do |example|
      Dir.mktmpdir("lain-path-gate") do |dir|
        @worker = File.realpath(dir)
        File.write(File.join(@worker, ".env.local"), "PLAIN=1\n")
        File.symlink(".env.local", File.join(@worker, "readme2.txt"))
        example.run
      end
    end

    let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @worker, env: {})) }
    let(:read) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "readme2.txt" }) }

    def park(surface)
      queue = Lain::Approval::Queue.new(journal: [], timeout: 0.5)
      Sync do |task|
        gated = task.async { queue.adjudicate(read, session) }
        pending = task.with_timeout(1) { queue.dequeue }
        [surface.claims?(pending), surface.sweep(queue), task.with_timeout(2) { gated.wait }].values_at(0, 2)
      ensure
        gated&.stop
      end
    end

    it "is claimed by the secret surface, which asks the oracle about the link and settles it" do
      oracle = PathGateSpecSupport::ApprovingOracle.new
      surface = Lain::Approval::SecretSurface.new(oracle:, threshold: 0.9, journal: [], path_gate: gate)

      claimed, settled = park(surface)

      expect(claimed).to be(true)
      landing = File.join(@worker, ".env.local")
      expect(oracle.asks).to eq([{ path: "readme2.txt -> #{landing}".inspect, tool: "read_file", region_count: "0" }])
      expect([settled.approved?, settled.surface]).to eq([true, Lain::Approval::SecretSurface::SURFACE])
    end
  end

  describe "::NONE" do
    it "answers nil for everything" do
      expect(described_class::NONE.path_for(pending("read_file", { "path" => ".env.local" }))).to be_nil
    end
  end
end
