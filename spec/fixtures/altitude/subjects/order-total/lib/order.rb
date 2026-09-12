# frozen_string_literal: true

# The subject an altitude task asks an arm to work on: an order that can total
# its lines but cannot yet refund one, which is the gap the committed unit
# example fails on before any arm has run.
class Order
  def initialize(lines = [])
    @lines = lines
  end

  attr_reader :lines

  def total = @lines.sum

  def refunded = nil
end
