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
      def initialize(channel:, socket_path:, version: Lain::VERSION, protocol: PROTOCOL)
        @channel = channel
        # on_death makes RPC-thread death observable: the channel closes, so the
        # drainer exits and producers meet ClosedQueueError instead of feeding a
        # zombie; {#run} then re-raises the recorded failure.
        @rpc = RpcThread.new(socket_path:, version:, protocol:,
                             on_death: -> { @channel.close unless @channel.closed? })
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
        drainer = nil
        begin
          @rpc.start
          drainer = Thread.new { drain }
          block.call(self)
        ensure
          teardown(drainer)
        end
        raise @rpc.failure if @rpc.failure
      end

      private

      # Close-drain-stop, in that order: closing the channel is what lets the
      # drainer's blocking drain return, and only a returned drainer makes
      # stopping the RPC thread race-free.
      def teardown(drainer)
        @channel.close unless @channel.closed?
        drainer&.join
        @rpc.stop
      end

      def drain
        @channel.drain { |event| post(event) }
      end

      def post(event)
        lines = render_lines(event)
        @rpc.post_render(lines) unless lines.empty?
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

require_relative "neovim/rpc_thread"
