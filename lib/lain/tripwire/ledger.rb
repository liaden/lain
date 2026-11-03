# frozen_string_literal: true

require "json"

module Lain
  module Tripwire
    # Folds a session's journal into a standing per requester and journals a
    # `tripwire` record for every signal it counts. Past the hard stop the
    # record says `would_stop`; only with {Stops} does a seeded signal stop
    # anyone, and the score and records are the same either way.
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
      FOLDED = %w[escalation exec_resolution exec_record sandbox].freeze
      CALLS = 256

      Standing = Data.define(:score, :evidence, :stop, :seeded)

      # What a requester has earned so far. `seeded` is the part of the score
      # the signals in {Stops::STOPPING} earned, the only part a stop reads.
      class Standing
        # @param hit [Hit]
        # @param rules [Rules]
        # @return [Standing] this one with the hit counted
        def add(hit, rules)
          points = rules.points_for(hit.weight)
          score = self.score + points
          Standing.new(score:, stop: rules.stop_for(score),
                       seeded: seeded + (Stops::STOPPING.include?(hit.name) ? points : 0),
                       evidence: Ractor.make_shareable([*evidence, hit.to_evidence]))
        end

        # @return [Array<String>] each signal counted so far that can never trip a stop
        def unseeded = evidence.map { _1["signal"] }.uniq - Stops::STOPPING

        EMPTY = new(score: 0, evidence: [].freeze, stop: Rules::NONE, seeded: 0)
      end

      # Whether a hit carried a requester past the hard stop, and if it did,
      # what the stop arm makes of it.
      class Stopping
        Crossing = Data.define(:requester, :signal, :trips, :unseeded)

        # Without stops nothing crosses, so the ledger journals what it always has.
        module Off
          def self.crossed(*) = []
        end

        # @param stops [Stops]
        # @param rules [Rules]
        def initialize(stops:, rules:)
          @stops = stops
          @rules = rules
        end

        # Only seeded signals count toward a trip; a hard stop crossed on the
        # rest is journaled as observe-only and stops no one.
        #
        # @return [Array<Crossing>] none, or the one this hit made
        def crossed(requester, hit, before, after)
          hard = @rules.hard_stop
          trips = before.seeded < hard && after.seeded >= hard
          return [] unless trips || (before.stop == Rules::NONE && after.stop == Rules::WOULD_STOP)

          [Crossing.new(requester:, signal: hit.name, trips:, unseeded: [])]
        end

        # Trips the stops, outside every lock but the stops' own, and answers what to journal.
        #
        # @param crossing [Crossing]
        # @return [Telemetry::TripwireStop]
        def settle(crossing)
          outcome = crossing.trips ? @stops.trip(crossing.requester) : Telemetry::TripwireStop::OBSERVE_ONLY
          Telemetry::TripwireStop.new(**crossing.to_h.slice(:requester, :signal, :unseeded), outcome:)
        end
      end

      # @param journal [#<<] where each `tripwire` record is written
      # @param rules [Rules]
      # @param stops [Stops, Stops::None] with {Stops::None} a hard stop crossed stops no one
      # @param fresh [#fresh?] which files changed this lineage
      # @param home [String] the home whose toolchain roots a launcher may exec into
      # @param execs [Confine::ExecRules] named build output, whose fresh run files are expected
      def initialize(journal:, rules: Rules::DEFAULT, stops: Stops::None, fresh: Resolution::AllFresh, home: Dir.home,
                     execs: Confine::ExecRules::NONE)
        @fresh = fresh
        @home = home
        @execs = execs
        @journal = journal
        @rules = rules
        @stopping = stops.stopping(rules:)
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
        tallied = record ? @lock.synchronize { tallied(record) } : []
        tallied.each { |tripwire, crossings| journal(tripwire, crossings) }
        self
      end

      # @param requester [String]
      # @return [Standing]
      def standing(requester) = @lock.synchronize { @standings.fetch(requester, Standing::EMPTY) }

      private

      def journal(tripwire, crossings)
        @journal << tripwire
        crossings.each { @journal << @stopping.settle(_1) }
      end

      # A crossing names what its requester had earned once the whole record is counted.
      def tallied(record)
        hits(record).map { tally(*_1) }.map do |tripwire, crossings|
          [tripwire, crossings.map { _1.with(unseeded: @standings.fetch(_1.requester).unseeded) }]
        end
      end

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
        when "sandbox" then attributed(id, Hit.of_sandbox(record))
        else attributed(id,
                        Hit.of_exec_record(record,
                                           @resolutions.delete(id) || Resolution.new(nil, fresh: @fresh, home: @home)))
        end
      end

      def escalated(record, id)
        requester = record["requester"]
        keep(@requesters, id, requester) if requester
        Hit.of_escalation(record).map { [requester || requester_of(id), _1] }
      end

      def resolved(record) = Resolution.new(record["stages"], fresh: @fresh, home: @home, execs: @execs)

      def keep(calls, id, value)
        calls.delete(id)
        calls[id] = value
        calls.shift while calls.size > CALLS
        value
      end

      def attributed(id, hits) = hits.map { [requester_of(id), _1] }

      def requester_of(id) = @requesters.fetch(id, UNKNOWN)

      def tally(requester, hit)
        before = @standings.fetch(requester, Standing::EMPTY)
        standing = before.add(hit, @rules)
        @standings[requester] = standing
        [Telemetry::Tripwire.new(requester:, signal: hit.name, weight: hit.weight, score: standing.score,
                                 stop: standing.stop, evidence: standing.evidence),
         @stopping.crossed(requester, hit, before, standing)]
      end
    end
  end
end
