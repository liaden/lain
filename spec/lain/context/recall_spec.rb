# frozen_string_literal: true

require "lain/context/recall"
require "lain/context/reminder"
require "lain/context/cache_breakpoints"
require "lain/context/base"
require "lain/memory/manifest"
require "lain/memory/index"
require "lain/memory/item"
require "lain/store"
require "lain/workspace"

RSpec.describe Lain::Context::Recall do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, content)
    { "role" => role, "content" => content }
  end

  def tool_use(id:, name: "dosing_lookup", input: {})
    [{ "type" => "tool_use", "id" => id, "name" => name, "input" => input }]
  end

  def tool_result(tool_use_id:, content:)
    [{ "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => content, "is_error" => false }]
  end

  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id: id, description: description, body: body)
  end

  def manifest_over(*items)
    store = Lain::Store.new
    idx = items.inject(Lain::Memory::Index.empty(store: store)) { |acc, entry| acc.write(entry) }
    Lain::Memory::Manifest.new(idx)
  end

  let(:index) { manifest_over(item("aspirin-dosage", "Adult aspirin dosing guidance")) }

  # Scenario: recall rides the uncached tail
  it "leaves every block up to and including the last neutral marker untouched, and appends after it" do
    workspace = Lain::Workspace.new(reminders: ["remember to be terse"])
    base = [message("user", text("what is the aspirin dosing?"))]

    without_recall = (Lain::Context::Reminder.new(workspace: workspace) >> Lain::Context::CacheBreakpoints.new)
                     .call(base)
    with_recall = (Lain::Context::Reminder.new(workspace: workspace) >> Lain::Context::CacheBreakpoints.new >>
                   described_class.new(index: index, k: 3)).call(base)

    marker_len = without_recall.last["content"].size
    expect(with_recall.last["content"].first(marker_len)).to eq(without_recall.last["content"])
    expect(with_recall.last["content"][marker_len - 1]).to have_key("cache")
    expect(with_recall.last["content"].size).to be > marker_len
    expect(with_recall.last["content"].last["text"]).to include("aspirin-dosage")
  end

  # Scenario: recall is pure and explainable
  it "is pure: identical snapshot and messages render byte-identical output, and each line carries its hit's why" do
    base = [message("user", text("what is the aspirin dosing?"))]
    combinator = described_class.new(index: index, k: 3)

    first = combinator.call(base)
    second = combinator.call(base)
    expect(first).to eq(second)

    hit = index.search("what is the aspirin dosing?").first
    expect(first.last["content"].last["text"]).to include(hit.why)
  end

  # Scenario: nothing to recall, nothing injected
  it "renders exactly the without-Recall messages when the index has no matches" do
    base = [message("user", text("what is the weather today?"))]
    combinator = described_class.new(index: index, k: 3)
    expect(combinator.call(base)).to eq(base)
  end

  # Scenario: a tool-result tail recalls from the last real user text
  it "derives the query from the most recent user text, never from tool_results or <workspace> blocks" do
    decoy = manifest_over(
      item("aspirin-dosage", "Adult aspirin dosing guidance"),
      item("dose-value", "325 650mg regimen note")
    )
    messages = [
      message("user", text("what is the aspirin dosing?")),
      message("assistant", tool_use(id: "tu_1")),
      message("user", tool_result(tool_use_id: "tu_1", content: "325-650mg"))
    ]
    combinator = described_class.new(index: decoy, k: 3)
    recalled = combinator.call(messages).last["content"].last["text"]

    expect(recalled).to include("aspirin-dosage")
    expect(recalled).not_to include("dose-value")
  end

  it "excludes <workspace>-tagged text from the query, falling back past it" do
    messages = [
      message("user", text("what is the aspirin dosing?") + [{ "type" => "text",
                                                               "text" => "<workspace>irrelevant</workspace>" }])
    ]
    combinator = described_class.new(index: index, k: 3)
    recalled = combinator.call(messages).last["content"].last["text"]
    expect(recalled).to include("aspirin-dosage")
  end

  it "is a no-op on an empty message list" do
    expect(described_class.new(index: index, k: 3).call([])).to eq([])
  end

  it "declines to inject when the last message is not a user turn" do
    messages = [message("user", text("what is the aspirin dosing?")), message("assistant", text("thinking"))]
    expect(described_class.new(index: index, k: 3).call(messages)).to eq(messages)
  end

  it "declares no required capabilities" do
    expect(described_class.new(index: index, k: 3).requires).to eq([])
  end

  it "composes with other combinators via >>" do
    base = [message("user", text("what is the aspirin dosing?"))]
    composed = described_class.new(index: index, k: 3) >> Lain::Context::Identity
    expect(composed.call(base).last["content"].last["text"]).to include("aspirin-dosage")
  end
end
