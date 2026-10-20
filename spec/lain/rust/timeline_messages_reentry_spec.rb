# frozen_string_literal: true

# `Timeline#messages` hands every Array it builds to `Canonical.adopt`, which is
# Ruby; see spec/support/reentry.rb for why a fiber dropped there can leak and
# how the leak is measured. Each round builds its own chain, so a walk stranded
# in the fiber would keep that chain's events alive.
RSpec.describe "Lain::Ext::Timeline#messages re-entering Ruby" do
  include Reentry

  it "frees the render state when the fiber is dropped inside Canonical.adopt" do
    allow(Lain::Canonical).to receive(:adopt).and_wrap_original do |original, array|
      Reentry.suspend_here
      original.call(array)
    end
    text = payload
    render = -> { Lain::Ext::Timeline.empty.commit(role: "user", content: [{ "text" => text }]).messages }

    expect(leaked_by(&render)).to be < Reentry::PAYLOAD
  end
end
