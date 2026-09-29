# frozen_string_literal: true

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

  describe "::NONE" do
    it "answers nil for everything" do
      expect(described_class::NONE.path_for(pending("read_file", { "path" => ".env.local" }))).to be_nil
    end
  end
end
