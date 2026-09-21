# frozen_string_literal: true

# {RpcThread} must exist before the `class Neovim` body below opens, because
# that body defines {Neovim::FrontendListener} against it. {RuntimeLoader} comes
# first for the same reason, one level down: {RpcThread}'s body names it.

module Lain
  module Frontend
    # The Neovim frontend: a second surface on the same {Lain::Channel} the {TTY}
    # drains. The agent knows about neither frontend -- it only pushes attributed
    # {Lain::Telemetry} onto the Channel, and nothing here reaches back into the
    # agent. The resend dispatch does not breach that: the frontend offers a
    # rebuilt Request to an INJECTED bridge duck, and only that CLI-owned object
    # touches the Agent it was built over.
    #
    # Shape mirrors {TTY}: a background thread drains the injected Channel. The
    # twist is that rendering touches nvim, and the neovim gem's session may be
    # touched only from the one thread that owns it. So this drain thread does
    # NOT render; it turns each event into plain lines and hands them to the
    # {RpcThread}, sole owner of every nvim call -- one editor thread fed by an
    # inbox, the actor shape the gem's single-threaded session forces.
    class Neovim
      # The Ruby<->runtime.lua handshake token for a chunk: a blake3 digest of the
      # exact bytes that go to `nvim_exec_lua`.
      #
      # DERIVED, never declared, and that is the whole of the design. What stood
      # here was an integer and a hundred lines of changelog, bumped by hand in
      # two places whenever the injected surface changed -- and a number somebody
      # has to remember to bump is a number somebody forgets. A digest of the
      # runtime cannot be forgotten on a change, because a change IS the digest
      # moving. The fifteen entries it replaced say what each bump bought and are
      # kept in docs/neovim-protocol-history.md; git has the diffs.
      #
      # METHODS rather than a constant: {Lain::Ext} owns blake3, and a digest
      # frozen into a constant at class-body time would be one taken before the
      # caller has the bytes it is actually about to inject.
      #
      # Takes the source rather than reading it, so {RpcThread#attach} can digest
      # the bytes it holds in its hand instead of a second read that could have
      # changed underneath -- one rule, and the one place it matters calls it
      # with what it is actually injecting.
      #
      # @param source [String] the chunk as it will be injected
      # @return [String] 64 hex characters
      def self.protocol_of(source) = Ext.blake3_hex(source)

      # The token for the runtime as it stands on disk right now.
      #
      # Read through the loader on every call rather than memoized, for
      # {RuntimeLoader#source}'s own reason: the runtime is a thing on disk, not a
      # thing the process learned at boot.
      #
      # @return [String] 64 hex characters
      def self.protocol = protocol_of(RuntimeLoader.new.source)

      # Seconds teardown waits on the resend worker before giving up the join. A
      # bridged offer holds that worker for a whole model round trip, so a bare
      # `join` is UNBOUNDED and a wedged provider would strand the editor's exit.
      # The inbox is already closed by then, so the worker exits the instant its
      # in-flight offer returns; a timed-out one exits on its own once the round
      # trip settles, its post-teardown pop meeting a closed queue.
      TEARDOWN_GRACE = 5

      # One of the three background threads died and {#run}'s block had already
      # returned without raising of its own. Wraps whatever StandardError killed
      # the thread so a caller's `rescue Lain::Error` presents editor-session
      # loss as a clean notice rather than a raw IOError with a backtrace at
      # exit. The message NAMES the dead thread, because exe/lain forwards it
      # verbatim and a bare "Broken pipe" with no source is not a notice a human
      # can act on. The original rides `cause`.
      class SessionFailure < Lain::Error; end

      # No changeset review is open in THIS editor -- what both review WRITES get
      # until one is bound. It answers a SENTENCE rather than nil, because nil
      # means "taken" to the editor, which clears 'modified' and reports the
      # human's note recorded when nothing here has anywhere to put it.
      #
      # Deliberately NOT {RpcThread::Listener::Null::UNREVIEWABLE}'s sentence:
      # that one is a frontend wiring no review surface at all, this one a live
      # editor with no review OPEN -- the ordinary state of every session that
      # has not started one.
      module NoReviewWrites
        UNOPENED = "no review is open here -- open one first; your text is untouched"

        def self.wrote_annotation(_note) = UNOPENED
        def self.wrote_verdict(_verdict) = UNOPENED
        def self.wrote_close = UNOPENED
      end

      # @param channel [Lain::Channel] drained by {#run}'s background thread
      # @param socket_path [String] a listening nvim's unix socket
      # @param version [String] the gem version, surfaced by :LainVersion
      # @param protocol [String, nil] the runtime handshake token. nil is the
      #   answer -- {RpcThread} digests the bytes it is about to inject, which is
      #   the only reading that cannot go stale. A String overrides it, which is
      #   how a spec stands an editor up holding a runtime this gem did not write.
      # @param store [Lain::Store] backs the live Timeline behind
      #   lain://timeline. Defaults to {Buffers::DetachedStore}: an un-wired
      #   frontend renders the timeline as unavailable rather than holding a
      #   real-but-disconnected store that crashes on the first
      #   {Telemetry::TurnUsage}.
      # @param session [Lain::Session] the run's live reminders source, behind
      #   lain://workspace
      # @param journal [#<<] where a resent request is recorded, the same duck
      #   the Agent's accounting/journal middleware write to; the Null channel by
      #   default, so an un-wired frontend records resends nowhere.
      # @param resend_bridge [#offer] the dispatch seam: the resend worker
      #   offers each rebuilt Request here after journaling the projection.
      #   {Unbridged} by default, so plain --nvim keeps the pure
      #   projection-only resend.
      # @param compose_notify [#call] where {Compose}'s notices go. The
      #   TERMINAL's warning renderer, not the editor's journal: every notice
      #   it can produce -- a timed-out round trip, an editor that stopped
      #   taking the draft -- is news for the human sitting at the prompt, and
      #   the editor is by definition the thing that just failed to answer.
      #   Silent by default, so an un-wired frontend reports nowhere.
      # @param question_notify [#call] where {QuestionView}'s one notice goes
      #   -- an abandoned question buffer, which has no caller to return
      #   to. The terminal's warning renderer for `compose_notify`'s reason, and
      #   a SEPARATE seam because the two say different things about different
      #   surfaces; a caller wiring both hands over the same renderer.
      # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
      # @param epic [#lines] what lain://status draws: {StatusView::Mounted}
      #   for a chat seated in an epic, which {CLI::Wiring} resolves, and
      #   {StatusView::Unmounted} by default, whose buffer says none is mounted
      def initialize(channel:, socket_path:, version: Lain::VERSION, protocol: nil,
                     store: Buffers::DetachedStore.instance, session: Session::Null.instance,
                     journal: Channel::Null.instance, resend_bridge: Unbridged, epic: StatusView::Unmounted,
                     compose_notify: SILENT, question_notify: SILENT,
                     render_capacity: RenderQueue::DEFAULT_CAPACITY)
        @channel = channel
        # Bound long after this returns (see {#bind_changeset_review}), so it
        # has to hold its Null from the start: {FrontendListener} resolves it
        # per call and the first review write may arrive before anyone opens a
        # review at all.
        @changeset_review = NoReviewWrites
        # Edited lain://request lines land here from the RPC thread's inbound
        # dispatch and are drained by the resend worker ({#resend_loop}). An
        # unbounded Thread::Queue so {FrontendListener#resend} never blocks the
        # RPC thread; a human can't flood single :LainResend invocations, so
        # unbounded is safe.
        @resend_inbox = Thread::Queue.new
        @resend_failure = nil
        @rpc = build_rpc(socket_path:, version:, protocol:, render_capacity:)
        build_round_trips(compose_notify:, question_notify:)
        # `questions:` is what makes the inbox's `<CR>` a real gesture rather
        # than a refusal: the view that resolves the line needs the surface the
        # set opens in.
        #
        # `approval_view:` hands over the SAME object {#approval_view} exposes.
        # {Surfaces#prime} draws the buffer; the `y` on one of its rows resolves
        # through whichever view {CLI::Repl} bound, which is this one. Two views
        # would mean the buffer on screen and the object answering gestures had
        # drifted apart silently, with every live assertion still passing --
        # which is why {Surfaces} takes it WITHOUT a default.
        @surfaces = Surfaces.new(rpc: @rpc, store:, session:, journal:, questions: @question_view,
                                 approval_view: @approval_view, epic:)
        @resender = Resender.new(channel:, rpc: @rpc, bridge: resend_bridge,
                                 request_buffer: @surfaces.request_buffer)
      end

      # The C-g compose round trip's Ruby end, for the terminal prompt to
      # register a key action against and to settle in its own loop. Exposed
      # like {#command_inbox}: a collaborator, never the session.
      # @return [Compose]
      attr_reader :compose

      # The question round trip's Ruby end, for whoever holds a pending
      # {Question::Set} to open and for the editor's write to answer. A
      # collaborator, never the session.
      # @return [QuestionView]
      attr_reader :question_view

      # The editor's surface on the approval queue. Built HERE, so it exists
      # exactly when an editor does: a headless chat constructs no frontend, so
      # there is nothing to bind and nothing spawns a watcher.
      # @return [ApprovalView]
      attr_reader :approval_view

      # Commands the editor invoked, enqueue-and-acked by the RpcThread, for an
      # agent-side consumer to drain -- and the way back for a gesture that had
      # to be refused. A collaborator, never the session.
      # @return [CommandInbox]
      attr_reader :command_inbox

      # The view set the editor's gestures resolve THROUGH: an `open` names a
      # line of a rendering only {InboxView} can identify, a `pin` names a line
      # of a chain only {Buffers::TimelineView} can. Exposed because the consumer
      # that pops the rail is agent-side and holds neither the frontend nor the
      # session.
      # @return [Buffers]
      def buffers = @surfaces.buffers

      # Hand a file on disk to the human, in a focused split, stamped with the
      # review it belongs to. The editor answers on {#command_inbox} with
      # `["review_done", [generation, epic_slug, annotations]]`.
      #
      # @return [String, nil] nil when the open landed, else the notice saying
      #   no editor took it (see {RenderInlet})
      def open_review(path, generation, epic_slug:) = @rpc.open_review(path, generation, epic_slug)

      # Where a changeset is DRAWN in this editor, and the rendering its
      # gestures resolve through: the review's outbound half as
      # {Lain::Review::Surface}'s port plus one view, rather than as four rails
      # a caller has to assemble.
      #
      # ONE pair for the life of the session, because a rendering STAMP is only
      # resolvable by the view that issued it: a caller building its own
      # {Lain::Review::Surface::Neovim} over this inlet would get a second view
      # whose stamps this one's gestures could never resolve, which is a silent
      # wrong-row rather than an error.
      #
      # Memoized rather than built in {#initialize}, so a session that never
      # opens a review pays for neither.
      #
      # @return [Lain::Review::Surface::Neovim]
      def review_surface = @review_surface ||= Lain::Review::Surface::Neovim.new(rpc: @rpc, view: review_view)

      # The sidebar's rendering history, the line -> row index a `review_open` or
      # `review_mark` resolves against, and -- through {ChangesetDiff} -- where a
      # `<CR>` on a row actually lands.
      #
      # The diff surface is wired HERE and only here, which is what makes
      # {ReviewView::Unwired}'s refusal unreachable from a review drawn in a real
      # editor. What the caller supplies instead is the CHANGESET, through
      # {ReviewView#reviewing}, once per round.
      #
      # @return [ReviewView]
      def review_view = @review_view ||= ReviewView.new(changesets: ChangesetDiff.new(rpc: @rpc))

      # The object whose answer is what a `review_annotate` or `review_verdict`
      # `:w` succeeds or fails with. Bound after construction because the session
      # that owns a changeset is built by whoever opened the review, often
      # mid-run.
      #
      # The twin of {CLI::HumanReplies#bind_changeset_review}, and a wiring binds
      # ONE object to both: the same review is reached from two rails, which
      # differ only in whether lain can refuse what arrives on them.
      #
      # @param review [#wrote_annotation, #wrote_verdict, #wrote_close, nil] nil restores
      #   {NoReviewWrites}, so closing a review is a bind like any other and no
      #   caller writes an unbind of its own
      # @return [void]
      def bind_changeset_review(review)
        @changeset_review = review || NoReviewWrites
      end

      # Attach, start draining the Channel into the editor, yield self, and ALWAYS
      # tear both threads down -- even on a raising block, so a wedged agent never
      # strands the editor half-rendered. If the RPC thread died mid-session
      # (editor gone), its failure re-raises here AFTER teardown, so the loss is
      # loud without ever masking the block's own exception.
      def run(&block)
        drainer = resender = nil
        begin
          @rpc.start
          drainer = Thread.new { drain }
          resender = Thread.new { resend_loop }
          yield(self)
        ensure
          teardown(drainer, resender)
        end
        reraise_recorded_failure
      end

      private

      # Every hand-off the RPC thread makes back into {Neovim}. {#died} makes
      # RPC-thread death observable: the channel closes, so the drainer exits and
      # producers meet ClosedQueueError instead of feeding a zombie. Every method
      # here only ever enqueues or forwards, because a listener method that
      # blocked would block the editor's whole session.
      class FrontendListener < RpcThread::Listener
        # `compose:` is a bound accessor, not the {Compose} collaborator itself:
        # {Compose} is built AFTER the RPC thread, which it takes as its own
        # editor inlet, so resolving it fresh on every call is what lets the two
        # be constructed in either order.
        #
        # @param channel [Lain::Channel] closed on RPC-thread death
        # @param compose [#call] returns the live {Compose}
        # @param resend [#call] hands edited lain://request lines to the resend worker
        # @param question [#call] returns the live {QuestionView}, bound for
        #   `compose:`'s reason -- it too is built after the RPC thread
        # @param review [#call] returns the bound changeset review, and this one
        #   is bound LATEST of all: not merely after the RPC thread but after
        #   the whole frontend is running, whenever a human opens a review. A
        #   held reference would be {NoReviewWrites} for the life of the session
        #   and every note would be refused; resolving per call is the only
        #   shape that sees a review opened mid-run.
        def initialize(channel:, compose:, resend:, question:, review:)
          super()
          @channel = channel
          @compose = compose
          @resend = resend
          @question = question
          @review = review
        end

        def died
          @channel.close unless @channel.closed?
        end

        # Every hand-off but {#died} is one delegation and is written as one:
        # the guard is what keeps that method a block.
        def resend(lines) = @resend.call(lines)
        def compose_written(lines, generation) = @compose.call.wrote(lines, generation)
        def compose_abandoned(generation) = @compose.call.abandoned(generation)

        # ANSWERS: its return value is what the editor's `:w` succeeds or fails
        # with -- nil once the answer is handed on, else the failure naming the
        # line the human has to go fix.
        def question_written(lines, digest) = @question.call.wrote(lines, digest)
        def question_abandoned(digest) = @question.call.abandoned(digest)

        # {#question_written}'s shape and reason: the review answers its own
        # refusal rather than raising one, since a raise reaches
        # {RpcThread#answer}, which answers the editor and then re-raises,
        # ending the session over a note.
        def review_annotated(note) = @review.call.wrote_annotation(note)
        def review_verdict_given(verdict) = @review.call.wrote_verdict(verdict)
        def review_close_given = @review.call.wrote_close
      end
      private_constant :FrontendListener

      def build_rpc(socket_path:, version:, protocol:, render_capacity:)
        listener = FrontendListener.new(channel: @channel, compose: method(:compose), resend: method(:post_resend),
                                        question: method(:question_view), review: method(:changeset_review))
        RpcThread.new(socket_path:, version:, protocol:, render_capacity:, listener:)
      end

      # Private because {#bind_changeset_review} is the whole of this
      # collaborator's public surface. `Object#method` reaches a private method,
      # so the binding is unaffected.
      attr_reader :changeset_review

      # The collaborators that take the RPC THREAD as their editor inlet, which
      # is why they are built after it and in one place. {FrontendListener} holds
      # bound accessors rather than these objects, so the listener can still be
      # built first.
      #
      # {QuestionView}'s `submit` is the rail's own push: it runs on the RPC
      # thread, inside the editor's write, under that view's lock, so it must be
      # an unbounded never-closed queue push -- something that cannot park and
      # cannot raise -- and never a promise resolution. {ApprovalView} takes
      # nothing of the sort, because its answer resolves a promise on the
      # consumer's own fiber rather than travelling to one.
      def build_round_trips(compose_notify:, question_notify:)
        @command_inbox = CommandInbox.new(inbox: @rpc.command_inbox, rpc: @rpc)
        @compose = Compose.new(rpc: @rpc, notify: compose_notify)
        @question_view = QuestionView.new(rpc: @rpc, notify: question_notify, submit: @command_inbox.method(:answered))
        @approval_view = ApprovalView.new(rpc: @rpc)
      end

      # The failures the background threads RECORDED rather than raised -- a
      # raise on a background thread is silent, and a join re-raise inside the
      # ensure would clobber the block's own exception -- surfaced only after
      # teardown completes, labeled with WHICH thread died.
      def reraise_recorded_failure
        label, failure = recorded_failures.first
        raise SessionFailure, "#{label}: #{failure.message}", cause: failure if failure
      end

      # Insertion order is priority order: RPC-thread death outranks worker
      # death when both happened -- a dead editor is the bigger loss.
      def recorded_failures
        { "nvim rpc thread died" => @rpc.failure,
          "render drain died" => @drain_failure,
          "resend worker died" => @resend_failure }.compact
      end

      # Close-drain-stop, in that order: closing the channel lets the drainer's
      # blocking drain return; closing the resend inbox lets the resend worker's
      # blocking pop return. Only returned workers make stopping the RPC thread
      # race-free.
      #
      # The joins are WRAPPED, not bare. Both siblings already record-and-die, so
      # a join raising here should never happen -- but a bare `drainer&.join`
      # that did would raise inside this `ensure`-called method and skip
      # `@rpc.stop`, leaking the RPC thread AND clobbering {#run}'s block's own
      # exception. Deferring keeps `@rpc.stop` unconditional.
      def teardown(drainer, resender)
        @channel.close unless @channel.closed?
        @resend_inbox.close
        join_deferring_failure(drainer) { |e| @drain_failure ||= e }
        # Bounded: the resend worker may be inside a bridged round trip,
        # so its join is capped -- teardown returns even if the wire is slow,
        # and the worker exits itself once the offer settles.
        join_deferring_failure(resender, timeout: TEARDOWN_GRACE) { |e| @resend_failure ||= e }
        @rpc.stop
      end

      def join_deferring_failure(thread, timeout: nil)
        thread&.join(timeout)
      rescue StandardError => e
        yield e
      end

      # An unrescued render exception (a malformed event's NoMethodError, say)
      # must not kill this thread in silence -- that would stop the Channel
      # draining with nobody left to notice, and a producer would eventually
      # wedge against a full queue. Same record-and-die shape as the resend
      # worker ({#record_worker_death}); the drainer's inlet IS the channel.
      def drain
        @surfaces.prime
        @channel.drain { |event| @surfaces.post(event) }
      rescue StandardError => e
        @drain_failure = record_worker_death(e)
      end

      # The resend worker: a synthetic PRODUCER, not a renderer. Each
      # edited-buffer hand-off becomes a fresh record pushed onto the SAME
      # Channel an agent request rides, so the drainer diffs and re-renders it
      # with no special case, and is THEN offered to the injected bridge.
      #
      # A thread of its own, and NOT the RPC thread: that thread drains the
      # render queue, so if it blocked pushing onto a full Channel the drainer --
      # blocked posting to a full render queue -- would deadlock it. A bridged
      # offer can also hold this thread for a whole model round trip.
      def resend_loop
        while (lines = @resend_inbox.pop)
          @resender.deliver(@surfaces.resend(lines))
        end
      rescue ClosedQueueError
        # Teardown closed the Channel out from under an in-flight resend; a
        # cut-short resend at shutdown is fine (mirrors {#post}'s own rescue).
        nil
      rescue StandardError => e
        # A raising journal write (this worker's native failure) must not die
        # silently while the inbox black-holes every later :LainResend.
        @resend_failure = record_worker_death(e, inlet: @resend_inbox)
      end

      # The record-and-die shape the two Neovim-owned worker threads share: hand
      # back the failure for the caller's own slot, where
      # {#reraise_recorded_failure} picks it up AFTER teardown; close the dead
      # worker's inlet so nothing queues behind a dead consumer; and close the
      # channel so the loss is observable at once. Rescuing rather than
      # re-raising is what keeps teardown's joins from raising INSIDE the ensure
      # and clobbering the block's exception.
      #
      # {RpcThread#record_death} is deliberately NOT folded in: before
      # {RpcThread#start} has returned its failure rides the @ready handshake
      # back to the caller's thread instead of a recorded slot, so unifying would
      # mean parameterizing away everything the method does.
      def record_worker_death(error, inlet: @channel)
        inlet.close unless inlet.closed?
        @channel.close unless @channel.closed?
        error
      end

      # {FrontendListener#resend}'s hand-off. A push onto a closed inbox (the
      # worker already died) is dropped, not raised: this runs on the RPC
      # thread inside inbound dispatch, and raising there would kill the whole
      # editor session over a resend whose loss {#run} already re-raises loudly.
      def post_resend(lines)
        @resend_inbox.push(lines)
      rescue ClosedQueueError
        nil
      end
    end
  end
end

# LAST: it builds the three views above, so every one of them must exist by the
# time its body is read.
