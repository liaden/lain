# frozen_string_literal: true

# The Rust Store must satisfy the SAME content-addressed-store contract as the
# Ruby one: it drives the shared `store_laws` group, and mirrors the rest of
# store_spec.rb (idempotence, MissingObject, key?, concurrent writers) against
# `Lain::Ext::Store`/`Lain::Ext::Turn`.
RSpec.describe Lain::Ext::Store do
  subject(:store) { described_class.new }

  def turn(body) = Lain::Ext::Turn.new(role: :user, content: [{ "type" => "text", "text" => body }])

  it "starts empty" do
    expect(store.size).to eq(0)
  end

  it "returns the digest from #put" do
    t = turn("hi")
    expect(store.put(t)).to eq(t.digest)
  end

  it "stores and fetches" do
    t = turn("hi")
    store.put(t)
    expect(store.fetch(t.digest)).to eq(t)
  end

  include_examples "a content-addressed store", store: -> { store }, member: -> { turn("hi") }

  it "raises on a missing object" do
    expect { store.fetch("blake3:nope") }
      .to raise_error(Lain::Ext::Store::MissingObject, /no object/)
  end

  it "answers key?" do
    t = turn("hi")
    expect(store.key?(t.digest)).to be(false)
    store.put(t)
    expect(store.key?(t.digest)).to be(true)
  end

  it "survives concurrent writers" do
    turns = Array.new(50) { |i| turn("body-#{i}") }
    threads = turns.each_slice(10).map do |slice|
      Thread.new { slice.each { |t| store.put(t) } }
    end
    threads.each(&:join)

    expect(store.size).to eq(50)
    expect(turns).to all(satisfy { |t| store.key?(t.digest) })
  end

  # `Lain::Ext::init` subclasses every Ext error from `Lain::Error` at
  # extension-load time, with NO StandardError fallback -- a load-order
  # regression (e.g. `lib/lain.rb` requiring `lain/lain` before `lain/error`)
  # must fail loudly there, not silently re-parent every Ext error under a
  # class none of Lain's `rescue Lain::Error` sites catch. Pinning the
  # ancestry here, through the normal `require "lain"` manifest, is the
  # guarantee: it would fail if that fallback ever came back.
  it "descends every Ext error class from Lain::Error" do
    expect(Lain::Ext::Store::MissingObject.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Turn::InvalidRole.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Timeline::CrossStore.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Bm25::EmptyCorpus.ancestors).to include(Lain::Error)
  end
end
