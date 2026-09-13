# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A fixture project under `spec/fixtures/` is another project's tree, but
# `rspec` and `parallel_rspec spec` collect every `*_spec.rb` under `spec/`,
# fixtures included. A fixture test file would therefore run in lain's own
# suite, against constants lain never defines. Fixture projects write their
# test files into a copy at run time, or name them outside the pattern, as
# `rspec_mini`'s `_check.rb` does.
#
# This one IS a guard and stays a spec: it goes red the day somebody plants a
# collectible file in a fixture. It was written beside two report-only tree
# censuses, which is why it used to live in `spec/spec_discipline_spec.rb`;
# those moved to `bin/spec-census` because they could not fail, and this did
# not move with them because it can.
module FixtureDiscipline
  # rspec's `_spec.rb` and minitest's `_test.rb`: the two patterns a Ruby
  # runner started from this repository would collect.
  COLLECTED = %w[**/*_spec.rb **/*_test.rb].freeze

  module_function

  # @param fixtures [String] a fixtures directory
  # @return [Array<String>] every file under it a runner would collect
  def collected(fixtures)
    COLLECTED.flat_map { |pattern| Dir.glob(pattern, base: fixtures) }.sort
  end
end

RSpec.describe FixtureDiscipline do
  it "flags a spec or test file planted in a fixture project" do
    Dir.mktmpdir do |fixtures|
      %w[projects/mini/spec/unit/order_spec.rb projects/mini/test/order_test.rb projects/mini/app/order.rb]
        .each do |relative|
          FileUtils.mkdir_p(File.dirname(File.join(fixtures, relative)))
          File.write(File.join(fixtures, relative), "")
        end

      expect(described_class.collected(fixtures))
        .to eq(%w[projects/mini/spec/unit/order_spec.rb projects/mini/test/order_test.rb])
    end
  end

  it "finds none in the real spec/fixtures" do
    expect(described_class.collected(File.join(__dir__, "fixtures"))).to be_empty
  end
end
