# frozen_string_literal: true

# The provider a `--dry-run` assembles. It exists so a dry pass wires a REAL
# collaborator into every required keyword instead of a `nil` that travels: the
# `nil` was checked at use ({Lain::Consolidation}'s deleted `require!`), which
# means a mis-wire surfaced far from the wiring, and a fourth nil looked exactly
# like a deliberate dry run. This one is loud at the only moment it could be
# wrong -- when something asks it for a round trip ({Sink::Null}'s duck, with
# the swallow replaced by a refusal, because "reached the model" is a defect
# where "wrote to /dev/null" is not).
RSpec.describe Lain::Provider::Unreachable do
  subject(:provider) { described_class.new }

  let(:request) { Lain::Request.new(model: "m", messages: [], max_tokens: 1) }
  # The capability-negotiation duck Capability::Policy folds over.
  let(:requirer) { Struct.new(:requires).new([:streaming]) }

  it "is a Provider, so it satisfies every seam that types on the duck" do
    expect(provider).to be_a(Lain::Provider)
  end

  describe "#complete" do
    it "raises, naming --dry-run as the reason it was ever constructed" do
      expect { provider.complete(request) }
        .to raise_error(described_class::Reached, /assembled for --dry-run/)
    end

    it "raises for the streaming signature too, so no call shape slips past" do
      expect { provider.complete(request, on_stream_started: -> {}) }
        .to raise_error(described_class::Reached)
    end
  end

  describe "#encode" do
    it "raises: encoding a payload is preparing to send one" do
      expect { provider.encode(request) }
        .to raise_error(described_class::Reached, /assembled for --dry-run/)
    end
  end

  # The two declarations a Provider must answer are ANSWERED rather than raised:
  # Provider#to_s and #inspect read #capabilities, so raising there would make
  # this object unprintable in the very error that named it.
  describe "the honest declarations" do
    it "declares no capabilities at all" do
      expect(provider.capabilities).to eq([])
    end

    it "declares no caching, never another provider's economics by accident" do
      expect(provider.cache_profile).to be(Lain::CacheProfile::NO_CACHING)
    end
  end

  # Answering rather than raising is only half of printable: Provider#to_s
  # projects the capability list, and an EMPTY list prints as nothing, so the
  # inherited projection would put a hole in the report that named it.
  describe "printing" do
    it "says what it is and why it is here, rather than the empty capability list" do
      expect(provider.to_s).to eq("unreachable provider (assembled for --dry-run; no model)")
    end

    it "inspects to more than its own class name" do
      expect(provider.inspect).to include("Unreachable", "assembled for --dry-run")
    end
  end

  # A :strict capability negotiation asks BEFORE anything calls #complete, so the
  # refusal a reader meets first must name the dry run rather than a tactic.
  describe "#require!" do
    it "refuses every capability, naming --dry-run instead of a missing feature" do
      expect { provider.require!(:streaming) }
        .to raise_error(Lain::Provider::Unsupported, /:streaming.*assembled for --dry-run/)
    end

    it "keeps the type Capability::Policy::Strict raises, so only the sentence changed" do
      expect { Lain::Capability::Policy.for(:strict).resolve(requirer, provider) }
        .to raise_error(Lain::Provider::Unsupported)
    end
  end
end
