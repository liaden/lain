# frozen_string_literal: true

module Lain
  module Frontend
    # The Neovim frontend: a second surface on the same {Lain::Channel} the {TTY}
    # drains. The agent knows about neither frontend -- it only pushes attributed
    # {Lain::Telemetry} onto the Channel, and nothing here ever reaches back into
    # the agent.
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
      PROTOCOL = "1"

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
      # @param render_capacity [Integer] see {RenderQueue::DEFAULT_CAPACITY}
      def initialize(channel:, socket_path:, version: Lain::VERSION, protocol: PROTOCOL,
                     store: Buffers::DetachedStore.instance, session: Session::Null.instance,
                     journal: Channel::Null.instance,
                     render_capacity: RenderQueue::DEFAULT_CAPACITY)
        @channel = channel
        @buffers = Buffers.new(store:, session:)
        @request_buffer = RequestBuffer.new(journal:)
        # Edited lain://request lines land here from the RPC thread's inbound
        # dispatch and are drained by the resend worker ({#resend_loop}). An
        # unbounded Thread::Queue so on_resend never blocks the RPC thread; a
        # human can't flood single :LainResend invocations, so unbounded is safe.
        @resend_inbox = Thread::Queue.new
        @resend_failure = nil
        # on_death makes RPC-thread death observable: the channel closes, so the
        # drainer exits and producers meet ClosedQueueError instead of feeding a
        # zombie; {#run} then re-raises the recorded failure.
        @rpc = RpcThread.new(socket_path:, version:, protocol:, render_capacity:,
                             on_death: -> { @channel.close unless @channel.closed? },
                             on_resend: ->(lines) { post_resend(lines) })
      end

      # Commands the editor invoked, enqueue-and-acked by the RpcThread, for an
      # agent-side consumer to drain. Exposed as a queue, never the session.
      # @return [Thread::Queue]
      def command_inbox = @rpc.command_inbox

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
          block.call(self)
        ensure
          teardown(drainer, resender)
        end
        reraise_recorded_failure
      end

      private

      # The failures the background threads RECORDED rather than raised (a raise
      # on a background thread is silent, and a join re-raise inside the ensure
      # would clobber the block's own exception), surfaced only after teardown
      # completes. RPC-thread death outranks worker death when both happened:
      # a dead editor is the bigger loss.
      def reraise_recorded_failure
        raise @rpc.failure if @rpc.failure
        raise @resend_failure if @resend_failure
      end

      # Close-drain-stop, in that order: closing the channel lets the drainer's
      # blocking drain return; closing the resend inbox lets the resend worker's
      # blocking pop return (and a resent event mid-push meets ClosedQueueError,
      # never a wedge). Only returned workers make stopping the RPC thread
      # race-free.
      def teardown(drainer, resender)
        @channel.close unless @channel.closed?
        @resend_inbox.close
        drainer&.join
        resender&.join
        @rpc.stop
      end

      def drain
        @channel.drain { |event| post(event) }
      end

      # The resend worker (4-2.3): a synthetic PRODUCER, not a renderer. It turns
      # each edited-buffer hand-off into a fresh RequestResent -- journaled by
      # {RequestBuffer#resend} and pushed onto the SAME Channel an agent request
      # rides, so the drainer diffs and re-renders it with no special case. It
      # must be a thread of its own, and NOT the RPC thread: the RPC thread drains
      # the render queue, so if it blocked pushing onto a full Channel the drainer
      # (blocked posting to a full render queue) would deadlock it. This worker
      # blocks on neither the render queue nor the RPC thread, so its Channel push
      # always drains.
      def resend_loop
        while (lines = @resend_inbox.pop)
          resent = @request_buffer.resend(lines)
          @channel.push(resent) if resent
        end
      rescue ClosedQueueError
        # Teardown closed the Channel out from under an in-flight resend; a
        # cut-short resend at shutdown is fine (mirrors {#post}'s own rescue).
        nil
      rescue StandardError => e
        record_resend_death(e)
      end

      # The same death-observability discipline the RPC thread gets: a raising
      # journal write (the worker's native failure) must not die silently while
      # the inbox black-holes every later :LainResend. Record the failure where
      # {#run} re-raises it after teardown (never masking the block's own
      # exception -- an ensure re-raise would; this is a post-ensure check),
      # close the inbox so nothing queues behind a dead consumer, and close the
      # channel so the loss is observable the moment it happens. Rescuing here
      # (not re-raising) is also what keeps teardown's `resender.join` from
      # re-raising INSIDE the ensure and clobbering the block's exception.
      def record_resend_death(error)
        @resend_failure = error
        @resend_inbox.close
        @channel.close unless @channel.closed?
      end

      # {RpcThread}'s on_resend hand-off. A push onto a closed inbox (the worker
      # already died) is dropped, not raised: this runs on the RPC thread inside
      # inbound dispatch, and raising there would kill the whole editor session
      # over a resend whose loss {#run} already re-raises loudly.
      def post_resend(lines)
        @resend_inbox.push(lines)
      rescue ClosedQueueError
        nil
      end

      # Journal lines (append) and view updates (whole-buffer replace, 4-2.2:
      # {Buffers}) are two independent projections of the SAME event, so both
      # are attempted regardless of which (if either) actually produces
      # anything. A ClosedQueueError here means the RPC thread died between this
      # event's arrival and its post -- its failure already rides {RpcThread#failure}
      # and re-raises from {#run} once teardown completes, so dropping this one
      # event is not additional data loss, just the last render racing the death.
      def post(event)
        lines = render_lines(event)
        @rpc.post_render(lines) unless lines.empty?
        @buffers.updates(event).each { |name, view_lines| @rpc.post_view(name, view_lines) }
        # The editable view is posted with editable: true, so the runtime leaves
        # the buffer modifiable for the human -- a read-only post would flip it
        # nomodifiable and lock out the edit :LainResend depends on.
        @request_buffer.updates(event).each { |name, view_lines| @rpc.post_view(name, view_lines, editable: true) }
      rescue ClosedQueueError
        nil
      end

      # Plain-text presentation for the buffer -- deliberately NOT the pastel
      # {Decorators} the TTY uses, because a buffer wants text, not ANSI escapes.
      # (The bytes themselves may still carry a tool's own raw ANSI; stripping or
      # highlighting them is the rendering follow-up card's concern, not this
      # skeleton's.) Only {Telemetry::ToolOutput} renders today, matching the
      # TTY's one-member set; other events stay Journal-only.
      def render_lines(event)
        case event
        when Telemetry::ToolOutput
          attribute_lines(event)
        else
          []
        end
      end

      # `chomp` strips only the trailing-newline artifact of line-oriented output;
      # interior blank lines are real lines and survive (a blank renders as the
      # bare attribution prefix).
      def attribute_lines(event)
        prefix = "[#{event.tool_use_id} #{event.stream}]"
        event.bytes.chomp.split("\n", -1).map { |line| line.empty? ? prefix : "#{prefix} #{line}" }
      end
    end
  end
end

require_relative "neovim/buffers"
require_relative "neovim/request_buffer"
require_relative "neovim/rpc_thread"
