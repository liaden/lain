# frozen_string_literal: true

# Histories and strategy doubles, built by a module rather than by `let`s for
# the reason spec/lain/compaction/strategy_spec.rb records: several examples
# build three histories inside one example body, and a `let` chain would make
# "fifty, two hundred and eight hundred turns" read as three separate fixtures
# rather than as one loop over sizes.
module DerivationFixtures
  module_function

  def text(body) = { "type" => "text", "text" => body }

  # `user` on even indices, which is both the shape a well-formed conversation
  # has and the one {Lain::Compaction::Boundary}'s backward search reads.
  # `roles:` cycles a different pattern -- `%w[user]` is the all-user history
  # that makes the boundary decline, and T1 ruled that shape ordinary
  # production output rather than exotic.
  def history(size, store: Lain::Store.new, roles: %w[user assistant])
    (0...size).inject(Lain::Timeline.empty(store:)) do |timeline, index|
      timeline.commit(role: roles[index % roles.size], content: [text("turn #{index}")])
    end
  end

  # A tool round in the middle of an ordinary history: the `tool_use` at index 1
  # is answered by the `tool_result` at index 2, which is what makes a range
  # that collapses only index 1 an orphan-producing cut (Grounding F2).
  def tool_history(store: Lain::Store.new)
    blocks = [[text("ask")], [tool_use(0)], [tool_result(0)]] +
             Array.new(5) { |index| [text("after #{index}")] }
    blocks.each_with_index.inject(Lain::Timeline.empty(store:)) do |timeline, (content, index)|
      timeline.commit(role: index.even? ? "user" : "assistant", content:)
    end
  end

  # T4's declining shape: the message at index 2 carries a `tool_result` for the
  # `tool_use` before it AND a `tool_use` answered by the one after it, so the
  # naive cut and the single move off it both split a pair. Nothing in `lib/`
  # emits this -- `Agent#perform_tools` commits one user message per assistant
  # turn's results -- which is exactly why it takes a hand-built history.
  def entangled_history(store: Lain::Store.new)
    blocks = [["user", [text("ask")]],
              ["assistant", [tool_use(0)]],
              ["user", [tool_result(0), tool_use(1)]],
              ["user", [tool_result(1)]],
              ["assistant", [text("done")]],
              ["user", [text("next")]]]
    blocks.inject(Lain::Timeline.empty(store:)) do |timeline, (role, content)|
      timeline.commit(role:, content:)
    end
  end

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  def projected(timeline)
    timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }
  end

  # The strategy doubles below deliberately declare NO algebra.
  # {Lain::Algebra.registry} is process-wide and spec/algebra_laws_spec.rb
  # asserts that every declaration has a generator and every generator a
  # declaration (D5), so an anonymous class declaring against the global
  # registry goes red in that file rather than in this one.

  # Collapses the whole span it is offered, into one block naming how many
  # messages it subsumed -- so a replacement's content is a function of the
  # span's LENGTH, which is what makes the non-functoriality example legible.
  def summarizing
    Class.new(Lain::Compaction::Strategy::Base) do
      def propose_ranges(_messages, span:) = [span]

      def blocks(messages) = [{ "type" => "text", "text" => "[#{messages.size} messages summarized]" }]
    end.new.freeze
  end

  # Collapses a fixed list of ranges. The derivation's job is what it does with
  # a proposal, never how one is computed.
  def collapsing(ranges)
    Class.new(Lain::Compaction::Strategy::Base) do
      define_method(:propose_ranges) { |_messages, **| ranges }

      def blocks(messages) = [{ "type" => "text", "text" => "[#{messages.size} messages summarized]" }]
    end.new.freeze
  end

  # Answers no blocks at all, so {Lain::Compaction::Strategy::Replacement.of}
  # hands back DROP -- the unit -- and the range vanishes with no replacement
  # event.
  def dropping(ranges)
    Class.new(Lain::Compaction::Strategy::Base) do
      define_method(:propose_ranges) { |_messages, **| ranges }

      def blocks(_messages) = []
    end.new.freeze
  end
end

