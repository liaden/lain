# frozen_string_literal: true

RSpec.describe Lain::SessionRecord::Sections do
  describe ".new" do
    it "refuses a profile or provenance left out, since a header without either is unreadable" do
      expect { described_class.new }.to raise_error(ArgumentError, /profile.*provenance/)
    end
  end

  it "refuses an empty profile or provenance, so a bad header fails at write time" do
    complete = SessionSections.complete

    expect do
      described_class.new(profile: {}, provenance: complete.provenance)
    end.to raise_error(ArgumentError, /profile/)
    expect { described_class.new(profile: complete.profile, provenance: {}) }
      .to raise_error(ArgumentError, /provenance/)
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
