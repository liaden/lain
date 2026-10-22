# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Tools::MemoryRead do
  subject(:tool) { described_class.new(index:) }

  let(:item) do
    Lain::Memory::Item.new(
      id: "dosage",
      description: "Adult dosage guidance for the trial drug",
      body: "500mg twice daily with food.\nHalve for renal impairment."
    )
  end
  let(:index) { Lain::Memory::Index.empty.write(item) }

  it "returns the item's body verbatim after an author line" do
    expect(tool.call(id: "dosage")).to eq(Lain::Tool::Result.ok("author: chat\n#{item.body}"))
  end

  it "names the clerk and its lineage on a clerk's item" do
    clerked = Lain::Memory::Item.new(id: "ttl", description: "d", body: "b",
                                     author: Lain::Memory::Author.clerk(spawn: "sha256:abc"))
    result = described_class.new(index: Lain::Memory::Index.empty.write(clerked)).call(id: "ttl")

    expect(result.content).to eq("author: clerk (spawn sha256:abc)\nb")
  end

  it "answers an unknown id with an error Result naming the id, never a raise" do
    result = nil
    expect { result = tool.call(id: "half-life") }.not_to raise_error
    expect(result).to have_attributes(is_error: true, content: /no memory with id.*half-life/)
  end

  it "does not care about the invocation it is handed" do
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect(tool.call({ id: "dosage" }, invocation).content).to end_with(item.body)
  end

  it "tells the model the result opens with the author line" do
    expect(tool.description).to include("author")
  end

  it "declares one required string field \"id\"" do
    schema = tool.input_schema
    expect(schema["properties"].keys).to eq(["id"])
    expect(schema["properties"]["id"]).to include("type" => "string")
    expect(schema["required"]).to eq(["id"])
  end

  describe "the clerk's read, in a lain consolidate pass" do
    let(:session) do
      RecordedSpawnSession.new(
        parent_responses: [tool_response(["tu_a", "subagent", { "prompt" => "investigate the login bug" }]),
                           text_response("orchestrated")],
        child_responses: [text_response("the token TTL was zero")]
      ).run
    end
    let(:lineages) { Lain::Bench::Session::Lineages.of(Lain::Bench::Session.load(session.lines)).to_a }
    let(:spawn) { lineages.first.spawn.digest }

    # The clerk reads only its own items, so the item is the lineage's clerk's.
    def clerk_read(body)
      item = Lain::Memory::Item.new(id: "note", description: "d", body:, author: Lain::Memory::Author.clerk(spawn:))
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_r", "memory_read", { "id" => "note" }]),
                                                      text_response("done")])
      consolidate(provider, Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item)))
      provider.requests.last.messages.flat_map { Array(_1["content"]).grep(Hash) }
              .find { _1["type"] == "tool_result" }.fetch("content")
    end

    def consolidate(provider, recorder)
      Dir.mktmpdir do |root|
        Lain::Consolidation.new(provider:, recorder:, context: Lain::Context.new(model: "clerk-model", max_tokens: 256),
                                slots: Lain::Prompt::Slots.load(root:), journal: []).call(lineages)
      end
    end

    it "sees a stored credential masked, and its own lineage digest whole" do
      content = clerk_read("spawn #{spawn}: login bug\nDB_PASSWORD=hunter2pass\n")

      expect(content)
        .to start_with("author: clerk (spawn #{spawn})\nspawn #{spawn}: login bug\nDB_PASSWORD=<redacted:1>\n")
      expect(content).not_to include("hunter2pass")
    end

    it "sees a clean body unchanged" do
      expect(clerk_read("the build uses rake pspec")).to eq("author: clerk (spawn #{spawn})\nthe build uses rake pspec")
    end

    it "cannot rewrite an item it read masked" do
      item = Lain::Memory::Item.new(id: "note", description: "d", body: "API_KEY=12345678\n",
                                    author: Lain::Memory::Author.clerk(spawn:))
      recorder = Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(item))
      rewrite = { "id" => "note", "description" => "d", "body" => "API_KEY=1\n" }
      consolidate(Lain::Provider::Mock.new(responses: [tool_response(["tu_r", "memory_read", { "id" => "note" }]),
                                                       tool_response(["tu_w", "memory_write", rewrite]),
                                                       text_response("done")]), recorder)

      expect(recorder.fetch("note").body).to eq("API_KEY=12345678\n")
    end
  end

  # The same tier-1 contract this tool states in its own docstring ("never a
  # raise"), over the byte shapes that break readers. It runs the BYTE half
  # only: the path half is a filesystem's to pose, and non-UTF-8 is not a shape
  # a memory item can even take -- Canonical refuses those bytes when the Item
  # is constructed, which is a different boundary and a correct one.
  describe "the tier-1 read contract, over pathological bodies" do
    def read_ceiling = Lain::Tools::MemoryRead::BOUND.limit

    def read_of(bytes)
      body = Lain::Memory::Item.new(id: "shape", description: "one shape", body: bytes)
      described_class.new(index: Lain::Memory::Index.empty.write(body)).call(id: "shape")
    end

    it_behaves_like "a tier-1 read that never raises"
  end

  # A memory body is a whole artifact like a file's contents, so an
  # oversized one is refused rather than truncated. It is the THIN case of the
  # three -- there is no window on memory and no structural query over it -- so
  # what the refusal names is the manifest line every item already has and the
  # superseding write that can replace it.
  describe "refusing a body too large to hand back" do
    let(:ceiling) { Lain::Tools::MemoryRead::BOUND.limit }

    let(:oversized) do
      Lain::Memory::Item.new(id: "dump", description: "A whole log, pasted",
                             body: "SENTINEL\n" * ((ceiling / 9) + 2))
    end
    let(:index) { Lain::Memory::Index.empty.write(item).write(oversized) }

    it "refuses the read, naming the body's size and the ceiling" do
      result = tool.call(id: "dump")

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("dump", oversized.body.bytesize.to_s, ceiling.to_s)
    end

    it "carries none of the refused body" do
      expect(tool.call(id: "dump").content).not_to include("SENTINEL")
    end

    # Fix round: neither of the first draft's two narrower actions survived
    # being followed. There is no manifest TOOL -- the manifest rides every
    # Request through Workspace -- so "read the manifest" named a call the
    # model cannot make; and "supersede it with a smaller memory_write" is
    # destructive AND needs the bytes it was just denied. What is left is a
    # fact it already has and a call it can actually place.
    it "names only actions that exist" do
      content = tool.call(id: "dump").content

      expect(content).to include("manifest already in your context", "different id")
      expect(content).not_to include("supersede")
    end

    # It may MENTION memory_write to explain why an item this large exists at
    # all; what it must not do is send the model there, because superseding an
    # id needs the bytes this refusal just withheld and destroys them either
    # way.
    it "does not send the model to a memory_write that cannot help it" do
      expect(Lain::Tools::MemoryRead::NARROWER.join(" ")).not_to match(/supersede|write a smaller|replace it/)
    end

    it "refuses a 20 KiB body, over the one result ceiling" do
      large = Lain::Memory::Item.new(id: "notes", description: "Long notes", body: "n" * (20 * 1024))

      result = described_class.new(index: Lain::Memory::Index.empty.write(large)).call(id: "notes")

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("ceiling of 16384")
    end

    it "leaves every item under the ceiling readable" do
      expect(tool.call(id: "dosage")).to eq(Lain::Tool::Result.ok("author: chat\n#{item.body}"))
    end
  end
end
