# frozen_string_literal: true

RSpec.describe Lain::Event do
  def block(text) = [{ "type" => "text", "text" => text }]

  def payload(kind: :turn, body: { "role" => "user", "content" => block("hi") })
    Lain::Event::Payload.new(kind:, body:)
  end

  def event(kind: :turn, payload_digest: payload.digest, **rest)
    Lain::Event.new(kind:, payload_digest:, **rest)
  end

  # TL-2, the cut: Turn collapsed into Event(kind: :turn), so the one primitive
  # is all there is -- one content-addressing scheme, one Store, one Ractor spec.
  it "is the only turn primitive: no Lain::Turn constant remains" do
    expect(Lain.const_defined?(:Turn)).to be(false)
  end

  describe "the closed kind set" do
    it "accepts each of the four legal kinds" do
      %i[turn spawn message snapshot].each do |kind|
        expect(event(kind:, payload_digest: "blake3:p").kind).to eq(kind)
      end
    end

    # AC: the kind set is closed and loud.
    it "raises a named error identifying the kind and listing the four legal kinds" do
      expect { event(kind: :banana, payload_digest: "blake3:p") }
        .to raise_error(Lain::Event::InvalidKind,
                        "kind must be one of turn, spawn, message, snapshot, got :banana")
    end

    it "coerces a String kind to the canonical Symbol" do
      expect(event(kind: "message", payload_digest: "blake3:p").kind).to eq(:message)
    end
  end

  describe "the envelope" do
    it "carries the direct-addressing and edge fields" do
      ev = event(kind: :message, payload_digest: "blake3:p", from: "orchestrator", to: "worker",
                 render_parent: "blake3:r", causal_parents: ["blake3:c"], correlation: "blake3:root")
      expect(ev).to have_attributes(kind: :message, from: "orchestrator", to: "worker",
                                    render_parent: "blake3:r", causal_parents: ["blake3:c"],
                                    correlation: "blake3:root", payload_digest: "blake3:p")
    end

    it "defaults every optional field so a bare event is well-formed" do
      ev = event(kind: :snapshot, payload_digest: "blake3:p")
      expect(ev).to have_attributes(from: nil, to: nil, render_parent: nil,
                                    causal_parents: [], correlation: nil)
    end

    # Review fix (T4): accepting a carried Payload made payload_digest an
    # optional keyword, so the old required-keyword loudness moves into an
    # explicit guard -- an envelope with no payload address at all is a bug.
    it "demands a payload address: neither payload_digest nor carried_payload is loud" do
      expect { Lain::Event.new(kind: :turn) }
        .to raise_error(ArgumentError, /payload_digest or carried_payload/)
    end

    # The carried Payload IS the address, so a separately passed digest or body
    # could only agree (noise) or disagree (a bug): refuse both.
    it "refuses a carried Payload alongside an explicit payload_digest or body" do
      pay = payload
      expect { Lain::Event.new(kind: :turn, carried_payload: pay, payload_digest: pay.digest) }
        .to raise_error(ArgumentError, /carried_payload already/)
    end
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(event.digest).to start_with("blake3:")
    end

    # AC: identity is stable (Canonical bytes) -- two events built from the same
    # content name the same digest, in this or any other process.
    it "is stable across independent constructions of the same content" do
      one = event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
                  render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2])
      two = event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
                  render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2])
      expect(one.digest).to eq(two.digest)
    end

    it "distinguishes events that differ in any envelope field" do
      base = event(kind: :message, payload_digest: "blake3:p", from: "a")
      other = event(kind: :message, payload_digest: "blake3:p", from: "z")
      expect(base.digest).not_to eq(other.digest)
    end

    # Panel amendment: causal_parents is a SET -- insertion order must not leak
    # into identity, so it enters the digested bytes in sorted order. Ruby<->Rust
    # byte parity later depends on this pin.
    it "sorts causal_parents into the digested bytes, so insertion order does not change identity" do
      forward = event(payload_digest: "blake3:p", causal_parents: %w[blake3:a blake3:b blake3:c])
      shuffled = event(payload_digest: "blake3:p", causal_parents: %w[blake3:c blake3:a blake3:b])
      expect(forward.digest).to eq(shuffled.digest)
    end

    it "exposes causal_parents already sorted and deduplicated" do
      ev = event(payload_digest: "blake3:p", causal_parents: %w[blake3:c blake3:a blake3:a blake3:b])
      expect(ev.causal_parents).to eq(%w[blake3:a blake3:b blake3:c])
    end
  end

  describe "immutability" do
    subject(:ev) do
      event(kind: :message, payload_digest: "blake3:p", from: "a", to: "b",
            render_parent: "blake3:r", causal_parents: %w[blake3:c1 blake3:c2], correlation: "blake3:root")
    end

    it "is deeply frozen" do
      expect(ev).to be_deeply_frozen
    end

    # AC: Ractor.shareable?(event) is true -- the mechanical "no reachable mutable
    # state". String interpolation and Symbol#to_s both hand back mutable Strings.
    it "is deeply immutable, hence Ractor-shareable without make_shareable" do
      expect(ev).to be_ractor_shareable
    end

    it "freezes every instance variable" do
      unfrozen = ev.instance_variables.reject { |ivar| ev.instance_variable_get(ivar).frozen? }
      expect(unfrozen).to be_empty
    end
  end

  describe "Regular equality" do
    it "equates two events naming the same digest" do
      expect(event(payload_digest: "blake3:p")).to eq(event(payload_digest: "blake3:p"))
    end

    it "dedupes in a Set by digest" do
      set = Set.new([event(payload_digest: "blake3:p"), event(payload_digest: "blake3:p")])
      expect(set.size).to eq(1)
    end
  end

  # The former Lain::Turn surface, now the :turn constructor on the one
  # primitive. These examples moved from turn_spec.rb with the collapse; the
  # reader surface (role/content/parent/meta/digest/root?) is unchanged.
  describe ".turn" do
    def turn(**args)
      Lain::Event.turn(role: :user, content: block("hi"), **args)
    end

    describe "construction" do
      it "accepts the two wire roles" do
        expect(Lain::Event::ROLES).to contain_exactly("user", "assistant")
      end

      it "rejects any other role" do
        expect { turn(role: "system") }
          .to raise_error(Lain::Event::InvalidRole, /must be one of/)
      end

      it "accepts a Symbol role" do
        expect(turn(role: :user).role).to eq("user")
      end

      it "is a root when it has no parent" do
        expect(turn).to be_root
      end

      it "carries the prompt chain on the single render edge, which #parent aliases" do
        chained = turn(parent: "blake3:abc")
        expect(chained.render_parent).to eq("blake3:abc")
        expect(chained.parent).to eq("blake3:abc")
      end
    end

    describe "the carried body" do
      # What is hashed and what is retained must not drift apart, so the event
      # carries the normalized wire form rather than whatever the caller passed.
      it "stores content in normalized wire form" do
        event = Lain::Event.turn(role: :user, content: [{ type: :text, text: "hi" }])
        expect(event.content).to eq([{ "type" => "text", "text" => "hi" }])
      end

      it "addresses the body out of line: payload_digest names Payload(kind: :turn, body:)" do
        tagged = turn(meta: { "a" => 1 })
        body = { "role" => "user", "content" => block("hi"), "meta" => { "a" => 1 } }
        expect(tagged.payload_digest).to eq(Lain::Event::Payload.new(kind: :turn, body:).digest)
      end

      # Review fix (T4): the turn CARRIES the very Payload object it addresses,
      # so a writer (Timeline#commit) stores that object rather than rebuilding
      # an equal one -- which would repeat the normalize+digest pass per commit.
      it "carries the Payload it addresses, the same object a writer stores" do
        ev = turn
        expect(ev.carried_payload).to be_a(Lain::Event::Payload)
        expect(ev.carried_payload.digest).to eq(ev.payload_digest)
        expect(ev.body).to equal(ev.carried_payload.body)
      end

      it "carries no Payload when built from digests alone" do
        expect(event(kind: :turn, payload_digest: "blake3:p").carried_payload).to be_nil
      end

      it "deeply freezes content" do
        expect(turn.content).to be_deeply_frozen
      end

      # Deep shareability is the guarantee "no reachable mutable state"; it
      # fails loudly the moment an ivar stops being frozen. `Symbol#to_s` and
      # string interpolation both hand back mutable Strings, which is how it
      # broke once.
      it "is deeply immutable, hence Ractor-shareable without make_shareable" do
        expect(turn(meta: { "a" => 1 })).to be_ractor_shareable
      end

      it "answers no body fields when detached (built from digests alone), loudly" do
        detached = event(kind: :turn, payload_digest: "blake3:p")
        expect { detached.role }.to raise_error(Lain::Event::Detached, /carries no body/)
      end
    end

    describe "#digest" do
      it "is identical for identical content" do
        expect(turn).to have_same_digest_as(turn)
      end

      it "changes with content" do
        expect(turn).not_to have_same_digest_as(Lain::Event.turn(role: :user, content: block("bye")))
      end

      it "changes with role" do
        expect(turn).not_to have_same_digest_as(turn(role: :assistant))
      end

      it "changes with parent, which is what chains the DAG" do
        expect(turn).not_to have_same_digest_as(turn(parent: "blake3:abc"))
      end

      # meta carries causal lineage (e.g. "spawned_from"), so it must stay
      # inside the content address -- it rides through the body's
      # payload_digest -- or two causally distinct turns would share an address.
      it "changes with meta, via the body digest" do
        tagged = turn(meta: { "spawned_from" => "blake3:abc" })
        expect(turn).not_to have_same_digest_as(tagged)
        expect(turn.payload_digest).not_to eq(tagged.payload_digest)
      end
    end

    describe "equality (Regular)" do
      include_examples "a Regular value",
                       equal_pair: lambda {
                         [Lain::Event.turn(role: :user, content: block("hi")),
                          Lain::Event.turn(role: :user, content: block("hi"))]
                       },
                       unequal: -> { Lain::Event.turn(role: :user, content: block("bye")) },
                       non_member: -> { Lain::Event.turn(role: :user, content: block("hi")).digest }
    end
  end

  # AC: payloads are content-addressed, never inline in the envelope.
  describe Lain::Event::Payload do
    it "is content-addressed and kind-tagged" do
      pay = payload(kind: :turn, body: { "role" => "user", "content" => block("hi") })
      expect(pay.digest).to start_with("blake3:")
      expect(pay.kind).to eq(:turn)
    end

    it "shares the envelope's closed, loud kind set" do
      expect { described_class.new(kind: :banana, body: {}) }
        .to raise_error(Lain::Event::InvalidKind, /got :banana/)
    end

    it "is deeply immutable, hence Ractor-shareable" do
      expect(payload).to be_ractor_shareable
    end

    it "the envelope references the payload by digest, and the payload is separately retrievable" do
      store = Lain::Store.new
      pay = payload(kind: :turn)
      store.put(pay)
      ev = event(kind: :turn, payload_digest: pay.digest)

      expect(ev.payload_digest).to eq(pay.digest)
      expect(store.fetch(ev.payload_digest)).to eq(pay)
    end

    # T4: storing the payload is purely additive -- payload_digest was already
    # in the hashed envelope, so an event's identity is unchanged whether or not
    # its body is in the Store, and the stored body reproduces from the carried
    # body. This is why every variance fixture still verifies through the Loader.
    it "storing the body does not change the event digest, and reproduces from the carried body" do
      store = Lain::Store.new
      ev = Lain::Event.turn(role: :user, content: block("hi"), meta: { "a" => 1 })
      before = ev.digest
      store.put(Lain::Event::Payload.new(kind: :turn, body: ev.body))
      store.put(ev)

      expect(ev.digest).to eq(before)
      expect(store.fetch(ev.payload_digest)).to eq(Lain::Event::Payload.new(kind: :turn, body: ev.body))
    end
  end
end