RSpec.describe Lain::Compaction::Derivation do
  let(:fixtures) { DerivationFixtures }

  describe "#derive" do
    it "replaces a collapsed span with one event whose causal parents are exactly that range's source digests" do
      source = fixtures.history(9)
      derived = described_class.new(strategy: fixtures.summarizing, keep_last: 3).derive(source)

      replacement = derived.to_a.first
      expect(replacement.role).to eq("user")
      expect(replacement.content).to eq([fixtures.text("[6 messages summarized]")])
      expect(replacement.causal_parents).to match_array(source.to_a[0...6].map(&:digest))
      expect(derived.length).to eq(source.length - 6 + 1)
    end

    it "never renders the turns it replaced" do
      source = fixtures.history(9)
      derived = described_class.new(strategy: fixtures.summarizing, keep_last: 3).derive(source)

      expect(derived.ancestor_digests & source.to_a[0...6].map(&:digest)).to be_empty
    end

    it "collapses three non-adjacent ranges to three events, in position, with the retained turns between them" do
      source = fixtures.history(13)
      strategy = fixtures.collapsing([0..1, 3..4, 6..7])
      derived = described_class.new(strategy:, keep_last: 3).derive(source)

      folded = derived.to_a.each_with_index.select { |event, _| event.causal_parents.any? }
      expect(folded.map(&:last)).to eq([0, 2, 4])
      expect(folded.map { |event, _| event.causal_parents.size }).to eq([2, 2, 2])
      expect(fixtures.projected(derived).map { |message| message.fetch("content").first.fetch("text") })
        .to eq(["[2 messages summarized]", "turn 2", "[2 messages summarized]", "turn 5",
                "[2 messages summarized]", "turn 8", "turn 9", "turn 10", "turn 11", "turn 12"])
    end

    # An EVEN-sized drop, because the retained neighbours close up against each
    # other: dropping an odd count of an alternating history leaves two
    # assistants adjacent, which is a violation and belongs to the refusal
    # examples below rather than to this one.
    it "leaves no replacement event at all for a dropped range" do
      source = fixtures.history(13)
      derived = described_class.new(strategy: fixtures.dropping([2..5]), keep_last: 3).derive(source)

      expect(derived.length).to eq(source.length - 4)
      expect(derived.to_a.map(&:causal_parents)).to all(be_empty)
      expect(fixtures.projected(derived)).to eq(fixtures.projected(source).values_at(0, 1, *(6..12)))
    end

    it "derives a chain that projects byte-identically to its source under the identity strategy" do
      source = fixtures.history(9)
      strategy = Lain::Compaction::Strategy::Identity.new
      derived = described_class.new(strategy:, keep_last: 3).derive(source)

      expect(Lain::Canonical.dump(fixtures.projected(derived)))
        .to eq(Lain::Canonical.dump(fixtures.projected(source)))
    end

    it "derives the same head digest from the same source and the same deterministic strategy" do
      source = fixtures.history(9)
      derivation = described_class.new(strategy: fixtures.summarizing, keep_last: 3)

      expect(derivation.derive(source).head_digest).to eq(derivation.derive(source).head_digest)
    end

    # The VALUE is pinned, not merely its constancy: `uniq.size == 1` stays
    # green for an implementation that writes a constant WRONG chain (always
    # length 1, say). 21 events is `keep_last` plus the replacement -- this
    # history splits no tool pair, so T4's boundary cuts at the naive split and
    # retains nothing extra; 22 objects is those 21 envelopes plus the
    # replacement's payload, every retained payload being already in the store
    # since role and content are unchanged and `meta` is empty on both sides, so
    # content addressing dedupes it.
    #
    # If this goes red on a legitimate change to the projection or the boundary,
    # the new numbers belong here, spelled out. That is the point of pinning
    # them: the moment the shape moves should be loud and legible.
    it "is bounded by the retained tail, not by history length" do
      measured = [50, 200, 800].map do |size|
        store = Lain::Store.new
        source = fixtures.history(size, store:)
        before = store.size
        derived = described_class.new(strategy: fixtures.summarizing, keep_last: 20).derive(source)
        [derived.length, store.size - before]
      end

      expect(measured).to eq([[21, 22], [21, 22], [21, 22]])
    end

    it "derives a valid conversation from every strategy this chunk ships" do
      source = fixtures.history(13)
      strategies = [Lain::Compaction::Strategy::Identity.new, fixtures.summarizing,
                    fixtures.collapsing([0..1, 3..4]), fixtures.dropping([2..5])]

      strategies.each do |strategy|
        derived = described_class.new(strategy:, keep_last: 3).derive(source)
        expect(Lain::Context::Conversation.new(fixtures.projected(derived))).to be_valid
      end
    end

    it "refuses a strategy whose replacement would orphan a tool_result" do
      source = fixtures.tool_history
      derivation = described_class.new(strategy: fixtures.collapsing([1..1]), keep_last: 3)

      expect { derivation.derive(source) }
        .to raise_error(described_class::Invalid, /tool_result "toolu_0".*answers no tool_use/)
    end

    it "refuses a strategy whose drop would leave the chain opening on an assistant" do
      source = fixtures.history(9)
      derivation = described_class.new(strategy: fixtures.dropping([0..0]), keep_last: 3)

      expect { derivation.derive(source) }
        .to raise_error(described_class::Invalid, /messages\[0\] must have role user/)
    end

    # A refusal is not a rollback: the Store is append-only and nothing removes
    # an object, so a chain committed before its projection was judged is dead
    # weight in the session's own Store forever. A deterministic strategy leaks
    # a bounded amount (content addressing dedupes the identical retry), but a
    # model-backed one answers differently every turn, and T9 puts this on the
    # render path -- one buggy `Strategy::Summarizing` would then grow the store
    # by a fresh dead chain per compacting turn with nothing but an exception to
    # show for it.
    it "writes nothing to the store when it refuses the chain" do
      store = Lain::Store.new
      source = fixtures.history(9, store:)
      derivation = described_class.new(strategy: fixtures.dropping([0..0]), keep_last: 3)
      before = store.size

      expect { derivation.derive(source) }.to raise_error(described_class::Invalid)
      expect(store.size).to eq(before)
    end

    it "journals nothing when it refuses the chain" do
      journal = []
      derivation = described_class.new(strategy: fixtures.dropping([0..0]), keep_last: 3, journal:)

      expect { derivation.derive(fixtures.history(9)) }.to raise_error(described_class::Invalid)
      expect(journal).to be_empty
    end

    it "refuses to derive into a store that does not hold the source, rather than dangling" do
      source = fixtures.history(9)
      derivation = described_class.new(strategy: fixtures.summarizing, keep_last: 3)

      expect { derivation.derive(source, into: Lain::Store.new) }
        .to raise_error(Lain::Store::MissingObject, /would dangle/)
    end

    it "journals the derivation edge" do
      journal = []
      source = fixtures.history(9)
      derived = described_class.new(strategy: fixtures.summarizing, keep_last: 3, journal:).derive(source)

      expect(journal.last.to_journal).to eq(
        "type" => "context_derived", "source_head" => source.head_digest, "derived_head" => derived.head_digest,
        "strategy" => "(anonymous strategy)", "spans" => [[source.to_a.first.digest, source.to_a[5].digest]],
        "cut" => :offered, "moved" => 0, "keep_last" => 3
      )
    end

    it "journals a named strategy by its constant name, which is what a re-derivation resolves" do
      journal = []
      described_class.new(strategy: Lain::Compaction::Strategy::Identity.new, keep_last: 3, journal:)
                     .derive(fixtures.history(9))

      expect(journal.last.strategy).to eq("Lain::Compaction::Strategy::Identity")
    end

    # An anonymous class renders as `#<Class:0x00007f...>` and that address is
    # fresh in every process, so a record carrying one reads as drift on the
    # next run -- and puts a heap address into the experiment record.
    it "journals no memory address for an anonymous strategy" do
      journal = []
      described_class.new(strategy: fixtures.summarizing, keep_last: 3, journal:).derive(fixtures.history(9))

      expect(journal.last.strategy).not_to match(/0x\h+/)
    end

    # `be_deeply_frozen` IS the pair this AC names -- `#frozen?` and
    # `Ractor.shareable?`, per its own doc -- so asserting both spellings would
    # be one claim written twice.
    # {Boundary} carries two distinctly named predicates because "compaction
    # silently stopped happening, forever, with no error anywhere" is a real
    # mode and telling it apart from an ordinary quiet turn is the whole point.
    # A derivation that collapsed nothing has three causes and they are NOT
    # interchangeable: the request was vacuous, no valid cut existed, or the
    # strategy was offered a span and declined it. All three journal `spans:
    # []`, so without the cause on the record T8 cannot tell them apart -- an
    # audit can only audit what was written.
    describe "the cause of a derivation that collapses nothing" do
      def cut_for(source, strategy:, keep_last: 3)
        journal = []
        described_class.new(strategy:, keep_last:, journal:).derive(source)
        journal.last
      end

      it "records a vacuous request, where keep_last covered the whole history" do
        record = cut_for(fixtures.history(2), strategy: fixtures.summarizing)

        expect(record.cut).to eq(:empty)
        expect(record.spans).to be_empty
      end

      # FINDING, recorded rather than papered over. This example used to build
      # its decline from an all-`user` history, which declined only under the
      # role-landing rule T4 retired. Rebuilt on T4's own shape -- a message
      # carrying a `tool_result` for the previous turn AND a `tool_use` answered
      # by the next, which declines because both the naive cut and the one move
      # off it split a pair -- it no longer reaches a record at all, because
      # that shape is one `Context::Conversation` refuses.
      #
      # The step that makes this an argument rather than a coincidence is that
      # THE TWO GUARDS JUDGE THE SAME ARRAY: a declining boundary makes
      # `Plan.proposed` answer no ranges, no ranges makes every write a
      # retention, and a chain of retentions projects to exactly the source
      # projection -- so the array the validator refuses IS the array the
      # boundary declined on. Were those two arrays ever allowed to differ, the
      # claim below would not close.
      #
      # That is not a coincidence of this fixture either, it is forced. Under the
      # relaxed rule a decline REQUIRES either a `tool_use` at index 0 (which
      # invariant 1 refuses, since `messages[0]` must be `user`, and invariant 5
      # refuses, since a `tool_use` must be `assistant`) or one message carrying
      # both a `tool_result` and a `tool_use` (which invariant 5 refuses
      # whichever role it takes). Measured on the cleanest possible declining
      # source -- everything else legal -- the only violation is the misplaced
      # block at the entangled message.
      #
      # So `cut: :declined` is UNREACHABLE end to end for a source this object
      # would accept, and the two guards agree: the shape the boundary cannot
      # cut is the shape the validator will not send. The vocabulary stays,
      # because `Boundary` can still answer `declined?` and T8 must handle a
      # record carrying it -- an older journal has them, and a future cut rule
      # may reach it again.
      it "cannot reach a declined cut, because every declining shape is one the validator refuses" do
        journal = []
        entangled = fixtures.entangled_history
        boundary = Lain::Compaction::Boundary.new(messages: fixtures.projected(entangled), keep_last: 3)
        derivation = described_class.new(strategy: fixtures.summarizing, keep_last: 3, journal:)

        expect(boundary).to be_declined
        expect { derivation.derive(entangled) }
          .to raise_error(described_class::Invalid, /tool_use in messages\[2\] is carried by a "user" message/)
        expect(journal).to be_empty
      end

      it "records an abstaining strategy, which was offered a span and answered no ranges" do
        record = cut_for(fixtures.history(9), strategy: Lain::Compaction::Strategy::Identity.new)

        expect(record.cut).to eq(:offered)
        expect(record.spans).to be_empty
      end

      it "records an offered span whenever ranges were collapsed" do
        record = cut_for(fixtures.history(9), strategy: fixtures.summarizing)

        expect(record.cut).to eq(:offered)
        expect(record.spans.size).to eq(1)
      end
    end

    it "leaves every derived event deeply frozen and Ractor-shareable" do
      source = fixtures.history(9)
      derived = described_class.new(strategy: fixtures.summarizing, keep_last: 3).derive(source)

      expect(derived.to_a).to all(be_deeply_frozen)
    end
  end

  # CHARACTERIZATION of inherited behaviour -- no red step, because nothing here
  # is new: these examples measure what the shipped object already does with the
  # shape follow-up 14 is about, and they exist so T9 wires the derived path in
  # knowing the answer.
  #
  # T4 pinned a defect on `Context::Compact`'s path: a pin inside the span can
  # strand a `tool_result` whose `tool_use` it retains, and the render is a 400
  # with pins on and clean with pins off. The derivation reaches the same shape
  # by a different road -- this object never consults pins, but T3's seam makes a
  # pin a CUT POINT, so a pin-aware strategy answers N ranges with the pinned
  # turn retained between them, and the counterpart inside a collapsed range is
  # stranded exactly as it is under Compact.
  #
  # The STRANDING is inherited. The 400 is not: this path refuses, names the
  # violation, and writes nothing. That difference is the whole reason the
  # validator is called here rather than trusted to a downstream that has none.
  describe "a pin between two ranges, which is how a pin reaches this object" do
    it "refuses a retained pinned tool_result whose tool_use a range collapsed" do
      store = Lain::Store.new
      source = fixtures.tool_history(store:)
      derivation = described_class.new(strategy: fixtures.collapsing([0..1, 3..4]), keep_last: 3)
      before = store.size

      expect { derivation.derive(source) }
        .to raise_error(described_class::Invalid, /tool_result "toolu_0".*answers no tool_use/)
      expect(store.size).to eq(before)
    end

    it "refuses a retained pinned tool_use whose tool_result a range collapsed" do
      source = fixtures.tool_history
      derivation = described_class.new(strategy: fixtures.collapsing([0..0, 2..4]), keep_last: 3)

      expect { derivation.derive(source) }
        .to raise_error(described_class::Invalid, /tool_use "toolu_0".*is never answered/)
    end
  end

  # The derivation is the caller that DIES on a malformed proposal, and it died
  # obscurely: `nil` reached `Partition` as a `NoMethodError` on `grep_v` and a
  # fractional range reached `Plan#subsumed` as `TypeError: can't iterate from
  # Float`, neither naming the strategy at fault. The refusals belong to
  # {Strategy::Base}, which owns the interval-partition contract; these examples
  # pin them from the seat where the damage was felt.
  describe "a malformed proposal" do
    def refusal(ranges)
      strategy = Class.new(Lain::Compaction::Strategy::Base) do
        define_method(:propose_ranges) { |_messages, **| ranges }

        def blocks(_messages) = [{ "type" => "text", "text" => "x" }]
      end.new.freeze

      { strategy:, derivation: described_class.new(strategy:, keep_last: 3) }
    end

    it "refuses a proposal that is not a list of ranges at all, naming the strategy" do
      answering = refusal(nil)

      expect { answering.fetch(:derivation).derive(fixtures.history(9)) }
        .to raise_error(Lain::Compaction::Strategy::NotAPartition, /answers nil.*#propose_ranges/m)
    end

    it "refuses a range whose endpoints are not message indices, naming the strategy" do
      answering = refusal([0.0..1.5])

      expect { answering.fetch(:derivation).derive(fixtures.history(9)) }
        .to raise_error(Lain::Compaction::Strategy::NotAPartition, /0\.0\.\.1\.5.*Integer/m)
    end
  end

  describe "the shape of the object" do
    it "offers no method that extends a previously derived chain" do
      expect(described_class.public_instance_methods(false)).to contain_exactly(:derive)
    end

    # A CHARACTERIZATION example: it is here to be READ, and it pins a negative
    # (Grounding F8). Derivation is not a functor on the prefix order -- a
    # source timeline being a prefix of another says nothing about their derived
    # chains -- because `render_parent` is folded into the digest (`event.rb:100`)
    # and the `keep_last` window slides, so every event of the later chain is
    # re-addressed. That is Grounding F5 restated: the failure of structural
    # sharing IS the failure of functoriality.
    #
    # If this ever goes red because derivation became prefix-preserving, that is
    # a real result and needs confirming -- but the far likelier cause is
    # someone "optimising" the derivation into an incremental extend, which the
    # Open decisions forbid. Either way: stop, do not delete the example.
    it "is not a functor on the prefix order: T1 <= T2 does not imply derive(T1) <= derive(T2)" do
      store = Lain::Store.new
      earlier = fixtures.history(9, store:)
      later = earlier.commit(role: "assistant", content: [fixtures.text("turn 9")])
      derivation = described_class.new(strategy: fixtures.summarizing, keep_last: 3)

      expect(earlier.ancestor_of?(later)).to be(true)
      expect(derivation.derive(earlier).ancestor_of?(derivation.derive(later))).to be(false)
      expect(derivation.derive(earlier).to_a.first.digest).not_to eq(derivation.derive(later).to_a.first.digest)
    end
  end
end
