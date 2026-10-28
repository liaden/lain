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

  describe "the journal line" do
    it "matches the line the record has always written" do
      record = described_class.new(image: "alpine:latest", id: "sha256:abc", listed: true, reason: "no ID")

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"exec_image","image":"alpine:latest","id":"sha256:abc","listed":true,"reason":"no ID"}')
    end

    it "keeps a nil id and reason as null" do
      record = described_class.new(image: "alpine:latest", id: nil, listed: false, reason: nil)

      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"exec_image","image":"alpine:latest","id":null,"listed":false,"reason":null}')
    end
  end

  it "shares the bytes of every interned field between 2 equal records" do
    build = -> { described_class.new(image: +"alpine:latest", id: +"sha256:abc", listed: false, reason: +"no ID") }
    one = build.call
    other = build.call

    expect([one.image, one.id, one.reason]).to eq([other.image, other.id, other.reason])
    expect([one.image.equal?(other.image), one.id.equal?(other.id), one.reason.equal?(other.reason)])
      .to eq([true, true, true])
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { described_class.new(image: "a", id: nil, listed: false, reason: nil, extra: 1) }
      .to raise_error(ArgumentError, /extra/)
  end
end
