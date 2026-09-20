# frozen_string_literal: true

# The namespace's own constants: the closed sets every guard beneath it cites.
#
# `Review::FILE_STATES` restates `MARK_STATES`' two spellings by hand
# (`review.rb`'s own doc says why: the legend's best-to-worst order is not
# `MARK_STATES`' declared order, so `+` isn't the right derivation). A restated
# pair is exactly the trap that doc warns against unless something holds it
# equal to the source it restates -- `Anchor::SIDES` earns that with a spec;
# before this file existed, `FILE_STATES` did not, despite its own comment
# claiming one.
RSpec.describe Lain::Review do
  it "restates every MARK_STATES member inside FILE_STATES, so the two spellings cannot drift apart" do
    expect(Lain::Review::MARK_STATES - Lain::Review::FILE_STATES).to be_empty
  end

  # `event_spec.rb`'s "no Turn constant remains", one namespace over. The scope
  # axis has a REGISTRY now, and a String list beside it would be the second
  # declaration `review.rb`'s own doc calls worse than a duplicate -- free to
  # disagree, with `SCOPES.include?(scope)` answering false for a strategy that
  # is registered and resolvable.
  it "declares no SCOPES of its own, because the strategy registry is that vocabulary" do
    expect(described_class.const_defined?(:SCOPES, false)).to be(false)
  end
end
