# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The resend delivery pipeline (T18), extracted from {Neovim} as its own
      # responsibility: one edited-buffer hand-off becomes a projection pushed
      # onto the render Channel AND -- when a real bridge is wired -- an offer
      # that reaches the provider. The worker THREAD stays in {Neovim} (it
      # shares the record-and-die shape with the drainer, {Neovim#resend_loop});
      # this owns only what one delivery does, so the frontend class is not
      # carrying the resend render logic on top of its three-thread lifecycle.
      class Resender
        # The upfront-attempt render (S2): pushed the instant the bridge's gate
        # passes and BEFORE the round trip, so the human is told an attempt is
        # under way rather than watching an idle diff while the wire blocks.
        ATTEMPT = "resend: dispatching the edited request to the provider..."

        # @param channel [Lain::Channel] the render Channel the projection rides
        # @param rpc [#post_render] the editor's render inlet
        # @param bridge [#offer] T18's dispatch seam ({CLI::ResendBridge}, or
        #   {Unbridged} for the projection-only default)
        # @param request_buffer [RequestBuffer] rebuilds a resent record into a
        #   live Request for the bridge
        def initialize(channel:, rpc:, bridge:, request_buffer:)
          @channel = channel
          @rpc = rpc
          @bridge = bridge
          @request_buffer = request_buffer
        end

        # One resend's delivery, in the T18 order: the projection FIRST (the
        # human's diff must never wait on a model round trip), then the offer.
        # The rebuild rides a block so {Unbridged} never forces it -- an
        # unbridged resend stays byte-identical to the pure projection, never
        # raising over an edit that parses as JSON but does not rebuild into a
        # Request. The notice (nil from {Unbridged}) renders through the same
        # append path every render takes -- how the editor is told a resend
        # dispatched, was refused mid-flight, or failed.
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
