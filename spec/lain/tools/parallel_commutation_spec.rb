# frozen_string_literal: true

require "fileutils"

# Fixtures kept out of any RSpec block (Lint/ConstantDefinitionInBlock): the
# deterministic workspace the sweep reads, one fixed input per tool, and the
# instance table the pairs are drawn from.
module ParallelCommutationSpecSupport
  # The only true-set tool this sweep does not range over. `subagent` spawns a
  # whole child agent loop -- a Timeline root, a provider round trip, its own
  # toolset -- so its result is not a read of anything this workspace holds and
  # two spawns are not two reads whose order could be exchanged. Its
  # parallel_safe? claim rests on the child's isolation (a FRESH Timeline root,
  # nothing shared with the parent's), which is a different property, pinned
  # where subagent's own isolation is: spec/lain/tools/subagent_spec.rb.
  SPAWNS_INSTEAD_OF_READING = %w[subagent].freeze

  # The workspace, written fresh per example. Small on purpose: every pair
  # re-reads it, so the sweep's cost is 45 pairs x 2 orders x 2 tools of
  # whatever this costs. Symlink-free (see {.write_fixture}'s note on realpath)
  # because two of the readers -- grep and ast_search -- cap their output and
  # therefore depend on WALK ORDER for WHICH matches come back (see the
  # walk-order note on {Lain::Tools::Grep}).
  FILES = {
    "alpha.rb" => <<~'RUBY',
      # frozen_string_literal: true

      module Fixture
        class Alpha
          def initialize(name)
            @name = name
          end

          def greet
            "hello, #{@name}"
          end

          def self.build(name)
            new(name)
          end
        end
      end
    RUBY
    "nested/beta.rb" => <<~RUBY,
      # frozen_string_literal: true

      module Fixture
        class Beta
          def total(items)
            items.sum
          end
        end
      end
    RUBY
    "notes.txt" => <<~TEXT
      alpha and beta are the fixture sources.
      this file defines nothing at all.
    TEXT
  }.freeze

  # The snippet the two snippet-only tools parse. Held here rather than inlined
  # so ast_dump and test_pattern demonstrably read the SAME source.
  SNIPPET = <<~RUBY
    class Snippet
      def run(argument)
        argument
      end
    end
  RUBY

  # One fixed input per tool, string-keyed as a tool_use block's `input` is
  # post-Canonical.normalize. Each is chosen to exercise that tool's OK path
  # over the fixture (see the anti-vacuity example): a directory walk where the
  # tool takes a directory, one named file where it takes a file, an in-memory
  # snippet where it takes source text.
  INPUTS = {
    "read_file" => { "path" => "alpha.rb" },
    "list_files" => { "path" => ".", "recursive" => true },
    "glob" => { "pattern" => "**/*.rb" },
    "grep" => { "pattern" => "def ", "path" => "." },
    "ast_search" => { "language" => "ruby", "path" => ".", "query" => "method_def" },
    "code_outline" => { "path" => "alpha.rb", "language" => "ruby" },
    "file_symbols" => { "path" => "alpha.rb", "language" => "ruby" },
    "ast_dump" => { "code" => SNIPPET, "language" => "ruby" },
    "test_pattern" => { "pattern" => "def $NAME($$$A)", "code" => SNIPPET, "language" => "ruby" },
    "memory_read" => { "id" => "dosage" }
  }.freeze

  PAIRS = INPUTS.keys.combination(2).to_a.freeze

  # What one order of one pair leaves behind: the tool_result content and
  # is_error per tool (gate 4's other two keys are the block's type and the
  # tool_use id, which are wire bookkeeping, not the tool's answer), plus the
  # observable Session state.
  Outcome = Data.define(:results, :reads)

  MEMORY_ITEM = Lain::Memory::Item.new(
    id: "dosage",
    description: "Adult dosage guidance for the trial drug",
    body: "500mg twice daily with food.\nHalve for renal impairment."
  )

  # Instances come from {ToolRegistry.build} -- the same real-instance table
  # parallel_safety_spec.rb asks #parallel_safe? of -- with ONE substitution,
  # for two reasons.
  #
  # CONTENT: the registry's memory_read holds an EMPTY index, so every id it is
  # given takes the "no memory with id" error path. An error Result is still a
  # result the law ranges over, but it exercises nothing this sweep looks for,
  # so this instance holds one item and {INPUTS} names its id.
  #
  # SHAPE: it is handed a {Memory::Recorder}, not a bare {Memory::Index}, because
  # that is what SHIPS -- `Wiring::BaseTools.build` passes the session's Recorder
  # (`cli/wiring/base_tools.rb:18`), the same MUTABLE holder memory_write writes
  # through, and Recorder delegates #fetch to its current snapshot so it satisfies
  # the same duck. This matters here specifically: {Tools::MemoryRead#parallel_safe?}
  # justifies itself with "@index is a FROZEN Memory::Index snapshot injected at
  # construction", which is true of a bare Index and NOT true of the shipped
  # wiring. Nothing is live today -- memory_write is parallel_safe? => false, so
  # {Agent::ToolRunner#contiguous_runs} isolates it as a barrier -- but that is a
  # RUNNER guarantee, not the guarantee the tool's own comment claims, and a sweep
  # over the real toolset is exactly where the two should be told apart.
  #
  # A Hash of thunks, not a branch, for {ToolRegistry::BUILDERS}' own reason.
  OVERRIDES = {
    "memory_read" => lambda {
      Lain::Tools::MemoryRead.new(index: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty.write(MEMORY_ITEM)))
    }
  }.freeze

  def self.build_tool(name)
    OVERRIDES.fetch(name) { -> { ToolRegistry.build(name) } }.call
  end

  # The true-set as the shipped toolset actually declares it, asked of the same
  # roster {ToolRegistry.shipped_names} enumerates: a tool that ships and opts
  # in without being named in {INPUTS} fails the coverage example BY NAME, and
  # one that ships without a builder at all fails there loudly too.
  def self.shipped_parallel_safe_names
    ToolRegistry.shipped_names.select { |name| ToolRegistry.build(name).parallel_safe? }
  end

  # Writes {FILES} under `root` and answers it back, so a caller can build the
  # workspace in one expression. `root` arrives already realpath'd (see the
  # `let` that calls this): /tmp is a symlink on some hosts, and a resolved root
  # is what keeps the read-set's File.expand_path identity and the tools' own
  # path resolution talking about the same string.
  def self.write_fixture(root)
    FILES.each do |relative, content|
      path = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    root
  end

  # The paths the read-set is probed at. {Lain::Session} exposes no reader for
  # its read-set -- only #read? -- so "the same recorded reads" is asked as
  # "the same answer for every file in the workspace", which over a closed
  # fixture is the same statement.
  def self.fixture_paths(root)
    FILES.keys.map { |relative| File.join(root, relative) }
  end
