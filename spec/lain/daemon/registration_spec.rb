# frozen_string_literal: true

require "async"
require "msgpack"
require "socket"
require "timeout"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module RegistrationSpecSupport
  # Plays the daemon on the far end of 1 connection: answers each request,
  # records it, and pushes or hangs up when told.
  class StandIn
    attr_reader :calls

    # @param refuse [String, nil] the error session.register answers with
    # @param push_first [Array, nil] a push sent before session.register is answered
    def initialize(refuse: nil, push_first: nil)
      @refuse = refuse
      @push_first = push_first
      @calls = []
      @ours, @peer = UNIXSocket.socketpair
    end

    # @return [Lain::Core::Client] connected and handshaken, as {Lain::Daemon.ensure} answers
    def client(pushes:)
      @serving = Async { serve }
      Lain::Core::Client.start(transport: Lain::Core::Transport::Mock.new(socket: @ours), pushes:)
    end

    def push(method, params) = write([Lain::Core::Client::PUSH, method, params])

    def hang_up = @peer.close

    def hung_up? = @serving&.finished?

    def registered = @calls.select { |call| call.first == "session.register" }

    private

    def serve
      MessagePack::Unpacker.new(@peer).each { |_kind, msgid, method, params| answer(msgid, method, params) }
    rescue IOError, SystemCallError
      nil
    ensure
      @peer.close unless @peer.closed?
    end

    def answer(msgid, method, params)
      @calls << [method, params]
      push(*@push_first) if method == "session.register" && @push_first
      write([Lain::Core::Client::RESPONSE, msgid, *reply(method)])
    end

    def reply(method)
      case method
      when "ping" then [nil, { "version" => Lain::Core::Client::PROTOCOL_VERSION, "pid" => 1 }]
      when "session.register" then [@refuse, nil]
      else [nil, "answered #{method}"]
      end
    end

    def write(frame) = @peer.write(MessagePack.pack(frame))
  end
  # 1 chat of its own launch in its own process: registers, answers each line
  # on stdin with how many times it has connected, and closes at EOF.
  LAUNCH_CHAT = <<~RUBY
    require "lain"
    session_id, lain = ARGV
    paths = Lain::Paths.new
    launch = Lain::Daemon::Launch.current(paths:).with(lain:)
    writer = Lain::Liveness::Writer.current
    record = Lain::LiveSessions::Record.new(session_id:, pid: Process.pid, start: writer.start, host: writer.host,
                                            root: "/r", cwd: "/r", input_socket: nil, journal: nil, attended: true,
                                            started_at: "2026-11-17T10:00:00Z")
    connects = 0
    registration = Lain::Daemon::Registration.new(record:, notes: $stderr, daemon: lambda { |pushes:, replace:|
      connects += 1
      Lain::Daemon.ensure(paths:, launch:, pushes:, replace:)
    })
    Sync do |task|
      registration.open(task)
      while $stdin.gets
        $stdout.puts(connects)
        $stdout.flush
      end
    ensure
      registration.close
    end
  RUBY

  # Each chat is stopped by its pid however the example ends.
  class LaunchChat
    def initialize(env, session_id, lain)
      @io = IO.popen(env, [RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", LAUNCH_CHAT,
                           session_id, lain], "r+")
    end

    # @return [Integer] how many times it has connected so far
    def connects
      @io.puts
      Integer(Timeout.timeout(10) { @io.gets })
    end

    def stop
      @io.close_write
      Timeout.timeout(10) { @io.read }
    rescue Timeout::Error
      Process.kill("KILL", @io.pid)
    ensure
      @io.close
    end
  end
end

