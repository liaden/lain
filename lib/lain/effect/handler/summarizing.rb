# frozen_string_literal: true

module Lain
  module Effect
    class Handler
      # Observes a tool result on its way back through the handler chain and
      # fires an eager summary of it WITHOUT interpreting the effect itself: it
      # declines every effect (so `inner` performs it) and only wraps the return.
      #
      # The chain stays plain synchronous Ruby -- this decorator never awaits.
      # {Oracle::Eager#fire} spawns the oracle call ONLY when a reactor is
      # ambient (the agent loop's, in live use); with none, the fire is a
      # graceful no-op and the dispatch still returns the tool result unchanged.
      # So a summary is added WHEN the reactor is there and degrades to a miss
      # when it is not -- the chain never depends on `Async` for a result.
      #
      # The summary is keyed by the result's SOURCE DIGEST -- the content address
      # of the bytes the tool returned -- so identical output fires exactly once
      # and the key can never go stale.
      #
      # The result is returned UNCHANGED: a summary is a side value a later seam
      # reads via {Oracle::Eager#held}, never a rewrite of what the tool returned.
      class Summarizing < Handler
        # The duck {Agent::ToolRunner}'s post-dispatch observation seam takes,
        # holding the rule this decorator also asks for so the two cannot drift.
        #
        # Neither mount holds a SIZE policy any more. This one once refused to
        # fire below 4096 bytes, which reads as "a small result is not worth an
        # oracle call" -- true of the MODEL tier and false of the free one,
        # since a declared summarizer costs no tokens and no latency. Gating
        # here made a project's own `.lain/summarizers.rb` dead for every
        # ordinary tool result, so every result is offered to the oracle now and
        # the cost gate sits with the object that knows which tier pays,
        # {Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES}.
        #
        # **This is the mount production should use, and exactly one of the two
        # may be mounted against a given {Oracle::Eager}.** A consumed digest is
        # refused forever, so with both mounted the decorator -- which fires from
        # inside the handler chain, above the post-dispatch seam -- burns the key
        # before that seam is ever offered the result. The decorator remains for
        # a chain that has no ToolRunner above it.
        class Observer
          # Readable so the run's ONE shared Eager can be checked, not assumed.
          attr_reader :eager

          def initialize(eager:)
            @eager = eager
          end

          # One completed tool_result wire block, plus the NAME of the tool that
          # produced it. Every effect a ToolRunner dispatches is already a tool
          # call, so `is_error` is all that remains here of "a successful one".
          #
          # The name is a second ARGUMENT, not a fifth key, because the block is
          # the `tool_result` sent to the provider and its shape is pinned. It is
          # REQUIRED, so a mount that cannot say which tool ran raises rather
          # than routing every result as nameless -- which would silently
          # disable every tool-keyed {Summarizer}.
          def observe(block, tool_name)
            summarize(block["content"], tool_name) unless block["is_error"]
          end

          # THE rule, in one place for both mounts: String content earns a
          # consult, keyed by its content address. Block (Array) content is
          # structured, not free text, so a prose summarizer has nothing to
          # compress. The KEY stays the digest of the tool's own bytes -- what
          # {Compaction::SummarySnapshot} looks a summary up by -- while the
          # fired VALUE carries the tool name {Oracle::RoutedSummarizer} routes
          # suitability on.
          def summarize(content, tool_name)
            return unless content.is_a?(String)

            @eager.fire(Canonical.digest(content), Summarizer::Result.new(tool_name:, text: content))
          end
        end

        # @param eager [Oracle::Eager] the summary store this fires into
        # @param inner [Effect::Handler, nil] performs the effect this only observes
        def initialize(eager:, inner: nil)
          super(inner:)
          @observer = Observer.new(eager:)
        end

        # `super` delegates to `inner` (this handler interprets nothing); the
        # fire is fire-and-forget, so the inner result comes back untouched.
        def call(effect, context = nil)
          super.tap { |result| fire_summary(effect, result) }
        end

        private

        # This mount's half of the predicate: was the outcome a successful tool
        # call at all. {Observer#summarize} owns the other half, the shape rule
        # both mounts share, so a policy change cannot reach one and miss the other.
        def fire_summary(effect, result)
          @observer.summarize(result.content, tool_name(effect)) if summarizable?(effect, result)
        end

        def summarizable?(effect, result) = (effect.tool_call? || effect.approval?) && result.ok?

        # An {Effect::Approval} WRAPS the tool call it gates, so the name lives
        # one level in; {#summarizable?} has already established it is one of the two.
        def tool_name(effect) = effect.tool_call? ? effect.name : effect.effect.name
      end
    end
  end
end
