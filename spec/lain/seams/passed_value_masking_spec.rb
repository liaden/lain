# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# A value the project's `env pass:` lets through reaches every bash child, so
# the secret inside it can come back out of a pipeline in pieces the output
# detector cannot see. A real {Lain::CLI::Wiring} reads the real config into a
# real {Lain::Exec::ChildEnv}, and a real bash call runs through the real guard
# stack; only the model's provider is a stand-in.
RSpec.describe "a passed value's secret masked in bash output", :seam do
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root:)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:dsn) { "postgres://app:hunter2xyz@db.local/app" }

  around do |example|
    Dir.mktmpdir("lain-passed-value") do |dir|
      base = File.realpath(dir)
      @root = File.join(base, "repo")
      homes = { "XDG_STATE_HOME" => File.join(base, "s"), "HOME" => File.join(base, "h") }
      @paths = Lain::Paths.new(env: SpecHome.env(homes))
      tmp = File.join(base, "t")
      FileUtils.mkdir_p([@root, tmp, *homes.values])
      # Every Config reader that defaults paths: builds its own Paths over ENV, so trust has to land there too.
      # The TMPDIR sits beside home because the workspace profile a bypassed call runs in refuses one holding it.
      with_env(homes.merge("DATABASE_URL" => dsn, "TMPDIR" => tmp)) do
        write_config(@root, "env pass: %w[DATABASE_URL]\n", paths: @paths)
        example.run
      end
    end
  end

  def wiring
    project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)
    Lain::CLI::Wiring.new(human: Lain::CLI::Human.new(kind: :terminal),
                          options: { grace: 5, approval: "bypass" }, chronicle: Lain::CLI::Chronicle::Null.new,
                          status_feed: instance_double(Lain::StatusFeed, bind_store: nil), project:, paths: @paths)
  end

  def run_bash(command) = run_tool("bash", { "command" => command })

  def run_tool(name, input)
    built = wiring
    backend = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 },
                                        mock: Lain::Provider::Mock.new(responses: []), root: @root)
    recorder, session = built.run_state(nil)
    built.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    board = built.instance_variable_get(:@switchboard)
    layers = Lain::CLI::ToolGuard.stack(Lain::CLI::Chronicle::Null.new, board).to_a
    Sync do |task|
      task.with_timeout(20) do
        dispatch_call(name, input, toolset: board.toolset, layers:, context: session)
      end
    end
  end

  describe "the same value in a project file" do
    before { File.write(File.join(@root, "deploy.txt"), "pw=hunter2xyz\n") }

    it "masks it in a read_file result" do
      result = run_tool("read_file", { "path" => "deploy.txt" })

      expect(result.content).to include(format(Lain::Sensitivity::Regions::PLACEHOLDER, 1))
      expect(result.content).not_to include("hunter2xyz")
    end

    it "masks it in a grep row" do
      result = run_tool("grep", { "pattern" => "pw=", "path" => "." })

      expect(result.content).to include("pw=#{format(Lain::Sensitivity::Regions::PLACEHOLDER, 1)}")
      expect(result.content).not_to include("hunter2xyz")
    end

    it "leaves no state file holding it" do
      run_tool("read_file", { "path" => "deploy.txt" })
      run_tool("grep", { "pattern" => "pw=", "path" => "." })

      state = Dir.glob(File.join(@paths.state_home, "**", "*")).select { File.file?(_1) }
      expect(state).not_to be_empty
      expect(state.select { File.binread(_1).include?("hunter2xyz") }).to be_empty
    end
  end

  it "masks the password a pipeline cut out of the URL" do
    result = run_bash("printenv DATABASE_URL | cut -d: -f3 | cut -d@ -f1")

    expect(result.content).to include(format(Lain::Sensitivity::Regions::PLACEHOLDER, 1))
    expect(result.content).not_to include("hunter2xyz")
  end

  it "leaves the readable part of the URL readable" do
    result = run_bash("printenv DATABASE_URL | cut -d@ -f2")

    expect(result.content).to include("db.local/app")
    expect(result.content).not_to include("redacted")
  end
end
