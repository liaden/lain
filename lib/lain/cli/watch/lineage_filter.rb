# frozen_string_literal: true

module Lain
  module CLI
    class Watch
      # Decides, from the NDJSON fields alone, whether a journal record chains
      # to the watched spawn S, an actor or a one-shot alike. Only
      # {Telemetry::Message} records are ever admitted: `turn` records are the
      # PARENT's render chain, a child's own turns arrive as `child_turn`
      # records this view does not render, and every spawn, exchange and
      # completion is a message record carrying its lineage explicitly as
      # `from`/`to`/`causal_parents`. No Store is
      # reconstructed and no digest is re-derived -- the record's own fields
      # are the whole truth this filter consults.
      #
      # Anchoring is FIRST-MATCH: a stream cannot know whether a second match
      # is still to come, so the first spawn record the selector matches is
      # the one watched, and every LATER matching spawn is reported through
      # `on_shadowed` -- named once, then ignored -- rather than silently
      # merging two lineages into one view. Pick a longer prefix to watch the
      # other one.
      #
      # Membership grows by a record's OWN digest only, never by absorbing its
      # `causal_parents`: a spawn's causal parent is the PARENT timeline's
      # head, and absorbing it would silently pull the parent's entire chain
      # into the watched lineage. Consulted, never absorbed.
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
          @admitted = Set.new
        end

        # @return [Boolean] whether any spawn has anchored the lineage yet
        def anchored? = !@anchor.nil?

        # @param record [Hash{String=>Object}] one parsed journal record
        # @return [Boolean] whether the record chains to the watched spawn
        def admit?(record)
          return false unless record["type"] == "message"

          digest = record["digest"]
          member = anchors?(record, digest) || chains?(record)
          @admitted.add(digest) if member && digest
          member
        end

        private

        # The first match claims the anchor; the anchor itself re-admits
        # quietly (content addressing makes re-puts idempotent); only a
        # DIFFERENT matching spawn is shadowed.
        def anchors?(record, digest)
          return false unless record["kind"].to_s == "spawn" && match?(digest.to_s, @selector)

          @anchor = digest unless anchored?
          return true if digest == @anchor

          @on_shadowed.call(digest)
          false
        end

        # An exchange chains when any explicit lineage field names an admitted
        # digest: `to` for the parent's tell (addressed to the spawn), `from`
        # for the actor's own replies (sent as the spawn's address), and
        # `causal_parents` for anything downstream of an admitted record.
        def chains?(record)
          @admitted.intersect?([record["from"], record["to"], *record["causal_parents"]].compact)
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
