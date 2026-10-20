# frozen_string_literal: true

# The Rust Store must satisfy the SAME content-addressed-store contract as the
# Ruby one: it drives the shared `store_laws` group, and mirrors the rest of
# store_spec.rb (idempotence, MissingObject, key?, concurrent writers) against
# `Lain::Ext::Store`/`Lain::Ext::Turn`.
RSpec.describe Lain::Ext::Store do
  subject(:store) { described_class.new }

  def turn(body) = Lain::Ext::Turn.new(role: :user, content: [{ "type" => "text", "text" => body }])

  # A turn's body is a Store edge (its payload_digest), so putting a turn means
  # putting its carried payload first -- the order Timeline#commit uses.
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

  include_examples "a content-addressed store", store: -> { store }, member: -> { turn("hi").carried_payload }

  it "raises on a missing object" do
    expect { store.fetch("blake3:nope") }
      .to raise_error(Lain::Ext::Store::MissingObject, /no object/)
  end

  it "answers key?" do
    t = turn("hi")
    expect(store.key?(t.digest)).to be(false)
    put_turn(t)
    expect(store.key?(t.digest)).to be(true)
  end

  describe "every kind of member" do
    let(:blob) { Lain::Workspace::Snapshot::Blob.new(bytes: "puts 1\n") }
    let(:item) { Lain::Memory::Item.new(id: "dosage", description: "dosing", body: "500mg") }
    let(:node) { Lain::Memory::Index::Node.new(id: "dosage", item: item.digest) }
    let(:supersession) do
      Lain::Plan::Supersession.new(step_id: "P1", superseded: "blake3:old", superseding: "blake3:new")
    end
    let(:closure) do
      Lain::Plan::Closure.new(step_id: "P1", title: "Port", status: "done", size: "M", criteria_digest: nil,
                              passed: true, score: 0.75, why: "green", files: ["a.rb"], snapshot_scope: nil,
                              elided_digests: [], error_digests: [], notes_for_future_steps: [])
    end
    let(:events) do
      root = turn("root")
      %i[spawn message snapshot].map { |kind| Lain::Ext::Event.new(kind:, body: { "x" => 1 }) }.unshift(root)
    end

    it "fetches every event kind back equal, with its body" do
      events.each { |event| put_turn(event) }

      fetched = events.map { |event| store.fetch(event.digest) }
      expect(fetched).to eq(events)
      expect(fetched.map(&:body)).to eq(events.map(&:body))
    end

    it "fetches a payload back as a payload" do
      payload = turn("hi").carried_payload
      store.put(payload)

      expect(store.fetch(payload.digest)).to eq(payload)
    end

    it "fetches a workspace blob back as its bytes" do
      store.put(blob)

      expect(store.fetch(blob.digest)).to eq(blob.bytes)
    end

    it "fetches a memory item and an index node back through their own readers" do
      store.put(item)
      store.put(node)

      expect(Lain::Memory::Item.from_canon(store.fetch(item.digest))).to eq(item)
      expect(Lain::Memory::Index::Node.from_canon(store.fetch(node.digest))).to eq(node)
    end

    it "fetches a plan closure and a supersession back as trees addressed as they were" do
      store.put(closure)
      store.put(supersession)

      expect(Lain::Canonical.digest(store.fetch(closure.digest))).to eq(closure.digest)
      expect(store.fetch(supersession.digest)).to eq(supersession.canonical)
    end

    it "fetches a canonical tree deeply frozen" do
      store.put(closure)

      expect(Ractor.shareable?(store.fetch(closure.digest))).to be(true)
    end

    it "refuses an object it has no arm for" do
      expect { store.put(Object.new) }.to raise_error(TypeError, /Object/)
    end
  end

  describe "raw binary" do
    let(:bytes) { "\xFF\xFEnot utf-8\x00".b }
    let(:blob) { Lain::Workspace::Snapshot::Blob.new(bytes:) }

    it "is addressed by the blob scheme and fetched back byte for byte" do
      expect(store.put(blob)).to eq(blob.digest)

      fetched = store.fetch(blob.digest)
      expect([fetched, fetched.encoding, fetched.frozen?]).to eq([bytes, Encoding::BINARY, true])
    end

    # Canonical cannot address these bytes at all, so the difference is shown
    # on text both schemes accept.
    it "addresses differently from the canonical digest of the same bytes" do
      text = Lain::Workspace::Snapshot::Blob.new(bytes: "puts 1\n")

      expect { Lain::Canonical.digest(bytes) }.to raise_error(Lain::Canonical::UnsupportedType)
      expect(store.put(text)).not_to eq(Lain::Canonical.digest("puts 1\n"))
    end
  end

  describe "a digest disagreement" do
    let(:forged) { Data.define(:canonical, :digest).new(canonical: { "a" => 1 }, digest: "blake3:forged") }

    it "is refused on a float-free object, naming both digests" do
      expect { store.put(forged) }
        .to raise_error(Lain::Ext::Store::DigestMismatch, /blake3:forged.*#{Lain::Canonical.digest("a" => 1)}/)
      expect(store.size).to eq(0)
    end

    it "is refused on a blob whose digest is not its bytes'" do
      forged_blob = Data.define(:tag, :bytes, :digest).new(tag: "blob", bytes: "x".b, digest: "blake3:forged")

      expect { store.put(forged_blob) }.to raise_error(Lain::Ext::Store::DigestMismatch, /blake3:forged/)
    end
  end

  describe "a detached envelope" do
    let(:whole) { turn("hi") }
    let(:detached) { Lain::Ext::Event.new(kind: :turn, payload_digest: whole.payload_digest) }

    it "is the same address as the envelope that carries its body" do
      expect(detached).to eq(whole)
    end

    it "refuses its role, content and meta" do
      %i[role content meta].each do |reader|
        expect { detached.public_send(reader) }.to raise_error(Lain::Error, /carries no body/)
      end
    end

    it "answers no body and no carried payload" do
      expect([detached.body, detached.carried_payload]).to eq([nil, nil])
    end

    it "is fetched whole once its payload is in the store" do
      store.put(whole.carried_payload)
      store.put(detached)

      expect(store.fetch(whole.digest).content).to eq(whole.content)
    end
  end

  # Referential integrity at the API boundary -- mirrors store_spec.rb's Ruby
  # group, plus the byte-identical message assertion the Ruby/Rust parity
  # examples established for this crate.
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
      ruby_head = Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => "head" }],
                                   parent: missing)
      ext_msg = refusal_message(Lain::Ext::Store::MissingObject) { store.put(dangling) }
      ruby_msg = refusal_message(Lain::Store::MissingObject) { Lain::Store.new.put(ruby_head) }
      expect(ext_msg).to eq(ruby_msg)
      expect(ext_msg)
        .to eq(%(no object #{missing.inspect} in store: putting #{dangling.digest.inspect} would dangle))
    end

    it "refuses an envelope whose payload was never put, in Ruby's words" do
      ruby_root = Lain::Event.turn(role: :user, content: [{ "type" => "text", "text" => "root" }])
      ext_msg = refusal_message(Lain::Ext::Store::MissingObject) { store.put(turn("root")) }
      ruby_msg = refusal_message(Lain::Store::MissingObject) { Lain::Store.new.put(ruby_root) }
      expect(ext_msg).to eq(ruby_msg)
    end

    def refusal_message(error_class)
      yield
      raise "expected #{error_class} to be raised"
    rescue error_class => e
      e.message
    end

    describe "an edge naming an object of the wrong arm" do
      let(:payload) { turn("held").carried_payload }
      let(:item) { Lain::Memory::Item.new(id: "a", description: "d", body: "b") }

      def refusal(edge, child)
        %(no event #{edge.inspect} in store: putting #{child.digest.inspect} would dangle)
      end

      it "refuses a causal parent that is a payload" do
        store.put(payload)
        child = Lain::Ext::Turn.new(role: :user, content: [{ "type" => "text", "text" => "c" }],
                                    causal_parents: [payload.digest])
        store.put(child.carried_payload)

        expect { store.put(child) }
          .to raise_error(Lain::Ext::Store::MissingObject, refusal(payload.digest, child))
      end

      it "refuses a render parent that is a memory item" do
        store.put(item)
        child = turn_with_parent(item.digest)
        store.put(child.carried_payload)

        expect { store.put(child) }.to raise_error(Lain::Ext::Store::MissingObject, refusal(item.digest, child))
      end
    end

    it "accepts a root turn (no parent)" do
      expect(put_turn(turn("root"))).to eq(turn("root").digest)
    end

    it "accepts a well-formed chain, parent-first" do
      root = turn("a")
      put_turn(root)
      child = Lain::Ext::Turn.new(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      expect(put_turn(child)).to eq(child.digest)
    end

    it "re-puts an existing chained turn as a no-op" do
      root = turn("a")
      put_turn(root)
      child = Lain::Ext::Turn.new(role: :assistant, content: [{ "type" => "text", "text" => "b" }], parent: root.digest)
      put_turn(child)
      expect { put_turn(child) }.not_to raise_error
      expect(store.size).to eq(4)
    end
  end

  it "survives concurrent writers" do
    turns = Array.new(50) { |i| turn("body-#{i}") }
    threads = turns.each_slice(10).map do |slice|
      Thread.new { slice.each { |t| put_turn(t) } }
    end
    threads.each(&:join)

    expect(store.size).to eq(100)
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
    expect(Lain::Ext::Store::DigestMismatch.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Turn::InvalidRole.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Timeline::CrossStore.ancestors).to include(Lain::Error)
    expect(Lain::Ext::Bm25::EmptyCorpus.ancestors).to include(Lain::Error)
  end
end
