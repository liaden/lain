# frozen_string_literal: true

require "json"

# Histories, replay strategies and journalled edges, built by a module rather
# than by `let`s for the reason spec/lain/compaction/derivation_spec.rb records:
# several examples build two edges and two strategies inside one body, and a
# `let` chain would make "the pure one and the impure one" read as two separate
# fixtures rather than as the two halves of one comparison.
module DerivationAuditFixtures
  module_function

  KEEP_LAST = 4

  def text(body) = { "type" => "text", "text" => body }

  def history(size, store: Lain::Store.new, tag: "turn")
    (0...size).inject(Lain::Timeline.empty(store:)) do |timeline, index|
      timeline.commit(role: index.even? ? "user" : "assistant", content: [text("#{tag} #{index}")])
    end
  end

  # A replay tier keyed on the QUESTION, as {Lain::Oracle::Recorded} is
  # (`recorded.rb:73-78`), and raising {Lain::Oracle::Recorded::Unrecorded} on a
  # miss exactly as that class does. It answers ONLY #ask, which is the replay
  # shape: {Lain::CLI::CompactionStrategy} refuses to build one (it validates
  # the live tier's #ask/#model/#usage trio), so a replay strategy is built
  # directly against {Lain::Compaction::Strategy::Summarizing.definition}.
  class Answering
    def initialize(definition:, &lookup)
      @definition = definition
      @lookup = lookup
    end

    def ask(inputs = {})
      summary = @lookup.call(@definition.render(inputs))
      raise Lain::Oracle::Recorded::Unrecorded, "no recorded answer for this question" if summary.nil?

      @definition.answer("summary" => summary)
    end
  end

  # Collapses the whole span and counts how often it was asked, which is how the
  # memo is observed without stubbing a frozen object (Elide freezes itself).
  # The registry says nothing about it either way, which is the third purity
  # state and a different thing from being refuted.
  class Counting < Lain::Compaction::Strategy::Base
    attr_reader :asked

    def initialize
      super
      @asked = 0
    end

    def propose_ranges(_messages, span:)
      @asked += 1
      [span]
    end

    def blocks(_messages) = [{ "type" => "text", "text" => "collapsed" }]
  end

  # Inherits a #blocks that IS declared pure. {Lain::Algebra::Registry#declares?}
  # matches on the exact subject, so the registry makes no claim about THIS
  # class -- the trap that makes a two-valued purity question wrong.
  class ElideChild < Lain::Compaction::Strategy::Elide; end

  # Collapses the whole span, or nothing at all, so a replay can propose a
  # DIFFERENT range at the very same window. The registry says nothing about it.
  class Selective < Lain::Compaction::Strategy::Base
    def initialize(collapsing:)
      super()
      @collapsing = collapsing
    end

    def propose_ranges(_messages, span:) = @collapsing ? [span] : []

    def blocks(_messages) = [{ "type" => "text", "text" => "collapsed" }]
  end

  def elide = Lain::Compaction::Strategy::Elide.new

  def counting = Counting.new

  def summarizing(&lookup)
    definition = Lain::Compaction::Strategy::Summarizing.definition
    Lain::Compaction::Strategy::Summarizing.new(oracle: Answering.new(definition:, &lookup))
  end

  # The journalled edge a real derivation writes -- never a hand-built Hash, so
  # the audit is read against the record the production path actually emits.
  def edge(strategy, source, keep_last: KEEP_LAST)
    journal = []
    Lain::Compaction::Derivation.new(strategy:, keep_last:, journal:).derive(source)
    journal.fetch(0).to_journal
  end

  # The `strategies:` duck: the journalled name mapped to a BUILDER, which
  # answers a fresh strategy per record.
  def replaying(record, &builder) = { record.fetch("strategy") => builder }
end

