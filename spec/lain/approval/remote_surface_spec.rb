# frozen_string_literal: true

require "async"
require "fileutils"
require "json"
require "socket"
require "stringio"
require "timeout"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module RemoteSurfaceSpecSupport
  # Nothing deferred and nobody asked: the agenda then lists parked calls alone.
  class NoGates
    def each(&block) = [].each(&block)
  end

  class NoReplies
    def waiting = []
  end

  # One deferred gate whose owner refuses every answer with a lain error, as a
  # gate whose epic document is gone does.
  class RaisingGates
    def each(&block)
      [Lain::Remote::Agenda::Gates::Row.new(digest: "d1", epic: "e", stage: "plan", issue: nil,
                                            question: "sign off?", asked_at: Time.at(0))].each(&block)
    end

    def initialize(message = "no epic document for e") = @message = message

    def approve(*, **) = raise(Lain::CLI::EpicQueue::MissingEpicDocument, @message)
  end

  # One open question, recording each answer with who gave it.
  class OneQuestion
    attr_reader :answers

    def initialize = @answers = []

    def waiting
      return [] if @answers.any?

      [Lain::CLI::HumanReplies::InboxItem.new(question: "which branch?", from: "agent", digest: "blake3:q1",
                                              asked_at: Time.at(0))]
    end

    def answer(text, digest, answered_by: nil) = (@answers << [text, digest, answered_by]) && true
  end

  # One issue-less research gate, recording each answer with who gave it.
  class StageGate
    attr_reader :answers

    def initialize = @answers = []

    def each(&block)
      [Lain::Remote::Agenda::Gates::Row.new(digest: "d1", epic: "e", stage: "research", issue: nil,
                                            question: "sign off?", asked_at: Time.at(0))].each(&block)
    end

    def approve(digest, reason: nil, answered_by: nil) = @answers << [:approve, digest, reason, answered_by]
  end

  # A wave of gate rows the spec can re-ask, as a newer artifact revision does.
  class Wave
    Row = Lain::Remote::Agenda::Gates::Row

    attr_accessor :rows

    def initialize(epic: "e", digests: %w[d1 d2])
      @rows = digests.each_with_index.map do |digest, at|
        Row.new(digest:, epic:, stage: "issue_plan", issue: "i#{at}", question: "sign off?", asked_at: Time.at(at))
      end
    end

    def each(&block) = @rows.each(&block)

    # The last row asked again under a new digest and a later time; the wave's earliest row keeps its time.
    def reask! = @rows[-1] = @rows[-1].with(digest: "#{@rows[-1].digest}-reasked", asked_at: Time.at(100))
  end

  # Gate journals the fold cannot read, whose message names one of them.
  class UnreadableGates
    Unreadable = Class.new(Lain::Error) { include Lain::JournalUnreadable }

    PATH = "/home/someone/.local/state/lain/sessions/9d832bf6a4ad/2026-11-04.ndjson"

    def each = raise(Unreadable, "the session journal #{PATH} holds a gate_decision at line 2")
  end

  # The desk answers each item just before the phone's answer reaches it, so the phone loses.
  class DeskFirst < SimpleDelegator
    def initialize(agenda, queue)
      super(agenda)
      @queue = queue
    end

    def answer(...)
      @queue.each { _1.approve(surface: "desk", authority: :human) unless _1.decided? }
      __getobj__.answer(...)
    end
  end

  # Time the spec moves by hand, so a delay is crossed without waiting for it.
  class Clock
    attr_accessor :now

    def initialize(now) = @now = now
  end

  # Records what it is asked to announce, and the clock's reading at that moment.
  class Ntfy
    attr_reader :sent

    def initialize(clock, failing: nil)
      @clock = clock
      @failing = failing
      @sent = []
    end

    def notify(view)
      @sent << [view, @clock.now]
      raise @failing if @failing
    end
  end

  # Plays the chat's registration: answers daemon.info with the relay's state,
  # records every request, and hands a push to its subscriber when told.
  class StandIn
    attr_reader :calls
    attr_accessor :relay, :refuse

    # @param relay [String] the relay state daemon.info answers
    # @param refuse [String, nil] the refusal every agenda.publish gets
    # @param dying [Hash{String=>Integer}] how many times each method raises Died before it answers
    # @param holding [Boolean] whether the first publish that adds an item is taken, and then
    #   answered only once the example calls {#release}
    def initialize(relay: "running", refuse: nil, dying: {}, holding: false)
      @relay = relay
      @refuse = refuse
      @dying = dying.dup
      @holding = holding
      @taken = Lain::Promise.new
      @released = Lain::Promise.new
      @calls = []
      @handlers = {}
    end

    def on(method, &handler) = (@handlers[method] = handler) && self

    def call(method, *params)
      @calls << [method, params]
      die(method)
      return { "relay" => @relay } if method == "daemon.info"
      raise Lain::Core::Client::Refused, @refuse if @refuse

      hold(params.first)
      @calls.size
    end

    # Parks until the held publish has been taken.
    def taken = @taken.await

    def release = @released.resolve(true)

    def hold(delta)
      return unless @holding && delta.fetch("added").any?

      @holding = false
      @taken.resolve(true)
      @released.await
    end

    def die(method)
      return unless @dying.fetch(method, 0).positive?

      @dying[method] -= 1
      raise Lain::Core::Died, "the daemon went away"
    end

    def settled_ids
      @calls.select { _1.first == "agenda.publish" }
            .flat_map { |_, (delta, _keys)| Lain::Remote::Wire::Delta.from_wire(delta).settled }
    end

    def wired_items
      @calls.select { _1.first == "agenda.publish" }.flat_map { |_, (delta, _keys)| delta.fetch("added") }
    end

    def deliver(method, params = []) = @handlers.fetch(method).call(params)

    def die_next(method) = @dying[method] = 1

    def methods_called = @calls.map(&:first).uniq

    # Each agenda.publish that added an item, as the Delta and the gate keys it sent.
    def published
      @calls.select { _1.first == "agenda.publish" }
            .map { |_, (delta, keys)| [Lain::Remote::Wire::Delta.from_wire(delta), keys] }
            .reject { |delta, _| delta.added.empty? }
    end

    def added_ids = published.flat_map { |delta, _| delta.added.map(&:id) }
  end

  # A lain-daemon running the phone relay on a loopback port with 1 paired
  # device, and this process registered with it as 1 chat.
  class Desk
    SESSION = "20261117T100000-spec"

    attr_reader :port, :token, :launch

    def initialize(dir, launch:, paths:, env:, devices: Lain::Remote::Devices.new(File.join(dir, "devices", "devices")))
      @token = devices.pair("pixel")
      @port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
      @launch = launch.with(flags: ["--relay", "127.0.0.1:#{@port}", "--devices-file", devices.path])
      @paths = paths
      @env = env
      @root = dir
    end

    def registration(launch: @launch)
      writer = Lain::Liveness::Writer.current
      record = Lain::LiveSessions::Record.new(session_id: SESSION, pid: writer.pid, start: writer.start,
                                              host: writer.host, root: @root, cwd: @root, input_socket: nil,
                                              journal: nil, attended: true, started_at: "2026-11-17T10:00:00Z")
      Lain::Daemon::Registration.new(record:, notes: StringIO.new, daemon: lambda { |pushes:, replace:|
        Lain::Daemon.ensure(paths: @paths, env: @env, launch:, pushes:, replace:)
      })
    end

    def pid = LainDaemon.pid_at(@paths)

    # A daemon other than `old` answers, with its relay listening.
    def restarted?(old)
      pid.then { _1 && _1 != old } && info.fetch("relay") == "running"
    rescue Lain::Core::Died, Lain::Core::Client::Stopped
      false
    end

    def info
      client = Lain::Core::Client.start(transport: Lain::Core::Transport::Unix.new(Lain::Daemon.socket(paths: @paths)))
      client.call("daemon.info").tap { client.stop }
    end

    # The relay worker is the daemon's only child.
    def worker_pid
      Dir[File.join("/proc", pid.to_s, "task", "*", "children")].flat_map { File.read(_1).split }.map(&:to_i).sole
    end
  end

  # 1 chat in a process of its own, as a sibling of every other: it registers
  # with the daemon, runs a RemoteSurface over 1 deferred gate wave read from
  # ROWS, appends each answer the wave gets to OUT, prints "published <ids>"
  # each time the daemon takes a publish that adds items, and stops at EOF.
  SIBLING_CHAT = <<~RUBY
    require "json"
    require "stringio"
    require "lain"

    session, root, out, rows, flags = ARGV
    paths = Lain::Paths.new
    launch = Lain::Daemon::Launch.current(paths:).with(flags: JSON.parse(flags))
    gates = Class.new do
      define_method(:each) do |&block|
        JSON.parse(File.read(rows)).map do |issue, digest, at|
          Lain::Remote::Agenda::Gates::Row.new(digest:, epic: "e", stage: "impl", issue:, question: "ship it?",
                                                asked_at: Time.at(at))
        end.each(&block)
      end
      define_method(:approve) { |digest, **| File.write(out, "\#{session} approve \#{digest}\n", mode: "a") }
      define_method(:deny) { |digest, **| File.write(out, "\#{session} deny \#{digest}\n", mode: "a") }
    end.new
    told = Class.new(SimpleDelegator) do
      def call(method, *params)
        super.tap do |answer|
          added = method == "agenda.publish" ? params.first.fetch("added") : []
          if answer && added.any?
            $stdout.puts("published \#{added.map { _1.values.first.fetch("id") }.join(",")}")
            $stdout.flush
          end
        end
      end
    end
    queue = Lain::Approval::Parked::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 60)
    agenda = Lain::Remote::Agenda.new(queue:, gates:, replies: Class.new { def waiting = [] }.new)
    writer = Lain::Liveness::Writer.current
    record = Lain::LiveSessions::Record.new(session_id: session, pid: writer.pid, start: writer.start,
                                            host: writer.host, root:, cwd: root, input_socket: nil, journal: nil,
                                            attended: true, started_at: "2026-11-17T10:00:00Z")
    Sync do |task|
      registration = Lain::Daemon::Registration.new(record:, notes: $stderr, daemon: lambda { |pushes:, replace:|
        Lain::Daemon.ensure(paths:, launch:, pushes:, replace:)
      }).open(task)
      surface = Lain::Approval::RemoteSurface.new(registration: told.new(registration), agenda:, secrets: [],
                                                  journal: Lain::Journal.new(io: StringIO.new), project: root,
                                                  trace: Lain::Daemon::Launch.trace_path(paths:), poll_interval: 0.02)
      watching = task.async { surface.watch }
      $stdin.read
      watching.stop
    ensure
      registration&.close
    end
  RUBY

  # Each sibling chat is stopped by its pid however the example ends.
  class SiblingChat
    STOP_BUDGET = 10

    def initialize(env, session, root:, out:, rows:, flags:)
      @err = File.join(root, "#{session}.err")
      @io = IO.popen(env, [RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", SIBLING_CHAT,
                           session, root, out, rows, JSON.generate(flags)], "r+", err: @err)
    end

    # Reads what the chat prints until a publish adds `id`.
    def published(id)
      seen = @io.each_line.find { |line| line.chomp.split(" ", 2).last.to_s.split(",").include?(id) }
      raise "the chat ended before it published #{id}: #{File.read(@err)}" unless seen
    end

    def stop
      @io.close_write
      Timeout.timeout(STOP_BUDGET) { @io.read }
    rescue Timeout::Error
      Process.kill("KILL", @io.pid)
    ensure
      @io.close
    end
  end

  # The phone's side of the relay, over TCP with the paired token, speaking the
  # wire through the same Core::Client the surface uses.
  class Phone
    CONNECT_BUDGET = 5.0

    def initialize(desk)
      socket = connected(desk.port)
      @client = Lain::Core::Client.new(transport: Lain::Core::Transport::Mock.new(socket:), socket:)
      hello = Lain::Remote::Wire::Hello.new(wire_version: Lain::Remote::Wire::VERSION, token: desk.token, cursor: 0)
      @head = Lain::Remote::Wire::Welcome.from_wire(@client.call("hello", [hello.to_wire])).head
      @cursor = 0
      @epoch = nil
      @open = {}
    end

    # The relay's delta count when this phone said hello: 0 when nothing was ever published.
    attr_reader :head

    # Reads deltas until `want` holds over the open items, and returns them.
    def until_open(&want)
      advance until yield(@open.values)
      @open.values
    end

    def answer(answer) = @client.call("answer.send", [answer.to_wire])

    def stop = @client.stop

    private

    # The worker binds its port after the daemon answers, so the first connect may come early.
    def connected(port)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + CONNECT_BUDGET
      begin
        TCPSocket.new("127.0.0.1", port)
      rescue Errno::ECONNREFUSED
        raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
        retry
      end
    end

    def advance
      page = Lain::Remote::Wire::AgendaPage.from_wire(
        @client.call("agenda.next", [Lain::Remote::Wire::Cursor.new(cursor: @cursor, epoch: @epoch).to_wire])
      )
      @open.clear if page.reset
      page.deltas.each { |delta| apply(delta) }
      @cursor = page.cursor
      @epoch = page.epoch
    end

    def apply(delta)
      delta.added.each { @open[_1.id] = _1 }
      delta.settled.each { @open.delete(_1) }
    end
  end
