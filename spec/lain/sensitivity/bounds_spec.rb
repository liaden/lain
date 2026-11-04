# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Sensitivity::Bounds do
  around do |example|
    Dir.mktmpdir("lain-bounds") do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p(%w[a/b c d].map { File.join(@base, _1) })
      File.symlink(File.join(@base, "c"), File.join(@base, "to_c"))
      example.run
    end
  end

  def at(*names) = names.map { File.join(@base, _1) }
  def some(names) = at(*names.select { rand < 0.4 })
  def exec_pool = Lain::Confine::ExecRules.of(["target/**", at("a").first], ["bin/*", @base])
  def drawn_execs = [Lain::Confine::ExecRules::NONE, exec_pool, Lain::Confine::ExecRules.of(["bin/*", @base])].sample

  def drawn
    bounds = described_class.of(reads: some(%w[a a/b c to_c]), writes: some(%w[a/b d]), execs: drawn_execs)
    some(%w[d c]).inject(bounds) { |held, dir| held.with_child(dir) }
  end

  def population = Array.new(24) { drawn }

  def paths = at("a/x", "a/b/y", "c/z", "to_c/z", "d/w", "e/v") + [@base, "/"]

  def same_component?(left, right, component)
    case component
    when :execs then left == right
    else paths.all? { left.held?(_1) == right.held?(_1) }
    end
  end

  describe "the join" do
    include_examples "a monoid", operation: ->(a, b) { a | b }, identity: described_class::NONE,
                                 generator: -> { drawn }
    include_examples "a commutative monoid", operation: ->(a, b) { a | b }, generator: -> { drawn }

    it "joins componentwise", aggregate_failures: false do
      pairs = PropCheck::Generator.new { PropCheck::LazyTree.wrap([drawn, drawn]) }

      forall(pair: pairs) do |pair:|
        a, b = pair
        joined = a | b
        expect(%i[reads writes children execs].all? do |c|
          same_component?(joined.public_send(c), a.public_send(c) | b.public_send(c), c)
        end).to be(true)
      end
    end

    it "joins A's reads and writes with B's reads and execs" do
      a = described_class.of(reads: ["/p"], writes: ["/p"])
      b = described_class.of(reads: ["/epic"], execs: Lain::Confine::ExecRules.of(["target/**", "/p"]))

      joined = a | b

      expect([joined.read?("/p/x"), joined.read?("/epic/x"), joined.write?("/p/x"), joined.write?("/epic/x"),
              joined.exec?("/p/target/debug/x"), joined.exec?("/p/src/x")])
        .to eq([true, true, true, false, true, false])
    end
  end

  describe "the order" do
    let(:members) { population }

    include_examples "a meet semilattice", population: -> { members }, meet: ->(a, b) { a | b },
                                           ancestor_of: ->(joined, operand) { operand <= joined },
                                           equal: ->(a, b) { a == b }

    it "is a partial order: bounds on both sides of each other are equal" do
      pairs = members.product(members).select { |a, b| [a <= b, b <= a].all? }

      expect(pairs.reject { |a, b| a == b }).to be_empty
    end
  end

  describe "the canonical form" do
    it "makes equal bounds equal however they were built, digests included" do
      a = described_class.of(reads: ["/tmp", "/usr"])
      b = described_class.of(reads: ["/usr", "/tmp"])

      expect([a == b, a.hash == b.hash, a.digest == b.digest]).to eq([true, true, true])
    end

    it "drops a root nested under another" do
      nested = described_class.of(reads: at("a", "a/b"))
      outer = described_class.of(reads: at("a"))

      expect([nested == outer, nested.digest == outer.digest]).to eq([true, true])
    end

    it "tells bounds apart that hold different roots" do
      expect(described_class.of(reads: at("a")).digest).not_to eq(described_class.of(writes: at("a")).digest)
    end

    it "tells bounds apart that differ only in what they run" do
      plain = described_class.of(reads: ["/p"])
      running = described_class.of(reads: ["/p"], execs: Lain::Confine::ExecRules.of(["target/**", "/p"]))

      expect([plain == running, plain.digest == running.digest]).to eq([false, false])
    end
  end

  describe "lending to a child" do
    let(:parent) do
      described_class.of(reads: ["/usr"], writes: ["/w/p"], execs: Lain::Confine::ExecRules.of(["bin/*", "/usr"]))
                     .with_child("/w/c/a").with_child("/w/c/b")
    end

    it "gives the child the parent's base, its own lease, and not its siblings" do
      child = parent.lend("/w/c/b")

      expect([child.read?("/usr/lib/x"), child.read?("/w/c/b/f"), child.write?("/w/c/b/f"),
              child.write?("/w/p/f"), child.read?("/w/c/a/f"), child.exec?("/usr/bin/ls")])
        .to eq([true, true, true, false, false, true])
    end

    it "drops the parent's children" do
      expect(parent.lend("/w/c/b").children.held?("/w/c/a/f")).to be(false)
    end

    it "lets the parent read every child's lease" do
      expect([parent.read?("/w/c/a/Cargo.toml"), parent.read?("/w/c/b/Cargo.toml")]).to eq([true, true])
    end

    it "refuses to lend a directory the parent holds no lease on" do
      expect { parent.lend("/w") }.to raise_error(ArgumentError, %r{/w})
    end

    it "spells a lease reached through a link where it really lands" do
      linked = described_class::NONE.with_child(at("to_c").first)
      child = linked.lend(at("to_c").first)

      expect([linked.read?(at("c/z").first), child.write?(at("c/z").first), child.write?(at("to_c/z").first)])
        .to eq([true, true, true])
    end
  end

  it "reads what it may write" do
    expect(described_class.of(writes: ["/p"]).read?("/p/x")).to be(true)
  end

  it "reads a path under a linked root's target as well as under its own spelling" do
    bounds = described_class.of(reads: at("to_c"))

    expect(at("to_c/z", "c/z", "d/z").map { bounds.read?(_1) }).to eq([true, true, false])
  end

  it "holds nothing when it is none" do
    expect(paths.map { described_class::NONE.read?(_1) || described_class::NONE.write?(_1) }).to all(be(false))
  end

  it "lists every directory it lets the agent read, each where it really lands too" do
    bounds = described_class.of(reads: at("a"), writes: at("d")).with_child(at("to_c").first)

    expect(bounds.readable).to eq([*at("a", "c", "d", "to_c")].sort)
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(drawn | described_class::NONE)).to be(true)
  end
end
