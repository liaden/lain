# frozen_string_literal: true

require "async"
require "delegate"
require "json"
require "pastel"
require "stringio"
require "timeout"
require "tmpdir"

# The editor's command rail as its consumer sees it
# ({Lain::Frontend::Neovim::CommandInbox}'s duck), with the push the RPC thread
# makes when a keymap fires. Its own class rather than an instance_double
# because the whole question here is WHEN somebody pops it, which only a real
# queue can answer.
class ReplEditorRail
  def initialize
    @commands = Thread::Queue.new
    @refusals = []
  end

  attr_reader :refusals

  def push(command) = @commands.push(command)

  # {Thread::Queue#pop}'s duck, non-blocking arm included: the consumer polls
  # with `pop(true)`, which raises ThreadError on an empty queue.
  def pop(...) = @commands.pop(...)
  def review_refused(message) = @refusals << message
  def attached? = true
end

# The changeset review the sidebar's gestures resolve against, recorded -- what
# a human marking a hunk at `you>` is trying to reach.
class ReplChangesetReview
  Outcome = Struct.new(:report) do
    def opened? = true
    def marked? = true
    def asked? = true
  end

  def initialize = @gestures = []

  attr_reader :gestures

  def open(line, generation: nil) = record([:open, line, generation])
  def mark(line, state, generation: nil) = record([:mark, line, state, generation])
  def ask(anchor_id, question) = record([:ask, anchor_id, question])

  private

  def record(gesture)
    @gestures << gesture
    Outcome.new("nothing to report")
  end
end

# The real {Lain::CLI::HumanReplies} with an editor ALREADY attached. {Repl#run}
# binds the frontend it builds, and an example with no nvim to build one from
# would have its rail overwritten by that bind -- so the two binds are refused
# here and everything else is the production object, running production fibers.
class AttachedReplies < SimpleDelegator
  def bind_editor(*, **) = nil
  def bind_review_editor(_editor) = nil
end

