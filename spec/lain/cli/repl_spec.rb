# frozen_string_literal: true

require "async"
require "delegate"
require "json"
require "pastel"
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

# A provider with a BUG in it, for T16's "a crash is not a refusal" example. Not
# a tool that raises: `Effect::Handler::Live#dispatch` contains those as
# `Tool::Result.error` (correctness gate 3), so a tool cannot crash an ask by
# design. The provider is the nearest thing to a real bug that reaches one.
class ExplodingProvider < Lain::Provider::Mock
  def complete(_request) = raise(TypeError, "genuinely broken")
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
      # The command surface's duck is two messages now (T1): the Repl asks
      # whether the LINE is itself a reply surface before it brackets it.
      commands = Struct.new(:outcome) do
        def dispatch(_text) = outcome
        def serves_replies?(_text) = false
      end.new(outcome)
      # `surfaces: []` because the reply surfaces are bracketed around the whole
      # DISPATCHED LINE now (T1), not around the ask -- so a command that never
      # reaches #respond still asks this collaborator for them.
      Lain::CLI::Repl.new(agent: instance_double(Lain::Agent, timeline: nil), tty:,
                          replies: instance_double(Lain::CLI::HumanReplies, surfaces: []), commands:,
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

  # T16, manual-QA round 4's F22. A budget ceiling is the HARNESS deciding to
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
    # reproduction T14 left standing, since the ceiling now bounds one ask.
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

  # T1: the reply surfaces' lifetime is one DISPATCHED LINE, not one ask.
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

    # T1 review, BLOCKER 2 (probe 1). The fleet outlives any one ask (OM-6), so a
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

    # T1 review round 2. The re-queue keeps it reachable, which is right -- but
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

    # T1 review, BLOCKER 1 (probe 2c). `/inbox` is a REGISTERED command, so the
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

      # T1 review round 2, BLOCKER A. The APPROVAL watcher is a different QUEUE
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
end
