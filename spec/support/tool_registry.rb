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
    "code_outline" => -> { Lain::Tools::CodeOutline.new },
    "file_symbols" => -> { Lain::Tools::FileSymbols.new },
    "subagent" => -> { build_subagent },
    "bash" => -> { Lain::Tools::Bash.new },
    # Construction-only: every property asked of this instance is a declaration,
    # never #perform, and a nil client fails loudly if that ever changes.
    "core_exec" => -> { Lain::Tools::CoreExec.new(client: nil) },
    "edit_file" => -> { Lain::Tools::EditFile.new },
    "write_file" => -> { Lain::Tools::WriteFile.new },
    "todo_write" => -> { Lain::Tools::TodoWrite.new },
    "memory_write" => -> { Lain::Tools::MemoryWrite.new(recorder: Lain::Memory::Recorder.new) },
    "improvement_write" => lambda {
      Lain::Tools::ImprovementWrite.new(sink: Lain::Improvement::Sink.new(paths: Lain::Paths.new, session: "test"))
    },
    "run_skill" => -> { build_run_skill },
    "ask_human" => -> { Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store: Lain::Store.new)) },
    # Construction-only, the "core_exec" precedent above: every property this
    # spec asks of the instance is a declaration, never #perform, and nil
    # collaborators fail loudly if that ever stops being true.
    "request_review" => -> { Lain::Tools::RequestReview.new(home: nil, review: nil) },
    "web_fetch" => -> { Lain::Tools::WebFetch.new },
    "web_search" => -> { Lain::Tools::WebSearch.new },
    "tool_search" => -> { Lain::Tools::ToolSearch.new(toolset: -> { Lain::Toolset.new([]) }) }
  }.freeze

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
