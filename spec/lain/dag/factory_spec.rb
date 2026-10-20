# frozen_string_literal: true

RSpec.describe Lain::Dag::Factory do
  describe ".store" do
    it "builds a fresh store each call" do
      expect(described_class.store).not_to equal(described_class.store)
    end
  end

  describe ".timeline" do
    let(:store) { described_class.store }

    it "builds an empty timeline over the given store by default" do
      timeline = described_class.timeline(store:)

      expect(timeline).to be_a(Lain::Ext::Timeline).and be_empty
      expect(timeline.store).to equal(store)
    end

    it "points a timeline at an existing head" do
      head = described_class.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])

      expect(described_class.timeline(head_digest: head.head_digest, store:)).to eq(head)
    end

    it "refuses a head the store does not hold" do
      expect { described_class.timeline(head_digest: "0" * 64, store:) }.to raise_error(Lain::Ext::Store::MissingObject)
    end
  end

  describe ".event" do
    it "builds an event carrying its payload" do
      event = described_class.event(kind: :message, body: { "text" => "hi" }, from: "parent", to: "child",
                                    causal_parents: [], correlation: nil)

      expect([event.class, event.carried_payload.body]).to eq([Lain::Ext::Event, { "text" => "hi" }])
    end
  end

  describe "construction sites" do
    let(:root) { File.expand_path("../../..", __dir__) }
    let(:factory) { File.join(root, "lib/lain/dag/factory.rb") }
    let(:direct) { /\b(?:Timeline\s*\.\s*(?:new|empty)|Store\s*\.\s*new)\b/ }
    let(:sources) { Dir[File.join(root, "lib/**/*.rb"), File.join(root, "bin/*")].select { |path| File.file?(path) } }

    it "has no direct construction of a timeline or a store outside the factory" do
      offenders = (sources - [factory]).select do |path|
        File.read(path).gsub(/^\s*#.*$/, "").match?(direct)
      end

      expect(offenders).to be_empty
    end
  end
end
