# frozen_string_literal: true

# Captured from the scripted run below against the pre-lens ToolRunner (the
# "before" half of AC 1). Kept out of the RSpec block per
# Lint/ConstantDefinitionInBlock.
PRE_RESULT_LENS_DIGESTS = %w[
  blake3:4c979108fe0fccd553f923deb23d9cf48d1628f1f37caf4faaa3e9a984a6a9e1
  blake3:dfa6fa7152989de6a82b43afd5e9c1e345b66ae209312d768d94402d416ff8eb
  blake3:827cf79c59e586a9f722ccf4e6eb2d7a00c5ef327b82e41792a377ac8190221b
  blake3:cd6ec466ab7f6724798ff6e39c136f0add77c349de1636d2ff9f8ce7377d2560
].freeze

RSpec.describe Lain::Tool::ResultBlock do
  let(:result) { Lain::Tool::Result.ok("hi") }
  let(:hash) do
    { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "hi", "is_error" => false }.freeze
  end

  describe ".of" do
    subject(:block) { described_class.of(result, tool_use_id: "tu_1") }

    it "builds the four wire keys a tool_result carries" do
      expect(block.to_h).to eq(hash)
    end

    # A convention this spec holds the sole builder to, NOT a byte invariant:
    # Canonical sorts keys for the digest, and the one NDJSON line carrying a
    # tool_result (`request_sent`) is normalized before it is written, so no
    # reader downstream can observe this order.
    it "writes the four keys in the order the wire documents" do
      expect(block.to_h.keys).to eq(%w[type tool_use_id content is_error])
    end

    it "reads is_error off the Result, never off the shape of the content" do
      expect(described_class.of(Lain::Tool::Result.error("boom"), tool_use_id: "tu_1").to_h["is_error"]).to be(true)
      expect(described_class.of(Lain::Tool::Result.ok("Error: not really"), tool_use_id: "tu_1")
                            .to_h["is_error"]).to be(false)
    end

    it "carries the Result's content through by identity" do
      content = +"the file body"
      expect(described_class.of(Lain::Tool::Result.ok(content), tool_use_id: "tu_1").content).to be(content)
    end

    # Gate 4 as a constructor invariant: an unpairable block cannot be built.
    it "refuses a missing tool_use_id" do
      expect { described_class.of(result) }.to raise_error(ArgumentError, /tool_use_id/)
    end

    it "refuses a nil tool_use_id, naming the class it got" do
      expect { described_class.of(result, tool_use_id: nil) }
        .to raise_error(ArgumentError, /names the tool_use it answers.*got NilClass/)
    end

    # "got String" would name the RIGHT class and read as a contradiction of
    # the rule it follows, so the empty case says which half is wrong.
    it "refuses an empty tool_use_id by its emptiness, not by its class" do
      expect { described_class.of(result, tool_use_id: "") }
        .to raise_error(ArgumentError, /got an empty String/)
    end

    # The one shape a real turn could still produce: a numeric id. Anthropic's
    # wire rejects it too -- this just fails at the builder instead of the 400.
    it "refuses a numeric tool_use_id" do
      expect { described_class.of(result, tool_use_id: 7) }
        .to raise_error(ArgumentError, /got Integer/)
    end

    it "refuses a non-String tool_use_id, naming only the class" do
      expect { described_class.of(result, tool_use_id: :tu_secret) }
        .to raise_error(ArgumentError, /got Symbol/)
      expect { described_class.of(result, tool_use_id: :tu_secret) }
        .to raise_error(ArgumentError) { |error| expect(error.message).not_to include("tu_secret") }
    end
  end

  describe ".wrap" do
    it "wraps a plain Hash into a lens" do
      expect(described_class.wrap(hash)).to be_a(described_class)
    end

    it "is idempotent: wrapping a lens returns the very same object" do
      lens = described_class.wrap(hash)
      expect(described_class.wrap(lens)).to be(lens)
    end

    # A dup would digest the same yet not BE the same object -- exactly the
    # drift the identity-preserving #to_h exists to prevent.
    it "#to_h hands back the ORIGINAL hash by identity" do
      expect(described_class.wrap(hash).to_h).to be(hash)
    end

    it "hands back the hash .of built, by identity, through a wrap round trip" do
      built = described_class.of(result, tool_use_id: "tu_1")
      expect(described_class.wrap(built).to_h).to be(built.to_h)
    end

    # .wrap and .of are the only doors: a public .new would let `new(wrap(h))`
    # nest a lens, and #to_h would then answer a lens where Canonical expects
    # a Hash.
    it "makes .of and .wrap the only constructors" do
      expect { described_class.new(hash) }.to raise_error(NoMethodError, /private method/)
    end

    it "refuses a non-Hash subject loudly, naming only the class" do
      [nil, :sym, "tu_1", [hash]].each do |subject|
        expect { described_class.wrap(subject) }
          .to raise_error(ArgumentError, /wraps a Hash block, got #{subject.class}/)
      end
    end
  end

  describe "the named readers" do
    subject(:block) { described_class.wrap(hash) }

    it "#tool_use_id, #content and #error? read the wire fields" do
      expect(block.tool_use_id).to eq("tu_1")
      expect(block.content).to eq("hi")
      expect(block.error?).to be(false)
    end

    it "#error? answers true on a failed block" do
      expect(described_class.of(Lain::Tool::Result.error("boom"), tool_use_id: "tu_1").error?).to be(true)
    end

    it "agrees with a block .of built for the same result" do
      built = described_class.of(result, tool_use_id: "tu_1")
      wrapped = described_class.wrap(built.to_h.dup)

      expect([wrapped.tool_use_id, wrapped.content, wrapped.error?])
        .to eq([built.tool_use_id, built.content, built.error?])
    end

    it "a malformed block fails loudly at the reader, naming the key and the block" do
      malformed = { "type" => "tool_result", "content" => "hi", "is_error" => false }

      expect { described_class.wrap(malformed).tool_use_id }
        .to raise_error(KeyError, /"tool_use_id".*tool_result/m)
    end

    it "the KeyError carries the missing key and the block it came from" do
      malformed = { "type" => "tool_result", "tool_use_id" => "tu_1", "content" => "hi" }

      error = begin
        described_class.wrap(malformed).error?
      rescue KeyError => e
        e
      end

      expect(error.key).to eq("is_error")
      expect(error.receiver).to be(malformed)
    end

    # A read_file-shaped result carries a whole file in `content`. The message
    # is capped because `receiver:` already hands a rescue site the whole block.
    it "caps the block it quotes, and says how much it left out" do
      malformed = { "type" => "tool_result", "content" => "x" * 10_000, "is_error" => false }

      error = begin
        described_class.wrap(malformed).tool_use_id
      rescue KeyError => e
        e
      end

      expect(error.message.length).to be < (described_class::INSPECT_LIMIT + 100)
      expect(error.message).to match(/\.\.\. \(\d+ chars\)\z/)
      expect(error.receiver).to be(malformed)
    end
  end

  describe "the Hash-duck surface existing consumers rely on" do
    subject(:block) { described_class.wrap(hash) }

    it "#[] reads a present key and returns nil for a missing one" do
      expect(block["tool_use_id"]).to eq("tu_1")
      expect(block["nope"]).to be_nil
    end

    it "#fetch reads a present key" do
      expect(block.fetch("content")).to eq("hi")
    end

    it "#fetch honors a default argument for a missing key" do
      expect(block.fetch("nope", :fallback)).to eq(:fallback)
    end

    it "#fetch honors a default block, yielding the missing key to it" do
      expect(block.fetch("nope") { |key| "no #{key}" }).to eq("no nope")
    end

    it "#fetch on a missing key with no default raises KeyError" do
      expect { block.fetch("nope") }.to raise_error(KeyError)
    end

    # Without the delegation a lens serializes as its own object header --
    # valid JSON carrying a debug string, which the NDJSON Journal would take
    # in silence. Its JSON is the hash's JSON, matching #to_h.
    it "#to_json serializes the underlying block, never the lens's object header" do
      expect(block.to_json).to eq(hash.to_json)
      expect(JSON.parse(block.to_json)).to eq(hash)
    end

    it "#to_json survives being nested inside a larger document" do
      expect(JSON.parse({ "block" => block }.to_json)).to eq({ "block" => hash })
    end
  end

  describe "as a value" do
    it "is frozen" do
      expect(described_class.wrap(hash)).to be_frozen
    end

    # The runner hands this hash to the observer seam AFTER #result_block and
    # BEFORE Timeline#commit, so an unfrozen block lets a late writer rewrite
    # the committed experiment record with gates 3 and 4 already behind it.
    it "freezes the block it builds, so a late writer raises where it writes" do
      built = described_class.of(result, tool_use_id: "tu_1")

      expect(built.to_h).to be_frozen
      expect { built.to_h["content"] = "TAMPERED" }.to raise_error(FrozenError)
    end

    # Honest about what the freeze does NOT buy. It is shallow, and a Result's
    # content String is mutable, so the built lens is not shareable. That only
    # arrives once `Canonical.normalize` has deep-frozen the block -- which is
    # the shape .wrap meets on the read side.
    it "is Ractor.shareable? only once the block has been normalized" do
      built = described_class.of(Lain::Tool::Result.ok(+"hi"), tool_use_id: "tu_1")

      expect(built).not_to be_deeply_frozen
      expect(described_class.wrap(Lain::Canonical.normalize(built.to_h))).to be_deeply_frozen
    end
  end

  # AC 1. The lens is a VIEW: nothing it touches may move a committed byte. The
  # literals above were captured from this same scripted run against the
  # pre-lens ToolRunner, so a drift in the wire hash the runner builds and
  # commits fails here rather than silently in a replay.
  describe "committed bytes" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new, BoomTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
    let(:script) do
      [tool_response(["tu_1", "echo", { "text" => "hi" }], ["tu_2", "boom", {}]), text_response("done")]
    end

    it "does not move the committed turn's digest" do
      agent, = record_run(script, toolset:, context:)

      expect(agent.timeline.to_a.map(&:digest)).to eq(PRE_RESULT_LENS_DIGESTS)
    end

    it "commits plain Hashes, never lenses" do
      agent, = record_run(script, toolset:, context:)

      blocks = agent.timeline.to_a.flat_map(&:content)
      expect(blocks.map(&:class).uniq).to eq([Hash])
    end

    # The observer runs between #result_block and the commit, and its seam
    # contains a broken observer by design, so the FrozenError this raises is
    # swallowed there. What the freeze buys is the line after: the record the
    # experiment keeps is the one the gates approved.
    it "keeps an observer that writes to the block out of the committed record" do
      mutator = Class.new do
        def observe(block, _name) = block["content"] = "TAMPERED"
      end.new
      agent, = record_run(script, toolset:, context:, tool_observer: mutator)

      results = agent.timeline.to_a.flat_map(&:content)
                     .select { |block| block["type"] == "tool_result" }
      expect(results.map { |block| block["content"] }).to eq(["hi", "RuntimeError: kaboom"])
    end
  end
end
