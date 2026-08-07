# frozen_string_literal: true

require "json"
require "pathname"

# T13: what T12's read-time denials and T15's masking leave in the Journal.
# Mirrors turn_stream_spec's per-record describe-block style (the sibling
# records live in one telemetry_spec.rb; these two are new enough, and
# specific enough to the secret boundary, to get their own file).
RSpec.describe "Lain::Telemetry secret boundary records" do
  describe Lain::Telemetry::ReadRefused do
    subject(:event) do
      described_class.new(tool_use_id: "tu_1", path: "/home/joel/.ssh/id_ed25519", reason: "ssh private key")
    end

    it "carries the tool_use_id, path, and reason" do
      expect(event.tool_use_id).to eq("tu_1")
      expect(event.path).to eq("/home/joel/.ssh/id_ed25519")
      expect(event.reason).to eq("ssh private key")
    end

    it "rejects a nil reason loudly -- a refusal record must name what refused" do
      expect { described_class.new(tool_use_id: "tu_1", path: "/etc/passwd", reason: nil) }
        .to raise_error(ArgumentError, /reason must name what refused, got nil/)
    end

    it "rejects a nil path loudly -- a refusal record must name which path it refused" do
      expect { described_class.new(tool_use_id: "tu_1", path: nil, reason: "denied") }
        .to raise_error(ArgumentError, "path must name the refused path, got nil")
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "tu_1", path: "/home/joel/.ssh/id_ed25519", reason: "ssh private key")
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable even when built from mutable Strings" do
      mutable = described_class.new(tool_use_id: +"tu_1", path: +"/etc/passwd", reason: +"denied")
      expect(mutable).to be_deeply_frozen
      expect(Ractor.shareable?(mutable)).to be(true)
    end

    it "coerces a Pathname path to a String, so the in-process field matches the journaled one" do
      from_pathname = described_class.new(tool_use_id: "tu_1", path: Pathname.new("/etc/passwd"), reason: "denied")
      expect(from_pathname.path).to eq("/etc/passwd")
      expect(from_pathname.path).to be_a(String)
      expect(from_pathname).to be_deeply_frozen
    end

    it "journals as a read_refused record that round-trips through JSON" do
      expect(event.journal_type).to eq("read_refused")
      expect(event.to_journal).to eq(
        "type" => "read_refused", "tool_use_id" => "tu_1",
        "path" => "/home/joel/.ssh/id_ed25519", "reason" => "ssh private key"
      )
      expect(JSON.parse(JSON.generate(event.to_journal))).to eq(
        "type" => "read_refused", "tool_use_id" => "tu_1",
        "path" => "/home/joel/.ssh/id_ed25519", "reason" => "ssh private key"
      )
    end
  end

  describe Lain::Telemetry::ReadRedacted do
    subject(:event) { described_class.new(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: 3, released: 1) }

    it "carries the tool_use_id, path, and the region counts" do
      expect(event.tool_use_id).to eq("tu_2")
      expect(event.path).to eq("/tmp/config.yml")
      expect(event.regions).to eq(3)
      expect(event.released).to eq(1)
    end

    it "is a frozen value object with structural equality" do
      twin = described_class.new(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: 3, released: 1)
      expect(event).to eq(twin)
      expect(event).to be_deeply_frozen
      expect(event.hash).to eq(twin.hash)
    end

    it "is Ractor-shareable even when built from mutable Strings" do
      mutable = described_class.new(tool_use_id: +"tu_2", path: +"/tmp/config.yml", regions: 3, released: 1)
      expect(mutable).to be_deeply_frozen
      expect(Ractor.shareable?(mutable)).to be(true)
    end

    it "coerces a Pathname path to a String, so the in-process field matches the journaled one" do
      from_pathname = described_class.new(tool_use_id: "tu_2", path: Pathname.new("/tmp/config.yml"),
                                          regions: 3, released: 1)
      expect(from_pathname.path).to eq("/tmp/config.yml")
      expect(from_pathname.path).to be_a(String)
    end

    it "tolerates zero regions and zero released -- an unredacted read is legitimate" do
      clean = described_class.new(tool_use_id: "tu_2", path: "/tmp/config.yml", regions: 0, released: 0)
      expect(clean).to have_attributes(regions: 0, released: 0)
      expect(clean).to be_deeply_frozen
    end

    # The panel's probe: nothing stopped a String, a Hash, a negative count, or
    # nil from reaching this record, and the record whose entire job is to
    # carry COUNTS instead of content would happily carry a Hash of leaked
    # bytes. Guards::ReadRedacted (the Guards::Dropped shape, twelve lines
    # above WriteRefused in turn_stream.rb) closes all four at once.
    # ActiveModel's numericality is type-permissive (Guards::Dropped's own
    # idiom): a numeric-looking String passes the guard, same as an Integer
    # would. What must NOT survive is the raw String -- the record coerces
    # with `to_i` regardless of the input's class, so the shareability bug
    # (a mutable "3" stored unfrozen) cannot come back through this door.
    it "coerces a numeric-looking String count to a native Integer, staying shareable regardless of input type" do
      from_strings = described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: +"3", released: +"1")
      expect(from_strings).to have_attributes(regions: 3, released: 1)
      expect(from_strings.regions).to be_a(Integer)
      expect(from_strings).to be_deeply_frozen
    end

    it "rejects a Hash regions loudly -- the field carries counts, never content" do
      expect do
        described_class.new(tool_use_id: "tu_2", path: "/tmp/x",
                            regions: { "leaked" => "BEGIN RSA PRIVATE KEY" }, released: 1)
      end.to raise_error(ArgumentError, /regions/)
    end

    it "rejects a nil released loudly" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 3, released: nil) }
        .to raise_error(ArgumentError, /released/)
    end

    it "rejects a negative count loudly" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: -1, released: 0) }
        .to raise_error(ArgumentError, /regions/)
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 3, released: -1) }
        .to raise_error(ArgumentError, /released/)
    end

    it "rejects released greater than regions -- more was released than was ever found" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 2, released: 3) }
        .to raise_error(ArgumentError, /released must be <= regions/)
    end

    # regions: 2, released: 3 cannot see a comparison done as Strings instead of
    # Integers ("2" <= "3" agrees with 2 <= 3 below ten). Past ten, lexical and
    # numeric order diverge: "10" < "9" lexically, so a String comparison here
    # would fail OPEN -- accept an impossible record where more was released
    # than was ever found -- which is the direction that matters (the failed-
    # CLOSED direction only refuses a legitimate record, never a security gap).
    it "rejects released greater than regions once digit counts diverge, where lexical and numeric order disagree" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 9, released: 10) }
        .to raise_error(ArgumentError, /released must be <= regions/)
    end

    # only_integer: true is what stands between this record and a SILENT
    # truncation: relax it and `regions: 3.7` would pass the guard, then `.to_i`
    # stores 3 -- a count that looks exact but was quietly rounded down, in a
    # record whose entire job is an accurate count.
    it "rejects a non-integer Float regions loudly, rather than silently truncating via to_i" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 3.7, released: 1) }
        .to raise_error(ArgumentError, /regions/)
    end

    it "rejects a non-integer Float released loudly, rather than silently truncating via to_i" do
      expect { described_class.new(tool_use_id: "tu_2", path: "/tmp/x", regions: 5, released: 3.7) }
        .to raise_error(ArgumentError, /released/)
    end

    it "journals as a read_redacted record carrying counts, no field holding file bytes" do
      expect(event.journal_type).to eq("read_redacted")
      journal = event.to_journal
      expect(journal).to eq(
        "type" => "read_redacted", "tool_use_id" => "tu_2",
        "path" => "/tmp/config.yml", "regions" => 3, "released" => 1
      )
      expect(journal.fetch("regions")).to eq(3)
      expect(journal.fetch("released")).to eq(1)
      expect(journal.values).not_to include(a_string_matching(/secret|password|BEGIN/))

      round_tripped = JSON.parse(JSON.generate(journal))
      expect(round_tripped).to eq(
        "type" => "read_redacted", "tool_use_id" => "tu_2",
        "path" => "/tmp/config.yml", "regions" => 3, "released" => 1
      )
    end
  end
end
