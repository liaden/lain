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

  describe "the header sections it writes" do
    def self.hashes_of(keys_to_values)
      gen = PropCheck::Generators
      gen.array(gen.one_of(*keys_to_values.map { |key, values| gen.tuple(gen.constant(key), values) }), max: 3)
         .map(&:to_h)
    end

    def self.word = PropCheck::Generators.alphanumeric_string(min: 1, max: 6)

    def self.profiles
      gen = PropCheck::Generators
      gen.tuple(word, hashes_of("api_base" => word, "num_ctx" => gen.positive_integer,
                                "num_batch" => gen.positive_integer))
         .map { |provider, extra| extra.merge("provider" => provider) }
    end

    # The profile leaves out model, effort and keep_alive: the header writes those beside the
    # profile, not in it, so Sections never holds them. A drawn compaction may be empty: the
    # header writer fills the schedule default, not Sections.
    def self.compactions
      gen = PropCheck::Generators
      hashes_of("compact_strategy" => word, "compact_keep" => gen.positive_integer,
                "compact" => gen.constant(false), "compact_schedule" => gen.one_of(gen.constant("idle"),
                                                                                   gen.constant("turn")))
    end

    def self.sections
      nested = PropCheck::Generators.array(PropCheck::Generators.tuple(word, word), max: 3).map(&:to_h)
      provenance = nested.map { |fields| { "provenance" => fields.merge("harness" => "h") } }
      PropCheck::Generators.fixed_hash(profile: profiles, compaction: compactions, arms: nested,
                                       middleware: nested, summarizer: nested, provenance:)
                           .map { |fields| described_class.new(**fields) }
    end

    include_examples "a round trip",
                     render: :to_header.to_proc,
                     parse: ->(header) { described_class.from_header(JSON.parse(JSON.generate(header))) },
                     generator: sections
  end

  describe "#to_header" do
    it "writes no key for an empty arms, middleware or summarizer section" do
      header = described_class.new(profile: { "provider" => "ollama" }, provenance: { "provenance" => { "a" => "b" } },
                                   arms: {}, middleware: {}, summarizer: {}).to_header

      expect(header.keys).to contain_exactly("provider", "provenance")
    end
  end

  describe ".from_header" do
    let(:header) { JSON.parse(JSON.generate(SessionSections.complete.to_header)) }

    it "refuses a header with no provenance, naming it" do
      expect { described_class.from_header(header.except("provenance")) }
        .to raise_error(Lain::Bench::Session::Corrupt, /provenance/)
    end

    it "refuses a header with no provider, naming it" do
      expect { described_class.from_header(header.except("provider")) }
        .to raise_error(Lain::Bench::Session::Corrupt, /provider/)
    end

    it "reads a section the header leaves out as empty" do
      expect(described_class.from_header(header).middleware).to eq({})
    end
  end
end
