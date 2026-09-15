# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The human-reply surfaces: the arrival note, the `/inbox` drain, and the
    # editor's :LainReply leg.
    #
    # Every answer NAMES the set it answers. This class holds the run's
    # {Tools::AskHuman::Directory}, not one asker, and routes by the digest the
    # arrival carried -- answering from "the asker this class happens to hold"
    # is how a child's question becomes unanswerable while the parent has
    # nothing pending. The digest is also what RETIRES the item, since the item
    # an answer belongs to need not be the one at the head of the list.
    class HumanReplies
      # One pending human question as the drain surface lists it: who is stuck,
      # since when, the question, and the name an answer must cite to reach it.
      InboxItem = Struct.new(:question, :from, :digest, :asked_at, keyword_init: true) do
        # Built from the Q event that has just been written, the only moment
        # BOTH attributions are true -- read at drain time instead, `from` is
        # whoever asked most recently and the digest is not recoverable at all.
        #
        # The asker's name wins over the event's own `from`, which is the
        # chain's ROOT digest: an `:inherit` child forks its parent, so the two
        # share a root and are indistinguishable at every surface that renders
        # the sender. `:inherit` is the DEFAULT for a role spawn, so that is the
        # common case rather than an edge one.
        def self.asked(question, event, agent: nil)
          named = Blankness.blank?(agent) ? event.from : agent
          new(question:, from: named, digest: event.digest, asked_at: Time.now)
        end
      end

      # No item to answer: an editor reply that named nothing, with nothing
      # listed to mean. It answers with a name no registered asker can hold, so
      # the refusal comes back from the directory in the words a human at a
      # reply prompt needs, rather than from a nil check here.
      module Unlisted
        def self.digest = nil
      end

      # How long the editor consumer parks between empty polls. The rail is a
      # Thread::Queue popped non-blockingly, since a blocking pop would freeze
      # the reactor thread, so the tick is what keeps the fiber cheap. Paid for
      # the whole conversation rather than one ask ({#session_surfaces}), which
      # is the price of answering a gesture made at `you>`: a 10Hz `pop(true)`
      # against an in-process queue, where the only alternative parks the RPC
      # thread.
      IDLE_TICK = 0.1

      # What `:LainGoalOff` says, in the chat pane when it stopped a goal and in
      # the editor when there was none.
      GOAL_STOPPED = "goal off from the editor -- the driver stopped before its next iteration"
      NO_GOAL = ":LainGoalOff stops a standing goal, and none is driving"

      # The editor that is not there ({Sink::Null}'s shape), so neither the
      # consumer loop nor the refusal path asks whether one was bound.
      # `attached?` is the one distinction still worth drawing: a fiber polling
      # a rail nothing can reach is pure cost, so it is never spawned.
      module NoEditor
        def self.pop(*) = nil
        def self.review_refused(_message) = nil
        def self.attached? = false
      end

      # The views nobody wired ({NoEditor}'s other half): no inbox rendering to
      # resolve a line against, no timeline to pin a turn in. Every gesture
      # answers {Nothing}, and the sentence it hands back goes to {NoEditor},
      # which renders it nowhere -- so there is no nil to check on either side.
      module NoViews
        # Nothing happened, and here is why: the shape both
        # {Frontend::Neovim::InboxView::Opened} and
        # {Frontend::Neovim::Buffers::TimelineView::Pin} answer, since the two
        # gestures share one refusal path here.
        module Nothing
          def self.opened? = false
          def self.pinned? = false
          def self.report = "no editor is attached, so there is nothing to open or pin"
        end

        # `**` rather than the named keyword: a keyword is its own name, so no
        # underscore spelling both matches the caller and reads as unused.
        def self.open(_line, **) = Nothing
        def self.open_next = Nothing
        def self.pin(_line) = Nothing
        def self.answered(_digest) = nil

        # No rendering was ever handed out, so no line names a set in one.
        def self.answering(_line, **) = Nothing
      end

      # The changeset review nobody wired: a third object because it is a third
      # fact -- the rail, the views and the review are bound at three different
      # moments by three different callers, and a run can easily have the first
      # two and not the last.
      module NoReview
        # {NoViews::Nothing}'s shape, kept APART rather than shared: the two say
        # different things, and a human who has an editor open and no review
        # would otherwise be told the editor is missing.
        module Nothing
          def self.opened? = false
          def self.marked? = false
          def self.asked? = false
          def self.report = "no changeset review is open, so there is nothing to open, mark or ask about"
        end

        # `**` rather than the named keyword, for {NoViews.open}'s reason.
        def self.open(_line, **) = Nothing
        def self.mark(_line, _state, **) = Nothing
        def self.ask(_anchor_id, _question) = Nothing
      end

      # `ask_human:` is whatever answers `#reply(answer, digest)` for the set a
      # digest names: the run's {Tools::AskHuman::Directory} in production, a
      # lone {Tools::AskHuman} for a single-asker caller. Which object it is has
      # stopped mattering here, which is the point -- this class no longer knows
      # WHICH agent is stuck.
      #
      # `goal:` is the chat's standing-goal driver, which the editor can stop.
      def initialize(tty:, conductor:, ask_human:, questions:, goal: GoalDriver::Null)
        @tty = tty
        @conductor = conductor
        @goal = goal
        @ask_human = ask_human
        @questions = questions
        # "Nothing is bound yet" stated as the bind it is, rather than as a
        # second copy of which Null each surface holds -- the copy that drifted
        # when a fourth arrived, which is what the approval list's did.
        bind_editor(nil)
        @changeset_review = NoReview
        @reviews = Reviews.new
        @inbox = Pending.new
        @reads = OpenReads.new
        @queued = questions ? Queued.new(questions) : Queued::NOTHING
        @reply = Reply.new(tty:, conductor:, inbox: @inbox)
        # READERS, never the surfaces: every one is bound after this returns, so
        # resolving each per call is what makes a late bind visible without
        # anybody remembering to rebuild.
        @gestures = Gestures.new(editor: -> { @editor }, views: -> { @views }, review: -> { @changeset_review },
                                 approvals: -> { @approvals })
      end

      # The editor's command rail, bound before converse runs so
      # #editor_reply_loop knows whether to spawn its consumer fiber. These are
      # the ONLY nil checks in this class, and they live here so no other line
      # has to repeat them.
      #
      # The views and the approval list are bound BESIDE the rail, never at a
      # second call site: a gesture arrives on the rail, resolves through a
      # rendering, and its refusal goes back out on the rail -- one
      # conversation, where two binds are two chances to hold different objects.
      # For an approval that is a wrong-call verdict rather than an error.
      def bind_editor(editor, views: nil, approvals: nil)
        @editor = editor || NoEditor
        @views = views || NoViews
        @approvals = approvals || NoApprovals
      end

      # The `you>` command registry, so a registered `/word` typed at `human> `
      # RUNS instead of being recorded as the answer to the parked set. A bare
      # `/inbox` literal stood here once, which made `/status` at a reply prompt
      # send the model the text "/status" and show the human nothing.
      #
      # BOUND rather than taken as a keyword, because the registry is built FROM
      # this object: {Wiring#build_repl} constructs this class first and hands it
      # to {Command::Surface}, so no constructor ordering could take one.
      def bind_commands(commands) = @reply.bind_commands(commands)

      # The editor a changeset is DRAWN in, and the second rail a review's
      # writes are answered on. The whole frontend rather than a piece of it,
      # because a review drawn in one editor and answered in another is not a
      # review.
      #
      # @param editor [Frontend::Neovim, nil] nil is the editor that is not
      #   there, so a headless chat binds like any other -- see {#review_editor},
      #   which is where that nil becomes {ReviewSeams::Unattached}
      def bind_review_editor(editor) = @review_editor = editor

      # Where a changeset is drawn, and the rendering its gestures resolve
      # through -- threaded into {Tools::RequestReview} as thunks, because the
      # tool is built before this is bound.
      delegate :review_surface, :review_view, to: :review_editor

      # Hold a review open for the editor's `done` gesture to settle -- see
      # {Reviews#bind}, which is where the keying rule lives.
      def bind_review(review, token:) = @reviews.bind(review, token:)

      # Hold the CHANGESET review the editor is reading, so its gestures resolve
      # against the rendering that produced the line they name. Deliberately not
      # {#bind_review}, which holds an EPIC's prose review keyed by slug and
      # generation: the two ride the same rail and share nothing else, and
      # folding them would have one object answering `settle` and `mark` for two
      # unrelated notions of "review".
      #
      # ONE BIND, BOTH RAILS. Acked gestures resolve here; the two WRITES are
      # answered by the editor on its own RPC thread through
      # {Frontend::Neovim#bind_changeset_review}, which had no caller in the
      # whole tree -- notes and verdicts reached
      # {Frontend::Neovim::NoReviewWrites} and were refused. Forwarded from here
      # rather than bound again by the tool, which cannot reach a frontend, and
      # because two binds are two chances to hold different reviews.
      def bind_changeset_review(review)
        review_editor.bind_changeset_review(review)
        @changeset_review = review || NoReview
      end

      # A human question is waiting: an item mid-drain, or one a subagent
      # enqueued while the human sat idle at `you>` with no answer_loop fiber
      # watching. The standing-goal driver reads this to hold off re-prompting
      # while the fleet is unquiet.
      def pending? = !@inbox.empty? || !@questions.empty?

      # `/inbox` at `you>`: the same TTY drain the `human>` path uses, over
      # whatever piled up since a fiber was last watching. {#surfaces}' fiber
      # lives for one DISPATCHED LINE, while the supervisor's fleet outlives
      # every one of them, so a subagent can enqueue a question while the human
      # sits idle at `you>` with nothing draining it. This is that second
      # watcher, run on demand rather than as another background fiber.
      #
      # It is therefore the one command that must NOT be bracketed in a reply
      # loop of its own -- {Command::Inbox} declares that and
      # {Repl::LineScope#serve} reads the declaration. Two readers on one stdin
      # is what this method exists to avoid, not a state it may run in.
      #
      # The listing offers no selection, so one typed answer answers the OLDEST
      # item listed: nothing is parked on this read, so the first line the human
      # read is the only thing it can mean. {Reply} hands that item back beside
      # the answer, so the set answered, the document printed and the line
      # retired are one question rather than three lookups that can disagree.
      #
      # A blank answer must resolve NOTHING and retire NOTHING, or the item
      # leaves the human's only view of a still-pending question.
      #
      # EOF ends this read as a blank line does, and for the same reason:
      # NOTHING IS PARKED ON IT. The inline prompt refuses a set on EOF because
      # a run is parked on it and the only read that could answer has ended --
      # the reason this prompt does not have. Refusing `@inbox.oldest` here
      # destroyed a question permanently, tombstoned in the directory so a later
      # real answer raised; with N listed it gave exactly one an unanswered
      # record and N-1 nothing, which is one doctrine applied to an arbitrary
      # question.
      #
      # @return [String] the answer as it will be delivered -- for a question
      #   carrying a set that is the answer set's rendering, not the line the
      #   human typed -- or "" (nothing pending, they typed nothing, or the
      #   stream ended under a read nothing was waiting on)
      def drain_at_prompt
        @inbox.gather(@questions)
        answer, answered = @reply.at_prompt
        resolve_reply(answer, answered.digest) unless answer.strip.empty?
        answer
      end

      # The TTY drain loop, whose fiber must live exactly as long as one
      # DISPATCHED LINE and no longer: the reply read parks inside it, and the
      # terminal it reads from is the one the next `you>` prompt needs back.
      # {Repl::LineScope#serve} stops it in its ensure.
      #
      # The LINE and not the ask, because a question can be raised from a
      # command running lib-side or from a spawned subagent, and neither reaches
      # {Repl#respond} -- the fiber that parks on one is the dispatching fiber,
      # so the surface answering it has to be its sibling. The editor's consumer
      # is deliberately not here; see {#session_surfaces}.
      #
      # WITH AN EDITOR ATTACHED nothing here reads an answer: lain://inbox and
      # lain://approval are where a cockpit's human answers, and a `human>` in
      # the chat pane beside them is a reader that typeahead lands in. The line
      # gets {CommandLine} instead, which announces and reads only commands --
      # kept because a line parked on its own call never settles, so without it
      # `/approve` could not be typed at all until nvim was used.
      #
      # @param task [Async::Task] the line's task, which the surface is spawned on
      # @param attention [Repl::LineScope::Attention] raised by an arrival on
      #   either surface, and what opens the cockpit's command read
      def surfaces(task, attention: Repl::LineScope::Attention.new)
        [@editor.attached? ? command_line.spawn(task, attention) : answers.spawn(task)]
      end

      # A line the human typed in the chat that was neither a command nor an
      # answer, waiting to be dispatched at `you>`. The input rail holds it
      # ({Frontend::InputRail#hold}), through the conductor that reads from it,
      # because a line typed ahead of an answer's prompt is held there too, and
      # ONE queue is what keeps the lines in the order they were typed.
      def hold(line) = @conductor.hold(line)

      # The oldest held line, or nil when nothing is held. {Repl#next_text}
      # asks this before it reads, so a held line is dispatched first and in
      # the order it was typed.
      def take_held = @conductor.take_held

      # The reply surfaces that live for the whole CONVERSATION, started on the
      # repl's own Sync rather than on an ask's -- today just the editor's
      # command rail.
      #
      # An ask's lifetime is the WRONG one for that rail. A human uses the
      # editor precisely when no ask is in flight: a code review is a long
      # stretch of reading and marking with no model turns in it, and the
      # sidebar cannot redraw a mark as a glyph, so the sentence coming back on
      # this rail is the only signal a gesture landed. Started per-ask, it was
      # measured (2026-08-05) answering nothing for 8s at an idle `you>` and
      # then flushing the whole backlog the moment a message was sent.
      #
      # The two loops share no queue -- this one polls the editor's rail, the
      # ask's parks on `@questions` -- so the longer lifetime cannot make them
      # race. Where they meet is {#deliver}, already the one answer path both
      # use, which drops the loser's duplicate as `AlreadyResolved`.
      #
      # The caller stops these in ITS ensure on every path, because a parked
      # fiber holds the Sync that owns it open forever.
      def session_surfaces(task) = [editor_reply_loop(task)].compact

      private

      # Built at the one call site that needs it, so a session that never spawns
      # a reply surface never builds one. Memoized because it REMEMBERS which
      # arrivals it has announced, and that memory must span the lines it is
      # spawned for rather than one of them.
      #
      # `resolve:` is a MESSAGE rather than this object: the loop owes an answer
      # one call, and handing over `self` would let it reach everything.
      def answers
        @answers ||= AnswerLoop.new(questions: @questions, inbox: @inbox, tty: @tty, reply: @reply,
                                    resolve: method(:resolve_reply), reads: @reads)
      end

      # {#answers}' cockpit counterpart. `drain:` is `/inbox`, which a cockpit
      # still answers from the chat when the human asks it to; `notice:` is the
      # frontend's one-line note, reached as {Wiring} reaches it for the run's
      # line to the human.
      def command_line
        @command_line ||= CommandLine.new(questions: @questions, inbox: @inbox, tty: @tty, reply: @reply,
                                          notice: @tty.method(:render_warning), conductor: @conductor,
                                          hold: method(:hold), drain: method(:drain_at_prompt))
      end

      # The null resolved HERE and nowhere else, which is why
      # {#bind_review_editor} may take a bare nil. Private because a reader
      # beside a binder is a second way to ask the same question; `delegate`
      # still reaches it, calling with an implicit receiver.
      def review_editor = @review_editor || ReviewSeams::Unattached

      # The refusal is rendered where the human typed, and passed through rather
      # than reworded: a digest no asker holds is a stale line, and the
      # directory's own sentence says so.
      #
      # A refusal SETTLES the line, and that half is load-bearing on the
      # `/inbox` path, which calls this directly rather than through
      # {AnswerLoop} -- nothing else would ever retire the item. Rendering and
      # returning left the dead question listed, so every later `/inbox` offered
      # it again: a line that lists forever and can only refuse.
      # `NoPendingQuestion` means the set is gone, so nothing is lost.
      #
      # THE SETTLE IS THE DIGEST'S, and a refusal that named none settles
      # nothing: telling the views a nil was answered puts a nil in the answered
      # set, while `retire(nil)` deletes whatever item is listed without a
      # digest.
      def resolve_reply(answer, digest)
        deliver(answer, digest)
      rescue Lain::Tools::AskHuman::NoPendingQuestion => e
        @tty.render_error(e.message)
        settled(digest) unless digest.nil?
      end

      # The ONE answer path both surfaces use. `AlreadyResolved` means the other
      # surface beat this one, which is normal, so the duplicate is dropped and
      # the item retired all the same -- the set it named IS answered.
      #
      # The `human>` reads and queued arrivals this answer retires are the ones
      # there BEFORE it is handed on. Handing it on can re-open the same set
      # under the same digest -- a reply too long for the record is handed back
      # -- and a read or an arrival for THAT is waiting on an answer nobody gave.
      def deliver(answer, digest)
        open = @reads.on(digest)
        queued = @queued.on(digest)
        handed_on(answer, digest)
        settled(digest, open, queued)
      end

      def handed_on(answer, digest)
        @ask_human.reply(answer, digest)
      rescue Lain::Promise::AlreadyResolved
        nil
      end

      # What "this set is DONE" means to everything that lists it, in ONE place
      # because every way of being done ends the same for a reader. Named for
      # settled rather than answered because a third of its callers is a
      # refusal. Reported rather than inferred: a row is retired by the agent's
      # committed turn a model round trip later, so until then only this knows.
      #
      # A `human>` still open for the set is stopped with it, and an arrival
      # re-queued when an earlier line ended is taken off the queue: either one
      # left drew `human>` again under every later line until somebody typed
      # into it and was refused. A refusal has handed nothing on, so what is
      # there now is what it retires.
      def settled(digest, reads = @reads.on(digest), queued = @queued.on(digest))
        @views.answered(digest)
        @inbox.retire(digest)
        @queued.withdraw(queued)
        reads.each(&:settle)
      end

      # The :LainReply command lands on the frontend's rail and this fiber
      # resolves the pending ask from it. ONE per conversation, never one per
      # ask: it is the sole consumer of every editor verb, so a second would
      # race it for the rail and each gesture would land on whichever popped
      # first.
      def editor_reply_loop(task)
        task.async { loop { serve_editor_command } } if @editor.attached?
      end

      # ONE editor command, and its own method because NOTHING a command does
      # may kill this fiber: it is the sole consumer of EVERY editor verb, so a
      # `review_done` that raises would take :LainReply down with it and the
      # editor would go quiet with no sign why. The refusal renders back in the
      # editor the gesture came from.
      #
      # There is no `pending?` pre-guard, and its absence is the fix: it asked
      # the object this class holds whether IT had something pending, which
      # under digest-addressed routing is not the question. "Is this digest
      # answerable" is the directory's to answer, so a child's question stays
      # answerable from the editor while the parent holds nothing, and a race
      # the TTY already won comes back as AlreadyResolved for {#deliver} to drop.
      #
      # `ScriptError` beside `StandardError` because `NotImplementedError` is
      # NOT a StandardError and is the likeliest one to arrive -- an abstract
      # duck raises exactly that, and it walked past the guard whose whole
      # paragraph says nothing may kill this fiber. `Exception` is still
      # refused, so `Interrupt` and `Async::Stop` keep climbing.
      def serve_editor_command
        verb, args = pop_command
        verb.nil? ? sleep(IDLE_TICK) : routes[verb]&.call(args)
      rescue Lain::Promise::AlreadyResolved
        nil
      rescue StandardError, ScriptError => e
        report(e.message)
      end

      # The REFUSAL'S own failure, which had nowhere to go and so went
      # everywhere: it reaches the editor -- the thing that just proved it can
      # fail -- and a raise here escaped every guard and ended :LainReply
      # permanently. Swallowed rather than re-reported, because an editor that
      # cannot take a refusal cannot take the refusal about the refusal.
      def report(message)
        @editor.review_refused(message)
      rescue StandardError, ScriptError
        nil
      end

      # One verb, one reaction, and its `&.` because the editor's commands are
      # not this object's to validate -- a verb no route claims falls through in
      # silence, having ridden its own path to the frontend.
      #
      # Two tables, and the split is a real seam rather than size: what stays
      # here SUBMITS -- an answer, a written document, a settled review -- each
      # of which reaches the Store or a promise and can raise, which is what
      # {#serve_editor_command} rescues. What moved to {Gestures} names a
      # position and submits nothing.
      def routes
        @routes ||= {
          "reply" => ->(args) { reply(args) },
          "question_answered" => ->(args) { answer_document(args) },
          "review_done" => ->(args) { @reviews.settle(args) },
          "goal_off" => ->(_args) { goal_off }
        }.merge(@gestures.routes).freeze
      end

      # `:LainGoalOff`. The drive shows in the chat pane, so that is where its
      # stop is said; with nothing driving, the editor is told instead, where
      # the command was typed.
      def goal_off
        return report(NO_GOAL) unless @goal.active?

        @goal.stop
        @tty.method(:render_warning).call(GOAL_STOPPED)
      end

      # The wire's `["reply", [answer, line, generation]]`. The ROW rides beside
      # the answer for {Gestures#open_set}'s reason -- an inbox row renders no
      # digest, so a line plus the stamp on the rendering the human is looking
      # at is what names a set -- and it resolves through the very same index,
      # so "which set is this an answer to" and "which set is this an open of"
      # cannot disagree.
      #
      # Sending the answer alone made the consumer guess the oldest item listed.
      # That guess is a set only while one is pending AND reached {Pending} at
      # all, and a question raised from the editor while the human sits at
      # `you>` never does -- so the guess was nil and the human was told the row
      # in front of them was stale.
      #
      # A reply that named NO row keeps the oldest-listed reading, which is not
      # a leftover: :Lain* commands are GLOBAL, so :LainReply is typable from
      # any buffer and a cursor outside lain://inbox names no row. Inside
      # lain://inbox the editor sends no row only when it has told the human
      # why, so the two nils cannot be confused.
      def reply(args)
        answer, line, generation = args
        return deliver(answer.to_s, @inbox.oldest.digest) if line.nil?

        replied(answer.to_s, @views.answering(line, generation:))
      end

      # Delivered when the row names a set, and otherwise the view's OWN
      # sentence about why it does not. Those sentences used to arrive as a nil
      # digest and be explained by {Tools::AskHuman::Directory}, which knows
      # only that no asker holds the name -- so a rendering that had merely aged
      # out was reported as permanently stale, about a row whose asker was still
      # parked on it.
      def replied(answer, row)
        row.opened? ? deliver(answer, row.digest) : report(row.report)
      end

      # The wire's `["question_answered", [digest, answer_set]]`. The digest is
      # the buffer's own stamp, so this answer names its set rather than
      # inheriting whatever the inbox lists first.
      def answer_document(args)
        digest, answers = args
        deliver(answers.render, digest)
        advance
      end

      # One document submitted, so open the next set the human owes an answer to.
      #
      # IT CANNOT HAPPEN ANYWHERE ELSE. {Frontend::Neovim::QuestionView} holds a
      # non-reentrant Mutex across the write and calls its `submit` INSIDE it,
      # so a chain from the submit callable re-enters that lock and raises
      # `ThreadError: deadlock; recursive locking` on the human's `:w`, with the
      # answer already handed on. This runs after the write returned and the
      # lock is gone, which is the whole reason the hand-off is a queue somebody
      # else pops.
      #
      # It needs no argument, because {#deliver} has already told the views
      # which sets were answered. Its outcome is deliberately NOT echoed: the
      # human asked for no particular set, and a set it could not open keeps its
      # row, so pressing enter on that row is what asks for a sentence.
      def advance = @views.open_next

      def pop_command
        @editor.pop(true)
      rescue ThreadError
        nil
      end
    end

    class HumanReplies
      # Reopened rather than nested above, `tty.rb`'s idiom: each collaborator
      # is its own responsibility, and the split keeps each body inside
      # Metrics/ClassLength instead of loosening it.

      # The TTY arrival surface: ONE fiber parked on the queue, serving each
      # arrival from its note to its answer -- and deciding what becomes of the
      # LINE when that exchange ends. Where {HumanReplies} routes an ANSWER to
      # the asker that asked, this owns an ITEM's lifetime: from the queue to
      # the list and, when nobody answered, back.
      #
      # `resolve:` is a message rather than the owner, which would let this
      # reach everything else.
      class AnswerLoop
        # Ends the line of a `human>` stopped because its set was answered on
        # another surface, so the next thing printed does not land beside it.
        ANSWERED_ELSEWHERE = "(human> closed -- answered elsewhere)"

        # `reads:` is where each `human>` is raced against its set being settled
        # by another surface.
        def initialize(questions:, inbox:, tty:, reply:, resolve:, reads:)
          @questions = questions
          @inbox = inbox
          @tty = tty
          @reply = reply
          @resolve = resolve
          @reads = reads
          @announced = Set.new
        end

        # Parks on dequeue -- a real scheduler yield, woken per arrival rather
        # than polling.
        def spawn(task) = task.async { loop { serve(@questions.dequeue) } }

        private

        # An item leaves the queue it came off and the list it was pushed onto
        # only when the EXCHANGE ended -- either the answer reached the reply
        # seam (or was refused there), or something raised and the human was
        # TOLD. Either way the line is dead and retiring it is right.
        #
        # An UNWIND is not on that list. `Async::Stop` climbing out of a
        # cancelled read is the SURFACE being stopped, not the question being
        # answered -- and the surface is stopped at the end of every dispatched
        # LINE. So a subagent's question arriving while the human ran `/help`
        # was dequeued, announced to a human who was not looking, then retired
        # when the line ended: off the queue and off the list at once, so
        # `HumanReplies#pending?` read false, no `/inbox` could list it, and the
        # asker stayed parked forever with no error and no journal line. It goes
        # back on the queue instead.
        #
        # A set WITHDRAWN under a parked reader is re-queued too, which is the
        # priced cost of the rule. The REPLY SEAM does not expose the
        # distinction, though somebody holds it: `Registration#holds?` answers
        # whether the NAME is registered, which stays true across a withdrawal
        # -- measured true both before and after `AskHuman#perform`'s unwind,
        # because `Outstanding#abandon` clears the asker and never touches the
        # registration's map.
        #
        # It is the right default even with that query in hand, because the two
        # mistakes are not symmetric: re-queueing a dead set costs one refusal
        # the human is told about, where retiring a live one parks the asker
        # forever with `#pending?` false and nothing able to reach it.
        #
        # A set ANSWERED on another surface while its read is open is the one
        # dead set this loop does know about: {HumanReplies#settled} stops that
        # read, and the exchange ends settled. Re-queued, it came back as a
        # `human>` under every later line, since no human types into a prompt
        # for a question they have already answered.
        def serve(item)
          settled = exchange(item)
        ensure
          settled ? @inbox.retire(item.digest) : requeue(item)
        end

        # One arrival, from the note to the answer, answering whether the item is
        # SETTLED. It answers THIS item -- the one whose note the human is
        # looking at -- never whichever is at the head of the list. Both exits
        # it has of its own are settled; the third, an unwind, does not return
        # at all and so cannot say so, which is what {#serve}'s ensure reads.
        #
        # EOF is the one thing that is not an answer. It arrives at the same
        # read as a blank line and was once collapsed into one, but a human
        # pressing Enter is a decision where a stream ending is nobody left to
        # make one: the second resolves the set as unanswerable, and no record
        # claims a human spoke.
        #
        # A blank line here IS an answer, deliberately unlike the same keystroke
        # at `you>`: a run is PARKED on this set, so declining still has to
        # reach the model, and `""` carries that where `Tool::Result.ok(nil)`
        # would raise. The `/inbox` detour inside the read does not move the
        # human to the other prompt, so Enter still answers this set.
        #
        # NOTHING here may kill this fiber. It is ONE fiber for the whole run,
        # its read reaches Reline and a real terminal, and its delivery reaches
        # the Store and the journal -- either raising un-guarded ended the loop
        # permanently and silently, with arrivals still landing on the queue and
        # a human watching a run that stopped asking. `StandardError`, so an
        # `Async::Stop` out of a cancelled read keeps climbing.
        #
        # A REFUSED answer never reaches that rescue: {Reply} refuses and
        # re-reads. Retiring on a refusal parked the agent forever AND deleted
        # the only line that could unpark it.
        def exchange(item)
          @inbox << item
          announce(item)
          heard = @reads.race(item.digest) { @reply.for(item) }
          heard.equal?(OpenReads::SETTLED) ? closed_elsewhere : resolved(*heard)
          true
        rescue StandardError => e
          @tty.render_error(e.message)
          true
        end

        def resolved(answer, answered) = @resolve.call(answer, answered.digest)

        # Private on the terminal, reached as {HumanReplies#command_line} reaches
        # it: the frontend's one-line note.
        def closed_elsewhere = @tty.method(:render_warning).call(ANSWERED_ELSEWHERE)

        # An ARRIVAL is announced ONCE, however many lines the question
        # outlives. A re-queued item is dequeued again by the next line's loop,
        # and "this just arrived" is false by the third line -- noise the human
        # cannot act on either, since the read it precedes is torn down before
        # they could type into it. The read still opens on every serve, so a
        # line they linger on is answerable; only the arrival claim is spent.
        #
        # Keyed on the ARRIVAL rather than on the set, and that distinction is
        # load-bearing now that ONE set can arrive twice: a reply handed back
        # for being too long carries the digest of the set already announced --
        # deliberately, so one question keeps one inbox row -- but it is a new
        # thing to tell the human, their own words measured and what to type.
        # Keyed on the digest alone it was suppressed, so somebody who typed 65
        # KB got a bare prompt back with nothing to say anything had happened.
        #
        # The stamp is what tells an arrival from a re-queue: `InboxItem.asked`
        # takes it once, at the instant that arrival was built, and a re-queue
        # carries the same item and so the same stamp. The pair holds no
        # question bytes, which the item itself would -- and a handback's bytes
        # are the whole oversized reply, held for the life of the session.
        def announce(item)
          @tty.render_arrival(item.question, from: item.from) if @announced.add?([item.digest, item.asked_at])
        end

        # Back where a later surface can reach it. Off the list FIRST, because
        # the queue is where it lives again and a copy in both would be listed
        # twice the moment anything gathered. Deliberately NOT reached after a
        # raise -- this loop would dequeue the item at once and fail the same
        # way, which is a hot loop rendering one error forever.
        def requeue(item)
          @inbox.retire(item.digest)
          @questions.enqueue(item)
        end
      end

      # A cockpit's chat for one DISPATCHED LINE: every question arrival
      # announced as one line and listed, and a read that runs only commands.
      #
      # AN ARRIVAL IS LISTED, NEVER SERVED. It goes onto the pending list and
      # stays there until some surface settles it, so `/inbox`, lain://inbox and
      # `#pending?` all see it -- and nothing re-queues it, because nothing here
      # took it off a list a human reads. That is what keeps a question answered
      # in nvim from being re-announced under every later line.
      #
      # THE READ IS OPEN WHILE SOMETHING IS OUTSTANDING, and only then: a
      # prompt drawn under every dispatched line is the ghost a cockpit is rid
      # of, and an open read holds the terminal -- {Conductor#read_reply}
      # suppresses the interrupt countdown for its span. So it opens when the
      # line's {Repl::LineScope::Attention} reports a parked call or a listed
      # question, from this line or an earlier one, and it is closed when
      # nothing is, when the line ends, or when the stream does. A registered
      # command runs where it was typed, owning the terminal for as long as it
      # reads; `/inbox` drains; anything else -- prose, or a `/word` no command
      # claims, which may be a skill -- is HELD for `you>` and said to be, since
      # a line nobody was told about reads as swallowed.
      class CommandLine
        PROMPT = "command> "

        # Said when a read is closed under its prompt, which also ends the row
        # that prompt was drawn on -- otherwise the next `you>` lands beside it.
        CLOSED = "(command> closed)"

        # The stream ended: no further read opens in this line.
        ENDED = Object.new.freeze

        # How often a closed reader asks whether to open, and an open one
        # whether its reason is gone -- {Repl::ApprovalSurfaces::Arrivals}' tick.
        TICK = 0.05

        # `conductor:` answers whether a Ctrl-C's grace countdown is running,
        # which this read must never sit under.
        def initialize(questions:, inbox:, tty:, reply:, notice:, conductor:, hold:, drain:)
          @questions = questions
          @inbox = inbox
          @tty = tty
          @reply = reply
          @notice = notice
          @conductor = conductor
          @hold = hold
          @drain = drain
        end

        # The reader is the noting fiber's CHILD, so stopping the one fiber
        # {#spawn} hands back stops both, and a line still starts one surface
        # here whichever kind of chat it is.
        def spawn(task, attention)
          attention.track { !@inbox.empty? }
          task.async do |noting|
            noting.async { read_while_outstanding(attention) }
            loop { noted(@questions.dequeue) }
          end
        end

        private

        # Listed before anything that can yield, so an unwind between the
        # dequeue and the note cannot drop the item from both places at once.
        # A note that failed to render is reported rather than allowed to end
        # the fiber every later arrival is noted on; the question is listed and
        # outstanding whether or not it was said.
        def noted(item)
          @inbox << item
          @tty.render_arrival(item.question, from: item.from)
        rescue StandardError => e
          @tty.render_error(e.message)
        end

        # Each read answers a line, nil for a read closed with nothing typed,
        # or {ENDED}.
        def read_while_outstanding(attention)
          reads = Enumerator.produce { read_once(attention) }.lazy
          reads.take_while { |read| !read.equal?(ENDED) }.compact.each { |line| served(line) }
        end

        # The read runs in a child so it can be RACED against its reason: a
        # read with nothing left to wait for is stopped, and the ensure is what
        # closes it on every other way out, the line's own stop included.
        def read_once(attention)
          park_until { wanted?(attention) }
          reading = Async::Task.current.async { heard }
          park_until { reading.finished? || !wanted?(attention) }
          reading.finished? ? reading.wait : nil
        ensure
          close(reading)
        end

        # Something is waiting on the human, and no interrupt countdown is. A
        # read open under the countdown suppresses it ({Conductor#read_reply}):
        # its status line never draws and the c/w/r a human presses to answer it
        # arrive here as a line. So the read closes when the countdown starts,
        # and opens again if it is cancelled.
        def wanted?(attention) = attention.outstanding? && !@conductor.counting_down?

        def park_until
          Async::Task.current.sleep(TICK) until yield
        end

        # A read that raised ends this line's reading in words rather than as a
        # task failure: retrying it every tick would render the same error
        # forever.
        def heard
          @reply.command_line(PROMPT) || ENDED
        rescue StandardError => e
          @tty.render_error(e.message)
          ENDED
        end

        # Guarded because it runs inside the ensure of an unwinding line, where
        # a raise would replace the stop that is climbing.
        def close(reading)
          return if reading.nil? || reading.completed?

          reading.stop
          @notice.call(CLOSED)
        rescue StandardError
          nil
        end

        # `StandardError` for {AnswerLoop#exchange}'s reason: this fiber is the
        # only way to type `/approve` while the line is parked, so a drain that
        # raised must be reported rather than end it. {Reply::UnknownArm} is the
        # one raise that climbs, as it does at the reply prompt.
        def served(line)
          @reply.commanded(line, hold: @hold, drain: @drain)
        rescue Reply::UnknownArm
          raise
        rescue StandardError => e
          @tty.render_error(e.message)
        end
      end

      # The `human>` reads open right now, each for the set it asks about, so a
      # set answered on ANOTHER surface can stop the read still waiting on it.
      # Held as reads rather than as digests: a digest can come back -- a reply
      # handed back re-opens the same set -- so "this set was settled" must reach
      # the reads that were open when it was, and no read opened after.
      class OpenReads
        # What {#race} answers for a read stopped because its set was settled.
        SETTLED = Object.new.freeze

        # One read of one set.
        class Read
          attr_reader :digest

          def initialize(digest, task)
            @digest = digest
            @task = task
            @settled = false
          end

          def settled? = @settled

          def wait = @task.wait

          # Not a stop of the calling fiber: a settle reached from inside the
          # read would unwind the delivery that settled it. The read then ends
          # as it would have, and still counts as settled.
          def settle
            @settled = true
            @task.stop unless @task.current?
          end
        end

        def initialize = @open = []

        # Run the block as a read of `digest` in a child task, answering its
        # value or {SETTLED}. `finished: false` because a raise out of the read
        # is re-raised here by `wait`, and is the caller's to report.
        def race(digest, &block)
          read = Read.new(digest, Async::Task.current.async(finished: false, &block))
          @open << read
          heard = read.wait
          read.settled? ? SETTLED : heard
        ensure
          @open.delete(read)
        end

        # The reads open for `digest` at this instant.
        def on(digest) = @open.select { |read| read.digest == digest }
      end

      # The arrivals waiting on the question queue, which a line that ended
      # while one was unanswered put back. Picked out BY IDENTITY, for
      # {OpenReads}' reason: the same digest can arrive again, and only the
      # items that were there when a set was settled are retired with it.
      class Queued
        # The queue nobody wired -- one surface answering one asker, as an epic
        # gate's seat is -- which holds nothing for an answer to retire.
        module NOTHING
          def self.on(_digest) = [].freeze
          def self.withdraw(_items) = nil
        end

        def initialize(questions) = @questions = questions

        # The items queued for `digest` at this instant, left where they are.
        def on(digest) = rotated { true }.select { |item| item.digest == digest }

        def withdraw(items)
          rotated { |item| items.none? { |gone| gone.equal?(item) } } unless items.empty?
        end

        private

        # Every item off the queue and the ones the block keeps put back, in
        # order and with no yield between -- {Approval::Queue}'s own way of
        # editing a buffer it cannot index. Answers everything that was taken.
        def rotated(&block)
          taken = Array.new(@questions.size) { @questions.dequeue(timeout: 0) }.compact
          kept = taken.select(&block)
          @questions.enqueue(*kept) unless kept.empty?
          taken
        end
      end

      # The approval list nobody wired, and a fourth object because it is a
      # fourth fact: a run can have an editor, its views and a changeset review
      # all bound and still have no approval list -- an unattended run wires no
      # {Approval::Queue} to render -- so a human told "no editor is attached"
      # would be told something false about the thing in front of them.
      #
      # Named for the LIST'S ABSENCE rather than whatever caused it, as
      # {Command::Env::NoApprovals} is: which flags leave a run queueless has
      # already changed once. That sibling is a LISTING over the session queue;
      # this one is a VERDICT surface over the EDITOR's view.
      module NoApprovals
        # {NoReview::Nothing}'s shape, kept apart for its reason: a human who
        # has an approval list open and no review must not be told about the
        # review.
        module Nothing
          def self.decided? = false
          def self.report = "no approval list is open in this editor, so there is nothing to answer"
        end

        # `**` rather than the named keyword, for {NoViews.open}'s reason.
        def self.decide(_line, _verdict, **) = Nothing
      end

      # Every editor verb that names a POSITION and answers only whether it
      # landed: each takes a LINE or an id off the wire, resolves it through the
      # surface that rendered it, and ends at {#gestured}, which reports a
      # refusal back in the editor the gesture came from.
      #
      # The cut from {HumanReplies} is the RAISE: what stayed there routes
      # ANSWERS, each reaching the Store or a promise and able to raise. An
      # approval verdict is the one member here that reaches a promise and
      # belongs on this side anyway, because {Approval::Queue::Pending#decide}
      # is single-shot and answers a lost race with `false` rather than with
      # {Promise::AlreadyResolved} -- a value this object reports, never an
      # exception somebody else's rescue has to catch.
      class Gestures
        # The gesture's own surface broke its outcome contract. A CONSTANT
        # rather than a literal at the call site, which is a width requirement:
        # `spec/refusal_width_discipline_spec.rb` measures what rides this rail
        # and a bare literal at a sink has no definition site to name -- this
        # sentence shipped at 128 columns of lain's own words for that reason.
        # `%s` is LAST because the embedded message is of a length no bar
        # reaches.
        UNANSWERED_OUTCOME = "this gesture's surface could not read its outcome -- nothing happened: %s"

        # All four are READERS, not the surfaces: every one is bound after this
        # object exists, at its own call site, and a review is opened mid-run.
        # Holding them instead worked only with a `rebind` at every binder PLUS
        # an invalidation of the memoized route table, and a future binder
        # forgetting either would be ignored in SILENCE.
        #
        # @param editor [#call] returns where a gesture that did not land is
        #   reported -- {NoEditor} when none was bound
        # @param views [#call] returns what resolves an inbox line and a timeline
        #   line -- {NoViews} when none were bound
        # @param review [#call] returns what resolves a review sidebar row and an
        #   anchor id -- {NoReview} when none was bound
        # @param approvals [#call] returns what resolves a lain://approval row
        #   into the parked call it drew -- {NoApprovals} when none was bound
        def initialize(editor:, views:, review:, approvals: -> { NoApprovals })
          @editor = editor
          @views = views
          @review = review
          @approvals = approvals
        end

        # One verb, one reaction, merged into {HumanReplies#routes}.
        def routes
          {
            "open" => ->(args) { open_set(args) },
            "pin" => ->(args) { pin_turn(args) },
            "review_open" => ->(args) { open_hunk(args) },
            "review_mark" => ->(args) { mark_hunk(args) },
            "review_ask" => ->(args) { ask_docent(args) },
            "approval" => ->(args) { answer_approval(args) }
          }
        end

        private

        # The `y`/`n` gesture from lain://approval, in {#mark_hunk}'s shape and
        # for its reasons: the LINE is all the editor can send, because a row
        # renders no identity for a parked call, and the VERDICT rides the wire
        # rather than being toggled, because a decision computed from a
        # rendering that has since moved answers the neighbouring call silently,
        # both values being legal.
        #
        # It runs HERE and nowhere else: deciding resolves a {Lain::Promise},
        # and a promise must be resolved on the reactor -- which is why the verb
        # is acked to this rail rather than answered on the RPC thread the way a
        # question's `:w` is.
        def answer_approval(args)
          line, verdict, generation = args
          gestured(@approvals.call.decide(line, verdict, generation:), &:decided?)
        end

        # The inbox's `<CR>`/`r` gesture. The LINE is all the editor can send,
        # since an inbox row renders no digest, and the GENERATION is the stamp
        # on the rendering the human is looking at -- without which a line
        # number names a position in a buffer whose positions move under it.
        def open_set(args)
          line, generation = args
          gestured(@views.call.open(line, generation:), &:opened?)
        end

        # No stamp is needed here: the timeline only ever grows, so a line names
        # one turn forever.
        def pin_turn(args) = gestured(@views.call.pin(args.first), &:pinned?)

        # The review sidebar's `<CR>`, in {#open_set}'s shape and for its
        # reasons. A sidebar row renders no hunk key -- a hunk key is a DIGEST,
        # which the editor never sends in either direction -- and the rows move
        # every time the scope toggles, which is what the stamp is for.
        def open_hunk(args)
          line, generation = args
          gestured(@review.call.open(line, generation:), &:opened?)
        end

        # Stamped for {#open_hunk}'s reason. The STATE rides the wire rather
        # than being toggled here: what the human pressed is what they meant,
        # and a toggle computed from a rendering that has since moved flips the
        # wrong hunk silently, both values being legal.
        #
        # `announce: true`, unlike every other gesture on this rail, because a
        # mark has nothing else that tells the human it landed -- opening a row
        # moves the cursor, answering an approval closes its row, while a mark
        # redraws a sidebar glyph nobody is necessarily looking at. Speaking
        # `outcome.report` unconditionally is correct because EVERY path through
        # {Review::Handover#mark} carries a sentence in its own words, and none
        # of them is a bare hunk key.
        def mark_hunk(args)
          line, state, generation = args
          gestured(@review.call.mark(line, state, generation:), announce: true)
        end

        # The docent question, and the ONE gesture here carrying no stamp: an
        # anchor id is one Ruby minted and handed to the editor, so it names the
        # same anchor in every rendering, where a line only names one in the
        # rendering that drew it.
        def ask_docent(args)
          anchor_id, question = args
          gestured(@review.call.ask(anchor_id, question), &:asked?)
        end

        # A gesture that did not land owes the human a sentence, in the editor
        # it came from. The predicate rides as a block because the gestures name
        # their own success -- opened, pinned, marked, asked -- and none should
        # be renamed to share a word with another.
        #
        # `announce:` is false for every gesture but {#mark_hunk}'s: a gesture
        # that DID land stays silent, because landing already has a visible
        # trace that speaks for it. True SKIPS the predicate rather than
        # inverting it, because {#mark_hunk} wants the report spoken on every
        # path -- success and refusal read the same field -- not a duplicate of
        # the refusal branch with the sense flipped.
        def gestured(outcome, announce: false)
          @editor.call.review_refused(outcome.report) if announce || !yield(outcome)
        rescue NoMethodError => e
          @editor.call.review_refused(format(UNANSWERED_OUTCOME, e.message))
        end
      end

      # The reviews the editor is holding open, keyed on the PAIR the wire
      # carries: a bare generation cannot say which epic it means, and two epics
      # both hand out 1. The generation goes through {Epic::WireInteger} on BOTH
      # sides of the lookup, because a key read two ways is a key that misses --
      # `.to_i` turns `"7abc"` and `7.9` into 7 and `nil` into 0, so a shallow
      # reading would name somebody else's review rather than refuse.
      class Reviews
        def initialize = @open = {}

        def bind(review, token:) = @open[key(token.epic_slug, token.generation)] = [review, token.path]

        # ONE array of arguments, like every other verb on this rail, because
        # the consumer destructures `verb, args`. Annotations arrive
        # String-keyed -- they crossed msgpack from lua and nothing here re-keys
        # them, so the journal records what the editor actually sent.
        #
        # A `done` naming no open review RAISES, which is how it reaches the
        # human: {HumanReplies#serve_editor_command} turns a raise into a
        # refusal rendered back in the editor.
        def settle(args)
          generation, epic_slug, annotations = args
          named = key(epic_slug, generation)
          review, path = @open.fetch(named) do
            raise Lain::Epic::Review::NotOpen,
                  "review generation #{generation} is not open for epic #{epic_slug.inspect}"
          end
          review.settle(generation, disk: File.binread(path), annotations: annotations || [])
          @open.delete(named)
        end

        private

        def key(epic_slug, generation)
          [epic_slug.to_s, Lain::Epic::WireInteger.read(generation, field: "generation")]
        end
      end

      # The lines a human can see, and the digest each one is answered by: which
      # items are listed, and which one a nameless answer means.
      #
      # An Array with an opinion rather than a wrapper -- every method here is
      # one of the four rules the list actually has.
      class Pending
        include Enumerable

        def initialize = @items = []

        def each(&block) = @items.each(&block)
        def <<(item) = @items << item
        def empty? = @items.empty?

        # Non-blocking: every arrival on the queue right now, without parking a
        # fiber on an empty one. `dequeue(timeout: 0)` answers nil on empty, so
        # `take_while` stops pulling at the first one -- an infinite producer is
        # safe because nothing forces it past that point.
        def gather(queue)
          @items.concat(Enumerator.produce { queue.dequeue(timeout: 0) }.take_while { |item| !item.nil? })
        end

        # By NAME, never by position: the item an answer belongs to need not be
        # the one at the head, and retiring the head drops a question nobody
        # answered out of the human's only view of it.
        def retire(digest) = @items.delete_if { |item| item.digest == digest }

        # What an answer naming no set of its own means: the oldest item listed.
        # {Unlisted} when nothing is, so the refusal is the directory's rather
        # than a nil's.
        def oldest = @items.first || Unlisted
      end

      # One human answer, read, paired with the set it answers. Holds the
      # terminal it happens on, the conductor that owns stdin while it does, and
      # the list the `/inbox` detour lists.
      #
      # Its own object because the detour, the refusal-and-retry and the pairing
      # all belong to the READ, and the pair is built where the knowledge is.
      class Reply
        # The session registry nobody bound, so {#read} never asks whether one
        # was wired: a single-asker caller constructs {HumanReplies} without a
        # registry and still reads answers. `dispatch` YIELDS, because the
        # fallthrough block IS the unmatched path in the real registry too.
        #
        # NO SESSION command is registered here, and `/inbox` is not one:
        # `/inbox` at this prompt is THIS surface under another name, it
        # predates the registry, and a caller that wired no commands must not
        # lose it. So the predicate is still put to the real {Command::Inbox},
        # which is what makes this a Null Object rather than a string literal.
        #
        # A class holding one instance rather than a module holding none: an
        # ivar set in `#initialize` is neither the class state `ThreadSafety`
        # objects to nor a constant pinning this leaf's load order against
        # `cli/command.rb`, and it builds the registry once per session.
        class NoSessionCommands
          def initialize
            @registry = Command::Registry.new([Command::Inbox.new])
            freeze
          end

          def serves_replies?(text) = @registry.serves_replies?(text)

          def dispatch(_text) = yield
        end

        # A `case` over {#classify}'s arms that met a value no arm claims: a
        # programming error, never a typed line, and the one raise this
        # surface's guards deliberately let climb -- rendered and re-read like a
        # command's raise, it would swallow every reply instead of reporting
        # itself once.
        class UnknownArm < Error; end

        def initialize(tty:, conductor:, inbox:, commands: NoSessionCommands.new)
          @tty = tty
          @conductor = conductor
          @inbox = inbox
          @commands = commands
          @detour = Command::Registry.new([Command::Inbox.new])
        end

        # @see HumanReplies#bind_commands the only caller, and where the reason
        #   for binding rather than injecting is written
        def bind_commands(commands) = @commands = commands || NoSessionCommands.new

        # The reply prompt of a PARKED set. `/inbox` detours to the drain for
        # THIS item, so the document the human reads and the set their reply
        # answers are one question. Draining for whatever was oldest and
        # resolving the answer against this item was invisible while an answer
        # was an opaque line, and is not any more: a prose answer NAMES the
        # questions it answers, so the wrong set received a reply naming another
        # set's ids while the set the human read stayed pending.
        #
        # @return [Array(String, InboxItem)] the answer -- or the answer nobody
        #   gave, when the stream ended under this read ({#unanswered}) -- and
        #   the item it answers
        def for(item) = accepted { read(item) }

        # `/inbox` at `you>`: nothing is parked on this read, so one typed
        # answer answers the oldest item listed and a read that ENDS answers
        # nothing. The two prompts read EOF identically and dispose of it
        # differently, because only one has a run waiting on the answer -- see
        # {HumanReplies#drain_at_prompt} for what refusing here destroyed.
        def at_prompt = accepted { drained(answering: @inbox.oldest, ended: "") }

        # {CommandLine}'s one read, through the conductor's command read, which
        # leaves typeahead to be read as the line it is.
        #
        # @return [String, nil] the line, or nil when the stream ended
        def command_line(prompt) = heard(prompt, through: :read_command)

        # What a line typed at {CommandLine} becomes, classified by the SAME
        # {#classify} both reply prompts use. Nothing here is an answer: prose
        # and an unclaimed `/word` go to `hold`, `/inbox` to `drain`, and a
        # command has already run. A line the record cannot carry is refused
        # where it was typed, as at the reply prompt -- checked BEFORE blankness,
        # which would read undecodable bytes as nothing and drop them unsaid.
        #
        # A BLANK line is nothing at all: Enter is what a human presses at a
        # prompt appearing mid-stream, and held it became an empty prompt sent
        # to the model.
        def commanded(line, hold:, drain:)
          refusable do
            readable = legible(line)
            routed(readable, hold:, drain:) unless Blankness.blank?(readable)
          end
        end

        private

        def routed(line, hold:, drain:)
          arm = classify(line)
          case arm
          when :prose, :unmatched then hold.call(line)
          when :replies then drain.call
          when :handled then nil
          else raise UnknownArm, unknown_arm(arm)
          end
        end

        # Routed through the conductor rather than the tty directly, so the
        # conductor KNOWS Reline owns stdin for the span and suppresses its
        # countdown ticker's render and key-read.
        #
        # nil is EOF, and it is NOT `""`. `.to_s`ed into one it is the same
        # value a human pressing Enter types, which this prompt delivers as
        # their answer on purpose -- so a session whose stdin went away wrote a
        # `message` record `from: "human"` carrying an empty answer: an
        # utterance in a session with nobody in it. One keystroke apart at the
        # terminal, as far apart as possible in the record.
        #
        # `legible` runs BEFORE the registry is consulted: `String#strip` on
        # invalid bytes raises Encoding::CompatibilityError, which is not the
        # ArgumentError the refusal path rescues, so it would climb past every
        # guard here and retire the line while leaving the promise pending --
        # the exact end state `legible` exists to prevent, reached one line
        # above it.
        def read(item)
          line = heard("human> ")
          return [unanswered, item] if line.nil?

          typed(legible(line), item)
        end

        # ONE read, and the one place this class decides a stream is over.
        # `read_reply` ANSWERS nil at end-of-file, but a terminal that dies
        # mid-read does not politely return: Reline raises `EOFError`, and a
        # PTY whose far end has gone raises `Errno::EIO`, which is what a
        # closing tmux pane produces. All three are the same fact. Left to climb
        # they were worse than a wrong answer -- both are StandardErrors, so
        # {AnswerLoop#exchange} rendered them and reported the line SETTLED,
        # retiring the inbox row while the asker stayed parked forever, by the
        # one path {#serve}'s re-queue rule does not cover.
        #
        # Narrow on purpose, and `IOError` is deliberately NOT here: widening it
        # would turn every transient terminal fault into a question nobody can
        # ever answer.
        def heard(prompt, through: :read_reply)
          @conductor.public_send(through, @tty, prompt)
        rescue EOFError, Errno::EIO
          nil
        end

        # `:unmatched` answers HERE and refuses in the drain, which is the one
        # place the two prompts part company: an unregistered `/word` typed at
        # this prompt is settled precedent, while in a drain it is refused.
        # Unifying it either deletes that precedent or sends a mistyped command
        # to the model as a considered reply.
        #
        # No rescue of its own: {#classify} owns the registry guard, and one
        # here would have to make an exception for {UnknownArm}, the one raise
        # that must climb.
        def typed(line, item)
          arm = classify(line)
          case arm
          when :prose, :unmatched then [line, item]
          when :replies then drained(answering: item, ended: unanswered)
          when :handled then nil
          else raise UnknownArm, unknown_arm(arm)
          end
        end

        # What the line turned out to be, in the order the registry itself draws
        # the lines -- asked by BOTH reply prompts so the order cannot drift
        # between them. As `line.strip == "/inbox"` and nothing else, every
        # OTHER registered `/word` was recorded as the human's answer.
        #
        # `/inbox` is not a session command here: it is this surface under
        # another name, and it is deliberately NOT routed through `dispatch`,
        # because {Command::Inbox} drains `@inbox.oldest` -- the defect {#for}
        # records as fixed.
        #
        # TWO PREDICATES, because `serves_replies?` means "reads the terminal
        # itself" and `/inbox` is no longer the only command that does:
        # `/approve` asks its `[y/N]` too. Read as the detour, that claim
        # swallowed `/approve` here -- it never ran, and the human's next line
        # answered the parked set. So the claim is the command's own, and which
        # command it is gets asked of a registry holding `/inbox` alone, rather
        # than of a literal.
        #
        # `:unmatched` comes from the FALLTHROUGH block, the only thing that can
        # say a command did NOT claim the line: a command's outcome may be any
        # value, `nil` included, so reading the return would take a quiet
        # `/keep` for an unmatched line.
        #
        # `StandardError`, not `Lain::Error`, on a measured hole: {Registry#invoke}
        # wraps a raise from a command's `#call` into an attributed Lain::Error,
        # and NOTHING wraps `#serves_replies?`, which is asked first -- a
        # command whose predicate raised took the parked question down.
        # `Async::Stop` is not a StandardError, so a cancelled read still climbs.
        #
        # @return [Symbol] :prose, :replies, :handled, or :unmatched
        def classify(line)
          return :prose if prose?(line)
          return :replies if @commands.serves_replies?(line) && @detour.serves_replies?(line)

          arm = :handled
          outcome = @commands.dispatch(line) { arm = :unmatched }
          delivered(outcome, line) if arm == :handled
          arm
        rescue StandardError => e
          @tty.render_error(e.message)
          :handled
        end

        # Whether the line cannot name a command AT ALL, asked before the
        # registry so no reply line is refused for the grammar's reasons. Two
        # shapes reach it:
        #
        # * a line the grammar cannot parse. {Skill::Invocation.parse} raises
        #   {Skill::Invocation::Malformed} on a leading token that attempts a
        #   role-and-skill spelling and breaks it -- right at `you> ` and wrong
        #   here, since this prompt dispatches no skills. Left to climb it did
        #   worse than refuse: past {#refusable}'s ArgumentError catch into
        #   {AnswerLoop#exchange}, which settles the line, so the set was
        #   retired unanswered and the next line never reached it either.
        # * a ROLE-BOUND line, which no command can be, since {Registry} matches
        #   only the inline shape.
        def prose?(line)
          invocation = Skill::Invocation.parse(line)
          invocation.nil? || !invocation.inline?
        rescue Skill::Invocation::Malformed
          true
        end

        # A command's outcome AT THIS PROMPT, always nil so the prompt comes
        # round again: the set is still parked, and running a command is not
        # answering it. A Repl ACTION cannot be honoured here, since
        # {AnswerLoop#exchange} hands back an answer and an item and nothing
        # else -- so it is refused BY NAME rather than dropped, because a
        # `/quit` that appears to do nothing reads as a wedged session.
        #
        # The refusal is POST-HOC: the command has already run. `/quit` is the
        # only shipped command returning a Symbol and its `#call` is `= :quit`,
        # so nothing happens before it is refused. A future action-returning
        # command that DOES something first would fire that side effect and then
        # be told it cannot run, which is a lie the human cannot act on -- at
        # that point this needs the registry to answer "does this command return
        # an action" BEFORE the call, not a wider rescue.
        def delivered(outcome, line)
          case outcome
          when nil then nil
          when String then @tty.render_response(spoken(outcome))
          when Renderable then @tty.render_renderable(outcome)
          else @tty.render_error(refusal(outcome, line))
          end
          nil
        end

        # The SAME synthetic Response {Repl#deliver_text} builds, so a command's
        # answer reaches the terminal through one renderer whichever prompt it
        # was typed at.
        def spoken(text) = Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn)

        # Both halves say WHICH command: a refusal that names none is one the
        # human cannot act on.
        def refusal(outcome, line)
          return "command #{called(line)} returned something a reply prompt cannot render: #{outcome.inspect}" \
            unless outcome.is_a?(Symbol)

          "#{called(line)} is a session command and cannot run at a reply prompt -- answer the question first"
        end

        # Only a line the registry already matched reaches here, so its leading
        # word IS the command -- split rather than parsed a second time that
        # could disagree.
        def called(line) = line.to_s.split.first

        # The drain answers the item it was NAMED, and pairs the answer with the
        # caller's own object -- never one shipped out to the frontend and back.
        #
        # `reader:` is the seam the registry arrives through. As a bare lambda
        # consulting nothing, a `/word` typed into the drain was recorded as the
        # human's answer -- the defect {#typed} had already been fixed for,
        # surviving behind the detour that opens this. {Frontend::TTY::Inbox}
        # learns nothing about commands; it asks for a line and gets one.
        #
        # `ended:` is a PARAMETER because it is the one thing the two prompts
        # genuinely disagree about. Both read EOF the same way, but only {#for}'s
        # caller has a run parked on the set, which is what makes "no answer will
        # ever come back" true there and a guess at `you>`. A type test in the
        # caller would be the same branch with the reason left out.
        def drained(answering:, ended:)
          answer = ""
          reading = drain_reader(-> { answer = ended })
          @tty.drain_inbox(@inbox, answering:, reader: reading) { |typed| answer = typed }
          [answer, answering]
        end

        # Each line read through the SAME {#classify} {#typed} uses, so a command
        # runs at either prompt and the registry's order is decided in one place.
        #
        # A lambda built per drain rather than a bare method reference, because
        # the drain `to_s`es whatever this hands back -- which would strip an
        # {Unanswered} to a plain String and deliver the refusal sentence as the
        # human's own prose. So the read that saw the nil is what says so,
        # through `on_eof`, living exactly as long as the drain it was built for.
        #
        # Lazy and iterative for {#accepted}'s reasons: a command answers
        # nothing, so a human who runs six before replying costs no six frames.
        #
        # A reply opening with a registered-looking `/word` cannot be typed here
        # -- `/tmp is fine` is classified, not answered. That is the deliberate
        # cost: a mistyped command reaching the model as a considered reply is
        # unrecoverable, where a refusal is one retype. The inline prompt keeps
        # the opposite rule, and {#typed} records why.
        def drain_reader(on_eof)
          lambda do |prompt|
            Enumerator.produce { heard(prompt) }
                      .lazy.filter_map { |line| answerable_or_eof(line, on_eof) }.first
          end
        end

        # EOF ends the drain the way a blank line does, and tells the caller WHY
        # on the way past, because this read is the only thing that can still
        # tell the two apart.
        def answerable_or_eof(line, on_eof)
          return answerable(line) unless line.nil?

          on_eof.call
          ""
        end

        # The answer nobody gave, and the one name this class has for EOF. It
        # rides the ordinary reply seam because it IS a String: the directory
        # routes it by digest without reading it, and the asker that wrote the
        # question is the one object that asks what it is -- so there is no
        # second delivery path to keep in step with the first.
        def unanswered = Lain::Tools::AskHuman::Unanswered.new

        # The line if the drain should treat it as the answer, or nil to read
        # again. Both refusals NAME the word, because a `/word` that appears to
        # do nothing reads as a wedged prompt.
        #
        # `/inbox` is refused rather than dispatched or re-entered: dispatched it
        # would open a SECOND reader over the same stdin, which
        # `spec/reply_surface_discipline_spec.rb` exists to prevent; re-entered
        # it would nest a drain inside the drain it names.
        def answerable(line)
          arm = classify(line)
          case arm
          when :prose then line
          when :handled then nil
          when :replies then refused("#{called(line)} is the drain you are already in -- type the reply")
          when :unmatched then refused("#{called(line)} is not a registered command -- nothing ran, and " \
                                       "nothing was answered. If you meant it as text, start the line " \
                                       "with a space")
          else raise UnknownArm, unknown_arm(arm)
          end
        end

        # Both `case`es above are CLOSED sets, and this is what closes them. A
        # fourth arm added to {#classify} and forgotten at one call site would
        # fall out as nil, which {#accepted} reads as "nothing typed yet" and
        # re-reads -- swallowing every reply the human types while rendering
        # nothing, which is this surface's own silent-answer failure
        # reintroduced one refactor later.
        def unknown_arm(arm) = "the reply prompt classified a line as #{arm.inspect}, which no arm claims"

        # Rendered, and nil so the drain reads again.
        def refused(message)
          @tty.render_error(message)
          nil
        end

        # Read until the human types something the record can carry. A refusal is
        # NOT a dead question -- the set is still pending and a legible reply
        # still answers it -- so the reason is rendered where they typed it and
        # the prompt comes round again. Every other exit from a served question
        # means the line is dead, which is what lets the serving `ensure` retire
        # unconditionally.
        #
        # The drain does this for itself, so in practice this catches the INLINE
        # prompt, where a line that cannot be written used to reach the Store,
        # raise there, and take the `ensure` with it.
        def accepted(&read) = Enumerator.produce { refusable(&read) }.lazy.compact.first

        def refusable
          yield
        rescue ArgumentError => e
          @tty.render_error(e.message)
          nil
        end

        # What the Store can hold, checked where the human can still retype it:
        # invalid UTF-8 used to reach the event write and raise there, which is
        # the same dead line by a longer route.
        def legible(line) = Question::Rules.prose(line, "a typed reply")
      end
    end
  end
end
