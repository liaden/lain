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

# The mixed transcript both narrowed strategies were proved out against --
# `spec/lain/compaction/strategy/composed_spec.rb:40` builds it as a Timeline
# and T9's fixtures as an Array; this is the Array form, because a resolver test
# needs only what `#ranges` indexes. A top-level module for the reason
# `ComposedFixtures` and `SummarizeConversationFixtures` are: a constant
# declared inside the group is a `Lint/ConstantDefinitionInBlock` leak.
#
#   0 lone | 1-2 tool | 3-4 conv | 5-6 tool | 7-10 conv
module CompactionStrategyTranscript
  module_function

  def text(body) = { "type" => "text", "text" => body }

  def tool_use(id) = { "type" => "tool_use", "id" => "toolu_#{id}", "name" => "read", "input" => {} }

  def tool_result(id) = { "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "ok" }

  def mixed
    [[text("lone opening")], [tool_use(0)], [tool_result(0)],
     [text("so")], [text("then")], [tool_use(1)], [tool_result(1)],
     [text("ok")], [text("more")], [text("and")], [text("last")]]
      .each_with_index.map { |content, i| { "role" => i.even? ? "user" : "assistant", "content" => content } }
  end
end

RSpec.describe Lain::CLI::CompactionStrategy do
  let(:mixed) { CompactionStrategyTranscript.mixed }
  let(:whole) { 0..(mixed.size - 1) }

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
    # AC 3: the WHOLE advertised set, read off the constant rather than
    # transcribed, so growing STRATEGIES cannot leave a refusal advertising a
    # subset of what ships. `--compact-strategy` and `--provider` are different
    # mistakes to make, so the flag is named too.
    # `include?(name)` would be substring matching, and "elide" is a substring
    # of "elide-tools" -- so a message that listed only `elide-tools` would
    # satisfy the `elide` check and this guard would pass on a set it no longer
    # names in full. The message renders `STRATEGIES.inspect`, so matching each
    # entry's own `inspect` pins the QUOTED entry and cannot be satisfied by a
    # neighbour that happens to contain it.
    it "is refused by name, listing every registered strategy" do
      expect { resolve("nope") }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown) do |error|
          expect(error.message).to include('--compact-strategy "nope"')
          expect(described_class::STRATEGIES.reject { |name| error.message.include?(name.inspect) }).to be_empty
        end
    end

    # Not reachable from Thor, which parses a String or nothing -- but Backend
    # reads the flag out of a Hash, and `Symbol#empty?` exists, so a Symbol
    # used to pass every guard and die on `Symbol#split` with an uncontained
    # NoMethodError. `exe/lain:51` renders a Lain::Error as a one-liner and a
    # NoMethodError as a backtrace, so the class the caller gets is the whole
    # difference.
    it "refuses a non-String name at the door, naming the type it got" do
      expect { resolve(:elide) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /takes a String, got Symbol: :elide/)
      expect { described_class.new(["elide"]) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /takes a String, got Array/)
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

    # Asserted THROUGH the part name, not trimmed just before it: there is more
    # than one oracle-backed strategy now, so a message hard-coding one of them
    # is wrong for the others, and a regex stopping at `tier:` is a spec shaped
    # around exactly the half that can go stale.
    it "refuses to build the summarizing strategy with no tier: given, naming it" do
      expect { resolve }
        .to raise_error(Lain::CLI::CompactionStrategy::MissingTier,
                        /CompactionStrategy\.resolve needs tier: to build "summarizing"/)
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

  describe "the narrowed strategies" do
    it "resolves elide-tools to a strategy claiming only the tool runs, needing no tier" do
      calls = []

      strategy = resolve("elide-tools", tier: tier_factory(calls:))

      expect(strategy).to be_a(Lain::Compaction::Strategy::ElideToolObservations)
      expect(strategy.ranges(mixed, span: whole)).to eq([1..2, 5..6])
      expect(calls).to be_empty
    end

    it "resolves summarize-conversation to a strategy claiming only the conversational runs" do
      strategy = resolve("summarize-conversation", tier: tier_factory, journal: [])

      expect(strategy).to be_a(Lain::Compaction::Strategy::SummarizeConversation)
      expect(strategy.ranges(mixed, span: whole)).to eq([3..4, 7..10])
    end

    it "refuses summarize-conversation with no tier:, naming IT and not its parent" do
      expect { resolve("summarize-conversation") }
        .to raise_error(Lain::CLI::CompactionStrategy::MissingTier,
                        /needs tier: to build "summarize-conversation"/)
    end

    it "names the oracle-backed part inside a composition, not the composition" do
      expect { resolve("elide-tools+summarize-conversation") }
        .to raise_error(Lain::CLI::CompactionStrategy::MissingTier,
                        /needs tier: to build "summarize-conversation"/)
    end
  end

  describe "a composition spelled with the separator" do
    it "builds a Composed strategy whose operands are the two named leaves" do
      strategy = resolve("elide-tools+summarize-conversation", tier: tier_factory, journal: [])

      expect(strategy).to be_a(Lain::Compaction::Strategy::Composed)
      expect(strategy.operands.map(&:class)).to eq([Lain::Compaction::Strategy::ElideToolObservations,
                                                    Lain::Compaction::Strategy::SummarizeConversation])
    end

    # The whole point of the pair: they are exact complements by construction
    # (both route through {Lain::Compaction::ToolMessages}), so proposing over a
    # mixed span partitions it rather than raising Overlap.
    it "proposes a disjoint partition of a mixed span, raising nothing" do
      strategy = resolve("elide-tools+summarize-conversation", tier: tier_factory, journal: [])

      expect(strategy.ranges(mixed, span: whole)).to eq([1..2, 3..4, 5..6, 7..10])
    end

    it "partitions the same span whichever way round the two are spelled" do
      strategy = resolve("summarize-conversation+elide-tools", tier: tier_factory, journal: [])

      expect(strategy.ranges(mixed, span: whole)).to eq([1..2, 3..4, 5..6, 7..10])
    end

    # One `tier:` call, so one Oracle::Recorded::Journaling and one journal --
    # {Lain::Compaction::Strategy::SummarizeConversation}'s own doc: "Two
    # strategies, one oracle, one journal." Two wraps would journal one span's
    # answer under two oracles and double what a resume has to reconcile.
    it "calls the tier factory once for a composition holding two oracle-backed leaves" do
      calls = []

      resolve("summarizing+summarize-conversation", tier: tier_factory(calls:), journal: [])

      expect(calls.size).to eq(1)
    end

    it "refuses an unknown name inside a composition, naming that part and the whole value" do
      expect { resolve("elide-tools+nope", tier: tier_factory) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown,
                        /unknown part "nope" in --compact-strategy "elide-tools\+nope"/)
    end

    # `"elide+".split("+")` drops the trailing empty and would resolve to a bare
    # Elide -- a typo silently answering a different strategy. The split keeps
    # the empties so both ends refuse identically.
    # The refusal names the PART and the VALUE IT CAME FROM. Naming the part
    # alone reported `unknown --compact-strategy ""` for all of these, which is
    # loud and false about what was typed -- nobody passed an empty flag, and
    # the reader goes hunting a shell-quoting bug that is not there.
    it "refuses an empty part at either end rather than dropping it, naming what was typed" do
      expect { resolve("elide+", tier: tier_factory) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown,
                        /unknown part "" in --compact-strategy "elide\+"/)
      expect { resolve("+elide", tier: tier_factory) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown,
                        /unknown part "" in --compact-strategy "\+elide"/)
      expect { resolve("elide++summarizing", tier: tier_factory) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown,
                        /unknown part "" in --compact-strategy "elide\+\+summarizing"/)
    end

    it "refuses an empty name outright rather than composing nothing" do
      expect { resolve("", tier: tier_factory) }
        .to raise_error(Lain::CLI::CompactionStrategy::Unknown, /unknown part "" in --compact-strategy ""/)
    end

    # AC 4, and it is deliberately weaker than "refused before any run begins":
    # `Base#|` only CONSTRUCTS, and Overlap is raised inside
    # {Lain::Compaction::Strategy::Composed#propose_ranges}, which needs the
    # messages and the span this resolver does not have. A static "claims the
    # whole span" declaration would let the refusal move here; that is a design
    # decision for its own card (composed_spec.rb:141 pins the position).
    it "constructs two whole-span strategies happily and raises Overlap at the first compaction" do
      strategy = resolve("elide+summarizing", tier: tier_factory, journal: [])

      expect(strategy).to be_a(Lain::Compaction::Strategy::Composed)
      expect { strategy.ranges(mixed, span: whole) }
        .to raise_error(Lain::Compaction::Strategy::Composed::Overlap,
                        /Strategy::Elide and .*Strategy::Summarizing both propose/)
    end
  end

  describe "the unset name" do
    # spec/docs_naming_spec.rb:92-106 pins that an unset --compact-strategy is
    # its OWN case, not a synonym for a strategy -- Backend::SpanSummarizer
    # short-circuits on nil and never reaches here, so what DEFAULT means is a
    # question only a direct caller of .resolve can ask.
    it "is still the single DEFAULT name and not a composition" do
      expect(described_class::DEFAULT).to eq("summarizing")
      expect(resolve(tier: tier_factory)).to be_a(Lain::Compaction::Strategy::Summarizing)
      expect(resolve(tier: tier_factory)).not_to be_a(Lain::Compaction::Strategy::Composed)
    end
  end

  describe "the exhaustiveness guard" do
    it "raises Unbuilt, not Unknown, for a validated name with no matching branch -- a bug here, not a bad flag" do
      strategy = described_class.new("summarizing", tier: tier_factory)
      allow(strategy).to receive(:strategy_names).and_return(["plan-step"])

      expect { strategy.strategy }
        .to raise_error(Lain::CLI::CompactionStrategy::Unbuilt, /"plan-step".*no branch here builds it/)
    end
  end
end
