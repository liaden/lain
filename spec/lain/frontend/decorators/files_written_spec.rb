# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::FilesWritten do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def record(paths, role: "lain") = Lain::Telemetry::FilesWritten.new(role:, paths:)
  def rendered(*args, **kwargs) = described_class.new(record(*args, **kwargs)).render(theme)

  it "names the one file written" do
    expect(rendered(["lib/a.rb"])).to eq("wrote lib/a.rb")
  end

  it "names the first 3 paths and counts the rest" do
    paths = %w[lib/a.rb lib/b.rb lib/c.rb spec/a_spec.rb spec/b_spec.rb]

    expect(rendered(paths)).to eq("wrote 5 files: lib/a.rb, lib/b.rb, lib/c.rb (+2 more)")
  end

  it "lists 3 paths without a remainder" do
    expect(rendered(%w[a b c])).to eq("wrote 3 files: a, b, c")
  end

  it "starts a child's line with its role" do
    expect(rendered(["src/main.rs"], role: "dev")).to eq("dev wrote src/main.rs")
  end

  it "is one stamped, whole line" do
    decorator = described_class.new(record(["a"]))

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, true])
  end

  it "is what the frontend renders the record with" do
    expect(Lain::Frontend::Decorators.for(record(["a"]))).to be_a(described_class)
  end
end
