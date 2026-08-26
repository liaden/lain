# frozen_string_literal: true

module Lain
  module Compaction
    # Whether a message carries a tool observation, and the two run-selections
    # built on that one predicate: the contiguous stretches of tool-carrying
    # messages, and the contiguous stretches of conversational ones long enough
    # to be worth a model call. ONE object, so that
    # {Strategy::ElideToolObservations} and {Strategy::SummarizeConversation}
    # ask rather than each spelling the predicate -- two spellings could drift
    # on real input, and the moment they did {Strategy::Composed} would raise
    # `Overlap` at proposal time, mid-turn, in a live chat, for a reason neither
    # strategy alone could see.
    #
    # Message-granular, deliberately: the normal Anthropic assistant shape is
    # text and `tool_use` in ONE message, so this predicate elides the model's
    # own prose along with the observation it is attached to. A stated
    # limitation, not an oversight -- masking at block granularity is a
    # different seam, since {Strategy::Base} is handed messages, never blocks.
    module ToolMessages
      module_function

      # A message carries a tool observation if ANY of its content blocks is
      # a `tool_use` or `tool_result` block.
      #
      # @param message [Hash] a rendered message, with a "content" key
      # @return [Boolean]
      def tool?(message) = message.fetch("content").any? { |block| block.fetch("type").start_with?("tool_") }

      # The contiguous runs of tool-carrying messages in span: everywhere
      # {#tool?} holds, chunked by adjacency.
      #
      # @param messages [Array<Hash>] the full message array; span indexes it
      # @param span [Range] the indices to select within
      # @param owner [String] the caller to name in a partition refusal
      # @return [Array<Range>] validated, ascending, non-overlapping
      def tool_runs(messages, span:, owner:)
        conversational = indices_where(messages, span) { |message| !tool?(message) }
        IntervalPartition.covering(span, excluding: conversational, owner:).validated
      end

      # The contiguous runs of conversational (non-tool) messages in span, kept
      # only where a run is more than one message long -- so a lone
      # conversational turn between two tool runs is left for the derivation to
      # retain verbatim rather than costing a model call to summarize one
      # message.
      #
      # @param (see #tool_runs)
      # @return (see #tool_runs)
      def conversational_runs(messages, span:, owner:)
        tools = indices_where(messages, span) { |message| tool?(message) }
        IntervalPartition.covering(span, excluding: tools, owner:).validated
                         .select { |run| run.size > 1 }
      end

      def indices_where(messages, span) = span.select { |index| yield(messages.fetch(index)) }
      private_class_method :indices_where
    end
  end
end
