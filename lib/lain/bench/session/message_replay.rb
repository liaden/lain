# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Re-puts a file's own flat event records into the shared Store a
      # resume chain rebuilds into: :message/:spawn events never enter any
      # render chain ({SessionRecord}'s class comment -- their causal edges
      # point BACKWARD and the Store has no forward enumerator), so they must
      # be reconstructed from their own flat records rather than walked. The
      # same verify-by-recommit idiom {Loader#verified_turn} follows for a
      # :turn: payload first, then the envelope (the same edge {Store#put}
      # enforces for a :turn), each landing on the digest recorded beside it
      # -- causal edges are the Store's own job (a dangling one raises
      # {Store::MissingObject}, not a {Corrupt} this class manufactures).
      #
      # `prior` is an earlier file's own already-verified messages in a
      # resume chain (empty for a file with none) -- prepended so a LATER
      # `message` naming an earlier one as a causal_parent finds it already
      # in the Store.
      #
      # {Telemetry::ChildTurn} records come through here too, and they are why
      # `render_parent` is carried: a :turn's render edge is part of its
      # content address, so a spawned chain's turn re-derives its digest only
      # with it. A `message` record has no such key and reads back nil, which
      # is what :message/:spawn already carried -- so every journal already on
      # disk rebuilds byte-identically.
      #
      # == File order stopped being an integrity check, deliberately
      #
      # This class used to put in strict file order, so a permuted section
      # refused with {Store::MissingObject}. It cannot any more, and the reason
      # is a real cycle rather than a tolerance anyone chose: a child's
      # `ask_human` question is written the instant it is asked and cites the
      # child turn it asked FROM, while the tool_result turn that delivers the
      # answer cites that question BACK. Neither record type can precede the
      # other wholesale.
      #
      # So ordering is now a WRITER's discipline, checked by the Store's
      # referential integrity rather than by file position: a record whose edges
      # never land anywhere in the file still refuses, in the same message. What
      # a permuted file loses is only the incidental refusal -- it now loads,
      # and {#messages} hands it back in its own (permuted) order. Every other
      # guarantee is unmoved: each record re-derives its own content address,
      # and the log a caller folds is the file's order, never the landing order.
      class MessageReplay
        def initialize(records:, store:, prior: [])
          @records = records
          @store = store
          @prior = prior
        end

        # @return [Array<Event>] every event this file (and any earlier one in
        #   its chain) carries, root/prior-file-first, in FILE order
        # @raise [Corrupt] on a record whose envelope no longer re-derives to
        #   its recorded digest
        def messages
          @prior + landed.sort_by(&:last).map(&:first)
        end

        private

        # Puts in DEPENDENCY order, returns in FILE order. The split is forced by
        # a real cycle across the spawn boundary (see the class note), and the
        # SHAPE of the solver is forced by journal size: a sweep lands each
        # record as it is REACHED, so a file already in dependency order -- which
        # is every file a writer produces -- lands whole in the first sweep and
        # this stays linear. Evaluating the whole pending set before landing any
        # of it costs one sweep per link instead, and a child chain IS such a
        # link chain (each turn's render_parent is the one before it).
        #
        # Iterative, not recursive, for the reason {Event::Projection#causal_closure}
        # already records: a long chain is a log shape, not an error, and one
        # frame per link turns it into a SystemStackError.
        #
        # A sweep that moves NOTHING has only genuinely dangling records left, so
        # {#forced} puts them and the refusal is the Store's own
        # {Store::MissingObject} rather than one this class manufactures -- the
        # currency the class note pins. Verification is untouched: every record
        # re-derives its own digest, in whatever order it lands.
        def landed
          pending = @records.each_with_index.to_a
          done = []
          stalled = false
          until pending.empty? || stalled
            remaining = swept(pending, done)
            stalled = remaining.size == pending.size
            pending = remaining
          end
          done + forced(pending)
        end

        # One greedy pass: land what the Store can take at the moment it is
        # reached, and answer what is still blocked.
        def swept(pending, done)
          pending.each_with_object([]) do |entry, blocked|
            record, index = entry
            if resolvable?(record)
              done << [verified(record, index), index]
            else
              blocked << entry
            end
          end
        end

        def forced(pending)
          pending.map { |record, index| [verified(record, index), index] }
        end

        def resolvable?(record)
          [record["render_parent"], *record.fetch("causal_parents")].compact.all? { |digest| @store.key?(digest) }
        end

        def verified(record, index)
          event = rebuilt(record)
          recorded = record.fetch("digest")
          return event if event.digest == recorded

          raise Corrupt, "message record #{index} (#{record.fetch("kind")}) recorded as #{recorded} " \
                         "re-commits to #{event.digest}; its content no longer matches its content address"
        end

        def rebuilt(record)
          payload = Event::Payload.new(kind: record.fetch("kind"), body: record.fetch("payload"))
          @store.put(payload)
          event = Event.new(kind: record.fetch("kind"), carried_payload: payload,
                            from: record.fetch("from"), to: record.fetch("to"),
                            render_parent: record["render_parent"],
                            causal_parents: record.fetch("causal_parents"), correlation: record.fetch("correlation"))
          @store.put(event)
          event
        end
      end
    end
  end
end
