# frozen_string_literal: true

require "stringio"

# Histories, spans and oracle tiers, built by a module rather than by `let`s for
# the reason spec/lain/compaction/strategy_spec.rb records: a fixture reached
# from a group body, where no `let` exists yet, would otherwise have to exist in
# two forms and then be two fixtures.
#
# The message shapes are ported from ComposedFixtures rather than re-derived --
# `spec/lain/compaction/strategy/composed_spec.rb:30-47` is where the working
# `elide | summarize` hybrid first proved out, and the span below is its
# `mixed_history` shape, so the two files describe the same conversation.
module SummarizeConversationFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  # Roles alternate by index, so a `tool_use` is always the assistant's and its
  # answer always the user's -- the shape a real transcript has, and the one
  # spec/lain/compaction/derivation_spec.rb builds.
  def messages(blocks)
    blocks.each_with_index.map do |content, index|
      { "role" => index.even? ? "user" : "assistant", "content" => content }
    end
  end

  def history(blocks, store: Lain::Store.new)
    blocks.each_with_index.inject(Lain::Timeline.empty(store:)) do |timeline, (content, index)|
      timeline.commit(role: index.even? ? "user" : "assistant", content:)
    end
  end

  # One LONE conversational turn, two tool rounds, and two conversational runs
  # long enough to be worth a call:
  #
  #   0 lone | 1-2 tool | 3-4 conv | 5-6 tool | 7-10 conv
  #
  # The opening turn's body is unmistakable on purpose: the oracle must never
  # see it, and an example asserts exactly that by looking for the string.
  def mixed_blocks
    [[text("lone opening")], [tool_use(0)], [tool_result(0)],
     [text("so")], [text("then")], [tool_use(1)], [tool_result(1)],
     [text("ok")], [text("more")], [text("and")], [text("last")]]
  end

  def mixed = messages(mixed_blocks)

  # Fifteen messages, so that with `keep_last: 3` TWO conversational runs still
  # fall inside the droppable span. One run would let the re-derivation example
  # pass on a single replayed answer, which is a weaker claim than the card
  # makes.
  #
  #   0 lone | 1-2 tool | 3-4 conv | 5-6 tool | 7-8 conv | 9-10 tool | 11 lone | 12-14 tail
  def long_blocks
    [[text("lone opening")], [tool_use(0)], [tool_result(0)],
     [text("so")], [text("then")], [tool_use(1)], [tool_result(1)],
     [text("ok")], [text("next")], [tool_use(2)], [tool_result(2)],
     [text("lone middle")], [text("tail one")], [text("tail two")], [text("tail three")]]
  end

  def all_tool_blocks = [[tool_use(0)], [tool_result(0)], [tool_use(1)], [tool_result(1)]]

  # A lone conversational turn with a tool round on BOTH sides, which
  # {#mixed_blocks}'s opening turn is not -- that one is lone because the span
  # ends, and the interior case is the one the filter is really about. The pair
  # at 5-6 rides along so the example shows the filter is selective and not a
  # blanket refusal to claim anything near a tool round.
  #
  #   0-1 tool | 2 lone | 3-4 tool | 5-6 conv
  def interior_lone_blocks
    [[tool_use(0)], [tool_result(0)], [text("lone interior")],
     [tool_use(1)], [tool_result(1)], [text("after")], [text("and after")]]
  end

  def definition = Lain::Compaction::Strategy::SummarizeConversation.definition

  # One scripted model reply, in the answer schema's own shape. Mock repeats its
  # last response once exhausted, so one is enough however many runs are asked
  # about -- and `requests.size` then counts the model calls exactly.
  def provider(summary = "the run, summarized")
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
    Lain::Compaction::Strategy::SummarizeConversation.new(oracle:, sink:)
  end

  # A tier that answers everything and REMEMBERS what it was asked. The card's
  # second criterion is about the questions themselves -- one per claimed run,
  # and none for the lone turn -- so counting provider round trips would only
  # prove the arithmetic, never which messages went up the wire.
  def counting(body = "summarized") = Counting.new(body)

  # Named rather than anonymous only because it carries state and two methods,
  # which is the point at which `Class.new` stops reading as a double.
  class Counting
    ANSWER = Struct.new(:summary)

    attr_reader :asked

    def initialize(body)
      @answer = ANSWER.new(body)
      @asked = []
    end

    def ask(inputs)
      @asked += [inputs]
      Lain::Promise.new.tap { |promise| promise.resolve(@answer) }
    end
  end

  # THE REAL COMPLEMENT, not a stand-in. An earlier draft built an anonymous
  # `Elide` subclass over {Lain::Compaction::ToolMessages.tool_runs} here, which
  # made the composition below a claim about a local fixture -- and left the
  # actual shipped pair asserted by neither card, which is the one crash T7, T8
  # and T9 exist between them to prevent.
  def eliding_tools = Lain::Compaction::Strategy::ElideToolObservations.new

  # A tier that is down. `Unrecorded` is the real one a replay hits, and it is a
  # {Lain::Error} -- the family the inherited collapse contains, and deliberately
  # not `StandardError`.
  def failing(error: Lain::Oracle::Recorded::Unrecorded.new("no recorded answer"))
    Class.new { define_method(:ask) { |_inputs| raise error } }.new
  end
