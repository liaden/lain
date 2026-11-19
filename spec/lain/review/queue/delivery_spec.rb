# frozen_string_literal: true

require "delegate"
require "json"
require "socket"
require "timeout"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module DeliverySpecSupport
  # A rail that records each offer put to it, and can be slow to build one.
  class Recording < SimpleDelegator
    attr_accessor :delay

    def offers = @offers ||= []

    def offer(request, &block)
      offers << request.to_h
      sleep(delay.to_f)
      super
    end
  end

  # 1 chat in a forked process of its own, registered with the daemon in its
  # root, answering `offers` on its end of a socket pair with how many offers
  # reached its human. The daemon refuses a 2nd session from 1 process, so
  # each of 2 chats needs a process. Bounded by its own clock, and stopped by
  # its pid however the example ends.
  class ForkedChat
    BOUND = 30

    attr_reader :pid

    def initialize(record:, paths:, env:, log:)
      @ours, theirs = UNIXSocket.pair
      # exit! on every path: an at_exit inherited from the suite must never run in the child.
      @pid = fork do
        @ours.close
        serve(theirs, record:, paths:, env:, log:)
      ensure
        exit!(0)
      end
      theirs.close
      raise "the chat at #{record.root} never registered" unless Timeout.timeout(BOUND) { @ours.gets } == "ready\n"
    end

    # @return [Integer] how many offers reached this chat's human
    def offers
      @ours.puts("offers")
      Integer(Timeout.timeout(BOUND) { @ours.gets })
    end

    def stop
      @ours.close
      Process.kill("TERM", @pid)
    rescue Errno::ESRCH
      nil
    ensure
      Process.wait(@pid)
    end

    private

    def serve(io, record:, paths:, env:, log:)
      rail = Recording.new(Lain::Frontend::Intake.new)
      DeliverySpecSupport.chat(record: record.with(pid: Process.pid), paths:, env:, log:, rail:) do |task|
        task.with_timeout(BOUND) do
          io.puts("ready")
          io.puts(rail.offers.size) while io.gets
        end
      rescue Async::TimeoutError
        nil
      end
    end
  end

  QUIET = ->(_) {}

  # This process as 1 attended chat, registered with the daemon and taking
  # its offers, for as long as the block runs.
  def self.chat(record:, paths:, env:, log:, rail:)
    registration = Lain::Daemon::Registration.new(record:, notes: StringIO.new, daemon: lambda { |pushes:, replace:|
      Lain::Daemon.ensure(paths:, env:, pushes:, replace:)
    })
    offers = Lain::CLI::Wiring::InputProducer::QueueOffers.new(Lain::Frontend::StdinPump::Idle, registration:, rail:,
                                                                                                log:, notice: QUIET)
    Sync do |task|
      offers.start(task)
      registration.open(task)
      yield task
    ensure
      offers.stop
      registration.close
    end
  end
end

