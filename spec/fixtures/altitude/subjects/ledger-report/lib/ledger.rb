# frozen_string_literal: true

# The first half of a LARGE task: the report below cannot be written until this
# totals, so the two edits are ordered rather than independent.
class Ledger
  def initialize(entries = [])
    @entries = entries
  end

  attr_reader :entries

  def total = nil
end
