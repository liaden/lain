# frozen_string_literal: true

RSpec.describe Lain::Confine::Request do
  let(:ruling) { Lain::Approval::Escalation::Ruling.allow(rung: "judge", because: "approved") }

  it "requires the call's id, which every record the sandbox journals carries" do
    expect { described_class.new(ruling:, executables: [], cwd: "/p", root: "/p") }
      .to raise_error(ArgumentError, /tool_use_id/)
  end

  it "is Ractor-shareable, and leaves the strings it was built from unfrozen" do
    cwd = +"/p"
    request = described_class.new(ruling:, executables: [], cwd:, root: "/p", tool_use_id: +"toolu_1")

    expect([Ractor.shareable?(request), cwd.frozen?]).to eq([true, false])
  end

  it "has an unruled request that answers allow? false and names no rule" do
    expect([described_class::NONE.ruling.allow?, described_class::NONE.ruling.rule]).to eq([false, nil])
  end
end
