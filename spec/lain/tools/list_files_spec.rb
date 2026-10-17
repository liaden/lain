# frozen_string_literal: true

require "fileutils"
require "open3"
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

  it "lists / recursively with entries relative to it" do
    result = Timeout.timeout(30) { tool.call(path: "/", recursive: true) }

    expect(result.is_error).to be(false)
    expect(result.content.split("\n").grep(%r{\A/})).to be_empty
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

  # The tool classifies nothing, so it hands a name that is not UTF-8 on as
  # the bytes it is -- {Lain::Middleware::WithholdSecretPaths} withholds that
  # one row. What the tool owns is the TAG: the listing is UTF-8 text however
  # the directory was spelled, so the guard asks the right question of it.
  describe "a name that is not UTF-8" do
    before do
      touch("ok.rb")
      File.binwrite(File.join(tmpdir, "bad\xFF.rb".b), "")
    end

    it "lists every entry without raising, the unreadable name among them" do
      result = tool.call(path: tmpdir)

      expect(result).not_to be_error
      expect(result.content.b.split("\n")).to eq(["bad\xFF.rb".b, "ok.rb".b])
    end
  end

  it "lists as UTF-8 text a directory spelled as BINARY bytes, the way Dir.pwd spells one under a C locale" do
    touch("café.rb")

    result = tool.call(path: tmpdir.b)

    expect(result.content).to eq("café.rb")
    expect(result.content.encoding).to eq(Encoding::UTF_8)
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

  it_behaves_like "a tool answering a bad file target", :directory do
    def call_with(path) = tool.call(path:)
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

  describe "holding the result to its byte ceiling" do
    let(:ceiling) { Lain::Tool::Bounds::CEILINGS.fetch("list_files") }

    it "keeps whole entries up to the ceiling and names a subdirectory as the narrower move" do
      400.times { |n| touch("app", "components", "feature_#{n / 50}", "a_component_with_a_long_name_#{n}.tsx") }

      result = tool.call(path: tmpdir, recursive: true)

      expect(result.content.bytesize).to be <= ceiling
      expect(result.content.lines.last).to match(/\A\.\.\. truncated to \d+ of \d+ paths, withholding \d+ bytes/)
      expect(result.content).to include("list a subdirectory")
    end
  end

  describe "a recursive listing of a repository" do
    before do
      _out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", "init", "-q", chdir: tmpdir)
      raise err unless status.success?

      File.write(File.join(tmpdir, ".gitignore"), "target/\n")
    end

    it "lists no entry under .git or an ignored tree, and keeps the directories that hold listed files" do
      touch("target", "a.rs")
      touch("src", "b.rs")

      rows = tool.call(path: tmpdir, recursive: true).content.split("\n")

      expect(rows).to eq(%w[.gitignore src src/b.rs])
    end
  end

  describe "the walk limit" do
    subject(:tool) { described_class.new(walk_limit: Lain::Tool::Bounds::WalkLimit.new(entries: 10, bytes: 1_000)) }

    it "stops listing past the entry limit and names it" do
      30.times { touch("f#{format("%02d", _1)}.txt") }

      content = tool.call(path: tmpdir, recursive: true).content

      expect(content.lines.size).to eq(11)
      expect(content.lines.last).to include("10 entries").and include("narrow")
    end

    it "adds no trailer to a walk under the limit" do
      3.times { touch("f#{format("%02d", _1)}.txt") }

      expect(tool.call(path: tmpdir, recursive: true).content).not_to include("narrow")
    end
  end

  it_behaves_like "a walk run off the reactor", ->(dir) { { "path" => dir, "recursive" => true } }
end
