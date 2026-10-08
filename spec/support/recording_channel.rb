# frozen_string_literal: true

# A tiny in-memory stand-in for Lain::Channel: records everything pushed so a
# spec can assert on emitted events without depending on Channel's threading.
# Reused across specs that need to observe attributed output (Sink::IOAdapter,
# Handler::Live's injected channel, Tools::Bash's live streaming).
class RecordingChannel
  attr_reader :events

  def initialize
    @events = []
  end

  def push(event)
    @events << event
    self
  end
  alias << push

  # The status feed's duck, for the specs that tee onto this as one.
  def transition_listener = Lain::Agent::TransitionListener::Null
end
