# frozen_string_literal: true

# `Store#put` asks a node for its tree or bytes and for the digest it claims;
# see spec/support/reentry.rb for why a fiber dropped inside one of those calls
# can leak and how the leak is measured.
RSpec.describe "Lain::Ext::Store#put re-entering Ruby" do
  include Reentry

  let(:store) { Lain::Ext::Store.new }

  def node(**answers)
    Class.new do
      answers.each { |name, answer| define_method(name, &answer) }
    end.new
  end

  def suspending_digest = -> { Reentry.suspend_here || "blake3:unchecked" }

  it "frees the tree it read when the fiber is dropped inside #digest" do
    big = payload
    tree = node(canonical: -> { { "big" => big } }, digest: suspending_digest)

    expect(leaked_by { store.put(tree) }).to be < Reentry::PAYLOAD
  end

  it "frees the bytes it read when the fiber is dropped inside #digest" do
    big = payload
    blob = node(tag: -> { "blob" }, bytes: -> { big }, digest: suspending_digest)

    expect(leaked_by { store.put(blob) }).to be < Reentry::PAYLOAD
  end

  it "frees the partial tree when the fiber is dropped inside the tree's own conversion" do
    allow(JSON).to receive(:generate).and_wrap_original do |original, *args|
      Reentry.suspend_here
      original.call(*args)
    end
    big = payload
    floating = node(canonical: -> { { "big" => big, "n" => 1.5 } }, digest: -> { "blake3:unchecked" })

    expect(leaked_by { store.put(floating) }).to be < Reentry::PAYLOAD
  end

  it "still stores a node whose digest it verified" do
    plain = node(canonical: -> { { "big" => "y" } }, digest: -> { Lain::Ext.canonical_digest(canonical) })

    expect(store.put(plain)).to eq(plain.digest)
    expect(store.fetch(plain.digest)).to eq("big" => "y")
  end
end
