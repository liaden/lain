# frozen_string_literal: true

require "lain/context/cache_breakpoints"
require "lain/context"
require "lain/store"
require "lain/timeline"
require "lain/toolset"

RSpec.describe Lain::Context::CacheBreakpoints do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, content)
    { "role" => role, "content" => content }
  end

  it "is a no-op on an empty message list" do
    expect(described_class.new.call([])).to eq([])
  end

  it "marks the last content block of the final message" do
    messages = [message("user", text("hello")), message("assistant", text("hi"))]
    marked = described_class.new.call(messages)
    expect(marked.last["content"].last["cache"]).to be(true)
  end

  it "leaves earlier short turns unmarked" do
    messages = [message("user", text("hello")), message("assistant", text("hi"))]
    marked = described_class.new.call(messages)
    expect(marked.first["content"].last).not_to have_key("cache")
  end

  # Agentic turns pile up tool_use/tool_result pairs and drift outside the
  # lookback window, so intermediate breakpoints are placed inside it.
  it "adds an intermediate breakpoint on a long turn" do
    fat = [message("user", Array.new(16) { { "type" => "text", "text" => "x" } }), message("assistant", text("ok"))]
    marked = described_class.new.call(fat)
    expect(marked.first["content"].last["cache"]).to be(true)
  end

  it "respects a configured every: and stays inside the lookback window by construction" do
    expect { described_class.new(every: 25, lookback: 20) }
      .to raise_error(ArgumentError, /inside the lookback window/)
  end

  # The whole point of a breakpoint: a volatile/timestamp-bearing tail must
  # not change which PRIOR blocks are marked, so the cached prefix stays
  # stable even as the tail churns turn over turn.
  it "does not move an earlier breakpoint when a volatile tail is appended" do
    base = [message("user", text("hello")), message("assistant", text("hi"))]
    marked_base = described_class.new.call(base)

    with_tail = base + [message("user", text("volatile: #{Time.now.to_f}"))]
    marked_with_tail = described_class.new.call(with_tail)

    expect(marked_with_tail.first).to eq(marked_base.first)
  end

  it "declares that it requires prompt_caching from the Provider" do
    expect(described_class.new.requires).to eq([:prompt_caching])
  end

  it "is pure: identical input yields identical output" do
    messages = [message("user", text("hello"))]
    combinator = described_class.new
    expect(combinator.call(messages)).to eq(combinator.call(messages))
  end

  it "composes with other combinators via >>" do
    require "lain/context/base"
    messages = [message("user", text("hello"))]
    composed = described_class.new >> Lain::Context::Identity
    expect(composed.call(messages).last["content"].last["cache"]).to be(true)
  end

  # CE-1: Anthropic rejects a request carrying more than 4 cache_control
  # blocks. Two layers used to place them independently (this combinator
  # AND AnthropicEncoding#with_stride_breakpoint) with no shared budget, so a
  # long-enough session 400s. This combinator now owns the whole budget.
  describe "the cap" do
    it "defaults to 4" do
      expect(described_class.new.instance_variable_get(:@message_budget)).to eq(3)
    end

    it "rejects a non-positive cap" do
      expect { described_class.new(cap: 0) }.to raise_error(ArgumentError, /cap/)
    end

    # Force far more candidate breakpoints (every ~15 blocks) than the
    # message budget could ever hold, so the cap has to actually drop some.
    def fat_messages(turns:, blocks_per_turn: 4)
      turns.times.map do |i|
        message(i.even? ? "user" : "assistant", Array.new(blocks_per_turn) do |j|
          { "type" => "text", "text" => "t#{i}b#{j}" }
        end)
      end
    end

    it "never marks more than message_budget blocks, tail-clustered" do
      messages = fat_messages(turns: 30)
      marked = described_class.new(cap: 4).call(messages)

      marked_indices = marked.each_index.select { |i| marked[i]["content"].last["cache"] }
      expect(marked_indices.size).to be <= 3
      expect(marked_indices.last).to eq(messages.size - 1)
    end

    it "drops the OLDEST intermediate markers first, keeping the most recent" do
      messages = fat_messages(turns: 30)
      uncapped = described_class.new(cap: 31).call(messages)
      capped = described_class.new(cap: 4).call(messages)

      uncapped_indices = uncapped.each_index.select { |i| uncapped[i]["content"].last["cache"] }
      capped_indices = capped.each_index.select { |i| capped[i]["content"].last["cache"] }

      expect(capped_indices).to eq(uncapped_indices.last(3))
    end

    # AC: "a long session never exceeds the marker budget" -- exercised
    # through the full pipeline, since that's what the acceptance criterion
    # is actually about: the Request Context#render produces, not just the
    # combinator's own return value.
    it "keeps a >100-block Request, with a cache-marked system prompt, at <= 4 markers total" do
      store = Lain::Store.new
      timeline = 30.times.inject(Lain::Timeline.empty(store: store)) do |tl, i|
        tl.commit(role: i.even? ? :user : :assistant,
                  content: Array.new(4) { |j| { "type" => "text", "text" => "turn #{i} block #{j}" } })
      end
      context = Lain::Context.new(model: "m", max_tokens: 1024, system: "be terse")

      request = context.render(timeline: timeline, toolset: Lain::Toolset.new)

      total_blocks = request.messages.sum { |m| m["content"].size }
      expect(total_blocks).to be > 100

      markers = Array(request.system).count { |b| b["cache"] } +
                request.messages.sum { |m| m["content"].count { |b| b["cache"] } }
      expect(markers).to be <= 4
    end

    # Cap is a parameter, and the system marker (Context#cache_marked_system)
    # always counts against it: this combinator has no visibility into
    # whether a render carries a system prompt, so it reserves that slot
    # unconditionally rather than guessing.
    it "leaves only 3 of a cap: 4 budget for messages once the system marker is accounted for" do
      store = Lain::Store.new
      timeline = 30.times.inject(Lain::Timeline.empty(store: store)) do |tl, i|
        tl.commit(role: i.even? ? :user : :assistant,
                  content: Array.new(4) { |j| { "type" => "text", "text" => "turn #{i} block #{j}" } })
      end
      context = Lain::Context.new(model: "m", max_tokens: 1024, system: "be terse")

      request = context.render(timeline: timeline, toolset: Lain::Toolset.new)

      expect(Array(request.system).last["cache"]).to be(true)
      message_markers = request.messages.sum { |m| m["content"].count { |b| b["cache"] } }
      expect(message_markers).to be <= 3
    end
  end
end
