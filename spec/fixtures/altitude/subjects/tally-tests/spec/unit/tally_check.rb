# frozen_string_literal: true

require_relative "../../lib/tally"

RSpec.describe Tally do
  it "starts empty" do
    expect(described_class.new.total).to eq(0)
  end
end
