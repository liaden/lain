# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      class InboxView
        # A keypress turned into an open set, or into the sentence saying why
        # none opened. {InboxView} PROJECTS the record stream onto rows; this
        # RESOLVES a gesture against the rows it drew -- which rendering the
        # editor is holding, which set that line named in it, whether that set
        # is still pending, and whether it can be rebuilt at all. Four
        # questions, four different answers, and none of them is the
        # projection's business; the class carried both until `Metrics` said so.
        #
        # It holds {InboxView}'s own `@pending` Hash, live rather than copied:
        # the arrival that mutates it and the gesture that reads it are the
        # same object's state, and a snapshot here would answer from a listing
        # the human is no longer looking at.
        #
        # THREAD CONTRACT. Every method runs UNDER {InboxView}'s `@slot` --
        # that is what makes reading a Hash another thread mutates safe, and it
        # is the same invariant that lets {Renderings} be lock-free. Nothing
        # here may park: `@questions.open` is the editor's NON-BLOCKING path
        # ({RenderQueue#post_question} refuses a full queue rather than waiting
        # on it), and nothing on the far side of it calls back into the view.
        class Gestures
          # A listed record that is no question set at all -- a bare
          # `{"question" => ...}` from before sets existed. Its own error so the
          # rescue below can name the REBUILD and nothing else; see {#rebuilt}.
          class Unreadable < Lain::Error; end
          # Four ways a keypress names no openable set, and four sentences
          # because four different things happened: the buffer the human is
          # holding is not one this view can still identify; the line names no
          # set in it (the placeholder, or past the end); it names one that has
          # since been answered or withdrawn; or the record on it is no question
          # set at all.
          #
          # Written to `spec/refusal_width_discipline_spec.rb`'s bar, which is
          # what took {UNSHOWN} from 194 rendered characters to here. Each keeps
          # its condition and its remedy and gives up the explanation between
          # them; this comment is where that explanation now lives.
          UNSHOWN = "#{NAME} re-rendered since %<generation>s -- press again on the row you want".freeze
          NO_SET = "no question set on #{NAME} line %d".freeze
          RETIRED = "#{NAME} line %d is not pending -- press again on a listed row".freeze
          UNREADABLE = "the question set on #{NAME} line %d cannot be read -- %s".freeze

          # A fifth, and it is the row that is hardest to explain: the set on it
          # HAS been answered, and it is still listed because a row clears only
          # when the agent's committed turn cites the answer -- a whole model
          # round trip later. Re-rendering it would hand the human a fresh
          # UNANSWERED document over the ticks they just made, so the gesture is
          # refused and the sentence says which of the two states this is.
          # It says CLEARS rather than warning that reopening would blank the
          # document, because only one of those fits the rail and only one is an
          # instruction: "wait" is what the human has to do, and the blanking is
          # why -- which is what this comment is for.
          ANSWERED = "#{NAME} line %d is answered -- it clears once the agent takes it".freeze

          # The two the ADVANCE answers with (T16). No line number in either:
          # that gesture is not a cursor, it is "the human just submitted a set,
          # show them the next one", so the sentences name the surface instead.
          NOTHING_NEXT = "nothing further is pending -- #{NAME} lists no more question sets".freeze
          NEXT_UNREADABLE = "the next question set in #{NAME} cannot be read -- %s".freeze

          # @param pending [Hash{String=>Object}] {InboxView}'s live listing,
          #   digest => item, in the order the rows were rendered
          # @param answered [Set<String>] the listed sets a human has already
          #   answered -- {InboxView}'s too, and live for `pending`'s reason:
          #   it is emptied by the same retirement that clears the row
          # @param renderings [Renderings] what this view has handed out
          # @param questions [#open] where a chosen set is opened for answering
          def initialize(pending:, answered:, renderings:, questions:)
            @pending = pending
            @answered = answered
            @renderings = renderings
            @questions = questions
          end

          # The `<CR>`/`r` gesture, once the buffer it came from is identified.
          # @return [Opened]
          def open(line, generation)
            return unopened(format(UNSHOWN, generation: generation.inspect)) unless
              @renderings.holds?(generation)

            listed(@renderings.digest_at(line, generation), line)
          end

          # The advance: the first listed set the human has NOT answered. A Hash
          # answers `find` in insertion order, which is the order the rows were
          # rendered in, so "the one the inbox lists first" needs no second walk
          # to agree with the lines.
          #
          # It skips EVERY answered set, not the one most recently answered, and
          # that is the whole of the difference: a row is retired by a committed
          # turn citing it, which is a model round trip away and, for a set
          # another agent asked, does not land until THAT agent commits. Told
          # only the last digest, the advance walked A -> B -> A -> B forever,
          # re-opening answered sets as blank documents and leaving C
          # unreachable -- silently, because a second answer to a resolved set
          # is dropped as {Promise::AlreadyResolved}.
          # @return [Opened]
          def open_next
            digest, item = @pending.find { |listed_digest, _| !@answered.include?(listed_digest) }
            return unopened(NOTHING_NEXT) if digest.nil?

            offer(digest, item) { |why| format(NEXT_UNREADABLE, why) }
          end

          private

          # One listed set, opened -- or the reason a digest the rendering named
          # is not one this view can still open.
          def listed(digest, line)
            return unopened(format(NO_SET, line)) if digest.nil?

            item = @pending[digest]
            return unopened(format(RETIRED, line)) if item.nil?
            return unopened(format(ANSWERED, line)) if @answered.include?(digest)

            offer(digest, item) { |why| format(UNREADABLE, line, why) }
          end

          # The open itself, shared by the gesture and the advance. The rebuild
          # is {Question::Set.from_body}, which reads only the keys it owns, so
          # the same body that rendered the one-line summary rebuilds exactly
          # the set that was asked. A body that is no set at all (a bare
          # `{"question" => ...}` from before sets existed) is REPORTED rather
          # than raised: this answers a keystroke, and a gesture that cannot be
          # honoured owes the human a sentence, not an exception on somebody
          # else's thread. The WORDING of that sentence is the caller's -- one
          # names a line, the other names the surface -- which is why it rides
          # as a block.
          def offer(digest, item)
            refusal = @questions.open(rebuilt(item), digest)
            refusal.nil? ? Opened.new(digest:, report: "opened #{digest}") : unopened(refusal)
          rescue Unreadable => e
            unopened(yield(e.message))
          end

          # The rescue is the REBUILD's alone, and it has to be: {QuestionView}
          # raises ArgumentError deliberately and loudly on a blank digest (a
          # caller bug, not a bad record), and a rescue spanning the open would
          # report that to the human as "this set cannot be read".
          def rebuilt(item)
            Question::Set.from_body(item.body)
          rescue ArgumentError => e
            raise Unreadable, e.message
          end

          def unopened(report) = Opened.new(digest: nil, report:)
        end
      end
    end
  end
end
