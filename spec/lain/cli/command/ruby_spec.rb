# frozen_string_literal: true

require "tmpdir"

# T22: /ruby's three arities over the live conversation's InspectionBinding.
# The expression and file arities are pinned behaviorally (they return the
# rendered inspect). The bare/console arity opens IRB and OWNS the terminal
# while live, so it is not driven here: the console launcher is injected and
# the spec asserts the wiring -- that a console is opened over an
# InspectionBinding built from the env -- rather than a live REPL. The real
# launcher (Ruby::Console) is asserted at construction level too: it builds an
# embedded IRB over the binding using a non-Reline Stdio input method, so IRB's
# line editor never nests a second Reline inside the chat's.
RSpec.describe Lain::CLI::Command::Ruby do
  let(:timeline) { double("timeline", head: "blake3:abc") }
  let(:session) { double("session") }
  let(:supervisor) { double("supervisor") }
  let(:status) { double("status") }
  let(:agent) { double("agent", timeline:, session:) }
  let(:env) { double("env", agent:, supervisor:, status:) }

  it "is the /ruby command" do
    expect(described_class.new.name).to eq("ruby")
  end

  describe "expression arity" do
    subject(:command) { described_class.new }

    it "renders the expression's inspect inline" do
      expect(command.call("timeline.head", env)).to eq('"blake3:abc"')
    end

    it "renders the error rather than crashing the repl on a bad message" do
      result = command.call("timeline.head.no_such_method", env)

      expect(result).to match(/NoMethodError/)
    end

    it "renders the error rather than crashing the repl on a syntax error" do
      result = command.call("timeline.", env)

      expect(result).to match(/SyntaxError/)
    end
  end

  describe "file arity" do
    subject(:command) { described_class.new }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    it "runs the named file against the same binding and renders its value" do
      path = File.join(@dir, "probe.rb")
      File.write(path, "timeline.head\n")

      expect(command.call(path, env)).to eq('"blake3:abc"')
    end
  end

  describe "console arity (bare)" do
    let(:console) { spy("console") }
    subject(:command) { described_class.new(console:) }

    it "opens a console over an InspectionBinding built from the env, then returns to chat" do
      result = command.call("", env)

      expect(console).to have_received(:open) do |inspection|
        expect(inspection).to be_a(Lain::CLI::InspectionBinding)
        expect(inspection.context.eval("timeline")).to be(timeline)
        expect(inspection.context.eval("supervisor")).to be(supervisor)
      end
      expect(result).to be_a(String)
    end

    it "defaults its console to the real embedded-IRB launcher" do
      expect(described_class.new.console).to be_a(described_class::Console)
    end
  end

  describe Lain::CLI::Command::Ruby::Console do
    subject(:console) { described_class.new }

    let(:inspection) do
      Lain::CLI::InspectionBinding.new(timeline: :tl, session: :s, supervisor: :sup, status: :st)
    end

    it "builds an embedded IRB over the binding using a non-Reline Stdio input method" do
      input_method = instance_double(IRB::StdioInputMethod)
      fake_irb = instance_double(IRB::Irb, run: nil)
      allow(IRB).to receive_messages(setup: nil, initialized?: true)
      allow(IRB::StdioInputMethod).to receive(:new).and_return(input_method)
      allow(IRB::Irb).to receive(:new).and_return(fake_irb)

      console.open(inspection)

      expect(IRB::Irb).to have_received(:new) do |workspace, io|
        expect(workspace).to be_a(IRB::WorkSpace)
        expect(workspace.binding.eval("timeline")).to eq(:tl)
        expect(io).to be(input_method)
      end
      expect(fake_irb).to have_received(:run)
    end
  end
end
