# frozen_string_literal: true

RSpec.describe Lain::LiveSessions::Record do
  let(:fields) do
    { "session_id" => "s", "pid" => 1, "start" => "t", "host" => "h", "root" => "/r", "cwd" => "/r",
      "input_socket" => nil, "journal" => nil, "attended" => true, "started_at" => "2026-11-19T10:00:00Z" }
  end

  def record(**extra) = described_class.new(**fields.transform_keys(&:to_sym), **extra)

  it "asks for no project poll unless told to" do
    expect(record.project_poll).to be(false)
  end

  it "sends the poll request as the register's project_poll field" do
    expect(record(project_poll: true).to_h).to include("project_poll" => true)
  end

  it "reads a daemon's listing, which does not carry the field, as asking for none" do
    expect(described_class.from_h(fields).project_poll).to be(false)
  end
end
