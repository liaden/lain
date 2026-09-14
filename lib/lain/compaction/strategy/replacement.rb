# frozen_string_literal: true

# `String#blank?` is the allocation-free blank test the per-block refusal below
# turns on, and it is NOT part of bare `active_support` -- requiring only that
# leaves `#blank?` undefined and the refusal silently evaporating. The core_ext
# require raises unless `active_support` is loaded first, so the order of these
# two lines is load-bearing.
require "active_support"
require "active_support/core_ext/object/blank"

module Lain
  module Compaction
    module Strategy
      # A replacement carrying a block the provider would reject as empty.
      # Named per the error-taxonomy convention, beside the value that raises it.
      class Blank < Error; end

      # Content that is not content blocks at all.
      class NotBlocks < Error; end

      # The empty content DROP answers, hoisted to a constant because a
      # `[].freeze` literal allocates a fresh Array on every read.
      NO_CONTENT = [].freeze
      private_constant :NO_CONTENT

      # What replaces one collapsed range: CONTENT BLOCKS, and nothing else.
      #
      # There is no role here and no way to add one. The Messages API requires
      # `messages[0]` to be `user`, and with no pins the replacement IS
      # `messages[0]`, so the role is decided in exactly one place -- the
      # derivation. An earlier draft decided it in four; a value that cannot
      # carry a role is what makes that impossible rather than discouraged.
      #
      # == What counts as content
      #
      # An Array of Hashes, each carrying a `"type"`. That one check refuses
      # every shape a hand-written `#blocks` actually produces by mistake: a
      # bare Hash where an Array was meant, a `nil` among good blocks, a bare
      # String, an empty Hash, and a whole MESSAGE posing as a block. Any of
      # them would render as garbage on the wire.
      #
      # == Blankness is per block, not per body
      #
      # Anthropic rejects the request if ANY text block is empty, not only if
      # the whole body is. So `[empty_text, good_text]` is refused; an earlier
      # all-blank reading let it through, and 15 concatenations of a modest pool
      # then carried an empty block. Only a TEXT block can be blank: a
      # `tool_use` carries no `"text"` and is content all the same.
      #
      # == Two constructors, and why they disagree about emptiness
      #
      # `.new` refuses empty content; `.of` is the map INTO the free monoid, so
      # it answers the unit (DROP) for no blocks at all rather than minting a
      # blank replacement. "No blocks" and "a block with nothing in it" are
      # different answers, and only the second is a bug.
      #
      # A deeply frozen value: content is made shareable on the way in, {Head}'s
      # idiom, so a caller's own blocks are neither frozen underneath it nor
      # reachable from here.
      Replacement = Data.define(:content) do
        # The free monoid's map: blocks in, a replacement or the unit out.
        def self.of(blocks) = blocks.is_a?(Array) && blocks.empty? ? DROP : new(content: blocks)

        # The one-text-block case. A blank body is refused by `.new`, where the
        # refusal belongs.
        def self.text(body) = of([{ "type" => "text", "text" => body }])

        def initialize(content:) = super(content: vetted(content))

        # A Null-Object pair with DROP, so no caller writes `if replacement`.
        def drop? = false

        private

        def vetted(content)
          refuse_foreign(content)
          refuse_blank(content)
          # Already-shareable content is kept as it is; copying it would buy
          # nothing.
          Ractor.shareable?(content) ? content : Ractor.make_shareable(content, copy: true)
        end

        # Both refusals walk the content without allocating, and the offenders
        # are collected only once there is something to name.
        def refuse_foreign(content)
          raise NotBlocks, not_an_array(content) unless content.is_a?(Array)
          return if content.all? { |block| block?(block) }

          raise NotBlocks, not_content_blocks(content.reject { |block| block?(block) })
        end

        def block?(value) = value.is_a?(Hash) && value.key?("type")

        def not_an_array(content)
          "a replacement's content must be an Array of content blocks, got #{content.inspect}"
        end

        def not_content_blocks(alien)
          # `size == 1` and not `one?`, which counts TRUTHY elements and so reads
          # "nil are not" for the commonest offender of all.
          "a replacement's content blocks must each be a Hash carrying \"type\"; " \
            "#{alien.map(&:inspect).join(", ")} #{alien.size == 1 ? "is" : "are"} not"
        end

        def refuse_blank(content)
          return unless content.empty? || content.any? { |block| blank_text?(block) }

          raise Blank, "a replacement whose content is #{content.inspect} renders an empty block, " \
                       "which the provider rejects; answer DROP to make the range vanish instead"
        end

        # `blank?` and not `strip.empty?`: ActiveSupport's reads a regex and
        # allocates nothing, where `strip` mints a String per block.
        def blank_text?(block) = block["type"] == "text" && block["text"].blank?
      end

      # The unit of that monoid: a collapsed range that vanishes, leaving no
      # replacement event at all. A distinct class rather than a {Replacement}
      # holding no content, because that is the thing this file refuses to build.
      Drop = Data.define do
        def content = NO_CONTENT

        def drop? = true

        def inspect = "Lain::Compaction::Strategy::DROP"
      end
      private_constant :Drop

      DROP = Drop.new.freeze
    end
  end
end
