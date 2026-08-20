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

        # An approve was submitted over a position a human wrote `blocker` on
        # and has not spoken to since. A DIFFERENT condition from {Incomplete},
        # and told apart because the work each calls for is different: one is
        # "you have not finished reading", the other is "somebody has read it
        # and said no".
        class Blocked < Error; end

        # The one {Review::ANNOTATION_KINDS} member a policy refuses over, and
        # the one that ANSWERS it -- named once each rather than spelled inline,
        # which is {Marks::REVIEWED}'s rule for {Marks::REVIEWED}'s reason. The
        # spec pins both as genuine members of that vocabulary, so a rename
        # there cannot leave either silently matching nothing.
        #
        # `question` is deliberately NEITHER, and that is a decision rather than
        # a gap in the set: asking about something is not answering it, so a
        # question left on a blocker's line leaves the blocker standing.
        BLOCKER = "blocker"
        ANSWER = "note"

        # @return [Policy] the policy a session takes when nobody names one
        def self.default = EveryHunk.new

        # The blockers still standing, and so also the definition of RESOLVED --
        # in one place, on the port, because a second policy deriving its own
        # answer is the trap {Marks} already warns about for the tri-state.
        #
        # ANNOTATIONS ARE A LOG, NOT A MAP, and getting that backwards is worth
        # a paragraph because the first version of this method did. A mark is a
        # map: the key MEANS "this hunk's state", re-marking is the only gesture
        # that touches it, and last-wins is what the key is FOR. A note is an
        # entry: {Session#annotations} is append-only, a surface renders every
        # one of them, and placing a second is an additive act rather than a
        # state transition. So identity here is {AnnotationPlaced}'s own `id` --
        # what {Surface::Neovim} already draws by -- and folding by position
        # would collapse two objections that drifted onto one line into one,
        # making the policy and the surface disagree by construction.
        #
        # A position `(path, side, line)` is therefore not an identity but an
        # ADDRESS: where an answer is delivered. The rule is one answer, one
        # objection, oldest first -- a human with two objections on a line
        # answers both or the line still refuses. What resolves a blocker is a
        # `note` on the same line: `:LainNote note ...`, the `n` key on the diff
        # rail. There is no `resolved` kind and no record that deletes a note,
        # and inventing either would be a persisted-record change; this needs
        # neither.
        #
        # An answer cannot precede its objection, which falls out of the walk
        # rather than being checked: a note landing on a line with nothing open
        # is spent on nothing.
        #
        # `revision` is deliberately NOT part of the address. An anchor carries
        # the revision it was authored against ({AnnotationPlaced}), so folding
        # it in would mean a human who answered a blocker after the diff moved
        # had answered nothing, with no way to tell they had not.
        #
        # @param annotations [Enumerable<AnnotationPlaced>] this round's notes,
        #   oldest first -- {Session#annotations}' own order
        # @return [Array<AnnotationPlaced>] the unanswered blockers, in the
        #   order they were placed
        def self.unresolved(annotations)
          answered = answered_ids(annotations)
          annotations.select { |placed| placed.kind == BLOCKER && !answered.include?(placed.id) }
        end

        # One queue of open blocker ids per address; an {ANSWER} spends the
        # oldest one waiting there. Two accumulators rather than one because
        # they answer different questions -- what is still open as the walk runs,
        # and what was closed by the end -- and only the second is the result.
        #
        # @param annotations [Enumerable<AnnotationPlaced>]
        # @return [Array<String>] the ids of the blockers that were answered
        def self.answered_ids(annotations)
          open = Hash.new { |addresses, key| addresses[key] = [] }
          annotations.each_with_object([]) do |placed, answered|
            standing = open[address(placed)]
            standing << placed.id if placed.kind == BLOCKER
            answered << standing.shift if placed.kind == ANSWER && !standing.empty?
          end
        end
        private_class_method :answered_ids

        # @param placed [AnnotationPlaced]
        # @return [Array] the diff position it names -- where an answer is
        #   delivered, never who it is
        def self.address(placed) = [placed.path, placed.side, placed.line]
        private_class_method :address

        # @param verdict [String] a member of {Review::VERDICTS}
        # @param changeset [#base_ref, #hunks] the whole, unfiltered changeset
        # @param marks [Review::Marks] the mark set recorded against it
        # @param annotations [Enumerable<AnnotationPlaced>] the round's notes.
        #   REQUIRED, with no default: a policy that could be asked without them
        #   is exactly how `blocker` came to be a kind nothing read.
        # @return [void]
        # @raise [Incomplete] if this policy refuses the submission
        # @raise [Blocked] if this policy refuses over an unresolved blocker
        def admit!(verdict, changeset:, marks:, annotations:)
          raise NotImplementedError,
                "#{self.class} must answer #admit!(verdict, changeset:, marks:, annotations:) -- deciding " \
                "admissibility is what a policy IS, and a base class that admitted by default would make " \
                "forgetting to implement it look like a deliberate permissive rule"
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

          # THE ORDER OF THE THREE REFUSALS IS A DECISION, and only one of them
          # is about taste. {Marks#states} raises {Marks::BaseMismatch} first
          # because a base mismatch is a PRECONDITION: the marks were recorded
          # against another diff, and so were the blockers' own line numbers, so
          # nothing below is evidence about the changeset in hand. Refusing
          # "answer the blocker at a.rb:3" over a position that names a line in
          # some other diff sends a human somewhere real and wrong, and only
          # walls them at the actual problem on the second try.
          #
          # Blocked then outranks Incomplete: a human who has read the work and
          # said no is a stronger statement than a human who has not read it
          # yet.
          #
          # This costs the whole-corpus walk on every refusal, blockers included
          # -- an earlier draft put the blocker check first to skip it. That was
          # the wrong trade: correctness outranks the walk, and the walk is one
          # a submit already pays on every path that admits.
          #
          # @param verdict [String] a member of {Review::VERDICTS}
          # @param changeset [#base_ref, #hunks] the whole, unfiltered changeset
          # @param marks [Review::Marks] the mark set recorded against it
          # @param annotations [Enumerable<AnnotationPlaced>] the round's notes
          # @return [void]
          # @raise [Marks::BaseMismatch] if the marks were recorded against
          #   another base -- raised by {Marks#states}, not re-checked here, and
          #   ahead of both refusals below
          # @raise [Blocked] naming the positions still carrying a blocker
          # @raise [Incomplete] naming the files that are not fully reviewed
          def admit!(verdict, changeset:, marks:, annotations:)
            outstanding = marks.states(changeset).reject { |_path, state| state == REVIEWED }.sort
            refuse_blocked!(verdict, Policy.unresolved(annotations))
            return if outstanding.empty?

            raise Incomplete, refusal(verdict, outstanding)
          end

          private

          def refuse_blocked!(verdict, blockers)
            raise Blocked, blocked(verdict, blockers) unless blockers.empty?
          end

          # Names the ADDRESS rather than the note's words: the words are on
          # screen where the human left them, and the address is what they have
          # to navigate back to in order to answer it. The way out is in the
          # sentence for the reason {#refusal} puts the swap in its own -- a wall
          # that does not carry one is a review nobody can settle, and this is
          # the only place the gesture is written down for someone who has not
          # read {Policy.unresolved}.
          #
          # It COUNTS them, because two objections that drifted onto one line
          # name the same address twice and would otherwise read as one entry
          # repeated by mistake.
          def blocked(verdict, blockers)
            named = blockers.first(NAMED_LIMIT).map { |placed| at(placed) }
            rest = blockers.size - named.size
            named << "and #{rest} more" unless rest.zero?
            "#{verdict} is refused over #{tally(blockers.size)} nobody has answered: #{named.join(", ")} -- " \
              "answer each one with a note on that same line, which is what resolves it"
          end

          def tally(size) = "#{size} #{size == 1 ? "blocker" : "blockers"}"

          # Says when the anchor DRIFTED, which is free -- the measurement is on
          # the record ({AnnotationPlaced}) -- and is the difference between a
          # line a human pointed at and a line that has since become something
          # else. Without it the refusal names a position with confidence it has
          # not got.
          def at(placed)
            drift = placed.drifted ? ", drifted" : ""
            "#{placed.path}:#{placed.line} (#{placed.side}#{drift})"
          end

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
          # `annotations` is kept and unread like the rest, and a blocker is
          # therefore admitted over. That is the escape working as designed: a
          # run with nobody at a keyboard cannot resolve a blocker any more than
          # it can mark a hunk, so a Permissive that started reading them would
          # wedge exactly the case it exists to unwedge.
          #
          # @return [void]
          def admit!(verdict, changeset:, marks:, annotations:) = nil # rubocop:disable Lint/UnusedMethodArgument
        end
      end
    end
  end
end
