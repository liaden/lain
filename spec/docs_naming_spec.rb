# frozen_string_literal: true

require "pathname"

# Mechanical guard over the names the living docs use for things that exist.
#
# The one it was written for is `Turn`. `Lain::Turn` was deleted in 61f7e81 --
# collapsed into `Lain::Event`, kind-tagged `:turn` -- and
# `spec/lain/event_spec.rb` asserts no such constant remains. The docs did not
# follow: `CLAUDE.md` still described the Merkle DAG as `Turn`/`Store`/
# `Timeline` and told a Rust porter to keep `Ractor.shareable?(turn)` true for a
# class that is not there, more than a year of commits after the cut. Prose
# drift is silent by construction, which is why it is worth a spec and why
# `spec/output_discipline_spec.rb` and `spec/lain/cli/chat_flags_spec.rb` exist
# in the same shape: the rule is enforced on the artifact, not restated in a
# paragraph nobody re-reads.
#
# == Why the retired name is not simply banned
#
# `ARCHITECTURE.md` says "There is no standalone `Turn` class in the current
# tree", which is the most useful sentence about `Turn` anyone could write, and
# a guard that forbade the word would delete it. So the rule is CONTEXTUAL: a
# mention of the retired name must sit beside the name that replaced it. That
# admits every honest sentence -- an explanation, a table row pointing at
# `lib/lain/event.rb`, a migration note -- and refuses the one shape that
# matters, a doc using `Turn` as if it were still a class you could reach for.
#
# The unit is the PARAGRAPH and not the line, because a line break in prose is
# wrapping rather than meaning: `CLAUDE.md`'s own correction has the two names
# on consecutive lines.
module DocsNaming
  ROOT = Pathname.new(File.expand_path("..", __dir__))

  # The docs a reader is expected to trust. `references/` and `planning/` are
  # deliberately out: the first is imported third-party material and the second
  # is a record of what was decided when, which must keep saying what it said.
  DOCS = [ROOT.join("README.md"), ROOT.join("CLAUDE.md"), ROOT.join("ARCHITECTURE.md"),
          *ROOT.glob("docs/**/*.md").sort].freeze

  # Whole-word and case-sensitive, so `TurnUsage` (a live record type), `turns`
  # and `turn` are all left alone. Only the bare constant reads as a class.
  RETIRED = /\bTurn\b/
  # Case-insensitive, so a table row naming `lib/lain/event.rb` counts as
  # context just as `Lain::Event` does.
  REPLACEMENT = /event/i

  # One paragraph that names the retired class with nothing to say it is gone.
  Drift = Struct.new(:path, :line, :snippet) do
    def to_s = "#{path}:#{line} -> #{snippet}"
  end

  module_function

  # Blank-line separated blocks, carrying the 1-based line each starts on so a
  # failure names somewhere a reader can go.
  def paragraphs(doc)
    blocks = doc.read.lines.slice_when { |before, _| before.strip.empty? }.map(&:join)
    starts = blocks.inject([1]) { |lines, block| lines << (lines.last + block.lines.size) }

    starts.first(blocks.size).zip(blocks)
  end

  def drift(doc)
    paragraphs(doc).select { |_, text| text.match?(RETIRED) && !text.match?(REPLACEMENT) }
                   .map { |line, text| Drift.new(doc.relative_path_from(ROOT), line, text.strip.lines.first.strip) }
  end
end

RSpec.describe "the living docs" do
  it "has docs to check" do
    expect(DocsNaming::DOCS).to all(be_file)
  end

  # The mirror of spec/lain/event_spec.rb's "no Lain::Turn constant remains":
  # that one holds the code to the cut, this one holds the prose to it.
  it "never names Turn as a class without saying it was replaced by Event" do
    found = DocsNaming::DOCS.flat_map { |doc| DocsNaming.drift(doc) }

    expect(found).to be_empty, lambda {
      "Lain::Turn was deleted in 61f7e81; the unit is Lain::Event, kind-tagged :turn. " \
        "These paragraphs name the retired class with no mention of Event:\n  #{found.join("\n  ")}"
    }
  end

  it "names Lain::Event in the architecture summary a contributor reads first" do
    expect(DocsNaming::ROOT.join("CLAUDE.md").read).to include("Lain::Event")
  end

  # The other half of spec/lain/cli/chat_flags_spec.rb's rule. That one refuses
  # a flag the code reads and no command declares; this refuses a VALUE the docs
  # offer and no resolver accepts -- the same drift one level in, and the reason
  # the list is read off the constant rather than transcribed.
  describe "the compaction strategies docs/commands.md offers" do
    let(:doc) { DocsNaming::ROOT.join("docs/commands.md").read }
    let(:shipped) { Lain::CLI::CompactionStrategy::STRATEGIES }

    it "names every strategy the resolver builds" do
      expect(shipped.reject { |name| doc.include?("`#{name}`") }).to be_empty
    end

    # `--compact-strategy` deliberately carries no Thor default, so "unset" is a
    # third, reachable choice and the doc has to say which it is describing.
    it "documents the unset flag as its own case rather than as a synonym for a strategy" do
      expect(doc).to match(/`--compact-strategy`/).and match(/no Thor default/)
    end
  end
end
