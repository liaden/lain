# frozen_string_literal: true

require "json"
require "stringio"
require "bigdecimal"

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

# The Source's un-flagged collapse policy, written out: one range over whatever
# span it is offered, collapsed into the turn's {Lain::Compaction::SummarySnapshot}.
# It exists so {#rewrite_delta} can measure the same crossover by a second path
# rather than by reaching into the Source's own private strategy.
class SourceSpecHeldSpan < Lain::Compaction::Strategy::Base
  def initialize(snapshot)
    super()
    @snapshot = snapshot
    freeze
  end

  def propose_ranges(_messages, span:) = [span]

  def blocks(messages) = [{ "type" => "text", "text" => @snapshot.call(messages) }]
end

# The span oracle {Lain::Compaction::Strategy::Summarizing} speaks to, reduced
# to the two calls it makes: `#ask(...).await.summary`. It counts its asks, so
# an example can tell "the strategy held the answer" from "the model was asked
# twice for one range".
class SourceSpecSpanOracle
  Answer = Struct.new(:summary) do
    def await = self
  end

  attr_reader :asks

  def initialize(text)
    @text = text
    @asks = 0
  end

  def ask(_inputs = {})
    @asks += 1
    Answer.new("#{@text} (#{@asks})")
  end
end

# A strategy that answers a replacement no conversation can carry: an
# `assistant`-first chain is what {Lain::Compaction::Derivation} refuses, and
# refusing is what the fallback record exists to name.
class SourceSpecStrandingSpan < Lain::Compaction::Strategy::Base
  def propose_ranges(_messages, span:) = [span]

  def blocks(_messages)
    [{ "type" => "tool_use", "id" => "call-nobody-answers", "name" => "read", "input" => {} }]
  end
end

# The handoff tier, reduced to the one call the fallback makes. It records the
# slots it was shown, so an example can prove the question was asked ONCE and
# over the held replacements rather than over the raw turns.
class SourceSpecHandoffOracle
  FIELDS = { "goal" => "finish the parser", "progress" => "the lexer lands",
             "files_and_decisions" => "lexer.rb; no regexes", "open_todos" => "the parser",
             "next_step" => "write parser.rb" }.freeze

  attr_reader :asks

  def initialize = (@asks = [])

  def ask(inputs = {})
    @asks << inputs
    Lain::Oracle::Handoff.definition.answer(FIELDS)
  end
end

# A tier whose reply the decoder cannot read. Wrapped in the real journaling
# recorder, it is what leaves an `oracle_failed` line behind.
class SourceSpecUndecodableOracle
  attr_reader :definition

  def initialize(definition) = (@definition = definition)

  def model = "qwen3:4b"

  def usage = {}

  def ask(_inputs = {}) = raise(Lain::Oracle::UndecodableAnswer, "oracle reply was not decodable JSON")
end

