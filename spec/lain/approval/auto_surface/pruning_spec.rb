# frozen_string_literal: true

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock), the
# same shape auto_surface_spec.rb's own support module uses.
module PruningSpecSupport
  # A minimal decided?-only double: Pending is a plain identity-keyed object
  # (compare_by_identity), so all Pruning needs from it is that one predicate.
  Decided = Struct.new(:decided?)
end

RSpec.describe Lain::Approval::AutoSurface::Pruning do
  # AC2: the seen-set no longer grows unbounded. A long watch adjudicates many
  # pendings; once one SETTLES (decided elsewhere, or by this surface), its
  # entry is released -- observable here, at the pruning seam itself, rather
  # than via an object-count heuristic on AutoSurface's private @adjudicated.
  it "releases adjudicated entries whose pending has since settled" do
    settled = PruningSpecSupport::Decided.new(true)
    still_parked = PruningSpecSupport::Decided.new(false)
    adjudicated = { settled => true, still_parked => true }.compare_by_identity

    described_class.new.call(adjudicated)

    expect(adjudicated).not_to have_key(settled)
    expect(adjudicated).to have_key(still_parked)
  end

  it "returns the same hash it was given, pruned" do
    adjudicated = {}.compare_by_identity

    expect(described_class.new.call(adjudicated)).to be(adjudicated)
  end
end
