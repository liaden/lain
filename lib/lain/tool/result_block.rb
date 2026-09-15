# frozen_string_literal: true

require "json"

module Lain
  class Tool
    # A read-only view over ONE tool_result block -- the string-keyed
    # `{ "type" => "tool_result", "tool_use_id" =>, "content" =>, "is_error" => }`
    # shape that IS the wire primitive. Same rule its read-side twin
    # {Response::ToolUse} states: `Canonical.normalize` rebuilds plain hashes and
    # raises on anything that is not one, so the hash stays the value and this is
    # only a lens onto it -- a committed digest cannot move because a caller
    # wrapped.
    #
    # {.of} is the write side, the ONE place a {Result} becomes a wire block, and
    # two correctness gates are constructor invariants here rather than four
    # lines in a dispatcher: gate 4 (the block names the tool_use it answers)
    # because {.of} refuses to build without an id, and gate 3 (a failed tool is
    # reported, never dropped) because `is_error` is read off the {Result} and
    # never inferred from the shape of the content.
    #
    # **{.of} is the SOLE writer of a string-keyed tool_result block in `lib/`,
    # reached only from `ToolRunner#delivery`.** That is what every named
    # reader's `fetch` rests on, so a second writer must either come through here
    # or retire the readers. `is_error` is OPTIONAL on Anthropic's wire and is
    # not optional on ours: a tool_result that reached a reader was built here,
    # with all four keys, so a missing one is a builder bug rather than a shape
    # to tolerate -- and readers may raise on it instead of reading a failure as
    # a success.
    class ResultBlock
      # How much of a malformed block {#field} quotes. A `read_file`-shaped
      # tool_result carries a whole file in `content`, so an unbounded `inspect`
      # puts a megabyte of it in an exception message and from there into
      # whatever logs it. The raised KeyError sets `receiver:`, so a rescue site
      # that wants the WHOLE block still has it; only the human-readable half is
      # capped.
      INSPECT_LIMIT = 300

      # The four keys are written in the order the wire documents them. That
      # order is a CONVENTION this one builder keeps, not an invariant anything
      # downstream can observe: `Canonical` sorts keys for the digest, and the
      # only NDJSON line carrying a tool_result (`request_sent`) has already been
      # through `normalize`. The spec pins the order so the sole builder cannot
      # drift from the documented shape; it does not pin any byte a replay diffs.
      #
      # The hash is FROZEN because this is the last place the block is a value
      # rather than a record. `ToolRunner` hands it to the observer seam after
      # #result_block and before `Timeline#commit`, so an observer writing
      # `block["content"]` would rewrite the committed experiment record after
      # gates 3 and 4 had been enforced -- measured, not feared. This does NOT
      # make the lens `Ractor.shareable?`: the freeze is shallow and a {Result}'s
      # content String is mutable. Shareability arrives after
      # `Canonical.normalize` deep-freezes the block, the shape {.wrap} sees.
      #
      # It is also the TEXT BOUNDARY: every String in a result's content, at
      # any depth, passes {Text.committable} here, so bytes `Canonical` would
      # refuse at commit -- after the tool ran and after its tool_use turn
      # committed -- become a refusal the ask can carry on past instead of a
      # raise that tears it. `tool` is the name that refusal gives the output.
      def self.of(result, tool_use_id:, tool: "this tool")
        refuse_unpaired(tool_use_id)
        committable = Text.committable(result, subject: "#{tool}'s output")

        new({
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => committable.content,
          "is_error" => committable.error?
        }.freeze)
      end

      # Re-lenses a block that has already been built (or has come back through
      # `Canonical.normalize`) so a reader gets the named accessors. Idempotent,
      # and `new` is private below because `new(wrap(hash))` nests a lens and
      # {#to_h} would then answer a lens where every caller -- and `Canonical` --
      # has been promised a Hash.
      #
      # A non-Hash subject is refused here rather than left to surface three
      # different ways downstream. The class is the whole diagnosis, so the
      # message quotes no value and cannot itself grow unbounded.
      def self.wrap(block)
        return block if block.is_a?(self)
        raise ArgumentError, "a tool_result lens wraps a Hash block, got #{block.class}" unless block.is_a?(Hash)

        new(block)
      end

      # Gate 4 is a *pairing*, so an id that cannot pair is refused where the
      # block is built. Most of the shapes this rejects are already unreachable
      # from a real turn, which is the point: `Response#initialize` normalizes,
      # `Canonical` maps Symbol to String, a block with no id raises `KeyError`
      # at {Response::ToolUse#id}, and both providers mint Strings. The one shape
      # genuinely foreclosed is a NUMERIC id, which Anthropic's wire rejects
      # anyway -- an ArgumentError at the sole builder beats a 400.
      #
      # The message names the class and never the value: an id is model-supplied
      # text. The empty String is the exception that proves it -- "got String"
      # names the RIGHT class and reads as a contradiction of the rule.
      def self.refuse_unpaired(tool_use_id)
        return if tool_use_id.is_a?(String) && !tool_use_id.empty?

        got = tool_use_id.is_a?(String) ? "an empty String" : tool_use_id.class.to_s
        raise ArgumentError, "a tool_result names the tool_use it answers with a non-empty String id, got #{got}"
      end
      private_class_method :refuse_unpaired

      def initialize(hash)
        @hash = hash
        freeze
      end
      private_class_method :new

      # The ORIGINAL hash, by identity (`equal?`, not a defensive copy) -- the
      # same rule {Context::MessageEnvelope#to_h} keeps, for the same reason.
      def to_h = @hash

      # Delegated, never inherited: without this a lens serializes as the `to_s`
      # of its own object header -- VALID JSON carrying a debug string, which the
      # NDJSON Journal accepts in silence where a raise would be caught. This
      # lens sits one hop from the Journal's `JSON.generate`, so the delegation
      # is what keeps a wrapped block honest there.
      def to_json(...) = @hash.to_json(...)

      def fetch(...) = @hash.fetch(...)

      # The compatibility ramp for consumers still reading raw keys off the
      # block; the named readers below are the intended surface.
      def [](key) = @hash[key]

      def tool_use_id = field("tool_use_id")

      def content = field("content")

      def error? = field("is_error")

      private

      # A `fetch`, not a `[]`: a tool_result missing one of its four keys is a
      # builder bug, and it surfaces here -- naming both the key and the block --
      # rather than as a nil that unpairs a result or reports a failure as a
      # success.
      def field(key)
        @hash.fetch(key) do
          raise KeyError.new("tool_result block has no #{key.inspect}: #{brief}", receiver: @hash, key:)
        end
      end

      def brief
        text = @hash.inspect
        text.length <= INSPECT_LIMIT ? text : "#{text[0, INSPECT_LIMIT]}... (#{text.length} chars)"
      end

      # One String a tool handed back, read as the UTF-8 text a commit can
      # take: bytes under a byte-transparent tag are text when they are valid
      # UTF-8. A subprocess buffer turns ASCII-8BIT at its first high byte,
      # valid UTF-8 included, so that tag says nothing about the bytes. Any other
      # tag is refused rather than transcoded -- the narrowing `ReadFile` makes,
      # since a value nobody converts would reach the model in one encoding and
      # the Timeline in another.
      #
      # This DEPARTS from the Rust `read_text` rule on one tag: `read_text`
      # refuses a US-ASCII tag over high bytes as mislabelled, and this reads
      # its bytes. A C locale tags whatever it reads US-ASCII, so a command's
      # perfectly good UTF-8 arrives in exactly that shape, and refusing it
      # would refuse ordinary output for the locale it ran under.
      #
      # Invalid bytes are refused, never scrubbed: a replacement character is a
      # byte the tool never produced.
      class Text
        BYTE_TRANSPARENT = [Encoding::UTF_8, Encoding::US_ASCII, Encoding::BINARY].freeze

        # What a refusal names when nothing closer to the bytes named them.
        SUBJECT = "this tool's output"

        # What a refusal advises when nothing closer to the bytes knows a
        # narrower command. Given the count of leading bytes that are text.
        ADVICE = ->(_kept) { "call the tool again for a narrower result, or for one that is text" }

        # @param result [Tool::Result]
        # @param subject [String] what a refusal calls the content
        # @return [Tool::Result] `result` itself when nothing needed re-tagging,
        #   a copy carrying UTF-8 text, or a refusal
        def self.committable(result, subject: SUBJECT)
          content = result.content
          texts = content.is_a?(String) ? new(content) : Content.new(content)
          texts.result_for(result, subject)
        end

        # @param string [String] never mutated: `force_encoding` would raise on a
        #   frozen literal and rewrite a String its tool still holds
        def initialize(string)
          @string = string
          @reading = string.encoding == Encoding::UTF_8 ? string : String.new(string, encoding: Encoding::UTF_8)
          freeze
        end

        def text? = byte_transparent? && @reading.valid_encoding?

        # The UTF-8 reading, which is the given String itself when it was one.
        def to_s = @reading

        def changed? = !@reading.equal?(@string)

        def result_for(result, subject = SUBJECT)
          return refusal(subject) unless text?

          changed? ? result.with(content: @reading) : result
        end

        # @param subject [String] what the bytes were, as the model would name them
        # @param advice [#call] `Integer -> String`, the narrower action, handed
        #   the count of leading bytes that are text (0 when none, or when the
        #   tag rules counting out)
        # @return [Tool::Result] an error carrying the verdict and none of the bytes
        def refusal(subject = SUBJECT, advice: ADVICE)
          kept = kept_bytes
          Tool::Result.error("#{subject} #{verdict(kept)}, so it cannot be recorded as part of this " \
                             "conversation -- instead, #{advice.call(kept)}")
        end

        private

        def byte_transparent? = BYTE_TRANSPARENT.include?(@string.encoding)

        # A foreign tag gets no count: Latin-1 "café" is good text under its own
        # tag, and "0 valid bytes" would misdescribe it.
        def verdict(kept)
          return "is tagged #{@string.encoding}, not UTF-8" unless byte_transparent?
          return "was not text: it does not begin with valid UTF-8" if kept.zero?

          "was not text: only its first #{kept} bytes are valid UTF-8"
        end

        # Character by character, and only on the refusal path: Ruby has no
        # call that answers where validity ends. Its cost is a few objects per
        # character, which bash's row in Tool::Bounds::CEILINGS caps before this runs.
        def kept_bytes
          return 0 unless byte_transparent?

          @reading.each_char.lazy.take_while(&:valid_encoding?).sum(&:bytesize)
        end
      end

      # Array content, judged as one answer: every String in it -- a text part,
      # a document title, image data, a bare element, a key -- is read as
      # {Text}, because `Canonical` checks every one at commit. One that is not
      # text refuses the whole result.
      class Content
        def initialize(content)
          @content = content
          @texts = enum_for(:each_string, content).each_with_object({}.compare_by_identity) do |string, texts|
            texts[string] = Text.new(string)
          end
          freeze
        end

        def result_for(result, subject)
          refused = @texts.values.reject(&:text?)
          return refused.first.refusal(subject) unless refused.empty?

          @texts.values.any?(&:changed?) ? result.with(content: retagged(@content)) : result
        end

        private

        def each_string(node, &)
          case node
          when String then yield node
          when Hash then node.each { |key, value| [key, value].each { |child| each_string(child, &) } }
          when Array then node.each { |child| each_string(child, &) }
          end
        end

        def retagged(node)
          case node
          when String then @texts.fetch(node).to_s
          when Hash then node.to_h { |key, value| [retagged(key), retagged(value)] }
          when Array then node.map { |child| retagged(child) }
          else node
          end
        end
      end
    end
  end
end
