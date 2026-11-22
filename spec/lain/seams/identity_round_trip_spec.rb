# frozen_string_literal: true

require "json"
require "tmpdir"
require "webmock/rspec"

# The person and the box leave the machine only as placeholders, and come back
# as the real values wherever the model hands them to a tool. A production
# Backend attached to a real board sends every request through its egress
# guard, and the board's own tool stack restores what the model wrote. The
# home is a temporary directory standing in for /home/alice, so the tools
# have a real tree to read and write.
RSpec.describe "Identity aliased on the way out and restored on the way in", :seam do
  let(:url) { "https://api.anthropic.com/v1/messages" }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "identity-round-trip.ndjson") }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new, Lain::Tools::WriteFile.new]) }
  let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {})) }
  let(:context) { Lain::Context.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false) }
  let(:sent) { [] }

  # Not a mktmpdir name, nor a pid: random digits read as a high-entropy
  # token, and the read masker would hide the home path before any alias
  # could. One directory per parallel worker.
  around do |example|
    base = File.join(File.realpath(Dir.tmpdir), "identity-round-trip#{ENV.fetch("TEST_ENV_NUMBER", "")}")
    @home = File.join(base, "alice")
    @root = File.join(@home, "dev", "app")
    FileUtils.mkdir_p(@root)
    SeedRepo.git(@root, "init", "-q")
    with_env("ANTHROPIC_API_KEY" => "sk-identity-round-trip") { example.run }
  ensure
    FileUtils.rm_rf(base)
  end

  # The process's identity is read once and kept, so this box's own stands in for alice only through the
  # one reader every production path asks.
  before do
    alice = Lain::Sensitivity::Secrets::Identity.current(env: { "HOME" => @home, "USER" => "alice" }, git: ->(_) {},
                                                         hostname: "wonder")
    allow(Lain::Sensitivity::Secrets::Identity).to receive(:session).and_return(alice)
  end

  def reply(content, stop_reason)
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("id" => "m", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
                          "content" => content, "stop_reason" => stop_reason,
                          "usage" => { "input_tokens" => 1, "output_tokens" => 1 }) }
  end

  def text_reply = reply([{ "type" => "text", "text" => "ok" }], "end_turn")

  def replies(*scripted)
    queue = [*scripted, text_reply]
    stub_request(:post, url).to_return { |request| (sent << request.body) && (queue.shift || text_reply) }
  end

  def policy
    @policy ||= Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @root, root: @root), home: @home, root: @root
    )
  end

  # Unattended, so nothing is parked on a human: the writes stay inside the root.
  def board
    @board ||= Lain::CLI::Switchboard.new(journal: chronicle.record_journal, model: "claude-haiku-5-5", toolset:,
                                          sensitivity: policy, attended: false, approval: :bypass)
  end

  def backend
    @backend ||= Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64 },
                                        root: @root).tap { _1.attach(board, Lain::Channel.new) }
  end

  def send_text(text, requester:)
    request = Lain::Request.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false,
                                messages: [{ role: "user", content: text }])
    backend.provider(journal:, requester:).complete(request)
  end

  def dispatch(name, input)
    dispatch_call(name, input, toolset: board.toolset, layers: Lain::CLI::ToolGuard.stack(chronicle, board).to_a,
                               context: session)
  end

  def agent
    Lain::Agent.new(provider: backend.provider(journal:), toolset: board.toolset, context:, session:,
                    tool_middleware: Lain::CLI::ToolGuard.stack(chronicle, board),
                    handler: Lain::Effect::Handler::Live.new(channel: journal))
  end

  def tool_use(name, input)
    reply([{ "type" => "tool_use", "id" => "tu_1", "name" => name, "input" => input }], "tool_use")
  end

  def kinds = journal.events.filter_map { _1.to_journal["type"] if _1.respond_to?(:to_journal) }

  # The judge call and the child turn are send_text calls under those requesters' names: each goes
  # through backend.provider, the one path every tier's provider is built on.
  it "sends a chat turn, a judge call and a child turn with placeholders, and refuses nothing" do
    replies
    state = File.join(@home, ".local", "state", "lain", "worktrees", "child-1")
    epic = File.join(@home, ".local", "share", "lain", "epics", "app")

    send_text("work in #{@root}", requester: :agent)
    send_text("judge a write to #{state}/a.rb", requester: Lain::CLI::Backend::EgressHold::ORACLE)
    send_text("child at #{state}, epic home #{epic}", requester: "child-1")
    send_text("and once more in #{@root}", requester: :agent)

    expect(sent.size).to eq(4)
    expect(sent).to all(include("/home/<lain:user>/"))
    expect(sent.join).to include("/home/<lain:user>/.local/state/lain/worktrees/child-1",
                                 "/home/<lain:user>/.local/share/lain/epics/app", "/home/<lain:user>/dev/app")
    expect(sent.join).not_to include(@home)
    expect(kinds).not_to include("egress_refused")
  end

  it "reads the real file for a path the model wrote with a placeholder" do
    File.write(File.join(@root, "README.md"), "the real readme\n")

    result = dispatch("read_file", { "path" => "/home/<lain:user>/dev/app/README.md" })

    expect([result.is_error, result.content]).to match([false, include("the real readme")])
  end

  it "keeps a file's real contents when the model reads it, edits one line and writes it back" do
    path = File.join(@root, "config.txt")
    File.write(path, "notes live in #{@home}/notes\nlevel 1\n")
    replies

    send_text(dispatch("read_file", { "path" => path }).content, requester: :agent)
    seen = JSON.parse(sent.sole).fetch("messages").first.fetch("content")
    written = seen.lines.first(2).join.sub("level 1", "level 2")
    dispatch("write_file", { "path" => "/home/<lain:user>/dev/app/config.txt", "content" => written })

    expect(seen).to start_with("notes live in /home/<lain:user>/notes\nlevel 1\n")
    expect(File.read(path)).to eq("notes live in #{@home}/notes\nlevel 2\n")
  end

  # Ordinary text holds bare tags like these, which must never turn into the box's values.
  it "writes a file holding bare <host> and <user> tags back unchanged" do
    path = File.join(@root, "site.xml")
    File.write(path, "<host>docs</host>\n<user>guest</user>\n")

    text = dispatch("read_file", { "path" => path }).content.lines.first(2).join
    dispatch("write_file", { "path" => path, "content" => text })

    expect(File.read(path)).to eq("<host>docs</host>\n<user>guest</user>\n")
  end

  it "journals the session's turns with the real values" do
    File.write(File.join(@root, "README.md"), "see #{@home}/notes\n")
    replies(tool_use("read_file", { "path" => "/home/<lain:user>/dev/app/README.md" }))
    path = File.join(@home, "session.ndjson")
    file = Lain::Journal.new(io: File.open(path, "ab"), owns_io: true)
    scribe = Lain::SessionRecord::Scribe.new(journal: file, context:, toolset: board.toolset,
                                             sections: SessionSections.complete)

    run = agent
    run.ask("read the readme in #{@root}")
    scribe.catch_up(run.timeline)
    file.close

    ours = journal_records(path, "turn").select { _1["role"] == "user" }.map { JSON.generate(_1) }.join
    expect(sent.join).not_to include(@home)
    expect(ours).to include("read the readme in #{@root}", "see #{@home}/notes")
    expect(ours).not_to include("/home/<lain:user>")
  end
end
