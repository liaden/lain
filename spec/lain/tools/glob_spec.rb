# frozen_string_literal: true

require "fileutils"
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
end
