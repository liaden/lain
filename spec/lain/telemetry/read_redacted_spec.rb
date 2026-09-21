# frozen_string_literal: true

require "json"
require "pathname"

# What the read-masking leaves in the Journal.
RSpec.describe Lain::Telemetry::ReadRedacted do
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

  # This record DRIVES a control now: SessionRecord::Replay folds it back into
  # the masked read-set. An unnamed path coerces to "", which a resume
  # normalizes to its own cwd -- so the mask lands on a directory, the file
  # reads back as wholly seen, and write_file replaces the secret with the
  # placeholder. The live writer always has a resolved path; a salvaged
  # journal is what the guard is for.
  it "refuses a record that names no path, which a replay would apply to the cwd" do
    expect { described_class.new(tool_use_id: "tu_2", path: nil, regions: 1, released: 0) }
      .to raise_error(ArgumentError, /path must name the redacted path/)
  end

  it "refuses a blank path for the same reason" do
    expect { described_class.new(tool_use_id: "tu_2", path: "", regions: 1, released: 0) }
      .to raise_error(ArgumentError, /path must name the redacted path/)
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
  # bytes. Carriers::ReadRedacted, on Carriers::Dropped's shape, closes all
  # four at once.
  # ActiveModel's numericality is type-permissive (Carriers::Dropped's own
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
