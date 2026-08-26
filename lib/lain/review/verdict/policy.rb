# frozen_string_literal: true

module Lain
  module Review
    module Verdict
      # Whether a verdict may be recorded over the changeset it judges.
      #
      # A PORT, not a rule, and that is the whole reason it is an object. The
      # interaction between "approve requires every hunk reviewed" and the
      # `deferred` approval gate is an open question, and a rule you cannot swap
      # is a rule you cannot experiment with on a bench.
      #
      # THREE RULES, and which of them a caller can TYPE is as much of the design
      # as what each admits. {EveryHunk} is what a session takes when nobody says
      # otherwise. {BlockersOnly} is the escape a human asks for by name
      # ({FLAG}): it forgives rows nobody read and still refuses an objection
      # nobody answered. {Permissive} forgives everything, which is right for a
      # run with nobody at a keyboard and is why it has no typed construction
      # site.
      #
      # It judges ADMISSIBILITY only. The vocabulary belongs to
      # {Review::VERDICTS} and is enforced by {ReviewVerdict}'s own guard, which
      # runs whether a policy exists or not. Two guards for one question is how
      # they drift apart.
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

        # The word a human types to swap this rule out, and the ONE place it is
        # written down. {EveryHunk#refusal} names it in the sentence it refuses
        # with, and `/survey` and `/review` both declare it as a switch -- so a
        # rename that missed one of the three would leave a refusal pointing at
        # a flag nothing reads, which is the defect that wording change exists
        # to end. It cannot be read from either command's CLASS BODY (`lain.rb`
        # loads `lain/cli` before `lain/review`, so a constant there naming this
        # one is a load-time NameError), which is why those two declare the word
        # and this file owns what it MEANS.
        FLAG = "--permissive"

        # @return [Policy] the policy a session takes when nobody names one
        def self.default = EveryHunk.new

        # The flag, resolved. Here rather than in each command because the
        # sentence that offers {FLAG} and the object that flag asks for are one
        # question, and answering it twice is how the two come to disagree.
        #
        # IT DOES NOT ANSWER {Permissive}, AND THAT IS THE POINT OF THE METHOD.
        # The flag's own sentence ({EveryHunk#refusal}) offers it as a way past
        # ROWS nobody has read. An unanswered `blocker` is not an unread row, so
        # forgiving one is outside what the sentence promises, and a flag named
        # in both commands' `usage` would put that power in front of every reader
        # of the help text. An earlier draft of this method DID answer
        # `Permissive`, which made an objection forgivable by a typed line for
        # the first time -- the escape is old, its reachability was new, and
        # reachability is what made it a defect.
        #
        # @param permissive [Boolean] whether the caller's line carried {FLAG}
        # @return [Policy] the escape a human may ask for, or the rule that
        #   applies when nobody asked
        def self.strict_unless(permissive:) = permissive ? BlockersOnly.new : default

        # The blockers still standing, and so also the definition of RESOLVED --
        # in one place, on the port, because a second policy deriving its own
        # answer is the trap {Marks} already warns about for the tri-state.
        #
        # ANNOTATIONS ARE A LOG, NOT A MAP, and getting that backwards is worth a
        # paragraph because the first version of this method did. A mark is a
        # map: the key MEANS "this hunk's state", re-marking is the only gesture
        # that touches it, and last-wins is what the key is FOR. A note is an
        # entry: {Session#annotations} is append-only and placing a second is
        # additive rather than a state transition. So identity here is
        # {AnnotationPlaced}'s own `id`, and folding by position would collapse
        # two objections that drifted onto one line into one, making the policy
        # and the surface disagree by construction.
        #
        # A position `(path, side, line)` is therefore not an identity but an
        # ADDRESS: where an answer is delivered. The rule is one answer, one
        # objection, oldest first. What resolves a blocker is a `note` on the
        # same line; there is no `resolved` kind and no record that deletes a
        # note, and inventing either would be a persisted-record change.
        #
        # An answer cannot precede its objection, which falls out of the walk
        # rather than being checked: a note landing on a line with nothing open
        # is spent on nothing.
        #
        # `revision` is deliberately NOT part of the address. An anchor carries
        # the revision it was authored against, so folding it in would mean a
        # human who answered a blocker after the diff moved had answered nothing,
        # with no way to tell they had not.
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
        # oldest one waiting there. Two accumulators rather than one because they
        # answer different questions -- what is still open as the walk runs, and
        # what was closed by the end -- and only the second is the result.
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

        # Approve over anything except an objection nobody answered.
        #
        # THE ESCAPE A HUMAN MAY ASK FOR BY NAME. {FLAG} resolves here, and the
        # rule is the one that flag's sentence promises: rows nobody read stop
        # refusing, and an unanswered `blocker` still does. Those are different
        # claims -- an unread row says nobody looked, a blocker says somebody
        # looked and said no -- and a single escape collapsing them would make
        # `blocker` a kind nothing reads again.
        #
        # {EveryHunk}'s SUPERCLASS rather than its sibling, so the blocker
        # refusal and its sentence exist once. The strict rule is this rule plus
        # one more, which is what the inheritance says out loud.
        #
        # {Marks#states} is called for its PRECONDITION and its answer discarded:
        # a base mismatch means the blockers' own line numbers were recorded
        # against another diff. {EveryHunk} needs that same walk's RESULT, which
        # is why it re-states the call rather than taking this one through
        # `super` -- two walks of a work-scale corpus for one submission is a
        # real cost.
        class BlockersOnly < Policy
          # How many positions a refusal names before it summarizes the rest. A
          # work-scale changeset is thousands of files (research 3.7), and a
          # refusal that names every one of them is a wall a human reads none
          # of; the COUNT is the part they act on.
          NAMED_LIMIT = 5

          # @param verdict [String] a member of {Review::VERDICTS}
          # @param changeset [#base_ref, #hunks] the whole, unfiltered changeset
          # @param marks [Review::Marks] the mark set recorded against it
          # @param annotations [Enumerable<AnnotationPlaced>] the round's notes
          # @return [void]
          # @raise [Marks::BaseMismatch] if the marks were recorded against
          #   another base -- raised by {Marks#states}, ahead of the refusal
          #   below and for the reason the class doc gives
          # @raise [Blocked] naming the positions still carrying a blocker
          def admit!(verdict, changeset:, marks:, annotations:)
            marks.states(changeset)
            refuse_blocked!(verdict, Policy.unresolved(annotations))
          end

          private

          def refuse_blocked!(verdict, blockers)
            raise Blocked, blocked(verdict, blockers) unless blockers.empty?
          end

          # Names the ADDRESS rather than the note's words: the words are on
          # screen where the human left them, and the address is what they have
          # to navigate back to in order to answer it. The way out is in the
          # sentence for {EveryHunk#refusal}'s reason -- a wall that does not
          # carry one is a review nobody can settle.
          #
          # It offers no flag, and none may ever be added: {FLAG} is advertised
          # in both review commands' `usage`, and a sentence naming one here
          # would tell every reader of the help text how to approve over an
          # objection.
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
        end

        # Approve only over a changeset whose every hunk is marked reviewed.
        #
        # {BlockersOnly} plus one rule: an unanswered objection refuses either
        # way, and this adds that a row nobody has read refuses too. {FLAG} drops
        # exactly this addition.
        #
        # It reads the tri-state through {Marks#states} -- one total pass, and
        # the one place that derivation lives -- rather than deriving anything
        # itself. A second derivation here would be free to disagree with the
        # glyph a surface renders beside it.
        #
        # A file the diff touched but no hunk covers (a binary change, a mode
        # change, a pure rename) never reaches {Marks#states}, so it cannot
        # block: it has no unreviewed hunk to block WITH. Its row still renders
        # `unreviewed`, and the two statements are consistent -- one is about
        # hunks, the other about a file with none.
        class EveryHunk < BlockersOnly
          # The one {MARK_STATES} member that counts, in the Symbol form
          # {Marks#states} answers in. Derived from {Marks::REVIEWED} rather
          # than restated, the rule `Anchor::SIDES` follows for `Review::SIDES`.
          REVIEWED = Marks::REVIEWED.to_sym

          # THE ORDER OF THE THREE REFUSALS IS A DECISION, and only one of them
          # is about taste. {Marks#states} raises {Marks::BaseMismatch} first
          # because a base mismatch is a PRECONDITION: the marks were recorded
          # against another diff, and so were the blockers' own line numbers, so
          # nothing below is evidence about the changeset in hand. Refusing
          # "answer the blocker at a.rb:3" over a position naming a line in some
          # other diff sends a human somewhere real and wrong.
          #
          # Blocked then outranks Incomplete: a human who has read the work and
          # said no is a stronger statement than one who has not read it yet.
          #
          # This costs the whole-corpus walk on every refusal, blockers included
          # -- an earlier draft put the blocker check first to skip it. Wrong
          # trade: correctness outranks the walk, and it is one a submit already
          # pays on every path that admits.
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

          # Says WHICH way each file falls short, because partial and unreviewed
          # call for different work, and points at the swap as well as the wall
          # -- an unattended run that hits this gets one sentence, and that
          # sentence has to carry its own escape.
          #
          # BOTH REMEDIES ARE GESTURES, and that is the correction this sentence
          # carries. It used to end `Verdict::Policy::Permissive.new`, a Ruby
          # constructor offered to somebody holding an editor: this message is
          # {Handover#wrote_verdict}'s return value, and the lua half echoes it on
          # the review rail. `x` is the sidebar's own reviewed-mark key and {FLAG}
          # is a switch both review commands declare, so a reader can perform
          # either without leaving the review.
          #
          # It says nothing about a blocker, and must not: {BlockersOnly#blocked}
          # outranks this refusal, so a human reading THIS one has none standing.
          # The escape it offers is mechanically incapable of forgiving one --
          # {FLAG} resolves to {BlockersOnly} -- and the two statements have to
          # stay true together.
          def refusal(verdict, outstanding)
            named = outstanding.first(NAMED_LIMIT).map { |path, state| "#{path} is #{state}" }
            rest = outstanding.size - named.size
            named << "and #{rest} more" unless rest.zero?
            "#{verdict} is refused over a changeset that is not fully reviewed: #{named.join(", ")} -- " \
              "mark each row reviewed with `x` in lain://review, or re-open it with `#{FLAG}` if this " \
              "run means to judge regardless"
          end
        end

        # Admit anything. The designed escape for a run with nobody at a
        # keyboard: an unattended agent under the `deferred` gate cannot mark
        # hunks, so {EveryHunk} would wedge it, and the answer is to swap the
        # rule rather than weaken it for everyone. A real class rather than a
        # `->(...) {}` so a caller wiring it says the name out loud.
        #
        # IT HAS NO TYPED CONSTRUCTION SITE, and that is a property to keep.
        # Nothing a human can put on a `/survey` or `/review` line resolves here:
        # {FLAG} answers {BlockersOnly}, and this arrives only as an injected
        # `policy:`. The reason is REACHABILITY rather than these semantics --
        # forgiving everything is right for a run with nobody at a keyboard and
        # wrong for a word advertised in a `usage` string.
        class Permissive < Policy
          # Every argument is kept and named, and none is read: the port's shape
          # is what a reader needs from this file, and `(*, **)` would hide it.
          #
          # `annotations` is kept and unread like the rest, so a blocker is
          # admitted over. That is the escape working as designed: a run with
          # nobody at a keyboard cannot resolve a blocker any more than it can
          # mark a hunk, so a Permissive that started reading them would wedge
          # exactly the case it exists to unwedge.
          # @return [void]
          def admit!(verdict, changeset:, marks:, annotations:) = nil # rubocop:disable Lint/UnusedMethodArgument
        end
      end
    end
  end
end
