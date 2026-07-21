# frozen_string_literal: true

module Lain
  # The approval queue behind {Effect::Handler::Gate}: a gated tool call parks
  # as a {Approval::Queue::Pending} until a surface -- any frontend fiber
  # watching the queue -- decides it, or the window expires and the fail-closed
  # doctrine denies it. Gate itself is untouched: {Approval::Queue} is just one
  # more object answering Gate's injected `#call(effect, context) -> Boolean`
  # policy seam, and {Gate::DenyAll} stays the no-frontend default.
  module Approval
  end
end

require_relative "approval/queue"
require_relative "approval/auto_surface"
