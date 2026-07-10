# frozen_string_literal: true

require "lain/context/reminder"
require "lain/workspace"

RSpec.describe Lain::Context::Reminder do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, content)
    { "role" => role, "content" => content }
  end

  let(:workspace) { Lain::Workspace.new(reminders: ["todo: finish M1"]) }

  it "appends workspace blocks to the last user message" do
    messages = [message("user", text("hello")), message("assistant", text("hi")), message("user", text("more"))]
    injected = described_class.new(workspace: workspace).call(messages)
    expect(injected.last["content"].map { |b| b["text"] }).to eq(%w[more] + ["<workspace>todo: finish M1</workspace>"])
  end

  it "declines to inject when the last turn is not a user turn" do
    messages = [message("user", text("hello")), message("assistant", text("thinking"))]
    injected = described_class.new(workspace: workspace).call(messages)
    expect(injected.last["content"].size).to eq(1)
  end

  it "declines to inject an empty workspace" do
    messages = [message("user", text("hello"))]
    injected = described_class.new(workspace: Lain::Workspace.empty).call(messages)
    expect(injected).to eq(messages)
  end

  it "is a no-op on an empty message list" do
    expect(described_class.new(workspace: workspace).call([])).to eq([])
  end

  # The reminder rides the UNCACHED SUFFIX: it must never touch any message
  # but the last, so composing with CacheBreakpoints afterward marks the
  # workspace-bearing tail, not a rewritten prefix.
  it "leaves every message but the last untouched" do
    messages = [message("user", text("hello")), message("assistant", text("hi")), message("user", text("more"))]
    injected = described_class.new(workspace: workspace).call(messages)
    expect(injected[0..-2]).to eq(messages[0..-2])
  end

  it "declares no required capabilities -- it is plain text injection" do
    expect(described_class.new(workspace: workspace).requires).to eq([])
  end

  it "is pure: identical input yields identical output" do
    messages = [message("user", text("hello"))]
    combinator = described_class.new(workspace: workspace)
    expect(combinator.call(messages)).to eq(combinator.call(messages))
  end

  it "composes with other combinators via >>" do
    require "lain/context/base"
    messages = [message("user", text("hello"))]
    composed = described_class.new(workspace: workspace) >> Lain::Context::Identity
    expect(composed.call(messages).last["content"].map { |b| b["text"] })
      .to eq(%w[hello] + ["<workspace>todo: finish M1</workspace>"])
  end
end
