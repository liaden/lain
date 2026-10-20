# frozen_string_literal: true

# A canonical conversion calls into Ruby midway; see spec/support/reentry.rb for
# why a fiber dropped there can leak and how the leak is measured.
RSpec.describe "Lain::Ext canonical conversion re-entering Ruby" do
  include Reentry

  it "frees the partial tree when the fiber is dropped inside a float's JSON.generate" do
    allow(JSON).to receive(:generate).and_wrap_original do |original, *args|
      Reentry.suspend_here
      original.call(*args)
    end

    expect(leaked_by { Lain::Ext.canonical_dump([payload, { "n" => 1.5 }]) }).to be < Reentry::PAYLOAD
  end

  # Ruby's `Canonical.normalize` matches `true` and `false` with `when`, which is
  # identity, so a value's own `==` is never consulted there either.
  it "reads true and false by identity, never asking a value's ==" do
    asked = []
    claims_true = Class.new { define_method(:==) { |other| asked << other or true } }.new

    expect { Lain::Ext.canonical_dump([claims_true]) }.to raise_error(Lain::Canonical::UnsupportedType)
    expect(asked).to be_empty
  end
end
