# frozen_string_literal: true

# The ask ladder over a real queue, for a spec that gates through the queue: the
# queue alone answers a Boolean, so a Gate holding it would drop who answered.
module AskingLadder
  def asking_ladder(queue, tools: Lain::Toolset.new([]), journal: Lain::Channel::Null.instance)
    Lain::Approval::Escalation.for(queue:, tools:, journal:)
  end
end

RSpec.configure { |config| config.include(AskingLadder) }
