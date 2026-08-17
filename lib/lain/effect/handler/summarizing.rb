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
      # is summarized: an error result is not worth compressing, and block
      # (Array) content is structured, not free text.
      #
      # The result is returned UNCHANGED. A summary is a side value a later seam
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
        # may be mounted against a given {Oracle::Eager}.** The decorator fires
        # from inside the handler chain -- which is inside `ToolRunner#gather`
        # -- where a fire can be reaped while {Oracle::Eager#fire} has already
        # consumed its digest, and a consumed digest is refused forever. With
        # both mounted, the decorator reaches the Eager first and burns the key
        # before the post-dispatch seam is ever offered the result. The
        # decorator remains for a chain that has no ToolRunner above it.
        class Observer
          # The run shares ONE Eager between this and the pipeline source; readable so
          # that sharing can be checked rather than assumed.
          attr_reader :eager

          def initialize(eager:)
            @eager = eager
          end

          # The seam's message: one completed tool_result wire block, plus the
          # NAME of the tool that produced it. Every effect a ToolRunner
          # dispatches is already a tool call, so `is_error` is all that
          # remains here of "a successful tool call".
          #
          # The name is a second ARGUMENT, not a fifth key: the block is the
          # `tool_result` sent to the provider and gate 4 pins its shape. It is
          # REQUIRED, so a mount that cannot say which tool ran raises rather
          # than routing every result as nameless -- which would silently
          # disable every tool-keyed {Summarizer}.
          def observe(block, tool_name)
            summarize(block["content"], tool_name) unless block["is_error"]
          end

          # THE rule, in one place for both mounts: String content earns a
          # consult, keyed by its content address. Block (Array) content is
          # structured, not free text, so there is nothing for a prose
          # summarizer to compress.
          #
          # The KEY stays the digest of the tool's own bytes -- that is what
          # {Compaction::SummarySnapshot} looks a summary up by -- while the
          # fired VALUE is a {Summarizer::Result}, which carries the tool name
          # {Oracle::RoutedSummarizer} routes suitability on.
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

        # Perform through the chain, then fire a summary of the outcome if it earns
        # one. `super` delegates to `inner` (this handler interprets nothing); the
        # fire is a fire-and-forget side effect, so the inner result is returned
        # exactly as it came back.
        def call(effect, context = nil)
          super.tap { |result| fire_summary(effect, result) }
        end

        private

        # This mount's half of the predicate: was the outcome a successful tool
        # call at all. {Observer#summarize} owns the other half -- the size and
        # shape rule both mounts share -- so a change to the policy cannot reach
        # one mount and miss the other.
        def fire_summary(effect, result)
          @observer.summarize(result.content, tool_name(effect)) if summarizable?(effect, result)
        end

        def summarizable?(effect, result) = (effect.tool_call? || effect.approval?) && result.ok?

        # An {Effect::Approval} WRAPS the tool call it gates, so the name lives
        # one level in -- and {#summarizable?} has already established that one
        # of the two is what this is.
        def tool_name(effect) = effect.tool_call? ? effect.name : effect.effect.name
      end
    end
  end
end
