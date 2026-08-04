# frozen_string_literal: true

# `Review::FILE_STATES` restates `MARK_STATES`' two spellings by hand
# (`vocabulary.rb`'s own doc says why: the legend's best-to-worst order is not
# `MARK_STATES`' declared order, so `+` isn't the right derivation). A restated
# pair is exactly the trap the file's own doc warns against unless something
# holds it equal to the source it restates -- `Anchor::SIDES` earns that with a
# spec; before this file existed, `FILE_STATES` did not, despite its own
# comment claiming one.
RSpec.describe "Lain::Review vocabulary" do
  it "restates every MARK_STATES member inside FILE_STATES, so the two spellings cannot drift apart" do
    expect(Lain::Review::MARK_STATES - Lain::Review::FILE_STATES).to be_empty
  end
end
