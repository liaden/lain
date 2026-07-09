# frozen_string_literal: true

RSpec.describe Lain do
  it "has a version number" do
    expect(Lain::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  # Proves the magnus FFI boundary is wired and `rake compile` produced a loadable
  # extension. Until the Timeline lands in Rust, this is the only thing crossing it.
  describe ".hello" do
    it "round-trips a string through the Rust extension" do
      expect(described_class.hello("lain")).to eq("Hello from Rust, lain!")
    end
  end
end
