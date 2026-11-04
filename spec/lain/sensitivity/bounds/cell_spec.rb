# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Bounds::Cell do
  let(:base) { Lain::Sensitivity::Bounds.of(reads: ["/p"], writes: ["/p"]) }
  let(:cell) { described_class.new(base) }

  it "holds the bounds it was given" do
    expect(cell.current).to eq(base)
  end

  it "stores what the block makes of the current bounds, and answers it" do
    held = cell.swap { _1.with_child("/w/children/a") }

    expect([cell.current, held]).to eq([base.with_child("/w/children/a")] * 2)
  end

  it "yields the bounds it holds at the moment of the swap" do
    cell.swap { _1.with_child("/w/children/a") }
    seen = nil
    cell.swap { seen = _1 }

    expect(seen.read?("/w/children/a/Cargo.toml")).to be(true)
  end

  it "holds a frozen Bounds at every read" do
    cell.swap { _1.with_child("/w/children/a") }

    expect(cell.current).to be_frozen
  end

  it "loses no lease when siblings swap from many threads" do
    dirs = Array.new(40) { "/w/children/#{_1}" }
    dirs.map { |dir| Thread.new { cell.swap { |bounds| bounds.with_child(dir) } } }.each(&:join)

    expect(dirs).to all(satisfy { cell.current.read?(File.join(_1, "x")) })
  end

  describe ".of" do
    it "holds a cell it is given as it is, so the spawner and the policy share it" do
      expect(described_class.of(cell)).to be(cell)
    end

    it "wraps bounds in a cell of their own" do
      expect(described_class.of(base)).to have_attributes(current: base)
    end
  end
end
