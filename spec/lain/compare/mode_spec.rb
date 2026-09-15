# frozen_string_literal: true

require "stringio"

# What a run's mode IS, given a journal: the trajectory it was in, since a mode
# can be switched mid-run and neither end of that switch describes what produced
# the outcome on its own. The mode is a comparison AXIS -- the same kind of fact
# Capability::Guard already refuses to cross -- so this covers both halves:
# reading a trajectory off a journal, and refusing two that disagree.
RSpec.describe Lain::Compare::Mode do
  # Each flip as `[from_approval, to_approval]`, or `[from, to, layers]` for a
  # flip that also turns layers on; the scope is the checkout throughout.
  def journaled(*flips)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    flips.each do |from, to, layers = []|
      journal.record(Lain::Telemetry::ModeSwitch.new(from_scope: :checkout, to_scope: :checkout,
                                                     from_approval: from, to_approval: to,
                                                     from_layers: [], to_layers: layers, surface: "tty"))
    end
    described_class.from_journal(io.string.lines)
  end

  it "reads the mode a run switched into off its mode_switch records" do
    expect(journaled(%w[ask auto]).to_s).to eq("checkout/ask → checkout/auto")
  end

  it "is unrecorded when the journal holds no mode record" do
    mode = journaled
    expect(mode.to_s).to eq("not recorded")
    expect(mode).to eq(described_class::UNRECORDED)
  end

  # A flip that moves only a layer is journaled, but the point on the axis never
  # moved, and an axis that reported "checkout/ask → checkout/ask" would be
  # reporting the flip rather than the run.
  it "collapses a flip that moved only a layer: the point in force never moved" do
    expect(journaled(["ask", "ask", %w[vi]]).to_s).to eq("checkout/ask")
  end

  it "refuses a run that switched against one that stayed put" do
    switched = journaled(%w[ask auto])
    expect { described_class.guard!(switched, described_class.for("checkout/auto")) }
      .to raise_error(Lain::Error, %r{checkout/ask → checkout/auto})
  end

  it "compares two runs that took the same trajectory" do
    expect(journaled(%w[ask auto])).to eq(journaled(%w[ask auto]))
  end

  it "reads a Mode as its point, so a caller may hold the value it switched" do
    expect(described_class.for(Lain::Mode.new(approval: :auto, layers: %i[vi])))
      .to eq(described_class.for("checkout/auto"))
  end

  # Reading only the `to`s after the first record would answer a plausible
  # trajectory that never happened, on the experiment record. Interleaved
  # records are ordinary the moment fan-out has more than one worker writing.
  it "refuses records that do not chain, rather than inventing a trajectory" do
    damaged = [{ "type" => "mode_switch", "from_scope" => "checkout", "from_approval" => "ask",
                 "to_scope" => "checkout", "to_approval" => "auto" },
               { "type" => "mode_switch", "from_scope" => "checkout", "from_approval" => "ask",
                 "to_scope" => "checkout", "to_approval" => "auto" }]
    expect { described_class.from_journal(damaged) }
      .to raise_error(Lain::Error, %r{in checkout/auto cannot switch from checkout/ask})
  end

  # The loader reads the new shape only: a record naming a side by the words a
  # retired vocabulary used is refused, never read as a blank point.
  it "refuses a record that carries no scope and approval on a side" do
    expect { described_class.from_journal([{ "type" => "mode_switch", "from" => "manual", "to" => "auto" }]) }
      .to raise_error(Lain::Error, /from_scope and from_approval/)
  end

  it "refuses a point naming a level that is not declared" do
    expect { described_class.for("checkout/manual") }.to raise_error(ArgumentError, /manual.*ask.*auto/m)
  end

  it "refuses a name that is not written as a point at all" do
    expect { described_class.for(:auto) }.to raise_error(ArgumentError, %r{scope/approval})
  end

  # An empty list of points IS absence, and a Recorded holding none would be
  # the value this whole file exists to not have: it renders as the empty
  # String and agrees with nothing, not even another empty one.
  it "answers absence for no names at all, never an empty trajectory" do
    expect(described_class.for).to eq(described_class::UNRECORDED)
    expect(described_class.coerce([])).to eq(described_class::UNRECORDED)
  end

  it "skips foreign lines, as every journal reader does" do
    expect(described_class.from_journal(['{"type":"turn_usage"}', "not json at all"]))
      .to eq(described_class::UNRECORDED)
  end

  it "is Ractor-shareable, recorded or not" do
    expect(described_class.for("checkout/auto")).to be_deeply_frozen
    expect(described_class::UNRECORDED).to be_deeply_frozen
  end
end
