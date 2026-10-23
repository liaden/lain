# frozen_string_literal: true

RSpec.describe Lain::Friction::BreakCause do
  def tool(name, schema = "a") = { "name" => name, "input_schema" => { "type" => schema } }

  def record(tools: [tool("read")], system: "be terse", reasoning: nil, stamp: "2026-10-23T10:00:00Z",
             payload: :recorded)
    body = if payload == :recorded
             { "model" => "m", "tools" => tools, "system" => system,
               "reasoning" => reasoning }
           end
    { "type" => "request_sent", "payload" => body, "ts" => stamp }.compact
  end

  def cause(before, after, **)
    described_class.between(described_class.shape_of(before), described_class.shape_of(after), **)
  end

  describe ".shape_of" do
    it "holds names and digests, never the payload bytes" do
      shape = described_class.shape_of(record(tools: [tool("read"), tool("bash")]))

      expect(shape.tool_names).to eq(%w[read bash])
      expect(shape.system_digest).to start_with("blake3:")
    end

    it "is shareable" do
      expect(Ractor.shareable?(described_class.shape_of(record))).to be(true)
    end

    it "is nil for a record whose payload was not recorded" do
      expect(described_class.shape_of(record(payload: nil))).to be_nil
    end

    it "reads the journal stamp as the time of the request" do
      expect(described_class.shape_of(record).at).to eq(Time.utc(2026, 10, 23, 10))
    end
  end

  describe ".between" do
    it "names an added tool" do
      expect(cause(record, record(tools: [tool("read"), tool("bash")]))).to eq(:tools_changed)
    end

    it "names a changed tool schema as a tools change" do
      expect(cause(record, record(tools: [tool("read", "b")]))).to eq(:tools_changed)
    end

    it "names a reorder of the same tools" do
      before = record(tools: [tool("read"), tool("bash")])

      expect(cause(before, record(tools: [tool("bash"), tool("read")]))).to eq(:tool_order_changed)
    end

    it "names an edited system" do
      expect(cause(record, record(system: "be verbose"))).to eq(:system_changed)
    end

    it "names changed reasoning settings" do
      expect(cause(record, record(reasoning: { "effort" => "high" }))).to eq(:effort_changed)
    end

    it "blames the history when only messages differ" do
      expect(cause(record, record)).to eq(:history_edited)
    end

    it "reads a long gap with a cold cache as expiry" do
      expect(cause(record, record(stamp: "2026-10-23T10:06:00Z"))).to eq(:ttl_expired)
    end

    it "does not read a long gap as expiry when the cache was read" do
      expect(cause(record, record(stamp: "2026-10-23T10:06:00Z"), cold: false)).to eq(:history_edited)
    end

    it "does not read a short gap as expiry" do
      expect(cause(record, record(stamp: "2026-10-23T10:04:00Z"))).to eq(:history_edited)
    end

    it "honours a longer ttl" do
      expect(cause(record, record(stamp: "2026-10-23T10:20:00Z"), ttl: 3600)).to eq(:history_edited)
    end

    it "says unknown when either payload was not recorded" do
      expect(cause(record, record(payload: nil))).to eq(:unknown)
    end

    it "only ever answers with a named cause" do
      expect(described_class::CAUSES).to include(cause(record, record))
    end
  end
end
