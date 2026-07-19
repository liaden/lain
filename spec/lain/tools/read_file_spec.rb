# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::ReadFile do
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

  it "has a model-facing name and description" do
    expect(tool.name).to eq("read_file")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "reads a file's full contents" do
    path = write("hello.txt", "hello\nworld\n")
    expect(tool.call(path:)).to eq(Lain::Tool::Result.ok("hello\nworld\n"))
  end

  it "reports a missing file as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope.txt")
    result = tool.call(path: missing)
    expect(result).to have_attributes(is_error: true)
    expect(result.content).to match(/no such file/)
  end

  it "reports a directory as an error Result rather than raising" do
    result = tool.call(path: tmpdir)
    expect(result).to have_attributes(is_error: true, content: /is a directory/)
  end

  it "reports an unreadable file as an error Result rather than raising" do
    path = write("secret.txt", "shh")
    File.chmod(0o000, path)
    result = tool.call(path:)
    expect(result).to have_attributes(is_error: true, content: /not readable/)
  ensure
    File.chmod(0o600, path) if path && File.exist?(path)
  end

  it "does not care about the invocation it is handed" do
    path = write("a.txt", "a")
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect(tool.call({ path: }, invocation)).to eq(Lain::Tool::Result.ok("a"))
  end

  describe "recording reads on the session (invocation.context)" do
    let(:session) { Lain::Session.new }

    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    it "records a successful read on the threaded session" do
      path = write("read.txt", "contents")

      tool.call({ path: }, invocation_with(session))

      expect(session.read?(path)).to be(true)
    end

    it "does not record a path it never read" do
      path = write("read.txt", "contents")
      tool.call({ path: }, invocation_with(session))

      expect(session.read?(File.join(tmpdir, "never.txt"))).to be(false)
    end

    it "does not record a failed read" do
      missing = File.join(tmpdir, "nope.txt")

      tool.call({ path: missing }, invocation_with(session))

      expect(session.read?(missing)).to be(false)
    end

    # AC3: a Session::Null context keeps the tool working with nothing recorded.
    it "records into a Session::Null context without raising" do
      path = write("read.txt", "contents")
      invocation = invocation_with(Lain::Session::Null.instance)

      result = tool.call({ path: }, invocation)

      expect(result).to eq(Lain::Tool::Result.ok("contents"))
    end
  end

  describe "resolving relative paths against the session WorkerEnv" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    it "resolves a relative path against Dir.pwd under the default WorkerEnv" do
      write("rel.txt", "relative-default")
      Dir.chdir(tmpdir) do
        result = tool.call({ path: "rel.txt" }, invocation_with(Lain::Session.new))
        expect(result).to eq(Lain::Tool::Result.ok("relative-default"))
      end
    end

    it "resolves a relative path under an injected WorkerEnv cwd" do
      write("rel.txt", "under-sandbox")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: ENV.to_h))

      result = tool.call({ path: "rel.txt" }, invocation_with(session))

      expect(result).to eq(Lain::Tool::Result.ok("under-sandbox"))
    end

    it "records the RESOLVED path so a later read-before-write contract still matches" do
      write("rel.txt", "x")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: tmpdir, env: ENV.to_h))

      tool.call({ path: "rel.txt" }, invocation_with(session))

      expect(session.read?(File.join(tmpdir, "rel.txt"))).to be(true)
    end
  end
end
