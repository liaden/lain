# frozen_string_literal: true

RSpec.describe Lain::Bench::Journals do
  let(:state) { instance_double(Lain::Paths, state_home: "/s") }
  let(:clock) { class_double(Time, now: Time.utc(2026, 10, 27, 10, 11, 12)) }

  it "stamps the path under the state home with the time and pid" do
    path = described_class.stamped(state, "oracle-calibration", ext: ".ndjson", clock:, pid: 42)

    expect(path).to eq("/s/bench/oracle-calibration-20261027T101112-42.ndjson")
  end

  it "leaves a directory path with no extension" do
    expect(described_class.stamped(state, "judge-scale", clock:, pid: 42))
      .to eq("/s/bench/judge-scale-20261027T101112-42")
  end

  it "uses the real clock and pid by default" do
    expect(described_class.stamped(state, "x")).to match(%r{\A/s/bench/x-\d{8}T\d{6}-#{Process.pid}\z})
  end
end
