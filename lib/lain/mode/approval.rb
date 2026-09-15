# frozen_string_literal: true

module Lain
  class Mode
    Approval = Data.define(:name, :lighter)

    # Who decides a gated call the session's own rules left open -- the second
    # of a mode's two exclusive axes, and exactly two levels.
    #
    # Both run the deterministic rungs first, so a triage deny or a rule deny
    # decides under either. They differ only in what stands below those rungs:
    # `ask` parks the call for a surface (a human, or the automatic approver
    # the `auto_approve` layer turns on), and `auto` approves it. There is no
    # "is this an edit" predicate between them: only `bash` asks to be gated,
    # so a level that gated edits and not commands would gate nothing different.
    #
    # ⚠️ This class SHADOWS the top-level {Lain::Approval} for everything
    # lexically inside `class Mode`. Root-qualify there.
    #
    # Reopened rather than declared inside a `Data.define ... do` block: a
    # constant declared there scopes to the enclosing module, not to the Data
    # class (the trap {Request::SYSTEM_PREFIX} documents).
    class Approval
      # `ask` is silent because every session starts in it. `auto` is lit: it
      # decides calls a human would otherwise have been asked about.
      DECLARED = {
        ask: new(name: :ask, lighter: ""),
        auto: new(name: :auto, lighter: "AUTO")
      }.freeze
      private_constant :DECLARED

      # Derived from the table, so the roster an error lists cannot drift from
      # the one that exists.
      NAMES = DECLARED.keys.freeze

      # @param name [Symbol, String] one of {NAMES}
      # @return [Approval] the one shared frozen value for that level
      # @raise [ArgumentError] naming every declared level
      def self.for(name)
        DECLARED.fetch(name.to_sym) do
          raise ArgumentError, "unknown approval #{name.inspect}, expected one of #{NAMES.inspect}"
        end
      end
    end
  end
end
