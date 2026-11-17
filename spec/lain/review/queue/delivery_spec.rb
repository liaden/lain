# frozen_string_literal: true

require "delegate"
require "json"
require "socket"
require "tmpdir"

# Driven against real input sockets and a real Intake behind each, since what
# a sender learns is whatever the chat's own socket says back.
RSpec.describe Lain::Review::Queue::Delivery, :seam do
  subject(:delivery) do
    described_class.new(live_sessions: Lain::LiveSessions.new(paths:), account:, pending:, shell_out_factory:,
                        greeting: 0.5)
  end

  let(:herdr_env) { {} }
  let(:started) { [] }
  let(:workspaces) do
    Struct.new(:started) do
      def create(**call) = (started << call) && "w9:p1"

      def include?(_label) = false
    end.new(started)
  end
  let(:pending) { Lain::Review::Queue::Pending.new(paths:, env: herdr_env, workspaces:) }

  let(:paths) do
    Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "XDG_RUNTIME_DIR" => File.join(@dir, "run") })
  end
  let(:log) { Lain::Review::Queue::Log.new(paths:) }
  let(:account) { Struct.new(:environment).new({ "GH_TOKEN" => "gho_account" }) }
  let(:gh) { [] }
  let(:shell_out_factory) do
    lambda do |*argv, **options|
      gh << [argv, options]
      Struct.new(:run_command).new(Struct.new(:exitstatus, :stdout, :stderr).new(0, "", ""))
    end
  end
  let(:url) { "https://github.com/fuze/api/pull/12" }
  let(:writer) { Lain::Liveness::Writer.current }
  let(:sockets) { [] }
  let(:servers) { [] }
  # The rail every offer reaches, recording what reached it.
  let(:recording) do
    Class.new(SimpleDelegator) do
      attr_accessor :delay

      def offers = @offers ||= []

      def offer(request, &decided)
        offers << request.to_h
        sleep(delay.to_f)
        super
      end
    end
  end

  around do |example|
    Dir.mktmpdir("lain-delivery") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  after do
    sockets.each(&:stop)
    servers.each { |server, thread| thread.kill.join && server.close }
  end

  def clone_at(path, origin)
    dir = FileUtils.mkdir_p(File.join(@dir, "roots", path)).first
    FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", dir)
    SeedRepo.git(dir, "remote", "add", "origin", origin)
    dir
  end

  def checkouts = Lain::Review::Queue::Checkouts.new(roots: [File.join(@dir, "roots")])

  def pull(at = url) = Lain::Review::Queue::Request.load({ "kind" => "pr", "url" => at }, checkouts:)

  def row(request, id: "pr:fuze/api#12")
    Lain::Review::Queue::Row.new(id:, rank: :direct, reason: "direct", request:, head_sha: "c" * 40)
  end

  def answered(rail, text)
    prompt = wait_until(reason: "the offer drawn") { rail.published.kind == :human && rail.published }
    rail << Lain::Frontend::Intake::Line.new(text:, generation: prompt.generation)
  end

  # A live chat at `root`, listening on a real socket.
  def chat(root, id:, started_at: "2026-11-16T10:00:00Z", delay: 0)
    rail = recording.new(Lain::Frontend::Intake.new).tap { _1.delay = delay }
    path = Lain::CLI::InputSocket.path(cwd: root, name: id, paths:)
    sockets << Lain::CLI::InputSocket.new(rail:, path:, log:).bind.start(nil)
    live(id, root, path, started_at)
    rail
  end

  def live(id, root, path, started_at)
    Lain::LiveSessions.new(paths:).enter(
      Lain::LiveSessions::Record.new(session_id: id, pid: writer.pid, start: writer.start, host: writer.host, root:,
                                     cwd: root, input_socket: path, journal: nil, attended: true, started_at:)
    )
  end

  # A listener that accepts and then says only what it is given, if anything:
  # `says` on accepting, and `answers` once an offer arrives.
  def stand_in(root, id:, started_at:, says: [], answers: [])
    path = File.join(@dir, "run", "#{id}.sock")
    FileUtils.mkdir_p(File.dirname(path))
    server = UNIXServer.new(path)
    held = []
    thread = Thread.new do
      Enumerator.produce { server.accept }.each do |io|
        held << io
        says.each { |frame| io.puts(frame) }
        io.gets && answers.each { |frame| io.puts(frame) }
      end
    end
    servers << [server, thread]
    live(id, root, path, started_at)
  end

  context "with the chat in the row's checkout at rest" do
    let!(:api) { clone_at("fuze/api", "https://github.com/fuze/api.git") }
    let!(:rail) { chat(api, id: "api") }

    it "gets 1 offer frame with the row's request, and the row is not marked seen while the human has not answered" do
      request = pull
      result = delivery.call(row(request))

      expect([result.outcome, rail.offers, log.seen?(row(request))]).to eq([:held, [request.to_h], false])
    end

    it "has the row marked seen by the chat once the human presses Enter there" do
      delivery.call(row(pull))
      answered(rail, "")

      expect(wait_until(reason: "the row marked seen") { log.seen?(row(pull)) }).to be(true)
    end

    it "leaves the row unseen once the human drops it with x" do
      delivery.call(row(pull))
      answered(rail, "x")
      wait_until(reason: "the offer withdrawn") { rail.published.kind.nil? }

      expect(log.seen?(row(pull))).to be(false)
    end

    it "is crowded while another offer waits there, and the row is not marked seen" do
      delivery.call(row(pull("#{url}3"), id: "pr:fuze/api#123"))
      result = delivery.call(row(pull))

      expect([result.outcome, log.seen?(row(pull))]).to eq([:crowded, false])
    end

    it "is a repeat when the same request is offered already" do
      first = delivery.call(row(pull))
      again = delivery.call(row(pull))

      expect([first.outcome, again.outcome, rail.offers.size]).to eq([:held, :repeat, 2])
    end

    it "is refused naming the field when the chat cannot rebuild the line, and the row is not marked seen" do
      dirty = Lain::Review::Queue::Request.load({ "kind" => "dirty", "repo_root" => api }, checkouts:)
      result = delivery.call(row(dirty, id: "dirty:#{api}"))

      expect([result.outcome, result.field, log.seen?(row(dirty, id: "dirty:#{api}"))])
        .to eq([:refused, "repo_root", false])
    end
  end

  it "never sends a row to a chat in another repository's checkout, and holds it for its own" do
    api = clone_at("fuze/api", "https://github.com/fuze/api.git")
    other = chat(clone_at("fuze/web", "https://github.com/fuze/web.git"), id: "web")
    result = delivery.call(row(pull))

    held = pending.take(api, notice: ->(_) {})

    expect([result.outcome, other.offers, log.seen?(row(pull)), held&.request&.to_h, held&.mark])
      .to eq([:pending, [], false, { "kind" => "pr", "url" => url },
              Lain::Review::Queue::Mark.new(id: "pr:fuze/api#12", head_sha: "c" * 40)])
  end

  context "when no chat runs in the checkout, inside herdr" do
    let(:herdr_env) { { "HERDR_ENV" => "1" } }

    it "holds the review and starts a cockpit there" do
      api = clone_at("fuze/api", "https://github.com/fuze/api.git")
      result = delivery.call(row(pull))

      expect([result.outcome, started.map { _1[:cwd] }, pending.take(api, notice: ->(_) {}).nil?])
        .to eq([:started, [api], false])
    end
  end

  it "offers to the newest of 2 chats in 1 checkout and names the other" do
    api = clone_at("fuze/api", "https://github.com/fuze/api.git")
    older = chat(api, id: "nine", started_at: "2026-11-16T09:00:00Z")
    newer = chat(api, id: "ten", started_at: "2026-11-16T10:00:00Z")
    result = delivery.call(row(pull))

    expect([result.outcome, result.chat.session_id, result.others.map(&:session_id), newer.offers.size,
            older.offers]).to eq([:held, "ten", ["nine"], 1, []])
  end

  it "waits past the greeting's bound for a chat slow to build the line, and is held" do
    api = clone_at("fuze/api", "https://github.com/fuze/api.git")
    rail = chat(api, id: "api", delay: 1.5)
    result = delivery.call(row(pull))

    expect([result.outcome, rail.offers.size]).to eq([:held, 1])
  end

  it "holds a dirty tree whose snapshot outlasts the greeting's bound" do
    api = clone_at("fuze/api", "https://github.com/fuze/api.git")
    File.write(File.join(api, "README"), "changed\n")
    rail = chat(api, id: "api")
    dirty = row(Lain::Review::Queue::Request.load({ "kind" => "dirty", "repo_root" => api }, checkouts:),
                id: "dirty:#{api}")
    bin = FileUtils.mkdir_p(File.join(@dir, "slow-git")).first
    git = Lain::Shell::Path.find("git", path: ENV.fetch("PATH"))
    File.write(File.join(bin, "git"),
               "#!/bin/sh\ncase \" $* \" in *\" write-tree \"*) sleep 1.5;; esac\nexec #{git} \"$@\"\n")
    File.chmod(0o755, File.join(bin, "git"))
    result = with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") { delivery.call(dirty) }

    expect([result.outcome, rail.offers.size]).to eq([:held, 1])
  end

  it "passes over the chat's prompt frames to find its reply" do
    api = clone_at("fuze/api", "https://github.com/fuze/api.git")
    stand_in(api, id: "busy", started_at: "2026-11-16T10:00:00Z",
                  says: [JSON.generate({ "v" => "context", "commands" => [] })],
                  answers: [JSON.generate({ "v" => "prompt", "kind" => "you", "text" => "you> ", "generation" => 1 }),
                            JSON.generate({ "v" => "offered", "outcome" => "held" })])

    expect(delivery.call(row(pull)).outcome).to eq(:held)
  end

  it "opens a pull request with no local checkout in the browser as the configured account, sending nothing" do
    result = delivery.call(row(pull))

    expect([result.outcome, gh]).to eq(
      [:browsed, [[%W[gh pr view --web #{url}], { environment: { "GH_TOKEN" => "gho_account" } }]]]
    )
  end

  describe "a live record whose socket does not answer" do
    let!(:api) { clone_at("fuze/api", "https://github.com/fuze/api.git") }

    it "is skipped, with nothing sent to it, when it never greets, and the offer goes to the next chat" do
      rail = chat(api, id: "ten", started_at: "2026-11-16T10:00:00Z")
      stand_in(api, id: "mute", started_at: "2026-11-16T11:00:00Z")
      result = delivery.call(row(pull))

      expect([result.outcome, result.chat.session_id, result.skipped.map(&:session_id), rail.offers.size])
        .to eq([:held, "ten", ["mute"], 1])
    end

    it "is not named among the other chats once skipped" do
      chat(api, id: "ten", started_at: "2026-11-16T10:00:00Z")
      stand_in(api, id: "mute", started_at: "2026-11-16T11:00:00Z")

      expect(delivery.call(row(pull)).others).to eq([])
    end

    it "is skipped when nothing listens on its path" do
      rail = chat(api, id: "ten", started_at: "2026-11-16T10:00:00Z")
      live("gone", api, File.join(@dir, "run", "gone.sock"), "2026-11-16T11:00:00Z")
      result = delivery.call(row(pull))

      expect([result.outcome, result.skipped.map(&:session_id), rail.offers.size]).to eq([:held, ["gone"], 1])
    end

    it "is silent, not seen, and tried no further, when it greets but never replies to the offer" do
      stub_const("Lain::Review::Queue::Delivery::REPLY", 0.3)
      rail = chat(api, id: "ten", started_at: "2026-11-16T10:00:00Z")
      stand_in(api, id: "old", started_at: "2026-11-16T11:00:00Z",
                    says: [JSON.generate({ "v" => "context", "commands" => [] })])
      result = delivery.call(row(pull))

      expect([result.outcome, result.chat.session_id, rail.offers, log.seen?(row(pull))])
        .to eq([:silent, "old", [], false])
    end
  end
end
