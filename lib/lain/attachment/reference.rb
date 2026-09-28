# frozen_string_literal: true

module Lain
  module Attachment
    Reference = Data.define(:digest, :media_type)

    # The address of one image, and the whole vocabulary of the neutral image
    # block both provider encoders read.
    #
    # Two spellings of one block, and every consumer here is about the move
    # between them. ADDRESSED is what rides the Timeline, the journal and a
    # `child_turn` record: about a hundred bytes, one per distinct picture.
    # INLINE is what goes on the wire, and it is put back by
    # {Middleware::ResolveAttachments} at the last hop out -- because base64 is
    # valid UTF-8, so a payload that reached {Canonical.normalize} would be
    # interned by `-@` in silence and for the life of the process, and because
    # {Context#render} is pure and a store read is not.
    #
    # The block wears Anthropic's own shape, chosen as the neutral one for a
    # reason that outlives the choice: base64 is ASCII, so a block in this shape
    # passes {Canonical}, the UTF-8 check in {Tool::ResultBlock::Content} and
    # `Ractor.shareable?` with nothing added anywhere. Ollama's `images` array
    # is that encoder's own business ({Provider::Ollama::Encoding}), and what it
    # reads out of a block it reads through {.data_in} rather than by knowing
    # Anthropic's field names. `"image"` needs no place in
    # {Context::Conversation::BLOCK_ROLES}, which says a type absent from it may
    # ride any role -- and a picture rides a user turn, an assistant turn and a
    # tool_result alike.
    #
    # A `Data`, and REOPENED rather than carrying a `do ... end` block, for the
    # two traps that shape intersects: a constant written inside that block binds
    # to {Attachment} rather than to this class, and a docstring on the
    # assignment would be the second of two, one of which YARD discards. So the
    # assignment is bare and everything -- constants, validation, both readers'
    # prose -- lives here.
    #
    # The `Data` is what makes `#with` exist, and `#with` goes through
    # {#initialize} like `.new` does: there is no door into this value that skips
    # the two refusals or the freeze.
    #
    # @!attribute [r] digest
    #   @return [String] the content address, in {Store}'s own canonical spelling
    # @!attribute [r] media_type
    #   @return [String] the media type, as the bytes' own signature gave it
    class Reference
      # An address that reached an encoder with nobody having put the bytes
      # back. Loud rather than dropped: a turn sent without its picture answers
      # a question about something the model never saw.
      class Unresolved < Error; end

      # The block's own `type`, and the two `source` types between which the
      # whole subsystem moves. All three are wire-visible spellings, so they are
      # named rather than written thirteen times.
      BLOCK_TYPE = "image"
      ADDRESSED = "attachment"
      INLINE = "base64"

      # A `source` no block carried, so `source(block)[TYPE]` answers for a text
      # block, a bare String and a malformed image alike without a guard at each
      # reader.
      NO_SOURCE = {}.freeze
      private_constant :NO_SOURCE

      TYPE = "type"
      SOURCE = "source"
      MEDIA_TYPE = "media_type"
      DIGEST = "digest"
      DATA = "data"
      private_constant :TYPE, :SOURCE, :MEDIA_TYPE, :DIGEST, :DATA

      # Case-insensitive, both of them, because both members normalize case: RFC
      # 6838 makes a media type case-insensitive, and a hex digest's case is a
      # spelling of the same number. One pattern per member, read by the
      # constructor that normalizes AND by the predicate that recognizes, so a
      # block this subsystem would accept and a value it would build cannot
      # disagree about what an address is.
      ADDRESS = /\A#{Canonical::DIGEST_ALGORITHM}:\h{64}\z/i
      MEDIA = %r{\Aimage/[a-z0-9][a-z0-9.+-]*\z}i
      private_constant :ADDRESS, :MEDIA

      # Both members are interned, which is the bound this whole subsystem rests
      # on: one ~71-byte fstring per distinct picture, however many turns refer
      # to it.
      #
      # @param digest [String] a {Store} address, prefix included
      # @param media_type [String] `image/...`
      # @raise [ArgumentError] on either written in a spelling {Store} would
      #   not answer to, or on a media type that is not an image's
      def initialize(digest:, media_type:)
        super(digest: address(digest), media_type: kind(media_type))
      end

      # @return [Hash] the block that rides the Timeline, deeply frozen
      def block = wrap(TYPE => ADDRESSED, MEDIA_TYPE => media_type, DIGEST => digest)

      # @param bytes [String] the stored bytes, as {Store#fetch} hands them over
      # @return [Hash] the block that goes on the wire, deeply frozen
      def inline(bytes) = wrap(TYPE => INLINE, MEDIA_TYPE => media_type, DATA => base64(bytes))

      def to_s = "#<#{self.class} #{media_type} #{digest}>"
      alias inspect to_s

      class << self
        # A LOOKALIKE is simply not an address, which is why this asks for a
        # well-formed source rather than only for the source TYPE. Model-authored
        # content lands on the Timeline verbatim and `"image"` is deliberately
        # absent from {Context::Conversation::BLOCK_ROLES}, so a block read as an
        # address it cannot satisfy would have {.of} refuse it from inside the
        # model phase on EVERY later render of that chain -- poisoning it, naming
        # neither the turn nor the picture, and reaching the model as a tool error
        # with its class stripped, since {Effect::Handler::Live#run} turns any
        # StandardError into a `Tool::Result.error`. Unrecognized instead, it
        # stays exactly what it is: a block this subsystem did not write.
        #
        # @param block [Object]
        # @return [Boolean] whether it is an address with no bytes behind it yet
        def addressed?(block) = image?(block, ADDRESSED) && well_formed?(source(block))

        # @param block [Object]
        # @return [Boolean] whether it is a block already carrying its bytes
        def inline?(block) = image?(block, INLINE)

        # @param block [Hash] one {.addressed?} answered true for
        # @return [Reference]
        def of(block)
          source = source(block)
          new(digest: source[DIGEST], media_type: source[MEDIA_TYPE])
        end

        # Every address in `payload` that still has no bytes behind it, at any
        # nesting: a tool_result's content nests, and that is exactly where a
        # tool's picture arrives.
        #
        # @param payload [Object] a message list, one message, or one block
        # @return [Enumerator<Reference>]
        def each_in(payload, &found)
          return to_enum(:each_in, payload) unless found

          deep(payload) { |block| yield(of(block)) if addressed?(block) }
        end

        # @param payload [Object]
        # @return [Object] `payload`
        # @raise [Unresolved] naming every address nobody resolved
        def refuse_unresolved!(payload)
          pending = each_in(payload).to_a
          return payload if pending.empty?

          raise Unresolved,
                "#{pending.size} image#{"s" unless pending.one?} reached the provider encoder as an address " \
                "(#{pending.map(&:digest).join(", ")}): put Lain::Middleware::ResolveAttachments in the model " \
                "stack, innermost, or the turn asks about a picture the model never saw"
        end

        # `payload` with every address replaced by the bytes the block answers
        # for it, deeply frozen, and the payload ITSELF when it holds none --
        # which is the path almost every request takes, so it copies nothing.
        #
        # @param payload [Object]
        # @yieldparam reference [Reference]
        # @yieldreturn [String] that reference's bytes
        # @return [Object]
        def resolve(payload, &bytes)
          case payload
          when Hash then resolve_hash(payload, &bytes)
          when Array then payload.map { |member| resolve(member, &bytes) }.freeze
          else payload
          end
        end

        # The base64 of every inline picture in `payload`, in the order the
        # blocks stand -- what Ollama's `images` array wants, read through this
        # rather than by that encoder knowing the block's field names.
        #
        # @param payload [Object]
        # @return [Array<String>]
        def data_in(payload)
          found = []
          deep(payload) { |block| found << source(block)[DATA] if inline?(block) }
          found
        end

        private

        def image?(block, source_type)
          block.is_a?(Hash) && block[TYPE] == BLOCK_TYPE &&
            source(block)[TYPE] == source_type
        end

        def well_formed?(source) = spelled?(source[DIGEST], ADDRESS) && spelled?(source[MEDIA_TYPE], MEDIA)

        def spelled?(value, pattern) = value.is_a?(String) && value.match?(pattern)

        def source(block)
          held = block.is_a?(Hash) ? block[SOURCE] : nil
          held.is_a?(Hash) ? held : NO_SOURCE
        end

        # Every Hash in `payload`, outermost first. A block's own `source` is
        # visited too and answers no predicate here, which costs one comparison
        # and saves this walk having to know which keys nest.
        def deep(payload, &visit)
          case payload
          when Hash then visit_hash(payload, &visit)
          when Array then payload.each { |member| deep(member, &visit) }
          end
          payload
        end

        def visit_hash(hash, &visit)
          yield(hash)
          hash.each_value { |value| deep(value, &visit) }
        end

        # MERGED into the block, never substituted for it: a block carries more
        # than its source. {Context::CacheBreakpoints} is in the default pipeline
        # and marks a message's LAST block, and a screenshot turn is
        # `[text, image]`, so the breakpoint lands on the ADDRESS -- substitution
        # threw it away and Anthropic then received the turn with no
        # `cache_control` at all, at the full input price of the whole prefix and
        # with nothing said anywhere. {Workspace::WORKSPACE_MARKER} rode the same
        # key and went the same way.
        def resolve_hash(hash, &bytes)
          return hash.transform_values { |value| resolve(value, &bytes) }.freeze unless addressed?(hash)

          of(hash).then { |reference| hash.merge(reference.inline(yield(reference))).freeze }
        end
      end

      private

      # Frozen, and deliberately NOT interned: `-@` would hold a few hundred
      # kilobytes of base64 for the life of the process, which is the cost the
      # address exists to avoid.
      def base64(bytes) = [bytes].pack("m0").force_encoding(Encoding::UTF_8).freeze

      def wrap(source) = { TYPE => BLOCK_TYPE, SOURCE => source.freeze }.freeze

      # {Store} refuses a bare hex digest on purpose, so an address is held in
      # the one spelling every door there answers to, prefix included -- and
      # DOWN-CASED for the same reason {Store#canonical} down-cases: case is a
      # spelling of the same number, so two references to one picture that
      # differed only in case would fetch the same bytes while comparing
      # unequal, which is a Merkle claim the block would be making falsely.
      def address(digest)
        written = digest.to_s.downcase
        raise ArgumentError, "not a #{Canonical::DIGEST_ALGORITHM} address: #{digest.inspect}" unless
          written.match?(ADDRESS)

        -written
      end

      # Down-cased for {#address}'s reason, one axis over: RFC 6838 makes a media
      # type case-insensitive, so two members of one value must not answer the
      # same spelling variance two different ways.
      def kind(media_type)
        written = media_type.to_s.downcase
        raise ArgumentError, "not an image media type: #{media_type.inspect}" unless written.match?(MEDIA)

        -written
      end
    end
  end
end