end

RSpec.describe Lain::Approval::RemoteSurface do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal:, timeout: 10) }
  let(:agenda) do
    Lain::Remote::Agenda.new(queue:, gates: RemoteSurfaceSpecSupport::NoGates.new,
                             replies: RemoteSurfaceSpecSupport::NoReplies.new)
  end
  let(:runs) { [] }
  let(:toolset) { Lain::Toolset.new([gated_tool]) }
  let(:gate) { Lain::Middleware::Gate.new(policy: asking_ladder(queue, tools: toolset, journal:)) }
  let(:wire) { Lain::Remote::Wire }

  around do |example|
    Dir.mktmpdir("remote") do |dir|
      @dir = dir
      example.run
    end
  end

  def gated_tool
    ran = runs
    Class.new(Lain::Tool) do
      def name = "bash"
      def description = "a gated stand-in for bash"
      def requires_approval? = true
      def input_schema = { type: :object, properties: { command: { type: :string } }, required: [] }
      define_method(:perform) do |input, _invocation|
        ran << input
        Lain::Tool::Result.ok("ran #{input["command"]}")
      end
    end.new
  end

  def trace = File.join(@dir, "daemon.trace")

  def surface(registration, secrets: [], agenda: self.agenda, journal: self.journal, project: @dir, **options)
    described_class.new(registration:, agenda:, secrets:, journal:, poll_interval: 0.02, project:, trace:, **options)
  end

  def agenda_over(gates: RemoteSurfaceSpecSupport::NoGates.new, queue: self.queue, **options)
    Lain::Remote::Agenda.new(queue:, gates:, replies: RemoteSurfaceSpecSupport::NoReplies.new, **options)
  end

  def park(task, command = "ls -la")
    task.async { dispatch_call("bash", { "command" => command }, toolset:, layers: [gate]) }
  end

  def records(type) = journal_records(journal_io, type)

  def approve(item) = wire::Answer::Call.new(id: item.id, verdict: Lain::Approval::Verdict::Approve.new, device: nil)

  describe "over its registration" do
    let(:registration) { RemoteSurfaceSpecSupport::StandIn.new }

    # Watching until `want` holds of the registration, with the call parked first when asked.
    def watched(stand_in = registration, parked: true, **options, &want)
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(stand_in, **options).watch }
          call = park(task) if parked
          wait_until(reason: "the surface published") { yield(stand_in) }
        ensure
          call&.stop
          watching&.stop
        end
      end
    end

    it "publishes a parked call as an agenda.publish request, and never polls for answers" do
      watched { _1.added_ids.any? }

      expect(registration.methods_called).to contain_exactly("daemon.info", "agenda.publish")
      expect(registration.published.first.first.added.sole).to have_attributes(tool: "bash", id: "1")
    end

    it "takes an answer the daemon pushes, as the paired device, with human authority" do
      outcome = Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration).watch }
          call = park(task)
          wait_until(reason: "the call was published") { registration.added_ids.any? }
          registration.deliver("answer", [wire::Answer::Call.new(id: "1", verdict: Lain::Approval::Verdict::Approve.new,
                                                                 device: "pixel").to_wire])
          call.wait
        ensure
          watching&.stop
        end
      end

      expect([outcome, runs]).to eq([Lain::Tool::Result.ok("ran ls -la"), [{ "command" => "ls -la" }]])
      expect(records("approval_decision").last).to include("surface" => "remote:pixel")
    end

    it "republishes every open item from cursor 0 when the registration reconnects, and does not degrade" do
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration).watch }
          call = park(task)
          wait_until(reason: "the call was published") { registration.added_ids.any? }
          registration.deliver(Lain::Daemon::Registration::RECONNECTED)
          wait_until(reason: "the call was published again") { registration.added_ids.size == 2 }
        ensure
          call&.stop
          watching&.stop
        end
      end

      expect(registration.added_ids).to eq(%w[1 1])
      expect(records("capability_degraded")).to be_empty
    end

    it "shares a gate under a key of its own, and a parked call under none" do
      gated = agenda_over(gates: RemoteSurfaceSpecSupport::StageGate.new)
      watched(agenda: gated) { |stand_in| stand_in.added_ids.size == 2 }

      keyed = registration.published.to_h { |delta, keys| [delta.added.sole.class, keys] }
      expect(keyed.fetch(wire::Item::GateQuestion)).to match("1" => a_string_matching(/\A\h{64}\z/))
      expect(keyed.fetch(wire::Item::ParkedCall)).to eq({})
    end

    def gate_key(gates, secrets: [], project: @dir)
      stand_in = RemoteSurfaceSpecSupport::StandIn.new
      watched(stand_in, parked: false, agenda: agenda_over(gates:), secrets:, project:) { |chat| chat.added_ids.any? }
      stand_in.published.sole.last.values.sole
    end

    it "keys the same gate the same way for 2 chats in 1 project" do
      keys = Array.new(2) { gate_key(RemoteSurfaceSpecSupport::StageGate.new) }

      expect(keys.uniq.size).to eq(1)
    end

    # The relay's keys span every project, and a project root is where authority ends.
    it "keys the same wave differently in 2 projects" do
      keys = [@dir, File.join(@dir, "other")].map { gate_key(RemoteSurfaceSpecSupport::StageGate.new, project: _1) }

      expect(keys.uniq.size).to eq(2)
    end

    it "keys the same gate the same way for 2 chats that know different secret values" do
      secret = "hunter2-correct-horse-battery"
      keys = [[secret], []].map { gate_key(RemoteSurfaceSpecSupport::Wave.new(epic: "ship-#{secret}"), secrets: _1) }

      expect(keys.uniq.size).to eq(1)
    end

    it "keys a re-asked wave anew, even when only 1 of its rows was asked again" do
      wave = RemoteSurfaceSpecSupport::Wave.new
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration, agenda: agenda_over(gates: wave)).watch }
          wait_until(reason: "the wave was published") { registration.added_ids.any? }
          wave.reask!
          wait_until(reason: "the re-asked wave was published") { registration.added_ids.size == 2 }
        ensure
          watching&.stop
        end
      end

      keys = registration.published.map { |_, keyed| keyed.values.sole }
      expect(keys.uniq.size).to eq(2)
      expect(registration.settled_ids).to include("1")
    end

    it "sends the phone no artifact digest" do
      wave = agenda_over(gates: RemoteSurfaceSpecSupport::Wave.new)
      watched(parked: false, agenda: wave, project: File.join(@dir, "d1-d2")) { _1.added_ids.any? }

      fields = registration.wired_items.flat_map(&:values).flat_map(&:to_a)
      expect(fields.map(&:first)).not_to include("digests")
      expect(fields.map(&:last).flatten).not_to include("d1", "d2")
    end

    it "hides a path under home in the refusal it shows the phone" do
      document = File.join(Dir.home, "dev", "nyotes", "epics", "e", "plan.md")
      gated = agenda_over(gates: RemoteSurfaceSpecSupport::RaisingGates.new("no epic document at #{document}"))
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration, agenda: gated).watch }
          wait_until(reason: "the gate was published") { registration.added_ids.any? }
          registration.deliver("answer", [approve(registration.published.first.first.added.sole).to_wire])
          wait_until(reason: "the refusal was published") { registration.added_ids.size == 2 }
        ensure
          watching&.stop
        end
      end

      shown = registration.published.last.first.added.sole.question
      expect(shown).to include("no epic document at", described_class::PATH_MASK)
      expect(shown).not_to include(Dir.home)
    end

    it "keeps watching when the daemon drops while it asks after a reconnect, and publishes again once it answers" do
      dropping = RemoteSurfaceSpecSupport::StandIn.new
      running = Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(dropping).watch }
          call = park(task)
          wait_until(reason: "the call was published") { dropping.added_ids.any? }
          dropping.die_next("daemon.info")
          dropping.deliver(Lain::Daemon::Registration::RECONNECTED)
          wait_until(reason: "the call was published again") { dropping.added_ids.size == 2 }
          watching.running?
        ensure
          call&.stop
          watching&.stop
        end
      end

      expect(running).to be(true)
      expect(records("capability_degraded")).to be_empty
    end

    it "publishes again on the next sweep when the daemon drops under a publish, and records no fault" do
      dropping = RemoteSurfaceSpecSupport::StandIn.new(dying: { "agenda.publish" => 1 })
      watched(dropping) { _1.added_ids.any? }

      expect(records("approval_surface_fault")).to be_empty
      expect(records("capability_degraded")).to be_empty
    end

    it "takes back what it published when it stops" do
      watched { _1.added_ids.any? }

      expect(registration.settled_ids).to eq(["1"])
    end

    it "takes back an item the daemon took, when it stops before the daemon's reply comes back" do
      holding = RemoteSurfaceSpecSupport::StandIn.new(holding: true)
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(holding).watch }
          call = park(task)
          holding.taken
          watching.stop
        ensure
          holding.release
          call&.stop
          watching&.stop
        end
      end

      expect(holding.settled_ids).to eq(["1"])
    end

    it "takes back nothing the daemon refused" do
      refusing = RemoteSurfaceSpecSupport::StandIn.new(refuse: "ParkedCall 900000 bytes, over the relay's reply budget")
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(refusing).watch }
          call = park(task)
          wait_until(reason: "the refusal was recorded") { records("approval_surface_fault").any? }
          watching.stop
        ensure
          call&.stop
          watching&.stop
        end
      end

      expect(refusing.settled_ids).to be_empty
    end

    it "still takes back an item the daemon took, when only its republish after a refused answer is refused" do
      gated = agenda_over(gates: RemoteSurfaceSpecSupport::RaisingGates.new)
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration, agenda: gated).watch }
          wait_until(reason: "the gate was published") { registration.added_ids.any? }
          registration.refuse = "GateQuestion 900000 bytes, over the relay's reply budget"
          registration.deliver("answer", [approve(registration.published.first.first.added.sole).to_wire])
          wait_until(reason: "the republish was refused") { registration.added_ids.size == 2 }
          watching.stop
        ensure
          watching&.stop
        end
      end

      expect(registration.settled_ids).to eq(["1"])
    end

    it "offers a refused item again after a reconnect, and takes it back once, after the daemon took it" do
      refusing = RemoteSurfaceSpecSupport::StandIn.new(refuse: "ParkedCall 900000 bytes, over the relay's reply budget")
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(refusing).watch }
          call = park(task)
          wait_until(reason: "the refusal was recorded") { records("approval_surface_fault").any? }
          refusing.refuse = nil
          refusing.deliver(Lain::Daemon::Registration::RECONNECTED)
          wait_until(reason: "the call was offered again") { refusing.added_ids.size == 2 }
        ensure
          call&.stop
          watching&.stop
        end
      end

      expect(refusing.settled_ids).to eq(["1"])
      expect(records("approval_surface_fault").size).to eq(1)
    end

    it "takes nothing back once the relay is gone" do
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(registration).watch }
          calls = [park(task)]
          wait_until(reason: "the call was published") { registration.added_ids.any? }
          registration.relay = "unavailable"
          registration.refuse = "the phone relay is unavailable"
          calls << park(task, "after the relay died")
          watching.wait
        ensure
          calls&.each(&:stop)
        end
      end

      expect(records("capability_degraded").size).to eq(1)
      expect(registration.settled_ids).to be_empty
    end

    it "leaves the session for the daemon to stamp and names its project on each item" do
      watched { _1.added_ids.any? }

      expect(registration.published.first.first.added.sole).to have_attributes(session: "", project: @dir)
    end

    it "records a publish the daemon refuses, and keeps serving" do
      refusing = RemoteSurfaceSpecSupport::StandIn.new(refuse: "ParkedCall 900000 bytes, over the relay's reply budget")
      Sync do |task|
        task.with_timeout(10) do
          watching = task.async { surface(refusing).watch }
          call = park(task)
          wait_until(reason: "the refusal was recorded") { records("approval_surface_fault").any? }
          [watching.running?, call]
        ensure
          call&.stop
          watching&.stop
        end
      end

      expect(records("approval_surface_fault").map { _1["error"] })
        .to contain_exactly(a_string_including("Refused", "reply budget"))
      expect(records("capability_degraded")).to be_empty
    end

    {
      "the daemon runs no relay" => "off",
      "the daemon's relay is unavailable" => "unavailable"
    }.each do |what, state|
      it "degrades once when #{what}" do
        Sync { |task| task.with_timeout(5) { surface(RemoteSurfaceSpecSupport::StandIn.new(relay: state)).watch } }

        expect(records("capability_degraded"))
          .to contain_exactly(a_hash_including("capability" => "remote_surface", "requirer" => described_class.name,
                                               "provider" => a_string_including(state, "#{trace} says why")))
      end
    end

    it "degrades cleanly over a registration with no daemon, and the desk keeps the call" do
      outcome = Sync do |task|
        task.with_timeout(5) do
          surface(Lain::Daemon::Registration::Null.new).watch
          call = park(task)
          wait_until(reason: "the call parked") { queue.any? }
          queue.first.approve(surface: "desk", authority: :human)
          call.wait
        end
      end

      expect(outcome).to eq(Lain::Tool::Result.ok("ran ls -la"))
      expect(records("capability_degraded").map { _1["capability"] }).to eq(["remote_surface"])
    end
  end

  # An owner's error can name any file on this box; the phone is not on it.
  describe ".unpathed" do
    {
      "a path on another mount" => "no epic document at /mnt/nvme/work/repo/epics/plan.md",
      "a path under /tmp" => "cannot read /tmp/lain/sessions/abc/2026-11-04.ndjson: torn line",
      "a path under /etc" => "refused by /etc/lain/policy.rb, line 3",
      "a ~/ spelling" => "move it to ~/dev/nyotes/epics first"
    }.each do |what, message|
      it "masks #{what}" do
        masked = described_class.unpathed(message)

        expect(masked).to include(described_class::PATH_MASK)
        expect(masked).not_to match(%r{\w/\w})
      end
    end

    it "keeps a bare slash and words with slashes in them" do
      text = "approve and/or deny / hold, one of approve/hold/deny"

      expect(described_class.unpathed(text)).to eq(text)
    end
  end

  describe ".for" do
    def built(relay, ntfy = nil)
      described_class.for(relay:, ntfy:, paths: Lain::Paths.new(env: { "HOME" => @dir }), root: @dir, queue:,
                          registration: Lain::Daemon::Registration::Null.new,
                          replies: RemoteSurfaceSpecSupport::NoReplies.new, secrets: [], journal:)
    end

    it "builds a surface that announces on the ntfy topic when remote ntfy is set, and one that does not when unset" do
      announcers = [built("127.0.0.1:7820", "http://127.0.0.1:1/t"), built("127.0.0.1:7820")]
                   .map(&:ntfy)

      expect(announcers).to match([an_instance_of(Lain::Remote::Ntfy), Lain::Remote::Ntfy::Null::INSTANCE])
    end

    it "builds the surface when remote relay is set, and none when it is not" do
      expect([built("127.0.0.1:7820"), built(nil)]).to match([an_instance_of(described_class), nil])
    end

    it "names the trace the daemon writes when its relay is unavailable" do
      paths = Lain::Paths.new(env: { "HOME" => @dir })
      built = described_class.for(relay: "127.0.0.1:7820", ntfy: nil, paths:, root: @dir, queue:,
                                  registration: RemoteSurfaceSpecSupport::StandIn.new(relay: "unavailable"),
                                  replies: RemoteSurfaceSpecSupport::NoReplies.new, secrets: [], journal:)
      Sync { |task| task.with_timeout(5) { built.watch } }

      expect(records("capability_degraded").sole["provider"])
        .to eq("the daemon's phone relay is unavailable; #{Lain::Daemon::Launch.current(paths:).trace} says why")
    end
  end

  it "keeps no socket of its own" do
    expect(described_class).not_to respond_to(:socket)
  end

  describe "through the built daemon's relay", :daemon do
    let(:desk) { RemoteSurfaceSpecSupport::Desk.new(@dir, launch: daemon_launch, paths: daemon_paths, env: daemon_env) }

    # Registered, watching, a phone connected, and one call parked: the block
    # gets the phone, the call's task and the call as the phone sees it.
    def with_a_parked_call(secrets: [], command: "ls -la", agenda: self.agenda)
      Sync do |task|
        task.with_timeout(20) do
          registration = desk.registration.open(task)
          watching = task.async { surface(registration, secrets:, agenda:).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(desk)
          call = park(task, command)
          item = phone.until_open(&:any?).first
          yield phone, call, item
        ensure
          phone&.stop
          watching&.stop
          registration&.close
        end
      end
    end

    # Registered, watching and a phone connected; the block gets the phone and the watch.
    def with_a_phone(agenda: self.agenda)
      Sync do |task|
        task.with_timeout(20) do
          registration = desk.registration.open(task)
          watching = task.async { surface(registration, agenda:).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(desk)
          yield phone, watching, task
        ensure
          phone&.stop
          watching&.stop
          registration&.close
        end
      end
    end

    context "when built by .for over a launch the user's config set" do
      def write_user_config(body)
        FileUtils.mkdir_p(File.dirname(daemon_paths.user_config))
        File.write(daemon_paths.user_config, body)
        Lain::Project::Trust.for_user(paths: daemon_paths).grant!
      end

      after { FileUtils.rm_f([daemon_paths.user_config, Lain::Remote::Devices.for(paths: daemon_paths).path]) }

      it "shows the phone the item under the registration's session and root" do
        port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
        write_user_config("remote relay: \"127.0.0.1:#{port}\"\n")
        launch = Lain::Daemon::Launch.current(paths: daemon_paths, env: daemon_env)
        token = Lain::Remote::Devices.for(paths: daemon_paths).pair("pixel")
        built = lambda do |registration|
          described_class.for(**Lain::Config.remote(paths: daemon_paths), paths: daemon_paths, root: Pathname(@dir),
                                                                          registration:, queue:, secrets: [], journal:,
                                                                          replies: RemoteSurfaceSpecSupport::NoReplies.new)
        end
        item = Sync do |task|
          task.with_timeout(20) do
            registration = desk.registration(launch:).open(task)
            watching = task.async { built.call(registration).watch }
            phone = RemoteSurfaceSpecSupport::Phone.new(Struct.new(:port, :token).new(port, token))
            call = park(task)
            phone.until_open(&:any?).first
          ensure
            call&.stop
            phone&.stop
            watching&.stop
            registration&.close
          end
        end

        expect([item.session, item.project]).to eq([RemoteSurfaceSpecSupport::Desk::SESSION, @dir])
      end
    end

    it "sends the phone the parked call, and its Approve runs it as the paired device, with human authority" do
      result = with_a_parked_call do |phone, call, item|
        expect(item).to have_attributes(tool: "bash", requester: "agent", postponed: false)
        expect(JSON.parse(item.input)).to eq("command" => "ls -la")
        phone.answer(approve(item))
        call.wait
      end

      expect([result, runs]).to eq([Lain::Tool::Result.ok("ran ls -la"), [{ "command" => "ls -la" }]])
      expect(records("approval_decision").last).to include("surface" => "remote:pixel")
      expect(records("escalation").last)
        .to include("verdict" => "allow", "authority" => "human", "reason" => a_string_including("(remote:pixel)"))
    end

    it "masks a known secret in the call before it leaves the box" do
      secret = "hunter2-correct-horse-battery"

      with_a_parked_call(secrets: [secret], command: "deploy --password #{secret}") do |phone, call, item|
        expect(item.input).not_to include(secret)
        phone.answer(wire::Answer::Call.new(id: item.id, verdict: Lain::Approval::Verdict::Deny.new, device: nil))
        call.wait
      end
    end

    it "settles a call the desk answered first, and the phone's late answer is told it is already settled" do
      refusal = with_a_parked_call do |phone, call, item|
        queue.first.approve(surface: "desk", authority: :human)
        call.wait
        phone.until_open { |open| open.none? { _1.id == item.id } }
        phone.answer(approve(item))
      rescue Lain::Core::Client::Refused => e
        e.message
      end

      expect(refusal).to include("already settled")
      expect(records("approval_decision").map { _1["surface"] }).to eq(["desk"])
    end

    it "writes a line naming the item and the device when the phone's answer loses to the desk" do
      with_a_parked_call(agenda: RemoteSurfaceSpecSupport::DeskFirst.new(agenda, queue)) do |phone, call, item|
        phone.answer(approve(item))
        call.wait
        wait_until(reason: "the lost answer was recorded") { records(described_class::LOST_TYPE).any? }
      end

      expect(records(described_class::LOST_TYPE)).to contain_exactly(a_hash_including("id" => "1", "device" => "pixel"))
      expect(records("approval_decision").map { _1["surface"] }).to eq(["desk"])
    end

    it "shows the phone why a wrong-typed answer was refused, and keeps the item open for another" do
      shown = with_a_parked_call do |phone, call, item|
        phone.answer(wire::Answer::Question.new(id: item.id, option: nil, text: "yes please", device: nil))
        again = phone.until_open { |open| open.any? { _1.why.include?("not a verdict") } }
        phone.answer(approve(again.first))
        call.wait
        again.first.why
      end

      expect(shown).to include("not a verdict")
      expect(runs).to eq([{ "command" => "ls -la" }])
    end

    it "records a call the relay refuses as too large, and keeps serving the phone" do
      shown = with_a_phone do |phone, watching, task|
        large = park(task, "x" * (800 << 10))
        wait_until(reason: "the refusal was recorded") { records("approval_surface_fault").any? }
        small = park(task)
        phone.answer(approve(phone.until_open(&:any?).sole))
        large.stop
        [small.wait, watching.running?]
      end

      expect(shown).to eq([Lain::Tool::Result.ok("ran ls -la"), true])
      expect(records("approval_surface_fault").map { _1["error"] }).to contain_exactly(a_string_including("budget"))
    end

    it "records a gate owner's refusal, shows it to the phone, and keeps serving" do
      raising = agenda_over(gates: RemoteSurfaceSpecSupport::RaisingGates.new)
      shown = with_a_phone(agenda: raising) do |phone, watching, task|
        phone.answer(approve(phone.until_open(&:any?).first))
        phone.until_open { |open| open.any? { _1.question.include?("no epic document") } }
        call = park(task)
        parked = phone.until_open { |open| open.any? { _1.respond_to?(:tool) } }.find { _1.respond_to?(:tool) }
        phone.answer(approve(parked))
        [call.wait, watching.running?]
      end

      expect(shown).to eq([Lain::Tool::Result.ok("ran ls -la"), true])
      expect(records("approval_surface_fault").map { _1["error"] })
        .to contain_exactly(a_string_including("MissingEpicDocument", "no epic document for e"))
    end

    it "hands a question's answer on with the device that gave it" do
      asked = RemoteSurfaceSpecSupport::OneQuestion.new
      with_a_phone(agenda: Lain::Remote::Agenda.new(queue:, gates: RemoteSurfaceSpecSupport::NoGates.new,
                                                    replies: asked)) do |phone, _watching, _task|
        item = phone.until_open(&:any?).first
        phone.answer(wire::Answer::Question.new(id: item.id, option: nil, text: "main", device: nil))
        wait_until(reason: "the answer was handed on") { asked.answers.any? }
      end

      expect(asked.answers).to eq([["main", "blake3:q1", "remote:pixel"]])
    end

    it "sends the phone an unreadable gate journal without its path, before and after an answer" do
      texts = with_a_phone(agenda: agenda_over(gates: RemoteSurfaceSpecSupport::UnreadableGates.new)) do |phone, _, _|
        first = phone.until_open(&:any?).first
        phone.answer(approve(first))
        again = phone.until_open { |open| open.any? { _1.question != first.question } }.first
        [first, again].map { _1.to_h.except(:session, :project).values.join(" ") }
      end

      expect(texts).to all(include("gate journal").and(include("desk")))
      expect(texts.join).not_to include(".ndjson", "/home/")
    end

    it "takes back what it published when it stops, so the phone stops showing it" do
      left = with_a_phone do |phone, watching, task|
        call = park(task)
        phone.until_open(&:any?)
        watching.stop
        phone.until_open(&:empty?).tap { call.stop }
      end

      expect(left).to be_empty
    end

    it "records a secrets source that raises once, and publishes nothing unmasked" do
      failing = Class.new { def to_a = raise(IOError, "the history walk failed") }.new
      seen = Sync do |task|
        task.with_timeout(20) do
          registration = desk.registration.open(task)
          watching = task.async { surface(registration, secrets: failing).watch }
          call = park(task)
          wait_until(reason: "a sweep failed") { records("approval_surface_fault").any? }
          task.sleep(0.1)
          phone = RemoteSurfaceSpecSupport::Phone.new(desk)
          [call, watching].each(&:stop)
          phone.stop
          phone.head
        ensure
          registration&.close
        end
      end

      expect(seen).to eq(0)
      expect(records("approval_surface_fault").map { _1["error"] }).to eq(["IOError: the history walk failed"])
    end

    it "shows the phone every open item again after the daemon restarts, and does not degrade" do
      result = with_a_parked_call do |_phone, call, _item|
        old = desk.pid
        Process.kill("KILL", old)
        wait_until(reason: "a new daemon runs the relay") { desk.restarted?(old) }
        again = RemoteSurfaceSpecSupport::Phone.new(desk)
        again.answer(approve(again.until_open(&:any?).sole))
        call.wait.tap { again.stop }
      end

      expect(result).to eq(Lain::Tool::Result.ok("ran ls -la"))
      expect(records("capability_degraded")).to be_empty
    end

    # Both chats hold the wave, so neither chat's re-ask alone takes it off the
    # phone; only a new key does.
    # The chats re-ask 1 at a time, so the wave the phone was shown is still held by one of them when
    # the other re-asks: under a key that survives a re-ask, its id would still be live at the answer.
    it "refuses a phone answer to a wave re-asked under it by 2 sibling chats, and shows the new wave anew" do
      out = File.join(@dir, "answers")
      rows = %w[chat-a chat-b].to_h { [_1, File.join(@dir, "#{_1}.rows.json")] }
      rows.each_value { File.write(_1, JSON.generate([["a", "d1", 100], ["b", "d2", 200]])) }
      chats = rows.map do |session, file|
        RemoteSurfaceSpecSupport::SiblingChat.new(daemon_env, session, root: @dir, out:, rows: file,
                                                                       flags: desk.launch.flags)
      end
      refusal, old, renewed = Sync do |task|
        task.with_timeout(20) do
          chats.each { _1.published("1") }
          phone = RemoteSurfaceSpecSupport::Phone.new(desk)
          shown = phone.until_open(&:any?).sole
          rows.values.zip(chats).each do |file, chat|
            File.write(file, JSON.generate([["a", "d1", 100], ["b", "d2-reasked", 900]]))
            chat.published("2")
          end
          verdicts = %w[a b].map { [_1, Lain::Approval::Verdict::Approve.new] }
          refused = begin
            phone.answer(wire::Answer::Gate.new(id: shown.id, verdicts:, device: nil)) && nil
          rescue Lain::Core::Client::Refused => e
            e.message
          end
          fresh = RemoteSurfaceSpecSupport::Phone.new(desk)
          [refused, shown, fresh.until_open(&:any?).sole]
        ensure
          [phone, fresh].compact.each(&:stop)
        end
      ensure
        chats.each(&:stop)
      end

      expect(refusal).to include("already settled")
      expect(File.exist?(out) ? File.read(out) : "").not_to include("d2-reasked")
      expect(renewed).to have_attributes(issues: %w[a b])
      expect(renewed.id).not_to eq(old.id)
    end

    it "degrades once the relay worker dies under it, and the desk keeps the call" do
      outcome = with_a_phone do |phone, watching, task|
        first = park(task)
        phone.until_open(&:any?)
        Process.kill("KILL", desk.worker_pid)
        wait_until(reason: "the daemon saw its relay die") { desk.info.fetch("relay") == "unavailable" }
        second = park(task, "after the relay died")
        watching.wait
        queue.to_a.each { _1.approve(surface: "desk", authority: :human) }
        [first, second].map(&:wait)
      end

      expect(outcome).to all(be_ok)
      expect(records("capability_degraded").map { _1["capability"] }).to eq(["remote_surface"])
    end
  end

  describe "announcing a waiting item through ntfy" do
    let(:registration) { RemoteSurfaceSpecSupport::StandIn.new }
    let(:asked) { Time.at(1_000) }
    let(:clock) { RemoteSurfaceSpecSupport::Clock.new(asked) }
    let(:ntfy) { RemoteSurfaceSpecSupport::Ntfy.new(clock) }
    let(:timed) { agenda_over(wall: -> { asked }) }

    def watching(task, ntfy: self.ntfy, **options)
      task.async { surface(registration, agenda: timed, ntfy:, clock:, buzz_after: 60, **options).watch }
    end

    def published(count) = wait_until(reason: "#{count} items were published") { registration.added_ids.size >= count }

    # A call left parked holds the Sync block open until the queue's 10 s timeout.
    def settle_parked = queue.to_a.each { _1.approve(surface: "desk", authority: :human) }

    def announcing(**options)
      Sync do |task|
        task.with_timeout(10) do
          watch = watching(task, **options)
          yield task
        ensure
          settle_parked
          watch&.stop
        end
      end
    end

    it "announces a call once it has waited the delay, not before" do
      announcing do |task|
        park(task)
        published(1)
        clock.now = asked + 59
        task.sleep(0.1)
        expect(ntfy.sent).to be_empty
        clock.now = asked + 60
        wait_until(reason: "the call was announced") { ntfy.sent.any? }
      end

      expect(ntfy.sent.map { |view, at| [view.id, view.requester, at] }).to eq([["1", "agent", asked + 60]])
    end

    it "does not announce a call the desk answered first" do
      announcing do |task|
        first = park(task)
        published(1)
        clock.now = asked + 30
        queue.first.approve(surface: "desk", authority: :human)
        first.wait
        clock.now = asked + 61
        park(task, "second")
        wait_until(reason: "the second call was announced") { ntfy.sent.any? }
      end

      expect(ntfy.sent.map { _1.first.input }).to eq([{ "command" => "second" }])
    end

    it "announces the masked view, and announces each item once" do
      secret = "hunter2-correct-horse-battery"
      announcing(secrets: [secret]) do |task|
        park(task, "deploy --password #{secret}")
        published(1)
        clock.now = asked + 600
        wait_until(reason: "the call was announced") { ntfy.sent.any? }
        task.sleep(0.2)
      end

      expect(ntfy.sent.size).to eq(1)
      expect(ntfy.sent.first.first.input.to_s).not_to include(secret)
    end

    it "announces nothing again when a reconnect publishes the item again" do
      announcing do |task|
        park(task)
        published(1)
        clock.now = asked + 60
        wait_until(reason: "the call was announced") { ntfy.sent.any? }
        registration.deliver(Lain::Daemon::Registration::RECONNECTED)
        published(2)
        task.sleep(0.1)
      end

      expect(ntfy.sent.size).to eq(1)
    end

    it "records a failed announcement once and keeps serving" do
      failing = RemoteSurfaceSpecSupport::Ntfy.new(clock, failing: IOError.new("ntfy is down"))
      announcing(ntfy: failing) do |task|
        park(task)
        published(1)
        clock.now = asked + 60
        wait_until(reason: "the failure was recorded") { records("approval_surface_fault").any? }
        park(task, "second")
        published(2)
      end

      expect(records("approval_surface_fault").map { _1["error"] }).to eq(["IOError: ntfy is down"])
    end

    it "publishes a second call while the announcement of the first hangs" do
      silent = TCPServer.new("127.0.0.1", 0)
      real = Lain::Remote::Ntfy.new(url: "http://127.0.0.1:#{silent.addr[1]}/lain-x7", timeout: 30)
      NetworkAccess.permit_loopback(silent.addr[1]) do
        announcing(ntfy: real) do |task|
          park(task)
          published(1)
          clock.now = asked + 60
          silent.wait_readable(10) || raise("the announcement never reached the server")
          park(task, "after the announcement began")
          published(2)
        end
      end
      silent.close

      expect(registration.added_ids).to eq(%w[1 2])
    end

    it "announces an item once even when a refused answer makes the surface publish it again" do
      announcing do |task|
        park(task)
        published(1)
        clock.now = asked + 60
        wait_until(reason: "the call was announced") { ntfy.sent.any? }
        registration.deliver("answer",
                             [wire::Answer::Question.new(id: "1", option: nil, text: "yes", device: nil).to_wire])
        published(2)
        park(task, "marker")
        wait_until(reason: "the marker was announced") { ntfy.sent.size >= 2 }
      end

      expect(ntfy.sent.map { _1.first.id }.tally.values).to eq([1, 1])
    end
  end
end
