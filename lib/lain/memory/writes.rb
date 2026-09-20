# frozen_string_literal: true

module Lain
  module Memory
    # The memory_write calls a chain actually executed, read out of the turns
    # themselves: `memory_write` tool_use blocks whose paired tool_result came
    # back without an error.
    #
    # ONE reader for both sides of the same question -- the LIVE view following
    # a `/rewind` ({Recorder#follow}) and the REPLAY rebuilding a recorded one
    # ({Bench::Session::MemoryReplay}) -- because a session rendering a memory
    # its own record says the chain dropped is exactly the divergence this
    # exists to make unrepresentable. It reads content blocks, so a live
    # {Event}'s and a recorded turn's are the same input.
    class Writes
      include Enumerable

      NAME = "memory_write"
      private_constant :NAME

      # @param contents [Enumerable<Array<Hash>>] each turn's content blocks, in
      #   chain order (root first), so a call and the turn answering it are both
      #   present
      def initialize(contents)
        @contents = contents.map { |content| content.is_a?(Array) ? content.grep(Hash) : [] }
      end

      # The items each content's executed calls wrote, ONE list per content and
      # in the order given -- what a caller pairing writes with the turn that
      # made them needs, where {#each} flattens for one that does not.
      #
      # @return [Array<Array<Item>>]
      def per_turn
        @per_turn ||= @contents.map { |blocks| executed(blocks).map { |block| item_for(block) } }
      end

      def each(&block)
        return enum_for(:each) unless block_given?

        per_turn.flatten(1).each(&block)
      end

      private

      # `== false`, not negation: a tool_use with NO result at all (nil) never
      # executed -- a round a rewind left behind, or one torn before its results
      # landed -- so it must not enter a view any more than an errored one.
      def executed(blocks)
        blocks.select do |block|
          block["type"] == "tool_use" && block["name"] == NAME && outcomes[block["id"]] == false
        end
      end

      # tool_use_id => is_error, across every content given: results answer
      # their call from the FOLLOWING turn, and ids are unique per run, so one
      # flat map is the pairing.
      def outcomes
        @outcomes ||= @contents.flatten(1)
                               .select { |block| block["type"] == "tool_result" }
                               .to_h { |block| [block["tool_use_id"], block["is_error"]] }
      end

      def item_for(block)
        input = block.fetch("input")
        Item.new(id: input.fetch("id"), description: input.fetch("description"), body: input.fetch("body"))
      end
    end
  end
end
