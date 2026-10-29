# frozen_string_literal: true

require "async"
require "fileutils"

# The two session files under spec/fixtures/sessions/approval_replay, and how they were made: each
# gated call was ruled by the stack a chat builds -- {Lain::CLI::Switchboard.for} and
# {Lain::CLI::ToolGuard.stack}, wired here and not through the replay's own Stack -- with a
# scripted human and judge and a mock interpreter answering each call's scripted output. The
# bytes are what the record writers produce, so a writer that changes shape makes the committed
# files stale, and the approval replay spec says so. Regenerate with:
#
#   bundle exec ruby -Ilib -Ispec -e 'require "lain"; require "support/session_sections"; \
#     require "support/approval_replay_fixtures"; ApprovalReplayFixtures.write'
#
# The committed files are ruled over {Lain::FileFacts::Recorded}, not the live disk: their project
# is the placeholder /home/user/project, which exists on no machine, and a real one cannot stand in
# for it afterwards because the judge's prompt names the project root, so rewriting the path would
# leave every judged call's recorded prompt digest naming a different question. A spec that needs
# the live disk calls {.record} with {Lain::FileFacts::LIVE} over a project it makes itself.
module ApprovalReplayFixtures
  DIR = File.expand_path("../fixtures/sessions/approval_replay", __dir__)
  ROOT = "/home/user/project"
  HOME = "/home/user"
  CLOCK = -> { "1970-01-01T00:00:00Z" }
  MODEL = "claude-sonnet-4-6"
  SECRET = "API_KEY=sk-live-9tKq2mR7xT4wL8nB3jH6yD1sA5fG0pE\n"

  # One gated call as the session made it: who asked, the human's answers to each park in order,
  # what the judge said under auto, what the tool printed, and whether its block survived.
  Scripted = Data.define(:id, :tool, :input, :requester, :answers, :judged, :drift, :joined, :output) do
    def initialize(id:, tool:, input:, requester: "agent", answers: [], judged: nil, drift: false, joined: true,
                   output: "")
      super
    end

    def child? = requester != "agent"
  end

  ASK = [
    Scripted.new(id: "tu_1", tool: "bash", input: { "command" => "pwd" }),
    Scripted.new(id: "tu_2", tool: "read_file", input: { "path" => ".env" }, answers: %i[approve deny],
                 output: SECRET),
    Scripted.new(id: "tu_3", tool: "write_file", input: { "path" => "/home/user/notes.md", "content" => "x" },
                 answers: %i[deny]),
    Scripted.new(id: "tu_4", tool: "bash", input: { "command" => "cat ~/.ssh/id_rsa" }),
    Scripted.new(id: "tu_5", tool: "bash", input: { "command" => "ls src" }, requester: "researcher",
                 answers: %i[approve]),
    Scripted.new(id: "tu_6", tool: "bash", input: { "command" => "make" }, answers: %i[approve], joined: false)
  ].freeze

  AUTO = [
    Scripted.new(id: "tu_1", tool: "bash", input: { "command" => "make test" }, judged: :approve),
    Scripted.new(id: "tu_2", tool: "bash", input: { "command" => "rm -rf build" }, judged: :deny),
    Scripted.new(id: "tu_3", tool: "bash", input: { "command" => "curl http://example.com" }, judged: :defer,
                 answers: %i[approve]),
    Scripted.new(id: "tu_4", tool: "bash", input: { "command" => "make lint" }, judged: :approve, drift: true)
  ].freeze

  # Where a chat's guards journal: kept as written, for the session file.
  Chronicle = Struct.new(:record_journal) do
    def instrumentation = Lain::Agent::Instrumentation.new(journal: record_journal)
  end

  # The journal the board and the guards write into.
  class Kept
    attr_reader :entries

    def initialize
      @entries = []
    end

    def record(entry)
      @entries << entry
      self
    end

    alias << record
  end

  module_function

  def place = Lain::Bench::ApprovalReplay::Place.new(cwd: ROOT, root: ROOT, home: HOME)

  def recorded(at) = Lain::FileFacts::Recorded.new(places: [at.cwd, at.root, at.home])

  # What `pwd` resolved to when it ran, as {Lain::Tools::Bash} journals it.
  def pwd
    Lain::Shell::Executable.new(name: "pwd", resolved: "/usr/bin/pwd", realpath: "/usr/lib/coreutils/pwd",
                                chain: ["/usr/bin/pwd"], shadowed: [], anomalies: [], klass: :system,
                                fresh: false, run_files: [], wrappers: [])
  end

  def write(dir = DIR)
    FileUtils.mkdir_p(dir)
    [record(File.join(dir, "ask.ndjson"), ASK, approval: :ask, rules: File.join(dir, "rules_a.rb"),
                                               policy: "blake3:#{"0" * 64}"),
     record(File.join(dir, "auto.ndjson"), AUTO, approval: :auto, policy: nil)]
  end

  # A nil policy digest writes a provenance that names no place, as a session from before it recorded one.
  def record(path, script, approval:, policy:, rules: nil, at: place, facts: recorded(at))
    FileUtils.rm_f(path)
    journal = Lain::Journal.open(path, clock: CLOCK)
    begin
      journal << header(policy, at)
      [*turns(script), *ruled(script, approval:, rules:, at:, facts:)].each { journal << _1 }
    ensure
      journal.close
    end
    path
  end

  def header(policy, at)
    context = Lain::Context.new(model: MODEL, max_tokens: 1024, system: "be terse")
    unrecorded = Lain::SessionRecord::Provenance::UNRECORDED
    stamp = Lain::SessionRecord::Provenance.new(harness: "unrecorded", tool_surface: toolset.digest, effort: nil,
                                                policy: policy || unrecorded, cwd: policy ? at.cwd : unrecorded,
                                                root: policy ? at.root : unrecorded,
                                                home: policy ? at.home : unrecorded)
    writer = Lain::Liveness::Writer.new(pid: 1, start: "0", host: "approval-replay-fixture")
    Lain::SessionRecord.header(context:, toolset:, writer:,
                               sections: SessionSections.complete(provenance: stamp.to_header))
  end

  def toolset
    Lain::Toolset.new([Lain::Tools::Bash.new, Lain::Tools::ReadFile.new, Lain::Tools::WriteFile.new,
                       Lain::Tools::EditFile.new, Lain::Tools::ListFiles.new, Lain::Tools::Glob.new,
                       Lain::Tools::Grep.new, Lain::Tools::AstSearch.new, Lain::Tools::FileSymbols.new])
  end

  # Every record each call drew, in the order the stack journaled them, with a scripted human
  # answering the queue from a sibling fiber as a chat's surfaces do.
  def ruled(script, approval:, rules:, at:, facts:)
    kept = Kept.new
    chronicle = Chronicle.new(kept)
    board = board(chronicle, script, approval:, rules:, at:, facts:)
    answers = script.to_h { [_1.id, _1.answers.dup] }
    Sync do |task|
      human = task.async { loop { answer(board.approvals.dequeue, answers) } }
      script.each { |call| dispatch(call, chronicle, board, at, kept) }
    ensure
      human&.stop
    end
    kept.entries
  end

  def board(chronicle, script, approval:, rules:, at:, facts:)
    remembered, denied_tools = rule_set(rules)
    classifier = Lain::Sensitivity.new(home: at.home, cwd: at.cwd, root: at.root)
    sensitivity = Lain::Sensitivity::Policy.new(sensitivity: classifier, home: at.home, root: at.root,
                                                file_facts: facts)
    Lain::CLI::Switchboard.for(
      chronicle:, options: { approval: }, model: MODEL, toolset:, judge: Judge.new(script), rules: remembered,
      denied_tools:, sensitivity:,
      classifiers: Lain::CLI::Wiring::BoardBuild::Classifiers.new(home: at.home, cwd: at.cwd, root: at.root),
      test_layout: Lain::Middleware::GuardTestLayout::Run.new(layout: Lain::TestLayout::None, root: at.root,
                                                              file_facts: facts)
    )
  end

  def rule_set(path)
    return [[], Set[]] unless path

    built = Lain::Config::Builder.evaluate(File.read(path), path:)
    [[Lain::Approval::Remembered.from(built)].reject(&:empty?), built.approval.deny_tools]
  end

  def answer(pending, answers)
    given = answers.fetch(pending.tool_use_id).shift or raise "no scripted answer for #{pending.tool_use_id}"
    return pending.approve(surface: "tty", authority: :human) if given == :approve

    pending.deny(surface: "tty", authority: :human)
  end

  def dispatch(call, chronicle, board, at, kept)
    resolution(call).each { kept.record(_1) }
    worker_env = Lain::WorkerEnv.new(cwd: at.cwd, env: {})
    layers = if call.child?
               Lain::CLI::ToolGuard.child_stack(chronicle, board, worker_env, requester: call.requester)
             else
               Lain::CLI::ToolGuard.stack(chronicle, board)
             end
    runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new { |*| call.output },
                                         middleware: layers, toolset: board.toolset)
    runner.run(Lain::Response.new(content: [block(call)], stop_reason: :tool_use),
               context: Lain::Session.new(worker_env:, root: at.root))
  end

  def resolution(call)
    return [] unless call.input["command"] == "pwd"

    [Lain::Telemetry::ExecResolution.new(tool_use_id: call.id, stages: [pwd.to_journal])]
  end

  def turns(script)
    store = Lain::Dag::Factory.store
    main = Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [text("tidy the project")])
    main = main.commit(role: :assistant, content: script.select { _1.joined && !_1.child? }.map { block(_1) })
    [*main.to_a.map { Lain::SessionRecord.turn(_1) }, *children(script, store)]
  end

  def children(script, store)
    script.select(&:child?).map do |call|
      child = Lain::Dag::Factory.timeline(store:).commit(role: :assistant, content: [block(call)])
      Lain::Telemetry::ChildTurn.from_event(child.head)
    end
  end

  def block(call) = { "type" => "tool_use", "id" => call.id, "name" => call.tool, "input" => call.input }

  def text(words) = { "type" => "text", "text" => words }

  # The judge a live session asked, scripted per call. A drifted call was asked under a prompt
  # worded differently from today's, as a session recorded by an older lain was.
  class Judge
    def initialize(script)
      @script = script
      @prompter = Lain::Approval::Judge.new(role_spawn: Lain::Bench::ApprovalReplay::RecordedJudge::NoModel)
    end

    def prompt(tool:, input:, place:)
      worded = @prompter.prompt(tool:, input:, place:)
      scripted(tool, input)&.drift ? "#{worded}(an older wording)\n" : worded
    end

    def call(tool:, input:, **) = scripted(tool, input)&.judged || :defer

    private

    def scripted(tool, input) = @script.find { _1.tool == tool && _1.input == input }
  end
end
