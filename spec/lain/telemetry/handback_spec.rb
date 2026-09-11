# frozen_string_literal: true

RSpec.describe Lain::Telemetry::Handback do
  let(:sha) { "b" * 40 }

  it "journals the strategy it merged with, whether it fast-forwarded, and the landed commit" do
    record = described_class.new(worker_key: "w-1", outcome: :merged, ref: "refs/lain/worker/w-1-abc",
                                 strategy: "conflict_style=zdiff3 diff_algorithm=histogram",
                                 fast_forward: true, sha:)

    expect(record.to_journal).to include("strategy" => "conflict_style=zdiff3 diff_algorithm=histogram",
                                         "fast_forward" => true, "sha" => sha)
  end

  # nil is the signal, as it is for `ref`: an anchor-only or refused handback
  # landed nothing, and a record that named a commit there would be a lie.
  it "names no strategy, no fast-forward and no commit by default" do
    record = described_class.new(worker_key: "w-1", outcome: :declined)

    expect([record.strategy, record.fast_forward, record.sha]).to eq([nil, false, nil])
  end

  it "refuses a fast_forward that is not exactly true or false" do
    ["yes", nil, 1].each do |value|
      expect { described_class.new(worker_key: "w-1", outcome: :merged, fast_forward: value) }
        .to raise_error(ArgumentError, /fast_forward/)
    end
  end

  it "is deeply frozen, even from unfrozen strings" do
    record = described_class.new(worker_key: +"w-1", outcome: :merged, ref: +"refs/lain/worker/w",
                                 strategy: +"conflict_style=zdiff3 diff_algorithm=histogram", sha: +sha)

    expect(record).to be_deeply_frozen
  end

  it "still refuses an outcome no handback can reach" do
    expect { described_class.new(worker_key: "w-1", outcome: :probably_fine) }
      .to raise_error(ArgumentError, /outcome/)
  end
end
