# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Mode::Switch do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:asking) { Lain::Mode.new }
  let(:switch) { described_class.new(asking, journal:) }

  def flips
    Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a
  end

  describe "the delegating slot (a stand-in for the Mode its holder was built with)" do
    it "answers the mode it currently holds" do
      expect(switch.current).to be(asking)
    end

    it "answers the scope, the approval, the layers and the description through that mode" do
      switch.switch(Lain::Mode.new(approval: :auto, layers: %i[goal]), surface: "tty")

      expect([switch.scope, switch.approval]).to eq([Lain::Mode::Scope.for(:checkout), Lain::Mode::Approval.for(:auto)])
      expect(switch.layers).to eq(Lain::Mode::LayerSet.new(%i[goal]))
      expect(switch.describe).to eq(switch.current.describe)
    end

    # Answering the slot rather than the argument: a dropped assignment must
    # not still confirm the new mode to its caller.
    it "answers the mode now in force, so a confirmation can name what it got" do
      auto = Lain::Mode.new(approval: :auto)

      expect(switch.switch(auto, surface: "tty")).to be(auto).and be(switch.current)
    end
  end

  describe "delegation, not mutation" do
    it "leaves the mode it held untouched -- the value is frozen and a switch replaces it" do
      switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")

      expect(asking).to eq(Lain::Mode.new)
      expect(asking).to be_frozen
      expect(switch.current).not_to eq(asking)
    end
  end

  # The slot must not move ahead of the record, or a refused flip leaves the
  # harness in a mode the experiment record never mentions.
  describe "a flip the journal refuses" do
    it "leaves the mode it held in force, and writes nothing" do
      expect { switch.switch(Lain::Mode.new(approval: :auto), surface: nil) }
        .to raise_error(ArgumentError, /surface/)

      expect(switch.current).to be(asking)
      expect(journal_io.string).to be_empty
    end

    it "leaves the mode it held in force when handed something that is not a Mode at all" do
      expect { switch.switch(Object.new, surface: "tty") }.to raise_error(NoMethodError, /scope/)

      expect(switch.current).to be(asking)
      expect(journal_io.string).to be_empty
    end
  end

  # Scenario: a no-op flip journals nothing
  describe "a flip that moves nothing" do
    it "journals nothing and keeps the mode it held" do
      held = described_class.new(Lain::Mode.new(layers: %i[vi]), journal:)

      held.switch(Lain::Mode.new(layers: %i[vi]), surface: "tty")

      expect(flips).to be_empty
    end
  end

  # Under `--no-journal --nvim` the journal is a tee that once raised on
  # `record`; the order is what made that a half-applied flip rather than a
  # refused one.
  describe "the order of record and assignment" do
    it "writes the record before the slot moves, so a journal that raises leaves the old mode in force" do
      refusing = Class.new { def record(_entry) = raise(IOError, "closed") }.new
      held = described_class.new(Lain::Mode.new, journal: refusing)

      expect { held.switch(Lain::Mode.new(approval: :auto), surface: "tty") }.to raise_error(IOError)
      expect(held.current).to eq(Lain::Mode.new)
    end
  end

  # Once the durable record is written the flip applies: every chat's record
  # journal is a JournalTee, and a live sink (the state feed on a full disk)
  # raises only after the session file already says the mode moved.
  describe "Mode::Switch atomicity" do
    def failing_sink(times: Float::INFINITY)
      failures = 0
      sink = Object.new
      sink.define_singleton_method(:<<) do |_event|
        raise IOError, "state file write failed" if (failures += 1) <= times
      end
      sink
    end

    it "moves the mode when a live sink raises after the durable record, then re-raises" do
      held = described_class.new(Lain::Mode.new, journal: Lain::CLI::JournalTee.new(journal, failing_sink))

      expect { held.switch(Lain::Mode.new(approval: :auto), surface: "tty") }.to raise_error(IOError)

      expect(flips.size).to eq(1)
      expect(held.current).to eq(Lain::Mode.new(approval: :auto))
    end

    it "moves the mode when the live sink's error is frozen, and surfaces the sink's own error" do
      frozen = IOError.new("state feed gone").freeze
      sink = Object.new
      sink.define_singleton_method(:<<) { |_event| raise frozen }
      held = described_class.new(Lain::Mode.new, journal: Lain::CLI::JournalTee.new(journal, sink))

      expect { held.switch(Lain::Mode.new(approval: :auto), surface: "tty") }.to raise_error(IOError, /state feed/)
      expect([flips.size, held.current]).to eq([1, Lain::Mode.new(approval: :auto)])
    end

    it "leaves the mode unchanged when the durable write itself fails" do
      journal.close
      held = described_class.new(Lain::Mode.new, journal: Lain::CLI::JournalTee.new(journal, failing_sink))

      expect { held.switch(Lain::Mode.new(approval: :auto), surface: "tty") }.to raise_error(Lain::Journal::Closed)
      expect(held.current).to eq(Lain::Mode.new)
    end

    it "writes no second record on a retry after a live-sink failure, so the records still chain" do
      held = described_class.new(Lain::Mode.new, journal: Lain::CLI::JournalTee.new(journal, failing_sink(times: 1)))
      auto = Lain::Mode.new(approval: :auto)

      expect { held.switch(auto, surface: "tty") }.to raise_error(IOError)
      held.switch(auto, surface: "tty")
      held.switch(Lain::Mode.new, surface: "tty")

      expect(flips.map { |record| record.values_at("from_approval", "to_approval") })
        .to eq([%w[ask auto], %w[auto ask]])
      expect { Lain::Compare::Mode.from_journal(journal_io.string.lines) }.not_to raise_error
    end
  end

  describe "the journaled flip (attributed evidence, not incident detail)" do
    it "journals both axes on each side, with the deciding surface" do
      switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")

      sides = %w[from_scope from_approval to_scope to_approval surface]
      expect(flips.map { |record| record.values_at(*sides) }).to eq([%w[checkout ask checkout auto tty]])
    end

    it "journals nothing at construction -- the initial mode is the wiring's choice, not a flip" do
      switch
      expect(flips).to be_empty
    end

    # The axes alone cannot see a layer flip: `/mode +auto_approve` moves
    # neither, so a record without the layer sets would journal
    # `checkout/ask -> checkout/ask` for a change that turns an outcome-altering
    # layer on.
    it "journals both layer sets, so a layer flip that moves no axis is still legible" do
      switch.switch(Lain::Mode.new(layers: %i[auto_approve]), surface: "tty")

      record = flips.first
      expect(record.values_at("from_approval", "to_approval")).to eq(%w[ask ask])
      expect(record["from_layers"]).to eq([])
      expect(record["to_layers"]).to eq(%w[auto_approve])
    end

    it "journals layer names in precedence order, the order a LayerSet canonicalizes to" do
      switch.switch(Lain::Mode.new(layers: %i[vi goal]), surface: "tty")

      expect(flips.first["to_layers"]).to eq(Lain::Mode::LayerSet.new(%i[vi goal]).names.map(&:to_s))
    end

    # A mode never changes what the model is shown, so the record has nothing
    # to say about a toolset.
    it "names no toolset" do
      switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")

      expect(flips.first.keys).not_to include("toolset_digest", "tool_names")
    end
  end

  describe "what actually reaches the NDJSON line" do
    # `Canonical.normalize` refuses an unknown object loudly, but JSON.generate
    # will happily write an object's `to_s` header into the journal, producing a
    # line that PARSES while carrying garbage. Every field of this record must
    # therefore already be a String or an Array of Strings.
    it "writes names and lists, never a rendered Ruby object" do
      switch.switch(Lain::Mode.new(approval: :auto, layers: %i[goal]), surface: "tty")
      line = JSON.parse(journal_io.string.lines.last)

      expect(journal_io.string).not_to include("#<")
      expect(line.values_at("from_scope", "to_scope", "from_approval", "to_approval", "surface")).to all(be_a(String))
      expect(line.values_at("from_layers", "to_layers").flatten).to all(be_a(String))
    end
  end

  describe Lain::Telemetry::ModeSwitch do
    def record(**over)
      described_class.new(from_scope: :checkout, to_scope: :checkout, from_approval: :ask, to_approval: :auto,
                          from_layers: %i[goal], to_layers: [], surface: :tty, **over)
    end

    it "journals under the discriminator readers and replay match on" do
      expect(record.journal_type).to eq("mode_switch")
    end

    it "interns every field, so the record stays shareable across a Ractor" do
      expect(record).to be_deeply_frozen
    end

    it "coerces names to Strings, whatever the caller held them as" do
      expect(record.to_journal)
        .to include("from_scope" => "checkout", "to_approval" => "auto", "surface" => "tty",
                    "from_layers" => %w[goal])
    end

    it "refuses a record that names no surface -- evidence that attributes nothing is not evidence" do
      expect { record(surface: nil) }.to raise_error(ArgumentError, /surface/)
    end

    it "refuses a record that names no approval it came from" do
      expect { record(from_approval: nil) }.to raise_error(ArgumentError, /from_approval/)
    end

    it "refuses a record that names no scope it went to" do
      expect { record(to_scope: nil) }.to raise_error(ArgumentError, /to_scope/)
    end

    # The failure this exists to prevent is silent: JSON.generate writes an
    # object's `to_s` header, so a Mode handed to a name field produces a line
    # that parses and holds `#<data Lain::Mode ...>` as a name.
    it "refuses a value that is not name-shaped, naming what it got instead" do
      expect { record(from_scope: Lain::Mode.new) }
        .to raise_error(ArgumentError, /from_scope must be a name, got Lain::Mode/)
    end

    it "refuses a nil layer list rather than journaling it as an empty one" do
      expect { record(from_layers: nil) }.to raise_error(ArgumentError, /from_layers/)
    end

    # The constant is public; other call sites build one without going through
    # Mode::Switch, so the list fields cannot rely on `#flip` filling them.
    it "refuses a layer list holding something that is not a name" do
      expect { record(to_layers: [Lain::Mode.new]) }
        .to raise_error(ArgumentError, /to_layers must be a list of layer names, got Lain::Mode in it/)
    end

    it "refuses a layer list holding a nil, which would journal as an unnamed layer" do
      expect { record(from_layers: [nil]) }.to raise_error(ArgumentError, /from_layers.*NilClass/)
    end

    it "refuses a bare name where a layer list belongs, rather than dying inside the record" do
      expect { record(to_layers: "goal") }
        .to raise_error(ArgumentError, /to_layers must be a list of layer names, got String/)
    end
  end
end
