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

  it "journals as a search_redacted record, apart from the source_masked a resume folds into a mask" do
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

  describe "journal bytes" do
    it "journals counts as Integers, including ones given as numeric strings" do
      expect(JSON.generate(event.to_journal)).to eq(
        '{"type":"search_redacted","tool_use_id":"tu_2","path":"/tmp/config.yml","regions":3,"released":1}'
      )
      expect(described_class.new(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: "3", released: "1"))
        .to eq(event)
    end

    it "interns the call id and the path across equal records" do
      first = described_class.new(tool_use_id: +"tu_2", path: +"/tmp/x", regions: 1, released: 0)
      second = described_class.new(tool_use_id: +"tu_2", path: +"/tmp/x", regions: 1, released: 0)
      expect(first.tool_use_id).to equal(second.tool_use_id)
      expect(first.path).to equal(second.path)
    end

    it "refuses a keyword it does not declare" do
      expect { described_class.new(tool_use_id: "t", path: "/p", regions: 1, released: 0, stray: 1) }
        .to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses path given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect do
          described_class.new(tool_use_id: "t", path: blank, regions: 1,
                              released: 0)
        end.to raise_error(ArgumentError, /path must name the redacted path/)
      end
    end
  end
end
