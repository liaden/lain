# frozen_string_literal: true

require "json"

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
    # {Ext::Event}'s and a recorded turn's are the same input.
    class Writes
      include Enumerable

      # A recorded result whose item, rebuilt with its call's input, addresses
      # another digest than the one it recorded.
      class Mismatch < ArgumentError; end

      NAME = "memory_write"
      RECORDED = "recorded item: "
      private_constant :NAME, :RECORDED

      # What a memory_write result carries beside its call's input so a replay
      # rebuilds the item as written: the input names source paths, never their
      # digests or the author. The body stays out, so the line does not grow with it.
      #
      # @param item [Item]
      # @return [String]
      def self.recorded(item)
        "#{RECORDED}#{Canonical.dump({ "author" => item.author.to_h, "digest" => item.digest,
                                       "sources" => item.sources })}"
      end

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
        @per_turn ||= @contents.each_index.map { |index| items_at(index) }
      end

      # The items the content at `index` wrote, alone, so a reader can name the
      # turn whose recorded result fails to rebuild.
      #
      # @param index [Integer] a position in the contents given
      # @return [Array<Item>]
      # @raise [Mismatch] when a recorded result disagrees with its call; a live
      #   caller never reaches it, because a chain loaded from disk is replayed
      #   first and refused there as Corrupt
      def items_at(index)
        executed(@contents.fetch(index)).map { |call| item_for(call, results.fetch(call["id"])) }
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
          block["type"] == "tool_use" && block["name"] == NAME && results[block["id"]]&.[]("is_error") == false
        end
      end

      # tool_use_id => tool_result, across every content given: results answer
      # their call from the FOLLOWING turn, and ids are unique per run, so one
      # flat map is the pairing.
      def results
        @results ||= @contents.flatten(1)
                              .select { |block| block["type"] == "tool_result" }
                              .to_h { |block| [block["tool_use_id"], block] }
      end

      # Results journaled before the recorded line existed, and hand-written
      # fixtures, carry no line.
      def item_for(call, result)
        recorded = recorded_line(original(result)["content"])
        return from_input(call.fetch("input")) unless recorded

        verified(call, rebuilt(call.fetch("input"), recorded), recorded.fetch("digest"))
      end

      # A round budget answers a repeated result by naming the first call's.
      def original(result)
        first = Tool::RoundBudget.referenced(result["content"])
        first ? results.fetch(first) : result
      end

      def from_input(input, **recorded)
        Item.new(id: input.fetch("id"), description: input.fetch("description"), body: input.fetch("body"), **recorded)
      end

      def rebuilt(input, recorded)
        from_input(input, author: Author.from(recorded.fetch("author")), sources: recorded.fetch("sources"))
      end

      def verified(call, item, digest)
        return item if item.digest == digest

        raise Mismatch, "memory_write #{call["id"]} rebuilds to #{item.digest} but its result recorded #{digest}"
      end

      def recorded_line(content)
        return unless content.is_a?(String)

        line = content.each_line(chomp: true).find { |text| text.start_with?(RECORDED) }
        line && JSON.parse(line.delete_prefix(RECORDED))
      end
    end
  end
end
