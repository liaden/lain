# frozen_string_literal: true

require "async"
require "delegate"
require "fileutils"
require "json"
require "pastel"
require "pty"
require "rbconfig"
require "stringio"
require "tempfile"
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

# The ask_human reply seam as {Lain::CLI::HumanReplies} routes an answer through
# it, with the pair each answer was delivered as recorded. A real object rather
# than an instance_double because the question these examples ask is whether any
# fiber was alive to route an answer at all -- a double would answer that by
# construction.
class ReplRecordedAnswers
  def initialize = @answered = []

  attr_reader :answered

  def reply(answer, digest) = @answered << [answer, digest]
end

# The real {Lain::CLI::HumanReplies} with an editor ALREADY attached. {Repl#run}
# binds the frontend it builds, and an example with no nvim to build one from
# would have its rail overwritten by that bind -- so the two binds are refused
# here and everything else is the production object, running production fibers.
class AttachedReplies < SimpleDelegator
  def bind_editor(*, **) = nil
  def bind_review_editor(_editor) = nil
end

# A provider with a BUG in it, for the "a crash is not a refusal" example. Not
# a tool that raises: `Effect::Handler::Live#dispatch` contains those as
# `Tool::Result.error` (correctness gate 3), so a tool cannot crash an ask by
# design. The provider is the nearest thing to a real bug that reaches one.
class ExplodingProvider < Lain::Provider::Mock
  def complete(_request) = raise(TypeError, "genuinely broken")
end

# An endpoint with nothing behind it, for the headless exit-status examples.
# What a live run gets is Lain's OWN error -- Provider::Ollama::APIError, rooted
# at Lain::Error by ErrorWrapping -- which {Lain::CLI::Repl::Ask} deliberately
# carries out of the ask as a VALUE. So the conversation ends cleanly, the
# refusal is rendered in one line, and the exit status is the only place the
# failure can still be read.
class UnreachableProvider < Lain::Provider::Mock
  def complete(_request, **) = raise(Lain::Provider::Ollama::APIError, "nothing is listening on 127.0.0.1:11434")
end

