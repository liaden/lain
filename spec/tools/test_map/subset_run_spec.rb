# frozen_string_literal: true

require "stringio"
require_relative "../../../tools/test_map/subset_run"

RSpec.describe TestMap::SubsetRun do
  subject(:run) { described_class.new(selection:, commands:, count:, out:, err:) }

  let(:selection_class) { Struct.new(:mode, :specs, :reasons) }
  let(:specs) { %w[spec/a_spec.rb spec/b_spec.rb] }
  let(:reasons) { { "spec/a_spec.rb" => "names Lain::Foo", "spec/b_spec.rb" => "edited" } }
  let(:selection) { selection_class.new(:subset, specs, reasons) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }
  let(:commands) do
    instance_double(Class.new do
      def capture(*, **) = nil
      def stream(*, **) = nil
    end)
  end
  let(:count) { instance_double(Class.new { def verify(_output) = nil }, verify: nil) }

  before do
    allow(commands).to receive_messages(capture: ["ok\n", ok], stream: ["ok\n", ok])
  end

  it "runs compile, then suite:files naming exactly the selected files" do
    expect(run.call).to eq(0)
    expect(commands).to have_received(:capture).with(%w[bundle exec rake compile], env: {}).ordered
    expect(commands).to have_received(:stream)
      .with(%w[bundle exec rake suite:files], env: { "FILES" => "spec/a_spec.rb\nspec/b_spec.rb" }).ordered
  end

  it "prints each selected file with its reason" do
    run.call
    expect(out.string).to include("spec/a_spec.rb", "names Lain::Foo", "spec/b_spec.rb", "edited")
  end

  it "does no work for an empty selection" do
    selection = selection_class.new(:none, [], {})
    status = described_class.new(selection:, commands:, count:, out:, err:).call
    expect(status).to eq(0)
    expect(commands).not_to have_received(:capture)
    expect(commands).not_to have_received(:stream)
  end

  it "fails with the counts when the example count is short" do
    allow(count).to receive(:verify).with("ok\n").and_return("run reported 31 examples, expected 40")
    expect(run.call).to eq(1)
    expect(err.string).to include("31", "40")
  end

  it "fails without running the suite when compile fails" do
    allow(commands).to receive(:capture).with(%w[bundle exec rake compile], env: {}).and_return(["no clang", failed])
    expect(run.call).to eq(1)
    expect(commands).to have_received(:capture).once
    expect(err.string).to include("no clang")
  end

  it "fails when the suite run fails" do
    allow(failed).to receive(:exitstatus).and_return(3)
    allow(commands).to receive(:stream).and_return(["red", failed])
    expect(run.call).to eq(1)
    expect(err.string).to include("suite:files failed with exit 3")
    expect(err.string).not_to include("red")
  end

  it "has the suite output on out before the example count is checked" do
    allow(commands).to receive(:stream) do
      out.puts "waiting for the suite lock"
      ["ok\n", ok]
    end
    seen = nil
    allow(count).to receive(:verify) do
      seen = out.string
      nil
    end
    run.call
    expect(seen).to include("waiting for the suite lock")
  end

  it "fails with the message when the dry run behind the count fails" do
    allow(count).to receive(:verify).and_raise(TestMap::ExampleCount::DryRunFailed, "dry run failed: boom")
    expect(run.call).to eq(1)
    expect(err.string).to include("dry run failed: boom")
  end
end
