# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Sensitivity::Roots do
  around do |example|
    Dir.mktmpdir("lain-roots") do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p(%w[a/b c d e].map { File.join(@base, _1) })
      File.symlink(File.join(@base, "c"), File.join(@base, "to_c"))
      File.symlink(File.join(@base, "a", "b"), File.join(@base, "to_b"))
      example.run
    end
  end

  def dirs = %w[a a/b c d to_c to_b].map { File.join(@base, _1) }
  def fixed = %w[a a/b c to_c].map { File.join(@base, _1) }
  def drawn = described_class.of(*dirs.select { rand < 0.4 })
  def every_roots = (0..fixed.size).flat_map { fixed.combination(_1).to_a }.map { described_class.of(*_1) }
  def same_held?(left, right) = paths.all? { left.held?(_1) == right.held?(_1) }

  def paths
    %w[a/x a/b/y c/z to_c/z to_b/y d e/w].map { File.join(@base, _1) } + [@base, "/"]
  end

  describe "the join" do
    include_examples "a monoid", operation: ->(a, b) { a | b }, identity: described_class.none,
                                 generator: -> { drawn }, equal: ->(a, b) { same_held?(a, b) }
    include_examples "a commutative monoid", operation: ->(a, b) { a | b }, generator: -> { drawn },
                                             equal: ->(a, b) { same_held?(a, b) }
  end

  describe "the order" do
    let(:population) { every_roots }

    include_examples "a meet semilattice", population: -> { population }, meet: ->(a, b) { a | b },
                                           ancestor_of: ->(joined, operand) { operand <= joined },
                                           equal: ->(a, b) { same_held?(a, b) }

    it "is the least upper bound: nothing above both operands sits below their join" do
      triples = population.product(population, population)

      bounded = triples.select { |a, b, c| a <= c && b <= c }

      expect(bounded.reject { |a, b, c| (a | b) <= c }).to be_empty
    end

    it "places no root below a sibling, nor a parent below its child" do
      c, d, a, b = %w[c d a a/b].map { described_class.of(File.join(@base, _1)) }

      expect([c <= d, a <= b]).to eq([false, false])
    end

    it "is a preorder only: a root beside its own child sits on both sides of the root alone" do
      alone = described_class.of(File.join(@base, "a"))
      nested = described_class.of(File.join(@base, "a"), File.join(@base, "a", "b"))

      expect([alone <= nested, nested <= alone]).to eq([true, true])
    end
  end

  it "distributes holding over the join", aggregate_failures: false do
    pairs = PropCheck::Generator.new { PropCheck::LazyTree.wrap([drawn, drawn, paths.sample]) }

    forall(draw: pairs) do |draw:|
      a, b, path = draw
      expect((a | b).held?(path)).to eq(a.held?(path) || b.held?(path))
    end
  end

  it "holds a path under a linked root's target as well as under its own spelling" do
    linked = described_class.of(File.join(@base, "to_c"))

    expect(%w[to_c/z c/z d/z].map { linked.held?(File.join(@base, _1)) }).to eq([true, true, false])
  end

  it "spells a root that does not exist as written, and a trailing slash away" do
    roots = described_class.of(File.join(@base, "gone", ""))

    expect([roots.held?(File.join(@base, "gone", "x")), roots.held?(File.join(@base, "gonex"))]).to eq([true, false])
  end

  it "holds nothing when it is none" do
    expect(paths.map { described_class.none.held?(_1) }).to all(be(false))
  end

  it "holds every absolute path under the filesystem root" do
    expect(paths.map { described_class.of("/").held?(_1) }).to all(be(true))
  end

  it "spells a root where the facts it is given say it lands" do
    facts = instance_double(Lain::FileFacts::Live, realpath: File.join(@base, "d"))

    roots = described_class.of(File.join(@base, "c"), facts:)

    expect(%w[c/z d/z e/z].map { roots.held?(File.join(@base, _1)) }).to eq([true, true, false])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(described_class.of(*dirs) | described_class.none)).to be(true)
  end
end
