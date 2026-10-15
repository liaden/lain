# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# The chat's research subagent as a chat builds it: the toolset build, the
# board for its project, and a child whose place to work is leased for real --
# a scratch directory, or a worktree of a related repository cut by real git.
RSpec.describe "A researcher spawn leases its own kept, confined directory", :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:kept_pattern) do
    Regexp.new("#{Regexp.escape(File.join(paths.state_home, "research"))}/[^ ,\"\\\\]+/scratch/research-[^ ,\"\\\\]+")
  end

  around do |example|
    Dir.mktmpdir("lain-research-lease") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home")
      @repo = File.join(@base, "repo")
      @other = File.join(@home, "dev", "other")
      FileUtils.mkdir_p([@home, @repo, @other])
      @leased = []
      example.run
    ensure
      @leased.each { FileUtils.rm_rf(_1) }
    end
  end

  def seed(dir, files)
    FileUtils.cp_r("#{SeedRepo.at(files)}/.", dir)
  end

  def git(*args, dir: @other) = SeedRepo.git(dir, *args).stdout

  def paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })

  def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :git)

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, judge: Lain::CLI::Switchboard::DEFERRING,
      model: "m", toolset: Lain::Toolset.new([]), project:, paths:,
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
    ).bind_session(Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: @repo)))
  end

  def toolset_build(provider)
    backend = Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd)
    the_board = board
    Lain::CLI::Wiring::ToolsetBuild.new(
      backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new, options: {}, parent: -> { Lain::Timeline.empty },
      supervisor: Lain::Supervisor.new(journal:), journal:, library: backend.library, root: @repo,
      epic: SpecNulls.unmounted_epic, switchboard: -> { the_board }, askers: SpecNulls::UnwiredAskers.build,
      paths:, config: Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
    )
  end

  def researcher(provider)
    toolset = toolset_build(provider).build(Lain::Memory::Recorder.new,
                                            ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty }))
    toolset.fetch(Lain::Tools::Subagent::NAME)
  end

  def spawn(provider, input) = researcher(provider).call({ "prompt" => "survey it" }.merge(input), invocation)

  def first_request(provider) = provider.requests.first.then { [_1.system, _1.messages].to_s }

  def leases = Lain::Journal.records(journal_io.string.lines, type: "isolation_lease").to_a

  def kept_dirs(text) = text.scan(kept_pattern).uniq

  def plan_branches
    git("for-each-ref", "--format=%(refname:short)", "refs/heads/lain/plan/").split
  end

  def worktrees = git("worktree", "list", "--porcelain").scan(/^worktree (.+)$/).flatten - [@other]

  describe "with no extends" do
    it "works in a fresh scratch directory its workspace names, kept after the child ends" do
      provider = Lain::Provider::Mock.new(responses: [text_response("found it")])

      result = spawn(provider, {})
      dirs = kept_dirs(first_request(provider)).tap { @leased.concat(_1) }

      expect(result.content).to eq("found it")
      expect(dirs.size).to eq(1)
      expect(File.directory?(dirs.first)).to be(true)
      expect(Dir.children(dirs.first)).to be_empty
    end

    # The bench counts lease cost off these records, so a kept lease is on the
    # record like any other, ending as kept rather than released.
    it "journals the lease acquired, then kept once the child ends" do
      provider = Lain::Provider::Mock.new(responses: [text_response("found it")])

      spawn(provider, {})
      dir = kept_dirs(first_request(provider)).first

      expect(leases.map { _1.values_at("kind", "backend", "path") })
        .to eq([["acquired", "Lain::Isolation::Scratch", dir], ["kept", "Lain::Isolation::Scratch", dir]])
      expect(leases.map { _1["worker_key"] }.uniq).to eq(["research.#{File.basename(dir)}"])
    end

    it "journals the lease kept when the child fails, too" do
      provider = Lain::Provider::Mock.new(responses: [])

      expect { spawn(provider, {}) }.to raise_error(StandardError)
      expect(leases.map { _1["kind"] }).to eq(%w[acquired kept])
    end

    it "keeps its scratch under lain's state home, which a reboot does not clear" do
      provider = Lain::Provider::Mock.new(responses: [text_response("found it")])

      spawn(provider, {})

      expect(kept_dirs(first_request(provider)).first).to start_with(File.join(@base, "state", "lain", "research", ""))
    end

    # The stack the production researcher's children get, over a lease of the
    # same shape a spawn hands them.
    it "refuses a child's write outside its lease, naming the lease" do
      lease = File.join(@base, "lease").tap { FileUtils.mkdir_p(_1) }
      env = Lain::WorkerEnv.new(cwd: lease, env: {}, checkout: lease)
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "write_file",
                                          input: { "path" => File.join(@repo, "a.rb"), "content" => "x" })
      stack = researcher(Lain::Provider::Mock.new).seam.tool_middleware.call(env)

      context = Lain::Session.new(worker_env: env)
      refused = stack.call({ effect:, tool: Lain::Tools::WriteFile.new, context: }) do
        raise "the write reached the interpreter"
      end.fetch(:result)

      expect(refused).to have_attributes(is_error: true, content: start_with("write_file refused"))
      expect(refused.content).to include(lease)
      expect(File.exist?(File.join(@repo, "a.rb"))).to be(false)
    end

    it "sends the task as the child's first request, with no setup call before it" do
      provider = Lain::Provider::Mock.new(responses: [text_response("found it")])

      spawn(provider, {})
      @leased.concat(kept_dirs(first_request(provider)))
      messages = provider.requests.first.messages

      expect(messages.size).to eq(1)
      expect(messages.first.to_s).to include("survey it")
      expect(messages.first.to_s).not_to include("tool_use")
    end
  end

  describe "with extends naming a related git repository" do
    before do
      seed(@other, { "OTHER.md" => "the other repository\n" })
      write_config(@repo, "sensitivity related: [\"~/dev/other\"]\n")
    end

    it "works in a new worktree of it on its own lain/plan branch, and keeps both after the child ends" do
      list = tool_response(["c1", "list_files", { "path" => "." }])
      provider = Lain::Provider::Mock.new(responses: [list, text_response("listed")])

      spawn(provider, { "extends" => @other })

      expect(worktrees.size).to eq(1)
      expect(plan_branches).to contain_exactly(start_with("lain/plan/"))
      expect(first_request(provider)).to include(worktrees.first, plan_branches.first)
      expect(provider.requests.last.messages.to_s).to include("OTHER.md")
      expect(File.read(File.join(worktrees.first, "OTHER.md"))).to eq("the other repository\n")
    end

    it "has the worktree on its branch, so a commit made there lands on the kept branch" do
      spawn(Lain::Provider::Mock.new(responses: [text_response("done")]), { "extends" => @other })
      worktree = worktrees.first

      git("commit", "-q", "--allow-empty", "-m", "a finding", dir: worktree)

      expect(git("symbolic-ref", "HEAD", dir: worktree).strip).to eq("refs/heads/#{plan_branches.first}")
      expect(git("rev-parse", plan_branches.first)).to eq(git("rev-parse", "HEAD", dir: worktree))
    end

    it "journals the spike's lease with where it was cut, and kept" do
      spawn(Lain::Provider::Mock.new(responses: [text_response("done")]), { "extends" => @other })

      expect(leases.map { _1.values_at("kind", "backend", "branch") })
        .to eq([["acquired", "Lain::Isolation::Spike", plan_branches.first],
                ["kept", "Lain::Isolation::Spike", plan_branches.first]])
    end

    it "is left alone by the reaper of the fleet's worktrees" do
      spawn(Lain::Provider::Mock.new(responses: [text_response("done")]), { "extends" => @other })
      worktree = worktrees.first

      records = Lain::Isolation::Gc.new(repo_root: @other, retain_days: 0,
                                        root: Lain::CLI::IsolationBackend.worktree_root(@other, paths:)).call

      expect(records.map(&:name)).not_to include(worktree)
      expect([File.directory?(worktree), plan_branches.size]).to eq([true, 1])
    end

    it "gives 2 researchers spawned at once their own worktree and branch" do
      provider = Lain::Provider::Mock.new(responses: [text_response("one"), text_response("two")])
      tool = researcher(provider)

      Sync do |task|
        Array.new(2) { task.async { tool.call({ "prompt" => "survey it", "extends" => @other }, invocation) } }
             .each(&:wait)
      end

      expect(worktrees.uniq.size).to eq(2)
      expect(plan_branches.uniq.size).to eq(2)
    end
  end

  it "refuses extends outside the project and its related directories, starting no child" do
    provider = Lain::Provider::Mock.new(responses: [text_response("never")])

    expect { spawn(provider, { "extends" => "/etc" }) }
      .to raise_error(Lain::Tool::InvalidInput, %r{extends.*/etc})
    expect(provider.requests).to be_empty
  end
end
