# frozen_string_literal: true

# One place that knows how to build every tool the toolset ships, and the
# completeness check that keeps it honest.
#
# Extracted from spec/lain/tools/parallel_safety_spec.rb, which built this table
# for #parallel_safe? and was then the only thing that could ask a question of
# the WHOLE toolset. Every other cross-tool property -- the approval tier, the
# model-facing name and description -- was instead hand-rolled once per tool
# spec: ~19 near-identical examples that pinned each tool individually and the
# toolset not at all, so a newly shipped tool arrived unpinned by exactly the
# examples meant to pin it. (The same failure `shipped_skills_spec.rb` records
# for `gherkin-tests`.) It lives in spec/support so any spec can reach it
# without depending on another spec file having been loaded first.
#
# The builders are minimal-but-REAL instances, each constructed the way that
# tool's own spec constructs it -- never from a bare directory listing, since
# these properties are declarations on the CLASS actually wired into the
# toolset, not on a name assumed to exist.
module ToolRegistry
  # What a spawn a spec builds says when its children run behind no tool
  # guard. It lives here and never in lib/, so no production constant means
  # "no guard": every real spawn names the guard it runs behind.
  #
  # Not an EMPTY stack: every stack {Lain::CLI::ToolGuard} builds ends in the
  # path refusal and the gate, and a child's posture places its own refusal
  # relative to them. So "no guard" is those two layers over the Nulls a seam
  # nobody taught about a gate stands for -- nothing is sensitive, and every
  # gated call is approved.
  UNGUARDED = lambda { |_worker_env|
    Lain::Middleware::Stack.new([Lain::Middleware::Sensitivity.new,
                                 Lain::Middleware::Gate.new(policy: Lain::Middleware::Gate::ApproveAll.new)])
  }.freeze

  # A builder putting `layers` ahead of {UNGUARDED}'s two, for a spec that
  # watches the calls a child's stack passes: every child's stack has to end
  # in the gate, so a watcher alone is not one.
  #
  # @return [#call] `worker_env -> Lain::Middleware::Stack`
  def self.guarded_by(*layers)
    ->(worker_env) { Lain::Middleware::Stack.new([*layers, *UNGUARDED.call(worker_env).to_a]) }
  end

  # A child's guard as the real builder makes it, gated by `policy` over
  # `sensitivity`, for a spec that asks what a child's gate does. No approval
  # queue, so the read guard releases every region, byte-for-byte what a child
  # read before children were guarded, and the gate is the only thing under
  # test.
  #
  # @return [#call] `worker_env -> Lain::Middleware::Stack`
  def self.gated(policy:, sensitivity: Lain::Sensitivity::Policy::Null.instance)
    inputs = Lain::CLI::ToolGuard::Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: nil, sensitivity:,
                                              test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
                                              policy:, denial: Lain::Middleware::Gate::DENIAL,
                                              bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new)
    chronicle = Lain::CLI::ToolGuard::Journaled.new(journal: Lain::Channel::Null.instance)
    ->(worker_env) { Lain::CLI::ToolGuard.working(chronicle, inputs, worker_env) }
  end

  def self.build_subagent
    Lain::Tools::Subagent.new(
      provider: Lain::Provider::Mock.new,
      context_factory: -> { Lain::Context.new(model: "child", max_tokens: 8) },
      toolset: Lain::Toolset.new([]),
      policy: Lain::Tool::SpawnPolicy.new,
      parent: Lain::Timeline.empty(store: Lain::Store.new),
      tool_middleware: ToolRegistry::UNGUARDED
    )
  end

  def self.build_run_skill
    Lain::Tools::RunSkill.new(
      renderer: Lain::Skill::Renderer.new(catalog: Lain::Skill::Catalog.new({}),
                                          slots: Lain::Prompt::Slots.new(fills: {}))
    )
  end

  # A Hash of thunks, not a case/when: #build stays a lookup regardless of how
  # many tools the toolset grows to. The KEY is the tool's model-facing name,
  # which is also its file basename -- #shipped_names depends on that, and
  # spec/lain/tools/tool_surface_spec.rb asserts it rather than assuming it.
  BUILDERS = {
    "read_file" => -> { Lain::Tools::ReadFile.new },
    "list_files" => -> { Lain::Tools::ListFiles.new },
    "glob" => -> { Lain::Tools::Glob.new },
    "grep" => -> { Lain::Tools::Grep.new },
    "memory_read" => -> { Lain::Tools::MemoryRead.new(index: Lain::Memory::Index.empty) },
    "ast_search" => -> { Lain::Tools::AstSearch.new },
    "ast_dump" => -> { Lain::Tools::AstDump.new },
    "test_pattern" => -> { Lain::Tools::TestPattern.new },
    "file_symbols" => -> { Lain::Tools::FileSymbols.new },
    "subagent" => -> { build_subagent },
    "bash" => -> { Lain::Tools::Bash.new },
    "edit_file" => -> { Lain::Tools::EditFile.new },
    "write_file" => -> { Lain::Tools::WriteFile.new },
    "todo_write" => -> { Lain::Tools::TodoWrite.new },
    "memory_write" => -> { Lain::Tools::MemoryWrite.new(recorder: Lain::Memory::Recorder.new) },
    "improvement_write" => lambda {
      Lain::Tools::ImprovementWrite.new(sink: Lain::Improvement::Sink.new(paths: Lain::Paths.new, session: "test"))
    },
    "run_skill" => -> { build_run_skill },
    "ask_human" => -> { Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store: Lain::Store.new)) },
    # Construction-only: every property this spec asks of the instance is a
    # declaration, never #perform, and nil collaborators fail loudly if that
    # ever stops being true. `told:` and `notes:` are required and undefaulted
    # in production, so they are passed here rather than left to a default that
    # does not exist.
    "request_review" => -> { Lain::Tools::RequestReview.new(home: nil, review: nil, told: SILENT, notes: nil) },
    "web_fetch" => -> { Lain::Tools::WebFetch.new },
    "web_search" => -> { Lain::Tools::WebSearch.new },
    "tool_search" => -> { Lain::Tools::ToolSearch.new(toolset: -> { Lain::Toolset.new([]) }) },
    # Construction-only, the same idiom -- and here the nil is the POINT: a
    # thunk over `Usage.zero` would be a fabricated zero, which is
    # the exact defect this tool exists to remove. Every property this table's
    # readers ask of the instance is a declaration, never #perform.
    "session_usage" => -> { Lain::Tools::SessionUsage.new(usage: nil) }
  }.freeze

  # `told:` is REQUIRED on the tool and undefaulted on purpose -- with no editor
  # wired in production it is the only thing that names a waiting file -- so
  # this table has to name one even though nothing here calls #perform.
  SILENT = ->(_text) {}

  def self.build(name)
    BUILDERS.fetch(name) { raise "unknown tool #{name.inspect} -- add it to ToolRegistry::BUILDERS" }.call
  end

  def self.names = BUILDERS.keys

  # The tools actually on disk, by file basename. The gap between this and
  # #names is what makes a newly shipped tool fail by NAME instead of silently
  # going unpinned.
  def self.shipped_names
    Dir.glob(File.expand_path("../../lib/lain/tools/*.rb", __dir__))
       .map { |path| File.basename(path, ".rb") }
       .sort
  end
end
