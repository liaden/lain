# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# The epic home in the XDG state directory is one of the session's read roots:
# a spawned child reads there as it reads in the project, and writes there as
# it writes anywhere outside it. Everything is real between the model and the
# gate, as {Lain::CLI::Wiring} assembles it; only the provider is scripted.
RSpec.describe "A spawned child in the XDG epic home", :seam do
  let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
  let(:script) { [] }
  let(:provider) { Lain::Provider::Mock.new(responses: script) }
  let(:status_feed) { instance_double(Lain::StatusFeed, bind_store: nil) }
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:, root: Dir.pwd)
        super(options, root:)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider) }

  around do |example|
    Dir.mktmpdir("lain-epic-home-read") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "project")
      @paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(base, "state") })
      FileUtils.mkdir_p([@home, File.join(@root, "lib")])
      @epic = mount_epic
      example.run
    end
  end

  def mount_epic
    container = Lain::Epic::Home.container(config: Lain::Config.load(root: @root, paths: Lain::Paths.new),
                                           paths: @paths, root: @root)
    File.join(container, "demo").tap do |epic|
      FileUtils.mkdir_p(File.join(epic, "issues"))
      File.write(File.join(epic, "epic.md"), "zq_epic_mark\n")
      File.write(File.join(epic, "issues", "a.md"), "zq_issue_mark\n")
    end
  end

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  def wired
    wiring = Lain::CLI::Wiring.new(human: Lain::CLI::Human.new(kind: :terminal), options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new,
                                   status_feed:, project:, paths: @paths)
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: RecordingChannel.new, recorder:, session:, backend:, notice: ->(_line) {})
    [wiring, agent]
  end

  def blocks_sent = provider.requests.flat_map { |request| request.messages.flat_map { |m| Array(m["content"]) } }

  def result_of(id)
    block = blocks_sent.grep(Hash).find { |sent| sent["type"] == "tool_result" && sent["tool_use_id"] == id }
    raise "no tool_result answered #{id}" unless block

    Array(block["content"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
  end

  # The human at the approval surface: keeps each park it saw and denies it.
  def answering(script_calls, ask: "read the epic")
    script.push(*script_calls)
    wiring, agent = wired
    seen = []
    Sync do |task|
      surface = task.async { loop { seen << wiring.approvals.dequeue.tap { _1.deny(surface: "spec") } } }
      task.with_timeout(30) { agent.ask(ask) }
    ensure
      surface&.stop
    end
    seen
  end

  # The chat's own `subagent` tool spawns the researcher, as the model would.
  def researching(calls)
    answering([tool_response(["tu_spawn", "subagent", { "prompt" => "read the epic", "role" => "researcher" }]),
               *numbered("tu_child", calls), text_response("child done"), text_response("parent done")])
  end

  def by_the_agent(calls) = answering([*numbered("tu_agent", calls), text_response("agent done")])

  def numbered(prefix, calls)
    calls.each_with_index.map { |(name, input), index| tool_response(["#{prefix}#{index}", name, input]) }
  end

  def at(*names) = File.join(@epic, *names)

  def outside_note = Lain::Sensitivity::Policy::OUTSIDE_PROJECT.explanation

  def raw_write = ["write_file", { "path" => at("issues", "b.md"), "content" => "x\n" }]

  def shell_writes
    File.write(File.join(@home, "x"), "planted\n")
    ["echo x >> #{at("epic.md")}", "sed -i s/a/b/ #{at("epic.md")}", "rm #{at("issues", "a.md")}",
     "cp #{File.join(@home, "x")} #{at("issues", "a.md")}"].map { ["bash", { "command" => _1 }] }
  end

  def untouched?
    contents = [File.read(at("epic.md")), File.read(at("issues", "a.md"))]
    !File.exist?(at("issues", "b.md")) && contents == %W[zq_epic_mark\n zq_issue_mark\n]
  end

  it "reads epic.md with read_file and with bash cat, asking no approval" do
    seen = researching([["read_file", { "path" => at("epic.md") }], ["bash", { "command" => "cat #{at("epic.md")}" }]])

    expect(seen.map(&:tool)).to be_empty
    expect([result_of("tu_child0"), result_of("tu_child1")]).to all(include("zq_epic_mark"))
  end

  # A researcher is leased a scratch directory, and its lease refuses every
  # write outside it before the gate is asked.
  it "refuses a researcher's raw write and each shell write into the epic home, writing nothing" do
    seen = researching([raw_write, *shell_writes])

    expect(seen).to be_empty
    expect((0..4).map { result_of("tu_child#{_1}") }).to all(include("lies outside it. Nothing was"))
    expect(untouched?).to be(true)
  end

  it "refuses the main agent's raw write, and gates each shell write into the epic home as outside the project" do
    seen = by_the_agent([raw_write, *shell_writes])

    expect(seen.map { [_1.tool, _1.notes.join] }).to match(Array.new(4) { ["bash", include(outside_note)] })
    expect(result_of("tu_agent0")).to include("epic_write and epic_graph")
    expect(untouched?).to be(true)
  end

  # The cargo caches are read roots of a Rust project's session, as the epic home is of every session.
  it "reads a crate's source with read_file and lists the registry with bash, asking no approval" do
    File.write(File.join(@root, "Cargo.toml"), "[package]\nname = \"x\"\n")
    registry = File.join(@home, ".cargo/registry/src")
    source = File.join(registry, "index.crates.io-1949cf8c6b5b557f/whisper-rs-0.16.0/src/lib.rs")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, "zq_crate_mark\n")

    seen = by_the_agent([["read_file", { "path" => source }], ["bash", { "command" => "ls #{registry}" }]])

    expect(seen.map(&:tool)).to be_empty
    expect([result_of("tu_agent0"), result_of("tu_agent1")])
      .to match([include("zq_crate_mark"), include("index.crates.io-1949cf8c6b5b557f")])
  end

  it "parks a read of a credential in the epic home, as in the project" do
    File.write(at("research.md"), "API_KEY=#{api_key}\n")

    seen = researching([["read_file", { "path" => at("research.md") }]])

    expect(seen.map(&:tool)).to eq(["read_file"])
    expect(result_of("tu_child0")).not_to include(api_key)
  end
end

# The same read root inside the reader sandbox: the real mask list over a real
# policy, bwrap, Landlock and the fence.
RSpec.describe "The XDG epic home inside the reader sandbox", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }

  around do |example|
    Dir.mktmpdir("lain-epic-home-sandbox") do |dir|
      @base = File.realpath(dir)
      @home, @repo, @epic = %w[home repo state/epics/demo].map { File.join(@base, _1).tap { |d| FileUtils.mkdir_p(d) } }
      SeedRepo.git(@repo, "init", "-q")
      File.write(File.join(@epic, "epic.md"), "zq_epic_mark\n")
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  def sandboxed
    judging = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo),
                                            home: @home, root: @repo, read_roots: [File.dirname(@epic)])
    masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { judging })
    Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, fence:, journal:,
                               probe: Lain::Confine::Probe.new(fence:, journal:))
                          .wrap(Lain::Exec::Local.new, requirer: "Spec")
  end

  def run_confined(command)
    ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
    request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1")
    sandboxed.call(command:, cwd: @repo, env: {}, timeout: 10, confinement: request)
  end

  it "reads the epic home and refuses a write there, leaving the file unchanged" do
    epic_md = File.join(@epic, "epic.md")

    read = run_confined("cat #{epic_md}")
    written = run_confined("echo x >> #{epic_md}")

    expect([read.exit_status, read.stdout]).to eq([0, "zq_epic_mark\n"]), read.stderr
    expect(written.exit_status).not_to eq(0)
    expect(File.read(epic_md)).to eq("zq_epic_mark\n")
    expect(journal.events.grep(Lain::Telemetry::Sandbox).map(&:profile)).to eq(%i[reader reader])
  end
end
