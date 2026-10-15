# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# A spawned child reads inside its project, its related directories and its own
# tree without asking; a read anywhere else parks for a human. Everything is
# real between the model and the gate: the assembly {Lain::CLI::Wiring} builds,
# the spawn seam, the guard stack and the queue. Only the provider is scripted.
RSpec.describe "A spawned child's read outside its scope", :seam do
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
    Dir.mktmpdir("lain-child-read-scope") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "project")
      @paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(base, "state") })
      FileUtils.mkdir_p([File.join(@home, ".local", "share", "zettelkasten"), File.join(@home, "notes"),
                         File.join(@root, "lib")])
      File.write(File.join(@home, ".local", "share", "zettelkasten", "a.md"), "outside\n")
      File.write(File.join(@home, "notes", "a.md"), "a related note\n")
      File.write(File.join(@root, "lib", "a.rb"), "zq_project_mark = 1\n")
      File.write(File.join(@home, "outside.md"), "zq_outside_mark\n")
      File.symlink(File.join(@home, "outside.md"), File.join(@root, "lib", "linked.md"))
      example.run
    end
  end

  def project = Lain::Project.new(root: @root, cwd: @root, kind: :project, detected_by: :flag)

  def wired(**options)
    wiring = Lain::CLI::Wiring.new(options: { grace: 5, **options }, chronicle: Lain::CLI::Chronicle::Null.new,
                                   status_feed:, project:, paths: @paths)
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: RecordingChannel.new, recorder:, session:, backend:, notice: ->(_line) {})
    [wiring, agent]
  end

  def calls(id, name, input) = tool_response([id, name, input])

  def blocks_sent = provider.requests.flat_map { |request| request.messages.flat_map { |m| Array(m["content"]) } }

  def result_of(id)
    block = blocks_sent.grep(Hash).find { |sent| sent["type"] == "tool_result" && sent["tool_use_id"] == id }
    raise "no tool_result answered #{id}" unless block

    Array(block["content"]).map { |part| part.is_a?(Hash) ? part["text"] : part }.join("\n")
  end

  # The human at the approval surface: keeps each park it saw, noting whether
  # anything had answered before it looked, then answers it. `answer: nil` only
  # watches, for a scenario some other surface decides.
  def answering(task, wiring, seen, settle: 0, answer: :deny)
    task.async do
      loop do
        pending = wiring.approvals.dequeue
        task.sleep(settle)
        seen << [pending, pending.decided?]
        pending.public_send(answer, surface: "spec") if answer
      end
    end
  end

  # The chat's own `subagent` tool spawns the researcher, as the model would.
  def researching(wiring, agent, settle: 0, answer: :deny, &)
    seen = []
    Sync do |task|
      surfaces = [answering(task, wiring, seen, settle:, answer:), *yield(task)]
      task.with_timeout(30) { agent.ask("look around") }
    ensure
      surfaces&.each(&:stop)
    end
    seen
  end

  def child_calls(name, input, judged: [])
    script.push(calls("tu_spawn", "subagent", { "prompt" => "look around" }), calls("tu_child", name, input),
                *judged, text_response("child done"), text_response("parent done"))
  end

  it "parks a researcher's list_files of the operator's home, naming the researcher, and lists nothing" do
    child_calls("list_files", { "path" => File.join(@home, ".local", "share") })
    wiring, agent = wired

    seen = researching(wiring, agent) { [] }

    expect(seen.map { |pending, _| [pending.tool, pending.requester] }).to eq([%w[list_files researcher]])
    expect(result_of("tu_child")).not_to include("zettelkasten")
  end

  it "parks a glob of /" do
    child_calls("glob", { "path" => "/", "pattern" => "**/*.md" })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }.map { |pending, _| pending.tool }).to eq(["glob"])
  end

  it "parks a glob whose pattern leaves the project" do
    child_calls("glob", { "path" => ".", "pattern" => "../../**/*.md" })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }.map { |pending, _| pending.tool }).to eq(["glob"])
  end

  it "refuses a researcher's read of /etc/passwd without parking it, pointing at $HOME" do
    child_calls("read_file", { "path" => "/etc/passwd" })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }).to be_empty
    expect(result_of("tu_child")).to include("refused: /etc/passwd", "home directory is $HOME")
    expect(result_of("tu_child")).not_to include("root:")
  end

  it "refuses a researcher's glob rooted at /etc/group without parking it" do
    child_calls("glob", { "path" => "/etc/group", "pattern" => "*" })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }).to be_empty
    expect(result_of("tu_child")).to include("refused: /etc/group")
  end

  it "parks the main agent's read of /etc/passwd under ask, as before" do
    script.push(calls("tu_parent", "read_file", { "path" => "/etc/passwd" }), text_response("parent done"))
    wiring, agent = wired
    seen = []

    Sync do |task|
      surface = answering(task, wiring, seen)
      task.with_timeout(30) { agent.ask("go") }
    ensure
      surface&.stop
    end

    expect(seen.map { |pending, _| [pending.tool, pending.requester] }).to eq([%w[read_file agent]])
  end

  it "runs a child's grep inside the project with no park" do
    child_calls("grep", { "pattern" => "zq_project_mark", "path" => File.join(@root, "lib") })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }).to be_empty
    expect(result_of("tu_child")).to include("zq_project_mark")
  end

  # A KNOWN GAP, pinned so it cannot change unnoticed: the gate judges the
  # path a call names, and grep follows a file link it walks into, so the
  # outside file's content comes back with nothing parked.
  it "returns an outside file a link in the project points at, unparked, through grep" do
    child_calls("grep", { "pattern" => "zq_outside_mark", "path" => File.join(@root, "lib") })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }).to be_empty
    expect(result_of("tu_child")).to include("zq_outside_mark")
  end

  it "runs a child's read under a related directory with no park" do
    write_config(@root, "sensitivity related: [#{File.join(@home, "notes").inspect}]\n")
    child_calls("read_file", { "path" => File.join(@home, "notes", "a.md") })
    wiring, agent = wired

    expect(researching(wiring, agent) { [] }).to be_empty
    expect(result_of("tu_child")).to include("a related note")
  end

  it "leaves the main agent's list_files outside the project unasked" do
    script.push(calls("tu_parent", "list_files", { "path" => File.join(@home, ".local", "share") }),
                text_response("parent done"))
    wiring, agent = wired
    seen = []

    Sync do |task|
      surface = answering(task, wiring, seen)
      task.with_timeout(30) { agent.ask("go") }
    ensure
      surface&.stop
    end

    expect(seen).to be_empty
    expect(result_of("tu_parent")).to include("zettelkasten")
  end

  it "refuses an auto_approver child's read outside, and parks nothing" do
    script.push(calls("tu_child", "read_file", { "path" => "/etc/hosts" }), text_response("child done"))
    wiring, = wired
    seen = []

    Sync do |task|
      surface = answering(task, wiring, seen)
      task.with_timeout(30) { wiring.role_spawn.never_parking.call(:auto_approver, :fresh, "judge") }
    ensure
      surface&.stop
    end

    expect(seen).to be_empty
    expect(result_of("tu_child")).to include("this child cannot ask a human")
  end

  # An outside read is gated like any other call: in ask mode with no layer
  # nothing but the human releases it.
  it "releases a child's outside list_files only when the human approves it" do
    child_calls("list_files", { "path" => File.join(@home, ".local", "share") })
    wiring, agent = wired

    seen = researching(wiring, agent, settle: 0.5, answer: :approve) { [] }

    expect(seen.map { |pending, decided| [pending.tool, decided, pending.surface] })
      .to eq([["list_files", false, "spec"]])
    expect(result_of("tu_child")).to include("zettelkasten")
  end

  # With the auto_approve layer on, the automatic approver may answer it, as it
  # may any parked call that carries no region.
  it "releases a child's outside list_files on the automatic approver's approve" do
    child_calls("list_files", { "path" => File.join(@home, ".local", "share") }, judged: [text_response("APPROVE")])
    wiring, agent = wired
    wiring.instance_variable_get(:@switchboard).mode_switch
          .switch(Lain::Mode.new(layers: %i[auto_approve]), surface: "spec")

    seen = researching(wiring, agent, answer: nil) do |task|
      [task.async { wiring.auto_surface.watch(wiring.approvals) }]
    end

    expect(seen.map { |pending, _| [pending.tool, pending.surface] })
      .to eq([["list_files", Lain::Approval::AutoSurface::SURFACE]])
    expect(result_of("tu_child")).to include("zettelkasten")
  end
end