end

RSpec.describe Lain::Compaction::Strategy::SummarizeConversation do
  let(:fixtures) { SummarizeConversationFixtures }
  let(:provider) { fixtures.provider }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:oracle) { fixtures.recording(provider:, journal:) }
  let(:strategy) { fixtures.strategy(oracle:) }
  let(:mixed) { fixtures.mixed }

  describe "the runs it claims out of a mixed span" do
    it "claims the conversational runs of two or more and nothing else" do
      expect(strategy.ranges(mixed, span: 0..10)).to eq([3..4, 7..10])
    end

    it "claims no index carrying a tool block" do
      claimed = strategy.ranges(mixed, span: 0..10).flat_map(&:to_a)
      carrying = (0..10).select { |index| Lain::Compaction::ToolMessages.tool?(mixed.fetch(index)) }

      expect(carrying).to eq([1, 2, 5, 6])
      expect(claimed & carrying).to be_empty
    end

    # The filter is T7's and it is load-bearing here rather than incidental: an
    # unfiltered complement would pay a model call to summarize one message.
    # Asserted against the INTERIOR case, with a tool round on both sides,
    # because {#mixed}'s opening turn is lone only because the span ends there.
    it "leaves a lone conversational turn between two tool runs unclaimed" do
      interior = fixtures.messages(fixtures.interior_lone_blocks)
      surrounding = [1, 3].map { |index| Lain::Compaction::ToolMessages.tool?(interior.fetch(index)) }

      expect(surrounding).to eq([true, true])
      expect(strategy.ranges(interior, span: 0..6)).to eq([5..6])
    end

    it "leaves a lone conversational turn at the edge of the span unclaimed too" do
      expect(strategy.ranges(mixed, span: 0..10).flat_map(&:to_a)).not_to include(0)
    end

    it "claims a wholly conversational span in one run" do
      conversational = fixtures.messages([[fixtures.text("a")], [fixtures.text("b")], [fixtures.text("c")]])

      expect(strategy.ranges(conversational, span: 0..2)).to eq([0..2])
    end

    it "claims nothing at all in a span that is only tool messages, and asks nobody" do
      only_tools = fixtures.messages(fixtures.all_tool_blocks)

      expect(strategy.ranges(only_tools, span: 0..3)).to be_empty
      expect(provider.requests).to be_empty
    end
  end

  describe "the questions the oracle is asked" do
    let(:tier) { fixtures.counting }
    let(:strategy) { fixtures.strategy(oracle: tier) }

    it "asks exactly one question per claimed run" do
      strategy.ranges(mixed, span: 0..10)

      expect(tier.asked.size).to eq(2)
    end

    it "asks about the claimed runs themselves, and never about the lone turn" do
      strategy.ranges(mixed, span: 0..10)
      asked = tier.asked.map { |inputs| inputs.fetch(described_class::SLOT) }

      expect(asked).to eq([strategy.question(mixed[3..4]), strategy.question(mixed[7..10])])
      expect(asked.join).not_to include("lone opening")
    end

    it "asks no further question when each claimed run is then collapsed" do
      ranges = strategy.ranges(mixed, span: 0..10)
      ranges.each { |range| strategy.collapse(mixed[range], range:) }

      expect(ranges.size).to eq(2)
      expect(tier.asked.size).to eq(2)
    end
  end

  describe "re-deriving over byte-identical messages" do
    it "replays the recorded answers with no further model call and the same head digest" do
      source = fixtures.history(fixtures.long_blocks)
      derivation = lambda do |tier|
        Lain::Compaction::Derivation.new(strategy: fixtures.strategy(oracle: tier), keep_last: 3)
      end

      first = derivation.call(fixtures.recording(provider:, journal:)).derive(source)
      paid = provider.requests.size
      second = derivation.call(fixtures.replaying(journal_io)).derive(source)

      expect(paid).to eq(2)
      expect(second.head_digest).to eq(first.head_digest)
      expect(provider.requests.size).to eq(paid)
    end
  end

  describe "the oracle address it inherits" do
    # The escalation trigger this card was given: {Summarizing::TEMPLATE} is a
    # JOURNAL ADDRESS, so a subclass that reworded it would silently re-key every
    # recorded answer and miss only on RESUME, after the model had been paid.
    # This strategy changes WHICH ranges are proposed and never WHAT is asked
    # about them, so the address is the parent's by inheritance -- and object
    # identity is what pins it, since any re-definition here breaks `equal?`
    # whether or not the wording happens to match.
    it "asks the parent's question under the parent's address" do
      parent = Lain::Compaction::Strategy::Summarizing

      expect(described_class::TEMPLATE).to be(parent::TEMPLATE)
      expect(described_class.definition.digest).to eq(parent.definition.digest)
    end
  end

  describe "a tier that is down" do
    let(:sink) { StringIO.new }
    let(:down) { fixtures.strategy(oracle: fixtures.failing, sink:) }

    it "leaves every run uncollapsed and reports why, once per run" do
      expect(down.ranges(mixed, span: 0..10)).to be_empty
      expect(sink.string.lines.size).to eq(2)
      expect(sink.string).to include(described_class.name, "Unrecorded")
    end
  end

  describe "what a derivation over it leaves standing" do
    it "retains the tool messages and the lone turn verbatim, in position" do
      source = fixtures.history(fixtures.mixed_blocks)
      derived = Lain::Compaction::Derivation.new(strategy:, keep_last: 3).derive(source)
      projected = Lain::Compaction::Derivation.projected(derived.to_a)

      expect(projected.select { |message| Lain::Compaction::ToolMessages.tool?(message) })
        .to eq(mixed.values_at(1, 2, 5, 6))
      expect(projected.first).to eq(mixed.fetch(0))
    end
  end

  # Not this card's acceptance criterion -- T10 owns the spelling -- but it is
  # the reason T7, T8 and T9 exist at all, and the failure it guards against is
  # the expensive one: {Composed} refuses an overlap at PROPOSAL time, mid-turn,
  # in a live chat. Asserted here against the shared predicate so that this
  # class is known to compose before the card that composes it lands.
  describe "composed with the complement that claims the tool runs" do
    it "proposes the union of the two selections rather than raising Overlap" do
      eliding = fixtures.eliding_tools

      expect { (strategy | eliding).ranges(mixed, span: 0..10) }.not_to raise_error
      expect((strategy | eliding).ranges(mixed, span: 0..10)).to eq([1..2, 3..4, 5..6, 7..10])
      expect(eliding.ranges(mixed, span: 0..10)).to eq([1..2, 5..6])
    end

    # `|` is a declared COMMUTATIVE monoid (`strategy/base.rb:235`), so the
    # order an operator spells the pair in must not decide what it claims.
    it "claims the same ranges whichever way round the pair is composed" do
      eliding = fixtures.eliding_tools

      expect((eliding | strategy).ranges(mixed, span: 0..10))
        .to eq((strategy | eliding).ranges(mixed, span: 0..10))
    end
  end

  describe "the structures it inherits the refutation of" do
    it "is neither elementwise nor pure, exactly as its parent refutes" do
      expect(strategy).not_to be_a(Lain::Algebra::Elementwise)
      expect(strategy).not_to be_a(Lain::Algebra::Pure)
      expect(strategy).not_to be_deeply_frozen
    end

    # The predicate is `DerivationAudit#refuted?`'s own
    # (`derivation_audit.rb:346-351`), transcribed rather than referenced
    # because that method is private. It is an EXACT-subject scan, so the
    # parent's refutation does not reach this class and an unrestated subclass
    # audits as `:unclaimed` -- which costs the audit the `:incomplete_replay`
    # diagnosis, the one that names an oracle-backed strategy drifting after a
    # resume. This is the half of the pair that can drift for oracle reasons,
    # so it is the worst place to lose it.
    it "restates the purity refutation on its own exact class, as the audit reads it" do
      refuted = Lain::Algebra.registry.refutations.any? do |entry|
        entry.subject == described_class && entry.operation == :blocks && entry.structure == :pure
      end

      expect(refuted).to be(true)
    end

    # Purity and elementwise part company here: one is registry-keyed and had to
    # be said again, the other is classified by `is_a?` and survives inheritance
    # as the absence it already is. Restating it would regenerate nothing and
    # oblige a second proof.
    it "restates nothing else, and claims nothing" do
      mine = Lain::Algebra.registry.select { |entry| entry.subject == described_class }

      expect(mine.map { |entry| [entry.operation, entry.structure] }).to eq([%i[blocks pure]])
      expect(Lain::Algebra.registry.declarations.map(&:subject)).not_to include(described_class)
    end

    it "leaves both of Base's questions owned by Base" do
      expect(%i[ranges collapse].map { |question| described_class.instance_method(question).owner })
        .to eq([Lain::Compaction::Strategy::Base] * 2)
    end
  end
end
