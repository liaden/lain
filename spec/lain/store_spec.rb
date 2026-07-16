# frozen_string_literal: true

RSpec.describe Lain::Store do
  subject(:store) { described_class.new }

  def turn(body) = Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => body }])

  def payload(body) = Lain::Event::Payload.new(kind: :turn, body: { "text" => body })

  # A turn's body is a Store edge now (its payload_digest), so putting a turn
  # means putting its carried payload first -- the same order Timeline#commit
  # uses. Returns the turn's digest, like a bare #put.
  def put_turn(event)
    store.put(event.carried_payload)
    store.put(event)
  end

  it "starts empty" do
    expect(store.size).to eq(0)
  end

  it "returns the digest from #put" do
    t = turn("hi")
    expect(put_turn(t)).to eq(t.digest)
  end

  it "stores and fetches" do
    t = turn("hi")
    put_turn(t)
    expect(store.fetch(t.digest)).to eq(t)
  end

  include_examples "a content-addressed store", store: -> { store }, member: -> { payload("hi") }

  it "raises on a missing object" do
    expect { store.fetch("blake3:nope") }
      .to raise_error(Lain::Store::MissingObject, /no object/)
  end

  it "answers key?" do
    t = turn("hi")
    expect(store.key?(t.digest)).to be(false)
    put_turn(t)
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
      root = turn("root")
      expect(put_turn(root)).to eq(root.digest)
    end

    it "accepts a well-formed chain, parent-first" do
      root = turn("a")
      put_turn(root)
      child = Lain::Event.turn(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      expect(put_turn(child)).to eq(child.digest)
    end

    it "re-puts an existing chained turn as a no-op" do
      root = turn("a")
      put_turn(root)
      child = Lain::Event.turn(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      put_turn(child)
      expect { store.put(child) }.not_to raise_error
      # Each turn stores its envelope AND its out-of-line payload, so a two-turn
      # chain is four objects; re-putting is still a no-op.
      expect(store.size).to eq(4)
    end

    it "treats an object with no #parent method as parentless" do
      item = Lain::Memory::Item.new(id: "a", description: "about a", body: "v1")
      expect { store.put(item) }.not_to raise_error
    end
  end

  # An Event names three predecessor edges -- a single render_parent, a
  # causal_parents set, and its payload_digest -- and all flow through the SAME
  # dangling-parent refusal, in the SAME message format the single-parent (Turn)
  # put pins. These examples pin the render/causal edges, so the body is present
  # throughout; the payload edge itself is pinned by the two examples below.
  describe "referential integrity across an event's two edges" do
    let(:payload) { Lain::Event::Payload.new(kind: :message, body: { "text" => "hi" }) }

    before { store.put(payload) }

    def event(render_parent: nil, causal_parents: [])
      Lain::Event.new(kind: :message, payload_digest: payload.digest,
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
      put_turn(a)
      put_turn(b)
      ev = event(render_parent: a.digest, causal_parents: [a.digest, b.digest])
      expect(store.put(ev)).to eq(ev.digest)
    end

    it "accepts an event with neither edge (a root event)" do
      expect { store.put(event) }.not_to raise_error
    end

    # T4: payload_digest is a THIRD predecessor edge -- the envelope names a body
    # the Store must already hold. Refused in the same message the parent edges
    # pin; a root event (no render/causal edge) isolates the payload as the sole
    # dangle, so the message names the payload digest.
    it "refuses an event whose payload was never put, naming the payload digest" do
      missing = "blake3:absent-payload"
      ev = Lain::Event.new(kind: :message, payload_digest: missing)
      expect { store.put(ev) }
        .to raise_error(Lain::Store::MissingObject,
                        %(no object #{missing.inspect} in store: putting #{ev.digest.inspect} would dangle))
    end

    # A stored payload stays Ractor-shareable -- "no reachable mutable state"
    # must survive the round trip through the Store, since storing payloads is
    # what T4 begins doing on every commit.
    it "keeps a stored payload Ractor-shareable" do
      body = { "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }
      pay = Lain::Event::Payload.new(kind: :turn, body:)
      store.put(pay)
      expect(Ractor.shareable?(store.fetch(pay.digest))).to be(true)
    end
  end

  it "survives concurrent writers" do
    payloads = Array.new(50) { |i| payload("body-#{i}") }
    threads = payloads.each_slice(10).map do |slice|
      Thread.new { slice.each { |p| store.put(p) } }
    end
    threads.each(&:join)

    expect(store.size).to eq(50)
    expect(payloads).to all(satisfy { |p| store.key?(p.digest) })
  end
end
