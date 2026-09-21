# frozen_string_literal: true

require "json"
require "pathname"

# What the path gate's read-time denials leave in the Journal.
RSpec.describe Lain::Telemetry::ReadRefused do
  subject(:event) do
    described_class.new(tool_use_id: "tu_1", tool: "read_file",
                        path: "/home/joel/.ssh/id_ed25519", reason: "ssh private key")
  end

  it "carries the tool_use_id, tool, path, and reason" do
    expect(event.tool_use_id).to eq("tu_1")
    expect(event.tool).to eq("read_file")
    expect(event.path).to eq("/home/joel/.ssh/id_ed25519")
    expect(event.reason).to eq("ssh private key")
  end

  # The record covers WRITERS too -- {Sensitivity::Policy::PATH_FIELDS} names
  # write_file, edit_file and bash beside the readers -- so a
  # Journal reader tallies by verb on this field rather than counting a
  # refused write as a refused read.
  it "names the tool, so a refused write is not tallied as a refused read" do
    write = described_class.new(tool_use_id: "tu_2", tool: "write_file",
                                path: "/home/joel/.ssh/id_ed25519", reason: "protected")

    expect(write.tool).to eq("write_file")
    expect(write.journal_type).to eq("read_refused")
    expect(write.to_journal).to include("tool" => "write_file")
  end

  it "rejects a nil tool loudly -- a refusal record must name which call it refused" do
    expect { described_class.new(tool_use_id: "tu_1", tool: nil, path: "/etc/passwd", reason: "denied") }
      .to raise_error(ArgumentError, /tool must name the refused tool, got nil/)
  end

  it "rejects a nil reason loudly -- a refusal record must name what refused" do
    expect { described_class.new(tool_use_id: "tu_1", tool: "read_file", path: "/etc/passwd", reason: nil) }
      .to raise_error(ArgumentError, /reason must name what refused, got nil/)
  end

  it "rejects a nil path loudly -- a refusal record must name which path it refused" do
    expect { described_class.new(tool_use_id: "tu_1", tool: "read_file", path: nil, reason: "denied") }
      .to raise_error(ArgumentError, "path must name the refused path, got nil")
  end

  it "is a frozen value object with structural equality" do
    twin = described_class.new(tool_use_id: "tu_1", tool: "read_file",
                               path: "/home/joel/.ssh/id_ed25519", reason: "ssh private key")
    expect(event).to eq(twin)
    expect(event).to be_deeply_frozen
    expect(event.hash).to eq(twin.hash)
  end

  it "is Ractor-shareable even when built from mutable Strings" do
    mutable = described_class.new(tool_use_id: +"tu_1", tool: +"read_file", path: +"/etc/passwd",
                                  reason: +"denied")
    expect(mutable).to be_deeply_frozen
    expect(Ractor.shareable?(mutable)).to be(true)
  end

  it "coerces a Pathname path to a String, so the in-process field matches the journaled one" do
    from_pathname = described_class.new(tool_use_id: "tu_1", tool: "read_file", path: Pathname.new("/etc/passwd"),
                                        reason: "denied")
    expect(from_pathname.path).to eq("/etc/passwd")
    expect(from_pathname.path).to be_a(String)
    expect(from_pathname).to be_deeply_frozen
  end

  it "journals as a read_refused record that round-trips through JSON" do
    expect(event.journal_type).to eq("read_refused")
    expect(event.to_journal).to eq(
      "type" => "read_refused", "tool_use_id" => "tu_1", "tool" => "read_file",
      "path" => "/home/joel/.ssh/id_ed25519", "reason" => "ssh private key"
    )
    expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
      "type" => "read_refused", "tool_use_id" => "tu_1", "tool" => "read_file",
      "path" => "/home/joel/.ssh/id_ed25519", "reason" => "ssh private key"
    )
  end
end
