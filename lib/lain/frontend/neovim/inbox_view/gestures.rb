# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      class InboxView
        # A keypress turned into an open set, or into the sentence saying why
        # none opened. {InboxView} PROJECTS the record stream onto rows; this
        # RESOLVES a gesture against the rows it drew -- which rendering the
        # editor is holding, which set that line named in it, whether that set is
        # still pending, and whether it can be rebuilt at all.
        #
        # It holds {InboxView}'s own `@pending` Hash, live rather than copied:
        # the arrival that mutates it and the gesture that reads it are the
        # same object's state, and a snapshot here would answer from a listing
        # the human is no longer looking at.
        #
        # THREAD CONTRACT. Every method runs UNDER {InboxView}'s `@slot` --
        # that is what makes reading a Hash another thread mutates safe, and it
        # is the same invariant that lets {ListView} be lock-free. Nothing
        # here may park: `@questions.open` is the editor's NON-BLOCKING path
        # (the question rail in {RenderQueue::RAILS} refuses a full queue rather than waiting
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
          # Written to `spec/refusal_width_discipline_spec.rb`'s bar, which took
          # {UNSHOWN} from 194 rendered characters to this. Each keeps its
          # condition and its remedy and gives up the explanation between them.
          UNSHOWN = "#{NAME} re-rendered since %<generation>s -- press again on the row you want".freeze
          NO_SET = "no question set on #{NAME} line %d".freeze
          RETIRED = "#{NAME} line %d is not pending -- press again on a listed row".freeze
          UNREADABLE = "the question set on #{NAME} line %d cannot be read -- %s".freeze

          # A fifth: the set HAS been answered and is still listed, because a row
          # clears only when the agent's committed turn cites the answer -- a
          # whole model round trip later. Re-rendering it would hand the human a
          # fresh UNANSWERED document over the ticks they just made. The sentence
          # says CLEARS rather than warning about the blanking, because "wait" is
          # what the human has to do and the blanking is only why.
          ANSWERED = "#{NAME} line %d is answered -- it clears once the agent takes it".freeze

          # The two the ADVANCE answers with. No line number in either:
          # that gesture is not a cursor, it is "the human just submitted a set,
          # show them the next one", so the sentences name the surface instead.
          NOTHING_NEXT = "nothing further is pending -- #{NAME} lists no more question sets".freeze
          NEXT_UNREADABLE = "the next question set in #{NAME} cannot be read -- %s".freeze

          # @param pending [Hash{String=>Object}] {InboxView}'s live listing,
          #   digest => item, in the order the rows were rendered
          # @param answered [Set<String>] the listed sets a human has already
          #   answered -- {InboxView}'s too, and live for `pending`'s reason:
          #   it is emptied by the same retirement that clears the row
          # @param renderings [ListView] what this view has handed out
          # @param questions [#open] where a chosen set is opened for answering
          def initialize(pending:, answered:, renderings:, questions:)
            @pending = pending
            @answered = answered
            @renderings = renderings
            @questions = questions
          end

          # The `<CR>`/`r` gesture, once the buffer it came from is identified.
          #
          # KNOWN, OPEN, AND NOT WHAT THE STAMP CATCHES -- the stationary cursor.
          # The stamp answers "which rendering is this line a line OF", never "is
          # this still the set the human AIMED at". Cursor on item B; a consuming
          # turn retires A; the list re-renders under a cursor that did not move;
          # `<CR>` carries the CURRENT stamp, every check here passes, and
          # whichever set took those lines opens. Multi-line rendering WIDENED it
          # rather than creating it: a shifted cursor used to land on a line the
          # editor could tell was no row, where a four-line item makes the same
          # shift land inside another ANSWERABLE one.
          # {Frontend::Neovim::ApprovalView#decide} carries the full analysis;
          # what belongs here is that it applies to THIS gesture too.
          # @return [Opened]
          def open(line, generation)
            resolved = @renderings.at(line, generation:)
            return unopened(format(UNSHOWN, generation: generation.inspect)) if resolved.unshown?

            listed(resolved.owner, line)
          end

          # {#open}'s question asked for an ANSWER: the same checks against the
          # same rendering, answering WHICH SET the human aimed at rather than
          # opening a document for it, so an answer and an open can never
          # disagree about the row under one cursor.
          #
          # It stops before {#offer}, and that is the whole of the difference:
          # opening rebuilds the set into a fresh document, which is precisely
          # what an answer must not do to the words the human just typed.
          #
          # Each refusal it gives is one a bare digest cannot carry: told only a
          # nil digest, the directory reported every one of them to the human as
          # "the inbox line offering it is stale", about a LIVE row.
          # @return [Opened]
          def answering(line, generation)
            resolved = @renderings.at(line, generation:)
            return unopened(format(UNSHOWN, generation: generation.inspect)) if resolved.unshown?

            named(resolved.owner, line)
          end

          # The advance: the first listed set the human has NOT answered. A Hash
          # answers `find` in insertion order, which is the order the rows were
          # rendered in, so this needs no second walk to agree with the lines.
          #
          # It skips EVERY answered set, not the one most recently answered: a row
          # is retired by a committed turn citing it, a model round trip away.
          # Told only the last digest, the advance walked A -> B -> A -> B
          # forever, re-opening answered sets as blank documents and leaving C
          # unreachable -- silently, because a second answer to a resolved set is
          # dropped as {Promise::AlreadyResolved}.
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

          # {#listed}'s three refusals with the open left off -- the set an
          # answer names, or the sentence saying why that row cannot take one.
          # {UNREADABLE} has no counterpart here: nothing is rebuilt, so there
          # is no body to fail to read, and a set whose record this view cannot
          # parse is still one the ASKER can be handed prose for.
          def named(digest, line)
            return unopened(format(NO_SET, line)) if digest.nil?
            return unopened(format(RETIRED, line)) if @pending[digest].nil?
            return unopened(format(ANSWERED, line)) if @answered.include?(digest)

            Opened.new(digest:, report: "answering #{digest}")
          end

          # Shared by the gesture and the advance. {Question::Set.from_body}
          # reads only the keys it owns, so the same body that rendered the
          # one-line summary rebuilds exactly the set that was asked. A body that
          # is no set at all is REPORTED rather than raised: this answers a
          # keystroke, and a gesture that cannot be honoured owes the human a
          # sentence, not an exception on somebody else's thread. The WORDING is
          # the caller's -- one names a line, the other names the surface --
          # which is why it rides as a block.
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
