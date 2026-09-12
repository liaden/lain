# frozen_string_literal: true

require_relative "../../lib/trail"

RSpec.describe Trail do
  it "starts empty" do
    expect(described_class.new.entries).to eq([])
  end

  it "records an entry (intentionally failing)" do
    trail = described_class.new
    trail.record("opened")
    expect(trail.entries).to eq(["opened"])
  end

  it "keeps arrival order (intentionally failing)" do
    trail = described_class.new
    trail.record("opened")
    trail.record("closed")
    expect(trail.entries).to eq(%w[opened closed])
  end
end
