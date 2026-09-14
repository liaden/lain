# frozen_string_literal: true

# A toolset that mints a NEW tool object on every lookup -- the shape a
# `/mode` flip gives {Lain::CLI::Switchboard::LiveToolset} between two reads.
# Kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module HandlerSpecSupport
  class MintingToolset
    def initialize(&mint)
      @mint = mint
    end

    def fetch(name) = @mint.call(name)
    def include?(_name) = true
    def select = []
  end

  # Gated, so the gate really judges it; each instance records itself when it
  # is judged and when it runs, into logs the whole mint shares.
  class JudgedTool < Lain::Tool
    def initialize(judged:, ran:)
      super()
      @judged = judged
      @ran = ran
    end

    def name = "probe"
    def description = "records the object that was judged and the object that ran"
    def input_schema = { type: :object, properties: {}, required: [] }

    def requires_approval?
      @judged << self
      true
    end

    def perform(_input, _invocation)
      @ran << self
      Lain::Tool::Result.ok("ran")
    end
  end
end

RSpec.describe Lain::Effect::Handler do
  def tool(tool_name, &body)
    Class.new(Lain::Tool) do
      define_method(:name) { tool_name.to_s }
      define_method(:description) { "the #{tool_name} tool" }
      def input_schema = { type: :object, properties: { text: { type: :string } }, required: [] }
      define_method(:perform, &body)
    end.new
  end

  let(:echo) { tool(:echo) { |input, _context| Lain::Tool::Result.ok(input.fetch(:text, "")) } }
  let(:toolset) { Lain::Toolset.new([echo]) }

  def tool_call(name, input = {}, id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name:, input:)
  end

  def env_for(effect, tool: echo, context: nil) = { effect:, tool:, context: }

  # The base names the one message a subclass must answer, so a handler that
  # forgot to write it fails with a sentence rather than a NoMethodError.
  it "refuses loudly to interpret anything itself" do
    expect { described_class.new.call(env_for(tool_call("echo"))) }
      .to raise_error(described_class::UnhandledEffect, /Lain::Effect::Handler does not interpret/)
  end

  describe Lain::Effect::Handler::Live do
    subject(:handler) { described_class.new }

    it "runs the tool the env carries" do
      expect(handler.call(env_for(tool_call("echo", { text: "hi" })))).to eq(Lain::Tool::Result.ok("hi"))
    end

    it "holds no toolset of its own to resolve a name against" do
      expect { described_class.new(toolset:) }.to raise_error(ArgumentError, /unknown keyword: :toolset/)
    end

    describe "the tool receives a Tool::Invocation, not the bare context" do
      # An accessor on the tool itself, not a closure over a `let`: define_method
      # rebinds `self` to the tool instance when #perform runs, so a captured
      # local from the surrounding example is not reliably reachable there.
      let(:capturing_class) do
        Class.new(Lain::Tool) do
          attr_reader :captured

          def name = "capturing"
          def description = "captures its invocation"
          def input_schema = { type: :object, properties: {}, required: [] }

          def perform(_input, invocation)
            @captured = invocation
            Lain::Tool::Result.ok("captured")
          end
        end
      end
      let(:capturing) { capturing_class.new }

      it "builds an Invocation carrying the effect's tool_use_id and the caller's context" do
        described_class.new.call(env_for(tool_call("capturing", {}, id: "tu_42"), tool: capturing,
                                                                                  context: "raw context"))

        expect(capturing.captured).to be_a(Lain::Tool::Invocation)
        expect(capturing.captured).to have_attributes(tool_use_id: "tu_42", context: "raw context")
      end

      it "defaults the channel to a Null Object when none is injected" do
        described_class.new.call(env_for(tool_call("capturing"), tool: capturing))
        expect(capturing.captured.channel).to be_a(Lain::Channel::Null)
      end

      it "threads the handler's injected channel through" do
        channel = RecordingChannel.new
        described_class.new(channel:).call(env_for(tool_call("capturing"), tool: capturing))
        expect(capturing.captured.channel).to be(channel)
      end
    end

    describe "correctness gate 3 -- a failure never raises past the loop" do
      it "turns a raising tool into an error Result" do
        boom = tool(:boom) { |_input, _context| raise "kaboom" }
        result = handler.call(env_for(tool_call("boom"), tool: boom))
        expect(result).to have_attributes(is_error: true)
        expect(result.content).to include("kaboom")
      end

      # AC: "an unexpected error still reaches the model as a usable sentence" --
      # the message survives; the raising class (RuntimeError, here standing in
      # for any error outside the harness's own ContractViolation/InvalidInput
      # vocabulary) does not leak into the wire text.
      it "carries an unexpected error's message but names no Ruby class" do
        boom = tool(:boom) { |_input, _context| raise "kaboom" }
        result = handler.call(env_for(tool_call("boom"), tool: boom))
        expect(result.content).to eq("kaboom")
        expect(result.content).not_to include("RuntimeError")
      end

      it "turns an invalid input into an error Result rather than dispatching" do
        strict = tool(:strict) { |_input, _context| Lain::Tool::Result.ok("ran") }
        allow(strict).to receive(:input_schema).and_return(
          { type: :object, properties: { text: { type: :string } }, required: [:text] }
        )
        expect(handler.call(env_for(tool_call("strict", {}), tool: strict)))
          .to have_attributes(is_error: true, content: /text is required/)
      end

      # AC: "an invalid input refusal is equally clean" -- no Ruby class named.
      it "does not leak the InvalidInput class name into the refusal" do
        strict = tool(:strict) { |_input, _context| Lain::Tool::Result.ok("ran") }
        allow(strict).to receive(:input_schema).and_return(
          { type: :object, properties: { text: { type: :string } }, required: [:text] }
        )
        result = handler.call(env_for(tool_call("strict", {}), tool: strict))
        expect(result.content).not_to include("InvalidInput")
      end
    end

    # The layer that turns a violation into a Result is the interpreter, and a
    # contract's wording is what the model reads to decide its next call. So the
    # message is pinned against the violation the tool ITSELF raises, driven the
    # whole way through the runner a turn uses: a rewording anywhere between
    # the two is a change to what a user sees.
    describe "a contract violation's message reaches the user unchanged" do
      let(:contracted) do
        Class.new(Lain::Tool) do
          def name = "contracted"
          def description = "d"
          requires("never") { |_input, _context| false }
          def perform(_input, _context) = Lain::Tool::Result.ok("unreachable")
        end.new
      end

      def violation_message
        contracted.call({}, Lain::Tool::Invocation.new(context: nil))
      rescue Lain::Tool::ContractViolation => e
        e.message
      end

      it "answers with an error carrying the violation's own message" do
        result = dispatch_call("contracted", toolset: Lain::Toolset.new([contracted]))

        expect(violation_message).to include("precondition failed")
        expect(result).to have_attributes(is_error: true, content: violation_message)
      end

      it "does not leak the ContractViolation class name into the refusal" do
        expect(dispatch_call("contracted", toolset: Lain::Toolset.new([contracted])).content)
          .not_to include("ContractViolation")
      end
    end

    it "unwraps an Approval and runs the inner effect (executor of last resort)" do
      gated = Lain::Effect::Approval.new(effect: tool_call("echo", { text: "yo" }))
      expect(handler.call(env_for(gated))).to eq(Lain::Tool::Result.ok("yo"))
    end

    it "refuses loudly an effect that is not a tool call, rather than dropping it" do
      declined = Lain::Effect::ModelCall.new(request: :req)
      expect { handler.call(env_for(declined)) }.to raise_error(Lain::Effect::Handler::UnhandledEffect)
    end
  end

  describe "an effect naming no tool the toolset holds" do
    it "is refused, naming the tool" do
      result = dispatch_call("ghost", toolset:)

      expect(result).to have_attributes(is_error: true, content: 'no tool named "ghost" is available')
    end

    it "is refused the same way behind a gate, which does not ask about a call nothing will run" do
      policy = instance_double(Lain::Middleware::Gate::DenyAll)
      gate = Lain::Middleware::Gate.new(policy:)

      expect(dispatch_call("ghost", toolset:, layers: [gate]))
        .to have_attributes(is_error: true, content: 'no tool named "ghost" is available')
    end
  end

  # Authorization and possession read ONE object: the tool the gate judged is
  # the tool that runs, or nothing runs. A set that answers the same object on
  # every read runs it; a set that answers a NEW object between the gate's read
  # and the interpreter's -- what a `/mode` flip does to the live toolset -- is
  # refused, where two independent lookups would have run the object nobody
  # judged.
  describe "the gate and the interpreter judge the same tool" do
    def judging(toolset_for)
      judged = []
      ran = []
      toolset = toolset_for.call(-> { HandlerSpecSupport::JudgedTool.new(judged:, ran:) })
      gate = Lain::Middleware::Gate.new(policy: Lain::Middleware::Gate::ApproveAll.new)
      [dispatch_call("probe", toolset:, layers: [gate]), judged, ran]
    end

    it "runs the very object the gate judged" do
      result, judged, ran = judging(->(mint) { Lain::Toolset.new([mint.call]) })

      expect(result).to eq(Lain::Tool::Result.ok("ran"))
      expect(judged.size).to eq(1)
      expect(ran.size).to eq(1)
      expect(ran.first).to be(judged.first)
    end

    # The runner checks the call's OWN name against `:tool`, so a layer placed
    # after the gate that swaps the tool is refused rather than obeyed. Position
    # still matters for the effect's input, which this test cannot see.
    it "refuses a tool a later layer swapped into the env" do
      ran = []
      probe = Class.new(HandlerSpecSupport::JudgedTool) { def requires_approval? = false }
      swapped = probe.new(judged: [], ran:)
      swapper = Class.new(Lain::Middleware::Base) do
        define_method(:call) { |env, &app| downstream(env.merge(tool: swapped), &app) }
      end.new
      toolset = Lain::Toolset.new([probe.new(judged: [], ran:)])

      expect(dispatch_call("probe", toolset:, layers: [swapper]))
        .to eq(Lain::Tool::Result.error('no tool named "probe" is available'))
      expect(ran).to be_empty
    end

    # An unheld name is the case with no tool object to compare: the stand-in
    # for it is a value, so what must match is that value, and not merely
    # "something else that is not held either".
    it "refuses a not-held stand-in a later layer swapped in for an unheld name" do
      rogue = Class.new do
        attr_reader :runs

        def initialize = (@runs = [])
        def held? = false
        def parallel_safe? = false
        def requires_approval? = false

        def call(_input, _invocation)
          @runs << :ran
          Lain::Tool::Result.ok("rogue ran")
        end
      end.new
      swapper = Class.new(Lain::Middleware::Base) do
        define_method(:call) { |env, &app| downstream(env.merge(tool: rogue), &app) }
      end.new

      expect(dispatch_call("ghost", toolset:, layers: [Lain::Middleware::Gate.new, swapper]))
        .to eq(Lain::Tool::Result.error('no tool named "ghost" is available'))
      expect(rogue.runs).to be_empty
    end

    it "runs nothing when the name no longer resolves to the object the gate judged" do
      result, judged, ran = judging(->(mint) { HandlerSpecSupport::MintingToolset.new { mint.call } })

      expect(result).to eq(Lain::Tool::Result.error('no tool named "probe" is available'))
      expect(judged.size).to eq(1)
      expect(ran).to be_empty
    end
  end

  describe Lain::Effect::Handler::Mock do
    def mocked(mock, effect) = mock.call({ effect:, context: nil })

    it "resolves by tool name" do
      mock = described_class.new(results: { "echo" => Lain::Tool::Result.ok("canned") })
      expect(mocked(mock, tool_call("echo"))).to eq(Lain::Tool::Result.ok("canned"))
    end

    it "resolves by tool_use_id" do
      mock = described_class.new(results: { "tu_42" => Lain::Tool::Result.ok("by id") })
      expect(mocked(mock, tool_call("echo", {}, id: "tu_42"))).to eq(Lain::Tool::Result.ok("by id"))
    end

    it "coerces a bare String canned value into a successful Result" do
      mock = described_class.new(results: { "echo" => "just text" })
      expect(mocked(mock, tool_call("echo"))).to eq(Lain::Tool::Result.ok("just text"))
    end

    it "lets a block resolve results from the effect" do
      mock = described_class.new { |effect, _context| Lain::Tool::Result.ok(effect.input[:text].upcase) }
      expect(mocked(mock, tool_call("echo", { text: "loud" }))).to eq(Lain::Tool::Result.ok("LOUD"))
    end

    it "falls back to an error Result when nothing matches" do
      expect(mocked(described_class.new, tool_call("echo"))).to have_attributes(is_error: true)
    end

    it "unwraps an Approval to the call it wraps" do
      mock = described_class.new(results: { "echo" => "unwrapped" })
      expect(mocked(mock, Lain::Effect::Approval.new(effect: tool_call("echo")))).to eq(Lain::Tool::Result.ok("unwrapped"))
    end
  end
end
