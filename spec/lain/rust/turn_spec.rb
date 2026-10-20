# frozen_string_literal: true

# The event built as a turn: it drives the shared `regular` group, keeps
# `Ractor.shareable?` true, and addresses itself as Canonical addresses its
# header. The digests themselves are pinned by the conformance corpus
# (ext/lain/corpus/event_digest.ndjson).
RSpec.describe Lain::Ext::Event, "built as a turn" do
  def text(body) = [{ "type" => "text", "text" => body }]

  describe "construction" do
    it "rejects any non-wire role" do
      expect { described_class.new(role: "system", content: text("x")) }
        .to raise_error(described_class::InvalidRole, /must be one of/)
    end

    it "accepts a Symbol role" do
      expect(described_class.new(role: :user, content: text("x")).role).to eq("user")
    end

    it "is a root when it has no parent" do
      expect(described_class.new(role: :user, content: text("x"))).to be_root
    end
  end

  describe "content" do
    it "stores content in normalized wire form" do
      turn = described_class.new(role: :user, content: [{ type: :text, text: "hi" }])
      expect(turn.content).to eq([{ "type" => "text", "text" => "hi" }])
    end

    it "deeply freezes content" do
      turn = described_class.new(role: :user, content: text("hi"))
      expect(turn.content).to be_deeply_frozen
    end

    it "freezes the turn itself" do
      expect(described_class.new(role: :user, content: text("hi"))).to be_deeply_frozen
    end

    # The whole reason the port is allowed: a magnus TypedData wrapping only
    # immutable Rust state stays Ractor-shareable once frozen.
    it "is Ractor-shareable" do
      turn = described_class.new(role: :user, content: text("hi"), meta: { "a" => 1 })
      expect(turn).to be_deeply_frozen
    end

    it "has no unfrozen instance variables" do
      turn = described_class.new(role: :user, content: text("hi"))
      unfrozen = turn.instance_variables.reject { |ivar| turn.instance_variable_get(ivar).frozen? }
      expect(unfrozen).to be_empty
    end
  end

  describe "#digest" do
    it "is a prefixed content address" do
      expect(described_class.new(role: :user, content: text("hi")).digest).to start_with("blake3:")
    end

    it "changes with role, content, parent, and meta" do
      base = described_class.new(role: :user, content: text("hi"))
      expect(base).not_to have_same_digest_as(described_class.new(role: :assistant, content: text("hi")))
      expect(base).not_to have_same_digest_as(described_class.new(role: :user, content: text("bye")))
      expect(base).not_to have_same_digest_as(
        described_class.new(role: :user, content: text("hi"), parent: "blake3:abc")
      )
      expect(base).not_to have_same_digest_as(
        described_class.new(role: :user, content: text("hi"), meta: { "s" => "x" })
      )
    end

    # A content address is only worth its name if it is the digest of the
    # header it reports, parent and meta included.
    it "addresses the header it reports, through Canonical" do
      ext = described_class.new(role: :user, content: text("hi"),
                                parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      expect(ext.digest).to eq(Lain::Canonical.digest(ext.payload))
    end
  end

  describe "#payload" do
    # payload is the exact structure the digest is taken over -- pin it field
    # by field, not just through the digest.
    it "names every header field, the body by its digest" do
      body = { "role" => "user", "content" => text("hi"), "meta" => { "spawned_from" => "blake3:xyz" } }
      turn = described_class.new(role: :user, content: text("hi"),
                                 parent: "blake3:abc", meta: { "spawned_from" => "blake3:xyz" })
      expect(turn.payload).to eq("kind" => :turn, "from" => nil, "to" => nil, "render_parent" => "blake3:abc",
                                 "causal_parents" => [], "correlation" => nil,
                                 "payload_digest" => Lain::Canonical.digest({ "kind" => :turn, "body" => body }))
    end
  end

  describe "the envelope and its payload" do
    subject(:turn) do
      described_class.new(role: :user, content: text("hi"), from: "alice", to: "bob", meta: { "k" => 1 })
    end

    it "names its sender and recipient" do
      expect([turn.from, turn.to]).to eq(%w[alice bob])
    end

    it "has no sender or recipient unless given one" do
      plain = described_class.new(role: :user, content: text("hi"))
      expect([plain.from, plain.to]).to eq([nil, nil])
    end

    it "hands back the carried body" do
      expect(turn.body).to eq("role" => "user", "content" => text("hi"), "meta" => { "k" => 1 })
    end

    it "hands back a frozen payload that names the envelope's payload digest" do
      payload = turn.carried_payload
      expect(payload).to be_a(Lain::Ext::Payload).and be_deeply_frozen
      expect(payload.digest).to eq(turn.payload_digest)
    end

    it "carries a payload addressing its kind and body together" do
      expect(turn.carried_payload)
        .to have_attributes(kind: :turn, body: turn.body,
                            digest: Lain::Canonical.digest({ "kind" => :turn, "body" => turn.body }))
    end

    it "changes digest with the sender and recipient" do
      plain = described_class.new(role: :user, content: text("hi"), meta: { "k" => 1 })
      expect(turn).not_to have_same_digest_as(plain)
    end

    it "addresses the sender and recipient it reports" do
      expect([turn.payload.values_at("from", "to"), turn.digest])
        .to eq([%w[alice bob], Lain::Canonical.digest(turn.payload)])
    end

    it "refuses a sender that is not a String" do
      expect { described_class.new(role: :user, content: text("hi"), from: 7) }.to raise_error(TypeError)
    end

    it "renders the payload as an Ext::Payload" do
      expect(turn.carried_payload.inspect).to start_with("#<Lain::Ext::Payload turn blake3:")
    end

    describe "the payload's equality (Regular)" do
      include_examples "a Regular value",
                       equal_pair: lambda {
                         [described_class.new(role: :user, content: text("hi")).carried_payload,
                          described_class.new(role: :user, content: text("hi")).carried_payload]
                       },
                       unequal: -> { described_class.new(role: :user, content: text("bye")).carried_payload },
                       non_member: -> { "x" }
    end
  end

  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: lambda {
                       [described_class.new(role: :user, content: text("hi")),
                        described_class.new(role: :user, content: text("hi"))]
                     },
                     unequal: -> { described_class.new(role: :user, content: text("bye")) },
                     non_member: -> { described_class.new(role: :user, content: text("hi")).digest }
  end

  # to_s is the human-facing projection; inspect keeps the class-tagged,
  # debug-oriented form -- the same convention Ruby's DegradedSet uses (see
  # capability/degraded_set_spec.rb), now held on both sides of the FFI
  # boundary.
  describe "string conversions" do
    subject(:turn) { described_class.new(role: :user, content: text("hi")) }

    it "renders to_s as role and a truncated digest, untagged" do
      expect(turn.to_s).to eq("user #{turn.digest[0, 19]}...")
    end

    it "keeps inspect class-tagged for debugging" do
      expect(turn.inspect).to eq("#<Lain::Ext::Event #{turn}>")
    end

    it "does not alias to_s and inspect" do
      expect(turn.method(:to_s)).not_to eq(turn.method(:inspect))
    end
  end
end
