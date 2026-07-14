# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::EditFile do
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
    expect(tool.name).to eq("edit_file")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is a direct-Ruby, no-subprocess tool and is not gated by approval" do
    expect(tool.requires_approval?).to be(false)
  end

  describe "AC: writing blind is refused loudly" do
    it "raises ContractViolation when the session never read the path" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new

      expect do
        tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))
      end.to raise_error(Lain::Tool::ContractViolation, /never read/)

      expect(File.read(path)).to eq("hello world")
    end

    it "runs through Handler::Live and the model receives an error result naming the unmet contract" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      toolset = Lain::Toolset.new([tool])
      live = Lain::Handler::Live.new(toolset:)
      effect = Lain::Effect::ToolCall.new(
        tool_use_id: "tu_1", name: "edit_file",
        input: { path:, old_string: "hello", new_string: "goodbye" }
      )

      result = live.call(effect, session)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/never read/)
      expect(File.read(path)).to eq("hello world")
    end

    it "is fail-closed against a Session::Null (bare wiring) context" do
      path = write("hello.txt", "hello world")
      invocation = invocation_with(Lain::Session::Null.instance)

      expect do
        tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation)
      end.to raise_error(Lain::Tool::ContractViolation)
    end

    it "is fail-closed when the tool is called with no invocation context at all" do
      path = write("hello.txt", "hello world")

      expect do
        tool.call({ path:, old_string: "hello", new_string: "goodbye" })
      end.to raise_error(Lain::Tool::ContractViolation)
    end
  end

  describe "AC: a unique replacement lands" do
    it "replaces old_string with new_string when the path was read this session" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))

      expect(result).to have_attributes(is_error: false)
      expect(File.read(path)).to eq("goodbye world")
    end

    it "re-records the path in the read-set on a successful edit" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path)

      tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "treats old_string literally, not as a regexp" do
      path = write("hello.txt", "a.b price")
      session = Lain::Session.new
      session.record_read(path)

      tool.call({ path:, old_string: "a.b", new_string: "MATCHED" }, invocation_with(session))

      expect(File.read(path)).to eq("MATCHED price")
    end

    it "does not treat new_string's backslash sequences as sub back-references" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path)

      tool.call({ path:, old_string: "hello", new_string: '\1 literally' }, invocation_with(session))

      expect(File.read(path)).to eq('\1 literally world')
    end

    it "honors path-spelling-insensitive read tracking (T11 normalization)" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(File.join(tmpdir, ".", "hello.txt"))

      result = tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))

      expect(result.is_error).to be(false)
    end
  end

  describe "AC: ambiguity is an error, not a guess" do
    it "errors naming zero occurrences and leaves the file unchanged" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "missing", new_string: "x" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/0/)
      expect(File.read(path)).to eq("hello world")
    end

    it "errors naming multiple occurrences and leaves the file unchanged" do
      path = write("hello.txt", "hello hello world")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "hello", new_string: "x" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/2/)
      expect(File.read(path)).to eq("hello hello world")
    end

    it "counts overlapping occurrences as ambiguous, not unique" do
      path = write("hello.txt", "aaa")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "aa", new_string: "b" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to match(/2/)
      expect(File.read(path)).to eq("aaa")
    end

    it "does not re-record the read on an ambiguous, refused edit" do
      path = write("hello.txt", "hello hello world")
      other = write("other.txt", "solo")
      session = Lain::Session.new
      session.record_read(path)

      tool.call({ path:, old_string: "hello", new_string: "x" }, invocation_with(session))

      expect(session.read?(other)).to be(false)
    end
  end

  describe "problems reported as an error Result, not a raise" do
    it "reports a missing file" do
      session = Lain::Session.new
      missing = File.join(tmpdir, "nope.txt")
      session.record_read(missing)

      result = tool.call({ path: missing, old_string: "a", new_string: "b" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
    end
  end
end
