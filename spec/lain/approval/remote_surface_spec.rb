# frozen_string_literal: true

require "async"
require "fileutils"
require "json"
require "socket"
require "stringio"
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

  # The built lain-core relay on a loopback port, with one paired device.
  class Relay
    BINARY = File.join(Lain::Paths::Shipped.cargo_target, "debug", "lain-core")
    START_BUDGET = 5.0

    attr_reader :socket, :port, :token

    def initialize(dir, socket: File.join(dir, "sock", "relay.sock"))
      @dir = dir
      @socket = socket
      FileUtils.mkdir_p(File.dirname(@socket), mode: 0o700)
      devices = Lain::Remote::Devices.new(File.join(dir, "devices", "devices"))
      @token = devices.pair("pixel")
      @devices_file = devices.path
      @port = TCPServer.open("127.0.0.1", 0) { _1.addr[1] }
    end

    def start
      @pid = Process.spawn(BINARY, "relay", "--unix", @socket, "--listen", "127.0.0.1:#{@port}",
                           "--devices-file", @devices_file, in: :close, out: :close,
                                                            err: File.join(@dir, "relay.log"))
      wait_for_socket
      self
    end

    def stop
      return unless @pid

      Process.kill("TERM", @pid)
      Process.wait(@pid)
      @pid = nil
    rescue Errno::ESRCH, Errno::ECHILD
      @pid = nil
    end

    def log = File.read(File.join(@dir, "relay.log"))

    private

    def wait_for_socket
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_BUDGET
      until File.socket?(@socket)
        raise "the relay did not start: #{log}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.02
      end
    end
  end

  # The phone's side of the relay, over TCP with the paired token, speaking the
  # wire through the same Core::Client the surface uses.
  class Phone
    def initialize(relay)
      socket = TCPSocket.new("127.0.0.1", relay.port)
      @client = Lain::Core::Client.new(transport: Lain::Core::Transport::Mock.new(socket:), socket:)
      hello = Lain::Remote::Wire::Hello.new(wire_version: Lain::Remote::Wire::VERSION, token: relay.token, cursor: 0)
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

  def surface(socket, secrets: [], agenda: self.agenda, journal: self.journal, **options)
    described_class.new(transport: Lain::Core::Transport::Unix.new(socket), agenda:, secrets:, journal:,
                        poll_interval: 0.02, project: "/work", **options)
  end

  def agenda_over(gates: RemoteSurfaceSpecSupport::NoGates.new, queue: self.queue, **options)
    Lain::Remote::Agenda.new(queue:, gates:, replies: RemoteSurfaceSpecSupport::NoReplies.new, **options)
  end

  def park(task, command = "ls -la")
    task.async { dispatch_call("bash", { "command" => command }, toolset:, layers: [gate]) }
  end

  def records(type) = journal_records(journal_io, type)

  describe "a dead relay degrades" do
    it "returns from its watch and names the remote surface in a capability_degraded record" do
      Sync { |task| task.with_timeout(5) { surface(File.join(@dir, "absent.sock")).watch } }

      expect(records("capability_degraded"))
        .to contain_exactly(a_hash_including("capability" => "remote_surface",
                                             "requirer" => described_class.name,
                                             "provider" => a_string_including("absent.sock")))
    end

    it "leaves the desk answering the parked call it could not publish" do
      outcome = Sync do |task|
        task.async { surface(File.join(@dir, "absent.sock")).watch }
        call = park(task)
        wait_until(reason: "the call parked") { queue.any? }
        queue.first.approve(surface: "desk", authority: :human)
        task.with_timeout(5) { call.wait }
      end

      expect([outcome, runs]).to eq([Lain::Tool::Result.ok("ran ls -la"), [{ "command" => "ls -la" }]])
    end
  end

  it "degrades with its own reason when the socket's directory is open to others" do
    dir = File.join(@dir, "loose")
    FileUtils.mkdir_p(dir, mode: 0o755)
    File.chmod(0o755, dir)
    Sync { |task| task.with_timeout(5) { surface(File.join(dir, "relay.sock")).watch } }

    expect(records("capability_degraded").map { _1["provider"] }).to contain_exactly(a_string_including("0755"))
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
  end

  it "is not built without the project its items name" do
    expect { described_class.new(transport: Lain::Core::Transport::Unix.new(File.join(@dir, "absent.sock")), agenda:, secrets: []) }
      .to raise_error(ArgumentError, /project/)
  end

  it "dials the relay's socket in the runtime directory, one per project" do
    paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => "/run/user/7", "HOME" => "/home/x" })

    expect(described_class.socket(paths:, root: @dir))
      .to eq(File.join("/run/user/7/lain", "remote-#{paths.project_hash(@dir)}", "relay.sock"))
  end

  describe "over the built relay", :core do
    let(:relay) { RemoteSurfaceSpecSupport::Relay.new(@dir).start }
    let(:wire) { Lain::Remote::Wire }

    after { relay.stop }

    # Watching, a phone connected, and one call parked: the block gets the
    # phone, the call's task and the call as the phone sees it.
    def with_a_parked_call(secrets: [], command: "ls -la")
      Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, secrets:).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          call = park(task, command)
          item = phone.until_open(&:any?).first
          yield phone, call, item
        ensure
          phone&.stop
          watching&.stop
        end
      end
    end

    def approve(item) = wire::Answer::Call.new(id: item.id, verdict: Lain::Approval::Verdict::Approve.new, device: nil)

    context "when built by .for" do
      let(:paths) { Lain::Paths.new(env: { "HOME" => @dir, "XDG_RUNTIME_DIR" => File.join(@dir, "r") }) }
      let!(:relay) { RemoteSurfaceSpecSupport::Relay.new(@dir, socket: described_class.socket(paths:, root: @dir)).start }

      it "names no session of its own and the root it was built for on the item the phone sees" do
        built = described_class.for(relay: "127.0.0.1:7820", ntfy: nil, paths:, root: Pathname(@dir), queue:,
                                    replies: RemoteSurfaceSpecSupport::NoReplies.new, secrets: [], journal:)
        item = Sync do |task|
          task.with_timeout(20) do
            watching = task.async { built.watch }
            phone = RemoteSurfaceSpecSupport::Phone.new(relay)
            call = park(task)
            phone.until_open(&:any?).first
          ensure
            call&.stop
            phone&.stop
            watching&.stop
          end
        end

        expect([item.session, item.project]).to eq([described_class::UNREGISTERED, @dir])
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

    it "leaves the desk's later answer losing to the phone's" do
      desk = with_a_parked_call do |phone, call, item|
        pending = queue.first
        phone.answer(approve(item))
        call.wait
        pending.deny(surface: "desk", authority: :human)
      end

      expect(desk).to be(false)
      expect(records("approval_decision").map { _1["surface"] }).to eq(["remote:pixel"])
    end

    it "shows the phone why a wrong-typed answer was refused, and keeps the item open for another" do
      shown = with_a_parked_call do |phone, call, item|
        phone.answer(wire::Answer::Question.new(id: item.id, option: nil, text: "yes please", device: nil))
        again = phone.until_open { |open| open.any? { _1.id == item.id && _1.why.include?("not a verdict") } }
        phone.answer(approve(item))
        call.wait
        again.first.why
      end

      expect(shown).to include("not a verdict")
      expect(runs).to eq([{ "command" => "ls -la" }])
    end

    it "records a gate owner's refusal, shows it to the phone, and keeps serving" do
      gated = agenda_over(gates: RemoteSurfaceSpecSupport::RaisingGates.new)
      shown = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, agenda: gated).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          gate_item = phone.until_open(&:any?).first
          phone.answer(approve(gate_item))
          phone.until_open { |open| open.any? { _1.question.include?("no epic document") } }
          call = park(task)
          parked = phone.until_open { |open| open.any? { _1.respond_to?(:tool) } }.find { _1.respond_to?(:tool) }
          phone.answer(approve(parked))
          [call.wait, watching.running?]
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(shown).to eq([Lain::Tool::Result.ok("ran ls -la"), true])
      expect(records("approval_surface_fault").map { _1["error"] })
        .to contain_exactly(a_string_including("MissingEpicDocument", "no epic document for e"))
    end

    it "refuses a gate answer with no verdicts, shows the phone why, and takes the answer keyed by the stage" do
      stage_gate = RemoteSurfaceSpecSupport::StageGate.new
      shown = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, agenda: agenda_over(gates: stage_gate)).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          item = phone.until_open(&:any?).first
          phone.answer(wire::Answer::Gate.new(id: item.id, verdicts: [], device: nil))
          again = phone.until_open { |open| open.any? { _1.question.include?("names no issue") } }.first
          phone.answer(wire::Answer::Gate.new(id: again.id, verdicts: again.issues.map { [_1, approve(item).verdict] },
                                              device: nil))
          wait_until(reason: "the keyed answer landed") { stage_gate.answers.any? }
          [item.issues, again.question]
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(shown).to match([%w[research], a_string_including("refused", "names no issue")])
      expect(stage_gate.answers).to eq([[:approve, "d1", nil, "remote:pixel"]])
    end

    it "hands a question's answer on with the device that gave it" do
      asked = RemoteSurfaceSpecSupport::OneQuestion.new
      Sync do |task|
        task.with_timeout(20) do
          agenda = Lain::Remote::Agenda.new(queue:, gates: RemoteSurfaceSpecSupport::NoGates.new, replies: asked)
          watching = task.async { surface(relay.socket, agenda:).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          item = phone.until_open(&:any?).first
          phone.answer(wire::Answer::Question.new(id: item.id, option: nil, text: "main", device: nil))
          wait_until(reason: "the answer was handed on") { asked.answers.any? }
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(asked.answers).to eq([["main", "blake3:q1", "remote:pixel"]])
    end

    it "shows the phone a refusal without the path under home it names" do
      document = File.join(Dir.home, "dev", "nyotes", "epics", "e", "plan.md")
      gated = agenda_over(gates: RemoteSurfaceSpecSupport::RaisingGates.new("no epic document at #{document}"))
      shown = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, agenda: gated).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          phone.answer(approve(phone.until_open(&:any?).first))
          phone.until_open { |open| open.any? { _1.question.include?("no epic document") } }.first.question
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(shown).to include("no epic document at", described_class::PATH_MASK)
      expect(shown).not_to include(Dir.home)
    end

    it "leaves an answer to another chat's item to that chat" do
      other_io = StringIO.new
      other_journal = Lain::Journal.new(io: other_io)
      other_queue = Lain::Approval::Parked::Queue.new(journal: other_journal, timeout: 10)
      other_toolset_gate = Lain::Middleware::Gate.new(policy: asking_ladder(other_queue, tools: toolset,
                                                                                         journal: other_journal))
      ran = Sync do |task|
        task.with_timeout(20) do
          ours = task.async { surface(relay.socket).watch }
          theirs = task.async do
            surface(relay.socket, agenda: agenda_over(queue: other_queue), journal: other_journal).watch
          end
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          our_call = task.async { dispatch_call("bash", { "command" => "ours" }, toolset:, layers: [gate]) }
          their_call = task.async do
            dispatch_call("bash", { "command" => "theirs" }, toolset:, layers: [other_toolset_gate])
          end
          open = phone.until_open { _1.size == 2 }
          phone.answer(approve(open.find { JSON.parse(_1.input)["command"] == "theirs" }))
          their_call.wait
          runs.dup
        ensure
          phone&.stop
          [ours, theirs, our_call].compact.each(&:stop)
        end
      end

      expect(ran).to eq([{ "command" => "theirs" }])
      expect(records("approval_surface_fault")).to be_empty
    end

    it "takes back what it published when it stops, so the phone stops showing it" do
      left = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          call = park(task)
          phone.until_open(&:any?)
          watching.stop
          phone.until_open(&:empty?).tap { call.stop }
        ensure
          phone&.stop
        end
      end

      expect(left).to be_empty
    end

    it "records a secrets source that raises once, and publishes nothing unmasked" do
      failing = Class.new { def to_a = raise(IOError, "the history walk failed") }.new
      seen = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, secrets: failing).watch }
          call = park(task)
          wait_until(reason: "a sweep failed twice over") { records("approval_surface_fault").any? }
          task.sleep(0.1)
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          [call, watching].each(&:stop)
          phone.stop
          phone.head
        end
      end

      expect(seen).to eq(0)
      expect(records("approval_surface_fault").map { _1["error"] }).to eq(["IOError: the history walk failed"])
    end

    it "writes a line naming the item and the device when the phone's answer loses to the desk" do
      Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, agenda: RemoteSurfaceSpecSupport::DeskFirst.new(agenda, queue)).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          call = park(task)
          item = phone.until_open(&:any?).first
          phone.answer(approve(item))
          call.wait
          wait_until(reason: "the lost answer was recorded") { records(described_class::LOST_TYPE).any? }
          @item_id = item.id
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(records(described_class::LOST_TYPE)).to contain_exactly(a_hash_including("id" => @item_id,
                                                                                      "device" => "pixel"))
      expect(records("approval_decision").map { _1["surface"] }).to eq(["desk"])
    end

    it "sends the phone an unreadable gate journal without its path, before and after an answer" do
      unreadable = agenda_over(gates: RemoteSurfaceSpecSupport::UnreadableGates.new)
      texts = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket, agenda: unreadable).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          first = phone.until_open(&:any?).first
          phone.answer(approve(first))
          again = phone.until_open { |open| open.any? { _1.question != first.question } }.first
          [first, again].map { _1.to_h.values.join(" ") }
        ensure
          phone&.stop
          watching&.stop
        end
      end

      expect(texts).to all(include("gate journal").and(include("desk")))
      expect(texts.join).not_to include(".ndjson", "/home/")
    end

    it "degrades once the relay dies under it, and the desk keeps the call" do
      outcome = Sync do |task|
        task.with_timeout(20) do
          watching = task.async { surface(relay.socket).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          call = park(task)
          phone.until_open(&:any?)
          relay.stop
          watching.wait
          queue.first.approve(surface: "desk", authority: :human)
          call.wait && :desk_answered
        ensure
          phone&.stop
        end
      end

      expect(outcome).to eq(:desk_answered)
      expect(records("capability_degraded").map { _1["capability"] }).to eq(["remote_surface"])
    end
  end

  describe "announcing a waiting item through ntfy", :core do
    let(:relay) { RemoteSurfaceSpecSupport::Relay.new(@dir).start }
    let(:asked) { Time.at(1_000) }
    let(:clock) { RemoteSurfaceSpecSupport::Clock.new(asked) }
    let(:ntfy) { RemoteSurfaceSpecSupport::Ntfy.new(clock) }
    let(:timed) { agenda_over(wall: -> { asked }) }

    after { relay.stop }

    def watching(task, **options)
      task.async { surface(relay.socket, agenda: timed, ntfy:, clock:, buzz_after: 60, **options).watch }
    end

    def sent_ids = ntfy.sent.map { _1.first.id }

    # A call left parked holds the Sync block open until the queue's 10 s timeout.
    def settle_parked = queue.to_a.each { _1.approve(surface: "desk", authority: :human) }

    it "announces a call once it has waited the delay, not before" do
      Sync do |task|
        task.with_timeout(20) do
          watch = watching(task)
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          park(task)
          item = phone.until_open(&:any?).first
          clock.now = asked + 59
          phone.until_open(&:any?)
          clock.now = asked + 60
          wait_until(reason: "the call was announced") { ntfy.sent.any? }
          @item = item
          settle_parked
          watch.stop
          phone.stop
        end
      end

      expect(ntfy.sent.map { |view, at| [view.id, view.requester, at] }).to eq([[@item.id, "agent", asked + 60]])
    end

    it "does not announce a call the desk answered first" do
      Sync do |task|
        task.with_timeout(20) do
          watch = watching(task)
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          first = park(task)
          phone.until_open(&:any?)
          clock.now = asked + 30
          queue.first.approve(surface: "desk", authority: :human)
          first.wait
          phone.until_open(&:empty?)
          clock.now = asked + 61
          park(task, "second")
          wait_until(reason: "the second call was announced") { ntfy.sent.any? }
          settle_parked
          watch.stop
          phone.stop
        end
      end

      expect(ntfy.sent.map { _1.first.input }).to eq([{ "command" => "second" }])
    end

    it "announces the masked view under the id the phone knows, and announces each item once" do
      secret = "hunter2-correct-horse-battery"
      Sync do |task|
        task.with_timeout(20) do
          watch = watching(task, secrets: [secret])
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          park(task, "deploy --password #{secret}")
          @item = phone.until_open(&:any?).first
          clock.now = asked + 600
          wait_until(reason: "the call was announced") { ntfy.sent.any? }
          task.sleep(0.2)
          settle_parked
          watch.stop
          phone.stop
        end
      end

      expect(ntfy.sent.size).to eq(1)
      expect(ntfy.sent.first.first).to have_attributes(id: @item.id)
      expect(ntfy.sent.first.first.input.to_s).not_to include(secret)
    end

    it "records a failed announcement once and keeps serving the phone" do
      failing = RemoteSurfaceSpecSupport::Ntfy.new(clock, failing: IOError.new("ntfy is down"))
      Sync do |task|
        task.with_timeout(20) do
          watch = task.async { surface(relay.socket, agenda: timed, ntfy: failing, clock:, buzz_after: 60).watch }
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          call = park(task)
          item = phone.until_open(&:any?).first
          clock.now = asked + 60
          wait_until(reason: "the failure was recorded") { records("approval_surface_fault").any? }
          phone.answer(wire_approve(item))
          call.wait
          settle_parked
          watch.stop
          phone.stop
        end
      end

      expect(records("approval_surface_fault").map { _1["error"] }).to eq(["IOError: ntfy is down"])
      expect(runs).to eq([{ "command" => "ls -la" }])
    end

    it "shows a second call and takes the desk's answer while the announcement of the first hangs" do
      silent = TCPServer.new("127.0.0.1", 0)
      real = Lain::Remote::Ntfy.new(url: "http://127.0.0.1:#{silent.addr[1]}/lain-x7", timeout: 30)
      result = NetworkAccess.permit_loopback(silent.addr[1]) do
        Sync do |task|
          task.with_timeout(20) do
            watch = task.async { surface(relay.socket, agenda: timed, ntfy: real, clock:, buzz_after: 60).watch }
            phone = RemoteSurfaceSpecSupport::Phone.new(relay)
            call = park(task)
            phone.until_open(&:any?)
            clock.now = asked + 60
            silent.wait_readable(10) || raise("the announcement never reached the server")
            park(task, "after the announcement began")
            item = phone.until_open { _1.size == 2 }.find { _1.input.include?("ls -la") }
            phone.answer(wire_approve(item))
            call.wait
          ensure
            settle_parked
            phone&.stop
            watch&.stop
          end
        end
      end
      silent.close

      expect(result).to eq(Lain::Tool::Result.ok("ran ls -la"))
    end

    it "announces an item once even when a refused answer makes the surface publish it again" do
      Sync do |task|
        task.with_timeout(20) do
          watch = watching(task)
          phone = RemoteSurfaceSpecSupport::Phone.new(relay)
          park(task)
          first = phone.until_open(&:any?).first
          clock.now = asked + 60
          wait_until(reason: "the call was announced") { ntfy.sent.any? }
          phone.answer(Lain::Remote::Wire::Answer::Question.new(id: first.id, option: nil, text: "yes", device: nil))
          phone.until_open { |open| open.any? { _1.why.include?("not a verdict") } }
          park(task, "marker")
          wait_until(reason: "the marker was announced") { ntfy.sent.size >= 2 }
          @first = first
          settle_parked
          watch.stop
          phone.stop
        end
      end

      expect(sent_ids.tally.values).to eq([1, 1])
    end

    def wire_approve(item)
      Lain::Remote::Wire::Answer::Call.new(id: item.id, verdict: Lain::Approval::Verdict::Approve.new, device: nil)
    end
  end
end
