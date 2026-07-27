# frozen_string_literal: true

# `String#blank?` is the allocation-free blank test the per-block refusal below
# turns on, and it is NOT part of bare `active_support` -- requiring only that
# leaves `#blank?` undefined and the refusal silently evaporating. The core_ext
# require raises unless `active_support` is loaded first (CLAUDE.md's trap), so
# the order of these two lines is load-bearing.
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

      # Blocks that have already been through {Replacement}'s vetting, wrapped so
      # that a second opinion costs an `is_a?` rather than another walk. Private,
      # and it cannot be reached BY ACCIDENT: {Concatenation#+} is its only
      # producer, and `#content` unwraps it on the way in, so one never escapes
      # into a caller's hands. It is not unforgeable -- `private_constant` has
      # never stopped `const_get` -- which is why the fast path still asserts the
      # invariant it is skipping the work for.
      #
      # This is what makes the fold `#+` invites cheap AND still checked. Both
      # properties {Replacement} enforces are preserved by concatenation -- every
      # block of `a ++ b` is a block of `a` or of `b`, so if neither carried a
      # foreign or blank block, nor does the join. Re-deriving that at every step
      # is what turned `inject(:+)` quadratic.
      Vetted = Data.define(:blocks)
      private_constant :Vetted

      # Concatenation, shared by the two shapes a collapse can answer. It is one
      # method in one place because {Replacement} and DROP are different classes
      # by necessity -- DROP carries no content, and a content-bearing
      # {Replacement} refuses to -- while `++` on the free monoid has to be ONE
      # operation or the monoid laws are being asserted about two.
      #
      # Both units short-circuit to the other operand ITSELF, which is what makes
      # `DROP + a` and `a + DROP` return `a` rather than an equal copy. That is
      # the unit law read strictly, and it is also the fold that actually
      # happens: most ranges in a span collapse to nothing.
      module Concatenation
        def +(other)
          return other if content.empty?
          return self if other.content.empty?

          # Frozen, so the shareability step sees an already-shareable graph and
          # copies nothing: both operands' blocks were made shareable when they
          # were built.
          Replacement.of(Vetted.new(blocks: (content + other.content).freeze))
        end
      end
      private_constant :Concatenation

      # What replaces one collapsed range: CONTENT BLOCKS, and nothing else.
      #
      # There is no role here and no way to add one. The Messages API requires
      # `messages[0]` to be `user`, and with no pins the replacement IS
      # `messages[0]`, so the role is decided in exactly one place -- the
      # derivation -- and a strategy never picks one. An earlier draft of this
      # chunk decided it in four places; a value that cannot carry a role is what
      # makes that impossible rather than merely discouraged.
      #
      # == What counts as content
      #
      # An Array of Hashes, each carrying a `"type"`. That one check refuses
      # every shape a hand-written `#blocks` (or a hand-written per-element map
      # generated over it) actually produces by mistake: a bare Hash where an
      # Array was meant -- `Elementwise`'s own doc flags exactly that as the live
      # per-element error -- a `nil` among good blocks, a bare String, an empty
      # Hash, and a whole MESSAGE (`{"role" =>, "content" =>}`) posing as a
      # block. A `Replacement` holding any of them would render as garbage on the
      # wire, and a bare Hash would additionally die inside `#+` on `Hash#+`.
      #
      # == Blankness is per block, not per body
      #
      # Anthropic rejects the request if ANY text block is empty, not only if the
      # whole body is -- the wire fact {SummarySnapshot::NOTHING} exists for. So
      # `[empty_text, good_text]` is refused; an earlier all-blank reading let it
      # through, and 15 concatenations of a modest pool then carried an empty
      # block. Only a TEXT block can be blank: a `tool_use` carries no `"text"`
      # and is content all the same.
      #
      # == Two constructors, and why they disagree about emptiness
      #
      # `.new` refuses empty content; `.of` is the map INTO the free monoid, so
      # it answers the unit (DROP) for no blocks at all rather than minting a
      # blank replacement. They are not in tension: "no blocks" and "a block with
      # nothing in it" are different answers, and only the second is a bug.
      #
      # A deeply frozen value: content is made shareable on the way in, copying
      # the idiom {Head} uses (`head.rb:75`) so a caller's own blocks are neither
      # frozen underneath it nor reachable from here. Content that is ALREADY
      # shareable is kept as it is -- copying it would buy nothing, and this is
      # the path `#+` takes.
      Replacement = Data.define(:content) do
        include Concatenation
        include Algebra::Monoid

        # The free monoid's map: blocks in, a replacement or the unit out.
        def self.of(blocks) = blocks.is_a?(Array) && blocks.empty? ? DROP : new(content: blocks)

        # The one-text-block case, which is what a summarizing or an eliding
        # strategy answers. A blank body is refused by `.new`, where the refusal
        # belongs.
        def self.text(body) = of([{ "type" => "text", "text" => body }])

        def initialize(content:) = super(content: vetted(content))

        # A Null-Object pair with DROP, so no caller writes `if replacement`.
        def drop? = false

        private

        def vetted(content)
          return pre_vetted(content.blocks) if content.is_a?(Vetted)

          refuse_foreign(content)
          refuse_blank(content)
          # Already-shareable content is kept as it is. Copying it would buy
          # nothing, and this is the path a concatenation takes.
          Ractor.shareable?(content) ? content : Ractor.make_shareable(content, copy: true)
        end

        # The deep-freeze invariant, kept by the VALUE rather than by the caller
        # of the fast path. Skipping the walk is sound because concatenation
        # preserves both refusals; skipping the shareability step would move the
        # invariant into `#+`, and CLAUDE.md records that an invariant maintained
        # somewhere other than the value it belongs to is the shape that broke
        # once. An O(1) flag read is a cheap price for keeping it here.
        def pre_vetted(blocks)
          return blocks if Ractor.shareable?(blocks)

          raise NotBlocks, "pre-vetted content #{blocks.inspect} is not shareable; a replacement's " \
                           "content is deeply frozen, and the fast path may not be the exception"
        end

        # Both refusals walk the content without allocating: `#+` invites a fold,
        # so a scan that built a String (or an Array) per block would be
        # quadratic in garbage for a value that is checked on every step. The
        # offenders are collected only once there is something to name.
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

        # Below the methods it names, and lazily, because the unit is an INSTANCE
        # built after this class body closes -- exactly {Context::Combinator}'s
        # situation with {Context::Identity}.
        monoid on: :+, identity: Algebra.later { DROP }
      end

      # The unit of that monoid: a collapsed range that vanishes, leaving no
      # replacement event at all. A distinct class rather than a {Replacement}
      # holding no content, because a replacement holding no content is the thing
      # this file refuses to build.
      Drop = Data.define do
        include Concatenation

        def content = NO_CONTENT

        def drop? = true

        def inspect = "Lain::Compaction::Strategy::DROP"
      end
      private_constant :Drop

      DROP = Drop.new.freeze
    end
  end
end
