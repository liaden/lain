# frozen_string_literal: true

require "ripper"
require "pathname"

# Project memory and compaction are two subsystems, and NEITHER reads the other.
# Project memory is durable fact, written on purpose with `memory_write` or by
# `lain consolidate`, shared by every chat in the project. Compaction is a
# derived, rebuildable view of ONE chat's own history, and its cuts -- an
# advance, a collapse, a handoff's state document -- are replaceable the moment
# the chain moves.
#
# The two directions that cannot be pinned by a behavioural spec are structural,
# because each is the ABSENCE of a reach:
#
#   * nothing under `lib/lain/compaction/` may name {Lain::Memory::ProjectStore}
#     or a memory record, or a handoff's state document becomes durable project
#     fact that no later chat can un-remember;
#   * nothing in the consolidation pass may read a `compaction_cut` or a
#     `Compaction::` object, or a clerk would distill a SUMMARY of a chat into
#     memory and cite it as what the chat said.
#
# An absence cannot fail a unit spec: the code that would break the rule is the
# code nobody has written yet. So the tree itself is the subject, and
# `spec/provider_construction_discipline_spec.rb` is the precedent for how --
# a reading half that knows only syntax, a policy half that knows only the rule,
# and fixtures for both so the guard can still be shown to bite.
#
# == Why the source is lexed and not grepped
#
# The two subsystems describe each other in PROSE, deliberately:
# `memory/project_store.rb`'s own docstring states the very rule enforced here,
# and the consolidation pass explains what it is not. A text match would fail on
# the sentences that document the boundary, so the source goes through Ripper's
# lexer and comments are dropped before any name is compared.
module MemoryCompactionSeparation
  # Project memory's names as they appear in CODE: the durable store, the two
  # tools that reach it, and the three record types a session file carries for
  # it ({Lain::Bench::Session::MemoryReplay} owns the last two spellings).
  MEMORY_NAMES = %w[ProjectStore MemoryRead MemoryWrite
                    memory_loaded memory_root memory_write].freeze

  # Compaction's names: the namespace, its cut carrier, and the record type a
  # session file carries for one.
  COMPACTION_NAMES = %w[Compaction CompactionCut compaction_cut].freeze

  # One side of the boundary: the files it covers, and what it may not name.
  # A prefix ending in `/` is a subtree; anything else is one file.
  Side = Data.define(:name, :holds, :prefixes, :names) do
    def covers?(path) = prefixes.any? { |prefix| prefix.end_with?("/") ? path.start_with?(prefix) : path == prefix }

    def forbids?(token) = names.include?(token)
  end

  SIDES = [
    Side.new(name: "compaction", holds: "a derived view of one chain",
             prefixes: %w[lain/compaction.rb lain/compaction/].freeze, names: MEMORY_NAMES),
    Side.new(name: "the consolidation pass", holds: "durable project fact",
             prefixes: %w[lain/consolidation.rb lain/consolidation/
                          lain/cli/consolidate.rb lain/cli/improve.rb].freeze,
             names: COMPACTION_NAMES)
  ].freeze

  # One forbidden name, where it was read.
  Mention = Data.define(:path, :line, :name, :side) do
    def to_s = "#{path}:#{line} names #{name}, which belongs to the other subsystem"
  end

  # The token kinds a name can be read from: a constant, an identifier (which
  # is also how a symbol's body lexes), a string's content, and a keyword
  # label. A label carries its own colon, stripped below so `compaction_cut:`
  # compares as the record it names.
  NAME_TOKENS = %i[on_const on_ident on_tstring_content on_label].freeze

  module_function

  def lib_root = Pathname(__dir__).join("..", "lib").expand_path

  # `{ path relative to lib/ => source }`. Taking the tree as data is what lets
  # the policy below be exercised against literal fixtures.
  def lib_sources(root = lib_root)
    root.glob("**/*.rb").to_h { |file| [file.relative_path_from(root).to_s, file.read] }
  end

  # @return [Array<String>] every name read from code in this source, with
  #   comments and their prose dropped by the lexer
  def names_in(source)
    Ripper.lex(source).filter_map do |(line, _column), type, token, _state|
      [line, token.delete_suffix(":")] if NAME_TOKENS.include?(type)
    end
  end

  def mentions(path, source)
    side = SIDES.find { |candidate| candidate.covers?(path) }
    return [] if side.nil?

    names_in(source).filter_map do |line, name|
      Mention.new(path:, line:, name:, side:) if side.forbids?(name)
    end
  end

  def violations(sources = lib_sources)
    sources.flat_map { |path, source| mentions(path, source) }
  end

  # What each side actually covers in the tree. A rule over a directory nobody
  # writes to any more passes by vacuum, so the scope is asserted rather than
  # assumed.
  def covered(side, sources = lib_sources) = sources.keys.select { |path| side.covers?(path) }.sort
