# frozen_string_literal: true

module Lain
  class Journal
    class Projection
      # Each agent of one chat as blocked, working, done or idle. The main chat is working from a
      # request of its own to the ask that settles it, and the judge's and summarizer's requests are
      # not its work. A spawned child is working from its spawn to a terminal completion. An agent
      # is blocked for as long as {Waits} holds an open wait that names it, whatever else it was
      # doing, and returns to that when the wait closes.
      #
      # Records arrive as {Telemetry.read} answers them, so a record read back from a file and a
      # live one fold alike; the one that arrives untyped is matched by its journal type.
      class AgentStates < Projection
        # @!attribute [r] id
        #   @return [String] {::Lain::AgentStates::MAIN} or a spawn's digest
        # @!attribute [r] state
        #   @return [Symbol] one of {::Lain::AgentStates::ORDER}
        # @!attribute [r] what
        #   @return [String, nil] what the human is asked, for a blocked agent
        Agent = Data.define(:id, :state, :what)

        # @return [AgentStates]
        def self.unit = new({ waits: Waits.unit, base: { ::Lain::AgentStates::MAIN => :idle } })

        # @param record [Telemetry::Journalable, Telemetry::Untyped, ::Lain::AgentStates::Seen]
        # @return [AgentStates]
        def step(record)
          with(waits: waits.step(record), base: advanced(record))
        end

        # A wait naming a spawn with no spawn record is not shown as an agent.
        #
        # @return [Array<Agent>] main first, then each spawn in the order it appeared
        def agents = base.map { |id, state| agent(id, state) }

        # @return [Symbol] the most urgent state of any agent
        def rollup = ::Lain::AgentStates::ORDER.find { |state| agents.any? { _1.state == state } }

        # @return [Array<Agent>] the agents finished that no {::Lain::AgentStates::Seen} has cleared
        def done_unseen = agents.select { _1.state == :done }

        # @return [Array<Agent>]
        def value = agents

        private

        def waits = state.fetch(:waits)

        def base = state.fetch(:base)

        def with(**changes) = self.class.new(state.merge(changes))

        def agent(id, resting)
          wait = waits.open_for(id).first
          wait ? Agent.new(id:, state: :blocked, what: wait.summary) : Agent.new(id:, state: resting, what: nil)
        end

        def advanced(record)
          case record
          when Telemetry::RequestSent then Telemetry::RequestSent.agent?(record.to_journal) ? main(:working) : base
          when Telemetry::AskSettled then main(:done)
          when Telemetry::RunInterrupted then main(:idle)
          when Telemetry::Message then messaged(record)
          when Telemetry::ChildProgress then progressed(record.spawn)
          when ::Lain::AgentStates::Seen then seen(record.agent)
          when Telemetry::Untyped then read_back(record)
          else base
          end
        end

        def set(id, resting) = base.merge(id => resting)

        def main(resting) = set(::Lain::AgentStates::MAIN, resting)

        def read_back(record)
          record["type"] == "run_interrupted" ? main(:idle) : base
        end

        def messaged(record)
          return set(record.digest, :working) if record.kind == :spawn && !base.key?(record.digest)

          ended = record.causal_parents.select { base.key?(_1) }
          ended.empty? || !finished?(record) ? base : ended.inject(base) { |rest, id| rest.merge(id => :done) }
        end

        def finished?(record)
          lifecycle = StatusFeed::SpawnLifecycle.new(record)
          record.kind == :message && (lifecycle.terminal? || lifecycle.finished?)
        end

        def progressed(spawn)
          base[spawn] == :done ? base : set(spawn, :working)
        end

        def seen(agent)
          base.to_h { |id, resting| [id, resting == :done && (agent.nil? || agent == id) ? :idle : resting] }
        end
      end
    end
  end
end
