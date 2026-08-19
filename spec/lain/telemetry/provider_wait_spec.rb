# frozen_string_literal: true

# T3: the record a caller queued behind {Lain::Provider::Admission}'s width
# leaves in the Journal. The DECORATOR that emits it is spec'd at its own mirror
# path, `spec/lain/provider/admission/journal_spec.rb`; what is asserted here is
# the VALUE -- its closed `kind` enum, the guard that keeps a refusal from
# carrying a wait it never completed, and the `resolution_seconds` that travels
# beside every `waited_seconds`.
RSpec.describe Lain::Telemetry::ProviderWait do
  subject(:record) do
    described_class.new(kind: :waited, endpoint: "http://localhost:11434",
                        waited_seconds: 0.25, resolution_seconds: 0.05, in_flight: 1)
  end

  it "carries the kind, the resolved endpoint, the wait, its resolution, and how many were inside" do
    expect(record).to have_attributes(kind: :waited, endpoint: "http://localhost:11434",
                                      waited_seconds: 0.25, resolution_seconds: 0.05, in_flight: 1)
  end

  it "journals under a type a reader can discriminate without inspecting its shape" do
    expect(record.journal_type).to eq("provider_wait")
    expect(record.to_journal).to include("type" => "provider_wait", "endpoint" => "http://localhost:11434")
  end

  # The whole point of carrying the resolution: a reader that sees 0.05 next to
  # a 0.05 resolution knows it has "queued at all", not "queued for 50ms".
  it "reports the wait alongside the resolution it was measured at, never as a bare measurement" do
    expect(record.to_journal).to include("waited_seconds" => 0.25, "resolution_seconds" => 0.05)
  end

  it "rounds the wait to milliseconds, because more digits than the resolution would be false precision" do
    noisy = described_class.new(kind: :waited, endpoint: "e", waited_seconds: 0.050123456789,
                                resolution_seconds: 0.05, in_flight: 1)

    expect(noisy.waited_seconds).to eq(0.05)
  end

  describe "a refusal" do
    subject(:refusal) do
      described_class.new(kind: :refused, endpoint: "http://localhost:11434",
                          resolution_seconds: 0.05, in_flight: 1)
    end

    it "names the refusal and reports no completed wait" do
      expect(refusal.kind).to eq(:refused)
      expect(refusal.waited_seconds).to be_nil
    end

    it "refuses to be built with a wait it never completed" do
      expect do
        described_class.new(kind: :refused, endpoint: "e", waited_seconds: 1.0, resolution_seconds: 0.05,
                            in_flight: 1)
      end.to raise_error(ArgumentError, /waited_seconds must be absent/)
    end
  end

  it "refuses an admission that says it waited without saying how long" do
    expect do
      described_class.new(kind: :waited, endpoint: "e", resolution_seconds: 0.05, in_flight: 1)
    end.to raise_error(ArgumentError, /waited_seconds must name/)
  end

  it "refuses a kind outside the closed enum" do
    expect do
      described_class.new(kind: :queued, endpoint: "e", waited_seconds: 1.0, resolution_seconds: 0.05, in_flight: 1)
    end.to raise_error(ArgumentError, %r{kind must be one of waited/refused})
  end

  it "refuses a record that cannot name the endpoint it queued for" do
    expect do
      described_class.new(kind: :waited, endpoint: nil, waited_seconds: 1.0, resolution_seconds: 0.05, in_flight: 1)
    end.to raise_error(ArgumentError, /endpoint must name/)
  end

  # Fix 2. The field carrying the record's whole honesty argument was the one
  # field nothing validated: a nil arrived as 0.0, which is a record asserting the
  # wait is EXACT -- precisely the misreading `resolution_seconds` exists to
  # prevent. Zero is refused for the same reason, not merely because it is falsy.
  describe "the resolution it must carry" do
    it "refuses a record that does not say what resolution its wait was read at" do
      expect do
        described_class.new(kind: :waited, endpoint: "e", waited_seconds: 0.25, resolution_seconds: nil,
                            in_flight: 1)
      end.to raise_error(ArgumentError, /resolution_seconds must name/)
    end

    it "refuses a zero resolution, which would claim the wait is exact" do
      expect do
        described_class.new(kind: :waited, endpoint: "e", waited_seconds: 0.25, resolution_seconds: 0.0,
                            in_flight: 1)
      end.to raise_error(ArgumentError, /resolution_seconds must be positive/)
    end

    it "refuses a negative resolution" do
      expect do
        described_class.new(kind: :refused, endpoint: "e", resolution_seconds: -0.05, in_flight: 1)
      end.to raise_error(ArgumentError, /resolution_seconds must be positive/)
    end
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(kind: :waited, endpoint: "http://localhost:11434",
                               waited_seconds: 0.25, resolution_seconds: 0.05, in_flight: 1)

    expect(record).to eq(twin)
    expect(record.hash).to eq(twin.hash)
    expect(record).to be_deeply_frozen
  end

  it "is Ractor-shareable even when built from a mutable String endpoint" do
    mutable = described_class.new(kind: :waited, endpoint: +"http://localhost:11434",
                                  waited_seconds: 0.25, resolution_seconds: 0.05, in_flight: 1)

    expect(Ractor.shareable?(mutable)).to be(true)
  end
end
