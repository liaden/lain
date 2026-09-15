# frozen_string_literal: true

module Lain
  class Mode
    Scope = Data.define(:name, :lighter)

    # Where a session's writes and commands land -- the first of a mode's two
    # exclusive axes. `checkout` is the project's own working tree. `plan`
    # confines the session's writes and commands to a spike: a worktree cut
    # from the checkout's tracked state, or a scratch directory outside git.
    #
    # A scope never changes the toolset. What a model is shown stays one set
    # for the life of the session, so a flip cannot move the tool block a
    # prompt cache keys on.
    #
    # Reopened rather than declared inside a `Data.define ... do` block: a
    # constant declared there scopes to the enclosing module, not to the Data
    # class (the trap {Request::SYSTEM_PREFIX} documents).
    class Scope
      # `checkout` is silent: every session starts there, so a prompt composed
      # in it says nothing. `plan` is lit, because what the session writes
      # there never reaches the checkout the human is looking at.
      DECLARED = { checkout: new(name: :checkout, lighter: ""), plan: new(name: :plan, lighter: "PLAN") }.freeze
      private_constant :DECLARED

      # Derived from the table, so the roster an error lists cannot drift from
      # the one that exists.
      NAMES = DECLARED.keys.freeze

      # A declared scope that cannot be entered right now: no spike could be
      # cut, or nothing is bound to confine. Raised before the flip is
      # recorded, so the mode in force is still the one the session is in.
      class Unavailable < Error; end

      # @param name [Symbol, String] one of {NAMES}
      # @return [Scope] the one shared frozen value for that name
      # @raise [ArgumentError] naming every declared scope
      def self.for(name)
        DECLARED.fetch(name.to_sym) do
          raise ArgumentError, "unknown mode scope #{name.inspect}, expected one of #{NAMES.inspect}"
        end
      end
    end
  end
end
