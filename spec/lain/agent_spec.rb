# frozen_string_literal: true

# A1's per-turn Context sources. Defined in a module body so each pipeline is
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

# T22: one recorder per {Lain::Agent::Instrumentation} member, so "the value
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

RSpec.describe Lain::Agent do
  # ---- fixtures -------------------------------------------------------------

  let(:toolset) { Lain::Toolset.new([EchoTool.new, BoomTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  def agent(responses, **overrides)
    described_class.new(
      provider: Lain::Provider::Mock.new(responses: Array(responses)),
      toolset:,
      context:,
      **overrides
    )
  end

  # A thinking block rides along on every tool_use here, so the loop is
  # exercised with the mixed content real responses carry.
  def tool_response(*calls) = super(*calls, thinking: "considering")

  # ---- the loop -------------------------------------------------------------

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

  # I6 (ruled): the tool_result commit is what DELIVERS an ask_human answer
  # back into the conversation, so that commit is the consumption edge -- the
  # :turn whose causal_parents cite Q, which is the ONLY thing that retires Q
  # from Projection#pending("human") (a reply :message alone never does; the
  # rule is pinned in status_feed_spec and projection's own doc).
  describe "ask_human consumption: the delivery commit cites the answered question" do
    it "records Q's digest as a causal parent of the tool_result turn" do
      a = nil
      ask = Lain::Tools::AskHuman.new(parent: -> { a.timeline })
      a = described_class.new(
        provider: Lain::Provider::Mock.new(responses: [
                                             tool_response(["tu_1", "ask_human", { "question" => "which db?" }]),
                                             text_response("done")
                                           ]),
        toolset: Lain::Toolset.new([ask]), context:
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
        provider: Lain::Provider::Mock.new(responses: [
                                             tool_response(["tu_1", "ask_human", { "question" => "which db?" }]),
                                             tool_response(["tu_2", "ask_human", { "question" => "and port?" }]),
                                             text_response("done")
                                           ]),
        toolset: Lain::Toolset.new([ask]), context:
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
      provider = Lain::Provider::Mock.new(
        responses: [text_response("", stop_reason: :pause_turn), text_response("finished")]
      )
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
      let(:context) { Lain::Context.new(model: "qwen3:4b", max_tokens: 1024) }

      # An Agent built with no book of its own. `ContextWindow.default`'s
      # conservative fallback is the honest answer for a caller that named no
      # window -- a wired chat is handed the provider-derived book instead
      # (T10, {CLI::Backend#context_window}), which is the example below.
      it "measures against the conservative fallback window" do
        a = agent(spent(4096))
        a.ask("hi")

        expect(a.occupancy).to eq(0.5)
      end

      # T10: the book is CONSTRUCTOR state, not a per-call default, because the
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
    # published contract: T13 renders it per prompt, so a caller that cannot
    # afford a raise on a blank model slot has to know it can happen rather
    # than discovering it as a REPL crash.
    context "with a blank model slot" do
      let(:context) { Lain::Context.new(model: "  ", max_tokens: 1024) }

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
      # :stalled is B11's additive dual-ledger state (see LoopMachine); the
      # transition-legality gates (agent_state_machine_spec's StopReason
      # totality + FAILURE_REASONS) are untouched -- this is a state-set snapshot
      # that grows with an authorized addition, like the generated diagram.
      expect(described_class::STATES)
        .to contain_exactly(:awaiting_user, :awaiting_model, :awaiting_tools,
                            :awaiting_approval, :stalled, :done, :failed)
    end
  end

  # T15: pin the Agent's existing Timeline injection seam (agent.rb:71,84) --
  # `timeline: nil` already defaults to a fresh Timeline, so passing one in is
  # already "resume from here". Subagent#spawn_agent is the production caller
  # (lib/lain/tools/subagent.rb:222); these examples pin the behavior it
  # depends on before T19 builds further on it. Spec-only: no lib change.
  describe "an injected Timeline" do
    let(:seeded_store) { Lain::Store.new }

    def committed(store, *turns)
      turns.inject(Lain::Timeline.empty(store:)) do |timeline, (role, text)|
        timeline.commit(role:, content: [{ "type" => "text", "text" => text }])
      end
    end

    def seed(store)
      committed(store, [:user, "first"], [:assistant, "ack"], [:user, "second"])
    end

    it "is the starting state: the request renders all three turns before the new user turn" do
      provider = Lain::Provider::Mock.new(responses: [text_response("hello")])
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
      assistant_head = committed(Lain::Store.new, [:user, "first"], [:assistant, "ack"])

      a = agent(text_response("hello"), timeline: assistant_head)
      a.ask("more")

      expect(a.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
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
  end

  describe "session threading" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    attr_reader :tmpdir

    # AC4: the Agent threads ONE session end to end. A read on the first turn is
    # visible to a probe tool that runs on a later turn, through its invocation
    # context -- and that context IS the Agent's own session, not a copy.
    it "hands every tool the same session, with earlier reads already recorded" do
      path = File.join(tmpdir, "read.txt")
      File.write(path, "contents")
      sightings = []
      toolset = Lain::Toolset.new([Lain::Tools::ReadFile.new, ContextProbe.new(sightings)])

      a = described_class.new(
        provider: Lain::Provider::Mock.new(responses: [
                                             tool_response(["tu_1", "read_file", { "path" => path }]),
                                             tool_response(["tu_2", "probe", {}]),
                                             text_response
                                           ]),
        toolset:,
        context:
      )
      a.ask("please read then probe")

      expect(sightings.last).to be(a.session)
      expect(sightings.last.read?(path)).to be(true)
      expect(a.session.read?(path)).to be(true)
    end

    # AC5: a reminder rides the Workspace tail into the Request, and NEVER lands
    # in the Timeline (Workspace is sent, not stored). The Session stays ignorant
    # of Workspace; the Agent composes them per render.
    it "carries a session reminder into the request tail without appending it to the Timeline" do
      reminding = instance_double(Lain::Session, reminders: ["ping the model"])
      provider = Lain::Provider::Mock.new(responses: [text_response])
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

  # A1: @context is construction-fixed and #render_request always rendered from
  # it, so a strategy that must re-decide EVERY turn (compaction) had nowhere to
  # live. The source is that seam: one message, asked once per render.
  describe "the per-turn Context source" do
    def texts(request) = request.messages.flat_map { |m| m["content"].map { |b| b["text"] } }.compact

    # AC1. The default is a real Null Object, so an Agent built without a source
    # sends the bytes its base Context renders -- not "equivalent" bytes.
    it "sends a Request byte-identical to the base Context's own render, with no source wired" do
      provider = Lain::Provider::Mock.new(responses: [text_response])
      a = described_class.new(provider:, toolset:, context:)
      a.ask("hi")

      direct = context.render(timeline: a.timeline.rewind(1), toolset:, workspace: Lain::Workspace.empty)
      # `eq`, deliberately NOT have_same_digest_as: Request#digest is Canonical
      # over #cache_payload, which by design omits `stream` and `extra`, so two
      # Requests differing in either share a digest. Request is a Data, so
      # value equality covers every field this example claims is identical.
      expect(provider.last_request).to eq(direct)
    end

    # AC2.
    it "renders through the Context the source returns, so its pipeline decides what is sent" do
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      text_response])
      a = described_class.new(provider:, toolset:, context:,
                              pipeline_source: A1PipelineSources::Pruning.new(keep_last: 2))
      a.ask("hi")

      expect(provider.requests.last.messages.size).to eq(2)
      expect(texts(provider.requests.last)).not_to include("hi")
    end

    # AC3. A source consulted once per RUN would answer [1, 1, 1] here; one
    # consulted per RENDER widens with the turn.
    it "is consulted once per render, not once per run" do
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      tool_response(["tu_2", "echo", { "text" => "y" }]),
                                                      text_response])
      a = described_class.new(provider:, toolset:, context:, pipeline_source: A1PipelineSources::Widening.new)
      a.ask("hi")

      expect(provider.requests.map { |request| request.messages.size }).to eq([1, 2, 3])
    end

    # AC4. `session:` is the parameter this card exists to place: the Session is
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
      provider = Lain::Provider::Mock.new(responses: [first, text_response])
      recorder = A1PipelineSources::Recording.new
      a = described_class.new(provider:, toolset:, context:, pipeline_source: recorder)
      a.ask("hi")

      expect(recorder.calls.map { |call| call[:usage] }).to eq([nil, 42])
      expect(recorder.calls.map { |call| call[:session] }).to all(be(a.session))
      expect(recorder.calls.map { |call| call[:base] }).to all(be(a.context))
      expect(recorder.calls.last[:timeline].head_digest).to eq(a.timeline.rewind(1).head_digest)
    end

    # AC6. `Scheduler::COMPOSE` calls `Ractor.make_shareable` on a lambda closing
    # over the pipeline, so a per-turn Context that is not shareable is not a
    # style failure -- it is an IsolationError on the compacting turn.
    it "keeps every per-turn Context Ractor-shareable" do
      source = A1PipelineSources::Pruning.new(keep_last: 2)
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      text_response])
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
      provider = Lain::Provider::Mock.new(responses: [text_response])
      override = Lain::Agent::RequestOverride.new
      a = described_class.new(provider:, toolset:, context:, pipeline_source: recorder,
                              request_override: override)
      override.queue(context.render(timeline: Lain::Timeline.empty(store: Lain::Store.new)
                                                            .commit(role: :user, content: [{ "type" => "text",
                                                                                             "text" => "edited" }]),
                                    toolset:))
      a.ask("hi")

      expect(recorder.calls).to be_empty
      expect(texts(provider.last_request)).to include("edited")
    end
  end

  # A7's owed diff: the post-dispatch tool-result observer is threaded from the
  # constructor into ToolRunner, and defaults to the Null so an Agent built
  # without one behaves byte-identically.
  describe "the tool-result observer" do
    it "hands each completed tool_result block to an injected observer" do
      seen = []
      observer = Class.new do
        def initialize(seen) = @seen = seen

        def observe(block, tool_name) = @seen << "#{tool_name}:#{block["tool_use_id"]}"
      end.new(seen)
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      text_response])
      described_class.new(provider:, toolset:, context:, tool_observer: observer).ask("hi")

      expect(seen).to eq(["echo:tu_1"])
    end

    it "observes nothing by default, leaving the delivered results byte-identical" do
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      text_response])
      a = described_class.new(provider:, toolset:, context:)
      a.ask("hi")

      results = a.timeline.to_a[2].content
      expect(results.map { |block| block["type"] }).to eq(["tool_result"])
    end
  end

  # T21: the Agent accepts the three objects it drives -- ModelCaller,
  # ToolRunner, Accounting -- instead of only the ingredients it builds them
  # from. Additive: the legacy keywords stay, and every existing call site
  # keeps its meaning. Mixing the two styles for ONE collaborator is the loud
  # case, because it states two answers to a single wiring question.
  describe "collaborator injection" do
    # One value per wiring keyword, so the clash table below can name a
    # collaborator and an ingredient and get a constructible pair. Built per
    # call: an Agent must never be handed a collaborator another Agent drives.
    def wiring_value(keyword)
      { model_caller: Lain::Agent::ModelCaller.new(provider: Lain::Provider::Mock.new(responses: [])),
        tool_runner: Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new),
        accounting: Lain::Agent::Accounting.new,
        provider: Lain::Provider::Mock.new(responses: []),
        model_middleware: Lain::Middleware::Stack.new,
        handler: Lain::Effect::Handler::Mock.new,
        tool_middleware: Lain::Middleware::Stack.new,
        tool_observer: Lain::Agent::ToolRunner::Observer::Null.new,
        journal: RecordingChannel.new }.fetch(keyword)
    end

    it "drives injected collaborators, with no provider:, journal: or middleware keyword" do
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                                      text_response("bye")])
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
                              model_caller: Lain::Agent::ModelCaller.new(provider: Lain::Provider::Mock.new(
                                responses: []
                              )))

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

    it "demands a provider when no model_caller is injected" do
      expect { described_class.new(toolset:, context:) }
        .to raise_error(ArgumentError, /provider/)
    end

    it "still refuses an unknown keyword, so a typo cannot be swallowed as wiring" do
      expect { described_class.new(toolset:, context:, provider: wiring_value(:provider), providr: nil) }
        .to raise_error(ArgumentError, /providr/)
    end

    # Both styles are valid; mixing them for one collaborator is not.
    { model_caller: %i[provider model_middleware],
      tool_runner: %i[handler tool_middleware tool_observer],
      accounting: %i[journal] }.each do |collaborator, ingredients|
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

  # T21's correctness gate, and the one place the two construction styles could
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
      Lain::Toolset.new([tool])
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
      Lain::Timeline.empty(store: Lain::Store.new)
                    .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
    end

    # The delivery turn: the one user message holding every tool_result, whose
    # causal_parents carry the harvest.
    def tool_result_turn(agent)
      agent.timeline.to_a.find { |event| event.content.any? { |block| block["type"] == "tool_result" } }
    end

    def handover_turn(style)
      seeded = seeded_timeline
      provider = Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "ask_human", {}]), text_response])
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
        described_class.new(toolset:, context:, provider: Lain::Provider::Mock.new(responses: []),
                            tool_runner: Lain::Agent::ToolRunner.new(handler: Lain::Effect::Handler::Mock.new))
      end.to raise_error(ArgumentError, /toolset/)
    end
  end

  # T22: the seven keywords a run REPORTS through -- the journal, the three
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
      Lain::Provider::Mock.new(responses: [tool_response(["tu_1", "echo", { "text" => "x" }]),
                                           text_response("bye")])
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
          described_class.new(toolset:, context:, provider: Lain::Provider::Mock.new(responses: []),
                              instrumentation: Lain::Agent::Instrumentation.new,
                              member => Lain::Agent::Instrumentation.new.public_send(member))
        end.to raise_error(ArgumentError, /instrumentation:.*#{member}:/m)
      end
    end

    # Every wiring keyword this constructor does not name lands in the
    # instrumentation resolver, which is therefore the only place a wiring typo
    # can be answered. It has to answer with the route to the fix: naming
    # `providr:` back at the caller without naming `provider:` is what Ruby's
    # own `unknown keyword:` does, and what Collaborators' vocabulary list used
    # to do before the slice put it out of reach.
    it "answers a typo with the keyword the caller meant, not just the typo" do
      message = begin
        described_class.new(toolset:, context:, providr: Lain::Provider::Mock.new(responses: []))
        raise "expected an ArgumentError, and none was raised"
      rescue ArgumentError => e
        e.message
      end

      expect(message).to include("providr:")
      expect(message).to include("provider:", "journal:", "pipeline_source:")
    end

    # `handler:` and `provider:` are NOT instrumentation members -- they are
    # {Collaborators} ingredients -- so naming them beside a value that carries
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
end
