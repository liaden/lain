# frozen_string_literal: true

# The subject of the test-writing task: a correct module, so the work is to
# write tests that would notice if it were broken.
class Tally
  def initialize = @counts = Hash.new(0)

  def add(key, amount = 1)
    raise ArgumentError, "amount must be positive" unless amount.positive?

    @counts[key] += amount
    self
  end

  def count(key) = @counts[key]

  def total = @counts.values.sum

  def top = @counts.max_by { |_key, count| count }&.first
end
