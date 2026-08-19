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

        # The `compact` is for an ABSENT `render_parent` -- a `message` record
        # legitimately has none -- and it must be reached only once the edge set
        # is known to hold digest strings, or it silently drops a malformed
        # entry as well and calls the record reachable. {#cited_parents?} is
        # what keeps that from happening.
        def resolvable?(record)
          cited_parents?(record) &&
            [record["render_parent"], *cited(record)].compact.all? { |digest| @store.key?(digest) }
        end

        # DEFAULTED, never fetched, exactly as {ChainFold#cited_parents} has
        # defaulted it since it was written: no key IS the empty set, the same
        # tolerance `meta` already has. Fetching it instead made the gate below
        # raise {KeyError} before it could answer -- and KeyError is no
        # {Lain::Error}, so `exe/lain`'s rescue misses it and an operator gets a
        # raw backtrace. Absence is not silently lossy: a record that really
        # carried an edge fails its content address without one.
        def cited(record) = record.fetch("causal_parents", [])

        # A journal is bytes, and bytes can be wrong. `payload`, `from`/`to` and
        # every other field announce their corruption through the digest they
        # then fail to re-derive -- but `causal_parents` reaches neither that
        # check nor the Store's, because {Event#normalize_causal} maps and SORTS
        # it before any digest exists. Three ways out, none of them {Corrupt}: a
        # String dies in `map`, a null BESIDE a digest dies in `sort`, and a
        # lone null slipped through the `compact` above to be refused by the
        # Store as a {Store::MissingObject} raised from the SWEEP, where
        # {#forced_put}'s translation cannot reach it. {ChainFold#cited_parents}
        # has checked the identical field for turn records since it was written;
        # this half had not, and that asymmetry -- not any one of the three
        # escapes -- was the defect.
        #
        # FIELD-scoped, like its {ChainFold} counterpart and unlike a name such
        # as "well formed": `render_parent`, `kind`, `digest` and `payload` are
        # equally the record's form and none of them are checked here.
        #
        # Asked as a QUESTION here and refused from {#cited_parents} on the
        # landing path, deliberately, and the asymmetry with {ChainFold} --
        # which raises straight out of its own `resolvable?` -- is principled
        # rather than incidental. ChainFold FORCES its remainder inside
        # {ChainFold#timeline}, so it has no tolerant question to protect; this
        # class's sweep/force split is consulted by one that must stay tolerant.
        # WITHIN ONE FILE, {Loader#timeline} answers over damage in a flat
        # record nothing cites (its own note), and {Loader#converged} sweeps
        # every round -- so a gate that RAISED here would take that away. Scoped
        # to one file on purpose: ACROSS a resume chain the prior file's replay
        # is forced by {Loader#fixpoint}'s `prior:`, so {Loader#timeline} and
        # {Loader#on_chain?} do refuse over a stray damaged prior-file record,
        # which `loader_fixpoint_spec.rb` pins. A malformed record simply cannot
        # land; {#force} is where every record still arrives, and where it is
        # named.
        def cited_parents?(record)
          parents = cited(record)
          parents.is_a?(Array) && parents.all?(String)
        end

        def verified(record, index)
          event = rebuilt(record, cited_parents(record, index))
          recorded = record.fetch("digest")
          return event if event.digest == recorded

          raise Corrupt, "message record #{index} (#{labelled(record)}) recorded as #{recorded} " \
                         "re-commits to #{event.digest}; its content no longer matches its content address"
        end

        # The checked edge set, handed to {#rebuilt} so the value that lands IS
        # the value that passed the gate -- a later caller cannot re-read the
        # field and route around it. Same index space and label as every other
        # refusal here ({#labelled}): two record types share it, and the
        # journal's own `type` is the honest name.
        #
        # Runs a second time per LANDED record ({#resolvable?} asked already),
        # which costs an Array#all? over a handful of digests and is worth
        # naming rather than optimising: on the sweep path this raise is dead,
        # and it is live only from {#forced_put}, where nothing pre-checked.
        def cited_parents(record, index)
          return cited(record) if cited_parents?(record)

          raise Corrupt, "message record #{index} (#{labelled(record)}) records causal_parents as " \
                         "#{cited(record).inspect}; the field is a set of digest strings, " \
                         "and only an array of them lands"
        end

        # The JOURNAL's record type, never the event's `kind`. Two record types
        # share this index space and a {Telemetry::ChildTurn} carries kind
        # :turn, so naming the kind made a damaged child turn refuse as
        # "(turn)" -- a record type the file does not contain, in exactly the
        # spawned session this fold exists to re-open. The noun stays "message
        # record": it names the INDEX SPACE, which is this replay's own and
        # deliberately not {ChainFold}'s "turn record".
        def labelled(record) = record["type"] || record.fetch("kind")

        # Takes the checked edge set rather than re-reading the field, so the
        # gate in {#cited_parents} cannot be routed around from here.
        def rebuilt(record, cited)
          payload = Event::Payload.new(kind: record.fetch("kind"), body: record.fetch("payload"))
          @store.put(payload)
          event = Event.new(kind: record.fetch("kind"), carried_payload: payload,
                            from: record.fetch("from"), to: record.fetch("to"),
                            render_parent: record["render_parent"],
                            causal_parents: cited, correlation: record.fetch("correlation"))
          @store.put(event)
          event
        end
      end
    end
  end
end
