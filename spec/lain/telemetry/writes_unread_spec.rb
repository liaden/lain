# frozen_string_literal: true

# The record that a bash command ran whose writes the shell reader could not name.
RSpec.describe Lain::Telemetry::WritesUnread do
  subject(:record) { described_class.new(tool_use_id: "tu_1", cwd: "/srv/project") }

  it "journals as writes_unread" do
    expect(record.to_journal["type"]).to eq("writes_unread")
  end

  describe "settled record" do
    it "journals byte for byte with every field set" do
      expect(JSON.generate(record.to_journal))
        .to eq('{"type":"writes_unread","tool_use_id":"tu_1","cwd":"/srv/project"}')
    end

    it "is deeply frozen when built from mutable input" do
      expect(described_class.new(tool_use_id: +"tu_1", cwd: +"/srv/project")).to be_deeply_frozen
    end

    it "refuses a missing cwd, naming it" do
      expect { described_class.new(tool_use_id: "tu_1") }.to raise_error(ArgumentError, /cwd/)
    end

    it "interns cwd" do
      first = described_class.new(tool_use_id: "tu_1", cwd: +"/v")
      second = described_class.new(tool_use_id: "tu_1", cwd: +"/v")
      expect(first.cwd).to equal(second.cwd)
    end
  end
end
