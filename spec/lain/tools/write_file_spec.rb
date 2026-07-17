# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::WriteFile do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def write(name, content)
    path = File.join(tmpdir, name)
    File.write(path, content)
    path
  end

  def invocation_with(session, tool_use_id: "tu_1")
    Lain::Tool::Invocation.new(tool_use_id:, context: session)
  end

  it "has a model-facing name and description" do
    expect(tool.name).to eq("write_file")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is a structured tier-1 tool and is not gated by approval" do
    expect(tool.requires_approval?).to be(false)
  end

  describe "AC: creating a brand-new file" do
    it "creates the file with the given content when the path does not exist" do
      path = File.join(tmpdir, "new.rb")
      session = Lain::Session.new

      result = tool.call({ path:, content: "x" }, invocation_with(session))

      expect(result).to have_attributes(is_error: false)
      expect(File.read(path)).to eq("x")
    end

    it "does not require a prior read for creation" do
      path = File.join(tmpdir, "new.rb")
      session = Lain::Session.new

      expect do
        tool.call({ path:, content: "x" }, invocation_with(session))
      end.not_to raise_error
    end

    # Review panel P8 (Schneeman, BLOCKER): a whole-file writer that cannot
    # produce an empty file, and fails by RAISING rather than by returning an
    # error Result, contradicts its own description ("creating it if it does
    # not exist"). content is a required KEY in the wire schema -- the model
    # must still supply it -- but its VALUE is allowed to be blank.
    it "creates a zero-byte file when content is empty, without raising" do
      path = File.join(tmpdir, "empty.rb")
      session = Lain::Session.new

      result = nil
      expect do
        result = tool.call({ path:, content: "" }, invocation_with(session))
      end.not_to raise_error

      expect(result).to have_attributes(is_error: false)
      expect(File.read(path)).to eq("")
      expect(File.size(path)).to eq(0)
    end

    it "records the new path in the read-set and write-set on success" do
      path = File.join(tmpdir, "new.rb")
      session = Lain::Session.new

      tool.call({ path:, content: "x" }, invocation_with(session))

      expect(session.read?(path)).to be(true)
      expect(session.written?(path)).to be(true)
    end
  end

  describe "AC: overwriting an existing file requires it was read this session" do
    it "raises ContractViolation when the session never read the path" do
      path = write("existing.rb", "original")
      session = Lain::Session.new

      expect do
        tool.call({ path:, content: "y" }, invocation_with(session))
      end.to raise_error(Lain::Tool::ContractViolation, /never read/)

      expect(File.read(path)).to eq("original")
    end

    it "runs through Handler::Live and the model receives an error result naming the unmet contract" do
      path = write("existing.rb", "original")
      session = Lain::Session.new
      toolset = Lain::Toolset.new([tool])
      live = Lain::Effect::Handler::Live.new(toolset:)
      effect = Lain::Effect::ToolCall.new(
        tool_use_id: "tu_1", name: "write_file",
        input: { path:, content: "y" }
      )

      result = live.call(effect, session)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/never read/)
      expect(File.read(path)).to eq("original")
    end

    it "is fail-closed against a Session::Null (bare wiring) context" do
      path = write("existing.rb", "original")
      invocation = invocation_with(Lain::Session::Null.instance)

      expect do
        tool.call({ path:, content: "y" }, invocation)
      end.to raise_error(Lain::Tool::ContractViolation)
    end

    it "is fail-closed when the tool is called with no invocation context at all" do
      path = write("existing.rb", "original")

      expect do
        tool.call({ path:, content: "y" })
      end.to raise_error(Lain::Tool::ContractViolation)
    end

    it "overwrites when the path was read this session" do
      path = write("existing.rb", "original")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, content: "y" }, invocation_with(session))

      expect(result).to have_attributes(is_error: false)
      expect(File.read(path)).to eq("y")
    end

    it "re-records the path in the read-set and write-set on a successful overwrite" do
      path = write("existing.rb", "original")
      session = Lain::Session.new
      session.record_read(path)

      tool.call({ path:, content: "y" }, invocation_with(session))

      expect(session.read?(path)).to be(true)
      expect(session.written?(path)).to be(true)
    end

    it "honors path-spelling-insensitive read tracking (T11 normalization)" do
      path = write("existing.rb", "original")
      session = Lain::Session.new
      session.record_read(File.join(tmpdir, ".", "existing.rb"))

      result = tool.call({ path:, content: "y" }, invocation_with(session))

      expect(result.is_error).to be(false)
    end
  end

  describe "problems reported as an error Result, not a raise" do
    it "reports a write to an undreadable location" do
      session = Lain::Session.new
      missing_dir_path = File.join(tmpdir, "nosuchdir", "new.rb")

      result = tool.call({ path: missing_dir_path, content: "x" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
    end
  end
end
