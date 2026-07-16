# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Re-puts a file's own `message` records (T14) into the shared Store a
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
      # in the Store, the same file-order discipline the ChainWriter wrote
      # them under.
      class MessageReplay
        def initialize(records:, store:, prior: [])
          @records = records
          @store = store
          @prior = prior
        end

        # @return [Array<Event>] every message this file (and any earlier one
        #   in its chain) carries, root/prior-file-first
        # @raise [Corrupt] on a record whose envelope no longer re-derives to
        #   its recorded digest
        def messages
          @prior + @records.each_with_index.map { |record, index| verified(record, index) }
        end

        private

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
                            causal_parents: record.fetch("causal_parents"), correlation: record.fetch("correlation"))
          @store.put(event)
          event
        end
      end
    end
  end
end
