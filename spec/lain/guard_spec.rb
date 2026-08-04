# frozen_string_literal: true

RSpec.describe Lain::Guard do
  # The entry point the five live consumers use: a named subclass declaring
  # `attribute`/`validates`, checked from a constructor. Anonymous here because
  # the subject is the mechanism, not any one consumer's rules -- which also
  # exercises the model_name fallback every DSL-built carrier depends on.
  def carrier(&body) = Class.new(described_class, &body)

  it "raises ArgumentError naming the attribute and the validator's message" do
    capacity = carrier do
      attribute :capacity
      validates :capacity, numericality: { only_integer: true, greater_than: 0,
                                           message: "must be a positive Integer, got %<value>s" }
    end

    expect { capacity.check!(capacity: 0) }
      .to raise_error(ArgumentError, "capacity must be a positive Integer, got 0")
  end

  it "joins every error, so one raise reports the whole refusal" do
    partition = carrier do
      attribute :epic_slug
      attribute :stage
      validates :epic_slug, presence: { message: "must name the epic this sign-off belongs to, got nil" }
      validates :stage, presence: { message: "must name the stage it was parked at, got nil" }
    end

    expect { partition.check!(epic_slug: nil, stage: nil) }
      .to raise_error(ArgumentError,
                      "epic_slug must name the epic this sign-off belongs to, got nil, " \
                      "stage must name the stage it was parked at, got nil")
  end

  it "generates a default message for an anonymous carrier, which has no constant name" do
    item = carrier do
      attribute :artifact_digest
      validates :artifact_digest, presence: true
    end

    expect(item.name).to be_nil
    expect { item.check!(artifact_digest: nil) }.to raise_error(ArgumentError, "artifact_digest can't be blank")
  end

  it "passes silently when every rule holds, and returns no carrier to hold on to" do
    item = carrier do
      attribute :artifact_digest
      validates :artifact_digest, presence: true
    end

    expect(item.check!(artifact_digest: "abc")).to be_nil
  end

  it "is its own carrier, which is what makes it the same mechanism a declared guard uses" do
    item = carrier do
      attribute :artifact_digest
      validates :artifact_digest, presence: true
    end

    expect(item.guard_carrier).to be(item)
  end
end
