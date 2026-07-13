# frozen_string_literal: true

# The cross-impl retrieval contract every memory search index must obey,
# whatever its scoring: Memory::Manifest (the always-runs floor, references/
# memory-and-retrieval.md #2) and Memory::Bm25 (T9, a boosting arm over the
# same floor) both ride this ONE set of laws, so a richer index can never
# regress what consumers (Context::Recall, the manifest tools) depend on.
#
# Pinned: determinism (same query, same index -> the same Hits, every time,
# within one process -- ordering across *repeated runs of one impl* is part
# of that, not merely equality of the Hit values), the Hit duck (id,
# description, score, why), #why never blank, k-bounding, and empty-on-no-
# match. Deliberately NOT pinned: score VALUES across impls -- Manifest's
# token-fraction score and BM25's score live on different scales by design,
# and comparing them would be grading one ranking against the wrong rubric.
#
# Include with a Hash:
#
#   build   [#call(pairs) -> index]        pairs: an Array of [id,
#                                           description, body] triples (the
#                                           fixture corpus below). Builds one
#                                           index instance per example.
#   search  [#call(index, query, k) -> Array<Hit>]  the impl's own top-k
#                                           calling convention -- Manifest has
#                                           no k parameter and bounds via
#                                           #first(k) on its receiver, while
#                                           Bm25 accepts k: directly. Pinning
#                                           k-bounding through one seam lets
#                                           each impl keep its own idiom
#                                           instead of forcing a shared method
#                                           signature neither owns.
#
# == Why every callable runs through #index_call instead of a bare call
#
# Same reason as "a Regular value" (see regular.rb): the config Hash is built
# inside a `describe` body, so a Proc literal there closes over the example
# GROUP, not an instance. `instance_exec` rebinds `self` to the real example,
# where the including spec's own `item`/`index_over`/`manifest_over` helpers
# actually live.
RSpec.shared_examples "a memory search index" do |config|
  build = config.fetch(:build)
  search = config.fetch(:search)

  define_method(:index_call) { |callable, *args| instance_exec(*args, &callable) }

  # A small drug-mention corpus. Descriptions alone carry every term the laws
  # below search for, so the fixture is meaningful to Manifest too (Manifest
  # tokenizes id + description only, never body) -- body is present solely to
  # give Bm25 more surface to score against, per its own design.
  # Named `laws_*` rather than the more obvious `corpus`/`index`: those names
  # are exactly what a consuming spec's own top-level `let`s are called
  # (manifest_spec.rb already has `index`), and `include_examples` splices
  # this group's `let`s into the SAME example group rather than a nested one
  # -- a same-name `let` here would shadow the consumer's own, and since the
  # consumer's `build` callable typically calls back into a helper that reads
  # its own `index`/`store` lets, the collision recurses into a stack
  # overflow rather than failing loudly.
  let(:laws_corpus) do
    [
      ["aspirin-dosage", "Adult aspirin dosing guidance", "Aspirin 325-650mg every 4 hours as needed"],
      ["ibuprofen-dosage", "Adult ibuprofen dosing", "Ibuprofen 200-400mg every 6 hours with food"],
      ["imatinib-therapy", "Imatinib chronic myeloid leukemia regimen", "Imatinib 400mg once daily with food"],
      ["warfarin-interactions", "Warfarin interaction list", "Warfarin interacts with NSAIDs and aspirin"]
    ]
  end
  let(:laws_index) { index_call(build, laws_corpus) }

  it "is deterministic: the same query against the same index returns the same Hits every time" do
    first = index_call(search, laws_index, "aspirin dosing", 3)
    second = index_call(search, laws_index, "aspirin dosing", 3)
    expect(first).to eq(second)
  end

  it "returns Hit-duck results" do
    hit = index_call(search, laws_index, "aspirin dosing", 3).first
    expect(hit.id).to be_a(String)
    expect(hit.description).to be_a(String)
    expect(hit.score).to be_a(Float)
    expect(hit.why).to be_a(String)
  end

  it "never returns a blank why" do
    hits = index_call(search, laws_index, "aspirin ibuprofen warfarin imatinib", 10)
    expect(hits).not_to be_empty
    expect(hits.map(&:why)).to all(satisfy { |why| !why.strip.empty? })
  end

  it "bounds the result count by k" do
    hits = index_call(search, laws_index, "aspirin ibuprofen warfarin imatinib", 2)
    expect(hits.size).to be <= 2
  end

  it "is empty when the query shares no tokens with any document" do
    expect(index_call(search, laws_index, "zzznonexistent qqquux", 5)).to eq([])
  end
end
