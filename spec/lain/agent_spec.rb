# frozen_string_literal: true

require "async/queue"

# The per-turn Context sources. Defined in a module body so each pipeline is
# built where `self` is Ractor-shareable -- the same reason
# T21PipelineProviders exists (see context_spec) -- and so the doubles read as
# the production duck they stand in for: `context_for(base:, timeline:, usage:,
# session:) -> Context`.
module A1PipelineSources
  # Records every call verbatim and defers to the base, so what the Agent
  # passes can be asserted without changing what it renders.
  class Recording
    attr_reader :calls

    def initialize = @calls = []

    def context_for(base:, **rest)
      @calls << rest.merge(base:)
      base
    end
  end

  # One fixed strategy, every turn: the copy-with the card is about.
  class Pruning
    attr_reader :contexts

    def initialize(keep_last:)
      @keep_last = keep_last
      @contexts = []
    end

    def context_for(base:, **)
      base.with_pipeline(Lain::Context::Prune.new(keep_last: @keep_last)).tap { |ctx| @contexts << ctx }
    end
  end

  # The handoff fallback's seam, reduced to the messages the Agent sends it.
  # `answers` is what each #handoff call reports, so an example can script
  # "room was made" and "nothing could be done" in one run; the calls are kept
  # so the timeline and session it was handed can be asserted. `droppable:`
  # is what the refused render left for an ordinary compaction to drop.
  # A render changes the way the real source's does: once per committed
  # handoff, and once more when `compacts:` and a reading arrives to measure,
  # which is the refusal's count on a first ask.
  class HandingOff
    attr_reader :calls

    def initialize(*answers, droppable: false, compacts: droppable)
      @answers = answers
      @droppable = droppable
      @compacts = compacts
      @committed = 0
      @calls = []
    end

    def context_for(base:, usage:, **)
      generation = @committed + (@compacts && usage ? 1 : 0)
      generation.zero? ? base : base.with_pipeline(Rewritten.new(generation))
    end

    def droppable? = @droppable

    def handed_off? = @committed.positive?

    def handoff(**rest)
      @calls << rest
      @answers.fetch(@calls.size - 1, false).tap { |made| @committed += 1 if made }
    end
  end

  # Whatever a cut or a compaction leaves the render, reduced to one fact: the
  # oldest message reads differently each generation, so no two renders match.
  class Rewritten < Lain::Context::Combinator
    def initialize(generation)
      super()
      @generation = generation
      freeze
    end

    def call(messages)
      oldest, *rest = messages
      [oldest.merge("content" => [{ "type" => "text", "text" => "rewritten #{@generation}" }]), *rest]
    end
  end

  # The idle-prepare half of the duck, recording what each prepare was handed
  # and, through `log`, when it ran relative to a render. A `gate` queue holds
  # the prepare open until the example pushes it a value, so a line can be typed
  # into a prepare still in flight.
  class Preparing
    attr_reader :prepares, :renders, :log

    def initialize(answer: true, gate: nil, during: -> {})
      @answer = answer
      @gate = gate
      @during = during
      @prepares = []
      @renders = []
      @log = []
    end

    def context_for(base:, **rest)
      @log << :render
      @renders << rest.merge(base:)
      base
    end

    def prepare(**args)
      @log << :prepare_started
      @prepares << args
      @during.call
      @gate&.pop
      @log << :prepare_returned
      @answer
    end
  end

  # A DIFFERENT pipeline per call -- the shape that tells "consulted every
  # turn" apart from "consulted once and cached".
  class Widening
    def initialize = @calls = 0

    def context_for(base:, **)
      @calls += 1
      base.with_pipeline(Lain::Context::Prune.new(keep_last: @calls))
    end
  end
end

# A tool that posts a note to the running agent while it runs, standing in for
# a line typed into the input pane during a tool round. In a module body for
# the reason A1PipelineSources is.
module LiveNotes
  class Posting < Lain::Tool
    def initialize(post)
      super()
      @post = post
    end

    def name = "posting"
    def description = "Runs while a note arrives."
    def input_schema = { type: :object, properties: {} }

    def perform(_input, _context)
      @post.call
      Lain::Tool::Result.ok("ran")
    end
  end

  class Witness
    attr_reader :renders

    def initialize = @renders = 0

    def context_for(base:, **)
      witness = self
      SimpleDelegator.new(base).tap do |stand_in|
        stand_in.define_singleton_method(:render) do |**args|
          witness.rendered!
          __getobj__.render(**args)
        end
      end
    end

    def rendered! = @renders += 1
  end

  class Tag < Lain::Context::Combinator
    include Lain::Context::TailInjection

    def call(messages) = append_to_last(messages, [{ "type" => "text", "text" => "<tag/>" }])
  end

  class Tagging
    def context_for(base:, **) = base.with_pipeline(->(workspace) { Lain::Context.pipeline(workspace) >> Tag.new })
  end
end

# One recorder per {Lain::Agent::Instrumentation} member, so "the value
# reached its consumer" is asserted from an observable effect rather than from
# the Agent's own ivars. In a module body for the same reason A1PipelineSources
# is: the doubles read as the production ducks they stand in for.
module T22Instrumentation
  # Any middleware phase. Appends its label on the way in, then defers, so the
  # log also says which phases ran and in what order.
  class Tap < Lain::Middleware::Base
    def initialize(log, label)
      super()
      @log = log
      @label = label
    end

    def call(env, &app)
      @log << @label
      downstream(env, &app)
    end
  end

  # {Lain::Agent::TransitionListener}'s duck.
  class Transitions
    attr_reader :events

    def initialize = @events = []

    def on_transition(from:, to:, event:) = @events << [from, to, event]
  end

  # {Lain::Agent::ToolRunner::Observer}'s duck: named after dispatch, per tool.
  class Observations
    attr_reader :tools

    def initialize = @tools = []

    def observe(_block, tool_name) = @tools << tool_name
  end

  # {Lain::Agent::PipelineSource}'s duck, counting the per-turn asks.
  class Renders
    attr_reader :asks

    def initialize = @asks = 0

    def context_for(base:, **)
      @asks += 1
      base
    end
  end
end

# The post-dispatch observation seam is the LAST thing
# {Lain::Agent::ToolRunner#run} does, so an observer that cancels its own task
# tears the run at the one point where every tool has already answered -- the
# case a cancellation must not claim, reached deterministically and with no
# clock. In a module body for the reason the fixtures above are.
module T6Interrupts
  # Cancels the task it is observing on, which is exactly what
  # {Lain::Agent#interrupt} does from outside.
  class Cancelling
    def observe(_block, _tool_name) = Async::Task.current.stop
  end
end

# A real Store that refuses any payload carrying its marker: a tool result the
# Timeline cannot commit, whatever upstream made it so. In a module body for
# the reason the fixtures above are.
module UncommittableResults
  class Store < Lain::Store
    REFUSAL = "this store refuses that result"

    attr_reader :refusals

    def initialize(*markers)
      super()
      @markers = markers
      @refusals = []
    end

    def put(object)
      refuse(object) if object.is_a?(Lain::Event::Payload)

      super
    end

    private

    def refuse(payload)
      body = JSON.generate(payload.body)
      marker = @markers.find { |candidate| body.include?(candidate) }
      return if marker.nil?

      @refusals << marker
      raise Lain::Error, @refusals.one? ? REFUSAL : "#{REFUSAL} (refusal #{@refusals.size})"
    end
  end

  # A Store that runs a one-shot race on its next read. A rewind's first read
  # is its walk back, the instant after any guard and before the move, which is
  # where a check-then-act guard lets a racing run in.
  class RacedStore < Lain::Store
    def arm(&race) = @race = race

    def fetch(digest)
      race = @race
      @race = nil
      race&.call
      super
    end
  end
end

