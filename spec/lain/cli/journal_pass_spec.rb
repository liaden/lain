# frozen_string_literal: true

# exe/lain is a script, not a lib file: this `load` defines the Thor class
# WITHOUT parsing rspec's ARGV or touching the network (spec/lain/cli_spec.rb's
# seam).
load File.expand_path("../../../exe/lain", __dir__)

# T25 review probe, kept as a spec. `--dry-run` no longer travels into the pass
# as a boolean; it picks a METHOD at the boundary, in exe/lain's private
# `journal_pass`. That is the right shape -- but it moved the ONE decision that
# separates "spend money on a model" from "print a plan" out of a spec'd lib
# object and into an unspec'd script, and nothing pinned it: inverting the
# ternary, or dropping it entirely so a `--dry-run` always spawns, left the whole
# suite green.
#
# So the dispatch itself is the subject here. A dry pass reaching a model is the
# card's whole thesis, and {Lain::Provider::Unreachable} only refuses at the
# provider -- it cannot refuse a boundary that called the wrong method with a
# REAL provider wired behind it.
RSpec.describe "exe/lain journal_pass" do
  # The pass duck both `consolidate` and `improve` hand to `journal_pass`:
  # records which method the boundary chose, spawning nothing either way.
  let(:pass) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def report(selector) = tap { @calls << [:report, selector] }.then { "live #{selector}" }
      def dry_report(selector) = tap { @calls << [:dry_report, selector] }.then { "dry #{selector}" }
    end.new
  end

  # `journal_pass` is private and reads Thor's `options`, so it is exercised on a
  # CLI instance built with the options hash Thor would have parsed -- the same
  # plain-hash seam Backend and Wiring are tested through.
  def dispatch(pass, selector, **options)
    LainCLI.new([], options).send(:journal_pass, pass, selector)
  end

  it "picks #dry_report when --dry-run is set, so nothing can reach a model" do
    expect(dispatch(pass, "s1", dry_run: true)).to eq("dry s1")
    expect(pass.calls).to eq([[:dry_report, "s1"]])
  end

  it "picks #report when --dry-run is absent, so a live run is not silently dry" do
    expect(dispatch(pass, "s1", dry_run: false)).to eq("live s1")
    expect(pass.calls).to eq([[:report, "s1"]])
  end

  it "forwards the selector unchanged, so the boundary resolves nothing itself" do
    dispatch(pass, "/tmp/elsewhere/kept.ndjson", dry_run: true)

    expect(pass.calls.first.last).to eq("/tmp/elsewhere/kept.ndjson")
  end
end
