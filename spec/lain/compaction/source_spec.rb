# frozen_string_literal: true

require "json"
require "stringio"

# A clock the examples drive by hand. The Source measures the idle gap that
# {Lain::Compaction::Cold#idle!} needs, and reading `Time.now` inline would make
# a replayed run non-deterministic -- so the clock is a collaborator, exactly as
# {Lain::StatusFeed} injects one (status_feed.rb:112).
class SourceSpecClock
  attr_reader :now

  def initialize(now) = (@now = now)

  def call = @now

  def advance(seconds) = (@now += seconds)
end

# Stands in for {Lain::Oracle::Eager}: holds summaries keyed by SOURCE digest and
# counts how often it is read, so an example can prove the snapshot is taken ONCE
# per turn rather than rebuilt inside each of the three passes a compacting turn
# makes over the head.
class SourceSpecEager
  Answer = Struct.new(:summary)

  attr_reader :reads

  def initialize(summaries = {})
    @summaries = summaries
    @reads = 0
  end

  def held(digest)
    @reads += 1
    @summaries.key?(digest) ? Answer.new(@summaries.fetch(digest)) : nil
  end
end

# A base render strategy that is NOT the Context class default: an injected
# pipeline whose effect is visible in the rendered messages. If the Source
# reaches for `base.class.pipeline(workspace)` instead of `base.pipeline_for`,
# this marker disappears and nothing else fails.
module SourceSpecPipelines
  class Marker < Lain::Context::Combinator
    def call(messages) = messages + [{ "role" => "user", "content" => "INJECTED-PIPELINE" }]
  end

  INJECTED = Ractor.make_shareable(->(_workspace) { Marker.new.freeze })
end

