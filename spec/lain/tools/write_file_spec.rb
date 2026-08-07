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

  # T15: a masked read is a read whose secrets the model never saw, and writing
  # the file back is worse here than an edit is. An edit rewrites one span; a
  # write replaces the WHOLE file with what the model holds -- the projection,
  # placeholders included -- so the secret is not clobbered, it is destroyed and
  # replaced by the literal string `<redacted:1>`.
  describe "AC: a masked read never satisfies the write contract" do
    let(:secret) { "API_KEY=sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE\n" }

    def masked_session(path)
      Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {}))
                   .record_read(path).record_masked_read(path)
    end

    it "refuses the write and leaves the secret on disk" do
      path = write(".env", secret)

      expect do
        tool.call({ path:, content: "API_KEY=<redacted:1>\n" }, invocation_with(masked_session(path)))
      end.to raise_error(Lain::Tool::ContractViolation, /read only in part/)

      expect(File.read(path)).to eq(secret)
    end

    # The refusal must name the MASK, not "never read": a model told the file
    # was never read re-reads it, gets the same projection, and loops.
    it "names the masking rather than claiming the file was never read" do
      path = write(".env", secret)
      message = begin
        tool.call({ path:, content: "x" }, invocation_with(masked_session(path)))
        nil
      rescue Lain::Tool::ContractViolation => e
        e.message
      end

      expect(message).to include("read only in part")
      expect(message).not_to include("never read")
    end

    # The masked guard must not close the create case, and it cannot: a path
    # that was read is a path that exists.
    it "still lets a create through, since only a read path can carry a mask" do
      path = File.join(tmpdir, "fresh.rb")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {}))

      expect { tool.call({ path:, content: "x" }, invocation_with(session)) }.not_to raise_error
      expect(File.read(path)).to eq("x")
    end

    it "allows the write once the same path is recorded as wholly read and unmasked" do
      path = write("plain.rb", "x = 1\n")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: {})).record_read(path)

      expect { tool.call({ path:, content: "x = 2\n" }, invocation_with(session)) }.not_to raise_error
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
      expect(result.content).to include("never read")
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

    it "honors path-spelling-insensitive read tracking" do
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
