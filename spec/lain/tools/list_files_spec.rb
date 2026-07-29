# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Tools::ListFiles do
  subject(:tool) { described_class.new }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  attr_reader :tmpdir

  def touch(*parts)
    path = File.join(tmpdir, *parts)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    path
  end

  it "lists the immediate entries of a directory, sorted" do
    touch("b.txt")
    touch("a.txt")
    FileUtils.mkdir_p(File.join(tmpdir, "sub"))

    result = tool.call(path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[a.txt b.txt sub])
  end

  it "does not descend into subdirectories unless asked" do
    touch("top.txt")
    touch("sub", "nested.txt")

    result = tool.call(path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[sub top.txt])
  end

  it "descends into subdirectories when recursive: true" do
    touch("top.txt")
    touch("sub", "nested.txt")

    result = tool.call(path: tmpdir, recursive: true)
    expect(result.content.split("\n")).to include("sub/nested.txt", "top.txt")
  end

  it "reports a missing directory as an error Result rather than raising" do
    missing = File.join(tmpdir, "nope")
    result = tool.call(path: missing)
    expect(result).to have_attributes(is_error: true, content: "no such directory: #{missing}")
  end

  it "reports a file (not a directory) as an error Result rather than raising" do
    path = touch("a_file.txt")
    result = tool.call(path:)
    expect(result).to have_attributes(is_error: true, content: "not a directory: #{path}")
  end

  it "reports an unreadable directory as an error Result rather than raising" do
    sub = File.join(tmpdir, "locked")
    FileUtils.mkdir_p(sub)
    File.chmod(0o000, sub)
    result = tool.call(path: sub)
    expect(result).to have_attributes(is_error: true, content: "directory is not readable: #{sub}")
  ensure
    File.chmod(0o700, sub) if sub && File.exist?(sub)
  end

  describe "resolving paths against the session WorkerEnv" do
    def invocation_with(session)
      Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session)
    end

    def session_at(cwd)
      Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd:, env: ENV.to_h))
    end

    it "resolves a relative path under the injected WorkerEnv cwd" do
      touch("sub", "nested.txt")

      result = tool.call({ path: "sub" }, invocation_with(session_at(tmpdir)))

      expect(result).to eq(Lain::Tool::Result.ok("nested.txt"))
    end

    it "honors an absolute path as given, whatever the WorkerEnv cwd" do
      touch("a.txt")

      Dir.mktmpdir do |elsewhere|
        result = tool.call({ path: tmpdir }, invocation_with(session_at(elsewhere)))

        expect(result).to eq(Lain::Tool::Result.ok("a.txt"))
      end
    end

    it "resolves a relative path against the process cwd under the default WorkerEnv" do
      touch("a.txt")

      Dir.chdir(tmpdir) do
        result = tool.call({ path: "." }, invocation_with(Lain::Session.new))

        expect(result).to eq(Lain::Tool::Result.ok("a.txt"))
      end
    end

    # An ERROR names the RESOLVED path: "where did it actually look" is the
    # whole content of that message, and under a worktree-isolated worker the
    # given spelling does not answer it. An exact string, because a loose
    # /no such directory/ passes against either spelling -- which is exactly
    # how this could drift back.
    it "names the resolved path in an error Result" do
      result = tool.call({ path: "nope" }, invocation_with(session_at(tmpdir)))

      expect(result).to have_attributes(is_error: true, content: "no such directory: #{tmpdir}/nope")
    end
  end
end
