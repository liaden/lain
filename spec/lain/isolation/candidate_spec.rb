# frozen_string_literal: true

RSpec.describe Lain::Isolation::Candidate do
  it "is shareable across Ractors even when built from mutable strings" do
    expect(Ractor.shareable?(described_class.new(sha: +"abc", path: +"/tmp/x"))).to be(true)
  end
end
