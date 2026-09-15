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

# The `mailbox:` duck, as the only thing that can exercise it: a per-turn
# snapshot slot that is BOTH the Agent's mailbox ({#capture}) and the tail of
# its Context pipeline ({#call}). Production wires no non-Null mailbox today --
# {Lain::Context::Mailbox::Null} captures itself and folds nothing, so with it
# in the slot every capture/render/commit ordering renders identically and the
# invariant below is invisible. In a module body for the reason
# A1PipelineSources is.
module A1MailboxSeam
  # Deliberately NOT frozen, unlike every other combinator: the per-turn
  # snapshot slot is the point, and its single writer is the Agent's own fiber.
  class Seam < Lain::Context::Combinator
    def initialize(source:)
      super()
      @source = source
      @snapshot = Lain::Context::Mailbox::Null
    end

    def capture(timeline) = @snapshot = @source.capture(timeline)

    def call(messages) = Lain::Context::Mailbox.new(snapshot: @snapshot).call(messages)
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
  # {Lain::Agent::Budget#interrupt} does from outside.
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
        a.budget.interrupt(run)
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
                     budget: Lain::Agent::Budget.new(max_total_tokens: 50),
                     timeline: CoreGraph.timeline(store: UncommittableResults::Store.new(notice)))

        expect { over.ask("hi") }.to raise_error(described_class::BudgetExceeded)
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
              budget: Lain::Agent::Budget.new(max_total_tokens: 50))
      end

      it "stops with the budget refusal and a head that answers the call" do
        expect { over_budget.ask("hi") }.to raise_error(described_class::BudgetExceeded)

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
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to include("refused")
    end

    it "fails on max_tokens" do
      a = agent(text_response("", stop_reason: :max_tokens))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to include("max_tokens")
    end

    # The wire enums are non-exhaustive. An unrecognized value must fail loudly,
    # not fall through a `case` and quietly do nothing.
    it "fails on an unrecognized stop_reason" do
      a = agent(Lain::Response.new(content: [], stop_reason: "something_new_in_2027"))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to include("unrecognized")
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
                budget: Lain::Agent::Budget.new(max_iterations: 3))
      expect { a.ask("hi") }.to raise_error(described_class::BudgetExceeded, /3 iterations/)
    end

    it "raises once the token ceiling is passed" do
      usage = Lain::Usage.new(input_tokens: 100, output_tokens: 100)
      a = agent([Lain::Response.new(content: [], stop_reason: :end_turn, usage:)],
                budget: Lain::Agent::Budget.new(max_total_tokens: 50))
      expect { a.ask("hi") }.to raise_error(described_class::BudgetExceeded, /ceiling is 50/)
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
                  budget: Lain::Agent::Budget.new(max_iterations: 2))

        expect(a.ask("one").text).to eq("first")
        expect(a.ask("two").text).to eq("second")
        expect(a.iterations).to eq(2)
      end

      # The reset is not a reprieve: the ceiling still bounds the ask it belongs
      # to, whatever ran before it.
      it "still stops a single ask at the ceiling, however many asks preceded it" do
        a = agent(settling_pair("first") + [tool_response(["tu_2", "echo", { "text" => "forever" }])],
                  budget: Lain::Agent::Budget.new(max_iterations: 2))
        a.ask("one")

        expect { a.ask("two") }
          .to raise_error(described_class::BudgetExceeded, "loop ran 2 iterations, ceiling is 2")
      end

      # The silent-swallow half. A refused ask says which ceiling stopped it
      # (the message {CLI::Repl#respond} renders), and the NEXT prompt reaches
      # the provider instead of dying on arrival.
      it "names the ceiling that stopped the run, then answers the next prompt" do
        looping = tool_response(["tu_1", "echo", { "text" => "loop" }])
        provider = CoreGraph.provider(looping, looping, looping, text_response("recovered"))
        a = described_class.new(provider:, toolset:, context:,
                                budget: Lain::Agent::Budget.new(max_iterations: 2))

        expect { a.ask("one") }
          .to raise_error(described_class::BudgetExceeded, "loop ran 2 iterations, ceiling is 2")
        expect(a.ask("two").text).to eq("recovered")
        expect(provider.call_count).to eq(4)
      end
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
                budget: Lain::Agent::Budget.new(max_total_tokens: 50),
                journal:)

      expect { a.ask("hi") }.to raise_error(described_class::BudgetExceeded)
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
      # totality + FAILURE_REASONS) are untouched -- this is a state-set snapshot
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

    def seed(store)
      committed(store, [:user, "first"], [:assistant, "ack"], [:user, "second"])
    end

    it "is the starting state: the request renders all three turns before the new user turn" do
      provider = CoreGraph.provider(text_response("hello"))
      a = described_class.new(provider:, toolset:, context:, timeline: seed(seeded_store))
      a.ask("hi")

      rendered = provider.last_request.messages
      expect(rendered.map { |message| message["role"] }).to eq(%w[user assistant user user])
      # The content sequence is the pin: two seeded turns share role "user", so
      # the role sequence alone would not catch a transposition of their content.
      expect(rendered.map { |message| message["content"].first["text"] }).to eq(%w[first ack second hi])
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

  # WHAT THE AGENT PROMISES THE MAILBOX, and the one thing `mailbox:` exists
  # for: the snapshot is captured ONCE at turn start, and the render and the
  # commit consume that same frozen value. {Lain::Agent#step} says why and
  # {Lain::Context::Mailbox} records the defect that taught it -- reading the
  # shared log live at commit "claimed a mid-dispatch arrival as a causal
  # parent of a turn that never rendered it, marking it consumed and losing it
  # from every future fold".
  #
  # These drive a real Agent over a real Timeline; the seam is the only double,
  # because production wires no non-Null mailbox and a Null one makes every
  # ordering of capture, render and commit look the same.
  describe "the per-turn mailbox snapshot" do
    let(:store) { CoreGraph.store }
    let(:log) { Lain::Tools::Subagent::Log.new }
    let(:parent_timeline) do
      CoreGraph.timeline(store:)
               .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
               .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
    end
    let(:recipient) { Lain::Event::ChainWriter.correlation_of(parent_timeline) }
    let(:seam) { A1MailboxSeam::Seam.new(source: Lain::Context::Mailbox::Source.new(recipient:, log:)) }

    def note(text)
      lineage = Lain::Tools::Subagent::Lineage.new(policy: CoreGraph.spawn_policy, log:)
      lineage.note(parent_timeline, from: "actor", to: recipient, text:, causal_parents: [])
    end

    # The seam rides the Agent's mailbox: slot AND the tail of its Context
    # pipeline -- one object, both ducks.
    def seam_context
      klass = Class.new(Lain::Context)
      stage = seam
      klass.define_singleton_method(:pipeline) { |workspace| Lain::Context.pipeline(workspace) >> stage }
      klass.new(model: "parent", max_tokens: 128)
    end

    def seam_agent(provider)
      described_class.new(provider:, toolset: CoreGraph.toolset([]),
                          context: seam_context, timeline: parent_timeline, mailbox: seam)
    end

    def mailbox_text(request)
      request.messages.last["content"].filter_map { |block| block["text"] }.join("\n")
    end

    # A Mailbox combinator binds its snapshot at construction, so a pipeline
    # built ONCE would re-fold turn 1's stale snapshot on turn 2 and never see
    # what arrived in between.
    it "folds each turn's OWN frozen snapshot -- no stale pipeline-construction binding" do
      provider = CoreGraph.provider(text_response("turn one"), text_response("turn two"))
      a = seam_agent(provider)

      first_note = note("before turn one")
      a.ask("first")
      second_note = note("between turns")
      a.ask("second")

      first_request, second_request = provider.requests
      expect(mailbox_text(first_request)).to include("before turn one")
      expect(mailbox_text(second_request)).to include("between turns")
      expect(mailbox_text(second_request)).not_to include("before turn one")

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
      a = seam_agent(provider)

      pre_note = note("before the turn")
      a.ask("first")
      a.ask("second")

      first_request, second_request = provider.requests
      expect(mailbox_text(first_request)).to include("before the turn")
      expect(mailbox_text(first_request)).not_to include("mid-turn arrival")
      expect(mailbox_text(second_request)).to include("mid-turn arrival")

      turns = a.timeline.to_a
      # Turn 1's commit consumed exactly its render's fold -- never the note
      # that arrived during the round trip; turn 2 consumed the straggler.
      expect(turns[3].causal_parents).to eq([pre_note.digest])
      expect(turns[5].causal_parents).to eq([mid_note.digest])
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
        .to contain_exactly(:provider, :model_middleware, :handler, :tool_middleware, :tool_observer, :journal)
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
end
