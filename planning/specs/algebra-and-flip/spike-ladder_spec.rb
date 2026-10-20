# frozen_string_literal: true

require_relative "ladder"

module RuleChainSpecSupport
  class Allower < Lain::Approval::Rule
    def decide(call) = allow(call, because: "spec allows everything")
  end
  class Denier < Lain::Approval::Rule
    def decide(call) = deny(call, because: "spec denies everything")
  end
  class Raiser < Lain::Approval::Rule
    def decide(_call) = raise("the rule itself is broken")
  end
  class Delegating < Lain::Approval::Rule
    def initialize(inner)
      super()
      @inner = inner
    end
    def decide(call) = @inner.decide(call)
  end
  class Recorder
    attr_reader :faults
    def initialize = @faults = []
    def call(fault) = @faults << fault
  end
end

module SpikeRungs
  Decision = Data.define(:verdict, :rule, :human) do
    def initialize(verdict:, rule:, human: false) = super
    def allow? = verdict == :allow
    def deny? = verdict == :deny
  end
  Silent = Data.define(:name) { def call(_) = Spike::ABSTAIN }
  Allower = Data.define(:name) { def call(_) = Decision.new(verdict: :allow, rule: name) }
  Human = Data.define(:name) { def call(_) = Decision.new(verdict: :allow, rule: name, human: true) }
  Denier = Data.define(:name) { def call(_) = Decision.new(verdict: :deny, rule: name) }
  Boom = Class.new(StandardError)
  Raiser = Data.define(:name) { def call(_) = raise(Boom, "the rule itself is broken") }
  Consulted = Class.new(Exception) # rubocop:disable Lint/InheritException
  Tripwire = Data.define(:name) { def call(_) = raise(Consulted) }

  POOL = [Silent.new("s1"), Silent.new("s2"), Allower.new("a1"), Allower.new("a2"),
          Denier.new("d1"), Denier.new("d2"), Raiser.new("r1"), Raiser.new("r2")].freeze
  HumanExempt = Data.define { def call(decision) = decision.human }
end

