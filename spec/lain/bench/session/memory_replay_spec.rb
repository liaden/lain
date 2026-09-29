# frozen_string_literal: true

# MemoryReplay event-sources the RecordedMemory surface from the session's own
# records: the `memory_loaded` record is the view the session opened on, and a
# successful memory_write tool_use IS the write log from there. Loader covers it
# end to end through a recorded run; this pins the unit directly -- built from
# hand-written records, so the seed, the fold, the chain scoping and the
# coverage envelope can be exercised without a live agent.
RSpec.describe Lain::Bench::Session::MemoryReplay do
  def write_use(id)
    { "type" => "tool_use", "id" => "tu_#{id}", "name" => "memory_write",
      "input" => { "id" => id, "description" => "finding #{id}", "body" => "body #{id}" } }
  end

  def result(id, is_error: false) = { "type" => "tool_result", "tool_use_id" => "tu_#{id}", "is_error" => is_error }

  def turn(digest, content, parent: nil)
    { "type" => "turn", "digest" => digest, "parent" => parent, "content" => content }
  end

  def item(id) = Lain::Memory::Item.new(id:, description: "finding #{id}", body: "body #{id}")

  def loaded_record(*items)
    load = Lain::Memory::ProjectStore::Loaded.of(items)
    { "type" => "memory_loaded", "version" => load.version, "items" => items.map(&:payload) }
  end

  def root_record(digest, index) = { "type" => "memory_root", "turn_digest" => digest, "root" => index.root }

  # The one fold every view is addressed through, live or replayed.
  def folded(*ids) = Lain::Memory::ProjectStore::Loaded.of(ids.map { |id| item(id) }).index

  # The replay's expected snapshots, computed the way the fold computes them:
  # each turn's root is the index BEFORE its own writes apply.
  let(:snapshots) do
    empty = Lain::Memory::Index.empty
    after_a = empty.write(item("a"))
    [empty, after_a, after_a.write(item("b"))]
  end

  let(:turns) do
    [turn("d1", [write_use("a")]),
     turn("d2", [result("a"), write_use("b")], parent: "d1"),
     turn("d3", [result("b")], parent: "d2")]
  end

  # Every run writes its load ahead of its first root ({JournalMemoryRoot}), so
  # a record list carrying roots carries the load those roots were taken over --
  # here the empty one, which is what a chat in a project with no memory opens
  # on. A list with roots and NO load is damage, and is pinned as such below.
  let(:roots) { [loaded_record, *%w[d1 d2 d3].zip(snapshots).map { |digest, index| root_record(digest, index) }] }

  describe "a resume whose seed holds a clerk's row" do
    it "rebuilds the seed at the version it was recorded under, author included" do
      clerk = Lain::Memory::Item.new(id: "ttl", description: "d", body: "b",
                                     author: Lain::Memory::Author.clerk(spawn: "sha256:abc"))
      record = JSON.parse(JSON.generate(loaded_record(clerk)))

      replay = described_class.new(records: [record])

      expect(replay.loaded.items.first.author).to eq(clerk.author)
    end
  end

  describe "#recorded_memory" do
    it "replays the successful writes and pairs each turn with its pre-write root" do
      memory = described_class.new(records: turns + roots).recorded_memory

      expect(memory.index.to_h.keys).to contain_exactly("a", "b")
      expect(memory.roots).to eq({ "d1" => snapshots[0].root, "d2" => snapshots[1].root,
                                   "d3" => snapshots[2].root })
    end

    it "skips a write whose paired result errored" do
      refused = [turn("d1", [write_use("a")]), turn("d2", [result("a", is_error: true)], parent: "d1")]

      expect(described_class.new(records: refused).recorded_memory.index).to be_empty
    end

    it "raises Corrupt when a root record disagrees with the replay" do
      forged = roots.map do |record|
        record["type"] == "memory_root" ? record.merge("root" => "blake3:#{"0" * 64}") : record
      end

      expect { described_class.new(records: turns + forged).recorded_memory }
        .to raise_error(Lain::Bench::Session::Corrupt)
    end

    it "loads a record with no turns at all as the empty view" do
      expect(described_class.new(records: []).recorded_memory.index).to be_empty
    end

    # The seed: what the session opened on, which is what makes a session file
    # self-contained about memory rather than a delta on somebody else's store.
    describe "the memory_loaded seed" do
      it "renders the seeded items alongside the chain's own writes" do
        records = [loaded_record(item("seeded")), *turns]

        memory = described_class.new(records:).recorded_memory
        expect(memory.index.to_h.keys).to contain_exactly("seeded", "a", "b")
      end

      # Stated through the fold itself rather than through a hand-built chain of
      # writes: a view's root addresses what it HOLDS, in id order, so the seed
      # and the turns' writes resolve together however they were ordered.
      it "roots every turn over the seed, so a seeded run's own roots verify" do
        over_seed = %w[d1 d2 d3].zip([folded("seeded"), folded("seeded", "a"), folded("seeded", "a", "b")])
                                .map { |digest, index| root_record(digest, index) }

        expect { described_class.new(records: [loaded_record(item("seeded")), *turns, *over_seed]).recorded_memory }
          .not_to raise_error
      end

      # A CHAIN of session files. Each file opened on its own view and recorded
      # roots against it, so each is folded against its OWN seed -- a file's
      # first turn stands on what that file loaded, never on what the file
      # before it left behind. Folding one window and then checking every file's
      # roots against it is what made an ordinary second resume refuse to load.
      describe "a resume chain of several files" do
        let(:header) { { "type" => "session" } }
        let(:seed) { Lain::Memory::ProjectStore::Loaded.of([item("a"), item("b")]) }

        # file 1 wrote a and b and recorded its roots; file 2 resumed it, named
        # the view it carried over, and wrote nothing of its own.
        let(:second_load) { loaded_record(item("a"), item("b")) }

        let(:chain) do
          [header, *turns, *roots,
           header, second_load, turn("d4", [], parent: "d3"), root_record("d4", seed.index)]
        end

        it "builds a view for every file, so an ordinary second resume loads" do
          expect { described_class.new(records: chain).recorded_memory }.not_to raise_error
        end

        it "roots the newer file's first turn on its OWN seed, not on the older file's last view" do
          expect(described_class.new(records: chain).recorded_memory.roots.fetch("d4")).to eq(seed.index.root)
        end

        it "renders what the chain wrote" do
          expect(described_class.new(records: chain).recorded_memory.index.to_h.keys)
            .to contain_exactly("a", "b")
        end

        it "raises Corrupt when an EARLIER file's root disagrees with its own seed" do
          forged = chain.map do |record|
            record["type"] == "memory_root" && record["turn_digest"] == "d2" ? record.merge("root" => nil) : record
          end

          expect { described_class.new(records: forged).recorded_memory }
            .to raise_error(Lain::Bench::Session::Corrupt, /d2/)
        end

        # A file holding roots and no seed is DAMAGE, not history: every run
        # writes its load ahead of its first root, so the pairing is
        # unforgeable. Exempting such a file's roots instead would key the
        # envelope on an ABSENCE -- which is exactly what the deletion it exists
        # to catch produces, so one removed line would have turned verification
        # off for every root in that file.
        it "refuses a file that records roots and no seed, naming it and what is missing" do
          damaged = chain.reject { |record| record.equal?(second_load) }

          expect { described_class.new(records: damaged).recorded_memory }
            .to raise_error(Lain::Bench::Session::Corrupt, /session file 2 .*no memory_loaded/m)
        end

        it "still catches a forged root in a middle file whose seed line was deleted with it" do
          forged = chain.map do |record|
            record["type"] == "memory_root" && record["turn_digest"] == "d4" ? record.merge("root" => nil) : record
          end

          expect { described_class.new(records: forged).recorded_memory }
            .to raise_error(Lain::Bench::Session::Corrupt, /d4/)
        end

        # A file that journaled no usage at all claims nothing, so it needs no
        # seed: it folds from what came before it and this walk declines to
        # check nothing.
        it "loads a file that recorded neither a seed nor a root" do
          quiet = [header, *turns, *roots, header, turn("d4", [], parent: "d3")]

          expect { described_class.new(records: quiet).recorded_memory }.not_to raise_error
        end
      end

      it "raises Corrupt when the recorded items no longer address the recorded version" do
        edited = loaded_record(item("seeded")).merge("version" => "blake3:#{"0" * 64}")

        expect { described_class.new(records: [edited, *turns]).recorded_memory }
          .to raise_error(Lain::Bench::Session::Corrupt, /has been edited/)
      end

      it "raises Corrupt on a memory_loaded record missing its items" do
        expect { described_class.new(records: [{ "type" => "memory_loaded", "version" => "v" }]).recorded_memory }
          .to raise_error(Lain::Bench::Session::Corrupt, /cannot be rebuilt/)
      end
    end

    # The view follows the chain: a `/rewind` past a write drops it here, while
    # the project store keeps it for the next fresh chat.
    describe "a chain a rewound record moved" do
      let(:rewound) { { "type" => "rewound", "from" => "d3", "to" => "d1" } }

      it "leaves a rewound-past write out of the view" do
        memory = described_class.new(records: [*turns, rewound]).recorded_memory

        expect(memory.index.to_h.keys).to contain_exactly("a")
      end

      # Nothing is exempted: the recorded turns are a TREE, so a root taken on
      # the branch the rewind moved off is still reproduced from that branch's
      # own ancestry.
      it "still verifies every root the abandoned branch recorded" do
        expect { described_class.new(records: [*turns, *roots, rewound]).recorded_memory }.not_to raise_error
      end

      # The live view follows the chain too, so a turn committed after the
      # rewind records the view its PARENT left -- and that is what is checked,
      # rather than waved through.
      def continued(root)
        [turn("d4", [], parent: "d1"), { "type" => "memory_root", "turn_digest" => "d4", "root" => root }]
      end

      it "verifies a root recorded after the rewind against the parent's view" do
        records = [*turns, *roots, rewound, *continued(snapshots[1].root)]

        expect(described_class.new(records:).recorded_memory.index.to_h.keys).to eq(["a"])
      end

      it "raises Corrupt when a root recorded after the rewind names the pre-rewind view" do
        records = [*turns, *roots, rewound, *continued(snapshots[2].root)]

        expect { described_class.new(records:).recorded_memory }
          .to raise_error(Lain::Bench::Session::Corrupt, /d4/)
      end
    end

    # A rewind-and-retry that re-commits identical content re-lands the SAME
    # digest, so one digest can carry several records. It is one turn written
    # twice, not two executions, and folding both would write its items twice.
    describe "turn records sharing a digest (the rewind-and-retry shape)" do
      let(:repeated) do
        [turn("d1", [write_use("a")]),
         turn("d1", [write_use("a")]),
         turn("d2", [result("a")], parent: "d1")]
      end

      it "folds each on-chain digest once" do
        memory = described_class.new(records: repeated).recorded_memory

        expect(memory.roots).to eq({ "d1" => nil, "d2" => Lain::Memory::Index.empty.write(item("a")).root })
      end

      it "names a write-bearing turn the root chain covers none of" do
        covering_nothing = [loaded_record, { "type" => "memory_root", "turn_digest" => "d2", "root" => nil }]

        expect { described_class.new(records: repeated + covering_nothing).recorded_memory }
          .to raise_error(Lain::Bench::Session::Corrupt, /d1/)
      end
    end

    # The write-bearing coverage check and the write fold read the SAME
    # tool_use blocks out of the SAME records, so the selection runs once per
    # record rather than once per reader.
    it "selects each record's write calls once, not once per reader" do
      turns.each { |record| allow(record).to receive(:fetch).and_call_original }

      described_class.new(records: turns + roots).recorded_memory

      expect(turns).to all(have_received(:fetch).with("content").at_most(:twice))
    end
  end
end
