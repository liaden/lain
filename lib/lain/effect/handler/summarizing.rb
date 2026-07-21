# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Observes a tool result on its way back through the handler chain and, when
      # the result is large enough to be worth compressing, fires an eager summary
      # of it -- WITHOUT interpreting the effect itself. It declines every effect
      # (so `inner` performs it) and only wraps the return value.
      #
      # The chain stays plain synchronous Ruby (5-0.2): this decorator never
      # awaits. It hands the source to {Oracle::Eager#fire}, which spawns the
      # oracle call ONLY when a reactor is ambient -- the agent loop's, in live
      # use. Called with NO surrounding reactor, the fire is a graceful no-op and
      # the summary is simply skipped; the dispatch still completes and returns the
      # tool result unchanged. So the decorator adds a summary WHEN the reactor is
      # there and degrades to a miss when it is not -- it never makes the chain
      # depend on `Async` to produce a result.
      #
      # The summary is keyed by the result's SOURCE DIGEST -- the content address
      # of the bytes the tool returned -- so identical output fires exactly once
      # and the key can never go stale. Only a SUCCESSFUL, String-content result
      # over the byte threshold is summarized: an error result is not worth
      # compressing, and block (Array) content is structured, not free text.
      #
      # The result is returned UNCHANGED. A summary is a side value a later seam
      # reads via {Oracle::Eager#held}, never a rewrite of what the tool returned.
      class Summarizing < Handler
        # Tool results below this many bytes are not worth an oracle call. A
        # starting policy, injectable; the eager tier is local-only, so a low
        # threshold spends local compute, not tokens.
        DEFAULT_THRESHOLD_BYTES = 4096

        # @param eager [Oracle::Eager] the summary store this fires into
        # @param threshold_bytes [Integer] the size a result must exceed to fire
        # @param inner [Effect::Handler, nil] performs the effect this only observes
        def initialize(eager:, threshold_bytes: DEFAULT_THRESHOLD_BYTES, inner: nil)
          super(inner:)
          @eager = eager
          @threshold_bytes = threshold_bytes
        end

        # Perform through the chain, then fire a summary of the outcome if it earns
        # one. `super` delegates to `inner` (this handler interprets nothing); the
        # fire is a fire-and-forget side effect, so the inner result is returned
        # exactly as it came back.
        def call(effect, context = nil)
          super.tap { |result| fire_summary(effect, result) }
        end

        private

        def fire_summary(effect, result)
          return unless summarizable?(effect, result)

          @eager.fire(Canonical.digest(result.content), result.content)
        end

        # A summarizable outcome is a successful tool call whose String content
        # crosses the threshold. Anything else -- a non-tool effect, an error, or
        # structured block content -- is left untouched.
        def summarizable?(effect, result)
          (effect.tool_call? || effect.approval?) && result.ok? &&
            result.content.is_a?(String) && result.content.bytesize > @threshold_bytes
        end
      end
    end
  end
end
