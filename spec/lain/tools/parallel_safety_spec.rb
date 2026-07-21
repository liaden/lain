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
  # command string (bash), a Session write-set mutation (edit_file,
  # write_file, todo_write, memory_write), or a capability this card's audit
  # never examined (run_skill, ask_human, the web tools, tool_search) -- none
  # opted in without a deliberate audit of its own.
  FALSE_TOOLS = %w[bash edit_file write_file todo_write memory_write
                   run_skill ask_human web_fetch web_search tool_search].freeze

  def self.build_subagent
    Lain::Tools::Subagent.new(
      provider: Lain::Provider::Mock.new,
      context_factory: -> { Lain::Context.new(model: "child", max_tokens: 8) },
      toolset: Lain::Toolset.new([]),
      policy: Lain::Tool::SpawnPolicy.new,
      parent: Lain::Timeline.empty(store: Lain::Store.new)
    )
  end

  def self.build_run_skill
    Lain::Tools::RunSkill.new(
      renderer: Lain::Skill::Renderer.new(catalog: Lain::Skill::Catalog.new({}),
                                          slots: Lain::Prompt::Slots.new(fills: {}))
    )
  end

  # One minimal-but-real instance per tool name, built the same way each
  # tool's own spec constructs it (see spec/lain/tools/*_spec.rb) -- never
  # from a bare directory listing, since #parallel_safe? is a declaration on
  # the CLASS actually wired into the toolset, not on a name assumed to exist.
  # A Hash of thunks, not a case/when: #build_tool stays a lookup regardless
  # of how many tools the toolset grows to.
  BUILDERS = {
    "read_file" => -> { Lain::Tools::ReadFile.new },
    "list_files" => -> { Lain::Tools::ListFiles.new },
    "glob" => -> { Lain::Tools::Glob.new },
    "grep" => -> { Lain::Tools::Grep.new },
    "memory_read" => -> { Lain::Tools::MemoryRead.new(index: Lain::Memory::Index.empty) },
    "ast_search" => -> { Lain::Tools::AstSearch.new },
    "ast_dump" => -> { Lain::Tools::AstDump.new },
    "test_pattern" => -> { Lain::Tools::TestPattern.new },
    "code_outline" => -> { Lain::Tools::CodeOutline.new },
    "file_symbols" => -> { Lain::Tools::FileSymbols.new },
    "subagent" => -> { build_subagent },
    "bash" => -> { Lain::Tools::Bash.new },
    "edit_file" => -> { Lain::Tools::EditFile.new },
    "write_file" => -> { Lain::Tools::WriteFile.new },
    "todo_write" => -> { Lain::Tools::TodoWrite.new },
    "memory_write" => -> { Lain::Tools::MemoryWrite.new(recorder: Lain::Memory::Recorder.new) },
    "run_skill" => -> { build_run_skill },
    "ask_human" => -> { Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store: Lain::Store.new)) },
    "web_fetch" => -> { Lain::Tools::WebFetch.new },
    "web_search" => -> { Lain::Tools::WebSearch.new },
    "tool_search" => -> { Lain::Tools::ToolSearch.new(toolset: -> { Lain::Toolset.new([]) }) }
  }.freeze

  def self.build_tool(name)
    BUILDERS.fetch(name) { raise "unknown tool #{name.inspect} -- add it to ParallelSafetySpecSupport::BUILDERS" }.call
  end
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

      shipped = Dir.glob(File.join(__dir__, "..", "..", "..", "lib", "lain", "tools", "*.rb"))
                   .map { |path| File.basename(path, ".rb") }
                   .sort
      expect((true_tools + false_tools).sort).to match_array(shipped)
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
