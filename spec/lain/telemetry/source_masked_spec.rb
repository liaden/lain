# frozen_string_literal: true

require "json"

# What a masked read of a file or a memory item leaves in the Journal.
RSpec.describe Lain::Telemetry::SourceMasked do
  subject(:event) do
    described_class.new(tool_use_id: "tu_2", kind: :file, key: "/tmp/config.yml", regions: 3, released: 1)
  end

  def build(**over)
    described_class.new(tool_use_id: "tu_2", kind: :file, key: "/tmp/x", regions: 1, released: 0, **over)
  end

  it "carries the call, the kind, the key and the region counts" do
    expect(event).to have_attributes(tool_use_id: "tu_2", kind: :file, key: "/tmp/config.yml", regions: 3, released: 1)
  end

  it "is deeply frozen, even from mutable Strings" do
    expect(build(tool_use_id: +"tu", key: +"/tmp/x")).to be_deeply_frozen
  end

  it "carries a masked file and a masked memory item as one record type" do
    memory = build(kind: :memory, key: "db-creds")

    expect([event, memory].map(&:journal_type).uniq).to eq(["source_masked"])
    expect(JSON.parse(JSON.generate(memory.to_journal))).to eq(
      "type" => "source_masked", "tool_use_id" => "tu_2", "kind" => "memory", "key" => "db-creds",
      "regions" => 1, "released" => 0
    )
  end

  it "reads back from the journal it wrote, kind and all" do
    journaled = JSON.parse(JSON.generate(event.to_journal)).except("type").transform_keys(&:to_sym)

    expect(described_class.new(**journaled)).to eq(event)
  end

  it "needs no released count for a source that has no release" do
    expect(described_class.new(tool_use_id: "tu", kind: :memory, key: "note", regions: 1).released).to eq(0)
  end

  it "refuses a kind that names no source" do
    [nil, :search, "", "file "].each { |bad| expect { build(kind: bad) }.to raise_error(ArgumentError, /kind/) }
  end

  it "refuses a record that names no key, which a replay would apply to the wrong source" do
    [nil, ""].each { |bad| expect { build(key: bad) }.to raise_error(ArgumentError, /key/) }
  end

  it "refuses counts that are not non-negative Integers" do
    [nil, -1, 3.7, { "leaked" => "bytes" }].each do |bad|
      expect { build(regions: bad) }.to raise_error(ArgumentError, /regions/)
      expect { build(released: bad) }.to raise_error(ArgumentError, /released/)
    end
  end

  it "refuses more released than found" do
    expect { build(regions: 9, released: 10) }.to raise_error(ArgumentError, /released must be <= regions/)
  end

  describe "journal bytes" do
    it "journals every field, the kind as a String" do
      expect(JSON.generate(event.to_journal)).to eq(
        '{"type":"source_masked","tool_use_id":"tu_2","kind":"file","key":"/tmp/config.yml","regions":3,' \
        '"released":1}'
      )
    end

    it "defaults released to 0 and takes a String kind as the Symbol" do
      record = described_class.new(tool_use_id: "tu_2", kind: "memory", key: "item-1", regions: 2)
      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"source_masked","tool_use_id":"tu_2","kind":"memory","key":"item-1","regions":2,"released":0}'
      )
      expect(record.kind).to be(:memory)
    end

    it "interns the call id and the key across equal records" do
      first = build(tool_use_id: +"tu_2", key: +"/tmp/x")
      second = build(tool_use_id: +"tu_2", key: +"/tmp/x")
      expect(first.tool_use_id).to equal(second.tool_use_id)
      expect(first.key).to equal(second.key)
    end

    it "refuses a keyword it does not declare" do
      expect { build(stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses key given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect { build(key: blank) }.to raise_error(ArgumentError, /key must name the masked source/)
      end
    end
  end

  describe "post-settle conversions" do
    it "journals numeric-string counts as Integers" do
      record = build(regions: "3", released: "1")
      expect(record.regions).to eq(3)
      expect(record.released).to eq(1)
    end
  end
end
