# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"

# The chat's end of the input rail when the human is in another pane. Driven
# against a REAL Unix socket throughout -- the object's whole subject is a file
# in the filesystem and a byte stream over it, and a doubled socket would leave
# the stale-path probe and the 0600 mode untested.
RSpec.describe Lain::CLI::InputSocket do
  subject(:socket) { described_class.new(rail:, path:, header:, commands: -> { %w[approve inbox] }) }

  let(:runtime) { Dir.mktmpdir("lain-input-socket") }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => runtime }) }
  let(:path) { described_class.path(name: "s1", paths:, cwd: Dir.pwd) }
  let(:rail) { Lain::Frontend::InputRail.new }
  let(:header) { -> { hud } }
  let(:hud) { +"fleet:0 inbox:0" }

  after do
    socket.stop
    FileUtils.remove_entry(runtime)
  end

  # A connected pane. Every read is bounded, so a frame that never arrives ends
  # the example with a timeout rather than hanging the suite.
  def connect
    UNIXSocket.new(path).tap { |client| client.timeout = 5 }
  end

  def next_frame(client, of:)
    frames = Enumerator.produce { JSON.parse(client.gets.to_s) }
    frames.find { |frame| frame["v"] == of }
  end

  def send_frame(client, frame)
    client.write("#{JSON.generate(frame)}\n")
    client.flush
  end

  # Whatever the block answers once it stops answering nil, or nil at the
  # deadline: the server reads its frames on a thread of its own.
  def settles(within: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    Enumerator.produce { sleep(0.005) && yield }
              .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
  end

  # One race for the path: how many of two contenders bound it, and how many
  # were refused by name.
  def race_to_bind
    gate = Thread::Queue.new
    outcomes = Thread::Queue.new
    racers = Array.new(2) { Thread.new { contend(gate, outcomes) } }
    2.times { gate.push(true) }
    racers.each(&:join)
    settled = [outcomes.pop, outcomes.pop]
    settled.grep(described_class).each(&:stop)
    [settled.grep(described_class).size, settled.count(:refused)]
  end

  def contend(gate, outcomes)
    contender = described_class.new(rail: Lain::Frontend::InputRail.new, path:)
    gate.pop
    outcomes.push(contender.bind)
  rescue described_class::InUse
    outcomes.push(:refused)
  end

  def refused(candidate)
    turned_away_at(candidate)
    nil
  rescue Lain::Error => e
    e
  end

  # A second chat that tried for `candidate` and was sent away, so an example
  # can ask what it did with the lock and the path on its way out.
  def turned_away_at(candidate)
    chat = described_class.new(rail: Lain::Frontend::InputRail.new, path: candidate)
    @turned_away = chat
    chat.bind
  end

  # Frames off a client until one whose header carries `marker`, or nil.
  def header_reaching(client, marker)
    Enumerator.produce { JSON.parse(client.gets.to_s) }
              .find { |frame| frame["header"].to_s.include?(marker) }
  end

  # A reader parked on the rail, so something is published for the pane to draw.
  def publish(kind, text, keys: {})
    answered = Thread::Queue.new
    Thread.new { answered.push(rail.read(kind, text, keys:)) }
    settles { rail.published.kind == kind || nil }
    answered
  end

  describe ".named" do
    it "reads the socket's name out of an --input option" do
      expect(described_class.named("socket:s1")).to eq("s1")
    end

    it "names the default chat socket when the option carries no name" do
      expect(described_class.named("socket:")).to eq(described_class::DEFAULT_NAME)
    end

    it "answers nothing for an option that asks for no socket" do
      expect([described_class.named(nil), described_class.named("tty")]).to eq([nil, nil])
    end
  end

  describe ".path" do
    it "carries no pid, so both panes can be written before either process starts" do
      expect(File.basename(path)).to eq("input-#{paths.project_hash(Dir.pwd)}-s1.sock")
    end

    it "keeps the runtime directory to its owner" do
      expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    end
  end

  describe "#bind" do
    it "leaves the socket readable only by its owner" do
      socket.bind
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    # Asserted by talking to whoever is on the path afterwards, not by the
    # inode: a freed inode number is handed straight back out on tmpfs, so
    # "it changed" is not evidence that the listener did.
    it "replaces a stale socket a killed chat left behind" do
      UNIXServer.new(path).close

      socket.bind.start(nil)

      expect(next_frame(connect, of: "context")["commands"]).to eq(%w[approve inbox])
    end

    it "refuses a path another live chat is listening on, naming it" do
      socket.bind
      second = described_class.new(rail: Lain::Frontend::InputRail.new, path:)
      expect { second.bind }.to raise_error(described_class::InUse, /#{Regexp.escape(path)}/)
    end

    # Probe-then-unlink was a TOCTOU: a socket that went live between the probe
    # and the unlink was DELETED, and both chats then believed they owned the
    # name while the pane could only ever reach one of them.
    it "lets exactly one of two chats racing for the path own it, every time" do
      rounds = Array.new(20) { race_to_bind }

      expect(rounds.uniq).to eq([[1, 1]])
    end

    it "reads a live socket it may not connect to as live, never as stale" do
      server = UNIXServer.new(path)
      File.chmod(0o000, path)

      expect { socket.bind }.to raise_error(described_class::InUse)
    ensure
      server&.close
    end

    # The kernel's wording for a directory on the path is "Address already in
    # use - connect(2)", which reads exactly like the refusal it is not.
    it "refuses a path that cannot carry a socket in words, not in a backtrace" do
      refusals = [File.join(runtime, "adirectory.sock"), File.join(runtime, "nope", "deep.sock")].map do |candidate|
        FileUtils.mkdir_p(candidate) if candidate.end_with?("adirectory.sock")
        refused(candidate)
      end

      expect(refusals).to all(be_a(described_class::Unusable))
      expect(refusals.map(&:message).join).not_to include("connect(2)")
    end

    # The lock is what makes the refusal enforced, so a chat that was REFUSED
    # must not keep holding it: it would then be the thing refusing everybody
    # else, long after the listener it was turned away by has gone.
    it "hands the lock back when its own bind is refused" do
      incumbent = UNIXServer.new(path)
      refused(path)
      incumbent.close
      File.unlink(path)

      expect(socket.bind).to be(socket)
    end

    it "unlinks only a path it bound, so a chat sent away cannot delete the owner's socket" do
      incumbent = UNIXServer.new(path)
      refused(path)

      @turned_away.stop

      expect(File.socket?(path)).to be(true)
    ensure
      incumbent&.close
    end
  end

  describe "serving a pane" do
    before { socket.bind.start(nil) }

    it "publishes the drawn prompt, its header and its kind" do
      client = connect
      publish(:you, "you> ")
      frame = next_frame(client, of: "prompt")
      expect(frame.values_at("kind", "text", "header")).to eq(["you", "you> ", "fleet:0 inbox:0"])
    end

    it "tells a pane the command names it completes against, since the pane holds no registry" do
      expect(next_frame(connect, of: "context")["commands"]).to eq(%w[approve inbox])
    end

    it "answers the drawn prompt with a line the pane sends" do
      client = connect
      answered = publish(:you, "you> ")
      generation = next_frame(client, of: "prompt")["generation"]
      send_frame(client, { "v" => "line", "text" => "hello", "generation" => generation })
      expect(answered.pop).to eq("hello")
    end

    it "routes a signal the pane sends where an OS signal would go" do
      sink = Struct.new(:names) { def signal(name) = names.push(name) }.new(Thread::Queue.new)
      rail.route(sink)
      send_frame(connect, { "v" => "signal", "name" => "sigint" })
      expect(sink.names.pop).to eq(:sigint)
    end

    it "ends the read when the pane's stream ends" do
      client = connect
      answered = publish(:you, "you> ")
      send_frame(client, { "v" => "eof" })
      expect(answered.pop).to be_nil
    end

    it "re-sends the drawn prompt under its own generation when the publication changes" do
      client = connect
      publish(:you, "you> ")
      first = next_frame(client, of: "prompt")
      hud.replace("fleet:2 inbox:1")
      again = next_frame(client, of: "prompt")
      expect([again["generation"], again["header"]]).to eq([first["generation"], "fleet:2 inbox:1"])
    end

    it "carries the countdown's keys so the pane can offer them" do
      client = connect
      publish(:countdown, "closing in 30s", keys: { "c" => :cancel })
      expect(next_frame(client, of: "prompt")["keys"]).to eq({ "c" => "cancel" })
    end

    it "reports the prompt untouched until the pane says otherwise" do
      client = connect
      publish(:you, "you> ")
      prompt = rail.published
      send_frame(client, { "v" => "touch", "generation" => prompt.generation, "untouched" => false })
      expect(settles { socket.untouched?(prompt) == false || nil }).to be(true)
    end

    it "tracks what each pane said was typed, so one mid-edit keeps the terminal from every other" do
      mid_edit = connect
      idle = connect
      publish(:you, "you> ")
      prompt = rail.published
      [next_frame(mid_edit, of: "prompt"), next_frame(idle, of: "prompt")]

      send_frame(mid_edit, { "v" => "touch", "generation" => prompt.generation, "untouched" => false })
      send_frame(idle, { "v" => "touch", "generation" => prompt.generation, "untouched" => true })

      expect(settles { socket.untouched?(prompt) == false || nil }).to be(true)
    end

    it "reaps a closed pane's reader, so it owns every thread it started" do
      standing = Thread.list.size
      30.times { connect.close }

      expect(settles { Thread.list.size <= standing + 2 || nil }).to be(true)
      # The registry has no public reader on purpose -- nothing but #stop has
      # any use for it -- and its unbounded growth is the defect under test.
      expect(socket.instance_variable_get(:@threads).size).to be <= 4
    end

    # A plain `lain chat` has no ceiling on a pasted line, so neither may the
    # pane that replaces it: the WRITE backlog is a different budget and must
    # not double as one.
    it "carries a paste far larger than the write backlog, whole" do
      answered = publish(:you, "you> ")
      pasted = "x" * (described_class::Client::BACKLOG * 2)

      send_frame(connect, { "v" => "line", "text" => pasted, "generation" => rail.published.generation })

      expect(answered.pop.bytesize).to eq(pasted.bytesize)
    end

    it "says goodbye before the path goes, so a pane can tell a clean close from a kill" do
      client = connect
      next_frame(client, of: "context")
      socket.stop
      expect([next_frame(client, of: "closed"), File.exist?(path)]).to eq([{ "v" => "closed" }, false])
    end
  end

  # A pane can be alive and not reading -- Ctrl-Z in `lain input` stops the
  # process while its descriptor stays open. A blocking write to one of those
  # parks the publish thread, darkens every other pane, and, because the
  # goodbye is written on the chat's own exit path, stops the chat exiting.
  describe "a pane that is alive and has stopped reading" do
    subject(:socket) { described_class.new(rail:, path:, header: -> { headers.last }, tick: 0.002) }

    # Appended to rather than mutated in place: the publish thread reads this
    # while the example writes it, and a String rewritten under a reader is a
    # race the subject is not the one being measured for.
    let(:headers) { ["#{"x" * 60_000}opening"] }

    before { socket.bind.start(nil) }

    # A pause per change, or the publish thread coalesces them into one frame
    # and the deaf pane's buffer never fills. Forty wide frames is 2.4 MB, well
    # past the ~43 KB a peer's socket buffer holds.
    def fill_the_deaf_pane
      40.times do |change|
        headers.push("#{"x" * 60_000}change#{change}")
        sleep(0.005)
      end
    end

    it "is passed over, while every other pane keeps drawing" do
      # Held in a local: an unreferenced socket is collected and CLOSED, and a
      # collected pane is a gone one rather than the deaf one under test.
      deaf = connect
      healthy = connect
      publish(:you, "you> ")
      # Draining as the frames arrive, which is what makes this pane the
      # healthy one: a reader that only looks at the end is as deaf as the other.
      seen = Thread.new { header_reaching(healthy, "the last word") }
      fill_the_deaf_pane

      headers.push("#{"x" * 60_000}the last word")

      expect(seen.value).to include("v" => "prompt")
      expect(deaf).to be_a(UNIXSocket)
    end

    it "is said out loud, so the flicker in the pane has an explanation" do
      said = []
      socket.stop
      loud = described_class.new(rail:, path:, header: -> { headers.last }, tick: 0.002,
                                 notice: ->(word) { said << word })
      loud.bind.start(nil)
      deaf = connect
      publish(:you, "you> ")
      fill_the_deaf_pane

      expect([settles { said.first }, deaf].first).to include("stopped reading")
    ensure
      loud&.stop
    end

    it "cannot keep the chat from exiting" do
      deaf = connect
      publish(:you, "you> ")
      fill_the_deaf_pane

      goodbye = Thread.new { socket.stop }

      expect([goodbye.join(5), deaf.closed?]).to eq([goodbye, false])
    end
  end

  describe "a frame past what one frame may be" do
    subject(:socket) { described_class.new(rail:, path:, notice: ->(word) { said << word }) }

    let(:said) { [] }

    before { socket.bind.start(nil) }

    # Silence is the one thing a refusal may not be: the pieces of an
    # over-long line are each unparseable, so dropping them quietly leaves the
    # chat's prompt simply never answering.
    it "is refused whole, and said out loud" do
      publish(:you, "you> ")
      client = connect
      client.write(%({"v":"line","text":"#{"y" * (described_class::Client::FRAME_LIMIT + 4096)}"}\n))
      client.flush

      expect(settles { said.first }).to include("one line")
    end
  end

  describe "with no pane connected" do
    it "composes no header, command list or layer set at all" do
      asked = []
      quiet = described_class.new(rail:, path:, header: -> { asked.push(:header).last.to_s },
                                  layers: -> { asked.push(:layers) && [] }, tick: 0.002)
      quiet.bind.start(nil)
      publish(:you, "you> ")
      settles(within: 0.3) { nil }

      expect(asked).to eq([])
    ensure
      quiet&.stop
    end
  end
end

# The HUD leads with a multibyte glyph and JSON.generate emits it raw, so
# every real frame is one where bytes and characters disagree -- and a short
# write is where that difference is either kept or silently thrown away.
RSpec.describe Lain::CLI::InputSocket::Client do
  let(:pair) { UNIXSocket.pair }
  let(:reader) { pair.first }
  let(:writer) { pair.last }

  after { pair.each { |io| io.close unless io.closed? } }

  # Small buffers so a short write happens at a few KB, rather than after a
  # pane has fallen a few hundred behind. The CONDITION is the subject.
  def cramped
    writer.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)
    reader.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
    described_class.new(writer)
  end

  def wide_frame
    Lain::CLI::InputSocket::Codec.dump({ "v" => "prompt", "kind" => "you", "text" => "you> ",
                                         "header" => "#{"\u{1f525} fleet:2 inbox:1 ctx:42% " * 900}end",
                                         "keys" => {}, "layers" => [], "generation" => 7 })
  end

  # Read and poke by turns: only a write moves what a short one left behind.
  def drained(client)
    held = String.new(encoding: Encoding::BINARY)
    Enumerator.produce { reader.read_nonblock(65_536, exception: false) }
              .lazy.take(200)
              .each do |chunk|
                held << chunk if chunk.is_a?(String)
                client.drain
                sleep(0.005)
              end
    held
  end

  it "loses not one byte of a multibyte frame to a short write" do
    frame = wide_frame
    client = cramped

    client << frame

    expect(drained(client)).to eq(frame.b)
  end

  it "carries a frame whose bytes and characters differ, which every real one does" do
    frame = wide_frame

    expect(frame.bytesize).to be > frame.length
  end
end
