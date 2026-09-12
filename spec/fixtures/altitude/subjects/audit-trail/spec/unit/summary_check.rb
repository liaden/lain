# frozen_string_literal: true

require_relative "../../lib/trail"
require_relative "../../lib/summary"

RSpec.describe Summary do
  it "summarises a trail in one line (intentionally failing, and ordered after Trail#record)" do
    trail = Trail.new
    trail.record("opened")
    trail.record("closed")
    expect(described_class.new(trail).to_s).to eq("opened -> closed")
  end
end
