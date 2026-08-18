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
      live = Lain::Effect::Handler::Live.new(toolset:)
      effect = Lain::Effect::ToolCall.new(
        tool_use_id: "tu_1", name: "edit_file",
        input: { path:, old_string: "hello", new_string: "goodbye" }
      )

      result = live.call(effect, session)

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("never read")
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

    it "honors path-spelling-insensitive read tracking" do
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
      expect(result.content).to include("0")
      expect(File.read(path)).to eq("hello world")
    end

    it "errors naming multiple occurrences and leaves the file unchanged" do
      path = write("hello.txt", "hello hello world")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "hello", new_string: "x" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("2")
      expect(File.read(path)).to eq("hello hello world")
    end

    it "counts overlapping occurrences as ambiguous, not unique" do
      path = write("hello.txt", "aaa")
      session = Lain::Session.new
      session.record_read(path)

      result = tool.call({ path:, old_string: "aa", new_string: "b" }, invocation_with(session))

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("2")
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

  # T3: a WINDOWED read is a third answer the session can give, and it had been
  # collapsed into "never read" -- a message that sends the model back to
  # re-read and be refused identically. Unlike the masked case, this one has a
  # remedy that actually works, because Lain::Session::ReadSet is monotone.
  describe "AC: a windowed read is refused by its own name" do
    it "refuses, naming the partial read rather than claiming the file was never read" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path, complete: false)

      expect do
        tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))
      end.to raise_error(Lain::Tool::ContractViolation, /window/)

      expect(File.read(path)).to eq("hello world")
    end

    it "does not reuse the never-read message" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path, complete: false)

      message = begin
        tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))
        nil
      rescue Lain::Tool::ContractViolation => e
        e.message
      end

      expect(message).not_to include("never read")
    end

    # The masked refusal is the NARROWER cause and must keep winning: a masked
    # read is also a partial one, so ordering it second would relabel every
    # masked file as a window and offer a remedy that does not exist.
    it "still names masking, not the window, when the read was masked" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path).record_masked_read(path)

      expect do
        tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))
      end.to raise_error(Lain::Tool::ContractViolation, /read only in part/)
    end

    it "names a remedy that the read-set can actually honour" do
      path = write("hello.txt", "hello world")
      session = Lain::Session.new
      session.record_read(path, complete: false)
      session.record_read(path)

      result = tool.call({ path:, old_string: "hello", new_string: "goodbye" }, invocation_with(session))

      expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
    end
  end

  # The pair T5 depends on, driven through the real ReadFile rather than a
  # hand-recorded read: a window that covers the whole file must leave the file
  # editable, or bounding the unwindowed read makes every large file
  # permanently uneditable with no escape (write_file's overwrite contract asks
  # Session#read? too, so it is not one).
  describe "AC: paired with a real read_file", :seam do
    let(:hundred) { (1..100).map { |n| "line #{n}\n" }.join }

    def read_with(session, **args)
      Lain::Tools::ReadFile.new.call(args, invocation_with(session, tool_use_id: "tu_read"))
    end

    # The trailing newline is what makes it unique: a bare "line 2" is also a
    # prefix of "line 20".."line 29", which edit_file refuses as ambiguous
    # BEFORE the contract under test would ever be reached.
    def edit_with(session, path)
      tool.call({ path:, old_string: "line 2\n", new_string: "LINE 2\n" }, invocation_with(session))
    end

    it "permits the edit when the window covered the whole file" do
      path = write("hundred.txt", hundred)
      session = Lain::Session.new
      read_with(session, path:, offset: 1, limit: 100)

      result = edit_with(session, path)

      expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
      expect(File.read(path)).to include("LINE 2\n")
    end

    it "refuses the edit when the window left lines unseen" do
      path = write("hundred.txt", hundred)
      session = Lain::Session.new
      read_with(session, path:, offset: 1, limit: 10)

      expect { edit_with(session, path) }.to raise_error(Lain::Tool::ContractViolation, /window/)
      expect(File.read(path)).to eq(hundred)
    end

    it "lets a later whole read upgrade a window into an edit" do
      path = write("hundred.txt", hundred)
      session = Lain::Session.new
      read_with(session, path:, offset: 50, limit: 5)
      read_with(session, path:)

      result = edit_with(session, path)

      expect(result.is_error).to be(false), -> { "edit_file refused: #{result.content}" }
    end
  end
end
