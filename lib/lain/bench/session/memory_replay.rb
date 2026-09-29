# frozen_string_literal: true

module Lain
  module Bench
    class Session
      # Event-sources the {RecordedMemory} surface from the session's own
      # records: each file's `memory_loaded` record is the view that file opened
      # on, and successful memory_write tool_use inputs ARE the write log from
      # there, so a fresh {Memory::Index} seeded and folded the same way lands
      # on the same roots the live run produced. Byte-equality against the
      # journaled memory_root chain is the integrity proof. A write whose paired
      # tool_result is an error never reached the live recorder, so it must not
      # enter the replay.
      #
      # == One seed per FILE, not one per chain
      #
      # A resume chain arrives here as every line of every file, oldest first
      # ({CLI::Resume::ChainWalk}), and each file opened on its own view and
      # recorded roots against it. So the fold is per file: a file's first turn
      # stands on the view THAT file loaded, never on whatever the file before it
      # left behind. Folding one window and checking every file's roots against
      # it is what made an ordinary second resume refuse to load.
      #
      # == The fold is chain-scoped, and the root is a content address
      #
      # The view follows the chain: a turn `/rewind` moved past is off the chain,
      # so its writes are not in the view a resume renders -- the entry stays in
      # the project store, where a fresh chat still sees it. The head is derived
      # the way {ChainFold} derives it, in file order, because that is the only
      # order in which a turn record and a `rewound` record are readable
      # together.
      #
      # Every view is addressed through {Memory::ProjectStore::Loaded.of}, the
      # same fold the LIVE view uses ({Memory::Recorder}), so a root depends on
      # what the view HOLDS and not on the route it took there. That is what
      # lets every recorded root be verified rather than exempted, and it is why
      # a chain whose turns the seed already accounts for reproduces the seed's
      # own root instead of drifting past it.
      #
      # A file with ZERO memory_root records replays its writes unverified, the
      # tolerant no-usage-journaled precedent. A PARTIAL chain is different:
      # memory_root records are not Merkle-anchored, so a silently deleted line
      # is otherwise undetectable, and incomplete coverage of the write-bearing
      # turns raises {Corrupt}. Stated honestly, coverage is checked only for
      # WRITE-BEARING turns, so deleting the record paired with a write-free
      # turn still loads clean -- the envelope detects deletions that could hide
      # a write, not every deletion.
      class MemoryReplay
        MOVE_TYPES = [TURN_TYPE, SessionRecord::REWOUND_TYPE].freeze
        LOADED_TYPE = "memory_loaded"
        ROOT_TYPE = "memory_root"
        private_constant :MOVE_TYPES, :LOADED_TYPE, :ROOT_TYPE

        # One session file's share of a resume chain: the load it opened on, the
        # turns it committed, and the roots it recorded. Deduped by digest
        # because the scribe re-records a chain after a rewind -- a second record
        # under one digest is the same turn written again, not a second
        # execution.
        class Segment
          def initialize(records)
            @records = records
          end

          def load_record = @records.reverse.find { |record| record["type"].to_s == LOADED_TYPE }

          def turns = @turns ||= of(TURN_TYPE).uniq { |record| record.fetch("digest") }

          def roots = @roots ||= of(ROOT_TYPE)

          private

          def of(type) = @records.select { |record| record["type"].to_s == type }
        end
        private_constant :Segment

        # The running state of one walk down the chain: the view each turn left
        # behind, the root each one rendered over, and the ONE Store every fold
        # lands in -- which is what keeps each of those roots resolvable through
        # `Index#checkout` once the walk is over.
        class Walk
          attr_reader :roots

          def initialize
            @views = {}
            @roots = {}
            @store = Lain::Store.new
          end

          # Opens a file. A turn looks its parent's view up among THIS file's
          # turns ALONE, so a first turn -- whose parent belongs to the file
          # before it -- stands on the seed that file recorded rather than on
          # whatever the previous one left behind. One map across the chain
          # would make the seed a fallback for an orphan parent instead of the
          # override it is, and a file whose recorded seed disagreed with its
          # predecessor would be checked against the wrong view.
          def open_file
            @views = {}
            self
          end

          # The view a turn rendered over: its parent's, or this file's seed,
          # where its parent belongs to the file before it.
          def before(record, seed) = @views.fetch(record["parent"], seed)

          # @return [Array<Memory::Item>] the view this turn left behind
          def record(digest, before, items)
            @roots[digest] = fold(before).root
            @views[digest] = Memory::ProjectStore::Loaded.of(before + items).items
          end

          def index(digest, fallback) = fold(@views.fetch(digest, fallback))

          private

          def fold(items) = Memory::ProjectStore::Loaded.of(items).index(store: @store)
        end
        private_constant :Walk

        # What one walk of the chain leaves: the per-turn roots, the final view,
        # and the seed the NEWEST file opened on.
        Fold = Data.define(:roots, :index, :seed)
        private_constant :Fold

        # @param records [Enumerable<Hash>] the chain's parsed records, in FILE
        #   ORDER and oldest file first -- the seeds, the turns, the head moves
        #   and the roots are selected here rather than by the caller, because
        #   the fold is only verifiable in the order the records were written
        def initialize(records:)
          @records = records.to_a
        end

        # @return [RecordedMemory]
        # @raise [Corrupt] on a root disagreeing with the replay, a record
        #   naming no recorded turn, a partial chain, or a seed whose items no
        #   longer address the version they were recorded under
        def recorded_memory
          verified(RecordedMemory.new(roots: folded.roots, index: folded.index))
        end

        # The view the NEWEST file of the chain opened on.
        #
        # PUBLIC because a reader that folds this chain itself needs the same
        # starting point: {Memory::Recorder#follow} refolds from it to answer
        # what a chain SHORTER than the recorded one carries, which is what a
        # `/fork` below a memory_write is.
        #
        # @return [Memory::ProjectStore::Loaded]
        # @raise [Corrupt] on a seed whose items no longer address its version
        def loaded = folded.seed

        private

        def folded = @folded ||= walk

        # Each file in turn, against its own seed. The pair carried through is
        # the view a file OPENED on and the view it ENDED holding: the first is
        # what its own turns fold over, what a live session resuming this chain
        # stands on, and the answer for a head this walk folded no turn for -- a
        # chain rewound to the empty session is exactly its own seed. The second
        # is the only honest guess available for a file that recorded no seed.
        def walk
          state = Walk.new
          opened, = segments.each_with_index.inject([Memory::ProjectStore.empty] * 2) do |(_seed, carried), pair|
            segment, position = pair
            seed = seed_for(segment, carried, position)
            [seed, folded_segment(segment, seed, state.open_file)]
          end
          Fold.new(roots: state.roots, seed: opened, index: state.index(head, opened.items))
        end

        # A turn's root is snapshotted BEFORE its own writes apply, because
        # TurnUsage -- which the memory_root record pairs with -- journals after
        # the assistant commit and strictly before perform_tools. A parent this
        # file does not carry is its resume boundary, whose view IS the seed.
        #
        # @return [Memory::ProjectStore::Loaded] what this file ended holding
        def folded_segment(segment, seed, state)
          held = write_calls(segment).inject(seed.items) do |_carried, (record, items)|
            state.record(record.fetch("digest"), state.before(record, seed.items), items)
          end
          Memory::ProjectStore::Loaded.of(held)
        end

        # A file's own `memory_loaded` is its seed. A file that recorded ROOTS
        # and no seed is DAMAGE and refuses: every run writes its load ahead of
        # its first root ({Memory::JournalMemoryRoot}), so the pairing is
        # unforgeable, and exempting the roots instead would have keyed the
        # envelope on an absence -- which is precisely what the deletion it
        # exists to catch produces.
        #
        # A file with neither is not damage, only a file that journaled no
        # usage: it folds from the empty view when it opens the chain and
        # carries on from what came before it otherwise, and it claims nothing
        # this walk then declines to check.
        def seed_for(segment, carried, position)
          record = segment.load_record
          return seeded(record) unless record.nil?

          missing_seed!(segment, position) if segment.roots.any?
          position.zero? ? Memory::ProjectStore.empty : carried
        end

        def missing_seed!(segment, position)
          raise Corrupt, "session file #{position + 1} of this chain records #{segment.roots.size} " \
                         "memory_root line(s) and no memory_loaded (its first turn is " \
                         "#{segment.turns.first&.fetch("digest").inspect}); every run writes its load " \
                         "ahead of its first root, so the line saying which view they were taken over " \
                         "has been lost"
        end

        def seeded(record)
          rebuilt = Memory::ProjectStore::Loaded.of(record.fetch("items").map { |item| item_from(item) })
          return rebuilt if rebuilt.version == record.fetch("version")

          raise Corrupt, "the memory_loaded record names version #{record.fetch("version").inspect} but its " \
                         "items address #{rebuilt.version.inspect}; the recorded view has been edited"
        rescue KeyError, ArgumentError => e
          raise Corrupt, "a memory_loaded record cannot be rebuilt (#{e.message})"
        end

        def item_from(item)
          Memory::Item.new(id: item.fetch("id"), description: item.fetch("description"), body: item.fetch("body"),
                           author: Memory::Author.from(item["author"]))
        end

        # The file's writes, paired with the turn that made them.
        # {Memory::Writes} is the reader, which is what makes this replay and
        # the LIVE view it is checked against one fold rather than two
        # implementations of it.
        def write_calls(segment)
          segment.turns.zip(Memory::Writes.new(segment.turns.map { |record| record.fetch("content") }).per_turn)
        end

        def segments = @segments ||= sliced.map { |records| Segment.new(records) }

        # One per session header. A chat's file OPENS with its header, so a
        # chain of them slices cleanly on that record; a bench recording appends
        # its header AFTER the run it describes and is never chained, so a
        # stream that does not open with one is a single file whatever else it
        # holds -- which is also what a hand-written record list is.
        def sliced
          return [@records] unless @records.first&.[]("type").to_s == SessionRecord::HEADER_TYPE

          @records.slice_before { |record| record["type"].to_s == SessionRecord::HEADER_TYPE }.to_a
        end

        # `rewound` records and turn records read together, in file order: a
        # turn commits onto the head, a rewind checks one out, and an unlanded
        # retreat is dropped exactly as {SessionRecord.applied} drops it.
        def head
          SessionRecord.applied(@records.select { |record| MOVE_TYPES.include?(record["type"].to_s) })
                       .map { |record| moved_to(record) }.last
        end

        def moved_to(record)
          record["type"].to_s == SessionRecord::REWOUND_TYPE ? record["to"] : record.fetch("digest")
        end

        def verified(memory)
          return memory if roots.empty?

          covered!
          roots.each { |record| agree!(record, memory) }
          memory
        end

        def covered!
          missing = write_bearing - roots.map { |record| record.fetch("turn_digest") }
          return if missing.empty?

          raise Corrupt, "no memory_root record pairs write-bearing turn(s) " \
                         "#{missing.join(", ")}; a partial chain reads as deletion, not as a " \
                         "pre-decorator recording"
        end

        def write_bearing
          segments.flat_map { |segment| write_calls(segment) }
                  .select { |_record, items| items.any? }
                  .map { |record, _items| record.fetch("digest") }
        end

        def agree!(record, memory)
          turn_digest = record.fetch("turn_digest")
          replayed = memory.roots.fetch(turn_digest) do
            raise Corrupt, "memory_root record names turn #{turn_digest}, which is not in the turn chain"
          end
          return if replayed == record.fetch("root")

          raise Corrupt, "memory_root for turn #{turn_digest} recorded as #{record.fetch("root").inspect} " \
                         "but the recorded writes replay to #{replayed.inspect}; the record no longer " \
                         "matches its turns"
        end

        # Every root in the chain: no file's are exempt, because a file that
        # recorded roots without a seed does not load at all.
        def roots = @roots ||= segments.flat_map(&:roots)
      end
    end
  end
end
