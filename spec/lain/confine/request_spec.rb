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

  it "carries no grants unless handed some, and makes the ones it is handed shareable" do
    grant = Lain::Shell::Executable.unresolved(+"ruby")
    granted = described_class.new(ruling:, executables: [], cwd: "/p", root: "/p", tool_use_id: "t", grants: [grant])

    expect(described_class.new(ruling:, executables: [], cwd: "/p", root: "/p", tool_use_id: "t").grants).to eq([])
    expect([granted.grants.map(&:name), Ractor.shareable?(granted)]).to eq([["ruby"], true])
  end

  it "has an unruled request that answers allow? false and names no rule" do
    expect([described_class::NONE.ruling.allow?, described_class::NONE.ruling.rule]).to eq([false, nil])
  end
end
