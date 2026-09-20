# frozen_string_literal: true

# The ONE reader of "what did this chain write to memory", shared by the live
# view following a rewind and by the replay rebuilding a recorded one. Driven
# here over hand-written content blocks, because the claim is about the blocks
# and not about where they came from -- a live Event's content and a recorded
# turn's are the same input by design.
RSpec.describe Lain::Memory::Writes do
  def write_use(id)
    { "type" => "tool_use", "id" => "tu_#{id}", "name" => "memory_write",
      "input" => { "id" => id, "description" => "about #{id}", "body" => "body of #{id}" } }
  end

  def result(id, is_error: false) = { "type" => "tool_result", "tool_use_id" => "tu_#{id}", "is_error" => is_error }

  it "yields the item each answered call wrote, in chain order" do
    writes = described_class.new([[write_use("a")], [result("a"), write_use("b")], [result("b")]])

    expect(writes.map(&:id)).to eq(%w[a b])
    expect(writes.first.body).to eq("body of a")
  end

  it "groups the items by the turn that made them, so a caller can snapshot per turn" do
    writes = described_class.new([[write_use("a")], [result("a"), write_use("b")], [result("b")]])

    expect(writes.per_turn.map { |items| items.map(&:id) }).to eq([["a"], ["b"], []])
  end

  it "skips a call the model was handed back an error for" do
    writes = described_class.new([[write_use("a")], [result("a", is_error: true)]])

    expect(writes.to_a).to be_empty
  end

  # A round a rewind left behind, or one torn before its results landed: no
  # result at all is not the same as a successful one, and a view built from
  # either would hold a write that never ran.
  it "skips a call no turn answered at all" do
    writes = described_class.new([[write_use("a")]])

    expect(writes.to_a).to be_empty
  end

  it "ignores blocks that are not memory_write calls" do
    other = { "type" => "tool_use", "id" => "tu_x", "name" => "read_file", "input" => { "path" => "x" } }
    writes = described_class.new([[other, { "type" => "text", "text" => "hi" }],
                                  [{ "type" => "tool_result", "tool_use_id" => "tu_x", "is_error" => false }]])

    expect(writes.to_a).to be_empty
  end

  it "reads a turn whose content is not an array at all as writing nothing" do
    expect(described_class.new(["just text", nil]).to_a).to be_empty
  end

  it "is an Enumerator without a block, so a caller may compose rather than collect" do
    expect(described_class.new([]).each).to be_a(Enumerator)
  end
end
