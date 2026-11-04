# frozen_string_literal: true

module Lain
  module Approval
    # What a wait nobody answered settles as: a parked call or a gate whose
    # window closed. The project picks it with `approval silence:`, and hold
    # is the default because an absent human is a "not yet", not a "no".
    #
    # An interrupt is not silence: a cancelled wait denies whatever the rule.
    module Silence
      # A gate stays held and listed for the human; a parked call is postponed,
      # leaving the queue until the agent issues it again.
      class Hold
        # @param seconds [Numeric] the window that closed
        # @return [Verdict::Hold]
        def verdict(seconds) = Verdict::Hold.new(note: "no answer within #{Silence.face(seconds)}s")

        # @return [String] what a prompt says the window's close will do
        def warning = "postpones"

        # @return [String] what a lapse line says the window's close did
        def past = "postponed"
      end

      # For a project that wants an unattended run to fail closed rather than wait.
      class Deny
        # @param _seconds [Numeric] the window that closed
        # @return [Verdict::Deny]
        def verdict(_seconds) = Verdict::Deny.new(note: "timeout")

        # @return [String] what a prompt says the window's close will do
        def warning = "auto-denies"

        # @return [String] what a lapse line says the window's close did
        def past = "denied"
      end

      HOLD = Hold.new.freeze
      DENY = Deny.new.freeze

      RULES = { hold: HOLD, deny: DENY }.freeze

      # What a project that sets nothing gets, read off the config's own default.
      DEFAULT = RULES.fetch(Config::DEFAULT_APPROVAL_SILENCE)

      # Whole seconds print as an integer, so a long window never reads in exponent form.
      #
      # @param seconds [Numeric]
      # @return [Numeric]
      def self.face(seconds) = seconds == seconds.to_i ? seconds.to_i : seconds

      # @param name [Symbol] :hold or :deny
      # @return [Boolean] whether a project may name it
      def self.named?(name) = RULES.key?(name)

      # @param config [Config]
      # @return [Hold, Deny] the rule the project's `approval silence:` names
      def self.from(config) = RULES.fetch(config.approval_silence)
    end
  end
end
