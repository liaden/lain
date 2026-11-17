# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "tmpdir"

# An orchestrator that leased a checkout to a dev reads that checkout when the
# dev hands back, and a second dev still cannot. Everything between the model
# and the gate is real: the nested spawn tools, the leases, the board and the
# guard stacks {Lain::CLI::ToolGuard} builds for each child. Only the provider
# is scripted, and the lease backend cuts plain directories.
RSpec.describe "A parent's read of its child's lease", :seam do
  # Checkouts numbered in the order they are cut, so a script can name the
  # directory a child will be given before it is.
  let(:backend_class) do
    Class.new do
      attr_reader :leased

      def initialize(root)
        @root = root
        @leased = []
      end

      def acquire(_worker_id)
        path = File.join(@root, (@leased.size + 1).to_s)
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "Cargo.toml"), "name = \"zq_lease_mark\"\n")
        @leased << path
        Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default.with(cwd: path), on_release: -> {},
                                   origin: Lain::Isolation::Lease::Origin.new(path:))
      end
    end
  end

  let(:journal) { Lain::Journal.new(io: StringIO.new) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:script) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: script) }
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }
  let(:places) { [] }
  let(:judge) { ->(place:, **) { (places << place) && :defer } }
  let(:board) do
    Lain::CLI::Wiring::BoardBuild.for(
      human: Lain::CLI::Human.new(kind: :terminal), chronicle:, options: {}, judge:, model: "m",
      toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]), project:,
      paths: Lain::Paths.new(env: { "HOME" => @home }),
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:, paths: Lain::Paths.new)
    )
  end

  around do |example|
    Dir.mktmpdir("lain-parent-lease-reads") do |dir|
      @base = File.realpath(dir)
      @root = File.join(@base, "project").tap { FileUtils.mkdir_p(_1) }
      @home = File.join(@base, "home").tap { FileUtils.mkdir_p(_1) }
      @backend = backend_class.new(File.join(@base, "children"))
      example.run
    end
  end

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  # The orchestrator's tool, over a dev spawner it hands down to each child it builds.
  def orchestrator
    parent = Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    seam = Lain::Tools::Subagent::Seam.new(
      provider:, context_factory: -> { Lain::Context.new(model: "m", max_tokens: 256) }, parent:,
      tool_middleware: Lain::CLI::ToolGuard::Spawned.new(chronicle:, board: -> { board }, requester: "subagent"),
      isolation: Lain::Isolation::Leases.new(backend: @backend), holder: Lain::Tools::Subagent::Holder.at(3)
    )
    dev = Lain::Tools::Subagent.new(seam:, toolset: Lain::Toolset.new([Lain::Tools::ReadFile.new]),
                                    policy: policy(only: %i[read_file]))
    Lain::Tools::Subagent.new(seam:, toolset: Lain::Toolset.new([dev, Lain::Tools::ReadFile.new]),
                              policy: policy(only: %i[subagent read_file]))
  end

  def policy(only:) = Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only:)

  def checkout(number) = File.join(@base, "children", number.to_s)

  def reads(number)
    tool_response(["r#{number}", "read_file", { "path" => File.join(checkout(number), "Cargo.toml") }])
  end

  def spawns(name) = tool_response([name, "subagent", { "prompt" => name }])

  # The human at the approval surface, denying whatever parks and keeping what it saw.
  def orchestrated(prompt = "orchestrate")
    parked = []
    Sync do |task|
      watching = task.async { loop { parked << board.approvals.dequeue.tap { _1.deny(surface: "spec") } } }
      task.with_timeout(30) { orchestrator.call({ "prompt" => prompt }, invocation) }
    ensure
      watching&.stop
    end
    parked
  end

  def results
    provider.requests.flat_map { |request| request.messages.flat_map { |m| Array(m["content"]) } }
            .grep(Hash).select { _1["type"] == "tool_result" }
  end

  def result_of(id)
    Array(results.find { _1["tool_use_id"] == id }&.fetch("content")).map { _1.is_a?(Hash) ? _1["text"] : _1 }.join
  end

  it "lets an orchestrator read its dev's tree after the dev hands back, without parking it" do
    script.push(spawns("skeleton"), text_response("skeleton done"), reads(2), text_response("reviewed"))

    expect(orchestrated).to be_empty
    expect(result_of("r2")).to include("zq_lease_mark")
  end

  it "still parks a second dev's read of the first dev's tree" do
    script.push(spawns("skeleton"), text_response("skeleton done"), spawns("store"), reads(2),
                text_response("store done"), text_response("orchestrated"))

    expect(orchestrated.map(&:tool)).to eq(["read_file"])
    expect(result_of("r2")).not_to include("zq_lease_mark")
  end

  # The approval ladder reads the board's own policy, and only the context
  # a stack asks it through says whose bounds a path is judged against.
  describe "the approval ladder's view of a held dev tree" do
    let(:orchestrator_env) { Lain::WorkerEnv.new(cwd: @root, env: {}, checkout: @root) }
    let(:cell) { Lain::Sensitivity::Bounds::Cell.new(Lain::Sensitivity::Bounds::NONE) }
    let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }

    def judged_bash(command)
      stack = Lain::CLI::ToolGuard.child_stack(chronicle, board, orchestrator_env, requester: "orchestrator", cell:)
      board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")
      denying { dispatched(stack, command) }
    end

    def dispatched(stack, command)
      dispatch_call("bash", { "command" => command }, toolset:, layers: stack.to_a,
                                                      context: Lain::Session.new(worker_env: orchestrator_env),
                                                      handler: Lain::Effect::Handler::Mock.new(default: "ran"))
    end

    def denying(&block)
      Sync do |task|
        watching = task.async { loop { board.approvals.dequeue.deny(surface: "spec") } }
        task.with_timeout(10, &block)
      ensure
        watching&.stop
      end
    end

    it "judges a held dev tree as inside, as the gate does" do
      dev_tree = File.join(@base, "children", "9").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(dev_tree, "Cargo.toml"), "x\n")
      cell.swap { _1.with_child(dev_tree) }
      judged_bash("cat #{File.join(dev_tree, "Cargo.toml")}")

      expect(places.map(&:outside)).to eq([[]])
    end

    it "still judges a tree no lease held as outside" do
      stray = File.join(@base, "children", "8").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(stray, "Cargo.toml"), "x\n")
      judged_bash("cat #{File.join(stray, "Cargo.toml")}")

      expect(places.flat_map(&:outside)).to include(File.join(stray, "Cargo.toml"))
    end
  end
end
