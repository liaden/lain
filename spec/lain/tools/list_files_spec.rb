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

  it "says an empty directory is empty, not silently returning blank content" do
    result = tool.call(path: tmpdir)

    expect(result.is_error).to be(false)
    expect(result.content).not_to eq("")
    expect(result.content).to include(tmpdir)
    expect(result.content).to match(/empty/i)
  end

  it "distinguishes an empty listing from a missing directory" do
    missing = File.join(tmpdir, "nope")

    empty_result = tool.call(path: tmpdir)
    missing_result = tool.call(path: missing)

    expect(empty_result.is_error).to be(false)
    expect(missing_result).to have_attributes(is_error: true, content: "no such directory: #{missing}")
    expect(missing_result.content).not_to match(/empty/i)
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

  it "describes an empty directory as a possible, non-error outcome" do
    expect(tool.description).to match(/empty/i)
  end

  # A listing is an ENUMERATION under {Lain::Tool::Bounds}' stated boundary --
  # a row-shaped result whose first N rows are a usable partial answer -- so it
  # caps and announces the cut IN BAND rather than refusing. Capping happens
  # after `entries`' sort, never by stopping the walk: which rows survive is
  # decided by the ordering, not by the filesystem.
  describe "the enumeration bound" do
    let(:bound) { described_class::BOUND }
    let(:overflow) { 5 }

    def fill(count)
      names = Array.new(count) { |i| format("f%05d.txt", i) }
      names.each { |name| File.write(File.join(tmpdir, name), "") }
      names
    end

    def rows_for = tool.call(path: tmpdir).content.split("\n")

    it "caps an oversized listing and discloses the cap and the true count in band" do
      total = bound.limit + overflow
      fill(total)

      rows = rows_for

      expect(rows.length).to eq(bound.limit + 1)
      expect(rows.last).to eq("... capped at #{bound.limit} of #{total} paths")
    end

    it "caps after the deterministic sort, so the surviving rows are the sorted prefix" do
      names = fill(bound.limit + overflow)

      expect(rows_for.first(bound.limit)).to eq(names.sort.first(bound.limit))
    end

    it "returns the same entries in the same order on every run" do
      fill(bound.limit + overflow)

      expect(rows_for).to eq(rows_for)
    end

    it "leaves a listing within the cap byte-identical" do
      touch("a.txt")
      touch("b.txt")

      expect(tool.call(path: tmpdir).content).to eq("a.txt\nb.txt")
    end
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
