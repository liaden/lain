# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The frontend's PROJECTIONS, and the two loops that are the whole of what
      # the frontend ever asked of them together: prime every view at attach,
      # and post one event's projections. Three views ({JournalView} appends,
      # {Buffers} replaces, {RequestBuffer} replaces and stays editable) that
      # differ in nothing a caller can see except which post they take -- so
      # "which entry point does this projection ride" is one rule, stated here,
      # rather than three lines repeated in {Neovim} beside its three-thread
      # lifecycle.
      #
      # It is also where the frontend's gesture surfaces are reachable from:
      # {#buffers} is what the editor's command consumer resolves an `open` or a
      # `pin` through, and {#resend} is what the resend worker turns edited
      # lines into a record with. Neither is a new capability -- both were
      # already hanging off {Neovim} -- but naming the collection is what let
      # {Neovim} stop being the thing that holds them.
      #
      # Like every view under it, this touches nvim through the injected inlet
      # only: it turns events into plain lines and posts them, and {RpcThread}
      # remains the sole owner of every nvim call.
      class Surfaces
        # @param rpc [#post_view, #post_render] the editor's render inlet
        #   ({RpcThread}), the ONE way out of here
        # @param store [Lain::Store] backs the live Timeline (see {Buffers})
        # @param session [Lain::Session] the run's live reminders source
        # @param journal [#<<] where a resent request is recorded
        # @param questions [#open] where a set the human chose in the inbox is
        #   opened for answering ({QuestionView}). {InboxView::Unwired} by
        #   default, which refuses the gesture honestly rather than reporting an
        #   open that never happened.
        # @param journal_view [JournalView] the append projection
        # @param buffers [Buffers] the read-only view set
        # @param request_buffer [RequestBuffer] the one editable projection
        # @param approval_view [ApprovalView] the parked-approval list, primed
        #   here and rendered from its own watch fiber thereafter. REQUIRED --
        #   see below.
        #
        # The other three views are INJECTED and merely defaulted, the house rule
        # {Buffers} already follows with `inbox:`/`timeline:`: `store:`,
        # `session:`, `journal:` and `questions:` exist only to build those
        # defaults, and a caller with a view of its own hands it over instead of
        # reaching in for the one this constructed.
        #
        # `approval_view:` is REQUIRED where the other three are defaulted, and
        # the asymmetry is the point rather than an oversight. The object the
        # editor's `y` resolves through is the one {CLI::Repl} bound -- the
        # frontend's own -- so the hand-over is the whole of UX4's fix, and a
        # DEFAULT here would make forgetting it silent: {#prime} would prime
        # some other view and every live attach assertion would still pass,
        # because priming and handing-over are different claims. A panel probe
        # demonstrated exactly that. Requiring it makes the mis-wire fail at
        # construction instead, the way {Sensitivity::Policy} makes a
        # disagreeing classifier unconstructable rather than merely untested.
        # The one production call site already passes it, so this costs nothing.
        def initialize(rpc:, approval_view:, store: Buffers::DetachedStore.instance,
                       session: Session::Null.instance, journal: Channel::Null.instance,
                       questions: InboxView::Unwired, journal_view: JournalView.new, buffers: nil,
                       request_buffer: nil)
          @rpc = rpc
          @journal_view = journal_view
          @buffers = buffers || Buffers.new(store:, session:, questions:)
          @request_buffer = request_buffer || RequestBuffer.new(journal:)
          @approval_view = approval_view
        end

        # The read-only view set, and the line -> digest indexes the editor's
        # gestures resolve through ({Buffers#open}, {Buffers#pin}).
        # @return [Buffers]
        attr_reader :buffers

        # The editable projection, for the ONE collaborator that needs it: the
        # resend pipeline rebuilds a resent record through
        # {RequestBuffer#rebuild}, so {Resender} is handed this buffer at
        # construction. {JournalView} has no such reader, deliberately -- it had
        # one briefly, and its only client was a spec reaching through an ivar
        # for something to stub, which is the injection point above asking to be
        # named rather than a reader anybody needed.
        attr_reader :request_buffer

        # Post every projection's at-rest state so the full lain:// buffer set is
        # in `:buffers` from attach -- an idle session that shows no buffers reads
        # as "broken" (the first manual verification pass stumbled exactly there,
        # and manual QA round 5 found lain://approval still missing from it).
        # Runs FIRST on the drain thread ({Neovim#drain}), so priming strictly
        # precedes every event render. The rescue mirrors {#post}'s: an RPC
        # thread dead this early is already loud through
        # {Neovim::FrontendListener#died} and {Neovim#run}'s re-raise.
        # lain://approval primes LAST and through its OWN inlet ({#post_views}
        # would not do): the runtime writes `b:lain_approval_rows` from
        # `set_approval` alone, so a list primed through `set_view` would render
        # rows the editor's `y` and `n` are inert on. It carries no rows, which
        # is why priming it costs no screen -- `runtime/62_approval.lua` opens a
        # window only `if rows > 0`.
        def prime
          [@journal_view, @buffers].each { |view| post_views(view.initial) }
          @request_buffer.initial.each { |name, lines| @rpc.post_view(name, lines, editable: true) }
          @approval_view.prime
        rescue ClosedQueueError
          nil
        end

        # Journal lines (append) and view updates (whole-buffer replace, 4-2.2:
        # {Buffers}) are two independent projections of the SAME event, so both
        # are attempted regardless of which (if either) actually produces
        # anything. A ClosedQueueError here means the RPC thread died between this
        # event's arrival and its post -- its failure already rides {RpcThread#failure}
        # and re-raises from {Neovim#run} once teardown completes, so dropping this
        # one event is not additional data loss, just the last render racing the
        # death.
        def post(event)
          lines = @journal_view.lines(event)
          @rpc.post_render(lines) unless lines.empty?
          post_views(@buffers.updates(event))
          # The editable view is posted with editable: true, so the runtime leaves
          # the buffer modifiable for the human -- a read-only post would flip it
          # nomodifiable and lock out the edit :LainResend depends on.
          @request_buffer.updates(event).each { |name, view_lines| @rpc.post_view(name, view_lines, editable: true) }
        rescue ClosedQueueError
          nil
        end

        # The resend worker's hand-off: edited lain://request lines become a
        # fresh record for {Resender} to deliver. nil when the edit rebuilds
        # nothing (see {RequestBuffer#resend}).
        def resend(lines) = @request_buffer.resend(lines)

        private

        # The read-only views' one post, and the ONE place a rendering's stamp
        # rides along: {Buffers#generation_of} answers it for the view that has
        # one (lain://inbox) and nothing for the rest, so a gesture-bearing
        # buffer gets stamped without the other four views knowing the word.
        #
        # It asserts nothing about the LINES. That each rendering is one line
        # per record is the view's own contract ({Buffers::TimelineView#preview},
        # {InboxView#line_for}), and the transport's refusal for a view that
        # breaks it lives at {RenderQueue#post_view} -- which is also the post
        # {#prime} and the editable view above go through, so a guarantee stated
        # here would be one this method's own neighbours bypass.
        def post_views(updates)
          updates.each { |name, lines| @rpc.post_view(name, lines, generation: @buffers.generation_of(name)) }
        end
      end
    end
  end
end
