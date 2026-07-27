# frozen_string_literal: true

module Lain
  class Context
    # Keeps only the newest of any (tool name, args) pair the model asked for
    # more than once, dropping every older occurrence's tool_use AND its
    # answering tool_result AS A UNIT -- an orphaned tool_use with no matching
    # tool_result (or vice versa) is an invalid turn on the wire, so a stale
    # pair is removed whole or not at all. A pure PROJECTION over the
    # rendered message list: nothing here touches the Timeline the messages
    # were derived from, so the "log" (the append-only Merkle DAG) is
    # untouched regardless of how many times this runs over its render.
    #
    # `#requires` is the inherited {Combinator} default: deduping rewrites
    # what already rode back from the Provider, so it needs nothing further
    # FROM the Provider.
    #
    # Two phases, and the split is the point: an ANALYSIS of the whole list
    # (which tool_use ids are stale), then a map over each message against that
    # fixed analysis. It is {Algebra::Elementwise} only relative to that
    # analysis -- a message cannot tell on its own whether a later message
    # supersedes it -- which is exactly why composition order matters here and
    # why an unconditional elementwise claim would be false. The analysis is
    # PUBLIC, because that is half of what the factoring buys: it is a value a
    # caller can ask for instead of a local variable, and the declaration names
    # it. The per-message map stays private (Algebra::Elementwise reaches it by
    # `send`) while still buying the other half -- every output message has one
    # known preimage, so a caller could journal what was dropped and why.
    class DedupeToolCalls < Combinator
      include Algebra::Elementwise

      def initialize(protected_patterns: ProtectedPatterns::NONE)
        super()
        @protected_patterns = protected_patterns
        freeze
      end

      # Every (name, input) pair with more than one occurrence, minus the
      # newest. Canonical.dump gives a deterministic key regardless of Hash
      # key insertion order; Array#group_by preserves encounter order within
      # each bucket, so "all but the last element of the group" IS "all but
      # the newest occurrence."
      #
      # Protection is checked against the CONTAINING MESSAGE's dump, not the
      # block's own -- the same granularity {Prune} and {Compact} use, so "a
      # protected span is never dropped" means one thing across every
      # consumer, not "protected block" here and "protected message" there.
      def stale_tool_use_ids(messages)
        tool_use_occurrences(messages)
          .group_by { |(_message, block)| Canonical.dump("name" => block["name"], "input" => block["input"]) }
          .values
          .flat_map { |occurrences| occurrences[0..-2] }
          .reject { |(message, _block)| @protected_patterns.protects?(Canonical.dump(message)) }
          .map { |(_message, block)| block["id"] }
      end

      private

      # Drops a stale tool_use or its answering tool_result from one message,
      # answering zero or more messages: a message left with no content blocks
      # contributes NOTHING rather than an empty turn, and concatenation is
      # what turns that empty answer into a drop rather than a hole. An
      # unchanged message is returned identically, so a caller comparing
      # preimage to image sees "untouched" as object identity.
      def without_stale(message, stale_ids)
        content = message["content"].reject { |block| stale?(block, stale_ids) }
        return [] if content.empty?

        [content == message["content"] ? message : message.merge("content" => content)]
      end

      # [message, block] pairs -- occurrences keep their containing message
      # alongside the tool_use block so the protection check downstream can
      # consult the whole message, not just the block.
      def tool_use_occurrences(messages)
        messages.flat_map do |message|
          message["content"].select { |block| block["type"] == "tool_use" }.map { |block| [message, block] }
        end
      end

      # A single predicate covers both block shapes: a tool_use block's own
      # "id" and a tool_result block's answering "tool_use_id" are never both
      # present on the same block, so checking both is safe and needs no
      # `block["type"]` branch.
      def stale?(block, stale_ids)
        stale_ids.include?(block["id"]) || stale_ids.include?(block["tool_use_id"])
      end

      # Below the methods it names, which Algebra::Elementwise requires: the
      # claim is checked at load, so a typo fails here rather than mid-render.
      elementwise on: :call, each: :without_stale, given: :stale_tool_use_ids
    end
  end
end
