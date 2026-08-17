# frozen_string_literal: true

require "async"

# A shareable base pipeline, in a module body so its `self` is this (shareable)
# module rather than an example instance -- the SchedulerShareableFixtures /
# T21PipelineProviders idiom, without which `Ractor.make_shareable` rejects the
# lambda for its binding alone and the example proves nothing about the
# summarizer.
module SummarySnapshotFixtures
  BASE = Ractor.make_shareable(->(_workspace) { Lain::Context::Identity })
end

# A4: a summarizer may never hold the live {Lain::Oracle::Eager}. The Eager is
# mutable by design (it accumulates summaries as fires land), so a
# {Lain::Context::Compact} referencing one is not `Ractor.shareable?` and
# `Compaction::Scheduler::COMPOSE` raises `Ractor::IsolationError` on the first
# compacting turn -- not in any spec that holds the summarizer alone. The
# snapshot is the frozen per-turn value that stands between them.
RSpec.describe Lain::Compaction::SummarySnapshot do
  # The summarizer oracle's schema, as PC-7's eager_spec establishes it: one
  # required `summary` field, which is the message the held answer speaks.
  let(:schema) do
    Class.new(Lain::Tool::Input) do
      field :summary, :string, required: true, description: "a terse summary"
    end
  end

  let(:definition) do
    Lain::Oracle::Definition.new(template: %(Summarize:\n<%= render("source") %>), schema:, tier: :heuristic)
  end
  # A tool result big enough to be worth even a MODEL summary
  # (Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES is 4096).
  let(:source) { "the bytes a tool returned. " * 400 }
  let(:source_digest) { Lain::Canonical.digest(source) }

  def heuristic_oracle(summary:)
    Lain::Oracle::Heuristic.new(definition:, predicate: ->(_inputs) { { "summary" => summary } })
  end

  # What ToolRunner#result_block commits, projected the way Context#render
  # projects a Timeline turn: `{"role" => .., "content" => ..}`.
  def tool_result_message(content, tool_use_id: "tu-1")
    { "role" => "user",
      "content" => [{ "type" => "tool_result", "tool_use_id" => tool_use_id,
                      "content" => content, "is_error" => false }] }
  end

  # ---- The key round trip, proved before anything rests on it --------------
  #
  # Handler::Summarizing fires on `Canonical.digest(result.content)` where
  # content is the Tool::Result's String. The COMMITTED message carries those
  # same bytes nested inside a tool_result block, through Canonical.normalize
  # on the way into the Timeline. If the digest recomputed from the committed
  # message did not equal the fired key, every lookup would miss SILENTLY.
  describe "the fired key and the committed message's digest agree" do
    it "recomputes the fired digest from the message a real dispatch commits" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "a fox"))
      handler = Lain::Effect::Handler::Summarizing.new(
        eager:, inner: Lain::Effect::Handler::Mock.new(default: source)
      )
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu-1", name: "read_file", input: {})

      result = Sync do
        handler.call(effect).tap { Async::Task.current.children&.each(&:wait) }
      end

      # The Timeline commit is where normalization happens; the projection is
      # exactly Context#render's (`context.rb:138`).
      timeline = Lain::Timeline.empty.commit(
        role: :user,
        content: [{ "type" => "tool_result", "tool_use_id" => "tu-1",
                    "content" => result.content, "is_error" => false }]
      )
      message = timeline.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }.last
      recomputed = Lain::Canonical.digest(message.fetch("content").first.fetch("content"))

      expect(recomputed).to eq(Lain::Canonical.digest(result.content))
      expect(eager.held(recomputed)&.summary).to eq("a fox")

      # And the snapshot, taken over that committed message, finds it.
      snapshot = described_class.take(messages: [message], eager:)
      expect(snapshot.call([message])).to include("a fox")
    end
  end

  # ---- Scenario: a held summary is used ------------------------------------

  describe "a held summary is used" do
    it "renders the summary the Eager holds for the message's content digest" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "the file lists three exports"))
      Sync { eager.fire(source_digest, source).wait }
      message = tool_result_message(source)

      snapshot = described_class.take(messages: [message], eager:)

      expect(snapshot.call([message])).to include("the file lists three exports")
    end
  end

  # ---- Scenario: a miss degrades to an attested elision --------------------

  describe "a miss degrades to an attested elision" do
    it "names the message's role, digest, and byte count" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "unused"))
      message = tool_result_message(source)

      rendered = described_class.take(messages: [message], eager:).call([message])

      expect(rendered).to include("user")
      expect(rendered).to include(Lain::Canonical.digest(message))
      expect(rendered).to include(Lain::Canonical.dump(message).bytesize.to_s)
    end

    it "attests an elision for a message the snapshot was never taken over" do
      snapshot = described_class.take(messages: [],
                                      eager: Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "x")))
      message = tool_result_message(source)

      expect(snapshot.call([message])).to include(Lain::Canonical.digest(message))
    end
  end

  # ---- Scenario: frozen against later Eager writes -------------------------

  describe "the snapshot is frozen against later Eager writes" do
    it "returns the elision byte-identically after the Eager gains the summary" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "arrived late"))
      message = tool_result_message(source)
      snapshot = described_class.take(messages: [message], eager:)
      before = snapshot.call([message])

      Sync { eager.fire(source_digest, source).wait }

      expect(eager.held(source_digest).summary).to eq("arrived late")
      expect(snapshot.call([message])).to eq(before)
      expect(snapshot.call([message])).not_to include("arrived late")
    end
  end

  # ---- Scenario: the snapshot is shareable ---------------------------------
  #
  # The card's reason for existing. A live Eager makes a Compact non-shareable;
  # a snapshot must not.

  describe "the snapshot is shareable" do
    it "is Ractor.shareable?, and so is a Context::Compact holding it" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "held text"))
      Sync { eager.fire(source_digest, source).wait }
      message = tool_result_message(source)

      snapshot = described_class.take(messages: [message], eager:)

      expect(snapshot).to be_deeply_frozen
      compact = Lain::Context::Compact.new(threshold: 10, keep_last: 1, summarizer: snapshot)
      expect(compact).to be_deeply_frozen
    end

    # The failure this card prevents happens inside Scheduler::COMPOSE on the
    # first COMPACTING turn -- never in a spec holding the summarizer alone --
    # so the real scheduler is what proves it.
    it "survives a real compacting Scheduler#pipeline, which a live Eager does not" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "held text"))
      snapshot = described_class.take(messages: [], eager:)

      expect { compacting_pipeline(snapshot) }.not_to raise_error
      expect { compacting_pipeline(eager) }.to raise_error(Ractor::IsolationError)
    end

    # A scheduler forced to compact (a cold cache runs it for free), so
    # `#pipeline` reaches COMPOSE rather than handing the base straight back.
    def compacting_pipeline(summarizer)
      compact = Lain::Context::Compact.new(threshold: 5, keep_last: 1, summarizer:)
      scheduler = Lain::Compaction::Scheduler.new(compact:, hard_cap: 1)
      need = Lain::Compaction::Need::Result.new(signals: ["manual"])
      scheduler.pipeline(need:, cold: true, history_size: 10, base: SummarySnapshotFixtures::BASE)
    end
  end

  # ---- Scenario: it takes the whole dropped array --------------------------

  describe "it takes the whole dropped array" do
    it "returns one String covering all three dropped messages" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "middle summary"))
      first = tool_result_message("#{source}-one", tool_use_id: "tu-1")
      second = tool_result_message("#{source}-two", tool_use_id: "tu-2")
      third = tool_result_message("#{source}-three", tool_use_id: "tu-3")
      Sync { eager.fire(Lain::Canonical.digest("#{source}-two"), "#{source}-two").wait }
      messages = [first, second, third]

      rendered = described_class.take(messages:, eager:).call(messages)

      expect(rendered).to be_a(String)
      expect(rendered).to include("middle summary")
      messages.each { |message| expect(rendered).to include(Lain::Canonical.digest(message)) }
    end

    it "is the duck Context::Compact invokes, whole dropped array in, one String out" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "s"))
      messages = Array.new(4) { |index| tool_result_message("body #{index}", tool_use_id: "tu-#{index}") }
      snapshot = described_class.take(messages:, eager:)
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 1, summarizer: snapshot)

      compacted = compact.call(messages)

      expect(compacted.size).to eq(2)
      text = compacted.first.fetch("content").first.fetch("text")
      messages.first(3).each { |message| expect(text).to include(Lain::Canonical.digest(message)) }
    end
  end

  # ---- The empty snapshot: a pure-elision default --------------------------

  describe "a snapshot with no summaries" do
    it "elides everything and is shareable" do
      message = tool_result_message(source)
      snapshot = described_class.new

      expect(snapshot).to be_deeply_frozen
      expect(snapshot.call([message])).to include(Lain::Canonical.digest(message))
    end
  end

  # ---- Review fix 1: nothing disappears unattested -------------------------
  #
  # Agent correctness gate 2 (`agent.rb:291`) commits every tool_result of one
  # assistant turn into ONE user message, so the common live shape is a message
  # whose blocks did not all cross Summarizing's 4096-byte threshold. Folded
  # from the review panel's probe 5 (5b/5d), which caught a whole `grep` result
  # vanishing while the line still read as a complete summary of the turn.

  describe "a partially summarized message" do
    let(:big) { "AAAA#{"a" * 6000}" }
    let(:small) { "CCCC a small grep result" }

    def two_block_message
      { "role" => "user",
        "content" => [
          { "type" => "tool_result", "tool_use_id" => "tu-1", "content" => big, "is_error" => false },
          { "type" => "tool_result", "tool_use_id" => "tu-2", "content" => small, "is_error" => false }
        ] }
    end

    def half_covered
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "SUMMARY-OF-BIG"))
      Sync { eager.fire(Lain::Canonical.digest(big), big).wait }
      [eager, two_block_message]
    end

    it "attests the uncovered block rather than dropping it silently" do
      eager, message = half_covered

      rendered = described_class.take(messages: [message], eager:).call([message])

      expect(rendered).to include("SUMMARY-OF-BIG")
      expect(rendered).to include(Lain::Canonical.digest(small))
      expect(rendered).to include(described_class::ELIDED)
    end

    it "states how many blocks the message carried" do
      eager, message = half_covered

      expect(described_class.take(messages: [message], eager:).call([message])).to include("2 blocks")
    end

    it "attests a block that could never carry a summary at all" do
      message = { "role" => "assistant",
                  "content" => [{ "type" => "text", "text" => "thinking out loud" },
                                { "type" => "tool_use", "id" => "tu-1", "name" => "grep", "input" => {} }] }
      snapshot = described_class.new

      lines = snapshot.call([message]).lines.map(&:chomp)

      expect(lines.grep(/\A- \[text /).size).to eq(1)
      expect(lines.grep(/\A- \[tool_use /).size).to eq(1)
    end

    it "still names the message's own role, digest, and byte count" do
      eager, message = half_covered

      rendered = described_class.take(messages: [message], eager:).call([message])

      expect(rendered).to include("user")
      expect(rendered).to include(Lain::Canonical.digest(message))
      expect(rendered).to include(Lain::Canonical.dump(message).bytesize.to_s)
    end
  end

  # ---- Review fix 2: #call([]) must not produce an empty text block --------

  describe "#call with an empty dropped array" do
    it "returns a brief honest String rather than an empty one" do
      expect(described_class.new.call([])).not_to be_empty
    end

    # Probe 4c: when protected_patterns matches every dropped message, Compact's
    # `summarizable` is [] and it used to emit {"type"=>"text","text"=>""}.
    # Anthropic rejects empty text blocks, and Provider::Ollama:131-132 guards
    # the same hazard on the response side. Plan::ClosureSummary never returned
    # empty, so this summarizer is what made the trap reachable.
    #
    # T4 closed the trap one level up rather than leaving this summarizer as its
    # only defence: Compact now DECLINES when nothing is summarizable, returning
    # the history untouched. So the guarantee is stronger than it was -- there is
    # no empty text block because there is no summary message at all, and no
    # cache prefix is broken to add one. This summarizer's own refusal to return
    # an empty String is still pinned directly, one example above.
    it "never lets Compact emit an empty text block when every dropped message is protected" do
      patterns = Lain::Context::ProtectedPatterns.new([/tool_result/])
      messages = Array.new(3) { |index| tool_result_message("body #{index}", tool_use_id: "tu-#{index}") }
      compact = Lain::Context::Compact.new(threshold: 1, keep_last: 1, summarizer: described_class.new,
                                           protected_patterns: patterns)

      rendered = compact.call(messages)

      expect(rendered).to eq(messages)
      expect(rendered.map { |message| message["role"] }).to all(eq("user"))
      expect(rendered.flat_map { |message| message["content"] }.map { |block| block["type"] })
        .to all(eq("tool_result"))
    end
  end

  # ---- Review fix 3: the key contract fails loudly -------------------------

  describe "the summaries map's keys" do
    it "raises on anything that is not a content address" do
      expect { described_class.new(summaries: { 123 => "s" }) }
        .to raise_error(described_class::NotADigest, /123/)
      expect { described_class.new(summaries: { "deadbeef" => "s" }) }
        .to raise_error(described_class::NotADigest, /deadbeef/)
    end

    it "accepts the source digest Summarizing fires under" do
      digest = Lain::Canonical.digest(source)

      snapshot = described_class.new(summaries: { digest => "known" })

      expect(snapshot.call([tool_result_message(source)])).to include("known")
    end

    # Both are well-formed to a loose `\h+` pattern and neither can ever equal
    # a key Summarizing fired -- so accepting them is exactly the permanent,
    # total, silent miss the validator exists to prevent.
    it "rejects a digest of the wrong length" do
      prefix = Lain::Canonical.digest(source).split(":").first

      expect { described_class.new(summaries: { "#{prefix}:a" => "s" }) }
        .to raise_error(described_class::NotADigest)
    end

    it "rejects uppercase hex, which Canonical never emits" do
      prefix, hex = Lain::Canonical.digest(source).split(":", 2)

      expect { described_class.new(summaries: { "#{prefix}:#{hex.upcase}" => "s" }) }
        .to raise_error(described_class::NotADigest)
    end

    it "measures the accepted shape from a real digest rather than a hardcoded width" do
      expect(described_class.digest_format).to match(Lain::Canonical.digest(""))
    end

    # The measurement cannot happen in the class body: Canonical.digest reaches
    # into the Rust extension, which lain.rb requires at :71 while this unit
    # loads at :24. Loading `lain` at all is the proof, so this pins the reason.
    it "does not hash at load time, when Lain::Ext does not exist yet" do
      expect(described_class).to be_a(Class)
    end
  end

  # ---- Review fix (round 2): a blank summary is a miss, not a blank line ----

  describe "a stored summary that is blank" do
    it "renders the elision rather than an empty body" do
      digest = Lain::Canonical.digest(source)

      [nil, "", "   "].each do |blank|
        rendered = described_class.new(summaries: { digest => blank }).call([tool_result_message(source)])

        expect(rendered).to include(described_class::ELIDED)
      end
    end
  end

  # ---- Review fix (round 2): no silent filtering of content parts ----------

  describe "a content array holding something that is not a block" do
    let(:message) do
      { "role" => "user",
        "content" => ["a raw string that is not a block",
                      { "type" => "tool_result", "tool_use_id" => "tu-1",
                        "content" => "body", "is_error" => false }] }
    end

    it "attests it rather than filtering it away" do
      expect(described_class.new.call([message]).lines.grep(/\A- \[/).size).to eq(2)
    end

    it "counts it, so the stated block count is not an understatement" do
      expect(described_class.new.call([message])).to include("2 blocks")
    end
  end

  describe "the stated block count" do
    it "is singular for a single block" do
      rendered = described_class.new.call([tool_result_message(source)])

      expect(rendered).to include("1 block]")
      expect(rendered).not_to include("1 blocks")
    end
  end

  # ---- Review fix 4: the bench can see the hit rate ------------------------
  #
  # The card's named failure mode is a key regression in which every lookup
  # misses silently. Counted at TAKE time, because the snapshot is frozen and
  # cannot tally during #call.

  describe "hit and miss counts" do
    it "counts a held block as a hit and an unheld one as a miss" do
      big = "AAAA#{"a" * 6000}"
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "held"))
      Sync { eager.fire(Lain::Canonical.digest(big), big).wait }
      message = { "role" => "user",
                  "content" => [
                    { "type" => "tool_result", "tool_use_id" => "tu-1", "content" => big, "is_error" => false },
                    { "type" => "tool_result", "tool_use_id" => "tu-2", "content" => "tiny", "is_error" => false }
                  ] }

      snapshot = described_class.take(messages: [message], eager:)

      expect(snapshot.hits).to eq(1)
      expect(snapshot.misses).to eq(1)
    end

    it "counts nothing when there was nothing to look up" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "unused"))

      snapshot = described_class.take(messages: [], eager:)

      expect(snapshot.hits).to eq(0)
      expect(snapshot.misses).to eq(0)
    end

    it "reports a total miss when every lookup fails, which is the regression signal" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "never fired"))
      messages = Array.new(3) { |index| tool_result_message("body #{index}", tool_use_id: "tu-#{index}") }

      snapshot = described_class.take(messages:, eager:)

      expect(snapshot.hits).to eq(0)
      expect(snapshot.misses).to eq(3)
    end

    # A hand-built map was measured against nothing, so it must not claim
    # coverage it never verified -- that is the one way these counters could
    # mask the key transposition the panel's probe 3d names.
    it "claims no coverage for a snapshot that was never taken over messages" do
      snapshot = described_class.new(summaries: { Lain::Canonical.digest(source) => "known" })

      expect(snapshot.hits).to eq(0)
      expect(snapshot.misses).to eq(0)
    end

    it "stays shareable with the counts on board" do
      eager = Lain::Oracle::Eager.new(oracle: heuristic_oracle(summary: "held"))

      expect(described_class.take(messages: [tool_result_message(source)], eager:)).to be_deeply_frozen
    end
  end

  # ---- Review fix 5: a missing role fails loudly ---------------------------

  describe "a message with no role" do
    it "raises rather than rendering a blank role" do
      expect { described_class.new.call([{ "content" => "hello" }]) }.to raise_error(KeyError)
    end
  end
end
