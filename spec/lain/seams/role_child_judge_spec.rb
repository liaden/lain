# frozen_string_literal: true

require "stringio"
require "tmpdir"

# A role skill's child, as the judge sees it: a real {Lain::Skill::RoleSpawn}
# over a real tool-guard builder, gated by a real {Lain::Approval::Judged}
# asking a real {Lain::Approval::Judge}. Only the judge's own spawn is canned,
# so the prompt it is handed is the one the judge child would read.
RSpec.describe "a role skill's child names its role to the judge", :seam do
  around do |example|
    Dir.mktmpdir do |root|
      @root = File.realpath(root)
      @slots = Lain::Prompt::Slots.load(root: @root)
      example.run
    end
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:prompts) { [] }
  let(:judge_spawn) do
    seen = prompts
    Class.new do
      define_method(:never_parking) { self }

      define_method(:call) do |_role, _mode, prompt|
        seen << prompt
        Lain::Tool::Result.ok("defer")
      end
    end.new
  end
  let(:judged) do
    classifier = Lain::Sensitivity.new(home: @root, cwd: @root, root: @root)
    sensitivity = Lain::Sensitivity::Policy.new(sensitivity: classifier, home: @root, root: @root)
    refusing = ->(_effect, _context) { Lain::Approval::Escalation::Ruling.deny(rung: "spec", because: "no", final: true) }
    Lain::Approval::Judged.new(judge: Lain::Approval::Judge.new(role_spawn: judge_spawn, timeout: 10),
                               policy: sensitivity, asking: refusing, journal:)
  end
  let(:union) do
    Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                       Lain::Tools::Grep.new, Lain::Tools::EditFile.new, Lain::Tools::WriteFile.new,
                       Lain::Tools::TodoWrite.new, Lain::Tools::Bash.new])
  end

  def dev_child(builder)
    provider = Lain::Provider::Mock.new(responses: [tool_response(["b1", "bash", { "command" => "make" }]),
                                                    text_response("done")])
    context_factory = -> { Lain::Context.new(model: "c", max_tokens: 256) }
    spawn = Lain::Skill::RoleSpawn.new(provider:, context_factory:, toolset: union, slots: @slots,
                                       parent: CoreGraph.timeline, tool_middleware: builder)
    Sync { spawn.call(:dev, :fresh, "go") }
  end

  def inputs
    Lain::CLI::ToolGuard::Inputs.new(ledger: Lain::Sensitivity::Ledger.new, approvals: nil,
                                     sensitivity: Lain::Sensitivity::Policy::Null.instance,
                                     test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
                                     policy: judged, policy_for: ->(_worker_env) { judged },
                                     denial: Lain::Middleware::Gate::DENIAL,
                                     bar: Lain::Middleware::WithholdAutomaticOutput::Bar.new)
  end

  def judged_requesters = prompts.map { |prompt| prompt[/requester: "(\w+)"/, 1] }

  def escalation_requesters = journal_records(journal_io, "escalation").map { |record| record["requester"] }.uniq

  it "names the role under a chat's builder, not the run's subagent" do
    board = Struct.new(:guard_inputs).new(inputs)
    dev_child(Lain::CLI::ToolGuard::Spawned.new(chronicle: Lain::CLI::ToolGuard::Journaled.new(journal:),
                                                board: -> { board }, requester: "subagent"))

    expect(judged_requesters).to eq(["dev"])
    expect(escalation_requesters).to eq(["dev"])
  end

  it "names the role under a run with no chat" do
    dev_child(Lain::CLI::ToolGuard.detached(journal:, policy_for: ->(_worker_env) { judged }))

    expect(judged_requesters).to eq(["dev"])
    expect(escalation_requesters).to eq(["dev"])
  end
end
