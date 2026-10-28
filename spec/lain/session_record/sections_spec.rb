# frozen_string_literal: true

RSpec.describe Lain::SessionRecord::Sections do
  describe ".none" do
    it "renders every section as an empty hash" do
      expect(described_class.none.to_h).to eq(profile: {}, compaction: {}, arms: {}, middleware: {}, provenance: {},
                                              summarizer: {})
    end

    it "is shareable" do
      expect(Ractor.shareable?(described_class.none)).to be(true)
    end
  end

  describe ".of" do
    let(:profile) { instance_double(Lain::CLI::RunProfile, to_header: { "provider" => "ollama" }) }
    let(:arms) { instance_double(Lain::CLI::Arms, to_header: { "confine" => "reader" }) }
    let(:middleware) { instance_double(Lain::Config::Middleware, to_header: { "project" => "d1" }) }
    let(:provenance) { instance_double(Lain::SessionRecord::Provenance, to_header: { "provenance" => { "a" => "b" } }) }

    it "asks each object for its header, once" do
      sections = described_class.of(profile:, compaction: { "compact_schedule" => "turn" }, arms:, middleware:,
                                    provenance:,
                                    summarizer: { "provider" => "ollama", "model" => "qwen3:4b" })

      expect(sections.to_h).to eq(profile: { "provider" => "ollama" }, compaction: { "compact_schedule" => "turn" },
                                  arms: { "confine" => "reader" }, middleware: { "project" => "d1" },
                                  provenance: { "provenance" => { "a" => "b" } },
                                  summarizer: { "provider" => "ollama", "model" => "qwen3:4b" })
      expect([profile, arms, middleware, provenance]).to all(have_received(:to_header).once)
    end
  end
end
