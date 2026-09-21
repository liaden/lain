# frozen_string_literal: true

module Lain
  # The approval queue behind {Middleware::Gate}: a gated tool call parks
  # as a {Approval::Queue::Pending} until a surface decides it, or the window
  # expires and the fail-closed doctrine denies it. Gate itself is untouched --
  # {Approval::Queue} is one more object answering its injected
  # `#call(effect, context) -> Boolean` seam, and {Gate::DenyAll} stays the
  # no-frontend default.
  module Approval
  end
end
