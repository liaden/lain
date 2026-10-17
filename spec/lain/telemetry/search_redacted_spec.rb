# frozen_string_literal: true

require "json"

# What a search's row masking leaves in the Journal.
RSpec.describe Lain::Telemetry::SearchRedacted do
  subject(:event) { described_class.new(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: 3, released: 1) }

  it "is a deeply frozen value carrying the call, the path and the region counts" do
    expect(event).to have_attributes(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: 3, released: 1)
    expect(event).to be_deeply_frozen
    expect(described_class.new(tool_use_id: +"tu_2", path: +"/tmp/x", regions: 1, released: 0)).to be_deeply_frozen
  end

  it "journals as a search_redacted record, apart from the read_redacted a resume folds into a mask" do
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
      "type" => "search_redacted", "tool_use_id" => "tu_2", "path" => "/tmp/config.yml", "regions" => 3,
      "released" => 1
    )
  end

  it "refuses a record that names no path" do
    expect { described_class.new(tool_use_id: "tu_2", path: nil, regions: 1, released: 0) }
      .to raise_error(ArgumentError, /path/)
  end

  it "refuses counts that are not non-negative Integers" do
    expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 3.7, released: 0) }
      .to raise_error(ArgumentError, /regions/)
    expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 1, released: -1) }
      .to raise_error(ArgumentError, /released/)
  end

  it "refuses more released than found" do
    expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 1, released: 2) }
      .to raise_error(ArgumentError, /released must be <= regions/)
  end
end
