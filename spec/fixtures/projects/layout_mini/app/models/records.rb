# frozen_string_literal: true

# Named for neither constant it defines, so a spec describing OrderTransition
# mirrors this file rather than one spelled after the class.
class OrderTransition
  def from = :pending
end

# The second constant, which is what a constant-equals-path rule would miss.
class OrderRecord
  def id = 1
end