RSpec.describe Spike::Ladder do
  include SpikeRungs
  S = SpikeRungs
  def lad(*r) = Spike::Ladder[*r]
  def poisoned(l, **kw) = Spike::Poisoning.new(ladder: l, **kw).call(:x)
  def observe(l) = poisoned(l).then { [_1.decision&.verdict, (_1.by if _1.decided?), _1.faults.map(&:rung)] }
  def observe_raw(l) = l.call(:x).then { [_1.decision&.verdict, (_1.by if _1.decided?), _1.faults.map(&:rung)] }

  it "is a deeply frozen, Ractor-shareable value, and so is its outcome" do
    l = lad(S::Raiser.new("r"), lad(S::Denier.new("d")))
    expect(Ractor.shareable?(l)).to be(true)
    expect(Ractor.shareable?(l.call(:x))).to be(true)
  end

  describe "RuleChain's poisoning examples, ported" do
    it "skips a raiser and continues" do
      expect(lad(S::Raiser.new("raiser"), S::Allower.new("allower")).call(:x).by).to eq("allower")
    end
    it "poisons the allow side" do
      o = poisoned(lad(S::Raiser.new("raiser"), S::Allower.new("allower")))
      expect(o).not_to be_allow
      expect(o.faults.first.rung).to eq("raiser")
    end
    it "a lone raiser is a fault, not the same nothing as abstention" do
      o = poisoned(lad(S::Raiser.new("raiser")))
      expect([o.decided?, o.faulted?]).to eq([false, true])
      expect(poisoned(lad(S::Silent.new("s"))).faulted?).to be(false)
    end
    it "leaves the deny side working, still attributed, still faulted" do
      o = poisoned(lad(S::Raiser.new("raiser"), S::Denier.new("denier")))
      expect([o.deny?, o.faulted?, o.by]).to eq([true, true, "denier"])
    end
    it "leaves a clean chain untouched" do
      expect(poisoned(lad(S::Allower.new("a")))).to be_allow
    end
  end

  describe "RuleChain's 4 nesting (associativity) examples, ported" do
    def nested(inner, *outer) = lad(lad(*inner), *outer)

    it "does not launder the inner fault into an abstention" do
      o = poisoned(nested([S::Raiser.new("raiser"), S::Allower.new("allower")], S::Allower.new("allower2")))
      expect(o).not_to be_allow
      expect(o.faults.first.rung).to eq("raiser")
    end
    it "propagates a clean inner decision" do
      expect(poisoned(nested([S::Denier.new("denier")]))).to be_deny
    end
    it "reaches the outer rules when the inner abstains" do
      expect(poisoned(nested([S::Silent.new("s")], S::Allower.new("a")))).to be_allow
    end
    it "lets a deny past the inner fault decide, naming which rung broke" do
      o = poisoned(nested([S::Raiser.new("raiser")], S::Denier.new("denier")))
      expect([o.deny?, o.faulted?, o.faults.first.rung]).to eq([true, true, "raiser"])
    end
  end

  describe "Escalation's composition examples, ported" do
    it "is unchanged by an always-abstaining rung inserted anywhere" do
      d = S::Denier.new("rules")
      bare = observe(lad(d))
      expect(observe(lad(S::Silent.new("first"), d))).to eq(bare)
      expect(observe(lad(d, S::Silent.new("last")))).to eq(bare)
    end
    it "never consults a rung past the deciding one" do
      expect { lad(S::Denier.new("rules"), S::Tripwire.new("t")).call(:x) }.not_to raise_error
    end
    it "does reach a rung past an abstaining one" do
      expect { lad(S::Silent.new("s"), S::Tripwire.new("t")).call(:x) }.to raise_error(S::Consulted)
    end
    it "an all-abstaining or empty ladder decides nothing (the caller's bottom refuses)" do
      expect(lad(S::Silent.new("s")).call(:x).decided?).to be(false)
      expect(lad.call(:x).decided?).to be(false)
    end
    it "never reads a rung's own failure as an approval" do
      expect(poisoned(lad(S::Raiser.new("broken"), S::Allower.new("rule")))).not_to be_allow
    end
    it "honours a human allow over a fault when poisoning exempts human authority" do
      o = poisoned(lad(S::Raiser.new("broken"), S::Human.new("surfaces")), exempt: SpikeRungs::HumanExempt.new)
      expect([o.allow?, o.faulted?]).to eq([true, true])
    end
  end

  # Draws are flat ladders of 0..3 LEAVES; the operation nests.
  gen = -> { Spike::Ladder[*Array.new(rand(0..3)) { SpikeRungs::POOL.sample }] }

  describe "monoid A: nesting, poisoning applied once at the edge" do
    include_examples "a monoid",
                     operation: ->(a, b) { Spike::Ladder[a, b] },
                     identity: Spike::Ladder[],
                     generator: gen,
                     equal: ->(a, b) { observe(a) == observe(b) }
  end

  describe "monoid A': nesting, raw outcome (no poisoning at all)" do
    include_examples "a monoid",
                     operation: ->(a, b) { Spike::Ladder[a, b] },
                     identity: Spike::Ladder[],
                     generator: gen,
                     equal: ->(a, b) { observe_raw(a) == observe_raw(b) }
  end

  describe "monoid B: poisoning inside every ladder (RuleChain's shape)" do
    include_examples "a monoid",
                     operation: ->(a, b) { Spike::Poisoning.new(ladder: Spike::Ladder[a, b]) },
                     identity: Spike::Poisoning.new(ladder: Spike::Ladder[]),
                     generator: -> { Spike::Poisoning.new(ladder: gen.call) },
                     equal: ->(a, b) { observe_raw(a) == observe_raw(b) }
  end

  describe "the real RuleChain, hand witnesses" do
    let(:call) { Lain::Approval::Rule::Call.for(tool: Lain::Tools::ReadFile.new, input: { "path" => "README.md" }) }
    let(:rc) { Lain::Approval::RuleChain }
    def deleg(inner) = RuleChainSpecSupport::Delegating.new(inner)

    it "is NOT associative under eager poisoning: ((R A) D) denies, (R A D) escalates" do
      r = RuleChainSpecSupport::Raiser.new
      a = RuleChainSpecSupport::Allower.new
      d = RuleChainSpecSupport::Denier.new
      flat = rc.new([r, a, d]).decide(call)
      left = rc.new([deleg(rc.new([r, a])), d]).decide(call)
      right = rc.new([r, deleg(rc.new([a, d]))]).decide(call)
      summary = ->(x) { [x.class.name.split("::").last, x.deny?, x.allow?] }
      puts "  flat=#{summary[flat]} left=#{summary[left]} right=#{summary[right]}"
      expect(summary[left]).not_to eq(summary[right])
    end

    it "loses the fault RECORD when the inner chain has no recorder (outcome still equal)" do
      flat_rec = RuleChainSpecSupport::Recorder.new
      nest_rec = RuleChainSpecSupport::Recorder.new
      r = RuleChainSpecSupport::Raiser.new
      a = RuleChainSpecSupport::Allower.new
      flat = rc.new([r, a], faults: flat_rec).decide(call)
      nest = rc.new([deleg(rc.new([r])), a], faults: nest_rec).decide(call)
      puts "  flat recorded=#{flat_rec.faults.size} nested recorded=#{nest_rec.faults.size}"
      expect([flat.allow?, flat.faulted?]).to eq([nest.allow?, nest.faulted?])
      expect(flat_rec.faults.size).not_to eq(nest_rec.faults.size)
    end
  end

  describe "Sensitivity strictest is a join, not a ladder" do
    V = Data.define(:level, :reason) do
      def denied? = level == :denied
      def ordinary? = level == :ordinary
    end
    def strictest(vs) = vs.find(&:denied?) || vs.find { !_1.ordinary? } || vs.first
    def ladder_of(vs) = Spike::Ladder[*vs.map { |v| ->(_) { v.ordinary? ? Spike::ABSTAIN : v } }]

    it "disagrees with the first-decisive fold on [gated, denied]" do
      vs = [V.new(:gated, "a"), V.new(:denied, "b")]
      expect(strictest(vs).level).to eq(:denied)
      expect(ladder_of(vs).call(:x).decision.level).to eq(:gated)
    end

    it "equals leftmost-max over level, which is associative" do
      rank = %i[ordinary gated denied]
      lmax = ->(x, y) { rank.index(y.level) > rank.index(x.level) ? y : x }
      vals = rank.product(%w[p q]).map { V.new(*_1) }
      vals.repeated_permutation(3).each do |a, b, c|
        expect(lmax[lmax[a, b], c]).to eq(lmax[a, lmax[b, c]])
        expect(strictest([a, b, c])).to eq([a, b, c].reduce(&lmax))
      end
    end
  end
end
