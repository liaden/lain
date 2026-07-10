# frozen_string_literal: true

require "lain/context/cache_breakpoints"

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
end
