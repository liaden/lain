# frozen_string_literal: true

require "json"

module Lain
  module Herdr
    # Whether herdr shows the pane a chat reports to, read from `agent get`'s `focused` field.
    class Focus
      # A probe that hangs must not hold a notice open.
      TIMEOUT = 2

      # @param target [Target] the pane and the server that owns it
      # @param shell_out [#call] `Shell::Out.new`, or a double
      def initialize(target:, shell_out: Shell::Out.public_method(:new))
        @target = target
        @shell_out = shell_out
      end

      # Every failure reads as "not focused": the caller then rings, the safe side of not knowing.
      #
      # @return [Boolean]
      def focused?
        run = @shell_out.call(@target.bin, "agent", "get", @target.pane, environment: @target.environment,
                                                                         timeout: TIMEOUT)
        run.run_command
        run.exitstatus.zero? && JSON.parse(run.stdout).dig("result", "agent", "focused") == true
      rescue StandardError
        false
      end
    end
  end
end
