# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::Bash do
  subject(:tool) { described_class.new }

  let(:channel) { RecordingChannel.new }

  def invocation(tool_use_id: "tu_1")
    Lain::Tool::Invocation.new(tool_use_id:, channel:)
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("bash")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # Tier 3: a String command goes through `sh -c`, and the model fully
  # controls it. Handler::Approving gates on exactly this flag.
  it "is gated by approval, being tier 3" do
    expect(tool.requires_approval?).to be(true)
  end

  it "runs a command and captures its stdout" do
    result = tool.call({ command: "echo hello" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 0")
    expect(result.content).to include("hello")
  end

  it "captures stderr alongside stdout" do
    result = tool.call({ command: "echo oops 1>&2" }, invocation)
    expect(result.content).to include("oops")
  end

  it "reports a nonzero exit status in the content, not as is_error" do
    # A nonzero exit is often exactly what the model asked to observe (grep
    # with no matches); the tool ran correctly, so this is not a tool failure.
    result = tool.call({ command: "exit 3" }, invocation)
    expect(result).to be_ok
    expect(result.content).to include("exit status: 3")
  end

  it "runs in the given cwd" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "marker.txt"), "here")
      result = tool.call({ command: "ls", cwd: dir }, invocation)
      expect(result.content).to include("marker.txt")
    end
  end

  it "kills a command that runs past its timeout" do
    result = tool.call({ command: "sleep 5", timeout: 1 }, invocation)
    expect(result).to be_error
    expect(result.content).to match(/timed out/)
  end

  describe "attributed live streaming" do
    it "emits stdout bytes as Event::ToolOutput carrying the invocation's tool_use_id and stream" do
      tool.call({ command: "echo from_stdout" }, invocation(tool_use_id: "tu_abc"))

      stdout_events = channel.events.select { |e| e.stream == :stdout }
      expect(stdout_events).not_to be_empty
      expect(stdout_events).to all(be_a(Lain::Event::ToolOutput))
      expect(stdout_events).to all(have_attributes(tool_use_id: "tu_abc"))
      expect(stdout_events.map(&:bytes).join).to include("from_stdout")
    end

    it "emits stderr bytes on the :stderr stream, distinct from stdout" do
      tool.call({ command: "echo to_err 1>&2" }, invocation(tool_use_id: "tu_xyz"))

      stderr_events = channel.events.select { |e| e.stream == :stderr }
      expect(stderr_events).not_to be_empty
      expect(stderr_events).to all(have_attributes(tool_use_id: "tu_xyz"))
      expect(stderr_events.map(&:bytes).join).to include("to_err")
    end
  end

  it "does nothing observable when no channel is injected (Null Object default)" do
    bare = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect { tool.call({ command: "echo quiet" }, bare) }.not_to raise_error
  end
end