RSpec.describe Lain::Compaction::Source do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:clock) { SourceSpecClock.new(Time.at(1_700_000_000).utc) }
  let(:eager) { SourceSpecEager.new }
  let(:keep_last) { 2 }
  let(:session) { session_pinning }
  let(:toolset) { Lain::Toolset.new([]) }
  let(:workspace) { Lain::Workspace.empty }
  let(:base) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt") }

  # A Session that pins the turn digests it is handed. `pinned?` is the O(1)
  # membership test the per-turn path asks (session.rb:153); `#pins` sorts on
  # every call and is deliberately NOT what a hot loop reaches for.
  #
  # It holds NO compaction cut and keeps none it is handed, so every render
  # through it is a decision over the uncut history -- which is what the
  # examples using it are about. A cut that sticks is a real Session's, and
  # the group that holds one builds one (see {#recording_session}).
  def session_pinning(*digests, plan_step_completed: false)
    instance_double(Lain::Session, plan_step_completed?: plan_step_completed, compaction_cuts: [],
                                   plan_step_completions: plan_step_completed ? 1 : 0).tap do |double|
      allow(double).to receive(:pinned?) { |digest| digests.include?(digest) }
      allow(double).to receive(:record_compaction_cut).and_return(double)
    end
  end

  # A real Session journaling into the example's own journal, so the cuts it
  # records land beside the decisions and edges that led to them.
  def recording_session = Lain::Session.new(journal:)

  def todo(content, status) = Struct.new(:content, :status).new(content, status)

  def complete_a_step(session, count = 1)
    session.write_todos(Array.new(count) { |index| todo("step #{index}", "completed") })
  end

  def records
    journal_io.string.each_line.map { |line| JSON.parse(line) }
  end

  def decisions = records.select { |record| record["type"] == "compaction_decision" }

  def compactions = records.select { |record| record["type"] == "compaction" }

  # Substantial text messages, in a WELL-FORMED conversation: roles alternate
  # from `user`, and no block claims to answer a tool call nothing made.
  #
  # THE SHAPE IS NOW LOAD-BEARING, and it was not before. These fixtures used to
  # be a run of `user` turns each carrying an orphan `tool_result` -- an array
  # the Messages API would reject -- which was invisible while compaction was a
  # render-time projection. {Lain::Compaction::Derivation} validates the chain it
  # derives through {Lain::Context::Conversation} and REFUSES an invalid one, so
  # an ill-formed fixture measures a compaction that never runs: `compacted:
  # false`, nothing raised, every byte assertion quietly about the uncompacted
  # history. The tier that keys on tool_results is exercised through
  # {#tool_timeline} below, which carries a real, answered pair.
  #
  # They are BIG on purpose. An elision line attests its message (role, digest,
  # byte counts, one line per block) in ~230 bytes, so a history of small
  # messages is one that compaction would GROW -- the case the floor in #decide
  # refuses, exercised by {#small_block} below.
  def block(index)
    { "type" => "text", "text" => "the quick brown fox jumped over the lazy dog, result number #{index}. " * 15 }
  end

  def small_block(index) = { "type" => "text", "text" => "result #{index}" }

  # `user, user, assistant, user, assistant, user, ...`: it opens on `user`, it
  # ENDS on `user`, and no two `assistant` turns are adjacent -- which is
  # exactly what {Lain::Context::Conversation} asks of a conversation (adjacent
  # `user` messages are the real Agent shape, a tool_result turn followed by the
  # human's next ask, and they are legal). Ending on `user` is what lets
  # {Lain::Context::Reminder} still find somewhere to inject.
  def role_at(index) = index.odd? && index > 1 ? "assistant" : "user"

  def timeline(size = 6, &block_for)
    block_for ||= method(:block)
    (1..size).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, index|
      line.commit(role: role_at(index), content: [block_for.call(index)])
    end
  end

  def small_timeline(size = 6) = timeline(size) { |index| small_block(index) }

  # The eager tier keys a summary on a String-content `tool_result`'s own
  # content address, so a fixture that exercises a HIT has to carry a real tool
  # exchange rather than a loose tool_result: an `assistant` tool_use answered
  # by the `user` tool_result immediately after it, which is the only shape
  # `Agent#perform_tools` commits (Correctness gate 2, agent.rb:326-328).
  #
  # The pair sits at indices 1-2, wholly inside the droppable span at
  # `keep_last: 2`, so {Lain::Compaction::Boundary} never has to move the cut
  # off it and the examples stay about the summary rather than about the cut.
  def tool_body(index) = "the quick brown fox jumped over the lazy dog, result number #{index}. " * 15

  # Parameterized on the tool result's OWN content, so an example can put it
  # on either edge of {Lain::Oracle::RoutedSummarizer}'s size window -- too
  # small to be worth a model call, comfortably inside the window, or too
  # large for {Lain::Oracle::RoutedSummarizer::INPUT_BOUND} to admit.
  def tool_timeline_with(content)
    [["user", [block(1)]],
     ["assistant", [{ "type" => "tool_use", "id" => "call-2", "name" => "read", "input" => { "n" => 2 } }]],
     ["user", [{ "type" => "tool_result", "tool_use_id" => "call-2", "content" => content }]],
     ["assistant", [block(4)]], ["user", [block(5)]], ["user", [block(6)]]]
      .inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, (role, content)|
        line.commit(role:, content:)
      end
  end

  def tool_timeline = tool_timeline_with(tool_body(2))

  # The floor's crossover, found by walking ONE dropped body a character at a
  # time (the re-review's `probe_a6_floor_cost.rb`): at 361 Z's the canonical
  # history and its rewrite both dump to 1,595 bytes, 360 inflates by one byte
  # and 362 saves one. The examples assert the delta they claim to sit on, so a
  # change in canonical framing fails loudly here rather than sliding the
  # fixture quietly off the boundary.
  #
  # MOVED ONCE, 366 -> 361: the summary message's role went from `"assistant"`
  # to `"user"` (Open decisions ruling), five fewer bytes in the canonical dump.
  # MOVED AGAIN, 361 -> 85, because the fixture's blocks are now `text`
  # rather than orphan `tool_result`s (see {#block}), its roles alternate, and
  # the rewrite being measured is the DERIVED chain's projection rather than
  # `Context::Compact`'s. Walked one character at a time, as before: at 85 Z's
  # the history and its rewrite dump to the same size, 84 inflates by one byte
  # and 86 saves one. Re-measured to the byte rather than loosened to a range,
  # which is what makes it still able to fail loudly.
  def neutral_pad = 85

  def crossover_timeline(pad)
    bodies = (1..5).map { |index| "pad#{index}-#{"m" * 100}" } + ["Z" * pad, "tail-a", "tail-b"]
    bodies.each_with_index.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, (body, index)|
      line.commit(role: role_at(index + 1), content: [{ "type" => "text", "text" => body }])
    end
  end

  # What the floor measures, measured independently: the bytes the DERIVED chain
  # would add to or remove from the rendered history.
  #
  # It mirrors the Source's un-flagged policy -- one range over the whole
  # droppable span, collapsed into a {Lain::Compaction::SummarySnapshot} -- with
  # its own strategy rather than reaching into the Source's private one, so the
  # crossover is still measured by a second, independent path.
  def rewrite_delta(line)
    messages = messages_of(line)
    head = Lain::Compaction::Head.new(messages:, keep_last:)
    snapshot = Lain::Compaction::SummarySnapshot.take(messages: head.messages,
                                                      eager: Lain::Compaction::Source::NoSummaries)
    derived = Lain::Compaction::Derivation.new(strategy: SourceSpecHeldSpan.new(snapshot), keep_last:).derive(line)
    Lain::Canonical.dump(Lain::Compaction::Derivation.projected(derived.to_a)).bytesize -
      Lain::Canonical.dump(messages).bytesize
  end

  def messages_of(line) = line.to_a.map { |turn| { "role" => turn.role, "content" => turn.content } }

  def build_need(byte_threshold: 1_000_000, approaching_ratio: 0.9)
    Lain::Compaction::Need.new(byte_threshold:, approaching_ratio:)
  end

  # A book that answers ONE window for every model these examples name, for the
  # ones that are about the ratio rather than about model resolution. A blank
  # model still raises through it.
  #
  # A PUBLISHED book, keyed by the family token every model in this file
  # carries, and NOT the `fallback:` form it used to be: a fallback is
  # by construction a GUESS, and a guessed window never fires
  # `:approaching_window` -- so the fallback form would make every ratio
  # example here pass vacuously. {#guessed_window_book} is the other side, and
  # is used only where the guess itself is the subject.
  def window_book(tokens) = Lain::ContextWindow.new(windows: { "claude" => tokens })

  # The guessed shape: nothing in the table matched, so the number is a floor
  # somebody picked rather than anything known about the model.
  def guessed_window_book(tokens) = Lain::ContextWindow.new(windows: {}, fallback: tokens)

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

  # Before the first cut commits. Once one has, a deferring turn renders the
  # cut's replacement rather than the base -- see "a committed compaction cut".
  describe "deferring, before any cut has committed, is a true no-op" do
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
    let(:session) { session_pinning(plan_step_completed: true) }

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
      line = timeline
      [400, 400, 10].each_with_index do |tokens, index|
        accounting.observe(response(tokens), digest: line.to_a[index].digest)
      end
      built = source(need: build_need(approaching_ratio: 0.9), context_window: window_book(1_000))

      expect(accounting.last_turn_usage(on: line)).to eq(10)
      context_for(built, line, usage: accounting.last_turn_usage(on: line))

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

  # The window is derived from the LIVE Context every turn, not fixed when
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

    # An ollama id no Anthropic-shaped table carries. 7_500 is under 0.9
    # of every real entry and over 0.9 of the 8_192 conservative fallback, so
    # the fallback is what is being measured against -- and it still degrades
    # rather than raising.
    #
    # It does NOT fire. This example asserted the opposite until it was
    # corrected, which is the defect written down as a test: a 32,768-token
    # qwen3 runner read as 300% full against the guess, and lain rewrote
    # history three times. The DENOMINATOR is still journaled, because a reader
    # has to be able to see which number the silence was about.
    it "does not authorise a rewrite off a window it guessed" do
      built = source

      context_for(built, timeline, base: context_naming("qwen3:4b"), usage: 7_500)

      expect(decisions.first["signals"]).to eq([])
      expect(decisions.first["window_tokens"]).to eq(Lain::ContextWindow::CONSERVATIVE_FALLBACK)
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

  # `:approaching_window` is the one signal that spends a number the
  # bench may have INVENTED, and what it buys is an irreversible lossy rewrite.
  # The `context_window.rb` comment this card amends argued the early firing
  # was "self-correcting, not a one-shot latch" -- true about FREQUENCY, and
  # silent about damage: QA watched three separate rewrites at 75-78% of a real
  # 32,768-token window that the book had guessed at 8,192.
  #
  # Provenance is THREE-valued, and only the guess is denied. A shipped-table
  # hit is a real published number, and it is what a hosted run is measured
  # against -- suppressing THAT would switch compaction off for every
  # Anthropic arm.
  describe "only an authoritative window may authorise a rewrite" do
    # 7_500 is over 0.9 of 8_192 and under 0.9 of any real entry, so the ratio
    # is crossed on every book below and provenance is the only variable.
    def crossing(book) = source(need: build_need(approaching_ratio: 0.9), context_window: book)

    it "does not fire the approaching-window trigger on a guessed window" do
      context_for(crossing(guessed_window_book(8_192)), timeline, usage: 7_500)

      expect(decisions.first["signals"]).not_to include("approaching_window")
    end

    it "fires it on a published table window" do
      context_for(crossing(Lain::ContextWindow.new(windows: { "claude-opus-4-8" => 8_192 })),
                  timeline, usage: 7_500)

      expect(decisions.first["signals"]).to include("approaching_window")
    end

    # The shipped book, through the id an Anthropic arm actually runs under --
    # the regression the panel caught, asserted rather than argued.
    it "fires it on the bench's own default book for a hosted model" do
      context_for(source(need: build_need(approaching_ratio: 0.9)), timeline,
                  base: context_naming("claude-opus-4-5"), usage: 190_000)

      expect(decisions.first["signals"]).to eq(%w[approaching_window])
    end

    # {CLI::Backend::WindowBook::Served} is the only PROBED window there is:
    # ollama's `/api/ps` naming the runner that is resident right now.
    it "fires it on a window probed from the provider" do
      served = Lain::CLI::Backend::WindowBook::Served.new(model: "claude-opus-4-8", window_tokens: 8_192)

      context_for(crossing(served), timeline, usage: 7_500)

      expect(decisions.first["signals"]).to include("approaching_window")
    end

    # A Served book answering for a model it did NOT probe is published (or
    # guessed) by whatever `shipped` says, never probed -- getting that
    # backwards would re-create that defect in the opposite direction, handing a
    # rewrite the authority of a runner that was never asked about this model.
    it "does not fire it for a model a Served book merely delegated" do
      served = Lain::CLI::Backend::WindowBook::Served.new(
        model: "qwen3", window_tokens: 32_768, shipped: guessed_window_book(8_192)
      )

      context_for(crossing(served), timeline, base: context_naming("qwen3:4b"), usage: 7_500)

      expect(decisions.first["signals"]).not_to include("approaching_window")
    end

    # A withdrawn signal must leave a trace. `signals: []` from a denial and
    # `signals: []` from a turn nowhere near the threshold are the same bytes
    # and opposite facts, and this class's own docstring is that "an
    # unrecorded decision is a missing measurement". The denominator alone is
    # not enough: it names the number, not that a decision was taken about it.
    describe "the decision records which kind of window it was taken against" do
      it "names the guess on a denied turn" do
        context_for(crossing(guessed_window_book(8_192)), timeline, usage: 7_500)

        expect(decisions.first).to include("provenance" => "guessed", "window_tokens" => 8_192,
                                           "used_tokens" => 7_500, "signals" => [])
      end

      it "names the table on a published turn" do
        context_for(crossing(Lain::ContextWindow.new(windows: { "claude-opus-4-8" => 8_192 })),
                    timeline, usage: 7_500)

        expect(decisions.first).to include("provenance" => "published")
      end

      it "names the probe on a served turn" do
        served = Lain::CLI::Backend::WindowBook::Served.new(model: "claude-opus-4-8", window_tokens: 8_192)

        context_for(crossing(served), timeline, usage: 7_500)

        expect(decisions.first).to include("provenance" => "probed")
      end

      # The two records the reviewer measured as indistinguishable. They still
      # share a signal list; provenance is the only thing telling them apart,
      # so it is asserted as the DIFFERENCE rather than as two constants.
      it "tells a denied trigger from a turn that was simply not full" do
        context_for(crossing(guessed_window_book(8_192)), timeline, usage: 7_500)
        context_for(crossing(Lain::ContextWindow.new(windows: { "claude" => 1_000_000 })),
                    timeline, usage: 7_500)

        expect(decisions.map { |record| record["signals"] }).to eq([[], []])
        expect(decisions.map { |record| record["provenance"] }).to eq(%w[guessed published])
      end

      # It rides every decision, not just the interesting ones -- a compacting
      # turn goes through a different journal path (`#commit`, not `#defer`).
      it "records it on a compacting turn too" do
        built = source(need: build_need(byte_threshold: 100), hard_cap: 100,
                       context_window: guessed_window_book(8_192))

        context_for(built, timeline, usage: 7_500)

        expect(decisions.first).to include("compacted" => true, "provenance" => "guessed")
      end
    end

    # Provenance suppresses ONE trigger. The hard cap is a history-size
    # question with no window in it at all, and a guess must not buy it a
    # reprieve either.
    it "leaves the hard cap firing under a guessed window" do
      built = source(need: build_need(byte_threshold: 100, approaching_ratio: 0.9),
                     hard_cap: 100, context_window: guessed_window_book(8_192))

      context_for(built, timeline, usage: 7_500)

      expect(decisions.first["signals"]).to eq(%w[token_threshold])
      expect(decisions.first["compacted"]).to be(true)
    end
  end

  # The other half of the pair: the WINDOW already follows the live model, but
  # the PRICE was left behind -- the Source is priced once, at construction, so
  # after a `/model` switch it would go on quoting dollars at the rate of a
  # model that is no longer answering. It now names what actually ran and
  # quotes nothing, which is {PriceBook}'s own refusal one tier up.
  describe "the price follows the turn's model too" do
    def switchable(initial)
      slot = Lain::Context::ModelSwitch.new(initial, journal:)
      [slot, Lain::Context.new(model: slot, max_tokens: 1024, system: "a system prompt")]
    end

    def forced(model:)
      source(need: build_need(byte_threshold: 100), hard_cap: 100, model:)
    end

    it "quotes real figures while the priced model is still the one answering" do
      built = forced(model: "claude-opus-4-8")

      context_for(built, timeline, base: context_naming("claude-opus-4-8"))

      expect(compactions.first).to include("model" => "claude-opus-4-8")
      expect(BigDecimal(compactions.first["cost_saved"])).to be > BigDecimal(0)
      expect(BigDecimal(compactions.first["cost_spent"])).to be > BigDecimal(0)
    end

    # The claim through the seam it is actually about: ONE live Context whose
    # {Context::ModelSwitch} slot is rewritten between renders, exactly as
    # `/model` rewrites it under a running session.
    it "quotes nothing once a live /model switch has moved off the priced model" do
      slot, live = switchable("claude-opus-4-8")
      built = forced(model: "claude-opus-4-8")

      context_for(built, timeline, base: live)
      slot.switch("claude-sonnet-4-6", surface: :spec)
      context_for(built, timeline, base: live)

      before, after = compactions
      expect(before).to include("model" => "claude-opus-4-8")
      expect(after).to include("model" => "claude-sonnet-4-6", "cost_saved" => nil, "cost_spent" => nil)
    end

    # A reader of the NDJSON must be able to tell a refusal from a genuinely
    # free compaction without knowing any Ruby, so this asserts on the BYTES:
    # a refusal is a JSON `null`, a real zero is the string `"0.0"`.
    it "is a JSON null on the wire, never the string a real zero writes" do
      slot, live = switchable("claude-opus-4-8")
      built = forced(model: "claude-opus-4-8")

      context_for(built, timeline, base: live)
      slot.switch("claude-sonnet-4-6", surface: :spec)
      context_for(built, timeline, base: live)

      lines = journal_io.string.each_line.select { |line| line.include?(%("type":"compaction")) }
      expect(lines.last).to include(%("cost_saved":null), %("cost_spent":null))
      expect(lines.last).not_to include(%("cost_saved":"0.0"))
    end

    # nil-model and switched-model are DIFFERENT states. An unpriced Source
    # never quoted anything to invalidate, so it keeps journalling the zeros
    # {Telemetry::Compaction}'s header documents -- byte-identically, whatever
    # the live model is doing.
    it "leaves an unpriced Source journalling zeros beside a nil model, not absence" do
      slot, live = switchable("claude-opus-4-8")
      built = forced(model: nil)

      context_for(built, timeline, base: live)
      slot.switch("claude-sonnet-4-6", surface: :spec)
      context_for(built, timeline, base: live)

      expect(compactions).to all(include("model" => nil, "cost_saved" => "0.0", "cost_spent" => "0.0"))
    end

    it "leaves the decision itself untouched -- the same signals, the same rewrite, either side" do
      slot, live = switchable("claude-opus-4-8")
      built = forced(model: "claude-opus-4-8")
      line = timeline

      before = render(context_for(built, line, base: live), line).messages
      slot.switch("claude-sonnet-4-6", surface: :spec)
      after = render(context_for(built, line, base: live), line).messages

      expect(Lain::Canonical.dump(after)).to eq(Lain::Canonical.dump(before))
      expect(decisions.map { |record| record["compacted"] }).to eq([true, true])
    end
  end

  describe "every returned Context is shareable" do
    it "is shareable on the deferring path" do
      expect(context_for(source, timeline)).to be_deeply_frozen
    end

    it "is shareable on the compacting path" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      expect(context_for(built, timeline)).to be_deeply_frozen
    end

    it "is shareable when the eager holds live summaries" do
      line = tool_timeline
      eager = SourceSpecEager.new(Lain::Canonical.digest(tool_body(2)) => "a held summary")
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager:)

      expect(context_for(built, line)).to be_deeply_frozen
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

  # The eager tier still reaches the render now that it sits on the derived
  # chain. It is no longer {Context::Compact}'s summarizer -- it is the
  # un-flagged COLLAPSE POLICY's, read through the same per-turn
  # {SummarySnapshot} -- and these assert the summary a dispatch fired still
  # arrives where an unwired run would carry an elision line.
  describe "the summaries it renders" do
    def held_summaries(text) = SourceSpecEager.new(Lain::Canonical.digest(tool_body(2)) => text)

    it "renders a summary the eager fired, not an elision line" do
      line = tool_timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager: held_summaries("a held summary"))

      text = render(context_for(built, line), line).messages.first["content"].first["text"]

      expect(text).to include("a held summary")
    end

    # The snapshot is taken ONCE per turn rather than rebuilt inside each pass a
    # compacting turn makes over the head. One lookupable block in the droppable
    # span, so three passes would read three times.
    it "reads the eager once per lookupable block, not once per pass over the head" do
      line = tool_timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      render(context_for(built, line), line)

      expect(eager.reads).to eq(1)
    end

    it "journals what the snapshot found" do
      line = tool_timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager: held_summaries("a held summary"))

      context_for(built, line)

      expect(decisions.first).to include("summary_hits" => 1, "summary_misses" => 0, "compacted" => true)
    end

    # A miss alone cannot tell "too small to be worth a model call" from a
    # summarizer that is simply down. {#tool_body}'s 945 bytes sits well under
    # {Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES}'s 4096, so the
    # run's default (empty) eager never holding one here is the HEALTHY
    # explanation, and the record has to say so rather than read exactly like
    # the dead-tier case.
    it "says every miss was size-declined when the candidate block is under the summarizer threshold" do
      line = tool_timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(decisions.first)
        .to include("summary_hits" => 0, "summary_misses" => 1, "misses_all_size_declined" => true)
    end

    # The mirror case: once the summarizer actually answered, the record must
    # not also claim a size-decline that never happened. `misses_all_size_declined`
    # is scoped to MISSES, not to the turn, so it stays readable beside a hit.
    it "reports the hit and no size decline once the summarizer answered" do
      line = tool_timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, eager: held_summaries("a held summary"))

      context_for(built, line)

      expect(decisions.first).to include("summary_hits" => 1, "misses_all_size_declined" => false)
    end

    # The gate is a WINDOW, not a floor: a miss big enough to have been worth
    # asking a model about (over 4096 bytes, still under the 256 KiB ceiling)
    # is a genuine attempt-and-failure, not a size decline -- pinning the
    # threshold's UPPER side of "explained", not just the flip from a hit.
    it "does not call a miss size-declined once it clears the threshold" do
      line = tool_timeline_with("x" * (Lain::Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES + 1))
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(decisions.first)
        .to include("summary_misses" => 1, "misses_all_size_declined" => false)
    end

    # The gate's OTHER edge: a tool result over the paid tier's input ceiling
    # is declined exactly as symmetrically as one under the threshold -- no
    # model asked either way -- so it must read as size-declined too, not as
    # an unexplained miss. A routine oversized `web_fetch` body is exactly
    # this case, not an exotic one.
    it "calls a miss size-declined when it is over the input ceiling, not only when it is under the threshold" do
      line = tool_timeline_with("x" * (Lain::Oracle::RoutedSummarizer::INPUT_BOUND.limit + 1))
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(decisions.first)
        .to include("summary_misses" => 1, "misses_all_size_declined" => true)
    end
  end

  describe "the accounting it hands the scheduler" do
    it "journals bytes_before over the WHOLE history, not the head" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, line)

      expect(compactions.first["bytes_before"]).to eq(Lain::Canonical.dump(messages_of(line)).bytesize)
    end

    it "journals bytes_after for the messages a render actually sends" do
      line = timeline
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)
      messages = messages_of(line)
      # `user`, fixed by the Open decisions ruling and never computed from the
      # history's parity: with nothing pinned the summary IS `messages[0]`, and
      # the Messages API requires that to be `user`.
      summary = { "role" => "user",
                  "content" => [{ "type" => "text",
                                  "text" => Lain::Compaction::SummarySnapshot.new
                                                                             .call(messages[0...-keep_last]) }] }

      context_for(built, line)

      expect(compactions.first["bytes_after"])
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
    let(:session) { session_pinning(plan_step_completed: true) }

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

  # This is the ONE object holding both the timeline and the session, so it
  # is the only place a pin -- recorded as a turn DIGEST -- can be mapped onto
  # the projected TEXT {Context::Compact} filters on. The head and the Compact
  # are handed the SAME {Context::PinnedMessages} value, which is what makes
  # "what Need measured" and "what Compact removes" the same list by
  # construction rather than by agreement.
  describe "the pins it must not elide" do
    def digests_of(line) = line.to_a.map(&:digest)

    def pins_for(line, *indices) = Lain::Context::PinnedMessages.new(messages_of(line).values_at(*indices))

    def head_for(line, pins: Lain::Context::PinnedMessages::NONE)
      Lain::Compaction::Head.new(messages: messages_of(line), keep_last:, pins:)
    end

    def forcing = source(need: build_need(byte_threshold: 100), hard_cap: 100)

    # Scenario: a pinned message survives a compaction verbatim, IN POSITION.
    #
    # RE-TITLED AND RE-POINTED. This used to read "ahead of
    # the summary message", because `Compact#call` PARTITIONED the span and
    # hoisted every protected message to the front -- so a pin from the middle
    # of the span landed at index 0, ahead of the summary of everything that
    # preceded it, with its own predecessor gone. Reading order inverted.
    #
    # RE-POINTED AGAIN, and the count moved with it. A pin is now a CUT
    # POINT rather than a shield (`#ranges` is an interval partition): the
    # span becomes one range per contiguous run of unpinned messages, so the pin
    # is not lifted out of a collapse at all -- it simply falls in no range, and
    # the derivation retains it, between the summary of what preceded it and the
    # summary of what followed. That is TWO replacements around one pin where
    # `Compact` emitted one, and it is the placement that keeps reading order
    # under any pin set rather than only under a single-replacement one.
    it "renders the pinned turn verbatim, between the summaries either side of it" do
      line = timeline
      pinning = session_pinning(digests_of(line)[1])

      messages = render(context_for(forcing, line, session: pinning), line).messages

      expect(messages.size).to eq(keep_last + 3)
      expect(messages[0]["content"].first["text"]).to include("elided")
      expect(messages[1]["content"].first).to eq(block(2))
      expect(messages[2]["content"].first["text"]).to include("elided")
    end

    it "leaves the unpinned head summarized, so the pin costs only its own bytes" do
      line = timeline
      pinning = session_pinning(digests_of(line)[1])

      messages = render(context_for(forcing, line, session: pinning), line).messages
      attested = messages.values_at(0, 2).map { |message| message["content"].first["text"] }.join("\n")

      expect(attested).not_to include(block(2)["text"])
      expect(attested.lines.grep(/^\[user |^\[assistant /).size).to eq(3)
    end

    # Scenario: pinning everything droppable declines the compaction rather than
    # emitting an empty summary. `SummarySnapshot::NOTHING` exists for Compact's
    # empty-summarizable path, but a Source that reached it would have broken
    # the cache prefix to say "(nothing to summarize)".
    it "declines rather than emitting an empty summary when every droppable turn is pinned" do
      line = timeline
      pinning = session_pinning(*digests_of(line).first(4), plan_step_completed: true)

      returned = context_for(forcing, line, session: pinning)

      expect(returned).to equal(base)
      expect(Lain::Canonical.dump(render(returned, line).cache_payload))
        .to eq(Lain::Canonical.dump(render(base, line).cache_payload))
      expect(compactions).to be_empty
    end

    # Scenario: a pin-shrunk head that no longer saves bytes is journalled as
    # not shrinking. A completed plan step is a non-byte detector, so it fires
    # on a short unpinned head -- and here the only unpinned droppable message
    # is smaller than the ~230-byte attestation that would replace it.
    it "journals a pin-shrunk head that no longer saves bytes as not shrinking" do
      line = timeline(6) { |index| index == 3 ? small_block(index) : block(index) }
      pinning = session_pinning(*digests_of(line).values_at(0, 1, 3), plan_step_completed: true)
      built = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1)

      expect(context_for(built, line, session: pinning)).to equal(base)
      expect(decisions.first).to include("compacted" => false, "would_not_shrink" => true)
    end

    # Scenario: Compact's own threshold measures the same set the Head measured.
    # A byte threshold BETWEEN the unpinned head and the whole candidate span
    # must not fire -- that gap is the over-report a protection-agnostic head
    # used to produce, and Need firing across it is the silent disagreement
    # {Head} exists to delete.
    it "measures the byte threshold on the unpinned head, not on the whole candidate span" do
      line = timeline
      pins = pins_for(line, 1)
      between = (head_for(line, pins:).bytesize + head_for(line).bytesize) / 2
      built = source(need: build_need(byte_threshold: between), hard_cap: 1)

      expect(context_for(built, line, session: session_pinning(digests_of(line)[1]))).to equal(base)
      expect(decisions.first["signals"]).to eq([])
      expect(decisions.first["head_bytes"]).to eq(head_for(line, pins:).bytesize)
    end

    it "journals the head it measured with the pinned bytes taken out" do
      line = timeline
      pinning = session_pinning(digests_of(line)[1])

      context_for(forcing, line, session: pinning)

      expect(decisions.first["head_bytes"]).to eq(head_for(line, pins: pins_for(line, 1)).bytesize)
      expect(decisions.first["head_bytes"]).to be < head_for(line).bytesize
    end

    it "behaves exactly as an unpinned run when the session pins nothing" do
      line = timeline
      unpinned = render(context_for(forcing, line), line)

      expect(Lain::Canonical.dump(unpinned.cache_payload))
        .to eq(Lain::Canonical.dump(render(context_for(forcing, line, session: session_pinning), line)
                                      .cache_payload))
    end

    it "still hands the scheduler a shareable Context when a pin is in force" do
      line = timeline
      pinning = session_pinning(digests_of(line)[1])

      expect(context_for(forcing, line, session: pinning)).to be_deeply_frozen
    end
  end

  describe "construction" do
    it "refuses a keep_last that would destroy the whole history" do
      expect { source(keep_last: 0) }.to raise_error(ArgumentError, "keep_last must be positive, got 0")
    end

    # The rule is CONSULTED, not re-enacted: it used to be applied by building a
    # throwaway Head over an empty message list purely for its constructor's
    # refusal, which is an object allocated for its side effect and discarded.
    it "applies the rule without building a throwaway Head" do
      allow(Lain::Compaction::Head).to receive(:new).and_call_original

      source

      expect(Lain::Compaction::Head).not_to have_received(:new)
    end
  end

  # A journalled compaction has to name the ARM it ran under -- the one
  # axis `--compact-strategy` exists to vary -- and the {Lain::Compaction::Scheduler}
  # that writes the record cannot: it is handed a pipeline, not a policy. So the
  # operator's word rides in the slot the policy already rides in, and this
  # object answers it for whoever journals. {Lain::CLI::Backend::SpanSummarizer
  # .resolve} is what fills that slot on the live path.
  describe "the collapse arm it can name" do
    def collapse(policy: nil, name: nil) = Lain::Compaction::Source::Collapse.new(policy:, name:)

    def forcing(**overrides) = source(need: build_need(byte_threshold: 100), hard_cap: 100, **overrides)

    # The disjoint pair {Lain::CLI::CompactionStrategy} recommends, composed the
    # way that resolver composes it -- so what is under test here is the same
    # object `--compact-strategy elide-tools+summarize-conversation` builds.
    def composed
      Lain::Compaction::Strategy::ElideToolObservations.new |
        Lain::Compaction::Strategy::SummarizeConversation.new(oracle: SourceSpecSpanOracle.new("a span summary"))
    end

    def rendered(built, line) = Lain::Canonical.dump(render(context_for(built, line), line).cache_payload)

    it "derives exactly what the same policy derives with no word attached" do
      line = timeline
      named = forcing(strategy: collapse(policy: composed, name: "elide-tools+summarize-conversation"))
      plain = forcing(strategy: composed)

      expect(rendered(named, line)).to eq(rendered(plain, line))
      expect(decisions.map { |record| record["compacted"] }).to eq([true, true])
    end

    # Verbatim, `+` and all: a bench groups `bytes_before - bytes_after` by this
    # string with no launch command to hand, so a normalisation of it would be a
    # second vocabulary for one arm.
    it "names the composition as the operator typed it" do
      built = source(strategy: collapse(policy: composed, name: "elide-tools+summarize-conversation"))

      expect(built.collapse_strategy).to eq("elide-tools+summarize-conversation")
    end

    # An unflagged run is not "no arm". It is the CONTROL arm -- the eager
    # tool-result tier every `--compact-strategy` run is measured against
    # ({Lain::CLI::Backend::SpanSummarizer}'s own doc argues it) -- and nil is
    # reserved for a record written before the field existed.
    it "names the eager control arm for a run that set no flag" do
      expect(source.collapse_strategy).to eq(Lain::Telemetry::Compaction::EAGER_CONTROL_ARM)
    end

    it "falls back to the policy's own name for a caller that gave no word" do
      built = source(strategy: Lain::Compaction::Strategy::Elide.new)

      expect(built.collapse_strategy).to eq("Lain::Compaction::Strategy::Elide")
    end

    # What travels onward is a String and only a String: the policy may hold a
    # live oracle and a mutable memo, and the record it ends up in is journalled
    # from a scheduler whose combinator is `Ractor.make_shareable`d.
    it "answers a frozen String" do
      expect(source(strategy: collapse(policy: composed, name: "elide")).collapse_strategy).to be_frozen
    end

    # The policy reaches the derivation UNWRAPPED -- `spec/lain/cli/backend_spec.rb`
    # and `spec/lain/cli/chat_flags_spec.rb` read it back along this exact path,
    # and a choice object standing in its place would change what they find.
    it "hands the derivation the policy itself, never the choice around it" do
      policy = composed
      built = source(strategy: collapse(policy:, name: "elide-tools+summarize-conversation"))

      expect(built.instance_variable_get(:@derived).instance_variable_get(:@strategy)).to equal(policy)
    end

    # The reason the name is held here at all. This is the only object
    # holding both the arm's word and the {Lain::Compaction::Scheduler} that
    # writes the accounting -- the scheduler is handed a PIPELINE and can name
    # no policy behind it -- so the word travels per call out of #commit.
    it "journals the compaction under the arm the run was wired with" do
      built = forcing(strategy: collapse(policy: composed, name: "elide-tools+summarize-conversation"))

      context_for(built, timeline)

      expect(compactions.map { |record| record["collapse_strategy"] })
        .to eq(["elide-tools+summarize-conversation"])
    end

    it "journals the eager control arm on a run that set no flag" do
      context_for(forcing, timeline)

      expect(compactions.map { |record| record["collapse_strategy"] })
        .to eq([Lain::Telemetry::Compaction::EAGER_CONTROL_ARM])
    end
  end

  # What a compacting turn actually renders is the projection of a SECOND
  # LINEAGE -- a derived chain materialized in the source's own Store, whose
  # replacement events name the source turns they subsume. These are the claims
  # that only hold once the render goes through it.
  describe "rendering through the derived chain" do
    def forcing(**overrides) = source(need: build_need(byte_threshold: 100), hard_cap: 100, **overrides)

    def derivations = records.select { |record| record["type"] == "context_derived" }

    def refusals = records.select { |record| record["type"] == "derivation_refused" }

    def chain_at(digest, store) = Lain::Timeline.new(head_digest: digest, store:)

    def projection_of(digest, store)
      Lain::Compaction::Derivation.projected(chain_at(digest, store).to_a)
    end

    it "renders the projection of the derived head the journal names" do
      line = timeline

      messages = render(context_for(forcing, line), line).messages

      expect(derivations.size).to eq(1)
      expect(messages.map { |message| message["role"] })
        .to eq(projection_of(derivations.first["derived_head"], line.store).map { |m| m["role"] })
      expect(Lain::Canonical.dump(messages.first))
        .to eq(Lain::Canonical.dump(projection_of(derivations.first["derived_head"], line.store).first))
    end

    # The session timeline is the LOSSLESS record and a derivation is a reader
    # of it. The replacement events land in the Store -- content-addressed
    # storage is append-only -- but nothing about the chain the Agent holds
    # moves, so its head advances only by committed turns.
    it "leaves the source timeline's head where it found it" do
      line = timeline
      before = line.head_digest

      context_for(forcing, line)

      expect(line.head_digest).to eq(before)
      expect(derivations.first["derived_head"]).not_to eq(before)
      expect(derivations.first["source_head"]).to eq(before)
    end

    # As a characterization example: `A <= B` does NOT imply
    # `derive(A) <= derive(B)`. `Event#payload` folds `render_parent`, so a
    # retained turn re-committed under a new parent chain gets a different
    # address, and the `keep_last` window slides besides. The wrong conceptual
    # model this exists to prevent is "derivation is incremental" -- if it ever
    # fails because someone made derivation prefix-preserving, that is a real
    # achievement and needs confirming, not deleting.
    #
    # It holds for a derivation taken with NO cut held, which is what the
    # stand-in session gives it. A held cut changes the meaning, confirmed
    # below: between two advances the derived chain does extend.
    it "is not a functor on the prefix order" do
      shorter = timeline(6)
      longer = shorter.commit(role: role_at(7), content: [block(7)])
      built = forcing

      context_for(built, shorter)
      context_for(built, longer)

      first, second = derivations.map { |record| record["derived_head"] }
      expect(first).not_to eq(second)
      expect(chain_at(second, longer.store).ancestor_digests).not_to include(first)
      expect(chain_at(first, shorter.store).ancestor_digests).not_to include(second)
    end

    it "extends the derived chain turn by turn while a committed cut holds and nothing new collapses" do
      session = recording_session
      complete_a_step(session)
      built = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1)
      line = timeline(6)
      context_for(built, line, session:)
      shorter = line.commit(role: role_at(7), content: [block(7)])
      longer = shorter.commit(role: role_at(8), content: [block(8)])

      context_for(built, shorter, session:)
      context_for(built, longer, session:)

      _, first, second = derivations.map { |record| record["derived_head"] }
      expect(chain_at(second, longer.store).ancestor_digests).to include(first)
    end

    # The derived chain is bounded by `keep_last` plus the number of ranges,
    # never by history length -- which is what makes deriving FULLY on every
    # compacting turn affordable and an incremental `#extend` unnecessary.
    it "writes the same number of store objects however long the history is" do
      expect(objects_written(timeline(8))).to eq(objects_written(timeline(80)))
    end

    def objects_written(line)
      before = line.store.size
      context_for(forcing, line)
      line.store.size - before
    end

    # The malformed-conversation class of 400, on the path that actually
    # reaches Anthropic.
    #
    # STATED HONESTLY, per measurement: this is the UNPINNED claim. A pin
    # punches a hole in the middle of the span, and a pinned `tool_use` whose
    # `tool_result` is inside a collapsed range is still stranded (follow-up
    # 14). What this path does NOT do is ship it -- see the refusal group below.
    it "renders a conversation the Messages API would accept, with nothing pinned" do
      line = timeline(12)

      messages = render(context_for(forcing, line), line).messages

      expect(Lain::Context::Conversation.new(messages).violations.map(&:message)).to be_empty
    end

    it "journals one edge per derivation, naming distinct derived heads" do
      built = forcing
      first = timeline(6)
      second = first.commit(role: role_at(7), content: [block(7)])

      context_for(built, first)
      context_for(built, second)

      expect(derivations.size).to eq(2)
      expect(derivations.map { |record| record["derived_head"] }.uniq.size).to eq(2)
    end

    # A regression, one object further in: the live `/model` slot makes the
    # chat Context unshareable, and `Scheduler::COMPOSE` calls
    # `Ractor.make_shareable` on a Proc -- which RAISES on anything it refers to
    # that is not already shareable rather than deep-freezing it. A replay
    # holding an ordinary Array fails there, on the first compacting turn of
    # every real chat.
    # The LIVE Context is deliberately not shareable -- `/model`'s slot is
    # mutable by design -- so what is asserted is narrower: the composed
    # pipeline is established shareable around it without raising, and the turn
    # really did compact.
    it "compacts a base Context carrying the live model slot, without raising" do
      slot = Lain::Context::ModelSwitch.new("claude-opus-4-8", journal:)
      live = Lain::Context.new(model: slot, max_tokens: 1024, system: "a system prompt")
      line = timeline
      built = forcing

      expect(live).not_to be_deeply_frozen
      expect { render(context_for(built, line, base: live), line) }.not_to raise_error
      expect(decisions.map { |record| record["compacted"] }).to eq([true])
    end

    it "carries the keep_last a re-derivation needs on the edge" do
      context_for(forcing, timeline)

      expect(derivations.first["keep_last"]).to eq(keep_last)
    end

    # The counters, read at the site that journals them, under the ONE policy
    # whose counters were the argument for carrying them at all.
    #
    # It discriminates on ARGUMENT-EVALUATION ORDER, which is why it exists. The
    # only thing that runs the strategy is the replay, so reading `policy.hits`
    # in the same argument list as the replay would be correct purely because
    # Ruby evaluates keyword arguments in source order -- and putting `hits:`
    # first would shift every journalled figure back one turn, permanently and
    # silently, with the rest of the suite still green. That is
    # {SummarySnapshot}'s "invisible except as a count that never rises",
    # reproduced one level up at the reader.
    #
    # One per turn each: `Summarizing` touches `#blocks` twice for one range
    # (once proposing it, once collapsing it) and holds the answer between them,
    # so a turn is one miss and one hit -- never two asks.
    describe "the hit rate a model-backed policy journals" do
      it "rises turn over turn, rather than reporting the previous turn's" do
        oracle = SourceSpecSpanOracle.new("a span summary")
        built = source(need: build_need(byte_threshold: 100), hard_cap: 100,
                       strategy: Lain::Compaction::Strategy::Summarizing.new(oracle:))
        first = timeline(6)

        context_for(built, first)
        context_for(built, first.commit(role: role_at(7), content: [block(7)]))

        expect(decisions.map { |record| [record["summary_hits"], record["summary_misses"]] })
          .to eq([[1, 1], [2, 2]])
        expect(oracle.asks).to eq(2)
      end
    end
  end

  # The cut is POLICY STATE, not a derived head: the Source re-derives from the
  # source root every turn, with the ranges a committed compaction collapsed
  # held at their recorded replacement and everything after them kept. A signal
  # that clears therefore never renders the full history again.
  describe "a committed compaction cut" do
    let(:session) { recording_session }

    def derivations = records.select { |record| record["type"] == "context_derived" }

    def cuts = records.select { |record| record["type"] == "compaction_cut" }

    def extend_by(line, count)
      (1..count).inject(line) do |grown, _|
        grown.commit(role: role_at(grown.length + 1), content: [block(grown.length + 1)])
      end
    end

    # Plan steps compact and nothing else does: the byte threshold is out of
    # reach, and a hard cap of 1 forces whatever is warranted even while warm.
    def stepping(**overrides) = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1, **overrides)

    def forcing(**overrides) = source(need: build_need(byte_threshold: 100), hard_cap: 100, **overrides)

    def failing_oracle
      Class.new do
        attr_reader :asks

        def initialize = (@asks = 0)

        def ask(_inputs = {})
          @asks += 1
          raise Lain::Error, "the summarizer is down"
        end
      end.new
    end

    it "is not undone when its signal clears" do
      built = stepping
      line = timeline(6)
      complete_a_step(session)
      compacted = render(context_for(built, line), line).messages

      complete_a_step(session)
      later = extend_by(line, 2)
      held = render(context_for(built, later), later).messages

      expect(decisions.map { |record| [record["signals"], record["compacted"]] })
        .to eq([[%w[plan_step_completion], true], [[], false]])
      expect(held.first).to eq(compacted.first)
      expect(held.size).to be <= compacted.size + 2
    end

    it "spans the same events turn after turn once the summary has landed" do
      oracle = SourceSpecSpanOracle.new("a span summary")
      built = stepping(strategy: Lain::Compaction::Strategy::Summarizing.new(oracle:))
      line = timeline(6)
      complete_a_step(session)
      context_for(built, line)

      renders = (1..3).map do |turns|
        grown = extend_by(line, turns)
        render(context_for(built, grown), grown).messages.first
      end

      expect(derivations.drop(1).map { |record| [record["spans"], record["compaction_cut"]] })
        .to eq([[cuts.first["collapses"].map { |collapse| collapse["span"] }, cuts.first["digest"]]] * 3)
      expect(renders.map { |message| Lain::Canonical.dump(message) }.uniq.size).to eq(1)
      expect(oracle.asks).to eq(1)
    end

    it "leaves the lossless record untouched through two compactions" do
      built = forcing
      line = timeline(6)
      context_for(built, line)
      longer = extend_by(line, 2)
      context_for(built, longer)

      expect(cuts.size).to eq(2)
      expect(longer.to_a.map(&:content)).to eq((1..8).map { |index| [block(index)] })
      expect(longer.to_a.map(&:role)).to eq((1..8).map { |index| role_at(index) })
    end

    def at(line, index) = Lain::Timeline.new(head_digest: line.to_a[index].digest, store: line.store)

    # The render an ordinary forward run sends at `line`: a fresh Source and a
    # fresh Session, with nothing ever committed.
    def forward_render(line, need: build_need(byte_threshold: 1_000_000), hard_cap: 1_000_000)
      fresh = described_class.new(need:, cold: build_cold, hard_cap:, keep_last:, eager:, clock:)
      render(fresh.context_for(base:, timeline: line, usage: nil, session: Lain::Session.new), line).messages
    end

    it "carries a completed plan step on the first compaction that commits, and not after" do
      built = stepping
      line = timeline(6)
      complete_a_step(session)

      context_for(built, line)
      context_for(built, extend_by(line, 2))

      expect(decisions.map { |record| [record["signals"], record["compacted"]] })
        .to eq([[%w[plan_step_completion], true], [[], false]])
    end

    # The render right after a completing todo_write is the next iteration of
    # the same tool loop, and its cache is warm: the scheduler defers. The step
    # must still be pending when the cache goes cold, or a plan step never
    # compacts in a live loop at all.
    it "keeps a completed plan step pending through a warm defer, so the first cold render compacts" do
      built = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1_000_000)
      line = timeline(6)
      complete_a_step(session)
      context_for(built, line)
      clock.advance(600)
      context_for(built, line)
      built << turn_usage(cache_read: 0)

      context_for(built, extend_by(line, 2))

      expect(decisions.map { |record| [record["signals"], record["compacted"]] })
        .to eq([[%w[plan_step_completion], false], [%w[plan_step_completion], false],
                [%w[plan_step_completion], true]])
      expect(compactions.map { |record| record["cache_state"] }).to eq(%w[cold])
    end

    it "fires again on the next write that raises the completed count" do
      built = stepping
      line = timeline(6)
      complete_a_step(session)
      context_for(built, line)
      complete_a_step(session, 2)

      context_for(built, extend_by(line, 2))

      expect(decisions.map { |record| [record["signals"], record["compacted"]] })
        .to eq([[%w[plan_step_completion], true], [%w[plan_step_completion], true]])
      expect(cuts.map { |record| record["plan_step_completions"] }).to eq([1, 2])
    end

    it "journals the cut once, when it commits, carrying the replacement it froze" do
      built = forcing
      line = timeline(6)
      rendered = render(context_for(built, line), line).messages

      3.times { context_for(built, line) }

      expect(cuts.size).to eq(1)
      expect(cuts.first).to include("digest" => line.to_a[3].digest, "head" => line.to_a[4].digest,
                                    "strategy" => built.collapse_strategy, "parent" => nil)
      expect(cuts.first["collapses"].map { |collapse| collapse["content"] }).to eq([rendered.first["content"]])
    end

    # The commit head is the turn below the asked prompt, because an ask
    # refused before any model saw it withdraws exactly that prompt. Holding
    # the cut through the withdrawal is what keeps a stuck ask from retreating
    # and committing the same cut again on every attempt.
    it "holds the cut through a withdrawn prompt and commits it once across two stuck asks" do
      built = forcing
      line = timeline(6)
      context_for(built, line)
      cut = cuts.first["digest"]

      2.times do |attempt|
        reasked = at(line, 4).commit(role: "user", content: [block(90 + attempt)])
        context_for(built, reasked)
      end

      expect(cuts.size).to eq(1)
      expect(derivations.drop(1).map { |record| record["compaction_cut"] }).to eq([cut, cut])
    end

    it "retreats to no cut when the human rewinds below it, and says so on the record" do
      built = stepping
      line = timeline(8)
      complete_a_step(session)
      replacement = render(context_for(built, line), line).messages.first
      context_for(built, extend_by(line, 1))
      edges = derivations.size
      rewound = at(line, 2)

      messages = render(context_for(built, rewound), rewound).messages

      expect(derivations[edges - 1]["compaction_cut"]).to eq(session.compaction_cuts.last.digest)
      expect(messages).not_to include(replacement)
      expect(derivations.size).to eq(edges + 1)
      expect(derivations.last["compaction_cut"]).to be_nil
    end

    # The common rewind: straight after the compacting reply, before any held
    # render. The file's last edge is the commit edge, which collapsed to the
    # new cut, so the retreat must still be written down.
    it "journals a retreat on a rewind straight after the compaction that committed the cut" do
      built = stepping
      line = timeline(8)
      complete_a_step(session)
      context_for(built, line)
      edges = derivations.size

      render(context_for(built, at(line, 3)), at(line, 3))

      expect(derivations.size).to eq(edges + 1)
      expect(derivations.last).to include("compaction_cut" => nil, "spans" => [])
    end

    it "retreats to the latest cut whose commit head is still on the chain, not past it" do
      built = forcing
      line = timeline(6)
      context_for(built, line)
      longer = extend_by(line, 2)
      context_for(built, longer)
      first_cut, second_cut = cuts.map { |record| record["digest"] }

      context_for(built, at(longer, 6))

      expect(longer.to_a.map(&:digest).index(second_cut)).to be <= 6
      expect(derivations.last["compaction_cut"]).to eq(first_cut)
    end

    # A cut committed at head 8 collapsed turns the original run still sent
    # verbatim at head 6. Rewinding there and prompting again is a forward run
    # from head 6, and it must be sent as one: the turn the human rewound TO is
    # not theirs to lose to a summary committed later in time.
    it "renders a rewind below the commit head plus a new prompt as an ordinary forward run would" do
      built = stepping
      line = timeline(8)
      complete_a_step(session)
      context_for(built, line)
      prompted = at(line, 5).commit(role: "user", content: [block(99)])

      expect(render(context_for(built, prompted), prompted).messages).to eq(forward_render(prompted))
    end

    it "renders the head exactly at the cut as the full request, never a one-message one" do
      built = stepping
      line = timeline(8)
      complete_a_step(session)
      context_for(built, line)
      cut_index = line.to_a.map(&:digest).index(session.compaction_cuts.last.digest)

      messages = render(context_for(built, at(line, cut_index)), at(line, cut_index)).messages

      expect(messages.size).to eq(cut_index + 1)
      expect(messages).to eq(forward_render(at(line, cut_index)))
    end

    it "inherits no later cut through a fork onto a turn between the cut and its commit head" do
      built = stepping
      line = timeline(8)
      complete_a_step(session)
      context_for(built, line)
      forked_session = Lain::SessionRecord::Replay.new(journal_io.string.each_line).session
      forked = at(line, 6)
      fresh = stepping

      messages = render(fresh.context_for(base:, timeline: forked, usage: nil, session: forked_session),
                        forked).messages

      expect(forked_session.compaction_cuts.size).to eq(1)
      expect(messages).to eq(forward_render(forked))
      expect(derivations.last["compaction_cut"]).to be_nil
    end

    # Each advance carries only what it newly collapsed, and names the record
    # it advanced past by content address. A whole-seam record grows with every
    # advance, which is quadratic over a long session.
    it "writes cut records whose size does not grow with the number of cuts, and resumes to the same bytes" do
      built = forcing
      line = timeline(4)
      renders = (1..8).map do
        line = extend_by(line, 2)
        render(context_for(built, line), line).messages
      end
      sizes = journal_io.string.each_line.select { |entry| entry.include?(%("type":"compaction_cut")) }.map(&:bytesize)
      resumed = Lain::SessionRecord::Replay.new(journal_io.string.each_line).session

      replayed = render(forcing.context_for(base:, timeline: line, usage: nil, session: resumed), line).messages

      expect(sizes.size).to eq(8)
      expect(sizes.drop(1).max - sizes.drop(1).min).to be < sizes.drop(1).min / 4
      expect(cuts.map { |record| record["collapses"].size }).to all(eq(1))
      expect(cuts.drop(1).map { |record| record["parent"] }).to eq(session.compaction_cuts.first(7).map(&:address))
      expect(Lain::Canonical.dump(replayed)).to eq(Lain::Canonical.dump(renders.last))
    end

    # A bench compares arms, so a prefix one arm collapsed must never be sent
    # under another: a cut from a different --compact-strategy retreats, and
    # the edge says no cut held.
    it "does not hold a cut another arm committed, and journals the retreat" do
      line = timeline(6)
      context_for(forcing, line)
      resumed = Lain::SessionRecord::Replay.new(journal_io.string.each_line).session
      other = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1_000_000,
                     strategy: Lain::Compaction::Strategy::Summarizing.new(oracle: SourceSpecSpanOracle.new("b")))

      messages = render(other.context_for(base:, timeline: line, usage: nil, session: resumed), line).messages

      expect(cuts.size).to eq(1)
      expect(messages).to eq(forward_render(line))
      expect(derivations.last["compaction_cut"]).to be_nil
    end

    it "does not commit a cut while the summarizer fails, and retries on the next render" do
      oracle = failing_oracle
      built = forcing(strategy: Lain::Compaction::Strategy::Summarizing.new(oracle:))
      line = timeline(6)

      2.times { expect(context_for(built, line)).to equal(base) }

      expect(cuts).to be_empty
      expect(session.compaction_cuts).to be_empty
      expect(oracle.asks).to eq(2)
    end

    # The eager tier replaces a tool result with its summary as the summary
    # lands, which is independent of the cut. The cut freezes the replacement it
    # committed, so a summary landing later inside the collapsed range changes
    # nothing a provider has already cached.
    it "keeps the replacement it froze when an eager summary lands inside its range afterwards" do
      line = tool_timeline
      live = SourceSpecEager.new
      built = forcing(eager: live)
      before = render(context_for(built, line), line).messages.first
      live.instance_variable_get(:@summaries)[Lain::Canonical.digest(tool_body(2))] = "a late summary"

      after = render(context_for(built, line), line).messages.first

      expect(after).to eq(before)
      expect(Lain::Canonical.dump(after)).not_to include("a late summary")
    end

    # An advancing turn derives twice -- the held render it must beat, and the
    # advance -- and a reader pairing a render with its edge takes the last one.
    it "journals the chain it sends as the last edge on a turn that advances past a held cut" do
      built = forcing
      line = timeline(6)
      context_for(built, line)
      longer = extend_by(line, 2)

      messages = render(context_for(built, longer), longer).messages
      sent = Lain::Timeline.new(head_digest: derivations.last["derived_head"], store: longer.store).to_a

      expect(cuts.size).to eq(2)
      expect(sent.map(&:role)).to eq(messages.map { |message| message["role"] })
      expect(sent.first(2).map(&:content)).to eq(messages.first(2).map { |message| message["content"] })
    end

    it "hands the scheduler a shareable Context on a turn that only holds its cut" do
      built = forcing
      line = timeline(6)
      context_for(built, line)

      expect(context_for(built, line)).to be_deeply_frozen
    end

    it "renders a conversation the Messages API would accept while it holds the cut" do
      built = stepping
      line = timeline(6)
      complete_a_step(session)
      context_for(built, line)
      later = extend_by(line, 4)

      messages = render(context_for(built, later), later).messages

      expect(Lain::Context::Conversation.new(messages).violations.map(&:message)).to be_empty
    end
  end

  # Summaries accumulate one per advance, and once nothing past them is
  # droppable no advance can make room. A collapse commits one cut that
  # supersedes the held ones: its range is over raw turns, and only the
  # summarizer's input is the held replacements' text.
  describe "held cuts that re-collapse" do
    let(:session) { recording_session }
    let(:oracle) { SourceSpecSpanOracle.new("a span summary") }

    def cuts = records.select { |record| record["type"] == "compaction_cut" }

    def derivations = records.select { |record| record["type"] == "context_derived" }

    def grow(line, count = 2)
      (1..count).inject(line) do |grown, _|
        grown.commit(role: role_at(grown.length + 1), content: [block(grown.length + 1)])
      end
    end

    def at(line, index) = Lain::Timeline.new(head_digest: line.to_a[index].digest, store: line.store)

    # Plan steps compact and nothing else does; a hard cap of 1 forces the step
    # even while warm.
    def stepping(strategy: Lain::Compaction::Strategy::SummarizeConversation.new(oracle:), **overrides)
      source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1, strategy:, **overrides)
    end

    def step(built, line)
      complete_a_step(session, session.plan_step_completions + 1)
      render(context_for(built, line), line).messages
    end

    # Four advances, each committed on its own step: 6, 8, 10 and 12 turns
    # under keep_last 2, which leaves nothing droppable past the fourth.
    def four_advances(built)
      [6, 8, 10, 12].inject(nil) do |line, size|
        grown = line.nil? ? timeline(size) : grow(line)
        step(built, grown)
        grown
      end
    end

    def replacement?(message)
      message["content"].any? { |block| block["text"].to_s.start_with?("a span summary") }
    end

    it "collapses four held advances into one cut that supersedes them, rendering one replacement" do
      built = stepping
      line = four_advances(built)
      advances = session.compaction_cuts.dup

      messages = step(built, line)

      expect(cuts.map { |record| record["kind"] }).to eq(%w[advance advance advance advance collapse])
      expect(cuts.last).to include("supersedes" => advances.map(&:address), "parent" => advances.last.address,
                                   "digest" => advances.last.digest, "strategy" => built.collapse_strategy)
      expect(cuts.last["collapses"].map { |collapse| collapse["span"] })
        .to eq([[line.to_a[0].digest, line.to_a[9].digest]])
      expect(messages.count { |message| replacement?(message) }).to eq(1)
      expect(messages.size).to eq(3)
    end

    it "writes the collapse from the held replacements' text, never from the raw turns" do
      asked = []
      recording = Class.new(SourceSpecSpanOracle) do
        define_method(:ask) do |inputs = {}|
          asked << inputs
          super(inputs)
        end
      end.new("a span summary")
      built = stepping(strategy: Lain::Compaction::Strategy::SummarizeConversation.new(oracle: recording))
      line = four_advances(built)
      summaries = session.compaction_cuts.flat_map(&:collapses).map { |collapse| collapse["content"].first["text"] }

      step(built, line)

      expect(recording.asks).to eq(5)
      expect(asked.last.values.join).to include(*summaries)
      expect(asked.last.values.join).not_to include(block(1)["text"])
    end

    it "journals the collapse as a compacting decision over a head with nothing droppable" do
      built = stepping
      line = four_advances(built)

      step(built, line)

      expect(decisions.last).to include("compacted" => true, "nothing_droppable" => true)
    end

    it "holds the collapse on later renders without collapsing it again" do
      built = stepping
      line = four_advances(built)
      collapsed = step(built, line)

      held = Array.new(2) { step(built, line) }

      expect(cuts.size).to eq(5)
      expect(held).to all(eq(collapsed))
      expect(oracle.asks).to eq(5)
    end

    # The un-flagged control arm re-collapses too: its replacements attest what
    # they stood for, and an attestation of attestations is smaller again. The
    # Context it hands back must still cross into a shareable pipeline.
    it "collapses under the un-flagged control arm, and still hands back a shareable Context" do
      built = source(need: build_need(byte_threshold: 1_000_000), hard_cap: 1)
      line = four_advances(built)
      complete_a_step(session, session.plan_step_completions + 1)

      context = context_for(built, line)

      expect(cuts.map { |record| record["kind"] }).to eq(%w[advance advance advance advance collapse])
      expect(context).to be_deeply_frozen
    end

    it "does not collapse a single held cut" do
      built = stepping
      line = timeline(6)
      step(built, line)

      step(built, line)

      expect(cuts.map { |record| record["kind"] }).to eq(%w[advance])
    end

    it "advances past a collapse, and holds the collapse's range beneath the new one" do
      built = stepping
      line = four_advances(built)
      step(built, line)
      longer = grow(line)

      messages = step(built, longer)

      expect(cuts.map { |record| record["kind"] }).to eq(%w[advance advance advance advance collapse advance])
      expect(cuts.last["parent"]).to eq(session.compaction_cuts[4].address)
      expect(messages.count { |message| replacement?(message) }).to eq(2)
    end

    # A rewind below the collapse's commit head is a forward run from there: it
    # holds the latest advance still on the chain, with every summary that run
    # sent, and not the collapse committed later in time.
    it "retreats past a collapse to the advance a rewind below it still holds" do
      built = stepping
      line = four_advances(built)
      step(built, line)
      third = session.compaction_cuts[2]
      rewound = at(line, 9)

      messages = render(context_for(built, rewound), rewound).messages

      expect(derivations.last["compaction_cut"]).to eq(third.digest)
      expect(messages.count { |message| replacement?(message) }).to eq(3)
    end

    it "does not commit a collapse while the summarizer fails, and asks again on the next render" do
      built = stepping
      line = four_advances(built)
      allow(oracle).to receive(:ask).and_raise(Lain::Error, "the summarizer is down")

      2.times { step(built, line) }

      expect(cuts.size).to eq(4)
      expect(oracle).to have_received(:ask).twice
      expect(decisions.last(2).map { |record| record["compacted"] }).to eq([false, false])
    end

    it "declines a collapse that would not shrink the render" do
      verbose = Class.new(SourceSpecSpanOracle) do
        def ask(inputs = {})
          answer = super
          asks < 5 ? answer : answer.class.new("#{answer.summary} #{"that goes on and on " * 400}")
        end
      end.new("a span summary")
      built = stepping(strategy: Lain::Compaction::Strategy::SummarizeConversation.new(oracle: verbose))
      line = four_advances(built)

      step(built, line)

      expect(verbose.asks).to eq(5)
      expect(cuts.size).to eq(4)
      expect(decisions.last).to include("compacted" => false, "would_not_shrink" => true)
    end

    # Pins are cut points in a collapse as in an advance: a turn pinned
    # between two held ranges is retained, verbatim and in position.
    it "keeps a pinned turn between held ranges verbatim, in position" do
      built = stepping(strategy: Lain::Compaction::Strategy::Summarizing.new(oracle:))
      line = timeline(6)
      step(built, line)
      longer = grow(line, 4)
      session.record_pin(longer.to_a[4].digest)
      step(built, longer)
      pinned = { "role" => longer.to_a[4].role, "content" => longer.to_a[4].content }
      longest = grow(longer, 2)
      step(built, longest)

      messages = step(built, longest)

      expect(cuts.map { |record| record["kind"] }.last).to eq("collapse")
      expect(messages).to include(pinned)
      expect(messages.index(pinned)).to eq(1)
    end

    describe "a withdrawal after a collapse" do
      it "keeps the collapse, and does not commit it again" do
        built = stepping
        line = four_advances(built)
        step(built, line)
        collapse = session.compaction_cuts.last

        2.times do |attempt|
          reasked = at(line, 10).commit(role: "user", content: [block(90 + attempt)])
          step(built, reasked)
        end

        expect(cuts.size).to eq(5)
        expect(derivations.last(2).map { |record| record["spans"] })
          .to all(eq(collapse.spans))
        expect(oracle.asks).to eq(5)
      end
    end
  end

  # The fallback. {Compaction::Derivation} validates its own projection and
  # RAISES rather than shipping a chain the Messages API would reject, so the
  # turn renders uncompacted -- which is the right answer once and the
  # silent-stop mode forty times, and the record is what tells them apart.
  describe "a derivation the Messages API would reject" do
    def stranding
      source(need: build_need(byte_threshold: 100), hard_cap: 100, strategy: SourceSpecStrandingSpan.new)
    end

    def refusals = records.select { |record| record["type"] == "derivation_refused" }

    it "renders the uncompacted history rather than an invalid one" do
      line = timeline
      returned = context_for(stranding, line)

      expect(returned).to equal(base)
      expect(Lain::Canonical.dump(render(returned, line).cache_payload))
        .to eq(Lain::Canonical.dump(render(base, line).cache_payload))
    end

    # Its own record type, never a `context_derived` with empty spans: `cut`
    # exists to make an empty collapse readable, and a fallback wearing a
    # derivation's badge would put the ambiguity straight back.
    it "journals the refusal as its own record, naming the strategy and the violation" do
      context_for(stranding, timeline)

      expect(records.map { |record| record["type"] }).not_to include("context_derived")
      expect(refusals.first).to include("strategy" => "SourceSpecStrandingSpan", "consecutive" => 1)
      expect(refusals.first["violations"]).to include("toolu", "never answered").or include("call-nobody-answers")
    end

    # A deterministic strategy over a stable history refuses IDENTICALLY every
    # turn. One refusal is an awkward history; a rising streak is a session that
    # has stopped compacting, and a record that counted nothing could not tell a
    # bench arm which it was looking at.
    it "counts the streak, so a session that has stopped compacting is visible" do
      built = stranding
      line = timeline

      3.times { context_for(built, line) }

      expect(refusals.map { |record| record["consecutive"] }).to eq([1, 2, 3])
    end

    it "is still journalled as a plain defer on the turn's own decision record" do
      context_for(stranding, timeline)

      expect(decisions.first).to include("compacted" => false, "would_not_shrink" => false)
    end

    # FOLLOW-UP 14, REPAIRED. A pin whose tool counterpart is inside a
    # collapsed range used to strand it here too: the derivation validated its
    # own projection, refused, and the turn deferred to the uncompacted
    # history for as long as the pin stood (the streak count above is what
    # that state left behind). Only ONE digest is pinned below -- as it would
    # be for a turn pinned while parked, or an old record from before the
    # counterpart drag existed -- and `Context::PinnedMessages` still finds
    # and protects the tool_result too: `Compaction::Source#pinned` hands it
    # `candidates: walk.messages`, the WHOLE chain, not only what got pinned,
    # so the pairing closes over the counterpart whether or not its own digest
    # was ever recorded. Both survive verbatim -- the same outcome as pinning
    # both digests explicitly, below -- and there is nothing to refuse.
    it "protects a lone-pinned tool_use's answer too, once it exists on the rendered chain" do
      line = stranded_pin_timeline
      pinning = session_pinning(line.to_a[1].digest)
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      messages = render(context_for(built, line, session: pinning), line).messages

      expect(refusals).to be_empty
      expect(messages).to include(
        hash_including("role" => "assistant", "content" => line.to_a[1].content),
        hash_including("role" => "user", "content" => line.to_a[2].content)
      )
    end

    # THE OTHER HALF: {Cli::Command::Pin} also drags a pin's tool counterpart
    # along explicitly at pin time, so an operator pinning either turn ends up
    # with BOTH RECORDED -- redundant with the closure above once the answer
    # exists, but what makes `/unpin` find both and a replay stay explicit.
    it "renders both halves of a pinned tool_use/tool_result pair, with no refusal" do
      line = stranded_pin_timeline
      pinning = session_pinning(line.to_a[1].digest, line.to_a[2].digest)
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      messages = render(context_for(built, line, session: pinning), line).messages

      expect(refusals).to be_empty
      expect(messages).to include(
        hash_including("role" => "assistant", "content" => line.to_a[1].content),
        hash_including("role" => "user", "content" => line.to_a[2].content)
      )
    end

    # A pinned `tool_use` at index 1 whose answering `tool_result` sits at index
    # 2, both inside the droppable span at `keep_last: 2`.
    def stranded_pin_timeline
      [["user", [block(1)]],
       ["assistant", [{ "type" => "tool_use", "id" => "call-1", "name" => "read", "input" => { "n" => 1 } }]],
       ["user", [{ "type" => "tool_result", "tool_use_id" => "call-1", "content" => tool_body(1) }]],
       ["user", [block(4)]], ["assistant", [block(5)]], ["user", [block(6)]]]
        .inject(Lain::Timeline.empty(store: Lain::Store.new)) { |line, (role, content)| line.commit(role:, content:) }
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

    # An empty head defers regardless of the signals -- `#decide` returns
    # before {Need} is consulted -- so a reader could not otherwise tell this
    # defer apart from an ordinary one where the signals simply never fired.
    it "reports nothing droppable when the head is empty and a signal fires" do
      built = source(need: build_need(byte_threshold: 1), hard_cap: 1, keep_last: 6)

      context_for(built, timeline(5))

      expect(decisions.first).to include("nothing_droppable" => true, "compacted" => false)
    end

    it "does not report nothing droppable when the head is real" do
      context_for(source, timeline)

      expect(decisions.first).to include("nothing_droppable" => false, "compacted" => false)
    end

    it "does not report nothing droppable when the turn compacts" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100)

      context_for(built, timeline)

      expect(decisions.first).to include("nothing_droppable" => false, "compacted" => true)
    end

    # The same fact, asked live by a refusal that has to decide whether to
    # offer compaction as a way to make room: offering it over an empty head
    # sends a human after the one move that cannot happen.
    it "answers whether the last render left anything to drop, as the decision recorded it" do
      stuck = source(need: build_need(byte_threshold: 1), hard_cap: 1, keep_last: 6)
      roomy = source

      context_for(stuck, timeline(5))
      context_for(roomy, timeline)

      expect([stuck.droppable?, roomy.droppable?]).to eq([false, true])
    end

    it "offers nothing to drop before any render has measured a head" do
      expect(source.droppable?).to be(false)
    end
  end

  # The record above is written for a journal reader after the fact. A human
  # watching a session that has gone full and cannot shrink gets nothing from
  # it: the HUD clamps at 100% deliberately, so "full" and "full with nothing
  # left to cut" are the same reading, and the second one never recovers on its
  # own. This object is the only one holding the head, the need, the occupancy
  # and the provenance together, so it is the only one that can tell them apart
  # out loud.
  describe "what it tells an operator when a warranted compaction has nothing to drop" do
    let(:surface) { RecordingChannel.new }

    # The run's real sink shape: {Lain::Sink::IOAdapter} over a Channel is the
    # one route from `lib/` to a frontend. A Sink::Null here would leave this
    # group proving the turn survives while proving nothing about the operator
    # being told, which is the whole of the sink's justification.
    def sink = Lain::Sink::IOAdapter.new(surface, tool_use_id: "spec:compaction", stream: :stderr)

    def reported = surface.events.grep(Lain::Telemetry::ToolOutput).map(&:bytes)

    # Five turns under a keep_last of six: {Lain::Compaction::Boundary} cuts
    # nothing, so the head is empty while the window says the prompt is nearly
    # full. The published book is what makes the signal survive #need_for --
    # see the guessed case below.
    def stalling(book: window_book(8_192))
      source(need: build_need(approaching_ratio: 0.9), keep_last: 6, context_window: book, sink:)
    end

    it "says the context is full and that there is nothing left to compact" do
      context_for(stalling, timeline(5), usage: 7_500)

      expect(reported.join)
        .to include("approaching_window").and include("nothing").and include("7500/8192")
    end

    it "says nothing on a deferring turn whose signals never fired" do
      context_for(stalling(book: window_book(1_000_000)), timeline(5), usage: 10)

      expect(reported).to be_empty
    end

    it "says nothing about an empty head on a turn that really compacts" do
      built = source(need: build_need(byte_threshold: 100), hard_cap: 100, sink:)

      context_for(built, timeline, usage: 7_500)

      expect(reported).to be_empty
    end

    # The occupancy that would have triggered this report is measured against a
    # denominator nobody vouched for, and #need_for has already withdrawn
    # `:approaching_window` for exactly that reason. Reporting anyway would put
    # a human-facing alarm on a number the rest of the object refuses to act
    # on -- the same defect, one surface further out.
    it "says nothing when the window it would be full against was only guessed" do
      context_for(stalling(book: guessed_window_book(8_192)), timeline(5), usage: 7_500)

      expect(reported).to be_empty
    end

    # {Need} has four detectors and only ONE of them is about a full window.
    # {Need::PlanStepCompletion} is a plain boolean independent of history
    # size, and #weigh's own comment says it "reaches it in an ordinary chat,
    # with compaction on by default" -- so a warrant that is not
    # `:approaching_window` is not evidence that a context is full.
    def plan_stepped = session_pinning(plan_step_completed: true)

    it "says nothing about a full context on a session using a millionth of its window" do
      built = stalling(book: window_book(1_000_000))

      context_for(built, timeline(3), usage: 10, session: plan_stepped)

      expect(reported).to be_empty
    end

    # The trigger the card names, held as a GUARANTEE rather than as an
    # accident of #need_for's scope. The withdrawal there removes one signal;
    # it does not stop a DIFFERENT signal firing over the same turn, and a
    # report keyed on "any signal" then quotes the guessed denominator at a
    # human -- 8,192 being {ContextWindow::CONSERVATIVE_FALLBACK}, which is the
    # round-3 defect verbatim.
    it "says nothing when a second signal fires over a window that was only guessed" do
      built = stalling(book: guessed_window_book(8_192))

      context_for(built, timeline(3), usage: 7_500, session: plan_stepped)

      expect(reported).to be_empty
    end

    # The OTHER way a head comes back empty, and the reason the line may not
    # hard-code one cause: the droppable span existed and every message in it
    # was pinned. This is the case whose one available action is UNPINNING, so
    # a sentence blaming keep_last sends the operator the other way.
    it "does not blame keep_last when the droppable span was pinned away" do
      line = timeline(8)
      pinned = session_pinning(*line.to_a.first(2).map(&:digest))
      built = source(need: build_need(approaching_ratio: 0.9), keep_last: 6,
                     context_window: window_book(8_192), sink:)

      context_for(built, line, usage: 7_500, session: pinned)

      expect(reported.join).to include("pinned")
    end

    # ONCE, and why it is a latch rather than a line per turn: this condition
    # does not clear on its own -- the human has to act -- so a per-turn report
    # would repeat until the one that mattered had scrolled out of reach.
    it "tells them once, not once per turn, while the condition holds" do
      built = stalling

      2.times { context_for(built, timeline(5), usage: 7_500) }

      expect(reported.size).to eq(1)
    end

    # Re-armed rather than spent. A session that recovers and stalls again is
    # two separate facts, and the second one is worth the same line as the
    # first -- a counter would have said "still", which is not the same claim.
    it "tells them again after the condition clears and returns" do
      built = stalling

      context_for(built, timeline(5), usage: 7_500)
      context_for(built, timeline(5), usage: 10)
      context_for(built, timeline(5), usage: 7_500)

      expect(reported.size).to eq(2)
    end
  end

  # The TRUTH half of the report, addressable on its own. It used to be two
  # private methods inside the routing class, which is why the latch could only
  # ever be tested through the thing that routes it -- and why the predicate
  # below could over-fire for a whole round without an example able to say so.
  describe Lain::Compaction::Source::Diagnosis do
    def decision(signals:, nothing_droppable: true, used: 7_500, window: 8_192, compacted: false)
      Lain::Compaction::Source::CompactionDecision.new(
        compacted:, signals:, head_bytes: 2, summary_hits: 0, summary_misses: 0, misses_all_size_declined: false,
        cold: false, would_not_shrink: false, window_tokens: window, used_tokens: used,
        provenance: :published, nothing_droppable:
      )
    end

    def over(head, **fields) = Lain::Compaction::Source::Diagnosis.of(decision: decision(**fields), head:)

    def empty_head = Lain::Compaction::Head.new(messages: [], keep_last: 2)

    def tool_pair
      [{ "role" => "assistant",
         "content" => [{ "type" => "tool_use", "id" => "call-1", "name" => "read", "input" => {} }] },
       { "role" => "user",
         "content" => [{ "type" => "tool_result", "tool_use_id" => "call-1", "content" => "x" }] }]
    end

    # The only legal cut is at 1 and it splits the pair; moving off it lands on
    # 0, so {Lain::Compaction::Boundary} declines. Empty head, different cause.
    def declined_head = Lain::Compaction::Head.new(messages: tool_pair, keep_last: 1)

    it "is stalled when the window signal fired over a head with nothing to drop" do
      expect(over(empty_head, signals: [:approaching_window])).to be_stalled
    end

    it "is not stalled on a warrant that says nothing about how full the window is" do
      expect(over(empty_head, signals: [:plan_step_completion])).not_to be_stalled
    end

    it "is not stalled while the head still had something to drop" do
      expect(over(empty_head, signals: [:approaching_window], nothing_droppable: false)).not_to be_stalled
    end

    # A collapse of the cuts that hold commits over an empty head by
    # construction: the turn that made room is the one turn this must not
    # report as stuck.
    it "is not stalled on a turn that compacted over a head with nothing to drop" do
      expect(over(empty_head, signals: [:approaching_window], compacted: true)).not_to be_stalled
    end

    it "names the boundary's refusal, and not keep_last, when the cut was declined" do
      line = over(declined_head, signals: [:approaching_window]).line

      expect(line).to include("declined")
      expect(line).not_to include("inside keep_last")
      # The REMEDY has to differ too, and `--compact-keep` cannot gate it --
      # both strings name that flag. {Lain::Compaction::Boundary} takes pins
      # "for interface parity ... and never consulted", so telling this
      # operator to unpin a turn is advice that cannot work. What can: a lower
      # keep_last raises the naive split past 1 and gives the cut room to move
      # off the pair.
      expect(line).to include("falls clear of the pair")
      expect(line).not_to include("unpin")
    end

    it "names both causes it cannot tell apart rather than asserting one" do
      line = over(empty_head, signals: [:approaching_window]).line

      expect(line).to include("pinned")
      expect(line).to include("keep_last")
    end

    it "gives the operator something to do about it" do
      expect(over(empty_head, signals: [:approaching_window]).line).to include("--compact-keep")
    end
  end

  # A walk and its projection are O(n) in history length, and a compacting
  # turn used to pay for THREE of each over the source chain: this object's own,
  # the {Lain::Compaction::Derivation}'s, and -- built, discarded unread --
  # {Lain::Context#render}'s. The rendered bytes are identical either way, so no
  # assertion over the messages can tell the two apart; the fetch count is the
  # only observable that can.
  describe "what one rendered turn costs" do
    def forcing = source(need: build_need(byte_threshold: 100), hard_cap: 100)

    it "walks the source chain once and the derived chain once" do
      line = timeline
      built = forcing

      tally = count_store_fetches(line.store) { render(context_for(built, line), line) }

      # One fetch per source turn (6) as the decision is made; one per derived
      # event (3: a summary and the two retained) as the chain is projected into
      # the messages a render sends; and one per derived commit that had a head
      # to take its correlation from (2 -- the first lands on the empty Timeline
      # and reads nothing).
      expect(tally.count).to eq(6 + 3 + 2)
    end

    # The DEFERRING path still walks twice, and that is the pure seam's price
    # rather than an oversight left behind: `Context#render` is a function of
    # (timeline, toolset, workspace) and projects the timeline itself, so the
    # only way to hand it a walk this object already made is to change that
    # signature. A compacting turn escapes the second walk because its pipeline
    # substitutes and reads NO messages -- not because one was threaded in.
    it "walks the source chain twice on a deferring turn: once to decide, once to render" do
      line = timeline

      tally = count_store_fetches(line.store) { render(context_for(source, line), line) }

      expect(tally.count).to eq(6 * 2)
    end

    # The same duplication in `Canonical.dump`: {Lain::Compaction::Head}
    # measures the candidate span at construction and {Lain::Compaction::Need}
    # used to dump the very same list again, while the floor's before/after
    # measurement was thrown away and re-taken inside the scheduler's accounting.
    it "dumps the candidate head once and the whole history once" do
      line = timeline
      messages = messages_of(line)
      head = Lain::Compaction::Head.new(messages:, keep_last:)
      allow(Lain::Canonical).to receive(:dump).and_call_original

      context_for(forcing, line)

      expect(Lain::Canonical).to have_received(:dump).with(head.messages).once
      expect(Lain::Canonical).to have_received(:dump).with(messages).once
    end
  end

  # The fallback that fires when no cut can make room: one state document
  # replaces the history before the current ask, and the ask is kept.
  describe "handing off when no cut can make room" do
    let(:session) { recording_session }
    let(:keep_last) { 8 }
    let(:oracle) { SourceSpecHandoffOracle.new }

    def cuts = records.select { |record| record["type"] == "compaction_cut" }

    def handing_off(**overrides)
      source(fallback: Lain::Compaction::Source::Fallback.new(tier: -> { oracle }), **overrides)
    end

    # The ask fills the window by itself: the human's question, then two
    # completed tool rounds, then the round nothing has answered yet.
    def asking_timeline
      [["user", [block(1)]],
       ["assistant", [{ "type" => "tool_use", "id" => "call-2", "name" => "read", "input" => { "n" => 2 } }]],
       ["user", [{ "type" => "tool_result", "tool_use_id" => "call-2", "content" => tool_body(2) }]],
       ["assistant", [{ "type" => "tool_use", "id" => "call-4", "name" => "read", "input" => { "n" => 4 } }]],
       ["user", [{ "type" => "tool_result", "tool_use_id" => "call-4", "content" => tool_body(4) }]]]
        .inject(Lain::Timeline.empty(store: Lain::Store.new)) do |line, (role, content)|
          line.commit(role:, content:)
        end
    end

    def refused_render(built, line)
      context_for(built, line)
      built.handoff(timeline: line, session:)
    end

    def replacement_text(messages)
      messages.flat_map { |message| Array(message["content"]) }
              .filter_map { |block| block["text"] if block.is_a?(Hash) }.join("\n")
    end

    it "commits one handoff cut and answers that it made room" do
      line = timeline
      built = handing_off

      expect(refused_render(built, line)).to be(true)
      expect(cuts.map { |record| record["kind"] }).to eq(["handoff"])
      expect(session.compaction_cuts.size).to eq(1)
    end

    it "asks the summarizer exactly once" do
      built = handing_off
      refused_render(built, timeline)

      expect(oracle.asks.size).to eq(1)
    end

    it "renders the state document's five headings in place of the history" do
      line = timeline
      built = handing_off
      refused_render(built, line)

      messages = render(context_for(built, line), line).messages

      expect(replacement_text(messages))
        .to include("Goal", "Progress", "Files and decisions", "Open todos", "Next step")
    end

    # The whole point of the fallback: the ask survives it. Its turn is
    # retained verbatim, so the retried render still carries the question.
    it "keeps the current ask verbatim beside the document" do
      line = timeline
      built = handing_off
      refused_render(built, line)

      messages = render(context_for(built, line), line).messages

      expect(messages.last["role"]).to eq("user")
      expect(messages.last["content"].first["text"]).to eq(block(6)["text"])
    end

    it "keeps a pinned turn verbatim, in position" do
      line = timeline
      allow(session).to receive(:pinned?) { |digest| digest == line.to_a[2].digest }
      built = handing_off
      refused_render(built, line)

      messages = render(context_for(built, line), line).messages

      expect(messages).to include("role" => "assistant", "content" => [block(3)])
    end

    # An ask whose own iterations fill the window: the rounds it already
    # COMPLETED are inside the range, and the round nothing has answered is not
    # -- collapsing half a tool pair renders a chain the API refuses.
    it "covers the ask's completed rounds and retains the unanswered one whole" do
      line = asking_timeline
      built = handing_off
      refused_render(built, line)

      messages = render(context_for(built, line), line).messages

      expect(cuts.last["collapses"].map { |collapse| collapse["span"] })
        .to eq([[line.to_a[1].digest, line.to_a[2].digest]])
      expect(messages.last(2).map { |message| message["role"] }).to eq(%w[assistant user])
      expect(messages.last["content"].first)
        .to include("tool_use_id" => "call-4", "content" => tool_body(4))
      expect(messages.first["content"].first["text"]).to eq(block(1)["text"])
    end

    # With a cut already holding there is still something droppable past it,
    # and the handoff fires anyway: the refused render WAS the newest cut, so
    # an advance is a move that has already been made.
    it "supersedes every cut that held, so the summaries do not accumulate" do
      line = timeline
      built = handing_off(keep_last: 2)
      advance = Lain::Telemetry::CompactionCut.new(
        digest: line.to_a[1].digest, head: Lain::Event.stands_on(line.to_a.last), strategy: built.collapse_strategy,
        kind: "advance", parent: nil, supersedes: [], plan_step_completions: 0,
        collapses: [{ "span" => [line.to_a[0].digest, line.to_a[1].digest],
                      "content" => [{ "type" => "text", "text" => "an earlier summary" }] }]
      )
      session.record_compaction_cut(advance)

      refused_render(built, line)

      expect(session.compaction_cuts.last.supersedes).to eq([advance.address])
      expect(oracle.asks.last[:held]).to include("an earlier summary")
    end

    # A refusal with something still droppable is a refusal an ADVANCE can
    # answer, and the refusal's own words say so. Spending a model call on a
    # handoff there would replace a history compaction had not tried on.
    it "declines while an ordinary compaction still has something to drop" do
      line = timeline
      built = handing_off(keep_last: 2)

      expect(refused_render(built, line)).to be(false)
      expect(cuts).to be_empty
    end

    it "declines when there is nothing but the ask to replace" do
      line = Lain::Timeline.empty(store: Lain::Store.new).commit(role: "user", content: [block(1)])
      built = handing_off

      expect(refused_render(built, line)).to be(false)
      expect(oracle.asks).to be_empty
    end

    it "does not fire before a refusal: no render commits a handoff cut" do
      line = timeline
      built = handing_off

      render(context_for(built, line), line)

      expect(cuts).to be_empty
    end

    describe "with the fallback off" do
      it "leaves the refusal standing and records no cut" do
        line = timeline
        built = source

        expect(built.handoff(timeline: line, session:)).to be(false)
        expect(cuts).to be_empty
      end
    end

    describe "when the oracle's answer cannot be decoded" do
      let(:failing) do
        definition = Lain::Oracle::Handoff.definition
        Lain::Oracle::Recorded::Journaling.new(
          inner: SourceSpecUndecodableOracle.new(definition), definition:, journal:
        )
      end

      it "journals oracle_failed, commits nothing, and reports no room made" do
        line = timeline
        built = source(fallback: Lain::Compaction::Source::Fallback.new(tier: -> { failing }))

        expect(refused_render(built, line)).to be(false)
        expect(cuts).to be_empty
        expect(records.count { |record| record["type"] == "oracle_failed" }).to eq(1)
      end

      it "leaves handed_off? false, so the refusal is worded as it was" do
        built = source(fallback: Lain::Compaction::Source::Fallback.new(tier: -> { failing }))
        refused_render(built, timeline)

        expect(built.handed_off?).to be(false)
      end
    end

    # A stuck session asks again, and again. A second handoff over a chain
    # nothing has added to would re-write the very turns the first one
    # replaced: a second model call, a second cut, and no more room.
    describe "a second refusal over a chain the first handoff already covered" do
      it "spends no second model call and commits no second cut" do
        line = timeline
        built = handing_off
        refused_render(built, line)

        expect(refused_render(built, line)).to be(false)
        expect(oracle.asks.size).to eq(1)
        expect(cuts.size).to eq(1)
      end

      it "does not drift: five stuck asks leave one call and one cut" do
        line = timeline
        built = handing_off
        5.times { refused_render(built, line) }

        expect(oracle.asks.size).to eq(1)
        expect(cuts.size).to eq(1)
      end

      # `handed_off?` is documented as "has this run EVER handed off", and the
      # refusal's words rest on it: the history is still replaced, whatever a
      # later attempt could or could not do.
      it "still reports handed_off?" do
        line = timeline
        built = handing_off
        refused_render(built, line)
        refused_render(built, line)

        expect(built.handed_off?).to be(true)
      end

      # The chain GREW, so there is something new to fold in and the second
      # handoff is the one that makes room. The distinction is what the guard
      # has to keep.
      it "fires again once the chain has turns no cut covers" do
        line = timeline
        built = handing_off
        refused_render(built, line)
        grown = (7..10).inject(line) { |chain, index| chain.commit(role: role_at(index), content: [block(index)]) }

        expect(refused_render(built, grown)).to be(true)
        expect(cuts.size).to eq(2)
        expect(cuts.last["supersedes"]).to eq([session.compaction_cuts.first.address])
      end
    end

    # The card's first escalation trigger, answered rather than escalated: the
    # question's own input is bounded before it is asked, so a handoff cannot
    # fail on the same window that refused the prompt.
    describe "what the summarizer is shown" do
      def question = oracle.asks.last

      def bytes(question) = question.values.sum(&:bytesize)

      # The conservative window, which is what a Source wired with no window
      # thunk is asked in -- and the one the fallback defaults to.
      def budget = Lain::Oracle::Handoff.budget_for(Lain::ContextWindow::CONSERVATIVE_FALLBACK)

      it "stays inside the budget over four hundred turns" do
        line = (1..400).inject(Lain::Timeline.empty(store: Lain::Store.new)) do |chain, index|
          chain.commit(role: role_at(index), content: [block(index)])
        end

        refused_render(handing_off(keep_last: 500), line)

        expect(bytes(question)).to be <= budget
        expect(question[:span]).to include("earlier turn(s) elided")
      end

      it "stays inside the budget for one pathological turn" do
        line = Lain::Timeline.empty(store: Lain::Store.new)
                             .commit(role: "user", content: [{ "type" => "text", "text" => "z" * 4_000_000 }])
                             .commit(role: "assistant", content: [block(2)])
                             .commit(role: "user", content: [block(3)])

        refused_render(handing_off, line)

        expect(bytes(question)).to be <= budget
        expect(question[:span]).not_to include("z" * 300)
      end

      # A large tool result was already stubbed; a large TEXT block was not,
      # so the oracle used to be handed the bytes that had just been refused.
      it "bounds a large text block as well as a large tool result" do
        line = Lain::Timeline.empty(store: Lain::Store.new)
                             .commit(role: "user", content: [{ "type" => "text", "text" => "p" * 300_000 }])
                             .commit(role: "assistant", content: [{ "type" => "text", "text" => "q" * 300_000 }])
                             .commit(role: "user", content: [block(3)])

        refused_render(handing_off, line)

        expect(bytes(question)).to be < 2_000
      end
    end

    # The containment is the TIER's, and nothing wider. A journal that cannot
    # write and a bug in the range arithmetic are not "the summarizer was
    # down", and reporting them that way would reach a human as an ordinary
    # over-window refusal with no trace of the real fault.
    describe "a failure that is not the tier's" do
      it "lets a journal that cannot record the cut raise" do
        line = timeline
        built = handing_off
        context_for(built, line)
        allow(session).to receive(:record_compaction_cut).and_raise(IOError, "no space left on device")

        expect { built.handoff(timeline: line, session:) }.to raise_error(IOError, /no space left/)
      end

      it "lets a raise from the range computation through" do
        line = timeline
        built = handing_off
        context_for(built, line)
        allow(Lain::IntervalPartition).to receive(:covering).and_raise(NoMethodError, "undefined method for nil")

        expect { built.handoff(timeline: line, session:) }.to raise_error(NoMethodError)
      end
    end

    it "reports handed_off? once a document has replaced the history" do
      built = handing_off
      refused_render(built, timeline)

      expect(built.handed_off?).to be(true)
    end

    # Compaction is a derived view of one chat's own history and project memory
    # is durable fact; neither reads the other. This object cannot reach a
    # store, and the assertion is that it holds nothing that could.
    it "writes no memory: the only record a handoff leaves is its cut" do
      built = handing_off
      refused_render(built, timeline)

      expect(records.map { |record| record["type"] }).not_to include("memory_write", "memory_root")
    end
  end
end
