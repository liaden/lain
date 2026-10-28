# frozen_string_literal: true

require "json"

# Written by {Bench::CLI::RunRecorder} into a recorded run's own file before it
# is set aside, so the file says why it holds no session. See
# `spec/lain/bench/cli/run_recorder_spec.rb` for the write path; this pins the
# record's own shape.
RSpec.describe Lain::Telemetry::RecordingFailed do
  subject(:event) { described_class.new(error_class: "Lain::Provider::Ollama::APIError", message: "connection refused") }

  it "is a frozen, Ractor-shareable value with structural equality" do
    twin = described_class.new(error_class: +"Lain::Provider::Ollama::APIError", message: +"connection refused")

    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
  end

  it "tags itself recording_failed and carries the error's class and message, nothing more" do
    expect(JSON.parse(JSON.generate(event.to_journal)))
      .to eq("type" => "recording_failed", "error_class" => "Lain::Provider::Ollama::APIError",
             "message" => "connection refused")
  end

  it "is read off the error itself, by class name" do
    expect(described_class.of(Interrupt.new)).to eq(described_class.new(error_class: "Interrupt", message: "Interrupt"))
  end

  it "refuses a record that names no error" do
    expect { described_class.new(error_class: nil, message: "boom") }
      .to raise_error(ArgumentError, /error_class must name what stopped the run/)
  end

  describe "journal bytes" do
    it "journals the class name then the message" do
      expect(JSON.generate(event.to_journal)).to eq(
        '{"type":"recording_failed","error_class":"Lain::Provider::Ollama::APIError","message":"connection refused"}'
      )
    end

    it "journals a nil message as the empty string" do
      expect(JSON.generate(described_class.new(error_class: "X", message: nil).to_journal)).to eq(
        '{"type":"recording_failed","error_class":"X","message":""}'
      )
    end

    it "refuses a keyword it does not declare" do
      expect { described_class.new(error_class: "X", message: "m", stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses error_class given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          described_class.new(error_class: blank,
                              message: "m")
        end.to raise_error(ArgumentError, /error_class must name what stopped the run/)
      end
    end
  end
end