# A chat with a standing goal over a PTY, the far end of which is the human. The
# child runs a real Repl, TTY, Conductor, HumanReplies, GoalDriver and `/goal`;
# the one fake is the command registry's fallthrough, which answers each driven
# prompt by printing `ITERATION n` and waiting until the spec lets it finish --
# so what is typed "during an iteration" is typed while nothing reads stdin.
# The `approval` shape parks one gated call in the second iteration.
class ReplGoalTerminal
  CHILD = <<~'RUBY'
    require "lain"

    dir, shape, cap, = ARGV
    journal = Lain::Journal.new(io: File.open(File.join(dir, "journal.ndjson"), "a").tap { |io| io.sync = true })
    queue = Lain::Approval::Queue.new(journal:, timeout: 30)
    tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, pastel: Pastel.new(enabled: false),
                                  history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
    conductor = Lain::CLI::Conductor.new(tty:, chronicle: Lain::CLI::Chronicle::Null.new,
                                         signals: Lain::CLI::Signals.new, grace: 5)
    askers = Lain::CLI::Wiring::Askers.new(observer: Lain::Event::ChainWriter::Null.new)
    replies = Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human: askers.directory, questions: askers.questions)
    driver = Lain::CLI::GoalDriver.new(journal:, cap: Integer(cap))
    agent = Struct.new(:timeline, :session).new(Lain::Timeline.empty, Lain::Session::Null.instance)

    commands = Class.new do
      def initialize(dir, shape, goal, env, queue)
        @dir = dir
        @shape = shape
        @goal = goal
        @env = env
        @queue = queue
        @iteration = 0
      end

      def serves_replies?(_text) = false

      def dispatch(text)
        File.write(File.join(@dir, "dispatched"), "#{text}\n", mode: "a")
        return @goal.call(text.delete_prefix("/goal"), @env) if text.start_with?("/goal")
        return unless text.start_with?("Standing goal")

        iterate(@iteration += 1)
      end

      def iterate(iteration)
        $stdout.write("ITERATION #{iteration}\n")
        Async::Task.current.sleep(0.02) until File.exist?(File.join(@dir, "finish-#{iteration}"))
        park if @shape == "approval" && iteration == 2
        nil
      end

      def park
        @queue.call(Lain::Effect::ToolCall.new(tool_use_id: "call_1", name: "bash",
                                               input: { "command" => "rm -rf build" }), nil)
      end
    end.new(dir, shape, Lain::CLI::Command::Goal.new(driver:), Struct.new(:agent).new(agent), queue)

    Sync do
      Lain::CLI::Repl.new(agent:, tty:, replies:, commands:, chronicle: Lain::CLI::Chronicle::Null.new, conductor:,
                          approvals: queue, goal_driver: driver)
                     .converse(first_prompt: "/goal make the specs green")
    end
  RUBY

  LIB = File.expand_path("../../../lib", __dir__)
  CURSOR_QUERY = "\e[6n"
  CURSOR_REPORT = "\e[1;1R"

  def initialize(dir, shape:, cap:, term:)
    @dir = dir
    @screen = +""
    @lock = Mutex.new
    env = { "TERM" => term, "INPUTRC" => File.join(dir, "no-inputrc") }
    @output, @input, @pid = PTY.spawn(env, RbConfig.ruby, "-I", LIB, "-e", CHILD, dir, shape, cap.to_s)
    @output.winsize = [40, 200]
    @pump = Thread.new { pump }
  end

  def screen = @lock.synchronize { @screen.dup }

  def type(bytes) = @input.write(bytes)

  def finish(iteration) = FileUtils.touch(File.join(@dir, "finish-#{iteration}"))

  def await(pattern, timeout: 20)
    waited_for(timeout) { screen.match?(pattern) }
    raise "#{pattern.inspect} never drew; the screen was:\n#{screen}" unless screen.match?(pattern)
  end

  def await_dispatched(line, timeout: 20)
    waited_for(timeout) { dispatched.include?(line) }
    raise "#{line.inspect} was never dispatched: #{dispatched.inspect}\n#{screen}" unless dispatched.include?(line)
  end

  def iterations = records("goal_iteration").count

  def verdicts = records("approval_decision").map { |record| record.values_at("surface", "verdict") }

  def dispatched
    path = File.join(@dir, "dispatched")
    File.exist?(path) ? File.readlines(path, chomp: true) : []
  end

  def close
    Process.kill("KILL", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pump.join(2)
    [@input, @output].each { |io| io.close unless io.closed? }
  end

  private

  def waited_for(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.02) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def records(type)
    path = File.join(@dir, "journal.ndjson")
    File.exist?(path) ? Lain::Journal.records(File.readlines(path), type:).to_a : []
  end

  # A real terminal answers Reline's cursor-position query; left unanswered,
  # every read waits out Reline's half-second timeout first.
  def pump
    loop do
      chunk = @output.readpartial(4096)
      @lock.synchronize { @screen << chunk }
      @input.write(CURSOR_REPORT) if chunk.include?(CURSOR_QUERY)
    end
  rescue IOError, Errno::EIO
    nil
  end
end

RSpec.describe Lain::CLI::Repl do
  # The AC round trip: a Provider::Mock, a Channel, and a Frontend::TTY over
  # StringIO stand in for the live edges; the Repl is constructed AND run
  # through Lain::CLI::Wiring#run -- the exe's own assembly path, minus the exe
  # -- via the injected tty seam (no send(:build_repl), no ivar pokes).
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

  # A tool turn primes the chat's snapshot slot, and the default posture keeps
  # its shadow store under the state home -- so each chat gets a throwaway one.
  def spec_state(dir) = Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir })

  def run_chat(input, dir:, chronicle: Lain::CLI::Chronicle::Null.new, options: { grace: 5 })
    output = StringIO.new
    # `**` swallows the `prompt_renderer:` keyword -- this spec is about the chat
    # round trip, and its StringIO input never reaches the composing path.
    tty_factory = lambda do |channel:, **|
      Lain::Frontend::TTY.new(channel:, output:, input: StringIO.new(input),
                              history_path: File.join(dir, "history"))
    end
    wiring = Lain::CLI::Wiring.new(options:, chronicle:, tty_factory:, paths: spec_state(dir),
                                   status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    wiring.run(backend:, resumed: nil, nvim: nil)
    wiring.conductor.close(reason: :exit)
    output.string
  end

  # The headless arm. `--non-interactive` is what makes a chat honest about a
  # machine at the other end: it runs the seeded question and stops, it never
  # reads a line nobody is there to type, and what it could not finish comes
  # back as an exit status instead of as a clean 0 over a rendered refusal
  # (round 7). `--prompt` is untouched by it -- that flag still seeds and
  # still continues, which is what the `/btw` child chat depends on.
  #
  # Driven through the real Wiring#run, like the round trip below it: the whole
  # question here is what an assembled chat does with a terminal nobody is at,
  # and a doubled Repl would answer that by construction.
  describe "a conversation with no human at the other end" do
    # Every example leaves a SECOND line sitting in stdin. An attended chat
    # takes it; a headless one must not, so its absence from the record is what
    # the reading-again example asserts on. The timeout is the "does not block"
    # half of the ask_human criterion -- a parked question would hang here
    # rather than fail.
    def waiting_terminal(output, dir:)
      lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output:, input: StringIO.new("and another thing\n"),
                                history_path: File.join(dir, "history"))
      end
    end

    def run_headless(prompt, dir:, provider: mock_provider)
      output = StringIO.new
      headless = offline_backend_class.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock: provider)
      wiring = Lain::CLI::Wiring.new(options: { grace: 5, prompt:, non_interactive: true },
                                     chronicle: Lain::CLI::Chronicle::Null.new,
                                     tty_factory: waiting_terminal(output, dir:), paths: spec_state(dir),
                                     status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
      Timeout.timeout(20) { wiring.run(backend: headless, resumed: nil, nvim: nil) }
      wiring.conductor.close(reason: :exit)
      [wiring, output.string]
    end

    # Never calls downstream and never sets :response -- the contract breach
    # {Lain::CLI::Repl#render_missing_response} exists to name.
    def silent_middleware
      Lain::Middleware::Stack.new([Class.new(Lain::Middleware::Base) do
        def call(env, &_app) = env
      end.new])
    end

    # A conductor whose prompt never answers ends the loop after one line, the
    # same way an unattended one does -- so this drives the fault and nothing
    # else. `attended: false` keeps it honest about which arm is under test.
    # A command surface that claims nothing, so every line falls through to the
    # middleware phase -- which is the phase under test.
    def falls_through
      Struct.new(:nothing) do
        def dispatch(_text) = yield
        def serves_replies?(_text) = false
      end.new(nil)
    end

    def repl_over_middleware(middleware, output:, dir:)
      Lain::CLI::Repl.new(
        agent: instance_double(Lain::Agent, timeline: nil), middleware:, attended: false,
        commands: falls_through, chronicle: Lain::CLI::Chronicle::Null.new,
        tty: Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                                     history_path: File.join(dir, "history")),
        replies: instance_double(Lain::CLI::HumanReplies, surfaces: []), conductor: passing_conductor
      )
    end

    # Every middleware line is supervised now, so the double runs the block it
    # is handed and answers the Outcome the real one would for a clean line.
    def passing_conductor
      instance_double(Lain::CLI::Conductor, closed?: false).tap do |conductor|
        allow(conductor).to receive(:supervise) do |*, &line|
          Lain::CLI::Conductor::Outcome.new(response: line.call, closed: false)
        end
      end
    end

    def stopping_at(stop_reason)
      Lain::Provider::Mock.new(responses: [
                                 Lain::Response.new(content: [{ "type" => "text", "text" => "half a sen" }],
                                                    stop_reason:)
                               ])
    end

    # The tool's own answer off the committed timeline, which is where a
    # refusal the model was shown has to be if it was shown at all.
    def tool_results(agent)
      agent.timeline.to_a.map(&:content).grep(Array).flatten.grep(Hash)
           .select { |block| block["type"] == "tool_result" }.map { |block| block["content"] }.join("\n")
    end

    it "exits zero when the ask completed" do
      Dir.mktmpdir do |dir|
        wiring, output = run_headless("hello?", dir:)

        expect(output).to include("hello from the mock")
        expect(wiring.exit_status).to eq(0)
      end
    end

    it "reads no second line: the question it was given is the whole conversation" do
      Dir.mktmpdir do |dir|
        run_headless("hello?", dir:)

        expect(mock_provider.call_count).to eq(1)
      end
    end

    it "reports a turn that could not finish in the exit status" do
      Dir.mktmpdir do |dir|
        wiring, output = run_headless("hello?", dir:, provider: UnreachableProvider.new)

        expect(output).to include("nothing is listening")
        expect(wiring.exit_status).not_to eq(0)
      end
    end

    # A refusal is the obvious torn turn and not the only one. These two render
    # text -- an attended human SEES the half-sentence and the decline -- so
    # they used to exit 0 and tell a script the run was clean, which is the one
    # thing this flag exists to stop. The rules live on {Repl::Outcome} and are
    # spec'd exhaustively there; these two go through the real Wiring, because
    # a rule nothing consults is worth nothing.
    it "reports an answer cut off at max_tokens, though the words reached the terminal" do
      Dir.mktmpdir do |dir|
        wiring, output = run_headless("hello?", dir:, provider: stopping_at(:max_tokens))

        expect(output).to include("half a sen")
        expect(wiring.exit_status).not_to eq(0)
      end
    end

    it "reports the model refusing" do
      Dir.mktmpdir do |dir|
        wiring, = run_headless("hello?", dir:, provider: stopping_at(:refusal))

        expect(wiring.exit_status).not_to eq(0)
      end
    end

    # The third torn shape, and the only one with no VALUE to describe it: a
    # middleware that short-circuits without setting :response. repl.rb calls
    # that a bug in its own words and renders it loudly -- so it must not also
    # report a clean run. Built directly rather than through Wiring because the
    # repl phase is assembled from the command surface there, and this fault is
    # a middleware's, not a command's.
    it "reports a middleware that broke its own contract, which it already names loudly" do
      Dir.mktmpdir do |dir|
        output = StringIO.new
        repl = repl_over_middleware(silent_middleware, output:, dir:)

        repl.converse(first_prompt: "hello?")

        expect(output.string).to include("short-circuited without setting :response")
        expect(repl.exit_status).not_to eq(0)
      end
    end

    describe "when the model asks the human anyway" do
      let(:asking_provider) do
        Lain::Provider::Mock.new(responses: [
                                   Lain::Response.new(
                                     content: [{ "type" => "tool_use", "id" => "tu_ask", "name" => "ask_human",
                                                 "input" => { "question" => "which branch?" } }],
                                     stop_reason: :tool_use
                                   ),
                                   Lain::Response.new(content: [{ "type" => "text", "text" => "settled alone" }],
                                                      stop_reason: :end_turn)
                                 ])
      end

      it "refuses by name rather than parking on a reply nobody will type" do
        Dir.mktmpdir do |dir|
          wiring, = run_headless("ask me something", dir:, provider: asking_provider)

          expect(tool_results(wiring.command_env.agent)).to include("ask_human", "no human")
        end
      end

      it "lets the turn carry on to its own conclusion" do
        Dir.mktmpdir do |dir|
          _wiring, output = run_headless("ask me something", dir:, provider: asking_provider)

          expect(output).to include("settled alone")
        end
      end
    end
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

  # The ONE line in any process that puts an editor's review rig within a
  # tool's reach. Everything downstream of it -- the changeset drawn in nvim, the
  # sidebar gestures, the verdict a `:w` writes -- is unreachable without it, and
  # nothing else in the suite runs `Repl#run` with an editor attached at all.
  #
  # A REAL headless editor, because the seam is exactly the attach: `nvim: nil`
  # takes the other branch of `attach_editor` and would prove nothing about it.
  describe "the editor a changeset review is drawn in", :nvim, :seam do
    around { |example| headless_editor("lain-repl-review-spec") { example.run } }

    def editor_wiring(tty_factory, dir)
      Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new, tty_factory:,
                            paths: spec_state(dir), status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    end

    def chat_with_editor(dir)
      tty_factory = lambda do |channel:, **|
        Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new("quit\n"),
                                history_path: File.join(dir, "history"))
      end
      wiring = editor_wiring(tty_factory, dir)
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

  # What a command may hand the Repl back. A String stays a first-class
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
      # The command surface's duck is two messages now: the Repl asks
      # whether the LINE is itself a reply surface before it brackets it.
      commands = Struct.new(:outcome) do
        def dispatch(_text) = outcome
        def serves_replies?(_text) = false
      end.new(outcome)
      # `surfaces: []` because the reply surfaces are bracketed around the whole
      # DISPATCHED LINE now, not around the ask -- so a command that never
      # reaches #respond still asks this collaborator for them.
      Lain::CLI::Repl.new(agent: instance_double(Lain::Agent, timeline: nil), tty:,
                          replies: instance_double(Lain::CLI::HumanReplies, surfaces: [], take_held: nil), commands:,
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

  # A line a cockpit's command reader HELD while a line dispatched is the
  # human's next prompt: it was typed before anything that could come after the
  # line settles, so it is dispatched before the goal driver is asked and
  # before `you>` is read again.
  describe "a held line" do
    let(:conductor) { instance_double(Lain::CLI::Conductor, closed?: false, read_prompt: "quit") }
    let(:replies) do
      Lain::CLI::HumanReplies.new(tty: Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new,
                                                               input: StringIO.new, history_path: File::NULL),
                                  conductor:, questions: Async::Queue.new, ask_human: ReplRecordedAnswers.new)
    end
    let(:dispatched) { [] }
    # The first line holds what the human typed during it, exactly as the
    # command reader does; every line is recorded as it is dispatched.
    let(:commands) do
      Struct.new(:dispatched, :replies) do
        def dispatch(text)
          dispatched << text
          replies.hold("yes please") if dispatched.one?
          nil
        end

        def serves_replies?(_text) = false
      end.new(dispatched, replies)
    end

    # The Repl's own terminal is a double with nothing allowed, so a sweep of
    # typeahead where no goal stands -- where `you>` reads it as typed -- fails.
    def converse_with(goal_driver: Lain::CLI::GoalDriver::Null, tty: instance_double(Lain::Frontend::TTY))
      described_class.new(agent: instance_double(Lain::Agent, timeline: nil), tty:,
                          replies:, commands:, chronicle: Lain::CLI::Chronicle::Null.new, conductor:, goal_driver:)
                     .converse(first_prompt: "run the tests")
    end

    it "dispatches the held line as the next prompt, before you> is read" do
      converse_with

      expect(dispatched).to eq(["run the tests", "yes please"])
      expect(conductor).to have_received(:read_prompt).once
    end

    it "dispatches it ahead of a standing goal's next prompt" do
      goal_driver = instance_double(Lain::CLI::GoalDriver, poll: nil, active?: true, settle_pin: nil)
      allow(goal_driver).to receive(:poll).and_return("keep going", nil)

      converse_with(goal_driver:, tty: instance_double(Lain::Frontend::TTY, hold_typed_ahead: nil))

      expect(dispatched).to eq(["run the tests", "yes please", "keep going"])
    end
  end

  # A standing goal answers the next prompt itself, so `you>` never reads while
  # it drives and a `/goal off` typed meanwhile waited in the terminal until the
  # cap. Between iterations the Repl asks the terminal for what was typed, and
  # a whole line runs before the driver is polled again.
  describe "a line typed while a standing goal drives" do
    let(:journal_io) { StringIO.new }
    let(:driver) { Lain::CLI::GoalDriver.new(journal: Lain::Journal.new(io: journal_io)) }
    let(:output) { StringIO.new }
    let(:conductor) { instance_double(Lain::CLI::Conductor, closed?: false, read_prompt: "quit") }
    let(:session) { Lain::Session.new }
    let(:agent) { Struct.new(:timeline, :session).new(Lain::Timeline.empty, session) }
    let(:dispatched) { [] }
    let(:stop_after) { 2 }
    # A terminal the human types `/goal off` into once `stop_after` iterations
    # have run: what the sweep finds there is held exactly as a real drain holds it.
    let(:tty) do
      lines = dispatched
      after = stop_after
      typed = -> { lines.count { |line| line.start_with?("Standing goal") } == after && !lines.include?("/goal off") }
      Class.new(SimpleDelegator) do
        define_method(:hold_typed_ahead) { typed.call ? hold("/goal off") : nil }
      end.new(Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new,
                                      history_path: File::NULL, pastel: Pastel.new(enabled: false)))
    end
    let(:replies) do
      Lain::CLI::HumanReplies.new(tty:, conductor:, questions: Async::Queue.new, ask_human: ReplRecordedAnswers.new)
    end
    let(:commands) do
      goal = Lain::CLI::Command::Goal.new(driver:)
      env = Struct.new(:agent).new(agent)
      # A driven prompt is committed with a reply, as the ask would commit it.
      Struct.new(:dispatched) do
        define_method(:dispatch) do |text|
          dispatched << text
          return goal.call(text.delete_prefix("/goal"), env) if text.start_with?("/goal")

          env.agent.timeline = env.agent.timeline.commit(role: :user, content: [{ "type" => "text", "text" => text }])
                                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "working" }])
          nil
        end

        def serves_replies?(_text) = false
      end.new(dispatched)
    end

    def records(type) = Lain::Journal.records(journal_io.string.lines, type:).to_a

    def iterations = records("goal_iteration").count

    def converse
      described_class.new(agent:, tty:, replies:, commands:, chronicle: Lain::CLI::Chronicle::Null.new, conductor:,
                          goal_driver: driver).converse(first_prompt: "/goal make the specs green")
    end

    it "runs a /goal off typed during the second iteration before a third is driven" do
      converse

      expect(iterations).to eq(2)
      expect(dispatched.last).to eq("/goal off")
      expect(output.string).to include("stopped")
    end

    # The objective's pin settles on the driver's look at the timeline, and a
    # held `/goal off` now runs before the driver is polled -- so the look comes
    # first, or a stop after the first iteration leaves the objective unpinned
    # and journals that it went unprotected.
    context "when /goal off is typed during the first iteration" do
      let(:stop_after) { 1 }

      it "pins the objective before the stop, and journals no miss" do
        converse

        expect(iterations).to eq(1)
        expect(session.pins.size).to eq(1)
        expect(records("goal_pin_missed")).to be_empty
      end
    end
  end

  # The goal layer and `:LainGoalOff` through the chat the exe assembles.
  describe "a standing goal, wired" do
    let(:mock_provider) do
      Lain::Provider::Mock.new(responses: [text_response("all done -- #{Lain::CLI::GoalDriver::DONE}")])
    end

    it "refuses /mode +goal with no standing goal, naming how to set one" do
      Dir.mktmpdir do |dir|
        expect(run_chat("/mode +goal\nquit\n", dir:)).to include("/goal <objective>")
      end
    end

    it "raises the goal layer for the goal's drive and lowers it when the agent signals done" do
      journal_io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "repl-goal.ndjson")

      Dir.mktmpdir { |dir| run_chat("/goal ship it\nquit\n", dir:, chronicle:) }

      flips = Lain::Journal.records(journal_io.string.lines, type: "mode_switch").select { |r| r["surface"] == "goal" }
      expect(flips.map { |flip| flip["to_layers"] }.to_a).to eq([["goal"], []])
    end

    it "hands the editor's goal_off verb to the driver the chat polls" do
      Dir.mktmpdir do |dir|
        tty_factory = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output: StringIO.new, input: StringIO.new("quit\n"),
                                  history_path: File.join(dir, "history"))
        end
        wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new, tty_factory:,
                                       paths: spec_state(dir),
                                       status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
        wiring.run(backend:, resumed: nil, nvim: nil)
        driver = wiring.command_surface.goal_driver
        driver.start("ship it")

        wiring.command_env.replies.send(:routes).fetch("goal_off").call([])
        wiring.conductor.close(reason: :exit)

        expect(driver).not_to be_active
      end
    end
  end

  # The same drive over a REAL terminal, in a child process for the reason
  # {PlainChatPromptGuards} gives: Reline picks its terminal gate once, from the
  # process's own stdin, and typeahead only exists in a kernel's tty buffer.
  describe "a standing goal over a real terminal", :seam do
    around do |example|
      Dir.mktmpdir do |dir|
        @terminal = ReplGoalTerminal.new(dir, shape:, cap:, term:)
        example.run
      ensure
        @terminal&.close
      end
    end

    let(:shape) { "plain" }
    let(:cap) { 5 }
    let(:term) { "xterm" }
    let(:terminal) { @terminal }

    # Typed while iteration `n` runs, which then finishes.
    def typed_during(iteration, bytes)
      terminal.await(/ITERATION #{iteration}\b/)
      terminal.type(bytes)
      sleep(0.2)
      terminal.finish(iteration)
    end

    it "stops before a third iteration when /goal off is typed during the second" do
      terminal.await(/ITERATION 1\b/)
      terminal.finish(1)
      typed_during(2, "/goal off\r")
      terminal.await(/you> /)

      expect(terminal.iterations).to eq(2)
      expect(terminal.screen).to include("the driver stopped")
      expect(terminal.screen).not_to include("ITERATION 3")
    end

    it "keeps a line begun in one iteration and finished in the next, and runs it whole" do
      terminal.await(/ITERATION 1\b/)
      terminal.finish(1)
      typed_during(2, "/goal o")
      typed_during(3, "ff\r")
      terminal.await(/you> /)

      expect(terminal.iterations).to eq(3)
      expect(terminal.dispatched).to include("/goal off")
    end

    context "when the goal ends with a line still unfinished" do
      let(:cap) { 1 }

      it "leaves the unfinished line for you>, where the human finishes it" do
        typed_during(1, "hel")
        terminal.await(/you> /)
        terminal.type("lo\r")
        terminal.await_dispatched("hello")

        expect(terminal.dispatched.last).to eq("hello")
      end

      context "with a dumb terminal" do
        let(:term) { "dumb" }

        it "still leaves it for you>" do
          typed_during(1, "hel")
          terminal.await(/you> /)
          terminal.type("lo\r")
          terminal.await_dispatched("hello")

          expect(terminal.dispatched.last).to eq("hello")
        end
      end
    end

    # `/goal off` typed AT the drawn `[y/N]` the second iteration parks: it was
    # meant for the chat, so it decides nothing -- the prompt asks again, the
    # `n` denies, and the held line runs before a third iteration.
    context "when the second iteration parks an approval" do
      let(:shape) { "approval" }

      def goal_off_at_the_drawn_prompt
        terminal.await(/ITERATION 1\b/)
        terminal.finish(1)
        terminal.await(/ITERATION 2\b/)
        terminal.finish(2)
        terminal.await(%r{\[y/N\] })
        sleep(0.3)
        terminal.type("/goal off\r")
        terminal.await(%r{held as your next prompt: /goal off})
        sleep(0.5)
      end

      def answered_n
        undecided = terminal.verdicts
        terminal.type("n\r")
        terminal.await(/you> /)
        undecided
      end

      it "decides nothing on the /goal off, denies on the n, and drives no third iteration" do
        goal_off_at_the_drawn_prompt

        expect(answered_n).to be_empty
        expect(terminal.verdicts).to eq([%w[tty deny]])
        expect(terminal.iterations).to eq(2)
        expect(terminal.dispatched.last).to eq("/goal off")
      end

      context "with a dumb terminal" do
        let(:term) { "dumb" }

        it "decides nothing on the /goal off, denies on the n, and drives no third iteration" do
          goal_off_at_the_drawn_prompt

          expect(answered_n).to be_empty
          expect(terminal.verdicts).to eq([%w[tty deny]])
          expect(terminal.iterations).to eq(2)
        end
      end
    end
  end

  # The editor's gesture rail is consumed for the SESSION, not for one ask.
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
    let(:commands) do
      Struct.new(:nothing) do
        def dispatch(_text) = nil
        def serves_replies?(_text) = false
      end.new(nil)
    end
    let(:mark) { ["review_mark", [3, "reviewed", 7]] }
    # Doubled so these examples are about the GESTURE RAIL alone -- the fleet's
    # reactor is a second lifetime {Repl::ConversationScope} opens beside it.
    # The double once stood in for a real gap: {Lain::Supervisor::Null} answered
    # neither `run` nor `stop`, so {Repl}'s own default could not survive the
    # conversation's first line. It answers both now, and the last example
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

    # The only example in the file that omits `supervisor:`. A default
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

  # Manual-QA round 4. A budget ceiling is the HARNESS deciding to
  # halt ({Agent::Budget}'s class doc), and {Repl#respond} already renders it as
  # the one line a human needs: `error: loop ran 2 iterations, ceiling is 2`.
  # What the human actually met was that line preceded by
  # `Task may have ended with unhandled exception.` and the whole backtrace --
  # measured at ~2.6KB of stderr per refusal, against 226 bytes for a clean ask.
  #
  # THE MECHANISM, measured rather than guessed. `Async::Task#run` rescues its
  # block and logs `unless @promise.waiting?` (async-2.42.0/lib/async/task.rb:
  # 224-228), and `Conductor#supervise` spawns the run with `task.async(&block)`
  # -- which resumes the fiber EAGERLY -- then builds the shutdown, spawns the
  # coordinator and the ticker, and only THEN reaches `run.wait`. So a raise the
  # ask makes before the parent parks is a task that "ended with an unhandled
  # exception" as far as Async can tell, and it says so. It is not a race:
  # measured 5/5 identical, and on all four bust shapes tried (ceilings of 0, 2
  # and 4, and the token ceiling) the warning fires exactly once per refusal.
  #
  # THE FIX IS NOT TO SILENCE THE LOGGER, which would hide real crashes too: the
  # ask's refusal is carried OUT of the task as a value, so the task completes
  # and there is no unhandled exception to report. Anything that is not a
  # {Lain::Error} still raises inside the task and still gets Async's warning,
  # which is the behaviour we want to keep -- covered by the second example.
  #
  # STDERR IS CAPTURED BY REOPENING THE FD, not by assigning `$stderr`.
  # `Console` binds its output when its logger is first built, so a StringIO
  # assigned later is never consulted and the example would pass while the
  # warning still printed -- a false green, and one that only appears in a
  # whole-suite run where some earlier example built the logger first.
  describe "a budget refusal reaches the human as one line" do
    let(:looping) { tool_response(["tu_1", "echo", { "text" => "loop" }]) }
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

    # The ceiling that stops one ask driven into a tool loop -- the
    # reproduction an earlier card left standing, since the ceiling now bounds one ask.
    let(:ceiling) { Lain::Agent::Budget.new(max_iterations: 2) }
    let(:looping_thrice) { [looping] * 3 }

    # A whole conversation over ONE typed line, through the real {Repl#run} and
    # so through the real {Conductor#supervise} and its real `Async::Task`. That
    # task is the subject: nothing below the Repl is doubled.
    def converse_once(dir, responses, budget:, out: StringIO.new, provider: nil)
      agent = Lain::Agent.new(provider: provider || Lain::Provider::Mock.new(responses:), toolset:, context:, budget:)
      tty = tty_over(dir, out)
      described_class.new(agent:, tty:, replies: replies_over(tty, one_line_conductor(tty)),
                          commands: passthrough_commands, chronicle: Lain::CLI::Chronicle::Null.new,
                          conductor: one_line_conductor(tty))
                     .run(nvim: nil, store: nil, session: nil)
      out.string
    end

    def tty_over(dir, out)
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: out, input: StringIO.new,
                              history_path: File.join(dir, "history"))
    end

    # A real Conductor -- `supervise` is the subject -- that answers one prompt
    # and then EOF, so the conversation is exactly one ask long.
    def one_line_conductor(tty)
      @one_line_conductor ||= Lain::CLI::Conductor.new(tty:, chronicle: Lain::CLI::Chronicle::Null.new,
                                                       signals: Lain::CLI::Signals.new, grace: 5).tap do |conductor|
        asks = ["tell me"]
        conductor.define_singleton_method(:read_prompt) { |*| asks.shift }
      end
    end

    def replies_over(tty, conductor)
      Lain::CLI::HumanReplies.new(tty:, conductor:, questions: Async::Queue.new,
                                  ask_human: instance_double(Lain::Tools::AskHuman::Directory))
    end

    # {Command::Registry}'s duck for a line no command claims: it YIELDS, and
    # the block is the model turn. A fake returning nil instead swallows the ask
    # entirely and renders nothing -- which looks exactly like the defect and is
    # not it, as one draft of this spec found out.
    def passthrough_commands
      Struct.new(:nothing) do
        def dispatch(_text) = yield
        def serves_replies?(_text) = false
      end.new(nil)
    end

    # Reopens the FD rather than assigning `$stderr` -- see this group's doc.
    def stderr_during(&)
      saved = $stderr.dup
      Tempfile.create("lain-repl-stderr") { |file| capture_into(file, saved, &) }
    ensure
      saved&.close
    end

    # THE RESTORE IS IN AN `ensure`, and the block below is EXPECTED to raise --
    # the crash example lets a TypeError out on purpose. Restoring on the
    # success path only would leave fd 2 pointing at a tempfile that
    # `Tempfile.create` then deletes, for the rest of the process: in a `pspec`
    # worker that silently swallows every later stderr write, including the very
    # Async warnings this group exists to detect. That is this group's own
    # false-green class, one method further down.
    def capture_into(file, saved)
      $stderr.reopen(file)
      yield
      $stderr.flush
      File.read(file.path)
    ensure
      $stderr.reopen(saved)
    end

    it "renders the ceiling and the count on the terminal" do
      Dir.mktmpdir do |dir|
        rendered = nil
        stderr_during { rendered = converse_once(dir, looping_thrice, budget: ceiling) }

        expect(rendered).to include("error: loop ran 2 iterations, ceiling is 2")
      end
    end

    it "announces no unhandled exception, and prints no backtrace, for that refusal" do
      Dir.mktmpdir do |dir|
        noise = stderr_during { converse_once(dir, looping_thrice, budget: ceiling) }

        expect(noise).not_to include("Task may have ended with unhandled exception")
        expect(noise).not_to include("Budget::Exceeded")
        expect(noise).not_to include("lib/lain/agent.rb")
      end
    end

    # The wedge {Agent::Budget} guards is the harness halting; a BUG is not, and
    # telling them apart is the whole reason the fix carries the refusal out as
    # a value instead of silencing Async. So this drives the SAME path as the
    # two examples above -- real Repl, real {Conductor#supervise}, real
    # `Async::Task` -- and changes only what the ask raises.
    #
    # THE PROVIDER IS WHAT EXPLODES, and picking it took a correction. An
    # earlier draft raised from a TOOL and claimed a `RuntimeError`; it got a
    # `Budget::Exceeded` instead and proved nothing, because
    # `Effect::Handler::Live#dispatch` contains every tool raise as
    # `Tool::Result.error` (correctness gate 3) and `Provider::Mock` repeats its
    # LAST response forever (`mock.rb:67`) -- so the loop merely ran to the
    # default 25-iteration ceiling. A tool cannot crash an ask by design. The
    # provider is the nearest thing to a real bug that reaches one.
    #
    # BOTH HALVES ARE ASSERTED, and the second is the one with teeth: the
    # exception still ESCAPES the whole conversation. A rescue widened to
    # `StandardError` satisfies neither -- it would swallow the TypeError into a
    # rendered line, and the Async warning would never be logged at all.
    it "still lets a genuine crash terminate its task loudly" do
      Dir.mktmpdir do |dir|
        escaped = nil
        noise = stderr_during do
          converse_once(dir, [], budget: Lain::Agent::Budget.new, provider: ExplodingProvider.new(responses: []))
        rescue TypeError => e
          escaped = e
        end

        expect(escaped).to be_a(TypeError).and have_attributes(message: "genuinely broken")
        expect(noise).to include("Task may have ended with unhandled exception")
      end
    end
  end

  # The reply surfaces' lifetime is one DISPATCHED LINE, not one ask.
  # A human question can now be raised from a frame {Repl#respond} never enters
  # -- a registered command runs lib-side with zero model turns, and a
  # `@role[/skill]` line folds a whole subagent run into the repl phase's short
  # circuit -- and the fiber that parks on such a question is the DISPATCHING
  # one. With the surfaces started inside `#respond`, nothing was draining the
  # queue while that fiber waited, so the question could only be answered by a
  # `/inbox` the wedged conversation could no longer read.
  #
  # The far edge is what the widening must not cross: {HumanReplies#surfaces}
  # documents its fiber as one that "must live exactly as long as the ask and no
  # longer -- the reply read parks inside it, and the terminal it reads from is
  # the one the next `you>` prompt needs back". `#dispatch` ends before that
  # read; a conversation-scoped answer_loop would not, and would race every
  # prompt for stdin.
  #
  # Every example drives the REAL {Repl#run} over the REAL {HumanReplies} and
  # its real fibers -- the queue is a live Async::Queue and the reply comes off
  # a real terminal read.
  describe "the reply surfaces' lifetime" do
    let(:conductor) { instance_double(Lain::CLI::Conductor, closed?: false) }
    let(:agent) { instance_double(Lain::Agent, timeline: nil) }
    let(:supervisor) { instance_double(Lain::Supervisor, run: nil, stop: nil) }
    let(:questions) { Async::Queue.new }
    let(:answers) { ReplRecordedAnswers.new }
    let(:output) { StringIO.new }
    let(:typed) { "an answer\nsecond answer\n" }
    let(:tty) do
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output:, input: StringIO.new(typed),
                              history_path: File.join(@dir, "history"))
    end
    # THE subject's collaborator, not a double: "was a fiber alive to serve this"
    # is the question, and a double answers it by construction.
    let(:replies) { Lain::CLI::HumanReplies.new(tty:, conductor:, questions:, ask_human: answers) }
    # The queue is REAL, and so is its fail-closed timer: what a suppressed
    # terminal surface costs is a call that waits, and the worst case is the
    # queue refusing it -- never a silent grant.
    let(:approvals) { Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 5) }

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        example.run
      end
    end

    def item(question = "which file", digest: "digest-of-which-file")
      Lain::CLI::HumanReplies::InboxItem.new(question:, from: "researcher", digest:, asked_at: Time.now)
    end

    # The command registry's seam, standing in for every frame that can now raise
    # a question without reaching `#respond`: a lambda, so the body runs in the
    # example's own scope and can wait on the example's collaborators.
    def commands_that(serves_replies: false, &body)
      Struct.new(:body, :serves) do
        def dispatch(text, &_downstream) = body.call(text)
        def serves_replies?(_text) = serves
      end.new(body, serves_replies)
    end

    # `reading:` is how the terminal behaves at a `human> ` prompt. `:typed` is a
    # human who answers at once; `:never` is the honest shape of one who is not
    # looking -- a read that parks and is still parked when the line ends.
    # `:counted` parks BRIEFLY and then answers, which is the only way two
    # readers can be caught overlapping: a StringIO returns instantly, so a
    # second reader would never be observed even where it exists.
    #
    # Bounded, because an unstopped surface would hold the session's Sync open
    # forever and a hung suite says nothing.
    def converse_over(commands, reading: :typed, approvals: nil, &at_prompt)
      allow(conductor).to receive(:read_reply, &reply_reader(reading))
      allow(conductor).to receive(:read_prompt, &at_prompt)
      Timeout.timeout(10) { repl_over(commands, approvals).run(nvim: nil, store: nil, session: nil) }
    end

    def repl_over(commands, approvals = nil)
      described_class.new(agent:, tty:, replies:, commands:, supervisor:, approvals:,
                          chronicle: Lain::CLI::Chronicle::Null.new, conductor:)
    end

    # `fetch`, so a typo names itself rather than silently reading the terminal.
    def reply_reader(reading)
      {
        typed: ->(terminal, prompt) { terminal.prompt(prompt) },
        never: ->(_terminal, _prompt) { Async::Task.current.sleep(60) },
        counted: method(:counted_read)
      }.fetch(reading)
    end

    # How many reply reads are parked on the one terminal at this instant, and
    # the most there have ever been. Counted rather than inferred from the
    # rendered prompts: two reads that ran back to back print the same two
    # prompts as two that overlapped, and only the second is a wedge.
    def counted_read(terminal, prompt)
      @in_flight = @in_flight.to_i + 1
      @peak = [@peak.to_i, @in_flight].max
      Async::Task.current.sleep(0.05) # the human is typing
      terminal.prompt(prompt).tap { @in_flight -= 1 }
    end

    def peak_reply_reads = @peak.to_i

    # THE REGRESSION. Nothing here ever calls `#respond`: the command answers the
    # line itself, exactly as a skill spawn's short circuit does, and the question
    # is raised while that call is in flight.
    it "serves a question raised while a command is dispatched, a frame respond never enters" do
      lines = ["ask me", "quit"]
      commands = commands_that do |_text|
        questions.enqueue(item)
        wait_until(reason: "the question raised mid-dispatch was answered") { answers.answered.any? }
        "the command answered"
      end

      converse_over(commands) { lines.shift }

      expect(answers.answered).to contain_exactly(["an answer", "digest-of-which-file"])
      expect(output.string).to include("which file", "human> ")
    end

    # The other edge, asserted as the NEGATIVE it is: at `you>` no reply fiber
    # may be parked on the terminal, so an arrival there waits for `/inbox` (or
    # for the next line to be dispatched) rather than stealing the prompt's read.
    it "leaves nothing parked on the terminal at the you> prompt" do
      commands = commands_that { |_text| "never dispatched" }

      converse_over(commands) do
        questions.enqueue(item)
        sleep(0.2)
        "quit"
      end

      expect(answers.answered).to be_empty
      expect(output.string).not_to include("human> ")
    end

    # Review BLOCKER 2 (probe 1). The fleet outlives any one ask, so a
    # background subagent can enqueue while the human runs a SHORT command line
    # -- `/help`, `/status`, `/models`. The reply loop is live for that line: it
    # dequeues, renders the note, and parks on a read nobody is looking at. The
    # line ends and the surface is stopped mid-read.
    #
    # The item must survive that. Destroyed, it is off `@questions` (dequeued)
    # AND off `@inbox` (retired), so `pending?` is false, `/inbox` can never list
    # it, and the asker is parked forever -- with no error and no journal line.
    # The widening is what exposes every command line to it; the mechanism is
    # {HumanReplies#serve_question}'s own ensure, pinned one level down in
    # human_replies_spec.
    it "keeps a question the human never answered reachable when the line that surfaced it ends" do
      lines = ["/short-command", "quit"]
      commands = commands_that do |_text|
        questions.enqueue(item)
        Async::Task.current.sleep(0.3) # long enough for the loop to dequeue and park on the read
        "the command is done"
      end

      converse_over(commands, reading: :never) { lines.shift }

      expect(answers.answered).to be_empty # nobody typed, so nothing may have been delivered
      expect(replies.pending?).to be(true)
    end

    # Review round 2. The re-queue keeps it reachable, which is right -- but
    # every later line re-opens a loop that dequeues it at once. An ARRIVAL note
    # says "this just arrived", and on the third `/fast` line that is simply
    # false; worse, the read it opens is torn down before a human could type into
    # it, so the repetition is noise the human cannot act on. The note is owed
    # ONCE per item; the read still opens, so a line they linger on is still
    # answerable.
    it "announces an outstanding question once, however many lines it outlives" do
      questions.enqueue(item)
      lines = ["/fast", "/fast", "/fast", "quit"]
      commands = commands_that { |_text| "done" }

      converse_over(commands, reading: :never) { lines.shift }

      expect(output.string.scan("which file").size).to eq(1)
    end

    # Review BLOCKER 1 (probe 2c). `/inbox` is a REGISTERED command, so the
    # widening puts it inside the bracket -- and `Async::Queue#dequeue` on a
    # non-empty queue returns WITHOUT suspending, so the reply loop takes the
    # head item and opens a `human> ` read while `drain_at_prompt` opens a SECOND
    # one on the same stdin. Whichever fiber wins takes the human's typed line,
    # and `Reply#at_prompt` answers `@inbox.oldest` -- which the loop has already
    # pushed its own item onto, so the answer lands on the wrong digest.
    #
    # `/inbox` exists BECAUSE no loop runs between asks; a fix that makes it race
    # the loop it substitutes for has moved the wedge, not removed it. So the
    # line DECLARES that it serves replies, and no second surface opens over it.
    # The REAL registry over the REAL `/inbox`, bound over the run's own
    # {HumanReplies} -- the whole chain the declaration travels, from the
    # command that makes it to the scope that reads it. A fake command answering
    # `serves_replies?` would pin the wiring and not the shipped behaviour, and
    # this defect lived in exactly that gap.
    describe "a line that is itself a reply surface" do
      let(:inbox_registry) do
        Lain::CLI::Command::Registry.new([Lain::CLI::Command::Inbox.new]).bind(build_command_env(replies:))
      end

      it "opens exactly one reply read over a backlog" do
        questions.enqueue(item)
        questions.enqueue(item("which branch", digest: "digest-of-which-branch"))
        lines = ["/inbox", "quit"]

        converse_over(inbox_registry, reading: :counted) { lines.shift }

        expect(peak_reply_reads).to eq(1)
      end

      it "gives that line's own drain the answer the human typed" do
        questions.enqueue(item)
        lines = ["/inbox", "quit"]

        converse_over(inbox_registry, reading: :counted) { lines.shift }

        expect(answers.answered).to contain_exactly(["an answer", "digest-of-which-file"])
        expect(output.string).to include("which file")
      end

      # Review round 2, BLOCKER A. The APPROVAL watcher is a different QUEUE
      # and NOT a different terminal: {Repl::ApprovalSurfaces#approval_surface}
      # reads through `conductor.read_reply(tty, prompt)`, byte-for-byte the
      # stdin the drain is parked on. An adopted actor can park a tier-3 call at
      # any instant, so a `y` typed at an inbox question could land as the
      # verdict on a gated `bash` -- an approval the human never gave. Before
      # this card a command line started no watchers at all, so it is the
      # widening that makes it reachable.
      #
      # A real {Approval::Queue} and a real parked call, because the claim is
      # about which fiber holds the terminal and only real fibers can be counted.
      it "opens no approval read either, so a keystroke cannot land as a y/N verdict" do
        questions.enqueue(item)
        lines = ["/inbox", "quit"]

        Sync do |task|
          task.async do
            task.sleep(0.05) # the drain has started and is parked on the read
            approvals.call(gated_call, nil)
          rescue StandardError
            nil
          end
          converse_over(inbox_registry, reading: :counted, approvals:) { lines.shift }
        end

        expect(peak_reply_reads).to eq(1)
        expect(output.string).not_to include("approve bash")
      end
    end

    def gated_call
      Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => "echo hi" })
    end
  end

  # A line no command claims runs its middleware phase UNDER the conductor's
  # supervision, not only its model turn: a middleware that answers without one
  # -- `/critique` spawning a child per chunk, `/meta generate` spawning one --
  # can run for minutes, and outside supervision every signal routes to
  # `Signals::NULL`. So the human's Ctrl-C reaches it exactly as it reaches a
  # turn: one arms the grace window, a second (or SIGQUIT, or the window
  # expiring) stops it and closes the session.
  #
  # Real {Repl#run}, real {Conductor}, real {Signals} installed, real OS
  # signals; only the middleware is a probe. The signal is sent from INSIDE the
  # parked middleware, so it provably arrives while that middleware runs.
  describe "a middleware turn under the conductor's supervision" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
      Dir.mktmpdir("lain-repl-supervised") do |dir|
        @dir = dir
        example.run
      end
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    # The session record, as the two writes a stop owes it.
    let(:chronicle) do
      Class.new(SimpleDelegator) do
        def initialize
          super(Lain::CLI::Chronicle::Null.new)
          @events = []
        end

        attr_reader :events

        def interrupted(reason:, **) = tap { @events << [:interrupted, reason] }
        def close(reason:) = tap { @events << [:close, reason] }
      end.new
    end

    let(:out) { StringIO.new }
    let(:tty) do
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: out, input: StringIO.new,
                              history_path: File.join(@dir, "history"))
    end
    let(:agent) do
      Lain::Agent.new(provider: Lain::Provider::Mock.new(responses: [text_response("a model answer")]),
                      toolset: Lain::Toolset.new([]), context: Lain::Context.new(model: "m", max_tokens: 64))
    end
    let(:log) { [] }

    def clock_returning(*values)
      seq = values.dup
      -> { seq.size > 1 ? seq.shift : seq.first }
    end

    # Answers each line once, then EOF, so the conversation is exactly as long
    # as the lines given. `supervisions` counts the real #supervise calls.
    def conductor_over(lines, clock: -> { 1000.0 })
      @signals = Lain::CLI::Signals.new.install
      Lain::CLI::Conductor.new(tty:, chronicle:, signals: @signals, grace: 60, clock:, tick: 0.01).tap do |conductor|
        conductor.define_singleton_method(:read_prompt) { |*| lines.shift }
        supervisions = @supervisions = []
        conductor.define_singleton_method(:supervise) do |*args, &block|
          supervisions << :supervised
          super(*args, &block)
        end
      end
    end

    def passthrough_commands
      Struct.new(:nothing) do
        def dispatch(_text) = yield
        def serves_replies?(_text) = false
      end.new(nil)
    end

    def replies_over(conductor)
      Lain::CLI::HumanReplies.new(tty:, conductor:, questions: Async::Queue.new,
                                  ask_human: instance_double(Lain::Tools::AskHuman::Directory))
    end

    # A registry that claims every line itself, the way `/help` is claimed.
    def claiming_commands
      Struct.new(:nothing) do
        def dispatch(_text) = "the help text"
        def serves_replies?(_text) = false
      end.new(nil)
    end

    def converse(middleware, conductor, commands: passthrough_commands)
      Timeout.timeout(20) do
        Lain::CLI::Repl.new(agent:, tty:, replies: replies_over(conductor), commands:,
                            chronicle:, conductor:, middleware: Lain::Middleware::Stack.new([middleware]))
                       .run(nvim: nil, store: nil, session: nil)
      end
    ensure
      @signals&.uninstall
    end

    # Parks long enough that only a stop ends it early, after sending `signals`
    # to this process.
    def parked(*signals)
      log = self.log
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &_app|
          log << :entered
          # A tick first: the run task starts EAGERLY, ahead of the conductor
          # routing signals to its shutdown, and a human's key arrives later.
          Async::Task.current.sleep(0.05)
          signals.each { |name| Process.kill(name, Process.pid) }
          Async::Task.current.sleep(3)
          log << :finished
          env.merge(response: Lain::Response.new(content: [{ "type" => "text", "text" => "late" }],
                                                 stop_reason: :end_turn))
        ensure
          log << :unwound
        end
      end.new
    end

    def answering(text)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) do |env, &_app|
          env.merge(response: Lain::Response.new(content: [{ "type" => "text", "text" => text }],
                                                 stop_reason: :end_turn))
        end
      end.new
    end

    def raising(message)
      Class.new(Lain::Middleware::Base) do
        define_method(:call) { |_env, &_app| raise Lain::Error, message }
      end.new
    end

    it "stops a parked middleware on a double SIGINT, closing the session as interrupted" do
      conductor = conductor_over(["/park"])

      converse(parked("INT", "INT"), conductor)

      expect(log).to eq(%i[entered unwound])
      expect(chronicle.events).to eq([%i[interrupted interrupted], %i[close interrupted]])
      expect(conductor).to be_closed
    end

    it "stops a parked middleware at once on SIGQUIT" do
      conductor = conductor_over(["/park"])

      converse(parked("QUIT"), conductor)

      expect(log).to eq(%i[entered unwound])
      expect(chronicle.events.last).to eq(%i[close interrupted])
    end

    # arm reads 1000 -> deadline 1060; the next poll reads 1061 -> expired.
    it "arms the grace window on one SIGINT, and stops the middleware when it expires" do
      conductor = conductor_over(["/park"], clock: clock_returning(1000.0, 1061.0))

      converse(parked("INT"), conductor)

      expect(log).to eq(%i[entered unwound])
      expect(chronicle.events).to eq([%i[interrupted grace_expired], %i[close grace_expired]])
    end

    it "settles a middleware that answers without a turn with no interrupted record, leaving the session open" do
      conductor = conductor_over(["/answered"])

      converse(answering("answered in the repl phase"), conductor)

      expect(out.string).to include("answered in the repl phase")
      expect(chronicle.events).to be_empty
      expect(conductor).not_to be_closed
      expect(@supervisions).to eq([:supervised])
    end

    it "renders a middleware's refusal as one line, with no interrupted record and no unhandled-task warning" do
      conductor = conductor_over(["/refused"])
      noise = Tempfile.create("lain-repl-supervised-stderr") do |file|
        saved = $stderr.dup
        begin
          $stderr.reopen(file)
          converse(raising("the middleware refused"), conductor)
          $stderr.flush
        ensure
          $stderr.reopen(saved)
          saved.close
        end
        File.read(file.path)
      end

      expect(out.string).to include("the middleware refused")
      expect(noise).not_to include("Task may have ended with unhandled exception")
      expect(chronicle.events).to be_empty
    end

    # The middleware here would send a signal if it ran; that it never runs is
    # the point, so no signal is ever sent.
    it "never enters the middleware phase or its supervision for a command line such as /help" do
      conductor = conductor_over(["/help"])

      converse(parked("INT"), conductor, commands: claiming_commands)

      expect(out.string).to include("the help text")
      expect(@supervisions).to be_empty
      expect(log).to be_empty
      expect(chronicle.events).to be_empty
      expect(conductor).not_to be_closed
    end

    # The supervisor ITSELF raising -- its fleet drain, say -- is refused in
    # the one line an ask's refusal gets, and that line is the whole of it: no
    # middleware-breach report on top, and one torn record rather than two.
    it "renders a supervisor's own refusal as its one line, with no breach report and one torn record" do
      conductor = conductor_over(["hello"])
      conductor.define_singleton_method(:supervise) { |*| raise Lain::Error, "the fleet could not drain" }

      converse(Lain::Middleware::Base.new, conductor)

      expect(out.string.scan("the fleet could not drain").size).to eq(1)
      expect(out.string).not_to include(Lain::CLI::Repl::MIDDLEWARE_BREACH)
      expect(chronicle.events).to eq([%i[interrupted torn]])
    end

    # The model turn a pass-through middleware reaches is supervised by the
    # SAME supervision as the middleware around it, never a second nested one.
    it "supervises a line that reaches the model exactly once" do
      conductor = conductor_over(["hello"])

      converse(Lain::Middleware::Base.new, conductor)

      expect(out.string).to include("a model answer")
      expect(@supervisions).to eq([:supervised])
      expect(chronicle.events).to be_empty
    end
  end
end
