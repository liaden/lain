# frozen_string_literal: true

require_relative "../../../tools/test_map/example_count"

RSpec.describe TestMap::ExampleCount do
  subject(:count) { described_class.new(files:, env:, commands:) }

  let(:files) { %w[spec/a_spec.rb spec/b_spec.rb] }
  let(:env) { { "LAIN_SLOW" => "1" } }
  let(:status) { instance_double(Process::Status, success?: true) }
  let(:dry_output) { "Run options: ...\n\n40 examples, 0 failures\n" }
  let(:commands) { instance_double(Class.new { def capture(*, **) = nil }) }

  before { allow(commands).to receive(:capture).and_return([dry_output, status]) }

  describe "#expected" do
    it "reads the example total of a dry run over the files with the run's environment" do
      expect(count.expected).to eq(40)
      expect(commands).to have_received(:capture)
        .with(%w[bundle exec rspec --dry-run spec/a_spec.rb spec/b_spec.rb], env:)
    end

    it "raises when the dry run fails" do
      allow(commands).to receive(:capture).and_return(["boom", instance_double(Process::Status, success?: false)])
      expect { count.expected }.to raise_error(TestMap::ExampleCount::DryRunFailed, /boom/)
    end

    it "raises when the dry run prints no total" do
      allow(commands).to receive(:capture).and_return(["nothing useful", status])
      expect { count.expected }.to raise_error(TestMap::ExampleCount::DryRunFailed, /no example count/)
    end
  end

  describe "#verify" do
    it "names both numbers when the run reported fewer examples" do
      expect(count.verify("31 examples, 0 failures\n")).to match(/40.*31|31.*40/)
    end

    it "returns nil when the totals match" do
      expect(count.verify("40 examples, 0 failures\n")).to be_nil
    end

    it "returns nil when the run reported more examples than the dry run" do
      expect(count.verify("41 examples, 0 failures\n")).to be_nil
    end

    it "reads the final total after per-worker lines" do
      output = "20 examples, 0 failures\n20 examples, 0 failures\n\n40 examples, 0 failures\nTook 3 seconds\n"
      expect(count.verify(output)).to be_nil
    end

    it "reports a run that printed no total" do
      expect(count.verify("worker died")).to include("no example total")
    end
  end
end
