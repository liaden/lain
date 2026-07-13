# frozen_string_literal: true

require "lain/memory/manifest"
require "lain/memory/index"
require "lain/memory/item"
require "lain/context"
require "lain/store"
require "lain/timeline"
require "lain/toolset"
require "lain/workspace"

RSpec.describe Lain::Memory::Manifest do
  let(:store) { Lain::Store.new }
  let(:index) { Lain::Memory::Index.empty(store: store) }

  def item(id, description)
    Lain::Memory::Item.new(id: id, description: description, body: "body of #{id}")
  end

  def manifest_over(*items)
    described_class.new(items.inject(index) { |idx, entry| idx.write(entry) })
  end

  describe "#lines" do
    it "renders one 'id | description' line per live entry, sorted by id" do
      manifest = manifest_over(item("b", "beta"), item("a", "alpha"))
      expect(manifest.lines).to eq(["a | alpha", "b | beta"])
    end

    # A pure projection of content: no timestamps, no insertion order, so two
    # indexes holding the same entries render the same Manifest.
    it "is identical across indexes that wrote the same items in different orders" do
      forward = manifest_over(item("a", "alpha"), item("b", "beta"))
      backward = manifest_over(item("b", "beta"), item("a", "alpha"))
      expect(forward.lines).to eq(backward.lines)
      expect(forward.search("alpha beta")).to eq(backward.search("alpha beta"))
    end

    # The "sorted by id" invariant is Manifest's own claim, so it must hold
    # whatever order the source enumerates -- the dependency is the #map duck,
    # not Index#each's walk order. Duplicate-id resolution stays the Index's
    # job, which is why this source has none.
    it "sorts by id itself, whatever order the source enumerates" do
      manifest = described_class.new([item("b", "beta"), item("a", "alpha")])
      expect(manifest.lines).to eq(["a | alpha", "b | beta"])
    end

    it "shows only the latest description for a superseded item" do
      manifest = manifest_over(item("dosage", "v1 guidance"), item("dosage", "v2 guidance"))
      expect(manifest.lines).to eq(["dosage | v2 guidance"])
    end

    it "is empty over an empty index" do
      expect(described_class.new(index).lines).to eq([])
    end
  end

  describe "#to_reminder" do
    it "joins the lines into one workspace-ready String" do
      manifest = manifest_over(item("a", "alpha"), item("b", "beta"))
      expect(manifest.to_reminder).to eq("a | alpha\nb | beta")
    end

    # Sent, not stored: the manifest rides the uncached suffix through
    # Workspace. What must be byte-stable is the MANIFEST's projection, not
    # merely Context's purity, so the digests are compared ACROSS two
    # manifests whose indexes wrote the same items in different orders. Any
    # write-order leakage into to_reminder would break the prompt cache
    # silently; this is the spec that catches it.
    it "keeps Context#render digest-identical across write orders" do
      context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse")
      timeline = Lain::Timeline.empty(store: store)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hello" }])
      toolset = Lain::Toolset.new
      forward = manifest_over(item("a", "alpha"), item("b", "beta"))
      backward = manifest_over(item("b", "beta"), item("a", "alpha"))

      digests = [forward, backward].map do |manifest|
        workspace = Lain::Workspace.empty.with(manifest.to_reminder)
        context.render(timeline: timeline, toolset: toolset, workspace: workspace).digest
      end
      expect(digests.uniq.size).to eq(1)
    end
  end

  describe "#search" do
    let(:manifest) do
      manifest_over(
        item("aspirin-dosage", "Adult aspirin dosing guidance"),
        item("ibuprofen-dosage", "Adult ibuprofen dosing"),
        item("acetaminophen-dosage", "Pediatric acetaminophen dosing"),
        item("warfarin-interactions", "Warfarin interaction list")
      )
    end

    it "scores by the fraction of query tokens matched" do
      hits = manifest.search("aspirin dosage")
      expect(hits.first.id).to eq("aspirin-dosage")
      expect(hits.first.score).to eq(1.0)
    end

    it "sorts by score descending, then id ascending" do
      hits = manifest.search("aspirin dosage")
      expect(hits.map(&:id)).to eq(%w[aspirin-dosage acetaminophen-dosage ibuprofen-dosage])
    end

    it "excludes zero-score entries" do
      expect(manifest.search("aspirin dosage").map(&:id)).not_to include("warfarin-interactions")
    end

    it "explains every hit by naming the matched tokens" do
      hits = manifest.search("aspirin dosage")
      expect(hits).to all(satisfy { |hit| !hit.why.strip.empty? })
      expect(hits.first.why).to include("matched tokens").and include("aspirin").and include("dosage")
    end

    # The floor below tokenization: a query that contains the id verbatim
    # always hits, even when \w+ token overlap is zero.
    it "hits on a literal id substring the tokenizer cannot see" do
      hits = manifest_over(item("aspirin", "Aspirin monograph")).search("aspirindosage")
      expect(hits.map(&:id)).to eq(%w[aspirin])
      expect(hits.first.why).to include("aspirin").and include("substring floor")
    end

    # #why must explain the NUMBER: when the substring floor outscores the
    # token fraction, naming matched tokens would misattribute the score.
    it "attributes the score to the substring floor when the floor wins" do
      hit = manifest.search("aspirin-dosage extra").first
      expect(hit.id).to eq("aspirin-dosage")
      expect(hit.score).to eq("aspirin-dosage".length.fdiv("aspirin-dosage extra".length))
      expect(hit.why).to include("substring floor")
    end

    it "matches case-insensitively" do
      expect(manifest.search("ASPIRIN Dosage").first.id).to eq("aspirin-dosage")
    end

    it "returns [] on no match, never raising" do
      expect(manifest.search("ketamine")).to eq([])
    end

    it "returns [] on a tokenless query, never raising" do
      expect(manifest.search("")).to eq([])
      expect(manifest.search("???")).to eq([])
    end

    it "is deterministic: same query, same index, same Hits, every time" do
      expect(manifest.search("adult dosing")).to eq(manifest.search("adult dosing"))
    end
  end

  # Manifest is the always-runs floor -- the cross-impl contract in
  # memory_index_laws.rb also binds Memory::Bm25 (spec/lain/memory/bm25_spec.rb),
  # so a richer index can never regress what this baseline guarantees.
  describe "as a memory search index" do
    include_examples "a memory search index",
                     build: lambda { |corpus|
                       manifest_over(*corpus.map { |id, description, _body|
                         item(id, description)
                       })
                     },
                     search: ->(idx, query, k) { idx.search(query).first(k) }
  end

  describe "Hit" do
    def hit(id: "a", description: "alpha", score: 0.5, why: "matched alpha")
      described_class::Hit.new(id: id, description: description, score: score, why: why)
    end

    # A judgment you cannot read the reason for is unusable -- the same
    # non-negotiable as Grader::Grade#why.
    it "refuses a blank why" do
      expect { hit(why: "") }.to raise_error(ArgumentError, /why/)
      expect { hit(why: "   ") }.to raise_error(ArgumentError, /why/)
    end

    # Manifest only emits 0..1, but Hit does not hard-clamp: a boosting arm
    # that exceeds 1.0 must renormalize, and a clamp would hide that bug. The
    # loud floor is finite and non-negative.
    it "refuses a non-finite or negative score" do
      expect { hit(score: Float::NAN) }.to raise_error(ArgumentError, /score/)
      expect { hit(score: Float::INFINITY) }.to raise_error(ArgumentError, /score/)
      expect { hit(score: -0.1) }.to raise_error(ArgumentError, /score/)
    end

    it "accepts a score above 1.0 rather than clamping it" do
      expect(hit(score: 1.5).score).to eq(1.5)
    end

    # to_f would coerce garbage to a valid-looking 0.0 -- exactly the silent
    # boosting-arm bug the finite/non-negative floor exists to catch.
    it "refuses a non-numeric score rather than coercing it to 0.0" do
      expect { hit(score: "high") }.to raise_error(ArgumentError, /high/)
    end

    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      expect(hit).to be_frozen
      expect(Ractor.shareable?(hit)).to be(true)
    end

    it "is Ractor-shareable when built by #search" do
      hits = manifest_over(item("a", "alpha")).search("alpha")
      expect(hits).to all(satisfy { |h| Ractor.shareable?(h) })
    end

    describe "equality (Regular)" do
      include_examples "a Regular value",
                       equal_pair: -> { [hit, hit] },
                       unequal: -> { hit(id: "b") },
                       non_member: -> { hit.id }
    end
  end

  describe "immutability" do
    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      manifest = manifest_over(item("a", "alpha"))
      expect(manifest).to be_frozen
      expect(Ractor.shareable?(manifest)).to be(true)
    end
  end
end
