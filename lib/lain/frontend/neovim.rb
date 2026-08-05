# frozen_string_literal: true

# {RpcThread} (and the {RpcThread::Listener} contract this file's
# {Neovim::FrontendListener} subclasses) must exist before the `class Neovim`
# body below opens, because that body defines FrontendListener against it --
# the same "load it early" exception {Context::REQUIRES} documents, not a
# departure from the index owning requires (this is still the index; only the
# ORDER moved).
#
# {RuntimeLoader} comes first for the same reason, one level down: {RpcThread}'s
# body names it.
require_relative "neovim/runtime_loader"
require_relative "neovim/rpc_thread"

module Lain
  module Frontend
    # The Neovim frontend: a second surface on the same {Lain::Channel} the {TTY}
    # drains. The agent knows about neither frontend -- it only pushes attributed
    # {Lain::Telemetry} onto the Channel, and nothing here ever reaches back into
    # the agent. (T18's resend dispatch does not breach that: the frontend offers
    # a rebuilt Request to an INJECTED bridge duck, and only that CLI-owned
    # object -- {CLI::ResendBridge} -- touches the Agent it was built over.)
    #
    # Shape mirrors {TTY}: a background thread drains the injected Channel. The
    # twist is that rendering touches nvim, and the neovim gem's session may be
    # touched only from the one thread that owns it ({RpcThread}). So this drain
    # thread does NOT render; it turns each event into plain lines and hands them
    # to the RpcThread, which is the sole owner of every nvim call. One editor
    # thread fed by an inbox -- the actor shape the gem's single-threaded session
    # forces (see {RpcThread} and planning/interface-integration.md).
    class Neovim
      # The Ruby<->runtime.lua contract version, compared at attach against the
      # copy hardcoded in runtime.lua (RUNTIME_PROTOCOL). Bump BOTH when the
      # injected protocol changes -- commands, render entry points, handshake
      # shape -- and never for a gem release: the gem version is display
      # (:LainVersion), this is compatibility, and conflating them made every
      # future gem bump a false mismatch warning.
      # The history below says WHAT CHANGED and names no card. It is read to
      # date a change and to tell whether a running runtime has some feature,
      # and a card id answers neither: the ids are chunk-local and repeat, so
      # this list once carried two T15s and two T16s from different chunks.
      # "2": :LainReply and the inbox drain autocmd.
      # "3": the User LainAttach/LainRender events, b:lain_view on every
      #   lain:// buffer, lain://workspace in the runtime's buffer set, and the
      #   six documented lain* syntax groups.
      # "4": the lain://compose round trip -- the set_compose render entry
      #   point, and the "compose"/"compose_abandon" commands its
      #   BufWriteCmd/BufUnload autocmds send back.
      # "5": the review surface -- the open_review/review_refused render entry
      #   points, :LainAnnotate and :LainReviewDone, and the
      #   b:lain_review_generation / b:lain_review_epic_slug stamps. Backfilled:
      #   d125aba shipped the bump without its history line, and a history that
      #   skips a version is worse than none.
      # "6": the lain://question round trip -- the set_question render entry
      #   point, b:lain_question_digest, the question fold predicate, and the
      #   "question"/"question_abandon" commands. "question" is the FIRST
      #   command whose answer is not an ack: its response is the write's
      #   verdict (see {RpcThread#answer}).
      # "7": the inbox's open gesture -- :LainOpen and the "open" command it
      #   sends, carrying the CURSOR LINE (:LainPin's rule, since the inbox row
      #   renders no digest), with <CR> and `r` both bound to it.
      # "8": set_view gained an OPTIONAL third argument, the rendering stamp it
      #   writes to b:lain_view_generation, and "open"'s second argument moved
      #   from the line COUNT to that stamp. The count aliased between
      #   renderings of equal height, which opened the wrong document and
      #   reported it as a success; the stamp cannot.
      # "9": the changeset review surface. Render entry points
      #   __lain.set_review (the sidebar), __lain.open_changeset (the old/new
      #   diff pair) and __lain.set_thread (a note's conversation in the pane
      #   you are not reading); __lain.review_layout / __lain.review_place, the
      #   tabpage slots those place through; __lain.review_notes_held; and the
      #   __lain.set_review_diagnostics / __lain.refresh_review_diagnostics /
      #   __lain.review_diagnostics_tracked projection. Commands
      #   :LainReviewOpen, :LainNote, :LainNoteDone and :LainThread. The only
      #   open gesture is :LainReviewOpen -- the diff-open command this chunk's
      #   plan assumed was dropped rather than added, since no gesture stood
      #   behind it, and a history may not name a command that does not exist.
      #   Two things a config hooking protocol 3 must re-read. b:lain_view no
      #   longer names a VIEW: the diff pair's old side reuses the named-buffer
      #   constructor, so it carries lain://review/OLD/<path> and differs per
      #   FILE. Dispatch on b:lain_review_side / b:lain_review_revision /
      #   b:lain_review_path instead -- stamped on both sides of the live pair
      #   and WITHDRAWN when you move off a file, so a gesture reads a variable
      #   rather than parsing a buffer name back apart.
      # "10": the two changeset-review gestures that had been wired Ruby-side
      #   since 9 with no key or command able to send them. :LainReviewMark
      #   {state} sends "review_mark" -- the cursor's line, the state, and
      #   b:lain_view_generation -- bound in lain://review as `x` (reviewed) and
      #   `u` (unreviewed), ONE KEY PER STATE because the state rides the wire
      #   and a toggle computed from a rendering that has since moved flips the
      #   wrong hunk in silence. :LainReviewVerdict {verdict} sends
      #   "review_verdict", the first ANSWERED verb outside a review buffer: its
      #   return leg is what the command fails with, and it names
      #   Lain::Review::VERDICTS rather than restating the vocabulary in lua. No
      #   new render entry point -- a refused mark comes back on
      #   __lain.review_refused, which 9 already shipped.
      # "11": one lain per editor. The injected chunk now RETURNS -- nil once it
      #   has loaded, and a refusal table BEFORE it loads anything at all when a
      #   live RPC channel already owns this editor, which {RpcThread#attach}
      #   raises as {SocketOwned}. The owner is named by the runtime's
      #   __lain.channel, this table's first non-function member: the channel id
      #   was a chunk local nothing could read, so a re-injection silently
      #   repointed every :Lain* command at a channel that then died, and no
      #   gesture, inspection or repair could see why. LIVENESS, never presence
      #   -- a marker left behind by a lain that has gone away must not cost the
      #   human their editor, so the recorded channel is asked of nvim rather
      #   than trusted, and nothing has to be cleaned up on the way out.
      # "12": the approval surface -- the one {Frontend::ApprovalPolicy}'s own
      #   class comment named and nothing ever wrote. Render entry point
      #   __lain.set_approval draws lain://approval, stamping
      #   b:lain_view_generation with the rendering and b:lain_approval_rows
      #   with how many of its leading lines are answerable calls (so the keys
      #   below are inert on the hint and the empty state without a lua-side
      #   pattern match on rendered text). :LainApprove and :LainDeny answer the
      #   call under the cursor, bound in that buffer as `y` and `n`; both send
      #   the "approval" verb carrying the line, the verdict and the stamp. ONE
      #   COMMAND PER VERDICT, protocol 10's rule for the same reason: the
      #   verdict rides the wire, because a decision computed from a rendering
      #   that has since moved answers the neighbouring call in silence.
      #   ACKED, never answered -- a verdict resolves a promise, which must
      #   happen on the reactor, so it rides the command inbox to the consumer
      #   fiber rather than being served on the RPC thread.
      PROTOCOL = "12"

      # Seconds teardown waits on the resend worker before giving up the join
      # (S3). Since T18 a bridged offer holds that worker for a whole model
      # round trip, so a bare `join` at teardown is UNBOUNDED -- a wedged or
      # slow provider would strand the editor's exit. The inbox is already
      # closed by the time the join runs, so the worker exits the instant its
      # in-flight offer returns; this bound only caps how long teardown blocks
      # for that return, and a timed-out worker exits on its own once the round
      # trip settles (its post-teardown render/pop meets a closed queue and is
      # swallowed, never a wedge -- see {#resend_loop}).
      TEARDOWN_GRACE = 5

      # One of the three background threads (the RPC thread, the drain, or the
      # resend worker -- see {#reraise_recorded_failure}) died and {#run}'s
      # block had already returned without raising of its own by the time
      # teardown finished. Wraps whatever StandardError killed the thread so a
      # caller's `rescue Lain::Error` (the exe's own convention -- see
      # exe/lain) presents editor-session loss as a clean notice, not a raw
      # IOError/NoMethodError with a backtrace at exit (T9). The message NAMES
      # the dead thread -- exe/lain forwards it verbatim, and a bare "Broken
      # pipe" with no source is not a notice a human can act on. The original
      # rides `cause`, so nothing about the underlying failure is actually
      # lost -- only what reaches the human by default is tamed.
      class SessionFailure < Lain::Error; end

      # No changeset review is open in THIS editor (T11) -- the answer both
      # review WRITES get until one is bound. A Null rather than a nil check for
      # {CLI::HumanReplies::NoReview}'s reason, and it answers a SENTENCE rather
      # than nil for {RpcThread::Listener::Null::UNANSWERABLE}'s: nil means
      # "taken" to the editor, which clears 'modified' and reports the human's
      # note recorded when nothing on this side has anywhere to put it.
      #
      # Its sentence is deliberately NOT
      # {RpcThread::Listener::Null::UNREVIEWABLE}'s. That one is a frontend
      # wiring no review surface at all; this one is a live editor with no
      # review OPEN, which is the ordinary state of every session that has not
      # started one. Two different facts, and two different things for the human
      # to do about them.
      module NoReviewWrites
        UNOPENED = "no review is open in this editor, so there is nothing to record this against -- " \
                   "nothing was submitted and your text is untouched"

        def self.wrote_annotation(_note) = UNOPENED
        def self.wrote_verdict(_verdict) = UNOPENED
      end

      # @param channel [Lain::Channel] drained by {#run}'s background thread
      # @param socket_path [String] a listening nvim's unix socket
      # @param version [String] the gem version, surfaced by :LainVersion
      # @param protocol [String] the runtime handshake token (see {PROTOCOL})
      # @param store [Lain::Store] backs the live Timeline (4-2.2's
      #   lain://timeline view). Defaults to {Buffers::DetachedStore}: an
      #   un-wired frontend renders the timeline as unavailable rather than
      #   holding a real-but-disconnected store that crashes on the first
      #   {Telemetry::TurnUsage} -- see {Buffers}.
      # @param session [Lain::Session] the run's live reminders source (4-2.2's
      #   lain://workspace view; see {Buffers})
      # @param journal [#<<] where a resent request is recorded (4-2.3), the same
      #   duck the Agent's accounting/journal middleware write to; the Null
      #   channel by default, so an un-wired frontend records resends nowhere.
      # @param resend_bridge [#offer] T18's dispatch seam: the resend worker
      #   offers each rebuilt Request here after journaling the projection.
      #   {Unbridged} by default, so plain --nvim keeps the pure
      #   projection-only resend.
      # @param compose_notify [#call] where {Compose}'s notices go (T15). The
      #   TERMINAL's warning renderer, not the editor's journal: every notice
      #   it can produce -- a timed-out round trip, an editor that stopped
      #   taking the draft -- is news for the human sitting at the prompt, and
      #   the editor is by definition the thing that just failed to answer.
      #   Silent by default, so an un-wired frontend reports nowhere.
      # @param question_notify [#call] where {QuestionView}'s one notice goes
      #   (T12) -- an abandoned question buffer, which has no caller to return
      #   to. The terminal's warning renderer for `compose_notify`'s reason, and
      #   a SEPARATE seam because the two say different things about different
      #   surfaces; a caller wiring both hands over the same renderer.
      # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
      def initialize(channel:, socket_path:, version: Lain::VERSION, protocol: PROTOCOL,
                     store: Buffers::DetachedStore.instance, session: Session::Null.instance,
                     journal: Channel::Null.instance, resend_bridge: Unbridged,
                     compose_notify: Compose::SILENT, question_notify: QuestionView::SILENT,
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
        # set opens in, and it is built above (it takes the RPC thread).
        @surfaces = Surfaces.new(rpc: @rpc, store:, session:, journal:, questions: @question_view)
        @resender = Resender.new(channel:, rpc: @rpc, bridge: resend_bridge,
                                 request_buffer: @surfaces.request_buffer)
      end

      # The C-g compose round trip's Ruby end (T15), for the terminal prompt to
      # register a key action against and to settle in its own loop. Exposed
      # like {#command_inbox}: a collaborator, never the session.
      # @return [Compose]
      attr_reader :compose

      # The question round trip's Ruby end (T12), for whoever holds a pending
      # {Question::Set} to open and for the editor's write to answer. A
      # collaborator, never the session.
      # @return [QuestionView]
      attr_reader :question_view

      # The editor's surface on the approval queue (T36), for the repl to hand
      # a queue to watch and for the editor's gesture to answer through. A
      # collaborator, never the session -- and built HERE, so it exists exactly
      # when an editor does: a headless chat constructs no frontend, so there
      # is nothing to bind and nothing spawns a watcher.
      # @return [ApprovalView]
      attr_reader :approval_view

      # Commands the editor invoked, enqueue-and-acked by the RpcThread, for an
      # agent-side consumer to drain -- and the way back for a gesture that had
      # to be refused. A collaborator, never the session.
      # @return [CommandInbox]
      attr_reader :command_inbox

      # The view set the editor's gestures resolve THROUGH: an `open` names a
      # line of a rendering only {InboxView} can identify, a `pin` names a line
      # of a chain only {Buffers::TimelineView} can. Exposed for the same reason
      # {#command_inbox} is -- the consumer that pops the rail is agent-side and
      # holds neither the frontend nor the session -- and it is a collaborator,
      # never the session.
      # @return [Buffers]
      def buffers = @surfaces.buffers

      # Hand a file on disk to the human, in a focused split, stamped with the
      # review it belongs to (T16). The editor answers on {#command_inbox} with
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
      # Owned here for {#buffers}' reason -- every view this editor renders into
      # is the frontend's own -- and it is ONE pair for the life of the session,
      # because a rendering STAMP is only resolvable by the view that issued it.
      # A caller building its own {Lain::Review::Surface::Neovim} over this
      # inlet would get a second view, whose stamps this one's gestures could
      # never resolve; that is a silent wrong-row, not an error, so the pair is
      # not a caller's to assemble.
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
      # The diff surface is wired HERE and only here (T32a), which is what makes
      # {ReviewView::Unwired}'s refusal unreachable from a review drawn in a real
      # editor: it is built with the inlet this frontend already owns, so no
      # caller has to assemble one, and a caller that did would get a second view
      # whose stamps this one's gestures could never resolve (see
      # {#review_surface} for the whole of that argument). What the caller
      # supplies instead is the CHANGESET, through {ReviewView#reviewing}, once
      # per round.
      #
      # @return [ReviewView]
      def review_view = @review_view ||= ReviewView.new(changesets: ChangesetDiff.new(rpc: @rpc))

      # The changeset review this editor WRITES to (T11): the object whose
      # answer is what a `review_annotate` or `review_verdict` `:w` succeeds or
      # fails with. Bound after construction, and it has to be -- the session
      # that owns a changeset is built by whoever opened the review, long after
      # the frontend attached and often mid-run.
      #
      # The twin of {CLI::HumanReplies#bind_changeset_review}, and a wiring
      # binds ONE object to both: the same review is reached from two rails,
      # which differ only in whether lain can refuse what arrives on them. The
      # acked gestures (open, mark, ask) ride the command inbox to the consumer
      # fiber; these two are answered here, on the RPC thread, because their
      # return value IS the editor's response.
      #
      # @param review [#wrote_annotation, #wrote_verdict, nil] nil restores
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

      # {RpcThread::Listener}'s concrete implementation for this frontend
      # (T34): every hand-off the RPC thread makes back into {Neovim}, in one
      # object instead of four hand-defaulted lambdas. {#died} makes
      # RPC-thread death observable: the channel closes, so the drainer exits
      # and producers meet ClosedQueueError instead of feeding a zombie;
      # {Neovim#run} then re-raises the recorded failure. The compose pair is
      # T15's round trip -- the editor writing or abandoning lain://compose --
      # and every method here only ever enqueues or forwards, because a
      # listener method that blocked would block the editor's whole session
      # (see {RpcThread::Listener}'s own must-not-block note).
      class FrontendListener < RpcThread::Listener
        # `compose:` is a bound accessor ({Object#method}), not the {Compose}
        # collaborator itself: {Compose} is built AFTER the RPC thread (it
        # takes the thread as ITS OWN editor inlet -- see the `compose:` note on
        # {Neovim#initialize}), so resolving it fresh on every call is what lets
        # the two be constructed in either order, the same trick the closures
        # this replaces relied on.
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

        # The one hand-off that ANSWERS (T12): its return value is what the
        # editor's `:w` succeeds or fails with, and {QuestionView#wrote}
        # produces exactly that -- nil once the answer is handed on, else the
        # failure naming the line the human has to go fix.
        def question_written(lines, digest) = @question.call.wrote(lines, digest)
        def question_abandoned(digest) = @question.call.abandoned(digest)

        # The changeset review's two writes (T11), {#question_written}'s shape
        # for {#question_written}'s reason: the return value is what the human's
        # `:w` succeeds or fails with, so the review answers its own refusal
        # rather than raising one -- a raise here reaches {RpcThread#answer},
        # which answers the editor and then re-raises, ending the session over a
        # note. The note has already been read for SHAPE by
        # {Neovim::ReviewWrite}; what is left is whether THIS review can take
        # it, which only the session holding the changeset knows.
        def review_annotated(note) = @review.call.wrote_annotation(note)
        def review_verdict_given(verdict) = @review.call.wrote_verdict(verdict)
      end
      private_constant :FrontendListener

      def build_rpc(socket_path:, version:, protocol:, render_capacity:)
        listener = FrontendListener.new(channel: @channel, compose: method(:compose), resend: method(:post_resend),
                                        question: method(:question_view), review: method(:changeset_review))
        RpcThread.new(socket_path:, version:, protocol:, render_capacity:, listener:)
      end

      # What {FrontendListener}'s `review:` accessor is bound to. Private
      # because {#bind_changeset_review} is the whole of this collaborator's
      # public surface -- a reader beside a binder would be a second way to ask
      # the same question. `Object#method` reaches a private method, so the
      # binding is unaffected.
      attr_reader :changeset_review

      # The three collaborators that take the RPC THREAD as their editor inlet,
      # which is the whole reason they are built after it and in one place: the
      # rail both directions of a gesture ride, and the two round trips whose
      # answers come back along it. {FrontendListener} holds bound accessors
      # rather than these objects, so the listener can still be built first (see
      # its own comment).
      #
      # {QuestionView}'s `submit` is the rail's own push: it runs on the RPC
      # thread, inside the editor's write, under that view's lock, so it must be
      # an unbounded never-closed queue push -- something that cannot park and
      # cannot raise -- and never a promise resolution.
      #
      # {ApprovalView} is here for the same reason and takes nothing else: it
      # has no submit rail, because its answer resolves a promise on the
      # consumer's own fiber rather than travelling to one.
      def build_round_trips(compose_notify:, question_notify:)
        @command_inbox = CommandInbox.new(inbox: @rpc.command_inbox, rpc: @rpc)
        @compose = Compose.new(rpc: @rpc, notify: compose_notify)
        @question_view = QuestionView.new(rpc: @rpc, notify: question_notify, submit: @command_inbox.method(:answered))
        @approval_view = ApprovalView.new(rpc: @rpc)
      end

      # The failures the background threads RECORDED rather than raised (a raise
      # on a background thread is silent, and a join re-raise inside the ensure
      # would clobber the block's own exception), surfaced only after teardown
      # completes -- wrapped in {SessionFailure}, labeled with WHICH thread
      # died, so this is a clean, actionable notice rather than a raw re-raise
      # with a backtrace (T9's AC4).
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
      # blocking pop return (and a resent event mid-push meets ClosedQueueError,
      # never a wedge). Only returned workers make stopping the RPC thread
      # race-free.
      #
      # The joins are wrapped, not bare: both siblings already record-and-die
      # rather than dying loudly (see {#drain}, {#resend_loop}), so a join
      # raising here should never actually happen -- but if it ever did, a bare
      # `drainer&.join` would raise INSIDE this `ensure`-called method and skip
      # `@rpc.stop` below, leaking the RPC thread AND clobbering {#run}'s
      # block's own exception (the T9 bug this replaces). Deferring instead
      # keeps `@rpc.stop` unconditional and lets {#reraise_recorded_failure}
      # surface the failure afterward, same as every other recorded death.
      def teardown(drainer, resender)
        @channel.close unless @channel.closed?
        @resend_inbox.close
        join_deferring_failure(drainer) { |e| @drain_failure ||= e }
        # Bounded (S3): the resend worker may be inside a bridged round trip,
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

      # The resend worker (4-2.3, dispatch since T18): a synthetic PRODUCER, not
      # a renderer. It turns each edited-buffer hand-off into a fresh
      # RequestResent -- journaled by {RequestBuffer#resend} and pushed onto the
      # SAME Channel an agent request rides, so the drainer diffs and re-renders
      # it with no special case -- and THEN offers the rebuilt Request to the
      # injected bridge ({#deliver_resend}), which is where an edit stops being
      # a projection and reaches the provider. It must be a thread of its own,
      # and NOT the RPC thread: the RPC thread drains the render queue, so if it
      # blocked pushing onto a full Channel the drainer (blocked posting to a
      # full render queue) would deadlock it -- and since T18 a bridged offer
      # can hold this thread for a whole model round trip, which the RPC thread
      # could never afford. This worker blocks on neither the render queue nor
      # the RPC thread, so its Channel push always drains.
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

      # The ONE record-and-die shape the two Neovim-owned worker threads share
      # (T9's card: the third copy becoming a shared shape): hand back the
      # failure for the caller to record in its own slot -- where
      # {#reraise_recorded_failure} picks it up AFTER teardown, never masking
      # the block's own exception the way an ensure re-raise would -- close the
      # dead worker's inlet so nothing queues behind a dead consumer, and close
      # the channel so the loss is observable the moment it happens.
      # Rescue-into-this (not re-raising) is also what keeps teardown's joins
      # from re-raising INSIDE the ensure and clobbering the block's exception.
      #
      # {RpcThread#record_death} is deliberately NOT folded in: its copy
      # genuinely differs -- before {RpcThread#start} has returned, the failure
      # rides the @ready handshake back to the caller's thread instead of a
      # recorded slot, and its resource is the render queue plus an owner
      # callback -- so unifying across that class boundary would mean
      # parameterizing away everything the method does.
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

require_relative "neovim/command_inbox"
require_relative "neovim/unbridged"
require_relative "neovim/compose"
require_relative "neovim/resender"
require_relative "neovim/inbox_view"
require_relative "neovim/buffers"
require_relative "neovim/journal_view"
require_relative "neovim/request_buffer"
require_relative "neovim/question_view"
require_relative "neovim/approval_view"
require_relative "neovim/changeset_diff"
require_relative "neovim/review_view"
require_relative "neovim/thread_view"
# LAST: it builds the three views above, so every one of them must exist by the
# time its body is read (the same load-order rule {Context::REQUIRES} states).
require_relative "neovim/surfaces"
