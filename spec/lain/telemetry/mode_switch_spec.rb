# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ModeSwitch do
  subject(:record) do
    described_class.new(from_scope: :checkout, to_scope: :plan, from_approval: :ask, to_approval: :auto,
                        from_layers: [:a, "b"], to_layers: [], surface: :cli)
  end

  it "prints its journal line, every name as a String" do
    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"mode_switch","from_scope":"checkout","to_scope":"plan","from_approval":"ask",' \
      '"to_approval":"auto","from_layers":["a","b"],"to_layers":[],"surface":"cli"}'
    )
  end

  it "is shareable" do
    expect(record).to be_deeply_frozen
  end

  it "refuses a missing name and a layer list that is not a list" do
    expect do
      described_class.new(from_scope: nil, to_scope: :plan, from_approval: :ask, to_approval: :auto,
                          from_layers: [], to_layers: [], surface: :cli)
    end.to raise_error(ArgumentError, /from_scope must be named/)
    expect do
      described_class.new(from_scope: :checkout, to_scope: :plan, from_approval: :ask, to_approval: :auto,
                          from_layers: nil, to_layers: [], surface: :cli)
    end.to raise_error(ArgumentError, /from_layers must be a list of layer names/)
  end

  it "interns every name and layer" do
    build = lambda do
      described_class.new(from_scope: +"a", to_scope: +"b", from_approval: +"c", to_approval: +"d",
                          from_layers: [+"e"], to_layers: [+"f"], surface: +"g")
    end
    first = build.call
    second = build.call

    %i[from_scope to_scope from_approval to_approval surface].each do |field|
      expect(first.public_send(field)).to equal(second.public_send(field)), field.to_s
    end
    expect(first.from_layers.first).to equal(second.from_layers.first)
    expect(first.to_layers.first).to equal(second.to_layers.first)
  end
end
