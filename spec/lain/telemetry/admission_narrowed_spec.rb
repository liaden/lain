# frozen_string_literal: true

RSpec.describe Lain::Telemetry::AdmissionNarrowed do
  subject(:record) do
    described_class.new(endpoint: "https://ollama.com:443", from_width: 3, to_width: 1,
                        max_concurrent: 1, active: 1, queue_limit: 10, queued: 10)
  end

  it "carries the endpoint, the old and new widths, and the rate-limit header values" do
    expect(record).to have_attributes(endpoint: "https://ollama.com:443", from_width: 3, to_width: 1,
                                      max_concurrent: 1, active: 1, queue_limit: 10, queued: 10)
  end

  it "journals under its own type with every field" do
    expect(record.to_journal).to include(
      "type" => "admission_narrowed", "endpoint" => "https://ollama.com:443", "from_width" => 3,
      "to_width" => 1, "max_concurrent" => 1, "active" => 1, "queue_limit" => 10, "queued" => 10
    )
  end
end
