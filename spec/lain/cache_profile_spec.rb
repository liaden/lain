# frozen_string_literal: true

RSpec.describe Lain::CacheProfile do
  describe "the abstract seam" do
    subject(:provider) { Lain::Provider.new }

    it "refuses to guess its cache profile, naming the class" do
      expect { provider.cache_profile }
        .to raise_error(NotImplementedError, /Lain::Provider must declare #cache_profile/)
    end
  end

  # Every provider Lain ships must answer with a real value, not a hash, and
  # not nil -- a scheduler (CAC-3/4) reads real numbers off it.
  describe "every shipped provider answers cache_profile" do
    {
      "Anthropic" => -> { Lain::Provider::Anthropic.new(client: Object.new) },
      "AnthropicRaw" => -> { Lain::Provider::AnthropicRaw.new(transport: Object.new) },
      "Bedrock" => -> { Lain::Provider::Bedrock.new(client: Object.new) },
      "BedrockRaw" => -> { Lain::Provider::BedrockRaw.new(transport: Object.new) },
      "Ollama" => -> { Lain::Provider::Ollama.new(transport: Object.new) },
      "Mock" => -> { Lain::Provider::Mock.new }
    }.each do |name, build|
      it "returns a CacheProfile value for #{name}" do
        expect(build.call.cache_profile).to be_a(described_class)
      end
    end
  end

  describe "the Anthropic-wire profile" do
    # AnthropicRaw/Bedrock/BedrockRaw share Anthropic's numbers verbatim --
    # same wire, same cache economics -- so this asserts they are the
    # IDENTICAL object, not merely equal values that could drift apart later.
    it "is the same object across every Anthropic-shaped backend" do
      anthropic = Lain::Provider::Anthropic.new(client: Object.new).cache_profile
      raw = Lain::Provider::AnthropicRaw.new(transport: Object.new).cache_profile
      bedrock = Lain::Provider::Bedrock.new(client: Object.new).cache_profile
      bedrock_raw = Lain::Provider::BedrockRaw.new(transport: Object.new).cache_profile

      expect([raw, bedrock, bedrock_raw]).to all(equal(anthropic))
    end

    it "reports Opus's real numbers: 5-minute sliding TTL and a 4096-token floor" do
      profile = Lain::Provider::Anthropic.new(client: Object.new).cache_profile

      expect(profile.ttl).to eq(300)
      expect(profile.min_prefix_tokens).to eq(described_class::MINIMUM_CACHEABLE_TOKENS)
      expect(profile.tiered_invalidation).to be(true)
    end
  end

  describe "providers with no prompt cache" do
    it "gives Ollama the flat, no-caching profile" do
      expect(Lain::Provider::Ollama.new(transport: Object.new).cache_profile).to eq(described_class::NO_CACHING)
    end

    it "defaults Mock to NO_CACHING so a scheduler spec never sees a phantom cache" do
      expect(Lain::Provider::Mock.new.cache_profile).to eq(described_class::NO_CACHING)
    end

    it "lets a scheduler spec inject Mock's cache_profile" do
      warm = described_class::ANTHROPIC

      expect(Lain::Provider::Mock.new(cache_profile: warm).cache_profile).to equal(warm)
    end
  end

  describe "the minimum-cacheable constant has one home" do
    it "is read by SiblingTemplate as the exact same object, not a copy" do
      expect(Lain::Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate::MINIMUM_CACHEABLE_TOKENS)
        .to equal(described_class::MINIMUM_CACHEABLE_TOKENS)
    end
  end

  # A CacheProfile stands in for the two per-provider Hash constants it
  # replaced (`Provider::Anthropic::CACHE_PROFILE`,
  # `Provider::Ollama::NO_CACHING_PROFILE`) at every call site that predates
  # it: StatusFeed and Compaction::Cold both read `profile[:ttl]` without
  # knowing the concrete type, and the pre-existing anthropic_spec.rb /
  # ollama_spec.rb pins compare `#cache_profile` to a bare Hash literal via
  # `eq`. Both must keep working unchanged.
  describe "hash-shape compatibility for duck-typed and pre-existing consumers" do
    it "answers [] like the Hash it replaced" do
      expect(described_class::ANTHROPIC[:ttl]).to eq(300)
      expect(described_class::NO_CACHING[:min_prefix_tokens]).to eq(Float::INFINITY)
    end

    it "compares equal to a Hash carrying the same fields" do
      expect(described_class::ANTHROPIC).to eq(
        ttl: 300, min_prefix_tokens: 4096, write_multiplier: 1.25, read_multiplier: 0.1, tiered_invalidation: true
      )
    end

    it "does not compare equal to a Hash missing or differing on a field" do
      expect(described_class::ANTHROPIC).not_to eq(ttl: 301)
    end

    it "keeps ordinary Data equality (class + fields) against a non-Hash" do
      expect(described_class::ANTHROPIC).to eq(described_class::ANTHROPIC)
      expect(described_class::ANTHROPIC).not_to eq(described_class::NO_CACHING)
    end

    # The landmine: #== treats a same-content Hash as equal, so #hash MUST
    # agree, or a caller that indexes a Hash/Set by either interchangeably
    # gets silently inconsistent behavior -- two objects Ruby says are `==`
    # ought to hash the same way.
    it "hashes the same as an equal Hash, so ==/hash stay consistent" do
      hash = { ttl: 300, min_prefix_tokens: 4096, write_multiplier: 1.25, read_multiplier: 0.1,
               tiered_invalidation: true }

      expect(described_class::ANTHROPIC).to eq(hash)
      expect(described_class::ANTHROPIC.hash).to eq(hash.hash)
    end

    it "answers to_hash for implicit Hash coercion (Hash#merge, **profile)" do
      expect({ extra: true }.merge(described_class::ANTHROPIC)).to include(ttl: 300, extra: true)
    end

    # #[] stands in for the Hash it replaced, but only for the Data's own
    # fields -- `public_send` unscoped would let `profile[:frozen?]` or
    # `profile[:class]` silently dispatch an arbitrary method instead of
    # failing the way a Hash's missing key does.
    it "raises KeyError naming the valid fields for an unknown key, rather than dispatching a method" do
      expect { described_class::ANTHROPIC[:frozen?] }.to raise_error(KeyError) do |error|
        expect(error.message).to include(":frozen?")
        expect(error.message).to include("ttl", "min_prefix_tokens", "write_multiplier", "read_multiplier",
                                         "tiered_invalidation")
      end
    end
  end

  # House convention (CLAUDE.md's "Value objects are deeply frozen"), via the
  # shared `be_ractor_shareable` matcher (31 other call sites) rather than a
  # raw `Ractor.shareable?` assertion: the mechanical statement of "no
  # reachable mutable state", pinned by spec everywhere else one exists
  # (Usage, Event, Skill, Oracle's definition, ...). CacheProfile's fields
  # are Integer/Float/Boolean only, so this should hold trivially, but the
  # pin is what catches a future field (a String label, a Symbol via
  # interpolation) that would quietly break it.
  describe "Ractor.shareable?" do
    it "holds for ANTHROPIC" do
      expect(described_class::ANTHROPIC).to be_frozen
      expect(described_class::ANTHROPIC).to be_ractor_shareable
    end

    it "holds for NO_CACHING" do
      expect(described_class::NO_CACHING).to be_frozen
      expect(described_class::NO_CACHING).to be_ractor_shareable
    end
  end
end
