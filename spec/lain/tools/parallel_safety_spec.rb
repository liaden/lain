# frozen_string_literal: true

require "async"

# E1's fixtures, kept out of any RSpec block (Lint/ConstantDefinitionInBlock):
# a fake tool for the concurrency probe, plus the full toolset partition as
# data -- a Hash of builder thunks is what keeps #build_tool a lookup, not a
# branch, however many tools the toolset grows to.
module ParallelSafetySpecSupport
  # Announces its own start onto `entered` the instant #perform begins, then
  # parks on `release` before returning -- the entered/release Async::Queue
  # idiom this suite already uses for supervisor concurrency probes (see
  # spec/lain/supervisor_spec.rb). This is deterministic where real file IO is
  # not: a read that happens to complete inside one scheduler tick, with no
  # yield point, would "pass" a timing-based probe whether or not ToolRunner
  # actually gathered it. Here, neither fake can return until BOTH have
  # announced entry, so the claim under test -- both dispatches BEGIN before
  # either RESOLVES -- is enforced by construction, not inferred from a clock.
  class GatedFakeTool < Lain::Tool
    def initialize(name:, entered:, release:)
      super()
      @tool_name = name
      @entered = entered
      @release = release
    end

    def name = @tool_name
    def description = "test double: announces entry on `entered`, then parks on `release`"
    def input_schema = { type: :object, properties: {} }
    def parallel_safe? = true

    protected

    def perform(_input, _context)
      @entered.enqueue(@tool_name)
      @release.dequeue
      Lain::Tool::Result.ok(@tool_name)
    end
  end

  # Every tool this card opts in. `subagent` was already true before this card
  # (Tool#parallel_safe?'s prior only opt-in); the other ten are this card's
  # audit -- reads only, no Session write-set mutation, no process-global
  # state (see each tool file's own WHY comment).
  TRUE_TOOLS = %w[read_file list_files glob grep memory_read
                  ast_search ast_dump test_pattern code_outline file_symbols
                  subagent].freeze

  # Every OTHER tool the toolset actually ships (exe/lain's `base_tools` plus
  # the subagent/ask_human/run_skill layered on top, and tool_search, which
  # {Toolset::Disclosure::Deferred} constructs separately): a model-controlled
  # command string (bash, and core_exec -- C3's approval-gated tier-3
  # comparison arm over the lain-core boundary, constructed explicitly rather
  # than shipped in base_tools), a Session write-set mutation (edit_file,
  # write_file, todo_write, memory_write), M2's `improvement_write` (NOT a
  # Session write-set mutation -- it never touches Session at all -- but a
  # durable, ORDERED cross-process append via {Improvement::Sink}: concurrent
  # dispatch could interleave two `sink.append` calls' underlying `write(2)`s
  # in whatever order the scheduler happens to run them, which is exactly the
  # ordering a model-visible sequence of notes should not depend on), or a
  # capability this card's audit never examined (run_skill, ask_human, the
  # web tools, tool_search) -- none opted in without a deliberate audit of
  # its own.
  FALSE_TOOLS = %w[bash core_exec edit_file write_file todo_write memory_write improvement_write
                   run_skill ask_human web_fetch web_search tool_search].freeze

  # The builder table moved to spec/support/tool_registry.rb once a second
  # cross-tool property (the approval tier -- see
  # spec/lain/tools/tool_surface_spec.rb) needed the same "one real instance per
  # shipped tool" table. Both specs ask their own question of ONE roster, so
  # neither can fall behind the directory while the other keeps up.
  def self.build_tool(name) = ToolRegistry.build(name)
end

# E1: widens Tool#parallel_safe? opt-in beyond {Lain::Tools::Subagent} (the only
# prior true) to the tier-1 STRUCTURED READS -- filesystem and structural-AST
# alike -- whose audit conclusion is "reads only, no Session write-set mutation,
# no process-global state" (see each tool's own WHY comment for its specific
# audit). This spec pins three things: concurrent dispatch actually happens for
# tools marked safe, the true/false partition covers the ENTIRE shipped
# toolset (so a future tool must choose deliberately or this spec names it),
# and bash's `cd` never leaks into the harness process -- the property that
# makes "no process-global state" true in the first place.
RSpec.describe "Tool#parallel_safe? across the shipped toolset" do
  # ---- Scenario: parallel-safe tools gather concurrently ---------------------

  describe "parallel-safe tools gather concurrently" do
    it "begins both dispatches before either resolves, then delivers results in tool_use order" do
      entered = Async::Queue.new
      release = Async::Queue.new
      toolset = Lain::Toolset.new(
        [ParallelSafetySpecSupport::GatedFakeTool.new(name: "fake_a", entered:, release:),
         ParallelSafetySpecSupport::GatedFakeTool.new(name: "fake_b", entered:, release:)]
      )
      runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Live.new(toolset:))
      response = tool_response(["tu_1", "fake_a", {}], ["tu_2", "fake_b", {}])

      Sync do |_task|
        run = Async { runner.run(response, context: nil) }
        entered.dequeue
        entered.dequeue # both tools are provably mid-dispatch -- neither has returned yet
        release.enqueue(:go)
        release.enqueue(:go)

        blocks = run.wait
        expect(blocks.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
        expect(blocks.map { |block| block["content"] }).to eq(%w[fake_a fake_b])
      end
    end
  end

  # ---- Scenario: the full toolset partition is pinned ------------------------

  describe "the full shipped-toolset partition" do
    it "asks every enumerated tool parallel_safe? and finds the true-set as declared" do
      ParallelSafetySpecSupport::TRUE_TOOLS.each do |name|
        tool = ParallelSafetySpecSupport.build_tool(name)
        expect(tool.parallel_safe?).to be(true), "expected #{name} to be parallel_safe?"
      end
    end

    it "asks every enumerated tool parallel_safe? and finds the false-set as declared" do
      ParallelSafetySpecSupport::FALSE_TOOLS.each do |name|
        tool = ParallelSafetySpecSupport.build_tool(name)
        expect(tool.parallel_safe?).to be(false), "expected #{name} NOT to be parallel_safe?"
      end
    end

    # The partition itself: the two enumerated lists, together, must be EXACTLY
    # the tools the toolset ships -- no overlap (a tool claiming both answers),
    # no gap (a tool this spec never named, which would fail by NAME here
    # rather than silently defaulting to false somewhere else).
    it "covers the whole toolset exactly -- no tool present in neither list, none in both" do
      true_tools = ParallelSafetySpecSupport::TRUE_TOOLS
      false_tools = ParallelSafetySpecSupport::FALSE_TOOLS
      expect(true_tools & false_tools).to eq([])

      expect((true_tools + false_tools).sort).to match_array(ToolRegistry.shipped_names)
    end
  end

  # ---- Scenario: no tool mutates the process working directory --------------

  describe "no tool mutates the process working directory" do
    it "runs `cd` inside the subprocess only -- Dir.pwd in the harness is unchanged" do
      original_pwd = Dir.pwd

      result = Lain::Tools::Bash.new.call({ command: "cd /tmp && pwd" }, Lain::Tool::Invocation.new)

      expect(result).to be_ok
      expect(result.content).to include("/tmp")
      expect(Dir.pwd).to eq(original_pwd)
    end
  end
end