RSpec.describe Lain::Daemon::Registration do
  let(:writer) { Lain::Liveness::Writer.current }
  let(:notes) { StringIO.new }
  let(:record) do
    Lain::LiveSessions::Record.new(session_id: "20261117T100000-1", pid: Process.pid, start: writer.start,
                                   host: writer.host, root: "/work/api", cwd: "/work/api", input_socket: nil,
                                   journal: nil, attended: true, started_at: "2026-11-17T10:00:00Z")
  end

  let(:replaced) { [] }
  let(:delays) { [] }
  let(:unreachable) { Lain::Core::Transport::Unix::Unreachable.new("/run/daemon.sock", Errno::ENOENT.new) }

  # Each connect answers the next stand-in, so a reconnect reaches a new one.
  # The sleeper records each backoff and only yields, so no example waits on a clock.
  def over(*answers)
    asked = answers.dup
    described_class.new(record:, notes:, sleeper: ->(seconds) { (delays << seconds) && Async::Task.current.yield },
                        daemon: lambda { |pushes:, replace:|
                          replaced << replace
                          answer = asked.shift
                          raise answer if answer.is_a?(Exception)

                          answer.respond_to?(:client) ? answer.client(pushes:) : answer
                        })
  end

  def reconnecting(registration, from:, until_heard: 1)
    heard = []
    registration.on(described_class::RECONNECTED) { heard << :reconnected }
    Sync do |task|
      opened(registration, task) do
        from.hang_up
        pumped_until(task, reason: "the reconnect") { heard.size >= until_heard || !notes.string.empty? }
        yield task if block_given?
      end
    end
    heard
  end

  def opened(registration, task)
    registration.open(task)
    yield registration
  ensure
    registration.close
  end

  describe "with a daemon there" do
    it "registers its record on the connection it opens" do
      daemon = RegistrationSpecSupport::StandIn.new

      Sync do |task|
        opened(over(daemon), task) { expect(daemon.registered).to eq([["session.register", [record.to_h]]]) }
      end
    end

    it "sends a request and answers what the daemon answered" do
      daemon = RegistrationSpecSupport::StandIn.new

      Sync do |task|
        opened(over(daemon), task) do |registration|
          expect(registration.call("agenda.publish", { "id" => 1 })).to eq("answered agenda.publish")
          expect(daemon.calls.last).to eq(["agenda.publish", [{ "id" => 1 }]])
        end
      end
    end

    it "hands each pushed frame to the 1 subscriber of its method" do
      daemon = RegistrationSpecSupport::StandIn.new
      heard = Hash.new { |all, method| all[method] = [] }

      Sync do |task|
        registration = over(daemon)
        registration.on("answer") { |params| heard["answer"] << params }
        registration.on("offer") { |params| heard["offer"] << params }
        opened(registration, task) do
          daemon.push("unheard", [0])
          daemon.push("answer", [1])
          daemon.push("offer", [2])
          pumped_until(task, reason: "both pushes delivered") { heard.values.sum(&:size) == 2 }
        end
      end

      expect(heard).to eq("answer" => [[1]], "offer" => [[2]])
    end

    it "refuses a second subscriber to one method" do
      registration = over

      registration.on("answer") { nil }

      expect { registration.on("answer") { nil } }.to raise_error(described_class::Taken, /answer/)
    end

    it "hangs up when closed, and does not come back" do
      daemon = RegistrationSpecSupport::StandIn.new
      spare = RegistrationSpecSupport::StandIn.new

      Sync do |task|
        opened(over(daemon, spare), task) { nil }
        pumped_until(task, reason: "the daemon's end closed") { daemon.hung_up? }
      end

      expect(spare.calls).to be_empty
    end
  end

  describe "when the daemon goes away" do
    it "re-registers before it delivers anything else, and tells :reconnected first" do
      first = RegistrationSpecSupport::StandIn.new
      second = RegistrationSpecSupport::StandIn.new(push_first: ["offer", [7]])
      heard = []

      Sync do |task|
        registration = over(first, second)
        registration.on(described_class::RECONNECTED) { heard << :reconnected }
        registration.on("offer") { |params| heard << params }
        opened(registration, task) do
          first.hang_up
          pumped_until(task, reason: "the reconnect and the offer") { heard.size == 2 }
        end
      end

      expect(heard).to eq([:reconnected, [7]])
      expect(second.registered).to eq([["session.register", [record.to_h]]])
    end

    it "is registered with the new daemon by the time :reconnected is heard" do
      first = RegistrationSpecSupport::StandIn.new
      second = RegistrationSpecSupport::StandIn.new
      registered_when_heard = []
      registration = over(first, second)
      registration.on(described_class::RECONNECTED) { registered_when_heard << second.registered.size }

      Sync do |task|
        opened(registration, task) do
          first.hang_up
          pumped_until(task, reason: "the reconnect") { registered_when_heard.any? }
        end
      end

      expect(registered_when_heard).to eq([1])
    end

    it "still hands on what the lost connection pushed before it went" do
      first = RegistrationSpecSupport::StandIn.new
      gate = Async::Queue.new
      heard = []
      registration = over(first, RegistrationSpecSupport::StandIn.new)
      registration.on("offer") do |params|
        gate.dequeue if params == [1]
        heard << params
      end

      Sync do |task|
        opened(registration, task) do |opening|
          first.push("offer", [1])
          first.push("offer", [2])
          first.hang_up
          expect { opening.call("ping") }.to raise_error(Lain::Core::Died)
          10.times { task.yield }
          gate.enqueue(:go)
          pumped_until(task, reason: "both offers") { heard.size == 2 }
        end
      end

      expect(heard).to eq([[1], [2]])
    end

    it "may replace a daemon from another launch when it opens, and only attaches when it reconnects" do
      first = RegistrationSpecSupport::StandIn.new

      reconnecting(over(first, RegistrationSpecSupport::StandIn.new), from: first)

      expect(replaced).to eq([true, false])
    end

    it "backs off from half a second, doubling to 30 seconds, while the daemon cannot be reached" do
      first = RegistrationSpecSupport::StandIn.new
      second = RegistrationSpecSupport::StandIn.new

      reconnecting(over(first, *Array.new(8) { unreachable }, second), from: first)

      expect(delays).to eq([0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0])
      expect(second.registered.size).to eq(1)
    end

    it "tries again after an error that is not lain's own" do
      first = RegistrationSpecSupport::StandIn.new
      second = RegistrationSpecSupport::StandIn.new

      heard = reconnecting(over(first, Errno::EACCES.new("/run/lain/daemon"), second), from: first)

      expect(heard).to eq([:reconnected])
      expect(second.registered.size).to eq(1)
    end

    it "says nothing for 2 failures in a row" do
      first = RegistrationSpecSupport::StandIn.new

      reconnecting(over(first, unreachable, unreachable, RegistrationSpecSupport::StandIn.new), from: first)

      expect(notes.string).to be_empty
    end

    it "says once, after 3 failures in a row, that it is still trying" do
      first = RegistrationSpecSupport::StandIn.new
      second = RegistrationSpecSupport::StandIn.new
      registration = over(first, *Array.new(5) { unreachable }, second)
      heard = []
      registration.on(described_class::RECONNECTED) { heard << :reconnected }

      Sync do |task|
        opened(registration, task) do
          first.hang_up
          pumped_until(task, reason: "the reconnect") { heard.any? }
        end
      end

      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to match(/lost the daemon.*no lain-core listens.*still trying/)
    end

    it "stops trying once the daemon refuses the registration" do
      first = RegistrationSpecSupport::StandIn.new
      refusing = RegistrationSpecSupport::StandIn.new(refuse: "pid 1 runs inside session a, which is registered")
      spare = RegistrationSpecSupport::StandIn.new

      reconnecting(over(first, refusing, spare), from: first)

      expect(spare.calls).to be_empty
      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to match(/review queue cannot find this chat.*runs inside session a/)
    end

    it "stops trying once there is no daemon to come back to" do
      first = RegistrationSpecSupport::StandIn.new
      spare = RegistrationSpecSupport::StandIn.new

      reconnecting(over(first, Lain::Daemon::Absent.new(reason: "the daemon is off"), spare), from: first)

      expect(spare.calls).to be_empty
      expect(notes.string.lines.size).to eq(1)
    end
  end

  describe "with no daemon" do
    it "lets the chat run, says once that the review queue cannot find it, and answers nothing" do
      Sync do |task|
        opened(over(Lain::Daemon::Absent.new(reason: "the daemon is off")), task) do |registration|
          expect(registration.call("agenda.publish", {})).to be_nil
        end
      end

      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to eq("the review queue cannot find this chat\n")
    end

    it "lets the chat run when connecting fails with an error that is not lain's own" do
      Sync do |task|
        opened(over(Errno::EACCES.new("/run/lain/daemon")), task) do |registration|
          expect(registration.call("agenda.publish", {})).to be_nil
        end
      end

      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to match(/review queue cannot find this chat.*Permission denied/)
    end

    it "treats a refused registration the same way" do
      daemon = RegistrationSpecSupport::StandIn.new(refuse: "pid 4300 runs inside session a, which is registered")

      Sync do |task|
        opened(over(daemon), task) do |registration|
          expect(registration.call("agenda.publish", {})).to be_nil
        end
      end

      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to match(/review queue cannot find this chat.*runs inside session a/)
    end
  end

  describe "against the real daemon", :daemon do
    def registration
      described_class.new(record:, notes:, daemon: lambda { |pushes:, replace:|
        Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env, pushes:, replace:)
      })
    end

    def listed
      client = Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env)
      client.call("session.list").tap { client.stop }
    end

    # Only attaches: a listing from this process must never start or replace a daemon.
    def attached
      socket = Lain::Daemon.socket(paths: daemon_paths)
      client = Lain::Core::Client.start(transport: Lain::Core::Transport::Unix.new(socket))
      yield(client).tap { client.stop }
    rescue Lain::Core::Transport::Unix::Unreachable, Lain::Core::Died
      nil
    end

    def daemon_pid
      client = Lain::Daemon.ensure(paths: daemon_paths, env: daemon_env)
      client.call("ping").fetch("pid").tap { client.stop }
    end

    it "is listed by its journal stem while open, and not once closed" do
      Sync do |task|
        opened(registration, task) do
          expect(listed).to contain_exactly(include("session_id" => record.session_id, "pid" => Process.pid,
                                                    "root" => "/work/api", "attended" => true,
                                                    "start" => writer.start))
        end
        pumped_until(task, reason: "the session dropped") { listed.empty? }
      end
    end

    it "keeps 1 daemon for 2 chats of 2 launches sharing a runtime dir, even once it is restarted" do
      chats = { "a" => "/checkout-a/exe/lain", "b" => "/checkout-b/exe/lain" }.map do |id, lain|
        RegistrationSpecSupport::LaunchChat.new(daemon_env, id, lain)
      end
      both = -> { (attached { _1.call("session.list") } || []).map { _1.fetch("session_id") }.sort == %w[a b] }

      Sync do |task|
        pumped_until(task, timeout: 20, reason: "both chats listed") { both.call }
        first = attached { _1.call("ping").fetch("pid") }
        Process.kill("TERM", first)
        pumped_until(task, timeout: 20, reason: "both listed again") do
          [nil, first].none?(attached { _1.call("ping").fetch("pid") }) && both.call
        end

        expect(chats.map(&:connects)).to all(be <= 3)
        expect(both.call).to be(true)
      end
    ensure
      chats&.each(&:stop)
    end

    it "registers again with a restarted daemon and tells its subscribers" do
      heard = []

      Sync do |task|
        opened(registration.tap { |opening| opening.on(described_class::RECONNECTED) { heard << :reconnected } },
               task) do
          killed = daemon_pid
          Process.kill("TERM", killed)
          pumped_until(task, timeout: 10, reason: "the reconnect") { heard.any? }

          expect(daemon_pid).not_to eq(killed)
          expect(listed.map { _1.fetch("session_id") }).to eq([record.session_id])
        end
      end
    end
  end
end
