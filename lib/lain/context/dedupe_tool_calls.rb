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
          .group_by { |(_message, use)| Canonical.dump("name" => use.name, "input" => use.input) }
          .values
          .flat_map { |occurrences| occurrences[0..-2] }
          .reject { |(message, _use)| @protected_patterns.protects?(Canonical.dump(message)) }
          .map { |(_message, use)| use.id }
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

      # [message, tool_use lens] pairs -- occurrences keep their containing
      # message alongside the block so the protection check downstream can
      # consult the whole message, not just the block. The `type` test is a raw
      # key read and stays one: {Response::ToolUse.wrap} accepts any Hash and
      # checks no type, so a block must be KNOWN a tool_use before it is lensed.
      def tool_use_occurrences(messages)
        messages.flat_map do |message|
          message["content"].select { |block| block["type"] == "tool_use" }
                            .map { |block| [message, Response::ToolUse.wrap(block)] }
        end
      end

      # Two shapes answer the same question -- a tool_use block by its own "id",
      # its answering tool_result by "tool_use_id" -- and each is asked through
      # the lens that names it. The branch is what makes that honest: neither
      # lens checks the wire type, so the type has to be established before one
      # is put on. It also closes what the earlier untyped `include?(block["id"])
      # || include?(block["tool_use_id"])` left open -- a tool_use with no "id"
      # put nil in the stale set, and every id-less block in the render (every
      # text block) then matched it and was dropped. That id is now a `fetch` in
      # #stale_tool_use_ids, so the malformed block raises where it is read.
      #
      # `else false` is a WIDENING, and deliberate: Anthropic's block vocabulary
      # is non-exhaustive, and shapes outside Lain's own -- `server_tool_use`,
      # `web_search_tool_result` -- carry these very keys. Before the branch
      # they could match a stale id and be dropped; now nothing but the two
      # shapes this class actually reasons about is ever dropped. A future
      # vocabulary that must dedupe gets an arm here, not a fall-through.
      def stale?(block, stale_ids)
        case block["type"]
        when "tool_use" then stale_ids.include?(Response::ToolUse.wrap(block).id)
        when "tool_result" then stale_ids.include?(Tool::ResultBlock.wrap(block).tool_use_id)
        else false
        end
      end

      # Below the methods it names, which Algebra::Elementwise requires: the
      # claim is checked at load, so a typo fails here rather than mid-render.
      elementwise on: :call, each: :without_stale, given: :stale_tool_use_ids
    end
  end
end
