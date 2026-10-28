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

  describe "settled record" do
    it "journals byte for byte with every field set" do
      record = described_class.new(endpoint: "https://ollama.com:443",
                                   from_width: 3,
                                   to_width: 1,
                                   max_concurrent: 1,
                                   active: 2,
                                   queue_limit: 10,
                                   queued: 9)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"admission_narrowed","endpoint":"https://ollama.com:443","from_width":3,' \
        '"to_width":1,"max_concurrent":1,"active":2,"queue_limit":10,"queued":9}'
      )
    end

    it "journals byte for byte with optional fields at their defaults (nil)" do
      record = described_class.new(endpoint: "https://ollama.com:443",
                                   from_width: 3,
                                   to_width: 1,
                                   max_concurrent: nil,
                                   active: nil,
                                   queue_limit: nil,
                                   queued: nil)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"admission_narrowed","endpoint":"https://ollama.com:443","from_width":3,' \
        '"to_width":1,"max_concurrent":null,"active":null,"queue_limit":null,"queued":null}'
      )
    end

    it "is deeply frozen when built from mutable input" do
      given = {
        endpoint: "https://ollama.com:443",
        from_width: 3,
        to_width: 1,
        max_concurrent: 1,
        active: 2,
        queue_limit: 10,
        queued: 9
      }
      mutable = given.transform_values { |value| value.is_a?(String) ? value.dup : value }
      expect(described_class.new(**mutable)).to be_deeply_frozen
    end

    it "refuses a missing endpoint, naming it" do
      given = {
        endpoint: "https://ollama.com:443",
        from_width: 3,
        to_width: 1,
        max_concurrent: 1,
        active: 2,
        queue_limit: 10,
        queued: 9
      }
      expect { described_class.new(**given.except(:endpoint)) }.to raise_error(ArgumentError, /endpoint/)
    end

    it "interns endpoint" do
      first = described_class.new(endpoint: +"v", from_width: 3, to_width: 1, max_concurrent: nil, active: nil,
                                  queue_limit: nil, queued: nil)
      second = described_class.new(endpoint: +"v", from_width: 3, to_width: 1, max_concurrent: nil, active: nil,
                                   queue_limit: nil, queued: nil)
      expect(first.endpoint).to equal(second.endpoint)
    end
  end
end
