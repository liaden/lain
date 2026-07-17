# frozen_string_literal: true

# Memory::Bm25 builds a Lain::Ext::Bm25 (T8, the `bm25` crate, in-process) once
# from a snapshot's items and returns Manifest::Hit-duck hits, so it slots into
# Context::Recall (T10) and any other Manifest consumer without a type check.
RSpec.describe Lain::Memory::Bm25 do
  def item(id, description, body: "body of #{id}")
    Lain::Memory::Item.new(id:, description:, body:)
  end

  def index_over(*items)
    store = Lain::Store.new
    items.inject(Lain::Memory::Index.empty(store:)) { |acc, entry| acc.write(entry) }
  end

  let(:snapshot) do
    index_over(
      item("aspirin-dosage", "Adult aspirin dosing guidance", body: "Aspirin 325-650mg every 4 hours as needed"),
      item("ibuprofen-dosage", "Adult ibuprofen dosing", body: "Ibuprofen 200-400mg every 6 hours with food"),
      item("imatinib-therapy", "Chronic myeloid leukemia regimen",
           body: "Imatinib 400mg once daily treats chronic myeloid leukemia")
    )
  end

  describe "as a memory search index" do
    include_examples "a memory search index",
                     build: lambda { |corpus|
                       described_class.new(index: index_over(*corpus.map do |id, description, body|
                         item(id, description, body:)
                       end))
                     },
                     search: ->(idx, query, k) { idx.search(query, k:) }
  end

  # A fresh memory index before the first write is empty; the crate refuses to
  # build an empty corpus, but the Ruby wrapper treats it as a legitimate
  # steady state -- constructs without raising, searches to [].
  describe "over an empty index" do
    it "constructs without raising and searches to []" do
      empty = described_class.new(index: index_over)
      expect(empty.search("aspirin")).to eq([])
    end
  end

  describe "#search" do
    subject(:index) { described_class.new(index: snapshot) }

    # Scenario: exact drug-name recall (remaining-work 5-3.3 acceptance) --
    # the term lives ONLY in the body, so this also proves Bm25 indexes body,
    # unlike Manifest which never sees it.
    it "recalls the item whose body names a rare drug, and #why names the matched token" do
      hits = index.search("imatinib")
      expect(hits.first.id).to eq("imatinib-therapy")
      expect(hits.first.why).to include("imatinib")
    end

    it "returns a Manifest::Hit-duck result" do
      hit = index.search("aspirin").first
      expect(hit).to be_a(Lain::Memory::Manifest::Hit)
      expect(hit.id).to eq("aspirin-dosage")
      expect(hit.description).to eq("Adult aspirin dosing guidance")
    end

    it "is empty when the query shares no tokens with any document" do
      expect(index.search("zzznonexistent qqquux")).to eq([])
    end

    # Williams (T8 panel): a query with no alphanumeric characters tokenizes
    # to nothing on both sides of the FFI boundary and returns [], not an
    # error.
    it "returns [] for a query that tokenizes to nothing (non-alphanumeric only)" do
      expect(index.search("🩺")).to eq([])
    end

    it "bounds the result count by k" do
      expect(index.search("aspirin ibuprofen imatinib", k: 1).size).to eq(1)
    end

    it "is deterministic across repeated calls" do
      expect(index.search("aspirin dosing")).to eq(index.search("aspirin dosing"))
    end

    # Without k:, EVERY match comes back -- pinned at a scale past any
    # plausible implicit library default (10 is common), which a four-item
    # fixture would sail green right through.
    it "returns the full match set without k:, past any plausible implicit cap" do
      items = (1..30).map { |n| item(format("note-%02d", n), "Aspirin note #{n}", body: "aspirin fact #{n}") }
      hits = described_class.new(index: index_over(*items)).search("aspirin")
      expect(hits.size).to eq(30)
    end

    # Gallant (T8 panel): a u32 token-hash collision inside the crate can
    # score a document above zero with an EMPTY surface intersection. Hit#why
    # raises on blank, so an empty matched-tokens hit must fall back to a
    # named explanation, never a blank string or an exception. Constructed via
    # a stub rather than hunting for a real collision, per the escalation note.
    it "falls back to a named why when a hit's matched tokens are empty" do
      engine = instance_double(Lain::Ext::Bm25, search: [["aspirin-dosage", 1.5, []]])
      allow(Lain::Ext::Bm25).to receive(:build).and_return(engine)

      hit = described_class.new(index: index_over(item("aspirin-dosage", "Adult aspirin dosing guidance")))
                           .search("anything")
                           .first

      expect(hit.why).to eq(described_class::FALLBACK_WHY)
      expect(hit.why.strip).not_to be_empty
    end
  end

  # Scenario: Recall composes over Bm25
  describe "composed with Context::Recall" do
    it "lands recalled hits after the last neutral marker (uncached tail)" do
      workspace = Lain::Workspace.new(reminders: ["remember to be terse"])
      base = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "what is the aspirin dosing?" }] }]
      bm25 = described_class.new(index: snapshot)

      pipeline = Lain::Context::Reminder.new(workspace:) >>
                 Lain::Context::CacheBreakpoints.new >>
                 Lain::Context::Recall.new(index: bm25, k: 3)
      without_recall = (Lain::Context::Reminder.new(workspace:) >> Lain::Context::CacheBreakpoints.new)
                       .call(base)

      rendered = pipeline.call(base)
      marker_len = without_recall.last["content"].size

      expect(rendered.last["content"].first(marker_len)).to eq(without_recall.last["content"])
      expect(rendered.last["content"][marker_len - 1]).to have_key("cache")
      expect(rendered.last["content"].last["text"]).to include("aspirin-dosage")
    end
  end

  # to_s is the human-facing projection; inspect keeps the class-tagged,
  # debug-oriented form -- the DegradedSet convention (see
  # capability/degraded_set_spec.rb).
  describe "string conversions" do
    subject(:bm25) { described_class.new(index: snapshot) }

    it "renders to_s as the human entry count, untagged" do
      expect(bm25.to_s).to eq("entries=3")
    end

    it "keeps inspect class-tagged for debugging" do
      expect(bm25.inspect).to eq("#<Lain::Memory::Bm25 entries=3>")
    end

    it "does not alias to_s and inspect" do
      expect(bm25.method(:to_s)).not_to eq(bm25.method(:inspect))
    end
  end
end
