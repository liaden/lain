# frozen_string_literal: true

module Lain
  module Compaction
    # Offers each completed tool result to the run's eager summarizer: the
    # write half of the summary a later compaction reads back through
    # {SummarySnapshot}, keyed by the same content address.
    #
    # It is the {Agent::ToolRunner::Observer} production mounts, sent once per
    # result AFTER a turn's calls have gathered. That placement is the whole
    # reason it is an observer and not a layer of the tool stack: a fire from
    # inside the stack runs inside the gather, whose reactor reaps it, and
    # {Oracle::Eager#fire} consumes a digest before it spawns -- so a reaped
    # fire burns that content's key for the whole session.
    #
    # It holds no SIZE policy. It once refused to fire below 4096 bytes, which
    # reads as "a small result is not worth an oracle call" -- true of the
    # MODEL tier and false of the free one, since a declared summarizer costs
    # no tokens and no latency. Gating here made a project's own
    # `.lain/summarizers.rb` dead for every ordinary tool result, so every
    # result is offered now and the cost gate sits with the object that knows
    # which tier pays, {Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES}.
    class SummaryObserver
      # Readable so the run's ONE shared Eager can be checked, not assumed.
      attr_reader :eager

      # @param eager [Oracle::Eager] the summary store this fires into
      def initialize(eager:)
        @eager = eager
      end

      # One completed tool_result wire block, plus the NAME of the tool that
      # produced it. Every effect a ToolRunner dispatches is already a tool
      # call, so `is_error` is all that remains here of "a successful one".
      #
      # The name is a second ARGUMENT, not a fifth key, because the block is
      # the `tool_result` sent to the provider and its shape is pinned. It is
      # REQUIRED, so a mount that cannot say which tool ran raises rather than
      # routing every result as nameless -- which would silently disable every
      # tool-keyed {Summarizer}.
      def observe(block, tool_name)
        summarize(block["content"], tool_name) unless block["is_error"]
      end

      private

      # String content earns a consult, keyed by its content address. Block
      # (Array) content is structured, not free text, so a prose summarizer has
      # nothing to compress. The KEY stays the digest of the tool's own bytes --
      # what {SummarySnapshot} looks a summary up by -- while the fired VALUE
      # carries the tool name {Oracle::RoutedSummarizer} routes suitability on.
      def summarize(content, tool_name)
        return unless content.is_a?(String)

        @eager.fire(Canonical.digest(content), Summarizer::Result.new(tool_name:, text: content))
      end
    end
  end
end
