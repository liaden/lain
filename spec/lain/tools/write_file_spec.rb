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

    # Review panel (Schneeman, BLOCKER): a whole-file writer that cannot
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

  # A masked read is a read whose secrets the model never saw, and writing
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

    # And it names WHICH file, not the placeholder word "path" the declaration
    # used to carry -- the same capability edit_file's refusals gained.
    it "names the file it is refusing" do
      path = write(".env", secret)
      message = begin
        tool.call({ path:, content: "x" }, invocation_with(masked_session(path)))
        nil
      rescue Lain::Tool::ContractViolation => e
        e.message
      end

      expect(message).to include("#{path} was read only in part this session")
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
      end.to raise_error(Lain::Tool::ContractViolation,
                         "precondition failed for write_file: #{path} exists and was never read in full in " \
                         "this conversation's current history")

      expect(File.read(path)).to eq("original")
    end

    it "runs through Handler::Live and the model receives an error result naming the unmet contract" do
      path = write("existing.rb", "original")
      session = Lain::Session.new
      result = dispatch_call("write_file", { path:, content: "y" }, toolset: Lain::Toolset.new([tool]),
                                                                    context: session)

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

    it "records the post-write read against the call that made the write" do
      path = write("existing.rb", "original")
      journal = []
      session = Lain::Session.new(journal:)
      session.record_read(path)

      invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_9", context: session)
      tool.call({ path:, content: "longer contents" }, invocation)

      expect(journal.last).to have_attributes(tool_use_id: "tu_9", lines: [1, nil])
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

  # Under the write-set scope nothing else knows what a path held before lain
  # wrote it, so an undo of a created file or a first overwrite reads it here.
  describe "the pre-image a turn's undo puts back" do
    it "records a path it creates as absent before the turn's first write" do
      path = File.join(tmpdir, "new.rb")
      session = Lain::Session.new.open_pre_images

      tool.call({ path:, content: "x" }, invocation_with(session))

      expect(session.pre_images.fetch(path)).to have_attributes(recorded?: true, bytes: nil)
    end

    it "records the bytes an overwrite replaced, keeping the first across later writes in the turn" do
      path = write("existing.rb", "original")
      session = Lain::Session.new.record_read(path).open_pre_images

      tool.call({ path:, content: "second" }, invocation_with(session))
      tool.call({ path:, content: "third" }, invocation_with(session))

      expect(session.pre_images.fetch(path).bytes).to eq("original".b)
    end

    it "captures afresh once a snapshot settled the last turn" do
      path = write("existing.rb", "original")
      session = Lain::Session.new.record_read(path).open_pre_images
      tool.call({ path:, content: "turn one's" }, invocation_with(session))

      session.settle_pre_images.open_pre_images
      tool.call({ path:, content: "turn two's" }, invocation_with(session))

      expect(session.pre_images.fetch(path).bytes).to eq("turn one's".b)
    end

    # A torn turn settles no snapshot, so the next settle spans both turns and
    # must put back what stood before the first of them.
    it "carries an unsettled turn's pre-images into the next, the first capture winning" do
      path = write("existing.rb", "original")
      session = Lain::Session.new.record_read(path).open_pre_images
      tool.call({ path:, content: "torn turn's" }, invocation_with(session))

      session.open_pre_images
      tool.call({ path:, content: "next turn's" }, invocation_with(session))

      expect(session.pre_images.fetch(path).bytes).to eq("original".b)
    end

    # Someone other than lain changed the path after the torn turn's write, so
    # what stood before the torn write is not what stands before the next one.
    it "captures afresh over a carried pre-image once the path no longer holds what the tool wrote" do
      path = write("existing.rb", "original")
      session = Lain::Session.new.record_read(path).open_pre_images
      tool.call({ path:, content: "torn turn's" }, invocation_with(session))
      File.write(path, "fixed by hand")

      session.open_pre_images
      tool.call({ path:, content: "next turn's" }, invocation_with(session))

      expect(session.pre_images.fetch(path).bytes).to eq("fixed by hand".b)
    end

    it "drops a carried pre-image whose path was changed by hand and not written again" do
      path = write("existing.rb", "original")
      other = File.join(tmpdir, "other.rb")
      session = Lain::Session.new.record_read(path).open_pre_images
      tool.call({ path:, content: "torn turn's" }, invocation_with(session))
      File.write(path, "fixed by hand")

      session.open_pre_images
      tool.call({ path: other, content: "next turn's" }, invocation_with(session))

      expect(session.pre_images.keys).to eq([other])
    end

    it "holds no bytes while no turn is open" do
      path = write("existing.rb", "original")
      session = Lain::Session.new.record_read(path)

      tool.call({ path:, content: "y" }, invocation_with(session))

      expect(session.pre_images).to eq({})
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
