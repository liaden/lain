# frozen_string_literal: true

RSpec.describe Lain::Agent::FixedSize do
  subject(:fixed) { described_class.new }

  let(:toolset) { Lain::Toolset.new([]) }
  let(:other_toolset) { Lain::Toolset.new([]) }
  let(:system_text) { +"you are a helper" }

  def measurements_during
    count = 0
    allow(Lain::Canonical).to receive(:dump).and_wrap_original do |original, *args|
      count += 1 if args.first.is_a?(Array) && args.first.first.is_a?(String)
      original.call(*args)
    end
    yield
    count
  end

  it "measures the canonical bytes of the system and the tool schemas" do
    expect(fixed.bytes(system: system_text, toolset:))
      .to eq(Lain::Canonical.dump([system_text, toolset.to_schema]).bytesize)
  end

  it "measures once for the same system and toolset objects" do
    count = measurements_during { 3.times { fixed.bytes(system: system_text, toolset:) } }

    expect(count).to eq(1)
  end

  it "measures again, to a different size, for a different system object" do
    first = fixed.bytes(system: system_text, toolset:)

    expect(fixed.bytes(system: +"a much longer system prompt than before", toolset:)).to be > first
  end

  it "measures again for a different toolset object" do
    count = measurements_during do
      fixed.bytes(system: system_text, toolset:)
      fixed.bytes(system: system_text, toolset: other_toolset)
    end

    expect(count).to eq(2)
  end

  # Pinned: identity, not equality, because an equal String can still be a new
  # prompt after a swap and comparing bytes would cost what the memo saves.
  it "measures again for an equal but not identical system" do
    count = measurements_during do
      fixed.bytes(system: system_text, toolset:)
      fixed.bytes(system: system_text.dup, toolset:)
    end

    expect(count).to eq(2)
  end
end
