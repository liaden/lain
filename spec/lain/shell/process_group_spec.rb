# frozen_string_literal: true

RSpec.describe Lain::Shell::ProcessGroup do
  let(:now) { [0.0] }
  let(:clock) { -> { now.first } }
  let(:sent) { [] }
  let(:stubborn) do
    lambda do |name, target|
      sent << [name, target] unless name == 0
      nil
    end
  end

  def group(signal:)
    described_class.new(signal:, clock:, grace: 1.0, poll: 0.25, sleeper: ->(secs) { now[0] += secs })
  end

  it "sends TERM, then KILL when the group lives past the deadline" do
    group(signal: stubborn).terminate(42)

    expect(sent).to eq([["TERM", -42], ["KILL", -42]])
  end

  it "sends no KILL when the group ends after TERM" do
    gone = false
    signal = lambda do |name, target|
      raise Errno::ESRCH if gone

      sent << [name, target] unless name == 0
      gone = true if name == "TERM"
    end

    group(signal:).terminate(42)

    expect(sent).to eq([["TERM", -42]])
  end

  it "calls the reaper while it waits" do
    reaped = []

    group(signal: stubborn).terminate(42, reaper: -> { reaped << true })

    expect(reaped).not_to be_empty
  end
end