end

# The law {Lain::Tool#parallel_safe?} claims and nothing tested: for tools that
# opt in, the result is independent of the order they ran in -- pairwise
# COMMUTATION of tool results, the same word this repo already uses for
# {Lain::Algebra::CommutativeMonoid} and spec/support/shared_examples/monoid.rb,
# spelled here over a relation rather than an operation (there is no binary
# combine to register a structure for; the claim is that running a then b and
# running b then a land in the same state). That commutativity is the licence
# {Lain::Agent::ToolRunner#gather} takes when it fans a contiguous run of
# opted-in tools out as sibling tasks: concurrency is only sound if every
# interleaving agrees, and pairwise exchange is what says so.
#
# Each order runs as two SINGLE-tool_use responses back-to-back, never one
# two-use response: a run of one gathers nothing (ToolRunner#gatherable? wants
# size > 1), so both orders are genuinely serial and therefore deterministic.
# Building one two-use response per order would instead hand both orders to
# #gather, and comparing two concurrent fan-outs proves nothing about order --
# it is the timing-based probe parallel_safety_spec.rb's GatedFakeTool exists to
# avoid.
RSpec.describe "Tool#parallel_safe?: the exchange law, i.e. pairwise commutation" do
  # ---- Scenario: the suite tracks the shipped true-set ----------------------
  #
  # Deliberately OUTSIDE the fixture group below: this example reads no files,
  # so it must not pay for a workspace it never opens.

  describe "coverage of the shipped true-set" do
    it "sweeps every parallel_safe? tool the toolset ships, bar the spawning one" do
      support = ParallelCommutationSpecSupport
      declared = (support::INPUTS.keys + support::SPAWNS_INSTEAD_OF_READING).sort
      expect(declared).to eq(support.shipped_parallel_safe_names.sort)
    end
  end

  describe "over a deterministic fixture workspace" do
    # One workspace per example, memoized so BOTH orders of a pair read the same
    # bytes -- which is the whole comparison. Per example rather than per context
    # because a fixture shared across examples is state that leaks; three small
    # files cost nothing next to that.
    let(:root) do
      ParallelCommutationSpecSupport.write_fixture(File.realpath(Dir.mktmpdir("lain-parallel-commutation")))
    end

    after { FileUtils.remove_entry(root) }

    # A fresh Session and fresh instances per order, so nothing an order leaves
    # behind can reach the other and mask a real dependence.
    def run_order(names)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {}))
      runner = build_runner(names)
      results = names.to_h { |name| [name, answer(runner, session, name)] }
      ParallelCommutationSpecSupport::Outcome.new(results:, reads: read_set(session))
    end

    def build_runner(names)
      toolset = Lain::Toolset.new(names.map { |name| ParallelCommutationSpecSupport.build_tool(name) })
      Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new(toolset:))
    end

    def answer(runner, session, name)
      response = tool_response(["tu_#{name}", name, ParallelCommutationSpecSupport::INPUTS.fetch(name)])
      runner.run(response, context: session).fetch(0).slice("content", "is_error")
    end

    def read_set(session)
      ParallelCommutationSpecSupport.fixture_paths(root).select { |path| session.read?(path) }
    end

    # ---- Scenario: every parallel-safe pair commutes on results --------------
    # ---- Scenario: the read-set is order-independent -------------------------

    ParallelCommutationSpecSupport::PAIRS.each do |(left, right)|
      describe "#{left} beside #{right}" do
        let(:forward) { run_order([left, right]) }
        let(:reverse) { run_order([right, left]) }

        it "answers each tool identically in either order" do
          expect(forward.results).to eq(reverse.results)
        end

        it "leaves the same Session read-set in either order" do
          expect(forward.reads).to eq(reverse.reads)
        end
      end
    end

    # Both scenarios above compare one order against the other, and a comparison
    # is only a test of its subject while the things compared have content. These
    # two examples are what supply it. NEITHER IS REDUNDANT -- each was written
    # against a mutation that left all 90 comparisons green:
    describe "the anchors that keep those comparisons from holding vacuously" do
      let(:sweep) { run_order(ParallelCommutationSpecSupport::INPUTS.keys) }

      # Ten tools all FAILING identically in both orders satisfies the law and
      # tests nothing, so every fixed input must reach its tool's OK path.
      it "drives every swept tool down its ok path, so no pair commutes on two errors" do
        expect(sweep.results.reject { |_name, answer| answer.fetch("is_error") == false }).to eq({})
      end

      # The read-set half's anchor, and the sharper of the two. Only the 9 pairs
      # containing read_file observe a read at all; the other 36 compare [] to
      # [] and hold however broken read-set observation is. A review probe that
      # redefined Session#read? to answer FALSE OUTRIGHT left all 92 examples
      # green -- the scenario was live (a tool recording conditionally on session
      # state does fail it) but unanchored. Naming the exact path the ok-path run
      # must have recorded is what makes those 45 comparisons statements about
      # reads. Delete this and the read-set scenario silently stops testing its
      # subject.
      it "records exactly the one file read_file opened, so the read-set is a real observation" do
        expect(sweep.reads).to eq([File.join(root, "alpha.rb")])
      end
    end
  end
end
