# frozen_string_literal: true

module Lain
  class Mode
    Scope = Data.define(:name, :lighter)

    # Where a session's writes and commands land -- the first of a mode's two
    # exclusive axes. `checkout` is the project's own working tree, the only
    # scope there is until plan scope confines a session to a spike worktree.
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
      # in it says nothing.
      DECLARED = { checkout: new(name: :checkout, lighter: "") }.freeze
      private_constant :DECLARED

      # Derived from the table, so the roster an error lists cannot drift from
      # the one that exists.
      NAMES = DECLARED.keys.freeze

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
