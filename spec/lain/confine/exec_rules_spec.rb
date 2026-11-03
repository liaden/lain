# frozen_string_literal: true

RSpec.describe Lain::Confine::ExecRules do
  def rules(*pairs) = described_class.of(*pairs)

  def pool = [["target/**", "/p"], ["bin/*", "/p"], [".venv/bin/*", "/q"], ["exe/lain", "/c"], ["*", "/r"]]
  def drawn = rules(*pool.select { rand < 0.4 })

  def paths
    %w[/p/target/debug/deps/x /p/bin/tool /p/src/main.rs /q/.venv/bin/pytest /c/exe/lain /c/exe/other /r/x /s/x]
  end

  describe "the join" do
    include_examples "a monoid", operation: ->(a, b) { a | b }, identity: described_class::NONE,
                                 generator: -> { drawn }
    include_examples "a commutative monoid", operation: ->(a, b) { a | b }, generator: -> { drawn }

    it "runs what either side runs", aggregate_failures: false do
      draws = PropCheck::Generator.new { PropCheck::LazyTree.wrap([drawn, drawn, paths.sample]) }

      forall(draw: draws) do |draw:|
        a, b, path = draw
        expect((a | b).exec?(path)).to eq(a.exec?(path) || b.exec?(path))
      end
    end
  end

  it "runs a path under a rule's root that its glob matches, dotted segments included" do
    set = rules(["target/**", "/p"], [".venv/bin/*", "/p"])

    verdicts = %w[/p/target/debug/deps/store-1a2b /p/.venv/bin/pytest /p/src/main.rs /elsewhere/target/x]

    expect(verdicts.map { set.exec?(_1) }).to eq([true, true, false, false])
  end

  it "runs nothing beside its root that only shares the root's spelling as a prefix" do
    expect(rules(["target/**", "/p"]).exec?("/ptarget/x")).to be(false)
  end

  it "runs a dotted path a leading wildcard matches" do
    expect(rules(["*", "/p"]).exec?("/p/.venv/bin/pytest")).to be(true)
  end

  it "runs nothing a parent segment climbs out to" do
    expect(rules(["target/**", "/p"]).exec?("/p/target/../../etc/x")).to be(false)
  end

  it "refuses a glob that climbs out of its root or is absolute" do
    expect([["../**", "/p"], ["target/../../x", "/p"], ["/usr/bin/*", "/p"]].map do |pair|
      rules(pair)
    rescue ArgumentError
      :refused
    end).to eq(%i[refused refused refused])
  end

  it "refuses a glob that is empty or holds an empty or `.` segment" do
    expect([["", "/p"], ["a/./b", "/p"], ["a//b", "/p"], ["a/", "/p"]].map do |pair|
      rules(pair)
    rescue ArgumentError
      :refused
    end).to eq(%i[refused refused refused refused])
  end

  it "refuses a rule whose root is not absolute" do
    expect { described_class::Rule.new(glob: "x", root: "p") }.to raise_error(ArgumentError, /"p"/)
  end

  it "expands a relative root against the process directory" do
    expect(rules(%w[x p]).exec?(File.join(Dir.pwd, "p", "x"))).to be(true)
  end

  it "builds a rule that is shareable from strings nobody froze" do
    expect(Ractor.shareable?(described_class::Rule.new(glob: +"x", root: +"/p"))).to be(true)
  end

  it "runs nothing when it is none" do
    expect(paths.map { described_class::NONE.exec?(_1) }).to all(be(false))
  end

  it "is equal however its rules were ordered or repeated" do
    a = rules(["bin/*", "/p"], ["target/**", "/p"])
    b = rules(["target/**", "/p"], ["bin/*", "/p"], ["bin/*", "/p"])

    expect([a == b, a.hash == b.hash]).to eq([true, true])
  end

  it "tells apart sets that hold different rules" do
    expect(rules(["bin/*", "/p"]) == rules(["target/**", "/p"])).to be(false)
  end

  it "lowers a wild rule to the directory above its first wild segment, and a literal one to itself" do
    set = rules(["target/**", "/p"], ["node_modules/.bin/*", "/p"], ["exe/lain", "/c"], ["*", "/r"], ["*/bin/x", "/s"])

    expect(set.dirs).to contain_exactly("/p/target", "/p/node_modules/.bin", "/c/exe/lain", "/r", "/s")
  end

  it "orders a set below one holding every rule it holds" do
    small = rules(["bin/*", "/p"])
    large = small | rules(["target/**", "/p"])

    expect([small <= large, large <= small]).to eq([true, false])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(rules(*pool) | described_class::NONE)).to be(true)
  end
end
