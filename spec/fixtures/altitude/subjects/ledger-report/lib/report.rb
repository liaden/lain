# frozen_string_literal: true

require_relative "ledger"

# The second half, which depends on Ledger#total: rendering cannot be right
# until the total is.
class Report
  def initialize(ledger)
    @ledger = ledger
  end

  def header = nil

  def to_s = nil
end
