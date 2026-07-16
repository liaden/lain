# frozen_string_literal: true

RSpec.describe Lain::Store do
  subject(:store) { described_class.new }

  def turn(body) = Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => body }])

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
      .to raise_error(Lain::Store::MissingObject, /no object/)
  end

  it "answers key?" do
    t = turn("hi")
    expect(store.key?(t.digest)).to be(false)
    store.put(t)
    expect(store.key?(t.digest)).to be(true)
  end

  # Referential integrity at the API boundary: a stored turn's parent must
  # already be in the store, so no chain reachable from any Store can dangle.
  # Prevention at #put replaces public-API reachability of the walk raises;
  # the Timeline walks stay loud as the backstop (see timeline_spec.rb's
  # flipped dangling-parent block).
  describe "referential integrity" do
    let(:missing) { "blake3:absent" }
    let(:dangling) { Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => "head" }], parent: missing) }

    it "refuses a turn whose parent digest was never put" do
      expect { store.put(dangling) }
        .to raise_error(Lain::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{dangling.digest.inspect} would dangle))
    end

    it "accepts a root turn (no parent)" do
      expect(store.put(turn("root"))).to eq(turn("root").digest)
    end

    it "accepts a well-formed chain, parent-first" do
      root = turn("a")
      store.put(root)
      child = Lain::Event.turn(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      expect(store.put(child)).to eq(child.digest)
    end

    it "re-puts an existing chained turn as a no-op" do
      root = turn("a")
      store.put(root)
      child = Lain::Event.turn(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      store.put(child)
      expect { store.put(child) }.not_to raise_error
      expect(store.size).to eq(2)
    end

    it "treats an object with no #parent method as parentless" do
      item = Lain::Memory::Item.new(id: "a", description: "about a", body: "v1")
      expect { store.put(item) }.not_to raise_error
    end
  end

  # An Event names two predecessor edges -- a single render_parent and a
  # causal_parents set -- and both flow through the SAME dangling-parent
  # refusal, in the SAME message format the single-parent (Turn) put pins.
  describe "referential integrity across an event's two edges" do
    def event(render_parent: nil, causal_parents: [])
      Lain::Event.new(kind: :message, payload_digest: "blake3:payload",
                      render_parent:, causal_parents:)
    end

    it "refuses an event whose render_parent was never put" do
      missing = "blake3:absent-render"
      ev = event(render_parent: missing)
      expect { store.put(ev) }
        .to raise_error(Lain::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{ev.digest.inspect} would dangle))
    end

    it "refuses an event whose causal parent was never put" do
      missing = "blake3:absent-causal"
      ev = event(causal_parents: [missing])
      expect { store.put(ev) }
        .to raise_error(Lain::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{ev.digest.inspect} would dangle))
    end

    it "accepts an event whose render_parent and every causal parent are already present" do
      a = turn("a")
      b = turn("b")
      store.put(a)
      store.put(b)
      ev = event(render_parent: a.digest, causal_parents: [a.digest, b.digest])
      expect(store.put(ev)).to eq(ev.digest)
    end

    it "accepts an event with neither edge (a root event)" do
      expect { store.put(event) }.not_to raise_error
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
end
