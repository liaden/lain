# frozen_string_literal: true

require "tmpdir"

# Seam tests: each unit above was specced by itself, and nobody specced the joint.
# These drive REAL tools through the REAL loop, because the correctness gates are
# claims about what happens when those two meet -- a fixture tool proves the loop,
# not the tools, and a bare tool spec proves the tool, not the loop.
RSpec.describe "tools x Agent loop" do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:channel) { RecordingChannel.new }

  around do |example|
    Dir.mktmpdir("lain-seam") do |dir|
      @dir = dir
      example.run
    end
  end

  attr_reader :dir

  def agent(toolset, responses, handler:)
    Lain::Agent.new(
      provider: Lain::Provider::Mock.new(responses: Array(responses)),
      toolset: toolset,
      context: context,
      handler: handler
    )
  end

  # Spec-local vocabulary over the shared builders: a seam example reads as
  # "the model used a tool, then settled".
  def tool_use(id, name, input) = tool_response([id, name, input], thinking: "considering")
  def settled(text = "done") = text_response(text)

  # The user turn holding tool_results is the one gate 2 is about. `Turn#role` is a
  # frozen String, not a Symbol -- see Turn's `-role.to_s`, which is what keeps
  # `Ractor.shareable?(turn)` true.
  def results_turn(agent)
    agent.timeline.to_a.reverse.find do |turn|
      turn.role == "user" && turn.content.first.key?("tool_use_id")
    end
  end

  describe "Tools::ReadFile through the loop" do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new]) }
    let(:handler) { Lain::Handler::Live.new(toolset: toolset, channel: channel) }

    it "reads a real file and returns its bytes to the model (gates 2, 4, 5)" do
      File.write(File.join(dir, "hello.txt"), "from disk\n")
      path = File.join(dir, "hello.txt")

      run = agent(toolset, [tool_use("tu_1", "read_file", { "path" => path }), settled], handler: handler)
      run.ask("read it")

      turn = results_turn(run)
      expect(turn.content.size).to eq(1)                       # gate 2: ONE user turn
      expect(turn.content.first["tool_use_id"]).to eq("tu_1")  # gate 4: ids pair up
      expect(turn.content.first["is_error"]).to be(false)
      expect(turn.content.first["content"]).to include("from disk")
    end

    it "reports a missing file as an error result and keeps going (gate 3)" do
      run = agent(toolset,
                  [tool_use("tu_1", "read_file", { "path" => File.join(dir, "nope.txt") }), settled],
                  handler: handler)

      expect { run.ask("read it") }.not_to raise_error
      expect(results_turn(run).content.first["is_error"]).to be(true)
      expect(run.state).to eq(:done)
    end

    it "hands the tool a parsed Hash, never a JSON string (gate 5)" do
      seen = nil
      spy = Class.new(Lain::Tools::ReadFile) do
        define_method(:perform) do |input, invocation|
          seen = input
          super(input, invocation)
        end
      end
      File.write(File.join(dir, "a.txt"), "x")
      set = Lain::Toolset.new([spy.new])

      agent(set, [tool_use("tu_1", "read_file", { "path" => File.join(dir, "a.txt") }), settled],
            handler: Lain::Handler::Live.new(toolset: set, channel: channel)).ask("go")

      expect(seen).not_to be_a(String)
      expect(seen.path).to eq(File.join(dir, "a.txt"))
    end
  end

  describe "Tools::Bash x Sink x Channel" do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
    let(:handler) do
      Lain::Handler::Approving.new(
        policy: Lain::Handler::Approving::ApproveAll.new,
        inner: Lain::Handler::Live.new(toolset: toolset, channel: channel)
      )
    end

    it "attributes live_stdout bytes to the tool_use_id that asked for them" do
      run = agent(toolset, [tool_use("tu_bash", "bash", { "command" => "echo seam" }), settled], handler: handler)
      run.ask("run it")

      emitted = channel.events.grep(Lain::Event::ToolOutput)
      expect(emitted).not_to be_empty
      expect(emitted.map(&:tool_use_id).uniq).to eq(["tu_bash"])
      expect(emitted.select { |e| e.stream == :stdout }.map(&:bytes).join).to include("seam")
    end

    it "separates stderr from stdout at the source" do
      run = agent(toolset, [tool_use("tu_e", "bash", { "command" => "echo out; echo err 1>&2" }), settled],
                  handler: handler)
      run.ask("run it")

      by_stream = channel.events.grep(Lain::Event::ToolOutput).group_by(&:stream)
      expect(by_stream[:stdout].map(&:bytes).join).to include("out")
      expect(by_stream[:stderr].map(&:bytes).join).to include("err")
    end
  end

  describe "Handler::Approving x ToolRunner" do
    let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
    let(:denying) do
      Lain::Handler::Approving.new(inner: Lain::Handler::Live.new(toolset: toolset, channel: channel))
    end

    it "turns a denied tier-3 call into is_error and lets the loop settle (gate 3)" do
      marker = File.join(dir, "pwned")
      run = agent(toolset, [tool_use("tu_x", "bash", { "command" => "touch #{marker}" }), settled],
                  handler: denying)

      expect { run.ask("do it") }.not_to raise_error
      expect(results_turn(run).content.first["is_error"]).to be(true)
      expect(run.state).to eq(:done)
      expect(File.exist?(marker)).to be(false), "a denied command must not run"
    end

    it "does not gate a tier-1 tool, which needs no approval" do
      File.write(File.join(dir, "ok.txt"), "readable")
      set = Lain::Toolset.new([Lain::Tools::ReadFile.new])
      # The SAME DenyAll default that refuses bash above. read_file still runs,
      # because the gate asks the tool its tier rather than gating every call.
      gate = Lain::Handler::Approving.new(inner: Lain::Handler::Live.new(toolset: set, channel: channel))

      run = agent(set, [tool_use("tu_r", "read_file", { "path" => File.join(dir, "ok.txt") }), settled],
                  handler: gate)
      run.ask("read")

      result = results_turn(run).content.first
      expect(result["is_error"]).to be(false)
      expect(result["content"]).to include("readable")
    end
  end
end
