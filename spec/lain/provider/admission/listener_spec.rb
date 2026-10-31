# frozen_string_literal: true

require "async"

RSpec.describe Lain::Provider::Admission::Listener do
  let(:listener) { Object.new }

  it "answers the Null listener when none is set" do
    expect(described_class.current).to be(described_class::Null)
  end

  it "has a Null listener that does nothing on any hook" do
    null = described_class::Null

    expect([null.entering, null.admitted, null.abandoned, null.released]).to eq([nil, nil, nil, nil])
  end

  it "sets the listener for the block and restores the one before after it" do
    outer = Object.new
    seen = described_class.with(outer) do
      [described_class.with(listener) { described_class.current }, described_class.current]
    end

    expect([seen, described_class.current]).to eq([[listener, outer], described_class::Null])
  end

  it "restores the one before when the block raises" do
    expect { described_class.with(listener) { raise IOError, "boom" } }.to raise_error(IOError)

    expect(described_class.current).to be(described_class::Null)
  end

  it "answers the block's value" do
    expect(described_class.with(listener) { :value }).to eq(:value)
  end

  it "reaches a task the block spawns, and no task beside it" do
    seen = Sync do
      beside = Async do
        Async::Task.current.yield
        described_class.current
      end
      inside = described_class.with(listener) { Async { described_class.current }.wait }
      [inside, beside.wait]
    end

    expect(seen).to eq([listener, described_class::Null])
  end
end
