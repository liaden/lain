# frozen_string_literal: true

# The lifecycle vocabulary lifted out of `FleetWindows#terminal?`
# (`fleet_windows.rb:289-292`), which tested two unrelated record shapes
# inline because a one-shot completion and an actor farewell speak different
# vocabularies. This object names the question once so a second reader
# (`StatusFeed`) can ask the same thing instead of growing its own copy.
RSpec.describe Lain::StatusFeed::SpawnLifecycle do
  # A record whose `#payload` is the flat body Hash -- the shape both
  # FleetWindows and StatusFeed actually hand this object, and the one
  # `Telemetry::Message#payload` answers.
  def record(payload)
    Lain::Telemetry::Message.new(
      digest: "blake3:0e50111122223333", kind: :message, from: "blake3:child", to: "blake3:parent",
      payload:, causal_parents: ["blake3:child"], correlation: "blake3:parent"
    )
  end

  describe "an actor farewell is terminal" do
    it "is terminal" do
      lifecycle = described_class.new(record({ "text" => "actor stopped", "lifecycle" => "stopped" }))

      expect(lifecycle.terminal?).to be(true)
    end
  end

  describe "an actor settling a turn is not terminal" do
    it "is not terminal" do
      lifecycle = described_class.new(record({ "text" => "found 3 papers", "lifecycle" => "settled" }))

      expect(lifecycle.terminal?).to be(false)
    end
  end

  describe "a launch is not terminal" do
    it "is not terminal" do
      lifecycle = described_class.new(record({ "prefix" => "fresh", "lifecycle" => "launched" }))

      expect(lifecycle.terminal?).to be(false)
    end
  end

  describe "a one-shot completion carrying only a result is terminal" do
    it "is terminal" do
      lifecycle = described_class.new(record({ "result" => "found 3 papers", "final" => "blake3:f1na" }))

      expect(lifecycle.terminal?).to be(true)
    end
  end

  describe "an ordinary tell is not terminal" do
    it "is not terminal" do
      lifecycle = described_class.new(record({ "text" => "narrow to RCTs" }))

      expect(lifecycle.terminal?).to be(false)
    end
  end

  describe "an unknown mark is not terminal, and says it was not understood" do
    it "is not terminal, and reports the mark it did not recognise" do
      lifecycle = described_class.new(record({ "text" => "actor wandered off", "lifecycle" => "meandering" }))

      expect(lifecycle.terminal?).to be(false)
      expect(lifecycle.unrecognized).to eq("meandering")
    end
  end

  describe "a recognized mark reports nothing unrecognized" do
    it "leaves #unrecognized nil" do
      lifecycle = described_class.new(record({ "text" => "actor stopped", "lifecycle" => "stopped" }))

      expect(lifecycle.unrecognized).to be_nil
    end
  end

  describe "a result stays terminal no matter which mark, if any, rides beside it" do
    it "is terminal when paired with a recognized non-stopped mark" do
      lifecycle = described_class.new(record({ "result" => "found 3 papers", "lifecycle" => "launched" }))

      expect(lifecycle.terminal?).to be(true)
    end

    it "is terminal when paired with an unrecognized mark, and still reports it" do
      lifecycle = described_class.new(record({ "result" => "found 3 papers", "lifecycle" => "meandering" }))

      expect(lifecycle.terminal?).to be(true)
      expect(lifecycle.unrecognized).to eq("meandering")
    end
  end

  # `Lain::Event#payload` is the CONTENT-ADDRESS ENVELOPE (kind/from/to/
  # causal_parents/correlation/payload_digest), not the body -- its own doc
  # says the body is "deliberately absent" from it. The body lives on
  # `Event#body`. A real actor farewell or one-shot completion travels as
  # exactly this shape wherever a raw Event reaches this object (per
  # `status_feed.rb:215-222`, StatusFeed's `:message` arm admits anything
  # answering `#kind`, which a raw Event does).
  def event(body, kind: :message)
    Lain::Event.new(kind:, payload_digest: "blake3:eventbody", body:,
                    from: "blake3:child", to: "blake3:parent",
                    causal_parents: ["blake3:child"], correlation: "blake3:parent")
  end

  describe "a raw Lain::Event, not a Telemetry::Message" do
    it "reads a farewell's body, not its envelope, so it is terminal" do
      lifecycle = described_class.new(event({ "text" => "actor stopped", "lifecycle" => "stopped" }))

      expect(lifecycle.terminal?).to be(true)
    end

    it "reads a one-shot completion's body, not its envelope, so it is terminal" do
      lifecycle = described_class.new(event({ "result" => "found 3 papers", "final" => "blake3:f1na" }))

      expect(lifecycle.terminal?).to be(true)
    end

    it "reads an ordinary tell's body as not terminal, same as the Message shape" do
      lifecycle = described_class.new(event({ "text" => "narrow to RCTs" }))

      expect(lifecycle.terminal?).to be(false)
    end

    # The rest of the matrix the Message-shape examples above already cover --
    # filled in here too, not because a discrepancy was found (there is none;
    # both shapes agree everywhere), but so a future edit that makes the two
    # `read_body` branches diverge trips a spec on THIS shape rather than only
    # on the Message one.
    it "reads a settling turn's body as not terminal" do
      lifecycle = described_class.new(event({ "text" => "found 3 papers", "lifecycle" => "settled" }))

      expect(lifecycle.terminal?).to be(false)
    end

    it "reads a launch's body as not terminal" do
      lifecycle = described_class.new(event({ "prefix" => "fresh", "lifecycle" => "launched" }, kind: :spawn))

      expect(lifecycle.terminal?).to be(false)
    end

    it "reads an unrecognized mark as not terminal, and reports it" do
      lifecycle = described_class.new(event({ "text" => "actor wandered off", "lifecycle" => "meandering" }))

      expect(lifecycle.terminal?).to be(false)
      expect(lifecycle.unrecognized).to eq("meandering")
    end

    it "reads a result paired with a recognized non-stopped mark as terminal" do
      lifecycle = described_class.new(event({ "result" => "found 3 papers", "lifecycle" => "launched" }))

      expect(lifecycle.terminal?).to be(true)
    end

    it "reads a result paired with an unrecognized mark as terminal, and still reports the mark" do
      lifecycle = described_class.new(event({ "result" => "found 3 papers", "lifecycle" => "meandering" }))

      expect(lifecycle.terminal?).to be(true)
      expect(lifecycle.unrecognized).to eq("meandering")
    end
  end

  describe "a record this object cannot read" do
    it "does not raise on a record whose #payload is not a Hash" do
      odd = Struct.new(:payload).new("not a hash")

      expect { described_class.new(odd).terminal? }.not_to raise_error
      expect(described_class.new(odd).terminal?).to be(false)
    end

    it "does not raise on a record answering no #payload at all" do
      bare = Object.new

      expect { described_class.new(bare).terminal? }.not_to raise_error
      expect(described_class.new(bare).terminal?).to be(false)
    end

    # Both consumers ride `CLI::JournalTee`, which re-raises a sink's failure
    # into the agent loop and costs a turn -- so a collaborator whose own
    # accessor raises must read the same as any other record this object
    # cannot make sense of, not propagate.
    it "does not raise when #body itself raises" do
      raising = Class.new do
        def body = raise "boom"
      end.new

      expect { described_class.new(raising).terminal? }.not_to raise_error
      expect(described_class.new(raising).terminal?).to be(false)
    end

    it "does not raise when #payload itself raises and the record has no #body" do
      raising = Class.new do
        def payload = raise "boom"
      end.new

      expect { described_class.new(raising).terminal? }.not_to raise_error
      expect(described_class.new(raising).terminal?).to be(false)
    end
  end

  describe "shareability" do
    it "is Ractor.shareable?" do
      lifecycle = described_class.new(record({ "text" => "actor stopped", "lifecycle" => "stopped" }))

      expect(lifecycle).to be_deeply_frozen
    end

    # `Kernel#freeze` on the receiver is not transitive: a mark read out of an
    # unfrozen source String and stored as-is would leave THIS object
    # unshareable even though `#initialize` calls `freeze`. Going through the
    # `record`/`event` helpers above would not exercise this: both
    # `Telemetry::Message.new` and `Lain::Event.new` run their `payload`/
    # `body` through `Canonical.normalize`, which deep-freezes every String
    # before this object ever sees it -- so a plain `#payload`-answering
    # double, fed a `JSON.parse` Hash (ordinary mutable Strings, unlike every
    # frozen literal used elsewhere in this file), is what actually drives an
    # unfrozen mark in. The unrecognized-mark branch is the one that stores a
    # String this object did not choose the literal for.
    def unnormalized(payload) = Struct.new(:payload).new(payload)

    it "is Ractor.shareable? even when the mark came from an unfrozen source, on the unrecognized branch" do
      unfrozen = JSON.parse('{"text": "actor wandered off", "lifecycle": "meandering"}')
      lifecycle = described_class.new(unnormalized(unfrozen))

      expect(lifecycle).to be_deeply_frozen
      expect(lifecycle.unrecognized).to eq("meandering")
    end

    it "is Ractor.shareable? even when the mark came from an unfrozen source, on a recognized mark" do
      unfrozen = JSON.parse('{"text": "actor stopped", "lifecycle": "stopped"}')
      lifecycle = described_class.new(unnormalized(unfrozen))

      expect(lifecycle).to be_deeply_frozen
    end
  end
end
