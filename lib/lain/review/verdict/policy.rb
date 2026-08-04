# frozen_string_literal: true

module Lain
  module Review
    module Verdict
      # Whether a verdict may be recorded over the changeset it judges.
      #
      # A PORT, not a rule, and that is the whole reason it is an object. The
      # interaction between "approve requires every hunk reviewed" and the
      # `deferred` approval gate is an open question, and a rule you cannot swap
      # is a rule you cannot experiment with on a bench -- so {Session} takes one
      # of these as a collaborator and takes no admissibility decision itself.
      # {EveryHunk} is what it takes when nobody says otherwise; {Permissive} is
      # the designed escape for an unattended run.
      #
      # It judges ADMISSIBILITY only. The vocabulary -- that `approve` is a
      # verdict and `looks-fine` is not -- belongs to {Review::VERDICTS} and is
      # enforced by {ReviewVerdict}'s own guard, which runs whether a policy
      # exists or not. Two guards for one question is how they drift apart.
      class Policy
        # An approve was submitted over work that is not fully reviewed. Named
        # after the CHANGESET's condition rather than the verdict's, because the
        # answer is to finish reviewing (or to swap the policy), never to pick a
        # different word.
        class Incomplete < Error; end

        # @return [Policy] the policy a session takes when nobody names one
        def self.default = EveryHunk.new

        # @param verdict [String] a member of {Review::VERDICTS}
        # @param changeset [#base_ref, #hunks] the whole, unfiltered changeset
        # @param marks [Review::Marks] the mark set recorded against it
        # @return [void]
        # @raise [Incomplete] if this policy refuses the submission
        def admit!(verdict, changeset:, marks:)
          raise NotImplementedError,
                "#{self.class} must answer #admit!(verdict, changeset:, marks:) -- deciding admissibility is " \
                "what a policy IS, and a base class that admitted by default would make forgetting to " \
                "implement it look like a deliberate permissive rule"
        end

        # Approve only over a changeset whose every hunk is marked reviewed.
        #
        # It reads the tri-state through {Marks#states} -- one total pass, and
        # the one place that derivation lives -- rather than deriving anything
        # itself. A second derivation here would be free to disagree with the
        # glyph a surface renders beside it, which is the same trap
        # {Review::MARK_STATES}' own doc warns about for a stored `partial`.
        #
        # A file the diff touched but no hunk covers (a binary change, a mode
        # change, a pure rename) never reaches {Marks#states} at all, so it
        # cannot block: it has no unreviewed hunk to block WITH. Its row still
        # renders `unreviewed`, because no hunk of it is marked reviewed, and
        # those two statements are consistent rather than in tension -- one is
        # about hunks, the other about a file with none.
        class EveryHunk < Policy
          # The one {MARK_STATES} member that counts, in the Symbol form
          # {Marks#states} answers in. Derived from {Marks::REVIEWED} rather
          # than restated, the rule `Anchor::SIDES` follows for `Review::SIDES`.
          REVIEWED = Marks::REVIEWED.to_sym

          # How many files a refusal names before it summarizes the rest. A
          # work-scale changeset is thousands of files (research 3.7), and a
          # refusal that names every one of them is a wall a human reads none
          # of; the COUNT is the part they act on.
          NAMED_LIMIT = 5

          # @param verdict [String] a member of {Review::VERDICTS}
          # @param changeset [#base_ref, #hunks] the whole, unfiltered changeset
          # @param marks [Review::Marks] the mark set recorded against it
          # @return [void]
          # @raise [Incomplete] naming the files that are not fully reviewed
          # @raise [Marks::BaseMismatch] if the marks were recorded against
          #   another base -- raised by {Marks#states}, not re-checked here
          def admit!(verdict, changeset:, marks:)
            outstanding = marks.states(changeset).reject { |_path, state| state == REVIEWED }.sort
            return if outstanding.empty?

            raise Incomplete, refusal(verdict, outstanding)
          end

          private

          # Says WHICH way each file falls short, because partial and unreviewed
          # call for different work, and points at the swap as well as the wall
          # -- an unattended run that hits this gets one sentence, and that
          # sentence has to carry its own escape.
          def refusal(verdict, outstanding)
            named = outstanding.first(NAMED_LIMIT).map { |path, state| "#{path} is #{state}" }
            rest = outstanding.size - named.size
            named << "and #{rest} more" unless rest.zero?
            "#{verdict} is refused over a changeset that is not fully reviewed: #{named.join(", ")} -- " \
              "mark every hunk, or open the session with #{Permissive.name}.new if this run means to " \
              "judge regardless"
          end
        end

        # Admit anything. The designed escape for a run with nobody at a
        # keyboard: an unattended agent under the `deferred` gate cannot mark
        # hunks, so {EveryHunk} would wedge it, and the answer is to swap the
        # rule rather than to weaken it for everyone.
        #
        # It is a real class rather than a `->(...) {}` so that a caller wiring
        # it says the name out loud in the code and in the journal-adjacent
        # refusal message above.
        class Permissive < Policy
          # Every argument is kept and named, and none is read: the port's shape
          # is what a reader needs from this file, and `(*, **)` would hide it.
          # {Surface::Null} makes the same trade for the same reason.
          #
          # @return [void]
          def admit!(verdict, changeset:, marks:) = nil # rubocop:disable Lint/UnusedMethodArgument
        end
      end
    end
  end
end
