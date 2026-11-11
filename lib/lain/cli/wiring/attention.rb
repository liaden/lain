# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # How a chat asks for the person outside the terminal: which notifier the frontend rings
      # through, and whether delayed notices run beside it. The two are chosen together, because a
      # notifier that holds back its sequence and feed entry is only right while notices send them.
      class Attention
        # The chat no tracker feeds: the notifier sends everything at once and no notice runs.
        class Immediate
          def initialize(secrets:, root:, env:)
            @secrets = secrets
            @root = root
            @env = env
          end

          def notifier = @notifier ||= Frontend::TTY::Notifier.for_chat(@secrets, @root, env: @env)

          def notices = AgentStates::Notices::Never
        end

        # @param agent_states [AgentStates::Tracker, nil] nil for a chat nothing feeds
        # @param switchboard [#guard_inputs, #mode_switch] the secrets and the mode layers are read from it
        # @param root [#to_s] the project's root, whose basename titles the feed entry
        # @param paths [Paths] where the user's `attention` table is read from
        # @param env [#[]] the chat process's environment
        # @param focus [#focused?] whether the human is at the chat's window
        # @param clock [#now] the notices' clock; a spec hands in its own
        # @return [Attention, Immediate]
        def self.for(agent_states, switchboard, root:, paths:, focus:, env: ENV, clock: Time)
          secrets = switchboard.guard_inputs.secrets
          return Immediate.new(secrets:, root:, env:) unless agent_states

          new(agent_states:, secrets:, root:, delay: Config.attention(paths:).delay, env:, focus:, clock:,
              layers: switchboard.mode_switch.method(:layers))
        end

        def initialize(agent_states:, secrets:, root:, delay:, layers:, env:, focus:, clock:)
          @agent_states = agent_states
          @secrets = secrets
          @root = root
          @delay = delay
          @layers = layers
          @env = env
          @focus = focus
          @clock = clock
        end

        def notifier = @notifier ||= Frontend::TTY::Notifier.for_chat(@secrets, @root, env: @env, deferred: true)

        def notices
          @notices ||= AgentStates::Notices.new(tracker: @agent_states, notifier:, focus: @focus, delay: @delay,
                                                layers: @layers, clock: @clock)
        end
      end
    end
  end
end
