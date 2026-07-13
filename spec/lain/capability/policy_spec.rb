# frozen_string_literal: true

require_relative "../../support/recording_channel"

# A provider that supports exactly the capabilities it is told to. Subclassing
# the real Provider means #supports? and #require! (which raises the real
# Provider::Unsupported) are inherited, not re-simulated.
class FakeCapabilityProvider < Lain::Provider
  attr_reader :capabilities

  def initialize(capabilities)
    super()
    @capabilities = capabilities.map(&:to_sym).freeze
  end
end

# A requirer stands in for a Context combinator: all the resolver asks of it is
# #requires.
class FakeRequirer
  attr_reader :requires

  def initialize(requires)
    @requires = requires
  end
end

RSpec.describe Lain::Capability::Policy do
  let(:requirer) { FakeRequirer.new(%i[thinking]) }
  let(:lacking) { FakeCapabilityProvider.new(Lain::Provider::CAPABILITIES - %i[thinking]) }
  let(:full) { FakeCapabilityProvider.new(Lain::Provider::CAPABILITIES) }
  let(:journal) { RecordingChannel.new }

  describe ".for" do
    it "builds a strict policy" do
      expect(described_class.for(:strict)).to be_a(described_class::Strict)
    end

    it "builds a degrade policy" do
      expect(described_class.for(:degrade)).to be_a(described_class::Degrade)
    end

    it "fails loudly on an unknown policy name" do
      expect { described_class.for(:lenient) }.to raise_error(ArgumentError, /lenient/)
    end
  end

  describe ":strict" do
    subject(:policy) { described_class.for(:strict, journal: journal) }

    it "raises Provider::Unsupported on a missing capability" do
      expect { policy.resolve(requirer, lacking) }
        .to raise_error(Lain::Provider::Unsupported, /thinking/)
    end

    it "never journals a degradation" do
      expect { policy.resolve(requirer, lacking) }.to raise_error(Lain::Provider::Unsupported)
      expect(journal.events).to be_empty
    end

    it "returns an empty degraded set when everything is supported" do
      expect(policy.resolve(requirer, full)).to be_empty
    end
  end

  describe ":degrade" do
    subject(:policy) { described_class.for(:degrade, journal: journal) }

    it "does not raise on a missing capability" do
      expect { policy.resolve(requirer, lacking) }.not_to raise_error
    end

    it "returns the run's degraded set" do
      expect(policy.resolve(requirer, lacking).to_a).to eq(%i[thinking])
    end

    it "journals exactly one degradation record for the missing capability" do
      policy.resolve(requirer, lacking)
      expect(journal.events.size).to eq(1)
      event = journal.events.first
      expect(event).to be_a(Lain::Event::CapabilityDegraded)
      expect(event.capability).to eq(:thinking)
      expect(event.requirer).to eq("FakeRequirer")
      expect(event.provider).to eq("FakeCapabilityProvider")
    end

    it "journals one record per missing capability, none for supported ones" do
      two = FakeRequirer.new(%i[thinking server_tools prompt_caching])
      provider = FakeCapabilityProvider.new(%i[prompt_caching])
      set = policy.resolve(two, provider)
      expect(set.to_a).to eq(%i[server_tools thinking])
      expect(journal.events.map(&:capability)).to contain_exactly(:thinking, :server_tools)
    end

    it "journals exactly one record when #requires yields the capability twice" do
      duplicated = FakeRequirer.new(%i[thinking thinking])
      set = policy.resolve(duplicated, lacking)
      expect(set.to_a).to eq(%i[thinking])
      expect(journal.events.size).to eq(1)
      expect(journal.events.first.capability).to eq(:thinking)
    end

    it "journals nothing and degrades nothing when everything is supported" do
      set = policy.resolve(requirer, full)
      expect(set).to be_empty
      expect(journal.events).to be_empty
    end

    it "defaults to a Null channel that swallows the degradation without a nil check" do
      expect { described_class.for(:degrade).resolve(requirer, lacking) }.not_to raise_error
    end
  end
end