RSpec.describe Lain::Compaction::Source do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:clock) { SourceSpecClock.new(Time.at(1_700_000_000).utc) }
  let(:eager) { SourceSpecEager.new }
  let(:keep_last) { 2 }
  let(:session) { instance_double(Lain::Session, plan_step_completed?: false) }
  let(:toolset) { Lain::Toolset.new([]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:base) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt") }

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  def decisions = records.select { |record| record["type"] == "compaction_decision" }

  def compactions = records.select { |record| record["type"] == "compaction" }

  # Substantial tool_result messages: `content` is a String, which is what
  # {Lain::Compaction::SummarySnapshot} keys a summary on, so the same fixture
  # serves the elision path and the eager-hit path.
  #
  # They are BIG on purpose. An elision line attests its message (role, digest,
  # byte counts, one line per block) in ~230 bytes, so a history of small
  # messages is one that compaction would GROW -- the case the floor in #decide
  # refuses, exercised by {#small_block} below.
  def block(index)
    { "type" => "tool_result", "tool_use_id" => "call-#{index}",
      "content" => "the quick brown fox jumped over the lazy dog, result number #{index}. " * 15 }
  end

  def small_block(index)
    { "type" => "tool_result", "tool_use_id" => "call-#{index}", "content" => "result #{index}" }
  end

  def timeline(size = 6, &block_for)
    block_for ||= method(:block)
    (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
      line.commit(role: "user", content: [block_for.call(index)])
    end
  end

  def small_timeline(size = 6) = timeline(size) { |index| small_block(index) }

  # The floor's crossover, found by walking ONE dropped body a character at a
  # time (the re-review's `probe_a6_floor_cost.rb`): at 366 Z's the canonical
  # history and its rewrite both dump to 1,600 bytes, 365 inflates by one byte
  # and 367 saves one. The examples assert the delta they claim to sit on, so a
  # change in canonical framing fails loudly here rather than sliding the
  # fixture quietly off the boundary.
  def neutral_pad = 366

  def crossover_timeline(pad)
    bodies = (1..5).map { |index| "pad#{index}-#{"m" * 100}" } + ["Z" * pad, "tail-a", "tail-b"]
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, (body, index)|
      line.commit(role: "user",
                  content: [{ "type" => "tool_result", "tool_use_id" => "call-#{index}", "content" => body }])
    end
  end

  # What the floor measures, measured independently: the bytes the rewrite would
  # add or remove from the rendered history.
  def rewrite_delta(line)
    messages = messages_of(line)
    head = Lain::Compaction::Head.new(messages:, keep_last:)
    snapshot = Lain::Compaction::SummarySnapshot.take(messages: head.messages,
                                                      eager: Lain::Compaction::Source::NoSummaries)
    compact = Lain::Context::Compact.new(threshold: 0, keep_last:, summarizer: snapshot,
                                         protected_patterns: Lain::Context::ProtectedPatterns::NONE)
    Lain::Canonical.dump(compact.call(messages)).bytesize - Lain::Canonical.dump(messages).bytesize
  end

  def messages_of(line) = line.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }

  def build_need(byte_threshold: 1_000_000, approaching_ratio: 0.9)
    Lain::Compaction::Need.new(byte_threshold:, approaching_ratio:)
  end

  # A book that answers ONE window whatever the model, for the examples that are
  # about the ratio rather than about model resolution. A blank model still
  # raises through it, which is the point of the fallback form.
  def window_book(tokens) = Lain::ContextWindow.new(windows: {}, fallback: tokens)

  def context_naming(model) = Lain::Context.new(model:, max_tokens: 1024, system: "a system prompt")

  def build_cold(ttl: 300) = Lain::Compaction::Cold.new(cache_profile: { ttl: }, journal:)

  def source(need: build_need, cold: build_cold, hard_cap: 1_000_000, **overrides)
    described_class.new(need:, cold:, hard_cap:, keep_last:, eager:, journal:, clock:, **overrides)
  end

  def turn_usage(cache_read:)
    Lain::Telemetry::TurnUsage.new(
      digest: "blake3:deadbeef", model: "claude-opus-4-8", stop_reason: :end_turn,
      usage: { "input_tokens" => 10, "cache_read_input_tokens" => cache_read }
    )
  end

  def context_for(built, line, base: self.base, usage: nil, session: self.session)
    built.context_for(base:, timeline: line, usage:, session:)
  end

  def render(context, line) = context.render(timeline: line, toolset:, workspace:)

  describe "deferring is a true no-op" do
    it "answers the base Context ITSELF, not a copy carrying an equivalent pipeline" do
      line = timeline
      expect(context_for(source, line)).to equal(base)
    end

    it "renders byte-identically to the base Context" do
      line = timeline
      returned = context_for(source, line)

      expect(Lain::Canonical.dump(render(returned, line).cache_payload))
        .to eq(Lain::Canonical.dump(render(base, line).cache_payload))
    end

    it "journals nothing from the scheduler" do
      context_for(source, timeline)

      expect(compactions).to be_empty
    end
  end

  describe "crossing the hard cap compacts even while the cache is warm" do
    it "renders the head summarized" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      messages = render(context_for(built, line), line).messages

      expect(messages.size).to eq(keep_last + 1)
      expect(messages.first["content"].first["text"]).to include("elided")
    end

    it "journals the forced-warm cache state" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)
      context_for(built, timeline)

      expect(compactions.first["cache_state"]).to eq("forced")
    end
  end

  describe "a cold cache is observed from usage" do
    # Idle past the TTL only raises Cold's PENDING mark; the next response's
    # zero cache-read is what confirms it (cold.rb's two-signal contract).
    def cold_cache(built, line)
      clock.advance(600)
      context_for(built, line)
      built << turn_usage(cache_read: 0)
    end

    it "takes the cold-free decision, not the forced-warm one" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)
      cold_cache(built, line)

      context_for(built, line)

      expect(compactions.map { |record| record["cache_state"] }).to eq(%w[cold])
    end

    it "defers at the same threshold while the cache is still warm" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)

      expect(context_for(built, line)).to equal(base)
      expect(compactions).to be_empty
    end

    it "cancels the cold mark when a later response reports a cache hit" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)
      cold_cache(built, line)
      built << turn_usage(cache_read: 4096)

      expect(context_for(built, line)).to equal(base)
    end

    it "answers self, so it can ride a journal fan-out as one more sink" do
      built = source

      expect(built << turn_usage(cache_read: 0)).to equal(built)
    end

    # The mirror of the example above: same zero cache-read, no idle time. It is
    # what distinguishes the injected clock from an inline `Time.now`, which
    # would measure the gap from a fixture clock set in 2023 and put every turn
    # past any TTL.
    it "leaves the cache warm when no idle time has passed" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)

      context_for(built, line)
      built << turn_usage(cache_read: 0)

      expect(context_for(built, line)).to equal(base)
      expect(compactions).to be_empty
    end

    # `#usage` alone would let this one through, and its usage Hash has no cache
    # fields -- so a landed oracle answer would read as a zero cache-read and
    # confirm a warm cache cold.
    it "ignores an oracle answer, which reports usage of its own" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)
      clock.advance(600)
      context_for(built, line)

      built << Lain::Telemetry::OracleAnswer.new(oracle_digest: "blake3:oracle", question: "how big?",
                                                 answer: { "summary" => "big" })

      expect(context_for(built, line)).to equal(base)
    end

    it "ignores an event that is not a turn's own usage" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 1_000_000)
      clock.advance(600)
      context_for(built, timeline)
      built << Lain::Telemetry::Dropped.new(count: 1)

      expect(context_for(built, timeline)).to equal(base)
    end
  end

  describe "a completed plan step is a trigger" do
    let(:session) { instance_double(Lain::Session, plan_step_completed?: true) }

    it "compacts a history above the byte threshold" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      expect(render(context_for(built, line), line).messages.size).to eq(keep_last + 1)
    end

    it "is the signal that fired when the history is below the byte threshold" do
      line = timeline
      built = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1)

      context_for(built, line)

      expect(compactions.first["trigger"]).to eq(%w[plan_step_completion])
    end
  end

  describe "occupancy comes from the last turn, not the run" do
    it "does not fire the approaching-window signal on a run whose cumulative usage crossed it" do
      accounting = Lain::Agent::Accounting.new
      [400, 400, 10].each_with_index do |tokens, index|
        accounting.observe(response(tokens), digest: "blake3:turn-#{index}")
      end
      built = source(need: build_need(approaching_ratio: 0.9), context_window: window_book(1_000))

      context_for(built, timeline, usage: accounting.last_turn_usage)

      expect(decisions.first["signals"]).not_to include("approaching_window")
    end

    def response(input_tokens)
      Struct.new(:usage, :model, :stop_reason)
            .new(Lain::Usage.new(input_tokens:), "claude-opus-4-8", :end_turn)
    end
  end

  describe "a resumed session does not force-compact on its first turn" do
    it "does not fire the approaching-window signal when usage is nil" do
      built = source(need: build_need(byte_threshold: 100), context_window: window_book(1_000))

      context_for(built, timeline, usage: nil)

      expect(decisions.first["signals"]).to eq(%w[token_threshold])
    end

    # At a ratio of zero every occupancy crosses the line, so the ONLY thing
    # keeping the signal quiet is nil being distinct from zero -- the
    # distinction a resumed session, whose Accounting is fresh and whose
    # Timeline is not, depends on.
    it "distinguishes an unknown occupancy from a measured zero" do
      built = source(need: build_need(byte_threshold: 100, approaching_ratio: 0.0),
                     context_window: window_book(1_000))

      context_for(built, timeline, usage: nil)
      context_for(built, timeline, usage: 0)

      expect(decisions.map { |record| record["signals"] })
        .to eq([%w[token_threshold], %w[token_threshold approaching_window]])
    end
  end

  # C1. The window is derived from the LIVE Context every turn, not fixed when
  # the Source was built -- `/model` rewrites {Context::ModelSwitch}'s slot
  # mid-session, and a window frozen at startup would keep measuring occupancy
  # against the model the run began with.
  describe "the window follows the turn's model" do
    # ONE Source, two renders. 190_000 is over 0.9 of Opus 4.5's real 200,000
    # window and far under 0.9 of Opus 4.8's 1,000,000, so the two renders can
    # only disagree if the lookup happened per turn.
    it "follows a mid-session model switch" do
      built = source

      context_for(built, timeline, base: context_naming("claude-opus-4-5"), usage: 190_000)
      context_for(built, timeline, base: context_naming("claude-opus-4-8"), usage: 190_000)

      expect(decisions.map { |record| record["signals"] })
        .to eq([%w[approaching_window], []])
    end

    # The same claim through the seam it is actually ABOUT. Two separately-built
    # Contexts prove the lookup reads its argument; only the live
    # {Context::ModelSwitch} slot -- ONE Context object, mutated between renders
    # exactly as `/model` mutates it -- proves the window follows a switch under
    # a running session, which is what "mid-session" means. Promoted from the
    # review panel's `probe-c1-live-switch.rb`.
    describe "through the live /model slot" do
      def switching(initial)
        slot = Lain::Context::ModelSwitch.new(initial, journal:)
        [slot, Lain::Context.new(model: slot, max_tokens: 1024, system: "a system prompt")]
      end

      it "stops firing when the switch is to a larger window" do
        slot, live = switching("claude-opus-4-5")
        built = source

        context_for(built, timeline, base: live, usage: 190_000)
        slot.switch("claude-opus-4-8", surface: :spec)
        context_for(built, timeline, base: live, usage: 190_000)

        expect(decisions.map { |record| record["signals"] }).to eq([%w[approaching_window], []])
      end

      it "starts firing when the switch is to a smaller window" do
        slot, live = switching("claude-opus-4-8")
        built = source

        context_for(built, timeline, base: live, usage: 190_000)
        slot.switch("claude-opus-4-5", surface: :spec)
        context_for(built, timeline, base: live, usage: 190_000)

        expect(decisions.map { |record| record["signals"] }).to eq([[], %w[approaching_window]])
      end
    end

    it "fires the approaching-window signal for a small-window model" do
      context_for(source, timeline, base: context_naming("claude-opus-4-5"), usage: 190_000)

      expect(decisions.first["signals"]).to eq(%w[approaching_window])
    end

    # An ollama/bedrock id no Anthropic-shaped table carries. 7_500 is under 0.9
    # of every real entry and over 0.9 of the 8_192 conservative fallback, so
    # only the fallback makes this fire -- and nothing raises.
    it "falls back conservatively for a model absent from the table, rather than raising" do
      built = source

      expect { context_for(built, timeline, base: context_naming("qwen3:4b"), usage: 7_500) }
        .not_to raise_error
      expect(decisions.first["signals"]).to eq(%w[approaching_window])
    end

    # Ruling of 2026-07-25: a nil or BLANK model is a wiring bug, not an
    # unsupported provider, so {ContextWindow} raises for it however the book is
    # configured. Deriving the window per turn moves that raise from startup to
    # the first render -- later, but still loud, which is the doctrine. Pinned
    # here so it stays deliberate.
    it "raises on a blank model rather than rescuing the wiring bug" do
      expect { context_for(source, timeline, base: context_naming("  ")) }
        .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
    end

    it "leaves the byte threshold untouched by the model" do
      built = source(need: build_need(byte_threshold: 100))

      context_for(built, timeline, base: context_naming("qwen3:4b"), usage: nil)

      expect(decisions.first["signals"]).to eq(%w[token_threshold])
    end
  end

  describe "every returned Context is shareable" do
    it "is shareable on the deferring path" do
      expect(Ractor.shareable?(context_for(source, timeline))).to be(true)
    end

    it "is shareable on the compacting path" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      expect(Ractor.shareable?(context_for(built, timeline))).to be(true)
    end

    it "is shareable when the eager holds live summaries" do
      line = timeline
      eager = SourceSpecEager.new(Lain::Canonical.digest(block(1)["content"]) => "a held summary")
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager:)

      expect(Ractor.shareable?(context_for(built, line))).to be(true)
    end
  end

  describe "the base pipeline it wraps" do
    it "keeps an injected pipeline the base Context is carrying" do
      injected = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024,
                                   pipeline: SourceSpecPipelines::INJECTED)
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      messages = render(context_for(built, line, base: injected), line).messages

      expect(messages.last["content"]).to eq("INJECTED-PIPELINE")
    end

    it "keeps the session reminders the default pipeline injects" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)
      workspace = Lain::Workspace.empty.with("REMEMBER THE MILK")

      messages = context_for(built, line).render(timeline: line, toolset:, workspace:).messages

      expect(Lain::Canonical.dump(messages)).to include("REMEMBER THE MILK")
    end
  end

  describe "the summaries it renders" do
    it "renders a summary the eager fired, not an elision line" do
      line = timeline
      eager = SourceSpecEager.new(Lain::Canonical.digest(block(1)["content"]) => "a held summary")
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager:)

      text = render(context_for(built, line), line).messages.first["content"].first["text"]

      expect(text).to include("a held summary")
    end

    it "reads the eager once per turn, not once per pass over the head" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      render(context_for(built, line), line)

      expect(eager.reads).to eq(messages_of(line).size - keep_last)
    end

    it "journals what the snapshot found" do
      line = timeline
      eager = SourceSpecEager.new(Lain::Canonical.digest(block(1)["content"]) => "a held summary")
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager:)

      context_for(built, line)

      expect(decisions.first).to include("summary_hits" => 1, "summary_misses" => 3, "compacted" => true)
    end
  end

  describe "the accounting it hands the scheduler" do
    it "journals tokens_before over the WHOLE history, not the head" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(compactions.first["tokens_before"]).to eq(Lain::Canonical.dump(messages_of(line)).bytesize)
    end

    it "journals tokens_after for the messages a render actually sends" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)
      messages = messages_of(line)
      summary = { "role" => "assistant",
                  "content" => [{ "type" => "text",
                                  "text" => Lain::Compaction::SummarySnapshot.new
                                                                             .call(messages[0...-keep_last]) }] }

      context_for(built, line)

      expect(compactions.first["tokens_after"])
        .to eq(Lain::Canonical.dump([summary] + messages.last(keep_last)).bytesize)
    end

    it "measures the head, not a head of the head, for the hard cap" do
      line = timeline
      head = Lain::Compaction::Head.new(messages: messages_of(line), keep_last:)
      built = source(need: build_need(byte_threshold: 100), hard_cap: head.bytesize)

      context_for(built, line)

      expect(compactions.first["cache_state"]).to eq("forced")
    end

    # The sibling constraint, from its discriminating side: a threshold between
    # the head (4,129 bytes) and the whole history (6,193) must NOT fire, which
    # is the only thing separating "Need measures what Compact will drop" from
    # the silent disagreement {Head} was written to delete.
    it "measures the candidate head against the byte threshold, not the whole history" do
      line = timeline
      head = Lain::Compaction::Head.new(messages: messages_of(line), keep_last:)
      between = (head.bytesize + Lain::Canonical.dump(messages_of(line)).bytesize) / 2
      built = source(need: build_need(byte_threshold: between), hard_cap: 1)

      expect(context_for(built, line)).to equal(base)
      expect(decisions.first["signals"]).to eq([])
    end

    # The discriminating side of the same constraint: one byte above the head is
    # BELOW the cap, while the whole history (6,193 against the head's 4,129)
    # would still cross it, so a `history_size:` derived from the wrong list
    # forces a compaction here.
    it "defers one byte above the head, where the whole history would force" do
      line = timeline
      head = Lain::Compaction::Head.new(messages: messages_of(line), keep_last:)
      built = source(need: build_need(byte_threshold: 100), hard_cap: head.bytesize + 1)

      expect(context_for(built, line)).to equal(base)
      expect(compactions).to be_empty
    end
  end

  describe "a history with nothing droppable" do
    let(:session) { instance_double(Lain::Session, plan_step_completed?: true) }

    it "answers the base untouched even when a signal fires" do
      built = source(need: build_need(byte_threshold: 1), hard_cap: 1, keep_last: 6)

      expect(context_for(built, timeline(6))).to equal(base)
      expect(compactions).to be_empty
    end
  end

  # The floor. Measured 2026-07-25: six small messages dump to 571 bytes and the
  # attestation that would replace their head dumps to 1,144 -- a compaction
  # that GROWS the prompt by 573 bytes and breaks the cache prefix to do it.
  # Six big ones go 6,193 -> 3,034. Both sides of that boundary, under signals
  # and a hard cap that would otherwise force a rewrite either way.
  describe "a compaction that would not shrink the rendered history" do
    def forcing(line) = source(need: build_need(byte_threshold: 100), hard_cap: 100).then { |s| [s, line] }

    it "answers the base untouched" do
      built, line = forcing(small_timeline)

      expect(context_for(built, line)).to equal(base)
    end

    it "journals the refusal rather than leaving it to be inferred from silence" do
      built, line = forcing(small_timeline)

      context_for(built, line)

      expect(decisions.first).to include("compacted" => false, "would_not_shrink" => true)
      expect(compactions).to be_empty
    end

    it "still compacts a history where the rewrite does shrink" do
      built, line = forcing(timeline)

      returned = context_for(built, line)

      expect(returned).not_to equal(base)
      expect(decisions.first).to include("compacted" => true, "would_not_shrink" => false)
    end

    # The floor answers "is this rewrite worth making", which is only a question
    # once the scheduler has said this turn is the turn. Asking it earlier
    # records every warm-under-cap turn on a short history as an inflation
    # refusal -- and a bench counting those would over-count by the whole
    # warm-defer population, which is the steady state.
    it "is not the reason recorded when the scheduler would defer on timing anyway" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 10**9)

      context_for(built, small_timeline)

      expect(decisions.first).to include("compacted" => false, "would_not_shrink" => false)
    end

    it "declines a rewrite that is exactly byte-neutral" do
      built, line = forcing(crossover_timeline(neutral_pad))

      expect(rewrite_delta(line)).to eq(0)
      expect(context_for(built, line)).to equal(base)
      expect(decisions.first).to include("would_not_shrink" => true)
    end

    it "takes a rewrite that saves a single byte" do
      built, line = forcing(crossover_timeline(neutral_pad + 1))

      expect(rewrite_delta(line)).to eq(-1)
      expect(context_for(built, line)).not_to equal(base)
    end
  end

  # Confirming the accepted ruling, not fixing it: a rewind rewinds the Timeline
  # and NOT Cold's warmth flags. What this pins is the half that does follow --
  # the head is re-derived from whatever Timeline the turn is handed, so a
  # rewound history is decided on the rewound bytes.
  describe "a rewound timeline" do
    it "decides on the history it is handed, turn by turn" do
      long = Lain::Compaction::Head.new(messages: messages_of(timeline(6)), keep_last:).bytesize
      built = source(need: build_need(byte_threshold: long), hard_cap: long)

      compacting = context_for(built, timeline(6))
      rewound = context_for(built, timeline(4))

      expect(compacting).not_to equal(base)
      expect(rewound).to equal(base)
    end
  end

  describe "construction" do
    it "refuses a keep_last that would destroy the whole history" do
      expect { source(keep_last: 0) }.to raise_error(ArgumentError, /keep_last must be positive/)
    end
  end

  describe "the decision it journals" do
    it "records a deferring turn" do
      context_for(source, timeline)

      expect(decisions.first)
        .to include("compacted" => false, "signals" => [], "cold" => false)
    end

    it "records the head it measured" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(decisions.first["head_bytes"])
        .to eq(Lain::Compaction::Head.new(messages: messages_of(line), keep_last:).bytesize)
    end
  end
end
