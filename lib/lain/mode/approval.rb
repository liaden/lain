# frozen_string_literal: true

module Lain
  class Mode
    Approval = Data.define(:name, :lighter)

    # Who decides a gated call the session's own rules left open -- the second
    # of a mode's two exclusive axes, and exactly three levels.
    #
    # All run the deterministic rungs first, so a triage deny or a rule deny
    # decides under any. They differ only in what stands below those rungs:
    # `ask` parks the call for a surface (a human, or the secret oracle),
    # `auto` asks a model judge first and
    # parks only what it cannot settle, and `bypass` approves it. There is no
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
      # `auto` is silent because a launched chat starts in it. `ask` is lit
      # because the session will wait on a human, and `bypass` because it
      # approves what a human or a judge would otherwise have decided.
      DECLARED = {
        ask: new(name: :ask, lighter: "ASK"),
        auto: new(name: :auto, lighter: ""),
        bypass: new(name: :bypass, lighter: "BYPASS")
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
