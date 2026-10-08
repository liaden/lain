# frozen_string_literal: true

RSpec.describe Lain::Tool::Bounds::WalkLimit do
  subject(:limit) { described_class.new(entries: 10, bytes: 1_500) }

  it "defaults to 20,000 entries and 200 MiB" do
    expect(described_class::DEFAULT).to have_attributes(entries: 20_000, bytes: 200 * 1024 * 1024)
  end

  it "says nothing about a walk under both limits, or exactly at them" do
    expect(limit.notice(listed: 10, read_bytes: 1_500)).to be_nil
  end

  it "names the entry limit and how to narrow when the walk listed more" do
    notice = limit.notice(listed: 11, read_bytes: 0)

    expect(notice).to include("10 entries").and include("narrow")
    expect(notice).not_to include("bytes")
  end

  it "names the byte limit when the reads would have gone past it" do
    notice = limit.notice(listed: 3, read_bytes: 2_000)

    expect(notice).to include("1500 bytes").and include("narrow")
    expect(notice).not_to include("entries")
  end

  it "names both limits when both were passed" do
    expect(limit.notice(listed: 11, read_bytes: 2_000)).to include("10 entries").and include("1500 bytes")
  end
end
