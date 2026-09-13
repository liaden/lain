# frozen_string_literal: true

require "stringio"

# What a run's posture IS, given a journal: the trajectory it was in, since a
# mode can be switched mid-run and neither end of that switch describes what
# produced the outcome on its own. The posture is a comparison AXIS -- the same
# kind of fact Capability::Guard already refuses to cross -- so this covers both
# halves: reading a trajectory off a journal, and refusing two that disagree.
RSpec.describe Lain::Compare::Posture do
  # `toolset:` a fresh empty Toolset named HERE: nothing this describe block
  # tests is about what any of these flips resolved to, only about the
  # trajectory their from/to pairs describe.
  def journaled(*flips)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    toolset = Lain::Toolset.new
    flips.each do |from, to|
      journal.record(Lain::Telemetry::ModeSwitch.new(from:, to:, from_layers: [], to_layers: [], surface: "tty",
                                                     toolset_digest: toolset.digest, tool_names: toolset.names))
    end
    described_class.from_journal(io.string.lines)
  end

  it "reads the posture a run switched into off its mode_switch records" do
    expect(journaled(%w[manual auto]).to_s).to eq("manual → auto")
  end

  it "is unrecorded when the journal holds no mode record" do
    posture = journaled
    expect(posture.to_s).to eq("not recorded")
    expect(posture).to eq(described_class::UNRECORDED)
  end

  # A switch to the posture already in force is journaled on purpose, so a
  # transcript shows the redundant request -- but the posture never moved, and
  # an axis that reported "plan → plan" would be reporting the request rather
  # than the run.
  it "collapses a redundant switch: the posture in force never moved" do
    expect(journaled(%w[plan plan]).to_s).to eq("plan")
  end

  it "refuses a run that switched against one that stayed put" do
    switched = journaled(%w[manual auto])
    expect { described_class.guard!(switched, described_class.for(:auto)) }
      .to raise_error(Lain::Error, /manual → auto/)
  end

  it "compares two runs that took the same trajectory" do
    expect(journaled(%w[manual auto])).to eq(journaled(%w[manual auto]))
  end

  # Reading only the `to`s after the first record would answer
  # "plan → manual → plan" for this: a plausible trajectory that never
  # happened, on the experiment record. Interleaved records are ordinary the
  # moment fan-out has more than one worker writing.
  it "refuses records that do not chain, rather than inventing a trajectory" do
    damaged = [{ "type" => "mode_switch", "from" => "plan", "to" => "manual" },
               { "type" => "mode_switch", "from" => "auto", "to" => "plan" }]
    expect { described_class.from_journal(damaged) }
      .to raise_error(Lain::Error, /\bmanual\b.*\bauto\b/m)
  end

  # An empty list of postures IS absence, and a Recorded holding none would be
  # the fifth value this whole file exists to not have: it renders as the
  # empty String and agrees with nothing, not even another empty one.
  it "answers absence for no names at all, never an empty trajectory" do
    expect(described_class.for).to eq(described_class::UNRECORDED)
    expect(described_class.coerce([])).to eq(described_class::UNRECORDED)
  end

  it "skips foreign lines, as every journal reader does" do
    expect(described_class.from_journal(['{"type":"turn_usage"}', "not json at all"]))
      .to eq(described_class::UNRECORDED)
  end

  it "is Ractor-shareable, recorded or not" do
    expect(described_class.for(:plan)).to be_deeply_frozen
    expect(described_class::UNRECORDED).to be_deeply_frozen
  end
end
