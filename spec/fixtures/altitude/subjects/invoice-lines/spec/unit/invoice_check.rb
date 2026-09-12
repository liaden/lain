# frozen_string_literal: true

require_relative "../../lib/invoice"

# Two passing examples and one failing one, so an ungraded arm scores 2 of 3 and
# a successful one scores 3 of 3.
RSpec.describe Invoice do
  it "carries its total" do
    expect(described_class.new(total: 10, discount: 2).total).to eq(10)
  end

  it "carries its discount" do
    expect(described_class.new(total: 10, discount: 2).discount).to eq(2)
  end

  it "nets the discount off the total (intentionally failing, and what the work is for)" do
    expect(described_class.new(total: 10, discount: 2).net).to eq(8)
  end
end
