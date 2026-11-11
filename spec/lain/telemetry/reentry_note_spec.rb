# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ReentryNote do
  it "journals as a reentry_note record holding the note" do
    expect(JSON.generate(described_class.new(note: "waiting on CI").to_journal))
      .to eq('{"type":"reentry_note","note":"waiting on CI"}')
  end

  it "accepts an empty note, which is how a note is cleared" do
    expect(described_class.new(note: "").note).to eq("")
  end

  it "is deeply frozen when built from mutable input" do
    expect(described_class.new(note: +"x")).to be_deeply_frozen
  end

  it "refuses a missing note, naming it" do
    expect { described_class.new }.to raise_error(ArgumentError, /note/)
  end
end
