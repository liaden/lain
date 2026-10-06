# frozen_string_literal: true

RSpec.describe Lain::Grader::TestHarness::Adapter do
  describe ".for" do
    it "builds the rspec adapter by name, with no Gemfile to detect it from" do
      Dir.mktmpdir do |dir|
        expect(described_class.for("rspec").call(dir)).to be_a(described_class::Rspec)
      end
    end

    it "raises naming a preset the probes recognize but have no adapter for" do
      expect { described_class.for("pytest") }.to raise_error(Lain::Error, /pytest.*not implemented/)
    end

    it "raises naming a preset no probe knows" do
      expect { described_class.for("minitest") }.to raise_error(Lain::Error, /test framework minitest/)
    end
  end
end
