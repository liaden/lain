# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../.rubocop/lain"

# CopHelper and ExpectOffense are included in this group alone: rubocop/rspec/support
# includes them in every group of whichever parallel worker loads this file.
RSpec.describe RuboCop::Cop::Lain::MemoryCompactionSeparation do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  let(:root) { File.expand_path("../../../..", __dir__) }
  let(:config) do
    real = RuboCop::ConfigLoader.configuration_from_file(File.join(root, ".rubocop.yml"))
    RuboCop::Config.new(real.to_h.merge("AllCops" => real.for_all_cops.merge("DisplayCopNames" => false)),
                        real.loaded_path)
  end
  let(:ruby_version) { 3.2 }
  let(:cop) { described_class.new(config) }

  def at(path) = File.join(root, path)

  it "flags a compaction file reaching for the project memory store, and says why" do
    offenses = expect_offense(<<~RUBY, at("lib/lain/compaction/x.rb"))
      store = Memory::ProjectStore.new(project_dir:)
                      ^^^^^^^^^^^^ `ProjectStore` belongs to the other subsystem. [...]
    RUBY

    expect(offenses.map(&:message)).to all(include("compaction holds a derived view of one chain", "Sides"))
  end

  it "flags a compaction file writing a memory record, and a call to a memory tool" do
    expect_offense(<<~RUBY, at("lib/lain/compaction/head.rb"))
      journal << Telemetry.of("memory_write", item)
                              ^^^^^^^^^^^^^^ `memory_write` belongs to the other subsystem. [...]
      memory_write(item)
      ^^^^^^^^^^^^ `memory_write` belongs to the other subsystem. [...]
    RUBY
  end

  it "flags the consolidation pass reading a cut record or naming a compaction object" do
    expect_offense(<<~RUBY, at("lib/lain/cli/consolidate.rb"))
      cuts = records.select { |r| r["type"] == "compaction_cut" }
                                               ^^^^^^^^^^^^^^^^ `compaction_cut` belongs to the other subsystem. [...]
      held = Compaction::Source::HeldCut.new(session)
             ^^^^^^^^^^ `Compaction` belongs to the other subsystem. [...]
    RUBY
  end

  it "counts a symbol body and a keyword label, and never a comment" do
    expect_offense(<<~RUBY, at("lib/lain/consolidation/x.rb"))
      # Compaction is the other subsystem, and a compaction_cut is its record.
      cut(kind: :compaction_cut, compaction_cut: true)
                ^^^^^^^^^^^^^^^ `compaction_cut` belongs to the other subsystem. [...]
                                 ^^^^^^^^^^^^^^ `compaction_cut` belongs to the other subsystem. [...]
    RUBY
  end

  it "counts a method, a local variable and a parameter named for the other side" do
    expect_offense(<<~RUBY, at("lib/lain/compaction/x.rb"))
      def memory_root(memory_loaded) = memory_loaded
          ^^^^^^^^^^^ `memory_root` belongs to the other subsystem. [...]
                      ^^^^^^^^^^^^^ `memory_loaded` belongs to the other subsystem. [...]
                                       ^^^^^^^^^^^^^ `memory_loaded` belongs to the other subsystem. [...]
    RUBY
  end

  it "counts a constant assignment, a safe-navigation call and a pattern variable" do
    expect_offense(<<~RUBY, at("lib/lain/compaction/x.rb"))
      ProjectStore = 1
      ^^^^^^^^^^^^ `ProjectStore` belongs to the other subsystem. [...]
      Foo::MemoryWrite ||= 2
           ^^^^^^^^^^^ `MemoryWrite` belongs to the other subsystem. [...]
      store&.memory_write(item)
             ^^^^^^^^^^^^ `memory_write` belongs to the other subsystem. [...]
      case record
      in {memory_root:} then 1
          ^^^^^^^^^^^ `memory_root` belongs to the other subsystem. [...]
      end
    RUBY
  end

  it "ignores the prose each subsystem writes about the other" do
    expect_no_offenses(<<~RUBY, at("lib/lain/compaction/cold.rb"))
      # Nothing under `lib/lain/compaction/` reads or writes ProjectStore, and
      # a handoff's state document is never a memory_write.
      class Cold
      end
    RUBY
  end

  it "leaves each side free to name its own subsystem" do
    expect_no_offenses("Compaction::Need.new(head)\n", at("lib/lain/compaction/need.rb"))
    expect_no_offenses("Tools::MemoryWrite.new(recorder:)\n", at("lib/lain/consolidation.rb"))
  end

  it "says nothing about a file on neither side" do
    expect_no_offenses("Memory::ProjectStore.new.view\nCompaction::Source.new\n", at("lib/lain/cli/wiring.rb"))
  end

  # Each name is a reach the boundary refuses, so dropping one edits this file as well
  # and shows up in review twice.
  it "forbids exactly the reviewed names on each side" do
    sides = config.for_cop("Lain/MemoryCompactionSeparation")["Sides"]

    expect(sides.transform_values { |rule| rule.fetch("Forbidden") }).to eq(
      "compaction" => %w[ProjectStore MemoryRead MemoryWrite memory_loaded memory_root memory_write],
      "the consolidation pass" => %w[Compaction CompactionCut compaction_cut]
    )
  end

  # Every rule here is an absence, so a renamed directory or a moved command would
  # leave the cop green over nothing at all.
  it "covers the files each side was written for, so it cannot pass by vacuum" do
    sides = config.for_cop("Lain/MemoryCompactionSeparation")["Sides"]
    covered = lambda do |side|
      Dir.glob("lib/**/*.rb", base: root).select do |path|
        sides.fetch(side).fetch("Files").any? { |glob| RuboCop::PathUtil.match_path?(glob, path) }
      end
    end

    expect(covered.call("compaction"))
      .to include("lib/lain/compaction.rb", "lib/lain/compaction/source.rb", "lib/lain/compaction/strategy.rb")
    expect(covered.call("the consolidation pass"))
      .to include("lib/lain/cli/consolidate.rb", "lib/lain/cli/improve.rb", "lib/lain/consolidation.rb")
  end
end
