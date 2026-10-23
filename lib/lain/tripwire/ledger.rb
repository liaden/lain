# frozen_string_literal: true

require "json"

module Lain
  module Tripwire
    # Folds a session's journal into a standing per requester and journals a
    # `tripwire` record for every signal it counts. It stops nothing: past the
    # hard stop the record says `would_stop`, and the run goes on.
    #
    # A bash call's own records name no requester, so the escalation that ruled
    # the call is what names it, joined on `tool_use_id`.
    #
    # A Journal tells its observers under its own monitor, so the score is kept
    # under a lock of this object's and the record written once it is released;
    # a thread asking for a standing then never waits on the journal.
    #
    # A call that runs untraced journals a resolution no exec record follows,
    # so what is kept per call is bounded: past {CALLS} the oldest is dropped.
    class Ledger
      UNKNOWN = "unknown"
      FOLDED = %w[escalation exec_resolution exec_record].freeze
      CALLS = 256

      Standing = Data.define(:score, :evidence, :stop)

      # What a requester has earned so far.
      class Standing
        # @param hit [Hit]
        # @param rules [Rules]
        # @return [Standing] this one with the hit counted
        def add(hit, rules)
          score = self.score + rules.points_for(hit.weight)
          Standing.new(score:, stop: rules.stop_for(score),
                       evidence: Ractor.make_shareable([*evidence, hit.to_evidence]))
        end

        EMPTY = new(score: 0, evidence: [].freeze, stop: Rules::NONE)
      end

      # @param journal [#<<] where each `tripwire` record is written
      # @param rules [Rules]
      def initialize(journal:, rules: Rules::DEFAULT)
        @journal = journal
        @rules = rules
        @lock = Mutex.new
        @requesters = {}
        @resolutions = {}
        @standings = {}
      end

      # A Journal observer.
      #
      # @param event [Hash, #to_journal] a record as written or as replayed
      # @return [self]
      def <<(event)
        record = folded(event)
        tallied = record ? @lock.synchronize { hits(record).map { tally(*_1) } } : []
        tallied.each { @journal << _1 }
        self
      end

      # @param requester [String]
      # @return [Standing]
      def standing(requester) = @lock.synchronize { @standings.fetch(requester, Standing::EMPTY) }

      private

      # Live records carry symbol keys and values deeper down, replayed ones
      # strings; one JSON round trip reads both the same.
      def folded(event)
        hash = Journal.parse(Journal.hash_of(event))
        JSON.parse(JSON.generate(hash)) if hash && FOLDED.include?(hash["type"])
      end

      def hits(record)
        id = record["tool_use_id"]
        case record["type"]
        when "escalation" then escalated(record, id)
        when "exec_resolution" then attributed(id, Hit.of_resolution(record, keep(@resolutions, id, resolved(record))))
        else attributed(id, Hit.of_exec_record(record, @resolutions.delete(id) || Resolution.new(nil)))
        end
      end

      def escalated(record, id)
        requester = record["requester"]
        keep(@requesters, id, requester) if requester
        Hit.of_escalation(record).map { [requester || requester_of(id), _1] }
      end

      def resolved(record) = Resolution.new(record["stages"])

      def keep(calls, id, value)
        calls.delete(id)
        calls[id] = value
        calls.shift while calls.size > CALLS
        value
      end

      def attributed(id, hits) = hits.map { [requester_of(id), _1] }

      def requester_of(id) = @requesters.fetch(id, UNKNOWN)

      def tally(requester, hit)
        standing = @standings.fetch(requester, Standing::EMPTY).add(hit, @rules)
        @standings[requester] = standing
        Telemetry::Tripwire.new(requester:, signal: hit.name, weight: hit.weight, score: standing.score,
                                stop: standing.stop, evidence: standing.evidence)
      end
    end
  end
end
