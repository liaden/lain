# frozen_string_literal: true

require "stringio"

# Histories, spans and oracle tiers, built by a module rather than by `let`s for
# the reason spec/lain/compaction/strategy_spec.rb records: the law groups below
# are included in a GROUP BODY, where no `let` exists yet, and a fixture that
# existed in two forms would be two fixtures.
module SummarizingFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def message(body, role: "user") = { "role" => role, "content" => [text(body)] }

  # `user` on even indices -- a real conversation slice, and the shape
  # {Lain::Context::Conversation} accepts once a `user` replacement is put in
  # front of it.
  def span(size) = Array.new(size) { |index| message("turn #{index}", role: index.even? ? "user" : "assistant") }

  # Sizes fixed, so a draw cannot certify nothing by accident; the empty span is
  # in the draw because DROP is the unit the homomorphism law reads.
  def spans = [0, 1, 2, 3].map { |size| span(size) }

  def history(size, store: Lain::Store.new)
    (0...size).inject(Lain::Timeline.empty(store:)) do |timeline, index|
      timeline.commit(role: index.even? ? "user" : "assistant", content: [text("turn #{index}")])
    end
  end

  def definition = Lain::Compaction::Strategy::Summarizing.definition

  # One scripted model reply, in the answer schema's own shape. Mock repeats its
  # last response once exhausted, so one is enough however many times a span is
  # asked about -- and `requests.size` then counts the model calls exactly.
  def provider(summary = "the span, summarized")
    reply = Lain::Response.new(content: [text(%({"summary":#{summary.to_json}}))], stop_reason: :end_turn,
                               usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
    Lain::Provider::Mock.new(responses: [reply])
  end

  # The mandated tier: a live model wrapped in the journalling half of the
  # record/replay pair, so every answer lands in the Journal that
  # {Lain::Oracle::Recorded.from_journal} replays.
  def recording(provider:, journal: Lain::Channel::Null.instance)
    tier = Lain::Oracle::Model.new(definition:, provider:, model: "test-model")
    Lain::Oracle::Recorded::Journaling.new(inner: tier, definition:, journal:)
  end

  def replaying(io) = Lain::Oracle::Recorded.from_journal(io.string.each_line, definition:)

  def strategy(oracle:, sink: Lain::Sink::Null.new)
    Lain::Compaction::Strategy::Summarizing.new(oracle:, sink:)
  end

  # A strategy over a scripted tier, for the law group below: `include_examples`
  # runs in a group body, where no `let` exists yet.
  def deterministic = strategy(oracle: recording(provider:))

  # A tier that is down. `Unrecorded` is the real one a replay hits, and it is a
  # {Lain::Error} -- which is the family the strategy contains, and deliberately
  # not `StandardError`.
  def failing(error: Lain::Oracle::Recorded::Unrecorded.new("no recorded answer"))
    Class.new { define_method(:ask) { |_inputs| raise error } }.new
  end

  # A tier answering one fixed summary. A BLANK one cannot be built from the
  # real {Lain::Oracle::Summarize::SCHEMA} -- `required: true` is a presence
  # check, so a blank answer never validates -- which is exactly why this double
  # stands in for a tier whose validation is looser than ours.
  def answering(body)
    answer = Struct.new(:summary).new(body)
    Class.new { define_method(:ask) { |_inputs| Lain::Promise.new.tap { |promise| promise.resolve(answer) } } }.new
  end
end

RSpec.describe Lain::Compaction::Strategy::Summarizing do
  let(:fixtures) { SummarizingFixtures }
  let(:provider) { fixtures.provider }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:oracle) { fixtures.recording(provider:, journal:) }
  let(:strategy) { fixtures.strategy(oracle:) }
  let(:span) { fixtures.span(4) }

  describe "collapsing a span nobody has summarized" do
    it "asks the oracle once and carries its summary into the replacement" do
      ranges = strategy.ranges(span, span: 0..3)

      expect(ranges).to eq([0..3])
      expect(strategy.collapse(span).content).to eq([fixtures.text("the span, summarized")])
      expect(provider.requests.size).to eq(1)
    end

    it "answers the unit for a span with nothing in it, without asking at all" do
      expect(strategy.collapse([])).to be(Lain::Compaction::Strategy::DROP)
      expect(provider.requests).to be_empty
    end
  end

  describe "collapsing a span whose answer is already recorded" do
    # The range is still OFFERED. Skipping an already-summarized range is the
    # shape the panel refused: it means the history stops shrinking after the
    # first compaction. What "only summarize what is new" buys is that asking
    # costs nothing, and {Lain::Oracle::Recorded} delivers exactly that.
    it "still offers the range, carries the recorded summary, and makes no model call" do
      fixtures.strategy(oracle: fixtures.recording(provider:, journal:)).collapse(span)
      replay = fixtures.strategy(oracle: fixtures.replaying(journal_io))

      expect(replay.ranges(span, span: 0..3)).to eq([0..3])
      expect(replay.collapse(span).content).to eq([fixtures.text("the span, summarized")])
      expect(provider.requests.size).to eq(1)
    end
  end

  describe "the question a range asks" do
    it "re-derives byte-identically for an unchanged range" do
      expect(strategy.question(span)).to eq(strategy.question(fixtures.span(4)))
    end

    it "differs for a range whose content changed" do
      changed = span.dup
      changed[2] = fixtures.message("something else")

      expect(strategy.question(changed)).not_to eq(strategy.question(span))
    end

    # The key and the question are two readings of ONE set of canonical bytes,
    # which is what stops a well-formed but wrongly-keyed address from missing
    # every lookup in silence.
    it "keys the range on the content address of those same bytes" do
      expect(strategy.whole_span(span)).to eq(Lain::Canonical.digest(span))
      expect(strategy.whole_span(span)).not_to eq(strategy.whole_span(fixtures.span(3)))
    end
  end

  describe "re-deriving from the journalled answer" do
    it "produces the same derived head digest, with no further model call" do
      source = fixtures.history(9)
      derivation = ->(tier) { Lain::Compaction::Derivation.new(strategy: fixtures.strategy(oracle: tier), keep_last: 3) }

      first = derivation.call(fixtures.recording(provider:, journal:)).derive(source)
      second = derivation.call(fixtures.replaying(journal_io)).derive(source)

      expect(second.head_digest).to eq(first.head_digest)
      expect(provider.requests.size).to eq(1)
    end
  end

  describe "an answer it cannot use" do
    it "refuses a blank summary loudly rather than rendering an empty block" do
      ["", "   "].each do |blank|
        expect { fixtures.strategy(oracle: fixtures.answering(blank)).collapse(span) }
          .to raise_error(Lain::Compaction::Strategy::Blank)
      end
    end
  end

  # `Ractor.make_shareable` RAISES for a Proc with unshareable self, but a plain
  # object graph -- which this is -- is silently deep-frozen. So the enforcement
  # that catches {Context::Compact} holding an {Lain::Oracle::Eager}
  # (`summary_snapshot.rb:5-17`) does not catch this object, and the failure it
  # would otherwise have raised at composition time arrives at the NEXT new span
  # instead. Pinned as a defect rather than smoothed over: a memo that degraded
  # quietly when frozen would stop memoizing, and against a queue-consuming
  # {Lain::Oracle::Recorded} that is a range vanishing in silence, not a cost.
  describe "a strategy something has made shareable" do
    it "fails loudly on the next new span, outside the family it contains" do
      frozen = fixtures.strategy(oracle: fixtures.answering("held"))
      frozen.collapse(span)
      Ractor.make_shareable(frozen)

      expect { frozen.collapse(fixtures.span(2)) }.to raise_error(FrozenError)
      expect(Lain::Compaction::Strategy::Blank.ancestors).to include(Lain::Error)
      expect(FrozenError.ancestors).not_to include(Lain::Error)
    end
  end

  describe "an oracle that is down" do
    let(:sink) { StringIO.new }
    let(:down) { fixtures.strategy(oracle: fixtures.failing, sink:) }

    it "leaves the range uncollapsed and reports why" do
      expect(down.ranges(span, span: 0..3)).to be_empty
      expect(sink.string).to include(described_class.name, "Unrecorded")
    end

    it "does not take out the derivation: the source is derived through unchanged" do
      source = fixtures.history(9)
      derived = Lain::Compaction::Derivation.new(strategy: down, keep_last: 3).derive(source)

      expect(Lain::Compaction::Derivation.projected(derived.to_a))
        .to eq(Lain::Compaction::Derivation.projected(source.to_a))
    end
  end

  describe "the oracle it is addressed under" do
    # {Lain::Oracle::Definition#digest} folds the template as well as the tier,
    # so the span question is already a different oracle from the tool-result
    # one at the SAME tier -- which is why this reuses `:model` rather than
    # minting a symbol that would move every existing recorded address.
    it "is a different oracle from the eager tool-result summarizer at the same tier" do
      expect(described_class::TIER).to eq(:model)
      expect(fixtures.definition.digest).not_to eq(Lain::Oracle::Summarize.definition(tier: :model).digest)
    end

    it "validates its answers through the shape SummarySnapshot already reads" do
      expect(fixtures.definition.answer("summary" => "a summary").await.summary).to eq("a summary")
    end
  end

  describe "the two structures it deliberately is not" do
    def refutation(structure)
      Lain::Algebra.registry.refutations.find do |entry|
        entry.subject == described_class && entry.structure == structure
      end
    end

    it "refutes elementwise on the block operation, without including the concern" do
      expect(strategy).not_to be_a(Lain::Algebra::Elementwise)
      expect(refutation(:elementwise)&.operation).to eq(:blocks)
      expect(refutation(:elementwise).reason).not_to be_empty
    end

    it "refutes purity on the same operation, and holds an oracle rather than answering pure?" do
      expect(strategy).not_to be_a(Lain::Algebra::Pure)
      expect(Ractor.shareable?(strategy)).to be(false)
      expect(refutation(:pure)&.operation).to eq(:blocks)
    end

    it "leaves both of Base's questions owned by Base" do
      expect(%i[ranges collapse].map { |question| described_class.instance_method(question).owner })
        .to eq([Lain::Compaction::Strategy::Base] * 2)
    end
  end

  describe "held against the homomorphism law it is the negative of" do
    summarizing = SummarizingFixtures.deterministic
    drawn = SummarizingFixtures.spans

    include_examples "not a monoid homomorphism",
                     collapse: ->(messages) { summarizing.collapse(messages) },
                     unit: Lain::Compaction::Strategy::DROP,
                     spans: -> { drawn }
  end
end
