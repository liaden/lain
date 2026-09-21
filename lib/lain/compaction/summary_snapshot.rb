# frozen_string_literal: true

module Lain
  module Compaction
    # A frozen, Ractor-shareable copy of what the eager summarizer had produced
    # as of one turn -- and therefore the `#call(Array<Hash>) -> String` duck
    # {Context::Compact} invokes (the whole dropped array in, one String out).
    #
    # It exists because a summarizer may never hold the live {Oracle::Eager}.
    # The Eager accumulates summaries as fires land, so it must stay mutable; a
    # {Context::Compact} referencing one is not `Ractor.shareable?`, and
    # {Scheduler::COMPOSE}'s `Ractor.make_shareable` then raises
    # `Ractor::IsolationError` on the first compacting turn -- in the live loop,
    # not in any spec that holds the summarizer by itself. Taking a snapshot
    # copies what is held NOW into a frozen map and cuts the reference, which
    # also makes the summarization deterministic for the render it feeds: a fire
    # landing mid-turn cannot change the bytes this turn's prompt is built from.
    #
    # It is keyed exactly as the Eager is -- by the SOURCE digest
    # {SummaryObserver} fires under -- so there is one key notion
    # here and no translation layer to drift.
    #
    # ALWAYS BUILD ONE WITH {.take}. `.new(summaries:)` is public only so that
    # `SummarySnapshot.new` can serve as the pure-elision default, and a
    # hand-built map is a live hazard: the validator rejects anything that is
    # not a content address, but a MESSAGE digest is a perfectly well-formed
    # content address and would miss every lookup, permanently and silently.
    # {#hits} and {#misses} cannot warn about it either -- a hand-built map
    # reports 0/0, indistinguishable from a snapshot taken over no messages.
    #
    # THE INVARIANT: nothing disappears unattested. Every tool_result of one
    # assistant turn is committed into ONE user message, so the ordinary
    # parallel-tools turn is a message whose blocks were not all summarized.
    # Rendering such a message as a single body
    # would let the un-summarized blocks vanish behind a line reading as a
    # complete summary of the turn. So the rendering is per BLOCK, and a reader
    # can always tell what was there and fetch the original by address.
    #
    # That attestation is also the honest degradation: {Oracle::Eager#held}
    # returns nil both for "never summarized" and for "still in flight", and
    # this object does not try to tell those apart. What it does instead is
    # COUNT -- {#hits} and {#misses}, the bench's read on whether the fires are
    # landing at all.
    #
    # {#size_declined_misses} narrows one corner of that same nil, the one
    # corner this object CAN name without asking the oracle anything: how many
    # misses were a block {Oracle::RoutedSummarizer} would have declined on
    # SIZE alone and so never asked a model about at all. The gate is a
    # WINDOW, not a floor -- `bytes > MODEL_THRESHOLD_BYTES && input_bound
    # admits it` -- so a block can be declined from either edge: too small to
    # be worth a call, or too large for one to serve (`INPUT_BOUND`'s 256 KiB,
    # which a routine 5 MiB `web_fetch` body clears every day). Both edges
    # decline identically -- no model asked, no catalog entry gated by size at
    # all -- so both count. That needs no oracle state -- only the byte count
    # {.take} already read off the block it is attesting -- so it is legible
    # even when a miss on its own reads exactly like a summarizer that is down.
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

      # Interpolation returns a MUTABLE String even under
      # frozen_string_literal, and this one is reachable from a constant.
      DIGEST_PREFIX = "#{Canonical::DIGEST_ALGORITHM}:".freeze

      # The EXACT shape `Canonical.digest` emits, measured from a real digest
      # rather than hardcoded, so it tracks the algorithm. Length and case are
      # both load-bearing: `blake3:a` and an uppercased digest satisfy a looser
      # `\h+` pattern yet can never equal a key {SummaryObserver} fired.
      #
      # Measured on FIRST USE, not in the class body, so the pattern is taken
      # once and only by a caller that actually reads one: a digest computed
      # while this file loads would be work every boot does for a snapshot most
      # never take.
      def self.digest_format
        @digest_format ||= begin
          hex_length = Canonical.digest("").delete_prefix(DIGEST_PREFIX).length
          /\A#{Regexp.escape(DIGEST_PREFIX)}[0-9a-f]{#{hex_length}}\z/
        end
      end

      # What a message's content is made of, and which parts could carry a
      # summary. Shared by {.take}, which reads the Eager, and `#call`, which
      # renders, so the two cannot disagree about which parts are lookupable --
      # the disagreement that would leave one silently unattested.
      module Blocks
        module_function

        # EVERY element of an Array content, not just the Hashes: filtering to
        # blocks would drop a non-Hash element silently AND understate the
        # count stated one line above it. A String content has no parts at all.
        def of(message)
          content = message["content"]
          content.is_a?(Array) ? content : []
        end

        # Byte-for-byte the key {SummaryObserver} fires under: the
        # digest of the Tool::Result's String, which the committed message
        # carries verbatim inside its tool_result block. A spec proves the round
        # trip end to end; if it broke, every lookup would miss in silence.
        def source_digest(part)
          Canonical.digest(part["content"]) if summarizable?(part)
        end

        # The tool's own bytes, measured the same way
        # {Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES} measures them --
        # `#bytesize` on the content String directly, never a `Canonical.dump`,
        # which would count a wire wrapper the gate was never compared against.
        def source_bytes(part)
          part["content"].bytesize if summarizable?(part)
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
      # which is otherwise invisible in the experiment record.
      #
      # `size_declined_misses` counts, of `misses` above, how many were a
      # block {Oracle::RoutedSummarizer}'s size gate would have declined
      # outright -- see the class doc for why that gate is a window and not a
      # floor. Summed rather than a Boolean so it composes the way `hits` and
      # `misses` already do: {Strategy::Composed} adds two operands' counts
      # rather than having to decide which operand's yes-or-no wins.
      attr_reader :hits, :misses, :size_declined_misses

      # Read the Eager once, over the messages this turn might drop, and keep
      # only the answers -- never the Eager itself.
      #
      # @param messages [Array<Hash>] rendered messages, `{"role" =>, "content" =>}`
      # @param eager [#held] the live summary store, read here and released
      # @return [SummarySnapshot]
      def self.take(messages:, eager:)
        candidates = summarizable_candidates(messages)
        digests = candidates.map(&:digest)
        found = digests.uniq.to_h { |digest| [digest, eager.held(digest)] }.compact.transform_values(&:summary)
        hits = digests.count { |digest| found.key?(digest) }
        missed = candidates.reject { |candidate| found.key?(candidate.digest) }
        new(summaries: found, hits:, misses: digests.size - hits, size_declined_misses: declined_misses(missed))
      end

      # One lookupable block, paired with the digest it is keyed under -- the
      # thing {.take} actually reasons about once a summary search has run,
      # named so a MISSED one (see {.declined_misses}) is a filter over real
      # values rather than a re-zip of two parallel arrays.
      Candidate = Struct.new(:part, :digest)
      private_constant :Candidate

      def self.summarizable_candidates(messages)
        messages.flat_map { |message| Blocks.of(message) }
                .select { |part| Blocks.summarizable?(part) }
                .map { |part| Candidate.new(part, Blocks.source_digest(part)) }
      end
      private_class_method :summarizable_candidates

      # How many MISSED candidates {Oracle::RoutedSummarizer}'s size gate would
      # have declined outright, from either edge of its window -- see the class
      # doc and {#size_declined_misses}.
      def self.declined_misses(missed)
        missed.count { |candidate| !gate_admits?(Blocks.source_bytes(candidate.part)) }
      end
      private_class_method :declined_misses

      # The window {Oracle::RoutedSummarizer#worth_a_model_call?} gates the
      # PAID tier on, read back the same way: strictly over the threshold
      # (worth asking) AND small enough for the ceiling to admit (small enough
      # to serve). Outside either edge the gate declines and no model is ever
      # asked -- checking only the threshold, as an earlier draft did, read a
      # routine over-ceiling decline (256 KiB, well under
      # `Tools::WebFetch::DEFAULT_BYTE_CAP`'s 5 MiB) as an unexplained miss.
      def self.gate_admits?(bytes)
        bytes > Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES && Oracle::RoutedSummarizer::INPUT_BOUND.admits?(bytes)
      end
      private_class_method :gate_admits?

      # @param summaries [Hash{String=>String}] SOURCE digest => summary text.
      #   The empty default is meaningful, not a placeholder: it is the
      #   pure-elision summarizer, which is what a run with no oracle wired gets.
      # @param hits [Integer] see {#hits}. Both counts default to zero because
      #   they describe a TAKE, and a hand-built map was measured against no
      #   messages at all: a snapshot claiming `summaries.size` hits it never
      #   verified is precisely how a mis-keyed map could hide.
      # @param misses [Integer] see {#misses}
      # @param size_declined_misses [Integer] see {#size_declined_misses}
      def initialize(summaries: {}, hits: 0, misses: 0, size_declined_misses: 0)
        # `-string` both freezes and dedups. An oracle answer's String arrives
        # MUTABLE, and one mutable String reachable from here costs this object
        # the shareability it exists to have.
        #
        # A blank summary is dropped rather than stored, so it renders as the
        # miss it is instead of a blank body. `.take` can never produce one --
        # the answer schema requires the field -- and the paths must not diverge.
        @summaries = summaries.to_h { |digest, text| [digest_key(digest), -text.to_s] }
                              .reject { |_, text| text.strip.empty? }
                              .freeze
        @hits = Integer(hits)
        @misses = Integer(misses)
        @size_declined_misses = Integer(size_declined_misses)
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
