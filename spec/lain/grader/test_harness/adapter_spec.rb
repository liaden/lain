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

  # rspec's `messages` carries its notes beside its load errors, so only the
  # summary's count says how many errors there were.
  describe "Rspec#parse" do
    def parsed(count, messages)
      document = JSON.generate("examples" => [], "messages" => messages,
                               "summary" => { "errors_outside_of_examples_count" => count })
      described_class::Rspec.new.parse(document, 1)
    end

    let(:load_error) do
      "An error occurred while loading ./spec/x_spec.rb.\nFailure/Error: X.go\n\nNameError:\n  uninitialized constant X"
    end

    it "counts a load error once, not the note that no examples were found beside it" do
      expect(parsed(1, [load_error, "No examples found."]).fetch(:errors)).to eq([load_error])
    end

    it "keeps every load error the summary counts" do
      expect(parsed(2, [load_error, load_error, "No examples found."]).fetch(:errors).size).to eq(2)
    end

    it "quotes an after(:suite) error, not the note on the filter in force that comes before it" do
      hook_error = "\nAn error occurred in an `after(:suite)` hook.\nFailure/Error: raise 'broke'\n\nRuntimeError:"

      expect(parsed(1, ["Run options: exclude {slow: true}", hook_error]).fetch(:errors)).to eq([hook_error])
    end

    it "counts an error whose message rspec coloured" do
      coloured = "\e[31mAn error occurred while loading ./spec/x_spec.rb.\e[0m\n\e[31mFailure/Error: X.go\e[0m"

      expect(parsed(1, [coloured, "No examples found."]).fetch(:errors)).to eq([coloured])
    end

    it "labels each counted error rspec gave no message for, beside those it did describe" do
      expect(parsed(2, [load_error, "No examples found."]).fetch(:errors))
        .to eq([load_error, "error outside of examples #2"])
    end

    it "labels each counted error when rspec gave no message for it" do
      expect(parsed(1, []).fetch(:errors)).to eq(["error outside of examples #1"])
    end
  end
end
