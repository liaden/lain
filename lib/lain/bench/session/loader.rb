# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Rebuilds a {Recording} from parsed journal records. A collaborator of
      # {Session.load} rather than a pile of class methods on Session: loading
      # is its own responsibility -- discriminating record types and folding
      # each into the object it reconstructs.
      #
      # Integrity is content-addressing, not trust: every turn record is
      # RE-COMMITTED in file order, so its digest is recomputed over its
      # recorded content and the chain's own parent, and a disagreement with
      # the recorded digest -- edited content, a reordered chain -- raises
      # {Corrupt} instead of loading quietly wrong. The rebuilt head must then
      # match the header's anchor (a Merkle chain self-verifies only its
      # prefix, so truncating the tail would otherwise pass), and every
      # request_sent record must rebuild to its own recorded digest.
      class Loader
        # @param entries [Enumerable<Hash, String>] the {Journal.parse} duck;
        #   entries it answers nil for are somebody else's records and skipped
        def initialize(entries)
          @records = entries.filter_map { |entry| Journal.parse(entry) }
        end

        # @return [Recording]
        def recording
          Recording.new(
            context:, context_class: header.fetch("context_class"),
            toolset:, workspace:,
            timeline:, baseline:,
            ledger_index: Ledger::Index.from_journal(@records),
            degraded:, memory:
          )
        end

        # The session's recorded slot attribution (PS-2): the one slot_fills
        # record folded back into a {Telemetry::SlotFills} value, or an empty
        # one for a journal written before the record existed (nothing recorded
        # is the empty attribution, a value here, not an absence). Loads
        # UNVERIFIED -- pure attribution, reporting the recorded fills rather
        # than the live disk state; the rendered system text these digests
        # address is separately verified through the request_sent chain.
        def slot_fills
          record = sole_slot_fills
          return Telemetry::SlotFills.new(digests: {}, fills: {}) if record.nil?

          Telemetry::SlotFills.new(digests: record.fetch("digests"), fills: record.fetch("fills"))
        end

        private

        def of_type(type)
          @records.select { |record| record["type"].to_s == type }
        end

        def header
          @header ||= sole_header
        end

        # First-wins over several headers would make "which run is this?" an
        # accident of file order; the format is one run, one journal, one file.
        def sole_header
          headers = of_type(HEADER_TYPE)
          raise Corrupt, "no #{HEADER_TYPE.inspect} header record to rebuild a context from" if headers.empty?

          unless headers.size == 1
            raise Corrupt, "#{headers.size} #{HEADER_TYPE.inspect} header records in one journal; " \
                           "the format is one run, one journal, one file"
          end

          headers.first
        end

        # Same discipline as {#sole_header}: fills are session-fixed, so a
        # second record would make "which fills?" an accident of file order.
        # Nil (no record at all) is fine -- an older journal simply predates
        # the attribution.
        def sole_slot_fills
          records = of_type("slot_fills")
          return records.first if records.size <= 1

          raise Corrupt, "#{records.size} \"slot_fills\" records in one journal; " \
                         "fills are session-fixed, one record pins them"
        end

        # The default-pipeline Context only -- see the note on {Session}.
        # `extra` (sampler params) loads unverified like the other transport
        # fields; `|| {}` tolerates recordings written before the key existed.
        def context
          Context.new(model: header.fetch("model"), max_tokens: header.fetch("max_tokens"),
                      system: header["system"], stream: header.fetch("stream"),
                      extra: header["extra"] || {})
        end

        def toolset
          RecordedToolset.new(schema: header.fetch("tools"))
        end

        def workspace
          Workspace.new(reminders: header.fetch("reminders"))
        end

        def timeline
          chain = of_type(TURN_TYPE).each_with_index.inject(Timeline.empty(store: Store.new)) do |acc, (record, i)|
            verified_turn(acc.commit(role: record.fetch("role"), content: record.fetch("content"),
                                     meta: record.fetch("meta", {})),
                          record, i)
          end
          anchored(chain)
        end

        def verified_turn(chain, record, index)
          recorded = record.fetch("digest")
          return chain if chain.head_digest == recorded

          raise Corrupt, "turn record #{index} (#{record.fetch("role")}) recorded as #{recorded} " \
                         "re-commits to #{chain.head_digest}; its content no longer matches its content address"
        end

        def anchored(chain)
          expected = header.fetch("head")
          return chain if chain.head_digest == expected

          raise Corrupt, "the header anchors head #{expected.inspect} but the turn chain rebuilds to " \
                         "#{chain.head_digest.inspect}; the tail has been truncated or spliced"
        end

        # The proven rebuild idiom (see Telemetry::RequestSent and its spec): the
        # payload's keys are exactly Request.new's content keywords, and the
        # record carries the digest-excluded transport fields alongside. Each
        # rebuild must land on the record's own digest -- RequestSent carries
        # it precisely so a forged PAYLOAD cannot load clean and book as
        # harness variance downstream. The transport fields (stream, extra)
        # ride alongside unverified: the digest deliberately excludes them,
        # so tampering there is invisible to this check.
        def baseline
          of_type("request_sent").each_with_index.map do |record, index|
            verified_request(Request.new(stream: record.fetch("stream"), extra: record.fetch("extra"),
                                         **record.fetch("payload").transform_keys(&:to_sym)),
                             record, index)
          end.freeze
        end

        def verified_request(request, record, index)
          recorded = record.fetch("digest")
          return request if request.digest == recorded

          raise Corrupt, "request_sent record #{index} recorded as #{recorded} rebuilds to #{request.digest}; " \
                         "its payload no longer matches its content address"
        end

        def degraded
          Capability::DegradedSet.new(
            of_type("capability_degraded").map { |record| record.fetch("capability") }
          )
        end

        def memory
          MemoryReplay.new(turns: of_type(TURN_TYPE), roots: of_type("memory_root")).recorded_memory
        end
      end
    end
  end
end