RSpec.describe Lain::Review::Queue::Delivery, :seam do
  subject(:delivery) { described_class.new(account:, pending:, notes:, shell_out_factory:, daemon:) }

  let(:daemon) { -> { Lain::Daemon::Absent.new(reason: "off") } }
  let(:notes) { StringIO.new }
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
    Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => File.join(@dir, "state"),
                                        "XDG_RUNTIME_DIR" => File.join(@dir, "run") }))
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

  around do |example|
    Dir.mktmpdir("lain-delivery") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
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

  def record(id, root, started_at, pid: Process.pid)
    Lain::LiveSessions::Record.new(session_id: id, pid:, start: writer.start, host: writer.host, root:, cwd: root,
                                   input_socket: nil, journal: nil, attended: true, started_at:)
  end

  describe "against the real daemon", :daemon do
    let(:daemon) { -> { Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env) } }

    # This process as the 1 attended chat in `root`.
    def chatting(root, id: "api", started_at: "2026-11-16T10:00:00Z", delay: 0)
      rail = DeliverySpecSupport::Recording.new(Lain::Frontend::Intake.new).tap { _1.delay = delay }
      DeliverySpecSupport.chat(record: record(id, root, started_at), paths: daemon_paths, env: daemon_env, log:,
                               rail:) { yield rail }
    end

    context "with the chat in the row's checkout at rest" do
      let!(:api) { clone_at("fuze/api", "https://github.com/fuze/api.git") }

      it "is held, with the offer put to the chat, and the row is not marked seen while the human has not answered" do
        chatting(api) do |rail|
          request = pull
          result = delivery.call(row(request))

          expect([result.outcome, result.chat.session_id, rail.offers, log.seen?(row(request))])
            .to eq([:held, "api", [request.to_h], false])
        end
      end

      it "has the row marked seen by the chat once the human presses Enter there" do
        chatting(api) do |rail|
          delivery.call(row(pull))
          answered(rail, "")

          expect(wait_until(reason: "the row marked seen") { log.seen?(row(pull)) }).to be(true)
        end
      end

      it "leaves the row unseen once the human drops it with x" do
        chatting(api) do |rail|
          delivery.call(row(pull))
          answered(rail, "x")
          wait_until(reason: "the offer withdrawn") { rail.published.kind.nil? }

          expect(log.seen?(row(pull))).to be(false)
        end
      end

      it "is crowded while another offer waits there, and the row is not marked seen" do
        chatting(api) do
          delivery.call(row(pull("#{url}3"), id: "pr:fuze/api#123"))
          result = delivery.call(row(pull))

          expect([result.outcome, log.seen?(row(pull))]).to eq([:crowded, false])
        end
      end

      it "is a repeat when the same request is offered already" do
        chatting(api) do |rail|
          first = delivery.call(row(pull))
          again = delivery.call(row(pull))

          expect([first.outcome, again.outcome, rail.offers.size]).to eq([:held, :repeat, 2])
        end
      end

      it "is refused naming the field when the chat cannot rebuild the line, and the row is not marked seen" do
        chatting(api) do
          dirty = Lain::Review::Queue::Request.load({ "kind" => "dirty", "repo_root" => api }, checkouts:)
          result = delivery.call(row(dirty, id: "dirty:#{api}"))

          expect([result.outcome, result.field, log.seen?(row(dirty, id: "dirty:#{api}"))])
            .to eq([:refused, "repo_root", false])
        end
      end
    end

    it "never sends a row to a chat in another repository's checkout, and holds it for its own" do
      api = clone_at("fuze/api", "https://github.com/fuze/api.git")
      chatting(clone_at("fuze/web", "https://github.com/fuze/web.git"), id: "web") do |other|
        result = delivery.call(row(pull))
        held = pending.take(api, notice: ->(_) {})

        expect([result.outcome, other.offers, log.seen?(row(pull)), held&.request&.to_h, held&.mark])
          .to eq([:pending, [], false, { "kind" => "pr", "url" => url },
                  Lain::Review::Queue::Mark.new(id: "pr:fuze/api#12", head_sha: "c" * 40)])
      end
    end

    it "offers to the newest of 2 attended chats in 1 checkout, which still waits on a keypress, and names the other" do
      api = clone_at("fuze/api", "https://github.com/fuze/api.git")
      chats = [["nine", "2026-11-16T09:00:00Z"], ["ten", "2026-11-16T10:00:00Z"]].map do |id, at|
        DeliverySpecSupport::ForkedChat.new(record: record(id, api, at, pid: 0), paths: daemon_paths,
                                            env: daemon_env, log:)
      end
      result = delivery.call(row(pull))

      expect([result.outcome, result.chat.session_id, result.others.map(&:session_id), chats.map(&:offers),
              log.seen?(row(pull))]).to eq([:held, "ten", ["nine"], [0, 1], false])
    ensure
      chats&.each(&:stop)
    end

    it "is held for a chat slow to build the line" do
      api = clone_at("fuze/api", "https://github.com/fuze/api.git")
      chatting(api, delay: 1.5) do |rail|
        result = delivery.call(row(pull))

        expect([result.outcome, rail.offers.size]).to eq([:held, 1])
      end
    end

    it "is held for a dirty tree whose snapshot is slow" do
      api = clone_at("fuze/api", "https://github.com/fuze/api.git")
      File.write(File.join(api, "README"), "changed\n")
      dirty = row(Lain::Review::Queue::Request.load({ "kind" => "dirty", "repo_root" => api }, checkouts:),
                  id: "dirty:#{api}")
      bin = FileUtils.mkdir_p(File.join(@dir, "slow-git")).first
      git = Lain::Shell::Path.find("git", path: ENV.fetch("PATH"))
      File.write(File.join(bin, "git"),
                 "#!/bin/sh\ncase \" $* \" in *\" write-tree \"*) sleep 1.5;; esac\nexec #{git} \"$@\"\n")
      File.chmod(0o755, File.join(bin, "git"))
      chatting(api) do |rail|
        result = with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}") { delivery.call(dirty) }

        expect([result.outcome, rail.offers.size]).to eq([:held, 1])
      end
    end
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

  # What the daemon answers offer.send with, from a connection that records the offer it was sent.
  def daemon_answering(answer)
    sent = []
    client = Struct.new(:sent, :answer) do
      def call(method, params) = (sent << [method, params]) && answer

      def stop = nil
    end.new(sent, answer)
    [-> { client }, sent]
  end

  describe "the daemon's answer" do
    let!(:api) { clone_at("fuze/api", "https://github.com/fuze/api.git") }

    it "sends the root, the request and the row, and nothing else" do
      source, sent = daemon_answering({ "session" => nil, "others" => [], "outcome" => "none", "field" => nil })
      described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: source).call(row(pull))

      expect(sent).to eq([["offer.send", [{ "root" => api, "request" => { "kind" => "pr", "url" => url },
                                            "row" => { "id" => "pr:fuze/api#12", "head_sha" => "c" * 40 } }]]])
    end

    it "is silent, and the row not seen, when the chat never replied to the offer" do
      chat = record("old", api, "2026-11-16T11:00:00Z").to_h
      source, = daemon_answering({ "session" => chat, "others" => [], "outcome" => "silent", "field" => nil })
      result = described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: source).call(row(pull))

      expect([result.outcome, result.chat.session_id, log.seen?(row(pull))]).to eq([:silent, "old", false])
    end

    it "holds the review for the next cockpit when the chat has no editor to open it in" do
      chat = record("old", api, "2026-11-16T11:00:00Z").to_h
      source, = daemon_answering({ "session" => chat, "others" => [], "outcome" => "plain", "field" => nil })
      result = described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: source).call(row(pull))

      expect([result.outcome, pending.take(api, notice: lambda { |_|
      })&.request&.to_h]).to eq([:pending, { "kind" => "pr", "url" => url }])
    end

    it "is silent for an outcome no chat says" do
      chat = record("old", api, "2026-11-16T11:00:00Z").to_h
      source, = daemon_answering({ "session" => chat, "others" => [], "outcome" => "taken\e[2J", "field" => nil })
      result = described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: source).call(row(pull))

      expect(result.outcome).to eq(:silent)
    end

    it "holds the review as if no chat ran, saying nothing, when there is no daemon" do
      absent = -> { Lain::Daemon::Absent.new(reason: "the daemon is off") }
      result = described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: absent).call(row(pull))

      expect([result.outcome, notes.string]).to eq([:pending, ""])
    end

    it "holds the review as if no chat ran, saying why, when the daemon cannot be reached" do
      unreached = -> { raise Lain::Daemon::Unstarted, "lain-daemon did not answer" }
      result = described_class.new(account:, pending:, notes:, shell_out_factory:, daemon: unreached).call(row(pull))

      expect([result.outcome, notes.string])
        .to eq([:pending, "cannot offer the review through lain-daemon: lain-daemon did not answer\n"])
    end
  end

  it "opens a pull request with no local checkout in the browser as the configured account, sending nothing" do
    result = delivery.call(row(pull))

    expect([result.outcome, gh]).to eq(
      [:browsed, [[%W[gh pr view --web #{url}], { environment: { "GH_TOKEN" => "gho_account" } }]]]
    )
  end
end
