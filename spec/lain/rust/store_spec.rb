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

  # Referential integrity at the API boundary -- mirrors store_spec.rb's Ruby
  # group, plus the byte-identical message assertion the T1 parity examples
  # established for this crate.
  describe "referential integrity" do
    let(:missing) { "blake3:absent" }
    let(:dangling) { turn_with_parent(missing) }

    def turn_with_parent(parent)
      Lain::Ext::Turn.new(role: :user, content: [{ "type" => "text", "text" => "head" }], parent:)
    end

    it "refuses a turn whose parent digest was never put" do
      expect { store.put(dangling) }
        .to raise_error(Lain::Ext::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{dangling.digest.inspect} would dangle))
    end

    # The quote-escaping edge ('blake3:a"b') is pinned by the flipped
    # dangling-parent block in rust/timeline_spec.rb; this example pins the
    # plain-digest bytes against both the Ruby message and the literal.
    it "renders the refusal message byte-identical to Ruby's" do
      ruby_head = Lain::Turn.new(role: :user, content: [{ "type" => "text", "text" => "head" }],
                                 parent: missing)
      ext_msg = refusal_message(Lain::Ext::Store::MissingObject) { store.put(dangling) }
      ruby_msg = refusal_message(Lain::Store::MissingObject) { Lain::Store.new.put(ruby_head) }
      expect(ext_msg).to eq(ruby_msg)
      expect(ext_msg)
        .to eq(%(no object #{missing.inspect} in store: putting #{dangling.digest.inspect} would dangle))
    end

    def refusal_message(error_class)
      yield
      raise "expected #{error_class} to be raised"
    rescue error_class => e
      e.message
    end

    it "accepts a root turn (no parent)" do
      expect(store.put(turn("root"))).to eq(turn("root").digest)
    end

    it "accepts a well-formed chain, parent-first" do
      root = turn("a")
      store.put(root)
      child = Lain::Ext::Turn.new(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      expect(store.put(child)).to eq(child.digest)
    end

    it "re-puts an existing chained turn as a no-op" do
      root = turn("a")
      store.put(root)
      child = Lain::Ext::Turn.new(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      store.put(child)
      expect { store.put(child) }.not_to raise_error
      expect(store.size).to eq(2)
    end
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
