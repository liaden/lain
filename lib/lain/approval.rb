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

require_relative "approval/queue"
require_relative "approval/queue_surface"
require_relative "approval/auto_surface"
require_relative "approval/secret_surface"
require_relative "approval/policy_switch"
require_relative "approval/signoff_queue"
require_relative "approval/gate"
require_relative "approval/rule"
require_relative "approval/rule_chain"
require_relative "approval/risk"
require_relative "approval/remembered"
require_relative "approval/composed_term"
require_relative "approval/escalation"
