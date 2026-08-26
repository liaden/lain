# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # One edited-buffer hand-off becomes a projection pushed onto the render
      # Channel AND -- when a real bridge is wired -- an offer that reaches the
      # provider. The worker THREAD stays in {Neovim}, sharing the
      # record-and-die shape with the drainer; this owns only what one delivery
      # does.
      class Resender
        # The upfront-attempt render: pushed the instant the bridge's gate
        # passes and BEFORE the round trip, so the human is told an attempt is
        # under way rather than watching an idle diff while the wire blocks.
        ATTEMPT = "resend: dispatching the edited request to the provider..."

        # @param channel [Lain::Channel] the render Channel the projection rides
        # @param rpc [#post_render] the editor's render inlet
        # @param bridge [#offer] the dispatch seam ({CLI::ResendBridge}, or
        #   {Unbridged} for the projection-only default)
        # @param request_buffer [RequestBuffer] rebuilds a resent record into a
        #   live Request for the bridge
        def initialize(channel:, rpc:, bridge:, request_buffer:)
          @channel = channel
          @rpc = rpc
          @bridge = bridge
          @request_buffer = request_buffer
        end

        # The required ORDER: the projection first -- the human's diff must never
        # wait on a model round trip -- then the offer. The rebuild rides a block
        # so {Unbridged} never forces it, and an unbridged resend therefore never
        # raises over an edit that parses as JSON but does not rebuild into a
        # Request.
        def deliver(resent)
          return if resent.nil?

          @channel.push(resent)
          notice = @bridge.offer(on_attempt: -> { announce }) { @request_buffer.rebuild(resent) }
          @rpc.post_render([notice]) unless notice.nil?
        end

        private

        # Best-effort: a dead render queue must not turn into a "resend failed"
        # narrative, so a ClosedQueueError is swallowed here rather than raised
        # into the bridge (the frontend's swallow idiom -- see {Neovim#post}).
        # The hook fires before the slot is staged, so a swallowed announce
        # leaves the dispatch itself untouched.
        def announce
          @rpc.post_render([ATTEMPT])
        rescue ClosedQueueError
          nil
        end
      end
    end
  end
end
