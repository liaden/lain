# frozen_string_literal: true

require_relative "../../lib/order"

# One passing example at a DIFFERENT level root, so a harness that failed to
# narrow to the unit root would grade 3 of 4 rather than 2 of 3 -- which is what
# makes the narrowing an assertion rather than a coincidence.
RSpec.describe Order do
  it "reads its own source off disk" do
    expect(File.exist?(__FILE__)).to be(true)
  end
end
