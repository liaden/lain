# frozen_string_literal: true

require "json"

module Lain
  module Bench
    class Session
      # A session's completed subagent lineages, read where a chat records them.
      #
      # No turn record carries lineage. A spawn is a `:spawn` event naming the
      # parent head it spawned from, its end is a completion `message` citing
      # that spawn and the child's final turn, and the child's turns are
      # `child_turn` records -- all three flat, so only a Store rebuilt from the
      # whole file can walk between them. {Loader} already rebuilds exactly
      # that, which is why this reads over its messages and Store rather than
      # over the records.
      #
      # A child is walked from its final turn down to the parent head its spawn
      # names, or to its own root when it never shared the parent's chain.
      # One stop rule serves every prefix arm: an inheriting child's lowest turn
      # renders onto that head, and a fresh child's chain never reaches it.
      # Walking the Store rather than the `child_turn` records is forced, not
      # chosen: the scribe writes a turn once per digest, so a child turn equal
      # to one already recorded -- a twin's transcript, or a fresh child seeded
      # with text the session already committed -- can have no record of its own.
      class Lineages
        include Enumerable

        # One completed lineage. `spawned_from` is the parent turn the spawn
        # ran from -- for a one-shot, the assistant turn that called it.
        Lineage = Data.define(:spawn, :completion, :child_turns) do
          def initialize(spawn:, completion:, child_turns:)
            super(spawn:, completion:, child_turns: child_turns.freeze)
          end

          def spawned_from = spawn.body.fetch("spawned_from")
        end

        # A slice that resumes from another file carries no directory to find
        # that file in, so it cannot land the chain its spawns hang off.
        UNCHAINED = lambda do |basename|
          raise Corrupt, "this journal slice resumes from #{basename.inspect} and names no directory to find " \
                         "it in; read its lineages from the session file (Lineages.read) and hand them in"
        end

        # Every lineage a {Recording} holds, which for a resumed session is the
        # whole chain's; {.read} is the door scoped to one file.
        #
        # @param recording [#messages, #timeline] a {Recording}, whole-file
        #   integrity already checked
        def self.of(recording) = new(messages: recording.messages, store: recording.timeline.store)

        # The lineages a session file records, its Store landed through any
        # resume chain from the files beside it -- `resumed_from` names a
        # basename, and a chain is written into one directory.
        #
        # A file recording no completion has no lineage to read, so nothing is
        # rebuilt to say so. One that does is rebuilt through {Loader} and read
        # whole, so damage refuses -- in an open file as in a closed one, less
        # exactly the one gap a live writer leaves ({InFlight}).
        #
        # @param path [String]
        # @raise [Corrupt] naming the file, for any damage
        def self.read(path)
          from(whole_records(File.foreach(path)), resolve: beside(path), whole: true)
        rescue Corrupt => e
          raise Corrupt, "#{path}: #{e.message}"
        end

        # nil for a basename with no file, which {ResumeChain} refuses by name.
        def self.beside(path)
          lambda do |basename|
            sibling = File.join(File.dirname(path), basename)
            File.file?(sibling) ? File.foreach(sibling) : nil
          end
        end
        private_class_method :beside

        # The lineages a journal slice records, for a reader handed records
        # rather than a file. Read as {.read} reads a file, but checked only as
        # far as its flat records: the lineages rest on them, and the header's
        # context does not.
        #
        # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
        # @param resolve [#call] `basename -> entries` for a resumed slice;
        #   refuses by default, since a slice carries no directory to look in
        def self.recorded_in(entries, resolve: UNCHAINED)
          from(whole_records(entries), resolve:, whole: false)
        end

        # A writer killed mid-record tears only the LAST line. A line that does
        # not parse with whole records after it was damaged, and reading past
        # it would read the session short.
        def self.whole_records(entries)
          lines = entries.to_a
          lines.each_with_index.filter_map do |entry, index|
            Journal.parse(entry) || refuse_torn(entry, index, last: lines.size - 1)
          end
        end
        private_class_method :whole_records

        # nil for somebody else's record and for the torn tail -- both skipped,
        # as every Journal reader skips them.
        def self.refuse_torn(entry, index, last:)
          return nil if index == last || !entry.is_a?(String) || entry.strip.empty?

          JSON.parse(entry)
          nil
        rescue JSON::ParserError
          raise Corrupt, "line #{index + 1} is torn: #{entry.strip[0, 60].inspect} does not parse, " \
                         "and whole records follow it"
        end
        private_class_method :refuse_torn

        def self.completion_record?(record)
          record["type"] == "message" && record["payload"].is_a?(Hash) && record["payload"].key?("final")
        end
        private_class_method :completion_record?

        # Scoped to the `message` records THIS file carries, in its order: the
        # Store holds a resume chain's prior events too, and those are the prior
        # file's lineages. Every record kept is forced, which is what refuses
        # damage.
        def self.from(records, resolve:, whole:)
          return new(messages: [], store: Store.new) unless records.any? { |record| completion_record?(record) }

          in_flight = InFlight.new(records)
          loader = Loader.new(in_flight.kept, resolve:)
          settle(loader, whole: whole && !in_flight.gap?)
          new(messages: events(in_flight.kept, loader.store), store: loader.store)
        end
        private_class_method :from

        def self.events(records, store)
          records.select { |record| record["type"] == "message" }.map { |record| record["digest"] }.uniq
                 .map { |digest| store.fetch(digest) }
        end
        private_class_method :events

        # {Loader#recording} checks the whole file. A file with a spawn in
        # flight cannot pass it -- its `memory_root` names the unwritten turn,
        # as its `turn_usage` does -- so there the turn chain and every kept
        # flat record are forced, which is all the lineages rest on.
        def self.settle(loader, whole:)
          return loader.recording if whole

          loader.timeline
          loader.messages
        end
        private_class_method :settle

        # @param messages [Enumerable<Event>] the session's :message/:spawn
        #   events, in file order
        # @param store [Store] the Store they, and every turn they cite, landed in
        def initialize(messages:, store:)
          @messages = messages
          @store = store
        end

        # Twin completions -- the same work from one head, answered alike --
        # are one content-addressed event, so they are one lineage.
        #
        # @yieldparam lineage [Lineage] in the order the completions were recorded
        def each(&)
          return enum_for(:each) unless block_given?

          completions.uniq(&:digest).each { |completion| yield lineage(completion) }
        end

        private

        # A `"final"` is what makes a one-shot's completion walkable. An adopted
        # actor's farewell is terminal too, and cites the actor's head among its
        # causal parents, but carries no `"final"`: actor lineages are not read
        # here yet.
        def completions
          @messages.select do |event|
            event.kind == :message && StatusFeed::SpawnLifecycle.new(event).terminal? && event.body.key?("final")
          end
        end

        def lineage(completion)
          spawn = spawn_of(completion)
          Lineage.new(spawn:, completion:, child_turns: child_turns(completion, spawn))
        end

        def spawn_of(completion)
          completion.causal_parents.map { |digest| @store.fetch(digest) }.find { |event| event.kind == :spawn } ||
            raise(Corrupt, "completion #{completion.digest} cites no :spawn; a one-shot's completion always does")
        end

        def child_turns(completion, spawn)
          stop = spawn.body.fetch("spawned_from")
          Timeline.new(head_digest: completion.body.fetch("final"), store: @store)
                  .ancestors.take_while { |turn| turn.digest != stop }.reverse
        end
      end

      class Lineages
        # The one gap an open session file may hold, and nothing wider.
        #
        # A top-level spawn cites the parent's assistant turn that called it,
        # and the scribe journals that turn only when its iteration returns --
        # after the child has run. So a live file, or one killed mid-spawn,
        # holds a `:spawn` whose causal parent is on no record yet. Its witness
        # is the parent's `turn_usage`, written the moment that turn committed:
        # the gap is a `:spawn` citing exactly the `spawned_from` it names, when
        # that head is the file's LAST `turn_usage` and no record carries it.
        #
        # Those spawns are set aside, with every flat record that rests on them
        # (a sibling's completion, an inheriting child's turns) and on nothing
        # else missing. Everything else is kept and forced, so a malformed
        # record, a dangling parent or an unlanded `final` refuses in an open
        # file exactly as in a closed one. A closed file has no gap.
        class InFlight
          FLAT_TYPES = ["message", SessionRecord::CHILD_TURN_TYPE].freeze
          CARRIERS = ["turn", *FLAT_TYPES].freeze

          # @param records [Array<Hash>] one file's parsed records
          def initialize(records)
            @records = records
          end

          # @return [Array<Hash>] the records to force, in file order
          def kept
            @kept ||= gap? ? without(set_aside) : @records
          end

          # Does this file hold the write-order gap at all?
          def gap? = gaps.any?

          private

          def without(aside)
            @records.reject { |record| FLAT_TYPES.include?(record["type"]) && aside.include?(record["digest"]) }
          end

          def gaps
            @gaps ||= open? && !witness.nil? ? @records.select { |record| in_flight_spawn?(record) } : []
          end

          def in_flight_spawn?(record)
            head = record.dig("payload", "spawned_from")
            record["type"] == "message" && record["kind"] == "spawn" && head == witness &&
              record["causal_parents"] == [head] && !carried.include?(head)
          end

          # Grown to a fixpoint: a dependent's own dependents rest on the gap too.
          def set_aside
            aside = Set[witness, *gaps.map { |record| record["digest"] }]
            grown = true
            while grown
              found = flat.reject { |record| aside.include?(record["digest"]) }
                          .select { |record| rests_on?(record, aside) }
              aside.merge(found.map { |record| record["digest"] })
              grown = found.any?
            end
            aside
          end

          # Only a record whose every missing parent is set aside; one also
          # citing a digest nothing carries is damage, and stays to refuse.
          def rests_on?(record, aside)
            cited = record.fetch("causal_parents", [])
            return false unless cited.is_a?(Array) && cited.all?(String)

            parents = [*cited, record["render_parent"]].compact
            aside.intersect?(parents) &&
              parents.all? { |digest| aside.include?(digest) || carried.include?(digest) }
          end

          def flat = @flat ||= @records.select { |record| FLAT_TYPES.include?(record["type"]) }

          def carried
            @carried ||= @records.select { |record| CARRIERS.include?(record["type"]) }
                                 .to_set { |record| record["digest"] }
          end

          def witness
            @witness ||= @records.reverse.find { |record| record["type"] == "turn_usage" }&.fetch("digest", nil)
          end

          def open?
            header = @records.find { |record| record["type"] == HEADER_TYPE }
            !header.nil? && Anchor.new(header:, session_closed_records: of_type("session_closed")).open?
          end

          def of_type(type) = @records.select { |record| record["type"] == type }
        end
      end
    end
  end
end
