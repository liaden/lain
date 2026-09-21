# frozen_string_literal: true

module Lain
  # The one place allowed to touch the terminal (see spec/output_discipline_spec.rb).
  # Everything under lib/lain/frontend/ is exempt from that rule; nothing outside it
  # may write to $stdout/$stderr. {TTY} owns the terminal and drains a {Lain::Channel}
  # of already-attributed {Lain::Telemetry}s; {ApprovalPolicy} is the interactive
  # {Middleware::Gate} policy that prompts a human here, because prompting is
  # itself a terminal write.
  module Frontend
  end
end
