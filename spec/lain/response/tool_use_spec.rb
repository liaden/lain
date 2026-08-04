# frozen_string_literal: true

# Captured from the scripted run below against the pre-lens ToolRunner (the
# "before" half of AC 3). Kept out of the RSpec block per
# Lint/ConstantDefinitionInBlock.
PRE_LENS_DIGESTS = %w[
  blake3:4c979108fe0fccd553f923deb23d9cf48d1628f1f37caf4faaa3e9a984a6a9e1
  blake3:1a44dba1e521e4e8a99d6ae9f093a5d0fff0853fcea82405b47a35e7fcbac965
  blake3:da1469119d0514333eacc809e38b13b46e8c9979b672aecf963e3acd51fbe6cb
  blake3:6a54702f4ae70d8158e8e72da970c178ac4b983aebbc930c26a2a5bf77fe0ff9
].freeze

RSpec.describe Lain::Response::ToolUse do
  let(:hash) do
    { "type" => "tool_use", "id" => "tu_1", "name" => "read_file", "input" => { "path" => "a.rb" } }.freeze
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

    it "survives a round trip through wrap twice with its identity intact" do
      expect(described_class.wrap(described_class.wrap(hash)).to_h).to be(hash)
    end

    # .wrap is the ONLY door: a public .new would let `new(wrap(h))` nest a
    # lens, and #to_h would then answer a lens where Canonical expects a Hash.
    it "makes .wrap the only constructor" do
      expect { described_class.new(hash) }.to raise_error(NoMethodError, /private method/)
    end

    it "refuses a non-Hash subject loudly rather than three ways downstream" do
      [nil, :sym, "tu_1", [hash]].each do |subject|
        expect { described_class.wrap(subject) }
          .to raise_error(ArgumentError, /wraps a Hash block, got #{subject.class}/)
      end
    end
  end

  describe "the named readers" do
    subject(:use) { described_class.wrap(hash) }

    it "#id, #name and #input read the wire fields" do
      expect(use.id).to eq("tu_1")
      expect(use.name).to eq("read_file")
      expect(use.input).to eq({ "path" => "a.rb" })
    end

    it "#input hands back the parsed Hash by identity" do
      expect(use.input).to be(hash.fetch("input"))
    end

    it "a malformed block fails loudly at the reader, naming the key and the block" do
      malformed = { "type" => "tool_use", "name" => "read_file", "input" => {} }

      expect { described_class.wrap(malformed).id }
        .to raise_error(KeyError, /"id".*read_file/m)
    end

    it "the KeyError carries the missing key and the block it came from" do
      malformed = { "type" => "tool_use", "id" => "tu_1", "input" => {} }

      error = begin
        described_class.wrap(malformed).name
      rescue KeyError => e
        e
      end

      expect(error.key).to eq("name")
      expect(error.receiver).to be(malformed)
    end

    # A write_file-shaped tool_use carries whole file contents in `input`. The
    # message is capped because `receiver:` already hands a rescue site the
    # whole block.
    it "caps the block it quotes, and says how much it left out" do
      malformed = { "type" => "tool_use", "name" => "write_file", "input" => { "body" => "x" * 10_000 } }

      error = begin
        described_class.wrap(malformed).id
      rescue KeyError => e
        e
      end

      expect(error.message.length).to be < (described_class::INSPECT_LIMIT + 100)
      expect(error.message).to match(/\.\.\. \(\d+ chars\)\z/)
      expect(error.receiver).to be(malformed)
    end
  end

  describe "the Hash-duck surface existing consumers rely on" do
    subject(:use) { described_class.wrap(hash) }

    it "#[] reads a present key and returns nil for a missing one" do
      expect(use["name"]).to eq("read_file")
      expect(use["nope"]).to be_nil
    end

    it "#fetch reads a present key" do
      expect(use.fetch("id")).to eq("tu_1")
    end

    it "#fetch honors a default argument for a missing key" do
      expect(use.fetch("nope", :fallback)).to eq(:fallback)
    end

    it "#fetch honors a default block, yielding the missing key to it" do
      expect(use.fetch("nope") { |key| "no #{key}" }).to eq("no nope")
    end

    it "#fetch on a missing key with no default raises KeyError" do
      expect { use.fetch("nope") }.to raise_error(KeyError)
    end

    # Without the delegation a lens serializes as its own object header --
    # valid JSON carrying a debug string, which the NDJSON Journal would take
    # in silence. Its JSON is the hash's JSON, matching #to_h.
    it "#to_json serializes the underlying block, never the lens's object header" do
      expect(use.to_json).to eq(hash.to_json)
      expect(JSON.parse(use.to_json)).to eq(hash)
    end

    it "#to_json survives being nested inside a larger document" do
      expect(JSON.parse({ "block" => use }.to_json)).to eq({ "block" => hash })
    end
  end

  describe "as a value" do
    it "is frozen" do
      expect(described_class.wrap(hash)).to be_frozen
    end

    it "is Ractor.shareable? over a deeply frozen block" do
      block = Lain::Response.new(content: [hash], stop_reason: :tool_use).tool_uses.first
      expect(block).to be_deeply_frozen
    end
  end

  # AC 3. The lens is a VIEW: nothing it touches may move a committed byte. The
  # literal below was captured from this same scripted run against the
  # pre-lens ToolRunner, so a drift in the wire hash the runner builds and
  # commits fails here rather than silently in a replay.
  describe "committed bytes" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }

    it "does not move the committed turn's digest" do
      agent, = record_run([tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("done")],
                          toolset:, context:)

      expect(agent.timeline.to_a.map(&:digest)).to eq(PRE_LENS_DIGESTS)
    end

    it "commits plain Hashes, never lenses" do
      agent, = record_run([tool_response(["tu_1", "echo", { "text" => "hi" }]), text_response("done")],
                          toolset:, context:)

      blocks = agent.timeline.to_a.flat_map(&:content)
      expect(blocks.map(&:class).uniq).to eq([Hash])
    end
  end
end
