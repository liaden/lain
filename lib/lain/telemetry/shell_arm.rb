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
      # allow ever authorised one.
      #
      # `arm` is enumerated the same way and for the same reason, over the two
      # shapes {Tools::Bash} can hand a backend. It is held VERBATIM here too:
      # a third arm added at the tool and not here refuses the record loudly
      # rather than journalling a name nothing runs.
      class ShellArm < Declarative::Carrier
        attribute :tool_use_id
        attribute :verdict
        attribute :arm
        attribute :reason
        attribute :term
        validates :tool_use_id,
                  presence: { message: "must name the call this record is about, got nil" }
        validates :verdict, presence: { message: "must name the verdict the call was given, got nil" },
                            inclusion: { in: %i[allow deny abstain],
                                         message: "must be allow, deny or abstain, got %<value>s" }
        validates :arm, presence: { message: "must name the arm the command ran on, got nil" },
                        inclusion: { in: %i[term string],
                                     message: "must be term or string, got %<value>s" }
        validates :reason, presence: { message: "must carry the verdict's reason, got nil" }
        validate :term_is_argv_stages
        validate :term_absent_unless_allowed
        validate :term_arm_needs_an_authorised_term

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

        # The term arm runs the reconstructed argv, and only an allow ever
        # authorises one, so a record claiming a call ran as a term under a
        # verdict that produced none describes something that cannot have
        # happened. The CONVERSE is deliberately unchecked: an allow that ran on
        # the string arm is the exact divergence `arm` exists to record.
        def term_arm_needs_an_authorised_term
          return if errors[:term].any? || arm != :term || (verdict == :allow && !term.empty?)

          errors.add(:arm, "must be string unless the verdict allows and authorised a term, got term")
        end
      end
    end
    # Which arm a gated shell call ran on, and why -- the Journal's only account
    # of arm selection when no ladder ran. The gate journals a `shell verdict`
    # line from inside its escalation record, but a gate over
    # {Middleware::Gate::ApproveAll} consults no rung and writes no escalation
    # record, so without this one such a gate records nothing about the choice
    # at all.
    #
    # TWO QUESTIONS, TWO MEMBERS, and the whole point is that they can disagree.
    # `verdict` is what {Shell::Verdict} DECIDED about the command; `arm` is what
    # actually ran. Only an allow ever authorises a term, but an allow does not
    # mean one was taken: {Tools::Bash} offers the term only where the backend
    # has a shape for it, and {Exec::Docker#takes_term?} is `term.size == 1` --
    # so under `--exec docker` every allowed PIPE, `cat README.md | head -20`
    # included, falls back to the model's own string and runs as
    # `["sh", "-c", command]` inside the container. A record carrying the verdict
    # alone said `allow` there, and a reader who took that to mean "no shell
    # anywhere" was wrong on this chunk's own headline command.
    #
    # `arm` is therefore written from the tool's OWN resolved choice -- the same
    # value it hands the backend, never a second derivation of the same
    # predicate, which could disagree with what ran. Whether a non-allow ran at
    # all is a further question this record does not answer: both approval
    # levels' triage rung refuses a deny, while a gate over ApproveAll runs it on
    # the string arm.
    #
    # `verdict`, `reason` and `term` are {Shell::Verdict::Decision#record}'s own
    # names, so a reader joining the two accounts of one call keys on the same
    # words in both. `arm` has no counterpart there, and cannot: a Decision does
    # not know which backend was handed it.
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
    ShellArm = Data.define(:tool_use_id, :verdict, :arm, :reason, :term, :claim) do
      include Journalable

      # @param tool_use_id [String] the `tool_use` block this call answers
      # @param verdict [Symbol, String] `:allow`, `:deny` or `:abstain`
      # @param arm [Symbol, String] `:term` if the reconstructed argv is what
      #   ran, `:string` if the model's own command reached a shell. Required,
      #   with no default and no derivation from `verdict`: which arm ran is the
      #   one question this record exists to answer, and a guess at it would be
      #   wrong for every allowed pipe under `--exec docker`.
      # @param reason [String] the decision's own reason, verbatim
      # @param term [Array<Array<String>>] the argv stages an allow authorised
      def initialize(tool_use_id:, verdict:, arm:, reason:, term: Shell::Verdict::NO_TERM)
        verdict = verdict.to_s.to_sym
        arm = arm.to_s.to_sym
        Carriers::ShellArm.check!(tool_use_id:, verdict:, arm:, reason:, term:)

        super(tool_use_id: -tool_use_id.to_s, verdict:, arm:, reason: -reason.to_s,
              term: interned_term(term), claim: Shell::Verdict::CLAIM)
      end

      # THE TWO PREDICATES, and the difference between them is the whole reason
      # this record has two members. `allow?` is the DECISION -- {Shell::Verdict}
      # understood the command and authorised a term. `term_arm?` is what RAN --
      # that term was actually spawned as argv, with no shell anywhere. Every
      # `term_arm?` is an `allow?`; the reverse fails wherever the backend had no
      # shape for the term, which under `--exec docker` is every allowed pipe.
      #
      # SO: counting how many commands ran deterministically is `term_arm?`, and
      # `allow?` overcounts it. That asymmetry is why the predicate exists rather
      # than a note telling a reader to compare `arm` by hand.
      #
      # @return [Boolean] whether the shell verdict allowed the command, whatever
      #   then ran it.
      def allow? = verdict == :allow

      # @return [Boolean] whether the reconstructed term is what actually ran,
      #   which is the question "did this command avoid a shell" asks.
      def term_arm? = arm == :term

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