RSpec.describe Lain::CLI::Repl do
  # The T1 AC round trip: a Provider::Mock, a Channel, and a Frontend::TTY over
  # StringIO stand in for the live edges; the Repl is constructed AND run
  # through Lain::CLI::Wiring#run -- the exe's own assembly path, minus the exe
  # -- via the injected tty seam (T9: no send(:build_repl), no ivar pokes).
  let(:offline_backend_class) do
    Class.new(Lain::CLI::Backend) do
      def initialize(options, mock:)
        super(options)
        @mock = mock
      end

      def provider(**) = @mock
    end
  end

  let(:mock_provider) do
    Lain::Provider::Mock.new(responses: [
                               Lain::Response.new(content: [{ "type" => "text", "text" => "hello from the mock" }],
                                                  stop_reason: :end_turn)
                             ])
  end
  let(:backend) { offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: mock_provider) }

  def run_chat(input, dir:, chronicle: Lain::CLI::Chronicle::Null.new, options: { grace: 5 })
    output = StringIO.new
    # `**` swallows T13's `prompt_renderer:` -- this spec is about the chat
    # round trip, and its StringIO input never reaches the composing path.
    tty_factory = lambda do |channel:, **|
      Lain::Frontend::TTY.new(channel:, output:, input: StringIO.new(input),
                              history_path: File.join(dir, "history"))
    end
    wiring = Lain::CLI::Wiring.new(options:, chronicle:, tty_factory:,
                                   status_feed: instance_double(Lain::StatusFeed))
    wiring.run(backend:, resumed: nil, nvim: nil)
    wiring.conductor.close(reason: :exit)
    output.string
  end

  it "settles one converse round-trip built through Wiring, and the journal records it" do
    Dir.mktmpdir do |dir|
      # Paths is injected (the chronicle_spec/journal_spec idiom), never a
      # global ENV mutation: the journal lands under this tmpdir by construction.
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir })
      chronicle = Lain::CLI::Chronicle.for(enabled: true, paths:)

      output = run_chat("hello?\n", dir:, chronicle:)

      expect(output).to include("hello from the mock")

      records = Dir.glob(File.join(dir, "lain", "sessions", "**", "*.ndjson"))
                   .flat_map { |file| File.readlines(file).map { |line| JSON.parse(line) } }
      expect(records.map { |record| record.fetch("type") }).to include("session", "turn")
      expect(records.any? { |record| record["type"] == "turn" && record.to_json.include?("hello from the mock") })
        .to be(true)
    end
  end

  # T31a: the ONE line in any process that puts an editor's review rig within a
  # tool's reach. Everything downstream of it -- the changeset drawn in nvim, the
  # sidebar gestures, the verdict a `:w` writes -- is unreachable without it, and
  # nothing else in the suite runs `Repl#run` with an editor attached at all.
  #
  # A REAL headless editor, because the seam is exactly the attach: `nvim: nil`
  # takes the other branch of `attach_editor` and would prove nothing about it.
  describe "the editor a changeset review is drawn in", :nvim, :seam do
    around do |example|
      socket = File.join(Dir.tmpdir, "lain-repl-review-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
      # `-n`, no swap file: the suite accumulates them otherwise and eventually
      # fails with E326.
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
      Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
      @socket = socket
      example.run
    ensure
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      FileUtils.rm_f(socket)
    end

    def chat_with_editor(dir)
      tty_factory = lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new("quit\n"),
                                history_path: File.join(dir, "history"))
      end
      wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new, tty_factory:,
                                     status_feed: instance_double(Lain::StatusFeed))
      wiring.run(backend:, resumed: nil,
                 nvim: { channel: Lain::Channel::DropOldest.new, socket_path: @socket })
      wiring.conductor.close(reason: :exit)
      wiring
    end

    it "binds the attached frontend as the review editor, so the tool's seams resolve to it" do
      Dir.mktmpdir do |dir|
        replies = chat_with_editor(dir).command_env.replies

        expect(replies.review_surface).to be_a(Lain::Review::Surface::Neovim)
        expect(replies.review_view).to be_a(Lain::Frontend::Neovim::ReviewView)
      end
    end

    # The other half of this card: what the Repl binds is the FRONTEND, and the
    # frontend is where a `review_verdict` is answered. Asserted on the object
    # the RPC thread will actually resolve per call ({Frontend::Neovim}'s
    # private `changeset_review`, which is what its listener reads) -- before
    # this, that slot held {Frontend::Neovim::NoReviewWrites} for the life of
    # every session ever run, because nothing called the binder.
    it "binds the frontend itself, so a review reaches the write rail nothing could reach before" do
      Dir.mktmpdir do |dir|
        replies = chat_with_editor(dir).command_env.replies
        frontend = replies.instance_variable_get(:@review_editor)
        review = Class.new do
          def wrote_verdict(_verdict) = nil
          def wrote_annotation(_note) = nil
        end.new

        replies.bind_changeset_review(review)

        expect(frontend).to be_a(Lain::Frontend::Neovim)
        expect(frontend.send(:changeset_review)).to equal(review)
      end
    end
  end

  describe "command dispatch" do
    it "consults the registry before the skill middleware: /help runs lib-side, zero model turns" do
      Dir.mktmpdir do |dir|
        output = run_chat("/help\n", dir:)

        expect(output).to include("/help", "/quit")
        expect(output).to include("skills:")
        expect(mock_provider.call_count).to eq(0)
      end
    end

    it "an unregistered /word still reaches SkillDispatch unchanged" do
      Dir.mktmpdir do |dir|
        output = run_chat("/nope\n", dir:)

        expect(output).to include("unknown skill \"nope\"")
        expect(mock_provider.call_count).to eq(0)
      end
    end

    it "/quit winds down through the same path as bare quit -- the next line is never read" do
      Dir.mktmpdir do |dir|
        output = run_chat("/quit\nnever dispatched\n", dir:)

        expect(mock_provider.call_count).to eq(0)
        expect(output).not_to include("hello from the mock")
      end
    end
  end

  # T9: what a command may hand the Repl back. A String stays a first-class
  # return forever; a {Lain::Renderable} is the second, structured one. Driven
  # through the PUBLIC #converse (a conductor whose next read is nil ends the
  # loop), never a send(:settle_command) -- the same no-ivar-pokes discipline
  # the round trip above keeps.
  describe "what a command returns" do
    let(:colored) { Pastel.new(enabled: true) }
    let(:conductor) { instance_double(Lain::CLI::Conductor, read_prompt: nil, closed?: false) }

    def tty_over(output, enabled:, dir:)
      pastel = Pastel.new(enabled:)
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new, pastel:,
                              theme: Lain::Frontend::Theme.new(pastel:, detect: -> { 256 }),
                              history_path: File.join(dir, "history"))
    end

    def settle(outcome, tty:)
      commands = Struct.new(:outcome) do
        def dispatch(_text) = outcome
      end.new(outcome)
      Lain::CLI::Repl.new(agent: instance_double(Lain::Agent, timeline: nil), tty:,
                          replies: instance_double(Lain::CLI::HumanReplies), commands:,
                          chronicle: Lain::CLI::Chronicle::Null.new, conductor:)
                     .converse(first_prompt: "/anything")
    end

    def settled_output(outcome, enabled: true)
      Dir.mktmpdir do |dir|
        output = StringIO.new
        settle(outcome, tty: tty_over(output, enabled:, dir:))
        output.string
      end
    end

    it "renders a renderable's named segment in the theme's own style for that token" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm)).to include(colored.green("warm"))
    end

    it "leaves the surrounding text out of that segment's colour" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm)).to include("cache #{colored.green("warm")}")
    end

    it "still delivers a plain String exactly as it does today" do
      expect(settled_output("just words")).to include(colored.cyan("just words"))
    end

    it "ends the conversation on :quit -- the next prompt is never read" do
      Dir.mktmpdir do |dir|
        settle(:quit, tty: tty_over(StringIO.new, enabled: false, dir:))

        expect(conductor).not_to have_received(:read_prompt)
      end
    end

    it "names an unrecognised return loudly, and recoverably" do
      expect(settled_output(42, enabled: false)).to include("error:", "42")
    end

    it "names the COMMAND in that breach, not only what it returned" do
      expect(settled_output(42, enabled: false)).to include("command /anything returned")
    end

    it "carries no ANSI escapes when the stream is not a terminal" do
      warm = Lain::Renderable.new.plain("cache ").with(:warm, "warm")

      expect(settled_output(warm, enabled: false)).not_to include("\e[")
    end
  end

  # T33: the editor's gesture rail is consumed for the SESSION, not for one ask.
  # A code review is a long stretch of reading and marking with no model turns
  # in it at all, and the sidebar deliberately draws no glyph for a mark
  # ({Lain::Review::Surface::Neovim}'s class doc says why it cannot) -- so the
  # sentence that comes back on the rail is the ONLY signal a gesture landed.
  # The sole consumer of every editor verb used to be started and stopped by
  # #respond, which made its lifetime exactly one ask: measured live on
  # 2026-08-05, `x` on a sidebar row at an idle `you>` produced nothing for 8
  # seconds and the whole backlog then flushed at once the moment a message was
  # sent.
  #
  # Every example here drives the REAL #run -- its Sync, its ensure -- with the
  # real HumanReplies and its real fibers. The human sits idle inside
  # `read_prompt`, which is exactly where the defect lives: no ask is in flight,
  # so nothing #respond starts is running.
  describe "the editor gesture rail's lifetime" do
    let(:rail) { ReplEditorRail.new }
    let(:review) { ReplChangesetReview.new }
    let(:conductor) { instance_double(Lain::CLI::Conductor, closed?: false) }
    let(:agent) { instance_double(Lain::Agent, timeline: nil) }
    let(:commands) { Struct.new(:nothing) { def dispatch(_text) = nil }.new(nil) }
    let(:mark) { ["review_mark", [3, "reviewed", 7]] }
    # Doubled so these examples are about the GESTURE RAIL alone -- the fleet's
    # reactor is a second lifetime {Repl::ConversationScope} opens beside it.
    # The double once stood in for a real gap: {Lain::Supervisor::Null} answered
    # neither `run` nor `stop`, so {Repl}'s own default could not survive the
    # conversation's first line. It answers both since T35, and the last example
    # in this group drives that default instead of this double.
    let(:supervisor) { instance_double(Lain::Supervisor, run: nil, stop: nil) }

    def tty_for(dir)
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new, input: StringIO.new,
                              history_path: File.join(dir, "history"))
    end

    def repl_over(tty)
      replies = Lain::CLI::HumanReplies.new(tty:, conductor:, questions: Async::Queue.new,
                                            ask_human: instance_double(Lain::Tools::AskHuman::Directory))
      replies.bind_editor(rail)
      replies.bind_changeset_review(review)
      Lain::CLI::Repl.new(agent:, tty:, replies: AttachedReplies.new(replies), commands:, supervisor:,
                          chronicle: Lain::CLI::Chronicle::Null.new, conductor:)
    end

    # `nvim: nil` takes {Repl#attach_editor}'s no-editor branch; `store:`/
    # `session:` are that branch's unused arguments. Bounded, because an
    # unstopped consumer would hold the session's Sync open forever and a hung
    # suite says nothing.
    def run_idling(dir, &at_prompt)
      allow(conductor).to receive(:read_prompt, &at_prompt)
      Timeout.timeout(10) { repl_over(tty_for(dir)).run(nvim: nil, store: nil, session: nil) }
    end

    # THE REGRESSION. Nothing but the prompt read is running: no ask, no
    # #respond, no surface #respond starts. The gesture must still be answered.
    it "answers a gesture that arrives while the human sits idle at you>, with no ask in flight" do
      Dir.mktmpdir do |dir|
        run_idling(dir) do
          rail.push(mark)
          wait_until(reason: "the idle gesture reached the changeset review") { review.gestures.any? }
          "quit"
        end

        expect(review.gestures).to contain_exactly([:mark, 3, "reviewed", 7])
      end
    end

    # The other half of the same fact: the answer goes back out on the rail the
    # gesture came from, which is the human's only signal at `you>`.
    it "reports an idle gesture the review could not answer back in the editor" do
      Dir.mktmpdir do |dir|
        run_idling(dir) do
          rail.push(["open", [4, 2]]) # no views are bound, so this one cannot land
          wait_until(reason: "the refusal reached the editor") { rail.refusals.any? }
          "quit"
        end

        expect(rail.refusals).to contain_exactly(a_string_matching(/no editor is attached/))
      end
    end

    # Teardown, asserted MECHANICALLY: a Sync cannot return while a child task
    # is still running, so #run returning at all is the proof that the consumer
    # was stopped. The bound on `run_idling` is what turns "never stopped" into
    # a failing example rather than a hung suite.
    it "stops that consumer when the conversation ends, so the session's Sync can return" do
      Dir.mktmpdir do |dir|
        run_idling(dir) do
          rail.push(mark)
          wait_until(reason: "the idle gesture reached the changeset review") { review.gestures.any? }
          "quit"
        end

        rail.push(["review_mark", [9, "unreviewed", 7]])
        sleep(0.2)
        expect(review.gestures.size).to eq(1) # nothing is left parked on the rail
      end
    end

    # Every #respond ensure stops what it started; the session scope owes the
    # same on EVERY exit, and a raise climbing out of the conversation is the
    # one an ensure is for.
    it "stops it when a Lain::Error tears the conversation down" do
      Dir.mktmpdir do |dir|
        expect do
          run_idling(dir) do
            rail.push(mark)
            wait_until(reason: "the idle gesture reached the changeset review") { review.gestures.any? }
            raise Lain::Error, "torn at the prompt"
          end
        end.to raise_error(Lain::Error, "torn at the prompt")
      end
    end

    # An interrupt at the prompt is not a StandardError, so it climbs past every
    # rescue in the repl -- and the consumer must still be stopped, or the
    # process ends holding a fiber the reactor is still waiting on.
    it "stops it when an Interrupt lands at the prompt" do
      Dir.mktmpdir do |dir|
        expect do
          run_idling(dir) do
            rail.push(mark)
            wait_until(reason: "the idle gesture reached the changeset review") { review.gestures.any? }
            raise Interrupt
          end
        end.to raise_error(Interrupt)
      end
    end

    # The /quit command's action, which leaves through {Repl#next_text} rather
    # than through farewell?: a different exit, the same ensure.
    it "stops it when a command ends the conversation with :quit" do
      Dir.mktmpdir do |dir|
        allow(commands).to receive(:dispatch).and_return(:quit)
        run_idling(dir) do
          rail.push(mark)
          wait_until(reason: "the idle gesture reached the changeset review") { review.gestures.any? }
          "/quit"
        end

        rail.push(["review_mark", [9, "unreviewed", 7]])
        sleep(0.2)
        expect(review.gestures.size).to eq(1)
      end
    end

    # T35, and the only example in the file that omits `supervisor:`. A default
    # nothing ever exercises is a default nobody knows is broken: this one was,
    # for as long as {Lain::Supervisor::Null} answered five of the duck's seven
    # messages, and it stayed invisible because {CLI::Wiring} passes a real
    # supervisor on every production path and every spec passed a double.
    #
    # Driven through the REAL {Repl#run}, not by sending `run` to the module: a
    # conversation opens the lifetime and closes it, and the failure this pins
    # was the very first line of the opening.
    it "converses on its own default supervisor when a caller wires none" do
      Dir.mktmpdir do |dir|
        replies = Lain::CLI::HumanReplies.new(tty: tty_for(dir), conductor:, questions: Async::Queue.new,
                                              ask_human: instance_double(Lain::Tools::AskHuman::Directory))
        repl = described_class.new(agent:, tty: tty_for(dir), replies: AttachedReplies.new(replies),
                                   commands:, chronicle: Lain::CLI::Chronicle::Null.new, conductor:)
        allow(conductor).to receive(:read_prompt).and_return("quit")

        expect { Timeout.timeout(10) { repl.run(nvim: nil, store: nil, session: nil) } }.not_to raise_error
      end
    end
  end
end
