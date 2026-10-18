# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::ExecImage do
  let(:id) { "d529dd0c6e5597ac7e4a3e2dea65c3fcc6173f4cae713c409265c1dd9914a11b" }

  it "is shareable across Ractors even built from mutable Strings" do
    record = described_class.new(image: +"alpine:latest", id: +id, listed: false, reason: +"docker export exited 1")

    expect(record).to be_deeply_frozen
  end

  it "writes one exec_image line naming the tag, the ID and whether the listing was read" do
    io = StringIO.new
    Lain::Journal.new(io:).record(described_class.new(image: "alpine:latest", id:, listed: true, reason: nil))

    expect(JSON.parse(io.string.lines.first))
      .to include("type" => "exec_image", "image" => "alpine:latest", "id" => id, "listed" => true, "reason" => nil)
  end

  it "writes why the listing was not read" do
    io = StringIO.new
    Lain::Journal.new(io:).record(described_class.new(image: "img:1", id: nil, listed: false, reason: "no ID"))

    expect(JSON.parse(io.string.lines.first)).to include("id" => nil, "listed" => false, "reason" => "no ID")
  end
end
