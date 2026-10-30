# frozen_string_literal: true

module Lain
  module CLI
    class Watch
      # Decides whether a journal record chains to the watched spawn S, an actor or a one-shot
      # alike, by stepping {Journal::Projection::Lineage} as the records arrive: the same fold
      # {Bench::Session::Lineages} reads a closed file through, so the live view and the read-back
      # agree. Only {Telemetry::Message} records are ever admitted: `turn` records are the PARENT's
      # render chain, and a child's own turns arrive as `child_turn` records this view does not render.
      #
      # Anchoring is FIRST-MATCH: a stream cannot know whether a second match is still to come, so
      # the first spawn record the selector matches is the one watched, and every LATER matching
      # spawn is reported through `on_shadowed` -- named once, then ignored -- rather than silently
      # merging two lineages into one view. Pick a longer prefix to watch the other one.
      class LineageFilter
        # The anchoring spawn's digest; nil until a spawn matches.
        attr_reader :anchor

        # @param selector [String] a prefix of the watched spawn's digest
        # @param on_shadowed [#call] invoked with each LATER spawn digest the
        #   selector also matches; the caller owns saying so out loud
        def initialize(selector:, on_shadowed: ->(_digest) {})
          @selector = selector
          @on_shadowed = on_shadowed
          @anchor = nil
          @lineages = Journal::Projection::Lineage.unit
        end

        # @return [Boolean] whether any spawn has anchored the lineage yet
        def anchored? = !@anchor.nil?

        # @param record [Telemetry::Journalable, Telemetry::Untyped] one journal record, as
        #   {Telemetry.read} answers it
        # @return [Boolean] whether the record chains to the watched spawn
        def admit?(record)
          @lineages = @lineages.step(record)
          return false unless record.is_a?(Telemetry::Message)

          anchors(record)
          anchored? && @lineages.member?(@anchor, record.digest)
        end

        private

        # The first match claims the anchor; the anchor itself re-admits
        # quietly (content addressing makes re-puts idempotent); only a
        # DIFFERENT matching spawn is shadowed.
        def anchors(record)
          return unless record.kind == :spawn && match?(record.digest.to_s, @selector)

          @anchor ||= record.digest
          @on_shadowed.call(record.digest) unless record.digest == @anchor
        end

        # Hex-only below a full "blake3:" prefix ({CLI::ForkPoint}'s idiom): a
        # bare hex selector -- what `lain watch` prints back in {View#lines} and
        # {Watch#shadowed} -- must still match a digest recorded with its
        # scheme, or every prefix a human copies off the tail's own output
        # would fail to anchor anything.
        def match?(digest, selector)
          return digest.start_with?(selector) if selector.start_with?("blake3:")

          digest.delete_prefix("blake3:").start_with?(selector)
        end
      end
    end
  end
end
