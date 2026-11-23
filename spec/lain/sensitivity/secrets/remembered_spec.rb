# frozen_string_literal: true

# A history whose stamps move only when a spec moves them, and whose value follows.
class RememberedSpecHistory
  Stamps = Data.define(:generation) do
    def unchanged_since?(earlier) = !earlier.nil? && earlier.generation == generation
  end

  def initialize = @generation = 0

  def move! = @generation += 1

  # The next read answers the current value, then the stamps move, as a file written while a set is built.
  def move_during_next_read! = @moving = true

  def stamps = Stamps.new(@generation)

  def to_a
    value = ["history-secret-value-#{@generation}"]
    if @moving
      @moving = false
      move!
    end
    value
  end

  def refusable = to_a

  def split = Lain::Sensitivity::HistoryLiterals::Split.new(known: to_a, refusable:)
end

RSpec.describe Lain::Sensitivity::Secrets::Remembered do
  let(:history) { RememberedSpecHistory.new }
  let(:env) { { "DB_PASSWORD" => "spec-db-password-24bytes" } }
  let(:source) { Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.from(env), history:) }
  let(:remembered) { described_class.new(source) }

  def context_lending(env) = Struct.new(:worker_env).new(Lain::WorkerEnv.new(cwd: Dir.pwd, env:))

  before { allow(Lain::Sensitivity::Secrets).to receive(:for).and_call_original }

  describe "#for" do
    it "answers what the source answers" do
      expect(remembered.for(nil)).to eq(source.for(nil))
    end

    it "builds once for 4 asks while nothing moved" do
      4.times { remembered.for(nil) }

      expect(Lain::Sensitivity::Secrets).to have_received(:for).once
    end

    it "builds again once the history's stamps move, and holds what it now lists" do
      remembered.for(nil)
      history.move!

      expect(remembered.for(nil)).to include("history-secret-value-1").and(not_include("history-secret-value-0"))
      expect(Lain::Sensitivity::Secrets).to have_received(:for).twice
    end

    it "builds again when the history moved while the set was being built" do
      history.move_during_next_read!
      remembered.for(nil)

      expect(remembered.for(nil)).to include("history-secret-value-1")
    end

    it "keeps at most its limit of sets, so the first of 1 more lent environment than that builds again" do
      lending = Array.new(described_class::LIMIT + 1) { context_lending("LENT_TOKEN" => "lent-value-#{_1}-padded") }
      lending.each { remembered.for(_1) }
      remembered.for(lending.first)

      expect(Lain::Sensitivity::Secrets).to have_received(:for).exactly(described_class::LIMIT + 2).times
    end

    it "builds again once the child environment changes" do
      remembered.for(nil)
      env["API_TOKEN"] = "later-token-value-7"

      expect(remembered.for(nil)).to include("later-token-value-7")
    end

    it "keeps 1 set per lent environment, so 2 subagents never share one" do
      first = context_lending("LENT_TOKEN" => "first-lent-value-1")
      second = context_lending("LENT_TOKEN" => "second-lent-value-2")
      2.times { [first, second].each { remembered.for(_1) } }

      expect([remembered.for(first), remembered.for(second)])
        .to match([include("first-lent-value-1").and(not_include("second-lent-value-2")),
                   include("second-lent-value-2").and(not_include("first-lent-value-1"))])
      expect(Lain::Sensitivity::Secrets).to have_received(:for).twice
    end
  end

  describe "#for_reads" do
    it "answers what the source answers, kept apart from #for" do
      2.times { [remembered.for(nil), remembered.for_reads(nil)] }

      expect(Lain::Sensitivity::Secrets).to have_received(:for).twice
      expect(remembered.for_reads(nil)).to eq(source.for_reads(nil))
    end
  end

  it "reads to_a as #for with no context" do
    expect(remembered.to_a).to eq(source.for(nil))
  end

  it "hands on the source's history, child environment and egress split" do
    expect([remembered.history, remembered.child_env, remembered.egress.refused])
      .to match([be(history), be(source.child_env), eq(source.egress.refused)])
  end
end
