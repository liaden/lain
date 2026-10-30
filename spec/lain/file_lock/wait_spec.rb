# frozen_string_literal: true

# One poll loop for every lock wait, measured against a fake clock its sleeper advances.
RSpec.describe Lain::FileLock::Wait do
  let(:now) { [0.0] }
  let(:slept) { [] }
  let(:told) { [] }
  let(:notice) { -> { told << now.first } }

  def wait
    described_class.new(patience: 0.5, interval: 0.25, clock: -> { now.first },
                        sleeper: ->(seconds) { (slept << seconds) && now[0] += seconds })
  end

  def free_at(at) = -> { now.first >= at }

  it "answers true at once when the first try succeeds, without sleeping or telling" do
    expect(wait.succeeded?(notice) { true }).to be(true)
    expect([slept, told]).to eq([[], []])
  end

  it "retries at its interval until the try succeeds" do
    expect(wait.succeeded?(notice, &free_at(1.0))).to be(true)
    expect(slept).to eq([0.25] * 4)
  end

  it "tells the notice once, after the patience has run out, and keeps waiting" do
    expect(wait.succeeded?(notice, &free_at(2.0))).to be(true)
    expect(told).to eq([0.5])
  end

  it "tells nothing to a wait that ends inside the patience" do
    wait.succeeded?(notice, &free_at(0.25))

    expect(told).to be_empty
  end

  it "answers false once the deadline passes, sleeping no further than it" do
    expect(wait.succeeded?(notice, deadline: 1.1) { false }).to be(false)
    expect(slept.take(4)).to eq([0.25] * 4)
    expect([slept.last, now.first]).to match([be_within(1e-9).of(0.1), be_within(1e-9).of(1.1)])
    expect(told).to eq([0.5])
  end

  it "tells nothing when the deadline comes before the patience" do
    expect(wait.succeeded?(notice, deadline: 0.4) { false }).to be(false)
    expect(told).to be_empty
  end

  it "answers true for a try that succeeds just before the deadline" do
    expect(wait.succeeded?(notice, deadline: 1.0, &free_at(0.75))).to be(true)
  end

  it "waits without end when no deadline is given" do
    expect(wait.succeeded?(notice, &free_at(1_000.0))).to be(true)
    expect(told.size).to eq(1)
  end

  it "polls with the real clock and Kernel#sleep by default" do
    tries = 0

    expect(described_class.new(patience: 5, interval: 0.001).succeeded?(-> {}) { (tries += 1) == 3 }).to be(true)
  end
end
