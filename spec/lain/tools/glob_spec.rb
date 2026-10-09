# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Lain::Tools::Glob do
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

  it "returns matches in deterministic sorted order" do
    touch("b.rb")
    touch("a.rb")
    touch("sub", "c.rb")
    touch("d.txt")

    result = tool.call(pattern: "**/*.rb", path: tmpdir)
    expect(result.content.split("\n")).to eq(%w[a.rb b.rb sub/c.rb])
  end

  it "says a pattern matched nothing, rather than returning an empty string" do
    touch("a.rb")

    result = tool.call(pattern: "*.nope", path: tmpdir)

    expect(result.is_error).to be(false)
    expect(result.content).not_to eq("")
    expect(result.content).to include('"*.nope"')
    expect(result.content).to match(/no match/i)
  end

  # {Lain::Middleware::WithholdSecretPaths} withholds the unreadable row; the
  # tool classifies nothing and must not raise over one.
  it "returns every match without raising when one name is not UTF-8" do
    touch("ok.rb")
    File.binwrite(File.join(tmpdir, "bad\xFF.rb".b), "")

    result = tool.call(pattern: "*.rb", path: tmpdir)

    expect(result).not_to be_error
    expect(result.content.b.split("\n")).to eq(["bad\xFF.rb".b, "ok.rb".b])
  end

  it "matches as UTF-8 text under a base spelled as BINARY bytes, the way Dir.pwd spells one under a C locale" do
    touch("café.rb")

    result = tool.call(pattern: "*.rb", path: tmpdir.b)

    expect(result.content).to eq("café.rb")
    expect(result.content.encoding).to eq(Encoding::UTF_8)
  end

  it "describes no-matches as a named, non-error outcome" do
    expect(tool.description).to match(/no match/i)
  end

  it "defaults the base path to the current directory" do
    Dir.chdir(tmpdir) do
      touch("only.rb")
      result = tool.call(pattern: "*.rb")
      expect(result.content.split("\n")).to eq(%w[only.rb])
    end
  end

  # A glob is an ENUMERATION under {Lain::Tool::Bounds}' stated boundary -- a
  # row-shaped result whose first N rows are a usable partial answer -- so it
  # caps and announces the cut IN BAND rather than refusing. The cap is applied
  # to the already-sorted list, never by stopping the walk, which is what keeps
  # the example above ("deterministic sorted order") true of a capped result
  # too.
  describe "the enumeration bound" do
    let(:bound) { described_class::BOUND }
    let(:overflow) { 5 }

    # Sortable-by-name so "which rows survived" is checkable against the sort
    # rather than against whatever order Dir.glob happened to yield.
    def fill(count)
      FileUtils.mkdir_p(File.join(tmpdir, "many"))
      names = Array.new(count) { |i| format("f%05d.rb", i) }
      names.each { |name| File.write(File.join(tmpdir, "many", name), "") }
      names
    end

    def rows_for = tool.call(pattern: "many/*.rb", path: tmpdir).content.split("\n")

    it "caps an oversized match set and discloses the cap and the true count in band" do
      total = bound.limit + overflow
      fill(total)

      rows = rows_for

      expect(rows.length).to eq(bound.limit + 1)
      expect(rows.last).to eq("... capped at #{bound.limit} of #{total} paths")
    end

    it "caps after the deterministic sort, so the surviving rows are the sorted prefix" do
      names = fill(bound.limit + overflow)

      expect(rows_for.first(bound.limit)).to eq(names.sort.first(bound.limit).map { "many/#{_1}" })
    end

    it "returns the same rows in the same order on every run" do
      fill(bound.limit + overflow)

      expect(rows_for).to eq(rows_for)
    end

    it "leaves a match set within the cap byte-identical" do
      touch("a.rb")
      touch("b.rb")

      expect(tool.call(pattern: "*.rb", path: tmpdir).content).to eq("a.rb\nb.rb")
    end
  end

  describe "holding the result to its byte ceiling" do
    let(:ceiling) { Lain::Tool::Bounds::CEILINGS.fetch("glob") }

    it "keeps whole paths up to the ceiling and says how many it kept and withheld" do
      400.times { |n| touch("app", "components", "feature_#{n / 50}", "a_component_with_a_long_name_#{n}.tsx") }

      result = tool.call(pattern: "**/*.tsx", path: tmpdir)

      expect(result.content.bytesize).to be <= ceiling
      expect(result.content.lines.last).to match(/\A\.\.\. truncated to \d+ of 400 paths, withholding \d+ bytes/)
      expect(result.content).to include("narrow the pattern or the path")
    end
  end

  describe "a tree git ignores part of" do
    def git_init(dir)
      FileUtils.mkdir_p(dir)
      _out, err, status = Open3.capture3("git", "init", "-q", chdir: dir)
      raise err unless status.success?
    end

    before do
      git_init(tmpdir)
      File.write(File.join(tmpdir, ".gitignore"), "target/\n")
    end

    it "does not return git-ignored files" do
      touch("target", "a.rs")
      touch("src", "b.rs")

      expect(tool.call(pattern: "**/*.rs", path: tmpdir).content).to eq("src/b.rs")
    end

    it "returns a directory that holds a listed file and not one that holds nothing" do
      touch("src", "sub", "c.rs")
      FileUtils.mkdir_p(File.join(tmpdir, "src", "empty"))

      expect(tool.call(pattern: "src/*", path: tmpdir).content).to eq("src/sub")
    end

    it "does not return a directory holding only ignored files" do
      touch("src", "target", "d.rs")
      touch("src", "e.rs")
      File.write(File.join(tmpdir, "src", ".gitignore"), "target/\n")

      expect(tool.call(pattern: "src/*", path: tmpdir).content.split("\n")).to eq(%w[src/.gitignore src/e.rs])
    end
  end

  describe "a pattern naming a directory away from the base" do
    it "honors an absolute pattern, filtered by that directory's own ignores" do
      Dir.mktmpdir do |elsewhere|
        _out, _err, status = Open3.capture3("git", "init", "-q", chdir: elsewhere)
        expect(status).to be_success
        File.write(File.join(elsewhere, ".gitignore"), "target/\n")
        FileUtils.mkdir_p(File.join(elsewhere, "target"))
        File.write(File.join(elsewhere, "target", "x.rs"), "")
        File.write(File.join(elsewhere, "y.rs"), "")

        result = tool.call(pattern: File.join(elsewhere, "**", "*.rs"), path: tmpdir)

        expect(result.content).to eq(File.join(elsewhere, "y.rs"))
      end
    end

    it "honors a pattern that climbs out of the base" do
      touch("up.rb")
      touch("base", "in.rb")

      result = tool.call(pattern: "../*.rb", path: File.join(tmpdir, "base"))

      expect(result.content).to eq("../up.rb")
    end

    it "expands braces" do
      touch("a.rb")
      touch("b.py")
      touch("c.txt")

      expect(tool.call(pattern: "*.{rb,py}", path: tmpdir).content).to eq("a.rb\nb.py")
    end
  end

  # Where a pattern's walk starts: its leading literal directories against the
  # base, which a confined child's gate judges as well as the base itself.
  describe ".walk_root" do
    it "is the base for a pattern that starts with a wildcard" do
      expect(described_class.walk_root("**/*.rb", "/p")).to eq("/p")
    end

    it "is the literal directories below the base" do
      expect(described_class.walk_root("lib/**/*.rb", "/p")).to eq("/p/lib")
    end

    it "climbs out of the base" do
      expect(described_class.walk_root("../../**/*.md", "/a/b/c")).to eq("/a")
    end

    it "is an absolute pattern's own directory" do
      expect(described_class.walk_root("/etc/*.conf", "/p")).to eq("/etc")
    end
  end

  describe "a pattern ending in a slash" do
    before do
      touch("src", "sub", "a.rb")
      touch("top.rb")
    end

    it "returns the matching directories with a trailing slash, and no files" do
      expect(tool.call(pattern: "src/", path: tmpdir).content).to eq("src/")
      expect(tool.call(pattern: "*/", path: tmpdir).content).to eq("src/")
      expect(tool.call(pattern: "**/", path: tmpdir).content.split("\n")).to eq(%w[src/ src/sub/])
    end
  end

  describe "the walk limit" do
    subject(:tool) { described_class.new(walk_limit: Lain::Tool::Bounds::WalkLimit.new(entries: 10, bytes: 1_000)) }

    it "stops listing past the entry limit and names it" do
      30.times { touch("f#{format("%02d", _1)}.txt") }

      content = tool.call(pattern: "**/*.txt", path: tmpdir).content

      expect(content.lines.size).to eq(11)
      expect(content.lines.last).to include("10 entries").and include("narrow")
    end

    it "adds no trailer to a walk under the limit" do
      3.times { touch("f#{format("%02d", _1)}.txt") }

      expect(tool.call(pattern: "**/*.txt", path: tmpdir).content).not_to include("narrow")
    end
  end

  it_behaves_like "a walk run off the reactor", ->(dir) { { "pattern" => "**/*.rb", "path" => dir } }
end
