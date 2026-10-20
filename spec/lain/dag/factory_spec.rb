# frozen_string_literal: true

RSpec.describe Lain::Dag::Factory do
  def selecting(value)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("LAIN_DAG", anything).and_return(value)
  end

  describe ".store" do
    it "builds a fresh store each call" do
      expect(described_class.store).not_to equal(described_class.store)
    end
  end

  describe ".timeline" do
    let(:store) { described_class.store }

    it "builds an empty timeline over the given store by default" do
      timeline = described_class.timeline(store:)

      expect(timeline).to be_empty
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

  describe ".implementation" do
    it "names the Rust implementation when LAIN_DAG selects it" do
      selecting("rust")

      expect([described_class.implementation, described_class.store.class]).to eq([:rust, Lain::Ext::Store])
    end

    it "builds the Rust timeline over the Rust store" do
      selecting("rust")

      expect(described_class.timeline(store: described_class.store)).to be_a(Lain::Ext::Timeline)
    end

    it "keeps the Ruby implementation one environment variable away" do
      selecting("ruby")

      expect([described_class.implementation, described_class.timeline(store: described_class.store).class])
        .to eq([:ruby, Lain::Timeline])
    end

    it "refuses an implementation it does not know, naming the two it does" do
      selecting("python")

      expect { described_class.store }.to raise_error(Lain::Error, /"python".*rust.*ruby/)
      expect { described_class.timeline(store: Lain::Store.new) }.to raise_error(Lain::Error, /"python".*rust.*ruby/)
      expect { described_class.event(kind: :turn, body: {}) }.to raise_error(Lain::Error, /"python".*rust.*ruby/)
      expect { described_class.implementation }.to raise_error(Lain::Error, /"python".*rust.*ruby/)
    end
  end

  describe ".event" do
    def message(setting)
      selecting(setting)
      described_class.event(kind: :message, body: { "text" => "hi" }, from: "parent", to: "child",
                            causal_parents: [], correlation: nil)
    end

    it "builds the selected implementation's event, carrying its payload" do
      events = %w[ruby rust].map { |setting| message(setting) }

      expect(events.map(&:class)).to eq([Lain::Event, Lain::Ext::Event])
      expect(events.map { |event| event.carried_payload.body }).to all(eq({ "text" => "hi" }))
    end

    it "addresses the same event identically in both implementations" do
      expect(message("rust").digest).to eq(message("ruby").digest)
    end
  end

  describe "a store of the other implementation" do
    it "is refused by name when Rust is selected" do
      selecting("rust")

      expect { described_class.timeline(store: Lain::Store.new) }
        .to raise_error(Lain::Dag::Factory::ForeignStore, /Lain::Store.*rust/)
    end

    it "is refused by name when Ruby is selected" do
      selecting("ruby")

      expect { described_class.timeline(store: Lain::Ext::Store.new) }
        .to raise_error(Lain::Dag::Factory::ForeignStore, /Lain::Ext::Store.*ruby/)
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