RSpec.describe Lain::Agent do
  # ---- fixtures -------------------------------------------------------------

  let(:toolset) { CoreGraph.toolset([EchoTool.new, BoomTool.new]) }
  let(:context) { CoreGraph.context }

  def agent(responses, **overrides)
    described_class.new(provider: CoreGraph.provider(*Array(responses)), toolset:, context:, **overrides)
  end

  # A thinking block rides along on every tool_use here, so the loop is
  # exercised with the mixed content real responses carry.
  def tool_response(*calls) = super(*calls, thinking: "considering")

  # ---- the loop -------------------------------------------------------------

  # CoreGraph has no spec of its own -- it is exercised by every spec that uses
  # it. This is the one property those specs LEAN on rather than merely enjoy:
  # the default graph is closed. Asserted here because this file drives more of
  # the factory than any other.
  #
  # Each default is named explicitly rather than inferred from a run, because
  # only some of them redden their users when broken. Swapping the journal or
  # the model for a real one fails in these specs; swapping the TOOLSET for an
  # empty one leaves this file, status_feed and session_record entirely green
  # and reddens only supervisor_spec -- so `echo` is pinned here, where a
  # reader of the factory will find it, and not left to a distant file.
  describe "the graph CoreGraph hands out by default" do
    it "runs to completion holding no file descriptor of its own" do
      expect(CoreGraph.journal).to be(Lain::Channel::Null.instance)
      expect(CoreGraph.provider).to be_a(Lain::Provider::Mock)
      expect(CoreGraph.toolset.names).to eq(["echo"])

      # The run leg, and the only assertion here that measures rather than
      # declares: a default graph that opened a journal file, a socket or a
      # pipe would leave the descriptor behind. WebMock already owns "no
      # network" suite-wide (spec/network_posture_spec.rb), so asking it again
      # here would be an assertion that cannot fail.
      before_fds = Dir.children("/proc/self/fd").size
      CoreGraph.agent(provider: CoreGraph.provider(text_response("hi"))).ask("hi")

      expect(Dir.children("/proc/self/fd").size).to eq(before_fds)
    end
  end

  describe "#ask" do
    it "appends the user turn and settles on end_turn" do
      a = agent(text_response("hello"))
      response = a.ask("hi")

      expect(response.text).to eq("hello")
      expect(a).to be_done
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
    end
  end

  describe "#ask!" do
    it "raises a named failure on a malformed stop, and leaves the agent failed" do
      a = agent(Lain::Response.new(content: [{ "type" => "text", "text" => "<tool_call>\n<function=bash>" }],
                                   stop_reason: :malformed))

      expect { a.ask!("hi") }.to raise_error(Lain::Response::Failed, /malformed/) { |error|
        expect(error.failure).to eq(Lain::Response::Failure.new(stop_reason: :malformed,
                                                                message: Lain::Response::Failure::PROSE_CALL))
      }
      expect(a).to be_failed
    end

    it "returns the answer's text on end_turn" do
      expect(agent(text_response("hello")).ask!("hi")).to eq("hello")
    end
  end

  # ---- correctness gates ----------------------------------------------------
  #
  # Gates 1-7 are verified provider-agnostically by the shared "a Lain::Provider"
  # group (spec/support/shared_examples/provider_parity.rb), driven against
  # Provider::Mock in provider/mock_spec.rb and against Anthropic. What stays
  # here is only what is Agent-specific and NOT in that group: the parallel-call
  # role sequence, the surfaced error/failure messages, usage accumulation, the
  # token ceiling, #rewind, and the state machine.

  describe "gate 2: all tool_results return in ONE user message" do
    it "appends a single user turn holding every result" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }]),
                 text_response])
      a.ask("hi")

      results_turn = a.timeline.to_a[2]
      expect(results_turn.role).to eq("user")
      expect(results_turn.content.map { |b| b["type"] }).to eq(%w[tool_result tool_result])
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end
  end

  # The tool_result commit is what DELIVERS an ask_human answer
  # back into the conversation, so that commit is the consumption edge -- the
  # :turn whose causal_parents cite Q, which is the ONLY thing that retires Q
  # from Projection#pending("human") (a reply :message alone never does; the
  # rule is pinned in status_feed_spec and projection's own doc).
  describe "ask_human consumption: the delivery commit cites the answered question" do
    it "records Q's digest as a causal parent of the tool_result turn" do
      a = nil
      ask = Lain::Tools::AskHuman.new(parent: -> { a.timeline })
      a = described_class.new(
        provider: CoreGraph.provider(
          tool_response(["tu_1", "ask_human", { "question" => "which db?" }]),
          text_response("done")
        ),
        toolset: CoreGraph.toolset([ask]), context:
      )

      Sync do |task|
        run = task.async { a.ask("hi") }
        # The ask ran synchronously up to its await, so the question is
        # already pending -- no sleep, no timing race (ask_human_spec's idiom).
        expect(ask.pending?).to be(true)
        ask.reply("postgres", ask.last_question.digest)
        run.wait
      end

      delivery = a.timeline.to_a[2]
      expect(delivery.role).to eq("user")
      expect(delivery.content.map { |block| block["type"] }).to eq(["tool_result"])
      expect(delivery.causal_parents).to include(ask.last_question.digest)
      # And the projection agrees: the delivered question is no longer pending.
      log = a.timeline.to_a + [ask.last_question, ask.last_answer]
      expect(Lain::Event::Projection.new(log).pending("human").to_a).to be_empty
    end

    it "cites the digest exactly once: a later tool turn carries no stale edge" do
      a = nil
      ask = Lain::Tools::AskHuman.new(parent: -> { a.timeline })
      a = described_class.new(
        provider: CoreGraph.provider(
          tool_response(["tu_1", "ask_human", { "question" => "which db?" }]),
          tool_response(["tu_2", "ask_human", { "question" => "and port?" }]),
          text_response("done")
        ),
        toolset: CoreGraph.toolset([ask]), context:
      )

      Sync do |task|
        run = task.async { a.ask("hi") }
        first_question = ask.last_question
        ask.reply("postgres", first_question.digest)
        # In a reactor, sleep yields this fiber, so the resumed loop commits
        # the first delivery and parks on the second ask before we continue.
        sleep(0.01)
        expect(ask.last_question).not_to eq(first_question)
        ask.reply("5432", ask.last_question.digest)
        run.wait

        turns = a.timeline.to_a
        deliveries = turns.select { |turn| turn.role == "user" && turn.causal_parents.any? }
        expect(deliveries.size).to eq(2)
        expect(deliveries.first.causal_parents).to eq([first_question.digest])
        expect(deliveries.last.causal_parents).to eq([ask.last_question.digest])
      end
    end

    it "keeps an ordinary tool turn's causal_parents empty (recorded digests unmoved)" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response])
      a.ask("hi")

      expect(a.timeline.to_a[2].causal_parents).to eq([])
    end
  end

  describe "the files a tool round wrote" do
    it "reports a real write_file to the display channel, by display_as, relative to the project root" do
      Dir.mktmpdir do |dir|
        worker_env = Lain::WorkerEnv.new(cwd: dir, env: {})
        display = []
        a = agent([tool_response(["tu_1", "write_file", { "path" => "notes.md", "content" => "hi\n" }]),
                   text_response],
                  toolset: CoreGraph.toolset([Lain::Tools::WriteFile.new]),
                  session: Lain::Session.new(worker_env:), display:, display_as: "sage")
        a.ask("write it")

        expect(display).to eq([Lain::Telemetry::FilesWritten.new(role: "sage", paths: ["notes.md"])])
      end
    end
  end

  # The window a tear strands a tool_use in is #perform_tools: the
  # assistant turn is committed and its results are not. What the Agent owns
  # here is WHEN the cancellation is committed, not what it says -- the block
  # shape belongs to ToolRunner::Answers, and the end-to-end tear (a real cancel
  # landing inside a real parked tool) is spec/lain/seams/tool_cancellation_spec.rb.
  describe "a run torn between the assistant turn and its tool results" do
    it "commits the real results, and journals no cancellation, when every tool had returned" do
      journal = []
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response],
                tool_observer: T6Interrupts::Cancelling.new, journal:)

      Sync { |task| task.async { a.ask("hi") }.wait }

      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
      expect(a.timeline.to_a.last.content.map { |block| block["content"] }).to eq(["a"])
      expect(journal.grep(Lain::Telemetry::ToolCancelled)).to be_empty
    end

    # The stop still lands. A cancellation commit that swallowed its own
    # interrupt would leave Ctrl-C and grace expiry unable to end a run at all,
    # so the commit is followed by a re-raise and never by a `return`.
    it "re-raises the interrupt after committing, so the loop takes no further turn" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response("second turn")],
                tool_observer: T6Interrupts::Cancelling.new)
      run = nil

      Sync do |task|
        run = task.async { a.ask("hi") }
        run.wait
      end

      expect(run).to be_cancelled
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
      expect(a).not_to be_done
    end
  end

  # Every record a tool round writes cites the turn that called its tools, so
  # that turn goes into the record before any of them runs, and before the
  # usage record naming it. The settle is shielded with the commit, so a stop
  # waits for the write rather than landing between the two.
  describe "settling the turn middleware before tools run" do
    # A turn phase that answers `settle`, logging what it was handed.
    def settling(log, &on_settle)
      Class.new(Lain::Middleware::Base) do
        define_method(:settle) do |timeline|
          on_settle&.call
          log << [:settle, timeline.head.content.map { |block| block["type"] }]
        end
      end.new
    end

    def logging_journal(log) = Class.new { define_method(:<<) { |record| log << record.class } }.new

    it "hands over the committed tool_use turn before any tool runs, and before its usage record" do
      log = []
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response("done")],
                turn_middleware: Lain::Middleware::Stack.new([settling(log)]),
                tool_middleware: Lain::Middleware::Stack.new([T22Instrumentation::Tap.new(log, :tool)]),
                journal: logging_journal(log))

      a.ask("hi")

      expect(log.take(3)).to eq([[:settle, %w[thinking tool_use]], Lain::Telemetry::TurnUsage, :tool])
    end

    # The documented middleware duck is `#call` alone, which the turn phase no
    # longer accepts: refused as the Agent is built, not as an errored tool round
    # on every commit.
    it "refuses, at construction, a turn member that answers only #call" do
      duck = Class.new { def call(env) = yield(env) }.new

      expect { agent(text_response("done"), turn_middleware: Lain::Middleware::Stack.new([duck])) }
        .to raise_error(Lain::Middleware::CannotSettle, /settle/)
      expect { Lain::Agent::Instrumentation.new.with(turn_middleware: Lain::Middleware::Stack.new([duck])) }
        .to raise_error(Lain::Middleware::CannotSettle, /settle/)
    end

    it "defers a stop landing during the settle until the turn's usage is recorded" do
      log = []
      entered = Async::Queue.new
      release = Async::Queue.new
      parked = settling(log) do
        entered.enqueue(true)
        release.dequeue
      end
      a = agent(text_response("done"), turn_middleware: Lain::Middleware::Stack.new([parked]),
                                       journal: logging_journal(log))
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = a.ask("hi") }
        task.with_timeout(5) { entered.dequeue }
        a.interrupt(run)
        release.enqueue(true)
        run.wait
      end

      expect(log).to eq([[:settle, %w[text]], Lain::Telemetry::TurnUsage])
      expect(returned).to eq(:never_returned)
    end
  end

  # Any failure after the assistant turn commits its calls, other than an
  # interrupt, used to leave those calls unanswered; the next ask committed user
  # text over them and every later derivation refused the chain. Each repair
  # answers through Tool::Cancellation, and the kind names which repair it was.
  describe "a tool_use is never left unanswered" do
    def conversation_of(agent)
      Lain::Context::Conversation.new(context.render(timeline: agent.timeline, toolset:).messages)
    end

    def poisoned_results
      Lain::Effect::Handler::Mock.new { |effect, _| Lain::Tool::Result.ok("poison #{effect.tool_use_id}") }
    end

    context "when the tool results cannot be committed" do
      let(:raised) { [] }
      let(:torn) do
        agent([tool_response(["tu_1", "echo", { "text" => "a" }], ["tu_2", "echo", { "text" => "b" }]), text_response],
              handler: poisoned_results,
              timeline: CoreGraph.timeline(store: UncommittableResults::Store.new("poison")))
      end

      before do
        torn.ask("hi")
      rescue Lain::Error => e
        raised << e
      end

      it "lets the commit's own refusal through to the caller" do
        expect(raised.map(&:message)).to eq([UncommittableResults::Store::REFUSAL])
      end

      it "heads the timeline with a user turn answering every call with the errored notice" do
        head = torn.timeline.head

        expect(torn.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
        expect(head.content.map { |block| block["tool_use_id"] }).to eq(%w[tu_1 tu_2])
        expect(head.content.map { |block| block["content"] })
          .to all(eq(Lain::Tool::Cancellation::NOTICES.fetch(:errored)))
      end

      it "carries none of the original result content" do
        expect(JSON.generate(torn.timeline.head.content)).not_to include("poison")
      end

      it "leaves a conversation the Messages API check finds no violation in" do
        expect(conversation_of(torn).violations).to be_empty
      end
    end

    # A repair runs on the way out of another failure, so its own failure must
    # never be what the caller sees: the original goes through, and the head is
    # left for the next ask to answer.
    context "when the repair is refused too" do
      let(:notice) { Lain::Tool::Cancellation::NOTICES.fetch(:errored) }
      let(:store) { UncommittableResults::Store.new("poison", notice) }
      let(:doubly_torn) do
        agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response("after")],
              handler: poisoned_results, timeline: CoreGraph.timeline(store:))
      end

      it "lets the original refusal reach the caller, and the next ask answers the call once" do
        expect { doubly_torn.ask("hi") }.to raise_error(Lain::Error, UncommittableResults::Store::REFUSAL)
        expect(Lain::Event.pending_tool_use?(doubly_torn.timeline.head)).to be(true)

        doubly_torn.ask("again")

        expect(doubly_torn.timeline.to_a.map(&:role)).to eq(%w[user assistant user user assistant])
        expect(conversation_of(doubly_torn).violations).to be_empty
        expect(store.refusals).to eq(["poison", notice])
      end

      it "still surfaces the budget refusal when the budget stop's repair is refused" do
        over = agent(Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                                    "input" => { "text" => "x" } }],
                                        stop_reason: :tool_use,
                                        usage: Lain::Usage.new(input_tokens: 100, output_tokens: 100)),
                     budget: Lain::Budget.ceilings(tokens: 50),
                     timeline: CoreGraph.timeline(store: UncommittableResults::Store.new(notice)))

        expect { over.ask("hi") }.to raise_error(Lain::Budget::Exceeded)
        expect(Lain::Event.pending_tool_use?(over.timeline.head)).to be(true)
      end
    end

    context "when the head is an assistant tool_use nobody answered" do
      let(:stranded) do
        CoreGraph.timeline
                 .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                 .commit(role: :assistant, content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                                       "input" => { "text" => "a" } }])
      end
      let(:provider) { CoreGraph.provider(text_response("fresh")) }
      let(:resumed) { described_class.new(provider:, toolset:, context:, timeline: stranded) }

      it "sends a tool_result for that call before the new user text" do
        resumed.ask("something new")

        blocks = provider.last_request.messages.flat_map { |message| message["content"] }
        answer = blocks.index { |block| block["type"] == "tool_result" && block["tool_use_id"] == "tu_1" }
        asked = blocks.index { |block| block["text"] == "something new" }
        expect(answer).to be < asked
        expect(Lain::Context::Conversation.new(provider.last_request.messages).violations).to be_empty
      end

      it "answers it with the same blocks a loaded session is repaired with" do
        resumed.ask("something new")

        expect(resumed.timeline.to_a[2].content).to eq(Lain::CLI::Resume::Cancellation.new(stranded.head).blocks)
      end

      it "leaves a settled head alone" do
        settled = agent(text_response("again"))
        settled.ask("one")
        before = settled.timeline.to_a.map(&:digest)

        settled.ask("two")

        expect(settled.timeline.to_a.map(&:digest).first(2)).to eq(before)
        expect(settled.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
      end
    end

    context "when the token budget is exceeded by the turn that emits a tool_use" do
      let(:over_budget) do
        agent(Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                             "input" => { "text" => "x" } }],
                                 stop_reason: :tool_use, usage: Lain::Usage.new(input_tokens: 100, output_tokens: 100)),
              budget: Lain::Budget.ceilings(tokens: 50))
      end

      it "stops with the budget refusal and a head that answers the call" do
        expect { over_budget.ask("hi") }.to raise_error(Lain::Budget::Exceeded)

        expect(over_budget.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
        expect(over_budget.timeline.head.content)
          .to eq(Lain::Tool::Cancellation.new(over_budget.timeline.to_a[1], kind: :errored).blocks)
        expect(conversation_of(over_budget).violations).to be_empty
      end
    end
  end

  describe "gate 3: a raising tool becomes an error result, and the loop continues" do
    it "reports is_error and keeps going" do
      a = agent([tool_response(["tu_1", "boom", {}]), text_response("recovered")])
      response = a.ask("hi")

      result_block = a.timeline.to_a[2].content.first
      expect(result_block["is_error"]).to be(true)
      expect(result_block["content"]).to include("kaboom")
      expect(response.text).to eq("recovered")
      expect(a).to be_done
    end

    it "reports an unknown tool as an error rather than crashing" do
      a = agent([tool_response(["tu_1", "nonexistent", {}]), text_response])
      a.ask("hi")

      expect(a.timeline.to_a[2].content.first["is_error"]).to be(true)
      expect(a).to be_done
    end
  end

  describe "gate 6: stop_reason handling is total" do
    it "settles done on end_turn" do
      expect(agent(text_response).tap { |a| a.ask("hi") }).to be_done
    end

    # Easy to forget, and it really does occur.
    it "settles done on stop_sequence" do
      a = agent(text_response("x", stop_reason: :stop_sequence))
      a.ask("hi")
      expect(a).to be_done
    end

    it "fails on refusal, recording why" do
      a = agent(text_response("", stop_reason: :refusal))
      response = a.ask("hi")
      expect(a).to be_failed
      expect(response.failure.message).to include("refused")
    end

    it "fails on max_tokens" do
      a = agent(text_response("", stop_reason: :max_tokens))
      response = a.ask("hi")
      expect(a).to be_failed
      expect(response.failure.message).to include("max_tokens")
    end

    describe "a reply cut off before the model finished" do
      let(:cut_text) { "The reply was cut off before the model finished." }
      let(:full_text) { "The reply filled the context window before the model finished." }

      def cut_off(stop_reason, blocks)
        Lain::Response.new(content: blocks, stop_reason:)
      end

      def sent_blocks(provider) = provider.last_request.messages.flat_map { |message| message["content"] }

      it "keeps the fragment, marks the turn, and ends its content on the marker" do
        a = agent(cut_off(:truncated, [{ "type" => "text", "text" => "partial answ" }]))
        a.ask("hi")

        expect(a.timeline.head.content).to eq([{ "type" => "text", "text" => "partial answ" },
                                               { "type" => "text", "text" => cut_text }])
        expect(a.timeline.head.meta).to eq({ "stop_reason" => "truncated" })
      end

      it "says the window filled when the stop was :context_full" do
        a = agent(cut_off(:context_full, [{ "type" => "text", "text" => "partial" }]))
        a.ask("hi")

        expect(a.timeline.head.content.last).to eq({ "type" => "text", "text" => full_text })
        expect(a.timeline.head.meta).to eq({ "stop_reason" => "context_full" })
      end

      it "tells the model on the next request, after the fragment" do
        provider = CoreGraph.provider(cut_off(:truncated, [{ "type" => "text", "text" => "partial answ" }]),
                                      text_response("fine"))
        a = described_class.new(provider:, toolset:, context:)
        a.ask("hi")
        a.ask("again")

        texts = sent_blocks(provider).filter_map { |block| block["text"] }
        expect(texts).to eq(["hi", "partial answ", cut_text, "again"])
      end

      it "leaves a complete reply and its meta alone" do
        a = agent(text_response("whole"))
        a.ask("hi")

        expect(a.timeline.head.content).to eq([{ "type" => "text", "text" => "whole" }])
        expect(a.timeline.head.meta).to eq({})
      end

      [nil, ""].each do |id|
        it "drops a cut-off tool call with id #{id.inspect}, so the next ask still reaches the provider" do
          provider = CoreGraph.provider(cut_off(:truncated, [{ "type" => "text", "text" => "part" },
                                                             { "type" => "tool_use", "id" => id, "name" => "echo",
                                                               "input" => {} }]),
                                        text_response("fine"))
          a = described_class.new(provider:, toolset:, context:)
          a.ask("hi")

          expect(a.timeline.head.content.map { |block| block["type"] }).to eq(%w[text text])
          expect(a.ask("again").text).to eq("fine")
          expect(provider.call_count).to eq(2)
        end
      end

      it "answers a tool call in a cut-off reply so the next request is well formed" do
        provider = CoreGraph.provider(cut_off(:truncated, [{ "type" => "tool_use", "id" => "toolu_1",
                                                             "name" => "echo", "input" => { "text" => "x" } }]),
                                      text_response("fine"))
        a = described_class.new(provider:, toolset:, context:)
        a.ask("hi")
        a.ask("again")

        result = sent_blocks(provider).find { |block| block["type"] == "tool_result" }
        expect(result).to include("tool_use_id" => "toolu_1", "is_error" => true)
        expect(result["content"]).to include("cut off").and include("never ran")
        expect(Lain::Context::Conversation.new(provider.last_request.messages).violations).to be_empty
      end
    end

    # The wire enums are non-exhaustive. An unrecognized value must fail loudly,
    # not fall through a `case` and quietly do nothing.
    it "fails on an unrecognized stop_reason" do
      a = agent(Lain::Response.new(content: [], stop_reason: "something_new_in_2027"))
      response = a.ask("hi")
      expect(a).to be_failed
      expect(response.failure.message).to include("unrecognized")
    end

    # The one failing reason no wire ever sends: a provider's reading that a
    # cleanly decoded turn is unusable -- a tool call written as prose, or a
    # reply that said nothing at all. The loop must fail it rather than settle
    # it as an answer, and the diagnostic points at the journal record because
    # that is where the evidence for which reading it was lives.
    it "fails on malformed, pointing at the journal record that holds the evidence" do
      a = agent(Lain::Response.new(content: [], stop_reason: :malformed))
      response = a.ask("hi")
      expect(a).to be_failed
      expect(response.failure.message).to include("malformed_response journal record")
    end

    # A server-side tool is mid-flight; resend and let it continue.
    it "re-requests on pause_turn rather than settling" do
      provider = CoreGraph.provider(text_response("", stop_reason: :pause_turn), text_response("finished"))
      a = described_class.new(provider:, toolset:, context:)
      response = a.ask("hi")

      expect(provider.call_count).to eq(2)
      expect(response.text).to eq("finished")
      expect(a).to be_done
    end
  end

  describe "gate 7: the loop is bounded" do
    it "raises once max_iterations is reached" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "loop" }])],
                budget: Lain::Budget.ceilings(iterations: 3))
      expect { a.ask("hi") }.to raise_error(Lain::Budget::Exceeded, /3 iterations/)
    end

    it "raises once the token ceiling is passed" do
      usage = Lain::Usage.new(input_tokens: 100, output_tokens: 100)
      a = agent([Lain::Response.new(content: [], stop_reason: :end_turn, usage:)],
                budget: Lain::Budget.ceilings(tokens: 50))
      expect { a.ask("hi") }.to raise_error(Lain::Budget::Exceeded, /ceiling is 50/)
    end

    it "bounds the session's tokens across asks, naming tokens" do
      reply = ->(output) { Lain::Response.new(content: [], stop_reason: :end_turn, usage: Lain::Usage.new(output_tokens: output)) }
      a = agent([reply.call(20), reply.call(20), reply.call(20)], budget: Lain::Budget.ceilings(tokens: 50))
      a.ask("one")
      a.ask("two")

      expect { a.ask("three") }
        .to raise_error(Lain::Budget::Exceeded, "spent 60 tokens, ceiling is 50") { |error| expect(error.kind).to eq(:tokens) }
    end

    it "names iterations on the refusal that bounds an ask" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "loop" }])], budget: Lain::Budget.ceilings(iterations: 3))

      expect { a.ask("hi") }.to raise_error(Lain::Budget::Exceeded) { |error| expect(error.kind).to eq(:iterations) }
    end

    # A budget stop is the harness's decision, not the model's output; a refusal
    # is the opposite. They must not be conflated.
    it "does not conflate a budget stop with a refusal" do
      a = agent(text_response("", stop_reason: :refusal))
      expect { a.ask("hi") }.not_to raise_error
      expect(a).to be_failed
    end

    # From manual-QA round 4. The counter was seeded once per Agent and never
    # reset, so the ceiling that names itself "loop ran N iterations" was in
    # fact a whole-session budget: 25 model calls spread over nine prompts
    # exhausted it, and every prompt after that was committed as a user turn and
    # then raised on before the provider was ever asked -- a session that keeps
    # accepting input and can no longer answer any of it.
    describe "the ceiling bounds ONE ask, not the session" do
      # Two iterations per ask: the tool call, then the text that settles it.
      def settling_pair(text) = [tool_response(["tu_1", "echo", { "text" => "loop" }]), text_response(text)]

      it "starts a fresh count on an ask that follows one which ran to the ceiling" do
        a = agent(settling_pair("first") + settling_pair("second"),
                  budget: Lain::Budget.ceilings(iterations: 2))

        expect(a.ask("one").text).to eq("first")
        expect(a.ask("two").text).to eq("second")
        expect(a.iterations).to eq(2)
      end

      # The reset is not a reprieve: the ceiling still bounds the ask it belongs
      # to, whatever ran before it.
      it "still stops a single ask at the ceiling, however many asks preceded it" do
        a = agent(settling_pair("first") + [tool_response(["tu_2", "echo", { "text" => "forever" }])],
                  budget: Lain::Budget.ceilings(iterations: 2))
        a.ask("one")

        expect { a.ask("two") }
          .to raise_error(Lain::Budget::Exceeded, "loop ran 2 iterations, ceiling is 2")
      end

      # The silent-swallow half. A refused ask says which ceiling stopped it
      # (the message {CLI::Repl#respond} renders), and the NEXT prompt reaches
      # the provider instead of dying on arrival.
      it "names the ceiling that stopped the run, then answers the next prompt" do
        looping = tool_response(["tu_1", "echo", { "text" => "loop" }])
        provider = CoreGraph.provider(looping, looping, looping, text_response("recovered"))
        a = described_class.new(provider:, toolset:, context:,
                                budget: Lain::Budget.ceilings(iterations: 2))

        expect { a.ask("one") }
          .to raise_error(Lain::Budget::Exceeded, "loop ran 2 iterations, ceiling is 2")
        expect(a.ask("two").text).to eq("recovered")
        expect(provider.call_count).to eq(4)
      end
    end
  end

  describe "#room" do
    # Reads the agent's room while its tool runs, which is when a spawn asks.
    def room_reader(seen, agent_ref)
      Class.new(Lain::Tool) do
        define_method(:name) { "room" }
        define_method(:description) { "Reads the room." }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) { |_input, _context| Lain::Tool::Result.ok(seen.push(agent_ref.call.room).size.to_s) }
      end.new
    end

    def spending(output) = Lain::Usage.new(output_tokens: output)

    it "answers mid-ask the iterations this ask has left and the tokens the run has left" do
      seen = []
      a = nil
      call = { "type" => "tool_use", "id" => "r1", "name" => "room", "input" => {} }
      responses = [Lain::Response.new(content: [call], stop_reason: :tool_use, usage: spending(30)),
                   text_response("done")]
      a = described_class.new(provider: CoreGraph.provider(*responses), context:,
                              toolset: CoreGraph.toolset([room_reader(seen, -> { a })]),
                              budget: Lain::Budget.ceilings(iterations: 10, tokens: 100).with(depth: 2))

      a.ask("go")

      expect(seen.map { |room| [room.iterations, room.tokens, room.depth] }).to eq([[9, 70, 2]])
    end

    # A role spawn between asks must not inherit the count of the ask that
    # ended: the next ask starts its own.
    it "answers idle the whole iteration ceiling, after an ask that used most of it" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "x" }]), tool_response(["tu_2", "echo", { "text" => "y" }]),
                 text_response("done", usage: spending(40))],
                budget: Lain::Budget.ceilings(iterations: 3, tokens: 100))

      a.ask("go")

      expect([a.room.iterations, a.room.tokens]).to eq([3, 60])
    end
  end

  describe "turn usage accounting" do
    let(:journal_io) { StringIO.new }
    let(:journal) { Lain::Journal.new(io: journal_io) }

    def turn_usage_records
      journal_io.string.each_line
                .map { |line| JSON.parse(line) }
                .select { |record| record["type"] == "turn_usage" }
    end

    it "journals exactly one turn_usage record, attributed to the committed assistant turn" do
      usage = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
      a = agent(Lain::Response.new(content: [{ "type" => "text", "text" => "hello" }],
                                   stop_reason: :end_turn, model: "claude-opus-4-8", usage:),
                journal:)
      a.ask("hi")

      expect(turn_usage_records.size).to eq(1)
      expect(journal_io).to include_journal_record(
        "turn_usage",
        digest: a.timeline.head_digest,
        model: "claude-opus-4-8",
        stop_reason: "end_turn",
        usage: { "input_tokens" => 10, "output_tokens" => 5,
                 "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 }
      )
    end

    it "journals one record per MODEL call in a tool loop, none for the tool_result user turn" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "x" }]), text_response],
                journal:)
      a.ask("hi")

      assistant_digests = a.timeline.to_a.select { |turn| turn.role == "assistant" }.map(&:digest)
      records = turn_usage_records
      expect(records.size).to eq(2)
      expect(records.map { |record| record["digest"] }).to eq(assistant_digests)
      expect(records.map { |record| record["digest"] }.uniq.size).to eq(2)
    end

    # Regenerating an identical turn after a rewind pays twice and must be
    # counted twice (see Telemetry::TurnUsage: the digest is a join key).
    it "journals one record per PAYMENT: rewind plus identical regeneration duplicates the digest" do
      usage = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
      same_answer = lambda do
        Lain::Response.new(content: [{ "type" => "text", "text" => "same answer" }],
                           stop_reason: :end_turn, usage:)
      end
      a = agent([same_answer.call, same_answer.call], journal:)
      a.ask("hi")
      a.rewind(1)
      a.run

      records = turn_usage_records
      expect(records.size).to eq(2)
      expect(records.map { |record| record["digest"] }.uniq.size).to eq(1)
      expect(a.usage).to eq(usage + usage)
    end

    it "keeps turn digests content-only: no usage or model in meta, identical content hashes identically" do
      content = [{ "type" => "text", "text" => "same answer" }]
      cheap = agent(Lain::Response.new(content:, stop_reason: :end_turn,
                                       usage: Lain::Usage.new(input_tokens: 1, output_tokens: 1)))
      pricey = agent(Lain::Response.new(content:, stop_reason: :end_turn,
                                        model: "claude-opus-4-8",
                                        usage: Lain::Usage.new(input_tokens: 900, output_tokens: 900)))
      cheap.ask("hi")
      pricey.ask("hi")

      expect(cheap.timeline.head.meta).to eq({})
      expect(cheap.timeline.head_digest).to eq(pricey.timeline.head_digest)
    end

    it "delegates accumulation to Accounting: usage is the monoid sum of every response's usage" do
      first = Lain::Usage.new(input_tokens: 10, output_tokens: 5)
      second = Lain::Usage.new(input_tokens: 7, output_tokens: 3)
      a = agent([Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                                "input" => { "text" => "x" } }],
                                    stop_reason: :tool_use, usage: first),
                 Lain::Response.new(content: [], stop_reason: :end_turn, usage: second)])
      a.ask("hi")

      expect(a.usage).to eq(first + second)
    end

    it "retains an over-budget turn in the Timeline and journals its usage before raising" do
      usage = Lain::Usage.new(input_tokens: 100, output_tokens: 100)
      a = agent(Lain::Response.new(content: [{ "type" => "text", "text" => "expensive" }],
                                   stop_reason: :end_turn, usage:),
                budget: Lain::Budget.ceilings(tokens: 50),
                journal:)

      expect { a.ask("hi") }.to raise_error(Lain::Budget::Exceeded)
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(turn_usage_records.size).to eq(1)
      expect(turn_usage_records.first["digest"]).to eq(a.timeline.head_digest)
    end
  end

  # The one number a chat status line wants -- how full the context is right
  # now -- read off the SAME last-turn usage the compaction trigger measures,
  # through the same window book.
  describe "#occupancy" do
    def spent(input) = text_response("hello", usage: Lain::Usage.new(input_tokens: input, output_tokens: 1))

    it "is nil before any turn: absence, not an empty context" do
      expect(agent(text_response).occupancy).to be_nil
    end

    it "reports the last turn's input tokens as a fraction of the model's window" do
      a = agent(spent(4096))
      a.ask("hi")

      expect(a.occupancy(context_window: Lain::ContextWindow.new(windows: { "opus" => 8192 }))).to eq(0.5)
    end

    it "measures the LAST turn, not the run's cumulative input" do
      first = Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                             "input" => { "text" => "x" } }],
                                 stop_reason: :tool_use,
                                 usage: Lain::Usage.new(input_tokens: 4096, output_tokens: 1))
      a = agent([first, spent(2048)])
      a.ask("hi")

      expect(a.occupancy(context_window: Lain::ContextWindow.new(windows: { "opus" => 8192 }))).to eq(0.25)
    end

    context "with a /model switch made" do
      let(:switch) { Lain::Context::ModelSwitch.new("qwen3:4b", journal: Lain::Journal.new(io: StringIO.new)) }
      let(:context) { CoreGraph.context(model: "qwen3:4b").with_model(switch) }

      it "withholds the usage an earlier model earned until the new model replies" do
        a = agent([spent(4096), spent(2048)])
        a.ask("hi")
        switch.switch("qwen3-coder:30b", surface: "tty")

        expect(a.occupancy).to be_nil
        a.ask("again")
        expect(a.occupancy).to eq(0.25)
      end
    end

    context "with a model the default book does not carry" do
      let(:context) { CoreGraph.context(model: "qwen3:4b") }

      # An Agent built with no book of its own. `ContextWindow.default`'s
      # conservative fallback is the honest answer for a caller that named no
      # window -- a wired chat is handed the provider-derived book instead
      # ({CLI::Backend#context_window}), which is the example below.
      it "measures against the conservative fallback window" do
        a = agent(spent(4096))
        a.ask("hi")

        expect(a.occupancy).to eq(0.5)
      end

      # The book is CONSTRUCTOR state, not a per-call default, because the
      # one caller that renders this figure to a human --
      # {Frontend::PromptComposer::RunState#occupancy} -- calls it with no
      # keyword at all. Left as a per-call default, the REPL prompt divided by
      # 8,192 while `.lain/state.json` divided by the served window, and the two
      # surfaces disagreed about the same turn.
      it "measures against the book it was CONSTRUCTED with, for a caller that passes none" do
        a = agent(spent(4096), context_window: Lain::ContextWindow.new(windows: { "qwen3" => 32_768 }))
        a.ask("hi")

        expect(a.occupancy).to eq(4096.fdiv(32_768))
      end

      # The keyword stays, and still wins: a bench arm measuring one run against
      # several candidate windows asks the same Agent more than once.
      it "still lets an explicit book override the one it was constructed with" do
        a = agent(spent(4096), context_window: Lain::ContextWindow.new(windows: { "qwen3" => 32_768 }))
        a.ask("hi")

        expect(a.occupancy(context_window: Lain::ContextWindow.new(windows: { "qwen3" => 8192 }))).to eq(0.5)
      end
    end

    # The reader is as loud as the book it asks, and this is PART of its
    # published contract: the prompt composer renders it per prompt, so a
    # caller that cannot afford a raise on a blank model slot has to know it
    # can happen rather than discovering it as a REPL crash.
    context "with a blank model slot" do
      let(:context) { CoreGraph.context(model: "  ") }

      it "raises UnknownModel rather than reporting an occupancy nobody chose" do
        expect { agent(text_response).occupancy }
          .to raise_error(Lain::ContextWindow::UnknownModel, /wiring bug/)
      end
    end
  end

  describe "state machine" do
    it "starts awaiting_user" do
      expect(agent(text_response).state).to eq(:awaiting_user)
    end

    it "exposes every declared state" do
      # :stalled is the additive dual-ledger state (see LoopMachine); the
      # transition-legality gates (agent_state_machine_spec's StopReason
      # totality + Response::Failure) are untouched -- this is a state-set snapshot
      # that grows with an authorized addition, like the generated diagram.
      expect(described_class::STATES)
        .to contain_exactly(:awaiting_user, :awaiting_model, :awaiting_tools,
                            :awaiting_approval, :stalled, :done, :failed)
    end

    # The settled half of the state set, homed here beside STATES rather than
    # copied into each reader that needs it -- {CLI::ResendBridge} gates its
    # resend on it, and it was defined there and here independently before
    # anyone noticed. One definition is the point of the example.
    it "names the settled states, excluding the mid-run parks" do
      expect(described_class::QUIESCENT).to contain_exactly(:awaiting_user, :done, :failed)
    end

    it "names only states the machine declares" do
      expect(described_class::STATES).to include(*described_class::QUIESCENT)
    end

    # A loop that is merely PARKED is not settled: :stalled awaits a replan and
    # :awaiting_approval awaits a gate decision, and a run resumes from both.
    it "excludes the parks a run resumes from" do
      expect(described_class::QUIESCENT).not_to include(:stalled, :awaiting_approval)
    end
  end

  # {#state} records what the loop was last DOING; this answers whether a
  # dispatch is in flight. They disagree exactly when a turn is torn, which is
  # the case the prompt line reads it for.
  describe "#dispatching?" do
    it "is false on a fresh agent" do
      expect(agent(text_response).dispatching?).to be(false)
    end

    it "is true while the dispatch lock is held" do
      subject = agent(text_response)

      expect(subject.dispatch_lock.synchronize { subject.dispatching? }).to be(true)
    end

    it "is true while another thread holds the lock" do
      subject = agent(text_response)
      held = Queue.new
      release = Queue.new
      worker = Thread.new { subject.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop

      expect(subject.dispatching?).to be(true)

      release.push(:go)
      worker.join
    end

    # The torn turn. `Monitor#synchronize` releases on the way out of a raise,
    # so this answers false while `#state` is still parked at :awaiting_model --
    # which is the whole reason the prompt line reads this and not the state.
    it "is false after a run raises out, though the state is still busy" do
      exploding = Class.new(Lain::Provider) do
        def capabilities = []
        def cache_profile = Lain::CacheProfile::NO_CACHING
        def encode(request) = request.cache_payload
        def complete(*, **) = raise(Lain::Error, "connection reset by peer")
      end.new
      subject = described_class.new(provider: exploding, toolset: CoreGraph.toolset([]),
                                    context: CoreGraph.context(model: "opus", max_tokens: 64))
      expect { subject.ask("hi") }.to raise_error(Lain::Error)

      expect(subject.state).to eq(:awaiting_model)
      expect(subject.dispatching?).to be(false)
    end
  end

  # Whether a model call or a tool is running, read by a line the human types
  # mid-run: a note while it is, the next prompt once the run's final reply has
  # committed, though the run still holds the dispatch lock while it tears down.
  describe "#working?" do
    it "is false on a fresh agent" do
      expect(agent(text_response).working?).to be(false)
    end

    it "is true during each model call and while a tool runs, and false once the final reply commits" do
      readings = []
      subject = nil
      reading = ->(label) { readings << [label, subject.working?] }
      provider = Class.new(Lain::Provider::Mock) do
        define_method(:complete) { |request, **opts| reading.call(:model) && super(request, **opts) }
      end.new(responses: [tool_response(["tu_1", "echo", { "text" => "a" }]), text_response("done")])
      tool = EchoTool.new
      tool.define_singleton_method(:perform) { |input, ctx| reading.call(:tool) && super(input, ctx) }
      journal = Class.new do
        define_method(:<<) do |record|
          reading.call(record.stop_reason) if record.is_a?(Lain::Telemetry::TurnUsage)
        end
      end.new
      subject = described_class.new(provider:, toolset: CoreGraph.toolset([tool]), context:, journal:)

      subject.ask("hi")

      expect(readings).to eq([[:model, true], [:tool_use, true], [:tool, true], [:model, true], [:end_turn, false]])
      expect(subject.working?).to be(false)
    end

    it "is false after a run raises out, though the state is still busy" do
      exploding = Class.new(Lain::Provider) do
        def capabilities = []
        def cache_profile = Lain::CacheProfile::NO_CACHING
        def encode(request) = request.cache_payload
        def complete(*, **) = raise(Lain::Error, "connection reset by peer")
      end.new
      subject = described_class.new(provider: exploding, toolset: CoreGraph.toolset([]),
                                    context: CoreGraph.context(model: "opus", max_tokens: 64))
      expect { subject.ask("hi") }.to raise_error(Lain::Error)

      expect(subject.working?).to be(false)
    end
  end

  # Pin the Agent's existing Timeline injection seam (agent.rb:71,84) --
  # `timeline: nil` already defaults to a fresh Timeline, so passing one in is
  # already "resume from here". Subagent#spawn_agent is the production caller
  # (lib/lain/tools/subagent.rb:222); these examples pin the behavior it
  # depends on before anything builds further on it. Spec-only: no lib change.
  describe "an injected Timeline" do
    let(:seeded_store) { CoreGraph.store }

    def committed(store, *turns)
      turns.inject(CoreGraph.timeline(store:)) do |timeline, (role, text)|
        timeline.commit(role:, content: [{ "type" => "text", "text" => text }])
      end
    end

    # Ends on an answered turn: a seed ending on an unanswered prompt is a
    # stranded one, which the next ask folds rather than renders beside.
    def seed(store)
      committed(store, [:user, "first"], [:assistant, "ack"], [:user, "second"], [:assistant, "again"])
    end

    it "is the starting state: the request renders every seeded turn before the new user turn" do
      provider = CoreGraph.provider(text_response("hello"))
      a = described_class.new(provider:, toolset:, context:, timeline: seed(seeded_store))
      a.ask("hi")

      rendered = provider.last_request.messages
      expect(rendered.map { |message| message["role"] }).to eq(%w[user assistant user assistant user])
      # The content sequence is the pin: seeded turns share roles, so the role
      # sequence alone would not catch a transposition of their content.
      expect(rendered.map { |message| message["content"].first["text"] }).to eq(%w[first ack second again hi])
    end

    it "shares its Store with the Agent: subsequent commits land in the same Store, no copy" do
      a = agent(text_response("hello"), timeline: seed(seeded_store))
      a.ask("hi")

      expect(a.timeline.store).to be(seeded_store)
    end

    it "resumes an assistant head without inventing a user turn" do
      assistant_head = committed(CoreGraph.store, [:user, "first"], [:assistant, "ack"])

      a = agent(text_response("hello"), timeline: assistant_head)
      a.ask("more")

      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end
  end

  # A provider can refuse a prompt whole for not fitting the context it loaded
  # -- ollama does once it is asked not to truncate -- naming the exact prompt
  # count. No model saw that prompt and nothing was generated, so the ask that
  # sent it leaves the head where it stood, and the count becomes the reading
  # compaction measures the next render against.
  describe "a prompt refused for not fitting the context" do
    let(:refusal_class) { Class.new(Lain::Error) { include Lain::WindowExceeded } }
    let(:book) { Lain::ContextWindow.new(windows: { "opus" => 8192 }) }

    def refusal = refusal_class.new("too long", prompt_tokens: 12_011, window_tokens: 8192, source: "spec")

    # Answers each call with the next outcome, raising the ones that are errors.
    def scripted(*outcomes)
      Class.new do
        define_method(:initialize) { |list| @list = list }
        define_method(:complete) do |_request|
          outcome = @list.shift || raise("script exhausted")
          outcome.is_a?(Exception) ? raise(outcome) : outcome
        end
      end.new(outcomes)
    end

    def agent_over(*outcomes) = described_class.new(provider: scripted(*outcomes), toolset:, context:)

    it "refuses the ask with the provider's refusal, so the caller can say it" do
      a = agent_over(text_response("hello"), refusal)
      a.ask("hi")

      expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)
    end

    it "leaves the head where it stood before the refused prompt, keeping the turn in the store" do
      a = agent_over(text_response("hello"), refusal)
      a.ask("hi")
      head = a.timeline.head_digest
      stored = a.timeline.store.size

      expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)

      expect(a.timeline.head_digest).to eq(head)
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(a.timeline.store.size).to be > stored
    end

    it "answers the next prompt on top of the head the refusal left, with no refused turn stacked under it" do
      a = agent_over(text_response("hello"), refusal, text_response("answered"))
      a.ask("hi")
      expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)

      expect(a.ask("a shorter one").text).to eq("answered")
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
      expect(a.timeline.to_a[2].content.first["text"]).to eq("a shorter one")
    end

    it "takes the refused prompt's exact count as the reading" do
      a = agent_over(text_response("hello", usage: Lain::Usage.new(input_tokens: 4096, output_tokens: 1)), refusal)
      a.ask("hi")
      expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)

      expect(a.occupancy(context_window: book)).to eq(12_011.fdiv(8192))
    end

    # The tool round before the refusal RAN, and its results are what the model
    # asked for: moving the head back past them would unsay work that happened.
    # Only the prompt this ask added is withdrawn, and only while it is still
    # the head.
    it "keeps a tool round that ran before a refusal later in the same ask" do
      a = agent_over(tool_response(["tu_1", "echo", { "text" => "a" }]), refusal)

      expect { a.ask("hi") }.to raise_error(refusal_class)

      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
    end

    it "leaves any other failure's prompt committed, as it always has" do
      a = agent_over(Lain::Error.new("provider down"))

      expect { a.ask("hi") }.to raise_error(Lain::Error, "provider down")
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user])
    end

    # The refusal's words say whether the prompt was taken back, and only the
    # Agent knows: a refusal after a tool round leaves the prompt where it was.
    it "tells the refusal it withdrew the prompt, and only when it did" do
      withdrawn = refusal
      kept = refusal
      expect { agent_over(withdrawn).ask("hi") }.to raise_error(withdrawn)
      expect { agent_over(tool_response(["tu_1", "echo", { "text" => "a" }]), kept).ask("hi") }.to raise_error(kept)

      expect(withdrawn).to be_withdrawn
      expect(kept).not_to be_withdrawn
    end

    # When no cut can make room, the compaction source replaces the history
    # before the current ask with one state document -- and THIS render is then
    # worth sending again, because it is the first render that fits. There is
    # no estimate before the send, so the refusal is what triggers it.
    describe "when a handoff makes room" do
      def handing_off(*answers) = A1PipelineSources::HandingOff.new(*answers)

      def agent_with(source, *outcomes)
        described_class.new(provider: scripted(*outcomes), toolset:, context:, pipeline_source: source)
      end

      it "retries the refused render once and answers the ask" do
        source = handing_off(true)
        a = agent_with(source, refusal, text_response("answered"))

        expect(a.ask("a prompt that does not fit").text).to eq("answered")
        expect(source.calls.size).to eq(1)
        expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      end

      it "hands the source the chain the refused render stood on, and the run's session" do
        source = handing_off(true)
        a = agent_with(source, refusal, text_response("answered"))
        a.ask("a prompt that does not fit")

        expect(source.calls.last[:session]).to be(a.session)
        expect(source.calls.last[:timeline].head_digest).to eq(a.timeline.rewind(1).head_digest)
      end

      # A second refusal is the ask failing: there is nothing further to
      # replace, so it withdraws and is worded like any other over-window
      # refusal rather than looping.
      it "refuses on a second refusal rather than handing off again" do
        source = handing_off(true, true)
        a = agent_with(source, refusal, refusal)

        expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)
        expect(source.calls.size).to eq(1)
        expect(a.timeline.to_a).to be_empty
      end

      it "still withdraws the prompt when the retry is refused too" do
        withdrawn = refusal
        expect { agent_with(handing_off(true), withdrawn, withdrawn).ask("hi") }.to raise_error(withdrawn)

        expect(withdrawn).to be_withdrawn
      end

      it "does not retry when no handoff could be committed" do
        source = handing_off(false)
        a = agent_with(source, refusal, text_response("never sent"))

        expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)
        expect(source.calls.size).to eq(1)
      end

      # The refusal's exact count is the reading compaction measures against,
      # and the RETRY's refusal carries its own: a retry that did not observe
      # its own count would leave the reading describing a prompt the handoff
      # has already replaced. Driven over a chain the ask cannot withdraw --
      # a tool round ran -- so the reading survives to be read back.
      it "takes the retry's own refusal count as the reading" do
        smaller = refusal_class.new("still too long", prompt_tokens: 9001, window_tokens: 8192, source: "spec")
        a = agent_with(handing_off(true), tool_response(["tu_1", "echo", { "text" => "a" }]), refusal, smaller)

        expect { a.ask("hi") }.to raise_error(refusal_class)

        expect(a.occupancy(context_window: book)).to eq(9001.fdiv(8192))
      end
    end

    # A refused render that left something droppable is worth one more
    # render: the refusal's count is now the reading compaction measures, so
    # the next render compacts by itself, inside this ask rather than the
    # next one.
    describe "when an ordinary compaction can make room" do
      def counting(*outcomes)
        Class.new do
          attr_reader :sent

          define_method(:initialize) do |list|
            @list = list
            @sent = 0
          end
          define_method(:complete) do |_request|
            @sent += 1
            outcome = @list.shift || raise("script exhausted")
            outcome.is_a?(Exception) ? raise(outcome) : outcome
          end
        end.new(outcomes)
      end

      def agent_with(source, *outcomes)
        provider = counting(*outcomes)
        [described_class.new(provider:, toolset:, context:, pipeline_source: source), provider]
      end

      it "re-renders once and answers the ask, with 2 requests sent" do
        a, provider = agent_with(A1PipelineSources::HandingOff.new(false, droppable: true),
                                 refusal, text_response("answered"))

        expect(a.ask("a prompt that does not fit").text).to eq("answered")
        expect(provider.sent).to eq(2)
        expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      end

      it "hands off on the re-render's refusal and answers the ask" do
        source = A1PipelineSources::HandingOff.new(false, true, droppable: true)
        a, provider = agent_with(source, refusal, refusal, text_response("answered"))

        expect(a.ask("a prompt that does not fit").text).to eq("answered")
        expect(provider.sent).to eq(3)
        expect(source.calls.size).to eq(2)
      end

      it "raises the refusal when the re-render is refused and no handoff can be made" do
        a, provider = agent_with(A1PipelineSources::HandingOff.new(droppable: true),
                                 refusal, refusal, text_response("never sent"))

        expect { a.ask("a prompt that does not fit") }.to raise_error(refusal_class)
        expect(provider.sent).to eq(2)
        expect(a.timeline.to_a).to be_empty
      end

      # Something droppable says nothing about whether the next render drops
      # it: a guessed window withholds the signal, and a floor refuses a
      # rewrite that would not shrink. Sending the same bytes again buys only
      # the same refusal.
      it "sends nothing more when the re-render comes out byte for byte the refused request" do
        refused = refusal
        a, provider = agent_with(A1PipelineSources::HandingOff.new(droppable: true, compacts: false),
                                 refused, text_response("never sent"))

        expect { a.ask("a prompt that does not fit") }.to raise_error(refused)
        expect(provider.sent).to eq(1)
        expect(refused).to be_withdrawn
        expect(a.timeline.to_a).to be_empty
      end
    end

    # A request none of whose attempts wrote a byte reached no model either,
    # so it is withdrawn the way an over-window refusal is.
    describe "a failure that provably never reached the wire" do
      let(:unsent_class) { Class.new(Lain::Error) { include Lain::PreWire } }

      def unsent = unsent_class.new("connection refused")

      it "withdraws the prompt, keeping the turn in the store" do
        a = agent_over(text_response("hello"), unsent)
        a.ask("hi")
        head = a.timeline.head_digest
        stored = a.timeline.store.size

        expect { a.ask("never sent") }.to raise_error(unsent_class)

        expect(a.timeline.head_digest).to eq(head)
        expect(a.timeline.store.size).to be > stored
      end

      it "keeps a tool round that ran before it later in the same ask" do
        a = agent_over(tool_response(["tu_1", "echo", { "text" => "a" }]), unsent)

        expect { a.ask("hi") }.to raise_error(unsent_class)

        expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
      end
    end
  end

  # A failure after the wire leaves its prompt committed and unanswered. The
  # next prompt is not stacked on top as a second user turn: both texts go as
  # one turn, cut from the stranded turn's parent, and the stranded turn stays
  # in the Store.
  describe "a prompt stranded by a failure after the wire" do
    def scripted(*outcomes)
      Class.new do
        define_method(:initialize) { |list| @list = list }
        define_method(:complete) do |_request|
          outcome = @list.shift || raise("script exhausted")
          outcome.is_a?(Exception) ? raise(outcome) : outcome
        end
      end.new(outcomes)
    end

    def stranded_agent
      a = described_class.new(provider: scripted(text_response("hello"), Lain::Error.new("stream cut"),
                                                 text_response("answered")), toolset:, context:)
      a.ask("hi")
      expect { a.ask("first") }.to raise_error(Lain::Error, "stream cut")
      a
    end

    it "folds the stranded text and the new text into one user turn" do
      a = stranded_agent

      expect(a.ask("next").text).to eq("answered")

      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
      expect(a.timeline.to_a[2].content.map { |block| block["text"] }).to eq(%w[first next])
    end

    # The caller is handed both chains BEFORE the request is sent, so a record
    # can make the folded turn durable ahead of the wire.
    it "keeps the stranded turn in the store and hands the caller both chains before the request is sent" do
      a = stranded_agent
      stranded = a.timeline
      told = []

      a.ask("next", on_fold: ->(from, to) { told << [from, to, a.timeline] })

      from, to, live = told.fetch(0)
      expect(from).to eq(stranded)
      expect(live).to eq(stranded)
      expect(to.head.parent).to eq(stranded.head.parent)
      expect(a.timeline.to_a[2].digest).to eq(to.head_digest)
      expect(a.timeline.store.fetch(stranded.head_digest)).to eq(stranded.head)
    end

    it "does not fold a head that answers tool calls rather than asks" do
      a = described_class.new(provider: scripted(tool_response(["tu_1", "echo", { "text" => "a" }]),
                                                 Lain::Error.new("stream cut"), text_response("answered")),
                              toolset:, context:)
      expect { a.ask("hi") }.to raise_error(Lain::Error, "stream cut")
      folded = []

      a.ask("next", on_fold: ->(*chains) { folded << chains })

      expect(folded).to be_empty
      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user user assistant])
    end
  end

  describe "#rewind" do
    it "moves the head back and reopens the loop" do
      a = agent([tool_response(["tu_1", "echo", { "text" => "a" }]), text_response])
      a.ask("hi")
      expect(a.timeline.length).to eq(4)

      a.rewind(2)
      expect(a.timeline.length).to eq(2)
      expect(a.state).to eq(:awaiting_user)
    end

    # A run in flight holds a Timeline it will settle onto and hand back, so a
    # head moved under it is re-committed over when the run lands.
    it "refuses while another caller's run is in flight, and moves nothing" do
      a = agent([text_response("one"), text_response("two")])
      a.ask("hi")
      held = Queue.new
      release = Queue.new
      worker = Thread.new { a.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop

      expect { a.rewind(1) }.to raise_error(described_class::InFlight, /in flight/)
      expect(a.timeline.length).to eq(2)
    ensure
      release&.push(:go)
      worker&.join
    end

    # Forced at the instant between the guard and the move: a run that could
    # take the lock there would settle over the head this rewind is moving.
    it "holds the dispatch lock from its guard through the move" do
      store = UncommittableResults::RacedStore.new
      a = agent([text_response("one")], timeline: CoreGraph.timeline(store:))
      a.ask("hi")
      raced = []
      store.arm { raced << Thread.new { a.dispatch_lock.try_enter.tap { |got| a.dispatch_lock.exit if got } }.value }

      a.rewind(1)

      expect(raced).to eq([false])
      expect(a.timeline.length).to eq(1)
    end

    # A resend rewinds from INSIDE the lock it took to make its run exclusive.
    it "moves the head for the caller that holds the dispatch lock itself" do
      a = agent(text_response("one"))
      a.ask("hi")

      a.dispatch_lock.synchronize { a.rewind(1) }

      expect(a.timeline.length).to eq(1)
    end
  end

  describe "the rendered prefix" do
    it "asks its timeline only for the turns after the head it last rendered" do
      provider = CoreGraph.provider(text_response("one"), text_response("two"))
      a = described_class.new(provider:, toolset:, context:)
      asked = []
      trace = TracePoint.new(:call) do |point|
        projecting = point.defined_class == Lain::Timeline && point.method_id == :messages
        asked << point.binding.local_variable_get(:after) if projecting
      end

      trace.enable do
        a.ask("hi")
        a.ask("again")
      end

      expect(asked).to eq([nil, a.timeline.to_a.first.digest])
      expect(provider.last_request.messages.map { |message| message["content"].first["text"] }).to eq(%w[hi one again])
    end
  end

  describe "session threading" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    # The Agent threads ONE session end to end. A read on the first turn is
    # visible to a probe tool that runs on a later turn, through its invocation
    # context -- and that context IS the Agent's own session, not a copy.
    it "hands every tool the same session, with earlier reads already recorded" do
      path = File.join(tmpdir, "read.txt")
      File.write(path, "contents")
      sightings = []
      toolset = CoreGraph.toolset([Lain::Tools::ReadFile.new, ContextProbe.new(sightings)])

      a = described_class.new(
        provider: CoreGraph.provider(
          tool_response(["tu_1", "read_file", { "path" => path }]),
          tool_response(["tu_2", "probe", {}]),
          text_response
        ),
        toolset:,
        context:
      )
      a.ask("please read then probe")

      expect(sightings.last).to be(a.session)
      expect(sightings.last.read?(path)).to be(true)
      expect(a.session.read?(path)).to be(true)
    end

    # A reminder rides the Workspace tail into the Request, and NEVER lands
    # in the Timeline (Workspace is sent, not stored). The Session stays ignorant
    # of Workspace; the Agent composes them per render.
    it "carries a session reminder into the request tail without appending it to the Timeline" do
      reminding = instance_double(Lain::Session, reminders: ["ping the model"])
      provider = CoreGraph.provider(text_response)
      a = described_class.new(provider:, toolset:, context:, session: reminding)
      a.ask("hi")

      tail = provider.last_request.messages.last
      expect(tail["role"]).to eq("user")
      # a_hash_including because CacheBreakpoints stamps "cache" => true on the
      # tail block -- the reminder still rides the last user message.
      expect(tail["content"]).to include(a_hash_including("text" => "<workspace>ping the model</workspace>"))

      timeline_blocks = a.timeline.to_a.flat_map(&:content)
      expect(timeline_blocks.map { |block| block["text"] }).not_to include(/workspace/)
    end
  end

  # The base `@context` is construction-fixed and #render_request always
  # rendered from it, so a strategy that must re-decide EVERY turn (compaction)
  # had nowhere to live. The source is that seam: one message, asked once per
  # render.
  describe "the per-turn Context source" do
    def texts(request) = request.messages.flat_map { |m| m["content"].map { |b| b["text"] } }.compact

    # The default is a real Null Object, so an Agent built without a source
    # sends the bytes its base Context renders -- not "equivalent" bytes.
    it "sends a Request byte-identical to the base Context's own render, with no source wired" do
      provider = CoreGraph.provider(text_response)
      a = described_class.new(provider:, toolset:, context:)
      a.ask("hi")

      direct = context.render(timeline: a.timeline.rewind(1), toolset:, workspace: Lain::Workspace.empty)
      # `eq`, deliberately NOT have_same_digest_as: Request#digest is Canonical
      # over #cache_payload, which by design omits `stream` and `extra`, so two
      # Requests differing in either share a digest. Request is a Data, so
      # value equality covers every field this example claims is identical.
      expect(provider.last_request).to eq(direct)
    end

    it "renders through the Context the source returns, so its pipeline decides what is sent" do
      provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response)
      a = described_class.new(provider:, toolset:, context:,
                              pipeline_source: A1PipelineSources::Pruning.new(keep_last: 2))
      a.ask("hi")

      expect(provider.requests.last.messages.size).to eq(2)
      expect(texts(provider.requests.last)).not_to include("hi")
    end

    # A source consulted once per RUN would answer [1, 1, 1] here; one
    # consulted per RENDER widens with the turn.
    it "is consulted once per render, not once per run" do
      provider = CoreGraph.provider(
        tool_response(["tu_1", "echo", { "text" => "x" }]),
        tool_response(["tu_2", "echo", { "text" => "y" }]),
        text_response
      )
      a = described_class.new(provider:, toolset:, context:, pipeline_source: A1PipelineSources::Widening.new)
      a.ask("hi")

      expect(provider.requests.map { |request| request.messages.size }).to eq([1, 2, 3])
    end

    # `session:` is the parameter this seam exists to place: the Session is
    # built in Wiring and handed to Agent.new separately, so the Agent is the
    # only place it and the base Context both exist. `usage:` is the LAST turn's
    # billed input, not the run's cumulative sum -- nil before any turn, which
    # is distinct from zero on a resumed session.
    it "hands the source the agent's own Session, its base Context, and the last turn's input tokens" do
      first = Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "echo",
                                             "input" => { "text" => "x" } }],
                                 stop_reason: :tool_use,
                                 usage: Lain::Usage.new(input_tokens: 40, output_tokens: 5,
                                                        cache_read_input_tokens: 2))
      provider = CoreGraph.provider(first, text_response)
      recorder = A1PipelineSources::Recording.new
      a = described_class.new(provider:, toolset:, context:, pipeline_source: recorder)
      a.ask("hi")

      expect(recorder.calls.map { |call| call[:usage] }).to eq([nil, 42])
      expect(recorder.calls.map { |call| call[:session] }).to all(be(a.session))
      expect(recorder.calls.map { |call| call[:base] }).to all(be(a.context))
      expect(recorder.calls.last[:timeline].head_digest).to eq(a.timeline.rewind(1).head_digest)
    end

    # `Scheduler::COMPOSE` calls `Ractor.make_shareable` on a lambda closing
    # over the pipeline, so a per-turn Context that is not shareable is not a
    # style failure -- it is an IsolationError on the compacting turn.
    it "keeps every per-turn Context Ractor-shareable" do
      source = A1PipelineSources::Pruning.new(keep_last: 2)
      provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response)
      described_class.new(provider:, toolset:, context:, pipeline_source: source).ask("hi")

      # The size check is what makes this about the Context RENDERED THROUGH and
      # not merely the one the source happened to build: two renders, and the
      # second carries the pruned shape only that Context produces.
      expect(source.contexts.size).to eq(2)
      expect(provider.requests.last.messages.size).to eq(2)
      expect(source.contexts).to all(be_deeply_frozen)
    end

    # The override preempts the render entirely (see RequestOverride), so a
    # resent edit must not acquire a pipeline on its way out.
    it "leaves an overridden dispatch alone -- the source is never consulted for a resend" do
      recorder = A1PipelineSources::Recording.new
      provider = CoreGraph.provider(text_response)
      override = Lain::Agent::RequestOverride.new
      a = described_class.new(provider:, toolset:, context:, pipeline_source: recorder,
                              request_override: override)
      override.queue(context.render(timeline: CoreGraph.timeline
                                                       .commit(role: :user, content: [{ "type" => "text",
                                                                                        "text" => "edited" }]),
                                    toolset:))
      a.ask("hi")

      expect(recorder.calls).to be_empty
      expect(texts(provider.last_request)).to include("edited")
    end
  end

  # An idle prepare commits a compaction cut while the human is away, so it
  # takes the dispatch lock a run takes: it writes the Store a run writes, and
  # a line typed meanwhile must render through the cut rather than race it.
  describe "#prepare_idle" do
    def preparing_agent(source, responses = [text_response], **overrides)
      described_class.new(provider: CoreGraph.provider(*responses), toolset:, context:, pipeline_source: source,
                          **overrides)
    end

    it "never prepares through the default source" do
      expect(agent(text_response).prepare_idle).to be(false)
    end

    it "answers what the source's prepare answered" do
      expect(preparing_agent(A1PipelineSources::Preparing.new(answer: true)).prepare_idle).to be(true)
      expect(preparing_agent(A1PipelineSources::Preparing.new(answer: false)).prepare_idle).to be(false)
    end

    it "hands the source exactly what the next render hands it" do
      source = A1PipelineSources::Preparing.new
      a = preparing_agent(source, [text_response("first"), text_response("again")])
      a.ask("hi")
      a.rewind(1)

      a.prepare_idle
      a.run

      expect(source.prepares.last.keys).to contain_exactly(:base, :timeline, :usage, :session)
      expect(source.prepares.last).to eq(source.renders.last)
    end

    it "hands the source the last turn's usage, not the cumulative sum" do
      usage = Lain::Usage.new(input_tokens: 40, output_tokens: 5, cache_read_input_tokens: 2)
      reply = Lain::Response.new(content: [{ "type" => "text", "text" => "ok" }], stop_reason: :end_turn, usage:)
      source = A1PipelineSources::Preparing.new
      a = preparing_agent(source, [reply, reply])
      a.ask("one")
      a.ask("two")

      a.prepare_idle

      expect(source.prepares.last[:usage]).to eq(42)
    end

    # A Monitor is reentrant, so the holder's own fiber would otherwise pass
    # the busy check and prepare in the middle of its own run.
    it "declines without asking the source when called from inside the lock's own holder" do
      source = A1PipelineSources::Preparing.new
      a = preparing_agent(source)

      expect(a.dispatch_lock.synchronize { a.prepare_idle }).to be(false)
      expect(source.prepares).to be_empty
    end

    it "declines at once, without asking the source, while another caller holds the dispatch lock" do
      source = A1PipelineSources::Preparing.new
      a = preparing_agent(source)
      held = Queue.new
      release = Queue.new
      worker = Thread.new { a.dispatch_lock.synchronize { held.push(:holding) && release.pop } }
      held.pop

      expect(a.prepare_idle).to be(false)
      expect(source.prepares).to be_empty

      release.push(:go)
      worker.join
    end

    # The torn turn: the lock is free but the machine is parked mid-run, and
    # the next ask is what reopens it.
    it "declines without asking the source when the agent is not quiescent" do
      exploding = Class.new(Lain::Provider) do
        def capabilities = []
        def cache_profile = Lain::CacheProfile::NO_CACHING
        def encode(request) = request.cache_payload
        def complete(*, **) = raise(Lain::Error, "connection reset by peer")
      end.new
      source = A1PipelineSources::Preparing.new
      a = described_class.new(provider: exploding, toolset:, context:, pipeline_source: source)
      expect { a.ask("hi") }.to raise_error(Lain::Error)
      expect(described_class::QUIESCENT).not_to include(a.state)

      expect(a.prepare_idle).to be(false)
      expect(source.prepares).to be_empty
    end

    it "declines without asking the source once the token budget is spent" do
      earlier = CoreGraph.timeline.commit(role: :user, content: [{ "type" => "text", "text" => "earlier" }])
      accounting = Lain::Agent::Accounting.new
      accounting.observe(Lain::Response.new(content: [], stop_reason: :end_turn,
                                            usage: Lain::Usage.new(input_tokens: 100, output_tokens: 100)),
                         digest: earlier.head_digest)
      source = A1PipelineSources::Preparing.new
      a = described_class.new(toolset:, context:, accounting:, pipeline_source: source,
                              provider: CoreGraph.provider(text_response),
                              budget: Lain::Budget.ceilings(tokens: 50))
      expect(described_class::QUIESCENT).to include(a.state)

      expect(a.prepare_idle).to be(false)
      expect(source.prepares).to be_empty
    end

    it "prepares under a budget that is not yet spent" do
      source = A1PipelineSources::Preparing.new
      a = preparing_agent(source, budget: Lain::Budget.ceilings(tokens: 50))

      expect(a.prepare_idle).to be(true)
    end

    describe "#preparing?" do
      it "is true only while a prepare runs, and false again after the source raises" do
        readings = []
        a = nil
        source = A1PipelineSources::Preparing.new(during: -> { readings << a.preparing? })
        a = preparing_agent(source)
        readings << a.preparing?

        a.prepare_idle

        expect(readings).to eq([false, true])
        expect(a.preparing?).to be(false)
        failing = Object.new.tap { |o| o.define_singleton_method(:prepare) { |**| raise "summarizer down" } }
        a = preparing_agent(failing)
        expect { a.prepare_idle }.to raise_error("summarizer down")
        expect(a.preparing?).to be(false)
      end

      it "is false while an ordinary run holds the lock" do
        a = preparing_agent(A1PipelineSources::Preparing.new)

        expect(a.dispatch_lock.synchronize { a.preparing? }).to be(false)
      end
    end

    describe "while a prepare is in flight" do
      it "reports the agent dispatching, to it and to every command that asks InFlight" do
        readings = []
        a = nil
        source = A1PipelineSources::Preparing.new(during: lambda {
          readings << a.dispatching? << Lain::CLI::Command::InFlight.dispatching?(Struct.new(:agent).new(a))
        })
        a = preparing_agent(source)

        a.prepare_idle

        expect(readings).to eq([true, true])
        expect(a.dispatching?).to be(false)
      end

      it "refuses a rewind from another fiber as it would mid-run" do
        gate = Async::Queue.new
        a = preparing_agent(A1PipelineSources::Preparing.new(gate:))
        a.ask("hi")

        Sync do
          preparing = Async { a.prepare_idle }

          expect { a.rewind }.to raise_error(described_class::InFlight)

          gate.push(:go)
          preparing.wait
        end
      end

      it "holds a line typed meanwhile until the prepare returns, then renders it" do
        gate = Async::Queue.new
        source = A1PipelineSources::Preparing.new(gate:)
        provider = CoreGraph.provider(text_response("answered"))
        a = described_class.new(provider:, toolset:, context:, pipeline_source: source)

        Sync do
          preparing = Async { a.prepare_idle }
          asking = Async { a.ask("back") }

          expect(source.log).to eq([:prepare_started])
          expect(provider.call_count).to eq(0)

          gate.push(:go)
          expect(preparing.wait).to be(true)
          expect(asking.wait.text).to eq("answered")
        end

        expect(source.log).to eq(%i[prepare_started prepare_returned render])
      end
    end
  end

  # WHAT THE AGENT PROMISES THE MAILBOX, and the one thing `mailbox:` exists
  # for: the snapshot is captured ONCE at turn start, and the render and the
  # commit consume that same frozen value. {Lain::Agent#step} says why and
  # {Lain::Context::Mailbox} records the defect that taught it -- reading the
  # shared log live at commit "claimed a mid-dispatch arrival as a causal
  # parent of a turn that never rendered it, marking it consumed and losing it
  # from every future fold".
  #
  # These drive a real Agent over a real Timeline and a real inbox: a
  # {Lain::Context::Mailbox::Source} over an actor's log here, and the
  # {Lain::Context::Mailbox::Live} a chat posts notes into below.
  describe "the per-turn mailbox snapshot" do
    let(:store) { CoreGraph.store }
    let(:log) { Lain::Tools::Subagent::Log.new }
    let(:parent_timeline) do
      CoreGraph.timeline(store:)
               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
               .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
    end
    let(:recipient) { Lain::Event::ChainWriter.correlation_of(parent_timeline) }

    def note(text)
      lineage = Lain::Tools::Subagent::Lineage.new(policy: CoreGraph.spawn_policy, log:)
      lineage.note(parent_timeline, from: "actor", to: recipient, text:, causal_parents: [])
    end

    def source_agent(provider)
      described_class.new(provider:, toolset: CoreGraph.toolset([]), context: CoreGraph.context(model: "parent"),
                          timeline: parent_timeline,
                          mailbox: Lain::Context::Mailbox::Source.new(recipient:, log:))
    end

    def mailboxes(request)
      request.messages.last["content"].filter_map { |block| block["text"] }.grep(/\A<mailbox>/)
    end

    def assistant_parents(agent) = agent.timeline.to_a.select { |turn| turn.role == "assistant" }.map(&:causal_parents)

    # A Mailbox combinator binds its snapshot at construction, so a pipeline
    # built ONCE would re-fold turn 1's stale snapshot on turn 2 and never see
    # what arrived in between.
    it "folds each turn's OWN frozen snapshot -- no stale pipeline-construction binding" do
      provider = CoreGraph.provider(text_response("turn one"), text_response("turn two"))
      a = source_agent(provider)

      first_note = note("before turn one")
      a.ask("first")
      second_note = note("between turns")
      a.ask("second")

      first_request, second_request = provider.requests
      expect(mailboxes(first_request)).to eq(["<mailbox>\nactor | before turn one\n</mailbox>"])
      expect(mailboxes(second_request)).to eq(["<mailbox>\nactor | between turns\n</mailbox>"])

      # Render/commit agreement rides the same per-turn snapshot: each
      # assistant commit consumed exactly the digests its own render folded.
      turns = a.timeline.to_a
      expect(turns[3].causal_parents).to eq([first_note.digest])
      expect(turns[5].causal_parents).to eq([second_note.digest])
    end

    # The one real yield inside a turn is the provider round trip: capture ->
    # render is a single synchronous stretch on the Agent's fiber. A message
    # landing THERE must stay out of both halves of this turn, and be folded by
    # the next one.
    it "keeps a message landing between render and commit out of NEITHER half, and folds it next turn" do
      mid_note = nil
      inject = -> { mid_note ||= note("mid-turn arrival") }
      provider = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request|
          response = super(request)
          inject.call
          response
        end
      end.new(responses: [text_response("turn one"), text_response("turn two")])
      a = source_agent(provider)

      pre_note = note("before the turn")
      a.ask("first")
      a.ask("second")

      first_request, second_request = provider.requests
      expect(mailboxes(first_request)).to eq(["<mailbox>\nactor | before the turn\n</mailbox>"])
      expect(mailboxes(second_request)).to eq(["<mailbox>\nactor | mid-turn arrival\n</mailbox>"])

      turns = a.timeline.to_a
      # Turn 1's commit consumed exactly its render's fold -- never the note
      # that arrived during the round trip; turn 2 consumed the straggler.
      expect(turns[3].causal_parents).to eq([pre_note.digest])
      expect(turns[5].causal_parents).to eq([mid_note.digest])
    end

    describe "with Mailbox::Null, the default" do
      it "renders through the very Context the per-turn source returned, and folds nothing" do
        witness = LiveNotes::Witness.new
        provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response)
        a = described_class.new(provider:, toolset:, context:, pipeline_source: witness)
        a.ask("hi")

        expect(witness.renders).to eq(provider.requests.size)
        expect(assistant_parents(a)).to eq([[], []])
      end
    end

    # The production shape: a chat's notes, folded between tool rounds and
    # checked on the ollama wire.
    describe "with a Mailbox::Live" do
      let(:journaled) { [] }
      let(:live) do
        Lain::Context::Mailbox::Live.new(recipient: Lain::Event::ChainWriter.method(:correlation_of),
                                         observer: journaled.method(:<<))
      end
      let(:encoder) { Class.new { include Lain::Provider::Ollama::Encoding }.new }

      def post(text) = live.post(from: "human", text:)

      def live_agent(provider, toolset: CoreGraph.toolset([]), **)
        described_class.new(provider:, toolset:, context:, mailbox: live, **)
      end

      def mailbox_texts(request)
        request.messages.flat_map { |message| Array(message["content"]) }
               .filter_map { |block| block.is_a?(Hash) && block["text"] }.grep(/<mailbox>/)
      end

      def recording(*outcomes)
        Class.new(Lain::Provider::Mock) do
          define_method(:complete) do |request, **|
            requests << request
            outcome = outcomes.shift || raise("script exhausted")
            outcome.is_a?(Exception) ? raise(outcome) : outcome
          end
        end.new
      end

      it "reaches the model on the wire in the request after the tool round, and only there" do
        provider = CoreGraph.provider(tool_response(["tu_1", "posting", {}]), text_response("answered"),
                                      text_response("again"))
        a = live_agent(provider, toolset: CoreGraph.toolset([LiveNotes::Posting.new(-> { post("use Syncthing") })]))
        a.ask("go")
        a.ask("more")

        first, second, third = provider.requests.map { |request| encoder.encode(request)[:messages] }
        tool_at = second.index { |message| message[:role] == "tool" }
        beside = second[(tool_at + 1)..].find { |message| message[:role] == "user" }
        expect(beside[:content]).to include("<mailbox>\nhuman | use Syncthing\n</mailbox>")
        expect([first, third].flatten.map { |message| message[:content] }.grep(/Syncthing/)).to eq([])

        answered = a.timeline.to_a[3]
        expect(answered.causal_parents).to eq(journaled.map(&:digest))
        expect(journaled.map { |event| event.body.fetch("text") }).to eq(["use Syncthing"])
      end

      it "folds behind the pipeline the per-turn source chose, not the class default" do
        provider = CoreGraph.provider(text_response)
        a = live_agent(provider, pipeline_source: LiveNotes::Tagging.new)
        post("note")
        a.ask("first")

        tail = provider.last_request.messages.last["content"].filter_map { |block| block["text"] }
        expect(tail.grep(/<tag|<mailbox>/)).to eq(["<tag/>", "<mailbox>\nhuman | note\n</mailbox>"])
      end

      it "folds the same words posted twice into 2 requests" do
        provider = CoreGraph.provider(text_response("one"), text_response("two"))
        a = live_agent(provider)
        post("continue")
        a.ask("first")
        post("continue")
        a.ask("second")

        expect(provider.requests.map { |request| mailbox_texts(request) })
          .to eq([["<mailbox>\nhuman | continue\n</mailbox>"]] * 2)
        expect(assistant_parents(a)).to eq(journaled.map { |note| [note.digest] })
      end

      it "addresses a note posted before the chat's first commit at the first request, and folds it there" do
        provider = CoreGraph.provider(text_response)
        a = live_agent(provider)
        post("early")
        a.ask("first")

        expect(mailbox_texts(provider.last_request)).to eq(["<mailbox>\nhuman | early\n</mailbox>"])
        expect(journaled.map(&:to)).to eq([a.timeline.correlation])
      end

      it "keeps a note posted during the provider round trip out of that request and commit, and folds it next" do
        inject = -> { post("mid-dispatch") }
        provider = Class.new(Lain::Provider::Mock) do
          define_method(:complete) do |request, **|
            super(request).tap { inject.call if requests.size == 1 }
          end
        end.new(responses: [text_response("one"), text_response("two")])
        a = live_agent(provider)
        a.ask("first")
        a.ask("second")

        expect(provider.requests.map { |request| mailbox_texts(request) })
          .to eq([[], ["<mailbox>\nhuman | mid-dispatch\n</mailbox>"]])
        expect(assistant_parents(a)).to eq([[], journaled.map(&:digest)])
      end

      it "claims no note for a resend it never rendered, and folds the note into the next rendered request" do
        override = Lain::Agent::RequestOverride.new
        provider = CoreGraph.provider(text_response("resent"), text_response("rendered"))
        a = live_agent(provider, request_override: override)
        override.queue(context.render(timeline: CoreGraph.timeline.commit(role: :user, content: [
                                                                            { "type" => "text", "text" => "edited" }
                                                                          ]),
                                      toolset: CoreGraph.toolset([])))
        post("hold on")
        a.ask("first")
        a.ask("second")

        expect(provider.requests.map { |request| mailbox_texts(request) })
          .to eq([[], ["<mailbox>\nhuman | hold on\n</mailbox>"]])
        expect(assistant_parents(a)).to eq([[], journaled.map(&:digest)])
      end

      # A first prompt that stalls is stranded, and the next ask folds it into a
      # turn with no parent: a chain with a new root. The note captured for the
      # stalled request still folds into the one that answers.
      it "folds a note captured for a stalled first request into the request that follows it" do
        provider = recording(RuntimeError.new("stalled"), text_response("answered"))
        a = live_agent(provider)
        post("use Syncthing")
        expect { a.ask("first") }.to raise_error(RuntimeError, "stalled")
        stalled_root = a.timeline.correlation
        a.ask("again")

        expect(a.timeline.correlation).not_to eq(stalled_root)
        expect(provider.requests.map { |request| mailbox_texts(request) })
          .to eq([["<mailbox>\nhuman | use Syncthing\n</mailbox>"]] * 2)
        expect(a.timeline.head.causal_parents).to eq(journaled.map(&:digest))
      end

      # The turn that folded the note is gone from the chain, so the context
      # that saw it is gone too: the note folds again.
      it "refolds a note whose consuming turn a rewind past the root removed" do
        provider = CoreGraph.provider(text_response("one"), text_response("two"))
        a = live_agent(provider)
        post("again please")
        a.ask("first")
        a.rewind(2)
        a.ask("over")

        expect(provider.requests.map { |request| mailbox_texts(request) })
          .to eq([["<mailbox>\nhuman | again please\n</mailbox>"]] * 2)
        expect(a.timeline.head.causal_parents).to eq(journaled.map(&:digest))
      end
    end
  end

  # The post-dispatch tool-result observer is threaded from the constructor
  # into ToolRunner, and defaults to the Null so an Agent built without one
  # behaves byte-identically.
  describe "the tool-result observer" do
    it "hands each completed tool_result block to an injected observer" do
      seen = []
      observer = Class.new do
        def initialize(seen) = @seen = seen

        def observe(block, tool_name) = @seen << "#{tool_name}:#{block["tool_use_id"]}"
      end.new(seen)
      provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response)
      described_class.new(provider:, toolset:, context:, tool_observer: observer).ask("hi")

      expect(seen).to eq(["echo:tu_1"])
    end

    it "observes nothing by default, leaving the delivered results byte-identical" do
      provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response)
      a = described_class.new(provider:, toolset:, context:)
      a.ask("hi")

      results = a.timeline.to_a[2].content
      expect(results.map { |block| block["type"] }).to eq(["tool_result"])
    end
  end

  # The Agent accepts the three objects it drives -- ModelCaller,
  # ToolRunner, Accounting -- instead of only the ingredients it builds them
  # from. Additive: the legacy keywords stay, and every existing call site
  # keeps its meaning. Mixing the two styles for ONE collaborator is the loud
  # case, because it states two answers to a single wiring question.
  describe "collaborator injection" do
    # One value per wiring keyword, so the clash table below can name a
    # collaborator and an ingredient and get a constructible pair. Built per
    # call: an Agent must never be handed a collaborator another Agent drives.
    def wiring_value(keyword)
      { model_caller: Lain::Agent::ModelCaller.new(provider: CoreGraph.provider),
        tool_runner: Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new),
        accounting: Lain::Agent::Accounting.new,
        provider: CoreGraph.provider,
        model_middleware: Lain::Middleware::Stack.new,
        handler: Lain::Effect::Handler::Mock.new,
        tool_middleware: Lain::Middleware::Stack.new,
        tool_observer: Lain::Agent::ToolRunner::Observer::Null.new,
        round_budget: Lain::Tool::RoundBudget.static,
        journal: RecordingChannel.new }.fetch(keyword)
    end

    it "drives injected collaborators, with no provider:, journal: or middleware keyword" do
      provider = CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response("bye"))
      journal = RecordingChannel.new
      a = described_class.new(
        toolset:, context:,
        model_caller: Lain::Agent::ModelCaller.new(provider:),
        # `toolset:` on the runner too: it must harvest from the same set the
        # Agent renders, or the committed digest moves (see the digest group).
        tool_runner: Lain::Agent::ToolRunner.new(
          handler: Lain::Effect::Handler::Mock.new(results: { "echo" => "from the injected runner" }), toolset:
        ),
        accounting: Lain::Agent::Accounting.new(journal:)
      )
      response = a.ask("hi")

      expect(response.text).to eq("bye")
      # The injected runner's handler answered, so dispatch went through IT and
      # not through a ToolRunner the Agent built over the real toolset.
      expect(a.timeline.to_a[2].content.map { |block| block["content"] }).to eq(["from the injected runner"])
      expect(journal.events.map(&:class)).to eq([Lain::Telemetry::TurnUsage, Lain::Telemetry::TurnUsage])
    end

    # The sharpest statement that the ledger is the caller's object and not a
    # fresh one: a resumed run's spend survives construction.
    it "reports the injected Accounting's running total, not a fresh ledger" do
      accounting = Lain::Agent::Accounting.new
      accounting.observe(text_response(usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2)), digest: "seed")
      a = described_class.new(toolset:, context:, accounting:,
                              model_caller: Lain::Agent::ModelCaller.new(provider: CoreGraph.provider))

      expect(a.usage.input_tokens).to eq(40)
    end

    it "still builds all three from the legacy keywords, journaling through the given channel" do
      journal = RecordingChannel.new
      a = agent([tool_response(["tu_1", "echo", { "text" => "x" }]),
                 text_response(usage: Lain::Usage.new(input_tokens: 12, output_tokens: 2))], journal:)
      a.ask("hi")

      # The default-built ToolRunner still dispatches over the real toolset,
      # and the default-built Accounting still rolls up over the given journal.
      expect(a.timeline.to_a[2].content.map { |block| block["content"] }).to eq(["x"])
      expect(journal.events.size).to eq(2)
      expect(a.usage.input_tokens).to eq(12)
    end

    # The clash rule is PER collaborator, so the two styles compose: an injected
    # ToolRunner beside a `provider:` says nothing contradictory. `toolset:` is
    # shared besides -- the Agent renders it and the runner harvests answered
    # questions from it -- so it is never exclusive to a collaborator either.
    it "mixes the two styles across different collaborators" do
      tool_runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new, toolset:)
      a = described_class.new(toolset:, context:, provider: wiring_value(:provider), tool_runner:)

      expect(a.send(:tool_runner)).to be(tool_runner)
      expect(a.send(:model_caller).provider).to be_a(Lain::Provider::Mock)
    end

    # The default-built runner's handler is LIVE, resolving calls against the
    # Agent's own toolset, which is what makes `handler:` an ingredient rather
    # than a requirement.
    it "builds a ToolRunner whose Live handler runs what the Agent's own toolset resolves" do
      runner = described_class.new(toolset:, context:, provider: wiring_value(:provider)).send(:tool_runner)

      expect(runner.handler).to be_a(Lain::Effect::Handler::Live)
      expect(runner.toolset).to be(toolset)
    end

    # The vocabulary the constructor polices, named once and read by
    # {Lain::Agent::Instrumentation}'s own refusal so the two halves of one
    # wiring surface cannot list different keywords.
    it "names the ingredient vocabulary its refusals are keyed on" do
      expect(described_class::KEYWORDS)
        .to contain_exactly(:provider, :model_middleware, :handler, :tool_middleware, :tool_observer, :round_budget,
                            :journal)
      expect(described_class::OMITTED).to be_frozen
    end

    it "demands a provider when no model_caller is injected" do
      expect { described_class.new(toolset:, context:) }
        .to raise_error(ArgumentError, /provider/)
    end

    it "still refuses an unknown keyword, so a typo cannot be swallowed as wiring" do
      expect { described_class.new(toolset:, context:, provider: wiring_value(:provider), providr: nil) }
        .to raise_error(ArgumentError, /providr/)
    end

    # Both styles are valid; mixing them for one collaborator is not. Driven
    # off the Agent's own table rather than a copy of it, so a new ingredient
    # cannot gain a clash rule with no example.
    described_class::INGREDIENTS.each do |collaborator, ingredients|
      ingredients.each do |ingredient|
        it "refuses #{collaborator}: passed alongside #{ingredient}:" do
          expect do
            described_class.new(toolset:, context:, collaborator => wiring_value(collaborator),
                                ingredient => wiring_value(ingredient))
          end.to raise_error(ArgumentError, /#{collaborator}.*#{ingredient}/m)
        end
      end
    end

    # An explicit nil is a caller mistake, not a request for the default: the way
    # to take a default is to omit the keyword. It has to be loud, because every
    # silent reading is worse. `handler: nil` used to propagate and crash on
    # dispatch; resolved to a default it would quietly become a LIVE handler over
    # the real toolset -- a nil that runs tools. `journal: nil` would quietly
    # become the Null channel and throw away the experiment record a caller
    # thought they had asked for.
    %i[model_caller provider model_middleware tool_runner handler tool_middleware
       tool_observer accounting journal].each do |keyword|
      it "refuses an explicit #{keyword}: nil rather than reading it as the default" do
        expect { described_class.new(toolset:, context:, keyword => nil) }
          .to raise_error(ArgumentError, /#{keyword}.*nil/m)
      end
    end
  end

  # The correctness gate, and the one place the two construction styles could
  # diverge in BYTES. A {Agent::ToolRunner} harvests answered questions from ITS
  # OWN toolset and the Agent commits them as the turn's `causal_parents:`, which
  # are Merkle digest input -- so a runner looking at a different capability set
  # than the Agent renders writes a different Timeline for the same conversation.
  # `Canonical` bytes serve turn hashing AND prompt-cache stability, so the
  # symptom would be a mysterious cache miss, never an error. Measured on both
  # paths here rather than reasoned about.
  describe "the committed digest across construction styles" do
    # The hand-over duck, exactly as Tools::AskHuman answers it: one drain, then
    # empty. A Struct rather than a Tool subclass because the harvest is the only
    # behaviour under test and `respond_to?(:take_answered_questions)` is the
    # whole selection rule ToolRunner applies.
    def handover_toolset(digest)
      tool = Struct.new(:name).new("ask_human")
      queue = [digest]
      tool.define_singleton_method(:take_answered_questions) { queue.slice!(0..) }
      tool.define_singleton_method(:parallel_safe?) { false }
      tool.define_singleton_method(:to_schema) do
        { "name" => "ask_human", "description" => "probe", "input_schema" => { "type" => "object" } }
      end
      CoreGraph.toolset([tool])
    end

    def handover_agent(style, tools:, provider:, timeline:)
      handler = Lain::Effect::Handler::Mock.new(results: { "ask_human" => "the answer" })
      wiring = case style
               when :legacy then { provider:, handler: }
               when :injected then { model_caller: Lain::Agent::ModelCaller.new(provider:),
                                     tool_runner: Lain::Agent::ToolRunner.new(handler:, toolset: tools) }
               end
      described_class.new(toolset: tools, context:, timeline:, **wiring)
    end

    def seeded_timeline
      CoreGraph.timeline
               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    # The delivery turn: the one user message holding every tool_result, whose
    # causal_parents carry the harvest.
    def tool_result_turn(agent)
      agent.timeline.to_a.find { |event| event.content.any? { |block| block["type"] == "tool_result" } }
    end

    def handover_turn(style)
      seeded = seeded_timeline
      provider = CoreGraph.provider(tool_response(["tu_1", "ask_human", {}]), text_response)
      agent = handover_agent(style, tools: handover_toolset(seeded.head_digest), provider:, timeline: seeded)
      agent.ask("go")
      tool_result_turn(agent)
    end

    it "is byte-identical, and both paths really do harvest the consumption edge" do
      turns = %i[legacy injected].map { |style| handover_turn(style) }

      # Non-empty on BOTH, so the equality below is two harvests agreeing and
      # not two omissions agreeing.
      expect(turns.map { |turn| turn.causal_parents.size }).to eq([1, 1])
      expect(turns.map(&:digest).uniq.size).to eq(1)
    end

    # The guard that makes the parity above impossible to lose quietly: the
    # Agent cannot hand its toolset to a runner it did not build, so a runner
    # over a different one is refused at construction instead of silently
    # writing a different digest.
    it "refuses an injected ToolRunner built over a toolset that is not the Agent's" do
      expect do
        described_class.new(toolset:, context:, provider: CoreGraph.provider,
                            tool_runner: Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new))
      end.to raise_error(ArgumentError, /toolset/)
    end
  end

  # The seven keywords a run REPORTS through -- the journal, the three
  # middleware phases, the tool observer, the transition listener and the
  # per-turn Context source -- travel as ONE {Lain::Agent::Instrumentation}
  # value. They were seven slots on this constructor and three Hash reifications
  # in the CLI, each poking at the Hash with `.fetch`/`.slice`/`.merge`.
  describe "instrumentation" do
    let(:log) { [] }
    let(:journal) { RecordingChannel.new }
    let(:transitions) { T22Instrumentation::Transitions.new }
    let(:observations) { T22Instrumentation::Observations.new }
    let(:renders) { T22Instrumentation::Renders.new }

    # One tool call then a text answer: two provider round trips, so a per-turn
    # member (the turn phase, the Context source) is asked TWICE and a per-tool
    # one (the observer, the tool phase) once.
    def echoing_provider
      CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]), text_response("bye"))
    end

    def full_instrumentation
      Lain::Agent::Instrumentation.new(
        journal:,
        model_middleware: Lain::Middleware::Stack.new([T22Instrumentation::Tap.new(log, :model)]),
        tool_middleware: Lain::Middleware::Stack.new([T22Instrumentation::Tap.new(log, :tool)]),
        turn_middleware: Lain::Middleware::Stack.new([T22Instrumentation::Tap.new(log, :turn)]),
        tool_observer: observations, transition_listener: transitions, pipeline_source: renders
      )
    end

    # One ask, one tool call, and every member is asked to prove it arrived. A
    # member that never reaches its consumer is the failure this exists for:
    # seven Nulls would leave the Agent working and the run unobserved.
    it "delivers all seven members to their consumers in one ask" do
      a = described_class.new(toolset:, context:, instrumentation: full_instrumentation,
                              provider: echoing_provider)
      a.ask("hi")

      expect(log.tally).to eq({ turn: 2, model: 2, tool: 1 })
      expect(journal.events.map(&:class)).to eq([Lain::Telemetry::TurnUsage, Lain::Telemetry::TurnUsage])
      expect(observations.tools).to eq(["echo"])
      expect(renders.asks).to eq(2)
      expect(transitions.events.map(&:last)).to include(:dispatch, :tool_use, :end_turn)
    end

    # The default is the all-Null value, so an Agent built without one behaves
    # exactly as it always did -- no `if journal` anywhere downstream.
    it "defaults to the all-Null value, which changes nothing" do
      a = agent(text_response("bye"))

      expect { a.ask("hi") }.not_to raise_error
      expect(a.timeline.to_a.size).to eq(2)
    end

    # Both styles are valid; saying the same thing twice is not. The refusal is
    # flat, because the value carries every one of the seven.
    %i[journal model_middleware tool_middleware turn_middleware
       tool_observer transition_listener pipeline_source].each do |member|
      it "refuses instrumentation: passed alongside the legacy #{member}:" do
        expect do
          described_class.new(toolset:, context:, provider: CoreGraph.provider,
                              instrumentation: Lain::Agent::Instrumentation.new,
                              member => Lain::Agent::Instrumentation.new.public_send(member))
        end.to raise_error(ArgumentError, /instrumentation:.*#{member}:/m)
      end
    end

    # Every wiring keyword this constructor does not name lands in the
    # instrumentation resolver, which is therefore the only place a wiring typo
    # can be answered. It has to answer with the route to the fix: naming
    # `providr:` back at the caller without naming `provider:` is what Ruby's
    # own `unknown keyword:` does. It is also the ONLY vocabulary refusal
    # reachable from here: the collaborator keywords are named on the signature,
    # so Ruby polices them and nothing behind them can ever be tripped.
    it "answers a typo with the keyword the caller meant, not just the typo" do
      message = begin
        described_class.new(toolset:, context:, providr: CoreGraph.provider)
        raise "expected an ArgumentError, and none was raised"
      rescue ArgumentError => e
        e.message
      end

      expect(message).to include("providr:")
      expect(message).to include("provider:", "journal:", "pipeline_source:")
    end

    # `handler:` and `provider:` are NOT instrumentation members -- they are
    # collaborator INGREDIENTS -- so naming them beside a value that carries
    # the phases those collaborators run in is the ordinary wiring, not a clash.
    it "composes with the collaborator ingredients it is not one of" do
      a = described_class.new(
        toolset:, context:, provider: echoing_provider,
        handler: Lain::Effect::Handler::Mock.new(results: { "echo" => "from the mock" }),
        instrumentation: Lain::Agent::Instrumentation.new(
          tool_middleware: Lain::Middleware::Stack.new([T22Instrumentation::Tap.new(log, :tool)])
        )
      )
      a.ask("hi")

      expect(log).to eq([:tool])
      expect(a.timeline.to_a[2].content.map { |block| block["content"] }).to eq(["from the mock"])
    end

    # The compatibility statement, measured in BYTES rather than reasoned about:
    # the legacy keywords build the same value, so the two construction styles
    # commit the same Timeline. `Canonical` bytes serve turn hashing AND
    # prompt-cache stability, so a divergence here would surface as an
    # unexplained cache miss and never as an error.
    it "commits a byte-identical Timeline whether written as one value or as the legacy keywords" do
      digests = %i[value legacy].map do |style|
        wiring = case style
                 when :value then { instrumentation: Lain::Agent::Instrumentation.new(journal:) }
                 when :legacy then { journal: }
                 end
        a = described_class.new(toolset:, context:, provider: echoing_provider, **wiring)
        a.ask("hi")
        a.timeline.to_a.map(&:digest)
      end

      # Four turns on BOTH -- user, tool_use, tool_result, text -- so the
      # equality is two real conversations agreeing, not two empty walks.
      expect(digests.map(&:size)).to eq([4, 4])
      expect(digests.uniq.size).to eq(1)
    end
  end

  # `#wire_callers` resolves both halves of the two construction styles onto
  # plain readers -- @model_caller/@tool_runner/@accounting -- kept private for
  # the reason the public surface at the top of this file is a curated list:
  # what the loop drives is not part of it.
  describe "wire_callers" do
    # The point of resolving eagerly (agent.rb wire_callers' comment) is that a
    # wiring mistake is an error AT CONSTRUCTION, never deferred to the first
    # turn. No #ask happens in this example -- the raise has to come out of
    # `described_class.new` itself, which is only possible if #wire_callers
    # resolves both halves there rather than lazily on first use.
    it "still raises during initialize, before any turn runs, on a wiring mistake" do
      expect do
        described_class.new(toolset:, context:, provider: CoreGraph.provider,
                            instrumentation: Lain::Agent::Instrumentation.new,
                            journal: RecordingChannel.new)
      end.to raise_error(ArgumentError, /instrumentation:.*journal:/m)
    end

    # The instrumentation clash above resolves inside `Instrumentation.resolve`,
    # which runs FIRST -- so it raises even if the collaborator half were
    # resolved lazily, and does not by itself prove that half is eager. This
    # example trips a mistake in the collaborator half instead (model_caller:
    # alongside the provider: it would have been built from, INGREDIENTS's own
    # clash table) and demands the same thing: no #ask, the raise comes out of
    # `described_class.new` itself.
    it "still raises during initialize on a double-wiring mistake between collaborators" do
      model_caller = Lain::Agent::ModelCaller.new(provider: CoreGraph.provider)

      expect do
        described_class.new(toolset:, context:, model_caller:,
                            provider: CoreGraph.provider)
      end.to raise_error(ArgumentError, /model_caller.*provider/m)
    end

    # The readers answer the same objects a caller injected -- not
    # copies, not rebuilt ones. Private (constraint 2), so reached with #send
    # rather than a public call, same as the two other specs (subagent_spec.rb,
    # wiring_spec.rb) that reach this seam from outside.
    it "answers model_caller, tool_runner and accounting as the injected doubles" do
      model_caller = Lain::Agent::ModelCaller.new(provider: CoreGraph.provider)
      tool_runner = Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new, toolset:)
      accounting = Lain::Agent::Accounting.new
      a = described_class.new(toolset:, context:, model_caller:, tool_runner:, accounting:)

      expect(a.send(:model_caller)).to equal(model_caller)
      expect(a.send(:tool_runner)).to equal(tool_runner)
      expect(a.send(:accounting)).to equal(accounting)
    end

    it "still delegates #usage to the injected accounting's cumulative usage" do
      accounting = Lain::Agent::Accounting.new
      accounting.observe(text_response(usage: Lain::Usage.new(input_tokens: 40, output_tokens: 2)), digest: "seed")
      a = described_class.new(toolset:, context:, accounting:,
                              model_caller: Lain::Agent::ModelCaller.new(
                                provider: CoreGraph.provider
                              ))

      expect(a.usage).to equal(accounting.usage)
    end

    # Constraint 2's ask, verified rather than assumed: the delegation must not
    # widen Agent's public surface as a side effect of a private-wiring
    # readability refactor. `public_instance_methods(false)`/
    # `private_instance_methods(false)` are scoped to methods `delegate`
    # defines directly on Agent (not inherited ones), which is exactly where a
    # stray public delegate would show up.
    it "keeps model_caller, tool_runner and accounting off Agent's public surface" do
      expect(described_class.public_instance_methods(false)).not_to include(:model_caller, :tool_runner,
                                                                            :accounting)
      expect(described_class.private_instance_methods(false)).to include(:model_caller, :tool_runner, :accounting)
    end
  end

  describe "a round budget" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    let(:journal) { [] }
    let(:paths) do
      (1..5).map do |n|
        File.join(@tmpdir, "file#{n}.rb").tap { |path| File.write(path, "# file #{n} #{"x" * 60}\n" * 100) }
      end
    end

    def window_agent(*responses)
      described_class.new(provider: CoreGraph.provider(*responses), journal:,
                          toolset: CoreGraph.toolset([Lain::Tools::ReadFile.new, Lain::Tools::EditFile.new]),
                          context: CoreGraph.context(model: "qwen3-coder:30b", max_tokens: 16_384),
                          context_window: Lain::ContextWindow.new(windows: { "qwen3" => 32_768 }),
                          round_budget: Lain::Tool::RoundBudget.window)
    end

    def fifteen_reads
      calls = (1..15).map do |n|
        { "type" => "tool_use", "id" => "tu_#{n}", "name" => "read_file", "input" => { "path" => paths[(n - 1) % 5] } }
      end
      Lain::Response.new(content: calls, stop_reason: :tool_use,
                         usage: Lain::Usage.new(input_tokens: 7_492, output_tokens: 300))
    end

    def results(agent)
      agent.timeline.to_a.find { |turn| turn.role == "user" && turn.content.first["type"] == "tool_result" }.content
    end

    it "holds the round to the window left after the last turn and the reply reserve" do
      a = window_agent(fifteen_reads, text_response)
      a.ask("read them all")

      blocks = results(a)
      expect(blocks.first(3).map { |block| block["is_error"] }).to eq([false, false, false])
      expect(blocks[5]["content"]).to eq("same result as call tu_1")
      expect(blocks[3]).to include("is_error" => true,
                                   "content" => start_with("not delivered: this round reached its 27352-byte budget " \
                                                           "(window 32768 tokens);"))
      expect(journal.grep(Lain::Telemetry::RoundBounded).map { |record| [record.head, record.withheld] })
        .to eq([[a.timeline.to_a[1].digest, %w[tu_4 tu_5 tu_9 tu_10 tu_14 tu_15]]])
    end

    it "hands the budget the room as a value with the window, usage and ceiling" do
      rooms = []
      spy = Lain::Tool::RoundBudget.new(:spy) do |room|
        rooms << room
        Lain::Tool::RoundBudget::Limit.new(bytes: 1_000_000, scope: "spy")
      end
      a = described_class.new(provider: CoreGraph.provider(fifteen_reads, text_response), journal:,
                              toolset: CoreGraph.toolset([Lain::Tools::ReadFile.new]),
                              context: CoreGraph.context(model: "qwen3-coder:30b", max_tokens: 16_384),
                              context_window: Lain::ContextWindow.new(windows: { "qwen3" => 32_768 }),
                              round_budget: spy)
      a.ask("read them all")

      expect(rooms).to contain_exactly(have_attributes(
                                         window: 32_768, ceiling: 16_384,
                                         usage: have_attributes(output_tokens: 300)
                                       ))
    end

    it "runs a tool round with no budget on a window book that cannot name the model's window" do
      a = described_class.new(provider: CoreGraph.provider(tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                           text_response),
                              toolset:, context: CoreGraph.context(model: "mystery-model"),
                              context_window: Lain::ContextWindow.new(windows: { "qwen3" => 32_768 }))

      expect(a.ask("go").text).to eq("done")
    end

    it "refuses an edit of a file whose read was withheld, as for any error result" do
      edit = tool_response(["tu_16", "edit_file",
                            { "path" => paths[3], "old_string" => "# file 4", "new_string" => "#" }])
      a = window_agent(fifteen_reads, edit, text_response)
      a.ask("read them all, then edit the fourth")

      refusal = a.timeline.to_a.reverse.find { |turn| turn.role == "user" }.content.first
      expect(refusal).to include("is_error" => true, "content" => include("was never read"))
      expect(File.read(paths[3])).to start_with("# file 4")
    end
  end
end
