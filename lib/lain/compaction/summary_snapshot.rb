# frozen_string_literal: true

module Lain
  module Compaction
    # A frozen, Ractor-shareable copy of what the eager summarizer had produced
    # as of one turn -- and therefore the `#call(Array<Hash>) -> String` duck
    # {Context::Compact} invokes (the whole dropped array in, one String out).
    #
    # It exists because a summarizer may never hold the live {Oracle::Eager}.
    # The Eager accumulates summaries as fires land, so it must stay mutable;
    # a {Context::Compact} referencing one is not `Ractor.shareable?`, and
    # {Scheduler::COMPOSE}'s `Ractor.make_shareable` then raises
    # `Ractor::IsolationError` on the first compacting turn -- in the live loop,
    # not in any spec that holds the summarizer by itself. Taking a snapshot
    # copies what is held NOW into a frozen map and cuts the reference, which
    # also makes the summarization deterministic for the render it feeds: a fire
    # landing mid-turn cannot change the bytes this turn's prompt is built from.
    #
    # It is keyed exactly as the Eager is -- by the SOURCE digest
    # {Effect::Handler::Summarizing} fires under -- so there is one key notion
    # in this file and no translation layer to drift.
    #
    # ALWAYS BUILD ONE WITH {.take}. `.new(summaries:)` is public only so that
    # `SummarySnapshot.new` can serve as the pure-elision default, and a
    # hand-built map is a live hazard: the validator rejects anything that is
    # not a content address, but a MESSAGE digest is a perfectly well-formed
    # content address and would miss every lookup, permanently and silently.
    # {#hits} and {#misses} cannot warn about it either -- a hand-built map
    # reports 0/0, which is indistinguishable from a snapshot taken over no
    # messages. `.take` derives the keys itself and is correct by construction.
    #
    # THE INVARIANT: nothing disappears unattested. Agent correctness gate 2
    # (`agent.rb:291`) commits every tool_result of one assistant turn into ONE
    # user message, so the ordinary parallel-tools turn is a message whose
    # blocks did not all cross Summarizing's byte threshold. Rendering such a
    # message as a single body would let the un-summarized blocks vanish behind
    # a line that reads as a complete summary of the turn. So the rendering is
    # per BLOCK: the message states its role, content address, canonical byte
    # count, and block count, and every block underneath states its own type,
    # size, and either its summary or an explicit elision. A reader can always
    # tell what was there and fetch the original from the Store by address.
    #
    # That attestation is also the honest degradation: {Oracle::Eager#held}
    # returns nil both for "never summarized" and for "still in flight", and
    # this object deliberately does not try to tell those apart. What it does
    # instead is COUNT -- see {#hits} and {#misses}, the bench's read on whether
    # the fires are landing at all.
    class SummarySnapshot
      # A key that is not a content address would be a permanent, total,
      # silent miss. Loud instead, per CLAUDE.md's unknown-values premise.
      class NotADigest < Error; end

      # The body of a line with no summary behind it. The attestation carries
      # the facts; this says only that the bytes are gone.
      ELIDED = "(elided -- no summary held)"

      # `Compact` calls its summarizer even when `protected_patterns` exempted
      # every dropped message, and an empty String here becomes a `text` block
      # with empty text -- which Anthropic rejects outright.
      NOTHING = "(nothing to summarize)"

      # Interpolation returns a MUTABLE String even under frozen_string_literal
      # (CLAUDE.md's trap), and this one is reachable from a constant.
      DIGEST_PREFIX = "#{Canonical::DIGEST_ALGORITHM}:".freeze

      # The EXACT shape `Canonical.digest` emits, measured from a real digest
      # rather than hardcoded, so it tracks the algorithm. Length and case are
      # both load-bearing: `blake3:a` and an uppercased digest satisfy a looser
      # `\h+` pattern yet can never equal a key Summarizing fired -- admitting
      # them would be precisely the permanent, total, silent miss this rejects.
      #
      # Measured on FIRST USE, not in the class body: `Canonical.digest` reaches
      # into the Rust extension, which `lain.rb` requires at :71 while this unit
      # loads at :24, so taking a digest at load time is a `NameError` on
      # `Lain::Ext`. Nothing loaded before that line may hash during load.
      def self.digest_format
        @digest_format ||= begin
          hex_length = Canonical.digest("").delete_prefix(DIGEST_PREFIX).length
          /\A#{Regexp.escape(DIGEST_PREFIX)}[0-9a-f]{#{hex_length}}\z/
        end
      end

      # What a message's content is made of, and which parts could carry a
      # summary. Shared by {.take}, which reads the Eager, and `#call`, which
      # renders -- so the two can never disagree about which parts are
      # lookupable, which is exactly the disagreement that would leave one
      # silently unattested.
      module Blocks
        module_function

        # EVERY element of an Array content, not just the Hashes. Filtering to
        # blocks would drop a non-Hash element silently AND understate the count
        # stated one line above it -- the same silence the per-block rendering
        # exists to end. A String content (an ordinary text turn) has no parts
        # at all: nothing addressable inside it, and Summarizing never fires on
        # one.
        def of(message)
          content = message["content"]
          content.is_a?(Array) ? content : []
        end

        # Byte-for-byte the key `summarizing.rb:56` fires under: the digest of
        # the Tool::Result's String, which the committed message carries
        # verbatim inside its tool_result block. A spec proves the round trip
        # end to end; if it ever broke, every lookup would miss in silence.
        def source_digest(part)
          Canonical.digest(part["content"]) if summarizable?(part)
        end

        # Only a Hash is a wire content block. Anything else is still content
        # being dropped, so it is named by its class and attested like the rest.
        def type_of(part) = part.is_a?(Hash) ? part["type"] : part.class.name

        def summarizable?(part)
          part.is_a?(Hash) && part["type"] == "tool_result" && part["content"].is_a?(String)
        end
      end
      private_constant :Blocks

      # How many lookupable blocks the take found a summary for, and how many it
      # did not -- counted per BLOCK OCCURRENCE over the messages {.take} was
      # given, since the snapshot is frozen and cannot tally during `#call`.
      # `hits.zero?` with `misses` high is the signature of a key regression,
      # which this card's escalation trigger names as the failure that would
      # otherwise be invisible in the experiment record. A6/A8 journal these;
      # nothing here touches the Journal.
      attr_reader :hits, :misses

      # Read the Eager once, over the messages this turn might drop, and keep
      # only the answers -- never the Eager itself.
      #
      # @param messages [Array<Hash>] rendered messages, `{"role" =>, "content" =>}`
      # @param eager [#held] the live summary store, read here and released
      # @return [SummarySnapshot]
      def self.take(messages:, eager:)
        digests = messages.flat_map { |message| source_digests(message) }
        found = digests.uniq.to_h { |digest| [digest, eager.held(digest)] }.compact.transform_values(&:summary)
        hits = digests.count { |digest| found.key?(digest) }
        new(summaries: found, hits:, misses: digests.size - hits)
      end

      def self.source_digests(message)
        Blocks.of(message).filter_map { |block| Blocks.source_digest(block) }
      end
      private_class_method :source_digests

      # @param summaries [Hash{String=>String}] SOURCE digest => summary text.
      #   The empty default is meaningful, not a placeholder: it is the
      #   pure-elision summarizer, which is what a run with no oracle wired gets.
      # @param hits [Integer] see {#hits}. Both counts default to zero because
      #   they describe a TAKE, and a hand-built map was measured against no
      #   messages at all: a snapshot that claimed `summaries.size` hits it
      #   never verified is precisely how a mis-keyed map could hide.
      # @param misses [Integer] see {#misses}
      def initialize(summaries: {}, hits: 0, misses: 0)
        # `-string` both freezes and dedups. An oracle answer's String arrives
        # MUTABLE, and one mutable String reachable from here costs this object
        # the shareability it exists to have.
        #
        # A blank summary is dropped rather than stored, so it renders as the
        # miss it is instead of a blank body: `.take` can never produce one (the
        # answer schema requires the field), and the two paths must not diverge.
        @summaries = summaries.to_h { |digest, text| [digest_key(digest), -text.to_s] }
                              .reject { |_, text| text.strip.empty? }
                              .freeze
        @hits = Integer(hits)
        @misses = Integer(misses)
        freeze
      end

      # @param dropped [Array<Hash>] every message being dropped, at once
      # @return [String] an attested line per dropped message, each followed by
      #   one line per content block it carried
      def call(dropped)
        return NOTHING if dropped.empty?

        dropped.map { |message| render(message) }.join("\n")
      end

      private

      def render(message)
        lines = Blocks.of(message).map { |part| block_line(part) }
        return "[#{attest(message)}] #{ELIDED}" if lines.empty?

        ["[#{attest(message)}, #{pluralize(lines.size, "block")}]", *lines].join("\n")
      end

      def pluralize(count, noun) = "#{count} #{noun}#{"s" unless count == 1}"

      # The role is ours -- every writer in `lib/` commits one -- so a missing
      # one is a caller bug, not a blank to render past.
      def attest(message)
        "#{message.fetch("role")} #{Canonical.digest(message)} #{Canonical.dump(message).bytesize} bytes"
      end

      # `compact` drops the two facts a part may not have: a lookup key (only
      # a String-content tool_result has one) and, unlike the role above, a
      # type -- provider content is not ours to insist on, and a typeless block
      # must still earn a line rather than vanish.
      def block_line(part)
        key = Blocks.source_digest(part)
        facts = [Blocks.type_of(part), key, "#{Canonical.dump(part).bytesize} bytes"].compact.join(" ")
        "- [#{facts}] #{@summaries.fetch(key, ELIDED)}"
      end

      def digest_key(digest)
        raise NotADigest, "summary keys must be content addresses, got #{digest.inspect}" unless digest?(digest)

        -digest
      end

      def digest?(value) = value.is_a?(String) && self.class.digest_format.match?(value)
    end
  end
end
