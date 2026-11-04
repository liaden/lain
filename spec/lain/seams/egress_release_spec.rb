# frozen_string_literal: true

require "tmpdir"
require "webmock/rspec"

# A release reaching the egress guard through the run's one ledger: a real board's read path
# releases into it, and the Backend it is attached to reads it back before a request leaves.
# Only a human's release, at a path the classifier marks secret, lifts a refusal.
RSpec.describe "A released secret reaching the egress guard", :seam do
  let(:url) { "https://api.anthropic.com/v1/messages" }
  let(:api_key) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }
  let(:password) { "qW3eR7tY1uI5oP9aS2dF6gH0jK4lZ8xC3vB7nM1qW5eR9tY2" }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "egress-release.ndjson") }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::ReadFile.new]) }
  let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {})) }

  around do |example|
    Dir.mktmpdir("egress-release") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "repo")
      FileUtils.mkdir_p([@home, @root])
      SeedRepo.git(@root, "init", "-q")
      example.run
    end
  end

  before { stub_request(:post, url).to_return(ok) }

  def ok
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("id" => "m", "type" => "message", "role" => "assistant", "model" => "claude-haiku-5-5",
                          "content" => [{ "type" => "text", "text" => "ok" }], "stop_reason" => "end_turn",
                          "usage" => { "input_tokens" => 1, "output_tokens" => 1 }) }
  end

  def write(name, content) = File.join(@root, name).tap { File.write(_1, content) }

  def policy
    @policy ||= Lain::Sensitivity::Policy.new(
      sensitivity: Lain::Sensitivity.new(home: @home, cwd: @root, root: @root), home: @home, root: @root
    )
  end

  # Built after the files are written, so the history walk primes over them. Unattended, it
  # bypasses, which is how a --non-interactive run reaches a .env at all.
  def board(attended: true)
    @board ||= begin
      history = Lain::Sensitivity::HistoryLiterals.new(root: @root, policy:).prime
      secrets = Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env: {}), history:)
      Lain::CLI::Switchboard.new(journal: chronicle.record_journal, model: "claude-haiku-5-5", toolset:,
                                 sensitivity: policy, secrets:, attended:, approval: attended ? :ask : :bypass)
    end
  end

  def backend
    @backend ||= attached(with_env("ANTHROPIC_API_KEY" => "sk-egress-release") do
      Lain::CLI::Backend.new({ provider: "anthropic", model: "claude-haiku-5-5", max_tokens: 64 }, root: @root)
    end)
  end

  def attached(backend) = backend.tap { _1.attach(board, Lain::Channel.new) }

  def dispatch(path)
    stack = Lain::CLI::ToolGuard.stack(chronicle, board)
    dispatch_call("read_file", { "path" => path }, toolset: board.toolset, layers: stack.to_a, context: session)
  end

  # A human at the keyboard answers the path gate and then the release, `release` at the release.
  def read(path, release: true)
    Sync do |task|
      answerer = task.async do
        loop do
          pending = board.approvals.dequeue
          approve = pending.outstanding.none? || release
          verdict = approve ? Lain::Approval::Verdict::Approve.new : Lain::Approval::Verdict::Deny.new
          pending.decide(verdict, surface: "spec", authority: :human)
        end
      end
      dispatch(path).tap { answerer.stop }
    end
  end

  def send_text(text)
    request = Lain::Request.new(model: "claude-haiku-5-5", max_tokens: 64, stream: false,
                                messages: [{ role: "user", content: text }])
    with_env("ANTHROPIC_API_KEY" => "sk-egress-release") { backend.provider(journal:).complete(request) }
    :sent
  rescue Lain::Provider::HTTP::EgressGuard::Refused
    :refused
  end

  def kinds = journal.events.filter_map { _1.to_journal["type"] if _1.respond_to?(:to_journal) }

  it "sends the next request once a human releases a quoted value at the secret path" do
    path = write(".env", "API_KEY=\"#{api_key}\"\n")
    backend

    content = read(path).content

    expect(content).to include(api_key)
    expect(send_text("the file says #{content}")).to eq(:sent)
    expect(kinds).to include("read_released")
    expect(kinds).not_to include("egress_refused")
  end

  it "refuses the value when the human declines the release" do
    path = write(".env", "API_KEY=#{api_key}\n")
    backend

    read(path, release: false)

    expect(send_text("echoing #{api_key}")).to eq(:refused)
    expect(kinds).to include("egress_refused")
  end

  it "refuses a second secret when only the first was released" do
    path = write(".env", "API_KEY=#{api_key}\nDB_PASSWORD=#{password}\n")
    backend
    first = Lain::Sensitivity::Regions.detect(File.read(path)).select { _1.bytes == api_key.b }

    board.ledger.release(path, first, authority: :human)

    expect([send_text("first #{api_key}"), send_text("second #{password}")]).to eq(%i[sent refused])
  end

  it "refuses a value a human released from a copy at an ordinary path" do
    write(".env", "API_KEY=#{api_key}\n")
    copy = write("leak.txt", "API_KEY=#{api_key}\n")
    backend

    expect(read(copy).content).to include(api_key)
    expect(send_text("the copy says #{api_key}")).to eq(:refused)
  end

  describe "an unattended board, whose read releases automatically" do
    %w[.env notes.txt].each do |name|
      it "still refuses the value after it reads #{name}" do
        env = write(".env", "API_KEY=#{api_key}\n")
        path = name == ".env" ? env : write(name, "copied from env: api_key = #{api_key}\n")
        board(attended: false)
        backend

        expect(dispatch(path).content).to include(api_key)
        expect(send_text("after the read: #{api_key}")).to eq(:refused)
      end
    end
  end

  describe "a value inside a larger literal" do
    { "a connection URL" => ->(key) { "DATABASE_URL=postgres://app:#{key}@db.internal:5432/app\n" },
      "an assignment with a trailing comment" => ->(key) { "API_KEY=#{key} # prod\n" },
      "a JSON line" => ->(key) { "{\"api_key\": \"#{key}\"}\n" } }.each do |form, body|
      it "sends #{form} once a human releases it" do
        path = write(".env", body.call(api_key))
        backend

        content = read(path).content

        expect(content).to include(api_key)
        expect(send_text("the file says #{content}")).to eq(:sent)
      end
    end
  end
end