end

RSpec.describe "memory and compaction separation discipline" do
  describe "the tree as it stands" do
    it "keeps each subsystem clear of the other's names" do
      violations = MemoryCompactionSeparation.violations

      expect(violations).to be_empty, lambda {
        listing = violations.map { |mention| "  #{mention}" }.join("\n")
        "Project memory and compaction are separate subsystems and neither reads the other. Found:\n" \
          "#{listing}\n" \
          "A handoff's state document is never a memory item, and a consolidation clerk reads the " \
          "chat's own turns, never a cut's replacement text. If the reach is genuinely needed, the " \
          "boundary is what has to be argued -- not this list."
      }
    end

    it "covers the files the rule was written for, so it cannot pass by vacuum" do
      # Every rule above is stated as an ABSENCE, so a renamed directory or a
      # moved command would leave the guard green over nothing at all.
      compaction, consolidation = MemoryCompactionSeparation::SIDES

      expect(MemoryCompactionSeparation.covered(compaction))
        .to include("lain/compaction.rb", "lain/compaction/source.rb", "lain/compaction/strategy.rb")
      expect(MemoryCompactionSeparation.covered(consolidation))
        .to include("lain/cli/consolidate.rb", "lain/cli/improve.rb", "lain/consolidation.rb")
    end
  end

  describe "the reading half" do
    def mentions_in(source, path) = MemoryCompactionSeparation.mentions(path, source)

    it "reports a compaction file reaching for the project memory store" do
      found = mentions_in("store = Memory::ProjectStore.new(project_dir:)\n", "lain/compaction/source.rb")

      expect(found.map(&:to_s))
        .to eq(["lain/compaction/source.rb:1 names ProjectStore, which belongs to the other subsystem"])
    end

    it "reports a compaction file writing a memory record" do
      found = mentions_in(%(journal << Telemetry.of("memory_write", item)\n), "lain/compaction/head.rb")

      expect(found.map(&:name)).to eq(["memory_write"])
    end

    it "reports the consolidation pass reading a cut record" do
      found = mentions_in(%(cuts = records.select { |r| r["type"] == "compaction_cut" }\n),
                          "lain/cli/consolidate.rb")

      expect(found.map(&:to_s))
        .to eq(["lain/cli/consolidate.rb:1 names compaction_cut, which belongs to the other subsystem"])
    end

    it "reports the consolidation pass naming a compaction object" do
      expect(mentions_in("held = Compaction::Source::HeldCut.new(session)\n", "lain/consolidation.rb").map(&:name))
        .to eq(["Compaction"])
    end

    it "reads a name out of a keyword label and a symbol as well as a constant" do
      found = mentions_in("cut(kind: :compaction_cut, compaction_cut: true)\n", "lain/cli/improve.rb")

      expect(found.map(&:name)).to eq(%w[compaction_cut compaction_cut])
    end

    it "ignores the prose each subsystem writes about the other" do
      # The rule this file enforces is STATED in a docstring on the very class
      # the rule protects. A text match would fail on the documentation.
      source = <<~RUBY
        # Nothing under `lib/lain/compaction/` reads or writes ProjectStore, and
        # a handoff's state document is never a memory_write.
        class Cold
        end
      RUBY

      expect(mentions_in(source, "lain/compaction/cold.rb")).to be_empty
    end

    it "leaves each side free to name its OWN subsystem" do
      expect(mentions_in("Compaction::Need.new(head)\n", "lain/compaction/need.rb")).to be_empty
      expect(mentions_in("Tools::MemoryWrite.new(recorder:)\n", "lain/consolidation.rb")).to be_empty
    end

    it "says nothing about a file on neither side" do
      expect(mentions_in("Memory::ProjectStore.new.view\nCompaction::Source.new\n", "lain/cli/wiring.rb"))
        .to be_empty
    end
  end
end
