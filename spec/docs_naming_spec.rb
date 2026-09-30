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
      expect(doc).to include("`--compact-strategy`").and include("no Thor default")
    end
  end

  # The same rule as the compaction strategies above, one level further in. A
  # config key a reader accepts and the docs never name is a knob nobody can
  # find, and a default restated in prose is the one that drifts from the
  # constant it copies -- so both the keys and their defaults are read off the
  # readers rather than transcribed here.
  describe "the config tables docs/commands.md documents" do
    let(:doc) { DocsNaming::ROOT.join("docs/commands.md").read }

    it "names every [isolation] key beside the default the reader falls back to" do
      Lain::Config::Isolation::DEFAULTS.each do |key, default|
        expect(doc).to include("`#{key}`"), "docs/commands.md never names the [isolation] key #{key}"
        expect(doc).to include("`#{default}`"),
                       "docs/commands.md names #{key} without its default, #{default}"
      end
    end

    # `TestLayout` keeps only `PRESET` and `KEYS` private, so the key list is
    # read off the Data members -- which are exactly that key set -- while
    # `PRESETS` is public and is read straight off the constant. Both halves are
    # derived rather than transcribed, which is what makes this a guard: a
    # preset or a key added to the code goes red here until the doc offers it.
    it "names every [tests] key and every preset the table accepts" do
      Lain::TestLayout.members.each do |key|
        expect(doc).to include("`#{key}`"), "docs/commands.md never names the [tests] key #{key}"
      end

      Lain::TestLayout::PRESETS.each_key do |preset|
        expect(doc).to include("`#{preset}`"), "docs/commands.md never names the #{preset} preset"
      end
    end

    # The fact a table of keys cannot carry, and the one a reader most needs:
    # `TestLayout::None` refuses nothing, so a project that declares no tests
    # table is held to no layout at all. A doc that listed the keys without
    # saying this would read as though the guard were on by default.
    it "says layout enforcement is opt-in, so no tests verb refuses nothing" do
      expect(doc).to include("no `tests` verb").and match(/opt-in/i)
    end
  end

  describe "the commands docs/commands.md documents" do
    let(:doc) { DocsNaming::ROOT.join("docs/commands.md").read }

    # Derived from the command objects the registry actually holds, so a rename
    # goes red here rather than leaving a section nobody can reach by typing it.
    it "gives each session command this chunk registered its own section" do
      [Lain::CLI::Command::Undo.new, Lain::CLI::Command::ImplementEpic.new].each do |command|
        expect(doc).to include("### /#{command.name}"),
                       "docs/commands.md has no section for /#{command.name}"
      end
    end

    # The shell verbs are declared in `exe/lain`, which is a script rather than
    # a loadable constant, so these are literal -- the compensating guard is
    # that each one is spelled exactly as `lain <verb> help` prints it.
    it "documents the shell commands this chunk added, with the flags they read" do
      ["lain worktrees gc", "lain epic add", "lain epic split", "lain epic merge",
       "lain epic land", "lain epic finish", "--mermaid", "--into", "--as",
       "--discovered-from", "--width"].each do |named|
        expect(doc).to include("`#{named}`").or(include(named)),
                       "docs/commands.md never names #{named}"
      end
    end

    # `/undo skip` is the remedy a refused undo offers by name, so a doc that
    # described `/undo` without it would leave the reader stuck at the refusal.
    it "names the skip form the refusal points at" do
      expect(doc).to include("/undo skip")
    end

    # `lain epic land ISSUE SHA` was REMOVED: the commit is found from the
    # anchor the implementation gate already approved, never named on the
    # command line, so a sha nobody approved is unrepresentable rather than
    # merely refused. A doc still offering it teaches a command that refuses.
    it "does not offer the retired SHA argument to lain epic land" do
      expect(doc).not_to match(/lain epic land \S+ SHA/)
    end
  end
end
