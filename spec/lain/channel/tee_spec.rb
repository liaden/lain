# frozen_string_literal: true

RSpec.describe Lain::Channel::Tee do
  let(:sink) { [] }

  it "mirrors a pushed event into the sink and keeps it on the channel" do
    tee = described_class.new(sink)

    tee.push(:event)

    expect(sink).to eq([:event])
    expect(tee.drain).to eq([:event])
  end

  it "mirrors an event appended with <<" do
    tee = described_class.new(sink)

    tee << :event

    expect(sink).to eq([:event])
    expect(tee.drain).to eq([:event])
  end

  it "mirrors only the events the predicate accepts, and still channels them all" do
    tee = described_class.new(sink, only: ->(event) { event == :keep })

    tee << :keep
    tee << :skip

    expect(sink).to eq([:keep])
    expect(tee.drain).to eq(%i[keep skip])
  end

  it "answers the channel from push" do
    tee = described_class.new(sink)

    expect(tee.push(:event)).to equal(tee)
  end
end
