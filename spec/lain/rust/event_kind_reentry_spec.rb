# frozen_string_literal: true

# A kind that is not one of the four is quoted in the refusal by its own
# `#inspect`, which is Ruby; see spec/support/reentry.rb for why a fiber dropped
# there can leak and how the leak is measured.
RSpec.describe "Lain::Ext::Event kind re-entering Ruby" do
  include Reentry

  def bogus(text)
    Class.new do
      define_method(:to_s) { "bogus#{text}" }
      define_method(:inspect) { Reentry.suspend_here || "#<bogus>" }
    end.new
  end

  it "frees the kind text it read when the fiber is dropped inside #inspect" do
    kind = bogus(payload)

    expect(leaked_by { Lain::Ext::Event.new(kind:, payload_digest: "blake3:x") }).to be < Reentry::PAYLOAD
  end

  it "still quotes a refused kind by its #inspect" do
    expect { Lain::Ext::Event.new(kind: bogus(""), payload_digest: "blake3:x") }
      .to raise_error(Lain::Error, /got #<bogus>/)
  end
end
