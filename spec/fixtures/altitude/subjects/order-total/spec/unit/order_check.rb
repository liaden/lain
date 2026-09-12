# frozen_string_literal: true

require_relative "../../lib/order"

# Two passing unit examples and one failing one, so a lease harness grading
# this level root scores 2 of 3 and does not pass.
#
# `_check.rb`, never `_spec.rb`, and the sibling `.rspec` points rspec at that
# pattern: a committed `*_spec.rb` anywhere under `spec/` is collected by lain's
# OWN suite, which would run this fixture's deliberate failure as a real one.
RSpec.describe Order do
  it "totals its lines" do
    expect(described_class.new([1, 2]).total).to eq(3)
  end

  it "totals an order with no lines as zero" do
    expect(described_class.new.total).to eq(0)
  end

  it "refunds a line (intentionally failing, and what the work is for)" do
    expect(described_class.new([1, 2]).refunded).to eq(0)
  end
end
