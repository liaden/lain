# frozen_string_literal: true

module Lain
  # What a person glancing at a fleet wants to know of each agent: is it stuck on them, busy, finished
  # and unseen, or quiet. {Journal::Projection::AgentStates} folds the chat's records into that, and
  # the pieces it shares with its readers live here.
  module AgentStates
    MAIN = "main"

    # Most urgent first, which is the order a rollup reads.
    ORDER = %i[blocked working done idle].freeze

    # The human looked at a finished agent. It is no journal record, since sight is not part of the
    # chat's history; whoever watches the human feeds it to the fold.
    #
    # @!attribute [r] agent
    #   @return [String, nil] the agent seen, or nil for every finished one
    Seen = Data.define(:agent)
  end
end
