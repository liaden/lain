# frozen_string_literal: true

require "tmpdir"

# The ONE reader of "what did this chain write to memory", shared by the live
# view following a rewind and by the replay rebuilding a recorded one. Driven
# here over hand-written content blocks, because the claim is about the blocks
# and not about where they came from -- a live Event's content and a recorded
# turn's are the same input by design.
RSpec.describe Lain::Memory::Writes do
  def write_use(id)
    { "type" => "tool_use", "id" => "tu_#{id}", "name" => "memory_write",
      "input" => { "id" => id, "description" => "about #{id}", "body" => "body of #{id}" } }
  end

  def result(id, is_error: false) = { "type" => "tool_result", "tool_use_id" => "tu_#{id}", "is_error" => is_error }

  it "yields the item each answered call wrote, in chain order" do
    writes = described_class.new([[write_use("a")], [result("a"), write_use("b")], [result("b")]])

    expect(writes.map(&:id)).to eq(%w[a b])
    expect(writes.first.body).to eq("body of a")
  end

  it "groups the items by the turn that made them, so a caller can snapshot per turn" do
    writes = described_class.new([[write_use("a")], [result("a"), write_use("b")], [result("b")]])

    expect(writes.per_turn.map { |items| items.map(&:id) }).to eq([["a"], ["b"], []])
  end

  it "skips a call the model was handed back an error for" do
    writes = described_class.new([[write_use("a")], [result("a", is_error: true)]])

    expect(writes.to_a).to be_empty
  end

  # A round a rewind left behind, or one torn before its results landed: no
  # result at all is not the same as a successful one, and a view built from
  # either would hold a write that never ran.
  it "skips a call no turn answered at all" do
    writes = described_class.new([[write_use("a")]])

    expect(writes.to_a).to be_empty
  end

  it "ignores blocks that are not memory_write calls" do
    other = { "type" => "tool_use", "id" => "tu_x", "name" => "read_file", "input" => { "path" => "x" } }
    writes = described_class.new([[other, { "type" => "text", "text" => "hi" }],
                                  [{ "type" => "tool_result", "tool_use_id" => "tu_x", "is_error" => false }]])

    expect(writes.to_a).to be_empty
  end

  it "reads a turn whose content is not an array at all as writing nothing" do
    expect(described_class.new(["just text", nil]).to_a).to be_empty
  end

  it "is an Enumerator without a block, so a caller may compose rather than collect" do
    expect(described_class.new([]).each).to be_a(Enumerator)
  end

  # The input names source paths, never their digests, and never the author:
  # an item rebuilt from it addresses a different digest than the one written.
  describe "a write with sources, replayed from its recorded result" do
    around do |example|
      Dir.mktmpdir("lain-writes-sources") do |dir|
        @root = File.realpath(dir)
        File.write(File.join(@root, "a.rb"), "x = 1")
        example.run
      end
    end

    let(:recorder) { Lain::Memory::Recorder.new }
    let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {}), root: @root) }
    let(:tool) do
      Lain::Tools::MemoryWrite.new(recorder:, author: Lain::Memory::Author.clerk(spawn: "sha256:abc"))
    end
    let(:input) { { "id" => "s", "description" => "d", "body" => "b", "sources" => ["a.rb"] } }
    let(:use) { use_of("tu_s") }
    let!(:journaled) { journal("tu_s") }
    let(:turns) { turns_of([use], [journaled]) }

    def use_of(id, given = input) = { "type" => "tool_use", "id" => id, "name" => "memory_write", "input" => given }

    def journal(id)
      result = tool.call(input.transform_keys(&:to_sym), Lain::Tool::Invocation.new(tool_use_id: id, context: session))
      JSON.parse(JSON.generate(Lain::Tool::ResultBlock.of(result, tool_use_id: id).to_h))
    end

    def turns_of(uses, results)
      [{ "type" => "turn", "digest" => "d1", "parent" => nil, "content" => uses },
       { "type" => "turn", "digest" => "d2", "parent" => "d1", "content" => results }]
    end

    def replayed(turns)
      empty = Lain::Memory::ProjectStore.empty
      written = Lain::Memory::ProjectStore::Loaded.of([recorder.fetch("s")]).index.root
      records = [{ "type" => "memory_loaded", "version" => empty.version, "items" => [] }, *turns,
                 { "type" => "memory_root", "turn_digest" => "d1", "root" => empty.index.root },
                 { "type" => "memory_root", "turn_digest" => "d2", "root" => written }]
      Lain::Bench::Session::MemoryReplay.new(records:).recorded_memory
    end

    it "yields the item that was written" do
      expect(described_class.new(turns.map { |turn| turn.fetch("content") }).first.digest)
        .to eq(recorder.fetch("s").digest)
    end

    it "survives the next turn's replay check" do
      expect(replayed(turns).index.fetch("s").digest).to eq(recorder.fetch("s").digest)
    end

    it "refuses by name a recorded result that disagrees with its call" do
      edited = use_of("tu_s", input.merge("body" => "edited"))

      expect { described_class.new([[edited], [journaled]]).to_a }
        .to raise_error(described_class::Mismatch, /tu_s/)
    end

    # The default arms deduplicate a round, so a second identical write's
    # result names the first call instead of carrying its own line.
    describe "a repeated identical write in one round" do
      let(:uses) { [use, use_of("tu_t")] }
      let(:bounded) do
        calls = %w[tu_s tu_t].map { |id| Lain::Tool::RoundBudget::Call.new(id:, tool:) }
        Lain::Tool::RoundBudget.dedup_only.for(head: nil).call([journaled, journal("tu_t")], calls)
      end

      it "yields the written item for both calls" do
        expect(bounded.last.fetch("content")).not_to eq(journaled.fetch("content"))
        expect(described_class.new([uses, bounded]).map(&:digest)).to eq([recorder.fetch("s").digest] * 2)
      end

      it "survives the next turn's replay check" do
        expect(replayed(turns_of(uses, bounded)).index.fetch("s").digest).to eq(recorder.fetch("s").digest)
      end
    end
  end

  describe ".recorded" do
    let(:item) { Lain::Memory::Item.new(id: "s", description: "d", body: "b", sources: { "a.rb" => "blake3:ab" }) }
    let(:fields) { ->(item) { %i[id description body author sources].map { |field| item.public_send(field) } } }
    let(:read_back) do
      lambda do |line|
        recorded = JSON.parse(line.delete_prefix("recorded item: "))
        Lain::Memory::Item.new(id: "recorded", description: "", body: "",
                               author: Lain::Memory::Author.from(recorded["author"]), sources: recorded["sources"])
      end
    end
    let(:battery) do
      AlgebraLaws::RoundTrip.from(render: described_class.method(:recorded), parse: read_back,
                                  equal: ->(a, b) { fields.call(a) == fields.call(b) },
                                  population: -> { [item] })
    end

    it "is a verification, not a round trip: the line holds the digest and never the body" do
      outcomes = AlgebraLaws.outcomes(battery)

      expect(outcomes).to eq(AlgebraLaws::ROUND_TRIP_LAW => :fails)
      expect(battery.witness).to eq(item)
      expect(JSON.parse(described_class.recorded(item).delete_prefix("recorded item: ")).keys)
        .to contain_exactly("author", "digest", "sources")
    end
  end
end
