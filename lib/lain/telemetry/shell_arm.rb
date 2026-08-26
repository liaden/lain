# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The three names held VERBATIM rather than referenced: this carrier's
      # class body evaluates at telemetry load time, and the shell/ unit loads
      # some sixty entries further down the manifest. {Shell::Verdict::Decision}
      # is the authority; a fourth name added there and not here refuses the
      # record loudly rather than journalling a name no decision answers to.
      #
      # `term` is checked for SHAPE and for agreement with the verdict, which is
      # the record's whole content: a stage list is an argv list, and only an
      # allow ever chose one.
      class ShellArm < Declarative::Carrier
        attribute :tool_use_id
        attribute :verdict
        attribute :reason
        attribute :term
        validates :tool_use_id,
                  presence: { message: "must name the call this record is about, got nil" }
        validates :verdict, presence: { message: "must name the arm the call ran on, got nil" },
                            inclusion: { in: %i[allow deny abstain],
                                         message: "must be allow, deny or abstain, got %<value>s" }
        validates :reason, presence: { message: "must carry the verdict's reason, got nil" }
        validate :term_is_argv_stages
        validate :term_absent_unless_allowed

        private

        # nil is refused here rather than coerced, because the empty term is
        # already a Null Object ({Shell::Verdict::NO_TERM}) and a record that
        # accepted nil would hand every reader back the guard that object exists
        # to remove.
        def term_is_argv_stages
          return if term.is_a?(Array) && term.all? { |stage| stage.is_a?(Array) && stage.all?(String) }

          errors.add(:term, "must be an Array of argv Arrays, empty when there is none, got #{term.inspect}")
        end

        # A record naming an abstention while carrying the argv of a chosen arm
        # tells a reader the opposite of what happened, and which arm ran is the
        # one question this record exists to answer. Skipped when the shape check
        # already failed: it has named the real problem.
        def term_absent_unless_allowed
          return if errors[:term].any? || verdict == :allow || term.empty?

          errors.add(:term, "must be empty unless the verdict allows, got #{term.inspect}")
        end
      end
    end
    # Which arm a gated shell call ran on, and why -- the Journal's only account
    # of arm selection when no ladder ran. The gate journals a `shell verdict`
    # line from inside its escalation record, but `/mode auto` replaces the
    # ladder wholesale, so an unattended run records nothing about the choice at
    # all. That is the mode a long bench run uses, which is what makes it the
    # mode the record most needs to cover.
    #
    # The record is named for the ARM and its field for the VERDICT, so: `allow`
    # ran the reconstructed term as argv with no shell anywhere, and both other
    # names ran the model's own string through a shell, because `Tools::Bash`
    # chooses on `decision.allow?` and nothing else. Whether a non-allow ran at
    # all is a separate question this record does not answer -- the attended
    # ladder refuses a deny, while `/mode auto` approves it and the string arm runs.
    #
    # The field names are {Shell::Verdict::Decision#record}'s, so a reader
    # joining the two accounts of one call keys on the same words in both.
    #
    # `claim` is not a constructor argument: it rides on every record the shell
    # verdict hands a journal so no allow can be read as a claim about safety,
    # and a disclaimer a caller may pass is one a caller may weaken. The intended
    # consequence is that this record has NO working `#with` at all -- `Data#with`
    # re-calls `initialize` with every member, so `with(reason:)` raises
    # `unknown keyword: :claim` exactly as `with(claim:)` does, and nothing needs
    # to copy a journal record.
    #
    # Every String is interned on the way in, which is both what keeps the record
    # `Ractor.shareable?` and what makes the repetition free: a term read back off
    # the Journal arrives as fresh mutable Strings, and a bench run's terms are
    # the same few program names many thousands of times over.
    ShellArm = Data.define(:tool_use_id, :verdict, :reason, :term, :claim) do
      include Journalable

      # @param tool_use_id [String] the `tool_use` block this call answers
      # @param verdict [Symbol, String] `:allow`, `:deny` or `:abstain`
      # @param reason [String] the decision's own reason, verbatim
      # @param term [Array<Array<String>>] the argv stages an allow authorised
      def initialize(tool_use_id:, verdict:, reason:, term: Shell::Verdict::NO_TERM)
        verdict = verdict.to_s.to_sym
        Carriers::ShellArm.check!(tool_use_id:, verdict:, reason:, term:)

        super(tool_use_id: -tool_use_id.to_s, verdict:, reason: -reason.to_s,
              term: interned_term(term), claim: Shell::Verdict::CLAIM)
      end

      # @return [Boolean] whether the call ran as a reconstructed term.
      def allow? = verdict == :allow

      private

      # An empty term is handed back as {Shell::Verdict::NO_TERM} ITSELF rather
      # than as a fresh frozen Array, so every abstention and denial in a run
      # shares the one object a Null Object is meant to be. A rebuilt one would
      # still read `== []`, which is why the identity is asserted in the spec.
      def interned_term(term)
        return Shell::Verdict::NO_TERM if term.empty?

        term.map { |stage| stage.map { |word| -word.to_s }.freeze }.freeze
      end
    end
  end
end
