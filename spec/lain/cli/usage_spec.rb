# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Usage do
  let(:fixtures) { File.expand_path("../../fixtures/usage", __dir__) }
  let(:sink) { StringIO.new }

  def rows
    sink.string.lines.drop(1).take_while { |line| !line.strip.empty? }.map(&:split)
  end

  it "prints input and output tokens per command and role, as the committed figures say" do
    status = described_class.new(selector: File.join(fixtures, "round3_slice.ndjson"), sink:).run
    expected = JSON.parse(File.read(File.join(fixtures, "round3_slice.expected.json")))
                   .map { |row| row.values_at("command", "role", "input_tokens", "output_tokens").map(&:to_s) }

    expect([status, rows]).to eq([0, expected])
  end

  it "heads the table with its columns" do
    described_class.new(selector: File.join(fixtures, "round3_slice.ndjson"), sink:).run

    expect(sink.string.lines.first.split).to eq(%w[COMMAND ROLE INPUT OUTPUT])
  end

  it "says under the table that the judge's spend is not split by command" do
    described_class.new(selector: File.join(fixtures, "round3_slice.ndjson"), sink:).run

    expect(sink.string.lines.last).to match(/auto_approver.*not split by command/)
  end

  it "says nothing of the judge when the session had none" do
    quiet = File.join(Dir.mktmpdir, "quiet.ndjson")
    File.write(quiet, File.readlines(File.join(fixtures, "round3_slice.ndjson")).grep_v(/auto_approver/).join)
    described_class.new(selector: quiet, sink:).run

    expect(sink.string).not_to include("auto_approver")
  end

  it "refuses a selector naming no session" do
    expect { described_class.new(selector: "no-such-session", sink:, paths: Lain::Paths.new(env: {})).run }
      .to raise_error(Lain::CLI::SessionFile::SessionNotFound)
  end
end
