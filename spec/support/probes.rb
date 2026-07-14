# frozen_string_literal: true

# Captures the invocation context it is handed, so a spec can prove the Agent
# threads ONE session all the way down to a tool that runs on a later turn.
class ContextProbe < Lain::Tool
  def initialize(sightings)
    @sightings = sightings
    super()
  end

  def name = "probe"
  def description = "Records the invocation context it is handed."

  def perform(_input, invocation)
    @sightings << invocation.context
    Lain::Tool::Result.ok("peeked")
  end
end