RSpec.describe Lain::Compaction::DerivationAudit do
  let(:fixtures) { DerivationAuditFixtures }
  let(:store) { Lain::Store.new }
  let(:source) { fixtures.history(12, store:) }

  def audit(entries, strategies:, keep_last: DerivationAuditFixtures::KEEP_LAST, **rest)
    described_class.new(entries:, store:, strategies:, keep_last:, **rest)
  end

  def eliding(record) = fixtures.replaying(record) { fixtures.elide }

  describe "a re-derivation that matches its record" do
    it "reports agreement, naming the derived head" do
      record = fixtures.edge(fixtures.elide, source)
      audited = audit([record], strategies: eliding(record))

      expect(audited.map(&:agreed?)).to eq([true])
      expect(audited.first.derived_head).to eq(record.fetch("derived_head"))
      expect(audited.first.notice).to include(record.fetch("derived_head"))
    end

    it "agrees over the whole journal, which no empty journal can" do
      record = fixtures.edge(fixtures.elide, source)

      expect(audit([record], strategies: eliding(record))).to be_agreed
      expect(audit([], strategies: eliding(record))).not_to be_agreed
    end

    it "reads a record equally as a parsed Hash and as the NDJSON line it was written as" do
      record = fixtures.edge(fixtures.elide, source)

      expect(audit([record], strategies: eliding(record)).map(&:agreed?)).to eq([true])
      expect(audit([record.to_json], strategies: eliding(record)).map(&:agreed?)).to eq([true])
    end
  end

  describe "a record that is not the shape it claims" do
    it "refuses to read a bare type tag as an agreement about nothing" do
      # `nil == nil` is not "a rebuild reproduced these bytes". The Journal's fd
      # is shared with foreign writers, so this line will happen.
      bare = { "type" => "context_derived", "strategy" => fixtures.elide.name }
      finding = audit([bare], strategies: fixtures.replaying(bare) { fixtures.elide }).first

      expect(finding.agreed?).to be(false)
      expect(finding.notice).to include("cut").and include("names no source head")
    end

    it "reports every incomplete record as unverifiable rather than judging it" do
      record = fixtures.edge(fixtures.elide, source)
      %w[cut spans strategy source_head derived_head].each do |field|
        maimed = record.reject { |key, _| key == field }
        finding = audit([maimed], strategies: eliding(record)).first

        expect(finding.agreed?).to be(false), "#{field} removed, yet the audit agreed"
        expect(finding.notice).to include(field).or include("must")
      end
    end

    it "refuses a head no derivation could have written, rather than accusing the strategy of it" do
      record = fixtures.edge(fixtures.elide, source)
      blank = audit([record.merge("derived_head" => "")], strategies: eliding(record)).first
      orphan = audit([record.merge("source_head" => nil)], strategies: eliding(record)).first

      expect(blank).not_to be_drifted
      expect(blank.notice).to include("not a digest")
      expect(orphan).not_to be_drifted
      expect(orphan.notice).to include("no source head at all")
    end

    it "reads a record carrying fields it has never heard of, since the record type is still growing" do
      record = fixtures.edge(fixtures.elide, source).merge("hits" => 3, "misses" => 1, "keep_last" => 4)

      expect(audit([record], strategies: eliding(record)).map(&:agreed?)).to eq([true])
    end

    it "treats a genuine empty-source edge as nothing to check, since it vouches for no bytes" do
      empty_store = Lain::Store.new
      record = fixtures.edge(fixtures.elide, Lain::Timeline.empty(store: empty_store))
      audited = described_class.new(entries: [record], store: empty_store, keep_last: 4,
                                    strategies: eliding(record))

      expect(record.slice("source_head", "derived_head", "cut"))
        .to eq({ "source_head" => nil, "derived_head" => nil, "cut" => :empty })
      expect(audited.first).to be_vacuous
      expect(audited).to be_nothing_to_check
      expect(audited).not_to be_agreed
    end
  end

  describe "a drift diagnosis" do
    it "calls a pure strategy's drift a derivation bug, and an impure one's an incomplete replay" do
      pure = fixtures.edge(fixtures.elide, source).merge("derived_head" => "blake3:not-the-head")
      impure = fixtures.edge(fixtures.summarizing { "what the run recorded" }, source)
                       .merge("derived_head" => "blake3:not-the-head")
      strategies = eliding(pure)
                   .merge(fixtures.replaying(impure) { fixtures.summarizing { "what the replay says" } })

      expect(audit([pure, impure], strategies:).map(&:diagnosis)).to eq(%i[derivation_bug incomplete_replay])
      expect(audit([pure, impure], strategies:).map(&:notice)).to all(include("blake3:not-the-head"))
    end

    it "refuses to call a strategy impure when the registry has made no claim about it" do
      record = fixtures.edge(fixtures.counting, source).merge("derived_head" => "blake3:not-the-head")
      finding = audit([record], strategies: fixtures.replaying(record) { fixtures.counting }).first

      expect(Lain::Algebra.registry.about(DerivationAuditFixtures::Counting)).to be_empty
      expect(finding.diagnosis).to eq(:unclaimed_purity)
      expect(finding.notice).to include("no claim")
    end

    it "makes no claim about a subclass of a pure strategy, since a declaration names one exact class" do
      record = fixtures.edge(DerivationAuditFixtures::ElideChild.new, source)
                       .merge("derived_head" => "blake3:not-the-head")
      strategies = fixtures.replaying(record) { DerivationAuditFixtures::ElideChild.new }

      expect(DerivationAuditFixtures::ElideChild.new).to be_a(Lain::Compaction::Strategy::Elide)
      expect(Lain::Algebra.registry.about(DerivationAuditFixtures::ElideChild)).to be_empty
      expect(audit([record], strategies:).first.diagnosis).to eq(:unclaimed_purity)
    end

    it "asks the registry it was given, which is what makes the registry the classification" do
      scratch = Lain::Algebra::Registry.new
      scratch.declare(subject: DerivationAuditFixtures::Counting, operation: :blocks, structure: :pure)
      record = fixtures.edge(fixtures.counting, source).merge("derived_head" => "blake3:not-the-head")
      strategies = fixtures.replaying(record) { fixtures.counting }

      expect(audit([record], strategies:).first.diagnosis).to eq(:unclaimed_purity)
      expect(audit([record], strategies:, registry: scratch).first.diagnosis).to eq(:derivation_bug)
    end

    it "blames the derivation whatever the strategy is, when no span was ever offered" do
      # keep_last covers the whole history, so the boundary offers nothing and
      # `cut` is :empty -- the strategy was never asked, so its purity cannot be
      # what a drift is about.
      record = fixtures.edge(fixtures.summarizing { "a summary" }, source, keep_last: 99)
                       .merge("derived_head" => "blake3:not-the-head")
      strategies = fixtures.replaying(record) { fixtures.summarizing { "a different summary" } }

      expect(record.fetch("cut")).to eq(:empty)
      expect(audit([record], strategies:, keep_last: 99).map(&:diagnosis)).to eq([:derivation_bug])
    end
  end

  describe "an audit run at the wrong keep_last" do
    it "says the window disagrees rather than crying derivation bug at its own configuration" do
      record = fixtures.edge(fixtures.elide, source)
      finding = audit([record], strategies: eliding(record), keep_last: 5).first

      expect(finding).to be_drifted
      expect(finding.diagnosis).to eq(:window_disagrees)
      expect(finding.notice).to include("keep_last")
    end

    it "still calls a genuinely tampered head a derivation bug at the right window" do
      record = fixtures.edge(fixtures.elide, source).merge("derived_head" => "blake3:tampered")

      expect(audit([record], strategies: eliding(record)).first.diagnosis).to eq(:derivation_bug)
    end

    it "leaves both causes open when an impure strategy collapsed different ranges" do
      # These two are genuinely indistinguishable, and the audit must not pick.
      # A wrong window changes the span, hence the question, hence the content
      # address -- so a FAITHFUL question-keyed replay misses on it and proposes
      # no range, exactly as a replay short an answer does at the right window.
      asked = []
      record = fixtures.edge(fixtures.summarizing { |question| asked << question and "what the run recorded" },
                             source)
      faithful = fixtures.replaying(record) do
        fixtures.summarizing { |question| "what the run recorded" if asked.include?(question) }
      end

      expect(audit([record], strategies: faithful, keep_last: 5).first.diagnosis).to eq(:window_or_replay)
      expect(audit([record], strategies: fixtures.replaying(record) { fixtures.summarizing { nil } })
               .first.diagnosis).to eq(:window_or_replay)
      expect(audit([record], strategies: faithful).first).to be_agreed
    end

    it "names both causes rather than one, since the record cannot tell them apart" do
      record = fixtures.edge(fixtures.summarizing { "what the run recorded" }, source)
      notice = audit([record], strategies: fixtures.replaying(record) { fixtures.summarizing { nil } })
               .first.notice

      expect(notice).to include("keep_last").and include("replay")
    end

    it "does not send a reader after a keep_last that was right, when the registry has made no claim" do
      # Registry silence must not be read as "pure" either: a strategy the
      # registry says nothing about, at the CORRECT window, proposing a
      # different range, is an unattributable drift and not a window error.
      record = fixtures.edge(DerivationAuditFixtures::Selective.new(collapsing: true), source)
      strategies = fixtures.replaying(record) { DerivationAuditFixtures::Selective.new(collapsing: false) }

      expect(Lain::Algebra.registry.about(DerivationAuditFixtures::Selective)).to be_empty
      expect(audit([record], strategies:).first.diagnosis).to eq(:unclaimed_purity)
    end
  end

  describe "a re-derivation that drifts" do
    it "reports disagreement, naming the recorded head and the re-derived one" do
      record = fixtures.edge(fixtures.summarizing { "what the run recorded" }, source)
      strategies = fixtures.replaying(record) { fixtures.summarizing { "what the replay answers now" } }
      finding = audit([record], strategies:).first

      expect(finding).to be_drifted
      expect(finding.recorded).to eq(record.fetch("derived_head"))
      expect(finding.rederived).not_to eq(finding.recorded)
      expect(finding.notice).to include(finding.recorded).and include(finding.rederived)
    end
  end

  describe "a journal with no derivation records" do
    it "reports nothing to check rather than agreement" do
      entries = [{ "type" => "turn_usage", "digest" => "blake3:whatever" }]
      audited = audit(entries, strategies: {})

      expect(audited).to be_nothing_to_check
      expect(audited).not_to be_agreed
      expect(audited.to_a).to be_empty
    end
  end

  describe "foreign and malformed journal lines" do
    it "skips them rather than treating either as fatal" do
      record = fixtures.edge(fixtures.elide, source)
      entries = [{ "type" => "turn_usage", "digest" => "blake3:whatever" }.to_json,
                 "{ this line is not JSON at all", record.to_json, "[1, 2, 3]", "42"]

      audited = audit(entries, strategies: eliding(record))
      expect { audited.to_a }.not_to raise_error
      expect(audited.map(&:agreed?)).to eq([true])
    end
  end

  describe "an edge naming a source head the store does not hold" do
    it "reports it as unverifiable, naming the missing digest" do
      record = fixtures.edge(fixtures.elide, fixtures.history(12))
      elsewhere = described_class.new(entries: [record], store: Lain::Store.new,
                                      strategies: eliding(record), keep_last: 4)
      finding = elsewhere.first

      expect(finding.agreed?).to be(false)
      expect(finding.drifted?).to be(false)
      expect(finding.notice).to include(record.fetch("source_head"))
      expect(elsewhere).not_to be_nothing_to_check
    end
  end

  describe "an edge whose strategy cannot be replayed by name" do
    it "reports it as unverifiable, naming the strategy the record carries" do
      anonymous = Class.new(Lain::Compaction::Strategy::Base) do
        def propose_ranges(_messages, span:) = [span]

        def blocks(_messages) = [{ "type" => "text", "text" => "collapsed" }]
      end.new
      record = fixtures.edge(anonymous, source)

      finding = audit([record], strategies: {}).first
      expect(record.fetch("strategy")).to eq("(anonymous strategy)")
      expect(finding.agreed?).to be(false)
      expect(finding.notice).to include("(anonymous strategy)")
    end
  end

  describe "a strategies map that answers something unusable" do
    it "refuses a value that is not a builder, naming the journalled name and what it got" do
      record = fixtures.edge(fixtures.elide, source)
      strategies = { record.fetch("strategy") => fixtures.elide }

      expect { audit([record], strategies:).to_a }
        .to raise_error(described_class::NotAStrategy, /#{Regexp.escape(record.fetch("strategy"))}.*#call/m)
    end

    it "refuses a builder that answers something which is not a strategy" do
      record = fixtures.edge(fixtures.elide, source)
      strategies = fixtures.replaying(record) { Object.new }

      expect { audit([record], strategies:).to_a }.to raise_error(described_class::NotAStrategy, /ranges/)
    end
  end

  describe "a re-derivation that cannot complete" do
    it "reports the refusal as unverifiable rather than letting it escape" do
      refusing = Class.new(Lain::Compaction::Strategy::Base) do
        def propose_ranges(_messages, span:) = [span.first..(span.max + 40)]

        def blocks(_messages) = [{ "type" => "text", "text" => "collapsed" }]
      end
      record = fixtures.edge(fixtures.elide, source)

      finding = audit([record], strategies: fixtures.replaying(record) { refusing.new }).first
      expect(finding.agreed?).to be(false)
      expect(finding.notice).to include("NotAPartition")
    end
  end

  describe "a journal holding several records for one model-backed strategy" do
    let(:records) do
      [fixtures.edge(fixtures.summarizing { "summary of alpha" }, fixtures.history(12, store:, tag: "alpha")),
       fixtures.edge(fixtures.summarizing { "summary of beta" }, fixtures.history(13, store:, tag: "beta"))]
    end

    # What a real replay builder looks like: it rebuilds its whole answer source
    # per record ({Lain::Oracle::Recorded.from_journal} over the journal), so
    # which record is judged first cannot matter.
    def replaying(records, built: [])
      fixtures.replaying(records.first) do
        fixtures.summarizing { |question| question.include?("alpha") ? "summary of alpha" : "summary of beta" }
                .tap { |strategy| built << strategy }
      end
    end

    it "builds a fresh strategy per record, since a replay strategy is stateful by design" do
      built = []

      audit(records, strategies: replaying(records, built:)).to_a
      expect(built.size).to eq(2)
      expect(built.first).not_to equal(built.last)
    end

    it "judges each record against its own recorded answer" do
      expect(audit(records, strategies: replaying(records)).map(&:agreed?)).to eq([true, true])
    end

    it "does not let a record it skipped shift the record after it" do
      # The first record's source is absent here, so it is skipped -- and the
      # second must still be judged exactly as it would have been alone.
      partial = Lain::Store.new
      fixtures.history(13, store: partial, tag: "beta")
      audited = described_class.new(entries: records, store: partial, keep_last: 4,
                                    strategies: replaying(records))

      expect(audited.map(&:agreed?)).to eq([false, true])
      expect(audited.first).not_to be_drifted
    end
  end

  describe "the store the audit was handed" do
    it "grows by a dead chain per disagreeing record, and not at all when the records agree" do
      record = fixtures.edge(fixtures.elide, source)
      before = store.size

      audit([record], strategies: eliding(record)).to_a
      settled = store.size
      audit([record], strategies: eliding(record), keep_last: 5).to_a

      expect(settled).to eq(before)
      expect(store.size).to be > settled
    end
  end

  describe "a finding" do
    let(:absent) { fixtures.edge(fixtures.elide, source).merge("source_head" => "blake3:absent") }
    let(:mixed) do
      [fixtures.edge(fixtures.elide, source),
       fixtures.edge(fixtures.elide, source).merge("derived_head" => "blake3:not-the-head"),
       absent,
       fixtures.edge(fixtures.elide, Lain::Timeline.empty(store: Lain::Store.new))]
    end

    it "answers one duck whichever verdict it carries, so no caller type-checks" do
      audited = audit(mixed, strategies: eliding(absent))

      expect(audited.map(&:class).uniq.size).to eq(4)
      %i[agreed? drifted? vacuous? checkable? diagnosis recorded rederived derived_head reason strategy
         source_head notice].each { |message| expect(audited).to all(respond_to(message)) }
    end

    it "is deeply frozen, so an audit's answers carry no reachable mutable state" do
      audited = audit(mixed, strategies: eliding(absent))

      expect(audited.map { |finding| Ractor.shareable?(finding) }).to eq([true, true, true, true])
    end
  end

  describe "the audit itself" do
    it "opens no file and is no part of a render path" do
      expect(described_class.instance_methods(false)).not_to include(:call)
      expect(File).not_to receive(:open)
      expect(File).not_to receive(:foreach)

      record = fixtures.edge(fixtures.elide, source)
      audit([record], strategies: eliding(record)).to_a
    end

    it "re-derives once per record, however often the findings are read" do
      # A counting strategy rather than a message expectation: {Lain::Compaction::Strategy::Elide}
      # freezes itself, and rspec-mocks cannot proxy a frozen object.
      strategy = fixtures.counting
      record = fixtures.edge(strategy, source)
      audited = audit([record], strategies: fixtures.replaying(record) { strategy })

      4.times { audited.to_a }
      expect(strategy.asked).to eq(2)
    end
  end
end
