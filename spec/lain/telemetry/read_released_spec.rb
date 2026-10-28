# frozen_string_literal: true

RSpec.describe Lain::Telemetry::ReadReleased do
  subject(:event) do
    described_class.new(tool_use_id: "tu_1", path: "/repo/.env", regions: 2, requester: "agent", surface: "tty")
  end

  def released(**overrides)
    described_class.new(tool_use_id: "tu_1", path: "/repo/.env", regions: 2, requester: "agent", surface: "tty",
                        **overrides)
  end

  it "journals as read_released naming the call, the file, the count, who asked and who answered" do
    expect(event.to_journal).to eq(
      "type" => "read_released", "tool_use_id" => "tu_1", "path" => "/repo/.env", "regions" => 2,
      "requester" => "agent", "surface" => "tty"
    )
  end

  it "is deeply frozen even when built from mutable Strings and a numeric String count" do
    mutable = described_class.new(tool_use_id: +"tu_1", path: +"/repo/.env", regions: +"2", requester: +"agent",
                                  surface: +"tty")

    expect(mutable).to eq(event)
    expect(mutable.regions).to be_a(Integer)
    expect(mutable).to be_deeply_frozen
  end

  it "refuses a record that names no call, file, requester or surface" do
    expect { released(tool_use_id: nil) }.to raise_error(ArgumentError, /tool_use_id must name the released call/)
    expect { released(path: "") }.to raise_error(ArgumentError, /path must name the released file/)
    expect { released(requester: nil) }.to raise_error(ArgumentError, /requester must name who the read was for/)
    expect { released(surface: nil) }.to raise_error(ArgumentError, /surface must name what released it/)
  end

  # A release of nothing is not a release, and a count that is not an Integer
  # is the door region bytes would come through.
  it "refuses a count that is not a positive Integer" do
    expect { released(regions: 0) }.to raise_error(ArgumentError, /regions/)
    expect { released(regions: { "leaked" => "BEGIN RSA PRIVATE KEY" }) }.to raise_error(ArgumentError, /regions/)
    expect { released(regions: nil) }.to raise_error(ArgumentError, /regions/)
  end

  describe "journal bytes" do
    it "journals every field in declaration order" do
      expect(JSON.generate(event.to_journal)).to eq(
        '{"type":"read_released","tool_use_id":"tu_1","path":"/repo/.env","regions":2,"requester":"agent",' \
        '"surface":"tty"}'
      )
    end

    it "interns every name across equal records" do
      twin = released(tool_use_id: +"tu_1", path: +"/repo/.env", requester: +"agent", surface: +"tty")
      other = released(tool_use_id: +"tu_1", path: +"/repo/.env", requester: +"agent", surface: +"tty")
      %i[tool_use_id path requester surface].each do |field|
        expect(twin.public_send(field)).to equal(other.public_send(field))
      end
    end

    it "journals a numeric-string count as an Integer" do
      expect(released(regions: "2").to_journal).to include("regions" => 2)
    end

    it "refuses a keyword it does not declare" do
      expect { released(stray: 1) }.to raise_error(ArgumentError, /stray/)
    end
  end

  describe "blank names" do
    it "refuses tool_use_id given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect { released(tool_use_id: blank) }.to raise_error(ArgumentError, /tool_use_id must name the released call/)
      end
    end

    it "refuses path given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect { released(path: blank) }.to raise_error(ArgumentError, /path must name the released file/)
      end
    end

    it "refuses requester given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect { released(requester: blank) }.to raise_error(ArgumentError, /requester must name who the read was for/)
      end
    end

    it "refuses surface given as false, an empty Array or an empty Hash, as it did before interning" do
      [false, [], {}].each do |blank|
        expect { released(surface: blank) }.to raise_error(ArgumentError, /surface must name what released it/)
      end
    end
  end
end
