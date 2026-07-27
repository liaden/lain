# frozen_string_literal: true

# Both siblings are real, landed, in-tree constants -- T6
# (`Compaction::Strategy::Summarizing`) and T7 (`Compaction::Strategy::Elide`)
# -- so this spec runs against them directly, no `stub_const`. A stub that
# shadows a real constant would keep standing in forever and report green
# about a class it never touches, which is exactly the failure mode a prior
# review round of this card found (a stubbed `#oracle` reader the real class
# does not have). `Summarizing` exposes no `#oracle`/`#sink` reader by design
# (holding a live oracle is the whole point, and it is what the purity
# refutation in its own file rests on), so every assertion below that needs
# to see what a resolved strategy holds reaches the ivar directly.
RSpec.describe Lain::CLI::CompactionStrategy do
  # A tier FACTORY, `->(definition) { live tier }` -- the shape
  # {Lain::CLI::CompactionStrategy} requires, never a pre-built tier. Answers
  # through whatever definition it is HANDED, exactly as the real
  # {Lain::Oracle::Model} would, so a spec that captures the definition it was
  # called with can assert it is the SAME one {Compaction::Strategy::
  # Summarizing.definition} answers (B1: the bug this fixture exists to catch
  # was two DIFFERENT definitions -- one built here, one the tier actually
  # answered through -- landing under two different oracle_digests).
  def tier_factory(summary: "a span, summarized", calls: nil)
    lambda do |definition|
      calls << definition if calls
      Class.new do
        define_method(:ask) { |*| definition.answer("summary" => summary) }
        define_method(:model) { "test-model" }
        define_method(:usage) { {} }
      end.new
    end
  end

  def resolve(name = nil, **) = described_class.resolve(name, **)

  describe "the default" do
    it "resolves to the summarizing strategy" do
      expect(resolve(tier: tier_factory)).to be_a(Lain::Compaction::Strategy::Summarizing)
    end
  end

  describe "the elide option" do
    it "is the real elision strategy, and needs no tier and writes no journal record" do
      journal = []
      calls = []

      strategy = resolve("elide", tier: tier_factory(calls:), journal:)

      expect(strategy).to be_a(Lain::Compaction::Strategy::Elide)
      expect(calls).to be_empty
      expect(journal).to be_empty
    end
  end

  describe "an unrecognized strategy option" do
    it "is refused by name, listing the valid set" do
      expect { resolve("nope") }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /--compact-strategy "nope".*summarizing.*elide/m)
    end
  end

  describe "the summarizing strategy's oracle" do
    it "is resolved with a recorded oracle, never a bare model tier" do
      strategy = resolve(tier: tier_factory, journal: [])

      held = strategy.instance_variable_get(:@oracle)
      expect(held).to be_a(Lain::Oracle::Recorded::Journaling)
      expect(held).not_to be_a(Lain::Oracle::Model)
    end

    it "wraps the SAME definition the tier itself answers through" do
      received = nil
      tier = lambda do |definition|
        received = definition
        tier_factory.call(definition)
      end

      resolve(tier:, journal: [])

      expect(received.digest).to eq(Lain::Compaction::Strategy::Summarizing.definition.digest)
    end

    it "records its answers" do
      journal = []
      strategy = resolve(tier: tier_factory(summary: "the span in short"), journal:)

      strategy.instance_variable_get(:@oracle).ask(source: "a span of chat")

      expect(journal.size).to eq(1)
      expect(journal.first).to be_a(Lain::Telemetry::OracleAnswer)
      expect(journal.first.answer).to eq("summary" => "the span in short")
    end

    it "threads sink: through to the summarizing strategy" do
      sink = Lain::Sink::Null.new
      strategy = resolve(tier: tier_factory, sink:)

      expect(strategy.instance_variable_get(:@sink)).to equal(sink)
    end

    it "refuses to build the summarizing strategy with no tier: given" do
      expect { resolve }
        .to raise_error(Lain::CLI::CompactionStrategy::MissingTier, /CompactionStrategy\.resolve needs tier:/)
    end

    # B3: `resolve(tier: ->(definition) { Oracle::Recorded.from_journal(entries, definition:) })`
    # used to resolve cleanly and then die on the RENDER path -- at the first
    # span, inside Oracle::Recorded::Journaling#ask reading `inner.model` --
    # with an uncontained NoMethodError, since Summarizing#asked only rescues
    # Lain::Error. Refused HERE instead, naming what is missing, against the
    # REAL Oracle::Recorded class (not a double), the exact shape the bug
    # report found.
    it "refuses a tier: factory that builds a replay-only tier, naming what it does not answer" do
      replay = ->(definition) { Lain::Oracle::Recorded.from_journal([], definition:) }

      expect { resolve(tier: replay, journal: []) }
        .to raise_error(Lain::CLI::CompactionStrategy::IncompleteTier, /model.*usage/m)
    end

    it "never reaches Oracle::Recorded::Journaling with an incomplete tier" do
      ask_only = ->(_definition) { Class.new { def ask(*) = nil }.new }

      expect { resolve(tier: ask_only, journal: []) }.to raise_error(Lain::CLI::CompactionStrategy::IncompleteTier)
    end
  end

  describe "the exhaustiveness guard" do
    it "raises Unbuilt, not Unknown, for a validated name with no matching branch -- a bug here, not a bad flag" do
      strategy = described_class.new("summarizing", tier: tier_factory)
      allow(strategy).to receive(:strategy_name).and_return("plan-step")

      expect { strategy.strategy }
        .to raise_error(Lain::CLI::CompactionStrategy::Unbuilt, /"plan-step".*no branch here builds it/)
    end
  end
end
