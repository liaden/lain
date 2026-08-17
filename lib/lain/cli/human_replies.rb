# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The human-reply surfaces (I6), lifted out of Repl the way Wiring lifted
    # chat assembly: answering ask_human is its own responsibility -- the
    # arrival note, the `/inbox` drain, and the editor's :LainReply leg -- and
    # the Metrics trip said so.
    #
    # Every answer NAMES the set it answers (T11). This class holds the run's
    # {Tools::AskHuman::Directory}, not one asker, and routes by the digest the
    # arrival carried: which asker holds the named set is the directory's
    # question, and answering it from "the asker this class happens to hold"
    # is how a child's question becomes unanswerable while the parent has
    # nothing pending. The digest is also what RETIRES the item -- the item an
    # answer belongs to need not be the one at the head of the list.
    class HumanReplies
      # I6: one pending human question as the drain surface lists it -- who is
      # stuck (the asker's chain correlation), since when, the question, and
      # (T11) the name an answer must cite to reach it.
      InboxItem = Struct.new(:question, :from, :digest, :asked_at, keyword_init: true) do
        # The arrival, built from the Q event that has just been written --
        # {Wiring::Askers#announce}'s one call, and the only moment BOTH
        # attributions are true. Read at drain time instead, `from` is
        # whoever asked most recently and the digest is not recoverable at
        # all.
        # `agent` wins over the event's own `from` because `from` is the chain's
        # ROOT digest, and an `:inherit` child forks its parent -- so the two
        # share a root and are permanently indistinguishable at every surface
        # that renders the sender. `:inherit` is the DEFAULT for a @role spawn,
        # so that is the common case, not an edge one. The asker's name is the
        # honest identifier and was already carried this far for the desktop
        # notification; it just stopped there.
        def self.asked(question, event, agent: nil)
          named = Blankness.blank?(agent) ? event.from : agent
          new(question:, from: named, digest: event.digest, asked_at: Time.now)
        end
      end

      # No item to answer: an editor reply that named nothing, with nothing
      # listed to mean. It answers the one message a caller asks of an item,
      # with a name no registered asker can hold -- so the refusal comes back
      # from the directory, in the words a human at a reply prompt needs,
      # rather than from a nil check here.
      module Unlisted
        def self.digest = nil
      end

      # How long the editor consumer parks between empty polls. The rail is a
      # Thread::Queue popped non-blockingly (a blocking pop would freeze the
      # reactor thread), so the tick is what keeps the fiber cheap. It is paid
      # for the whole conversation now, not for one ask ({#session_surfaces}),
      # which is the price of answering a gesture the human makes at `you>` --
      # a 10Hz `pop(true)` against a queue in this process, and the only
      # alternative on offer parks the RPC thread.
      IDLE_TICK = 0.1

      # The editor that is not there ({Sink::Null}'s shape): nothing ever
      # arrives on its rail and a refusal has nowhere to render. It exists so
      # that neither the consumer loop nor the refusal path asks whether an
      # editor was bound -- the question is answered once, in {#bind_editor}.
      # `attached?` is the one distinction still worth drawing: a fiber polling
      # a rail nothing can ever reach is pure cost, so it is never spawned.
      module NoEditor
        def self.pop(*) = nil
        def self.review_refused(_message) = nil
        def self.attached? = false
      end

      # The views nobody wired ({NoEditor}'s other half): no editor means no
      # inbox rendering to resolve a line against and no timeline to pin a turn
      # in. Every gesture answers {Nothing}, so the consumer never asks whether
      # views were bound -- and the sentence it hands back goes to {NoEditor},
      # which renders it nowhere, so there is no nil to check on that side
      # either.
      module NoViews
        # Nothing happened, and here is why -- the shape both
        # {Frontend::Neovim::InboxView::Opened} and
        # {Frontend::Neovim::Buffers::TimelineView::Pin} answer, since the two
        # gestures share one refusal path here.
        module Nothing
          def self.opened? = false
          def self.pinned? = false
          def self.report = "no editor is attached, so there is nothing to open or pin"
        end

        # `**` rather than the named keyword ({Frontend::Neovim::Buffers#open}
        # takes `generation:`): a keyword is its own name, so there is no
        # underscore spelling that both matches the caller and reads as unused.
        def self.open(_line, **) = Nothing
        def self.open_next = Nothing
        def self.pin(_line) = Nothing
        def self.answered(_digest) = nil
      end

      # The changeset review nobody wired (T11) -- {NoEditor} and {NoViews}'
      # third sibling, and a third object because it is a third fact: the rail,
      # the views and the review the human is reading are bound at three
      # different moments by three different callers, and a run can easily have
      # the first two and not the last.
      module NoReview
        # {NoViews::Nothing}'s shape, kept APART from it rather than shared: the
        # two say different things, and a human who has an editor open and no
        # review would otherwise be told the editor is missing -- the same defect
        # {Frontend::Neovim::RenderInlet}'s three separate sentences exist to
        # avoid, on the outbound side.
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

      # `ask_human:` is the ask_human REPLY SEAM -- whatever answers
      # `#reply(answer, digest)` for the set a digest names. Production hands
      # over the run's {Tools::AskHuman::Directory} (many askers, one routing
      # table); a single-asker caller may hand over a lone
      # {Tools::AskHuman}, which answers the same message with the same two
      # refusals. Which object it is has stopped mattering here, which is the
      # point: this class no longer knows or cares WHICH agent is stuck.
      def initialize(tty:, conductor:, ask_human:, questions:)
        @tty = tty
        @ask_human = ask_human
        @questions = questions
        # "Nothing is bound yet" stated as the bind it is, rather than as a
        # second copy of which Null each surface holds -- the copy that would
        # be the one to drift when a fourth arrived, which is exactly what
        # T36's did.
        bind_editor(nil)
        @changeset_review = NoReview
        @reviews = Reviews.new
        @inbox = Pending.new
        @reply = Reply.new(tty:, conductor:, inbox: @inbox)
        # READERS, never the surfaces: every one is bound after this returns, and
        # {Gestures} resolves each per call so a late bind is seen without
        # anybody remembering to rebuild anything.
        @gestures = Gestures.new(editor: -> { @editor }, views: -> { @views }, review: -> { @changeset_review },
                                 approvals: -> { @approvals })
      end

      # The editor's command rail -- :LainReply, :LainReviewDone, :LainOpen,
      # :LainPin -- bound before converse runs so #editor_reply_loop knows
      # whether to spawn its consumer fiber. The frontend hands over its own
      # inbox adapter and its view set, or nil for both when no editor is
      # attached; those are the ONLY nil checks in this class, and they live
      # here so no other line has to repeat them.
      #
      # `views` is the frontend's {Frontend::Neovim#buffers}: an `open` or a
      # `pin` names a LINE, and only the view that rendered that line can say
      # which set or turn it is. Bound beside the rail because the two are one
      # conversation -- the gesture arrives on the rail, resolves through the
      # views, and a refusal goes back out on the rail.
      #
      # `approvals` is the frontend's {Frontend::Neovim#approval_view} (T36),
      # bound HERE and not at a second call site for {#bind_changeset_review}'s
      # recorded reason: the rendering a keypress resolves through and the rail
      # its refusal goes back out on are one conversation, and two binds are two
      # chances for them to hold different objects -- which is a wrong-call
      # approval rather than an error.
      def bind_editor(editor, views: nil, approvals: nil)
        @editor = editor || NoEditor
        @views = views || NoViews
        @approvals = approvals || NoApprovals
      end

      # The editor a changeset is DRAWN in, and the second rail a review's
      # writes are answered on (T31a). The whole frontend, and deliberately not
      # a piece of it the way {#bind_editor} takes two: what this class needs
      # from it is one object to bind to and two collaborators to hand on, and
      # they are one fact -- a review drawn in one editor and answered in
      # another is not a review.
      #
      # @param editor [Frontend::Neovim, nil] nil is the editor that is not
      #   there, so a headless chat binds like any other -- see {#review_editor},
      #   which is where that nil becomes {ReviewSeams::Unattached}
      def bind_review_editor(editor) = @review_editor = editor

      # Where a changeset is drawn for this human, and the rendering their
      # gestures resolve through -- what {Wiring} threads into
      # {Tools::RequestReview} as thunks, because the tool is built before this
      # is bound. Both answer nil when no editor is attached, and the tool's own
      # seams coalesce that ({#bind_editor}'s one-nil-check rule, one object
      # over).
      delegate :review_surface, :review_view, to: :review_editor

      # Hold a review open for the editor's `done` gesture to settle -- see
      # {Reviews#bind}, which is where the keying rule lives.
      def bind_review(review, token:) = @reviews.bind(review, token:)

      # Hold the CHANGESET review the editor is reading (T11), so its gestures --
      # opening a row, marking a hunk, asking a docent about one -- resolve
      # against the rendering that produced the line they name. Deliberately not
      # {#bind_review}, which holds an EPIC's prose review keyed by (slug,
      # generation): the two ride the same rail and share nothing else, and
      # folding them together would mean one object answering `settle` and
      # `mark` for two unrelated notions of "review".
      #
      # ONE BIND, BOTH RAILS (T31a). The acked gestures resolve here; the two
      # WRITES -- an annotation and a verdict -- are answered by the editor on
      # its own RPC thread, through {Frontend::Neovim#bind_changeset_review},
      # and that method had no caller in the whole tree: notes and verdicts
      # reached {Frontend::Neovim::NoReviewWrites} and were refused. Forwarded
      # from here rather than bound a second time by the tool, because the tool
      # cannot reach a frontend -- and because two binds are two chances for the
      # rails to hold different reviews, which is a wrong-review write rather
      # than an error.
      def bind_changeset_review(review)
        review_editor.bind_changeset_review(review)
        @changeset_review = review || NoReview
      end

      # A human question is waiting for an answer: an item mid-drain (@inbox) or
      # one a subagent enqueued while the human sat idle at `you>`, which no
      # answer_loop fiber is watching between asks. T21's standing-goal driver
      # reads this to hold off re-prompting while the fleet is unquiet -- the
      # inbox half of that guard (the parked-approval half lives in Wiring).
      def pending? = !@inbox.empty? || !@questions.empty?

      # `/inbox` at `you>` (T13): the SAME TTY drain UX #answer_loop's
      # read_drained_answer calls at `human>`, over whatever has piled up in
      # `@questions` since the last time a fiber was actually watching it.
      # #answer_loop's fiber only lives for one DISPATCHED LINE
      # ({Repl::LineScope} starts it before the line is routed, per
      # {#surfaces}); the OM-6 supervisor's fleet outlives every one of them, so
      # a subagent's `announce` can enqueue a question while the human sits idle
      # at `you>` with nothing draining it. This is that second watcher, run on
      # demand instead of a second background fiber.
      #
      # It is therefore the one command that must NOT be bracketed in a reply
      # loop of its own -- {Command::Inbox} declares that, and
      # {Repl::LineScope#serve} is what reads the declaration. Two readers on one
      # stdin is what this method exists to avoid, not a state it may run in.
      #
      # Lists every item (gathered non-blockingly first, so a `you>`-time
      # `/inbox` shows the WHOLE backlog, not just the head), reads exactly
      # ONE answer ({Reply}'s own contract), and resolves it through the SAME
      # reply seam the human> path uses -- never a second answer path. The
      # listing offers no selection, so what one typed answer answers here is
      # the OLDEST item listed: nothing is parked on this read, so the first
      # line the human read is the only thing it can mean. {Reply} hands that
      # item back beside the answer, so the set that gets the answer, the
      # document that was printed, and the line that gets retired are one
      # question rather than three lookups that can disagree.
      #
      # A blank answer must resolve NOTHING and retire NOTHING, or the item
      # leaves the human's only view of a still-pending question. The drain
      # guards that at the source (a line of nothing but whitespace is never
      # an answer, see {Frontend::TTY::Inbox#settled}); the `strip.empty?`
      # check keeps the property local to the resolve as well.
      #
      # @return [String] the answer as it will be delivered -- for a question
      #   carrying a set that is the answer set's rendering, not the line the
      #   human typed -- or "" (nothing pending, or they typed nothing)
      def drain_at_prompt
        @inbox.gather(@questions)
        answer, answered = @reply.at_prompt
        resolve_reply(answer, answered.digest) unless answer.strip.empty?
        answer
      end

      # The concurrent reply surfaces for one DISPATCHED LINE: the TTY drain
      # loop, whose fiber must live exactly as long as that line and no longer --
      # the reply read parks inside it, and the terminal it reads from is the one
      # the next `you>` prompt needs back. The caller
      # ({Repl::LineScope#serve}) stops them in its ensure.
      #
      # The line, and not the ask: a question can be raised from a command
      # running lib-side or from the subagent a `@role[/skill]` line spawns, and
      # neither reaches {Repl#respond} -- the fiber that parks on one is the
      # dispatching fiber, so the surface answering it has to be its sibling.
      # The rest of the sentence above is unchanged and is the reason it goes no
      # wider than that.
      #
      # The editor's consumer is deliberately NOT here any more, and that
      # split is the point: see {#session_surfaces}.
      def surfaces(task) = [answers.spawn(task)]

      # The reply surfaces that live for the whole CONVERSATION, started on the
      # repl's own Sync ({Repl#run}) instead of on an ask's -- today just the
      # editor's command rail, and only when an editor is attached.
      #
      # An ask's lifetime is the WRONG one for that rail. This fiber is the
      # sole consumer of every editor verb, and a human uses the editor
      # precisely when no ask is in flight: a code review is a long stretch of
      # reading and marking with no model turns in it at all, and the sidebar
      # cannot redraw a mark as a glyph ({Review::Surface::Neovim}'s class doc
      # says why), so the sentence that comes back on this rail is the only
      # signal a gesture landed. Started per-ask, it was measured (2026-08-05)
      # answering nothing for 8s at an idle `you>` and then flushing the whole
      # backlog at once the moment a message was sent.
      #
      # The two loops share no queue -- this one polls the editor's rail, the
      # ask's parks on `@questions` -- so the longer lifetime cannot make them
      # race for an item. Where they do meet is {#deliver}, which is already
      # the one answer path both use and already drops the loser's duplicate as
      # `AlreadyResolved`.
      #
      # The caller stops these in ITS ensure, on every path, for exactly the
      # reason {Repl#respond} stops the ask's: a parked fiber holds the Sync
      # that owns it open forever.
      #
      # Only the surfaces that EXIST: "no editor is attached" is a fact this
      # class already answers with an object ({NoEditor}), so handing back a
      # nil beside it would be the same fact said a second way, in the form
      # every caller then has to check.
      def session_surfaces(task) = [editor_reply_loop(task)].compact

      private

      # The TTY arrival surface, built at the one call site that needs it rather
      # than in the constructor: nothing else in this class asks it anything, and
      # a session with no reply surface ever spawned never builds one. Memoized
      # because it REMEMBERS -- which arrivals it has already announced -- and
      # that memory must span the lines it is spawned for, not one of them.
      #
      # `resolve:` is a MESSAGE, not this object: what the loop owes an answer is
      # one call, and handing over `self` would let it reach everything.
      def answers
        @answers ||= AnswerLoop.new(questions: @questions, inbox: @inbox, tty: @tty, reply: @reply,
                                    resolve: method(:resolve_reply))
      end

      # The editor a changeset is drawn in, with its null resolved HERE and
      # nowhere else -- {Tools::RequestReview#bindings}' shape, and the reason
      # {#bind_review_editor} may take a bare nil. Private because
      # {#bind_review_editor} is the whole of this collaborator's public
      # surface: a reader beside a binder is a second way to ask the same
      # question. `delegate` reaches it (it calls with an implicit receiver),
      # which is what makes the two seams above one line rather than three.
      def review_editor = @review_editor || ReviewSeams::Unattached

      # The TTY's answer: the refusal is rendered where the human typed. A
      # digest no asker holds is the live outcome of a stale line (a run
      # stopped between the note and the answer), and the directory's own
      # sentence says the line was stale rather than that the answer was
      # wrong -- so it is passed through, not reworded.
      # A refusal SETTLES the line, and that half is load-bearing on the
      # `/inbox` path: `#drain_at_prompt` calls this directly rather than through
      # {AnswerLoop}, so nothing else here would ever retire the item. Rendering
      # and returning left the dead question listed, and every later `/inbox`
      # offered it again -- a line that lists forever and can only ever refuse,
      # which is exactly what the re-queue rule makes reachable by putting
      # ghosts where a drain finds them. `NoPendingQuestion` means the set is
      # gone, so nothing is lost by letting the line go; it is the same
      # conclusion {AnswerLoop#exchange} already reaches on its own path.
      def resolve_reply(answer, digest)
        deliver(answer, digest)
      rescue Lain::Tools::AskHuman::NoPendingQuestion => e
        @tty.render_error(e.message)
        settled(digest)
      end

      # The ONE answer path both surfaces use. AlreadyResolved: the other
      # surface beat this one -- normal, per the queue's own doctrine -- so
      # the duplicate is dropped and the item retired all the same, because
      # the set it named IS answered.
      def deliver(answer, digest)
        @ask_human.reply(answer, digest)
        settled(digest)
      rescue Lain::Promise::AlreadyResolved
        settled(digest)
      end

      # What "this set is DONE" means to everything that lists it, in ONE place
      # because every way of being done ends the same for a reader: the line
      # leaves the terminal's own list, and the editor's views stop offering the
      # set -- whichever surface took the answer, and whether the set was
      # answered, already answered, or withdrawn under the human. Named for
      # settled rather than answered because a third of its callers is a
      # refusal. Reported rather than inferred: a row is retired by the agent's
      # committed turn, a model round trip later, so until then only this knows.
      def settled(digest)
        @views.answered(digest)
        @inbox.retire(digest)
      end

      # The editor reply leg (I6): the :LainReply command lands on the frontend's
      # rail and this fiber resolves the pending ask from it. Spawned only for
      # an editor that exists -- {NoEditor} answers everything else, so nothing
      # downstream branches on whether one is attached.
      #
      # ONE of these per conversation, on the repl's own Sync ({#session_surfaces}),
      # never one per ask: it is the sole consumer of every editor verb, so a
      # second would race it for the same rail and each gesture would land on
      # whichever popped first.
      def editor_reply_loop(task)
        task.async { loop { serve_editor_command } } if @editor.attached?
      end

      # ONE editor command, and its own method because NOTHING a command does
      # may kill this fiber. It is the sole consumer of EVERY editor verb, so a
      # `review_done` that raises -- the reviewed file gone, an annotation the
      # wire dropped a key from, a settle that refuses -- would take
      # :LainReply down with it and the editor would go quiet with no sign why.
      # The refusal renders back in the editor, which is where the gesture came
      # from: a `done` that vanishes is the one outcome this surface must never
      # produce. Verbs nothing here claims are ignored (they rode their own
      # path to the frontend).
      #
      # There is no `pending?` pre-guard any more, and its absence is the fix:
      # it asked the object this class holds whether IT had something pending,
      # which under digest-addressed routing is not the question. "Is this
      # digest answerable" is the directory's to answer, and it answers it by
      # replying or refusing -- so a child's question stays answerable from the
      # editor while the parent holds nothing, and a race the TTY already won
      # comes back as AlreadyResolved, which {#deliver} drops.
      # `ScriptError` beside `StandardError` because `NotImplementedError` is
      # NOT a StandardError, and it is the likeliest one to arrive: an abstract
      # duck raises exactly that ({Frontend::Neovim::RpcThread::Listener}'s base
      # does), and it walked straight past the guard whose whole paragraph says
      # nothing may kill this fiber -- :LainReply died with no refusal rendered
      # at all. `Exception` is still refused, so `Interrupt` and `Async::Stop`
      # keep climbing.
      def serve_editor_command
        verb, args = pop_command
        verb.nil? ? sleep(IDLE_TICK) : routes[verb]&.call(args)
      rescue Lain::Promise::AlreadyResolved
        nil
      rescue StandardError, ScriptError => e
        report(e.message)
      end

      # The REFUSAL'S own failure, which had nowhere to go and so went
      # everywhere: this is the last line of the method above, it reaches the
      # editor -- the thing that just proved it can fail -- and a raise here
      # escaped every guard and ended :LainReply permanently, the one outcome
      # that method's comment forbids. Swallowed rather than re-reported
      # because there is no third surface to report it to: an editor that
      # cannot take a refusal cannot take the refusal about the refusal either.
      def report(message)
        @editor.review_refused(message)
      rescue StandardError, ScriptError
        nil
      end

      # One verb, one reaction -- {Frontend::Neovim::Router}'s shape on the
      # consumer's side of the same rail, and its `&.` for the same reason: the
      # editor's commands are not this object's to validate, so a verb no route
      # claims falls through in silence (it rode its own path to the frontend).
      # It became a table when `open` and `pin` made five branches of it and
      # Metrics said what that was, and two tables when T11's three made eight
      # and Metrics said it again -- this time naming a real seam rather than
      # mere size. What stays here SUBMITS: an answer for a parked set, a written
      # document, a settled review, each of which reaches the Store or a promise
      # and can raise, which is what {#serve_editor_command} rescues. What moved
      # to {Gestures} names a position and submits nothing.
      def routes
        @routes ||= {
          "reply" => ->(args) { deliver(args.first.to_s, @inbox.oldest.digest) },
          "question_answered" => ->(args) { answer_document(args) },
          "review_done" => ->(args) { @reviews.settle(args) }
        }.merge(@gestures.routes).freeze
      end

      # The written question document ({Neovim::QuestionView}): the wire's
      # `["question_answered", [digest, answer_set]]`. The digest is the
      # buffer's own stamp, so this answer names its set rather than inheriting
      # whatever the inbox lists first, and the set RENDERS to the String a
      # {Tool::Result} carries -- the tool's contract, not this seam's choice.
      def answer_document(args)
        digest, answers = args
        deliver(answers.render, digest)
        advance
      end

      # T16: one document submitted, so open the next set the human owes an
      # answer to -- or tell them there is none and leave them at the inbox.
      #
      # IT HAPPENS HERE, ON THE CONSUMER, AND IT CANNOT HAPPEN ANYWHERE ELSE.
      # {Frontend::Neovim::QuestionView} holds a non-reentrant Mutex across the
      # write and calls its `submit` INSIDE it, so a chain from the submit
      # callable (or from `#wrote`) re-enters that lock and raises
      # `ThreadError: deadlock; recursive locking` on the human's `:w`, with
      # the answer already handed on. This runs after the write returned and
      # the lock is long gone, which is the whole reason the hand-off is a
      # queue somebody else pops.
      #
      # It needs no argument: {#deliver} has already told the views that this
      # set was answered, and every set answered before it too, so "the next
      # one" is a question the views can answer for themselves.
      #
      # Its outcome is deliberately NOT echoed, which is the one place this
      # differs from {#open_set}: the human asked for no particular set here,
      # and everything the advance could say is already on their screen -- a
      # document opened, or the inbox with the remaining rows in it. A set it
      # could not open keeps its row, so pressing enter on it is what asks for
      # a sentence, and that path gives one.
      def advance = @views.open_next

      def pop_command
        @editor.pop(true)
      rescue ThreadError
        nil
      end
    end

    class HumanReplies
      # Reopened rather than nested in the class body above -- `tty.rb`'s idiom,
      # for the same reason: each collaborator is its own responsibility, and the
      # split keeps each body inside Metrics/ClassLength instead of loosening it.

      # The TTY arrival surface: ONE fiber parked on the queue, serving each
      # arrival from its note to its answer -- and deciding what becomes of the
      # LINE when that exchange ends.
      #
      # Its own object for this file's recurring reason ({Gestures}, {Reviews},
      # {Pending} and {Reply} came out the same way): {HumanReplies} was over
      # Metrics/ClassLength carrying it, and the cop was naming a real seam.
      # What is left there routes an ANSWER to the asker that asked; this owns
      # an ITEM's lifetime, from the queue to the list and -- when nobody
      # answered -- back.
      #
      # `resolve:` is a message rather than the owner: what this owes an answer
      # is one call ({HumanReplies#resolve_reply}), and holding the owner would
      # let it reach everything else.
      class AnswerLoop
        def initialize(questions:, inbox:, tty:, reply:, resolve:)
          @questions = questions
          @inbox = inbox
          @tty = tty
          @reply = reply
          @resolve = resolve
          @announced = Set.new
        end

        # Parks on dequeue (a real scheduler yield -- woken per arrival, never
        # polling) and serves them one at a time.
        def spawn(task) = task.async { loop { serve(@questions.dequeue) } }

        private

        # An item leaves this pair of holdings -- the queue it came off and the
        # list it was pushed onto -- only when the EXCHANGE ended, and
        # {#exchange} is what answers that. It ends two ways: the answer reached
        # the reply seam (or was refused there, which is the same fact about a
        # stale set said by the object that knows), or something raised and the
        # human was TOLD. Either way the line is dead and retiring it is right.
        #
        # An UNWIND is not on that list, and that is the change (T1).
        # `Async::Stop` climbing out of a cancelled read is not the question
        # being answered, it is the SURFACE being stopped -- and the surface is
        # now stopped at the end of every dispatched LINE
        # ({Repl::LineScope}), not of every ask. So a subagent's question
        # arriving while the human runs `/help` was dequeued, announced to a
        # human who was not looking, and then retired when the line ended: off
        # the queue and off the list at once, so `HumanReplies#pending?` read
        # false, no `/inbox` could ever list it, and the asker stayed parked
        # forever with no error and no journal line. It goes back on the queue
        # instead, for the next surface -- or the human's `/inbox` -- to reach.
        #
        # A set WITHDRAWN under a parked reader (the Ctrl-C shape) is re-queued
        # too, and that is the priced cost of the rule. The reason is that the
        # REPLY SEAM does not expose the distinction, not that nobody holds it:
        # `Directory` routes by name and its `Registration#holds?` answers
        # whether the NAME is registered, which stays true across a withdrawal --
        # measured, `holds?` reads true both before and after
        # `AskHuman#perform`'s unwind, because `Outstanding#abandon` clears the
        # asker and never touches the registration's map. The object that knows
        # is {Tools::AskHuman::Outstanding}, one layer under a seam whose whole
        # public contract is "reply or refuse".
        #
        # It is the right default even with that query in hand, because the two
        # mistakes are not symmetric: re-queueing a dead set costs one refusal
        # the human is told about, where retiring a live one parks the asker
        # forever with `#pending?` false and no surface able to reach it. This
        # one is also self-limiting -- the next surface serves it once, the
        # directory refuses it as stale, and it is retired, on the drain's path
        # ({HumanReplies#resolve_reply}) as much as on this one.
        #
        # The digest is this item's own, so nothing here can retire or re-queue
        # somebody else's.
        def serve(item)
          settled = exchange(item)
        ensure
          settled ? @inbox.retire(item.digest) : requeue(item)
        end

        # One arrival, from the note to the answer, answering whether the item
        # is SETTLED. A question ARRIVES as a one-line note; the reply read stays
        # fiber-parked (the ask cannot complete without it), but the surface is
        # the drain. `/inbox` at the reply prompt lists the pending items before
        # answering; any other line answers directly (the inline path stays the
        # no-inbox fallback), and it answers THIS item -- the one whose note the
        # human is looking at -- never whichever is at the head of the list.
        #
        # Both exits it has of its own are settled; the third, an unwind, does
        # not return at all and so cannot say so, which is exactly what
        # {#serve}'s ensure reads.
        #
        # A blank line here IS an answer, and deliberately not what the same
        # keystroke means at `you>`: this prompt exists because a run is PARKED
        # on this set, so declining to answer still has to reach the model, and
        # `""` is what carries that (`Tool::Result.ok(nil)` would raise). At
        # `you>` nothing waits on the drain's read, so Enter there means "I
        # looked, not now" and resolves nothing. The `/inbox` detour inside the
        # read does not move the human to that other prompt -- the set is still
        # parked on this fiber -- so Enter still answers it.
        #
        # NOTHING here may kill this fiber, for
        # {HumanReplies#serve_editor_command}'s reason and a sharper one: this is
        # the TTY answer path, which ruling 7 keeps live whether or not an editor
        # is attached, and it is ONE fiber for the whole run. The read reaches
        # Reline and a real terminal; the delivery reaches the Store and the
        # journal. Either raising un-guarded ended the loop permanently and
        # silently -- arrivals still landing on the queue with nothing draining
        # them, and a human watching a run that stopped asking. `StandardError`,
        # so an `Async::Stop` climbing out of a cancelled read keeps climbing.
        #
        # A REFUSED answer never reaches that rescue: {Reply} refuses and
        # re-reads, so what comes back is always something the record can carry.
        # Retiring on a refusal parked the agent forever AND deleted the only
        # line that could unpark it.
        def exchange(item)
          @inbox << item
          announce(item)
          answer, answered = @reply.for(item)
          @resolve.call(answer, answered.digest)
          true
        rescue StandardError => e
          @tty.render_error(e.message)
          true
        end

        # An ARRIVAL is announced ONCE, however many lines the question outlives.
        # A re-queued item is dequeued again by the next line's loop, and the
        # note says "this just arrived" -- which on the third `/fast` line is
        # simply false, and is noise the human cannot act on either, because the
        # read it precedes is torn down before they could type into it. The read
        # still opens on every serve, so a line they do linger on is answerable;
        # only the claim about arriving is spent.
        #
        # Keyed on the digest, so it is per SET and not per fiber, and bounded by
        # the questions a session asks -- the same bound {Directory}'s tombstones
        # already carry.
        def announce(item)
          @tty.render_arrival(item.question, from: item.from) if @announced.add?(item.digest)
        end

        # Back where a later surface can reach it. Off the list FIRST, because
        # the queue is where it lives again: a copy in both would be listed twice
        # the moment anything gathered. Deliberately NOT reached after a raise
        # ({#exchange} answers settled there) -- this loop would dequeue the item
        # again at once and fail the same way, which is a hot loop rendering one
        # error forever.
        def requeue(item)
          @inbox.retire(item.digest)
          @questions.enqueue(item)
        end
      end

      # The approval list nobody wired (T36) -- {NoEditor}, {NoViews} and
      # {NoReview}'s fourth sibling, and a fourth object for {NoReview}'s
      # reason: it is a fourth fact. A run can have an editor, its views and a
      # changeset review all bound and still have no approval list at all
      # (`--yolo` wires no queue, and a headless chat no editor), so a human
      # told "no editor is attached" there would be told something false about
      # the thing in front of them.
      #
      # It sits in THIS body and not beside its three siblings for the reason
      # stated directly above: the body above was over Metrics/ClassLength
      # carrying it, and the split is this file's recorded remedy rather than
      # loosening the limit.
      module NoApprovals
        # {NoReview::Nothing}'s shape, kept apart from it for its reason: the
        # two say different things, and a human who has an approval list open
        # and no review must not be told about the review.
        module Nothing
          def self.decided? = false
          def self.report = "no approval list is open in this editor, so there is nothing to answer"
        end

        # `**` rather than the named keyword, for {NoViews.open}'s reason.
        def self.decide(_line, _verdict, **) = Nothing
      end

      # Every editor verb that names a POSITION and answers only whether it
      # landed (T11, T36). Six of the nine, and they are one thing: each takes a
      # LINE or an id off the wire, resolves it through the surface that
      # rendered it, and ends at {#gestured}, which reports a refusal back in
      # the editor the gesture came from.
      #
      # Its own object because {HumanReplies} was over `Metrics/ClassLength`
      # carrying it, and the cop was naming a real seam rather than a size: the
      # class it left behind routes ANSWERS -- a reply, a written document, a
      # settled review -- each of which reaches the Store or a promise and can
      # RAISE, which is what {HumanReplies#serve_editor_command} rescues.
      #
      # An approval verdict is the one member here that does reach a promise,
      # and it belongs on this side anyway, because the cut is the RAISE and not
      # the promise: {Approval::Queue::Pending#decide} is single-shot and
      # answers a lost race with `false` rather than with
      # {Promise::AlreadyResolved}, so a verdict that arrives second is a value
      # this object reports -- exactly what {#gestured} is for -- and never an
      # exception somebody else's rescue has to catch.
      #
      # It holds its three surfaces rather than reaching for them, which is why
      # {HumanReplies#rebind} rebuilds it: the surfaces are bound after
      # construction, at two different call sites, by callers that may bind
      # either one or neither.
      class Gestures
        # All three are READERS, not the surfaces -- the bound-accessor shape
        # {Frontend::Neovim}'s listener uses, and for the same reason: every one
        # is bound after this object exists, at its own call site, and a review
        # is opened mid-run. Holding them instead worked only with a `rebind` at
        # every binder PLUS an invalidation of the memoized route table, and a
        # future binder forgetting either would be ignored in SILENCE -- which
        # is the exact failure the accessor exists to prevent. One answer to one
        # problem, in both directions.
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

        # {Frontend::Neovim::Router}'s shape, on the consumer's side of the same
        # rail: one verb, one reaction, merged into {HumanReplies#routes}.
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

        # The `y`/`n` gesture from lain://approval (T36): the wire's
        # `["approval", [line, verdict, generation]]`, which is {#mark_hunk}'s
        # shape for {#mark_hunk}'s two reasons. The LINE is all the editor can
        # send, because a row renders no identity for a parked call -- and the
        # VERDICT rides the wire rather than being toggled, because a decision
        # computed from a rendering that has since moved answers the
        # neighbouring call, silently, both values being legal.
        #
        # It runs HERE, on the reactor's editor-command consumer, and it can run
        # nowhere else: deciding resolves a {Lain::Promise}, and a promise must
        # be resolved on the reactor -- which is why the verb is acked to this
        # rail rather than answered on the RPC thread the way a question's `:w`
        # is.
        def answer_approval(args)
          line, verdict, generation = args
          gestured(@approvals.call.decide(line, verdict, generation:), &:decided?)
        end

        # The inbox's `<CR>`/`r` gesture (T16): the wire's `["open", [line,
        # generation]]`. The LINE is all the editor can send -- an inbox row
        # renders no digest -- and the GENERATION is the stamp on the rendering
        # the human is looking at, without which a line number names a position
        # in a buffer whose positions move under it.
        def open_set(args)
          line, generation = args
          gestured(@views.call.open(line, generation:), &:opened?)
        end

        # :LainPin's `["pin", [line]]` (B4), which has been sent and dropped for
        # as long as `open` was: the timeline only ever grows, so a line names one
        # turn forever and no stamp is needed.
        def pin_turn(args) = gestured(@views.call.pin(args.first), &:pinned?)

        # The review sidebar's `<CR>` (T11): the wire's `["review_open", [line,
        # generation]]`, which is {#open_set}'s shape for {#open_set}'s two
        # reasons. The LINE is all the editor can send, because a sidebar row
        # renders no hunk key -- and a hunk key is a DIGEST, which the editor
        # never sends in either direction. The GENERATION is the stamp on the
        # rendering the human is looking at, without which a row number names a
        # position in a buffer whose rows move every time the scope toggles.
        def open_hunk(args)
          line, generation = args
          gestured(@review.call.open(line, generation:), &:opened?)
        end

        # `["review_mark", [line, state, generation]]`, stamped for {#open_hunk}'s
        # reason. The STATE rides the wire rather than being toggled here: what
        # the human pressed is what they meant, and a toggle computed from a
        # rendering that has since moved flips the wrong hunk -- silently, since
        # both values are legal.
        def mark_hunk(args)
          line, state, generation = args
          gestured(@review.call.mark(line, state, generation:), &:marked?)
        end

        # `["review_ask", [anchor_id, question]]` -- the docent question, and the
        # ONE gesture here carrying no stamp. An anchor id is one Ruby minted and
        # handed to the editor, so it names the same anchor in every rendering,
        # while a line only names one in the rendering that drew it.
        def ask_docent(args)
          anchor_id, question = args
          gestured(@review.call.ask(anchor_id, question), &:asked?)
        end

        # A gesture that did not land owes the human a sentence, and it belongs in
        # the editor the gesture came from -- the same rail a refused
        # :LainReviewDone answers on. The predicate rides as a block because the
        # gestures name their own success ("opened", "pinned", "marked", "asked")
        # and none should be renamed to share a word with another.
        def gestured(outcome)
          @editor.call.review_refused(outcome.report) unless yield(outcome)
        rescue NoMethodError => e
          @editor.call.review_refused("the surface answering this gesture could not answer this gesture's " \
                                      "outcome, so nothing happened and lain cannot say why (#{e.message})")
        end
      end

      # The reviews the editor is holding open, and the ONE rule that keying
      # them needs. Its own object because "which review does this `done`
      # gesture mean" is not the business of a class about human replies: it
      # rides the same rail and shares nothing else, and {HumanReplies} was
      # over `Metrics/ClassLength` carrying it.
      #
      # Keyed on the PAIR the wire carries -- a bare generation cannot say which
      # epic it means, and two epics both hand out 1 (see {Epic::Review}) -- and
      # the generation goes through {Epic::WireInteger} on BOTH sides of the
      # lookup, because a key read two ways is a key that misses: `.to_i` turns
      # `"7abc"` and `7.9` into 7 and `nil` into 0, so a shallow reading would
      # name somebody else's review rather than refuse.
      class Reviews
        def initialize = @open = {}

        def bind(review, token:) = @open[key(token.epic_slug, token.generation)] = [review, token.path]

        # The wire's `["review_done", [generation, epic_slug, annotations]]` --
        # ONE array of arguments, like every other verb on this rail, because
        # the consumer destructures `verb, args`. Annotations arrive
        # String-keyed: they crossed msgpack from lua and nothing here re-keys
        # them, so the journal records what the editor actually sent.
        #
        # A `done` naming no open review RAISES, which is how it reaches the
        # human: {HumanReplies#serve_editor_command} turns any raise into a
        # refusal rendered back in the editor the gesture came from.
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

      # The lines a human can see, and the digest each one is answered by.
      # Split out because "which items are listed, and which one does a
      # nameless answer mean" is a responsibility of its own -- {HumanReplies}
      # was carrying it beside routing an answer to the asker that asked, and
      # the review panel and Metrics named the same seam.
      #
      # An Array with an opinion, not a wrapper: every method here is one of
      # the four rules the list actually has.
      class Pending
        include Enumerable

        def initialize = @items = []

        def each(&block) = @items.each(&block)
        def <<(item) = @items << item
        def empty? = @items.empty?

        # Non-blocking: every arrival sitting on the queue right now, without
        # parking a fiber on an empty one. `Enumerator.produce` calling
        # `dequeue(timeout: 0)` (nil on empty, per Async::Queue) stops pulling
        # the instant `take_while` sees the first nil -- an infinite producer
        # is safe because nothing forces it past that point. Each item arrives
        # carrying its own attribution, so nothing here asks an asker who
        # asked.
        def gather(queue)
          @items.concat(Enumerator.produce { queue.dequeue(timeout: 0) }.take_while { |item| !item.nil? })
        end

        # By NAME, never by position: the item an answer belongs to need not be
        # the one at the head, and retiring the head instead drops a question
        # nobody answered out of the human's only view of it.
        def retire(digest) = @items.delete_if { |item| item.digest == digest }

        # What an answer that names no set of its own means: the oldest item
        # listed -- the first line the drain printed, and what the editor's
        # digest-less :LainReply is replying to. {Unlisted} when nothing is
        # listed, so the refusal is the directory's rather than a nil's.
        def oldest = @items.first || Unlisted
      end

      # One human answer, read -- and the pairing of that answer with the set
      # it answers. Holds the terminal it happens on, the conductor that owns
      # stdin while it does, and the list the `/inbox` detour lists.
      #
      # Its own object because "read until the human types something the
      # record can carry" is not {HumanReplies}' business of routing an answer
      # to an asker: the detour, the refusal-and-retry, and the pairing all
      # belong to the READ, and the panel's note that the pair should be built
      # where the knowledge is points at exactly this seam.
      class Reply
        def initialize(tty:, conductor:, inbox:)
          @tty = tty
          @conductor = conductor
          @inbox = inbox
        end

        # The reply prompt of a PARKED set. `/inbox` detours to the drain for
        # THIS item -- the set the run is parked on, whose note the human is
        # looking at -- so the document they read and the set their reply
        # answers are one question. It used to drain for whatever was oldest
        # and hand the answer back to be resolved against this item, which was
        # invisible while an answer was an opaque line and is not any more:
        # the prose answer NAMES the questions it answers, so the wrong set
        # received a reply naming another set's ids and the set the human
        # actually read stayed pending.
        #
        # Any other line answers this item directly, which is the no-inbox
        # fallback and the common path.
        #
        # @return [Array(String, InboxItem)] the answer, and the item it answers
        def for(item) = accepted { read(item) }

        # `/inbox` at `you>`: nothing is parked on this read, so one typed
        # answer answers the oldest item listed.
        def at_prompt = accepted { drained(answering: @inbox.oldest) }

        private

        # The read routes through the conductor's #read_reply (not the tty
        # directly) so the conductor KNOWS Reline owns stdin for the span and
        # suppresses its countdown ticker's render + key-read. `.to_s` is
        # load-bearing: EOF returns nil, and an empty answer is honest where
        # `Tool::Result.ok(nil)` would raise.
        # `legible` runs BEFORE the `/inbox` test, not after: `String#strip` on
        # invalid bytes raises Encoding::CompatibilityError, which is not the
        # ArgumentError the refusal path rescues, so it would climb past every
        # guard here to `#serve_question`'s ensure -- retiring the line while
        # leaving the promise pending, which is the exact end state `legible`
        # exists to prevent, reached one line above it.
        def read(item)
          line = legible(@conductor.read_reply(@tty, "human> ").to_s)
          return [line, item] unless line.strip == "/inbox"

          drained(answering: item)
        end

        # The drain answers the item it was NAMED, and that item is what the
        # answer is paired with here -- the caller's own object, never one
        # shipped out to the frontend and back.
        def drained(answering:)
          answer = ""
          reader = ->(prompt) { @conductor.read_reply(@tty, prompt) }
          @tty.drain_inbox(@inbox, answering:, reader:) { |typed| answer = typed }
          [answer, answering]
        end

        # Read until the human types something the record can carry. A refusal
        # is NOT a dead question -- the set is still pending and a shorter or
        # legible reply still answers it -- so the reason is rendered where
        # they typed it and the prompt comes round again. Every other exit
        # from a served question means the line is dead, which is what lets
        # {HumanReplies#serve_question}'s `ensure` retire unconditionally.
        #
        # The drain does this for itself ({Frontend::TTY::Inbox#accepted}), so
        # in practice this catches the INLINE prompt -- where a line that
        # cannot be written used to reach the Store, raise there, and take the
        # `ensure` with it.
        def accepted(&read) = Enumerator.produce { refusable(&read) }.lazy.compact.first

        def refusable
          yield
        rescue ArgumentError => e
          @tty.render_error(e.message)
          nil
        end

        # What the Store can hold, checked where the human can still retype
        # it: invalid UTF-8 used to reach the event write and raise there,
        # which is the same dead line by a longer route.
        def legible(line) = Question::Rules.prose(line, "a typed reply")
      end
    end
  end
end
