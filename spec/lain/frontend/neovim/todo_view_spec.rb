# frozen_string_literal: true

# lain://todos: the session's current todo list, one line per item.
RSpec.describe Lain::Frontend::Neovim::TodoView do
  def todo(content, status) = Struct.new(:content, :status).new(content, status)

  let(:session) { Lain::Session.new }
  let(:view) { described_class.new(session:) }
  let(:turn) { Lain::Telemetry::TurnUsage.new(digest: "blake3:t", model: "m", stop_reason: :end_turn, usage: {}) }

  it "says so when the session has no todos" do
    expect(view.initial).to eq(["(no todos)"])
  end

  it "draws one line per item with a status glyph, pending first" do
    session.write_todos([todo("ship", "completed"), todo("test", "in_progress"), todo("write", "pending")])

    expect(view.update(turn)).to eq(["[ ] write", "[~] test", "[x] ship"])
  end

  it "answers nil when the list did not move" do
    session.write_todos([todo("write", "pending")])
    view.update(turn)

    expect(view.update(turn)).to be_nil
  end

  it "redraws after the list is replaced" do
    session.write_todos([todo("a", "pending")])
    view.update(turn)
    session.write_todos([])

    expect(view.update(turn)).to eq(["(no todos)"])
  end

  it "keeps one buffer line per item when a content holds a newline" do
    session.write_todos([todo("a\nb", "pending")])

    expect(view.update(turn)).to eq(["[ ] a b"])
  end

  it "is named lain://todos" do
    expect(described_class::NAME).to eq("lain://todos")
  end
end
