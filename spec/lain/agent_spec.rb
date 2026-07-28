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
  # Provider::Mock in provider/mock_spec.rb and against AnthropicRaw. What stays
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
        ask.reply("postgres")
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
        ask.reply("postgres")
        # In a reactor, sleep yields this fiber, so the resumed loop commits
        # the first delivery and parks on the second ask before we continue.
        sleep(0.01)
        expect(ask.last_question).not_to eq(first_question)
        ask.reply("5432")
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
      expect(result_block["content"]).to match(/kaboom/)
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
      expect(a.failure_reason).to match(/refused/)
    end

    it "fails on max_tokens" do
      a = agent(text_response("", stop_reason: :max_tokens))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to match(/max_tokens/)
    end

    # The wire enums are non-exhaustive. An unrecognized value must fail loudly,
    # not fall through a `case` and quietly do nothing.
    it "fails on an unrecognized stop_reason" do
      a = agent(Lain::Response.new(content: [], stop_reason: "something_new_in_2027"))
      a.ask("hi")
      expect(a).to be_failed
      expect(a.failure_reason).to match(/unrecognized/)
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

      it "measures against the conservative fallback window" do
        a = agent(spent(4096))
        a.ask("hi")

        expect(a.occupancy).to eq(0.5)
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
      expect(source.contexts).to all(be_ractor_shareable)
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
end
