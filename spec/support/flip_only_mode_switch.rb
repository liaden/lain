# frozen_string_literal: true

# The mode switch as the editor's :LainMode sees it: `current` and the
# serialized `flip`, and nothing else. It hides `switch` so a caller doing its
# own read-then-write fails here instead of racing the approval key in
# production.
class FlipOnlyModeSwitch
  def initialize(switch) = @switch = switch

  def current = @switch.current

  def flip(surface:) = @switch.switch(yield(@switch.current), surface:)
end
