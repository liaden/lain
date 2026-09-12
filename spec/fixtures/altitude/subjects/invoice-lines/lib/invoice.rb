# frozen_string_literal: true

# A small subject: one file, one missing behaviour. `#net` is the gap an arm is
# asked to close, and the committed unit example fails until it does.
class Invoice
  def initialize(total: 0, discount: 0)
    @total = total
    @discount = discount
  end

  attr_reader :total, :discount

  def net = nil
end
