# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # What `auto` approval asks first, built at the first judged call: the
      # spawn seam it asks through is the toolset build's discovery, and
      # `build_agent`'s spec seam reaches the board with no build behind it.
      class JudgeSource
        # @param role_spawn [#call] answers the run's role-spawn seam
        def initialize(role_spawn)
          @role_spawn = role_spawn
        end

        # A judge that cannot be built is a fault like any other the judge has,
        # so the call goes to a human rather than out of the rung as a raise.
        #
        # @param question [Hash] the requester, tool and input being judged
        # @yieldparam why [String] what went wrong, when the judge faults
        # @return [Symbol] the judge's verdict, or `:fault`
        def call(**question, &on_fault)
          @judge ||= Approval::Judge.new(role_spawn: @role_spawn.call)
          @judge.call(**question, &on_fault)
        rescue StandardError => e
          on_fault&.call("#{e.class}: #{e.message}")
          :fault
        end
      end
    end
  end
end
