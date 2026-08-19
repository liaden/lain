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
      # -- causal edges stay the Store's own job to ENFORCE, and {#forced_put}
      # only re-dresses its refusal as the {Corrupt} every reader of this
      # format already rescues.
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
          @pending = records.each_with_index.to_a
          @landed = []
        end

        # Land every record the Store can already take, repeating until a pass
        # moves nothing; answer whether anything landed. That answer is what
        # lets {Loader} alternate this replay with {ChainFold} to a fixpoint:
        # a flat record's edges can name a turn only that fold can land, and
        # its turns' `causal_parents` can name a :message only this replay can.
        #
        # Puts in DEPENDENCY order, returns (from {#messages}) in FILE order.
        # The split is forced by a real cycle across the spawn boundary (see
        # the class note), and the SHAPE of the solver is forced by journal
        # size: a sweep lands each record as it is REACHED, so a file already
        # in dependency order -- which is every file a writer produces -- lands
        # whole in the first sweep and this stays linear. Evaluating the whole
        # pending set before landing any of it costs one sweep per link
        # instead, and a child chain IS such a link chain (each turn's
        # render_parent is the one before it).
        #
        # Iterative, not recursive, for the reason {Event::Projection#causal_closure}
        # already records: a long chain is a log shape, not an error, and one
        # frame per link turns it into a SystemStackError.
        #
        # rubocop:disable Naming/PredicateMethod -- a COMMAND whose Boolean
        # reports whether it landed anything, not a query. `sweep?` would name
        # the question and hide the puts, which is {Timeline#commit}'s lesson.
        def sweep
          before = @pending.size
          stalled = false
          until @pending.empty? || stalled
            remaining = swept(@pending)
            stalled = remaining.size == @pending.size
            @pending = remaining
          end
          @pending.size < before
        end
        # rubocop:enable Naming/PredicateMethod

        # @return [Array<Event>] every event this file (and any earlier one in
        #   its chain) carries, root/prior-file-first, in FILE order
        # @raise [Corrupt] on a record whose envelope no longer re-derives to
        #   its recorded digest, or whose edges name nothing the file provides
        def messages
          sweep
          force
          @prior + @landed.sort_by(&:last).map(&:first)
        end

        private

        # One greedy pass: land what the Store can take at the moment it is
        # reached, and answer what is still blocked.
        def swept(pending)
          pending.each_with_object([]) do |entry, blocked|
            record, index = entry
            if resolvable?(record)
              @landed << [verified(record, index), index]
            else
              blocked << entry
            end
          end
        end

        # A sweep that moves NOTHING has only genuinely dangling records left,
        # so this puts them and the Store raises the honest refusal.
        # Verification is untouched: every record re-derives its own digest, in
        # whatever order it lands.
        def force
          remainder = @pending.map { |record, index| [forced_put(record, index), index] }
          @pending = []
          @landed.concat(remainder)
        end

        # ONE refusal currency. The Store's own {Store::MissingObject} is the
        # honest refusal, but which exception a damaged journal raises must not
        # become an accident of whether the stuck record happened to be a turn
        # or a message: {CLI::Resume}, {Bench::CLI} and {Supervisor::Restart}
        # rescue different sets, and {ChainFold#recommitted} already translates
        # the identical edge for turns. So it is translated here too, and the
        # Store's own message is carried through rather than reworded.
        def forced_put(record, index)
          verified(record, index)
        rescue Store::MissingObject => e
          raise Corrupt, "message record #{index} (#{labelled(record)}) cites a causal parent this " \
                         "replay never landed: #{e.message}"
        end

        def resolvable?(record)
          [record["render_parent"], *record.fetch("causal_parents")].compact.all? { |digest| @store.key?(digest) }
        end

        def verified(record, index)
          event = rebuilt(record)
          recorded = record.fetch("digest")
          return event if event.digest == recorded

          raise Corrupt, "message record #{index} (#{labelled(record)}) recorded as #{recorded} " \
                         "re-commits to #{event.digest}; its content no longer matches its content address"
        end

        # The JOURNAL's record type, never the event's `kind`. Two record types
        # share this index space and a {Telemetry::ChildTurn} carries kind
        # :turn, so naming the kind made a damaged child turn refuse as
        # "(turn)" -- a record type the file does not contain, in exactly the
        # spawned session this fold exists to re-open. The noun stays "message
        # record": it names the INDEX SPACE, which is this replay's own and
        # deliberately not {ChainFold}'s "turn record".
        def labelled(record) = record["type"] || record.fetch("kind")

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
