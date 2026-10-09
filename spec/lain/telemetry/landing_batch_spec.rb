# frozen_string_literal: true

RSpec.describe Lain::Telemetry::LandingBatch do
  def build(**overrides)
    described_class.new(branch: "main", desk: :parent, verifier: "rake spec", worker_keys: %w[w-1 w-2],
                        landed: %w[w-1 w-2], ejected: [], declined: [], verifies: 1, rebuilds: 0,
                        verify_wall_s: 1.5, queue_wait_s: { "w-1" => 0.2, "w-2" => 0.4 },
                        outcome: :landed, **overrides)
  end

  it "journals under its own short name, deeply frozen and shareable" do
    record = build(worker_keys: [+"w-1", +"w-2"], branch: +"main")

    expect(record.to_journal).to include("type" => "landing_batch", "worker_keys" => %w[w-1 w-2],
                                         "desk" => :parent, "outcome" => :landed)
    expect(record).to be_deeply_frozen
    expect(Ractor.shareable?(record)).to be(true)
  end

  it "answers landing_batch to no other Journalable" do
    others = ObjectSpace.each_object(Class).select { |klass| klass.include?(Lain::Telemetry::Journalable) }
                        .reject { |klass| klass == described_class }
                        .select { |klass| klass.name.split("::").last.underscore == "landing_batch" }

    expect(others).to be_empty
  end

  it "refuses an outcome outside landed, partial and none, naming the field" do
    expect { build(outcome: "maybe") }.to raise_error(ArgumentError, %r{outcome.*landed/partial/none})
  end

  it "refuses a desk that is neither parent nor candidate" do
    expect { build(desk: :elsewhere) }.to raise_error(ArgumentError, /desk/)
  end

  it "refuses a record that names no branch" do
    expect { build(branch: nil) }.to raise_error(ArgumentError, /branch/)
  end
end
