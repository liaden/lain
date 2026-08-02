# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Mode::Switch do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:manual) { Lain::Mode.new(posture: :manual) }
  let(:switch) { described_class.new(manual, journal:) }

  def flips
    Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a
  end

  describe "the delegating slot (a stand-in for the Mode its holder was built with)" do
    it "answers the mode it currently holds" do
      expect(switch.current).to be(manual)
    end

    it "answers the posture, the layers and the description through that mode" do
      switch.switch(Lain::Mode.new(posture: :auto, layers: %i[goal]), surface: "tty")

      expect(switch.posture).to eq(Lain::Mode::Posture.for(:auto))
      expect(switch.layers).to eq(Lain::Mode::LayerSet.new(%i[goal]))
      expect(switch.describe).to eq(switch.current.describe)
    end

    # Answering the slot rather than the argument: a dropped assignment must
    # not still confirm the new mode to its caller.
    it "answers the mode now in force, so a confirmation can name what it got" do
      auto = Lain::Mode.new(posture: :auto)

      expect(switch.switch(auto, surface: "tty")).to be(auto).and be(switch.current)
    end
  end

  describe "delegation, not mutation" do
    it "leaves the mode it held untouched -- the value is frozen and a switch replaces it" do
      switch.switch(Lain::Mode.new(posture: :auto), surface: "tty")

      expect(manual).to eq(Lain::Mode.new(posture: :manual))
      expect(manual).to be_frozen
      expect(switch.current).not_to eq(manual)
    end
  end

  # The slot must not move ahead of the record, or a refused flip leaves the
  # harness in a mode the experiment record never mentions -- worse than the
  # bad-but-present evidence an unguarded record would have written.
  describe "a flip the journal refuses" do
    it "leaves the mode it held in force, and writes nothing" do
      expect { switch.switch(Lain::Mode.new(posture: :auto), surface: nil) }
        .to raise_error(ArgumentError, /surface/)

      expect(switch.current).to be(manual)
      expect(journal_io.string).to be_empty
    end

    it "leaves the mode it held in force when handed something that is not a Mode at all" do
      expect { switch.switch(Object.new, surface: "tty") }.to raise_error(NoMethodError, /posture/)

      expect(switch.current).to be(manual)
      expect(journal_io.string).to be_empty
    end
  end

  describe "the journaled flip (attributed evidence, not incident detail)" do
    it "journals the flip from/to with the deciding surface" do
      switch.switch(Lain::Mode.new(posture: :auto), surface: "tty")

      expect(flips.map { |record| record.values_at("from", "to", "surface") })
        .to eq([%w[manual auto tty]])
    end

    it "journals nothing at construction -- the initial mode is the wiring's choice, not a flip" do
      switch
      expect(flips).to be_empty
    end

    it "journals a switch to the mode already held, so a transcript shows the redundant request" do
      plan = described_class.new(Lain::Mode.new(posture: :plan), journal:)
      plan.switch(Lain::Mode.new(posture: :plan), surface: "editor")

      expect(flips.map { |record| record.values_at("from", "to", "surface") })
        .to eq([%w[plan plan editor]])
    end

    # from/to alone cannot see a layer flip: `/mode +auto_approve` never moves
    # the posture, so a three-field record would journal `manual -> manual` for
    # a change that turns an outcome-altering layer on.
    it "journals both layer sets, so a layer flip that never moves the posture is still legible" do
      switch.switch(Lain::Mode.new(posture: :manual, layers: %i[auto_approve]), surface: "tty")

      record = flips.first
      expect(record.values_at("from", "to")).to eq(%w[manual manual])
      expect(record["from_layers"]).to eq([])
      expect(record["to_layers"]).to eq(%w[auto_approve])
    end

    it "journals layer names in precedence order, the order a LayerSet canonicalizes to" do
      switch.switch(Lain::Mode.new(posture: :manual, layers: %i[vi goal]), surface: "tty")

      expect(flips.first["to_layers"]).to eq(Lain::Mode::LayerSet.new(%i[vi goal]).names.map(&:to_s))
    end
  end

  describe "what actually reaches the NDJSON line" do
    # `Canonical.normalize` refuses an unknown object loudly, but JSON.generate
    # will happily write an object's `to_s` header into the journal, producing a
    # line that PARSES while carrying garbage. Every field of this record must
    # therefore already be a String or an Array of Strings.
    it "writes names and lists, never a rendered Ruby object" do
      switch.switch(Lain::Mode.new(posture: :auto, layers: %i[goal]), surface: "tty")
      line = journal_io.string.lines.last

      expect(line).not_to include("#<")
      expect(JSON.parse(line).values_at("from", "to", "surface")).to all(be_a(String))
      expect(JSON.parse(line).values_at("from_layers", "to_layers").flatten).to all(be_a(String))
    end
  end

  describe Lain::Telemetry::ModeSwitch do
    subject(:record) do
      described_class.new(from: :manual, to: :auto, from_layers: %i[goal], to_layers: [], surface: :tty)
    end

    it "journals under the discriminator readers and replay match on" do
      expect(record.journal_type).to eq("mode_switch")
    end

    it "interns every field, so the record stays shareable across a Ractor" do
      expect(Ractor.shareable?(record)).to be(true)
    end

    it "coerces names to Strings, whatever the caller held them as" do
      expect(record.to_journal)
        .to include("from" => "manual", "to" => "auto", "surface" => "tty", "from_layers" => %w[goal])
    end

    it "refuses a record that names no surface -- evidence that attributes nothing is not evidence" do
      expect { described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: nil) }
        .to raise_error(ArgumentError, /surface/)
    end

    it "refuses a record that names no posture it came from" do
      expect { described_class.new(from: nil, to: :auto, from_layers: [], to_layers: [], surface: :tty) }
        .to raise_error(ArgumentError, /from/)
    end

    # The failure this exists to prevent is silent: JSON.generate writes an
    # object's `to_s` header, so a Mode handed to a name field produces a line
    # that parses and holds `#<data Lain::Mode ...>` as a posture.
    it "refuses a value that is not name-shaped, naming what it got instead" do
      mode = Lain::Mode.new(posture: :manual)

      expect { described_class.new(from: mode, to: :auto, from_layers: [], to_layers: [], surface: :tty) }
        .to raise_error(ArgumentError, /from must be a name, got Lain::Mode/)
    end

    it "refuses a nil layer list rather than journaling it as an empty one" do
      expect { described_class.new(from: :manual, to: :auto, from_layers: nil, to_layers: [], surface: :tty) }
        .to raise_error(ArgumentError, /from_layers/)
    end

    # The constant is public; T8 and T22 build one without going through
    # Mode::Switch, so the list fields cannot rely on `#flip` filling them.
    it "refuses a layer list holding something that is not a name" do
      mode = Lain::Mode.new(posture: :manual)

      expect { described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [mode], surface: :tty) }
        .to raise_error(ArgumentError, /to_layers must be a list of layer names, got Lain::Mode in it/)
    end

    it "refuses a layer list holding a nil, which would journal as an unnamed layer" do
      expect { described_class.new(from: :manual, to: :auto, from_layers: [nil], to_layers: [], surface: :tty) }
        .to raise_error(ArgumentError, /from_layers.*NilClass/)
    end

    it "refuses a bare name where a layer list belongs, rather than dying inside the record" do
      expect { described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: "goal", surface: :tty) }
        .to raise_error(ArgumentError, /to_layers must be a list of layer names, got String/)
    end
  end
end
