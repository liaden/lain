# frozen_string_literal: true

require "json"
require "stringio"

RSpec.describe Lain::Mode::Switch do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:manual) { Lain::Mode.new(posture: :manual) }
  let(:switch) { described_class.new(manual, journal:) }

  # An empty Toolset is a real one -- it answers #digest and #names honestly --
  # and is the right stand-in everywhere a scenario is not itself about what the
  # flip resolved to. `resolved_toolset` names a small REAL set (ToolRegistry's,
  # posture_spec and switchboard_spec's own reason: a verifying double's `#only`
  # accepts anything, so it would pass here and raise on the first live flip).
  let(:no_tools) { Lain::Toolset.new }
  let(:resolved_toolset) { Lain::Toolset.new(ToolRegistry.names.first(2).map { |name| ToolRegistry.build(name) }) }

  def flips
    Lain::Journal.records(journal_io.string.lines, type: "mode_switch").to_a
  end

  describe "the delegating slot (a stand-in for the Mode its holder was built with)" do
    it "answers the mode it currently holds" do
      expect(switch.current).to be(manual)
    end

    it "answers the posture, the layers and the description through that mode" do
      switch.switch(Lain::Mode.new(posture: :auto, layers: %i[goal]), surface: "tty", toolset: no_tools)

      expect(switch.posture).to eq(Lain::Mode::Posture.for(:auto))
      expect(switch.layers).to eq(Lain::Mode::LayerSet.new(%i[goal]))
      expect(switch.describe).to eq(switch.current.describe)
    end

    # Answering the slot rather than the argument: a dropped assignment must
    # not still confirm the new mode to its caller.
    it "answers the mode now in force, so a confirmation can name what it got" do
      auto = Lain::Mode.new(posture: :auto)

      expect(switch.switch(auto, surface: "tty", toolset: no_tools)).to be(auto).and be(switch.current)
    end
  end

  describe "delegation, not mutation" do
    it "leaves the mode it held untouched -- the value is frozen and a switch replaces it" do
      switch.switch(Lain::Mode.new(posture: :auto), surface: "tty", toolset: no_tools)

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
      expect { switch.switch(Lain::Mode.new(posture: :auto), surface: nil, toolset: no_tools) }
        .to raise_error(ArgumentError, /surface/)

      expect(switch.current).to be(manual)
      expect(journal_io.string).to be_empty
    end

    it "leaves the mode it held in force when handed something that is not a Mode at all" do
      expect { switch.switch(Object.new, surface: "tty", toolset: no_tools) }.to raise_error(NoMethodError, /posture/)

      expect(switch.current).to be(manual)
      expect(journal_io.string).to be_empty
    end

    # `toolset:` is REQUIRED, with no empty-Toolset default: a default here is
    # exactly how a future caller that forgot to resolve one would go on
    # journaling a false "nothing declared" set instead of failing where the
    # mistake was made. Every production and spec caller names one explicitly
    # (real or a bare `Lain::Toolset.new`) -- see `no_tools` above.
    it "raises rather than journal a flip with no toolset at all" do
      expect { switch.switch(Lain::Mode.new(posture: :auto), surface: "tty") }
        .to raise_error(ArgumentError, /toolset/)

      expect(switch.current).to be(manual)
      expect(journal_io.string).to be_empty
    end
  end

  describe "the journaled flip (attributed evidence, not incident detail)" do
    it "journals the flip from/to with the deciding surface" do
      switch.switch(Lain::Mode.new(posture: :auto), surface: "tty", toolset: no_tools)

      expect(flips.map { |record| record.values_at("from", "to", "surface") })
        .to eq([%w[manual auto tty]])
    end

    it "journals nothing at construction -- the initial mode is the wiring's choice, not a flip" do
      switch
      expect(flips).to be_empty
    end

    it "journals a switch to the mode already held, so a transcript shows the redundant request" do
      plan = described_class.new(Lain::Mode.new(posture: :plan), journal:)
      plan.switch(Lain::Mode.new(posture: :plan), surface: "editor", toolset: no_tools)

      expect(flips.map { |record| record.values_at("from", "to", "surface") })
        .to eq([%w[plan plan editor]])
    end

    # from/to alone cannot see a layer flip: `/mode +auto_approve` never moves
    # the posture, so a three-field record would journal `manual -> manual` for
    # a change that turns an outcome-altering layer on.
    it "journals both layer sets, so a layer flip that never moves the posture is still legible" do
      switch.switch(Lain::Mode.new(posture: :manual, layers: %i[auto_approve]), surface: "tty", toolset: no_tools)

      record = flips.first
      expect(record.values_at("from", "to")).to eq(%w[manual manual])
      expect(record["from_layers"]).to eq([])
      expect(record["to_layers"]).to eq(%w[auto_approve])
    end

    it "journals layer names in precedence order, the order a LayerSet canonicalizes to" do
      switch.switch(Lain::Mode.new(posture: :manual, layers: %i[vi goal]), surface: "tty", toolset: no_tools)

      expect(flips.first["to_layers"]).to eq(Lain::Mode::LayerSet.new(%i[vi goal]).names.map(&:to_s))
    end

    # The payload {Grader::ToolSteering} reads: what the flip resolved to, named
    # by the same digest prompt caching keys on and the plain names beside it --
    # taken off the ARGUMENT this call was handed, never re-derived.
    it "journals the resolved toolset's digest and names" do
      switch.switch(Lain::Mode.new(posture: :auto), surface: "tty", toolset: resolved_toolset)

      record = flips.first
      expect(record["toolset_digest"]).to eq(resolved_toolset.digest)
      expect(record["tool_names"]).to eq(resolved_toolset.names)
    end
  end

  describe "what actually reaches the NDJSON line" do
    # `Canonical.normalize` refuses an unknown object loudly, but JSON.generate
    # will happily write an object's `to_s` header into the journal, producing a
    # line that PARSES while carrying garbage. Every field of this record must
    # therefore already be a String or an Array of Strings.
    it "writes names and lists, never a rendered Ruby object" do
      switch.switch(Lain::Mode.new(posture: :auto, layers: %i[goal]), surface: "tty", toolset: resolved_toolset)
      line = journal_io.string.lines.last

      expect(line).not_to include("#<")
      expect(JSON.parse(line).values_at("from", "to", "surface", "toolset_digest")).to all(be_a(String))
      expect(JSON.parse(line).values_at("from_layers", "to_layers", "tool_names").flatten).to all(be_a(String))
    end
  end

  describe Lain::Telemetry::ModeSwitch do
    subject(:record) do
      described_class.new(from: :manual, to: :auto, from_layers: %i[goal], to_layers: [], surface: :tty,
                          toolset_digest: "blake3:example", tool_names: %w[read_file])
    end

    it "journals under the discriminator readers and replay match on" do
      expect(record.journal_type).to eq("mode_switch")
    end

    it "interns every field, so the record stays shareable across a Ractor" do
      expect(record).to be_deeply_frozen
    end

    it "coerces names to Strings, whatever the caller held them as" do
      expect(record.to_journal)
        .to include("from" => "manual", "to" => "auto", "surface" => "tty", "from_layers" => %w[goal],
                    "toolset_digest" => "blake3:example", "tool_names" => %w[read_file])
    end

    it "refuses a record that names no surface -- evidence that attributes nothing is not evidence" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: nil,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /surface/)
    end

    it "refuses a record that names no posture it came from" do
      expect do
        described_class.new(from: nil, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /from/)
    end

    # The failure this exists to prevent is silent: JSON.generate writes an
    # object's `to_s` header, so a Mode handed to a name field produces a line
    # that parses and holds `#<data Lain::Mode ...>` as a posture.
    it "refuses a value that is not name-shaped, naming what it got instead" do
      mode = Lain::Mode.new(posture: :manual)

      expect do
        described_class.new(from: mode, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /from must be a name, got Lain::Mode/)
    end

    it "refuses a nil layer list rather than journaling it as an empty one" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: nil, to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /from_layers/)
    end

    # The constant is public; other call sites build one without going through
    # Mode::Switch, so the list fields cannot rely on `#flip` filling them.
    it "refuses a layer list holding something that is not a name" do
      mode = Lain::Mode.new(posture: :manual)

      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [mode], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /to_layers must be a list of layer names, got Lain::Mode in it/)
    end

    it "refuses a layer list holding a nil, which would journal as an unnamed layer" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [nil], to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /from_layers.*NilClass/)
    end

    it "refuses a bare name where a layer list belongs, rather than dying inside the record" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: "goal", surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [])
      end.to raise_error(ArgumentError, /to_layers must be a list of layer names, got String/)
    end

    # Mirrors from/to/surface's name-shaped guard: a live {Lain::Toolset} handed
    # to this field would stringify to its own `#<Lain::Toolset ...>` header,
    # not to the digest a reader could compare against a session header's.
    it "refuses a digest that names no toolset at all" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: nil, tool_names: [])
      end.to raise_error(ArgumentError, /toolset_digest/)
    end

    # The failure this exists to prevent is the same one `from` guards
    # against, one field over: JSON.generate would write the live object's
    # `to_s` header into the journal, producing a line that PARSES while
    # holding `#<Lain::Toolset ...>` as a digest -- indistinguishable from
    # a real one to anything downstream that only checks the type.
    #
    # A NON-empty Toolset, deliberately: an empty one answers `#empty?`
    # true and ActiveModel's `presence` reads that as blank, so the example
    # would raise over the presence guard instead of proving THIS one.
    it "refuses a live Toolset handed to toolset_digest, naming what it got instead" do
      live = Lain::Toolset.new(ToolRegistry.names.first(1).map { |name| ToolRegistry.build(name) })

      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: live, tool_names: [])
      end.to raise_error(ArgumentError, /toolset_digest must be a name, got Lain::Toolset/)
    end

    it "refuses a tool_names list holding something that is not a name" do
      mode = Lain::Mode.new(posture: :manual)

      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: [mode])
      end.to raise_error(ArgumentError, /tool_names must be a list of tool names, got Lain::Mode in it/)
    end

    it "refuses a nil tool_names list rather than journaling it as an empty one" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: :tty,
                            toolset_digest: "blake3:example", tool_names: nil)
      end.to raise_error(ArgumentError, /tool_names/)
    end

    # Required, with no empty-Toolset default: a default here is exactly how a
    # caller that forgot to resolve one would go on journaling a false
    # "nothing declared" set instead of failing at the construction site.
    it "raises when toolset_digest and tool_names are omitted entirely, not merely nil" do
      expect do
        described_class.new(from: :manual, to: :auto, from_layers: [], to_layers: [], surface: :tty)
      end.to raise_error(ArgumentError, /missing keyword/)
    end
  end
end
